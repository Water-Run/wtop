/* Adapter GUID/instance joins without changing registry or network state. */
#define WINVER 0x0601
#define _WIN32_WINNT 0x0601
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <lua.h>
#include <lauxlib.h>
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>
#include "../../native/wtop_windows.h"

static unsigned mode, opened, closed, destroyed, guid_reads[3], id_reads[3];
enum { DUPLICATE = 1, CONFIG_REUSED = 2, INSTANCE_REUSED = 4, BAD_GUID = 8,
    DRIVER_FAILED = 16, REGISTRY_DENIED = 32 };
static const WCHAR *guids[] = {
 L"{11111111-1111-1111-1111-111111111111}",
 L"{22222222-2222-2222-2222-222222222222}",
 L"{33333333-3333-3333-3333-333333333333}" };
static const WCHAR *instances[] = { L"PCI\\fixture", L"USB\\fixture", L"ROOT\\virtual" };
static HDEVINFO WINAPI fixture_devices(const GUID *guid, PCWSTR enumerator, HWND parent, DWORD flags) {
 (void)parent; assert(guid && !enumerator && flags == DIGCF_PRESENT); return (HDEVINFO)(uintptr_t)1;
}
static BOOL WINAPI fixture_enumerate(HDEVINFO set, DWORD index, PSP_DEVINFO_DATA device) {
 (void)set;
 if (index >= 3) { SetLastError(ERROR_NO_MORE_ITEMS); return FALSE; }
 device->DevInst = index; return TRUE;
}
static HKEY WINAPI fixture_open(HDEVINFO set, PSP_DEVINFO_DATA device, DWORD scope,
 DWORD profile, DWORD type, REGSAM access) {
 (void)set; (void)profile;
 assert(scope == DICS_FLAG_GLOBAL && type == DIREG_DRV && access == KEY_QUERY_VALUE);
 if (mode & REGISTRY_DENIED) return (HKEY)INVALID_HANDLE_VALUE;
 ++opened; return (HKEY)(uintptr_t)(device->DevInst + 100);
}
static LONG WINAPI fixture_registry(HKEY key, LPCWSTR name, LPDWORD reserved,
 LPDWORD type, LPBYTE output, LPDWORD capacity) {
 unsigned i = (unsigned)(uintptr_t)key - 100;
 const WCHAR *text = guids[i];
 (void)reserved; assert(wcscmp(name,L"NetCfgInstanceId") == 0);
 if ((mode & DUPLICATE) && i == 1) text = guids[0];
 if ((mode & CONFIG_REUSED) && i == 0 && guid_reads[i] > 0) text = guids[1];
 if ((mode & BAD_GUID) && i == 0) text = L"{not-a-guid}";
 ++guid_reads[i];
 DWORD bytes = (DWORD)((wcslen(text)+1)*sizeof(WCHAR));
 assert(*capacity >= bytes); memcpy(output,text,bytes); *capacity=bytes; *type=REG_SZ; return ERROR_SUCCESS;
}
static LONG WINAPI fixture_close(HKEY key) { (void)key; ++closed; return ERROR_SUCCESS; }
static BOOL WINAPI fixture_destroy(HDEVINFO set) { (void)set; ++destroyed; return TRUE; }
static BOOL WINAPI fixture_property(HDEVINFO set, PSP_DEVINFO_DATA device, DWORD property,
 PDWORD type, PBYTE output, DWORD capacity, PDWORD required) {
 (void)set; (void)device; (void)required;
 assert(property == SPDRP_SERVICE && capacity > 30);
 wcscpy((WCHAR *)output,L"fixture-driver"); *type=REG_SZ;
 return !(mode & DRIVER_FAILED);
}
static CONFIGRET WINAPI fixture_id(DEVINST child, PWSTR output, ULONG capacity, ULONG flags) {
 assert(child<3 && capacity==256 && flags==0);
 const WCHAR *text=instances[child];
 if ((mode & INSTANCE_REUSED) && child==0 && id_reads[child]>0) text=L"PCI\\replaced";
 ++id_reads[child]; wcscpy(output,text); return CR_SUCCESS;
}
static CONFIGRET WINAPI fixture_parent(PDEVINST parent, DEVINST child, ULONG flags) {
 (void)parent; (void)child; assert(flags==0); return CR_NO_SUCH_DEVNODE;
}
static void fixture_fill_guid(lua_State *L) { (void)L; }
#define SetupDiGetClassDevsW fixture_devices
#define SetupDiEnumDeviceInfo fixture_enumerate
#define SetupDiOpenDevRegKey fixture_open
#define SetupDiGetDeviceRegistryPropertyW fixture_property
#define SetupDiDestroyDeviceInfoList fixture_destroy
#define RegQueryValueExW fixture_registry
#define RegCloseKey fixture_close
#define wtop_fill_interface_guids fixture_fill_guid
#include "../../native/wtop_windows_hw.c"

static void collect(lua_State *L,unsigned scenario) {
 lua_settop(L,0);mode=scenario;opened=closed=destroyed=0;
 memset(guid_reads,0,sizeof(guid_reads));memset(id_reads,0,sizeof(id_reads));
 inventory_cm.resolved=1;inventory_cm.id=fixture_id;inventory_cm.parent=fixture_parent;
 lua_newtable(L);lua_newtable(L);
 for (int i=0;i<4;++i) {
  lua_newtable(L);lua_pushinteger(L,i+10);lua_setfield(L,-2,"id");
  lua_pushliteral(L,"same alias");lua_setfield(L,-2,"name");
  if (i<3) { wtop_push_utf8(L,guids[i]);lua_setfield(L,-2,"_interface_guid"); }
  lua_pushboolean(L,i<2);lua_setfield(L,-2,"hardware");
  lua_newtable(L);lua_pushinteger(L,123);lua_setfield(L,-2,"rx_bytes");lua_setfield(L,-2,"counters");
  lua_rawseti(L,-2,i+1);
 }
 lua_setfield(L,-2,"interfaces");wtop_enrich_network(L);
 assert(opened==closed && destroyed==1 && lua_gettop(L)==1);
}
static void row(lua_State *L,int n) {
 lua_getfield(L,-1,"interfaces");lua_rawgeti(L,-1,n);lua_remove(L,-2);
}
static void text(lua_State *L,const char *key,const char *expected) {
 lua_getfield(L,-1,key);assert(lua_isstring(L,-1)&&strcmp(lua_tostring(L,-1),expected)==0);lua_pop(L,1);
}
static void absent(lua_State *L,const char *key) {
 lua_getfield(L,-1,key);assert(lua_isnil(L,-1));lua_pop(L,1);
}
int main(void) {
 lua_State *L=luaL_newstate();assert(L);
 collect(L,0);absent(L,"quality");row(L,1);text(L,"_pnp_parent_bus","pci");text(L,"_pnp_parent_id","PCI\\fixture");text(L,"driver","fixture-driver");lua_pop(L,1);
 row(L,2);text(L,"_pnp_parent_bus","usb");lua_pop(L,1);
 row(L,3);text(L,"_pnp_instance_id","ROOT\\virtual");absent(L,"_pnp_parent_id");lua_pop(L,1);
 row(L,4);absent(L,"_pnp_instance_id");
 for (unsigned scenario=1;scenario<=8;scenario<<=1) {
  collect(L,scenario);text(L,"quality","partial");row(L,1);absent(L,"_pnp_parent_id");
  lua_getfield(L,-1,"counters");lua_getfield(L,-1,"rx_bytes");assert(lua_tointeger(L,-1)==123);
 }
 collect(L,DRIVER_FAILED);row(L,1);absent(L,"driver");text(L,"_pnp_parent_bus","pci");
 collect(L,REGISTRY_DENIED);text(L,"quality","partial");row(L,1);absent(L,"_pnp_parent_id");
 lua_close(L);puts("Windows adapter joins: exact GUIDs, virtual devices, duplicate/reused identities and closed keys passed");return 0;
}
