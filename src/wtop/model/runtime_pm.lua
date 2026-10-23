-- PCI D-state, runtime-PM state, policy and accounting are distinct reports.
local Quality = require("wtop.model.quality")
local M = { STALE_AFTER_NS = 90 * 1000000000 }
local RUNTIME = { active=true, suspended=true, suspending=true, resuming=true,
    error=true, unsupported=true }
local PCI = { D0=true, D1=true, D2=true, D3hot=true, D3cold=true, unknown=true, error=true }
local FIELDS = { runtime_status=true, pci_state=true, control=true, active_time_ms=true,
    suspended_time_ms=true, autosuspend_delay_ms=true, d3cold_allowed=true, capture=true, identity=true }

local function nonnegative(value)
    return type(value) == "number" and math.tointeger(value) ~= nil and value >= 0
end

local function timestamp(value)
    return type(value) == "number" and value == value and value >= 0 and value <= math.maxinteger
end

function M.public(raw, source_quality, now_ns)
    if type(raw) ~= "table" then return nil end
    local result = { errors={} }
    if RUNTIME[raw.runtime_status] then result.runtime_status = raw.runtime_status end
    if PCI[raw.pci_state] then result.pci_state = raw.pci_state end
    if raw.control == "on" or raw.control == "auto" then result.control = raw.control end
    for _, key in ipairs({ "active_time_ms", "suspended_time_ms" }) do
        if nonnegative(raw[key]) then result[key] = raw[key] end
    end
    if math.type(raw.autosuspend_delay_ms) == "integer"
        and raw.autosuspend_delay_ms >= -2147483648 and raw.autosuspend_delay_ms <= 2147483647 then
        result.autosuspend_delay_ms = raw.autosuspend_delay_ms
    end
    if type(raw.d3cold_allowed) == "boolean" then result.d3cold_allowed = raw.d3cold_allowed end
    if type(raw.source) == "string" and #raw.source <= 4096 then result.source = raw.source end
    for _, key in ipairs({ "capture_started_ns", "capture_finished_ns", "observed_at_ns" }) do
        if timestamp(raw[key]) then result[key] = raw[key] end
    end
    result.state_changed = raw.state_changed == true
    result.status = (raw.status == "partial" or Quality.VALID_STATUS[raw.status]) and raw.status or "unavailable"
    for key, value in pairs(type(raw.errors) == "table" and raw.errors or {}) do
        if FIELDS[key] and (value == "gap" or value == "error" or value == "denied"
            or value == "unavailable") then result.errors[key] = value end
    end
    if result.errors.identity then
        for _, key in ipairs({ "runtime_status", "pci_state", "control", "active_time_ms",
            "suspended_time_ms", "autosuspend_delay_ms", "d3cold_allowed", "observed_at_ns" }) do
            result[key] = nil
        end
        result.status = "unavailable"
    end
    local observed = result.observed_at_ns
    if timestamp(now_ns) and observed and now_ns >= observed then
        local age = now_ns - observed
        result.age_ms = age // 1000000
    end
    local usable = source_quality == nil or type(source_quality) == "table"
        and (source_quality.status == nil or source_quality.status == "ok")
        and not Quality.UNUSABLE_FOR_ALERT[source_quality.quality]
    result.quality = result.status == "ok" and "fresh" or result.status
    if not usable then result.quality = "stale"
    elseif result.status == "ok" or result.status == "partial" then
        if not timestamp(now_ns) or not observed or now_ns < observed
            or not result.capture_started_ns or not result.capture_finished_ns
            or result.capture_started_ns > result.capture_finished_ns
            or observed ~= result.capture_finished_ns then result.quality = "gap"
        elseif now_ns - observed > M.STALE_AFTER_NS then result.quality = "stale" end
    end
    return result
end

function M.summary(inventory, quality, now_ns, limit)
    local result = { devices={}, devices_total=0, runtime_status_counts={}, pci_state_counts={} }
    limit = type(limit) == "number" and math.max(0, math.min(32, math.floor(limit))) or 5
    for _, bus in ipairs({ "pci", "usb" }) do
        local data = type(inventory) == "table" and inventory[bus] or nil
        for index, device in ipairs(type(data) == "table" and data.devices or {}) do
            if index > (bus == "pci" and 256 or 128) then result.devices_truncated = true; break end
            local row = M.public(device.runtime_pm, quality, now_ns)
            if row then
                result.devices_total = result.devices_total + 1
                local current = (row.quality == "fresh" or row.quality == "partial") and not row.state_changed
                local state = current and row.runtime_status or "unknown"
                state = state or "unknown"
                result.runtime_status_counts[state] = (result.runtime_status_counts[state] or 0) + 1
                if bus == "pci" then
                    local pci = current and row.pci_state or "unknown"
                    pci = pci or "unknown"
                    result.pci_state_counts[pci] = (result.pci_state_counts[pci] or 0) + 1
                end
                if #result.devices < limit then
                    row.bus = bus
                    row.id = bus .. ":" .. tostring(bus == "pci" and device.address or device.id)
                    result.devices[#result.devices + 1] = row
                end
            end
        end
        result.devices_truncated = result.devices_truncated or type(data) == "table" and data.truncated == true
    end
    if result.devices_total == 0 then return nil end
    result.devices_truncated = result.devices_truncated or result.devices_total > #result.devices
    return result
end

return M
