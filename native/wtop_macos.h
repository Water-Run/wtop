/* Shared declarations for the macOS native module's translation units. */
#ifndef WTOP_MACOS_H
#define WTOP_MACOS_H

#include <lua.h>
#include <stdint.h>

void wtop_register_hardware(lua_State *L);
int wtop_collect_cpu(lua_State *L);
int wtop_collect_cpu_info(lua_State *L);
int wtop_collect_inventory(lua_State *L);
int wtop_collect_disk(lua_State *L);
int wtop_collect_network(lua_State *L);
int wtop_collect_hwmon(lua_State *L);
int wtop_collect_gpu(lua_State *L);
int wtop_collect_cpufreq(lua_State *L);
int wtop_collect_powercap(lua_State *L);
int wtop_collect_displays(lua_State *L);
struct wtop_gpu_frequency {
    double mean, active;
    uint64_t minimum, maximum;
    int warming;
};
int wtop_gpu_frequency(uint64_t owner, struct wtop_gpu_frequency *frequency);
void wtop_smc_begin(void);
int wtop_smc_number(const char *key, double *value);
uint64_t wtop_smc_epoch(void);
uint64_t wtop_mach_to_ns(uint64_t value);

#endif
