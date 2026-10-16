local Thermal = require("wtop.model.thermal")
local M = {}

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
    local projected = { timestamp_ns = snapshot.timestamp_ns,
        sensors = {}, quality = { sensors = snapshot.quality and snapshot.quality.disk_health } }
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
