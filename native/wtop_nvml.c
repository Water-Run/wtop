/*
 * Copyright 1993-2026 NVIDIA Corporation.  All rights reserved.
 *
 * NOTICE TO USER:
 *
 * This source code is subject to NVIDIA ownership rights under U.S. and
 * international Copyright laws.  Users and possessors of this source code
 * are hereby granted a nonexclusive, royalty-free license to use this code
 * in individual and commercial software.
 *
 * NVIDIA MAKES NO REPRESENTATION ABOUT THE SUITABILITY OF THIS SOURCE
 * CODE FOR ANY PURPOSE.  IT IS PROVIDED "AS IS" WITHOUT EXPRESS OR
 * IMPLIED WARRANTY OF ANY KIND.  NVIDIA DISCLAIMS ALL WARRANTIES WITH
 * REGARD TO THIS SOURCE CODE, INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY, NONINFRINGEMENT, AND FITNESS FOR A PARTICULAR PURPOSE.
 * IN NO EVENT SHALL NVIDIA BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL,
 * OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS,  WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE
 * OR OTHER TORTIOUS ACTION,  ARISING OUT OF OR IN CONNECTION WITH THE USE
 * OR PERFORMANCE OF THIS SOURCE CODE.
 *
 * U.S. Government End Users.   This source code is a "commercial item" as
 * that term is defined at  48 C.F.R. 2.101 (OCT 1995), consisting  of
 * "commercial computer  software"  and "commercial computer software
 * documentation" as such terms are  used in 48 C.F.R. 12.212 (SEPT 1995)
 * and is provided to the U.S. Government only as a commercial end item.
 * Consistent with 48 C.F.R.12.212 and 48 C.F.R. 227.7202-1 through
 * 227.7202-4 (JUNE 1995), all U.S. Government End Users acquire the
 * source code with only those rights set forth herein.
 *
 * Any use of this source code in individual and commercial software must
 * include, in the user documentation and internal comments to the code,
 * the above Disclaimer and U.S. Government End Users Notice.
 */
/* NVIDIA Management Library provider. libnvidia-ml ships with the NVIDIA
 * driver, so it is opened at run time and nothing links against it; a host
 * without the driver reports the provider as unavailable. Only read-only
 * queries are used. */
#define _GNU_SOURCE

#include <lua.h>
#include <lauxlib.h>

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include <math.h>
#include <time.h>

#include "wtop_nvml.h"

const char wtop_nvml_interface_license[] =
    "Copyright 1993-2026 NVIDIA Corporation.  All rights reserved.\n"
    "\n"
    "NOTICE TO USER:\n"
    "\n"
    "This source code is subject to NVIDIA ownership rights under U.S. and\n"
    "international Copyright laws.  Users and possessors of this source code\n"
    "are hereby granted a nonexclusive, royalty-free license to use this code\n"
    "in individual and commercial software.\n"
    "\n"
    "NVIDIA MAKES NO REPRESENTATION ABOUT THE SUITABILITY OF THIS SOURCE\n"
    "CODE FOR ANY PURPOSE.  IT IS PROVIDED \"AS IS\" WITHOUT EXPRESS OR\n"
    "IMPLIED WARRANTY OF ANY KIND.  NVIDIA DISCLAIMS ALL WARRANTIES WITH\n"
    "REGARD TO THIS SOURCE CODE, INCLUDING ALL IMPLIED WARRANTIES OF\n"
    "MERCHANTABILITY, NONINFRINGEMENT, AND FITNESS FOR A PARTICULAR PURPOSE.\n"
    "IN NO EVENT SHALL NVIDIA BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL,\n"
    "OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS\n"
    "OF USE, DATA OR PROFITS,  WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE\n"
    "OR OTHER TORTIOUS ACTION,  ARISING OUT OF OR IN CONNECTION WITH THE USE\n"
    "OR PERFORMANCE OF THIS SOURCE CODE.\n"
    "\n"
    "U.S. Government End Users.   This source code is a \"commercial item\" as\n"
    "that term is defined at  48 C.F.R. 2.101 (OCT 1995), consisting  of\n"
    "\"commercial computer  software\"  and \"commercial computer software\n"
    "documentation\" as such terms are  used in 48 C.F.R. 12.212 (SEPT 1995)\n"
    "and is provided to the U.S. Government only as a commercial end item.\n"
    "Consistent with 48 C.F.R.12.212 and 48 C.F.R. 227.7202-1 through\n"
    "227.7202-4 (JUNE 1995), all U.S. Government End Users acquire the\n"
    "source code with only those rights set forth herein.\n"
    "\n"
    "Any use of this source code in individual and commercial software must\n"
    "include, in the user documentation and internal comments to the code,\n"
    "the above Disclaimer and U.S. Government End Users Notice.\n"
    ;

#define NVML_MAX_DEVICES 64
#define NVML_MAX_PROCESSES 256

typedef void *nvml_device;
typedef unsigned int nvml_return; /* NVML_SUCCESS = 0 */

typedef struct {
    char bus_id_legacy[16];
    unsigned int domain;
    unsigned int bus;
    unsigned int device;
    unsigned int pci_device_id;
    unsigned int pci_subsystem_id;
    char bus_id[32];
} nvml_pci_info;

typedef struct {
    unsigned int gpu;
    unsigned int memory;
} nvml_utilization;

typedef struct {
    unsigned long long total;
    unsigned long long free;
    unsigned long long used;
} nvml_memory;

typedef struct {
    unsigned int pid;
    unsigned long long used_gpu_memory;
    unsigned int gpu_instance_id;
    unsigned int compute_instance_id;
} nvml_process;

typedef struct {
    unsigned int pid;
    unsigned long long timestamp;
    unsigned int sm;
    unsigned int memory;
    unsigned int encoder;
    unsigned int decoder;
} nvml_process_sample;

typedef struct { unsigned int pid; unsigned long long used_gpu_memory; } nvml_process_v1;
typedef union { double d; int si; unsigned int ui; unsigned long ul;
    unsigned long long ull; long long sll; unsigned short us; } nvml_field_value;
typedef struct { unsigned int field_id, scope; long long timestamp, latency;
    unsigned int type, status; nvml_field_value value; } nvml_field;

typedef nvml_return (*nvml_init_function)(void);
typedef nvml_return (*nvml_count_function)(unsigned int *);
typedef nvml_return (*nvml_handle_function)(unsigned int, nvml_device *);
typedef nvml_return (*nvml_text_function)(nvml_device, char *, unsigned int);
typedef nvml_return (*nvml_system_text_function)(char *, unsigned int);
typedef nvml_return (*nvml_pci_function)(nvml_device, nvml_pci_info *);
typedef nvml_return (*nvml_utilization_function)(nvml_device, nvml_utilization *);
typedef nvml_return (*nvml_memory_function)(nvml_device, nvml_memory *);
typedef nvml_return (*nvml_sensor_function)(nvml_device, unsigned int, unsigned int *);
typedef nvml_return (*nvml_value_function)(nvml_device, unsigned int *);
typedef nvml_return (*nvml_state_function)(nvml_device, unsigned int *);
typedef nvml_return (*nvml_processes_function)(nvml_device, unsigned int *, nvml_process *);
typedef nvml_return (*nvml_samples_function)(nvml_device, nvml_process_sample *,
    unsigned int *, unsigned long long);
typedef nvml_return (*nvml_processes_v1_function)(nvml_device, unsigned int *, nvml_process_v1 *);
typedef nvml_return (*nvml_mask_function)(nvml_device, unsigned long long *);
typedef nvml_return (*nvml_fields_function)(nvml_device, int, nvml_field *);

/* POSIX dlsym dispatch uses local ABI types. Clang's function-name/type check
 * cannot express equivalence with SDK enums and opaque handles. Keep the
 * other UBSan checks and ASan active; full SDK layout tests cover this bridge. */
#if defined(__clang__)
#define NVML_ABI __attribute__((no_sanitize("function")))
#else
#define NVML_ABI
#endif

typedef struct { char uuid[128]; unsigned long long timestamp; } sample_cursor;

typedef struct {
    int state;
    void *library;
    nvml_init_function shutdown;
    nvml_count_function count;
    nvml_handle_function handle;
    nvml_text_function name;
    nvml_text_function uuid;
    nvml_system_text_function driver_version;
    nvml_pci_function pci;
    nvml_utilization_function utilization;
    nvml_memory_function memory;
    nvml_sensor_function temperature;
    nvml_value_function power;
    nvml_value_function power_limit;
    nvml_sensor_function clock;
    nvml_sensor_function max_clock;
    nvml_value_function fan;
    nvml_state_function performance_state;
    nvml_processes_function compute_processes;
    nvml_processes_function graphics_processes;
    nvml_processes_function compute_processes_v2, graphics_processes_v2;
    nvml_processes_v1_function compute_processes_v1, graphics_processes_v1;
    nvml_samples_function process_samples;
    nvml_mask_function current_events, current_throttle, supported_events, supported_throttle;
    nvml_fields_function fields;
    sample_cursor cursors[NVML_MAX_DEVICES];
} nvml_api;
static char nvml_registry_key;

NVML_ABI static void nvml_close(nvml_api *a) {
    if (a->state && a->shutdown) a->shutdown();
    if (a->library) dlclose(a->library);
    memset(a, 0, sizeof(*a));
}
static int nvml_gc(lua_State *L) { nvml_close(lua_touserdata(L, 1)); return 0; }
static nvml_api *nvml_context(lua_State *L) {
    lua_rawgetp(L, LUA_REGISTRYINDEX, &nvml_registry_key);
    nvml_api *a = lua_touserdata(L, -1);
    if (a) { lua_pop(L, 1); return a; }
    lua_pop(L, 1);
    a = lua_newuserdatauv(L, sizeof(*a), 0); memset(a, 0, sizeof(*a));
    luaL_newmetatable(L, "wtop.nvml.session");
    /* Also repair a metatable left half-built by an earlier allocation error. */
    lua_pushcfunction(L, nvml_gc); lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &nvml_registry_key);
    /* No SDK resource is acquired until the finalizer and registry root exist. */
    return a;
}

static void *symbol(void *library, const char *name, const char *fallback) {
    void *found = dlsym(library, name);
    if (!found && fallback) found = dlsym(library, fallback);
    return found;
}

NVML_ABI static const char *nvml_open(nvml_api *a) {
    if (a->state) return NULL;
    void *library = dlopen("libnvidia-ml.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!library) return "nvml_library_not_found";
    a->library = library;
    nvml_init_function init = (nvml_init_function)symbol(library, "nvmlInit_v2", "nvmlInit");
#define GET(field, type, name, fallback) a->field = (type)symbol(library, name, fallback)
    GET(shutdown, nvml_init_function, "nvmlShutdown", NULL);
    GET(count, nvml_count_function, "nvmlDeviceGetCount_v2", "nvmlDeviceGetCount");
    GET(handle, nvml_handle_function, "nvmlDeviceGetHandleByIndex_v2", "nvmlDeviceGetHandleByIndex");
    GET(name, nvml_text_function, "nvmlDeviceGetName", NULL);
    GET(uuid, nvml_text_function, "nvmlDeviceGetUUID", NULL);
    GET(driver_version, nvml_system_text_function, "nvmlSystemGetDriverVersion", NULL);
    GET(pci, nvml_pci_function, "nvmlDeviceGetPciInfo_v3", "nvmlDeviceGetPciInfo_v2");
    if (!a->pci) GET(pci, nvml_pci_function, "nvmlDeviceGetPciInfo", NULL);
    GET(utilization, nvml_utilization_function, "nvmlDeviceGetUtilizationRates", NULL);
    GET(memory, nvml_memory_function, "nvmlDeviceGetMemoryInfo", NULL);
    GET(temperature, nvml_sensor_function, "nvmlDeviceGetTemperature", NULL);
    GET(power, nvml_value_function, "nvmlDeviceGetPowerUsage", NULL);
    GET(power_limit, nvml_value_function, "nvmlDeviceGetEnforcedPowerLimit", NULL);
    GET(clock, nvml_sensor_function, "nvmlDeviceGetClockInfo", NULL);
    GET(max_clock, nvml_sensor_function, "nvmlDeviceGetMaxClockInfo", NULL);
    GET(fan, nvml_value_function, "nvmlDeviceGetFanSpeed", NULL);
    GET(performance_state, nvml_state_function, "nvmlDeviceGetPerformanceState", NULL);
    GET(compute_processes, nvml_processes_function, "nvmlDeviceGetComputeRunningProcesses_v3", NULL);
    GET(graphics_processes, nvml_processes_function, "nvmlDeviceGetGraphicsRunningProcesses_v3", NULL);
    GET(compute_processes_v2, nvml_processes_function, "nvmlDeviceGetComputeRunningProcesses_v2", NULL);
    GET(graphics_processes_v2, nvml_processes_function, "nvmlDeviceGetGraphicsRunningProcesses_v2", NULL);
    GET(compute_processes_v1, nvml_processes_v1_function, "nvmlDeviceGetComputeRunningProcesses", NULL);
    GET(graphics_processes_v1, nvml_processes_v1_function, "nvmlDeviceGetGraphicsRunningProcesses", NULL);
    GET(process_samples, nvml_samples_function, "nvmlDeviceGetProcessUtilization", NULL);
    GET(current_events, nvml_mask_function, "nvmlDeviceGetCurrentClocksEventReasons", NULL);
    GET(current_throttle, nvml_mask_function, "nvmlDeviceGetCurrentClocksThrottleReasons", NULL);
    GET(supported_events, nvml_mask_function, "nvmlDeviceGetSupportedClocksEventReasons", NULL);
    GET(supported_throttle, nvml_mask_function, "nvmlDeviceGetSupportedClocksThrottleReasons", NULL);
    GET(fields, nvml_fields_function, "nvmlDeviceGetFieldValues", NULL);
#undef GET
    if (!init || !a->shutdown || !a->count || !a->handle) {
        nvml_close(a); return "nvml_symbols_missing";
    }
    if (init() != 0) { nvml_close(a); return "nvml_initialization_failed"; }
    a->state = 1;
    return NULL;
}

static void integer_field(lua_State *L, const char *name, lua_Integer value) {
    lua_pushinteger(L, value);
    lua_setfield(L, -2, name);
}

static void number_field(lua_State *L, const char *name, lua_Number value) {
    lua_pushnumber(L, value);
    lua_setfield(L, -2, name);
}

static void string_field(lua_State *L, const char *name, const char *value) {
    lua_pushstring(L, value);
    lua_setfield(L, -2, name);
}

typedef struct {
    unsigned int pid;
    unsigned long long memory, whole_memory, context_memory, timestamp;
    unsigned int source_bits, context_count;
    int has_memory, has_whole, memory_estimated;
    unsigned int sm, memory_utilization, encoder, decoder;
    int has_sample;
    const char *kind;
} process_row;

static int find_process(process_row *rows, int count, unsigned int pid) {
    for (int index = 0; index < count; ++index) {
        if (rows[index].pid == pid) return index;
    }
    return -1;
}

/* A report can occur in both graphics and compute lists. Preserve distinct
 * contexts, but do not add them: CIs can share memory, including newer shared
 * MIG configurations. If no whole-device report exists, expose the largest
 * observed context as an estimate and retain every context for inspection. */
typedef struct { nvml_process value; unsigned int sources; } allocation;
NVML_ABI static int process_list(nvml_api *a, nvml_device device, int graphics,
    nvml_process *values, int *truncated) {
    nvml_processes_function versions[2] = {
        graphics ? a->graphics_processes : a->compute_processes,
        graphics ? a->graphics_processes_v2 : a->compute_processes_v2 };
    for (int v = 0; v < 2; ++v) if (versions[v]) {
        unsigned int count = NVML_MAX_PROCESSES;
        memset(values, 0xff, sizeof(*values) * NVML_MAX_PROCESSES);
        nvml_return status = versions[v](device, &count, values);
        if (count > NVML_MAX_PROCESSES || status == 7) *truncated = 1;
        if (status == 0 && count <= NVML_MAX_PROCESSES) return (int)count;
        if (status != 3 && status != 13) return 0;
    }
    nvml_processes_v1_function legacy = graphics ? a->graphics_processes_v1 : a->compute_processes_v1;
    if (legacy) {
        nvml_process_v1 old[NVML_MAX_PROCESSES]; memset(old, 0xff, sizeof(old));
        unsigned int count = NVML_MAX_PROCESSES;
        nvml_return status = legacy(device, &count, old);
        if (count > NVML_MAX_PROCESSES || status == 7) *truncated = 1;
        if (status == 0 && count <= NVML_MAX_PROCESSES) {
            memset(values, 0xff, sizeof(*values) * NVML_MAX_PROCESSES);
            for (unsigned int i = 0; i < count; ++i) {
                values[i].pid = old[i].pid; values[i].used_gpu_memory = old[i].used_gpu_memory;
            }
            return (int)count;
        }
    }
    return 0;
}
NVML_ABI static int collect_processes(nvml_api *a, nvml_device device,
    unsigned long long previous, unsigned long long *next, process_row *rows, int *truncated,
    allocation *allocations, int *records_count) {
    int allocations_count = 0, count = 0;
    for (int source = 0; source < 2; ++source) {
        nvml_process values[NVML_MAX_PROCESSES];
        int amount = process_list(a, device, source, values, truncated);
        for (int i = 0; i < amount; ++i) {
            nvml_process p = values[i];
            if (p.pid == 0 || p.pid > INT_MAX) continue;
            int found = -1;
            for (int j = 0; j < allocations_count; ++j) {
                nvml_process *old = &allocations[j].value;
                if (old->pid == p.pid && old->gpu_instance_id == p.gpu_instance_id
                    && old->compute_instance_id == p.compute_instance_id) { found = j; break; }
            }
            if (found < 0) {
                found = allocations_count++; allocations[found].value = p;
                allocations[found].sources = 0;
            } else if (p.used_gpu_memory != ~0ULL
                && (allocations[found].value.used_gpu_memory == ~0ULL
                    || p.used_gpu_memory > allocations[found].value.used_gpu_memory))
                allocations[found].value.used_gpu_memory = p.used_gpu_memory;
            allocations[found].sources |= 1u << source;
        }
    }
    for (int i = 0; i < allocations_count; ++i) {
        nvml_process p = allocations[i].value;
        int found = find_process(rows, count, p.pid);
        if (found < 0) {
            if (count == NVML_MAX_PROCESSES) { *truncated = 1; continue; }
            found = count++; memset(&rows[found], 0, sizeof(rows[found])); rows[found].pid = p.pid;
        }
        process_row *r = &rows[found];
        r->source_bits |= allocations[i].sources;
        if (p.used_gpu_memory < (1ULL << 50)) {
            /* A legacy whole-device report overlaps context-specific reports.
             * Distinct contexts are not proof of disjoint memory allocations. */
            if (p.gpu_instance_id == UINT_MAX && p.compute_instance_id == UINT_MAX) {
                if (p.used_gpu_memory > r->whole_memory) r->whole_memory = p.used_gpu_memory;
                r->has_whole = 1;
            } else {
                r->context_count++;
                if (p.used_gpu_memory > r->context_memory) r->context_memory = p.used_gpu_memory;
            }
            r->has_memory = 1;
        }
    }
    for (int i = 0; i < count; ++i) {
        rows[i].memory = rows[i].context_memory > rows[i].whole_memory
            ? rows[i].context_memory : rows[i].whole_memory;
        rows[i].memory_estimated = (rows[i].context_count > 1 && !rows[i].has_whole)
            || (rows[i].has_whole && rows[i].context_memory > rows[i].whole_memory);
        rows[i].kind = rows[i].source_bits == 3 ? "compute+graphics"
            : rows[i].source_bits == 1 ? "compute" : "graphics";
    }
    if (a->process_samples) {
        nvml_process_sample samples[NVML_MAX_PROCESSES]; memset(samples, 0xff, sizeof(samples));
        unsigned int amount = NVML_MAX_PROCESSES;
        nvml_return status = a->process_samples(device, samples, &amount, previous);
        if (amount > NVML_MAX_PROCESSES || status == 7) *truncated = 1;
        if (status == 0 && amount <= NVML_MAX_PROCESSES) for (unsigned int i = 0; i < amount; ++i) {
            nvml_process_sample p = samples[i];
            if (p.pid == 0 || p.pid > INT_MAX || p.timestamp == ~0ULL || p.timestamp <= previous) continue;
            if (p.timestamp > *next) *next = p.timestamp;
            if (p.sm > 100 || p.memory > 100 || p.encoder > 100 || p.decoder > 100) continue;
            int found = find_process(rows, count, p.pid);
            if (found < 0) {
                if (count == NVML_MAX_PROCESSES) { *truncated = 1; continue; }
                found = count++; memset(&rows[found], 0, sizeof(rows[found]));
                rows[found].pid = p.pid; rows[found].kind = "sampled";
            }
            if (!rows[found].has_sample || p.timestamp > rows[found].timestamp) {
                rows[found].timestamp = p.timestamp;
                rows[found].sm = p.sm; rows[found].memory_utilization = p.memory;
                rows[found].encoder = p.encoder; rows[found].decoder = p.decoder;
                rows[found].has_sample = 1;
            }
        }
    }
    *records_count = allocations_count;
    return count;
}

static int valid_text(const char *text, size_t size) {
    const char *end = memchr(text, 0, size);
    return end && end != text;
}
static int hex_digit(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static int pci_address(const char *text, size_t size, const nvml_pci_info *pci, char *out, size_t out_size) {
    const char *end = memchr(text, 0, size);
    if (!end) return 0;
    size_t length = (size_t)(end - text);
    if (length != 12 && length != 16) return 0;
    size_t widths[4] = {length - 8, 2, 2, 1}, position = 0;
    const char separators[3] = {':', ':', '.'};
    unsigned int values[4] = {0};
    for (int field = 0; field < 4; ++field) {
        for (size_t i = 0; i < widths[field]; ++i) {
            int digit = hex_digit((unsigned char)text[position++]);
            if (digit < 0) return 0;
            values[field] = values[field] * 16u + (unsigned int)digit;
        }
        if (field < 3 && text[position++] != separators[field]) return 0;
    }
    if (values[0] > 0xffff || values[1] > 0xff || values[2] > 0x1f || values[3] > 7
        || values[0] != pci->domain || values[1] != pci->bus || values[2] != pci->device) return -1;
    snprintf(out, out_size, "%04x:%02x:%02x.%x", values[0], values[1], values[2], values[3]);
    return 1;
}
NVML_ABI static nvml_return mask_query(nvml_device device, nvml_mask_function current,
    nvml_mask_function legacy, unsigned long long *mask, const char **source,
    const char *current_name, const char *legacy_name) {
    nvml_return status = 13; *source = current_name;
    if (current) status = current(device, mask);
    if ((!current || status == 3 || status == 13) && legacy) {
        *source = legacy_name; status = legacy(device, mask);
    }
    return status;
}
NVML_ABI static void clock_events(lua_State *L, nvml_api *a, nvml_device device) {
    unsigned long long active = ~0ULL, supported = ~0ULL;
    const char *active_source, *supported_source;
    nvml_return status = mask_query(device, a->current_events, a->current_throttle, &active,
        &active_source, "nvmlDeviceGetCurrentClocksEventReasons", "nvmlDeviceGetCurrentClocksThrottleReasons");
    nvml_return support_status = mask_query(device, a->supported_events, a->supported_throttle,
        &supported, &supported_source, "nvmlDeviceGetSupportedClocksEventReasons", "nvmlDeviceGetSupportedClocksThrottleReasons");
    lua_createtable(L, 0, 6);
    integer_field(L, "status_code", status); integer_field(L, "supported_status_code", support_status);
    string_field(L, "source", active_source); string_field(L, "supported_source", supported_source);
    char text[19];
    if (status == 0) { snprintf(text, sizeof(text), "0x%016llx", active); string_field(L, "raw_hex", text); }
    if (support_status == 0) { snprintf(text, sizeof(text), "0x%016llx", supported); string_field(L, "supported_hex", text); }
    lua_setfield(L, -2, "clock_events");
}
static int field_power(const nvml_field *field, unsigned int expected, double *watts) {
    if (field->field_id != expected || field->scope != 0 || field->status != 0) return 0;
    double value;
    switch (field->type) {
        case 0: value = field->value.d; break;
        case 1: value = field->value.ui; break;
        case 2: value = (double)field->value.ul; break;
        case 3: value = (double)field->value.ull; break;
        case 4: value = (double)field->value.sll; break;
        case 5: value = field->value.si; break;
        case 6: value = field->value.us; break;
        default: return 0;
    }
    if (!isfinite(value) || value < 0 || value >= 100000000.0) return 0;
    *watts = value / 1000.0; return 1;
}
/* Field timestamps are documented UTC microseconds, unlike process sample
 * timestamps. A successful read of an old cache is not fresh power. */
static const char *field_freshness(const nvml_field *field) {
    struct timespec now;
    if (field->timestamp <= 0 || clock_gettime(CLOCK_REALTIME, &now) != 0
        || now.tv_sec < 0 || now.tv_sec >= LLONG_MAX / 1000000) return "gap";
    long long current = (long long)now.tv_sec * 1000000 + now.tv_nsec / 1000;
    long long age = current - field->timestamp;
    if (age < -1000000) return "gap";
    return age > 5000000 ? "stale" : "fresh";
}
NVML_ABI static void device_power(lua_State *L, nvml_api *a, nvml_device device) {
    nvml_field fields[2]; memset(fields, 0xff, sizeof(fields));
    fields[0].field_id = 186; fields[1].field_id = 185;
    fields[0].scope = fields[1].scope = 0; /* GPU, not module/CPU+GPU scope. */
    double instant = 0, average = 0; int has_instant = 0, has_average = 0;
    if (a->fields && a->fields(device, 2, fields) == 0) {
        has_instant = field_power(&fields[0], 186, &instant);
        has_average = field_power(&fields[1], 185, &average);
    }
    const char *instant_quality = has_instant ? field_freshness(&fields[0]) : NULL;
    const char *average_quality = has_average ? field_freshness(&fields[1]) : NULL;
    if (has_instant) {
        string_field(L, "power_instant_quality", instant_quality);
        number_field(L, "power_instant_watts", instant);
        if (fields[0].timestamp > 0) integer_field(L, "power_instant_timestamp_us", fields[0].timestamp);
    }
    if (has_average) {
        string_field(L, "power_average_quality", average_quality);
        number_field(L, "power_average_watts", average);
        integer_field(L, "power_average_interval_ns", 1000000000);
        if (fields[1].timestamp > 0) integer_field(L, "power_average_timestamp_us", fields[1].timestamp);
    }
    if (has_instant || has_average) {
        int use_instant = has_instant && (!has_average || !strcmp(instant_quality, "fresh")
            || strcmp(average_quality, "fresh"));
        number_field(L, "power_watts", use_instant ? instant : average);
        string_field(L, "power_measurement", use_instant ? "current" : "average");
        string_field(L, "power_quality", use_instant ? instant_quality : average_quality);
        if (!use_instant) integer_field(L, "power_interval_ns", 1000000000);
    } else {
        unsigned int value = UINT_MAX;
        if (a->power && a->power(device, &value) == 0 && value < 100000000) {
            number_field(L, "power_watts", value / 1000.0);
            /* This API is instantaneous on older/GA100 GPUs and a 1s average
             * on other Ampere/newer GPUs. Without explicit fields, don't guess. */
            string_field(L, "power_measurement", "device_sample");
            string_field(L, "power_quality", "fresh");
        }
    }
    unsigned int limit = UINT_MAX;
    if (a->power_limit && a->power_limit(device, &limit) == 0 && limit > 0 && limit < 100000000)
        number_field(L, "power_limit_watts", limit / 1000.0);
}

/* One initialized SDK session per Lua VM, with a registry-owned finalizer.
 * Keep the sampler alive across queries; release it on VM close. Failed opens
 * are retryable. Cursors are keyed by UUID and committed only after every Lua
 * allocation succeeds, so an OOM or index reorder cannot consume another
 * device's samples. */
NVML_ABI int wtop_nvml_query(lua_State *L) {
    int include_processes = lua_toboolean(L, 1);
    nvml_api *a = nvml_context(L);
    const char *reason = nvml_open(a);
    if (reason) { lua_pushnil(L); lua_pushstring(L, reason); return 2; }
    unsigned int total = 0;
    nvml_return status = a->count(&total);
    if (status != 0) {
        if (status == 1 || status == 9 || status == 15) nvml_close(a);
        lua_pushnil(L); lua_pushliteral(L, "nvml_device_count_failed"); return 2;
    }
    unsigned int count = total > NVML_MAX_DEVICES ? NVML_MAX_DEVICES : total;
    int truncated = total > count, partial = truncated, returned = 0;
    sample_cursor pending[NVML_MAX_DEVICES]; memset(pending, 0, sizeof(pending));
    lua_createtable(L, 0, 5);
    char text[256]; memset(text, 0xff, sizeof(text));
    if (a->driver_version && a->driver_version(text, sizeof(text)) == 0 && valid_text(text, sizeof(text)))
        string_field(L, "driver_version", text);
    lua_createtable(L, (int)count, 0);
    for (unsigned int index = 0; index < count; ++index) {
        nvml_device device = NULL;
        if (a->handle(index, &device) != 0 || !device) { partial = 1; continue; }
        char uuid[128] = {0}; memset(text, 0xff, sizeof(text));
        if (a->uuid && a->uuid(device, text, sizeof(text)) == 0 && valid_text(text, sizeof(text))
            && strlen(text) < sizeof(uuid)) memcpy(uuid, text, strlen(text) + 1);
        unsigned long long previous = 0;
        int duplicate = 0;
        if (uuid[0]) {
            for (int i = 0; i < returned; ++i) if (strcmp(pending[i].uuid, uuid) == 0) duplicate = 1;
            for (int i = 0; i < NVML_MAX_DEVICES; ++i)
                if (strcmp(a->cursors[i].uuid, uuid) == 0) previous = a->cursors[i].timestamp;
        }
        if (duplicate) { partial = 1; continue; }
        lua_createtable(L, 0, 28);
        integer_field(L, "index", index);
        if (uuid[0]) string_field(L, "uuid", uuid);
        memset(text, 0xff, sizeof(text));
        if (a->name && a->name(device, text, sizeof(text)) == 0 && valid_text(text, sizeof(text)))
            string_field(L, "name", text);
        nvml_pci_info pci; memset(&pci, 0xff, sizeof(pci));
        if (a->pci && a->pci(device, &pci) == 0) {
            int address = pci_address(pci.bus_id, sizeof(pci.bus_id), &pci, text, sizeof(text));
            if (address == 0) address = pci_address(pci.bus_id_legacy,
                sizeof(pci.bus_id_legacy), &pci, text, sizeof(text));
            if (address == 1) string_field(L, "pci_bdf", text);
            if (pci.pci_device_id != UINT_MAX) {
                snprintf(text, sizeof(text), "0x%04x", pci.pci_device_id & 0xffff);
                string_field(L, "vendor_id", text);
                snprintf(text, sizeof(text), "0x%04x", pci.pci_device_id >> 16);
                string_field(L, "device_id", text);
            }
        }
        nvml_utilization utilization; memset(&utilization, 0xff, sizeof(utilization));
        if (a->utilization && a->utilization(device, &utilization) == 0) {
            if (utilization.gpu <= 100) integer_field(L, "utilization_percent", utilization.gpu);
            if (utilization.memory <= 100) integer_field(L, "memory_utilization_percent", utilization.memory);
        }
        nvml_memory memory; memset(&memory, 0xff, sizeof(memory));
        if (a->memory && a->memory(device, &memory) == 0 && memory.total < (1ULL << 50)) {
            integer_field(L, "memory_total_bytes", (lua_Integer)memory.total);
            if (memory.used <= memory.total) integer_field(L, "memory_used_bytes", (lua_Integer)memory.used);
        }
        unsigned int value = UINT_MAX;
        if (a->temperature && a->temperature(device, 0, &value) == 0 && value < 1000)
            integer_field(L, "temperature_celsius", value);
        device_power(L, a, device);
        value = UINT_MAX;
        if (a->clock && a->clock(device, 0, &value) == 0 && value < 100000)
            number_field(L, "graphics_clock_hz", value * 1000000.0);
        value = UINT_MAX;
        if (a->clock && a->clock(device, 2, &value) == 0 && value < 100000)
            number_field(L, "memory_clock_hz", value * 1000000.0);
        value = UINT_MAX;
        if (a->max_clock && a->max_clock(device, 0, &value) == 0 && value > 0 && value < 100000)
            number_field(L, "graphics_clock_maximum_hz", value * 1000000.0);
        value = UINT_MAX;
        if (a->fan && a->fan(device, &value) == 0 && value <= 100)
            integer_field(L, "fan_speed_percent", value);
        value = UINT_MAX;
        if (a->performance_state && a->performance_state(device, &value) == 0 && value <= 15) {
            snprintf(text, sizeof(text), "P%u", value); string_field(L, "performance_state", text);
        }
        clock_events(L, a, device);
        unsigned long long next = previous;
        if (include_processes) {
            process_row rows[NVML_MAX_PROCESSES]; int process_truncated = 0;
            allocation allocations[NVML_MAX_PROCESSES * 2]; int records_count = 0;
            int amount = collect_processes(a, device, previous, &next, rows, &process_truncated,
                allocations, &records_count);
            lua_createtable(L, amount, 0);
            for (int i = 0; i < amount; ++i) {
                lua_createtable(L, 0, 10);
                integer_field(L, "pid", rows[i].pid); string_field(L, "kind", rows[i].kind);
                if (rows[i].has_memory) {
                    integer_field(L, "memory_bytes", (lua_Integer)rows[i].memory);
                    string_field(L, "memory_quality", rows[i].memory_estimated ? "estimated" : "fresh");
                    string_field(L, "memory_scope", rows[i].memory_estimated ? "largest_reported_context"
                        : rows[i].has_whole ? "whole_device" : "reported_context");
                }
                lua_createtable(L, 0, 0); int contexts = 0;
                for (int j = 0; j < records_count; ++j) {
                    nvml_process p = allocations[j].value;
                    if (p.pid != rows[i].pid) continue;
                    lua_createtable(L, 0, 4);
                    if (p.gpu_instance_id != UINT_MAX) integer_field(L, "gpu_instance_id", p.gpu_instance_id);
                    if (p.compute_instance_id != UINT_MAX) integer_field(L, "compute_instance_id", p.compute_instance_id);
                    if (p.used_gpu_memory < (1ULL << 50)) integer_field(L, "memory_bytes", (lua_Integer)p.used_gpu_memory);
                    string_field(L, "kind", allocations[j].sources == 3 ? "compute+graphics"
                        : allocations[j].sources == 1 ? "compute" : "graphics");
                    lua_rawseti(L, -2, ++contexts);
                }
                lua_setfield(L, -2, "memory_contexts");
                if (rows[i].has_sample) {
                    integer_field(L, "sm_percent", rows[i].sm);
                    integer_field(L, "memory_percent", rows[i].memory_utilization);
                    integer_field(L, "encoder_percent", rows[i].encoder);
                    integer_field(L, "decoder_percent", rows[i].decoder);
                    integer_field(L, "sample_timestamp_us", (lua_Integer)rows[i].timestamp);
                    string_field(L, "sample_window", previous ? "since_last_query" : "driver_buffer");
                }
                lua_rawseti(L, -2, i + 1);
            }
            lua_setfield(L, -2, "processes");
            lua_pushboolean(L, process_truncated); lua_setfield(L, -2, "processes_truncated");
            if (process_truncated) partial = truncated = 1;
        }
        /* UUID is read again before committing identity/cursors. Keep explicit
         * missing identity; a replacement card is not the old card's sample. */
        if (uuid[0]) {
            memset(text, 0xff, sizeof(text));
            if (a->uuid(device, text, sizeof(text)) != 0 || !valid_text(text, sizeof(text)) || strcmp(text, uuid) != 0) {
                partial = 1; lua_pop(L, 1); continue;
            }
            memcpy(pending[returned].uuid, uuid, strlen(uuid) + 1);
            pending[returned].timestamp = next;
        }
        lua_rawseti(L, -2, ++returned);
    }
    lua_setfield(L, -2, "devices");
    unsigned int after = 0;
    if (a->count(&after) != 0 || after != total) partial = 1;
    string_field(L, "source", "nvml");
    string_field(L, "status", partial ? "partial" : "ok");
    if (partial) string_field(L, "reason", "nvml_enumeration_incomplete");
    lua_pushboolean(L, truncated); lua_setfield(L, -2, "truncated");
    memcpy(a->cursors, pending, sizeof(pending));
    return 1;
}
