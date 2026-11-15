/* Exercise the production system-info collector's boot/uptime derivation.
 * GetTickCount64 is Vista+, so the XP path must fall back to the
 * SystemTimeOfDayInformation boot time instead of dropping uptime. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    XP = 1, QUERY_FAIL = 2, QUERY_MISMATCH = 4, ZERO_BOOT = 8,
    FUTURE_BOOT = 16, PRE_EPOCH = 32, SHORT_REPLY = 64, LIVE = 128
};
static unsigned mode;
static uint64_t query_calls;

#define UNIX_TICKS 116444736000000000ULL
#define FIXTURE_BOOT_UNIX 1700000000ULL
#define FIXTURE_UPTIME 3600ULL

static FARPROC (WINAPI *real_get_proc_address)(HMODULE, LPCSTR);
static HMODULE (WINAPI *real_get_module_handle)(LPCSTR);
static void save_real_api(void) {
    real_get_proc_address = GetProcAddress;
    real_get_module_handle = GetModuleHandleA;
}

static ULONGLONG WINAPI fake_tick64(void) { return 123456789ULL; }

static void put64(unsigned char *p, uint64_t v) { memcpy(p, &v, 8); }

static LONG WINAPI fake_query(ULONG class, void *buffer, ULONG length,
    ULONG *returned) {
    uint64_t boot = UNIX_TICKS + FIXTURE_BOOT_UNIX * 10000000ULL;
    uint64_t current = boot + FIXTURE_UPTIME * 10000000ULL;
    assert(class == 3);
    ++query_calls;
    if (mode & QUERY_FAIL) return (LONG)0xc0000001u;
    if (mode & QUERY_MISMATCH) {
        *returned = 128;
        return (LONG)0xc0000004u;
    }
    if (mode & ZERO_BOOT) boot = 0;
    if (mode & FUTURE_BOOT) boot = current + 100000000ULL;
    if (mode & PRE_EPOCH) boot = UNIX_TICKS;
    assert(length >= 16);
    memset(buffer, 0, length);
    put64((unsigned char *)buffer, boot);
    put64((unsigned char *)buffer + 8, current);
    *returned = (mode & SHORT_REPLY) ? 8 : 48;
    return 0;
}

static HMODULE WINAPI module_handle(LPCSTR name) {
    return real_get_module_handle(name);
}

static FARPROC WINAPI resolve_api(HMODULE module, LPCSTR name) {
    if (!(mode & LIVE)) {
        if (!strcmp(name, "GetTickCount64"))
            return (mode & XP) ? NULL : (FARPROC)(void *)fake_tick64;
        if (!strcmp(name, "NtQuerySystemInformation"))
            return (FARPROC)(void *)fake_query;
    }
    return real_get_proc_address(module, name);
}

#define GetModuleHandleA module_handle
#define GetProcAddress resolve_api
#include "../../native/wtop_windows.c"
#undef GetProcAddress
#undef GetModuleHandleA

static void collect(lua_State *L, unsigned flags, const char *checks) {
    int status;
    mode = flags;
    lua_settop(L, 0);
    lua_pushcfunction(L, l_collect_system_info);
    status = lua_pcall(L, 0, 1, 0);
    if (status != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    assert(status == LUA_OK);
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

    /* Modern Windows: the tick counter stays the uptime source, and the boot
     * time is published alongside it. */
    collect(L, 0,
        "assert(data.uptime_seconds==123456, 'tick uptime: '..tostring(data.uptime_seconds));"
        "assert(data.boot_time_unix==1700000000, 'boot: '..tostring(data.boot_time_unix));"
        "assert(data.distribution.name=='Windows' and data.kernel.type=='Windows NT')");

    /* XP: no GetTickCount64. Uptime must come from the boot-time query
     * instead of disappearing. */
    collect(L, XP,
        "assert(data.uptime_seconds==3600, 'XP uptime: '..tostring(data.uptime_seconds));"
        "assert(data.boot_time_unix==1700000000)");

    /* A failed or malformed query degrades to absent fields, never a zero
     * uptime or a crash. */
    collect(L, XP | QUERY_FAIL,
        "assert(data.uptime_seconds==nil and data.boot_time_unix==nil)");
    collect(L, XP | QUERY_MISMATCH,
        "assert(data.uptime_seconds==nil and data.boot_time_unix==nil)");
    collect(L, XP | SHORT_REPLY,
        "assert(data.uptime_seconds==nil and data.boot_time_unix==nil)");
    collect(L, XP | ZERO_BOOT,
        "assert(data.uptime_seconds==nil and data.boot_time_unix==nil)");
    collect(L, XP | FUTURE_BOOT,
        "assert(data.uptime_seconds==nil and data.boot_time_unix==nil)");

    /* A boot time exactly at the Unix epoch is not a positive boot time;
     * the strict comparison keeps it out. */
    collect(L, PRE_EPOCH,
        "assert(data.boot_time_unix==nil and data.uptime_seconds==123456)");

    /* With the tick counter present, a failed boot query removes only the
     * boot time, not the uptime. */
    collect(L, QUERY_FAIL,
        "assert(data.uptime_seconds==123456 and data.boot_time_unix==nil)");

    /* Live host: both fields exist and agree with the wall clock. Under Wine
     * the tick counter starts with the wine server while the boot time is the
     * host's, so only plausibility is checked there. */
    {
        int under_wine = real_get_proc_address(
            real_get_module_handle("ntdll.dll"), "wine_get_version") != NULL;
        lua_pushboolean(L, under_wine);
        lua_setglobal(L, "under_wine");
        collect(L, LIVE,
            "assert(type(data.uptime_seconds)=='number' and data.uptime_seconds>0,"
            " 'live uptime missing');"
            "assert(type(data.boot_time_unix)=='number'"
            " and data.boot_time_unix>946684800, 'live boot time missing');"
            "local now=os.time();"
            "assert(data.boot_time_unix<=now+60, 'boot in the future');"
            "if not under_wine then"
            " local drift=math.abs(data.uptime_seconds-(now-data.boot_time_unix));"
            " assert(drift<=120, 'uptime/boot drift '..drift);"
            "end");
    }

    assert(query_calls > 0);
    lua_close(L);
    puts("Windows system info: tick uptime, XP boot-time fallback, query faults and live consistency passed");
    return 0;
}