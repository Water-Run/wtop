#!/bin/sh
# Build wtop inside a distribution container and report the glibc floor of the
# artifacts that come out.
#
# Usage: tools/cross_libc_build.sh <image> [suite]
#
#   suite   additionally run the Lua unit suite in the container, which is the
#           only way to show the older-libc artifacts work rather than merely
#           compile.
#
# Why this exists.  The glibc floor of a wtop artifact is a property of the
# machine that compiled it, not of the source, so "which glibc does wtop need"
# is only answerable by compiling somewhere and reading the result off the
# binaries.  A container varies the libc while leaving everything else alone, so
# it is the cheapest way to get that answer.
#
# What it deliberately cannot do is vary the kernel: a container shares the
# host's, so this says nothing about minimum-kernel claims and must not be
# cited for them.  docs/PACKAGING.md 9.2 answers the kernel question from the
# source instead.
#
# The project tree is streamed in on stdin and never bind-mounted, so a
# container build cannot modify the working tree even if it wants to.
#
# --network host is used because the development host reaches the network
# through a proxy on 127.0.0.1, which a container's own loopback cannot see,
# and some images need a package manager to install a compiler at all.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lua_version=5.5.1
lua_archive="$project_dir/.tools/downloads/lua-$lua_version.tar.gz"
native_flags="-O2 -std=c17 -fPIC -Wall -Wextra -Werror"

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <image> [suite]" >&2
    exit 2
fi
image=$1
run_suite=${2:-}

# The suite compares collectors against the procfs of whatever kernel it runs
# on, and one of those tests insists a live host has more than five processes.
# A container's own PID namespace holds a handful, so the run would fail on the
# namespace rather than on the libc.  Sharing the host's PID namespace makes
# the environment faithful to what the test is about; weakening the assertion
# instead would let a real regression through on every host.
pid_flag=
if [ "$run_suite" = "suite" ]; then
    pid_flag=--pid=host
fi

command -v podman >/dev/null 2>&1 || {
    echo "$0: podman is required" >&2
    exit 2
}
[ -f "$lua_archive" ] || {
    echo "$0: $lua_archive is missing; run the project's Lua bootstrap first" >&2
    exit 2
}

# A staging tree, assembled in a directory of its own so the archive carries
# exactly what the container needs and nothing that could be mistaken for it.
stage=$(mktemp -d "${TMPDIR:-/tmp}/wtop-cross-libc.XXXXXX")
archive=""
cleanup() {
    # This host wraps rm in a recoverable-delete helper that narrates what it
    # moved; that note is not part of the measurement and would otherwise land
    # in the middle of the report.
    if [ -n "$stage" ]; then rm -rf -- "$stage" >/dev/null 2>&1; fi
    if [ -n "$archive" ]; then rm -f -- "$archive" >/dev/null 2>&1; fi
    return 0
}
trap cleanup EXIT INT TERM
cp -r "$project_dir/native" "$stage/"
cp "$lua_archive" "$stage/"

# The build identity travels with the sources.  The container has no .git, so it
# cannot run tools/write_build_id.sh, and without the header the module it builds
# reports an empty revision -- which is the correct thing for a tree with no
# history and the wrong thing for this one, whose Lua half does carry a revision.
# The header comes from the host, where the git describe that produced it ran.
# The version header travels with it for the same reason: it is generated from
# the same script run, and a container build without it would compile a module
# that reports no version, which tests/unit/test_version_convergence.lua would
# correctly refuse to accept.
# `make cross-libc` depends on `native`, so both files are there by now; a
# missing one is a hard error rather than a silently identity-less artifact.
revision_header="$project_dir/build/native/build_revision.h"
version_header="$project_dir/build/native/build_version.h"
for header in "$revision_header" "$version_header"; do
    [ -f "$header" ] || {
        echo "$0: $header is missing; run 'make native' first" >&2
        exit 2
    }
done
mkdir -p "$stage/build/native"
cp "$revision_header" "$version_header" "$stage/build/native/"

if [ "$run_suite" = "suite" ]; then
    mkdir -p "$stage/full"
    # docs/ and .github/ are not optional here.  Two of the unit tests assert on
    # what the documents say -- the declared glibc floor and the published test
    # count -- and a third asserts that no CI step invokes a release-evidence
    # tool directly.  A staging tree without them fails on a missing file rather
    # than on anything to do with the libc, and making those assertions
    # conditional on the file being present would be the same defect in the test:
    # the check would be skipped on exactly the machine where nobody can see that
    # it was skipped.  That cost one confusing "cannot read" before it was found,
    # the same way omitting docs/ did.
    # locales/ joins that list for the same reason, and it is the fifth such
    # omission rather than a new kind of problem.  `test_reason_localization.lua`
    # now asserts that every catalogue's `reason.*` keys are in ascending order
    # and one contiguous run, which is a property of the *source* YAML and not of
    # the generated Lua the container already had -- `require("wtop.generated.
    # locales.en-US")` is a hash table and carries no order.  So the clause reads
    # `locales/*.yml`, the container had no such directory, and the suite failed
    # with a bare "FAIL" in the one environment that exists to catch libc
    # differences.  Making the clause conditional on the directory being present
    # would repeat verbatim the mistake the comment above warns about twice, so
    # the directory travels instead.
    cp -r "$project_dir/src" "$project_dir/tests" "$project_dir/native" \
        "$project_dir/tools" "$project_dir/docs" "$project_dir/.github" \
        "$project_dir/locales" \
        "$stage/full/"
    # VERSION travels with them: three tests read it, and a staging tree without
    # it would report a version disagreement that is an artefact of the staging
    # rather than of the code.
    #
    # THIRD_PARTY.md travels for the same reason and is not optional either.  It
    # is read by tests/unit/test_release_evidence.lua, which checks that every
    # path the file names in backticks is a path the release actually contains.
    # Skipping that check when the file is absent would be the same defect in the
    # test: the clause would be skipped on exactly the machine where nobody can
    # see that it was skipped.  Its absence from this list was found by the
    # suite failing at "cannot read THIRD_PARTY.md" -- the fourth time a file
    # this tree reads has been missing from the staging list, after docs/,
    # .github/ and VERSION.
    cp "$project_dir/Makefile" "$project_dir/VERSION" "$project_dir/THIRD_PARTY.md" \
        "$stage/full/"
fi

# The archive lives beside the staging tree, not inside it: `tar -C "$stage" .`
# would otherwise try to include the archive it is still writing.
archive=$(mktemp "${TMPDIR:-/tmp}/wtop-cross-libc-tar.XXXXXX")
tar -c -C "$stage" . >"$archive"

# The container program is passed as an argument rather than on stdin: stdin
# carries the staged tarball, and `sh -s` would read the two as one stream.
container_program='
set -eu
native_flags=$1
run_suite=$2

mkdir -p /b
tar -x -C /b
cd /b

# An image that ships no compiler gets one, by whichever manager it has.  The
# check is deliberate rather than unconditional: manylinux-style images already
# have a full toolchain, and running a package manager there would add a
# network dependency to a measurement that should need none.
if ! command -v gcc >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq gcc libc6-dev binutils make >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q gcc glibc-devel binutils make >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache gcc musl-dev binutils make >/dev/null 2>&1 || true
    fi
fi
command -v gcc >/dev/null 2>&1 || { echo "no C compiler available in this image" >&2; exit 1; }

# Three of the unit tests shell out to the Python tools in this repository, so
# a suite run without python3 fails on a missing interpreter and says nothing
# about the libc.  manylinux2014 ships python2 and no python3, and installing it
# is what the suite needs before its results mean anything.  The floor
# measurement above does not use Python at all, so this is required for the
# suite specifically and not for the measurement.
if [ "$run_suite" = "suite" ] && ! command -v python3 >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq python3 >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q python3 >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q python3 >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache python3 >/dev/null 2>&1 || true
    fi
    command -v python3 >/dev/null 2>&1 || {
        echo "no python3 available in this image and it could not be installed;" >&2
        echo "the unit suite needs it for tools/elf_floors.py and tools/make_sbom.py." >&2
        echo "The glibc floor above was still measured; only the suite is missing." >&2
        exit 1
    }
    echo "installed python3 $(python3 -V 2>&1) for the unit suite"
fi

build_glibc=$(ldd --version 2>/dev/null | head -1 | grep -o "[0-9.]*$" || echo unknown)
echo "== container"
echo "image: $IMAGE"
echo "build glibc: $build_glibc"
echo "host kernel: $(uname -r)   (shared with the container; not a claim about it)"
echo

tar -xzf "lua-$LUA_VERSION.tar.gz"
make -C "/b/lua-$LUA_VERSION" -j"$(nproc 2>/dev/null || echo 2)" linux >/dev/null 2>&1
make -C "/b/lua-$LUA_VERSION" install INSTALL_TOP=/opt/lua >/dev/null 2>&1

mkdir -p /b/native-build
gcc $native_flags -shared -I/b/build/native -I/opt/lua/include \
    -o /b/native-build/wtop_native.so \
    /b/native/wtop_native.c /b/native/wtop_nvml.c /b/native/wtop_amdsmi.c \
    /b/native/wtop_levelzero.c -ldl

floors=""
report() {
    label=$1
    file=$2
    required=$(objdump -T "$file" | grep -o "GLIBC_[0-9][0-9.]*" | sed "s/^GLIBC_//" | sort -Vu | tr "\n" " ")
    highest=$(printf "%s\n" $required | sort -Vu | tail -1)
    if [ -z "$highest" ]; then
        echo "  $label: links no versioned glibc symbol (unmeasurable)"
        return
    fi
    echo "  $label: $required   (highest $highest)"
    floors="$floors $required"
}

echo "== required GLIBC symbol versions"
report "lua interpreter" /opt/lua/bin/lua
report "native module   " /b/native-build/wtop_native.so
echo

echo "== shared library dependencies"
for f in /b/native-build/wtop_native.so /opt/lua/bin/lua; do
    readelf -d "$f" | sed -n "s/.*(NEEDED).*\[\(.*\)\]/  \1/p"
done
echo

combined=$(printf "%s\n" $floors | sort -Vu | tail -1)
echo "combined glibc floor: $combined"

if [ "$run_suite" = "suite" ]; then
    echo
    echo "== unit suite in this container"
    mkdir -p /b/full/build/native
    cp /b/native-build/wtop_native.so /b/full/build/native/wtop_native.so
    # The revision header has to be where the staged tree expects it, not only
    # where it was compiled: tests/unit/test_build_identity.lua reads the file
    # to confirm the module was compiled against the header the Lua half agrees
    # with.  Without it the module carries a revision and the test still fails,
    # for want of the one artifact that makes the two comparable.
    cp /b/build/native/build_revision.h /b/full/build/native/build_revision.h
    cp /b/build/native/build_version.h /b/full/build/native/build_version.h
    # The suite asserts against the toolchain layout of the project itself, so
    # give the staged tree one.  tests/unit/test_native_baseline.lua reads
    # LUA_VERSION out of the Makefile and then opens .tools/lua-<v>/bin/lua,
    # and tests/unit/test_native_build.lua compiles the module against
    # .tools/lua-<v>/include.  A container that built Lua to /opt and stopped
    # there would fail both on a missing path rather than on anything about the
    # libc, so the whole prefix is mirrored, not just the two executables.
    # NOTE: this program is a single-quoted shell string, so an apostrophe
    # anywhere below -- including in a comment -- silently ends it and the
    # remainder is parsed as shell by the outer script.  That cost one confusing
    # "unexpected fi" before it was found; do not put one in.
    mkdir -p "/b/full/.tools/lua-$LUA_VERSION"
    ln -sfn /opt/lua/include "/b/full/.tools/lua-$LUA_VERSION/include"
    ln -sfn /opt/lua/lib "/b/full/.tools/lua-$LUA_VERSION/lib"
    mkdir -p "/b/full/.tools/lua-$LUA_VERSION/bin"
    ln -sf /opt/lua/bin/lua "/b/full/.tools/lua-$LUA_VERSION/bin/lua"
    ln -sf /opt/lua/bin/luac "/b/full/.tools/lua-$LUA_VERSION/bin/luac"
    cd /b/full
    LUA_PATH="./src/?.lua;./src/?/init.lua;./tests/?.lua;" \
    LUA_CPATH="/b/full/build/native/?.so;;" \
        /opt/lua/bin/lua tests/run.lua tests/unit/test_*.lua
    echo "--version: $(/opt/lua/bin/lua src/wtop.lua --version 2>&1 | head -1)"
fi
'

if ! podman run -i --rm --network host ${pid_flag} -e "IMAGE=$image" -e "LUA_VERSION=$lua_version" \
    "$image" sh -c "$container_program" wtop "$native_flags" "$run_suite" \
    <"$archive"; then
    echo "$0: the container build failed" >&2
    exit 1
fi
