#define _DEFAULT_SOURCE
#define _BSD_SOURCE
#define _SVID_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
static void *blocks[256];
static size_t sizes[256],live_bytes,allocations,fail_at;
static int native_malloc_failure;
static unsigned native_fail_at,native_allocations;
static void *checked_malloc(size_t size) {
 if(native_malloc_failure || (native_fail_at && ++native_allocations==native_fail_at))return NULL;
 void *p=malloc(size);if(!p)return NULL;
 for(unsigned i=0;i<256;i++)if(!blocks[i]){blocks[i]=p;sizes[i]=size;live_bytes+=size;return p;}
 abort();
}
static void *checked_calloc(size_t n,size_t size) {
 void *p=checked_malloc(n*size);if(p)memset(p,0,n*size);return p;
}
static void checked_free(void *p) {
 if(p)for(unsigned i=0;i<256;i++)if(blocks[i]==p){live_bytes-=sizes[i];blocks[i]=NULL;sizes[i]=0;break;}
 free(p);
}
#define malloc checked_malloc
#define calloc checked_calloc
#define free checked_free
#undef _DEFAULT_SOURCE
#undef _POSIX_C_SOURCE
#include "../../native/wtop_native.c"
#undef malloc
#undef calloc
#undef free
static void *allocate(void *ud,void *p,size_t old,size_t size) {
 (void)ud;
 if(!size){free(p);return NULL;}
 if(size>old && fail_at && ++allocations>=fail_at)return NULL;
 return realloc(p,size);
}
static unsigned descriptors(void) {
 DIR *d=opendir("/proc/self/fd");assert(d);unsigned n=0;
 while(readdir(d))n++;
 assert(closedir(d)==0);return n;
}
static void register_guard(lua_State *L) {
 luaL_newmetatable(L,IO_GUARD_METATABLE);
 lua_pushcfunction(L,l_io_guard_close);lua_setfield(L,-2,"__close");
 lua_pushcfunction(L,l_io_guard_close);lua_setfield(L,-2,"__gc");lua_pop(L,1);
}
static int call(lua_State *L,const char *mode,unsigned budget) {
 lua_settop(L,0);lua_pushcfunction(L,l_proc_batch);lua_createtable(L,8,0);
 for(lua_Integer i=1;i<=8;i++){lua_pushinteger(L,(lua_Integer)getpid());lua_rawseti(L,-2,i);}
 lua_pushstring(L,mode);allocations=0;fail_at=budget;
 int status=lua_pcall(L,2,LUA_MULTRET,0);fail_at=0;return status;
}
static int call_run(lua_State *L,unsigned budget,int bad_argv) {
 lua_settop(L,0);lua_pushcfunction(L,l_run);lua_createtable(L,3,0);
 if(bad_argv){lua_pushinteger(L,42);lua_rawseti(L,-2,1);}
 else{
  const char *args[]={"/bin/sh","-c","printf stdout; printf stderr >&2"};
  for(int i=0;i<3;i++){lua_pushstring(L,args[i]);lua_rawseti(L,-2,i+1);}
 }
 lua_createtable(L,0,2);lua_pushinteger(L,1024);lua_setfield(L,-2,"max_output_bytes");
 lua_pushinteger(L,1000);lua_setfield(L,-2,"timeout_ms");
 lua_createtable(L,0,1);lua_pushliteral(L,"/nonexistent-wtop-io-fixture");lua_setfield(L,-2,"XDG_RUNTIME_DIR");lua_setfield(L,-2,"env");
 allocations=0;fail_at=budget;int rc=lua_pcall(L,2,LUA_MULTRET,0);fail_at=0;return rc;
}
static void release_leaks(void) {
 for(unsigned i=0;i<256;i++)if(blocks[i])checked_free(blocks[i]);
}
int main(void) {
 lua_State *L=lua_newstate(allocate,NULL,0);assert(L);register_guard(L);
 unsigned initial_descriptors=descriptors();
 unsigned failures=0,successes=0,leaked_calls=0;size_t lost=0;
 const char *modes[]={"stat","stat_parsed","stat_rows","io","cmdline","no_such_file"};
 for(unsigned mode=0;mode<sizeof(modes)/sizeof(modes[0]);mode++){
  assert(call(L,modes[mode],0)==LUA_OK);assert(!live_bytes);
  for(unsigned budget=1;budget<=160;budget++){
   lua_settop(L,0);lua_gc(L,LUA_GCCOLLECT);
   int rc=call(L,modes[mode],budget);
   if(rc==LUA_ERRMEM)failures++;else{assert(rc==LUA_OK);successes++;}
   assert(!live_bytes && "C allocation survived protected-call unwinding");
   assert(descriptors()==initial_descriptors);
   lua_settop(L,0);lua_gc(L,LUA_GCCOLLECT);
   if(live_bytes){leaked_calls++;lost+=live_bytes;
    release_leaks();
   }
  }
 }
 native_malloc_failure=1;assert(call(L,"stat",0)==LUA_OK);native_malloc_failure=0;
 assert(lua_isnil(L,1)&&lua_tointeger(L,3)==ENOMEM);lua_settop(L,0);lua_gc(L,LUA_GCCOLLECT);
 unsigned runner_leaks=0;size_t runner_lost=0;
 for(unsigned budget=1;budget<=80;budget++){
  lua_settop(L,0);lua_gc(L,LUA_GCCOLLECT);
  int rc=call_run(L,budget,0);assert(rc==LUA_OK||rc==LUA_ERRMEM);
  assert(!live_bytes && "runner C allocation survived protected-call unwinding");
  assert(descriptors()==initial_descriptors);
  if(rc==LUA_OK){
   lua_getfield(L,1,"exit_code");assert(lua_tointeger(L,-1)==0);lua_pop(L,1);
   lua_getfield(L,1,"stdout");assert(!strcmp(lua_tostring(L,-1),"stdout"));lua_pop(L,1);
   lua_getfield(L,1,"stderr");assert(!strcmp(lua_tostring(L,-1),"stderr"));lua_pop(L,1);
  }
  lua_settop(L,0);lua_gc(L,LUA_GCCOLLECT);
  if(live_bytes){runner_leaks++;runner_lost+=live_bytes;release_leaks();}
 }
 for(unsigned failure=1;failure<=7;failure++){
  native_allocations=0;native_fail_at=failure;int rc=call_run(L,0,0);native_fail_at=0;
  assert(rc==LUA_OK||rc==LUA_ERRRUN);assert(!live_bytes&&descriptors()==initial_descriptors);
  if(failure<=6)assert(rc==LUA_ERRRUN);
  else assert(rc==LUA_OK);
  lua_settop(L,0);lua_gc(L,LUA_GCCOLLECT);
 }
 assert(call_run(L,0,1)==LUA_ERRRUN);assert(!live_bytes&&descriptors()==initial_descriptors);lua_settop(L,0);lua_gc(L,LUA_GCCOLLECT);
 if(live_bytes){runner_leaks++;runner_lost+=live_bytes;release_leaks();}
 lua_close(L);assert(!live_bytes&&failures&&successes&&descriptors()==initial_descriptors);
 printf("proc batch allocator sweep: %u OOM / %u success, %u leaked calls, %zu lost bytes after unwind+fullGC\n",failures,successes,leaked_calls,lost);
 printf("runner argv/capture sweep +7 native allocation cases, descriptors stable, cleanup before GC: %u leaked calls, %zu lost bytes after unwind+fullGC\n",runner_leaks,runner_lost);
 return leaked_calls||runner_leaks?1:0;
}
