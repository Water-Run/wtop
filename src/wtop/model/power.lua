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
    reset = true, error = true, unknown = true, held = true }

function M.state(quality)
    if type(quality) == "table" then
        if quality.status and quality.status ~= "ok" then
            return quality.quality == "stale" and "stale" or quality.status
        end
        return quality.power or quality.quality or quality.status
    end
    return quality
end

function M.unusable(quality)
    return unusable[M.state(quality)] == true
end

function M.zone_age(zone, quality, now_ns)
    local observed = zone.observed_at_ns
        or type(quality) == "table" and quality.value_timestamp_ns
    if M.reading(now_ns) == nil or M.reading(observed) == nil or observed > now_ns then return nil end
    -- Subtract before converting: long uptimes can exceed exact float
    -- nanoseconds even while the interval is still a small integer.
    return now_ns - observed
end

function M.zone_state(zone, quality, now_ns)
    local state = M.state(quality)
    if M.unusable(state) then return state end
    if M.unusable(zone.power_quality) then return zone.power_quality end
    if M.unusable(zone.quality) then return zone.quality end
    if now_ns ~= nil then
        local age = M.zone_age(zone, quality, now_ns)
        if age == nil then return "unknown" end
        if age > 15000000000 then return "stale" end
    end
    return zone.power_quality or zone.quality or state
end

function M.zone(zone, constraint, quality, now_ns)
    if M.unusable(M.zone_state(zone, quality, now_ns)) then return nil end
    local enabled = zone.controls_enabled
    if zone.enabled == false or zone.control_enabled == false then enabled = false end
    return M.compare(zone.power_watts, constraint and constraint.power_limit_watts, enabled)
end

-- Keep controller aliases and packages separate. The headline total cannot be
-- used as the numerator of an individual controller's cap.
function M.cpu_budgets(power, quality, maximum, now_ns)
    maximum = maximum or 512
    local rows, rank = {}, { long_term = 1, short_term = 2, peak_power = 3 }
    for _, zone in ipairs(power and power.zones or {}) do
        if not zone.parent_id and zone.aggregate_domain == "cpu_package" then
            for _, cap in ipairs(zone.constraints or {}) do
                local limit = M.limit(cap.power_limit_watts)
                if limit then
                    local state = M.zone_state(zone, quality, now_ns)
                    rows[#rows + 1] = {
                        zone_id = zone.id, constraint_id = cap.id, constraint_name = cap.name,
                        watts = M.reading(zone.power_watts), limit_watts = limit,
                        comparison = M.zone(zone, cap, quality, now_ns), quality = state,
                        disabled = zone.enabled == false or zone.control_enabled == false
                            or zone.controls_enabled == false,
                    }
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        local left, right = rank[a.constraint_name] or 4, rank[b.constraint_name] or 4
        if left ~= right then return left < right end
        if a.zone_id ~= b.zone_id then return tostring(a.zone_id) < tostring(b.zone_id) end
        return tostring(a.constraint_id) < tostring(b.constraint_id)
    end)
    local total = #rows
    for index = #rows, maximum + 1, -1 do rows[index] = nil end
    return rows, total
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
        if channel.enabled == false or (unusable[channel.quality] and not channel.verified_cap) then cap = nil end
    else
        cap, cap_source = M.limit(metrics.power_limit_watts), metrics.power_limit_source
    end
    local comparison
    if not M.unusable(quality) then comparison = M.compare(watts, cap) end
    return { watts = watts, limit = cap, source = source, limit_source = cap_source,
        comparison = comparison }
end

return M
