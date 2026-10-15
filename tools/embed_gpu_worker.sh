#!/bin/sh
# Embed the standalone GPU reader with POSIX tools, without a second runtime.
set -eu
test "$#" = 2 || test "$#" = 3
image_file=$1
header_file=$2
symbol=${3:-wtop_gpu_worker_image}
case "$symbol" in wtop_gpu_worker_image|wtop_hardware_worker_image) ;; *) exit 2 ;; esac
mkdir -p "$(dirname -- "$header_file")"
header_temp="$header_file.tmp"
trap 'rm -f "$header_temp"' EXIT HUP INT TERM
{
    printf '/* Generated standalone reader. */\n'
    printf 'static const unsigned char %s[] = {\n' "$symbol"
    od -An -v -tu1 "$image_file" | awk '{for(i=1;i<=NF;i++)printf "0x%02x,",$i;printf "\n"}'
    printf '};\n'
} > "$header_temp"
mv "$header_temp" "$header_file"
