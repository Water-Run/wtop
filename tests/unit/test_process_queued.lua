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
local ProcessTable = require("wtop.model.process_table")
local ViewModel = require("wtop.view_model")

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
  ["/proc/100/wchan"] = "do_wait\n",
  ["/proc/200/wchan"] = "0\n",
  ["/proc/300/wchan"] = "off_screen\n",
  ["/proc/100/io"] = "read_bytes: 10\nwrite_bytes: 20\n",
  ["/proc/200/io"] = "read_bytes: 100\nwrite_bytes: 200\n",
  ["/proc/300/io"] = "read_bytes: 30\nwrite_bytes: 40\n",
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

-- All ordinary samples below read the same procfs fixture.
local process_fs = fake_fs()
local now = 1000000000
local function context(visible, overrides)
  return {
    fs = overrides and fake_fs(overrides) or process_fs,
    now_ns = function() return now end,
    visible_process_ids = visible,
  }
end

local collector = Process.new({ read_status = false })

local bulk_now = 1000000000
local bulk_collector = Process.new({ read_status = false })
local function bulk_context()
  return {
    fs = process_fs, now_ns = function() return bulk_now end,
    scan_process_io = true,
  }
end
reads = {}
local bulk_first = bulk_collector:sample(bulk_context())
assert(bulk_first.data.io_scan.status == "ok"
  and bulk_first.data.io_scan.covered == 3
  and bulk_first.data.io_scan.refreshed == 3
  and bulk_first.data.by_id["200:12"].io.read_bytes == 100,
  "an explicit I/O sort measures every collected process, not only the cursor")
assert(bulk_first.data.by_id["200:12"].io_rate.quality == "gap"
  and bulk_first.data.by_id["200:12"].io_rate.read_bytes_per_second == nil,
  "one cumulative I/O sample cannot establish a rate")
local io_reads = 0
for _, path in ipairs(reads) do
  if path:find("/io$", 1) then io_reads = io_reads + 1 end
end
assert(io_reads == 3, "the initial bulk sample reads each I/O file once")
local capped_collector = Process.new({ read_status = false, max_bulk_io_reads = 2 })
assert(not pcall(Process.new, { max_bulk_io_reads = 8193 }),
  "the I/O scan budget cannot exceed the native batch reader's hard bound")
reads = {}
local capped_io = capped_collector:sample(bulk_context())
assert(capped_io.data.io_scan.status == "partial"
  and capped_io.data.io_scan.covered == 2
  and capped_io.data.io_scan.total == 3
  and capped_io.data.io_scan.capped == 1
  and capped_io.data.by_id["300:13"].io == nil
  and capped_io.data.by_id["300:13"].io_status == "truncated",
  "the read budget reports missing I/O coverage instead of sorting an unknown as zero")
for _, path in ipairs(reads) do
  assert(path ~= "/proc/300/io", "the I/O read budget must stop actual file opens")
end
files["/proc/200/io"] = "read_bytes: 150\nwrite_bytes: 250\n"
bulk_now = bulk_now + 1000000000
reads = {}
local bulk_cached = bulk_collector:sample(bulk_context(), bulk_first)
assert(bulk_cached.data.io_scan.refreshed == 0
  and bulk_cached.data.io_scan.reused == 3
  and bulk_cached.data.by_id["200:12"].io.read_bytes == 100
  and bulk_cached.data.by_id["200:12"].io_observed_ns == 1000000000,
  "bulk I/O counters retain their observation time until the five-second refresh")
assert(bulk_cached.data.by_id["200:12"].io_rate.quality == "gap",
  "reusing a first sample does not create a rate")
for _, path in ipairs(reads) do
  assert(not path:find("/io$", 1), "a warm bulk scan must not reread I/O every tick")
end
bulk_now = bulk_now + 5000000000
local bulk_refreshed = bulk_collector:sample(bulk_context(), bulk_cached)
assert(bulk_refreshed.data.io_scan.refreshed == 3
  and bulk_refreshed.data.by_id["200:12"].io.read_bytes == 150
  and bulk_refreshed.data.by_id["200:12"].io_observed_ns == bulk_now,
  "the bulk cache refreshes after five seconds")
local observed_rate = bulk_refreshed.data.by_id["200:12"].io_rate
assert(observed_rate.quality == "fresh" and observed_rate.interval_ns == 6000000000
  and math.abs(observed_rate.read_bytes_per_second - 50 / 6) < 0.000001
  and math.abs(observed_rate.write_bytes_per_second - 50 / 6) < 0.000001,
  "read and write rates use the actual counter interval, not the screen refresh")
local original_stat = files["/proc/100/stat"]
files["/proc/100/stat"] = stat_line({ pid = 100, comm = "replacement", starttime = 99 })
bulk_now = bulk_now + 1000000000
local recycled_io = bulk_collector:sample(bulk_context(), bulk_refreshed)
assert(recycled_io.data.by_id["100:99"].io.read_bytes == 10
  and recycled_io.data.by_id["100:99"].io_observed_ns == bulk_now
  and recycled_io.data.io_scan.refreshed == 1,
  "a recycled PID is read anew even while other identities reuse warm I/O")
assert(recycled_io.data.by_id["100:99"].io_rate.quality == "gap",
  "a recycled PID cannot inherit another process's I/O rate")
assert(recycled_io.data.by_id["200:12"].io_rate.quality == "held"
  and recycled_io.data.by_id["200:12"].io_rate.observed_ns == bulk_refreshed.data
    .by_id["200:12"].io_rate.observed_ns,
  "a warm read preserves the measured interval while marking its rate held")
files["/proc/100/stat"] = original_stat
local original_io = files["/proc/200/io"]
files["/proc/200/io"] = nil
bulk_now = bulk_now + 5000000000
local incomplete_io = bulk_collector:sample(bulk_context(), recycled_io)
assert(incomplete_io.data.io_scan.status == "partial"
  and incomplete_io.data.io_scan.covered == 2
  and incomplete_io.data.by_id["200:12"].io == nil
  and incomplete_io.data.by_id["200:12"].io_status == "unavailable"
  and incomplete_io.data.by_id["200:12"].io_rate == nil,
  "a missing I/O file is unknown, never a zero that can win a sort")
files["/proc/200/io"] = original_io
local reset_collector = Process.new({ read_status = false })
local reset_first = reset_collector:sample(bulk_context())
local reset_source = files["/proc/200/io"]
files["/proc/200/io"] = "read_bytes: 1\nwrite_bytes: 251\n"
bulk_now = bulk_now + 5000000000
local reset_sample = reset_collector:sample(bulk_context(), reset_first)
local reset_rate = reset_sample.data.by_id["200:12"].io_rate
assert(reset_rate.quality == "reset"
  and reset_rate.reason == "counter_reset"
  and reset_rate.read_bytes_per_second == nil
  and reset_rate.write_bytes_per_second == nil,
  "one counter reset invalidates the pair instead of inventing a negative rate")
files["/proc/200/io"] = reset_source
local frozen_collector = Process.new({ read_status = false, read_io = true })
local frozen_context = { fs = process_fs, now_ns = function() return 1000000000 end }
local frozen_first = frozen_collector:sample(frozen_context)
local frozen_second = frozen_collector:sample(frozen_context, frozen_first)
assert(frozen_second.data.by_id["200:12"].io_rate.quality == "gap"
  and frozen_second.data.by_id["200:12"].io_rate.reason == "invalid_interval"
  and frozen_second.data.by_id["200:12"].io_rate.read_bytes_per_second == nil,
  "a stopped monotonic clock cannot produce a throughput rate")
local rate_now = 1000000000
local rate_collector = Process.new({ read_status = false })
local function rate_context()
  return { fs = process_fs, now_ns = function() return rate_now end,
    scan_process_io_rate = true }
end
local rate_first = rate_collector:sample(rate_context())
assert(rate_first.data.io_scan.refresh_interval_ns == 2000000000
  and rate_first.data.io_scan.rate_covered == 0,
  "requesting live I/O rates begins with a gap and a two-second budget")
rate_now = rate_now + 1000000000
local rate_cached = rate_collector:sample(rate_context(), rate_first)
assert(rate_cached.data.io_scan.refreshed == 0
  and rate_cached.data.io_scan.rate_covered == 0,
  "one second is not silently treated as the two-second I/O interval")
local rate_source = files["/proc/200/io"]
files["/proc/200/io"] = "read_bytes: 180\nwrite_bytes: 280\n"
rate_now = rate_now + 1000000000
local rate_second = rate_collector:sample(rate_context(), rate_cached)
assert(rate_second.data.io_scan.refreshed == 3
  and rate_second.data.io_scan.rate_covered == 3
  and math.abs(rate_second.data.by_id["200:12"].io_rate.read_bytes_per_second - 15) < 1e-9,
  "a visible rate request refreshes every two seconds and covers all rows")
files["/proc/200/io"] = rate_source
local oneshot_now = 1000000000
local oneshot_collector = Process.new({ read_status = false })
local function oneshot_context(force)
  return { fs = process_fs, now_ns = function() return oneshot_now end,
    scan_process_io_rate = true, force_process_io_refresh = force }
end
local oneshot_first = oneshot_collector:sample(oneshot_context(false))
local oneshot_source = files["/proc/200/io"]
files["/proc/200/io"] = "read_bytes: 200\nwrite_bytes: 300\n"
oneshot_now = oneshot_now + 250000000
local oneshot_second = oneshot_collector:sample(oneshot_context(true), oneshot_first)
assert(oneshot_second.data.io_scan.refreshed == 3
  and oneshot_second.data.io_scan.reused == 0
  and oneshot_second.data.io_scan.rate_covered == 3
  and oneshot_second.data.by_id["200:12"].io_rate.quality == "fresh"
  and math.abs(oneshot_second.data.by_id["200:12"].io_rate.read_bytes_per_second - 200) < 1e-9,
  "the second one-shot sample reads fresh counters despite the interactive refresh floor")
files["/proc/200/io"] = oneshot_source
local io_controller = ProcessTable.new({ sort_key = "io_read", descending = true })
local english = assert(I18n.new({ locale = "en-US" }))
local engine_stub = { history_values = function() return {} end }
local function io_view(processes)
  return ViewModel.build(engine_stub, {
    cpu = {}, memory = {}, pressure = {}, disks = {}, network = {},
    gpus = {}, cpu_frequency = {}, sensors = {}, quality = {},
    processes = processes,
  }, english, {}, "processes", io_controller, { process_table = true },
    { platform = "Linux" }).process_table
end
assert(io_view({ list = bulk_first.data.list }).rows[1].process.pid == 200,
  "the bulk readings make an I/O sort compare all collected processes")
assert(io_view({ list = bulk_first.data.list }).status_text:find("I/O loading", 1, true),
  "before an explicit scan arrives, the table names the pending I/O data")
local io_complete = io_view(bulk_first.data)
assert(not io_complete.status_text:find("I/O loading", 1, true))
local io_incomplete = io_view(incomplete_io.data)
assert(io_incomplete.status_text:find("I/O 2/3", 1, true),
  "a partial bulk scan reports its actual coverage")
io_controller:set_sort("io_read_rate", true)
assert(io_view(rate_first.data).status_text:find("I/O rate needs another sample", 1, true),
  "a rate sort says why its first frame has no number")
local rate_view = io_view(rate_second.data)
assert(rate_view.rows[1].process.pid == 200
  and not rate_view.status_text:find("needs another sample", 1, true),
  "the measured rate, not a lifetime total, determines I/O-rate sort order")
io_controller:set_columns({ "pid", "name", "io_read_rate", "io_write_rate" })
rate_view = io_view(rate_second.data)
assert(rate_view.rows[1].io_read_rate:find("/s", 1, true)
  and rate_view.rows[1].io_write_rate:find("/s", 1, true),
  "opt-in process columns show separate read and write rates")
io_controller:set_sort("cpu", true)
io_controller:set_query("ioread>20")
local filtered = io_view(bulk_first.data)
assert(#filtered.rows == 2 and filtered.rows[1].process.pid == 200
  and filtered.rows[2].process.pid == 300,
  "I/O numeric filters use the same complete bulk sample as sorting")
io_controller:set_query("ioreadps>0")
local rate_filtered = io_view(rate_second.data)
assert(#rate_filtered.rows == 1 and rate_filtered.rows[1].process.pid == 200,
  "a rate filter compares measured bytes per second rather than totals")

-- The table cursor is not an open detail overlay, and a hidden Queued column
-- has no consumer. Neither should turn one process selection into extra procfs
-- reads on every refresh of the default table.
local source_rows = {
  { id = "100:11" }, { id = "200:12" }, { id = "300:13" },
}
local function sampling(extra)
  local state = {
    page = "processes", source_rows = source_rows,
    offset = 0, visible_rows = 2,
    queued_chosen = false,
    drawn_columns = { { key = "cpu" } },
  }
  for key, value in pairs(extra or {}) do state[key] = value end
  return TUI.process_sampling_plan(state)
end
local ordinary = sampling()
assert(next(ordinary.selected_process_ids) == nil
  and ordinary.visible_process_ids == nil,
  "the cursor alone requests neither process detail nor scheduler reads")
local chosen_but_hidden = sampling({ queued_chosen = true })
assert(chosen_but_hidden.visible_process_ids == nil,
  "a user-chosen Queued column dropped by the renderer costs no procfs reads")
local drawn = sampling({ queued_chosen = true,
  drawn_columns = { { key = "cpu" }, { key = "queued" } } })
assert(drawn.visible_process_ids["100:11"]
  and drawn.visible_process_ids["200:12"]
  and not drawn.visible_process_ids["300:13"],
  "a drawn Queued column measures exactly its viewport")
local scrolled = sampling({ queued_chosen = true,
  drawn_columns = { { key = "queued" } }, offset = 1 })
assert(not scrolled.visible_process_ids["100:11"]
  and scrolled.visible_process_ids["200:12"]
  and scrolled.visible_process_ids["300:13"],
  "scrolling changes the set that is sampled")
local covered = sampling({ queued_chosen = true, overlay = {},
  drawn_columns = { { key = "queued" } } })
assert(covered.visible_process_ids == nil,
  "a table covered by an unrelated overlay does not need viewport queue readings")
local wait_hidden = sampling({ wait_site_chosen = true })
assert(wait_hidden.visible_wait_process_ids == nil,
  "a WCHAN column omitted by responsive layout costs no procfs reads")
local wait_drawn = sampling({ wait_site_chosen = true,
  drawn_columns = { { key = "wait_site" } } })
assert(wait_drawn.visible_wait_process_ids["100:11"]
  and wait_drawn.visible_wait_process_ids["200:12"]
  and not wait_drawn.visible_wait_process_ids["300:13"]
  and wait_drawn.visible_process_ids == nil,
  "WCHAN reads exactly its viewport without enabling schedstat")
local wait_scrolled = sampling({ wait_site_chosen = true,
  drawn_columns = { { key = "wait_site" } }, offset = 1 })
assert(not wait_scrolled.visible_wait_process_ids["100:11"]
  and wait_scrolled.visible_wait_process_ids["200:12"]
  and wait_scrolled.visible_wait_process_ids["300:13"],
  "scrolling changes which wait sites are read")
assert(sampling({ wait_site_chosen = true, overlay = {},
  drawn_columns = { { key = "wait_site" } } }).visible_wait_process_ids == nil,
  "a covered table stops viewport WCHAN reads")
assert(sampling({ io_requested = true }).scan_process_io == true
  and sampling({ page = "gpu", io_requested = true }).scan_process_io == false
  and sampling({ overlay = {}, io_requested = true }).scan_process_io == false,
  "an explicit process I/O sort or filter scans only while its table is visible")
assert(sampling({ io_rate_requested = true }).scan_process_io_rate == true
  and sampling({ io_rate_requested = true }).scan_process_io == true
  and sampling({ page = "gpu", io_rate_requested = true }).scan_process_io_rate == false
  and sampling({ overlay = {}, io_rate_requested = true }).scan_process_io_rate == false,
  "rate sort/filter requests the faster I/O interval only on the process table")
assert(sampling({ io_rate_columns_chosen = true,
  drawn_columns = { { key = "io_read_rate" } } }).scan_process_io_rate == true
  and sampling({ io_rate_columns_chosen = true }).scan_process_io_rate == false,
  "an optional rate column costs I/O reads only when the renderer draws it")
local builder = function() end
local process_detail = { builder = builder, resolve = function() return source_rows[3] end }
local detail = sampling({ page = "gpu", overlay = {}, overlay_builder = builder,
  process_detail = process_detail })
assert(detail.selected_process_ids["300:13"]
  and next(detail.selected_process_thread_list_ids) == nil
  and detail.selected_process_numa_ids["300:13"]
  and detail.visible_process_ids["300:13"],
  "a host process opened from GPU gets its own detail and scheduler readings")
local picker = sampling({ overlay = {}, thread_selection = { mode = "picker",
  resolve = function() return source_rows[2] end,
} })
assert(next(picker.selected_process_ids) == nil
  and picker.selected_process_thread_list_ids["200:12"]
  and picker.visible_process_ids == nil
  and next(picker.selected_process_numa_ids) == nil,
  "thread navigation requests only the task list, not full process detail")
local thread_detail = sampling({ overlay = {}, thread_selection = {
  mode = "detail", resolve = function() return source_rows[2] end,
} })
assert(thread_detail.selected_process_ids["200:12"]
  and next(thread_detail.selected_process_thread_list_ids) == nil
  and thread_detail.visible_process_ids == nil,
  "opening thread detail adds process memory and FD context, not its queue rate")
assert(next(sampling({ process_detail = process_detail,
  overlay = {}, overlay_builder = function() end }).selected_process_ids) == nil,
  "an unrelated overlay does not keep a stale process detail selected")
assert(next(sampling({ process_detail = process_detail,
  overlay_builder = builder }).selected_process_ids) == nil,
  "a closed overlay stops detail reads before the next sample")

reads = {}
local quiet_context = context(ordinary.visible_process_ids)
quiet_context.selected_process_ids = ordinary.selected_process_ids
local quiet_sample = collector:sample(quiet_context)
assert(quiet_sample.status == "ok")
for _, path in ipairs(reads) do
  assert(not path:find("schedstat", 1, true)
    and not path:find("/smaps_rollup", 1, true)
    and not path:find("/io", 1, true),
    "the default table must not perform invisible detail reads: " .. path)
end

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

-- PID reuse during the schedstat read is different from reuse between two
-- samples. The post-read identity must fence both the public row and the
-- private rate baseline, including when a previously valid reading exists.
for _, replacement in ipairs({
  stat_line({ pid = 100, starttime = 99 }),
  stat_line({ pid = 999, starttime = 11 }),
  stat_line({ pid = 100, starttime = 11 }):gsub("4194304", "2097152", 1),
  false,
  "malformed stat\n",
}) do
  local race_now, race_stat, trigger = 1000000000,
    stat_line({ pid = 100, starttime = 11 }), false
  local race_wait, race_reads = 100000000, {}
  local race_fs = {
    list = function() return { "100" } end,
    read = function(_, path)
      race_reads[#race_reads + 1] = path
      if path == "/proc/100/stat" then
        if race_stat == false then return nil, { kind = "missing" } end
        return race_stat
      elseif path == "/proc/100/schedstat" then
        if trigger then race_stat = replacement end
        return string.format("1000000000 %d 10\n", race_wait)
      end
      return nil, { kind = "missing" }
    end,
  }
  local fenced = Process.new({ fs = race_fs, read_status = false })
  local race_context = { now_ns = function() return race_now end,
    visible_process_ids = { ["100:11"] = true } }
  local valid = fenced:sample(race_context)
  assert(valid.data.by_id["100:11"].scheduler.wait_ns == 100000000)
  local memo = fenced.sched_memo["pid /proc/100"]
  trigger, race_now, race_wait = true, 2000000000, 900000000
  local discarded = fenced:sample(race_context, valid)
  assert(discarded.data.by_id["100:11"] == nil
    and #discarded.data.list == 0
    and discarded.data.races + discarded.data.parse_errors == 1,
    "a schedstat-time identity change must not publish a mixed process row")
  assert(fenced.sched_memo["pid /proc/100"] == memo
    and memo.at_ns == 1000000000 and memo.wait_ns == 100000000,
    "a discarded schedstat reading must not replace the rate baseline")
  trigger, race_now, race_wait = false, 3000000000, 300000000
  race_stat = stat_line({ pid = 100, starttime = 11 })
  local recovered = fenced:sample(race_context, discarded)
  local recovered_rate = recovered.data.by_id["100:11"].scheduler
  assert(recovered_rate.quality == "fresh"
    and recovered_rate.interval_ns == 2000000000
    and recovered_rate.wait_rate_ns == 100000000,
    "recovery differences only against the last identity-checked reading")
  local stat_reads, scheduler_reads = 0, 0
  for _, path in ipairs(race_reads) do
    if path == "/proc/100/stat" then stat_reads = stat_reads + 1 end
    if path == "/proc/100/schedstat" then scheduler_reads = scheduler_reads + 1 end
  end
  assert(stat_reads == 6 and scheduler_reads == 3,
    "one final stat read fences each visible scheduler reading")
end

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
local function io_rate_row(lines, label)
  for _, line in ipairs(lines) do
    if line:find(label, 1, true) then return line end
  end
end
local first_io_lines = TUI.process_detail_lines({ pid = 200, id = "200:12",
  io = bulk_first.data.by_id["200:12"].io,
  io_rate = bulk_first.data.by_id["200:12"].io_rate }, translator)
assert(io_rate_row(first_io_lines, "读取速率"):find("—", 1, true)
  and io_rate_row(first_io_lines, "I/O 速率状态"):find("采样缺口", 1, true),
  "first-sample I/O detail says gap rather than printing zero throughput")
local fresh_io_lines = TUI.process_detail_lines({ pid = 200, id = "200:12",
  io = bulk_refreshed.data.by_id["200:12"].io,
  io_rate = observed_rate }, translator)
assert(io_rate_row(fresh_io_lines, "读取速率"):find("/s", 1, true)
  and io_rate_row(fresh_io_lines, "写入速率"):find("/s", 1, true)
  and io_rate_row(fresh_io_lines, "I/O 速率状态") == nil,
  "measured read and write rates are separate per-second rows")
local held_io_lines = TUI.process_detail_lines({ pid = 200, id = "200:12",
  io = recycled_io.data.by_id["200:12"].io,
  io_rate = recycled_io.data.by_id["200:12"].io_rate }, translator)
assert(io_rate_row(held_io_lines, "I/O 速率状态"):find("保持", 1, true),
  "a cached rate is labelled held rather than passed off as a new interval")
local reset_io_lines = TUI.process_detail_lines({ pid = 200, id = "200:12",
  io = reset_sample.data.by_id["200:12"].io,
  io_rate = reset_rate }, translator)
assert(io_rate_row(reset_io_lines, "读取速率"):find("—", 1, true)
  and io_rate_row(reset_io_lines, "I/O 速率状态"):find("已重置", 1, true),
  "counter rollback remains unknown in the detail overlay")
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
assert(not Columns.contains(Columns.defaults(), "wait_site"),
  "WCHAN is opt-in so the default table avoids per-row procfs reads")
assert(#Columns.keys() == 16,
  "the run-queue, wait-site, elapsed and two I/O-rate columns are all offered")
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

-- WCHAN is a symbolic leader-task location, not a scheduler rate. It can be
-- useful across the visible process rows, but opening it for every PID would
-- defeat the default scan's cost bound. Every published symbol is protected
-- by the final starttime check, as in the selected-process detail.
reads = {}
local reused_stat = files["/proc/100/stat"]
files["/proc/100/stat"] = original_stat
local wait_context = context(nil)
wait_context.visible_wait_process_ids = wait_drawn.visible_wait_process_ids
local wait_sample = Process.new({ read_status = false }):sample(wait_context)
assert(wait_sample.data.by_id["100:11"].wait_site == "do_wait"
  and wait_sample.data.by_id["200:12"].wait_site_status == "not_reported"
  and wait_sample.data.by_id["300:13"].wait_site_status == nil,
  "only visible leaders have a wait-site reading; kernel 0 remains distinct")
local stat_reads = { [100] = 0, [200] = 0, [300] = 0 }
for _, path in ipairs(reads) do
  local pid = tonumber(path:match("^/proc/(%d+)/stat$"))
  if pid then stat_reads[pid] = stat_reads[pid] + 1 end
  assert(path ~= "/proc/300/wchan" and not path:find("schedstat", 1, true),
    "a WCHAN viewport must not read an offscreen site or schedstat")
end
assert(stat_reads[100] == 2 and stat_reads[200] == 2 and stat_reads[300] == 1,
  "a displayed symbol is checked against its PID generation")
local invalid_wait_context = context(nil)
invalid_wait_context.visible_wait_process_ids = { ["100:11"] = true }
for index = 1, 256 do
  invalid_wait_context.visible_wait_process_ids["unknown:" .. index] = true
end
reads = {}
Process.new({ read_status = false }):sample(invalid_wait_context)
for _, path in ipairs(reads) do
  assert(not path:find("/wchan", 1, true),
    "an oversized viewport request cannot trigger unbounded wait-site reads")
end

local shown_wait = Columns.toggle(Columns.defaults(), "wait_site")
local wait_controller = Controller.new({ columns = shown_wait })
local wait_snapshot = {
  cpu = {}, memory = {}, pressure = {}, disks = {}, network = { interfaces = {} },
  processes = wait_sample.data, gpus = {}, cpu_frequency = {}, sensors = {}, quality = {},
  connections = { connections = {}, owner_scan = { status = "ok" } },
  mounts = { mounts = {} }, workloads = { workloads = {}, summary = {} },
}
local wait_models = ViewModel.build(engine, wait_snapshot,
  assert(I18n.new({ locale = "en-US" })), {}, "processes", wait_controller,
  { process_table = true })
local wait_column = false
for _, column in ipairs(wait_models.process_table.columns) do
  if column.key == "wait_site" then wait_column = true end
end
assert(wait_column, "the Linux process table includes the chosen WCHAN column")
local wait_cells = {}
for _, row in ipairs(wait_models.process_table.rows) do
  wait_cells[row.pid] = row.wait_site
end
assert(wait_cells["100"] == "do_wait" and wait_cells["200"] == "—"
  and wait_cells["300"] == "—",
  "the table shows a symbol only when the kernel reported one")
wait_sample.data.by_id["200:12"].wait_site_status = "denied"
local denied_models = ViewModel.build(engine, wait_snapshot,
  assert(I18n.new({ locale = "en-US" })), {}, "processes",
  Controller.new({ columns = shown_wait }), { process_table = true })
local denied_cell
for _, row in ipairs(denied_models.process_table.rows) do
  if row.pid == "200" then denied_cell = row.wait_site end
end
assert(denied_cell == "Denied",
  "a refused WCHAN read is visible as a localized status, not an empty cell")
wait_sample.data.by_id["200:12"].wait_site_status = "not_reported"
for _, platform in ipairs({ "Darwin", "Windows" }) do
  local portable_models = ViewModel.build(engine, wait_snapshot,
    assert(I18n.new({ locale = "en-US" })), {}, "processes", wait_controller,
    { process_table = true }, { platform = platform })
  for _, column in ipairs(portable_models.process_table.columns) do
    assert(column.key ~= "wait_site", platform .. " must not draw a Linux-only column")
  end
end

local racing_fs = fake_fs()
local original_read = racing_fs.read
local selected_stat_reads = 0
racing_fs.read = function(self, path, limit)
  if path == "/proc/100/stat" then
    selected_stat_reads = selected_stat_reads + 1
    if selected_stat_reads == 2 then
      return stat_line({ pid = 100, comm = "replacement", starttime = 99 })
    end
  end
  return original_read(self, path, limit)
end
local race_context = context(nil)
race_context.fs = racing_fs
race_context.visible_wait_process_ids = { ["100:11"] = true }
local race_sample = Process.new({ read_status = false }):sample(race_context)
assert(race_sample.data.by_id["100:11"] == nil and race_sample.data.races >= 1,
  "PID reuse during a viewport WCHAN read discards the mixed row")
files["/proc/100/stat"] = reused_stat
local exported_wait = Export.snapshot({ processes = { list = { {
  id = "100:11", pid = 100, name = "busy", wait_site = "do_wait",
  wait_site_status = "ok",
} } } }, { process_limit = 1 })
assert(not json.encode(exported_wait):find("do_wait", 1, true),
  "an opt-in viewport reading does not enter the default process snapshot")

print("ok: process queue and wait site (viewport bound, rates, identity, columns)")
return true
