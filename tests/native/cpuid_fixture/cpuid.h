#ifndef WTOP_REPLAY_CPUID_H
#define WTOP_REPLAY_CPUID_H
static unsigned __get_cpuid_max(unsigned leaf,unsigned *vendor) {
    (void)leaf;*vendor=0x68747541u;return 0x10;
}
static void fixture_cpuid(unsigned leaf,unsigned sub,unsigned *a,unsigned *b,unsigned *c,unsigned *d);
#define __cpuid_count(leaf,sub,a,b,c,d) fixture_cpuid(leaf,sub,&(a),&(b),&(c),&(d))
#endif
