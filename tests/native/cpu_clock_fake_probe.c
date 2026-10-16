/* Check the injected device itself before testing the actual native reader. */
#define _GNU_SOURCE
#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <unistd.h>

extern ssize_t __pread_chk(int,void *,size_t,off_t,size_t);
extern ssize_t __pread64_chk(int,void *,size_t,off64_t,size_t);

static uint64_t little(const unsigned char data[8]) {
    uint64_t value=0;
    for(unsigned i=0;i<8;++i)value|=(uint64_t)data[i]<<(8u*i);
    return value;
}

int main(void) {
    unsigned char bytes[8];
    struct stat metadata;
    int fd=open("/dev/cpu/0/msr",O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW);
    assert(fd>=0 && !fstat(fd,&metadata));
    assert(S_ISCHR(metadata.st_mode) && major(metadata.st_rdev)==202 && minor(metadata.st_rdev)==0);
    assert(pread(fd,bytes,8,0xe8)==8 && little(bytes)==UINT64_C(0x1122334455667788));
    assert(pread(fd,bytes,8,0xe7)==8 && little(bytes)==UINT64_C(0x0102030405060708));
    assert(pread64(fd,bytes,8,0xe8)==8 && little(bytes)==UINT64_C(0x1122334455667788));
    assert(pread64(fd,bytes,8,0xe7)==8 && little(bytes)==UINT64_C(0x0102030405060708));
    assert(__pread_chk(fd,bytes,8,0xe8,sizeof(bytes))==8 && little(bytes)==UINT64_C(0x1122334455667788));
    assert(__pread_chk(fd,bytes,8,0xe7,sizeof(bytes))==8 && little(bytes)==UINT64_C(0x0102030405060708));
    assert(__pread64_chk(fd,bytes,8,0xe8,sizeof(bytes))==8 && little(bytes)==UINT64_C(0x1122334455667788));
    assert(__pread64_chk(fd,bytes,8,0xe7,sizeof(bytes))==8 && little(bytes)==UINT64_C(0x0102030405060708));
    for(int wide=0;wide<2;++wide){
        pid_t child=fork();assert(child>=0);
        if(!child){
            struct rlimit core={0,0};assert(!setrlimit(RLIMIT_CORE,&core));
            assert(freopen("/dev/null","w",stderr));
            volatile size_t capacity=4;
            ssize_t result=wide?__pread64_chk(fd,bytes,8,0xe8,capacity)
                :__pread_chk(fd,bytes,8,0xe8,capacity);
            (void)result;
            _exit(3);
        }
        int status=0;assert(waitpid(child,&status,0)==child);
        assert(WIFSIGNALED(status) && WTERMSIG(status)==SIGABRT);
    }
    assert(!close(fd));
    puts("ok: CPU counter fixture ordinary/large/fortified reads, fixed offsets, device identity and preserved bounds aborts");
    return 0;
}
