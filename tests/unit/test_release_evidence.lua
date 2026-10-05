package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;;" .. package.path

-- Release evidence has one contract, and this project has now broken it three
-- times without noticing any of them:
--
--   A document filed as release evidence must not assert a conclusion it did
--   not earn.  Concretely: if the tool was asked about a set of files and could
--   not measure all of them, the run fails and the document says nothing --
--   no floor, no serial number, no "within the promised".
--
-- The three occurrences, for the record, because they are three different
-- shapes of the same mistake:
--
--   1. tools/make_sbom.py took a bundle path that no rule had ever produced,
--      found no files, and wrote a complete CycloneDX document -- components,
--      serial number, licenses, purls -- with not one hash, then printed
--      "SBOM written" and exited 0.
--   2. tools/record_baseline.sh exited non-zero for an unmeasurable ELF and the
--      report it had already written still said "status: within the promised
--      floor", because an unmeasurable file contributes zero and zero compares
--      below every promised floor.
--   3. Two CI steps called tools/record_baseline.sh with no arguments, which has
--      been a usage error since the ELF list became required, and the shell
--      redirect had already created the file.  So the step created a zero-byte
--      dist/BASELINE.txt, and the release job is configured to upload exactly
--      that file.  The empty document was created by the shell rather than by
--      the tool, which is why fixing the tool fixed nothing about it.
--
-- Each was found by reading something -- a document, a script, a workflow file
-- -- and none was found by the gate that ran the tool.  That is the part this
-- file exists to change, and the change is structural rather than a lint: every
-- tool in tools/ has to be classified here, so adding one is a decision rather
-- than an omission, and an evidence tool that is not reached through a Makefile
-- target is a failure here rather than a usage error in a workflow nobody reads.
--
-- The classification is enumerated rather than discovered.  A discovery rule
-- would have to tell a report from a bootstrap script, and the honest answer is
-- that there is no mechanical test for "produces a document a person files as
-- evidence" -- the same trade docs/PLAN.md's test-count guard makes, for the
-- same reason.  The cost is that a new tool is not covered until it is listed,
-- and what is given for that is that listing it is required before this test
-- passes, so the omission cannot be silent.

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

local function exists(path)
    local handle = io.open(path, "rb")
    if handle then handle:close() end
    return handle ~= nil
end

-- ---------------------------------------------------------------------------
-- Reading the workflow.
--
-- Two questions are asked of .github/workflows/ci.yml and neither is answered
-- by a substring search: which paths does an upload step publish, and which
-- paths does a `make` invocation produce.  Both are read out of the workflow
-- rather than listed here, because a list of paths written in this file is a
-- second copy of the paths in the workflow -- and a second copy is the second
-- thing to forget when the first one changes.  That is the whole reason section
-- 6 exists instead of three assertions naming three files: when it was written,
-- the first version of the check below was `workflow:find("dist/BASELINE-arm64.txt")`,
-- which is satisfied by the path appearing in a *run* step as well as in an
-- upload, and so could not tell the defect from its absence.

local function indent_of(line)
    return #(line:match("^%s*") or "")
end

--- A YAML mapping line, as key, value, and whether it opens a block scalar.
--
-- One reader for one job: the question "is this a `key: |` header?" was being
-- answered twice, in the code that reads upload paths and again in the code
-- that finds prose in them, and the two answers drifting apart is how one of
-- them ends up stripping a comment the other is trying to report.
--
-- A trailing comment on the header line is YAML, not yet a path, so
-- `path: | # the evidence` is still a block: the comment is removed before the
-- marker is compared rather than becoming part of the first path.
local function mapping_of(line)
    local key, value = line:match("^%s*(%a[%w_%-]*):%s*(.*)$")
    if not key then return nil, nil, false end
    local marker = value:gsub("%s*#.*$", ""):gsub("[%-%+ ]$", "")
    return key, value, marker == "|" or marker == ">"
end

--- Every line inside a `path: |` block that begins with `#`.
--
-- Read from the raw text on purpose.  The clause that uses it has to hold even
-- if the rest of this file is fed a different text than the one it was written
-- against, so it does not go through strip_comments: that is the whole question
-- being asked.  A block scalar ends at the first line indented no further than
-- its key, the same rule published_paths uses, which is why the two agree about
-- where the block is.
local function prose_in_path_blocks(text)
    local offenders, prose_indent = {}, nil
    for line in text:gmatch("[^\n]+") do
        if prose_indent then
            if indent_of(line) > prose_indent then
                local body = line:match("^%s*(.-)%s*$")
                if body:match("^#") then
                    offenders[#offenders + 1] = body
                end
            else
                prose_indent = nil
            end
        else
            local key, _, is_block = mapping_of(line)
            if key == "path" and is_block then
                prose_indent = indent_of(line)
            end
        end
    end
    return offenders
end

--- Drop `#` comments, which the workflow uses to explain each step.
--
-- Not cosmetic: the comments explain *why* an upload exists, so they name the
-- very paths the checks look for, and a search that did not strip them would
-- find those paths in the explanation of the step that was supposed to publish
-- them.
local function strip_comments(text)
    local out = {}
    for line in text:gmatch("[^\n]+") do
        out[#out + 1] = (line:gsub("%s*#.*$", ""))
    end
    return table.concat(out, "\n")
end

--- Every path an upload step publishes, as `{ artifact = ..., path = ... }`.
--
-- The step's own indentation bounds the scan: a line at or left of it that
-- starts a new list item is the *next* step, and the `path:` key belongs to this
-- one only until then.  Searching the whole file for `path:` would be shorter
-- and would also collect the keys of whatever action comes next, and "some
-- action had a path key" is not what "published" means.
local function published_paths(text)
    local lines = {}
    for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
    local published, index = {}, 1
    while index <= #lines do
        local step = lines[index]
        if step:match("^%s*%- uses:%s*actions/upload%-artifact") then
            local step_indent, artifact = indent_of(step), nil
            local cursor = index + 1
            while cursor <= #lines do
                local line = lines[cursor]
                if indent_of(line) <= step_indent and line:match("^%s*%- ") then
                    break
                end
                -- One branch moves the cursor, and the cursor is the loop's only
                -- progress.  The first version had a `name` branch that
                -- assigned and fell through without advancing, so every upload
                -- step with a name in it looped forever on that one line -- and
                -- stdout was block-buffered into a pipe, so the symptom was a
                -- process that printed nothing at all rather than one that
                -- visibly spun.  A line with no key is not an error either:
                -- mapping_of returns nils for it and both conditions below are
                -- false, where a reader that indexed the nil died with
                -- "attempt to index a nil value" and said nothing about the
                -- evidence, which is the one thing this file exists to make
                -- people read.
                local key, value, is_block = mapping_of(line)
                if key == "path" and is_block then
                    local key_indent = indent_of(line)
                    local scan = cursor + 1
                    while scan <= #lines and indent_of(lines[scan]) > key_indent do
                        published[#published + 1] = { artifact = artifact,
                                                       path = lines[scan]:match("^%s*(.-)%s*$") }
                        scan = scan + 1
                    end
                    cursor = scan
                else
                    if key == "name" then
                        artifact = value
                    elseif key == "path" then
                        published[#published + 1] = { artifact = artifact,
                                                       path = value }
                    end
                    cursor = cursor + 1
                end
            end
            index = cursor
        else
            index = index + 1
        end
    end
    return published
end

--- The artifact that publishes `path`, or nil when nothing does.
local function publisher_of(path, published)
    for _, entry in ipairs(published) do
        if entry.path == path then
            return entry.artifact or "(an upload with no name)"
        end
        -- A trailing slash is how an entry says "this whole directory".
        if entry.path:sub(-1) == "/" and path:sub(1, #entry.path) == entry.path then
            return entry.artifact or "(an upload with no name)"
        end
    end
    return nil
end

--- Every `make <targets> [VAR=VALUE ...]` the workflow runs.
local function make_invocations(text)
    local invocations = {}
    for line in text:gmatch("[^\n]+") do
        local body = line:match("%f[%w]make%s+(.+)$")
        if body then
            -- A shell fallback -- `make test || { ...; exit 1; }` -- is not part
            -- of the command.  Stopping at the first metacharacter keeps `exit`
            -- and `1` from being read as target names.
            body = body:match("^([^|&;]*)") or body
            local targets, overrides = {}, {}
            for token in body:gmatch("%S+") do
                local name, value = token:match("^([%w_%-]+)=(.*)$")
                if name then
                    overrides[name] = value
                else
                    targets[#targets + 1] = token
                end
            end
            if #targets > 0 then
                invocations[#invocations + 1] =
                    { targets = targets, overrides = overrides }
            end
        end
    end
    return invocations
end

local makefile = read_file("Makefile")
local makefile_api = require("support.makefile")
local recipe_of = makefile_api.recipe_of
local variable_of = makefile_api.variable_of
local plan_text = read_file("docs/PLAN.md")
local workflow_raw = read_file(".github/workflows/ci.yml")
local workflow = strip_comments(workflow_raw)
-- The upload paths are read from the *unstripped* text, and that is the whole
-- reason the two are kept apart.  Everything under a `path: |` is literal text
-- to the YAML parser, so a paragraph of explanation written there to say why
-- the upload exists is not a comment: it is a list of filenames, one of which
-- begins with "#".  This project's release upload carried exactly such a
-- paragraph for an increment, and reading the paths through strip_comments
-- would have deleted the evidence before this file got to report it.
local published = published_paths(workflow_raw)

-- ---------------------------------------------------------------------------
-- 1. Every tool is classified.

local RELEASE_EVIDENCE = {
    -- Records the architecture, dependencies and glibc requirement of the files
    -- a release ships.  Reached through two targets, and the pair is a decision
    -- rather than a duplicate: `release-baseline` measures the shipped forms and
    -- is the release evidence, while `baseline` measures the build host and is
    -- not in `test-all` at all.  Naming only one of them here would make the
    -- aggregate-gate check below pass or fail for the wrong reason -- `baseline`
    -- is a substring of `release-baseline`, so a check that looks for one is
    -- satisfied by the other without either being run.
    { tool = "record_baseline.sh", target = "baseline", document = true,
      also = "release-baseline" },
    -- Records which components a release contains and what their hashes are.
    -- Document: yes, through `make sbom`.
    { tool = "make_sbom.py", target = "sbom", document = true },
}

-- The measurement tools and the build tools, listed so that the enumeration
-- above is exhaustive.  They are named here rather than ignored, because "not
-- release evidence" is a decision and not a default.
local NOT_RELEASE_EVIDENCE = {
    "bootstrap_luainstaller.sh", "bootstrap_luarocks.sh", "bootstrap_lua.sh",
    "build_macos.sh", "build_windows_x86.sh", "check_digest_agreement.py",
    "check_resources.sh",
    "compile_locales.lua", "cross_libc_build.sh", "elf_floors.py",
    "perf_benchmark.py", "write_build_id.sh",
}

local classified = {}
for _, entry in ipairs(RELEASE_EVIDENCE) do
    assert(classified[entry.tool] == nil,
        entry.tool .. " is classified twice")
    classified[entry.tool] = "release evidence"
    assert(exists("tools/" .. entry.tool),
        "tools/" .. entry.tool .. " is listed as release evidence but does not "
            .. "exist; a stale entry is a contract nobody is keeping")
end
for _, tool in ipairs(NOT_RELEASE_EVIDENCE) do
    assert(classified[tool] == nil, tool .. " is classified twice")
    classified[tool] = "not release evidence"
    assert(exists("tools/" .. tool),
        "tools/" .. tool .. " is listed as not being release evidence but does "
            .. "not exist; delete the entry rather than leaving it to rot")
end

-- Every script and Python file in tools/ must appear in exactly one table.  This
-- is the clause that makes the whole file worth having: a new tool that produces
-- a release document cannot be added without saying what it does when the
-- release is incomplete.
local unclassified = {}
local pipe = assert(io.popen("ls tools/*.sh tools/*.py 2>/dev/null", "r"))
for line in pipe:read("*a"):gmatch("[^\n]+") do
    local tool = line:match("([^/]+)$")
    if tool and tool ~= "compile_locales.lua" and classified[tool] == nil then
        unclassified[#unclassified + 1] = tool
    end
end
pipe:close()
table.sort(unclassified)
assert(#unclassified == 0,
    "tools/ contains " .. table.concat(unclassified, ", ") .. ", which this "
        .. "file has not classified.  Add it to RELEASE_EVIDENCE or to "
        .. "NOT_RELEASE_EVIDENCE.  A release-evidence tool that is not listed "
        .. "here is one whose behaviour on an incomplete release is unspecified, "
        .. "which is the state all three of the defects above were found in.")

-- ---------------------------------------------------------------------------
-- 2. Every release-evidence tool is reached through a Makefile target, and the
--    target is where the file list lives.

for _, entry in ipairs(RELEASE_EVIDENCE) do
    for _, target in ipairs({ entry.target, entry.also }) do
        if target then
            assert(makefile:find("\n" .. target .. ":", 1, true) ~= nil,
                "the Makefile has no `" .. target .. "` target for "
                    .. entry.tool .. "; a tool that produces release evidence "
                    .. "needs a target, because the target is the one place that "
                    .. "decides what gets measured and a caller that re-derives "
                    .. "it will eventually re-derive it wrongly")
        end
    end
end

-- The reason the CI steps broke: they called the tool, and the tool has no
-- default.  A direct invocation of an evidence tool means whoever wrote it also
-- had to know which files to measure, and that knowledge now lives in the
-- Makefile and nowhere else.
for _, entry in ipairs(RELEASE_EVIDENCE) do
    -- `workflow` has its comments stripped already, which is load-bearing
    -- here: the workflow documents *why* it goes through the target, and that
    -- text necessarily names the tool.
    assert(not workflow:find("tools/" .. entry.tool, 1, true),
        ".github/workflows/ci.yml invokes tools/" .. entry.tool .. " directly.  "
            .. "Go through `make " .. entry.target .. "` instead: the target "
            .. "holds the list of files to measure, and a caller that supplies "
            .. "its own list is the defect that left two CI steps failing on a "
            .. "usage error while still writing the zero-byte document the "
            .. "release job uploads.")
end

-- ---------------------------------------------------------------------------
-- 3. The aggregate gate covers all of them.  `test-all` is the local answer to
--    "does the whole release story hold"; an evidence target that is not in it
--    is one that only CI knows about, and CI is a place nobody reads.

-- Read through make rather than by matching lines: this used to be
-- `makefile:match("test%-all:[^\n]*\n[^\n]*\n?")`, a two-line window on a rule
-- written across three.  It happened to be right -- every release-evidence
-- target this file knows about fits in the first two lines -- and being right
-- by coincidence is how the fourth copy of the same guess in §6f went on
-- silently dropping three gates for an increment.
local test_all_list, test_all_refusal = makefile_api.prerequisites_of("test-all")
assert(test_all_list ~= nil,
    "the Makefile's test-all rule could not be read: "
        .. (test_all_refusal or "the reader refused without saying why"))
local test_all = table.concat(test_all_list, " ")
for _, entry in ipairs(RELEASE_EVIDENCE) do
    -- Any of the tool's targets will do, and the search is exact rather than a
    -- substring: `baseline` is a substring of `release-baseline`, so a
    -- substring test here would pass with `release-baseline` in the list and
    -- `baseline` absent -- which is the state the aggregate gate was in before
    -- the build-host floor was taken out of it, and which nobody noticed for
    -- exactly that reason.
    local candidates = { entry.target }
    if entry.also then candidates[#candidates + 1] = entry.also end
    local present = false
    for _, candidate in ipairs(candidates) do
        if (" " .. test_all .. " "):find(" " .. candidate .. " ", 1, true) ~= nil then
            present = true
        end
    end
    assert(present,
        "`make test-all` runs neither " .. table.concat(candidates, " nor ")
            .. ", so the aggregate gate is silent about a document the release "
            .. "ships.  It used to omit sbom entirely while CI ran it, which is "
            .. "how an SBOM spent a month describing nothing and reporting "
            .. "success.")
end

-- ---------------------------------------------------------------------------
-- 4. The contract itself, over the declared set: a complete run succeeds and
--    says so; an incomplete run fails and says nothing.

-- 4a. The baseline gate.
local lua_version = assert(makefile:match("LUA_VERSION%s*:=%s*([%d%.]+)"),
    "the Makefile no longer declares LUA_VERSION, so the interpreter path used "
        .. "to give the gate a real file to measure is unknown")
local interpreter = ".tools/lua-" .. lua_version .. "/bin/lua"
-- Section 4 feeds the gate real ELF images; sections 5 and 6 below read text
-- and do not need them, but they run in every artifact-rich suite, and the
-- one suite that builds nothing takes a stated skip here rather than a
-- failure that would say the build broke when it did not.
local Artifacts = require("support.artifacts")
if not Artifacts.require_file("build/native/wtop_native.so",
        "the native module", "run `make native`")
    or not Artifacts.require_file(interpreter,
        "the packaged Lua interpreter", "run `make toolchain`") then
    return true
end

local scratch = "build/native/.wtop-evidence-fixture"
os.execute("rm -rf " .. scratch .. " && mkdir -p " .. scratch)
local not_an_elf = scratch .. "/not-an-elf.bin"
local handle = assert(io.open(not_an_elf, "wb"))
handle:write("this is not an ELF image\n")
handle:close()

local complete_report, complete_status = run(
    "sh tools/record_baseline.sh build/native/wtop_native.so " .. interpreter)
assert(complete_status == 0,
    "the gate rejected artifacts that are present; the refusal below would then "
        .. "be testing nothing:\n" .. complete_report)
assert(complete_report:find("status: within the promised floor", 1, true) ~= nil,
    "a complete run produced no verdict, so a reader cannot tell a measured "
        .. "release from an unmeasured one:\n" .. complete_report)

local partial_report, partial_status = run(
    "sh tools/record_baseline.sh build/native/wtop_native.so " .. not_an_elf)
assert(partial_status ~= 0,
    "the gate passed an input containing a file it could not measure:\n"
        .. partial_report)
assert(partial_report:find("status: within the promised floor", 1, true) == nil,
    "the gate exited non-zero and still wrote a document certifying the "
        .. "release.  The exit status is read by CI; the document is read by "
        .. "whoever signs the release, and only the document asserted anything:\n"
        .. partial_report)

-- 4b. The SBOM generator.  It has no prose verdict: the document *is* the
--     claim, so the contract for it is that the document must not exist unless
--     everything it was asked about was there.  The fixture is the minimum
--     layout the generator accepts, built here rather than borrowed from
--     dist/ so the test does not depend on a bundle having been produced.
os.execute("mkdir -p " .. scratch .. "/bundle/.luai/native")
for _, name in ipairs({ scratch .. "/bundle/wtop",
                        scratch .. "/bundle/.luai/native/wtop_native.so",
                        scratch .. "/wtop-onefile" }) do
    local handle = assert(io.open(name, "wb"))
    handle:write("fixture bytes for " .. name .. "\n")
    handle:close()
end
-- The licence texts, because the generator now refuses a release that does not
-- carry them.  A fixture without them would be measuring that refusal instead
-- of the contract this section is about.
for _, name in ipairs({ "LICENSE",
                        ".luai/licenses/Lua-MIT.txt",
                        ".luai/licenses/LGPL-3.0-or-later.txt" }) do
    local path = scratch .. "/bundle/" .. name
    local directory = name:match("^(.*)/[^/]+$")
    if directory then
        os.execute("mkdir -p " .. scratch .. "/bundle/" .. directory)
    end
    local handle = assert(io.open(path, "wb"))
    handle:write("fixture licence text for " .. name .. "\n")
    handle:close()
end

local good_sbom = scratch .. "/good.json"
local _, good_status = run("python3 tools/make_sbom.py --onedir " .. scratch
    .. "/bundle --onefile " .. scratch .. "/wtop-onefile --output " .. good_sbom)
assert(good_status == 0, "the SBOM generator rejected a complete fixture, so "
    .. "the refusal below would be testing nothing")
assert(exists(good_sbom), "a complete SBOM run wrote no document")

local bad_sbom = scratch .. "/must-not-exist.json"
local bad_report, bad_status = run("python3 tools/make_sbom.py --onedir " .. scratch
    .. "/bundle --onefile " .. scratch .. "/absent --output " .. bad_sbom)
assert(bad_status ~= 0, "the SBOM generator passed an input with a missing artifact")
assert(not exists(bad_sbom),
    "the SBOM generator failed and still wrote a document; a document that "
        .. "describes less than the release is filed as evidence anyway, and "
        .. "this is the shape that shipped a CycloneDX file with no hashes in it")
-- A crash satisfies both clauses above and is not a refusal.  Removing the
-- generator's own check does not make it write a document: it makes it go on to
-- open a file that is not there and die on the traceback, which exits non-zero
-- and leaves no output -- the same two observable facts as a decision.  Without
-- this the contract was satisfied by an accident, and the mutation that proved
-- it was one line.
assert(not bad_report:find("Traceback (most recent call last)", 1, true),
    "the generator refused by crashing rather than by deciding.  A traceback "
        .. "exits non-zero and writes no document, so it is indistinguishable "
        .. "from a refusal by exit status and by file existence -- the two things "
        .. "this contract can see:\n" .. bad_report)
assert(bad_report:find("refusing", 1, true) ~= nil,
    "the generator failed without saying it was refusing to describe an "
        .. "incomplete release:\n" .. bad_report)

-- 4b, second half.  "Everything it was asked about" includes the licence texts,
-- not only the executables.  A document that names EUPL-1.2, MIT and LGPL on
-- four components while carrying none of those texts is a document asserting a
-- conclusion nobody established, which is this file's whole subject -- and it
-- is invisible to the clause above, because all three executables were present
-- when it was taken.
local unlicensed = scratch .. "/unlicensed"
os.execute("cp -a " .. scratch .. "/bundle " .. unlicensed)
assert(os.remove(unlicensed .. "/LICENSE"), "could not stage the unlicensed fixture")
local unlicensed_sbom = scratch .. "/must-not-exist-unlicensed.json"
local unlicensed_report, unlicensed_status = run(
    "python3 tools/make_sbom.py --onedir " .. unlicensed .. " --onefile "
        .. scratch .. "/wtop-onefile --output " .. unlicensed_sbom)
assert(unlicensed_status ~= 0,
    "the SBOM generator passed a release that does not carry the text of the "
        .. "licence it declares on two of its four components:\n" .. unlicensed_report)
assert(not exists(unlicensed_sbom),
    "the generator wrote a document naming terms the release does not carry, "
        .. "and that document is filed as evidence")
assert(unlicensed_report:find("refusing", 1, true) ~= nil,
    "the generator failed without saying it was refusing:\n" .. unlicensed_report)

-- 4c. The digest-agreement check.  Two documents describe the same release --
--     the SBOM's component hashes and SHA256SUMS over everything the release
--     ships -- and nothing compared them until this file's increment did.  They
--     are produced by different targets from different tools over different
--     lists, so a rebuild that refreshed one and not the other ships two
--     integrity records that contradict each other with every gate still green.
--
--     It runs only in `make test-release-notices` and in CI, where the real
--     documents exist, which is exactly the gap this file keeps running into:
--     a check that only a person who builds the bundle ever sees.  So it is
--     shown documents here too, and the refusing half is the half that matters
--     -- a validator only ever shown a conforming document is a validator
--     nobody has run.
local agree = scratch .. "/digest-agreement"
os.execute("mkdir -p " .. agree)
local digest = string.rep("ab", 32)
local function write_fixture(name, body)
    local handle = assert(io.open(agree .. "/" .. name, "wb"))
    handle:write(body)
    handle:close()
end
write_fixture("good.json",
    '{"specVersion":"1.5","components":[{"name":"wtop","hashes":['
        .. '{"alg":"SHA-256","content":"' .. digest .. '"}]}]}' .. "\n")
write_fixture("good.SHA256SUMS", digest .. "  wtop/wtop\n")

local agree_report, agree_status = run(
    "python3 tools/check_digest_agreement.py --sbom " .. agree
        .. "/good.json --manifest " .. agree .. "/good.SHA256SUMS")
assert(agree_status == 0,
    "the digest-agreement check rejected a pair of documents that agree, so "
        .. "the refusal below would be testing nothing:\n" .. agree_report)

-- The refusing half, twice: a stale SBOM and a stale manifest name the same
-- disagreement from opposite directions, and both have to be caught, because a
-- rebuild refreshes either document.
write_fixture("stale-sbom.json",
    '{"specVersion":"1.5","components":[{"name":"wtop","hashes":['
        .. '{"alg":"SHA-256","content":"' .. string.rep("cd", 32) .. '"}]}]}' .. "\n")
local stale_report, stale_status = run(
    "python3 tools/check_digest_agreement.py --sbom " .. agree
        .. "/stale-sbom.json --manifest " .. agree .. "/good.SHA256SUMS")
assert(stale_status ~= 0,
    "a stale SBOM passed: the SBOM records a digest the manifest does not, "
        .. "and the release ships two integrity records that contradict each "
        .. "other:\n" .. stale_report)
assert(stale_report:find(digest, 1, true) == nil
        and stale_report:find(string.rep("cd", 32), 1, true) ~= nil,
    "the disagreement was reported without naming the digest neither document "
        .. "shares, so a reader cannot tell which claim is the stale one:\n"
        .. stale_report)
assert(stale_report:find("refus", 1, true) ~= nil or stale_report:find("wtop:", 1, true) ~= nil,
    "the check failed without saying what it refused:\n" .. stale_report)

write_fixture("stale-manifest.SHA256SUMS", string.rep("ef", 32) .. "  wtop/wtop\n")
local other_report, other_status = run(
    "python3 tools/check_digest_agreement.py --sbom " .. agree
        .. "/good.json --manifest " .. agree .. "/stale-manifest.SHA256SUMS")
assert(other_status ~= 0,
    "a stale manifest passed: the same disagreement, reached from the other "
        .. "document:\n" .. other_report)
-- And the empty cases, because a check that reads no digests and compares them
-- successfully is a check that passes for the wrong reason.
write_fixture("no-hashes.json", '{"specVersion":"1.5","components":[{"name":"wtop"}]}' .. "\n")
local empty_report, empty_status = run(
    "python3 tools/check_digest_agreement.py --sbom " .. agree
        .. "/no-hashes.json --manifest " .. agree .. "/good.SHA256SUMS")
assert(empty_status ~= 0,
    "an SBOM with no digests passed the agreement check, so there was nothing "
        .. "to agree about:\n" .. empty_report)
local empty_manifest_report, empty_manifest_status = run(
    "python3 tools/check_digest_agreement.py --sbom " .. agree
        .. "/good.json --manifest " .. agree .. "/empty.SHA256SUMS")
assert(empty_manifest_status ~= 0,
    "an empty manifest passed the agreement check:\n" .. empty_manifest_report)

-- ---------------------------------------------------------------------------
-- 5. The terms travel with the programs.  A fourth occurrence of the shape, and
--    the first one about a file rather than a claim inside a document.
--
--    The gate in docs/PLAN.md §9 lists third-party notices among the release
--    artifacts.  Nothing produced one, nothing checked for one, and nobody
--    published one: the SBOM declared EUPL-1.2 on both wtop components, MIT on
--    lua and LGPL on luainstaller, and carried the text of none of the three.
--    SHA256SUMS covered the two executables and none of the notices.  Both CI
--    upload jobs published evidence and a program, and neither published a
--    single licence file.  A release can be complete, verified and green while
--    carrying no readable statement of the terms it is distributed under.
--
--    The three clauses below are what makes that fail somewhere.  The generator
--    refusing a licence with no text is asserted in test_sbom.lua and in 4b
--    above; what is pinned here is the two links that are easy to leave out --
--    the manifest covering the notices, and CI actually shipping them.

-- 5a. The integrity manifest is not a manifest of the two entry points.  It
--     covered them and stopped, which means `sha256sum -c` said "all good"
--     while the terms beside them could be deleted or replaced.
local checksums_recipe = recipe_of(makefile, "checksums")
assert(checksums_recipe ~= nil, "the Makefile has no checksums recipe to inspect")
assert(checksums_recipe:find("RELEASE_NOTICE_FILES", 1, true) ~= nil,
    "the checksums recipe does not use the notice discovery, so the manifest "
        .. "covers the executables and not the licences and notices beside "
        .. "them.  A release whose integrity manifest omits its own terms "
        .. "verifies green while those terms are replaced:\n" .. checksums_recipe)
-- And the discovery has to be able to come back empty, which is checked
-- rather than assumed: a `find` that matches nothing still produces a valid
-- two-file manifest and still reports success.
assert(checksums_recipe:find("@test -s dist/.wtop-notices || {", 1, true) ~= nil,
    "the checksums recipe does not check that it found any notice file, so a "
        .. "packaging change that stopped shipping them would quietly produce a "
        .. "manifest covering two programs and no terms:\n" .. checksums_recipe)

-- 5a, second half.  The manifest has to cover what ships, not only what is
--     notice-shaped.  The discovery above selects licences and notices by name,
--     and for a long time that *was* the whole coverage list, plus two entry
--     points written out by hand: everything else in the bundle was outside the
--     integrity manifest.  The shipped native module was among them, and it is
--     an executable -- the thing the package exists to load.  Replacing it in a
--     recipient's copy left `sha256sum -c` reporting 7 of 7 and exiting 0.
--
--     This clause reads the recipe's shape rather than a file list: the walk
--     that feeds the manifest must be unfiltered, and the filtered one must
--     still exist, because the notice check is a separate question and the
--     refusal above depends on it.
assert(checksums_recipe:find("find wtop -type f | LC_ALL=C sort > .wtop-files", 1, true) ~= nil,
    "the checksums recipe does not walk the whole bundle, so the manifest "
        .. "covers the notice-shaped files and the two entry points named by "
        .. "hand, and any other file the release ships -- including "
        .. ".luai/native/wtop_native.so -- is outside it.  A recipient who "
        .. "replaces one of those gets a green `sha256sum -c`:\n"
        .. checksums_recipe)
assert(checksums_recipe:find("xargs sha256sum < .wtop-files", 1, true) ~= nil,
    "the checksums recipe does not hash the unfiltered file list it walks; the "
        .. "walk is there and nothing consumes it:\n" .. checksums_recipe)
assert(checksums_recipe:find("@test -s dist/.wtop-files || {", 1, true) ~= nil,
    "the checksums recipe does not check that its file walk found anything, so "
        .. "a bundler that produced an empty tree would still write a manifest "
        .. "covering one program:\n" .. checksums_recipe)
-- And the question is asked of the real bundle, not only of the recipe: every
-- file the onedir bundle carries has to appear in the manifest.  That clause
-- lives in `make test-release-notices` rather than here, because it needs the
-- built bundle -- and it is the clause that would have failed on the replaced
-- module above.
local notices_recipe = recipe_of(makefile, "test-release-notices")
assert(notices_recipe ~= nil
        and notices_recipe:find("find wtop -type f | LC_ALL=C sort", 1, true) ~= nil,
    "the test-release-notices recipe does not ask the unfiltered question -- "
        .. "that every file the bundle carries is in SHA256SUMS.  The recipe's "
        .. "notice filter is a different question, and answering only that one "
        .. "is what left the shipped native module uncovered")
-- And it asks the third question, about two documents that describe the same
-- release and were compared by nothing.
assert(notices_recipe:find("tools/check_digest_agreement.py", 1, true) ~= nil,
    "the test-release-notices recipe does not compare the SBOM's digests "
        .. "against the manifest's.  The two are written by different targets "
        .. "over different lists, so a rebuild that refreshed one and not the "
        .. "other ships two integrity records that contradict each other while "
        .. "every gate in this project stays green.")
-- The third reader of a prerequisite list in this file, and the third that had
-- to guess how many lines the rule was written across: this one read a single
-- line, which is right today because `test-release-notices:` happens to fit on
-- one.  It is the same belief as §3 and §6f and it converges on the same
-- reader, because three correct-by-coincidence readers and one wrong reader is
-- not four reasons to keep guessing.
local notices_list, notices_refusal = makefile_api.prerequisites_of("test-release-notices")
assert(notices_list ~= nil,
    "`make test-release-notices` could not be read: "
        .. (notices_refusal or "the reader refused without saying why"))
assert(("\n" .. table.concat(notices_list, "\n") .. "\n"):find("\nsbom\n", 1, true) ~= nil,
    "`make test-release-notices` does not depend on `sbom`, so the comparison "
        .. "would run against whatever document happened to be in dist/ -- or "
        .. "against none at all")

-- 5b. The bundle is asked to carry them, and the aggregate gate runs that
--     question.  `test-release-notices` is the target; without it in test-all
--     the bundle's notices would only ever be checked by a person who happened
--     to run `make bundle-dir`.
--
--     The copy itself is checked here because nothing else would notice it
--     going away.  Every unit fixture builds its own notices, so the SBOM tests
--     would stay green with the real bundle carrying none, and
--     `test-release-notices` only runs in `make test-all` and in CI -- which is
--     the same "only a person remembers" gap this file was written about.
local bundle_dir_recipe = recipe_of(makefile, "bundle-dir")
assert(bundle_dir_recipe:find("$(RELEASE_LICENCE) dist/wtop/$(RELEASE_LICENCE)", 1, true) ~= nil,
    "the bundle-dir recipe does not copy the project's licence into the "
        .. "bundle, so the release is documented as EUPL-1.2 with no file "
        .. "carrying those terms:\n" .. bundle_dir_recipe)

-- This used to be asked of `recipe_of`, which is the wrong question twice
-- over: whether `test-all` runs a gate is a question about its
-- *prerequisites*, and `test-all` is an aggregate with no recipe at all.  It
-- passed only because the reader also misread a continued prerequisite list as
-- a recipe, so the word it was looking for arrived attached to the wrong kind
-- of line.  Fixing either defect alone would have broken this clause, which is
-- the part worth remembering: two mistakes can hold a line of reasoning up.
-- The question is now asked of make, through the same reader §6f uses.
local test_all_gates, test_all_gates_refusal = makefile_api.prerequisites_of("test-all")
assert(test_all_gates ~= nil,
    "`make test-all` could not be read: "
        .. (test_all_gates_refusal or "the reader refused without saying why"))
local test_all_requires_notices = false
for _, gate in ipairs(test_all_gates) do
    if gate == "test-release-notices" then test_all_requires_notices = true end
end
assert(test_all_requires_notices,
    "`make test-all` does not run test-release-notices, so the question "
        .. "whether the release ships its own licence text is asked only by "
        .. "whoever thinks to ask it")

-- 5c. The repository's own third-party notice must not name a path the release
--     does not contain.  THIRD_PARTY.md said the Lua licence text travelled
--     "as part of the Lua source distribution under lua-src/doc/", and no
--     bundle has ever held a lua-src directory -- the text is at
--     .luai/licenses/Lua-MIT.txt, and nothing checked either claim.  That is
--     the sixth occurrence of this project's recurring shape, and the only one
--     where the claim lived in a file a distributor reads *instead of* a
--     generated document.
--
--     The convention this relies on is stated in the file itself: a path in
--     backticks is one the release contains, and a path in quotes is being
--     discussed rather than shipped.  That is what lets the check be total
--     rather than filtered -- an earlier version of it matched only
--     ".luai/licenses/", and substituting a wrong path outside that prefix
--     passed, which is the guard-covering-only-the-sentence-it-knows-about
--     failure this project has now hit in two different guards.
local third_party = read_file("THIRD_PARTY.md")
local generator = read_file("tools/make_sbom.py")
local checked_paths = 0
for stated in third_party:gmatch("`([^`]+)`") do
    local is_path = stated:find("/", 1, true) ~= nil
        and stated:match("^make%f[%s]") == nil
        and stated:match("^https?://") == nil
    if is_path then
        checked_paths = checked_paths + 1
        -- A directory is named with its trailing slash in prose; the build
        -- rules name it with a file inside it, so compare on the bare name.
        local bare = stated:gsub("/$", "")
        assert(generator:find(bare, 1, true) ~= nil
            or makefile:find(bare, 1, true) ~= nil
            or exists(bare),
            "THIRD_PARTY.md names " .. stated .. " in backticks, which this "
                .. "file promises is a path the release contains -- and nothing "
                .. "in tools/make_sbom.py, the Makefile or the tree accounts "
                .. "for it.  That is how this file came to claim a lua-src "
                .. "directory that no bundle has ever contained.")
    end
end
assert(checked_paths > 0,
    "no path in THIRD_PARTY.md was checked, so the clause above is passing "
        .. "vacuously; the file has lost the backticked paths it used to carry")

-- 5d. CI publishes them.  This is the clause that would have caught the whole
--     thing: the notices were in the bundle for the entire time, and both jobs
--     still shipped a release without them.  A notice that exists in dist/ and
--     is not in an upload path is not a release artifact, it is a build
--     byproduct.
--
--     This checks the upload path rather than the workflow text, which is the
--     difference the whole of section 6 is about.  The first version searched
--     the file for the notice's name, so a run step that merely mentioned it --
--     `cat dist/wtop/LICENSE` to see whether the bundle copied it -- satisfied a
--     clause whose own comment says "not in an upload path".
for _, notice in ipairs({ "dist/wtop/LICENSE",
                          "dist/wtop/THIRD_PARTY_NOTICES.md",
                          "dist/wtop/.luai/licenses/" }) do
    assert(publisher_of(notice, published) ~= nil,
        ".github/workflows/ci.yml never uploads " .. notice .. ", so a release "
            .. "produced by CI carries no readable statement of the terms it is "
            .. "distributed under.  The gate in docs/PLAN.md §9 names the "
            .. "notices as release artifacts; they were in the bundle and in "
            .. "neither upload path.")
end

-- ---------------------------------------------------------------------------
-- 6. The evidence has to leave the runner.
--
--    The fifth occurrence, and the first one about a document produced by CI
--    and then thrown away.  The aarch64 job ran `make baseline
--    BASELINE_OUTPUT=dist/BASELINE-arm64.txt`, the target exists, the recipe
--    writes the file, the step is green -- and no upload step mentioned it, so
--    the only record that the release was measured on the architecture
--    README.md calls the release target was a file on a runner that was
--    deleted.  The same workflow publishes the x86_64 baseline from another job
--    and the bundle from a third, so the shape is not "CI forgets to publish";
--    it is one named output with no destination.
--
--    Two clauses, because they fail differently.
--
--    6a resolves what each `make` invocation actually produces -- the override
--    on the command line, or the Makefile's default when there is none -- and
--    requires each of those paths to be published.  It reads the Makefile for
--    the answer, so it cannot pass vacuously: `make baseline` resolves to
--    dist/BASELINE.txt whether or not the workflow ever writes that path down.
--
--    6b is the wider net: every path under dist/ that the workflow names at
--    all, published or not.  Its limit is worth stating rather than hiding --
--    a hardcoded producer path that the workflow stops naming anywhere is no
--    longer 6b's business, and 6a only covers outputs the Makefile routes
--    through a variable.  dist/SBOM.cyclonedx.json is written by the sbom
--    recipe rather than by a variable, so what keeps it honest today is §5d --
--    a clause that names it and requires an upload to publish it -- not 6a.

-- Non-vacuity, in three parts: a reader that stops finding uploads, or stops
-- finding make invocations, must not turn the clauses below into a pass.  Each
-- one silently succeeding would be enough to hide the defect.
assert(#published > 0,
    "no upload path was found in .github/workflows/ci.yml, so every clause "
        .. "below is passing for the wrong reason.  Either the workflow stopped "
        .. "publishing anything -- in which case the release ships no evidence "
        .. "at all -- or this reader no longer understands the file.")
-- And nothing in those paths is a comment.  Everything under a `key: |` is
-- literal text, so a paragraph of prose written there to explain the upload is
-- a list of filenames to GitHub: it goes looking for a file called "# The gate
-- in docs/PLAN.md", does not find one, and says so in the log of every release
-- run.  This project's release upload carried exactly such a paragraph for an
-- increment, and nothing complained, because an upload step that finds no file
-- for one of its paths warns rather than fails.
for _, entry in ipairs(published) do
    assert(not entry.path:match("^#"),
        "the " .. tostring(entry.artifact) .. " artifact publishes a path that "
            .. "begins with `#`: " .. entry.path .. ".  Inside a `path: |` block "
            .. "a `#` is not a comment, it is the first character of a filename "
            .. "-- move the explanation above the block.")
end
local prose = prose_in_path_blocks(workflow_raw)
assert(#prose == 0,
    "these lines sit inside a `path: |` block in .github/workflows/ci.yml and "
        .. "begin with `#`, which makes them filenames rather than comments: "
        .. table.concat(prose, " / ") .. ".  An upload step that finds no file "
        .. "for one of its paths warns rather than fails, so this ships as noise "
        .. "in every run of that job.")
assert(#make_invocations(workflow) > 0,
    "no `make` invocation was found in .github/workflows/ci.yml, so clause 6a "
        .. "has nothing to resolve and is passing vacuously")

-- 6a. What CI makes, somebody receives.
--
--     The resolution is a named function rather than inline code so that 6c can
--     pin it on a fixture.  Inlined, a mutation that threw away the command-line
--     override still passed the whole file: `make baseline
--     BASELINE_OUTPUT=dist/BASELINE-arm64.txt` would have resolved to the
--     Makefile's default dist/BASELINE.txt, which *is* published by another
--     job, and the guard would have gone on reporting that the aarch64 evidence
--     is delivered -- while checking a file that job never writes.
local function resolved_outputs(makefile_text, invocation)
    local outputs = {}
    for _, target in ipairs(invocation.targets) do
        -- "No such target" and "no recipe" are different answers and only one
        -- of them is a defect.  `toolchain: $(LUA_STAMP)` has no recipe and
        -- writes nothing itself, which is the truth about what CI runs; a
        -- target the Makefile does not declare means the invocation could not
        -- be resolved at all, and the clause below would then be reasoning
        -- about a target that does not exist.
        assert(makefile_text:find("\n" .. target .. ":", 1, true) ~= nil,
            "CI runs `make " .. target .. "` and the Makefile declares no such "
                .. "target, so what that invocation produces cannot be resolved "
                .. "and the checks below are reasoning about nothing")
        local recipe = recipe_of(makefile_text, target)
        local resolved = {}
        for name in recipe:gmatch("%$%(([A-Z_0-9]+)%)") do
            if name:match("OUTPUT$") then
                local path, from = invocation.overrides[name], nil
                if path == nil then
                    path = variable_of(makefile_text, name)
                    from = "the Makefile's default for " .. name
                    assert(path ~= "",
                        "CI runs `make " .. target .. "`, its recipe writes $("
                            .. name .. "), the command line does not name that "
                            .. "variable and the Makefile declares no default for "
                            .. "it -- so this invocation has no file to produce "
                            .. "and nothing can say whether it is published")
                else
                    from = name .. "=" .. path .. " on the command line"
                end
                resolved[name] = { path = path, from = from,
                                   via_override = path ~= variable_of(makefile_text, name) }
            end
        end
        for _, entry in pairs(resolved) do
            entry.target = target
            outputs[#outputs + 1] = entry
        end
    end
    return outputs
end

local resolved_evidence = {}
for _, invocation in ipairs(make_invocations(workflow)) do
    for _, entry in ipairs(resolved_outputs(makefile, invocation)) do
        resolved_evidence[#resolved_evidence + 1] = entry
        local target = entry.target
        assert(publisher_of(entry.path, published) ~= nil,
            "CI runs `make " .. target .. "` with " .. entry.from
                .. ", which puts its evidence in " .. entry.path
                .. ", and no upload step publishes that path.  A document "
                .. "written on a runner and not uploaded is not evidence: it "
                .. "is a build byproduct that happens to contain a verdict. "
                .. "This is the state dist/BASELINE-arm64.txt spent its "
                .. "entire life in -- produced by the aarch64 job, named in "
                    .. "that job's run step, and received by nobody.")
    end
end

-- The floor those assertions rested on.
--
-- The obvious way to say "the loop above covered every invocation" is to count
-- the targets and compare with the number the reader found.  That count is
-- worthless here and the mutation battery is what showed it: both sides of the
-- comparison come from the same list, so a change that narrows the loop to one
-- invocation narrows the expectation too, and the two stay equal.  A guard
-- whose coverage check is satisfied by the same mistake as the thing it covers
-- is worse than no coverage check, because it reads like one.
--
-- What survives is a floor on the *shape* of the resolution rather than on its
-- size: an output can be named two ways -- overridden on the command line, or
-- left to the Makefile's default -- and a loop that reached neither is not
-- looking at CI, it is looking at part of it.  ci.yml uses both, once each.
local via_override, via_default = 0, 0
for _, entry in ipairs(resolved_evidence) do
    if entry.via_override then
        via_override = via_override + 1
    else
        via_default = via_default + 1
    end
end
assert(via_override > 0 and via_default > 0,
    "clause 6a resolved " .. via_override .. " outputs named on the command "
        .. "line and " .. via_default .. " left to a Makefile default; CI names "
        .. "its evidence both ways, so a run that resolves neither has stopped "
        .. "looking at most of the workflow and says nothing")

-- 6b. Every dist/ path the workflow names, published.
--
--     This is the clause that survives the next named evidence: nobody has to
--     add it here, because a path only reaches this test by being written in
--     the workflow, and if the workflow writes it, the workflow has to say who
--     gets it.
local named_paths = {}
for token in workflow:gmatch("dist/%S+") do
    named_paths[token] = true
end
assert(next(named_paths) ~= nil,
    "no path under dist/ appears anywhere in .github/workflows/ci.yml, so 6b "
        .. "is passing vacuously")
local orphans = {}
for path in pairs(named_paths) do
    if publisher_of(path, published) == nil then
        orphans[#orphans + 1] = path
    end
end
table.sort(orphans)
assert(#orphans == 0,
    ".github/workflows/ci.yml names these paths and no upload step publishes "
        .. "them: " .. table.concat(orphans, ", ") .. ".  Either publish them or "
        .. "stop naming them; what CI does with a file is not evidence about the "
        .. "release.")

-- 6c. An artifact that publishes the integrity manifest must publish the files
--     the manifest names.
--
--     The eleventh occurrence, and the one that undoes part of the fifth.  Both
--     upload steps carried `dist/SHA256SUMS` and neither carried what the
--     manifest is a manifest *of*.  Unpacked and run, `sha256sum -c SHA256SUMS`
--     read five of seven entries in the release-artifacts artifact and one of
--     seven in wtop-bundles, exiting 1 in both cases -- and the test that pins
--     this manifest (`make test-release-notices`) passes, because it runs inside
--     the build tree, where all seven files are present by construction.  The
--     claim being checked was "a recipient can check what they got", and the
--     only run of that check in this project could never have found the defect:
--     it was measured in the one place where the answer is guaranteed.
--
--     The clause asks the Makefile which files ship rather than naming them
--     here, so `RELEASE_ELFS` -- the same list `make release-baseline` measures
--     as "both shipped artifact forms" -- is the source.  A second copy of that
--     list in this file would be a second thing to forget, and the defect this
--     section is about is a list that fell behind.
--
--     The limit is worth naming: this asks that the shipped forms travel with
--     the manifest, not that the manifest's entries are individually listed.  A
--     bundle directory in the upload path covers the files inside it, which is
--     how `make checksums` discovers the notices it hashes, so publishing the
--     directory is the sufficient condition and listing files by hand is the
--     second copy again.
local MANIFEST = "dist/SHA256SUMS"
-- One place that asks make a question about the release and insists on getting
-- an answer.  `expanded` refuses rather than returning an empty string when
-- make itself fails, and before it did refuse, every caller had to write its
-- own `~= ""` guard -- which cannot tell a variable that is legitimately empty
-- from one nobody could read, and which said "the Makefile no longer declares
-- this" whether the Makefile was at fault or the question was malformed.
-- Four call sites writing the same three lines is a second contract, and this
-- is where it lives now.
local function asked(expression, question)
    local value, refusal = makefile_api.expanded(expression)
    assert(value ~= nil,
        "asking make `" .. expression .. "` did not produce an answer, so there "
            .. "is nothing to give about " .. question .. ": " .. tostring(refusal))
    return value
end
local shipped = asked("$(patsubst $(CURDIR)/%,%,$(RELEASE_ELFS))",
    "which files the integrity manifest has to travel with")
assert(shipped ~= "",
    "`RELEASE_ELFS` expands to the empty string, so the release is measured as "
        .. "shipping nothing that can be checked -- which is a different claim "
        .. "from \"the question could not be asked\", and the difference is why "
        .. "the reader above refuses rather than returning \"\"")
local manifest_artifacts = {}
for _, entry in ipairs(published) do
    if entry.path == MANIFEST and entry.artifact ~= manifest_artifacts[1] then
        manifest_artifacts[#manifest_artifacts + 1] = entry.artifact
    end
end
local checked = 0
for _, artifact in ipairs(manifest_artifacts) do
    for path in shipped:gmatch("%S+") do
        assert(publisher_of(path, published) == artifact,
            "the " .. tostring(artifact) .. " artifact publishes " .. MANIFEST
                .. " but not " .. path .. ", which is one of the files the "
                .. "manifest is a manifest of.  A recipient who unpacks that "
                .. "artifact and runs `sha256sum -c " .. MANIFEST .. "` gets a "
                .. "failed run, which is the one result the manifest exists to "
                .. "prevent -- and nothing here notices, because the check this "
                .. "project actually runs happens in the build tree where the "
                .. "file is always present.")
        checked = checked + 1
    end
end
assert(checked > 0,
    "no artifact publishes " .. MANIFEST .. ", so the clause above examined "
        .. "nothing and passed for the wrong reason")

-- 6d. A published floor has to be a floor of the release.
--
--     §6a and §6c are about delivery, and delivery is not the whole of it.  The
--     x86_64 job published dist/BASELINE.txt for as long as it has existed, and
--     that document measures $(NATIVE_MODULE) and the bootstrapped interpreter
--     under .tools/: two files that are on the runner and in no release.  The
--     document that measures what ships -- dist/BASELINE.release.txt, over
--     RELEASE_ELFS -- was produced by a target no job in this workflow had ever
--     run.  The x86_64 evidence therefore described a build host and called it
--     a release, and the two documents happened to report the same highest
--     requirement, which is why nothing looked wrong: a coincidence that reads
--     as agreement.
--
--     Both paths come from the Makefile rather than from being written here, so
--     renaming either default moves this clause with it.  The limit is worth
--     naming: this asks that the published floor come from the release ELF list,
--     not that it be internally consistent or complete -- the document's own
--     refusal to certify an incomplete run is pinned in 4a above, on the tool
--     rather than on the workflow.
local build_baseline = asked("$(patsubst $(CURDIR)/%,%,$(BASELINE_OUTPUT))",
    "where the build-host floor is written")
local release_baseline = asked(
    "$(patsubst $(CURDIR)/%,%,$(RELEASE_BASELINE_OUTPUT))",
    "where the release floor is written")
assert(build_baseline ~= "" and release_baseline ~= "",
    "the Makefile no longer declares both baseline outputs, so this clause "
        .. "cannot tell a release floor from a build floor")
-- The distinction has to be a real one, or demanding the release document says
-- nothing: if the two lists had come to name the same files, either would do.
-- Both sides go through `asked`, because `"" ~= ""` is false and would have
-- reported "the two lists now name the same files" for a pair of questions
-- nobody could answer -- a true statement about the wrong thing, which is the
-- failure this file exists to catch and which the reader's own refusal now
-- prevents rather than leaving to a coincidence of inequality.
assert(asked("$(BASELINE_ELFS)", "what the build-host floor measures")
        ~= asked("$(RELEASE_ELFS)", "what the release floor measures"),
    "BASELINE_ELFS and RELEASE_ELFS now expand to the same list, so insisting "
        .. "on the release baseline is insisting on nothing")
for _, entry in ipairs(published) do
    assert(entry.path ~= build_baseline,
        "the " .. tostring(entry.artifact) .. " artifact publishes "
            .. build_baseline .. ", which measures the files listed in "
            .. "BASELINE_ELFS -- the native module under build/ and the "
            .. "bootstrapped interpreter under .tools/, neither of which ships. "
            .. "A glibc floor stated about a build host is not a statement about "
            .. "the release, and the two documents reporting the same number is "
            .. "the reason this went unnoticed rather than a reason it is right.")
end
assert(publisher_of(release_baseline, published) ~= nil,
    "no artifact publishes " .. release_baseline .. ", which is the document "
        .. "that measures the shipped ELFs.  " .. build_baseline .. " exists for "
        .. "the same job and measures files the release does not contain, so the "
        .. "release floor is the one nobody receives.")

-- 6f. Every gate `make test-all` runs is also run by CI.
--
--     This file's section 3 argued that an evidence target missing from
--     `test-all` is one that only CI knows about.  The converse turned out to
--     be the live failure, and it is worse: `test-release-notices` was in
--     `test-all`, and `test-all` is not in the workflow, so the whole gate ran
--     only on the machine of whoever typed it.  The questions it asks -- that
--     every file the bundle ships is in SHA256SUMS, and that the SBOM and the
--     manifest agree about the same bytes -- were being asked of CI artifacts
--     by nobody.  The job that builds them ran `sbom`, `checksums` and
--     `release-baseline`: three producers and not one checker, which reads as
--     a working evidence pipeline and is not one.
--
--     The list is read from the Makefile rather than written here, and the
--     invocations are the ones clause 6a already parses, so this cannot fall
--     behind either side.  `test-all` itself is exempt because it is the
--     aggregate rather than a step; everything it requires must appear as a
--     step somewhere.
assert(makefile:match("test%-all:") ~= nil,
    "the Makefile has no test-all target, so there is no list of gates for "
        .. "this clause to compare the workflow against")
-- The list is make's answer, not a reading of the file.  It used to be
-- `makefile:match("test%-all:[^\n]*\n?[^\n]*")`, a pattern that reads exactly
-- two lines, on a rule this project writes across three -- so `test-luarocks`,
-- `test-bundle-dir` and `test-bundle-file` were never compared against the
-- workflow at all.  Those three do run in CI today, which is the only reason
-- this was dormant: the clause was reporting full coverage of a list that was
-- a third short, and the comment right below used to assert that the Makefile
-- "writes the aggregate across two lines" as though it had been checked.
local gate_list, gate_list_refusal = makefile_api.prerequisites_of("test-all")
assert(gate_list ~= nil,
    "the list of gates `make test-all` runs could not be resolved: "
        .. (gate_list_refusal or "the reader refused without saying why")
        .. "  A gate list that comes back empty is not the same as a rule that "
        .. "requires nothing, and this clause is about coverage.")
local required_gates = {}
for _, gate in ipairs(gate_list) do required_gates[gate] = true end
-- And the clause has to have compared the whole of it.  This is the assertion
-- that survives a reader going back to counting lines, and it is deliberately
-- not written as a second reading of the Makefile: comparing this clause's
-- set against make's own list cannot go stale, cannot disagree about a
-- `$(...)` expansion, and cannot itself be the truncated thing -- while a
-- re-derivation from the file text is exactly the mistake that produced the
-- gap.  It is checked before the comparison below so that a partial list fails
-- as a partial list.
for _, gate in ipairs(gate_list) do
    assert(required_gates[gate],
        "`make test-all` requires " .. gate .. " and this clause is not "
            .. "comparing it against the workflow.  A gate that CI stopped "
            .. "running has to be reported here; a gate that was never read "
            .. "off the rule cannot be, and the difference is the whole defect.")
end
local ci_runs = {}
for _, invocation in ipairs(make_invocations(workflow)) do
    for _, target in ipairs(invocation.targets) do
        ci_runs[target] = true
    end
end
-- One exemption, named rather than filtered.  `resource-check-full` is a
-- precheck, not a gate: it exists to refuse to run a heavy target on a host
-- that is already under load, and every other target in the list already pulls
-- it in transitively.  Requiring it as a step of its own would be asking for a
-- step whose only job is to refuse.  Anything added to this list has to say
-- here why it is not a gate, because "it is not really a check" is the sentence
-- this clause exists to catch people from believing.
local NOT_A_GATE = { ["resource-check-full"] = "a resource precheck, not a check" }
-- And the exemption list cannot quietly become a switch.  Two rules: every
-- entry has to say why, and none of them may be a target a release-evidence
-- tool is reached through.  A list of exceptions with no stated reason is how
-- "it is not really a check" starts being believed, and exempting the very gate
-- that was missing is the failure this clause was added for.
for name, reason in pairs(NOT_A_GATE) do
    assert(type(reason) == "string" and reason:find("%S") ~= nil,
        "this file lists " .. name .. " as exempt from the CI gate comparison "
            .. "without saying why; an exception with no stated reason is an "
            .. "exception nobody will look at again")
    -- Only the resource prechecks may be exempt, and the reason is written
    -- into the pattern rather than left to review.  The first version of this
    -- list was only checked against the release-evidence targets, and a
    -- mutation that put `test-release-notices` in it passed -- the list had
    -- become a switch for the clause, which is the one thing an exception list
    -- must not be.  If a real second exception ever appears, the honest change
    -- is to make that target a CI step rather than to widen this.
    assert(name:match("^resource%-check") ~= nil,
        "this file exempts " .. name .. " from the CI gate comparison.  Only "
            .. "the resource prechecks may be exempt: they exist to refuse to "
            .. "run a heavy target on a loaded host, and every other target "
            .. "already pulls them in.  Exempting a gate is a way of switching "
            .. "this clause off, so the answer to a gate that CI does not run is "
            .. "a step in the workflow, not a second name in this table.")
end
-- The list above is the whole of what make resolves, so there is no fragment of
-- it left out for the comparison below to miss: `prerequisites_of` reads make's
-- own database, and a rule's prerequisite list is not something a reader can
-- read partially without being wrong about it.  This clause used to carry a
-- non-vacuity check of its own -- "the list came back non-empty" -- which was
-- exactly the check that could not see the truncation, since a two-line window
-- of a three-line rule is still non-empty.
assert(next(required_gates) ~= nil and next(ci_runs) ~= nil,
    "the gate list or the workflow's invocation list came back empty, so the "
        .. "clause below would pass by comparing nothing")
local gate_never_run = {}
for gate in pairs(required_gates) do
    if not ci_runs[gate] and NOT_A_GATE[gate] == nil then
        gate_never_run[#gate_never_run + 1] = gate
    end
end
table.sort(gate_never_run)
if #gate_never_run > 0 then
    assert(false,
        "`make test-all` requires " .. table.concat(gate_never_run, ", ")
            .. ", and no step in .github/workflows/ci.yml runs "
            .. (#gate_never_run == 1 and "it" or "them") .. ".  `test-all` is "
            .. "not in the workflow either, so these run on the machine of "
            .. "whoever typed it and nowhere else: a release gate that reports "
            .. "where somebody remembered.  The workflow builds the artifacts "
            .. "-- sbom, checksums, release-baseline -- and did not ask them a "
            .. "question.")
end

-- 6g. The release-gate list must name a baseline CI actually writes.
--
--     docs/PLAN.md §9 is prose, and it sat on a claim four increments turned
--     false without anything noticing: that `make baseline` writes
--     `dist/BASELINE.txt` "produced in CI alongside the SBOM and checksums".  It
--     was true when written.  Increment 39 moved CI to `release-baseline`,
--     because the build tree's module and the bootstrapped interpreter in
--     `.tools/` ship in no release, and increment 43 took `baseline` out of
--     `test-all`; the sentence followed neither.
--
--     The narrow form is the one that can be derived: of the
--     `dist/BASELINE*.txt` paths §9 names, at least one has to be a path some
--     CI invocation resolves to.  The first version of this clause was the
--     strong form -- *every* named path -- and it fired immediately on the
--     sentence that explains the difference, because §9 is right to discuss a
--     file the pipeline does not write in order to say why that file is not the
--     gate's evidence.  A gate on a document has to be able to say what is not
--     evidence without failing.
--
--     The limit is stated rather than hidden: this asks whether the gate list
--     points at anything the pipeline writes, not whether the prose around each
--     mention is accurate, and not whether every baseline the build can produce
--     is listed.  A document that named all four possible paths and presented
--     the wrong one as its evidence would pass here, and no mechanical test
--     over prose can say otherwise.
local ci_produced = {}
for _, invocation in ipairs(make_invocations(workflow)) do
    for _, entry in ipairs(resolved_outputs(makefile, invocation)) do
        ci_produced[entry.path] = true
    end
end
local gates_section = plan_text:match("(## 9%.[^\n]*\n.-)\n## 10") or ""
assert(gates_section ~= "",
    "docs/PLAN.md no longer has a §9 release-gate section followed by a §10, so "
        .. "this clause has nothing to read and would pass for the wrong reason")
local named_baselines, any_produced = {}, false
for path in gates_section:gmatch("dist/BASELINE[A-Za-z0-9_.-]*%.txt") do
    named_baselines[path] = true
    if ci_produced[path] then any_produced = true end
end
assert(next(named_baselines) ~= nil,
    "docs/PLAN.md §9 names no baseline document at all, so this clause is "
        .. "comparing an empty list against the workflow")
if not any_produced then
    local named = {}
    for path in pairs(named_baselines) do named[#named + 1] = path end
    table.sort(named)
    assert(false,
        "docs/PLAN.md §9 names " .. table.concat(named, ", ") .. " as release "
            .. "evidence and no step in .github/workflows/ci.yml produces any of "
            .. "them.  The gate list is prose and nothing else kept it true: CI "
            .. "moved from `make baseline` to `make release-baseline` because the "
            .. "build tree ships nothing, and the sentence moved neither.  A gate "
            .. "that points only at files the pipeline stopped writing is a gate "
            .. "nobody can run.")
end

-- 6e. The reader itself, over a workflow this project does not have.
--
--     6a and 6b are only as good as a hand-written YAML reader, and a reader
--     with no fixture is the guard that only knows the one sentence it was
--     written for -- twice now in this project, and once in this very file
--     (5d, above, which searched the file for a path instead of reading the
--     upload steps).  The fixture below deliberately contains shapes ci.yml does
--     not: an inline path rather than a block scalar, a folded scalar with a
--     chomping indicator, an upload step with no name, an upload whose entry is
--     a directory rather than a file, and a run step between two uploads so the
--     step boundary has to be found rather than assumed.
local fixture = [[
jobs:
  probe:
    steps:
      # A commented-out upload: dist/never-published.txt must not be read as
      # published, or a commented-out step would satisfy the clause it was
      # commented out of.
      # - uses: actions/upload-artifact@v4
      #   with:
      #     path: dist/never-published.txt
      - uses: actions/upload-artifact@v4
        with:
          name: one
          path: |
            dist/alpha.txt
            dist/tree/
      - run: echo between uploads
      - uses: actions/upload-artifact@v4
        with:
          name: two
          path: dist/gamma.txt
      - uses: actions/upload-artifact@v4
        with:
          path: >-
            dist/delta.txt
      - run: |
          make baseline BASELINE_OUTPUT=dist/alpha.txt
          make test-pty || { echo failed; exit 1; }
      - run: make sbom checksums
]]
local fixture_published = published_paths(fixture)
assert(publisher_of("dist/never-published.txt", fixture_published) == nil,
    "a commented-out upload step was read as a real one")
assert(publisher_of("dist/never-published.txt", published_paths(fixture)) == nil,
    "the fixture above is passed to published_paths without its comments "
        .. "stripped, so the commented-out upload is real; the clauses above "
        .. "then pass for a reason this file does not claim")
-- A `#` inside a block scalar is a filename, and the reader has to treat it as
-- one: the clause on the real workflow above is only able to report that shape
-- because the path text is read without stripping, and that is worth pinning
-- rather than assuming.  The block header carries a comment of its own, which is
-- the one `#` that really is a comment -- it is on the key line, before the
-- scalar begins.
local prose_fixture = [[
steps:
  - uses: actions/upload-artifact@v4
    with:
      path: | # the evidence files
        dist/real.txt
        # an explanation that is not a comment
]]
local prose_published = published_paths(prose_fixture)
assert(#prose_published == 2,
    "a block scalar of two lines produced " .. #prose_published
        .. " published paths; a line beginning with `#` inside `path: |` is a "
        .. "filename, not a comment, and a comment on the header line is not a "
        .. "block at all")
assert(prose_published[1].path == "dist/real.txt",
    "a trailing comment on the block header hid the block: the first path read "
        .. "back as " .. prose_published[1].path)
assert(prose_published[2].path == "# an explanation that is not a comment",
    "the reader changed the text of a path rather than reporting it verbatim")
local prose_offenders = prose_in_path_blocks(prose_fixture)
assert(#prose_offenders == 1
        and prose_offenders[1] == "# an explanation that is not a comment",
    "the raw-text scan found " .. #prose_offenders .. " comment-shaped lines "
        .. "inside a `path:` block; the clause on the real workflow is only as "
        .. "good as this scan")
local kept_lines = {}
for line in prose_fixture:gmatch("[^\n]+") do
    if not line:match("^%s*#") then kept_lines[#kept_lines + 1] = line end
end
assert(#prose_in_path_blocks(table.concat(kept_lines, "\n")) == 0,
    "a path block with no prose in it still reported prose; the block boundary "
        .. "rule disagrees with published_paths'")
assert(#fixture_published == 4,
    "the workflow reader found " .. #fixture_published
        .. " published paths in a fixture with four: a block scalar of two, one "
        .. "inline, and one folded.  Either it is over-counting or it is missing "
        .. "a shape, and clause 6 is only as strong as this reader.")
assert(publisher_of("dist/alpha.txt", fixture_published) == "one",
    "a path in a block scalar was not attributed to the upload that published it")
assert(publisher_of("dist/gamma.txt", fixture_published) == "two",
    "an inline `path:` value was not read")
assert(publisher_of("dist/delta.txt", fixture_published)
        == "(an upload with no name)",
    "a folded scalar with a chomping indicator was not read, or an upload step "
        .. "with no name was attributed to the upload before it")
-- The directory entry: dist/tree/ is published as a directory, so a file under
-- it is published without being listed by name.  Nothing in ci.yml needs this
-- today, which is exactly why it needs a fixture -- an untested branch in a
-- reader is a branch that quietly stops working.
assert(publisher_of("dist/tree/inside.txt", fixture_published) == "one",
    "a directory entry in an upload path does not publish the files under it")
assert(publisher_of("dist/omega.txt", fixture_published) == nil,
    "the reader invented a published path that the fixture does not contain")
local fixture_invocations = make_invocations(fixture)
assert(#fixture_invocations == 3,
    "the make reader found " .. #fixture_invocations
        .. " invocations in a fixture with three, one of them behind a shell "
        .. "fallback")
assert(fixture_invocations[1].overrides.BASELINE_OUTPUT == "dist/alpha.txt",
    "the make reader lost a command-line override")
assert(#fixture_invocations[1].targets == 1
        and fixture_invocations[1].targets[1] == "baseline",
    "the make reader did not stop at the first target")
assert(fixture_invocations[2].targets[1] == "test-pty"
        and #fixture_invocations[2].targets == 1,
    "the make reader read the shell fallback as targets: "
        .. table.concat(fixture_invocations[2].targets, " "))
assert(#fixture_invocations[3].targets == 2
        and fixture_invocations[3].targets[2] == "checksums",
    "the make reader did not keep both targets of one invocation")
-- And the resolution itself.  The fixture's first invocation names its output
-- on the command line, and the Makefile's default for that variable is
-- dist/BASELINE.txt -- which this fixture does not publish.  So an override that
-- were silently dropped would resolve to an unpublished path and fail, which is
-- exactly the blindness the mutation found: without this assertion the guard
-- checked a file the aarch64 job never writes and called the evidence delivered.
local fixture_outputs = resolved_outputs(
    read_file("Makefile"), fixture_invocations[1])
assert(#fixture_outputs == 1,
    "resolving `make baseline BASELINE_OUTPUT=dist/alpha.txt` produced "
        .. #fixture_outputs .. " output paths; the baseline recipe writes one")
assert(fixture_outputs[1].path == "dist/alpha.txt",
    "the command-line override was not the path that got resolved; the guard "
        .. "resolved " .. fixture_outputs[1].path .. " instead")

-- ---------------------------------------------------------------------------
-- 6h. The Makefile reader, over the rule it was written against.
--
--     The YAML reader above is fixture-tested because it is hand-written.  The
--     prerequisite reader went through the same problem for a different reason:
--     `makefile_api.prerequisites_of` shells out to make, so it cannot truncate
--     a rule -- and that is exactly why it needs pinning.  A reader that asks
--     the authoritative source has nothing left to test *if* nobody checks that
--     it is still asking, and §3, §5a and §6f all read lines instead of asking,
--     three times correctly by coincidence and once not.
--
--     The fixture is the real rule rather than a synthetic one, because the
--     defect was a property of *this* file: `make test-all` is written across
--     three lines and its last three prerequisites exist only on the third.  A
--     synthetic Makefile would prove the reader can handle a long rule; this
--     proves it handles the one that was being misread, and it fails on the day
--     someone re-wraps the rule and a reader goes back to counting lines.
local probed, probed_refusal = makefile_api.prerequisites_of("test-all")
assert(probed ~= nil,
    "reading `make test-all` failed: "
        .. (probed_refusal or "the reader refused without saying why"))
local probed_set = {}
for _, gate in ipairs(probed) do probed_set[gate] = true end
-- The three the two-line pattern dropped.  `test-bundle-file` is the one that
-- matters most: it is the last word of the rule, so it is the furthest thing
-- from the start of the line, and no fixed-width window that starts at
-- `test-all:` can reach it.
for _, late in ipairs({ "test-luarocks", "test-bundle-dir", "test-bundle-file" }) do
    assert(probed_set[late],
        "`make test-all` requires " .. late .. " and the reader did not return "
            .. "it.  These three prerequisites exist only on the third line of "
            .. "the rule; a reader that takes a fixed number of lines reports "
            .. "coverage of a list a third short, and the gate that was "
            .. "supposed to notice CI dropping one of them never saw them.")
end
-- And the marker that must not be mistaken for one.  `test-all` is named in
-- `.NOTPARALLEL`, and make 4.4 serialises such a target by inserting its own
-- `.WAIT` between the prerequisites.  A reader that passed those through would
-- report a gate no step in the workflow can ever run -- and the message would
-- be true, which is what makes it worth pinning rather than assuming.
for _, gate in ipairs(probed) do
    assert(gate ~= ".WAIT",
        "the prerequisite list came back with make's own serialisation marker "
            .. ".WAIT in it, and this clause would go on to report a target "
            .. "this project does not define as a gate no CI job runs")
end
-- An empty list and a refusal are different answers, and every caller of this
-- reader is reasoning about coverage, so it has to keep them apart.  `checksums`
-- is a real target with no prerequisites; `no-such-target-here` is not a target
-- at all, and make's answer to that is an error rather than an empty list.
local empty_list, empty_refusal = makefile_api.prerequisites_of("checksums")
assert(empty_list ~= nil and #empty_list == 0,
    "`make checksums` has no prerequisites and should read back as an empty "
        .. "list, not as a refusal: " .. tostring(empty_refusal))
local absent, absent_refusal = makefile_api.prerequisites_of("no-such-target-here")
assert(absent == nil and absent_refusal ~= nil and absent_refusal:find("%S") ~= nil,
    "a target that does not exist has to come back refused and named, because "
        .. "an empty list here means 'this rule requires nothing' to a clause "
        .. "asking what a rule covers -- and a typo in a target name is the "
        .. "cheapest way to turn a gate off")
-- The name reaches a shell, so it is checked rather than quoted.
assert(not pcall(makefile_api.prerequisites_of, "test-all; false"),
    "prerequisites_of passed a target name containing a shell separator to make "
        .. "instead of refusing it")

os.execute("rm -rf " .. scratch)
return true
