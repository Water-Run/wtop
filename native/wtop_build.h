#ifndef WTOP_BUILD_H
#define WTOP_BUILD_H

/* Generated identity is shared by every OS backend. Out-of-tree compilation
 * may omit the headers; unknown identity is then an empty string. */
#if defined(__has_include)
# if __has_include("build_revision.h")
#  include "build_revision.h"
# endif
# if __has_include("build_version.h")
#  include "build_version.h"
# endif
#endif
#ifndef WTOP_BUILD_REVISION
#define WTOP_BUILD_REVISION ""
#endif
#ifndef WTOP_VERSION
#define WTOP_VERSION ""
#endif

#endif
