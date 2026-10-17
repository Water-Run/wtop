/* Fixed-width, little-endian protocol for the isolated x86 CPU readers. */
#ifndef WTOP_CPUID_PROTOCOL_H
#define WTOP_CPUID_PROTOCOL_H
#include <stdint.h>
#define WTOP_CPUID_CPUS 512u
#define WTOP_CPUID_LEAVES 96u
#define WTOP_CPUID_BYTES (2u * 1024u * 1024u)
#define WTOP_CPUID_MAGIC UINT32_C(0x50435457)
#define WTOP_CPUID_VERSION 1u
/* v2 uses a Linux CPU id directly, without Windows processor groups. */
#define WTOP_CPUID_LINUX_VERSION 2u
struct wtop_cpuid_target { uint32_t id; uint16_t group, index; };
struct wtop_cpuid_leaf { uint32_t leaf, subleaf, eax, ebx, ecx, edx; };
struct wtop_cpuid_header {
    uint32_t magic, version, bytes, cpus, architecture_bits, flags, checksum, reserved;
};
struct wtop_cpuid_cpu {
    uint32_t id, group, index, status, count, max_basic, max_extended, flags;
    uint32_t xcr0_low, xcr0_high, signature_after, initial_apic_after;
};
#define WTOP_CPUID_FLAG_XCR0 1u
#define WTOP_CPUID_FLAG_XMM 2u
#define WTOP_CPUID_FLAG_SSE2 4u
#define WTOP_CPUID_FLAG_OS_ID 8u
#define WTOP_CPUID_FLAG_RESTORED 16u
#define WTOP_CPUID_FLAG_TRUNCATED 32u
#define WTOP_CPUID_FLAG_GROUP_PIN 64u
#define WTOP_CPUID_FLAG_CPUID 128u
#define WTOP_CPUID_STATUS_OK 0u
#define WTOP_CPUID_STATUS_AFFINITY 1u
#define WTOP_CPUID_STATUS_UNSUPPORTED 2u
#define WTOP_CPUID_STATUS_WRONG_CPU 3u
#define WTOP_CPUID_STATUS_RESTORE 4u
#define WTOP_CPUID_STATUS_UNSTABLE 5u
#define WTOP_CPUID_STATUS_BAD_RANGE 6u
_Static_assert(sizeof(struct wtop_cpuid_target)==8,"CPUID target stride");
_Static_assert(sizeof(struct wtop_cpuid_header)==32,"CPUID header stride");
_Static_assert(sizeof(struct wtop_cpuid_cpu)==48,"CPUID CPU stride");
_Static_assert(sizeof(struct wtop_cpuid_leaf)==24,"CPUID leaf stride");
static inline uint32_t wtop_cpuid_checksum(const void *data, uint32_t size) {
    const unsigned char *p=data;uint32_t hash=UINT32_C(2166136261);
    for(uint32_t i=0;i<size;++i)hash=(hash^p[i])*UINT32_C(16777619);
    return hash;
}
#endif
