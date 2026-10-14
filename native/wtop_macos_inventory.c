/* Bounded IOService inventory. Registry IDs identify an instance until reboot;
 * a BDF without a PCI domain is only a display address, not a global identity. */
#include <lua.h>
#include <lauxlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "wtop_macos.h"

#define MAX_PCI 256
#define MAX_USB 128
#define MAX_ENUMERATED 4096
#define MAX_ANCESTORS 64

enum { BUS_NONE, BUS_PCI, BUS_USB };
struct registry_path {
    uint64_t ids[MAX_ANCESTORS + 1];
    unsigned count;
    int bus;
};
struct bus_row {
    uint64_t entry_id, parent_id;
    uint32_t vendor, product, class_code, revision;
    unsigned has_vendor:1, has_product:1, has_class:1, has_revision:1;
    int parent_bus;
    char candidate[32], identifier[40], vendor_name[160], name[160], driver[160];
};
struct bus_rows {
    struct bus_row pci[MAX_PCI], usb[MAX_USB];
    unsigned pci_count, usb_count, pci_total, usb_total;
    int partial, pci_truncated, usb_truncated;
};

static int registry_id(io_registry_entry_t entry, uint64_t *id) {
    *id = 0;
    return IORegistryEntryInPlane(entry, kIOServicePlane)
        && IORegistryEntryGetRegistryEntryID(entry, id) == KERN_SUCCESS && *id;
}

/* GetParentEntry returns the first parent. Refuse multiple parents rather
 * than silently treating that first attachment as an unambiguous edge. */
static int unique_parent(io_registry_entry_t entry, io_registry_entry_t *parent) {
    io_iterator_t iterator = 0;
    io_registry_entry_t extra;
    *parent = 0;
    if (IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator)
            != KERN_SUCCESS || !iterator) {
        if (iterator) IOObjectRelease(iterator);
        return 0;
    }
    *parent = IOIteratorNext(iterator);
    extra = IOIteratorNext(iterator);
    int valid = IOIteratorIsValid(iterator) && !extra;
    if (extra) IOObjectRelease(extra);
    IOObjectRelease(iterator);
    if (!valid && *parent) { IOObjectRelease(*parent); *parent = 0; }
    return valid;
}

static int registry_path(io_registry_entry_t entry, struct registry_path *path) {
    io_registry_entry_t cursor = entry;
    memset(path, 0, sizeof(*path));
    if (!registry_id(entry, &path->ids[0])) return 0;
    path->count = 1;
    while (path->count <= MAX_ANCESTORS) {
        io_registry_entry_t parent = 0;
        uint64_t id;
        int valid = unique_parent(cursor, &parent);
        if (cursor != entry) IOObjectRelease(cursor);
        if (!valid) return 0;
        if (!parent) return 1;
        if (!registry_id(parent, &id)) {
            /* The registry root belongs to no plane. Recognize the actual
             * root object, without confusing a detached service with it. */
            io_registry_entry_t root = IORegistryGetRootEntry(MACH_PORT_NULL);
            int is_root = root && IOObjectIsEqualTo(parent, root)
                && IORegistryEntryGetRegistryEntryID(parent, &id) == KERN_SUCCESS && id;
            if (root) IOObjectRelease(root);
            IOObjectRelease(parent);
            if (!is_root) return 0;
            path->ids[path->count++] = id;
            return 1;
        }
        for (unsigned i = 0; i < path->count; ++i) {
            if (path->ids[i] == id) { IOObjectRelease(parent); return 0; }
        }
        path->ids[path->count++] = id;
        if (IOObjectConformsTo(parent, "IOPCIDevice")) path->bus = BUS_PCI;
        else if (IOObjectConformsTo(parent, "IOUSBHostDevice")) path->bus = BUS_USB;
        if (path->bus) { IOObjectRelease(parent); return 1; }
        cursor = parent;
    }
    if (cursor != entry) IOObjectRelease(cursor);
    return 0;
}

static int verified_parent(io_registry_entry_t entry, uint64_t expected,
    uint64_t *parent, int *bus) {
    struct registry_path first, second;
    *parent = 0; *bus = BUS_NONE;
    if (!registry_path(entry, &first) || first.ids[0] != expected
        || !registry_path(entry, &second) || first.count != second.count
        || first.bus != second.bus
        || memcmp(first.ids, second.ids, first.count * sizeof(first.ids[0]))) return 0;
    if (first.bus) { *parent = first.ids[first.count - 1]; *bus = first.bus; }
    return 1;
}

static int data32(CFDictionaryRef properties, CFStringRef key, uint32_t *out) {
    CFTypeRef value = CFDictionaryGetValue(properties, key);
    if (!value || CFGetTypeID(value) != CFDataGetTypeID()
        || CFDataGetLength(value) < 4) return 0;
    const UInt8 *bytes = CFDataGetBytePtr(value);
    *out = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8)
        | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
    return 1;
}

static int number32(CFDictionaryRef properties, CFStringRef key, uint32_t *out) {
    CFTypeRef value = CFDictionaryGetValue(properties, key);
    int64_t number;
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()
        || !CFNumberGetValue(value, kCFNumberSInt64Type, &number)
        || number < 0 || number > UINT32_MAX) return 0;
    *out = (uint32_t)number;
    return 1;
}

static int property_text(CFDictionaryRef properties, CFStringRef key,
    char *text, size_t size) {
    CFTypeRef value = CFDictionaryGetValue(properties, key);
    CFStringRef string = NULL;
    int created = 0, valid = 0;
    text[0] = 0;
    if (!value) return 0;
    if (CFGetTypeID(value) == CFStringGetTypeID()) string = value;
    else if (CFGetTypeID(value) == CFDataGetTypeID()) {
        CFIndex length = CFDataGetLength(value);
        const UInt8 *bytes = CFDataGetBytePtr(value);
        if (length <= 0 || length >= (CFIndex)size) return 0;
        while (length && bytes[length - 1] == 0) --length;
        if (!length || memchr(bytes, 0, (size_t)length)) return 0;
        string = CFStringCreateWithBytes(kCFAllocatorDefault, bytes, length,
            kCFStringEncodingUTF8, false);
        created = 1;
    }
    if (string) valid = CFStringGetCString(string, text, (CFIndex)size,
        kCFStringEncodingUTF8) && text[0];
    if (created && string) CFRelease(string);
    if (!valid) text[0] = 0;
    return valid;
}

static const char *vendor_name(uint32_t vendor) {
    switch (vendor) {
        case 0x106b: return "Apple";
        case 0x1002: return "AMD";
        case 0x8086: return "Intel";
        case 0x10de: return "NVIDIA";
        case 0x14e4: return "Broadcom";
        default: return "Unknown";
    }
}

static void collect_bus(struct bus_rows *all, int bus) {
    io_iterator_t iterator = 0;
    struct bus_row *rows = bus == BUS_PCI ? all->pci : all->usb;
    unsigned *count = bus == BUS_PCI ? &all->pci_count : &all->usb_count;
    unsigned *total = bus == BUS_PCI ? &all->pci_total : &all->usb_total;
    int *truncated = bus == BUS_PCI ? &all->pci_truncated : &all->usb_truncated;
    unsigned limit = bus == BUS_PCI ? MAX_PCI : MAX_USB;
    CFMutableDictionaryRef matching = IOServiceMatching(
        bus == BUS_PCI ? "IOPCIDevice" : "IOUSBHostDevice");
    if (!matching) { all->partial = 1; return; }
    if (IOServiceGetMatchingServices(MACH_PORT_NULL, matching, &iterator)
        != KERN_SUCCESS || !iterator) {
        if (iterator) IOObjectRelease(iterator);
        all->partial = 1; return;
    }
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator)) != 0) {
        CFMutableDictionaryRef properties = NULL;
        struct bus_row row;
        uint64_t after;
        uint32_t location;
        memset(&row, 0, sizeof(row));
        ++*total;
        if (*total > MAX_ENUMERATED) {
            *truncated = all->partial = 1;
            IOObjectRelease(entry); break;
        }
        if (*count >= limit) { *truncated = 1; IOObjectRelease(entry); continue; }
        if (!registry_id(entry, &row.entry_id)
            || IORegistryEntryCreateCFProperties(entry, &properties,
                kCFAllocatorDefault, 0) != KERN_SUCCESS || !properties) {
            all->partial = 1;
            if (properties) CFRelease(properties);
            IOObjectRelease(entry); continue;
        }
        if (bus == BUS_PCI) {
            row.has_vendor = data32(properties, CFSTR("vendor-id"), &row.vendor)
                && row.vendor <= 0xffff;
            row.has_product = data32(properties, CFSTR("device-id"), &row.product)
                && row.product <= 0xffff;
            row.has_class = data32(properties, CFSTR("class-code"), &row.class_code)
                && row.class_code <= 0xffffff;
            row.has_revision = data32(properties, CFSTR("revision-id"), &row.revision)
                && row.revision <= 0xff;
            if (data32(properties, CFSTR("reg"), &location))
                snprintf(row.candidate, sizeof(row.candidate), "%02x:%02x.%x",
                    (location >> 16) & 0xff, (location >> 11) & 0x1f,
                    (location >> 8) & 0x7);
            if (row.has_vendor)
                snprintf(row.vendor_name, sizeof(row.vendor_name), "%s", vendor_name(row.vendor));
            if (!property_text(properties, CFSTR("model"), row.name, sizeof(row.name)))
                if (IORegistryEntryGetName(entry, row.name) != KERN_SUCCESS) row.name[0] = 0;
        } else {
            row.has_vendor = number32(properties, CFSTR("idVendor"), &row.vendor)
                && row.vendor <= 0xffff;
            row.has_product = number32(properties, CFSTR("idProduct"), &row.product)
                && row.product <= 0xffff;
            if (number32(properties, CFSTR("locationID"), &location))
                snprintf(row.candidate, sizeof(row.candidate), "%08x", location);
            if (!property_text(properties, CFSTR("kUSBVendorString"), row.vendor_name, sizeof(row.vendor_name)))
                property_text(properties, CFSTR("USB Vendor String"), row.vendor_name, sizeof(row.vendor_name));
            if (!property_text(properties, CFSTR("kUSBProductString"), row.name, sizeof(row.name)))
                property_text(properties, CFSTR("USB Product String"), row.name, sizeof(row.name));
        }
        property_text(properties, CFSTR("CFBundleIdentifier"), row.driver, sizeof(row.driver));
        if (!row.has_vendor || !row.has_product) all->partial = 1;
        if (!verified_parent(entry, row.entry_id, &row.parent_id, &row.parent_bus)) all->partial = 1;
        if (registry_id(entry, &after) && after == row.entry_id) rows[(*count)++] = row;
        else all->partial = 1;
        CFRelease(properties);
        IOObjectRelease(entry);
    }
    if (!IOIteratorIsValid(iterator)) {
        all->partial = 1;
        for (unsigned i = 0; i < *count; ++i) rows[i].parent_id = 0;
    }
    IOObjectRelease(iterator);
    /* Different PCI roots can reuse a domainless BDF. USB location IDs can
     * also be missing or repeated. Preserve every instance without guessing. */
    for (unsigned i = 0; i < *count; ++i) {
        int unique = rows[i].candidate[0] && !*truncated && *total == *count;
        for (unsigned j = 0; j < *count; ++j) {
            if (i != j && rows[i].entry_id == rows[j].entry_id) {
                unique = 0; all->partial = 1;
            }
            if (i != j && !strcmp(rows[i].candidate, rows[j].candidate)) unique = 0;
        }
        if (unique) snprintf(rows[i].identifier, sizeof(rows[i].identifier), "%s", rows[i].candidate);
        else snprintf(rows[i].identifier, sizeof(rows[i].identifier), "ioreg:%llu",
            (unsigned long long)rows[i].entry_id);
    }
}

static void string_field(lua_State *L, const char *key, const char *text) {
    if (text[0]) { lua_pushstring(L, text); lua_setfield(L, -2, key); }
}
static void integer_field(lua_State *L, const char *key, uint32_t value) {
    lua_pushinteger(L, value); lua_setfield(L, -2, key);
}
static void registry_field(lua_State *L, const char *key, uint64_t value) {
    char text[40];
    if (!value) return;
    snprintf(text, sizeof(text), "ioreg:%llu", (unsigned long long)value);
    string_field(L, key, text);
}
static void push_bus(lua_State *L, const struct bus_row *rows, unsigned count,
    unsigned total, int truncated, int bus) {
    lua_createtable(L, 0, 3);
    lua_createtable(L, (int)count, 0);
    for (unsigned i = 0; i < count; ++i) {
        const struct bus_row *row = &rows[i];
        lua_createtable(L, 0, 12);
        string_field(L, bus == BUS_PCI ? "address" : "id", row->identifier);
        if (row->has_vendor) integer_field(L, "vendor_id", row->vendor);
        if (row->has_product) integer_field(L, bus == BUS_PCI ? "device_id" : "product_id", row->product);
        if (row->has_class) integer_field(L, "class_id", row->class_code);
        if (row->has_revision) integer_field(L, "revision", row->revision);
        string_field(L, bus == BUS_PCI ? "vendor_name" : "manufacturer", row->vendor_name);
        string_field(L, bus == BUS_PCI ? "device_name" : "product", row->name);
        string_field(L, "driver", row->driver);
        string_field(L, "source", "IOKit");
        registry_field(L, "_registry_entry_id", row->entry_id);
        registry_field(L, "_registry_parent_id", row->parent_id);
        if (row->parent_id) string_field(L, "_registry_parent_bus",
            row->parent_bus == BUS_PCI ? "pci" : "usb");
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "devices");
    integer_field(L, "total", total);
    lua_pushboolean(L, truncated); lua_setfield(L, -2, "truncated");
}

int wtop_collect_inventory(lua_State *L) {
    /* Allocate owned storage before acquiring OS resources. All IOKit/CF
     * objects are released before result construction can raise a Lua OOM. */
    struct bus_rows *rows = lua_newuserdatauv(L, sizeof(*rows), 0);
    memset(rows, 0, sizeof(*rows));
    collect_bus(rows, BUS_PCI);
    collect_bus(rows, BUS_USB);
    lua_createtable(L, 0, 3);
    push_bus(L, rows->pci, rows->pci_count, rows->pci_total, rows->pci_truncated, BUS_PCI);
    lua_setfield(L, -2, "pci");
    push_bus(L, rows->usb, rows->usb_count, rows->usb_total, rows->usb_truncated, BUS_USB);
    lua_setfield(L, -2, "usb");
    if (rows->partial) string_field(L, "quality", "partial");
    return 1;
}
