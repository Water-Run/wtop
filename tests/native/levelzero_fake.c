#define _POSIX_C_SOURCE 200809L
#ifdef WTOP_LEVELZERO_SDK_HEADER
#include WTOP_LEVELZERO_SDK_HEADER
#else
#include "../fixtures/levelzero/sdk.h"
#endif
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
static int mode,stage,walk,manual;
static uint64_t tick=1000000;
static void hang(void) {for(;;)pause();}
__attribute__((constructor)) static void setup(void) {
    const char *s=getenv("WTOP_LEVELZERO_FIXTURE_MODE");mode=s?atoi(s):0;
    if(mode==40)hang();
    if(mode==46){puts("driver noise");fputs("driver stderr\n",stderr);fflush(stdout);fflush(stderr);}
    if(mode==47){const char bytes[]="corrupt frame";ssize_t sent=write(3,bytes,sizeof(bytes));(void)sent;}
    if(mode==48){uint32_t header[16]={0x4d4e5457,2,UINT32_MAX};ssize_t sent=write(3,header,sizeof(header));(void)sent;}
    const char *audit=getenv("WTOP_LEVELZERO_FIXTURE_AUDIT");
    if(audit){FILE *f=fopen(audit,"a");if(f){fprintf(f,"pid=%ld legacy=%d\n",(long)getpid(),getenv("ZES_ENABLE_SYSMAN")!=NULL);fclose(f);}}
}
__attribute__((destructor)) static void finish(void) {if(mode==45)hang();}
void fixture_mode(int value) {mode=value;walk=0;}
void fixture_tick(uint64_t value) {manual=1;tick=value;}
static uint64_t clock_us(void) {if(manual)return tick;struct timespec t;assert(!clock_gettime(CLOCK_MONOTONIC,&t));return (uint64_t)t.tv_sec*1000000u+(uint64_t)t.tv_nsec/1000u;}
ze_result_t zeInit(ze_init_flags_t flags) {
    assert(flags==1&&(stage==0||stage==1));assert(getenv("ZES_ENABLE_SYSMAN")&&!strcmp(getenv("ZES_ENABLE_SYSMAN"),"1"));
    if(mode==41)hang();
    stage=1;return ZE_RESULT_SUCCESS;
}
#ifndef WTOP_LEVELZERO_LEGACY
ze_result_t zesInit(zes_init_flags_t flags) {
    assert(flags==0&&(stage==0||stage==2)&&!getenv("ZES_ENABLE_SYSMAN"));
    if(mode==2||mode==49)return ZE_RESULT_ERROR_UNSUPPORTED_FEATURE;
    if(mode==41)hang();
    stage=2;return ZE_RESULT_SUCCESS;
}
#endif
static unsigned device_id(uintptr_t handle) {assert(stage);uintptr_t start=stage==2?0x4000u:0x2000u;assert(handle>=start&&handle<start+3);return (unsigned)(handle-start);}
static ze_result_t drivers(uint32_t *n,void **out) {
    assert(stage&&n);if(mode==42)hang();
    if(!out){*n=2;++walk;return ZE_RESULT_SUCCESS;}
    unsigned take=*n<2?*n:2;for(unsigned i=0;i<take;++i)out[i]=(void *)(uintptr_t)(0x100u+i);*n=take;return ZE_RESULT_SUCCESS;
}
static ze_result_t devices(uintptr_t driver,uint32_t *n,void **out) {
    assert(stage&&n&&driver>=0x100&&driver<=0x101);unsigned total=driver==0x100?2:1;
    if(!out){*n=total;return ZE_RESULT_SUCCESS;}
    unsigned take=*n<total?*n:total;
    for(unsigned i=0;i<take;++i){unsigned id=driver==0x101?2:(mode==20&&(walk&1)?1-i:i);out[i]=(void *)(uintptr_t)((stage==2?0x4000u:0x2000u)+id);}
    *n=take;return ZE_RESULT_SUCCESS;
}
ze_result_t zeDriverGet(uint32_t *n,ze_driver_handle_t *h) {assert(stage==1);return drivers(n,(void **)h);}
ze_result_t zeDeviceGet(ze_driver_handle_t h,uint32_t *n,ze_device_handle_t *d) {assert(stage==1);return devices((uintptr_t)h,n,(void **)d);}
#ifndef WTOP_LEVELZERO_LEGACY
ze_result_t zesDriverGet(uint32_t *n,zes_driver_handle_t *h) {assert(stage==2);return drivers(n,(void **)h);}
ze_result_t zesDeviceGet(zes_driver_handle_t h,uint32_t *n,zes_device_handle_t *d) {assert(stage==2);return devices((uintptr_t)h,n,(void **)d);}
#endif
ze_result_t zesDeviceGetProperties(zes_device_handle_t h,zes_device_properties_t *p) {
    unsigned id=device_id((uintptr_t)h);assert(p&&p->stype==1&&p->pNext==NULL&&p->core.stype==3&&p->core.pNext==NULL);
    memset(p,0,sizeof(*p));p->core.type=1;p->core.vendorId=0x8086;p->core.deviceId=0x5600+id;
    p->core.uuid.id[15]=(uint8_t)(mode==9?1:id+1);snprintf(p->core.name,sizeof(p->core.name),"SDK GPU %c",'A'+(int)id);
    strcpy(p->vendorName,"Intel");strcpy(p->driverVersion,"verified SDK fixture");strcpy(p->serialNumber,"PRIVATE-SERIAL");strcpy(p->boardNumber,"PRIVATE-BOARD");return ZE_RESULT_SUCCESS;
}
ze_result_t zesDevicePciGetProperties(zes_device_handle_t h,zes_pci_properties_t *p) {
    unsigned id=device_id((uintptr_t)h);assert(p&&p->stype==2&&p->pNext==NULL);if(mode==6)return ZE_RESULT_ERROR_INSUFFICIENT_PERMISSIONS;
    memset(p,0,sizeof(*p));p->address.bus=mode==8?3:3+id;p->maxSpeed.gen=4;p->maxSpeed.width=16;p->maxSpeed.maxBandwidth=32000000000LL;return ZE_RESULT_SUCCESS;
}
static ze_result_t domains(zes_device_handle_t device,uint32_t *n,void **out,unsigned base,unsigned total) {
    unsigned id=device_id((uintptr_t)device);assert(n);if(!out){*n=total;return ZE_RESULT_SUCCESS;}
    unsigned take=*n<total?*n:total;for(unsigned i=0;i<take;++i)out[i]=(void *)(uintptr_t)(base+id*16+i);*n=take;return ZE_RESULT_SUCCESS;
}
ze_result_t zesDeviceEnumTemperatureSensors(zes_device_handle_t h,uint32_t *n,zes_temp_handle_t *out) {return domains(h,n,(void **)out,0x6000,2);}
ze_result_t zesTemperatureGetProperties(zes_temp_handle_t h,zes_temp_properties_t *p) {
    uintptr_t x=(uintptr_t)h-0x6000;assert(x/16<3&&x%16<2&&p->stype==0x14&&p->pNext==NULL);
    memset(p,0,sizeof(*p));p->type=x%16?2:1;return ZE_RESULT_SUCCESS;
}
ze_result_t zesTemperatureGetState(zes_temp_handle_t h,double *p) {
    uintptr_t x=(uintptr_t)h-0x6000;assert(x/16<3&&x%16<2);if(mode==43)raise(SIGSEGV);
    *p=mode==7?NAN:x%16?99:50+(double)(x/16);return ZE_RESULT_SUCCESS;
}
ze_result_t zesDeviceEnumFrequencyDomains(zes_device_handle_t h,uint32_t *n,zes_freq_handle_t *out) {return domains(h,n,(void **)out,0x7000,3);}
ze_result_t zesFrequencyGetProperties(zes_freq_handle_t h,zes_freq_properties_t *p) {
    uintptr_t x=(uintptr_t)h-0x7000;assert(x/16<3&&x%16<3&&p->stype==9&&p->pNext==NULL);
    memset(p,0,sizeof(*p));p->type=x%16==1?1:0;p->onSubdevice=x%16==2;p->subdeviceId=1;p->isThrottleEventSupported=mode!=25;p->min=100;p->max=8000;return ZE_RESULT_SUCCESS;
}
ze_result_t zesFrequencyGetState(zes_freq_handle_t h,zes_freq_state_t *p) {
    uintptr_t x=(uintptr_t)h-0x7000;assert(x/16<3&&x%16<3&&p->stype==0x1b&&p->pNext==NULL);
    memset(p,0,sizeof(*p));p->actual=mode==10?-1:mode==11?NAN:x%16==1?6400:x%16==2?5000:800+(double)(x/16)*100;
    p->request=900;p->throttleReasons=mode==11?UINT32_MAX:1;return ZE_RESULT_SUCCESS;
}
ze_result_t zesDeviceEnumPowerDomains(zes_device_handle_t h,uint32_t *n,zes_pwr_handle_t *out) {return domains(h,n,(void **)out,0x8000,4);}
ze_result_t zesDeviceGetCardPowerDomain(zes_device_handle_t h,zes_pwr_handle_t *out) {
    unsigned id=device_id((uintptr_t)h);if(mode==12)return ZE_RESULT_ERROR_UNSUPPORTED_FEATURE;*out=(zes_pwr_handle_t)(uintptr_t)(0x8000u+id*16);return ZE_RESULT_SUCCESS;
}
ze_result_t zesPowerGetProperties(zes_pwr_handle_t h,zes_power_properties_t *p) {
    uintptr_t x=(uintptr_t)h-0x8000;assert(x/16<3&&x%16<4&&p->stype==0xd);
#ifdef WTOP_LEVELZERO_LEGACY
    if(p->pNext)return ZE_RESULT_ERROR_UNSUPPORTED_FEATURE;
#else
    if(p->pNext){zes_power_ext_properties_t *e=p->pNext;assert(e->stype==0x28);e->domain=(zes_power_domain_t)(x%16+1);e->defaultLimit=(zes_power_limit_ext_desc_t *)(uintptr_t)1;}
#endif
    void *next=p->pNext;memset(p,0,sizeof(*p));p->pNext=next;p->onSubdevice=x%16==2;p->subdeviceId=1;p->defaultLimit=40000;p->maxLimit=100000;p->canControl=1;return ZE_RESULT_SUCCESS;
}
ze_result_t zesPowerGetEnergyCounter(zes_pwr_handle_t h,zes_power_energy_counter_t *p) {
    uintptr_t x=(uintptr_t)h-0x8000;assert(x/16<3&&x%16<4);if(mode==44)hang();uint64_t t=clock_us();
    if(mode==24)return ZE_RESULT_ERROR_DEVICE_LOST;
    unsigned watts=x%16==0?30+(unsigned)(x/16)*10:x%16==1?10:x%16==2?5:2;
    p->energy=mode==13?UINT64_MAX:(mode==15?UINT64_C(0x8000000000000000):UINT64_C(1000000))+t*watts;p->timestamp=t;return ZE_RESULT_SUCCESS;
}
ze_result_t zesPowerGetLimits(zes_pwr_handle_t h,zes_power_sustained_limit_t *s,zes_power_burst_limit_t *b,zes_power_peak_limit_t *p) {
    uintptr_t x=(uintptr_t)h-0x8000;assert(x/16<3&&x%16<4);memset(s,0,sizeof(*s));memset(b,0,sizeof(*b));memset(p,0,sizeof(*p));
    s->enabled=1;s->power=40000;s->interval=28000;b->enabled=1;b->power=60000;p->powerAC=100000;p->powerDC=80000;return ZE_RESULT_SUCCESS;
}
#ifndef WTOP_LEVELZERO_LEGACY
ze_result_t zesPowerGetLimitsExt(zes_pwr_handle_t h,uint32_t *n,zes_power_limit_ext_desc_t *out) {
    uintptr_t x=(uintptr_t)h-0x8000;assert(x/16<3&&x%16<4);unsigned total=mode==19?2:1;
    if(!out){*n=total;return ZE_RESULT_SUCCESS;}unsigned take=*n<total?*n:total;
    for(unsigned i=0;i<take;++i){assert(out[i].stype==0x27&&out[i].pNext==NULL);memset(&out[i],0,sizeof(out[i]));out[i].level=(zes_power_level_t)1;out[i].source=(zes_power_source_t)(mode==17?1:0);out[i].limitUnit=(zes_limit_unit_t)(mode==16?1:2);out[i].enabled=mode!=18;out[i].interval=28000;out[i].limit=mode==16?1000:40000+(int)i*10000;}
    *n=take;return ZE_RESULT_SUCCESS;
}
#endif
