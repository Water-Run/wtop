#define _DEFAULT_SOURCE
#define _BSD_SOURCE
#define _SVID_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static int fixture_open(const char *, int, ...);
static int fixture_stat(int, struct stat *);
static ssize_t fixture_read(int, void *, size_t, off_t);
static int fixture_close(int);
#define open fixture_open
#define fstat fixture_stat
#define pread fixture_read
#define close fixture_close
#undef _DEFAULT_SOURCE
#undef _POSIX_C_SOURCE
#include "../../native/wtop_native.c"
#undef open
#undef fstat
#undef pread
#undef close

enum { OK, DENIED, WRONG_TYPE, WRONG_CPU, READ_ERROR, SHORT_READ, CLOSE_ERROR };
static int scenario, live, opens, reads, closes, serial, clock_mode;

static int fixture_open(const char *path, int flags, ...) {
    assert(strcmp(path, "/dev/cpu/3/msr") == 0);
    assert((flags & O_ACCMODE) == O_RDONLY);
    assert((flags & O_NOFOLLOW) != 0 && (flags & O_CLOEXEC) != 0);
    opens++;
    if (scenario == DENIED) { errno = EACCES; return -1; }
    assert(live == 0); live = 1;
    return 501;
}
static int fixture_stat(int fd, struct stat *value) {
    assert(fd == 501 && live == 1);
    memset(value, 0, sizeof(*value));
    value->st_mode = scenario == WRONG_TYPE ? S_IFREG : S_IFCHR;
    value->st_rdev = makedev(202, scenario == WRONG_CPU ? 4 : 3);
    return 0;
}
static ssize_t fixture_read(int fd, void *bytes, size_t length, off_t offset) {
    assert(fd == 501 && live == 1 && length == 8);
    if (clock_mode) assert(offset == 0xe8 || offset == 0xe7);
    else assert(offset == 0x64f);
    reads++;
    if (scenario == READ_ERROR) { errno = EIO; return -1; }
    memset(bytes, 0, length); ((unsigned char *)bytes)[0] = (unsigned char)++serial;
    return scenario == SHORT_READ ? 4 : 8;
}
static int fixture_close(int fd) {
    assert(fd == 501 && live == 1);
    closes++; live = 0;
    if (scenario == CLOSE_ERROR) { errno = EIO; return -1; }
    return 0;
}

static int allocations_left = -1;
static void *fixture_allocator(void *unused, void *ptr, size_t old, size_t size) {
    (void)unused;
    if (size == 0) { free(ptr); return NULL; }
    if (size > old && allocations_left >= 0) {
        if (allocations_left == 0) return NULL;
        allocations_left--;
    }
    return realloc(ptr, size);
}

static int call(lua_State *L, lua_Integer cpu) {
    lua_settop(L, 1);
    lua_getfield(L, 1, clock_mode ? "read_cpu_clock_counters" : "read_cpu_perf_limits"); lua_pushinteger(L, cpu);
    return lua_pcall(L, 1, LUA_MULTRET, 0);
}

int main(void) {
    lua_State *L = lua_newstate(fixture_allocator, NULL, 0);
    assert(L); luaopen_wtop_native(L);
    assert(call(L, -1) != LUA_OK && opens == 0);
    assert(call(L, 8192) != LUA_OK && opens == 0);
    for (clock_mode = 0; clock_mode <= 1; clock_mode++) {
    int previous_opens=opens;
    assert(call(L,-1)!=LUA_OK && call(L,8192)!=LUA_OK && opens==previous_opens);
    for (scenario = OK; scenario <= CLOSE_ERROR; scenario++) {
        int old_reads = reads, old_closes = closes;
        assert(call(L, 3) == LUA_OK && live == 0);
        if (scenario == OK) {
            assert(lua_type(L, 2) == LUA_TSTRING && lua_rawlen(L, 2) == (clock_mode ? 16u : 8u));
            if (clock_mode) {
                const unsigned char *raw=(const unsigned char *)lua_tostring(L,2);
                assert(raw[8] == (unsigned char)(raw[0]+1u));
                assert(lua_istable(L,3));
                lua_getfield(L,3,"aperf_started_ns");lua_Integer start=lua_tointeger(L,-1);lua_pop(L,1);
                lua_getfield(L,3,"mperf_finished_ns");assert(lua_tointeger(L,-1)>=start && start>0);lua_pop(L,1);
            }
        }
        else {
            assert(lua_isnil(L, 2) && lua_type(L, 3) == LUA_TSTRING);
            assert(lua_tointeger(L, 4) == (scenario == DENIED ? EACCES
                : (scenario == WRONG_TYPE || scenario == WRONG_CPU) ? EINVAL : EIO));
        }
        if (scenario == DENIED || scenario == WRONG_TYPE || scenario == WRONG_CPU)
            assert(reads == old_reads);
        assert(closes == old_closes + (scenario == DENIED ? 0 : 1));
    }
    scenario = OK;
    int failed = 0, succeeded = 0;
    for (int budget = 0; budget < 12; budget++) {
        lua_settop(L, 1); lua_getfield(L, 1, clock_mode ? "read_cpu_clock_counters" : "read_cpu_perf_limits"); lua_pushinteger(L, 3);
        allocations_left = budget;
        int result = lua_pcall(L, 1, LUA_MULTRET, 0);
        allocations_left = -1;
        assert(live == 0);
        if (result == LUA_OK) succeeded++; else failed++;
    }
    assert(failed > 0 && succeeded > 0);
    }
    lua_close(L); assert(live == 0);
    puts("Linux CPU limit/clock MSRs: fixed read-only registers, device identity, brackets, failures and Lua OOM passed");
    return 0;
}
