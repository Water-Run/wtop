/* Windows disk interfaces, current identities and counters. Query codes that
 * an older host doesn't implement remain optional, with no new hard imports. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <winioctl.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <lua.h>
#include <lauxlib.h>
#include "wtop_windows.h"
#include "wtop_windows_storage.h"

#define MAX_DISKS 256
#define MAX_INTERFACES 1024
#define MAX_DETAIL_BYTES 8192
/* GUID_DEVINTERFACE_DISK, kept local to avoid a UUID library dependency. */
static const GUID disk_interface = { 0x53f56307, 0xb6bf, 0x11d0,
    { 0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b } };

/* Windows 10 added this FILE_ANY_ACCESS query. Older drivers return an error.
 * Declare the layout locally so the XP SDK remains a valid build target. */
#define DISK_NUMBER_EX_QUERY CTL_CODE(IOCTL_STORAGE_BASE, 0x0421, METHOD_BUFFERED, FILE_ANY_ACCESS)
typedef struct {
    DWORD Version, Size, Flags, DeviceType, DeviceNumber;
    GUID DeviceGuid;
    DWORD PartitionNumber;
} disk_number_ex;

typedef struct { DWORD Version, Size; BOOLEAN IncursSeekPenalty; } seek_penalty_descriptor;
typedef struct {
    WCHAR instance[256];
    char vendor[64], model[128], firmware[32], serial[256];
    GUID guid;
    int has_guid;
} disk_key;
typedef struct {
    DWORD number, devinst;
    disk_key key;
    WCHAR parent[256];
    char parent_bus[4];
    int parent_status, descriptor_valid, bus, removable, rotational;
    int has_size, has_performance, partial, ambiguous;
    uint64_t size;
    DISK_PERFORMANCE performance;
    wtop_storage_reading *health;
} disk_row;
typedef struct { disk_key key; uint64_t generation; DWORD number; int present; } disk_cache;
static disk_cache cache[MAX_DISKS];
static uint64_t next_generation, session_started;

typedef struct { HDEVINFO set; } interface_guard;
static int close_interfaces(lua_State *L) {
    interface_guard *guard = (interface_guard *)lua_touserdata(L, 1);
    if (guard && guard->set != INVALID_HANDLE_VALUE) {
        SetupDiDestroyDeviceInfoList(guard->set);
        guard->set = INVALID_HANDLE_VALUE;
    }
    return 0;
}

static void integer_field(lua_State *L, const char *name, lua_Integer value) {
    lua_pushinteger(L, value); lua_setfield(L, -2, name);
}
static void string_field(lua_State *L, const char *name, const char *value) {
    lua_pushstring(L, value); lua_setfield(L, -2, name);
}
static void boolean_field(lua_State *L, const char *name, int value) {
    lua_pushboolean(L, value); lua_setfield(L, -2, name);
}
static void utf8_field(lua_State *L, const char *name, const WCHAR *value) {
    wtop_push_utf8(L, value); lua_setfield(L, -2, name);
}

/* A missing offset is an absent attribute. An invalid, unterminated or too
 * long value is rejected, including serials used only for identity matching. */
static int descriptor_text(char *output, size_t size, const BYTE *base,
    DWORD available, DWORD offset) {
    size_t length = 0, skip = 0;
    output[0] = 0;
    if (!offset) return 1;
    if (offset >= available) return 0;
    while (offset + length < available && base[offset + length]) ++length;
    if (offset + length == available || length >= size) return 0;
    memcpy(output, base + offset, length);
    output[length] = 0;
    while (length && output[length - 1] == ' ') output[--length] = 0;
    while (output[skip] == ' ') ++skip;
    if (skip) memmove(output, output + skip, length - skip + 1);
    return 1;
}

static void read_identity(HANDLE drive, disk_row *row) {
    STORAGE_PROPERTY_QUERY query;
    union { STORAGE_DEVICE_DESCRIPTOR descriptor; BYTE bytes[4096]; } buffer;
    seek_penalty_descriptor penalty;
    disk_number_ex number;
    DWORD returned = 0;
    memset(&query, 0, sizeof(query));
    memset(&buffer, 0, sizeof(buffer));
    query.PropertyId = StorageDeviceProperty;
    query.QueryType = PropertyStandardQuery;
    row->rotational = -1;
    if (DeviceIoControl(drive, IOCTL_STORAGE_QUERY_PROPERTY, &query, sizeof(query),
            &buffer, sizeof(buffer), &returned, NULL)
            && returned >= offsetof(STORAGE_DEVICE_DESCRIPTOR, RawDeviceProperties)
            && returned <= sizeof(buffer)
            && buffer.descriptor.Size >= offsetof(STORAGE_DEVICE_DESCRIPTOR, RawDeviceProperties)
            && buffer.descriptor.Size <= returned) {
        DWORD available = buffer.descriptor.Size;
        int valid = descriptor_text(row->key.vendor, sizeof(row->key.vendor), buffer.bytes,
                available, buffer.descriptor.VendorIdOffset);
        valid &= descriptor_text(row->key.model, sizeof(row->key.model), buffer.bytes,
                available, buffer.descriptor.ProductIdOffset);
        valid &= descriptor_text(row->key.firmware, sizeof(row->key.firmware), buffer.bytes,
                available, buffer.descriptor.ProductRevisionOffset);
        valid &= descriptor_text(row->key.serial, sizeof(row->key.serial), buffer.bytes,
                available, buffer.descriptor.SerialNumberOffset);
        row->descriptor_valid = 1;
        row->bus = (int)buffer.descriptor.BusType;
        row->removable = buffer.descriptor.RemovableMedia != 0;
        if (!valid) row->partial = 1;
    } else row->partial = 1;
    query.PropertyId = (STORAGE_PROPERTY_ID)7; /* StorageDeviceSeekPenaltyProperty */
    memset(&penalty, 0, sizeof(penalty));
    if (DeviceIoControl(drive, IOCTL_STORAGE_QUERY_PROPERTY, &query, sizeof(query),
            &penalty, sizeof(penalty), &returned, NULL)
            && returned >= sizeof(penalty) && returned <= sizeof(penalty)
            && penalty.Size >= sizeof(penalty))
        row->rotational = penalty.IncursSeekPenalty ? 1 : 0;
    memset(&number, 0, sizeof(number));
    if (DeviceIoControl(drive, DISK_NUMBER_EX_QUERY, NULL, 0, &number, sizeof(number),
            &returned, NULL) && returned >= offsetof(disk_number_ex, PartitionNumber)
            && returned <= sizeof(number)
            && number.Size >= offsetof(disk_number_ex, PartitionNumber)
            && number.DeviceType == FILE_DEVICE_DISK
            && number.DeviceNumber == row->number) {
        static const GUID zero;
        if (memcmp(&number.DeviceGuid, &zero, sizeof(zero)) != 0) {
            row->key.guid = number.DeviceGuid;
            row->key.has_guid = 1;
        }
    }
}

static const char *bus_name(int bus) {
    static const char *names[] = { NULL, "SCSI", "ATAPI", "ATA", "IEEE 1394", "SSA",
        "Fibre Channel", "USB", "RAID", "iSCSI", "SAS", "SATA", "SD", "MMC",
        "Virtual", "File-backed virtual", "Storage Spaces", "NVMe" };
    return bus > 0 && bus < (int)(sizeof(names) / sizeof(names[0])) ? names[bus] : NULL;
}

static int same_key(const disk_key *a, const disk_key *b) {
    return wcscmp(a->instance, b->instance) == 0 && a->has_guid == b->has_guid
        && (!a->has_guid || memcmp(&a->guid, &b->guid, sizeof(a->guid)) == 0)
        && strcmp(a->vendor, b->vendor) == 0 && strcmp(a->model, b->model) == 0
        && strcmp(a->firmware, b->firmware) == 0 && strcmp(a->serial, b->serial) == 0;
}

/* Public IDs are opaque and scoped to this monitoring session. Serials and
 * raw PnP IDs remain private; changing a signature gets a new counter epoch. */
static void stable_id(lua_State *L, const disk_row *row, int slot) {
    char text[96];
    if (!session_started) {
        FILETIME created, exited, kernel, user;
        if (GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user))
            session_started = (uint64_t)created.dwHighDateTime << 32 | created.dwLowDateTime;
        else session_started = GetTickCount();
    }
    snprintf(text, sizeof(text), "windows:disk:%lu:%016llx:%llu",
        (unsigned long)GetCurrentProcessId(), (unsigned long long)session_started,
        (unsigned long long)cache[slot].generation);
    string_field(L, "stable_id", text);
    string_field(L, "identity_quality", row->key.has_guid || row->key.serial[0]
        ? "stable" : row->key.instance[0] ? "instance" : "unavailable");
}

static int read_interface(HDEVINFO set, SP_DEVICE_INTERFACE_DATA *interface,
    disk_row *row, int health_mode, int deep, DWORD selected) {
    union { SP_DEVICE_INTERFACE_DETAIL_DATA_W detail; BYTE bytes[MAX_DETAIL_BYTES]; } details;
    SP_DEVINFO_DATA device;
    STORAGE_DEVICE_NUMBER number, confirmed;
    DISK_GEOMETRY_EX geometry;
    DWORD needed = 0, returned = 0;
    HANDLE drive;
    size_t characters, length = 0;
    WCHAR current[256];
    memset(&device, 0, sizeof(device)); device.cbSize = sizeof(device);
    memset(&details, 0, sizeof(details)); details.detail.cbSize = sizeof(details.detail);
    if (!SetupDiGetDeviceInterfaceDetailW(set, interface, &details.detail,
            sizeof(details), &needed, &device) || needed > sizeof(details)
            || needed < offsetof(SP_DEVICE_INTERFACE_DETAIL_DATA_W, DevicePath) + sizeof(WCHAR))
        return 0;
    characters = (needed - offsetof(SP_DEVICE_INTERFACE_DETAIL_DATA_W, DevicePath)) / sizeof(WCHAR);
    while (length < characters && details.detail.DevicePath[length]) ++length;
    if (!length || length == characters) return 0;
    drive = CreateFileW(details.detail.DevicePath, 0,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (drive == INVALID_HANDLE_VALUE) return 0;
    memset(&number, 0, sizeof(number));
    if (!DeviceIoControl(drive, IOCTL_STORAGE_GET_DEVICE_NUMBER, NULL, 0, &number,
            sizeof(number), &returned, NULL) || returned != sizeof(number)
            || number.DeviceType != FILE_DEVICE_DISK || number.DeviceNumber == MAXDWORD) {
        CloseHandle(drive); return 0;
    }
    row->number = number.DeviceNumber;
    if (health_mode && deep && row->number != selected) { CloseHandle(drive); return -1; }
    row->devinst = device.DevInst;
    if (!wtop_pnp_identity(row->devinst, row->key.instance, 256)) row->partial = 1;
    read_identity(drive, row);
    if (health_mode && deep && row->bus != 17) {
        disk_row identity_before = *row;
        CloseHandle(drive);
        drive = CreateFileW(details.detail.DevicePath, GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
        if (drive == INVALID_HANDLE_VALUE) {
            memset(row->health, 0, sizeof(*row->health));
            row->health->deep = 1; row->health->ata_error = GetLastError();
            row->health->temperature_error = row->health->ata_error;
            goto identity_only;
        }
        memset(&row->key, 0, sizeof(row->key));
        wcscpy(row->key.instance, identity_before.key.instance);
        read_identity(drive, row);
        if (!same_key(&identity_before.key, &row->key)) { CloseHandle(drive); return 0; }
    }
    memset(&geometry, 0, sizeof(geometry));
    row->has_size = DeviceIoControl(drive, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, NULL, 0,
        &geometry, sizeof(geometry), &returned, NULL)
        && returned >= offsetof(DISK_GEOMETRY_EX, Data) && returned <= sizeof(geometry)
        && geometry.DiskSize.QuadPart >= 0;
    if (row->has_size) row->size = (uint64_t)geometry.DiskSize.QuadPart;
    row->has_performance = !health_mode && DeviceIoControl(drive, IOCTL_DISK_PERFORMANCE, NULL, 0,
        &row->performance, sizeof(row->performance), &returned, NULL)
        && returned >= offsetof(DISK_PERFORMANCE, QueueDepth) + sizeof(row->performance.QueueDepth)
        && returned <= sizeof(row->performance)
        && row->performance.BytesRead.QuadPart >= 0 && row->performance.BytesWritten.QuadPart >= 0;
    if (!health_mode && !row->has_performance) row->partial = 1;
    if (health_mode) wtop_storage_read(drive, row->health, row->bus, row->number, deep);
    /* The handle's descriptor must still name the same device after queries. */
    if (health_mode) {
        disk_row after = *row;
        memset(&after.key, 0, sizeof(after.key));
        wcscpy(after.key.instance, row->key.instance);
        read_identity(drive, &after);
        if (!same_key(&row->key, &after.key)) { CloseHandle(drive); return 0; }
    }
    memset(&confirmed, 0, sizeof(confirmed));
    if (!DeviceIoControl(drive, IOCTL_STORAGE_GET_DEVICE_NUMBER, NULL, 0, &confirmed,
            sizeof(confirmed), &returned, NULL) || returned != sizeof(confirmed)
            || confirmed.DeviceType != number.DeviceType || confirmed.DeviceNumber != number.DeviceNumber) {
        CloseHandle(drive); return 0;
    }
    CloseHandle(drive);
identity_only:
    row->parent_status = row->key.instance[0]
        ? wtop_pnp_parent(row->devinst, row->key.instance, row->parent, row->parent_bus) : -1;
    if (row->key.instance[0] && (!wtop_pnp_identity(row->devinst, current, 256)
            || wcscmp(current, row->key.instance) != 0)) return 0;
    if (row->parent_status < 0) row->partial = 1;
    return 1;
}

static void time_field(lua_State *L, const char *name, LONGLONG ticks) {
    if (ticks >= 0 && ticks <= LUA_MAXINTEGER / 100)
        integer_field(L, name, (lua_Integer)ticks * 100);
}

static int collect_disks(lua_State *L, int health_mode, int deep, DWORD selected) {
    interface_guard *guard = (interface_guard *)lua_newuserdatauv(L, sizeof(*guard), 0);
    int guard_index = lua_gettop(L);
    guard->set = INVALID_HANDLE_VALUE;
    if (luaL_newmetatable(L, "wtop.disk.interfaces")) {
        lua_pushcfunction(L, close_interfaces); lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, close_interfaces); lua_setfield(L, -2, "__gc");
    }
    lua_setmetatable(L, guard_index);
    lua_toclose(L, guard_index);
    guard->set = SetupDiGetClassDevsW(&disk_interface, NULL, NULL,
        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    HDEVINFO set = guard->set;
    int capacity = 0;
    int count = 0, partial = 0, total = 0, truncated = 0, output = 0;
    unsigned char seen[MAX_DISKS] = { 0 };
    int slots[MAX_DISKS];
    if (set != INVALID_HANDLE_VALUE) {
        for (DWORD index = 0; index < MAX_INTERFACES; ++index) {
            SP_DEVICE_INTERFACE_DATA interface;
            memset(&interface, 0, sizeof(interface)); interface.cbSize = sizeof(interface);
            if (!SetupDiEnumDeviceInterfaces(set, NULL, &disk_interface, index, &interface)) {
                if (GetLastError() != ERROR_NO_MORE_ITEMS) partial = 1;
                break;
            }
            if (capacity < MAX_DISKS) ++capacity;
        }
    }
    /* Allocate for the visible devices rather than the global limit. Lua's
     * close guard also releases SetupAPI if this allocation runs out of RAM. */
    disk_row *rows = (disk_row *)lua_newuserdatauv(L, sizeof(disk_row) * (size_t)capacity, 0);
    wtop_storage_reading *health_rows = health_mode ? lua_newuserdatauv(L,
        sizeof(wtop_storage_reading) * (size_t)capacity, 0) : NULL;
    if (set != INVALID_HANDLE_VALUE) {
        for (DWORD index = 0; index < MAX_INTERFACES; ++index) {
            SP_DEVICE_INTERFACE_DATA interface;
            disk_row row;
            memset(&interface, 0, sizeof(interface)); interface.cbSize = sizeof(interface);
            if (!SetupDiEnumDeviceInterfaces(set, NULL, &disk_interface, index, &interface)) {
                if (GetLastError() != ERROR_NO_MORE_ITEMS) partial = 1;
                break;
            }
            ++total;
            if (index + 1 == MAX_INTERFACES) truncated = 1;
            if (count >= capacity) { truncated = 1; continue; }
            memset(&row, 0, sizeof(row));
            if (health_mode) row.health = &health_rows[count];
            int read = read_interface(set, &interface, &row, health_mode, deep, selected);
            if (read < 0) continue;
            if (!read) { partial = 1; continue; }
            for (int i = 0; i < count; ++i) {
                if (rows[i].number == row.number) {
                    rows[i].ambiguous = row.ambiguous = 1;
                    partial = 1;
                }
            }
            if (row.partial) partial = 1;
            rows[count++] = row;
        }
        SetupDiDestroyDeviceInfoList(set);
        guard->set = INVALID_HANDLE_VALUE;
    } else partial = 1;
    lua_closeslot(L, guard_index);
    /* Reserve every unchanged identity first. At the limit, a replacement
     * must not evict a still-present disk whose row appears later. */
    for (int r = 0; r < count; ++r) {
        slots[r] = -1;
        if (rows[r].ambiguous) continue;
        for (int i = 0; i < MAX_DISKS; ++i) {
            if (cache[i].present && !seen[i] && same_key(&cache[i].key, &rows[r].key)
                    && (rows[r].key.instance[0] || rows[r].key.has_guid || rows[r].key.serial[0]
                        || cache[i].number == rows[r].number)) {
                slots[r] = i; seen[i] = 1; break;
            }
        }
    }
    for (int r = 0; r < count; ++r) {
        if (rows[r].ambiguous || slots[r] >= 0) continue;
        int slot = -1;
        for (int i = 0; i < MAX_DISKS; ++i)
            if (!seen[i] && !cache[i].present) { slot = i; break; }
        if (slot < 0)
            for (int i = 0; i < MAX_DISKS; ++i) if (!seen[i]) { slot = i; break; }
        slots[r] = slot; seen[slot] = 1;
        cache[slot].key = rows[r].key;
        cache[slot].number = rows[r].number;
        cache[slot].generation = ++next_generation;
        cache[slot].present = 1;
    }
    /* All OS handles have been closed before any Lua result allocation. */
    lua_createtable(L, 0, 5);
    lua_createtable(L, count, 0);
    for (int i = 0; i < count; ++i) {
        const disk_row *row = &rows[i];
        char name[64];
        if (row->ambiguous) continue;
        lua_createtable(L, 0, 12);
        snprintf(name, sizeof(name), "PhysicalDrive%lu", (unsigned long)row->number);
        string_field(L, "id", name);
        snprintf(name, sizeof(name), "Disk %lu", (unsigned long)row->number);
        string_field(L, "name", name);
        string_field(L, "source", "SetupAPI:disk");
        boolean_field(L, "aggregate", 1);
        stable_id(L, row, slots[i]);
        /* Private equality proof across I/O and health readers. Never exported. */
        if (row->descriptor_valid && (row->key.has_guid || row->key.serial[0])) {
            disk_key key;
            memset(&key, 0, sizeof(key));
            wcscpy(key.instance, row->key.instance);
            strcpy(key.vendor, row->key.vendor); strcpy(key.model, row->key.model);
            strcpy(key.firmware, row->key.firmware); strcpy(key.serial, row->key.serial);
            key.has_guid = row->key.has_guid;
            if (key.has_guid) key.guid = row->key.guid;
            lua_pushlstring(L, (const char *)&key, sizeof(key));
            lua_setfield(L, -2, "_health_key");
        }
        if (row->partial) boolean_field(L, "partial", 1);
        if (row->key.instance[0]) utf8_field(L, "_pnp_instance_id", row->key.instance);
        if (row->parent_status > 0) {
            utf8_field(L, "_pnp_parent_id", row->parent);
            string_field(L, "_pnp_parent_bus", row->parent_bus);
        }
        lua_createtable(L, 0, 7);
        if (row->key.model[0]) string_field(L, "model", row->key.model);
        if (row->key.vendor[0]) string_field(L, "vendor", row->key.vendor);
        if (row->key.firmware[0]) string_field(L, "firmware", row->key.firmware);
        if (bus_name(row->bus)) string_field(L, "bus", bus_name(row->bus));
        if (row->has_size && row->size <= (uint64_t)LUA_MAXINTEGER)
            integer_field(L, "size_bytes", (lua_Integer)row->size);
        if (row->rotational >= 0) integer_field(L, "rotational", row->rotational);
        if (row->descriptor_valid) boolean_field(L, "removable", row->removable);
        lua_setfield(L, -2, "identity");
        if (health_mode) {
            integer_field(L, "bus_type", row->bus);
            wtop_storage_push(L, row->health); lua_setfield(L, -2, "raw_health");
        }
        if (row->has_performance) {
            const DISK_PERFORMANCE *p = &row->performance;
            lua_createtable(L, 0, 7);
            integer_field(L, "bytes_read", (lua_Integer)p->BytesRead.QuadPart);
            integer_field(L, "bytes_written", (lua_Integer)p->BytesWritten.QuadPart);
            integer_field(L, "reads", (lua_Integer)p->ReadCount);
            integer_field(L, "writes", (lua_Integer)p->WriteCount);
            time_field(L, "read_time_ns", p->ReadTime.QuadPart);
            time_field(L, "write_time_ns", p->WriteTime.QuadPart);
            time_field(L, "idle_time_ns", p->IdleTime.QuadPart);
            lua_setfield(L, -2, "counters");
            integer_field(L, "in_flight", (lua_Integer)p->QueueDepth);
        }
        lua_rawseti(L, -2, ++output);
    }
    if (!partial && !truncated)
        for (int i = 0; i < MAX_DISKS; ++i) if (!seen[i]) cache[i].present = 0;
    lua_setfield(L, -2, "devices");
    integer_field(L, "total", total);
    boolean_field(L, "truncated", truncated);
    if (partial || truncated) string_field(L, "quality", "partial");
    return 1;
}

int wtop_collect_disk(lua_State *L) { return collect_disks(L, 0, 0, MAXDWORD); }

int wtop_collect_disk_health(lua_State *L) {
    int deep = lua_toboolean(L, 1);
    lua_Integer selected = luaL_optinteger(L, 2, -1);
    luaL_argcheck(L, selected >= -1 && selected <= MAXDWORD, 2, "invalid disk number");
    luaL_argcheck(L, !deep || selected >= 0, 2, "deep query requires a selected disk");
    return collect_disks(L, 1, deep, (DWORD)selected);
}
