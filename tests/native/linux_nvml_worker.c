#define _GNU_SOURCE
#include <lua.h>
#include <lauxlib.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <sys/wait.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include "../../native/wtop_nvml_protocol.h"
typedef int (*entry)(lua_State *);
static entry open_worker,query_worker,close_worker;
static long budget=-1;
static unsigned oom,success;
static void *allocation(void *opaque,void *pointer,size_t previous,size_t size) {
    (void)opaque;
    if(!size){free(pointer);return NULL;}
    if((!pointer||size>previous)&&budget>=0){if(!budget)return NULL;--budget;}
    return realloc(pointer,size);
}
static uint64_t now(void) {
    struct timespec time;assert(!clock_gettime(CLOCK_MONOTONIC,&time));
    return (uint64_t)time.tv_sec*1000000000u+(uint64_t)time.tv_nsec;
}
static void pause_ms(unsigned ms) {struct timespec delay={0,(long)ms*1000000};nanosleep(&delay,NULL);}
static void idle(void) {
    uint64_t deadline=now()+UINT64_C(4000000000);
    for(;;){
        siginfo_t info;memset(&info,0,sizeof(info));
        if(waitid(P_ALL,0,&info,WEXITED|WNOHANG|WNOWAIT)<0&&errno==ECHILD)break;
        assert(now()<deadline&&"worker was not reaped");pause_ms(2);
    }
    pause_ms(2);
}
static unsigned descriptors(void) {
    DIR *directory=opendir("/proc/self/fd");assert(directory);unsigned count=0;struct dirent *entry;
    while((entry=readdir(directory)))if(entry->d_name[0]!='.')++count;
    closedir(directory);return count;
}
static void legacy_syscalls(void) {
    /* Exercise the old-kernel file/kill/waitpid paths on a modern host. This
     * changes only the test process and its descendants, not the host policy. */
    struct sock_filter code[]={
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS,(unsigned)offsetof(struct seccomp_data,nr)),
#ifdef SYS_memfd_create
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,SYS_memfd_create,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|ENOSYS),
#endif
#ifdef SYS_pidfd_open
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,SYS_pidfd_open,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|ENOSYS),
#endif
#ifdef SYS_pidfd_send_signal
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,SYS_pidfd_send_signal,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|ENOSYS),
#endif
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program={(unsigned short)(sizeof(code)/sizeof(code[0])),code};
    assert(!prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0));
    assert(!prctl(PR_SET_SECCOMP,SECCOMP_MODE_FILTER,&program));
#ifdef SYS_memfd_create
    assert(syscall(SYS_memfd_create,"forbidden",0u)==-1&&errno==ENOSYS);
#endif
}
static lua_State *session(void) {
    lua_State *L=lua_newstate(allocation,NULL,0);assert(L);
    lua_pushcfunction(L,open_worker);assert(lua_pcall(L,0,1,0)==LUA_OK&&lua_isuserdata(L,1));return L;
}
static int query(lua_State *L) {
    lua_settop(L,1);lua_pushcfunction(L,query_worker);lua_pushvalue(L,1);lua_pushboolean(L,1);
    return lua_pcall(L,2,2,0);
}
static void complete(lua_State *L) {
    uint64_t deadline=now()+UINT64_C(4000000000);
    for(;;){assert(query(L)==LUA_OK);
        if(lua_istable(L,2))break;
        assert(!strcmp(lua_tostring(L,3),"nvml_query_pending"));assert(now()<deadline);pause_ms(2);}
}
static void close_vm(lua_State *L) {
    budget=-1;lua_settop(L,1);lua_pushcfunction(L,close_worker);lua_pushvalue(L,1);
    uint64_t start=now();assert(lua_pcall(L,1,1,0)==LUA_OK);assert(now()-start<UINT64_C(250000000));
    lua_close(L);idle();
}
static void stream_validation(void) {
    unsigned char valid[64]={NVML_TABLE};size_t n=9;
    valid[n++]=NVML_INTEGER;valid[n++]=1;valid[n++]='x';nvml_put64(valid+n,42);n+=8;
    assert(nvml_wire_valid(valid,n));
    for(size_t i=0;i<n;++i)if(i!=9)assert(!nvml_wire_valid(valid,i));
    unsigned char changed[64];memcpy(changed,valid,n);changed[0]=255;assert(!nvml_wire_valid(changed,n));
    memcpy(changed,valid,n);changed[11]='!';assert(!nvml_wire_valid(changed,n));
    memcpy(changed,valid,n);changed[9]=NVML_NUMBER;nvml_put64(changed+12,UINT64_C(0x7ff0000000000000));assert(!nvml_wire_valid(changed,n));
    unsigned seed=1;
    for(unsigned i=0;i<20000;++i){for(size_t j=0;j<sizeof(changed);++j){seed=seed*1664525u+1013904223u;changed[j]=(unsigned char)(seed>>24);} (void)nvml_wire_valid(changed,i%sizeof(changed));}
}
int main(int argc,char **argv) {
    assert(argc==2||(argc==3&&!strcmp(argv[2],"--legacy-syscalls")));
    if(argc==3)legacy_syscalls();
    stream_validation();
    void *module=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!module)fprintf(stderr,"%s\n",dlerror());assert(module);
    open_worker=(entry)dlsym(module,"wtop_nvml_worker_open");query_worker=(entry)dlsym(module,"wtop_nvml_worker_query");close_worker=(entry)dlsym(module,"wtop_nvml_worker_close");assert(open_worker&&query_worker&&close_worker);
    assert(!setenv("WTOP_NVML_FIXTURE_MODE","0",1));
    lua_State *L=session();complete(L);lua_getfield(L,2,"worker_pid");lua_Integer pid=lua_tointeger(L,-1);assert(pid>0);
    for(long limit=0;limit<180;++limit){
        lua_settop(L,1);lua_pushcfunction(L,query_worker);lua_pushvalue(L,1);lua_pushboolean(L,1);
        budget=limit;int code=lua_pcall(L,2,2,0);budget=-1;
        assert(code==LUA_OK||code==LUA_ERRMEM);if(code==LUA_ERRMEM)oom++;else success++;
        complete(L);lua_getfield(L,2,"worker_pid");assert(lua_tointeger(L,-1)==pid);
    }
    close_vm(L);unsigned baseline_fds=descriptors();
    for(long limit=0;limit<180;++limit){
        L=session();lua_pushcfunction(L,query_worker);lua_pushvalue(L,1);lua_pushboolean(L,1);
        budget=limit;int code=lua_pcall(L,2,2,0);budget=-1;
        assert(code==LUA_OK||code==LUA_ERRMEM);if(code==LUA_ERRMEM)oom++;else success++;
        complete(L);close_vm(L);
    }
    assert(oom&&success);
    /* A VM may close while the SDK's constructor has not returned. */
    assert(!setenv("WTOP_NVML_FIXTURE_MODE","45",1));
    L=session();assert(query(L)==LUA_OK);uint64_t start=now();lua_close(L);
    assert(now()-start<UINT64_C(100000000));idle();
    /* Independent contexts own their child. Closing one does not stop another. */
    assert(!setenv("WTOP_NVML_FIXTURE_MODE","0",1));
    lua_State *a=session(),*b=session(),*c=session();complete(a);complete(b);
    assert(query(c)==LUA_OK&&lua_isnil(c,2)&&!strcmp(lua_tostring(c,3),"nvml_worker_busy"));
    lua_close(c);
    lua_settop(a,1);lua_pushcfunction(a,close_worker);lua_pushvalue(a,1);assert(lua_pcall(a,1,1,0)==LUA_OK);lua_close(a);
    complete(b);close_vm(b);
    /* Constructor allocations are protected too, including partial metatables. */
    for(long limit=0;limit<35;++limit){
        L=lua_newstate(allocation,NULL,0);assert(L);lua_pushcfunction(L,open_worker);
        budget=limit;int code=lua_pcall(L,0,1,0);budget=-1;assert(code==LUA_OK||code==LUA_ERRMEM);lua_close(L);
    }
    idle();
    const int modes[]={45,46,47,48,49,50,51,52,56,57};
    for(size_t i=0;i<sizeof(modes)/sizeof(modes[0]);++i){
        char value[16];snprintf(value,sizeof(value),"%d",modes[i]);assert(!setenv("WTOP_NVML_FIXTURE_MODE",value,1));
        L=session();uint64_t deadline=now()+UINT64_C(4000000000);int ready=0;
        for(;;){uint64_t before=now();assert(query(L)==LUA_OK);assert(now()-before<UINT64_C(200000000));
            if(lua_istable(L,2)){ready=1;break;}
            const char *reason=lua_tostring(L,3);assert(reason);
            if(strcmp(reason,"nvml_query_pending")){
                assert((modes[i]>=45&&modes[i]<=48&&!strcmp(reason,"nvml_query_timeout"))
                    ||(modes[i]==51&&!strcmp(reason,"nvml_worker_exited"))
                    ||((modes[i]==56||modes[i]==57)&&!strcmp(reason,"nvml_invalid_response")));break;
            }
            assert(now()<deadline);pause_ms(5);
        }
        assert(ready==(modes[i]==49||modes[i]==50||modes[i]==52));close_vm(L);
    }
    FILE *private=tmpfile();assert(private);assert(dup2(fileno(private),20)==20);
    struct stat st;assert(!fstat(20,&st));char inode[64];snprintf(inode,sizeof(inode),"%llu",(unsigned long long)st.st_ino);
    assert(!setenv("WTOP_NVML_TEST_FD_INO",inode,1));assert(!setenv("WTOP_NVML_FIXTURE_MODE","58",1));
    L=session();complete(L);close_vm(L);close(20);fclose(private);
    assert(descriptors()==baseline_fds&&"parent file descriptors leaked");
    assert(!dlclose(module));
    printf("NVML worker: bounded wire fuzz, %u OOM failures/%u successes, 180 cached + 180 fresh budgets, VM-close cancellation, independent contexts, two-reader cap and reaping passed\n",oom,success);
    return 0;
}
