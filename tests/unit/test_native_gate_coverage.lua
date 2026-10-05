package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;;" .. package.path

-- Two CI gates named the native module and rebuilt it from a copy of its
-- source list that was shorter than the real one.
--
-- The stricter-dialect job compiled native/wtop_native.c and native/wtop_nvml.c
-- and wrote them to /dev/null.  The ASan/UBSan job compiled the same two and
-- loaded the result.  NATIVE_SOURCES has four.  The two that were left out are
-- wtop_amdsmi.c and wtop_levelzero.c -- the vendor backends, which reach AMD
-- SMI and Level Zero through dlopen and dlsym rather than at link time, and so
-- are the part of this module most able to get a pointer wrong.  The only job
-- in the workflow that checks for memory errors never loaded them.
--
-- Nothing was being worked around: all four compile clean under the stricter
-- dialect and all four instrument clean under ASan+UBSan, both measured before
-- the fix.  The gates were simply narrower than their names, and a gate that is
-- narrower than its name fails silently for as long as the uncovered code
-- happens to be clean.
--
-- The root cause is the one increment 31 named for a different list: a second
-- copy of a fact the Makefile already holds.  The ELF list moved into the
-- baseline target and BASELINE_OUTPUT replaced a re-derived path list in two CI
-- steps; the C source list had not moved.  So the source list is now only in
-- NATIVE_SOURCES, both gates are Makefile targets, and the strongest clause
-- here is the first one: the workflow may not name a C source file at all.
-- That makes the copy impossible to reintroduce rather than fixing today's copy.

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
local workflow = read_file(".github/workflows/ci.yml")

-- Comments are stripped before anything is searched.  Two of the three places
-- the workflow still says "native/wtop_nvml.c" are the comments recording what
-- this change was, and a guard that fails on its own explanation is a guard
-- that gets deleted.  The same stripping is how test_release_evidence.lua
-- checks that no CI step calls an evidence tool directly.
local uncommented = ""
for line in workflow:gmatch("[^\n]+") do
    uncommented = uncommented .. line:gsub("%s*#.*$", "") .. "\n"
end

-- One job's steps, so a rule about the sanitizers job is not applied to the
-- flaky job, which legitimately points LUA_CPATH at the ordinary module.
-- Comments are stripped here for the same reason as above: the explanation of
-- what moved says the names of the things that moved.
local function job_block(name)
    local block, collecting = {}, false
    for line in workflow:gmatch("[^\n]+") do
        if line:match("^  " .. name .. ":") then
            collecting = true
        elseif collecting and line:match("^  %S") then
            break
        elseif collecting then
            block[#block + 1] = (line:gsub("%s*#.*$", ""))
        end
    end
    return table.concat(block, "\n")
end

-- NATIVE_SOURCES as make reads it, continuation lines included.  Reading the
-- Makefile rather than the expansion keeps this half independent of the gates
-- being checked; the expansion is what the next half compares against.
local Makefile = require("support.makefile")

local sources = {}
-- The list, as make reads it, continuation lines joined.
for name in Makefile.variable_of(makefile, "NATIVE_SOURCES"):gmatch("(native/%S+%.c)") do
  sources[name] = true
end
local declared = {}
for name in pairs(sources) do declared[#declared + 1] = name end
table.sort(declared)
assert(#declared >= 4,
    "NATIVE_SOURCES resolved to " .. #declared .. " file(s); the module is "
        .. "built from more than that, so the list this file compares against "
        .. "is itself truncated")

-- ---------------------------------------------------------------------------
-- 1. The workflow holds no C source list.

for name in pairs(sources) do
    assert(not uncommented:find(name, 1, true),
        ".github/workflows/ci.yml names " .. name .. " directly.  A gate that "
            .. "compiles a copy of the module's source list is a gate that "
            .. "covers only the files somebody remembered to write down, and "
            .. "this one had been covering two of four for as long as the two "
            .. "omitted files stayed clean.")
end
-- The general form, so the rule survives the next translation unit being
-- added: the workflow compiles no C source file at all.  A blanket "native/"
-- check would be wrong -- build/native/ is where the module lives and several
-- jobs legitimately point at it -- so the rule is about sources, which is what
-- was actually being duplicated.
assert(not uncommented:find("%.c[%s'\"\\]", 1, true),
    ".github/workflows/ci.yml names a C source file.  Everything the native "
        .. "module is built from belongs to NATIVE_SOURCES; a path into "
        .. "native/ is where a re-derived file list starts.")
assert(not uncommented:find("native/%S+%.c", 1, true),
    ".github/workflows/ci.yml reaches into the native/ source directory.")

-- ---------------------------------------------------------------------------
-- 2. Both gates are Makefile targets, so the list they compile is the list the
--    module is built from.  The check is on the *expansion*, not on the recipe
--    text: a target that hardcodes two file names still names NATIVE_SOURCES
--    somewhere in a comment, and only what make actually runs says what was
--    compiled.

local function expansion_of(target)
    local output, code = run("make -n " .. target)
    assert(code == 0, "make -n " .. target .. " failed, so nothing below was "
        .. "checked against a real expansion:\n" .. output)
    return output
end

for _, target in ipairs({ "check-native-warnings", "sanitize-native" }) do
    local expanded = expansion_of(target)
    for _, name in ipairs(declared) do
        assert(expanded:find(name, 1, true) ~= nil,
            "`make " .. target .. "` does not compile " .. name .. ".  This is "
                .. "the defect itself: the gate covers part of the module and "
                .. "its name does not say so.\n" .. expanded)
    end
end

-- The stricter gate has to actually be stricter.  A target that compiles the
-- same flags as the ordinary build would satisfy the clause above and check
-- nothing extra, and the flags are the gate.
local strict = expansion_of("check-native-warnings")
for _, flag in ipairs({ "-Werror", "-Wshadow", "-Wconversion", "-Wsign-conversion",
                        "-Wpointer-arith" }) do
    assert(strict:find(flag, 1, true) ~= nil,
        "`make check-native-warnings` does not pass " .. flag .. ", so the gate "
            .. "is not stricter than the ordinary build:\n" .. strict)
end

-- The sanitizer gate has to actually sanitize, and it must not write over the
-- ordinary module.  A sanitized module left at $(NATIVE_MODULE) would be newer
-- than its own prerequisites, so the next `make native` would decline to
-- rebuild it and every later suite would run against an instrumented build it
-- did not ask for.
local sanitized = expansion_of("sanitize-native")
assert(sanitized:find("-fsanitize=address,undefined", 1, true) ~= nil,
    "`make sanitize-native` does not enable the sanitizers:\n" .. sanitized)
assert(sanitized:find("build/native/wtop_native.so", 1, true) == nil,
    "`make sanitize-native` writes over the ordinary module, so the next "
        .. "`make native` would not rebuild it and the rest of the suite would "
        .. "load an instrumented build:\n" .. sanitized)
assert(sanitized:find("build/native-san/", 1, true) ~= nil,
    "`make sanitize-native` does not say where it put the instrumented module, "
        .. "and the run that loads it has to name the same path:\n" .. sanitized)

-- ---------------------------------------------------------------------------
-- 3. The workflow reaches both targets, and holds the sanitizer policy nowhere.

assert(workflow:find("make check-native-warnings", 1, true) ~= nil,
    ".github/workflows/ci.yml no longer runs `make check-native-warnings`")
assert(workflow:find("make test-sanitized", 1, true) ~= nil,
    ".github/workflows/ci.yml no longer runs `make test-sanitized`")

-- These three are scoped to the sanitizers job.  The flaky job sets LUA_CPATH
-- against the ordinary module and is entitled to; what is not acceptable is a
-- sanitizer run that decides for itself which module it is loading, because
-- that is how the job came to load whatever the previous step happened to
-- write.
local sanitizers = job_block("sanitizers")
assert(sanitizers ~= "" and sanitizers:find("make test-sanitized", 1, true) ~= nil,
    "the sanitizers job no longer calls `make test-sanitized`")
assert(not sanitizers:find("ASAN_OPTIONS", 1, true),
    "the sanitizers job sets ASAN_OPTIONS itself.  The sanitizer policy is a "
        .. "decision about this project -- why leak detection is off and why "
        .. "both sanitizers halt on the first error -- and it belongs with the "
        .. "build it configures, not in the job that happens to run it.")
assert(not sanitizers:find("LUA_CPATH", 1, true),
    "the sanitizers job sets LUA_CPATH itself, which is how it came to load "
        .. "whatever module the step before it happened to write.  The target "
        .. "owns the path.")
assert(not sanitizers:find("%.c[%s'\"]", 1, true),
    "the sanitizers job names a C source file")

-- The three CLI invocations drove real collection through the instrumented
-- module and are not covered by the unit suite.  They moved into the target
-- when the step did; dropping them would have been a quiet loss of coverage in
-- a job whose whole purpose is coverage.
local sanitized_run = expansion_of("test-sanitized")
for _, mode in ipairs({ "--snapshot", "--agent", "--diagnose" }) do
    assert(sanitized_run:find(mode, 1, true) ~= nil,
        "`make test-sanitized` no longer runs " .. mode .. " against the "
            .. "instrumented module.  Those three drove the real collection "
            .. "paths end to end and the unit suite reaches only part of what "
            .. "they touch:\n" .. sanitized_run)
end

-- And the exclusion is a named decision, not a silent narrowing.
assert(sanitized_run:find("test_benchmark_record", 1, true) == nil,
    "test_benchmark_record.lua is back in the sanitized run.  It asserts on a "
        .. "three-second first-frame window, which under ASan+UBSan is the one "
        .. "place in that run where a pass would depend on the sanitizer's "
        .. "overhead rather than on the code -- and the development host cannot "
        .. "run the target at all, so a flake would first appear in CI.")
assert(makefile:find("SANITIZER_EXCLUDED", 1, true) ~= nil,
    "the sanitized run no longer names what it excludes, so a reader cannot "
        .. "tell the difference between a deliberate exclusion and a shorter "
        .. "list")

return true
