/* Read-only AMD Display Library queries. Called only in an isolated SDK reader. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <wchar.h>
#include "wtop_adl_abi.h"
#include "wtop_gpu_output.h"
#define ADL_MAX_ADAPTERS 64
#define ADL_UNSUPPORTED (-8)
typedef void *(__stdcall *adl_alloc_fn)(int);
typedef int (__cdecl *adl_create2_fn)(adl_alloc_fn,int,void **);
typedef int (__cdecl *adl_create1_fn)(adl_alloc_fn,int);
typedef int (__cdecl *adl_destroy2_fn)(void *);
typedef int (__cdecl *adl_destroy1_fn)(void);
typedef int (__cdecl *adl_count2_fn)(void *,int *);
typedef int (__cdecl *adl_count1_fn)(int *);
typedef int (__cdecl *adl_info2_fn)(void *,wtop_AdapterInfo *,int);
typedef int (__cdecl *adl_info1_fn)(wtop_AdapterInfo *,int);
typedef int (__cdecl *adl_output2_fn)(void *,int,void *);
typedef int (__cdecl *adl_output1_fn)(int,void *);
typedef int (__cdecl *adl_sensor2_fn)(void *,int,int,void *);
typedef int (__cdecl *adl_sensor1_fn)(int,int,void *);
typedef int (__cdecl *adl_caps2_fn)(void *,int,int *,int *,int *);
typedef int (__cdecl *adl_caps1_fn)(int,int *,int *,int *);
typedef int (__cdecl *adl_power2_fn)(void *,int,int,int *);
struct adl_output {adl_output2_fn two;adl_output1_fn one;};
struct adl_sensor {adl_sensor2_fn two;adl_sensor1_fn one;};
static struct {
    HMODULE library;void *context;int ready,two;
    adl_destroy2_fn destroy2;adl_destroy1_fn destroy1;
    adl_count2_fn count2;adl_count1_fn count1;
    adl_info2_fn info2;adl_info1_fn info1;
    adl_caps2_fn caps2;adl_caps1_fn caps1;
    struct adl_output active,activity5,status6,temp6,fan6;
    struct adl_sensor thermal5,temp5,fan5;
    adl_power2_fn power6;
} api;
static void *__stdcall adl_allocate(int size) {
    return size>0&&size<=4*1024*1024?malloc((size_t)size):NULL;
}
void wtop_adl_finish(void) {
    if(api.ready){if(api.two)api.destroy2(api.context);else api.destroy1();}
    HMODULE module=api.library;memset(&api,0,sizeof(api));if(module)FreeLibrary(module);
}
#define RESOLVE(type,name) ((type)(void *)GetProcAddress(api.library,name))
static const char *adl_open(void) {
    if(api.ready)return NULL;
    if(api.library)wtop_adl_finish();
    WCHAR path[32768];UINT size=GetSystemDirectoryW(path,32768);
    if(!size||size>=32740||!SetCurrentDirectoryW(path))return "adl_library_not_found";
#ifdef _WIN64
    wcscat(path,L"\\atiadlxx.dll");
#else
    wcscat(path,L"\\atiadlxy.dll");
#endif
    api.library=LoadLibraryExW(path,NULL,LOAD_WITH_ALTERED_SEARCH_PATH);
#ifndef _WIN64
    if(!api.library){path[size]=0;wcscat(path,L"\\atiadlxx.dll");api.library=LoadLibraryExW(path,NULL,LOAD_WITH_ALTERED_SEARCH_PATH);}
#endif
    if(!api.library)return "adl_library_not_found";
    adl_create2_fn create2=RESOLVE(adl_create2_fn,"ADL2_Main_Control_Create");
    api.destroy2=RESOLVE(adl_destroy2_fn,"ADL2_Main_Control_Destroy");
    api.count2=RESOLVE(adl_count2_fn,"ADL2_Adapter_NumberOfAdapters_Get");
    api.info2=RESOLVE(adl_info2_fn,"ADL2_Adapter_AdapterInfo_Get");
    if(create2&&api.destroy2&&api.count2&&api.info2){
        api.two=1;
        if(create2(adl_allocate,1,&api.context)||!api.context)return "adl_initialization_failed";
    }else{
        adl_create1_fn create1=RESOLVE(adl_create1_fn,"ADL_Main_Control_Create");
        api.destroy1=RESOLVE(adl_destroy1_fn,"ADL_Main_Control_Destroy");
        api.count1=RESOLVE(adl_count1_fn,"ADL_Adapter_NumberOfAdapters_Get");
        api.info1=RESOLVE(adl_info1_fn,"ADL_Adapter_AdapterInfo_Get");
        if(!create1||!api.destroy1||!api.count1||!api.info1)return "adl_symbols_missing";
        if(create1(adl_allocate,1))return "adl_initialization_failed";
    }
    api.ready=1;
#define OUTPUT(field,name) api.field.two=RESOLVE(adl_output2_fn,"ADL2_" name);api.field.one=RESOLVE(adl_output1_fn,"ADL_" name)
#define SENSOR(field,name) api.field.two=RESOLVE(adl_sensor2_fn,"ADL2_" name);api.field.one=RESOLVE(adl_sensor1_fn,"ADL_" name)
    OUTPUT(active,"Adapter_Active_Get");
    OUTPUT(activity5,"Overdrive5_CurrentActivity_Get");OUTPUT(status6,"Overdrive6_CurrentStatus_Get");
    OUTPUT(temp6,"Overdrive6_Temperature_Get");OUTPUT(fan6,"Overdrive6_FanSpeed_Get");
    SENSOR(thermal5,"Overdrive5_ThermalDevices_Enum");SENSOR(temp5,"Overdrive5_Temperature_Get");SENSOR(fan5,"Overdrive5_FanSpeed_Get");
#undef OUTPUT
#undef SENSOR
    api.caps2=RESOLVE(adl_caps2_fn,"ADL2_Overdrive_Caps");api.caps1=RESOLVE(adl_caps1_fn,"ADL_Overdrive_Caps");
    api.power6=RESOLVE(adl_power2_fn,"ADL2_Overdrive6_CurrentPower_Get");
    return NULL;
}
static int adl_output(struct adl_output fn,int index,void *data) {
    return api.two?(fn.two?fn.two(api.context,index,data):ADL_UNSUPPORTED):(fn.one?fn.one(index,data):ADL_UNSUPPORTED);
}
static int adl_sensor(struct adl_sensor fn,int index,int sensor,void *data) {
    return api.two?(fn.two?fn.two(api.context,index,sensor,data):ADL_UNSUPPORTED):(fn.one?fn.one(index,sensor,data):ADL_UNSUPPORTED);
}
static int adl_caps(int index,int *supported,int *enabled,int *version) {
    return api.two?(api.caps2?api.caps2(api.context,index,supported,enabled,version):ADL_UNSUPPORTED)
        :(api.caps1?api.caps1(index,supported,enabled,version):ADL_UNSUPPORTED);
}
static int hex_digit(unsigned char c) {
    return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:c>='A'&&c<='F'?c-'A'+10:-1;
}
static int pci_component(const char *text,const char *key) {
    const char *end=memchr(text,0,256);if(!end)return -1;
    size_t length=(size_t)(end-text),key_length=strlen(key);int found=-1;
    for(size_t at=0;at+key_length+4<=length;++at){
        unsigned k=0;for(;key[k]&&text[at+k];++k){unsigned char c=(unsigned char)text[at+k];if(c>='a'&&c<='z')c-=32;if(c!=(unsigned char)key[k])break;}
        if(key[k])continue;
        unsigned value=0;for(unsigned i=0;i<4;++i){int h=hex_digit((unsigned char)text[at+k+i]);if(h<0)return -1;value=value*16+(unsigned)h;}
        if(at+k+4<length&&hex_digit((unsigned char)text[at+k+4])>=0)return -1;
        if(found>=0)return -1;
        found=(int)value;
    }
    return found;
}
struct adl_reading {
    int adapter_index,active,present,caps_status,supported,enabled,version;
    int active_status,activity_status,temperature_status,fan_status,power_status;
    int vendor,device,strong,has_activity,has_temperature,has_fan_percent,has_fan_rpm,has_power;
    int bus,slot,function,aliases,partial;
    double temperature,power;
    int engine,memory,utilization,fan_percent,fan_rpm;
    char name[256],key[256];
};
static int adl_same_identity(const wtop_AdapterInfo *a,const wtop_AdapterInfo *b) {
    return a->iAdapterIndex==b->iAdapterIndex&&a->iExist==b->iExist
        &&a->iBusNumber==b->iBusNumber&&a->iDeviceNumber==b->iDeviceNumber
        &&a->iFunctionNumber==b->iFunctionNumber&&a->iVendorID==b->iVendorID
        &&memchr(a->strPNPString,0,256)&&memchr(b->strPNPString,0,256)
        &&memchr(a->strUDID,0,256)&&memchr(b->strUDID,0,256)
        &&!strcmp(a->strPNPString,b->strPNPString)&&!strcmp(a->strUDID,b->strUDID);
}
static int adl_clock(int value) {return value>=0&&value<=1000000;}
static void adl_read(const wtop_AdapterInfo *info,struct adl_reading *r) {
    memset(r,0,sizeof(*r));r->adapter_index=info->iAdapterIndex;r->active=-1;r->present=info->iPresent;
    r->bus=info->iBusNumber;r->slot=info->iDeviceNumber;r->function=info->iFunctionNumber;
    r->engine=r->memory=r->utilization=-1;r->aliases=1;
    r->vendor=pci_component(info->strPNPString,"VEN_");r->device=pci_component(info->strPNPString,"DEV_");
    if(r->vendor<0)r->vendor=pci_component(info->strUDID,"VEN_");
    if(r->device<0)r->device=pci_component(info->strUDID,"DEV_");
    int other_vendor=pci_component(info->strUDID,"VEN_"),other_device=pci_component(info->strUDID,"DEV_");
    r->strong=r->vendor==0x1002&&r->device>=0
        &&(info->iVendorID==1002||info->iVendorID==0x1002)
        &&(other_vendor<0||other_vendor==r->vendor)&&(other_device<0||other_device==r->device);
    /* ADL's legacy iVendorID can be decimal 1002, not PCI vendor 0x03ea. */
    if(r->vendor<0&&(info->iVendorID==1002||info->iVendorID==0x1002))r->vendor=0x1002;
    if(memchr(info->strAdapterName,0,256))memcpy(r->name,info->strAdapterName,256);
    if(memchr(info->strPNPString,0,256))memcpy(r->key,info->strPNPString,256);
    if(!r->key[0]&&memchr(info->strUDID,0,256))memcpy(r->key,info->strUDID,256);
    r->active_status=adl_output(api.active,r->adapter_index,&r->active);
    r->supported=r->enabled=r->version=-1;
    r->caps_status=adl_caps(r->adapter_index,&r->supported,&r->enabled,&r->version);
    wtop_ADLPMActivity a;memset(&a,0xff,sizeof(a));a.iSize=sizeof(a);
    r->activity_status=adl_output(api.activity5,r->adapter_index,&a);
    if(!r->activity_status){
        if(adl_clock(a.iEngineClock))r->engine=a.iEngineClock;
        if(adl_clock(a.iMemoryClock))r->memory=a.iMemoryClock;
        if(a.iActivityPercent>=0&&a.iActivityPercent<=100)r->utilization=a.iActivityPercent;
    }
    if(r->activity_status){
        wtop_ADLOD6CurrentStatus s;memset(&s,0xff,sizeof(s));
        int status=adl_output(api.status6,r->adapter_index,&s);
        if(!status){r->activity_status=0;if(adl_clock(s.iEngineClock))r->engine=s.iEngineClock;
            if(adl_clock(s.iMemoryClock))r->memory=s.iMemoryClock;
            if(s.iActivityPercent>=0&&s.iActivityPercent<=100)r->utilization=s.iActivityPercent;}
        else if(r->activity_status==ADL_UNSUPPORTED)r->activity_status=status;
    }
    r->has_activity=r->engine>=0||r->memory>=0||r->utilization>=0;
    r->temperature_status=ADL_UNSUPPORTED;r->fan_status=ADL_UNSUPPORTED;
    for(int sensor=0;sensor<8;++sensor){
        wtop_ADLThermalControllerInfo t;memset(&t,0xff,sizeof(t));t.iSize=sizeof(t);
        int status=adl_sensor(api.thermal5,r->adapter_index,sensor,&t);
        if(status){if(!sensor)r->temperature_status=status;break;}
        if(t.iThermalDomain!=1)continue;
        wtop_ADLTemperature v;memset(&v,0xff,sizeof(v));v.iSize=sizeof(v);v.iTemperature=INT_MIN;
        status=adl_sensor(api.temp5,r->adapter_index,sensor,&v);
        if(!status&&v.iTemperature>-200000&&v.iTemperature<1000000){
            double c=(double)v.iTemperature/1000.0;
            if(!r->has_temperature||c>r->temperature)r->temperature=c;
            r->has_temperature=1;r->temperature_status=0;
        }else if(!r->has_temperature)r->temperature_status=status?status:-3;
        for(int kind=1;kind<=2;++kind){
            wtop_ADLFanSpeedValue f;memset(&f,0xff,sizeof(f));f.iSize=sizeof(f);f.iSpeedType=kind;f.iFlags=0;
            status=adl_sensor(api.fan5,r->adapter_index,sensor,&f);
            if(!status&&f.iSpeedType==kind&&f.iFanSpeed>=0&&f.iFanSpeed<=(kind==1?100:100000)){
                if(kind==1){r->fan_percent=f.iFanSpeed;r->has_fan_percent=1;}else{r->fan_rpm=f.iFanSpeed;r->has_fan_rpm=1;}
                r->fan_status=0;
            }else if(!r->has_fan_percent&&!r->has_fan_rpm)r->fan_status=status?status:-3;
        }
    }
    if(!r->has_temperature){int value=INT_MIN;int status=adl_output(api.temp6,r->adapter_index,&value);
        if(!status&&value>-200000&&value<1000000){r->temperature=(double)value/1000.0;r->has_temperature=1;r->temperature_status=0;}
        else if(r->temperature_status==ADL_UNSUPPORTED)r->temperature_status=status?status:-3;}
    if(!r->has_fan_percent&&!r->has_fan_rpm){
        wtop_ADLOD6FanSpeedInfo f;memset(&f,0xff,sizeof(f));int status=adl_output(api.fan6,r->adapter_index,&f);
        if(!status&&f.iSpeedType>=0){
            if((f.iSpeedType&1)&&f.iFanSpeedPercent>=0&&f.iFanSpeedPercent<=100){r->fan_percent=f.iFanSpeedPercent;r->has_fan_percent=1;}
            if((f.iSpeedType&2)&&f.iFanSpeedRPM>=0&&f.iFanSpeedRPM<=100000){r->fan_rpm=f.iFanSpeedRPM;r->has_fan_rpm=1;}
        }
        if(r->has_fan_percent||r->has_fan_rpm)r->fan_status=0;else if(r->fan_status==ADL_UNSUPPORTED)r->fan_status=status?status:-3;
    }
    int power=INT_MIN;r->power_status=api.two&&api.power6?api.power6(api.context,r->adapter_index,0,&power):ADL_UNSUPPORTED;
    if(!r->power_status&&power>=0&&(double)power/256.0<100000){r->power=(double)power/256.0;r->has_power=1;}
    else if(!r->power_status)r->power_status=-3;
    if(!r->strong){r->has_activity=r->has_temperature=r->has_power=r->has_fan_percent=r->has_fan_rpm=0;
        r->engine=r->memory=r->utilization=-1;}
    r->partial=!r->strong||r->engine<0||r->memory<0||r->utilization<0||r->activity_status!=0||r->temperature_status!=0||r->fan_status!=0||r->power_status!=0;
}
static void adl_emit(gpu_output *out,const struct adl_reading *r,int index) {
    gpu_table(out,0,24);integer_field(out,"index",r->adapter_index);integer_field(out,"aliases",r->aliases);
    if(r->bus>=0&&r->bus<=255&&r->slot>=0&&r->slot<=31&&r->function>=0&&r->function<=7){
        char bdf[24];snprintf(bdf,sizeof(bdf),"0000:%02x:%02x.%x",r->bus,r->slot,r->function);string_field(out,"pci_bdf",bdf);}
    if(r->vendor>=0)integer_field(out,"vendor_id",r->vendor);
    if(r->device>=0)integer_field(out,"device_id",r->device);
    if(r->present==0||r->present==1)boolean_field(out,"present",r->present);
    boolean_field(out,"identity_verified",r->strong);if(r->name[0])string_field(out,"name",r->name);
    if(r->active_status==0&&(r->active==0||r->active==1))boolean_field(out,"active",r->active);
    if(!r->caps_status&&r->version>=0)integer_field(out,"overdrive_version",r->version);
    if(r->engine>=0)number_field(out,"graphics_clock_hz",(double)r->engine*10000.0);
    if(r->memory>=0)number_field(out,"memory_clock_hz",(double)r->memory*10000.0);
    if(r->utilization>=0)integer_field(out,"utilization_percent",r->utilization);
    if(r->has_temperature)number_field(out,"temperature_celsius",r->temperature);
    if(r->has_fan_percent)integer_field(out,"fan_speed_percent",r->fan_percent);
    if(r->has_fan_rpm)integer_field(out,"fan_speed_rpm",r->fan_rpm);
    if(r->has_power){number_field(out,"power_watts",r->power);string_field(out,"power_scope","asic");string_field(out,"power_measurement","device_sample");}
    integer_field(out,"active_status",r->active_status);integer_field(out,"caps_status",r->caps_status);
    integer_field(out,"activity_status",r->activity_status);integer_field(out,"temperature_status",r->temperature_status);
    integer_field(out,"fan_status",r->fan_status);integer_field(out,"power_status",r->power_status);
    boolean_field(out,"partial",r->partial);gpu_index(out,index);
}
const char *wtop_adl_collect(gpu_output *out,int processes) {
    (void)processes;const char *reason=adl_open();if(reason)return reason;
    int total=-1,status=api.two?api.count2(api.context,&total):api.count1(&total);
    if(status||total<0)return "adl_device_count_failed";
    if(total>ADL_MAX_ADAPTERS)return "adl_output_too_large";
    int count=total<ADL_MAX_ADAPTERS?total:ADL_MAX_ADAPTERS;
    wtop_AdapterInfo info[ADL_MAX_ADAPTERS];memset(info,0,sizeof(info));
    for(int i=0;i<count;++i)info[i].iSize=sizeof(info[i]);
    if(count&&(api.two?api.info2(api.context,info,count*(int)sizeof(info[0])):api.info1(info,count*(int)sizeof(info[0]))))return "adl_device_list_failed";
    struct adl_reading readings[ADL_MAX_ADAPTERS];unsigned used=0;int partial=total>ADL_MAX_ADAPTERS;
    for(int i=0;i<count;++i){
        if(info[i].iAdapterIndex<0||info[i].iExist!=1){partial=1;continue;}
        struct adl_reading r;adl_read(&info[i],&r);
        if(r.vendor!=0x1002){partial=1;continue;}
        int duplicate=-1;
        for(unsigned j=0;j<used;++j)if(r.bus==readings[j].bus&&r.slot==readings[j].slot&&r.function==readings[j].function)duplicate=(int)j;
        if(duplicate>=0){struct adl_reading *old=&readings[duplicate];
            if(!r.strong||!old->strong||r.device!=old->device||strcmp(r.key,old->key)){++old->aliases;old->strong=0;old->partial=1;old->has_activity=old->has_temperature=old->has_power=0;
                old->has_fan_percent=old->has_fan_rpm=0;old->engine=old->memory=old->utilization=-1;partial=1;continue;}
            int aliases=old->aliases+1;
            if((!old->has_activity&&!old->has_temperature&&!old->has_power)&&(r.has_activity||r.has_temperature||r.has_power))*old=r;
            old->aliases=aliases;continue;
        }
        readings[used++]=r;partial|=r.partial;
    }
    /* Logical adapter indices can be reused during a hotplug. Re-enumerate
     * after all reads so numeric telemetry cannot cross an index change. */
    int after=-1;status=api.two?api.count2(api.context,&after):api.count1(&after);
    if(status||after!=total)return "adl_identity_changed";
    wtop_AdapterInfo confirmed[ADL_MAX_ADAPTERS];memset(confirmed,0,sizeof(confirmed));
    for(int i=0;i<count;++i)confirmed[i].iSize=sizeof(confirmed[i]);
    if(count&&(api.two?api.info2(api.context,confirmed,count*(int)sizeof(confirmed[0]))
        :api.info1(confirmed,count*(int)sizeof(confirmed[0]))))return "adl_device_list_failed";
    for(int i=0;i<count;++i){int matched=0;
        for(int j=0;j<count;++j)if(adl_same_identity(&info[i],&confirmed[j]))++matched;
        if(matched!=1)return "adl_identity_changed";
    }
    gpu_table(out,0,6);string_field(out,"source","adl");string_field(out,"initialization",api.two?"adl2":"adl1");
    boolean_field(out,"truncated",total>ADL_MAX_ADAPTERS);string_field(out,"status",partial?"partial":"ok");
    if(partial)string_field(out,"reason","adl_data_incomplete");
    gpu_table(out,(int)used,0);for(unsigned i=0;i<used;++i)adl_emit(out,&readings[i],(int)i+1);gpu_field_attach(out,"devices");
    return out->failed?(out->failed==2?"adl_allocation_failed":"adl_output_too_large"):NULL;
}
