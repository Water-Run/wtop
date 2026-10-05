-- AMD System Management Interface data joined onto DRM devices by PCI address.
--
-- amdgpu's DRM sysfs exposes identity and a little power state, and its
-- per-process fdinfo is the richer source for process usage, so amdsmi is
-- consulted for the counters the kernel does not publish: graphics and memory
-- controller activity, VRAM totals, edge temperature, socket power, clocks and
-- fan speed. A value DRM already measured keeps precedence; amdsmi only fills
-- what is missing. A GPU without a DRM node becomes its own device entry, the
-- same way a headless NVIDIA card does.
--
-- amdsmi has no process enumeration, so unlike NVML this provider never
-- contributes process rows.
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

-- The native layer already renders a BDF string; this accepts it and drops
-- anything that is not a complete domain:bus:device.function so a malformed
-- value cannot silently fail to join and instead create a duplicate device.
function M.normalize_bdf(value)
  if type(value) ~= "string" then return nil end
  local domain, bus, device, func = value:lower():match(
    "^(%x+):(%x%x):(%x%x)%.(%x)$")
  if not domain then return nil end
  local domain_number = tonumber(domain, 16)
  local bus_number = tonumber(bus, 16)
  local device_number = tonumber(device, 16)
  local function_number = tonumber(func, 16)
  if not domain_number or domain_number > 0xffff then return nil end
  if not bus_number or bus_number > 0xff then return nil end
  if not device_number or device_number > 0x1f then return nil end
  if not function_number or function_number > 0x7 then return nil end
  return string.format("%04x:%02x:%02x.%x", domain_number, bus_number,
    device_number, function_number)
end

function M.default_provider()
  local ok, native = pcall(require, "wtop.native")
  if not ok or type(native) ~= "table" or type(native.amdsmi_query) ~= "function" then
    return nil
  end
  return function(include_processes)
    -- include_processes is accepted for symmetry with NVML and ignored:
    -- amdsmi exposes no process enumeration.
    local called, data, reason = pcall(native.amdsmi_query, include_processes == true)
    if not called then return nil, "amdsmi_query_failed" end
    return data, reason
  end
end

-- Returns the provider result, or nil and a reason, without raising.
function M.query(provider, include_processes)
  if type(provider) ~= "function" then return nil, "amdsmi_provider_unavailable" end
  local called, data, reason = pcall(provider, include_processes)
  if not called then return nil, "amdsmi_query_failed" end
  if type(data) ~= "table" or type(data.devices) ~= "table" then
    return nil, type(reason) == "string" and reason or "amdsmi_unavailable"
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
  local id = bdf or ("amdsmi:" .. tostring(text(entry.uuid, 96) or entry.index or "?"))
  while used_ids[id] do id = id .. "+" end
  used_ids[id] = true
  return {
    id = id,
    card = "amdsmi" .. tostring(entry.index or 0),
    pci_bdf = bdf,
    stable_id = bdf or id,
    vendor = "amdgpu",
    vendor_name = "AMD",
    driver = "amdgpu",
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
    source = "amdsmi",
    processes = {
      list = {}, by_id = {}, clients = {}, clients_by_id = {},
      summary = { process_count = 0, client_count = 0 },
    },
  }
end

-- devices/lookup/used_ids are the GPU collector's working set.
function M.merge(devices, lookup, data, options)
  options = options or {}
  local merged, added, incomplete = 0, 0, 0
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
      device.amdsmi_index = entry.index
      device.amdsmi_name = text(entry.name, 96)
      if not device.model_name then device.model_name = device.amdsmi_name end
      device.metrics = device.metrics or {}
      local metrics = device.metrics
      if set_missing(metrics, "utilization_percent", entry.utilization_percent) then
        metrics.utilization_source = "amdsmi"
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
      device.capabilities = device.capabilities or {}
      device.capabilities.amdsmi = true
      -- A device amdsmi listed but could not describe is a real gap, and
      -- saying so keeps a partially-read card from looking like a healthy one.
      if entry.name == nil and entry.pci_bdf == nil then
        incomplete = incomplete + 1
        device.partial = true
        device.quality = device.quality or {}
        device.quality.identity = "partial"
      end
    end
  end
  return {
    status = incomplete > 0 and "partial" or "ok",
    source = "amdsmi",
    driver_version = text(data.driver_version, 32),
    device_count = #(data.devices or {}),
    merged_devices = merged,
    added_devices = added,
    incomplete_devices = incomplete,
  }
end

return M
