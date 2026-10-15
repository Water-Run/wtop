/* GPU SDKs run only in exec'd processes for default providers. stdout and
 * stderr are not the protocol channel: even noisy driver constructors cannot
 * corrupt the reply or the TUI. No Lua runtime or script is needed here. */
#define _GNU_SOURCE
#include "wtop_gpu_worker.h"
#include "wtop_gpu_protocol.h"
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>
#include <time.h>
#include <dirent.h>

struct wire_buffer { unsigned char *data;size_t size,capacity; };
static uint64_t worker_now(void) {
    struct timespec time;if(clock_gettime(CLOCK_MONOTONIC,&time))return 0;
    return (uint64_t)time.tv_sec*UINT64_C(1000000000)+(uint64_t)time.tv_nsec;
}
static unsigned char *reserve(gpu_output *out,size_t n) {
    struct wire_buffer *buffer=out->context;
    if(out->failed||n>GPU_WIRE_LIMIT-buffer->size){out->failed=1;return NULL;}
    if(buffer->size+n>buffer->capacity){
        size_t capacity=buffer->capacity?buffer->capacity:65536;
        while(capacity<buffer->size+n)capacity*=2;
        unsigned char *data=realloc(buffer->data,capacity);
        if(!data){out->failed=2;return NULL;}buffer->data=data;buffer->capacity=capacity;
    }
    unsigned char *p=buffer->data+buffer->size;buffer->size+=n;return p;
}
static void wire_emit(gpu_output *out,enum gpu_operation op,const char *key,int64_t integer,double number,const char *text) {
    size_t k=key?strlen(key):0,n=text?strlen(text):0;
    if(k>63||n>256){out->failed=1;return;}
    size_t payload=op==GPU_TABLE||op==GPU_INTEGER||op==GPU_NUMBER?8:op==GPU_INDEX?4:
        op==GPU_BOOLEAN?1:op==GPU_STRING?n+2:0;
    unsigned char *p=reserve(out,1+(key?k+1:0)+payload);if(!p)return;
    *p++=(unsigned char)op;
    if(key){*p++=(unsigned char)k;memcpy(p,key,k);p+=k;}
    if(op==GPU_TABLE||op==GPU_INTEGER)gpu_put64(p,(uint64_t)integer);
    else if(op==GPU_NUMBER){uint64_t bits;memcpy(&bits,&number,8);gpu_put64(p,bits);}
    else if(op==GPU_INDEX)gpu_put32(p,(uint32_t)integer);
    else if(op==GPU_BOOLEAN)*p=(unsigned char)integer;
    else if(op==GPU_STRING){p[0]=(unsigned char)n;p[1]=(unsigned char)(n>>8);memcpy(p+2,text,n);}
}
static int receive_exact(int fd,unsigned char *data,size_t size) {
    while(size){ssize_t n=recv(fd,data,size,0);if(n<0&&errno==EINTR)continue;if(n<=0)return 0;data+=(size_t)n;size-=(size_t)n;}
    return 1;
}
static int send_exact(int fd,const unsigned char *data,size_t size) {
    while(size){ssize_t n=send(fd,data,size,MSG_NOSIGNAL);if(n<0&&errno==EINTR)continue;if(n<=0)return 0;data+=(size_t)n;size-=(size_t)n;}
    return 1;
}

static const char *const names[GPU_VENDOR_COUNT]={"nvml","amdsmi","levelzero"};
static const char *const invalid[GPU_VENDOR_COUNT]={"nvml_invalid_response","amdsmi_invalid_response","levelzero_invalid_response"};
static int close_extra_fds(void) {
    DIR *directory=opendir("/proc/self/fd");if(!directory)return -1;
    struct dirent *entry;
    while((entry=readdir(directory))){
        unsigned number=0;const unsigned char *p=(const unsigned char *)entry->d_name;int valid=*p!=0;
        for(;*p;++p){if(*p<'0'||*p>'9'||number>INT_MAX/10u){valid=0;break;}number=number*10u+(unsigned)(*p-'0');}
        if(valid&&number>3&&number<=INT_MAX&&(int)number!=dirfd(directory))(void)close((int)number);
    }
    closedir(directory);return 0;
}
int main(int argc,char **argv) {
    if(argc<2||argc>3)return 2;
    enum gpu_vendor vendor=GPU_NVML;int legacy=0;
    if(argc==3){
        if(!strcmp(argv[2],"levelzero-legacy")){vendor=GPU_LEVELZERO;legacy=1;}
        else {
            unsigned i;for(i=0;i<GPU_VENDOR_COUNT;++i)if(!strcmp(argv[2],names[i]))break;
            if(i==GPU_VENDOR_COUNT)return 2;
            vendor=(enum gpu_vendor)i;
        }
    }
    uint64_t parent=0;
    if(!argv[1][0])return 2;
    for(const char *p=argv[1];*p;++p){if(*p<'0'||*p>'9')return 2;parent=parent*10u+(unsigned)(*p-'0');if(parent>INT_MAX)return 2;}
    if(!parent)return 2;
    struct rlimit core={0,0};(void)setrlimit(RLIMIT_CORE,&core);
    if(prctl(PR_SET_PDEATHSIG,SIGKILL)||getppid()!=(pid_t)parent)return 3;
    (void)close(4);
    (void)prctl(PR_SET_DUMPABLE,0);
    const char *boot_reason=NULL;
    if(vendor==GPU_LEVELZERO){
        if(legacy?setenv("ZES_ENABLE_SYSMAN","1",1):unsetenv("ZES_ENABLE_SYSMAN"))
            boot_reason="levelzero_allocation_failed";
        else boot_reason=wtop_levelzero_prepare(legacy);
        if(!legacy&&boot_reason&&!strcmp(boot_reason,"levelzero_legacy_required")){
            /* Sysman and legacy initialization cannot be mixed. Re-exec before
             * consuming the first request, with a clean loader and FD set.
             * The PID/channel and parent's original deadline stay unchanged. */
            if(!close_extra_fds()){
                char *next[]={"wtop-gpu-reader",argv[1],"levelzero-legacy",NULL};
                execv("/proc/self/exe",next);
            }
            boot_reason="levelzero_worker_unavailable";
        }
    }
    struct wire_buffer buffer={0};uint64_t previous=0;
    unsigned char command[GPU_WIRE_COMMAND];
    while(receive_exact(3,command,sizeof(command))){
        uint64_t sequence=gpu_u64(command+8);uint32_t flags=gpu_u32(command+16);
        if(gpu_u32(command)!=GPU_WIRE_MAGIC||gpu_u32(command+4)!=GPU_WIRE_VERSION
            ||gpu_u32(command+20)||!sequence||sequence<=previous||flags>2)break;
        previous=sequence;if(flags==2)break;
        buffer.size=0;gpu_output output={&buffer,0,wire_emit};uint64_t start=worker_now();
        const char *reason=boot_reason;
        if(!reason){
            if(vendor==GPU_NVML)reason=wtop_nvml_collect(&output,flags==1);
            else if(vendor==GPU_AMDSMI)reason=wtop_amdsmi_collect(&output,flags==1);
            else reason=wtop_levelzero_collect(&output,flags==1);
        }
        uint64_t finish=worker_now();
        if(!reason&&!gpu_wire_valid(buffer.data,buffer.size))reason=invalid[vendor];
        const unsigned char *data=reason?(const unsigned char *)reason:buffer.data;
        size_t length=reason?strlen(reason):buffer.size;
        unsigned char header[GPU_WIRE_HEADER]={0};
        gpu_put32(header,GPU_WIRE_MAGIC);gpu_put32(header+4,GPU_WIRE_VERSION);
        gpu_put32(header+8,(uint32_t)length);gpu_put32(header+12,reason?1u:0u);
        gpu_put64(header+16,sequence);gpu_put64(header+24,start);gpu_put64(header+32,finish);
        gpu_put32(header+40,flags);gpu_put32(header+44,gpu_checksum(data,length));gpu_put32(header+48,(uint32_t)vendor);
        if(!send_exact(3,header,sizeof(header))||!send_exact(3,data,length))break;
        if(reason)break;
    }
    free(buffer.data);
    if(vendor==GPU_NVML)wtop_nvml_finish();
    else if(vendor==GPU_LEVELZERO)wtop_levelzero_finish();
    return 0;
}
