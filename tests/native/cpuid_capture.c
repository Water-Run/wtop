#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned topoext,topology_calls,cache_calls;
static int cpuid_alive(void){return 1;}
#include "wtop_cpuid_capture.h"
static void fixture_cpuid(unsigned leaf,unsigned sub,unsigned *a,unsigned *b,unsigned *c,unsigned *d) {
    *a=*b=*c=*d=0;
    if(leaf==0){*a=0x10;*b=0x68747541;*d=0x69746e65;*c=0x444d4163;}
    else if(leaf==1){*a=0xa10f11;}
    else if(leaf==0x80000000u){*a=0x80000026;}
    else if(leaf==0x80000001u){*c=topoext?(1u<<22):0;}
    else if(leaf==0x8000001du){cache_calls++;}
    else if(leaf==0x80000026u){
        topology_calls++;
        if(sub<2){*a=sub?3:1;*b=sub?8:2;*c=(sub?4u:1u)<<8|sub;}
        else *c=sub;
    }
}
int main(void){
    for(topoext=0;topoext<2;topoext++){
        struct wtop_cpuid_cpu cpu;
        struct wtop_cpuid_leaf leaves[WTOP_CPUID_LEAVES];
        memset(&cpu,0,sizeof(cpu));topology_calls=cache_calls=0;
        wtop_cpuid_snapshot(&cpu,leaves);
        if(cpu.status!=WTOP_CPUID_STATUS_OK||topology_calls!=3||cache_calls!=topoext){
            fprintf(stderr,"TOPOEXT=%u status=%u topology26=%u deterministiccache=%u\n",topoext,cpu.status,topology_calls,cache_calls);return 1;
        }
    }
    puts("Independent AMD26 topology capture and TOPOEXT cache guard passed");return 0;
}
