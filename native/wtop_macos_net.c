/* Interface counters and IOKit identities are captured across the same read.
 * No MAC address, interface alias or inferred PCI domain establishes a parent. */
#define _DARWIN_C_SOURCE
#include <lua.h>
#include <lauxlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <sys/sysctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <net/if_mib.h>
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "wtop_macos.h"
#include "wtop_macos_registry.h"

#define MAX_INTERFACES 4096
#define MAX_OWNERS 128
#define MAX_REGISTRY_INTERFACES 4096
#define MAX_ROUTE_BYTES (32u * 1024u * 1024u)

struct interface_owner {
    uint64_t id, parent_id;
    unsigned index;
    int bus, valid;
    char name[IFNAMSIZ], driver[160];
};
struct owners { struct interface_owner rows[MAX_OWNERS]; unsigned count; int partial; };
struct interface_row {
    unsigned index, mtu, mask;
    uint64_t speed_mbps, counters[5], registry_id, parent_id;
    int flags, bits, bus, valid, partial, estimated;
    int64_t change_sec, change_usec;
    char name[IFNAMSIZ], address[18], driver[160];
};
struct interface_rows {
    struct interface_row rows[MAX_INTERFACES];
    struct owners before, after;
    unsigned count, total;
    int partial, truncated;
};

static int valid_name(const char *name, size_t length) {
    if (!length || length >= IFNAMSIZ) return 0;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')) return 0;
    }
    return 1;
}
static int registry_name(io_registry_entry_t entry, char *name) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, CFSTR(kIOBSDNameKey), kCFAllocatorDefault, 0);
    name[0] = 0;
    int valid = value && CFGetTypeID(value) == CFStringGetTypeID()
        && CFStringGetCString(value, name, IFNAMSIZ, kCFStringEncodingUTF8)
        && CFStringGetLength(value) == (CFIndex)strlen(name)
        && valid_name(name, strlen(name));
    if (value) CFRelease(value);
    return valid;
}
static void collect_owners(struct owners *out) {
    io_iterator_t iterator = 0;
    CFMutableDictionaryRef matching = IOServiceMatching("IONetworkInterface");
    memset(out, 0, sizeof(*out));
    if (!matching) { out->partial = 1; return; }
    if (IOServiceGetMatchingServices(MACH_PORT_NULL, matching, &iterator)
        != KERN_SUCCESS || !iterator) {
        if (iterator) IOObjectRelease(iterator);
        out->partial = 1; return;
    }
    io_registry_entry_t entry;
    unsigned scanned = 0;
    while ((entry = IOIteratorNext(iterator)) != 0) {
        struct interface_owner row;
        uint64_t after;
        char after_name[IFNAMSIZ];
        memset(&row, 0, sizeof(row));
        if (++scanned > MAX_REGISTRY_INTERFACES) {
            out->partial = 1; IOObjectRelease(entry); break;
        }
        if (out->count >= MAX_OWNERS) { out->partial = 1; IOObjectRelease(entry); continue; }
        if (!wtop_registry_id(entry, &row.id) || !registry_name(entry, row.name)
            || !(row.index = if_nametoindex(row.name))) {
            out->partial = 1; IOObjectRelease(entry); continue;
        }
        row.valid = wtop_registry_parent(entry, row.id, &row.parent_id, &row.bus)
            && wtop_registry_id(entry, &after) && after == row.id
            && registry_name(entry, after_name) && !strcmp(row.name, after_name)
            && if_nametoindex(row.name) == row.index;
        if (!row.valid) out->partial = 1;
        io_registry_entry_t provider = 0;
        if (row.valid && wtop_registry_unique_parent(entry, &provider) && provider) {
            CFTypeRef value = IORegistryEntryCreateCFProperty(provider,
                CFSTR("CFBundleIdentifier"), kCFAllocatorDefault, 0);
            if (value && CFGetTypeID(value) == CFStringGetTypeID())
                if (!CFStringGetCString(value, row.driver, sizeof(row.driver), kCFStringEncodingUTF8)) row.driver[0] = 0;
            if (value) CFRelease(value);
        }
        if (provider) IOObjectRelease(provider);
        out->rows[out->count++] = row;
        IOObjectRelease(entry);
    }
    if (!IOIteratorIsValid(iterator)) {
        out->partial = 1;
        for (unsigned i = 0; i < out->count; ++i) out->rows[i].valid = 0;
    }
    IOObjectRelease(iterator);
}
/* Report ambiguity even for an invalid record: it must not disappear and
 * allow a second record with the same name/index to win the match. */
static const struct interface_owner *owner_for(const struct owners *owners,
    const struct interface_row *row, int *present) {
    const struct interface_owner *found = NULL;
    *present = 0;
    for (unsigned i = 0; i < owners->count; ++i) {
        const struct interface_owner *candidate = &owners->rows[i];
        if (candidate->index == row->index || !strcmp(candidate->name, row->name)) {
            ++*present;
            if (candidate->index == row->index && !strcmp(candidate->name, row->name)
                && candidate->valid) found = candidate;
        }
    }
    return *present == 1 ? found : NULL;
}

static void copy_counters(struct interface_row *row, const struct if_data64 *data) {
    uint64_t values[] = { data->ifi_ibytes, data->ifi_obytes, data->ifi_ierrors,
        data->ifi_oerrors, data->ifi_iqdrops };
    for (unsigned i = 0; i < 5; ++i) {
        if (values[i] <= (uint64_t)LUA_MAXINTEGER) {
            row->counters[i] = values[i]; row->mask |= 1u << i;
        } else row->partial = 1;
    }
    row->mtu = data->ifi_mtu;
    row->speed_mbps = data->ifi_baudrate / 1000000;
    row->change_sec = data->ifi_lastchange.tv_sec;
    row->change_usec = data->ifi_lastchange.tv_usec;
}
static void parse_routes(struct interface_rows *all, const char *buffer, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        struct { uint16_t ifm_msglen; uint8_t ifm_version, ifm_type; } header;
        if (length - offset < sizeof(header)) { all->partial = 1; break; }
        memcpy(&header, buffer + offset, sizeof(header));
        if (header.ifm_msglen < sizeof(header) || header.ifm_msglen > length - offset) {
            all->partial = 1; break;
        }
        const char *payload = buffer + offset;
        offset += header.ifm_msglen;
        if (header.ifm_version != RTM_VERSION) { all->partial = 1; continue; }
        if (header.ifm_type != RTM_IFINFO2) continue;
        ++all->total;
        if (all->count >= MAX_INTERFACES) { all->truncated = 1; continue; }
        struct if_msghdr2 message;
        struct sockaddr_dl link;
        const size_t link_prefix = offsetof(struct sockaddr_dl, sdl_data);
        if (header.ifm_msglen < sizeof(message) + link_prefix) { all->partial = 1; continue; }
        memcpy(&message, payload, sizeof(message));
        memset(&link, 0, sizeof(link));
        memcpy(&link, payload + sizeof(message), link_prefix);
        size_t remaining = header.ifm_msglen - sizeof(message);
        if (!(message.ifm_addrs & RTA_IFP) || !message.ifm_index
            || link.sdl_family != AF_LINK || link.sdl_index != message.ifm_index
            || link.sdl_len < link_prefix || link.sdl_len > remaining
            || (size_t)link.sdl_nlen + link.sdl_alen + link.sdl_slen > link.sdl_len - link_prefix
            || !valid_name(payload + sizeof(message) + link_prefix, link.sdl_nlen)) {
            all->partial = 1; continue;
        }
        struct interface_row row;
        memset(&row, 0, sizeof(row));
        row.index = message.ifm_index; row.flags = message.ifm_flags; row.valid = 1;
        row.mtu = message.ifm_data.ifi_mtu;
        row.speed_mbps = message.ifm_data.ifi_baudrate / 1000000;
        memcpy(row.name, payload + sizeof(message) + link_prefix, link.sdl_nlen);
        if (link.sdl_alen == 6) {
            const unsigned char *mac = (const unsigned char *)payload + sizeof(message) + link_prefix + link.sdl_nlen;
            snprintf(row.address, sizeof(row.address), "%02x:%02x:%02x:%02x:%02x:%02x",
                mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        }
        struct ifmibdata mib;
        size_t mib_length = sizeof(mib);
        int query[] = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)row.index, IFDATA_GENERAL};
        memset(&mib, 0, sizeof(mib));
        int status = sysctl(query, 6, &mib, &mib_length, NULL, 0);
        if (status == 0 && mib_length == sizeof(mib)) {
            row.bits = 64;
            const char *end = memchr(mib.ifmd_name, 0, sizeof(mib.ifmd_name));
            if (!end || !valid_name(mib.ifmd_name, (size_t)(end - mib.ifmd_name))
                || strcmp(mib.ifmd_name, row.name)) row.partial = 1;
            else { copy_counters(&row, &mib.ifmd_data); row.flags = mib.ifmd_flags; row.bits = 64; }
        } else {
            /* XNU rounds byte counters in route messages for ordinary apps.
             * The interface MIB is exact; fallback precision belongs to this
             * interface, not every other row in a mixed sample. */
            copy_counters(&row, &message.ifm_data);
            row.bits = 32; row.estimated = 1; all->partial = 1;
        }
        if (if_nametoindex(row.name) != row.index) { row.mask = 0; row.partial = 1; }
        all->partial |= row.partial;
        all->rows[all->count++] = row;
    }
}
static void bind_owners(struct interface_rows *all) {
    all->partial |= all->before.partial | all->after.partial;
    for (unsigned i = 0; i < all->count; ++i) {
        struct interface_row *row = &all->rows[i];
        int first_count, last_count;
        const struct interface_owner *first = owner_for(&all->before, row, &first_count);
        const struct interface_owner *last = owner_for(&all->after, row, &last_count);
        if (first_count || last_count) {
            if (first && last && first->id == last->id && first->parent_id == last->parent_id
                && first->bus == last->bus && !strcmp(first->driver, last->driver)) {
                row->registry_id = last->id; row->parent_id = last->parent_id; row->bus = last->bus;
                snprintf(row->driver, sizeof(row->driver), "%s", last->driver);
            } else { row->mask = 0; row->partial = all->partial = 1; }
        }
        if (if_nametoindex(row->name) != row->index) { row->mask = 0; row->partial = all->partial = 1; }
        for (unsigned j = i + 1; j < all->count; ++j)
            if (row->index == all->rows[j].index || !strcmp(row->name, all->rows[j].name)) {
                row->valid = all->rows[j].valid = 0; all->partial = 1;
            }
    }
}
static void string_field(lua_State *L, const char *key, const char *value) {
    if (value[0]) { lua_pushstring(L, value); lua_setfield(L, -2, key); }
}
static void integer_field(lua_State *L, const char *key, uint64_t value) {
    lua_pushinteger(L, (lua_Integer)value); lua_setfield(L, -2, key);
}
static void registry_field(lua_State *L, const char *key, uint64_t value) {
    char text[40]; snprintf(text, sizeof(text), "ioreg:%llu", (unsigned long long)value);
    string_field(L, key, text);
}
int wtop_collect_network(lua_State *L) {
    struct interface_rows *all = lua_newuserdatauv(L, sizeof(*all), 0);
    memset(all, 0, sizeof(*all));
    int query[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t needed = 0, length = 0;
    char *buffer = NULL;
    if (sysctl(query, 6, NULL, &needed, NULL, 0) != 0 || !needed || needed > MAX_ROUTE_BYTES - 4096) {
        lua_pushnil(L); lua_pushliteral(L, "sysctl(NET_RT_IFLIST2) size failed"); return 2;
    }
    int captured = 0;
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        size_t capacity = needed + 4096;
        buffer = lua_newuserdatauv(L, capacity, 0);
        collect_owners(&all->before);
        length = capacity;
        if (sysctl(query, 6, buffer, &length, NULL, 0) == 0 && length <= capacity) { captured = 1; break; }
        if ((errno != ENOMEM && errno != ENOBUFS) || length <= capacity || length > MAX_ROUTE_BYTES - 4096) break;
        needed = length;
    }
    if (!captured) { lua_pushnil(L); lua_pushliteral(L, "sysctl(NET_RT_IFLIST2) capture failed"); return 2; }
    parse_routes(all, buffer, length);
    collect_owners(&all->after);
    bind_owners(all);
    /* Owned buffers remain on the Lua stack; OS/CF handles are already closed. */
    lua_createtable(L, 0, 5);
    lua_createtable(L, (int)all->count, 0);
    unsigned pushed = 0;
    static const char *counter_names[] = { "rx_bytes", "tx_bytes", "rx_errors", "tx_errors", "rx_drops" };
    for (unsigned i = 0; i < all->count; ++i) {
        const struct interface_row *row = &all->rows[i];
        if (!row->valid) continue;
        lua_createtable(L, 0, 14);
        string_field(L, "id", row->name); string_field(L, "name", row->name);
        integer_field(L, "ifindex", row->index);
        string_field(L, "operstate", row->flags & IFF_UP && row->flags & IFF_RUNNING ? "up" : "down");
        integer_field(L, "mtu", row->mtu);
        if (row->speed_mbps) integer_field(L, "speed_mbps", row->speed_mbps);
        string_field(L, "address", row->address); string_field(L, "driver", row->driver);
        integer_field(L, "counter_bits", row->bits);
        string_field(L, "counter_source", row->bits == 64 ? "IFMIB_IFDATA" : "NET_RT_IFLIST2");
        string_field(L, "counter_quality", row->partial ? "partial" : row->estimated ? "estimated" : "fresh");
        string_field(L, "source", "sysctl+IOKit");
        if (row->partial) { lua_pushboolean(L, 1); lua_setfield(L, -2, "partial"); }
        if (row->registry_id) registry_field(L, "_registry_entry_id", row->registry_id);
        else {
            char epoch[80]; snprintf(epoch, sizeof(epoch), "%lld:%lld",
                (long long)row->change_sec, (long long)row->change_usec);
            string_field(L, "_interface_last_change", epoch);
        }
        if (row->parent_id) {
            registry_field(L, "_registry_parent_id", row->parent_id);
            string_field(L, "_registry_parent_bus", row->bus == WTOP_REGISTRY_PCI ? "pci" : "usb");
            lua_pushboolean(L, 1); lua_setfield(L, -2, "hardware");
        }
        lua_createtable(L, 0, 5);
        for (unsigned c = 0; c < 5; ++c)
            if (row->mask & (1u << c)) integer_field(L, counter_names[c], row->counters[c]);
        lua_setfield(L, -2, "counters");
        lua_rawseti(L, -2, ++pushed);
    }
    lua_setfield(L, -2, "interfaces");
    integer_field(L, "total", all->total);
    lua_pushboolean(L, all->truncated); lua_setfield(L, -2, "truncated");
    if (all->partial) string_field(L, "quality", "partial");
    return 1;
}
