-- PCIe driver readings retain their own quality and observation time. The
-- reported link maximum is not a traffic denominator or a throttling verdict.
local Quality = require("wtop.model.quality")
local Power = require("wtop.model.power")
local M = {}
M.fields = { "pcie_current_generation", "pcie_current_width", "pcie_maximum_generation",
    "pcie_maximum_width", "pcie_tx_kilobytes_per_second", "pcie_rx_kilobytes_per_second" }
local ranges = {
    pcie_current_generation = {1,32}, pcie_maximum_generation = {1,32},
    pcie_current_width = {0,64}, pcie_maximum_width = {0,64},
    pcie_tx_kilobytes_per_second = {0,4294967294}, pcie_rx_kilobytes_per_second = {0,4294967294},
    pcie_throughput_interval_ns = {20000000,20000000},
}

function M.reading(key, value)
    local bounds = ranges[key]
    if bounds and Power.reading(value) ~= nil and value % 1 == 0
        and value >= bounds[1] and value <= bounds[2] then return value end
end

local function observation_age(snapshot, observation)
    local now = snapshot.timestamp_ns or snapshot.captured_monotonic_ns
    local observed = observation and observation.observed_at_ns
    local age, clock_state
    if observed ~= nil then
        if Power.reading(now) == nil or Power.reading(observed) == nil or observed > now then clock_state = "gap"
        else age = now - observed; if age > 15000000000 then clock_state = "stale" end end
    end
    return age, clock_state
end

function M.state(snapshot, device, key)
    local observation = device.metric_observations and device.metric_observations[key]
    local age, clock_state = observation_age(snapshot, observation)
    local source = snapshot.quality and snapshot.quality.gpus
    if not Quality.current_source(snapshot.quality, "gpus") then return Power.state(source), age end
    if device.identity_quality == "stale" or observation and observation.retained then return "stale", age end
    local state = Quality.gpu_metric_quality(device, key, "pcie")
    if Power.unusable(state) then return state, age end
    return clock_state or state or "unknown", age
end

local function system_speed(value)
    if type(value) ~= "string" or #value == 0 or #value > 256 or value:find("%c") then return end
    if value:lower() ~= "unknown" and value:lower() ~= "n/a" then return value end
end

local function system_width(value)
    if Power.reading(value) ~= nil and value % 1 == 0 and value >= 1 and value <= 1024
        and value ~= 255 then return value end
end

-- Linux sysfs max_link_* describes this device's capability. It is not the
-- NVML device/system maximum. No probing or generation inference happens here.
function M.system(snapshot, device)
    local pci = device.pci or {}
    local result = { current_speed = system_speed(pci.current_link_speed),
        current_width = system_width(pci.current_link_width),
        maximum_speed = system_speed(pci.maximum_link_speed),
        maximum_width = system_width(pci.maximum_link_width), source = device.source }
    if not (result.current_speed or result.current_width or result.maximum_speed or result.maximum_width) then return end
    local observation = device.observations and device.observations.drm
    local age, clock_state = observation_age(snapshot, observation)
    local source = snapshot.quality and snapshot.quality.gpus
    local quality = observation and observation.quality or "unknown"
    if not Quality.current_source(snapshot.quality, "gpus") then quality = Power.state(source)
    elseif device.identity_quality == "stale" or observation and observation.retained then quality = "stale"
    elseif not Power.unusable(quality) then quality = clock_state or quality end
    result.quality, result.age_ns = quality, age
    return result
end

function M.has_data(device)
    for _, key in ipairs(M.fields) do
        if M.reading(key, (device.metrics or {})[key]) ~= nil then return true end
    end
    return false
end

return M
