/* Logical processor identity/counters from Mach; physical relationships stay
 * unknown when the OS does not expose them. */
#include <lua.h>
#include <lauxlib.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/host_info.h>
#include <mach/processor_info.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include "wtop_macos.h"
#include "wtop_macos_cpu.h"

static host_t cached_host;
static int host_cleanup_registered;
/* mach_host_self() returns an owned send right each time. CPU, CPUInfo and
 * memory share one right for this process; polling must not grow its urefs. */
void wtop_macos_host_cleanup(void){
    if(cached_host!=MACH_PORT_NULL)mach_port_deallocate(mach_task_self(),cached_host);
    cached_host=MACH_PORT_NULL;
}
host_t wtop_macos_host_port(void){
    if(cached_host!=MACH_PORT_NULL)return cached_host;
    if(!host_cleanup_registered){if(atexit(wtop_macos_host_cleanup)!=0)return MACH_PORT_NULL;host_cleanup_registered=1;}
    cached_host=mach_host_self();return cached_host;
}
static void integer_field(lua_State *L,const char *key,lua_Integer value){lua_pushinteger(L,value);lua_setfield(L,-2,key);}
static void string_field(lua_State *L,const char *key,const char *value){lua_pushstring(L,value);lua_setfield(L,-2,key);}
static void boolean_field(lua_State *L,const char *key,int value){lua_pushboolean(L,value);lua_setfield(L,-2,key);}
static void number_field(lua_State *L,const char *key,lua_Number value){lua_pushnumber(L,value);lua_setfield(L,-2,key);}
struct processor_buffer{processor_info_array_t data;natural_t count;mach_msg_type_number_t words;};
_Static_assert(sizeof(natural_t)==sizeof(uint32_t),"Mach tick counters must be 32-bit");
_Static_assert(sizeof(processor_basic_info_data_t)==PROCESSOR_BASIC_INFO_COUNT*sizeof(integer_t),"Mach basic stride");
static void release_buffer(struct processor_buffer *buffer){
    if(buffer->data)vm_deallocate(mach_task_self(),(vm_address_t)buffer->data,(vm_size_t)buffer->words*sizeof(integer_t));
    memset(buffer,0,sizeof(*buffer));
}
static int get_buffer(host_t host,processor_flavor_t flavor,unsigned stride,struct processor_buffer *out){
    memset(out,0,sizeof(*out));
    kern_return_t result=host_processor_info(host,flavor,&out->count,&out->data,&out->words);
    return result==KERN_SUCCESS&&out->data&&out->count>0&&out->count<=WTOP_MACOS_MAX_CPUS
        &&out->words==(mach_msg_type_number_t)out->count*stride;
}
static void basic_at(const struct processor_buffer *buffer,unsigned index,processor_basic_info_data_t *info){
    memcpy(info,buffer->data+index*PROCESSOR_BASIC_INFO_COUNT,sizeof(*info));
}
static int basic_valid(const struct processor_buffer *buffer){
    for(unsigned i=0;i<buffer->count;++i){
        processor_basic_info_data_t a;basic_at(buffer,i,&a);
        if(a.slot_num<0||(a.running!=0&&a.running!=1)||(a.is_master!=0&&a.is_master!=1))return 0;
        for(unsigned j=0;j<i;++j){processor_basic_info_data_t b;basic_at(buffer,j,&b);if(a.slot_num==b.slot_num)return 0;}
    }
    return 1;
}
static int same_basic(const struct processor_buffer *first,const struct processor_buffer *last){
    if(first->count!=last->count||!basic_valid(first)||!basic_valid(last))return 0;
    for(unsigned i=0;i<first->count;++i){
        processor_basic_info_data_t a,b;basic_at(first,i,&a);basic_at(last,i,&b);
        if(a.slot_num!=b.slot_num||a.cpu_type!=b.cpu_type||a.cpu_subtype!=b.cpu_subtype
            ||a.running!=b.running||a.is_master!=b.is_master)return 0;
    }
    return 1;
}
struct cpu_row{processor_basic_info_data_t identity;uint32_t ticks[CPU_STATE_MAX];};
struct cpu_capture{struct cpu_row rows[WTOP_MACOS_MAX_CPUS];host_cpu_load_info_data_t total;unsigned count;int partial,truncated;};
static int row_compare(const void *a,const void *b){
    const struct cpu_row *x=a,*y=b;return (x->identity.slot_num>y->identity.slot_num)-(x->identity.slot_num<y->identity.slot_num);
}
static void push_raw(lua_State *L,const uint32_t *ticks){
    uint64_t busy=(uint64_t)ticks[CPU_STATE_USER]+ticks[CPU_STATE_SYSTEM]+ticks[CPU_STATE_NICE];
    lua_createtable(L,0,6);integer_field(L,"busy",(lua_Integer)busy);
    integer_field(L,"total",(lua_Integer)(busy+ticks[CPU_STATE_IDLE]));
    integer_field(L,"user",ticks[CPU_STATE_USER]);integer_field(L,"system",ticks[CPU_STATE_SYSTEM]);
    integer_field(L,"nice",ticks[CPU_STATE_NICE]);integer_field(L,"idle",ticks[CPU_STATE_IDLE]);
}
int wtop_collect_cpu(lua_State *L){
    /* Lua allocations can longjmp. Allocate scratch space before acquiring any
     * out-of-line Mach buffers; release them before building the result. */
    struct cpu_capture *capture=lua_newuserdatauv(L,sizeof(*capture),0);memset(capture,0,sizeof(*capture));
    host_t host=wtop_macos_host_port();mach_msg_type_number_t total_words=HOST_CPU_LOAD_INFO_COUNT;
    if(host==MACH_PORT_NULL||host_statistics(host,HOST_CPU_LOAD_INFO,(host_info_t)&capture->total,&total_words)!=KERN_SUCCESS
        ||total_words!=HOST_CPU_LOAD_INFO_COUNT){lua_pushnil(L);lua_pushliteral(L,"host_statistics(HOST_CPU_LOAD_INFO) failed");return 2;}
    struct processor_buffer first={0},loads={0},last={0};
    /* XNU host_processor_info traverses processor_array for both flavors.
     * Its index is usable only while the ordered BASIC roster is unchanged;
     * slot_num, not the index, is the public logical CPU identity. */
    int valid=get_buffer(host,PROCESSOR_BASIC_INFO,PROCESSOR_BASIC_INFO_COUNT,&first)
        &&get_buffer(host,PROCESSOR_CPU_LOAD_INFO,PROCESSOR_CPU_LOAD_INFO_COUNT,&loads)
        &&get_buffer(host,PROCESSOR_BASIC_INFO,PROCESSOR_BASIC_INFO_COUNT,&last)
        &&first.count==loads.count&&same_basic(&first,&last);
    if(valid){
        capture->count=first.count;
        for(unsigned i=0;i<first.count;++i){basic_at(&first,i,&capture->rows[i].identity);
            processor_cpu_load_info_data_t load;memcpy(&load,loads.data+i*PROCESSOR_CPU_LOAD_INFO_COUNT,sizeof(load));
            memcpy(capture->rows[i].ticks,load.cpu_ticks,sizeof(load.cpu_ticks));}
    }else{capture->partial=1;capture->truncated=first.count>WTOP_MACOS_MAX_CPUS||loads.count>WTOP_MACOS_MAX_CPUS||last.count>WTOP_MACOS_MAX_CPUS;}
    release_buffer(&last);release_buffer(&loads);release_buffer(&first);
    qsort(capture->rows,capture->count,sizeof(capture->rows[0]),row_compare);
    static struct cpu_row previous[WTOP_MACOS_MAX_CPUS];static unsigned previous_count;static uint64_t epoch;
    int changed=previous_count!=capture->count;
    for(unsigned i=0;!changed&&i<capture->count;++i){
        const processor_basic_info_data_t *a=&previous[i].identity,*b=&capture->rows[i].identity;
        if(a->slot_num!=b->slot_num||a->cpu_type!=b->cpu_type||a->cpu_subtype!=b->cpu_subtype||a->running!=b->running)changed=1;
    }
    if(!epoch||changed){if(epoch<UINT64_MAX)++epoch;previous_count=capture->count;memcpy(previous,capture->rows,capture->count*sizeof(previous[0]));}
    lua_createtable(L,0,7);push_raw(L,capture->total.cpu_ticks);lua_setfield(L,-2,"raw");
    integer_field(L,"counter_bits",32);string_field(L,"counter_source","mach:HOST_CPU_LOAD_INFO");
    boolean_field(L,"partial",capture->partial);boolean_field(L,"truncated",capture->truncated);
    char generation[48];snprintf(generation,sizeof(generation),"mach:%llu",(unsigned long long)epoch);string_field(L,"_source_epoch",generation);
    lua_createtable(L,(int)capture->count,0);
    for(unsigned i=0;i<capture->count;++i){
        const struct cpu_row *row=&capture->rows[i];char name[32],identity[80];
        snprintf(name,sizeof(name),"cpu%d",row->identity.slot_num);
        snprintf(identity,sizeof(identity),"mach:%d:%d:%d",row->identity.slot_num,row->identity.cpu_type,row->identity.cpu_subtype);
        lua_createtable(L,0,8);integer_field(L,"id",row->identity.slot_num);string_field(L,"name",name);
        string_field(L,"_source_instance",identity);boolean_field(L,"online",row->identity.running);
        string_field(L,"identity_quality","fresh");string_field(L,"source","mach:PROCESSOR_CPU_LOAD_INFO");
        push_raw(L,row->ticks);lua_setfield(L,-2,"raw");lua_rawseti(L,-2,i+1);
    }
    lua_setfield(L,-2,"cores");double load[3];if(getloadavg(load,3)==3){lua_createtable(L,0,3);number_field(L,"one",load[0]);number_field(L,"five",load[1]);number_field(L,"fifteen",load[2]);lua_setfield(L,-2,"load");}
    return 1;
}

static int sysctl_integer(const char *name,int64_t *value){
    unsigned char bytes[8]={0};size_t size=sizeof(bytes);*value=0;
    if(sysctlbyname(name,bytes,&size,NULL,0)!=0)return 0;
    if(size==4){int32_t n;memcpy(&n,bytes,4);*value=n;return 1;}
    if(size==8){memcpy(value,bytes,8);return 1;}return 0;
}
static int sysctl_text(const char *name,char *out,size_t capacity){
    size_t size=capacity;memset(out,0,capacity);
    if(sysctlbyname(name,out,&size,NULL,0)!=0||!size||size>capacity||out[size-1]!=0||strlen(out)+1!=size){out[0]=0;return 0;}
    return out[0]!=0;
}
struct cache_total{int level;const char *type;int64_t instances,total;};
struct perf_level{char name[64];int64_t logical,physical;int has_logical,has_physical;};
struct info_capture{
    char model[256],vendor[64];int64_t logical,physical,packages,levels,family,model_id,stepping;
    int has_family,has_model_id,has_stepping,partial,truncated;
    struct perf_level level[8];struct cache_total caches[8];int cache_count;
    struct cpu_row rows[WTOP_MACOS_MAX_CPUS];unsigned count;
};
static void add_cache(struct info_capture *capture,int level,const char *type,int64_t size,int64_t instances){
    if(size<=0||instances<=0)return;
    if(size>INT64_MAX/instances){capture->partial=1;return;}
    int64_t total=size*instances;
    for(int i=0;i<capture->cache_count;++i)if(capture->caches[i].level==level&&!strcmp(capture->caches[i].type,type)){
        if(total>INT64_MAX-capture->caches[i].total||instances>INT64_MAX-capture->caches[i].instances){capture->partial=1;return;}
        capture->caches[i].total+=total;capture->caches[i].instances+=instances;return;
    }
    if(capture->cache_count==8){capture->truncated=capture->partial=1;return;}
    capture->caches[capture->cache_count++]=(struct cache_total){level,type,instances,total};
}
static void shared_cache(struct info_capture *capture,int level,const char *type,int64_t size,int64_t logical,int64_t sharing){
    if(size<=0||sharing<=0)return;
    if(logical<=0||sharing>logical||logical%sharing){capture->partial=1;return;}
    add_cache(capture,level,type,size,logical/sharing);
}
int wtop_collect_cpu_info(lua_State *L){
    struct info_capture *capture=lua_newuserdatauv(L,sizeof(*capture),0);memset(capture,0,sizeof(*capture));
    host_t host=wtop_macos_host_port();struct processor_buffer first={0},last={0};
    int before=host!=MACH_PORT_NULL&&get_buffer(host,PROCESSOR_BASIC_INFO,PROCESSOR_BASIC_INFO_COUNT,&first);
    if(!sysctl_integer("hw.logicalcpu",&capture->logical)||capture->logical<=0){capture->logical=0;capture->partial=1;}
    (void)sysctl_integer("hw.physicalcpu",&capture->physical);(void)sysctl_integer("hw.packages",&capture->packages);
    (void)sysctl_integer("hw.nperflevels",&capture->levels);
    (void)sysctl_text("machdep.cpu.brand_string",capture->model,sizeof(capture->model));
    (void)sysctl_text("machdep.cpu.vendor",capture->vendor,sizeof(capture->vendor));
#if defined(__arm64__)
    if(!capture->vendor[0])memcpy(capture->vendor,"Apple",6);
#endif
    capture->has_family=sysctl_integer("machdep.cpu.family",&capture->family);
    capture->has_model_id=sysctl_integer("machdep.cpu.model",&capture->model_id);
    capture->has_stepping=sysctl_integer("machdep.cpu.stepping",&capture->stepping);
    if(capture->levels<0){capture->levels=0;capture->partial=1;}
    if(capture->levels>8){capture->levels=8;capture->partial=capture->truncated=1;}
    if(capture->levels){
        for(int i=0;i<capture->levels;++i){
            char key[96];int64_t value=0,sharing=0;struct perf_level *level=&capture->level[i];
            snprintf(key,sizeof(key),"hw.perflevel%d.name",i);(void)sysctl_text(key,level->name,sizeof(level->name));
            snprintf(key,sizeof(key),"hw.perflevel%d.logicalcpu",i);level->has_logical=sysctl_integer(key,&level->logical)&&level->logical>=0&&level->logical<=512;
            snprintf(key,sizeof(key),"hw.perflevel%d.physicalcpu",i);level->has_physical=sysctl_integer(key,&level->physical)&&level->physical>=0&&level->physical<=512;
            if(!level->has_logical||!level->has_physical){capture->partial=1;continue;}
            snprintf(key,sizeof(key),"hw.perflevel%d.l1dcachesize",i);if(sysctl_integer(key,&value))add_cache(capture,1,"Data",value,level->physical);
            snprintf(key,sizeof(key),"hw.perflevel%d.l1icachesize",i);if(sysctl_integer(key,&value))add_cache(capture,1,"Instruction",value,level->physical);
            snprintf(key,sizeof(key),"hw.perflevel%d.cpusperl2",i);(void)sysctl_integer(key,&sharing);
            snprintf(key,sizeof(key),"hw.perflevel%d.l2cachesize",i);if(sysctl_integer(key,&value))shared_cache(capture,2,"Unified",value,level->logical,sharing);
            sharing=0;snprintf(key,sizeof(key),"hw.perflevel%d.cpusperl3",i);(void)sysctl_integer(key,&sharing);
            snprintf(key,sizeof(key),"hw.perflevel%d.l3cachesize",i);if(sysctl_integer(key,&value))shared_cache(capture,3,"Unified",value,level->logical,sharing);
        }
    }else{
        uint64_t sharing[8]={0};size_t bytes=sizeof(sharing);int64_t value;
        if(sysctlbyname("hw.cacheconfig",sharing,&bytes,NULL,0)!=0||bytes>sizeof(sharing)||bytes%sizeof(sharing[0]))bytes=0;
        if(bytes>=16&&sharing[1]>0&&sharing[1]<=512){
            if(sysctl_integer("hw.l1dcachesize",&value))shared_cache(capture,1,"Data",value,capture->logical,(int64_t)sharing[1]);
            if(sysctl_integer("hw.l1icachesize",&value))shared_cache(capture,1,"Instruction",value,capture->logical,(int64_t)sharing[1]);
        }
        if(bytes>=24&&sharing[2]>0&&sharing[2]<=512&&sysctl_integer("hw.l2cachesize",&value))shared_cache(capture,2,"Unified",value,capture->logical,(int64_t)sharing[2]);
        if(bytes>=32&&sharing[3]>0&&sharing[3]<=512&&sysctl_integer("hw.l3cachesize",&value))shared_cache(capture,3,"Unified",value,capture->logical,(int64_t)sharing[3]);
    }
    int stable=before&&get_buffer(host,PROCESSOR_BASIC_INFO,PROCESSOR_BASIC_INFO_COUNT,&last)&&same_basic(&first,&last);
    if(stable){capture->count=first.count;for(unsigned i=0;i<first.count;++i)basic_at(&first,i,&capture->rows[i].identity);}
    else{capture->partial=1;if(first.count>512||last.count>512)capture->truncated=1;}
    release_buffer(&last);release_buffer(&first);qsort(capture->rows,capture->count,sizeof(capture->rows[0]),row_compare);
    if(!capture->count&&!capture->logical){lua_pushnil(L);lua_pushliteral(L,"logical CPU identity and count unavailable");return 2;}
    lua_createtable(L,0,6);string_field(L,"quality",capture->partial?"partial":"fresh");boolean_field(L,"truncated",capture->truncated);
    lua_createtable(L,0,8);
    if(capture->model[0])string_field(L,"model_name",capture->model);if(capture->vendor[0])string_field(L,"vendor",capture->vendor);
    if(capture->has_family)integer_field(L,"family",capture->family);if(capture->has_model_id)integer_field(L,"model",capture->model_id);
    if(capture->has_stepping)integer_field(L,"stepping",capture->stepping);boolean_field(L,"heterogeneous",capture->levels>1);lua_setfield(L,-2,"identity");
    lua_createtable(L,0,12);integer_field(L,"threads",capture->count?capture->count:capture->logical);
    if(capture->physical>0)integer_field(L,"physical_cores",capture->physical);if(capture->packages>0)integer_field(L,"sockets",capture->packages);
    string_field(L,"source",stable?"mach:PROCESSOR_BASIC_INFO":"sysctl:hw.logicalcpu");string_field(L,"quality","partial");
    string_field(L,"identity_quality",stable?"fresh":"partial");boolean_field(L,"truncated",capture->truncated);
    lua_createtable(L,(int)capture->count,0);unsigned online=0;
    for(unsigned i=0;i<capture->count;++i){
        const processor_basic_info_data_t *cpu=&capture->rows[i].identity;if(cpu->running)++online;
        lua_createtable(L,0,10);integer_field(L,"id",cpu->slot_num);boolean_field(L,"online",cpu->running);
        boolean_field(L,"online_known",1);boolean_field(L,"is_main",cpu->is_master);
        integer_field(L,"mach_cpu_type",cpu->cpu_type);integer_field(L,"mach_cpu_subtype",cpu->cpu_subtype);
        boolean_field(L,"package_id_known",0);boolean_field(L,"core_id_known",0);
        string_field(L,"identity_quality","fresh");string_field(L,"source","mach:PROCESSOR_BASIC_INFO");lua_rawseti(L,-2,i+1);
    }
    lua_setfield(L,-2,"logical_cpus");if(stable)integer_field(L,"online_threads",online);
    const char *lists[]={"present_cpu_list","online_cpu_list"};
    for(unsigned list=0;list<2;++list){lua_createtable(L,(int)capture->count,0);unsigned output=1;
        for(unsigned i=0;i<capture->count;++i)if(!list||capture->rows[i].identity.running){lua_pushinteger(L,capture->rows[i].identity.slot_num);lua_rawseti(L,-2,output++);}
        lua_setfield(L,-2,lists[list]);}
    lua_setfield(L,-2,"topology");
    lua_createtable(L,(int)capture->levels,0);
    for(int i=0;i<capture->levels;++i){const struct perf_level *level=&capture->level[i];char id[24];snprintf(id,sizeof(id),"type-%d",i+1);
        lua_createtable(L,0,4);string_field(L,"id",id);if(level->name[0])string_field(L,"model_name",level->name);
        if(level->has_logical)integer_field(L,"logical_cpu_count",level->logical);if(level->has_physical)integer_field(L,"physical_core_count",level->physical);lua_rawseti(L,-2,i+1);}
    lua_setfield(L,-2,"core_types");lua_createtable(L,capture->cache_count,0);
    for(int i=0;i<capture->cache_count;++i){const struct cache_total *cache=&capture->caches[i];char id[32];snprintf(id,sizeof(id),"L%d:%s",cache->level,cache->type);
        lua_createtable(L,0,5);string_field(L,"id",id);integer_field(L,"level",cache->level);string_field(L,"type",cache->type);
        integer_field(L,"total_size_bytes",cache->total);integer_field(L,"instances",cache->instances);lua_rawseti(L,-2,i+1);}
    lua_setfield(L,-2,"cache_summary");return 1;
}
