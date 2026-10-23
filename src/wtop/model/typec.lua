local Power = require("wtop.model.power")
local M = { MAX_PORTS = 64, MAX_PD = 64, MAX_PROFILES = 256 }
local COMMON = { "id", "index", "source", "device_path", "identity_quality",
  "quality", "read_started_ns", "observed_at_ns", "truncated" }
local PORT = { "data_role", "power_role", "port_type", "preferred_role", "power_operation_mode",
  "orientation", "vconn_source", "usb_typec_revision", "usb_power_delivery_revision",
  "usb_default_mode", "partner_observed", "cable_observed", "pd_id" }
local PROFILE = { "id", "position", "kind", "direction", "source", "quality",
  "voltage_volts", "minimum_voltage_volts", "maximum_voltage_volts", "maximum_current_amperes",
  "operational_current_amperes", "maximum_power_watts", "operational_power_watts",
  "maximum_current_9V_to_15V_amperes", "maximum_current_15V_to_20V_amperes",
  "peak_current_code", "fast_role_swap_current_code", "dual_role_power", "usb_suspend_supported",
  "higher_capability", "unconstrained_power", "usb_communication_capable", "dual_role_data",
  "unchunked_extended_messages_supported", "pps_power_limited" }
local function copy(source, fields)
  local out = {}; for _, key in ipairs(fields) do out[key] = source[key] end; return out
end
local function issues(source)
  local out = {}
  for index, issue in ipairs(source or {}) do
    if index > 32 then break end
    out[index] = copy(issue, { "field", "source", "status", "reason" })
  end
  return out
end
local function strings(source)
  local out = {}; for index, value in ipairs(source or {}) do
    if index > 16 then break end; out[index] = value
  end; return out
end

function M.state(snapshot, row)
  local quality = snapshot.quality and snapshot.quality.typec
  local state = Power.state(quality)
  if Power.unusable(state) then return state end
  if Power.unusable(row.quality) then return row.quality end
  local observed = row.observed_at_ns or type(quality) == "table" and quality.value_timestamp_ns
  if snapshot.timestamp_ns ~= nil then
    if type(observed) ~= "number" or observed < 0 or observed > snapshot.timestamp_ns then return "unknown" end
    if snapshot.timestamp_ns - observed > 60000000000 then return "stale" end
  end
  return row.quality or state or "unknown"
end

function M.current(snapshot, row)
  local state = M.state(snapshot, row)
  return state == "fresh" or state == "partial" or state == "estimated"
end

function M.port(snapshot, port)
  local out = copy(port, COMMON)
  for _, key in ipairs(PORT) do out[key] = port[key] end
  out.issues, out.quality = issues(port.issues), M.state(snapshot, port)
  for _, key in ipairs({ "data_roles", "power_roles", "usb_capabilities" }) do out[key] = strings(port[key]) end
  if not M.current(snapshot, port) then out.pd_id = nil end
  for _, key in ipairs({ "partner", "cable" }) do
    if type(port[key]) == "table" then
      out[key] = copy(port[key], { "id", "type", "source", "plug_type", "accessory_mode",
        "supports_usb_power_delivery", "usb_power_delivery_revision", "usb_mode", "quality" })
      out[key].issues, out[key].usb_modes = issues(port[key].issues), strings(port[key].usb_modes)
      if not M.current(snapshot, port) then out[key].quality = out.quality end
    end
  end
  return out
end

function M.pd(snapshot, pd, maximum)
  local out = copy(pd, COMMON)
  out.revision, out.version, out.declarations_only = pd.revision, pd.version, true
  out.quality, out.issues = M.state(snapshot, pd), issues(pd.issues)
  out.capability_status = copy(pd.capability_status or {}, { "source", "sink" })
  out.profiles = {}
  for index, profile in ipairs(pd.profiles or {}) do
    if index > (maximum or 64) then out.truncated = true; break end
    local row = copy(profile, PROFILE)
    row.declarations_only, row.issues = true, issues(profile.issues)
    if not M.current(snapshot, pd) then row.quality = out.quality end
    out.profiles[index] = row
  end
  return out
end

return M
