/* Shared declarations for the Win32 native module's translation units. */
#ifndef WTOP_WINDOWS_H
#define WTOP_WINDOWS_H

#include <lua.h>
#include <stdint.h>
#include <wchar.h>

void wtop_push_utf8(lua_State *L, const wchar_t *source);
int wtop_push_if_table2(lua_State *L);
void wtop_enrich_network(lua_State *L);
void wtop_push_interface_guid(lua_State *L, const void *guid);
void wtop_fill_interface_guids(lua_State *L);
int wtop_collect_connections(lua_State *L);
int wtop_collect_disk(lua_State *L);
int wtop_collect_disk_health(lua_State *L);
int wtop_collect_cpu_info(lua_State *L);
int wtop_collect_cpuid(lua_State *L);
int wtop_collect_cpu(lua_State *L);
int wtop_pnp_identity(uint32_t devinst, wchar_t *identity, size_t capacity);
/* 1 verified PCI/USB ancestor, 0 outside those buses, -1 incomplete. */
int wtop_pnp_parent(uint32_t devinst, const wchar_t *identity,
    wchar_t *parent, char *bus);
void wtop_register_hardware(lua_State *L);
int wtop_launcher_gone(void);

typedef struct {
    uint64_t working_set;
    uint64_t commit;
    uint64_t private_bytes;
} wtop_memory_counters;

/* Takes a Win32 process HANDLE; declared as void * to keep windows.h out. */
int wtop_process_memory(void *process, wtop_memory_counters *counters);

#endif
