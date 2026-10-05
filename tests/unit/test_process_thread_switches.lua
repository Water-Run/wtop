-- Per-thread context-switch rates, and the per-thread memory question that has
-- no answer.
--
-- The switch counters arrive in the same status file the thread is already read
-- for its thread group, so the rates cost no additional `/proc` read.  What
-- they add is the one per-thread signal that separates a thread the kernel
-- keeps preempting from one that blocks on something itself: the two look
-- identical in the cumulative totals, and they want opposite fixes.
--
-- The memory half is a refusal, and the refusal is the point.  Threads share an
-- address space.  `/proc/<pid>/task/<tid>/smaps` is a real, separate file --
-- a different inode, so a second full walk of a large mapping table -- whose
-- content is byte-for-byte the process's own smaps.  Reading it would print the
-- process's numbers under a thread's name.  So it is not read, and the process's
-- own figures are shown instead, labelled as the process's.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Process = require("wtop.collectors.process")
local Parsers = require("wtop.linux.parsers")
local I18n = require("wtop.i18n")
local TUI = require("wtop.tui")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

local function near(actual, expected, tolerance, label)
  assert(type(actual) == "number", (label or "value") .. ": expected a number, got "
    .. tostring(actual))
  assert(math.abs(actual - expected) <= (tolerance or 0.001),
    string.format("%s: expected ~%s, got %s", label or "value", expected, actual))
end

-- 1. The smaps claim, checked rather than assumed.  The whole decision to not
-- read it rests on this, so it is verified against the parser too: the two
-- files are the same address space, not two views of one thread's.
local status_sample = table.concat({
  "Name:\tworker",
  "State:\tR (running)",
  "Tgid:\t700",
  "Uid:\t1000\t1000\t1000\t1000",
  "voluntary_ctxt_switches:\t55",
  "nonvoluntary_ctxt_switches:\t6",
}, "\n") .. "\n"
local parsed = assert(Parsers.process_status(status_sample))
equal(parsed.voluntary_context_switches, 55, "voluntary switches parse")
equal(parsed.nonvoluntary_context_switches, 6, "involuntary switches parse")
-- 55 + 6 is the total sched reports as nr_switches; the split is the part
-- that says anything.
equal(parsed.voluntary_context_switches + parsed.nonvoluntary_context_switches, 61,
  "the two halves are the total")

-- 2. The memory figures this overlay will show are the *process's*, read once
-- from its rollup.  A real smaps_rollup: the synthetic mapping header first,
-- then "Key: n kB".  Whether the parser converts kB to bytes and whether the
-- collector derives USS from the private share are covered by the core parser
-- and process memory tests; what is new here is the read side, checked below
-- against the paths the collector actually opens.
local rollup = table.concat({
  "55a4b0d0-7ffd636da000 ---p 00000000 00:00 0                          [rollup]",
  "Rss:                72 kB",
  "Pss:                48 kB",
  "Pss_Anon:           40 kB",
  "Pss_File:            8 kB",
  "Shared_Clean:       24 kB",
  "Shared_Dirty:        0 kB",
  "Private_Clean:       8 kB",
  "Private_Dirty:      16 kB",
  "Swap:                0 kB",
}, "\n") .. "\n"

-- 3. The rates.  Two readings one second apart, with the switch counters
-- moving at a known rate: 100 voluntary and 40 involuntary in the interval, so
-- 140 switches a second and a quarter of them taken by the kernel.
local files = {}
local directories = {}
-- Every path the collector opens, in order.  The memory decision below is a
-- claim about which files are *not* read, and a claim about a read that never
-- happens can only be checked by recording the reads that do.
local reads = {}
-- One clock for the whole test, shared by the context's now_ns below.  It is
-- declared out here rather than passed into build() precisely because a
-- parameter would be captured by value: the context would keep reporting the
-- instant it was built with, every interval would be zero, and no rate would
-- ever exist to assert on.
local now = 1000000000
local function build()
  local collector = Process.new({
    proc_path = "/proc",
    max_detail_threads = 4,
    read_status = true,
  })
  local function read(path)
    reads[#reads + 1] = path
    local value = files[path]
    if value == nil then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    return tostring(value)
  end
  local fs = {}
  function fs:read(path, limit) return read(path) end
  function fs:read_number(path) return nil end
  function fs:list(path, limit)
    local value = directories[path]
    if not value then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    local out = {}
    for index, item in ipairs(value) do out[index] = item end
    return out, nil, false
  end
  function fs:readlink(path)
    return nil, { kind = "missing", message = "fixture_missing", path = path }
  end
  return collector, {
    fs = fs,
    now_ns = function() return now end,
    -- Sets keyed by the composite process id, not by pid: a starttime is part
    -- of the identity, and the collector asks "is this exact process selected",
    -- so a list or a bare pid would select nothing and the detail pass would
    -- never run.  The thread selection is keyed by pid, because a TID is only
    -- meaningful together with the process that owns it.
    selected_process_ids = { ["700:7"] = true },
    selected_thread_ids = { [700] = 700 },
    visible_process_ids = { ["700:7"] = true },
  }
end

-- The process scan needs enough of a row to reach the thread pass.
local function proc_stat(pid, comm, starttime)
  return string.format(
    "%d (%s) S 1 %d %d 0 -1 4194304 10 0 2 0 100 50 0 0 20 0 2 0 %d 10485760 512 0 0 0 0 0 0 0 0 0 0 0 0 3 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n",
    pid, comm, pid, pid, starttime)
end

local function status_with(voluntary, involuntary)
  return table.concat({
    "Name:\tworker",
    "State:\tR (running)",
    "Tgid:\t700",
    "Uid:\t1000\t1000\t1000\t1000",
    "voluntary_ctxt_switches:\t" .. voluntary,
    "nonvoluntary_ctxt_switches:\t" .. involuntary,
  }, "\n") .. "\n"
end

files["/proc/700/stat"] = proc_stat(700, "worker", 7)
directories["/proc"] = { "self", "700" }
directories["/proc/700/task"] = { "700" }
-- The thread row is built from the task's own stat; without it the task is
-- treated as a race and no detail is read for it.
files["/proc/700/task/700/stat"] = proc_stat(700, "worker", 7)
files["/proc/700/task/700/schedstat"] = "1000000000 0 500\n"
files["/proc/700/task/700/sched"] = "policy : 0\nprio : 120\n"
files["/proc/700/task/700/io"] = "rchar: 0\nwchar: 0\n"
files["/proc/700/task/700/cgroup"] = "0::/user.slice\n"
files["/proc/700/smaps_rollup"] = rollup

local collector, context = build()
files["/proc/700/task/700/status"] = status_with(55, 6)
local first = collector:sample(context)
local opening = first.data.by_id["700:7"]
assert(opening, "the process was not scanned")
local first_scheduler = assert(opening.thread_details
  and opening.thread_details[700] and opening.thread_details[700].scheduler,
  "the thread detail was not read")

-- The refusal, checked on the reads themselves.  `/proc/<pid>/task/<tid>/smaps`
-- is a real file on this host -- a second inode -- whose content is
-- byte-for-byte the process's own smaps, because a thread has no address space
-- of its own.  Reading it would walk a large mapping table a second time to
-- print numbers that already say what they are, under a name that makes them
-- mean something else.  So no path under a thread is ever opened for it, and
-- the process's own rollup is read exactly once instead.
for _, path in ipairs(reads) do
  assert(not path:match("/task/.*/smaps"),
    "a per-thread smaps was read, which is the process's own smaps:\n" .. path)
end
local rollup_reads = 0
for _, path in ipairs(reads) do
  if path == "/proc/700/smaps_rollup" then rollup_reads = rollup_reads + 1 end
end
equal(rollup_reads, 1, "the process's rollup is read once, not once per thread")
local memory = assert(opening.memory_detail,
  "the process's own memory figures were not collected")
equal(memory.pss, 48 * 1024, "PSS comes from the rollup, in bytes")
equal(memory.uss, 24 * 1024, "USS is the private total, in bytes")
-- The thread's detail carries no memory of its own, which is the point: there
-- is no per-thread figure to carry.
equal(opening.thread_details[700].memory_detail, nil,
  "the thread detail invents a memory figure of its own")
-- A first reading has no interval, so it has no rate -- for the switches just
-- as for the wait time.  A rate divided by nothing would be a fiction.
equal(first_scheduler.quality, "gap", "a first reading has no rate")
equal(first_scheduler.switch_rate, nil, "and no switch rate either")
equal(first_scheduler.preempted_fraction, nil,
  "a fraction of no interval is not zero, it is an absence")

-- The second reading a second later: 100 voluntary and 40 involuntary more.
files["/proc/700/task/700/schedstat"] = "1500000000 0 550\n"
files["/proc/700/task/700/status"] = status_with(155, 46)
now = now + 1000000000
local second = collector:sample(context, first)
local rated = assert(second.data.by_id["700:7"].thread_details[700].scheduler)
equal(rated.quality, "fresh", "a second reading is differenced")
equal(rated.interval_ns, 1000000000, "the interval is the one that elapsed")
near(rated.switch_rate, 140, 0.001, "switches per second")
near(rated.voluntary_switch_rate, 100, 0.001, "voluntary per second")
near(rated.involuntary_switch_rate, 40, 0.001, "involuntary per second")
near(rated.preempted_fraction, 40 / 140, 0.0001, "the preempted share")
-- The wait and switch families share one interval, so they cannot end up
-- describing different spans of time.
near(rated.wait_rate_ns, 0, 0.001, "the wait rate shares the interval")

-- 4. A thread that did not switch at all has no share to report.  A fraction
-- of zero switches is an absence of evidence, and printing 0% would be the
-- same claim as "nothing preempted it", which is not what was measured.
files["/proc/700/task/700/status"] = status_with(155, 46)
now = now + 1000000000
local third = collector:sample(context, second)
local still = third.data.by_id["700:7"].thread_details[700].scheduler
equal(still.quality, "fresh", "an idle thread is still a valid reading")
equal(still.switch_rate, 0, "and it switched not at all")
equal(still.preempted_fraction, nil,
  "so no preempted share is drawn: zero switches is not zero preemption")

-- 5. A thread that switched not at all in the interval is the same case, and
-- the counters going *backwards* is a thread that exited and whose TID was
-- reused.  Neither may be differenced into a rate.
files["/proc/700/task/700/status"] = status_with(2, 1)
now = now + 1000000000
local recycled = collector:sample(context, third)
local reset = recycled.data.by_id["700:7"].thread_details[700].scheduler
equal(reset.switch_rate, nil, "counters that moved backwards yield no rate")
equal(reset.preempted_fraction, nil, "and no preempted share")

-- 6. The overlay shows the rates, and only when there is an interval to show
-- them over.  A cumulative total under a label that says "per second" is the
-- exact mistake this whole change exists to avoid.
local translator = assert(I18n.new({ locale = "en-US" }))
local function detail_of(scheduler, process)
  return table.concat(TUI.thread_detail_lines({ tid = 700, name = "worker",
    cpu_percent = 12.5, priority = 120, nice = 0, state = "R" },
    { tgid = 700, state_text = "R (running)", scheduler = scheduler },
    process, translator), "\n")
end
local shown = detail_of(rated)
assert(shown:find("Switches", 1, true), "the overlay shows no switch rate:\n" .. shown)
assert(shown:find("140", 1, true), "the switch rate is not drawn:\n" .. shown)
assert(shown:find("Preempted share", 1, true),
  "the overlay shows no preempted share:\n" .. shown)
assert(shown:lower():find("28.6", 1, true),
  "the preempted share is not drawn as a percentage:\n" .. shown)
local gap = detail_of(first_scheduler)
assert(gap:find("Switches", 1, true) == nil,
  "a first reading drew a switch rate out of nothing:\n" .. gap)
-- A thread with no interval has no preempted share either, even though the
-- label would fit on the line.
local idle = detail_of(still)
assert(idle:find("Preempted share", 1, true) == nil,
  "a thread that never switched drew a preempted share:\n" .. idle)
assert(idle:find("Switches", 1, true) and idle:find("0.0", 1, true),
  "but its zero switch rate is a real measurement and is drawn:\n" .. idle)

-- 7. The memory section says whose memory it is, and says so in the heading
-- rather than in a footnote.  A reader who sees a byte count under a thread's
-- name will believe it is the thread's.
local with_memory = detail_of(rated, {
  name = "worker", memory_detail = { pss = 48 * 1024 * 1024, uss = 16 * 1024 * 1024 },
})
assert(with_memory:find("not the thread", 1, true),
  "the memory section does not say the memory is the process's:\n" .. with_memory)
assert(with_memory:find("PSS", 1, true) and with_memory:find("USS", 1, true),
  "the process's own figures are not shown:\n" .. with_memory)
local without_memory = detail_of(rated, { name = "worker" })
assert(without_memory:find("Memory (", 1, true) == nil,
  "a section appeared with nothing in it:\n" .. without_memory)

print("ok: per-thread switch rates and the per-thread memory question")
