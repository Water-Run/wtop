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
  if spec.cpus then
    lines[#lines + 1] = "Cpus_allowed_list:\t" .. spec.cpus
    lines[#lines + 1] = "Mems_allowed_list:\t" .. (spec.mems or "0")
  end
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
-- The collector reads one selected TID's files and FD directory.
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

local reads, lists = {}, {}
local files = {
  ["/proc/42/stat"] = stat_line({ pid = 42, comm = "server", threads = 3, starttime = 3 }),
  ["/proc/42/task/42/stat"] = stat_line({ pid = 42, comm = "server", starttime = 3 }),
  ["/proc/42/task/43/stat"] = stat_line({ pid = 43, comm = "worker", starttime = 3 }),
  ["/proc/42/task/44/stat"] = stat_line({ pid = 44, comm = "io-thread", starttime = 3 }),
  ["/proc/42/status"] = status_file({ tid = 42, tgid = 42, name = "server",
    cpus = "0-1", mems = "0-1" }),
  ["/proc/42/cgroup"] = "0::/system.slice/server.service\n",
  ["/proc/42/wchan"] = "do_wait\n",
  ["/proc/42/limits"] = "Max open files 1024 4096 files\n",
  ["/proc/42/task/43/status"] = status_file({ tid = 43, tgid = 42, name = "worker",
    state = "R (running)", voluntary = 900, involuntary = 12,
    cpus = "0", mems = "0" }),
  ["/proc/42/task/43/cgroup"] = "0::/system.slice/server.service\n",
  ["/proc/42/task/43/wchan"] = "0\n",
  ["/proc/42/task/43/io"] = "rchar: 4096\nwchar: 0\nsyscr: 3\nsyscw: 0\n" ..
    "read_bytes: 0\nwrite_bytes: 0\ncancelled_write_bytes: 0\n",
  -- Thread 44 is the one an operator would ask about: it does the I/O.
  ["/proc/42/task/44/status"] = status_file({ tid = 44, tgid = 42, name = "io-thread",
    state = "D (disk sleep)", voluntary = 5, involuntary = 900,
    cpus = "1", mems = "1" }),
  -- ...and it is the one that was moved out of the process' cgroup.
  ["/proc/42/task/44/cgroup"] = "0::/system.slice/latency.target\n",
  ["/proc/42/task/44/wchan"] = "io_schedule\n",
  ["/proc/42/task/44/io"] = "rchar: 8192\nwchar: 2048\nsyscr: 6\nsyscw: 2\n" ..
    "read_bytes: 4096\nwrite_bytes: 0\ncancelled_write_bytes: 0\n",
}
local dirs = {
  ["/proc"] = { "42" },
  ["/proc/42/task"] = { "42", "43", "44" },
  ["/proc/42/fd"] = { "0", "1", "2" },
  ["/proc/42/task/43/fd"] = { "0", "1", "2", "7" },
  ["/proc/42/task/44/fd"] = { "0", "1" },
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
      lists[#lists + 1] = path
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

-- Repeated samples of this fixture use the same procfs provider.
local process_fs = fake_fs()
local now = 1000000000
local function context(thread_tid)
  return {
    fs = process_fs,
    now_ns = function() return now end,
    selected_process_ids = { ["42:3"] = true },
    selected_thread_ids = thread_tid and { [42] = thread_tid } or nil,
  }
end

local collector = Process.new({ read_status = false })
assert(next(TUI.thread_detail_request({ mode = "picker" },
  { pid = 42 }, { tid = 43 })) == nil,
  "moving through the thread picker must not request per-thread file reads")
local task_request = TUI.thread_detail_request({ mode = "detail", tid = 43,
  starttime_ticks = 3 }, { pid = 42 }, { tid = 43, starttime_ticks = 3 })[42]
assert(task_request.tid == 43 and task_request.starttime_ticks == 3,
  "opening the selected task requests its TID and start time")
assert(next(TUI.thread_detail_request({ mode = "detail", tid = 43,
  starttime_ticks = 3 }, { pid = 42 }, { tid = 43, starttime_ticks = 9 })) == nil,
  "a recycled TID must not inherit the open thread detail")
assert(next(TUI.thread_detail_request({ mode = "detail" },
  { pid = 42 }, nil)) == nil,
  "an exited thread cannot leave a stale detail request")

reads, lists = {}, {}
local picker_context = context(nil)
picker_context.selected_process_ids = {}
picker_context.selected_process_thread_list_ids = { ["42:3"] = true }
local picker_sample = collector:sample(picker_context)
local picker_process = picker_sample.data.by_id["42:3"]
assert(picker_process.thread_rows and #picker_process.thread_rows == 3
  and picker_process.thread_details == nil
  and picker_process.fd_detail == nil,
  "the thread picker updates the task rows without opening process or task detail")
assert(picker_process.wait_site_status == nil,
  "a closed process detail must not read its kernel wait site")
for _, path in ipairs(reads) do
  assert(not path:find("/io", 1, true)
    and not path:find("/smaps_rollup", 1, true)
    and not path:find("/wchan", 1, true)
    and not path:find("/task/43/status", 1, true),
    "picker-only sampling opened an unused detail file: " .. path)
end
for _, path in ipairs(lists) do
  assert(path ~= "/proc/42/fd" and path ~= "/proc/42/task/43/fd",
    "picker-only sampling must not enumerate an FD table")
end

-- The broad scan reads status once for a new identity. Later scans reuse the
-- last observed allowed set; opening process detail refreshes it immediately.
local affinity_collector = Process.new({ read_status = true })
local function scan_context()
  local value = context(nil)
  value.selected_process_ids = {}
  return value
end
reads = {}
local affinity_first = affinity_collector:sample(scan_context())
local affinity_process = affinity_first.data.by_id["42:3"]
assert(affinity_process.affinity.cpus_allowed_list == "0-1"
  and affinity_process.affinity.cpus_allowed_count == 2
  and affinity_process.affinity.observed_ns == now,
  "the leader mask is captured during its first status read")
local first_status_reads = 0
for _, path in ipairs(reads) do
  if path == "/proc/42/status" then first_status_reads = first_status_reads + 1 end
end
assert(first_status_reads == 1, "one status read is enough for the first scan")
files["/proc/42/status"] = status_file({ tid = 42, tgid = 42,
  name = "server", cpus = "1", mems = "1" })
now = now + 1000000000
reads = {}
local affinity_cached = affinity_collector:sample(scan_context(), affinity_first)
assert(affinity_cached.data.by_id["42:3"].affinity.cpus_allowed_list == "0-1"
  and affinity_cached.data.by_id["42:3"].affinity.observed_ns == now - 1000000000,
  "a cached affinity retains its original observation time")
for _, path in ipairs(reads) do
  assert(path ~= "/proc/42/status", "the cached mask must not add a status read")
end
reads = {}
local affinity_selected = affinity_collector:sample(context(43), affinity_cached)
assert(affinity_selected.data.by_id["42:3"].affinity.cpus_allowed_list == "1"
  and affinity_selected.data.by_id["42:3"].affinity.observed_ns == now,
  "selected process detail refreshes its leader mask")
local refreshed = false
for _, path in ipairs(reads) do
  if path == "/proc/42/status" then refreshed = true end
end
assert(refreshed, "selected detail must actually reread the leader's status")
files["/proc/42/status"] = status_file({ tid = 42, tgid = 42, name = "server",
  cpus = "0-1", mems = "0-1" })
now = 1000000000

-- No thread selected: the detail pass must not run at all.
reads, lists = {}, {}
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
for _, path in ipairs(lists) do
  assert(not path:find("/task/43/fd", 1, true),
    "an unselected thread must not enumerate its FD directory")
end

-- Thread 43 selected: its files and FD directory, nothing of its siblings'.
reads, lists = {}, {}
local selected = collector:sample(context(43), base)
local selected_process = selected.data.by_id["42:3"]
local detail = selected_process.thread_details
assert(type(detail) == "table" and detail[43],
  "the selected TID carries its own detail")
assert(selected_process.wait_site == "do_wait"
  and selected_process.wait_site_status == "ok"
  and detail[43].wait_site == nil
  and detail[43].wait_site_status == "not_reported",
  "process and selected thread report distinct wait sites, including kernel 0")
assert(detail[42] == nil and detail[44] == nil,
  "only the selected TID is read; a process with many threads must not scale")
local read_set = {}
for _, path in ipairs(reads) do read_set[path] = true end
for _, suffix in ipairs({ "status", "cgroup", "io", "wchan" }) do
  assert(read_set["/proc/42/task/43/" .. suffix],
    "the selected thread's " .. suffix .. " must be read")
  assert(not read_set["/proc/42/task/44/" .. suffix],
    "a sibling thread's " .. suffix .. " must not be read")
end
local thread_fd_seen, sibling_fd_seen = false, false
for _, path in ipairs(lists) do
  if path == "/proc/42/task/43/fd" then thread_fd_seen = true end
  if path == "/proc/42/task/44/fd" then sibling_fd_seen = true end
end
assert(thread_fd_seen and not sibling_fd_seen,
  "only the selected TID's descriptor table is enumerated")

assert(detail[43].tgid == 42,
  "the thread group names the owning process, got " .. tostring(detail[43].tgid))
assert(detail[43].starttime_ticks == 3,
  "the verified task generation must accompany its cgroup reading")
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
assert(detail[43].affinity.cpus_allowed_list == "0"
  and detail[43].affinity.cpus_allowed_count == 1
  and detail[43].affinity.mems_allowed_list == "0"
  and detail[43].affinity.observed_ns == now,
  "selected thread affinity comes from that TID's status")
assert(selected_process.fd_detail.count == 3
  and detail[43].fd_detail.count == 4
  and detail[43].fd_detail.status == "ok"
  and detail[43].fd_detail.observed_ns == now,
  "a thread can report a different FD count from its leader")

-- A selection naming a TID that is not in this process reads nothing, rather
-- than attaching one process' thread detail to another.
local stranger = collector:sample(context(9999), selected)
assert(stranger.data.by_id["42:3"].thread_details == nil,
  "a thread id outside the process must not produce a detail entry")
reads, lists = {}, {}
local original_task_stat = files["/proc/42/task/43/stat"]
files["/proc/42/task/43/stat"] = stat_line({ pid = 43,
  comm = "replacement", starttime = 99 })
local recycled_request = collector:sample(context({ tid = 43, starttime_ticks = 3 }),
  selected)
assert(recycled_request.data.by_id["42:3"].thread_details == nil,
  "a task with the same TID but a different start time cannot satisfy the selection")
for _, path in ipairs(reads) do
  assert(not path:find("/task/43/status", 1, true)
    and not path:find("/task/43/io", 1, true)
    and not path:find("/task/43/wchan", 1, true),
    "a generation mismatch must not read the new task's detail: " .. path)
end
files["/proc/42/task/43/stat"] = original_task_stat
local racing_fs = fake_fs()
local regular_read = racing_fs.read
local task_stat_reads = 0
racing_fs.read = function(self, path, limit)
  if path == "/proc/42/task/43/stat" then
    task_stat_reads = task_stat_reads + 1
    if task_stat_reads == 2 then
      return stat_line({ pid = 43, comm = "replacement", starttime = 99 })
    end
  end
  return regular_read(self, path, limit)
end
local racing_context = context({ tid = 43, starttime_ticks = 3 })
racing_context.fs = racing_fs
local raced_detail = collector:sample(racing_context, selected).data.by_id["42:3"]
assert(task_stat_reads == 2 and raced_detail.thread_details == nil
  and raced_detail.thread_scan.races == 1
  and #raced_detail.thread_rows == 2,
  "a task recycled during supplemental reads is removed with its mixed detail")

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
local denied = collector:sample(denied_context, stranger)
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
  affinity = affinity_process.affinity,
  wait_site = selected_process.wait_site,
  wait_site_status = selected_process.wait_site_status,
  fd_detail = selected_process.fd_detail,
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
assert(find(lines, "内核等待位置"):find("未报告休眠位置", 1, true),
  "kernel 0 is described as unreported, not as a function")
assert(find(lines, "允许的 CPU"):find("0", 1, true)
  and find(lines, "允许的内存节点"):find("0", 1, true),
  "thread details display its own allowed CPU and memory-node sets")
assert(find(lines, "该线程打开的文件描述符"):find("4", 1, true)
  and find(lines, "首线程打开的文件描述符"):find("3", 1, true),
  "thread detail shows both observed counts without claiming shared tables")
assert(find(lines, "系统调用读"):match("4 KiB$")
    and find(lines, "系统调用写"),
  "the syscall I/O pair is shown, not only the block-layer pair")
assert(find(lines, "与所属进程相同"),
  "a thread in the process' cgroup says so")
assert(find(lines, "g 打开此线程的工作负载"),
  "the thread detail offers its own workload jump")
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
assert(moved_process.thread_details[44].wait_site == "io_schedule"
  and moved_process.thread_details[44].wait_site_status == "ok",
  "a sleeping thread displays its own kernel wait site")
local moved = TUI.thread_detail_lines(
  { tid = 44, name = "io-thread", state = "D", nice = 0, priority = 20,
    cpu_ticks = 10, starttime_ticks = 3, cpu_percent = 0.0, quality = "fresh" },
  moved_process.thread_details[44], process, translator)
assert(find(moved, "不在所属进程的控制组中"),
  "a thread outside the process' cgroup says so")
assert(find(moved, "latency.target"),
  "the thread's own unit is named")
assert(find(moved, "内核等待位置"):find("io_schedule", 1, true)
  and find(moved, "不能据此诊断原因"),
  "the selected thread shows a kernel function without calling it a diagnosis")
assert(find(moved, "允许的 CPU"):find("1", 1, true)
  and find(moved, "允许的内存节点"):find("1", 1, true),
  "a sibling's different allowed sets remain visible")
assert(moved_process.thread_details[44].fd_detail.count == 2
  and find(moved, "该线程打开的文件描述符"):find("2", 1, true),
  "the sibling's own descriptor count remains distinct")
lists = {}
local leader_sample = collector:sample(context(42), moved_sample)
local leader_process = leader_sample.data.by_id["42:3"]
assert(leader_process.thread_details[42].fd_detail == leader_process.fd_detail,
  "selecting the leader reuses the already observed descriptor table")

local denied_wait_fs = fake_fs()
local original_read = denied_wait_fs.read
denied_wait_fs.read = function(self, path, limit)
  if path:match("/wchan$") then
    return nil, { kind = "denied", message = "fixture_denied", path = path }
  end
  return original_read(self, path, limit)
end
local denied_wait_context = context(44)
denied_wait_context.fs = denied_wait_fs
local denied_wait_process = collector:sample(denied_wait_context, leader_sample)
  .data.by_id["42:3"]
assert(denied_wait_process.wait_site == nil
  and denied_wait_process.wait_site_status == "denied"
  and denied_wait_process.thread_details[44].wait_site_status == "denied",
  "wchan permission failures do not become zeros or erase the process")
assert(find(TUI.process_detail_lines(denied_wait_process, translator),
  "内核等待位置"):find("无权限", 1, true),
  "the process view reports a denied wait-site read")
files["/proc/42/task/44/wchan"] = "unsafe\nsecond_line\n"
local malformed_wait = collector:sample(context(44), denied_wait_process)
  .data.by_id["42:3"].thread_details[44]
assert(malformed_wait.wait_site == nil and malformed_wait.wait_site_status == "parse_error",
  "a malformed symbol cannot inject another detail line")
assert(find(TUI.thread_detail_lines(worker_detail, malformed_wait,
  denied_wait_process, translator), "内核等待位置"):find("错误", 1, true),
  "the thread view localizes a malformed wait-site reading")
files["/proc/42/task/44/wchan"] = string.rep("x", 257)
local oversized_wait = collector:sample(context(44), denied_wait_process)
  .data.by_id["42:3"].thread_details[44]
assert(oversized_wait.wait_site == nil and oversized_wait.wait_site_status == "parse_error",
  "a wait-site symbol remains bounded even with a permissive filesystem adapter")
files["/proc/42/task/44/wchan"] = ""
local empty_wait = collector:sample(context(44), denied_wait_process)
  .data.by_id["42:3"].thread_details[44]
assert(empty_wait.wait_site == nil and empty_wait.wait_site_status == "parse_error",
  "an empty read is malformed rather than the kernel's explicit zero")
files["/proc/42/task/44/wchan"] = "io_schedule\n"
for _, path in ipairs(lists) do
  assert(path ~= "/proc/42/task/42/fd",
    "the leader's task alias must not cause another directory walk")
end

local denied_fd_fs = fake_fs()
local original_list = denied_fd_fs.list
denied_fd_fs.list = function(self, path, limit)
  if path == "/proc/42/task/43/fd" then
    return nil, { kind = "denied", message = "fixture_denied", path = path }
  end
  return original_list(self, path, limit)
end
local denied_fd_context = context(43)
denied_fd_context.fs = denied_fd_fs
local denied_fd_process = collector:sample(denied_fd_context, leader_sample)
  .data.by_id["42:3"]
local denied_fd_detail = denied_fd_process.thread_details[43]
assert(denied_fd_detail.fd_detail.count == nil
  and denied_fd_detail.fd_detail.status == "denied"
  and denied_fd_detail.io.rchar == 4096,
  "a denied task FD directory does not turn into zero or erase readable thread I/O")
local denied_fd_lines = TUI.thread_detail_lines(worker_detail,
  denied_fd_detail, denied_fd_process, translator)
assert(find(denied_fd_lines, "该线程打开的文件描述符"):find("无权限", 1, true),
  "thread detail names an inaccessible FD directory")

local truncated_fd_fs = fake_fs()
local base_list = truncated_fd_fs.list
truncated_fd_fs.list = function(self, path, limit)
  if path == "/proc/42/task/43/fd" then
    assert(limit == 4096)
    return { "0", "1" }, nil, true
  end
  return base_list(self, path, limit)
end
local truncated_fd_context = context(43)
truncated_fd_context.fs = truncated_fd_fs
local truncated_fd_process = collector:sample(truncated_fd_context, leader_sample)
  .data.by_id["42:3"]
local truncated_fd_detail = truncated_fd_process.thread_details[43]
assert(truncated_fd_detail.fd_detail.status == "truncated"
  and truncated_fd_detail.fd_detail.count == 2,
  "the task FD scan keeps its lower bound when capped")
assert(find(TUI.thread_detail_lines(worker_detail, truncated_fd_detail,
  truncated_fd_process, translator), "该线程打开的文件描述符"):find(">=2", 1, true),
  "the displayed thread FD count marks a lower bound in ASCII")
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
assert(not find(pending, "g 打开此线程的工作负载"),
  "a pending read does not offer the process workload as a thread target")
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
assert(find(detail_lines, "首线程内核等待位置"):find("do_wait", 1, true)
  and find(detail_lines, "不能据此诊断原因"),
  "process detail shows the kernel function with its interpretation limit")
assert(find(detail_lines, "首线程允许的 CPU"):find("0-1", 1, true)
  and find(detail_lines, "首线程允许的内存节点"):find("0-1", 1, true),
  "process detail labels the leader's allowed sets, not all threads' sets")
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
