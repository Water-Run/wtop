local Capability = require("wtop.core.capability")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")
local native = require("wtop.native")

local Process = {}
Process.__index = Process

-- Revalidation still parses the complete stat record. Reuse the native
-- parser when available, and keep Lua's handling of unusual or invalid input.
local function process_stat(provider, content)
  if type(content) == "string" and provider.available == true
      and type(provider.process_stat_fields) == "function" then
    local parsed = provider.process_stat_fields(content)
    if parsed then return parsed end
  end
  return Parsers.process_stat(content)
end

-- Native decoding handles validated metadata. Unsupported inputs retain the
-- reducer and full Lua parser's errors and partial-field interpretation.
local function process_metadata(provider, content)
  if type(content) == "string" and provider.available == true
      and type(provider.process_status_metadata_fields) == "function" then
    local parsed = provider.process_status_metadata_fields(content)
    if type(parsed) == "table" then return parsed end
  end
  if type(content) == "string" and provider.available == true
      and type(provider.process_status_metadata_input) == "function" then
    local reduced = provider.process_status_metadata_input(content)
    if type(reduced) == "string" then content = reduced end
  end
  return Parsers.process_status(content)
end

local STATUS_REFRESH_NS = 5 * 1000000000
local function next_status_refresh(now, pid, starttime)
  -- Stable identity phases distribute refreshes across a five-second period.
  local phase = ((pid * 1103515245 + starttime % 5000) % 5000) * 1000000
  local delta = (phase - now % STATUS_REFRESH_NS) % STATUS_REFRESH_NS
  return now + (delta == 0 and STATUS_REFRESH_NS or delta)
end

local DEFAULT_MAX_PROCESSES = 8192
local HARD_MAX_PROCESSES = 65536
local DIRECTORY_ENTRY_SLACK = 256
local DEFAULT_MAX_DETAIL_THREADS = 1024
local HARD_MAX_DETAIL_THREADS = 4096
local MAX_DETAIL_FDS = 4096
local MAX_BULK_IO_READS = 8192
local MAX_SCHEDULER_HISTORY = 4096
local BULK_IO_REFRESH_NS = 5 * 1000000000
local BULK_IO_RATE_REFRESH_NS = 2 * 1000000000
local NUMA_MAPS_MAX_BYTES = 2 * 1024 * 1024
local NUMA_REFRESH_NS = 10 * 1000000000
-- Linux get_task_mm() excludes PF_KTHREAD even when a kernel worker borrows
-- an address space; procfs cmdline therefore returns EOF for these tasks.
-- include/linux/sched.h and kernel/fork.c define this flag/relationship.
local PF_KTHREAD = 0x00200000

local function kernel_thread(stat)
  return math.type(stat.flags) == "integer" and stat.flags >= 0
    and (stat.flags & PF_KTHREAD) ~= 0
end

-- wchan is a symbolic kernel location, not a diagnosis or a duration. The
-- kernel prints 0 when it has no sleeping location to report. Keep this read
-- confined to an open detail and verify the task generation after it.
local function wait_site(fs, path)
  local content, err = fs:read(path .. "/wchan", 256)
  if not content then return nil, FS.error_status(err) end
  if #content > 256 then return nil, "parse_error" end
  local symbol = Common.trim(content)
  if symbol == "0" then return nil, "not_reported" end
  if not symbol or not symbol:match("^[!-~]+$") then
    return nil, "parse_error"
  end
  return symbol, "ok"
end

local function descriptor_detail(fs, path, now)
  local entries, failure, truncated = fs:list(path, MAX_DETAIL_FDS)
  return {
    count = entries and #entries or nil,
    status = entries and (truncated and "truncated" or "ok")
      or FS.error_status(failure),
    observed_ns = now,
  }
end

local function oom_counter(fs, path, minimum, maximum)
  local content, err = fs:read(path, 64)
  if not content then return nil, FS.error_status(err) end
  local token = Common.trim(content)
  if not token or not token:match("^%-?%d+$") then return nil, "error" end
  local value = tonumber(token)
  if not value or math.type(value) ~= "integer"
      or value < minimum or value > maximum then return nil, "error" end
  return value, "ok"
end

local function process_io_rate(current, previous, previous_ns, now)
  local result = { quality = "gap", observed_ns = now }
  if type(current) ~= "table" or type(current.read_bytes) ~= "number"
      or type(current.write_bytes) ~= "number" then
    result.reason = "missing_counter"
    return result
  end
  if type(previous) ~= "table" or type(previous_ns) ~= "number" then
    result.reason = "first_sample"
    return result
  end
  local interval = Common.elapsed_ns(now, previous_ns)
  if not interval or interval <= 0 then
    result.reason = "invalid_interval"
    return result
  end
  result.interval_ns = interval
  local read, read_error = Common.rate(current.read_bytes, previous.read_bytes, interval)
  local write, write_error = Common.rate(current.write_bytes, previous.write_bytes, interval)
  if read == nil or write == nil then
    if read_error == "reset" or write_error == "reset" then
      result.quality = "reset"
      result.reason = "counter_reset"
    else
      result.reason = read_error or write_error
    end
    return result
  end
  result.quality = "fresh"
  result.read_bytes_per_second = read
  result.write_bytes_per_second = write
  return result
end

local function bounded_process_limit(value)
  if value == nil then return DEFAULT_MAX_PROCESSES end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
      or value % 1 ~= 0 or value < 1 or value > HARD_MAX_PROCESSES then
    error("max_processes must be an integer in 1.." .. HARD_MAX_PROCESSES, 3)
  end
  return value
end

local function bounded_detail_thread_limit(value)
  if value == nil then return DEFAULT_MAX_DETAIL_THREADS end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
      or value % 1 ~= 0 or value < 1 or value > HARD_MAX_DETAIL_THREADS then
    error("max_detail_threads must be an integer in 1.." .. HARD_MAX_DETAIL_THREADS, 3)
  end
  return value
end

local function bounded_bulk_io_limit(value)
  if value == nil then return MAX_BULK_IO_READS end
  if type(value) ~= "number" or value ~= value or value == math.huge
      or value == -math.huge or value % 1 ~= 0 or value < 1
      or value > MAX_BULK_IO_READS then
    error("max_bulk_io_reads must be an integer in 1.." .. MAX_BULK_IO_READS, 3)
  end
  return value
end

local function canonical_pid(entry)
  if type(entry) ~= "string" or not entry:match("^[1-9]%d*$") then return nil end
  local pid = tonumber(entry)
  if not pid or math.type(pid) ~= "integer" or pid > 2147483647
      or tostring(pid) ~= entry then return nil end
  return pid
end

local function sanitize_text(value)
  if type(value) ~= "string" then
    return nil
  end
  value = value:gsub("%z+", " ")
  value = value:gsub("[%c]", function(character)
    if character == "\t" then
      return " "
    end
    return "?"
  end)
  if not utf8.len(value) then
    local output = {}
    local index = 1
    while index <= #value do
      local byte = value:byte(index)
      local length
      if byte < 0x80 then
        length = 1
      elseif byte >= 0xc2 and byte <= 0xdf then
        length = 2
      elseif byte >= 0xe0 and byte <= 0xef then
        length = 3
      elseif byte >= 0xf0 and byte <= 0xf4 then
        length = 4
      end
      local candidate = length and value:sub(index, index + length - 1) or nil
      local valid = candidate and #candidate == length and utf8.len(candidate) == 1
      if valid then
        output[#output + 1] = candidate
        index = index + length
      else
        output[#output + 1] = "�"
        index = index + 1
      end
    end
    value = table.concat(output)
  end
  return Common.trim(value)
end

function Process.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Process options must be a table", 2) end
  local constants = options.system_constants
  if not constants and type(native.system_constants) == "function" then
    local called, value = pcall(native.system_constants)
    if called then constants = value end
  end
  constants = type(constants) == "table" and constants or {}
  local clock_ticks_per_second = options.clock_ticks_per_second
    or constants.clock_ticks_per_second or 100
  local page_size_bytes = options.page_size_bytes or constants.page_size_bytes or 4096
  if type(clock_ticks_per_second) ~= "number" or clock_ticks_per_second ~= clock_ticks_per_second
      or clock_ticks_per_second <= 0 or clock_ticks_per_second == math.huge then
    error("clock_ticks_per_second must be a finite positive number", 2)
  end
  if type(page_size_bytes) ~= "number" or page_size_bytes ~= page_size_bytes
      or page_size_bytes <= 0 or page_size_bytes == math.huge or page_size_bytes % 1 ~= 0 then
    error("page_size_bytes must be a finite positive integer", 2)
  end
  for _, key in ipairs({ "read_status", "read_cmdline", "read_io", "read_cgroup" }) do
    if options[key] ~= nil and type(options[key]) ~= "boolean" then
      error(key .. " must be a boolean", 2)
    end
  end
  local native = options.native and options.native or native
  return setmetatable({
    id = "process",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    fs = options.fs or FS.default,
    native = native,
    -- The batch reader talks to the real /proc only; a redirected proc_path
    -- (fixtures, chroot-like tests) must keep the per-file reader.
    use_native_batch = Common.absolute_path("proc_path", options.proc_path, "/proc") == "/proc"
      and native.available == true and type(native.proc_batch) == "function",
    use_native_parsed_stat = type(native.process_stat_fields) == "function",
    proc_path = Common.absolute_path("proc_path", options.proc_path, "/proc"),
    clock_ticks_per_second = clock_ticks_per_second,
    uptime_path = Common.absolute_path("uptime_path", options.uptime_path, "/proc/uptime"),
    page_size_bytes = page_size_bytes,
    read_status = options.read_status ~= false,
    read_cmdline = options.read_cmdline == true,
    read_io = options.read_io == true,
    read_cgroup = options.read_cgroup == true,
    max_processes = bounded_process_limit(options.max_processes),
    max_detail_threads = bounded_detail_thread_limit(options.max_detail_threads),
    max_bulk_io_reads = bounded_bulk_io_limit(options.max_bulk_io_reads),
    _method_style = true,
    -- Identity fields survive between samples. An explicitly requested I/O
    -- sort/filter also keeps its last counter reading for five seconds.
    identity_cache = {},
    io_bulk_last_ns = nil,
    -- The previous schedstat reading of everything this collector has been
    -- asked to measure: the processes whose rows the operator can see, and the
    -- individual threads they opened.  Keyed by an identity string that carries
    -- the pid and tid, so a recycled id can never inherit a previous task's
    -- counters. Retain at most MAX_SCHEDULER_HISTORY recently observed tasks;
    -- navigating through many identities cannot grow this history forever.
    sched_memo = {},
    sched_memo_size = 0,
  }, Process)
end

function Process:probe(context)
  local fs = Common.fs(context, self.fs)
  local entries, err = fs:list(self.proc_path, 1)
  if entries then
    return Capability.available({ source = self.proc_path })
  end
  local status = FS.error_status(err)
  if status == "denied" then
    return Capability.denied(err.message, { source = self.proc_path })
  end
  return Capability.unavailable(err and err.message or "proc_enumeration_unavailable", { source = self.proc_path })
end

-- One thread, a handful of small files.  A thread is a schedulable task rather
-- than a process, so what the kernel publishes per thread is not a copy of the
-- process's own numbers: its context switches, its I/O, its cgroup membership
-- and how long it spent queued for a cpu are all tracked per task and each can
-- differ from the process the thread belongs to.  The reads happen for the
-- selected TID only -- a process with a thousand threads must not cost a
-- thousand extra files.
function Process:_thread_detail(fs, context, base, task_entry, tid, starttime_ticks, now,
    leader_fd_detail)
  local task_base = base .. "/task/" .. task_entry
  local result = { tid = tid, starttime_ticks = starttime_ticks }
  local source = task_base

  -- Threads usually share an FD table, but CLONE_FILES can be undone for one
  -- thread. Read the selected task's own directory. The leader's selected
  -- process read is the same table and can be reused without another walk.
  result.fd_detail = leader_fd_detail or descriptor_detail(fs, task_base .. "/fd", now)

  local status_content, status_error = fs:read(task_base .. "/status", 256 * 1024)
  -- The switch counters come out of this same file, and they are the only
  -- per-thread reading that says whether the kernel took the cpu away from
  -- this thread or the thread gave it up itself.  They are kept aside rather
  -- than differenced here so the one interval below covers every rate.
  local switches
  if status_content then
    local status = Parsers.process_status(status_content)
    if status then
      -- The stat row carries the single-letter state; the status line spells
      -- it out ("S (sleeping)"), which is the difference between a code an
      -- operator has to look up and a word they can read.
      result.state_text = status.raw.State
      result.tgid = status.tgid
      result.uid = status.uid
      result.nspid = status.nspid
      result.affinity = status.affinity
      if result.affinity then result.affinity.observed_ns = now end
      result.voluntary_switches = status.voluntary_context_switches
      result.involuntary_switches = status.nonvoluntary_context_switches
      if type(status.voluntary_context_switches) == "number"
          and type(status.nonvoluntary_context_switches) == "number" then
        switches = {
          voluntary = status.voluntary_context_switches,
          involuntary = status.nonvoluntary_context_switches,
        }
      end
    else
      result.status_reason = "parse_error"
    end
  elseif status_error then
    result.status_error = FS.error_status(status_error)
  end

  -- io and cgroup are read unconditionally here, unlike the per-process pass
  -- that gates them behind collector options: this method only runs for a
  -- thread the operator explicitly opened, and leaving a column blank because
  -- a bulk-scan option is off would be a worse answer than the read it avoids.
  local io_content, io_error = fs:read(task_base .. "/io", 65536)
  if io_content then
    local parsed_io = Parsers.process_io(io_content)
    if parsed_io then
      result.io = parsed_io
    else
      result.io_error = "parse_error"
    end
  elseif io_error then
    result.io_error = FS.error_status(io_error)
  end

  local cgroup_content, cgroup_error = fs:read(task_base .. "/cgroup", 65536)
  if cgroup_content then
    local parsed_cgroups = Parsers.cgroup(cgroup_content)
    if parsed_cgroups then
      result.cgroups = parsed_cgroups
    else
      result.cgroup_error = "parse_error"
    end
  elseif cgroup_error then
    result.cgroup_error = FS.error_status(cgroup_error)
  end

  -- How long this thread spent queued for a cpu is the one number that
  -- separates "this thread is slow" from "this thread is starved", and no
  -- other file reports it.  schedstat carries it in three fixed-width numbers;
  -- sched carries the policy, and only the policy, because its field set
  -- changes with the kernel and everything else in it is either already known
  -- or not worth a guess.  The status file already read above contributes the
  -- switch counters, so no additional file is opened for the rates.
  local identity = "tid " .. base .. "/" .. tid
  local schedstat_content, schedstat_error = fs:read(task_base .. "/schedstat", 4096)
  local parsed_schedstat, schedstat_status
  if schedstat_content then
    parsed_schedstat = Parsers.thread_schedstat(schedstat_content)
    if not parsed_schedstat then schedstat_status = "parse_error" end
  elseif schedstat_error then
    -- A kernel without CONFIG_SCHEDSTATS does not create the file.  That is
    -- the kernel declining to publish the figure, not a reading of zero, and
    -- the two must not look alike.
    schedstat_status = FS.error_status(schedstat_error)
  end

  local sched_content, sched_error = fs:read(task_base .. "/sched", 64 * 1024)
  local parsed_sched
  if sched_content then
    parsed_sched = Parsers.thread_sched(sched_content)
  end

  result.wait_site, result.wait_site_status = wait_site(fs, task_base)

  -- A TID can exit and be recycled while its optional files are being read.
  -- The first stat read admitted the row; only a second one can confirm that
  -- the supplemental values still belong to that same task generation.
  local final_content = fs:read(task_base .. "/stat", 65536)
  local final_task = final_content and Parsers.process_stat(final_content)
  if not final_task or final_task.pid ~= tid
      or final_task.starttime_ticks ~= starttime_ticks then
    return nil
  end

  -- One rate call for the whole thread, after every file has been read: the
  -- interval has to be shared by the wait, timeslice and switch families, and
  -- it has to be established even on a kernel that publishes no schedstat at
  -- all, where the switch counters are then the only rate there is.
  local scheduler = self:_sched_rate(identity, parsed_schedstat, starttime_ticks, now,
    switches)
  if schedstat_status then
    -- The schedstat status is a statement about that file alone.  A kernel
    -- without CONFIG_SCHEDSTATS still has switch counters, so the family is
    -- reported as partially read rather than lost.
    scheduler.schedstat_status = schedstat_status
  end
  if parsed_sched then
    if parsed_sched.policy ~= nil then
      scheduler.policy = parsed_sched.policy
    else
      -- The key is absent on kernels that do not print it; that is not the
      -- same as a policy of zero.
      scheduler.policy_status = "unavailable"
    end
  elseif sched_error then
    scheduler.policy_status = FS.error_status(sched_error)
  elseif sched_content then
    scheduler.policy_status = "parse_error"
  end
  result.scheduler = scheduler

  result.source = source
  return result
end

-- Cumulative scheduler counters say nothing about right now: a thread that
-- waited 7 ms in its first hour and none in the last minute is not currently
-- starved.  The rate is therefore differenced against this thread's own
-- previous reading, matched on (pid, tid, starttime) so a recycled TID never
-- inherits a previous thread's counters.
--
-- The previous reading is kept on the collector rather than in the sample
-- because schedstat is read for the selected thread only.  Moving the cursor
-- away and back resumes from its last cached reading. The rate covers that
-- whole interval, rather than rescaling to one tick. Once old history has
-- been evicted, the next reading starts a new interval with gap quality.
--
-- The context-switch counters travel in the same slot even though they come
-- from a different file, for two reasons.  They are the only per-thread signal
-- that separates a thread the kernel keeps preempting from one that blocks on
-- something itself, and they cost nothing extra: the status file this thread is
-- already read for its thread group carries them.  One slot and one interval
-- also means the two families cannot end up describing different spans.
local function remember_scheduler(self, identity, reading)
  local memo = self.sched_memo
  local previous = memo[identity]
  if previous then
    -- Remove this identity from its old recency position before putting the
    -- new reading at the head. Links belong only to private baseline records.
    if previous.newer then memo[previous.newer].older = previous.older
    else self.sched_newest = previous.older end
    if previous.older then memo[previous.older].newer = previous.newer
    else self.sched_oldest = previous.newer end
  elseif self.sched_memo_size == MAX_SCHEDULER_HISTORY then
    local oldest = self.sched_oldest
    self.sched_oldest = memo[oldest].newer
    memo[self.sched_oldest].older = nil
    memo[oldest] = nil
  else
    self.sched_memo_size = self.sched_memo_size + 1
  end
  reading.older = self.sched_newest
  if self.sched_newest then memo[self.sched_newest].newer = identity
  else self.sched_oldest = identity end
  self.sched_newest = identity
  memo[identity] = reading
end

function Process:_sched_rate(identity, parsed, starttime_ticks, now, switches)
  local key = self.sched_memo
  local result = {}
  if parsed then
    result.run_ns = parsed.run_ns
    result.wait_ns = parsed.wait_ns
    result.timeslices = parsed.timeslices
  end
  local slot = key[identity]
  local previous = (slot and slot.starttime_ticks == starttime_ticks) and slot or nil
  local elapsed_ns = previous and now and Common.elapsed_ns(now, previous.at_ns) or nil
  local fresh = false
  if elapsed_ns and elapsed_ns > 0 then
    local seconds = elapsed_ns / 1000000000
    if parsed then
      local run_delta = Common.delta(parsed.run_ns, previous.run_ns)
      local wait_delta = Common.delta(parsed.wait_ns, previous.wait_ns)
      local slice_delta = Common.delta(parsed.timeslices, previous.timeslices)
      if run_delta and wait_delta and slice_delta then
        result.wait_rate_ns = (wait_delta + 0.0) / seconds
        result.timeslice_rate = (slice_delta + 0.0) / seconds
        fresh = true
      end
    end
    if switches and previous.switches then
      local voluntary = Common.delta(switches.voluntary, previous.switches.voluntary)
      local involuntary = Common.delta(switches.involuntary, previous.switches.involuntary)
      if voluntary and involuntary then
        result.voluntary_switch_rate = voluntary / seconds
        result.involuntary_switch_rate = involuntary / seconds
        result.switch_rate = (voluntary + involuntary) / seconds
        local total = voluntary + involuntary
        -- The share of this thread's switches the kernel took away from it.
        -- Left nil when the thread switched not at all: a fraction of nothing
        -- is an absence of evidence, not a zero.
        if total > 0 then
          result.preempted_fraction = involuntary / total
        end
        fresh = true
      end
    end
  end
  if not fresh then
    -- A first reading, or a TID whose starttime moved under us.  Either way
    -- there is no interval to divide by, and a rate invented from a single
    -- cumulative total would be a fiction.
    result.quality = "gap"
  else
    result.quality = "fresh"
    result.interval_ns = elapsed_ns
  end
  remember_scheduler(self, identity, {
    starttime_ticks = starttime_ticks,
    -- Recorded only from a real reading.  A kernel without CONFIG_SCHEDSTATS
    -- publishes no schedstat at all, and carrying a previous value forward
    -- would difference a counter against a span it was not measured over.
    run_ns = parsed and parsed.run_ns or nil,
    wait_ns = parsed and parsed.wait_ns or nil,
    timeslices = parsed and parsed.timeslices or nil,
    -- Recorded even when schedstat is absent, so the interval is established
    -- for the switch counters on a kernel that publishes neither.
    switches = switches and {
      voluntary = switches.voluntary,
      involuntary = switches.involuntary,
    } or nil,
    at_ns = now,
  })
  return result
end

local function context_fs(self, context)
  if type(context) ~= "table" then return nil end
  return context.fs
end

local function wants_detail(context, process_id)
  if not context then
    return false
  end
  local selected = context.selected_process_ids
  return type(selected) == "table" and selected[process_id] == true
end

local function wants_thread_list(context, process_id)
  local selected = context and context.selected_process_thread_list_ids
  return type(selected) == "table" and selected[process_id] == true
end

local function selected_numa_process_id(context)
  local selected = context and context.selected_process_numa_ids
  if type(selected) ~= "table" then return nil end
  local id
  for candidate, wanted in pairs(selected) do
    if wanted == true then
      if id or type(candidate) ~= "string" then return nil end
      id = candidate
    end
  end
  return id
end

-- The process ids the table is currently drawing, bounded so a malformed or
-- hostile context cannot turn a viewport measurement into a full sweep.  The
-- bound is generous next to any real terminal: a viewport is as tall as the
-- screen, and a 200-row terminal is already far past where this table is
-- usable.
local MAX_VISIBLE_PROCESSES = 256

local function visible_process_ids(context, key)
  local selected = context and context[key or "visible_process_ids"]
  if type(selected) ~= "table" then return nil end
  local result, count = {}, 0
  for id, wanted in pairs(selected) do
    if wanted == true and type(id) == "string" and id ~= "" then
      count = count + 1
      if count > MAX_VISIBLE_PROCESSES then return nil end
      result[id] = true
    end
  end
  if count == 0 then return nil end
  return result
end

-- Per-thread detail is a second, narrower selection: the operator has picked
-- one TID out of a process they are already inspecting.  It is keyed by pid
-- rather than by process id because a TID is only meaningful together with the
-- process that owns it, and a stale entry for a process that is gone can never
-- match.
local function selected_thread_identity(context, pid)
  if not context then
    return nil
  end
  local selected = context.selected_thread_ids
  if type(selected) ~= "table" then
    return nil
  end
  local target = selected[pid]
  local tid = type(target) == "table" and target.tid or target
  if type(tid) ~= "number" or tid <= 0 or tid ~= tid then
    return nil
  end
  local starttime = type(target) == "table" and target.starttime_ticks or nil
  if starttime ~= nil and (type(starttime) ~= "number" or starttime < 0
      or starttime ~= starttime) then return nil end
  return tid, starttime
end

function Process:sample(context, previous)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  -- Bound native getdents retention before Lua allocation/sorting.  The small
  -- slack accounts for /proc's non-PID entries without making a fork storm an
  -- unbounded memory or I/O workload.
  local entries, list_error, directory_truncated = fs:list(
    self.proc_path, self.max_processes + DIRECTORY_ENTRY_SLACK)
  if not entries then
    return Common.error_result(list_error, Common.now_ns(context), self.proc_path)
  end

  local now = Common.now_ns(context)
  if self.identity_cache_fs ~= fs then
    -- A different procfs provider can reuse both PID and start time. Its
    -- identities and rate baselines must begin with a fresh observation.
    previous = nil
    self.io_bulk_last_ns = nil
    self.sched_memo = {}
    self.sched_memo_size = 0
    self.sched_newest, self.sched_oldest = nil, nil
  end
  local previous_data = Common.previous_data(previous)
  local elapsed_ns = previous_data and Common.elapsed_ns(now, previous.timestamp_ns) or nil
  local previous_by_id = previous_data and previous_data.by_id or {}
  local numa_process_id = selected_numa_process_id(context)
  -- This sample's cache; assigned over self.identity_cache at the end so
  -- identities that disappeared are dropped in the same pass.
  local live_cache = {}
  local prior_cache = self.identity_cache_fs == fs and self.identity_cache or {}
  -- One read per sample gives every process an age in wall-clock seconds.
  -- The first frame also uses that age for its lifetime CPU average. If
  -- uptime is unreadable, age remains unknown and rates still work.
  local uptime_seconds
  local uptime_content = fs:read(self.uptime_path, 4096)
  if type(uptime_content) == "string" then
    local seconds = tonumber(uptime_content:match("^%s*([%d%.]+)"))
    if type(seconds) == "number" and seconds == seconds
        and seconds ~= math.huge and seconds > 0 then
      uptime_seconds = seconds
    end
  end
  local clock_ticks_per_second = (context and context.clock_ticks_per_second) or self.clock_ticks_per_second
  local page_size_bytes = (context and context.page_size_bytes) or self.page_size_bytes
  if type(clock_ticks_per_second) ~= "number" or clock_ticks_per_second ~= clock_ticks_per_second
      or clock_ticks_per_second <= 0 or clock_ticks_per_second == math.huge
      or type(page_size_bytes) ~= "number" or page_size_bytes ~= page_size_bytes
      or page_size_bytes <= 0 or page_size_bytes == math.huge or page_size_bytes % 1 ~= 0 then
    return Common.result("error", now, nil, {
      quality = "error", reason = "invalid_process_system_constants", source = self.proc_path,
    })
  end
  local processes = {}
  local by_id = {}
  local by_pid = {}
  local races = 0
  local denied = 0
  local parse_errors = 0
  local supplemental_parse_errors = 0
  local scanned = 0
  local visible_ids = visible_process_ids(context)
  local visible_wait_ids = visible_process_ids(context, "visible_wait_process_ids")
  local resolve_username = context and context.resolve_username
  if type(resolve_username) ~= "function" then resolve_username = nil end
  local usernames = {}

  local candidates = {}
  for _, entry in ipairs(entries) do
    local pid = canonical_pid(entry)
    if pid then candidates[#candidates + 1] = pid end
  end
  local process_candidates = #candidates
  local truncated = directory_truncated == true or process_candidates > self.max_processes

  table.sort(candidates)

  -- A process I/O sort/filter needs comparable readings for the whole
  -- collected set. Never pay this cost for the default CPU table. The native
  -- batch reader amortizes the crossing on real procfs; fixtures keep their
  -- injected filesystem. Each identity retains its exact observation time.
  local bulk_rate = context and context.scan_process_io_rate == true
  local bulk_io = context and context.scan_process_io == true or bulk_rate
  local io_refresh_ns = self.read_io and 0
    or (bulk_rate and BULK_IO_RATE_REFRESH_NS or BULK_IO_REFRESH_NS)
  if not bulk_io then self.io_bulk_last_ns = nil end
  local bulk_due = bulk_io and (type(self.io_bulk_last_ns) ~= "number"
    or now < self.io_bulk_last_ns
    or now - self.io_bulk_last_ns >= io_refresh_ns
    or context.force_process_io_refresh == true)
  local io_batch_contents, io_batch_denied
  if bulk_due and self.use_native_batch and fs == FS.default
      and context_fs(self, context) == nil then
    local wanted = {}
    for index, pid in ipairs(candidates) do
      if index > self.max_processes or index > self.max_bulk_io_reads then break end
      wanted[#wanted + 1] = pid
    end
    local ok, contents, denied_flags = pcall(self.native.proc_batch, wanted, "io", 65536)
    if ok and type(contents) == "table" then
      io_batch_contents, io_batch_denied = contents, denied_flags
    end
  end
  if bulk_due then self.io_bulk_last_ns = now end
  local io_reads, io_reused, io_covered, io_rate_covered, io_capped = 0, 0, 0, 0, 0

  -- One native crossing for every stat file when the real /proc is in use.
  -- A context-injected fs (fixtures, isolated tests) always keeps the
  -- per-file reader even with the default proc_path, and so do pure-Lua runs.
  local batch_contents, batch_denied, batch_rows
  if self.use_native_batch and fs == FS.default and context_fs(self, context) == nil then
    local wanted = {}
    for index, pid in ipairs(candidates) do
      if index > self.max_processes then break end
      wanted[#wanted + 1] = pid
    end
    local rows = type(self.native.process_stat_row_fields) == "function"
    local mode = rows and "stat_rows" or self.use_native_parsed_stat and "stat_parsed" or "stat"
    local ok, contents, denied_flags = pcall(self.native.proc_batch, wanted, mode)
    if ok and type(contents) == "table" then
      batch_contents, batch_denied, batch_rows = contents, denied_flags, rows
    end
  end

  for index, pid in ipairs(candidates) do
    local entry = tostring(pid)
      if scanned >= self.max_processes then
        break
      end
      scanned = scanned + 1
      local base = self.proc_path .. "/" .. entry
      local stat_content, stat_error
      if batch_contents then
        stat_content = batch_contents[index]
        if stat_content == false then
          stat_content = nil
          if batch_denied and batch_denied[index] then
            stat_error = { kind = "denied" }
          end
        end
      else
        stat_content, stat_error = fs:read(base .. "/stat", 65536)
      end
      if not stat_content then
        if stat_error and stat_error.kind == "denied" then
          denied = denied + 1
        else
          races = races + 1
        end
      else
        local stat = type(stat_content) == "table" and stat_content
          or process_stat(self.native, stat_content)
        if not stat then
          parse_errors = parse_errors + 1
        elseif stat.pid ~= pid then
          races = races + 1
        else
          local is_kernel_thread = kernel_thread(stat)
          local native_row = batch_rows and type(stat_content) == "table"
          local process = native_row and stat or {
            id = stat.id,
            pid = stat.pid,
            starttime_ticks = stat.starttime_ticks,
            name = sanitize_text(stat.comm),
            state = stat.state,
            parent_pid = stat.ppid,
            process_group = stat.pgrp,
            session = stat.session,
            threads = stat.threads,
            priority = stat.priority,
            nice = stat.nice,
            processor = stat.processor,
            virtual_bytes = stat.vsize_bytes,
            resident_bytes = stat.rss_pages >= 0
              and stat.rss_pages <= math.maxinteger // page_size_bytes
              and (stat.rss_pages * page_size_bytes) or nil,
            cpu_ticks = stat.cpu_ticks,
            cpu_time_seconds = type(stat.cpu_ticks) == "number"
              and stat.cpu_ticks / clock_ticks_per_second or nil,
            elapsed_seconds = uptime_seconds
              and uptime_seconds - stat.starttime_ticks / clock_ticks_per_second or nil,
            cpu_percent = nil,
            quality = "gap",
          }
          if native_row then
            -- This fresh native table is already in the public row shape.
            -- Finish the context-dependent values and remove parser scratch
            -- fields, avoiding a second large table for every process.
            process.name = sanitize_text(process.name)
            process.resident_bytes = stat.rss_pages >= 0
              and stat.rss_pages <= math.maxinteger // page_size_bytes
              and (stat.rss_pages * page_size_bytes) or nil
            process.cpu_time_seconds = type(stat.cpu_ticks) == "number"
              and stat.cpu_ticks / clock_ticks_per_second or nil
            process.elapsed_seconds = uptime_seconds
              and uptime_seconds - stat.starttime_ticks / clock_ticks_per_second or nil
            process.flags, process.rss_pages = nil, nil
            process.quality = "gap"
          end
          if process.elapsed_seconds and process.elapsed_seconds < 0 then
            process.elapsed_seconds = process.elapsed_seconds >= -1 and 0 or nil
          end
          local old = previous_by_id[process.id]
          if old and elapsed_ns and elapsed_ns > 0 then
            local ticks = Common.delta(process.cpu_ticks, old.cpu_ticks)
            if ticks then
              local cpu_percent = (ticks + 0.0) / clock_ticks_per_second
                / (elapsed_ns / 1000000000) * 100
              if cpu_percent == cpu_percent and cpu_percent < math.huge then
                process.cpu_percent = math.max(0, cpu_percent)
                process.quality = "fresh"
              end
            end
          elseif process.elapsed_seconds and type(process.cpu_ticks) == "number" then
            -- The very first sample has nothing to difference against, so every
            -- row used to show "—" and a CPU-descending table was really sorted
            -- by PID.  Lifetime average CPU over the process's age is a usable
            -- first frame; it is explicitly marked estimated so it is never
            -- mistaken for an interval measurement.
            local age = process.elapsed_seconds
            if age > 0.5 then
              local cpu_percent = (process.cpu_ticks + 0.0) / clock_ticks_per_second
                / age * 100
              if cpu_percent == cpu_percent and cpu_percent < math.huge then
                process.cpu_percent = math.max(0, cpu_percent)
                process.quality = "estimated"
              end
            end
          end

          local detail = wants_detail(context, process.id)
          local thread_list = wants_thread_list(context, process.id)
          local command_value = nil
          local io_attempted = false
          local cached = prior_cache[process.id]
          if cached and cached.kernel_thread ~= nil and cached.kernel_thread ~= is_kernel_thread then
            cached = nil
          end
          if cached then
            process.uid = cached.uid
            process.user = cached.user
            if cached.command then process.command = cached.command end
            process.affinity = cached.affinity
            process.namespaces = cached.namespaces
          end
          local status_requested = self.read_status and (detail or not cached
            or type(cached.status_attempt_ns) ~= "number"
            or type(cached.status_next_ns) ~= "number"
            or now < cached.status_attempt_ns or now >= cached.status_next_ns)
          if status_requested then
            process.uid, process.user, process.affinity, process.namespaces = nil, nil, nil, nil
            local status_content, status_error = fs:read(base .. "/status", 256 * 1024)
            if status_content then
              local status = process_metadata(self.native, status_content)
              if status then
                process.uid = status.uid
                if cached and cached.uid == status.uid then process.user = cached.user end
                -- Periodic metadata refresh must not alternate the table's
                -- ordinary RSS source between stat and status.
                if detail or not cached then
                  process.resident_bytes = status.rss_bytes or process.resident_bytes
                end
                process.affinity = status.affinity
                if process.affinity then process.affinity.observed_ns = now end
                process.context_switches = {
                  voluntary = status.voluntary_context_switches,
                  involuntary = status.nonvoluntary_context_switches,
                }
                -- IDs run from this procfs mount towards the innermost
                -- namespace. The mount may itself be inside a container,
                -- so its first ID does not establish an initial-host PID.
                if status.nspid and #status.nspid > 0 then
                  process.namespaces = {
                    nspid = status.nspid,
                    nstgid = status.nstgid,
                    namespaced = #status.nspid > 1,
                    inner_pid = status.nspid[#status.nspid],
                    procfs_pid = status.nspid[1],
                  }
                end
              else
                process.partial = true
                process.partial_reason = "status_parse_error"
                supplemental_parse_errors = supplemental_parse_errors + 1
              end
            elseif status_error and status_error.kind == "denied" then
              process.partial = true
              process.partial_reason = "status_denied"
            else
              process.partial = true
              process.partial_reason = "status_unavailable"
            end
          end

          local supplemental_read = false
          if is_kernel_thread and not detail then
            process.command = nil
            command_value = false
          elseif (self.read_cmdline or detail) and (detail or not cached or not cached.command_read) then
            supplemental_read = true
            local cmdline, cmdline_error = fs:read(base .. "/cmdline", 64 * 1024)
            if cmdline and cmdline ~= "" then
              process.command = sanitize_text(cmdline)
              command_value = process.command
            elseif cmdline == "" then
              -- A genuinely empty command line is stable; do not reread it.
              process.command = nil
              command_value = false
            elseif cmdline_error then
              process.partial = true
              process.command_status = FS.error_status(cmdline_error)
            end
          end
          local cached_io = bulk_io and not bulk_due and not detail
            and not self.read_io and cached and type(cached.io) == "table"
            and type(cached.io_observed_ns) == "number"
            and now >= cached.io_observed_ns
            and now - cached.io_observed_ns < io_refresh_ns
          if cached_io then
            process.io = cached.io
            process.io_observed_ns = cached.io_observed_ns
            if type(cached.io_rate) == "table" then
              process.io_rate = {
                read_bytes_per_second = cached.io_rate.read_bytes_per_second,
                write_bytes_per_second = cached.io_rate.write_bytes_per_second,
                interval_ns = cached.io_rate.interval_ns,
                observed_ns = cached.io_rate.observed_ns,
                reason = cached.io_rate.reason,
                quality = cached.io_rate.quality == "fresh" and "held"
                  or cached.io_rate.quality,
              }
            end
            io_reused = io_reused + 1
          elseif self.read_io or detail or bulk_io then
            if bulk_io and not self.read_io and index > self.max_bulk_io_reads then
              process.io_status = "truncated"
              process.partial = true
              io_capped = io_capped + 1
            else
              supplemental_read = true
              io_attempted = true
              local io_content, io_error
              if bulk_io and bulk_due and io_batch_contents then
                io_content = io_batch_contents[index]
                if io_content == false or io_content == nil then
                  io_content = nil
                  io_error = type(io_batch_denied) == "table" and io_batch_denied[index]
                    and { kind = "denied" } or { kind = "missing" }
                end
              else
                io_content, io_error = fs:read(base .. "/io", 65536)
              end
              if bulk_io then io_reads = io_reads + 1 end
              if io_content then
                local parsed_io = Parsers.process_io(io_content)
                if parsed_io then
                  process.io = parsed_io
                  process.io_observed_ns = now
                  process.io_rate = process_io_rate(parsed_io,
                    cached and cached.io, cached and cached.io_observed_ns, now)
                else
                  process.io_status = "parse_error"
                  process.partial = true
                  supplemental_parse_errors = supplemental_parse_errors + 1
                end
              elseif io_error and io_error.kind == "denied" then
                process.io_status = "denied"
                process.partial = true
              elseif io_error then
                process.io_status = FS.error_status(io_error)
                process.partial = true
              end
            end
          end
          if self.read_cgroup or detail then
            supplemental_read = true
            local cgroup_content, cgroup_error = fs:read(base .. "/cgroup", 65536)
            if cgroup_content then
              local parsed_cgroups = Parsers.cgroup(cgroup_content)
              if parsed_cgroups then
                process.cgroups = parsed_cgroups
              else
                process.partial = true
                supplemental_parse_errors = supplemental_parse_errors + 1
              end
            elseif cgroup_error then
              process.partial = true
              process.cgroup_status = FS.error_status(cgroup_error)
            end
          end
          -- File descriptors are useful when diagnosing a leak, but one
          -- directory walk per PID would overwhelm the ordinary process
          -- scan. Only the open detail requests this bounded count.
          if detail then
            supplemental_read = true
            process.fd_detail = descriptor_detail(fs, base .. "/fd", now)
            local limits_content, limits_error = fs:read(base .. "/limits", 65536)
            if limits_content then
              local limits, parse_error = Parsers.process_open_file_limits(limits_content)
              if limits then
                process.fd_detail.limit = limits
                process.fd_detail.limit_status = "ok"
              else
                process.fd_detail.limit_status = parse_error == "open_file_limits_absent"
                  and "unavailable" or "error"
              end
            else
              process.fd_detail.limit_status = FS.error_status(limits_error)
            end
            local score, score_status = oom_counter(fs, base .. "/oom_score", 0, 1000)
            local adjustment, adjustment_status = oom_counter(fs,
              base .. "/oom_score_adj", -1000, 1000)
            if score_status ~= "unavailable" or adjustment_status ~= "unavailable" then
              process.oom = { score = score, score_status = score_status,
                adjustment = adjustment, adjustment_status = adjustment_status,
                observed_ns = now, source = base }
            end
          end
          -- Thread rows are a detail-only read: enumerating every process's
          -- /proc/<pid>/task every tick would multiply procfs traffic by the
          -- thread count for one table that shows a single selection.
          if detail or thread_list then
            supplemental_read = true
            local task_entries, task_error, task_truncated =
              fs:list(base .. "/task", self.max_detail_threads)
            if task_entries then
              local previous_threads = type(old) == "table"
                and type(old.thread_ticks_by_tid) == "table"
                and old.thread_ticks_by_tid or nil
              local thread_rows = {}
              local thread_ticks_by_tid = {}
              local thread_details = {}
              local thread_races = 0
              for _, task_entry in ipairs(task_entries) do
                local tid = canonical_pid(task_entry)
                if tid then
                  local task_stat, task_stat_error =
                    fs:read(base .. "/task/" .. task_entry .. "/stat", 65536)
                  local parsed_task = task_stat and process_stat(self.native, task_stat)
                  if parsed_task and parsed_task.pid == tid then
                    local thread = {
                      tid = tid,
                      name = sanitize_text(parsed_task.comm),
                      state = parsed_task.state,
                      nice = parsed_task.nice,
                      priority = parsed_task.priority,
                      cpu_ticks = parsed_task.cpu_ticks,
                      cpu_time_seconds = type(parsed_task.cpu_ticks) == "number"
                        and parsed_task.cpu_ticks / clock_ticks_per_second or nil,
                      elapsed_seconds = uptime_seconds
                        and uptime_seconds - parsed_task.starttime_ticks / clock_ticks_per_second or nil,
                      starttime_ticks = parsed_task.starttime_ticks,
                      leader = tid == process.pid,
                      cpu_percent = nil,
                      quality = "gap",
                    }
                    if thread.elapsed_seconds and thread.elapsed_seconds < 0 then
                      thread.elapsed_seconds = thread.elapsed_seconds >= -1 and 0 or nil
                    end
                    -- TIDs are recycled as threads exit, so ticks are only
                    -- differenced against the same thread identity, the same
                    -- starttime discipline the process rows use.
                    local previous_thread = previous_threads
                      and previous_threads[tid]
                    if previous_thread
                        and previous_thread.starttime_ticks == thread.starttime_ticks
                        and elapsed_ns and elapsed_ns > 0 then
                      local ticks = Common.delta(thread.cpu_ticks,
                        previous_thread.cpu_ticks)
                      if ticks then
                        local thread_percent = (ticks + 0.0) / clock_ticks_per_second
                          / (elapsed_ns / 1000000000) * 100
                        if thread_percent == thread_percent
                            and thread_percent < math.huge then
                          thread.cpu_percent = math.max(0, thread_percent)
                          thread.quality = "fresh"
                        end
                      end
                    end
                    local generation_matches = true
                    local selected_tid, selected_starttime =
                      selected_thread_identity(context, process.pid)
                    if tid == selected_tid and (selected_starttime == nil
                        or selected_starttime == thread.starttime_ticks) then
                      supplemental_read = true
                      local detail_value = self:_thread_detail(fs, context, base,
                        task_entry, tid, thread.starttime_ticks, now,
                        tid == process.pid and process.fd_detail or nil)
                      if detail_value then
                        thread_details[tid] = detail_value
                      else
                        generation_matches = false
                        thread_races = thread_races + 1
                      end
                    end
                    if generation_matches then
                      thread_ticks_by_tid[tid] = {
                        cpu_ticks = thread.cpu_ticks,
                        starttime_ticks = thread.starttime_ticks,
                      }
                      thread_rows[#thread_rows + 1] = thread
                    end
                  else
                    -- A thread that exited between the listing and the stat
                    -- read is normal churn, not a failed process sample.
                    thread_races = thread_races + 1
                  end
                end
              end
              table.sort(thread_rows, function(left, right)
                return left.tid < right.tid
              end)
              process.thread_rows = thread_rows
              process.thread_ticks_by_tid = thread_ticks_by_tid
              if next(thread_details) ~= nil then
                process.thread_details = thread_details
              end
              process.thread_scan = {
                total = process.threads,
                scanned = #thread_rows,
                races = thread_races,
                truncated = task_truncated == true,
              }
            elseif task_error then
              process.thread_status = FS.error_status(task_error)
            end
          end
          -- PSS/USS come from smaps_rollup, which is a small kernel-maintained
          -- summary rather than the full smaps walk: reading every mapping of
          -- every process would be unbounded I/O, and the rollup already
          -- carries the proportional and private totals the table needs.
          if detail then
            supplemental_read = true
            process.wait_site, process.wait_site_status = wait_site(fs, base)
            local rollup_content, rollup_error = fs:read(base .. "/smaps_rollup", 65536)
            if rollup_content then
              local parsed_rollup = Parsers.process_smaps_rollup(rollup_content)
              if parsed_rollup then
                local private_clean = parsed_rollup.Private_Clean
                local private_dirty = parsed_rollup.Private_Dirty
                process.memory_detail = {
                  pss = parsed_rollup.Pss,
                  -- USS is not a kernel field; it is the private share.
                  uss = (type(private_clean) == "number" and type(private_dirty) == "number")
                    and (private_clean + private_dirty) or nil,
                  rss = parsed_rollup.Rss,
                  swap = parsed_rollup.Swap,
                  shared_clean = parsed_rollup.Shared_Clean,
                  shared_dirty = parsed_rollup.Shared_Dirty,
                  pss_anon = parsed_rollup.Pss_Anon,
                  pss_file = parsed_rollup.Pss_File,
                  referenced = parsed_rollup.Referenced,
                }
              else
                process.memory_status = "parse_error"
                process.partial = true
                supplemental_parse_errors = supplemental_parse_errors + 1
              end
            elseif rollup_error then
              -- Kernels before 4.14 have no rollup file at all; report the
              -- reason instead of silently showing an empty memory section.
              process.memory_status = FS.error_status(rollup_error)
              process.partial = true
            end
          end
          if visible_wait_ids and visible_wait_ids[process.id] and not detail then
            -- The optional WCHAN column is sampled only for rows on screen.
            -- Unlike a scheduler rate, this is a symbolic value attached to
            -- the row; recheck PID generation before publishing it.
            supplemental_read = true
            process.wait_site, process.wait_site_status = wait_site(fs, base)
          end
          -- numa_maps walks a process's VMAs in the kernel.  Only an open
          -- process detail overlay requests it, and one reading serves ten
          -- ordinary process samples.  The identity-keyed previous row keeps
          -- a recycled pid from inheriting another process's node totals.
          if detail and process.id == numa_process_id then
            supplemental_read = true
            if old and type(old.numa_sample_ns) == "number"
                and now >= old.numa_sample_ns
                and now - old.numa_sample_ns < NUMA_REFRESH_NS then
              process.numa_detail = old.numa_detail
              process.numa_status = old.numa_status
              process.numa_sample_ns = old.numa_sample_ns
            else
              process.numa_sample_ns = now
              local maps, maps_error = fs:read(base .. "/numa_maps", NUMA_MAPS_MAX_BYTES)
              if maps then
                local parsed = Parsers.process_numa_maps(maps, page_size_bytes)
                if parsed then
                  process.numa_detail = parsed
                else
                  process.numa_status = "parse_error"
                end
              elseif maps_error then
                process.numa_status = maps_error.kind == "too_large"
                  and "too_large" or FS.error_status(maps_error)
              end
            end
          end
          if resolve_username and process.uid then
            local user = usernames[process.uid]
            if user ~= nil then
              process.user = user ~= false and user or nil
            else
              local resolved, value = pcall(resolve_username, process.uid)
              if resolved then
                process.user = sanitize_text(value)
                -- Names belong to UIDs, so one successful lookup (including
                -- an absent name) serves this scan. Retry exceptions and
                -- keep this map local to the current scan and resolver.
                usernames[process.uid] = process.user or false
              end
            end
          end

          -- Run-queue wait for a process, read only for the rows the table is
          -- actually showing.  The process table is where triage happens, and
          -- CPU share alone cannot tell a busy process from a starved one --
          -- both are running.  Reading it for every process on the machine
          -- would be a second full procfs sweep every tick for a column the
          -- operator cannot see, so the viewport is the bound: what is not on
          -- screen is not measured.
          local parsed_process_schedstat
          if visible_ids and visible_ids[process.id] then
            -- Separate procfs lookups can observe a recycled PID after the
            -- initial stat read. Fence this reading like other supplemental
            -- fields, and update the rate baseline only after that check.
            supplemental_read = true
            local schedstat_content, schedstat_error = fs:read(base .. "/schedstat", 4096)
            if schedstat_content then
              parsed_process_schedstat = Parsers.thread_schedstat(schedstat_content)
              if not parsed_process_schedstat then
                process.scheduler = { status = "parse_error" }
              end
            elseif schedstat_error then
              -- A kernel without CONFIG_SCHEDSTATS does not create the file.
              -- That is the kernel declining to publish the figure, which must
              -- not be drawn as a process that never waited for a cpu.
              process.scheduler = { status = FS.error_status(schedstat_error) }
            end
          end

          -- status is a supplemental read too.  Each /proc/<pid> path lookup
          -- can resolve to a newly reused PID, so verify the generation again
          -- after all supplemental fields have been collected.  Mixed samples
          -- are discarded instead of attaching another process's UID/RSS/I/O.
          -- Only a pass that actually opened supplemental files has a
          -- reuse window to re-verify; a fully cached row re-reads nothing,
          -- so the second stat fetch would be pure I/O for the same answer.
          supplemental_read = supplemental_read or status_requested
          local generation_matches = true
          if supplemental_read then
            local final_content = fs:read(base .. "/stat", 65536)
            if not final_content then
              races = races + 1
              generation_matches = false
            else
              local final_stat = process_stat(self.native, final_content)
              if not final_stat then
                parse_errors = parse_errors + 1
                generation_matches = false
              elseif final_stat.pid ~= process.pid
                or final_stat.starttime_ticks ~= process.starttime_ticks
                or kernel_thread(final_stat) ~= is_kernel_thread
              then
                races = races + 1
                generation_matches = false
              end
            end
          end
          if generation_matches then
            if parsed_process_schedstat then
              process.scheduler = self:_sched_rate("pid " .. base,
                parsed_process_schedstat, process.starttime_ticks, now)
            end
            if bulk_io and process.io
                and type(process.io.read_bytes) == "number"
                and type(process.io.write_bytes) == "number" then
              io_covered = io_covered + 1
            end
            if bulk_io and process.io_rate
                and type(process.io_rate.read_bytes_per_second) == "number"
                and type(process.io_rate.write_bytes_per_second) == "number" then
              io_rate_covered = io_rate_covered + 1
            end
            by_id[process.id] = process
            by_pid[process.pid] = process
            processes[#processes + 1] = process
            -- Forward only identities seen this sample, so the cache cannot
            -- outlive its processes or grow without bound.
            local entry = live_cache[process.id]
            if not entry then
              local unique_pid = (index == 1 or candidates[index - 1] ~= pid)
                and (index == #candidates or candidates[index + 1] ~= pid)
              -- This cache record is private. Its referenced values can also
              -- belong to older snapshots, so replace fields, not their data.
              entry = unique_pid and cached or {}
              entry.command_read = false
              entry.command = nil
              live_cache[process.id] = entry
            end
            if status_requested then
              entry.status_attempt_ns = now
              entry.status_next_ns = next_status_refresh(now, process.pid, process.starttime_ticks)
            elseif cached then
              entry.status_attempt_ns = cached.status_attempt_ns
              entry.status_next_ns = cached.status_next_ns
            end
            entry.uid = process.uid
            entry.kernel_thread = is_kernel_thread
            entry.user = process.user
            entry.affinity = process.affinity
            entry.namespaces = process.namespaces
            if io_attempted then
              entry.io = process.io
              entry.io_observed_ns = process.io_observed_ns
              entry.io_rate = process.io_rate
            elseif process.io then
              entry.io = process.io
              entry.io_observed_ns = process.io_observed_ns
              entry.io_rate = process.io_rate
            elseif cached then
              entry.io = cached.io
              entry.io_observed_ns = cached.io_observed_ns
              entry.io_rate = cached.io_rate
            end
            if command_value ~= nil then
              entry.command_read = true
              if command_value then entry.command = command_value end
            end
          end
        end
      end
  end

  table.sort(processes, function(left, right)
    return left.pid < right.pid
  end)
  local any_fresh, any_process_partial = false, false
  for _, process in ipairs(processes) do
    any_fresh = any_fresh or process.quality == "fresh"
    any_process_partial = any_process_partial or process.partial == true
  end
  self.identity_cache = live_cache
  self.identity_cache_fs = fs
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, {
    list = processes,
    by_id = by_id,
    by_pid = by_pid,
    scanned = scanned,
    races = races,
    denied = denied,
    parse_errors = parse_errors,
    supplemental_parse_errors = supplemental_parse_errors,
    process_candidates = process_candidates,
    process_limit = self.max_processes,
    clock_ticks_per_second = clock_ticks_per_second,
    uptime_seconds = uptime_seconds,
    io_scan = bulk_io and {
      status = (io_covered == #processes and not truncated and io_capped == 0)
        and "ok" or "partial",
      covered = io_covered, total = #processes,
      rate_covered = io_rate_covered, refresh_interval_ns = io_refresh_ns,
      refreshed = io_reads, reused = io_reused, capped = io_capped,
      observed_ns = now,
    } or nil,
    truncated = truncated,
    partial = truncated or denied > 0 or parse_errors > 0
      or supplemental_parse_errors > 0 or any_process_partial,
  }, {
    quality = (truncated or denied > 0 or parse_errors > 0
        or supplemental_parse_errors > 0 or any_process_partial)
      and "partial" or (any_fresh and "fresh" or "gap"),
    -- Two reasons, and this is the only collector on the list whose quality
    -- expression reaches a third word.  `partial` is set by the enumeration
    -- stopping at its cap, by a `/proc/<pid>/stat` that was denied, by two
    -- different parse failures, and by any single process carrying a
    -- `partial_reason` -- ten separate sites, all of them a read that failed or
    -- a read that produced something unparseable.  The verb is *collected*
    -- rather than *read`, and the reason is the cap: a cap is a limit this
    -- collector chose, and "could not be read" would send a user after a
    -- permissions problem that `data.truncated` contradicts in the same
    -- payload.  The per-process detail is already on each row as
    -- `partial_reason`, and the four sample-level counters are published
    -- beside it.
    --
    -- `gap` is the word that made this collector its own shape, and it has
    -- exactly one cause: no process on this sample has a fresh CPU rate, so
    -- there is no interval to difference against.  That is not a degradation
    -- of the process *data* -- every row may be perfectly readable, and the
    -- first sample after start-up always looks like this -- which is why it
    -- gets its own code rather than folding into the one above.  A user
    -- reading "part of the process data could not be collected" on a machine
    -- whose process table is complete would be chasing a fault that is not
    -- there; what they actually need to know is that a rate needs a second
    -- sample, or that a counter went backwards, and the per-row quality and
    -- the collector's own previous-sample reuse already say which.
    reason = (truncated or denied > 0 or parse_errors > 0
        or supplemental_parse_errors > 0 or any_process_partial)
      and "process_data_partial"
      -- Written `not any_fresh and "..." or nil` and not the other way round:
      -- `any_fresh and nil or "..."` evaluates to the string on the fresh path,
      -- because `and` yields nil and `or` then takes over.  That is the same
      -- trap as `cond and x or y` when x is nil or false, and it is invisible
      -- until a sample that is *not* degraded reaches the pairing assertion.
      or (not any_fresh and "process_rate_unavailable" or nil),
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = self.proc_path,
  })
end

Process.sanitize_text = sanitize_text
Process.DEFAULT_MAX_PROCESSES = DEFAULT_MAX_PROCESSES
Process.HARD_MAX_PROCESSES = HARD_MAX_PROCESSES
Process.DEFAULT_MAX_DETAIL_THREADS = DEFAULT_MAX_DETAIL_THREADS

return Process
