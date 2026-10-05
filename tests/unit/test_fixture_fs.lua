-- The fixture filesystem, over the property that makes it usable.
--
-- `tests/support/fixture_fs.lua` is depended on by a dozen test files, and it
-- had no test of its own -- the same gap `tests/unit/test_makefile_readers.lua`
-- was written for, in the other support module.  What makes this one worth a
-- test is not that it might be wrong someday; it is that it was wrong, and that
-- `merge` dropped a whole kind of declaration:
--
--   `new` read six kinds of declaration -- files, dirs, denied, links,
--   truncated, errors -- and `merge` copied five.  So every `errors`
--   declaration handed to `merge` was discarded, and not harmlessly: a driver
--   answering ENODATA reads as `unavailable` with its directory present, and the
--   same declaration after a merge reads as `missing` with no directory, which
--   is exactly what declaring no error at all produces.  A test written to model
--   "this attribute exists and holds no value" would have been asserting about
--   an absent file instead, in a project whose quality labels are built on the
--   difference between those two states.
--
-- The assertion below is deliberately *not* a list of the six names.  It is the
-- property that would have caught it: **a merge may not change what a fixture
-- says.**  A list would be a second copy of the enumeration, free to drift from
-- both functions again -- which is how the two diverged in the first place.  A
-- kind added to `KINDS` and wired into one function but not the other fails
-- here, and so does a kind nobody wired in anywhere, because each probe below
-- also has to be distinguishable from the fixture that declares nothing at all.

package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;;" .. package.path
local Fixture = require("support.fixture_fs")

-- Everything a fixture filesystem can be asked about a path, rendered as one
-- deterministic string.  Four accessors rather than one, because the kinds do
-- not fail the same way: a dropped `denied` still leaves the file readable, and
-- a dropped `truncated` still lists the right names.  Reading only `read` would
-- have missed both.
local function observe(fs, path)
    local parts = {}
    local content, err = fs:read(path)
    parts[#parts + 1] = "read=" .. (content ~= nil and ("ok:" .. content)
        or ("err:" .. tostring(err and err.kind) .. "/" .. tostring(err and err.message)))
    local target, link_err = fs:readlink(path)
    parts[#parts + 1] = "readlink=" .. (target ~= nil and ("ok:" .. target)
        or ("err:" .. tostring(link_err and link_err.kind)))
    local ok = fs:kind(path)
    parts[#parts + 1] = "kind=" .. tostring(ok)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then
        local entries, list_err, cut = fs:list(parent)
        if entries then
            local sorted = {}
            for index, name in ipairs(entries) do sorted[index] = name end
            table.sort(sorted)
            parts[#parts + 1] = "list=" .. table.concat(sorted, ",")
                .. "/cut=" .. tostring(cut == true)
        else
            parts[#parts + 1] = "list=err:" .. tostring(list_err and list_err.kind)
        end
    end
    return table.concat(parts, " | ")
end

local PROBE = "/probe/leaf"
local DIR = "/probe"

-- One probe per kind, at the same path, so a difference in the observation is
-- attributable to the kind and not to where it was declared.
local PROBES = {
    { kind = "files", spec = { files = { [PROBE] = "body" } } },
    { kind = "dirs", spec = { dirs = { [DIR] = { "leaf" } } } },
    { kind = "denied", spec = { denied = { [PROBE] = true } } },
    { kind = "links", spec = { links = { [PROBE] = "/elsewhere/target" } } },
    { kind = "truncated", spec = { truncated = { [DIR] = true },
        files = { [PROBE] = "body", ["/probe/other"] = "b" } } },
    { kind = "errors", spec = { errors = { [PROBE] = 61 } } },
}

-- Every declared kind has a probe, and every probe names a kind the module
-- lists.  Without this, a kind could be added to KINDS with no probe here, and
-- the loop below would pass over it in silence -- which is the enumeration this
-- file exists to avoid repeating.
local declared = {}
for _, kind in ipairs(Fixture.KINDS) do declared[kind] = true end
for _, probe in ipairs(PROBES) do
    assert(declared[probe.kind],
        "this file probes a declaration kind, `" .. probe.kind .. "`, that "
            .. "fixture_fs.KINDS does not list.  Either the probe is stale or the "
            .. "kind is new, and in both cases the loop below is not covering "
            .. "what the module can actually declare.")
end
assert(#PROBES == #Fixture.KINDS,
    "fixture_fs declares " .. #Fixture.KINDS .. " kinds (" ..
        table.concat(Fixture.KINDS, ", ") .. ") and this file has " .. #PROBES ..
        " probes.  A new kind needs one, or the property below is only being "
        .. "checked for the kinds that happened to exist when it was written.")

-- The property.  For each kind, and for all of them together, merging a fixture
-- has to produce a filesystem that says the same thing.
local all = {}
for _, probe in ipairs(PROBES) do
    for kind, value in pairs(probe.spec) do
        all[kind] = all[kind] or {}
        for path, entry in pairs(value) do all[kind][path] = entry end
    end
end
-- Each case names the exact argument list handed to `merge`, because a label
-- that does not match the call is a label that cannot be trusted to describe
-- what is being checked.  The `nil` and the bare `{}` are there on purpose:
-- fixtures get composed conditionally, and `select("#", ...)` is what makes a
-- missing argument distinguishable from a nil one, so a merge that counted its
-- arguments wrongly would pass every other case here.
local body = { files = { [PROBE] = "body" } }
for _, case in ipairs({
    { label = "all kinds at once", parts = { all } },
    { label = "a fixture with nothing in it", parts = { {} } },
    { label = "one fixture, nothing beside it", parts = { body } },
    { label = "a nil and an empty argument among others",
      parts = { body, nil, {}, body } },
    { label = "no arguments at all", parts = {} },
}) do
    -- "Before the merge" is the first argument, built directly.  Every case
    -- below is checked against the fixture it is actually merging, not against
    -- a common one -- a comparison against a fixed fixture would pass for any
    -- merge that returned the wrong answer *consistently*.
    local spec = case.parts[1] or {}
    local direct = observe(Fixture.new(spec), PROBE)
    local via_merge = observe(
        Fixture.new(Fixture.merge(table.unpack(case.parts, 1, #case.parts))), PROBE)
    assert(direct == via_merge,
        case.label .. ": merging the fixture changed what it says.\n"
            .. "  before merge: " .. direct .. "\n"
            .. "  after  merge: " .. via_merge .. "\n"
            .. "  A merge that drops a declaration does not produce a smaller "
            .. "fixture; it produces one that contradicts the fixture it was "
            .. "given, and for `errors` the contradiction is between a driver "
            .. "answering ENODATA and a file that is not there.")
end

-- Each kind on its own, so a failure names which one.
for _, probe in ipairs(PROBES) do
    local direct = observe(Fixture.new(probe.spec), PROBE)
    local via_merge = observe(Fixture.new(Fixture.merge(probe.spec)), PROBE)
    assert(direct == via_merge,
        "a `merge` of a fixture declaring only `" .. probe.kind .. "` changed "
            .. "what it says.\n  before merge: " .. direct
            .. "\n  after  merge: " .. via_merge)
    -- And the probe has to say something.  A kind that `new` ignores entirely
    -- would produce the same observation as an empty fixture, and the
    -- comparison above would pass for it.
    local empty = observe(Fixture.new({}), PROBE)
    assert(direct ~= empty,
        "declaring `" .. probe.kind .. "` produces the same observation as "
            .. "declaring nothing: " .. direct .. ".  The module lists this "
            .. "kind but does not act on it, so a fixture using it is asserting "
            .. "something the collector will never see.")
end

-- The specific case the defect was found through, pinned by name because it is
-- the one whose silent failure is indistinguishable from a correct fixture: an
-- attribute the driver knows about and has no value for.
local nodata = Fixture.new(Fixture.merge({ files = { ["/probe/x"] = "b" } },
    { errors = { [PROBE] = 61 } }))
local content, err = nodata:read(PROBE)
assert(content == nil and err ~= nil and err.kind == "unavailable",
    "an ENODATA error declaration that has been through `merge` no longer reads "
        .. "as unavailable: it read back as " .. tostring(content) .. " / " ..
        tostring(err and err.kind) .. ".  A driver answering \"this attribute "
        .. "exists and holds no value\" is not a driver answering \"there is no "
        .. "such file\", and the project's quality labels are built on the "
        .. "difference.")
local absent = Fixture.new({})
local _, absent_err = absent:read(PROBE)
assert(absent_err ~= nil and absent_err.kind == "missing",
    "declaring nothing at all should read as missing, so that the assertion "
        .. "above is comparing two different states rather than one: it reads "
        .. "back as " .. tostring(absent_err and absent_err.kind))

-- Later arguments win, which is the only ordering question `merge` has to
-- answer, and it is not written down anywhere.
local layered = Fixture.merge({ files = { [PROBE] = "first" } },
    { files = { [PROBE] = "second" } })
local layered_body = layered.files[PROBE]
assert(layered_body == "second",
    "a later specification should override an earlier one for the same path, "
        .. "and the merged value is " .. tostring(layered_body) .. ".  Fixtures "
        .. "are layered so a shared base can be specialised, so an override that "
        .. "does not win makes the base win instead.")

return true
