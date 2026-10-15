/* Exercise the production x86 CPU collector, without changing host state. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

enum {
    LEGACY=1,ANCIENT=2,NO_SETS=4,NO_EX=8,API_FAIL=16,SHORT_REPLY=32,LONG_REPLY=64,
    ZERO_RECORD=128,SMALL_RECORD=256,OVERSIZE=512,DUP_CPU=1024,DUP_SET=2048,
    DUP_CORE=4096,OVERLAP=8192,REORDER=16384,CHANGE_CORE=32768,CHANGE_PACKAGE=65536,
    CHANGE_SET=131072,CHANGE_COUNT=262144,CHANGE_CLASS=524288,PARK_CHANGED=1048576,
    MULTIGROUP=2097152,BIGGROUP=4194304,SPARSE=8388608,HYBRID=16777216,
    BAD_TEXT=33554432,BAD_REG_TYPE=67108864,BAD_REG_SIZE=134217728,
    CACHE_FUTURE=268435456,CACHE_LEGACY=536870912
};
#define CPUS_512 (UINT64_C(1)<<30)
#define TOO_MANY (UINT64_C(1)<<31)
#define BAD_GROUP (UINT64_C(1)<<32)
#define HUGE_GROUPS (UINT64_C(1)<<33)
#define MALLOC_FAIL (UINT64_C(1)<<34)
#define GROW_BUFFER (UINT64_C(1)<<35)
#define NEVER_STABLE (UINT64_C(1)<<36)
#define MISSING_CORE (UINT64_C(1)<<37)
#define NO_TIMES_EX (UINT64_C(1)<<38)
#define NO_TIMES_OLD (UINT64_C(1)<<39)
#define NO_SYSTEM_TIMES (UINT64_C(1)<<40)
#define TIMES_FAIL (UINT64_C(1)<<41)
#define TIMES_SHORT (UINT64_C(1)<<42)
#define TIMES_LONG (UINT64_C(1)<<43)
#define NEGATIVE_TIME (UINT64_C(1)<<44)
#define TOTAL_OVERFLOW (UINT64_C(1)<<45)
#define BAD_IRQ (UINT64_C(1)<<46)
#define FAILED_GROUP (UINT64_C(1)<<47)
#define SUM_OVERFLOW (UINT64_C(1)<<48)
#define SPLIT_PACKAGE (UINT64_C(1)<<49)
#define ZERO_ACTIVE (UINT64_C(1)<<50)
#define REG_PADDED (UINT64_C(1)<<51)
#define REG_NO_NUL (UINT64_C(1)<<52)
static uint64_t mode;
static unsigned phase, live_buffers, live_keys, total_allocations, query_calls[3];
static int fault_kind=-1, fault_phase, fail_lua, oom_after_release;
static unsigned char reply[1048576];
static unsigned sample_number;
static void put16(unsigned char *p,unsigned v){uint16_t n=(uint16_t)v;memcpy(p,&n,2);}
static void put32(unsigned char *p,unsigned v){uint32_t n=v;memcpy(p,&n,4);}
static unsigned group_number(void){return mode&HUGE_GROUPS?65:mode&TOO_MANY?9:mode&CPUS_512?8:mode&MULTIGROUP?2:1;}
static unsigned per_group(void){return mode&(BIGGROUP|CPUS_512|TOO_MANY)?64:mode&SPARSE?4:mode&LEGACY?6:8;}
static int fault(int kind){return (fault_kind<0||fault_kind==kind)&&(!fault_phase||fault_phase==(int)phase);}
static void WINAPI native_info(LPSYSTEM_INFO out){++phase;memset(out,0,sizeof(*out));out->dwNumberOfProcessors=per_group();out->dwActiveProcessorMask=0xff;}
static WORD WINAPI groups(void){return (WORD)group_number();}
static DWORD WINAPI active(WORD group){if(mode&ZERO_ACTIVE)return 0;return group==0xffff?group_number()*per_group():per_group()-((mode&CHANGE_COUNT)&&phase==2?1:0);}
static unsigned logical_index(unsigned index){return mode&SPARSE?(index<2?index:index+30):index;}
static unsigned core_index(unsigned index){return mode&LEGACY?index:index/2*2;}
static unsigned efficiency(unsigned index){return mode&HYBRID?(index>=per_group()/2?128:0):0;}
static DWORD sets_reply(void){
    DWORD offset=0;unsigned total=group_number()*per_group();
    for(unsigned k=0;k<total;++k){unsigned n=mode&REORDER?total-1-k:k,g=n/per_group(),i=n%per_group();
        unsigned char *p=reply+offset;memset(p,0,32);put32(p,32);put32(p+8,256+n);
        put16(p+12,g);p[14]=(BYTE)logical_index(i);p[15]=(BYTE)core_index(i);p[18]=(BYTE)efficiency(i);
        if(phase==2){if(mode&CHANGE_CORE)p[15]+=1;if(mode&CHANGE_SET)put32(p+8,1024+n);if(mode&CHANGE_CLASS)p[18]^=128;if(mode&PARK_CHANGED)p[19]=1;}
        if((mode&DUP_CPU)&&i==1)p[14]=0;
        if((mode&DUP_SET)&&i==1)put32(p+8,256+g*per_group());
        if(mode&BAD_GROUP)put16(p+12,group_number());
        offset+=32;
    }
    return offset;
}
static DWORD ex_record(DWORD offset,unsigned kind,unsigned group,DWORD mask,unsigned level,unsigned size){
    unsigned count=kind==3||(kind==2&&level==3)?group_number():1;
    DWORD length=(kind==2?40:32)+count*12;
    unsigned char *p=reply+offset;memset(p,0,length);put32(p,kind);put32(p+4,length);
    if(kind==2){p[8]=(BYTE)level;p[9]=8;put16(p+10,64);put32(p+12,size);put32(p+16,level==1?2:0);put16(p+38,(mode&CACHE_LEGACY)&&count==1?0:count);}
    else{p[8]=(BYTE)(kind==0&&!(mode&LEGACY));put16(p+30,count);}
    unsigned start=kind==2?40:32;
    for(unsigned n=0;n<count;++n){put32(p+start+n*12,mask);put16(p+start+n*12+4,count==1?group:n);}
    return length;
}
static DWORD ex_reply(void){
    DWORD offset=0;DWORD full=per_group()>=32?0xffffffffu:((1u<<per_group())-1);
    offset+=ex_record(offset,3,0,full,0,0);
    if(mode&SPLIT_PACKAGE){put32(reply+32,0x55);DWORD at=offset;offset+=ex_record(offset,3,0,0xaa,0,0);assert(at>0);}
    if((mode&CHANGE_PACKAGE)&&phase==2)put32(reply+32,full>>1);
    unsigned step=mode&LEGACY?1:2;
    for(unsigned g=0;g<group_number();++g)for(unsigned i=0;i<per_group();i+=step){
        DWORD mask=step==1?1u<<(i%32):3u<<(i%32);
        if((mode&OVERLAP)&&i==2)mask|=1;
        if(!(mode&MISSING_CORE)||i!=0){
            DWORD at=offset;offset+=ex_record(offset,0,g,mask,0,0);
            if((mode&DUP_CORE)&&i==0){DWORD bytes=offset-at;memcpy(reply+offset,reply+at,bytes);offset+=bytes;}
        }
        offset+=ex_record(offset,2,g,mask,1,32768);
        offset+=ex_record(offset,2,g,mask,2,262144);
    }
    offset+=ex_record(offset,2,0,full,3,8388608);
    if(mode&CACHE_FUTURE){memset(reply+offset,0,16);put32(reply+offset,99);put32(reply+offset+4,16);offset+=16;}
    if(mode&REORDER){unsigned char temp[1048576];DWORD cursor=0;
        for(DWORD end=offset;end;){DWORD start=0;while(start<end){DWORD n;memcpy(&n,reply+start+4,4);if(start+n==end)break;start+=n;}DWORD n=end-start;memcpy(temp+cursor,reply+start,n);cursor+=n;end=start;}memcpy(reply,temp,offset);}
    return offset;
}
static DWORD old_reply(void){
    SYSTEM_LOGICAL_PROCESSOR_INFORMATION entries[256];memset(entries,0,sizeof(entries));unsigned count=0;
    DWORD full=per_group()>=32?0xffffffffu:((1u<<per_group())-1);
    entries[count].Relationship=RelationProcessorPackage;entries[count++].ProcessorMask=full;
    unsigned step=mode&LEGACY?1:2;
    for(unsigned i=0;i<per_group();i+=step){
        DWORD mask=(step==1?1u:3u)<<(i%32);
        entries[count].Relationship=RelationProcessorCore;entries[count++].ProcessorMask=mask;
        entries[count].Relationship=RelationCache;entries[count].ProcessorMask=mask;entries[count].Cache.Level=1;entries[count].Cache.Size=32768;entries[count].Cache.Type=CacheData;entries[count].Cache.LineSize=64;entries[count++].Cache.Associativity=4;
    }
    memcpy(reply,entries,count*sizeof(entries[0]));return count*sizeof(entries[0]);
}
static BOOL query_reply(int kind,void *buffer,DWORD capacity,DWORD *bytes){
    ++query_calls[kind];int bad=fault(kind);
    if(bad&&(mode&API_FAIL)){SetLastError(ERROR_ACCESS_DENIED);return FALSE;}
    DWORD actual=kind==2?sets_reply():kind==1?ex_reply():old_reply();
    if(!buffer){*bytes=bad&&(mode&OVERSIZE)?1048577:mode&GROW_BUFFER?actual-8:mode&NEVER_STABLE?8:actual;SetLastError(ERROR_INSUFFICIENT_BUFFER);return FALSE;}
    if((mode&NEVER_STABLE)||capacity<actual){*bytes=mode&NEVER_STABLE?capacity+8:actual;SetLastError(ERROR_INSUFFICIENT_BUFFER);return FALSE;}
    memcpy(buffer,reply,actual);*bytes=actual;
    if(bad){
        if(mode&SHORT_REPLY)--*bytes;
        if(mode&LONG_REPLY)*bytes=capacity+1;
        if(mode&ZERO_RECORD)put32((unsigned char*)buffer+(kind==1?4:0),0);
        if(mode&SMALL_RECORD)put32((unsigned char*)buffer+(kind==1?4:0),4);
    }
    return TRUE;
}
static BOOL WINAPI old_query(void *buffer,DWORD *bytes){return query_reply(0,buffer,*bytes,bytes);}
static BOOL WINAPI ex_query(DWORD relation,void *buffer,DWORD *bytes){assert(relation==0xffff);return query_reply(1,buffer,*bytes,bytes);}
static BOOL WINAPI sets_query(void *buffer,ULONG capacity,ULONG *bytes,HANDLE process,ULONG flags){assert(!process&&!flags);return query_reply(2,buffer,capacity,bytes);}
struct fixture_time { int64_t idle,kernel,user,dpc,interrupt;ULONG count,padding; };
static LONG times_reply(unsigned group,void *buffer,ULONG capacity,ULONG *bytes){
    assert(group<group_number()&&capacity==per_group()*48);
    if((mode&TIMES_FAIL)||((mode&FAILED_GROUP)&&group==1))return (LONG)0xc0000001u;
    struct fixture_time rows[64];memset(rows,0,sizeof(rows));
    for(unsigned i=0;i<per_group();++i){
        rows[i].idle=800+sample_number*10;rows[i].kernel=1000+sample_number*20;rows[i].user=100+sample_number*10;
        rows[i].dpc=10+sample_number;rows[i].interrupt=5+sample_number;
        if((mode&NEGATIVE_TIME)&&i==1)rows[i].idle=-1;
        if(mode&TOTAL_OVERFLOW){rows[i].kernel=INT64_MAX;rows[i].user=1;}
        if(mode&SUM_OVERFLOW){rows[i].kernel=INT64_MAX/4;rows[i].user=1;}
        if((mode&BAD_IRQ)&&i==1)rows[i].dpc=INT64_MAX;
    }
    memcpy(buffer,rows,capacity);*bytes=capacity;
    if(mode&TIMES_SHORT)--*bytes;
    if(mode&TIMES_LONG)++*bytes;
    return 0;
}
static LONG WINAPI times_old(ULONG kind,void *buffer,ULONG capacity,ULONG *bytes){assert(kind==8&&group_number()==1);return times_reply(0,buffer,capacity,bytes);}
static LONG WINAPI times_ex(ULONG kind,void *input,ULONG length,void *buffer,ULONG capacity,ULONG *bytes){WORD group;assert(kind==8&&length==2);memcpy(&group,input,2);return times_reply(group,buffer,capacity,bytes);}
static BOOL WINAPI system_times(LPFILETIME idle,LPFILETIME kernel,LPFILETIME user){assert(group_number()==1);idle->dwHighDateTime=kernel->dwHighDateTime=user->dwHighDateTime=0;idle->dwLowDateTime=8000;kernel->dwLowDateTime=10000;user->dwLowDateTime=1000;return TRUE;}
static FARPROC WINAPI resolve_api(HMODULE module,LPCSTR name){
    if(module==(HMODULE)(uintptr_t)2){
        if(!strcmp(name,"NtQuerySystemInformation"))return mode&NO_TIMES_OLD?NULL:(FARPROC)(void*)times_old;
        if(!strcmp(name,"NtQuerySystemInformationEx"))return mode&(LEGACY|ANCIENT|NO_TIMES_EX)?NULL:(FARPROC)(void*)times_ex;
        assert(0);
    }
    assert(module==(HMODULE)(uintptr_t)1);
    if(!strcmp(name,"GetSystemTimes"))return mode&NO_SYSTEM_TIMES?NULL:(FARPROC)(void*)system_times;
    if(!strcmp(name,"GetNativeSystemInfo"))return mode&ANCIENT?NULL:(FARPROC)(void*)native_info;
    if(mode&ANCIENT)return NULL;
    if(!strcmp(name,"GetLogicalProcessorInformation"))return (FARPROC)(void*)old_query;
    if(!strcmp(name,"GetActiveProcessorGroupCount"))return (FARPROC)(void*)groups;
    if(!strcmp(name,"GetActiveProcessorCount"))return (FARPROC)(void*)active;
    if(!strcmp(name,"GetLogicalProcessorInformationEx"))return mode&(LEGACY|NO_EX)?NULL:(FARPROC)(void*)ex_query;
    if(!strcmp(name,"GetSystemCpuSetInformation"))return mode&(LEGACY|NO_SETS)?NULL:(FARPROC)(void*)sets_query;
    assert(0);return NULL;
}
static HMODULE WINAPI module_handle(LPCSTR name){if(!strcmp(name,"ntdll.dll"))return (HMODULE)(uintptr_t)2;assert(!strcmp(name,"kernel32.dll"));return (HMODULE)(uintptr_t)1;}
static LSTATUS WINAPI open_key(HKEY root,LPCWSTR path,DWORD options,REGSAM access,PHKEY key){
    assert(root==HKEY_LOCAL_MACHINE&&wcsstr(path,L"CentralProcessor")&&!options&&access==KEY_QUERY_VALUE);assert(!live_keys);*key=(HKEY)(uintptr_t)1;++live_keys;return ERROR_SUCCESS;
}
static LSTATUS WINAPI close_key(HKEY key){assert(key==(HKEY)(uintptr_t)1&&live_keys==1);--live_keys;return ERROR_SUCCESS;}
static LSTATUS WINAPI query_value(HKEY key,LPCWSTR name,LPDWORD reserved,LPDWORD type,LPBYTE out,LPDWORD bytes){
    assert(key==(HKEY)(uintptr_t)1&&live_keys==1&&!reserved);
    if(!wcscmp(name,L"~MHz")){assert(*bytes==4);put32(out,3000);*type=REG_DWORD;if(mode&BAD_REG_SIZE)*bytes=3;return ERROR_SUCCESS;}
    const WCHAR *text=!wcscmp(name,L"Identifier")?L"Intel64 Family 6 Model 151 Stepping 5":L" CPU 测试 ";
    *type=mode&BAD_REG_TYPE?REG_BINARY:REG_SZ;
    if(mode&BAD_TEXT){memset(out,'x',*bytes);return ERROR_SUCCESS;}
    DWORD n=(DWORD)(wcslen(text)+1)*sizeof(WCHAR);assert(n<=*bytes);memcpy(out,text,n);*bytes=mode&REG_PADDED?*bytes:mode&REG_NO_NUL?n-2:mode&BAD_REG_SIZE?n-1:n;return ERROR_SUCCESS;
}
static void *owned_malloc(size_t bytes){if(mode&MALLOC_FAIL)return NULL;void *p=malloc(bytes);if(p){++live_buffers;++total_allocations;}return p;}
static void owned_free(void *p){if(p){assert(live_buffers);--live_buffers;free(p);if(oom_after_release)fail_lua=1;}}
void wtop_push_utf8(lua_State *L,const wchar_t *source){char text[2048];int n=WideCharToMultiByte(CP_UTF8,0,source,-1,text,sizeof(text),NULL,NULL);assert(n>0);lua_pushstring(L,text);}
#define GetModuleHandleA module_handle
#define GetProcAddress resolve_api
#define GetSystemInfo native_info
#define RegOpenKeyExW open_key
#define RegCloseKey close_key
#define RegQueryValueExW query_value
#define malloc owned_malloc
#define free owned_free
#include "../../native/wtop_windows_cpu.c"
#undef malloc
#undef free

static void *allocator(void *context,void *pointer,size_t previous,size_t size){
    (void)context;(void)previous;if(!size){free(pointer);return NULL;}
    assert(!live_buffers&&!live_keys);if(fail_lua)return NULL;return realloc(pointer,size);
}
static void collect_function(lua_State *L,lua_CFunction function,uint64_t flags,int kind,int phase_number,const char *checks){
    assert(!live_buffers&&!live_keys);mode=flags;phase=0;fault_kind=kind;fault_phase=phase_number;
    ++sample_number;lua_settop(L,0);lua_pushcfunction(L,function);int status=lua_pcall(L,0,2,0);
    if(status!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));
    assert(status==LUA_OK&&!live_buffers&&!live_keys);
    lua_pushvalue(L,1);lua_setglobal(L,"data");status=luaL_dostring(L,checks);
    if(status!=LUA_OK)fprintf(stderr,"flags=%llu kind=%d phase=%d %s\n",(unsigned long long)flags,kind,phase_number,lua_tostring(L,-1));
    assert(status==LUA_OK);
}
static void collect(lua_State *L,uint64_t flags,int kind,int phase_number,const char *checks){collect_function(L,wtop_collect_cpu_info,flags,kind,phase_number,checks);}
static void usage(lua_State *L,uint64_t flags,const char *checks){collect_function(L,wtop_collect_cpu,flags,-1,0,checks);}
int main(void){
    assert(sizeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION)==24&&sizeof(WCHAR)==2);
    lua_State *L=lua_newstate(allocator,NULL,0);assert(L);luaL_openlibs(L);
    collect(L,0,-1,0,"assert(data.quality=='fresh');local t=data.topology;assert(t.threads==8 and t.physical_cores==4 and t.sockets==1 and #t.logical_cpus==8);local c=t.logical_cpus[2];assert(c.id==1 and c.processor_group==0 and c.core_key=='win:g0:c0' and c.package_id==0 and #c.thread_siblings==2 and c.threads_in_core==2);assert(#data.caches==9 and #data.cache_summary==3);assert(data.identity.model_name=='CPU 测试' and data.identity.model==151 and data.identity.nominal_frequency_hz==3000000000);cache_id=data.caches[1].id");
    collect(L,REORDER,-1,0,"assert(data.quality=='fresh' and data.caches[1].id==cache_id and data.identity.heterogeneous==nil and data.core_types[1].source=='GetSystemCpuSetInformation')");
    collect(L,PARK_CHANGED,-1,0,"assert(data.quality=='fresh' and data.topology.logical_cpus[1].parked and data.topology.logical_cpus[1].online)");
    collect(L,LEGACY,-1,0,"assert(data.quality=='fresh' and data.topology.threads==6 and data.topology.physical_cores==6 and #data.caches==6);assert(data.topology.logical_cpus[6].core_id==5 and data.topology.logical_cpus[6].core_id_method=='lowest_logical_cpu')");
    collect(L,ANCIENT,-1,0,"assert(data.quality=='partial' and data.topology.threads==8 and #data.topology.logical_cpus==0 and data.topology.source=='GetSystemInfo')");
    collect(L,NO_SETS,-1,0,"assert(data.quality=='fresh' and #data.topology.logical_cpus==8 and data.topology.logical_cpus[2].cpu_set_id==nil)");
    collect(L,NO_EX,-1,0,"assert(data.quality=='fresh' and #data.topology.logical_cpus==8)");
    collect(L,MULTIGROUP,-1,0,"assert(data.quality=='fresh' and data.topology.processor_groups==2 and data.topology.threads==16);local c=data.topology.logical_cpus[9];assert(c.id==64 and c.processor_group==1 and c.logical_processor_index==0 and c.core_key=='win:g1:c0' and c.package_id==0)");
    collect(L,BIGGROUP,-1,0,"assert(data.quality=='partial' and data.topology.threads==64 and data.topology.physical_cores==32 and #data.topology.logical_cpus==64);assert(data.topology.logical_cpus[40].core_id_known and not data.topology.logical_cpus[40].package_id_known);assert(#data.caches==0 and #data.cache_summary==3)");
    collect(L,SPARSE,-1,0,"assert(data.quality=='partial' and data.topology.logical_cpus[3].id==32 and data.topology.logical_cpus[3].core_id_known and not data.topology.logical_cpus[3].package_id_known)");
    collect(L,HYBRID,-1,0,"assert(data.identity.heterogeneous and #data.core_types==2 and data.core_types[2].efficiency_class==128 and data.core_types[2].logical_cpu_count==4)");
    const uint64_t changes[]={CHANGE_CORE,CHANGE_SET,CHANGE_COUNT,CHANGE_CLASS,CHANGE_PACKAGE};
    for(unsigned i=0;i<sizeof(changes)/sizeof(changes[0]);++i)collect(L,changes[i],-1,0,"assert(data.quality=='partial' and #data.topology.logical_cpus==0 and #data.caches==0)");
    const uint64_t faults[]={API_FAIL,SHORT_REPLY,LONG_REPLY,ZERO_RECORD,SMALL_RECORD,OVERSIZE};
    for(unsigned kind=1;kind<=2;++kind)for(unsigned stage=1;stage<=2;++stage)for(unsigned i=0;i<sizeof(faults)/sizeof(faults[0]);++i)
        collect(L,faults[i],(int)kind,(int)stage,"assert(data.quality=='partial')");
    for(unsigned stage=1;stage<=2;++stage)for(unsigned i=0;i<sizeof(faults)/sizeof(faults[0]);++i)
        collect(L,LEGACY|faults[i],0,(int)stage,"assert(data.quality=='partial')");
    collect(L,DUP_CPU,-1,0,"assert(data.quality=='partial' and #data.topology.logical_cpus==8 and data.topology.logical_cpus[1].cpu_set_id==nil)");
    collect(L,DUP_SET,-1,0,"assert(data.quality=='partial' and data.topology.logical_cpus[1].cpu_set_id==nil)");
    collect(L,DUP_CORE,-1,0,"assert(data.quality=='partial' and #data.caches==0)");
    collect(L,OVERLAP,-1,0,"assert(data.quality=='partial' and data.topology.logical_cpus[1].core_id_known==false and data.core_types[1].physical_core_count==nil)");
    collect(L,MISSING_CORE,-1,0,"assert(data.quality=='partial' and data.topology.physical_cores==nil)");
    collect(L,SPLIT_PACKAGE,-1,0,"assert(data.quality=='partial' and data.topology.logical_cpus[1].core_id_known and not data.topology.logical_cpus[1].package_id_known)");
    collect(L,SPLIT_PACKAGE|NO_SETS,-1,0,"assert(data.quality=='partial' and not data.topology.logical_cpus[1].core_id_known and not data.topology.logical_cpus[1].package_id_known)");
    collect(L,BAD_GROUP,-1,0,"assert(data.quality=='partial' and data.topology.logical_cpus[1].cpu_set_id==nil)");
    collect(L,HUGE_GROUPS,-1,0,"assert(data.truncated and #data.topology.logical_cpus==0 and data.topology.source=='GetActiveProcessorCount')");
    collect(L,ZERO_ACTIVE,-1,0,"assert(data.quality=='partial' and data.identity.model_name and data.topology.threads==nil and #data.topology.logical_cpus==0)");
    collect(L,BAD_TEXT,-1,0,"assert(data.identity.model_name==nil and data.identity.family==nil)");
    collect(L,BAD_REG_TYPE,-1,0,"assert(data.identity.model_name==nil)");
    collect(L,BAD_REG_SIZE,-1,0,"assert(data.identity.model_name==nil and data.identity.nominal_frequency_hz==nil)");
    collect(L,REG_PADDED,-1,0,"assert(data.identity.model_name=='CPU 测试' and data.identity.model==151)");
    collect(L,REG_NO_NUL,-1,0,"assert(data.identity.model_name=='CPU 测试' and data.identity.model==151)");
    collect(L,CACHE_LEGACY,-1,0,"assert(data.quality=='fresh' and #data.caches==9)");
    collect(L,CACHE_FUTURE,-1,0,"assert(data.quality=='fresh' and #data.caches==9)");
    collect(L,GROW_BUFFER,-1,0,"assert(data.quality=='fresh' and #data.caches==9)");
    collect(L,NEVER_STABLE,-1,0,"assert(data.quality=='partial' and #data.topology.logical_cpus==0)");
    collect(L,MALLOC_FAIL,-1,0,"assert(data.quality=='partial' and #data.topology.logical_cpus==0)");
    collect(L,CPUS_512,-1,0,"assert(data.truncated==false and #data.topology.logical_cpus==512 and data.topology.logical_cpus[512].id==511)");
    collect(L,TOO_MANY,-1,0,"assert(data.truncated and #data.topology.logical_cpus==0)");
    for(unsigned i=0;i<20;++i)collect(L,0,-1,0,"assert(data.quality=='fresh')");
    usage(L,0,"assert(not data.partial and data.counter_bits==64 and data.counter_source=='NtQuerySystemInformationEx' and data.counter_scope=='system' and #data.cores==8);assert(data.cores[2].id==1 and data.cores[2].raw.system and data.cores[2].raw.irq and data.raw.busy>0);epoch=data._source_epoch;instance=data.cores[1]._source_instance");
    usage(L,REORDER,"assert(not data.partial and data._source_epoch==epoch and data.cores[1]._source_instance==instance)");
    usage(L,LEGACY|NO_SYSTEM_TIMES,"assert(not data.partial and data.counter_source=='NtQuerySystemInformation' and #data.cores==6 and data.cores[6].id==5)");
    usage(L,MULTIGROUP,"assert(not data.partial and #data.cores==16 and data.cores[9].id==64 and data.cores[9].processor_group==1 and data.raw.total>0)");
    usage(L,BIGGROUP,"assert(not data.partial and #data.cores==64 and data.cores[64].id==63 and data.cores[64].raw.total>0)");
    usage(L,CPUS_512,"assert(not data.partial and #data.cores==512 and data.cores[512].id==511)");
    usage(L,MULTIGROUP|FAILED_GROUP,"assert(data.partial and #data.cores==16 and data.raw.busy==nil and data.cores[1].raw.busy>0 and data.cores[9].raw.busy==nil)");
    usage(L,MULTIGROUP|NO_TIMES_EX,"assert(data==nil)");
    usage(L,SPARSE,"assert(data.partial and data.raw.busy>0 and #data.cores==4 and data.cores[1].raw.busy==nil and data.cores[3].id==32)");
    usage(L,TIMES_FAIL,"assert(data.partial and data.counter_source=='GetSystemTimes' and data.raw.total==11000 and #data.cores==8 and data.cores[1].raw.busy==nil)");
    usage(L,TIMES_SHORT,"assert(data.partial and data.counter_source=='GetSystemTimes')");
    usage(L,TIMES_LONG|NO_SYSTEM_TIMES,"assert(data==nil)");
    usage(L,API_FAIL,"assert(data.partial and data.raw.total>0 and #data.cores==8 and data.cores[1].identity_quality=='partial')");
    usage(L,MALLOC_FAIL,"assert(data.partial and data.raw.total>0 and #data.cores==8)");
    usage(L,NEGATIVE_TIME,"assert(data.partial and data.raw.busy==nil and #data.cores==8 and data.cores[1].raw.busy and data.cores[2].raw.busy==nil)");
    usage(L,TOTAL_OVERFLOW,"assert(data.partial and data.raw.total==nil and data.cores[1].raw.total==nil)");
    usage(L,SUM_OVERFLOW,"assert(data.partial and data.raw.total==nil and data.cores[1].raw.total>0)");
    usage(L,BAD_IRQ,"assert(data.partial and data.raw.total>0 and data.cores[2].raw.system==nil and data.cores[2].raw.irq==nil)");
    usage(L,CHANGE_SET,"assert(data.partial and #data.cores==0 and data.raw.total==nil)");
    usage(L,CHANGE_COUNT,"assert(data.partial and #data.cores==0 and data.raw.total==nil)");
    usage(L,0,"assert(not data.partial);epoch=data._source_epoch;instance=data.cores[1]._source_instance");
    usage(L,NO_TIMES_EX,"assert(not data.partial and data._source_epoch~=epoch and data.cores[1]._source_instance~=instance);epoch=data._source_epoch");
    usage(L,0,"assert(not data.partial and data._source_epoch~=epoch)");
    assert(total_allocations>100);lua_close(L);
    const lua_CFunction functions[]={wtop_collect_cpu_info,wtop_collect_cpu};
    for(unsigned i=0;i<2;++i){
        L=lua_newstate(allocator,NULL,0);assert(L);mode=0;phase=0;fault_kind=-1;fault_phase=0;
        lua_pushcfunction(L,functions[i]);oom_after_release=1;
        assert(lua_pcall(L,0,1,0)==LUA_ERRMEM&&!live_buffers&&!live_keys);
        fail_lua=oom_after_release=0;lua_close(L);
    }
    puts("Windows CPU: CPU Sets/GLPIEx/legacy, groups/WOW64, shared caches, grouped NT times/XP fallback, counter errors/overflow, changing identities, bounds, owned buffers/registry and Lua OOM passed");return 0;
}
