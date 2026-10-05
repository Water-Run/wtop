package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;;"

-- The version of the program is written down once.
--
-- It used to be written three times -- a literal in src/wtop/version.lua, a
-- literal in native/wtop_native.c, and a fallback literal in tools/make_sbom.py
-- -- and two of the three were printed by commands a user runs.  `--version`
-- printed the Lua tree's and `--diagnose` printed the module's, so a release
-- that bumped one and not the other made a single diagnostic report state two
-- different versions with nothing flagging the disagreement.  Nothing caught it
-- because the C copy was pinned to a literal inside a test that a person
-- updating the version would have updated along with everything else, which is
-- a guard that agrees with whatever it is guarding.
--
-- All three now come out of VERSION at the top of the tree by one run of
-- tools/write_build_id.sh, so the copies cannot drift.  This file pins that
-- arrangement rather than the arrangement's absence: it asserts the declared
-- file exists, that each consumer matches it, and that the generator is what
-- makes them match.  A test that only compared the three with each other would
-- pass just as happily on three copies that had all drifted together, which is
-- the state this project was actually in -- the two Lua-side copies were
-- compared and agreed, and the C-side one was not compared with anything.

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

-- ---------------------------------------------------------------------------
-- 1. The one place a human edits.

local declared = read_file("VERSION"):gsub("%s+", "")
assert(declared ~= "" and declared ~= nil,
    "VERSION is empty; there is no version for the program to report")
assert(declared:match("^%d+%.%d+") ~= nil,
    "VERSION holds " .. declared .. ", which does not start like a version number")

-- The generator must refuse a VERSION it cannot make sense of, rather than
-- writing that string into a C header and a Lua module.  A header is compiled:
-- a quote or a backslash in here would not be a wrong version, it would be a
-- build failure far from the file that caused it.
--
-- The layout matters and was wrong at first.  The script resolves the project
-- directory from its own location, so a copy under `tools/` reads
-- `<fixture>/VERSION` -- not the repository's, and not one beside the copy.  The
-- first version of this fixture put the hostile VERSION in the directory
-- holding the script, so the script failed because the file was *absent*, and
-- the assertion passed without ever looking at its contents.  The positive case
-- below is what makes the negative one mean something: the same layout, the same
-- script, a VERSION it accepts.
local function fixture_version(contents)
    local root = "build/native/.wtop-version-fixture"
    os.execute("rm -rf " .. root)
    os.execute("mkdir -p " .. root .. "/tools")
    local source = assert(io.open("tools/write_build_id.sh", "rb"))
    local copy = assert(io.open(root .. "/tools/write_build_id.sh", "wb"))
    copy:write(source:read("*a"))
    source:close()
    copy:close()
    local file = assert(io.open(root .. "/VERSION", "wb"))
    file:write(contents)
    file:close()
    local report, status = run("sh " .. root .. "/tools/write_build_id.sh")
    return report, status, root
end

local accepted_report, accepted_status, fixture_root = fixture_version("2.7.1\n")
assert(accepted_status == 0,
    "the generator rejected a perfectly ordinary version, so the refusal below "
        .. "would be testing nothing:\n" .. accepted_report)
local fixture_header = assert(io.open(fixture_root .. "/build/native/build_version.h", "rb"))
local fixture_value = fixture_header:read("*a")
fixture_header:close()
assert(fixture_value:find('#define WTOP_VERSION "2.7.1"', 1, true) ~= nil,
    "the generator accepted a version but did not write it into the header:\n"
        .. fixture_value)
local fixture_module = assert(io.open(fixture_root .. "/src/wtop/version.lua", "rb"))
local fixture_lua = fixture_module:read("*a")
fixture_module:close()
assert(fixture_lua:find('version = "2.7.1"', 1, true) ~= nil,
    "the generator accepted a version but did not write it into the Lua module:\n"
        .. fixture_lua)

local hostile_report, hostile_status = fixture_version('1.0" ; return nil; --\n')
assert(hostile_status ~= 0,
    "a VERSION containing a quote and a comment was accepted and written into a "
        .. "C header and a Lua module; the generated C string would not compile "
        .. "and the failure would be nowhere near this file:\n" .. hostile_report)
assert(not hostile_report:find("Traceback", 1, true),
    "the rejection should be a stated error, not a crash:\n" .. hostile_report)
assert(hostile_report:find("VERSION", 1, true) ~= nil,
    "the rejection does not say which file it was reading:\n" .. hostile_report)
os.execute("rm -rf " .. fixture_root)

-- ---------------------------------------------------------------------------
-- 2. Every consumer reports the declared version.

local native = require("wtop.native")
local version = require("wtop.version")

-- Section 2's second half compares the module's compiled version with the
-- tree's; without a built module the comparison has no subject, and the run
-- says so instead of comparing the fallback word "unavailable" against the
-- declared version (a stated skip in the one suite that builds nothing, a
-- failure everywhere else).
if not require("support.artifacts").require_condition(native.available,
        "the native module", "run `make native`") then
    return true
end

assert(version.version == declared,
    "the Lua tree reports version " .. tostring(version.version) ..
        " and VERSION says " .. declared .. "; run `make build-id`")

-- The C side.  `native.VERSION` is what `--diagnose` prints next to the Lua
-- tree's, so the two appearing side by side is the exact surface where a
-- mismatch would be visible to a user and invisible to a test.
assert(type(native.VERSION) == "string",
    "the module does not report a version at all")
assert(native.VERSION == declared,
    "the module was compiled with version " .. tostring(native.VERSION) ..
        " and VERSION says " .. declared .. ".  This is the copy that was a "
        .. "literal in the C source: nothing compared it with the Lua tree, so a "
        .. "bump could leave one report stating two versions.")

-- Comparing the two values is not enough on its own, and this is the reason.
-- Restoring the literal in the C source passes every assertion above, because
-- the literal and the declared version are the same string today -- the guard
-- agrees with whatever it is guarding, which is what the original arrangement
-- was: the C copy was pinned to a literal inside a test that anyone bumping the
-- version would have updated along with it.  So what is asserted here is
-- provenance rather than equality: the C sources must not contain the version
-- at all.  A value check cannot tell a derived number from a copied one; only
-- the absence of the copy can.
local native_source = read_file("native/wtop_native.c")
assert(native_source:find('"' .. declared .. '"', 1, true) == nil,
    "native/wtop_native.c contains the version as a string literal.  It is "
        .. "generated into build/native/build_version.h from VERSION and pushed "
        .. "as WTOP_VERSION; a literal here is a second copy that agrees today "
        .. "and will not agree after a bump, and nothing else in this file can "
        .. "see the difference while the two strings match")
assert(native_source:find("lua_pushliteral(L, WTOP_VERSION)", 1, true) ~= nil,
    "the module does not push the generated version, so the macro is generated "
        .. "and then ignored")

-- The Lua side is generated too, and saying so in the file is what stops a
-- future edit from putting a hand-written version back.
local version_source = read_file("src/wtop/version.lua")
assert(version_source:find("DO NOT EDIT", 1, true) ~= nil,
    "src/wtop/version.lua is not marked as generated.  It used to be a "
        .. "hand-written module with the version written into it, which is how "
        .. "the second copy existed; run `make build-id` to regenerate it")

-- And the header the module was compiled against, read directly.  The two
-- runtime values above already agree, so they would not notice a header
-- regenerated after the module was compiled -- the module carries its value
-- from compile time and nothing would move.
local header = read_file("build/native/build_version.h")
local compiled_in = header:match('#define WTOP_VERSION "([^"]*)"')
assert(compiled_in ~= nil,
    "build/native/build_version.h must define WTOP_VERSION:\n" .. header)
assert(compiled_in == declared,
    "the header the module was compiled against says " .. compiled_in ..
        " and VERSION says " .. declared .. "; the generated file is newer than "
        .. "the module compiled from it")

-- ---------------------------------------------------------------------------
-- 3. The generator is what keeps them equal, so it has to be wired into the
--    build rather than run by hand.  Reading the Makefile is how a missing
--    prerequisite is caught: a script nobody runs produces files nobody checks.

local makefile = read_file("Makefile")
assert(makefile:find("tools/write_build_id.sh", 1, true) ~= nil,
    "the Makefile no longer runs tools/write_build_id.sh")
assert(makefile:find("NATIVE_VERSION_HEADER", 1, true) ~= nil,
    "the Makefile has no NATIVE_VERSION_HEADER, so a version change would not "
        .. "rebuild the module and the C side would keep the version it was "
        .. "compiled with while the Lua side moved")
-- VERSION has to be a prerequisite of the rule, not merely mentioned: the
-- generator writes the revision header whether or not the version changed, so
-- depending on the script alone leaves a version bump rebuilding nothing.
--
-- The rule is located with a plain find and the line read from there.  A Lua
-- pattern would have to escape the hyphens in NATIVE_REVISION_HEADER, where a
-- `-` is a lazy quantifier and `NATIVE_REVISION_HEADER` is read as a sequence
-- of `N`s -- which is the eighth time this project has been caught by it.
local rule_start = makefile:find("$(NATIVE_REVISION_HEADER):", 1, true)
assert(rule_start ~= nil, "the Makefile has no rule for the revision header")
local revision_rule = makefile:match("[^\n]*", rule_start)
assert(revision_rule:find("VERSION", 1, true) ~= nil,
    "the generated-header rule does not depend on VERSION, so editing the "
        .. "version rebuilds nothing:\n" .. revision_rule)
local module_start = makefile:find("$(NATIVE_MODULE):", 1, true)
assert(module_start ~= nil, "the Makefile has no rule for the native module")
local module_rule = makefile:match("[^\n]*\n[^\n]*", module_start)
assert(module_rule:find("$(NATIVE_VERSION_HEADER)", 1, true) ~= nil,
    "the native module does not depend on the version header, so a rebuilt "
        .. "header would not reach the binary:\n" .. module_rule)

-- ---------------------------------------------------------------------------
-- 4. The disagreement is reported rather than assumed impossible.
--
--    The convergence above means `--version` should never have to say anything
--    extra, and a guard that cannot fire is a guard nobody has run.  So the
--    reporting path is exercised directly, with a module whose compiled version
--    is deliberately not the tree's, which is the state the arrangement exists
--    to make unreachable.

-- Only VERSION is replaced, and everything else is the real module: the command
-- under test reaches further into the native table than this is about, and a
-- hand-built stand-in would be a fixture asserting its own conclusion back at
-- the code.  The real table is wrapped rather than mutated so the agreeing case
-- below still sees the genuine value.
local real_native = require("wtop.native")
package.loaded["wtop.native"] = setmetatable({ VERSION = "0.0.0-different" },
    { __index = real_native })
local output = run(
    -- No environment prefix: the child inherits LUA_PATH and LUA_CPATH from
    -- whatever ran this file, which is how the real program finds its modules.
    -- Spelling them out here is a third place to get quoting wrong -- single
    -- quotes stop the shell expanding $PWD, and double quotes break this Lua
    -- string -- and a version test that cannot load the native module is a
    -- version test that cannot fail.
    ".tools/lua-5.5.1/bin/lua -e "
        .. "'package.path=\"./src/?.lua;./src/?/init.lua;\"..package.path; "
        .. "local real=require(\"wtop.native\"); "
        .. "package.loaded[\"wtop.native\"]=setmetatable({VERSION=\"0.0.0-different\"},"
        .. "{__index=real}); "
        .. "require(\"wtop.cli\").run({\"--version\"})'")
assert(output:find("native module version 0.0.0%-different") ~= nil,
    "the version command did not report that the module carries a different "
        .. "version from the tree.  It used to be impossible to tell, because "
        .. "the two came from two literals and the two commands that printed "
        .. "them were different commands:\n" .. output)
assert(output:find(declared, 1, true) ~= nil,
    "the version line does not carry the declared version at all:\n" .. output)

-- And the quiet case stays quiet: agreeing is the normal state and must not
-- produce a second version on every line the program ever prints.
local agree = run(
    ".tools/lua-5.5.1/bin/lua src/wtop.lua --version")
assert(agree:find("native module version", 1, true) == nil,
    "the two sides agree and the version line still says otherwise, which turns "
        .. "a real disagreement into noise nobody reads:\n" .. agree)
assert(agree:match("^wtop " .. declared:gsub("(%W)", "%%%1")) ~= nil,
    "the version line is not the declared version:\n" .. agree)

return true
