/* Read-only Windows CPU topology. New APIs are optional even in the XP build.
 * A logical identity is (processor group, group-relative processor number).
 * Physical relationships come from CPU Sets / GLPI records, not record order. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <errno.h>
#include "wtop_windows.h"

#define MAX_CPUS 512
#define MAX_GROUPS 64
#define MAX_RECORDS 4096
#define MAX_CACHES 1024
#define MAX_QUERY_BYTES (1024u * 1024u)
#define WORDS ((MAX_CPUS + 63) / 64)
_Static_assert(sizeof(void *)==4&&sizeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION)==24,
    "Windows CPU wire parser requires the x86 runtime");

/* Wire offsets below are the documented x86 layouts. Keeping them local avoids
 * raising the SDK/import floor for APIs resolved with GetProcAddress. */
typedef BOOL (WINAPI *query_old_fn)(void *, DWORD *);
typedef BOOL (WINAPI *query_ex_fn)(DWORD, void *, DWORD *);
typedef BOOL (WINAPI *query_sets_fn)(void *, ULONG, ULONG *, HANDLE, ULONG);
typedef WORD (WINAPI *group_count_fn)(void);
typedef DWORD (WINAPI *active_count_fn)(WORD);
typedef void (WINAPI *native_info_fn)(LPSYSTEM_INFO);
struct apis {
    query_old_fn old; query_ex_fn ex; query_sets_fn sets;
    group_count_fn groups; active_count_fn active; native_info_fn info;
};
struct cpu_row {
    DWORD set_id; unsigned group, index, core, llc, numa, efficiency, flags;
    int has_set, core_known, package_known, package, core_method;
    const char *source, *core_source, *package_source;
    uint64_t siblings[WORDS];
};
struct record {
    DWORD masks[MAX_GROUPS];
    DWORD size; unsigned kind, level, type, line, ways, flags, efficiency;
};
struct observation {
    struct cpu_row cpus[MAX_CPUS]; struct record *records;
    DWORD active[MAX_GROUPS], logical; WORD groups;
    unsigned cpu_count, record_count; int sets_valid, layout_valid, layout_source;
    int partial, truncated;
    const char *domain_source;
};
struct cache_row { struct record record; uint64_t members[WORDS]; uint64_t key; int mapped, ambiguous; };
struct capture {
    struct observation first, last;
    struct record records[2][MAX_RECORDS];
    struct cache_row caches[MAX_CACHES]; unsigned cache_count;
    WCHAR model[256], vendor[256], identifier[256];
    DWORD mhz, family, model_id, stepping; int has_identity_numbers;
    int partial, truncated, stable, cores, packages;
};
static void integer_field(lua_State *L, const char *key, lua_Integer value) { lua_pushinteger(L,value);lua_setfield(L,-2,key); }
static void string_field(lua_State *L, const char *key, const char *value) { lua_pushstring(L,value);lua_setfield(L,-2,key); }
static void boolean_field(lua_State *L, const char *key, int value) { lua_pushboolean(L,value);lua_setfield(L,-2,key); }
static uint16_t u16(const unsigned char *p) { uint16_t value;memcpy(&value,p,2);return value; }
static uint32_t u32(const unsigned char *p) { uint32_t value;memcpy(&value,p,4);return value; }
static unsigned flat_id(const struct cpu_row *row) { return row->group*64+row->index; }
static const char *layout_name(int source) { return source==2?"GetLogicalProcessorInformationEx":"GetLogicalProcessorInformation"; }
static unsigned popcount32(DWORD mask) { unsigned n=0;for(;mask;mask&=mask-1)++n;return n; }
static int row_compare(const void *a,const void *b) {
    unsigned x=flat_id(a),y=flat_id(b);return (x>y)-(x<y);
}
static int record_compare(const void *a,const void *b) {
    const struct record *x=a,*y=b;
    const unsigned first[]={x->kind,x->level,x->type,x->size,x->line,x->ways,x->flags,x->efficiency};
    const unsigned last[]={y->kind,y->level,y->type,y->size,y->line,y->ways,y->flags,y->efficiency};
    for(unsigned i=0;i<sizeof(first)/sizeof(first[0]);++i)if(first[i]!=last[i])return first[i]>last[i]?1:-1;
    for(unsigned i=0;i<MAX_GROUPS;++i)if(x->masks[i]!=y->masks[i])return x->masks[i]>y->masks[i]?1:-1;
    return 0;
}
static void resolve(struct apis *api) {
    HMODULE kernel=GetModuleHandleA("kernel32.dll");memset(api,0,sizeof(*api));if(!kernel)return;
    api->old=(query_old_fn)(void *)GetProcAddress(kernel,"GetLogicalProcessorInformation");
    api->ex=(query_ex_fn)(void *)GetProcAddress(kernel,"GetLogicalProcessorInformationEx");
    api->sets=(query_sets_fn)(void *)GetProcAddress(kernel,"GetSystemCpuSetInformation");
    api->groups=(group_count_fn)(void *)GetProcAddress(kernel,"GetActiveProcessorGroupCount");
    api->active=(active_count_fn)(void *)GetProcAddress(kernel,"GetActiveProcessorCount");
    api->info=(native_info_fn)(void *)GetProcAddress(kernel,"GetNativeSystemInfo");
}
static BOOL query(const struct apis *api,int kind,void *buffer,DWORD capacity,DWORD *bytes) {
    *bytes=capacity;
    if(kind==0)return api->old(buffer,bytes);
    if(kind==1)return api->ex(0xffff,buffer,bytes);
    return api->sets(buffer,capacity,bytes,NULL,0);
}
static unsigned char *read_buffer(const struct apis *api,int kind,DWORD *length,int *truncated) {
    DWORD needed=0;
    if(query(api,kind,NULL,0,&needed)||GetLastError()!=ERROR_INSUFFICIENT_BUFFER||!needed)return NULL;
    for(unsigned attempt=0;attempt<3;++attempt) {
        if(needed>MAX_QUERY_BYTES){*truncated=1;return NULL;}
        unsigned char *buffer=malloc(needed);if(!buffer)return NULL;
        DWORD capacity=needed,returned=0;
        BOOL valid=query(api,kind,buffer,capacity,&returned);DWORD error=GetLastError();
        if(valid&&returned>0&&returned<=capacity){*length=returned;return buffer;}
        free(buffer);
        if(valid||error!=ERROR_INSUFFICIENT_BUFFER||returned<=capacity)return NULL;
        needed=returned;
    }
    return NULL;
}
static void read_domain(const struct apis *api,struct observation *out) {
    SYSTEM_INFO info;memset(&info,0,sizeof(info));
    out->domain_source=api->info?"GetNativeSystemInfo":"GetSystemInfo";
    if(api->info)api->info(&info);else GetSystemInfo(&info);
    out->groups=api->groups?api->groups():1;
    if(!out->groups||out->groups>MAX_GROUPS){out->partial=out->truncated=1;out->groups=0;if(api->active){out->logical=api->active(0xffff);out->domain_source="GetActiveProcessorCount";}return;}
    for(unsigned g=0;g<out->groups;++g) {
        DWORD n=api->active?api->active((WORD)g):info.dwNumberOfProcessors;
        if(!n||n>64||(!api->active&&out->groups!=1)){out->partial=1;out->groups=0;out->logical=0;return;}
        out->active[g]=n;out->logical+=n;
    }
    if(out->logical>MAX_CPUS)out->partial=out->truncated=1;
}
static int read_sets(const struct apis *api,struct observation *out) {
    DWORD bytes=0;unsigned char *buffer=read_buffer(api,2,&bytes,&out->truncated);if(!buffer)return 0;
    int valid=1;unsigned seen=0;
    for(DWORD offset=0;offset<bytes;) {
        if(bytes-offset<8){valid=0;break;}
        const unsigned char *p=buffer+offset;DWORD size=u32(p),type=u32(p+4);
        if(size<8||size>bytes-offset||++seen>MAX_RECORDS){valid=0;break;}
        if(type==0) {
            if(size<32){valid=0;break;}
            unsigned group=u16(p+12),index=p[14];
            if(group>=out->groups||index>=64||out->cpu_count==MAX_CPUS){valid=0;if(out->cpu_count==MAX_CPUS)out->truncated=1;break;}
            struct cpu_row *row=&out->cpus[out->cpu_count++];
            row->has_set=1;row->set_id=u32(p+8);row->group=group;row->index=index;
            row->core=p[15];row->llc=p[16];row->numa=p[17];row->efficiency=p[18];row->flags=p[19];
            row->source=row->core_source="GetSystemCpuSetInformation";row->core_known=1;row->core_method=1;
        }
        offset+=size;
    }
    free(buffer);
    qsort(out->cpus,out->cpu_count,sizeof(out->cpus[0]),row_compare);
    DWORD per_group[MAX_GROUPS]={0};
    for(unsigned i=0;valid&&i<out->cpu_count;++i) {
        const struct cpu_row *row=&out->cpus[i];++per_group[row->group];
        if(i&&flat_id(row)==flat_id(&out->cpus[i-1]))valid=0;
        for(unsigned j=0;j<i;++j) {
            const struct cpu_row *other=&out->cpus[j];
            if(row->set_id==other->set_id)valid=0;
            if(row->group==other->group&&row->core==other->core
                &&(row->efficiency!=other->efficiency||row->numa!=other->numa||row->llc!=other->llc))valid=0;
        }
    }
    if(out->cpu_count!=out->logical)valid=0;
    for(unsigned g=0;g<out->groups;++g)if(per_group[g]!=out->active[g])valid=0;
    if(!valid){out->cpu_count=0;memset(out->cpus,0,sizeof(out->cpus));}
    return valid&&out->cpu_count>0;
}
static int add_record(struct observation *out,const struct record *record) {
    if(out->record_count==MAX_RECORDS){out->truncated=1;return 0;}
    out->records[out->record_count++]=*record;return 1;
}
static int read_masks(const unsigned char *p,DWORD size,unsigned offset,unsigned count,struct observation *out,struct record *record) {
    if(!count||count>MAX_GROUPS||offset>size||count>(size-offset)/12)return 0;
    for(unsigned i=0;i<count;++i) {
        unsigned group=u16(p+offset+i*12+4);DWORD mask=u32(p+offset+i*12);
        if(group>=out->groups||!mask||record->masks[group])return 0;
        record->masks[group]=mask;
    }
    return 1;
}
static int parse_ex(const unsigned char *buffer,DWORD bytes,struct observation *out) {
    unsigned seen=0;
    for(DWORD offset=0;offset<bytes;) {
        if(bytes-offset<8)return 0;
        const unsigned char *p=buffer+offset;DWORD kind=u32(p),size=u32(p+4);
        if(size<8||size>bytes-offset||++seen>MAX_RECORDS)return 0;
        struct record record;memset(&record,0,sizeof(record));record.kind=kind;
        if(kind==0||kind==3) {
            if(size<32||!read_masks(p,size,32,u16(p+30),out,&record))return 0;
            record.flags=p[8];record.efficiency=p[9];
            if(!add_record(out,&record))return 0;
        } else if(kind==2) {
            /* Pre-21H2 cache records have a reserved zero at GroupCount and
             * exactly one GroupMask at the same wire offset. */
            if(size<40)return 0;
            unsigned groups=u16(p+38);if(!groups)groups=1;
            if(!read_masks(p,size,40,groups,out,&record))return 0;
            record.level=p[8];record.ways=p[9];record.line=u16(p+10);record.size=u32(p+12);record.type=u32(p+16);
            if(!record.level||record.level>8||record.type>3||!record.size)return 0;
            if(!add_record(out,&record))return 0;
        }
        offset+=size;
    }
    return out->record_count>0;
}
static int parse_old(const unsigned char *buffer,DWORD bytes,struct observation *out) {
    if(out->groups!=1||bytes%sizeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION))return 0;
    for(DWORD offset=0;offset<bytes;offset+=sizeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION)) {
        SYSTEM_LOGICAL_PROCESSOR_INFORMATION entry;memcpy(&entry,buffer+offset,sizeof(entry));
        if(entry.Relationship!=RelationProcessorCore&&entry.Relationship!=RelationProcessorPackage&&entry.Relationship!=RelationCache)continue;
        struct record record;memset(&record,0,sizeof(record));record.kind=entry.Relationship;record.masks[0]=(DWORD)entry.ProcessorMask;
        if(!record.masks[0])return 0;
        if(record.kind==0)record.flags=entry.ProcessorCore.Flags;
        if(record.kind==2) {
            record.level=entry.Cache.Level;record.ways=entry.Cache.Associativity;record.line=entry.Cache.LineSize;record.size=entry.Cache.Size;record.type=entry.Cache.Type;
            if(!record.level||record.level>8||record.type>3||!record.size)return 0;
        }
        if(!add_record(out,&record))return 0;
    }
    return out->record_count>0;
}
static int read_layout(const struct apis *api,struct observation *out) {
    DWORD bytes=0;unsigned char *buffer=NULL;int valid=0;
    if(api->ex) {
        buffer=read_buffer(api,1,&bytes,&out->truncated);
        if(buffer){valid=parse_ex(buffer,bytes,out);free(buffer);out->layout_source=2;return valid;}
        out->partial=1;
    }
    if(api->old&&out->groups==1) {
        buffer=read_buffer(api,0,&bytes,&out->truncated);
        if(buffer){valid=parse_old(buffer,bytes,out);free(buffer);out->layout_source=1;return valid;}
    }
    return 0;
}
static int mask_safe(const struct observation *out,unsigned group);
static void observe(const struct apis *api,struct observation *out) {
    read_domain(api,out);if(!out->groups)return;
    if(api->sets){out->sets_valid=read_sets(api,out);if(!out->sets_valid)out->partial=1;}
    out->layout_valid=read_layout(api,out);
    if(!out->layout_valid){out->record_count=0;out->partial=1;}
    qsort(out->records,out->record_count,sizeof(out->records[0]),record_compare);
    for(unsigned i=1;i<out->record_count;++i)if(record_compare(&out->records[i-1],&out->records[i])==0) {
        int safe=1;
        for(unsigned g=0;g<out->groups;++g)if(out->records[i].masks[g]&&!mask_safe(out,g))safe=0;
        /* WOW64 can fold two distinct 64-bit affinities into the same DWORD.
         * Keep API record counts, but never use those masks as relationships. */
        if(safe){out->layout_valid=0;out->record_count=0;out->partial=1;break;}
    }
}
static int same_observation(const struct observation *a,const struct observation *b) {
    if(!a->groups||a->groups!=b->groups||a->logical!=b->logical||a->sets_valid!=b->sets_valid
        ||a->layout_valid!=b->layout_valid||a->layout_source!=b->layout_source||a->cpu_count!=b->cpu_count
        ||a->record_count!=b->record_count||a->truncated||b->truncated)return 0;
    for(unsigned g=0;g<a->groups;++g)if(a->active[g]!=b->active[g])return 0;
    for(unsigned i=0;i<a->cpu_count;++i) {
        const struct cpu_row *x=&a->cpus[i],*y=&b->cpus[i];
        if(x->set_id!=y->set_id||x->group!=y->group||x->index!=y->index||x->core!=y->core
            ||x->llc!=y->llc||x->numa!=y->numa||x->efficiency!=y->efficiency)return 0;
    }
    for(unsigned i=0;i<a->record_count;++i)if(record_compare(&a->records[i],&b->records[i]))return 0;
    return a->sets_valid||a->layout_valid;
}
static int mask_safe(const struct observation *out,unsigned group) {
    if(group>=out->groups||out->active[group]>32)return 0;
    if(out->sets_valid)for(unsigned i=0;i<out->cpu_count;++i)if(out->cpus[i].group==group&&out->cpus[i].index>=32)return 0;
    return 1;
}
static int contains(const struct record *record,const struct cpu_row *row) {
    return row->index<32&&(record->masks[row->group]&(1u<<row->index))!=0;
}
static int seed_from_masks(struct observation *out) {
    DWORD masks[MAX_GROUPS]={0};
    for(unsigned i=0;i<out->record_count;++i)if(out->records[i].kind==0)
        for(unsigned g=0;g<out->groups;++g)masks[g]|=out->records[i].masks[g];
    for(unsigned g=0;g<out->groups;++g)if(!mask_safe(out,g)||popcount32(masks[g])!=out->active[g])return 0;
    for(unsigned g=0;g<out->groups;++g)for(unsigned n=0;n<32;++n)if(masks[g]&(1u<<n)) {
        if(out->cpu_count==MAX_CPUS){out->cpu_count=0;out->truncated=1;return 0;}
        struct cpu_row *row=&out->cpus[out->cpu_count++];row->group=g;row->index=n;row->source=layout_name(out->layout_source);
    }
    return out->cpu_count>0;
}
static int members(const struct observation *out,const struct record *record,uint64_t *bits) {
    memset(bits,0,sizeof(uint64_t)*WORDS);unsigned expected=0,found=0;
    for(unsigned g=0;g<out->groups;++g)if(record->masks[g]) {
        if(!mask_safe(out,g))return 0;
        expected+=popcount32(record->masks[g]);
    }
    for(unsigned i=0;i<out->cpu_count;++i)if(contains(record,&out->cpus[i])){bits[i/64]|=UINT64_C(1)<<(i%64);++found;}
    return found>0&&found==expected;
}
static unsigned first_member(const struct observation *out,const uint64_t *bits) {
    for(unsigned i=0;i<out->cpu_count;++i)if(bits[i/64]&(UINT64_C(1)<<(i%64)))return flat_id(&out->cpus[i]);
    return 0;
}
static void relate(struct capture *capture) {
    struct observation *out=&capture->last;
    if(!capture->stable)return;
    if(!out->sets_valid&&(!out->layout_valid||!seed_from_masks(out))){capture->partial=1;return;}
    for(unsigned i=0;i<out->cpu_count;++i) {
        struct cpu_row *row=&out->cpus[i];unsigned cores=0,packages=0;uint64_t core_members[WORDS]={0};unsigned core_id=0,package_id=0;
        for(unsigned r=0;r<out->record_count;++r)if(out->records[r].kind==0||out->records[r].kind==3) {
            uint64_t bits[WORDS];const struct record *record=&out->records[r];
            if(!members(out,record,bits)||!(bits[i/64]&(UINT64_C(1)<<(i%64))))continue;
            if(record->kind==0){++cores;core_id=first_member(out,bits);memcpy(core_members,bits,sizeof(bits));}
            else{++packages;package_id=first_member(out,bits);}
        }
        if(row->has_set) {
            for(unsigned j=0;j<out->cpu_count;++j)if(out->cpus[j].group==row->group&&out->cpus[j].core==row->core)
                row->siblings[j/64]|=UINT64_C(1)<<(j%64);
            if(cores>1||(cores==1&&memcmp(core_members,row->siblings,sizeof(core_members)))){row->core_known=0;capture->partial=1;}
        } else if(cores==1) {
            row->core_known=1;row->core=core_id;row->core_method=2;row->core_source=layout_name(out->layout_source);
            memcpy(row->siblings,core_members,sizeof(core_members));
        }
        if(packages==1){row->package_known=1;row->package=(int)package_id;row->package_source=layout_name(out->layout_source);}
        if(!row->core_known||!row->package_known)capture->partial=1;
        if(cores>1||packages>1)capture->partial=1;
    }
    unsigned char inconsistent[MAX_CPUS]={0};
    for(unsigned i=0;i<out->cpu_count;++i)if(out->cpus[i].core_known&&out->cpus[i].package_known) {
        int split=0;
        for(unsigned j=0;j<out->cpu_count;++j)if((out->cpus[i].siblings[j/64]&(UINT64_C(1)<<(j%64)))
            &&out->cpus[j].package_known&&out->cpus[j].package!=out->cpus[i].package)split=1;
        if(split)for(unsigned j=0;j<out->cpu_count;++j)if(out->cpus[i].siblings[j/64]&(UINT64_C(1)<<(j%64)))inconsistent[j]=1;
    }
    for(unsigned i=0;i<out->cpu_count;++i)if(inconsistent[i]) {
        out->cpus[i].package_known=0;
        /* CPU Sets independently prove these siblings. A legacy mask alone
         * cannot resolve which contradictory physical relationship is valid. */
        if(!out->cpus[i].has_set)out->cpus[i].core_known=0;
        capture->partial=1;
    }
}
static uint64_t cache_key(const struct observation *out,const struct record *record,const uint64_t *memberships) {
    uint64_t hash=UINT64_C(14695981039346656037);
    unsigned fields[]={record->level,record->type};
    for(unsigned n=0;n<2;++n){hash^=fields[n];hash*=UINT64_C(1099511628211);}
    for(unsigned i=0;i<out->cpu_count;++i)if(memberships[i/64]&(UINT64_C(1)<<(i%64))) {
        unsigned id=flat_id(&out->cpus[i]);for(unsigned b=0;b<4;++b){hash^=(id>>(b*8))&255;hash*=UINT64_C(1099511628211);}
    }
    return hash;
}
static void collect_caches(struct capture *capture) {
    struct observation *out=&capture->last;if(!out->layout_valid)return;
    for(unsigned i=0;i<out->record_count;++i) {
        const struct record *record=&out->records[i];
        if(record->kind==0)++capture->cores;
        if(record->kind==3)++capture->packages;
        if(record->kind!=2)continue;
        if(capture->cache_count==MAX_CACHES){capture->partial=capture->truncated=1;continue;}
        struct cache_row *cache=&capture->caches[capture->cache_count++];cache->record=*record;
        if(capture->stable&&out->cpu_count&&members(out,record,cache->members)) {
            cache->mapped=1;cache->key=cache_key(out,record,cache->members);
            for(unsigned j=0;j+1<capture->cache_count;++j)if(capture->caches[j].mapped&&capture->caches[j].key==cache->key) {
                cache->ambiguous=capture->caches[j].ambiguous=1;capture->partial=1;
            }
        }
    }
}
static void reconcile_counts(struct capture *capture) {
    const struct observation *out=&capture->last;
    if(!capture->stable||!out->sets_valid)return;
    unsigned cores=0;
    for(unsigned i=0;i<out->cpu_count;++i) {
        int first=1;
        for(unsigned j=0;j<i;++j)if(out->cpus[i].group==out->cpus[j].group&&out->cpus[i].core==out->cpus[j].core)first=0;
        if(first)++cores;
    }
    if(capture->cores&&(unsigned)capture->cores!=cores){capture->cores=0;capture->partial=1;}
    else capture->cores=(int)cores;
}
static int registry_text(HKEY key,const WCHAR *name,WCHAR *out,DWORD characters) {
    DWORD type=0,bytes=characters*sizeof(WCHAR);memset(out,0,bytes);
    if(RegQueryValueExW(key,name,NULL,&type,(BYTE *)out,&bytes)!=ERROR_SUCCESS||type!=REG_SZ
        ||bytes<sizeof(WCHAR)||bytes>characters*sizeof(WCHAR)||bytes%sizeof(WCHAR)) {out[0]=0;return 0;}
    DWORD units=bytes/sizeof(WCHAR);
    /* RegQueryValueEx does not guarantee a terminator for REG_SZ. Accept a
     * bounded missing terminator and zero padding used by older providers. */
    if(units<characters)out[units]=0;
    else if(out[units-1]){out[0]=0;return 0;}
    size_t length=wcslen(out);
    for(size_t i=length+1;i<units;++i)if(out[i]){out[0]=0;return 0;}
    WCHAR *start=out;while(*start==L' ')++start;
    if(start!=out)memmove(out,start,(wcslen(start)+1)*sizeof(WCHAR));
    for(size_t n=wcslen(out);n&&out[n-1]==L' ';--n)out[n-1]=0;
    return out[0]!=0;
}
static int identity_number(const WCHAR **text,DWORD *out) {
    if(**text<L'0'||**text>L'9')return 0;
    WCHAR *end;errno=0;unsigned long value=wcstoul(*text,&end,10);
    if(end==*text||errno==ERANGE||**text==L'-')return 0;
    *out=(DWORD)value;*text=end;return 1;
}
static void read_identity(struct capture *capture) {
    HKEY key;
    if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",0,KEY_QUERY_VALUE,&key)!=ERROR_SUCCESS)return;
    registry_text(key,L"ProcessorNameString",capture->model,256);registry_text(key,L"VendorIdentifier",capture->vendor,256);
    registry_text(key,L"Identifier",capture->identifier,256);
    DWORD type=0,bytes=sizeof(capture->mhz);
    if(RegQueryValueExW(key,L"~MHz",NULL,&type,(BYTE *)&capture->mhz,&bytes)!=ERROR_SUCCESS
        ||type!=REG_DWORD||bytes!=sizeof(capture->mhz))capture->mhz=0;
    RegCloseKey(key);
    const WCHAR *p=wcsstr(capture->identifier,L"Family ");
    if(p){p+=7;if(identity_number(&p,&capture->family)&&!wcsncmp(p,L" Model ",7)) {
        p+=7;if(identity_number(&p,&capture->model_id)&&!wcsncmp(p,L" Stepping ",10)) {
            p+=10;capture->has_identity_numbers=identity_number(&p,&capture->stepping)&&!*p;
        }
    }}
}
static const char *cache_type(unsigned type) { const char *names[]={"Unified","Instruction","Data","Trace"};return names[type]; }
static void push_members(lua_State *L,const struct observation *out,const uint64_t *bits) {
    lua_newtable(L);unsigned n=1;
    for(unsigned i=0;i<out->cpu_count;++i)if(bits[i/64]&(UINT64_C(1)<<(i%64))){lua_pushinteger(L,flat_id(&out->cpus[i]));lua_rawseti(L,-2,n++);}
}
static void push_topology(lua_State *L,const struct capture *capture) {
    const struct observation *out=&capture->last;unsigned count=capture->stable?out->cpu_count:0;
    lua_createtable(L,0,12);
    if(out->logical){integer_field(L,"threads",out->logical);integer_field(L,"online_threads",out->logical);}
    if(capture->cores)integer_field(L,"physical_cores",capture->cores);
    if(capture->packages)integer_field(L,"sockets",capture->packages);
    if(out->groups)integer_field(L,"processor_groups",out->groups);
    string_field(L,"source",out->sets_valid?"GetSystemCpuSetInformation":out->layout_source?layout_name(out->layout_source):out->domain_source);
    string_field(L,"quality",capture->partial?"partial":"fresh");string_field(L,"identity_quality",count?"fresh":"partial");boolean_field(L,"truncated",capture->truncated);
    lua_createtable(L,(int)count,0);
    for(unsigned i=0;i<count;++i) {
        const struct cpu_row *row=&out->cpus[i];char key[64];
        lua_createtable(L,0,24);integer_field(L,"id",flat_id(row));integer_field(L,"processor_group",row->group);integer_field(L,"logical_processor_index",row->index);
        boolean_field(L,"online",1);boolean_field(L,"online_known",1);boolean_field(L,"core_id_known",row->core_known);boolean_field(L,"package_id_known",row->package_known);
        string_field(L,"source",row->source);string_field(L,"identity_quality","fresh");
        if(row->has_set){integer_field(L,"cpu_set_id",row->set_id);integer_field(L,"efficiency_class",row->efficiency);integer_field(L,"last_level_cache_index",row->llc);integer_field(L,"numa_node_index",row->numa);boolean_field(L,"parked",row->flags&1);boolean_field(L,"allocated",row->flags&2);snprintf(key,sizeof(key),"efficiency-%u",row->efficiency);string_field(L,"core_type_id",key);}
        if(row->core_known){integer_field(L,"core_id",row->core);snprintf(key,sizeof(key),"win:g%u:c%u",row->group,row->core);string_field(L,"core_key",key);string_field(L,"core_source",row->core_source);string_field(L,"core_id_scope",row->core_method==1?"processor_group":"system");string_field(L,"core_id_method",row->core_method==1?"cpu_set_core_index":"lowest_logical_cpu");unsigned threads=0;for(unsigned j=0;j<out->cpu_count;++j)if(row->siblings[j/64]&(UINT64_C(1)<<(j%64)))++threads;integer_field(L,"threads_in_core",threads);push_members(L,out,row->siblings);lua_setfield(L,-2,"thread_siblings");}
        if(row->package_known){integer_field(L,"package_id",row->package);string_field(L,"package_source",row->package_source);string_field(L,"package_id_method","lowest_logical_cpu");}
        lua_rawseti(L,-2,i+1);
    }
    lua_setfield(L,-2,"logical_cpus");
    const char *lists[]={"present_cpu_list","online_cpu_list"};
    for(unsigned list=0;list<2;++list){lua_createtable(L,(int)count,0);for(unsigned i=0;i<count;++i){lua_pushinteger(L,flat_id(&out->cpus[i]));lua_rawseti(L,-2,i+1);}lua_setfield(L,-2,lists[list]);}
}
static void push_caches(lua_State *L,const struct capture *capture) {
    const struct observation *out=&capture->last;unsigned output=1;lua_newtable(L);
    for(unsigned i=0;i<capture->cache_count;++i) {
        const struct cache_row *cache=&capture->caches[i];const struct record *record=&cache->record;
        if(!cache->mapped||cache->ambiguous)continue;
        char id[64];snprintf(id,sizeof(id),"win:L%u:%s:%016llx",record->level,cache_type(record->type),(unsigned long long)cache->key);
        lua_createtable(L,0,8);string_field(L,"id",id);integer_field(L,"level",record->level);string_field(L,"type",cache_type(record->type));integer_field(L,"size_bytes",record->size);
        if(record->line)integer_field(L,"coherency_line_size_bytes",record->line);
        if(record->ways&&record->ways!=255)integer_field(L,"ways_of_associativity",record->ways);
        string_field(L,"source",layout_name(out->layout_source));push_members(L,out,cache->members);lua_setfield(L,-2,"shared_cpu_list");lua_rawseti(L,-2,output++);
    }
    lua_setfield(L,-2,"caches");lua_newtable(L);output=1;
    for(unsigned level=1;level<=8;++level)for(unsigned type=0;type<4;++type) {
        uint64_t total=0;unsigned instances=0;DWORD minimum=0,maximum=0;
        for(unsigned i=0;i<capture->cache_count;++i){const struct record *record=&capture->caches[i].record;
            if(record->level==level&&record->type==type){total+=record->size;++instances;if(!minimum||record->size<minimum)minimum=record->size;if(record->size>maximum)maximum=record->size;}}
        if(!instances)continue;
        char id[32];snprintf(id,sizeof(id),"L%u:%s",level,cache_type(type));lua_createtable(L,0,7);string_field(L,"id",id);integer_field(L,"level",level);string_field(L,"type",cache_type(type));integer_field(L,"instances",instances);integer_field(L,"total_size_bytes",(lua_Integer)total);integer_field(L,"minimum_size_bytes",minimum);integer_field(L,"maximum_size_bytes",maximum);lua_rawseti(L,-2,output++);
    }
    lua_setfield(L,-2,"cache_summary");
}
static void push_core_types(lua_State *L,const struct capture *capture) {
    const struct observation *out=&capture->last;unsigned output=1;lua_newtable(L);
    if(capture->stable&&out->sets_valid)for(unsigned efficiency=0;efficiency<256;++efficiency) {
        unsigned logical=0,physical=0;int verified=1;uint64_t bits[WORDS]={0};
        for(unsigned i=0;i<out->cpu_count;++i)if(out->cpus[i].efficiency==efficiency) {
            if(!out->cpus[i].core_known)verified=0;
            ++logical;bits[i/64]|=UINT64_C(1)<<(i%64);int first=1;
            for(unsigned j=0;j<i;++j)if(out->cpus[j].group==out->cpus[i].group&&out->cpus[j].core==out->cpus[i].core)first=0;
            if(first)++physical;
        }
        if(!logical)continue;
        char id[32];snprintf(id,sizeof(id),"efficiency-%u",efficiency);lua_createtable(L,0,6);string_field(L,"id",id);string_field(L,"source","GetSystemCpuSetInformation");integer_field(L,"efficiency_class",efficiency);integer_field(L,"logical_cpu_count",logical);if(verified)integer_field(L,"physical_core_count",physical);push_members(L,out,bits);lua_setfield(L,-2,"logical_cpu_ids");lua_rawseti(L,-2,output++);
    }
    lua_setfield(L,-2,"core_types");
}
int wtop_collect_cpu_info(lua_State *L) {
    /* No Lua allocations while a registry handle or a malloc query buffer is
     * live. Scratch data is owned by Lua before the first native acquisition. */
    struct capture *capture=lua_newuserdatauv(L,sizeof(*capture),0);memset(capture,0,sizeof(*capture));
    capture->first.records=capture->records[0];capture->last.records=capture->records[1];
    struct apis api;resolve(&api);observe(&api,&capture->first);read_identity(capture);observe(&api,&capture->last);
    capture->stable=same_observation(&capture->first,&capture->last);
    capture->partial=capture->first.partial||capture->last.partial||!capture->stable;
    capture->truncated=capture->first.truncated||capture->last.truncated;
    relate(capture);collect_caches(capture);reconcile_counts(capture);
    if(!capture->last.logical){
        capture->partial=1;
        if(!capture->model[0]&&!capture->vendor[0]){lua_pushnil(L);lua_pushliteral(L,"logical CPU count unavailable");return 2;}
    }
    lua_createtable(L,0,8);string_field(L,"quality",capture->partial?"partial":"fresh");boolean_field(L,"truncated",capture->truncated);
    lua_createtable(L,0,8);
    if(capture->model[0]){wtop_push_utf8(L,capture->model);lua_setfield(L,-2,"model_name");}
    if(capture->vendor[0]){wtop_push_utf8(L,capture->vendor);lua_setfield(L,-2,"vendor");}
    if(capture->mhz)integer_field(L,"nominal_frequency_hz",(lua_Integer)capture->mhz*1000000);
    if(capture->has_identity_numbers){integer_field(L,"family",capture->family);integer_field(L,"model",capture->model_id);integer_field(L,"stepping",capture->stepping);}
    unsigned classes=0;int seen[256]={0};
    if(capture->stable&&capture->last.sets_valid)for(unsigned i=0;i<capture->last.cpu_count;++i)if(!seen[capture->last.cpus[i].efficiency]){seen[capture->last.cpus[i].efficiency]=1;++classes;}
    if(classes)integer_field(L,"core_type_count",classes);
    if(classes>1)boolean_field(L,"heterogeneous",1);
    lua_setfield(L,-2,"identity");push_topology(L,capture);lua_setfield(L,-2,"topology");push_caches(L,capture);push_core_types(L,capture);return 1;
}

/* NT class 8 is the same 100 ns time record used by the XP fallback. The Ex
 * form takes a USHORT processor group, allowing a 32-bit process to read every
 * group without changing thread affinity or folding processor numbers. */
typedef struct {
    LARGE_INTEGER idle, kernel, user, dpc, interrupt;
    ULONG interrupt_count;
} processor_times;
typedef LONG (WINAPI *times_fn)(ULONG,void *,ULONG,ULONG *);
typedef LONG (WINAPI *times_ex_fn)(ULONG,void *,ULONG,void *,ULONG,ULONG *);
typedef BOOL (WINAPI *system_times_fn)(LPFILETIME,LPFILETIME,LPFILETIME);
struct time_row { uint64_t busy,total,user,system,irq;int valid,classes,source; };
struct usage_capture {
    struct observation first,last;
    struct time_row rows[MAX_CPUS],total;
    struct time_row group_totals[MAX_GROUPS];
    int group_sources[MAX_GROUPS];
    unsigned count;int partial,truncated,stable,aggregate_source;
    processor_times buffer[64];
};
struct usage_identity {
    DWORD logical,active[MAX_GROUPS],set_ids[MAX_CPUS];unsigned ids[MAX_CPUS];
    unsigned count;WORD groups;int sets_valid,stable,aggregate_source;
};
static struct usage_identity previous_usage;
static uint64_t usage_epoch;
_Static_assert(sizeof(processor_times)==48,"NT processor performance x86 stride");
static void observe_roster(const struct apis *api,struct observation *out) {
    read_domain(api,out);if(!out->groups||out->logical>MAX_CPUS)return;
    if(api->sets){out->sets_valid=read_sets(api,out);if(!out->sets_valid)out->partial=1;}
    if(!out->sets_valid)for(unsigned g=0;g<out->groups;++g)for(unsigned n=0;n<out->active[g];++n) {
        struct cpu_row *row=&out->cpus[out->cpu_count++];row->group=g;row->index=n;
    }
}
static uint64_t file_ticks(FILETIME value) { return ((uint64_t)value.dwHighDateTime<<32)|value.dwLowDateTime; }
static int convert_times(const processor_times *input,struct time_row *out) {
    if(input->idle.QuadPart<0||input->kernel.QuadPart<0||input->user.QuadPart<0
        ||input->kernel.QuadPart<input->idle.QuadPart)return 0;
    uint64_t idle=(uint64_t)input->idle.QuadPart,kernel=(uint64_t)input->kernel.QuadPart,user=(uint64_t)input->user.QuadPart;
    if(kernel>(uint64_t)INT64_MAX-user)return 0;
    out->total=kernel+user;out->busy=kernel-idle+user;out->user=user;out->valid=1;
    if(input->dpc.QuadPart>=0&&input->interrupt.QuadPart>=0) {
        uint64_t dpc=(uint64_t)input->dpc.QuadPart,irq=(uint64_t)input->interrupt.QuadPart;
        if(dpc<=(uint64_t)INT64_MAX-irq&&dpc+irq<=kernel-idle) {
            out->irq=dpc+irq;out->system=kernel-idle-out->irq;out->classes=1;
        }
    }
    return 1;
}
static int read_times(times_fn old,times_ex_fn ex,WORD group,unsigned count,int single,
    processor_times *buffer,int *source) {
    ULONG capacity=(ULONG)(count*sizeof(*buffer)),returned=0;
    memset(buffer,0,64*sizeof(*buffer));
    if(ex&&ex(8,&group,sizeof(group),buffer,capacity,&returned)>=0&&returned==capacity){*source=1;return 1;}
    returned=0;
    /* The old query has no group selector. It is only unambiguous on a
     * verified single-group domain, including XP before GetSystemTimes. */
    if(single&&group==0&&old&&old(8,buffer,capacity,&returned)>=0&&returned==capacity){*source=2;return 1;}
    return 0;
}
static int add_times(struct time_row *sum,const struct time_row *row) {
    if(sum->total>(uint64_t)INT64_MAX-row->total||sum->busy>(uint64_t)INT64_MAX-row->busy
        ||sum->user>(uint64_t)INT64_MAX-row->user)return 0;
    sum->total+=row->total;sum->busy+=row->busy;sum->user+=row->user;sum->valid=1;return 1;
}
static void push_times(lua_State *L,const struct time_row *row,int classes) {
    lua_createtable(L,0,5);if(!row->valid)return;
    integer_field(L,"busy",(lua_Integer)row->busy);integer_field(L,"total",(lua_Integer)row->total);integer_field(L,"user",(lua_Integer)row->user);
    if(classes&&row->classes){integer_field(L,"system",(lua_Integer)row->system);integer_field(L,"irq",(lua_Integer)row->irq);}
}
static uint64_t update_usage_epoch(const struct usage_capture *capture) {
    struct usage_identity current;memset(&current,0,sizeof(current));const struct observation *out=&capture->last;
    current.logical=out->logical;current.groups=out->groups;current.count=out->cpu_count;
    current.sets_valid=out->sets_valid;current.stable=capture->stable;current.aggregate_source=capture->aggregate_source;
    memcpy(current.active,out->active,sizeof(current.active));
    for(unsigned i=0;i<out->cpu_count;++i){current.ids[i]=flat_id(&out->cpus[i]);current.set_ids[i]=out->cpus[i].set_id;}
    if(!usage_epoch||memcmp(&current,&previous_usage,sizeof(current))){if(usage_epoch<UINT64_MAX)++usage_epoch;previous_usage=current;}
    return usage_epoch;
}
int wtop_collect_cpu(lua_State *L) {
    struct usage_capture *capture=lua_newuserdatauv(L,sizeof(*capture),0);memset(capture,0,sizeof(*capture));
    struct apis api;resolve(&api);observe_roster(&api,&capture->first);
    HMODULE nt=GetModuleHandleA("ntdll.dll"),kernel=GetModuleHandleA("kernel32.dll");
    times_fn old=nt?(times_fn)(void *)GetProcAddress(nt,"NtQuerySystemInformation"):NULL;
    times_ex_fn ex=nt?(times_ex_fn)(void *)GetProcAddress(nt,"NtQuerySystemInformationEx"):NULL;
    system_times_fn system_times=kernel?(system_times_fn)(void *)GetProcAddress(kernel,"GetSystemTimes"):NULL;
    unsigned successful=0;
    if(capture->first.cpu_count)for(WORD g=0;g<capture->first.groups;++g) {
        int source=0;unsigned count=capture->first.active[g];
        if(!read_times(old,ex,g,count,capture->first.groups==1,capture->buffer,&source)){capture->partial=1;continue;}
        ++successful;
        /* Array element n describes processor n in this explicitly selected
         * group. Sparse CPU Sets cannot be zipped by enumeration position. */
        int dense=1,group_valid=1;unsigned joined=0;
        for(unsigned i=0;i<capture->first.cpu_count;++i)if(capture->first.cpus[i].group==g&&capture->first.cpus[i].index>=count)dense=0;
        for(unsigned n=0;n<count;++n){struct time_row item;memset(&item,0,sizeof(item));
            if(!convert_times(&capture->buffer[n],&item)||!add_times(&capture->group_totals[g],&item))group_valid=0;}
        if(group_valid)capture->group_sources[g]=source;else memset(&capture->group_totals[g],0,sizeof(capture->group_totals[g]));
        if(!dense){capture->partial=1;continue;}
        for(unsigned i=0;i<capture->first.cpu_count;++i)if(capture->first.cpus[i].group==g) {
            unsigned n=capture->first.cpus[i].index;
            if(n>=count){capture->partial=1;continue;}
            struct time_row *row=&capture->rows[i];row->source=source;
            if(!convert_times(&capture->buffer[n],row)){capture->partial=1;continue;}
            ++joined;if(!row->classes)capture->partial=1;
        }
        if(joined!=count)capture->partial=1;
    }
    struct time_row fallback;memset(&fallback,0,sizeof(fallback));
    if(!successful&&capture->first.groups==1&&system_times) {
        FILETIME idle,kernel_ticks,user;
        if(system_times(&idle,&kernel_ticks,&user)) {
            uint64_t i=file_ticks(idle),k=file_ticks(kernel_ticks),u=file_ticks(user);
            if(k>=i&&k<=(uint64_t)INT64_MAX&&u<=(uint64_t)INT64_MAX-k) {
                fallback.valid=1;fallback.busy=k-i+u;fallback.total=k+u;fallback.user=u;
            }
        }
    }
    observe_roster(&api,&capture->last);capture->stable=same_observation(&capture->first,&capture->last);
    /* same_observation also serves topology reads. Here the domain and CPU
     * roster alone are the observations; NT array indices are the fallback
     * identities on systems where CPU Sets do not exist. */
    if(!capture->first.sets_valid&&!capture->last.sets_valid) {
        struct observation *a=&capture->first,*b=&capture->last;
        capture->stable=a->groups&&a->groups==b->groups&&a->logical==b->logical&&a->cpu_count==b->cpu_count&&!a->truncated&&!b->truncated;
        for(unsigned g=0;capture->stable&&g<a->groups;++g)if(a->active[g]!=b->active[g])capture->stable=0;
    }
    capture->partial|=capture->first.partial||capture->last.partial||!capture->stable;
    capture->truncated=capture->first.truncated||capture->last.truncated;
    if(capture->stable) {
        int complete=capture->first.cpu_count==capture->first.logical;
        for(unsigned i=0;i<capture->first.cpu_count;++i) {
            if(capture->rows[i].valid)++capture->count;
        }
        for(unsigned g=0;g<capture->first.groups;++g)if(!capture->group_totals[g].valid||!add_times(&capture->total,&capture->group_totals[g]))complete=0;
        if(complete&&capture->first.groups){capture->aggregate_source=capture->group_sources[0];}
        else{memset(&capture->total,0,sizeof(capture->total));capture->partial=1;}
        if(!capture->count&&fallback.valid){capture->total=fallback;capture->aggregate_source=3;capture->partial=1;}
    }
    char epoch[64];snprintf(epoch,sizeof(epoch),"windows:%llu",(unsigned long long)update_usage_epoch(capture));
    if(!successful&&!fallback.valid){lua_pushnil(L);lua_pushliteral(L,"system CPU counters unavailable");return 2;}
    lua_createtable(L,0,8);push_times(L,&capture->total,0);lua_setfield(L,-2,"raw");
    integer_field(L,"counter_bits",64);string_field(L,"counter_scope","system");
    const char *names[]={"unavailable","NtQuerySystemInformationEx","NtQuerySystemInformation","GetSystemTimes"};
    string_field(L,"counter_source",names[capture->aggregate_source]);string_field(L,"_source_epoch",epoch);
    boolean_field(L,"partial",capture->partial);boolean_field(L,"truncated",capture->truncated);
    lua_createtable(L,(int)capture->last.cpu_count,0);unsigned output=1;
    if(capture->stable)for(unsigned i=0;i<capture->first.cpu_count;++i) {
        const struct time_row *time=&capture->rows[i];const struct cpu_row *identity=&capture->last.cpus[i];
        char name[32],instance[128];unsigned id=flat_id(identity);snprintf(name,sizeof(name),"cpu%u",id);
        snprintf(instance,sizeof(instance),"nt:%d:g%u:p%u:%s%lu",time->source,identity->group,identity->index,identity->has_set?"set:":"index:",(unsigned long)identity->set_id);
        lua_createtable(L,0,10);integer_field(L,"id",id);string_field(L,"name",name);boolean_field(L,"online",1);
        integer_field(L,"processor_group",identity->group);integer_field(L,"logical_processor_index",identity->index);
        if(identity->has_set)integer_field(L,"cpu_set_id",identity->set_id);
        string_field(L,"identity_quality",api.sets&&!identity->has_set?"partial":"fresh");string_field(L,"source",names[time->source]);string_field(L,"_source_instance",instance);
        push_times(L,time,1);lua_setfield(L,-2,"raw");lua_rawseti(L,-2,output++);
    }
    lua_setfield(L,-2,"cores");return 1;
}
