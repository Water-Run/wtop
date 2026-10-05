-- ENODATA is an attribute that exists and holds no value, not a failed read.
--
-- The development host answers with it for every `intel-rapl` zone, in two
-- places that are not a driver quirk but a statement about the hardware: a
-- `peak_power` constraint is an instantaneous ceiling with no time window to
-- publish, and a core or uncore sub-zone has no maximum power.  Both attributes
-- are present, both open successfully, and both return "no data available" --
-- which the errno table did not know, so it fell through to `io_error` and every
-- reader of an optional attribute recorded a read failure.  On this host that
-- was four of the eight issues on the powercap zones, all of them describing
-- files the driver had opened and had nothing to put in.
--
-- The fixture is declared by errno and classified through the real
-- `FS.classify_error`, so what is under test is the mapping rather than a
-- conclusion the fixture asserts back at the collector.
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local FS = require("wtop.linux.fs")
local Powercap = require("wtop.collectors.powercap")
local Fixture = require("support.fixture_fs")
local Hardware = require("support.hardware_fixtures")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

local function check(condition, message)
  if not condition then error(message, 2) end
end

local function find(list, predicate)
  for _, value in ipairs(list or {}) do
    if predicate(value) then return value end
  end
  return nil
end

-- 1. The mapping itself.  ENODATA is the kernel declining to state a figure, so
--    it joins the word the optional-attribute readers already treat as "not
--    published".  A read that really did fail is untouched by that.  ENOSPC is
--    the witness here rather than EIO, because errno 5 is deliberately mapped to
--    `denied` in this table for Win32's ERROR_ACCESS_DENIED and has been since
--    before this change.
equal(FS.classify_error("read: No data available", 61), "unavailable",
  "ENODATA is not an I/O error")
equal(FS.error_status({ kind = FS.classify_error("read: No data available", 61) }),
  "unavailable", "ENODATA does not report as an error status")
equal(FS.classify_error("read: No space left on device", 28), "io_error",
  "a read that failed for a real reason is still an I/O error")
equal(FS.classify_error("open: Permission denied", 13), "denied",
  "EACCES is still denied")
equal(FS.classify_error("no such file", 2), "missing", "ENOENT is still missing")

-- 2. The collector's response.  Nothing about the zone changes except that the
--    false errors are gone: the constraints the driver *did* state keep their
--    figures, and an entirely readable zone is not degraded.
local rapl = Powercap.new({ fs = Fixture.new(Hardware.powercap_intel_rapl_no_data()) })
local sample = rapl:sample({})
equal(sample.status, "ok", "powercap sample status")
local by_id = sample.data.by_id
local package = assert(by_id["intel-rapl:0"])
local core = assert(by_id["intel-rapl:0:0"])
local uncore = assert(by_id["intel-rapl:0:1"])

for _, zone in ipairs({ package, core, uncore }) do
  -- The collector always publishes an issues list, empty rather than absent, so
  -- the claim under test is that nothing landed in it -- and that the zone's own
  -- quality followed, which is the part a panel and the export both read.
  equal(#zone.issues, 0,
    zone.id .. " records an issue for an attribute the driver declined to state")
  equal(zone.quality, "fresh",
    zone.id .. " is degraded by a read that never failed")
end

-- The peak constraint keeps the limit it does state; only the window it has no
-- figure for is absent.  A peak power limit is an instantaneous ceiling, so its
-- time window is not a zero here and not an error either.
local peak = find(package.constraints, function(c) return c.name == "peak_power" end)
check(peak, "the peak constraint must be read")
equal(peak.power_limit_watts, 114, "the peak power limit is still stated")
equal(peak.time_window_seconds, nil, "a peak constraint has no time window")
equal(peak.maximum_power_watts, nil, "a zero maximum is an unset bound, not a figure")

local long_term = find(package.constraints, function(c) return c.name == "long_term" end)
equal(long_term.time_window_seconds, 31.981568, "a stated time window is still read")
equal(long_term.maximum_power_watts, 45, "a stated maximum is still read")

for _, zone in ipairs({ core, uncore }) do
  local constraint = zone.constraints[1]
  check(constraint, zone.id .. " constraint must be read")
  equal(constraint.time_window_seconds, 0.000976, zone.id .. " keeps its stated window")
  equal(constraint.maximum_power_watts, nil,
    zone.id .. " sub-zone has no maximum power and is not reported as failing to have one")
end

-- 3. A read that really did fail is still reported.  The host's own powercap
--    zones are in exactly this state -- energy_uj is root-only -- which is why
--    the live issue list went from eight entries to four and no further, and
--    the four that remain are these.
local specification = Hardware.powercap_intel_rapl_no_data()
specification.denied = { ["/sys/class/powercap/intel-rapl:0/energy_uj"] = true }
local denied = Powercap.new({ fs = Fixture.new(specification) })
local denied_sample = denied:sample({})
equal(denied_sample.status, "ok", "a denied zone still samples")
local denied_zone = assert(denied_sample.data.by_id["intel-rapl:0"])
check(denied_zone.quality == "partial",
  "a zone whose energy could not be read is no longer called degraded")
local denied_issues = 0
for _, issue in ipairs(denied_zone.issues) do
  if issue.field == "energy" then
    denied_issues = denied_issues + 1
    equal(issue.status, "denied", "the denial is reported as a denial")
  end
end
equal(denied_issues, 1, "the denied read is the zone's only issue")
equal(denied_sample.data.denied_zones, 1, "the denied zone is counted as denied")
-- The constraint figures beside the denial are untouched: losing the ability to
-- read the energy counter is not a reason to lose the limits.
local denied_peak = find(denied_zone.constraints,
  function(c) return c.name == "peak_power" end)
equal(denied_peak and denied_peak.power_limit_watts, 114,
  "the limits are still read beside a denied counter")

-- 4. The other absence still behaves as it did: a file that is genuinely absent
--    is absent too, and that path is unchanged by this one.
local absent = Powercap.new({ fs = Fixture.new(Hardware.powercap_intel_rapl_unset_bounds()) })
local absent_sample = absent:sample({})
equal(absent_sample.status, "ok", "the unset-bounds fixture still samples")
check(absent_sample.data.by_id["intel-rapl:0"], "the package zone is still read")

-- 5. The fixture has to *reach* the mapping, not merely describe it.
--
--    Sections 1 and 2 are each one half of a claim, and the join between them was
--    never tested.  Section 1 checks that ENODATA classifies as `unavailable`;
--    section 2 checks the collector's response to the fixture.  Measured, the
--    collector's response is **byte-for-byte identical** whether a path answers
--    ENODATA or is simply absent -- both yield nil for the same attribute and
--    both leave the zone's other figures untouched.  So section 2 passes with
--    the fixture's `errors` table emptied entirely: deleting all three
--    declarations left both fixture consumers green, and this file still printed
--    its closing line.  A file whose whole subject is "ENODATA is a value the
--    driver declined to state" had proved nothing of the kind, and proved it
--    confidently, which is the failure this clause closes.  The assertions
--    below sit at the filesystem boundary rather than around the collector
--    because **that is the only layer where the two are different** -- and if
--    the collector ever starts distinguishing them, this clause should move up
--    to where the difference is, not be deleted.
--
--    Nothing here names a path.  A list of the three declarations would be a
--    second copy of the fixture, free to drift from it exactly as section 2
--    drifted from the errno table.
local no_data = Hardware.powercap_intel_rapl_no_data()
local no_data_fs = Fixture.new(no_data)

-- Every declaration the fixture makes has to be one the filesystem actually
-- serves.  A path listed in `errors` that also exists in `files`, or that no
-- accessor ever asks for, leaves the mapping unexercised while looking
-- exercised.
local declared_paths = 0
for path in pairs(no_data.errors or {}) do
  declared_paths = declared_paths + 1
  local content, err = no_data_fs:read(path)
  check(content == nil and err ~= nil,
    "the no-data fixture declares an errno for " .. path .. ", but that path "
      .. "reads back as content -- the declaration is shadowed by a file of the "
      .. "same name, so the errno mapping never runs for it")
  equal(err.kind, "unavailable",
    "the errno declared for " .. path .. " does not classify as unavailable")
end
check(declared_paths > 0,
  "the no-data fixture declares no errno at all, so it is an ordinary fixture "
    .. "and the mapping this file is about is not exercised by anything")

-- A floor rather than a list.  Three is not arbitrary: the fixture names three
-- different reasons, reached in three different places in the collector -- a
-- package constraint's time window, a core sub-zone's maximum, and an uncore
-- sub-zone's maximum -- and a floor keeps holding when a path is renamed, which
-- a list of names would not.  What it cannot do is catch one of the three going
-- away while the other two remain, and no test written without naming them can:
-- a fixture that answers ENODATA twice is a different fixture, not a worse one,
-- as far as anything observable from here is concerned.
local answering = 0
for _, spec in ipairs({ no_data.files, no_data.errors }) do
  for path in pairs(spec or {}) do
    local _, err = no_data_fs:read(path)
    if err ~= nil and err.kind == "unavailable" then answering = answering + 1 end
  end
end
check(answering >= 3,
  "only " .. answering .. " paths in the no-data fixture answer unavailable.  It "
    .. "exists to reach the errno mapping through three different collector "
    .. "shapes -- a package constraint's time window, and a core and an uncore "
    .. "sub-zone's maximum power -- so fewer than three means one of those "
    .. "shapes is no longer reached at all")

-- And the fixture has to be sensitive to the thing it is for.  This is the
-- property that broke: an emptied `errors` table produced a fixture that looked
-- fine and ran everywhere.  Stated as a property so it survives a rename.
local emptied = Hardware.powercap_intel_rapl_no_data()
emptied.errors = {}
local emptied_fs = Fixture.new(emptied)
local differs = false
for path in pairs(no_data.errors or {}) do
  local _, before = no_data_fs:read(path)
  local _, after = emptied_fs:read(path)
  if (before and before.kind) ~= (after and after.kind) then differs = true end
end
check(differs,
  "clearing the no-data fixture's errno declarations changes nothing it reports, "
    .. "so the fixture cannot be the thing exercising the mapping: an ENODATA "
    .. "answer and an absent file have to read differently here, or the "
    .. "distinction this file exists to preserve is not in the tree at all")

-- 6. And the other half, which the clauses above had to assume: that the
--    collector really does collapse the two routes.  `docs/ARCHITECTURE.md` says
--    so -- "the collector's sample is identical for an attribute the driver
--    declines to state and an attribute that is simply absent" -- and that is
--    why this clause had to be written at the filesystem boundary, because the
--    boundary is the only layer where the two differ.
--
--    Measuring that took three attempts and the first two instruments were both
--    wrong in ways that would have produced a confident answer.
--
--    Increment 48's serialiser iterated `tostring(key)` into a list and read each
--    value back by that string, so every numeric key came back nil and whole
--    arrays -- the zone's `constraints`, its `issues` -- never entered the
--    comparison.  The verdict was right and the instrument was blind, which is
--    the worst of the two: a difference living in an array would have been
--    reported as identical.
--
--    The replacement that went in next was blind in a different place.  It kept
--    one `seen` set for the whole traversal and wrote "<cycle>" for anything it
--    had already walked, but the powercap sample reaches the same three zone
--    tables from two places at once -- `data.by_id[id]` and `data.zones[i]` -- so
--    which of the two renderings a zone received was decided by the order
--    `pairs` walked the hash part in, and that order is not required to match
--    between two structurally identical tables.  Measured over 200 rounds: 19
--    distinct texts for one fixed sample, and the "identical" assertion below
--    failed in 3 to 10 of them.  An assertion that agrees nineteen times in
--    twenty is a coincidence wearing a measurement's clothes.
--
--    The second defect was in the sample rather than in the serialiser.
--    `timestamp_ns`, each zone's `observed_at_ns` and `duration_ns` are wall
--    clock readings, and this host's clock is `/proc/uptime`, whose finest step
--    is 10 ms.  Two samples taken a fraction of a millisecond apart usually land
--    in the same tick -- which is why the assertion passed the first time it was
--    run, and why it failed on a later one -- and differ when they do not.  The
--    cure is the injection point the collectors already provide, `context.now_ns`
--    (`Common.now_ns`, src/wtop/collectors/common.lua:94), which pins the clock
--    rather than masking the fields it would otherwise vary.
--
--    So the serialiser below is a pure function of the value handed to it: a
--    cycle guard scoped to the ancestor chain, so a table reachable from two
--    places is expanded at both rather than once, and a held clock, so the
--    sample is a pure function of the fixture.  Each half is pinned by a control
--    that fails without it, and the purity of the pair is checked before the
--    comparison that rests on it.
-- A pure function of the value: the same value always yields the same text.
-- `stack` holds the tables on the path being walked and nothing else, so a
-- genuine cycle is still reported as one and a table reachable from two places
-- is expanded at both.  A single `seen` set for the whole traversal cannot say
-- that -- it makes the text depend on traversal order, and the sample below
-- reaches each zone from two paths.
local function serialise(value, stack)
  stack = stack or {}
  if type(value) ~= "table" then
    if type(value) == "string" then return string.format("%q", value) end
    return tostring(value)
  end
  if stack[value] then return "<cycle>" end
  stack[value] = true
  local array, map, length = {}, {}, #value
  for index = 1, length do array[index] = serialise(value[index], stack) end
  for key, item in pairs(value) do
    local is_array_slot = type(key) == "number" and key % 1 == 0 and key >= 1 and key <= length
    if not is_array_slot then map[#map + 1] = { key = tostring(key), text = serialise(item, stack) } end
  end
  table.sort(map, function(a, b) return a.key < b.key end)
  stack[value] = nil
  local parts = {}
  for _, entry in ipairs(map) do parts[#parts + 1] = entry.key .. "=" .. entry.text end
  return "[" .. table.concat(array, ",") .. "]{" .. table.concat(parts, ",") .. "}"
end

-- The control.  A serialiser that drops array entries reports a shorter array
-- as identical to a longer one, which is precisely the blindness the first
-- version of this comparison had, so it is checked directly rather than assumed.
assert(serialise({ { 1, 2, 3 } }) ~= serialise({ { 1, 2 } }),
  "this comparison cannot tell a shorter array from a longer one, so an "
    .. "identical result below would mean nothing: the instrument has to be "
    .. "watched failing before its success is evidence of anything")
assert(serialise({ { "a" }, { "b" } }) ~= serialise({ { "a" } }),
  "this comparison drops array entries, so a difference inside one of the "
    .. "zone's constraint or issue lists would read as identical")

-- The control for the second defect, on a value small enough to reason about.
-- A table reachable from two places is not a cycle, and this serialiser has to
-- say so by expanding it at both.  The powercap sample is built exactly this
-- way -- every zone is in `by_id` and in `zones` -- so a serialiser that gets
-- this wrong produces a text that depends on traversal order, and an assertion
-- built on it agrees whenever the order happens to match.
local shared = { reading = 42 }
local diamond = { by_id = { zone = shared }, zones = { shared } }
local diamond_text = serialise(diamond)
check(diamond_text:find("<cycle>", 1, true) == nil,
  "a table reachable from two places is reported as a cycle here, so the "
    .. "serialisation depends on the order the walk reached it in.  The zones "
    .. "are reachable twice each, so the text below would be a property of "
    .. "iteration order rather than of the sample")
equal(select(2, diamond_text:gsub("reading", "")), 2,
  "a table reachable from two places is expanded at only one of them, so the "
    .. "text depends on which path the walk took first")

-- ...and a real cycle still has to terminate, or the serialiser is not total.
local cyclic = { id = "loop" }
cyclic.self = cyclic
check(serialise(cyclic):find("<cycle>", 1, true) ~= nil,
  "a table that contains itself is not reported as a cycle, so this serialiser "
    .. "either does not terminate on a cyclic value or has stopped marking them")

-- The clock, held through the injection point the collectors already provide.
-- Without this the sample is not a function of the fixture: `timestamp_ns`, each
-- zone's `observed_at_ns` and `duration_ns` move with the wall clock, and this
-- host's is `/proc/uptime` with a 10 ms step, so two samples taken microseconds
-- apart agree only when they land in the same tick.  Pinning it is checked
-- directly, because the comparison below cannot tell a pinned clock from a lucky
-- one.
local HELD_CLOCK_NS = 1700000000000000000
local clock_calls = 0
local held = { now_ns = function()
  clock_calls = clock_calls + 1
  return HELD_CLOCK_NS
end }
local held_sample = Powercap.new({
  fs = Fixture.new(Hardware.powercap_intel_rapl_no_data()),
}):sample(held)
equal(held_sample.timestamp_ns, HELD_CLOCK_NS,
  "the sample's own timestamp is not the held clock, so the comparison below is "
    .. "a race against /proc/uptime rather than a measurement of the two routes")
for id, zone in pairs(held_sample.data.by_id) do
  equal(zone.observed_at_ns, HELD_CLOCK_NS,
    id .. " does not timestamp itself from the held clock, so the zone figures "
      .. "the two routes are compared on still move between samples")
end

-- And the clock has to be consulted on *every* sample the comparison takes, not
-- merely on the one above.  Pinning it once proves the collector honours the
-- injection; recording the calls proves this comparison is using it, which is
-- the difference between a held clock and a lucky one.  A sample that reached
-- the host clock instead would look fine whenever it landed in the same tick.
local function powercap_sample(spec)
  local before = clock_calls
  local text = serialise(Powercap.new({ fs = Fixture.new(spec) }):sample(held))
  check(clock_calls > before,
    "this sample was not timestamped by the clock this file injected, so its "
      .. "timestamps came from the host: two samples a fraction of a millisecond "
      .. "apart agree or disagree depending on which side of a /proc/uptime tick "
      .. "they fall, and a comparison that can do that is not measuring the two "
      .. "routes")
  return text
end

-- And with both halves in place the text has to be reproducible, which is the
-- property the earlier version lacked and the reason it could not be trusted.
-- What this catches is any other nondeterminism in the sample; the clock above
-- cannot be the cause of a failure here, because it is pinned.
local texts = {}
for _ = 1, 32 do
  texts[powercap_sample(Hardware.powercap_intel_rapl_no_data())] = true
end
local distinct = 0
for _ in pairs(texts) do distinct = distinct + 1 end
equal(distinct, 1,
  "one fixed fixture serialised to " .. distinct .. " different texts in 32 "
    .. "rounds, so the comparison below is reading the run rather than the "
    .. "sample and cannot be used to decide whether two routes agree")

local declared_spec = Hardware.powercap_intel_rapl_no_data()
local removed_spec = Hardware.powercap_intel_rapl_no_data()
removed_spec.errors = {}
-- And the two sides have to be two.  A comparison of the no-data fixture with
-- itself is `equal` by construction and would satisfy the clause below without
-- having compared anything, so the difference between the two specifications is
-- asserted before the comparison rather than assumed by it.
assert(next(declared_spec.errors) ~= nil and next(removed_spec.errors) == nil,
  "the two sides of the comparison below are the same fixture, so \"identical\" "
    .. "is guaranteed by construction and the clause is measuring nothing")
local declared = powercap_sample(declared_spec)
local removed = powercap_sample(removed_spec)
-- The control, on the real fixtures: a different tree must read as different,
-- or "identical" is the only answer this comparison knows how to give.
assert(declared ~= powercap_sample(Hardware.powercap_intel_rapl()),
  "two different powercap fixtures serialise to the same text, so the "
    .. "comparison below cannot detect a difference and its result is void")
assert(declared == removed,
  "the powercap collector's sample differs between a path that answers ENODATA "
    .. "and a path that is simply absent, so docs/ARCHITECTURE.md no longer "
    .. "describes it correctly.  If that is an improvement, it is a real one: "
    .. "the collector would be distinguishing an attribute the driver declined "
    .. "to state from an absent file, this clause's first section would move up "
    .. "from the filesystem boundary to the collector, and the document has to "
    .. "change with it rather than the two drifting apart again.")

print("ok: ENODATA is a value the driver declined to state, not a failed read")
