#!/bin/sh
set -eu

host_os=$(uname -s 2>/dev/null || true)
if [ "$host_os" != "Linux" ]; then
    echo "wtop: Linux is required (detected ${host_os:-unknown})" >&2
    exit 1
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lua_prefix="$project_dir/.tools/lua-5.5.1"
rock_tree="$project_dir/.tools/rocks-5.5"
luai="$rock_tree/bin/luai"
luainstaller_version=1.5.0-1
installed_rockspec="$rock_tree/lib/luarocks/rocks-5.5/luainstaller/$luainstaller_version/luainstaller-$luainstaller_version.rockspec"
lock_file="$project_dir/tools/luainstaller-1.5.0.sha256"
# Pin the official source rock as well as the installed payload. This release
# is available directly even before the LuaRocks index has picked it up.
source_sha256=5d57d07e539107cc13e171e2b0a5919be692898c2627acfda4bcd12694055545
source_rock="$project_dir/.tools/downloads/luainstaller-$luainstaller_version.src.rock"
local_rockspec=${WTOP_LUAINSTALLER_ROCKSPEC:-}

if [ -z "$local_rockspec" ] && [ -x "$luai" ] && [ -f "$installed_rockspec" ] \
        && grep -Fxq "version = \"$luainstaller_version\"" "$installed_rockspec" \
        && (cd "$rock_tree" && sha256sum -c "$lock_file" >/dev/null 2>&1) \
        && "$luai" -h >/dev/null 2>&1; then
    exit 0
fi

"$project_dir/tools/check_resources.sh" build

if [ ! -x "$lua_prefix/bin/lua" ]; then
    "$project_dir/tools/bootstrap_lua.sh"
fi

# The distribution LuaRocks cannot target Lua 5.5, so use the pinned build.
luarocks="$project_dir/.tools/luarocks/bin/luarocks"
if [ ! -x "$luarocks" ]; then
    "$project_dir/tools/bootstrap_luarocks.sh"
fi

if [ -n "$local_rockspec" ]; then
    case "$local_rockspec" in
        /*) ;;
        *)
            echo "wtop: WTOP_LUAINSTALLER_ROCKSPEC must be an absolute path" >&2
            exit 1
            ;;
    esac
    if [ ! -f "$local_rockspec" ]; then
        echo "wtop: requested luainstaller rockspec does not exist: $local_rockspec" >&2
        exit 1
    fi
    if ! grep -Fxq "version = \"$luainstaller_version\"" "$local_rockspec"; then
        echo "wtop: local luainstaller rockspec must declare version $luainstaller_version" >&2
        exit 1
    fi
    rock_dir=$(dirname -- "$local_rockspec")
    rock_file=$(basename -- "$local_rockspec")
    (
        cd "$rock_dir"
        "$luarocks" --lua-version=5.5 --lua-dir="$lua_prefix" --tree="$rock_tree" \
            make "$rock_file" --deps-mode=none
    )
else
    mkdir -p "$project_dir/.tools/downloads"
    if [ ! -f "$source_rock" ]; then
        partial="$source_rock.part"
        trap 'rm -f "$partial"' EXIT HUP INT TERM
        source_url="https://github.com/Water-Run/luainstaller/releases/download/v1.5.0/luainstaller-$luainstaller_version.src.rock"
        if command -v curl >/dev/null 2>&1; then
            curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
                "$source_url" --output "$partial"
        elif command -v wget >/dev/null 2>&1; then
            wget --https-only "$source_url" -O "$partial"
        else
            echo "wtop: curl or wget is required to download luainstaller" >&2
            exit 1
        fi
        printf '%s  %s\n' "$source_sha256" "$partial" | sha256sum -c - >/dev/null
        mv "$partial" "$source_rock"
        trap - EXIT HUP INT TERM
    fi
    printf '%s  %s\n' "$source_sha256" "$source_rock" | sha256sum -c - >/dev/null
    "$luarocks" --lua-version=5.5 --lua-dir="$lua_prefix" --tree="$rock_tree" \
        install "$source_rock" --deps-mode=none --force
    if ! (cd "$rock_tree" && sha256sum -c "$lock_file" >/dev/null); then
        echo "wtop: installed luainstaller does not match the pinned 1.5.0 payload" >&2
        exit 1
    fi
fi
