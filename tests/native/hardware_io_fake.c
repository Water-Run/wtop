/* Read-only test filesystem redirect and a warmed driver read that stops
 * returning. Only exec'd hardware readers are affected by this preload. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdarg.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <errno.h>
static int (*real_open)(const char *,int,...);
static ssize_t (*real_read)(int,void *,size_t);
static ssize_t (*real_pread)(int,void *,size_t,off_t);
static int (*real_close)(int);
static DIR *(*real_opendir)(const char *);
static ssize_t (*real_readlink)(const char *,char *,size_t);
static int (*real_lstat)(const char *,struct stat *);
static int enabled,target_fd=-1,target_kind;
__attribute__((constructor)) static void setup(void) {
    real_pread=dlsym(RTLD_NEXT,"pread");real_open=dlsym(RTLD_NEXT,"open");real_read=dlsym(RTLD_NEXT,"read");real_close=dlsym(RTLD_NEXT,"close");
    real_opendir=dlsym(RTLD_NEXT,"opendir");real_readlink=dlsym(RTLD_NEXT,"readlink");real_lstat=dlsym(RTLD_NEXT,"lstat");
    char command[64]={0};int fd=real_open("/proc/self/cmdline",O_RDONLY|O_CLOEXEC);
    if(fd>=0){ssize_t n=real_read(fd,command,sizeof(command)-1);real_close(fd);
        enabled=n>0&&!strcmp(command,"wtop-hardware-reader");}
}
static const char *redirect(const char *path,char output[8192]) {
    const char *root=getenv("WTOP_HARDWARE_FIXTURE_ROOT");const char *prefix="/sys/class/hwmon";
    const char *firmware=getenv("WTOP_SMBIOS_FIXTURE_ROOT");
    if(firmware&&!strncmp(path,"/sys/firmware/dmi/tables",24)){
        root=firmware;prefix="/sys/firmware/dmi/tables";
    }
    const char *drm=getenv("WTOP_DRM_FIXTURE_ROOT"),*proc=getenv("WTOP_GPU_PROC_FIXTURE_ROOT");
    if(drm&&!strncmp(path,"/sys/class/drm",14)){root=drm;prefix="/sys/class/drm";}
    if(proc&&!strncmp(path,"/proc",5)){root=proc;prefix="/proc";}
    const char *spd=getenv("WTOP_SPD_FIXTURE_ROOT");
    if(spd&&!strncmp(path,"/sys/bus/i2c/devices",20)){root=spd;prefix="/sys/bus/i2c/devices";}
    size_t size=strlen(prefix);
    if(enabled&&root&&!strncmp(path,prefix,size)&&(path[size]=='/'||!path[size])){
        if(snprintf(output,8192,"%s%s",root,path+size)<8192)return output;
    }
    return path;
}
static void write_pid(const char *path,int append) {
    if(!path)return;
    int file=real_open(path,O_WRONLY|O_CREAT|O_CLOEXEC|(append?O_APPEND:O_TRUNC),0600);
    if(file<0)return;
    char pid[32];int n=snprintf(pid,sizeof(pid),"%ld\n",(long)getpid());
    if(n>0&&(size_t)n<sizeof(pid)){
        size_t offset=0;
        while(offset<(size_t)n){
            ssize_t written=write(file,pid+offset,(size_t)n-offset);
            if(written<0&&errno==EINTR)continue;
            if(written<=0)break;
            offset+=(size_t)written;
        }
    }
    real_close(file);
}
int open(const char *path,int flags,...) {
    mode_t mode=0;
    if(flags&O_CREAT){va_list args;va_start(args,flags);mode=(mode_t)va_arg(args,int);va_end(args);}
    char mapped[8192];int fd=real_open(redirect(path,mapped),flags,mode);
    if(enabled&&fd>=0&&strstr(path,"/temp1_input")){target_fd=fd;target_kind=1;}
    if(enabled&&fd>=0&&!strcmp(path,"/sys/firmware/dmi/tables/DMI")&&getenv("WTOP_SMBIOS_FIXTURE_ROOT")){
        target_fd=fd;target_kind=2;write_pid(getenv("WTOP_SMBIOS_FIXTURE_READS"),1);
    }
    if(enabled&&fd>=0&&strstr(path,"/gpu_busy_percent")&&getenv("WTOP_DRM_FIXTURE_ROOT")){
        target_fd=fd;target_kind=3;write_pid(getenv("WTOP_DRM_FIXTURE_READS"),1);
    }
    if(enabled&&fd>=0&&strstr(path,"/eeprom")&&getenv("WTOP_SPD_FIXTURE_ROOT")){
        target_fd=fd;target_kind=4;write_pid(getenv("WTOP_SPD_FIXTURE_READS"),1);
    }
    return fd;
}
int close(int fd) {if(fd==target_fd)target_fd=-1;return real_close(fd);}
DIR *opendir(const char *path) {char mapped[8192];return real_opendir(redirect(path,mapped));}
ssize_t readlink(const char *path,char *buffer,size_t size) {char mapped[8192];return real_readlink(redirect(path,mapped),buffer,size);}
int lstat(const char *path,struct stat *value) {char mapped[8192];return real_lstat(redirect(path,mapped),value);}
static int blocked(void) {
    const char *path=getenv(target_kind==4?"WTOP_SPD_FIXTURE_CONTROL":target_kind==3?"WTOP_DRM_FIXTURE_CONTROL":target_kind==2?"WTOP_SMBIOS_FIXTURE_CONTROL":"WTOP_HARDWARE_FIXTURE_CONTROL");if(!path)return 0;
    int fd=real_open(path,O_RDONLY|O_CLOEXEC);if(fd<0)return 0;
    char value=0;ssize_t size=real_read(fd,&value,1);real_close(fd);return size==1&&value=='1';
}
ssize_t read(int fd,void *buffer,size_t size) {
    if(enabled&&fd==target_fd&&blocked()){
        write_pid(getenv(target_kind==4?"WTOP_SPD_FIXTURE_ENTERED":target_kind==3?"WTOP_DRM_FIXTURE_ENTERED":target_kind==2?"WTOP_SMBIOS_FIXTURE_ENTERED":"WTOP_HARDWARE_FIXTURE_ENTERED"),0);
        while(blocked()){struct timespec delay={0,10000000};(void)nanosleep(&delay,NULL);}
    }
    return real_read(fd,buffer,size);
}

ssize_t pread(int fd,void *buffer,size_t size,off_t offset) {
    if(enabled&&fd==target_fd&&target_kind==4&&blocked()){
        write_pid(getenv("WTOP_SPD_FIXTURE_ENTERED"),0);
        while(blocked()){struct timespec delay={0,10000000};(void)nanosleep(&delay,NULL);}
    }
    return real_pread(fd,buffer,size,offset);
}
