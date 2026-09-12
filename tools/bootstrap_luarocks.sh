#!/bin/sh
# Install the pinned LuaRocks into .tools/luarocks.
#
# wtop targets Lua 5.5, which LuaRocks only learned to build for in 3.12.
# Ubuntu 24.04 still ships 3.8, so relying on the distribution package makes
# `--lua-version=5.5` fail on exactly the systems most likely to run CI.  This
# builds the pinned release against the project's own Lua instead, which keeps
# the packaging path identical on a developer machine and on a fresh runner.
set -eu

host_os=$(uname -s 2>/dev/null || true)
if [ "$host_os" != "Linux" ]; then
    echo "wtop: Linux is required (detected ${host_os:-unknown})" >&2
    exit 1
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=3.13.0
# Recorded from the published release archive; it pins what is built, so an
# upstream change to the tarball is a hard failure rather than a silent swap.
sha256=245bf6ec560c042cb8948e3d661189292587c5949104677f1eecddc54dbe7e37
lua_prefix="$project_dir/.tools/lua-5.5.1"
archive="$project_dir/.tools/downloads/luarocks-$version.tar.gz"
source_dir="$project_dir/.tools/src/luarocks-$version"
prefix="$project_dir/.tools/luarocks"

if [ -x "$prefix/bin/luarocks" ]; then
    actual_version=$("$prefix/bin/luarocks" --version 2>&1 | head -n 1)
    case "$actual_version" in
        *" $version") exit 0 ;;
        *)
            echo "wtop: existing project LuaRocks is not the pinned $version" >&2
            echo "actual: $actual_version" >&2
            exit 1
            ;;
    esac
fi

"$project_dir/tools/check_resources.sh" build

if [ ! -x "$lua_prefix/bin/lua" ]; then
    "$project_dir/tools/bootstrap_lua.sh"
fi

mkdir -p "$project_dir/.tools/downloads" "$project_dir/.tools/src"

if [ ! -f "$archive" ]; then
    partial="$archive.part"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --proto '=https' --tlsv1.2 \
            "https://luarocks.github.io/luarocks/releases/luarocks-$version.tar.gz" \
            --output "$partial"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only \
            "https://luarocks.github.io/luarocks/releases/luarocks-$version.tar.gz" \
            -O "$partial"
    else
        echo "wtop: curl or wget is required to download LuaRocks" >&2
        exit 1
    fi
    mv "$partial" "$archive"
fi

echo "$sha256  $archive" | sha256sum -c - >/dev/null

rm -rf "$source_dir"
mkdir -p "$source_dir"
tar -xzf "$archive" -C "$project_dir/.tools/src"

(
    cd "$source_dir"
    ./configure \
        --prefix="$prefix" \
        --with-lua="$lua_prefix" \
        --with-lua-include="$lua_prefix/include" \
        --lua-version=5.5 \
        --force-config >/dev/null
    make build >/dev/null
    make install >/dev/null
)

"$prefix/bin/luarocks" --version >/dev/null
