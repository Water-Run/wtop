/* Read-only CPUID worker. Its process, affinity and instruction faults are
 * isolated from the 32-bit monitoring program. No privileged instruction or
 * machine setting is used. Selected CPUID leaves are bounded, not an attempt
 * to interpret every future vendor leaf. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cpuid.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "wtop_cpuid_protocol.h"
struct group_affinity { ULONG_PTR mask;WORD group,reserved[3]; };
struct processor_number { WORD group;BYTE number,reserved; };
typedef BOOL (WINAPI *set_group_fn)(HANDLE,const struct group_affinity *,struct group_affinity *);
typedef void (WINAPI *current_ex_fn)(struct processor_number *);
typedef DWORD (WINAPI *current_fn)(void);
static HANDLE parent_guard;
static DWORD started;
static int alive(void) { return WaitForSingleObject(parent_guard,0)==WAIT_TIMEOUT && (DWORD)(GetTickCount()-started)<2500; }
static void cpuid(uint32_t leaf,uint32_t sub,struct wtop_cpuid_leaf *out) {
    out->leaf=leaf;out->subleaf=sub;
    __cpuid_count(leaf,sub,out->eax,out->ebx,out->ecx,out->edx);
}
static int add(struct wtop_cpuid_cpu *cpu,struct wtop_cpuid_leaf *leaves,uint32_t leaf,uint32_t sub) {
    if(cpu->count==WTOP_CPUID_LEAVES){cpu->flags|=WTOP_CPUID_FLAG_TRUNCATED;return 0;}
    if(!alive())return 0;
    cpuid(leaf,sub,&leaves[cpu->count++]);return 1;
}
static void enumerate(struct wtop_cpuid_cpu *cpu,struct wtop_cpuid_leaf *leaves,uint32_t leaf,int cache) {
    unsigned bound=cache?32:16;int terminated=0;
    for(unsigned sub=0;sub<bound;++sub) {
        if(!add(cpu,leaves,leaf,sub))break;
        const struct wtop_cpuid_leaf *value=&leaves[cpu->count-1];
        if(cache?!(value->eax&31):(!(value->ebx&0xffff)||!((value->ecx>>8)&255))){terminated=1;break;}
    }
    if(!terminated)cpu->flags|=WTOP_CPUID_FLAG_TRUNCATED;
}
static int on_target(const struct wtop_cpuid_target *target,current_ex_fn ex,current_fn old) {
    if(ex){struct processor_number current;memset(&current,0,sizeof(current));ex(&current);return current.group==target->group&&current.number==target->index;}
    return !old||(target->group==0&&old()==target->index);
}
static void capture(const struct wtop_cpuid_target *target,struct wtop_cpuid_cpu *cpu,struct wtop_cpuid_leaf *leaves,
    set_group_fn set_group,current_ex_fn current_ex,current_fn current) {
    memset(cpu,0,sizeof(*cpu));cpu->id=target->id;cpu->group=target->group;cpu->index=target->index;
    cpu->status=WTOP_CPUID_STATUS_AFFINITY;
    if(target->index>=sizeof(ULONG_PTR)*8||(!set_group&&target->group))return;
    ULONG_PTR old_mask=0;struct group_affinity previous;memset(&previous,0,sizeof(previous));
    if(set_group) {
        struct group_affinity desired;memset(&desired,0,sizeof(desired));desired.group=target->group;desired.mask=(ULONG_PTR)1<<target->index;
        if(!set_group(GetCurrentThread(),&desired,&previous))return;
        cpu->flags|=WTOP_CPUID_FLAG_GROUP_PIN;
    } else {old_mask=SetThreadAffinityMask(GetCurrentThread(),(ULONG_PTR)1<<target->index);if(!old_mask)return;}
    if(current_ex||current)cpu->flags|=WTOP_CPUID_FLAG_OS_ID;
    if(!on_target(target,current_ex,current)){cpu->status=WTOP_CPUID_STATUS_WRONG_CPU;goto restore;}
    unsigned vendor=0;cpu->max_basic=__get_cpuid_max(0,&vendor);
    if(!cpu->max_basic&&!vendor){cpu->status=WTOP_CPUID_STATUS_UNSUPPORTED;goto restore;}
    cpu->flags|=WTOP_CPUID_FLAG_CPUID;
    if(!add(cpu,leaves,0,0)||!add(cpu,leaves,0x80000000,0)){cpu->status=WTOP_CPUID_STATUS_UNSTABLE;goto restore;}
    cpu->max_extended=leaves[cpu->count-1].eax;
    /* Older Intel CPUs may echo a basic leaf for an unsupported extended
     * range. That means no extended leaves, not an invalid CPUID instruction. */
    if(cpu->max_extended<0x80000000u)cpu->max_extended=0;
    if(cpu->max_basic>0xffff||cpu->max_extended>0x8000ffffu){cpu->status=WTOP_CPUID_STATUS_BAD_RANGE;goto restore;}
    struct wtop_cpuid_leaf first;memset(&first,0,sizeof(first));
    if(cpu->max_basic>=1){if(!add(cpu,leaves,1,0)){cpu->status=WTOP_CPUID_STATUS_UNSTABLE;goto restore;}first=leaves[cpu->count-1];}
    const uint32_t basic[]={2,5,6,7,0x15,0x16,0x1a};
    for(unsigned i=0;i<sizeof(basic)/sizeof(basic[0]);++i)if(cpu->max_basic>=basic[i]) {
        if(!add(cpu,leaves,basic[i],0))break;
        if(basic[i]==2&&(leaves[cpu->count-1].eax&255)>1)cpu->flags|=WTOP_CPUID_FLAG_TRUNCATED;
        if(basic[i]==7) {uint32_t maximum=leaves[cpu->count-1].eax;for(uint32_t sub=1;sub<=2&&sub<=maximum;++sub)add(cpu,leaves,7,sub);}
    }
    if(cpu->max_basic>=0xd&&(first.ecx&(1u<<26))){add(cpu,leaves,0xd,0);add(cpu,leaves,0xd,1);}
    uint32_t ext_features=0;
    for(uint32_t leaf=0x80000001u;leaf<=0x80000008u&&leaf<=cpu->max_extended;++leaf) {
        if(!add(cpu,leaves,leaf,0))break;
        if(leaf==0x80000001u)ext_features=leaves[cpu->count-1].ecx;
    }
    if(first.ecx&(1u<<31))add(cpu,leaves,0x40000000,0);
    char name[13];memcpy(name,&leaves[0].ebx,4);memcpy(name+4,&leaves[0].edx,4);memcpy(name+8,&leaves[0].ecx,4);name[12]=0;
    if(!strcmp(name,"GenuineIntel")&&cpu->max_basic>=4)enumerate(cpu,leaves,4,1);
    if(cpu->max_basic>=0xb)enumerate(cpu,leaves,0xb,0);
    if(cpu->max_basic>=0x1f)enumerate(cpu,leaves,0x1f,0);
    if(!strcmp(name,"AuthenticAMD")&&(ext_features&(1u<<22))) {
        if(cpu->max_extended>=0x8000001du)enumerate(cpu,leaves,0x8000001d,1);
        if(cpu->max_extended>=0x8000001eu)add(cpu,leaves,0x8000001e,0);
        if(cpu->max_extended>=0x80000026u)enumerate(cpu,leaves,0x80000026,0);
    }
    if((first.ecx&((1u<<26)|(1u<<27)))==((1u<<26)|(1u<<27))) {
        uint32_t low,high;__asm__ volatile(".byte 0x0f,0x01,0xd0":"=a"(low),"=d"(high):"c"(0));
        cpu->xcr0_low=low;cpu->xcr0_high=high;cpu->flags|=WTOP_CPUID_FLAG_XCR0;
    }
    if(IsProcessorFeaturePresent(PF_XMMI_INSTRUCTIONS_AVAILABLE))cpu->flags|=WTOP_CPUID_FLAG_XMM;
    if(IsProcessorFeaturePresent(PF_XMMI64_INSTRUCTIONS_AVAILABLE))cpu->flags|=WTOP_CPUID_FLAG_SSE2;
    struct wtop_cpuid_leaf last;memset(&last,0,sizeof(last));if(cpu->max_basic>=1)cpuid(1,0,&last);
    cpu->signature_after=last.eax;cpu->initial_apic_after=last.ebx>>24;
    cpu->status=WTOP_CPUID_STATUS_OK;
    if(!on_target(target,current_ex,current)||(cpu->max_basic>=1&&(last.eax!=first.eax||(last.ebx>>24)!=(first.ebx>>24))))cpu->status=WTOP_CPUID_STATUS_UNSTABLE;
restore:
    if(set_group?set_group(GetCurrentThread(),&previous,NULL)!=0:SetThreadAffinityMask(GetCurrentThread(),old_mask)!=0)cpu->flags|=WTOP_CPUID_FLAG_RESTORED;
    else cpu->status=WTOP_CPUID_STATUS_RESTORE;
}
static int hex_digit(wchar_t c) {if(c>=L'0'&&c<=L'9')return c-L'0';if(c>=L'a'&&c<=L'f')return c-L'a'+10;if(c>=L'A'&&c<=L'F')return c-L'A'+10;return -1;}
int wmain(int argc,wchar_t **argv) {
    if(argc!=3)return 2;
    uintptr_t guard=0;size_t guard_digits=wcslen(argv[1]);
    if(!guard_digits||guard_digits>sizeof(uintptr_t)*2)return 2;
    for(size_t i=0;i<guard_digits;++i){int digit=hex_digit(argv[1][i]);if(digit<0)return 2;guard=guard*16u+(unsigned)digit;}
    if(!guard)return 2;
    parent_guard=(HANDLE)(uintptr_t)guard;started=GetTickCount();if(!alive())return 3;
    size_t length=wcslen(argv[2]);if(!length||length%(sizeof(struct wtop_cpuid_target)*2)||length>WTOP_CPUID_CPUS*sizeof(struct wtop_cpuid_target)*2)return 2;
    unsigned count=(unsigned)(length/(sizeof(struct wtop_cpuid_target)*2));
    struct wtop_cpuid_target targets[WTOP_CPUID_CPUS];unsigned char *bytes=(unsigned char *)targets;
    for(size_t i=0;i<length;i+=2){int a=hex_digit(argv[2][i]),b=hex_digit(argv[2][i+1]);if(a<0||b<0)return 2;bytes[i/2]=(unsigned char)(a*16+b);}
    for(unsigned i=0;i<count;++i){if(targets[i].group>=64||targets[i].index>=64||targets[i].id!=targets[i].group*64u+targets[i].index)return 2;for(unsigned j=0;j<i;++j)if(targets[j].id==targets[i].id)return 2;}
    unsigned char *data=calloc(1,WTOP_CPUID_BYTES);if(!data)return 4;
    struct wtop_cpuid_header *header=(struct wtop_cpuid_header *)data;
    header->magic=WTOP_CPUID_MAGIC;header->version=WTOP_CPUID_VERSION;header->cpus=count;header->architecture_bits=sizeof(void *)*8;
    HMODULE kernel=GetModuleHandleA("kernel32.dll");
    set_group_fn set_group=(set_group_fn)(void *)GetProcAddress(kernel,"SetThreadGroupAffinity");
    current_ex_fn current_ex=(current_ex_fn)(void *)GetProcAddress(kernel,"GetCurrentProcessorNumberEx");
    current_fn current=(current_fn)(void *)GetProcAddress(kernel,"GetCurrentProcessorNumber");
    uint32_t offset=sizeof(*header);
    for(unsigned i=0;i<count;++i) {
        if(!alive()){free(data);return 3;}
        if(offset>WTOP_CPUID_BYTES-sizeof(struct wtop_cpuid_cpu)-WTOP_CPUID_LEAVES*sizeof(struct wtop_cpuid_leaf)){free(data);return 4;}
        struct wtop_cpuid_cpu *cpu=(struct wtop_cpuid_cpu *)(data+offset);
        struct wtop_cpuid_leaf *leaves=(struct wtop_cpuid_leaf *)(data+offset+sizeof(*cpu));
        capture(&targets[i],cpu,leaves,set_group,current_ex,current);
        offset+=(uint32_t)sizeof(*cpu)+cpu->count*(uint32_t)sizeof(*leaves);
        if(cpu->status||cpu->flags&WTOP_CPUID_FLAG_TRUNCATED)header->flags|=1;
    }
    header->bytes=offset;header->checksum=wtop_cpuid_checksum(data+sizeof(*header),offset-(uint32_t)sizeof(*header));
    HANDLE output=GetStdHandle(STD_OUTPUT_HANDLE);uint32_t written=0;
    while(written<offset){DWORD amount=0;if(!alive()||!WriteFile(output,data+written,offset-written,&amount,NULL)||!amount){free(data);return 5;}written+=amount;}
    free(data);CloseHandle(parent_guard);return 0;
}
