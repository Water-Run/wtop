/* The default NVML provider executes a fresh native reader process. The
 * controller thread owns spawn, IPC, timeouts and reaping; it never calls Lua
 * or a vendor API. Only short state updates hold the job mutex. */
#define _GNU_SOURCE
#include <lua.h>
#include <lauxlib.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <spawn.h>
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "wtop_nvml_protocol.h"
#include "wtop_nvml_worker_image.h"
#define NVML_SESSION_META "wtop.nvml.worker.session.v1"
#define NVML_FRAME_META "wtop.nvml.worker.frame.v1"
#define NVML_QUERY_NS UINT64_C(2000000000)
#define NVML_FRAME_NS UINT64_C(5000000000)
#define NVML_RETRY_NS UINT64_C(5000000000)
#define NVML_REPLY_WAIT_MS 50
enum client_state { QUERY, READY, ERROR };
struct nvml_frame {
    atomic_uint refs;
    uint64_t started,finished;
    unsigned processes;
    size_t size;
    unsigned char data[];
};
struct nvml_job {
    atomic_uint refs,cancelled;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    enum client_state state;
    int done,processes,error;
    uint64_t requested,failed_at,sequence;
    atomic_int pid;
    struct nvml_frame *frame;
    char reason[96];
    char **environment;
};
struct nvml_session {struct nvml_job *job;int closed;};
struct nvml_frame_guard {struct nvml_frame *frame;struct nvml_job *job;};
static atomic_uint controllers;
static pthread_once_t module_once=PTHREAD_ONCE_INIT;
static int module_pinned;
extern char **environ;
int wtop_nvml_worker_query(lua_State *L);
static uint64_t client_now(void) {
    struct timespec time;if(clock_gettime(CLOCK_MONOTONIC,&time))return 0;
    return (uint64_t)time.tv_sec*UINT64_C(1000000000)+(uint64_t)time.tv_nsec;
}
static void frame_release(struct nvml_frame *frame) {
    if(frame&&atomic_fetch_sub(&frame->refs,1)==1)free(frame);
}
static void environment_free(char **environment) {
    if(environment){for(size_t i=0;environment[i];++i)free(environment[i]);free(environment);}
}
static char **environment_copy(void) {
    size_t count=0,total=0;
    while(environ[count]){size_t length=strnlen(environ[count],1048577);
        if(count==4096||total>=1048576||length>=1048576-total){errno=E2BIG;return NULL;}
        total+=length+1;++count;
    }
    char **copy=calloc(count+1,sizeof(*copy));if(!copy)return NULL;
    for(size_t i=0;i<count;++i){copy[i]=strdup(environ[i]);if(!copy[i]){environment_free(copy);return NULL;}}
    return copy;
}
static void job_release(struct nvml_job *job) {
    if(job&&atomic_fetch_sub(&job->refs,1)==1){frame_release(job->frame);environment_free(job->environment);
        pthread_cond_destroy(&job->condition);pthread_mutex_destroy(&job->mutex);free(job);}
}
static void pin_module(void) {
    Dl_info info;
    if(!dladdr((void *)(uintptr_t)&wtop_nvml_worker_query,&info)||!info.dli_fname)return;
    /* RTLD_NODELETE is process-bounded. It avoids executing a thread's return
     * address after its last Lua VM unloads this module, without trying to
     * dlclose the module from a thread still executing inside it. */
    void *self=dlopen(info.dli_fname,RTLD_NOW|RTLD_NOLOAD|RTLD_NODELETE);
    if(self){module_pinned=1;dlclose(self);}
}
static void job_error(struct nvml_job *job,const char *reason,int error) {
    pthread_mutex_lock(&job->mutex);job->state=ERROR;job->error=error;job->failed_at=client_now();
    snprintf(job->reason,sizeof(job->reason),"%s",reason);pthread_cond_broadcast(&job->condition);pthread_mutex_unlock(&job->mutex);
}
static int fd_image(void) {
    int file=-1;char temporary[]="/tmp/wtop-nvml-XXXXXX";int named=0;
#ifdef SYS_memfd_create
    file=(int)syscall(SYS_memfd_create,"wtop-nvml",3u|0x10u);
    if(file<0&&errno==EINVAL)file=(int)syscall(SYS_memfd_create,"wtop-nvml",3u);
#endif
    if(file<0){file=mkstemp(temporary);if(file<0)return -1;named=1;
        if(fcntl(file,F_SETFD,FD_CLOEXEC)||fchmod(file,0700)){int error=errno;close(file);unlink(temporary);errno=error;return -1;}}
    size_t offset=0;
    while(offset<sizeof(wtop_nvml_worker_image)){
        ssize_t n=write(file,wtop_nvml_worker_image+offset,sizeof(wtop_nvml_worker_image)-offset);
        if(n<0&&errno==EINTR)continue;
        if(n<=0){int error=errno;close(file);if(named)unlink(temporary);errno=error;return -1;}offset+=(size_t)n;
    }
    if(!named){
#ifdef F_ADD_SEALS
        if(fcntl(file,F_ADD_SEALS,F_SEAL_WRITE|F_SEAL_GROW|F_SEAL_SHRINK|F_SEAL_SEAL)){
            int error=errno;close(file);errno=error;return -1;
        }
#endif
    }
    char path[64];snprintf(path,sizeof(path),"/proc/self/fd/%d",file);
    int reader=open(path,O_RDONLY|O_CLOEXEC);int error=errno;
    close(file);if(named)unlink(temporary);
    if(reader<0){errno=error;return -1;}
    int executable=fcntl(reader,F_DUPFD_CLOEXEC,10);error=errno;close(reader);errno=error;return executable;
}
static int spawn_reader(struct nvml_job *job,int *channel) {
    /* Refuse a process sandbox which prevents ownership/reaping altogether. */
    if(waitpid((pid_t)INT_MAX,NULL,WNOHANG)<0&&errno!=ECHILD)return errno;
    int executable=fd_image();if(executable<0)return errno;
    int pair[2];
    if(socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,pair)){int error=errno;close(executable);return error;}
    for(int i=0;i<2;++i){
        int raised=fcntl(pair[i],F_DUPFD_CLOEXEC,10);
        if(raised<0){int saved=errno;close(pair[0]);close(pair[1]);close(executable);return saved;}
        close(pair[i]);pair[i]=raised;
    }
    posix_spawn_file_actions_t actions;posix_spawnattr_t attributes;
    int error=posix_spawn_file_actions_init(&actions);
    if(error){close(executable);close(pair[0]);close(pair[1]);return error;}
    error=posix_spawnattr_init(&attributes);
    if(error){posix_spawn_file_actions_destroy(&actions);close(executable);close(pair[0]);close(pair[1]);return error;}
#define ACTION(expression) do {if(!error)error=(expression);} while(0)
    ACTION(posix_spawn_file_actions_adddup2(&actions,pair[1],3));
    ACTION(posix_spawn_file_actions_adddup2(&actions,executable,4));
    for(int fd=0;fd<3;++fd)ACTION(posix_spawn_file_actions_addopen(&actions,fd,"/dev/null",O_RDWR,0));
    typedef int (*closefrom_function)(posix_spawn_file_actions_t *,int);
    closefrom_function closefrom=(closefrom_function)dlsym(RTLD_DEFAULT,"posix_spawn_file_actions_addclosefrom_np");
    DIR *directory=closefrom?NULL:opendir("/proc/self/fd");
    if(closefrom)ACTION(closefrom(&actions,5));
    else if(!directory)error=errno;
    if(directory) {
        struct dirent *entry;
        while((entry=readdir(directory))){
            unsigned number=0;const unsigned char *p=(const unsigned char *)entry->d_name;int valid=*p!=0;
            for(;*p;++p){if(*p<'0'||*p>'9'||number>INT_MAX/10u){valid=0;break;}number=number*10u+(unsigned)(*p-'0');}
            if(valid&&number>4&&number<=INT_MAX&&(int)number!=executable&&(int)number!=dirfd(directory)
                &&fcntl((int)number,F_GETFD)>=0&&!(fcntl((int)number,F_GETFD)&FD_CLOEXEC))
                ACTION(posix_spawn_file_actions_addclose(&actions,(int)number));
        }
        closedir(directory);
    }
    sigset_t empty,defaults;sigemptyset(&empty);sigemptyset(&defaults);
    sigaddset(&defaults,SIGPIPE);sigaddset(&defaults,SIGTERM);sigaddset(&defaults,SIGINT);sigaddset(&defaults,SIGCHLD);
    ACTION(posix_spawnattr_setsigmask(&attributes,&empty));ACTION(posix_spawnattr_setsigdefault(&attributes,&defaults));
    short flags=POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_SETPGROUP;
#ifdef POSIX_SPAWN_USEVFORK
    flags|=POSIX_SPAWN_USEVFORK;
#endif
    ACTION(posix_spawnattr_setflags(&attributes,flags));ACTION(posix_spawnattr_setpgroup(&attributes,0));
    char path[64],parent[32];snprintf(path,sizeof(path),"/proc/self/fd/4");
    snprintf(parent,sizeof(parent),"%ld",(long)getpid());char *arguments[]={"wtop-nvml-reader",parent,NULL};
    pid_t pid=0;
    if(!error)error=posix_spawn(&pid,path,&actions,&attributes,arguments,job->environment);
    if(!error)atomic_store(&job->pid,pid);
    posix_spawnattr_destroy(&attributes);posix_spawn_file_actions_destroy(&actions);
    close(executable);close(pair[1]);
    if(error){close(pair[0]);return error;}*channel=pair[0];return 0;
#undef ACTION
}
static int transfer(struct nvml_job *job,int fd,unsigned char *data,size_t length,int writing,uint64_t deadline) {
    while(length){
        if(atomic_load(&job->cancelled))return ECANCELED;
        uint64_t now=client_now();if(!now||now>=deadline)return ETIMEDOUT;
        ssize_t n=writing?send(fd,data,length,MSG_DONTWAIT|MSG_NOSIGNAL):recv(fd,data,length,MSG_DONTWAIT);
        if(n>0){data+=(size_t)n;length-=(size_t)n;continue;}
        if(n==0)return EPIPE;
        if(errno==EINTR)continue;
        if(errno!=EAGAIN&&errno!=EWOULDBLOCK)return errno;
        struct pollfd descriptor={fd,writing?POLLOUT:POLLIN,0};
        int timeout=(int)((deadline-now)/UINT64_C(1000000));if(timeout>20)timeout=20;if(timeout<1)timeout=1;
        int result=poll(&descriptor,1,timeout);if(result<0&&errno!=EINTR)return errno;
    }
    return 0;
}
static int child_descriptor(pid_t pid) {
#if defined(SYS_pidfd_open) && defined(SYS_pidfd_send_signal)
    int descriptor=(int)syscall(SYS_pidfd_open,pid,0u);
    if(descriptor>=0){
        /* Another embedding thread may reap children. Check ownership before
         * trusting a descriptor opened after spawn, then signal by descriptor. */
        siginfo_t info;memset(&info,0,sizeof(info));
        if(waitid((idtype_t)3,(id_t)descriptor,&info,WEXITED|WNOHANG|WNOWAIT)==0)return descriptor;
        close(descriptor);
    }
#else
    (void)pid;
#endif
    return -1;
}
static void finish_child(struct nvml_job *job,int channel,int descriptor) {
    pid_t pid=(pid_t)atomic_load(&job->pid);
    if(pid<=0){if(channel>=0)close(channel);if(descriptor>=0)close(descriptor);return;}
    unsigned char quit[NVML_WIRE_COMMAND]={0};nvml_put32(quit,NVML_WIRE_MAGIC);nvml_put32(quit+4,NVML_WIRE_VERSION);
    nvml_put64(quit+8,job->sequence+1);nvml_put32(quit+16,2);
    if(channel>=0){(void)send(channel,quit,sizeof(quit),MSG_DONTWAIT|MSG_NOSIGNAL);close(channel);}
    uint64_t deadline=client_now()+UINT64_C(20000000);int killed=0;
    for(;;){
        pid_t result=waitpid(pid,NULL,WNOHANG);
        if(result==pid||(result<0&&errno==ECHILD)){atomic_store(&job->pid,0);break;}
        if(result<0&&errno!=EINTR){
            /* Keep this bounded controller slot owned if an embedding changes
             * its wait policy while a request is running. Do not lose a PID
             * and start unlimited replacement readers. */
            struct timespec delay={0,250000000};nanosleep(&delay,NULL);
        }
        if(!killed&&client_now()>=deadline){
#ifdef SYS_pidfd_send_signal
            if(descriptor>=0)(void)syscall(SYS_pidfd_send_signal,descriptor,SIGKILL,NULL,0u);
            else
#endif
                (void)kill(pid,SIGKILL);
            killed=1;
        }
        struct timespec delay={0,2000000};nanosleep(&delay,NULL);
    }
    if(descriptor>=0)close(descriptor);
}
static struct nvml_frame *read_response(struct nvml_job *job,int channel,unsigned processes,uint64_t requested,int *error,char reason[96]) {
    uint64_t deadline=requested+NVML_QUERY_NS;
    unsigned char command[NVML_WIRE_COMMAND]={0};nvml_put32(command,NVML_WIRE_MAGIC);nvml_put32(command+4,NVML_WIRE_VERSION);
    nvml_put64(command+8,++job->sequence);nvml_put32(command+16,processes);
    *error=transfer(job,channel,command,sizeof(command),1,deadline);if(*error)return NULL;
    unsigned char header[NVML_WIRE_HEADER];*error=transfer(job,channel,header,sizeof(header),0,deadline);if(*error)return NULL;
    uint32_t length=nvml_u32(header+8),status=nvml_u32(header+12);
    uint64_t started=nvml_u64(header+24),finished=nvml_u64(header+32);
    if(nvml_u32(header)!=NVML_WIRE_MAGIC||nvml_u32(header+4)!=NVML_WIRE_VERSION||!length||length>NVML_WIRE_LIMIT
        ||status>1||nvml_u64(header+16)!=job->sequence||nvml_u32(header+40)!=processes
        ||nvml_u64(header+48)||nvml_u64(header+56)||!started||started<requested||finished<started||finished>client_now()){
        *error=EPROTO;return NULL;
    }
    struct nvml_frame *frame=malloc(sizeof(*frame)+length);if(!frame){*error=ENOMEM;return NULL;}
    atomic_init(&frame->refs,1);frame->size=length;frame->started=started;frame->finished=finished;frame->processes=processes;
    *error=transfer(job,channel,frame->data,length,0,deadline);
    if(!*error&&nvml_checksum(frame->data,length)!=nvml_u32(header+44))*error=EPROTO;
    if(!*error&&status){
        if(length>=sizeof(job->reason)||length<6||memcmp(frame->data,"nvml_",5))*error=EPROTO;
        else {for(uint32_t i=0;i<length;++i)if(!((frame->data[i]>='a'&&frame->data[i]<='z')||frame->data[i]=='_'))*error=EPROTO;}
        if(!*error){memcpy(reason,frame->data,length);reason[length]=0;}
    } else if(!*error&&!nvml_wire_valid(frame->data,length))*error=EPROTO;
    if(*error||status){frame_release(frame);return NULL;}return frame;
}
static void *controller(void *opaque) {
    struct nvml_job *job=opaque;int channel=-1,descriptor=-1,error=spawn_reader(job,&channel);
    if(error){job_error(job,"nvml_worker_unavailable",error);goto done;}
    descriptor=child_descriptor((pid_t)atomic_load(&job->pid));
    for(;;){
        pthread_mutex_lock(&job->mutex);
        while(job->state!=QUERY&&!atomic_load(&job->cancelled))pthread_cond_wait(&job->condition,&job->mutex);
        int cancelled=atomic_load(&job->cancelled)!=0;unsigned processes=(unsigned)job->processes;uint64_t requested=job->requested;
        pthread_mutex_unlock(&job->mutex);if(cancelled)break;
        char reason[96]={0};struct nvml_frame *frame=read_response(job,channel,processes,requested,&error,reason);
        if(!frame){job_error(job,reason[0]?reason:error==ETIMEDOUT?"nvml_query_timeout":error==ENOMEM?"nvml_allocation_failed":error==EPROTO?"nvml_invalid_response":"nvml_worker_exited",error);break;}
        pthread_mutex_lock(&job->mutex);job->frame=frame;job->state=READY;
        pthread_cond_broadcast(&job->condition);pthread_mutex_unlock(&job->mutex);
    }
done:
    finish_child(job,channel,descriptor);
    pthread_mutex_lock(&job->mutex);job->done=1;pthread_cond_broadcast(&job->condition);pthread_mutex_unlock(&job->mutex);
    atomic_fetch_sub(&controllers,1);job_release(job);return NULL;
}
static void wait_deadline(struct timespec *deadline,unsigned milliseconds) {
    clock_gettime(CLOCK_MONOTONIC,deadline);deadline->tv_nsec+=(long)milliseconds*1000000L;
    deadline->tv_sec+=deadline->tv_nsec/1000000000L;deadline->tv_nsec%=1000000000L;
}
static int close_session(lua_State *L) {
    struct nvml_session *session=luaL_checkudata(L,1,NVML_SESSION_META);struct nvml_job *job=session->job;
    session->closed=1;
    if(job){atomic_store(&job->cancelled,1);pthread_mutex_lock(&job->mutex);pthread_cond_broadcast(&job->condition);pthread_mutex_unlock(&job->mutex);
        session->job=NULL;job_release(job);}
    return 0;
}
int wtop_nvml_worker_close(lua_State *L) {
    struct nvml_session *session=luaL_checkudata(L,1,NVML_SESSION_META);struct nvml_job *job=session->job;int done=1;
    session->closed=1;
    if(job){atomic_store(&job->cancelled,1);pthread_mutex_lock(&job->mutex);pthread_cond_broadcast(&job->condition);
        struct timespec limit;wait_deadline(&limit,100);
        while(!job->done){int error=pthread_cond_timedwait(&job->condition,&job->mutex,&limit);if(error)break;}
        done=job->done;pthread_mutex_unlock(&job->mutex);session->job=NULL;job_release(job);}
    lua_pushboolean(L,done);return 1;
}
int wtop_nvml_worker_open(lua_State *L) {
    pthread_once(&module_once,pin_module);
    struct nvml_session *session=lua_newuserdatauv(L,sizeof(*session),0);session->job=NULL;session->closed=0;
    luaL_newmetatable(L,NVML_SESSION_META);lua_pushcfunction(L,close_session);lua_setfield(L,-2,"__gc");
    lua_pushcfunction(L,close_session);lua_setfield(L,-2,"__close");lua_setmetatable(L,-2);return 1;
}
static void guard_release(struct nvml_frame_guard *guard) {
    frame_release(guard->frame);guard->frame=NULL;job_release(guard->job);guard->job=NULL;
}
static int frame_gc(lua_State *L) {
    struct nvml_frame_guard *guard=luaL_checkudata(L,1,NVML_FRAME_META);guard_release(guard);return 0;
}
static void decode_frame(lua_State *L,const struct nvml_frame *frame) {
    const unsigned char *data=frame->data;size_t p=0;luaL_checkstack(L,80,"NVML response");
    while(p<frame->size){
        unsigned op=data[p++];
        if(op==NVML_TABLE){p+=8;lua_createtable(L,0,0);continue;}
        if(op==NVML_INDEX){lua_Integer index=(lua_Integer)nvml_u32(data+p);p+=4;lua_rawseti(L,-2,index);continue;}
        if(op==NVML_DISCARD){lua_pop(L,1);continue;}
        size_t n=data[p++];char key[64];memcpy(key,data+p,n);key[n]=0;p+=n;
        if(op==NVML_FIELD){lua_setfield(L,-2,key);continue;}
        if(op==NVML_INTEGER){lua_pushinteger(L,(lua_Integer)(int64_t)nvml_u64(data+p));p+=8;}
        else if(op==NVML_NUMBER){uint64_t bits=nvml_u64(data+p);double number;memcpy(&number,&bits,8);p+=8;lua_pushnumber(L,number);}
        else if(op==NVML_BOOLEAN)lua_pushboolean(L,data[p++]!=0);
        else {n=(size_t)data[p]|((size_t)data[p+1]<<8);p+=2;lua_pushlstring(L,(const char *)data+p,n);p+=n;}
        lua_setfield(L,-2,key);
    }
}
static struct nvml_job *new_job(int processes) {
    if(atomic_fetch_add(&controllers,1)>=2){atomic_fetch_sub(&controllers,1);errno=EBUSY;return NULL;}
    struct nvml_job *job=calloc(1,sizeof(*job));if(!job){atomic_fetch_sub(&controllers,1);return NULL;}
    atomic_init(&job->refs,2);atomic_init(&job->cancelled,0);atomic_init(&job->pid,0);job->processes=processes;job->requested=client_now();
    int error=pthread_mutex_init(&job->mutex,NULL);if(error){free(job);atomic_fetch_sub(&controllers,1);errno=error;return NULL;}
    pthread_condattr_t attr;error=pthread_condattr_init(&attr);
    if(!error){error=pthread_condattr_setclock(&attr,CLOCK_MONOTONIC);if(!error)error=pthread_cond_init(&job->condition,&attr);pthread_condattr_destroy(&attr);}
    if(error){pthread_mutex_destroy(&job->mutex);free(job);atomic_fetch_sub(&controllers,1);errno=error;return NULL;}
    job->environment=environment_copy();if(!job->environment){atomic_store(&job->refs,1);job_release(job);atomic_fetch_sub(&controllers,1);return NULL;}
    return job;
}
int wtop_nvml_worker_query(lua_State *L) {
    struct nvml_session *session=luaL_checkudata(L,1,NVML_SESSION_META);int processes=lua_toboolean(L,2);
    if(session->closed){lua_pushnil(L);lua_pushliteral(L,"nvml_worker_closed");return 2;}
    struct nvml_frame_guard *guard=lua_newuserdatauv(L,sizeof(*guard),0);guard->frame=NULL;guard->job=NULL;
    luaL_newmetatable(L,NVML_FRAME_META);lua_pushcfunction(L,frame_gc);lua_setfield(L,-2,"__gc");lua_setmetatable(L,-2);
    int guard_index=lua_gettop(L);
    if(session->closed){lua_pushnil(L);lua_pushliteral(L,"nvml_worker_closed");return 2;}
    pthread_once(&module_once,pin_module);
    if(!module_pinned){lua_pushnil(L);lua_pushliteral(L,"nvml_worker_unavailable");return 2;}
    struct nvml_job *job=session->job;
    if(job){pthread_mutex_lock(&job->mutex);int expired=job->state==ERROR&&job->done&&client_now()-job->failed_at>=NVML_RETRY_NS;
        pthread_mutex_unlock(&job->mutex);if(expired){session->job=NULL;job_release(job);job=NULL;}}
    if(!job){
        job=new_job(processes);if(!job){lua_pushnil(L);lua_pushstring(L,errno==EBUSY?"nvml_worker_busy":"nvml_allocation_failed");return 2;}
        session->job=job;pthread_t thread;int error=pthread_create(&thread,NULL,controller,job);
        if(error){session->job=NULL;atomic_store(&job->refs,1);job_release(job);atomic_fetch_sub(&controllers,1);lua_pushnil(L);lua_pushliteral(L,"nvml_worker_unavailable");return 2;}
        pthread_detach(thread);
    }
    atomic_fetch_add(&job->refs,1);guard->job=job;
    /* Reserve a finalizable reference before touching a frame. Lua GC or OOM
     * can re-enter this provider while the outer decoder is allocating. */
    struct timespec limit;wait_deadline(&limit,NVML_REPLY_WAIT_MS);
    pthread_mutex_lock(&job->mutex);
    while(job->state==QUERY&&!job->done){int error=pthread_cond_timedwait(&job->condition,&job->mutex,&limit);if(error)break;}
    struct nvml_frame *frame=job->state==READY?job->frame:NULL;
    if(frame&&(frame->processes!=(unsigned)processes||client_now()-frame->started>NVML_FRAME_NS)){
        job->frame=NULL;job->state=QUERY;job->processes=processes;job->requested=client_now();
        pthread_cond_broadcast(&job->condition);pthread_mutex_unlock(&job->mutex);frame_release(frame);
        lua_pushnil(L);lua_pushliteral(L,"nvml_query_pending");guard_release(guard);return 2;
    }
    if(frame){atomic_fetch_add(&frame->refs,1);guard->frame=frame;}
    int error_state=job->state==ERROR,expired=client_now()-job->requested>=NVML_QUERY_NS;
    char reason[96];snprintf(reason,sizeof(reason),"%s",job->reason);pthread_mutex_unlock(&job->mutex);
    if(!frame){lua_pushnil(L);lua_pushstring(L,error_state?reason:expired?"nvml_query_timeout":"nvml_query_pending");guard_release(guard);return 2;}
    decode_frame(L,frame);
    lua_pushinteger(L,(lua_Integer)frame->started);lua_setfield(L,-2,"sample_started_ns");
    lua_pushinteger(L,(lua_Integer)frame->finished);lua_setfield(L,-2,"sample_finished_ns");
    lua_pushboolean(L,frame->processes!=0);lua_setfield(L,-2,"processes_included");
    lua_pushliteral(L,"process");lua_setfield(L,-2,"transport");
    lua_pushinteger(L,(lua_Integer)atomic_load(&job->pid));lua_setfield(L,-2,"worker_pid");
    struct nvml_frame *old=NULL;pthread_mutex_lock(&job->mutex);
    if(job->frame==frame&&!atomic_load(&job->cancelled)&&!job->done){old=job->frame;job->frame=NULL;job->state=QUERY;job->processes=processes;job->requested=client_now();pthread_cond_broadcast(&job->condition);}
    pthread_mutex_unlock(&job->mutex);frame_release(old);guard_release(guard);lua_remove(L,guard_index);return 1;
}
