/* AMD System Management Interface provider. libamdsmi ships with the amdgpu
 * driver, so it is opened at run time and nothing links against it; a host
 * without the library reports the provider as unavailable. Only read-only
 * queries are used.
 *
 * ABI posture: amdsmi is versioned in place, and the library is routinely
 * newer than any header wtop was built against. Every call here is therefore
 * resolved by name, guarded, and allowed to fail independently -- a struct
 * that moved, a symbol that was renamed or a query the running driver refuses
 * omits one field instead of poisoning the whole device. Nothing this file
 * reads is written back, so a mismatch degrades to a partial device rather
 * than acting on a misread value.
 *
 * Per-process usage is deliberately absent: amdsmi exposes no process
 * enumeration, and amdgpu's own /proc/<pid>/fdinfo is the richer source that
 * the DRM path already reads. */
#define _GNU_SOURCE

#include <lua.h>
#include <lauxlib.h>

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "wtop_amdsmi.h"

#define AMDSMI_MAX_SOCKETS 32
#define AMDSMI_MAX_PROCESSORS 64

/* The layouts below are the documented amdsmi ABI for the fields wtop reads.
 * They are kept minimal on purpose: a prefix is far more likely to stay valid
 * across versions than a trailing field, so nothing past what is read here is
 * declared. */
typedef struct {
    uint32_t domain;
    uint32_t bus;
    uint32_t device;
    uint32_t function;
    uint32_t pci_segment;
} amdsmi_bdf_info;

typedef struct {
    uint32_t gfx_activity;
    uint32_t umc_activity;
    uint32_t mm_activity;
} amdsmi_gpu_activity;

typedef struct {
    uint64_t vram_total;
    uint64_t vram_used;
} amdsmi_memory_usage;

typedef struct {
    uint32_t average_socket_power;
    uint32_t current_socket_power;
    uint32_t power_cap;
    uint32_t power_limit;
} amdsmi_power_info;

typedef struct {
    uint32_t model;
    uint32_t revision;
    uint32_t sub_revision;
} amdsmi_processor_handle;

typedef void *amdsmi_socket_handle;

typedef int amdsmi_status; /* AMDSMI_STATUS_SUCCESS = 0 */

typedef amdsmi_status (*amdsmi_init_function)(uint32_t);
typedef amdsmi_status (*amdsmi_status_function)(void);
typedef amdsmi_status (*amdsmi_socket_function)(uint32_t *, amdsmi_socket_handle *);
typedef amdsmi_status (*amdsmi_processor_function)(uint32_t *, amdsmi_processor_handle *);
typedef amdsmi_status (*amdsmi_bdf_function)(amdsmi_processor_handle *, amdsmi_bdf_info *);
typedef amdsmi_status (*amdsmi_handle_text_function)(amdsmi_processor_handle *, char **);
typedef amdsmi_status (*amdsmi_text_function)(char **);
typedef amdsmi_status (*amdsmi_activity_function)(amdsmi_processor_handle *,
    amdsmi_gpu_activity *);
typedef amdsmi_status (*amdsmi_memory_function)(amdsmi_processor_handle *,
    amdsmi_memory_usage *);
typedef amdsmi_status (*amdsmi_temp_function)(amdsmi_processor_handle *, int, int,
    uint64_t *);
typedef amdsmi_status (*amdsmi_power_function)(amdsmi_processor_handle *,
    amdsmi_power_info *);
typedef amdsmi_status (*amdsmi_clock_function)(amdsmi_processor_handle *, int,
    uint32_t *);
/* Fan speed takes no clock type and returns a signed percent, so it cannot
 * share the clock signature. */
typedef amdsmi_status (*amdsmi_fan_function)(amdsmi_processor_handle *, int *);

static struct {
    int state; /* 0 untried, 1 ready, -1 unavailable */
    const char *reason;
    amdsmi_status_function shutdown;
    amdsmi_socket_function sockets;
    amdsmi_processor_function processors;
    amdsmi_bdf_function bdf;
    amdsmi_handle_text_function uuid;
    amdsmi_handle_text_function name;
    amdsmi_text_function driver_version;
    amdsmi_activity_function activity;
    amdsmi_memory_function memory;
    amdsmi_temp_function temperature;
    amdsmi_power_function power;
    amdsmi_clock_function clock;
    amdsmi_clock_function max_clock;
    amdsmi_fan_function fan;
} amdsmi;

/* amdsmi enums used below, restated so the file does not need the SDK header
 * to build: AMDSMI_TEMP_TYPE_EDGE, AMDSMI_CLK_TYPE_GRAPHICS/MEMORY. */
#define AMDSMI_TEMP_TYPE_EDGE 1
#define AMDSMI_CLK_TYPE_GRAPHICS 1
#define AMDSMI_CLK_TYPE_MEMORY 2

static int amdsmi_open(void) {
    void *library;
    amdsmi_init_function init;
    if (amdsmi.state) return amdsmi.state > 0;
    amdsmi.state = -1;
    library = dlopen("libamdsmi.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        library = dlopen("libamdsmi.so", RTLD_NOW | RTLD_LOCAL);
    }
    if (!library) {
        amdsmi.reason = "amdsmi_library_not_found";
        return 0;
    }
    init = (amdsmi_init_function)dlsym(library, "amdsmi_init");
    amdsmi.shutdown = (amdsmi_status_function)dlsym(library, "amdsmi_shut_down");
    amdsmi.sockets = (amdsmi_socket_function)dlsym(library, "amdsmi_get_socket_handles");
    amdsmi.processors = (amdsmi_processor_function)dlsym(library,
        "amdsmi_get_processor_handles");
    amdsmi.bdf = (amdsmi_bdf_function)dlsym(library, "amdsmi_get_gpu_device_bdf");
    amdsmi.uuid = (amdsmi_handle_text_function)dlsym(library,
        "amdsmi_get_gpu_device_uuid");
    amdsmi.name = (amdsmi_handle_text_function)dlsym(library,
        "amdsmi_get_gpu_device_name");
    amdsmi.driver_version = (amdsmi_text_function)dlsym(library,
        "amdsmi_get_gpu_driver_version");
    amdsmi.activity = (amdsmi_activity_function)dlsym(library,
        "amdsmi_get_gpu_activity");
    amdsmi.memory = (amdsmi_memory_function)dlsym(library,
        "amdsmi_get_gpu_vram_usage");
    amdsmi.temperature = (amdsmi_temp_function)dlsym(library,
        "amdsmi_get_temp_metric");
    amdsmi.power = (amdsmi_power_function)dlsym(library, "amdsmi_get_power_info");
    amdsmi.clock = (amdsmi_clock_function)dlsym(library,
        "amdsmi_get_gpu_device_clock");
    amdsmi.max_clock = (amdsmi_clock_function)dlsym(library,
        "amdsmi_get_gpu_device_max_clock");
    amdsmi.fan = (amdsmi_fan_function)dlsym(library,
        "amdsmi_get_gpu_device_fan_speed");
    if (!init || !amdsmi.sockets || !amdsmi.processors) {
        amdsmi.reason = "amdsmi_symbols_missing";
        return 0;
    }
    if (init(0) != 0) {
        amdsmi.reason = "amdsmi_initialization_failed";
        return 0;
    }
    amdsmi.state = 1;
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

/* A sensor that reports all ones is the library's "unknown" marker, not a
 * reading; passing it on would paint a plausible-looking 4-billion on a
 * panel. */
static int plausible_number(double value, double ceiling) {
    return value == value && value >= 0 && value < ceiling;
}

static int bounded(unsigned long long value, unsigned long long ceiling) {
    return value < ceiling;
}

/* Collects the processor handles across every socket. A driver may expose
 * processors that no socket enumeration lists, so the socket walk is a
 * convenience rather than a requirement: when it yields nothing the result is
 * empty and the caller reports the provider as having no devices. */
static int collect_handles(amdsmi_processor_handle *handles, int capacity) {
    amdsmi_socket_handle sockets[AMDSMI_MAX_SOCKETS];
    int count = 0;
    if (!amdsmi.sockets || !amdsmi.processors) return 0;
    uint32_t socket_count = AMDSMI_MAX_SOCKETS;
    if (amdsmi.sockets(&socket_count, sockets) != 0) return 0;
    if (socket_count > AMDSMI_MAX_SOCKETS) socket_count = AMDSMI_MAX_SOCKETS;
    for (uint32_t index = 0; index < socket_count; ++index) {
        amdsmi_processor_handle batch[AMDSMI_MAX_PROCESSORS];
        uint32_t batch_count = AMDSMI_MAX_PROCESSORS;
        if (amdsmi.processors(&batch_count, batch) != 0) continue;
        if (batch_count > AMDSMI_MAX_PROCESSORS) batch_count = AMDSMI_MAX_PROCESSORS;
        for (uint32_t item = 0; item < batch_count; ++item) {
            if (count >= capacity) return count;
            int duplicate = 0;
            for (int found = 0; found < count; ++found) {
                if (handles[found].model == batch[item].model
                    && handles[found].revision == batch[item].revision
                    && handles[found].sub_revision == batch[item].sub_revision) {
                    duplicate = 1;
                    break;
                }
            }
            if (!duplicate) handles[count++] = batch[item];
        }
    }
    return count;
}

/* amdsmi_query([include_processes]) -> {driver_version, devices} | nil, reason
 *
 * include_processes is accepted and ignored: amdsmi has no process
 * enumeration, so there is nothing to opt into. */
int wtop_amdsmi_query(lua_State *L) {
    amdsmi_processor_handle handles[AMDSMI_MAX_PROCESSORS];
    int handle_count;
    if (!amdsmi_open()) {
        lua_pushnil(L);
        lua_pushstring(L, amdsmi.reason ? amdsmi.reason : "amdsmi_unavailable");
        return 2;
    }
    handle_count = collect_handles(handles, AMDSMI_MAX_PROCESSORS);
    lua_createtable(L, 0, 2);
    if (amdsmi.driver_version) {
        char *version = NULL;
        if (amdsmi.driver_version(&version) == 0 && version) {
            string_field(L, "driver_version", version);
        }
    }
    lua_createtable(L, handle_count > 0 ? handle_count : 0, 0);
    for (int index = 0; index < handle_count; ++index) {
        amdsmi_processor_handle handle = handles[index];
        amdsmi_bdf_info bdf;
        amdsmi_gpu_activity activity;
        amdsmi_memory_usage memory;
        amdsmi_power_info power;
        uint64_t temperature = 0;
        uint32_t clock = 0;
        lua_createtable(L, 0, 20);
        integer_field(L, "index", index);
        if (amdsmi.bdf && amdsmi.bdf(&handle, &bdf) == 0) {
            char text[32];
            snprintf(text, sizeof(text), "%04x:%02x:%02x.%x",
                bdf.domain & 0xffff, bdf.bus & 0xff, bdf.device & 0x1f,
                bdf.function & 0x7);
            string_field(L, "pci_bdf", text);
        }
        if (amdsmi.name) {
            char *value = NULL;
            if (amdsmi.name(&handle, &value) == 0 && value) {
                string_field(L, "name", value);
            }
        }
        if (amdsmi.uuid) {
            char *value = NULL;
            if (amdsmi.uuid(&handle, &value) == 0 && value) {
                string_field(L, "uuid", value);
            }
        }
        if (amdsmi.activity && amdsmi.activity(&handle, &activity) == 0) {
            /* gfx is the compute activity the table's utilisation column wants;
             * UMC is reported separately because on a card where the two
             * diverge, calling memory traffic "utilisation" would mislead. */
            if (bounded(activity.gfx_activity, 101)) {
                number_field(L, "utilization_percent", (double)activity.gfx_activity);
            }
            if (bounded(activity.umc_activity, 101)) {
                number_field(L, "memory_utilization_percent",
                    (double)activity.umc_activity);
            }
        }
        if (amdsmi.memory && amdsmi.memory(&handle, &memory) == 0) {
            if (bounded(memory.vram_total, 1ULL << 50)) {
                number_field(L, "memory_total_bytes", (double)memory.vram_total);
            }
            if (bounded(memory.vram_used, 1ULL << 50)) {
                number_field(L, "memory_used_bytes", (double)memory.vram_used);
            }
        }
        if (amdsmi.temperature
            && amdsmi.temperature(&handle, AMDSMI_TEMP_TYPE_EDGE, 0, &temperature) == 0
            && plausible_number((double)temperature, 1000)) {
            number_field(L, "temperature_celsius", (double)temperature);
        }
        if (amdsmi.power && amdsmi.power(&handle, &power) == 0) {
            if (bounded(power.average_socket_power, 100000u)) {
                number_field(L, "power_watts", (double)power.average_socket_power / 1000.0);
            }
            if (bounded(power.power_cap, 100000u)) {
                number_field(L, "power_limit_watts", (double)power.power_cap / 1000.0);
            }
        }
        if (amdsmi.clock
            && amdsmi.clock(&handle, AMDSMI_CLK_TYPE_GRAPHICS, &clock) == 0
            && bounded(clock, 100000u)) {
            number_field(L, "graphics_clock_hz", (double)clock * 1000000.0);
        }
        if (amdsmi.max_clock
            && amdsmi.max_clock(&handle, AMDSMI_CLK_TYPE_GRAPHICS, &clock) == 0
            && bounded(clock, 100000u)) {
            number_field(L, "graphics_clock_maximum_hz", (double)clock * 1000000.0);
        }
        if (amdsmi.clock
            && amdsmi.clock(&handle, AMDSMI_CLK_TYPE_MEMORY, &clock) == 0
            && bounded(clock, 100000u)) {
            number_field(L, "memory_clock_hz", (double)clock * 1000000.0);
        }
        if (amdsmi.fan) {
            int fan = 0;
            if (amdsmi.fan(&handle, &fan) == 0 && plausible_number((double)fan, 101)) {
                number_field(L, "fan_speed_percent", (double)fan);
            }
        }
        lua_rawseti(L, -2, index + 1);
    }
    return 1;
}
