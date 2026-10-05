-- Per-thread scheduling: how long a thread was queued for a cpu, and under
-- which policy.
--
-- Everything the process table shows about a thread is either derived from the
-- same counters for the whole process or is a single-letter state code.  What
-- it cannot say is why a thread is slow: a thread that is starved looks exactly
-- like a thread that is busy, because both are running.  The run-queue wait is
-- the number that separates them, and the policy is the reason a thread can be
-- starved on purpose.
--
-- The read rests on /proc/<pid>/task/<tid>/schedstat rather than on /sched,
-- because schedstat is a fixed three-number ABI while sched's field set changes
-- with the kernel version and its build options.  These tests pin that choice,
-- the rate arithmetic, the TID-recycling guard, and the refusal to render a
-- rate that no interval supports.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Process = require("wtop.collectors.process")
local Parsers = require("wtop.linux.parsers")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")

-- ---------------------------------------------------------------------------
-- schedstat is three numbers and nothing else.
-- ---------------------------------------------------------------------------

local stat = assert(Parsers.thread_schedstat("  732423114 6950190 1102\n"))
assert(stat.run_ns == 732423114 and stat.wait_ns == 6950190
  and stat.timeslices == 1102, "the three schedstat fields are read in order")

-- Real /proc content, captured verbatim from a busy thread on this host.
local busy = assert(Parsers.thread_schedstat("24887565 92782 61"))
assert(busy.run_ns == 24887565 and busy.wait_ns == 92782 and busy.timeslices == 61,
  "unpadded schedstat parses the same way")

-- A file the kernel did not write in this shape is refused rather than
-- partially read: half a scheduler reading is worse than none.
for _, bad in ipairs({ "1 2", "1 2 3 4", "a b c", "" }) do
  local parsed, err = Parsers.thread_schedstat(bad)
  assert(parsed == nil and err == "invalid_thread_schedstat",
    "malformed schedstat must be refused, got " .. tostring(err) .. " for " .. bad)
end
assert(select(1, Parsers.thread_schedstat(nil)) == nil, "schedstat needs content")

-- ---------------------------------------------------------------------------
-- sched is whitelist-parsed, because its field set is not stable.
-- ---------------------------------------------------------------------------

-- A real /proc/<pid>/task/<tid>/sched header and the keys this host prints.
local real_sched = table.concat({
  "python3 (737322, #threads: 8)",
  "-------------------------------------------------------------------",
  "se.exec_start                                :      27835485.123951",
  "se.sum_exec_runtime                          :            24.887565",
  "nr_switches                                  :                   61",
  "nr_voluntary_switches                        :                   55",
  "nr_involuntary_switches                     :                    6",
  "policy                                       :                    0",
  "prio                                         :                  120",
  "clock-delta                                  :                  266",
}, "\n") .. "\n"
local sched = assert(Parsers.thread_sched(real_sched))
assert(sched.policy == 0, "the policy is read, got " .. tostring(sched.policy))
-- Everything else is deliberately dropped: sched is a debug interface and a
-- kernel that renames a key must not change what this view claims.
assert(sched.sum_exec_runtime == nil and sched.prio == nil,
  "only the policy crosses the boundary from sched")

-- A kernel that does not print the policy yields no policy -- which is not the
-- same as a policy of zero, and must not be collapsed into one.
local no_policy = assert(Parsers.thread_sched("x (1)\n---\nprio : 120\n"))
assert(no_policy.policy == nil,
  "an absent policy key is nil, never a defaulted SCHED_OTHER")

-- Policy values are the stable public ABI from include/uapi/linux/sched.h.
for _, text in ipairs({
  "policy : 0", "policy : 1", "policy : 2", "policy : 3",
  "policy : 5", "policy : 6", "policy : 7",
}) do
  local expected = tonumber(text:match("(%d+)"))
  assert(assert(Parsers.thread_sched("h\n" .. text .. "\n")).policy == expected,
    "policy " .. text .. " parses as " .. expected)
end

-- ---------------------------------------------------------------------------
-- The collector reads both files, and only for the selected TID.
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

local function status_file(spec)
  return table.concat({
    "Name:\t" .. (spec.name or "thread"),
    "State:\t" .. (spec.state or "S (sleeping)"),
    "Tgid:\t" .. tostring(spec.tgid or spec.tid),
    "Uid:\t1000\t1000\t1000\t1000",
  }, "\n") .. "\n"
end

local function sched_file(policy)
  return "worker (700, #threads: 2)\n---\npolicy  :  " .. (policy or 0) .. "\nprio    :  120\n"
end

local function schedstat_file(run_ns, wait_ns, slices)
  return string.format("%d %d %d\n", run_ns, wait_ns, slices)
end

local reads = {}
local files = {
  ["/proc/700/stat"] = stat_line({ pid = 700, comm = "server", threads = 2, starttime = 7 }),
  ["/proc/700/task/700/stat"] = stat_line({ pid = 700, comm = "server", starttime = 7 }),
  ["/proc/700/task/701/stat"] = stat_line({ pid = 701, comm = "worker", starttime = 7 }),
  ["/proc/700/task/701/status"] = status_file({ tid = 701, tgid = 700, name = "worker" }),
  ["/proc/700/task/701/cgroup"] = "0::/system.slice/server.service\n",
  ["/proc/700/task/701/io"] = "rchar: 0\nwchar: 0\nread_bytes: 0\nwrite_bytes: 0\n",
  ["/proc/700/task/701/schedstat"] = schedstat_file(732423114, 6950190, 1102),
  ["/proc/700/task/701/sched"] = sched_file(0),
}
local dirs = {
  ["/proc"] = { "700" },
  ["/proc/700/task"] = { "700", "701" },
}

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
local function context(tid, overrides)
  return {
    fs = fake_fs(overrides),
    now_ns = function() return now end,
    selected_process_ids = { ["700:7"] = true },
    selected_thread_ids = tid and { [700] = tid } or nil,
  }
end

local collector = Process.new({ read_status = false })

-- No thread selected: the scheduler files must not be read at all.
reads = {}
local first = collector:sample(context(nil))
assert(first.status == "ok", "fixture sample failed")
assert(first.data.by_id["700:7"].thread_details == nil,
  "an unselected thread exposes no detail")
for _, path in ipairs(reads) do
  assert(not path:find("schedstat", 1, true) and not path:find("/sched", 1, true),
    "a scheduler file was read without a thread selection: " .. path)
end

-- First reading: cumulative counters, but no rate, because there is no
-- interval to divide by yet.
local opened = collector:sample(context(701), first)
local scheduler = opened.data.by_id["700:7"].thread_details[701].scheduler
assert(scheduler.status == nil, "a successful read carries no error status")
assert(scheduler.run_ns == 732423114 and scheduler.wait_ns == 6950190
  and scheduler.timeslices == 1102, "the cumulative counters are carried through")
assert(scheduler.policy == 0, "the policy is read from sched")
assert(scheduler.quality == "gap" and scheduler.wait_rate_ns == nil
  and scheduler.timeslice_rate == nil,
  "a first reading has no rate; a rate divided by nothing would be a fiction")

-- A second reading one second later produces the rates.  The thread ran for
-- another 500 ms of a second and queued for 4 ms of it.
files["/proc/700/task/701/schedstat"] = schedstat_file(1224233114, 10950190, 1182)
now = now + 1000000000
local second = collector:sample(context(701), opened)
local rated = second.data.by_id["700:7"].thread_details[701].scheduler
assert(rated.quality == "fresh", "a second reading is differenced")
assert(rated.interval_ns == 1000000000, "the interval is the one that elapsed")
local function near(actual, expected, tolerance)
  assert(type(actual) == "number", "expected a number, got " .. tostring(actual))
  assert(math.abs(actual - expected) <= (tolerance or 0.001),
    string.format("expected ~%s, got %s", expected, tostring(actual)))
end
near(rated.wait_rate_ns, 4000000, 1)          -- 4 ms of queueing per second
near(rated.timeslice_rate, 80, 0.001)         -- 80 further timeslices

-- The interval is the gap since *this thread* was last read, not since the
-- last tick.  Moving the cursor away and back must not silently rescale a
-- two-second span into a one-second rate.
now = now + 1000000000
local away = collector:sample(context(nil), second)
assert(away.data.by_id["700:7"].thread_details == nil,
  "moving the cursor away releases the per-thread read")
files["/proc/700/task/701/schedstat"] = schedstat_file(1724233114, 10950190, 1242)
now = now + 1000000000
local resumed = collector:sample(context(701), away)
local resumed_scheduler = resumed.data.by_id["700:7"].thread_details[701].scheduler
assert(resumed_scheduler.interval_ns == 2000000000,
  "the rate covers the whole gap, got " .. tostring(resumed_scheduler.interval_ns))
near(resumed_scheduler.timeslice_rate, 30, 0.001)   -- 60 slices over two seconds

-- A TID recycled by a different thread must not inherit the previous thread's
-- counters: a rate computed across two unrelated tasks is worse than no rate.
files["/proc/700/task/701/stat"] =
  stat_line({ pid = 701, comm = "replacement", starttime = 99 })
now = now + 1000000000
local recycled = collector:sample(context(701), resumed)
local recycled_scheduler = recycled.data.by_id["700:7"].thread_details[701].scheduler
assert(recycled_scheduler.quality == "gap" and recycled_scheduler.wait_rate_ns == nil,
  "a reused TID must not inherit a rate from the thread that held the id")

-- A kernel without CONFIG_SCHEDSTATS does not create the file.  That is the
-- kernel declining to publish the figure and must not look like a thread that
-- never waited.  The status names *that file* rather than the whole scheduler
-- group: the status file this thread is already read for its thread group
-- still carries the switch counters, so a family that lost schedstat has not
-- lost everything, and a bare `status` here would say it had.
local without = collector:sample(context(701, {
  ["/proc/700/task/701/schedstat"] = false,
}), recycled)
local missing = without.data.by_id["700:7"].thread_details[701].scheduler
assert(missing.schedstat_status == "unavailable",
  "an absent schedstat is unavailable, got " .. tostring(missing.schedstat_status))
assert(missing.wait_rate_ns == nil and missing.run_ns == nil,
  "an absent schedstat carries no figures at all")

-- schedstat present but sched denied: the policy is lost and named, while the
-- counters -- the part that cannot be read anywhere else -- still arrive.
local partial = collector:sample(context(701, {
  ["/proc/700/task/701/schedstat"] = schedstat_file(1724233114, 10950190, 1242),
  ["/proc/700/task/701/sched"] = false,
}), without)
local partial_scheduler = partial.data.by_id["700:7"].thread_details[701].scheduler
assert(partial_scheduler.run_ns == 1724233114,
  "the schedstat figures survive a denied sched")
assert(partial_scheduler.policy == nil and partial_scheduler.policy_status == "unavailable",
  "the missing policy is named as missing, not defaulted to SCHED_OTHER")

-- ---------------------------------------------------------------------------
-- The overlay.
-- ---------------------------------------------------------------------------

local translator = assert(I18n.new({ locale = "zh-CN" }))
local thread = {
  tid = 701, name = "worker", state = "S", nice = 0, priority = 120,
  cpu_ticks = 7324, starttime_ticks = 7, cpu_percent = 49.1, quality = "fresh",
}
local process = {
  pid = 700, name = "server",
  cgroups = { { hierarchy = 0, controllers = "", path = "/system.slice/server.service" } },
}
local function detail_with(sched)
  return {
    tid = 701, tgid = 700, state_text = "S (sleeping)",
    cgroups = process.cgroups, source = "/proc/700/task/701",
    scheduler = sched,
  }
end
local function find(lines, needle)
  for index, line in ipairs(lines) do
    if line:find(needle, 1, true) then return line, index end
  end
  return nil
end

local lines = TUI.thread_detail_lines(thread, detail_with({
  run_ns = 1224233114, wait_ns = 10950190, timeslices = 1182,
  wait_rate_ns = 4000000, timeslice_rate = 80, interval_ns = 1000000000,
  quality = "fresh", policy = 0,
}), process, translator)

assert(find(lines, "线程详情 · TID 701"), "the detail titles itself with the TID")
local policy_line = find(lines, "调度策略")
assert(policy_line and policy_line:match("SCHED_OTHER$"),
  "an ordinary thread reports SCHED_OTHER, got " .. tostring(policy_line))
local queued = find(lines, "队列等待")
assert(queued and queued:match("4 ms/s$"),
  "the queueing rate is shown per second, got " .. tostring(queued))
local slices = find(lines, "时间片")
assert(slices and slices:match("80%.0/s$"),
  "the timeslice rate is shown per second, got " .. tostring(slices))
-- CPU time now comes from schedstat's nanoseconds rather than from ticks
-- divided by an assumed 100 Hz, which would be wrong on any other kernel.
assert(find(lines, "CPU 时间"):match("1 s$")
  or find(lines, "CPU 时间"):match("1%.2"),
  "CPU time is taken from the exact run_ns, got " .. tostring(find(lines, "CPU 时间")))

-- A starved real-time thread and an idle one are told apart by their policy,
-- which is the whole reason the field is read.
local idle = TUI.thread_detail_lines(thread, detail_with({
  run_ns = 134532, wait_ns = 128098, timeslices = 3,
  wait_rate_ns = 128098, timeslice_rate = 0.2, interval_ns = 1000000000,
  quality = "fresh", policy = 5,
}), process, translator)
assert(find(idle, "调度策略"):match("SCHED_IDLE$"),
  "an idle-policy thread reports SCHED_IDLE, the reason it can be starved on purpose")
local idle_queued = find(idle, "队列等待")
assert(idle_queued and idle_queued:match("%d+ µs/s$"),
  "a nearly-idle thread's queueing is a microsecond figure, not a zero, got "
    .. tostring(idle_queued))

-- A policy the kernel added after this table was written is shown as the
-- number.  Naming it would be a guess, and a wrong policy name is worse than
-- an honest one.
local future = TUI.thread_detail_lines(thread, detail_with({
  run_ns = 1, wait_ns = 0, timeslices = 1, quality = "gap", policy = 42,
}), process, translator)
assert(find(future, "调度策略"):match("42$"),
  "an unknown policy is shown as its number, got " .. tostring(find(future, "调度策略")))

-- Before there is an interval there is no rate, and the overlay does not
-- print one.  A zero here would be indistinguishable from "never queued".
local first_reading = TUI.thread_detail_lines(thread, detail_with({
  run_ns = 732423114, wait_ns = 6950190, timeslices = 1102, quality = "gap", policy = 0,
}), process, translator)
assert(not find(first_reading, "队列等待"),
  "no queueing rate is drawn before an interval exists")
assert(not find(first_reading, "时间片"),
  "no timeslice rate is drawn before an interval exists")
assert(find(first_reading, "调度策略"),
  "the policy is known on the first reading and is still shown")

-- A kernel without schedstat shows the reason instead of an empty section.
-- The policy comes from a different file, so it survives: the two reads fail
-- independently and the view says which half is missing.
local no_schedstat = TUI.thread_detail_lines(thread, detail_with({
  status = "unavailable", policy = 0,
}), process, translator)
assert(not find(no_schedstat, "队列等待") and not find(no_schedstat, "时间片"),
  "an unavailable schedstat invents no rate")
assert(find(no_schedstat, "调度策略"):match("SCHED_OTHER$"),
  "the policy comes from a different file and survives a missing schedstat")
-- The CPU time still has an exact source even without schedstat: the stat
-- counters.  It is coarser, but it is a reading rather than a blank.
assert(find(no_schedstat, "CPU 时间"),
  "CPU time still falls back to the stat counters when schedstat is gone")

-- Both files gone leaves nothing to claim.
local nothing = TUI.thread_detail_lines(thread, detail_with({ status = "unavailable" }),
  process, translator)
assert(not find(nothing, "调度策略") and not find(nothing, "队列等待"),
  "an unreadable schedstat and sched invent nothing at all")

print("ok: per-thread scheduler (parsers, rates, TID recycling, overlay)")
return true
