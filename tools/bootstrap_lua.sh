#!/bin/sh
set -eu

host_os=$(uname -s 2>/dev/null || true)
if [ "$host_os" != "Linux" ]; then
    echo "wtop: Linux is required (detected ${host_os:-unknown})" >&2
    exit 1
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=5.5.1
sha256=1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce
archive="$project_dir/.tools/downloads/lua-$version.tar.gz"
source_dir="$project_dir/.tools/src/lua-$version"
prefix="$project_dir/.tools/lua-$version"

if [ -x "$prefix/bin/lua" ]; then
    actual_version=$("$prefix/bin/lua" -v 2>&1)
    case "$actual_version" in
        "Lua 5.5.1 "*) ;;
        *)
            echo "wtop: existing project Lua is not the pinned Lua 5.5.1" >&2
            echo "actual: $actual_version" >&2
            exit 1
            ;;
    esac
    exit 0
fi

mkdir -p "$project_dir/.tools/downloads" "$project_dir/.tools/src"

if [ ! -f "$archive" ]; then
    partial="$archive.part"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --proto '=https' --tlsv1.2 \
            "https://www.lua.org/ftp/lua-$version.tar.gz" --output "$partial"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only "https://www.lua.org/ftp/lua-$version.tar.gz" -O "$partial"
    else
        echo "wtop: curl or wget is required to download Lua" >&2
        exit 1
    fi
    mv "$partial" "$archive"
fi

actual=$(sha256sum "$archive" | awk '{print $1}')
if [ "$actual" != "$sha256" ]; then
    echo "wtop: Lua archive checksum mismatch" >&2
    echo "expected: $sha256" >&2
    echo "actual:   $actual" >&2
    exit 1
fi

if [ ! -f "$source_dir/Makefile" ]; then
    tar -xzf "$archive" -C "$project_dir/.tools/src"
fi

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
make -C "$source_dir" -j "$jobs" linux
make -C "$source_dir" install INSTALL_TOP="$prefix"
"$prefix/bin/lua" -e 'assert(_VERSION == "Lua 5.5"); print(_VERSION)'
