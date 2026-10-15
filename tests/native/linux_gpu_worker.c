#define _GNU_SOURCE
#include <lua.h>
#include <lauxlib.h>
#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
typedef int (*entry)(lua_State *);
static entry open_worker,query_worker,close_worker;
static long budget=-1;
static const char *const sources[]={"nvml","amdsmi","levelzero"};
static void *allocation(void *opaque,void *pointer,size_t previous,size_t size) {
    (void)opaque;if(!size){free(pointer);return NULL;}
    if((!pointer||size>previous)&&budget>=0){if(!budget)return NULL;--budget;}return realloc(pointer,size);
}
static uint64_t now(void) {struct timespec t;assert(!clock_gettime(CLOCK_MONOTONIC,&t));return (uint64_t)t.tv_sec*1000000000u+(uint64_t)t.tv_nsec;}
static void pause_ms(unsigned ms) {struct timespec t={(time_t)(ms/1000),(long)(ms%1000)*1000000};nanosleep(&t,NULL);}
static unsigned fd_count(void) {DIR *d=opendir("/proc/self/fd");assert(d);unsigned n=0;struct dirent *e;while((e=readdir(d)))if(e->d_name[0]!='.')++n;closedir(d);return n;}
static void idle(void) {
    uint64_t deadline=now()+4000000000u;
    for(;;){siginfo_t info;memset(&info,0,sizeof(info));if(waitid(P_ALL,0,&info,WEXITED|WNOHANG|WNOWAIT)<0&&errno==ECHILD)break;assert(now()<deadline);pause_ms(2);}
    pause_ms(2);
}
static lua_State *session(const char *source) {
    lua_State *L=lua_newstate(allocation,NULL,0);assert(L);lua_pushcfunction(L,open_worker);lua_pushstring(L,source);assert(lua_pcall(L,1,1,0)==LUA_OK&&lua_isuserdata(L,1));return L;
}
static int query(lua_State *L) {lua_settop(L,1);lua_pushcfunction(L,query_worker);lua_pushvalue(L,1);lua_pushboolean(L,0);return lua_pcall(L,2,2,0);}
static const char *reason(lua_State *L) {return lua_tostring(L,3);}
static void complete(lua_State *L) {
    uint64_t deadline=now()+4000000000u;
    for(;;){uint64_t start=now();assert(query(L)==LUA_OK);assert(now()-start<150000000u);
        if(lua_istable(L,2))return;
        const char *why=reason(L);if(!why||!strstr(why,"_query_pending"))fprintf(stderr,"unexpected GPU worker: %s\n",why?why:"nil");
        assert(why&&strstr(why,"_query_pending"));assert(now()<deadline);pause_ms(2);}
}
static void close_vm(lua_State *L) {
    lua_settop(L,1);lua_pushcfunction(L,close_worker);lua_pushvalue(L,1);lua_pushinteger(L,0);
    uint64_t start=now();assert(lua_pcall(L,2,1,0)==LUA_OK);assert(now()-start<100000000u);lua_close(L);
}
static lua_Integer pid(lua_State *L) {lua_getfield(L,2,"worker_pid");lua_Integer result=lua_tointeger(L,-1);lua_pop(L,1);assert(result>0);return result;}
static void maps_private(void) {
    FILE *f=fopen("/proc/self/maps","r");assert(f);char line[2048];
    while(fgets(line,sizeof(line),f))assert(!strstr(line,"libnvidia-ml")&&!strstr(line,"libamd_smi")&&!strstr(line,"libze_loader"));
    fclose(f);
}
int main(int argc,char **argv) {
    assert(argc==2);void *module=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!module)fprintf(stderr,"%s\n",dlerror());assert(module);
    open_worker=(entry)dlsym(module,"wtop_gpu_worker_open");query_worker=(entry)dlsym(module,"wtop_gpu_worker_query");close_worker=(entry)dlsym(module,"wtop_gpu_worker_close");assert(open_worker&&query_worker&&close_worker);
    unsigned baseline=fd_count();
    /* Two contexts for each SDK can coexist. One provider cannot spend the
     * controller quota needed by the other adapters in a mixed-vendor host. */
    lua_State *live[6];lua_Integer pids[6];
    for(unsigned i=0;i<6;++i){live[i]=session(sources[i/2]);complete(live[i]);pids[i]=pid(live[i]);for(unsigned j=0;j<i;++j)assert(pids[j]!=pids[i]);}
    maps_private();
    for(unsigned i=0;i<3;++i){lua_State *extra=session(sources[i]);assert(query(extra)==LUA_OK&&lua_isnil(extra,2));assert(strstr(reason(extra),"_worker_busy"));lua_close(extra);}
    close_vm(live[0]);complete(live[1]);complete(live[2]);complete(live[4]);
    for(unsigned i=1;i<6;++i)close_vm(live[i]);
    idle();assert(fd_count()==baseline);
    unsigned failures=0,success=0;
    for(unsigned source=1;source<3;++source){
        lua_State *L=session(sources[source]);complete(L);lua_Integer child=pid(L);
        for(long limit=0;limit<320;++limit){
            lua_settop(L,1);lua_pushcfunction(L,query_worker);lua_pushvalue(L,1);lua_pushboolean(L,0);lua_pushinteger(L,50);
            /* Wait for the response inside the protected call. A zero-wait
             * pending reply would test almost none of the frame decoder. */
            budget=limit;int code=lua_pcall(L,3,2,0);budget=-1;assert(code==LUA_OK||code==LUA_ERRMEM);
            if(code==LUA_OK)assert(lua_istable(L,2));
            if(code==LUA_ERRMEM)++failures;else ++success;
            complete(L);assert(pid(L)==child);
        }
        close_vm(L);idle();
    }
    assert(failures>20&&success);maps_private();assert(fd_count()==baseline);
    /* A loader that exposes an unsupported zesInit must switch modes in a
     * fresh process image. Audit both constructors and their unchanged PID. */
    char audit[]="/tmp/wtop-gpu-init-XXXXXX";int audit_fd=mkstemp(audit);assert(audit_fd>=0);close(audit_fd);
    assert(!setenv("WTOP_LEVELZERO_FIXTURE_MODE","49",1));assert(!setenv("WTOP_LEVELZERO_FIXTURE_AUDIT",audit,1));
    lua_State *legacy=session("levelzero");complete(legacy);lua_Integer legacy_pid=pid(legacy);
    lua_getfield(legacy,2,"initialization");assert(!strcmp(lua_tostring(legacy,-1),"core_legacy"));lua_pop(legacy,1);close_vm(legacy);idle();
    FILE *audit_file=fopen(audit,"r");assert(audit_file);long first_pid=0,second_pid=0;int first_mode=-1,second_mode=-1;
    assert(fscanf(audit_file,"pid=%ld legacy=%d\npid=%ld legacy=%d",&first_pid,&first_mode,&second_pid,&second_mode)==4);
    assert(first_pid==(long)legacy_pid&&second_pid==first_pid&&first_mode==0&&second_mode==1);
    fclose(audit_file);assert(!unlink(audit));assert(!unsetenv("WTOP_LEVELZERO_FIXTURE_MODE"));assert(!unsetenv("WTOP_LEVELZERO_FIXTURE_AUDIT"));
    /* SDK constructors, initialization, enumeration and optional calls fail
     * in separate exec processes. Every foreground call remains bounded. */
    for(unsigned source=1;source<3;++source)for(unsigned mode=40;mode<=48;++mode){
        char value[12];snprintf(value,sizeof(value),"%u",mode);const char *key=source==1?"WTOP_AMDSMI_FIXTURE_MODE":"WTOP_LEVELZERO_FIXTURE_MODE";
        assert(!setenv(key,value,1));lua_State *L=session(sources[source]);uint64_t deadline=now()+4000000000u;int ready=0;
        for(;;){uint64_t start=now();assert(query(L)==LUA_OK);assert(now()-start<150000000u);
            if(lua_istable(L,2)){ready=1;break;}
            const char *why=reason(L);assert(why);
            if(!strstr(why,"_query_pending")){
                assert(((mode==40||mode==41||mode==42||mode==44||(source==1&&mode==45))&&strstr(why,"_query_timeout"))
                    ||(mode==43&&strstr(why,"_worker_exited"))||((mode==47||mode==48)&&strstr(why,"_invalid_response")));break;
            }
            assert(now()<deadline);pause_ms(5);
        }
        assert(ready==(mode==46||(source==2&&mode==45)));close_vm(L);idle();assert(!unsetenv(key));
    }
    /* Two blocked NVIDIA readers still leave AMD and Intel usable. */
    assert(!setenv("WTOP_NVML_FIXTURE_MODE","45",1));lua_State *a=session("nvml"),*b=session("nvml");assert(query(a)==LUA_OK&&query(b)==LUA_OK);
    lua_State *c=session("amdsmi"),*d=session("levelzero");complete(c);complete(d);close_vm(a);close_vm(b);close_vm(c);close_vm(d);idle();assert(!unsetenv("WTOP_NVML_FIXTURE_MODE"));
    assert(fd_count()==baseline);assert(!dlclose(module));
    printf("GPU workers: all3 SDKs isolated; 6 independent contexts/per-source quota; %u OOM/%u success; legacy re-exec; 18 hang/crash/noise/corruption faults; mixed-vendor survival; fd/child cleanup passed\n",failures,success);
    return 0;
}
