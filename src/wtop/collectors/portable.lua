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
  connections = {nil, 2000},
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

local function cpu_data(data, previous)
  local current = data.raw
  if type(current) ~= "table" then return nil, "missing CPU counters" end
  local old_data = previous and previous.status == "ok" and previous.data or nil
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

local function process_data(data, previous, timestamp_ns)
  local old_data = previous and previous.status == "ok" and previous.data or nil
  local old_by_id = {}
  for _, process in ipairs(old_data and old_data.list or {}) do
    if process.id then old_by_id[process.id] = process end
  end
  local elapsed_ns = old_data and previous.timestamp_ns
      and timestamp_ns - previous.timestamp_ns or nil
  for _, process in ipairs(data.list or {}) do
    if not process.id and process.pid and process.starttime_ticks then
      process.id = tostring(process.pid) .. ":" .. tostring(process.starttime_ticks)
    end
    local old = old_by_id[process.id]
    local ticks = old and Common.delta(process.cpu_ticks, old.cpu_ticks)
    if ticks and elapsed_ns and elapsed_ns > 0 then
      process.cpu_percent = math.max(0,
        ticks / (data.clock_ticks_per_second or 100)
          / (elapsed_ns / 1000000000) * 100)
      process.quality = "fresh"
    else
      process.quality = "gap"
    end
  end
  data.process_candidates = data.process_candidates or #(data.list or {})
  return data
end

local function network_data(data, previous, timestamp_ns)
  local old_data = previous and previous.status == "ok" and previous.data or nil
  local old_by_id = {}
  for _, interface in ipairs(old_data and old_data.interfaces or {}) do
    old_by_id[interface.id or interface.name] = interface
  end
  local elapsed_ns = old_data and previous.timestamp_ns
      and timestamp_ns - previous.timestamp_ns or nil
  for _, interface in ipairs(data.interfaces or {}) do
    local counters = interface.counters or {}
    local old = old_by_id[interface.id or interface.name]
    local old_counters = old and old.counters or {}
    local rx = elapsed_ns and Common.rate(counters.rx_bytes, old_counters.rx_bytes, elapsed_ns)
    local tx = elapsed_ns and Common.rate(counters.tx_bytes, old_counters.tx_bytes, elapsed_ns)
    interface.rates = {rx_bytes_per_second = rx, tx_bytes_per_second = tx}
    interface.rx_bytes_per_second = rx
    interface.tx_bytes_per_second = tx
  end
  return data
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
      data = process_data(data, previous, timestamp_ns)
    elseif id == "network" then
      data = network_data(data, previous, timestamp_ns)
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
