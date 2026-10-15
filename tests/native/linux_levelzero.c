#define _POSIX_C_SOURCE 200809L
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <dlfcn.h>
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "../../native/wtop_levelzero.c"
static long budget=-1;
static void *allocation(void *opaque,void *pointer,size_t previous,size_t size) {
    (void)opaque;if(!size){free(pointer);return NULL;}
    if((!pointer||size>previous)&&budget>=0){if(!budget)return NULL;--budget;}
    return realloc(pointer,size);
}
static void query(lua_State *L) {
    lua_settop(L,0);lua_pushcfunction(L,wtop_levelzero_query);int code=lua_pcall(L,0,2,0);
    if(code!=LUA_OK)fprintf(stderr,"query: %s\n",lua_tostring(L,-1));
    assert(code==LUA_OK);
    if(!lua_istable(L,1))fprintf(stderr,"provider: %s\n",lua_tostring(L,2));
    assert(lua_istable(L,1));
    lua_settop(L,1);lua_setglobal(L,"data");
}
static void check(lua_State *L,const char *code) {
    int status=luaL_dostring(L,code);if(status!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));assert(status==LUA_OK);
}
int main(int argc,char **argv) {
    assert(argc==2);int legacy=atoi(argv[1]);
    void *sdk=dlopen("libze_loader.so.1",RTLD_NOW|RTLD_LOCAL);if(!sdk)fprintf(stderr,"%s\n",dlerror());assert(sdk);
    void (*mode)(int)=(void (*)(int))dlsym(sdk,"fixture_mode");void (*tick)(uint64_t)=(void (*)(uint64_t))dlsym(sdk,"fixture_tick");assert(mode&&tick);
    lua_State *L=lua_newstate(allocation,NULL,0);assert(L);luaL_openlibs(L);tick(1000000);query(L);
    check(L,"assert(data.status=='ok' and #data.devices==3 and data.driver_count==2)\n"
        "for i,d in ipairs(data.devices) do assert(d.name=='SDK GPU '..string.char(64+i));assert(d.pci_bdf==string.format('0000:%02x:00.0',i+2));assert(d.vendor_id==0x8086);assert(d.temperature_celsius==49+i);assert(d.graphics_clock_hz==(700+i*100)*1e6);assert(d.memory_clock_hz==6400e6);assert(#d.frequency_domains==3 and #d.power_domains==4);assert(d.power_watts==nil and d.power_reason=='levelzero_power_warmup');assert(d.power_limit_watts==40);assert(d.power_scope=='card') end");
    tick(1050000);query(L);check(L,"assert(data.devices[1].power_watts==nil)");
    tick(1100000);query(L);check(L,"assert(data.devices[1].power_watts==30 and data.devices[1].board_power_watts==30 and data.devices[1].power_interval_ns==100000000);assert(data.devices[1].power_domains[2].power_watts==10);assert(data.devices[1].power_domains[3].power_watts==5);assert(data.devices[1].power_domains[4].power_watts==2)");
    mode(20);tick(1200000);query(L);check(L,"assert(data.devices[1].name=='SDK GPU B' and data.devices[1].power_watts==40);assert(data.devices[2].name=='SDK GPU A' and data.devices[2].power_watts==30)");
    mode(0);tick(50000);query(L);check(L,"assert(data.devices[1].power_watts==nil and data.devices[1].power_reason=='levelzero_energy_counter_reset')");
    tick(150000);query(L);check(L,"assert(data.devices[1].power_watts==30)");
    tick(6200000);query(L);check(L,"assert(data.devices[1].power_watts==nil and data.devices[1].power_reason=='levelzero_energy_counter_gap')");
    tick(6400000);query(L);check(L,"assert(data.devices[1].power_watts==30 and data.devices[1].power_interval_ns==200000000)");
    mode(10);query(L);check(L,"assert(data.devices[1].graphics_clock_hz==nil and data.devices[1].frequency_domains[1].requested_hz==900e6)");
    mode(11);query(L);check(L,"assert(data.devices[1].graphics_clock_hz==nil and data.devices[1].frequency_domains[1].throttle_raw_hex==nil)");
    mode(25);query(L);check(L,"assert(data.devices[1].frequency_domains[1].throttle_quality=='fresh' and data.devices[1].frequency_domains[1].throttle_raw_hex=='0x0000000000000001')");
    mode(7);query(L);check(L,"assert(data.devices[1].temperature_celsius==nil and data.status=='partial')");
    mode(6);query(L);check(L,"assert(data.devices[1].pci_bdf==nil and data.devices[1].uuid)");
    for(int m=8;m<=9;++m){mode(m);query(L);check(L,"assert(#data.devices==1 and data.status=='partial')");}
    mode(12);query(L);if(legacy)check(L,"assert(data.devices[1].power_watts==nil and data.devices[1].power_reason=='levelzero_power_domain_ambiguous')");
    else check(L,"assert(data.devices[1].power_scope=='card')");
    mode(13);query(L);check(L,"assert(data.devices[1].power_watts==nil and data.devices[1].power_quality=='unavailable')");
    if(!legacy)for(int m=16;m<=19;++m){mode(m);query(L);check(L,"assert(data.devices[1].power_limit_watts==nil)");}
    mode(15);tick(6600000);query(L);tick(6800000);query(L);
    check(L,"assert(data.devices[1].power_watts==30 and data.devices[1].power_domains[1].energy_microjoules==nil and data.devices[1].power_domains[1].energy_raw_hex:match('^0x800'))");
    mode(24);lua_settop(L,0);lua_pushcfunction(L,wtop_levelzero_query);assert(lua_pcall(L,0,2,0)==LUA_OK&&lua_isnil(L,1));assert(!strcmp(lua_tostring(L,2),"levelzero_device_lost"));
    mode(0);tick(6600000);query(L);tick(6800000);query(L);
    unsigned oom=0,success=0;
    for(long limit=0;limit<260;++limit){
        lua_settop(L,0);lua_pushcfunction(L,wtop_levelzero_query);budget=limit;int code=lua_pcall(L,0,2,0);budget=-1;
        assert(code==LUA_OK||code==LUA_ERRMEM);if(code==LUA_ERRMEM)++oom;else ++success;
        tick(6800000+(uint64_t)(limit+1)*100000);query(L);check(L,"assert(#data.devices==3 and data.devices[1].name=='SDK GPU A')");
    }
    assert(oom&&success);lua_close(L);assert(!dlclose(sdk));
    printf("Level Zero %s: complete SDK ABI, correct init/driver/device signatures, 2 drivers/3 devices, identity, actual frequency, 4 overlapping energy domains, caps/units, reset/gap and OOM %u/%u passed\n",legacy?"legacy":"standalone",oom,success);
}
