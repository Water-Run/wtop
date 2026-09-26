/* Win32 hardware sources: display adapters, processor frequency, batteries,
 * ACPI thermal zones, and service workloads. Every API newer than XP is
 * resolved at run time, so the DLL keeps the XP import set and a source the
 * host lacks is reported as unavailable instead of failing to load. */
#define WINVER 0x0601
#define _WIN32_WINNT 0x0601
#define PSAPI_VERSION 1
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS

#include <windows.h>
#include <dxgi.h>
#include <pdh.h>
#include <pdhmsg.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <winsvc.h>
#include <setupapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <lua.h>
#include <lauxlib.h>

#include "wtop_windows.h"

#define MAX_ADAPTERS 16
#define MAX_ENGINES 256
#define MAX_GPU_PROCESSES 512
#define MAX_PROCESS_ENGINES 8
#define MAX_FREQUENCY_CPUS 256
#define MAX_THERMAL_ZONES 64
#define MAX_SERVICE_HOSTS 1024
#define MAX_SERVICES_PER_HOST 64
#define PDH_MAX_BYTES (8 * 1024 * 1024)

static void integer_field(lua_State *L, const char *name, lua_Integer value) {
    lua_pushinteger(L, value);
    lua_setfield(L, -2, name);
}

static void number_field(lua_State *L, const char *name, lua_Number value) {
    lua_pushnumber(L, value);
    lua_setfield(L, -2, name);
}

static void string_field(lua_State *L, const char *name, const char *value) {
    lua_pushstring(L, value);
    lua_setfield(L, -2, name);
}

static void boolean_field(lua_State *L, const char *name, int value) {
    lua_pushboolean(L, value);
    lua_setfield(L, -2, name);
}

static void utf8_field(lua_State *L, const char *name, const WCHAR *value) {
    wtop_push_utf8(L, value);
    lua_setfield(L, -2, name);
}

static uint64_t filetime_value(FILETIME value) {
    return ((uint64_t)value.dwHighDateTime << 32) | value.dwLowDateTime;
}

/* ------------------------------------------------------------------------
 * Performance Data Helper, resolved dynamically. The English-name API keeps
 * counter paths valid on localized systems; it exists from Vista on, so XP
 * reports these sources as unavailable. */

typedef PDH_STATUS (WINAPI *pdh_open_query_function)(LPCWSTR, DWORD_PTR,
    PDH_HQUERY *);
typedef PDH_STATUS (WINAPI *pdh_add_counter_function)(PDH_HQUERY, LPCWSTR,
    DWORD_PTR, PDH_HCOUNTER *);
typedef PDH_STATUS (WINAPI *pdh_collect_function)(PDH_HQUERY);
typedef PDH_STATUS (WINAPI *pdh_counter_array_function)(PDH_HCOUNTER, DWORD,
    LPDWORD, LPDWORD, PPDH_FMT_COUNTERVALUE_ITEM_W);
typedef PDH_STATUS (WINAPI *pdh_close_function)(PDH_HQUERY);

static struct {
    int resolved;
    pdh_open_query_function open_query;
    pdh_add_counter_function add_counter;
    pdh_collect_function collect;
    pdh_counter_array_function counter_array;
    pdh_close_function close_query;
} pdh;

static int pdh_ready(void) {
    if (!pdh.resolved) {
        HMODULE module = LoadLibraryA("pdh.dll");
        pdh.resolved = 1;
        if (module) {
            pdh.open_query = (pdh_open_query_function)(void *)
                GetProcAddress(module, "PdhOpenQueryW");
            pdh.add_counter = (pdh_add_counter_function)(void *)
                GetProcAddress(module, "PdhAddEnglishCounterW");
            pdh.collect = (pdh_collect_function)(void *)
                GetProcAddress(module, "PdhCollectQueryData");
            pdh.counter_array = (pdh_counter_array_function)(void *)
                GetProcAddress(module, "PdhGetFormattedCounterArrayW");
            pdh.close_query = (pdh_close_function)(void *)
                GetProcAddress(module, "PdhCloseQuery");
        }
    }
    return pdh.open_query && pdh.add_counter && pdh.collect
        && pdh.counter_array && pdh.close_query;
}

#define PDH_SET_COUNTERS 4

typedef struct {
    int state; /* 0 untried, 1 open, -1 unavailable */
    PDH_HQUERY query;
    PDH_HCOUNTER counters[PDH_SET_COUNTERS];
    unsigned collections;
} pdh_set;

/* The first `required` paths must exist; the others are optional. */
static int pdh_set_open(pdh_set *set, const WCHAR *const *paths, int count,
    int required) {
    int index;
    if (set->state) return set->state > 0;
    set->state = -1;
    if (!pdh_ready() || pdh.open_query(NULL, 0, &set->query) != ERROR_SUCCESS)
        return 0;
    for (index = 0; index < count && index < PDH_SET_COUNTERS; ++index) {
        set->counters[index] = NULL;
        if (pdh.add_counter(set->query, paths[index], 0, &set->counters[index])
            != ERROR_SUCCESS) {
            set->counters[index] = NULL;
            if (index < required) {
                pdh.close_query(set->query);
                set->query = NULL;
                return 0;
            }
        }
    }
    set->state = 1;
    return 1;
}

static int pdh_set_collect(pdh_set *set) {
    PDH_STATUS status = pdh.collect(set->query);
    /* A wildcard set with no current instance reports PDH_NO_DATA. */
    if (status != ERROR_SUCCESS && status != (PDH_STATUS)PDH_NO_DATA) return 0;
    set->collections += 1;
    return 1;
}

/* Caller frees the returned array. Rate counters have no value until a
 * second collection, and a counter without instances has no array. */
static PDH_FMT_COUNTERVALUE_ITEM_W *pdh_items(PDH_HCOUNTER counter,
    DWORD *count) {
    DWORD bytes = 0, items = 0;
    PDH_FMT_COUNTERVALUE_ITEM_W *buffer;
    PDH_STATUS status;
    *count = 0;
    if (!counter) return NULL;
    status = pdh.counter_array(counter, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100,
        &bytes, &items, NULL);
    if (status != (PDH_STATUS)PDH_MORE_DATA || bytes == 0 || bytes > PDH_MAX_BYTES)
        return NULL;
    buffer = (PDH_FMT_COUNTERVALUE_ITEM_W *)malloc(bytes);
    if (!buffer) return NULL;
    status = pdh.counter_array(counter, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100,
        &bytes, &items, buffer);
    if (status != ERROR_SUCCESS) {
        free(buffer);
        return NULL;
    }
    *count = items;
    return buffer;
}

static int pdh_item_valid(const PDH_FMT_COUNTERVALUE_ITEM_W *item) {
    return (item->FmtValue.CStatus == PDH_CSTATUS_VALID_DATA
        || item->FmtValue.CStatus == PDH_CSTATUS_NEW_DATA)
        && item->FmtValue.doubleValue == item->FmtValue.doubleValue;
}

/* ------------------------------------------------------------------------
 * Display adapters. SetupAPI lists every present display-class device with
 * its driver key, independent of the session a service or SSH login runs
 * in, back to XP. DXGI 1.1 (Windows 7, or Vista/2008 with the platform
 * update) adds the adapter LUID that ties PDH GPU counters to a device;
 * adapters are joined on their PCI vendor, device, and subsystem IDs. */

typedef HRESULT (WINAPI *create_factory_function)(const IID *, void **);

static const IID wtop_iid_dxgi_factory1 = {0x770aae78, 0xf26f, 0x4dba,
    {0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87}};
static const IID wtop_iid_d3d10_device = {0x9b7e4c0f, 0x342c, 0x4106,
    {0xa1, 0x9f, 0x4f, 0x27, 0x04, 0xf6, 0x89, 0xf0}};
static const GUID wtop_display_class = {0x4d36e968, 0xe325, 0x11ce,
    {0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}};

typedef struct {
    WCHAR name[128];
    WCHAR hardware_id[160];
    WCHAR provider[64];
    UINT vendor_id, device_id, subsystem_id, revision;
    uint64_t dedicated_bytes, shared_bytes;
    LUID luid;
    int has_luid;
    int pci_bus, pci_device, pci_function; /* -1 when unknown */
    char driver_version[32];
    int matched;
} adapter_info;

static struct {
    int loaded;
    HMODULE module;
    create_factory_function create;
    IDXGIFactory1 *factory;
    adapter_info adapters[MAX_ADAPTERS];
    int count;
} dxgi;

static void dxgi_refresh(void) {
    UINT index;
    IDXGIAdapter1 *adapter = NULL;
    if (!dxgi.loaded) {
        dxgi.loaded = 1;
        dxgi.module = LoadLibraryA("dxgi.dll");
        if (dxgi.module)
            dxgi.create = (create_factory_function)(void *)GetProcAddress(
                dxgi.module, "CreateDXGIFactory1");
    }
    if (!dxgi.create) return;
    /* A factory goes stale when adapters change (hot plug, driver update). */
    if (dxgi.factory && IDXGIFactory1_IsCurrent(dxgi.factory)) return;
    if (dxgi.factory) {
        IDXGIFactory1_Release(dxgi.factory);
        dxgi.factory = NULL;
    }
    dxgi.count = 0;
    if (FAILED(dxgi.create(&wtop_iid_dxgi_factory1, (void **)&dxgi.factory))
        || !dxgi.factory) {
        dxgi.factory = NULL;
        return;
    }
    for (index = 0; dxgi.count < MAX_ADAPTERS
        && IDXGIFactory1_EnumAdapters1(dxgi.factory, index, &adapter) == S_OK;
        ++index) {
        DXGI_ADAPTER_DESC1 description;
        LARGE_INTEGER umd_version;
        adapter_info *info;
        memset(&description, 0, sizeof(description));
        /* The Basic Render Driver (1414:008c) is the WARP software
         * rasterizer; DXGI 1.1 does not flag it as software. */
        if (FAILED(IDXGIAdapter1_GetDesc1(adapter, &description))
            || (description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)
            || (description.VendorId == 0x1414 && description.DeviceId == 0x8c)) {
            IDXGIAdapter1_Release(adapter);
            continue;
        }
        info = &dxgi.adapters[dxgi.count++];
        memset(info, 0, sizeof(*info));
        info->pci_bus = info->pci_device = info->pci_function = -1;
        wcsncpy(info->name, description.Description, 127);
        info->vendor_id = description.VendorId;
        info->device_id = description.DeviceId;
        info->subsystem_id = description.SubSysId;
        info->revision = description.Revision;
        info->dedicated_bytes = (uint64_t)description.DedicatedVideoMemory;
        info->shared_bytes = (uint64_t)description.SharedSystemMemory;
        info->luid = description.AdapterLuid;
        info->has_luid = 1;
        /* The Direct3D 10 support query returns the user-mode driver
         * version, the number shown as the driver version in Device Manager. */
        if (IDXGIAdapter1_CheckInterfaceSupport(adapter,
            &wtop_iid_d3d10_device, &umd_version) == S_OK) {
            snprintf(info->driver_version, sizeof(info->driver_version),
                "%u.%u.%u.%u",
                (unsigned)(umd_version.HighPart >> 16),
                (unsigned)(umd_version.HighPart & 0xffff),
                (unsigned)(umd_version.LowPart >> 16),
                (unsigned)(umd_version.LowPart & 0xffff));
        }
        IDXGIAdapter1_Release(adapter);
    }
}

static unsigned hex_after(const WCHAR *text, const WCHAR *prefix) {
    const WCHAR *found = wcsstr(text, prefix);
    unsigned value = 0;
    if (!found) return 0;
    found += wcslen(prefix);
    while ((*found >= L'0' && *found <= L'9') || (*found >= L'a' && *found <= L'f')
        || (*found >= L'A' && *found <= L'F')) {
        WCHAR c = *found++;
        value = value * 16 + (unsigned)(c <= L'9' ? c - L'0'
            : (c | 0x20) - L'a' + 10);
    }
    return value;
}

static int registry_string(HKEY key, const WCHAR *name, WCHAR *output,
    DWORD characters) {
    DWORD type = 0, bytes = (characters - 1) * sizeof(WCHAR);
    if (RegQueryValueExW(key, name, NULL, &type, (BYTE *)output, &bytes)
        != ERROR_SUCCESS || type != REG_SZ) return 0;
    output[bytes / sizeof(WCHAR)] = 0;
    output[characters - 1] = 0;
    return output[0] != 0;
}

static uint64_t registry_memory_size(HKEY key) {
    BYTE data[8];
    DWORD type = 0, bytes = sizeof(data);
    uint64_t result = 0;
    if (RegQueryValueExW(key, L"HardwareInformation.qwMemorySize", NULL,
        &type, data, &bytes) == ERROR_SUCCESS && bytes == 8
        && (type == REG_QWORD || type == REG_BINARY)) {
        memcpy(&result, data, 8);
        return result;
    }
    bytes = sizeof(data);
    if (RegQueryValueExW(key, L"HardwareInformation.MemorySize", NULL,
        &type, data, &bytes) == ERROR_SUCCESS && bytes >= 4
        && (type == REG_DWORD || type == REG_BINARY)) {
        DWORD value;
        memcpy(&value, data, 4);
        result = value;
    }
    return result;
}

static int setupapi_adapters(adapter_info *adapters, int capacity) {
    HDEVINFO set = SetupDiGetClassDevsW(&wtop_display_class, NULL, NULL,
        DIGCF_PRESENT);
    SP_DEVINFO_DATA device;
    int count = 0;
    if (set == INVALID_HANDLE_VALUE) return 0;
    for (DWORD index = 0; count < capacity; ++index) {
        WCHAR ids[512];
        DWORD type = 0, bus = 0, address = 0;
        adapter_info *info;
        HKEY driver;
        memset(&device, 0, sizeof(device));
        device.cbSize = sizeof(device);
        if (!SetupDiEnumDeviceInfo(set, index, &device)) break;
        memset(ids, 0, sizeof(ids));
        if (!SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_HARDWAREID,
            &type, (BYTE *)ids, sizeof(ids) - 2 * sizeof(WCHAR), NULL)) continue;
        /* Remote-desktop and other software display devices are not GPUs. */
        if (_wcsnicmp(ids, L"PCI\\", 4) != 0 && _wcsnicmp(ids, L"ACPI\\", 5) != 0)
            continue;
        info = &adapters[count++];
        memset(info, 0, sizeof(*info));
        info->pci_bus = info->pci_device = info->pci_function = -1;
        wcsncpy(info->hardware_id, ids, 159);
        if (!SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_FRIENDLYNAME,
            &type, (BYTE *)info->name, sizeof(info->name) - sizeof(WCHAR), NULL))
            (void)SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_DEVICEDESC,
                &type, (BYTE *)info->name, sizeof(info->name) - sizeof(WCHAR), NULL);
        info->vendor_id = hex_after(ids, L"VEN_");
        info->device_id = hex_after(ids, L"DEV_");
        info->subsystem_id = hex_after(ids, L"SUBSYS_");
        info->revision = hex_after(ids, L"REV_");
        if (_wcsnicmp(ids, L"PCI\\", 4) == 0
            && SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_BUSNUMBER,
                &type, (BYTE *)&bus, sizeof(bus), NULL)
            && SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_ADDRESS,
                &type, (BYTE *)&address, sizeof(address), NULL)) {
            info->pci_bus = (int)bus;
            info->pci_device = (int)(address >> 16);
            info->pci_function = (int)(address & 0xffff);
        }
        driver = SetupDiOpenDevRegKey(set, &device, DICS_FLAG_GLOBAL, 0,
            DIREG_DRV, KEY_QUERY_VALUE);
        if (driver != INVALID_HANDLE_VALUE) {
            WCHAR version[32];
            info->dedicated_bytes = registry_memory_size(driver);
            if (registry_string(driver, L"DriverVersion", version, 32))
                WideCharToMultiByte(CP_UTF8, 0, version, -1, info->driver_version,
                    sizeof(info->driver_version), NULL, NULL);
            (void)registry_string(driver, L"ProviderName", info->provider, 64);
            RegCloseKey(driver);
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    return count;
}

/* Joins DXGI adapters onto the SetupAPI list and appends the rest. */
static int merged_adapters(adapter_info *adapters, int count) {
    for (int index = 0; index < dxgi.count; ++index) dxgi.adapters[index].matched = 0;
    for (int index = 0; index < count; ++index) {
        adapter_info *info = &adapters[index];
        for (int other = 0; other < dxgi.count; ++other) {
            adapter_info *source = &dxgi.adapters[other];
            if (source->matched || source->vendor_id != info->vendor_id
                || source->device_id != info->device_id
                || (info->subsystem_id && source->subsystem_id
                    && source->subsystem_id != info->subsystem_id)) continue;
            source->matched = 1;
            info->luid = source->luid;
            info->has_luid = 1;
            if (source->dedicated_bytes) info->dedicated_bytes = source->dedicated_bytes;
            info->shared_bytes = source->shared_bytes;
            break;
        }
    }
    for (int other = 0; other < dxgi.count && count < MAX_ADAPTERS; ++other) {
        if (!dxgi.adapters[other].matched) adapters[count++] = dxgi.adapters[other];
    }
    return count;
}

static const char *vendor_name(UINT vendor) {
    switch (vendor) {
    case 0x10de: return "NVIDIA";
    case 0x1002: case 0x1022: return "AMD";
    case 0x8086: return "Intel";
    case 0x1414: return "Microsoft";
    case 0x15ad: return "VMware";
    case 0x80ee: return "VirtualBox";
    case 0x1af4: case 0x1b36: return "Red Hat";
    case 0x1234: return "QEMU";
    case 0x5143: case 0x4d4f4351: return "Qualcomm";
    case 0x102b: return "Matrox";
    case 0x1a03: return "ASPEED";
    case 0x18ca: return "XGI";
    case 0x5333: return "S3";
    default: return NULL;
    }
}

typedef struct {
    LUID luid;
    unsigned phys, engine;
    double value;
    WCHAR type[32];
} engine_total;

typedef struct {
    char name[32];
    double value;
} engine_share;

typedef struct {
    DWORD pid;
    LUID luid;
    double utilization;
    uint64_t dedicated_bytes;
    int has_memory;
    engine_share engines[MAX_PROCESS_ENGINES];
    int engine_count;
} gpu_process;

typedef struct {
    LUID luid;
    double dedicated_used, shared_used;
    int has_dedicated, has_shared;
} adapter_memory;

static pdh_set gpu_counters;

static int parse_luid(const WCHAR *text, LUID *luid, unsigned *phys) {
    const WCHAR *found = wcsstr(text, L"luid_0x");
    unsigned long high = 0, low = 0;
    unsigned physical = 0;
    if (!found || swscanf(found, L"luid_0x%lx_0x%lx_phys_%u", &high, &low,
        &physical) < 2) return 0;
    luid->HighPart = (LONG)high;
    luid->LowPart = (DWORD)low;
    if (phys) *phys = physical;
    return 1;
}

static int same_luid(LUID left, LUID right) {
    return left.HighPart == right.HighPart && left.LowPart == right.LowPart;
}

static gpu_process *find_gpu_process(gpu_process *processes, int *count,
    DWORD pid, LUID luid) {
    for (int index = 0; index < *count; ++index) {
        if (processes[index].pid == pid && same_luid(processes[index].luid, luid))
            return &processes[index];
    }
    if (*count >= MAX_GPU_PROCESSES) return NULL;
    memset(&processes[*count], 0, sizeof(processes[0]));
    processes[*count].pid = pid;
    processes[*count].luid = luid;
    return &processes[(*count)++];
}

static void process_engine_add(gpu_process *process, const WCHAR *type,
    double value) {
    char name[32];
    int length = WideCharToMultiByte(CP_UTF8, 0, type, -1, name, sizeof(name),
        NULL, NULL);
    if (length <= 0) snprintf(name, sizeof(name), "engine");
    name[sizeof(name) - 1] = 0;
    for (int index = 0; index < process->engine_count; ++index) {
        if (strcmp(process->engines[index].name, name) == 0) {
            process->engines[index].value += value;
            return;
        }
    }
    if (process->engine_count < MAX_PROCESS_ENGINES) {
        strcpy(process->engines[process->engine_count].name, name);
        process->engines[process->engine_count++].value = value;
    }
}

/* Pushes a pid -> image name table, empty when nothing needs a name. */
static void push_process_names(lua_State *L, gpu_process *processes, int count) {
    HANDLE snapshot;
    PROCESSENTRY32W entry;
    lua_createtable(L, 0, count);
    if (count == 0) return;
    snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return;
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) {
        do {
            for (int index = 0; index < count; ++index) {
                if (processes[index].pid == entry.th32ProcessID) {
                    entry.szExeFile[MAX_PATH - 1] = 0;
                    wtop_push_utf8(L, entry.szExeFile);
                    lua_rawseti(L, -2, (lua_Integer)entry.th32ProcessID);
                    break;
                }
            }
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
}

static int l_collect_gpu(lua_State *L) {
    static const WCHAR *const paths[] = {
        L"\\GPU Engine(*)\\Utilization Percentage",
        L"\\GPU Adapter Memory(*)\\Dedicated Usage",
        L"\\GPU Adapter Memory(*)\\Shared Usage",
        L"\\GPU Process Memory(*)\\Dedicated Usage",
    };
    adapter_info adapters[MAX_ADAPTERS];
    int adapter_count, counters_ready = 0, rates_ready = 0;
    engine_total *engines = NULL;
    int engine_count = 0;
    gpu_process *processes = NULL;
    int process_count = 0;
    adapter_memory memory[MAX_ADAPTERS];
    int memory_count = 0;
    int names_index;
    const char *source;

    dxgi_refresh();
    adapter_count = merged_adapters(adapters, setupapi_adapters(adapters, MAX_ADAPTERS));
    source = dxgi.count > 0 ? "setupapi+dxgi" : "setupapi";
    if (adapter_count == 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "no_display_adapters");
        return 2;
    }

    /* Windows 10 1709 added GPU counters keyed by adapter LUID. */
    if (dxgi.count > 0 && pdh_set_open(&gpu_counters, paths, 4, 1)
        && pdh_set_collect(&gpu_counters)) {
        DWORD count = 0;
        PDH_FMT_COUNTERVALUE_ITEM_W *items;
        counters_ready = 1;
        engines = (engine_total *)calloc(MAX_ENGINES, sizeof(*engines));
        processes = (gpu_process *)calloc(MAX_GPU_PROCESSES, sizeof(*processes));
        if (!engines || !processes) {
            free(engines);
            free(processes);
            return luaL_error(L, "out of memory collecting GPU counters");
        }
        items = gpu_counters.collections >= 2
            ? pdh_items(gpu_counters.counters[0], &count) : NULL;
        rates_ready = items != NULL || gpu_counters.collections >= 2;
        for (DWORD index = 0; items && index < count; ++index) {
            const WCHAR *name = items[index].szName;
            const WCHAR *type = wcsstr(name, L"engtype_");
            unsigned long pid = 0;
            unsigned phys = 0, engine_index = 0;
            LUID luid;
            const WCHAR *engine_text = wcsstr(name, L"_eng_");
            double value;
            engine_total *total = NULL;
            gpu_process *process;
            if (!pdh_item_valid(&items[index]) || !parse_luid(name, &luid, &phys))
                continue;
            value = items[index].FmtValue.doubleValue;
            if (value < 0) value = 0;
            if (engine_text) swscanf(engine_text, L"_eng_%u", &engine_index);
            type = type ? type + 8 : L"engine";
            for (int other = 0; other < engine_count; ++other) {
                if (same_luid(engines[other].luid, luid) && engines[other].phys == phys
                    && engines[other].engine == engine_index) {
                    total = &engines[other];
                    break;
                }
            }
            if (!total && engine_count < MAX_ENGINES) {
                total = &engines[engine_count++];
                total->luid = luid;
                total->phys = phys;
                total->engine = engine_index;
                wcsncpy(total->type, type, 31);
            }
            if (total) total->value += value;
            if (swscanf(name, L"pid_%lu_", &pid) == 1 && pid > 0 && value > 0) {
                process = find_gpu_process(processes, &process_count,
                    (DWORD)pid, luid);
                if (process) {
                    process_engine_add(process, type, value);
                    if (value > process->utilization) process->utilization = value;
                }
            }
        }
        free(items);
        for (int counter = 1; counter <= 2; ++counter) {
            items = pdh_items(gpu_counters.counters[counter], &count);
            for (DWORD index = 0; items && index < count; ++index) {
                LUID luid;
                adapter_memory *entry = NULL;
                if (!pdh_item_valid(&items[index])
                    || !parse_luid(items[index].szName, &luid, NULL)) continue;
                for (int other = 0; other < memory_count; ++other) {
                    if (same_luid(memory[other].luid, luid)) {
                        entry = &memory[other];
                        break;
                    }
                }
                if (!entry && memory_count < MAX_ADAPTERS) {
                    entry = &memory[memory_count++];
                    memset(entry, 0, sizeof(*entry));
                    entry->luid = luid;
                }
                if (!entry) continue;
                if (counter == 1) {
                    entry->dedicated_used += items[index].FmtValue.doubleValue;
                    entry->has_dedicated = 1;
                } else {
                    entry->shared_used += items[index].FmtValue.doubleValue;
                    entry->has_shared = 1;
                }
            }
            free(items);
        }
        items = pdh_items(gpu_counters.counters[3], &count);
        for (DWORD index = 0; items && index < count; ++index) {
            unsigned long pid = 0;
            LUID luid;
            gpu_process *process;
            double value = items[index].FmtValue.doubleValue;
            if (!pdh_item_valid(&items[index]) || value <= 0
                || swscanf(items[index].szName, L"pid_%lu_", &pid) != 1 || pid == 0
                || !parse_luid(items[index].szName, &luid, NULL)) continue;
            process = find_gpu_process(processes, &process_count, (DWORD)pid, luid);
            if (process) {
                process->dedicated_bytes += (uint64_t)value;
                process->has_memory = 1;
            }
        }
        free(items);
    }

    push_process_names(L, processes, process_count);
    names_index = lua_gettop(L);
    lua_createtable(L, 0, 5);
    string_field(L, "schema", "dev.waterrun.wtop.gpu/v2");
    lua_createtable(L, adapter_count, 0);
    for (int index = 0; index < adapter_count; ++index) {
        adapter_info *info = &adapters[index];
        char text[64];
        double utilization = -1;
        adapter_memory *used = NULL;
        int process_output = 1, total_processes = 0;
        lua_createtable(L, 0, 16);
        if (info->pci_bus >= 0)
            snprintf(text, sizeof(text), "0000:%02x:%02x.%x", info->pci_bus,
                info->pci_device, info->pci_function);
        else if (info->has_luid)
            snprintf(text, sizeof(text), "luid:%08lx%08lx",
                (unsigned long)info->luid.HighPart, (unsigned long)info->luid.LowPart);
        else
            snprintf(text, sizeof(text), "pci:%04x:%04x:%08x:%d", info->vendor_id,
                info->device_id, info->subsystem_id, index);
        string_field(L, "id", text);
        snprintf(text, sizeof(text), "GPU%d", index);
        string_field(L, "card", text);
        snprintf(text, sizeof(text), "0x%04x", info->vendor_id);
        string_field(L, "vendor_id", text);
        string_field(L, "vendor", text);
        snprintf(text, sizeof(text), "0x%04x", info->device_id);
        string_field(L, "device_id", text);
        if (vendor_name(info->vendor_id))
            string_field(L, "vendor_name", vendor_name(info->vendor_id));
        if (info->name[0]) utf8_field(L, "model_name", info->name);
        if (info->driver_version[0]) {
            string_field(L, "driver", info->driver_version);
            string_field(L, "driver_version", info->driver_version);
        }
        if (info->pci_bus >= 0) {
            snprintf(text, sizeof(text), "0000:%02x:%02x.%x", info->pci_bus,
                info->pci_device, info->pci_function);
            string_field(L, "pci_bdf", text);
            string_field(L, "stable_id", text);
        }
        if (info->provider[0]) utf8_field(L, "driver_provider", info->provider);
        string_field(L, "identity_quality", info->pci_bus >= 0 || info->has_luid
            ? "fresh" : "estimated");
        string_field(L, "source", info->hardware_id[0] ? source : "dxgi");
        lua_createtable(L, 0, 3);
        if (info->subsystem_id) {
            snprintf(text, sizeof(text), "0x%04x", info->subsystem_id & 0xffff);
            string_field(L, "subsystem_vendor_id", text);
            snprintf(text, sizeof(text), "0x%04x", info->subsystem_id >> 16);
            string_field(L, "subsystem_device_id", text);
        }
        snprintf(text, sizeof(text), "0x%02x", info->revision);
        string_field(L, "revision", text);
        lua_setfield(L, -2, "pci");

        if (counters_ready && info->has_luid) {
            for (int engine = 0; engine < engine_count; ++engine) {
                if (same_luid(engines[engine].luid, info->luid)
                    && engines[engine].value > utilization)
                    utilization = engines[engine].value;
            }
            if (rates_ready && utilization < 0) utilization = 0;
            for (int other = 0; other < memory_count; ++other) {
                if (same_luid(memory[other].luid, info->luid)) used = &memory[other];
            }
        }
        lua_createtable(L, 0, 8);
        if (utilization >= 0) {
            number_field(L, "utilization_percent",
                utilization > 100 ? 100 : utilization);
            string_field(L, "utilization_source", "pdh_gpu_engine");
        }
        if (info->dedicated_bytes > 0) {
            integer_field(L, "memory_total_bytes", (lua_Integer)info->dedicated_bytes);
            if (used && used->has_dedicated)
                integer_field(L, "memory_used_bytes", (lua_Integer)used->dedicated_used);
        } else if (info->shared_bytes > 0) {
            /* Integrated adapters have no dedicated memory; their budget is
             * shared system memory, which is what Task Manager reports. */
            integer_field(L, "memory_total_bytes", (lua_Integer)info->shared_bytes);
            if (used && used->has_shared)
                integer_field(L, "memory_used_bytes", (lua_Integer)used->shared_used);
        }
        if (info->shared_bytes > 0)
            integer_field(L, "shared_memory_total_bytes", (lua_Integer)info->shared_bytes);
        if (used && used->has_shared)
            integer_field(L, "shared_memory_used_bytes", (lua_Integer)used->shared_used);
        lua_setfield(L, -2, "metrics");

        lua_createtable(L, 0, 2);
        boolean_field(L, "utilization", counters_ready && info->has_luid);
        boolean_field(L, "memory", info->dedicated_bytes > 0 || info->shared_bytes > 0);
        boolean_field(L, "process_usage", counters_ready && info->has_luid);
        lua_setfield(L, -2, "capabilities");
        lua_createtable(L, 0, 1);
        string_field(L, "utilization", !counters_ready || !info->has_luid
            ? "unavailable" : (rates_ready ? "fresh" : "gap"));
        lua_setfield(L, -2, "quality");

        lua_createtable(L, 0, 3);
        lua_createtable(L, 8, 0);
        for (int process_index = 0; process_index < process_count; ++process_index) {
            gpu_process *process = &processes[process_index];
            if (!info->has_luid || !same_luid(process->luid, info->luid)) continue;
            ++total_processes;
            lua_createtable(L, 0, 7);
            snprintf(text, sizeof(text), "%lu", (unsigned long)process->pid);
            string_field(L, "id", text);
            integer_field(L, "pid", (lua_Integer)process->pid);
            lua_rawgeti(L, names_index, (lua_Integer)process->pid);
            lua_setfield(L, -2, "name");
            number_field(L, "utilization_percent",
                process->utilization > 100 ? 100 : process->utilization);
            if (process->has_memory) {
                lua_createtable(L, 0, 1);
                integer_field(L, "resident_bytes", (lua_Integer)process->dedicated_bytes);
                lua_setfield(L, -2, "memory_summary");
            }
            lua_createtable(L, 0, process->engine_count);
            for (int engine = 0; engine < process->engine_count; ++engine) {
                lua_createtable(L, 0, 1);
                number_field(L, "utilization_percent", process->engines[engine].value);
                lua_setfield(L, -2, process->engines[engine].name);
            }
            lua_setfield(L, -2, "engines");
            string_field(L, "quality", "fresh");
            lua_rawseti(L, -2, process_output++);
        }
        lua_setfield(L, -2, "list");
        lua_createtable(L, 0, 2);
        integer_field(L, "process_count", total_processes);
        lua_setfield(L, -2, "summary");
        string_field(L, "quality", counters_ready && info->has_luid
            ? (rates_ready ? "fresh" : "gap") : "unavailable");
        lua_setfield(L, -2, "processes");
        lua_rawseti(L, -2, index + 1);
    }
    lua_setfield(L, -2, "devices");
    lua_createtable(L, 0, 3);
    boolean_field(L, "enabled", counters_ready);
    string_field(L, "status", counters_ready ? "ok" : "unavailable");
    if (!counters_ready) string_field(L, "reason", "gpu_performance_counters_unavailable");
    lua_setfield(L, -2, "process_scan");
    lua_remove(L, names_index);
    free(engines);
    free(processes);
    return 1;
}

/* ------------------------------------------------------------------------
 * Processor frequency. PDH's "% Processor Performance" (Windows 7 / 2008 R2
 * and later) tracks the effective clock, including turbo. The power
 * information query exists back to XP, but from Windows 8 on its current
 * frequency is the nominal one, so it is reported as an estimate there. */

typedef struct {
    ULONG Number;
    ULONG MaxMhz;
    ULONG CurrentMhz;
    ULONG MhzLimit;
    ULONG MaxIdleState;
    ULONG CurrentIdleState;
} processor_power_information;

typedef LONG (WINAPI *call_power_information_function)(int, PVOID, ULONG,
    PVOID, ULONG);
typedef DWORD (WINAPI *power_active_scheme_function)(HKEY, GUID **);
typedef DWORD (WINAPI *power_friendly_name_function)(HKEY, const GUID *,
    const GUID *, const GUID *, PUCHAR, LPDWORD);

static pdh_set frequency_counters;

static int processor_power(processor_power_information *values, ULONG count) {
    static int resolved = 0;
    static call_power_information_function query = NULL;
    if (!resolved) {
        HMODULE module = LoadLibraryA("powrprof.dll");
        resolved = 1;
        query = module ? (call_power_information_function)(void *)
            GetProcAddress(module, "CallNtPowerInformation") : NULL;
    }
    /* ProcessorInformation = 11 */
    return query && query(11, NULL, 0, values,
        count * (ULONG)sizeof(values[0])) == 0;
}

static void push_power_scheme(lua_State *L) {
    static int resolved = 0;
    static power_active_scheme_function active = NULL;
    static power_friendly_name_function friendly = NULL;
    GUID *scheme = NULL;
    WCHAR name[128];
    DWORD bytes = sizeof(name) - sizeof(WCHAR);
    if (!resolved) {
        HMODULE module = LoadLibraryA("powrprof.dll");
        resolved = 1;
        if (module) {
            active = (power_active_scheme_function)(void *)GetProcAddress(module,
                "PowerGetActiveScheme");
            friendly = (power_friendly_name_function)(void *)GetProcAddress(module,
                "PowerReadFriendlyName");
        }
    }
    if (!active || !friendly || active(NULL, &scheme) != ERROR_SUCCESS || !scheme)
        return;
    memset(name, 0, sizeof(name));
    if (friendly(NULL, scheme, NULL, NULL, (PUCHAR)name, &bytes) == ERROR_SUCCESS
        && name[0]) {
        utf8_field(L, "governor", name);
    }
    LocalFree(scheme);
}

static int l_collect_cpufreq(lua_State *L) {
    static const WCHAR *const paths[] = {
        L"\\Processor Information(*)\\Processor Frequency",
        L"\\Processor Information(*)\\% Processor Performance",
    };
    SYSTEM_INFO system;
    processor_power_information *power;
    ULONG count;
    double performance[MAX_FREQUENCY_CPUS], base[MAX_FREQUENCY_CPUS];
    int has_effective = 0, have_power;
    GetSystemInfo(&system);
    count = system.dwNumberOfProcessors;
    if (count == 0) count = 1;
    if (count > MAX_FREQUENCY_CPUS) count = MAX_FREQUENCY_CPUS;
    for (ULONG index = 0; index < count; ++index) performance[index] = base[index] = -1;
    power = (processor_power_information *)calloc(count, sizeof(*power));
    if (!power) return luaL_error(L, "out of memory collecting CPU frequency");
    have_power = processor_power(power, count);

    if (pdh_set_open(&frequency_counters, paths, 2, 2)
        && pdh_set_collect(&frequency_counters) && frequency_counters.collections >= 2) {
        for (int counter = 0; counter < 2; ++counter) {
            DWORD items_count = 0;
            PDH_FMT_COUNTERVALUE_ITEM_W *items = pdh_items(
                frequency_counters.counters[counter], &items_count);
            for (DWORD index = 0; items && index < items_count; ++index) {
                unsigned group = 0, number = 0;
                ULONG cpu;
                if (!pdh_item_valid(&items[index])
                    || swscanf(items[index].szName, L"%u,%u", &group, &number) != 2)
                    continue;
                /* Processor groups hold up to 64 CPUs each. */
                cpu = group * 64 + number;
                if (cpu >= count) continue;
                if (counter == 0) base[cpu] = items[index].FmtValue.doubleValue;
                else performance[cpu] = items[index].FmtValue.doubleValue;
            }
            free(items);
        }
        for (ULONG index = 0; index < count; ++index) {
            if (base[index] > 0 && performance[index] >= 0) has_effective = 1;
        }
    }
    if (!have_power && !has_effective) {
        free(power);
        lua_pushnil(L);
        lua_pushliteral(L, "processor_frequency_unavailable");
        return 2;
    }
    lua_createtable(L, 0, 2);
    lua_createtable(L, (int)count, 0);
    for (ULONG index = 0; index < count; ++index) {
        char name[32];
        double current = -1;
        const char *quality = "fresh";
        const char *driver = "pdh";
        if (base[index] > 0 && performance[index] >= 0) {
            current = base[index] * performance[index] / 100.0;
        } else if (have_power && power[index].CurrentMhz > 0) {
            current = power[index].CurrentMhz;
            driver = "CallNtPowerInformation";
            quality = "estimated";
        }
        lua_createtable(L, 0, 8);
        snprintf(name, sizeof(name), "cpu%lu", (unsigned long)index);
        string_field(L, "id", name);
        string_field(L, "policy", name);
        integer_field(L, "policy_index", (lua_Integer)index);
        lua_createtable(L, 1, 0);
        lua_pushinteger(L, (lua_Integer)index);
        lua_rawseti(L, -2, 1);
        lua_setfield(L, -2, "affected_cpus");
        string_field(L, "driver", driver);
        push_power_scheme(L);
        lua_createtable(L, 0, 6);
        if (current > 0) {
            integer_field(L, "current_hz", (lua_Integer)(current * 1000000.0));
            string_field(L, "current_quality", quality);
        }
        /* Windows reports the rated frequency, not the turbo ceiling, so
         * it is a base value; claiming it as the maximum would be wrong on
         * any CPU that boosts above it. */
        if (base[index] > 0)
            integer_field(L, "base_hz", (lua_Integer)(base[index] * 1000000.0));
        else if (have_power && power[index].MaxMhz > 0)
            integer_field(L, "base_hz", (lua_Integer)power[index].MaxMhz * 1000000);
        if (have_power && power[index].MhzLimit > 0
            && power[index].MhzLimit < power[index].MaxMhz)
            integer_field(L, "limit_hz", (lua_Integer)power[index].MhzLimit * 1000000);
        lua_setfield(L, -2, "frequencies");
        string_field(L, "quality", current > 0 ? quality : "unavailable");
        string_field(L, "source", driver);
        lua_rawseti(L, -2, (lua_Integer)index + 1);
    }
    lua_setfield(L, -2, "policies");
    free(power);
    return 1;
}

/* ------------------------------------------------------------------------
 * Batteries. A host without a system battery reports the same way a Linux
 * desktop without power-supply entries does: the source is unavailable. */

static int l_collect_power_supply(lua_State *L) {
    SYSTEM_POWER_STATUS status;
    const char *state;
    if (!GetSystemPowerStatus(&status)) {
        lua_pushnil(L);
        lua_pushliteral(L, "GetSystemPowerStatus failed");
        return 2;
    }
    if (status.BatteryFlag == 255 || (status.BatteryFlag & 128)) {
        lua_pushnil(L);
        lua_pushliteral(L, "no_power_supplies");
        return 2;
    }
    if (status.BatteryFlag & 8) state = "Charging";
    else if (status.ACLineStatus == 0) state = "Discharging";
    else if (status.BatteryLifePercent == 100) state = "Full";
    else state = "Not charging";
    lua_createtable(L, 0, 4);
    lua_createtable(L, 1, 0);
    lua_createtable(L, 0, 8);
    string_field(L, "id", "BAT0");
    string_field(L, "name", "Battery");
    string_field(L, "type", "Battery");
    boolean_field(L, "present", 1);
    string_field(L, "status", state);
    if (status.BatteryLifePercent <= 100)
        integer_field(L, "capacity_percent", status.BatteryLifePercent);
    if (status.ACLineStatus == 0 && status.BatteryLifeTime != (DWORD)-1)
        integer_field(L, "time_remaining_seconds", (lua_Integer)status.BatteryLifeTime);
    string_field(L, "quality", status.BatteryLifePercent <= 100 ? "fresh" : "partial");
    string_field(L, "source", "GetSystemPowerStatus");
    lua_rawseti(L, -2, 1);
    lua_setfield(L, -2, "batteries");
    lua_createtable(L, 1, 0);
    if (status.ACLineStatus <= 1) {
        lua_createtable(L, 0, 5);
        string_field(L, "id", "AC");
        string_field(L, "name", "AC");
        string_field(L, "type", "Mains");
        boolean_field(L, "online", status.ACLineStatus == 1);
        boolean_field(L, "present", 1);
        lua_rawseti(L, -2, 1);
    }
    lua_setfield(L, -2, "supplies");
    lua_createtable(L, 0, 3);
    integer_field(L, "count", 1);
    if (status.BatteryLifePercent <= 100)
        integer_field(L, "capacity_percent", status.BatteryLifePercent);
    string_field(L, "state", (status.BatteryFlag & 8) ? "charging"
        : status.ACLineStatus == 0 ? "discharging" : "idle");
    lua_setfield(L, -2, "summary");
    if (status.ACLineStatus <= 1) boolean_field(L, "on_ac_power", status.ACLineStatus == 1);
    return 1;
}

/* ------------------------------------------------------------------------
 * ACPI thermal zones through PDH (Windows 7 / 2008 R2 and later). These are
 * the same firmware zones Linux shows as acpitz; many desktop boards report
 * a fixed value there, so the label names the zone rather than a component. */

static pdh_set thermal_counters;

static int l_collect_hwmon(lua_State *L) {
    static const WCHAR *const paths[] = {
        L"\\Thermal Zone Information(*)\\Temperature",
        L"\\Thermal Zone Information(*)\\% Passive Limit",
    };
    PDH_FMT_COUNTERVALUE_ITEM_W *items, *limits = NULL;
    DWORD count = 0, limit_count = 0;
    int output = 1;
    if (!pdh_set_open(&thermal_counters, paths, 2, 1)
        || !pdh_set_collect(&thermal_counters)) {
        lua_pushnil(L);
        lua_pushliteral(L, "thermal_zone_counters_unavailable");
        return 2;
    }
    items = pdh_items(thermal_counters.counters[0], &count);
    if (!items || count == 0) {
        free(items);
        lua_pushnil(L);
        lua_pushliteral(L, "no_thermal_zones");
        return 2;
    }
    limits = pdh_items(thermal_counters.counters[1], &limit_count);
    lua_createtable(L, 0, 2);
    lua_createtable(L, 1, 0);
    lua_createtable(L, 0, 7);
    string_field(L, "id", "acpi_thermal_zones");
    string_field(L, "class", "acpi_thermal_zones");
    string_field(L, "name", "ACPI thermal zone");
    string_field(L, "identity_quality", "fresh");
    string_field(L, "quality", "fresh");
    string_field(L, "source", "pdh:Thermal Zone Information");
    lua_createtable(L, (int)count, 0);
    for (DWORD index = 0; index < count && output <= MAX_THERMAL_ZONES; ++index) {
        double kelvin;
        char id[32];
        if (!pdh_item_valid(&items[index])) continue;
        kelvin = items[index].FmtValue.doubleValue;
        /* Zero kelvin is how an unimplemented zone reads. */
        if (kelvin <= 0) continue;
        lua_createtable(L, 0, 9);
        snprintf(id, sizeof(id), "temp%d", output);
        string_field(L, "id", id);
        string_field(L, "type", "temperature");
        integer_field(L, "index", output);
        string_field(L, "unit", "celsius");
        utf8_field(L, "label", items[index].szName);
        number_field(L, "input", kelvin - 273.15);
        string_field(L, "input_source", "pdh");
        string_field(L, "quality", "fresh");
        for (DWORD limit = 0; limits && limit < limit_count; ++limit) {
            if (pdh_item_valid(&limits[limit])
                && wcscmp(limits[limit].szName, items[index].szName) == 0) {
                /* Below 100% the firmware is passively throttling the CPU. */
                boolean_field(L, "alarm", limits[limit].FmtValue.doubleValue < 100);
                break;
            }
        }
        lua_rawseti(L, -2, output++);
    }
    lua_setfield(L, -2, "channels");
    lua_rawseti(L, -2, 1);
    lua_setfield(L, -2, "devices");
    boolean_field(L, "truncated", output > MAX_THERMAL_ZONES);
    free(items);
    free(limits);
    return 1;
}

/* ------------------------------------------------------------------------
 * Workloads: running Win32 services grouped by their host process. Services
 * that share one svchost instance share its CPU and memory, so a workload is
 * a host process listing its services, never a per-service split that the
 * operating system does not measure. */

typedef struct {
    DWORD pid;
    int count;
    int own_process;
    const ENUM_SERVICE_STATUS_PROCESSW *services[MAX_SERVICES_PER_HOST];
} service_host;

static int service_compare(const void *left, const void *right) {
    const ENUM_SERVICE_STATUS_PROCESSW *a = *(const ENUM_SERVICE_STATUS_PROCESSW *const *)left;
    const ENUM_SERVICE_STATUS_PROCESSW *b = *(const ENUM_SERVICE_STATUS_PROCESSW *const *)right;
    return _wcsicmp(a->lpServiceName, b->lpServiceName);
}

static int l_collect_cgroup(lua_State *L) {
    SC_HANDLE manager;
    BYTE *buffer = NULL;
    DWORD bytes = 0, needed = 0, returned = 0, resume = 0;
    ENUM_SERVICE_STATUS_PROCESSW *services;
    service_host *hosts;
    int host_count = 0, output = 2, denied = 0, running = 0;
    uint64_t total_memory = 0;
    manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_ENUMERATE_SERVICE);
    if (!manager) {
        DWORD code = GetLastError();
        lua_pushnil(L);
        lua_pushstring(L, code == ERROR_ACCESS_DENIED ? "service_manager_denied"
            : "service_manager_unavailable");
        return 2;
    }
    (void)EnumServicesStatusExW(manager, SC_ENUM_PROCESS_INFO, SERVICE_WIN32,
        SERVICE_ACTIVE, NULL, 0, &needed, &returned, &resume, NULL);
    if (GetLastError() != ERROR_MORE_DATA || needed == 0 || needed > 16 * 1024 * 1024) {
        CloseServiceHandle(manager);
        lua_pushnil(L);
        lua_pushliteral(L, "EnumServicesStatusExW failed");
        return 2;
    }
    bytes = needed + 4096;
    buffer = (BYTE *)malloc(bytes);
    hosts = (service_host *)calloc(MAX_SERVICE_HOSTS, sizeof(*hosts));
    if (!buffer || !hosts) {
        free(buffer);
        free(hosts);
        CloseServiceHandle(manager);
        return luaL_error(L, "out of memory collecting services");
    }
    resume = 0;
    if (!EnumServicesStatusExW(manager, SC_ENUM_PROCESS_INFO, SERVICE_WIN32,
        SERVICE_ACTIVE, buffer, bytes, &needed, &returned, &resume, NULL)) {
        free(buffer);
        free(hosts);
        CloseServiceHandle(manager);
        lua_pushnil(L);
        lua_pushliteral(L, "EnumServicesStatusExW failed");
        return 2;
    }
    CloseServiceHandle(manager);
    services = (ENUM_SERVICE_STATUS_PROCESSW *)buffer;
    for (DWORD index = 0; index < returned; ++index) {
        DWORD pid = services[index].ServiceStatusProcess.dwProcessId;
        service_host *host = NULL;
        if (services[index].ServiceStatusProcess.dwCurrentState != SERVICE_RUNNING
            || pid == 0) continue;
        ++running;
        for (int other = 0; other < host_count; ++other) {
            if (hosts[other].pid == pid) {
                host = &hosts[other];
                break;
            }
        }
        if (!host && host_count < MAX_SERVICE_HOSTS) {
            host = &hosts[host_count++];
            host->pid = pid;
            host->own_process = (services[index].ServiceStatusProcess.dwServiceType
                & SERVICE_WIN32_OWN_PROCESS) != 0;
        }
        if (host && host->count < MAX_SERVICES_PER_HOST)
            host->services[host->count++] = &services[index];
    }

    lua_createtable(L, 0, 5);
    string_field(L, "schema", "dev.waterrun.wtop.windows-services/v1");
    string_field(L, "kind", "service");
    lua_createtable(L, host_count + 1, 0);
    for (int index = 0; index < host_count; ++index) {
        service_host *host = &hosts[index];
        HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
            FALSE, host->pid);
        FILETIME created, exited, kernel, user;
        wtop_memory_counters memory;
        IO_COUNTERS io;
        char id[64];
        int has_times = 0, has_memory = 0, has_io = 0;
        if (!process) process = OpenProcess(0x1000, FALSE, host->pid);
        if (process) {
            has_times = GetProcessTimes(process, &created, &exited, &kernel, &user);
            has_memory = wtop_process_memory(process, &memory);
            has_io = GetProcessIoCounters(process, &io);
            CloseHandle(process);
        } else {
            ++denied;
        }
        qsort(host->services, (size_t)host->count, sizeof(host->services[0]),
            service_compare);
        lua_createtable(L, 0, 12);
        if (has_times)
            snprintf(id, sizeof(id), "service:%lu:%llu", (unsigned long)host->pid,
                (unsigned long long)filetime_value(created));
        else
            snprintf(id, sizeof(id), "service:%lu", (unsigned long)host->pid);
        string_field(L, "id", id);
        string_field(L, "parent_id", "services");
        integer_field(L, "depth", 1);
        integer_field(L, "pid", (lua_Integer)host->pid);
        {
            luaL_Buffer name;
            int shown = host->count < 3 ? host->count : 3;
            luaL_buffinit(L, &name);
            for (int service = 0; service < shown; ++service) {
                if (service > 0) luaL_addstring(&name, ", ");
                wtop_push_utf8(L, host->services[service]->lpServiceName);
                luaL_addvalue(&name);
            }
            if (host->count > shown) {
                char more[24];
                snprintf(more, sizeof(more), " +%d", host->count - shown);
                luaL_addstring(&name, more);
            }
            luaL_pushresult(&name);
            lua_setfield(L, -2, "name");
        }
        lua_createtable(L, host->count, 0);
        for (int service = 0; service < host->count; ++service) {
            lua_createtable(L, 0, 2);
            utf8_field(L, "name", host->services[service]->lpServiceName);
            utf8_field(L, "display_name", host->services[service]->lpDisplayName);
            lua_rawseti(L, -2, service + 1);
        }
        lua_setfield(L, -2, "services");
        boolean_field(L, "shared_host", host->count > 1 || !host->own_process);
        boolean_field(L, "accessible", process != NULL);
        boolean_field(L, "partial", !has_times || !has_memory);
        lua_createtable(L, 0, 1);
        integer_field(L, "count", 1);
        lua_setfield(L, -2, "processes");
        if (has_times) {
            lua_createtable(L, 0, 1);
            integer_field(L, "usage_ns", (lua_Integer)((filetime_value(kernel)
                + filetime_value(user)) * 100ULL));
            lua_setfield(L, -2, "raw_cpu");
        }
        if (has_memory) {
            lua_createtable(L, 0, 2);
            integer_field(L, "current_bytes", (lua_Integer)memory.working_set);
            integer_field(L, "private_bytes", (lua_Integer)memory.private_bytes);
            lua_setfield(L, -2, "memory");
            total_memory += memory.working_set;
        }
        if (has_io) {
            lua_createtable(L, 0, 2);
            integer_field(L, "rbytes", (lua_Integer)io.ReadTransferCount);
            integer_field(L, "wbytes", (lua_Integer)io.WriteTransferCount);
            lua_setfield(L, -2, "raw_io");
        }
        lua_rawseti(L, -2, output++);
    }
    /* The root row aggregates every service host. */
    lua_createtable(L, 0, 8);
    string_field(L, "id", "services");
    string_field(L, "name", "Services");
    integer_field(L, "depth", 0);
    boolean_field(L, "accessible", 1);
    boolean_field(L, "partial", denied > 0);
    lua_createtable(L, 0, 1);
    integer_field(L, "count", host_count);
    lua_setfield(L, -2, "processes");
    lua_createtable(L, 0, 1);
    integer_field(L, "current_bytes", (lua_Integer)total_memory);
    lua_setfield(L, -2, "memory");
    lua_rawseti(L, -2, 1);
    lua_setfield(L, -2, "workloads");
    integer_field(L, "running_services", running);
    integer_field(L, "denied_hosts", denied);
    boolean_field(L, "truncated", host_count >= MAX_SERVICE_HOSTS);
    free(buffer);
    free(hosts);
    return 1;
}

/* ------------------------------------------------------------------------
 * Process memory. A 32-bit process reading a 64-bit one through psapi gets
 * SIZE_T counters that saturate at 4 GiB, so under WOW64 the native 64-bit
 * VM counters are queried instead. */

typedef struct {
    uint64_t peak_virtual, virtual_size;
    uint32_t page_faults, padding;
    uint64_t peak_working_set, working_set;
    uint64_t quota_peak_paged, quota_paged, quota_peak_nonpaged, quota_nonpaged;
    uint64_t pagefile, peak_pagefile, private_usage;
} vm_counters64;

typedef LONG (NTAPI *wow64_query_function)(HANDLE, ULONG, PVOID, ULONG, PULONG);
typedef BOOL (WINAPI *is_wow64_function)(HANDLE, PBOOL);

int wtop_process_memory(void *process, wtop_memory_counters *counters) {
    static int resolved = 0;
    static wow64_query_function wow64_query = NULL;
    PROCESS_MEMORY_COUNTERS_EX memory;
    if (!resolved) {
        HMODULE kernel = GetModuleHandleA("kernel32.dll");
        HMODULE ntdll = GetModuleHandleA("ntdll.dll");
        is_wow64_function is_wow64 = kernel ? (is_wow64_function)(void *)
            GetProcAddress(kernel, "IsWow64Process") : NULL;
        BOOL wow64 = FALSE;
        resolved = 1;
        if (is_wow64 && is_wow64(GetCurrentProcess(), &wow64) && wow64 && ntdll)
            wow64_query = (wow64_query_function)(void *)GetProcAddress(ntdll,
                "NtWow64QueryInformationProcess64");
    }
    memset(counters, 0, sizeof(*counters));
    if (wow64_query) {
        vm_counters64 vm;
        memset(&vm, 0, sizeof(vm));
        /* ProcessVmCounters = 3; the shorter form lacks PrivateUsage. */
        if (wow64_query(process, 3, &vm, sizeof(vm), NULL) >= 0
            || wow64_query(process, 3, &vm, sizeof(vm) - sizeof(uint64_t), NULL) >= 0) {
            counters->working_set = vm.working_set;
            counters->commit = vm.pagefile;
            counters->private_bytes = vm.private_usage ? vm.private_usage : vm.pagefile;
            return 1;
        }
    }
    memset(&memory, 0, sizeof(memory));
    memory.cb = sizeof(memory);
    if (!GetProcessMemoryInfo(process, (PROCESS_MEMORY_COUNTERS *)&memory,
        sizeof(memory))) {
        memory.cb = sizeof(PROCESS_MEMORY_COUNTERS);
        if (!GetProcessMemoryInfo(process, (PROCESS_MEMORY_COUNTERS *)&memory,
            sizeof(PROCESS_MEMORY_COUNTERS))) return 0;
        memory.PrivateUsage = memory.PagefileUsage;
    }
    counters->working_set = memory.WorkingSetSize;
    counters->commit = memory.PagefileUsage;
    counters->private_bytes = memory.PrivateUsage;
    return 1;
}

/* ------------------------------------------------------------------------
 * A Cygwin/OpenSSH launcher passes its own Windows PID. When the session
 * hangs up, that shell exits while the pipe it handed over can stay open, so
 * the terminal loop watches the launcher instead of waiting for end-of-file. */

static HANDLE watched_launcher = NULL;
static int watch_checked = 0;

int wtop_launcher_gone(void) {
    if (!watch_checked) {
        char text[32];
        DWORD length = GetEnvironmentVariableA("WTOP_WATCH_PID", text, sizeof(text));
        watch_checked = 1;
        if (length > 0 && length < sizeof(text)) {
            unsigned long pid = strtoul(text, NULL, 10);
            if (pid > 0 && pid != GetCurrentProcessId())
                watched_launcher = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid);
        }
    }
    return watched_launcher
        && WaitForSingleObject(watched_launcher, 0) == WAIT_OBJECT_0;
}

static const luaL_Reg hardware_functions[] = {
    {"collect_gpu", l_collect_gpu},
    {"collect_cpufreq", l_collect_cpufreq},
    {"collect_power_supply", l_collect_power_supply},
    {"collect_hwmon", l_collect_hwmon},
    {"collect_cgroup", l_collect_cgroup},
    {NULL, NULL},
};

void wtop_register_hardware(lua_State *L) {
    luaL_setfuncs(L, hardware_functions, 0);
}
