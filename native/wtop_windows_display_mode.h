/* Session GDI source modes, joined through the documented monitor interface.
 * No device path is parsed and no display setting is changed. The caller
 * allocates storage before opening any SetupAPI handle. APIs predate XP. */
#ifndef WTOP_WINDOWS_DISPLAY_MODE_H
#define WTOP_WINDOWS_DISPLAY_MODE_H

#define WTOP_DESKTOP_LIMIT 128u
#define WTOP_DESKTOP_CALL_LIMIT 512u
#define WTOP_DESKTOP_FIELDS (DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY \
    | DM_BITSPERPEL | DM_POSITION | DM_DISPLAYORIENTATION | DM_DISPLAYFLAGS)

typedef BOOL (WINAPI *wtop_desktop_devices_fn)(LPCWSTR, DWORD, PDISPLAY_DEVICEW, DWORD);
typedef BOOL (WINAPI *wtop_desktop_mode_fn)(LPCWSTR, DWORD, DEVMODEW *, DWORD);
static struct {
    int resolved;
    wtop_desktop_devices_fn devices;
    wtop_desktop_mode_fn mode;
} wtop_desktop_api;

static int wtop_desktop_ready(void) {
    if (!wtop_desktop_api.resolved) {
        WCHAR path[MAX_PATH];
        UINT length = GetSystemDirectoryW(path, MAX_PATH);
        wtop_desktop_api.resolved = 1;
        if (length && length < MAX_PATH - 12) {
            wcscpy(path + length, L"\\user32.dll");
            HMODULE module = LoadLibraryW(path);
            if (module) {
                wtop_desktop_api.devices = (wtop_desktop_devices_fn)(void *)
                    GetProcAddress(module, "EnumDisplayDevicesW");
                wtop_desktop_api.mode = (wtop_desktop_mode_fn)(void *)
                    GetProcAddress(module, "EnumDisplaySettingsExW");
            }
        }
    }
    return wtop_desktop_api.devices && wtop_desktop_api.mode;
}

typedef struct {
    WCHAR adapter[32], monitor[32], interface_name[128], instance[256];
    DWORD adapter_flags, monitor_flags;
    DEVMODEW mode;
    int mode_read;
} wtop_desktop_row;

typedef struct {
    wtop_desktop_row rows[WTOP_DESKTOP_LIMIT];
    unsigned count, calls;
    int complete;
} wtop_desktop_sample;

/* SetupDiGetDeviceInterfaceDetailW explicitly supports this no-path query:
 * ERROR_INSUFFICIENT_BUFFER fills DeviceInfoData for the opened interface. */
static int wtop_desktop_identity(HDEVINFO set, const WCHAR *path, WCHAR *instance) {
    SP_DEVICE_INTERFACE_DATA interface_data;
    SP_DEVINFO_DATA device;
    WCHAR confirmed[256] = { 0 };
    DWORD bytes = 0;
    memset(&interface_data, 0, sizeof(interface_data));
    memset(&device, 0, sizeof(device));
    interface_data.cbSize = sizeof(interface_data);
    device.cbSize = sizeof(device);
    if (!SetupDiOpenDeviceInterfaceW(set, path, 0, &interface_data)) return 0;
    SetLastError(ERROR_SUCCESS);
    if (SetupDiGetDeviceInterfaceDetailW(set, &interface_data, NULL, 0, &bytes, &device)
            || GetLastError() != ERROR_INSUFFICIENT_BUFFER || !bytes) return 0;
    return SetupDiGetDeviceInstanceIdW(set, &device, instance, 256, NULL)
        && instance[0] && instance[255] == 0
        && wtop_pnp_identity(device.DevInst, confirmed, 256)
        && _wcsicmp(instance, confirmed) == 0;
}

static void wtop_desktop_capture(wtop_desktop_sample *sample) {
    memset(sample, 0, sizeof(*sample));
    sample->complete = 1;
    if (!wtop_desktop_ready()) return;
    HDEVINFO set = SetupDiCreateDeviceInfoList(NULL, NULL);
    if (set == INVALID_HANDLE_VALUE) { sample->complete = 0; return; }
    for (DWORD index = 0; ; ++index) {
        DISPLAY_DEVICEW adapter;
        memset(&adapter, 0, sizeof(adapter));
        adapter.cb = sizeof(adapter);
        if (++sample->calls > WTOP_DESKTOP_CALL_LIMIT) { sample->complete = 0; break; }
        if (!wtop_desktop_api.devices(NULL, index, &adapter, 0)) break;
        if (!adapter.DeviceName[0] || adapter.DeviceName[31]) { sample->complete = 0; break; }
        for (DWORD number = 0; ; ++number) {
            DISPLAY_DEVICEW monitor;
            memset(&monitor, 0, sizeof(monitor));
            monitor.cb = sizeof(monitor);
            if (++sample->calls > WTOP_DESKTOP_CALL_LIMIT) { sample->complete = 0; break; }
            if (!wtop_desktop_api.devices(adapter.DeviceName, number, &monitor,
                    EDD_GET_DEVICE_INTERFACE_NAME)) break;
            if (sample->count == WTOP_DESKTOP_LIMIT) { sample->complete = 0; break; }
            if (!monitor.DeviceID[0] || monitor.DeviceID[127]
                    || !monitor.DeviceName[0] || monitor.DeviceName[31]) {
                sample->complete = 0; break;
            }
            wtop_desktop_row *row = &sample->rows[sample->count++];
            memcpy(row->adapter, adapter.DeviceName, sizeof(row->adapter));
            memcpy(row->monitor, monitor.DeviceName, sizeof(row->monitor));
            memcpy(row->interface_name, monitor.DeviceID, sizeof(row->interface_name));
            row->adapter_flags = adapter.StateFlags;
            row->monitor_flags = monitor.StateFlags;
            if (!wtop_desktop_identity(set, row->interface_name, row->instance)) sample->complete = 0;
            row->mode.dmSize = sizeof(row->mode);
            row->mode_read = wtop_desktop_api.mode(row->adapter, ENUM_CURRENT_SETTINGS, &row->mode, 0) != 0;
        }
        if (!sample->complete) break;
    }
    SetupDiDestroyDeviceInfoList(set);
}

static const wtop_desktop_row *wtop_desktop_find(const wtop_desktop_sample *sample,
        const WCHAR *instance, unsigned *matches) {
    *matches = 0;
    if (!sample->complete) return NULL;
    const wtop_desktop_row *found = NULL;
    for (unsigned index = 0; index < sample->count; ++index) {
        const wtop_desktop_row *row = &sample->rows[index];
        if (_wcsicmp(row->instance, instance)) continue;
        ++*matches;
        found = row;
    }
    return *matches == 1 ? found : NULL;
}

static int wtop_desktop_same(const wtop_desktop_row *a, const wtop_desktop_row *b) {
    if (!a || !b || _wcsicmp(a->adapter, b->adapter) || _wcsicmp(a->monitor, b->monitor)
            || _wcsicmp(a->interface_name, b->interface_name)
            || _wcsicmp(a->instance, b->instance) || a->adapter_flags != b->adapter_flags
            || a->monitor_flags != b->monitor_flags || a->mode_read != b->mode_read) return 0;
    const DEVMODEW *x = &a->mode, *y = &b->mode;
    if (!a->mode_read) return 1;
    /* Compare only documented returned fields. Reserved/private driver bytes
     * and printer unions do not belong to a display observation. */
    DWORD fields = x->dmFields & WTOP_DESKTOP_FIELDS;
    if (fields != (y->dmFields & WTOP_DESKTOP_FIELDS)) return 0;
#define WTOP_MODE_SAME(flag, field) if ((fields & (flag)) && x->field != y->field) return 0
    WTOP_MODE_SAME(DM_PELSWIDTH, dmPelsWidth);
    WTOP_MODE_SAME(DM_PELSHEIGHT, dmPelsHeight);
    WTOP_MODE_SAME(DM_DISPLAYFREQUENCY, dmDisplayFrequency);
    WTOP_MODE_SAME(DM_BITSPERPEL, dmBitsPerPel);
    WTOP_MODE_SAME(DM_DISPLAYORIENTATION, dmDisplayOrientation);
    WTOP_MODE_SAME(DM_DISPLAYFLAGS, dmDisplayFlags);
    WTOP_MODE_SAME(DM_POSITION, dmPosition.x);
    WTOP_MODE_SAME(DM_POSITION, dmPosition.y);
#undef WTOP_MODE_SAME
    return 1;
}

#endif
