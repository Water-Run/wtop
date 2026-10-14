/* Modern MIB ownership and XP adapter-index fallback through the real code. */
#define WINVER 0x0600
#define _WIN32_WINNT 0x0600
#define NTDDI_VERSION 0x06000000
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <lua.h>
#include <lauxlib.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include "../../native/wtop_windows.h"
static struct { ULONG count; MIB_IF_ROW2 rows[2]; } mib;
static unsigned releases, mode;
static int fail_allocations, fail_after_table;
enum { DUPLICATE_INDEX=1, BAD_POINTER=2, CYCLE=4 };
static const char *guid1="{11111111-1111-1111-1111-111111111111}";
static const char *guid2="{22222222-2222-2222-2222-222222222222}";
static DWORD WINAPI table2(PMIB_IF_TABLE2 *output) {
 *output=(PMIB_IF_TABLE2)&mib;
 if(fail_after_table)fail_allocations=1;
 return NO_ERROR;
}
static VOID WINAPI release_table(PVOID table) {
 assert(table==&mib);++releases;fail_allocations=0;
}
static DWORD WINAPI adapter_info(PIP_ADAPTER_INFO output,PULONG bytes) {
 ULONG needed=2*sizeof(IP_ADAPTER_INFO);
 if (!output) { *bytes=needed;return ERROR_BUFFER_OVERFLOW; }
 assert(*bytes>=needed);memset(output,0,needed);
 output[0].Index=10;strcpy(output[0].AdapterName,guid1);output[0].Next=&output[1];
 output[1].Index=(mode&DUPLICATE_INDEX)?10:11;strcpy(output[1].AdapterName,guid2);
 if (mode&BAD_POINTER) output[1].Next=(IP_ADAPTER_INFO *)((BYTE *)output+needed+8);
 if (mode&CYCLE) output[1].Next=output;
 *bytes=needed;return NO_ERROR;
}
static FARPROC WINAPI fixture_export(HMODULE module,LPCSTR name) {
 (void)module;
 if (!strcmp(name,"GetIfTable2"))return(FARPROC)(void *)table2;
 if (!strcmp(name,"FreeMibTable"))return(FARPROC)(void *)release_table;
 if (!strcmp(name,"GetAdaptersInfo"))return(FARPROC)(void *)adapter_info;
 return NULL;
}
static void fixture_enrich(lua_State *L) { (void)L; }
#define GetProcAddress fixture_export
#define wtop_enrich_network fixture_enrich
#include "../../native/wtop_windows_net.c"
static void text(lua_State *L,const char *key,const char *expected) {
 lua_getfield(L,-1,key);assert(lua_isstring(L,-1)&&!strcmp(lua_tostring(L,-1),expected));lua_pop(L,1);
}
static void absent(lua_State *L,const char *key) {
 lua_getfield(L,-1,key);assert(lua_isnil(L,-1));lua_pop(L,1);
}
static void make_rows(lua_State *L) {
 lua_settop(L,0);lua_newtable(L);lua_newtable(L);
 for(int i=0;i<2;++i){lua_newtable(L);lua_pushinteger(L,10+i);lua_setfield(L,-2,"id");lua_rawseti(L,-2,i+1);}
 lua_setfield(L,-2,"interfaces");
}
static void row(lua_State *L,int n) {
 lua_getfield(L,-1,"interfaces");lua_rawgeti(L,-1,n);lua_remove(L,-2);
}
typedef struct {lua_Alloc allocate;void *userdata;} allocation_policy;
static void *allocate(void *context,void *pointer,size_t old,size_t size) {
 allocation_policy *policy=context;
 if(fail_allocations&&size)return NULL;
 return policy->allocate(policy->userdata,pointer,old,size);
}
int main(void) {
 lua_State *L=luaL_newstate();assert(L);
 make_rows(L);wtop_fill_interface_guids(L);assert(lua_gettop(L)==1);
 row(L,1);text(L,"_interface_guid",guid1);lua_pop(L,1);row(L,2);text(L,"_interface_guid",guid2);
 mode=DUPLICATE_INDEX;make_rows(L);wtop_fill_interface_guids(L);row(L,1);absent(L,"_interface_guid");
 for(unsigned flag=BAD_POINTER;flag<=CYCLE;flag<<=1){mode=flag;make_rows(L);wtop_fill_interface_guids(L);text(L,"quality","partial");row(L,1);absent(L,"_interface_guid");}
 memset(&mib,0,sizeof(mib));mib.count=2;
 for(int i=0;i<2;++i){mib.rows[i].InterfaceIndex=10+i;mib.rows[i].InterfaceAndOperStatusFlags.HardwareInterface=1;mib.rows[i].OperStatus=IfOperStatusUp;mib.rows[i].InOctets=42;}
 mib.rows[0].InterfaceGuid.Data1=0x11111111;mib.rows[0].InterfaceGuid.Data2=mib.rows[0].InterfaceGuid.Data3=0x1111;memset(mib.rows[0].InterfaceGuid.Data4,0x11,8);
 for(int i=0;i<200;++i)mib.rows[0].Alias[i]=0x4e2d;
 for(size_t i=0;i<sizeof(mib.rows[1].Description)/sizeof(WCHAR);++i)mib.rows[1].Description[i]=L'A';
 lua_settop(L,0);releases=0;assert(wtop_push_if_table2(L)==1&&lua_gettop(L)==1&&releases==1);
 row(L,1);text(L,"_interface_guid",guid1);lua_getfield(L,-1,"name");assert(lua_rawlen(L,-1)==600);lua_pop(L,2);
 row(L,2);lua_getfield(L,-1,"description");assert(lua_rawlen(L,-1)==256);lua_pop(L,2);
 lua_settop(L,0);lua_pushcfunction(L,wtop_push_if_table2);
 allocation_policy policy;policy.allocate=lua_getallocf(L,&policy.userdata);
 releases=0;fail_after_table=1;lua_setallocf(L,allocate,&policy);
 int status=lua_pcall(L,0,1,0);lua_setallocf(L,policy.allocate,policy.userdata);
 assert(status==LUA_ERRMEM&&releases==1);fail_after_table=0;
 lua_close(L);puts("Windows network tables: GUID fallback, bounds, Unicode and MIB release passed");return 0;
}
