/* Fixed counter device fixture; enabled only in the isolated clock reader. */
#define _GNU_SOURCE
#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>
static int (*real_open)(const char *,int,...);
static int (*real_close)(int);
static int (*real_stat)(int,struct stat *);
static int (*real_fxstat)(int,int,struct stat *);
static ssize_t (*real_read)(int,void *,size_t);
static ssize_t (*real_pread)(int,void *,size_t,off_t);
static int enabled,tracked[4096];
__attribute__((constructor)) static void setup(void) {
    real_open=dlsym(RTLD_NEXT,"open");real_close=dlsym(RTLD_NEXT,"close");
    real_stat=dlsym(RTLD_NEXT,"fstat");real_read=dlsym(RTLD_NEXT,"read");real_pread=dlsym(RTLD_NEXT,"pread");
    real_fxstat=dlsym(RTLD_NEXT,"__fxstat");
    char command[64]={0};int fd=real_open("/proc/self/cmdline",O_RDONLY|O_CLOEXEC);
    if(fd>=0){ssize_t n=real_read(fd,command,sizeof(command)-1);real_close(fd);
        if(n>0&&!strcmp(command,"wtop-hardware-reader")){
            const char *source=command+strlen(command)+1;
            source+=strlen(source)+1;
            enabled=source<command+sizeof(command)&&!strcmp(source,"cpu_clocks");
        }}
}
static void entered(void) {
    const char *path=getenv("WTOP_CPU_CLOCK_ENTERED");if(!path)return;
    int fd=real_open(path,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC,0600);if(fd<0)return;
    char pid[32];int n=snprintf(pid,sizeof(pid),"%ld\n",(long)getpid());
    if(n>0&&(size_t)n<sizeof(pid)){
        size_t done=0;while(done<(size_t)n){ssize_t size=write(fd,pid+done,(size_t)n-done);
            if(size<0&&errno==EINTR)continue;
            if(size<=0)break;
            done+=(size_t)size;}
    }
    real_close(fd);
}
static int blocked(void) {
    const char *path=getenv("WTOP_CPU_CLOCK_CONTROL");if(!path)return 0;
    int fd=real_open(path,O_RDONLY|O_CLOEXEC);if(fd<0)return 0;
    char value=0;ssize_t n=real_read(fd,&value,1);real_close(fd);return n==1&&value=='1';
}
int open(const char *path,int flags,...) {
    mode_t mode=0;if(flags&O_CREAT){va_list ap;va_start(ap,flags);mode=(mode_t)va_arg(ap,int);va_end(ap);}
    unsigned cpu;int consumed=0;const char *root=getenv("WTOP_CPU_CLOCK_ROOT");
    if(enabled&&root&&sscanf(path,"/dev/cpu/%u/msr%n",&cpu,&consumed)==1&&consumed>0&&!path[consumed]){
        assert((flags&O_ACCMODE)==O_RDONLY && (flags&O_NOFOLLOW) && cpu<=8191);
        char mapped[8192];int length=snprintf(mapped,sizeof(mapped),"%s/cpu%u",root,cpu);
        if(length<0||(size_t)length>=sizeof(mapped)){errno=ENAMETOOLONG;return -1;}
        int fd=real_open(mapped,flags,mode);
        if(fd>=4096){real_close(fd);errno=EMFILE;return -1;}
        if(fd>=0)tracked[fd]=(int)cpu+1;
        return fd;
    }
    return real_open(path,flags,mode);
}
static int decorate_stat(int result,int fd,struct stat *value) {
    if(!result&&fd>=0&&fd<4096&&tracked[fd]){
        value->st_mode=(value->st_mode&~(mode_t)S_IFMT)|S_IFCHR;
        value->st_rdev=makedev(202,(unsigned)(tracked[fd]-1));
    }
    return result;
}
int fstat(int fd,struct stat *value) {
    return decorate_stat(real_stat(fd,value),fd,value);
}
/* Older glibc headers inline fstat through the versioned ABI. Intercept that
 * call too; the production guard must still reject ordinary fixture files. */
int __fxstat(int version,int fd,struct stat *value) {
    if(!real_fxstat){errno=ENOSYS;return -1;}
    return decorate_stat(real_fxstat(version,fd,value),fd,value);
}
int close(int fd) {if(fd>=0&&fd<4096)tracked[fd]=0;return real_close(fd);}
ssize_t pread(int fd,void *data,size_t size,off_t offset) {
    if(fd>=0&&fd<4096&&tracked[fd]){
        assert(size==8&&(offset==0xe8||offset==0xe7));
        if(blocked()){
            entered();while(blocked()){struct timespec pause={0,10000000};(void)nanosleep(&pause,NULL);}
        }
        return real_pread(fd,data,size,offset==0xe8?0:8);
    }
    return real_pread(fd,data,size,offset);
}
