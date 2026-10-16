#ifndef WTOP_HARDWARE_WORKER_H
#define WTOP_HARDWARE_WORKER_H
#include <lua.h>
int wtop_hardware_worker_open(lua_State *L);
int wtop_hardware_worker_query(lua_State *L);
int wtop_hardware_worker_close(lua_State *L);
#define WTOP_HARDWARE_COUNT 9
#define WTOP_HARDWARE_NAMES \
    "hwmon","cpufreq","powercap","cpu_limits","thermal_throttle","cpuidle","thermal_zones","smbios_input","gpu_drm"
#endif
