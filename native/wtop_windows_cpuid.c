/* Isolated CPUID reader for the x86 host module. The worker can be native
 * x64, so WOW64 affinity masks do not lose processors 32..63. Lua allocations
 * happen outside worker resources. A VM closing cancels its work without
 * waiting for a thread; the worker owns its references and pins this DLL. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <wchar.h>
#include "wtop_cpuid_protocol.h"
#include "wtop_cpuid_helpers.h"
#include "wtop_windows_spawn.h"
#define CPUID_META "wtop.cpuid.session.v1"
#define CPUID_CACHE_MS 60000u
#define CPUID_RETRY_MS 5000u
#define CPUID_DEADLINE_MS 3500u
struct cpuid_job {
    volatile LONG refs,done,cancelled;
    HMODULE module;
    struct wtop_cpuid_target targets[WTOP_CPUID_CPUS];
    uint64_t roster;
    unsigned count,bits;
    DWORD started,finished,error;
    uint32_t size;unsigned char *data;
    const char *reason;
};
struct cpuid_context { struct cpuid_job *job; };
static char cpuid_registry_key;
static volatile LONG cpuid_workers;
typedef void (WINAPI *native_info_fn)(LPSYSTEM_INFO);
static void release_job(struct cpuid_job *job) {
    if(job&&InterlockedDecrement(&job->refs)==0){free(job->data);free(job);}
}
static int close_context(lua_State *L) {
    struct cpuid_context *context=luaL_testudata(L,1,CPUID_META);
    if(context&&context->job){InterlockedExchange(&context->job->cancelled,1);release_job(context->job);context->job=NULL;}
    return 0;
}
static struct cpuid_context *context_for(lua_State *L) {
    lua_rawgetp(L,LUA_REGISTRYINDEX,&cpuid_registry_key);
    struct cpuid_context *context=lua_touserdata(L,-1);
    if(context){lua_pop(L,1);return context;}
    lua_pop(L,1);context=lua_newuserdatauv(L,sizeof(*context),0);context->job=NULL;
    luaL_newmetatable(L,CPUID_META);lua_pushcfunction(L,close_context);lua_setfield(L,-2,"__gc");lua_setmetatable(L,-2);
    lua_rawsetp(L,LUA_REGISTRYINDEX,&cpuid_registry_key);return context;
}
static int valid_packet(const struct cpuid_job *job) {
    if(job->size<sizeof(struct wtop_cpuid_header))return 0;
    struct wtop_cpuid_header head;memcpy(&head,job->data,sizeof(head));
    if(head.magic!=WTOP_CPUID_MAGIC||head.version!=WTOP_CPUID_VERSION||head.bytes!=job->size
        ||head.cpus!=job->count||head.architecture_bits!=job->bits||head.reserved||head.flags>1
        ||head.checksum!=wtop_cpuid_checksum(job->data+sizeof(head),job->size-(uint32_t)sizeof(head)))return 0;
    uint32_t offset=sizeof(head);unsigned partial=0;
    for(unsigned i=0;i<head.cpus;++i) {
        if(offset>job->size||job->size-offset<sizeof(struct wtop_cpuid_cpu))return 0;
        struct wtop_cpuid_cpu cpu;memcpy(&cpu,job->data+offset,sizeof(cpu));offset+=(uint32_t)sizeof(cpu);
        if(cpu.id!=job->targets[i].id||cpu.group!=job->targets[i].group||cpu.index!=job->targets[i].index
            ||cpu.count>WTOP_CPUID_LEAVES||cpu.status>WTOP_CPUID_STATUS_BAD_RANGE||cpu.flags>255
            ||cpu.count>(job->size-offset)/sizeof(struct wtop_cpuid_leaf))return 0;
        if(cpu.status==WTOP_CPUID_STATUS_OK&&((cpu.flags&(WTOP_CPUID_FLAG_CPUID|WTOP_CPUID_FLAG_RESTORED))!=(WTOP_CPUID_FLAG_CPUID|WTOP_CPUID_FLAG_RESTORED)))return 0;
        partial|=cpu.status!=0||(cpu.flags&WTOP_CPUID_FLAG_TRUNCATED)!=0;
        offset+=cpu.count*(uint32_t)sizeof(struct wtop_cpuid_leaf);
    }
    return offset==job->size&&head.flags==partial;
}
static int keep_running(struct cpuid_job *job) {
    return !InterlockedCompareExchange(&job->cancelled,0,0)&&(DWORD)(GetTickCount()-job->started)<CPUID_DEADLINE_MS;
}
static DWORD WINAPI cpuid_worker(void *opaque) {
    struct cpuid_job *job=opaque;
    HANDLE reader=NULL,writer=NULL,guard=NULL,file=INVALID_HANDLE_VALUE;
    PROCESS_INFORMATION process;memset(&process,0,sizeof(process));
    WCHAR temp[MAX_PATH+1],path[MAX_PATH+1],*command=NULL;
    path[0]=0;
    const unsigned char *image=job->bits==64?wtop_cpuid_x64:wtop_cpuid_x86;
    DWORD image_size=(DWORD)(job->bits==64?sizeof(wtop_cpuid_x64):sizeof(wtop_cpuid_x86));
    job->reason="cpuid_helper_failed";
    DWORD length=GetTempPathW(MAX_PATH,temp);
    if(!length||length>=MAX_PATH||!GetTempFileNameW(temp,L"wtc",0,path))goto finish;
    file=CreateFileW(path,GENERIC_WRITE,0,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_TEMPORARY,NULL);
    if(file==INVALID_HANDLE_VALUE)goto finish;
    DWORD written=0;
    if(!WriteFile(file,image,image_size,&written,NULL)||written!=image_size)goto finish;
    CloseHandle(file);file=INVALID_HANDLE_VALUE;
    SECURITY_ATTRIBUTES security={sizeof(security),NULL,TRUE};
    if(!CreatePipe(&reader,&writer,&security,65536)||!SetHandleInformation(reader,HANDLE_FLAG_INHERIT,0)
        ||!DuplicateHandle(GetCurrentProcess(),GetCurrentProcess(),GetCurrentProcess(),&guard,SYNCHRONIZE,TRUE,0))goto finish;
    size_t hex_length=job->count*sizeof(struct wtop_cpuid_target)*2;
    size_t capacity=wcslen(path)+hex_length+64;
    command=calloc(capacity,sizeof(WCHAR));if(!command){job->reason="cpuid_allocation_failed";goto finish;}
    int prefix=_snwprintf(command,capacity,L"\"%ls\" %lx ",path,(unsigned long)(uintptr_t)guard);
    if(prefix<0||(size_t)prefix>=capacity)goto finish;
    static const WCHAR digits[]=L"0123456789abcdef";
    const unsigned char *bytes=(const unsigned char *)job->targets;
    for(size_t i=0;i<hex_length/2;++i){command[prefix+i*2]=digits[bytes[i]>>4];command[prefix+i*2+1]=digits[bytes[i]&15];}
    STARTUPINFOW startup;memset(&startup,0,sizeof(startup));startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESTDHANDLES;
    startup.hStdInput=NULL;startup.hStdOutput=writer;startup.hStdError=writer;
    if(!keep_running(job)){job->reason="cpuid_probe_timeout";goto finish;}
    HANDLE inherited[]={guard,writer};
    if(!wtop_spawn_reader(path,command,&startup,inherited,2,&process))goto finish;
    CloseHandle(process.hThread);process.hThread=NULL;
    CloseHandle(writer);writer=NULL;CloseHandle(guard);guard=NULL;free(command);command=NULL;
    job->data=malloc(WTOP_CPUID_BYTES);if(!job->data){job->reason="cpuid_allocation_failed";goto finish;}
    for(;;) {
        if(!keep_running(job)){job->reason="cpuid_probe_timeout";goto finish;}
        DWORD available=0;
        BOOL pipe_ok=PeekNamedPipe(reader,NULL,0,NULL,&available,NULL);
        DWORD pipe_error=pipe_ok?0:GetLastError();
        if(pipe_ok&&available) {
            if(available>WTOP_CPUID_BYTES-job->size){job->reason="cpuid_invalid_response";goto finish;}
            DWORD count=0;
            if(!ReadFile(reader,job->data+job->size,available,&count,NULL)||!count)goto finish;
            job->size+=count;continue;
        }
        if(WaitForSingleObject(process.hProcess,0)==WAIT_OBJECT_0) {
            DWORD code=1;
            if(GetExitCodeProcess(process.hProcess,&code)&&code==0&&valid_packet(job))job->reason=NULL;
            else job->reason="cpuid_invalid_response";
            break;
        }
        if(!pipe_ok&&pipe_error!=ERROR_BROKEN_PIPE){SetLastError(pipe_error);goto finish;}
        Sleep(1);
    }
finish:
    job->error=0;
    if(job->reason){
        if(!strcmp(job->reason,"cpuid_probe_timeout"))job->error=ERROR_TIMEOUT;
        else if(!strcmp(job->reason,"cpuid_invalid_response"))job->error=ERROR_INVALID_DATA;
        else if(!strcmp(job->reason,"cpuid_allocation_failed"))job->error=ERROR_NOT_ENOUGH_MEMORY;
        else job->error=GetLastError();
    }
    if(process.hProcess){if(WaitForSingleObject(process.hProcess,0)==WAIT_TIMEOUT){TerminateProcess(process.hProcess,1);WaitForSingleObject(process.hProcess,100);}CloseHandle(process.hProcess);}
    if(process.hThread)CloseHandle(process.hThread);
    if(reader)CloseHandle(reader);
    if(writer)CloseHandle(writer);
    if(guard)CloseHandle(guard);
    if(file!=INVALID_HANDLE_VALUE)CloseHandle(file);
    if(path[0])DeleteFileW(path);
    free(command);
    job->finished=GetTickCount();HMODULE module=job->module;
    InterlockedExchange(&job->done,1);InterlockedDecrement(&cpuid_workers);release_job(job);
    if(module)FreeLibraryAndExitThread(module,0);
    return 0;
}
static int same_targets(const struct cpuid_job *job,const struct wtop_cpuid_target *targets,unsigned count,unsigned bits,uint64_t roster) {
    return job&&job->count==count&&job->bits==bits&&job->roster==roster&&!memcmp(job->targets,targets,count*sizeof(*targets));
}
static uint64_t fingerprint(uint64_t hash,const void *bytes,size_t length) {
    const unsigned char *data=bytes;
    for(size_t i=0;i<length;++i)hash=(hash^data[i])*UINT64_C(1099511628211);
    return hash;
}
static uint64_t target_roster(lua_State *L,int row,uint64_t hash) {
    static const char *fields[]={"cpu_set_id","core_id","core_key","package_id","core_id_known",
        "package_id_known","efficiency_class","source","core_source","package_source"};
    row=lua_absindex(L,row);
    for(unsigned i=0;i<sizeof(fields)/sizeof(fields[0]);++i){
        lua_getfield(L,row,fields[i]);int type=lua_type(L,-1);hash=fingerprint(hash,&type,sizeof(type));
        if(type==LUA_TSTRING){size_t n;const char *s=lua_tolstring(L,-1,&n);
            if(n>128)luaL_error(L,"invalid CPUID roster metadata");
            hash=fingerprint(hash,&n,sizeof(n));hash=fingerprint(hash,s,n);
        } else if(type==LUA_TNUMBER){lua_Integer value=luaL_checkinteger(L,-1);hash=fingerprint(hash,&value,sizeof(value));}
        else if(type==LUA_TBOOLEAN){int value=lua_toboolean(L,-1);hash=fingerprint(hash,&value,sizeof(value));}
        else if(type!=LUA_TNIL)luaL_error(L,"invalid CPUID roster metadata");
        lua_pop(L,1);
    }
    return hash;
}
static unsigned worker_bits(void) {
    HMODULE kernel=GetModuleHandleA("kernel32.dll");native_info_fn info=(native_info_fn)(void *)GetProcAddress(kernel,"GetNativeSystemInfo");
    SYSTEM_INFO system;memset(&system,0,sizeof(system));if(info)info(&system);else GetSystemInfo(&system);
    return system.wProcessorArchitecture==PROCESSOR_ARCHITECTURE_AMD64?64:system.wProcessorArchitecture==PROCESSOR_ARCHITECTURE_INTEL?32:0;
}
static void text_field(lua_State *L,const char *name,const char *value) {lua_pushstring(L,value);lua_setfield(L,-2,name);}
static void int_field(lua_State *L,const char *name,lua_Integer value) {lua_pushinteger(L,value);lua_setfield(L,-2,name);}
int wtop_collect_cpuid(lua_State *L) {
    luaL_checktype(L,1,LUA_TTABLE);size_t length=lua_rawlen(L,1);
    if(!length||length>WTOP_CPUID_CPUS){lua_pushnil(L);lua_pushliteral(L,"cpuid_invalid_targets");return 2;}
    struct wtop_cpuid_target targets[WTOP_CPUID_CPUS];memset(targets,0,sizeof(targets));
    uint64_t roster=UINT64_C(14695981039346656037);
    for(size_t i=0;i<length;++i) {
        lua_rawgeti(L,1,(lua_Integer)i+1);luaL_checktype(L,-1,LUA_TTABLE);
        roster=target_roster(L,-1,roster);
        lua_getfield(L,-1,"id");lua_Integer id=luaL_checkinteger(L,-1);lua_pop(L,1);
        lua_getfield(L,-1,"processor_group");lua_Integer group=luaL_checkinteger(L,-1);lua_pop(L,1);
        lua_getfield(L,-1,"logical_processor_index");lua_Integer index=luaL_checkinteger(L,-1);lua_pop(L,2);
        if(group<0||group>=64||index<0||index>=64||id!=group*64+index)return luaL_error(L,"invalid CPUID target identity");
        for(size_t j=0;j<i;++j)if(targets[j].id==(uint32_t)id)return luaL_error(L,"duplicate CPUID target identity");
        targets[i].id=(uint32_t)id;targets[i].group=(uint16_t)group;targets[i].index=(uint16_t)index;
    }
    struct cpuid_context *context=context_for(L);unsigned bits=worker_bits();
    if(!bits){lua_pushnil(L);lua_pushliteral(L,"cpuid_unsupported_architecture");return 2;}
    struct cpuid_job *job=context->job;
    if(job&&(!same_targets(job,targets,(unsigned)length,bits,roster)
        ||(InterlockedCompareExchange(&job->done,0,0)&&(DWORD)(GetTickCount()-job->finished)>=(job->reason?CPUID_RETRY_MS:CPUID_CACHE_MS)))) {
        if(!InterlockedCompareExchange(&job->done,0,0))InterlockedExchange(&job->cancelled,1);
        /* Keep an unfinished worker referenced instead of creating unbounded
         * replacements while a slow filesystem or loader is stuck. */
        if(InterlockedCompareExchange(&job->done,0,0)){release_job(job);context->job=NULL;job=NULL;}
    }
    if(!job) {
        HMODULE self=NULL;
        if(!GetModuleHandleExW(4,(LPCWSTR)(uintptr_t)&wtop_collect_cpuid,&self)){lua_pushnil(L);lua_pushliteral(L,"cpuid_helper_failed");return 2;}
        if(InterlockedIncrement(&cpuid_workers)>2){InterlockedDecrement(&cpuid_workers);FreeLibrary(self);lua_pushnil(L);lua_pushliteral(L,"cpuid_probe_busy");return 2;}
        job=calloc(1,sizeof(*job));if(!job){InterlockedDecrement(&cpuid_workers);FreeLibrary(self);lua_pushnil(L);lua_pushliteral(L,"cpuid_allocation_failed");return 2;}
        job->refs=2;job->module=self;job->count=(unsigned)length;job->bits=bits;job->roster=roster;job->started=GetTickCount();memcpy(job->targets,targets,length*sizeof(*targets));
        HANDLE thread=CreateThread(NULL,0,cpuid_worker,job,0,NULL);
        if(!thread){InterlockedDecrement(&cpuid_workers);FreeLibrary(self);free(job);lua_pushnil(L);lua_pushliteral(L,"cpuid_helper_failed");return 2;}
        context->job=job;
        WaitForSingleObject(thread,100);CloseHandle(thread);
    }
    lua_createtable(L,0,6);text_field(L,"source",bits==64?"native-x64 CPUID worker":"native-x86 CPUID worker");
    int_field(L,"architecture_bits",bits);
    int done=InterlockedCompareExchange(&job->done,0,0)!=0;
    int matches=same_targets(job,targets,(unsigned)length,bits,roster);
    if(!matches){text_field(L,"status","gap");text_field(L,"reason","cpuid_roster_changed");}
    else if(!done){
        int expired=(DWORD)(GetTickCount()-job->started)>=CPUID_DEADLINE_MS;
        text_field(L,"status",expired?"error":"pending");
        text_field(L,"reason",expired?"cpuid_probe_timeout":"cpuid_probe_pending");
        if(expired)int_field(L,"error_code",ERROR_TIMEOUT);
    }
    else if(job->reason){text_field(L,"status","error");text_field(L,"reason",job->reason);int_field(L,"error_code",job->error);}
    else {text_field(L,"status","ok");lua_pushlstring(L,(const char *)job->data,job->size);lua_setfield(L,-2,"raw");int_field(L,"age_ms",(DWORD)(GetTickCount()-job->finished));}
    return 1;
}
