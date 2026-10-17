/* Independent driver fixture. It is never installed in a system directory. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#ifdef WTOP_ADL_SDK_HEADER
#include WTOP_ADL_SDK_HEADER
#else
#include "../fixtures/adl/sdk.h"
#endif
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
static int mode,info_calls,created;
static unsigned pm_created,pm_started,pm_reads,pm_queries,pm_stopped,pm_destroyed;
static unsigned int pm_handles[2];
static int pm_logging[2];
static void pm_trace(void){
    const char *path=getenv("WTOP_ADL_PMLOG_TRACE");if(!path)return;
    FILE *f=fopen(path,"wb");assert(f);
    assert(fprintf(f,"{\"created\":%u,\"started\":%u,\"reads\":%u,\"queries\":%u,\"stopped\":%u,\"destroyed\":%u,\"owned\":%u}\n",
        pm_created,pm_started,pm_reads,pm_queries,pm_stopped,pm_destroyed,
        (unsigned)(pm_handles[0]!=0)+(unsigned)(pm_handles[1]!=0))>0);assert(!fclose(f));
}
static void marker(const char *state){
    const char *root=getenv("WTOP_ADL_LIFECYCLE_MARKER");if(!root)return;
    char path[1024];int length=snprintf(path,sizeof(path),"%s.%s",root,state);
    assert(length>0&&(size_t)length<sizeof(path));
    FILETIME created_at,ended,kernel,user;
    assert(GetProcessTimes(GetCurrentProcess(),&created_at,&ended,&kernel,&user));
    unsigned long long birth=(unsigned long long)created_at.dwHighDateTime<<32|created_at.dwLowDateTime;
    FILE *file=fopen(path,"wb");assert(file);
    assert(fprintf(file,"{\"pid\":%lu,\"birth\":\"%llu\"}\n",(unsigned long)GetCurrentProcessId(),birth)>0);
    assert(!fclose(file));
}
static void control(void){
    const char *path=getenv("WTOP_ADL_FIXTURE_CONTROL");if(!path)return;
    FILE *file=fopen(path,"r");if(!file)return;
    int value;if(fscanf(file,"%d",&value)==1)mode=value;fclose(file);
}
static void hang(void){marker("blocked");Sleep(10000);}
__attribute__((constructor)) static void setup(void){const char *s=getenv("WTOP_ADL_FIXTURE_MODE");mode=s?atoi(s):0;marker("loaded");if(mode==40)hang();}
__attribute__((destructor)) static void finish(void){if(mode==45)hang();}
static int create(ADL_MAIN_MALLOC_CALLBACK callback,int connected){
    assert(callback&&connected==1);void *p=callback(32);assert(p);free(p);assert(!callback(-1));
    if(mode==41)hang();
    if(mode==2)return -2;
    created=1;return 0;
}
#ifndef WTOP_ADL_LEGACY
int ADL2_Main_Control_Create(ADL_MAIN_MALLOC_CALLBACK cb,int connected,void **ctx){int status=create(cb,connected);*ctx=status?NULL:(void *)(uintptr_t)0x1234;return status;}
int ADL2_Main_Control_Destroy(void *ctx){assert(created&&ctx==(void *)(uintptr_t)0x1234);created=0;memset(pm_handles,0,sizeof(pm_handles));memset(pm_logging,0,sizeof(pm_logging));pm_trace();return 0;}
#endif
int ADL_Main_Control_Create(ADL_MAIN_MALLOC_CALLBACK cb,int connected){return create(cb,connected);}
int ADL_Main_Control_Destroy(void){assert(created);created=0;memset(pm_handles,0,sizeof(pm_handles));memset(pm_logging,0,sizeof(pm_logging));pm_trace();return 0;}
static int count(int *total){control();assert(created&&total);if(mode==42)hang();if(mode==3)return -1;*total=mode==4?1000000:mode==25||((mode==76||mode==77||mode==85||mode==86)&&pm_reads>=4)?0:2;return 0;}
static int info(AdapterInfo *values,int bytes){
    assert(created&&values&&bytes==2*(int)sizeof(*values));if(mode==5)return -4;++info_calls;
    for(int i=0;i<2;++i){
        assert(values[i].iSize==(int)sizeof(*values));memset(&values[i],0,sizeof(values[i]));
        int slot=mode==6&&(info_calls%2==0)?1-i:i;
        values[i].iSize=sizeof(values[i]);values[i].iAdapterIndex=slot?42:7;values[i].iBusNumber=1;values[i].iDeviceNumber=0;
        values[i].iFunctionNumber=0;values[i].iVendorID=mode==29?0x10de:mode==14?0x1002:1002;
        values[i].iPresent=mode!=20;values[i].iExist=1;strcpy(values[i].strAdapterName,"Independent AMD SDK");
        const char *pnp="PCI\\VEN_1002&DEV_6613&SUBSYS_00000000";
        if((mode==9||mode==79)&&info_calls%2==0)pnp="PCI\\VEN_1002&DEV_9999&SUBSYS_00000000";
        if(mode==10&&i==1)pnp="PCI\\VEN_1002&DEV_9999&SUBSYS_00000000";
        strcpy(values[i].strPNPString,pnp);strcpy(values[i].strUDID,pnp);
        if(mode==11){memset(values[i].strPNPString,'A',sizeof(values[i].strPNPString));memset(values[i].strUDID,'A',sizeof(values[i].strUDID));}
        if(mode==12)strcpy(values[i].strUDID,"PCI\\VEN_10DE&DEV_9999");
        if(mode==28){strcpy(values[i].strPNPString,"UNKNOWN");strcpy(values[i].strUDID,"UNKNOWN");}
        if(mode==13){strcpy(values[i].strPNPString,"PCI\\VEN_10020&DEV_66130");strcpy(values[i].strUDID,values[i].strPNPString);}
    }return 0;
}
static void index_ok(int index){assert(created&&(index==7||index==42));}
static int active(int index,int *value){index_ok(index);if(mode==20)return -5;*value=1;return 0;}
static int caps(int index,int *supported,int *enabled,int *version){index_ok(index);if(mode==20)return -5;*supported=*enabled=1;*version=mode==1?6:5;return 0;}
static int activity(int index,ADLPMActivity *v){index_ok(index);assert(v->iSize==(int)sizeof(*v));if(mode==20)return -5;if(mode==1)return -8;if(mode==21)return -23;
    #if !defined(WTOP_ADL_LEGACY) && !defined(WTOP_ADL_NO_PMLOG)
    if(mode==60||mode==63)ExitProcess(96);
#endif /* Complete PMLog must bypass legacy queries. */
    if(mode==27)return 0;
    if(mode==43)RaiseException(0xc0000005,0,0,NULL);
    memset(v,0,sizeof(*v));v->iSize=sizeof(*v);v->iEngineClock=30000;v->iMemoryClock=15000;v->iActivityPercent=25;v->iVddc=950;
    if(mode==15)v->iEngineClock=v->iMemoryClock=INT_MAX;
    if(mode==16)v->iActivityPercent=101;
    return 0;
}
static int status6(int index,ADLOD6CurrentStatus *v){index_ok(index);if(mode==20)return -5;if(mode==21)return -23;memset(v,0,sizeof(*v));v->iEngineClock=40000;v->iMemoryClock=20000;v->iActivityPercent=30;return 0;}
static int thermal(int index,int sensor,ADLThermalControllerInfo *v){index_ok(index);assert(v->iSize==(int)sizeof(*v));if(mode==20)return -5;if(mode==1)return -8;if(sensor)return -6;memset(v,0,sizeof(*v));v->iSize=sizeof(*v);v->iThermalDomain=1;return 0;}
static int temp5(int index,int sensor,ADLTemperature *v){index_ok(index);assert(sensor==0&&v->iSize==(int)sizeof(*v));if(mode==26)return 0;v->iTemperature=mode==17?INT_MAX:43250;return 0;}
static int temp6(int index,int *value){index_ok(index);if(mode==20)return -5;if(mode==17||mode==26)return -8;*value=mode==1?45000:43250;return 0;}
static int fan5(int index,int sensor,ADLFanSpeedValue *v){index_ok(index);assert(sensor==0&&v->iSize==(int)sizeof(*v)&&v->iFlags==0);
    if(mode==18)return -23;
    assert(v->iSpeedType==1||v->iSpeedType==2);v->iFanSpeed=v->iSpeedType==1?25:1200;return 0;}
static int fan6(int index,ADLOD6FanSpeedInfo *v){index_ok(index);if(mode==20)return -5;if(mode==18)return -23;memset(v,0,sizeof(*v));v->iSpeedType=3;v->iFanSpeedPercent=35;v->iFanSpeedRPM=1400;return 0;}
#ifndef WTOP_ADL_LEGACY
static void context_ok(void *ctx){assert(ctx==(void *)(uintptr_t)0x1234);}
int ADL2_Adapter_NumberOfAdapters_Get(void *c,int *v){context_ok(c);return count(v);}
int ADL2_Adapter_AdapterInfo_Get(void *c,AdapterInfo *v,int n){context_ok(c);return info(v,n);}
int ADL2_Adapter_Active_Get(void *c,int index,int *v){context_ok(c);return active(index,v);}
int ADL2_Overdrive_Caps(void *c,int index,int *s,int *e,int *v){context_ok(c);return caps(index,s,e,v);}
int ADL2_Overdrive5_CurrentActivity_Get(void *c,int index,ADLPMActivity *v){context_ok(c);return activity(index,v);}
int ADL2_Overdrive6_CurrentStatus_Get(void *c,int index,ADLOD6CurrentStatus *v){context_ok(c);return status6(index,v);}
int ADL2_Overdrive5_ThermalDevices_Enum(void *c,int index,int sensor,ADLThermalControllerInfo *v){context_ok(c);return thermal(index,sensor,v);}
int ADL2_Overdrive5_Temperature_Get(void *c,int index,int sensor,ADLTemperature *v){context_ok(c);return temp5(index,sensor,v);}
int ADL2_Overdrive6_Temperature_Get(void *c,int index,int *v){context_ok(c);return temp6(index,v);}
int ADL2_Overdrive5_FanSpeed_Get(void *c,int index,int sensor,ADLFanSpeedValue *v){context_ok(c);return fan5(index,sensor,v);}
int ADL2_Overdrive6_FanSpeed_Get(void *c,int index,ADLOD6FanSpeedInfo *v){context_ok(c);return fan6(index,v);}
int ADL2_Overdrive6_CurrentPower_Get(void *c,int index,int type,int *v){context_ok(c);index_ok(index);assert(type==0);if(mode==44)hang();if(mode==20)return -5;if(mode==19)return -8;*v=mode==22?-1:mode==23?0:5760;return 0;}
#ifndef WTOP_ADL_NO_PMLOG
static int pm_slot(int index){index_ok(index);return index==7?0:1;}
static void pm_list(int count,int *list){
    const int expected[]={PMLOG_CLK_GFXCLK,PMLOG_CLK_MEMCLK,PMLOG_TEMPERATURE_EDGE,
        PMLOG_TEMPERATURE_HOTSPOT,PMLOG_FAN_RPM,PMLOG_FAN_PERCENTAGE,
        PMLOG_INFO_ACTIVITY_GFX,PMLOG_GFX_VOLTAGE,PMLOG_ASIC_POWER};
    assert(count==9&&list);for(int i=0;i<count;++i)assert(list[i]==expected[i]);
}
static void pm_output(ADLPMLogDataOutput *v,int shared){
    assert(v&&v->size==(shared?0:(int)sizeof(*v)));
    if(mode==74)return;
    int ids[]={1,2,8,27,14,15,19,21,23};
    int values[]={1875,1000,51,79,1500,35,63,950,37};
    int over[]={10001,10001,1000,1000,100001,101,101,10001,100000};
    for(int i=0;i<9;++i){
        assert(v->sensors[ids[i]].supported==0&&v->sensors[ids[i]].value==INT_MIN);
        if(mode==65||(mode==62&&ids[i]!=23&&ids[i]!=27&&ids[i]!=21))continue;
        v->sensors[ids[i]].supported=mode==64?2:1;
        if(mode!=66)v->sensors[ids[i]].value=mode==63?0:values[i];
        if(mode==91)v->sensors[ids[i]].value=over[i];
        if(mode==92)v->sensors[ids[i]].value=(i==2||i==3)?-200:-1;
        if(mode==93&&i==3)v->sensors[ids[i]].value=INT_MAX;
        if(mode==94&&i==8){v->sensors[ids[i]].supported=0;v->sensors[ids[i]].value=0;}
    }
    v->size=mode==67?12:(int)sizeof(*v);
    if(mode==90)v->size=0;
    /* Untyped limits/board power and sampled throttle flags are traps, not watts/caps. */
    v->sensors[35].supported=v->sensors[47].supported=v->sensors[73].supported=1;
    v->sensors[35].value=v->sensors[47].value=v->sensors[73].value=999;
}
int ADL2_Overdrive8_PMLog_ShareMemory_Support(void *c,int index,int *supported,int option){
    context_ok(c);index_ok(index);assert(supported&&option==0);
    if(mode==81)hang();
    *supported=mode>=60?1:0;
    if(mode==61||mode==87||mode==88)*supported=0;
    if(mode==68)return -8;
    if(mode==69)*supported=2;
    return 0;
}
int ADL2_Device_PMLog_Device_Create(void *c,int index,ADL_D3DKMT_HANDLE *h){
    context_ok(c);int slot=pm_slot(index);assert(h&&!*h&&!pm_handles[slot]);
    if(mode==82)hang();
    if(mode==70)return -8;
    if(mode==71)return 0;
    *h=pm_handles[slot]=0x80000000u+(unsigned)index;++pm_created;pm_trace();
    return mode==97?-8:0;
}
int ADL2_Overdrive8_PMLog_ShareMemory_Start(void *c,int index,int rate,int count,int *list,ADL_D3DKMT_HANDLE *h,void **memory,int option){
    context_ok(c);int slot=pm_slot(index);pm_list(count,list);
    assert(rate==1000&&option==0&&h&&*h==pm_handles[slot]&&memory&&!*memory&&!pm_logging[slot]);
    if(mode==83)hang();
    pm_logging[slot]=1;++pm_started;pm_trace();
    if(mode==72)return -8;
    if(mode==73)return 0;
    *memory=(void *)(uintptr_t)(0xf0000000u+(unsigned)index); /* Deliberately unmapped. */
    if(mode==98)return -23;
    if(mode==78)*h=0xdeadbeefu;
    return 0;
}
int ADL2_Overdrive8_PMLog_ShareMemory_Read(void *c,int index,int count,int *list,void **memory,ADLPMLogDataOutput *v){
    context_ok(c);int slot=pm_slot(index);pm_list(count,list);assert(pm_logging[slot]&&pm_handles[slot]);
    assert(memory&&*memory==(void *)(uintptr_t)(0xf0000000u+(unsigned)index));
    ++pm_reads;pm_trace();
    if(mode==80)RaiseException(0xc0000005,0,0,NULL);
    if(mode==84)hang();
    if(mode==74)return -23;
    if(mode==75){*memory=NULL;
    return 0;}pm_output(v,1);
    return 0;
}
int ADL2_Overdrive8_PMLog_ShareMemory_Stop(void *c,int index,ADL_D3DKMT_HANDLE *h){
    context_ok(c);int slot=pm_slot(index);assert(h&&*h==pm_handles[slot]&&pm_logging[slot]);
    if(mode==85)hang();
    pm_logging[slot]=0;++pm_stopped;pm_trace();
    return mode==76?-23:0;
}
int ADL2_Device_PMLog_Device_Destroy(void *c,ADL_D3DKMT_HANDLE h){
    context_ok(c);int slot=h==pm_handles[0]?0:1;assert(h&&h==pm_handles[slot]&&!pm_logging[slot]);
    if(mode==86)hang();
    pm_handles[slot]=0;++pm_destroyed;pm_trace();
    return mode==77?-23:0;
}
int ADL2_New_QueryPMLogData_Get(void *c,int index,ADLPMLogDataOutput *v){
    context_ok(c);index_ok(index);
    if(mode<60)return -8;
    assert(mode==61||mode==68||mode==69||mode==70||mode==71||mode==72||mode==73||mode==78||mode==87||mode==88||mode==97||mode==98);
    ++pm_queries;pm_trace();
    if(mode==87)hang();
    if(mode==88)RaiseException(0xc0000005,0,0,NULL);
    pm_output(v,0);
    return 0;
}
#endif
#endif
int ADL_Adapter_NumberOfAdapters_Get(int *v){return count(v);}
int ADL_Adapter_AdapterInfo_Get(AdapterInfo *v,int n){return info(v,n);}
int ADL_Adapter_Active_Get(int index,int *v){return active(index,v);}
int ADL_Overdrive_Caps(int index,int *s,int *e,int *v){return caps(index,s,e,v);}
int ADL_Overdrive5_CurrentActivity_Get(int index,ADLPMActivity *v){return activity(index,v);}
int ADL_Overdrive6_CurrentStatus_Get(int index,ADLOD6CurrentStatus *v){return status6(index,v);}
int ADL_Overdrive5_ThermalDevices_Enum(int index,int sensor,ADLThermalControllerInfo *v){return thermal(index,sensor,v);}
int ADL_Overdrive5_Temperature_Get(int index,int sensor,ADLTemperature *v){return temp5(index,sensor,v);}
int ADL_Overdrive6_Temperature_Get(int index,int *v){return temp6(index,v);}
int ADL_Overdrive5_FanSpeed_Get(int index,int sensor,ADLFanSpeedValue *v){return fan5(index,sensor,v);}
int ADL_Overdrive6_FanSpeed_Get(int index,ADLOD6FanSpeedInfo *v){return fan6(index,v);}
/* Exported traps prove that monitoring never asks for power adjustment or setters. */
int ADL2_Overdrive6_PowerControl_Get(void *c,int index,int *a,int *b){(void)c;(void)index;(void)a;(void)b;ExitProcess(97);
    return -1;}
int ADL2_Overdrive6_PowerControl_Set(void *c,int index,int value){(void)c;(void)index;(void)value;ExitProcess(98);
    return -1;}
