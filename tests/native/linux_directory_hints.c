#define _DEFAULT_SOURCE
#define _BSD_SOURCE
#define _SVID_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <lua.h>
#include <lauxlib.h>
#include <dirent.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static unsigned opened, closed, reads;
static int mode, failing, errno_noise, with_hints=1;
static size_t calls, fail_at;
static DIR *fixture_open(const char *path) { DIR *d=opendir(path);if(d)++opened;return d; }
static int fixture_close(DIR *d) {
    ++closed;int rc=closedir(d);
    if(mode==6){errno=EIO;return -1;}
    return rc;
}
static struct dirent *fixture_read(DIR *d) {
    ++reads;
    if(mode==2&&reads==3){errno=EBADF;return NULL;}
    if(mode==3||mode==5){static struct dirent generated;
        if(reads>9000){if(mode!=5)errno=0;return NULL;}
        strcpy(generated.d_name,"regular");generated.d_type=DT_REG;return &generated;
    }
    struct dirent *entry=readdir(d);
    if(entry&&mode==1)entry->d_type=DT_UNKNOWN;
    return entry;
}
#define opendir fixture_open
#define closedir fixture_close
#define readdir fixture_read
#undef _DEFAULT_SOURCE
#undef _POSIX_C_SOURCE
#include "../../native/wtop_native.c"
struct allocator {lua_Alloc original;void *context;};
static void *allocate(void *context,void *old,size_t previous,size_t size) {
    struct allocator *a=context;
    if(size&&failing&&++calls>=fail_at)return NULL;
    void *result=a->original(a->context,old,previous,size);
    if(result&&errno_noise)errno=EIO;
    return result;
}
static void prepare(lua_State *L,const char *path,lua_Integer limit) {
    luaL_newmetatable(L,IO_GUARD_METATABLE);
    lua_pushcfunction(L,l_io_guard_close);lua_setfield(L,-2,"__close");
    lua_pushcfunction(L,l_io_guard_close);lua_setfield(L,-2,"__gc");lua_pop(L,1);
    lua_pushcfunction(L,with_hints?l_listdir_hints:l_listdir);lua_pushstring(L,path);lua_pushinteger(L,limit);
    opened=closed=reads=0;
}
int main(void) {
    char path[]="/tmp/wtop-dirtypes-fixture-XXXXXX";assert(mkdtemp(path));
    char filename[512];const char *names[]={"alpha","beta","gamma"};
    for(unsigned i=0;i<3;++i){snprintf(filename,sizeof(filename),"%s/%s",path,names[i]);int fd=open(filename,O_CREAT|O_EXCL|O_WRONLY,0600);assert(fd>=0);close(fd);}
    snprintf(filename,sizeof(filename),"%s/child",path);assert(!mkdir(filename,0700));
    snprintf(filename,sizeof(filename),"%s/link",path);assert(!symlink("child",filename));
    lua_State *L=luaL_newstate();assert(L);
    prepare(L,path,100);assert(lua_pcall(L,2,4,0)==LUA_OK&&opened==closed&&lua_rawlen(L,1)==5&&!lua_toboolean(L,3));
    assert(lua_type(L,4)==LUA_TSTRING&&lua_rawlen(L,4)==5);
    const char *hints=lua_tostring(L,4);unsigned regular=0,unknown=0;
    for(int i=1;i<=5;++i){lua_rawgeti(L,1,i);const char *name=lua_tostring(L,-1);assert(name);
      if(!strcmp(name,"child")||!strcmp(name,"link")){assert(hints[i-1]=='?');unknown++;}
      else{
#ifdef _DIRENT_HAVE_D_TYPE
        assert(hints[i-1]=='f');
#else
        assert(hints[i-1]=='?');
#endif
        regular++;
      }lua_pop(L,1);}
    assert(regular==3&&unknown==2);lua_settop(L,0);
    mode=1;prepare(L,path,100);assert(lua_pcall(L,2,4,0)==LUA_OK&&opened==closed&&lua_rawlen(L,1)==5&&lua_rawlen(L,4)==5);lua_settop(L,0);
    mode=0;prepare(L,path,2);assert(lua_pcall(L,2,4,0)==LUA_OK&&opened==closed&&lua_rawlen(L,1)==2&&lua_toboolean(L,3)&&lua_rawlen(L,4)==2);lua_settop(L,0);
    mode=2;prepare(L,path,100);assert(lua_pcall(L,2,4,0)==LUA_OK&&opened==closed&&lua_isnil(L,1)&&lua_tointeger(L,3)==EBADF);lua_close(L);
    L=luaL_newstate();assert(L);mode=3;prepare(L,path,10000);
    assert(lua_pcall(L,2,4,0)==LUA_OK&&opened==closed&&lua_rawlen(L,1)==9000&&lua_rawlen(L,4)==9000);lua_close(L);
    mode=0;unsigned failures=0;
    for(size_t n=1;n<1024;++n) {
        L=luaL_newstate();assert(L);prepare(L,path,100);
        struct allocator a;a.original=lua_getallocf(L,&a.context);lua_setallocf(L,allocate,&a);
        calls=0;fail_at=n;failing=1;int status=lua_pcall(L,2,4,0);failing=0;
        if(opened!=closed)fprintf(stderr,"budget=%zu rc=%d opened=%u closed=%u reads=%u\n",n,status,opened,closed,reads);
        assert(opened==closed);
        assert(status==LUA_OK||status==LUA_ERRMEM);
        lua_setallocf(L,a.original,a.context);lua_close(L);
        if(status==LUA_OK)break;
        ++failures;
    }
    assert(failures>5);
    unsigned large_failures=0;mode=3;
    for(size_t n=1;n<128;++n){
      L=luaL_newstate();assert(L);prepare(L,path,10000);
      struct allocator a;a.original=lua_getallocf(L,&a.context);lua_setallocf(L,allocate,&a);
      calls=0;fail_at=n;failing=1;int rc=lua_pcall(L,2,4,0);failing=0;
      assert(opened==closed&&(rc==LUA_OK||rc==LUA_ERRMEM));lua_setallocf(L,a.original,a.context);lua_close(L);
      if(rc==LUA_OK)break;
      large_failures++;
    }
    assert(large_failures>failures);mode=0;
    for(int hints_enabled=0;hints_enabled<=1;hints_enabled++){
      with_hints=hints_enabled;L=luaL_newstate();assert(L);
      mode=5;prepare(L,path,10000);
      struct allocator a;a.original=lua_getallocf(L,&a.context);lua_setallocf(L,allocate,&a);errno_noise=1;
      assert(lua_pcall(L,2,4,0)==LUA_OK&&opened==closed&&lua_rawlen(L,1)==9000);
      errno_noise=0;lua_setallocf(L,a.original,a.context);lua_settop(L,0);
      mode=6;prepare(L,path,100);
      assert(lua_pcall(L,2,4,0)==LUA_OK&&opened==closed&&lua_isnil(L,1)&&lua_tointeger(L,3)==EIO);
      lua_close(L);
    }
    with_hints=1;mode=0;
    for(unsigned i=0;i<3;++i){snprintf(filename,sizeof(filename),"%s/%s",path,names[i]);assert(!unlink(filename));}
    snprintf(filename,sizeof(filename),"%s/link",path);assert(!unlink(filename));
    snprintf(filename,sizeof(filename),"%s/child",path);assert(!rmdir(filename));assert(!rmdir(path));
    printf("ok: compact hints, 9000 entry buffer growth, unknown/error/bounds, %u small + %u large persistent Lua-OOM positions close every DIR\n",failures,large_failures);
    return 0;
}
