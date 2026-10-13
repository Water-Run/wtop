#!/bin/sh
set -eu

[ "$(uname -s)" = Darwin ] || { echo 'wtop: macOS packaging must run on macOS' >&2; exit 1; }
kind=${1:-}
case "$kind" in dir|file) ;; *) echo 'usage: package_macos.sh dir|file' >&2; exit 2 ;; esac
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$(uname -m)" in
    arm64) MACOSX_DEPLOYMENT_TARGET=11.0 ;;
    x86_64) MACOSX_DEPLOYMENT_TARGET=10.13 ;;
    *) echo 'wtop: unsupported macOS architecture' >&2; exit 1 ;;
esac
# Apply the same floor to luainstaller's launcher and embedded interpreter.
# Without this, clang defaults to the build host's macOS release.
export MACOSX_DEPLOYMENT_TARGET
lua_prefix="$project_dir/.tools/lua-5.5.1"
"$project_dir/tools/bootstrap_portable_luainstaller.sh"
output_root="$project_dir/dist/macos-bundle"
mkdir -p "$output_root"
if [ "$kind" = dir ]; then
    output="$output_root/wtop"
    rm -rf "$output"
else
    output="$output_root/wtop-onefile"
fi
set -- "$project_dir/.tools/luainstaller-1.5.0/bin/luai" -b "--$kind" \
    "$project_dir/src/wtop.lua" -o "$output" \
    --lua "$lua_prefix/bin/lua" --lua-prefix "$lua_prefix" \
    --target-os macos --max-deps 300
for locale in "$project_dir"/src/wtop/generated/locales/*.lua; do
    set -- "$@" --include "$locale"
done
LUA_PATH="$project_dir/src/?.lua;$project_dir/src/?/init.lua;;" \
LUA_CPATH="$project_dir/dist/macos/?.so;;" "$@" -- --version
cp "$project_dir/LICENSE" "$output_root/LICENSE"
if [ "$kind" = dir ]; then cp "$project_dir/LICENSE" "$output/LICENSE"; fi
