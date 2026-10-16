/* Deterministic Win32 frequency API and Lua-allocation failure fixtures. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <pdh.h>
#include <pdhmsg.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <float.h>
#include <math.h>
#include <assert.h>
#include <process.h>
enum frequency_scenario {
    BASELINE = 0,
    MULTIGROUP = 1,
    WRAPPED_GROUP = 2,
    TRAILING_NAME = 3,
    INFINITE_RATIO = 4,
    LAST_GROUP_CPU = 5,
    INVALID_GROUP = 6,
    INVALID_NUMBER = 7,
    INCOMPLETE_NAME = 8,
    NEGATIVE_GROUP = 9,
    DUPLICATE_COUNTER = 10,
    INVALID_DUPLICATE = 11,
    LEGACY_POWER = 12,
    REORDERED_POWER = 13,
    MULTIGROUP_NO_PDH = 14,
    POLICY_LIMIT = 15,
    POLICY_OVERFLOW = 16,
    OVERFLOWING_HZ = 17,
    ZERO_RATIO = 18,
    NAN_RATIO = 19,
    NULL_NAME = 20,
    COLD_QUERY = 21,
    TICK_WRAP = 22,
    COLLECT_FAILURE = 23,
    MISSING_ARRAY = 24,
    TOPOLOGY_DURING_SAMPLE = 25,
    TOPOLOGY_BETWEEN_SAMPLES = 26,
    GROUP_QUERY_FAILURE = 27,
    POWER_QUERY_FAILURE = 28,
    SCHEME_QUERY_FAILURE = 29,
    SCHEME_NAME_FAILURE = 30,
    SCHEME_NAME_OVERSIZE = 31,
    LUA_OOM = 32,
    TRANSIENT_OPEN = 33,
    MISSING_PDH_API = 34,
};

typedef struct {int state; PDH_HQUERY query; PDH_HCOUNTER counters[4]; unsigned collections;} pdh_set;
static int scenario,power_queries,open_attempts;
static unsigned opened_queries,closed_queries,collect_calls,group_calls,active_calls;
static unsigned scheme_queries,scheme_releases,schemes_alive,arrays_alive;
static void *array_pointer,*scheme_pointer;
static PDH_STATUS WINAPI fixture_close_query(PDH_HQUERY q){assert(q);++closed_queries;return ERROR_SUCCESS;}
static struct{PDH_STATUS(WINAPI *close_query)(PDH_HQUERY);}pdh={fixture_close_query};
static DWORD fixture_tick=1000;
static DWORD fixture_get_tick(void){return fixture_tick;}
static unsigned cpu_count(void){return scenario==LEGACY_POWER||scenario==MISSING_PDH_API?6:scenario==REORDERED_POWER?3:1;}
static void fixture_system(SYSTEM_INFO *s){s->dwNumberOfProcessors=cpu_count();}
static WORD WINAPI fixture_groups(void){
 ++group_calls;
 if(scenario==GROUP_QUERY_FAILURE)return 0;
 if(scenario==TOPOLOGY_DURING_SAMPLE)return group_calls<=2?1:2;
 return scenario==MULTIGROUP||scenario==MULTIGROUP_NO_PDH||scenario==COLD_QUERY||scenario==TICK_WRAP?2:scenario==LAST_GROUP_CPU?64:scenario==POLICY_LIMIT?8:scenario==POLICY_OVERFLOW?9:1;
}
static DWORD WINAPI fixture_active(WORD g){
 (void)g;++active_calls;
 return scenario==TOPOLOGY_BETWEEN_SAMPLES&&active_calls>2?2:cpu_count();
}
struct fixture_power{uint32_t number,maximum,current,limit,idle,state;};
static LONG WINAPI fixture_power_query(int level,PVOID input,ULONG input_size,PVOID output,ULONG size){
    (void)input;(void)input_size;assert(level==11);++power_queries;
    assert(size==cpu_count()*sizeof(struct fixture_power));
    struct fixture_power *p=output;unsigned order[]={2,0,1};
    for(unsigned i=0;i<cpu_count();i++){unsigned n=scenario==REORDERED_POWER?order[i]:i;p[i]=(struct fixture_power){n,3300,3000+100*n,2800,0,0};}
    return scenario==POWER_QUERY_FAILURE?-1:0;
}
static HMODULE fixture_module(const char *name){(void)name;return(void*)1;}
static HMODULE fixture_library(const char *name){(void)name;return(void*)2;}
static HLOCAL WINAPI fixture_local_free(HLOCAL p){assert(p&&p==scheme_pointer&&schemes_alive==1);free(p);scheme_pointer=NULL;--schemes_alive;++scheme_releases;return NULL;}
static DWORD WINAPI fixture_scheme(HKEY key,GUID **guid){(void)key;assert(!schemes_alive);*guid=malloc(sizeof(**guid));assert(*guid);scheme_pointer=*guid;++schemes_alive;++scheme_queries;return scenario==SCHEME_QUERY_FAILURE?ERROR_ACCESS_DENIED:ERROR_SUCCESS;}
static DWORD WINAPI fixture_friendly(HKEY key,const GUID *scheme,const GUID *sub,const GUID *setting,PUCHAR text,LPDWORD size){
 (void)key;(void)scheme;(void)sub;(void)setting;if(scenario==SCHEME_NAME_FAILURE)return ERROR_ACCESS_DENIED;
 const WCHAR *name=L"Fixture scheme";DWORD wanted=(DWORD)((wcslen(name)+1)*sizeof(WCHAR));assert(*size>=wanted);memcpy(text,name,wanted);*size=scenario==SCHEME_NAME_OVERSIZE?*size+10:wanted;return ERROR_SUCCESS;
}
static void fixture_free(void *p){if(!p)return;assert(p==array_pointer&&arrays_alive==1);free(p);array_pointer=NULL;--arrays_alive;}

static FARPROC fixture_address(HMODULE module,const char *name){
    (void)module;
    if(!strcmp(name,"PowerGetActiveScheme"))return(FARPROC)(void*)fixture_scheme;
    if(!strcmp(name,"PowerReadFriendlyName"))return(FARPROC)(void*)fixture_friendly;
    if(!strcmp(name,"CallNtPowerInformation"))return(scenario>=LEGACY_POWER&&scenario<=MULTIGROUP_NO_PDH)||scenario==POWER_QUERY_FAILURE||scenario==MISSING_PDH_API?(FARPROC)(void*)fixture_power_query:NULL;
    if(scenario==LEGACY_POWER)return NULL;
    if(!strcmp(name,"GetActiveProcessorGroupCount"))return(FARPROC)(void*)fixture_groups;
    if(!strcmp(name,"GetActiveProcessorCount"))return(FARPROC)(void*)fixture_active;
    return NULL;
}
static int pdh_ready(void){return scenario!=MISSING_PDH_API&&scenario!=LEGACY_POWER;}
static int pdh_set_open(pdh_set *s,const WCHAR *const *p,int n,int required){
 (void)p;(void)n;(void)required;if(s->state)return s->state>0;
 ++open_attempts;
 if(scenario==MISSING_PDH_API||(scenario==TRANSIENT_OPEN&&open_attempts==1)){s->state=-1;return 0;}
 if((scenario>=LEGACY_POWER&&scenario<=MULTIGROUP_NO_PDH)||scenario==POWER_QUERY_FAILURE){s->state=-1;return 0;}
 s->state=1;s->query=(PDH_HQUERY)(uintptr_t)100;++opened_queries;
 s->collections=((scenario>=COLD_QUERY&&scenario<=MISSING_ARRAY)||(scenario==COLLECT_FAILURE&&opened_queries>1)||(scenario==TOPOLOGY_DURING_SAMPLE&&opened_queries>1)||(scenario==TOPOLOGY_BETWEEN_SAMPLES&&opened_queries>1))?0:1;
 if(scenario==TRANSIENT_OPEN)s->collections=0;
 s->counters[0]=(PDH_HCOUNTER)(uintptr_t)1;s->counters[1]=(PDH_HCOUNTER)(uintptr_t)2;return 1;
}
static int pdh_set_collect(pdh_set *s){++collect_calls;if(scenario==COLLECT_FAILURE&&collect_calls==1)return 0;++s->collections;return 1;}
static PDH_FMT_COUNTERVALUE_ITEM_W *pdh_items(PDH_HCOUNTER counter,DWORD *count){
    static WCHAR names[513][40];
    if(scenario==MISSING_ARRAY&&counter==(void*)2){*count=0;return NULL;}
    *count=scenario==MULTIGROUP||scenario==DUPLICATE_COUNTER||scenario==INVALID_DUPLICATE||scenario==COLD_QUERY||scenario==TICK_WRAP||scenario==TOPOLOGY_DURING_SAMPLE||scenario==TOPOLOGY_BETWEEN_SAMPLES?2:scenario==POLICY_LIMIT?512:scenario==POLICY_OVERFLOW?513:1;
    PDH_FMT_COUNTERVALUE_ITEM_W *items=calloc(*count,sizeof(*items));assert(items&&!arrays_alive);array_pointer=items;++arrays_alive;
    for(DWORD i=0;i<*count;i++){
        unsigned g=0,n=0;
        if(scenario==MULTIGROUP||scenario==COLD_QUERY||scenario==TICK_WRAP||scenario==TOPOLOGY_DURING_SAMPLE)g=i;
        if(scenario==TOPOLOGY_BETWEEN_SAMPLES)n=i;
        if(scenario==POLICY_LIMIT||scenario==POLICY_OVERFLOW){g=i/64;n=i%64;}
        swprintf(names[i],40,L"%u,%u",g,n);
        const WCHAR *name=names[i];
        if(scenario==WRAPPED_GROUP)name=L"67108864,0";
        if(scenario==TRAILING_NAME)name=L"0,0junk";
        if(scenario==LAST_GROUP_CPU)name=L"63,63";
        if(scenario==INVALID_GROUP)name=L"64,0";
        if(scenario==INVALID_NUMBER)name=L"0,64";
        if(scenario==INCOMPLETE_NAME)name=L"0,";
        if(scenario==NEGATIVE_GROUP)name=L"-1,0";
        if(scenario==NULL_NAME)name=NULL;
        items[i].szName=(WCHAR*)name;items[i].FmtValue.CStatus=0;
        double value=counter==(void*)1?3300:125;
        if(scenario==INFINITE_RATIO&&counter==(void*)2)value=INFINITY;
        if(scenario==INVALID_DUPLICATE&&i==1&&counter==(void*)1)value=INFINITY;
        if(scenario==OVERFLOWING_HZ&&counter==(void*)1)value=1e300;
        if(scenario==ZERO_RATIO&&counter==(void*)2)value=0;
        if(scenario==NAN_RATIO&&counter==(void*)2)value=NAN;
        items[i].FmtValue.doubleValue=value;
    }
    return items;
}
static void integer_field(lua_State *L,const char *n,lua_Integer v){lua_pushinteger(L,v);lua_setfield(L,-2,n);}
static void string_field(lua_State *L,const char *n,const char *v){lua_pushstring(L,v);lua_setfield(L,-2,n);}
static void utf8_field(lua_State *L,const char *n,const WCHAR *v){
 assert(schemes_alive==0);char text[256];size_t i=0;for(;v[i]&&i<sizeof(text)-1;i++){assert(v[i]<128);text[i]=(char)v[i];}text[i]=0;lua_pushstring(L,text);lua_setfield(L,-2,n);
}
static int pdh_item_valid(const PDH_FMT_COUNTERVALUE_ITEM_W *item){return(item->FmtValue.CStatus==PDH_CSTATUS_VALID_DATA||item->FmtValue.CStatus==PDH_CSTATUS_NEW_DATA)&&item->FmtValue.doubleValue==item->FmtValue.doubleValue;}
#define GetSystemInfo fixture_system
#define GetModuleHandleA fixture_module
#define LoadLibraryA fixture_library
#define GetProcAddress fixture_address
#define LocalFree fixture_local_free
#define GetTickCount fixture_get_tick
#define free fixture_free
#include "../../native/wtop_windows_frequency.h"
#undef free

static int invoke(lua_State *L){lua_settop(L,0);lua_pushcfunction(L,l_collect_cpufreq);return lua_pcall(L,0,LUA_MULTRET,0);}
static int pending(lua_State *L){lua_getfield(L,-1,"_sampling_pending");int value=lua_toboolean(L,-1);lua_pop(L,1);return value;}
static size_t policies(lua_State *L){lua_getfield(L,-1,"policies");size_t n=lua_rawlen(L,-1);lua_pop(L,1);return n;}
static void clean(void){assert(!arrays_alive&&!schemes_alive);frequency_reset_query();assert(opened_queries==closed_queries);assert(scheme_queries==scheme_releases);}
struct allocation {size_t calls,fail;};
static void *allocator(void *opaque,void *pointer,size_t old,size_t size){
 struct allocation *a=opaque;(void)old;
 if(!size){free(pointer);return NULL;}
 if(a->fail&&++a->calls>=a->fail)return NULL;
 return realloc(pointer,size);
}
static void oom_test(void){
 unsigned failures=0,successes=0;
 for(size_t point=1;point<=180;point++){
  struct allocation a={0,0};lua_State *L=lua_newstate(allocator,&a,0);assert(L);
  lua_pushcfunction(L,l_collect_cpufreq);a.fail=point;
  int status=lua_pcall(L,0,LUA_MULTRET,0);a.fail=0;
  if(status==LUA_ERRMEM)++failures;else{assert(status==LUA_OK);++successes;}
  assert(!schemes_alive&&!arrays_alive);lua_close(L);clean();
 }
 assert(failures&&successes&&scheme_queries);printf("OOM: %u allocation failures and %u successful calls, no OS object/array leaks\n",failures,successes);
}
int main(int argc,char **argv){
 if(argc==1){
  for(unsigned i=BASELINE;i<=MISSING_PDH_API;i++){char text[16];snprintf(text,sizeof(text),"%u",i);assert(_spawnl(_P_WAIT,argv[0],argv[0],text,(char*)NULL)==0);}
  puts("Windows frequency:35 typed API scenarios, group identities, numeric bounds, warmup/wrap, query reset, topology changes and Lua OOM passed");return 0;
 }
 assert(argc==2);scenario=atoi(argv[1]);assert(scenario>=BASELINE&&scenario<=MISSING_PDH_API);
 if(scenario==TICK_WRAP)fixture_tick=UINT32_MAX-255;
 if(scenario==LUA_OOM){oom_test();return 0;}
 lua_State *L=luaL_newstate();assert(L);assert(invoke(L)==LUA_OK);
 if(scenario==TRANSIENT_OPEN){
  assert(lua_isnil(L,-2)&&open_attempts==1);
  fixture_tick+=4999;assert(invoke(L)==LUA_OK&&lua_isnil(L,-2)&&open_attempts==1);
  fixture_tick+=1;assert(invoke(L)==LUA_OK&&pending(L)&&open_attempts==2);
  fixture_tick+=999;assert(invoke(L)==LUA_OK&&pending(L)&&collect_calls==1);
  fixture_tick+=1;assert(invoke(L)==LUA_OK&&!pending(L)&&policies(L)==1&&collect_calls==2);
 }else if(scenario==MISSING_PDH_API){
  assert(policies(L)==6&&open_attempts==1);
  fixture_tick+=10000;assert(invoke(L)==LUA_OK&&policies(L)==6&&open_attempts==1);
 }else if(scenario==COLD_QUERY||scenario==TICK_WRAP){
  assert(pending(L)&&policies(L)==0&&collect_calls==1);
  fixture_tick+=500;assert(invoke(L)==LUA_OK&&pending(L)&&collect_calls==1);
  fixture_tick+=500;assert(invoke(L)==LUA_OK&&!pending(L)&&policies(L)==2&&collect_calls==2);
 }else if(scenario==COLLECT_FAILURE){
  assert(lua_isnil(L,-2)&&closed_queries==1);
  fixture_tick+=1000;assert(invoke(L)==LUA_OK&&pending(L));
  fixture_tick+=1000;assert(invoke(L)==LUA_OK&&!pending(L)&&policies(L)==1&&opened_queries==2);
 }else if(scenario==MISSING_ARRAY){
  fixture_tick+=1000;assert(invoke(L)==LUA_OK&&policies(L)==1&&closed_queries==1);
  lua_getfield(L,-1,"quality");assert(!strcmp(lua_tostring(L,-1),"partial"));lua_pop(L,1);
 }else if(scenario==TOPOLOGY_DURING_SAMPLE){
  assert(pending(L)&&policies(L)==0&&closed_queries==1);
  fixture_tick+=1000;assert(invoke(L)==LUA_OK&&pending(L));
  fixture_tick+=1000;assert(invoke(L)==LUA_OK&&!pending(L)&&policies(L)==2);
 }else if(scenario==TOPOLOGY_BETWEEN_SAMPLES){
  assert(policies(L)==2);fixture_tick+=1000;assert(invoke(L)==LUA_OK&&pending(L)&&closed_queries==1);
  fixture_tick+=1000;assert(invoke(L)==LUA_OK&&!pending(L)&&policies(L)==2);
 }else{
  int absent=scenario==WRAPPED_GROUP||scenario==TRAILING_NAME||scenario==INVALID_GROUP||scenario==INVALID_NUMBER||scenario==INCOMPLETE_NAME||scenario==NEGATIVE_GROUP||scenario==MULTIGROUP_NO_PDH||scenario==NULL_NAME||scenario==GROUP_QUERY_FAILURE||scenario==POWER_QUERY_FAILURE;
  if(absent){assert(lua_isnil(L,-2));if(scenario==MULTIGROUP_NO_PDH)assert(power_queries==0);}
  else{
   size_t count=policies(L),wanted=scenario==MULTIGROUP?2:scenario==LEGACY_POWER||scenario==MISSING_PDH_API?6:scenario==REORDERED_POWER?3:scenario==POLICY_LIMIT||scenario==POLICY_OVERFLOW?512:1;
   assert(count==wanted);lua_getfield(L,-1,"truncated");assert(lua_toboolean(L,-1)==(scenario==POLICY_OVERFLOW));lua_pop(L,1);
   lua_getfield(L,-1,"policies");
   for(size_t i=1;i<=count;i++){
    unsigned id=scenario==LAST_GROUP_CPU?4095:scenario==MULTIGROUP?(unsigned)(i-1)*64:(unsigned)i-1;
    lua_rawgeti(L,-1,(lua_Integer)i);lua_getfield(L,-1,"policy_index");assert(lua_tointeger(L,-1)==id);lua_pop(L,1);
    lua_getfield(L,-1,"processor_group");assert(lua_tointeger(L,-1)==id/64);lua_pop(L,1);
    lua_getfield(L,-1,"processor_number");assert(lua_tointeger(L,-1)==id%64);lua_pop(L,1);
    lua_getfield(L,-1,"governor");assert(scenario>=SCHEME_QUERY_FAILURE&&scenario<=SCHEME_NAME_OVERSIZE?lua_isnil(L,-1):lua_isstring(L,-1));lua_pop(L,1);
    lua_getfield(L,-1,"frequencies");lua_getfield(L,-1,"current_hz");
    int no_current=scenario==INFINITE_RATIO||scenario==DUPLICATE_COUNTER||scenario==INVALID_DUPLICATE||scenario==OVERFLOWING_HZ||scenario==ZERO_RATIO||scenario==NAN_RATIO;
    if(no_current)assert(lua_isnil(L,-1));else assert(lua_isinteger(L,-1)&&lua_tointeger(L,-1)==(scenario==LEGACY_POWER||scenario==REORDERED_POWER?(lua_Integer)(3000+100*id)*1000000:4125000000LL));
    lua_pop(L,1);
    lua_getfield(L,-1,"current_source");
    if(no_current)assert(lua_isnil(L,-1));
    else assert(!strcmp(lua_tostring(L,-1),scenario==LEGACY_POWER||scenario==REORDERED_POWER?"CallNtPowerInformation":"pdh"));
    lua_pop(L,3);
   }
   lua_pop(L,1);assert(scheme_queries==1);
  }
 }
 lua_close(L);clean();printf("case %d: passed\n",scenario);return 0;
}
