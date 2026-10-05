/* Both modern syscall numbers removed, so the module is compiled with none of
 * its optional kernel paths present at all.  This is the shape of a build
 * against a kernel header from before any of them, and it is the variant that
 * finds an interaction the single-feature shims cannot: a helper used by one
 * guard and a variable written by another.
 *
 * See tests/native/no_pidfd.h for why the #include has to come first. */
#include <sys/syscall.h>

#undef SYS_pidfd_open
#undef SYS_pidfd_send_signal
#undef SYS_close_range
