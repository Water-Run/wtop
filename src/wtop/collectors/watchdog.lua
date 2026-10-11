-- Read-only Linux watchdog class inventory. Never opens /dev/watchdog.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Sysfs = require("wtop.linux.sysfs")

local Watchdog = {}
Watchdog.__index = Watchdog

local function names(fs, base, maximum)
  local entries, err, cut = fs:list(base, 256)
  if not entries then return nil, err end
  local result = {}
  for _, name in ipairs(entries) do
    local digits = type(name) == "string" and name:match("^watchdog(%d+)$")
    local index = digits and tonumber(digits)
    if index and index <= 65535 and name == "watchdog" .. tostring(index) then
      result[#result + 1] = { id = name, index = index }
    end
  end
  table.sort(result, function(a, b) return a.index < b.index end)
  return result, nil, cut == true or #result > maximum
end

local function issue(issues, field, source, err, reason)
  if #issues >= 64 then return end
  issues[#issues + 1] = { field = field, source = source,
    status = FS.error_status(err), reason = reason or err and err.message or "invalid_watchdog_value" }
end

local function read_text(fs, path, field, issues, required)
  local raw, err = fs:read(path, 128)
  if raw == nil then
    if required or not err or (err.kind ~= "missing" and err.kind ~= "unavailable") then
      issue(issues, field, path, err)
    end
    return nil
  end
  local value = Common.safe_text(Common.trim(raw), 128)
  if value and value ~= "" then return value end
  issue(issues, field, path, { kind = "parse_error" }, "invalid_watchdog_value")
end

local function read_number(fs, path, field, issues, required, maximum)
  local value = read_text(fs, path, field, issues, required)
  if value == nil then return nil end
  local parsed = value:match("^0[xX][%da-fA-F]+$") and tonumber(value:sub(3), 16)
    or value:match("^%d+$") and tonumber(value) or nil
  if parsed and math.type(parsed) == "integer" and parsed >= 0 and parsed <= maximum then
    return parsed
  end
  issue(issues, field, path, { kind = "parse_error" }, "invalid_watchdog_value")
end

local function read_flag(fs, path, field, issues)
  local value = read_number(fs, path, field, issues, false, 1)
  if value == 0 then return false end
  if value == 1 then return true end
end

function Watchdog.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Watchdog options must be a table", 2) end
  return setmetatable({ id = "watchdog", _method_style = true,
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/class/watchdog"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 5000),
    max_devices = Common.positive_integer("max_devices", options.max_devices, 16, 64),
  }, Watchdog)
end

function Watchdog:probe(context)
  local devices, err = names(Common.fs(context, self.fs), self.base_path, self.max_devices)
  if devices and #devices > 0 then return Capability.available({ source = self.base_path }) end
  if err and FS.error_status(err) == "denied" then
    return Capability.denied(err.message, { source = self.base_path })
  end
  return Capability.unavailable("no_watchdog_devices", { source = self.base_path })
end

function Watchdog:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local ids, err, truncated = names(fs, self.base_path, self.max_devices)
  if not ids then return Common.error_result(err, Common.now_ns(context), self.base_path) end
  if #ids == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { source = self.base_path, reason = "no_watchdog_devices" })
  end
  local data = { devices = {}, issues = {}, truncated = truncated == true,
    source = self.base_path }
  for index = 1, math.min(#ids, self.max_devices) do
    local id = ids[index].id
    local path = self.base_path .. "/" .. id
    local device = { id = id, index = ids[index].index, source = path, issues = {} }
    device.identity = read_text(fs, path .. "/identity", "identity", device.issues, true)
    local state = read_text(fs, path .. "/state", "state", device.issues, true)
    if state == "active" or state == "inactive" then
      device.state = state
    elseif state then
      issue(device.issues, "state", path .. "/state",
        { kind = "parse_error" }, "invalid_watchdog_state")
    end
    device.timeout_seconds = read_number(fs, path .. "/timeout", "timeout",
      device.issues, false, 604800)
    if device.state == "active" then
      device.timeleft_seconds = read_number(fs, path .. "/timeleft", "timeleft",
        device.issues, false, 604800)
    end
    device.pretimeout_seconds = read_number(fs, path .. "/pretimeout", "pretimeout",
      device.issues, false, 604800)
    device.nowayout = read_flag(fs, path .. "/nowayout", "nowayout", device.issues)
    device.status = read_number(fs, path .. "/status", "status", device.issues,
      false, 0xffffffff)
    device.bootstatus = read_number(fs, path .. "/bootstatus", "bootstatus",
      device.issues, false, 0xffffffff)
    device.firmware_version = read_number(fs, path .. "/fw_version", "fw_version",
      device.issues, false, 0xffffffff)
    device.pretimeout_governor = read_text(fs, path .. "/pretimeout_governor",
      "pretimeout_governor", device.issues, false)
    device.device_path = Sysfs.device_path(fs, path)
    local driver_target = fs:readlink(path .. "/device/driver")
    local driver = type(driver_target) == "string" and driver_target:match("/([^/]+)$")
    if driver and #driver <= 64 and driver:match("^[%w_.-]+$") then
      device.driver = driver
    end
    device.quality = #device.issues > 0 and "partial" or "fresh"
    for _, item in ipairs(device.issues) do
      if #data.issues < 64 then data.issues[#data.issues + 1] = item end
    end
    data.devices[#data.devices + 1] = device
  end
  data.partial = #data.issues > 0
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, data, {
    quality = (data.partial or data.truncated) and "partial" or "fresh",
    reason = (data.partial or data.truncated) and "watchdog_data_incomplete" or nil,
    source = self.base_path,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
  })
end

return Watchdog
