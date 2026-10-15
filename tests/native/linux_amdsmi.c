#define _GNU_SOURCE
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <math.h>
static void *fixture_open(const char *, int);
static int fixture_close(void *);
#define dlopen fixture_open
#define dlclose fixture_close
#include "../../native/wtop_amdsmi.c"
#undef dlopen
#undef dlclose
static int loads, unloads, absent;
static void *fixture_open(const char *name, int flags) {
    /* Verify the official basename, including the underscore. */
    assert(strncmp(name, "libamd_smi.so", 13) == 0);
    if (absent) return NULL;
    void *result = dlopen(name, flags); if (result) loads++;
    return result;
}
static int fixture_close(void *lib) { unloads++; return dlclose(lib); }
static int allocations_left = -1;
static void *allocate(void *unused, void *ptr, size_t old, size_t size) {
    (void)unused;
    if (!size) { free(ptr); return NULL; }
    if (size > old && allocations_left >= 0) {
        if (allocations_left == 0) return NULL;
        allocations_left--;
    }
    return realloc(ptr, size);
}
static int call(lua_State *L) {
    lua_settop(L, 0); lua_pushcfunction(L, wtop_amdsmi_query);
    return lua_pcall(L, 0, LUA_MULTRET, 0);
}
static void text_is(lua_State *L, const char *key, const char *expected) {
    lua_getfield(L, -1, key); const char *got = lua_tostring(L, -1);
    assert(got && strcmp(got, expected) == 0); lua_pop(L, 1);
}
static void number_is(lua_State *L, const char *key, double expected) {
    lua_getfield(L, -1, key); assert(lua_isnumber(L, -1));
    assert(fabs(lua_tonumber(L, -1) - expected) < 0.0001); lua_pop(L, 1);
}
static void missing(lua_State *L, const char *key) {
    lua_getfield(L, -1, key); assert(lua_isnil(L, -1)); lua_pop(L, 1);
}
int main(int argc, char **argv) {
    assert(argc == 3);
    int profile = atoi(argv[1]), variant = atoi(argv[2]);
    void *sdk = dlopen("libamd_smi.so", RTLD_NOW | RTLD_LOCAL); assert(sdk);
    void (*reset)(int) = (void (*)(int))dlsym(sdk, "fixture_reset");
    int (*active)(void) = (int (*)(void))dlsym(sdk, "fixture_active");
    int (*inits)(void) = (int (*)(void))dlsym(sdk, "fixture_inits");
    int (*shutdowns)(void) = (int (*)(void))dlsym(sdk, "fixture_shutdowns");
    int (*queries)(void) = (int (*)(void))dlsym(sdk, "fixture_queries");
    assert(reset && active && inits && shutdowns && queries);
    lua_State *L = lua_newstate(allocate, NULL, 0); assert(L);
    for (int mode = 0; mode <= 23; ++mode) {
        reset(mode); assert(call(L) == LUA_OK);
        assert(!active() && loads == unloads);
        if (variant == 2) {
            assert(lua_isnil(L, 1) && strcmp(lua_tostring(L, 2), "amdsmi_symbols_missing") == 0);
            assert(inits() == 0 && shutdowns() == 0); continue;
        }
        int failure = mode == 1 || mode == 2 || mode == 3 || mode == 4
            || mode == 5 || mode == 6 || mode == 7 || mode == 21;
        if (failure) {
            assert(lua_isnil(L, 1) && lua_isstring(L, 2));
            if (mode == 1) assert(inits() == 1 && shutdowns() == 0);
            else assert(inits() == shutdowns());
            if (mode == 3) assert(queries() == 0);
            continue;
        }
        assert(inits() == 1 && shutdowns() == 1);
        assert(lua_istable(L, 1)); lua_settop(L, 1);
        text_is(L, "status", (mode == 8 || mode == 9 || mode == 10 || mode == 19 || mode == 20) ? "partial" : "ok");
        lua_getfield(L, 1, "devices");
        assert(lua_rawlen(L, 2) == (size_t)((mode == 8 || mode == 9 || mode == 10 || mode == 19) ? 2 : 3));
        lua_rawgeti(L, 2, 1);
        if (variant == 1) { missing(L, "name"); missing(L, "power_watts"); continue; }
        if (mode == 15) { missing(L, "name"); missing(L, "power_watts"); missing(L, "power_limit_watts"); continue; }
        if (mode == 16) { missing(L, "name"); missing(L, "uuid"); missing(L, "driver_version"); }
        else { text_is(L, "name", "AMD SDK fixture 0"); text_is(L, "driver_version", "driver-0"); }
        if (mode == 22) missing(L, "uuid");
        else if (mode != 16) text_is(L, "uuid", "GPU-fixture-0");
        if (mode == 17) missing(L, "pci_bdf");
        else text_is(L, "pci_bdf", "abcd:03:1a.5");
        if (mode == 11) {
            for (int m = 0; m < METRIC_COUNT; ++m) missing(L, metric_names[m]);
            continue;
        }
        number_is(L, "utilization_percent", mode == 12 ? 0 : 71);
        number_is(L, "memory_utilization_percent", mode == 12 ? 0 : 12);
        number_is(L, "temperature_celsius", mode == 12 ? 0 : 58);
        number_is(L, "memory_total_bytes", mode == 12 ? 0 : 24.0 * 1073741824);
        if (mode == 18) missing(L, "memory_used_bytes");
        else number_is(L, "memory_used_bytes", mode == 12 ? 0 : 6.0 * 1073741824);
        if (mode == 14) missing(L, "power_watts");
        else {
            number_is(L, "power_watts", mode == 12 ? 0 : (profile == 232 || mode == 13) ? 47 : 300);
            text_is(L, "power_measurement", (profile == 232 || mode == 13) ? "average" : "current");
        }
        if (mode == 23) missing(L, "power_limit_watts"); else number_is(L, "power_limit_watts", 355.5);
        number_is(L, "graphics_clock_hz", mode == 12 ? 0 : 2510000000.0);
        number_is(L, "graphics_clock_maximum_hz", 2900000000.0);
        number_is(L, "memory_clock_hz", mode == 12 ? 0 : 1050000000.0);
        number_is(L, "fan_speed_percent", mode == 12 ? 0 : 12800.0 / 255);
    }
    if (variant == 2) { lua_close(L); dlclose(sdk); puts("ok: AMD SMI missing required symbol"); return 0; }
    reset(0); absent = 1; assert(call(L) == LUA_OK && lua_isnil(L, 1));
    assert(strcmp(lua_tostring(L, 2), "amdsmi_library_not_found") == 0);
    absent = 0; assert(call(L) == LUA_OK && lua_istable(L, 1)); /* Recover. */
    int errors = 0, completed = 0;
    for (int budget = 0; budget < 170; ++budget) {
        reset(0); allocations_left = budget;
        int status = call(L); allocations_left = -1;
        assert(!active() && loads == unloads && inits() == shutdowns());
        if (status == LUA_ERRMEM) errors++; else { assert(status == LUA_OK); completed++; }
        lua_settop(L, 0); lua_gc(L, LUA_GCCOLLECT);
    }
    assert(errors > 0 && completed > 0);
    lua_close(L); assert(dlclose(sdk) == 0);
    printf("ok: native AMD SMI profile %d variant %d (ABI, units, enumeration, failures, OOM, recovery)\n", profile, variant);
    return 0;
}
