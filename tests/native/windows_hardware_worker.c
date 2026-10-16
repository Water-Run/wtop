/* Exercise the production transport against deterministic child processes.
 * No device state, installed files or global user configuration is changed. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <assert.h>
#include <process.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static volatile LONG native_blocks,native_calls,native_fail_at,fail_thread,owned_sections;
static volatile LONG owned_handles[128];
static void own_handle(HANDLE h){if(h&&h!=INVALID_HANDLE_VALUE){for(unsigned i=0;i<128;++i)if(InterlockedCompareExchange(&owned_handles[i],(LONG)(uintptr_t)h,0)==0)return;assert(0);}}
static HANDLE WINAPI fixture_event(LPSECURITY_ATTRIBUTES a,BOOL manual,BOOL initial,LPCWSTR name){HANDLE h=CreateEventW(a,manual,initial,name);own_handle(h);return h;}
static BOOL WINAPI fixture_close(HANDLE h){
 for(unsigned i=0;i<128;++i)(void)InterlockedCompareExchange(&owned_handles[i],0,(LONG)(uintptr_t)h);
 BOOL ok=CloseHandle(h);assert(ok);return ok;
}
static BOOL WINAPI fixture_pipe(PHANDLE reader,PHANDLE writer,LPSECURITY_ATTRIBUTES a,DWORD size){BOOL ok=CreatePipe(reader,writer,a,size);if(ok){own_handle(*reader);own_handle(*writer);}return ok;}
static BOOL WINAPI fixture_duplicate(HANDLE source,HANDLE h,HANDLE target,LPHANDLE result,DWORD access,BOOL inherit,DWORD options){BOOL ok=DuplicateHandle(source,h,target,result,access,inherit,options);if(ok)own_handle(*result);return ok;}
static HANDLE WINAPI fixture_file(LPCWSTR name,DWORD access,DWORD sharing,LPSECURITY_ATTRIBUTES a,DWORD creation,DWORD flags,HANDLE template){HANDLE h=CreateFileW(name,access,sharing,a,creation,flags,template);own_handle(h);return h;}
static BOOL WINAPI fixture_process(LPCWSTR exe,LPWSTR command,LPSECURITY_ATTRIBUTES process_security,LPSECURITY_ATTRIBUTES thread_security,BOOL inherit,DWORD flags,LPVOID env,LPCWSTR cwd,LPSTARTUPINFOW startup,LPPROCESS_INFORMATION process){BOOL ok=CreateProcessW(exe,command,process_security,thread_security,inherit,flags,env,cwd,startup,process);if(ok){own_handle(process->hProcess);own_handle(process->hThread);}return ok;}
static BOOL WINAPI fixture_section(LPCRITICAL_SECTION section,DWORD spin){BOOL ok=InitializeCriticalSectionAndSpinCount(section,spin);if(ok)InterlockedIncrement(&owned_sections);return ok;}
static void WINAPI fixture_delete_section(LPCRITICAL_SECTION section){DeleteCriticalSection(section);assert(InterlockedDecrement(&owned_sections)>=0);}
static int fail_native_alloc(void){LONG n=InterlockedIncrement(&native_calls);return native_fail_at&&n==native_fail_at;}
#define CreateEventW fixture_event
#define CloseHandle fixture_close
#define CreatePipe fixture_pipe
#define DuplicateHandle fixture_duplicate
#define CreateFileW fixture_file
#define CreateProcessW fixture_process
#define InitializeCriticalSectionAndSpinCount fixture_section
#define DeleteCriticalSection fixture_delete_section
static void *native_malloc(size_t size){if(fail_native_alloc())return NULL;void *p=malloc(size);if(p)InterlockedIncrement(&native_blocks);return p;}
static void *native_calloc(size_t count,size_t size){if(fail_native_alloc())return NULL;void *p=calloc(count,size);if(p)InterlockedIncrement(&native_blocks);return p;}
static void native_free(void *p){if(p){assert(InterlockedDecrement(&native_blocks)>=0);free(p);}}
static HANDLE WINAPI fixture_thread(LPSECURITY_ATTRIBUTES security,SIZE_T stack,LPTHREAD_START_ROUTINE run,LPVOID data,DWORD flags,LPDWORD id){
 if(InterlockedExchange(&fail_thread,0)){SetLastError(ERROR_NOT_ENOUGH_MEMORY);return NULL;}
 HANDLE h=CreateThread(security,stack,run,data,flags,id);own_handle(h);return h;
}
#define CreateThread fixture_thread
#define malloc native_malloc
#define calloc native_calloc
#define free native_free
#include "../../native/wtop_windows_worker.c"
#undef CreatePipe
#undef DuplicateHandle
#undef CreateFileW
#undef CreateProcessW
#undef InitializeCriticalSectionAndSpinCount
#undef DeleteCriticalSection
#undef CreateEventW
#undef CloseHandle
#undef CreateThread
#undef malloc
#undef calloc
#undef free

enum scenario {
    NORMAL, BAD_MAGIC, BAD_VERSION, EMPTY_BODY, OVERSIZE_BODY, BAD_CHECKSUM,
    BAD_SEQUENCE, BAD_FLAGS, BAD_SOURCE, BAD_RESERVED, PAST_TIME, FUTURE_TIME,
    REVERSED_TIME, ERROR_RESPONSE, EARLY_EXIT, HANG, PARTIAL_HEADER,
    CLOSED_PIPE, POLICY_CHANGE, EXPIRED_REPLY, INVALID_INPUT, LUA_OOM,
    VM_CLOSE_PENDING, NATIVE_ALLOC_FAILURE, THREAD_FAILURE, WORKER_LIMIT, SOURCE_ROUNDTRIP, SOURCE_SLOT_FAIRNESS, SOURCE_MISMATCH, SCENARIOS
};
static int selected;
static int fake_child(int argc,char **argv) {
    assert(argc==7);unsigned source=source_index(argv[6],strlen(argv[6]));assert(source<HARDWARE_SOURCES);
    HANDLE parent=(HANDLE)(uintptr_t)strtoul(argv[2],NULL,16),cancel=(HANDLE)(uintptr_t)strtoul(argv[3],NULL,16);
    HANDLE input=(HANDLE)(uintptr_t)strtoul(argv[4],NULL,16),output=(HANDLE)(uintptr_t)strtoul(argv[5],NULL,16);
    if(selected==EARLY_EXIT)return 7;
    unsigned char prefix[4];if(!child_receive(input,prefix,4))return 2;
    uint32_t size=gpu_u32(prefix);assert(size&&size<=65536);unsigned char *configuration=malloc(size);assert(configuration);
    assert(child_receive(input,configuration,size));free(configuration);
    unsigned char command[GPU_WIRE_COMMAND];char body[131072];memset(body,'v',sizeof(body));
    for(;;){
        if(WaitForSingleObject(cancel,0)!=WAIT_TIMEOUT||WaitForSingleObject(parent,0)!=WAIT_TIMEOUT)return 0;
        DWORD available=0;if(!PeekNamedPipe(input,NULL,0,NULL,&available,NULL))return 0;
        if(available<sizeof(command)){Sleep(1);continue;}
        assert(child_receive(input,command,sizeof(command)));
        if(selected==CLOSED_PIPE){CloseHandle(output);WaitForSingleObject(cancel,10000);return 0;}
        if(selected==HANG||selected==VM_CLOSE_PENDING||selected==WORKER_LIMIT||(selected==SOURCE_SLOT_FAIRNESS&&source==0)){WaitForSingleObject(cancel,10000);return 0;}
        uint64_t start=now_ns(),end=now_ns(),sequence=gpu_u64(command+8);unsigned flags=gpu_u32(command+16);
        unsigned char header[GPU_WIRE_HEADER]={0};uint32_t bytes=selected==LUA_OOM?sizeof(body):16;
        gpu_put32(header,selected==BAD_MAGIC?0:GPU_WIRE_MAGIC);
        gpu_put32(header+4,selected==BAD_VERSION?99:GPU_WIRE_VERSION);
        gpu_put32(header+8,selected==EMPTY_BODY?0:selected==OVERSIZE_BODY?GPU_WIRE_LIMIT+1:bytes);
        gpu_put32(header+12,selected==ERROR_RESPONSE?1:0);
        gpu_put64(header+16,selected==BAD_SEQUENCE?sequence+1:sequence);
        gpu_put64(header+24,selected==PAST_TIME?0:selected==FUTURE_TIME?start+UINT64_C(10000000000):start);
        gpu_put64(header+32,selected==REVERSED_TIME?start-1:selected==FUTURE_TIME?end+UINT64_C(10000000000):end);
        gpu_put32(header+40,selected==BAD_FLAGS?flags^1:flags);
        gpu_put32(header+44,gpu_checksum(body,bytes)^(selected==BAD_CHECKSUM?1u:0u));
        gpu_put32(header+48,selected==BAD_SOURCE?99:selected==SOURCE_MISMATCH?3:3+source);
        if(selected==BAD_RESERVED)header[63]=1;
        if(selected==PARTIAL_HEADER){assert(child_send(output,header,7));WaitForSingleObject(cancel,10000);return 0;}
        if(!child_send(output,header,sizeof(header))||!child_send(output,body,bytes))return 0;
    }
}
static int call_configure(lua_State *L) { lua_settop(L,0);lua_pushcfunction(L,wtop_windows_hardware_configure);return lua_pcall(L,0,1,0); }
static int call_open(lua_State *L,const char *name,size_t size,const char *configuration,size_t length) {
    lua_settop(L,0);lua_pushcfunction(L,wtop_windows_hardware_open);lua_pushlstring(L,name,size);lua_pushlstring(L,configuration,length);
    return lua_pcall(L,2,1,0);
}
static int call_query(lua_State *L,int reference,unsigned flags) {
    lua_settop(L,0);lua_pushcfunction(L,wtop_windows_hardware_query);lua_rawgeti(L,LUA_REGISTRYINDEX,reference);
    lua_pushboolean(L,flags!=0);lua_pushinteger(L,0);return lua_pcall(L,3,2,0);
}
static DWORD handles(void) {DWORD count=0;assert(GetProcessHandleCount(GetCurrentProcess(),&count));return count;}
static void drained(DWORD before) {
    DWORD started=GetTickCount();
    while(InterlockedCompareExchange(&controllers,0,0)||InterlockedCompareExchange(&native_blocks,0,0)||InterlockedCompareExchange(&owned_sections,0,0)){
        if((DWORD)(GetTickCount()-started)>=5000){printf("RESOURCE_DEBUG scenario=%d controllers=%ld handles_before=%lu handles_now=%lu native_blocks=%ld\n",selected,(long)controllers,(unsigned long)before,(unsigned long)handles(),(long)native_blocks);fflush(stdout);assert(0);}
        Sleep(5);
    }
    assert(!InterlockedCompareExchange(&native_blocks,0,0));
    for(unsigned i=0;i<HARDWARE_SOURCES;++i)assert(!InterlockedCompareExchange(&source_controllers[i],0,0));
    assert(!InterlockedCompareExchange(&owned_sections,0,0));
    for(unsigned i=0;i<128;++i)assert(!InterlockedCompareExchange(&owned_handles[i],0,0));
}
static int source_reference(lua_State *L,const char *name) {
    assert(call_configure(L)==LUA_OK);
    for(unsigned i=0;i<HARDWARE_SOURCES;++i){lua_getfield(L,-1,source_names[i]);assert(lua_toboolean(L,-1));lua_pop(L,1);}
    assert(call_open(L,name,strlen(name),"x",1)==LUA_OK);
    assert(luaL_testudata(L,-1,SESSION_META));return luaL_ref(L,LUA_REGISTRYINDEX);
}
static int session_reference(lua_State *L){return source_reference(L,"cpufreq");}
static void wait_state(struct session *session,enum state wanted) {
    DWORD started=GetTickCount();
    for(;;){struct job *job=session->job;assert(job);EnterCriticalSection(&job->mutex);enum state state=job->state;LeaveCriticalSection(&job->mutex);
        if(state==wanted)return;
        assert(state!=FAILED);assert((DWORD)(GetTickCount()-started)<5000);Sleep(2);}
}
struct allocation {size_t calls,fail;};
static void *allocator(void *opaque,void *old,size_t old_size,size_t size) {
    struct allocation *a=opaque;(void)old_size;
    if(!size){free(old);return NULL;}
    if(a->fail&&++a->calls>=a->fail)return NULL;
    return realloc(old,size);
}
static void oom_cases(void) {
    unsigned failures=0,successes=0;DWORD before=handles();
    for(size_t point=1;point<=48;++point){
        struct allocation a={0,0};lua_State *L=lua_newstate(allocator,&a,0);assert(L);int ref=session_reference(L);
        lua_rawgeti(L,LUA_REGISTRYINDEX,ref);struct session *session=lua_touserdata(L,-1);lua_pop(L,1);
        assert(call_query(L,ref,0)==LUA_OK);wait_state(session,READY);
        lua_settop(L,0);lua_pushcfunction(L,wtop_windows_hardware_query);lua_rawgeti(L,LUA_REGISTRYINDEX,ref);lua_pushboolean(L,0);lua_pushinteger(L,0);
        a.fail=point;int status=lua_pcall(L,3,2,0);a.fail=0;
        if(status==LUA_ERRMEM)++failures;else{assert(status==LUA_OK&&lua_type(L,-2)==LUA_TSTRING);++successes;}
        lua_close(L);drained(before);
    }
    assert(failures&&successes);printf("Worker OOM: %u failures and %u successes; child processes, events, pipes and frame references drained\n",failures,successes);
}
static void invalid_inputs(void) {
    lua_State *L=luaL_newstate();assert(L);
    assert(call_open(L,"cpufreq",7,"x",1)==LUA_OK&&lua_isnil(L,-1));
    assert(call_configure(L)==LUA_OK);
    assert(call_open(L,"cpufreq\0bad",11,"x",1)==LUA_ERRRUN);
    assert(call_open(L,"wrong",5,"x",1)==LUA_ERRRUN);
    assert(call_open(L,"cpufreq",7,"",0)==LUA_ERRRUN);
    char *big=calloc(65537,1);assert(big);assert(call_open(L,"cpufreq",7,big,65537)==LUA_ERRRUN);free(big);
    assert(!InterlockedCompareExchange(&controllers,0,0));lua_close(L);
}
/* Windows initializes process-launch ETW/registry caches on first use.
 * Warm them with an unrelated child, before accounting transport resources. */
static void warm_process_api(void){
 HANDLE read_pipe,write_pipe;assert(CreatePipe(&read_pipe,&write_pipe,NULL,0));CloseHandle(read_pipe);CloseHandle(write_pipe);
 WCHAR path[32768],command[32768];DWORD n=GetModuleFileNameW(NULL,path,32768);assert(n&&n<16000);
 size_t at=quote_argument(command,path);assert(at+20<32768);wcscpy(command+at,L" --fixture-noop");
 STARTUPINFOW startup;PROCESS_INFORMATION process;memset(&startup,0,sizeof(startup));startup.cb=sizeof(startup);
 SECURITY_ATTRIBUTES security={sizeof(security),NULL,TRUE};
 HANDLE null_file=CreateFileW(L"NUL",GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,0,NULL);assert(null_file!=INVALID_HANDLE_VALUE);
 startup.dwFlags=STARTF_USESTDHANDLES;startup.hStdInput=startup.hStdOutput=startup.hStdError=null_file;
 assert(CreateProcessW(path,command,NULL,NULL,TRUE,CREATE_NO_WINDOW,NULL,NULL,&startup,&process));
 CloseHandle(null_file);
 assert(WaitForSingleObject(process.hProcess,5000)==WAIT_OBJECT_0);CloseHandle(process.hThread);CloseHandle(process.hProcess);
}
static HANDLE warm_gate;
static DWORD WINAPI warm_concurrent(void *unused){
 (void)unused;assert(WaitForSingleObject(warm_gate,5000)==WAIT_OBJECT_0);
 for(unsigned i=0;i<1000;++i){void *p=malloc(1024+(i%127));assert(p);WCHAR text[128];assert(_snwprintf(text,128,L"runtime %lu %u",(unsigned long)GetCurrentThreadId(),i)>0);free(p);}
 warm_process_api();return 0;
}
static void warm_concurrent_process_api(void){
 warm_gate=CreateEventW(NULL,TRUE,FALSE,NULL);assert(warm_gate);
 HANDLE first=CreateThread(NULL,0,warm_concurrent,NULL,0,NULL),second=CreateThread(NULL,0,warm_concurrent,NULL,0,NULL);assert(first&&second);
 SetEvent(warm_gate);assert(WaitForSingleObject(first,10000)==WAIT_OBJECT_0&&WaitForSingleObject(second,10000)==WAIT_OBJECT_0);
 CloseHandle(first);CloseHandle(second);CloseHandle(warm_gate);
}
static void native_failure_cases(DWORD before){
 unsigned errors=0,successes=0;
 for(LONG point=1;point<=8;++point){
  lua_State *L=luaL_newstate();assert(L);int ref=session_reference(L);native_calls=0;native_fail_at=point;
  DWORD start=GetTickCount();
  for(;;){assert(call_query(L,ref,0)==LUA_OK);
   if(lua_type(L,-2)==LUA_TSTRING){++successes;break;}
   const char *reason=lua_tostring(L,-1);assert(reason);
   if(strcmp(reason,"hardware_query_pending")){assert(!strcmp(reason,"hardware_allocation_failed")||!strcmp(reason,"hardware_worker_unavailable"));++errors;break;}
   assert((DWORD)(GetTickCount()-start)<5000);Sleep(2);
  }
  native_fail_at=0;lua_close(L);drained(before);
 }
 assert(errors==5&&successes==3);puts("Worker native allocation: five failing sites and three complete reads drained");
}
static void one_case(void) {
    warm_process_api();
    if(selected==WORKER_LIMIT)warm_concurrent_process_api();
    printf("transport case %d: starting\n",selected);fflush(stdout);
    DWORD before=handles();
    if(selected==INVALID_INPUT){invalid_inputs();drained(before);return;}
    if(selected==SOURCE_ROUNDTRIP||selected==SOURCE_SLOT_FAIRNESS){
        lua_State *L=luaL_newstate();assert(L);int refs[4];unsigned count=selected==SOURCE_SLOT_FAIRNESS?4:3;
        for(unsigned i=0;i<count;++i){const char *name=selected==SOURCE_SLOT_FAIRNESS?source_names[i<2?0:i-1]:source_names[i];refs[i]=source_reference(L,name);assert(call_query(L,refs[i],0)==LUA_OK);}
        if(selected==SOURCE_SLOT_FAIRNESS){int extra=source_reference(L,"cpufreq");assert(call_query(L,extra,0)==LUA_OK&&lua_isnil(L,-2)&&!strcmp(lua_tostring(L,-1),"hardware_worker_busy"));}
        DWORD pids[3]={0,0,0};unsigned first=selected==SOURCE_SLOT_FAIRNESS?2:0;
        for(unsigned i=first;i<count;++i){
            lua_rawgeti(L,LUA_REGISTRYINDEX,refs[i]);struct session *slot=lua_touserdata(L,-1);lua_pop(L,1);wait_state(slot,READY);
            assert(call_query(L,refs[i],0)==LUA_OK&&lua_type(L,-2)==LUA_TSTRING);
            lua_getfield(L,-1,"worker_pid");DWORD pid=(DWORD)lua_tointeger(L,-1);lua_pop(L,1);assert(pid&&pid!=GetCurrentProcessId());
            for(unsigned previous=first;previous<i;++previous)assert(pids[previous-first]!=pid);
            pids[i-first]=pid;
        }
        lua_close(L);drained(before);return;
    }
    if(selected==SOURCE_MISMATCH){
        lua_State *L=luaL_newstate();assert(L);int ref=source_reference(L,"gpu");DWORD start=GetTickCount();
        for(;;){assert(call_query(L,ref,0)==LUA_OK&&lua_isnil(L,-2));const char *reason=lua_tostring(L,-1);assert(reason);
            if(strcmp(reason,"hardware_query_pending")){assert(!strcmp(reason,"hardware_invalid_response"));break;}
            assert((DWORD)(GetTickCount()-start)<5000);Sleep(2);}
        lua_close(L);drained(before);return;
    }
    if(selected==NATIVE_ALLOC_FAILURE){native_failure_cases(before);return;}
    if(selected==THREAD_FAILURE){
        lua_State *L=luaL_newstate();assert(L);int ref=session_reference(L);fail_thread=1;
        assert(call_query(L,ref,0)==LUA_OK&&lua_isnil(L,-2)&&!strcmp(lua_tostring(L,-1),"hardware_worker_unavailable"));
        lua_close(L);drained(before);return;
    }
    if(selected==WORKER_LIMIT){
        DWORD stable=before;
        for(unsigned round=0;round<12;++round){
            lua_State *L=luaL_newstate();assert(L);int refs[3];for(unsigned i=0;i<3;++i)refs[i]=session_reference(L);
            for(unsigned i=0;i<2;++i)assert(call_query(L,refs[i],0)==LUA_OK&&lua_isnil(L,-2));
            assert(InterlockedCompareExchange(&controllers,0,0)==2);
            assert(call_query(L,refs[2],0)==LUA_OK&&lua_isnil(L,-2)&&!strcmp(lua_tostring(L,-1),"hardware_worker_busy"));
            HANDLE child[2]={NULL,NULL};
            for(unsigned i=0;i<2;++i){
                lua_rawgeti(L,LUA_REGISTRYINDEX,refs[i]);struct session *slot=lua_touserdata(L,-1);lua_pop(L,1);
                DWORD started=GetTickCount(),pid=0;
                while(!pid){EnterCriticalSection(&slot->job->mutex);pid=slot->job->pid;LeaveCriticalSection(&slot->job->mutex);assert((DWORD)(GetTickCount()-started)<5000);if(!pid)Sleep(2);}
                child[i]=OpenProcess(SYNCHRONIZE|PROCESS_QUERY_INFORMATION,FALSE,pid);assert(child[i]);
            }
            lua_close(L);
            for(unsigned i=0;i<2;++i){assert(WaitForSingleObject(child[i],2000)==WAIT_OBJECT_0);CloseHandle(child[i]);}
            drained(before);
            DWORD after=handles();
            if(!round)stable=after;else if(after>stable)stable=after;
            printf("CONCURRENT_RESOURCE round=%u before=%lu after=%lu native_blocks=%ld\n",round,(unsigned long)before,(unsigned long)after,(long)native_blocks);fflush(stdout);
        }
        printf("CONCURRENT_RESOURCE final_peak=%lu original=%lu\n",(unsigned long)stable,(unsigned long)before);fflush(stdout);
        /* Process totals include OS/CRT caches and are an observation. Native
         * handles/critical sections/heap/slots above are strict conservation
         * checks; every child has an independently waited process handle. */
        return;
    }
    if(selected==LUA_OOM){oom_cases();return;}
    lua_State *L=luaL_newstate();assert(L);int ref=session_reference(L);
    lua_rawgeti(L,LUA_REGISTRYINDEX,ref);struct session *session=lua_touserdata(L,-1);lua_pop(L,1);
    uint64_t started=now_ns();assert(call_query(L,ref,0)==LUA_OK);assert(now_ns()-started<UINT64_C(100000000));
    if(selected==VM_CLOSE_PENDING){lua_close(L);drained(before);return;}
    int success=selected==NORMAL||selected==POLICY_CHANGE||selected==EXPIRED_REPLY;
    DWORD begin=GetTickCount();
    if(success){
        wait_state(session,READY);
        if(selected==EXPIRED_REPLY){EnterCriticalSection(&session->job->mutex);session->job->frame->started=now_ns()-FRAME_NS-1;LeaveCriticalSection(&session->job->mutex);}
        if(selected==EXPIRED_REPLY||selected==POLICY_CHANGE){assert(call_query(L,ref,selected==POLICY_CHANGE)==LUA_OK&&lua_isnil(L,-2));wait_state(session,READY);}
        assert(call_query(L,ref,selected==POLICY_CHANGE)==LUA_OK&&lua_type(L,-2)==LUA_TSTRING);
        size_t length;const char *value=lua_tolstring(L,-2,&length);assert(length==16&&value[0]=='v');
        lua_getfield(L,-1,"worker_pid");DWORD pid=(DWORD)lua_tointeger(L,-1);lua_pop(L,1);assert(pid&&pid!=GetCurrentProcessId());
        lua_getfield(L,-1,"sample_started_ns");lua_Integer start=lua_tointeger(L,-1);lua_pop(L,1);
        lua_getfield(L,-1,"sample_finished_ns");lua_Integer finish=lua_tointeger(L,-1);lua_pop(L,1);assert(start>0&&finish>=start&&(uint64_t)finish<=now_ns());
        HANDLE child=OpenProcess(SYNCHRONIZE|PROCESS_QUERY_INFORMATION,FALSE,pid);assert(child);
        lua_close(L);assert(WaitForSingleObject(child,2000)==WAIT_OBJECT_0);CloseHandle(child);drained(before);return;
    }
    for(;;){
        assert(call_query(L,ref,0)==LUA_OK&&lua_isnil(L,-2));const char *reason=lua_tostring(L,-1);assert(reason);
        if(strcmp(reason,"hardware_query_pending")){
            const char *wanted=selected==HANG||selected==PARTIAL_HEADER?"hardware_query_timeout":selected==ERROR_RESPONSE?"hardware_collector_error":selected==EARLY_EXIT||selected==CLOSED_PIPE?"hardware_worker_exited":"hardware_invalid_response";
            assert(!strcmp(reason,wanted)||(selected==EARLY_EXIT&&!strcmp(reason,"hardware_worker_unavailable")));break;
        }
        assert((DWORD)(GetTickCount()-begin)<5000);Sleep(2);
    }
    lua_close(L);drained(before);
}
int main(int argc,char **argv) {
    const char *mode=getenv("WTOP_WORKER_FIXTURE_MODE");if(mode)selected=atoi(mode);
    if(argc>1&&!strcmp(argv[1],"--fixture-noop"))return 0;
    if(argc>1&&!strcmp(argv[1],"--wtop-hardware-reader"))return fake_child(argc,argv);
    if(argc==1){
        for(unsigned i=0;i<SCENARIOS;++i){char text[24];snprintf(text,sizeof(text),"%u",i);assert(_spawnl(_P_WAIT,argv[0],argv[0],text,(char *)NULL)==0);}
        printf("Windows hardware transport: %u process/protocol/lifecycle scenarios passed\n",SCENARIOS);return 0;
    }
    assert(argc==2);selected=atoi(argv[1]);assert(selected>=0&&selected<SCENARIOS);char text[24];snprintf(text,sizeof(text),"%d",selected);assert(SetEnvironmentVariableA("WTOP_WORKER_FIXTURE_MODE",text));
    one_case();printf("transport case %d: passed\n",selected);return 0;
}
