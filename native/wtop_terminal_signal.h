#ifndef WTOP_TERMINAL_SIGNAL_H
#define WTOP_TERMINAL_SIGNAL_H
#include <signal.h>
#include <stdatomic.h>

/* A process-directed signal can arrive on a controller thread. Never split
 * reading and clearing its notification, or a concurrent delivery is lost. */
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "terminal signal flags must be lock-free");
static atomic_uint wtop_terminal_signals = 0;
enum { WTOP_TERMINAL_RESIZE = 1u, WTOP_TERMINAL_INTERRUPT = 2u,
       WTOP_TERMINAL_TERMINATE = 4u, WTOP_TERMINAL_HANGUP = 8u };

static inline void wtop_terminal_signal_notify(int number) {
    unsigned pending = 0;
    if (number == SIGWINCH) pending = WTOP_TERMINAL_RESIZE;
    else if (number == SIGINT) pending = WTOP_TERMINAL_INTERRUPT;
    else if (number == SIGTERM) pending = WTOP_TERMINAL_TERMINATE;
    else if (number == SIGHUP) pending = WTOP_TERMINAL_HANGUP;
    if (pending) atomic_fetch_or_explicit(&wtop_terminal_signals, pending, memory_order_relaxed);
}
static inline unsigned wtop_terminal_signal_pending(void) {
    return atomic_load_explicit(&wtop_terminal_signals, memory_order_relaxed);
}
static inline unsigned wtop_terminal_signal_take(void) {
    return atomic_exchange_explicit(&wtop_terminal_signals, 0, memory_order_relaxed);
}
static inline void wtop_terminal_signal_reset(unsigned pending) {
    atomic_store_explicit(&wtop_terminal_signals, pending, memory_order_relaxed);
}
#endif
