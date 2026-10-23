-- Public sysfs PDO attributes describe advertised supplies or requirements.
-- They do not identify the selected contract or measure delivered power.
local M = {}
local units = { voltage = "mV", minimum_voltage = "mV", maximum_voltage = "mV",
  maximum_current = "mA", operational_current = "mA", maximum_power = "mW",
  operational_power = "mW", maximum_current_9V_to_15V = "mA",
  maximum_current_15V_to_20V = "mA" }
local fields = { voltage = "voltage_volts", minimum_voltage = "minimum_voltage_volts",
  maximum_voltage = "maximum_voltage_volts", maximum_current = "maximum_current_amperes",
  operational_current = "operational_current_amperes", maximum_power = "maximum_power_watts",
  operational_power = "operational_power_watts", peak_current = "peak_current_code",
  fast_role_swap_current = "fast_role_swap_current_code",
  maximum_current_9V_to_15V = "maximum_current_9V_to_15V_amperes",
  maximum_current_15V_to_20V = "maximum_current_15V_to_20V_amperes" }
local flags = { dual_role_power = true, usb_suspend_supported = true, higher_capability = true,
  unconstrained_power = true, usb_communication_capable = true, dual_role_data = true,
  unchunked_extended_messages_supported = true, pps_power_limited = true }

function M.fields(kind, direction, position)
  local out = {}
  local function add(...) for _, key in ipairs({...}) do out[#out + 1] = key end end
  local source = direction == "source"
  if kind == "fixed_supply" then
    add("voltage", source and "maximum_current" or "operational_current")
    add(source and "peak_current" or "fast_role_swap_current")
    if position == 1 then
      add("dual_role_power", "unconstrained_power", "usb_communication_capable",
        "dual_role_data", "unchunked_extended_messages_supported")
      add(source and "usb_suspend_supported" or "higher_capability")
    end
  elseif kind == "variable_supply" then
    add("minimum_voltage", "maximum_voltage", source and "maximum_current" or "operational_current")
  elseif kind == "battery" then
    add("minimum_voltage", "maximum_voltage", source and "maximum_power" or "operational_power")
  elseif kind == "programmable_supply" then
    add("minimum_voltage", "maximum_voltage", "maximum_current")
    if source then add("pps_power_limited") end
  elseif kind == "spr_adjustable_voltage_supply" then
    add("maximum_current_9V_to_15V", "maximum_current_15V_to_20V")
    if source then add("peak_current") end
  end
  return out
end

function M.required(key)
  return units[key] ~= nil
end

function M.parse(key, text)
  if type(text) ~= "string" or #text > 128 then return nil end
  text = text:match("^%s*(.-)%s*$")
  local digits, suffix = text:match("^(%d+)%s*([%a]*)$")
  local value = digits and tonumber(digits)
  if not value or math.type(value) ~= "integer" or value > 2147483647 then return nil end
  if flags[key] then
    if suffix ~= "" or value > 1 then return nil end
    return value == 1, key
  end
  if units[key] then
    if suffix ~= "" and suffix ~= units[key] then return nil end
    return value / 1000, fields[key]
  end
  if not fields[key] or suffix ~= "" or value > 3 then return nil end
  return value, fields[key]
end

return M
