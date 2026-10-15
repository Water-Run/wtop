/* Lua sink for the shared GPU data operations. Never used in the reader ELF. */
#ifndef WTOP_GPU_LUA_H
#define WTOP_GPU_LUA_H
#include <lua.h>
#include "wtop_gpu_output.h"
static inline void gpu_lua_emit(gpu_output *out,enum gpu_operation op,const char *key,
    int64_t integer,double number,const char *text) {
    lua_State *L=out->context;
    switch(op) {
    case GPU_TABLE:lua_createtable(L,(int)(integer>>32),(int)(integer&0xffffffff));return;
    case GPU_FIELD:lua_setfield(L,-2,key);return;
    case GPU_INDEX:lua_rawseti(L,-2,(lua_Integer)integer);return;
    case GPU_DISCARD:lua_pop(L,1);return;
    case GPU_INTEGER:lua_pushinteger(L,(lua_Integer)integer);break;
    case GPU_NUMBER:lua_pushnumber(L,number);break;
    case GPU_STRING:lua_pushstring(L,text);break;
    case GPU_BOOLEAN:lua_pushboolean(L,integer!=0);break;
    }
    lua_setfield(L,-2,key);
}
#endif
