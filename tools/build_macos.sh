#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
    echo "wtop: macOS build must run on macOS" >&2
    exit 1
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
archive="$project_dir/.tools/downloads/lua-5.5.1.tar.gz"
work_dir="$project_dir/build/macos"
output_dir="$project_dir/dist/macos"
expected=1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce
case "$(uname -m)" in
    arm64) deployment=11.0 ;;
    x86_64) deployment=10.13 ;;
    *) echo "wtop: unsupported macOS architecture" >&2; exit 1 ;;
esac

mkdir -p "$project_dir/.tools/downloads" "$work_dir"
if [ ! -f "$archive" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 \
        https://www.lua.org/ftp/lua-5.5.1.tar.gz -o "$archive.part"
    mv "$archive.part" "$archive"
fi
actual=$(shasum -a 256 "$archive" | awk '{print $1}')
if [ "$actual" != "$expected" ]; then
    echo "wtop: Lua archive checksum mismatch" >&2
    exit 1
fi
if [ ! -f "$work_dir/lua-5.5.1/src/Makefile" ]; then
    tar -xzf "$archive" -C "$work_dir"
fi

if [ ! -f "$work_dir/.deployment-$deployment" ]; then
    make -C "$work_dir/lua-5.5.1/src" clean
    rm -f "$work_dir"/.deployment-*
    touch "$work_dir/.deployment-$deployment"
fi
make -C "$work_dir/lua-5.5.1/src" macosx \
    "MYCFLAGS=-mmacosx-version-min=$deployment" \
    "MYLDFLAGS=-mmacosx-version-min=$deployment"
rm -rf "$output_dir"
mkdir -p "$output_dir"
cc -std=c17 -O2 -Wall -Wextra -Werror \
    "-mmacosx-version-min=$deployment" -dynamiclib -undefined dynamic_lookup \
    -I"$work_dir/lua-5.5.1/src" \
    -o "$output_dir/wtop_native.so" "$project_dir/native/wtop_macos.c" \
    -framework IOKit -framework CoreFoundation
cp "$work_dir/lua-5.5.1/src/lua" "$output_dir/lua"
cp -R "$project_dir/src" "$output_dir/"
cat > "$output_dir/wtop" <<'EOF'
#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LUA_PATH="$root/src/?.lua;$root/src/?/init.lua;;"
export LUA_CPATH="$root/?.so;;"
exec "$root/lua" "$root/src/wtop.lua" "$@"
EOF
chmod 755 "$output_dir/wtop" "$output_dir/lua"
echo "wtop: macOS bundle ready: $output_dir"
