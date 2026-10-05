/* Level Zero provider for Intel GPUs.
 *
 * libze_loader ships with the Intel compute runtime and is opened at run time,
 * so nothing links against it; a host without it reports the provider as
 * unavailable. Only read-only queries are used.
 *
 * ABI posture, and it is stricter here than for amdsmi. Level Zero expresses
 * device identity and engine inventory through large, append-only,
 * versioned structures -- ze_device_properties_t, ze_engine_properties_t,
 * ze_engine_utilities_t. wtop does not build against the Level Zero SDK, so
 * the element stride of those arrays cannot be known: reading a struct array
 * with a guessed stride does not degrade, it walks off the end of the real
 * one. This file therefore crosses the boundary with nothing but pointers,
 * doubles and 32-bit integers:
 *
 *   - device handles and power-domain handles are opaque pointers, so the
 *     arrays that carry them have a known element size;
 *   - temperature is an out-parameter double;
 *   - frequency and power are out-parameter uint32_t.
 *
 * That is exactly the set that fills the gap on Intel hardware, where i915
 * sysfs exposes neither an edge temperature nor a package power reading.
 * Device name, UUID and engine utilization are deliberately left to the DRM
 * and fdinfo paths rather than guessed at from a misread structure. */
#define _GNU_SOURCE

#include <lua.h>
#include <lauxlib.h>

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "wtop_levelzero.h"

#define L0_MAX_DRIVERS 8
#define L0_MAX_DEVICES 32
#define L0_MAX_POWER_DOMAINS 16

/* Enums restated so the file needs no SDK header. */
#define ZE_DRIVER_TYPE_GPU 0x1
#define ZE_INIT_FLAG_GPU_ONLY 0x1
#define ZE_STRUCTURE_TYPE_INIT_FLAGS 0x0
#define ZE_DEVICE_TEMPERATURE_SENSORS_GPU 0x1
#define ZE_FREQ_DOMAIN_GPU 0x1
#define ZE_FREQ_DOMAIN_MEMORY 0x2

/* ze_result_t ZE_RESULT_SUCCESS = 0 */
typedef int ze_result;

/* ze_init_flags_t: every Level Zero structure opens with this three-field
 * prefix, and it is append-only, so naming just the prefix is stable. */
typedef struct {
    uint32_t stype;
    uint32_t reserved;
    const void *pNext;
    uint32_t flags;
} ze_init_flags;

typedef void *ze_driver_handle;
typedef void *ze_device_handle;
typedef void *ze_power_domain_handle;

typedef ze_result (*ze_init_function)(ze_init_flags *);
typedef ze_result (*ze_driver_get_function)(uint32_t, uint32_t *, ze_driver_handle *);
typedef ze_result (*ze_device_get_function)(ze_driver_handle, uint32_t *, ze_device_handle *);
typedef ze_result (*ze_temperature_function)(ze_device_handle, uint32_t, uint32_t, double *);
typedef ze_result (*ze_frequency_function)(ze_device_handle, uint32_t, uint32_t *);
typedef ze_result (*ze_power_domain_function)(ze_device_handle, uint32_t *,
    ze_power_domain_handle *);
typedef ze_result (*ze_power_function)(ze_device_handle, ze_power_domain_handle,
    uint32_t *);

static struct {
    int state; /* 0 untried, 1 ready, -1 unavailable */
    const char *reason;
    ze_driver_get_function driver_get;
    ze_device_get_function device_get;
    ze_temperature_function temperature;
    ze_frequency_function frequency;
    ze_power_domain_function power_domains;
    ze_power_function power;
} levelzero;

static int levelzero_open(void) {
    void *library;
    ze_init_function init;
    if (levelzero.state) return levelzero.state > 0;
    levelzero.state = -1;
    library = dlopen("libze_loader.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!library) library = dlopen("libze_loader.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        levelzero.reason = "levelzero_library_not_found";
        return 0;
    }
    init = (ze_init_function)dlsym(library, "zeInit");
    levelzero.driver_get = (ze_driver_get_function)dlsym(library, "zeDriverGet");
    levelzero.device_get = (ze_device_get_function)dlsym(library, "zeDeviceGet");
    levelzero.temperature = (ze_temperature_function)dlsym(library,
        "zeDeviceGetTemperature");
    levelzero.frequency = (ze_frequency_function)dlsym(library,
        "zeDeviceGetFrequency");
    levelzero.power_domains = (ze_power_domain_function)dlsym(library,
        "zeDeviceEnumPowerDomains");
    levelzero.power = (ze_power_function)dlsym(library, "zeDeviceGetPower");
    if (!init || !levelzero.driver_get || !levelzero.device_get) {
        levelzero.reason = "levelzero_symbols_missing";
        return 0;
    }
    ze_init_flags flags;
    memset(&flags, 0, sizeof(flags));
    flags.stype = ZE_STRUCTURE_TYPE_INIT_FLAGS;
    flags.flags = ZE_INIT_FLAG_GPU_ONLY;
    if (init(&flags) != 0) {
        levelzero.reason = "levelzero_initialization_failed";
        return 0;
    }
    levelzero.state = 1;
    return 1;
}

static void number_field(lua_State *L, const char *name, lua_Number value) {
    lua_pushnumber(L, value);
    lua_setfield(L, -2, name);
}

static void integer_field(lua_State *L, const char *name, lua_Integer value) {
    lua_pushinteger(L, value);
    lua_setfield(L, -2, name);
}

/* Drivers report "unsupported" by leaving the out-parameter at its maximum.
 * Passing that on would print a four-billion-degree GPU. */
static int plausible_number(double value, double ceiling) {
    return value == value && value >= 0 && value < ceiling;
}

static int bounded(uint32_t value, uint32_t ceiling) {
    return value < ceiling;
}

/* Package power is the sum across the device's power domains, which is what
 * "board power" means: each domain reports one rail or package limit, and
 * adding them is how the vendor's own tools report a whole-card figure. */
static int collect_board_power(ze_device_handle device, double *watts) {
    ze_power_domain_handle domains[L0_MAX_POWER_DOMAINS];
    uint32_t count = L0_MAX_POWER_DOMAINS;
    if (!levelzero.power_domains || !levelzero.power) return 0;
    if (levelzero.power_domains(device, &count, domains) != 0) return 0;
    if (count > L0_MAX_POWER_DOMAINS) count = L0_MAX_POWER_DOMAINS;
    double total = 0;
    int reported = 0;
    for (uint32_t index = 0; index < count; ++index) {
        uint32_t milliwatts = 0;
        if (levelzero.power(device, domains[index], &milliwatts) != 0) continue;
        if (!bounded(milliwatts, 100000u)) continue;
        total += (double)milliwatts / 1000.0;
        reported = 1;
    }
    if (!reported) return 0;
    *watts = total;
    return 1;
}

/* levelzero_query([include_processes]) -> {driver, devices} | nil, reason
 *
 * include_processes is accepted and ignored: Level Zero has no process
 * enumeration, and per-process usage comes from the DRM fdinfo path. */
int wtop_levelzero_query(lua_State *L) {
    ze_driver_handle drivers[L0_MAX_DRIVERS];
    ze_device_handle devices[L0_MAX_DEVICES];
    uint32_t driver_count = L0_MAX_DRIVERS;
    int device_total = 0;
    if (!levelzero_open()) {
        lua_pushnil(L);
        lua_pushstring(L, levelzero.reason ? levelzero.reason : "levelzero_unavailable");
        return 2;
    }
    if (levelzero.driver_get(ZE_DRIVER_TYPE_GPU, &driver_count, drivers) != 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "levelzero_driver_enumeration_failed");
        return 2;
    }
    if (driver_count > L0_MAX_DRIVERS) driver_count = L0_MAX_DRIVERS;
    for (uint32_t driver = 0; driver < driver_count; ++driver) {
        uint32_t count = L0_MAX_DEVICES;
        if (levelzero.device_get(drivers[driver], &count, devices) != 0) continue;
        if (count > L0_MAX_DEVICES) count = L0_MAX_DEVICES;
        for (uint32_t index = 0; index < count; ++index) {
            if (device_total < L0_MAX_DEVICES) devices[device_total++] = devices[index];
        }
    }
    lua_createtable(L, 0, 2);
    integer_field(L, "driver_count", (lua_Integer)driver_count);
    lua_createtable(L, device_total > 0 ? device_total : 0, 0);
    for (int index = 0; index < device_total; ++index) {
        ze_device_handle device = devices[index];
        uint32_t value = 0;
        double temperature = 0;
        double board_watts = 0;
        int has_board_power;
        lua_createtable(L, 0, 8);
        integer_field(L, "index", index);
        if (levelzero.temperature
            && levelzero.temperature(device, ZE_DEVICE_TEMPERATURE_SENSORS_GPU, 0,
                &temperature) == 0
            && plausible_number(temperature, 1000)) {
            number_field(L, "temperature_celsius", temperature);
        }
        if (levelzero.frequency
            && levelzero.frequency(device, ZE_FREQ_DOMAIN_GPU, &value) == 0
            && bounded(value, 100000u)) {
            number_field(L, "graphics_clock_hz", (double)value * 1000000.0);
        }
        if (levelzero.frequency
            && levelzero.frequency(device, ZE_FREQ_DOMAIN_MEMORY, &value) == 0
            && bounded(value, 100000u)) {
            number_field(L, "memory_clock_hz", (double)value * 1000000.0);
        }
        has_board_power = collect_board_power(device, &board_watts);
        if (has_board_power && plausible_number(board_watts, 100000)) {
            number_field(L, "board_power_watts", board_watts);
        }
        lua_rawseti(L, -2, index + 1);
    }
    return 1;
}
