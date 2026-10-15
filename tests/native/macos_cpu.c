/* Real CPU collectors with adversarial Mach/sysctl replies and owned buffers. */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/host_info.h>
#include <mach/processor_info.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    API_FAIL=1, SHORT=2, LONG=4, NULL_DATA=8, ZERO_COUNT=16, TOO_MANY=32,
    DUPLICATE=64, NEGATIVE_SLOT=128, BAD_RUNNING=256, BAD_MAIN=512,
    CHANGE_SLOT=1024, CHANGE_TYPE=2048, CHANGE_ONLINE=4096, REVERSE=8192,
    COUNT_MISMATCH=16384, HUGE_COUNT=32768, STAT_FAIL=65536, STAT_SHORT=131072,
    SYSCTL_FAIL=262144, BAD_TEXT=524288, EMBEDDED_NUL=1048576,
    BAD_INTEGER=2097152, CACHE_OVERFLOW=4194304, LEVEL_OVERFLOW=8388608,
    BAD_SHARING=16777216, NO_LEVELS=33554432, SHORT_CACHE=67108864,
    CACHE_ARRAY_LONG=134217728, NO_LOGICAL=268435456, CHANGE_ORDER=536870912
};
static unsigned mode, call_number, fault_call, releases, host_gets, host_refs, exit_calls;
static int fail_exit, fail_host, fail_lua, oom_after_release;
static unsigned live_buffers;
static unsigned processor_count = 3;
static int processor_subtype = 3, force_online = -1;
static void (*exit_cleanup)(void);
struct allocation { void *pointer; size_t bytes; };
static struct allocation allocations[3];

static host_t fixture_host(void) {
    ++host_gets;
    if (fail_host) return MACH_PORT_NULL;
    ++host_refs;
    return 42;
}
static kern_return_t fixture_port_release(ipc_space_t task, mach_port_name_t port) {
    assert(task == mach_task_self() && port == 42 && host_refs == 1);
    --host_refs;
    return KERN_SUCCESS;
}
static int fixture_exit(void (*callback)(void)) {
    ++exit_calls;
    if (fail_exit) return -1;
    assert(!exit_cleanup);
    exit_cleanup = callback;
    return 0;
}
static kern_return_t fixture_statistics(host_t host, host_flavor_t flavor,
    host_info_t output, mach_msg_type_number_t *words) {
    assert(host == 42 && flavor == HOST_CPU_LOAD_INFO && *words == HOST_CPU_LOAD_INFO_COUNT);
    host_cpu_load_info_data_t data = {{100, 20, 500, 3}};
    memcpy(output, &data, sizeof(data));
    if (mode & STAT_SHORT) --*words;
    return mode & STAT_FAIL ? KERN_FAILURE : KERN_SUCCESS;
}
static kern_return_t fixture_processors(host_t host, processor_flavor_t flavor,
    natural_t *count, processor_info_array_t *output, mach_msg_type_number_t *words) {
    assert(host == 42);
    ++call_number;
    int fault = !fault_call || fault_call == call_number;
    unsigned flags = fault ? mode : 0;
    unsigned stride = flavor == PROCESSOR_BASIC_INFO ? PROCESSOR_BASIC_INFO_COUNT : PROCESSOR_CPU_LOAD_INFO_COUNT;
    assert(flavor == PROCESSOR_BASIC_INFO || flavor == PROCESSOR_CPU_LOAD_INFO);
    *count = flags & ZERO_COUNT ? 0 : flags & TOO_MANY ? 513 : processor_count;
    if (flags & HUGE_COUNT) *count = UINT32_MAX;
    if ((flags & COUNT_MISMATCH) && flavor == PROCESSOR_CPU_LOAD_INFO) *count = 2;
    *words = flags & HUGE_COUNT ? 3 * stride : *count * stride;
    if (flags & SHORT) --*words;
    if (flags & LONG) ++*words;
    if (flags & NULL_DATA) { *output = NULL; return KERN_SUCCESS; }
    assert(live_buffers < 3);
    size_t bytes = *words * sizeof(integer_t);
    *output = calloc(1, bytes ? bytes : 1); assert(*output);
    allocations[live_buffers++] = (struct allocation){*output, bytes};
    if (!(flags & (SHORT | LONG | ZERO_COUNT | TOO_MANY | HUGE_COUNT))) {
        const int slots[] = {8, 2, 5};
        for (unsigned i = 0; i < *count; ++i) {
            int reversed = (mode & REVERSE) || ((mode & CHANGE_ORDER) && call_number > 1 && flavor == PROCESSOR_BASIC_INFO);
            unsigned index = reversed ? processor_count - 1 - i : i;
            int slot = processor_count == 3 ? slots[index] : (int)index;
            if ((mode & DUPLICATE) && i == 1) slot = slots[0];
            if ((mode & NEGATIVE_SLOT) && i == 1) slot = -1;
            if (flavor == PROCESSOR_BASIC_INFO) {
                processor_basic_info_data_t row = {
                    .cpu_type = 7, .cpu_subtype = processor_subtype,
                    .running = force_online >= 0 ? force_online : slot != 5,
                    .slot_num = slot, .is_master = slot == 8,
                };
                if ((mode & BAD_RUNNING) && i == 1) row.running = 2;
                if ((mode & BAD_MAIN) && i == 1) row.is_master = 2;
                if (call_number > 1 && i == 1) {
                    if (mode & CHANGE_SLOT) row.slot_num = 100;
                    if (mode & CHANGE_TYPE) ++row.cpu_subtype;
                    if (mode & CHANGE_ONLINE) row.running = !row.running;
                }
                memcpy(*output + i * stride, &row, sizeof(row));
            } else {
                processor_cpu_load_info_data_t row = {{100 + (unsigned)slot, 20, 500, 3}};
                memcpy(*output + i * stride, &row, sizeof(row));
            }
        }
    }
    return flags & API_FAIL ? KERN_FAILURE : KERN_SUCCESS;
}
static kern_return_t fixture_deallocate(vm_map_t task, vm_address_t address, vm_size_t bytes) {
    assert(task == mach_task_self());
    unsigned i;
    for (i = 0; i < live_buffers; ++i) if (allocations[i].pointer == (void *)address) break;
    assert(i < live_buffers && bytes == allocations[i].bytes);
    free((void *)address);
    allocations[i] = allocations[--live_buffers];
    ++releases;
    if (oom_after_release && live_buffers == 0) fail_lua = 1;
    return KERN_SUCCESS;
}
static int fixture_sysctl(const char *key, void *output, size_t *size, void *new_value, size_t new_size) {
    assert(!new_value && !new_size);
    if (mode & SYSCTL_FAIL) return -1;
    if (!strcmp(key, "hw.logicalcpu") && (mode & NO_LOGICAL)) return -1;
    if (!strcmp(key, "hw.cacheconfig")) {
        uint64_t sharing[] = {3, 1, 3, 0};
        if (mode & BAD_SHARING) sharing[2] = 2;
        assert(*size >= sizeof(sharing)); memcpy(output, sharing, sizeof(sharing));
        *size = mode & CACHE_ARRAY_LONG ? 72 : mode & SHORT_CACHE ? 3 : sizeof(sharing);
        return 0;
    }
    if (strstr(key, "brand_string") || strstr(key, "vendor") || strstr(key, ".name")) {
        if (mode & BAD_TEXT) { memset(output, 'x', *size); return 0; }
        const char text[] = "CPU fixture";
        assert(*size >= sizeof(text)); memcpy(output, text, sizeof(text)); *size = sizeof(text);
        if (mode & EMBEDDED_NUL) ((char *)output)[1] = 0;
        return 0;
    }
    int64_t value = 0;
    if (!strcmp(key, "hw.logicalcpu") || !strcmp(key, "hw.physicalcpu")) value = 3;
    else if (!strcmp(key, "hw.packages")) value = 1;
    else if (!strcmp(key, "hw.nperflevels")) value = mode & NO_LEVELS ? 0 : mode & LEVEL_OVERFLOW ? 100 : 1;
    else if (strstr(key, ".logicalcpu") || strstr(key, ".physicalcpu")) value = 3;
    else if (strstr(key, "cpusperl2")) value = mode & BAD_SHARING ? 2 : 3;
    else if (strstr(key, "l1dcachesize")) value = mode & CACHE_OVERFLOW ? INT64_MAX : 32768;
    else if (strstr(key, "l1icachesize")) value = 65536;
    else if (strstr(key, "l2cachesize")) value = 1048576;
    else return -1;
    assert(*size == 8); memcpy(output, &value, 8); *size = mode & BAD_INTEGER ? 3 : 8;
    return 0;
}
static int fixture_load(double *values, int count) {
    assert(count == 3); values[0] = 1; values[1] = 2; values[2] = 3; return 3;
}
#define mach_host_self fixture_host
#define mach_port_deallocate fixture_port_release
#define host_statistics fixture_statistics
#define host_processor_info fixture_processors
#define vm_deallocate fixture_deallocate
#define sysctlbyname fixture_sysctl
#define getloadavg fixture_load
#define atexit fixture_exit
#include "../../native/wtop_macos_cpu.c"
#undef atexit

static void *allocator(void *context, void *pointer, size_t old_size, size_t size) {
    (void)context; (void)old_size;
    if (!size) { free(pointer); return NULL; }
    /* Lua may longjmp on allocation failure. No Mach buffer may survive it. */
    assert(live_buffers == 0);
    if (fail_lua) return NULL;
    return realloc(pointer, size);
}
static int collect(lua_State *L, lua_CFunction function, unsigned flags, unsigned stage) {
    assert(live_buffers == 0); mode = flags; fault_call = stage; call_number = 0;
    lua_settop(L, 0); lua_pushcfunction(L, function);
    int status = lua_pcall(L, 0, 2, 0);
    assert(live_buffers == 0);
    return status;
}
static void check(lua_State *L, const char *script) {
    lua_pushvalue(L, 1); lua_setglobal(L, "data");
    int status = luaL_dostring(L, script);
    if (status != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    assert(status == LUA_OK);
}
static void usage(lua_State *L, unsigned flags, unsigned stage, const char *script) {
    assert(collect(L, wtop_collect_cpu, flags, stage) == LUA_OK); check(L, script);
}
static void info(lua_State *L, unsigned flags, unsigned stage, const char *script) {
    assert(collect(L, wtop_collect_cpu_info, flags, stage) == LUA_OK); check(L, script);
}
int main(void) {
    lua_State *L = lua_newstate(allocator, NULL, 0); assert(L); luaL_openlibs(L);
    fail_exit = 1;
    usage(L, 0, 0, "assert(data == nil)"); assert(!host_gets && !host_refs);
    fail_exit = 0; fail_host = 1;
    usage(L, 0, 0, "assert(data == nil)"); assert(host_gets == 1 && exit_calls == 2);
    fail_host = 0;
    usage(L, 0, 0, "assert(not data.partial and not data.truncated and #data.cores == 3); "
        "assert(data.counter_bits == 32 and data.counter_source == 'mach:HOST_CPU_LOAD_INFO'); "
        "assert(data.cores[1].id == 2 and data.cores[1].name == 'cpu2' and data.cores[1].raw.user == 102); "
        "assert(data.cores[2].id == 5 and data.cores[2].online == false); "
        "assert(data.cores[3].id == 8 and data.cores[3].online); epoch = data._source_epoch");
    usage(L, REVERSE, 0, "assert(not data.partial and data._source_epoch == epoch and data.cores[1].raw.user == 102)");
    processor_subtype = 4;
    usage(L, 0, 0, "assert(data._source_epoch ~= epoch and data.cores[1]._source_instance == 'mach:2:7:4'); epoch = data._source_epoch");
    force_online = 1;
    usage(L, 0, 0, "assert(data._source_epoch ~= epoch and data.cores[2].online); epoch = data._source_epoch");
    processor_subtype = 3; force_online = -1;
    processor_count = 512;
    usage(L, 0, 0, "assert(not data.partial and #data.cores == 512 and data.cores[512].id == 511)");
    processor_count = 3;
    assert(host_refs == 1 && host_gets == 2);
    for (unsigned stage = 1; stage <= 3; ++stage) {
        const unsigned flags[] = {API_FAIL, SHORT, LONG, NULL_DATA, ZERO_COUNT, TOO_MANY, HUGE_COUNT};
        for (unsigned i = 0; i < sizeof(flags)/sizeof(flags[0]); ++i) {
            usage(L, flags[i], stage, "assert(data.partial and #data.cores == 0)");
        }
    }
    const unsigned bad_ids[] = {DUPLICATE, NEGATIVE_SLOT, BAD_RUNNING, BAD_MAIN, CHANGE_SLOT, CHANGE_TYPE, CHANGE_ONLINE, COUNT_MISMATCH, CHANGE_ORDER};
    for (unsigned i = 0; i < sizeof(bad_ids)/sizeof(bad_ids[0]); ++i)
        usage(L, bad_ids[i], 0, "assert(data.partial and #data.cores == 0)");
    usage(L, TOO_MANY, 1, "assert(data.truncated)");
    usage(L, STAT_FAIL, 0, "assert(data == nil)");
    usage(L, STAT_SHORT, 0, "assert(data == nil)");
    usage(L, 0, 0, "assert(not data.partial and data._source_epoch ~= epoch)");
    info(L, 0, 0, "assert(data.quality == 'fresh' and data.topology.quality == 'partial'); "
        "local t = data.topology; assert(t.identity_quality == 'fresh' and t.threads == 3 and t.online_threads == 2); "
        "assert(t.present_cpu_list[1] == 2 and t.online_cpu_list[2] == 8 and #t.online_cpu_list == 2); "
        "assert(t.logical_cpus[3].is_main and t.logical_cpus[1].mach_cpu_type == 7); "
        "assert(t.logical_cpus[1].core_id_known == false and t.logical_cpus[1].package_id == nil); "
        "assert(data.cache_summary[1].total_size_bytes == 98304 and data.cache_summary[3].instances == 1)");
    for (unsigned stage = 1; stage <= 2; ++stage) {
        info(L, SHORT, stage, "assert(data.quality == 'partial' and #data.topology.logical_cpus == 0 and data.topology.threads == 3)");
        info(L, TOO_MANY, stage, "assert(data.truncated and #data.topology.logical_cpus == 0)");
    }
    info(L, DUPLICATE, 0, "assert(data.topology.identity_quality == 'partial' and #data.topology.logical_cpus == 0)");
    info(L, CHANGE_TYPE, 0, "assert(#data.topology.logical_cpus == 0)");
    info(L, CHANGE_ORDER, 0, "assert(#data.topology.logical_cpus == 0)");
    info(L, BAD_TEXT, 0, "assert(data.identity.model_name == nil and data.core_types[1].model_name == nil)");
    info(L, EMBEDDED_NUL, 0, "assert(data.identity.model_name == nil)");
    info(L, NO_LOGICAL, 0, "assert(data.quality == 'partial' and data.topology.threads == 3 and #data.topology.logical_cpus == 3)");
    info(L, SYSCTL_FAIL, 0, "assert(data.topology.threads == 3 and #data.topology.logical_cpus == 3)");
    info(L, SYSCTL_FAIL | SHORT, 1, "assert(data == nil)");
    info(L, BAD_INTEGER, 0, "assert(data.quality == 'partial' and data.topology.threads == 3)");
    info(L, CACHE_OVERFLOW, 0, "assert(data.quality == 'partial' and #data.cache_summary == 2)");
    info(L, LEVEL_OVERFLOW, 0, "assert(data.truncated and #data.core_types == 8)");
    info(L, BAD_SHARING, 0, "assert(data.quality == 'partial' and #data.cache_summary == 2)");
    info(L, NO_LEVELS, 0, "assert(#data.core_types == 0 and #data.cache_summary == 3)");
    info(L, NO_LEVELS | SHORT_CACHE, 0, "assert(#data.cache_summary == 0)");
    info(L, NO_LEVELS | CACHE_ARRAY_LONG, 0, "assert(#data.cache_summary == 0)");
    info(L, NO_LEVELS | BAD_SHARING, 0, "assert(data.quality == 'partial' and #data.cache_summary == 2)");
    unsigned before = host_gets;
    for (unsigned i = 0; i < 1000; ++i) {
        usage(L, 0, 0, "assert(#data.cores == 3)");
        info(L, 0, 0, "assert(#data.topology.logical_cpus == 3)");
    }
    assert(host_gets == before && host_refs == 1 && releases > 5000);
    lua_close(L);
    /* Force OOM immediately after the final VM release, for both entrypoints. */
    const lua_CFunction functions[] = {wtop_collect_cpu, wtop_collect_cpu_info};
    for (unsigned i = 0; i < 2; ++i) {
        L = lua_newstate(allocator, NULL, 0); assert(L);
        oom_after_release = 1;
        assert(collect(L, functions[i], 0, 0) == LUA_ERRMEM && live_buffers == 0);
        fail_lua = oom_after_release = 0; lua_close(L);
    }
    assert(exit_cleanup); exit_cleanup(); assert(!host_refs);
    exit_cleanup(); assert(!host_refs);
    assert(wtop_macos_host_port() == 42 && host_refs == 1 && exit_calls == 2);
    exit_cleanup(); assert(!host_refs);
    puts("macOS CPU identity/counters, owned buffers, cached port and OOM: passed");
    return 0;
}
