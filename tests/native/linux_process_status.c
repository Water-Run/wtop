#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "../../native/wtop_linux_process_status.h"
struct allocation {size_t calls,fail,blocks;};
static void *allocate(void *opaque,void *old,size_t old_size,size_t size){
 struct allocation *a=opaque;(void)old_size;
 if(!size){if(old){assert(a->blocks);--a->blocks;free(old);}return NULL;}
 if(a->fail&&++a->calls>=a->fail)return NULL;
 int fresh=old==NULL;void *result=realloc(old,size);if(result&&fresh)++a->blocks;return result;
}
int main(int argc,char **argv){
 assert(argc==2);lua_State *L=luaL_newstate();assert(L);luaL_openlibs(L);
 lua_pushcfunction(L,wtop_linux_process_status_input);lua_setglobal(L,"WTOP_STATUS_REDUCE");
 int result=luaL_dofile(L,argv[1]);if(result!=LUA_OK){fprintf(stderr,"%s\n",lua_tostring(L,-1));lua_close(L);return 1;}lua_close(L);
 char *input=malloc(61000);assert(input);memcpy(input,"Uid:",4);memset(input+4,' ',60000);strcpy(input+60004,"1000 1000 1000 1000\nNSpid: 10\n");
 unsigned failures=0,successes=0;
 for(size_t point=1;point<=40;++point){
  struct allocation a={0,0,0};
#if LUA_VERSION_NUM>=505
  L=lua_newstate(allocate,&a,0);
#else
  L=lua_newstate(allocate,&a);
#endif
  assert(L);lua_pushcfunction(L,wtop_linux_process_status_input);lua_pushstring(L,input);a.calls=0;a.fail=point;
  result=lua_pcall(L,1,1,0);a.fail=0;
  if(result==LUA_ERRMEM)++failures;else{assert(result==LUA_OK&&lua_isstring(L,-1));size_t length;const char *out=lua_tolstring(L,-1,&length);assert(length==strlen(input)&&!memcmp(out,input,length));++successes;}
  lua_close(L);assert(!a.blocks);
 }
 free(input);assert(failures&&successes);printf("metadata reduction allocator: %u OOM/%u successes, all owned Lua blocks released\n",failures,successes);return 0;
}
