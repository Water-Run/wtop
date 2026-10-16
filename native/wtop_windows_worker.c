/* Win32 hardware transport. Driver calls run in a self-launched reader;
 * its controller thread owns all blocking IPC, process waits and teardown. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "wtop_gpu_protocol.h"
#include "wtop_windows_sdk_image.h"
#include "wtop_windows_spawn.h"
#define SESSION_META "wtop.windows.hardware.session.v1"
#define FRAME_META "wtop.windows.hardware.frame.v1"
#define QUERY_NS UINT64_C(2000000000)
#define RETRY_NS UINT64_C(5000000000)
#define FRAME_NS UINT64_C(5000000000)
static char launcher_key;
/* Source numbers are wire identifiers. NVML remains 3 (wire kind 6). */
#define NVML_SOURCE 3u
#define LEVELZERO_SOURCE 6u
#define HARDWARE_SOURCES 7u
static const char *const source_names[HARDWARE_SOURCES]={"cpufreq","gpu","hwmon","nvml","disk_health","disk","levelzero"};
static const WCHAR *const wide_source_names[HARDWARE_SOURCES]={L"cpufreq",L"gpu",L"hwmon",L"nvml",L"disk_health",L"disk",L"levelzero"};
static volatile LONG controllers,source_controllers[HARDWARE_SOURCES];
static int sdk_source(unsigned source) {return source==NVML_SOURCE||source==LEVELZERO_SOURCE;}
static unsigned source_index(const char *name,size_t size){
    for(unsigned i=0;i<HARDWARE_SOURCES;++i)if(size==strlen(source_names[i])&&!memcmp(name,source_names[i],size))return i;
    return HARDWARE_SOURCES;
}
enum state { REQUESTED, READY, IDLE, FAILED };
struct frame { volatile LONG refs; uint64_t started,finished; unsigned flags; size_t size; unsigned char data[]; };
struct job {
    volatile LONG refs,done;
    CRITICAL_SECTION mutex;
    HANDLE cancel,request,changed;
    HMODULE module;
    enum state state;
    unsigned flags,source;
    DWORD pid;
    uint64_t requested,failed_at,sequence;
    struct frame *frame;
    const char *reason;
    char sdk_reason[96];
    size_t configuration_size;
    char *configuration,*entry;
};
struct session { struct job *job; int closed; unsigned source; };
struct guard { struct job *job; struct frame *frame; };
static uint64_t now_ns(void) {
    LARGE_INTEGER counter,frequency;
    if(!QueryPerformanceCounter(&counter)||!QueryPerformanceFrequency(&frequency)||frequency.QuadPart<=0||counter.QuadPart<0)return 0;
    uint64_t f=(uint64_t)frequency.QuadPart,n=(uint64_t)counter.QuadPart;
    return n/f*UINT64_C(1000000000)+(n%f)*UINT64_C(1000000000)/f;
}
static void frame_release(struct frame *frame) { if(frame&&InterlockedDecrement(&frame->refs)==0)free(frame); }
static void job_release(struct job *job) {
    if(job&&InterlockedDecrement(&job->refs)==0){
        frame_release(job->frame);CloseHandle(job->cancel);CloseHandle(job->request);CloseHandle(job->changed);
        DeleteCriticalSection(&job->mutex);free(job);
    }
}
static int cancelled(struct job *job) { return WaitForSingleObject(job->cancel,0)!=WAIT_TIMEOUT; }
static void cancel_job(struct job *job) { if(job){SetEvent(job->cancel);SetEvent(job->request);} }
static int session_close(lua_State *L) {
    struct session *session=luaL_testudata(L,1,SESSION_META);
    if(session&&!session->closed){session->closed=1;cancel_job(session->job);job_release(session->job);session->job=NULL;}
    return 0;
}
static void release_guard(struct guard *guard) {
    frame_release(guard->frame);guard->frame=NULL;job_release(guard->job);guard->job=NULL;
}
static int guard_close(lua_State *L) { release_guard(luaL_checkudata(L,1,FRAME_META));return 0; }
static int failure(lua_State *L,const char *reason) { lua_pushnil(L);lua_pushstring(L,reason);return 2; }
static WCHAR *wide_string(const char *text) {
    int length=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,NULL,0);
    if(length<=0||length>32767)return NULL;
    WCHAR *value=malloc((size_t)length*sizeof(*value));
    if(value&&!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,value,length)){free(value);value=NULL;}
    return value;
}
static size_t quote_argument(WCHAR *output,const WCHAR *input) {
    size_t count=0;output[count++]=L'"';
    while(*input){
        size_t slashes=0;while(*input==L'\\'){++slashes;++input;}
        if(!*input||*input==L'"')slashes*=2;
        while(slashes--)output[count++]=L'\\';
        if(*input==L'"')output[count++]=L'\\';
        if(*input)output[count++]=*input++;
    }
    output[count++]=L'"';output[count]=0;return count;
}
static int transmit(HANDLE pipe,const void *data,size_t size,struct job *job) {
    const unsigned char *bytes=data;
    while(size&&!cancelled(job)){
        DWORD written=0,n=(DWORD)(size>32768?32768:size);
        if(!WriteFile(pipe,bytes,n,&written,NULL)||!written)return 0;
        bytes+=written;size-=written;
    }
    return size==0;
}
static int receive(HANDLE pipe,HANDLE process,void *data,size_t size,struct job *job) {
    unsigned char *bytes=data;
    while(size){
        if(cancelled(job))return 0;
        if(now_ns()-job->requested>=QUERY_NS){job->reason="hardware_query_timeout";return 0;}
        DWORD available=0;
        if(!PeekNamedPipe(pipe,NULL,0,NULL,&available,NULL))return 0;
        if(available){
            DWORD read=0,n=(DWORD)(size<available?size:available);
            if(!ReadFile(pipe,bytes,n,&read,NULL)||!read)return 0;
            bytes+=read;size-=read;continue;
        }
        if(WaitForSingleObject(process,0)!=WAIT_TIMEOUT)return 0;
        if(WaitForSingleObject(job->cancel,2)!=WAIT_TIMEOUT)return 0;
    }
    return 1;
}
static DWORD WINAPI controller(void *opaque) {
    struct job *job=opaque;
    HANDLE input=NULL,input_child=NULL,output=NULL,output_child=NULL,parent=NULL,stop=NULL,null_file=INVALID_HANDLE_VALUE;
    PROCESS_INFORMATION process;memset(&process,0,sizeof(process));
    HANDLE sdk_image=NULL;
    WCHAR *executable=calloc(32768,sizeof(WCHAR)),*entry=NULL,*command=NULL;
    job->reason="hardware_worker_unavailable";
    if(!executable)goto finish;
    if(sdk_source(job->source)){
        sdk_image=job->source==NVML_SOURCE?nvml_reader_image(executable,32768):levelzero_reader_image(executable,32768);if(!sdk_image)goto finish;
    }else{
        DWORD length=GetModuleFileNameW(NULL,executable,32768);
        if(!length||length>=32768)goto finish;
    }
    entry=wide_string(job->entry);if(!entry)goto finish;
    size_t capacity=2*wcslen(executable)+2*wcslen(entry)+256;
    if(capacity>32767)goto finish;
    command=calloc(capacity,sizeof(WCHAR));if(!command)goto finish;
    SECURITY_ATTRIBUTES security={sizeof(security),NULL,TRUE};
    if(!CreatePipe(&input_child,&input,&security,65536)||!SetHandleInformation(input,HANDLE_FLAG_INHERIT,0)
        ||!CreatePipe(&output,&output_child,&security,65536)||!SetHandleInformation(output,HANDLE_FLAG_INHERIT,0)
        ||!DuplicateHandle(GetCurrentProcess(),GetCurrentProcess(),GetCurrentProcess(),&parent,SYNCHRONIZE,TRUE,0)
        ||!DuplicateHandle(GetCurrentProcess(),job->cancel,GetCurrentProcess(),&stop,SYNCHRONIZE,TRUE,0))goto finish;
    null_file=CreateFileW(L"NUL",GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,0,NULL);
    if(null_file==INVALID_HANDLE_VALUE)goto finish;
    size_t at=quote_argument(command,executable);
    if(entry[0]){command[at++]=L' ';at+=quote_argument(command+at,entry);}
    int used=_snwprintf(command+at,capacity-at,L" --wtop-hardware-reader %lx %lx %lx %lx %ls",
        (unsigned long)(uintptr_t)parent,(unsigned long)(uintptr_t)stop,
        (unsigned long)(uintptr_t)input_child,(unsigned long)(uintptr_t)output_child,wide_source_names[job->source]);
    if(used<0||(size_t)used>=capacity-at||cancelled(job))goto finish;
    STARTUPINFOW startup;memset(&startup,0,sizeof(startup));startup.cb=sizeof(startup);
    startup.dwFlags=STARTF_USESTDHANDLES;startup.hStdInput=startup.hStdOutput=startup.hStdError=null_file;
    HANDLE inherited[]={parent,stop,input_child,output_child,null_file};
    if(!wtop_spawn_reader(executable,command,&startup,inherited,5,&process))goto finish;
    CloseHandle(process.hThread);process.hThread=NULL;
    CloseHandle(input_child);input_child=NULL;CloseHandle(output_child);output_child=NULL;
    CloseHandle(parent);parent=NULL;CloseHandle(stop);stop=NULL;CloseHandle(null_file);null_file=INVALID_HANDLE_VALUE;
    EnterCriticalSection(&job->mutex);job->pid=process.dwProcessId;LeaveCriticalSection(&job->mutex);
    unsigned char prefix[4];gpu_put32(prefix,(uint32_t)job->configuration_size);
    if(!transmit(input,prefix,sizeof(prefix),job)||!transmit(input,job->configuration,job->configuration_size,job))goto finish;
    job->reason="hardware_worker_exited";
    for(;;){
        HANDLE waits[]={job->cancel,job->request,process.hProcess};
        if(WaitForMultipleObjects(3,waits,FALSE,INFINITE)!=WAIT_OBJECT_0+1)break;
        if(cancelled(job))break;
        EnterCriticalSection(&job->mutex);
        unsigned flags=job->flags;uint64_t sequence=++job->sequence;int requested=job->state==REQUESTED;
        LeaveCriticalSection(&job->mutex);
        if(!requested)continue;
        unsigned char request[GPU_WIRE_COMMAND]={0},header[GPU_WIRE_HEADER];
        gpu_put32(request,GPU_WIRE_MAGIC);gpu_put32(request+4,GPU_WIRE_VERSION);
        gpu_put64(request+8,sequence);gpu_put32(request+16,flags);
        if(!transmit(input,request,sizeof(request),job)||!receive(output,process.hProcess,header,sizeof(header),job))break;
        uint32_t size=gpu_u32(header+8),status=gpu_u32(header+12);uint64_t start=gpu_u64(header+24),end=gpu_u64(header+32);
        unsigned reserved=0;for(unsigned i=52;i<GPU_WIRE_HEADER;++i)reserved|=header[i];
        if(gpu_u32(header)!=GPU_WIRE_MAGIC||gpu_u32(header+4)!=GPU_WIRE_VERSION||!size||size>GPU_WIRE_LIMIT
            ||status>1||gpu_u64(header+16)!=sequence||start<job->requested||end<start||end>now_ns()
            ||gpu_u32(header+40)!=flags||gpu_u32(header+48)!=3+job->source||reserved){job->reason="hardware_invalid_response";break;}
        struct frame *frame=malloc(sizeof(*frame)+size);
        if(!frame){job->reason="hardware_allocation_failed";break;}
        frame->refs=1;frame->size=size;frame->started=start;frame->finished=end;frame->flags=flags;
        if(!receive(output,process.hProcess,frame->data,size,job)){frame_release(frame);break;}
        if(gpu_checksum(frame->data,size)!=gpu_u32(header+44)){frame_release(frame);job->reason="hardware_invalid_response";break;}
        if(status){
            job->reason="hardware_collector_error";
            if(sdk_source(job->source)){
                const char *prefix=job->source==NVML_SOURCE?"nvml_":"levelzero_";size_t prefix_size=strlen(prefix);
                int valid=size>prefix_size&&size<sizeof(job->sdk_reason)&&!memcmp(frame->data,prefix,prefix_size);
                for(uint32_t i=0;valid&&i<size;++i){unsigned char c=frame->data[i];valid=(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='_';}
                if(valid){memcpy(job->sdk_reason,frame->data,size);job->sdk_reason[size]=0;job->reason=job->sdk_reason;}
                else job->reason="hardware_invalid_response";
            }
            frame_release(frame);break;
        }
        if(sdk_source(job->source)&&!gpu_wire_valid(frame->data,frame->size)){
            frame_release(frame);job->reason="hardware_invalid_response";break;
        }
        EnterCriticalSection(&job->mutex);
        job->frame=frame;job->state=READY;SetEvent(job->changed);
        LeaveCriticalSection(&job->mutex);
    }
finish:
    if(process.hProcess){
        SetEvent(job->cancel);
        /* Only a signalled process handle proves exit. A failed wait also
         * retains the slot; it must not spin or masquerade as successful reap. */
        DWORD waited=WaitForSingleObject(process.hProcess,0);
        while(waited!=WAIT_OBJECT_0){
            (void)TerminateProcess(process.hProcess,3);
            if(waited==WAIT_FAILED)Sleep(100);
            waited=WaitForSingleObject(process.hProcess,100);
        }
        CloseHandle(process.hProcess);
    }
    if(process.hThread)CloseHandle(process.hThread);
    if(input)CloseHandle(input);
    if(input_child)CloseHandle(input_child);
    if(output)CloseHandle(output);
    if(output_child)CloseHandle(output_child);
    if(parent)CloseHandle(parent);
    if(stop)CloseHandle(stop);
    if(null_file!=INVALID_HANDLE_VALUE)CloseHandle(null_file);
    if(sdk_image)CloseHandle(sdk_image);
    free(executable);free(entry);free(command);
    EnterCriticalSection(&job->mutex);job->failed_at=now_ns();job->state=FAILED;
    InterlockedExchange(&job->done,1);SetEvent(job->changed);LeaveCriticalSection(&job->mutex);
    HMODULE module=job->module;InterlockedDecrement(&source_controllers[job->source]);InterlockedDecrement(&controllers);job_release(job);
    FreeLibraryAndExitThread(module,0);return 0;
}
static struct job *new_job(const char *configuration,size_t size,const char *entry,unsigned flags,unsigned source,const char **reason) {
    *reason="hardware_allocation_failed";
    if(InterlockedIncrement(&source_controllers[source])>2){InterlockedDecrement(&source_controllers[source]);*reason="hardware_worker_busy";return NULL;}
    InterlockedIncrement(&controllers);
    size_t entry_size=strlen(entry)+1;
    struct job *job=calloc(1,sizeof(*job)+size+entry_size);
    if(!job)goto failed;
    if(!InitializeCriticalSectionAndSpinCount(&job->mutex,0)){free(job);job=NULL;goto failed;}
    job->refs=1;job->source=source;
    job->cancel=CreateEventW(NULL,TRUE,FALSE,NULL);job->request=CreateEventW(NULL,FALSE,TRUE,NULL);job->changed=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!job->cancel||!job->request||!job->changed){job_release(job);job=NULL;goto failed;}
    if(!GetModuleHandleExW(4,(LPCWSTR)(uintptr_t)&new_job,&job->module)){job_release(job);job=NULL;*reason="hardware_worker_unavailable";goto failed;}
    job->configuration=(char *)(job+1);memcpy(job->configuration,configuration,size);job->configuration_size=size;
    job->entry=job->configuration+size;memcpy(job->entry,entry,entry_size);
    job->state=REQUESTED;job->flags=flags;job->requested=now_ns();job->refs=2;
    HANDLE thread=CreateThread(NULL,0,controller,job,0,NULL);
    if(!thread){HMODULE module=job->module;job->refs=1;job_release(job);FreeLibrary(module);job=NULL;*reason="hardware_worker_unavailable";goto failed;}
    CloseHandle(thread);return job;
failed:
    InterlockedDecrement(&source_controllers[source]);InterlockedDecrement(&controllers);return NULL;
}
int wtop_windows_hardware_configure(lua_State *L) {
    size_t size=0;const char *entry=luaL_optlstring(L,1,"",&size);
    luaL_argcheck(L,size<=16383&&!memchr(entry,0,size),1,"invalid reader entry");
    lua_pushlstring(L,entry,size);lua_rawsetp(L,LUA_REGISTRYINDEX,&launcher_key);
    lua_createtable(L,0,HARDWARE_SOURCES);
    for(unsigned i=0;i<HARDWARE_SOURCES;++i)if(!sdk_source(i)){lua_pushboolean(L,1);lua_setfield(L,-2,source_names[i]);}
    return 1;
}
int wtop_windows_hardware_open(lua_State *L) {
    size_t name_size;const char *name=luaL_checklstring(L,1,&name_size);
    unsigned source=source_index(name,name_size);
    luaL_argcheck(L,source<HARDWARE_SOURCES&&!sdk_source(source),1,"unknown hardware source");
    size_t size;(void)luaL_checklstring(L,2,&size);luaL_argcheck(L,size&&size<=65536,2,"invalid configuration size");
    lua_rawgetp(L,LUA_REGISTRYINDEX,&launcher_key);
    if(lua_type(L,-1)!=LUA_TSTRING)return failure(L,"hardware_worker_unavailable");
    int launcher=lua_gettop(L);
    struct session *session=lua_newuserdatauv(L,sizeof(*session),2);session->job=NULL;session->closed=0;session->source=source;
    luaL_newmetatable(L,SESSION_META);lua_pushcfunction(L,session_close);lua_setfield(L,-2,"__gc");
    lua_pushcfunction(L,session_close);lua_setfield(L,-2,"__close");lua_setmetatable(L,-2);
    lua_pushvalue(L,2);lua_setiuservalue(L,-2,1);lua_pushvalue(L,launcher);lua_setiuservalue(L,-2,2);return 1;
}
int wtop_windows_hardware_close(lua_State *L) { session_close(L);lua_pushboolean(L,1);return 1; }
int wtop_windows_hardware_query(lua_State *L) {
    struct session *session=luaL_checkudata(L,1,SESSION_META);unsigned flags=lua_toboolean(L,2)?1u:0u;
    if(session->source==1&&lua_type(L,4)==LUA_TBOOLEAN&&!lua_toboolean(L,4))flags|=2;
    lua_Integer wait=luaL_optinteger(L,3,0);luaL_argcheck(L,wait>=0&&wait<=50,3,"wait must be 0..50 ms");
    struct guard *guard=lua_newuserdatauv(L,sizeof(*guard),0);guard->job=NULL;guard->frame=NULL;
    luaL_newmetatable(L,FRAME_META);lua_pushcfunction(L,guard_close);lua_setfield(L,-2,"__gc");lua_setmetatable(L,-2);
    int guard_index=lua_gettop(L);
    if(session->closed)return failure(L,"hardware_worker_closed");
    struct job *job=session->job;
    if(job&&InterlockedCompareExchange(&job->done,0,0)&&now_ns()-job->failed_at>=RETRY_NS){session->job=NULL;job_release(job);job=NULL;}
    if(!job){
        lua_getiuservalue(L,1,1);size_t size;const char *configuration=lua_tolstring(L,-1,&size);
        lua_getiuservalue(L,1,2);const char *entry=lua_tostring(L,-1),*reason;
        job=new_job(configuration,size,entry,flags,session->source,&reason);lua_pop(L,2);
        if(!job)return failure(L,reason);
        session->job=job;
    }
    InterlockedIncrement(&job->refs);guard->job=job;
    EnterCriticalSection(&job->mutex);
    if(job->state==IDLE){job->flags=flags;job->requested=now_ns();job->state=REQUESTED;ResetEvent(job->changed);SetEvent(job->request);}
    LeaveCriticalSection(&job->mutex);
    if(wait)(void)WaitForSingleObject(job->changed,(DWORD)wait);
    EnterCriticalSection(&job->mutex);
    struct frame *frame=job->state==READY?job->frame:NULL;
    if(frame&&(frame->flags!=flags||now_ns()-frame->started>FRAME_NS)){
        job->frame=NULL;job->flags=flags;job->requested=now_ns();job->state=REQUESTED;
        ResetEvent(job->changed);SetEvent(job->request);LeaveCriticalSection(&job->mutex);frame_release(frame);
        release_guard(guard);return failure(L,"hardware_query_pending");
    }
    if(frame){InterlockedIncrement(&frame->refs);guard->frame=frame;}
    const char *reason=job->state==FAILED?job->reason:now_ns()-job->requested>=QUERY_NS?"hardware_query_timeout":"hardware_query_pending";
    DWORD pid=job->pid;LeaveCriticalSection(&job->mutex);
    if(!frame){release_guard(guard);return failure(L,reason);}
    lua_pushlstring(L,(const char *)frame->data,frame->size);lua_createtable(L,0,4);
    lua_pushinteger(L,(lua_Integer)frame->started);lua_setfield(L,-2,"sample_started_ns");
    lua_pushinteger(L,(lua_Integer)frame->finished);lua_setfield(L,-2,"sample_finished_ns");
    lua_pushinteger(L,pid);lua_setfield(L,-2,"worker_pid");lua_pushliteral(L,"process");lua_setfield(L,-2,"transport");
    struct frame *old=NULL;EnterCriticalSection(&job->mutex);
    if(job->frame==frame&&job->state==READY){old=job->frame;job->frame=NULL;job->state=IDLE;}
    LeaveCriticalSection(&job->mutex);frame_release(old);release_guard(guard);lua_remove(L,guard_index);return 2;
}
int wtop_windows_gpu_open(lua_State *L) {
    size_t size;const char *source=luaL_checklstring(L,1,&size);
    unsigned source_id=source_index(source,size);
    luaL_argcheck(L,sdk_source(source_id),1,"unknown GPU source");
    struct session *session=lua_newuserdatauv(L,sizeof(*session),2);
    session->job=NULL;session->closed=0;session->source=source_id;
    luaL_newmetatable(L,SESSION_META);lua_pushcfunction(L,session_close);lua_setfield(L,-2,"__gc");
    lua_pushcfunction(L,session_close);lua_setfield(L,-2,"__close");lua_setmetatable(L,-2);
    lua_pushliteral(L,"x");lua_setiuservalue(L,-2,1);lua_pushliteral(L,"");lua_setiuservalue(L,-2,2);return 1;
}
static void decode_sdk_frame(lua_State *L,const unsigned char *data,size_t length) {
    size_t p=0;luaL_checkstack(L,80,"GPU response");
    while(p<length){
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
int wtop_windows_gpu_query(lua_State *L) {
    struct session *session=luaL_checkudata(L,1,SESSION_META);
    luaL_argcheck(L,sdk_source(session->source),1,"not a GPU reader");
    const char *name=source_names[session->source];
    int result=wtop_windows_hardware_query(L);
    if(result!=2||lua_type(L,-2)!=LUA_TSTRING){
        const char *reason=lua_tostring(L,-1);
        if(reason&&session->source==LEVELZERO_SOURCE&&!strcmp(reason,"levelzero_legacy_required")
            &&session->job&&InterlockedCompareExchange(&session->job->done,0,0)){
            lua_getiuservalue(L,1,1);int legacy=lua_tostring(L,-1)[0]=='l';lua_pop(L,1);
            if(!legacy){
                /* done is set only after the original process is signalled.
                 * No initialized Sysman state crosses into the legacy reader. */
                lua_pushliteral(L,"l");lua_setiuservalue(L,1,1);
                struct job *old=session->job;session->job=NULL;job_release(old);
                lua_pushliteral(L,"levelzero_query_pending");lua_replace(L,-2);return 2;
            }
        }
        if(reason&&!strncmp(reason,"hardware_",9))lua_pushfstring(L,"%s_%s",name,reason+9);
        else if(reason)lua_pushstring(L,reason);
        else lua_pushfstring(L,"%s_query_failed",name);
        lua_replace(L,-2);return 2;
    }
    size_t size;const unsigned char *bytes=(const unsigned char *)lua_tolstring(L,-2,&size);
    int metadata=lua_gettop(L);decode_sdk_frame(L,bytes,size);
    const char *keys[]={"sample_started_ns","sample_finished_ns","worker_pid","transport"};
    for(unsigned i=0;i<4;++i){lua_getfield(L,metadata,keys[i]);lua_setfield(L,-2,keys[i]);}
    return 1;
}
/* Child-only side. The watcher never accesses Lua, even if the collector is
 * stuck while holding its own Lua stack or a loader/provider lock. */
struct watcher { HANDLE parent,cancel,stop,ready; };
static DWORD WINAPI watch_parent(void *opaque) {
    struct watcher watch=*(struct watcher *)opaque;free(opaque);
    SetEvent(watch.ready);
    HANDLE handles[]={watch.parent,watch.cancel,watch.stop};
    DWORD status=WaitForMultipleObjects(3,handles,FALSE,INFINITE);
    if(status!=WAIT_OBJECT_0+2)(void)TerminateProcess(GetCurrentProcess(),3);
    return 0;
}
static HANDLE handle_argument(lua_State *L,int argument) {
    size_t size;const char *text=luaL_checklstring(L,argument,&size);uintptr_t value=0;
    if(!size||size>sizeof(value)*2)return NULL;
    for(size_t i=0;i<size;++i){unsigned n=text[i]>='0'&&text[i]<='9'?(unsigned)(text[i]-'0'):text[i]>='a'&&text[i]<='f'?(unsigned)(text[i]-'a'+10):16;
        if(n>15)return NULL;
        value=value*16+n;}
    return (HANDLE)value;
}
static int child_receive(HANDLE pipe,void *data,size_t size) {
    unsigned char *bytes=data;
    while(size){DWORD read=0,n=(DWORD)(size>32768?32768:size);if(!ReadFile(pipe,bytes,n,&read,NULL)||!read)return 0;bytes+=read;size-=read;}
    return 1;
}
static int child_send(HANDLE pipe,const void *data,size_t size) {
    const unsigned char *bytes=data;
    while(size){DWORD written=0,n=(DWORD)(size>32768?32768:size);if(!WriteFile(pipe,bytes,n,&written,NULL)||!written)return 0;bytes+=written;size-=written;}
    return 1;
}
static int child_initialize(lua_State *L) {
    lua_getglobal(L,"require");lua_pushliteral(L,"wtop.core.hardware_worker");lua_call(L,1,1);
    lua_pushvalue(L,1);lua_pushvalue(L,2);lua_call(L,2,1);return 1;
}
int wtop_windows_hardware_run(lua_State *L) {
    struct watcher watch={handle_argument(L,1),handle_argument(L,2),NULL,NULL};
    HANDLE input=handle_argument(L,3),output=handle_argument(L,4);
    size_t name_size;const char *source=luaL_checklstring(L,5,&name_size);
    unsigned source_id=source_index(source,name_size);
    if(lua_gettop(L)!=5||(source_id>=HARDWARE_SOURCES||sdk_source(source_id))||!watch.parent||!watch.cancel||!input||!output
        ||GetFileType(input)!=FILE_TYPE_PIPE||GetFileType(output)!=FILE_TYPE_PIPE
        ||WaitForSingleObject(watch.parent,0)!=WAIT_TIMEOUT||WaitForSingleObject(watch.cancel,0)!=WAIT_TIMEOUT){lua_pushinteger(L,2);return 1;}
    if(!SetHandleInformation(watch.parent,HANDLE_FLAG_INHERIT,0)||!SetHandleInformation(watch.cancel,HANDLE_FLAG_INHERIT,0)
        ||!SetHandleInformation(input,HANDLE_FLAG_INHERIT,0)||!SetHandleInformation(output,HANDLE_FLAG_INHERIT,0)){lua_pushinteger(L,2);return 1;}
    watch.stop=CreateEventW(NULL,TRUE,FALSE,NULL);watch.ready=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!watch.stop||!watch.ready){if(watch.stop)CloseHandle(watch.stop);if(watch.ready)CloseHandle(watch.ready);lua_pushinteger(L,3);return 1;}
    struct watcher *copy=malloc(sizeof(*copy));
    if(!copy){CloseHandle(watch.stop);CloseHandle(watch.ready);lua_pushinteger(L,5);return 1;}
    *copy=watch;HANDLE thread=CreateThread(NULL,0,watch_parent,copy,0,NULL);
    if(!thread){free(copy);CloseHandle(watch.stop);CloseHandle(watch.ready);lua_pushinteger(L,3);return 1;}
    int code=4;unsigned char prefix[4];
    if(WaitForSingleObject(watch.ready,5000)!=WAIT_OBJECT_0)goto finish;
    if(!child_receive(input,prefix,4))goto finish;
    uint32_t size=gpu_u32(prefix);if(!size||size>65536)goto finish;
    char *configuration=malloc(size);if(!configuration){code=5;goto finish;}
    if(!child_receive(input,configuration,size)){free(configuration);goto finish;}
    lua_pushcfunction(L,child_initialize);lua_pushstring(L,source);lua_pushlstring(L,configuration,size);free(configuration);
    int initialized=lua_pcall(L,2,1,0)==LUA_OK,factory=lua_gettop(L);
    uint64_t previous=0;unsigned char command[GPU_WIRE_COMMAND];
    while(child_receive(input,command,sizeof(command))){
        uint64_t sequence=gpu_u64(command+8);uint32_t flags=gpu_u32(command+16);
        if(gpu_u32(command)!=GPU_WIRE_MAGIC||gpu_u32(command+4)!=GPU_WIRE_VERSION||gpu_u32(command+20)
            ||!sequence||sequence<=previous||(flags&~(source_id==1?3u:1u)))break;
        previous=sequence;uint64_t start=now_ns();int success=0;size_t length=0;const char *data;
        if(initialized){lua_pushvalue(L,factory);lua_pushboolean(L,(flags&1)!=0);lua_pushboolean(L,(flags&2)==0);
            if(lua_pcall(L,2,1,0)==LUA_OK&&lua_type(L,-1)==LUA_TSTRING){data=lua_tolstring(L,-1,&length);success=length&&length<=GPU_WIRE_LIMIT;}}
        if(!success){data="hardware_collector_error";length=strlen(data);}
        uint64_t end=now_ns();unsigned char header[GPU_WIRE_HEADER]={0};
        gpu_put32(header,GPU_WIRE_MAGIC);gpu_put32(header+4,GPU_WIRE_VERSION);gpu_put32(header+8,(uint32_t)length);
        gpu_put32(header+12,success?0:1);gpu_put64(header+16,sequence);gpu_put64(header+24,start);gpu_put64(header+32,end);
        gpu_put32(header+40,flags);gpu_put32(header+44,gpu_checksum(data,length));gpu_put32(header+48,3+source_id);
        if(!child_send(output,header,sizeof(header))||!child_send(output,data,length)||!success)break;
        lua_settop(L,factory);code=0;
    }
finish:
    SetEvent(watch.stop);(void)WaitForSingleObject(thread,INFINITE);
    CloseHandle(thread);CloseHandle(watch.stop);CloseHandle(watch.ready);CloseHandle(watch.parent);CloseHandle(watch.cancel);CloseHandle(input);CloseHandle(output);
    lua_pushinteger(L,code);return 1;
}
