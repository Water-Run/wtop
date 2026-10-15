/* Real worker process/lifetime/OOM tests plus malformed packet checks. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
enum { REAL, CREATE_FAIL, INVALID, OVERSIZE, TIMEOUT, INSTRUCTION_FAULT, THREAD_FAIL, FORCE_X86 };
static unsigned mode;
static unsigned roster_version;
static volatile LONG live_allocations, allocation_budget=-1;
static WCHAR temp_paths[256][MAX_PATH+1];
static volatile LONG temp_count;
static void WINAPI fixture_native_info(LPSYSTEM_INFO info) {
    memset(info,0,sizeof(*info));info->wProcessorArchitecture=PROCESSOR_ARCHITECTURE_INTEL;
}
static FARPROC WINAPI fixture_export(HMODULE module,LPCSTR name) {
    if(mode==FORCE_X86&&!strcmp(name,"GetNativeSystemInfo"))return (FARPROC)(void *)fixture_native_info;
    return GetProcAddress(module,name);
}
static int allow_allocation(void) {
    LONG budget=InterlockedCompareExchange(&allocation_budget,0,0);
    if(budget<0)return 1;
    if(!budget)return 0;
    InterlockedDecrement(&allocation_budget);return 1;
}
static void *fixture_malloc(size_t size) {
    if(!allow_allocation())return NULL;
    void *pointer=malloc(size);if(pointer)InterlockedIncrement(&live_allocations);return pointer;
}
static void *fixture_calloc(size_t n,size_t size) {
    if(!allow_allocation())return NULL;
    void *pointer=calloc(n,size);if(pointer)InterlockedIncrement(&live_allocations);return pointer;
}
static void fixture_free(void *pointer) {
    if(pointer)InterlockedDecrement(&live_allocations);
    free(pointer);
}
static UINT WINAPI fixture_temp(LPCWSTR root,LPCWSTR prefix,UINT unique,LPWSTR path) {
    UINT result=GetTempFileNameW(root,prefix,unique,path);
    if(result){LONG slot=InterlockedIncrement(&temp_count)-1;assert(slot<256);wcscpy(temp_paths[slot],path);}
    return result;
}
static BOOL WINAPI fixture_process(LPCWSTR app,LPWSTR command,LPSECURITY_ATTRIBUTES process_security,
    LPSECURITY_ATTRIBUTES thread_security,BOOL inherit,DWORD flags,LPVOID environment,LPCWSTR directory,
    LPSTARTUPINFOW startup,LPPROCESS_INFORMATION process) {
    if(mode==CREATE_FAIL){SetLastError(ERROR_ACCESS_DENIED);return FALSE;}
    WCHAR self[MAX_PATH+1],replacement[MAX_PATH+64];
    if(mode!=REAL&&mode!=FORCE_X86){assert(GetModuleFileNameW(NULL,self,MAX_PATH));
        _snwprintf(replacement,MAX_PATH+64,L"\"%ls\" --fault %u",self,mode);app=self;command=replacement;}
    return CreateProcessW(app,command,process_security,thread_security,inherit,flags,environment,directory,startup,process);
}
static HANDLE WINAPI fixture_thread(LPSECURITY_ATTRIBUTES security,SIZE_T stack,LPTHREAD_START_ROUTINE start,
    LPVOID arg,DWORD flags,LPDWORD id) {
    if(mode==THREAD_FAIL){SetLastError(ERROR_NOT_ENOUGH_MEMORY);return NULL;}
    return CreateThread(security,stack,start,arg,flags,id);
}
#define GetTempFileNameW fixture_temp
#define CreateProcessW fixture_process
#define CreateThread fixture_thread
#define GetProcAddress fixture_export
#define malloc fixture_malloc
#define calloc fixture_calloc
#define free fixture_free
#include "../../native/wtop_windows_cpuid.c"
#undef GetTempFileNameW
#undef CreateProcessW
#undef CreateThread
#undef GetProcAddress
#undef malloc
#undef calloc
#undef free

static void idle(void) {
    DWORD start=GetTickCount();
    while(InterlockedCompareExchange(&cpuid_workers,0,0)){
        assert((DWORD)(GetTickCount()-start)<6000);Sleep(2);
    }
    Sleep(20); /* allow the worker's final FreeLibraryAndExitThread */
    for(LONG i=0;i<InterlockedCompareExchange(&temp_count,0,0);++i)
        assert(GetFileAttributesW(temp_paths[i])==INVALID_FILE_ATTRIBUTES);
    assert(!InterlockedCompareExchange(&live_allocations,0,0));
}
static void request(lua_State *L,unsigned id) {
    lua_settop(L,0);lua_pushcfunction(L,wtop_collect_cpuid);lua_newtable(L);lua_newtable(L);
    lua_pushinteger(L,id);lua_setfield(L,-2,"id");
    lua_pushinteger(L,id/64);lua_setfield(L,-2,"processor_group");
    lua_pushinteger(L,id%64);lua_setfield(L,-2,"logical_processor_index");lua_rawseti(L,-2,1);
    lua_rawgeti(L,-1,1);lua_pushinteger(L,roster_version);lua_setfield(L,-2,"cpu_set_id");lua_pop(L,1);
}
static const char *field(lua_State *L,const char *name) {
    lua_getfield(L,-1,name);const char *value=lua_tostring(L,-1);lua_pop(L,1);return value;
}
static void completed(lua_State *L,const char *expected) {
    DWORD start=GetTickCount();
    for(;;){request(L,0);DWORD before=GetTickCount();assert(lua_pcall(L,1,1,0)==LUA_OK);
        assert((DWORD)(GetTickCount()-before)<350 && "parent API blocked");
        const char *status=field(L,"status");assert(status);
        if(strcmp(status,"pending")){assert(!strcmp(status,expected));break;}
        assert((DWORD)(GetTickCount()-start)<6000);Sleep(5);
    }
}
static void packet_checks(void) {
    struct cpuid_job job;memset(&job,0,sizeof(job));job.count=1;job.bits=64;
    unsigned char bytes[32+48+24];memset(bytes,0,sizeof(bytes));
    struct wtop_cpuid_header *head=(struct wtop_cpuid_header *)bytes;
    struct wtop_cpuid_cpu *cpu=(struct wtop_cpuid_cpu *)(bytes+32);
    head->magic=WTOP_CPUID_MAGIC;head->version=1;head->bytes=sizeof(bytes);head->cpus=1;head->architecture_bits=64;
    cpu->count=1;cpu->flags=WTOP_CPUID_FLAG_CPUID|WTOP_CPUID_FLAG_RESTORED;
    head->checksum=wtop_cpuid_checksum(bytes+32,sizeof(bytes)-32);job.data=bytes;job.size=sizeof(bytes);
    assert(valid_packet(&job));
    head->bytes--;assert(!valid_packet(&job));head->bytes++;
    head->checksum^=1;assert(!valid_packet(&job));head->checksum^=1;
    head->architecture_bits=32;assert(!valid_packet(&job));head->architecture_bits=64;
    head->reserved=1;assert(!valid_packet(&job));head->reserved=0;
    cpu->id=1;head->checksum=wtop_cpuid_checksum(bytes+32,sizeof(bytes)-32);assert(!valid_packet(&job));cpu->id=0;
    cpu->flags=WTOP_CPUID_FLAG_CPUID;head->checksum=wtop_cpuid_checksum(bytes+32,sizeof(bytes)-32);assert(!valid_packet(&job));
    cpu->flags|=WTOP_CPUID_FLAG_RESTORED;cpu->count=97;
    head->checksum=wtop_cpuid_checksum(bytes+32,sizeof(bytes)-32);assert(!valid_packet(&job));
}
struct allocation_policy {lua_Alloc original;void *opaque;long budget;};
static void *allocation(void *opaque,void *pointer,size_t old,size_t size) {
    struct allocation_policy *policy=opaque;
    if(size&&(!pointer||size>old)&&policy->budget>=0){if(!policy->budget)return NULL;--policy->budget;}
    return policy->original(policy->opaque,pointer,old,size);
}
int main(int argc,char **argv) {
    if(argc==3&&!strcmp(argv[1],"--fault")){
        unsigned fault=(unsigned)strtoul(argv[2],NULL,10);SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX);
        if(fault==TIMEOUT){Sleep(10000);return 0;}
        if(fault==INSTRUCTION_FAULT){RaiseException(EXCEPTION_ILLEGAL_INSTRUCTION,EXCEPTION_NONCONTINUABLE,0,NULL);return 1;}
        unsigned char bytes[4096];memset(bytes,0xa5,sizeof(bytes));DWORD written;
        unsigned chunks=fault==OVERSIZE?600:1;
        for(unsigned i=0;i<chunks;++i)if(!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),bytes,sizeof(bytes),&written,NULL))break;
        return 0;
    }
    packet_checks();
    DWORD handles_before,handles_after;assert(GetProcessHandleCount(GetCurrentProcess(),&handles_before));
    DWORD_PTR allowed,system;assert(GetProcessAffinityMask(GetCurrentProcess(),&allowed,&system)&&allowed&1);
    DWORD_PTR original=SetThreadAffinityMask(GetCurrentThread(),1);assert(original);
    lua_State *L=luaL_newstate();assert(L);mode=REAL;completed(L,"ok");
    lua_getfield(L,-1,"raw");size_t length;const char *raw=lua_tolstring(L,-1,&length);
    assert(raw&&length>32+48);struct wtop_cpuid_header head;memcpy(&head,raw,sizeof(head));assert(head.architecture_bits==worker_bits());
    struct cpuid_context *context=context_for(L);struct cpuid_job *cached=context->job;
    completed(L,"ok");assert(context->job==cached && "successful capture was not cached");
    for(long budget=0;budget<30;++budget){
        request(L,0);struct allocation_policy policy;
        policy.original=lua_getallocf(L,&policy.opaque);policy.budget=budget;
        lua_setallocf(L,allocation,&policy);int code=lua_pcall(L,1,1,0);
        lua_setallocf(L,policy.original,policy.opaque);assert(code==LUA_OK||code==LUA_ERRMEM);
        assert(context->job==cached && "OOM discarded the rooted capture");
    }
    assert(SetThreadAffinityMask(GetCurrentThread(),1)==1);assert(SetThreadAffinityMask(GetCurrentThread(),original));
    lua_close(L);idle();
    mode=FORCE_X86;L=luaL_newstate();assert(L);completed(L,"ok");
    lua_getfield(L,-1,"architecture_bits");assert(lua_tointeger(L,-1)==32);lua_close(L);idle();
    for(mode=CREATE_FAIL;mode<=THREAD_FAIL;++mode){
        L=luaL_newstate();assert(L);
        if(mode==THREAD_FAIL){request(L,0);assert(lua_pcall(L,1,1,0)==LUA_OK&&lua_isnil(L,-1));}
        else {completed(L,"error");assert(field(L,"reason"));lua_getfield(L,-1,"error_code");
            lua_Integer error=lua_tointeger(L,-1);
            if(mode==INSTRUCTION_FAULT)assert(error==ERROR_INVALID_DATA||error==ERROR_TIMEOUT);
            else assert(error==(mode==CREATE_FAIL?ERROR_ACCESS_DENIED:mode==TIMEOUT?ERROR_TIMEOUT:ERROR_INVALID_DATA));
            lua_pop(L,1);}
        lua_close(L);idle();
    }
    /* First calls may initialize process-lifetime CRT/Windows resources.
     * Measure steady state after warming both success and failure paths. */
    assert(GetProcessHandleCount(GetCurrentProcess(),&handles_before));
    mode=TIMEOUT;L=luaL_newstate();assert(L);request(L,0);assert(lua_pcall(L,1,1,0)==LUA_OK);
    /* A changed roster cancels old work; no packet is attributed to new CPUs. */
    request(L,1);assert(lua_pcall(L,1,1,0)==LUA_OK);assert(!strcmp(field(L,"status"),"gap"));
    roster_version=1;request(L,0);assert(lua_pcall(L,1,1,0)==LUA_OK);assert(!strcmp(field(L,"status"),"gap"));roster_version=0;
    DWORD before=GetTickCount();lua_close(L);assert((DWORD)(GetTickCount()-before)<200);idle();
    /* Two independent VMs own independent jobs. Closing a VM never waits for
     * its child, and a third VM hits bounded process-wide backpressure. */
    lua_State *a=luaL_newstate(),*b=luaL_newstate(),*c=luaL_newstate();assert(a&&b&&c);
    request(a,0);assert(lua_pcall(a,1,1,0)==LUA_OK);request(b,0);assert(lua_pcall(b,1,1,0)==LUA_OK);
    request(c,0);assert(lua_pcall(c,1,1,0)==LUA_OK&&lua_isnil(c,-1));
    lua_close(c);lua_close(a);lua_close(b);idle();
    mode=REAL;
    for(long budget=0;budget<80;++budget){
        L=luaL_newstate();assert(L);request(L,0);
        struct allocation_policy policy;policy.original=lua_getallocf(L,&policy.opaque);policy.budget=budget;
        lua_setallocf(L,allocation,&policy);int code=lua_pcall(L,1,1,0);
        lua_setallocf(L,policy.original,policy.opaque);assert(code==LUA_OK||code==LUA_ERRMEM);
        lua_close(L);idle();
    }
    for(LONG budget=0;budget<3;++budget){
        L=luaL_newstate();assert(L);InterlockedExchange(&allocation_budget,budget);
        if(!budget){request(L,0);assert(lua_pcall(L,1,1,0)==LUA_OK&&lua_isnil(L,-1));}
        else completed(L,"error");
        lua_close(L);idle();InterlockedExchange(&allocation_budget,-1);
    }
    assert(GetProcessHandleCount(GetCurrentProcess(),&handles_after));assert(handles_after<=handles_before);
    puts("Windows CPUID: native x86/x64 workers, cache, parent affinity, faults/oversize/timeout, cancellation, two VMs, 80 first-call/30 cached Lua/3 heap OOM budgets and handle/temp/heap cleanup passed");
    return 0;
}
