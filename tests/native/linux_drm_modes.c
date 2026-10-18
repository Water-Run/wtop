/* The production read-only entry with deterministic device/ioctl snapshots. */
#define _GNU_SOURCE
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>
enum { DENIED=1, BAD_DEVICE=2, PATH_CHANGED=4, CONNECTOR_CHANGED=8,
    ENCODER_CHANGED=16, CRTC_CHANGED=32, NO_ENCODER=64, NO_CRTC=128,
    NO_MODE=256, IO_UNSUPPORTED=512, IO_ERROR=1024, FRAMEBUFFER_FLIP=2048,
    WRONG_CONNECTOR=4096, WRONG_ENCODER=8192, WRONG_CRTC=16384, DISCONNECTED=32768,
    STAT_ERROR=65536, PATH_SYMLINK=131072 };
static unsigned scenario, opened, closed, live, connectors, encoders, crtcs;
static int fail_enabled;
static size_t allocations, fail_at;
static int fake_open(const char *path, int flags, ...) {
    assert(!strcmp(path,"/dev/dri/card1"));
    assert((flags&O_ACCMODE)==O_RDONLY&&(flags&O_NOFOLLOW)&&(flags&O_CLOEXEC)&&(flags&O_NONBLOCK));
    if(scenario&DENIED){errno=EACCES;return -1;}
    assert(!live);++opened;++live;return 42;
}
static int fake_close(int fd) {assert(fd==42&&live==1);--live;++closed;return 0;}
static void metadata(struct stat *value) {
    memset(value,0,sizeof(*value));value->st_mode=S_IFCHR|0600;
    value->st_dev=1;value->st_ino=7;value->st_rdev=makedev(scenario&BAD_DEVICE?227:226,1);
}
static int fake_fstat(int fd,struct stat *value) {
    assert(fd==42&&live==1);
    if(scenario&STAT_ERROR){errno=EIO;return -1;}
    metadata(value);return 0;
}
static int fake_lstat(const char *path,struct stat *value) {
    assert(!strcmp(path,"/dev/dri/card1")&&live==1);metadata(value);
    if(scenario&PATH_CHANGED)value->st_ino=8;
    if(scenario&PATH_SYMLINK)value->st_mode=S_IFLNK|0777;
    return 0;
}
static int fake_ioctl(int fd,unsigned long request,void *value);
#define open fake_open
#define close fake_close
#define fstat fake_fstat
#define lstat fake_lstat
#define ioctl fake_ioctl
#include "../../native/wtop_linux_drm_lua.h"
static int fake_ioctl(int fd,unsigned long request,void *value) {
    assert(fd==42&&live==1);
    assert(request==WTOP_DRM_GETCONNECTOR||request==WTOP_DRM_GETENCODER||request==WTOP_DRM_GETCRTC);
    if(scenario&IO_UNSUPPORTED){errno=ENOTTY;return -1;}
    if((scenario&IO_ERROR)&&request==WTOP_DRM_GETCRTC){errno=EIO;return -1;}
    if(request==WTOP_DRM_GETCONNECTOR) {
        wtop_drm_connector *v=value;uint32_t id=v->connector_id;
        assert(id==95&&v->count_modes==1&&v->modes_ptr&&v->count_props==0&&v->count_encoders==0);
        assert(!v->encoders_ptr&&!v->props_ptr&&!v->prop_values_ptr);
        ++connectors;memset(v,0,sizeof(*v));v->connector_id=scenario&WRONG_CONNECTOR?96:id;
        v->connection=scenario&DISCONNECTED?2:1;
        if((scenario&CONNECTOR_CHANGED)&&connectors==2)v->connection=2;
        v->connector_type=14;v->connector_type_id=1;v->count_modes=12;
        if(!(scenario&NO_ENCODER))v->encoder_id=100;
    } else if(request==WTOP_DRM_GETENCODER) {
        wtop_drm_encoder *v=value;assert(v->encoder_id==100);++encoders;
        v->encoder_id=scenario&WRONG_ENCODER?101:100;v->encoder_type=2;
        v->crtc_id=scenario&NO_CRTC?0:200;
        if((scenario&ENCODER_CHANGED)&&encoders==2)v->crtc_id=201;
    } else {
        wtop_drm_crtc *v=value;assert(v->crtc_id==200&&!v->modes_connector_pointer&&!v->count_connectors);++crtcs;
        v->crtc_id=scenario&WRONG_CRTC?201:200;v->mode_valid=scenario&NO_MODE?0:1;
        v->fb_id=(scenario&FRAMEBUFFER_FLIP)?1000+crtcs:1000;
        v->x=(scenario&FRAMEBUFFER_FLIP)?crtcs:0;
        v->mode.clock=(scenario&CRTC_CHANGED)&&crtcs==2?149000:148500;
        v->mode.hdisplay=1920;v->mode.vdisplay=1080;v->mode.htotal=2200;v->mode.vtotal=1125;
        v->mode.vrefresh=60;v->mode.flags=9;
    }
    return 0;
}
static void reset(unsigned flags) {scenario=flags;opened=closed=live=connectors=encoders=crtcs=0;}
static void arguments(lua_State *L) {
    lua_pushcfunction(L,wtop_linux_read_drm_mode);lua_pushliteral(L,"card1");
    lua_pushinteger(L,226);lua_pushinteger(L,1);lua_pushinteger(L,95);
}
static void check(lua_State *L,unsigned flags,const char *script) {
    reset(flags);arguments(L);int status=lua_pcall(L,4,1,0);
    if(status!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));
    assert(status==LUA_OK&&live==0&&opened==closed);
    lua_setglobal(L,"value");status=luaL_dostring(L,script);
    if(status!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));
    assert(status==LUA_OK);
}
struct allocator {lua_Alloc original;void *context;};
static void *allocate(void *context,void *old,size_t previous,size_t size) {
    struct allocator *a=context;
    if(size&&fail_enabled){assert(live==0);if(++allocations>=fail_at)return NULL;}
    return a->original(a->context,old,previous,size);
}
int main(void) {
    lua_State *L=luaL_newstate();assert(L);luaL_openlibs(L);
    lua_pushinteger(L,ESTALE);lua_setglobal(L,"ESTALE");
    lua_pushinteger(L,EACCES);lua_setglobal(L,"EACCES");
    lua_pushinteger(L,ENOTTY);lua_setglobal(L,"ENOTTY");
    const char *healthy="assert(value.status=='ok' and value.configured and value.backend=='drm-kms');local m=value.mode;assert(m.pixel_width==1920 and m.pixel_height==1080 and m.pixel_clock_hz==148500000 and m.horizontal_total==2200 and m.vertical_total==1125 and value.observed_at_ns>0)";
    check(L,0,healthy);assert(connectors==2&&encoders==2&&crtcs==2);
    check(L,FRAMEBUFFER_FLIP,healthy);check(L,DISCONNECTED,healthy);
    for(unsigned flag=BAD_DEVICE;flag<=CRTC_CHANGED;flag<<=1)
        check(L,flag,"assert(value.status=='gap' and value.mode==nil and value.errno==ESTALE)");
    for(unsigned flag=WRONG_CONNECTOR;flag<=WRONG_CRTC;flag<<=1)
        check(L,flag,"assert(value.status=='gap' and value.mode==nil)");
    check(L,PATH_SYMLINK,"assert(value.status=='gap' and value.mode==nil)");
    for(unsigned flag=NO_ENCODER;flag<=NO_MODE;flag<<=1)
        check(L,flag,"assert(value.status=='unavailable' and value.configured==false and value.mode==nil and value.errno==nil)");
    check(L,DENIED,"assert(value.status=='denied' and value.mode==nil and value.errno==EACCES)");assert(!opened);
    check(L,IO_UNSUPPORTED,"assert(value.status=='unavailable' and value.errno==ENOTTY and value.mode==nil)");
    check(L,IO_ERROR,"assert(value.status=='error' and value.mode==nil)");
    check(L,STAT_ERROR,"assert(value.status=='error' and value.mode==nil)");
    const char *invalid[]={"card01","card1/other","renderD128","card1extra"};
    for(unsigned i=0;i<sizeof(invalid)/sizeof(invalid[0]);++i){reset(0);arguments(L);lua_pushstring(L,invalid[i]);lua_replace(L,-5);assert(lua_pcall(L,4,1,0)==LUA_ERRRUN&&!opened);lua_pop(L,1);}
    reset(0);arguments(L);lua_pushlstring(L,"card1\0ignored",13);lua_replace(L,-5);
    assert(lua_pcall(L,4,1,0)==LUA_ERRRUN&&!opened);lua_pop(L,1);
    lua_close(L);unsigned failures=0;
    for(size_t n=1;n<1024;++n) {
        L=luaL_newstate();assert(L);reset(0);arguments(L);
        struct allocator a;a.original=lua_getallocf(L,&a.context);lua_setallocf(L,allocate,&a);
        fail_at=n;allocations=0;fail_enabled=1;int status=lua_pcall(L,4,1,0);fail_enabled=0;
        assert(!live&&opened==closed&&(status==LUA_OK||status==LUA_ERRMEM));
        lua_setallocf(L,a.original,a.context);lua_close(L);if(status==LUA_OK)break;++failures;
    }
    assert(failures>10);
    printf("ok: DRM cached-only ioctls, current mode, framebuffer flips, unconfigured/denied/unsupported, identity/state races and %u OOM positions; all descriptors closed before Lua output\n",failures);
    return 0;
}
