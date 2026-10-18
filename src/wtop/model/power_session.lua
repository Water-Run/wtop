-- Statistics cover accepted observations of one power domain. Energy-derived
-- windows are weighted by their actual duration; point readings are averaged
-- by sample count. Missing time is not integrated or filled with zero.
local Power = require("wtop.model.power")
local M = {}
local IDENTITY = { "id", "name", "source", "source_kind", "parent_id",
    "maximum_energy_range_joules", "_source_epoch" }
local FIELDS = { "minimum_watts", "maximum_watts", "average_watts", "average_kind", "samples",
    "first_timestamp_ns", "last_timestamp_ns", "covered_time_ns", "energy_joules" }

local function finite(value) return Power.reading(value) ~= nil end
local function copy(session)
    local output = {}
    for _, key in ipairs(FIELDS) do output[key] = session[key] end
    return output
end

local function valid(session, now_ns)
    if type(session) ~= "table" or not finite(session.minimum_watts)
        or not finite(session.maximum_watts) or not finite(session.average_watts)
        or session.minimum_watts > session.average_watts or session.average_watts > session.maximum_watts
        or math.type(session.samples) ~= "integer" or session.samples <= 0 or session.samples >= math.maxinteger
        or not finite(session.first_timestamp_ns) or not finite(session.last_timestamp_ns)
        or session.first_timestamp_ns > session.last_timestamp_ns
        or now_ns ~= nil and (not finite(now_ns) or session.last_timestamp_ns > now_ns) then return false end
    if session.average_kind == "time_weighted" then
        local span = session.last_timestamp_ns - session.first_timestamp_ns
        local mean = finite(session.covered_time_ns) and session.covered_time_ns > 0
            and finite(session.energy_joules) and session.energy_joules / (session.covered_time_ns / 1e9) or nil
        return finite(session.covered_time_ns) and session.covered_time_ns > 0
            and session.covered_time_ns <= span + math.max(1, span * 1e-12)
            and finite(mean) and math.abs(mean - session.average_watts) <= math.max(1e-9, mean * 1e-9)
    end
    return session.average_kind == "samples" and session.covered_time_ns == nil and session.energy_joules == nil
end

function M.public(zone, now_ns)
    return valid(zone.power_session, now_ns) and copy(zone.power_session) or nil
end

local function identities(zones)
    local output = {}
    for index, zone in ipairs(zones or {}) do
        if index > 1024 then return {} end
        if type(zone.id) == "string" then
            if output[zone.id] == nil then output[zone.id] = zone else output[zone.id] = false end
        end
    end
    return output
end

local function same_identity(zone, old)
    if type(old) ~= "table" then return false end
    for _, key in ipairs(IDENTITY) do if zone[key] ~= old[key] then return false end end
    return true
end

function M.attach(zones, previous, now_ns)
    local current, earlier = identities(zones), identities(previous and previous.zones)
    for index, zone in ipairs(zones or {}) do
        if index > 1024 then break end
        local old = earlier[zone.id]
        local prior = same_identity(zone, old) and old.power_session or nil
        zone.power_session = nil
        if current[zone.id] == zone then
            if not valid(prior, now_ns) or zone.power_quality == "reset" then prior = nil end
            local state = Power.zone_state(zone, nil, now_ns)
            local observed, watts = zone.observed_at_ns, Power.reading(zone.power_watts)
            local usable = watts ~= nil and (state == "measured" or state == "wrapped" or state == "fresh")
            local kind = zone.power_source == "energy_delta" and "time_weighted" or "samples"
            local duration = kind == "time_weighted" and zone.power_interval_ns or nil
            if kind == "time_weighted" and (not finite(duration) or duration <= 0 or duration > (observed or -1)) then
                usable = false
            end
            if prior and usable and (prior._power_source ~= zone.power_source or prior.average_kind ~= kind) then prior = nil end
            if prior and usable and observed < prior.last_timestamp_ns then prior = nil end
            local first = kind == "time_weighted" and usable and observed - duration or observed
            -- Replayed or overlapping energy windows do not count twice.
            local append = usable and (not prior or observed > prior.last_timestamp_ns
                and (kind ~= "time_weighted" or first >= prior.last_timestamp_ns))
            if append then
                local samples = prior and prior.samples + 1 or 1
                local covered = duration and ((prior and prior.covered_time_ns or 0) + 0.0 + duration) or nil
                local energy = duration and ((prior and prior.energy_joules or 0) + watts * (duration / 1e9)) or nil
                local minimum = prior and math.min(prior.minimum_watts, watts) or watts
                local maximum = prior and math.max(prior.maximum_watts, watts) or watts
                local average = duration and energy / (covered / 1e9)
                    or prior and prior.average_watts + (watts - prior.average_watts) / samples or watts
                average = math.max(minimum, math.min(maximum, average))
                local session = { minimum_watts = minimum, maximum_watts = maximum,
                    average_watts = average, average_kind = kind, samples = samples,
                    first_timestamp_ns = prior and prior.first_timestamp_ns or first, last_timestamp_ns = observed,
                    covered_time_ns = covered, energy_joules = energy }
                if valid(session, now_ns) then zone.power_session = session end
            elseif prior then zone.power_session = copy(prior) end
            if zone.power_session then
                zone.power_session._power_source = usable and zone.power_source or prior and prior._power_source
            end
        end
    end
end

return M
