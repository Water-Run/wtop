package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Clock = require("wtop.core.clock")
local JSON = require("wtop.core.json")
local Runner = require("wtop.core.runner")
local Scheduler = require("wtop.core.scheduler")
local Ring = require("wtop.model.ring")
local Snapshot = require("wtop.model.snapshot")

local function equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

equal(Clock.decimal_seconds_to_ns("12.000000345"), 12000000345)
equal(Clock.decimal_seconds_to_ns("0.5"), 500000000)
for _, invalid_time in ipairs({ "12junk", "1.2junk", "1e3", "-1", "", "1.2.3" }) do
  local parsed_time = Clock.decimal_seconds_to_ns(invalid_time)
  assert(parsed_time == nil, "invalid time accepted: " .. invalid_time)
end
assert(Clock.decimal_seconds_to_ns(math.huge) == nil)
assert(Clock.decimal_seconds_to_ns(0 / 0) == nil)
assert(Clock.decimal_seconds_to_ns(tostring(math.maxinteger)) == nil)
local uptime_values = { "10.25 20.0\n", "9.0 20.0\n", "11.0 21.0\n" }
local uptime_index = 0
local clock = Clock.new({
  read_file = function()
    uptime_index = uptime_index + 1
    return uptime_values[uptime_index]
  end,
})
equal(clock:now_ns(), 10250000000)
equal(clock:now_ns(), 10250000000, "clock must not move backwards")
equal(clock:now_ns(), 11000000000)

-- The source name is the only place the clock says where its value came from,
-- and it had no caller and no assertion: `Clock:source_name` was defined and
-- nothing in src, tests or docs ever read it.  A label nobody reads is a label
-- nobody is protected by, so the three states below are distinguished by name
-- and each one is asserted.
equal(clock:source_name(), "procfs_uptime",
  "a reading taken from /proc/uptime is named for its source")

-- 1. The default fallback is `os.clock` -- the process's own CPU time, which is
--    a different quantity on a different scale from /proc/uptime, not a second
--    copy of it.  So a single failed read after a real reading makes every
--    later candidate older than the value in hand, and the clock holds: measured,
--    a two-year uptime plus one failed read freezes every rate derived from
--    `now_ns()` at that value, for as long as the read keeps failing.  Holding is
--    the safe answer and it is the answer this keeps giving.  What was not safe
--    was the name: `process_clock_fallback` claimed the value had been
--    re-derived from the process clock when nothing had come from it at all.
local frozen_reads = 0
local frozen = Clock.new({
  read_file = function()
    frozen_reads = frozen_reads + 1
    if frozen_reads == 1 then return "63072000.42 63071900.10\n" end
    error("simulated /proc/uptime failure")
  end,
})
equal(frozen:now_ns(), 63072000420000000, "the first read comes from procfs")
equal(frozen:source_name(), "procfs_uptime")
equal(frozen:now_ns(), 63072000420000000,
  "holding the previous value is the safe answer when the new one is older")
equal(frozen:source_name(), "held",
  "a value that is the previous reading must not be named for the source that "
    .. "was not consulted; a user whose rates have frozen is reading `held`")
equal(frozen:now_ns(), 63072000420000000, "and it keeps holding while the read fails")
equal(frozen:source_name(), "held")

-- 2. A fallback on a comparable scale is a real reading from a different source,
--    and it advances.  os.clock is not one, which is clause 1's whole subject;
--    this is the shape that would be correct if the default were a monotonic
--    second clock.
local elapsed = 0
local comparable = Clock.new({
  read_file = function() error("simulated /proc/uptime failure") end,
  fallback = function() return 63072000.42 + elapsed end,
})
equal(comparable:source_name(), nil, "nothing has been read yet")
equal(comparable:now_ns(), 63072000420000000)
equal(comparable:source_name(), "process_clock_fallback",
  "a value the fallback really produced is named for the fallback")
elapsed = 0.5
equal(comparable:now_ns(), 63072000920000000, "a usable fallback advances")

-- 3. Nothing measured and nothing measurable.  0 is a placeholder the caller can
--    see through, and `unavailable` is the word this project already uses for an
--    optional reading it could not take -- rather than `held`, which would claim
--    a previous reading that does not exist.
local blind = Clock.new({
  read_file = function() error("simulated /proc/uptime failure") end,
  fallback = function() error("simulated fallback failure") end,
})
equal(blind:now_ns(), 0, "a clock with no reading at all still returns a number")
equal(blind:source_name(), "unavailable",
  "a first-ever failure is not a held value; there is nothing to hold")

local ring = Ring.new(3)
assert(not pcall(Ring.new, math.huge))
assert(not pcall(Ring.new, 1000001))
assert(ring:push("a") == nil)
ring:push("b")
ring:push("c")
equal(ring:push("d"), "a")
equal(table.concat(ring:values(), ","), "b,c,d")
ring:resize(2)
equal(table.concat(ring:values(), ","), "c,d")
ring:resize(4)
ring:push("e")
equal(ring:oldest(), "c")
equal(ring:newest(), "e")
assert(ring:get(1.5) == nil)

local now = 1000000000
local fake_clock = { now_ns = function() return now end }
local calls = 0
local scheduler = Scheduler.new({ clock = fake_clock, max_backoff_ms = 10000 })
assert(not pcall(Scheduler.new, "invalid"))
assert(scheduler:add({ id = "bad", sample = function() end }, { interval_ms = "1" }) == nil)
assert(scheduler:add({ id = "bad", sample = function() end }, { interval_ms = 1,
  background_interval_ms = math.huge }) == nil)
assert(scheduler:add({ id = "bad", sample = function() end }, "invalid") == nil)
assert(not pcall(Scheduler.new, { max_backoff_ms = 0 / 0 }))
assert(scheduler:add({
  id = "fixture",
  default_interval_ms = 100,
  sample = function(_, previous)
    calls = calls + 1
    if calls == 1 then
      return { status = "error", quality = "error", reason = "temporary" }
    end
    return { status = "ok", data = { previous = previous }, quality = "fresh" }
  end,
}))
local first = scheduler:tick()
equal(first.fixture.status, "error")
equal(scheduler:task("fixture").failures, 1)
equal(scheduler:next_delay_ms(), 100)
now = now + 100000000
local second = scheduler:tick()
equal(second.fixture.status, "ok")
equal(calls, 2)
equal(scheduler:task("fixture").failures, 0)

local base = Snapshot.new(1, 10)
base.cpu = { total = { utilization = 25 } }
local merged = Snapshot.merge(base, {
  cpu = { status = "error", quality = "error", reason = "race", timestamp_ns = 20 },
  memory = { status = "ok", quality = "fresh", data = { total_bytes = 10 }, timestamp_ns = 20 },
}, 2, 20)
equal(merged.cpu.total.utilization, 25)
equal(merged.quality.cpu.quality, "stale")
-- That assertion above is the whole of the snapshot path's `stale` rule, and it
-- says something the documentation used to contradict.  The retained value here
-- is ten nanoseconds old and it is already `stale`; `docs/MONITORING.md` §9
-- described `stale` as "a retained value exceeded its freshness deadline", which
-- is a claim about age, and the code consults no deadline.  A consumer who
-- believed the sentence would compute an age, find the value young, and conclude
-- the label was wrong.  The behaviour was pinned here and the wording was pinned
-- in a document, and nothing joined the two while they said different things.
--
-- So the behaviour is asserted again with its age stated, and the document is
-- required to say the same thing.  Neither can move alone: a real deadline added
-- to the code would fail the assertion below and force the wording to change with
-- it, and a wording change would have to keep describing what the code does.
local young_base = Snapshot.new(1, 10)
young_base.cpu = { total = { utilization = 25 } }
local young = Snapshot.merge(young_base, {
  cpu = { status = "error", quality = "error", reason = "race", timestamp_ns = 20 },
}, 2, 20)
equal(young.quality.cpu.quality, "stale",
  "a retained value that is ten nanoseconds old is no longer `stale`")
equal(young.cpu.total.utilization, 25,
  "and the retained value is still the one being shown")
-- The other half, and the one that makes the trap reachable from outside: the
-- record's own timestamp is the *attempt*, so a consumer computing staleness from
-- it gets the age of the failed read rather than of the value.
equal(young.quality.cpu.timestamp_ns, 20,
  "the quality record's timestamp is no longer the time of the attempt")
assert(young.quality.cpu.timestamp_ns - young.timestamp_ns == 0,
  "a consumer computing `now - quality[resource].timestamp_ns` on a `stale` record "
    .. "measures how long ago the last read was tried, not how old the value is: "
    .. "measured, a value 99 s old retried just now reports an age of 0 s.  See "
    .. "docs/MONITORING.md §9 and the open item in docs/PLAN.md -- nothing in the "
    .. "record states the value's own age, and a consumer cannot derive it.")
local monitoring_handle = assert(io.open("docs/MONITORING.md", "rb"),
  "docs/MONITORING.md is missing, so the quality vocabulary this file is measured "
    .. "against cannot be read")
local monitoring = monitoring_handle:read("*a")
monitoring_handle:close()
assert(monitoring:find("它是在第一个无法安装的结果上重新标注的", 1, true) ~= nil,
  "docs/MONITORING.md §9 describes `stale` as a freshness deadline again.  The "
    .. "snapshot path has no deadline: it relabels on the first result that does "
    .. "not install, so a value one sampling interval old is already `stale`.  The "
    .. "assertion above is what the sentence has to match.")
assert(monitoring:find("上一次*尝试*的时间,不是该记录所限定的值", 1, true) ~= nil,
  "docs/MONITORING.md §9 no longer says that a quality record's timestamp_ns is "
    .. "the time of the last attempt rather than of the value it qualifies, which "
    .. "is what makes a `stale` record's age read as zero")
equal(merged.memory.total_bytes, 10)
assert(merged.quality.memory.reason == nil)

-- A label this snapshot cannot publish.  The vocabulary is closed on purpose --
-- these are the words the UI, the JSON snapshot and an agent all read -- so
-- normalising an unpublishable one is right, and the only question is which way
-- it normalises.  Measured, it normalised to the permissive answer: an unknown
-- quality on an `ok` result became `fresh` while the status stayed `ok` and the
-- reason survived beside it, so the record published status ok, quality fresh,
-- and a reason saying some resources were unreadable, all at once.  A genuine
-- degradation misspelled as `partail` was published as fresh data.  The status
-- line above it already refused that direction, which is what made the quality
-- line the odd one out rather than a deliberate choice.
--
-- So the two are now one step, and this clause is about the direction: whatever
-- the label, a reading nobody can describe must never be published as `fresh`.
local function merged_cpu(result)
  local previous = Snapshot.new(1, 10)
  previous.cpu = { total = { utilization = 25 } }
  return Snapshot.merge(previous, { cpu = result }, 2, 20)
end
for _, label in ipairs({ "approximate", "partail", "", "Fresh" }) do
  local record = merged_cpu({
    status = "ok", quality = label, data = { total = { utilization = 99 } },
    reason = "some_resources_unreadable", timestamp_ns = 20,
  })
  assert(record.quality.cpu.quality ~= "fresh",
    "a quality of `" .. label .. "` is published as `fresh`, so a reading the "
      .. "snapshot cannot describe is reported as a current one.  The permissive "
      .. "answer here is the dangerous one: a collector that misspells "
      .. "`partial` loses its degradation entirely.")
  assert(record.quality.cpu.status ~= "ok",
    "a quality of `" .. label .. "` leaves the status as `ok`, so the record "
      .. "claims a working reading while carrying a label nobody publishes")
end
-- And it lands where the equivalent failure already lands, so the two refusals
-- cannot drift apart: the status fails, and the quality becomes `stale`, which is
-- what an outright failure produces.
--
-- The `stale` half is stated rather than wished for, and it carries a limit
-- worth recording.  `stale` means "a retained value that is no longer fresh",
-- and the test for whether a value was retained is `previous[resource] ~= nil` --
-- but `Snapshot.new` seeds every resource with `{}`, so that is true from the
-- first snapshot onward.  A first-ever failing sample is therefore labelled
-- `stale` with an empty table behind it.  That is the same family as the `fresh`
-- rewrite and a much smaller lie, because nothing wrong is installed and no
-- number is shown: the retained value is an empty object, and the label says the
-- shown value is old.  Deciding what "retained" means for a seeded empty table is
-- a change to the data model rather than a patch, so it is recorded here and left
-- alone; what matters for this increment is that the permissive direction is
-- gone, and the pre-fix behaviour installed the new data under a `fresh` label.
local refused = merged_cpu({ status = "ok", quality = "approximate", timestamp_ns = 20 })
equal(refused.quality.cpu.status, "error", "an unpublishable quality fails the status")
equal(refused.quality.cpu.quality, "stale",
  "an unpublishable quality becomes whatever an outright failure becomes")
equal(merged_cpu({ status = "okay", quality = "fresh", timestamp_ns = 20 })
  .quality.cpu.status, "error", "an unpublishable status is refused the same way")
-- Every published label has to pass through untouched, or the clause above would
-- be satisfiable by refusing everything.  The list is read from the module that
-- now owns it, not restated here and not scraped out of a source file: a
-- restatement is a second copy free to drift, which is how this class of defect
-- starts, and scraping a literal table out of a particular file is a guard
-- coupled to a location -- one that broke the moment the vocabulary was moved to
-- the one place it belongs, which is the right way for it to break.
local Quality = require("wtop.model.quality")
local published = {}
for value in pairs(Quality.VALID_QUALITY) do published[#published + 1] = value end
table.sort(published)
local checked = 0
for _, value in ipairs(published) do
  local record = merged_cpu({ status = "ok", quality = value, data = {}, timestamp_ns = 20 })
  equal(record.quality.cpu.quality, value, "the published quality `" .. value
    .. "` is altered on the way through")
  checked = checked + 1
end
assert(checked > 0,
  "no published quality was checked, so the clause above is satisfied by a "
    .. "refusal that would break every real reading")

-- And the vocabulary has one owner.  Measured, it had three: the snapshot model,
-- the scheduler and the inspector model each wrote their own `VALID_QUALITY`, the
-- copies had already diverged -- the snapshot published `truncated` and the other
-- two did not -- and they disagreed about what to do with a label none of them
-- publishes.  The inspector refused and named it, the scheduler rewrote it to
-- `fresh` when the status was `ok`, and the snapshot did the same until an
-- increment ago.  So this is the clause for the convergence, and it is stated as
-- a property rather than as a list: **every gate must accept every published
-- label, and refuse the same ones.**  A copy that quietly loses an entry fails
-- the first half; a copy that drifts back to the permissive direction fails the
-- second, which is the part that matters and the part no list could catch.
local Scheduler = require("wtop.core.scheduler")
local InspectorModel = require("wtop.inspectors.model")
-- The scheduler's gate is internal, so it is asked through the public path the
-- engine uses: register a collector that returns the label, tick, and read the
-- result the scheduler kept.  Exposing the normaliser for a test would be a
-- public API added for a test, and this way the clause fails if the gate moves
-- rather than quietly checking nothing.
local probe_serial = 0
local function through_scheduler(status, quality)
  probe_serial = probe_serial + 1
  local scheduler = Scheduler.new({ clock = fake_clock, max_backoff_ms = 10000 })
  local task, err = scheduler:add({
    id = "probe-" .. probe_serial,
    default_interval_ms = 1000,
    _method_style = true,
    sample = function() return { status = status, quality = quality, data = {} } end,
  })
  assert(task, "the probe collector was not registered: " .. tostring(err))
  scheduler:tick()
  return task.last_result
end
for _, value in ipairs(published) do
  local record = through_scheduler("ok", value)
  equal(record.quality, value,
    "the scheduler rewrites the published quality `" .. value .. "` into `"
      .. tostring(record.quality) .. "`, so the scheduler and the snapshot do not "
      .. "hold the same vocabulary")
  local ok_field = pcall(InspectorModel.field, 1, "W", { quality = value, timestamp_ns = 1 })
  assert(ok_field,
    "the inspector model refuses the published quality `" .. value .. "`, so the "
      .. "inspector and the snapshot do not hold the same vocabulary")
end
-- And the unpublishable ones, on both sides.  The scheduler must not answer
-- `fresh`; that is the whole of the defect this increment closes.
for _, label in ipairs({ "approximate", "partail", "Fresh", "" }) do
  local refused = through_scheduler("ok", label)
  assert(refused.quality ~= "fresh" and refused.status ~= "ok",
    "the scheduler publishes the unpublishable quality `" .. label .. "` as "
      .. tostring(refused.status) .. "/" .. tostring(refused.quality)
      .. ", so a reading it cannot describe is reported as a current one")
  assert(not pcall(InspectorModel.field, 1, "W", { quality = label, timestamp_ns = 1 }),
    "the inspector model accepts the unpublishable quality `" .. label
      .. "` that the scheduler and the snapshot refuse")
  local via_snapshot = merged_cpu({ status = "ok", quality = label, timestamp_ns = 20 })
  assert(via_snapshot.quality.cpu.quality ~= "fresh",
    "the snapshot publishes the unpublishable quality `" .. label .. "` as fresh")
end
-- And the third relation, which is the one with a trap in it: the collectors a
-- snapshot can hold.  A collector whose id is neither a slot name nor a mapping
-- entry has its data dropped by `Snapshot.merge` with no error anywhere, so the
-- question is asked of the real registry rather than of a list -- and it is asked
-- by observing the merge, because both the slot list and the id map are locals and
-- reading them here would be a second copy of the relation in a test.
--
-- Measured, all seventeen registered collectors reach a slot and none is dropped,
-- so this is a guard on a relation that holds rather than a fix for one that is
-- broken.  What it protects is the next collector: the map already carried an
-- entry for `psi`, a collector that does not exist, and that entry was a trap --
-- harmless until a collector took the id, at which point it would have resolved to
-- `pressure`, which the real one owns, and two collectors would have written one
-- slot silently.  The two clauses together are what makes that fail loudly: the
-- first notices an id that reaches nothing, the second notices one that reaches a
-- slot somebody else already has.
local Collectors = require("wtop.collectors.init")
local registered = {}
for key in pairs(Collectors.constructors) do registered[#registered + 1] = key end
table.sort(registered)
assert(#registered > 0, "the collector registry is empty, so nothing below is checked")
local owner_of_slot, resolved = {}, {}
for _, key in ipairs(registered) do
  local collector = assert(Collectors.new_all({})[key],
    "the registry names `" .. key .. "` but constructing it produced nothing")
  local id = collector.id
  assert(type(id) == "string" and id ~= "",
    "the collector registered as `" .. key .. "` has no id, so nothing can "
      .. "address its reading")
  local snapshot = Snapshot.merge(Snapshot.new(0, 1), {
    [id] = { status = "ok", quality = "fresh", timestamp_ns = 2, data = { probe = key } },
  })
  local where
  for slot, value in pairs(snapshot) do
    if type(value) == "table" and value.probe == key then where = slot end
  end
  assert(where,
    "the collector registered as `" .. key .. "` calls itself `" .. id
      .. "`, and `Snapshot.merge` dropped its data: the id is neither a snapshot "
      .. "slot nor an entry in the id map, so the reading is collected every "
      .. "interval and never shown, with nothing to say so")
  -- `assert` builds its message eagerly, and `owner_of_slot[where]` is nil for the
  -- first collector -- so the refusal is written as an explicit `if` rather than
  -- with a message that concatenates a value which only exists on failure.
  if owner_of_slot[where] then
    error("the collectors `" .. owner_of_slot[where] .. "` and `" .. key
      .. "` both write the `" .. where .. "` slot, so one of them silently "
      .. "overwrites the other.  A stale entry in the id map is how that starts: "
      .. "an alias for a collector that does not exist yet looks like a name "
      .. "until somebody takes it.", 0)
  end
  owner_of_slot[where] = key
  resolved[#resolved + 1] = key .. " -> " .. where
end
-- The loop above is the whole relation, so it has to have run: a registry that
-- resolved nothing would satisfy both clauses by having nothing to check.
assert(#resolved == #registered,
  "only " .. #resolved .. " of " .. #registered .. " registered collectors were "
    .. "resolved to a slot, so the two clauses above are weaker than they look")
-- And the direction a lookup cannot see.  The map is written by hand rather than
-- derived from the registry, so an entry naming a collector that does not exist is
-- possible -- and it is exactly the state this was found in, with `psi` mapping to
-- a slot the real `pressure` collector owns.  It is inert until somebody takes the
-- name, which is why neither of the two clauses above can see it and why the map is
-- exported for inspection: `resource_for_collector` answers where an id goes, and
-- says nothing about the entries that name nothing.
local ids_in_map = Snapshot.RESOURCE_IDS
assert(type(ids_in_map) == "table",
  "the snapshot model no longer exposes its id map, so an entry naming a "
    .. "collector that does not exist cannot be noticed at all")
local collector_ids = {}
for _, key in ipairs(registered) do
  local id = Collectors.new_all({})[key].id
  collector_ids[id] = key
end
for id in pairs(ids_in_map) do
  assert(collector_ids[id],
    "the id map has an entry for `" .. id .. "`, which is not a registered "
      .. "collector: the alias is inert today and a trap the day a collector takes "
      .. "that name, because it would resolve to the `"
      .. tostring(ids_in_map[id]) .. "` slot and overwrite whoever owns it.  The "
      .. "map is a hand-written copy of a relation the registry owns, and this is "
      .. "the direction that copy can be wrong in.")
end
-- The three gates must also agree on which statuses exist, and a gate that grew
-- its own status vocabulary would be a second copy of the same fact in a new place.
for _, status in ipairs({ "ok", "unavailable", "denied", "error" }) do
  assert(Quality.VALID_STATUS[status],
    "the shared status vocabulary lost `" .. status .. "`")
  local via_scheduler = through_scheduler(status, "fresh")
  equal(via_scheduler.status, status,
    "the scheduler rewrites the published status `" .. status .. "`")
end

local observed
local runner = Runner.new({
  default_max_output_bytes = 4,
  execute = function(argv, policy)
    observed = { argv = argv, policy = policy }
    return { status = "ok", exit_code = 0, stdout = "abcdef", stderr = "" }
  end,
})
assert(not pcall(Runner.new, "invalid"))
assert(not pcall(Runner.new, { default_timeout_ms = math.huge }))
equal(runner:run({ "relative", "x" }).reason, "executable_must_be_absolute")
equal(runner:run({ "/usr/bin/example" }, "invalid").reason, "invalid_runner_options")
local run = runner:run({ "/usr/bin/example", "one;two" })
equal(observed.argv[2], "one;two", "arguments must be passed without shell interpretation")
equal(run.stdout, "abcd")
assert(run.truncated)

local invalid_status = Runner.new({ execute = function() return { stdout = "" } end })
  :run({ "/usr/bin/example" })
equal(invalid_status.status, "error")
equal(invalid_status.reason, "invalid_executor_status")
local unavailable_status = Runner.new({ execute = function()
  return { status = "unavailable", reason = "missing" }
end }):run({ "/usr/bin/example" })
equal(unavailable_status.status, "unavailable")
equal(unavailable_status.reason, "missing")
for _, invalid_policy in ipairs({ "1", math.huge, 0 / 0, 1.5, 0, 60001 }) do
  local rejected = runner:run({ "/usr/bin/example" }, { timeout_ms = invalid_policy })
  equal(rejected.reason, "invalid_runner_policy")
end
equal(runner:run({ "/usr/bin/example" }, { env = "invalid" }).reason,
  "invalid_runner_policy")

local raw_result = {
  status = "ok", quality = "fresh", timestamp_ns = math.huge, duration_ns = -1,
}
local normalized = Scheduler.normalize_result(raw_result, 10, 20)
equal(normalized.timestamp_ns, 20)
equal(normalized.duration_ns, 10)
assert(normalized ~= raw_result and raw_result.timestamp_ns == math.huge,
  "scheduler normalization must not mutate collector-owned results")
local invalid_clock = Scheduler.new({ clock = function() return math.huge end })
assert(not pcall(function()
  invalid_clock:add({ id = "clock", sample = function() return { status = "ok" } end })
end))

local decoded = assert(JSON.decode('{"name":"wtop","unicode":"\\u6c34","items":[1,true,null]}'))
equal(decoded.name, "wtop")
equal(decoded.unicode, "水")
assert(decoded.items[3] == JSON.null)
local invalid, decode_error = JSON.decode('{"x":01}')
assert(invalid == nil and decode_error.message == "invalid_number")
local duplicate, duplicate_error = JSON.decode('{"x":1,"x":2}')
assert(duplicate == nil and duplicate_error.message == "duplicate_object_key")
local invalid_utf8, utf8_error = JSON.decode('"bad\255value"')
assert(invalid_utf8 == nil and utf8_error.message == "invalid_utf8")

equal(assert(JSON.decode("-0")), 0)
equal(assert(JSON.decode("0.125")), 0.125)
equal(assert(JSON.decode("1e+2")), 100)
equal(assert(JSON.decode("-2E-1")), -0.2)
for _, number in ipairs({ "-01", "1.", "1e", "1e+" }) do
  local value, number_error = JSON.decode(number)
  assert(value == nil and number_error.message == "invalid_number", number)
end
local out_of_range, range_error = JSON.decode("1e99999")
assert(out_of_range == nil and range_error.message == "number_out_of_range")

assert(JSON.decode("null", { max_nodes = 1 }) == JSON.null)
assert(JSON.decode('"scalar"', { max_nodes = 1 }) == "scalar")
assert(type(assert(JSON.decode("[]", { max_nodes = 1 }))) == "table")
assert(type(assert(JSON.decode("{}", { max_nodes = 1 }))) == "table")
assert(assert(JSON.decode('{"value":1}', { max_nodes = 2 })).value == 1)
local node_limited, node_error = JSON.decode("[0]", { max_nodes = 1 })
assert(node_limited == nil and node_error.message == "maximum_nodes_exceeded")
assert(type(JSON.DEFAULT_MAX_NODES) == "number" and JSON.DEFAULT_MAX_NODES >= 1000)
local default_node_limit = "[" .. string.rep("0,", JSON.DEFAULT_MAX_NODES - 1) .. "0]"
local default_limited, default_limit_error = JSON.decode(default_node_limit)
assert(default_limited == nil and default_limit_error.message == "maximum_nodes_exceeded")

for _, bad_limit in ipairs({ 0, -1, 1.5, "2", math.huge, 0 / 0 }) do
  local value, limit_error = JSON.decode("null", { max_nodes = bad_limit })
  assert(value == nil and limit_error.message == "invalid_max_nodes")
end
local bad_options, options_error = JSON.decode("null", "invalid")
assert(bad_options == nil and options_error.message == "invalid_options")
local bad_bytes, bytes_error = JSON.decode("null", { max_bytes = -1 })
assert(bad_bytes == nil and bytes_error.message == "invalid_max_bytes")
local bad_depth, depth_error = JSON.decode("null", { max_depth = -1 })
assert(bad_depth == nil and depth_error.message == "invalid_max_depth")
assert(JSON.decode("null", {max_depth = JSON.HARD_MAX_DEPTH + 1}) == nil)
assert(JSON.decode("null", {max_nodes = JSON.HARD_MAX_NODES + 1}) == nil)
assert(JSON.decode("null", {max_bytes = JSON.HARD_MAX_BYTES + 1}) == nil)
assert(JSON.decode("null", { max_depth = 0 }) == JSON.null)
local depth_limited, depth_limit_error = JSON.decode("[]", { max_depth = 0 })
assert(depth_limited == nil and depth_limit_error.message == "maximum_depth_exceeded")

-- Performance smoke: a numeric array must not copy the entire unparsed suffix
-- for every element.  The generous bound catches accidental quadratic parsing
-- without turning normal differences between CI hosts into a benchmark gate.
local number_count = 50000
local numeric_array = "[" .. string.rep("0,", number_count - 1) .. "0]"
local decode_started = os.clock()
local many_numbers = assert(JSON.decode(numeric_array, { max_nodes = number_count + 1 }))
local decode_seconds = os.clock() - decode_started
equal(#many_numbers, number_count)
assert(decode_seconds < 5, string.format("large numeric JSON decode took %.3fs", decode_seconds))

return true
