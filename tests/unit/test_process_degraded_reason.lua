-- The process collector's reason column.
--
-- This is the only collector on the degraded-reason list whose quality
-- expression reaches a third word, and the reason is that a process table can
-- be entirely readable and still have nothing to measure.  So the pairing table
-- has three rows, not two, and the two reasons are not neighbours: one is about
-- data that could not be brought together, the other about a rate that does not
-- exist yet.
--
-- Instrumenting the four sample-level counters and the per-process partial flag
-- across the whole process suite gave 37 samples: 2 `fresh`, 11 `gap` -- all
-- from the same cause, no process with a fresh rate -- and 24 `partial`, of
-- which 23 were reached through `any_process_partial` and one through
-- `supplemental_parse_errors`.  The three counters `truncated`, `denied` and
-- `parse_errors` had never fired in any sample, and they are half of the
-- expression that selects this quality, so each is built here as a sample of
-- its own rather than assumed.
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local Process = require("wtop.collectors.process")

local REASON = { partial = "process_data_partial",
  gap = "process_rate_unavailable", fresh = false }
local reason_is = function(result, label)
  return require("support.collector_reason").assert_reason(result, REASON, label)
end

local function stat_line(pid, starttime, utime, stime)
  local fields = {
    1, pid, pid, 0, -1, 4194304, 10, 0, 2, 0,
    utime or 0, stime or 0, 0, 0, 20, 0, 1, 0,
    starttime, 10485760, 512,
  }
  local numbers = {}
  for index, value in ipairs(fields) do numbers[index] = tostring(value) end
  for index = #fields + 1, 44 do numbers[index] = "0" end
  return string.format("%d (%s) S %s", pid, "proc" .. pid, table.concat(numbers, " "))
end

-- `errors` lets a path be answered with a failure instead of a body, which is
-- how the denied case is built: a fixture that returns a table with a `kind`
-- is a refusal, not content.
local function fake_fs(files, dirs, errors)
  errors = errors or {}
  return {
    read = function(_, path, limit)
      local refusal = errors[path]
      if refusal then return nil, refusal end
      local value = files[path]
      if type(value) == "function" then value = value(path, limit) end
      if value == nil then
        return nil, { kind = "missing", message = "fixture_missing", path = path }
      end
      value = tostring(value)
      if limit and #value > limit then
        return nil, { kind = "too_large", message = "file_exceeds_limit", path = path }
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
local function context(fs) return { fs = fs, now_ns = function() return now end } end
local function scan(collector, files, dirs, errors, previous)
  return collector:sample(context(fake_fs(files, dirs, errors)), previous)
end

-- The four files the base scan reads beyond stat, present so a `partial` can
-- only come from the case under test.
local function whole(pid, starttime, utime)
  return {
    [string.format("/proc/%d/stat", pid)] = stat_line(pid, starttime, utime),
    [string.format("/proc/%d/cmdline", pid)] = "proc" .. pid .. "\0",
    [string.format("/proc/%d/status", pid)] =
      "Name:\tproc" .. pid .. "\nUid:\t1000\t1000\t1000\t1000\n",
  }
end

local collector = Process.new({})

-- `gap`: a first sample has nothing to difference against, so every row is
-- readable and every rate is missing.  Nothing failed and nothing was cut off --
-- the table is complete -- which is exactly why this is a reason of its own
-- rather than the partial one.
local gap_files = whole(10, 5)
local gap = scan(collector, gap_files, { ["/proc"] = { "10" } })
assert(gap.status == "ok" and gap.quality == "gap")
assert(#gap.data.list == 1 and gap.data.denied == 0 and gap.data.parse_errors == 0)
assert(gap.data.list[1].quality == "gap" and gap.data.list[1].cpu_percent == nil)
assert(not gap.data.partial and not gap.data.truncated,
  "a complete table with no rate is not a partial read")
reason_is(gap, "a process table with nothing to difference against")

-- `fresh`: the same table one second later, with the counters moved.  The
-- fresh row of a reason table is not optional bookkeeping -- it is the only row
-- that can contradict the other two, and a reason published here would tell a
-- user their process data is incomplete when it is not.
now = now + 1000000000
local fresh_files = whole(10, 5, 120)
local fresh = scan(collector, fresh_files, { ["/proc"] = { "10" } }, nil, gap)
assert(fresh.status == "ok" and fresh.quality == "fresh")
assert(#fresh.data.list == 1 and fresh.data.list[1].quality == "fresh")
assert(type(fresh.data.list[1].cpu_percent) == "number")
assert(not fresh.data.partial and not fresh.data.truncated and fresh.data.denied == 0)
assert(fresh.data.list[1].partial_reason == nil,
  "a row with a rate is not a row with a failed field")
reason_is(fresh, "a process table with a rate")

-- `partial`, first of four causes: a process whose `status` could not be read.
-- Every other field of that row is fine, which is the shape of the whole
-- `any_process_partial` family -- ten sites, all of them a read that failed or
-- produced something unparseable.
local statusless = whole(20, 7)
statusless["/proc/20/status"] = nil
local status_partial = scan(collector, statusless, { ["/proc"] = { "20" } })
assert(status_partial.status == "ok" and status_partial.quality == "partial")
assert(status_partial.data.partial)
assert(status_partial.data.list[1].partial_reason ~= nil,
  "the row itself carries which field failed: "
    .. tostring(status_partial.data.list[1].partial_reason))
reason_is(status_partial, "a process table whose status file could not be read")

-- `partial`, second: the enumeration stopped at its cap.  Nothing failed to be
-- read here either -- this is a limit wtop chose -- so the verb in the reason
-- is *collected*, and the sample asserts there is no error to point at.
local capped = scan(Process.new({ max_processes = 1 }), {
  ["/proc/10/stat"] = stat_line(10, 5), ["/proc/20/stat"] = stat_line(20, 7),
  ["/proc/10/status"] = "Name:\tproc10\nUid:\t0\t0\t0\t0\n",
  ["/proc/20/status"] = "Name:\tproc20\nUid:\t0\t0\t0\t0\n",
}, { ["/proc"] = { "10", "20" } })
assert(capped.status == "ok" and capped.quality == "partial")
assert(capped.data.truncated and capped.data.partial)
assert(#capped.data.list == 1, "the cap is what limits the table")
assert(capped.data.denied == 0 and capped.data.parse_errors == 0,
  "a cap is not a failed read")
reason_is(capped, "a process table stopped at its cap")

-- `partial`, third: a `/proc/<pid>/stat` the kernel refused.  This counter had
-- never fired in any sample in the suite, and it is the one cause of this
-- quality that a user can act on directly.
local denied = scan(collector, { ["/proc/10/status"] = "Name:\tproc10\nUid:\t0\t0\t0\t0\n" },
  { ["/proc"] = { "10" } },
  { ["/proc/10/stat"] = { kind = "denied", message = "permission denied",
    path = "/proc/10/stat" } })
assert(denied.status == "ok" and denied.quality == "partial")
assert(denied.data.denied == 1 and denied.data.partial)
assert(denied.data.parse_errors == 0 and not denied.data.truncated)
assert(#denied.data.list == 0, "a row whose stat was refused is not shown at all")
reason_is(denied, "a process table whose stat read was denied")

-- `partial`, fourth: a `stat` that was read and could not be parsed.  Also never
-- fired.  The bytes arrived; what could not be produced is a row.
local malformed = scan(collector, {
  ["/proc/10/stat"] = "this is not a stat line",
  ["/proc/10/status"] = "Name:\tproc10\nUid:\t0\t0\t0\t0\n",
}, { ["/proc"] = { "10" } })
assert(malformed.status == "ok" and malformed.quality == "partial")
assert(malformed.data.parse_errors == 1 and malformed.data.partial)
assert(malformed.data.denied == 0 and not malformed.data.truncated)
assert(#malformed.data.list == 0)
reason_is(malformed, "a process table with an unparseable stat line")

-- `gap`, the other cause: the baseline exists but the counter went backwards,
-- so there is still no interval to difference.  A first sample and a reset look
-- identical from the outside -- no rate -- and the reason has to cover both,
-- because a user who was told only about "no second sample yet" would be sent
-- away waiting for something that has already happened twice.
local reset_first = scan(collector, { ["/proc/30/stat"] = stat_line(30, 9, 500),
  ["/proc/30/status"] = "Name:\tproc30\nUid:\t0\t0\t0\t0\n" }, { ["/proc"] = { "30" } })
assert(reset_first.quality == "gap")
now = now + 1000000000
local reset_second = scan(collector, { ["/proc/30/stat"] = stat_line(30, 9, 10),
  ["/proc/30/status"] = "Name:\tproc30\nUid:\t0\t0\t0\t0\n" }, { ["/proc"] = { "30" } },
  nil, reset_first)
assert(reset_second.quality == "gap",
  "a counter that went backwards leaves no rate to publish")
assert(reset_second.data.list[1].quality == "gap"
  and reset_second.data.list[1].cpu_percent == nil)
assert(not reset_second.data.partial and not reset_second.data.truncated,
  "a reset is not a failed read and not a cap")
assert(reset_second.data.denied == 0 and reset_second.data.parse_errors == 0)
reason_is(reset_second, "a process table whose CPU counter went backwards")

return true
