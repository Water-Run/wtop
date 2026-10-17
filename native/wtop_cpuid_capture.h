/* Bounded x86 instruction enumeration shared by isolated OS readers. */
#ifndef WTOP_CPUID_CAPTURE_H
#define WTOP_CPUID_CAPTURE_H
#include <cpuid.h>
#include <stdint.h>
#include <string.h>
#include "wtop_cpuid_protocol.h"
/* The including reader supplies a monotonic deadline check. */
static void cpuid(uint32_t leaf,uint32_t sub,struct wtop_cpuid_leaf *out) {
    out->leaf=leaf;out->subleaf=sub;
    __cpuid_count(leaf,sub,out->eax,out->ebx,out->ecx,out->edx);
}
static int add(struct wtop_cpuid_cpu *cpu,struct wtop_cpuid_leaf *leaves,uint32_t leaf,uint32_t sub) {
    if(cpu->count==WTOP_CPUID_LEAVES){cpu->flags|=WTOP_CPUID_FLAG_TRUNCATED;return 0;}
    if(!cpuid_alive())return 0;
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
static void wtop_cpuid_snapshot(struct wtop_cpuid_cpu *cpu,struct wtop_cpuid_leaf *leaves) {
    unsigned vendor=0;cpu->max_basic=__get_cpuid_max(0,&vendor);
    if(!cpu->max_basic&&!vendor){cpu->status=WTOP_CPUID_STATUS_UNSUPPORTED;return;}
    cpu->flags|=WTOP_CPUID_FLAG_CPUID;
    if(!add(cpu,leaves,0,0)||!add(cpu,leaves,0x80000000,0)){cpu->status=WTOP_CPUID_STATUS_UNSTABLE;return;}
    cpu->max_extended=leaves[cpu->count-1].eax;
    /* Older Intel CPUs may echo a basic leaf for an unsupported extended
     * range. That means no extended leaves, not an invalid CPUID instruction. */
    if(cpu->max_extended<0x80000000u)cpu->max_extended=0;
    if(cpu->max_basic>0xffff||cpu->max_extended>0x8000ffffu){cpu->status=WTOP_CPUID_STATUS_BAD_RANGE;return;}
    struct wtop_cpuid_leaf first;memset(&first,0,sizeof(first));
    if(cpu->max_basic>=1){if(!add(cpu,leaves,1,0)){cpu->status=WTOP_CPUID_STATUS_UNSTABLE;return;}first=leaves[cpu->count-1];}
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
    struct wtop_cpuid_leaf last;memset(&last,0,sizeof(last));if(cpu->max_basic>=1)cpuid(1,0,&last);
    cpu->signature_after=last.eax;cpu->initial_apic_after=last.ebx>>24;
    cpu->status=WTOP_CPUID_STATUS_OK;
    if(cpu->max_basic>=1&&(last.eax!=first.eax||(last.ebx>>24)!=(first.ebx>>24)))cpu->status=WTOP_CPUID_STATUS_UNSTABLE;
}
#endif
