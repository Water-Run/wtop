-- Used only by the explicitly opened RAM monitor's isolated Linux reader.
local Inspector = require("wtop.inspectors.ram_bandwidth")
local Direct = require("wtop.inspectors.native_bandwidth")
local Capability = require("wtop.core.capability")
local M = { id = "ram_bandwidth", default_interval_ms = 1000 }
M.__index = M

local function plain(value, depth, remaining)
    if type(value) ~= "table" then return value end
    assert(depth < 32 and remaining[1] > 0, "bandwidth_result_size")
    remaining[1] = remaining[1] - 1
    local output = {}
    for key, child in pairs(value) do output[key] = plain(child, depth+1, remaining) end
    return output
end

function M.new(options)
    options = options or {}
    assert(options.pmu == nil or Inspector.matches_pmu(options.pmu), "invalid memory PMU")
    assert(options.type == nil or type(options.type) == "number" and options.type >= 6
        and options.type % 1 == 0, "invalid memory PMU type")
    local reader = Direct.new(options)
    return setmetatable({ id = M.id, _method_style = true, default_interval_ms = 1000,
        inspector = Inspector.new({ fs = options.fs, perf_reader = function(request)
            return reader:read(request)
        end }),
        entity = options.pmu and { id = options.pmu, name = options.pmu,
            type = options.type, measurement_scope = "controller_pmu" }
            or { id = "system-memory", name = "System aggregate", measurement_scope = "system" } }, M)
end

function M:probe(context)
    if context.safe_mode then return Capability.unavailable("safe_mode") end
    return self.inspector:probe(context)
end

function M:sample(context)
    local inspection
    if context.safe_mode then
        inspection = require("wtop.inspectors.model").result("unavailable", nil, {}, {
            timestamp_ns = context.clock:now_ns(), reason = "safe_mode", provider = "perf_event_open" })
    else inspection = self.inspector:inspect(context, self.entity) end
    return { status = inspection.status, quality = inspection.quality, reason = inspection.reason,
        timestamp_ns = inspection.timestamp_ns, duration_ns = inspection.duration_ns,
        data = { inspection = plain(inspection, 0, { 65536 }) } }
end

return M
