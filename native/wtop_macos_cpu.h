/* Kernel logical slots, independently of unexposed physical CPU relationships. */
#ifndef WTOP_MACOS_CPU_H
#define WTOP_MACOS_CPU_H
#include <mach/mach.h>
#define WTOP_MACOS_MAX_CPUS 512
/* Borrowed cached right: callers must not deallocate it. */
host_t wtop_macos_host_port(void);
void wtop_macos_host_cleanup(void);
#endif
