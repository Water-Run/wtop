/* macOS hardware sources: GPU, sensors, energy, CPU frequency, batteries,
 * sockets, and application groups. IOReport, IOHID events, the SMC, and the
 * process coalition query are private interfaces with no SDK header; each
 * is resolved at run time, and a missing one reports its source as
 * unavailable rather than failing the module load. */
#define _DARWIN_C_SOURCE

#include <lua.h>
#include <lauxlib.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#include "wtop_macos.h"

#define MAX_PIDS 8192
#define MAX_SOCKETS 16384
#define MAX_FDS_PER_PROCESS 4096
#define MAX_HID_SENSORS 128
#define MAX_CLUSTERS 8
#define MAX_TABLE_STATES 64
#define MAX_COALITIONS 4096

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

static int cf_text(CFTypeRef value, char *output, size_t size) {
    output[0] = 0;
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return 0;
    return CFStringGetCString((CFStringRef)value, output, (CFIndex)size,
        kCFStringEncodingUTF8) && output[0];
}

static int cf_int64(CFTypeRef value, int64_t *output) {
    return value && CFGetTypeID(value) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, output);
}

static int cf_double(CFTypeRef value, double *output) {
    return value && CFGetTypeID(value) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, output);
}

static int cf_bool(CFTypeRef value, int *output) {
    if (!value || CFGetTypeID(value) != CFBooleanGetTypeID()) return 0;
    *output = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
    return 1;
}

static int64_t sysctl_int64(const char *name, int64_t fallback) {
    int64_t value = 0;
    size_t length = sizeof(value);
    if (sysctlbyname(name, &value, &length, NULL, 0) != 0 || length == 0)
        return fallback;
    if (length == sizeof(int32_t)) {
        int32_t narrow;
        memcpy(&narrow, &value, sizeof(narrow));
        return narrow;
    }
    return value;
}

/* Task CPU times are Mach absolute time on Apple silicon and nanoseconds on
 * Intel; the timebase converts either to nanoseconds. */
uint64_t wtop_mach_to_ns(uint64_t value) {
    static mach_timebase_info_data_t timebase = {0, 0};
    if (timebase.denom == 0 && mach_timebase_info(&timebase) != KERN_SUCCESS) {
        timebase.numer = 1;
        timebase.denom = 1;
    }
    if (timebase.numer == timebase.denom) return value;
    return (uint64_t)((long double)value * timebase.numer / timebase.denom);
}

/* ------------------------------------------------------------------------
 * IOReport */

typedef struct IOReportSubscription *ioreport_subscription;
typedef CFDictionaryRef (*ioreport_copy_group_function)(CFStringRef, CFStringRef,
    uint64_t, uint64_t, uint64_t);
typedef void (*ioreport_merge_function)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef ioreport_subscription (*ioreport_subscribe_function)(void *,
    CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*ioreport_samples_function)(ioreport_subscription,
    CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*ioreport_delta_function)(CFDictionaryRef,
    CFDictionaryRef, CFTypeRef);
typedef int64_t (*ioreport_integer_function)(CFDictionaryRef, int32_t);
typedef CFStringRef (*ioreport_text_function)(CFDictionaryRef);
typedef int32_t (*ioreport_count_function)(CFDictionaryRef);
typedef CFStringRef (*ioreport_state_name_function)(CFDictionaryRef, int32_t);
typedef int64_t (*ioreport_residency_function)(CFDictionaryRef, int32_t);

static struct {
    int resolved;
    ioreport_copy_group_function copy_group;
    ioreport_merge_function merge;
    ioreport_subscribe_function subscribe;
    ioreport_samples_function samples;
    ioreport_delta_function delta;
    ioreport_integer_function integer;
    ioreport_text_function name;
    ioreport_text_function unit;
    ioreport_count_function state_count;
    ioreport_state_name_function state_name;
    ioreport_residency_function residency;
} ioreport;

static int ioreport_ready(void) {
    if (!ioreport.resolved) {
        void *library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL);
        ioreport.resolved = 1;
        if (library) {
            ioreport.copy_group = (ioreport_copy_group_function)dlsym(library,
                "IOReportCopyChannelsInGroup");
            ioreport.merge = (ioreport_merge_function)dlsym(library,
                "IOReportMergeChannels");
            ioreport.subscribe = (ioreport_subscribe_function)dlsym(library,
                "IOReportCreateSubscription");
            ioreport.samples = (ioreport_samples_function)dlsym(library,
                "IOReportCreateSamples");
            ioreport.delta = (ioreport_delta_function)dlsym(library,
                "IOReportCreateSamplesDelta");
            ioreport.integer = (ioreport_integer_function)dlsym(library,
                "IOReportSimpleGetIntegerValue");
            ioreport.name = (ioreport_text_function)dlsym(library,
                "IOReportChannelGetChannelName");
            ioreport.unit = (ioreport_text_function)dlsym(library,
                "IOReportChannelGetUnitLabel");
            ioreport.state_count = (ioreport_count_function)dlsym(library,
                "IOReportStateGetCount");
            ioreport.state_name = (ioreport_state_name_function)dlsym(library,
                "IOReportStateGetNameForIndex");
            ioreport.residency = (ioreport_residency_function)dlsym(library,
                "IOReportStateGetResidency");
        }
    }
    return ioreport.copy_group && ioreport.merge && ioreport.subscribe
        && ioreport.samples && ioreport.delta && ioreport.integer
        && ioreport.name && ioreport.unit && ioreport.state_count
        && ioreport.state_name && ioreport.residency;
}

typedef struct {
    int state; /* 0 untried, 1 open, -1 unavailable */
    ioreport_subscription subscription;
    CFMutableDictionaryRef channels;
    CFMutableDictionaryRef subscribed;
    CFDictionaryRef previous;
} ioreport_set;

static int ioreport_open(ioreport_set *set, CFStringRef group, CFStringRef subgroup) {
    CFDictionaryRef found;
    if (set->state) return set->state > 0;
    set->state = -1;
    if (!ioreport_ready()) return 0;
    found = ioreport.copy_group(group, subgroup, 0, 0, 0);
    if (!found) return 0;
    set->channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, found);
    CFRelease(found);
    if (!set->channels) return 0;
    set->subscription = ioreport.subscribe(NULL, set->channels, &set->subscribed, 0, NULL);
    if (!set->subscription || !set->subscribed) return 0;
    set->state = 1;
    return 1;
}

/* Returns the change since the previous call, or NULL on the first call. */
static CFArrayRef ioreport_changes(ioreport_set *set, CFDictionaryRef *owner) {
    CFDictionaryRef current = ioreport.samples(set->subscription, set->subscribed, NULL);
    CFDictionaryRef delta = NULL;
    CFTypeRef items;
    *owner = NULL;
    if (!current) return NULL;
    if (set->previous) {
        delta = ioreport.delta(set->previous, current, NULL);
        CFRelease(set->previous);
    }
    set->previous = current;
    if (!delta) return NULL;
    items = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (!items || CFGetTypeID(items) != CFArrayGetTypeID()) {
        CFRelease(delta);
        return NULL;
    }
    *owner = delta;
    return (CFArrayRef)items;
}

static double energy_scale(CFStringRef unit) {
    char text[16];
    if (!cf_text(unit, text, sizeof(text))) return 0;
    if (strcmp(text, "mJ") == 0) return 1e-3;
    if (strcmp(text, "uJ") == 0) return 1e-6;
    if (strcmp(text, "nJ") == 0) return 1e-9;
    return 0;
}

/* ------------------------------------------------------------------------
 * DVFS tables. The power manager's voltage-state properties list the
 * frequency of each performance state in order: kHz on M4 and later, Hz
 * before, told apart by magnitude. */

typedef struct {
    double hz[MAX_TABLE_STATES];
    int count;
} dvfs_table;

static int read_dvfs_table(const char *key, dvfs_table *table) {
    io_iterator_t iterator = 0;
    io_registry_entry_t entry;
    int found = 0;
    CFStringRef name;
    memset(table, 0, sizeof(*table));
    if (IOServiceGetMatchingServices(MACH_PORT_NULL,
        IOServiceNameMatching("pmgr"), &iterator) != KERN_SUCCESS) return 0;
    name = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    while (!found && (entry = IOIteratorNext(iterator)) != 0) {
        CFTypeRef data = IORegistryEntryCreateCFProperty(entry, name,
            kCFAllocatorDefault, 0);
        if (data && CFGetTypeID(data) == CFDataGetTypeID()) {
            const uint8_t *bytes = CFDataGetBytePtr((CFDataRef)data);
            CFIndex length = CFDataGetLength((CFDataRef)data);
            double maximum = 0;
            for (CFIndex offset = 0; offset + 8 <= length
                && table->count < MAX_TABLE_STATES; offset += 8) {
                uint32_t frequency;
                memcpy(&frequency, bytes + offset, sizeof(frequency));
                if (frequency == 0) continue;
                table->hz[table->count++] = frequency;
                if (frequency > maximum) maximum = frequency;
            }
            if (table->count > 0 && maximum < 1e8) {
                for (int index = 0; index < table->count; ++index)
                    table->hz[index] *= 1000.0;
            }
            found = table->count > 0;
        }
        if (data) CFRelease(data);
        IOObjectRelease(entry);
    }
    CFRelease(name);
    IOObjectRelease(iterator);
    return found;
}

/* Averages the non-idle states of one residency channel over its table. */
static int residency_frequency(CFDictionaryRef item, const dvfs_table *table,
    double *average, double *active_fraction) {
    int32_t states = ioreport.state_count(item);
    double weighted = 0, active = 0, total = 0;
    int table_index = 0;
    for (int32_t state = 0; state < states; ++state) {
        char text[32];
        int64_t residency = ioreport.residency(item, state);
        if (residency < 0) residency = 0;
        total += (double)residency;
        (void)cf_text(ioreport.state_name(item, state), text, sizeof(text));
        if (strcmp(text, "IDLE") == 0 || strcmp(text, "OFF") == 0
            || strcmp(text, "DOWN") == 0) continue;
        if (table_index < table->count) {
            weighted += (double)residency * table->hz[table_index];
            active += (double)residency;
        }
        ++table_index;
    }
    *active_fraction = total > 0 ? active / total : 0;
    *average = active > 0 ? weighted / active : 0;
    return total > 0;
}

/* ------------------------------------------------------------------------
 * GPU */

static ioreport_set gpu_states;
static dvfs_table gpu_table;
static int gpu_table_state = 0;

static int dictionary_number(CFDictionaryRef dictionary, const char *key,
    double *value) {
    CFStringRef name;
    int found;
    if (!dictionary) return 0;
    name = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    found = cf_double(CFDictionaryGetValue(dictionary, name), value);
    CFRelease(name);
    return found;
}

static int l_collect_gpu(lua_State *L) {
    io_iterator_t iterator = 0;
    io_registry_entry_t entry;
    int output = 1;
    double frequency = 0, active = 0;
    int has_frequency = 0;
    if (!gpu_table_state)
        gpu_table_state = read_dvfs_table("voltage-states9-sram", &gpu_table) ? 1 : -1;
    if (gpu_table_state > 0
        && ioreport_open(&gpu_states, CFSTR("GPU Stats"), CFSTR("GPU Performance States"))) {
        CFDictionaryRef owner;
        CFArrayRef items = ioreport_changes(&gpu_states, &owner);
        for (CFIndex index = 0; items && index < CFArrayGetCount(items); ++index) {
            CFDictionaryRef item = CFArrayGetValueAtIndex(items, index);
            char name[32];
            if (cf_text(ioreport.name(item), name, sizeof(name))
                && strcmp(name, "GPUPH") == 0)
                has_frequency = residency_frequency(item, &gpu_table, &frequency, &active);
        }
        if (owner) CFRelease(owner);
    }
    if (IOServiceGetMatchingServices(MACH_PORT_NULL,
        IOServiceMatching("IOAccelerator"), &iterator) != KERN_SUCCESS) {
        lua_pushnil(L);
        lua_pushliteral(L, "IOAccelerator is unavailable");
        return 2;
    }
    lua_createtable(L, 0, 3);
    string_field(L, "schema", "dev.waterrun.wtop.gpu/v2");
    lua_createtable(L, 2, 0);
    while ((entry = IOIteratorNext(iterator)) != 0) {
        CFMutableDictionaryRef properties = NULL;
        CFDictionaryRef statistics = NULL;
        char text[128], id[64];
        int64_t cores = 0, vendor = 0;
        double value;
        if (IORegistryEntryCreateCFProperties(entry, &properties,
            kCFAllocatorDefault, 0) != KERN_SUCCESS || !properties) {
            IOObjectRelease(entry);
            continue;
        }
        {
            CFTypeRef stats = CFDictionaryGetValue(properties,
                CFSTR("PerformanceStatistics"));
            if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID())
                statistics = (CFDictionaryRef)stats;
        }
        lua_createtable(L, 0, 12);
        snprintf(id, sizeof(id), "gpu%d", output - 1);
        string_field(L, "id", id);
        string_field(L, "card", id);
        {
            CFTypeRef vendor_data = CFDictionaryGetValue(properties, CFSTR("vendor-id"));
            if (vendor_data && CFGetTypeID(vendor_data) == CFDataGetTypeID()
                && CFDataGetLength((CFDataRef)vendor_data) >= 2) {
                const uint8_t *bytes = CFDataGetBytePtr((CFDataRef)vendor_data);
                vendor = bytes[0] | (bytes[1] << 8);
                snprintf(text, sizeof(text), "0x%04llx", (long long)vendor);
                string_field(L, "vendor_id", text);
                string_field(L, "vendor", text);
            }
        }
        string_field(L, "vendor_name", vendor == 0x106b ? "Apple"
            : vendor == 0x1002 ? "AMD" : vendor == 0x8086 ? "Intel"
            : vendor == 0x10de ? "NVIDIA" : "Unknown");
        if (cf_text(CFDictionaryGetValue(properties, CFSTR("model")), text, sizeof(text)))
            string_field(L, "model_name", text);
        if (cf_text(CFDictionaryGetValue(properties, CFSTR("IOClass")), text, sizeof(text)))
            string_field(L, "driver", text);
        string_field(L, "identity_quality", "fresh");
        string_field(L, "source", "iokit:IOAccelerator");
        if (cf_int64(CFDictionaryGetValue(properties, CFSTR("gpu-core-count")), &cores)
            && cores > 0) integer_field(L, "core_count", cores);
        lua_createtable(L, 0, 8);
        if (dictionary_number(statistics, "Device Utilization %", &value)) {
            number_field(L, "utilization_percent", value);
            string_field(L, "utilization_source", "iokit");
        } else if (dictionary_number(statistics, "GPU Activity(%)", &value)) {
            number_field(L, "utilization_percent", value);
            string_field(L, "utilization_source", "iokit");
        }
        if (dictionary_number(statistics, "Renderer Utilization %", &value))
            number_field(L, "renderer_utilization_percent", value);
        if (dictionary_number(statistics, "Tiler Utilization %", &value))
            number_field(L, "tiler_utilization_percent", value);
        if (dictionary_number(statistics, "vramUsedBytes", &value)) {
            double free_bytes;
            integer_field(L, "memory_used_bytes", (lua_Integer)value);
            if (dictionary_number(statistics, "vramFreeBytes", &free_bytes))
                integer_field(L, "memory_total_bytes", (lua_Integer)(value + free_bytes));
        } else if (dictionary_number(statistics, "In use system memory", &value)) {
            /* Unified memory: the GPU's share of system memory. */
            integer_field(L, "memory_used_bytes", (lua_Integer)value);
            integer_field(L, "shared_memory_used_bytes", (lua_Integer)value);
            if (dictionary_number(statistics, "Alloc system memory", &value))
                integer_field(L, "shared_memory_allocated_bytes", (lua_Integer)value);
        }
        /* The DVFS residency belongs to the integrated GPU. */
        if (vendor == 0x106b && has_frequency && output == 1) {
            if (frequency > 0) integer_field(L, "frequency_current_hz", (lua_Integer)frequency);
            if (gpu_table.count > 0) {
                integer_field(L, "frequency_minimum_hz", (lua_Integer)gpu_table.hz[0]);
                integer_field(L, "frequency_maximum_hz",
                    (lua_Integer)gpu_table.hz[gpu_table.count - 1]);
            }
            number_field(L, "active_residency_percent", active * 100);
        }
        lua_setfield(L, -2, "metrics");
        lua_createtable(L, 0, 2);
        boolean_field(L, "utilization", statistics != NULL);
        boolean_field(L, "process_usage", 0);
        lua_setfield(L, -2, "capabilities");
        lua_createtable(L, 0, 1);
        string_field(L, "quality", "unavailable");
        string_field(L, "reason", "per_process_gpu_usage_unavailable");
        lua_setfield(L, -2, "processes");
        lua_rawseti(L, -2, output++);
        CFRelease(properties);
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    lua_setfield(L, -2, "devices");
    if (output == 1) {
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "no_display_adapters");
        return 2;
    }
    lua_createtable(L, 0, 2);
    boolean_field(L, "enabled", 0);
    string_field(L, "status", "unavailable");
    string_field(L, "reason", "per_process_gpu_usage_unavailable");
    lua_setfield(L, -2, "process_scan");
    return 1;
}

/* ------------------------------------------------------------------------
 * SMC. The AppleSMC user client answers key reads for any user. */

typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} smc_version;

typedef struct {
    uint16_t version, length;
    uint32_t cpu, gpu, memory;
} smc_limits;

typedef struct {
    uint32_t data_size;
    uint32_t data_type;
    uint8_t data_attributes;
} smc_key_info;

typedef struct {
    uint32_t key;
    smc_version version;
    smc_limits limits;
    smc_key_info info;
    uint8_t result, status, command;
    uint32_t data32;
    uint8_t bytes[32];
} smc_message;

static io_connect_t smc_connection = 0;
static int smc_state = 0;

static uint32_t four_cc(const char *text) {
    return ((uint32_t)(uint8_t)text[0] << 24) | ((uint32_t)(uint8_t)text[1] << 16)
        | ((uint32_t)(uint8_t)text[2] << 8) | (uint32_t)(uint8_t)text[3];
}

static int smc_open(void) {
    if (smc_state == 0) {
        io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL,
            IOServiceMatching("AppleSMC"));
        smc_state = -1;
        if (service) {
            if (IOServiceOpen(service, mach_task_self(), 0, &smc_connection)
                == KERN_SUCCESS) smc_state = 1;
            IOObjectRelease(service);
        }
    }
    return smc_state > 0;
}

/* Reads a numeric SMC key; the encodings cover Apple silicon (flt) and the
 * fixed-point types of Intel Macs. */
static int smc_number(const char *key, double *value) {
    smc_message input, output;
    size_t size = sizeof(output);
    char type[5];
    const uint8_t *b;
    if (!smc_open()) return 0;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = four_cc(key);
    input.command = 9; /* key information */
    if (IOConnectCallStructMethod(smc_connection, 2, &input, sizeof(input),
        &output, &size) != KERN_SUCCESS || output.result != 0) return 0;
    input.info.data_size = output.info.data_size;
    type[0] = (char)(output.info.data_type >> 24);
    type[1] = (char)(output.info.data_type >> 16);
    type[2] = (char)(output.info.data_type >> 8);
    type[3] = (char)output.info.data_type;
    type[4] = 0;
    input.command = 5; /* read bytes */
    memset(&output, 0, sizeof(output));
    size = sizeof(output);
    if (input.info.data_size == 0 || input.info.data_size > 32
        || IOConnectCallStructMethod(smc_connection, 2, &input, sizeof(input),
            &output, &size) != KERN_SUCCESS || output.result != 0) return 0;
    b = output.bytes;
    if (strcmp(type, "flt ") == 0 && input.info.data_size == 4) {
        float number;
        memcpy(&number, b, sizeof(number));
        *value = number;
    } else if (strcmp(type, "fpe2") == 0 && input.info.data_size == 2) {
        *value = ((b[0] << 8) | b[1]) / 4.0;
    } else if (strcmp(type, "sp78") == 0 && input.info.data_size == 2) {
        *value = (int16_t)((b[0] << 8) | b[1]) / 256.0;
    } else if (strcmp(type, "ui8 ") == 0) {
        *value = b[0];
    } else if (strcmp(type, "ui16") == 0 && input.info.data_size == 2) {
        *value = (b[0] << 8) | b[1];
    } else if (strcmp(type, "ui32") == 0 && input.info.data_size == 4) {
        *value = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | (b[2] << 8) | b[3];
    } else {
        return 0;
    }
    return *value == *value;
}

/* ------------------------------------------------------------------------
 * Sensors: HID temperature services and SMC fans and power rails. */

typedef struct __IOHIDEventSystemClient *hid_client;
typedef struct __IOHIDServiceClient *hid_service;
typedef struct __IOHIDEvent *hid_event;
typedef hid_client (*hid_create_function)(CFAllocatorRef);
typedef int (*hid_matching_function)(hid_client, CFDictionaryRef);
typedef CFArrayRef (*hid_services_function)(hid_client);
typedef CFTypeRef (*hid_property_function)(hid_service, CFStringRef);
typedef hid_event (*hid_copy_event_function)(hid_service, int64_t, int32_t, int64_t);
typedef double (*hid_float_function)(hid_event, int32_t);

#define HID_TEMPERATURE_EVENT 15

static struct {
    int state;
    hid_client client;
    CFArrayRef services;
    hid_property_function property;
    hid_copy_event_function copy_event;
    hid_float_function float_value;
} hid;

static int hid_open(void) {
    hid_create_function create;
    hid_matching_function set_matching;
    hid_services_function copy_services;
    int page = 0xff00, usage = 5;
    CFNumberRef page_number, usage_number;
    const void *keys[2], *values[2];
    CFDictionaryRef matching;
    if (hid.state) return hid.state > 0;
    hid.state = -1;
    create = (hid_create_function)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    set_matching = (hid_matching_function)dlsym(RTLD_DEFAULT,
        "IOHIDEventSystemClientSetMatching");
    copy_services = (hid_services_function)dlsym(RTLD_DEFAULT,
        "IOHIDEventSystemClientCopyServices");
    hid.property = (hid_property_function)dlsym(RTLD_DEFAULT,
        "IOHIDServiceClientCopyProperty");
    hid.copy_event = (hid_copy_event_function)dlsym(RTLD_DEFAULT,
        "IOHIDServiceClientCopyEvent");
    hid.float_value = (hid_float_function)dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
    if (!create || !set_matching || !copy_services || !hid.property
        || !hid.copy_event || !hid.float_value) return 0;
    hid.client = create(kCFAllocatorDefault);
    if (!hid.client) return 0;
    /* Vendor usage page 0xff00, usage 5: temperature sensors. */
    page_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    usage_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    keys[0] = CFSTR("PrimaryUsagePage");
    keys[1] = CFSTR("PrimaryUsage");
    values[0] = page_number;
    values[1] = usage_number;
    matching = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(page_number);
    CFRelease(usage_number);
    if (!matching) return 0;
    (void)set_matching(hid.client, matching);
    CFRelease(matching);
    hid.services = copy_services(hid.client);
    if (!hid.services || CFArrayGetCount(hid.services) == 0) return 0;
    hid.state = 1;
    return 1;
}

typedef struct {
    char device[32];
    char label[64];
    double celsius;
} hid_reading;

static int reading_compare(const void *left, const void *right) {
    const hid_reading *a = (const hid_reading *)left, *b = (const hid_reading *)right;
    int device = strcmp(a->device, b->device);
    size_t a_length, b_length;
    if (device) return device;
    /* Natural order: tdie2 before tdie10. */
    a_length = strlen(a->label);
    b_length = strlen(b->label);
    if (a_length != b_length && strncmp(a->label, b->label,
        a_length < b_length ? a_length - 1 : b_length - 1) == 0)
        return a_length < b_length ? -1 : 1;
    return strcmp(a->label, b->label);
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

static int l_collect_hwmon(lua_State *L) {
    hid_reading readings[MAX_HID_SENSORS];
    int reading_count = 0, device_output = 1;
    double fans = 0;
    if (hid_open()) {
        CFIndex count = CFArrayGetCount(hid.services);
        for (CFIndex index = 0; index < count && reading_count < MAX_HID_SENSORS; ++index) {
            hid_service service = (hid_service)CFArrayGetValueAtIndex(hid.services, index);
            CFTypeRef product = hid.property(service, CFSTR("Product"));
            hid_event event;
            char name[96];
            char *space;
            double value;
            if (!cf_text(product, name, sizeof(name))) {
                if (product) CFRelease(product);
                continue;
            }
            CFRelease(product);
            /* tcal is a calibration constant, not a measurement. */
            if (strstr(name, "tcal")) continue;
            event = hid.copy_event(service, HID_TEMPERATURE_EVENT, 0, 0);
            if (!event) continue;
            value = hid.float_value(event, HID_TEMPERATURE_EVENT << 16);
            CFRelease(event);
            if (!(value > -40 && value < 150)) continue;
            space = strchr(name, ' ');
            if (space) {
                *space = 0;
                snprintf(readings[reading_count].device, sizeof(readings[0].device),
                    "%s", name);
                snprintf(readings[reading_count].label, sizeof(readings[0].label),
                    "%s", space + 1);
            } else {
                snprintf(readings[reading_count].device, sizeof(readings[0].device),
                    "HID");
                snprintf(readings[reading_count].label, sizeof(readings[0].label),
                    "%s", name);
            }
            readings[reading_count++].celsius = value;
        }
        qsort(readings, (size_t)reading_count, sizeof(readings[0]), reading_compare);
    }
    lua_createtable(L, 0, 2);
    lua_createtable(L, 4, 0);
    for (int index = 0; index < reading_count; ) {
        int stop = index, channel = 1;
        char id[48];
        while (stop < reading_count
            && strcmp(readings[stop].device, readings[index].device) == 0) ++stop;
        lua_createtable(L, 0, 7);
        snprintf(id, sizeof(id), "hid:%s", readings[index].device);
        string_field(L, "id", id);
        string_field(L, "class", id);
        string_field(L, "name", readings[index].device);
        string_field(L, "identity_quality", "fresh");
        string_field(L, "quality", "fresh");
        string_field(L, "source", "iohid");
        lua_createtable(L, stop - index, 0);
        for (int reading = index; reading < stop; ++reading) {
            push_channel(L, channel, "temperature", "celsius",
                readings[reading].label, readings[reading].celsius);
            lua_rawseti(L, -2, channel++);
        }
        lua_setfield(L, -2, "channels");
        lua_rawseti(L, -2, device_output++);
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
        if (smc_number("FNum", &fans)) {
            for (int fan = 0; fan < (int)fans && fan < 8; ++fan) {
                char key[8], label[16];
                double minimum, maximum;
                snprintf(key, sizeof(key), "F%dAc", fan);
                if (!smc_number(key, &value)) continue;
                snprintf(label, sizeof(label), "Fan %d", fan + 1);
                push_channel(L, fan_index++, "fan", "rpm", label, value);
                lua_createtable(L, 0, 2);
                snprintf(key, sizeof(key), "F%dMn", fan);
                if (smc_number(key, &minimum)) number_field(L, "min", minimum);
                snprintf(key, sizeof(key), "F%dMx", fan);
                if (smc_number(key, &maximum)) number_field(L, "max", maximum);
                lua_setfield(L, -2, "thresholds");
                lua_rawseti(L, -2, channel++);
            }
        }
        for (size_t rail = 0; rail < sizeof(rails) / sizeof(rails[0]); ++rail) {
            if (!smc_number(rails[rail].key, &value)) continue;
            push_channel(L, channel, rails[rail].type, rails[rail].unit,
                rails[rail].label, value);
            string_field(L, "input_source", rails[rail].key);
            lua_rawseti(L, -2, channel++);
        }
        lua_setfield(L, -2, "channels");
        if (channel > 1) lua_rawseti(L, -2, device_output++);
        else lua_pop(L, 1);
    }
    lua_setfield(L, -2, "devices");
    if (device_output == 1) {
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "no_sensors");
        return 2;
    }
    boolean_field(L, "truncated", reading_count >= MAX_HID_SENSORS);
    return 1;
}

/* ------------------------------------------------------------------------
 * Energy: IOReport's energy model per SoC block, accumulated into counters
 * so the shared collector derives power the same way it does for RAPL. */

static ioreport_set energy_report;

typedef struct {
    const char *channel;
    const char *id;
    const char *name;
    const char *kind;
    int aggregate;
    double joules;
    int seen;
} energy_zone;

static energy_zone energy_zones[] = {
    {"CPU Energy", "cpu", "CPU", "package", 1, 0, 0},
    {"ECPU", "cpu-efficiency", "Efficiency cores", "core", 0, 0, 0},
    {"PCPU", "cpu-performance", "Performance cores", "core", 0, 0, 0},
    {"GPU Energy", "gpu", "GPU", "uncore", 0, 0, 0},
    {"ANE", "ane", "Neural Engine", "uncore", 0, 0, 0},
    {"DRAM", "dram", "DRAM", "dram", 0, 0, 0},
};

static int l_collect_powercap(lua_State *L) {
    size_t count = sizeof(energy_zones) / sizeof(energy_zones[0]);
    int output = 1, first = energy_report.previous == NULL;
    double system_watts = 0;
    int has_system;
    if (!ioreport_open(&energy_report, CFSTR("Energy Model"), NULL)) {
        lua_pushnil(L);
        lua_pushliteral(L, "ioreport_energy_model_unavailable");
        return 2;
    }
    {
        CFDictionaryRef owner;
        CFArrayRef items = ioreport_changes(&energy_report, &owner);
        for (CFIndex index = 0; items && index < CFArrayGetCount(items); ++index) {
            CFDictionaryRef item = CFArrayGetValueAtIndex(items, index);
            char name[64];
            double scale;
            if (!cf_text(ioreport.name(item), name, sizeof(name))) continue;
            for (size_t zone = 0; zone < count; ++zone) {
                if (strcmp(name, energy_zones[zone].channel) != 0) continue;
                scale = energy_scale(ioreport.unit(item));
                if (scale > 0) {
                    int64_t value = ioreport.integer(item, 0);
                    if (value > 0) energy_zones[zone].joules += (double)value * scale;
                    energy_zones[zone].seen = 1;
                }
            }
        }
        if (owner) CFRelease(owner);
    }
    has_system = smc_number("PSTR", &system_watts);
    lua_createtable(L, 0, 4);
    string_field(L, "schema", "dev.waterrun.wtop.macos-energy/v1");
    lua_createtable(L, (int)count + 1, 0);
    for (size_t zone = 0; zone < count; ++zone) {
        if (!first && !energy_zones[zone].seen) continue;
        lua_createtable(L, 0, 8);
        string_field(L, "id", energy_zones[zone].id);
        string_field(L, "name", energy_zones[zone].name);
        string_field(L, "source_kind", energy_zones[zone].kind);
        number_field(L, "energy_joules", energy_zones[zone].joules);
        boolean_field(L, "aggregate", energy_zones[zone].aggregate);
        boolean_field(L, "enabled", 1);
        string_field(L, "source", "ioreport:Energy Model");
        lua_rawseti(L, -2, output++);
    }
    if (has_system) {
        lua_createtable(L, 0, 8);
        string_field(L, "id", "system");
        string_field(L, "name", "System total");
        string_field(L, "source_kind", "platform");
        number_field(L, "power_watts", system_watts);
        string_field(L, "power_source", "smc:PSTR");
        boolean_field(L, "aggregate", 0);
        boolean_field(L, "enabled", 1);
        string_field(L, "source", "smc");
        lua_rawseti(L, -2, output++);
    }
    lua_setfield(L, -2, "zones");
    if (has_system) {
        number_field(L, "platform_power_watts", system_watts);
        integer_field(L, "measured_platform_zones", 1);
    }
    string_field(L, "aggregate_source_kind", "package");
    string_field(L, "aggregate_strategy", "ioreport_cpu_energy");
    return 1;
}

/* ------------------------------------------------------------------------
 * CPU frequency: residency across each cluster's performance states,
 * weighted by the state frequencies. */

static ioreport_set cpu_states;
static dvfs_table efficiency_table, performance_table;
static int cpu_tables_state = 0;

static int l_collect_cpufreq(lua_State *L) {
    int64_t performance_cpus = sysctl_int64("hw.perflevel0.logicalcpu", 0);
    int64_t efficiency_cpus = sysctl_int64("hw.perflevel1.logicalcpu", 0);
    int output = 1, performance_clusters = 0, efficiency_clusters = 0;
    char names[MAX_CLUSTERS][16];
    double averages[MAX_CLUSTERS], active[MAX_CLUSTERS];
    int valid[MAX_CLUSTERS], cluster_count = 0;
    CFDictionaryRef owner = NULL;
    CFArrayRef items;
    if (!cpu_tables_state) {
        int efficiency = read_dvfs_table("voltage-states1-sram", &efficiency_table);
        int performance = read_dvfs_table("voltage-states5-sram", &performance_table);
        cpu_tables_state = efficiency || performance ? 1 : -1;
    }
    if (cpu_tables_state < 0 || !ioreport_open(&cpu_states, CFSTR("CPU Stats"),
        CFSTR("CPU Complex Performance States"))) {
        lua_pushnil(L);
        lua_pushliteral(L, "cpu_performance_states_unavailable");
        return 2;
    }
    items = ioreport_changes(&cpu_states, &owner);
    for (CFIndex index = 0; items && index < CFArrayGetCount(items)
        && cluster_count < MAX_CLUSTERS; ++index) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(items, index);
        char name[32];
        const dvfs_table *table;
        size_t length;
        if (!cf_text(ioreport.name(item), name, sizeof(name))) continue;
        /* ECPU, PCPU, PCPU1 ...; ECPM/PCPM are the cluster managers. */
        length = strlen(name);
        if (length < 4 || (name[0] != 'E' && name[0] != 'P')
            || strncmp(name + 1, "CPU", 3) != 0) continue;
        if (length > 4 && (name[4] < '0' || name[4] > '9')) continue;
        table = name[0] == 'E' ? &efficiency_table : &performance_table;
        if (table->count == 0) continue;
        snprintf(names[cluster_count], sizeof(names[0]), "%s", name);
        valid[cluster_count] = residency_frequency(item, table,
            &averages[cluster_count], &active[cluster_count]);
        if (name[0] == 'E') ++efficiency_clusters;
        else ++performance_clusters;
        ++cluster_count;
    }
    if (owner) CFRelease(owner);
    lua_createtable(L, 0, 2);
    lua_createtable(L, cluster_count > 0 ? cluster_count : 2, 0);
    if (cluster_count == 0) {
        /* The first call only primes the residency counters. */
        const char *first_names[] = {"ECPU", "PCPU"};
        for (int index = 0; index < 2; ++index) {
            const dvfs_table *table = index == 0 ? &efficiency_table : &performance_table;
            if (table->count == 0) continue;
            lua_createtable(L, 0, 6);
            string_field(L, "id", first_names[index]);
            string_field(L, "policy", first_names[index]);
            string_field(L, "driver", "ioreport");
            lua_createtable(L, 0, 3);
            integer_field(L, "hardware_minimum_hz", (lua_Integer)table->hz[0]);
            integer_field(L, "hardware_maximum_hz", (lua_Integer)table->hz[table->count - 1]);
            string_field(L, "current_quality", "gap");
            lua_setfield(L, -2, "frequencies");
            string_field(L, "quality", "gap");
            lua_rawseti(L, -2, output++);
        }
    }
    {
        /* Apple silicon numbers its logical CPUs cluster by cluster, the
         * efficiency cores first. */
        int next_cpu = 0;
        for (int pass = 0; pass < 2; ++pass) {
            for (int index = 0; index < cluster_count; ++index) {
                int efficiency = names[index][0] == 'E';
                int64_t cpus = efficiency
                    ? (efficiency_clusters ? efficiency_cpus / efficiency_clusters : 0)
                    : (performance_clusters ? performance_cpus / performance_clusters : 0);
                const dvfs_table *table = efficiency ? &efficiency_table : &performance_table;
                if ((pass == 0) != efficiency) continue;
                lua_createtable(L, 0, 9);
                string_field(L, "id", names[index]);
                string_field(L, "policy", names[index]);
                string_field(L, "identity_quality", "estimated");
                string_field(L, "driver", "ioreport");
                lua_createtable(L, (int)cpus, 0);
                for (int64_t cpu = 0; cpu < cpus; ++cpu) {
                    lua_pushinteger(L, next_cpu++);
                    lua_rawseti(L, -2, (lua_Integer)cpu + 1);
                }
                lua_setfield(L, -2, "affected_cpus");
                lua_createtable(L, 0, 5);
                if (valid[index] && averages[index] > 0) {
                    integer_field(L, "current_hz", (lua_Integer)averages[index]);
                    string_field(L, "current_quality", "fresh");
                } else {
                    /* A cluster that stayed idle has no running frequency. */
                    string_field(L, "current_quality", valid[index] ? "idle" : "gap");
                }
                integer_field(L, "hardware_minimum_hz", (lua_Integer)table->hz[0]);
                integer_field(L, "hardware_maximum_hz",
                    (lua_Integer)table->hz[table->count - 1]);
                lua_setfield(L, -2, "frequencies");
                number_field(L, "active_residency_percent", active[index] * 100);
                string_field(L, "quality", valid[index] ? "fresh" : "gap");
                string_field(L, "source", "ioreport:CPU Complex Performance States");
                lua_rawseti(L, -2, output++);
            }
        }
    }
    lua_setfield(L, -2, "policies");
    return 1;
}

/* ------------------------------------------------------------------------
 * Batteries through IOPowerSources, with cycle and design data from the
 * smart-battery service when a battery is installed. */

static void battery_details(lua_State *L) {
    io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL,
        IOServiceMatching("AppleSmartBattery"));
    CFMutableDictionaryRef properties = NULL;
    int64_t value, design = 0, maximum = 0, voltage = 0, amperage = 0;
    if (!service) return;
    if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        == KERN_SUCCESS && properties) {
        if (cf_int64(CFDictionaryGetValue(properties, CFSTR("CycleCount")), &value))
            integer_field(L, "cycle_count", value);
        (void)cf_int64(CFDictionaryGetValue(properties, CFSTR("DesignCapacity")), &design);
        if (!cf_int64(CFDictionaryGetValue(properties, CFSTR("AppleRawMaxCapacity")), &maximum))
            (void)cf_int64(CFDictionaryGetValue(properties, CFSTR("NominalChargeCapacity")),
                &maximum);
        if (design > 0 && maximum > 0)
            number_field(L, "health_percent", (double)maximum * 100 / (double)design);
        if (cf_int64(CFDictionaryGetValue(properties, CFSTR("Voltage")), &voltage)
            && voltage > 0) {
            number_field(L, "voltage_volts", voltage / 1000.0);
            if (cf_int64(CFDictionaryGetValue(properties, CFSTR("InstantAmperage")), &amperage)
                || cf_int64(CFDictionaryGetValue(properties, CFSTR("Amperage")), &amperage)) {
                /* Negative current is discharge; power is reported as a
                 * magnitude, like the Linux power_now attribute. */
                double watts = (double)(amperage < 0 ? -amperage : amperage)
                    * (double)voltage / 1e6;
                number_field(L, "power_watts", watts);
            }
            if (design > 0) number_field(L, "energy_design_watt_hours",
                (double)design * voltage / 1e6);
            if (maximum > 0) number_field(L, "energy_full_watt_hours",
                (double)maximum * voltage / 1e6);
        }
        if (cf_int64(CFDictionaryGetValue(properties, CFSTR("Temperature")), &value))
            number_field(L, "temperature_celsius", value / 100.0);
        CFRelease(properties);
    }
    IOObjectRelease(service);
}

static int l_collect_power_supply(lua_State *L) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    CFArrayRef list = info ? IOPSCopyPowerSourcesList(info) : NULL;
    CFStringRef providing = info ? IOPSGetProvidingPowerSourceType(info) : NULL;
    int batteries = 0, on_ac = 0;
    double capacity_sum = 0;
    int charging = 0, discharging = 0;
    if (providing && CFStringCompare(providing, CFSTR(kIOPSACPowerValue), 0)
        == kCFCompareEqualTo) on_ac = 1;
    lua_createtable(L, 0, 5);
    lua_createtable(L, 1, 0);
    for (CFIndex index = 0; list && index < CFArrayGetCount(list); ++index) {
        CFDictionaryRef source = IOPSGetPowerSourceDescription(info,
            CFArrayGetValueAtIndex(list, index));
        char text[64];
        int64_t current = -1, maximum = -1, minutes = -1;
        int present = 1, is_charging = 0, charged = 0;
        if (!source || !cf_text(CFDictionaryGetValue(source, CFSTR(kIOPSTypeKey)),
            text, sizeof(text)) || strcmp(text, kIOPSInternalBatteryType) != 0) continue;
        (void)cf_bool(CFDictionaryGetValue(source, CFSTR(kIOPSIsPresentKey)), &present);
        if (!present) continue;
        ++batteries;
        lua_createtable(L, 0, 14);
        snprintf(text, sizeof(text), "BAT%d", batteries - 1);
        string_field(L, "id", text);
        if (cf_text(CFDictionaryGetValue(source, CFSTR(kIOPSNameKey)), text, sizeof(text)))
            string_field(L, "name", text);
        else string_field(L, "name", "Battery");
        string_field(L, "type", "Battery");
        boolean_field(L, "present", 1);
        (void)cf_int64(CFDictionaryGetValue(source, CFSTR(kIOPSCurrentCapacityKey)), &current);
        (void)cf_int64(CFDictionaryGetValue(source, CFSTR(kIOPSMaxCapacityKey)), &maximum);
        (void)cf_bool(CFDictionaryGetValue(source, CFSTR(kIOPSIsChargingKey)), &is_charging);
        (void)cf_bool(CFDictionaryGetValue(source, CFSTR(kIOPSIsChargedKey)), &charged);
        if (current >= 0 && maximum > 0) {
            double percent = (double)current * 100 / (double)maximum;
            number_field(L, "capacity_percent", percent);
            capacity_sum += percent;
        }
        string_field(L, "status", is_charging ? "Charging"
            : charged ? "Full" : on_ac ? "Not charging" : "Discharging");
        charging |= is_charging;
        discharging |= !on_ac;
        if (!on_ac && cf_int64(CFDictionaryGetValue(source, CFSTR(kIOPSTimeToEmptyKey)),
            &minutes) && minutes > 0)
            integer_field(L, "time_remaining_seconds", minutes * 60);
        if (is_charging && cf_int64(CFDictionaryGetValue(source,
            CFSTR(kIOPSTimeToFullChargeKey)), &minutes) && minutes > 0)
            integer_field(L, "time_to_full_seconds", minutes * 60);
        battery_details(L);
        string_field(L, "quality", current >= 0 ? "fresh" : "partial");
        string_field(L, "source", "iokit:IOPowerSources");
        lua_rawseti(L, -2, batteries);
    }
    lua_setfield(L, -2, "batteries");
    if (list) CFRelease(list);
    if (info) CFRelease(info);
    if (batteries == 0) {
        /* Desktops report like a Linux host without power-supply entries. */
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "no_power_supplies");
        return 2;
    }
    lua_createtable(L, 1, 0);
    lua_createtable(L, 0, 5);
    string_field(L, "id", "AC");
    string_field(L, "name", "AC");
    string_field(L, "type", "Mains");
    boolean_field(L, "online", on_ac);
    boolean_field(L, "present", 1);
    lua_rawseti(L, -2, 1);
    lua_setfield(L, -2, "supplies");
    lua_createtable(L, 0, 3);
    integer_field(L, "count", batteries);
    number_field(L, "capacity_percent", capacity_sum / batteries);
    string_field(L, "state", charging ? "charging" : discharging ? "discharging" : "idle");
    lua_setfield(L, -2, "summary");
    boolean_field(L, "on_ac_power", on_ac);
    return 1;
}

/* ------------------------------------------------------------------------
 * Sockets: each readable process's socket descriptors. Without root only
 * the caller's own processes are readable, and the result says so. */

/* Open-addressing set of kernel socket handles; zero marks a free slot. */
#define SOCKET_SET_SIZE 32768

static int socket_set_insert(uint64_t *set, uint64_t handle) {
    uint64_t slot = (handle >> 4) * 0x9e3779b97f4a7c15ULL;
    if (handle == 0) return 1;
    for (int probe = 0; probe < SOCKET_SET_SIZE; ++probe) {
        uint64_t *entry = &set[(slot + (uint64_t)probe) & (SOCKET_SET_SIZE - 1)];
        if (*entry == handle) return 0;
        if (*entry == 0) {
            *entry = handle;
            return 1;
        }
    }
    return 0;
}

/* TSI_S_* numbering onto MIB_TCP_STATE, which the shared collector maps. */
static int tcp_state(int state) {
    static const int map[] = {1, 2, 3, 4, 5, 8, 6, 9, 10, 7, 11};
    return state >= 0 && state < (int)(sizeof(map) / sizeof(map[0])) ? map[state] : 0;
}

static void push_endpoint(lua_State *L, int ipv6, const struct in_sockinfo *info,
    int remote) {
    char text[INET6_ADDRSTRLEN];
    const char *address_field = remote ? "remote_address" : "local_address";
    if (ipv6) {
        const struct in6_addr *address = remote ? &info->insi_faddr.ina_6
            : &info->insi_laddr.ina_6;
        lua_pushlstring(L, (const char *)address->s6_addr, 16);
        lua_setfield(L, -2, remote ? "remote_address_bytes" : "local_address_bytes");
    } else {
        const struct in_addr *address = remote ? &info->insi_faddr.ina_46.i46a_addr4
            : &info->insi_laddr.ina_46.i46a_addr4;
        if (inet_ntop(AF_INET, address, text, sizeof(text)))
            string_field(L, address_field, text);
    }
    integer_field(L, remote ? "remote_port" : "local_port",
        ntohs((uint16_t)(remote ? info->insi_fport : info->insi_lport)));
}

static int l_collect_connections(lua_State *L) {
    pid_t *pids = (pid_t *)malloc(sizeof(pid_t) * MAX_PIDS);
    struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc(
        sizeof(struct proc_fdinfo) * MAX_FDS_PER_PROCESS);
    uint64_t *seen = (uint64_t *)calloc(SOCKET_SET_SIZE, sizeof(uint64_t));
    int bytes, count, output = 1, seen_count = 0, denied = 0, truncated = 0;
    pid_t self = getpid();
    uid_t uid = getuid();
    if (!pids || !fds || !seen) {
        free(pids);
        free(fds);
        free(seen);
        return luaL_error(L, "out of memory collecting sockets");
    }
    bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)(sizeof(pid_t) * MAX_PIDS));
    count = bytes > 0 ? bytes / (int)sizeof(pid_t) : 0;
    lua_createtable(L, 0, 6);
    lua_createtable(L, 64, 0);
    for (int index = 0; index < count && !truncated; ++index) {
        pid_t pid = pids[index];
        int fd_bytes, fd_count;
        char name[2 * MAXCOMLEN + 1];
        int named = 0;
        if (pid <= 0) continue;
        fd_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds,
            (int)(sizeof(struct proc_fdinfo) * MAX_FDS_PER_PROCESS));
        if (fd_bytes <= 0) {
            if (errno == EPERM || errno == EACCES) ++denied;
            continue;
        }
        fd_count = fd_bytes / (int)sizeof(struct proc_fdinfo);
        if (fd_count >= MAX_FDS_PER_PROCESS) truncated = 1;
        for (int fd = 0; fd < fd_count; ++fd) {
            struct socket_fdinfo socket_info;
            const struct in_sockinfo *in;
            int kind, ipv6;
            if (fds[fd].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            if (proc_pidfdinfo(pid, fds[fd].proc_fd, PROC_PIDFDSOCKETINFO,
                &socket_info, sizeof(socket_info)) != sizeof(socket_info)) continue;
            kind = socket_info.psi.soi_kind;
            if (kind != SOCKINFO_TCP && kind != SOCKINFO_IN) continue;
            if (socket_info.psi.soi_family != AF_INET
                && socket_info.psi.soi_family != AF_INET6) continue;
            /* A socket inherited across fork appears in every holder. */
            if (seen_count >= MAX_SOCKETS) {
                truncated = 1;
                break;
            }
            if (!socket_set_insert(seen, socket_info.psi.soi_so)) continue;
            ++seen_count;
            in = kind == SOCKINFO_TCP ? &socket_info.psi.soi_proto.pri_tcp.tcpsi_ini
                : &socket_info.psi.soi_proto.pri_in;
            ipv6 = (in->insi_vflag & INI_IPV6) != 0 && !(in->insi_vflag & INI_IPV4);
            if (!named) {
                memset(name, 0, sizeof(name));
                if (proc_name(pid, name, sizeof(name)) <= 0)
                    snprintf(name, sizeof(name), "PID %d", pid);
                named = 1;
            }
            lua_createtable(L, 0, 11);
            string_field(L, "protocol", kind == SOCKINFO_TCP ? "tcp" : "udp");
            string_field(L, "family", ipv6 ? "ipv6" : "ipv4");
            push_endpoint(L, ipv6, in, 0);
            push_endpoint(L, ipv6, in, 1);
            if (kind == SOCKINFO_TCP)
                integer_field(L, "tcp_state",
                    tcp_state(socket_info.psi.soi_proto.pri_tcp.tcpsi_state));
            integer_field(L, "pid", pid);
            string_field(L, "owner_name", name);
            lua_rawseti(L, -2, output++);
        }
    }
    lua_setfield(L, -2, "connections");
    boolean_field(L, "owners_available", 1);
    boolean_field(L, "truncated", truncated);
    integer_field(L, "denied_processes", denied);
    boolean_field(L, "privileged", uid == 0);
    integer_field(L, "scanner_pid", self);
    free(pids);
    free(fds);
    free(seen);
    return 1;
}

/* ------------------------------------------------------------------------
 * Workloads: resource coalitions. launchd places each job, and each app
 * with its XPC helpers, in one coalition, the grouping Activity Monitor
 * uses. The coalition flavor of proc_pidinfo has no SDK declaration. */

#define PROC_PIDCOALITIONINFO_FLAVOR 20

typedef struct {
    uint64_t coalition_id[2];
    uint64_t reserved[3];
} coalition_info;

typedef struct {
    uint64_t id;
    pid_t leader;
    pid_t leader_parent;
    int leader_rank;
    int processes;
    int denied;
    uint64_t cpu_ns, resident, read_bytes, written_bytes;
    int has_cpu, has_io;
    char name[2 * MAXCOMLEN + 1];
} coalition_total;

static int l_collect_cgroup(lua_State *L) {
    pid_t *pids = (pid_t *)malloc(sizeof(pid_t) * MAX_PIDS);
    coalition_total *groups = (coalition_total *)calloc(MAX_COALITIONS,
        sizeof(coalition_total));
    int bytes, count, group_count = 0, unreadable = 0, truncated = 0;
    uint64_t total_resident = 0;
    if (!pids || !groups) {
        free(pids);
        free(groups);
        return luaL_error(L, "out of memory collecting coalitions");
    }
    bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)(sizeof(pid_t) * MAX_PIDS));
    count = bytes > 0 ? bytes / (int)sizeof(pid_t) : 0;
    for (int index = 0; index < count; ++index) {
        pid_t pid = pids[index];
        coalition_info coalition;
        struct proc_bsdinfo bsd;
        struct proc_taskinfo task;
        struct rusage_info_v2 usage;
        coalition_total *group = NULL;
        int rank;
        if (pid <= 0) continue;
        memset(&coalition, 0, sizeof(coalition));
        if (proc_pidinfo(pid, PROC_PIDCOALITIONINFO_FLAVOR, 0, &coalition,
            sizeof(coalition)) != sizeof(coalition) || coalition.coalition_id[0] == 0) {
            ++unreadable;
            continue;
        }
        for (int other = 0; other < group_count; ++other) {
            if (groups[other].id == coalition.coalition_id[0]) {
                group = &groups[other];
                break;
            }
        }
        if (!group) {
            if (group_count >= MAX_COALITIONS) {
                truncated = 1;
                continue;
            }
            group = &groups[group_count++];
            group->id = coalition.coalition_id[0];
            group->leader = -1;
            group->leader_rank = 1 << 30;
        }
        group->processes += 1;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) {
            group->denied += 1;
            continue;
        }
        /* The leader is the member launchd started; ties go to the oldest. */
        rank = bsd.pbi_ppid == 1 ? pid : (1 << 29) + pid;
        if (rank < group->leader_rank) {
            group->leader_rank = rank;
            group->leader = pid;
            group->leader_parent = (pid_t)bsd.pbi_ppid;
            memset(group->name, 0, sizeof(group->name));
            if (proc_name(pid, group->name, sizeof(group->name)) <= 0)
                snprintf(group->name, sizeof(group->name), "%s", bsd.pbi_comm);
        }
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
            group->cpu_ns += wtop_mach_to_ns(task.pti_total_user + task.pti_total_system);
            group->resident += task.pti_resident_size;
            group->has_cpu = 1;
        } else {
            group->denied += 1;
        }
        if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) == 0) {
            group->read_bytes += usage.ri_diskio_bytesread;
            group->written_bytes += usage.ri_diskio_byteswritten;
            group->has_io = 1;
        }
    }
    lua_createtable(L, 0, 6);
    string_field(L, "schema", "dev.waterrun.wtop.macos-coalitions/v1");
    string_field(L, "kind", "coalition");
    lua_createtable(L, group_count + 1, 0);
    lua_createtable(L, 0, 8);
    string_field(L, "id", "coalitions");
    string_field(L, "name", "Applications");
    integer_field(L, "depth", 0);
    boolean_field(L, "accessible", 1);
    lua_rawseti(L, -2, 1);
    for (int index = 0; index < group_count; ++index) {
        coalition_total *group = &groups[index];
        char id[48];
        lua_createtable(L, 0, 12);
        snprintf(id, sizeof(id), "coalition:%llu", (unsigned long long)group->id);
        string_field(L, "id", id);
        string_field(L, "parent_id", "coalitions");
        integer_field(L, "depth", 1);
        integer_field(L, "coalition_id", (lua_Integer)group->id);
        if (group->leader > 0) integer_field(L, "leader_pid", group->leader);
        string_field(L, "name", group->name[0] ? group->name : id);
        boolean_field(L, "accessible", group->has_cpu);
        boolean_field(L, "partial", group->denied > 0);
        lua_createtable(L, 0, 1);
        integer_field(L, "count", group->processes);
        lua_setfield(L, -2, "processes");
        if (group->has_cpu) {
            lua_createtable(L, 0, 1);
            integer_field(L, "usage_ns", (lua_Integer)group->cpu_ns);
            lua_setfield(L, -2, "raw_cpu");
            lua_createtable(L, 0, 1);
            integer_field(L, "current_bytes", (lua_Integer)group->resident);
            lua_setfield(L, -2, "memory");
            total_resident += group->resident;
        }
        if (group->has_io) {
            lua_createtable(L, 0, 2);
            integer_field(L, "rbytes", (lua_Integer)group->read_bytes);
            integer_field(L, "wbytes", (lua_Integer)group->written_bytes);
            lua_setfield(L, -2, "raw_io");
        }
        lua_rawseti(L, -2, index + 2);
    }
    /* Fill the root's totals now that every group is known. */
    lua_rawgeti(L, -1, 1);
    lua_createtable(L, 0, 1);
    integer_field(L, "count", count - unreadable);
    lua_setfield(L, -2, "processes");
    lua_createtable(L, 0, 1);
    integer_field(L, "current_bytes", (lua_Integer)total_resident);
    lua_setfield(L, -2, "memory");
    boolean_field(L, "partial", unreadable > 0);
    lua_pop(L, 1);
    lua_setfield(L, -2, "workloads");
    integer_field(L, "unreadable_processes", unreadable);
    boolean_field(L, "truncated", truncated);
    free(pids);
    free(groups);
    if (group_count == 0) {
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "coalition_query_unavailable");
        return 2;
    }
    return 1;
}

static const luaL_Reg hardware_functions[] = {
    {"collect_gpu", l_collect_gpu},
    {"collect_hwmon", l_collect_hwmon},
    {"collect_powercap", l_collect_powercap},
    {"collect_cpufreq", l_collect_cpufreq},
    {"collect_power_supply", l_collect_power_supply},
    {"collect_connections", l_collect_connections},
    {"collect_cgroup", l_collect_cgroup},
    {NULL, NULL},
};

void wtop_register_hardware(lua_State *L) {
    luaL_setfuncs(L, hardware_functions, 0);
}
