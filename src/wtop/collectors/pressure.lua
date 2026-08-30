local Capability = require("wtop.core.capability")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local Pressure = {}
Pressure.__index = Pressure

function Pressure.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Pressure options must be a table", 2) end
  local resources = options.resources or { "cpu", "memory", "io" }
  if type(resources) ~= "table" or #resources < 1 or #resources > 16 then
    error("pressure resources must be a non-empty table with at most 16 entries", 2)
  end
  local resource_copy, seen = {}, {}
  for _, resource in ipairs(resources) do
    if type(resource) ~= "string" or not resource:match("^[A-Za-z0-9_-]+$")
        or #resource > 64 or seen[resource] then
      error("invalid pressure resource", 2)
    end
    seen[resource] = true
    resource_copy[#resource_copy + 1] = resource
  end
  return setmetatable({
    id = "pressure",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/proc/pressure"),
    resources = resource_copy,
    _method_style = true,
  }, Pressure)
end

function Pressure:probe(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.base_path .. "/cpu", 65536)
  if content then
    return Capability.available({ source = self.base_path })
  end
  local status = FS.error_status(err)
  if status == "denied" then
    return Capability.denied(err.message, { source = self.base_path })
  end
  return Capability.unavailable(err and err.message or "psi_unavailable", { source = self.base_path })
end

function Pressure:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local data = {}
  local errors = {}
  local success = 0
  local denied = 0
  local failed = 0
  for _, resource in ipairs(self.resources) do
    local path = self.base_path .. "/" .. resource
    local content, err = fs:read(path, 65536)
    if content then
      local parsed, parse_error = Parsers.psi(content)
      if parsed then
        data[resource] = parsed
        success = success + 1
      else
        errors[resource] = { status = "error", reason = parse_error, source = path }
        failed = failed + 1
      end
    else
      local status = FS.error_status(err)
      errors[resource] = { status = status, reason = err and err.message, source = path }
      if status == "denied" then
        denied = denied + 1
      elseif status == "error" then
        failed = failed + 1
      end
    end
  end
  local finished = Common.now_ns(context)
  if success == 0 then
    local status = denied == #self.resources and "denied"
      or failed > 0 and "error" or "unavailable"
    return Common.result(status, finished, nil, {
      quality = status,
      reason = "no_pressure_resources_readable",
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.base_path,
      error = errors,
    })
  end
  data.errors = errors
  return Common.result("ok", finished, data, {
    -- Readable PSI values remain exact even when another resource is absent;
    -- per-resource errors carry the partial capability information.
    quality = success < #self.resources and "partial" or "fresh",
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = self.base_path,
  })
end

return Pressure
