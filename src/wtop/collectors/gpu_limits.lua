local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")

local M = {}
local I915 = {
    { "pl1", "pl1" }, { "pl2", "pl2" }, { "pl4", "pl4" },
    { "thermal", "thermal" }, { "prochot", "prochot" }, { "ratl", "ratl" },
    { "vr_thermal", "vr_thermalert" }, { "vr_current", "vr_tdc" },
}

local function read(fs, path)
    local text, err = fs:read(path, 64)
    if not text then return nil, err end
    text = Common.trim(text)
    if text == "0" then return false end
    if text == "1" then return true end
    return nil, { kind = "parse_error", message = "invalid_limit_status" }
end

local function round(fs, base)
    local values, issues, present = {}, {}, false
    for _, spec in ipairs({ { "status", "status" }, table.unpack(I915) }) do
        local path = base .. "/throttle_reason_" .. spec[2]
        local value, err = read(fs, path)
        values[spec[1]] = value
        if value ~= nil then present = true end
        if err and err.kind ~= "missing" and err.kind ~= "unavailable" then
            present = true
            issues[#issues + 1] = { field = spec[1], source = path,
                status = FS.error_status(err), reason = err.message }
        end
    end
    return values, issues, present
end

-- i915 exposes one current hardware status per GT. Two matching rounds avoid
-- promoting a mixture of flags while the throttle state is changing.
function M.i915(fs, class_path, max_domains, now_ns)
    local root = class_path .. "/gt"
    local names, list_error, cut = fs:list(root, max_domains + 1)
    local result = { domains = {}, truncated = cut == true, source_kind = "i915_sysfs" }
    if not names then
        if list_error and list_error.kind == "denied" then result.quality = "denied" end
        return result
    end
    local ordered = {}
    for _, name in ipairs(names) do
        local id = type(name) == "string" and name:match("^gt(%d+)$")
        if id and tonumber(id) <= 2147483647 and tostring(tonumber(id)) == id then
            ordered[#ordered + 1] = name
        end
    end
    table.sort(ordered, function(a,b) return tonumber(a:sub(3)) < tonumber(b:sub(3)) end)
    result.truncated = result.truncated or #ordered > max_domains
    for index = 1, math.min(#ordered, max_domains) do
        local name = ordered[index]
        local base = root .. "/" .. name
        local first, first_issues, present = round(fs, base)
        if present then
            local second, issues = round(fs, base)
            local domain = { id = name, scope = "gpu_gt", source_kind = "i915_sysfs",
                source = base, observed_at_ns = type(now_ns) == "function" and now_ns() or now_ns,
                reasons = {}, issues = issues, quality = "fresh" }
            local stable = first.status == second.status
            local known, any = 0, false
            for _, spec in ipairs(I915) do
                local id = spec[1]
                if first[id] ~= second[id] then stable = false end
                if second[id] ~= nil then
                    known = known + 1
                    any = any or second[id]
                    domain.reasons[#domain.reasons + 1] = { id = id, active = second[id] }
                end
            end
            if second.status == false and any then stable = false end
            if not stable then
                domain.quality = (#issues > 0 or #first_issues > 0) and "partial" or "gap"
                -- Individual reads stay observable through issues; they do not
                -- become a simultaneous current state after a failed round.
                for _, reason in ipairs(domain.reasons) do reason.active = nil end
            else
                if second.status ~= nil then domain.active = second.status
                elseif any then domain.active = true end
                if known < #I915 or second.status == nil or (second.status and not any)
                    or #issues > 0 or #first_issues > 0 then
                    domain.quality = "partial"
                end
                if known == 0 and domain.active == nil then
                    local denied = false
                    for _, issue in ipairs(issues) do denied = denied or issue.status == "denied" end
                    if denied then domain.quality = "denied" end
                end
            end
            if #first_issues > 0 and #issues == 0 then domain.issues = first_issues end
            result.domains[#result.domains + 1] = domain
        end
    end
    result.quality = #result.domains > 0 and (result.truncated and "partial" or "fresh") or "unavailable"
    for _, domain in ipairs(result.domains) do
        if domain.quality ~= "fresh" then result.quality = "partial" end
    end
    return result
end

-- NVML returns a coherent 64-bit current mask in one call. Capability bits
-- are separate: a zero unsupported bit is not proof of an inactive limiter.
local NVML_REASONS = {
    { "idle", 0 }, { "application_clock", 1 }, { "software_power_cap", 2 },
    { "hardware_slowdown", 3 }, { "sync_boost", 4 }, { "software_thermal", 5 },
    { "hardware_thermal", 6 }, { "power_brake", 7 }, { "display_clock", 8 },
    { "board_limit", 9 }, { "reliability", 10 },
}
local function mask(value)
    if type(value) ~= "string" or not value:match("^0x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then return nil end
    return tonumber(value:sub(3), 16)
end
local function nvml_quality(status)
    if status == 3 or status == 13 then return "unavailable" end
    if status == 4 then return "denied" end
    if status == 1 or status == 9 or status == 15 then return "gap" end
    return "error"
end
function M.nvml(data, observed_at_ns)
    if type(data) ~= "table" then return nil end
    local domain = {
        id = "clock_events", scope = "gpu_clock", source_kind = "nvml_clock_events",
        source = Common.safe_text(data.source or "NVML clock events", 96),
        supported_source = Common.safe_text(data.supported_source or "NVML supported clock events", 96),
        status_code = data.status_code, supported_status_code = data.supported_status_code,
        observed_at_ns = observed_at_ns, reasons = {},
    }
    local active = data.status_code == 0 and mask(data.raw_hex) or nil
    local supported = data.supported_status_code == 0 and mask(data.supported_hex) or nil
    -- All ones is not a usable current/capability report. Keep its raw form
    -- for diagnosis without presenting every known reason as asserted.
    if active == -1 then active = nil end
    if supported == -1 then supported = nil end
    domain.raw_hex = type(data.raw_hex) == "string" and data.raw_hex:sub(1, 18):lower() or nil
    if supported ~= nil then domain.supported_hex = string.format("0x%016x", supported) end
    if active == nil then
        domain.quality = data.status_code == 0 and "error" or nvml_quality(data.status_code)
        domain.reason = data.status_code == 0 and "nvml_invalid_clock_events" or "nvml_clock_events_unavailable"
    else
        domain.raw_hex = string.format("0x%016x", active)
        domain.active = active ~= 0
        domain.unknown_status_hex = string.format("0x%016x", active & ~0x7ff)
        domain.quality = active & ~0x7ff ~= 0 and "partial" or "fresh"
        if supported ~= nil then
            domain.unsupported_status_hex = string.format("0x%016x", active & ~supported)
            if active & ~supported ~= 0 then domain.quality = "partial" end
        end
    end
    for _, spec in ipairs(NVML_REASONS) do
        local bit = 1 << spec[2]
        local supported_bit
        if supported ~= nil then supported_bit = supported & bit ~= 0 end
        local reason = { id = spec[1], supported = supported_bit }
        if active ~= nil then
            if active & bit ~= 0 then reason.active = true
            elseif supported_bit == true then reason.active = false end
        end
        domain.reasons[#domain.reasons + 1] = reason
    end
    return domain
end

local SYSMAN_REASONS = {
    "pl1", "pl2", "pl4", "thermal", "psu_alert", "software_frequency_range",
    "hardware_frequency_range", "voltage_limit", "thermal_conditions", "power_constraint",
}
function M.levelzero(data, observed_at_ns)
    local domains = {}
    for index, entry in ipairs(data or {}) do
        if index > 32 then break end
        local active = entry.throttle_quality == "fresh" and mask(entry.throttle_raw_hex) or nil
        local domain = {
            id = "sysman-frequency:" .. tostring(entry.index or index - 1), scope = "gpu_clock",
            source_kind = "levelzero_frequency", source = "zesFrequencyGetState",
            observed_at_ns = observed_at_ns, reasons = {}, raw_hex = entry.throttle_raw_hex,
            quality = active ~= nil and "fresh" or "unavailable",
        }
        if active ~= nil and active >= 0 and active < 0xffffffff then
            domain.active = active ~= 0
            domain.unknown_status_hex = string.format("0x%016x", active & ~0x3ff)
            if active & ~0x3ff ~= 0 then domain.quality = "partial" end
        elseif active ~= nil then active = nil; domain.quality = "error" end
        for bit, name in ipairs(SYSMAN_REASONS) do
            local reason = { id = name }
            if active ~= nil then reason.active = active & (1 << (bit - 1)) ~= 0 end
            domain.reasons[#domain.reasons + 1] = reason
        end
        domains[#domains + 1] = domain
    end
    return domains
end

return M
