#ifndef WTOP_RECORDING_H
#define WTOP_RECORDING_H

/* Private, bounded independent LZ4 blocks. No filesystem or device access. */
#if defined(__GNUC__) && !defined(_WIN32)
#define LZ4LIB_VISIBILITY __attribute__((visibility("hidden")))
#else
#define LZ4LIB_VISIBILITY
#endif
#define LZ4_HEAPMODE 1
#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wconversion"
#pragma GCC diagnostic ignored "-Wsign-conversion"
#pragma GCC diagnostic ignored "-Wshadow"
#endif
#include "vendor/lz4/lz4.c"
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

#define WTOP_RECORDING_MAX_BYTES (64 * 1024 * 1024)

/* Return a normal Lua file stream so indexing stays bounded and seekable.
 * Windows paths use the same UTF-8 conversion as other native file APIs. */
#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#endif

static int l_recording_file_close(lua_State *L) {
    luaL_Stream *stream = (luaL_Stream *)luaL_checkudata(L, 1, LUA_FILEHANDLE);
    FILE *file = stream->f;
    stream->f = NULL;
    return luaL_fileresult(L, fclose(file) == 0, NULL);
}

static int l_recording_open(lua_State *L) {
    size_t length = 0;
    const char *path = luaL_checklstring(L, 1, &length);
    luaL_argcheck(L, length > 0 && memchr(path, '\0', length) == NULL, 1, "invalid recording path");
    luaL_Stream *stream = (luaL_Stream *)lua_newuserdatauv(L, sizeof(*stream), 0);
    stream->f = NULL;
    stream->closef = NULL;
    luaL_setmetatable(L, LUA_FILEHANDLE);
#ifdef _WIN32
    WCHAR *wide = utf8_path(L, 1);
    HANDLE handle = CreateFileW(wide, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD open_error = GetLastError();
    free(wide);
    if (handle == INVALID_HANDLE_VALUE) {
        SetLastError(open_error);
        return push_windows_error(L, "open recording");
    }
    BY_HANDLE_FILE_INFORMATION info;
    if (GetFileType(handle) != FILE_TYPE_DISK || !GetFileInformationByHandle(handle, &info)
        || (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        CloseHandle(handle);
        return luaL_error(L, "recording must be a regular file");
    }
    int fd = _open_osfhandle((intptr_t)handle, _O_RDONLY | _O_BINARY);
    if (fd < 0) { CloseHandle(handle); return luaL_fileresult(L, 0, path); }
    FILE *file = _fdopen(fd, "rb");
    if (file == NULL) { _close(fd); return luaL_fileresult(L, 0, path); }
#else
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return luaL_fileresult(L, 0, path);
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
        close(fd);
        return luaL_error(L, "recording must be a regular file");
    }
    FILE *file = fdopen(fd, "rb");
    if (file == NULL) { close(fd); return luaL_fileresult(L, 0, path); }
#endif
    stream->f = file;
    stream->closef = l_recording_file_close;
    return 1;
}

static int l_recording_compress(lua_State *L) {
    size_t length = 0;
    const char *input = luaL_checklstring(L, 1, &length);
    luaL_argcheck(L, length > 0 && length <= WTOP_RECORDING_MAX_BYTES, 1,
        "recording block must contain 1..67108864 bytes");
    int bound = LZ4_compressBound((int)length);
    luaL_Buffer buffer;
    char *output = luaL_buffinitsize(L, &buffer, (size_t)bound);
    int result = LZ4_compress_default(input, output, (int)length, bound);
    if (result <= 0) return luaL_error(L, "recording compression failed");
    luaL_pushresultsize(&buffer, (size_t)result);
    return 1;
}

static int l_recording_decompress(lua_State *L) {
    size_t length = 0;
    const char *input = luaL_checklstring(L, 1, &length);
    lua_Integer expected = luaL_checkinteger(L, 2);
    luaL_argcheck(L, expected > 0 && expected <= WTOP_RECORDING_MAX_BYTES, 2,
        "invalid recording block output size");
    luaL_argcheck(L, length > 0 && length <= (size_t)LZ4_compressBound((int)expected), 1,
        "invalid compressed recording block size");
    luaL_Buffer buffer;
    char *output = luaL_buffinitsize(L, &buffer, (size_t)expected);
    int result = LZ4_decompress_safe(input, output, (int)length, (int)expected);
    if (result != (int)expected) return luaL_error(L, "invalid compressed recording block");
    luaL_pushresultsize(&buffer, (size_t)result);
    return 1;
}

#include "wtop_recording_license.h"
#endif
