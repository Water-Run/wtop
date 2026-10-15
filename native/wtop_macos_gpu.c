/* IOAccelerator snapshots belong to a registry instance, not an array slot. */
#include <lua.h>
#include <lauxlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wtop_macos.h"
#include "wtop_macos_registry.h"
#define MAX_GPUS 128
#define MAX_ACCELERATORS 4096

enum { UTIL, RENDER, TILER, USED, TOTAL, SHARED, ALLOCATED };
struct gpu_identity {
    uint32_t vendor, product;
    int has_vendor, has_product;
    int64_t cores;
    char model[256], driver[160];
};
struct gpu_row {
    struct gpu_identity identity;
    uint64_t id, parent;
    int bus, valid, partial, has_frequency;
    unsigned present;
    double utilization[3];
    int64_t memory[4];
    struct wtop_gpu_frequency frequency;
};
struct gpu_rows {
    struct gpu_row rows[MAX_GPUS];
    uint64_t seen[MAX_ACCELERATORS];
    unsigned count, scanned;
    int partial, truncated, identity_complete;
};

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

static int text(CFTypeRef value, char *output, size_t capacity) {
    output[0] = 0;
    if (!value) return 1;
    CFIndex used = 0;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFIndex length = CFStringGetLength(value);
        if (CFStringGetBytes(value, CFRangeMake(0, length), kCFStringEncodingUTF8,
            0, false, (UInt8 *)output, (CFIndex)capacity - 1, &used) != length) goto invalid;
    } else if (CFGetTypeID(value) == CFDataGetTypeID()) {
        used = CFDataGetLength(value);
        const UInt8 *bytes = CFDataGetBytePtr(value);
        while (used && bytes[used - 1] == 0) --used;
        if (used >= (CFIndex)capacity) goto invalid;
        /* Validate UTF-8 bytes before treating them as a name. */
        CFStringRef decoded = CFStringCreateWithBytes(NULL, bytes, used, kCFStringEncodingUTF8, false);
        if (!decoded) goto invalid;
        CFRelease(decoded);
        if (used) memcpy(output, bytes, (size_t)used);
    } else goto invalid;
    if (used >= (CFIndex)capacity || memchr(output, 0, (size_t)used)) goto invalid;
    output[used] = 0;
    return 1;
invalid:
    output[0] = 0;
    return 0;
}
static int identifier(CFTypeRef value, uint32_t *out) {
    if (!value) return 0;
    if (CFGetTypeID(value) == CFDataGetTypeID()) {
        CFIndex length = CFDataGetLength(value);
        if (length != 2 && length != 4) return 0;
        const UInt8 *bytes = CFDataGetBytePtr(value);
        if (length == 4 && (bytes[2] || bytes[3])) return 0;
        *out = (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8;
        return 1;
    }
    int64_t number;
    if (CFGetTypeID(value) != CFNumberGetTypeID() || CFNumberIsFloatType(value)
        || !CFNumberGetValue(value, kCFNumberSInt64Type, &number) || number < 0 || number > 65535) return 0;
    *out = (uint32_t)number;
    return 1;
}
static int identity(CFDictionaryRef properties, struct gpu_identity *out) {
    memset(out, 0, sizeof(*out));
    CFTypeRef vendor = CFDictionaryGetValue(properties, CFSTR("vendor-id"));
    CFTypeRef product = CFDictionaryGetValue(properties, CFSTR("device-id"));
    CFTypeRef cores = CFDictionaryGetValue(properties, CFSTR("gpu-core-count"));
    out->has_vendor = identifier(vendor, &out->vendor);
    out->has_product = identifier(product, &out->product);
    int valid = (!vendor || out->has_vendor) && (!product || out->has_product);
    if (!text(CFDictionaryGetValue(properties, CFSTR("model")), out->model, sizeof(out->model))) valid = 0;
    if (!text(CFDictionaryGetValue(properties, CFSTR("IOClass")), out->driver, sizeof(out->driver))) valid = 0;
    if (cores && (CFGetTypeID(cores) != CFNumberGetTypeID() || CFNumberIsFloatType(cores)
        || !CFNumberGetValue(cores, kCFNumberSInt64Type, &out->cores)
        || out->cores <= 0 || out->cores > INT32_MAX)) { out->cores = 0; valid = 0; }
    return valid;
}

static int percentage(CFDictionaryRef statistics, CFStringRef key, double *value, int *partial) {
    CFTypeRef number = statistics ? CFDictionaryGetValue(statistics, key) : NULL;
    if (!number) return 0;
    if (CFGetTypeID(number) == CFNumberGetTypeID()
        && CFNumberGetValue(number, kCFNumberDoubleType, value)
        && isfinite(*value) && *value >= 0 && *value <= 100) return 1;
    *partial = 1; return 0;
}
static int bytes(CFDictionaryRef statistics, CFStringRef key, int64_t *value, int *partial) {
    CFTypeRef number = statistics ? CFDictionaryGetValue(statistics, key) : NULL;
    if (!number) return 0;
    if (CFGetTypeID(number) == CFNumberGetTypeID()) {
        if (!CFNumberIsFloatType(number)) {
            if (CFNumberGetValue(number, kCFNumberSInt64Type, value) && *value >= 0 && *value <= LUA_MAXINTEGER) return 1;
        } else {
            double real;
            /* Doubles above 2^53-1 cannot prove an exact byte count. */
            if (CFNumberGetValue(number, kCFNumberDoubleType, &real) && isfinite(real)
                && real >= 0 && real <= 9007199254740991.0 && floor(real) == real) {
                *value = (int64_t)real; return 1;
            }
        }
    }
    *partial = 1; return 0;
}
static void metrics(CFDictionaryRef properties, struct gpu_row *row) {
    CFTypeRef statistics = CFDictionaryGetValue(properties, CFSTR("PerformanceStatistics"));
    if (!statistics) return;
    if (CFGetTypeID(statistics) != CFDictionaryGetTypeID()) { row->partial = 1; return; }
    if (percentage(statistics, CFSTR("Device Utilization %"), &row->utilization[UTIL], &row->partial)
        || percentage(statistics, CFSTR("GPU Activity(%)"), &row->utilization[UTIL], &row->partial)) row->present |= 1u << UTIL;
    if (percentage(statistics, CFSTR("Renderer Utilization %"), &row->utilization[RENDER], &row->partial)) row->present |= 1u << RENDER;
    if (percentage(statistics, CFSTR("Tiler Utilization %"), &row->utilization[TILER], &row->partial)) row->present |= 1u << TILER;
    if (bytes(statistics, CFSTR("vramUsedBytes"), &row->memory[USED-3], &row->partial)) {
        row->present |= 1u << USED;
        int64_t free_bytes;
        if (bytes(statistics, CFSTR("vramFreeBytes"), &free_bytes, &row->partial)) {
            if (free_bytes <= LUA_MAXINTEGER - row->memory[USED-3]) {
                row->memory[TOTAL-3] = row->memory[USED-3] + free_bytes; row->present |= 1u << TOTAL;
            } else row->partial = 1;
        }
    } else if (bytes(statistics, CFSTR("In use system memory"), &row->memory[USED-3], &row->partial)) {
        row->memory[SHARED-3] = row->memory[USED-3]; row->present |= (1u << USED) | (1u << SHARED);
        if (bytes(statistics, CFSTR("Alloc system memory"), &row->memory[ALLOCATED-3], &row->partial)) {
            if (row->memory[ALLOCATED-3] >= row->memory[USED-3]) row->present |= 1u << ALLOCATED;
            else row->partial = 1;
        }
    }
}

static int capture(struct gpu_rows *capture) {
    io_iterator_t iterator = 0;
    CFMutableDictionaryRef matching = IOServiceMatching("IOAccelerator");
    capture->identity_complete = 1;
    if (!matching) return 0;
    kern_return_t status = IOServiceGetMatchingServices(MACH_PORT_NULL, matching, &iterator);
    if (status != KERN_SUCCESS || !iterator) { if (iterator) IOObjectRelease(iterator); return 0; }
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        if (capture->scanned == MAX_ACCELERATORS) {
            capture->partial = capture->truncated = 1; capture->identity_complete = 0;
            IOObjectRelease(entry); break;
        }
        uint64_t id = 0, parent = 0, after = 0, after_parent = 0;
        int bus = 0, after_bus = 0;
        unsigned scan = capture->scanned++;
        if (!wtop_registry_id(entry, &id)) goto invalid;
        capture->seen[scan] = id;
        for (unsigned i = 0; i < scan; ++i) if (capture->seen[i] == id) {
            for (unsigned j = 0; j < capture->count; ++j)
                if (capture->rows[j].id == id) capture->rows[j].valid = 0;
            goto invalid;
        }
        if (capture->count == MAX_GPUS) {
            capture->partial = capture->truncated = 1; capture->identity_complete = 0;
            IOObjectRelease(entry); continue;
        }
        if (!wtop_registry_parent(entry, id, &parent, &bus)) goto invalid;
        CFMutableDictionaryRef properties = NULL, confirmed = NULL;
        struct gpu_row row; memset(&row, 0, sizeof(row));
        struct gpu_identity after_identity;
        kern_return_t result = IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0);
        if (result != KERN_SUCCESS || !properties) { if (properties) CFRelease(properties); goto invalid; }
        row.partial = !identity(properties, &row.identity);
        metrics(properties, &row);
        result = IORegistryEntryCreateCFProperties(entry, &confirmed, kCFAllocatorDefault, 0);
        int consistent = result == KERN_SUCCESS && confirmed;
        if (consistent) {
            (void)identity(confirmed, &after_identity);
            consistent = !memcmp(&row.identity, &after_identity, sizeof(after_identity))
                && wtop_registry_id(entry, &after) && after == id
                && wtop_registry_parent(entry, id, &after_parent, &after_bus)
                && parent == after_parent && bus == after_bus;
        }
        if (confirmed) CFRelease(confirmed);
        CFRelease(properties);
        if (!consistent) goto invalid;
        row.id = id; row.parent = parent; row.bus = bus; row.valid = 1;
        capture->rows[capture->count++] = row;
        if (row.partial) capture->partial = 1;
        IOObjectRelease(entry); continue;
invalid:
        capture->partial = 1; capture->identity_complete = 0; IOObjectRelease(entry);
    }
    if (!IOIteratorIsValid(iterator)) { capture->partial = 1; capture->identity_complete = 0; }
    IOObjectRelease(iterator);
    return 1;
}
static int current(const struct gpu_row *row) {
    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(row->id);
    if (!matching) return 0;
    io_registry_entry_t entry = IOServiceGetMatchingService(MACH_PORT_NULL, matching);
    if (!entry) return 0;
    uint64_t id = 0, parent = 0;
    int bus = 0;
    int valid = wtop_registry_id(entry, &id) && id == row->id
        && wtop_registry_parent(entry, id, &parent, &bus) && parent == row->parent && bus == row->bus;
    IOObjectRelease(entry);
    return valid;
}
static int compare(const void *left, const void *right) {
    const struct gpu_row *a = left, *b = right;
    return (a->id > b->id) - (a->id < b->id);
}
int wtop_collect_gpu(lua_State *L) {
    struct gpu_rows *rows = lua_newuserdatauv(L, sizeof(*rows), 0);
    memset(rows, 0, sizeof(*rows));
    if (!capture(rows)) { lua_pushnil(L); lua_pushliteral(L, "IOAccelerator is unavailable"); return 2; }
    qsort(rows->rows, rows->count, sizeof(rows->rows[0]), compare);
    struct gpu_row *apple = NULL;
    unsigned apples = 0;
    for (unsigned i = 0; i < rows->count; ++i) {
        struct gpu_row *row = &rows->rows[i];
        if (row->valid && row->identity.has_vendor && row->identity.vendor == 0x106b && !row->bus) { apple = row; ++apples; }
    }
    struct wtop_gpu_frequency frequency = {0};
    int clock = wtop_gpu_frequency(apples == 1 && rows->identity_complete ? apple->id : 0, &frequency);
    if (apples == 1 && rows->identity_complete) {
        if (!current(apple)) { apple->valid = 0; rows->partial = 1; }
        else if (clock && isfinite(frequency.mean) && frequency.mean >= 0 && frequency.mean <= 1e11
            && isfinite(frequency.active) && frequency.active >= 0 && frequency.active <= 1
            && frequency.minimum > 0 && frequency.maximum >= frequency.minimum && frequency.maximum <= UINT64_C(100000000000)
            && (frequency.mean == 0 || (frequency.mean >= frequency.minimum && frequency.mean <= frequency.maximum))) {
            apple->frequency = frequency; apple->has_frequency = 1;
        }
    }
    /* No OS references owned by this invocation survive any Lua allocation. */
    lua_createtable(L, 0, 6);
    string_field(L, "schema", "dev.waterrun.wtop.gpu/v2");
    boolean_field(L, "truncated", rows->truncated);
    boolean_field(L, "partial", rows->partial);
    string_field(L, "quality", rows->partial ? "partial" : "fresh");
    lua_createtable(L, (int)rows->count, 0);
    unsigned output = 1;
    for (unsigned i = 0; i < rows->count; ++i) {
        const struct gpu_row *row = &rows->rows[i];
        if (!row->valid) continue;
        char id[40], value[16];
        snprintf(id, sizeof(id), "ioreg:%llu", (unsigned long long)row->id);
        lua_createtable(L, 0, 16);
        string_field(L, "id", id); string_field(L, "card", id); string_field(L, "stable_id", id);
        string_field(L, "_registry_entry_id", id);
        string_field(L, "identity_quality", rows->identity_complete ? "fresh" : "partial");
        string_field(L, "source", "iokit:IOAccelerator");
        boolean_field(L, "partial", row->partial);
        if (row->parent) {
            snprintf(id, sizeof(id), "ioreg:%llu", (unsigned long long)row->parent);
            string_field(L, "_registry_parent_id", id);
            string_field(L, "_registry_parent_bus", row->bus == WTOP_REGISTRY_PCI ? "pci" : "usb");
        }
        if (row->identity.has_vendor) {
            snprintf(value, sizeof(value), "0x%04x", row->identity.vendor);
            string_field(L, "vendor_id", value); string_field(L, "vendor", value);
        }
        if (row->identity.has_product) { snprintf(value, sizeof(value), "0x%04x", row->identity.product); string_field(L, "device_id", value); }
        string_field(L, "vendor_name", row->identity.has_vendor && row->identity.vendor == 0x106b ? "Apple"
            : row->identity.vendor == 0x1002 ? "AMD" : row->identity.vendor == 0x8086 ? "Intel"
            : row->identity.vendor == 0x10de ? "NVIDIA" : "Unknown");
        if (row->identity.model[0]) string_field(L, "model_name", row->identity.model);
        if (row->identity.driver[0]) string_field(L, "driver", row->identity.driver);
        if (row->identity.cores) integer_field(L, "core_count", row->identity.cores);
        lua_createtable(L, 0, 14);
        static const char *names[] = { "utilization_percent", "renderer_utilization_percent", "tiler_utilization_percent",
            "memory_used_bytes", "memory_total_bytes", "shared_memory_used_bytes", "shared_memory_allocated_bytes" };
        for (unsigned field = 0; field <= ALLOCATED; ++field) if (row->present & (1u << field)) {
            if (field < 3) number_field(L, names[field], row->utilization[field]);
            else integer_field(L, names[field], row->memory[field-3]);
        }
        if (row->present & (1u << UTIL)) string_field(L, "utilization_source", "iokit");
        if (row->has_frequency) {
            if (row->frequency.mean > 0) integer_field(L, "frequency_current_hz", (lua_Integer)row->frequency.mean);
            integer_field(L, "frequency_minimum_hz", (lua_Integer)row->frequency.minimum);
            integer_field(L, "frequency_maximum_hz", (lua_Integer)row->frequency.maximum);
            number_field(L, "active_residency_percent", row->frequency.active * 100);
            string_field(L, "frequency_source_kind", "ioreport:GPUPH");
            string_field(L, "frequency_domain", "GPUPH");
        }
        lua_setfield(L, -2, "metrics");
        if (row->has_frequency) {
            lua_createtable(L, 0, 1);
            lua_createtable(L, 1, 0);
            lua_createtable(L, 0, 6);
            string_field(L, "id", "GPUPH");
            string_field(L, "source_kind", "ioreport_residency");
            string_field(L, "source", "pmgr:voltage-states9-sram");
            string_field(L, "quality", row->frequency.mean > 0 ? "estimated" : "unavailable");
            if (row->frequency.mean > 0) integer_field(L, "current_hz", (lua_Integer)row->frequency.mean);
            integer_field(L, "hardware_minimum_hz", (lua_Integer)row->frequency.minimum);
            integer_field(L, "hardware_maximum_hz", (lua_Integer)row->frequency.maximum);
            lua_rawseti(L, -2, 1); lua_setfield(L, -2, "domains");
            lua_setfield(L, -2, "frequencies");
        }
        lua_createtable(L, 0, 4);
        string_field(L, "identity", rows->identity_complete ? "fresh" : "partial");
        string_field(L, "utilization", row->present & (1u << UTIL) ? "fresh" : "unavailable");
        string_field(L, "memory", row->present & (1u << USED) ? "fresh" : "unavailable");
        string_field(L, "frequency", row->has_frequency ? "estimated" : "unavailable");
        lua_setfield(L, -2, "quality");
        lua_createtable(L, 0, 4);
        boolean_field(L, "utilization", row->present & (1u << UTIL));
        boolean_field(L, "memory", row->present & (1u << USED));
        boolean_field(L, "frequency", row->has_frequency);
        boolean_field(L, "process_usage", 0);
        lua_setfield(L, -2, "capabilities");
        lua_createtable(L, 0, 2);
        string_field(L, "quality", "unavailable"); string_field(L, "reason", "per_process_gpu_usage_unavailable");
        lua_setfield(L, -2, "processes");
        lua_rawseti(L, -2, output++);
    }
    lua_setfield(L, -2, "devices");
    if (output == 1) { lua_pop(L, 1); lua_pushnil(L); lua_pushliteral(L, "no_display_adapters"); return 2; }
    lua_createtable(L, 0, 3);
    boolean_field(L, "enabled", 0); string_field(L, "status", "unavailable");
    string_field(L, "reason", "per_process_gpu_usage_unavailable"); lua_setfield(L, -2, "process_scan");
    return 1;
}
