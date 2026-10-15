/* Exercise real HID enumeration and Lua conversion using owned CF fixtures. */
#include <lua.h>
#include <lauxlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { CREATE_FAILED=1, SERVICES_FAILED=2, WRONG_SERVICES=4, EVENT_FAILED=8,
    ID_CHANGED=16, NAME_CHANGED=32, MISSING_REGISTRY=64, MISSING_SYMBOL=128,
    NUMBER_FAILED=256, MATCHING_FAILED=512, DETACHED=1024, CURRENT_ID_CHANGED=2048 };
static unsigned mode, creates, lists, events, id_calls[4200], name_calls[4200];
static unsigned number_calls, service_count;
static int oom_enabled, fail_allocation;
static double observed_value = 40;
static CFDictionaryRef services[4200];
static CFNumberRef alternate_id;
static CFTypeRef client_object, owned[16384];
static unsigned owned_count;
static unsigned registry_references;
static uint64_t current_id;
static CFTypeRef own(CFTypeRef value) { if (value) { assert(owned_count < 16384); owned[owned_count++] = value; } return value; }
static void release(CFTypeRef value) {
    unsigned i;
    for (i = 0; i < owned_count; ++i) if (owned[i] == value) { owned[i] = owned[--owned_count]; break; }
    int client = value == client_object;
    CFRelease(value);
    if (client) { client_object = NULL; assert(owned_count == 0); if (oom_enabled) fail_allocation = 1; }
}
static unsigned service_index(CFTypeRef service) {
    int index = -1;
    assert(CFNumberGetValue(CFDictionaryGetValue(service, CFSTR("index")), kCFNumberIntType, &index));
    assert(index >= 0 && index < 4200); return (unsigned)index;
}
static void *fixture_create(CFAllocatorRef allocator) {
    (void)allocator; ++creates;
    if (mode & CREATE_FAILED) return NULL;
    client_object = own(CFStringCreateWithCString(NULL, "client", kCFStringEncodingUTF8));
    return (void *)client_object;
}
static void fixture_matching(void *client, CFDictionaryRef matching) {
    assert(client == client_object);
    int page = 0, usage = 0;
    assert(CFNumberGetValue(CFDictionaryGetValue(matching, CFSTR("PrimaryUsagePage")), kCFNumberIntType, &page));
    assert(CFNumberGetValue(CFDictionaryGetValue(matching, CFSTR("PrimaryUsage")), kCFNumberIntType, &usage));
    assert(page == 0xff00 && usage == 5);
}
static CFArrayRef fixture_services(void *client) {
    assert(client == client_object); ++lists;
    if (mode & SERVICES_FAILED) return NULL;
    if (mode & WRONG_SERVICES) return (CFArrayRef)own(CFStringCreateWithCString(NULL, "invalid", kCFStringEncodingUTF8));
    return (CFArrayRef)own(CFArrayCreate(NULL, (const void **)services, service_count, &kCFTypeArrayCallBacks));
}
static CFTypeRef fixture_property(void *service, CFStringRef key) {
    assert(CFEqual(key, CFSTR("Product")));
    unsigned index = service_index(service); ++name_calls[index];
    CFTypeRef name = (mode & NAME_CHANGED) && index == 0 && name_calls[0] > 1
        ? CFSTR("Thermal Replacement") : CFDictionaryGetValue(service, key);
    return name ? own(CFRetain(name)) : NULL;
}
static CFTypeRef fixture_registry(void *service) {
    unsigned index = service_index(service); ++id_calls[index];
    return (mode & ID_CHANGED) && index == 0 && id_calls[0] > 1
        ? alternate_id : CFDictionaryGetValue(service, CFSTR("id"));
}
static void *fixture_event(void *service, uint32_t type, void *matching, uint32_t options) {
    assert(type == 15 && !matching && options == 0); ++events;
    if ((mode & EVENT_FAILED) && service_index(service) == 0) return NULL;
    return (void *)own(CFNumberCreate(NULL, kCFNumberDoubleType, &observed_value));
}
static double fixture_float(void *event, int32_t field) {
    assert(field == 15 << 16); double value; assert(CFNumberGetValue(event, kCFNumberDoubleType, &value)); return value;
}
static void *fixture_dlsym(void *handle, const char *name) {
    assert(handle == RTLD_DEFAULT);
    if ((mode & MISSING_SYMBOL) && !strcmp(name, "IOHIDEventSystemClientCreate")) return NULL;
    if ((mode & MISSING_REGISTRY) && !strcmp(name, "IOHIDServiceClientGetRegistryID")) return NULL;
    if (!strcmp(name, "IOHIDEventSystemClientCreate")) return (void *)fixture_create;
    if (!strcmp(name, "IOHIDEventSystemClientSetMatching")) return (void *)fixture_matching;
    if (!strcmp(name, "IOHIDEventSystemClientCopyServices")) return (void *)fixture_services;
    if (!strcmp(name, "IOHIDServiceClientCopyProperty")) return (void *)fixture_property;
    if (!strcmp(name, "IOHIDServiceClientGetRegistryID")) return (void *)fixture_registry;
    if (!strcmp(name, "IOHIDServiceClientCopyEvent")) return (void *)fixture_event;
    if (!strcmp(name, "IOHIDEventGetFloatValue")) return (void *)fixture_float;
    assert(0); return NULL;
}
static CFNumberRef fixture_number(CFAllocatorRef allocator, CFNumberType type, const void *value) {
    ++number_calls;
    if ((mode & NUMBER_FAILED) && number_calls == 2) return NULL;
    return CFNumberCreate(allocator, type, value);
}
static CFDictionaryRef fixture_dictionary(CFAllocatorRef allocator, const void **keys,
    const void **values, CFIndex count, const CFDictionaryKeyCallBacks *k, const CFDictionaryValueCallBacks *v) {
    if (mode & MATCHING_FAILED) return NULL;
    return CFDictionaryCreate(allocator, keys, values, count, k, v);
}
static CFMutableDictionaryRef fixture_entry_matching(uint64_t id) {
    current_id = id;
    return (CFMutableDictionaryRef)own(CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
}
static io_service_t fixture_entry(mach_port_t port, CFDictionaryRef matching) {
    (void)port; release(matching);
    if ((mode & DETACHED) && current_id == 1001) return 0;
    ++registry_references; return 1;
}
static boolean_t fixture_plane(io_registry_entry_t entry, const io_name_t plane) {
    assert(entry == 1 && registry_references == 1 && !strcmp(plane, kIOServicePlane)); return 1;
}
static kern_return_t fixture_entry_id(io_registry_entry_t entry, uint64_t *id) {
    assert(entry == 1 && registry_references == 1);
    *id = current_id + ((mode & CURRENT_ID_CHANGED) && current_id == 1001); return KERN_SUCCESS;
}
static kern_return_t fixture_entry_release(io_object_t entry) {
    assert(entry == 1 && registry_references == 1); --registry_references; return KERN_SUCCESS;
}
#define dlsym fixture_dlsym
#define CFRelease release
#define CFNumberCreate fixture_number
#define CFDictionaryCreate fixture_dictionary
#define IORegistryEntryIDMatching fixture_entry_matching
#define IOServiceGetMatchingService fixture_entry
#define IORegistryEntryInPlane fixture_plane
#define IORegistryEntryGetRegistryEntryID fixture_entry_id
#define IOObjectRelease fixture_entry_release
#include "../../native/wtop_macos_sensors.c"
#undef CFRelease
#undef CFNumberCreate
#undef CFDictionaryCreate
void wtop_smc_begin(void) {}
uint64_t wtop_smc_epoch(void) { return 1; }
int wtop_smc_number(const char *key, double *value) { (void)key; (void)value; return 0; }

static void set_services(unsigned count) {
    for (unsigned i = 0; i < service_count; ++i) CFRelease(services[i]);
    service_count = count;
    for (unsigned i = 0; i < count; ++i) {
        int index = (int)i; int64_t id = 1001+i;
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &id), x = CFNumberCreate(NULL, kCFNumberIntType, &index);
        const void *keys[] = { CFSTR("id"), CFSTR("index"), CFSTR("Product") };
        const void *values[] = { n, x, CFSTR("Thermal Board") };
        services[i] = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(n); CFRelease(x);
    }
}
static void property(unsigned index, CFStringRef key, CFTypeRef value) {
    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(NULL, 0, services[index]);
    if (value) CFDictionarySetValue(copy, key, value); else CFDictionaryRemoveValue(copy, key);
    CFRelease(services[index]); services[index] = copy;
}
static int poll(lua_State *L, unsigned flags, int reset_symbols) {
    mode = flags; number_calls = 0; memset(id_calls, 0, sizeof(id_calls)); memset(name_calls, 0, sizeof(name_calls));
    if (reset_symbols) memset(&hid, 0, sizeof(hid));
    lua_settop(L, 0); lua_pushcfunction(L, wtop_collect_hwmon);
    assert(lua_pcall(L, 0, LUA_MULTRET, 0) == LUA_OK); assert(!owned_count && !client_object && !registry_references);
    return lua_istable(L, 1);
}
static int collect(lua_State *L, unsigned flags) { return poll(L, flags, 1); }
static int boolean(lua_State *L, int table, const char *field) {
    lua_getfield(L, table, field); int result = lua_toboolean(L, -1); lua_pop(L, 1); return result;
}
static unsigned channels(lua_State *L) {
    lua_getfield(L, 1, "devices"); assert(lua_rawlen(L, -1) == 1);
    lua_rawgeti(L, -1, 1); lua_getfield(L, -1, "channels"); return (unsigned)lua_rawlen(L, -1);
}
static void expect_text(lua_State *L, const char *field, const char *text) {
    lua_getfield(L, -1, field); assert(lua_isstring(L, -1) && !strcmp(lua_tostring(L, -1), text)); lua_pop(L, 1);
}
static void *allocator(void *context, void *pointer, size_t old_size, size_t size) {
    (void)context; (void)old_size;
    if (!size) { free(pointer); return NULL; }
    return fail_allocation ? NULL : realloc(pointer, size);
}
int main(void) {
    int64_t changed = 99999; alternate_id = CFNumberCreate(NULL, kCFNumberSInt64Type, &changed);
    lua_State *L = luaL_newstate(); assert(L);
    set_services(2); assert(collect(L, 0)); assert(!boolean(L, 1, "partial") && channels(L) == 2);
    lua_rawgeti(L, -1, 1); expect_text(L, "id", "ioreg:1001"); expect_text(L, "label", "Board"); expect_text(L, "identity_quality", "fresh");
    CFIndex retain = CFGetRetainCount(CFDictionaryGetValue(services[0], CFSTR("id")));
    unsigned before = creates; assert(poll(L, 0, 0) && channels(L) == 2 && creates == before + 1);
    assert(CFGetRetainCount(CFDictionaryGetValue(services[0], CFSTR("id"))) == retain);
    CFDictionaryRef swap = services[0]; services[0] = services[1]; services[1] = swap;
    assert(poll(L, 0, 0) && channels(L) == 2); lua_rawgeti(L, -1, 1); expect_text(L, "id", "ioreg:1001");
    set_services(0); assert(!poll(L, 0, 0)); set_services(1); assert(poll(L, 0, 0) && channels(L) == 1);
    for (unsigned flags = CREATE_FAILED; flags <= WRONG_SERVICES; flags <<= 1) {
        assert(!collect(L, flags)); assert(poll(L, 0, 0));
    }
    assert(!collect(L, NUMBER_FAILED)); assert(!collect(L, MATCHING_FAILED)); assert(!collect(L, MISSING_SYMBOL));
    set_services(2);
    for (unsigned flags = EVENT_FAILED; flags <= NAME_CHANGED; flags <<= 1) {
        assert(collect(L, flags) && boolean(L, 1, "partial") && channels(L) == 1);
        lua_rawgeti(L, -1, 1); expect_text(L, "id", "ioreg:1002");
    }
    for (unsigned flags = DETACHED; flags <= CURRENT_ID_CHANGED; flags <<= 1) {
        assert(collect(L, flags) && boolean(L, 1, "partial") && channels(L) == 1);
        lua_rawgeti(L, -1, 1); expect_text(L, "id", "ioreg:1002");
    }
    assert(collect(L, MISSING_REGISTRY) && boolean(L, 1, "partial") && channels(L) == 2);
    lua_rawgeti(L, -1, 1); expect_text(L, "identity_quality", "partial"); expect_text(L, "id", "unresolved:1");
    property(1, CFSTR("id"), CFDictionaryGetValue(services[0], CFSTR("id")));
    assert(!collect(L, 0)); /* Both duplicated owners are quarantined. */
    set_services(2); property(0, CFSTR("id"), CFSTR("not a number"));
    assert(collect(L, 0) && channels(L) == 2); lua_rawgeti(L, -1, 1); expect_text(L, "identity_quality", "partial");
    set_services(1); int64_t high = -1; CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &high);
    property(0, CFSTR("id"), n); CFRelease(n); assert(collect(L, 0) && channels(L) == 1);
    lua_rawgeti(L, -1, 1); expect_text(L, "id", "ioreg:18446744073709551615");
    double fractional = 1001.5; n = CFNumberCreate(NULL, kCFNumberDoubleType, &fractional);
    property(0, CFSTR("id"), n); CFRelease(n); assert(collect(L, 0) && boolean(L, 1, "partial"));
    set_services(1);
    property(0, CFSTR("Product"), CFSTR("Thermal tcal1")); unsigned event_before = events; assert(!collect(L, 0) && events == event_before);
    property(0, CFSTR("Product"), CFSTR("Thermal 板温")); assert(collect(L, 0) && channels(L) == 1); lua_rawgeti(L, -1, 1); expect_text(L, "label", "板温");
    UniChar embedded[] = {'T', ' ', 'a', 0, 'b'}; CFStringRef text = CFStringCreateWithCharacters(NULL, embedded, 5);
    property(0, CFSTR("Product"), text); CFRelease(text); assert(!collect(L, 0));
    char long_name[400]; memset(long_name, 'a', sizeof(long_name)-1); long_name[399] = 0;
    text = CFStringCreateWithCString(NULL, long_name, kCFStringEncodingUTF8); property(0, CFSTR("Product"), text); CFRelease(text); assert(!collect(L, 0));
    long_name[110] = ' '; long_name[120] = 0; text = CFStringCreateWithCString(NULL, long_name, kCFStringEncodingUTF8);
    property(0, CFSTR("Product"), text); CFRelease(text); assert(!collect(L, 0));
    property(0, CFSTR("Product"), CFSTR("Thermal ")); assert(!collect(L, 0));
    property(0, CFSTR("Product"), NULL); assert(!collect(L, 0));
    set_services(1);
    const double invalid[] = {NAN, INFINITY, -INFINITY, -40, 150};
    for (unsigned i = 0; i < sizeof(invalid)/sizeof(invalid[0]); ++i) { observed_value = invalid[i]; assert(!collect(L, 0)); }
    observed_value = 0; assert(collect(L, 0)); observed_value = 40;
    set_services(128); assert(collect(L, 0) && !boolean(L, 1, "truncated") && channels(L) == 128);
    set_services(129); assert(collect(L, 0) && boolean(L, 1, "truncated") && channels(L) == 128);
    lua_rawgeti(L, -1, 1); expect_text(L, "identity_quality", "partial");
    set_services(4097); before = events; assert(collect(L, 0) && boolean(L, 1, "truncated") && events - before == 128);
    observed_value = NAN; before = events; assert(!collect(L, 0) && events - before == 256); observed_value = 40;
    set_services(129); property(128, CFSTR("id"), CFDictionaryGetValue(services[0], CFSTR("id")));
    assert(collect(L, 0) && boolean(L, 1, "partial") && channels(L) == 127);
    assert(natural_compare("tdie2", "tdie10") < 0 && natural_compare("tdie10", "tdie2") > 0);
    assert(natural_compare("a", "ab") < 0 && natural_compare("", "") == 0);
    assert(natural_compare("tdie2x", "tdie2y") < 0 && natural_compare("02", "2") > 0);
    lua_close(L);
    set_services(2); L = lua_newstate(allocator, NULL, 0); assert(L);
    mode = 0; memset(&hid, 0, sizeof(hid)); number_calls = 0;
    memset(id_calls, 0, sizeof(id_calls)); memset(name_calls, 0, sizeof(name_calls));
    lua_pushcfunction(L, wtop_collect_hwmon); oom_enabled = 1;
    assert(lua_pcall(L, 0, LUA_MULTRET, 0) == LUA_ERRMEM);
    assert(!owned_count && !client_object && !registry_references); fail_allocation = oom_enabled = 0; lua_close(L);
    set_services(0); CFRelease(alternate_id);
    puts("HID: refreshed services, stable IDs, hotplug/reordering/replacement, duplicate quarantine, borrowed IDs, UTF-8, bounds, failures, nonfinite values and Lua-OOM cleanup passed");
    return 0;
}
