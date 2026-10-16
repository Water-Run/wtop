-- A configured critical threshold is not evidence of active throttling.
-- Compare only one channel's Celsius reading and its own critical maximum.
local M = { STALE_AFTER_NS = 15 * 1000000000 }

local unusable = {
    stale = true, gap = true, denied = true, error = true, unavailable = true,
    missing = true, held = true, reset = true,
}

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

function M.current(snapshot, now_ns)
    snapshot = snapshot or {}
    local state = snapshot.quality and snapshot.quality.sensors or {}
    if state.status and state.status ~= "ok" or unusable[state.quality]
        or unusable[snapshot.sensors and snapshot.sensors.quality] then return false end
    now_ns = now_ns == nil and snapshot.timestamp_ns or now_ns
    local observed = state.value_timestamp_ns
    if finite(now_ns) and finite(observed) then
        if now_ns < observed or (now_ns + 0.0) - observed > M.STALE_AFTER_NS then
            return false
        end
    end
    return true
end

function M.input_current(snapshot, device, channel, now_ns)
    return M.current(snapshot, now_ns) and not unusable[(device or {}).quality]
        and not unusable[channel.quality] and channel.fault ~= true
        and not (channel.errors and channel.errors.input) and finite(channel.input)
end

function M.channel(snapshot, device, channel, now_ns)
    if type(channel) ~= "table" or channel.type ~= "temperature"
        or channel.unit ~= "celsius" then return nil end
    local critical = channel.thresholds and channel.thresholds.crit
    if not finite(critical) or channel.errors and channel.errors.crit then return nil end
    local result = { critical_celsius = critical }
    if not M.input_current(snapshot, device, channel, now_ns) then return result end
    local headroom = critical - channel.input
    if finite(headroom) then result.headroom_celsius = headroom end
    return result
end

function M.closest(snapshot, limit, now_ns)
    local rows = {}
    for _, device in ipairs(snapshot.sensors and snapshot.sensors.devices or {}) do
        for _, channel in ipairs(device.channels or {}) do
            local thermal = M.channel(snapshot, device, channel, now_ns)
            if thermal and thermal.headroom_celsius ~= nil then
                local index = 1
                while rows[index] and rows[index].headroom_celsius <= thermal.headroom_celsius do
                    index = index + 1
                end
                if index <= limit then
                    thermal.device, thermal.channel = device, channel
                    table.insert(rows, index, thermal)
                    if #rows > limit then rows[#rows] = nil end
                end
            end
        end
    end
    return rows
end

return M
