-- Counting-only memory PMUs through the kernel; no external helper process.
local Perf = require("wtop.inspectors.perf_bandwidth")
local Bandwidth = require("wtop.inspectors.ram_bandwidth")
local FS = require("wtop.linux.fs")
local Json = require("wtop.format.json")
local Native = require("wtop.native")
local M = {}
M.__index = M
local BASE = "/sys/bus/event_source/devices"
local LIMIT = 1024

local function integer(value)
    return type(value) == "number" and math.type(value) == "integer"
end
local function identifier(value)
    return type(value) == "string" and #value > 0 and #value <= 255
        and value:match("^[A-Za-z0-9_][A-Za-z0-9_.%-]*$") ~= nil
end
local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- The ABI describes masks, so source-value bits map to increasing target bits.
-- Overlapping attributes are allowed only when their assigned bits agree.
function M.encode(descriptor, formats)
    if type(descriptor) ~= "string" or #descriptor == 0 or #descriptor > 4096
        or type(formats) ~= "table" then return nil end
    descriptor = trim(descriptor)
    if descriptor:sub(1,1) == "," or descriptor:sub(-1) == "," or descriptor:find(",%s*,") then return nil end
    local result, masks, seen, count = { config = 0, config1 = 0, config2 = 0 }, {}, {}, 0
    for token in descriptor:gmatch("[^,]+") do
        local key, raw = trim(token):match("^([%w_]+)=([^%s]+)$")
        if not key or seen[key] then return nil end
        seen[key], count = true, count + 1
        if count > 64 then return nil end
        local hex = raw:match("^0[xX]([%da-fA-F]+)$")
        if hex then hex = hex:gsub("^0+", ""); if hex == "" then hex = "0" end end
        if not hex and not raw:match("^%d+$") or hex and #hex > 16 then return nil end
        if not hex then
            local decimal = raw:gsub("^0+", "")
            if #decimal > 19 or #decimal == 19 and decimal > "9223372036854775807" then return nil end
        end
        local value = tonumber(hex or raw, hex and 16 or 10)
        if not integer(value) or not hex and value < 0 then return nil end
        local format = formats[key]
        if type(format) ~= "string" or #format > 1024 then return nil end
        local target, ranges = trim(format):match("^(config[12]?):([%d,%-%s]+)$")
        if not target or ranges:sub(1,1) == "," or ranges:sub(-1) == "," or ranges:find(",%s*,") then return nil end
        local positions, used = {}, {}
        for part in ranges:gmatch("[^,]+") do
            local range = trim(part)
            local first, last = range:match("^(%d+)%-(%d+)$")
            if not first then first, last = range:match("^(%d+)$"), range:match("^(%d+)$") end
            first, last = tonumber(first), tonumber(last)
            if not first or not last or first > last or last > 63 then return nil end
            for bit = first, last do
                if used[bit] then return nil end
                used[bit], positions[#positions+1] = true, bit
            end
        end
        table.sort(positions)
        if #positions == 0 or #positions < 64 and value >> #positions ~= 0 then return nil end
        local assigned, mask = 0, 0
        for index, bit in ipairs(positions) do
            mask = mask | 1 << bit
            assigned = assigned | ((value >> (index-1)) & 1) << bit
        end
        local overlap = (masks[target] or 0) & mask
        if ((result[target] ~ assigned) & overlap) ~= 0 then return nil end
        result[target], masks[target] = result[target] | assigned, (masks[target] or 0) | mask
    end
    return count > 0 and result or nil
end

function M.new(options)
    options = options or {}
    return setmetatable({ fs = options.fs or FS.new(), native = options.native or Native,
        selector = Perf.new({ max_events = options.max_events or 64 }), base = options.base or BASE }, M)
end

local function failure(status, reason)
    return { status = status, reason = reason, provider = "perf_event_open",
        permission = "CAP_PERFMON_may_be_required" }
end

function M:read(request)
    request = request or {}
    if request.safe_mode then return failure("unavailable", "safe_mode") end
    if type(self.native.read_perf_counts) ~= "function" then
        return failure("unavailable", "unsupported_on_this_platform")
    end
    local duration = request.duration_ms or 250
    if not integer(duration) or duration < 50 or duration > 2000 then
        return failure("error", "invalid_perf_reader_result")
    end
    local specs, truncated = self.selector:_events(request.pmus)
    if #specs == 0 then return failure("unavailable", "supported_memory_events_not_found") end
    local pmus, probes, checks = {}, {}, {}
    local function capture(path, maximum)
        if checks[path] ~= nil then return checks[path] end
        local value = self.fs:read(path, maximum or 4096)
        if not value then return nil end
        checks[path] = value
        return value
    end
    for index, pmu in ipairs(request.pmus or {}) do
        if index > 256 then break end
        if type(pmu) ~= "table" or not identifier(pmu.name or pmu.id) or pmus[pmu.name or pmu.id] then
            return failure("unavailable", "memory_pmu_identity_changed")
        end
        pmus[pmu.name or pmu.id] = pmu
    end
    local configuration, evidence = {}, {}
    for _, spec in ipairs(specs) do
        local pmu = pmus[spec.pmu]
        local source = self.base .. "/" .. spec.pmu
        if not Bandwidth.matches_pmu(spec.pmu) or type(pmu) ~= "table" or pmu.source ~= source
            or not integer(pmu.type) or pmu.type < 6 then
            return failure("unavailable", "memory_pmu_identity_changed")
        end
        local type_text = capture(source .. "/type", 64)
        local cpumask = capture(source .. "/cpumask", 65536)
        if tonumber(trim(type_text)) ~= pmu.type or not cpumask then
            return failure("unavailable", "memory_pmu_identity_changed")
        end
        local cpus = Bandwidth.parse_cpu_list(cpumask)
        if not cpus or #cpus == 0 or not spec.expected_cpus or #cpus ~= #spec.expected_cpus then
            return failure("unavailable", "perf_reader_partial_bandwidth")
        end
        table.sort(cpus)
        for index, cpu in ipairs(cpus) do
            if cpu ~= spec.expected_cpus[index] then return failure("unavailable", "memory_pmu_identity_changed") end
        end
        local descriptor = capture(source .. "/events/" .. spec.event)
        local declared = pmu.events[spec.event]
        local current = Bandwidth.parse_event_descriptor(descriptor)
        for key, value in pairs(declared) do
            if key ~= "scale" and key ~= "unit" and current[key] ~= value then
                return failure("unavailable", "memory_pmu_identity_changed")
            end
        end
        for key in pairs(current) do
            if declared[key] == nil then return failure("unavailable", "memory_pmu_identity_changed") end
        end
        local formats = {}
        for key in tostring(descriptor):gmatch("([%w_]+)%s*=") do
            if not identifier(key) then return failure("error", "invalid_perf_reader_result") end
            formats[key] = capture(source .. "/format/" .. key, 1024)
        end
        local encoded = M.encode(descriptor, formats)
        if not encoded then return failure("unavailable", "supported_memory_events_not_found") end
        -- Event units and scaling are part of the identity too.
        for _, suffix in ipairs({ ".scale", ".unit" }) do
            local path = source .. "/events/" .. spec.event .. suffix
            probes[path] = self.fs:read(path, 256) or false
        end
        local scale = probes[source .. "/events/" .. spec.event .. ".scale"]
        local unit = probes[source .. "/events/" .. spec.event .. ".unit"]
        local numeric_scale = scale and tonumber(trim(scale)) or nil
        if scale and (not numeric_scale or numeric_scale <= 0 or numeric_scale == math.huge)
            or numeric_scale ~= declared.scale or (unit and trim(unit) or nil) ~= declared.unit then
            return failure("unavailable", "memory_pmu_identity_changed")
        end
        for _, cpu in ipairs(cpus) do
            if #configuration == LIMIT then truncated = true break end
            configuration[#configuration+1] = { type = pmu.type, cpu = cpu,
                config = encoded.config, config1 = encoded.config1, config2 = encoded.config2 }
            evidence[#evidence+1] = { spec = spec, cpu = cpu, source = source }
        end
    end
    local measured, native_error = self.native.read_perf_counts(configuration, duration)
    if measured == nil and integer(native_error) then return failure("error", "read_failed") end
    if type(measured) ~= "table" or type(measured.samples) ~= "table" or #measured.samples ~= #configuration
        or not integer(measured.started_ns) or measured.started_ns < 0
        or not integer(measured.finished_ns) or measured.finished_ns < measured.started_ns then
        return failure("error", "invalid_perf_reader_result")
    end
    for index = 1, #configuration do
        if type(measured.samples[index]) ~= "table" then return failure("error", "invalid_perf_reader_result") end
    end
    for path, old in pairs(checks) do
        if self.fs:read(path, 65536) ~= old then return failure("unavailable", "memory_pmu_identity_changed") end
    end
    for path, old in pairs(probes) do
        if (self.fs:read(path, 256) or false) ~= old then return failure("unavailable", "memory_pmu_identity_changed") end
    end
    local rows, totals, directions, valid, denied, failed = Json.array({}), { read = 0, write = 0 }, {}, 0, false, false
    for index, sample in ipairs(measured.samples) do
        local item = evidence[index]
        local spec, rate, percent = item.spec
        if sample.errno == nil and integer(sample.count) and sample.count >= 0 and integer(sample.running_ns)
            and sample.running_ns > 0 and integer(sample.enabled_ns) and sample.enabled_ns >= sample.running_ns then
            rate = sample.count * (spec.bytes_per_count + 0.0) * 1e9 / sample.running_ns
            percent = sample.running_ns * 100.0 / sample.enabled_ns
            if rate ~= rate or rate == math.huge or totals[spec.direction] + rate == math.huge then rate = nil end
        end
        local unavailable = sample.errno == nil or sample.errno == 1 or sample.errno == 13
            or sample.errno == 19 or sample.errno == 22 or sample.errno == 34 or sample.errno == 95
        failed = failed or not unavailable
        local quality = rate and (percent < 99.995 and "estimated" or "fresh")
            or unavailable and "unavailable" or "error"
        if rate then
            valid = valid + 1; totals[spec.direction] = totals[spec.direction] + rate
            directions[spec.direction] = true
        end
        denied = denied or sample.errno == 1 or sample.errno == 13
        rows[#rows+1] = { pmu = spec.pmu, event = spec.event, direction = spec.direction,
            instance = "CPU" .. item.cpu, cpu_id = item.cpu, source = item.source,
            bytes_per_second = rate, count = rate and sample.count or nil,
            bytes_per_count = rate and spec.bytes_per_count or nil, unit = rate and "count" or nil,
            runtime_ns = rate and sample.running_ns or nil, enabled_ns = rate and sample.enabled_ns or nil,
            running_percent = rate and percent or nil, instance_expected = true, quality = quality,
            reason = not rate and "perf_stat_invalid_counts" or quality == "estimated" and "perf_reader_partial_bandwidth" or nil }
    end
    if valid == 0 then
        local result = failure(denied and "denied" or failed and "error" or "unavailable",
            denied and "perf_event_permission_denied" or failed and "read_failed" or "memory_events_not_counted")
        result.counter_samples, result.counter_samples_total, result.counter_samples_truncated = rows, #rows, truncated
        return result
    end
    local partial = truncated or valid < #rows or not directions.read or not directions.write
    for _, row in ipairs(rows) do partial = partial or row.quality ~= "fresh" end
    return { status = "ok", read_bytes_per_second = directions.read and totals.read or nil,
        write_bytes_per_second = directions.write and totals.write or nil,
        estimated = partial, provider = "perf_event_open", formula_version = "perf-event-counting-v1",
        permission = "CAP_PERFMON_may_be_required", duration_ns = measured.finished_ns - measured.started_ns,
        counter_samples = rows, counter_samples_total = #rows, counter_samples_truncated = truncated }
end

return M
