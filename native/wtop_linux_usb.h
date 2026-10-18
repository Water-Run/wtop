/* Cached USB interface/endpoint attributes. No USB requests or state changes. */
#ifndef WTOP_LINUX_USB_H
#define WTOP_LINUX_USB_H
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <lua.h>
#include <lauxlib.h>

#define WTOP_USB_ENDPOINTS 30
#define WTOP_USB_SCAN 128
#define WTOP_USB_RAW 32
#ifndef WTOP_USB_SNAPSHOT_HOOK
#define WTOP_USB_SNAPSHOT_HOOK(path, stage, index) ((void)0)
#endif

typedef struct { char bytes[WTOP_USB_RAW + 1]; size_t size; int error; } wtop_usb_value;
typedef struct {
    char names[WTOP_USB_ENDPOINTS][6];
    unsigned count;
    int truncated, malformed;
} wtop_usb_roster;
typedef struct {
    int fd, error, identity_known;
    struct stat identity;
    wtop_usb_value values[6];
} wtop_usb_endpoint;
static const char *const wtop_usb_interface_files[] = {
    "bInterfaceNumber", "bAlternateSetting", "bNumEndpoints",
    "bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol"
};
static const char *const wtop_usb_endpoint_files[] = {
    "bLength", "bEndpointAddress", "bmAttributes", "wMaxPacketSize", "bInterval", "interval"
};

static int wtop_usb_same(const struct stat *a, const struct stat *b) {
    return S_ISDIR(b->st_mode) && a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}

/* Attribute descriptors are always closed before any Lua allocation. */
static int wtop_usb_read(int directory, const char *name, char *bytes,
                         size_t capacity, size_t *size) {
    struct stat before, opened;
    int fd, error = 0;
    unsigned interrupts = 0;
    *size = 0;
    if (fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) != 0) return errno;
    if (!S_ISREG(before.st_mode)) return EINVAL;
    fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW);
    if (fd < 0) return errno;
    if (fstat(fd, &opened) != 0) error = errno;
    else if (!S_ISREG(opened.st_mode) || before.st_dev != opened.st_dev
             || before.st_ino != opened.st_ino) error = ESTALE;
    while (!error && *size <= capacity) {
        ssize_t n = read(fd, bytes + *size, capacity + 1 - *size);
        if (n > 0) *size += (size_t)n;
        else if (n == 0) break;
        else if (errno != EINTR || ++interrupts > 16) error = errno;
    }
    if (*size > capacity) error = EFBIG;
    if (close(fd) != 0 && !error) error = errno;
    if (error) *size = 0;
    return error;
}

static wtop_usb_value wtop_usb_attribute(int fd, const char *name) {
    wtop_usb_value value;
    memset(&value, 0, sizeof(value));
    value.error = wtop_usb_read(fd, name, value.bytes, WTOP_USB_RAW, &value.size);
    return value;
}

static int wtop_usb_equal(const wtop_usb_value *a, const wtop_usb_value *b) {
    return a->error == b->error && a->size == b->size
        && (!a->size || memcmp(a->bytes, b->bytes, a->size) == 0);
}

static int wtop_usb_hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static int wtop_usb_name(const char *name) {
    int a, b, address;
    if (strlen(name) != 5 || memcmp(name, "ep_", 3) != 0) return 0;
    a = wtop_usb_hex(name[3]); b = wtop_usb_hex(name[4]);
    if (a < 0 || b < 0) return 0;
    address = a * 16 + b;
    return (address & 0x70) == 0 && (address & 15) != 0;
}

static int wtop_usb_compare_names(const void *a, const void *b) {
    return strcmp((const char *)a, (const char *)b);
}

static int wtop_usb_scan(int fd, wtop_usb_roster *roster) {
    int copy, error = 0;
    unsigned scanned = 0;
    DIR *directory;
    struct dirent *entry;
    memset(roster, 0, sizeof(*roster));
    /* openat creates a fresh directory offset; dup would share the previous scan. */
    copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (copy < 0) return errno;
    directory = fdopendir(copy);
    if (!directory) { error = errno; (void)close(copy); return error; }
    for (;;) {
        errno = 0;
        entry = readdir(directory);
        if (!entry) { error = errno; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (++scanned > WTOP_USB_SCAN) { roster->truncated = 1; break; }
        if (strncmp(entry->d_name, "ep_", 3) != 0) continue;
        if (!wtop_usb_name(entry->d_name)) { roster->malformed = 1; continue; }
        if (roster->count == WTOP_USB_ENDPOINTS) { roster->truncated = 1; break; }
        memcpy(roster->names[roster->count++], entry->d_name, 6);
    }
    if (closedir(directory) != 0 && !error) error = errno;
    qsort(roster->names, roster->count, sizeof(roster->names[0]), wtop_usb_compare_names);
    return error;
}

static int wtop_usb_failure(lua_State *L, int error) {
    lua_pushnil(L);
    lua_pushfstring(L, "cached USB interface: %s", strerror(error));
    lua_pushinteger(L, error);
    if (error == ESTALE) lua_pushliteral(L, "changed"); else lua_pushnil(L);
    return 4;
}

static void wtop_usb_fields(lua_State *L, const wtop_usb_value *values,
                            const char *const *names, int count) {
    int i;
    lua_createtable(L, 0, count);
    for (i = 0; i < count; ++i) {
        if (values[i].error) continue;
        lua_pushlstring(L, values[i].bytes, values[i].size);
        lua_setfield(L, -2, names[i]);
    }
    lua_createtable(L, 0, count);
    for (i = 0; i < count; ++i) {
        if (!values[i].error) continue;
        lua_pushinteger(L, values[i].error);
        lua_setfield(L, -2, names[i]);
    }
    lua_setfield(L, -2, "errors");
}

static int wtop_linux_read_usb_interface(lua_State *L) {
    const char *path;
    size_t path_size, text_size = 0;
    lua_Integer limit = luaL_checkinteger(L, 2);
    int fd = -1, error = 0, text_error = 0;
    unsigned i, j, kept = 0;
    ssize_t target_size = -1, driver_size = -1;
    char target[4096], driver[4096], text[129];
    struct stat identity, current;
    wtop_usb_roster before, after;
    wtop_usb_value fields[6];
    wtop_usb_endpoint endpoints[WTOP_USB_ENDPOINTS];
    luaL_checktype(L, 1, LUA_TSTRING);
    path = luaL_checklstring(L, 1, &path_size);
    luaL_argcheck(L, path_size > 0 && path_size < 4096 && path[0] == '/'
        && !memchr(path, 0, path_size), 1, "absolute NUL-free path required");
    luaL_argcheck(L, limit >= 0 && limit <= WTOP_USB_ENDPOINTS, 2, "limit must be in 0..30");
    memset(endpoints, 0, sizeof(endpoints));
    for (i = 0; i < WTOP_USB_ENDPOINTS; ++i) endpoints[i].fd = -1;

    fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return wtop_usb_failure(L, errno);
    if (fstat(fd, &identity) != 0) { error = errno; goto done; }
    for (i = 0; i < 6; ++i) fields[i] = wtop_usb_attribute(fd, wtop_usb_interface_files[i]);
    text_error = wtop_usb_read(fd, "interface", text, 128, &text_size);
    target_size = readlink(path, target, sizeof(target));
    driver_size = readlinkat(fd, "driver", driver, sizeof(driver));
    WTOP_USB_SNAPSHOT_HOOK(path, 1, 0);
    error = wtop_usb_scan(fd, &before);
    if (error) goto done;
    kept = before.count < (unsigned)limit ? before.count : (unsigned)limit;
    for (i = 0; i < kept; ++i) {
        wtop_usb_endpoint *ep = &endpoints[i];
        if (fstatat(fd, before.names[i], &ep->identity, AT_SYMLINK_NOFOLLOW) == 0) {
            ep->identity_known = S_ISDIR(ep->identity.st_mode);
            ep->error = ep->identity_known ? 0 : EINVAL;
        } else ep->error = errno;
        if (!ep->error) {
            ep->fd = openat(fd, before.names[i], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if (ep->fd < 0) ep->error = errno;
            else if (fstat(ep->fd, &current) != 0) ep->error = errno;
            else if (!wtop_usb_same(&ep->identity, &current)) ep->error = ESTALE;
        }
        if (ep->error == ENOENT || ep->error == ESTALE) { error = ESTALE; goto done; }
        for (j = 0; j < 6; ++j) {
            if (ep->error) endpoints[i].values[j].error = ep->error;
            else ep->values[j] = wtop_usb_attribute(ep->fd, wtop_usb_endpoint_files[j]);
        }
        WTOP_USB_SNAPSHOT_HOOK(path, 2, i);
    }
    WTOP_USB_SNAPSHOT_HOOK(path, 3, 0);
    error = wtop_usb_scan(fd, &after);
    if (error) goto done;
    if (memcmp(&before, &after, sizeof(before)) != 0) { error = ESTALE; goto done; }
    for (i = 0; i < 6; ++i) {
        wtop_usb_value value = wtop_usb_attribute(fd, wtop_usb_interface_files[i]);
        if (!wtop_usb_equal(&fields[i], &value)) { error = ESTALE; goto done; }
    }
    for (i = 0; i < kept; ++i) {
        wtop_usb_endpoint *ep = &endpoints[i];
        if (ep->identity_known && (fstatat(fd, before.names[i], &current, AT_SYMLINK_NOFOLLOW) != 0
                || !wtop_usb_same(&ep->identity, &current))) { error = ESTALE; goto done; }
        if (ep->error) continue;
        for (j = 0; j < 6; ++j) {
            wtop_usb_value value = wtop_usb_attribute(ep->fd, wtop_usb_endpoint_files[j]);
            if (!wtop_usb_equal(&ep->values[j], &value)) { error = ESTALE; goto done; }
        }
    }
    if (stat(path, &current) != 0 || !wtop_usb_same(&identity, &current)) error = ESTALE;
done:
    for (i = 0; i < kept; ++i) if (endpoints[i].fd >= 0) (void)close(endpoints[i].fd);
    (void)close(fd);
    if (error) return wtop_usb_failure(L, error);

    lua_createtable(L, 0, 8);
    wtop_usb_fields(L, fields, wtop_usb_interface_files, 6);
    lua_setfield(L, -2, "fields");
    if (!text_error) { lua_pushlstring(L, text, text_size); lua_setfield(L, -2, "interface"); }
    if (target_size >= 0 && (size_t)target_size < sizeof(target)) {
        lua_pushlstring(L, target, (size_t)target_size); lua_setfield(L, -2, "source_target");
    }
    if (driver_size >= 0 && (size_t)driver_size < sizeof(driver)) {
        lua_pushlstring(L, driver, (size_t)driver_size); lua_setfield(L, -2, "driver_target");
    }
    lua_pushboolean(L, 1); lua_setfield(L, -2, "guarded");
    lua_pushboolean(L, before.truncated || before.count > kept); lua_setfield(L, -2, "truncated");
    lua_pushboolean(L, before.malformed); lua_setfield(L, -2, "malformed_entries");
    lua_pushboolean(L, !before.truncated && !before.malformed); lua_setfield(L, -2, "total_known");
    lua_pushinteger(L, before.count); lua_setfield(L, -2, "total");
    lua_createtable(L, (int)kept, 0);
    for (i = 0; i < kept; ++i) {
        wtop_usb_fields(L, endpoints[i].values, wtop_usb_endpoint_files, 6);
        lua_pushstring(L, before.names[i]); lua_setfield(L, -2, "name");
        lua_rawseti(L, -2, (lua_Integer)i + 1);
    }
    lua_setfield(L, -2, "endpoints");
    return 1;
}
#endif
