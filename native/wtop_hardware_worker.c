/* Each reader owns a complete collector and its counter history. Blocking
 * filesystem/driver callbacks cannot hold the terminal thread or a Lua lock. */
#define _GNU_SOURCE
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <signal.h>
#include <errno.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include <time.h>
#include "wtop_hardware_worker.h"
#include "wtop_gpu_worker.h"
#include "wtop_gpu_protocol.h"
#include "wtop_hardware_lua.h"

int luaopen_wtop_native(lua_State *L);
static const char *const wtop_hardware_names[WTOP_HARDWARE_COUNT]={WTOP_HARDWARE_NAMES};
static uint64_t now_ns(void) {
    struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))return 0;
    return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
}
static int receive_exact(unsigned char *data,size_t size) {
    while(size){ssize_t n=recv(3,data,size,0);if(n<0&&errno==EINTR)continue;
        if(n<=0)return 0;
        data+=(size_t)n;size-=(size_t)n;}
    return 1;
}
static int send_exact(const unsigned char *data,size_t size) {
    while(size){ssize_t n=send(3,data,size,MSG_NOSIGNAL);if(n<0&&errno==EINTR)continue;
        if(n<=0)return 0;
        data+=(size_t)n;size-=(size_t)n;}
    return 1;
}
static int module_loader(lua_State *L) {
    size_t i=(size_t)lua_tointeger(L,lua_upvalueindex(1));
    if(luaL_loadbufferx(L,(const char *)hardware_modules[i].source,hardware_modules[i].size,
        hardware_modules[i].name,"t")!=LUA_OK)return lua_error(L);
    lua_call(L,0,1);return 1;
}
static int initialize(lua_State *L) {
    const char *name=lua_tostring(L,1);size_t size;
    const char *configuration=lua_tolstring(L,2,&size);
    luaL_openlibs(L);
    luaL_requiref(L,"wtop_native",luaopen_wtop_native,0);lua_pop(L,1);
    lua_getglobal(L,"package");
    lua_pushliteral(L,"");lua_setfield(L,-2,"path");
    lua_pushliteral(L,"");lua_setfield(L,-2,"cpath");
    lua_getfield(L,-1,"preload");
    for(size_t i=0;i<sizeof(hardware_modules)/sizeof(hardware_modules[0]);++i){
        lua_pushinteger(L,(lua_Integer)i);lua_pushcclosure(L,module_loader,1);
        lua_setfield(L,-2,hardware_modules[i].name);
    }
    lua_pop(L,2);
    lua_getglobal(L,"require");lua_pushliteral(L,"wtop.core.hardware_worker");lua_call(L,1,1);
    lua_pushstring(L,name);lua_pushlstring(L,configuration,size);lua_call(L,2,1);return 1;
}
static void *limited_alloc(void *opaque,void *old,size_t old_size,size_t size) {
    size_t *used=opaque;
    if(!old)old_size=0;
    if(!size){free(old);*used-=old_size;return NULL;}
    if(size>old_size&&size-old_size>128u*1024u*1024u-*used)return NULL;
    void *value=realloc(old,size);
    if(value)*used=*used-old_size+size;
    return value;
}
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    uint64_t parent=0;
    if(!argv[1][0])return 2;
    for(const char *p=argv[1];*p;++p){if(*p<'0'||*p>'9')return 2;
        parent=parent*10u+(unsigned)(*p-'0');if(parent>INT_MAX)return 2;}
    unsigned source=0;
    while(source<WTOP_HARDWARE_COUNT&&strcmp(argv[2],wtop_hardware_names[source]))++source;
    if(!parent||source==WTOP_HARDWARE_COUNT)return 2;
    struct rlimit core={0,0};(void)setrlimit(RLIMIT_CORE,&core);
    if(prctl(PR_SET_PDEATHSIG,SIGKILL)||getppid()!=(pid_t)parent)return 3;
    (void)close(4);(void)prctl(PR_SET_DUMPABLE,0);
    unsigned char prefix[4];if(!receive_exact(prefix,4))return 4;
    uint32_t size=gpu_u32(prefix);if(!size||size>65536)return 4;
    char *configuration=malloc(size);if(!configuration)return 5;
    if(!receive_exact((unsigned char *)configuration,size)){free(configuration);return 4;}
    size_t used=0;lua_State *L=lua_newstate(limited_alloc,&used,0);
    if(!L){free(configuration);return 5;}
    lua_pushcfunction(L,initialize);lua_pushstring(L,argv[2]);lua_pushlstring(L,configuration,size);
    int initialized=lua_pcall(L,2,1,0)==LUA_OK;free(configuration);
    uint64_t previous=0;unsigned char command[GPU_WIRE_COMMAND];
    while(receive_exact(command,sizeof(command))){
        uint64_t sequence=gpu_u64(command+8);uint32_t flags=gpu_u32(command+16);
        if(gpu_u32(command)!=GPU_WIRE_MAGIC||gpu_u32(command+4)!=GPU_WIRE_VERSION
            ||gpu_u32(command+20)||!sequence||sequence<=previous||flags>2)break;
        previous=sequence;if(flags==2)break;
        uint64_t start=now_ns();int success=0;size_t length=0;
        const char *data="hardware_collector_error";
        if(initialized){
            lua_pushvalue(L,1);lua_pushboolean(L,flags==1);
            if(lua_pcall(L,1,1,0)==LUA_OK&&lua_type(L,-1)==LUA_TSTRING){
                data=lua_tolstring(L,-1,&length);success=length>0&&length<=GPU_WIRE_LIMIT;
            }
        }
        if(!success){data="hardware_collector_error";length=strlen(data);}
        uint64_t finish=now_ns();unsigned char header[GPU_WIRE_HEADER]={0};
        gpu_put32(header,GPU_WIRE_MAGIC);gpu_put32(header+4,GPU_WIRE_VERSION);
        gpu_put32(header+8,(uint32_t)length);gpu_put32(header+12,success?0u:1u);
        gpu_put64(header+16,sequence);gpu_put64(header+24,start);gpu_put64(header+32,finish);
        gpu_put32(header+40,flags);gpu_put32(header+44,gpu_checksum(data,length));gpu_put32(header+48,source+GPU_VENDOR_COUNT);
        if(!send_exact(header,sizeof(header))||!send_exact((const unsigned char *)data,length)||!success)break;
        lua_settop(L,1);
    }
    lua_close(L);return 0;
}
