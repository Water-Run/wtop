#!/bin/sh
# POSIX build tools only: LuaRocks builds do not require Python or a second Lua.
set -eu
test "$#" = 2
image_file=$1
header_file=$2
mkdir -p "$(dirname -- "$header_file")"
header_temp="$header_file.tmp"
trap 'rm -f "$header_temp"' EXIT HUP INT TERM
{
    printf '/* Generated standalone NVML reader. */\n'
    printf 'static const unsigned char wtop_nvml_worker_image[] = {\n'
    od -An -v -tu1 "$image_file" | awk '{for(i=1;i<=NF;i++)printf "0x%02x,",$i;printf "\n"}'
    printf '};\n'
} > "$header_temp"
mv "$header_temp" "$header_file"
