package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

-- The Lua tree and the native module must be able to state the same source
-- revision, because the version string a user sees comes from only one of them.
--
-- Until this existed, src/wtop/build_id.lua carried the revision and the native
-- module carried nothing but the linker's own build-id note, which is a hash of
-- the object rather than of the source.  Nothing tied the two together, so a
-- bundle could hold a module compiled from an older tree and still print the
-- newer revision: the number in `--version` came from the other half of the
-- program and had no way to be contradicted.  A release that reports a revision
-- it cannot corroborate is worse than one that reports none.
--
-- The identity is generated rather than passed as a -D flag precisely so that
-- the two sides are comparable: they come out of one `git describe` inside
-- tools/write_build_id.sh.  Two independent readings could disagree between the
-- moment one is compiled and the moment the other is, and a comparison between
-- two independently-read values would be comparing noise.

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

local native = require("wtop.native")

-- The whole subject of this file is the identity the *module* was compiled
-- with and its generated Lua-side twin; without either there is nothing to
-- compare and the run says so instead of failing a require (a stated skip in
-- the one suite that builds nothing, a failure everywhere else).
local Artifacts = require("support.artifacts")
if not Artifacts.require_condition(native.available,
        "the native module", "run `make native`")
    or not Artifacts.require_file("src/wtop/build_id.lua",
        "the generated build identity", "run `make build-id`") then
    return true
end

local build_id = require("wtop.build_id")

local constants = assert(native.system_constants())
assert(type(constants.build_revision) == "string",
    "the module must report a build revision, and a string even when it has "
        .. "none, so that a missing identity is visible rather than absent")
assert(constants.build_revision ~= "",
    "the module in this tree was compiled without a build identity, so the two "
        .. "halves cannot be compared and this test is not proving anything")

assert(type(build_id.revision) == "string" and build_id.revision ~= "",
    "the Lua tree carries no revision; run `make build-id`")
assert(constants.build_revision == build_id.revision,
    "the module was compiled from " .. constants.build_revision
        .. " while the Lua tree reports " .. build_id.revision
        .. "; one of the two halves is stale")

-- The generated header is what makes the two comparable, so it has to say the
-- same thing the Lua module does.  Reading it directly catches the case where
-- the header was regenerated after the module was compiled, which the two
-- runtime values above would not notice because the module carries its value
-- from compile time.
local header = read_file("build/native/build_revision.h")
local compiled_in = header:match('#define WTOP_BUILD_REVISION "([^"]*)"')
assert(compiled_in ~= nil,
    "build/native/build_revision.h must define WTOP_BUILD_REVISION")
assert(compiled_in == build_id.revision,
    "the header the module was compiled against says " .. compiled_in
        .. " and the Lua module says " .. build_id.revision)

-- The module also has to build without the build tree, which is the case a
-- source checkout and a hand-run compiler both hit.  __has_include makes the
-- generated header optional, and the fallback has to be an empty string: a
-- module that invented a revision would be worse than one that admits it has
-- none, and the assertion above is what would otherwise be comparing a guess.
local makefile = read_file("Makefile")
local lua_version = assert(makefile:match("LUA_VERSION%s*:=%s*([%d%.]+)"))
local include = "-I.tools/lua-" .. lua_version .. "/include"
-- Asserted on the exit status, not on the text: an empty string is what a
-- successful compile prints through this pipe, so a check written against the
-- output would be satisfied by the very failure it is meant to catch.
local output, status = run("cc -std=c17 -fPIC -Wall -Wextra -Werror -c -o /dev/null "
    .. include .. " native/wtop_native.c")
assert(status == 0,
    "the module must compile when the generated header is absent, which is the "
        .. "case a source checkout and a hand-run compiler both hit:\n" .. output)
-- Preprocessing removes the #define line and leaves the use site expanded, so
-- the fallback is observable there and nowhere else.  The first draft of this
-- check grepped for `WTOP_BUILD_REVISION ""` in preprocessed output, which can
-- never appear -- the macro is gone by that point -- so it was asserting on a
-- string the compiler had already removed.  What distinguishes the two builds
-- is the pushed literal: an empty one without the header, the revision with it.
local function empty_literal_count(includes)
    local output = run("cc -std=c17 -fPIC -E " .. includes
        .. " native/wtop_native.c 2>&1 | grep -c 'lua_pushstring(L, \"\");'")
    return tonumber(output:match("(%d+)"))
end
assert(empty_literal_count(include) == 1,
    "with no header in scope the revision must fall back to an empty string, so "
        .. "a module built outside the build tree says it has no identity")
assert(empty_literal_count("-Ibuild/native " .. include) == 0,
    "with the generated header in scope the module must carry the real "
        .. "revision rather than the empty fallback")

-- The version line is where a packager looks, so it is where a disagreement has
-- to surface.  Only a disagreement is reported: printing both revisions on every
-- run would be noise, and printing neither would leave a line that reads
-- normally while the two halves of the artifact came from different trees.
--
-- The agreeing case is what this asserts, and it is the one that regresses
-- silently -- a change that always prints the module's revision looks like it
-- works, and the extra text is easy to accept as harmless.  The disagreeing case
-- is not arranged here: producing it means rebuilding the module from a
-- different tree, and doing that inside a test would leave the build tree in a
-- state the next test inherits.  It was checked by mutation -- compiling the
-- header with a different revision makes the line read
-- `(rev ...) [native module rev ...]`.
-- The `--version` subprocess below pins the ordinary module: it is the pair a
-- packager ships, and the ordinary module is its subject.  A run whose module
-- lives elsewhere -- the sanitized run loads build/native-san -- has no such
-- file, and that is the environment's statement, not a broken build; the
-- identity comparisons above have already run against whatever module this
-- suite loaded, and under sanitizers that is the instrumented half this file
-- is there to exercise.
if not Artifacts.require_file("build/native/wtop_native.so",
        "the ordinary native module", "run `make native`") then
    return true
end

local version_output = run("LUA_PATH='./src/?.lua;./src/?/init.lua;;' LUA_CPATH='"
    .. os.getenv("PWD") .. "/build/native/?.so;;' .tools/lua-5.5.1/bin/lua "
    .. "src/wtop.lua --version")
assert(version_output:find(build_id.revision, 1, true) ~= nil,
    "--version must report the revision both halves agree on:\n" .. version_output)
assert(version_output:find("[native module rev", 1, true) == nil,
    "with the module compiled from the same tree there is nothing to report, "
        .. "and a version line carrying a second revision is noise:\n" .. version_output)

return true
