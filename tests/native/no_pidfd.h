/* A compile-time stand-in for a toolchain whose <sys/syscall.h> predates
 * Linux 5.1.
 *
 * The module guards its pidfd path with `#if defined(SYS_pidfd_open) &&
 * defined(SYS_pidfd_send_signal)`, so those two names are the whole difference
 * between a build that has process-identity signalling and one that reports it
 * unavailable.  The names come from the host's kernel headers, which means the
 * guarded branch is otherwise exercised on exactly one machine class: any
 * developer box with a current kernel.  Including this file ahead of the
 * translation unit pulls in the real header and then removes the two macros,
 * so the `#else` branch is compiled and checked on every host.
 *
 * The `#include` first is the point.  wtop_native.c includes <sys/syscall.h>
 * itself, but by then the include guard makes it a no-op, so the #undef below
 * survives.  The reverse order would silently do nothing.
 *
 * This file caught two real defects: a variable that is assigned before the
 * branch and read only inside it, and a static helper defined unconditionally
 * whose only caller is in the guarded branch.  Both are warnings, and the
 * project builds with -Werror, so on an older toolchain the module did not
 * build at all rather than building without the feature. */
#include <sys/syscall.h>

#undef SYS_pidfd_open
#undef SYS_pidfd_send_signal
