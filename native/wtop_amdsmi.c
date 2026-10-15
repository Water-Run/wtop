/* Read-only AMD SMI queries. The SDK is optional and loaded at runtime.
 * Output layouts are selected from verified public SDK versions, rather than
 * passing shorter prefixes to functions that write complete structures.
 * Process counters continue to come from DRM fdinfo. */
#define _GNU_SOURCE
#include <lua.h>
#include <lauxlib.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "wtop_amdsmi.h"
#include "wtop_amdsmi_abi.h"

/* AMD SDK interface-declaration notice. An exported constant keeps the
 * notice in native modules and in onefile payloads as well as source trees. */
const char wtop_amdsmi_abi_license[] =
    "Copyright (c) Advanced Micro Devices, Inc. All rights reserved.\n"
    "\n"
    "Permission is hereby granted, free of charge, to any person obtaining a copy\n"
    "of this software and associated documentation files (the \"Software\"), to deal\n"
    "in the Software without restriction, including without limitation the rights\n"
    "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell\n"
    "copies of the Software, and to permit persons to whom the Software is\n"
    "furnished to do so, subject to the following conditions:\n"
    "\n"
    "The above copyright notice and this permission notice shall be included in\n"
    "all copies or substantial portions of the Software.\n"
    "\n"
    "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\n"
    "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\n"
    "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\n"
    "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\n"
    "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\n"
    "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN\n"
    "THE SOFTWARE.\n"
    ;

/* This is a POSIX dlsym ABI bridge. Clang's function sanitizer compares C
 * enum/anonymous-struct type names, which differ between the local versioned
 * declarations and the SDK translation unit even when the ABI matches. Only
 * that check is excluded at the bridge; ASan and all other UBSan checks remain
 * active. Tests compile the fake DSO against each original public SDK header. */
#if defined(__clang__)
#define SDK_ABI __attribute__((no_sanitize("function")))
#else
#define SDK_ABI
#endif

#define MAX_SOCKETS 32
#define MAX_DEVICES 64
#define GPU_INIT_FLAGS UINT64_C(2)
#define AMD_GPU_TYPE 1

typedef void *handle;
typedef uint32_t (*init_fn)(uint64_t);
typedef uint32_t (*shutdown_fn)(void);
typedef uint32_t (*output_fn)(void *);
typedef uint32_t (*sockets_fn)(uint32_t *, handle *);
typedef uint32_t (*processors_fn)(handle, uint32_t *, handle *);
typedef uint32_t (*type_fn)(handle, uint32_t *);
typedef uint32_t (*device_output_fn)(handle, void *);
typedef uint32_t (*uuid_fn)(handle, unsigned int *, char *);
typedef uint32_t (*driver_fn)(handle, int *, char *);
typedef uint32_t (*memory_fn)(handle, uint32_t, uint64_t *);
typedef uint32_t (*temp_fn)(handle, uint32_t, uint32_t, int64_t *);
typedef uint32_t (*clock_fn)(handle, uint32_t, void *);
typedef uint32_t (*cap_fn)(handle, uint32_t, wtop_amd_power_cap *);
typedef uint32_t (*fan_fn)(handle, uint32_t, int64_t *);
typedef uint32_t (*fan_max_fn)(handle, uint32_t, uint64_t *);

typedef struct {
    void *library;
    init_fn init;
    shutdown_fn shutdown;
    output_fn version;
    sockets_fn sockets;
    processors_fn processors;
    type_fn type;
    device_output_fn bdf, asic, driver_info, activity, power;
    uuid_fn uuid;
    driver_fn driver;
    memory_fn memory_total, memory_used;
    temp_fn temperature;
    clock_fn clock;
    cap_fn cap;
    fan_fn fan;
    fan_max_fn fan_max;
} api;

enum metric { UTILIZATION, MEMORY_UTILIZATION, MEMORY_TOTAL, MEMORY_USED,
    TEMPERATURE, POWER, POWER_LIMIT, GRAPHICS_CLOCK, GRAPHICS_MAX,
    MEMORY_CLOCK, FAN_PERCENT, METRIC_COUNT };
static const char *const metric_names[METRIC_COUNT] = {
    "utilization_percent", "memory_utilization_percent", "memory_total_bytes",
    "memory_used_bytes", "temperature_celsius", "power_watts", "power_limit_watts",
    "graphics_clock_hz", "graphics_clock_maximum_hz", "memory_clock_hz",
    "fan_speed_percent"
};
typedef struct {
    unsigned int present;
    double metrics[METRIC_COUNT];
    char name[257], uuid[257], driver[257], bdf[20];
    const char *power_measurement;
} device;
typedef struct {
    device devices[MAX_DEVICES];
    int count, partial, truncated;
    char version[48];
} snapshot;

static void text_copy(char *dest, size_t capacity, const char *value, size_t length) {
    const char *end = memchr(value, 0, length);
    if (!end || end == value || (size_t)(end - value) >= capacity) return;
    size_t size = (size_t)(end - value);
    memcpy(dest, value, size); dest[size] = 0;
}
static void reading(device *dev, enum metric key, double value) {
    dev->metrics[key] = value;
    dev->present |= 1u << key;
}
/* Both 0xffff and all ones occur as unsupported markers in the Linux SDK.
 * A genuine zero-watt idle reading remains valid. */
static int watts_valid(uint64_t value) {
    return value != UINT16_MAX && value != UINT32_MAX && value < 100000;
}
static int clock_valid(uint32_t value) {
    return value != UINT16_MAX && value < 100000;
}

static const char *open_api(api *a) {
    static const char *const libraries[] = {
        "libamd_smi.so", "libamd_smi.so.26", "libamd_smi.so.25",
        "libamd_smi.so.24", "libamd_smi.so.23", "libamd_smi.so.1"
    };
    memset(a, 0, sizeof(*a));
    for (size_t i = 0; i < sizeof(libraries) / sizeof(libraries[0]); ++i) {
        a->library = dlopen(libraries[i], RTLD_NOW | RTLD_LOCAL);
        if (a->library) break;
    }
    if (!a->library) return "amdsmi_library_not_found";
#define RESOLVE(field, type, symbol) a->field = (type)dlsym(a->library, symbol)
    RESOLVE(init, init_fn, "amdsmi_init");
    RESOLVE(shutdown, shutdown_fn, "amdsmi_shut_down");
    RESOLVE(version, output_fn, "amdsmi_get_lib_version");
    RESOLVE(sockets, sockets_fn, "amdsmi_get_socket_handles");
    RESOLVE(processors, processors_fn, "amdsmi_get_processor_handles");
    RESOLVE(type, type_fn, "amdsmi_get_processor_type");
    RESOLVE(bdf, device_output_fn, "amdsmi_get_gpu_device_bdf");
    RESOLVE(asic, device_output_fn, "amdsmi_get_gpu_asic_info");
    RESOLVE(driver_info, device_output_fn, "amdsmi_get_gpu_driver_info");
    RESOLVE(driver, driver_fn, "amdsmi_get_gpu_driver_version");
    RESOLVE(uuid, uuid_fn, "amdsmi_get_gpu_device_uuid");
    RESOLVE(activity, device_output_fn, "amdsmi_get_gpu_activity");
    RESOLVE(memory_total, memory_fn, "amdsmi_get_gpu_memory_total");
    RESOLVE(memory_used, memory_fn, "amdsmi_get_gpu_memory_usage");
    RESOLVE(temperature, temp_fn, "amdsmi_get_temp_metric");
    RESOLVE(power, device_output_fn, "amdsmi_get_power_info");
    RESOLVE(cap, cap_fn, "amdsmi_get_power_cap_info");
    RESOLVE(clock, clock_fn, "amdsmi_get_clock_info");
    RESOLVE(fan, fan_fn, "amdsmi_get_gpu_fan_speed");
    RESOLVE(fan_max, fan_max_fn, "amdsmi_get_gpu_fan_speed_max");
#undef RESOLVE
    if (!a->init || !a->shutdown || !a->version || !a->sockets
        || !a->processors || !a->type) return "amdsmi_symbols_missing";
    return NULL;
}

/* The version getter itself has two complete layouts. Bootstrap into an
 * aligned union large enough for both; never dereference its build pointer.
 * Unknown version tuples do not authorize any variable-layout output calls. */
SDK_ABI static int version_profile(api *a, snapshot *s) {
    union {
        wtop_amd_version_232 legacy;
        wtop_amd_version_262 modern;
        uint32_t words[8];
    } version;
    memset(&version, 0xff, sizeof(version));
    if (a->version(&version) != 0) return 0;
    uint32_t *v = version.words;
    if (v[0] == 26) {
        snprintf(s->version, sizeof(s->version), "%u.%u.%u", v[0], v[1], v[2]);
        if (v[1] == 0 && v[2] == 2) return 260;
        if (v[1] == 2 && (v[2] == 0 || v[2] == 2)) return 262;
    } else {
        snprintf(s->version, sizeof(s->version), "%u.%u.%u.%u", v[0], v[1], v[2], v[3]);
        if (v[0] == 23 && v[1] == 2 && v[2] == 0 && v[3] == 1) return 232;
        if (v[0] == 23 && v[1] == 4 && v[2] == 0 && v[3] == 0) return 234;
        if (v[0] == 24 && v[1] == 5 && v[2] == 2 && v[3] == 0) return 245;
        if (v[0] == 24 && v[1] == 6 && v[2] == 3 && v[3] == 0) return 246;
        if (v[0] == 25 && v[1] == 1 && v[2] == 0 && v[3] == 0) return 251;
        if (v[0] == 25 && v[1] == 25 && v[2] == 5 && v[3] == 1) return 255;
    }
    return 0;
}

SDK_ABI static const char *collect_handles(api *a, snapshot *s, handle *handles, int *count) {
    handle sockets[MAX_SOCKETS] = {0};
    uint32_t needed = 0;
    if (a->sockets(&needed, NULL) != 0) return "amdsmi_socket_query_failed";
    if (needed == 0) return NULL;
    uint32_t capacity = needed < MAX_SOCKETS ? needed : MAX_SOCKETS;
    uint32_t size = capacity;
    if (needed > MAX_SOCKETS) s->truncated = s->partial = 1;
    if (a->sockets(&size, sockets) != 0 || size > capacity) {
        s->partial = 1;
        if (size > capacity) s->truncated = 1;
        return "amdsmi_socket_query_failed";
    }
    for (uint32_t i = 0; i < size; ++i) {
        if (!sockets[i]) { s->partial = 1; continue; }
        needed = 0;
        if (a->processors(sockets[i], &needed, NULL) != 0) {
            s->partial = 1; continue;
        }
        if (needed == 0) continue;
        handle batch[MAX_DEVICES] = {0};
        capacity = needed < MAX_DEVICES ? needed : MAX_DEVICES;
        uint32_t amount = capacity;
        if (needed > MAX_DEVICES) s->truncated = s->partial = 1;
        if (a->processors(sockets[i], &amount, batch) != 0 || amount > capacity) {
            s->partial = 1;
            if (amount > capacity) s->truncated = 1;
            continue;
        }
        for (uint32_t j = 0; j < amount; ++j) {
            uint32_t type = UINT32_MAX; int duplicate = 0;
            if (!batch[j] || a->type(batch[j], &type) != 0) { s->partial = 1; continue; }
            if (type != AMD_GPU_TYPE) continue;
            for (int k = 0; k < *count; ++k) if (handles[k] == batch[j]) duplicate = 1;
            if (duplicate) continue;
            if (*count == MAX_DEVICES) { s->truncated = s->partial = 1; continue; }
            handles[(*count)++] = batch[j];
        }
    }
    return NULL;
}

/* Each case allocates the complete SDK structure, including reserved fields.
 * New versions must be checked against their public header before adding a
 * tuple above. A symbol existing alone says nothing about output size. */
SDK_ABI static void identity(api *a, handle h, int profile, device *d) {
#define IDENTITY_CASE(p) case p: { \
    wtop_amd_asic_info_##p value; memset(&value, 0xff, sizeof(value)); \
    if (a->asic && a->asic(h, &value) == 0) \
        text_copy(d->name, sizeof(d->name), value.market_name, sizeof(value.market_name)); \
    break; }
    switch (profile) {
        IDENTITY_CASE(232) IDENTITY_CASE(234) IDENTITY_CASE(245) IDENTITY_CASE(246)
        IDENTITY_CASE(251) IDENTITY_CASE(255) IDENTITY_CASE(260) IDENTITY_CASE(262)
    }
#undef IDENTITY_CASE
#define DRIVER_CASE(p) case p: { \
    wtop_amd_driver_info_##p value; memset(&value, 0xff, sizeof(value)); \
    if (a->driver_info && a->driver_info(h, &value) == 0) \
        text_copy(d->driver, sizeof(d->driver), value.driver_version, sizeof(value.driver_version)); \
    break; }
    switch (profile) {
        DRIVER_CASE(234) DRIVER_CASE(245) DRIVER_CASE(246) DRIVER_CASE(251)
        DRIVER_CASE(255) DRIVER_CASE(260) DRIVER_CASE(262)
    }
#undef DRIVER_CASE
    if (!d->driver[0] && a->driver) {
        char value[257]; memset(value, 0xff, sizeof(value));
        int length = sizeof(value);
        if (a->driver(h, &length, value) == 0 && length > 0
            && (size_t)length <= sizeof(value))
            text_copy(d->driver, sizeof(d->driver), value, (size_t)length);
    }
    if (a->uuid) {
        char value[257]; memset(value, 0xff, sizeof(value));
        unsigned int length = sizeof(value);
        if (a->uuid(h, &length, value) == 0 && length > 0 && length <= sizeof(value)) {
            /* SDK releases differ on whether the returned length counts NUL. */
            size_t bound = length < sizeof(value) ? length + 1 : length;
            text_copy(d->uuid, sizeof(d->uuid), value, bound);
        }
    }
    wtop_amd_bdf bdf; memset(&bdf, 0xff, sizeof(bdf));
    if (a->bdf && a->bdf(h, &bdf) == 0 && (bdf.as_uint >> 16) <= 0xffff) {
        snprintf(d->bdf, sizeof(d->bdf), "%04x:%02x:%02x.%x",
            (unsigned int)(bdf.as_uint >> 16), (unsigned int)((bdf.as_uint >> 8) & 0xff),
            (unsigned int)((bdf.as_uint >> 3) & 0x1f), (unsigned int)(bdf.as_uint & 7));
    }
}
static void power_reading(device *d, uint64_t current, uint64_t average) {
    if (watts_valid(current)) {
        reading(d, POWER, (double)current); d->power_measurement = "current";
    } else if (watts_valid(average)) {
        reading(d, POWER, (double)average); d->power_measurement = "average";
    }
}
SDK_ABI static void power(api *a, handle h, int profile, device *d) {
    if (a->power) {
        if (profile == 232) {
            wtop_amd_power_info_232 value; memset(&value, 0xff, sizeof(value));
            if (a->power(h, &value) == 0) power_reading(d, UINT64_MAX, value.average_socket_power);
        } else if (profile <= 251) {
            wtop_amd_power_info_234 value; memset(&value, 0xff, sizeof(value));
            if (a->power(h, &value) == 0)
                power_reading(d, value.current_socket_power, value.average_socket_power);
        } else if (profile == 255) {
            wtop_amd_power_info_255 value; memset(&value, 0xff, sizeof(value));
            /* This release doesn't populate socket_power; use current/average. */
            if (a->power(h, &value) == 0)
                power_reading(d, value.current_socket_power, value.average_socket_power);
        } else {
            wtop_amd_power_info_262 value; memset(&value, 0xff, sizeof(value));
            if (a->power(h, &value) == 0)
                power_reading(d, value.current_socket_power, value.average_socket_power);
        }
    }
    wtop_amd_power_cap cap; memset(&cap, 0xff, sizeof(cap));
    if (a->cap && a->cap(h, 0, &cap) == 0 && cap.power_cap > 0
        && cap.power_cap != UINT16_MAX && cap.power_cap != UINT32_MAX
        && cap.power_cap < UINT64_C(100000000000))
        reading(d, POWER_LIMIT, (double)cap.power_cap / 1000000.0);
}
SDK_ABI static void clocks(api *a, handle h, int profile, device *d) {
    if (!a->clock) return;
    /* GFX=0 and MEM=4 in all supported SDK headers. Every layout is 32 bytes,
     * but declare the correct complete object for the version in use. */
#define CLOCK_CASE(p, current) case p: { \
    wtop_amd_clk_info_##p value; memset(&value, 0xff, sizeof(value)); \
    if (a->clock(h, 0, &value) == 0) { \
        if (clock_valid(value.current)) reading(d, GRAPHICS_CLOCK, value.current * 1000000.0); \
        if (value.max_clk > 0 && clock_valid(value.max_clk)) \
            reading(d, GRAPHICS_MAX, value.max_clk * 1000000.0); \
    } \
    memset(&value, 0xff, sizeof(value)); \
    if (a->clock(h, 4, &value) == 0 && clock_valid(value.current)) \
        reading(d, MEMORY_CLOCK, value.current * 1000000.0); \
    break; }
    switch (profile) {
        CLOCK_CASE(232, cur_clk) CLOCK_CASE(234, cur_clk) CLOCK_CASE(245, cur_clk)
        CLOCK_CASE(246, clk) CLOCK_CASE(251, clk) CLOCK_CASE(255, clk)
        CLOCK_CASE(260, clk) CLOCK_CASE(262, clk)
    }
#undef CLOCK_CASE
}
SDK_ABI static void collect_device(api *a, handle h, int profile, device *d) {
    identity(a, h, profile, d);
    wtop_amd_activity value; memset(&value, 0xff, sizeof(value));
    if (a->activity && a->activity(h, &value) == 0) {
        if (value.gfx_activity <= 100) reading(d, UTILIZATION, value.gfx_activity);
        if (value.umc_activity <= 100) reading(d, MEMORY_UTILIZATION, value.umc_activity);
    }
    uint64_t bytes = UINT64_MAX;
    if (a->memory_total && a->memory_total(h, 0, &bytes) == 0 && bytes < (UINT64_C(1) << 50))
        reading(d, MEMORY_TOTAL, (double)bytes);
    bytes = UINT64_MAX;
    if (a->memory_used && a->memory_used(h, 0, &bytes) == 0 && bytes < (UINT64_C(1) << 50))
        reading(d, MEMORY_USED, (double)bytes);
    if ((d->present & ((1u << MEMORY_TOTAL) | (1u << MEMORY_USED)))
        == ((1u << MEMORY_TOTAL) | (1u << MEMORY_USED))
        && d->metrics[MEMORY_USED] > d->metrics[MEMORY_TOTAL])
        d->present &= ~(1u << MEMORY_USED);
    int64_t temperature = INT64_MAX;
    if (a->temperature && a->temperature(h, 0, 0, &temperature) == 0
        && temperature > -274 && temperature < 1000) reading(d, TEMPERATURE, (double)temperature);
    power(a, h, profile, d);
    clocks(a, h, profile, d);
    int64_t fan = INT64_MAX;
    uint64_t maximum = UINT64_MAX;
    if (a->fan && a->fan_max && a->fan(h, 0, &fan) == 0
        && a->fan_max(h, 0, &maximum) == 0 && fan >= 0 && maximum > 0
        && maximum < 1000000000 && (uint64_t)fan <= maximum)
        reading(d, FAN_PERCENT, (double)fan * 100.0 / (double)maximum);
}

static void string_field(lua_State *L, const char *name, const char *value) {
    if (!value || !*value) return;
    lua_pushstring(L, value); lua_setfield(L, -2, name);
}

/* Collect all vendor outputs before allocating Lua objects. Every successfully
 * initialized session is shut down and the DSO closed even if Lua later OOMs.
 * Opening a fresh session also recovers after driver startup/reset/hotplug. */
SDK_ABI int wtop_amdsmi_query(lua_State *L) {
    snapshot s; memset(&s, 0, sizeof(s));
    api a;
    const char *reason = open_api(&a);
    int initialized = 0;
    if (!reason) {
        if (a.init(GPU_INIT_FLAGS) != 0) reason = "amdsmi_initialization_failed";
        else initialized = 1;
    }
    if (!reason) {
        int profile = version_profile(&a, &s);
        if (!profile) reason = "amdsmi_abi_unsupported";
        else {
            handle handles[MAX_DEVICES]; int count = 0;
            reason = collect_handles(&a, &s, handles, &count);
            if (!reason) {
                s.count = count;
                for (int i = 0; i < count; ++i) collect_device(&a, handles[i], profile, &s.devices[i]);
            }
        }
    }
    if (initialized && a.shutdown() != 0) reason = "amdsmi_shutdown_failed";
    if (a.library) dlclose(a.library);
    if (reason) { lua_pushnil(L); lua_pushstring(L, reason); return 2; }
    lua_createtable(L, 0, 6);
    string_field(L, "api_version", s.version);
    string_field(L, "status", s.partial ? "partial" : "ok");
    if (s.partial) string_field(L, "reason", "amdsmi_enumeration_incomplete");
    lua_pushboolean(L, s.truncated); lua_setfield(L, -2, "truncated");
    lua_createtable(L, s.count, 0);
    for (int i = 0; i < s.count; ++i) {
        device *d = &s.devices[i];
        lua_createtable(L, 0, 20);
        lua_pushinteger(L, i); lua_setfield(L, -2, "index");
        string_field(L, "name", d->name); string_field(L, "uuid", d->uuid);
        string_field(L, "pci_bdf", d->bdf); string_field(L, "driver_version", d->driver);
        string_field(L, "power_measurement", d->power_measurement);
        for (int m = 0; m < METRIC_COUNT; ++m) if (d->present & (1u << m)) {
            lua_pushnumber(L, d->metrics[m]); lua_setfield(L, -2, metric_names[m]);
        }
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "devices");
    return 1;
}
