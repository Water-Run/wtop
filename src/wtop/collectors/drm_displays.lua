-- Read the kernel's cached DRM connector attributes. No DDC/I2C transaction,
-- forced detect, modeset, debugfs or EDID override is requested here.
local Common = require("wtop.collectors.common")
local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local EDID = require("wtop.format.edid")
local CurrentMode = require("wtop.collectors.drm_current_mode")
local Native = require("wtop.native")
local M = {}
M.__index = M
local MAX_CONNECTORS, MAX_ENTRIES, MAX_MODES = 128, 1024, 128

local function text(fs, path)
  local value, failure = fs:read(path, 256)
  return type(value) == "string" and Common.trim(value) or nil, failure
end

local function link(fs, path)
  if type(fs.readlink) ~= "function" then return nil end
  local value = fs:readlink(path)
  return type(value) == "string" and #value <= 4096 and value or nil
end

local function connector(fs, base, name, card, port, context, native)
  local path = base .. "/" .. name
  local target = link(fs, path)
  local card_target = link(fs, base .. "/" .. card .. "/device")
  local status, failure = text(fs, path .. "/status")
  local identity = text(fs, path .. "/connector_id")
  local device = { id = name, card = card, connector = port, source = path, quality = "fresh", backend = "drm-sysfs" }
  local function issue(reason)
    device.quality = "partial"
    device.reason = device.reason or reason
  end
  if status == "connected" or status == "disconnected" or status == "unknown" then
    device.connection = status
  else issue(status and "display_invalid_state" or "display_state_unavailable") end
  if not status then device.status = FS.error_status(failure) end
  local id = identity and tonumber(identity)
  if id and math.type(id) == "integer" and id > 0 and id <= 0xffffffff then device.connector_id = id end
  local enabled = text(fs, path .. "/enabled")
  if enabled == "enabled" then device.enabled = true
  elseif enabled == "disabled" then device.enabled = false end
  local dpms = text(fs, path .. "/dpms")
  if dpms == "On" or dpms == "Standby" or dpms == "Suspend" or dpms == "Off" then device.dpms = dpms end
  local raw, edid_failure = fs:read(path .. "/edid", 32768)
  if type(raw) == "string" and #raw > 0 and device.connection ~= "disconnected" then
    device.edid, device.edid_reason = EDID.parse(raw)
    device.edid_status = device.edid and "ok" or "error"
    if not device.edid or device.edid.quality ~= "fresh" then issue("display_edid_incomplete") end
  else
    device.edid_status = type(raw) == "string" and "unavailable" or FS.error_status(edid_failure)
    if device.connection == "connected" then issue("display_edid_unavailable") end
  end
  local modes, modes_failure = fs:read(path .. "/modes", 16384)
  device.modes, device.modes_truncated = {}, false
  if modes then
    local seen = {}
    for value in modes:gmatch("[^\r\n]+") do
      -- This sysfs list contains mode names, not rates or the active mode.
      if #value <= 64 and value:match("^[%w%+%._%-]+$") then
        if not seen[value] then
          seen[value] = true
          if #device.modes < MAX_MODES then device.modes[#device.modes + 1] = value
          else device.modes_truncated = true end
        end
      else issue("display_invalid_modes") end
    end
  elseif device.connection == "connected" then
    device.modes_status = FS.error_status(modes_failure)
    issue("display_modes_unavailable")
  end
  if CurrentMode.attach(device, fs, base, context, native) then issue("display_inventory_incomplete") end
  device.observed_at_ns = Common.now_ns(context)
  local after = text(fs, path .. "/status")
  local after_id = text(fs, path .. "/connector_id")
  local after_edid = fs:read(path .. "/edid", 32768)
  if status ~= after or identity ~= after_id or raw ~= after_edid
      or target ~= link(fs, path) or card_target ~= link(fs, base .. "/" .. card .. "/device") then
    -- Do not attach a display's declarations to a connector that changed
    -- during this read. The next inventory sample discovers its new state.
    device.edid, device.connection, device.enabled, device.dpms = nil, nil, nil, nil
    device.connector_id, device.edid_reason, device.modes_status = nil, nil, nil
    device.modes, device.edid_status = {}, "gap"
    device.current_mode, device.current_mode_configured = nil, nil
    device.current_mode_observed_at_ns, device.current_mode_errno = nil, nil
    device.current_mode_status = "gap"
    device.current_mode_reason = "display_changed_during_read"
    device.quality = "gap"
    device.reason = "display_changed_during_read"
    return device
  end
  if card_target then
    local address = card_target:match("([^/]+)$")
    if address and address:match("^%x+:%x%x:%x%x%.[0-7]$") then
      device.pci_address = address:lower()
    end
  end
  return device
end

function M.read(fs, base, context, native)
  native = native or Native
  local entries, failure, truncated = fs:list(base, MAX_ENTRIES + 1)
  local result = { devices = {}, total = 0, truncated = truncated == true, source = base }
  if type(entries) ~= "table" then result.status = FS.error_status(failure); return result end
  result.total_is_lower_bound = truncated == true or #entries > MAX_ENTRIES
  result.status = "ok"
  local seen = {}
  for index = 1, math.min(#entries, MAX_ENTRIES) do
    local name = entries[index]
    local card, port
    if type(name) == "string" then card, port = name:match("^(card%d+)%-([%w%-]+%-%d+)$") end
    if card and #name <= 128 and not seen[name] then
      seen[name] = true
      result.total = result.total + 1
      if #result.devices < MAX_CONNECTORS then
        local device = connector(fs, base, name, card, port, context, native)
        result.devices[#result.devices + 1] = device
        if device.quality ~= "fresh" then result.status = "partial" end
      else result.truncated = true end
    end
  end
  table.sort(result.devices, function(a, b) return a.id < b.id end)
  result.truncated = result.truncated or #entries > MAX_ENTRIES
  return result
end

function M.new(options)
  options = options or {}
  if type(options) ~= "table" then error("display options must be a table", 2) end
  return setmetatable({ id = "displays", _method_style = true,
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 5000),
    fs = options.fs or FS.default,
    native = options.native or Native,
    drm_base = Common.absolute_path("drm_base", options.drm_base, "/sys/class/drm") }, M)
end

function M:probe(context)
  local entries, failure, truncated = Common.fs(context, self.fs):list(self.drm_base, MAX_ENTRIES + 1)
  for index = 1, math.min(#(entries or {}), MAX_ENTRIES) do
    local value = entries[index]
    if type(value) == "string" and value:match("^card%d+%-[%w%-]+%-%d+$") then
      return Capability.available({ source = self.drm_base })
    end
  end
  if FS.error_status(failure) == "denied" then
    return Capability.denied("display_inventory_denied", { source = self.drm_base })
  end
  if not entries and FS.error_status(failure) == "error" then
    return Capability.error("display_inventory_incomplete", { source = self.drm_base })
  end
  if entries and (truncated == true or #entries > MAX_ENTRIES) then
    return Capability.unavailable("device_enumeration_truncated", { source = self.drm_base })
  end
  return Capability.unavailable("no_display_connectors", { source = self.drm_base })
end

function M:sample(context)
  local started = Common.now_ns(context)
  local data = M.read(Common.fs(context, self.fs), self.drm_base, context, self.native)
  local finished = Common.now_ns(context)
  local metadata = { source = self.drm_base,
    duration_ns = Common.elapsed_ns(finished, started) or 0 }
  if #data.devices == 0 then
    local status = data.status == "denied" and "denied" or data.status == "error" and "error" or "unavailable"
    if status == "denied" then metadata.reason = "display_inventory_denied"
    elseif status == "error" then metadata.reason = "display_inventory_incomplete"
    elseif data.truncated then metadata.reason = "device_enumeration_truncated"
    else metadata.reason = "no_display_connectors" end
    return Common.result(status, finished, nil, metadata)
  end
  metadata.quality = data.status == "partial" and "partial" or data.truncated and "truncated" or "fresh"
  if data.status == "partial" then metadata.reason = "display_inventory_incomplete"
  elseif data.truncated then metadata.reason = "device_enumeration_truncated" end
  return Common.result("ok", finished, data, metadata)
end

return M
