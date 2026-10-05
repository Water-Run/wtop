-- Detail-mode thread rows: /proc/<pid>/task is enumerated only for the
-- selected process, TID identity is carried across samples, and the detail
-- overlay renders the rows the collector produced.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Process = require("wtop.collectors.process")
local Export = require("wtop.export")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local json = require("wtop.format.json")

-- A real /proc/<pid>/stat line: 21 numbered fields after the state, padded to
-- the full 44-field shape so the parser takes its usual path.
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

-- Minimal procfs double. Directory listings honour the limit and report
-- truncation the way the native listdir does.
local function fake_fs(files, dirs)
  return {
    read = function(_, path)
      local value = files[path]
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

local function thread_stat(tid, ticks, starttime, comm, state)
  return stat_line({ pid = tid, comm = comm, state = state or "S",
    utime = ticks, stime = 0, starttime = starttime, nice = tid == 11 and 5 or 0 })
end

local files = {
  ["/proc/10/stat"] = stat_line({ pid = 10, comm = "multi", state = "S",
    utime = 90, stime = 0, starttime = 5, threads = 3 }),
  ["/proc/10/task/10/stat"] = thread_stat(10, 90, 5, "multi"),
  ["/proc/10/task/11/stat"] = thread_stat(11, 30, 5, "worker", "R"),
  ["/proc/10/task/12/stat"] = thread_stat(12, 10, 5, "idle"),
  ["/proc/20/stat"] = stat_line({ pid = 20, comm = "single", state = "S",
    utime = 5, stime = 0, starttime = 7, threads = 1 }),
  ["/proc/20/task/20/stat"] = thread_stat(20, 5, 7, "single"),
}
local dirs = {
  ["/proc"] = { "10", "20" },
  ["/proc/10/task"] = { "10", "11", "12" },
  ["/proc/20/task"] = { "20" },
}

local now = 1000000000
local function context(fs, selected)
  return {
    fs = fs,
    now_ns = function() return now end,
    selected_process_ids = selected,
  }
end
local collector = Process.new({ read_status = false })

local first = collector:sample(context(fake_fs(files, dirs), { ["10:5"] = true }))
assert(first.status == "ok", "fixture sample failed")
local first_processes = first.data.by_id
assert(first_processes["10:5"].thread_rows and #first_processes["10:5"].thread_rows == 3,
  "the selected process must expose its task rows")
assert(first_processes["20:7"].thread_rows == nil,
  "unselected processes must not scan /task")
local by_tid = {}
for _, thread in ipairs(first_processes["10:5"].thread_rows) do
  by_tid[thread.tid] = thread
end
assert(by_tid[10].leader == true and by_tid[11].leader == false
  and by_tid[12].leader == false, "only the group leader row is flagged")
assert(by_tid[11].name == "worker" and by_tid[11].nice == 5
  and by_tid[11].state == "R", "thread rows carry name, nice and state")
assert(by_tid[10].quality == "gap" and by_tid[10].cpu_percent == nil,
  "a first sample has no per-thread rate to difference")
assert(first_processes["10:5"].thread_scan.total == 3
  and first_processes["10:5"].thread_scan.scanned == 3
  and first_processes["10:5"].thread_scan.truncated == false,
  "the scan summary echoes the NLWP and the scanned count")

-- Second sample one second later: per-thread CPU rates appear.
files["/proc/10/stat"] = stat_line({ pid = 10, comm = "multi", state = "S",
  utime = 160, stime = 0, starttime = 5, threads = 3 })
files["/proc/10/task/10/stat"] = thread_stat(10, 130, 5, "multi")
files["/proc/10/task/11/stat"] = thread_stat(11, 60, 5, "worker", "R")
now = now + 1000000000
local second = collector:sample(context(fake_fs(files, dirs), { ["10:5"] = true }),
  first)
local second_threads = {}
for _, thread in ipairs(second.data.by_id["10:5"].thread_rows) do
  second_threads[thread.tid] = thread
end
local function near(actual, expected)
  assert(type(actual) == "number", "expected a number, got " .. tostring(actual))
  assert(math.abs(actual - expected) < 0.01,
    string.format("expected ~%s, got %s", expected, tostring(actual)))
end
near(second_threads[10].cpu_percent, 40)
near(second_threads[11].cpu_percent, 30)
near(second_threads[12].cpu_percent, 0)
assert(second_threads[11].quality == "fresh", "a differenced thread is fresh")

-- TID 11 exits and its ID is immediately reused by a new thread: the ticks of
-- two different threads must not be differenced.
files["/proc/10/task/11/stat"] = thread_stat(11, 500, 9, "replacement", "R")
now = now + 1000000000
local reused = collector:sample(context(fake_fs(files, dirs), { ["10:5"] = true }),
  second)
local reused_threads = {}
for _, thread in ipairs(reused.data.by_id["10:5"].thread_rows) do
  reused_threads[thread.tid] = thread
end
assert(reused_threads[11].quality == "gap"
  and reused_threads[11].cpu_percent == nil,
  "a reused TID with a new starttime must not inherit a rate")
assert(reused_threads[11].name == "replacement",
  "the new thread under the reused TID is the one listed")

-- A thread that exits between the listing and the stat read is churn, not a
-- failed sample.
files["/proc/10/task/12/stat"] = nil
now = now + 1000000000
local raced = collector:sample(context(fake_fs(files, dirs), { ["10:5"] = true }),
  reused)
local raced_process = raced.data.by_id["10:5"]
assert(#raced_process.thread_rows == 2 and raced_process.thread_scan.races == 1,
  "a vanished task counts as a race and keeps the rest of the rows")

-- The task enumeration bound marks the scan truncated instead of hiding it.
local capped = Process.new({ read_status = false, max_detail_threads = 2 })
local capped_result = capped:sample(context(fake_fs(files, dirs), { ["10:5"] = true }))
local capped_process = capped_result.data.by_id["10:5"]
assert(#capped_process.thread_rows == 2 and capped_process.thread_scan.truncated == true,
  "hitting the thread limit reports truncation")

-- The overlay renders the rows the collector produced, CPU-sorted and capped.
local translator = assert(I18n.new({ locale = "zh-CN" }))
local display = {}
for index = 1, 18 do
  display[index] = { tid = 1000 + index, name = "thread-" .. index,
    state = "S", nice = 0, cpu_ticks = index, starttime_ticks = 5,
    cpu_percent = index, quality = "fresh" }
end
local lines = TUI.process_detail_lines({
  pid = 10, id = "10:5", name = "multi", threads = 20,
  thread_rows = display,
  thread_scan = { total = 20, scanned = 18, races = 0, truncated = false },
}, translator)
local header, shown, more = nil, 0, nil
local previous_cpu = math.huge
for _, line in ipairs(lines) do
  if line:find("TID", 1, true) and not header then
    header = line
  elseif header and line:match("^  %d+") then
    shown = shown + 1
    local cpu = tonumber(line:match("%s([%d%.]+%%)"):sub(1, -2))
    assert(cpu <= previous_cpu, "thread rows must be CPU-descending")
    previous_cpu = cpu
  elseif header and line:find("…", 1, true) then
    more = line
  end
end
assert(header and header:find("名称", 1, true) and header:find("线程", 1, true) == nil,
  "the thread table header carries the localized name column")
assert(shown == 16, "the overlay caps at 16 thread rows, got " .. shown)
assert(more and more:find("+4", 1, true),
  "rows beyond the cap are reported as a remainder, got " .. tostring(more))

-- The export field list must not grow thread internals by accident.
local exported = Export.snapshot({ processes = { list = { {
  id = "10:5", pid = 10, name = "multi", threads = 3,
  thread_rows = display, thread_ticks_by_tid = { [10] = { cpu_ticks = 1 } },
} } } }, { process_limit = 1 })
local encoded = json.encode(exported)
assert(not encoded:find("thread_rows", 1, true)
  and not encoded:find("thread_ticks", 1, true),
  "snapshot JSON must not carry detail-mode thread internals")

print("ok: process detail thread rows (collector, overlay, export boundary)")
return true
