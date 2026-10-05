/* A compile-time stand-in for a toolchain whose <sys/syscall.h> predates
 * Linux 5.9, where close_range(2) does not exist.
 *
 * close_range is a speed-up inside close_extra_fds, not the mechanism: the
 * function falls back to walking /proc/self/fd with getdents64 and then to a
 * bounded close() loop, so a kernel without it still closes its descriptors
 * correctly, just more slowly.  That is a runtime property the fallback
 * already provides; what this file checks is the compile-time one, since the
 * same assignment-outside-the-branch pattern that broke the pidfd path would
 * break here too and -Werror would turn it into a build failure rather than a
 * slower run.
 *
 * See tests/native/no_pidfd.h for why the #include has to come first. */
#include <sys/syscall.h>

#undef SYS_close_range
