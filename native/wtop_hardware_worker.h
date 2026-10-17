#ifndef WTOP_HARDWARE_WORKER_H
#define WTOP_HARDWARE_WORKER_H
#include <lua.h>
int wtop_hardware_worker_open(lua_State *L);
int wtop_hardware_worker_query(lua_State *L);
int wtop_hardware_worker_close(lua_State *L);
#ifdef __APPLE__
#define WTOP_HARDWARE_COUNT 5
#define WTOP_HARDWARE_NAMES "cpufreq","powercap","gpu","hwmon","network"
#else
#define WTOP_HARDWARE_COUNT 12
#define WTOP_HARDWARE_NAMES \
    "hwmon","cpufreq","powercap","cpu_limits","thermal_throttle","cpuidle","thermal_zones","smbios_input","gpu_drm","cpu_clocks","cpuid","spd"
#endif
#endif
