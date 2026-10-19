#ifndef WTOP_LINUX_PERF_H
#define WTOP_LINUX_PERF_H
/* Counting-only perf UAPI. No samples, mmap, process attachment or helper exec.
 * The caller supplies configurations derived from the PMU's sysfs format ABI.
 * All descriptors close before any result allocation; a guard covers Lua OOM. */
#include <lua.h>
#include <lauxlib.h>
#include <linux/perf_event.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <limits.h>

#define WTOP_PERF_LIMIT 1024
#define WTOP_PERF_META "wtop.perf.counting.guard.v1"
#ifndef WTOP_PERF_OPEN
#define WTOP_PERF_OPEN(attr,cpu,flags) ((int)syscall(SYS_perf_event_open,attr,-1,cpu,-1,flags))
#endif
#ifndef WTOP_PERF_IOCTL
#define WTOP_PERF_IOCTL(fd,request) ioctl(fd,request,0)
#endif
#ifndef WTOP_PERF_READ
#define WTOP_PERF_READ(fd,bytes,size) read(fd,bytes,size)
#endif
#ifndef WTOP_PERF_CLOSE
#define WTOP_PERF_CLOSE(fd) close(fd)
#endif
#ifndef WTOP_PERF_SLEEP
#define WTOP_PERF_SLEEP(request,remaining) nanosleep(request,remaining)
#endif
struct wtop_perf_row {
    int fd,error,cpu;
    uint32_t type;
    uint64_t config,config1,config2,value,enabled,running;
};
struct wtop_perf_guard {size_t count;struct wtop_perf_row rows[];};
static int wtop_perf_cleanup(lua_State *L) {
    struct wtop_perf_guard *guard=luaL_checkudata(L,1,WTOP_PERF_META);
    for(size_t i=0;i<guard->count;++i)if(guard->rows[i].fd>=0){
        WTOP_PERF_CLOSE(guard->rows[i].fd);guard->rows[i].fd=-1;
    }
    return 0;
}
static int64_t wtop_perf_now(void) {
    struct timespec value;
    if(clock_gettime(CLOCK_MONOTONIC,&value))return -1;
    return (int64_t)value.tv_sec*INT64_C(1000000000)+value.tv_nsec;
}
static lua_Integer wtop_perf_integer(lua_State *L,int index,const char *key,int optional) {
    lua_getfield(L,index,key);
    lua_Integer value=optional&&lua_isnil(L,-1)?0:luaL_checkinteger(L,-1);
    lua_pop(L,1);return value;
}
static int wtop_linux_read_perf_counts(lua_State *L) {
    luaL_checktype(L,1,LUA_TTABLE);
    size_t count=lua_rawlen(L,1);
    lua_Integer duration=luaL_checkinteger(L,2);
    if(!count||count>WTOP_PERF_LIMIT)return luaL_argerror(L,1,"expected 1..1024 counting events");
    if(duration<50||duration>2000)return luaL_argerror(L,2,"duration must be in 50..2000 ms");
    if(luaL_newmetatable(L,WTOP_PERF_META)){
        lua_pushcfunction(L,wtop_perf_cleanup);lua_setfield(L,-2,"__gc");
    }
    lua_pop(L,1);
    struct wtop_perf_guard *guard=lua_newuserdatauv(L,sizeof(*guard)+count*sizeof(guard->rows[0]),0);
    guard->count=count;memset(guard->rows,0,count*sizeof(guard->rows[0]));
    for(size_t i=0;i<count;++i)guard->rows[i].fd=-1;
    luaL_setmetatable(L,WTOP_PERF_META);
    /* Validate the entire batch before opening its first descriptor. */
    for(size_t i=0;i<count;++i){
        lua_rawgeti(L,1,(lua_Integer)i+1);luaL_checktype(L,-1,LUA_TTABLE);
        int index=lua_gettop(L);struct wtop_perf_row *row=&guard->rows[i];
        lua_Integer type=wtop_perf_integer(L,index,"type",0),cpu=wtop_perf_integer(L,index,"cpu",0);
        if(type<6||type>INT_MAX||cpu<0||cpu>1048575)return luaL_argerror(L,1,"invalid PMU type or control CPU");
        row->type=(uint32_t)type;row->cpu=(int)cpu;
        row->config=(uint64_t)wtop_perf_integer(L,index,"config",0);
        row->config1=(uint64_t)wtop_perf_integer(L,index,"config1",1);
        row->config2=(uint64_t)wtop_perf_integer(L,index,"config2",1);
        lua_pop(L,1);
    }
    int64_t started=wtop_perf_now();int failure=started<0?errno:0;
    size_t active=0;
    for(size_t i=0;i<count&&!failure;++i){
        struct wtop_perf_row *row=&guard->rows[i];struct perf_event_attr attr;
        memset(&attr,0,sizeof(attr));attr.size=PERF_ATTR_SIZE_VER1;
        attr.type=row->type;attr.config=row->config;attr.config1=row->config1;attr.config2=row->config2;
        attr.disabled=1;attr.read_format=PERF_FORMAT_TOTAL_TIME_ENABLED|PERF_FORMAT_TOTAL_TIME_RUNNING;
        row->fd=WTOP_PERF_OPEN(&attr,row->cpu,PERF_FLAG_FD_CLOEXEC);
        if(row->fd<0&&errno==EINVAL){
            /* Kernels before 3.14 do not support FD_CLOEXEC at creation. */
            row->fd=WTOP_PERF_OPEN(&attr,row->cpu,0);
            if(row->fd>=0&&fcntl(row->fd,F_SETFD,FD_CLOEXEC)<0){
                row->error=errno;WTOP_PERF_CLOSE(row->fd);row->fd=-1;
            }
        }
        if(row->fd<0){if(!row->error)row->error=errno;continue;}
        if(WTOP_PERF_IOCTL(row->fd,PERF_EVENT_IOC_ENABLE)<0)row->error=errno;
        if(!row->error)++active;
    }
    struct timespec request={(time_t)(duration/1000),(long)(duration%1000)*1000000L},remaining;
    if(!failure&&active){
        while(WTOP_PERF_SLEEP(&request,&remaining)<0){
            if(errno!=EINTR){failure=errno;break;}request=remaining;
        }
    }
    for(size_t i=0;i<count;++i){
        struct wtop_perf_row *row=&guard->rows[i];
        if(row->fd<0)continue;
        if(!row->error&&WTOP_PERF_IOCTL(row->fd,PERF_EVENT_IOC_DISABLE)<0)row->error=errno;
        if(!row->error){
            uint64_t packet[3];ssize_t length;
            do {length=WTOP_PERF_READ(row->fd,packet,sizeof(packet));}while(length<0&&errno==EINTR);
            if(length!=(ssize_t)sizeof(packet))row->error=length<0?errno:EIO;
            else if(packet[0]>(uint64_t)LUA_MAXINTEGER||packet[1]>(uint64_t)LUA_MAXINTEGER
                ||packet[2]>(uint64_t)LUA_MAXINTEGER||!packet[2]||packet[2]>packet[1])row->error=ERANGE;
            else {row->value=packet[0];row->enabled=packet[1];row->running=packet[2];}
        }
        WTOP_PERF_CLOSE(row->fd);row->fd=-1;
    }
    int64_t finished=wtop_perf_now();if(finished<0&&!failure)failure=errno;
    if(failure){lua_pushnil(L);lua_pushinteger(L,failure);return 2;}
    lua_createtable(L,0,3);
    lua_pushinteger(L,started);lua_setfield(L,-2,"started_ns");
    lua_pushinteger(L,finished);lua_setfield(L,-2,"finished_ns");
    lua_createtable(L,(int)count,0);
    for(size_t i=0;i<count;++i){
        const struct wtop_perf_row *row=&guard->rows[i];lua_createtable(L,0,4);
        if(row->error){lua_pushinteger(L,row->error);lua_setfield(L,-2,"errno");}
        else {
            lua_pushinteger(L,(lua_Integer)row->value);lua_setfield(L,-2,"count");
            lua_pushinteger(L,(lua_Integer)row->enabled);lua_setfield(L,-2,"enabled_ns");
            lua_pushinteger(L,(lua_Integer)row->running);lua_setfield(L,-2,"running_ns");
        }
        lua_rawseti(L,-2,(lua_Integer)i+1);
    }
    lua_setfield(L,-2,"samples");return 1;
}
#endif
