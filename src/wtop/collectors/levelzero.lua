-- Level Zero data joined onto DRM devices.
--
-- i915 sysfs exposes no edge temperature and no package power, so on Intel
-- hardware Level Zero is the only source for both. Identity and per-process
-- usage stay with the DRM and fdinfo paths; this provider fills the counters
-- the kernel does not publish.
--
-- Devices are matched by enumeration order rather than by bus address. Level
-- Zero only reports a bus address through ze_device_properties_t, a
-- versioned structure this build does not read, so the join is positional and
-- every device it contributes is marked with an estimated identity. A host
-- whose DRM enumeration and Level Zero enumeration disagree in length is
-- reported partial rather than silently cross-wired.
local M = {}

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function set_missing(metrics, key, value)
  if metrics[key] == nil and finite_number(value) then
    metrics[key] = value
    return true
  end
  return false
end

function M.default_provider()
  local ok, native = pcall(require, "wtop.native")
  if not ok or type(native) ~= "table" or type(native.levelzero_query) ~= "function" then
    return nil
  end
  return function(include_processes)
    local called, data, reason = pcall(native.levelzero_query, include_processes == true)
    if not called then return nil, "levelzero_query_failed" end
    return data, reason
  end
end

-- Returns the provider result, or nil and a reason, without raising.
function M.query(provider)
  if type(provider) ~= "function" then return nil, "levelzero_provider_unavailable" end
  local called, data, reason = pcall(provider, false)
  if not called then return nil, "levelzero_query_failed" end
  if type(data) ~= "table" or type(data.devices) ~= "table" then
    return nil, type(reason) == "string" and reason or "levelzero_unavailable"
  end
  return data
end

local function new_device(entry, index, used_ids)
  local id = "levelzero:" .. tostring(index)
  while used_ids[id] do id = id .. "+" end
  used_ids[id] = true
  return {
    id = id,
    card = "ze" .. tostring(index),
    stable_id = id,
    vendor = "i915",
    vendor_name = "Intel",
    driver = "i915",
    -- No bus address was read, so nothing about this identity is confirmed.
    identity_quality = "estimated",
    drm_nodes = {},
    render_nodes = {},
    metrics = {},
    frequencies = {},
    hwmon_refs = {},
    capabilities = {},
    quality = { identity = "estimated" },
    issues = {},
    partial = true,
    source = "levelzero",
    processes = {
      list = {}, by_id = {}, clients = {}, clients_by_id = {},
      summary = { process_count = 0, client_count = 0 },
    },
  }
end

-- drm_order is the DRM enumeration for the same page, in the order i915
-- exposed the cards. devices/lookup/used_ids are the collector's working set.
function M.merge(devices, data, drm_order, options)
  options = options or {}
  local entries = data.devices or {}
  local merged, added, unmatched = 0, 0, 0
  for index, entry in ipairs(entries) do
    if type(entry) == "table" then
      local target = drm_order and drm_order[index] or nil
      local device = target
      if not device then
        device = new_device(entry, index, options.used_ids or {})
        devices[#devices + 1] = device
        added = added + 1
        unmatched = unmatched + 1
      else
        merged = merged + 1
      end
      device.levelzero_index = entry.index or (index - 1)
      device.metrics = device.metrics or {}
      local metrics = device.metrics
      set_missing(metrics, "temperature_celsius", entry.temperature_celsius)
      set_missing(metrics, "frequency_current_hz", entry.graphics_clock_hz)
      set_missing(metrics, "frequency_graphics_hz", entry.graphics_clock_hz)
      set_missing(metrics, "frequency_memory_hz", entry.memory_clock_hz)
      -- Package power is a Level Zero measurement on Intel hardware, where
      -- sysfs has no equivalent; it is kept separate from the per-socket
      -- power figure so a panel can say which one it is showing.
      if set_missing(metrics, "board_power_watts", entry.board_power_watts) then
        metrics.board_power_source = "levelzero"
      end
      device.capabilities = device.capabilities or {}
      device.capabilities.levelzero = true
      if entry.board_power_watts == nil and entry.temperature_celsius == nil then
        device.partial = true
        device.quality = device.quality or {}
        device.quality.identity = device.quality.identity or "partial"
      end
    end
  end
  return {
    status = unmatched > 0 and "partial" or "ok",
    source = "levelzero",
    driver_count = data.driver_count,
    device_count = #entries,
    merged_devices = merged,
    added_devices = added,
    unmatched_devices = unmatched,
  }
end

return M
