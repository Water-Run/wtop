/* IOReport consumers copy native results before allocating Lua tables. */
#include <lua.h>
#include <lauxlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include "wtop_macos.h"
#include "wtop_macos_gpu_clock.h"
#include "wtop_macos_ioreport.h"
#define MAX_CLUSTERS 8
#define MAX_TABLE_STATES 64
static void integer_field(lua_State *L,const char *key,lua_Integer value){lua_pushinteger(L,value);lua_setfield(L,-2,key);}
static void number_field(lua_State *L,const char *key,lua_Number value){lua_pushnumber(L,value);lua_setfield(L,-2,key);}
static void string_field(lua_State *L,const char *key,const char *value){lua_pushstring(L,value);lua_setfield(L,-2,key);}
static void boolean_field(lua_State *L,const char *key,int value){lua_pushboolean(L,value);lua_setfield(L,-2,key);}
static int cf_text(CFTypeRef value,char *out,size_t capacity){
    out[0]=0;if(!value||CFGetTypeID(value)!=CFStringGetTypeID())return 0;
    CFIndex length=CFStringGetLength(value),used=0;
    if(CFStringGetBytes(value,CFRangeMake(0,length),kCFStringEncodingUTF8,0,false,(UInt8*)out,(CFIndex)capacity-1,&used)!=length
        || used<=0 || used>=(CFIndex)capacity || memchr(out,0,(size_t)used))return 0;
    out[used]=0;return 1;
}
static int64_t sysctl_int64(const char *key,int64_t fallback){
    int64_t value=0;size_t size=sizeof(value);
    if(sysctlbyname(key,&value,&size,NULL,0)!=0)return fallback;
    if(size==sizeof(int32_t)){int32_t narrow;memcpy(&narrow,&value,sizeof(narrow));return narrow;}
    return size==sizeof(value)?value:fallback;
}
static double energy_scale(CFStringRef unit) {
    char text[16];
    if (!cf_text(unit, text, sizeof(text))) return 0;
    if (strcmp(text, "mJ") == 0) return 1e-3;
    if (strcmp(text, "uJ") == 0) return 1e-6;
    if (strcmp(text, "nJ") == 0) return 1e-9;
    return 0;
}

/* ------------------------------------------------------------------------
 * DVFS tables. The power manager's voltage-state properties list the
 * frequency of each performance state in order: kHz on M4 and later, Hz
 * before, told apart by magnitude. */

typedef struct {
    double hz[MAX_TABLE_STATES];
    int count;
} dvfs_table;

static int read_dvfs_table(const char *key,dvfs_table *table){
    io_iterator_t iterator=0;io_registry_entry_t entry;memset(table,0,sizeof(*table));
    CFMutableDictionaryRef matching=IOServiceNameMatching("pmgr");
    if(!matching)return 0;
    if(IOServiceGetMatchingServices(MACH_PORT_NULL,matching,&iterator)!=KERN_SUCCESS||!iterator){
        if(iterator)IOObjectRelease(iterator);return 0;
    }
    CFStringRef name=CFStringCreateWithCString(NULL,key,kCFStringEncodingUTF8);
    unsigned scanned=0;int found=0,valid=name!=NULL;
    while(name&&(entry=IOIteratorNext(iterator))){
        if(scanned++==64){valid=0;IOObjectRelease(entry);break;}
        CFTypeRef data=IORegistryEntryCreateCFProperty(entry,name,kCFAllocatorDefault,0);
        if(data){
            dvfs_table candidate={0};
            if(CFGetTypeID(data)!=CFDataGetTypeID())valid=0;
            else{
                CFIndex length=CFDataGetLength(data);const UInt8 *bytes=CFDataGetBytePtr(data);
                if(length<=0||length%8||length>MAX_TABLE_STATES*8)valid=0;
                else{
                    double maximum=0;
                    for(CFIndex offset=0;offset<length;offset+=8){
                        uint32_t hz;memcpy(&hz,bytes+offset,sizeof(hz));if(!hz)continue;
                        candidate.hz[candidate.count++]=hz;if(hz>maximum)maximum=hz;
                    }
                    if(maximum>0&&maximum<1e8)for(int i=0;i<candidate.count;++i)candidate.hz[i]*=1000;
                    if(!candidate.count)valid=0;
                    else if(found&&(table->count!=candidate.count||memcmp(table->hz,candidate.hz,(size_t)table->count*sizeof(table->hz[0]))))valid=0;
                    else{*table=candidate;found=1;}
                }
            }
            CFRelease(data);
        }
        IOObjectRelease(entry);
    }
    if(!IOIteratorIsValid(iterator))valid=0;
    if(name)CFRelease(name);IOObjectRelease(iterator);
    if(!valid||!found){memset(table,0,sizeof(*table));return 0;}return 1;
}

/* ------------------------------------------------------------------------
 * GPU */

static dvfs_table gpu_table;
static int gpu_table_state = 0;

int wtop_gpu_frequency(uint64_t owner, struct wtop_gpu_frequency *frequency) {
    static uint64_t previous_owner,previous_epoch;
    memset(frequency, 0, sizeof(*frequency));
    if (previous_owner != owner) {
        wtop_ioreport_reset(WTOP_REPORT_GPU);
        gpu_table_state = 0;
        previous_owner = owner;
    }
    if (!owner) return 0;
    if (gpu_table_state <= 0)
        gpu_table_state = read_dvfs_table("voltage-states9-sram", &gpu_table) ? 1 : -1;
    if (gpu_table_state <= 0) { wtop_ioreport_reset(WTOP_REPORT_GPU); return 0; }
    struct wtop_report_sample sample;
    enum wtop_report_status status = wtop_ioreport_sample(WTOP_REPORT_GPU, &sample);
    frequency->warming=status==WTOP_REPORT_WARMUP;
    if(status!=WTOP_REPORT_FAILED&&sample.epoch!=previous_epoch){
        previous_epoch=sample.epoch;gpu_table_state=0;
    }
    if (status != WTOP_REPORT_FRESH) { if (sample.owner) CFRelease(sample.owner); return 0; }
    CFDictionaryRef delta = sample.owner;
    CFArrayRef items = sample.items;
    int found = 0, valid = 0;
    CFIndex count = items ? CFArrayGetCount(items) : 0;
    if (count > 1024) goto done;
    for (CFIndex index = 0; index < count; ++index) {
        CFTypeRef item = CFArrayGetValueAtIndex(items, index);
        char name[32];
        if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()
            || !cf_text(wtop_ioreport.name(item), name, sizeof(name)) || strcmp(name, "GPUPH")) continue;
        int64_t driver=0;
        CFTypeRef reported_driver=CFDictionaryGetValue(item,CFSTR("DriverID"));
        if(!reported_driver||!CFNumberGetValue(reported_driver,kCFNumberSInt64Type,&driver)
            ||(uint64_t)driver!=owner)continue;
        if(wtop_ioreport.format(item)!=2)continue; /* kIOReportFormatState */
        if (++found > 1) { valid = 0; break; }
        int32_t states = wtop_ioreport.state_count(item);
        CFDataRef raw=CFDictionaryGetValue(item,CFSTR("RawElements"));
        if (states <= 0 || states > WTOP_MAX_GPU_STATES || states > CFDataGetLength(raw)/64) continue;
        struct wtop_gpu_state values[WTOP_MAX_GPU_STATES];
        int named = 1;
        unsigned next_state = UINT_MAX;
        for (int32_t state = 0; state < states; ++state) {
            if (!cf_text(wtop_ioreport.state_name(item, state), name, sizeof(name))) { named = 0; break; }
            values[state].ticks = wtop_ioreport.residency(item, state);
            if (!wtop_gpu_state_label(name, &next_state, &values[state].idle)) { named = 0; break; }
        }
        if (named) valid = wtop_gpu_clock(values, (unsigned)states, gpu_table.hz,
            (unsigned)gpu_table.count, &frequency->mean, &frequency->active);
    }
    if (valid) {
        frequency->minimum = (uint64_t)gpu_table.hz[0];
        frequency->maximum = frequency->minimum;
        for (int i = 1; i < gpu_table.count; ++i) {
            uint64_t hz = (uint64_t)gpu_table.hz[i];
            if (hz < frequency->minimum) frequency->minimum = hz;
            if (hz > frequency->maximum) frequency->maximum = hz;
        }
    }
done:
    if (delta) CFRelease(delta);
    return valid;
}

/* ------------------------------------------------------------------------
 * Energy: IOReport's energy model per SoC block, accumulated into counters
 * so the shared collector derives power the same way it does for RAPL. */


/* Energy totals count observations within one source epoch, excluding gaps. */
typedef struct {
    const char *channel, *id, *name, *kind;
    int aggregate, previous;
    uint64_t epoch, generation;
    double joules;
    char unit[16];
} energy_zone;
static energy_zone energy_zones[] = {
    {.channel="CPU Energy",.id="cpu",.name="CPU",.kind="package",.aggregate=1},
    {.channel="ECPU",.id="cpu-efficiency",.name="Efficiency cores",.kind="core"},
    {.channel="PCPU",.id="cpu-performance",.name="Performance cores",.kind="core"},
    {.channel="GPU Energy",.id="gpu",.name="GPU",.kind="uncore"},
    {.channel="ANE",.id="ane",.name="Neural Engine",.kind="uncore"},
    {.channel="DRAM",.id="dram",.name="DRAM",.kind="dram"},
};
int wtop_collect_powercap(lua_State *L) {
    struct wtop_report_sample sample;
    enum wtop_report_status status=wtop_ioreport_sample(WTOP_REPORT_ENERGY,&sample);
    int seen[6]={0},valid[6]={0},baseline[6]={0},partial=status==WTOP_REPORT_FAILED;
    int64_t values[6]={0};double scales[6]={0};char units[6][16]={{0}};
    for(CFIndex i=0;sample.items&&i<CFArrayGetCount(sample.items);++i){
        CFDictionaryRef item=CFArrayGetValueAtIndex(sample.items,i);
        char name[64],unit[16];
        if(!cf_text(wtop_ioreport.name(item),name,sizeof(name)))continue;
        for(unsigned zone=0;zone<6;++zone){
            if(strcmp(name,energy_zones[zone].channel))continue;
            if(seen[zone]++){valid[zone]=0;partial=1;continue;}
            if(wtop_ioreport.format(item)!=1){partial=1;continue;} /* kIOReportFormatSimple */
            CFDictionaryRef info=CFDictionaryGetValue(item,CFSTR("IOReportChannelInfo"));
            CFTypeRef encoded_unit=CFDictionaryGetValue(info,CFSTR("IOReportChannelUnit"));
            if(!encoded_unit||CFGetTypeID(encoded_unit)!=CFNumberGetTypeID()
                ||CFNumberIsFloatType(encoded_unit)){partial=1;continue;}
            double scale=energy_scale(wtop_ioreport.unit(item));
            int64_t value=wtop_ioreport.integer(item,0);
            if(scale<=0||value<0||!cf_text(wtop_ioreport.unit(item),unit,sizeof(unit))){partial=1;continue;}
            memcpy(units[zone],unit,strlen(unit)+1);values[zone]=value;scales[zone]=scale;valid[zone]=1;
        }
    }
    if(sample.owner)CFRelease(sample.owner);
    for(unsigned zone=0;zone<6;++zone){
        energy_zone *state=&energy_zones[zone];
        if(!valid[zone]){if(state->previous)partial=1;state->previous=0;continue;}
        baseline[zone]=status!=WTOP_REPORT_FRESH||!state->previous
            ||state->epoch!=sample.epoch||strcmp(state->unit,units[zone]);
        if(baseline[zone]){
            state->joules=0;++state->generation;state->epoch=sample.epoch;
            memcpy(state->unit,units[zone],sizeof(state->unit));
        }else{
            double total=state->joules+(double)values[zone]*scales[zone];
            if(!isfinite(total)||(values[zone]>0&&total<=state->joules)){
                valid[zone]=0;state->previous=0;partial=1;continue;
            }
            state->joules=total;
        }
        state->previous=1;
    }
    wtop_smc_begin();double system_watts=0;
    int has_system=wtop_smc_number("PSTR",&system_watts)&&isfinite(system_watts)&&system_watts>=0;
    int output=1;
    lua_createtable(L,0,7);string_field(L,"schema","dev.waterrun.wtop.macos-energy/v1");
    boolean_field(L,"_sampling_pending",status==WTOP_REPORT_WARMUP);
    lua_createtable(L,7,0);
    for(unsigned zone=0;zone<6;++zone){
        if(!valid[zone])continue;
        energy_zone *state=&energy_zones[zone];char epoch[80];
        snprintf(epoch,sizeof(epoch),"ioreport:%llu:%llu",(unsigned long long)state->epoch,(unsigned long long)state->generation);
        lua_createtable(L,0,12);string_field(L,"id",state->id);string_field(L,"name",state->name);
        string_field(L,"source_kind",state->kind);number_field(L,"energy_joules",state->joules);
        string_field(L,"_source_epoch",epoch);integer_field(L,"_sample_timestamp_ns",(lua_Integer)sample.timestamp_ns);
        string_field(L,"power_quality",baseline[zone]?"gap":"fresh");
        boolean_field(L,"aggregate",state->aggregate);boolean_field(L,"enabled",1);
        string_field(L,"source","ioreport:Energy Model");lua_rawseti(L,-2,output++);
    }
    if(has_system){
        lua_createtable(L,0,9);string_field(L,"id","system");string_field(L,"name","System total");
        string_field(L,"source_kind","platform");number_field(L,"power_watts",system_watts);
        string_field(L,"power_source","smc:PSTR");string_field(L,"power_quality","fresh");
        boolean_field(L,"aggregate",0);boolean_field(L,"enabled",1);string_field(L,"source","smc");lua_rawseti(L,-2,output++);
    }
    lua_setfield(L,-2,"zones");
    if(output==1){lua_pop(L,1);lua_pushnil(L);lua_pushliteral(L,"ioreport_energy_model_unavailable");return 2;}
    if(has_system){number_field(L,"platform_power_watts",system_watts);integer_field(L,"measured_platform_zones",1);}
    boolean_field(L,"partial",partial);string_field(L,"quality",partial?"partial":status==WTOP_REPORT_WARMUP?"gap":"fresh");
    string_field(L,"aggregate_source_kind","package");string_field(L,"aggregate_strategy","ioreport_cpu_energy");return 1;
}

/* CPU residency shares the bounded state decoder used by the GPU. */
static dvfs_table efficiency_table,performance_table;
static uint64_t cpu_epoch;
static int voltage_state(const char *name,unsigned index,unsigned clocks){
    if(*name++!='V'||*name<'0'||*name>'9')return 0;
    unsigned voltage=0,performance=0;
    while(*name>='0'&&*name<='9'){voltage=voltage*10+(unsigned)(*name++-'0');if(voltage>64)return 0;}
    if(*name++!='P'||*name<'0'||*name>'9')return 0;
    while(*name>='0'&&*name<='9'){performance=performance*10+(unsigned)(*name++-'0');if(performance>64)return 0;}
    return !*name&&voltage==index&&voltage+performance+1==clocks;
}
static int residency_frequency(CFDictionaryRef item,const dvfs_table *table,double *mean,double *active){
    if(wtop_ioreport.format(item)!=2)return 0;
    int32_t count=wtop_ioreport.state_count(item);unsigned next=UINT_MAX,index=0;int format=-1;
    CFDataRef raw=CFDictionaryGetValue(item,CFSTR("RawElements"));
    if(count<=0||count>WTOP_MAX_GPU_STATES||count>CFDataGetLength(raw)/64)return 0;
    struct wtop_gpu_state states[WTOP_MAX_GPU_STATES];
    for(int32_t i=0;i<count;++i){
        char name[32];
        if(!cf_text(wtop_ioreport.state_name(item,i),name,sizeof(name)))return 0;
        states[i].idle=!strcmp(name,"IDLE")||!strcmp(name,"OFF")||!strcmp(name,"DOWN");
        if(!states[i].idle){
            int voltage=name[0]=='V';
            if(format>=0&&format!=voltage)return 0;
            format=voltage;
            if(voltage?!voltage_state(name,index,(unsigned)table->count)
                :!wtop_gpu_state_label(name,&next,&states[i].idle))return 0;
            ++index;
        }
        states[i].ticks=wtop_ioreport.residency(item,i);
    }
    return wtop_gpu_clock(states,(unsigned)count,table->hz,(unsigned)table->count,mean,active);
}
static void table_range(const dvfs_table *table,uint64_t *minimum,uint64_t *maximum){
    *minimum=*maximum=(uint64_t)table->hz[0];
    for(int i=1;i<table->count;++i){uint64_t hz=(uint64_t)table->hz[i];if(hz<*minimum)*minimum=hz;if(hz>*maximum)*maximum=hz;}
}
int wtop_collect_cpufreq(lua_State *L){
    int64_t performance_cpus=sysctl_int64("hw.perflevel0.logicalcpu",0);
    int64_t efficiency_cpus=sysctl_int64("hw.perflevel1.logicalcpu",0);
    int partial=0;
    if(performance_cpus<0||performance_cpus>512){performance_cpus=0;partial=1;}
    if(efficiency_cpus<0||efficiency_cpus>512){efficiency_cpus=0;partial=1;}
    struct wtop_report_sample sample={0};
    enum wtop_report_status status=wtop_ioreport_sample(WTOP_REPORT_CPU,&sample);
    if(status==WTOP_REPORT_FAILED){lua_pushnil(L);lua_pushliteral(L,"cpu_performance_states_unavailable");return 2;}
    if(cpu_epoch!=sample.epoch){cpu_epoch=sample.epoch;memset(&efficiency_table,0,sizeof(efficiency_table));memset(&performance_table,0,sizeof(performance_table));}
    if(!efficiency_table.count)(void)read_dvfs_table("voltage-states1-sram",&efficiency_table);
    if(!performance_table.count)(void)read_dvfs_table("voltage-states5-sram",&performance_table);
    if(!efficiency_table.count&&!performance_table.count){
        if(sample.owner)CFRelease(sample.owner);wtop_ioreport_reset(WTOP_REPORT_CPU);
        lua_pushnil(L);lua_pushliteral(L,"cpu_performance_states_unavailable");return 2;
    }
    char names[MAX_CLUSTERS][16]={{0}};double means[MAX_CLUSTERS]={0},active[MAX_CLUSTERS]={0};
    int valid[MAX_CLUSTERS]={0},duplicate[MAX_CLUSTERS]={0},count=0;
    for(CFIndex index=0;index<CFArrayGetCount(sample.items);++index){
        CFDictionaryRef item=CFArrayGetValueAtIndex(sample.items,index);char name[32];
        if(!cf_text(wtop_ioreport.name(item),name,sizeof(name)))continue;
        size_t length=strlen(name);
        if(length<4||(name[0]!='E'&&name[0]!='P')||strncmp(name+1,"CPU",3))continue;
        int digits=1;for(size_t i=4;i<length;++i)if(name[i]<'0'||name[i]>'9')digits=0;
        if(!digits)continue;
        if(length>=sizeof(names[0])){partial=1;continue;}
        int prior;for(prior=0;prior<count;++prior)if(!strcmp(names[prior],name))break;
        if(prior<count){duplicate[prior]=1;partial=1;continue;}
        if(count==MAX_CLUSTERS){partial=1;continue;}
        const dvfs_table *table=name[0]=='E'?&efficiency_table:&performance_table;
        if(!table->count){partial=1;continue;}
        memcpy(names[count],name,length+1);
        if(status==WTOP_REPORT_FRESH){
            valid[count]=residency_frequency(item,table,&means[count],&active[count]);
            if(!valid[count])partial=1;
        }
        ++count;
    }
    if(sample.owner)CFRelease(sample.owner);
    int efficiency_clusters=0,performance_clusters=0;
    for(int i=0;i<count;++i)if(!duplicate[i]){if(names[i][0]=='E')++efficiency_clusters;else ++performance_clusters;}
    int map=(!efficiency_cpus||efficiency_clusters)&&(!performance_cpus||performance_clusters);
    if(efficiency_clusters&&efficiency_cpus%efficiency_clusters)map=0;
    if(performance_clusters&&performance_cpus%performance_clusters)map=0;
    lua_createtable(L,0,4);lua_createtable(L,count,0);
    int next_cpu=0,output=1,any_running=0;
    for(int pass=0;pass<2;++pass)for(int i=0;i<count;++i){
        int efficiency=names[i][0]=='E';if(duplicate[i]||(pass==0)!=efficiency)continue;
        const dvfs_table *table=efficiency?&efficiency_table:&performance_table;
        int64_t cpus=map?(efficiency?efficiency_cpus/efficiency_clusters:performance_cpus/performance_clusters):0;
        uint64_t minimum,maximum;table_range(table,&minimum,&maximum);
        lua_createtable(L,0,10);string_field(L,"id",names[i]);string_field(L,"policy",names[i]);
        string_field(L,"identity_quality",map?"estimated":"partial");string_field(L,"driver","ioreport");
        string_field(L,"source","ioreport:CPU Complex Performance States");
        lua_createtable(L,(int)cpus,0);for(int64_t cpu=0;cpu<cpus;++cpu){lua_pushinteger(L,next_cpu++);lua_rawseti(L,-2,(lua_Integer)cpu+1);}
        lua_setfield(L,-2,"affected_cpus");lua_createtable(L,0,6);
        if(valid[i]&&means[i]>0){integer_field(L,"current_hz",(lua_Integer)means[i]);string_field(L,"current_quality","estimated");any_running=1;}
        else string_field(L,"current_quality",valid[i]?"unavailable":"gap");
        string_field(L,"current_source","ioreport_residency");
        integer_field(L,"hardware_minimum_hz",(lua_Integer)minimum);integer_field(L,"hardware_maximum_hz",(lua_Integer)maximum);
        lua_setfield(L,-2,"frequencies");
        if(valid[i])number_field(L,"active_residency_percent",active[i]*100);
        string_field(L,"quality",valid[i]?(means[i]>0?"estimated":"fresh"):"gap");lua_rawseti(L,-2,output++);
    }
    lua_setfield(L,-2,"policies");
    if(output==1){lua_pop(L,1);lua_pushnil(L);lua_pushliteral(L,"cpu_performance_states_unavailable");return 2;}
    boolean_field(L,"partial",partial||!map);
    boolean_field(L,"_sampling_pending",status==WTOP_REPORT_WARMUP);
    string_field(L,"quality",partial||!map?"partial":status==WTOP_REPORT_WARMUP?"gap":any_running?"estimated":"fresh");return 1;
}
