package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

-- The glibc floor of a wtop release is a property of the machine that built it,
-- so it has to be measured off the shipped files and compared against a single
-- declared promise -- and the two must not be able to drift apart quietly.
--
-- This started as a defect rather than a test.  tools/record_baseline.sh named
-- one file, the native module, and printed its highest required symbol version
-- as *the* floor.  The module tops out at GLIBC_2.34; the PUC Lua 5.5.1
-- interpreter that luainstaller embeds asks for GLIBC_2.38 through `fmod`.
-- Measuring the module alone therefore understated what a user has to have
-- installed, and it did so silently, in the file whose entire job is release
-- evidence.  Everything below exists so that "the report says one number" and
-- "that number is what the bundle actually needs" cannot come apart.

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

-- glibc's ABI versions are dotted numbers that a lexicographic sort gets
-- backwards: it calls 2.9 newer than 2.17, and both spellings occur in every
-- release of a real toolchain.  Comparing field by field is the only correct
-- way to ask whether an artifact overran the promise.
local function version_gt(a, b)
    local av, bv = {}, {}
    for field in a:gmatch("[^.]+") do av[#av + 1] = tonumber(field) end
    for field in b:gmatch("[^.]+") do bv[#bv + 1] = tonumber(field) end
    assert(#av > 0 and #bv > 0, "a version to compare must have a numeric field")
    for index = 1, math.max(#av, #bv) do
        local x, y = av[index] or 0, bv[index] or 0
        if x ~= y then return x > y end
    end
    return false
end

assert(version_gt("2.38", "2.17") and version_gt("2.17", "2.9")
    and version_gt("2.34", "2.33") and not version_gt("2.17", "2.17")
    and not version_gt("2.17.0", "2.17") and version_gt("3.0", "2.99"),
    "the version comparison this gate depends on is itself wrong")

-- ---------------------------------------------------------------------------
-- 1. The declared floor: one place, well formed, and quoted in the document a
--    packager will actually read.

local conf = read_file("tools/baseline.conf")
local declared
for line in conf:gmatch("[^\n]+") do
    local value = line:match("^GLIBC_FLOOR=([0-9][0-9%.]*)%s*$")
    if value then
        assert(declared == nil,
            "GLIBC_FLOOR is declared more than once in tools/baseline.conf")
        declared = value
    end
end
assert(declared, "tools/baseline.conf must declare a GLIBC_FLOOR assignment")
assert(not declared:match("%.$") and not declared:match("%.%."),
    "the declared floor must not have an empty component: " .. declared)
assert(not version_gt(declared, declared), "the declared floor must compare equal to itself")

-- ---------------------------------------------------------------------------
-- 2. Every ELF handed to the script is measured, and the floor it reports is
--    the highest of them -- not the first, not the last, not the lowest.

-- Derived from the Makefile rather than from a `ls` glob.  The first version
-- of this test shelled out to `ls -d .tools/lua-*/bin/lua` and matched the
-- first line of the result -- but `run` merges stderr into stdout, so when the
-- glob matched nothing the *error message* became the match, the script was
-- handed a diagnostic string as a file path, and the gate failed for a reason
-- that had nothing to do with the gate.  Reading the one place the version is
-- written removes the shell, the glob, and the way to confuse the two.
local makefile = read_file("Makefile")
local lua_version = assert(makefile:match("LUA_VERSION%s*:=%s*([%d%.]+)"),
    "the Makefile no longer declares LUA_VERSION, so the interpreter path is unknown")
local interpreter = ".tools/lua-" .. lua_version .. "/bin/lua"
local interpreter_handle = io.open(interpreter, "rb")
assert(interpreter_handle,
    "the packaged Lua interpreter " .. interpreter .. " is missing; run `make toolchain`")
interpreter_handle:close()
local native_module = "build/native/wtop_native.so"

local report, status = run(
    "sh tools/record_baseline.sh " .. native_module .. " " .. interpreter)
assert(status == 0,
    "the baseline gate rejected the artifacts it was just built from:\n" .. report)

local quoted = function(path) return (path:gsub("(%W)", "%%%1")) end
-- The report's wording is part of what is under test here, not an incidental
-- detail: the claim is that this file says the right number for each artifact
-- it was given, which cannot be checked without reading the file. The coupling
-- is deliberate, and when tools/elf_floors.py is reworded this test is expected
-- to fail so that the change is a decision rather than a drift.
local REPORTED = "highest required overall"
for _, module in ipairs({ native_module, interpreter }) do
    local section = report:match("== " .. quoted(module) .. "\n(.-)\n\n")
    assert(section, "the report has no section for " .. module .. ":\n" .. report)
    assert(section:find(REPORTED .. ": (%d[%.%d]*)") ~= nil,
        "the report does not state a highest required version for " .. module)
end

-- ---------------------------------------------------------------------------
-- 3. The script's own arithmetic, checked against an independent reading of
--    the same files.  A release gate that is only ever checked by itself is an
--    assertion that cannot fail, which is the failure mode this project has
--    already walked into six times.

local function highest_required(path)
    local output = run("objdump -T " .. path .. " | grep -o 'GLIBC_[0-9][0-9.]*'")
    local highest
    for version in output:gmatch("GLIBC_([%d][%d%.]*)") do
        if not highest or version_gt(version, highest) then highest = version end
    end
    return highest
end

local combined = assert(report:match("combined glibc floor: (%d[%.%d]*)"),
    "the report does not state a combined floor:\n" .. report)
local expected_combined
local module_floor, interpreter_floor
for _, module in ipairs({ native_module, interpreter }) do
    local expected = assert(highest_required(module),
        "objdump reported no versioned glibc symbol in " .. module)
    local claimed = report:match("== " .. quoted(module)
        .. "\n.-" .. REPORTED .. ": (%d[%.%d]*)")
    assert(claimed == expected, "the report says " .. tostring(claimed)
        .. " for " .. module .. " but objdump says " .. expected)
    if module == native_module then
        module_floor = expected
    else
        interpreter_floor = expected
    end
    if not expected_combined or version_gt(expected, expected_combined) then
        expected_combined = expected
    end
end
assert(combined == expected_combined,
    "the combined floor is " .. combined .. " but the highest single requirement is "
        .. expected_combined .. " -- a bundle runs every file it ships")

-- The two artifacts are not peers.  The interpreter is a fixed input at a
-- pinned version; the native module is ours, and its requirement is whatever
-- the compiler and the libc headers we build against happen to ask for.  So on
-- the packaging host the module may never be the one that sets the floor, and
-- it does not at present.
--
-- "On the packaging host" is doing real work and is not a way of dodging the
-- check.  The arrangement is a property of the build host, not of the source:
-- the same module needs GLIBC_2.34 where the interpreter needs 2.38, and needs
-- GLIBC_2.17 where the interpreter built in that same container needs 2.14.  The
-- two swap places, and in the older-libc case the module genuinely does set the
-- floor, which is correct for a build intended to run on that libc.  Asserting
-- the comparison everywhere made the cross-libc run fail on a host where the
-- packaging host's arrangement is deliberately not the case.
--
-- So the invariant is asserted where it is a claim about this project, and
-- skipped with the reason stated where it is not.  The packaging host is the
-- one whose interpreter is the file the release promise is written against, so
-- that is what identifies it.  What is *not* given up on other hosts: the C23
-- scan below, which names the cause of the regression and is evaluated
-- everywhere, and the combined-floor comparison above.
local on_packaging_host = interpreter_floor == declared
if on_packaging_host then
    assert(not version_gt(module_floor, interpreter_floor),
        "the native module requires glibc " .. module_floor .. " but the pinned Lua "
            .. "interpreter only requires " .. interpreter_floor .. "; the module is the "
            .. "side of this pair the project controls, and on the packaging host it "
            .. "must not be the one that raises the floor")
else
    -- Not a silent skip: the reason travels with the fact, so a reader of the
    -- run knows this check did not apply rather than assuming it passed.
    print(string.format(
        "-- packaging-host floor arrangement not applicable here: the interpreter "
        .. "needs %s and the promised floor is %s, so this host is not the one that "
        .. "ships. The module needs %s on this host and does set the floor, which is "
        .. "correct for a build meant to run on this libc.",
        interpreter_floor, declared, module_floor))
end

-- The comparison above is not enough on its own, and saying why matters: the
-- regression it describes ended with the module *equal* to the interpreter at
-- 2.38, not above it, because the interpreter had been there all along.  So the
-- invariant above catches a module that overshoots and stays silent about one
-- that merely climbs to meet it.  The cause is nameable, so it is asserted
-- directly: a glibc of 2.38 or newer redirects the strtol family to its C23
-- spellings whenever _GNU_SOURCE is defined, and each of those names is a
-- GLIBC_2.38 requirement the module did not have before.
--
-- This is vacuous on a host whose glibc predates 2.38, because there the
-- redirection cannot happen at all.  That is not a gap being papered over: on
-- such a host tests/unit/test_native_build.lua still pins the feature macros,
-- which is the part that decides this on every machine.
local c23 = run("readelf --dyn-syms -W " .. native_module
    .. " 2>/dev/null | grep -o '__isoc23_[a-z]*' | sort -u")
local c23_symbols = {}
for name in c23:gmatch("__isoc23_%a+") do c23_symbols[#c23_symbols + 1] = name end
table.sort(c23_symbols)
assert(#c23_symbols == 0,
    "the native module references the C23 strtol family ("
        .. table.concat(c23_symbols, ", ") .. "), which only happens when "
        .. "_GNU_SOURCE is defined and only costs a glibc version from 2.38 on")

-- The measured floor is the promise made concrete, so the two must agree.
assert(not version_gt(combined, declared),
    "the artifacts require glibc " .. combined .. " but tools/baseline.conf promises "
        .. declared .. "; the gate would reject this release")

-- ---------------------------------------------------------------------------
-- 4. A file that was named but not produced is an error, not a smaller number.
--    This is the same class of defect as measuring one file of two: a report
--    that quietly measures less than it claims to is worse than no report.

local _, missing_status = run(
    "sh tools/record_baseline.sh " .. native_module .. " build/native/absent.so")
assert(missing_status ~= 0,
    "naming an ELF that does not exist must fail the gate, not shorten the report")

-- ---------------------------------------------------------------------------
-- 4b. A file that cannot be measured is the same defect wearing a different
--     hat, and the earlier form of it is the one this project keeps meeting.
--     A named-but-absent file exits non-zero.  An unmeasurable one also exited
--     non-zero -- and the report still went on to say "status: within the
--     promised floor", because an unmeasurable file contributed zero, zero is
--     below every promised floor, and the comparison the verdict is built from
--     cannot tell a requirement of zero from the absence of a measurement.  So
--     the document certified a release on evidence that was not collected while
--     the exit status said the opposite.  Exit codes are read by CI; the report
--     is read by whoever signs the release, and only the report asserted
--     anything.
--
--     Both halves are asserted: the gate must fail, and the document must not
--     contain a verdict.  A test that only checked the exit code would pass
--     against the broken version, which is why it is written this way.

local not_an_elf = (os.getenv("TMPDIR") or "/tmp") .. "/wtop-not-an-elf.bin"
local junk = assert(io.open(not_an_elf, "wb"))
junk:write("this is not an ELF image, it is 64 bytes of nothing much\n")
junk:close()

local unmeasurable_report, unmeasurable_status = run(
    "sh tools/record_baseline.sh " .. native_module .. " " .. not_an_elf)
os.remove(not_an_elf)
assert(unmeasurable_status ~= 0,
    "naming an ELF that cannot be measured must fail the gate")
assert(unmeasurable_report:find("status: within the promised floor", 1, true) == nil,
    "the report certifies a release it could not measure.  One of the two files "
        .. "named produced no glibc symbols, so the floor is undetermined rather "
        .. "than low, and a document that says otherwise is read by whoever signs "
        .. "the release:\n" .. unmeasurable_report)
assert(unmeasurable_report:find("undetermined", 1, true) ~= nil,
    "the report should say the floor is undetermined rather than omitting the "
        .. "verdict silently:\n" .. unmeasurable_report)
assert(unmeasurable_report:match("combined glibc floor: (%d[%.%d]*)") == nil,
    "the report states a numeric floor for a release with an unmeasured file:\n"
        .. unmeasurable_report)

-- ---------------------------------------------------------------------------
-- 5. The document a packager reads quotes the same promise.  A declared floor
--    that only exists in tools/baseline.conf is one nobody can act on.

local packaging = read_file("docs/PACKAGING.md")
assert(packaging:find("glibc " .. declared, 1, true) ~= nil,
    "docs/PACKAGING.md does not state the declared glibc floor (" .. declared .. ")")
assert(packaging:find("最低内核", 1, true) ~= nil,
    "docs/PACKAGING.md must answer the minimum-kernel question explicitly")

return true
