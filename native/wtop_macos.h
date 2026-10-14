/* Shared declarations for the macOS native module's translation units. */
#ifndef WTOP_MACOS_H
#define WTOP_MACOS_H

#include <lua.h>
#include <stdint.h>

void wtop_register_hardware(lua_State *L);
int wtop_collect_inventory(lua_State *L);
int wtop_collect_disk(lua_State *L);
int wtop_collect_network(lua_State *L);
uint64_t wtop_mach_to_ns(uint64_t value);

#endif
