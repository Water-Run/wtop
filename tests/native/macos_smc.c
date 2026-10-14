/* Exercise only SMC read commands, without changing any hardware state. */
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned opened, closed, services, calls, mode;
static uint32_t data_type, data_size;
static uint8_t payload[32];
static void (*cleanup)(void);
enum { OPEN_FAILED=1, CALL_FAILED=2, SHORT_INFO=4, SHORT_DATA=8,
    LONG_REPLY=16, KEY_FAILED=32, ZERO_SIZE=64, LARGE_SIZE=128 };
static CFMutableDictionaryRef fixture_matching(const char *name){
    assert(!strcmp(name,"AppleSMC"));
    return CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
}
static io_service_t fixture_service(mach_port_t port,CFDictionaryRef matching){(void)port;CFRelease(matching);++services;return 1;}
static kern_return_t fixture_open(io_service_t service,task_port_t task,uint32_t type,io_connect_t *out){
    (void)task;assert(service==1&&type==0);++opened;*out=100;return mode&OPEN_FAILED?KERN_FAILURE:KERN_SUCCESS;
}
static kern_return_t fixture_close(io_connect_t client){assert(client==100);++closed;return KERN_SUCCESS;}
static kern_return_t fixture_release(io_object_t service){assert(service==1&&services);--services;return KERN_SUCCESS;}
static int fixture_atexit(void (*fn)(void)){cleanup=fn;return 0;}
static kern_return_t fixture_call(io_connect_t,uint32_t,const void *,size_t,void *,size_t *);
#define IOServiceMatching fixture_matching
#define IOServiceGetMatchingService fixture_service
#define IOServiceOpen fixture_open
#define IOServiceClose fixture_close
#define IOObjectRelease fixture_release
#define IOConnectCallStructMethod fixture_call
#define atexit fixture_atexit
#include "../../native/wtop_macos_smc.c"

static kern_return_t fixture_call(io_connect_t client,uint32_t selector,const void *input,size_t input_size,void *output,size_t *output_size){
    const smc_message *request=input;smc_message *reply=output;
    assert(client==100&&selector==2&&input_size==sizeof(*request)&&*output_size==sizeof(*reply));
    assert(request->command==9||request->command==5);++calls;
    if(mode&CALL_FAILED)return KERN_FAILURE;
    memset(reply,0,sizeof(*reply));
    if(mode&KEY_FAILED)reply->result=1;
    if(request->command==9){
        reply->info.data_type=data_type;reply->info.data_size=mode&ZERO_SIZE?0:mode&LARGE_SIZE?33:data_size;
        if(mode&SHORT_INFO)*output_size=offsetof(smc_message,bytes)-1;
    }else{
        assert(request->info.data_size==data_size);memcpy(reply->bytes,payload,data_size);
        if(mode&SHORT_DATA)*output_size=offsetof(smc_message,bytes)+data_size-1;
    }
    if(mode&LONG_REPLY)*output_size=sizeof(*reply)+1;
    return KERN_SUCCESS;
}
static void expect(const char *type,unsigned size,const uint8_t *bytes,double expected){
    data_type=four_cc(type);data_size=size;memset(payload,0,sizeof(payload));memcpy(payload,bytes,size);
    double value=12345;assert(wtop_smc_number("TEST",&value));assert(fabs(value-expected)<1e-6);
}
int main(void){
    _Static_assert(sizeof(smc_message)==80,"SMC user-client ABI size");
    _Static_assert(offsetof(smc_message,bytes)==48,"SMC payload offset");
    wtop_smc_begin();
    const uint8_t u8[]={2},u16[]={0x12,0x34},u32[]={0x89,0xab,0xcd,0xef};
    expect("ui8 ",1,u8,2);expect("ui16",2,u16,0x1234);expect("ui32",4,u32,UINT32_C(0x89abcdef));
    const uint8_t fan[]={0x1f,0x40};expect("fpe2",2,fan,2000);
    const uint8_t voltage[]={0x14,0x00};expect("fp4c",2,voltage,1.25);
    const uint8_t positive[]={0x19,0x80},negative[]={0x99,0x80};
    expect("sp78",2,positive,25.5);expect("sp78",2,negative,-25.5);
    const uint8_t current[]={0x86,0x00};expect("sp5a",2,current,-1.5);
    for(unsigned integer=1;integer<=15;++integer){
        char type[5];snprintf(type,sizeof(type),"fp%x%x",integer,16-integer);expect(type,2,voltage,0x1400/(double)(1u<<(16-integer)));
        snprintf(type,sizeof(type),"sp%x%x",integer,15-integer);expect(type,2,negative,-0x1980/(double)(1u<<(15-integer)));
    }
    float f=12.5f;expect("flt ",4,(const uint8_t *)&f,12.5);
    for(unsigned index=0;index<3;++index){f=index==0?INFINITY:index==1?-INFINITY:NAN;memcpy(payload,&f,4);double value=7;assert(!wtop_smc_number("TEST",&value)&&value==7);}
    double value=7;data_type=four_cc("ui8 ");data_size=2;assert(!wtop_smc_number("TEST",&value));
    data_type=four_cc("sp88");assert(!wtop_smc_number("TEST",&value));
    data_type=four_cc("ch8*");assert(!wtop_smc_number("TEST",&value));
    data_type=four_cc("ui16");data_size=2;
    for(unsigned flag=SHORT_INFO;flag<=LARGE_SIZE;flag<<=1){mode=flag;unsigned before=closed;assert(!wtop_smc_number("TEST",&value));assert(closed==before);}
    wtop_smc_begin();
    mode=CALL_FAILED;unsigned before=closed;assert(!wtop_smc_number("TEST",&value));assert(closed==before+1&&connection==0);
    mode=0;unsigned before_open=opened;assert(!wtop_smc_number("TEST",&value)&&opened==before_open);
    uint64_t old_epoch=wtop_smc_epoch();
    wtop_smc_begin();assert(wtop_smc_number("TEST",&value)&&opened==before_open+1&&wtop_smc_epoch()==old_epoch+1);
    smc_close();mode=OPEN_FAILED;wtop_smc_begin();before_open=opened;
    assert(!wtop_smc_number("TEST",&value)&&opened==before_open+1&&services==0&&connection==0);
    assert(!wtop_smc_number("TEST",&value)&&opened==before_open+1);
    mode=0;wtop_smc_begin();assert(wtop_smc_number("TEST",&value));
    unsigned before_calls=calls;assert(!wtop_smc_number(NULL,&value)&&!wtop_smc_number("ABC",&value)&&!wtop_smc_number("ABCDE",&value)&&!wtop_smc_number("TEST",NULL));assert(calls==before_calls);
    assert(cleanup);cleanup();assert(connection==0&&services==0&&opened==closed);
    puts("SMC: read-only ABI lengths, integer/float/fixed-point formats, signed magnitude, malformed replies, nonfinite values, bounded reopen and cleanup passed");
    return 0;
}
