/* Shared declarations for the Win32 native module's translation units. */
#ifndef WTOP_WINDOWS_H
#define WTOP_WINDOWS_H

#include <lua.h>
#include <wchar.h>

void wtop_push_utf8(lua_State *L, const wchar_t *source);
int wtop_push_if_table2(lua_State *L);
int wtop_collect_connections(lua_State *L);

#endif
