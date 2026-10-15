/* macOS read-only temperature services, SMC fans and power rails. Runtime
 * lookup keeps private HID interfaces optional on older systems. */
#include <lua.h>
#include <lauxlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wtop_macos.h"

#define MAX_HID_SENSORS 128
#define MAX_HID_SERVICES 4096
#define MAX_HID_EVENT_READS 256
#define HID_TEMPERATURE_EVENT 15

typedef struct __IOHIDEventSystemClient *hid_client;
typedef struct __IOHIDServiceClient *hid_service;
typedef struct __IOHIDEvent *hid_event;
typedef hid_client (*hid_create_function)(CFAllocatorRef);
typedef void (*hid_matching_function)(hid_client, CFDictionaryRef);
typedef CFArrayRef (*hid_services_function)(hid_client);
typedef CFTypeRef (*hid_property_function)(hid_service, CFStringRef);
typedef CFTypeRef (*hid_registry_function)(hid_service);
typedef hid_event (*hid_copy_event_function)(hid_service, uint32_t, hid_event, uint32_t);
typedef double (*hid_float_function)(hid_event, int32_t);

static struct {
    int state;
    hid_create_function create;
    hid_matching_function set_matching;
    hid_services_function copy_services;
    hid_property_function property;
    hid_registry_function registry_id;
    hid_copy_event_function copy_event;
    hid_float_function float_value;
} hid;

typedef struct {
    char device[96], label[256];
    uint64_t registry_id;
    double celsius;
    int ordinal, ambiguous;
} hid_reading;
typedef struct {
    hid_reading readings[MAX_HID_SENSORS];
    uint64_t seen[MAX_HID_SERVICES];
    int count, partial, truncated;
} hid_snapshot;

static void integer_field(lua_State *L, const char *key, lua_Integer value) {
    lua_pushinteger(L, value); lua_setfield(L, -2, key);
}
static void number_field(lua_State *L, const char *key, lua_Number value) {
    lua_pushnumber(L, value); lua_setfield(L, -2, key);
}
static void string_field(lua_State *L, const char *key, const char *value) {
    lua_pushstring(L, value); lua_setfield(L, -2, key);
}
static void boolean_field(lua_State *L, const char *key, int value) {
    lua_pushboolean(L, value); lua_setfield(L, -2, key);
}

static int hid_symbols(void) {
    if (hid.state) return hid.state > 0;
    hid.state = -1;
    hid.create = (hid_create_function)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    hid.set_matching = (hid_matching_function)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientSetMatching");
    hid.copy_services = (hid_services_function)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
    hid.property = (hid_property_function)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
    hid.registry_id = (hid_registry_function)dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetRegistryID");
    hid.copy_event = (hid_copy_event_function)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyEvent");
    hid.float_value = (hid_float_function)dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
    /* Registry identity is optional: older systems can still show readings,
     * but unidentified channels cannot carry statistics into another poll. */
    if (!hid.create || !hid.set_matching || !hid.copy_services || !hid.property
        || !hid.copy_event || !hid.float_value) return 0;
    hid.state = 1;
    return 1;
}

static int hid_product(hid_service service, char *output, size_t capacity) {
    CFTypeRef product = hid.property(service, CFSTR("Product"));
    int valid = 0;
    if (product && CFGetTypeID(product) == CFStringGetTypeID()) {
        CFIndex length = CFStringGetLength((CFStringRef)product), used = 0;
        CFIndex converted = CFStringGetBytes((CFStringRef)product, CFRangeMake(0, length),
            kCFStringEncodingUTF8, 0, false, (UInt8 *)output, (CFIndex)capacity - 1, &used);
        if (length > 0 && converted == length && used > 0 && used < (CFIndex)capacity
            && !memchr(output, 0, (size_t)used)) {
            output[used] = 0;
            valid = 1;
        }
    }
    if (product) CFRelease(product);
    return valid;
}

static uint64_t hid_registry(hid_service service) {
    if (!hid.registry_id) return 0;
    /* GetRegistryID returns a borrowed CF object, not a uint64_t. */
    CFTypeRef number = hid.registry_id(service);
    int64_t value = 0;
    if (!number || CFGetTypeID(number) != CFNumberGetTypeID()
        || CFNumberIsFloatType((CFNumberRef)number)
        || !CFNumberGetValue((CFNumberRef)number, kCFNumberSInt64Type, &value)) return 0;
    return (uint64_t)value;
}

static int hid_current(uint64_t id) {
    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(id);
    if (!matching) return 0;
    /* The matching call consumes the dictionary even when the service is gone. */
    io_service_t entry = IOServiceGetMatchingService(MACH_PORT_NULL, matching);
    if (!entry) return 0;
    uint64_t current = 0;
    int valid = IORegistryEntryInPlane(entry, kIOServicePlane)
        && IORegistryEntryGetRegistryEntryID(entry, &current) == KERN_SUCCESS && current == id;
    IOObjectRelease(entry);
    return valid;
}

static void hid_read(hid_snapshot *snapshot) {
    hid_client client = NULL;
    CFArrayRef services = NULL;
    CFNumberRef page_number = NULL, usage_number = NULL;
    CFDictionaryRef matching = NULL;
    int page = 0xff00, usage = 5, event_reads = 0;
    if (!hid_symbols()) return;
    /* A new client observes hotplug without requiring a CFRunLoop or cached
     * service callbacks. Failed creation/enumeration is retried next poll. */
    client = hid.create(kCFAllocatorDefault);
    if (!client) { snapshot->partial = 1; goto done; }
    page_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    usage_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    if (!page_number || !usage_number) { snapshot->partial = 1; goto done; }
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {page_number, usage_number};
    matching = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!matching) { snapshot->partial = 1; goto done; }
    hid.set_matching(client, matching);
    services = hid.copy_services(client);
    if (!services || CFGetTypeID(services) != CFArrayGetTypeID()) {
        snapshot->partial = 1; goto done;
    }
    CFIndex count = CFArrayGetCount(services);
    if (count > MAX_HID_SERVICES) {
        count = MAX_HID_SERVICES; snapshot->truncated = snapshot->partial = 1;
    }
    for (CFIndex index = 0; index < count; ++index) {
        hid_service service = (hid_service)CFArrayGetValueAtIndex(services, index);
        char name[256], after_name[256];
        uint64_t id = hid_registry(service);
        snapshot->seen[index] = id;
        int duplicate = 0;
        if (id) for (CFIndex prior = 0; prior < index; ++prior)
            if (snapshot->seen[prior] == id) { duplicate = 1; break; }
        if (duplicate) {
            snapshot->partial = 1;
            for (int row = 0; row < snapshot->count; ++row)
                if (snapshot->readings[row].registry_id == id)
                    snapshot->readings[row].ambiguous = 1;
            continue;
        }
        if (!hid_product(service, name, sizeof(name))) { snapshot->partial = 1; continue; }
        /* Calibration constants are not direct observations. */
        if (strstr(name, "tcal")) continue;
        if (snapshot->count == MAX_HID_SENSORS || event_reads == MAX_HID_EVENT_READS) {
            snapshot->truncated = snapshot->partial = 1; continue;
        }
        ++event_reads;
        hid_event event = hid.copy_event(service, HID_TEMPERATURE_EVENT, NULL, 0);
        if (!event) { snapshot->partial = 1; continue; }
        double value = hid.float_value(event, HID_TEMPERATURE_EVENT << 16);
        CFRelease(event);
        if (!(value > -40 && value < 150) || hid_registry(service) != id
            || (id && !hid_current(id))
            || !hid_product(service, after_name, sizeof(after_name))
            || strcmp(name, after_name)) { snapshot->partial = 1; continue; }
        hid_reading *row = &snapshot->readings[snapshot->count];
        char *space = strchr(name, ' ');
        const char *label = space ? space + 1 : name;
        size_t device_length = space ? (size_t)(space - name) : 3;
        if (!*label || !device_length || device_length >= sizeof(row->device)) {
            snapshot->partial = 1; continue;
        }
        memcpy(row->device, space ? name : "HID", device_length);
        row->device[device_length] = 0;
        memcpy(row->label, label, strlen(label) + 1);
        row->celsius = value;
        row->registry_id = id;
        row->ordinal = (int)index + 1;
        if (!id) snapshot->partial = 1;
        ++snapshot->count;
    }
done:
    if (services) CFRelease(services);
    if (matching) CFRelease(matching);
    if (page_number) CFRelease(page_number);
    if (usage_number) CFRelease(usage_number);
    if (client) CFRelease(client);
}

static int natural_compare(const char *a, const char *b) {
    while (*a && *b) {
        if (*a >= '0' && *a <= '9' && *b >= '0' && *b <= '9') {
            const char *a_end = a, *b_end = b, *a_number = a, *b_number = b;
            while (*a_end >= '0' && *a_end <= '9') ++a_end;
            while (*b_end >= '0' && *b_end <= '9') ++b_end;
            while (a_number < a_end && *a_number == '0') ++a_number;
            while (b_number < b_end && *b_number == '0') ++b_number;
            size_t alen = (size_t)(a_end - a_number), blen = (size_t)(b_end - b_number);
            if (alen != blen) return alen < blen ? -1 : 1;
            int order = memcmp(a_number, b_number, alen);
            if (order) return order;
            if (a_end - a != b_end - b) return a_end - a < b_end - b ? -1 : 1;
            a = a_end; b = b_end;
        } else {
            if ((unsigned char)*a != (unsigned char)*b)
                return (unsigned char)*a < (unsigned char)*b ? -1 : 1;
            ++a; ++b;
        }
    }
    return (*a != 0) - (*b != 0);
}
static int reading_compare(const void *left, const void *right) {
    const hid_reading *a = left, *b = right;
    int order = strcmp(a->device, b->device);
    if (!order) order = natural_compare(a->label, b->label);
    if (!order && a->registry_id != b->registry_id)
        order = a->registry_id < b->registry_id ? -1 : 1;
    if (!order) order = (a->ordinal > b->ordinal) - (a->ordinal < b->ordinal);
    return order;
}

static void push_channel(lua_State *L, int index, const char *type,
    const char *unit, const char *label, double value) {
    char id[32];
    lua_createtable(L, 0, 8);
    snprintf(id, sizeof(id), "%s%d", type, index);
    string_field(L, "id", id);
    string_field(L, "type", type);
    integer_field(L, "index", index);
    string_field(L, "unit", unit);
    string_field(L, "label", label);
    number_field(L, "input", value);
    string_field(L, "quality", "fresh");
}

int wtop_collect_hwmon(lua_State *L) {
    /* Allocate before acquiring any CF resources; all resources are released
     * before building Lua tables, including if Lua later runs out of memory. */
    hid_snapshot *snapshot = lua_newuserdatauv(L, sizeof(*snapshot), 0);
    memset(snapshot, 0, sizeof(*snapshot));
    hid_read(snapshot);
    qsort(snapshot->readings, (size_t)snapshot->count, sizeof(snapshot->readings[0]), reading_compare);
    wtop_smc_begin();
    int device_output = 1;
    double fans = 0;
    lua_createtable(L, 0, 4);
    lua_createtable(L, 4, 0);
    for (int index = 0; index < snapshot->count; ) {
        int stop = index, channel = 1;
        char device_id[104];
        while (stop < snapshot->count
            && !strcmp(snapshot->readings[stop].device, snapshot->readings[index].device)) ++stop;
        lua_createtable(L, 0, 7);
        snprintf(device_id, sizeof(device_id), "hid:%s", snapshot->readings[index].device);
        string_field(L, "id", device_id);
        string_field(L, "class", device_id);
        string_field(L, "name", snapshot->readings[index].device);
        string_field(L, "identity_quality", "fresh");
        string_field(L, "quality", "fresh");
        string_field(L, "source", "iohid");
        lua_createtable(L, stop - index, 0);
        for (int reading = index; reading < stop; ++reading) {
            const hid_reading *row = &snapshot->readings[reading];
            char id[48];
            if (row->ambiguous) continue;
            push_channel(L, channel, "temperature", "celsius", row->label, row->celsius);
            if (row->registry_id) {
                snprintf(id, sizeof(id), "ioreg:%llu", (unsigned long long)row->registry_id);
                string_field(L, "id", id);
                string_field(L, "input_source", id);
                string_field(L, "_source_instance", id);
            } else {
                snprintf(id, sizeof(id), "unresolved:%d", row->ordinal);
                string_field(L, "id", id);
            }
            string_field(L, "identity_quality", row->registry_id && !snapshot->truncated ? "fresh" : "partial");
            lua_rawseti(L, -2, channel++);
        }
        lua_setfield(L, -2, "channels");
        if (channel > 1) lua_rawseti(L, -2, device_output++);
        else lua_pop(L, 1);
        index = stop;
    }
    {
        static const struct {
            const char *key, *type, *unit, *label;
        } rails[] = {
            {"PSTR", "power", "watts", "System total"},
            {"PDTR", "power", "watts", "DC input"},
            {"VD0R", "voltage", "volts", "DC input"},
            {"ID0R", "current", "amperes", "DC input"},
        };
        static const char *const temperatures[] = {
            "TC0D", "TC0P", "TC1D", "TC1P", "TG0D", "TG0P",
            "TG1D", "TG1P", "TA0P", "TA1P", "TB0T", "TB1T",
        };
        int channel = 1, fan_index = 1;
        double value;
        lua_createtable(L, 0, 7);
        string_field(L, "id", "smc");
        string_field(L, "class", "smc");
        string_field(L, "name", "SMC");
        string_field(L, "identity_quality", "fresh");
        string_field(L, "quality", "fresh");
        string_field(L, "source", "smc");
        lua_createtable(L, 8, 0);
        if (wtop_smc_number("FNum", &fans) && fans >= 0 && fans <= 8 && fans == (int)fans) {
            for (int fan = 0; fan < (int)fans && fan < 8; ++fan) {
                char key[8], label[16];
                double minimum, maximum;
                snprintf(key, sizeof(key), "F%dAc", fan);
                if (!wtop_smc_number(key, &value)) continue;
                snprintf(label, sizeof(label), "Fan %d", fan + 1);
                push_channel(L, fan_index++, "fan", "rpm", label, value);
                string_field(L, "id", key);
                string_field(L, "input_source", key);
                lua_createtable(L, 0, 2);
                snprintf(key, sizeof(key), "F%dMn", fan);
                if (wtop_smc_number(key, &minimum)) number_field(L, "min", minimum);
                snprintf(key, sizeof(key), "F%dMx", fan);
                if (wtop_smc_number(key, &maximum)) number_field(L, "max", maximum);
                lua_setfield(L, -2, "thresholds");
                lua_rawseti(L, -2, channel++);
            }
        }
        for (size_t rail = 0; rail < sizeof(rails) / sizeof(rails[0]); ++rail) {
            if (!wtop_smc_number(rails[rail].key, &value)) continue;
            push_channel(L, channel, rails[rail].type, rails[rail].unit,
                rails[rail].label, value);
            string_field(L, "id", rails[rail].key);
            string_field(L, "input_source", rails[rail].key);
            lua_rawseti(L, -2, channel++);
        }
        for (size_t sensor = 0; sensor < sizeof(temperatures) / sizeof(temperatures[0]); ++sensor) {
            const char *key = temperatures[sensor];
            if (!wtop_smc_number(key, &value) || !(value > -40 && value < 150)) continue;
            /* Key meanings can vary by Mac model. Keep the actual key as the
             * label and source instead of declaring a CPU/GPU owner by name. */
            push_channel(L, channel, "temperature", "celsius", key, value);
            string_field(L, "id", key);
            string_field(L, "input_source", key);
            lua_rawseti(L, -2, channel++);
        }
        lua_setfield(L, -2, "channels");
        if (channel > 1) {
            char epoch[48];
            snprintf(epoch, sizeof(epoch), "smc:%llu", (unsigned long long)wtop_smc_epoch());
            string_field(L, "_source_epoch", epoch);
            lua_rawseti(L, -2, device_output++);
        }
        else lua_pop(L, 1);
    }
    lua_setfield(L, -2, "devices");
    if (device_output == 1) {
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "no_sensors");
        return 2;
    }
    boolean_field(L, "truncated", snapshot->truncated);
    boolean_field(L, "partial", snapshot->partial);
    string_field(L, "quality", snapshot->partial ? "partial" : "fresh");
    return 1;
}
