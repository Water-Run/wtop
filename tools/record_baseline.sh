#!/bin/sh
# Reproducible evidence for the release gate: the native module's
# architecture, dynamic dependencies, and the minimum glibc symbol version it
# requires, plus the kernel it was built on. Run on every packaging host and
# keep the output with the release artifacts.
#
# Usage: tools/record_baseline.sh [module] > dist/BASELINE.txt
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module=${1:-"$project_dir/build/native/wtop_native.so"}

revision=$(git -C "$project_dir" describe --always --dirty --tags 2>/dev/null || echo unknown)

echo "wtop native baseline evidence"
echo "revision: $revision"
echo "build host: $(uname -srm)"
echo "module: $module"
echo

echo "== file"
file "$module"
echo

echo "== ldd"
ldd "$module"
echo

echo "== required GLIBC symbol versions (ascending)"
objdump -T "$module" | grep -o 'GLIBC_[0-9][0-9.]*' | sort -Vu | sed 's/^/  /'
echo

echo "minimum glibc symbol version:" \
    "$(objdump -T "$module" | grep -o 'GLIBC_[0-9][0-9.]*' | sort -Vu | tail -1)"
echo "minimum kernel baseline: recorded per validation host in docs/CROSS_PLATFORM.md"
