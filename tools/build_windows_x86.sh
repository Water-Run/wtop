#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=$(printenv WTOP_WINDOWS_CC 2>/dev/null || printf 'i686-w64-mingw32-gcc')
compiler64=$(printenv WTOP_WINDOWS_CC64 2>/dev/null || printf 'x86_64-w64-mingw32-gcc')
source_dir="$project_dir/.tools/src/lua-5.5.1"
work_dir="$project_dir/build/windows-x86"
output_dir="$project_dir/dist/windows-x86"

if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "wtop: 32-bit MinGW compiler is required: $compiler" >&2
    exit 1
fi
if ! command -v "$compiler64" >/dev/null 2>&1; then
    echo "wtop: 64-bit MinGW compiler is required for the isolated CPU reader: $compiler64" >&2
    exit 1
fi
if [ ! -f "$source_dir/src/Makefile" ]; then
    "$project_dir/tools/bootstrap_lua.sh"
fi
if [ ! -f "$work_dir/lua-src/src/Makefile" ]; then
    mkdir -p "$work_dir"
    cp -R "$source_dir" "$work_dir/lua-src"
fi
if [ ! -f "$work_dir/.lua-source-clean" ]; then
    make -C "$work_dir/lua-src/src" clean
    touch "$work_dir/.lua-source-clean"
fi

if [ ! -f "$work_dir/.lua-static-runtime-large-address-aware" ] \
    || [ ! -f "$work_dir/lua-src/src/liblua55.dll.a" ]; then
    make -C "$work_dir/lua-src/src" clean
fi
make -C "$work_dir/lua-src/src" lua.exe "CC=$compiler" \
    "LUA_A=lua55.dll" "LUA_T=lua.exe" \
    "AR=$compiler -shared -static-libgcc -Wl,--out-implib,liblua55.dll.a -o" \
    "RANLIB=i686-w64-mingw32-strip --strip-unneeded" \
    "SYSCFLAGS=-DLUA_BUILD_AS_DLL" "SYSLIBS=" \
    "SYSLDFLAGS=-s -static-libgcc -Wl,--large-address-aware"
# The 32-bit interpreter also runs the packager. Allow its working set to
# exceed 2 GiB on 64-bit build hosts while keeping a PE32/XP runtime.
touch "$work_dir/.lua-static-runtime-large-address-aware"
"$project_dir/tools/write_build_id.sh"
for architecture in x86 x64; do
    worker_compiler="$compiler"
    worker_version=1
    if [ "$architecture" = x64 ]; then worker_compiler="$compiler64"; worker_version=2; fi
    "$worker_compiler" -std=c17 -Os -s -Wall -Wextra -Werror -static-libgcc -municode \
        -Wl,--no-insert-timestamp,--major-os-version,5,--minor-os-version,"$worker_version" \
        -Wl,--major-subsystem-version,5,--minor-subsystem-version,"$worker_version" \
        "$project_dir/native/wtop_cpuid_helper.c" -o "$work_dir/cpuid-$architecture.exe"
done
for architecture in x86 x64; do
    worker_compiler="$compiler"
    worker_version=1
    if [ "$architecture" = x64 ]; then worker_compiler="$compiler64"; worker_version=2; fi
    "$worker_compiler" -std=c17 -Os -s -Wall -Wextra -Werror -static-libgcc -municode -DWTOP_GPU_WORKER \
        -Wl,--no-insert-timestamp,--major-os-version,5,--minor-os-version,"$worker_version" \
        -Wl,--major-subsystem-version,5,--minor-subsystem-version,"$worker_version" \
        "$project_dir/native/wtop_windows_nvml_helper.c" "$project_dir/native/wtop_nvml.c" \
        -o "$work_dir/nvml-$architecture.exe"
done
for architecture in x86 x64; do
    worker_compiler="$compiler"
    worker_version=1
    if [ "$architecture" = x64 ]; then worker_compiler="$compiler64"; worker_version=2; fi
    "$worker_compiler" -std=c17 -Os -s -Wall -Wextra -Werror -static-libgcc -municode -DWTOP_GPU_WORKER -DWTOP_WINDOWS_LEVELZERO \
        -Wl,--no-insert-timestamp,--major-os-version,5,--minor-os-version,"$worker_version" \
        -Wl,--major-subsystem-version,5,--minor-subsystem-version,"$worker_version" \
        "$project_dir/native/wtop_windows_nvml_helper.c" "$project_dir/native/wtop_levelzero.c" \
        -o "$work_dir/levelzero-$architecture.exe"
done
for architecture in x86 x64; do
    worker_compiler="$compiler"
    worker_version=1
    if [ "$architecture" = x64 ]; then worker_compiler="$compiler64"; worker_version=2; fi
    "$worker_compiler" -std=c17 -Os -s -Wall -Wextra -Werror -static-libgcc -municode -DWTOP_GPU_WORKER -DWTOP_WINDOWS_ADL \
        -Wl,--no-insert-timestamp,--major-os-version,5,--minor-os-version,"$worker_version" \
        -Wl,--major-subsystem-version,5,--minor-subsystem-version,"$worker_version" \
        "$project_dir/native/wtop_windows_nvml_helper.c" "$project_dir/native/wtop_windows_adl.c" \
        -o "$work_dir/adl-$architecture.exe"
done
python3 "$project_dir/tools/embed_cpuid_helpers.py" --kind nvml \
    --x86 "$work_dir/nvml-x86.exe" --x64 "$work_dir/nvml-x64.exe" \
    --output "$work_dir/wtop_nvml_helpers.h"
python3 "$project_dir/tools/embed_cpuid_helpers.py" --kind levelzero \
    --x86 "$work_dir/levelzero-x86.exe" --x64 "$work_dir/levelzero-x64.exe" \
    --output "$work_dir/wtop_levelzero_helpers.h"
python3 "$project_dir/tools/embed_cpuid_helpers.py" --kind adl \
    --x86 "$work_dir/adl-x86.exe" --x64 "$work_dir/adl-x64.exe" \
    --output "$work_dir/wtop_adl_helpers.h"
python3 "$project_dir/tools/embed_cpuid_helpers.py" \
    --x86 "$work_dir/cpuid-x86.exe" --x64 "$work_dir/cpuid-x64.exe" \
    --output "$work_dir/wtop_cpuid_helpers.h"
"$compiler" -std=c17 -O2 -Wall -Wextra -Werror -shared -static-libgcc \
    -I"$source_dir/src" -I"$project_dir/build/native" -I"$work_dir" -o "$work_dir/wtop_native.dll" \
    "$project_dir/native/wtop_windows.c" "$project_dir/native/wtop_windows_net.c" \
    "$project_dir/native/wtop_windows_hw.c" "$project_dir/native/wtop_windows_cpu.c" \
    "$project_dir/native/wtop_windows_disk.c" \
    "$project_dir/native/wtop_windows_cpuid.c" "$project_dir/native/wtop_windows_worker.c" \
    "$work_dir/lua-src/src/lua55.dll" -lpsapi -liphlpapi -lsetupapi

rm -rf "$output_dir"
mkdir -p "$output_dir"
cp "$work_dir/lua-src/src/lua.exe" "$output_dir/lua.exe"
cp "$work_dir/lua-src/src/lua55.dll" "$output_dir/lua55.dll"
cp "$work_dir/lua-src/src/liblua55.dll.a" "$output_dir/liblua55.dll.a"
mkdir -p "$output_dir/include"
for header in lua.h luaconf.h lualib.h lauxlib.h; do
    cp "$source_dir/src/$header" "$output_dir/include/$header"
done
cp "$work_dir/wtop_native.dll" "$output_dir/wtop_native.dll"
cp "$project_dir/native/licenses/NVML-NVIDIA.txt" "$output_dir/NVML-NVIDIA.txt"
cp "$project_dir/native/licenses/Level-Zero-MIT.txt" "$output_dir/Level-Zero-MIT.txt"
cp "$project_dir/native/licenses/AMD-ADL-MIT.txt" "$output_dir/AMD-ADL-MIT.txt"
cp -R "$project_dir/src" "$output_dir/"
cat > "$output_dir/wtop.cmd" <<'EOF'
@echo off
setlocal
set "WTOP_ROOT=%~dp0"
set "LUA_PATH=%WTOP_ROOT%src\?.lua;%WTOP_ROOT%src\?\init.lua;;"
set "LUA_CPATH=%WTOP_ROOT%?.dll;;"
"%WTOP_ROOT%lua.exe" "%WTOP_ROOT%src\wtop.lua" %*
exit /b %ERRORLEVEL%
EOF
cat > "$output_dir/wtop.sh" <<'EOF'
#!/bin/sh
# Cygwin/OpenSSH presents native Windows programs with pipes rather than a
# Win32 console. Put its PTY in raw mode while the native program runs.
set -eu
root=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
case "$root" in
    /cygdrive/[A-Za-z]/*)
        drive=${root#/cygdrive/}
        drive_letter=${drive%%/*}
        root_win="$drive_letter:/${drive#*/}"
        ;;
    *) echo "wtop: expected a Cygwin /cygdrive path" >&2; exit 1 ;;
esac
saved=$(stty -g </dev/tty) || exit 1
size=$(stty size </dev/tty) || exit 1
export LINES="${size%% *}" COLUMNS="${size#* }"
restore() { stty "$saved" </dev/tty; }
# A hang-up ends this shell by default; wtop watches the shell's Windows PID
# and exits with it, because the pipe it reads from can outlive the session.
trap restore EXIT INT TERM
if [ -r "/proc/$$/winpid" ]; then
    WTOP_WATCH_PID=$(cat "/proc/$$/winpid")
    export WTOP_WATCH_PID
fi
stty raw -echo </dev/tty
export LUA_PATH="$root_win\\src\\?.lua;$root_win\\src\\?\\init.lua;;"
export LUA_CPATH="$root_win\\?.dll;;"
export WTOP_ANSI_PTY=1
"$root/lua.exe" "$root_win\\src\\wtop.lua" "$@"
EOF
chmod 755 "$output_dir/wtop.sh"
python3 "$project_dir/tools/check_windows_x86.py" --bundle "$output_dir"
echo "wtop: Windows x86 bundle ready: $output_dir"
