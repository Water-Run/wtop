/* NVML runs only in this exec'd process for the default provider. stdout and
 * stderr are not the protocol channel: even noisy driver constructors cannot
 * corrupt the reply or the TUI. No Lua runtime or script is needed here. */
#define _GNU_SOURCE
#define WTOP_NVML_CORE_ONLY
#include "wtop_nvml.c"
#include "wtop_nvml_protocol.h"
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <signal.h>

struct wire_buffer { unsigned char *data;size_t size,capacity; };
static uint64_t worker_now(void) {
    struct timespec time;if(clock_gettime(CLOCK_MONOTONIC,&time))return 0;
    return (uint64_t)time.tv_sec*UINT64_C(1000000000)+(uint64_t)time.tv_nsec;
}
static unsigned char *reserve(nvml_output *out,size_t n) {
    struct wire_buffer *buffer=out->context;
    if(out->failed||n>NVML_WIRE_LIMIT-buffer->size){out->failed=1;return NULL;}
    if(buffer->size+n>buffer->capacity){
        size_t capacity=buffer->capacity?buffer->capacity:65536;
        while(capacity<buffer->size+n)capacity*=2;
        unsigned char *data=realloc(buffer->data,capacity);
        if(!data){out->failed=2;return NULL;}buffer->data=data;buffer->capacity=capacity;
    }
    unsigned char *p=buffer->data+buffer->size;buffer->size+=n;return p;
}
static void wire_emit(nvml_output *out,enum nvml_operation op,const char *key,int64_t integer,double number,const char *text) {
    size_t k=key?strlen(key):0,n=text?strlen(text):0;
    if(k>63||n>256){out->failed=1;return;}
    size_t payload=op==NVML_TABLE||op==NVML_INTEGER||op==NVML_NUMBER?8:op==NVML_INDEX?4:
        op==NVML_BOOLEAN?1:op==NVML_STRING?n+2:0;
    unsigned char *p=reserve(out,1+(key?k+1:0)+payload);if(!p)return;
    *p++=(unsigned char)op;
    if(key){*p++=(unsigned char)k;memcpy(p,key,k);p+=k;}
    if(op==NVML_TABLE||op==NVML_INTEGER)nvml_put64(p,(uint64_t)integer);
    else if(op==NVML_NUMBER){uint64_t bits;memcpy(&bits,&number,8);nvml_put64(p,bits);}
    else if(op==NVML_INDEX)nvml_put32(p,(uint32_t)integer);
    else if(op==NVML_BOOLEAN)*p=(unsigned char)integer;
    else if(op==NVML_STRING){p[0]=(unsigned char)n;p[1]=(unsigned char)(n>>8);memcpy(p+2,text,n);}
}
static int receive_exact(int fd,unsigned char *data,size_t size) {
    while(size){ssize_t n=recv(fd,data,size,0);if(n<0&&errno==EINTR)continue;if(n<=0)return 0;data+=(size_t)n;size-=(size_t)n;}
    return 1;
}
static int send_exact(int fd,const unsigned char *data,size_t size) {
    while(size){ssize_t n=send(fd,data,size,MSG_NOSIGNAL);if(n<0&&errno==EINTR)continue;if(n<=0)return 0;data+=(size_t)n;size-=(size_t)n;}
    return 1;
}
int main(int argc,char **argv) {
    if(argc!=2)return 2;
    uint64_t parent=0;
    if(!argv[1][0])return 2;
    for(const char *p=argv[1];*p;++p){if(*p<'0'||*p>'9')return 2;parent=parent*10u+(unsigned)(*p-'0');if(parent>INT_MAX)return 2;}
    if(!parent)return 2;
    struct rlimit core={0,0};(void)setrlimit(RLIMIT_CORE,&core);
    if(prctl(PR_SET_PDEATHSIG,SIGKILL)||getppid()!=(pid_t)parent)return 3;
    (void)close(4); /* bootstrap executable descriptor, never the RPC channel */
    (void)prctl(PR_SET_DUMPABLE,0);
    nvml_api api;memset(&api,0,sizeof(api));struct wire_buffer buffer={0};uint64_t previous=0;
    unsigned char command[NVML_WIRE_COMMAND];
    while(receive_exact(3,command,sizeof(command))){
        uint64_t sequence=nvml_u64(command+8);uint32_t flags=nvml_u32(command+16);
        if(nvml_u32(command)!=NVML_WIRE_MAGIC||nvml_u32(command+4)!=NVML_WIRE_VERSION
            ||nvml_u32(command+20)||!sequence||sequence<=previous||flags>2)break;
        previous=sequence;if(flags==2)break;
        buffer.size=0;nvml_output output={&buffer,0,wire_emit};uint64_t start=worker_now();
        const char *reason=nvml_collect(&api,&output,flags==1);uint64_t finish=worker_now();
        if(!reason&&!nvml_wire_valid(buffer.data,buffer.size))reason="nvml_invalid_response";
        const unsigned char *data=reason?(const unsigned char *)reason:buffer.data;
        size_t length=reason?strlen(reason):buffer.size;
        unsigned char header[NVML_WIRE_HEADER]={0};
        nvml_put32(header,NVML_WIRE_MAGIC);nvml_put32(header+4,NVML_WIRE_VERSION);
        nvml_put32(header+8,(uint32_t)length);nvml_put32(header+12,reason?1u:0u);
        nvml_put64(header+16,sequence);nvml_put64(header+24,start);nvml_put64(header+32,finish);
        nvml_put32(header+40,flags);nvml_put32(header+44,nvml_checksum(data,length));
        if(!send_exact(3,header,sizeof(header))||!send_exact(3,data,length))break;
        if(reason)break; /* failed starts are retryable in a fresh process */
    }
    free(buffer.data);nvml_close(&api);return 0;
}
