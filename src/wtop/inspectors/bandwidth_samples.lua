-- Bounded public evidence for one on-demand perf read. Control CPUs identify
-- counter instances, not DIMM channels or the CPUs that generated the traffic.
local Json = require("wtop.format.json")
local M = { LIMIT = 1024 }
local reasons = { memory_events_not_supported = true, memory_events_not_counted = true,
  perf_stat_invalid_counts = true, perf_reader_partial_bandwidth = true }

local function finite(value)
  return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

local function identifier(value)
  return type(value) == "string" and #value > 0 and #value <= 255
    and value:match("^[A-Za-z0-9_][A-Za-z0-9_.%-]*$") ~= nil
end

function M.direction_for(name)
  name = tostring(name or ""):lower()
  if name == "data_read" or name == "cas_count_read"
      or name:find("rdcas", 1, true) or name:find("cas_count_rd", 1, true) then return "read" end
  if name == "data_write" or name == "cas_count_write"
      or name:find("wrcas", 1, true) or name:find("cas_count_wr", 1, true) then return "write" end
end

function M.copy(input, reported_total, truncated, pmus)
  if type(input) ~= "table" then return nil end
  local allowed = {}
  for index, pmu in ipairs(pmus or {}) do
    if index > 256 then break end
    local id = pmu.name or pmu.id
    if identifier(id) then
      local expected
      if type(pmu.cpus) == "table" and #pmu.cpus > 0 and #pmu.cpus <= 8192 then
        expected = {}
        for _, cpu in ipairs(pmu.cpus) do
          if not finite(cpu) or cpu % 1 ~= 0 or cpu > 1048575 or expected[cpu] then expected = nil break end
          expected[cpu] = true
        end
      end
      allowed[id] = allowed[id] == nil and { pmu = pmu, expected = expected } or false
    end
  end
  local output, seen = Json.array({}), {}
  local total = finite(reported_total) and reported_total % 1 == 0 and reported_total <= 2147483647
    and math.max(#input, reported_total) or #input
  for index = 1, math.min(#input, M.LIMIT) do
    local raw = input[index]
    local entry = type(raw) == "table" and allowed[raw.pmu]
    local pmu = type(entry) == "table" and entry.pmu
    if type(pmu) == "table" and identifier(raw.event) and identifier(raw.instance)
        and type(pmu.events) == "table" and pmu.events[raw.event] ~= nil
        and (raw.direction == "read" or raw.direction == "write")
        and M.direction_for(raw.event) == raw.direction then
      local key = raw.pmu .. "\0" .. raw.event .. "\0" .. raw.instance
      if not seen[key] then
        seen[key] = true
        local cpu = tonumber(raw.instance:match("^CPU(%d+)$"))
        if cpu and (cpu > 1048575 or "CPU" .. cpu ~= raw.instance) then cpu = nil end
        local expected
        if entry.expected then expected = entry.expected[cpu] == true end
        local rate = finite(raw.bytes_per_second) and raw.bytes_per_second or nil
        local valid = rate ~= nil and finite(raw.count) and finite(raw.runtime_ns) and raw.runtime_ns > 0
          and (raw.running_percent == nil or finite(raw.running_percent)
            and raw.running_percent > 0 and raw.running_percent <= 100.01)
          and expected ~= false and (raw.quality == "fresh" or raw.quality == "estimated")
        local quality = valid and (raw.quality == "estimated" or expected == nil
          or raw.running_percent == nil or raw.running_percent < 99.995) and "estimated"
          or valid and "fresh" or raw.quality == "error" and "error" or "unavailable"
        local reason = type(raw.reason) == "string" and reasons[raw.reason] and raw.reason or nil
        if quality == "estimated" then reason = reason or "perf_reader_partial_bandwidth"
        elseif not valid then reason = reason or "perf_stat_invalid_counts" end
        output[#output + 1] = {
          pmu = raw.pmu, event = raw.event, instance = raw.instance, cpu_id = cpu,
          direction = raw.direction, instance_expected = expected, source = pmu.source,
          bytes_per_second = valid and rate or nil, count = valid and raw.count or nil,
          runtime_ns = valid and raw.runtime_ns or nil,
          running_percent = valid and raw.running_percent or nil,
          unit = valid and type(raw.unit) == "string" and #raw.unit <= 64
            and not raw.unit:find("[%c]") and raw.unit or nil,
          quality = quality, reason = reason,
        }
      end
    end
  end
  return output, total, truncated == true or #output < total
end

return M
