/* Real parser and registry join, with deterministic kernel/IOKit snapshots. */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <sys/sysctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <net/if_mib.h>
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { REPLACED=1, REPARENTED=2, REG_DUPLICATE=4, REG_FAILED=8,
    REG_INVALID=16, MIB_FAILED=32, MIB_SHORT=64, MIB_NAME=128,
    SHORT_LINK=256, LONG_NAME=512, SHORT_MAC=1024, BAD_LENGTH=2048,
    ROUTE_DUPLICATE=4096, OVERSIZE=8192, REG_NAME=16384, INDEX_CHANGED=32768,
    EMBEDDED_NUL=65536, GROW_ONCE=131072, COUNTER_TOO_LARGE=262144 };
static unsigned mode, phase, references, enumerations;
static unsigned captures;
static int oom_enabled, fail_allocation;
static char route[4096];
static size_t route_length;
struct iterator {unsigned used,kind,entry,cursor;};
static struct iterator iterators[16];
static unsigned retain(unsigned object){if(object)++references;return object;}
static unsigned new_iterator(unsigned kind,unsigned entry){
    for(unsigned i=0;i<16;++i)if(!iterators[i].used){iterators[i]=(struct iterator){1,kind,entry,0};++references;return 100+i;}
    assert(0);return 0;
}
static CFMutableDictionaryRef fixture_matching(const char *name){
    assert(!strcmp(name,"IONetworkInterface"));
    return CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
}
static kern_return_t fixture_services(mach_port_t port,CFDictionaryRef matching,io_iterator_t *out){
    (void)port;CFRelease(matching);++enumerations;*out=0;
    if(mode&REG_FAILED)return KERN_FAILURE;
    *out=new_iterator(1,0);return KERN_SUCCESS;
}
static io_object_t fixture_next(io_iterator_t handle){
    struct iterator *it=&iterators[handle-100];assert(it->used);unsigned n=it->cursor++;
    if(it->kind==1){unsigned entries[]={5,9,15};unsigned count=mode&REG_DUPLICATE?3:2;return n<count?retain(entries[n]):0;}
    if(n)return 0;
    unsigned parent=it->entry==2?1:it->entry==3?2:it->entry==4?2:it->entry==5||it->entry==15?4:it->entry==8?3:it->entry==9?8:0;
    if((mode&REPARENTED)&&phase&&it->entry==4)parent=3;
    return retain(parent);
}
static boolean_t fixture_valid(io_iterator_t handle){return !((mode&REG_INVALID)&&iterators[handle-100].kind==1);}
static kern_return_t fixture_release(io_object_t object){
    assert(object&&references);--references;
    if(object>=100){assert(iterators[object-100].used);if(oom_enabled&&enumerations==2&&iterators[object-100].kind==1)fail_allocation=1;iterators[object-100].used=0;}
    return KERN_SUCCESS;
}
static kern_return_t fixture_parent(io_registry_entry_t entry,const io_name_t plane,io_iterator_t *out){(void)plane;*out=new_iterator(2,entry);return KERN_SUCCESS;}
static boolean_t fixture_plane(io_registry_entry_t entry,const io_name_t plane){(void)plane;return entry!=1;}
static kern_return_t fixture_id(io_registry_entry_t entry,uint64_t *id){*id=1000+entry;if((mode&REPLACED)&&phase&&entry==5)*id+=10000;return KERN_SUCCESS;}
static boolean_t fixture_class(io_object_t entry,const io_name_t name){return !strcmp(name,"IOPCIDevice")?entry==2:!strcmp(name,"IOUSBHostDevice")?entry==3:0;}
static io_registry_entry_t fixture_root(mach_port_t port){(void)port;return retain(1);}
static boolean_t fixture_equal(io_object_t a,io_object_t b){return a==b;}
static CFTypeRef fixture_property(io_registry_entry_t entry,CFStringRef key,CFAllocatorRef allocator,IOOptionBits options){
    (void)allocator;(void)options;
    if(CFEqual(key,CFSTR(kIOBSDNameKey))){
        if((mode&REG_NAME)&&phase&&entry==5)return CFRetain(CFSTR("en9"));
        return CFRetain(entry==9?CFSTR("en1"):CFSTR("en0"));
    }
    if(CFEqual(key,CFSTR("CFBundleIdentifier")))return CFRetain(CFSTR("fixture.driver"));
    return NULL;
}
static unsigned fixture_index(const char *name){
    if((mode&INDEX_CHANGED)&&phase&&!strcmp(name,"en0"))return 10;
    if(!strcmp(name,"en0")||!strcmp(name,"en9"))return 1;
    return !strcmp(name,"en1")?2:!strcmp(name,"lo0")?3:0;
}
static int fixture_sysctl(const int *query,unsigned count,void *output,size_t *length,void *new_value,size_t new_length){
    (void)new_value;(void)new_length;assert(count==6);
    if(query[1]==PF_ROUTE){
        if(!output){*length=mode&OVERSIZE?64u*1024u*1024u:route_length;return 0;}
        if((mode&GROW_ONCE)&&++captures==1){*length+=8192;errno=ENOMEM;return -1;}
        assert(*length>=route_length);memcpy(output,route,route_length);*length=route_length;phase=1;return 0;
    }
    assert(query[1]==PF_LINK);unsigned index=(unsigned)query[4];
    if((mode&MIB_FAILED)&&index==1){errno=ENOENT;return -1;}
    struct ifmibdata data;memset(&data,0,sizeof(data));
    snprintf(data.ifmd_name,sizeof(data.ifmd_name),"%s",index==1?(mode&MIB_NAME?"wrong":"en0"):index==2?"en1":"lo0");
    data.ifmd_flags=IFF_UP|IFF_RUNNING;data.ifmd_data.ifi_mtu=1500;
    data.ifmd_data.ifi_ibytes=UINT64_C(10000000000)+index;
    if((mode&COUNTER_TOO_LARGE)&&index==1)data.ifmd_data.ifi_ibytes=UINT64_MAX;
    data.ifmd_data.ifi_obytes=UINT64_C(20000000000)+index;
    data.ifmd_data.ifi_lastchange.tv_sec=123;data.ifmd_data.ifi_lastchange.tv_usec=456;
    memcpy(output,&data,sizeof(data));*length=(mode&MIB_SHORT)&&index==1?sizeof(data)-1:sizeof(data);return 0;
}
#define IOServiceMatching fixture_matching
#define IOServiceGetMatchingServices fixture_services
#define IOIteratorNext fixture_next
#define IOIteratorIsValid fixture_valid
#define IOObjectRelease fixture_release
#define IORegistryEntryGetParentIterator fixture_parent
#define IORegistryEntryInPlane fixture_plane
#define IORegistryEntryGetRegistryEntryID fixture_id
#define IOObjectConformsTo fixture_class
#define IORegistryGetRootEntry fixture_root
#define IOObjectIsEqualTo fixture_equal
#define IORegistryEntryCreateCFProperty fixture_property
#define if_nametoindex fixture_index
#define sysctl fixture_sysctl
#include "../../native/wtop_macos_net.c"

static void append_route(unsigned index){
    struct if_msghdr2 m;struct sockaddr_dl link;memset(&m,0,sizeof(m));memset(&link,0,sizeof(link));
    const char *name=index==1?"en0":index==2?"en1":"lo0";size_t n=strlen(name);
    size_t prefix=offsetof(struct sockaddr_dl,sdl_data);size_t size=sizeof(m)+prefix+n+6;
    m.ifm_msglen=(uint16_t)size;m.ifm_version=RTM_VERSION;m.ifm_type=RTM_IFINFO2;m.ifm_index=(unsigned short)index;
    m.ifm_addrs=RTA_IFP;m.ifm_flags=IFF_UP|IFF_RUNNING;m.ifm_data.ifi_mtu=1500;
    m.ifm_data.ifi_ibytes=1234;m.ifm_data.ifi_obytes=5678;
    link.sdl_len=(unsigned char)(prefix+n+6);link.sdl_family=AF_LINK;link.sdl_index=(unsigned short)index;link.sdl_nlen=(unsigned char)n;link.sdl_alen=6;
    if(index==1){
        if(mode&SHORT_LINK)link.sdl_len=1;
        if(mode&LONG_NAME)link.sdl_nlen=100;
        if(mode&SHORT_MAC)link.sdl_len=(unsigned char)(prefix+n);
        if(mode&BAD_LENGTH)m.ifm_msglen=3;
    }
    memcpy(route+route_length,&m,sizeof(m));memcpy(route+route_length+sizeof(m),&link,prefix);
    memcpy(route+route_length+sizeof(m)+prefix,name,n);
    if((mode&EMBEDDED_NUL)&&index==1)route[route_length+sizeof(m)+prefix+1]=0;
    memset(route+route_length+sizeof(m)+prefix+n,1,6);route_length+=size;
}
static void build_routes(void){
    memset(route,0,sizeof(route));route_length=5;
    /* A short unrelated route message makes the following structs unaligned. */
    uint16_t length=5;memcpy(route,&length,2);route[2]=RTM_VERSION;route[3]=RTM_NEWADDR;
    append_route(1);append_route(2);append_route(3);if(mode&ROUTE_DUPLICATE)append_route(1);
}
static void check(lua_State *L,unsigned flags,const char *script){
    mode=flags;phase=references=enumerations=captures=0;build_routes();
    lua_pushcfunction(L,wtop_collect_network);int status=lua_pcall(L,0,1,0);
    if(status!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));assert(status==LUA_OK&&references==0);
    lua_setglobal(L,"data");status=luaL_dostring(L,script);
    if(status!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));assert(status==LUA_OK);
}
struct allocator{lua_Alloc original;void *context;};
static void *failing_allocator(void *context,void *pointer,size_t old,size_t size){
    struct allocator *a=context;if(size&&fail_allocation){assert(references==0);return NULL;}return a->original(a->context,pointer,old,size);
}
int main(void){
    lua_State *L=luaL_newstate();assert(L);luaL_openlibs(L);
    check(L,0,"assert(data.quality==nil and #data.interfaces==3 and data.total==3); "
        "local a,b,c=data.interfaces[1],data.interfaces[2],data.interfaces[3]; "
        "assert(a.counter_bits==64 and a.counters.rx_bytes==10000000001 and a._registry_entry_id=='ioreg:1005'); "
        "assert(a._registry_parent_id=='ioreg:1002' and a.hardware and a.driver=='fixture.driver'); "
        "assert(b._registry_parent_bus=='usb' and b._registry_parent_id=='ioreg:1003'); "
        "assert(c._registry_entry_id==nil and c.hardware==nil and c._registry_parent_id==nil and c._interface_last_change=='123:456')");
    for(unsigned flag=REPLACED;flag<=REG_DUPLICATE;flag<<=1)
        check(L,flag,"assert(data.quality=='partial' and data.interfaces[1].counters.rx_bytes==nil and data.interfaces[1]._registry_parent_id==nil)");
    check(L,REG_FAILED,"assert(data.quality=='partial' and data.interfaces[1]._registry_entry_id==nil and data.interfaces[1].counters.rx_bytes==10000000001)");
    check(L,REG_INVALID,"assert(data.quality=='partial' and data.interfaces[1].counters.rx_bytes==nil)");
    for(unsigned flag=MIB_FAILED;flag<=MIB_SHORT;flag<<=1)
        check(L,flag,"assert(data.quality=='partial' and data.interfaces[1].counter_bits==32 and data.interfaces[1].counter_quality=='estimated' and data.interfaces[1].counters.rx_bytes==1234 and data.interfaces[2].counter_bits==64)");
    check(L,MIB_NAME,"assert(data.quality=='partial' and data.interfaces[1].counters.rx_bytes==nil)");
    for(unsigned flag=SHORT_LINK;flag<=SHORT_MAC;flag<<=1)
        check(L,flag,"assert(data.quality=='partial' and #data.interfaces==2 and data.interfaces[1].name=='en1')");
    check(L,BAD_LENGTH,"assert(data.quality=='partial' and #data.interfaces==0)");
    check(L,ROUTE_DUPLICATE,"assert(data.quality=='partial' and #data.interfaces==2 and data.interfaces[1].name=='en1')");
    check(L,REG_NAME,"assert(data.quality=='partial' and data.interfaces[1].counters.rx_bytes==nil)");
    check(L,INDEX_CHANGED,"assert(data.quality=='partial' and data.interfaces[1].counters.rx_bytes==nil)");
    check(L,EMBEDDED_NUL,"assert(data.quality=='partial' and #data.interfaces==2)");
    check(L,GROW_ONCE,"assert(data.quality==nil and #data.interfaces==3)");assert(captures==2);
    check(L,COUNTER_TOO_LARGE,"assert(data.quality=='partial' and data.interfaces[1].counters.rx_bytes==nil and data.interfaces[1].counters.tx_bytes==20000000001)");
    mode=OVERSIZE;phase=references=enumerations=0;build_routes();lua_pushcfunction(L,wtop_collect_network);assert(lua_pcall(L,0,2,0)==LUA_OK&&lua_isnil(L,-2)&&references==0);lua_pop(L,2);
    mode=phase=references=enumerations=0;build_routes();struct allocator a;a.original=lua_getallocf(L,&a.context);lua_setallocf(L,failing_allocator,&a);
    lua_pushcfunction(L,wtop_collect_network);oom_enabled=1;int status=lua_pcall(L,0,1,0);oom_enabled=fail_allocation=0;
    assert(status==LUA_ERRMEM&&references==0);lua_setallocf(L,a.original,a.context);lua_close(L);
    puts("macOS network: current registry/MIB identity, PCI/USB owners, software interfaces, replacement/ambiguity, per-interface fallback, bounds, unaligned messages, NULs and OOM cleanup passed");return 0;
}
