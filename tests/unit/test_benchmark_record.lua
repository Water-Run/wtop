package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local recipe_of = require("support.makefile").recipe_of

-- A measurement that does not say what it measured.
--
-- tools/perf_benchmark.py can drive two subjects: the development tree, or a
-- release bundle named by WTOP_BENCH_EXECUTABLE.  They are not the same
-- program.  Measured on one host minutes apart, with the rest of the tree
-- untouched:
--
--   metric          source tree    bundle      delta
--   first_frame_ms  283.6          326.4       +15.1%
--   rss_peak_kib    36752          46016       +25.2%
--
-- and the two JSON records had *byte-identical key sets*.  Nothing in either
-- said which subject produced it, so a number from the development tree and a
-- number from the artifact that actually ships were the same file.  Every other
-- release gate in this project measures the bundle -- the onefile PTY, the
-- SBOM, the baseline -- and the only documented way to get a performance
-- number produced one for a binary nobody distributes.
--
-- The record now carries its subject and its host.  The host is here for the
-- same reason the subject is: the tool's own banner says "compare same host
-- only", and a process count is not a host.  Two machines with the same process
-- count and the same load average can differ in core count and kernel, and both
-- change every number the tool reports.
--
-- The `--pages 1` case is in here too, because it is the same mistake one level
-- down: a latency sample is a measurement only if the keypress changes the
-- page, and asking the application to stay where it already was measured
-- nothing while aborting the run.  It is a value the help text offers.

local function run(command, environment)
    local prefix = ""
    for _, pair in ipairs(environment or {}) do
        prefix = prefix .. pair .. " "
    end
    local pipe = assert(io.popen(prefix .. command .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local _, _, code = pipe:close()
    return output, code
end

local function read_file(path)
    local handle = assert(io.open(path, "rb"), "cannot read " .. path)
    local body = handle:read("*a")
    handle:close()
    return body
end

local function exists(path)
    local handle = io.open(path, "rb")
    if handle then handle:close() end
    return handle ~= nil
end

-- Ask the tool to describe a subject without running anything.  This is the
-- cheap half of the contract and it is what makes both subjects checkable in
-- one test: the two descriptions have to differ, and each has to name something
-- a reader can go and look at.
local function describe(environment)
    local script = table.concat({
        "import json, sys",
        "sys.path.insert(0, 'tools')",
        "import perf_benchmark as b",
        "print(json.dumps(b.describe_subject()))",
    }, "; ")
    local output, code = run("python3 -c \"" .. script .. "\"", environment)
    assert(code == 0,
        "perf_benchmark could not be imported, so none of the subject "
            .. "descriptions below were checked:\n" .. output)
    return output:match("(%b{})") or ""
end

local source = describe({})
assert(source:find('"kind": "source%-tree"') ~= nil,
    "with no WTOP_BENCH_EXECUTABLE the tool measures the development tree, and "
        .. "describes itself as: " .. source)
assert(source:find("src/wtop.lua", 1, true) ~= nil,
    "the source-tree description does not name the entry point it runs, so a "
        .. "reader still cannot tell what was measured: " .. source)

-- The bundle subject is a file this test makes, not `dist/wtop/wtop`.  What
-- the description has to do is name an executable and say so; whether it is a
-- real wtop bundle is not what is under test, and depending on one would make
-- this file fail on any tree where the packaging has not been run -- including
-- the cross-libc container, which builds the module and runs the suite but has
-- no bundle and no luainstaller.  A guard that can only run after a release
-- build is a guard that does not run on the oldest libc.
local bundle = "build/native/.wtop-bench-subject"
os.execute("mkdir -p build/native")
local subject_file = assert(io.open(bundle, "wb"))
subject_file:write("#!/bin/sh\nexit 0\n")
subject_file:close()
os.execute("chmod 0755 " .. bundle)
assert(exists(bundle), "could not stage an executable to name as a subject")

local measured = describe({ "WTOP_BENCH_EXECUTABLE=" .. bundle })
assert(measured:find('"kind": "bundle"') ~= nil,
    "with WTOP_BENCH_EXECUTABLE set the tool measures a bundle, and describes "
        .. "itself as: " .. measured)
assert(measured ~= source,
    "the two subjects produce the same description, so a record cannot tell a "
        .. "development-tree run from a bundle run:\n" .. measured)
assert(measured:find('"present": true') ~= nil,
    "an executable file must be reported as present: " .. measured)

-- A path that exists but is not executable is the case in between, and it is
-- the one a mistyped path and a stale build both look like.
local not_executable = "build/native/.wtop-bench-not-executable"
local plain = assert(io.open(not_executable, "wb"))
plain:write("not a program\n")
plain:close()
assert(describe({ "WTOP_BENCH_EXECUTABLE=" .. not_executable })
    :find('"present": false') ~= nil,
    "a file that is not executable was reported as measurable; the tool would "
        .. "execve it and report the failure as the application never painting "
        .. "a first frame")

-- A subject that is not there is a refusal, not a measurement.  Without this
-- the execve fails inside the forked child and the run reports "no first frame
-- within 3 seconds" -- a statement about the application that is really a
-- statement about a typo in a path, and it costs the full warm-up to find out.
local missing_output, missing_code = run(
    "python3 tools/perf_benchmark.py --pages 1 --window-seconds 0.1 --latency-samples 1",
    { "WTOP_BENCH_EXECUTABLE=dist/wtop/not-here" })
assert(missing_code ~= 0,
    "the benchmark measured a path that does not exist:\n" .. missing_output)
assert(missing_output:find("refusing", 1, true) ~= nil,
    "the benchmark failed on a missing subject without saying it was refusing.  "
        .. "A reader would be told the application produced no first frame:\n"
        .. missing_output)
assert(missing_output:find("not%-here") ~= nil,
    "the refusal does not name the path that is missing:\n" .. missing_output)
assert(missing_output:find("no first frame", 1, true) == nil,
    "the failure surfaced as the application's own timeout, which is a claim "
        .. "about wtop rather than about the path that was passed:\n"
        .. missing_output)

-- The live run below drives the real TUI on the packaged interpreter with the
-- native module, and both are artifacts this tree may not have built.  A run
-- without them does not measure the program this gate is about (a stated skip
-- in the one suite that builds nothing, a failure everywhere else).  The path
-- is declared once because the invocation below spells it out too, and two
-- literals would be two copies of the same fact.
local interpreter = ".tools/lua-5.5.1/bin/lua"
if not require("support.artifacts").require_file(interpreter,
        "the packaged Lua interpreter", "run `make toolchain`")
    or not require("support.artifacts").require_file(
        "build/native/wtop_native.so",
        "the native module", "run `make native`") then
    return true
end

-- ---------------------------------------------------------------------------
-- The record itself, from one short end-to-end run.  This is the clause that
-- matters most: describe_subject() being correct says nothing about whether
-- main() puts it in the document, and a record that computes a fact and does
-- not write it down has asserted nothing.
--
-- Note the suite's own line for this file reads `ok 0.000s`.  That is not a
-- sign it was skipped.  tests/run.lua times with os.clock(), which counts the
-- CPU this process burns and not the time it spends waiting on a child, and
-- almost everything here is io.popen.  Measured on the development host the
-- file takes about six seconds of wall clock and reports zero; if you are
-- reading a suite log to decide whether a test ran, that column cannot answer
-- it, and the assertions below are what say so.
--
-- `--pages 1` is used deliberately.  It is the value the help text offers for
-- "just the overview", and it used to abort every run: the latency sweep sent
-- the key for the page already displayed, nothing redrew, the marker never
-- arrived.  A short window keeps the run to a few seconds; the CPU percentage
-- it produces at that length is not a meaningful steady-state figure and
-- nothing here asserts on it.
local output_path = "build/native/.wtop-benchmark-record.json"
os.execute("mkdir -p build/native")
local live, live_code = run(
    "python3 tools/perf_benchmark.py --pages 1 --window-seconds 0.2 "
        .. "--latency-samples 2 --json " .. output_path,
    { "WTOP_LUA=" .. interpreter, "WTOP_ROOT=." })
assert(live_code == 0,
    "the benchmark could not complete a --pages 1 run.  That combination is "
        .. "offered by the tool's own help text, and it used to abort on every "
        .. "sample because re-selecting the displayed page changes nothing:\n"
        .. live)
assert(exists(output_path), "the run produced no JSON document")

local document = read_file(output_path)
assert(document:find('"subject"', 1, true) ~= nil,
    "the JSON record does not carry a subject, so a number from the "
        .. "development tree and one from the shipped bundle are the same "
        .. "file:\n" .. document)
assert(document:find('"kind": "source%-tree"') ~= nil,
    "the record does not say which subject it measured:\n" .. document)
assert(document:find('"host"', 1, true) ~= nil,
    "the record does not carry a host, and the banner tells the reader to "
        .. "compare runs only on the same one:\n" .. document)
assert(document:find('"kernel"', 1, true) ~= nil
    and document:find('"machine"', 1, true) ~= nil
    and document:find('"cpus"', 1, true) ~= nil,
    "the host record is missing one of the three fields that identify a "
        .. "machine; a process count is not a host:\n" .. document)
assert(document:find('"unavailable"', 1, true) == nil,
    "the host record says a field could not be read, so the record is "
        .. "describing a host it could not identify:\n" .. document)

-- The printed form carries them too.  The JSON is what a machine reads, and the
-- banner is what a person reads while deciding whether two numbers are worth
-- comparing; a fact in only one of them is a fact one of the two audiences
-- does not have.
assert(live:find("subject.kind", 1, true) ~= nil,
    "the printed output does not name the subject:\n" .. live)
assert(live:find("host.kernel", 1, true) ~= nil,
    "the printed output does not name the host:\n" .. live)

-- The Makefile is how every other release target is reached, and the bundle
-- subject used to be reachable only through an environment variable that
-- appeared in no document and in no target.
local makefile = read_file("Makefile")
assert(makefile:find("BENCH_EXECUTABLE", 1, true) ~= nil,
    "the Makefile has no BENCH_EXECUTABLE, so the only way to measure the "
        .. "artifact that ships is an environment variable documented nowhere")
local benchmark = recipe_of(makefile, "benchmark")
assert(benchmark ~= nil and benchmark:find("WTOP_BENCH_EXECUTABLE", 1, true) ~= nil,
    "the benchmark target does not pass BENCH_EXECUTABLE through to the tool, "
        .. "so setting the Makefile variable changes nothing:\n"
        .. tostring(benchmark))

os.execute("rm -f " .. output_path .. " " .. bundle .. " " .. not_executable)
return true
