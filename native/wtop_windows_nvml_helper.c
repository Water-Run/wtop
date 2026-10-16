/* Native-architecture NVML reader. No Lua or SDK call runs in its parent. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include "wtop_gpu_protocol.h"
#include "wtop_gpu_worker.h"
#if defined(WTOP_WINDOWS_ADL)
#define WINDOWS_SDK_SOURCE 10u
#define WINDOWS_SDK_NAME L"adl"
#define WINDOWS_SDK_INVALID "adl_invalid_response"
#elif defined(WTOP_WINDOWS_LEVELZERO)
#define WINDOWS_SDK_SOURCE 9u
#define WINDOWS_SDK_NAME L"levelzero"
#define WINDOWS_SDK_INVALID "levelzero_invalid_response"
#else
#define WINDOWS_SDK_SOURCE 6u
#define WINDOWS_SDK_NAME L"nvml"
#define WINDOWS_SDK_INVALID "nvml_invalid_response"
#endif
struct wire_buffer {unsigned char *data;size_t size,capacity;};
struct watcher {HANDLE parent,cancel,stop,ready;};
static uint64_t now_ns(void) {
    LARGE_INTEGER counter,frequency;
    if(!QueryPerformanceCounter(&counter)||!QueryPerformanceFrequency(&frequency)
        ||counter.QuadPart<0||frequency.QuadPart<=0)return 0;
    uint64_t n=(uint64_t)counter.QuadPart,f=(uint64_t)frequency.QuadPart;
    return n/f*UINT64_C(1000000000)+(n%f)*UINT64_C(1000000000)/f;
}
static DWORD WINAPI watch_parent(void *opaque) {
    struct watcher watch=*(struct watcher *)opaque;
    SetEvent(watch.ready);
    HANDLE handles[]={watch.parent,watch.cancel,watch.stop};
    if(WaitForMultipleObjects(3,handles,FALSE,INFINITE)!=WAIT_OBJECT_0+2)
        (void)TerminateProcess(GetCurrentProcess(),3);
    return 0;
}
static HANDLE argument(const WCHAR *text) {
    uintptr_t value=0;if(!text[0])return NULL;
    for(;*text;++text){unsigned digit=*text>=L'0'&&*text<=L'9'?(unsigned)(*text-L'0'):
        *text>=L'a'&&*text<=L'f'?(unsigned)(*text-L'a'+10):16;
        if(digit==16||value>(UINTPTR_MAX-digit)/16)return NULL;
        value=value*16+digit;}
    return (HANDLE)value;
}
static int transfer(HANDLE pipe,void *bytes,size_t size,int writing) {
    unsigned char *p=bytes;
    while(size){DWORD n=0,amount=(DWORD)(size>32768?32768:size);
        BOOL ok=writing?WriteFile(pipe,p,amount,&n,NULL):ReadFile(pipe,p,amount,&n,NULL);
        if(!ok||!n)return 0;
        p+=n;size-=n;}
    return 1;
}
static unsigned char *reserve(gpu_output *out,size_t size) {
    struct wire_buffer *b=out->context;
    if(out->failed||size>GPU_WIRE_LIMIT-b->size){out->failed=1;return NULL;}
    if(b->size+size>b->capacity){size_t capacity=b->capacity?b->capacity:65536;
        while(capacity<b->size+size)capacity*=2;
        unsigned char *data=realloc(b->data,capacity);
        if(!data){out->failed=2;return NULL;}b->data=data;b->capacity=capacity;}
    unsigned char *p=b->data+b->size;b->size+=size;return p;
}
static void emit(gpu_output *out,enum gpu_operation op,const char *key,int64_t integer,double number,const char *text) {
    size_t k=key?strlen(key):0,n=text?strlen(text):0;
    if(k>63||n>256){out->failed=1;return;}
    size_t payload=op==GPU_TABLE||op==GPU_INTEGER||op==GPU_NUMBER?8:
        op==GPU_INDEX?4:op==GPU_BOOLEAN?1:op==GPU_STRING?n+2:0;
    unsigned char *p=reserve(out,1+(key?k+1:0)+payload);if(!p)return;
    *p++=(unsigned char)op;
    if(key){*p++=(unsigned char)k;memcpy(p,key,k);p+=k;}
    if(op==GPU_TABLE||op==GPU_INTEGER)gpu_put64(p,(uint64_t)integer);
    else if(op==GPU_NUMBER){uint64_t bits;memcpy(&bits,&number,8);gpu_put64(p,bits);}
    else if(op==GPU_INDEX)gpu_put32(p,(uint32_t)integer);
    else if(op==GPU_BOOLEAN)*p=(unsigned char)integer;
    else if(op==GPU_STRING){p[0]=(unsigned char)n;p[1]=(unsigned char)(n>>8);memcpy(p+2,text,n);}
}
int wmain(int argc,WCHAR **argv) {
    if(argc!=7||wcscmp(argv[1],L"--wtop-hardware-reader")||wcscmp(argv[6],WINDOWS_SDK_NAME))return 2;
    struct watcher watch={argument(argv[2]),argument(argv[3]),NULL,NULL};
    HANDLE input=argument(argv[4]),output=argument(argv[5]);
    if(!watch.parent||!watch.cancel||!input||!output||GetFileType(input)!=FILE_TYPE_PIPE
        ||GetFileType(output)!=FILE_TYPE_PIPE||WaitForSingleObject(watch.parent,0)!=WAIT_TIMEOUT
        ||WaitForSingleObject(watch.cancel,0)!=WAIT_TIMEOUT)return 2;
    if(!SetHandleInformation(watch.parent,HANDLE_FLAG_INHERIT,0)||!SetHandleInformation(watch.cancel,HANDLE_FLAG_INHERIT,0)
        ||!SetHandleInformation(input,HANDLE_FLAG_INHERIT,0)||!SetHandleInformation(output,HANDLE_FLAG_INHERIT,0))return 2;
    SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX|SEM_NOOPENFILEERRORBOX);
    watch.stop=CreateEventW(NULL,TRUE,FALSE,NULL);watch.ready=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!watch.stop||!watch.ready){if(watch.stop)CloseHandle(watch.stop);if(watch.ready)CloseHandle(watch.ready);return 3;}
    HANDLE thread=CreateThread(NULL,0,watch_parent,&watch,0,NULL);
    if(!thread){CloseHandle(watch.stop);CloseHandle(watch.ready);return 3;}
    struct wire_buffer buffer={0};uint64_t previous=0;int code=2;
    if(WaitForSingleObject(watch.ready,5000)!=WAIT_OBJECT_0)goto finish;
    unsigned char prefix[4],configuration;
    if(!transfer(input,prefix,4,0)||gpu_u32(prefix)!=1||!transfer(input,&configuration,1,0))goto finish;
#ifdef WTOP_WINDOWS_LEVELZERO
    if(configuration!='x'&&configuration!='l')goto finish;
#else
    if(configuration!='x')goto finish;
#endif
#ifdef WTOP_WINDOWS_LEVELZERO
    /* Environment and loader initialization happen after the watchdog is ready.
     * Legacy retry always receives a fresh process from the controller. */
    int legacy=configuration=='l';
    /* Some SDK builds use the CRT environment, others use Win32 APIs. Update
     * both inside this new reader, before loading either SDK runtime. */
    const char *boot_reason=(!_putenv(legacy?"ZES_ENABLE_SYSMAN=1":"ZES_ENABLE_SYSMAN=")
        &&SetEnvironmentVariableW(L"ZES_ENABLE_SYSMAN",legacy?L"1":NULL))
        ?wtop_levelzero_prepare(legacy):"levelzero_initialization_failed";
#endif
    for(;;){
        unsigned char command[GPU_WIRE_COMMAND];
        if(!transfer(input,command,sizeof(command),0))break;
        uint64_t sequence=gpu_u64(command+8);unsigned flags=gpu_u32(command+16);
        if(gpu_u32(command)!=GPU_WIRE_MAGIC||gpu_u32(command+4)!=GPU_WIRE_VERSION
            ||gpu_u32(command+20)||!sequence||sequence<=previous||flags>1)break;
        previous=sequence;buffer.size=0;gpu_output out={&buffer,0,emit};uint64_t start=now_ns();
#if defined(WTOP_WINDOWS_ADL)
        const char *reason=wtop_adl_collect(&out,0);
#elif defined(WTOP_WINDOWS_LEVELZERO)
        const char *reason=boot_reason?boot_reason:wtop_levelzero_collect(&out,0);
#else
        const char *reason=wtop_nvml_collect(&out,flags!=0);
#endif
        if(!reason&&!gpu_wire_valid(buffer.data,buffer.size))reason=WINDOWS_SDK_INVALID;
        const void *data=reason?(const void *)reason:buffer.data;
        size_t size=reason?strlen(reason):buffer.size;
        unsigned char header[GPU_WIRE_HEADER]={0};gpu_put32(header,GPU_WIRE_MAGIC);
        gpu_put32(header+4,GPU_WIRE_VERSION);gpu_put32(header+8,(uint32_t)size);gpu_put32(header+12,reason!=NULL);
        gpu_put64(header+16,sequence);gpu_put64(header+24,start);gpu_put64(header+32,now_ns());
        gpu_put32(header+40,flags);gpu_put32(header+44,gpu_checksum(data,size));gpu_put32(header+48,WINDOWS_SDK_SOURCE);
        if(!transfer(output,header,sizeof(header),1)||!transfer(output,(void *)data,size,1))break;
        code=0;if(reason)break;
    }
finish:
#if defined(WTOP_WINDOWS_ADL)
    wtop_adl_finish();
#elif defined(WTOP_WINDOWS_LEVELZERO)
    wtop_levelzero_finish();
#else
    wtop_nvml_finish();
#endif
    free(buffer.data);SetEvent(watch.stop);WaitForSingleObject(thread,INFINITE);
    CloseHandle(thread);CloseHandle(watch.stop);CloseHandle(watch.ready);CloseHandle(watch.parent);CloseHandle(watch.cancel);
    CloseHandle(input);CloseHandle(output);return code;
}
