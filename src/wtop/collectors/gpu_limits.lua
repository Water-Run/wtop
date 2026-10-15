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

return M
