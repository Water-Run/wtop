/* Exercise production affinity/error/allocation behavior with independent
 * syscall outcomes. CPUID instruction contents remain real on x86. */
#define _GNU_SOURCE
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sched.h>
#include <time.h>
#include <errno.h>
#if defined(__i386__) || defined(__x86_64__)
static unsigned char current_mask[131072],initial_mask[131072];
static int mode,pins,restores,current_cpu,getcpu_calls,gets,allocations,blocks,fail_at;
static uint64_t ticks;
static void reset(int value){
 mode=value;pins=restores=getcpu_calls=gets=allocations=0;current_cpu=0;ticks=1000000000;
 memset(initial_mask,0,sizeof(initial_mask));
 unsigned ids[]={0,65,4096,1048575};for(unsigned i=0;i<4;++i)initial_mask[ids[i]/8]|=1u<<(ids[i]%8);
 memcpy(current_mask,initial_mask,sizeof(current_mask));assert(!blocks);
}
static long fake_syscall(long number,...){
 va_list ap;va_start(ap,number);
 if(number==SYS_arch_prctl){(void)va_arg(ap,int);(void)va_arg(ap,int);va_end(ap);if(mode==8)return 0;if(mode==12){errno=EINVAL;return -1;}return 1;}
 assert(number==SYS_sched_getaffinity||number==SYS_sched_setaffinity);
 int who=va_arg(ap,int);size_t size=va_arg(ap,size_t);unsigned char *mask=va_arg(ap,unsigned char *);va_end(ap);assert(who==0);
 if(number==SYS_sched_getaffinity){
  ++gets;if(mode==2){errno=EPERM;return -1;}
  if(size<sizeof(current_mask)){errno=EINVAL;return -1;}
  assert(size==sizeof(current_mask));memcpy(mask,current_mask,size);return (long)size;
 }
 assert(size==sizeof(current_mask));
 if(!memcmp(mask,initial_mask,size)){
  ++restores;if(mode==6){errno=EINVAL;return -1;}
  memcpy(current_mask,mask,size);if(mode==7)current_mask[8]=0;return 0;
 }
 ++pins;if(mode==3){errno=EINVAL;return -1;}
 memcpy(current_mask,mask,size);unsigned bits=0;
 for(size_t i=0;i<size;++i)for(unsigned b=0;b<8;++b)if(mask[i]&(1u<<b)){++bits;current_cpu=(int)(i*8+b);}
 assert(bits==1);return 0;
}
static int fake_getcpu(void){++getcpu_calls;return current_cpu+((mode==4||(mode==5&&getcpu_calls%2==0))?1:0);}
static int fake_clock(clockid_t clock,struct timespec *out){assert(clock==CLOCK_MONOTONIC);out->tv_sec=ticks/1000000000;out->tv_nsec=ticks%1000000000;if(mode==9)ticks+=400000000;return 0;}
static void *counted_calloc(size_t n,size_t size){if(++allocations==fail_at)return NULL;void *p=calloc(n,size);if(p)++blocks;return p;}
static void counted_free(void *p){if(p){assert(blocks>0);--blocks;free(p);}}
#define syscall fake_syscall
#define sched_getcpu fake_getcpu
#define clock_gettime fake_clock
#define calloc counted_calloc
#define free counted_free
#include "../../native/wtop_linux_cpuid.c"
#undef syscall
#undef sched_getcpu
#undef clock_gettime
#undef calloc
#undef free
struct allocation {size_t calls,fail;};
static void *lua_allocate(void *opaque,void *old,size_t old_size,size_t size){
 struct allocation *a=opaque;(void)old_size;
 if(!size){free(old);return NULL;}if(a->fail&&++a->calls>=a->fail)return NULL;return realloc(old,size);
}
static void push_targets(lua_State *L,int count){
 static const int ids[]={0,65,4096,1048575};lua_newtable(L);
 for(int i=0;i<count;++i){lua_newtable(L);lua_pushinteger(L,ids[i]);lua_setfield(L,-2,"id");lua_rawseti(L,-2,i+1);}
}
static int call(lua_State *L,int count){lua_settop(L,0);lua_pushcfunction(L,wtop_linux_read_cpuid);push_targets(L,count);return lua_pcall(L,1,2,0);}
static void packet(lua_State *L,int count,unsigned status){
 size_t size;const unsigned char *raw=(const unsigned char *)lua_tolstring(L,-2,&size);assert(raw&&size>=32);
 struct wtop_cpuid_header header;memcpy(&header,raw,sizeof(header));assert(header.version==2&&header.cpus==(unsigned)count&&header.bytes==size);
 assert(header.checksum==wtop_cpuid_checksum(raw+32,(uint32_t)size-32));
 size_t at=32;unsigned ids[]={0,65,4096,1048575};
 for(int i=0;i<count;++i){struct wtop_cpuid_cpu cpu;memcpy(&cpu,raw+at,sizeof(cpu));assert(cpu.id==ids[i]&&cpu.index==ids[i]&&cpu.group==0&&cpu.status==status);
  if(!status)assert(cpu.count>0&&(cpu.flags&WTOP_CPUID_FLAG_RESTORED)&&(cpu.flags&WTOP_CPUID_FLAG_OS_ID));
  at+=sizeof(cpu)+cpu.count*sizeof(struct wtop_cpuid_leaf);}
 assert(at==size);
}
int main(void){
 lua_State *L=luaL_newstate();assert(L);
 for(int value=0;value<=12;++value){
  if(value==1||value==10||value==11)continue;
  reset(value);assert(call(L,value==9?2:4)==LUA_OK);assert(!blocks);
  const char *reason=lua_tostring(L,-1);
  if(value==2||value==6||value==7||value==8||value==9){
   assert(lua_isnil(L,-2)&&reason);
   assert(!strcmp(reason,value==2?"cpuid_affinity_unavailable":value==8?"cpuid_disabled":value==9?"cpuid_probe_timeout":"cpuid_affinity_restore_failed"));
   if(value==8)assert(!gets&&!pins);
  }else packet(L,4,value==3?1:value==4?3:value==5?5:0);
  if(value!=6&&value!=7)assert(!memcmp(current_mask,initial_mask,sizeof(current_mask)));
 }
 for(int point=1;point<=3;++point){reset(0);fail_at=point;assert(call(L,4)==LUA_OK&&lua_isnil(L,-2));assert(!strcmp(lua_tostring(L,-1),"cpuid_allocation_failed"));fail_at=0;assert(!blocks&&!pins);}
#if defined(__x86_64__) && defined(SYS_arch_prctl)
 reset(8);
 if(!syscall(SYS_arch_prctl,0x1012,0)){
  assert(call(L,1)==LUA_OK&&lua_isnil(L,-2)&&!strcmp(lua_tostring(L,-1),"cpuid_disabled"));
  assert(syscall(SYS_arch_prctl,0x1011,0)==0);
  assert(!syscall(SYS_arch_prctl,0x1012,1));
  puts("Linux CPUID actual disabled-instruction guard passed");
 }
#endif
 for(int bad=0;bad<7;++bad){
  reset(0);lua_settop(L,0);lua_pushcfunction(L,wtop_linux_read_cpuid);lua_newtable(L);
  int count=bad==0?0:bad==1?2:bad==6?513:1;
  for(int i=0;i<count;++i){
   if(bad==4)lua_pushboolean(L,0);
   else{lua_newtable(L);if(bad==5)lua_pushnumber(L,1.5);else lua_pushinteger(L,bad==2?-1:bad==3?1048576:0);lua_setfield(L,-2,"id");}
   lua_rawseti(L,-2,i+1);
  }
  assert(lua_pcall(L,1,2,0)==LUA_ERRRUN);assert(!blocks&&!pins&&!gets);
 }
 puts("Linux CPUID invalid target types/ranges/duplicates/counts rejected before affinity or allocation");
 lua_close(L);
 unsigned failures=0,successes=0;
 for(size_t point=1;point<=24;++point){
  reset(0);struct allocation a={0,0};
#if LUA_VERSION_NUM>=505
  L=lua_newstate(lua_allocate,&a,0);
#else
  L=lua_newstate(lua_allocate,&a);
#endif
  assert(L);
  lua_pushcfunction(L,wtop_linux_read_cpuid);push_targets(L,4);a.calls=0;a.fail=point;
  int status=lua_pcall(L,1,2,0);a.fail=0;
  if(status==LUA_ERRMEM)++failures;else{assert(status==LUA_OK);++successes;}
  assert(!blocks&&!memcmp(current_mask,initial_mask,sizeof(current_mask)));lua_close(L);
 }
 assert(failures&&successes);
 printf("Linux CPUID native: sparse CPU IDs,mask growth,pin/restore/identity/disabled/timeout,3 allocation sites and%u Lua OOM/%u successes passed\n",failures,successes);
 return 0;
}
#else
#include "../../native/wtop_linux_cpuid.c"
int main(void){
 lua_State *L=luaL_newstate();assert(L);assert(wtop_linux_read_cpuid(L)==2);
 assert(lua_isnil(L,-2)&&!strcmp(lua_tostring(L,-1),"cpuid_unsupported_architecture"));
 lua_close(L);puts("Linux CPUID native: non-x86 unavailable guard passed");return 0;
}
#endif
