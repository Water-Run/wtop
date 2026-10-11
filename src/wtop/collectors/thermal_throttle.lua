local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")

local ThermalThrottle = {}
ThermalThrottle.__index = ThermalThrottle

local FIELDS = {
  { "core_count", "core_throttle_count", true },
  { "package_count", "package_throttle_count", true },
  { "core_total_time_ms", "core_throttle_total_time_ms" },
  { "package_total_time_ms", "package_throttle_total_time_ms" },
  { "core_max_time_ms", "core_throttle_max_time_ms" },
  { "package_max_time_ms", "package_throttle_max_time_ms" },
}

local function cpu_ids(fs, base, maximum)
  local names, err, cut = fs:list(base, 4096)
  if not names then return nil, err end
  local ids, seen = {}, {}
  for _, name in ipairs(names) do
    local token = type(name) == "string" and name:match("^cpu(%d+)$")
    local id = token and tonumber(token)
    if id and id <= 8191 and name == "cpu" .. tostring(id) and not seen[id] then
      ids[#ids + 1] = id
      seen[id] = true
    end
  end
  table.sort(ids)
  return ids, nil, cut == true or #ids > maximum
end

local function read_counter(fs, path, field, required, issues)
  local value, err = fs:read(path, 64)
  if value then
    value = Common.trim(value)
    if value and value:match("^%d+$") then
      local parsed = tonumber(value)
      if parsed and parsed <= 9007199254740991 and math.type(parsed) == "integer" then
        return parsed
      end
    end
    err = { kind = "parse_error", message = "invalid_thermal_throttle_counter" }
  elseif not required and err and (err.kind == "missing" or err.kind == "unavailable") then
    return nil
  end
  issues[#issues + 1] = { field = field, source = path,
    status = FS.error_status(err), reason = err and err.message or "read_failed" }
end

local function difference(current, previous)
  if current == nil or previous == nil then return nil, "gap" end
  if current < previous then return nil, "reset" end
  return current - previous, "fresh"
end

local function has_counter(files)
  for _, name in ipairs(files or {}) do
    if name == "core_throttle_count" or name == "package_throttle_count" then
      return true
    end
  end
  return false
end

function ThermalThrottle.new(options)
  options = options or {}
  if type(options) ~= "table" then error("thermal throttle options must be a table", 2) end
  return setmetatable({ id = "thermal_throttle", _method_style = true,
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/devices/system/cpu"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 5000),
    max_cpus = Common.positive_integer("max_cpus", options.max_cpus, 256, 8192),
    previous = {},
  }, ThermalThrottle)
end

function ThermalThrottle:probe(context)
  local fs = Common.fs(context, self.fs)
  local ids, err = cpu_ids(fs, self.base_path, self.max_cpus)
  if not ids then
    if FS.error_status(err) == "denied" then
      return Capability.denied(err.message, { source = self.base_path })
    end
    return Capability.unavailable("no_thermal_throttle_counters", { source = self.base_path })
  end
  local denied
  for _, id in ipairs(ids) do
    local path = self.base_path .. "/cpu" .. id .. "/thermal_throttle"
    local files, dir_error = fs:list(path, 16)
    if files and has_counter(files) then
      return Capability.available({ source = self.base_path })
    end
    if FS.error_status(dir_error) == "denied" then
      denied = denied or { reason = dir_error.message, source = path }
    end
  end
  if denied then return Capability.denied(denied.reason, { source = denied.source }) end
  return Capability.unavailable("no_thermal_throttle_counters", { source = self.base_path })
end

function ThermalThrottle:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local ids, err, truncated = cpu_ids(fs, self.base_path, self.max_cpus)
  if not ids then
    self.previous = {}
    return Common.error_result(err, Common.now_ns(context), self.base_path)
  end
  local data = { cpus = {}, issues = {}, truncated = truncated, source = self.base_path }
  local next_previous = {}
  local any_count = false
  for index = 1, math.min(#ids, self.max_cpus) do
    local id = ids[index]
    local path = self.base_path .. "/cpu" .. id .. "/thermal_throttle"
    local files, dir_error = fs:list(path, 16)
    if files and has_counter(files) then
      local cpu = { id = id, source = path, issues = {} }
      for _, spec in ipairs(FIELDS) do
        cpu[spec[1]] = read_counter(fs, path .. "/" .. spec[2], spec[1], spec[3], cpu.issues)
      end
      any_count = any_count or cpu.core_count ~= nil or cpu.package_count ~= nil
      local previous = self.previous[id] or {}
      cpu.core_new, cpu.core_delta_quality = difference(cpu.core_count, previous.core_count)
      cpu.package_new, cpu.package_delta_quality = difference(cpu.package_count, previous.package_count)
      next_previous[id] = { core_count = cpu.core_count, package_count = cpu.package_count }
      data.cpus[#data.cpus + 1] = cpu
    elseif not files and FS.error_status(dir_error) ~= "unavailable" then
      data.issues[#data.issues + 1] = { field = "cpu" .. id, source = path,
        status = FS.error_status(dir_error), reason = dir_error and dir_error.message }
    end
  end
  self.previous = next_previous
  local finished = Common.now_ns(context)
  if not any_count then
    local status = "unavailable"
    local function inspect(issues)
      for _, issue in ipairs(issues) do
        if issue.status == "error" then status = "error"; return end
        if issue.status == "denied" then status = "denied" end
      end
    end
    inspect(data.issues)
    for _, cpu in ipairs(data.cpus) do inspect(cpu.issues) end
    local reason = (#data.cpus > 0 or #data.issues > 0)
        and "thermal_throttle_data_incomplete" or "no_thermal_throttle_counters"
    return Common.result(status, finished, nil,
      { source = self.base_path, quality = status, reason = reason })
  end
  local partial = data.truncated or #data.issues > 0
  for _, cpu in ipairs(data.cpus) do partial = partial or #cpu.issues > 0 end
  return Common.result("ok", finished, data, { source = self.base_path,
    quality = partial and "partial" or "fresh",
    reason = partial and "thermal_throttle_data_incomplete" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

return ThermalThrottle
