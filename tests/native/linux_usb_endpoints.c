#define _POSIX_C_SOURCE 200809L
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *scenario;
static int recording, live, owned[4096], injected;
static unsigned reads;
static int fail_enabled;
static size_t allocations, fail_at;
static int remember(int fd) {
    if (recording && fd >= 0) { assert(fd < 4096 && !owned[fd]); owned[fd] = 1; ++live; }
    return fd;
}
static int checked_open(const char *path, int flags, ...) {
    assert((flags & O_ACCMODE) == O_RDONLY && (flags & O_DIRECTORY) && (flags & O_CLOEXEC));
    if (!strcmp(scenario, "open-denied")) { errno = EACCES; return -1; }
    return remember(open(path, flags));
}
static int checked_openat(int fd, const char *name, int flags, ...) {
    assert((flags & O_ACCMODE) == O_RDONLY && (flags & O_CLOEXEC));
    if (!(flags & O_DIRECTORY)) assert((flags & O_NONBLOCK) && (flags & O_NOFOLLOW));
    if (!strcmp(scenario, "field-denied") && !strcmp(name, "bmAttributes")) { errno = EACCES; return -1; }
    if (!strcmp(scenario, "fd-limit") && live >= 3) { errno = EMFILE; return -1; }
    return remember(openat(fd, name, flags));
}
static int checked_close(int fd) {
    if (recording) { assert(fd >= 0 && fd < 4096 && owned[fd]); owned[fd] = 0; --live; }
    return close(fd);
}
static DIR *checked_fdopendir(int fd) {
    if (!strcmp(scenario, "directory-memory")) { errno = ENOMEM; return NULL; }
    return fdopendir(fd);
}
static int checked_closedir(DIR *directory) {
    int fd = dirfd(directory);
    assert(recording && fd >= 0 && fd < 4096 && owned[fd]);
    owned[fd] = 0; --live;
    return closedir(directory);
}
static struct dirent *checked_readdir(DIR *directory) {
    if (!strcmp(scenario, "directory-error")) { errno = EIO; return NULL; }
    return readdir(directory);
}
static ssize_t checked_read(int fd, void *bytes, size_t size) {
    assert(recording && fd >= 0 && fd < 4096 && owned[fd]);
    ++reads;
    assert(reads < 10000);
    if (!strcmp(scenario, "interrupt-storm")) { errno = EINTR; return -1; }
    if (!strcmp(scenario, "short-read") && size > 1) size = 1;
    return read(fd, bytes, size);
}
static void hook(const char *path, unsigned stage, unsigned index);
#define open checked_open
#define openat checked_openat
#define close checked_close
#define fdopendir checked_fdopendir
#define closedir checked_closedir
#define readdir checked_readdir
#define read checked_read
#define WTOP_USB_SNAPSHOT_HOOK(path, stage, index) hook(path, stage, index)
#include "../../native/wtop_linux_usb.h"
#undef open
#undef openat
#undef close
#undef fdopendir
#undef closedir
#undef readdir
#undef read

static void write_file(const char *path, const char *value) {
    FILE *file = fopen(path, "wb");
    assert(file && fwrite(value, 1, strlen(value), file) == strlen(value) && fclose(file) == 0);
}
static void hook(const char *path, unsigned stage, unsigned index) {
    char first[8192], second[8192];
    (void)index;
    if (stage != 3 || injected) return;
    injected = 1;
    if (!strcmp(scenario, "alternate-change")) {
        assert(snprintf(first, sizeof(first), "%s/bAlternateSetting", path) > 0); write_file(first, "01\n");
    } else if (!strcmp(scenario, "field-change")) {
        assert(snprintf(first, sizeof(first), "%s/ep_81/bInterval", path) > 0); write_file(first, "02\n");
    } else if (!strcmp(scenario, "class-change")) {
        assert(snprintf(first, sizeof(first), "%s/bInterfaceClass", path) > 0); write_file(first, "ff\n");
    } else if (!strcmp(scenario, "endpoint-replace") || !strcmp(scenario, "alternate-aba")) {
        assert(snprintf(first, sizeof(first), "%s/ep_81", path) > 0);
        assert(snprintf(second, sizeof(second), "%s/old-endpoint", path) > 0);
        assert(rename(first, second) == 0 && mkdir(first, 0700) == 0);
        if (!strcmp(scenario, "alternate-aba")) {
            assert(snprintf(first, sizeof(first), "%s/bAlternateSetting", path) > 0);
            write_file(first, "01\n"); write_file(first, "00\n");
        }
    } else if (!strcmp(scenario, "interface-replace")) {
        assert(snprintf(second, sizeof(second), "%s-old", path) > 0);
        assert(rename(path, second) == 0 && mkdir(path, 0700) == 0);
    } else if (!strcmp(scenario, "endpoint-remove")) {
        assert(snprintf(first, sizeof(first), "%s/ep_81", path) > 0);
        assert(snprintf(second, sizeof(second), "%s/removed-endpoint", path) > 0);
        assert(rename(first, second) == 0);
    } else if (!strcmp(scenario, "endpoint-add")) {
        assert(snprintf(first, sizeof(first), "%s/ep_83", path) > 0); assert(mkdir(first, 0700) == 0);
    } else if (!strcmp(scenario, "attribute-replace")) {
        assert(snprintf(first, sizeof(first), "%s/ep_81/bInterval", path) > 0);
        assert(unlink(first) == 0 && symlink("/dev/zero", first) == 0);
    } else if (!strcmp(scenario,"source-symlink-retarget")) {
        assert(snprintf(second,sizeof(second),"%s-new",path)>0);
        assert(mkdir(second,0700)==0 && unlink(path)==0 && symlink(second,path)==0);
    }
}

static void *allocator(void *ud, void *pointer, size_t old_size, size_t size) {
    (void)ud;
    if (!size) { free(pointer); return NULL; }
    if (recording && size > old_size) {
        /* The native entry cannot expose a live FD to a throwing Lua allocator. */
        assert(live == 0);
        if (fail_enabled && allocations++ >= fail_at) return NULL;
    }
    return realloc(pointer, size);
}
static int call(lua_State *L, const char *path, int limit, int oom) {
    int status;
    lua_settop(L, 0);
    lua_pushcfunction(L, wtop_linux_read_usb_interface);
    if (!strcmp(scenario,"argument-nul")) lua_pushlstring(L,"/tmp\0private",12);
    else if (!strcmp(scenario,"argument-type")) lua_pushinteger(L,42);
    else if (!strcmp(scenario,"argument-relative")) lua_pushliteral(L,"relative");
    else lua_pushstring(L,path);
    if (!strcmp(scenario,"argument-fraction")) lua_pushnumber(L,1.5);
    else if (!strcmp(scenario,"argument-boolean")) lua_pushboolean(L,1);
    else lua_pushinteger(L, limit);
    recording = 1; fail_enabled = oom; allocations = 0; reads = 0; injected = 0;
    status = lua_pcall(L, 2, LUA_MULTRET, 0);
    fail_enabled = recording = 0;
    assert(live == 0);
    return status;
}
int main(int argc, char **argv) {
    lua_State *L;
    int limit, status, changed;
    assert(argc == 4);
    scenario = argv[2]; limit = atoi(argv[3]);
#if LUA_VERSION_NUM >= 505
    L = lua_newstate(allocator, NULL, 0);
#else
    L = lua_newstate(allocator, NULL);
#endif
    assert(L); luaL_openlibs(L);
    status = call(L, argv[1], limit, 0);
    if (!strncmp(scenario,"argument-",9)) {
        assert(status==LUA_ERRRUN);lua_close(L);return 0;
    }
    assert(status == LUA_OK);
    changed = !strcmp(scenario,"alternate-change") || !strcmp(scenario,"field-change")
        || !strcmp(scenario,"class-change") || !strcmp(scenario,"endpoint-replace")
        || !strcmp(scenario,"alternate-aba") || !strcmp(scenario,"interface-replace")
        || !strcmp(scenario,"endpoint-remove") || !strcmp(scenario,"endpoint-add")
        || !strcmp(scenario,"attribute-replace") || !strcmp(scenario,"source-symlink-retarget");
    if (changed) {
        assert(lua_isnil(L, 1) && lua_tointeger(L, 3) == ESTALE);
        assert(!strcmp(lua_tostring(L, 4), "changed"));
    } else if (!strcmp(scenario,"open-denied") || !strcmp(scenario,"directory-memory")
            || !strcmp(scenario,"directory-error") || !strcmp(scenario,"fd-limit")) {
        int expected = !strcmp(scenario,"open-denied") ? EACCES
            : !strcmp(scenario,"directory-memory") ? ENOMEM
            : !strcmp(scenario,"fd-limit") ? EMFILE : EIO;
        assert(lua_isnil(L, 1) && lua_tointeger(L, 3) == expected);
    } else {
        assert(lua_istable(L, 1));
        lua_getfield(L, 1, "guarded"); assert(lua_toboolean(L, -1)); lua_pop(L, 1);
        lua_getfield(L, 1, "endpoints"); assert(lua_istable(L, -1));
        if (!strcmp(scenario,"source-symlink") || !strcmp(scenario,"oom")) {
            lua_getfield(L,1,"source_target");assert(lua_type(L,-1)==LUA_TSTRING);lua_pop(L,1);
            lua_getfield(L,1,"driver_target");assert(!strcmp(lua_tostring(L,-1),"../../drivers/usbhid"));lua_pop(L,1);
        }
        if (!strcmp(scenario,"normal") || !strcmp(scenario,"short-read") || !strcmp(scenario,"oom"))
            assert(lua_rawlen(L, -1) == (size_t)(limit < 3 ? limit : 3));
        if (!strcmp(scenario,"scan-limit")) {
            lua_getfield(L,1,"truncated");assert(lua_toboolean(L,-1));lua_pop(L,1);
            lua_getfield(L,1,"total_known");assert(!lua_toboolean(L,-1));lua_pop(L,1);
        }
        if (!strcmp(scenario,"malformed-name")) { lua_getfield(L, 1,"malformed_entries"); assert(lua_toboolean(L,-1)); lua_pop(L,1); }
        if (!strcmp(scenario,"normal") && limit == 30) {
            lua_rawgeti(L,-1,3);lua_getfield(L,-1,"interval");assert(!strcmp(lua_tostring(L,-1),"125us\n"));lua_pop(L,2);
        }
        if (!strcmp(scenario,"field-denied") || !strcmp(scenario,"attribute-symlink")
                || !strcmp(scenario,"attribute-fifo") || !strcmp(scenario,"oversized-field")) {
            int denied = !strcmp(scenario,"field-denied");
            lua_rawgeti(L,-1,denied ? 1 : 3);lua_getfield(L,-1,"errors");
            lua_getfield(L,-1,denied ? "bmAttributes" : "bInterval");
            assert(lua_tointeger(L,-1) == (denied ? EACCES : !strcmp(scenario,"oversized-field") ? EFBIG : EINVAL));
            lua_pop(L,3);
        }
        if (!strcmp(scenario,"endpoint-symlink")) {
            lua_rawgeti(L,-1,2);lua_getfield(L,-1,"errors");lua_getfield(L,-1,"bLength");
            assert(lua_tointeger(L,-1) == EINVAL);lua_pop(L,3);
        }
    }
    if (!strcmp(scenario, "oom")) {
        unsigned failures = 0;
        for (fail_at = 0; fail_at < 2048; ++fail_at) {
            status = call(L, argv[1], limit, 1);
            if (status == LUA_OK) { assert(lua_istable(L, 1)); break; }
            assert(status == LUA_ERRMEM); ++failures;
            lua_settop(L, 0); lua_gc(L, LUA_GCCOLLECT);
        }
        assert(fail_at < 2048 && failures > 20);
        printf("USB native: %u Lua allocation failure positions, all FDs closed before allocations\n", failures);
    }
    lua_close(L);
    return 0;
}
