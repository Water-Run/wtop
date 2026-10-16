/* Exercise real report transport/consumers with owned CF objects, no hardware. */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <time.h>
#include <math.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include "../../native/wtop_macos_ioreport.h"
enum { LOAD_FAIL=1,GROUP_FAIL=2,SUB_FAIL=4,SUBSCRIBED_MISSING=8,SAMPLE_FAIL=16,
    DELTA_FAIL=32,WRONG_TYPE=64,EMPTY=128,META_CHANGE=256,RAW_SHORT=512,
    REORDER=1024,DUPLICATE=2048,TOO_MANY=4096,CLOCK_FAIL=8192,
    UNIT_CHANGE=16384,NEGATIVE_DELTA=32768,NO_INTEGER=65536,BAD_STATES=131072,
    PMGR_CONFLICT=262144,META_ALLOC_FAIL=524288,DUPLICATE_ID=1048576,SHARED_INFO=2097152,
    WRONG_FORMAT=4194304,MISSING_UNIT=8388608 };
static unsigned mode,loads,unloads,opens,closes,frame_number[3],io_refs;
static uint64_t now_ns=1000000000;
static int selected_source,fail_source=-1,oom_enabled,fail_allocation,smc_available=1;
static uint32_t efficiency_maximum=2000000;
static int64_t gpu_driver=100;
static CFTypeRef owned[16384];static unsigned owned_count;
static CFMutableDictionaryRef shared_info;
static void (*exit_cleanup)(void);
struct IOReportSubscription;
static CFTypeRef own(CFTypeRef value){if(value){assert(owned_count<16384);owned[owned_count++]=value;}return value;}
static CFTypeRef retain_cf(CFTypeRef value){return own(CFRetain(value));}
static void release_cf(CFTypeRef value){
    unsigned i;for(i=0;i<owned_count;++i)if(owned[i]==value){owned[i]=owned[--owned_count];break;}
    if(CFGetTypeID(value)==CFStringGetTypeID()&&CFEqual(value,CFSTR("Subscription")))++closes;
    if(oom_enabled&&CFGetTypeID(value)==CFDictionaryGetTypeID()
        &&CFDictionaryContainsKey(value,CFSTR("IOReportChannels")))fail_allocation=1;
    CFRelease(value);
}
static int applies(unsigned flag,int source){return (mode&flag)&&(fail_source<0||fail_source==source);}
static void put(CFMutableDictionaryRef d,CFStringRef key,int64_t number){CFNumberRef n=CFNumberCreate(NULL,kCFNumberSInt64Type,&number);CFDictionarySetValue(d,key,n);CFRelease(n);}
static CFMutableDictionaryRef channel(int source,unsigned index,int delta){
    CFMutableDictionaryRef item=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    put(item,CFSTR("DriverID"),applies(META_CHANGE,source)?999:source==0?gpu_driver:100+source);
    CFDictionarySetValue(item,CFSTR("IOReportGroupName"),source==0?CFSTR("GPU Stats"):source==1?CFSTR("CPU Stats"):CFSTR("Energy Model"));
    CFMutableArrayRef legend=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    int64_t id=applies(DUPLICATE_ID,source)?1:index+1,format=source==2?1:2;
    if(applies(WRONG_FORMAT,source))format=3;
    CFNumberRef n=CFNumberCreate(NULL,kCFNumberSInt64Type,&id),f=CFNumberCreate(NULL,kCFNumberSInt64Type,&format);
    CFArrayAppendValue(legend,n);CFArrayAppendValue(legend,f);CFRelease(n);CFRelease(f);
    const CFStringRef energy[]={CFSTR("CPU Energy"),CFSTR("ECPU"),CFSTR("GPU Energy")};
    if(source!=0)CFArrayAppendValue(legend,source==1?(index?CFSTR("PCPU"):CFSTR("ECPU")):energy[index%3]);
    CFDictionarySetValue(item,CFSTR("LegendChannel"),legend);CFRelease(legend);
    CFMutableDictionaryRef info=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    put(info,CFSTR("IOReportChannelUnit"),source==2?1:2);
    if(applies(MISSING_UNIT,source))CFDictionaryRemoveValue(info,CFSTR("IOReportChannelUnit"));
    CFDictionarySetValue(info,CFSTR("unit_text"),source==2?(applies(UNIT_CHANGE,source)?CFSTR("bad"):CFSTR("mJ")):CFSTR("ticks"));
    if((mode&SHARED_INFO)&&source==2){
        if(!shared_info)shared_info=CFDictionaryCreateMutableCopy(NULL,0,info);
        else if(mode&UNIT_CHANGE)CFDictionarySetValue(shared_info,CFSTR("unit_text"),CFSTR("bad"));
        CFDictionarySetValue(item,CFSTR("IOReportChannelInfo"),shared_info);
    }else CFDictionarySetValue(item,CFSTR("IOReportChannelInfo"),info);
    CFRelease(info);
    unsigned count=source==2?1:3;uint8_t raw[192]={0};
    for(unsigned state=0;state<count;++state){int64_t value=(delta?1:(int64_t)frame_number[source])*(int64_t)(state+1)*1000;
        if(delta&&applies(NEGATIVE_DELTA,source))value=-value;memcpy(raw+state*64,&value,sizeof(value));}
    CFDataRef bytes=CFDataCreate(NULL,raw,applies(RAW_SHORT,source)?1:count*64);
    CFDictionarySetValue(item,CFSTR("RawElements"),bytes);CFRelease(bytes);return item;
}
static CFDictionaryRef frame(int source,int delta){
    if(applies(WRONG_TYPE,source))return (CFDictionaryRef)own(CFStringCreateWithCString(NULL,"wrong",kCFStringEncodingUTF8));
    CFMutableDictionaryRef d=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    put(d,CFSTR("source"),source);
    CFMutableArrayRef array=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    unsigned count=source==0?1:source==1?2:3;
    if(applies(EMPTY,source))count=0;if(applies(TOO_MANY,source))count=1025;
    for(unsigned i=0;i<count;++i){unsigned index=i;if(applies(REORDER,source)&&count<=3)index=count-1-i;
        CFMutableDictionaryRef item=channel(source,applies(DUPLICATE,source)?0:index,delta);CFArrayAppendValue(array,item);CFRelease(item);}
    CFDictionarySetValue(d,CFSTR("IOReportChannels"),array);CFRelease(array);return (CFDictionaryRef)own(d);
}
static void *fixture_dlopen(const char *path,int flags){(void)flags;assert(!strcmp(path,"/usr/lib/libIOReport.dylib"));++loads;return mode&LOAD_FAIL?NULL:(void*)1;}
static int fixture_dlclose(void *library){assert(library==(void*)1);++unloads;return 0;}
static CFDictionaryRef fixture_group(CFStringRef group,CFStringRef subgroup,uint64_t a,uint64_t b,uint64_t c){
    (void)subgroup;assert(!a&&!b&&!c);selected_source=CFEqual(group,CFSTR("Energy Model"))?2:CFEqual(group,CFSTR("CPU Stats"))?1:0;
    if(applies(GROUP_FAIL,selected_source))return NULL;return frame(selected_source,0);
}
static struct IOReportSubscription *fixture_subscribe(void *a,CFMutableDictionaryRef channels,CFMutableDictionaryRef *subscribed,uint64_t b,CFTypeRef c){
    (void)channels;assert(!a&&!b&&!c);*subscribed=NULL;++opens;
    if(!applies(SUBSCRIBED_MISSING,selected_source))*subscribed=(CFMutableDictionaryRef)frame(selected_source,0);
    if(applies(SUB_FAIL,selected_source))return NULL;
    return (struct IOReportSubscription*)own(CFStringCreateWithCString(NULL,"Subscription",kCFStringEncodingUTF8));
}
static int source_of(CFDictionaryRef d){int source=-1;assert(CFNumberGetValue(CFDictionaryGetValue(d,CFSTR("source")),kCFNumberIntType,&source));assert(source>=0&&source<3);return source;}
static CFDictionaryRef fixture_samples(struct IOReportSubscription *s,CFMutableDictionaryRef channels,CFTypeRef options){
    assert(s&&!options);int source=source_of(channels);++frame_number[source];now_ns+=1000000000;
    if(applies(SAMPLE_FAIL,source))return NULL;return frame(source,0);
}
static CFDictionaryRef fixture_delta(CFDictionaryRef old,CFDictionaryRef current,CFTypeRef options){
    (void)old;assert(!options);int source=source_of(current);if(applies(DELTA_FAIL,source))return NULL;return frame(source,1);
}
static CFStringRef fixture_name(CFDictionaryRef item){CFArrayRef legend=CFDictionaryGetValue(item,CFSTR("LegendChannel"));return CFArrayGetCount(legend)>2?CFArrayGetValueAtIndex(legend,2):CFSTR("GPUPH");}
static CFStringRef fixture_unit(CFDictionaryRef item){CFDictionaryRef info=CFDictionaryGetValue(item,CFSTR("IOReportChannelInfo"));assert(CFDictionaryGetValue(info,CFSTR("IOReportChannelUnit")));return CFDictionaryGetValue(info,CFSTR("unit_text"));}
static int32_t fixture_format(CFDictionaryRef item){int32_t format;CFArrayRef legend=CFDictionaryGetValue(item,CFSTR("LegendChannel"));assert(CFNumberGetValue(CFArrayGetValueAtIndex(legend,1),kCFNumberSInt32Type,&format));return format;}
static int64_t fixture_integer(CFDictionaryRef item,int32_t index){assert(index==0&&fixture_format(item)==1);int64_t value;memcpy(&value,CFDataGetBytePtr(CFDictionaryGetValue(item,CFSTR("RawElements"))),8);return value;}
static int32_t fixture_count(CFDictionaryRef item){(void)item;return 3;}
static CFStringRef fixture_state_name(CFDictionaryRef item,int32_t index){
    if(mode&BAD_STATES)return CFSTR("unknown");
    int gpu=CFEqual(fixture_name(item),CFSTR("GPUPH"));
    return index==0?(gpu?CFSTR("OFF"):CFSTR("IDLE")):gpu?(index==1?CFSTR("P1"):CFSTR("P2")):(index==1?CFSTR("V0P1"):CFSTR("V1P0"));
}
static int64_t fixture_residency(CFDictionaryRef item,int32_t index){assert(index>=0&&index<3);int64_t value;memcpy(&value,CFDataGetBytePtr(CFDictionaryGetValue(item,CFSTR("RawElements")))+index*64,8);return value;}
static void *fixture_dlsym(void *library,const char *name){assert(library==(void*)1);
    if(!strcmp(name,"IOReportCopyChannelsInGroup"))return (void*)fixture_group;
    if(!strcmp(name,"IOReportCreateSubscription"))return (void*)fixture_subscribe;
    if(!strcmp(name,"IOReportCreateSamples"))return (void*)fixture_samples;
    if(!strcmp(name,"IOReportCreateSamplesDelta"))return (void*)fixture_delta;
    if(!strcmp(name,"IOReportChannelGetFormat"))return (void*)fixture_format;
    if(!strcmp(name,"IOReportSimpleGetIntegerValue"))return mode&NO_INTEGER?NULL:(void*)fixture_integer;
    if(!strcmp(name,"IOReportChannelGetChannelName"))return (void*)fixture_name;
    if(!strcmp(name,"IOReportChannelGetUnitLabel"))return (void*)fixture_unit;
    if(!strcmp(name,"IOReportStateGetCount"))return (void*)fixture_count;
    if(!strcmp(name,"IOReportStateGetNameForIndex"))return (void*)fixture_state_name;
    if(!strcmp(name,"IOReportStateGetResidency"))return (void*)fixture_residency;
    assert(0);return NULL;
}
static int fixture_atexit(void (*fn)(void)){assert(!exit_cleanup);exit_cleanup=fn;return 0;}
static int fixture_clock(clockid_t clock,struct timespec *out){assert(clock==CLOCK_MONOTONIC);if(mode&CLOCK_FAIL)return -1;out->tv_sec=(time_t)(now_ns/1000000000);out->tv_nsec=(long)(now_ns%1000000000);return 0;}
static CFMutableDictionaryRef copy_dictionary(CFAllocatorRef a,CFIndex b,CFDictionaryRef c){return (CFMutableDictionaryRef)own(CFDictionaryCreateMutableCopy(a,b,c));}
static CFMutableArrayRef new_array(CFAllocatorRef a,CFIndex b,const CFArrayCallBacks *c){return (CFMutableArrayRef)own(CFArrayCreateMutable(a,b,c));}
static CFPropertyListRef freeze_copy(CFAllocatorRef a,CFPropertyListRef b,CFOptionFlags c){return own(CFPropertyListCreateDeepCopy(a,b,c));}
static void *fixture_malloc(size_t size){return mode&META_ALLOC_FAIL?NULL:malloc(size);}
#define dlopen fixture_dlopen
#define dlclose fixture_dlclose
#define dlsym fixture_dlsym
#define atexit fixture_atexit
#define clock_gettime fixture_clock
#define CFRelease release_cf
#define CFRetain retain_cf
#define CFDictionaryCreateMutableCopy copy_dictionary
#define CFArrayCreateMutable new_array
#define CFPropertyListCreateDeepCopy freeze_copy
#define malloc fixture_malloc
#include "../../native/wtop_macos_ioreport.c"
#undef malloc
#undef CFDictionaryCreateMutableCopy
#undef CFArrayCreateMutable
#undef CFPropertyListCreateDeepCopy
static unsigned pmgr_cursor;
static CFMutableDictionaryRef fixture_matching(const char *name){assert(!strcmp(name,"pmgr"));return (CFMutableDictionaryRef)own(CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks));}
static kern_return_t fixture_services(mach_port_t port,CFDictionaryRef matching,io_iterator_t *out){(void)port;release_cf(matching);pmgr_cursor=0;*out=1;++io_refs;return KERN_SUCCESS;}
static io_object_t fixture_next(io_iterator_t it){assert(it==1);unsigned cursor=pmgr_cursor++;if(cursor>=((mode&PMGR_CONFLICT)?2u:1u))return 0;++io_refs;return 2+cursor;}
static kern_return_t fixture_release(io_object_t object){assert((object==1||object==2||object==3)&&io_refs);--io_refs;return KERN_SUCCESS;}
static boolean_t fixture_valid(io_iterator_t it){assert(it==1);return 1;}
static CFTypeRef fixture_property(io_registry_entry_t entry,CFStringRef key,CFAllocatorRef a,IOOptionBits b){
    (void)a;(void)b;assert(entry==2||entry==3);uint32_t values[4]={200000,0,1000000,0};
    if(CFEqual(key,CFSTR("voltage-states1-sram"))){values[0]=900000;values[2]=efficiency_maximum;}
    if(CFEqual(key,CFSTR("voltage-states5-sram"))){values[0]=1000000;values[2]=3000000;}
    if(entry==3)values[2]+=1000;
    return own(CFDataCreate(NULL,(const UInt8*)values,sizeof(values)));
}
static int fixture_sysctl(const char *key,void *out,size_t *size,void *new_value,size_t length){(void)new_value;(void)length;int64_t value=strstr(key,"perflevel0")?4:6;assert(*size==8);memcpy(out,&value,8);return 0;}
#define IOServiceNameMatching fixture_matching
#define IOServiceGetMatchingServices fixture_services
#define IOIteratorNext fixture_next
#define IOObjectRelease fixture_release
#define IOIteratorIsValid fixture_valid
#define IORegistryEntryCreateCFProperty fixture_property
#define sysctlbyname fixture_sysctl
#include "../../native/wtop_macos_report.c"
void wtop_smc_begin(void){}
int wtop_smc_number(const char *key,double *value){assert(!strcmp(key,"PSTR"));if(!smc_available)return 0;*value=20;return 1;}
#undef CFRelease
#undef CFRetain
static void release_sample(struct wtop_report_sample *sample){if(sample->owner)release_cf(sample->owner);}
static void clean(void){wtop_ioreport_cleanup();assert(owned_count==0&&io_refs==0);if(shared_info){assert(CFGetRetainCount(shared_info)==1);CFRelease(shared_info);shared_info=NULL;}mode=0;fail_source=-1;}
static void call(lua_State *L,lua_CFunction fn,const char *checks){
    lua_settop(L,0);lua_pushcfunction(L,fn);int status=lua_pcall(L,0,1,0);
    if(status!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));assert(status==LUA_OK&&io_refs==0);lua_setglobal(L,"data");
    status=luaL_dostring(L,checks);if(status!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));assert(status==LUA_OK);
}
struct alloc_context{lua_Alloc original;void *context;};
static void *allocator(void *context,void *pointer,size_t old,size_t size){struct alloc_context *a=context;if(size&&fail_allocation)return NULL;return a->original(a->context,pointer,old,size);}
int main(void){
    struct wtop_report_sample sample;
    mode=LOAD_FAIL;assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_FAILED);
    mode=0;assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_WARMUP);release_sample(&sample);
    assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_FRESH);uint64_t first=sample.epoch;release_sample(&sample);
    mode=SAMPLE_FAIL;assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_FAILED&&owned_count==0);
    mode=0;assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_WARMUP&&sample.epoch>first);release_sample(&sample);
    assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_FRESH);release_sample(&sample);clean();
    const unsigned failures[]={GROUP_FAIL,SUB_FAIL,SUBSCRIBED_MISSING,WRONG_TYPE,EMPTY,RAW_SHORT,DUPLICATE,DUPLICATE_ID,TOO_MANY,CLOCK_FAIL,META_ALLOC_FAIL};
    for(unsigned i=0;i<sizeof(failures)/sizeof(failures[0]);++i){mode=failures[i];assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_FAILED);assert(owned_count==0);mode=0;assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_WARMUP);release_sample(&sample);clean();}
    const unsigned changed[]={DELTA_FAIL,META_CHANGE,UNIT_CHANGE,META_ALLOC_FAIL};
    for(unsigned i=0;i<sizeof(changed)/sizeof(changed[0]);++i){assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_WARMUP);release_sample(&sample);mode=changed[i];assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_FAILED&&owned_count==0);mode=0;assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_WARMUP);release_sample(&sample);clean();}
    assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_WARMUP);release_sample(&sample);mode=REORDER;assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_FRESH);release_sample(&sample);clean();
    mode=SHARED_INFO;assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_WARMUP);release_sample(&sample);
    mode=SHARED_INFO|UNIT_CHANGE;assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_FAILED&&owned_count==0);clean();
    mode=NO_INTEGER;assert(wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample)==WTOP_REPORT_FAILED);assert(wtop_ioreport_sample(WTOP_REPORT_GPU,&sample)==WTOP_REPORT_WARMUP);release_sample(&sample);clean();
    lua_State *L=luaL_newstate();assert(L);luaL_openlibs(L);
    call(L,wtop_collect_powercap,"assert(data.quality=='gap' and data._sampling_pending); zones={}; for _,z in ipairs(data.zones)do zones[z.id]=z end; assert(zones.cpu.energy_joules==0 and zones.cpu.power_quality=='gap' and zones.system.power_watts==20); epoch=zones.cpu._source_epoch");
    call(L,wtop_collect_powercap,"assert(not data._sampling_pending); for _,z in ipairs(data.zones)do if z.id=='cpu'then assert(z.energy_joules==1 and z.power_quality=='fresh')end end");
    mode=SAMPLE_FAIL;fail_source=2;call(L,wtop_collect_powercap,"assert(data.partial and #data.zones==1 and data.zones[1].id=='system')");
    mode=0;call(L,wtop_collect_powercap,"for _,z in ipairs(data.zones)do if z.id=='cpu'then assert(z.energy_joules==0 and z.power_quality=='gap' and z._source_epoch~=epoch)end end");
    mode=NEGATIVE_DELTA;call(L,wtop_collect_powercap,"assert(data.partial and #data.zones==1)");mode=0;
    call(L,wtop_collect_powercap,"for _,z in ipairs(data.zones)do if z.id=='cpu'then assert(z.energy_joules==0 and z.power_quality=='gap')end end");
    mode=WRONG_FORMAT;call(L,wtop_collect_powercap,"assert(data.partial and #data.zones==1)");
    call(L,wtop_collect_powercap,"assert(data.partial and #data.zones==1)");mode=0;
    mode=MISSING_UNIT;call(L,wtop_collect_powercap,"assert(data.partial and #data.zones==1)");
    call(L,wtop_collect_powercap,"assert(data.partial and #data.zones==1)");mode=0;
    smc_available=0;mode=SAMPLE_FAIL;call(L,wtop_collect_powercap,"assert(data==nil)");mode=0;smc_available=1;fail_source=-1;
    call(L,wtop_collect_cpufreq,"assert(data.quality=='gap' and data._sampling_pending and #data.policies==2 and not data.policies[1].frequencies.current_hz)");
    call(L,wtop_collect_cpufreq,"assert(data.quality=='estimated' and not data._sampling_pending and data.policies[1].frequencies.current_quality=='estimated');assert(#data.policies[1].affected_cpus==6 and #data.policies[2].affected_cpus==4)");
    wtop_ioreport_reset(WTOP_REPORT_CPU);efficiency_maximum=6000000;
    call(L,wtop_collect_cpufreq,"assert(data.quality=='gap' and data.policies[1].frequencies.hardware_maximum_hz==6000000000)");
    call(L,wtop_collect_cpufreq,"assert(data.policies[1].frequencies.current_hz==3960000000)");
    mode=SAMPLE_FAIL;fail_source=1;call(L,wtop_collect_cpufreq,"assert(data==nil)");mode=0;
    call(L,wtop_collect_cpufreq,"assert(data.quality=='gap' and not data.policies[1].frequencies.current_hz)");
    mode=BAD_STATES;call(L,wtop_collect_cpufreq,"assert(data.partial and not data.policies[1].frequencies.current_hz)");mode=0;fail_source=-1;
    struct wtop_gpu_frequency frequency;assert(!wtop_gpu_frequency(100,&frequency)&&frequency.warming);assert(wtop_gpu_frequency(100,&frequency)&&!frequency.warming);
    assert(frequency.minimum==200000000&&frequency.maximum==1000000000);gpu_driver=101;
    assert(!wtop_gpu_frequency(101,&frequency));assert(wtop_gpu_frequency(101,&frequency));
    gpu_driver=102;mode=PMGR_CONFLICT;assert(!wtop_gpu_frequency(102,&frequency));mode=0;
    assert(!wtop_gpu_frequency(102,&frequency));assert(wtop_gpu_frequency(102,&frequency));
    assert(!wtop_gpu_frequency(999,&frequency));assert(!wtop_gpu_frequency(999,&frequency));
    gpu_driver=999;assert(!wtop_gpu_frequency(999,&frequency));assert(!wtop_gpu_frequency(999,&frequency));
    assert(wtop_gpu_frequency(999,&frequency));
    clean();
    struct alloc_context a;a.original=lua_getallocf(L,&a.context);lua_setallocf(L,allocator,&a);lua_pushcfunction(L,wtop_collect_powercap);
    oom_enabled=1;assert(lua_pcall(L,0,1,0)==LUA_ERRMEM);assert(io_refs==0);
    fail_allocation=oom_enabled=0;lua_setallocf(L,a.original,a.context);clean();
    assert(voltage_state("V0P1",0,2)&&voltage_state("V1P0",1,2));assert(!voltage_state("V0P0",0,2)&&!voltage_state("V1P0junk",1,2));
    lua_close(L);clean();assert(exit_cleanup);exit_cleanup();assert(owned_count==0&&loads>=unloads&&closes<=opens);
    puts("IOReport: recoverable open/sample/delta failures, epochs, metadata/order/units, independent readers, genuine warmup, energy/CPU/GPU recovery and owned-object cleanup passed");return 0;
}
