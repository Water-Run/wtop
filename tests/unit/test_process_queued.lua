-- Run-queue wait for the processes the table is showing.
--
-- The process table is where triage happens, and CPU share alone cannot answer
-- the question that matters there: a process that is starved and a process that
-- is busy are both running, and only the queueing figure tells them apart.  The
-- cost of that figure is what shapes this feature -- /proc/<pid>/schedstat is
-- one small file per process, and reading it for every process every tick would
-- be a second full procfs sweep for a column nobody can see.  So it is read for
-- the viewport, and these tests pin that bound as carefully as the arithmetic.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Process = require("wtop.collectors.process")
local Parsers = require("wtop.linux.parsers")
local Columns = require("wtop.model.process_columns")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local json = require("wtop.format.json")
local Export = require("wtop.export")

local function stat_line(spec)
  local fields = {
    spec.ppid or 1, spec.pgrp or spec.pid, spec.session or spec.pid,
    0, -1, 4194304, 10, 0, 2, 0,
    spec.utime or 0, spec.stime or 0, 0, 0,
    spec.priority or 20, spec.nice or 0, spec.threads or 1, 0,
    spec.starttime or 1000, spec.vsize or 10485760, spec.rss or 512,
  }
  local numbers = {}
  for index, value in ipairs(fields) do numbers[index] = tostring(value) end
  for index = #fields + 1, 44 do numbers[index] = "0" end
  numbers[36] = tostring(spec.processor or 0)
  return string.format("%d (%s) %s %s", spec.pid, spec.comm or "task",
    spec.state or "S", table.concat(numbers, " "))
end

local reads = {}
local files = {
  ["/proc/100/stat"] = stat_line({ pid = 100, comm = "busy", starttime = 11 }),
  ["/proc/200/stat"] = stat_line({ pid = 200, comm = "idle", starttime = 12 }),
  ["/proc/300/stat"] = stat_line({ pid = 300, comm = "offscreen", starttime = 13 }),
  ["/proc/100/schedstat"] = "732423114 6950190 1102\n",
  ["/proc/200/schedstat"] = "134532 0 3\n",
}
local dirs = { ["/proc"] = { "100", "200", "300" } }

local function fake_fs(overrides)
  return {
    read = function(_, path)
      reads[#reads + 1] = path
      local value = (overrides and overrides[path]) or files[path]
      if overrides and overrides[path] == false then value = nil end
      if value == nil then
        return nil, { kind = "missing", message = "fixture_missing", path = path }
      end
      return value
    end,
    list = function(_, path, limit)
      local values = dirs[path]
      if not values then
        return nil, { kind = "missing", message = "fixture_directory_missing", path = path }
      end
      local copy, cut = {}, false
      for _, entry in ipairs(values) do
        if limit and #copy >= limit then cut = true break end
        copy[#copy + 1] = entry
      end
      return copy, nil, cut
    end,
  }
end

local now = 1000000000
local function context(visible, overrides)
  return {
    fs = fake_fs(overrides),
    now_ns = function() return now end,
    visible_process_ids = visible,
  }
end

local collector = Process.new({ read_status = false })

-- ---------------------------------------------------------------------------
-- The viewport is the bound.
-- ---------------------------------------------------------------------------

-- Nothing published: no process is measured, because nothing is on screen that
-- the operator could read a figure from.
reads = {}
local plain = collector:sample(context(nil))
assert(plain.status == "ok", "fixture sample failed")
for _, id in ipairs({ "100:11", "200:12", "300:13" }) do
  assert(plain.data.by_id[id].scheduler == nil,
    "an unmeasured process must carry no scheduler figure: " .. id)
end
for _, path in ipairs(reads) do
  assert(not path:find("schedstat", 1, true),
    "schedstat was read with no viewport published: " .. path)
end

-- One row visible: exactly that process's file is read, and the two others are
-- not.  This is the whole cost argument, so it is checked directly rather than
-- inferred from a total.
reads = {}
local one = collector:sample(context({ ["100:11"] = true }))
local read_set = {}
for _, path in ipairs(reads) do read_set[path] = true end
assert(read_set["/proc/100/schedstat"], "the visible process must be measured")
assert(not read_set["/proc/200/schedstat"],
  "an off-screen process must not be measured")
assert(not read_set["/proc/300/schedstat"],
  "an off-screen process must not be measured")
assert(one.data.by_id["100:11"].scheduler.quality == "gap",
  "a first reading has no rate")
assert(one.data.by_id["100:11"].scheduler.wait_ns == 6950190,
  "the cumulative counters are carried through")

-- A second reading one second later produces the rate for that process only.
files["/proc/100/schedstat"] = "1224233114 10950190 1182\n"
now = now + 1000000000
local two = collector:sample(context({ ["100:11"] = true }), one)
local scheduler = two.data.by_id["100:11"].scheduler
assert(scheduler.quality == "fresh", "a second reading is differenced")
assert(scheduler.interval_ns == 1000000000, "the interval is the one that elapsed")
local function near(actual, expected, tolerance)
  assert(type(actual) == "number", "expected a number, got " .. tostring(actual))
  assert(math.abs(actual - expected) <= (tolerance or 1),
    string.format("expected ~%s, got %s", expected, tostring(actual)))
end
near(scheduler.wait_rate_ns, 4000000, 1)   -- 4 ms of queueing per second
assert(two.data.by_id["200:12"].scheduler == nil,
  "a process that left the viewport stops being measured")

-- A PID reused by a different process must not inherit the previous one's
-- counters: a rate across two unrelated tasks is worse than no rate.
files["/proc/100/stat"] = stat_line({ pid = 100, comm = "impostor", starttime = 99 })
now = now + 1000000000
local reused = collector:sample(context({ ["100:99"] = true }), two)
assert(reused.data.by_id["100:99"].scheduler.quality == "gap"
  and reused.data.by_id["100:99"].scheduler.wait_rate_ns == nil,
  "a reused pid must not inherit a rate from the process that held the id")

-- A malformed set is ignored rather than trusted, and a set beyond the bound is
-- refused outright: the whole point of the bound is that a hostile context
-- cannot turn a viewport measurement back into a full sweep.
local oversized = {}
for index = 1, 400 do oversized["p" .. index .. ":1"] = true end
reads = {}
local refused = collector:sample(context(oversized))
for _, path in ipairs(reads) do
  assert(not path:find("schedstat", 1, true),
    "an oversized visible set must be refused rather than honoured")
end
assert(refused.status == "ok", "an oversized set does not fail the sample")

for _, hostile in ipairs({ { 1, 2, 3 }, { [true] = true }, "not a set", 42 }) do
  local result = collector:sample(context(hostile))
  assert(result.status == "ok", "a malformed visible set does not fail the sample")
end

-- A kernel without CONFIG_SCHEDSTATS does not create the file.  That is the
-- kernel declining to publish the figure and must not look like a process that
-- never waited.
local without = collector:sample(context({ ["200:12"] = true }, {
  ["/proc/200/schedstat"] = false,
}), refused)
local missing = without.data.by_id["200:12"].scheduler
assert(missing.status == "unavailable",
  "an absent schedstat is unavailable, got " .. tostring(missing.status))
assert(missing.wait_rate_ns == nil and missing.wait_ns == nil,
  "an absent schedstat carries no figures at all")

-- ---------------------------------------------------------------------------
-- What the two views draw.
-- ---------------------------------------------------------------------------

local translator = assert(I18n.new({ locale = "zh-CN" }))
local function queued_rows(process)
  local count = 0
  for _, line in ipairs(TUI.process_detail_lines(process, translator)) do
    if line:find("队列等待", 1, true) then count = count + 1 end
  end
  return count
end

-- The row appears only when there is a rate behind it.  A row of em dashes
-- would read as "this process never queued", which is the one claim this figure
-- must not make without having measured it.
assert(queued_rows({ pid = 100, id = "100:11",
  scheduler = { quality = "fresh", wait_rate_ns = 4000000 } }) == 1,
  "a measured rate is drawn")
for _, scheduler_case in ipairs({
  { quality = "gap", wait_ns = 6950190 },
  { status = "unavailable" },
  { status = "parse_error" },
  {},
}) do
  assert(queued_rows({ pid = 100, id = "100:11", scheduler = scheduler_case }) == 0,
    "an unmeasured process draws no queueing row: " .. json.encode(scheduler_case))
end
assert(queued_rows({ pid = 100, id = "100:11" }) == 0,
  "a process that was never measured draws no queueing row")

-- A starved process and an idle one are told apart by this figure, which is the
-- whole point: both are running.
local starved = TUI.process_detail_lines({ pid = 100, id = "100:11",
  scheduler = { quality = "fresh", wait_rate_ns = 1200000000 } }, translator)
local quiet = TUI.process_detail_lines({ pid = 200, id = "200:12",
  scheduler = { quality = "fresh", wait_rate_ns = 0 } }, translator)
local function value_of(lines)
  for _, line in ipairs(lines) do
    -- The value can contain a space ("1.2 s/s"), so everything after the label
    -- is taken rather than the last non-space run.
    local value = line:match("队列等待%s+(.+)$")
    if value then return value end
  end
  return nil
end
assert(value_of(starved) == "1.2 s/s",
  "a heavily starved process reports seconds queued per second, got "
    .. tostring(value_of(starved)))
assert(value_of(quiet) == "0 µs/s",
  "a process that never queued reports a real measured zero, not a blank: got "
    .. tostring(value_of(quiet)))

-- ---------------------------------------------------------------------------
-- The column.
-- ---------------------------------------------------------------------------

-- Offered, but not shown by default: a row that has just scrolled into view has
-- no reading for a tick, and shipping a column that is blank for the first
-- second after every scroll would answer nobody's question.
assert(not Columns.contains(Columns.defaults(), "queued"),
  "the run-queue column is not part of the default table")
assert(#Columns.keys() == 12, "the column is in the catalogue, so it can be switched on")
local shown = Columns.toggle(Columns.defaults(), "queued")
assert(Columns.contains(shown, "queued"),
  "the user can switch the run-queue column on")
assert(#shown == #Columns.defaults() + 1,
  "switching it on adds exactly one column")

-- With the column on, the value comes from the same figure the detail overlay
-- shows, and an unmeasured row is blank rather than zero.
local ViewModel = require("wtop.view_model")
local engine = { history_values = function() return {} end }
local snapshot = {
  cpu = {}, memory = {}, pressure = {}, disks = {}, network = { interfaces = {} },
  processes = {}, gpus = {}, cpu_frequency = {}, sensors = {}, quality = {},
  connections = { connections = {}, owner_scan = { status = "ok" } },
  mounts = { mounts = {} }, workloads = { workloads = {}, summary = {} },
}
local Controller = require("wtop.model.process_table")
local function column_for(chosen)
  local built = Controller.new({ columns = chosen })
  local models = ViewModel.build(engine, snapshot,
    assert(I18n.new({ locale = "en-US" })), {}, "processes", built,
    { process_table = true })
  for _, column in ipairs(models.process_table.columns) do
    if column.key == "queued" then return column end
  end
  return nil
end
assert(column_for(shown) ~= nil, "the run-queue column reaches the view model")
assert(column_for(Columns.defaults()) == nil,
  "the run-queue column stays out of the table until it is asked for")

-- The export boundary is an allowlist, so a per-process scheduler figure cannot
-- reach a snapshot by accident.
local exported = Export.snapshot({ processes = { list = { {
  id = "100:11", pid = 100, name = "busy",
  scheduler = { quality = "fresh", wait_rate_ns = 4000000, run_ns = 1 },
} } } }, { process_limit = 1 })
assert(not json.encode(exported):find("schedul", 1, true),
  "snapshot JSON must not carry the per-process scheduler figure")

print("ok: process run-queue wait (viewport bound, rates, drawing, column)")
return true
