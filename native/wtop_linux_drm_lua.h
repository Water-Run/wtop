/* Lua entry for the fixed read-only DRM mode query. Descriptors are closed
 * before constructing Lua tables, including on all API/identity errors. */
#ifndef WTOP_LINUX_DRM_LUA_H
#define WTOP_LINUX_DRM_LUA_H
#include <lua.h>
#include <lauxlib.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include "wtop_linux_drm.h"

static int wtop_linux_read_drm_mode(lua_State *L) {
    size_t name_length;
    const char *name = luaL_checklstring(L, 1, &name_length);
    luaL_argcheck(L, name_length > 0 && !memchr(name, 0, name_length), 1, "invalid card name");
    lua_Integer device_major = luaL_checkinteger(L, 2), device_minor = luaL_checkinteger(L, 3);
    lua_Integer connector = luaL_checkinteger(L, 4);
    char canonical[32], path[64], *end;
    unsigned long index;
    luaL_argcheck(L, strlen(name) <= 20 && !strncmp(name, "card", 4)
        && name[4] >= '0' && name[4] <= '9', 1, "expected a DRM card name");
    errno = 0;index = strtoul(name + 4, &end, 10);
    luaL_argcheck(L, !errno && !*end && index <= 1048575, 1, "invalid DRM card name");
    (void)snprintf(canonical, sizeof(canonical), "card%lu", index);
    luaL_argcheck(L, !strcmp(name, canonical), 1, "expected a canonical DRM card name");
    luaL_argcheck(L, device_major == 226, 2, "expected DRM device major");
    luaL_argcheck(L, device_minor >= 0 && device_minor <= 1048575 && (unsigned long)device_minor == index,
        3, "DRM card minor does not match its name");
    luaL_argcheck(L, connector > 0 && connector <= UINT32_MAX, 4, "invalid DRM connector ID");
    (void)snprintf(path, sizeof(path), "/dev/dri/%s", canonical);
    wtop_drm_modeinfo mode;
    struct stat before, after;
    int status = -1, saved_errno = 0;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW);
    if (fd >= 0) {
        if (!fstat(fd, &before)) {
            status = wtop_drm_mode_read(fd, (unsigned)device_major, (unsigned)device_minor,
                (uint32_t)connector, &mode);
            saved_errno = status < 0 ? errno : 0;
            if (status >= 0 && (lstat(path, &after) || !S_ISCHR(after.st_mode)
                || before.st_dev != after.st_dev || before.st_ino != after.st_ino
                || before.st_rdev != after.st_rdev)) { status = -1; saved_errno = ESTALE; }
        } else saved_errno = errno;
        (void)close(fd);
    } else saved_errno = errno;
    /* No descriptor remains live when Lua starts constructing the result. */
    struct timespec now;
    uint64_t observed = !clock_gettime(CLOCK_MONOTONIC, &now)
        ? (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec : 0;
    const char *state = status == 0 ? "ok" : status == 1 ? "unavailable"
        : saved_errno == ESTALE ? "gap" : saved_errno == EACCES || saved_errno == EPERM ? "denied"
        : saved_errno == ENOENT || saved_errno == ENODEV || saved_errno == ENXIO
            || saved_errno == ENOTTY || saved_errno == EOPNOTSUPP ? "unavailable" : "error";
    lua_createtable(L, 0, 10);
    lua_pushstring(L, state);lua_setfield(L, -2, "status");
    lua_pushliteral(L, "drm-kms");lua_setfield(L, -2, "backend");
    lua_pushinteger(L, (lua_Integer)observed);lua_setfield(L, -2, "observed_at_ns");
    lua_pushinteger(L, device_major);lua_setfield(L, -2, "device_major");
    lua_pushinteger(L, device_minor);lua_setfield(L, -2, "device_minor");
    lua_pushinteger(L, connector);lua_setfield(L, -2, "connector_id");
    if (saved_errno) { lua_pushinteger(L, saved_errno);lua_setfield(L, -2, "errno"); }
    if (status >= 0) { lua_pushboolean(L, status == 0);lua_setfield(L, -2, "configured"); }
    if (status == 0) {
        lua_createtable(L, 0, 8);
#define MODE_INTEGER(key, value) do { lua_pushinteger(L, (lua_Integer)(value)); lua_setfield(L, -2, (key)); } while (0)
        MODE_INTEGER("pixel_width", mode.hdisplay);
        MODE_INTEGER("pixel_height", mode.vdisplay);
        MODE_INTEGER("pixel_clock_hz", (uint64_t)mode.clock * 1000u);
        MODE_INTEGER("horizontal_total", mode.htotal);
        MODE_INTEGER("vertical_total", mode.vtotal);
        MODE_INTEGER("vscan", mode.vscan);
        MODE_INTEGER("flags", mode.flags);
        MODE_INTEGER("approx_refresh_hz", mode.vrefresh);
#undef MODE_INTEGER
        lua_setfield(L, -2, "mode");
    }
    return 1;
}

#endif
