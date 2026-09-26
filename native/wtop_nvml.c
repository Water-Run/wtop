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

#include "wtop_nvml.h"

#define NVML_MAX_DEVICES 64
#define NVML_MAX_PROCESSES 256

typedef void *nvml_device;
typedef int nvml_return; /* NVML_SUCCESS = 0 */

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

typedef nvml_return (*nvml_init_function)(void);
typedef nvml_return (*nvml_count_function)(unsigned int *);
typedef nvml_return (*nvml_handle_function)(unsigned int, nvml_device *);
typedef nvml_return (*nvml_text_function)(nvml_device, char *, unsigned int);
typedef nvml_return (*nvml_system_text_function)(char *, unsigned int);
typedef nvml_return (*nvml_pci_function)(nvml_device, nvml_pci_info *);
typedef nvml_return (*nvml_utilization_function)(nvml_device, nvml_utilization *);
typedef nvml_return (*nvml_memory_function)(nvml_device, nvml_memory *);
typedef nvml_return (*nvml_sensor_function)(nvml_device, int, unsigned int *);
typedef nvml_return (*nvml_value_function)(nvml_device, unsigned int *);
typedef nvml_return (*nvml_state_function)(nvml_device, int *);
typedef nvml_return (*nvml_processes_function)(nvml_device, unsigned int *, nvml_process *);
typedef nvml_return (*nvml_samples_function)(nvml_device, nvml_process_sample *,
    unsigned int *, unsigned long long);
typedef const char *(*nvml_error_function)(nvml_return);

static struct {
    int state; /* 0 untried, 1 ready, -1 unavailable */
    const char *reason;
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
    nvml_samples_function process_samples;
    unsigned long long last_sample[NVML_MAX_DEVICES];
} nvml;

static void *symbol(void *library, const char *name, const char *fallback) {
    void *found = dlsym(library, name);
    if (!found && fallback) found = dlsym(library, fallback);
    return found;
}

static int nvml_open(void) {
    void *library;
    nvml_init_function init;
    if (nvml.state) return nvml.state > 0;
    nvml.state = -1;
    library = dlopen("libnvidia-ml.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        nvml.reason = "nvml_library_not_found";
        return 0;
    }
    init = (nvml_init_function)symbol(library, "nvmlInit_v2", "nvmlInit");
    nvml.count = (nvml_count_function)symbol(library, "nvmlDeviceGetCount_v2",
        "nvmlDeviceGetCount");
    nvml.handle = (nvml_handle_function)symbol(library,
        "nvmlDeviceGetHandleByIndex_v2", "nvmlDeviceGetHandleByIndex");
    nvml.name = (nvml_text_function)symbol(library, "nvmlDeviceGetName", NULL);
    nvml.uuid = (nvml_text_function)symbol(library, "nvmlDeviceGetUUID", NULL);
    nvml.driver_version = (nvml_system_text_function)symbol(library,
        "nvmlSystemGetDriverVersion", NULL);
    nvml.pci = (nvml_pci_function)symbol(library, "nvmlDeviceGetPciInfo_v3",
        "nvmlDeviceGetPciInfo_v2");
    nvml.utilization = (nvml_utilization_function)symbol(library,
        "nvmlDeviceGetUtilizationRates", NULL);
    nvml.memory = (nvml_memory_function)symbol(library, "nvmlDeviceGetMemoryInfo", NULL);
    nvml.temperature = (nvml_sensor_function)symbol(library,
        "nvmlDeviceGetTemperature", NULL);
    nvml.power = (nvml_value_function)symbol(library, "nvmlDeviceGetPowerUsage", NULL);
    nvml.power_limit = (nvml_value_function)symbol(library,
        "nvmlDeviceGetEnforcedPowerLimit", NULL);
    nvml.clock = (nvml_sensor_function)symbol(library, "nvmlDeviceGetClockInfo", NULL);
    nvml.max_clock = (nvml_sensor_function)symbol(library,
        "nvmlDeviceGetMaxClockInfo", NULL);
    nvml.fan = (nvml_value_function)symbol(library, "nvmlDeviceGetFanSpeed", NULL);
    nvml.performance_state = (nvml_state_function)symbol(library,
        "nvmlDeviceGetPerformanceState", NULL);
    nvml.compute_processes = (nvml_processes_function)symbol(library,
        "nvmlDeviceGetComputeRunningProcesses_v3", NULL);
    nvml.graphics_processes = (nvml_processes_function)symbol(library,
        "nvmlDeviceGetGraphicsRunningProcesses_v3", NULL);
    nvml.process_samples = (nvml_samples_function)symbol(library,
        "nvmlDeviceGetProcessUtilization", NULL);
    if (!init || !nvml.count || !nvml.handle) {
        nvml.reason = "nvml_symbols_missing";
        return 0;
    }
    if (init() != 0) {
        nvml.reason = "nvml_initialization_failed";
        return 0;
    }
    nvml.state = 1;
    return 1;
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
    unsigned long long memory;
    int has_memory;
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

static int collect_processes(nvml_device device, unsigned int index,
    process_row *rows) {
    int count = 0;
    nvml_processes_function sources[2] = {nvml.compute_processes, nvml.graphics_processes};
    const char *kinds[2] = {"compute", "graphics"};
    for (int source = 0; source < 2; ++source) {
        nvml_process processes[NVML_MAX_PROCESSES];
        unsigned int returned = NVML_MAX_PROCESSES;
        if (!sources[source] || sources[source](device, &returned, processes) != 0)
            continue;
        for (unsigned int item = 0; item < returned && item < NVML_MAX_PROCESSES; ++item) {
            int found = find_process(rows, count, processes[item].pid);
            if (found < 0) {
                if (count >= NVML_MAX_PROCESSES) break;
                found = count++;
                memset(&rows[found], 0, sizeof(rows[0]));
                rows[found].pid = processes[item].pid;
                rows[found].kind = kinds[source];
            }
            /* NVML reports an unknown value as all ones. */
            if (processes[item].used_gpu_memory != ~0ULL) {
                rows[found].memory += processes[item].used_gpu_memory;
                rows[found].has_memory = 1;
            }
        }
    }
    if (nvml.process_samples && index < NVML_MAX_DEVICES) {
        nvml_process_sample samples[NVML_MAX_PROCESSES];
        unsigned int returned = NVML_MAX_PROCESSES;
        unsigned long long newest = nvml.last_sample[index];
        if (nvml.process_samples(device, samples, &returned, nvml.last_sample[index]) == 0) {
            for (unsigned int item = 0; item < returned && item < NVML_MAX_PROCESSES; ++item) {
                int found = find_process(rows, count, samples[item].pid);
                if (found < 0) {
                    if (count >= NVML_MAX_PROCESSES) break;
                    found = count++;
                    memset(&rows[found], 0, sizeof(rows[0]));
                    rows[found].pid = samples[item].pid;
                    rows[found].kind = "sampled";
                }
                if (samples[item].sm > rows[found].sm) rows[found].sm = samples[item].sm;
                if (samples[item].memory > rows[found].memory_utilization)
                    rows[found].memory_utilization = samples[item].memory;
                if (samples[item].encoder > rows[found].encoder)
                    rows[found].encoder = samples[item].encoder;
                if (samples[item].decoder > rows[found].decoder)
                    rows[found].decoder = samples[item].decoder;
                rows[found].has_sample = 1;
                if (samples[item].timestamp > newest) newest = samples[item].timestamp;
            }
        }
        nvml.last_sample[index] = newest;
    }
    return count;
}

/* nvml_query([include_processes]) -> {driver_version, devices} | nil, reason */
int wtop_nvml_query(lua_State *L) {
    unsigned int count = 0;
    int include_processes = lua_toboolean(L, 1);
    char text[96];
    if (!nvml_open()) {
        lua_pushnil(L);
        lua_pushstring(L, nvml.reason ? nvml.reason : "nvml_unavailable");
        return 2;
    }
    if (nvml.count(&count) != 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "nvml_device_count_failed");
        return 2;
    }
    if (count > NVML_MAX_DEVICES) count = NVML_MAX_DEVICES;
    lua_createtable(L, 0, 3);
    if (nvml.driver_version && nvml.driver_version(text, sizeof(text)) == 0) {
        text[sizeof(text) - 1] = 0;
        string_field(L, "driver_version", text);
    }
    lua_createtable(L, (int)count, 0);
    for (unsigned int index = 0; index < count; ++index) {
        nvml_device device = NULL;
        nvml_pci_info pci;
        nvml_utilization utilization;
        nvml_memory memory;
        unsigned int value = 0;
        int state = 0;
        if (nvml.handle(index, &device) != 0 || !device) continue;
        lua_createtable(L, 0, 24);
        integer_field(L, "index", index);
        if (nvml.name && nvml.name(device, text, sizeof(text)) == 0) {
            text[sizeof(text) - 1] = 0;
            string_field(L, "name", text);
        }
        if (nvml.uuid && nvml.uuid(device, text, sizeof(text)) == 0) {
            text[sizeof(text) - 1] = 0;
            string_field(L, "uuid", text);
        }
        if (nvml.pci && nvml.pci(device, &pci) == 0) {
            snprintf(text, sizeof(text), "%04x:%02x:%02x.0", pci.domain & 0xffff,
                pci.bus & 0xff, pci.device & 0x1f);
            string_field(L, "pci_bdf", text);
            snprintf(text, sizeof(text), "0x%04x", pci.pci_device_id & 0xffff);
            string_field(L, "vendor_id", text);
            snprintf(text, sizeof(text), "0x%04x", pci.pci_device_id >> 16);
            string_field(L, "device_id", text);
        }
        if (nvml.utilization && nvml.utilization(device, &utilization) == 0) {
            integer_field(L, "utilization_percent", utilization.gpu);
            integer_field(L, "memory_utilization_percent", utilization.memory);
        }
        if (nvml.memory && nvml.memory(device, &memory) == 0 && memory.total > 0) {
            integer_field(L, "memory_total_bytes", (lua_Integer)memory.total);
            integer_field(L, "memory_used_bytes", (lua_Integer)memory.used);
        }
        if (nvml.temperature && nvml.temperature(device, 0, &value) == 0)
            integer_field(L, "temperature_celsius", value);
        if (nvml.power && nvml.power(device, &value) == 0)
            number_field(L, "power_watts", value / 1000.0);
        if (nvml.power_limit && nvml.power_limit(device, &value) == 0)
            number_field(L, "power_limit_watts", value / 1000.0);
        /* Clock domains: 0 graphics, 1 SM, 2 memory. */
        if (nvml.clock && nvml.clock(device, 0, &value) == 0)
            integer_field(L, "graphics_clock_hz", (lua_Integer)value * 1000000);
        if (nvml.clock && nvml.clock(device, 2, &value) == 0 && value > 0)
            integer_field(L, "memory_clock_hz", (lua_Integer)value * 1000000);
        if (nvml.max_clock && nvml.max_clock(device, 0, &value) == 0 && value > 0)
            integer_field(L, "graphics_clock_maximum_hz", (lua_Integer)value * 1000000);
        if (nvml.fan && nvml.fan(device, &value) == 0)
            integer_field(L, "fan_speed_percent", value);
        if (nvml.performance_state && nvml.performance_state(device, &state) == 0
            && state >= 0 && state < 32) {
            snprintf(text, sizeof(text), "P%d", state);
            string_field(L, "performance_state", text);
        }
        if (include_processes) {
            process_row rows[NVML_MAX_PROCESSES];
            int rows_count = collect_processes(device, index, rows);
            lua_createtable(L, rows_count, 0);
            for (int row = 0; row < rows_count; ++row) {
                lua_createtable(L, 0, 8);
                integer_field(L, "pid", rows[row].pid);
                string_field(L, "kind", rows[row].kind);
                if (rows[row].has_memory)
                    integer_field(L, "memory_bytes", (lua_Integer)rows[row].memory);
                if (rows[row].has_sample) {
                    integer_field(L, "sm_percent", rows[row].sm);
                    integer_field(L, "memory_percent", rows[row].memory_utilization);
                    integer_field(L, "encoder_percent", rows[row].encoder);
                    integer_field(L, "decoder_percent", rows[row].decoder);
                }
                lua_rawseti(L, -2, row + 1);
            }
            lua_setfield(L, -2, "processes");
        }
        lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
    }
    lua_setfield(L, -2, "devices");
    string_field(L, "source", "nvml");
    return 1;
}
