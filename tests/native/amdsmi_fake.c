#define _POSIX_C_SOURCE 200809L
/* Fake AMD SMI DSO, compiled against either independent public-header excerpts
 * or an original SDK header. There is no dependency on wtop's ABI header. */
#ifdef WTOP_AMDSMI_SDK_HEADER
#include WTOP_AMDSMI_SDK_HEADER
#else
#include "../fixtures/amdsmi/sdk.h"
#endif
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>

static int scenario, active, initializations, shutdowns, queries;
static int socket_ids[2], processor_ids[4];
static void fixture_hang(void) {for(;;)pause();}
static void fixture_control(void) {
    const char *path=getenv("WTOP_AMDSMI_FIXTURE_CONTROL");if(!path)return;
    FILE *file=fopen(path,"r");if(!file)return;
    int value;if(fscanf(file,"%d",&value)==1)scenario=value;fclose(file);
}
__attribute__((constructor)) static void fixture_start(void) {
    const char *setting=getenv("WTOP_AMDSMI_FIXTURE_MODE");scenario=setting?atoi(setting):0;
    if(scenario==40)fixture_hang();
    if(scenario==46){puts("AMD driver stdout");fputs("AMD driver stderr\n",stderr);fflush(stdout);fflush(stderr);}
    if(scenario==47){const char bad[]="bad driver frame";ssize_t sent=write(3,bad,sizeof(bad));(void)sent;}
    if(scenario==48){uint32_t bad[16]={0x4d4e5457,2,UINT32_MAX};ssize_t sent=write(3,bad,sizeof(bad));(void)sent;}
    if(scenario==49){struct timespec delay={0,800000000};nanosleep(&delay,NULL);}
}
void fixture_reset(int mode) { assert(!active); scenario = mode; initializations = shutdowns = queries = 0; }
int fixture_active(void) { return active; }
int fixture_inits(void) { return initializations; }
int fixture_shutdowns(void) { return shutdowns; }
int fixture_queries(void) { return queries; }
static int id(amdsmi_processor_handle h) {
    assert(active);
    for (int i = 0; i < 4; ++i) if (h == &processor_ids[i]) return i;
    assert(!"invalid opaque processor handle"); return 0;
}
amdsmi_status_t amdsmi_init(uint64_t flags) {
    fixture_control();
    if(scenario==41)fixture_hang();
    assert(flags == 2 && !active); initializations++;
    if (scenario == 1) return 1;
    active = 1; return 0;
}
amdsmi_status_t amdsmi_shut_down(void) {
    if(scenario==45)fixture_hang();
    assert(active); active = 0; shutdowns++;
    return scenario == 21 ? 1 : 0;
}
amdsmi_status_t amdsmi_get_lib_version(amdsmi_version_t *v) {
    assert(active); if (scenario == 2) return 1;
    memset(v, 0, sizeof(*v));
#ifdef AMDSMI_LIB_VERSION_YEAR
    v->year = AMDSMI_LIB_VERSION_YEAR;
#endif
    v->major = AMDSMI_LIB_VERSION_MAJOR; v->minor = AMDSMI_LIB_VERSION_MINOR;
    #ifdef WTOP_AMDSMI_VERSION_RELEASE
    v->release = WTOP_AMDSMI_VERSION_RELEASE;
#else
    v->release = AMDSMI_LIB_VERSION_RELEASE;
#endif
    v->build = (const char *)(uintptr_t)1; /* Must never be dereferenced. */
    if (scenario == 3) v->major = 999;
    return 0;
}
amdsmi_status_t amdsmi_get_socket_handles(uint32_t *n, amdsmi_socket_handle *out) {
    if(scenario==42)fixture_hang();
    assert(active); queries++;
    if (!out) { if (scenario == 4) return 1; *n = scenario == 7 ? 1000 : 2; return 0; }
    assert(*n >= 2 && *n <= 32);
    if (scenario == 5) return 1;
    if (scenario == 6 || scenario == 7) { *n = 1000; return 41; }
    out[0] = &socket_ids[0]; out[1] = &socket_ids[1]; *n = 2;
    return 0;
}
amdsmi_status_t amdsmi_get_processor_handles(amdsmi_socket_handle socket, uint32_t *n,
    amdsmi_processor_handle *out) {
    assert(active && (socket == &socket_ids[0] || socket == &socket_ids[1])); queries++;
    int second = socket == &socket_ids[1];
    if (scenario == 8 && second) return 1;
    if (!out) { *n = scenario == 10 && second ? 1000 : 3; return 0; }
    assert(*n >= 3 && *n <= 64);
    if ((scenario == 9 || scenario == 10) && second) { *n = 1000; return 39; }
    out[0] = &processor_ids[second ? 1 : 0];
    out[1] = &processor_ids[second ? 2 : 1];
    out[2] = scenario == 20 ? NULL : &processor_ids[3]; *n = 3;
    return 0;
}
#ifndef WTOP_FAKE_MISSING_REQUIRED
amdsmi_status_t amdsmi_get_processor_type(amdsmi_processor_handle h, processor_type_t *type) {
    int index = id(h); if (scenario == 19 && index == 2) return 1;
    *type = index == 3 ? 2 : 1; return 0;
}
#endif
#ifndef WTOP_FAKE_NO_OPTIONAL
static int optional(amdsmi_processor_handle h) { (void)id(h); queries++; return scenario == 15; }
amdsmi_status_t amdsmi_get_gpu_device_bdf(amdsmi_processor_handle h, amdsmi_bdf_t *out) {
    if (optional(h)) return 1;
    out->as_uint = ((scenario == 17 ? UINT64_C(0x10000) : UINT64_C(0xabcd)) << 16)
        | ((uint64_t)(id(h) + 3) << 8) | (UINT64_C(0x1a) << 3) | 5;
    return 0;
}
amdsmi_status_t amdsmi_get_gpu_asic_info(amdsmi_processor_handle h, amdsmi_asic_info_t *out) {
    if (optional(h)) return 1;
    memset(out, 0xa5, sizeof(*out));
    if (scenario != 16) snprintf(out->market_name, sizeof(out->market_name), "AMD SDK fixture %d", id(h));
    return 0;
}
amdsmi_status_t amdsmi_get_gpu_device_uuid(amdsmi_processor_handle h, unsigned int *n, char *out) {
    if (optional(h)) return 1;
    assert(*n >= 256);
    if (scenario == 16) { memset(out, 'X', *n); return 0; }
    if (scenario == 22) { *n = UINT_MAX; return 0; }
    int size = snprintf(out, *n, "GPU-fixture-%d", id(h)); *n = (unsigned int)size; return 0;
}
#if WTOP_AMDSMI_PROFILE != 232
amdsmi_status_t amdsmi_get_gpu_driver_info(amdsmi_processor_handle h, amdsmi_driver_info_t *out) {
    if (optional(h)) return 1;
    memset(out, 0xa5, sizeof(*out));
    if (scenario != 16) {
        snprintf(out->driver_name, sizeof(out->driver_name), "amdgpu");
        snprintf(out->driver_date, sizeof(out->driver_date), "20261015");
        snprintf(out->driver_version, sizeof(out->driver_version), "driver-%d", id(h));
    }
    return 0;
}
#endif
/* The old driver-version function disappeared from current public headers. */
#if WTOP_AMDSMI_PROFILE == 232
amdsmi_status_t amdsmi_get_gpu_driver_version(amdsmi_processor_handle h, int *n, char *out) {
    if (optional(h)) return 1;
    assert(*n >= 64);
    if (scenario == 16) { memset(out, 'X', (size_t)*n); return 0; }
    int size = snprintf(out, (size_t)*n, "driver-%d", id(h)); *n = size + 1; return 0;
}
#endif
amdsmi_status_t amdsmi_get_gpu_activity(amdsmi_processor_handle h, amdsmi_engine_usage_t *out) {
    if (optional(h)) return 1;
    memset(out, 0xff, sizeof(*out));
    out->gfx_activity = scenario == 11 ? UINT_MAX : scenario == 12 ? 0 : 71;
    out->umc_activity = scenario == 11 ? 101 : scenario == 12 ? 0 : 12;
    return 0;
}
amdsmi_status_t amdsmi_get_gpu_memory_total(amdsmi_processor_handle h, amdsmi_memory_type_t type, uint64_t *out) {
    if (optional(h)) return 1;
    assert(type == 0);
    *out = scenario == 11 ? UINT64_MAX : scenario == 12 ? 0 : UINT64_C(24) << 30; return 0;
}
amdsmi_status_t amdsmi_get_gpu_memory_usage(amdsmi_processor_handle h, amdsmi_memory_type_t type, uint64_t *out) {
    if (optional(h)) return 1;
    assert(type == 0);
    *out = scenario == 11 ? UINT64_MAX : scenario == 12 ? 0 : (uint64_t)(scenario == 18 ? 25 : 6) << 30; return 0;
}
amdsmi_status_t amdsmi_get_temp_metric(amdsmi_processor_handle h, amdsmi_temperature_type_t sensor,
    amdsmi_temperature_metric_t metric, int64_t *out) {
    if (optional(h)) return 1;
    assert(sensor == 0 && metric == 0);
    *out = scenario == 11 ? INT64_MIN : scenario == 12 ? 0 : 58; return 0;
}
amdsmi_status_t amdsmi_get_power_info(amdsmi_processor_handle h, amdsmi_power_info_t *out) {
    if(scenario==43)raise(SIGSEGV);
    if(scenario==44)fixture_hang();
    if (optional(h)) return 1;
    memset(out, 0xff, sizeof(*out));
#if WTOP_AMDSMI_PROFILE >= 255
    out->socket_power = 0; /* 25.5 leaves it unwritten; don't trust this member. */
#endif
#if WTOP_AMDSMI_PROFILE != 232
    out->current_socket_power = scenario == 12 ? 0 : (scenario == 11 || scenario == 13 || scenario == 14) ? 0xffff : 300;
#endif
    out->average_socket_power = scenario == 12 ? 0 : (scenario == 11 || scenario == 14) ? UINT_MAX : 47;
    out->power_limit = 12345; /* Must use the independent cap API, not this. */
    return 0;
}
amdsmi_status_t amdsmi_get_power_cap_info(amdsmi_processor_handle h, uint32_t sensor, amdsmi_power_cap_info_t *out) {
    if (optional(h) || scenario == 23) return 1;
    assert(sensor == 0); memset(out, 0xff, sizeof(*out));
    out->power_cap = scenario == 11 ? UINT64_MAX : UINT64_C(355500000); return 0;
}
amdsmi_status_t amdsmi_get_clock_info(amdsmi_processor_handle h, amdsmi_clk_type_t clock, amdsmi_clk_info_t *out) {
    if (optional(h)) return 1;
    assert(clock == 0 || clock == 4); memset(out, 0xff, sizeof(*out));
#if WTOP_AMDSMI_PROFILE <= 245
    out->cur_clk = scenario == 11 ? UINT_MAX : scenario == 12 ? 0 : clock == 0 ? 2510 : 1050;
#else
    out->clk = scenario == 11 ? UINT_MAX : scenario == 12 ? 0 : clock == 0 ? 2510 : 1050;
#endif
    out->max_clk = scenario == 11 ? UINT_MAX : 2900; return 0;
}
amdsmi_status_t amdsmi_get_gpu_fan_speed(amdsmi_processor_handle h, uint32_t sensor, int64_t *out) {
    if (optional(h)) return 1;
    assert(sensor == 0);
    *out = scenario == 11 ? -1 : scenario == 12 ? 0 : 128; return 0;
}
amdsmi_status_t amdsmi_get_gpu_fan_speed_max(amdsmi_processor_handle h, uint32_t sensor, uint64_t *out) {
    if (optional(h)) return 1;
    assert(sensor == 0); *out = 255; return 0;
}
#endif
