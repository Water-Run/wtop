#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lua="$project_dir/.tools/lua-5.5.1/bin/lua"
archive="$project_dir/.tools/downloads/luainstaller-1.5.0-1.src.rock"
source_dir="$project_dir/.tools/luainstaller-source-1.5.0"
prefix="$project_dir/.tools/luainstaller-1.5.0"
expected=5d57d07e539107cc13e171e2b0a5919be692898c2627acfda4bcd12694055545

[ -x "$lua" ] || { echo 'wtop: build the Lua 5.5.1 prefix first' >&2; exit 1; }
"$lua" -e 'assert(_VERSION == "Lua 5.5")'
mkdir -p "$project_dir/.tools/downloads"
if [ ! -f "$archive" ]; then
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        https://github.com/Water-Run/luainstaller/releases/download/v1.5.0/luainstaller-1.5.0-1.src.rock \
        --output "$archive.part"
    mv "$archive.part" "$archive"
fi
actual=$(shasum -a 256 "$archive" | awk '{print $1}')
[ "$actual" = "$expected" ] || { echo 'wtop: luainstaller source checksum mismatch' >&2; exit 1; }
if [ ! -d "$source_dir" ]; then
    mkdir -p "$source_dir"
    unzip -q "$archive" -d "$source_dir"
fi
source_root="$source_dir/luainstaller"
if [ ! -d "$prefix" ]; then
    "$lua" "$source_root/tools/install.lua" --prefix "$prefix" --lua "$lua"
fi
# The installed Lua files must still equal the pinned source rock payload.
for source in "$source_root"/src/*.lua "$source_root/luainstaller.lua" \
    "$source_root/bin/luai.lua" "$source_root/bin/luainstaller.lua"; do
    relative=${source#"$source_root/"}
    cmp "$source" "$prefix/$relative" >/dev/null || {
        echo "wtop: installed luainstaller differs from its pinned source: $relative" >&2
        exit 1
    }
done
"$prefix/bin/luai" -v
