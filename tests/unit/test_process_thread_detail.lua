-- Per-thread detail: what one thread of one process knows that the process
-- itself does not.
--
-- The process overlay already lists a process' threads, but a thread is a
-- schedulable task rather than a process: its context switches, its I/O and,
-- above all, its cgroup membership are tracked per task and can each differ
-- from the process the thread belongs to.  These tests pin the three things
-- that make that visible -- the extra reads happen for one TID only, the thread
-- group is read rather than assumed, and the cgroup comparison is stated
-- rather than left to the reader to diff two path lists by eye.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Process = require("wtop.collectors.process")
local Parsers = require("wtop.linux.parsers")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local json = require("wtop.format.json")
local Export = require("wtop.export")

-- ---------------------------------------------------------------------------
-- The status parser is the source of the thread group.
-- ---------------------------------------------------------------------------

local function status_file(spec)
  local lines = {
    "Name:\t" .. (spec.name or "thread"),
    "State:\t" .. (spec.state or "S (sleeping)"),
    "Tgid:\t" .. tostring(spec.tgid or spec.tid),
    "PPid:\t" .. tostring(spec.ppid or 1),
    "Uid:\t" .. tostring(spec.uid or 1000) .. "\t" .. tostring(spec.uid or 1000),
    "NSpid:\t" .. tostring(spec.tid),
  }
  if spec.voluntary then
    lines[#lines + 1] = "voluntary_ctxt_switches:\t" .. tostring(spec.voluntary)
  end
  if spec.involuntary then
    lines[#lines + 1] = "nonvoluntary_ctxt_switches:\t" .. tostring(spec.involuntary)
  end
  return table.concat(lines, "\n") .. "\n"
end

local parsed_status = assert(Parsers.process_status(
  status_file({ tid = 4242, tgid = 4200, voluntary = 512, involuntary = 7 })))
assert(parsed_status.tgid == 4200,
  "the thread group is parsed from status, got " .. tostring(parsed_status.tgid))
assert(parsed_status.voluntary_context_switches == 512
  and parsed_status.nonvoluntary_context_switches == 7,
  "per-thread context switches are read from the thread's own status")
assert(parsed_status.nspid and parsed_status.nspid[1] == 4242,
  "the thread keeps its own id chain")

-- A kernel that does not spell out the thread group must not be second-guessed
-- into one: an absent line is nil, never the reading's own tid.
local without_tgid = assert(Parsers.process_status("Name:\tx\nState:\tS (sleeping)\n"))
assert(without_tgid.tgid == nil, "a missing Tgid line yields nil, not a guess")
local broken_tgid, broken_tgid_error = Parsers.process_status("Tgid:\tnot-a-number\n")
assert(broken_tgid == nil and broken_tgid_error == "invalid_process_tgid",
  "a malformed Tgid line is rejected instead of being coerced")

-- ---------------------------------------------------------------------------
-- The collector reads three files, and only for the selected TID.
-- ---------------------------------------------------------------------------

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
  ["/proc/42/stat"] = stat_line({ pid = 42, comm = "server", threads = 3, starttime = 3 }),
  ["/proc/42/task/42/stat"] = stat_line({ pid = 42, comm = "server", starttime = 3 }),
  ["/proc/42/task/43/stat"] = stat_line({ pid = 43, comm = "worker", starttime = 3 }),
  ["/proc/42/task/44/stat"] = stat_line({ pid = 44, comm = "io-thread", starttime = 3 }),
  ["/proc/42/status"] = status_file({ tid = 42, tgid = 42, name = "server" }),
  ["/proc/42/cgroup"] = "0::/system.slice/server.service\n",
  ["/proc/42/task/43/status"] = status_file({ tid = 43, tgid = 42, name = "worker",
    state = "R (running)", voluntary = 900, involuntary = 12 }),
  ["/proc/42/task/43/cgroup"] = "0::/system.slice/server.service\n",
  ["/proc/42/task/43/io"] = "rchar: 4096\nwchar: 0\nsyscr: 3\nsyscw: 0\n" ..
    "read_bytes: 0\nwrite_bytes: 0\ncancelled_write_bytes: 0\n",
  -- Thread 44 is the one an operator would ask about: it does the I/O.
  ["/proc/42/task/44/status"] = status_file({ tid = 44, tgid = 42, name = "io-thread",
    state = "D (disk sleep)", voluntary = 5, involuntary = 900 }),
  -- ...and it is the one that was moved out of the process' cgroup.
  ["/proc/42/task/44/cgroup"] = "0::/system.slice/latency.target\n",
  ["/proc/42/task/44/io"] = "rchar: 8192\nwchar: 2048\nsyscr: 6\nsyscw: 2\n" ..
    "read_bytes: 4096\nwrite_bytes: 0\ncancelled_write_bytes: 0\n",
}
local dirs = {
  ["/proc"] = { "42" },
  ["/proc/42/task"] = { "42", "43", "44" },
}

local function fake_fs()
  return {
    read = function(_, path)
      reads[#reads + 1] = path
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

local now = 1000000000
local function context(thread_tid)
  return {
    fs = fake_fs(),
    now_ns = function() return now end,
    selected_process_ids = { ["42:3"] = true },
    selected_thread_ids = thread_tid and { [42] = thread_tid } or nil,
  }
end

local collector = Process.new({ read_status = false })

-- No thread selected: the detail pass must not run at all.
reads = {}
local base = collector:sample(context(nil))
assert(base.status == "ok", "fixture sample failed")
local base_process = base.data.by_id["42:3"]
assert(base_process.thread_details == nil,
  "an unselected thread must cost no reads and expose no detail")
for _, path in ipairs(reads) do
  assert(not path:find("/task/43/status", 1, true)
    and not path:find("/task/43/cgroup", 1, true)
    and not path:find("/task/43/io", 1, true),
    "a per-thread file was read without a thread selection: " .. path)
end

-- Thread 43 selected: exactly its three files, and nothing of its siblings'.
reads = {}
local selected = collector:sample(context(43), base)
local selected_process = selected.data.by_id["42:3"]
local detail = selected_process.thread_details
assert(type(detail) == "table" and detail[43],
  "the selected TID carries its own detail")
assert(detail[42] == nil and detail[44] == nil,
  "only the selected TID is read; a process with many threads must not scale")
local read_set = {}
for _, path in ipairs(reads) do read_set[path] = true end
for _, suffix in ipairs({ "status", "cgroup", "io" }) do
  assert(read_set["/proc/42/task/43/" .. suffix],
    "the selected thread's " .. suffix .. " must be read")
  assert(not read_set["/proc/42/task/44/" .. suffix],
    "a sibling thread's " .. suffix .. " must not be read")
end

assert(detail[43].tgid == 42,
  "the thread group names the owning process, got " .. tostring(detail[43].tgid))
assert(detail[43].state_text == "R (running)",
  "the status line spells the state out, got " .. tostring(detail[43].state_text))
assert(detail[43].voluntary_switches == 900 and detail[43].involuntary_switches == 12,
  "per-thread context switches come from the thread's own status")
assert(detail[43].io and detail[43].io.rchar == 4096,
  "per-thread I/O is read from the thread's own io file")
assert(detail[43].cgroups and detail[43].cgroups[1].path == "/system.slice/server.service",
  "the thread's own cgroup line is parsed")
assert(detail[43].source == "/proc/42/task/43",
  "the detail reports which files it came from")

-- A selection naming a TID that is not in this process reads nothing, rather
-- than attaching one process' thread detail to another.
local stranger = collector:sample(context(9999), selected)
assert(stranger.data.by_id["42:3"].thread_details == nil,
  "a thread id outside the process must not produce a detail entry")

-- A denied read is reported for that file alone: the rest of the thread is
-- still usable, and the sample is not thrown away over one permission.
local denied_fs = {
  read = function(_, path)
    if path == "/proc/42/task/44/cgroup" then
      return nil, { kind = "denied", message = "fixture_denied", path = path }
    end
    local value = files[path]
    if value == nil then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    return value
  end,
  list = fake_fs().list,
}
local denied_context = {
  fs = denied_fs,
  now_ns = function() return now end,
  selected_process_ids = { ["42:3"] = true },
  selected_thread_ids = { [42] = 44 },
}
local denied = collector:sample(denied_context, moved_sample)
local denied_detail = denied.data.by_id["42:3"].thread_details[44]
assert(denied.status == "ok" and denied_detail,
  "a denied per-thread file must not fail the sample")
assert(denied_detail.cgroup_error == "denied",
  "the denied file is named, got " .. tostring(denied_detail.cgroup_error))
assert(denied_detail.io and denied_detail.io.wchar == 2048,
  "the readable files of the same thread still arrive")

-- ---------------------------------------------------------------------------
-- The cgroup comparison.
-- ---------------------------------------------------------------------------

local same = TUI.compare_thread_cgroup(
  { { path = "/system.slice/server.service" } },
  { { path = "/system.slice/server.service" } })
assert(same == "same", "a thread in the process' cgroup reads as the same, got " ..
  tostring(same))

local verdict, differing = TUI.compare_thread_cgroup(
  { { path = "/system.slice/latency.target" } },
  { { path = "/system.slice/server.service" } })
assert(verdict == "differs" and differing and differing[1]
    and differing[1].path == "/system.slice/latency.target",
  "a thread in another unit reads as different and names its own path")

-- Mixed: one controller line matches and another does not.  Reporting only the
-- mismatching lines is what makes the difference visible at all.
local mixed, mixed_differing = TUI.compare_thread_cgroup(
  { { path = "/system.slice/server.service" }, { path = "/system.slice/latency.target" } },
  { { path = "/system.slice/server.service" } })
assert(mixed == "differs" and #mixed_differing == 1
    and mixed_differing[1].path == "/system.slice/latency.target",
  "only the mismatching controller lines are listed as different")

-- An unreadable cgroup is not evidence that the two match.
assert(TUI.compare_thread_cgroup(nil, { { path = "/x" } }) == nil,
  "a missing thread cgroup yields no verdict")
assert(TUI.compare_thread_cgroup({ { path = "/x" } }, {}) == nil,
  "a process with no readable cgroup yields no verdict")
assert(TUI.compare_thread_cgroup({ { path = "/x" } }, nil) == nil,
  "an absent process cgroup yields no verdict")

-- ---------------------------------------------------------------------------
-- The overlays.
-- ---------------------------------------------------------------------------

local translator = assert(I18n.new({ locale = "zh-CN" }))
local function find(lines, needle)
  for index, line in ipairs(lines) do
    if line:find(needle, 1, true) then return line, index end
  end
  return nil
end

local process = {
  pid = 42, id = "42:3", name = "server", user = "root",
  cgroups = { { hierarchy = 0, controllers = "", path = "/system.slice/server.service" } },
  thread_rows = {
    { tid = 42, name = "server", state = "S", nice = 0, priority = 20,
      cpu_ticks = 900, starttime_ticks = 3, leader = true,
      cpu_percent = 55.0, quality = "fresh" },
    { tid = 43, name = "worker", state = "R", nice = 0, priority = 20,
      cpu_ticks = 100, starttime_ticks = 3, leader = false,
      cpu_percent = 30.0, quality = "fresh" },
    { tid = 44, name = "io-thread", state = "D", nice = 0, priority = 20,
      cpu_ticks = 10, starttime_ticks = 3, leader = false,
      cpu_percent = 0.0, quality = "fresh" },
  },
  thread_scan = { total = 3, scanned = 3, races = 0, truncated = false },
  thread_details = selected_process.thread_details,
}

-- The picker lists every thread, hottest first, and marks the leader.
local picker = TUI.thread_picker_lines(process, { index = 2 }, translator, true)
local picker_titles = find(picker, "PID 42")
assert(picker_titles, "the picker names the process it belongs to")
local order = {}
for _, line in ipairs(picker) do
  -- Lua's `?` quantifier does not backtrack, so the two-character cursor
  -- marker is skipped with a class rather than an optional item.
  local tid = line:match("^%D*(%d+)%s+%S+%s")
  if tid and tonumber(tid) >= 42 and tonumber(tid) <= 44 then order[#order + 1] = tonumber(tid) end
end
assert(#order == 3, "the picker lists all three threads, got " .. #order)
assert(order[1] == 42 and order[2] == 43 and order[3] == 44,
  "the picker is ordered by CPU share, got " .. table.concat(order, ","))
assert(find(picker, "55.0%") and find(picker, "30.0%"),
  "the picker shows the per-thread CPU share")
assert(find(picker, "[主线程]"),
  "the thread group leader is marked so a worker is distinguishable")
-- Line 5 is the first thread row; the cursor was placed on the second.
local selected_line = picker[6]
assert(selected_line:find("▸", 1, true),
  "the cursor marks the selected thread, got " .. tostring(selected_line))
assert(not picker[5]:find("▸", 1, true),
  "only the selected thread carries the cursor")

-- A truncated scan says so instead of quietly showing a short list.
local truncated = TUI.thread_picker_lines({
  pid = 42, name = "server", thread_rows = process.thread_rows,
  thread_scan = { total = 900, scanned = 3, truncated = true },
}, { index = 1 }, translator, true)
assert(find(truncated, "3/900"), "a capped scan reports how many threads exist")

-- No threads at all is a sentence, not an empty table.
local empty = TUI.thread_picker_lines({ pid = 42, name = "server" },
  { index = 1 }, translator, true)
assert(find(empty, "没有可读的线程"),
  "an unreadable process explains itself rather than showing no rows")

-- The detail view of a thread in the process' own cgroup.
local worker_detail = {
  tid = 43, name = "worker", state = "R", nice = 0, priority = 20,
  cpu_ticks = 100, starttime_ticks = 3, cpu_percent = 30.0, quality = "fresh",
}
local lines = TUI.thread_detail_lines(worker_detail, detail[43], process, translator)
assert(find(lines, "线程详情 · TID 43"), "the detail titles itself with the TID")
assert(find(lines, "server 的线程 · PID 42"),
  "the detail names the process the thread belongs to")
assert(find(lines, "线程组"):match("线程组%s+42$"),
  "the thread group is shown, got " .. tostring(find(lines, "线程组")))
assert(find(lines, "R (running)"),
  "the spelled-out state is preferred over the single letter")
assert(find(lines, "系统调用读"):match("4 KiB$")
    and find(lines, "系统调用写"),
  "the syscall I/O pair is shown, not only the block-layer pair")
assert(find(lines, "与所属进程相同"),
  "a thread in the process' cgroup says so")
assert(not find(lines, "latency.target"),
  "a matching thread does not print another unit's path")

-- The detail view of a thread that was moved out of the process' cgroup.  This
-- is the case the whole feature exists for: it is invisible in every
-- per-process view.  Selecting it is what reads it -- thread 44 has no detail
-- in the sample above, because only thread 43 was selected there.
local moved_sample = collector:sample(context(44), stranger)
local moved_process = moved_sample.data.by_id["42:3"]
assert(moved_process.thread_details[44]
    and moved_process.thread_details[44].cgroups[1].path == "/system.slice/latency.target",
  "selecting the thread is what reads it")
local moved = TUI.thread_detail_lines(
  { tid = 44, name = "io-thread", state = "D", nice = 0, priority = 20,
    cpu_ticks = 10, starttime_ticks = 3, cpu_percent = 0.0, quality = "fresh" },
  moved_process.thread_details[44], process, translator)
assert(find(moved, "不在所属进程的控制组中"),
  "a thread outside the process' cgroup says so")
assert(find(moved, "latency.target"),
  "the thread's own unit is named")
assert(find(moved, "进程所在："),
  "the process' own cgroup is printed next to it")
assert(find(moved, "server.service"),
  "the process' path is shown so the difference is actionable")

-- Before the collector has read this thread, the overlay says so.  An overlay
-- full of em dashes reads as "this thread has no I/O", which is a different
-- and wrong claim.
local pending = TUI.thread_detail_lines(worker_detail, nil, process, translator)
assert(find(pending, "正在读取该线程"),
  "an unread thread is announced rather than rendered blank")
assert(not find(pending, "系统调用读"),
  "nothing is invented before the read lands")

-- A thread that exited between the pick and the read.
local gone = TUI.thread_detail_lines(nil, nil, process, translator)
assert(find(gone, "已不属于此进程"),
  "a thread that is no longer listed says so instead of rendering an empty page")

-- The detail names the files it read, so a stale or partial view is
-- attributable.
assert(find(lines, "/proc/42/task/43"),
  "the source path of the per-thread read is shown")

-- The process overlay and the picker must not disagree about thread order, or
-- a row moves between the two views under the operator's cursor.
local detail_lines = TUI.process_detail_lines(process, translator)
local overlay_order = {}
local in_table = false
for _, line in ipairs(detail_lines) do
  if line:find("TID", 1, true) and line:find("CPU%", 1, true) then in_table = true
  elseif in_table then
    local tid = line:match("^  (%d+)%s")
    if tid then overlay_order[#overlay_order + 1] = tonumber(tid) end
  end
end
assert(#overlay_order >= 3, "the overlay table still lists the threads")
for index, tid in ipairs(overlay_order) do
  assert(tid == order[index],
    string.format("row %d is TID %d in the overlay but %d in the picker",
      index, tid, order[index]))
end

-- The action hint may only advertise keys that work.  `k` reaches the signal
-- menu from the process table, not from inside an open overlay, so naming it
-- here was a claim the overlay could not keep.
local hint = TUI.process_detail_lines(process, translator)
local hint_line = find(hint, "滚动")
assert(hint_line and hint_line:find("i 线程", 1, true),
  "the hint names the thread drill-down")
assert(not hint_line:find("k", 1, true),
  "the hint must not advertise a key the overlay ignores: " .. tostring(hint_line))

-- The process I/O section gained the syscall pair; the thread view would
-- otherwise be showing a number the process view hides.
local io_section = find(hint, "系统调用读")
assert(io_section, "the process I/O section carries the same pair as the thread view")

-- ---------------------------------------------------------------------------
-- The export boundary.
-- ---------------------------------------------------------------------------

local exported = Export.snapshot({ processes = { list = { {
  id = "42:3", pid = 42, name = "server", threads = 3,
  thread_rows = process.thread_rows,
  thread_details = process.thread_details,
} } } }, { process_limit = 1 })
local encoded = json.encode(exported)
assert(not encoded:find("thread_rows", 1, true)
  and not encoded:find("thread_details", 1, true),
  "snapshot JSON must not carry per-thread detail internals")

print("ok: per-thread detail (collector reads, cgroup verdict, picker, detail, export)")
return true
