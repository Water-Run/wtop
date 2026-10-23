/* Read-only test filesystem redirect and a warmed driver read that stops
 * returning. Hardware redirects affect only exec'd readers; the explicit
 * supply fixture also covers the foreground power-supply collector. */
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
#include <sys/ioctl.h>
#include <sys/sysmacros.h>
#include "../../native/wtop_linux_drm.h"
static int (*real_open)(const char *,int,...);
static ssize_t (*real_read)(int,void *,size_t);
static ssize_t (*real_pread)(int,void *,size_t,off_t);
static ssize_t (*real_pread_chk)(int,void *,size_t,off_t,size_t);
static ssize_t (*real_pread64_chk)(int,void *,size_t,off64_t,size_t);
static int (*real_close)(int);
static DIR *(*real_opendir)(const char *);
static ssize_t (*real_readlink)(const char *,char *,size_t);
static int (*real_lstat)(const char *,struct stat *);
static int (*real_fstat)(int,struct stat *);
static int (*real_ioctl)(int,unsigned long,...);
static int mode_fd=-1;
static int enabled,target_fd=-1,target_kind;
__attribute__((constructor)) static void setup(void) {
    real_pread_chk=dlsym(RTLD_NEXT,"__pread_chk");real_pread64_chk=dlsym(RTLD_NEXT,"__pread64_chk");
    real_pread=dlsym(RTLD_NEXT,"pread");real_open=dlsym(RTLD_NEXT,"open");real_read=dlsym(RTLD_NEXT,"read");real_close=dlsym(RTLD_NEXT,"close");
    real_opendir=dlsym(RTLD_NEXT,"opendir");real_readlink=dlsym(RTLD_NEXT,"readlink");real_lstat=dlsym(RTLD_NEXT,"lstat");
    real_fstat=dlsym(RTLD_NEXT,"fstat");real_ioctl=dlsym(RTLD_NEXT,"ioctl");
    (void)wtop_drm_mode_read;
    char command[64]={0};int fd=real_open("/proc/self/cmdline",O_RDONLY|O_CLOEXEC);
    if(fd>=0){ssize_t n=real_read(fd,command,sizeof(command)-1);real_close(fd);
        enabled=n>0&&!strcmp(command,"wtop-hardware-reader");}
}
static const char *redirect(const char *path,char output[8192]) {
    const char *typec=getenv("WTOP_TYPEC_FIXTURE_ROOT"),*pd=getenv("WTOP_PD_FIXTURE_ROOT");
    const char *physical=getenv("WTOP_TYPEC_PHYSICAL_ROOT");
    const char *typec_prefix="/sys/class/typec",*pd_prefix="/sys/class/usb_power_delivery";
    const char *physical_prefix="/sys/devices/wtop-typec";
    const char *special_roots[]={typec,pd,physical};
    const char *special_prefixes[]={typec_prefix,pd_prefix,physical_prefix};
    if(enabled){
        for(unsigned i=0;i<3;i++){
            size_t n=strlen(special_prefixes[i]);
            if(special_roots[i]&&!strncmp(path,special_prefixes[i],n)&&(path[n]=='/'||!path[n])){
                if(snprintf(output,8192,"%s%s",special_roots[i],path+n)<8192)return output;
            }
        }
    }
    const char *supply=getenv("WTOP_SUPPLY_FIXTURE_ROOT");
    const char *supply_prefix="/sys/class/power_supply";
    size_t supply_size=strlen(supply_prefix);
    if(supply&&!strncmp(path,supply_prefix,supply_size)&&(path[supply_size]=='/'||!path[supply_size])){
        if(snprintf(output,8192,"%s%s",supply,path+supply_size)<8192)return output;
    }
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
    if(enabled&&!strcmp(path,"/dev/dri/card1")&&getenv("WTOP_DISPLAY_FIXTURE_CONTROL")){
        mode_fd=real_open("/dev/null",flags,mode);
        if(mode_fd>=0)write_pid(getenv("WTOP_DRM_MODE_FIXTURE_READS"),1);
        return mode_fd;
    }
    char mapped[8192];int fd=real_open(redirect(path,mapped),flags,mode);
    if(enabled&&fd>=0&&strstr(path,"/data_role")&&getenv("WTOP_TYPEC_FIXTURE_CONTROL")){
        target_fd=fd;target_kind=7;
    }
    if(enabled&&fd>=0&&strstr(path,"/power_now")&&getenv("WTOP_SUPPLY_FIXTURE_CONTROL")){
        target_fd=fd;target_kind=6;
    }
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
    if(enabled&&fd>=0&&strstr(path,"/edid")&&getenv("WTOP_DISPLAY_FIXTURE_CONTROL")){
        target_fd=fd;target_kind=5;write_pid(getenv("WTOP_DISPLAY_FIXTURE_READS"),1);
    }
    return fd;
}
int close(int fd) {if(fd==target_fd)target_fd=-1;if(fd==mode_fd)mode_fd=-1;return real_close(fd);}
DIR *opendir(const char *path) {char mapped[8192];return real_opendir(redirect(path,mapped));}
ssize_t readlink(const char *path,char *buffer,size_t size) {
    char mapped[8192];const char *actual=redirect(path,mapped);
    if(size==0)return real_readlink(actual,buffer,size);
    const char *physical=enabled?getenv("WTOP_TYPEC_PHYSICAL_ROOT"):NULL;
    if(physical){
        char target[8192];ssize_t n=real_readlink(actual,target,sizeof(target)-1);
        if(n<0)return n;
        target[n]='\0';size_t prefix=strlen(physical);
        if(!strncmp(target,physical,prefix)&&(target[prefix]=='/'||!target[prefix])){
            char converted[8192];int length=snprintf(converted,sizeof(converted),"/sys/devices/wtop-typec%s",target+prefix);
            if(length<0||(size_t)length>=sizeof(converted)){errno=ENAMETOOLONG;return -1;}
            size_t count=(size_t)length<size?(size_t)length:size;
            memcpy(buffer,converted,count);return (ssize_t)count;
        }
        size_t count=(size_t)n<size?(size_t)n:size;
        memcpy(buffer,target,count);return (ssize_t)count;
    }
    return real_readlink(actual,buffer,size);
}
static void mode_metadata(struct stat *value) {
    memset(value,0,sizeof(*value));value->st_mode=S_IFCHR|0600;
    value->st_dev=1;value->st_ino=7;value->st_rdev=makedev(226,1);
}
int lstat(const char *path,struct stat *value) {
    if(enabled&&!strcmp(path,"/dev/dri/card1")&&getenv("WTOP_DISPLAY_FIXTURE_CONTROL")){mode_metadata(value);return 0;}
    char mapped[8192];return real_lstat(redirect(path,mapped),value);
}
int fstat(int fd,struct stat *value) {
    if(enabled&&fd==mode_fd){mode_metadata(value);return 0;}
    return real_fstat(fd,value);
}
static char mode_control(void) {
    const char *path=getenv("WTOP_DRM_MODE_FIXTURE_CONTROL");if(!path)return '0';
    int fd=real_open(path,O_RDONLY|O_CLOEXEC);if(fd<0)return '0';
    char value='0';(void)real_read(fd,&value,1);real_close(fd);return value;
}
int ioctl(int fd,unsigned long request,...) {
    va_list args;va_start(args,request);void *value=va_arg(args,void *);va_end(args);
    if(!enabled||fd!=mode_fd)return real_ioctl(fd,request,value);
    if(request==WTOP_DRM_GETCONNECTOR){
        wtop_drm_connector *v=value;uint32_t id=v->connector_id;
        if(v->count_modes!=1||!v->modes_ptr){errno=EINVAL;return -1;}
        memset(v,0,sizeof(*v));v->connector_id=id;v->encoder_id=100;
        v->connection=1;v->connector_type=14;v->connector_type_id=1;return 0;
    }
    if(request==WTOP_DRM_GETENCODER){
        wtop_drm_encoder *v=value;uint32_t id=v->encoder_id;
        memset(v,0,sizeof(*v));v->encoder_id=id;v->crtc_id=200;v->encoder_type=2;return 0;
    }
    if(request==WTOP_DRM_GETCRTC){
        if(mode_control()=='1'){
            write_pid(getenv("WTOP_DRM_MODE_FIXTURE_ENTERED"),0);
            while(mode_control()=='1'){struct timespec delay={0,10000000};(void)nanosleep(&delay,NULL);}
        }
        wtop_drm_crtc *v=value;uint32_t id=v->crtc_id;
        memset(v,0,sizeof(*v));v->crtc_id=id;v->mode_valid=1;
        v->mode.clock=mode_control()=='2'?185625:148500;
        v->mode.hdisplay=1920;v->mode.vdisplay=1080;v->mode.htotal=2200;v->mode.vtotal=1125;
        v->mode.vrefresh=mode_control()=='2'?75:60;v->mode.flags=9;return 0;
    }
    errno=ENOTTY;return -1;
}
static int blocked(void) {
    const char *path=getenv(target_kind==7?"WTOP_TYPEC_FIXTURE_CONTROL":target_kind==6?"WTOP_SUPPLY_FIXTURE_CONTROL":target_kind==5?"WTOP_DISPLAY_FIXTURE_CONTROL":target_kind==4?"WTOP_SPD_FIXTURE_CONTROL":target_kind==3?"WTOP_DRM_FIXTURE_CONTROL":target_kind==2?"WTOP_SMBIOS_FIXTURE_CONTROL":"WTOP_HARDWARE_FIXTURE_CONTROL");if(!path)return 0;
    int fd=real_open(path,O_RDONLY|O_CLOEXEC);if(fd<0)return 0;
    char value=0;ssize_t size=real_read(fd,&value,1);real_close(fd);return size==1&&value=='1';
}
ssize_t read(int fd,void *buffer,size_t size) {
    if(enabled&&fd==target_fd&&blocked()){
        write_pid(getenv(target_kind==7?"WTOP_TYPEC_FIXTURE_ENTERED":target_kind==6?"WTOP_SUPPLY_FIXTURE_ENTERED":target_kind==5?"WTOP_DISPLAY_FIXTURE_ENTERED":target_kind==4?"WTOP_SPD_FIXTURE_ENTERED":target_kind==3?"WTOP_DRM_FIXTURE_ENTERED":target_kind==2?"WTOP_SMBIOS_FIXTURE_ENTERED":"WTOP_HARDWARE_FIXTURE_ENTERED"),0);
        while(blocked()){struct timespec delay={0,10000000};(void)nanosleep(&delay,NULL);}
    }
    return real_read(fd,buffer,size);
}


/* Fortified builds call the checked entry points directly. Keep the original
 * object-size check while applying the same fixture barrier as pread. */
static void block_spd_read(int fd) {
    if(enabled&&fd==target_fd&&target_kind==4&&blocked()){
        write_pid(getenv("WTOP_SPD_FIXTURE_ENTERED"),0);
        while(blocked()){struct timespec delay={0,10000000};(void)nanosleep(&delay,NULL);}
    }
}
ssize_t __pread_chk(int fd,void *buffer,size_t size,off_t offset,size_t buffer_size) {
    block_spd_read(fd);
    return real_pread_chk(fd,buffer,size,offset,buffer_size);
}
ssize_t __pread64_chk(int fd,void *buffer,size_t size,off64_t offset,size_t buffer_size) {
    block_spd_read(fd);
    return real_pread64_chk(fd,buffer,size,offset,buffer_size);
}
ssize_t pread(int fd,void *buffer,size_t size,off_t offset) {
    block_spd_read(fd);
    return real_pread(fd,buffer,size,offset);
}
