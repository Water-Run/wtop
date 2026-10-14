/* Whole-media I/O belongs to the current driver + media instance. BSD names
 * are presentation identifiers and may be reused after detach/attach. */
#include <lua.h>
#include <lauxlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/IOStorageDeviceCharacteristics.h>
#include <IOKit/storage/IOStorageProtocolCharacteristics.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "wtop_macos.h"
#include "wtop_macos_registry.h"

#define MAX_DISKS 256
#define MAX_DISK_DRIVERS 4096
#define MAX_MEDIA_CHILDREN 64

static const char *counter_names[] = { "bytes_read", "bytes_written", "reads",
    "writes", "read_time_ns", "write_time_ns" };
static CFStringRef counter_key(unsigned index) {
    switch (index) {
        case 0: return CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey);
        case 1: return CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey);
        case 2: return CFSTR(kIOBlockStorageDriverStatisticsReadsKey);
        case 3: return CFSTR(kIOBlockStorageDriverStatisticsWritesKey);
        case 4: return CFSTR(kIOBlockStorageDriverStatisticsTotalReadTimeKey);
        default: return CFSTR(kIOBlockStorageDriverStatisticsTotalWriteTimeKey);
    }
}
struct disk_row {
    uint64_t driver_id, media_id, parent_id;
    int parent_bus, valid, partial, has_size, has_removable, removable, rotational;
    unsigned counter_mask;
    int64_t size, counters[6];
    char name[64], model[256], vendor[256], firmware[256], bus[128];
};
struct disk_rows {
    struct disk_row rows[MAX_DISKS];
    unsigned count, total, scanned;
    int partial, truncated;
};

static CFTypeRef property(io_registry_entry_t entry, CFStringRef key, CFTypeID type) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (value && CFGetTypeID(value) != type) { CFRelease(value); value = NULL; }
    return value;
}
static int number(CFTypeRef value, int64_t *out) {
    return value && CFGetTypeID(value) == CFNumberGetTypeID()
        && CFNumberGetValue(value, kCFNumberSInt64Type, out) && *out >= 0;
}
static void text(CFDictionaryRef dictionary, CFStringRef key, char *out, size_t size) {
    CFTypeRef value = dictionary ? CFDictionaryGetValue(dictionary, key) : NULL;
    out[0] = 0;
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()
        || !CFStringGetCString(value, out, (CFIndex)size, kCFStringEncodingUTF8)) {
        out[0] = 0; return;
    }
    size_t length = strlen(out);
    while (length && out[length - 1] == ' ') out[--length] = 0;
}
static int bsd_name(io_registry_entry_t media, char *out, size_t size) {
    CFStringRef name = property(media, CFSTR(kIOBSDNameKey), CFStringGetTypeID());
    out[0] = 0;
    int valid = name && CFStringGetCString(name, out, (CFIndex)size, kCFStringEncodingUTF8)
        && out[0] && CFStringGetLength(name) == (CFIndex)strlen(out);
    for (size_t i = 0; valid && out[i]; ++i) {
        unsigned char c = (unsigned char)out[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')) valid = 0;
    }
    if (name) CFRelease(name);
    if (!valid) out[0] = 0;
    return valid;
}

/* A driver can publish partitions and other services. Read its unique whole
 * IOMedia child; the first child alone does not establish that relationship. */
static int whole_media(io_registry_entry_t driver, io_registry_entry_t *media) {
    io_iterator_t iterator = 0;
    io_registry_entry_t entry;
    unsigned count = 0;
    int valid = 1;
    *media = 0;
    if (IORegistryEntryGetChildIterator(driver, kIOServicePlane, &iterator)
        != KERN_SUCCESS || !iterator) {
        if (iterator) IOObjectRelease(iterator);
        return 0;
    }
    while ((entry = IOIteratorNext(iterator)) != 0) {
        if (++count > MAX_MEDIA_CHILDREN) { IOObjectRelease(entry); valid = 0; break; }
        if (IOObjectConformsTo(entry, "IOMedia")) {
            CFBooleanRef whole = property(entry, CFSTR(kIOMediaWholeKey), CFBooleanGetTypeID());
            if (!whole) valid = 0;
            else if (CFBooleanGetValue(whole)) {
                if (*media) valid = 0;
                else { *media = entry; entry = 0; }
            }
            if (whole) CFRelease(whole);
        }
        if (entry) IOObjectRelease(entry);
    }
    if (!IOIteratorIsValid(iterator)) valid = 0;
    IOObjectRelease(iterator);
    if (!valid && *media) { IOObjectRelease(*media); *media = 0; }
    return valid;
}
static int media_owner(io_registry_entry_t media, uint64_t driver_id) {
    io_registry_entry_t parent = 0;
    uint64_t id;
    int valid = wtop_registry_unique_parent(media, &parent)
        && parent && wtop_registry_id(parent, &id) && id == driver_id;
    if (parent) IOObjectRelease(parent);
    return valid;
}
static int media_whole(io_registry_entry_t media) {
    CFBooleanRef whole = property(media, CFSTR(kIOMediaWholeKey), CFBooleanGetTypeID());
    int valid = whole && CFBooleanGetValue(whole);
    if (whole) CFRelease(whole);
    return valid;
}

static void read_row(io_registry_entry_t driver, io_registry_entry_t media,
    struct disk_row *row) {
    io_registry_entry_t device = 0, after_device = 0;
    CFDictionaryRef statistics = NULL, characteristics = NULL, protocol = NULL;
    CFNumberRef size = NULL;
    CFBooleanRef removable = NULL;
    uint64_t driver_after, media_after, device_id = 0, device_after_id = 0;
    char after_name[64];
    row->rotational = -1;
    if (!wtop_registry_id(driver, &row->driver_id)
        || !wtop_registry_id(media, &row->media_id)
        || !media_owner(media, row->driver_id)
        || !bsd_name(media, row->name, sizeof(row->name))) return;
    statistics = property(driver, CFSTR(kIOBlockStorageDriverStatisticsKey), CFDictionaryGetTypeID());
    for (unsigned i = 0; i < 6; ++i) {
        CFTypeRef value = statistics ? CFDictionaryGetValue(statistics, counter_key(i)) : NULL;
        if (number(value, &row->counters[i])) row->counter_mask |= 1u << i;
        else if (value || i < 4) row->partial = 1;
    }
    size = property(media, CFSTR(kIOMediaSizeKey), CFNumberGetTypeID());
    row->has_size = number(size, &row->size);
    removable = property(media, CFSTR(kIOMediaRemovableKey), CFBooleanGetTypeID());
    if (removable) { row->has_removable = 1; row->removable = CFBooleanGetValue(removable); }
    if (wtop_registry_unique_parent(driver, &device) && device
        && wtop_registry_id(device, &device_id)) {
        characteristics = property(device, CFSTR(kIOPropertyDeviceCharacteristicsKey), CFDictionaryGetTypeID());
        protocol = property(device, CFSTR(kIOPropertyProtocolCharacteristicsKey), CFDictionaryGetTypeID());
        text(characteristics, CFSTR(kIOPropertyProductNameKey), row->model, sizeof(row->model));
        text(characteristics, CFSTR(kIOPropertyVendorNameKey), row->vendor, sizeof(row->vendor));
        text(characteristics, CFSTR(kIOPropertyProductRevisionLevelKey), row->firmware, sizeof(row->firmware));
        text(protocol, CFSTR(kIOPropertyPhysicalInterconnectTypeKey), row->bus, sizeof(row->bus));
        CFTypeRef medium = characteristics ? CFDictionaryGetValue(characteristics,
            CFSTR(kIOPropertyMediumTypeKey)) : NULL;
        if (medium && CFGetTypeID(medium) == CFStringGetTypeID()) {
            if (CFEqual(medium, CFSTR(kIOPropertyMediumTypeSolidStateKey))) row->rotational = 0;
            else if (CFEqual(medium, CFSTR(kIOPropertyMediumTypeRotationalKey))) row->rotational = 1;
        }
    } else row->partial = 1;
    if (!wtop_registry_parent(driver, row->driver_id, &row->parent_id, &row->parent_bus)) row->partial = 1;
    /* Keep statistics only with the same media, BSD name and driver edge.
     * Static identity also needs the same immediate device provider. */
    row->valid = wtop_registry_id(driver, &driver_after) && driver_after == row->driver_id
        && wtop_registry_id(media, &media_after) && media_after == row->media_id
        && media_whole(media)
        && media_owner(media, row->driver_id)
        && bsd_name(media, after_name, sizeof(after_name)) && !strcmp(row->name, after_name);
    if (device_id && (!wtop_registry_unique_parent(driver, &after_device)
        || !after_device || !wtop_registry_id(after_device, &device_after_id)
        || device_after_id != device_id)) row->valid = 0;
    if (statistics) CFRelease(statistics);
    if (characteristics) CFRelease(characteristics);
    if (protocol) CFRelease(protocol);
    if (size) CFRelease(size);
    if (removable) CFRelease(removable);
    if (device) IOObjectRelease(device);
    if (after_device) IOObjectRelease(after_device);
}

static int collect_rows(struct disk_rows *all) {
    io_iterator_t iterator = 0;
    CFMutableDictionaryRef matching = IOServiceMatching(kIOBlockStorageDriverClass);
    if (!matching) return 0;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL, matching, &iterator)
        != KERN_SUCCESS || !iterator) {
        if (iterator) IOObjectRelease(iterator);
        return 0;
    }
    io_registry_entry_t driver;
    while ((driver = IOIteratorNext(iterator)) != 0) {
        io_registry_entry_t media = 0;
        struct disk_row row;
        memset(&row, 0, sizeof(row));
        if (++all->scanned > MAX_DISK_DRIVERS) {
            all->partial = all->truncated = 1; IOObjectRelease(driver); break;
        }
        if (!whole_media(driver, &media)) all->partial = 1;
        else if (media) {
            ++all->total;
            if (all->count >= MAX_DISKS) all->truncated = 1;
            else {
                read_row(driver, media, &row);
                if (!row.valid) all->partial = 1;
                else { all->rows[all->count++] = row; all->partial |= row.partial; }
            }
        }
        if (media) IOObjectRelease(media);
        IOObjectRelease(driver);
    }
    if (!IOIteratorIsValid(iterator)) {
        all->partial = 1;
        for (unsigned i = 0; i < all->count; ++i) all->rows[i].parent_id = 0;
    }
    IOObjectRelease(iterator);
    for (unsigned i = 0; i < all->count; ++i)
        for (unsigned j = i + 1; j < all->count; ++j)
            if (!strcmp(all->rows[i].name, all->rows[j].name)
                || all->rows[i].media_id == all->rows[j].media_id) {
                all->rows[i].valid = all->rows[j].valid = 0; all->partial = 1;
            }
    return 1;
}

static void string_field(lua_State *L, const char *key, const char *value) {
    if (value[0]) { lua_pushstring(L, value); lua_setfield(L, -2, key); }
}
static void integer_field(lua_State *L, const char *key, int64_t value) {
    lua_pushinteger(L, (lua_Integer)value); lua_setfield(L, -2, key);
}
static void registry_field(lua_State *L, const char *key, uint64_t value) {
    char buffer[40];
    snprintf(buffer, sizeof(buffer), "ioreg:%llu", (unsigned long long)value);
    string_field(L, key, buffer);
}

int wtop_collect_disk(lua_State *L) {
    struct disk_rows *all = lua_newuserdatauv(L, sizeof(*all), 0);
    memset(all, 0, sizeof(*all));
    if (!collect_rows(all)) {
        lua_pushnil(L); lua_pushliteral(L, "IOServiceGetMatchingServices failed"); return 2;
    }
    /* No OS resource survives into Lua result construction, including OOM. */
    lua_createtable(L, 0, 4);
    lua_createtable(L, (int)all->count, 0);
    unsigned pushed = 0;
    for (unsigned i = 0; i < all->count; ++i) {
        const struct disk_row *row = &all->rows[i];
        char stable_id[64];
        if (!row->valid) continue;
        lua_createtable(L, 0, 10);
        string_field(L, "id", row->name); string_field(L, "name", row->name);
        snprintf(stable_id, sizeof(stable_id), "ioreg:%llu:%llu",
            (unsigned long long)row->driver_id, (unsigned long long)row->media_id);
        string_field(L, "stable_id", stable_id);
        string_field(L, "identity_quality", "stable");
        string_field(L, "source", "IOKit");
        lua_pushboolean(L, 1); lua_setfield(L, -2, "aggregate");
        if (row->partial) { lua_pushboolean(L, 1); lua_setfield(L, -2, "partial"); }
        if (row->parent_id) {
            registry_field(L, "_registry_parent_id", row->parent_id);
            string_field(L, "_registry_parent_bus", row->parent_bus == WTOP_REGISTRY_PCI ? "pci" : "usb");
        }
        lua_createtable(L, 0, 7);
        string_field(L, "model", row->model); string_field(L, "vendor", row->vendor);
        string_field(L, "firmware", row->firmware); string_field(L, "bus", row->bus);
        if (row->has_size) integer_field(L, "size_bytes", row->size);
        if (row->rotational >= 0) integer_field(L, "rotational", row->rotational);
        if (row->has_removable) { lua_pushboolean(L, row->removable); lua_setfield(L, -2, "removable"); }
        lua_setfield(L, -2, "identity");
        lua_createtable(L, 0, 7);
        for (unsigned c = 0; c < 6; ++c)
            if (row->counter_mask & (1u << c)) integer_field(L, counter_names[c], row->counters[c]);
        if ((row->counter_mask & 0x30) == 0x30) {
            if (row->counters[4] <= INT64_MAX - row->counters[5])
                integer_field(L, "service_time_ns", row->counters[4] + row->counters[5]);
        }
        lua_setfield(L, -2, "counters");
        lua_rawseti(L, -2, ++pushed);
    }
    lua_setfield(L, -2, "devices");
    integer_field(L, "total", all->total);
    lua_pushboolean(L, all->truncated); lua_setfield(L, -2, "truncated");
    if (all->partial) string_field(L, "quality", "partial");
    return 1;
}
