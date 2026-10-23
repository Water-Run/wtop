-- Read-only external supply attributes. Programmable VBUS values can be
-- setpoints, so voltage/current products are not power measurements here.
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local M = {}
local NUMBERS = {
  voltage_now = "voltage_volts", current_now = "current_amperes",
  voltage_min = "minimum_voltage_volts", voltage_max = "maximum_voltage_volts",
  current_max = "maximum_current_amperes", power_now = "power_watts",
  input_voltage_limit = "input_voltage_limit_volts",
  input_current_limit = "input_current_limit_amperes",
  input_power_limit = "input_power_limit_watts",
}

function M.read(fs, device, context)
  local path, errors = device.source, {}
  device.errors, device.read_started_ns = errors, Common.now_ns(context)
  local function issue(key, err)
    if err and err.kind ~= "missing" and err.kind ~= "unavailable" then
      errors[key] = { status = FS.error_status(err), reason = err.message, source = path .. "/" .. key }
    end
  end
  local function text(key)
    local value, err = fs:read(path .. "/" .. key, 256)
    if not value then issue(key, err); return nil end
    value = Common.trim(value)
    if #value > 255 or value == "" or value:find("[%z\1-\31\127]") or not utf8.len(value) then
      issue(key, { kind = "parse_error", message = "invalid_supply_attribute" }); return nil
    end
    return value
  end
  local function number(key)
    local token = text(key)
    if token == nil then return nil end
    local value = tonumber(token)
    if not token:match("^%+?%d+$") or math.type(value) ~= "integer"
        or value < 0 or value > 9007199254740991 then
      issue(key, { kind = "parse_error", message = "invalid_supply_number" }); return nil
    end
    return value
  end
  local function link()
    return type(fs.readlink) == "function" and fs:readlink(path) or nil
  end
  local identity = link()
  device.identity_quality = identity and "path" or "estimated"
  local online = number("online")
  if online == 0 then device.online = false
  elseif online == 1 or online == 2 then device.online = true
  elseif online ~= nil then issue("online", { kind = "parse_error", message = "invalid_supply_online" }) end
  if online == 2 then device.online_mode = "programmable" end
  local usb = text("usb_type")
  if usb then
    local supported, active, bad = {}, nil, false
    for token in usb:gmatch("%S+") do
      local selected = token:match("^%[([%w_]+)%]$")
      local value = selected or token
      if #supported >= 16 or #value > 32 or not value:match("^[%w_]+$") then bad = true; break end
      supported[#supported + 1] = value
      if selected then if active then bad = true else active = selected end end
    end
    if #supported == 1 and not active then active = supported[1] end
    if bad or not active then issue("usb_type", { kind = "parse_error", message = "invalid_supply_usb_type" })
    else device.usb_type, device.usb_types = active, supported end
  end
  device.scope, device.status = text("scope"), text("status")
  local raw_input_limit
  for key, field in pairs(NUMBERS) do
    local value = number(key)
    if key == "input_power_limit" then raw_input_limit = value end
    if value ~= nil then device[field] = value / 1000000.0 end
  end
  -- Recheck identity and negotiation state around this non-atomic sysfs read.
  local unchanged = link() == identity and text("type") == device.type
    and number("online") == online and text("usb_type") == usb
  if device.input_power_limit_watts ~= nil then
    unchanged = unchanged and number("input_power_limit") == raw_input_limit
  end
  device.observed_at_ns = Common.now_ns(context)
  device.quality = not unchanged and "gap" or (device.online == nil or next(errors)) and "partial" or "fresh"
  return device
end

return M
