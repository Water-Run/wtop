/* Read-only x86 CPUID in the exec'd Linux hardware reader. The monitor never
 * changes affinity or executes optional instruction probes on its own thread. */
#define _GNU_SOURCE
#include <lua.h>
#include <lauxlib.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <errno.h>
#include "wtop_cpuid_protocol.h"
#if defined(__i386__) || defined(__x86_64__)
#include <sched.h>
static uint64_t began;
static uint64_t clock_ns(void){struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))return 0;return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;}
static int cpuid_alive(void){uint64_t now=clock_ns();return now>=began&&now-began<UINT64_C(1500000000);}
#include "wtop_cpuid_capture.h"
#define MAX_MASK_BYTES (128u*1024u)
static int contains(const unsigned char *mask,size_t size,uint32_t id){return id/8<size&&(mask[id/8]&(1u<<(id%8)))!=0;}
static int copy_packet(lua_State *L){
    const char *data=lua_touserdata(L,1);size_t size=(size_t)lua_tointeger(L,2);
    lua_pushlstring(L,data,size);return 1;
}
int wtop_linux_read_cpuid(lua_State *L){
    luaL_checkstack(L,8,"CPUID packet");
    luaL_checktype(L,1,LUA_TTABLE);size_t count=lua_rawlen(L,1);
    luaL_argcheck(L,count>0&&count<=WTOP_CPUID_CPUS,1,"invalid CPUID target count");
    uint32_t ids[WTOP_CPUID_CPUS];
    for(size_t i=0;i<count;++i){lua_rawgeti(L,1,(lua_Integer)i+1);lua_getfield(L,-1,"id");lua_Integer id=luaL_checkinteger(L,-1);lua_pop(L,2);
        luaL_argcheck(L,id>=0&&id<MAX_MASK_BYTES*8,1,"invalid CPUID CPU id");ids[i]=(uint32_t)id;
        for(size_t j=0;j<i;++j)luaL_argcheck(L,ids[j]!=ids[i],1,"duplicate CPUID CPU id");}
#if defined(__x86_64__) && defined(SYS_arch_prctl)
    /* Query only. Do not undo a caller's CPUID-faulting policy. */
    if(syscall(SYS_arch_prctl,0x1011,0)==0){lua_pushnil(L);lua_pushliteral(L,"cpuid_disabled");return 2;}
#endif
    began=clock_ns();if(!began){lua_pushnil(L);lua_pushliteral(L,"cpuid_helper_failed");return 2;}
    unsigned char *original=calloc(1,MAX_MASK_BYTES),*desired=calloc(1,MAX_MASK_BYTES);
    unsigned char *data=calloc(1,WTOP_CPUID_BYTES);
    if(!original||!desired||!data){free(original);free(desired);free(data);lua_pushnil(L);lua_pushliteral(L,"cpuid_allocation_failed");return 2;}
    size_t size=128;long actual;
    while((actual=syscall(SYS_sched_getaffinity,0,size,original))<0&&errno==EINVAL&&size<MAX_MASK_BYTES)size*=2;
    if(actual<=0||(size_t)actual>size){free(original);free(desired);free(data);lua_pushnil(L);lua_pushliteral(L,"cpuid_affinity_unavailable");return 2;}
    size=(size_t)actual;
    struct wtop_cpuid_header *header=(struct wtop_cpuid_header *)data;
    header->magic=WTOP_CPUID_MAGIC;header->version=WTOP_CPUID_LINUX_VERSION;header->cpus=(uint32_t)count;header->architecture_bits=sizeof(void *)*8;
    uint32_t offset=sizeof(*header);int restore_failed=0;
    for(size_t i=0;i<count;++i){
        if(!cpuid_alive()){free(original);free(desired);free(data);lua_pushnil(L);lua_pushliteral(L,"cpuid_probe_timeout");return 2;}
        struct wtop_cpuid_cpu *cpu=(struct wtop_cpuid_cpu *)(data+offset);
        struct wtop_cpuid_leaf *leaves=(struct wtop_cpuid_leaf *)(data+offset+sizeof(*cpu));
        cpu->id=ids[i];cpu->index=ids[i];cpu->status=WTOP_CPUID_STATUS_AFFINITY;
        if(!restore_failed&&contains(original,size,ids[i])){
            memset(desired,0,size);desired[ids[i]/8]=(unsigned char)(1u<<(ids[i]%8));
            if(!syscall(SYS_sched_setaffinity,0,size,desired)){
                int actual_cpu=sched_getcpu();
                if(actual_cpu>=0)cpu->flags|=WTOP_CPUID_FLAG_OS_ID;
                if(actual_cpu==(int)ids[i]){
                    wtop_cpuid_snapshot(cpu,leaves);
#ifdef __x86_64__
                    /* The x86-64 process ABI requires OS-managed SSE2 state.
                     * On 32-bit Linux these flags remain unknown in v2. */
                    cpu->flags|=WTOP_CPUID_FLAG_XMM|WTOP_CPUID_FLAG_SSE2;
#endif
                    if(cpu->status==WTOP_CPUID_STATUS_OK&&sched_getcpu()!=(int)ids[i])cpu->status=WTOP_CPUID_STATUS_UNSTABLE;
                }else cpu->status=WTOP_CPUID_STATUS_WRONG_CPU;
                if(!syscall(SYS_sched_setaffinity,0,size,original)){
                    memset(desired,0,size);
                    long n=syscall(SYS_sched_getaffinity,0,size,desired);
                    if(n==(long)size&&!memcmp(original,desired,size))cpu->flags|=WTOP_CPUID_FLAG_RESTORED;
                    else restore_failed=1;
                }else restore_failed=1;
                if(restore_failed)cpu->status=WTOP_CPUID_STATUS_RESTORE;
            }
        }
        if(cpu->status||cpu->flags&WTOP_CPUID_FLAG_TRUNCATED)header->flags|=1;
        offset+=(uint32_t)sizeof(*cpu)+cpu->count*(uint32_t)sizeof(*leaves);
    }
    if(!cpuid_alive()&&!restore_failed){free(original);free(desired);free(data);lua_pushnil(L);lua_pushliteral(L,"cpuid_probe_timeout");return 2;}
    if(restore_failed){free(original);free(desired);free(data);lua_pushnil(L);lua_pushliteral(L,"cpuid_affinity_restore_failed");return 2;}
    header->bytes=offset;header->checksum=wtop_cpuid_checksum(data+sizeof(*header),offset-(uint32_t)sizeof(*header));
    free(original);free(desired);
    /* Copy into a Lua-owned buffer under a protected call so an allocation
     * failure cannot strand the native packet. Affinity is already restored. */
    lua_pushcfunction(L,copy_packet);lua_pushlightuserdata(L,data);lua_pushinteger(L,offset);
    int status=lua_pcall(L,2,1,0);free(data);
    if(status!=LUA_OK)return lua_error(L);
    return 1;
}
#else
int wtop_linux_read_cpuid(lua_State *L){lua_pushnil(L);lua_pushliteral(L,"cpuid_unsupported_architecture");return 2;}
#endif
