local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local CPUInfo = require("wtop.collectors.cpu_info")
local FS = require("wtop.linux.fs")

local CPPC = {}
CPPC.__index = CPPC
local FIELDS = {
  { "highest_perf", "highest_performance" },
  { "nominal_perf", "nominal_performance" },
  { "lowest_nonlinear_perf", "lowest_nonlinear_performance" },
  { "lowest_perf", "lowest_performance" },
  { "guaranteed_perf", "guaranteed_performance" },
  { "reference_perf", "reference_performance" },
  -- These ACPI frequencies are MHz, unlike CPUFreq's kHz attributes.
  { "nominal_freq", "nominal_frequency_hz", 1000000 },
  { "lowest_freq", "lowest_frequency_hz", 1000000 },
}

local function absent(err)
  return err and (err.kind == "missing" or err.kind == "unavailable")
end

local function issue(issues, field, path, err)
  issues[#issues + 1] = { field=field, source=path,
    status=FS.error_status(err), reason=err and err.message or "invalid_value" }
end

local function integer(fs, path, issues, field, scale)
  local text, err = fs:read(path, 64)
  if not text then
    if not absent(err) then issue(issues, field, path, err) end
    return nil
  end
  local token = #text <= 64 and Common.trim(text)
  if token and token:match("^%d+$") then
    token = token:gsub("^0+", "")
    if token == "" then token = "0" end
    local value = tonumber(token)
    if value and value <= (scale and 1000000 or 4294967295) then
      if scale then return value > 0 and value * scale or nil end
      return value
    end
  end
  issue(issues, field, path, {kind="parse_error", message="invalid_value"})
end

local function roster(self, fs)
  local names, err, cut = fs:list(self.base_path, self.max_entries + 1)
  if not names then return nil, err end
  local ids, seen = {}, {}
  for index = 1, math.min(#names, self.max_entries) do
    local name = names[index]
    local token = type(name) == "string" and name:match("^cpu(%d+)$")
    local id = token and tonumber(token)
    if id and id <= 1048575 and tostring(id) == token and not seen[id] then
      ids[#ids + 1] = id; seen[id] = true
    end
  end
  table.sort(ids)
  local truncated = cut == true or #names > self.max_entries or #ids > self.max_cpus
  while #ids > self.max_cpus do ids[#ids] = nil end
  local text, read_error = fs:read(self.base_path .. "/online", 65536)
  local online
  if text then
    online = #text <= 65536 and CPUInfo.parse_cpu_list(Common.trim(text), 8192, 1048575)
    if not online then return nil, {kind="parse_error", message="invalid_value"} end
  elseif not absent(read_error) then return nil, read_error end
  local online_set = {}
  for _, id in ipairs(online or {}) do online_set[id] = true end
  local identity = {}
  for _, id in ipairs(ids) do identity[#identity + 1] = tostring(id) end
  identity[#identity + 1] = online and table.concat(online, ",") or "unknown"
  return { ids=ids, online=online and online_set, truncated=truncated,
    identity=table.concat(identity, ";") }
end

function CPPC.new(options)
  options = options or {}
  if type(options) ~= "table" then error("CPPC options must be a table", 2) end
  return setmetatable({ id="cppc", _method_style=true, fs=options.fs or FS.default,
    base_path=Common.absolute_path("base_path", options.base_path, "/sys/devices/system/cpu"),
    max_cpus=Common.positive_integer("max_cpus", options.max_cpus, 256, 8192),
    max_entries=Common.positive_integer("max_entries", options.max_entries, 8192, 65536),
    default_interval_ms=Common.positive_integer("interval_ms", options.interval_ms, 30000),
  }, CPPC)
end

function CPPC:probe(context)
  local fs = Common.fs(context, self.fs)
  local before, err = roster(self, fs)
  if not before then
    return FS.error_status(err) == "denied" and Capability.denied(err and err.message)
      or Capability.unavailable("cppc_unavailable")
  end
  local denied = false
  for _, id in ipairs(before.ids) do
    if not before.online or before.online[id] then
      local path = self.base_path .. "/cpu" .. id .. "/acpi_cppc"
      local names, why = fs:list(path, 32)
      if names then return Capability.available({source=self.base_path}) end
      denied = denied or FS.error_status(why) == "denied"
    end
  end
  return denied and Capability.denied("cppc_unavailable") or Capability.unavailable("cppc_unavailable")
end

function CPPC:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local before, err = roster(self, fs)
  if not before then return Common.error_result(err, started, self.base_path) end
  local data = { schema="dev.waterrun.wtop.cppc/v1", cpus={}, source=self.base_path,
    truncated=before.truncated, consistent=true }
  local partial, denied, readable = before.truncated, false, false
  for _, id in ipairs(before.ids) do
    if not before.online or before.online[id] then
      local base = self.base_path .. "/cpu" .. id .. "/acpi_cppc"
      local values, issues = {}, {}
      for _, field in ipairs(FIELDS) do
        values[field[2]] = integer(fs, base .. "/" .. field[1], issues, field[2], field[3])
      end
      -- The kernel also returns zero when the optional guaranteed-performance
      -- register is not implemented. It does not establish a zero guarantee.
      if values.guaranteed_performance == 0 then values.guaranteed_performance = nil end
      if next(values) or #issues > 0 then
        readable = readable or next(values) ~= nil
        local highest = integer(fs, base .. "/highest_perf", issues, "highest_performance")
        local nominal = integer(fs, base .. "/nominal_perf", issues, "nominal_performance")
        local consistent = highest == values.highest_performance and nominal == values.nominal_performance
        local previous
        for _, name in ipairs({"highest_performance","nominal_performance",
            "lowest_nonlinear_performance","lowest_performance"}) do
          local value = values[name]
          if value == nil or value == 0 or previous and value > previous then
            issue(issues, name, base, {kind="parse_error", message="invalid_value"})
          end
          previous = value or previous
        end
        local guaranteed = values.guaranteed_performance
        if guaranteed and (values.lowest_performance and guaranteed < values.lowest_performance
            or values.nominal_performance and guaranteed > values.nominal_performance) then
          issue(issues, "guaranteed_performance", base, {kind="parse_error", message="invalid_value"})
        end
        if values.lowest_frequency_hz and values.nominal_frequency_hz
            and values.lowest_frequency_hz > values.nominal_frequency_hz then
          issue(issues, "frequency_range", base, {kind="parse_error", message="invalid_value"})
        end
        for _, failure in ipairs(issues) do denied = denied or failure.status == "denied" end
        values.id, values.source, values.issues = id, base, issues
        values.consistent = consistent
        data.consistent = data.consistent and consistent
        values.quality = not consistent and "gap" or #issues > 0 and "partial" or "fresh"
        values.observed_at_ns = Common.now_ns(context)
        partial = partial or values.quality ~= "fresh"
        data.cpus[#data.cpus + 1] = values
      end
    end
  end
  local after = roster(self, fs)
  if not after or after.identity ~= before.identity or after.truncated ~= before.truncated then
    data.consistent, partial = false, true
    for _, row in ipairs(data.cpus) do row.consistent, row.quality = false, "gap" end
  end
  local finished = Common.now_ns(context)
  local status = #data.cpus > 0 and "ok" or "unavailable"
  local result = Common.result(status, finished, data, {
    quality=status ~= "ok" and "unavailable" or partial and "partial" or "fresh",
    reason=status ~= "ok" and "cppc_unavailable" or partial and "cppc_data_incomplete" or nil,
    source=self.base_path, duration_ns=Common.elapsed_ns(finished, started) or 0,
  })
  result.capability = readable and Capability.available({source=self.base_path})
    or denied and Capability.denied("cppc_unavailable") or Capability.unavailable("cppc_unavailable")
  return result
end

return CPPC
