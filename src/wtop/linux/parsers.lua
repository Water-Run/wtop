local Parsers = {}

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function unsigned_number(token)
  if type(token) ~= "string" or not token:match("^%d+$") then return nil end
  local value = tonumber(token)
  if not finite_number(value) or value % 1 ~= 0 then return nil end
  if math.type and math.type(value) ~= "integer" then return nil end
  return value
end

-- Validate a compact kernel CPU/node list without expanding large ranges.
-- A caller may retain the source spelling and the bounded item count.
function Parsers.range_list(content, maximum_items, maximum_id, maximum_bytes)
  maximum_items = maximum_items or 4096
  maximum_id = maximum_id or 65535
  maximum_bytes = maximum_bytes or 1024
  if type(content) ~= "string" or #content > maximum_bytes then
    return nil, "invalid_range_list"
  end
  local value = content:match("^%s*(.-)%s*$")
  if value == "" or value:find("[^%d,%-]")
      or value:sub(1, 1) == "," or value:sub(-1) == ","
      or value:find(",,", 1, true) then return nil, "invalid_range_list" end
  local count, previous_end = 0, -1
  for token in value:gmatch("[^,]+") do
    local first, last = token:match("^(%d+)%-(%d+)$")
    if not first then first = token:match("^(%d+)$"); last = first end
    first, last = unsigned_number(first), unsigned_number(last)
    if first == nil or last == nil or first > last or first <= previous_end
        or last > maximum_id or last - first + 1 > maximum_items - count then
      return nil, "invalid_range_list"
    end
    count = count + last - first + 1
    previous_end = last
  end
  return value, count
end

local function exact_integer(token)
  if type(token) ~= "string" or not token:match("^%-?%d+$") then return nil end
  local value = tonumber(token)
  if not finite_number(value) or value % 1 ~= 0 then return nil end
  if math.type and math.type(value) ~= "integer" then return nil end
  return value
end

local function decimal_number(token)
  if type(token) ~= "string" or not token:match("^%d+%.?%d*$") then return nil end
  local value = tonumber(token)
  return finite_number(value) and value or nil
end

local function checked_multiply(value, multiplier)
  if not finite_number(value) or not finite_number(multiplier) or value < 0 or multiplier < 0 then
    return nil
  end
  if value > math.maxinteger // multiplier then return nil end
  return value * multiplier
end

local function checked_sum(values)
  local total = 0
  for _, value in ipairs(values) do
    if not finite_number(value) or value < 0 or total > math.maxinteger - value then return nil end
    total = total + value
  end
  return total
end

local function split_words(value)
  local result = {}
  for word in tostring(value):gmatch("%S+") do
    result[#result + 1] = word
  end
  return result
end

function Parsers.proc_stat(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local result = { cpus = {}, metadata = {}, unknown = {} }
  for line in content:gmatch("[^\n]+") do
    local key, rest = line:match("^(%S+)%s+(.+)$")
    if key and key:match("^cpu%d*$") then
      local values = {}
      for token in rest:gmatch("%S+") do
        local value = unsigned_number(token)
        if not value then
          return nil, "invalid_cpu_counter"
        end
        values[#values + 1] = value
      end
      if #values < 4 then
        return nil, "incomplete_cpu_line"
      end
      local cpu = {
        name = key,
        user = values[1] or 0,
        nice = values[2] or 0,
        system = values[3] or 0,
        idle = values[4] or 0,
        iowait = values[5] or 0,
        irq = values[6] or 0,
        softirq = values[7] or 0,
        steal = values[8] or 0,
        guest = values[9] or 0,
        guest_nice = values[10] or 0,
        raw = values,
      }
      cpu.idle_all = checked_sum({ cpu.idle, cpu.iowait })
      cpu.total = checked_sum({ cpu.user, cpu.nice, cpu.system, cpu.idle,
        cpu.iowait, cpu.irq, cpu.softirq, cpu.steal })
      if not cpu.idle_all or not cpu.total then return nil, "cpu_counter_sum_out_of_range" end
      result.cpus[key] = cpu
      if key == "cpu" then
        result.total = cpu
      else
        result.cores = result.cores or {}
        result.cores[#result.cores + 1] = cpu
      end
    elseif key then
      if key == "intr" or key == "ctxt" or key == "btime" or key == "processes"
          or key == "procs_running" or key == "procs_blocked" then
        local first = unsigned_number(rest:match("^(%S+)"))
        if first == nil then return nil, "invalid_proc_stat_metadata" end
        result.metadata[key] = first
      else
        result.unknown[key] = rest
      end
    end
  end
  if not result.total then
    return nil, "aggregate_cpu_missing"
  end
  return result
end

function Parsers.loadavg(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local normalized = content:match("^%s*(.-)%s*$")
  local one, five, fifteen, running, total, last_pid = normalized:match(
    "^([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)%s+(%d+)/(%d+)%s+(%d+)$"
  )
  if not one then
    return nil, "invalid_loadavg"
  end
  local values = {
    one = decimal_number(one), five = decimal_number(five), fifteen = decimal_number(fifteen),
    running = unsigned_number(running), total = unsigned_number(total),
    last_pid = unsigned_number(last_pid),
  }
  if not values.one or not values.five or not values.fifteen or not values.running
      or not values.total or not values.last_pid then
    return nil, "invalid_loadavg"
  end
  return values
end

function Parsers.meminfo(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local result = {}
  for line in content:gmatch("[^\n]+") do
    local key, value, unit = line:match("^([%w_()]+):%s*(%d+)%s*(%a*)%s*$")
    if key and value then
      local number = unsigned_number(value)
      if not number then return nil, "invalid_meminfo_value" end
      if unit == "kB" then
        number = checked_multiply(number, 1024)
        if not number then return nil, "meminfo_value_out_of_range" end
      elseif unit ~= "" then
        return nil, "unsupported_meminfo_unit"
      end
      if result[key] ~= nil then return nil, "duplicate_meminfo_key" end
      result[key] = number
    elseif line:match("%S") then
      return nil, "invalid_meminfo_line"
    end
  end
  if not result.MemTotal or result.MemTotal <= 0 then
    return nil, "MemTotal_missing"
  end
  return result
end

function Parsers.vmstat(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local result = {}
  for line in content:gmatch("[^\n]+") do
    local key, value = line:match("^(%S+)%s+(%-?%d+)%s*$")
    if not key then return nil, "invalid_vmstat_line" end
    local number = exact_integer(value)
    if number == nil then return nil, "invalid_vmstat_value" end
    if result[key] ~= nil then return nil, "duplicate_vmstat_key" end
    result[key] = number
  end
  return result
end

function Parsers.psi(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local result = {}
  for line in content:gmatch("[^\n]+") do
    local kind, rest = line:match("^(%a+)%s+(.+)$")
    if kind == "some" or kind == "full" then
      if result[kind] ~= nil then return nil, "duplicate_psi_line" end
      local values = {}
      local tokens = 0
      for token in rest:gmatch("%S+") do
        local key, value = token:match("^([%w_]+)=([%d%.]+)$")
        if not key or values[key] ~= nil then return nil, "invalid_psi_field" end
        local number = key == "total" and unsigned_number(value) or decimal_number(value)
        if number == nil then return nil, "invalid_psi_value" end
        values[key] = number
        tokens = tokens + 1
      end
      if tokens == 0 or values.avg10 == nil or values.avg60 == nil
          or values.avg300 == nil or values.total == nil then
        return nil, "incomplete_psi_line"
      end
      result[kind] = values
    elseif line:match("%S") then
      return nil, "invalid_psi_line"
    end
  end
  if not result.some and not result.full then
    return nil, "psi_lines_missing"
  end
  return result
end

function Parsers.diskstats(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local devices = {}
  local seen = {}
  for line in content:gmatch("[^\n]+") do
    local words = split_words(line)
    if #words > 0 then
      if #words < 14 then return nil, "incomplete_diskstats_line" end
      local major, minor = unsigned_number(words[1]), unsigned_number(words[2])
      if not major or not minor or type(words[3]) ~= "string" or words[3] == "" then
        return nil, "invalid_disk_identity"
      end
      local id = words[1] .. ":" .. words[2]
      if seen[id] then return nil, "duplicate_disk_identity" end
      seen[id] = true
        local values = {}
        for index = 4, 14 do
          values[index] = unsigned_number(words[index])
          if values[index] == nil then return nil, "invalid_disk_counter" end
        end
        for index = 15, math.min(#words, 20) do
          values[index] = unsigned_number(words[index])
          if values[index] == nil then return nil, "invalid_disk_counter" end
        end
        devices[#devices + 1] = {
          major = major,
          minor = minor,
          id = words[1] .. ":" .. words[2],
          name = words[3],
          reads_completed = values[4],
          reads_merged = values[5],
          sectors_read = values[6],
          read_time_ms = values[7],
          writes_completed = values[8],
          writes_merged = values[9],
          sectors_written = values[10],
          write_time_ms = values[11],
          io_in_progress = values[12],
          io_time_ms = values[13],
          weighted_io_time_ms = values[14],
          discards_completed = values[15],
          discards_merged = values[16],
          sectors_discarded = values[17],
          discard_time_ms = values[18],
          flushes_completed = values[19],
          flush_time_ms = values[20],
        }
    end
  end
  return devices
end

function Parsers.net_dev(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local interfaces = {}
  for line in content:gmatch("[^\n]+") do
    local name, rest = line:match("^%s*([^:]+):%s*(.+)$")
    if name and rest then
      local values = {}
      for token in rest:gmatch("%S+") do
        local number = unsigned_number(token)
        if number == nil then return nil, "invalid_network_counter" end
        values[#values + 1] = number
      end
      if #values < 16 then return nil, "incomplete_network_line" end
      if #values >= 16 then
        name = name:match("^%s*(.-)%s*$")
        if name == "" or name:find("[%c]") then return nil, "invalid_network_name" end
        interfaces[#interfaces + 1] = {
          name = name,
          rx_bytes = values[1],
          rx_packets = values[2],
          rx_errors = values[3],
          rx_drops = values[4],
          rx_fifo = values[5],
          rx_frame = values[6],
          rx_compressed = values[7],
          rx_multicast = values[8],
          tx_bytes = values[9],
          tx_packets = values[10],
          tx_errors = values[11],
          tx_drops = values[12],
          tx_fifo = values[13],
          tx_collisions = values[14],
          tx_carrier = values[15],
          tx_compressed = values[16],
        }
      end
    elseif line:find(":", 1, true) then
      return nil, "invalid_network_line"
    end
  end
  return interfaces
end

-- The first three softnet columns have remained the processed, dropped and
-- time-squeeze counters across kernel layouts. Newer kernels also print the
-- receive backlog and an explicit CPU id; without that id the rows cannot be
-- matched safely across samples when CPUs go offline.
function Parsers.softnet_stat(content)
  if type(content) ~= "string" or #content > 1024 * 1024 then
    return nil, "invalid_softnet_stat"
  end
  local rows, seen, indexed = {}, {}, nil
  local function hex32(token)
    if type(token) ~= "string" or #token < 1 or #token > 8
        or not token:match("^%x+$") then return nil end
    return tonumber(token, 16)
  end
  for line in content:gmatch("[^\n]+") do
    if #rows >= 4096 then return nil, "softnet_row_limit" end
    local fields = split_words(line)
    if #fields < 3 or #fields > 32 then return nil, "invalid_softnet_line" end
    local processed, dropped, squeezed = hex32(fields[1]), hex32(fields[2]),
      hex32(fields[3])
    if not processed or not dropped or not squeezed then
      return nil, "invalid_softnet_counter"
    end
    local has_id = #fields >= 13
    if indexed ~= nil and indexed ~= has_id then
      return nil, "inconsistent_softnet_columns"
    end
    indexed = has_id
    local row = { processed = processed, dropped = dropped, time_squeeze = squeezed }
    if has_id then
      row.backlog_packets = hex32(fields[12])
      row.cpu = hex32(fields[13])
      if not row.backlog_packets or not row.cpu or row.cpu > 65535 or seen[row.cpu] then
        return nil, "invalid_softnet_cpu"
      end
      seen[row.cpu] = true
      if #fields >= 15 then
        row.input_backlog_packets = hex32(fields[14])
        row.process_backlog_packets = hex32(fields[15])
        if not row.input_backlog_packets or not row.process_backlog_packets then
          return nil, "invalid_softnet_backlog"
        end
      end
    end
    rows[#rows + 1] = row
  end
  if #rows == 0 then return nil, "softnet_rows_missing" end
  return { rows = rows, indexed = indexed == true }
end

-- Field positions (after state) that process_stat needs; defined once so a
-- per-process parse does not allocate its own lookup table.
local PROCESS_STAT_REQUIRED = {
  [1] = true, [2] = true, [3] = true, [4] = true, [6] = true, [7] = true,
  [9] = true, [11] = true, [12] = true, [15] = true, [16] = true, [17] = true,
  [19] = true, [20] = true, [21] = true,
}

function Parsers.process_stat(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  -- Linux permits ')' inside comm, so the closing parenthesis is the last
  -- one. Scanning for it directly avoids the greedy pattern capture that
  -- dominated whole-table parse time.
  local close, seek = nil, 0
  while true do
    local found = content:find(")", seek + 1, true)
    if not found then break end
    close, seek = found, found
  end
  local open = close and content:find("(", 1, true) or nil
  if not close or not open or open > close or open < 2 then
    return nil, "invalid_process_stat"
  end
  local pid_token = content:sub(1, open - 1):match("^(%d+)%s+$")
  local state_pos = close and content:find("%S", close + 1) or nil
  if not pid_token or not state_pos then
    return nil, "invalid_process_stat"
  end
  local comm = content:sub(open + 1, close - 1)
  local state = content:sub(state_pos, state_pos)
  local rest_start = content:find("%S", state_pos + 1)
  local numbers = {}
  local fields = {}
  local index = 0
  for word in (rest_start and content:sub(rest_start) or ""):gmatch("%S+") do
    index = index + 1
    if PROCESS_STAT_REQUIRED[index] or index == 36 then
      fields[index] = word
      if index == 36 then break end
    end
  end
  if index < 21 then
    return nil, "incomplete_process_stat"
  end
  for position in pairs(PROCESS_STAT_REQUIRED) do
    numbers[position] = exact_integer(fields[position])
    if numbers[position] == nil then return nil, "invalid_process_stat_number" end
  end
  if numbers[1] < 0 or numbers[2] < 0 or numbers[3] < 0 or numbers[6] < 0
      or numbers[7] < 0 or numbers[9] < 0 or numbers[11] < 0 or numbers[12] < 0
      or numbers[17] < 0 or numbers[19] < 0 or numbers[20] < 0 then
    return nil, "invalid_process_stat_range"
  end
  local processor
  if fields[36] ~= nil then
    processor = exact_integer(fields[36])
    if processor == nil or processor < 0 then return nil, "invalid_process_stat_processor" end
  end
  local parsed_pid = exact_integer(pid_token)
  if not parsed_pid or parsed_pid <= 0 then return nil, "invalid_process_pid" end
  if numbers[11] > math.maxinteger - numbers[12] then
    return nil, "process_cpu_ticks_out_of_range"
  end
  local parsed = {
    pid = parsed_pid,
    comm = comm,
    state = state,
    ppid = numbers[1],
    pgrp = numbers[2],
    session = numbers[3],
    tty_nr = numbers[4],
    flags = numbers[6],
    minflt = numbers[7],
    majflt = numbers[9],
    utime_ticks = numbers[11],
    stime_ticks = numbers[12],
    priority = numbers[15],
    nice = numbers[16],
    threads = numbers[17],
    starttime_ticks = numbers[19],
    vsize_bytes = numbers[20],
    rss_pages = numbers[21],
    processor = processor,
  }
  parsed.cpu_ticks = parsed.utime_ticks + parsed.stime_ticks
  parsed.id = tostring(parsed.pid) .. ":" .. tostring(parsed.starttime_ticks)
  return parsed
end

function Parsers.process_status(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local result = {}
  for line in content:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_]+):%s*(.-)%s*$")
    if key then
      if result[key] ~= nil then return nil, "duplicate_process_status_key" end
      result[key] = value
    end
  end
  local uid = result.Uid and unsigned_number(result.Uid:match("^(%d+)%s")) or nil
  if result.Uid and uid == nil then return nil, "invalid_process_uid" end
  -- Tgid is the thread group's id: for a process it repeats the pid, and for a
  -- thread it names the process the thread belongs to.  It is read from status
  -- rather than from field 5 of stat because that field is not a portable
  -- thread-group id: kernels and containers have been seen to report 0 or -1
  -- there while status still carries the real value, and a wrong ownership
  -- claim is worse than no claim at all.  The line carries a single id, so the
  -- match is anchored rather than trailing-space tolerant like Uid's.
  local tgid = result.Tgid and unsigned_number(result.Tgid:match("^(%d+)%s*$")) or nil
  if result.Tgid and tgid == nil then return nil, "invalid_process_tgid" end
  local vmrss = result.VmRSS and unsigned_number(result.VmRSS:match("^(%d+)%s+kB%s*$")) or nil
  if result.VmRSS and vmrss == nil then return nil, "invalid_process_rss" end
  local rss_bytes = vmrss and checked_multiply(vmrss, 1024) or nil
  if vmrss and not rss_bytes then return nil, "process_rss_out_of_range" end
  local voluntary = result.voluntary_ctxt_switches
    and unsigned_number(result.voluntary_ctxt_switches) or nil
  local involuntary = result.nonvoluntary_ctxt_switches
    and unsigned_number(result.nonvoluntary_ctxt_switches) or nil
  if result.voluntary_ctxt_switches and voluntary == nil then
    return nil, "invalid_voluntary_context_switches"
  end
  if result.nonvoluntary_ctxt_switches and involuntary == nil then
    return nil, "invalid_nonvoluntary_context_switches"
  end
  -- NSpid and NStgid list the id as seen from the innermost namespace outwards,
  -- so a process inside a container reports its own pid first.  A single value
  -- means the process shares the namespace of whoever read it; more than one
  -- means it is nested, and the first value is the id an operator sees from
  -- inside.  The list is capped because a deeply nested chain is not something
  -- a table should be sized by.
  local function id_chain(key)
    local line = result[key]
    if not line then return nil end
    local chain, count = {}, 0
    for token in line:gmatch("%d+") do
      local value = unsigned_number(token)
      if value == nil then return nil, "invalid_" .. key:lower() end
      count = count + 1
      if count > 4 then
        -- A chain longer than any real nesting is malformed input, not a
        -- deeper container, and must not be silently truncated into a lie.
        return nil, "process_namespace_chain_too_long"
      end
      chain[#chain + 1] = value
    end
    if #chain == 0 then return nil, "invalid_" .. key:lower() end
    return chain
  end
  local nspid, nspid_error = id_chain("NSpid")
  if nspid_error then return nil, nspid_error end
  local nstgid, nstgid_error = id_chain("NStgid")
  if nstgid_error then return nil, nstgid_error end
  local affinity
  if result.Cpus_allowed_list ~= nil or result.Mems_allowed_list ~= nil then
    affinity = { issues = {} }
    for _, specification in ipairs({
      { "Cpus_allowed_list", "cpus_allowed_list", "cpus_allowed_count" },
      { "Mems_allowed_list", "mems_allowed_list", "mems_allowed_count" },
    }) do
      local raw = result[specification[1]]
      if raw ~= nil then
        local list, count = Parsers.range_list(raw, 4096, 65535, 1024)
        if list then
          affinity[specification[2]] = list
          affinity[specification[3]] = count
        else
          affinity.issues[#affinity.issues + 1] = {
            field = specification[1], status = "error",
          }
        end
      end
    end
    if #affinity.issues == 0 and affinity.cpus_allowed_list
        and affinity.mems_allowed_list then
      affinity.status = "ok"
    elseif #affinity.issues == 2 then
      affinity.status = "error"
    else
      affinity.status = "partial"
    end
  end
  return {
    raw = result,
    uid = uid,
    tgid = tgid,
    rss_bytes = rss_bytes,
    voluntary_context_switches = voluntary,
    nonvoluntary_context_switches = involuntary,
    nspid = nspid,
    nstgid = nstgid,
    affinity = affinity,
  }
end

-- /proc/<pid>/limits is an English kernel table. Only the open-file row is
-- needed here; a missing or malformed row must not turn into a zero limit.
function Parsers.process_open_file_limits(content)
  if type(content) ~= "string" then return nil, "content_required" end
  for line in content:gmatch("[^\n]+") do
    if line:match("^Max open files%s") then
      local soft_text, hard_text = line:match(
        "^Max open files%s+(%S+)%s+(%S+)%s+files%s*$")
      if not soft_text then return nil, "invalid_open_file_limits" end
      local soft_unlimited = soft_text == "unlimited"
      local hard_unlimited = hard_text == "unlimited"
      local soft = not soft_unlimited and unsigned_number(soft_text) or nil
      local hard = not hard_unlimited and unsigned_number(hard_text) or nil
      if (not soft_unlimited and soft == nil) or (not hard_unlimited and hard == nil)
          or (soft_unlimited and not hard_unlimited)
          or (soft and hard and soft > hard) then
        return nil, "invalid_open_file_limits"
      end
      return {
        soft = soft, hard = hard,
        soft_unlimited = soft_unlimited,
        hard_unlimited = hard_unlimited,
      }
    end
  end
  return nil, "open_file_limits_absent"
end

function Parsers.process_io(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local result = {}
  for line in content:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_]+):%s*(%d+)%s*$")
    if not key then return nil, "invalid_process_io_line" end
    local number = unsigned_number(value)
    if number == nil then return nil, "invalid_process_io_value" end
    if result[key] ~= nil then return nil, "duplicate_process_io_key" end
    result[key] = number
  end
  return result
end

-- /proc/<pid>/task/<tid>/schedstat is three unsigned numbers on one line:
-- nanoseconds spent running on a cpu, nanoseconds spent waiting on a runqueue,
-- and the number of timeslices the task was given.  Unlike /sched, whose field
-- set changes with the kernel version and its configuration, this file is a
-- fixed three-field ABI, so it is the one the scheduler view is built on.  A
-- kernel built without CONFIG_SCHEDSTATS does not create the file at all, which
-- is reported as unavailable rather than as three zeroes.
function Parsers.thread_schedstat(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local run_ns, wait_ns, timeslices =
    content:match("^%s*(%d+)%s+(%d+)%s+(%d+)%s*$")
  if not run_ns then
    return nil, "invalid_thread_schedstat"
  end
  return {
    run_ns = unsigned_number(run_ns),
    wait_ns = unsigned_number(wait_ns),
    timeslices = unsigned_number(timeslices),
  }
end

-- /proc/<pid>/task/<tid>/sched is a human-readable dump whose keys come and go
-- with the kernel version and its build options: a field this host does not
-- print (se.statistics.wait_sum, for one) is simply absent, not zero.  Only
-- the scheduling policy is taken, and only because nothing smaller reports it;
-- every other key is ignored rather than guessed at, so a kernel that renames
-- or drops one costs this view nothing.  An unrecognised policy number is kept
-- as the number, because naming it would be a guess.
function Parsers.thread_sched(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local result = {}
  local policy = content:match("\npolicy%s+:%s*(%-?%d+)")
  if policy then
    result.policy = tonumber(policy)
  end
  return result
end

-- /proc/<pid>/smaps_rollup is the kernel's per-process memory summary.  The
-- first line is the synthetic mapping header that ends in "[rollup]"; every
-- later line is "Key: <n> kB" and is converted to bytes here so callers never
-- have to know the unit the kernel prints.
function Parsers.process_smaps_rollup(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local result = {}
  local fields = 0
  for line in content:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_]+):%s*(%d+)%s*kB%s*$")
    if key then
      local number = unsigned_number(value)
      if number == nil then return nil, "invalid_smaps_rollup_value" end
      if result[key] ~= nil then return nil, "duplicate_smaps_rollup_key" end
      result[key] = number * 1024
      fields = fields + 1
    elseif not line:match("%[rollup%]%s*$") then
      return nil, "invalid_smaps_rollup_line"
    end
  end
  if fields == 0 then return nil, "empty_smaps_rollup" end
  return result
end

-- numa_maps counts mapped pages per VMA and node.  A huge VMA counts huge
-- pages, so its own kernel page size must be used before aggregating nodes.
-- Keep only totals: addresses and backing file names are private detail.
function Parsers.process_numa_maps(content, base_page_bytes)
  if type(content) ~= "string" then return nil, "content_required" end
  if type(base_page_bytes) ~= "number" or base_page_bytes < 1
      or base_page_bytes % 1 ~= 0 then return nil, "invalid_page_size" end
  local totals, mappings, node_count, total = {}, 0, 0, 0
  for line in content:gmatch("[^\n]+") do
    mappings = mappings + 1
    if mappings > 8192 then return nil, "too_many_mappings" end
    local address, policy = line:match("^(%x+)%s+(%S+)")
    if not address or not policy then return nil, "invalid_numa_maps_line" end
    local page_kb, huge, line_nodes = nil, false, {}
    for token in line:gmatch("%S+") do
      local size = token:match("^kernelpagesize_kB=(%d+)$")
      if size then
        if page_kb then return nil, "duplicate_page_size" end
        page_kb = unsigned_number(size)
        if not page_kb or page_kb < 1 then return nil, "invalid_page_size" end
      elseif token == "huge" then
        huge = true
      else
        local node, pages = token:match("^N(%d+)=(%d+)$")
        if node then
          node, pages = unsigned_number(node), unsigned_number(pages)
          if not node or node > 65535 or not pages then
            return nil, "invalid_node_pages"
          end
          if line_nodes[node] then return nil, "duplicate_node" end
          line_nodes[node] = pages
        elseif token:match("^N%d+=") or token:match("^kernelpagesize_kB=") then
          return nil, "invalid_numa_maps_value"
        end
      end
    end
    if next(line_nodes) then
      if huge and not page_kb then return nil, "huge_page_size_missing" end
      local page_bytes = page_kb and checked_multiply(page_kb, 1024) or base_page_bytes
      if not page_bytes then return nil, "page_size_out_of_range" end
      for node, pages in pairs(line_nodes) do
        local amount = checked_multiply(pages, page_bytes)
        if not amount or total > math.maxinteger - amount
            or (totals[node] or 0) > math.maxinteger - amount then
          return nil, "node_bytes_out_of_range"
        end
        if totals[node] == nil then
          node_count = node_count + 1
          if node_count > 128 then return nil, "too_many_nodes" end
        end
        totals[node] = (totals[node] or 0) + amount
        total = total + amount
      end
    end
  end
  local nodes = {}
  for node, mapped_bytes in pairs(totals) do
    nodes[#nodes + 1] = { node_id = node, mapped_bytes = mapped_bytes }
  end
  table.sort(nodes, function(a, b) return a.node_id < b.node_id end)
  return { nodes = nodes, total_mapped_bytes = total, mappings = mappings }
end

-- PCIe AER device files have named error classes and one authoritative
-- TOTAL_ERR_* line.  The kernel explicitly says a message may contain several
-- errors, so adding the class counters is not a substitute for that total.
function Parsers.pci_aer_stats(content, total_key)
  if type(content) ~= "string" or #content > 16 * 1024 then
    return nil, "invalid_aer_content"
  end
  if total_key ~= "TOTAL_ERR_COR" and total_key ~= "TOTAL_ERR_FATAL"
      and total_key ~= "TOTAL_ERR_NONFATAL" then
    return nil, "invalid_aer_total_key"
  end
  local total, categories, seen, lines = nil, {}, {}, 0
  for line in content:gmatch("[^\n]+") do
    lines = lines + 1
    if lines > 64 then return nil, "too_many_aer_lines" end
    local name, token = line:match("^%s*(.-)%s+(%d+)%s*$")
    if not name or name == "" or #name > 64 or name:find("[%c]")
        or seen[name] then return nil, "invalid_aer_line" end
    local value = unsigned_number(token)
    if value == nil then return nil, "invalid_aer_counter" end
    seen[name] = true
    if name == total_key then
      total = value
    elseif name:match("^TOTAL_") then
      return nil, "unexpected_aer_total"
    elseif value > 0 then
      if #categories >= 32 then return nil, "too_many_aer_categories" end
      categories[#categories + 1] = { name = name, count = value }
    end
  end
  if total == nil then return nil, "aer_total_missing" end
  return { total = total, categories = categories }
end

function Parsers.pci_aer_root_total(content)
  if type(content) ~= "string" or #content > 64 then return nil end
  return unsigned_number(content:match("^%s*(%d+)%s*$"))
end

-- Match numeric IRQs explicitly named by sysfs to /proc/interrupts. Textual
-- handler names are not used as device identity. Keep only the four busiest
-- CPUs per vector so a large CPU machine cannot inflate a Snapshot.
function Parsers.proc_interrupts(content, wanted)
  if type(content) ~= "string" or #content > 4 * 1024 * 1024
      or type(wanted) ~= "table" then return nil, "invalid_interrupts_content" end
  local first = content:match("^([^\n]*)")
  if not first or #first > 65536 then return nil, "invalid_interrupts_header" end
  local cpus = {}
  for token in first:gmatch("%S+") do
    local id = unsigned_number(token:match("^CPU(%d+)$"))
    if id == nil or id > 65535 or #cpus >= 4096 then
      return nil, "invalid_interrupts_header"
    end
    cpus[#cpus + 1] = id
  end
  if #cpus == 0 then return nil, "invalid_interrupts_header" end
  local totals, partial, lines, header = {}, false, 0, true
  for line in content:gmatch("[^\n]+") do
    if header then header = false
    else
      lines = lines + 1
      if lines > 65536 or #line > 65536 then
        partial = true
        break
      end
      local token, rest = line:match("^%s*(%d+):%s*(.*)$")
      local irq = token and unsigned_number(token)
      if irq and wanted[irq] then
        if totals[irq] ~= nil then
          totals[irq] = false
          partial = true
        else
          local total, top, position, valid = 0, {}, 0, true
          for field in rest:gmatch("%S+") do
            if position == #cpus then break end
            position = position + 1
            local amount = unsigned_number(field)
            if amount == nil or amount > math.maxinteger - total then
              valid = false
              break
            end
            total = total + amount
            if amount > 0 then
              top[#top + 1] = { cpu_id = cpus[position], count = amount }
              table.sort(top, function(a, b)
                return a.count > b.count or a.count == b.count
                  and a.cpu_id < b.cpu_id
              end)
              if #top > 4 then top[5] = nil end
            end
          end
          if valid and position == #cpus then
            totals[irq] = { total = total, top_cpus = top }
          else
            totals[irq] = false
            partial = true
          end
        end
      end
    end
  end
  return totals, partial and "partial" or "ok"
end

function Parsers.cgroup(content)
  local result = {}
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  for line in content:gmatch("[^\n]+") do
    local hierarchy, controllers, path = line:match("^(%d+):([^:]*):(.*)$")
    local parsed_hierarchy = hierarchy and unsigned_number(hierarchy) or nil
    if parsed_hierarchy == nil then return nil, "invalid_cgroup_line" end
    result[#result + 1] = {
      hierarchy = parsed_hierarchy,
      controllers = controllers,
      path = path,
    }
  end
  return result
end

function Parsers.drm_fdinfo(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local result = {
    engines_ns = {},
    memory_bytes = {},
    unknown = {},
  }
  for line in content:gmatch("[^\n]+") do
    local key, value, unit = line:match("^([%w_%-]+):%s*([%d]+)%s*(%S*)")
    if key and value then
      local number = unsigned_number(value)
      if number == nil then return nil, "invalid_drm_fdinfo_value" end
      local engine = key:match("^drm%-engine%-(.+)$")
      local memory = key:match("^drm%-memory%-(.+)$")
      if engine then
        if unit == "ns" or unit == "" then
          if result.engines_ns[engine] ~= nil then return nil, "duplicate_drm_engine" end
          result.engines_ns[engine] = number
        else
          result.unknown[key] = { value = number, unit = unit }
        end
      elseif memory then
        local multipliers = { [""] = 1, B = 1, KiB = 1024, MiB = 1024 * 1024,
          GiB = 1024 * 1024 * 1024 }
        local multiplier = multipliers[unit]
        local bytes = multiplier and checked_multiply(number, multiplier) or nil
        if bytes then
          if result.memory_bytes[memory] ~= nil then return nil, "duplicate_drm_memory" end
          result.memory_bytes[memory] = bytes
        else
          result.unknown[key] = { value = number, unit = unit }
        end
      else
        result.unknown[key] = { value = number, unit = unit }
      end
    else
      local text_key, text_value = line:match("^([%w_%-]+):%s*(.*)$")
      if text_key then
        result[text_key] = text_value
      end
    end
  end
  return result
end

return Parsers
