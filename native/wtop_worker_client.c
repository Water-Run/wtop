/* GPU SDKs and hardware collectors execute isolated native reader processes. The
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
#include "wtop_gpu_protocol.h"
#include "wtop_gpu_worker.h"
#include "wtop_gpu_worker_image.h"
#include "wtop_hardware_worker.h"
#include "wtop_hardware_worker_image.h"
#define WORKER_COUNT (GPU_VENDOR_COUNT + WTOP_HARDWARE_COUNT)
#define GPU_SESSION_META "wtop.worker.session.v2"
#define GPU_FRAME_META "wtop.worker.frame.v2"
#define GPU_QUERY_NS UINT64_C(2000000000)
#define GPU_FRAME_NS UINT64_C(5000000000)
#define GPU_RETRY_NS UINT64_C(5000000000)
#define GPU_REPLY_WAIT_MS 50
enum client_state { QUERY, READY, ERROR, IDLE };
struct gpu_frame {
    atomic_uint refs;
    uint64_t started,finished;
    unsigned processes;
    size_t size;
    unsigned char data[];
};
struct gpu_job {
    atomic_uint refs,cancelled;
    unsigned vendor;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    enum client_state state;
    int done,processes,error;
    uint64_t requested,failed_at,sequence;
    atomic_int pid;
    struct gpu_frame *frame;
    char reason[96];
    char **environment;
    unsigned char *configuration;size_t configuration_size;
};
struct gpu_session {struct gpu_job *job;int closed;unsigned vendor;};
struct gpu_frame_guard {struct gpu_frame *frame;struct gpu_job *job;};
static atomic_uint controllers[WORKER_COUNT];
static const char *const vendor_names[WORKER_COUNT]={"nvml","amdsmi","levelzero",WTOP_HARDWARE_NAMES};
enum gpu_error {UNAVAILABLE,BUSY,CLOSED,ALLOCATION,PENDING,TIMEOUT,INVALID,EXITED};
static const char *const vendor_errors[WORKER_COUNT][8]={
    {"nvml_worker_unavailable", "nvml_worker_busy", "nvml_worker_closed", "nvml_allocation_failed", "nvml_query_pending", "nvml_query_timeout", "nvml_invalid_response", "nvml_worker_exited"},
    {"amdsmi_worker_unavailable", "amdsmi_worker_busy", "amdsmi_worker_closed", "amdsmi_allocation_failed", "amdsmi_query_pending", "amdsmi_query_timeout", "amdsmi_invalid_response", "amdsmi_worker_exited"},
    {"levelzero_worker_unavailable", "levelzero_worker_busy", "levelzero_worker_closed", "levelzero_allocation_failed", "levelzero_query_pending", "levelzero_query_timeout", "levelzero_invalid_response", "levelzero_worker_exited"},
};
static const char *const hardware_errors[8]={"hardware_worker_unavailable", "hardware_worker_busy", "hardware_worker_closed", "hardware_allocation_failed", "hardware_query_pending", "hardware_query_timeout", "hardware_invalid_response", "hardware_worker_exited"};
static const char *worker_error(unsigned source,unsigned error) {
    return source<GPU_VENDOR_COUNT?vendor_errors[source][error]:hardware_errors[error];
}
static pthread_once_t module_once=PTHREAD_ONCE_INIT;
static void *module_pin;
extern char **environ;
int wtop_gpu_worker_query(lua_State *L);
static uint64_t client_now(void) {
    struct timespec time;if(clock_gettime(CLOCK_MONOTONIC,&time))return 0;
    return (uint64_t)time.tv_sec*UINT64_C(1000000000)+(uint64_t)time.tv_nsec;
}
static void frame_release(struct gpu_frame *frame) {
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
static void job_release(struct gpu_job *job) {
    if(job&&atomic_fetch_sub(&job->refs,1)==1){frame_release(job->frame);environment_free(job->environment);free(job->configuration);
        pthread_cond_destroy(&job->condition);pthread_mutex_destroy(&job->mutex);free(job);}
}
static void pin_module(void) {
    Dl_info info;
    if(!dladdr((void *)(uintptr_t)&wtop_gpu_worker_query,&info)||!info.dli_fname)return;
    /* Keep one loader reference for the process lifetime. Older glibc does
     * not promote an already loaded DSO to NODELETE with RTLD_NOLOAD; closing
     * that handle lets Lua unmap controller code while a thread is reaping.
     * Never dlclose from a thread whose return address is inside the module. */
    module_pin=dlopen(info.dli_fname,RTLD_NOW|RTLD_NOLOAD);
}
static void job_error(struct gpu_job *job,const char *reason,int error) {
    pthread_mutex_lock(&job->mutex);job->state=ERROR;job->error=error;job->failed_at=client_now();
    snprintf(job->reason,sizeof(job->reason),"%s",reason);pthread_cond_broadcast(&job->condition);pthread_mutex_unlock(&job->mutex);
}
static int fd_image(unsigned source) {
    int file=-1;char temporary[]="/tmp/wtop-gpu-XXXXXX";int named=0;
#ifdef SYS_memfd_create
    file=(int)syscall(SYS_memfd_create,"wtop-gpu",3u|0x10u);
    if(file<0&&errno==EINVAL)file=(int)syscall(SYS_memfd_create,"wtop-gpu",3u);
#endif
    if(file<0){file=mkstemp(temporary);if(file<0)return -1;named=1;
        if(fcntl(file,F_SETFD,FD_CLOEXEC)||fchmod(file,0700)){int error=errno;close(file);unlink(temporary);errno=error;return -1;}}
    const unsigned char *image=source<GPU_VENDOR_COUNT?wtop_gpu_worker_image:wtop_hardware_worker_image;
    size_t image_size=source<GPU_VENDOR_COUNT?sizeof(wtop_gpu_worker_image):sizeof(wtop_hardware_worker_image);
    size_t offset=0;
    while(offset<image_size){
        ssize_t n=write(file,image+offset,image_size-offset);
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
static int spawn_reader(struct gpu_job *job,int *channel) {
    /* Refuse a process sandbox which prevents ownership/reaping altogether. */
    if(waitpid((pid_t)INT_MAX,NULL,WNOHANG)<0&&errno!=ECHILD)return errno;
    int executable=fd_image(job->vendor);if(executable<0)return errno;
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
    snprintf(parent,sizeof(parent),"%ld",(long)getpid());char *arguments[]={job->vendor<GPU_VENDOR_COUNT?"wtop-gpu-reader":"wtop-hardware-reader",parent,(char *)vendor_names[job->vendor],NULL};
    pid_t pid=0;
    if(!error)error=posix_spawn(&pid,path,&actions,&attributes,arguments,job->environment);
    if(!error)atomic_store(&job->pid,pid);
    posix_spawnattr_destroy(&attributes);posix_spawn_file_actions_destroy(&actions);
    close(executable);close(pair[1]);
    if(error){close(pair[0]);return error;}*channel=pair[0];return 0;
#undef ACTION
}
static int transfer(struct gpu_job *job,int fd,unsigned char *data,size_t length,int writing,uint64_t deadline) {
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
static void finish_child(struct gpu_job *job,int channel,int descriptor) {
    pid_t pid=(pid_t)atomic_load(&job->pid);
    if(pid<=0){if(channel>=0)close(channel);if(descriptor>=0)close(descriptor);return;}
    unsigned char quit[GPU_WIRE_COMMAND]={0};gpu_put32(quit,GPU_WIRE_MAGIC);gpu_put32(quit+4,GPU_WIRE_VERSION);
    gpu_put64(quit+8,job->sequence+1);gpu_put32(quit+16,2);
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
static struct gpu_frame *read_response(struct gpu_job *job,int channel,unsigned processes,uint64_t requested,int *error,char reason[96]) {
    uint64_t deadline=requested+GPU_QUERY_NS;
    unsigned char command[GPU_WIRE_COMMAND]={0};gpu_put32(command,GPU_WIRE_MAGIC);gpu_put32(command+4,GPU_WIRE_VERSION);
    gpu_put64(command+8,++job->sequence);gpu_put32(command+16,processes);
    *error=transfer(job,channel,command,sizeof(command),1,deadline);if(*error)return NULL;
    unsigned char header[GPU_WIRE_HEADER];*error=transfer(job,channel,header,sizeof(header),0,deadline);if(*error)return NULL;
    uint32_t length=gpu_u32(header+8),status=gpu_u32(header+12);
    uint64_t started=gpu_u64(header+24),finished=gpu_u64(header+32);
    if(gpu_u32(header)!=GPU_WIRE_MAGIC||gpu_u32(header+4)!=GPU_WIRE_VERSION||!length||length>GPU_WIRE_LIMIT
        ||status>1||gpu_u64(header+16)!=job->sequence||gpu_u32(header+40)!=processes
        ||gpu_u32(header+48)!=(unsigned)job->vendor||gpu_u32(header+52)||gpu_u64(header+56)||!started||started<requested||finished<started||finished>client_now()){
        *error=EPROTO;return NULL;
    }
    struct gpu_frame *frame=malloc(sizeof(*frame)+length);if(!frame){*error=ENOMEM;return NULL;}
    atomic_init(&frame->refs,1);frame->size=length;frame->started=started;frame->finished=finished;frame->processes=processes;
    *error=transfer(job,channel,frame->data,length,0,deadline);
    if(!*error&&gpu_checksum(frame->data,length)!=gpu_u32(header+44))*error=EPROTO;
    if(!*error&&status){
        const char *name=job->vendor<GPU_VENDOR_COUNT?vendor_names[job->vendor]:"hardware";
        size_t prefix=strlen(name);
        if(length>=sizeof(job->reason)||length<=prefix+1||memcmp(frame->data,name,prefix)||frame->data[prefix]!='_')*error=EPROTO;
        else {for(uint32_t i=0;i<length;++i)if(!((frame->data[i]>='a'&&frame->data[i]<='z')||frame->data[i]=='_'))*error=EPROTO;}
        if(!*error){memcpy(reason,frame->data,length);reason[length]=0;}
    } else if(!*error&&job->vendor<GPU_VENDOR_COUNT&&!gpu_wire_valid(frame->data,length))*error=EPROTO;
    if(*error||status){frame_release(frame);return NULL;}return frame;
}
static void *controller(void *opaque) {
    struct gpu_job *job=opaque;int channel=-1,descriptor=-1,error=spawn_reader(job,&channel);
    if(error){job_error(job,worker_error(job->vendor,UNAVAILABLE),error);goto done;}
    descriptor=child_descriptor((pid_t)atomic_load(&job->pid));
    if(job->vendor>=GPU_VENDOR_COUNT){
        uint64_t deadline=job->requested+GPU_QUERY_NS;
        unsigned char size[4];gpu_put32(size,(uint32_t)job->configuration_size);
        error=transfer(job,channel,size,4,1,deadline);
        if(!error)error=transfer(job,channel,job->configuration,job->configuration_size,1,deadline);
        if(error){job_error(job,worker_error(job->vendor,error==ETIMEDOUT?TIMEOUT:EXITED),error);goto done;}
    }
    for(;;){
        pthread_mutex_lock(&job->mutex);
        while(job->state!=QUERY&&!atomic_load(&job->cancelled))pthread_cond_wait(&job->condition,&job->mutex);
        int cancelled=atomic_load(&job->cancelled)!=0;unsigned processes=(unsigned)job->processes;uint64_t requested=job->requested;
        pthread_mutex_unlock(&job->mutex);if(cancelled)break;
        char reason[96]={0};struct gpu_frame *frame=read_response(job,channel,processes,requested,&error,reason);
        if(!frame){job_error(job,reason[0]?reason:worker_error(job->vendor,error==ETIMEDOUT?TIMEOUT:error==ENOMEM?ALLOCATION:error==EPROTO?INVALID:EXITED),error);break;}
        pthread_mutex_lock(&job->mutex);job->frame=frame;job->state=READY;
        pthread_cond_broadcast(&job->condition);pthread_mutex_unlock(&job->mutex);
    }
done:
    finish_child(job,channel,descriptor);
    pthread_mutex_lock(&job->mutex);job->done=1;pthread_cond_broadcast(&job->condition);pthread_mutex_unlock(&job->mutex);
    atomic_fetch_sub(&controllers[job->vendor],1);job_release(job);return NULL;
}
static void wait_deadline(struct timespec *deadline,unsigned milliseconds) {
    clock_gettime(CLOCK_MONOTONIC,deadline);deadline->tv_nsec+=(long)milliseconds*1000000L;
    deadline->tv_sec+=deadline->tv_nsec/1000000000L;deadline->tv_nsec%=1000000000L;
}
static int close_session(lua_State *L) {
    struct gpu_session *session=luaL_checkudata(L,1,GPU_SESSION_META);struct gpu_job *job=session->job;
    session->closed=1;
    if(job){atomic_store(&job->cancelled,1);pthread_mutex_lock(&job->mutex);pthread_cond_broadcast(&job->condition);pthread_mutex_unlock(&job->mutex);
        session->job=NULL;job_release(job);}
    return 0;
}
int wtop_gpu_worker_close(lua_State *L) {
    lua_Integer wait_ms=luaL_optinteger(L,2,100);
    luaL_argcheck(L,wait_ms>=0&&wait_ms<=100,2,"wait must be 0..100 ms");
    struct gpu_session *session=luaL_checkudata(L,1,GPU_SESSION_META);struct gpu_job *job=session->job;int done=1;
    session->closed=1;
    if(job){atomic_store(&job->cancelled,1);pthread_mutex_lock(&job->mutex);pthread_cond_broadcast(&job->condition);
        struct timespec limit;wait_deadline(&limit,(unsigned)wait_ms);
        while(wait_ms&&!job->done){int error=pthread_cond_timedwait(&job->condition,&job->mutex,&limit);if(error)break;}
        done=job->done;pthread_mutex_unlock(&job->mutex);session->job=NULL;job_release(job);}
    lua_pushboolean(L,done);return 1;
}
static int open_session(lua_State *L,unsigned vendor) {
    pthread_once(&module_once,pin_module);
    struct gpu_session *session=lua_newuserdatauv(L,sizeof(*session),1);session->job=NULL;session->closed=0;session->vendor=vendor;
    luaL_newmetatable(L,GPU_SESSION_META);lua_pushcfunction(L,close_session);lua_setfield(L,-2,"__gc");
    lua_pushcfunction(L,close_session);lua_setfield(L,-2,"__close");lua_setmetatable(L,-2);
    if(vendor>=GPU_VENDOR_COUNT){lua_pushvalue(L,2);lua_setiuservalue(L,-2,1);}
    return 1;
}
static void guard_release(struct gpu_frame_guard *guard) {
    frame_release(guard->frame);guard->frame=NULL;job_release(guard->job);guard->job=NULL;
}
static int frame_gc(lua_State *L) {
    struct gpu_frame_guard *guard=luaL_checkudata(L,1,GPU_FRAME_META);guard_release(guard);return 0;
}
static void decode_frame(lua_State *L,const struct gpu_frame *frame) {
    const unsigned char *data=frame->data;size_t p=0;luaL_checkstack(L,80,"GPU response");
    while(p<frame->size){
        unsigned op=data[p++];
        if(op==GPU_TABLE){p+=8;lua_createtable(L,0,0);continue;}
        if(op==GPU_INDEX){lua_Integer index=(lua_Integer)gpu_u32(data+p);p+=4;lua_rawseti(L,-2,index);continue;}
        if(op==GPU_DISCARD){lua_pop(L,1);continue;}
        size_t n=data[p++];char key[64];memcpy(key,data+p,n);key[n]=0;p+=n;
        if(op==GPU_FIELD){lua_setfield(L,-2,key);continue;}
        if(op==GPU_INTEGER){lua_pushinteger(L,(lua_Integer)(int64_t)gpu_u64(data+p));p+=8;}
        else if(op==GPU_NUMBER){uint64_t bits=gpu_u64(data+p);double number;memcpy(&number,&bits,8);p+=8;lua_pushnumber(L,number);}
        else if(op==GPU_BOOLEAN)lua_pushboolean(L,data[p++]!=0);
        else {n=(size_t)data[p]|((size_t)data[p+1]<<8);p+=2;lua_pushlstring(L,(const char *)data+p,n);p+=n;}
        lua_setfield(L,-2,key);
    }
}
static struct gpu_job *new_job(int processes,unsigned vendor,const char *configuration,size_t configuration_size) {
    if(atomic_fetch_add(&controllers[vendor],1)>=2){atomic_fetch_sub(&controllers[vendor],1);errno=EBUSY;return NULL;}
    struct gpu_job *job=calloc(1,sizeof(*job));if(!job){atomic_fetch_sub(&controllers[vendor],1);return NULL;}
    atomic_init(&job->refs,2);atomic_init(&job->cancelled,0);atomic_init(&job->pid,0);job->vendor=vendor;job->processes=processes;job->requested=client_now();
    int error=pthread_mutex_init(&job->mutex,NULL);if(error){free(job);atomic_fetch_sub(&controllers[vendor],1);errno=error;return NULL;}
    pthread_condattr_t attr;error=pthread_condattr_init(&attr);
    if(!error){error=pthread_condattr_setclock(&attr,CLOCK_MONOTONIC);if(!error)error=pthread_cond_init(&job->condition,&attr);pthread_condattr_destroy(&attr);}
    if(error){pthread_mutex_destroy(&job->mutex);free(job);atomic_fetch_sub(&controllers[vendor],1);errno=error;return NULL;}
    if(configuration_size){
        job->configuration=malloc(configuration_size);
        if(!job->configuration){atomic_store(&job->refs,1);job_release(job);atomic_fetch_sub(&controllers[vendor],1);return NULL;}
        memcpy(job->configuration,configuration,configuration_size);job->configuration_size=configuration_size;
    }
    job->environment=environment_copy();if(!job->environment){atomic_store(&job->refs,1);job_release(job);atomic_fetch_sub(&controllers[vendor],1);return NULL;}
    return job;
}
static int query_session(lua_State *L,unsigned wait_ms) {
    struct gpu_session *session=luaL_checkudata(L,1,GPU_SESSION_META);int processes=lua_toboolean(L,2);
    if(session->closed){lua_pushnil(L);lua_pushstring(L,worker_error(session->vendor,CLOSED));return 2;}
    struct gpu_frame_guard *guard=lua_newuserdatauv(L,sizeof(*guard),0);guard->frame=NULL;guard->job=NULL;
    luaL_newmetatable(L,GPU_FRAME_META);lua_pushcfunction(L,frame_gc);lua_setfield(L,-2,"__gc");lua_setmetatable(L,-2);
    int guard_index=lua_gettop(L);
    if(session->closed){lua_pushnil(L);lua_pushstring(L,worker_error(session->vendor,CLOSED));return 2;}
    pthread_once(&module_once,pin_module);
    if(!module_pin){lua_pushnil(L);lua_pushstring(L,worker_error(session->vendor,UNAVAILABLE));return 2;}
    struct gpu_job *job=session->job;
    if(job){pthread_mutex_lock(&job->mutex);int expired=job->state==ERROR&&job->done&&client_now()-job->failed_at>=GPU_RETRY_NS;
        pthread_mutex_unlock(&job->mutex);if(expired){session->job=NULL;job_release(job);job=NULL;}}
    if(!job){
        size_t configuration_size=0;const char *configuration=NULL;
        if(session->vendor>=GPU_VENDOR_COUNT){lua_getiuservalue(L,1,1);configuration=lua_tolstring(L,-1,&configuration_size);lua_pop(L,1);}
        job=new_job(processes,session->vendor,configuration,configuration_size);if(!job){lua_pushnil(L);lua_pushstring(L,worker_error(session->vendor,errno==EBUSY?BUSY:ALLOCATION));return 2;}
        session->job=job;pthread_t thread;int error=pthread_create(&thread,NULL,controller,job);
        if(error){session->job=NULL;atomic_store(&job->refs,1);job_release(job);atomic_fetch_sub(&controllers[session->vendor],1);lua_pushnil(L);lua_pushstring(L,worker_error(session->vendor,UNAVAILABLE));return 2;}
        pthread_detach(thread);
    }
    atomic_fetch_add(&job->refs,1);guard->job=job;
    /* Reserve a finalizable reference before touching a frame. Lua GC or OOM
     * can re-enter this provider while the outer decoder is allocating. */
    struct timespec limit;wait_deadline(&limit,wait_ms);
    pthread_mutex_lock(&job->mutex);
    if(job->state==IDLE){job->state=QUERY;job->processes=processes;job->requested=client_now();pthread_cond_broadcast(&job->condition);}
    while(wait_ms&&job->state==QUERY&&!job->done){int error=pthread_cond_timedwait(&job->condition,&job->mutex,&limit);if(error)break;}
    struct gpu_frame *frame=job->state==READY?job->frame:NULL;
    if(frame&&(frame->processes!=(unsigned)processes||client_now()-frame->started>GPU_FRAME_NS)){
        job->frame=NULL;job->state=QUERY;job->processes=processes;job->requested=client_now();
        pthread_cond_broadcast(&job->condition);pthread_mutex_unlock(&job->mutex);frame_release(frame);
        lua_pushnil(L);lua_pushstring(L,worker_error(session->vendor,PENDING));guard_release(guard);return 2;
    }
    if(frame){atomic_fetch_add(&frame->refs,1);guard->frame=frame;}
    int error_state=job->state==ERROR,expired=client_now()-job->requested>=GPU_QUERY_NS;
    char reason[96];snprintf(reason,sizeof(reason),"%s",job->reason);pthread_mutex_unlock(&job->mutex);
    if(!frame){lua_pushnil(L);lua_pushstring(L,error_state?reason:worker_error(session->vendor,expired?TIMEOUT:PENDING));guard_release(guard);return 2;}
    if(session->vendor<GPU_VENDOR_COUNT)decode_frame(L,frame);
    else {lua_pushlstring(L,(const char *)frame->data,frame->size);lua_newtable(L);}
    lua_pushinteger(L,(lua_Integer)frame->started);lua_setfield(L,-2,"sample_started_ns");
    lua_pushinteger(L,(lua_Integer)frame->finished);lua_setfield(L,-2,"sample_finished_ns");
    lua_pushboolean(L,frame->processes!=0&&session->vendor==GPU_NVML);lua_setfield(L,-2,"processes_included");
    lua_pushliteral(L,"process");lua_setfield(L,-2,"transport");
    lua_pushinteger(L,(lua_Integer)atomic_load(&job->pid));lua_setfield(L,-2,"worker_pid");
    struct gpu_frame *old=NULL;pthread_mutex_lock(&job->mutex);
    if(job->frame==frame&&!atomic_load(&job->cancelled)&&!job->done){old=job->frame;job->frame=NULL;job->state=session->vendor<GPU_VENDOR_COUNT?QUERY:IDLE;job->processes=processes;job->requested=client_now();pthread_cond_broadcast(&job->condition);}
    pthread_mutex_unlock(&job->mutex);frame_release(old);guard_release(guard);lua_remove(L,guard_index);return session->vendor<GPU_VENDOR_COUNT?1:2;
}

int wtop_gpu_worker_open(lua_State *L) {
    const char *name=luaL_checkstring(L,1);
    for(unsigned i=0;i<GPU_VENDOR_COUNT;++i)
        if(!strcmp(name,vendor_names[i]))return open_session(L,(enum gpu_vendor)i);
    return luaL_argerror(L,1,"unknown GPU provider");
}
int wtop_gpu_worker_query(lua_State *L) {
    lua_Integer wait=luaL_optinteger(L,3,0);
    luaL_argcheck(L,wait>=0&&wait<=GPU_REPLY_WAIT_MS,3,"wait must be 0..50 ms");
    return query_session(L,(unsigned)wait);
}
/* Preserve the isolated NVML low-level API and its bounded 50ms wait. */
int wtop_nvml_worker_open(lua_State *L) {return open_session(L,GPU_NVML);}
int wtop_nvml_worker_query(lua_State *L) {return query_session(L,GPU_REPLY_WAIT_MS);}
int wtop_nvml_worker_close(lua_State *L) {return wtop_gpu_worker_close(L);}

int wtop_hardware_worker_open(lua_State *L) {
    const char *name=luaL_checkstring(L,1);size_t size;
    (void)luaL_checklstring(L,2,&size);luaL_argcheck(L,size>0&&size<=65536,2,"configuration must be 1..65536 bytes");
    for(unsigned i=GPU_VENDOR_COUNT;i<WORKER_COUNT;++i)
        if(!strcmp(name,vendor_names[i]))return open_session(L,i);
    return luaL_argerror(L,1,"unknown hardware collector");
}
int wtop_hardware_worker_query(lua_State *L) {return wtop_gpu_worker_query(L);}
int wtop_hardware_worker_close(lua_State *L) {return wtop_gpu_worker_close(L);}
