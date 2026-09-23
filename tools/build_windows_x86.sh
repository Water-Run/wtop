#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=$(printenv WTOP_WINDOWS_CC 2>/dev/null || printf 'i686-w64-mingw32-gcc')
source_dir="$project_dir/.tools/src/lua-5.5.1"
work_dir="$project_dir/build/windows-x86"
output_dir="$project_dir/dist/windows-x86"

if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "wtop: 32-bit MinGW compiler is required: $compiler" >&2
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

make -C "$work_dir/lua-src/src" mingw "CC=$compiler"
"$compiler" -std=c17 -O2 -Wall -Wextra -Werror -shared \
    -I"$source_dir/src" -o "$work_dir/wtop_native.dll" \
    "$project_dir/native/wtop_windows.c" "$project_dir/native/wtop_windows_net.c" \
    "$work_dir/lua-src/src/lua55.dll" -lpsapi -liphlpapi

rm -rf "$output_dir"
mkdir -p "$output_dir"
cp "$work_dir/lua-src/src/lua.exe" "$output_dir/lua.exe"
cp "$work_dir/lua-src/src/lua55.dll" "$output_dir/lua55.dll"
cp "$work_dir/wtop_native.dll" "$output_dir/wtop_native.dll"
runtime_dll=$("$compiler" -print-sysroot)/mingw/bin/libgcc_s_dw2-1.dll
if [ ! -f "$runtime_dll" ]; then
    echo "wtop: MinGW runtime DLL is missing: $runtime_dll" >&2
    exit 1
fi
cp "$runtime_dll" "$output_dir/libgcc_s_dw2-1.dll"
thread_dll=$("$compiler" -print-sysroot)/mingw/bin/libwinpthread-1.dll
if [ ! -f "$thread_dll" ]; then
    echo "wtop: MinGW thread runtime DLL is missing: $thread_dll" >&2
    exit 1
fi
cp "$thread_dll" "$output_dir/libwinpthread-1.dll"
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
trap restore EXIT HUP INT TERM
stty raw -echo </dev/tty
export LUA_PATH="$root_win\\src\\?.lua;$root_win\\src\\?\\init.lua;;"
export LUA_CPATH="$root_win\\?.dll;;"
export WTOP_ANSI_PTY=1
"$root/lua.exe" "$root_win\\src\\wtop.lua" "$@"
EOF
chmod 755 "$output_dir/wtop.sh"
echo "wtop: Windows x86 bundle ready: $output_dir"
