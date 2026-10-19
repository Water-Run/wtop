#define _GNU_SOURCE
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <linux/perf_event.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <time.h>
static int mode,opens,closed,live,enable_calls;
static int fake_open(struct perf_event_attr *attr,int cpu,unsigned long flags) {
    ++opens;assert(attr->size==PERF_ATTR_SIZE_VER1&&attr->type==8&&cpu==0);
    assert(attr->disabled&&!attr->inherit&&!attr->sample_period&&!attr->sample_type);
    assert(attr->read_format==(PERF_FORMAT_TOTAL_TIME_ENABLED|PERF_FORMAT_TOTAL_TIME_RUNNING));
    assert(attr->config==0x304&&attr->config1==7&&attr->config2==UINT64_C(0x8000000000000000));
    if(mode==1){errno=EACCES;return -1;}
    if(mode==2&&flags){errno=EINVAL;return -1;}
    int fd=open("/dev/null",O_RDONLY|O_CLOEXEC);assert(fd>=0);++live;return fd;
}
static int fake_ioctl(int fd,unsigned long operation) {
    assert(fd>=0);
    if(operation==PERF_EVENT_IOC_ENABLE){++enable_calls;if(mode==3){errno=EIO;return -1;}}
    else assert(operation==PERF_EVENT_IOC_DISABLE);
    if(mode==4&&operation==PERF_EVENT_IOC_DISABLE){errno=EIO;return -1;}
    return 0;
}
static ssize_t fake_read(int fd,void *bytes,size_t size) {
    assert(fd>=0&&size==24);uint64_t values[3]={100,1000000000,1000000000};
    if(mode==5)return 8;
    if(mode==6)values[2]=0;
    if(mode==7)values[2]=values[1]+1;
    if(mode==8)values[0]=UINT64_MAX;
    memcpy(bytes,values,sizeof(values));return sizeof(values);
}
static int fake_close(int fd){assert(fd>=0&&live>0);++closed;--live;return close(fd);}
static int fake_sleep(const struct timespec *request,struct timespec *remaining) {
    (void)remaining;assert(request->tv_sec==0&&request->tv_nsec==50000000);
    if(mode==9){errno=EIO;return -1;}return 0;
}
#define WTOP_PERF_OPEN(a,c,f) fake_open(a,c,f)
#define WTOP_PERF_IOCTL(fd,request) fake_ioctl(fd,request)
#define WTOP_PERF_READ(fd,p,n) fake_read(fd,p,n)
#define WTOP_PERF_CLOSE(fd) fake_close(fd)
#define WTOP_PERF_SLEEP(r,t) fake_sleep(r,t)
#include "wtop_linux_perf.h"
static void reset(int scenario){assert(live==0);mode=scenario;opens=closed=enable_calls=0;}
static void run(lua_State *L,const char *program){if(luaL_dostring(L,program)!=LUA_OK){fprintf(stderr,"%s\n",lua_tostring(L,-1));abort();}}
struct allocation {unsigned left;int armed;};
static void *allocate(void *opaque,void *old,size_t old_size,size_t size){
    struct allocation *state=opaque;(void)old_size;
    if(!size){free(old);return NULL;}
    if(state->armed&&size>(old?old_size:0)){
        if(state->left)--state->left;
        if(!state->left)return NULL;
    }
    return realloc(old,size);
}
int main(void){
    lua_State *L=luaL_newstate();assert(L);luaL_openlibs(L);
    lua_pushcfunction(L,wtop_linux_read_perf_counts);lua_setglobal(L,"read_counts");
    run(L,"request={{type=8,cpu=0,config=0x304,config1=7,config2=0x8000000000000000}}\n");
    reset(0);run(L,"local r=assert(read_counts(request,50));assert(#r.samples==1 and r.samples[1].count==100 and r.samples[1].running_ns==1000000000);assert(r.finished_ns>=r.started_ns)");assert(opens==1&&closed==1&&live==0);
    for(int scenario=1;scenario<=8;++scenario){if(scenario==2)continue;reset(scenario);run(L,"local r=assert(read_counts(request,50));assert(r.samples[1].errno and r.samples[1].count==nil)");assert(live==0);}
    /* The legacy flag retry is a success, so test it separately. */
    reset(2);run(L,"assert(read_counts(request,50).samples[1].count==100)");assert(opens==2&&closed==1&&live==0);
    reset(9);run(L,"local r,errno=read_counts(request,50);assert(r==nil and errno==5)");assert(live==0);
    reset(0);run(L,"assert(not pcall(read_counts,request,49));assert(not pcall(read_counts,{},50));assert(not pcall(read_counts,{{type=4,cpu=0,config=0}},50));assert(not pcall(read_counts,{request[1],{type=8,cpu=-1,config=0}},50))");assert(opens==0);
    lua_close(L);
    unsigned failures=0;
    for(unsigned position=1;position<=48;++position){
        reset(0);struct allocation state={0,0};L=lua_newstate(allocate,&state,0);assert(L);luaL_openlibs(L);
        lua_pushcfunction(L,wtop_linux_read_perf_counts);lua_setglobal(L,"read_counts");
        run(L,"request={{type=8,cpu=0,config=0x304,config1=7,config2=0x8000000000000000}}");
        lua_getglobal(L,"read_counts");lua_getglobal(L,"request");lua_pushinteger(L,50);
        state.left=position;state.armed=1;int status=lua_pcall(L,2,1,0);state.armed=0;
        if(status!=LUA_OK){assert(status==LUA_ERRMEM);++failures;}
        lua_gc(L,LUA_GCCOLLECT);lua_gc(L,LUA_GCCOLLECT);assert(live==0);lua_close(L);assert(live==0);
    }
    assert(failures>5);printf("perf counting UAPI: fields, permissions, legacy flag, malformed reads, timeouts, preflight and %u allocation refusals; all descriptors closed\n",failures);
    return 0;
}
