/* Validate a residency-weighted clock without tying it to an enumeration slot. */
#ifndef WTOP_MACOS_GPU_CLOCK_H
#define WTOP_MACOS_GPU_CLOCK_H
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#define WTOP_MAX_GPU_STATES 128
struct wtop_gpu_state { int64_t ticks; int idle; };
static inline int wtop_gpu_state_label(const char *name, unsigned *next, int *idle) {
    *idle = !strcmp(name, "OFF") || !strcmp(name, "IDLE") || !strcmp(name, "DOWN");
    if (*idle) return 1;
    if (name[0] != 'P' || name[1] < '0' || name[1] > '9') return 0;
    unsigned number = (unsigned)(name[1] - '0');
    if (name[2]) {
        if (!number || name[2] < '0' || name[2] > '9' || name[3]) return 0;
        number = number * 10 + (unsigned)(name[2] - '0');
    }
    if (number > 64 || (*next == UINT_MAX ? number > 1 : number != *next)) return 0;
    *next = number + 1;
    return 1;
}
static inline int wtop_gpu_clock(const struct wtop_gpu_state *states, unsigned count,
    const double *hz, unsigned clocks, double *mean, double *active_fraction) {
    if (!count || count > WTOP_MAX_GPU_STATES || !clocks || clocks > 64) return 0;
    for (unsigned i = 0; i < clocks; ++i)
        /* The observed M4 table is not frequency-sorted: retain state order. */
        if (!isfinite(hz[i]) || hz[i] <= 0 || hz[i] > 1e11) return 0;
    double weighted = 0, active = 0, total = 0;
    unsigned clock = 0;
    for (unsigned i = 0; i < count; ++i) {
        if (states[i].ticks < 0) return 0;
        total += (double)states[i].ticks;
        if (states[i].idle) continue;
        if (clock == clocks) return 0;
        weighted += (double)states[i].ticks * hz[clock++];
        active += (double)states[i].ticks;
    }
    if (clock != clocks || total <= 0 || !isfinite(weighted)) return 0;
    *mean = active > 0 ? weighted / active : 0;
    *active_fraction = active / total;
    return isfinite(*mean) && isfinite(*active_fraction);
}
#endif
