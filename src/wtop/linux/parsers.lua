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

function Parsers.process_stat(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  -- Greedy comm capture is intentional: Linux permits ')' inside comm.
  local pid, comm, state, rest = content:match("^(%d+)%s+%((.*)%)%s+(%S)%s+(.+)$")
  if not pid then
    return nil, "invalid_process_stat"
  end
  local fields = split_words(rest)
  if #fields < 21 then
    return nil, "incomplete_process_stat"
  end
  local required = { 1, 2, 3, 4, 6, 7, 9, 11, 12, 15, 16, 17, 19, 20, 21 }
  local numbers = {}
  for _, index in ipairs(required) do
    numbers[index] = exact_integer(fields[index])
    if numbers[index] == nil then return nil, "invalid_process_stat_number" end
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
  local parsed_pid = exact_integer(pid)
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
  return {
    raw = result,
    uid = uid,
    rss_bytes = rss_bytes,
    voluntary_context_switches = voluntary,
    nonvoluntary_context_switches = involuntary,
  }
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
