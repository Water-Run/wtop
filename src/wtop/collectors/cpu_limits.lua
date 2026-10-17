local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local CPUInfo = require("wtop.collectors.cpu_info")
local FS = require("wtop.linux.fs")
local Native = require("wtop.native")

local CPU = {}
CPU.__index = CPU

-- Intel SDM Vol.4, Table 2-39, 335592-085 (Oct 2024), pp.2-354,
-- 2-361..364. These Core models use this layout; Atom's 0x64f differs.
local MODELS = { [0x4e]=true, [0x5e]=true, [0x8e]=true, [0x9e]=true,
    [0xa5]=true, [0xa6]=true, [0x7d]=true, [0x7e]=true, [0x8c]=true,
    [0x8d]=true, [0x97]=true, [0x9a]=true, [0xba]=true, [0xb7]=true, [0xbf]=true }
local REASONS = {
    { "prochot", 0 }, { "thermal", 1 }, { "residency", 4 }, { "ratl", 5 },
    { "vr_thermal", 6 }, { "vr_current", 7 }, { "electrical", 8 },
    { "pl1", 10 }, { "pl2_pl3", 11 }, { "max_turbo", 12 }, { "turbo_transition", 13 },
}
local MASK = 0x3df3

local function integer(text)
    text = Common.trim(text)
    if type(text) ~= "string" or not text:match("^%d+$") then return nil end
    local n = tonumber(text)
    if n and math.type(n) == "integer" and n <= 2147483647 then return n end
end

function CPU.decode(bytes)
    if type(bytes) ~= "string" or #bytes ~= 8 then return nil end
    local low, high = string.unpack("<I4I4", bytes)
    local value = { raw_hex = string.format("0x%08x%08x", high, low), reasons = {},
        unknown_status_mask = (low & 0xffff) & ~MASK,
        unknown_log_mask = (low >> 16) & ~MASK, reserved_high = high,
        quality = "fresh" }
    local active = (low & MASK) ~= 0
    if active or (value.unknown_status_mask == 0 and high == 0) then value.active = active end
    if value.unknown_status_mask ~= 0 or value.unknown_log_mask ~= 0 or high ~= 0 then
        value.quality = "partial"
    end
    for _, spec in ipairs(REASONS) do
        value.reasons[#value.reasons + 1] = { id = spec[1],
            active = (low & (1 << spec[2])) ~= 0,
            logged = (low & (1 << (spec[2] + 16))) ~= 0 }
    end
    return value
end

local function roster(self, fs)
    local online, err = fs:read(self.cpu_path .. "/online", 65536)
    if not online then return nil, err end
    local ids = CPUInfo.parse_cpu_list(Common.trim(online), 8192, 8191)
    if not ids then return nil, { kind = "parse_error", message = "invalid_online_cpu_list",
        path = self.cpu_path .. "/online" } end
    local content, read_error = fs:read(self.cpuinfo_path, 4 * 1024 * 1024)
    if not content then return nil, read_error end
    local sections, _, cut = CPUInfo.parse_cpuinfo(content, self.max_cpus + 1)
    if not sections then return nil, { kind = "parse_error", message = "invalid_cpuinfo",
        path = self.cpuinfo_path } end
    local by_id, duplicate = {}, {}
    for _, section in ipairs(sections) do
        local id = integer(section.processor)
        if id then
            if by_id[id] then duplicate[id] = true else by_id[id] = section end
        end
    end
    local groups, signature, partial = {}, {}, cut == true or #ids > self.max_cpus
    for index = 1, math.min(#ids, self.max_cpus) do
        local id = ids[index]
        local cpu = by_id[id]
        local package = integer(fs:read(self.cpu_path .. "/cpu" .. id .. "/topology/physical_package_id", 64))
        local vendor = cpu and cpu.vendor_id
        local family, model = cpu and integer(cpu["cpu family"]), cpu and integer(cpu.model)
        local supported = vendor == "GenuineIntel" and family == 6 and MODELS[model] == true and not duplicate[id]
        local key = package and "package:" .. package or "cpu:" .. id
        signature[#signature + 1] = table.concat({ id, package or "?", vendor or "?",
            family or "?", model or "?", duplicate[id] and "duplicate" or "" }, ":")
        local group = groups[key]
        if not group then
            group = { id = key, package_id = package, cpu_id = id, family = family,
                model = model, supported = supported, logical_cpu_ids = {} }
            groups[key] = group
        end
        if not supported or group.family ~= family or group.model ~= model then group.supported = false end
        group.logical_cpu_ids[#group.logical_cpu_ids + 1] = id
        partial = partial or package == nil or cpu == nil or duplicate[id] == true
    end
    return { groups = groups, signature = table.concat(signature, ";"), partial = partial,
        truncated = cut == true or #ids > self.max_cpus }
end

function CPU.new(options)
    options = options or {}
    if type(options) ~= "table" then error("CPU limit options must be a table", 2) end
    return setmetatable({ id = "cpu_limits", _method_style = true,
        fs = options.fs or FS.default,
        reader = options.reader or Native.read_cpu_perf_limits,
        cpu_path = Common.absolute_path("cpu_path", options.cpu_path, "/sys/devices/system/cpu"),
        cpuinfo_path = Common.absolute_path("cpuinfo_path", options.cpuinfo_path, "/proc/cpuinfo"),
        max_cpus = Common.positive_integer("max_cpus", options.max_cpus, 256, 8192),
        default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    }, CPU)
end

function CPU:probe(context)
    if type(self.reader) ~= "function" then return Capability.unavailable("cpu_limits_reader_unavailable") end
    local data, err = roster(self, Common.fs(context, self.fs))
    if not data then
        if FS.error_status(err) == "denied" then return Capability.denied("cpu_limits_data_incomplete") end
        return Capability.unavailable("cpu_limits_data_incomplete")
    end
    for _, group in pairs(data.groups) do
        if group.supported then return Capability.available({ source = "MSR_CORE_PERF_LIMIT_REASONS" }) end
    end
    return Capability.unavailable("cpu_limits_not_supported")
end

function CPU:sample(context)
    local started = Common.now_ns(context)
    if type(self.reader) ~= "function" then
        return Common.result("unavailable", started, nil, { quality = "unavailable",
            reason = "cpu_limits_reader_unavailable", source = "MSR_CORE_PERF_LIMIT_REASONS" })
    end
    local fs = Common.fs(context, self.fs)
    local before, err = roster(self, fs)
    if not before then
        local status = FS.error_status(err)
        return Common.result(status, Common.now_ns(context), nil, { quality = status,
            reason = "cpu_limits_data_incomplete", source = err and err.path or self.cpuinfo_path, error = err })
    end
    local data = { schema = "dev.waterrun.wtop.cpu-limits/v1", domains = {},
        denied_domains = 0, truncated = before.truncated, source = "MSR_CORE_PERF_LIMIT_REASONS" }
    local keys = {}
    for key, group in pairs(before.groups) do if group.supported then keys[#keys + 1] = key end end
    table.sort(keys)
    if #keys == 0 then
        return Common.result("unavailable", Common.now_ns(context), nil, {
            quality = "unavailable", reason = "cpu_limits_not_supported", source = data.source })
    end
    local discovered = 0
    for _ in pairs(before.groups) do discovered = discovered + 1 end
    data.domains_discovered, data.domains_supported = discovered, #keys
    data.roster_complete = not before.partial and not before.truncated
    data.domains_observed = 0
    data.coverage_complete = data.roster_complete and #keys == discovered
    local partial = before.partial or #keys < discovered
    for _, key in ipairs(keys) do
        local group = before.groups[key]
        local domain, message, denied, reader_cpu = nil, nil, false, group.cpu_id
        for _, id in ipairs(group.logical_cpu_ids) do
            local called, bytes, read_error, errno = pcall(self.reader, id)
            domain = called and CPU.decode(bytes) or nil
            if domain then reader_cpu = id; break end
            denied = denied or errno == 1 or errno == 13
            message = called and tostring(read_error or "invalid_cpu_msr_read") or "cpu_msr_read_failed"
        end
        local observed = domain ~= nil
        if observed then data.domains_observed = data.domains_observed + 1 end
        if not observed or type(domain.active) ~= "boolean"
            or (domain.unknown_status_mask or 0) ~= 0 or (domain.reserved_high or 0) ~= 0 then
            data.coverage_complete = false
        end
        if not domain then
            domain = { quality = denied and "denied" or "unavailable", reasons = {},
                reason = Common.safe_text(message or "invalid_cpu_msr_read", 256) }
            if denied then data.denied_domains = data.denied_domains + 1 end
        end
        domain.id, domain.cpu_id, domain.package_id = group.id, reader_cpu, group.package_id
        domain.family, domain.model = group.family, group.model
        domain.logical_cpu_ids = group.logical_cpu_ids
        domain.scope, domain.source_kind = "cpu_package", "intel_core_perf_limit_reasons"
        domain.source, domain.register = "/dev/cpu/" .. reader_cpu .. "/msr", 0x64f
        domain.observed_at_ns = Common.now_ns(context)
        partial = partial or domain.quality ~= "fresh"
        data.domains[#data.domains + 1] = domain
    end
    local after = roster(self, fs)
    if not after or after.signature ~= before.signature then
        partial = true
        data.coverage_complete = false
        data.roster_complete = false
        for _, domain in ipairs(data.domains) do
            domain.active, domain.quality, domain.reason = nil, "gap", "cpu_roster_changed"
            for _, reason in ipairs(domain.reasons) do reason.active, reason.logged = nil, nil end
        end
    end
    local finished = Common.now_ns(context)
    return Common.result("ok", finished, data, { quality = partial and "partial" or "fresh",
        reason = partial and "cpu_limits_data_incomplete" or nil, source = data.source,
        duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

return CPU
