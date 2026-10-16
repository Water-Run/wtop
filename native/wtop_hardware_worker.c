/* Each reader owns a complete collector and its counter history. Blocking
 * filesystem/driver callbacks cannot hold the terminal thread or a Lua lock. */
#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <unistd.h>
#include <sys/socket.h>
#ifdef __APPLE__
#include <sys/event.h>
#include <pthread.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <mach-o/dyld.h>
#else
#include <sys/prctl.h>
#endif
#include <sys/resource.h>
#include <signal.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include <time.h>
#include "wtop_hardware_worker.h"
#include "wtop_gpu_worker.h"
#include "wtop_gpu_protocol.h"
#include "wtop_hardware_lua.h"

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#ifdef __APPLE__
static char private_image[PATH_MAX];
static struct stat image_identity;
static void remove_private_image(void) {
    struct stat current;
    if(private_image[0]&&!lstat(private_image,&current)&&S_ISREG(current.st_mode)
        &&current.st_dev==image_identity.st_dev&&current.st_ino==image_identity.st_ino)
        (void)unlink(private_image);
}
static void remember_image(void) {
    char path[PATH_MAX],executable[PATH_MAX];uint32_t capacity=sizeof(executable);struct stat current;
    if(fstat(4,&image_identity)||fcntl(4,F_GETPATH,path)<0
        ||_NSGetExecutablePath(executable,&capacity)||stat(executable,&current))return;
    if(strncmp(path,"/tmp/wtop-hardware-",19)&&strncmp(path,"/private/tmp/wtop-hardware-",27))return;
    if(!S_ISREG(image_identity.st_mode)||image_identity.st_uid!=geteuid()
        ||(image_identity.st_mode&0077)||image_identity.st_dev!=current.st_dev
        ||image_identity.st_ino!=current.st_ino)return;
    snprintf(private_image,sizeof(private_image),"%s",path);
}
/* A blocked API cannot receive the quit command. Watch both the parent and
 * the IPC peer so cancellation still ends this process while its main thread
 * is inside a driver. No thread shares or touches the collector's Lua state. */
static void *watch_parent(void *opaque) {
    int queue=(int)(intptr_t)opaque;
    for(;;){
        struct kevent event;int count=kevent(queue,NULL,0,&event,1,NULL);
        if(count<0&&errno==EINTR)continue;
        if(count<0||(count>0&&(event.filter==EVFILT_PROC||(event.flags&EV_EOF)))){
            remove_private_image();_Exit(3);
        }
    }
}
static int monitor_parent(pid_t parent) {
    int queue=kqueue();if(queue<0)return 0;
    struct kevent changes[2];
    EV_SET(&changes[0],(uintptr_t)parent,EVFILT_PROC,EV_ADD|EV_ONESHOT,NOTE_EXIT,0,NULL);
    EV_SET(&changes[1],3,EVFILT_READ,EV_ADD|EV_CLEAR,0,0,NULL);
    if(fcntl(queue,F_SETFD,FD_CLOEXEC)||kevent(queue,changes,2,NULL,0,NULL)<0||getppid()!=parent){close(queue);return 0;}
    pthread_t thread;int error=pthread_create(&thread,NULL,watch_parent,(void *)(intptr_t)queue);
    if(error){close(queue);return 0;}
    (void)pthread_detach(thread);return 1;
}
#endif

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
#ifdef __APPLE__
    remember_image();
    if(private_image[0]&&atexit(remove_private_image)){remove_private_image();return 3;}
#endif
    (void)close(4);
#ifdef __APPLE__
    if(!monitor_parent((pid_t)parent)){remove_private_image();return 3;}
#else
    if(prctl(PR_SET_PDEATHSIG,SIGKILL)||getppid()!=(pid_t)parent)return 3;
    (void)prctl(PR_SET_DUMPABLE,0);
#endif
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
            ||gpu_u32(command+20)||!sequence||sequence<=previous
            ||(flags!=2&&(flags&~5u)))break;
        previous=sequence;if(flags==2)break;
        uint64_t start=now_ns();int success=0;size_t length=0;
        const char *data="hardware_collector_error";
        if(initialized){
            lua_pushvalue(L,1);lua_pushboolean(L,(flags&1u)!=0);lua_pushboolean(L,(flags&4u)!=0);
            if(lua_pcall(L,2,1,0)==LUA_OK&&lua_type(L,-1)==LUA_TSTRING){
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
