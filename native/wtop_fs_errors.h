#ifndef WTOP_FS_ERRORS_H
#define WTOP_FS_ERRORS_H

#include <errno.h>
#include <lua.h>

static void wtop_file_error(lua_State *L, int code, const char *kind) {
    lua_pushstring(L, kind);
    lua_rawseti(L, -2, code);
}

/* Export the compiler's errno values: they differ across Unix systems and
 * architectures. Win32 file APIs return GetLastError, while Lua io uses errno. */
static void wtop_register_file_errors(lua_State *L) {
    lua_createtable(L, 0, 12);
    int errors = lua_gettop(L);

    lua_createtable(L, 0, 5);
    wtop_file_error(L, EPERM, "denied");
    wtop_file_error(L, EACCES, "denied");
    wtop_file_error(L, ENOENT, "missing");
    wtop_file_error(L, ENOTDIR, "missing");
#ifdef ENODATA
    wtop_file_error(L, ENODATA, "unavailable");
#endif
    lua_pushvalue(L, -1);
    lua_setfield(L, errors, "stdio");

#ifdef _WIN32
    lua_pop(L, 1);
    lua_createtable(L, 0, 4);
    wtop_file_error(L, ERROR_ACCESS_DENIED, "denied");
    wtop_file_error(L, ERROR_FILE_NOT_FOUND, "missing");
    wtop_file_error(L, ERROR_PATH_NOT_FOUND, "missing");
    wtop_file_error(L, ERROR_DIRECTORY, "missing");
#endif
    lua_setfield(L, errors, "general");

    lua_createtable(L, 0, 3);
#ifdef _WIN32
    wtop_file_error(L, ERROR_INVALID_PARAMETER, "not_regular");
    wtop_file_error(L, ERROR_FILE_TOO_LARGE, "too_large");
#else
    wtop_file_error(L, EINVAL, "not_regular");
    wtop_file_error(L, EFBIG, "too_large");
    wtop_file_error(L, ELOOP, "symlink");
#endif
    lua_setfield(L, errors, "readfile");

    lua_createtable(L, 0, 1);
#ifndef _WIN32
    wtop_file_error(L, EINVAL, "not_link");
#endif
    lua_setfield(L, errors, "readlink");
    lua_setfield(L, -2, "file_errors");
}

#endif
