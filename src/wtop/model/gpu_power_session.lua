-- Statistics summarize provider readings, including driver averages. They do
-- not integrate energy or pretend that overlapping vendor windows are disjoint.
local Session = require("wtop.model.power_session")
local Power = require("wtop.model.power")
local M = {}
M.SOURCES = { "nvml", "amdsmi", "levelzero", "adl" }
local METRICS = { "power_watts", "power_instant_watts", "power_average_watts", "board_power_watts" }
local KNOWN = {}; for _, source in ipairs(M.SOURCES) do KNOWN[source] = true end
local METRIC = {}; for _, metric in ipairs(METRICS) do METRIC[metric] = true end
local META = { "id", "metric", "source", "scope", "measurement", "method", "quality", "observed_at_ns", "current_watts",
    "sample_time_basis", "provider_timestamp_us", "minimum_interval_ns", "maximum_interval_ns" }

local function finite(value) return Power.reading(value) ~= nil end
local function text(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum
        and not value:find("[%c]") and value or nil
end
local function copy(value)
    local output = {}; for key, item in pairs(value or {}) do output[key] = item end; return output
end
local function fingerprint(device, anchor)
    local uuid, bdf = text(device.vendor_uuid, 96), text(device.pci_bdf, 32)
    if device.identity_quality ~= "fresh" and device.identity_quality ~= "estimated" then return nil end
    if not (uuid or bdf and device.identity_quality == "fresh") then return nil end
    if anchor == false then return nil end
    local parts = {}
    for _, value in ipairs({ device.id or false, uuid or false, bdf or false,
        device.vendor_id or false, device.device_id or false, device.driver or false,
        device.driver_version or false, device.model_name or false, anchor or false }) do
        local kind = type(value)
        if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then return nil end
        local token = tostring(value); if #token > 4096 then return nil end
        parts[#parts + 1] = kind .. #token .. ":" .. token
    end
    return table.concat(parts, "|")
end
local function unique(devices, field)
    local output = {}
    for index, device in ipairs(devices or {}) do
        if index > 64 then return {} end
        local key = device[field]
        if key ~= nil then
            if output[key] == nil then output[key] = device else output[key] = false end
        end
    end
    return output
end
local function state(value)
    if value == "fresh" or value == "measured" then return "fresh" end
    return Power.unusable(value) and value or "gap"
end
local function descriptor(device, source, metric)
    local m = device.metrics or {}
    local scope = text(m.power_scope, 32) or "unspecified"
    local measurement = text(m.power_measurement, 32) or "unknown"
    local interval, timestamp, quality = m.power_interval_ns, nil,
        type(device.quality) == "table" and device.quality.power or device.quality
    if metric == "power_instant_watts" then
        measurement, interval, timestamp, quality = "current", nil, m.power_instant_timestamp_us, m.power_instant_quality
    elseif metric == "power_average_watts" then
        measurement, interval, timestamp, quality = "average", m.power_average_interval_ns,
            m.power_average_timestamp_us, m.power_average_quality
    elseif metric == "board_power_watts" then scope = "card"
    elseif source == "nvml" then
        timestamp = measurement == "current" and m.power_instant_timestamp_us
            or measurement == "average" and m.power_average_timestamp_us or nil
    end
    if not finite(interval) or interval <= 0 then interval = nil end
    if not finite(timestamp) or timestamp <= 0 or timestamp % 1 ~= 0 then timestamp = nil end
    if source == "nvml" and (metric == "power_instant_watts" or metric == "power_average_watts"
        or metric == "power_watts" and (measurement == "current" or measurement == "average")) and not timestamp then
        quality = "gap"
    end
    local method = device.adl and device.adl.metric_methods and device.adl.metric_methods[metric]
    return { scope = scope, measurement = measurement, interval = interval, timestamp = timestamp,
        quality = state(quality), method = text(method, 32) }
end

function M.attach(devices, previous, source, data, now_ns, anchors)
    if not KNOWN[source] then return end
    local ids, bdfs, uuids = unique(devices, "id"), unique(devices, "pci_bdf"), unique(devices, "vendor_uuid")
    local old = unique(previous, "id")
    local captured = finite(data.sample_started_ns) and data.sample_started_ns <= now_ns and data.sample_started_ns or nil
    local invalid_capture = data.sample_started_ns ~= nil and captured == nil
    for index, device in ipairs(devices) do
        if index > 64 then break end
        local before = old[device.id]
        local before_identity = type(before) == "table" and before._power_session_identity
        local before_points = type(before) == "table" and before._power_session_points
        device._power_session_points = nil
        local identity = fingerprint(device, device.pci_bdf and anchors[device.pci_bdf])
        local valid = identity and ids[device.id] == device and (not device.pci_bdf or bdfs[device.pci_bdf] == device)
            and (not device.vendor_uuid or uuids[device.vendor_uuid] == device)
        device._power_session_identity = valid and identity or nil
        if valid then
            local earlier = {}
            for _, point in ipairs(before_identity == identity and before_points or {}) do earlier[point.id] = point end
            local points, prior, usable_before = {}, {}, {}
            local m = device.metrics or {}
            for _, metric in ipairs(METRICS) do
                -- Dedicated NVML fields supersede its selected alias; a card
                -- domain is also already represented by board_power_watts.
                local alias = metric == "power_watts" and
                    (source == "nvml" and (finite(m.power_instant_watts) or finite(m.power_average_watts))
                    or (m.power_scope == "card" and finite(m.board_power_watts)))
                local previous_point = earlier[metric]
                if not alias and (finite(m[metric]) or previous_point) then
                    local d = descriptor(device, source, metric)
                    if not finite(m[metric]) and previous_point then d = copy(previous_point._descriptor); d.quality = "unavailable" end
                    local signature = identity .. "|" .. source .. "|" .. d.scope .. "|" .. d.measurement .. "|" .. tostring(d.method)
                    if previous_point and previous_point._source_epoch ~= signature then previous_point = nil end
                    local observed = not invalid_capture and (captured or (d.timestamp and now_ns)) or nil
                    local q = observed and d.quality or "gap"
                    local last = previous_point and previous_point.power_session and previous_point.power_session.last_timestamp_ns
                    if last and last > now_ns then previous_point, last = nil, nil end
                    local old_capture = last and observed and observed < last
                    if old_capture then q = "stale" end
                    if not old_capture and d.timestamp and previous_point and previous_point._provider_timestamp_us then
                        if d.timestamp < previous_point._provider_timestamp_us then previous_point = nil
                        elseif d.timestamp == previous_point._provider_timestamp_us and q == "fresh" then q = "held" end
                    end
                    if q == "held" and previous_point._accepted_watts ~= m[metric] then q = "gap" end
                    if q == "fresh" and last and observed == last and previous_point
                        and previous_point._accepted_watts ~= m[metric] then q = "gap" end
                    local point = { id = metric, name = metric, source = source, source_kind = source,
                        _source_epoch = signature, observed_at_ns = observed, power_watts = m[metric],
                        power_source = "api_reading", power_quality = q, _descriptor = d,
                        _reading_quality = q == "held" and d.quality or q }
                    points[#points + 1] = point
                    if previous_point then prior[#prior + 1] = previous_point; usable_before[metric] = previous_point end
                end
            end
            Session.attach(points, { zones = prior }, now_ns)
            for _, point in ipairs(points) do
                local before_point = usable_before[point.id]
                local same = before_point and before_point._source_epoch == point._source_epoch
                local appended = point.power_session and (not same or not before_point.power_session
                    or point.power_session.last_timestamp_ns > before_point.power_session.last_timestamp_ns)
                point._provider_timestamp_us = point.power_session and
                    (appended and point._descriptor.timestamp or same and before_point._provider_timestamp_us) or nil
                point._accepted_watts = point.power_session and
                    (appended and point.power_watts or same and before_point._accepted_watts) or nil
                local duration = point._descriptor.interval
                point._minimum_interval_ns = same and before_point._minimum_interval_ns or nil
                point._maximum_interval_ns = same and before_point._maximum_interval_ns or nil
                if appended and duration then
                    point._minimum_interval_ns = math.min(point._minimum_interval_ns or duration, duration)
                    point._maximum_interval_ns = math.max(point._maximum_interval_ns or duration, duration)
                end
                if not point.power_session then point._minimum_interval_ns, point._maximum_interval_ns = nil, nil end
            end
            device._power_session_points = points
        end
    end
end

function M.rows(device, source, now_ns, observation)
    local output = {}
    for _, point in ipairs(device._power_session_points or {}) do
        local row = Session.public(point, now_ns)
        if row then
            local d = point._descriptor
            row.id, row.metric, row.source = source .. ":" .. point.id, point.id, source
            row.scope, row.measurement, row.method = d.scope, d.measurement, d.method
            row.observed_at_ns = point.observed_at_ns
            row.quality = point._reading_quality
            if not finite(point.observed_at_ns) or point.observed_at_ns > now_ns then row.quality = "gap"
            elseif now_ns - point.observed_at_ns > 15000000000 then row.quality = "stale" end
            if observation.retained or observation.quality == "stale" then row.quality = "stale" end
            if row.quality == "fresh" then row.current_watts = Power.reading(point.power_watts) end
            row.provider_timestamp_us = point._provider_timestamp_us
            row.sample_time_basis = row.provider_timestamp_us and "provider_timestamp" or "query_capture"
            row.minimum_interval_ns, row.maximum_interval_ns = point._minimum_interval_ns, point._maximum_interval_ns
            output[#output + 1] = row
        end
    end
    return output
end

function M.public(device, now_ns, quality)
    local output, seen = {}, {}
    for index, record in ipairs(device.power_sessions or {}) do
        if index > 16 then break end
        local basis = record.sample_time_basis == "query_capture" or record.sample_time_basis == "provider_timestamp"
            and finite(record.provider_timestamp_us) and record.provider_timestamp_us > 0 and record.provider_timestamp_us % 1 == 0
        if basis and record.average_kind == "samples" and KNOWN[record.source] and METRIC[record.metric]
            and record.id == record.source .. ":" .. record.metric and not seen[record.id] then
            seen[record.id] = true
            local row = Session.public({ power_session = record }, now_ns)
            if row then
                for _, key in ipairs(META) do row[key] = record[key] end
                if Power.unusable(quality) then row.quality = Power.state(quality)
                elseif not finite(now_ns) or not finite(row.observed_at_ns) or row.observed_at_ns > now_ns then row.quality = "gap"
                elseif now_ns - row.observed_at_ns > 15000000000 then row.quality = "stale" end
                if row.quality ~= "fresh" then row.current_watts = nil end
                output[#output + 1] = row
            end
        end
    end
    return output
end

return M
