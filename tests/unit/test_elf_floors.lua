package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

-- What a release artifact requires is the highest glibc version among every
-- ELF image that will actually execute on the target -- not just the one at
-- offset 0.
--
-- This started as a defect found by building the onefile rather than leaving
-- the source tree as the subject.  `dist/wtop-onefile` is a luainstaller
-- launcher with the native module and the PUC Lua interpreter appended to it;
-- it extracts them and runs them at startup, so both are load-bearing on the
-- target machine.  Measuring the shipped file with objdump reports GLIBC_2.34,
-- while the interpreter embedded inside that same file requires GLIBC_2.38.
-- The artifact does not run on 2.34, and the number the obvious measurement
-- produces is wrong in the direction that hides the problem.  It is the class
-- of mistake this project has now made twice -- measuring only the native
-- module and calling it the bundle's floor was the first -- except that here
-- the unmeasured file is inside the measured one, so no directory listing and
-- no sibling path would have found it.
--
-- The onefile is a build product, so it is not present in every test context.
-- The property is pinned against a file assembled from the two real ELFs the
-- project already has, which has the same shape and needs no bundle.

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
local module_path = "build/native/wtop_native.so"
local interpreter_path = ".tools/lua-" .. lua_version .. "/bin/lua"

-- The subject is real ELF images from a real build; without them there is
-- nothing to measure floors over (a stated skip in the one suite that builds
-- nothing, a failure everywhere else).
local Artifacts = require("support.artifacts")
if not Artifacts.require_file(module_path, "the native module", "run `make native`")
    or not Artifacts.require_file(interpreter_path,
        "the packaged Lua interpreter", "run `make toolchain`") then
    return true
end

-- The two inputs must differ, or the property below has nothing to find: a
-- combined file of two images that agree cannot distinguish "reports the
-- highest" from "reports the one at offset 0".
--
-- Which of the two is higher is not fixed, and the first version of this test
-- assumed it was.  It is a property of the build host, not of the source: on
-- the packaging host the interpreter sets the release floor and the module sits
-- below it, and in the glibc 2.17 container the two swap places, with the module
-- at 2.17 and the interpreter at 2.14.  Hardcoding the packaging host's
-- arrangement made this test fail on a host where the packaging host's
-- arrangement is deliberately not the case, which says nothing about the
-- scanner.  So the expected answer is computed from the two measurements.
local function version_at_least(candidate, reference)
    local left, right = {}, {}
    for field in candidate:gmatch("%d+") do left[#left + 1] = tonumber(field) end
    for field in reference:gmatch("%d+") do right[#right + 1] = tonumber(field) end
    for index = 1, math.max(#left, #right) do
        local l, r = left[index] or 0, right[index] or 0
        if l ~= r then return l > r end
    end
    return false
end

local function quiet_floor(path)
    local output, code = run("python3 tools/elf_floors.py --quiet " .. path)
    assert(code == 0, "elf_floors.py failed on " .. path .. ":\n" .. output)
    return (output:match("(%d[%.%d]*)"))
end

local module_floor = assert(quiet_floor(module_path),
    "the native module reported no glibc floor")
local interpreter_floor = assert(quiet_floor(interpreter_path),
    "the interpreter reported no glibc floor")
assert(module_floor ~= interpreter_floor,
    "this test needs two files with different floors, and both are now "
        .. module_floor .. "; pick another pair or the property is untested")

-- A plain ELF reports its own floor, and finding nothing inside it is the
-- expected answer rather than a scan that failed to look.
local plain = run("python3 tools/elf_floors.py " .. module_path)
assert(plain:find("embedded ELF images found: 0", 1, true) ~= nil,
    "a plain shared object must be reported as carrying no ELF image:\n" .. plain)

-- The assembled file has the shape of a onefile: the *lower*-requirement image
-- at offset 0 with the higher-requirement one appended, so that a scanner
-- reading only the first image produces the other number and the test can see
-- it.  Which file that is depends on the host, so the order is decided here
-- rather than assumed.
local lower, higher = module_path, interpreter_path
local lower_floor, higher_floor = module_floor, interpreter_floor
if version_at_least(module_floor, interpreter_floor) then
    lower, higher = interpreter_path, module_path
    lower_floor, higher_floor = interpreter_floor, module_floor
end

local combined = "build/native/.wtop-embedded-baseline.so"
local written, message = os.execute("cat " .. lower .. " " .. higher
    .. " > " .. combined)
assert(written == true, "could not assemble the fixture: " .. tostring(message))

local combined_floor = assert(quiet_floor(combined),
    "the assembled file reported no glibc floor")
assert(combined_floor == higher_floor,
    "the floor of a file is the highest among the ELFs it carries, so appending "
        .. "an image that needs " .. higher_floor .. " to one that needs "
        .. lower_floor .. " must report " .. higher_floor .. ", not "
        .. lower_floor .. " -- reporting only the image at offset 0 is the "
        .. "defect this test exists for")

local report = run("python3 tools/elf_floors.py " .. combined)
assert(report:find("embedded ELF images found: 1", 1, true) ~= nil,
    "the appended image must be counted, so that a bundler compressing its "
        .. "payload and hiding the images shows up as a zero rather than as a "
        .. "quietly lower floor:\n" .. report)
assert(report:find("the file itself", 1, true) ~= nil
    and report:find("embedded ELF at +", 1, true) ~= nil,
    "the report must distinguish the file from what it carries:\n" .. report)

os.remove(combined)

-- A file that is not an ELF has no floor to claim, and saying "2.2.5" or
-- "none found" would be a guess in the one place a guess is least welcome.
local not_elf = "build/native/.wtop-not-an-elf"
local handle = assert(io.open(not_elf, "wb"))
handle:write("this is not an ELF image")
handle:close()
local _, not_elf_code = run("python3 tools/elf_floors.py " .. not_elf)
assert(not_elf_code ~= 0, "a file that is not an ELF must not report a floor")
os.remove(not_elf)

-- --quiet exists so the gate can read one number, and with more than one file
-- there is no single answer: it would answer with whichever came last and look
-- authoritative.  Refusing is the only honest response, and an untested refusal
-- is the same problem as an untested guard anywhere else in this project.
local _, ambiguous_code = run("python3 tools/elf_floors.py --quiet "
    .. module_path .. " " .. interpreter_path)
assert(ambiguous_code ~= 0,
    "--quiet must refuse more than one file rather than print one of the two "
        .. "floors as if it were the pair's")

return true
