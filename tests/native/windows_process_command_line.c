/* Exercise the production on-demand command-line detail read. The bulk scan
 * only publishes the image path; this verifies the identity-verified
 * ProcessCommandLineInformation parse and its graceful XP/failure fallbacks. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winternl.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

enum {
    XP = 1, QUERY_FAIL = 2, EMPTY = 4, OVERSIZE = 8, ODD = 16,
    IDENTITY = 32, OPEN_FAIL = 64
};
static unsigned mode;
static uint64_t query_calls, open_calls, close_calls, handle_opens;

#define FIXTURE_START 170000000000000000ULL
static const WCHAR fixture_cmdline[] = L"svc.exe --flag value";

static FARPROC (WINAPI *real_get_proc_address)(HMODULE, LPCSTR);
static HMODULE (WINAPI *real_get_module_handle)(LPCSTR);
static void save_real_api(void) {
    real_get_proc_address = GetProcAddress;
    real_get_module_handle = GetModuleHandleA;
}

static void put64(unsigned char *p, uint64_t v) { memcpy(p, &v, 8); }

static HANDLE WINAPI fake_open(DWORD access, BOOL inherit, DWORD pid) {
    (void)access; (void)inherit; (void)pid;
    ++open_calls;
    if (mode & OPEN_FAIL) { SetLastError(ERROR_ACCESS_DENIED); return NULL; }
    ++handle_opens;
    return (HANDLE)(uintptr_t)1;
}

/* noinline keeps the fake opaque like the real external API; inlining it lets
 * GCC fold the always-TRUE return into unrelated callers and raise a spurious
 * maybe-uninitialized under -Werror. */
static BOOL WINAPI __attribute__((noinline)) fake_times(HANDLE h, FILETIME *c,
    FILETIME *e, FILETIME *k, FILETIME *u) {
    uint64_t start = (mode & IDENTITY) ? FIXTURE_START + 1 : FIXTURE_START;
    (void)h;
    put64((unsigned char *)c, start);
    put64((unsigned char *)e, 0);
    put64((unsigned char *)k, 0);
    put64((unsigned char *)u, 0);
    return TRUE;
}

static BOOL WINAPI fake_close(HANDLE h) {
    assert(h == (HANDLE)(uintptr_t)1);
    ++close_calls;
    return TRUE;
}

static LONG WINAPI fake_query(HANDLE h, ULONG class, void *buffer,
    ULONG length, ULONG *returned) {
    USHORT bytes = (USHORT)(wcslen(fixture_cmdline) * sizeof(WCHAR));
    unsigned char *p = buffer;
    WCHAR *strloc;
    assert(h == (HANDLE)(uintptr_t)1 && class == 60);
    ++query_calls;
    if (mode & QUERY_FAIL) return (LONG)0xc0000001u;
    if (mode & EMPTY) bytes = 0;
    if (mode & OVERSIZE) bytes = 2 * 8192 + 2;
    if (mode & ODD) bytes = 3;
    assert(length >= sizeof(UNICODE_STRING));
    memset(p, 0, length);
    memcpy(p, &bytes, sizeof(bytes));
    memcpy(p + 2, &bytes, sizeof(bytes));
    strloc = (WCHAR *)(p + sizeof(UNICODE_STRING));
    memcpy(p + 4, &strloc, sizeof(strloc));
    if (bytes > 0 && bytes <= 2 * 8192 && !(mode & ODD))
        memcpy(p + sizeof(UNICODE_STRING), fixture_cmdline, bytes);
    *returned = (ULONG)(sizeof(UNICODE_STRING) + bytes);
    return 0;
}

static HMODULE WINAPI module_handle(LPCSTR name) {
    return real_get_module_handle(name);
}

static FARPROC WINAPI resolve_api(HMODULE module, LPCSTR name) {
    if (!strcmp(name, "NtQueryInformationProcess"))
        return (mode & XP) ? NULL : (FARPROC)(void *)fake_query;
    return real_get_proc_address(module, name);
}

#define GetModuleHandleA module_handle
#define GetProcAddress resolve_api
#define OpenProcess fake_open
#define GetProcessTimes fake_times
#define CloseHandle fake_close
#include "../../native/wtop_windows.c"
#undef CloseHandle
#undef GetProcessTimes
#undef OpenProcess
#undef GetProcAddress
#undef GetModuleHandleA

static void collect(lua_State *L, unsigned flags, const char *checks) {
    int status;
    mode = flags;
    lua_settop(L, 0);
    lua_pushcfunction(L, l_collect_process_command_line);
    lua_pushinteger(L, 4242);
    lua_pushinteger(L, (lua_Integer)FIXTURE_START);
    status = lua_pcall(L, 2, 2, 0);
    if (status != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    assert(status == LUA_OK);
    lua_setglobal(L, "reason");
    lua_setglobal(L, "data");
    status = luaL_dostring(L, checks);
    if (status != LUA_OK)
        fprintf(stderr, "mode=%u: %s\n", flags, lua_tostring(L, -1));
    assert(status == LUA_OK);
}

int main(void) {
    lua_State *L;
    save_real_api();
    L = luaL_newstate();
    assert(L);
    luaL_openlibs(L);

    /* Success: the full command line with arguments is parsed from the
     * UNICODE_STRING that follows the header. */
    collect(L, 0,
        "assert(type(data)=='table', 'expected a table');"
        "assert(data.command_line=='svc.exe --flag value',"
        " 'got: '..tostring(data.command_line));"
        "assert(data.source=='NtQueryInformationProcess');assert(reason==nil)");

    /* XP: the query is absent, so the caller is told it is unsupported and
     * keeps the image path. */
    collect(L, XP,
        "assert(data==nil and reason=='command_line_unsupported')");

    /* A failed query, an empty/oversized/odd length all degrade to a reason,
     * never a fabricated or truncated command line. */
    collect(L, QUERY_FAIL,
        "assert(data==nil and reason=='command_line_unavailable')");
    collect(L, EMPTY,
        "assert(data==nil and reason=='command_line_unavailable')");
    collect(L, OVERSIZE,
        "assert(data==nil and reason=='command_line_unavailable')");
    collect(L, ODD,
        "assert(data==nil and reason=='command_line_unavailable')");

    /* A reused PID (creation time no longer matches) is rejected before any
     * command line is read. */
    collect(L, IDENTITY,
        "assert(data==nil and reason=='process_identity_changed')");

    /* A denied open surfaces the OS error, not a crash. */
    collect(L, OPEN_FAIL, "assert(data==nil and type(reason)=='string')");

    assert(query_calls > 0 && open_calls > 0 && close_calls > 0);
    /* Every successfully opened handle is closed on every path. */
    assert(handle_opens == close_calls);
    lua_close(L);
    puts("Windows process command line: parse, XP/failure fallbacks, identity and handle balance passed");
    return 0;
}