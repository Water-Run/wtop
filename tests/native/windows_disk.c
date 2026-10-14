/* Real disk collector, with OS fixtures. No host disks or registry are changed. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <winioctl.h>
#include <lua.h>
#include <lauxlib.h>
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>
#include "../../native/wtop_windows.h"

static unsigned mode, sample, count = 2, opens, closes, destroys, number_calls[258], id_calls[258];
static int reverse_first_two;
enum { LEGACY = 1, NO_SERIAL = 2, BAD_DESCRIPTOR = 4, REUSED_INSTANCE = 8,
    REUSED_NUMBER = 16, DUPLICATE_NUMBER = 32, NO_PARENT = 64, OVERFLOW_TIME = 128,
    SHORT_PERFORMANCE = 256, ONE_REPLACED = 512 };
static WCHAR instance[258][256];
static const char *serial = "PRIVATE-SERIAL-A";
static const char *model = "Drive A";
typedef struct {
    DWORD Version, Size, Flags, DeviceType, DeviceNumber;
    GUID DeviceGuid;
    DWORD PartitionNumber;
} fixture_number_ex;

static HDEVINFO WINAPI devices(const GUID *guid, PCWSTR enumerator, HWND parent, DWORD flags) {
    (void)parent;
    assert(guid && !enumerator && (flags & DIGCF_DEVICEINTERFACE));
    return (HDEVINFO)(uintptr_t)1;
}
static BOOL WINAPI enumerate(HDEVINFO set, PSP_DEVINFO_DATA data, const GUID *guid,
    DWORD index, PSP_DEVICE_INTERFACE_DATA interface) {
    (void)set; (void)data; (void)guid;
    if (index >= count) { SetLastError(ERROR_NO_MORE_ITEMS); return FALSE; }
    assert(interface->cbSize == sizeof(*interface));
    interface->Reserved = reverse_first_two && index < 2 ? index ^ 1u : index;
    return TRUE;
}
static BOOL WINAPI detail(HDEVINFO set, PSP_DEVICE_INTERFACE_DATA interface,
    PSP_DEVICE_INTERFACE_DETAIL_DATA_W output, DWORD capacity, PDWORD required,
    PSP_DEVINFO_DATA device) {
    WCHAR path[32];
    DWORD size;
    (void)set;
    swprintf(path, 32, L"fixture:%lu", (unsigned long)interface->Reserved);
    size = (DWORD)(offsetof(SP_DEVICE_INTERFACE_DETAIL_DATA_W, DevicePath)
        + (wcslen(path) + 1) * sizeof(WCHAR));
    *required = size;
    if (capacity < size) return FALSE;
    assert(output->cbSize == sizeof(*output) && device->cbSize == sizeof(*device));
    wcscpy(output->DevicePath, path);
    device->DevInst = (DWORD)interface->Reserved;
    return TRUE;
}
static HANDLE WINAPI open_disk(LPCWSTR path, DWORD access, DWORD shares,
    LPSECURITY_ATTRIBUTES security, DWORD disposition, DWORD flags, HANDLE template) {
    unsigned i;
    (void)security; (void)template;
    assert(access == 0 && disposition == OPEN_EXISTING && flags == 0);
    assert(shares == (FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE));
    assert(wcsncmp(path, L"fixture:", 8) == 0);
    i = (unsigned)wcstoul(path + 8, NULL, 10);
    assert(i < count);
    ++opens;
    return (HANDLE)(uintptr_t)(i + 100);
}
static BOOL WINAPI close_disk(HANDLE handle) {
    assert((uintptr_t)handle >= 100 && (uintptr_t)handle < 100 + count);
    ++closes; return TRUE;
}
static BOOL WINAPI destroy(HDEVINFO set) { (void)set; ++destroys; return TRUE; }
static int identity(uint32_t devinst, wchar_t *output, size_t capacity) {
    assert(devinst < count && capacity == 256);
    wcscpy(output, instance[devinst]);
    if ((mode & REUSED_INSTANCE) && id_calls[devinst]++) wcscpy(output, L"SCSI\\REPLACEMENT");
    return 1;
}
static int parent(uint32_t devinst, const wchar_t *id, wchar_t *output, char *bus) {
    (void)id;
    if (mode & NO_PARENT) return -1;
    wcscpy(output, devinst == 0 ? L"PCI\\controller" : L"USB\\disk-interface");
    strcpy(bus, devinst == 0 ? "pci" : "usb");
    return 1;
}
static DWORD device_number(unsigned i) {
    return (mode & DUPLICATE_NUMBER) ? 0 : i == 1 ? 257 : i;
}
static BOOL WINAPI ioctl(HANDLE handle, DWORD code, LPVOID input, DWORD input_size,
    LPVOID output, DWORD capacity, LPDWORD returned, LPOVERLAPPED overlapped) {
    unsigned i = (unsigned)(uintptr_t)handle - 100;
    (void)input_size; (void)overlapped;
    if (code == IOCTL_STORAGE_GET_DEVICE_NUMBER) {
        STORAGE_DEVICE_NUMBER *n = output;
        assert(capacity == sizeof(*n));
        memset(n, 0, sizeof(*n)); n->DeviceType = FILE_DEVICE_DISK;
        n->DeviceNumber = device_number(i);
        if ((mode & REUSED_NUMBER) && number_calls[i]++) n->DeviceNumber += 1000;
        *returned = sizeof(*n); return TRUE;
    }
    if (code == CTL_CODE(IOCTL_STORAGE_BASE, 0x0421, METHOD_BUFFERED, FILE_ANY_ACCESS)) {
        fixture_number_ex *n = output;
        if (mode & LEGACY) return FALSE;
        assert(capacity == sizeof(*n));
        memset(n, 0, sizeof(*n)); n->Version = n->Size = sizeof(*n);
        n->DeviceType = FILE_DEVICE_DISK; n->DeviceNumber = device_number(i);
        n->DeviceGuid.Data1 = 100 + i;
        *returned = sizeof(*n); return TRUE;
    }
    if (code == IOCTL_STORAGE_QUERY_PROPERTY) {
        STORAGE_PROPERTY_QUERY *query = input;
        STORAGE_DEVICE_DESCRIPTOR *d = output;
        char *base = output;
        const char *device_model = i == 0 ? model : "Other drive";
        const char *device_serial = i == 0 ? serial
            : (mode & ONE_REPLACED) && i == 1 ? "PRIVATE-REPLACED-SECOND" : "PRIVATE-OTHER";
        DWORD offset = sizeof(*d);
        if ((int)query->PropertyId == 7) return FALSE; /* XP fallback */
        assert(query->PropertyId == StorageDeviceProperty);
        memset(output, 0, capacity);
        d->Version = sizeof(*d);
        d->VendorIdOffset = offset; strcpy(base + offset, "Vendor"); offset += 7;
        d->ProductIdOffset = offset; strcpy(base + offset, device_model); offset += (DWORD)strlen(device_model) + 1;
        d->ProductRevisionOffset = offset; strcpy(base + offset, "1"); offset += 2;
        if (!(mode & NO_SERIAL)) {
            d->SerialNumberOffset = offset; strcpy(base + offset, device_serial); offset += (DWORD)strlen(device_serial) + 1;
        }
        d->Size = offset; d->BusType = i == 0 ? (STORAGE_BUS_TYPE)11 : BusTypeUsb;
        d->RemovableMedia = i != 0;
        *returned = (mode & BAD_DESCRIPTOR) ? capacity + 1 : offset;
        return TRUE;
    }
    if (code == IOCTL_DISK_GET_DRIVE_GEOMETRY_EX) {
        DISK_GEOMETRY_EX *g = output;
        memset(g, 0, sizeof(*g)); g->DiskSize.QuadPart = 1000000000;
        *returned = sizeof(*g); return TRUE;
    }
    if (code == IOCTL_DISK_PERFORMANCE) {
        DISK_PERFORMANCE *p = output;
        memset(p, 0, sizeof(*p));
        p->BytesRead.QuadPart = (sample + 1) * 1024;
        p->BytesWritten.QuadPart = sample * 512;
        p->ReadCount = sample + 1; p->WriteCount = sample;
        p->ReadTime.QuadPart = (mode & OVERFLOW_TIME) ? INT64_MAX : sample * 5000;
        p->WriteTime.QuadPart = sample * 1000;
        p->IdleTime.QuadPart = sample * 5000000;
        *returned = (mode & SHORT_PERFORMANCE)
            ? offsetof(DISK_PERFORMANCE, QueueDepth) + sizeof(p->QueueDepth) : sizeof(*p);
        return TRUE;
    }
    assert(!"unexpected disk control code"); return FALSE;
}

#define SetupDiGetClassDevsW devices
#define SetupDiEnumDeviceInterfaces enumerate
#define SetupDiGetDeviceInterfaceDetailW detail
#define SetupDiDestroyDeviceInfoList destroy
#define CreateFileW open_disk
#define CloseHandle close_disk
#define DeviceIoControl ioctl
#define wtop_pnp_identity identity
#define wtop_pnp_parent parent
#include "../../native/wtop_windows_disk.c"

static void collect(lua_State *L, unsigned scenario) {
    lua_settop(L, 0); mode = scenario; opens = closes = destroys = 0;
    memset(number_calls, 0, sizeof(number_calls)); memset(id_calls, 0, sizeof(id_calls));
    assert(wtop_collect_disk(L) == 1);
    assert(opens == closes && destroys == 1);
    ++sample;
}
static void field_text(lua_State *L, const char *field, const char *expected) {
    lua_getfield(L, -1, field);
    assert(lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), expected) == 0);
    lua_pop(L, 1);
}
static void absent(lua_State *L, const char *field) {
    lua_getfield(L, -1, field); assert(lua_isnil(L, -1)); lua_pop(L, 1);
}
static void get_disk(lua_State *L, int index) {
    lua_getfield(L, -1, "devices"); lua_rawgeti(L, -1, index);
    assert(lua_istable(L, -1)); lua_remove(L, -2);
}
static size_t device_count(lua_State *L) {
    size_t n; lua_getfield(L, -1, "devices"); n = lua_rawlen(L, -1); lua_pop(L, 1); return n;
}
static void save_id(lua_State *L, char *output) {
    lua_getfield(L, -1, "stable_id"); assert(lua_isstring(L, -1));
    assert(strlen(lua_tostring(L, -1)) < 96); strcpy(output, lua_tostring(L, -1)); lua_pop(L, 1);
}
typedef struct { lua_Alloc allocator; void *userdata; size_t maximum; } allocation_policy;
static void *limited_allocate(void *context, void *pointer, size_t old_size, size_t new_size) {
    allocation_policy *policy = context;
    if (new_size >= policy->maximum) return NULL;
    return policy->allocator(policy->userdata, pointer, old_size, new_size);
}
int main(void) {
    lua_State *L = luaL_newstate();
    char first[96], current[96];
    assert(L);
    for (unsigned i = 0; i < 258; ++i) swprintf(instance[i], 256, L"SCSI\\fixture%u", i);
    collect(L, 0); assert(device_count(L) == 2); absent(L, "quality");
    get_disk(L, 2); field_text(L, "id", "PhysicalDrive257");
    field_text(L, "_pnp_parent_bus", "usb"); lua_pop(L, 1);
    get_disk(L, 1); save_id(L, first); field_text(L, "identity_quality", "stable");
    assert(!strstr(first, "PRIVATE") && !strstr(first, "SCSI"));
    lua_getfield(L, -1, "identity"); field_text(L, "model", "Drive A"); absent(L, "serial");
    collect(L, 0); get_disk(L, 1); save_id(L, current); assert(strcmp(first, current) == 0);
    serial = "PRIVATE-SERIAL-B"; model = "Drive B";
    collect(L, 0); get_disk(L, 1); save_id(L, current); assert(strcmp(first, current) != 0);
    lua_getfield(L, -1, "identity"); field_text(L, "model", "Drive B");
    collect(L, LEGACY); get_disk(L, 1); field_text(L, "identity_quality", "stable");
    collect(L, LEGACY | NO_SERIAL); get_disk(L, 1); field_text(L, "identity_quality", "instance");
    collect(L, BAD_DESCRIPTOR); field_text(L, "quality", "partial"); get_disk(L, 1);
    lua_getfield(L, -1, "identity"); absent(L, "model"); absent(L, "removable");
    collect(L, REUSED_INSTANCE); assert(device_count(L) == 0); field_text(L, "quality", "partial");
    collect(L, REUSED_NUMBER); assert(device_count(L) == 0); field_text(L, "quality", "partial");
    collect(L, DUPLICATE_NUMBER); assert(device_count(L) == 0); field_text(L, "quality", "partial");
    collect(L, NO_PARENT); assert(device_count(L) == 2); get_disk(L, 1); absent(L, "_pnp_parent_id");
    collect(L, OVERFLOW_TIME); get_disk(L, 1); lua_getfield(L, -1, "counters"); absent(L, "read_time_ns");
    collect(L, SHORT_PERFORMANCE); get_disk(L, 1);
    lua_getfield(L, -1, "counters"); assert(lua_istable(L, -1));
    count = 0; collect(L, 0); assert(device_count(L) == 0);
    count = 2; collect(L, 0); get_disk(L, 1); save_id(L, first);
    count = 0; collect(L, 0);
    count = 2; collect(L, 0); get_disk(L, 1); save_id(L, current); assert(strcmp(first, current) != 0);
    count = 256; collect(L, 0); get_disk(L, 1); save_id(L, first);
    reverse_first_two = 1; collect(L, ONE_REPLACED); get_disk(L, 2); save_id(L, current);
    assert(strcmp(first, current) == 0); /* cache limit must not evict an unchanged disk */
    reverse_first_two = 0;
    count = 257; collect(L, 0); assert(device_count(L) == 256); field_text(L, "quality", "partial");
    lua_getfield(L, -1, "truncated"); assert(lua_toboolean(L, -1)); lua_pop(L, 1);
    {
        allocation_policy policy;
        count = 2; mode = 0; opens = closes = destroys = 0;
        lua_settop(L, 0);
        lua_pushcfunction(L, wtop_collect_disk);
        policy.allocator = lua_getallocf(L, &policy.userdata);
        policy.maximum = sizeof(disk_row) * 2;
        lua_setallocf(L, limited_allocate, &policy);
        int status = lua_pcall(L, 0, 1, 0);
        lua_setallocf(L, policy.allocator, policy.userdata);
        assert(status == LUA_ERRMEM && opens == 0 && closes == 0 && destroys == 1);
    }
    lua_close(L);
    puts("Windows disks: sparse numbers, current identity, hotplug, bounds and closed handles passed");
    return 0;
}
