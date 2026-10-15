-- Comparisons use a configured cap for the same measurement domain. They
-- describe the sampled power, not a hardware throttling verdict.
local M = {}

function M.reading(value)
    if type(value) == "number" and value == value and value >= 0 and value < math.huge then
        return value
    end
end

function M.limit(value)
    value = M.reading(value)
    if value and value > 0 then return value end
end

function M.compare(watts, limit, enabled)
    watts, limit = M.reading(watts), M.limit(limit)
    if watts == nil or limit == nil or enabled == false then return nil end
    local percent = watts / limit * 100
    if not M.reading(percent) then return nil end
    -- Keep values above 100% and negative headroom. Only the drawn bar is
    -- clamped; averaging windows can legitimately differ from the cap window.
    return { percent = percent, headroom_watts = limit - watts }
end

local unusable = { denied = true, unavailable = true, stale = true, gap = true,
    reset = true, error = true }

function M.unusable(quality)
    if type(quality) == "table" then quality = quality.power or quality.quality or quality.status end
    return unusable[quality] == true
end

function M.zone(zone, constraint, quality)
    if M.unusable(quality) or unusable[zone.power_quality] or unusable[zone.quality] then return nil end
    local enabled = zone.controls_enabled
    if zone.enabled == false or zone.control_enabled == false then enabled = false end
    return M.compare(zone.power_watts, constraint and constraint.power_limit_watts, enabled)
end

function M.gpu(metrics, channel, quality)
    metrics = metrics or {}
    local watts, cap, source, cap_source
    if M.reading(metrics.power_watts) ~= nil then
        watts, source = metrics.power_watts, metrics.power_source
        cap, cap_source = M.limit(metrics.power_limit_watts), metrics.power_limit_source
        -- A vendor board reading must not borrow a rail cap from hwmon or
        -- from another provider that only filled one missing metric.
        if source == nil or source ~= cap_source then cap = nil end
    elseif channel then
        watts = M.reading(channel.input)
        cap = M.limit(channel.thresholds and channel.thresholds.cap)
        source, cap_source = channel.source, channel.source
        if channel.enabled == false or unusable[channel.quality] then cap = nil end
    else
        cap, cap_source = M.limit(metrics.power_limit_watts), metrics.power_limit_source
    end
    local comparison
    if not M.unusable(quality) then comparison = M.compare(watts, cap) end
    return { watts = watts, limit = cap, source = source, limit_source = cap_source,
        comparison = comparison }
end

return M
