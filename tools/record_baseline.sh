#!/bin/sh
# Reproducible evidence for the release gate: the architecture, dynamic
# dependencies, and required glibc symbol versions of every ELF that ships,
# plus the floor promised in tools/baseline.conf.
#
# Usage: tools/record_baseline.sh <elf> [<elf> ...] > dist/BASELINE.txt
#
# The ELF list is an argument rather than a default because the previous
# version measured only the native module and reported its floor as *the*
# floor.  The interpreter that luainstaller embeds asks for a newer glibc than
# the module does, so a report that names one file silently understates what a
# user has to have installed.  Whoever packages wtop now has to say which
# binaries they ship, and a file that is missing is a hard error rather than a
# smaller number.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <elf> [<elf> ...]" >&2
    echo "name every ELF the release ships, for example:" >&2
    echo "  $0 build/native/wtop_native.so .tools/lua-5.5.1/bin/lua" >&2
    exit 2
fi

for tool in file ldd objdump; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$0: $tool is required to read a release baseline" >&2
        exit 2
    }
done

# shellcheck source=tools/baseline.conf
. "$project_dir/tools/baseline.conf"
case ${GLIBC_FLOOR:-} in
    ''|*[!0-9.]*)
        echo "$0: GLIBC_FLOOR in tools/baseline.conf must be a dotted version" >&2
        exit 2
        ;;
esac

# Numeric comparison of dotted versions, field by field, with absent fields
# read as zero so that 2.17 and 2.17.0 agree.  A lexicographic sort would call
# 2.9 newer than 2.17, and this is the comparison that decides whether a build
# is shippable.
version_gt() {
    left=$1
    right=$2
    while [ -n "$left$right" ]; do
        l=${left%%.*}
        r=${right%%.*}
        [ -n "$l" ] || l=0
        [ -n "$r" ] || r=0
        [ "$l" -gt "$r" ] && return 0
        [ "$l" -lt "$r" ] && return 1
        case $left in *.*) left=${left#*.} ;; *) left= ;; esac
        case $right in *.*) right=${right#*.} ;; *) right= ;; esac
    done
    return 1
}

revision=$(git -C "$project_dir" describe --always --dirty --tags 2>/dev/null || echo unknown)

echo "wtop native baseline evidence"
echo "checkout revision: $revision"
echo "build host: $(uname -srm)"
echo "promised glibc floor: $GLIBC_FLOOR"
echo

# The combined floor is the highest any one shipped file needs.  A bundle runs
# all of them, so the lowest requirement among them is not the requirement.
floor=0
floor_file=
measured=0
unmeasurable=0
status=0

for module in "$@"; do
    if [ ! -f "$module" ]; then
        echo "MISSING: $module" >&2
        status=1
        continue
    fi
    measured=$((measured + 1))
    file "$module"
    ldd "$module" || true
    # A hash per artifact, so that "these two files are the same build" is a
    # question with an answer.  The checkout revision in the header does not
    # answer it: it describes the tree, and a stale artifact in a current tree
    # would carry the current tree's revision in this report without anyone
    # noticing that the bytes are older.
    if command -v sha256sum >/dev/null 2>&1; then
        echo "  sha256: $(sha256sum "$module" | cut -d' ' -f1)"
    fi
    # What a file needs is the highest requirement among every ELF image that
    # will execute on the target, not just the one at offset 0.  For the
    # onedir bundle and a plain module that is the file itself; for the onefile
    # it is the launcher plus the module and the interpreter appended to it,
    # which it extracts and runs.  Measuring the launcher alone reported
    # GLIBC_2.34 for an artifact whose embedded interpreter needs GLIBC_2.38 --
    # a number that is wrong in the direction that hides the problem.  The
    # section header is the tool's own, so this loop does not print one.
    if ! "$project_dir/tools/elf_floors.py" "$module"; then
        # A file that yields no versioned glibc symbol is not a lower
        # requirement; it is an unmeasurable one, and guessing would be worse.
        echo "UNMEASURABLE: $module yields no versioned glibc symbol" >&2
        unmeasurable=$((unmeasurable + 1))
        status=1
        continue
    fi
    highest=$("$project_dir/tools/elf_floors.py" --quiet "$module")
    if version_gt "$highest" "$floor"; then
        floor=$highest
        floor_file=$module
    fi
done

# An unmeasurable file leaves its contribution at zero, and zero compares below
# every promised floor, so the verdict below would read "within the promised
# floor" on the strength of a number that was never obtained.  The exit status
# already said so; this document did not.  A gate that exits non-zero while
# writing a report certifying the release is the same failure as an SBOM that
# exits zero while describing nothing: the reader has to notice, and the reader
# is reading the document.

if [ "$unmeasurable" -ne 0 ]; then
    echo "combined glibc floor: undetermined ($unmeasurable of $measured shipped ELFs could not be measured)"
    echo "NO VERDICT: an artifact that could not be measured cannot be shown to be" >&2
    echo "          within the promised floor of $GLIBC_FLOOR, and the artifacts" >&2
    echo "          that could be measured are not evidence about the ones that" >&2
    echo "          could not." >&2
    exit 1
fi

echo "combined glibc floor: $floor (set by $floor_file)"
if [ "$measured" -eq 0 ]; then
    echo "no shipped ELF was measured, so no floor can be claimed" >&2
    exit 1
fi
if version_gt "$floor" "$GLIBC_FLOOR"; then
    echo "FAIL: the artifacts require glibc $floor but only $GLIBC_FLOOR is promised" >&2
    echo "      build on an older glibc, or raise GLIBC_FLOOR in tools/baseline.conf" >&2
    echo "      and accept that older distributions are then unsupported." >&2
    exit 1
fi

cat <<EOF
status: within the promised floor

The revision above describes the checkout, not the artifacts.  Those are two
different claims and the first version of this file made only one of them.  Each
artifact now carries its own hash, and the native module compiles its source
revision in -- from the same git describe as src/wtop/build_id.lua -- so an
artifact can be asked which tree built it rather than assumed to.  A onefile
bundle is not byte-comparable against the module built beside it, because
luainstaller strips the copy it embeds; there the module's reported revision is
what to compare, not its hash.

The kernel is not part of this file on purpose.  Nothing in the artifacts
records a minimum kernel: an ELF declares the libc it needs, not the kernel
interfaces its collector will read, and wtop treats every one of those as
optional -- a missing interface degrades its own panel and is reported in the
snapshot's quality record rather than preventing startup.  docs/MONITORING.md
lists which panel each source feeds.  The kernel this build ran on is the
"build host" line above; it is a record of where the evidence was produced, not
a requirement.
EOF
exit $status
