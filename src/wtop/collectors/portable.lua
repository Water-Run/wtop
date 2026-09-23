-- Collectors backed by native host APIs on macOS and Windows. They keep the
-- Linux Snapshot contract so the scheduler, ViewModel, and exports stay shared.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local native_default = require("wtop.native")

local M = {}

local sources = {
  cpu = {"collect_cpu", 500},
  cpu_info = {"collect_cpu_info", 30000},
  memory = {"collect_memory", 1000},
  pressure = {nil, 2000},
  disk = {"collect_disk", 1000},
  network = {"collect_network", 1000},
  connections = {"collect_connections", 2000},
  process = {"collect_process", 1000},
  gpu = {nil, 5000},
  cpufreq = {nil, 5000},
  hwmon = {nil, 5000},
  powercap = {nil, 5000},
  mounts = {"collect_mounts", 5000},
  cgroup = {nil, 10000},
  system_info = {"collect_system_info", 2000},
  power_supply = {nil, 15000},
}

local function previous_ok(previous)
  return previous and previous.status == "ok" and previous.data or nil
end

local function elapsed_since(previous, timestamp_ns)
  return previous_ok(previous) and previous.timestamp_ns
      and timestamp_ns - previous.timestamp_ns or nil
end

local function cpu_data(data, previous)
  local current = data.raw
  if type(current) ~= "table" then return nil, "missing CPU counters" end
  local old_data = previous_ok(previous)
  local old = old_data and old_data.raw or nil
  local used = old and Common.delta(current.busy, old.busy)
  local total = old and Common.delta(current.total, old.total)
  data.total = {
    utilization = used and total and total > 0
        and math.max(0, math.min(100, used * 100 / total)) or nil,
    quality = used and total and total > 0 and "fresh" or "gap",
  }
  local old_cores = {}
  for _, core in ipairs(old_data and old_data.cores or {}) do
    if core.name then old_cores[core.name] = core end
  end
  local any_gap = data.total.quality == "gap"
  for _, core in ipairs(data.cores or {}) do
    local raw = core.raw
    local old_core = old_cores[core.name]
    local old_raw = old_core and old_core.raw
    local core_used = raw and old_raw and Common.delta(raw.busy, old_raw.busy)
    local core_total = raw and old_raw and Common.delta(raw.total, old_raw.total)
    if core_used and core_total and core_total > 0 then
      core.utilization = math.max(0, math.min(100,
        core_used * 100 / core_total))
      core.quality = "fresh"
    else
      core.quality = "gap"
      any_gap = true
    end
  end
  data.cores = data.cores or {}
  return data, any_gap and "gap" or "fresh"
end

-- Nanoseconds from each platform's process start-time epoch to the Unix epoch.
local START_EPOCHS = {
  -- FILETIME: 100 ns ticks since 1601-01-01.
  filetime = { scale = 100, offset = 11644473600 * 1000000000 },
  -- proc_bsdinfo: microseconds since 1970-01-01.
  unix_us = { scale = 1000, offset = 0 },
}

local function process_age_seconds(process, epoch, realtime_ns)
  if not epoch or type(realtime_ns) ~= "number"
      or type(process.starttime_ticks) ~= "number" then return nil end
  local started_ns = process.starttime_ticks * epoch.scale - epoch.offset
  local age = (realtime_ns - started_ns) / 1000000000
  return age > 0.5 and age or nil
end

local function process_data(data, previous, timestamp_ns, realtime_ns)
  local old_by_id = previous_ok(previous) and previous_ok(previous).by_id or {}
  local elapsed_ns = elapsed_since(previous, timestamp_ns)
  local ticks_per_second = data.clock_ticks_per_second or 100
  local epoch = START_EPOCHS[data.starttime_unit]
  local by_id, by_pid = {}, {}
  local any_fresh, any_partial = false, false
  for _, process in ipairs(data.list or {}) do
    if not process.id and process.pid and process.starttime_ticks then
      process.id = tostring(process.pid) .. ":" .. tostring(process.starttime_ticks)
    end
    local old = old_by_id[process.id]
    local ticks = old and Common.delta(process.cpu_ticks, old.cpu_ticks)
    if ticks and elapsed_ns and elapsed_ns > 0 then
      process.cpu_percent = math.max(0,
        ticks / ticks_per_second / (elapsed_ns / 1000000000) * 100)
      process.quality = "fresh"
      any_fresh = true
    elseif not old and type(process.cpu_ticks) == "number" then
      -- Like the Linux collector, the first frame shows the lifetime average
      -- so a CPU-sorted table is meaningful before the second sample.
      local age = process_age_seconds(process, epoch, realtime_ns)
      if age then
        process.cpu_percent = math.max(0, process.cpu_ticks / ticks_per_second / age * 100)
        process.quality = "estimated"
      else
        process.quality = "gap"
      end
    else
      process.quality = "gap"
    end
    any_partial = any_partial or process.partial == true
    if process.id then by_id[process.id] = process end
    if process.pid then by_pid[process.pid] = process end
  end
  data.by_id = by_id
  data.by_pid = by_pid
  data.process_candidates = data.process_candidates or #(data.list or {})
  data.partial = data.truncated == true or (data.denied or 0) > 0 or any_partial
  local quality = data.partial and "partial" or (any_fresh and "fresh" or "gap")
  return data, quality
end

local function counter_delta(current, previous, bits)
  local delta = Common.delta(current, previous)
  if delta or not bits or type(current) ~= "number" or type(previous) ~= "number" then
    return delta
  end
  -- A 32-bit interface counter wraps every few seconds at gigabit speed.
  local modulus = 1 << bits
  if previous < modulus and current < previous then
    return current + modulus - previous
  end
  return nil
end

local function network_data(data, previous, timestamp_ns)
  local old_data = previous_ok(previous)
  local old_by_id = {}
  for _, interface in ipairs(old_data and old_data.interfaces or {}) do
    old_by_id[interface.id or interface.name] = interface
  end
  local elapsed_ns = elapsed_since(previous, timestamp_ns)
  local bits = data.counter_bits == 32 and 32 or nil
  local any_gap = false
  for _, interface in ipairs(data.interfaces or {}) do
    local counters = interface.counters or {}
    local old = old_by_id[interface.id or interface.name]
    local old_counters = old and old.counters or {}
    local function rate(key)
      if not elapsed_ns or elapsed_ns <= 0 then return nil end
      local delta = counter_delta(counters[key], old_counters[key], bits)
      return delta and (delta + 0.0) * 1e9 / elapsed_ns or nil
    end
    local rx, tx = rate("rx_bytes"), rate("tx_bytes")
    interface.rates = {rx_bytes_per_second = rx, tx_bytes_per_second = tx}
    interface.rx_bytes_per_second = rx
    interface.tx_bytes_per_second = tx
    interface.quality = rx and tx and "fresh" or "gap"
    any_gap = any_gap or interface.quality == "gap"
  end
  return data, any_gap and "gap" or "fresh"
end

local function disk_data(data, previous, timestamp_ns)
  local old_data = previous_ok(previous)
  local old_by_id = {}
  for _, device in ipairs(old_data and old_data.devices or {}) do
    if device.id then old_by_id[device.id] = device end
  end
  local elapsed_ns = elapsed_since(previous, timestamp_ns)
  local any_gap = false
  for _, device in ipairs(data.devices or {}) do
    local counters = device.counters
    local old = old_by_id[device.id]
    local old_counters = old and old.counters
    device.quality = "gap"
    if counters and old_counters and elapsed_ns and elapsed_ns > 0 then
      local function delta(key) return Common.delta(counters[key], old_counters[key]) end
      local read_bytes, written_bytes = delta("bytes_read"), delta("bytes_written")
      local reads, writes = delta("reads"), delta("writes")
      if read_bytes and written_bytes and reads and writes then
        local seconds = elapsed_ns / 1000000000
        device.read_bytes_per_second = (read_bytes + 0.0) / seconds
        device.write_bytes_per_second = (written_bytes + 0.0) / seconds
        device.read_iops = reads / seconds
        device.write_iops = writes / seconds
        local read_ns, write_ns = delta("read_time_ns"), delta("write_time_ns")
        if read_ns and reads > 0 then device.average_read_latency_ms = read_ns / reads / 1e6 end
        if write_ns and writes > 0 then device.average_write_latency_ms = write_ns / writes / 1e6 end
        -- Windows accumulates idle time on a precise clock, while its query
        -- timestamp moves in 15.6 ms ticks; dividing by that tick-rounded
        -- interval shows an idle disk as several percent busy. The monotonic
        -- sampling interval is the accurate denominator.
        local idle_ns = delta("idle_time_ns")
        if idle_ns then
          device.busy_percent = math.max(0, math.min(100, 100 - idle_ns * 100 / elapsed_ns))
        end
        device.quality = "fresh"
      else
        device.reset_reason = "counter_reset"
      end
    end
    if device.quality == "gap" then any_gap = true end
  end
  return data, any_gap and "gap" or "fresh"
end

-- RFC 5952 text: lowercase, no leading zeros, longest zero run compressed.
function M.format_ipv6(bytes)
  if type(bytes) ~= "string" or #bytes ~= 16 then return nil end
  local groups = {}
  for index = 1, 15, 2 do
    groups[#groups + 1] = bytes:byte(index) * 256 + bytes:byte(index + 1)
  end
  local best_start, best_length = nil, 1
  local index = 1
  while index <= 8 do
    if groups[index] == 0 then
      local stop = index
      while stop <= 8 and groups[stop] == 0 do stop = stop + 1 end
      if stop - index > best_length then best_start, best_length = index, stop - index end
      index = stop
    else
      index = index + 1
    end
  end
  local function hex(first, last)
    local parts = {}
    for position = first, last do parts[#parts + 1] = string.format("%x", groups[position]) end
    return table.concat(parts, ":")
  end
  if not best_start then return hex(1, 8) end
  return hex(1, best_start - 1) .. "::" .. hex(best_start + best_length, 8)
end

-- MIB_TCP_STATE values mapped onto the /proc/net/tcp codes the ViewModel,
-- ordering, and exported IDs already use.
local WINDOWS_TCP_STATES = {
  [1] = {"07", "CLOSE"}, [2] = {"0A", "LISTEN"}, [3] = {"02", "SYN_SENT"},
  [4] = {"03", "SYN_RECV"}, [5] = {"01", "ESTABLISHED"}, [6] = {"04", "FIN_WAIT1"},
  [7] = {"05", "FIN_WAIT2"}, [8] = {"08", "CLOSE_WAIT"}, [9] = {"0B", "CLOSING"},
  [10] = {"09", "LAST_ACK"}, [11] = {"06", "TIME_WAIT"}, [12] = {"07", "CLOSE"},
}
M.WINDOWS_TCP_STATES = WINDOWS_TCP_STATES

local TABLE_RANK = { tcp = 1, tcp6 = 2, udp = 3, udp6 = 4 }

local function endpoint(family, address, port)
  if type(address) ~= "string" or type(port) ~= "number" then return nil end
  return {
    family = family,
    address = address,
    port = port,
    text = family == "ipv6" and ("[" .. address .. "]:" .. tostring(port))
      or (address .. ":" .. tostring(port)),
  }
end

local function connection_order(left, right)
  local left_rank, right_rank = TABLE_RANK[left.table] or 9, TABLE_RANK[right.table] or 9
  if left_rank ~= right_rank then return left_rank < right_rank end
  if left.local_endpoint.text ~= right.local_endpoint.text then
    return left.local_endpoint.text < right.local_endpoint.text
  end
  if left.remote_endpoint.text ~= right.remote_endpoint.text then
    return left.remote_endpoint.text < right.remote_endpoint.text
  end
  if left.state_code ~= right.state_code then return left.state_code < right.state_code end
  return (left.owners[1] and left.owners[1].pid or 0) < (right.owners[1] and right.owners[1].pid or 0)
end

local function connections_data(data)
  local connections = {}
  local counts = { tcp = 0, tcp6 = 0, udp = 0, udp6 = 0 }
  local owners_available = data.owners_available == true
  local invalid = 0
  for _, raw in ipairs(data.connections or {}) do
    local family = raw.family == "ipv6" and "ipv6" or "ipv4"
    local unspecified = family == "ipv6" and "::" or "0.0.0.0"
    local local_address = family == "ipv6" and M.format_ipv6(raw.local_address_bytes)
      or raw.local_address
    local remote_address = family == "ipv6" and M.format_ipv6(raw.remote_address_bytes)
      or raw.remote_address or unspecified
    local local_endpoint = endpoint(family, local_address, raw.local_port)
    local remote_endpoint = endpoint(family, remote_address, raw.remote_port or 0)
    local protocol = raw.protocol == "udp" and "udp" or "tcp"
    if local_endpoint and remote_endpoint then
      local table_name = protocol .. (family == "ipv6" and "6" or "")
      local state = protocol == "tcp" and WINDOWS_TCP_STATES[raw.tcp_state] or nil
      local state_code = state and state[1] or "07"
      local connection = {
        protocol = protocol,
        family = family,
        table = table_name,
        local_endpoint = local_endpoint,
        remote_endpoint = remote_endpoint,
        local_address = local_endpoint.address,
        local_port = local_endpoint.port,
        remote_address = remote_endpoint.address,
        remote_port = remote_endpoint.port,
        state_code = state_code,
        state = state and state[2] or (protocol == "tcp"
          and ("UNKNOWN_" .. tostring(raw.tcp_state)) or "CLOSE"),
        owners = {},
        owners_quality = owners_available and "fresh" or "unavailable",
      }
      if raw.pid then
        connection.owners[1] = { pid = raw.pid, name = raw.owner_name }
      end
      connection.owner_count = #connection.owners
      connection.base_id = table.concat({
        table_name, local_endpoint.text, remote_endpoint.text, state_code,
      }, ":")
      counts[table_name] = counts[table_name] + 1
      connections[#connections + 1] = connection
    else
      invalid = invalid + 1
    end
  end
  table.sort(connections, connection_order)
  local seen, by_id = {}, {}
  for _, connection in ipairs(connections) do
    local count = (seen[connection.base_id] or 0) + 1
    seen[connection.base_id] = count
    connection.id = count == 1 and connection.base_id
      or (connection.base_id .. "#" .. tostring(count))
    by_id[connection.id] = connection
  end
  local partial = data.truncated == true or invalid > 0
    or data.ipv6_unavailable == true
  return {
    connections = connections,
    by_id = by_id,
    counts = counts,
    total = #connections,
    partial = partial,
    owner_scan = {
      enabled = owners_available,
      status = owners_available and "ok" or "unavailable",
      partial = false,
    },
  }, partial and "partial" or "fresh"
end

local function new_collector(id, description, options)
  options = options or {}
  local native = options.native or native_default
  local method, default_interval_ms = description[1], description[2]
  local collector = {
    id = id,
    default_interval_ms = default_interval_ms,
    native = native,
    method = method,
    _method_style = true,
  }
  function collector:probe()
    if self.method and type(self.native[self.method]) == "function" then
      return Capability.available({source = "native:" .. self.method})
    end
    return Capability.unavailable("unsupported_on_this_platform")
  end
  function collector:sample(context, previous)
    local timestamp_ns = Common.now_ns(context)
    if not self.method or type(self.native[self.method]) ~= "function" then
      return Common.result("unavailable", timestamp_ns, nil, {
        reason = "unsupported_on_this_platform",
      })
    end
    local called, data, reason = pcall(self.native[self.method])
    if not called or type(data) ~= "table" then
      return Common.result("unavailable", timestamp_ns, nil, {
        reason = tostring(called and reason or data or "native_collection_failed"),
      })
    end
    local quality = "fresh"
    if id == "cpu" then
      data, quality = cpu_data(data, previous)
      if not data then
        return Common.result("error", timestamp_ns, nil, {reason = quality})
      end
    elseif id == "process" then
      local realtime_ok, realtime_ns = false, nil
      if type(self.native.realtime_ns) == "function" then
        realtime_ok, realtime_ns = pcall(self.native.realtime_ns)
      end
      data, quality = process_data(data, previous, timestamp_ns,
        realtime_ok and realtime_ns or nil)
    elseif id == "network" then
      data, quality = network_data(data, previous, timestamp_ns)
    elseif id == "disk" then
      data, quality = disk_data(data, previous, timestamp_ns)
    elseif id == "connections" then
      data, quality = connections_data(data)
    end
    return Common.result("ok", timestamp_ns, data, {
      quality = quality,
      source = "native:" .. self.method,
    })
  end
  return collector
end

function M.new_all(options)
  options = options or {}
  local result = {}
  for id, description in pairs(sources) do
    result[id] = new_collector(id, description, options[id] or options.common)
  end
  return result
end

return M
