package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

-- An SBOM exists to answer one question: are these the bytes I think they are?
-- A document that cannot is worse than no document, because it is filed as
-- evidence.
--
-- The first version of tools/make_sbom.py was a working demonstration of that.
-- It took a bundle directory that did not exist, found no files in it, and wrote
-- a complete, well-formed CycloneDX 1.5 document: three components, a serial
-- number, licenses, purls, a scope of "required".  Not one hash.  The hashes
-- were the only part that needed a file to be present, so their absence changed
-- nothing about whether the tool reported success, and it printed "SBOM written"
-- and exited 0.  The result sat in dist/ from that day until this was found.
--
-- So the two things worth pinning are that it refuses rather than degrading, and
-- that the hashes it does write are the hashes of the files it was pointed at.

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

-- SHA-256 in pure Lua would be a hundred lines of bit twiddling to re-derive a
-- number the kernel already computed, so this shells out to the same tool the
-- release checklist uses.  The point of the comparison is that it comes from a
-- different invocation over the same bytes, not that the arithmetic is redone.
local function sha256(path)
    local output, code = run("sha256sum " .. path)
    assert(code == 0, "could not hash " .. path .. ": " .. output)
    return output:match("(%x+)")
end

local fixture = "build/native/.wtop-sbom-fixture"
-- Clear anything a previous run left behind before building anything.  This
-- file cleans up at the end, so a run that aborts mid-way skips that -- and the
-- next run then fails for a reason that has nothing to do with the generator:
-- `cp -a bundle unlicensed` copies *into* an existing directory, so the
-- unlicensed fixture ends up holding `unlicensed/bundle` and the licence
-- removal below finds nothing to remove.  A guard that cannot be re-run after
-- it fails is a guard whose second failure is noise.
os.execute("rm -rf " .. fixture)
os.execute("mkdir -p " .. fixture .. "/bundle/.luai/native")

-- Three files with distinguishable content, standing in for the three things a
-- release ships.  The layout mirrors the real one and the distinction is load
-- bearing: the onefile is a *sibling* of the bundle directory, not a child of
-- it.  The previous generator was given one root and looked for both entry
-- points inside it, so it could never find the onefile.  A fixture that put the
-- onefile at the root it was also given as the bundle would make that root and
-- the real one the same path, and the broken generator would pass.
local paths = {
    fixture .. "/bundle/wtop",
    fixture .. "/bundle/.luai/native/wtop_native.so",
    fixture .. "/wtop-onefile",
}
-- The onefile carries the Lua notice inside its own bytes, the way the real one
-- does, and this is what makes the two branches of "where is this text" both
-- reachable below.  A fixture whose onefile held no licence at all would make
-- every text onedir-only, and a document that claimed the onefile held the
-- project licence would pass.
local MIT_TEXT = "MIT fixture text for the PUC Lua runtime\n"
local contents = {
    "launcher bytes\n",
    "native module bytes\n",
    "onefile bytes\n" .. MIT_TEXT,
}

-- The licence texts a release has to carry for the licences it declares.  They
-- are written into every bundle fixture in this file, because the generator
-- now refuses to describe a release that does not have them -- which is the
-- behaviour under test, and also means a fixture that omits them would be
-- measuring the refusal instead of the thing it was written to measure.
local LICENCES = {
    { path = "LICENSE", bytes = "EUPL-1.2 fixture text for this project\n" },
    { path = ".luai/licenses/Lua-MIT.txt", bytes = MIT_TEXT },
    { path = ".luai/licenses/LGPL-3.0-or-later.txt",
      bytes = "LGPL-3.0-or-later fixture text\n" },
}

local function install_licences(bundle)
    for _, entry in ipairs(LICENCES) do
        local directory = entry.path:match("^(.*)/[^/]+$")
        if directory then
            os.execute("mkdir -p " .. bundle .. "/" .. directory)
        end
        local handle = assert(io.open(bundle .. "/" .. entry.path, "wb"))
        handle:write(entry.bytes)
        handle:close()
    end
end

for index, path in ipairs(paths) do
    local handle = assert(io.open(path, "wb"))
    handle:write(contents[index])
    handle:close()
end
install_licences(fixture .. "/bundle")

-- ---------------------------------------------------------------------------
-- A missing artifact is an error, and the output file must not be created at
-- all.  Writing an empty document and exiting 0 is the defect; leaving a stale
-- valid one in place is the same defect wearing a different hat, so the
-- generator is pointed at a fresh output path that must not appear.
--
-- "Refuses" is asserted as a refusal and not merely as a non-zero exit.  A
-- generator that skips its own check and goes on to open a missing file exits
-- non-zero too, on a Python traceback, and satisfies a bare `exit ~= 0` --
-- which is then the failure this test congratulates itself for catching.  So
-- the message must name what is missing, in the generator's own words, and a
-- traceback must be absent.
local function refuses(description, command)
    local output, code = run(command)
    assert(code ~= 0, description .. ": an SBOM describing nothing must not be "
        .. "reported as written, yet the generator exited 0")
    assert(not output:find("Traceback (most recent call last)", 1, true),
        description .. ": the generator refused by crashing, not by deciding.  "
            .. "A traceback happens to exit non-zero, so an exit-code assertion "
            .. "alone cannot tell a decision from an accident:\n" .. output)
    return output
end

local absent_output = fixture .. "/must-not-exist.json"
local complaint = refuses("no bundle at all",
    "python3 tools/make_sbom.py --onedir " .. fixture
        .. "/absent --onefile " .. fixture .. "/wtop-onefile --output " .. absent_output)
assert(io.open(absent_output, "rb") == nil,
    "refusing must not leave an output file behind; the previous defect was not "
        .. "that it failed but that it succeeded with nothing in it")
-- The onefile is present, so it must not be blamed; the launcher and the module
-- are not, so they must be.  Both halves matter.  A refusal that named nothing
-- is unusable and a refusal that named everything sends the reader to rebuild an
-- artifact that is already sitting there.
for _, name in ipairs({ "launcher", "module" }) do
    assert(complaint:find(name, 1, true) ~= nil,
        "the refusal does not say which artifact is absent; it names " .. name
            .. " nowhere, so the reader is told something went wrong instead of "
            .. "what to build:\n" .. complaint)
end
assert(complaint:find("onefile", 1, true) == nil,
    "the refusal blames the onefile, which is present; pointing the reader at "
        .. "an artifact that already exists is the same failure as naming "
        .. "none of them:\n" .. complaint)

-- The partial bundle is the case a generator is most tempted by, because enough
-- of it exists to hash.  One artifact absent is still one artifact
-- unaccounted for, and the document must not be written.
local partial = fixture .. "/partial"
os.execute("mkdir -p " .. partial .. "/.luai/native")
install_licences(partial)
local partial_launcher = assert(io.open(partial .. "/wtop", "wb"))
partial_launcher:write(contents[1])
partial_launcher:close()
local partial_output = fixture .. "/must-not-exist-partial.json"
local partial_complaint = refuses("a bundle missing its native module",
    "python3 tools/make_sbom.py --onedir " .. partial
        .. " --onefile " .. fixture .. "/wtop-onefile --output " .. partial_output)
assert(io.open(partial_output, "rb") == nil,
    "a bundle one file short must not produce a document; the missing file is "
        .. "exactly the one the document exists to account for")
assert(partial_complaint:find("module", 1, true) ~= nil,
    "a refusal about a partial bundle must name the module that is absent:\n"
        .. partial_complaint)

-- ---------------------------------------------------------------------------
-- The real thing, over the fixture.

local output_path = fixture .. "/sbom.json"
local generated, status = run("python3 tools/make_sbom.py --onedir " .. fixture
    .. "/bundle --onefile " .. fixture .. "/wtop-onefile --output " .. output_path)
assert(status == 0, "the SBOM generator failed over a complete fixture:\n" .. generated)

local document = read_file(output_path)
assert(document:find('"bomFormat"%s*:%s*"CycloneDX"') ~= nil,
    "the document is not CycloneDX:\n" .. document)
assert(document:find('"specVersion"%s*:%s*"1%.5"') ~= nil,
    "the document is not the declared spec version")
assert(document:find('"serialNumber"%s*:%s*"urn:uuid:') ~= nil,
    "a CycloneDX document needs a serial number")

-- Every shipped file must appear as a hash, and each must be the hash of that
-- file.  Checking only that *some* hash is present would pass on a document
-- that described the launcher and dropped the module.
local function hashes_in(document)
    local found = {}
    for algorithm, content in document:gmatch('"alg"%s*:%s*"([%w%--]+)"%s*,%s*"content"%s*:%s*"(%x+)"') do
        found[algorithm] = found[algorithm] or {}
        found[algorithm][content] = true
    end
    return found
end

local present = hashes_in(document)
assert(present["SHA-256"] ~= nil, "the SBOM carries no SHA-256 at all:\n" .. document)
for index, path in ipairs(paths) do
    local expected = sha256(path)
    assert(present["SHA-256"][expected] ~= nil,
        "the SBOM does not carry the hash of " .. path
            .. " (expected " .. expected .. "); an SBOM that omits a shipped file "
            .. "is the defect this test exists for")
end

-- The native module is compiled from this project and belongs in the document
-- as a component of its own, not as an attribute of wtop.  An earlier version
-- declared exactly the list of names it should have described and then never
-- referenced it, so the module appeared in no component at all.
--
-- Components come back from json.dumps(indent=2) at a known depth, so a component
-- object is a brace-delimited run of lines indented by four spaces.  That is what
-- lets the test check which hashes are attached to *which* component, which
-- finding the strings "wtop_native" and "wtop" somewhere in the document does
-- not: a document that described the launcher and hung the module's hash off it
-- would satisfy both of those and answer the wrong question.
local function component_block(name)
    local block, collecting = nil, false
    for line in document:gmatch("[^\n]+") do
        if line:match("^    {$") then
            collecting = true
            block = line
        elseif collecting then
            block = block .. "\n" .. line
            if line:match("^    }[,]?$") then
                -- The whole object, matched by the name inside it rather than by
                -- the indentation of any one key, so that re-indenting the JSON
                -- cannot make this helper quietly stop finding anything.
                if block:find('"name":%s*"' .. name .. '"') then
                    return block
                end
                collecting = false
                block = nil
            end
        end
    end
    return nil
end

local module_block = component_block("wtop_native")
assert(module_block ~= nil,
    "the native module is compiled from this project and must be a component:\n"
        .. document)

local module_sha = sha256(paths[2])
assert(module_block:find(module_sha, 1, true) ~= nil,
    "the wtop_native component carries no hash of the module it names; the "
        .. "module is compiled from this project and is the half of the program "
        .. "whose provenance differs from the Lua tree's, so it must be hashed "
        .. "where it is declared:\n" .. module_block)

local launcher_block = component_block("wtop")
assert(launcher_block ~= nil, "the wtop component is missing:\n" .. document)
assert(launcher_block:find(module_sha, 1, true) == nil,
    "the module's hash is attached to the wtop component.  The launcher is a "
        .. "luainstaller build product and the module is compiled from this "
        .. "repository; folding one into the other is what makes an SBOM unable "
        .. "to say which bytes came from where:\n" .. launcher_block)
for _, path in ipairs({ paths[1], paths[3] }) do
    local expected = sha256(path)
    assert(launcher_block:find(expected, 1, true) ~= nil,
        "the wtop component should carry the hash of " .. path
            .. "; it ships as both artifact forms and both hashes are its:\n"
            .. launcher_block)
end

-- The Lua runtime is linked into the launcher and embedded in the onefile
-- rather than shipped as a file, so it has no file of ours to hash.  That is a
-- fact about the packaging and belongs in the document; inventing a hash for it
-- would be worse than saying so.
assert(document:find('"lua"', 1, true) ~= nil,
    "the bundled Lua runtime must appear as a component:\n" .. document)

-- ---------------------------------------------------------------------------
-- A component version must be a real version even where there is no git history
-- to read one from -- and an assertion about that is worth nothing unless the
-- fallback is actually reached.  Run from inside this repository `git describe`
-- always succeeds, so checking the document for the string "None" here cannot
-- fail whatever the fallback is; it would be congratulating itself for catching
-- a defect that cannot occur in this environment.  The generator resolves its
-- own root from its own location, so copying it outside the tree is what makes
-- the lookup fail for real.

local outside = os.tmpname()
os.remove(outside)
os.execute("mkdir -p " .. outside .. "/tools")
os.execute("cp tools/make_sbom.py " .. outside .. "/tools/make_sbom.py")
os.execute("cp VERSION " .. outside .. "/VERSION")

-- The test's own precondition, checked rather than assumed: if git could read a
-- revision from there, the run below would prove nothing about the fallback.
local _, describe_status = run("git -C " .. outside .. " describe --always --tags")
assert(describe_status ~= 0,
    "git read a revision from " .. outside .. ", so this copy is still inside a "
        .. "repository and the run below never reaches the fallback; the test "
        .. "would pass without having checked anything")

local outside_output = outside .. "/sbom.json"
local outside_generated, outside_status = run("python3 " .. outside
    .. "/tools/make_sbom.py --onedir " .. fixture .. "/bundle --onefile "
    .. fixture .. "/wtop-onefile --output " .. outside_output)
assert(outside_status == 0,
    "the generator failed outside a build tree:\n" .. outside_generated)

local outside_document = read_file(outside_output)
assert(not outside_document:find('"version"%s*:%s*"None"', 1, true),
    "a component version serialised as None means the revision lookup failed "
        .. "and the fallback is the Python stringification of None:\n"
        .. outside_document)
assert(not outside_document:find("@None", 1, true),
    "a purl was built from a None version:\n" .. outside_document)

-- Outside a build tree the version comes from VERSION, which is the only place
-- it is written.  It used to be a literal in this script, one in
-- src/wtop/version.lua and one in the C source: three copies, and this one was
-- the least checked of the three, in the document a distributor reads to decide
-- what a release contains.
local declared = (read_file("VERSION"):gsub("%s+", ""))
assert(declared ~= nil and declared ~= "",
    "VERSION is empty, so there is no declared version to compare against")
assert(outside_document:find('"version": "' .. declared .. '"', 1, true) ~= nil,
    "outside a build tree the SBOM reports a version that is not the one in "
        .. "VERSION (" .. declared .. "):\n" .. outside_document)

-- And a tree with no VERSION is a build error rather than a guess.  A fallback
-- that invents a version is how the three copies started drifting in the first
-- place: the SBOM had one of its own, nothing compared it with anything, and a
-- release could be cut under a version the program does not report.
os.remove(outside .. "/VERSION")
local no_version_output = outside .. "/must-not-exist-no-version.json"
local no_version_report, no_version_status = run("python3 " .. outside
    .. "/tools/make_sbom.py --onedir " .. fixture .. "/bundle --onefile "
    .. fixture .. "/wtop-onefile --output " .. no_version_output)
assert(no_version_status ~= 0,
    "with no VERSION the generator still wrote a document, so its version came "
        .. "from somewhere that is not the project:\n" .. no_version_report)
assert(io.open(no_version_output, "rb") == nil,
    "a document was written from a tree that does not say what version it is")
assert(not no_version_report:find("Traceback (most recent call last)", 1, true),
    "the missing VERSION was reported as a crash rather than as a decision:\n"
        .. no_version_report)

-- The document still has to be a usable SBOM in that case, not a degraded one.
local outside_present = hashes_in(outside_document)
assert(outside_present["SHA-256"] ~= nil,
    "the out-of-tree document lost its hashes:\n" .. outside_document)
for _, path in ipairs(paths) do
    assert(outside_present["SHA-256"][sha256(path)] ~= nil,
        "the out-of-tree document does not carry the hash of " .. path .. ":\n"
            .. outside_document)
end

-- ---------------------------------------------------------------------------
-- The generator is only ever correct about the files it is pointed at, so what
-- points at it matters just as much.
--
-- The `sbom` target used to depend on `bundle-dir` and pass `--bundle
-- dist/bundle-dir`.  No rule has ever produced that directory: `bundle-dir` is a
-- target name, and what it produces is `dist/wtop`.  A path built by gluing the
-- output prefix to a target name reads exactly like a path a rule produced, and
-- nothing in the build caught it because the generator then found no files and
-- succeeded anyway.  So the rule below is the one that actually failed: a path
-- under the output directory whose final component is the name of a phony
-- target is a path nobody writes.

-- Make continuations are joined first.  `.PHONY` spans four lines here and
-- `bundle-dir` is on the third, so a line-at-a-time scan of a declaration
-- collects fifteen of the twenty-nine names and then reports that `dist/
-- bundle-dir` is not named after a phony target -- which is the one question
-- this whole guard exists to ask, answered wrongly in the negative.
local makefile = read_file("Makefile"):gsub("\\\n", " ")

local phony = {}
for line in makefile:gmatch("[^\n]+") do
    local list = line:match("^%.PHONY:%s*(.+)$")
    if list then
        for name in list:gmatch("%S+") do
            phony[name] = true
        end
    end
end
assert(next(phony) ~= nil, "no .PHONY declaration found in the Makefile; the "
    .. "guard below would have nothing to compare against and would pass "
    .. "having checked nothing")
-- `sbom` is declared on the same continuation line as `bundle-dir`, so finding
-- it is what says the scan reached past the first line of the declaration at
-- all.  Without this the guard could quietly compare against half the list.
assert(phony["sbom"] == true,
    "the phony scan stopped before the end of the .PHONY declaration and did "
        .. "not reach `sbom`; the target being audited is missing from its own "
        .. "audit, so the comparison below is not the one it claims to be")

local rule_body, prerequisites = {}, nil
local inside = false
for line in makefile:gmatch("[^\n]+") do
    if line:match("^sbom:") then
        prerequisites = line:match("^sbom:%s*(.+)$")
        inside = true
    elseif inside then
        if line:match("^\t") then
            rule_body[#rule_body + 1] = line
        else
            break
        end
    end
end
assert(prerequisites ~= nil, "the Makefile has no sbom target")

for _, required in ipairs({ "bundle-dir", "bundle-file" }) do
    -- `-` is a quantifier in a Lua pattern, so the target name has to be
    -- escaped before it is used to match one; left alone, `bundle-dir` is read
    -- as a lazy repeat and matches nothing.
    local escaped = required:gsub("%W", "%%%0")
    assert(prerequisites:match("%f[%w%-]" .. escaped .. "%f[%W]") ~= nil,
        "the sbom target does not depend on " .. required .. "; it is `"
            .. prerequisites .. "`, so the artifact that target builds is only "
            .. "there if something else happened to build it first")
end

for _, line in ipairs(rule_body) do
    for path in line:gmatch("%S+") do
        local tail = path:match("^dist/(.+)$")
        if tail then
            local first = tail:match("^([^/]+)")
            assert(not phony[first],
                "the sbom recipe is passed " .. path .. ", whose directory is "
                    .. "named after the phony target `" .. first .. "`.  No rule "
                    .. "writes it: a target name is a name, not a path, and "
                    .. "gluing it to dist/ makes a path that reads as if some "
                    .. "rule had produced it.  That is how this target came to "
                    .. "point at a directory that does not exist and describe "
                    .. "zero artifacts while reporting success.")
        end
    end
end

-- ---------------------------------------------------------------------------
-- A declared licence has to have its text in the release.
--
-- This is the same contract one level up from the hashes above.  A component
-- carrying "MIT" says the release is distributed under those terms, and the
-- only way anyone can comply with a licence is to read it.  The generator used
-- to declare EUPL-1.2, MIT and LGPL on four components while carrying none of
-- the three texts, and it reported success with the Lua MIT text taken out of
-- the bundle entirely -- the same failure the hash check exists for, one level
-- out, and just as silent.

-- Each component that declares a licence says where that text is, what it
-- hashes to, and which artifact forms hold it.  All three, because each is a
-- different claim: a path with no hash is a reference nobody can check, a hash
-- with no path says nothing about what it is a hash of, and a form list that
-- omitted the onefile would let a distributor assume a copy they do not have.
local function properties_of(component_name, key)
    local block = component_block(component_name)
    if not block then return nil end
    -- The key is escaped rather than pasted into the pattern: a bare `-` is
    -- Lua's lazy repetition operator, so "present-in" reads as "presen(t*)(in)"
    -- and silently matches nothing.  Two earlier guards in this project failed
    -- the same way.
    local escaped = key:gsub("(%W)", "%%%1")
    local value = block:match('"name"%s*:%s*"wtop:licence%-text:' .. escaped .. '"%s*,%s*"value"%s*:%s*"([^"]*)"')
    return value
end

for _, component_name in ipairs({ "wtop", "wtop_native", "lua", "luainstaller" }) do
    for _, key in ipairs({ "path", "sha256", "present-in", "covers" }) do
        assert(properties_of(component_name, key) ~= nil,
            "the " .. component_name .. " component declares a licence but does "
                .. "not say `wtop:licence-text:" .. key .. "`, so the terms it is "
                .. "distributed under are named without being locatable:\n"
                .. document)
    end
end

-- The recorded hash has to be the hash of the file it names.  Comparing the
-- document against itself would pass on a hash computed from anything.
for _, entry in ipairs(LICENCES) do
    local expected = sha256(fixture .. "/bundle/" .. entry.path)
    assert(properties_of("lua", "sha256") == expected
        or properties_of("wtop", "sha256") == expected
        or properties_of("luainstaller", "sha256") == expected,
        "no component records " .. expected .. ", the hash of "
            .. entry.path .. ", so the notice text is described but unverifiable")
end
assert(properties_of("wtop", "sha256") == sha256(fixture .. "/bundle/LICENSE"),
    "the wtop component declares EUPL-1.2 and records a hash that is not the "
        .. "hash of the licence text it names:\n" .. document)
assert(properties_of("lua", "sha256") == sha256(fixture .. "/bundle/.luai/licenses/Lua-MIT.txt"),
    "the lua component declares MIT and records a hash that is not the hash of "
        .. "the Lua licence text:\n" .. document)

-- Which forms hold the text is measured, so both branches have to appear.  The
-- fixture onefile embeds the MIT text and not the other two, so a document
-- claiming the onefile carries the project's own licence -- which is exactly
-- what the real onefile does not do -- fails here.
assert(properties_of("lua", "present-in") == "onedir,onefile",
    "the fixture onefile contains the Lua notice bytes, so the document must "
        .. "record both forms, and it records `"
        .. tostring(properties_of("lua", "present-in")) .. "`:\n" .. document)
assert(properties_of("wtop", "present-in") == "onedir",
    "the fixture onefile does not contain the project's licence text, so the "
        .. "document must not say it holds a copy there; it records `"
        .. tostring(properties_of("wtop", "present-in")) .. "`:\n" .. document)

-- And the refusal.  This fixture is a complete, buildable release with one
-- thing wrong with it: the text of the project's own licence is gone.  That is
-- the case the generator has to decline, and it has to decline the way the
-- missing-artifact case above does -- a decision, a non-zero exit, and no
-- document at all.  A document naming terms it does not carry is worse than no
-- document, because it is filed as evidence.
local unlicensed = fixture .. "/unlicensed"
os.execute("cp -a " .. fixture .. "/bundle " .. unlicensed)
assert(os.remove(unlicensed .. "/LICENSE"),
    "could not remove the licence text from the unlicensed fixture")

local unlicensed_output = fixture .. "/must-not-exist-unlicensed.json"
local unlicensed_report = refuses("a release with no copy of its own licence",
    "python3 tools/make_sbom.py --onedir " .. unlicensed
        .. " --onefile " .. fixture .. "/wtop-onefile --output " .. unlicensed_output)
assert(io.open(unlicensed_output, "rb") == nil,
    "the generator wrote an SBOM for a release that does not carry the text of "
        .. "the licence it declares on two of its four components")
assert(unlicensed_report:find("EUPL-1.2", 1, true) ~= nil,
    "the refusal does not say which licence has no text in the release:\n"
        .. unlicensed_report)
-- The two that are present must not be blamed.  A refusal that names every
-- licence sends the reader after files that are already in the bundle, which is
-- the same unusable message as naming none of them.
assert(unlicensed_report:find("MIT", 1, true) == nil,
    "the refusal blames the Lua notice, which is present in the bundle:\n"
        .. unlicensed_report)

-- The sentence saying whether the onefile carries the module's own bytes has to
-- follow the measurement rather than an assumption about how luainstaller
-- packages things.  Both branches are checked, because the branch that is not
-- taken is the one that would quietly become a lie: a future packaging change
-- that rebuilt the module would leave "carries these same bytes" in the
-- document and nothing here would notice.
local module_bytes = read_file(paths[2])
local launcher_bytes = read_file(paths[1])

local function wording_for(what_the_onefile_carries)
    local handle = assert(io.open(paths[3], "wb"))
    handle:write(what_the_onefile_carries)
    handle:close()
    local output, code = run("python3 tools/make_sbom.py --onedir " .. fixture
        .. "/bundle --onefile " .. paths[3] .. " --output " .. fixture .. "/wording.json")
    assert(code == 0, "the wording fixture did not generate:\n" .. output)
    return read_file(fixture .. "/wording.json")
end

local carrying = wording_for(launcher_bytes .. module_bytes .. "trailing bytes\n")
assert(carrying:find("carries these same bytes", 1, true) ~= nil,
    "the onefile contains the module's exact bytes, so the document may say it "
        .. "carries them, and it does not:\n" .. carrying)

local rebuilt = wording_for(launcher_bytes .. "a different build of the same source\n")
assert(rebuilt:find("carries these same bytes", 1, true) == nil,
    "the onefile does not contain the module's bytes, yet the document still "
        .. "claims it carries them.  An SBOM asserting a packaging fact it did "
        .. "not check is worse than one that says less:\n" .. rebuilt)
assert(rebuilt:find("does not carry these bytes", 1, true) ~= nil,
    "the document should say plainly that the onefile holds a different build, "
        .. "rather than merely omitting the claim:\n" .. rebuilt)

os.execute("rm -rf " .. outside)
os.execute("rm -rf " .. fixture)
return true
