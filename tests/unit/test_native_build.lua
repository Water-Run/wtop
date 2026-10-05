package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

-- The native module has to *compile* everywhere wtop claims to run, not only
-- where the developer happens to be.
--
-- Two guarded code paths in wtop_native.c -- pidfd signalling (Linux 5.1 and
-- 5.3) and close_range (Linux 5.9) -- disappear on a toolchain whose kernel
-- headers predate them, and both left something behind that -Werror refuses:
-- a variable assigned before the branch and read only inside it, and a static
-- helper whose only caller was in the guarded block.  On a current
-- development host neither warning can appear, so the module built cleanly
-- here and did not build at all in a glibc 2.17 container.  That is the worst
-- shape a portability bug can have: invisible where you work, fatal where
-- anyone else does.
--
-- These variants are compiled with the macros removed rather than by building
-- in an old container, so the check is local, fast, and runs on every host.

local function read_file(path)
    local handle = assert(io.open(path, "rb"), "cannot read " .. path)
    local body = handle:read("*a")
    handle:close()
    return body
end

local function run(command)
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local _, _, code = pipe:close()
    return output, code
end

local makefile = read_file("Makefile")
local lua_version = assert(makefile:match("LUA_VERSION%s*:=%s*([%d%.]+)"))
local include = "-I.tools/lua-" .. lua_version .. "/include"

-- The project's own warning flags, so a variant that would break `make native`
-- breaks this too.  They are written out rather than parsed out of the
-- Makefile: the two lists can drift, and the honest fix when they do is to
-- notice, not a claim in a comment that they cannot.  -O2 and -g0 are left off
-- because neither affects a diagnostic.
--
-- `-c` rather than `-fsyntax-only`, and that is not a style preference.  The
-- two defects differ in which warning they raise: one is an unused-but-set
-- variable, the other an unused static function.  `-fsyntax-only` emits the
-- first and silently skips the second -- verified with a two-line file, where
-- an unreferenced `static int helper(void)` passes clean under
-- `-fsyntax-only` and fails under `-c`.  A syntax-only guard would therefore
-- have covered half of what it claims to, and passed for a reason unrelated to
-- the half it missed.
local base = ("cc -std=c17 -fPIC -Wall -Wextra -Werror -c -o /dev/null %s "):format(include)

local variants = {
    { name = "as built", shim = nil },
    { name = "without pidfd", shim = "tests/native/no_pidfd.h" },
    { name = "without close_range", shim = "tests/native/no_close_range.h" },
    { name = "without both", shim = "tests/native/no_pidfd_and_close_range.h" },
}

for _, variant in ipairs(variants) do
    assert(read_file(variant.shim or "Makefile") ~= nil,
        "the compile shim " .. tostring(variant.shim) .. " is missing")
    local output, code = run(base
        .. (variant.shim and ("-include " .. variant.shim .. " ") or "")
        .. "native/wtop_native.c")
    assert(code == 0,
        "the native module does not compile " .. variant.name .. ":\n" .. output)
end

-- The shims have to actually remove something, or the four variants above are
-- the same compile four times and the guard is decorative.  A shim that failed
-- to undef its macros -- a wrong header name, a macro the host does not define
-- -- would leave the guarded branch compiled and every assertion above would
-- still pass, which is the failure mode this project has walked into repeatedly.
--
-- Directive positions are read line by line and anchored to the start of a
-- line, because a substring search finds the words inside the shim's own
-- explanatory comment.  The first draft of this check did exactly that and
-- failed on its own prose before it ever compiled anything: the comment
-- explains that "#undef below survives", and that sentence sits above the
-- `#include`, so the search concluded the header came second.
local function directive_line(body, prefix)
    local index = 0
    for line in body:gmatch("[^\n]+") do
        index = index + 1
        if line:sub(1, #prefix) == prefix then return index, line end
    end
    return nil, nil
end

for _, entry in ipairs({
    { shim = "tests/native/no_pidfd.h", macros = { "SYS_pidfd_open", "SYS_pidfd_send_signal" } },
    { shim = "tests/native/no_close_range.h", macros = { "SYS_close_range" } },
    {
        shim = "tests/native/no_pidfd_and_close_range.h",
        macros = { "SYS_pidfd_open", "SYS_pidfd_send_signal", "SYS_close_range" },
    },
}) do
    local body = read_file(entry.shim)
    local include_at, include_line = directive_line(body, "#include")
    local undef_at = directive_line(body, "#undef")
    assert(include_line ~= nil and include_line:find("<sys/syscall.h>", 1, true) ~= nil,
        entry.shim .. " must include <sys/syscall.h> as a directive, not in prose")
    assert(undef_at ~= nil,
        entry.shim .. " must undefine a syscall number as a directive")
    -- Line numbers, not substring offsets: the shim's own comment mentions both
    -- directives in prose, and a raw `find` would locate that sentence instead
    -- of the preprocessor line.  The include has to precede the undef, or the
    -- module's own <sys/syscall.h> re-defines what the shim removed.
    assert(include_at < undef_at,
        entry.shim .. " must include <sys/syscall.h> before undefining, or the "
            .. "module's own include makes both no-ops and the guarded branch "
            .. "is never exercised")
    for _, macro in ipairs(entry.macros) do
        assert(body:find("#undef " .. macro, 1, true) ~= nil,
            entry.shim .. " does not undefine " .. macro)
    end
end

-- And the module must actually be guarded: a future edit that drops the #if
-- would make every variant compile identically and pass again.
local native_source = read_file("native/wtop_native.c")
assert(native_source:find("#if defined(SYS_pidfd_open) && defined(SYS_pidfd_send_signal)", 1, true)
    or native_source:find("#if defined(SYS_pidfd_open) and defined(SYS_pidfd_send_signal)", 1, true),
    "the pidfd path is no longer guarded by its two syscall numbers")
assert(native_source:find("#ifdef SYS_close_range", 1, true) ~= nil,
    "the close_range speed-up is no longer guarded by its syscall number")

-- The feature macros are the one thing the four compiles above cannot check,
-- and the reason is worth stating rather than leaving as an apparent gap.  The
-- combination this file used to carry -- _DEFAULT_SOURCE beside
-- _POSIX_C_SOURCE and _XOPEN_SOURCE -- is a no-op on glibc older than 2.19,
-- which is what broke the build in the glibc 2.17 container.  On a current
-- host that same combination compiles clean, verified here, so no shim or
-- compiler flag can reproduce the failure locally: reproducing it would mean
-- reimplementing another C library's features.h, and a simulation that agreed
-- with reality only on this machine would be worse than no check.
--
-- What can be checked is that the arrangement which does work across the range
-- is still in place, because each of its five macros is load-bearing on some
-- glibc and dropping any one of them looks harmless on the machine you are on.
-- _DEFAULT_SOURCE is the 2.19+ spelling, _BSD_SOURCE and _SVID_SOURCE are the
-- 2.17 spelling that 2.20 deprecated, and _POSIX_C_SOURCE with _XOPEN_SOURCE
-- 700 is what declares wcwidth.  The set is also what keeps the module off
-- _GNU_SOURCE, which is not a neutral choice: under _GNU_SOURCE a glibc of
-- 2.38 or newer redirects strtol and strtoull to __isoc23_strtol and
-- __isoc23_strtoull, and the module's measured floor rises from GLIBC_2.34 to
-- GLIBC_2.38.  That is invisible to a compile check, because it compiles
-- cleanly either way; it is visible in the baseline report, and
-- tests/unit/test_native_baseline.lua is where the number is checked.
--
-- These are source assertions, not compiles, and they are the whole extent of
-- what this file can promise about the macros; tools/cross_libc_build.sh is
-- what actually proves the build on an older libc.
for _, macro in ipairs({ "_DEFAULT_SOURCE", "_BSD_SOURCE", "_SVID_SOURCE",
    "_POSIX_C_SOURCE", "_XOPEN_SOURCE" }) do
    assert(native_source:find("#define " .. macro, 1, true) ~= nil,
        "the feature macros must keep " .. macro .. ": each one is load-bearing on "
            .. "some glibc in the supported range, and on any one host the others "
            .. "make its absence invisible")
end
assert(not native_source:find("#define _GNU_SOURCE", 1, true),
    "_GNU_SOURCE compiles everywhere but raises the module's glibc floor from "
        .. "2.34 to 2.38 on glibc 2.38 and newer, because it turns on the C23 "
        .. "strtol redirection; the five-macro set above covers the same ground")

return true
