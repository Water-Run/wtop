/* Shared read-only IOKit instance and ancestry checks. */
#ifndef WTOP_MACOS_REGISTRY_H
#define WTOP_MACOS_REGISTRY_H
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <string.h>
#define WTOP_MAX_REGISTRY_ANCESTORS 64
enum { WTOP_REGISTRY_NONE, WTOP_REGISTRY_PCI, WTOP_REGISTRY_USB };

struct wtop_registry_path {
    uint64_t ids[WTOP_MAX_REGISTRY_ANCESTORS + 1];
    unsigned count;
    int bus;
};
static inline int wtop_registry_id(io_registry_entry_t entry, uint64_t *id) {
    *id = 0;
    return IORegistryEntryInPlane(entry, kIOServicePlane)
        && IORegistryEntryGetRegistryEntryID(entry, id) == KERN_SUCCESS && *id;
}

/* GetParentEntry returns the first parent. Refuse multiple parents rather
 * than silently treating that first attachment as an unambiguous edge. */
static inline int wtop_registry_unique_parent(io_registry_entry_t entry, io_registry_entry_t *parent) {
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

static inline int wtop_registry_path(io_registry_entry_t entry, struct wtop_registry_path *path) {
    io_registry_entry_t cursor = entry;
    memset(path, 0, sizeof(*path));
    if (!wtop_registry_id(entry, &path->ids[0])) return 0;
    path->count = 1;
    while (path->count <= WTOP_MAX_REGISTRY_ANCESTORS) {
        io_registry_entry_t parent = 0;
        uint64_t id;
        int valid = wtop_registry_unique_parent(cursor, &parent);
        if (cursor != entry) IOObjectRelease(cursor);
        if (!valid) return 0;
        if (!parent) return 1;
        if (!wtop_registry_id(parent, &id)) {
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
        if (IOObjectConformsTo(parent, "IOPCIDevice")) path->bus = WTOP_REGISTRY_PCI;
        else if (IOObjectConformsTo(parent, "IOUSBHostDevice")) path->bus = WTOP_REGISTRY_USB;
        if (path->bus) { IOObjectRelease(parent); return 1; }
        cursor = parent;
    }
    if (cursor != entry) IOObjectRelease(cursor);
    return 0;
}

static inline int wtop_registry_parent(io_registry_entry_t entry, uint64_t expected,
    uint64_t *parent, int *bus) {
    struct wtop_registry_path first, second;
    *parent = 0; *bus = WTOP_REGISTRY_NONE;
    if (!wtop_registry_path(entry, &first) || first.ids[0] != expected
        || !wtop_registry_path(entry, &second) || first.count != second.count
        || first.bus != second.bus
        || memcmp(first.ids, second.ids, first.count * sizeof(first.ids[0]))) return 0;
    if (first.bus) { *parent = first.ids[first.count - 1]; *bus = first.bus; }
    return 1;
}

#endif
