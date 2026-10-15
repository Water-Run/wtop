/* Run the real collector against deterministic IOKit handles and real CF
 * properties. This never changes any host devices. */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <math.h>
#include <stdlib.h>
#include "../../native/wtop_macos_gpu_clock.h"
enum { REPLACED=1, REPARENTED=2, DUPLICATE=4, REORDER=8, DETACHED=16,
    ENUM_FAILED=32, ENUM_INVALID=64, MULTI_PARENT=128, CYCLE=256,
    NAME_CHANGED=512, PROPERTIES_FAILED=1024, CLOCK_DETACHED=2048, FLOOD=4096, HIGH_ID=8192 };
static unsigned mode, references, next_calls, property_calls[5000], id_calls[5000], parent_calls[5000];
static unsigned devices = 2, clock_calls;
static uint64_t clock_owner;
static int oom_enabled, fail_allocation, clock_bad;
static CFMutableDictionaryRef properties[5000];
struct iterator { unsigned used, kind, entry, cursor; };
static struct iterator iterators[16];
static unsigned retain(unsigned object) { if (object) ++references; return object; }
static unsigned new_iterator(unsigned kind,unsigned entry) {
    for (unsigned i=0;i<16;++i) if (!iterators[i].used) {iterators[i]=(struct iterator){1,kind,entry,0};++references;return 10000+i;}
    assert(0);return 0;
}
static CFMutableDictionaryRef fixture_matching(const char *name) {
    assert(!strcmp(name,"IOAccelerator"));
    return CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
}
static kern_return_t fixture_services(mach_port_t port,CFDictionaryRef matching,io_iterator_t *out) {
    (void)port;CFRelease(matching);*out=0;
    if(mode&ENUM_FAILED)return KERN_FAILURE;
    *out=new_iterator(1,0);return KERN_SUCCESS;
}
static io_object_t fixture_next(io_iterator_t handle) {
    struct iterator *it=&iterators[handle-10000];assert(it->used);++next_calls;
    unsigned cursor=it->cursor++;
    if(it->kind==1) {
        if(mode&FLOOD)return retain(5);
        if(cursor>=devices)return 0;
        if((mode&REORDER)&&devices==2)cursor=1-cursor;
        return retain(5+cursor);
    }
    if(cursor>0 && !((mode&MULTI_PARENT)&&it->entry==5&&cursor==1))return 0;
    unsigned parent=it->entry==2||it->entry==3?1:it->entry==5?2:1;
    if(cursor==1)parent=3;
    if((mode&REPARENTED)&&it->entry==5&&property_calls[5]>0)parent=3;
    if((mode&CYCLE)&&it->entry==5)parent=5;
    return retain(parent);
}
static boolean_t fixture_valid(io_iterator_t handle) {return !((mode&ENUM_INVALID)&&iterators[handle-10000].kind==1);}
static kern_return_t fixture_release(io_object_t object) {
    assert(object&&references);--references;
    if(object>=10000) {
        struct iterator *it=&iterators[object-10000];assert(it->used);
        if(oom_enabled&&it->kind==1)fail_allocation=1;
        it->used=0;
    }
    return KERN_SUCCESS;
}
static kern_return_t fixture_parent(io_registry_entry_t entry,const io_name_t plane,io_iterator_t *out) {
    (void)plane;++parent_calls[entry];*out=new_iterator(2,entry);return KERN_SUCCESS;
}
static boolean_t fixture_plane(io_registry_entry_t entry,const io_name_t plane) {
    (void)plane;
    return entry!=1&&!((mode&DETACHED)&&entry==5&&property_calls[5]>0);
}
static kern_return_t fixture_id(io_registry_entry_t entry,uint64_t *id) {
    ++id_calls[entry];*id=1000+entry;
    if((mode&DUPLICATE)&&entry==6)*id=1005;
    if((mode&HIGH_ID)&&entry==5)*id=UINT64_MAX;
    if((mode&REPLACED)&&entry==5&&property_calls[5]>0)*id=10000+entry;
    return KERN_SUCCESS;
}
static boolean_t fixture_class(io_object_t entry,const io_name_t name) {
    return !strcmp(name,"IOPCIDevice")&&(entry==2||entry==3);
}
static io_registry_entry_t fixture_root(mach_port_t port){(void)port;return retain(1);}
static boolean_t fixture_equal(io_object_t a,io_object_t b){return a==b;}
static kern_return_t fixture_properties(io_registry_entry_t entry,CFMutableDictionaryRef *out,CFAllocatorRef allocator,IOOptionBits options) {
    (void)allocator;(void)options;++property_calls[entry];*out=NULL;
    if((mode&PROPERTIES_FAILED)&&entry==5)return KERN_FAILURE;
    *out=CFDictionaryCreateMutableCopy(NULL,0,properties[entry]);
    if((mode&NAME_CHANGED)&&entry==5&&property_calls[5]>1)CFDictionarySetValue(*out,CFSTR("model"),CFSTR("Replacement"));
    return KERN_SUCCESS;
}
static CFMutableDictionaryRef fixture_id_matching(uint64_t id) {
    CFMutableDictionaryRef result=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    int64_t raw=(int64_t)id;CFNumberRef n=CFNumberCreate(NULL,kCFNumberSInt64Type,&raw);
    CFDictionarySetValue(result,CFSTR("id"),n);CFRelease(n);return result;
}
static io_service_t fixture_service(mach_port_t port,CFDictionaryRef matching) {
    (void)port;int64_t id;assert(CFNumberGetValue(CFDictionaryGetValue(matching,CFSTR("id")),kCFNumberSInt64Type,&id));CFRelease(matching);
    if(mode&CLOCK_DETACHED)return 0;
    return retain((unsigned)(id-1000));
}
#define IOServiceMatching fixture_matching
#define IOServiceGetMatchingServices fixture_services
#define IOIteratorNext fixture_next
#define IOIteratorIsValid fixture_valid
#define IOObjectRelease fixture_release
#define IORegistryEntryGetParentIterator fixture_parent
#define IORegistryEntryInPlane fixture_plane
#define IORegistryEntryGetRegistryEntryID fixture_id
#define IOObjectConformsTo fixture_class
#define IORegistryGetRootEntry fixture_root
#define IOObjectIsEqualTo fixture_equal
#define IORegistryEntryCreateCFProperties fixture_properties
#define IORegistryEntryIDMatching fixture_id_matching
#define IOServiceGetMatchingService fixture_service
#include "../../native/wtop_macos_gpu.c"
int wtop_gpu_frequency(uint64_t owner,struct wtop_gpu_frequency *frequency) {
    ++clock_calls;clock_owner=owner;
    *frequency=(struct wtop_gpu_frequency){.mean=clock_bad?NAN:500000000,.active=0.5,.minimum=200000000,.maximum=1000000000};
    return owner!=0;
}
static void put_number(CFMutableDictionaryRef dictionary,CFStringRef key,int64_t value) {
    CFNumberRef n=CFNumberCreate(NULL,kCFNumberSInt64Type,&value);CFDictionarySetValue(dictionary,key,n);CFRelease(n);
}
static void put_float(CFMutableDictionaryRef dictionary,CFStringRef key,double value) {
    CFNumberRef n=CFNumberCreate(NULL,kCFNumberDoubleType,&value);CFDictionarySetValue(dictionary,key,n);CFRelease(n);
}
static CFMutableDictionaryRef statistics(unsigned entry) {return (CFMutableDictionaryRef)CFDictionaryGetValue(properties[entry],CFSTR("PerformanceStatistics"));}
static void setup(unsigned count) {
    for(unsigned i=0;i<devices;++i)if(properties[5+i]){CFRelease(properties[5+i]);properties[5+i]=NULL;}
    devices=count;
    for(unsigned i=0;i<count;++i) {
        CFMutableDictionaryRef p=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        properties[5+i]=p;put_number(p,CFSTR("vendor-id"),i==1?0x106b:0x1002);put_number(p,CFSTR("device-id"),0);
        put_number(p,CFSTR("gpu-core-count"),10);CFDictionarySetValue(p,CFSTR("model"),CFSTR("Fixture GPU"));
        CFDictionarySetValue(p,CFSTR("IOClass"),CFSTR("FixtureDriver"));
        CFMutableDictionaryRef stats=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        put_float(stats,CFSTR("Device Utilization %"),i?20:0);put_number(stats,CFSTR("vramUsedBytes"),i?0:INT64_C(9007199254741001));
        put_number(stats,CFSTR("vramFreeBytes"),10);CFDictionarySetValue(p,CFSTR("PerformanceStatistics"),stats);CFRelease(stats);
    }
}
static void collect(lua_State *L,unsigned flags,const char *checks) {
    mode=flags;next_calls=0;clock_calls=0;clock_owner=0;
    memset(property_calls,0,sizeof(property_calls));memset(id_calls,0,sizeof(id_calls));memset(parent_calls,0,sizeof(parent_calls));
    lua_settop(L,0);lua_pushcfunction(L,wtop_collect_gpu);int result=lua_pcall(L,0,1,0);
    if(result!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));
    assert(result==LUA_OK&&references==0);lua_setglobal(L,"data");
    result=luaL_dostring(L,checks);if(result!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));assert(result==LUA_OK);
    for(unsigned i=0;i<devices;++i)assert(CFGetRetainCount(properties[5+i])==1);
}
struct allocator_context {lua_Alloc original;void *context;};
static void *allocator(void *context,void *pointer,size_t old,size_t size) {
    struct allocator_context *a=context;if(size>0&&fail_allocation)return NULL;return a->original(a->context,pointer,old,size);
}
int main(void) {
    lua_State *L=luaL_newstate();assert(L);luaL_openlibs(L);setup(2);
    collect(L,0,"assert(#data.devices==2 and not data.partial); a,b=table.unpack(data.devices); assert(a.id=='ioreg:1005' and b.id=='ioreg:1006'); assert(a.metrics.utilization_percent==0 and a.metrics.memory_used_bytes==9007199254741001 and a.metrics.memory_total_bytes==9007199254741011); assert(a._registry_parent_id=='ioreg:1002' and not b._registry_parent_id); assert(not a.capabilities.frequency and b.quality.frequency=='estimated' and b.metrics.frequency_current_hz==500000000)");
    assert(clock_owner==1006&&clock_calls==1);
    collect(L,REORDER,"assert(data.devices[1].id=='ioreg:1005' and data.devices[2].id=='ioreg:1006' and data.devices[2].metrics.frequency_current_hz==500000000)");
    collect(L,HIGH_ID,"assert(data.devices[2].id=='ioreg:18446744073709551615')");
    for(unsigned flags=REPLACED;flags<=REPARENTED;flags<<=1)collect(L,flags,"assert(data.partial and #data.devices==1 and data.devices[1].id=='ioreg:1006' and not data.devices[1].capabilities.frequency)");
    collect(L,DUPLICATE,"assert(data==nil)");collect(L,DETACHED,"assert(data.partial and #data.devices==1)");
    collect(L,ENUM_FAILED,"assert(data==nil)");collect(L,ENUM_INVALID,"assert(data.partial and data.devices[1].identity_quality=='partial')");
    for(unsigned flags=MULTI_PARENT;flags<=PROPERTIES_FAILED;flags<<=1)collect(L,flags,"assert(data.partial and #data.devices==1)");
    collect(L,CLOCK_DETACHED,"assert(data.partial and #data.devices==1 and data.devices[1].id=='ioreg:1005')");
    clock_bad=1;collect(L,0,"assert(not data.devices[2].capabilities.frequency)");clock_bad=0;
    const double bad[]={NAN,INFINITY,-INFINITY,-1,100.1};
    for(unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);++i){put_float(statistics(5),CFSTR("Device Utilization %"),bad[i]);collect(L,0,"assert(data.partial and not data.devices[1].capabilities.utilization and not data.devices[1].metrics.utilization_percent)");}
    put_float(statistics(5),CFSTR("GPU Activity(%)"),55);collect(L,0,"assert(data.devices[1].metrics.utilization_percent==55)");
    put_number(statistics(5),CFSTR("vramUsedBytes"),INT64_MAX);collect(L,0,"assert(data.partial and data.devices[1].metrics.memory_used_bytes==math.maxinteger and not data.devices[1].metrics.memory_total_bytes)");
    const double bad_bytes[]={NAN,INFINITY,-1,0.5,9007199254740992.0};
    for(unsigned i=0;i<sizeof(bad_bytes)/sizeof(bad_bytes[0]);++i){put_float(statistics(5),CFSTR("vramUsedBytes"),bad_bytes[i]);collect(L,0,"assert(data.partial and not data.devices[1].capabilities.memory and not data.devices[1].metrics.memory_used_bytes)");}
    CFDictionaryRemoveValue(statistics(5),CFSTR("vramUsedBytes"));put_number(statistics(5),CFSTR("In use system memory"),0);put_number(statistics(5),CFSTR("Alloc system memory"),0);
    collect(L,0,"assert(data.devices[1].metrics.shared_memory_used_bytes==0 and data.devices[1].metrics.shared_memory_allocated_bytes==0)");
    put_number(statistics(5),CFSTR("In use system memory"),100);collect(L,0,"assert(data.partial and data.devices[1].metrics.memory_used_bytes==100 and not data.devices[1].metrics.shared_memory_allocated_bytes)");
    setup(2);CFDictionaryRemoveValue(properties[5],CFSTR("PerformanceStatistics"));collect(L,0,"assert(not data.partial and not data.devices[1].capabilities.utilization and not data.devices[1].capabilities.memory)");
    CFDictionarySetValue(properties[5],CFSTR("PerformanceStatistics"),CFSTR("wrong"));collect(L,0,"assert(data.partial and not data.devices[1].capabilities.utilization)");
    setup(2);CFDictionarySetValue(properties[5],CFSTR("model"),CFSTR("显卡 GPU"));collect(L,0,"assert(data.devices[1].model_name=='显卡 GPU')");
    const UInt8 name[]={'D','a','t','a',0};CFDataRef text=CFDataCreate(NULL,name,sizeof(name));CFDictionarySetValue(properties[5],CFSTR("model"),text);CFRelease(text);
    collect(L,0,"assert(data.devices[1].model_name=='Data')");
    const UniChar nul[]={'a',0,'b'};CFStringRef embedded=CFStringCreateWithCharacters(NULL,nul,3);CFDictionarySetValue(properties[5],CFSTR("model"),embedded);CFRelease(embedded);
    collect(L,0,"assert(data.partial and not data.devices[1].model_name)");
    setup(2);put_number(properties[5],CFSTR("vendor-id"),0x106b);collect(L,0,"assert(data.devices[2].capabilities.frequency)"); /* PCI Apple entry is not the integrated owner. */
    setup(3);put_number(properties[7],CFSTR("vendor-id"),0x106b);collect(L,0,"assert(not data.devices[2].capabilities.frequency and not data.devices[3].capabilities.frequency)");assert(clock_owner==0);
    setup(128);collect(L,0,"assert(#data.devices==128 and not data.truncated)");
    setup(129);collect(L,0,"assert(#data.devices==128 and data.truncated and data.partial)");
    setup(2);collect(L,FLOOD,"assert(data==nil)");assert(next_calls<5000);
    double clocks[]={200000000,1000000000},mean=0,active=0;
    struct wtop_gpu_state states[]={{10,1},{10,0},{30,0}};
    assert(wtop_gpu_clock(states,3,clocks,2,&mean,&active)&&mean==800000000&&active==0.8);
    double unordered[]={1000000000,200000000};
    assert(wtop_gpu_clock(states,3,unordered,2,&mean,&active)&&mean==400000000);
    states[1].ticks=states[2].ticks=0;assert(wtop_gpu_clock(states,3,clocks,2,&mean,&active)&&mean==0&&active==0);
    states[0].ticks=-1;assert(!wtop_gpu_clock(states,3,clocks,2,&mean,&active));states[0].ticks=0;
    assert(!wtop_gpu_clock(states,3,clocks,2,&mean,&active));assert(!wtop_gpu_clock(states,3,clocks,1,&mean,&active));
    assert(!wtop_gpu_clock(states,129,clocks,2,&mean,&active));clocks[0]=NAN;assert(!wtop_gpu_clock(states,3,clocks,2,&mean,&active));
    unsigned next=UINT_MAX;int idle;
    assert(wtop_gpu_state_label("OFF",&next,&idle)&&idle);
    assert(wtop_gpu_state_label("P1",&next,&idle)&&!idle&&next==2);
    assert(wtop_gpu_state_label("P2",&next,&idle)&&next==3);
    assert(!wtop_gpu_state_label("P4",&next,&idle)&&!wtop_gpu_state_label("Unknown",&next,&idle));
    next=UINT_MAX;assert(wtop_gpu_state_label("P0",&next,&idle)&&next==1);
    struct allocator_context a;a.original=lua_getallocf(L,&a.context);lua_setallocf(L,allocator,&a);lua_pushcfunction(L,wtop_collect_gpu);
    mode=0;memset(property_calls,0,sizeof(property_calls));oom_enabled=1;assert(lua_pcall(L,0,1,0)==LUA_ERRMEM);assert(references==0);
    fail_allocation=oom_enabled=0;lua_setallocf(L,a.original,a.context);lua_close(L);setup(0);
    puts("GPU: registry identities, reorder/replacement/detach, exact owners, finite utilization, integer memory/overflow, optional clocks, caps and Lua-OOM cleanup passed");
    return 0;
}
