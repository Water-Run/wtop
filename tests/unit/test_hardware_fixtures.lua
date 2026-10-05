-- The hardware fixtures, over the property that makes them usable.
--
-- `tests/support/hardware_fixtures.lua` is the third shared helper under
-- `tests/support/`, it has three callers, and it had no test of its own -- the
-- same gap `test_makefile_readers.lua` and `test_fixture_fs.lua` were each
-- written for, in the other two.  A helper with callers and no test of its own
-- is one whose correctness is an accident of which callers happen to use it.
--
-- This module is different from its two siblings in one way that makes the gap
-- worse rather than better: the other two *build* things, and what they build is
-- checked against a property here.  This one *is* the evidence.  Every collector
-- test that needs hardware this project does not have takes a tree from here and
-- believes it -- the driver quirks in its header comment are the whole reason it
-- exists, because a test that agreed with a wrong unit would be worthless.  A
-- fixture that contradicts itself does not fail; it makes the test reading it
-- pass, which is the failure mode the previous helper's test was written for and
-- the reason this file asserts properties rather than examples.
--
-- So: nothing here names a path.  A list of the paths in `hwmon_coretemp` would
-- be a second copy of the fixture, free to drift from it exactly the way the
-- assertions drift when they enumerate instead of asking.  Every clause below
-- asks the filesystem what the fixture said and requires the answer to be the
-- one the fixture meant.
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Fixture = require("support.fixture_fs")
local Hardware = require("support.hardware_fixtures")
local FS = require("wtop.linux.fs")

local function check(condition, message)
  if not condition then error(message, 2) end
end

local function parent_of(path) return path:match("^(.*)/[^/]+$") end
local function leaf_of(path) return path:match("([^/]+)$") end

-- 1. The set of fixtures, discovered rather than listed.  A list here would be a
--    third copy: a fixture added to the module and forgotten here would simply
--    not be audited, and the file would go on passing.
local builders = {}
for name, value in pairs(Hardware) do
  if type(value) == "function" then builders[#builders + 1] = name end
end
table.sort(builders)
check(#builders > 0,
  "the module exports no fixture function, so the loop below audits nothing and "
    .. "this file would pass on a module that had lost every tree in it")

-- Every builder is called with no arguments.  One of them cannot be: the
-- derivative tree is the same tree one sample later and so needs the delta to
-- have advanced, and defaulting the delta to zero would make it a second name
-- for the tree it derives from.  That is not a reason to stop looking at it --
-- it is a reason to say how it is called and then audit the result like any
-- other tree -- so it is built explicitly here rather than exempted, and the
-- coverage check below is what makes the two routes equivalent.
local built, unbuilt = {}, {}
for _, name in ipairs(builders) do
  local ok, spec = pcall(Hardware[name])
  if ok then
    built[#built + 1] = { name = name, spec = spec }
  else
    unbuilt[#unbuilt + 1] = name
  end
end
check(#unbuilt == 1 and unbuilt[1] == "powercap_intel_rapl_advanced",
  "these fixtures cannot be built with no arguments: "
    .. table.concat(unbuilt, ", ") .. ".  A fixture that cannot be constructed is "
    .. "one this audit cannot reach, so it has to be built the way its callers "
    .. "build it and audited through that tree -- not skipped.")
built[#built + 1] = {
  name = "powercap_intel_rapl_advanced",
  spec = Hardware.powercap_intel_rapl_advanced(nil, 1000),
}
-- And the audit's own coverage is a property, not a hope: a builder that
-- contributes no tree is a fixture nobody looked at, and the file would go on
-- reporting what it found over the ones it did reach.  This is the shape the
-- first draft of this loop had -- `pcall`, collect what worked, say nothing
-- about what raised -- and a mutation that removed the exemption proved it: the
-- file still passed with the derivative silently dropped.
check(#built == #builders,
  "the module exports " .. #builders .. " fixtures and this audit covers "
    .. #built .. " of them, so a fixture is being exported that nothing here "
    .. "looks at.  A tree nobody audited is a tree whose driver quirks are "
    .. "believed rather than checked.")

-- A text of a whole specification.  Order-independent and cycle-safe, and it is
-- the instrument the duplicate check below rests on, so it gets a control of its
-- own: two specifications that differ must not read the same.
local function text_of(value, stack)
  stack = stack or {}
  if type(value) ~= "table" then
    if type(value) == "string" then return string.format("%q", value) end
    return tostring(value)
  end
  if stack[value] then return "<cycle>" end
  stack[value] = true
  local parts = {}
  for key, item in pairs(value) do
    parts[#parts + 1] = tostring(key) .. "=" .. text_of(item, stack)
  end
  stack[value] = nil
  table.sort(parts)
  return "{" .. table.concat(parts, ";") .. "}"
end
check(text_of({ a = 1 }) ~= text_of({ a = 2 }),
  "this file cannot tell two specifications apart, so the duplicate check below "
    .. "is the only answer it knows how to give")
check(text_of({ a = 1 }) == text_of({ a = 1 }),
  "this file reads the same specification two ways, so every check in it is void")

-- 2. A path may not answer two different ways.
--
--    `fixture_fs.read_file` consults `denied`, then `files`, then `errors`, and
--    `path_type` consulted `directories` before `links`, so a declaration that
--    named a path twice was not a contradiction the module reported -- it was a
--    declaration quietly dropped, and the fixture read as though the other one
--    had never been written.  This is the hazard `test_no_data_absence.lua`
--    already states for one fixture: an errno declaration shadowed by a file of
--    the same name looks exercised and is not.
local READING_KINDS = { "denied", "files", "errors" }
local seen_trees = {}
for _, entry in ipairs(built) do
  for first = 1, #READING_KINDS do
    for second = first + 1, #READING_KINDS do
      local one, other = READING_KINDS[first], READING_KINDS[second]
      for path in pairs(entry.spec[one] or {}) do
        check((entry.spec[other] or {})[path] == nil,
          "the fixture `" .. entry.name .. "` declares " .. path .. " as both `"
            .. one .. "` and `" .. other .. "`.  The filesystem answers `"
            .. one .. "` and discards the other, so the fixture asserts one "
            .. "thing and reads back as another.")
      end
    end
  end
  for path in pairs(entry.spec.links or {}) do
    check((entry.spec.files or {})[path] == nil,
      "the fixture `" .. entry.name .. "` declares " .. path .. " as both a link "
        .. "and a file, so whether a collector sees a symlink or a file depends "
        .. "on which of the two it asks about rather than on what the driver "
        .. "publishes.")
  end
end

for _, entry in ipairs(built) do
  local name, spec = entry.name, entry.spec
  local fs = Fixture.new(spec)

  -- 3. A file that reads by name must also appear when its directory is
  --    enumerated.  Two collectors reading the same tree -- one listing, one
  --    asking for a path -- would otherwise disagree about what exists, and both
  --    would be right about their own accessor.
  for path in pairs(spec.files or {}) do
    local parent, leaf = parent_of(path), leaf_of(path)
    check(parent and leaf,
      "the fixture `" .. name .. "` declares " .. path .. ", which is not an "
        .. "absolute leaf path, so no directory holds it.")
    local entries, err = fs:list(parent)
    check(entries,
      "the fixture `" .. name .. "` declares the file " .. path .. " but its "
        .. "directory does not list (" .. tostring(err and err.kind) .. ").")
    local found = false
    for _, entry_name in ipairs(entries) do
      if entry_name == leaf then found = true end
    end
    check(found,
      "the fixture `" .. name .. "` declares the file " .. path .. " but `"
        .. leaf .. "` is not in the listing of " .. parent .. ", so a collector "
        .. "that enumerates the directory never sees a file another can read.")
  end

  -- 4. Every declared errno is served, and serves the errno it declared.  A
  --    declaration the filesystem never reaches is a comment.
  for path, declared in pairs(spec.errors or {}) do
    local content, err = fs:read(path)
    check(content == nil and err ~= nil,
      "the fixture `" .. name .. "` declares an errno for " .. path
        .. " but that path reads back as content, so the declaration is shadowed "
        .. "and the mapping is never exercised.")
    local errno = type(declared) == "table" and declared.errno or declared
    local message = type(declared) == "table" and declared.message or "io_error"
    local expected = FS.classify_error(message, errno)
    check(err.kind == expected,
      "the fixture `" .. name .. "` declares errno " .. tostring(errno)
        .. " for " .. path .. ", which classifies as `" .. tostring(expected)
        .. "`, but the read comes back as `" .. tostring(err.kind) .. "`.")
  end

  -- 5. Same for a denial, and for the truncation flag: a declaration the
  --    filesystem does not act on is not a weaker fixture, it is a fixture that
  --    looks exercised.
  for path in pairs(spec.denied or {}) do
    local content, err = fs:read(path)
    check(content == nil and err ~= nil and err.kind == "denied",
      "the fixture `" .. name .. "` declares a denial for " .. path
        .. " but the read comes back as " .. tostring(content)
        .. " / " .. tostring(err and err.kind) .. ".")
  end
  for path in pairs(spec.truncated or {}) do
    local entries, err, cut = fs:list(path)
    check(entries,
      "the fixture `" .. name .. "` declares truncation for " .. path
        .. ", which does not list (" .. tostring(err and err.kind) .. ").")
    check(cut == true,
      "the fixture `" .. name .. "` declares truncation for " .. path
        .. " but the listing does not report it.")
  end

  -- 6. An explicit entry list that contradicts the tree is the same
  --    disagreement as (3), reached the other way round.
  for path, names in pairs(spec.dirs or {}) do
    local listed, err = fs:list(path)
    check(listed,
      "the fixture `" .. name .. "` declares an entry list for " .. path
        .. ", which does not list (" .. tostring(err and err.kind) .. ").")
    for _, wanted in ipairs(names) do
      local present = false
      for _, have in ipairs(listed) do
        if have == wanted then present = true end
      end
      check(present,
        "the entry list the fixture `" .. name .. "` declares for " .. path
          .. " names " .. tostring(wanted) .. ", which the listing does not "
          .. "contain.")
    end
  end

  -- 7. A declared link is a link, and it is a link to what it said.  This is
  --    the clause the shared filesystem used to fail: `path_type` asked
  --    `directories` first, so a class device directory -- which is a symlink,
  --    and which the fixtures declare as one precisely because it is -- came
  --    back "directory" while the product's `lstat` says "symlink".  The only
  --    consumer of that answer, `collectors/cgroup.lua`, counts a symlink as a
  --    skipped entry so it does not walk a cycle, and the one test covering it
  --    passes a private filesystem that answers "symlink" -- so the shared one
  --    was free to be wrong in the one direction that matters.
  for path, target in pairs(spec.links or {}) do
    local read_target, link_err = fs:readlink(path)
    check(read_target == target,
      "the fixture `" .. name .. "` declares " .. path .. " as a link to "
        .. tostring(target) .. " but it reads back as " .. tostring(read_target)
        .. " / " .. tostring(link_err and link_err.kind) .. ".")
    check(fs:kind(path) == "symlink",
      "the fixture `" .. name .. "` declares " .. path .. " as a link, and the "
        .. "filesystem calls it `" .. tostring(fs:kind(path)) .. "`.  A path that "
        .. "is a link and also holds declared files is a symlinked directory, "
        .. "which is what every /sys/class device directory is; the product "
        .. "answers with lstat and says symlink, and a fixture filesystem that "
        .. "disagrees with the product is asserting about a filesystem that does "
        .. "not exist.")
  end

  -- 8. Two names for one tree.  A duplicate is not a harmless extra fixture: it
  --    is a second copy of a set of facts, free to drift from the first, and a
  --    test that edited one would leave the other asserting the old thing.
  local text = text_of(spec)
  check(not seen_trees[text],
    "the fixture `" .. name .. "` is the same tree as `" .. tostring(seen_trees[text])
      .. "`, so two names here are one fact in two places and can drift apart.")
  seen_trees[text] = name
end

-- 9. And the instrument this file audits with is the one that was wrong last
--    time.  Two controls, because a link alone and a link over a directory are
--    the two cases that used to be conflated, plus the shape the product's
--    `lstat` actually distinguishes.
local link_only = Fixture.new({ links = { ["/class/dev"] = "../../devices/x" } })
check(link_only:kind("/class/dev") == "symlink",
  "a path declared only as a link is not reported as one.")
local linked_dir = Fixture.new({
  links = { ["/class/dev"] = "../../devices/x" },
  files = { ["/class/dev/attr"] = "1" },
})
check(linked_dir:kind("/class/dev") == "symlink",
  "a path that is a link and also holds declared files is not reported as a "
    .. "link, so a class device directory reads as a plain directory and the "
    .. "cycle-avoidance branch in collectors/cgroup.lua is unreachable for every "
    .. "test that uses the shared fixture.")
check(linked_dir:kind("/class") == "directory",
  "a directory that holds a link is not reported as a directory.")
check(Fixture.new({ files = { ["/plain/file"] = "1" } }):kind("/plain/file") == "regular",
  "a regular file is not reported as `regular`, which is the word the product's "
    .. "native path_type uses for S_ISREG.  A fixture filesystem with its own "
    .. "vocabulary for a product's answers cannot be checked against the product.")
check(Fixture.new({}):kind("/nowhere") == nil,
  "a path that is in no tree is reported as something rather than nothing.")

-- 10. The derivative fixture is audited through the tree it derives from, and
--     its delta is required to be real: a second sample whose counters did not
--     move is not a second sample, it is the first one under another name, and
--     any rate derived from the pair would be a division by a difference that
--     was never there.
local derivative = Hardware.powercap_intel_rapl_advanced(nil, 1000)
local base = Hardware.powercap_intel_rapl()
local function energy_of(spec)
  local total = {}
  for path, content in pairs(spec.files or {}) do
    if path:match("energy_uj$") then total[#total + 1] = path .. "=" .. content end
  end
  table.sort(total)
  return table.concat(total, " ")
end
check(energy_of(derivative) ~= energy_of(base),
  "the fixture the delta is taken from produces the same energy counters as the "
    .. "tree it derives from, so a rate derived from the pair divides by a "
    .. "difference that was never there.")
check(Hardware.powercap_intel_rapl_advanced(nil, 0) ~= nil
  and energy_of(Hardware.powercap_intel_rapl_advanced(nil, 0)) == energy_of(base),
  "a zero delta does not reproduce the base tree, so the check above is "
    .. "satisfied by any change at all rather than by the delta being applied "
    .. "where the fixture says it is.")

return true
