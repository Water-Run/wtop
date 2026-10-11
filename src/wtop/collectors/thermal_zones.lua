-- Read-only Linux thermal zones, trip points and cooling-device bindings.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Sysfs = require("wtop.linux.sysfs")

local ThermalZones = {}
ThermalZones.__index = ThermalZones
local MAX_SAFE_INTEGER = 9007199254740991

local function entries(fs, base, max_zones, max_cooling)
  local listed, err, cut = fs:list(base, 512)
  if not listed then return nil, nil, err end
  local zones, cooling = {}, {}
  for _, name in ipairs(listed) do
    if type(name) == "string" then
      for _, spec in ipairs({ { "thermal_zone", zones },
          { "cooling_device", cooling } }) do
        local digits = name:match("^" .. spec[1] .. "(%d+)$")
        local index = digits and tonumber(digits)
        if index and index <= 65535 and name == spec[1] .. tostring(index) then
          spec[2][#spec[2] + 1] = { id = name, index = index }
        end
      end
    end
  end
  local by_index = function(a, b) return a.index < b.index end
  table.sort(zones, by_index)
  table.sort(cooling, by_index)
  return zones, cooling, nil, cut == true
    or #zones > max_zones or #cooling > max_cooling
end

local function issue(issues, field, path, err, reason)
  if #issues >= 64 then return end
  issues[#issues + 1] = { field = field, source = path,
    status = FS.error_status(err),
    reason = reason or err and err.message or "invalid_thermal_value" }
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
  issue(issues, field, path, { kind = "parse_error" }, "invalid_thermal_value")
end

local function read_integer(fs, path, field, issues, required, minimum, maximum)
  local raw, err = fs:read(path, 32)
  if raw == nil then
    if required or not err or (err.kind ~= "missing" and err.kind ~= "unavailable") then
      issue(issues, field, path, err)
    end
    return nil
  end
  local token = Common.trim(raw)
  local value = token and token:match("^%-?%d+$") and tonumber(token)
  if value and math.type(value) == "integer" and value >= minimum and value <= maximum then
    return value
  end
  issue(issues, field, path, { kind = "parse_error" }, "invalid_thermal_value")
end

local function temperature(fs, path, field, issues, required)
  local value = read_integer(fs, path, field, issues, required, -1000000, 1000000)
  if value == nil then return nil end
  -- Several drivers publish -274000 for a trip they cannot provide. It is
  -- below absolute zero, so leave an optional trip unknown without inventing
  -- a threshold or degrading the zone's actual temperature reading.
  if value < -273150 then
    if required then
      issue(issues, field, path, { kind = "parse_error" }, "invalid_thermal_value")
    end
    return nil
  end
  return value / 1000
end

local function member_ids(listed, pattern, maximum)
  local ids, seen = {}, {}
  local patterns = type(pattern) == "table" and pattern or { pattern }
  for _, name in ipairs(listed) do
    local digits
    if type(name) == "string" then
      for _, candidate in ipairs(patterns) do
        digits = name:match(candidate)
        if digits then break end
      end
    end
    local id = digits and tonumber(digits)
    if id and id <= 65535 and digits == tostring(id) and not seen[id] then
      ids[#ids + 1], seen[id] = id, true
    end
  end
  table.sort(ids)
  return ids, #ids > maximum
end

local function cooling_target(fs, path, issues)
  local target, err = fs:readlink(path)
  if target == nil then
    issue(issues, "cooling_binding", path, err)
    return nil
  end
  local id = target:match("^%.%./(cooling_device%d+)$")
    or target:match("^/sys/devices/virtual/thermal/(cooling_device%d+)$")
    or target:match("^/sys/class/thermal/(cooling_device%d+)$")
  local digits = id and id:match("^cooling_device(%d+)$")
  local index = digits and tonumber(digits)
  if index and index <= 65535 and id == "cooling_device" .. tostring(index) then
    return id
  end
  issue(issues, "cooling_binding", path,
    { kind = "parse_error" }, "invalid_thermal_binding")
end

local function backing_device_path(fs, path)
  -- The class entry is itself a symlink. A zone's `device` link is relative
  -- to that resolved directory, not to /sys/class/thermal/thermal_zoneN.
  local class_path = Sysfs.device_path(fs, path)
  if class_path then
    local device = Sysfs.device_path(fs, class_path .. "/device")
    if device then return device end
    if not class_path:match("^/sys/devices/virtual/thermal/") then
      return class_path
    end
    return nil
  end
  return Sysfs.device_path(fs, path .. "/device")
end

local function sample_zone(fs, base, entry)
  local path = base .. "/" .. entry.id
  local zone = { id = entry.id, index = entry.index, source = path,
    trips = {}, bindings = {}, issues = {} }
  zone.type = read_text(fs, path .. "/type", "type", zone.issues, true)
  zone.temperature_celsius = temperature(fs, path .. "/temp", "temp", zone.issues, true)
  zone.mode = read_text(fs, path .. "/mode", "mode", zone.issues, false)
  zone.policy = read_text(fs, path .. "/policy", "policy", zone.issues, false)
  zone.device_path = backing_device_path(fs, path)
  local listed, err, cut = fs:list(path, 256)
  if not listed then
    issue(zone.issues, "directory", path, err)
  else
    local trips, trip_cut = member_ids(listed,
      { "^trip_point_(%d+)_type$", "^trip_point_(%d+)_temp$",
        "^trip_point_(%d+)_hyst$" }, 32)
    local cooling, cooling_cut = member_ids(listed, "^cdev(%d+)$", 32)
    zone.truncated = cut == true or trip_cut or cooling_cut
    for index = 1, math.min(#trips, 32) do
      local id = trips[index]
      zone.trips[#zone.trips + 1] = {
        index = id,
        type = read_text(fs, path .. "/trip_point_" .. id .. "_type",
          "trip_type", zone.issues, true),
        temperature_celsius = temperature(fs,
          path .. "/trip_point_" .. id .. "_temp", "trip_temp", zone.issues, false),
      }
    end
    for index = 1, math.min(#cooling, 32) do
      local slot = cooling[index]
      local link = path .. "/cdev" .. slot
      local cooling_id = cooling_target(fs, link, zone.issues)
      local trip = read_integer(fs, link .. "_trip_point", "cooling_trip",
        zone.issues, false, -1, 65535)
      local weight = read_integer(fs, link .. "_weight", "cooling_weight",
        zone.issues, false, 0, 1000000)
      if cooling_id then
        zone.bindings[#zone.bindings + 1] = {
          slot = slot, cooling_id = cooling_id,
          trip_index = trip and trip >= 0 and trip or nil,
          weight = weight,
        }
      end
    end
  end
  zone.quality = (#zone.issues > 0 or zone.truncated) and "partial" or "fresh"
  return zone
end

local function cooling_stats(fs, path, max_state, issues)
  local source = path .. "/stats"
  local files, err, cut = fs:list(source, 8)
  if not files then
    if err and (err.kind == "missing" or err.kind == "unavailable") then return nil end
    issue(issues, "stats", source, err)
    return nil
  end
  local stats = { source = source, time_in_state_ms = {}, truncated = cut == true }
  local start_issues = #issues
  local found = {}
  for _, name in ipairs(files) do found[name] = true end
  if found.total_trans then
    stats.total_transitions = read_integer(fs, source .. "/total_trans",
      "total_trans", issues, true, 0, MAX_SAFE_INTEGER)
  else
    issue(issues, "total_trans", source .. "/total_trans",
      { kind = "missing" }, "cooling_stats_incomplete")
  end
  if found.time_in_state_ms then
    local file = source .. "/time_in_state_ms"
    local raw, read_error = fs:read(file, 16384)
    if raw == nil then
      issue(issues, "time_in_state_ms", file, read_error)
    else
      local seen, count = {}, 0
      for line in raw:gmatch("[^\n]+") do
        count = count + 1
        if count > 256 then stats.truncated = true break end
        local state_text, value_text = line:match("^state(%d+)%s+(%d+)%s*$")
        local state = state_text and tonumber(state_text)
        local value = value_text and tonumber(value_text)
        if state and value and state_text == tostring(state)
            and math.type(state) == "integer" and state >= 0
            and (max_state == nil or state <= max_state)
            and math.type(value) == "integer" and value <= MAX_SAFE_INTEGER
            and not seen[state] then
          seen[state] = true
          stats.time_in_state_ms[#stats.time_in_state_ms + 1] = {
            state = state, milliseconds = value }
        else
          issue(issues, "time_in_state_ms", file,
            { kind = "parse_error" }, "invalid_cooling_stats")
        end
      end
      if max_state and max_state <= 255 then
        for state = 0, max_state do
          if not seen[state] then
            issue(issues, "time_in_state_ms", file,
              { kind = "unavailable" }, "cooling_stats_incomplete")
            break
          end
        end
      elseif max_state and max_state > 255 then
        stats.truncated = true
      end
      table.sort(stats.time_in_state_ms, function(a, b) return a.state < b.state end)
    end
  else
    issue(issues, "time_in_state_ms", source .. "/time_in_state_ms",
      { kind = "missing" }, "cooling_stats_incomplete")
  end
  stats.quality = (#issues > start_issues or stats.truncated) and "partial" or "fresh"
  return stats
end

local function sample_cooling(fs, base, entry)
  local path = base .. "/" .. entry.id
  local device = { id = entry.id, index = entry.index, source = path, issues = {} }
  device.type = read_text(fs, path .. "/type", "type", device.issues, true)
  device.max_state = read_integer(fs, path .. "/max_state", "max_state",
    device.issues, true, 0, 1000000)
  device.cur_state = read_integer(fs, path .. "/cur_state", "cur_state",
    device.issues, true, 0, 1000000)
  if device.max_state and device.cur_state and device.cur_state > device.max_state then
    issue(device.issues, "cur_state", path .. "/cur_state",
      { kind = "parse_error" }, "invalid_thermal_value")
    device.cur_state = nil
  end
  device.device_path = backing_device_path(fs, path)
  device.stats = cooling_stats(fs, path, device.max_state, device.issues)
  device.truncated = device.stats and device.stats.truncated or nil
  device.quality = (#device.issues > 0 or device.truncated) and "partial" or "fresh"
  return device
end

function ThermalZones.new(options)
  options = options or {}
  if type(options) ~= "table" then error("thermal zones options must be a table", 2) end
  return setmetatable({ id = "thermal_zones", _method_style = true,
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/class/thermal"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 2000),
    max_zones = Common.positive_integer("max_zones", options.max_zones, 64, 64),
    max_cooling = Common.positive_integer("max_cooling", options.max_cooling, 128, 128),
  }, ThermalZones)
end

function ThermalZones:probe(context)
  local zones, cooling, err = entries(Common.fs(context, self.fs),
    self.base_path, self.max_zones, self.max_cooling)
  if zones and (#zones > 0 or #cooling > 0) then
    return Capability.available({ source = self.base_path })
  end
  if err and FS.error_status(err) == "denied" then
    return Capability.denied(err.message, { source = self.base_path })
  end
  return Capability.unavailable("no_linux_thermal_devices", { source = self.base_path })
end

function ThermalZones:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local zones, cooling, err, truncated = entries(fs, self.base_path,
    self.max_zones, self.max_cooling)
  if not zones then return Common.error_result(err, Common.now_ns(context), self.base_path) end
  if #zones == 0 and #cooling == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { source = self.base_path, reason = "no_linux_thermal_devices" })
  end
  local data = { zones = {}, cooling_devices = {}, issues = {},
    truncated = truncated == true, source = self.base_path }
  local function add_issues(device)
    for _, item in ipairs(device.issues) do
      if #data.issues < 64 then data.issues[#data.issues + 1] = item end
    end
    data.truncated = data.truncated or device.truncated == true
  end
  for index = 1, math.min(#zones, self.max_zones) do
    local zone = sample_zone(fs, self.base_path, zones[index])
    data.zones[#data.zones + 1] = zone
    add_issues(zone)
  end
  for index = 1, math.min(#cooling, self.max_cooling) do
    local device = sample_cooling(fs, self.base_path, cooling[index])
    data.cooling_devices[#data.cooling_devices + 1] = device
    add_issues(device)
  end
  data.partial = #data.issues > 0
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, data, {
    quality = (data.partial or data.truncated) and "partial" or "fresh",
    reason = (data.partial or data.truncated) and "thermal_data_incomplete" or nil,
    source = self.base_path,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
  })
end

return ThermalZones
