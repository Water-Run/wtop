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

function M.state(snapshot, device, key)
    local observation = device.metric_observations and device.metric_observations[key]
    local now = snapshot.timestamp_ns or snapshot.captured_monotonic_ns
    local observed = observation and observation.observed_at_ns
    local age, clock_state
    if observed ~= nil then
        if Power.reading(now) == nil or Power.reading(observed) == nil or observed > now then clock_state = "gap"
        else age = now - observed; if age > 15000000000 then clock_state = "stale" end end
    end
    local source = snapshot.quality and snapshot.quality.gpus
    if not Quality.current_source(snapshot.quality, "gpus") then return Power.state(source), age end
    if device.identity_quality == "stale" or observation and observation.retained then return "stale", age end
    local state = Quality.gpu_metric_quality(device, key, "pcie")
    if Power.unusable(state) then return state, age end
    return clock_state or state or "unknown", age
end

function M.has_data(device)
    for _, key in ipairs(M.fields) do
        if M.reading(key, (device.metrics or {})[key]) ~= nil then return true end
    end
    return false
end

return M
