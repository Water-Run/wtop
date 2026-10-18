-- Power from adjacent hwmon energy observations. Counters and clocks are
-- subtracted as integers before conversion; a counter decrease is a reset.
local Common = require("wtop.collectors.common")
local Power = require("wtop.model.power")
local Session = require("wtop.model.power_session")
local M = {}
local DEVICE_FIELDS = { "id", "name", "class", "source", "device_target", "device_path", "driver" }

local function unique(rows)
    local result = {}
    for _, row in ipairs(rows or {}) do
        if type(row) == "table" and type(row.id) == "string" then
            if result[row.id] == nil then result[row.id] = row else result[row.id] = false end
        end
    end
    return result
end
local function identity(device, old, channel, earlier)
    if type(old) ~= "table" or type(earlier) ~= "table"
        or device.identity_quality ~= "fresh" or old.identity_quality ~= "fresh"
        or not device._power_identity_verified or not old._power_identity_verified
        or not device.device_path or device.device_path == "" then return false end
    for _, field in ipairs(DEVICE_FIELDS) do if device[field] ~= old[field] then return false end end
    return channel.id == earlier.id and channel.label == earlier.label
        and channel.unit == earlier.unit and channel.source == earlier.source and earlier.type == channel.type
end
local function limits(device, channel, channels)
    local verified = device._power_identity_verified and device.identity_quality == "fresh" and not device.truncated
    local scope = verified and device.driver == "xe"
        and ({ [1] = "card", [2] = "package" })[channel.index]
    if verified and device.driver == "i915" and channel.index == 1 then
        if device.name == "i915" then scope = "card"
        elseif channel.type == "energy" and type(device.name) == "string"
            and device.name:match("^i915_gt%d+$") then return "gpu_gt", {} end
    end
    if not scope then return nil, {} end
    local power = channels["power:" .. channel.index]
    local result = {}
    if type(power) == "table" then
        for _, spec in ipairs({ { "max", "long_term" }, { "cap", "short_term" } }) do
            local watts = power._raw_power_limits and power._raw_power_limits[spec[1]]
            if Power.reading(watts) and (device.driver == "xe" or spec[1] == "max") then
                result[#result + 1] = { id = spec[2], power_limit_watts = watts, enabled = watts > 0,
                    source = power.source .. "/power" .. power.index .. "_" .. spec[1],
                    window_ns = power.intervals_ms and power.intervals_ms[spec[1] .. "_interval"]
                        and power.intervals_ms[spec[1] .. "_interval"] * 1000000 or nil }
            end
        end
    end
    return scope, result
end

local function direct(device, channel, channels, old_device, earlier, now_ns, same)
    local scope, caps = limits(device, channel, channels)
    if not scope then return end
    local reading = Power.reading(channel.readings and channel.readings.input) ~= nil
        and not (channel.errors and channel.errors.input) and "input" or "average"
    local watts = Power.reading(channel.readings and channel.readings[reading])
    local bracket = channel.power_readings and channel.power_readings[reading]
    local duration = bracket and Common.elapsed_ns(bracket.finished_ns, bracket.started_ns)
    local power = { id = device.id .. "/" .. channel.id, name = channel.label,
        source = channel.source .. "/power" .. channel.index .. "_" .. reading,
        source_kind = "hwmon_power", power_source = "power_" .. reading,
        measurement = reading == "input" and "current" or "average",
        power_quality = "unavailable", quality = "fresh", enabled = channel.enabled,
        scope = scope, limits = caps }
    channel.power = power
    if duration and duration <= 1500000000 and bracket.started_ns >= 0 and bracket.finished_ns <= now_ns then
        power.observed_at_ns = bracket.started_ns + duration // 2
        power.read_duration_ns = duration
        if channel.enabled ~= false and not channel.fault and watts ~= nil then
            power.power_watts, power.power_quality = watts, "fresh"
        end
    end
    local failure = channel.errors and (channel.errors.enable or channel.errors[reading])
    if failure then power.power_watts, power.power_quality = nil, failure.status end
    if channel.fault then power.power_watts, power.power_quality = nil, "error" end
    if reading == "average" then
        power.power_interval_ns = channel.intervals_ms and channel.intervals_ms.average_interval
            and channel.intervals_ms.average_interval * 1000000 or nil
    end
    local old = earlier[channel.id]
    local prior = same and identity(device, old_device, channel, old) and old.power or nil
    Session.attach({ power }, prior and { zones = { prior } } or nil, now_ns)
end
local function counter(power)
    return power and math.type(power.energy_microjoules) == "integer" and power.energy_microjoules >= 0
        and power.enabled ~= false and power.counter_valid == true and power.observed_at_ns ~= nil
        and Power.reading(power.read_duration_ns) and power.read_duration_ns <= 1500000000
end

function M.attach(devices, previous, now_ns, truncated)
    local current, old_devices = unique(devices), unique(previous and previous.devices)
    local processed = 0
    for _, device in ipairs(devices) do
        local old = old_devices[device.id]
        local channels, earlier = unique(device.channels), unique(type(old) == "table" and old.channels)
        for _, channel in ipairs(device.channels or {}) do
            if channel.type == "power" then
                direct(device, channel, channels, old, earlier, now_ns,
                    current[device.id] == device and channels[channel.id] == channel
                        and not truncated and not (previous and previous.truncated))
            elseif channel.type == "energy" then
                processed = processed + 1
                local source = channel.source .. "/energy" .. channel.index .. "_input"
                local power = { id = device.id .. "/" .. channel.id, name = channel.label,
                    source = source, source_kind = "hwmon_energy", power_source = "energy_delta",
                    quality = "fresh", power_quality = "gap", energy_microjoules = channel.energy_microjoules,
                    enabled = channel.enabled, measurement = "energy_delta" }
                channel.power = power
                if processed > 4096 then power.power_quality = "truncated"
                else
                    local began, finished = channel.energy_read_started_ns, channel.energy_read_finished_ns
                    local duration = began and finished and Common.elapsed_ns(finished, began)
                    if duration and began >= 0 and finished <= now_ns then
                        power.observed_at_ns = began + duration // 2
                        power.read_duration_ns = duration
                    end
                    local failure = channel.errors and (channel.errors.input or channel.errors.enable)
                    if failure then power.power_quality = failure.status
                    elseif channel.enabled == false then power.power_quality = "unavailable"
                    elseif channel.fault then power.power_quality = "error"
                    elseif power.observed_at_ns and math.type(power.energy_microjoules) == "integer" then power.counter_valid = true end
                    local prior_channel = earlier[channel.id]
                    local same = current[device.id] == device and channels[channel.id] == channel
                        and not truncated and not (previous and previous.truncated)
                        and identity(device, old, channel, prior_channel)
                    local prior = same and prior_channel.power or nil
                    if counter(power) and counter(prior) then
                        local elapsed = Common.elapsed_ns(power.observed_at_ns, prior.observed_at_ns)
                        local delta = power.energy_microjoules - prior.energy_microjoules
                        if delta < 0 then power.power_quality = "reset"
                        elseif elapsed and elapsed > 0 and elapsed <= 15000000000 then
                            local uncertainty = (power.read_duration_ns + prior.read_duration_ns + 1) // 2
                            power.interval_uncertainty_ns = uncertainty
                            if uncertainty * 10 <= elapsed then
                                local watts = (delta + 0.0) * 1000 / elapsed
                                if Power.reading(watts) and watts <= 1000000 then
                                    power.power_watts, power.power_quality, power.power_interval_ns = watts, "measured", elapsed
                                else power.power_quality = "reset" end
                            end
                        end
                    end
                    power.scope, power.limits = limits(device, channel, channels)
                    Session.attach({ power }, prior and { zones = { prior } } or nil, now_ns)
                end
            end
        end
    end
end

function M.public(channel, now_ns, quality)
    local power = type(channel) == "table" and channel.power
    if type(power) ~= "table" then return nil end
    local output = {}
    for _, field in ipairs({ "source", "source_kind", "scope", "power_source", "power_watts", "power_quality",
        "power_interval_ns", "interval_uncertainty_ns", "read_duration_ns", "observed_at_ns", "enabled", "measurement" }) do output[field] = power[field] end
    output.limits = {}
    output.power_session = Session.public(power, now_ns)
    if Power.unusable(quality) then
        output.power_watts, output.power_quality = nil, Power.state(quality)
    elseif power.observed_at_ns ~= nil and (not Power.reading(now_ns) or not Power.reading(power.observed_at_ns)
        or power.observed_at_ns > now_ns or now_ns - power.observed_at_ns > 15000000000) then
        output.power_watts, output.power_quality = nil, "stale"
    end
    for _, row in ipairs(power.limits or {}) do
        local limit = {}
        for _, field in ipairs({ "id", "source", "window_ns", "power_limit_watts", "enabled" }) do limit[field] = row[field] end
        local comparison = not Power.unusable(output.power_quality)
            and Power.compare(output.power_watts, limit.power_limit_watts, limit.enabled)
        if comparison then
            limit.percent, limit.headroom_watts = comparison.percent, comparison.headroom_watts
        end
        output.limits[#output.limits + 1] = limit
    end
    return output
end

function M.channel(channel, now_ns, quality)
    local power = M.public(channel, now_ns, quality)
    if not power then return nil end
    local cap, kind
    for _, row in ipairs(power.limits) do if row.enabled then cap, kind = row.power_limit_watts, row.id; break end end
    local input_source = power.power_source == "energy_delta" and "energy_delta"
        or power.measurement == "average" and "average" or nil
    return { id = channel.id, type = channel.type, index = channel.index, label = channel.label,
        input = power.power_watts, input_source = input_source, source = power.source,
        quality = power.power_quality, thresholds = { cap = cap }, power = power, limit_kind = kind,
        verified_cap = power.scope ~= nil and #power.limits > 0 }
end

return M
