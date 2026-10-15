/* Read-only Level Zero Sysman, using complete verified SDK layouts.
 * SDK calls remain shared by explicit low-level fixtures and the isolated
 * default reader. A Sysman handle is never guessed from a standalone core
 * handle, devices join by PCI address, and overlapping power domains are not
 * summed. See wtop_levelzero_abi.h and the SDK layout/function fixtures. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <limits.h>
#include "wtop_levelzero_abi.h"
#include "wtop_gpu_output.h"
#ifndef WTOP_GPU_WORKER
#include <lua.h>
#include <lauxlib.h>
#include "wtop_levelzero.h"
#include "wtop_gpu_lua.h"
#endif
const char wtop_levelzero_abi_license[]="MIT License\n\nCopyright (C) 2019-2026 Intel Corporation\n\nPermission is hereby granted, free of charge, to any person obtaining a copy\nof this software and associated documentation files (the \"Software\"), to deal\nin the Software without restriction, including without limitation the rights\nto use, copy, modify, merge, publish, distribute, sublicense, and/or sell\ncopies of the Software, and to permit persons to whom the Software is\nfurnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all\ncopies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\nIMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\nFITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\nAUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\nLIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\nOUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\nSOFTWARE.\n";

#if defined(__clang__)
#define L0_ABI __attribute__((no_sanitize("function")))
#else
#define L0_ABI
#endif
#define L0_DRIVERS 8
#define L0_DEVICES 64
#define L0_DOMAINS 32
#define L0_LOST UINT32_C(0x70000001)
#define L0_UNINITIALIZED UINT32_C(0x78000001)
#define L0_UNSUPPORTED UINT32_C(0x78000003)
typedef void *l0_handle;
typedef uint32_t (*l0_init_fn)(uint32_t);
typedef uint32_t (*l0_drivers_fn)(uint32_t *,l0_handle *);
typedef uint32_t (*l0_enum_fn)(l0_handle,uint32_t *,l0_handle *);
typedef uint32_t (*l0_output_fn)(l0_handle,void *);
typedef uint32_t (*l0_temperature_fn)(l0_handle,double *);
typedef uint32_t (*l0_card_fn)(l0_handle,l0_handle *);
typedef uint32_t (*l0_limits_ext_fn)(l0_handle,uint32_t *,wtop_zes_power_limit_ext_desc_t *);
typedef uint32_t (*l0_limits_fn)(l0_handle,wtop_zes_power_sustained_limit_t *,
    wtop_zes_power_burst_limit_t *,wtop_zes_power_peak_limit_t *);
struct l0_power_cursor {l0_handle power;uint64_t energy,timestamp;};
struct l0_cursor {
    l0_handle device;char identity[64];unsigned count;
    struct l0_power_cursor powers[L0_DOMAINS];
};
struct l0_api {
    void *library;int ready,legacy,lost;
    l0_drivers_fn drivers;
    l0_enum_fn devices,temperatures,frequencies,powers;
    l0_output_fn properties,pci,temp_properties,freq_properties,freq_state,power_properties,energy;
    l0_temperature_fn temperature;
    l0_card_fn card;
    l0_limits_fn limits;
    l0_limits_ext_fn limits_ext;
    struct l0_cursor cursors[L0_DEVICES];
};
static void l0_close(struct l0_api *a) {
    void *library=a->library;memset(a,0,sizeof(*a));if(library)dlclose(library);
}
static int l0_ok(struct l0_api *a,uint32_t result) {
    if(result==L0_LOST||result==L0_UNINITIALIZED)a->lost=1;
    return result==0;
}
L0_ABI static const char *l0_open(struct l0_api *a,int legacy) {
    if(a->ready)return NULL;
    if(a->library)l0_close(a);
    a->legacy=legacy;
    a->library=dlopen("libze_loader.so.1",RTLD_NOW|RTLD_LOCAL);
    if(!a->library)a->library=dlopen("libze_loader.so",RTLD_NOW|RTLD_LOCAL);
    if(!a->library)return "levelzero_library_not_found";
    l0_init_fn init=(l0_init_fn)dlsym(a->library,legacy?"zeInit":"zesInit");
    a->drivers=(l0_drivers_fn)dlsym(a->library,legacy?"zeDriverGet":"zesDriverGet");
    a->devices=(l0_enum_fn)dlsym(a->library,legacy?"zeDeviceGet":"zesDeviceGet");
    if(!init||!a->drivers||!a->devices)return legacy?"levelzero_symbols_missing":"levelzero_legacy_required";
    uint32_t status=init(legacy?1u:0u);
    if(!legacy&&status==L0_UNSUPPORTED)return "levelzero_legacy_required";
    if(status)return "levelzero_initialization_failed";
#define RESOLVE(field,type,name) a->field=(type)dlsym(a->library,name)
    RESOLVE(properties,l0_output_fn,"zesDeviceGetProperties");
    RESOLVE(pci,l0_output_fn,"zesDevicePciGetProperties");
    RESOLVE(temperatures,l0_enum_fn,"zesDeviceEnumTemperatureSensors");
    RESOLVE(temp_properties,l0_output_fn,"zesTemperatureGetProperties");
    RESOLVE(temperature,l0_temperature_fn,"zesTemperatureGetState");
    RESOLVE(frequencies,l0_enum_fn,"zesDeviceEnumFrequencyDomains");
    RESOLVE(freq_properties,l0_output_fn,"zesFrequencyGetProperties");
    RESOLVE(freq_state,l0_output_fn,"zesFrequencyGetState");
    RESOLVE(powers,l0_enum_fn,"zesDeviceEnumPowerDomains");
    RESOLVE(power_properties,l0_output_fn,"zesPowerGetProperties");
    RESOLVE(card,l0_card_fn,"zesDeviceGetCardPowerDomain");
    RESOLVE(energy,l0_output_fn,"zesPowerGetEnergyCounter");
    RESOLVE(limits,l0_limits_fn,"zesPowerGetLimits");
    RESOLVE(limits_ext,l0_limits_ext_fn,"zesPowerGetLimitsExt");
#undef RESOLVE
    a->ready=1;return NULL;
}
static int l0_number(double value,double maximum) {return isfinite(value)&&value>=0&&value<maximum;}
static void l0_text(gpu_output *out,const char *key,const char *value,size_t capacity) {
    const char *end=memchr(value,0,capacity);if(end&&end!=value&&(size_t)(end-value)<=256)string_field(out,key,value);
}
static void l0_uuid(char text[64],const uint8_t *uuid) {
    unsigned zero=0,ones=0;for(unsigned i=0;i<16;++i){zero+=uuid[i]==0;ones+=uuid[i]==255;}
    if(zero==16||ones==16)return;
    for(unsigned i=0;i<16;++i)snprintf(text+i*2,3,"%02x",uuid[i]);
}
L0_ABI static unsigned l0_enumerate(struct l0_api *a,l0_enum_fn function,l0_handle device,
    l0_handle handles[L0_DOMAINS],int *partial,int *truncated) {
    if(a->lost)return 0;
    uint32_t total=0;if(!l0_ok(a,function(device,&total,NULL))){*partial=1;return 0;}
    if(total>L0_DOMAINS)*partial=*truncated=1;
    uint32_t capacity=total<L0_DOMAINS?total:L0_DOMAINS,count=capacity;
    if(!capacity)return 0;
    memset(handles,0,sizeof(*handles)*L0_DOMAINS);
    if(!l0_ok(a,function(device,&count,handles))||count>capacity){*partial=1;if(count>capacity)*truncated=1;return 0;}
    if(count!=capacity)*partial=1;
    unsigned used=0;
    for(uint32_t i=0;i<count;++i){
        int duplicate=0;for(unsigned j=0;j<used;++j)duplicate|=handles[j]==handles[i];
        if(!handles[i]||duplicate){*partial=1;continue;}handles[used++]=handles[i];
    }
    return used;
}
L0_ABI static void l0_temperatures(struct l0_api *a,l0_handle device,gpu_output *out,int *partial,int *truncated) {
    if(!a->temperatures||!a->temp_properties||!a->temperature)return;
    l0_handle handles[L0_DOMAINS];unsigned count=l0_enumerate(a,a->temperatures,device,handles,partial,truncated);
    double hottest=-274;
    for(unsigned i=0;i<count;++i){
        if(a->lost)break;
        wtop_zes_temp_properties_t props;memset(&props,0xff,sizeof(props));props.stype=0x14;props.pNext=NULL;
        if(!l0_ok(a,a->temp_properties(handles[i],&props))){*partial=1;continue;}
        if(props.type!=1||props.onSubdevice>1)continue;
        double temperature=NAN;
        if(l0_ok(a,a->temperature(handles[i],&temperature))&&isfinite(temperature)&&temperature>-274&&temperature<1000){
            if(temperature>hottest)hottest=temperature;
        } else *partial=1;
    }
    if(hottest>-274)number_field(out,"temperature_celsius",hottest);
}
static const char *l0_frequency_kind(uint32_t type) {return type==0?"gpu":type==1?"memory":type==2?"media":"unknown";}
L0_ABI static void l0_frequencies(struct l0_api *a,l0_handle device,gpu_output *out,int *partial,int *truncated) {
    if(!a->frequencies||!a->freq_properties||!a->freq_state)return;
    l0_handle handles[L0_DOMAINS];unsigned count=l0_enumerate(a,a->frequencies,device,handles,partial,truncated);
    double root_gpu=0,root_memory=0;unsigned gpu_count=0,memory_count=0;
    gpu_table(out,(int)count,0);int returned=0;
    for(unsigned i=0;i<count;++i){
        if(a->lost)break;
        wtop_zes_freq_properties_t props;memset(&props,0xff,sizeof(props));props.stype=9;props.pNext=NULL;
        if(!l0_ok(a,a->freq_properties(handles[i],&props))||props.onSubdevice>1){*partial=1;continue;}
        wtop_zes_freq_state_t state;memset(&state,0xff,sizeof(state));state.stype=0x1b;state.pNext=NULL;
        int valid=l0_ok(a,a->freq_state(handles[i],&state));if(!valid)*partial=1;
        gpu_table(out,0,15);integer_field(out,"index",i);string_field(out,"kind",l0_frequency_kind(props.type));
        boolean_field(out,"on_subdevice",props.onSubdevice);if(props.onSubdevice)integer_field(out,"subdevice_id",props.subdeviceId);
        if(l0_number(props.min,100000))number_field(out,"minimum_hz",props.min*1e6);
        if(l0_number(props.max,100000)&&props.max>=props.min)number_field(out,"maximum_hz",props.max*1e6);
        if(valid&&l0_number(state.actual,100000)){
            number_field(out,"actual_hz",state.actual*1e6);
            if(!props.onSubdevice&&props.type==0){root_gpu=state.actual*1e6;++gpu_count;}
            if(!props.onSubdevice&&props.type==1){root_memory=state.actual*1e6;++memory_count;}
        }
        if(valid&&l0_number(state.request,100000))number_field(out,"requested_hz",state.request*1e6);
        if(valid&&props.isThrottleEventSupported==1&&state.throttleReasons!=UINT32_MAX){
            char text[19];snprintf(text,sizeof(text),"0x%016llx",(unsigned long long)state.throttleReasons);
            string_field(out,"throttle_raw_hex",text);string_field(out,"throttle_quality","fresh");
        } else string_field(out,"throttle_quality",valid?"unavailable":"error");
        gpu_index(out,++returned);
    }
    gpu_field_attach(out,"frequency_domains");
    if(gpu_count==1)number_field(out,"graphics_clock_hz",root_gpu);
    if(memory_count==1)number_field(out,"memory_clock_hz",root_memory);
}
static const char *l0_power_kind(uint32_t domain) {
    return domain==1?"card":domain==2?"package":domain==3?"stack":domain==4?"memory":domain==5?"gpu":"unknown";
}
struct l0_power_read {
    l0_handle handle;
    wtop_zes_power_properties_t properties;
    wtop_zes_power_energy_counter_t energy;
    wtop_zes_power_sustained_limit_t sustained;
    wtop_zes_power_burst_limit_t burst;
    wtop_zes_power_peak_limit_t peak;
    wtop_zes_power_limit_ext_desc_t limits[16];
    unsigned limits_count;
    uint32_t domain;
    int legacy_limits,energy_valid,selected_rank;
    double watts,cap;
    uint64_t interval_us;
    const char *quality,*reason;
};
static void l0_energy(struct l0_power_read *r,const struct l0_cursor *old,struct l0_cursor *next) {
    r->quality="unavailable";
    if(!r->energy_valid)return;
    const struct l0_power_cursor *before=NULL;
    for(unsigned i=0;old&&i<old->count;++i)if(old->powers[i].power==r->handle)before=&old->powers[i];
    struct l0_power_cursor cursor={r->handle,r->energy.energy,r->energy.timestamp};
    r->quality="gap";r->reason="levelzero_power_warmup";
    if(before){
        if(r->energy.timestamp<=before->timestamp||r->energy.energy<before->energy)
            r->reason="levelzero_energy_counter_reset";
        else {
            uint64_t delta=r->energy.timestamp-before->timestamp;
            if(delta<100000){cursor=*before;}
            else if(delta>5000000)r->reason="levelzero_energy_counter_gap";
            else {
                double watts=(double)(r->energy.energy-before->energy)/(double)delta;
                if(l0_number(watts,100000)){r->watts=watts;r->interval_us=delta;r->quality="fresh";r->reason=NULL;}
                else r->reason="levelzero_energy_counter_invalid";
            }
        }
    }
    if(next->count<L0_DOMAINS)next->powers[next->count++]=cursor;
}
L0_ABI static void l0_limits(struct l0_api *a,struct l0_power_read *r,int *partial,int *truncated) {
    if(a->lost)return;
    if(a->limits_ext){
        uint32_t total=0;
        if(l0_ok(a,a->limits_ext(r->handle,&total,NULL))){
            if(total>16)*partial=*truncated=1;
            uint32_t capacity=total<16?total:16,count=capacity;
            for(unsigned i=0;i<16;++i){memset(&r->limits[i],0xff,sizeof(r->limits[i]));r->limits[i].stype=0x27;r->limits[i].pNext=NULL;}
            if(!capacity)return;
            if(!l0_ok(a,a->limits_ext(r->handle,&count,r->limits))||count>capacity){*partial=1;return;}
            r->limits_count=count;unsigned caps=0;
            for(unsigned i=0;i<count;++i){
                const wtop_zes_power_limit_ext_desc_t *v=&r->limits[i];
                if(v->level==1&&v->source==0&&v->limitUnit==2&&v->enabled==1&&v->limit>0){r->cap=(double)v->limit/1000.0;++caps;}
            }
            if(caps!=1)r->cap=0;
            return;
        }
    }
    if(!a->lost&&a->limits&&l0_ok(a,a->limits(r->handle,&r->sustained,&r->burst,&r->peak))){
        r->legacy_limits=1;
        if(r->sustained.enabled==1&&r->sustained.power>0)r->cap=(double)r->sustained.power/1000.0;
    }
}
static void l0_emit_limits(gpu_output *out,const struct l0_power_read *r) {
    if(r->legacy_limits){
        if(r->sustained.enabled<=1)boolean_field(out,"sustained_enabled",r->sustained.enabled);
        if(r->sustained.power>=0)number_field(out,"sustained_limit_watts",(double)r->sustained.power/1000.0);
        if(r->sustained.interval>=0)number_field(out,"sustained_window_seconds",(double)r->sustained.interval/1000.0);
        if(r->burst.enabled<=1)boolean_field(out,"burst_enabled",r->burst.enabled);
        if(r->burst.power>=0)number_field(out,"burst_limit_watts",(double)r->burst.power/1000.0);
        if(r->peak.powerAC>=0)number_field(out,"peak_ac_watts",(double)r->peak.powerAC/1000.0);
        if(r->peak.powerDC>=0)number_field(out,"peak_dc_watts",(double)r->peak.powerDC/1000.0);
    }
    gpu_table(out,(int)r->limits_count,0);
    for(unsigned i=0;i<r->limits_count;++i){
        const wtop_zes_power_limit_ext_desc_t *v=&r->limits[i];gpu_table(out,0,8);
        integer_field(out,"level_code",v->level);integer_field(out,"source_code",v->source);integer_field(out,"unit_code",v->limitUnit);
        if(v->enabled<=1)boolean_field(out,"enabled",v->enabled);
        if(v->interval>=0)number_field(out,"window_seconds",(double)v->interval/1000.0);
        if(v->limit>=0&&v->limitUnit==2)number_field(out,"watts",(double)v->limit/1000.0);
        else if(v->limit>=0&&v->limitUnit==1)number_field(out,"amperes",(double)v->limit/1000.0);
        gpu_index(out,(int)i+1);
    }
    gpu_field_attach(out,"limits");
}
L0_ABI static void l0_powers(struct l0_api *a,l0_handle device,const struct l0_cursor *old,
    struct l0_cursor *next,gpu_output *out,int *partial,int *truncated) {
    if(!a->powers||!a->power_properties)return;
    l0_handle handles[L0_DOMAINS],card=NULL;unsigned count=l0_enumerate(a,a->powers,device,handles,partial,truncated);
    if(!a->lost&&a->card&&!l0_ok(a,a->card(device,&card)))card=NULL;
    struct l0_power_read readings[L0_DOMAINS];memset(readings,0,sizeof(readings));
    unsigned used=0;int best=INT_MAX,selected=-1,ties=0;
    for(unsigned i=0;i<count;++i){
        if(a->lost)break;
        struct l0_power_read r;memset(&r,0,sizeof(r));r.handle=handles[i];r.selected_rank=INT_MAX;
        wtop_zes_power_ext_properties_t ext;memset(&ext,0,sizeof(ext));ext.stype=0x28;ext.domain=UINT32_MAX;
        memset(&r.properties,0xff,sizeof(r.properties));r.properties.stype=0xd;r.properties.pNext=&ext;
        int ok=l0_ok(a,a->power_properties(r.handle,&r.properties));
        if(!ok&&!a->lost){r.properties.pNext=NULL;ok=l0_ok(a,a->power_properties(r.handle,&r.properties));}
        if(!ok||r.properties.onSubdevice>1){*partial=1;continue;}
        r.domain=ext.domain<=5?ext.domain:0;
        if(r.handle==card)r.domain=1;
        if(!r.properties.onSubdevice)r.selected_rank=r.domain==1?0:r.domain==2?1:r.domain==5?2:r.domain==0?3:INT_MAX;
        memset(&r.energy,0xff,sizeof(r.energy));
        r.energy_valid=a->energy&&l0_ok(a,a->energy(r.handle,&r.energy))
            &&r.energy.energy!=UINT64_MAX&&r.energy.timestamp!=UINT64_MAX&&r.energy.timestamp>0;
        if(a->energy&&!r.energy_valid)*partial=1;
        l0_energy(&r,old,next);
        memset(&r.sustained,0xff,sizeof(r.sustained));memset(&r.burst,0xff,sizeof(r.burst));memset(&r.peak,0xff,sizeof(r.peak));
        l0_limits(a,&r,partial,truncated);
        if(r.selected_rank<best){best=r.selected_rank;selected=(int)used;ties=1;}
        else if(r.selected_rank==best)++ties;
        readings[used++]=r;
    }
    gpu_table(out,(int)used,0);
    for(unsigned i=0;i<used;++i){
        const struct l0_power_read *r=&readings[i];gpu_table(out,0,18);
        integer_field(out,"index",i);string_field(out,"scope",l0_power_kind(r->domain));
        boolean_field(out,"on_subdevice",r->properties.onSubdevice);
        if(r->properties.onSubdevice)integer_field(out,"subdevice_id",r->properties.subdeviceId);
        string_field(out,"quality",r->quality);if(r->reason)string_field(out,"reason",r->reason);
        if(r->energy_valid){
            if(r->energy.energy<=INT64_MAX)integer_field(out,"energy_microjoules",(int64_t)r->energy.energy);
            else {char hex[19];snprintf(hex,sizeof(hex),"0x%016llx",(unsigned long long)r->energy.energy);string_field(out,"energy_raw_hex",hex);}
            if(r->energy.timestamp<=INT64_MAX)integer_field(out,"counter_timestamp_us",(int64_t)r->energy.timestamp);
        }
        if(r->interval_us){number_field(out,"power_watts",r->watts);integer_field(out,"interval_ns",(int64_t)(r->interval_us*1000));}
        l0_emit_limits(out,r);gpu_index(out,(int)i+1);
    }
    gpu_field_attach(out,"power_domains");
    if(ties==1&&selected>=0&&best!=INT_MAX){
        const struct l0_power_read *r=&readings[selected];string_field(out,"power_scope",l0_power_kind(r->domain));
        integer_field(out,"power_domain_index",selected);string_field(out,"power_quality",r->quality);
        if(r->reason)string_field(out,"power_reason",r->reason);
        if(r->interval_us){
            number_field(out,"power_watts",r->watts);string_field(out,"power_measurement","average");
            integer_field(out,"power_interval_ns",(int64_t)(r->interval_us*1000));
            if(r->domain==1)number_field(out,"board_power_watts",r->watts);
        }
        if(r->cap>0&&r->cap<100000)number_field(out,"power_limit_watts",r->cap);
    } else if(used){string_field(out,"power_quality","unavailable");string_field(out,"power_reason","levelzero_power_domain_ambiguous");}
}
struct l0_device {l0_handle handle,driver;};
L0_ABI static const char *l0_devices(struct l0_api *a,struct l0_device devices[L0_DEVICES],
    unsigned *used,unsigned *driver_total,int *partial,int *truncated) {
    uint32_t total=0;if(!l0_ok(a,a->drivers(&total,NULL)))return "levelzero_driver_enumeration_failed";
    *driver_total=total;if(total>L0_DRIVERS)*partial=*truncated=1;
    uint32_t capacity=total<L0_DRIVERS?total:L0_DRIVERS,count=capacity;
    l0_handle drivers[L0_DRIVERS]={0};
    if(!capacity)return NULL;
    if(!l0_ok(a,a->drivers(&count,drivers))||count>capacity)return "levelzero_driver_enumeration_failed";
    for(uint32_t i=0;i<count;++i){
        if(!drivers[i]){*partial=1;continue;}
        total=0;if(!l0_ok(a,a->devices(drivers[i],&total,NULL))){*partial=1;continue;}
        if(total>L0_DEVICES)*partial=*truncated=1;
        uint32_t size=total<L0_DEVICES?total:L0_DEVICES,amount=size;l0_handle handles[L0_DEVICES]={0};
        if(!size)continue;
        if(!l0_ok(a,a->devices(drivers[i],&amount,handles))||amount>size){*partial=1;continue;}
        for(uint32_t j=0;j<amount;++j){
            int duplicate=0;for(unsigned k=0;k<*used;++k)duplicate|=devices[k].handle==handles[j]&&devices[k].driver==drivers[i];
            if(!handles[j]||duplicate){*partial=1;continue;}
            if(*used==L0_DEVICES){*partial=*truncated=1;continue;}
            devices[*used]=(struct l0_device){handles[j],drivers[i]};++*used;
        }
    }
    return NULL;
}
L0_ABI static const char *l0_collect(struct l0_api *a,gpu_output *out) {
    struct l0_device devices[L0_DEVICES];unsigned count=0,drivers=0;int partial=0,truncated=0;
    const char *reason=l0_devices(a,devices,&count,&drivers,&partial,&truncated);if(reason)return reason;
    struct l0_cursor pending[L0_DEVICES];memset(pending,0,sizeof(pending));
    char bdfs[L0_DEVICES][20]={{0}};unsigned returned=0;
    gpu_table(out,0,8);string_field(out,"initialization",a->legacy?"core_legacy":"sysman");integer_field(out,"driver_count",drivers);
    gpu_table(out,(int)count,0);
    for(unsigned i=0;i<count;++i){
        l0_handle device=devices[i].handle;
        wtop_zes_device_properties_t properties;memset(&properties,0xff,sizeof(properties));
        properties.stype=1;properties.pNext=NULL;properties.core.stype=3;properties.core.pNext=NULL;
        int identified=a->properties&&l0_ok(a,a->properties(device,&properties));
        if(identified&&properties.core.type!=1){partial=1;continue;}
        wtop_zes_pci_properties_t pci;memset(&pci,0xff,sizeof(pci));pci.stype=2;pci.pNext=NULL;
        int pci_valid=a->pci&&l0_ok(a,a->pci(device,&pci))&&pci.address.domain<=0xffff
            &&pci.address.bus<=255&&pci.address.device<=31&&pci.address.function<=7;
        char bdf[20]={0},uuid[64]={0};
        if(pci_valid)snprintf(bdf,sizeof(bdf),"%04x:%02x:%02x.%x",pci.address.domain,pci.address.bus,pci.address.device,pci.address.function);
        if(identified)l0_uuid(uuid,properties.core.uuid.id);
        int duplicate=0;
        for(unsigned j=0;j<returned;++j)duplicate|=(bdf[0]&&!strcmp(bdf,bdfs[j]))||(uuid[0]&&!strcmp(uuid,pending[j].identity));
        if(duplicate){partial=1;continue;}
        memcpy(bdfs[returned],bdf,sizeof(bdf));
        struct l0_cursor *next=&pending[returned];next->device=device;
        snprintf(next->identity,sizeof(next->identity),"%s",uuid[0]?uuid:bdf);
        if(!next->identity[0])snprintf(next->identity,sizeof(next->identity),"opaque:%p:%p",devices[i].driver,device);
        const struct l0_cursor *old=NULL;
        for(unsigned j=0;j<L0_DEVICES;++j)if(a->cursors[j].device==device&&!strcmp(a->cursors[j].identity,next->identity))old=&a->cursors[j];
        gpu_table(out,0,22);integer_field(out,"index",i);
        if(bdf[0])string_field(out,"pci_bdf",bdf);
        if(uuid[0])string_field(out,"uuid",uuid);
        if(identified){
            l0_text(out,"name",properties.core.name,sizeof(properties.core.name));
            l0_text(out,"vendor_name",properties.vendorName,sizeof(properties.vendorName));
            l0_text(out,"driver_version",properties.driverVersion,sizeof(properties.driverVersion));
            if(properties.core.vendorId<=0xffff)integer_field(out,"vendor_id",properties.core.vendorId);
            if(properties.core.deviceId<=0xffff)integer_field(out,"device_id",properties.core.deviceId);
            if(properties.numSubdevices<1024)integer_field(out,"subdevice_count",properties.numSubdevices);
        }
        l0_temperatures(a,device,out,&partial,&truncated);
        if(a->lost)return "levelzero_device_lost";
        l0_frequencies(a,device,out,&partial,&truncated);
        if(a->lost)return "levelzero_device_lost";
        l0_powers(a,device,old,next,out,&partial,&truncated);
        gpu_index(out,(int)++returned);
        if(a->lost)return "levelzero_device_lost";
    }
    gpu_field_attach(out,"devices");string_field(out,"source","levelzero");string_field(out,"status",partial?"partial":"ok");
    boolean_field(out,"truncated",truncated);if(partial)string_field(out,"reason","levelzero_data_incomplete");
    if(out->failed)return out->failed==2?"levelzero_allocation_failed":"levelzero_output_too_large";
    memcpy(a->cursors,pending,sizeof(pending));return NULL;
}
#ifdef WTOP_GPU_WORKER
#include "wtop_gpu_worker.h"
static struct l0_api worker_api;
const char *wtop_levelzero_prepare(int legacy) {return l0_open(&worker_api,legacy);}
const char *wtop_levelzero_collect(gpu_output *out,int processes) {(void)processes;return l0_collect(&worker_api,out);}
void wtop_levelzero_finish(void) {l0_close(&worker_api);}
#else
static char l0_registry_key;
static int l0_gc(lua_State *L) {l0_close(lua_touserdata(L,1));return 0;}
static struct l0_api *l0_context(lua_State *L) {
    lua_rawgetp(L,LUA_REGISTRYINDEX,&l0_registry_key);
    if(lua_isuserdata(L,-1)){struct l0_api *api=lua_touserdata(L,-1);lua_pop(L,1);return api;}
    lua_pop(L,1);struct l0_api *api=lua_newuserdatauv(L,sizeof(*api),0);memset(api,0,sizeof(*api));
    lua_newtable(L);lua_pushcfunction(L,l0_gc);lua_setfield(L,-2,"__gc");lua_setmetatable(L,-2);
    lua_rawsetp(L,LUA_REGISTRYINDEX,&l0_registry_key);return api;
}
int wtop_levelzero_query(lua_State *L) {
    struct l0_api *api=l0_context(L);const char *setting=getenv("ZES_ENABLE_SYSMAN");
    const char *reason=l0_open(api,setting&&!strcmp(setting,"1"));gpu_output out={L,0,gpu_lua_emit};
    if(!reason)reason=l0_collect(api,&out);
    if(reason){if(api->lost)l0_close(api);lua_pushnil(L);lua_pushstring(L,reason);return 2;}
    return 1;
}
#endif
