local Thermal = require("wtop.model.thermal")
local M = {}

local function time(value)
    return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

-- A slow batch's completion does not make its first device newly observed.
-- Older providers without individual timestamps retain the source timestamp.
function M.observed_at(snapshot, health)
    local state = snapshot.quality and snapshot.quality.disk_health or {}
    local observed, batch = health.observed_at_ns, state.value_timestamp_ns
    if observed == nil then return time(batch) and batch or nil end
    if not time(observed) or time(batch) and observed > batch then return nil end
    return observed
end

local function observation(snapshot, health, now_ns)
    local state = snapshot.quality and snapshot.quality.disk_health or {}
    local observed = M.observed_at(snapshot, health)
    return { timestamp_ns = now_ns or snapshot.timestamp_ns, sensors = {},
        quality = { sensors = { status = state.status, quality = observed == nil and "stale" or state.quality,
            value_timestamp_ns = observed } } }
end

function M.current(snapshot, health, now_ns)
    return Thermal.current(observation(snapshot, health, now_ns))
end

local function unique(rows, id)
    local result
    for _, row in ipairs(rows or {}) do
        if row.id == id then
            if result then return nil end
            result = row
        end
    end
    return result
end

function M.match(snapshot, disk, data)
    snapshot = snapshot or {}
    if type(disk) ~= "table" or type(disk.id) ~= "string"
        or type(disk._health_key) ~= "string" or #disk._health_key == 0 then return nil end
    if unique(snapshot.disks and snapshot.disks.devices, disk.id) ~= disk then return nil end
    local health = unique((data or snapshot.disk_health or {}).devices, disk.id)
    if not health or health._health_key ~= disk._health_key then return nil end
    return health
end

function M.temperature(snapshot, disk, now_ns)
    local health = M.match(snapshot, disk)
    if not health then return nil end
    local projected = observation(snapshot, health, now_ns)
    local selected, selected_margin
    for _, channel in ipairs(health.temperature and health.temperature.channels or {}) do
        if type(channel.input) == "number" and channel.input == channel.input
            and (not selected or channel.input > selected.input) then
            selected, selected_margin = channel, Thermal.channel(projected, health, channel, now_ns)
        end
    end
    if not selected then return nil end
    local current = Thermal.input_current(projected, health, selected, now_ns)
    return { channel = selected, critical_celsius = selected_margin and selected_margin.critical_celsius,
        headroom_celsius = selected_margin and selected_margin.headroom_celsius,
        quality = current and selected.quality or "stale", observed_at_ns = projected.quality.sensors
            and projected.quality.sensors.value_timestamp_ns }
end

return M
