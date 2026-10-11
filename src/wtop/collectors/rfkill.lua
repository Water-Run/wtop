-- Read-only Linux radio-block inventory. Does not change software switches.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Sysfs = require("wtop.linux.sysfs")

local Rfkill = {}
Rfkill.__index = Rfkill

local function names(fs, base, maximum)
  local entries, err, cut = fs:list(base, 256)
  if not entries then return nil, err end
  local result = {}
  for _, name in ipairs(entries) do
    local digits = type(name) == "string" and name:match("^rfkill(%d+)$")
    local index = digits and tonumber(digits)
    if index and index <= 65535 and name == "rfkill" .. tostring(index) then
      result[#result + 1] = { id = name, index = index }
    end
  end
  table.sort(result, function(a, b) return a.index < b.index end)
  return result, nil, cut == true or #result > maximum
end

local function issue(issues, field, path, err, reason)
  if #issues >= 64 then return end
  issues[#issues + 1] = { field = field, source = path,
    status = FS.error_status(err), reason = reason or err and err.message or "invalid_rfkill_value" }
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
  issue(issues, field, path, { kind = "parse_error" }, "invalid_rfkill_value")
end

local function read_flag(fs, path, field, issues)
  local raw, err = fs:read(path, 16)
  if raw == nil then
    if err and (err.kind == "missing" or err.kind == "unavailable") then
      return nil, err.kind
    end
    issue(issues, field, path, err)
    return nil, "error"
  end
  local value = Common.trim(raw)
  if value == "0" then return false end
  if value == "1" then return true end
  issue(issues, field, path, { kind = "parse_error" }, "invalid_rfkill_value")
  return nil, "error"
end

local function legacy_state(fs, path, device)
  local raw, err = fs:read(path, 16)
  if raw == nil then
    issue(device.issues, "state", path, err)
    return
  end
  local state = Common.trim(raw)
  if state == "0" then
    device.soft_blocked = true
    device.blocked = true
  elseif state == "1" then
    device.soft_blocked = false
    device.hard_blocked = false
    device.blocked = false
  elseif state == "2" then
    device.hard_blocked = true
    device.blocked = true
  else
    issue(device.issues, "state", path, { kind = "parse_error" }, "invalid_rfkill_value")
    return
  end
  device.state_source = "legacy"
end

function Rfkill.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Rfkill options must be a table", 2) end
  return setmetatable({ id = "rfkill", _method_style = true,
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/class/rfkill"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 2000),
    max_devices = Common.positive_integer("max_devices", options.max_devices, 64, 128),
  }, Rfkill)
end

function Rfkill:probe(context)
  local devices, err = names(Common.fs(context, self.fs), self.base_path, self.max_devices)
  if devices and #devices > 0 then return Capability.available({ source = self.base_path }) end
  if err and FS.error_status(err) == "denied" then
    return Capability.denied(err.message, { source = self.base_path })
  end
  return Capability.unavailable("no_rfkill_devices", { source = self.base_path })
end

function Rfkill:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local ids, err, truncated = names(fs, self.base_path, self.max_devices)
  if not ids then return Common.error_result(err, Common.now_ns(context), self.base_path) end
  if #ids == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { source = self.base_path, reason = "no_rfkill_devices" })
  end
  local data = { devices = {}, issues = {}, truncated = truncated == true,
    source = self.base_path }
  for index = 1, math.min(#ids, self.max_devices) do
    local id = ids[index].id
    local path = self.base_path .. "/" .. id
    local device = { id = id, index = ids[index].index,
      source = path, issues = {} }
    device.name = read_text(fs, path .. "/name", "name", device.issues, true)
    device.type = read_text(fs, path .. "/type", "type", device.issues, true)
    local hard, hard_state = read_flag(fs, path .. "/hard", "hard", device.issues)
    local soft, soft_state = read_flag(fs, path .. "/soft", "soft", device.issues)
    device.hard_blocked, device.soft_blocked = hard, soft
    if hard ~= nil and soft ~= nil then
      device.blocked = hard or soft
      device.state_source = "hard_soft"
    elseif hard_state == "missing" and soft_state == "missing" then
      legacy_state(fs, path .. "/state", device)
    else
      if hard == true or soft == true then device.blocked = true end
      issue(device.issues, "block_state", path,
        { kind = "unavailable" }, "rfkill_block_state_incomplete")
    end
    device.persistent = read_flag(fs, path .. "/persistent",
      "persistent", device.issues)
    device.device_path = Sysfs.device_path(fs, path)
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
    reason = (data.partial or data.truncated) and "rfkill_data_incomplete" or nil,
    source = self.base_path,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
  })
end

return Rfkill
