#define _GNU_SOURCE
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
static void *fixture_open(const char *, int);
static int fixture_close(void *);
#define dlopen fixture_open
#define dlclose fixture_close
#include "../../native/wtop_nvml.c"
#undef dlopen
#undef dlclose
#define NVML_NO_UNVERSIONED_FUNC_DEFS
#ifdef WTOP_NVML_SDK_HEADER
#include WTOP_NVML_SDK_HEADER
#else
#include "../fixtures/nvml/sdk.h"
#endif
#define LAYOUT(a,b) _Static_assert(sizeof(a) == sizeof(b), "size: " #b); _Static_assert(_Alignof(a) == _Alignof(b), "alignment: " #b)
#define FIELD(a,b,x,y) _Static_assert(offsetof(a,x) == offsetof(b,y), "offset: " #b "." #y)
#include <stddef.h>
LAYOUT(nvml_pci_info,nvmlPciInfo_t); FIELD(nvml_pci_info,nvmlPciInfo_t,bus_id,busId);
FIELD(nvml_pci_info,nvmlPciInfo_t,pci_device_id,pciDeviceId);
LAYOUT(nvml_memory,nvmlMemory_t); FIELD(nvml_memory,nvmlMemory_t,used,used);
LAYOUT(nvml_utilization,nvmlUtilization_t);
LAYOUT(nvml_process,nvmlProcessInfo_t); FIELD(nvml_process,nvmlProcessInfo_t,used_gpu_memory,usedGpuMemory);
FIELD(nvml_process,nvmlProcessInfo_t,gpu_instance_id,gpuInstanceId);
FIELD(nvml_process,nvmlProcessInfo_t,compute_instance_id,computeInstanceId);
LAYOUT(nvml_process_v1,nvmlProcessInfo_v1_t); FIELD(nvml_process_v1,nvmlProcessInfo_v1_t,used_gpu_memory,usedGpuMemory);
LAYOUT(nvml_process_sample,nvmlProcessUtilizationSample_t); FIELD(nvml_process_sample,nvmlProcessUtilizationSample_t,timestamp,timeStamp);
FIELD(nvml_process_sample,nvmlProcessUtilizationSample_t,sm,smUtil);
FIELD(nvml_process_sample,nvmlProcessUtilizationSample_t,decoder,decUtil);
LAYOUT(nvml_field_value,nvmlValue_t); LAYOUT(nvml_field,nvmlFieldValue_t);
FIELD(nvml_field,nvmlFieldValue_t,scope,scopeId); FIELD(nvml_field,nvmlFieldValue_t,timestamp,timestamp);
FIELD(nvml_field,nvmlFieldValue_t,type,valueType); FIELD(nvml_field,nvmlFieldValue_t,status,nvmlReturn);
FIELD(nvml_field,nvmlFieldValue_t,value,value);
_Static_assert(sizeof(nvmlReturn_t) == 4 && sizeof(nvmlClockType_t) == 4 && sizeof(nvmlPstates_t) == 4, "NVML enum ABI");
_Static_assert(sizeof(nvmlPcieUtilCounter_t) == 4 && NVML_PCIE_UTIL_TX_BYTES == 0
    && NVML_PCIE_UTIL_RX_BYTES == 1, "NVML PCIe enum ABI");

static int loads, unloads, absent, allocations_left = -1;
static void *fixture_open(const char *name, int flags) {
    assert(strcmp(name,"libnvidia-ml.so.1") == 0);
    if (absent) return NULL;
    void *lib = dlopen(name,flags); if (lib) loads++; return lib;
}
static int fixture_close(void *lib) { unloads++; return dlclose(lib); }
static void *allocate(void *unused, void *ptr, size_t old, size_t size) {
    (void)unused;
    if (!size) { free(ptr); return NULL; }
    if (size > old && allocations_left >= 0) { if (!allocations_left) return NULL; allocations_left--; }
    return realloc(ptr,size);
}
static lua_State *new_vm(void) { lua_State *L = lua_newstate(allocate,NULL,0); assert(L); return L; }
static int call(lua_State *L, int processes) {
    lua_settop(L,0); lua_pushcfunction(L,wtop_nvml_query); lua_pushboolean(L,processes);
    return lua_pcall(L,1,LUA_MULTRET,0);
}
static void text_is(lua_State *L, const char *key, const char *expected) {
    lua_getfield(L,-1,key); const char *got=lua_tostring(L,-1);
    if (!got || strcmp(got,expected)) fprintf(stderr,"%s: expected %s, got %s\n",key,expected,got ? got : "nil");
    assert(got && !strcmp(got,expected)); lua_pop(L,1);
}
static void number_is(lua_State *L, const char *key, double expected) {
    lua_getfield(L,-1,key); assert(lua_isnumber(L,-1));
    if (fabs(lua_tonumber(L,-1)-expected) >= 0.000001) fprintf(stderr,"%s: expected %.6f, got %.6f\n",key,expected,lua_tonumber(L,-1));
    assert(fabs(lua_tonumber(L,-1)-expected) < 0.000001); lua_pop(L,1);
}
static void missing(lua_State *L, const char *key) { lua_getfield(L,-1,key); assert(lua_isnil(L,-1)); lua_pop(L,1); }
int main(int argc, char **argv) {
    assert(argc==2); int variant=atoi(argv[1]);
    void *sdk=dlopen("libnvidia-ml.so.1",RTLD_NOW|RTLD_LOCAL); assert(sdk);
    void (*reset)(int)=(void (*)(int))dlsym(sdk,"fixture_reset");
    void (*mode)(int)=(void (*)(int))dlsym(sdk,"fixture_mode");
    int (*refs)(void)=(int (*)(void))dlsym(sdk,"fixture_refs");
    int (*inits)(void)=(int (*)(void))dlsym(sdk,"fixture_inits");
    int (*shutdowns)(void)=(int (*)(void))dlsym(sdk,"fixture_shutdowns");
    int (*legacy)(void)=(int (*)(void))dlsym(sdk,"fixture_legacy");
    unsigned long long (*cursor)(int)=(unsigned long long (*)(int))dlsym(sdk,"fixture_cursor");
    assert(reset && mode && refs && inits && shutdowns && legacy && cursor);
    for (int scenario=0;scenario<44;++scenario) {
        reset(scenario); lua_State *L=new_vm(); assert(call(L,1)==LUA_OK);
        if (variant==3) {
            assert(lua_isnil(L,1) && !strcmp(lua_tostring(L,2),"nvml_symbols_missing"));
            assert(!inits() && !refs()); lua_close(L); assert(loads==unloads); continue;
        }
        if (scenario==1 || scenario==2 || scenario==3 || scenario==34) {
            assert(lua_isnil(L,1) && lua_isstring(L,2));
            mode(0); assert(call(L,1)==LUA_OK && lua_istable(L,1));
            lua_close(L); assert(!refs() && loads==unloads); continue;
        }
        assert(lua_istable(L,1) && refs()==1 && inits()==1 && shutdowns()==0);
        text_is(L,"status",(scenario==4 || scenario==5 || (scenario==26 && variant!=2) || (scenario==31 && variant!=2) || scenario==32) ? "partial" : "ok");
        lua_getfield(L,1,"devices");
        assert(lua_rawlen(L,2)==(size_t)((scenario==4 || (scenario==31 && variant!=2)) ? 1 : 2));
        lua_rawgeti(L,2,1);
        if (variant==2) { missing(L,"name"); missing(L,"power_watts"); goto close_vm; }
        if (scenario==33) { missing(L,"power_watts"); missing(L,"name"); goto close_vm; }
        if (scenario==6) { missing(L,"name"); missing(L,"uuid"); missing(L,"pci_bdf"); }
        else if (scenario==38 || (scenario==39 && variant!=1)) missing(L,"pci_bdf");
        else if (scenario!=4 && scenario!=31) text_is(L,"pci_bdf",scenario==30 ? "abcd:04:1a.3" : "abcd:03:1a.3");
        if (scenario==7) {
            for (size_t k=0;k<7;++k) missing(L,((const char *[]) {"power_watts","power_limit_watts","temperature_celsius","utilization_percent","fan_speed_percent","graphics_clock_hz","performance_state"})[k]);
            goto close_vm;
        }
        if (scenario==37) missing(L,"power_watts");
        else {
            double power= scenario==8 ? 0 : variant==1 || scenario==17 || scenario==18 || scenario==19 ? 123.456 : scenario==16 || scenario==40 ? 42.25 : 300;
            number_is(L,"power_watts",power);
            text_is(L,"power_measurement",variant==1 || scenario==17 || scenario==18 || scenario==19 ? "device_sample" : scenario==16 || scenario==40 ? "average" : "current");
        }
        if (scenario!=37) text_is(L,"power_quality", variant==1 ? "fresh" : scenario==41 ? "stale" : scenario==42 || scenario==43 ? "gap" : "fresh");
        number_is(L,"power_limit_watts",355.5);
        if (variant==0 || variant==4) {
            number_is(L,"pcie_current_generation",3); number_is(L,"pcie_maximum_generation",4);
            number_is(L,"pcie_current_width",8); number_is(L,"pcie_maximum_width",16);
            number_is(L,"pcie_tx_kilobytes_per_second",scenario==8?0:12345);
            number_is(L,"pcie_rx_kilobytes_per_second",scenario==8?0:6789);
            number_is(L,"pcie_throughput_interval_ns",20000000);
        } else missing(L,"pcie_tx_kilobytes_per_second");
        number_is(L,"graphics_clock_hz",scenario==8 ? 0 : 2510000000.0);
        lua_getfield(L,3,"clock_events");
        if (scenario==12) { number_is(L,"status_code",4); if (variant==0) assert(!legacy()); }
        else {
            number_is(L,"status_code",0);
            text_is(L,"raw_hex",scenario==9 ? "0x0000000000000000" : scenario==10 ? "0x0000000000000044" : scenario==11 ? "0x8000000000000004" : scenario==15 ? "0xffffffffffffffff" : "0x0000000000000004");
            text_is(L,"source",variant==1 || variant==4 || scenario==13 ? "nvmlDeviceGetCurrentClocksThrottleReasons" : "nvmlDeviceGetCurrentClocksEventReasons");
        }
        lua_pop(L,1); lua_getfield(L,3,"processes");
        if (scenario==26 || scenario==27) assert(lua_rawlen(L,-1)==0);
        else {
            lua_rawgeti(L,-1,1); number_is(L,"pid",4242);
            if (scenario==36) missing(L,"memory_bytes");
            else number_is(L,"memory_bytes",scenario==28 && variant!=1 ? 3.0*1073741824 : 1073741824.0);
            if (scenario==28 && variant!=1) {
                text_is(L,"memory_quality","estimated"); text_is(L,"memory_scope","largest_reported_context");
                lua_getfield(L,-1,"memory_contexts"); assert(lua_rawlen(L,-1)==2); lua_pop(L,1);
            }
            if (scenario==35) missing(L,"sm_percent"); else { number_is(L,"sm_percent",10); text_is(L,"sample_window","driver_buffer"); }
        }
close_vm:
        lua_close(L); assert(refs()==0 && loads==unloads && shutdowns()==1);
    }
    if (variant!=3) {
        if (variant==0 || variant==4) for (int scenario=60;scenario<=64;++scenario) {
            reset(scenario);lua_State *extra=new_vm();assert(call(extra,0)==LUA_OK);
            lua_getfield(extra,1,"devices");lua_rawgeti(extra,-1,1);
            if (scenario==60 || scenario==62) {
                missing(extra,"pcie_tx_kilobytes_per_second");missing(extra,"pcie_rx_kilobytes_per_second");
                missing(extra,"pcie_throughput_interval_ns");
            } else {
                if (scenario==63) missing(extra,"pcie_tx_kilobytes_per_second");
                else number_is(extra,"pcie_tx_kilobytes_per_second",scenario==61?0:4294967294.0);
                number_is(extra,"pcie_rx_kilobytes_per_second",scenario==61?0:scenario==64?4294967294.0:6789);
            }
            if (scenario==61) number_is(extra,"pcie_current_width",0);
            if (scenario==62) {missing(extra,"pcie_current_generation");missing(extra,"pcie_current_width");}
            lua_close(extra);assert(!refs() && loads==unloads);
        }
        reset(0); lua_State *L=new_vm(); absent=1;
        assert(call(L,1)==LUA_OK && lua_isnil(L,1)); absent=0;
        assert(call(L,1)==LUA_OK && lua_istable(L,1));
        if (variant!=2) {
            assert(cursor(0)==0 && cursor(1)==0);
            mode(30); assert(call(L,1)==LUA_OK);
            assert(cursor(0)==200 && cursor(1)==1200); /* UUID, not old index. */
        }
        lua_State *other=new_vm(); assert(call(other,0)==LUA_OK && refs()==2);
        lua_close(other); assert(refs()==1); lua_close(L); assert(!refs() && loads==unloads);
        int errors=0,successes=0;
        for (int budget=0;budget<350;++budget) {
            reset(0); L=new_vm(); allocations_left=budget;
            int status=call(L,1); allocations_left=-1;
            if (status==LUA_ERRMEM) errors++; else { assert(status==LUA_OK); successes++; }
            /* A failed metatable setup must be repairable on the same VM. */
            assert(call(L,1)==LUA_OK); lua_close(L); assert(!refs() && loads==unloads);
        }
        assert(errors && successes);
        reset(0); L=new_vm(); assert(call(L,1)==LUA_OK);
        nvml_api *api=nvml_context(L);
        sample_cursor before[NVML_MAX_DEVICES]; memcpy(before,api->cursors,sizeof(before));
        for (int budget=0;budget<100;++budget) {
            allocations_left=budget; int status=call(L,1); allocations_left=-1;
            if (status==LUA_ERRMEM) assert(memcmp(before,api->cursors,sizeof(before))==0);
            else { assert(status==LUA_OK); memcpy(before,api->cursors,sizeof(before)); }
            lua_settop(L,0); lua_gc(L,LUA_GCCOLLECT);
        }
        lua_close(L); assert(!refs() && loads==unloads);
    }
    dlclose(sdk);
    printf("ok: native NVML variant %d (SDK layout, limits, power, processes, session lifetime, OOM, UUID reorder)\n",variant);
    return 0;
}
