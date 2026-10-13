/* Exercise the real collector without changing any host devices. */
#define WINVER 0x0601
#define _WIN32_WINNT 0x0601
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <lua.h>
#include <lauxlib.h>

static WCHAR manufacturer[96], description[151], usb_instance[200];
static unsigned destroyed, mode, parent_calls[5];
enum { REPLACED = 1, REPARENTED = 2, ENUM_FAILED = 4, ID_FAILED = 8,
    DUPLICATE = 16, NO_HARDWARE_IDS = 32, SHORT_CLASS = 64 };
static const struct {
    DEVINST devinst, parent;
    DWORD bus, slot;
    const WCHAR *instance, *hardware;
} devices[] = {
    { 10, 99, 10, 31u << 16, L"PCI\\ROOT", L"PCI\\VEN_1234&DEV_0000&REV_00" },
    { 11, 10, 1, 0, L"PCI\\CHILD", L"PCI\\VEN_1234&DEV_5678&REV_ABC" },
    { 20, 11, 0, 0, L"USB\\ROOT_HUB30\\fixture", L"USB\\ROOT_HUB30" },
    { 21, 20, 0, 0, usb_instance, L"USB\\VID_1234&PID_0000" },
    { 22, 21, 0, 0, L"USB\\leaf", L"USB\\VID_12345&PID_Z123" },
};

static HDEVINFO WINAPI fixture_devices(const GUID *guid, PCWSTR enumerator,
    HWND parent, DWORD flags) {
    (void)guid; (void)parent; (void)flags;
    return (HDEVINFO)(uintptr_t)(wcscmp(enumerator, L"PCI") == 0 ? 1 : 2);
}

static BOOL WINAPI fixture_enumerate(HDEVINFO set, DWORD index,
    PSP_DEVINFO_DATA device) {
    unsigned first = (uintptr_t)set == 1 ? 0 : 2;
    unsigned count = first == 0 ? 2 : 3;
    if ((mode & ENUM_FAILED) && first == 2 && index == 1) {
        SetLastError(ERROR_ACCESS_DENIED); return FALSE;
    }
    if (index >= count) { SetLastError(ERROR_NO_MORE_ITEMS); return FALSE; }
    device->Reserved = first + index;
    device->DevInst = devices[first + index].devinst;
    if ((mode & DUPLICATE) && first + index == 4) device->DevInst = 21;
    return TRUE;
}

static BOOL WINAPI fixture_property(HDEVINFO set, PSP_DEVINFO_DATA device,
    DWORD property, PDWORD type, PBYTE output, DWORD capacity, PDWORD required) {
    const WCHAR *text = NULL;
    DWORD size;
    unsigned i = (unsigned)device->Reserved;
    (void)set;
    if (property == SPDRP_COMPATIBLEIDS) {
        static const WCHAR compatible[] = L"PCI\\VEN_1234\0PCI\\CC_0c0330\0PCI\\CC_0c03\0";
        static const WCHAR incomplete[] = L"PCI\\CC_0604\0PCI\\CC_0604000\0";
        text = (mode & SHORT_CLASS) ? incomplete : compatible;
        size = (mode & SHORT_CLASS) ? sizeof(incomplete) : sizeof(compatible);
        if (required) *required = size;
        if (capacity < size) return FALSE;
        if (type) *type = REG_MULTI_SZ;
        memcpy(output, text, size);
        return TRUE;
    }
    if (property == SPDRP_BUSNUMBER || property == SPDRP_ADDRESS) {
        DWORD value = property == SPDRP_BUSNUMBER ? devices[i].bus : devices[i].slot;
        if (capacity < sizeof(value)) return FALSE;
        if (type) *type = REG_DWORD;
        memcpy(output, &value, sizeof(value));
        return TRUE;
    }
    if (property == SPDRP_HARDWAREID) {
        if (mode & NO_HARDWARE_IDS) return FALSE;
        text = devices[i].hardware;
    }
    else if (property == SPDRP_MFG) text = manufacturer;
    else if (property == SPDRP_DEVICEDESC) text = description;
    else if (property == SPDRP_SERVICE) text = L"fixture-driver";
    if (!text) return FALSE;
    size = (DWORD)((wcslen(text) + 1) * sizeof(WCHAR));
    if (required) *required = size;
    if (capacity < size) { SetLastError(ERROR_INSUFFICIENT_BUFFER); return FALSE; }
    if (type) *type = property == SPDRP_HARDWAREID ? REG_MULTI_SZ : REG_SZ;
    memcpy(output, text, size);
    return TRUE;
}

static BOOL WINAPI fixture_instance(HDEVINFO set, PSP_DEVINFO_DATA device,
    PWSTR output, DWORD capacity, PDWORD required) {
    const WCHAR *text = devices[device->Reserved].instance;
    DWORD length = (DWORD)wcslen(text) + 1;
    (void)set;
    if ((mode & ID_FAILED) && device->Reserved == 4) return FALSE;
    if (required) *required = length;
    if (capacity < length) return FALSE;
    memcpy(output, text, (size_t)length * sizeof(WCHAR));
    return TRUE;
}

static BOOL WINAPI fixture_destroy(HDEVINFO set) {
    (void)set;
    ++destroyed;
    return TRUE;
}

static CONFIGRET WINAPI fixture_parent(PDEVINST parent, DEVINST child, ULONG flags) {
    assert(flags == 0);
    for (unsigned i = 0; i < 5; ++i) {
        if (devices[i].devinst != child) continue;
        *parent = devices[i].parent;
        if ((mode & REPARENTED) && i == 4 && parent_calls[i] > 0) *parent = 20;
        ++parent_calls[i];
        return CR_SUCCESS;
    }
    return CR_NO_SUCH_DEVNODE;
}

static CONFIGRET WINAPI fixture_id(DEVINST child, PWSTR output, ULONG capacity, ULONG flags) {
    assert(flags == 0);
    for (unsigned i = 0; i < 5; ++i) {
        const WCHAR *text = devices[i].instance;
        size_t length;
        if (devices[i].devinst != child) continue;
        if ((mode & REPLACED) && i == 4) text = L"USB\\replacement";
        length = wcslen(text) + 1;
        if (capacity < length) return CR_BUFFER_SMALL;
        memcpy(output, text, length * sizeof(WCHAR));
        return CR_SUCCESS;
    }
    return CR_NO_SUCH_DEVNODE;
}

#define SetupDiGetClassDevsW fixture_devices
#define SetupDiEnumDeviceInfo fixture_enumerate
#define SetupDiGetDeviceRegistryPropertyW fixture_property
#define SetupDiGetDeviceInstanceIdW fixture_instance
#define SetupDiDestroyDeviceInfoList fixture_destroy
#include "../../native/wtop_windows_hw.c"

static void check_text(lua_State *L, const char *field, const WCHAR *expected) {
    char utf8[1024];
    int length = WideCharToMultiByte(CP_UTF8, 0, expected, -1,
        utf8, sizeof(utf8), NULL, NULL);
    size_t actual_length = 0;
    const char *actual;
    assert(length > 0);
    lua_getfield(L, -1, field);
    actual = lua_tolstring(L, -1, &actual_length);
    if (!actual || actual_length != (size_t)length - 1
        || memcmp(actual, utf8, actual_length) != 0) {
        fprintf(stderr, "%s: wanted %d UTF-8 bytes, got %lu\n", field,
            length - 1, (unsigned long)actual_length);
        exit(1);
    }
    lua_pop(L, 1);
}

static void check_number(lua_State *L, const char *field, int expected) {
    lua_getfield(L, -1, field);
    assert(lua_isinteger(L, -1) && lua_tointeger(L, -1) == expected);
    lua_pop(L, 1);
}

static void check_absent(lua_State *L, const char *field) {
    lua_getfield(L, -1, field);
    assert(lua_isnil(L, -1));
    lua_pop(L, 1);
}

static void get_device(lua_State *L, const char *bus, int index) {
    lua_getfield(L, -1, bus);
    lua_getfield(L, -1, "devices");
    lua_rawgeti(L, -1, index);
    assert(lua_istable(L, -1));
    lua_remove(L, -2);
    lua_remove(L, -2);
}

static void collect(lua_State *L, unsigned scenario) {
    lua_settop(L, 0);
    mode = scenario;
    destroyed = 0;
    memset(parent_calls, 0, sizeof(parent_calls));
    assert(l_collect_inventory(L) == 1);
    assert(destroyed == 2);
}

int main(void) {
    lua_State *L = luaL_newstate();
    assert(L);
    for (unsigned index = 0; index < 95; ++index) manufacturer[index] = 0x4e2d;
    for (unsigned index = 0; index < 150; ++index) description[index] = L'A' + index % 26;
    wcscpy(usb_instance, L"USB\\VID_1234&PID_5678\\");
    for (unsigned index = 0; index < 100; ++index)
        usb_instance[wcslen(L"USB\\VID_1234&PID_5678\\") + index] = 0x4e2d;
    inventory_cm.resolved = 1;
    inventory_cm.parent = fixture_parent;
    inventory_cm.id = fixture_id;
    collect(L, 0);
    check_absent(L, "quality");
    get_device(L, "pci", 1);
    check_number(L, "device_id", 0);
    check_number(L, "revision", 0);
    check_number(L, "class_id", 0x0c0330);
    check_text(L, "driver", L"fixture-driver");
    check_text(L, "address", L"0a:1f.0");
    check_text(L, "vendor_name", manufacturer);
    check_text(L, "device_name", description);
    check_absent(L, "parent_address");
    lua_pop(L, 1);
    get_device(L, "pci", 2);
    check_absent(L, "revision");
    check_text(L, "parent_address", L"0a:1f.0");
    check_text(L, "parent_bus", L"pci");
    lua_pop(L, 1);
    get_device(L, "usb", 1);
    check_absent(L, "vendor_id");
    check_absent(L, "product_id");
    check_text(L, "id", devices[2].instance);
    check_text(L, "parent_id", L"01:00.0");
    check_text(L, "parent_bus", L"pci");
    lua_pop(L, 1);
    get_device(L, "usb", 2);
    check_number(L, "product_id", 0);
    check_text(L, "id", usb_instance);
    check_text(L, "manufacturer", manufacturer);
    check_text(L, "product", description);
    check_text(L, "parent_id", devices[2].instance);
    check_text(L, "parent_bus", L"usb");
    lua_pop(L, 1);
    get_device(L, "usb", 3);
    check_absent(L, "vendor_id");
    check_absent(L, "product_id");
    check_text(L, "parent_id", usb_instance);
    lua_pop(L, 1);
    collect(L, SHORT_CLASS);
    get_device(L, "pci", 1);
    check_absent(L, "class_id");
    for (unsigned scenario = REPLACED; scenario <= REPARENTED; scenario <<= 1) {
        collect(L, scenario);
        check_text(L, "quality", L"partial");
        get_device(L, "usb", 3);
        check_absent(L, "parent_id");
        check_absent(L, "parent_bus");
    }
    collect(L, ENUM_FAILED);
    check_text(L, "quality", L"partial");
    lua_getfield(L, -1, "usb");
    check_number(L, "total", 1);
    collect(L, ID_FAILED);
    check_text(L, "quality", L"partial");
    lua_getfield(L, -1, "usb");
    check_number(L, "total", 3);
    lua_getfield(L, -1, "devices");
    assert(lua_rawlen(L, -1) == 2);
    collect(L, DUPLICATE);
    check_text(L, "quality", L"partial");
    get_device(L, "usb", 2);
    check_absent(L, "parent_id");
    collect(L, NO_HARDWARE_IDS);
    check_absent(L, "quality");
    get_device(L, "pci", 1);
    check_absent(L, "device_id");
    lua_pop(L, 1);
    get_device(L, "usb", 3);
    check_text(L, "parent_id", usb_instance);
    inventory_cm.parent = NULL;
    collect(L, 0);
    check_text(L, "quality", L"partial");
    get_device(L, "usb", 1);
    check_text(L, "id", devices[2].instance);
    check_absent(L, "parent_id");
    lua_close(L);
    puts("Windows inventory: UTF-8, IDs, PCI class/revision/driver, ancestry and hotplug checks passed");
    return 0;
}
