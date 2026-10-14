/* Run the real collector against deterministic IOKit handles and real CF
 * properties. This never changes any host devices. */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { REPARENT = 1, MULTI_PARENT = 2, CYCLE = 4, REMOVED = 8,
    ID_CHANGED = 16, SHORT_PROPERTY = 32, ENUM_FAILED = 64,
    ENUM_INVALID = 128, DUPLICATE = 256, FLOOD = 512, LONG_CHAIN = 1024 };
static unsigned mode, references, next_calls, parent_calls[80], id_calls[80];
static int oom_enabled, fail_allocation;
static CFMutableDictionaryRef properties[10];
static const unsigned classes[10] = {0, 0, 1, 1, 0, 2, 2, 1, 2, 0};
static const unsigned parents[10] = {0, 0, 1, 2, 3, 4, 5, 1, 5, 0};
struct fixture_iterator { unsigned used, kind, cursor, count, objects[2]; };
static struct fixture_iterator iterators[16];

static io_object_t retain_object(unsigned object) {
    if (object) ++references;
    return object;
}
static io_iterator_t new_iterator(unsigned kind) {
    for (unsigned i = 0; i < 16; ++i) if (!iterators[i].used) {
        memset(&iterators[i], 0, sizeof(iterators[i]));
        iterators[i].used = 1; iterators[i].kind = kind;
        ++references; return 100 + i;
    }
    assert(0 && "fixture iterator overflow"); return 0;
}
static CFMutableDictionaryRef fixture_matching(const char *name) {
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, CFSTR("class"),
        !strcmp(name, "IOPCIDevice") ? CFSTR("pci") : CFSTR("usb"));
    return d;
}
static kern_return_t fixture_services(mach_port_t port, CFDictionaryRef matching,
    io_iterator_t *iterator) {
    (void)port;
    unsigned kind = CFEqual(CFDictionaryGetValue(matching, CFSTR("class")), CFSTR("pci")) ? 1 : 2;
    CFRelease(matching); *iterator = 0;
    if (mode & ENUM_FAILED) return KERN_FAILURE;
    *iterator = new_iterator(kind); return KERN_SUCCESS;
}
static io_object_t fixture_next(io_iterator_t iterator) {
    assert(iterator >= 100 && iterator < 116);
    struct fixture_iterator *it = &iterators[iterator - 100];
    assert(it->used); ++next_calls;
    if (it->kind == 3) {
        if (it->cursor >= it->count) return 0;
        return retain_object(it->objects[it->cursor++]);
    }
    if ((mode & FLOOD) && it->kind == 1) { ++it->cursor; return retain_object(2); }
    while (++it->cursor < 10) if (classes[it->cursor] == it->kind)
        return retain_object(it->cursor);
    return 0;
}
static boolean_t fixture_valid(io_iterator_t iterator) {
    return !((mode & ENUM_INVALID) && iterators[iterator - 100].kind == 1);
}
static kern_return_t fixture_release(io_object_t object) {
    assert(object && references); --references;
    if (object >= 100) {
        assert(iterators[object - 100].used);
        if (oom_enabled && iterators[object - 100].kind == 2) fail_allocation = 1;
        iterators[object - 100].used = 0;
    }
    return KERN_SUCCESS;
}
static kern_return_t fixture_parent_iterator(io_registry_entry_t entry,
    const io_name_t plane, io_iterator_t *iterator) {
    (void)plane; assert(entry > 0 && entry < 80);
    *iterator = new_iterator(3);
    struct fixture_iterator *it = &iterators[*iterator - 100];
    unsigned parent = entry < 10 ? parents[entry] : 0; ++parent_calls[entry];
    if (mode & LONG_CHAIN) {
        if (entry == 4) parent = 9;
        else if (entry >= 9) parent = entry < 79 ? entry + 1 : 1;
    }
    if ((mode & REPARENT) && entry == 4 && parent_calls[entry] > 1) parent = 7;
    if ((mode & CYCLE) && entry == 4) parent = 4;
    if (parent) { it->objects[0] = parent; it->count = 1; }
    if ((mode & MULTI_PARENT) && entry == 5) { it->objects[1] = 3; it->count = 2; }
    return KERN_SUCCESS;
}
static boolean_t fixture_in_plane(io_registry_entry_t entry, const io_name_t plane) {
    (void)plane;
    return entry != 1 && !((mode & REMOVED) && entry == 5);
}
static kern_return_t fixture_id(io_registry_entry_t entry, uint64_t *id) {
    assert(entry > 0 && entry < 80); ++id_calls[entry];
    *id = 1000 + entry;
    if (entry == 7) *id = (mode & DUPLICATE) ? 1002 : UINT64_MAX;
    if ((mode & ID_CHANGED) && entry == 5 && id_calls[entry] > 1) *id += 10000;
    return KERN_SUCCESS;
}
static boolean_t fixture_conforms(io_object_t object, const io_name_t name) {
    return object < 10 && classes[object] == (!strcmp(name, "IOPCIDevice") ? 1u : 2u);
}
static io_registry_entry_t fixture_root(mach_port_t port) { (void)port; return retain_object(1); }
static boolean_t fixture_equal(io_object_t a, io_object_t b) { return a == b; }
static kern_return_t fixture_name(io_registry_entry_t entry, io_name_t name) {
    snprintf(name, 128, "Device %u", entry); return KERN_SUCCESS;
}
static kern_return_t fixture_properties(io_registry_entry_t entry,
    CFMutableDictionaryRef *out, CFAllocatorRef allocator, IOOptionBits options) {
    (void)allocator; (void)options;
    *out = (CFMutableDictionaryRef)CFRetain(properties[entry]); return KERN_SUCCESS;
}

#define IOServiceMatching fixture_matching
#define IOServiceGetMatchingServices fixture_services
#define IOIteratorNext fixture_next
#define IOIteratorIsValid fixture_valid
#define IOObjectRelease fixture_release
#define IORegistryEntryGetParentIterator fixture_parent_iterator
#define IORegistryEntryInPlane fixture_in_plane
#define IORegistryEntryGetRegistryEntryID fixture_id
#define IOObjectConformsTo fixture_conforms
#define IORegistryGetRootEntry fixture_root
#define IOObjectIsEqualTo fixture_equal
#define IORegistryEntryGetName fixture_name
#define IORegistryEntryCreateCFProperties fixture_properties
#include "../../native/wtop_macos_inventory.c"

static void put_data(unsigned entry, CFStringRef key, uint32_t value, unsigned length) {
    UInt8 bytes[4] = {value, value >> 8, value >> 16, value >> 24};
    CFDataRef data = CFDataCreate(NULL, bytes, length);
    CFDictionarySetValue(properties[entry], key, data); CFRelease(data);
}
static void put_number(unsigned entry, CFStringRef key, int64_t value) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
    CFDictionarySetValue(properties[entry], key, number); CFRelease(number);
}
static void check(lua_State *L, unsigned flags, const char *assertions) {
    mode = flags; next_calls = 0;
    memset(parent_calls, 0, sizeof(parent_calls)); memset(id_calls, 0, sizeof(id_calls));
    put_data(2, CFSTR("vendor-id"), 0x106b, flags & SHORT_PROPERTY ? 3 : 4);
    lua_pushcfunction(L, wtop_collect_inventory);
    int status = lua_pcall(L, 0, 1, 0);
    if (status != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    assert(status == LUA_OK && references == 0);
    lua_setglobal(L, "data");
    status = luaL_dostring(L, assertions);
    if (status != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    assert(status == LUA_OK);
    for (unsigned i = 1; i < 10; ++i) assert(CFGetRetainCount(properties[i]) == 1);
}
struct allocator_context { lua_Alloc original; void *context; };
static void *failing_allocator(void *context, void *pointer, size_t old, size_t size) {
    struct allocator_context *a = context;
    if (size && fail_allocation) { assert(references == 0); return NULL; }
    return a->original(a->context, pointer, old, size);
}
int main(void) {
    for (unsigned i = 1; i < 10; ++i) {
        properties[i] = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (classes[i] == 1) {
            put_data(i, CFSTR("vendor-id"), 0x106b, 4);
            put_data(i, CFSTR("device-id"), 0, 4);
            put_data(i, CFSTR("class-code"), 0, 4);
            put_data(i, CFSTR("revision-id"), 0, 4);
            put_data(i, CFSTR("reg"), i == 3 ? 0x0aff00 : 0, 4);
            static const UInt8 model[] = "中文控制器";
            CFDataRef text = CFDataCreate(NULL, model, sizeof(model));
            CFDictionarySetValue(properties[i], CFSTR("model"), text); CFRelease(text);
        } else if (classes[i] == 2) {
            put_number(i, CFSTR("idVendor"), 0x1234);
            put_number(i, CFSTR("idProduct"), 0);
            if (i != 8) put_number(i, CFSTR("locationID"), 0);
            CFDictionarySetValue(properties[i], CFSTR("USB Product String"), CFSTR("中文设备"));
        }
    }
    lua_State *L = luaL_newstate(); assert(L); luaL_openlibs(L);
    check(L, 0, "assert(data.quality==nil and #data.pci.devices==3 and #data.usb.devices==3); "
        "assert(data.pci.devices[1].address=='ioreg:1002' and data.pci.devices[1].device_id==0 and data.pci.devices[1].revision==0 and data.pci.devices[1].class_id==0); "
        "assert(data.pci.devices[1].device_name=='中文控制器'); "
        "assert(data.pci.devices[2].address=='0a:1f.7' and data.pci.devices[2]._registry_parent_id=='ioreg:1002'); "
        "assert(data.pci.devices[3].address=='ioreg:18446744073709551615'); "
        "assert(data.usb.devices[1].id=='ioreg:1005' and data.usb.devices[1]._registry_parent_id=='ioreg:1003' and data.usb.devices[1]._registry_parent_bus=='pci'); "
        "assert(data.usb.devices[2].id=='ioreg:1006' and data.usb.devices[2]._registry_parent_bus=='usb' and data.usb.devices[3].id=='ioreg:1008'); "
        "assert(data.usb.devices[1].product=='中文设备')");
    for (unsigned flag = REPARENT; flag <= CYCLE; flag <<= 1)
        check(L, flag, "assert(data.quality=='partial' and data.usb.devices[1]._registry_parent_id==nil)");
    check(L, REMOVED, "assert(data.quality=='partial' and #data.usb.devices==2 and data.usb.total==3)");
    check(L, ID_CHANGED, "assert(data.quality=='partial' and #data.usb.devices==2)");
    check(L, SHORT_PROPERTY, "assert(data.quality=='partial' and data.pci.devices[1].vendor_id==nil and data.pci.devices[1].device_id==0)");
    check(L, ENUM_FAILED, "assert(data.quality=='partial' and #data.pci.devices==0 and #data.usb.devices==0)");
    check(L, ENUM_INVALID, "assert(data.quality=='partial' and data.pci.devices[2]._registry_parent_id==nil)");
    check(L, DUPLICATE, "assert(data.quality=='partial' and data.pci.devices[1].address==data.pci.devices[3].address)");
    check(L, FLOOD, "assert(data.quality=='partial' and #data.pci.devices==256 and data.pci.total==4097 and data.pci.truncated)");
    assert(next_calls < 10000);
    check(L, LONG_CHAIN, "assert(data.quality=='partial' and data.usb.devices[1]._registry_parent_id==nil)");
    assert(next_calls < 1000);
    mode = 0; memset(parent_calls, 0, sizeof(parent_calls)); memset(id_calls, 0, sizeof(id_calls));
    struct allocator_context allocator;
    allocator.original = lua_getallocf(L, &allocator.context);
    lua_setallocf(L, failing_allocator, &allocator);
    lua_pushcfunction(L, wtop_collect_inventory); oom_enabled = 1;
    int status = lua_pcall(L, 0, 1, 0);
    fail_allocation = oom_enabled = 0;
    assert(status == LUA_ERRMEM && references == 0);
    lua_setallocf(L, allocator.original, allocator.context);
    lua_close(L);
    for (unsigned i = 1; i < 10; ++i) {
        assert(CFGetRetainCount(properties[i]) == 1); CFRelease(properties[i]);
    }
    puts("macOS inventory: zero/duplicate addresses, hex BDF, zero IDs/revision, ancestors, roots, reparenting, cycles, ambiguity, detachment, bounds, Unicode and OOM cleanup passed");
    return 0;
}
