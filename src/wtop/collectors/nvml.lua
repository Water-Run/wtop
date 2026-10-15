-- NVIDIA Management Library data joined onto DRM devices by PCI address.
--
-- The proprietary driver exposes little through DRM sysfs and nothing
-- through fdinfo, so NVML supplies utilization, memory, clocks, sensors and
-- per-process usage. A value DRM already measured keeps precedence; NVML
-- only fills what is missing. A GPU without a DRM node (a headless compute
-- card without nvidia-drm) becomes its own device entry.
local Limits = require("wtop.collectors.gpu_limits")
local M = {}

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function text(value, limit)
  if type(value) ~= "string" or value == "" then return nil end
  value = value:gsub("[%c]", "")
  if #value > (limit or 128) then value = value:sub(1, limit or 128) end
  return value
end

-- NVML prints the domain with eight digits; sysfs uses four.
function M.normalize_bdf(value)
  if type(value) ~= "string" then return nil end
  local domain, bus, device, func = value:lower():match(
    "^(%x+):(%x%x):(%x%x)%.(%x)$")
  if not domain then return nil end
  local domain_number = tonumber(domain, 16)
  if not domain_number or domain_number > 0xffff then return nil end
  if tonumber(device, 16) > 0x1f or tonumber(func, 16) > 7 then return nil end
  return string.format("%04x:%s:%s.%s", domain_number, bus, device, func)
end

function M.default_provider()
  local ok, native = pcall(require, "wtop.native")
  if not ok or type(native) ~= "table" or type(native.nvml_worker_open) ~= "function"
      or type(native.nvml_worker_query) ~= "function" or type(native.nvml_worker_close) ~= "function" then
    return nil
  end
  local session, closed
  local function query(include_processes)
    if closed then return nil, "nvml_worker_closed" end
    if not session then
      local created, value = pcall(native.nvml_worker_open)
      if not created then return nil, "nvml_allocation_failed" end
      if not value then return nil, "nvml_worker_unavailable" end
      session = value
    end
    local called, data, reason = pcall(native.nvml_worker_query, session, include_processes == true)
    if not called then return nil, "nvml_query_failed" end
    if type(data) == "table" then
      local read, realtime = pcall(native.realtime_ns)
      if read and type(realtime) == "number" then M.refresh_power(data, realtime / 1000) end
    end
    return data, reason
  end
  return query, function()
    closed = true
    if session then return native.nvml_worker_close(session) end
    return true
  end
end

-- A response can wait for the next collector tick. Re-evaluate SDK UTC field
-- timestamps at delivery, including the preference for a fresh averaged field
-- over an older instantaneous one. Cached data cannot reset its own age.
function M.refresh_power(data, realtime_us)
  for _, device in ipairs(data.devices or {}) do
    if device.power_measurement ~= "device_sample" then
      local function freshness(kind)
        if not finite_number(device["power_" .. kind .. "_watts"]) then return nil end
        local timestamp = device["power_" .. kind .. "_timestamp_us"]
        if not finite_number(timestamp) or timestamp <= 0 then return "gap" end
        local age = realtime_us - timestamp
        return age < -1000000 and "gap" or age > 5000000 and "stale" or "fresh"
      end
      local instant, average = freshness("instant"), freshness("average")
      device.power_instant_quality, device.power_average_quality = instant, average
      if instant or average then
        local use_instant = instant and (not average or instant == "fresh" or average ~= "fresh")
        device.power_watts = use_instant and device.power_instant_watts or device.power_average_watts
        device.power_quality = use_instant and instant or average
        device.power_measurement = use_instant and "current" or "average"
        device.power_interval_ns = not use_instant and 1000000000 or nil
      end
    end
  end
end

-- Returns the provider result, or nil and a reason, without raising.
function M.query(provider, include_processes)
  if type(provider) ~= "function" then return nil, "nvml_provider_unavailable" end
  local called, data, reason = pcall(provider, include_processes)
  if not called then return nil, "nvml_query_failed" end
  if type(data) ~= "table" or type(data.devices) ~= "table" then
    return nil, type(reason) == "string" and reason or "nvml_unavailable"
  end
  return data
end

local function set_missing(metrics, key, value)
  if metrics[key] == nil and finite_number(value) then
    metrics[key] = value
    return true
  end
  return false
end

local function new_device(entry, bdf, used_ids)
  local id = bdf or ("nvml:" .. tostring(text(entry.uuid, 96) or entry.index or "?"))
  while used_ids[id] do id = id .. "+" end
  used_ids[id] = true
  return {
    id = id,
    card = "nvml" .. tostring(entry.index or 0),
    pci_bdf = bdf,
    stable_id = bdf or id,
    vendor_id = text(entry.vendor_id, 16),
    device_id = text(entry.device_id, 16),
    vendor = text(entry.vendor_id, 16),
    vendor_name = "NVIDIA",
    driver = "nvidia",
    identity_quality = bdf and "fresh" or "estimated",
    drm_nodes = {},
    render_nodes = {},
    metrics = {},
    frequencies = {},
    hwmon_refs = {},
    capabilities = {},
    quality = {},
    issues = {},
    partial = false,
    source = "nvml",
    processes = {
      list = {}, by_id = {}, clients = {}, clients_by_id = {},
      summary = { process_count = 0, client_count = 0 },
    },
  }
end

local function process_rows(device, entry, process_name)
  local processes = device.processes
  if type(processes) ~= "table" then
    processes = {
      list = {}, by_id = {}, clients = {}, clients_by_id = {},
      summary = { process_count = 0, client_count = 0 },
    }
    device.processes = processes
  end
  -- DRM fdinfo, where the driver provides it, is the richer source.
  if #(processes.list or {}) > 0 then return 0 end
  local added = 0
  for _, row in ipairs(entry.processes or {}) do
    if type(row) == "table" and type(row.pid) == "number" and row.pid > 0 then
      local engines = {}
      if finite_number(row.sm_percent) then engines.sm = { utilization_percent = row.sm_percent } end
      if finite_number(row.encoder_percent) and row.encoder_percent > 0 then
        engines.encoder = { utilization_percent = row.encoder_percent }
      end
      if finite_number(row.decoder_percent) and row.decoder_percent > 0 then
        engines.decoder = { utilization_percent = row.decoder_percent }
      end
      local contexts = {}
      for _, entry in ipairs(row.memory_contexts or {}) do
        if #contexts >= 512 then break end
        if type(entry) == "table" then
          contexts[#contexts + 1] = {
            gpu_instance_id = finite_number(entry.gpu_instance_id) and entry.gpu_instance_id or nil,
            compute_instance_id = finite_number(entry.compute_instance_id) and entry.compute_instance_id or nil,
            memory_bytes = finite_number(entry.memory_bytes) and entry.memory_bytes >= 0 and entry.memory_bytes or nil,
            kind = text(entry.kind, 32),
          }
        end
      end
      local process = {
        id = "nvml:" .. tostring(row.pid),
        pid = row.pid,
        name = process_name and process_name(row.pid) or nil,
        kind = text(row.kind, 16),
        utilization_percent = finite_number(row.sm_percent) and row.sm_percent or nil,
        memory_summary = finite_number(row.memory_bytes)
          and { resident_bytes = row.memory_bytes, quality = text(row.memory_quality, 16),
            scope = text(row.memory_scope, 40) } or {},
        memory_contexts = contexts,
        engines = engines,
        quality = (row.sample_window == "driver_buffer" or row.memory_quality == "estimated")
          and "estimated" or "fresh",
        sample_timestamp_us = finite_number(row.sample_timestamp_us) and row.sample_timestamp_us >= 0
          and row.sample_timestamp_us or nil,
        sample_window = text(row.sample_window, 32),
        source = "nvml",
      }
      processes.list[#processes.list + 1] = process
      processes.by_id[process.id] = process
      added = added + 1
    end
  end
  processes.summary = processes.summary or {}
  processes.summary.process_count = #processes.list
  if entry.processes_truncated == true then
    processes.truncated = true
    processes.quality = "truncated"
  end
  if added > 0 then
    processes.source = "nvml"
    processes.quality = entry.processes_truncated and "truncated" or "fresh"
    processes.truncated = entry.processes_truncated == true
    device.capabilities = device.capabilities or {}
    device.capabilities.processes = true
  end
  return added
end

-- devices/lookup/used_ids are the GPU collector's working set.
function M.merge(devices, lookup, data, options)
  options = options or {}
  local merged, added = 0, 0
  for _, entry in ipairs(data.devices or {}) do
    if type(entry) == "table" then
      local bdf = M.normalize_bdf(entry.pci_bdf)
      local device = bdf and lookup.by_bdf[bdf] or nil
      if not device then
        device = new_device(entry, bdf, options.used_ids or {})
        devices[#devices + 1] = device
        if bdf then lookup.by_bdf[bdf] = device end
        added = added + 1
      else
        merged = merged + 1
      end
      device.vendor_uuid = text(entry.uuid, 96) or device.vendor_uuid
      device.driver_version = text(data.driver_version, 32) or device.driver_version
      device.nvml_index = entry.index
      device.nvml_name = text(entry.name, 96)
      if not device.model_name then device.model_name = device.nvml_name end
      device.metrics = device.metrics or {}
      local metrics = device.metrics
      if set_missing(metrics, "utilization_percent", entry.utilization_percent) then
        metrics.utilization_source = "nvml"
      end
      set_missing(metrics, "memory_busy_percent", entry.memory_utilization_percent)
      set_missing(metrics, "memory_total_bytes", entry.memory_total_bytes)
      set_missing(metrics, "memory_used_bytes", entry.memory_used_bytes)
      set_missing(metrics, "temperature_celsius", entry.temperature_celsius)
      if finite_number(entry.power_watts) and entry.power_watts >= 0
          and set_missing(metrics, "power_watts", entry.power_watts) then
        metrics.power_source = "nvml"
        device.quality = type(device.quality) == "table" and device.quality or {}
        device.capabilities = device.capabilities or {}
        local power_quality = entry.power_quality
        if power_quality ~= "fresh" and power_quality ~= "stale" and power_quality ~= "gap" then
          power_quality = power_quality == nil and "fresh" or "error"
        end
        device.quality.power, device.capabilities.power = power_quality, true
        for _, key in ipairs({ "power_instant_quality", "power_average_quality" }) do
          if entry[key] == "fresh" or entry[key] == "stale" or entry[key] == "gap" then metrics[key] = entry[key] end
        end
        if entry.power_measurement == "current" or entry.power_measurement == "average"
            or entry.power_measurement == "device_sample" then
          metrics.power_measurement = entry.power_measurement
        end
        for _, key in ipairs({ "power_instant_watts", "power_average_watts", "power_interval_ns",
            "power_average_interval_ns", "power_instant_timestamp_us", "power_average_timestamp_us" }) do
          if finite_number(entry[key]) and entry[key] >= 0 then metrics[key] = entry[key] end
        end
      end
      if finite_number(entry.power_limit_watts) and entry.power_limit_watts > 0
          and set_missing(metrics, "power_limit_watts", entry.power_limit_watts) then
        metrics.power_limit_source = "nvml"
      end
      set_missing(metrics, "frequency_current_hz", entry.graphics_clock_hz)
      set_missing(metrics, "frequency_graphics_hz", entry.graphics_clock_hz)
      set_missing(metrics, "frequency_maximum_hz", entry.graphics_clock_maximum_hz)
      set_missing(metrics, "frequency_memory_hz", entry.memory_clock_hz)
      set_missing(metrics, "fan_speed_percent", entry.fan_speed_percent)
      if metrics.performance_state == nil then
        metrics.performance_state = text(entry.performance_state, 8)
      end
      device.capabilities = device.capabilities or {}
      device.capabilities.nvml = true
      local domain = Limits.nvml(entry.clock_events, data.sample_started_ns or options.now_ns)
      if domain then
        device.performance_limits = device.performance_limits or { domains = {} }
        device.performance_limits.domains = device.performance_limits.domains or {}
        device.performance_limits.domains[#device.performance_limits.domains + 1] = domain
        device.quality = type(device.quality) == "table" and device.quality or {}
        device.quality.performance_limits = domain.quality
        device.capabilities.performance_limits = domain.active ~= nil
      end
      if options.include_processes then
        process_rows(device, entry, options.process_name)
      end
    end
  end
  return {
    status = (data.status == "partial" or data.truncated == true) and "partial" or "ok",
    reason = text(data.reason, 96),
    truncated = data.truncated == true,
    source = "nvml",
    transport = text(data.transport, 32),
    sample_started_ns = data.sample_started_ns,
    sample_finished_ns = data.sample_finished_ns,
    driver_version = text(data.driver_version, 32),
    device_count = #(data.devices or {}),
    merged_devices = merged,
    added_devices = added,
  }
end

return M
