/* Real SetupAPI collector with deterministic OS doubles. No monitor or
 * registry configuration is modified. Run as a native 32-bit Windows test. */
#define WINVER 0x0601
#define _WIN32_WINNT 0x0601
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

enum { EMPTY = 1, SET_DENIED = 2, ENUM_FAILED = 4, KEY_DENIED = 8,
    MISSING_EDID = 16, WRONG_TYPE = 32, OVERSIZE = 64, CHANGED_EDID = 128,
    REPLACED = 256, REPARENTED = 512, NO_IDENTITY = 1024, DUPLICATE = 2048,
    PARENT_CYCLE = 4096, LARGE_EDID = 8192 };
static unsigned mode, device_count = 2, enum_calls, key_reads[130], open_sets, open_keys, queries;
static size_t allocations, fail_at;
static BYTE edid[128];
enum { DESKTOP_NORMAL = 1, DESKTOP_INACTIVE, DESKTOP_MODE_FAILED, DESKTOP_MODE_CHANGED,
    DESKTOP_ID_CHANGED, DESKTOP_DUPLICATE, DESKTOP_MAP_FAILED, DESKTOP_BAD_SIZE,
    DESKTOP_TRUNCATED, DESKTOP_DEFAULT_HZ, DESKTOP_ZERO_HZ, DESKTOP_OPTIONAL_ABSENT,
    DESKTOP_REORDERED, DESKTOP_FLAGS_CHANGED, DESKTOP_BAD_ORIENTATION, DESKTOP_CALL_BUDGET };
static unsigned desktop_mode, desktop_pass, desktop_calls;

static HDEVINFO WINAPI fixture_create(const GUID *guid, HWND parent) {
    assert(!guid && !parent && !open_sets);++open_sets;++desktop_pass;
    return (HDEVINFO)(uintptr_t)2;
}
static BOOL WINAPI fixture_desktop(LPCWSTR adapter, DWORD index, PDISPLAY_DEVICEW output, DWORD flags) {
    assert(output->cb == sizeof(*output));++desktop_calls;
    if (!desktop_mode) return FALSE;
    if (!adapter) {
        assert(flags == 0);
        if (desktop_mode == DESKTOP_CALL_BUDGET) {
            wcscpy(output->DeviceName, L"\\\\.\\DISPLAY1");
            return TRUE;
        }
        if (index) return FALSE;
        wcscpy(output->DeviceName, L"\\\\.\\DISPLAY1");
        output->StateFlags = DISPLAY_DEVICE_ATTACHED_TO_DESKTOP | DISPLAY_DEVICE_PRIMARY_DEVICE;
        if (desktop_mode == DESKTOP_INACTIVE) output->StateFlags = 0;
        if (desktop_mode == DESKTOP_FLAGS_CHANGED && desktop_pass == 2) output->StateFlags ^= DISPLAY_DEVICE_PRIMARY_DEVICE;
        return TRUE;
    }
    assert(flags == EDD_GET_DEVICE_INTERFACE_NAME && !wcscmp(adapter, L"\\\\.\\DISPLAY1"));
    if (desktop_mode == DESKTOP_CALL_BUDGET) return FALSE;
    unsigned count = desktop_mode == DESKTOP_TRUNCATED ? 129 : 2;
    if (index >= count) return FALSE;
    unsigned id = desktop_mode == DESKTOP_REORDERED && desktop_pass == 2 ? 1 - index : index;
    if (desktop_mode == DESKTOP_DUPLICATE) id = 0;
    swprintf(output->DeviceName, 32, L"\\\\.\\DISPLAY1\\Monitor%u", id);
    swprintf(output->DeviceID, 128, L"\\\\?\\monitor-interface-%u", id);
    output->StateFlags = DISPLAY_DEVICE_ACTIVE;
    if (desktop_mode == DESKTOP_ID_CHANGED && desktop_pass == 2) wcscpy(output->DeviceID, L"\\\\?\\changed-interface");
    return TRUE;
}
static BOOL WINAPI fixture_mode(LPCWSTR name, DWORD index, DEVMODEW *output, DWORD flags) {
    assert(!wcscmp(name, L"\\\\.\\DISPLAY1") && index == ENUM_CURRENT_SETTINGS && flags == 0);
    assert(output->dmSize == sizeof(*output) && !output->dmDriverExtra);
    if (desktop_mode == DESKTOP_MODE_FAILED) return FALSE;
    output->dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_BITSPERPEL
        | DM_POSITION | DM_DISPLAYORIENTATION | DM_DISPLAYFLAGS;
    output->dmPelsWidth = desktop_mode == DESKTOP_BAD_SIZE ? 0 : 2560;
    output->dmPelsHeight = 1440;
    if (desktop_mode == DESKTOP_MODE_CHANGED && desktop_pass == 2) output->dmPelsWidth = 1920;
    output->dmPosition.x = -2560;output->dmPosition.y = -120;
    output->dmDisplayOrientation = desktop_mode == DESKTOP_BAD_ORIENTATION ? 4 : DMDO_90;
    output->dmBitsPerPel = 32;output->dmDisplayFrequency = desktop_mode == DESKTOP_DEFAULT_HZ ? 1
        : desktop_mode == DESKTOP_ZERO_HZ ? 0 : 144;
    if (desktop_mode == DESKTOP_OPTIONAL_ABSENT) output->dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
    return TRUE;
}
static BOOL WINAPI fixture_interface(HDEVINFO set, PCWSTR name, DWORD flags, PSP_DEVICE_INTERFACE_DATA output) {
    assert((uintptr_t)set == 2 && flags == 0 && output->cbSize == sizeof(*output));
    if (desktop_mode == DESKTOP_MAP_FAILED) return FALSE;
    unsigned index = 0;
    if (wcscmp(name, L"\\\\?\\changed-interface")) assert(swscanf(name, L"\\\\?\\monitor-interface-%u", &index) == 1);
    else index = 9;
    output->Reserved = index;return TRUE;
}
static BOOL WINAPI fixture_interface_detail(HDEVINFO set, PSP_DEVICE_INTERFACE_DATA interface_data,
        PSP_DEVICE_INTERFACE_DETAIL_DATA_W output, DWORD capacity, PDWORD bytes, PSP_DEVINFO_DATA device) {
    assert((uintptr_t)set == 2 && !output && capacity == 0 && bytes && device->cbSize == sizeof(*device));
    *bytes = 100;device->Reserved = interface_data->Reserved;device->DevInst = (DEVINST)(device->Reserved + 10);
    SetLastError(ERROR_INSUFFICIENT_BUFFER);return FALSE;
}

static HDEVINFO WINAPI fixture_set(const GUID *guid, PCWSTR enumerator, HWND parent, DWORD flags) {
    assert(guid && guid->Data1 == 0x4d36e96e && !enumerator && !parent && flags == DIGCF_PRESENT);
    if (mode & SET_DENIED) { SetLastError(ERROR_ACCESS_DENIED);return INVALID_HANDLE_VALUE; }
    ++open_sets;return (HDEVINFO)(uintptr_t)1;
}
static BOOL WINAPI fixture_enum(HDEVINFO set, DWORD index, PSP_DEVINFO_DATA output) {
    assert((uintptr_t)set == 1 && output->cbSize == sizeof(*output));++enum_calls;
    if ((mode & ENUM_FAILED) && index == 1) { SetLastError(ERROR_ACCESS_DENIED);return FALSE; }
    if ((mode & EMPTY) || index >= device_count) { SetLastError(ERROR_NO_MORE_ITEMS);return FALSE; }
    output->DevInst = index + 10;
    output->Reserved = index;
    return TRUE;
}
static BOOL WINAPI fixture_instance(HDEVINFO set, PSP_DEVINFO_DATA device, PWSTR output, DWORD capacity, PDWORD required) {
    (void)set;(void)required;assert(capacity >= 128);
    if (mode & NO_IDENTITY) return FALSE;
    unsigned index = (unsigned)device->Reserved;
    if (mode & DUPLICATE) index = 0;
    swprintf(output, capacity, L"DISPLAY\\FIX1234\\PRIVATE-SERIAL-%u", index);
    return TRUE;
}
static BOOL WINAPI fixture_property(HDEVINFO set, PSP_DEVINFO_DATA device, DWORD property,
    PDWORD type, PBYTE output, DWORD capacity, PDWORD required) {
    (void)set;(void)device;(void)required;assert(property == SPDRP_SERVICE);
    static const WCHAR service[] = L"fixture-display";
    assert(capacity >= sizeof(service));*type = REG_SZ;memcpy(output, service, sizeof(service));return TRUE;
}
static BOOL WINAPI fixture_destroy(HDEVINFO set) { assert(((uintptr_t)set == 1 || (uintptr_t)set == 2) && open_sets == 1);--open_sets;return TRUE; }
static HKEY WINAPI fixture_key(HDEVINFO set, PSP_DEVINFO_DATA device, DWORD scope, DWORD profile, DWORD key, REGSAM access) {
    (void)set;assert(scope == DICS_FLAG_GLOBAL && profile == 0 && key == DIREG_DEV && access == KEY_QUERY_VALUE);
    if (mode & KEY_DENIED) { SetLastError(ERROR_ACCESS_DENIED);return (HKEY)INVALID_HANDLE_VALUE; }
    ++open_keys;return (HKEY)(uintptr_t)(device->Reserved + 10);
}
static LONG WINAPI fixture_query(HKEY key, LPCWSTR name, LPDWORD reserved, LPDWORD type, LPBYTE output, LPDWORD bytes) {
    unsigned index = (unsigned)((uintptr_t)key - 10);
    assert(!wcscmp(name, L"EDID") && !reserved && *bytes == 32768 && open_keys == 1);
    ++key_reads[index];++queries;
    if (mode & MISSING_EDID) return ERROR_FILE_NOT_FOUND;
    *type = mode & WRONG_TYPE ? REG_SZ : REG_BINARY;
    if (mode & OVERSIZE) { *bytes = 32769;return ERROR_MORE_DATA; }
    *bytes = mode & LARGE_EDID ? 32768 : 128;
    memset(output, 0, *bytes);memcpy(output, edid, 128);
    if ((mode & CHANGED_EDID) && (key_reads[index] & 1u) == 0) output[20] ^= 1;
    return ERROR_SUCCESS;
}
static LONG WINAPI fixture_close(HKEY key) { (void)key;assert(open_keys == 1);--open_keys;return ERROR_SUCCESS; }
static CONFIGRET WINAPI fixture_parent(PDEVINST parent, DEVINST child, ULONG flags) {
    assert(flags == 0);
    if (child >= 10 && child < 140) {
        if (mode & PARENT_CYCLE) *parent = child;
        else if ((mode & REPARENTED) && key_reads[child - 10]) *parent = 201;
        else *parent = 200;
        return CR_SUCCESS;
    }
    return CR_NO_SUCH_DEVNODE;
}
static CONFIGRET WINAPI fixture_id(DEVINST device, PWSTR output, ULONG capacity, ULONG flags) {
    assert(flags == 0 && capacity >= 128);
    if (device == 200) wcscpy(output, L"PCI\\VEN_1234&DEV_5678\\PRIVATE-PARENT");
    else if (device == 201) wcscpy(output, L"USB\\VID_1234&PID_5678\\PRIVATE-PARENT");
    else {
        unsigned index = (unsigned)device - 10;
        if (mode & DUPLICATE) index = 0;
        swprintf(output, capacity, L"DISPLAY\\FIX1234\\PRIVATE-SERIAL-%u%s", index,
            (mode & REPLACED) && key_reads[(unsigned)device - 10] ? L"-NEW" : L"");
    }
    return CR_SUCCESS;
}
#define SetupDiGetClassDevsW fixture_set
#define SetupDiCreateDeviceInfoList fixture_create
#define SetupDiOpenDeviceInterfaceW fixture_interface
#define SetupDiGetDeviceInterfaceDetailW fixture_interface_detail
#define SetupDiEnumDeviceInfo fixture_enum
#define SetupDiGetDeviceInstanceIdW fixture_instance
#define SetupDiGetDeviceRegistryPropertyW fixture_property
#define SetupDiDestroyDeviceInfoList fixture_destroy
#define SetupDiOpenDevRegKey fixture_key
#define RegQueryValueExW fixture_query
#define RegCloseKey fixture_close
#include "../../native/wtop_windows_hw.c"

static void *allocator(void *opaque, void *pointer, size_t old_size, size_t size) {
    (void)opaque;(void)old_size;
    if (!size) { free(pointer);return NULL; }
    assert(open_sets == 0 && open_keys == 0 && "Lua allocation while a WinAPI handle is open");
    ++allocations;
    if (fail_at && allocations >= fail_at) return NULL;
    return realloc(pointer, size);
}
static int collect(lua_State *L, unsigned selected, unsigned count) {
    lua_settop(L, 0);mode = selected;device_count = count;enum_calls = queries = desktop_pass = desktop_calls = 0;
    memset(key_reads, 0, sizeof(key_reads));assert(!open_sets && !open_keys);
    lua_pushcfunction(L, l_collect_displays);
    int status = lua_pcall(L, 0, 1, 0);
    assert(!open_sets && !open_keys);
    return status;
}
static void text_is(lua_State *L, const char *field, const char *wanted) {
    lua_getfield(L, -1, field);assert(lua_type(L, -1) == LUA_TSTRING && !strcmp(lua_tostring(L, -1), wanted));lua_pop(L, 1);
}
static void record(lua_State *L, int index) {
    lua_settop(L, 1);lua_getfield(L, 1, "devices");lua_rawgeti(L, -1, index);lua_remove(L, -2);assert(lua_istable(L, -1));
}
static void absent(lua_State *L, const char *field) { lua_getfield(L, -1, field);assert(lua_isnil(L, -1));lua_pop(L, 1); }
static void integer_is(lua_State *L, const char *field, lua_Integer expected) {
    lua_getfield(L, -1, field);assert(lua_isinteger(L, -1) && lua_tointeger(L, -1) == expected);lua_pop(L, 1);
}
static void boolean_is(lua_State *L, const char *field, int expected) {
    lua_getfield(L, -1, field);assert(lua_isboolean(L, -1) && lua_toboolean(L, -1) == expected);lua_pop(L, 1);
}
int main(void) {
    lua_State *L = lua_newstate(allocator, NULL, 0);assert(L);
    inventory_cm.resolved = 1;inventory_cm.parent = fixture_parent;inventory_cm.id = fixture_id;
    wtop_desktop_api.resolved = 1;wtop_desktop_api.devices = fixture_desktop;wtop_desktop_api.mode = fixture_mode;
    memcpy(edid, "\0\xff\xff\xff\xff\xff\xff\0", 8);edid[8] = 0x4c;edid[9] = 0x2d;edid[18] = 1;edid[19] = 4;
    for (unsigned i = 0, sum = 0; i < 127; ++i) { sum += edid[i];if (i == 126) edid[127] = (BYTE)(-sum); }
    assert(collect(L, 0, 2) == LUA_OK);text_is(L, "backend", "setupapi");text_is(L, "status", "ok");text_is(L, "quality", "fresh");assert(queries == 4);
    record(L, 1);text_is(L, "id", "monitor0");text_is(L, "connection", "unknown");text_is(L, "edid_status", "ok");
    lua_getfield(L, -1, "os_present");assert(lua_toboolean(L, -1));lua_pop(L, 1);
    absent(L, "enabled");text_is(L, "_pnp_instance_id", "DISPLAY\\FIX1234\\PRIVATE-SERIAL-0");text_is(L, "_pnp_parent_bus", "pci");
    lua_getfield(L, -1, "_edid");size_t bytes;assert(lua_tolstring(L, -1, &bytes) && bytes == 128 && !memcmp(lua_tostring(L, -1), edid, 128));lua_pop(L, 1);
    unsigned failures[] = { CHANGED_EDID, REPLACED, REPARENTED, NO_IDENTITY, DUPLICATE };
    for (unsigned i = 0; i < sizeof(failures) / sizeof(failures[0]); ++i) {
        assert(collect(L, failures[i], 2) == LUA_OK);text_is(L, "quality", "partial");record(L, 1);text_is(L, "quality", "gap");
        absent(L, "_edid");absent(L, "_pnp_parent_id");absent(L, "os_present");
    }
    assert(collect(L, KEY_DENIED, 1) == LUA_OK);record(L, 1);text_is(L, "edid_status", "denied");absent(L, "_edid");
    assert(collect(L, MISSING_EDID, 1) == LUA_OK);record(L, 1);text_is(L, "edid_status", "unavailable");
    assert(collect(L, WRONG_TYPE, 1) == LUA_OK);record(L, 1);text_is(L, "edid_status", "error");
    assert(collect(L, OVERSIZE, 1) == LUA_OK);record(L, 1);text_is(L, "edid_reason", "edid_too_large");
    assert(collect(L, PARENT_CYCLE, 1) == LUA_OK);record(L, 1);text_is(L, "reason", "display_parent_unavailable");absent(L, "_pnp_parent_id");
    assert(collect(L, EMPTY, 0) == LUA_OK);text_is(L, "status", "unavailable");text_is(L, "reason", "no_windows_displays");
    assert(collect(L, SET_DENIED, 0) == LUA_OK);text_is(L, "status", "denied");
    assert(collect(L, ENUM_FAILED, 2) == LUA_OK);text_is(L, "quality", "partial");
    assert(collect(L, 0, 129) == LUA_OK);assert(enum_calls == 129);lua_getfield(L, 1, "truncated");assert(lua_toboolean(L, -1));lua_pop(L, 1);
    assert(collect(L, LARGE_EDID, 33) == LUA_OK);record(L, 33);text_is(L, "edid_reason", "display_edid_budget_exhausted");absent(L, "_edid");
    wtop_desktop_api.mode = NULL;
    assert(collect(L, 0, 2) == LUA_OK);text_is(L, "quality", "fresh");
    record(L, 1);text_is(L, "desktop_status", "unavailable");absent(L, "current_mode");
    wtop_desktop_api.mode = fixture_mode;
    desktop_mode = DESKTOP_NORMAL;
    assert(collect(L, 0, 2) == LUA_OK);text_is(L, "quality", "fresh");
    for (int index = 1; index <= 2; ++index) {
        record(L, index);text_is(L, "desktop_status", "ok");text_is(L, "current_mode_status", "ok");
        boolean_is(L, "desktop_active", 1);boolean_is(L, "desktop_primary", 1);
        absent(L, "interface_name");absent(L, "adapter");
        lua_getfield(L, -1, "current_mode");
        integer_is(L, "pixel_width", 2560);integer_is(L, "pixel_height", 1440);
        integer_is(L, "refresh_hz", 144);integer_is(L, "bits_per_pixel", 32);
        integer_is(L, "position_x", -2560);integer_is(L, "position_y", -120);integer_is(L, "orientation_degrees", 90);
        text_is(L, "scope", "windows_desktop_source");boolean_is(L, "interlaced", 0);
    }
    unsigned gaps[] = { DESKTOP_MODE_CHANGED, DESKTOP_ID_CHANGED, DESKTOP_DUPLICATE, DESKTOP_FLAGS_CHANGED };
    for (unsigned index = 0; index < sizeof(gaps) / sizeof(gaps[0]); ++index) {
        desktop_mode = gaps[index];assert(collect(L, 0, 2) == LUA_OK);text_is(L, "quality", "partial");
        record(L, 1);text_is(L, "desktop_status", "gap");absent(L, "current_mode");absent(L, "desktop_active");
        text_is(L, "edid_status", "ok");boolean_is(L, "os_present", 1);
    }
    unsigned bad_maps[] = { DESKTOP_MAP_FAILED, DESKTOP_TRUNCATED, DESKTOP_CALL_BUDGET };
    for (unsigned index = 0; index < sizeof(bad_maps) / sizeof(bad_maps[0]); ++index) {
        desktop_mode = bad_maps[index];assert(collect(L, 0, 2) == LUA_OK);text_is(L, "quality", "partial");
        assert(desktop_calls <= 2 * WTOP_DESKTOP_CALL_LIMIT);
        record(L, 1);text_is(L, "desktop_status", "error");absent(L, "desktop_active");absent(L, "current_mode");
    }
    unsigned bad_modes[] = { DESKTOP_MODE_FAILED, DESKTOP_BAD_SIZE, DESKTOP_BAD_ORIENTATION };
    for (unsigned index = 0; index < sizeof(bad_modes) / sizeof(bad_modes[0]); ++index) {
        desktop_mode = bad_modes[index];assert(collect(L, 0, 2) == LUA_OK);text_is(L, "quality", "partial");
        record(L, 1);text_is(L, "desktop_status", "ok");boolean_is(L, "desktop_active", 1);absent(L, "current_mode");
        text_is(L, "current_mode_status", desktop_mode == DESKTOP_MODE_FAILED ? "unavailable" : "error");
    }
    desktop_mode = DESKTOP_INACTIVE;assert(collect(L, 0, 2) == LUA_OK);text_is(L, "quality", "fresh");
    record(L, 1);boolean_is(L, "desktop_active", 0);boolean_is(L, "desktop_primary", 0);
    text_is(L, "current_mode_status", "unavailable");absent(L, "current_mode");
    unsigned defaults[] = { DESKTOP_DEFAULT_HZ, DESKTOP_ZERO_HZ, DESKTOP_OPTIONAL_ABSENT, DESKTOP_REORDERED };
    for (unsigned index = 0; index < sizeof(defaults) / sizeof(defaults[0]); ++index) {
        desktop_mode = defaults[index];assert(collect(L, 0, 2) == LUA_OK);text_is(L, "quality", "fresh");
        record(L, 1);text_is(L, "current_mode_status", "ok");lua_getfield(L, -1, "current_mode");
        integer_is(L, "pixel_width", 2560);
        if (desktop_mode != DESKTOP_REORDERED) absent(L, "refresh_hz");
        if (desktop_mode == DESKTOP_OPTIONAL_ABSENT) {
            absent(L, "position_x");absent(L, "orientation_degrees");absent(L, "bits_per_pixel");absent(L, "interlaced");
        }
    }
    desktop_mode = DESKTOP_NORMAL;
    unsigned oom = 0, successes = 0;
    for (unsigned n = 1; n <= 256; ++n) {
        lua_settop(L, 0);lua_gc(L, LUA_GCCOLLECT);
        allocations = 0;fail_at = n;int status = collect(L, 0, 2);fail_at = 0;
        if (status == LUA_ERRMEM) ++oom;else { assert(status == LUA_OK);++successes; }
    }
    assert(oom && successes);lua_close(L);assert(!open_sets && !open_keys);
    printf("Windows display source: cached EDID, verified ancestry, 17 desktop mode scenarios, identity/mode races, ambiguity, signed position, defaults, bounded calls, %u OOM/%u successes, handles closed before Lua allocation passed\n", oom, successes);
    return 0;
}
