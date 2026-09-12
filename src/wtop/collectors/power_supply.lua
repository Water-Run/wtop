-- Batteries and mains adapters from /sys/class/power_supply.
--
-- Kernel drivers expose either energy (µWh) or charge (µAh) units depending on
-- the platform, so both are normalised here and the derived percentage
-- prefers the driver's own `capacity` when it publishes one.
local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local PowerSupply = {}
PowerSupply.__index = PowerSupply

local MAX_DEVICES = 16
local MAX_SMALL_FILE = 64 * 1024
local MICRO = 1000000.0

local function text(fs, path)
  local content = fs:read(path, MAX_SMALL_FILE)
  if type(content) ~= "string" then return nil end
  local trimmed = Common.trim(content)
  if trimmed == "" then return nil end
  return Common.safe_text(trimmed, 128)
end

local function micro(fs, path)
  local value = tonumber(text(fs, path))
  if type(value) ~= "number" or value ~= value
      or value == math.huge or value == -math.huge then
    return nil
  end
  return value / MICRO
end

local function integer(fs, path)
  local value = tonumber(text(fs, path))
  if type(value) ~= "number" or value ~= value
      or value == math.huge or value == -math.huge or value % 1 ~= 0 then
    return nil
  end
  return value
end

local function first(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil then return value end
  end
  return nil
end

local function read_device(fs, base, name)
  local path = base .. "/" .. name
  local kind = text(fs, path .. "/type")
  if not kind then return nil end

  local device = {
    id = name,
    name = name,
    type = kind,
    present = text(fs, path .. "/present") ~= "0",
    source = path,
  }

  if kind == "Mains" or kind == "USB" or kind == "Wireless" then
    device.online = text(fs, path .. "/online") == "1"
    device.quality = "fresh"
    return device
  end

  device.status = text(fs, path .. "/status")
  device.technology = text(fs, path .. "/technology")
  device.manufacturer = text(fs, path .. "/manufacturer")
  device.model = text(fs, path .. "/model_name")
  device.serial_present = text(fs, path .. "/serial_number") ~= nil
  device.cycle_count = integer(fs, path .. "/cycle_count")
  device.voltage_volts = micro(fs, path .. "/voltage_now")
  device.voltage_design_volts = micro(fs, path .. "/voltage_min_design")
  device.temperature_celsius = (function()
    local raw = integer(fs, path .. "/temp")
    return raw and raw / 10 or nil
  end)()

  -- energy_* is Wh once scaled; charge_* is Ah and needs the present voltage to
  -- become comparable energy.  Keep both and expose whichever the driver gave.
  local energy_now = micro(fs, path .. "/energy_now")
  local energy_full = micro(fs, path .. "/energy_full")
  local energy_design = micro(fs, path .. "/energy_full_design")
  local charge_now = micro(fs, path .. "/charge_now")
  local charge_full = micro(fs, path .. "/charge_full")
  local charge_design = micro(fs, path .. "/charge_full_design")

  if not energy_now and charge_now and device.voltage_volts then
    energy_now = charge_now * device.voltage_volts
  end
  if not energy_full and charge_full and device.voltage_volts then
    energy_full = charge_full * device.voltage_volts
  end
  if not energy_design and charge_design and device.voltage_volts then
    energy_design = charge_design * device.voltage_volts
  end

  device.energy_watt_hours = energy_now
  device.energy_full_watt_hours = energy_full
  device.energy_design_watt_hours = energy_design
  device.charge_amp_hours = charge_now
  device.charge_full_amp_hours = charge_full

  local capacity = integer(fs, path .. "/capacity")
  if capacity and capacity >= 0 and capacity <= 100 then
    device.capacity_percent = capacity
  elseif energy_now and energy_full and energy_full > 0 then
    device.capacity_percent = math.max(0, math.min(100, energy_now * 100 / energy_full))
  end

  if energy_full and energy_design and energy_design > 0 then
    device.health_percent = math.max(0, math.min(100, energy_full * 100 / energy_design))
  end

  local power = micro(fs, path .. "/power_now")
  if not power then
    local current = micro(fs, path .. "/current_now")
    if current and device.voltage_volts then power = current * device.voltage_volts end
  end
  device.power_watts = power

  -- Remaining runtime only means something while actually discharging.
  if power and power > 0 and energy_now and device.status == "Discharging" then
    device.time_remaining_seconds = energy_now / power * 3600
  elseif power and power > 0 and energy_now and energy_full
      and device.status == "Charging" and energy_full > energy_now then
    device.time_to_full_seconds = (energy_full - energy_now) / power * 3600
  end

  device.capacity_level = text(fs, path .. "/capacity_level")
  device.quality = first(device.capacity_percent, device.status) and "fresh" or "partial"
  return device
end

function PowerSupply.new(options)
  options = options or {}
  if type(options) ~= "table" then error("PowerSupply options must be a table", 2) end
  return setmetatable({
    id = "power_supply",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 5000),
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path,
      "/sys/class/power_supply"),
    _method_style = true,
  }, PowerSupply)
end

function PowerSupply:probe(context)
  local fs = Common.fs(context, self.fs)
  local entries, err = fs:list(self.base_path, MAX_DEVICES)
  if entries and #entries > 0 then
    return Capability.available({ source = self.base_path })
  end
  if entries then
    return Capability.unavailable("no_power_supplies", { source = self.base_path })
  end
  local status = FS.error_status(err)
  if status == "denied" then
    return Capability.denied(err.message, { source = self.base_path })
  end
  return Capability.unavailable(err and err.message or "power_supply_unavailable",
    { source = self.base_path })
end

function PowerSupply:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local entries, list_error, truncated = fs:list(self.base_path, MAX_DEVICES)
  if not entries then
    return Common.error_result(list_error, Common.now_ns(context), self.base_path)
  end

  local batteries, supplies = {}, {}
  local partial = 0
  for _, name in ipairs(entries) do
    if #batteries + #supplies >= MAX_DEVICES then
      truncated = true
      break
    end
    local device = read_device(fs, self.base_path, name)
    if device then
      if device.quality == "partial" then partial = partial + 1 end
      if device.type == "Battery" then
        batteries[#batteries + 1] = device
      else
        supplies[#supplies + 1] = device
      end
    end
  end

  local summary
  if #batteries > 0 then
    local percent_sum, percent_count, power_sum = 0, 0, nil
    local charging, discharging = false, false
    for _, battery in ipairs(batteries) do
      if battery.capacity_percent then
        percent_sum = percent_sum + battery.capacity_percent
        percent_count = percent_count + 1
      end
      if battery.power_watts then power_sum = (power_sum or 0) + battery.power_watts end
      if battery.status == "Charging" then charging = true end
      if battery.status == "Discharging" then discharging = true end
    end
    summary = {
      count = #batteries,
      capacity_percent = percent_count > 0 and percent_sum / percent_count or nil,
      power_watts = power_sum,
      state = charging and "charging" or (discharging and "discharging" or "idle"),
    }
  end

  local on_ac
  for _, supply in ipairs(supplies) do
    if supply.online then on_ac = true break end
    on_ac = on_ac or false
  end

  local finished = Common.now_ns(context)
  -- A host with no battery and no adapter must report the same way every other
  -- absent resource does: `unavailable`, not `ok` with an empty payload.
  -- Reporting "ok" left the UI unable to tell "no power supplies" from "power
  -- supplies read successfully", kept the widget on screen with nothing in it,
  -- and denied the scheduler its back-off.
  if #batteries == 0 and #supplies == 0 then
    return Common.result("unavailable", finished, nil, {
      quality = "unavailable",
      reason = "no_power_supplies",
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.base_path,
    })
  end
  local quality = "fresh"
  if partial > 0 or truncated then
    quality = truncated and "truncated" or "partial"
  end
  return Common.result("ok", finished, {
    batteries = batteries,
    supplies = supplies,
    summary = summary,
    on_ac_power = on_ac,
    truncated = truncated == true,
  }, {
    quality = quality,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = self.base_path,
  })
end

PowerSupply.read_device = read_device

return PowerSupply
