-- NVIDIA Management Library data joined onto DRM devices by PCI address.
--
-- The proprietary driver exposes little through DRM sysfs and nothing
-- through fdinfo, so NVML supplies utilization, memory, clocks, sensors and
-- per-process usage. A value DRM already measured keeps precedence; NVML
-- only fills what is missing. A GPU without a DRM node (a headless compute
-- card without nvidia-drm) becomes its own device entry.
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
  return string.format("%04x:%s:%s.%s", domain_number, bus, device, func)
end

function M.default_provider()
  local ok, native = pcall(require, "wtop.native")
  if not ok or type(native) ~= "table" or type(native.nvml_query) ~= "function" then
    return nil
  end
  return function(include_processes)
    local called, data, reason = pcall(native.nvml_query, include_processes == true)
    if not called then return nil, "nvml_query_failed" end
    return data, reason
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
      local process = {
        id = "nvml:" .. tostring(row.pid),
        pid = row.pid,
        name = process_name and process_name(row.pid) or nil,
        kind = text(row.kind, 16),
        utilization_percent = finite_number(row.sm_percent) and row.sm_percent or nil,
        memory_summary = finite_number(row.memory_bytes)
          and { resident_bytes = row.memory_bytes } or {},
        engines = engines,
        quality = "fresh",
        source = "nvml",
      }
      processes.list[#processes.list + 1] = process
      processes.by_id[process.id] = process
      added = added + 1
    end
  end
  processes.summary = processes.summary or {}
  processes.summary.process_count = #processes.list
  if added > 0 then
    processes.source = "nvml"
    processes.quality = "fresh"
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
      set_missing(metrics, "power_watts", entry.power_watts)
      set_missing(metrics, "power_limit_watts", entry.power_limit_watts)
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
      if options.include_processes then
        process_rows(device, entry, options.process_name)
      end
    end
  end
  return {
    status = "ok",
    source = "nvml",
    driver_version = text(data.driver_version, 32),
    device_count = #(data.devices or {}),
    merged_devices = merged,
    added_devices = added,
  }
end

return M
