/* Private, little-endian protocol. Values are data operations, never Lua
 * source, bytecode or function references. Each response is independently
 * bounded, checksummed and paired with its request sequence. */
#ifndef WTOP_NVML_PROTOCOL_H
#define WTOP_NVML_PROTOCOL_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <float.h>
#include <math.h>
#include "wtop_nvml_output.h"
#define NVML_WIRE_MAGIC UINT32_C(0x4d4e5457)
#define NVML_WIRE_VERSION 1u
#define NVML_WIRE_COMMAND 24u
#define NVML_WIRE_HEADER 64u
#define NVML_WIRE_LIMIT (16u*1024u*1024u)
#define NVML_WIRE_OPERATIONS 600000u
#define NVML_WIRE_TABLES 131072u
_Static_assert(sizeof(double)==8&&DBL_MANT_DIG==53&&DBL_MAX_EXP==1024,"NVML wire double ABI");
static inline uint32_t nvml_u32(const unsigned char *p) {
    return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);
}
static inline uint64_t nvml_u64(const unsigned char *p) {
    return nvml_u32(p)|((uint64_t)nvml_u32(p+4)<<32);
}
static inline void nvml_put32(unsigned char *p,uint32_t value) {
    for(unsigned i=0;i<4;++i)p[i]=(unsigned char)(value>>(i*8));
}
static inline void nvml_put64(unsigned char *p,uint64_t value) {
    for(unsigned i=0;i<8;++i)p[i]=(unsigned char)(value>>(i*8));
}
static inline uint32_t nvml_checksum(const void *bytes,size_t n) {
    const unsigned char *p=bytes;uint32_t hash=UINT32_C(2166136261);
    for(size_t i=0;i<n;++i)hash=(hash^p[i])*UINT32_C(16777619);
    return hash;
}
/* Validate the entire instruction stream before any Lua allocation. Table
 * depth and total work are bounded independently of response byte length. */
static inline int nvml_wire_valid(const unsigned char *data,size_t length) {
    size_t p=0;unsigned depth=0,operations=0,tables=0,entries[64]={0};
    if(!length||length>NVML_WIRE_LIMIT)return 0;
    while(p<length){
        unsigned op=data[p++];if(++operations>NVML_WIRE_OPERATIONS)return 0;
        if(op==NVML_TABLE){
            if(length-p<8||depth==64||++tables>NVML_WIRE_TABLES)return 0;
            if(nvml_u32(data+p)>128||nvml_u32(data+p+4)>4096)return 0;
            p+=8;entries[depth++]=0;continue;
        }
        if(op==NVML_INDEX){
            if(depth<2||length-p<4||!nvml_u32(data+p)||nvml_u32(data+p)>4096)return 0;
            p+=4;--depth;if(++entries[depth-1]>4096)return 0;continue;
        }
        if(op==NVML_DISCARD){if(depth<2)return 0;--depth;continue;}
        if(op<NVML_INTEGER||op>NVML_FIELD||!depth||p>=length)return 0;
        size_t n=data[p++];if(!n||n>63||n>length-p)return 0;
        for(size_t i=0;i<n;++i){unsigned char c=data[p+i];if(!((c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='_'))return 0;}
        p+=n;
        if(op==NVML_FIELD){if(depth<2)return 0;--depth;}
        if(++entries[depth-1]>4096)return 0;
        if(op==NVML_INTEGER||op==NVML_NUMBER){
            if(length-p<8)return 0;
            if(op==NVML_NUMBER){uint64_t bits=nvml_u64(data+p);double value;memcpy(&value,&bits,8);if(!isfinite(value))return 0;}
            p+=8;
        }
        else if(op==NVML_BOOLEAN){if(p>=length||data[p]>1)return 0;++p;}
        else if(op==NVML_STRING){
            if(length-p<2)return 0;
            n=(size_t)data[p]|((size_t)data[p+1]<<8);p+=2;
            if(n>256||n>length-p||memchr(data+p,0,n))return 0;
            p+=n;
        }
    }
    return depth==1;
}
#endif
