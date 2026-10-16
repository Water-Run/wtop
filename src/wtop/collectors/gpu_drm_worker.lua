local Hardware = require("wtop.collectors.hardware_worker")
local Wire = require("wtop.core.worker_wire")
local Common = require("wtop.collectors.common")
local M = {}
M.__index = M

local groups = {
    utilization_percent="utilization",memory_used_bytes="memory",memory_total_bytes="memory",
    frequency_current_hz="frequency",temperature_celsius="temperature",power_watts="power",
    fan_speed_percent="fan",
}

local function group(key)
    if groups[key] then return groups[key] end
    if key:match("^power_") then return "power" end
    if key:match("^frequency_") then return "frequency" end
    if key:match("^memory_") then return "memory" end
    if key:match("^utilization_") then return "utilization" end
end

local function mark(result, now, retained, reason)
    local observed = result.value_timestamp_ns or result.timestamp_ns
    for _,device in ipairs(result.data.devices) do
        local observation = {source="drm",observed_at_ns=observed,received_at_ns=now,
            sample_started_ns=result.sample_started_ns,sample_finished_ns=result.sample_finished_ns,
            quality=retained and "stale" or "fresh",retained=retained or false,reason=reason}
        if retained then
            local previous=device.observations and device.observations.drm
            observation.received_at_ns=previous and previous.received_at_ns
            observation.attempted_at_ns=now
        end
        device.observations=device.observations or {}
        device.observations.drm=observation
        device.metric_observations=device.metric_observations or {}
        device.quality=device.quality or {}
        for key in pairs(device.metrics or {}) do
            local field = {}
            for name,value in pairs(observation) do field[name]=value end
            local category=group(key)
            field.quality=retained and "stale" or (category and device.quality[category]) or "fresh"
            device.metric_observations[key]=field
            if retained and category then device.quality[category]="stale" end
        end
        if retained then
            device.partial,device.identity_quality,device.quality.identity=true,"stale","stale"
            device.quality.performance_limits="stale"
            if device.frequencies then device.frequencies.quality="stale" end
            for _,key in ipairs({"power_instant_quality","power_average_quality"}) do
                if device.metrics[key]=="fresh" then device.metrics[key]="stale" end
            end
            for _,domain in ipairs(device.frequencies and device.frequencies.domains or {}) do domain.quality="stale" end
            for _,domain in ipairs(device.performance_limits and device.performance_limits.domains or {}) do domain.quality="stale" end
            device.processes={list={},by_id={},clients={},clients_by_id={},quality="unavailable",
                summary={process_count=0,client_count=0}}
            device.capabilities.processes,device.capabilities.process_memory=false,false
        end
    end
end

-- Offer live SDKs empty metric slots. Restore old DRM groups only where no
-- live source supplied that group, so a stale busy/clock cannot win a join.
function M:prepare(result)
    if not result.retained then return end
    local fallback={}
    for _,device in ipairs(result.data.devices) do
        fallback[device]=device.metrics
        device.metrics={}
    end
    return fallback
end

function M:restore(fallback)
    for device,metrics in pairs(fallback or {}) do
        local live={}
        for key in pairs(device.metrics) do
            local category=group(key)
            if category then live[category]=true end
        end
        for key,value in pairs(metrics) do
            local category=group(key)
            if device.metrics[key]==nil and not (category and live[category]) then
                device.metrics[key]=value
            end
        end
        -- Omitted old fields must not retain a stale observation next to a
        -- fresh sibling supplied by another source.
        for key in pairs(device.metric_observations or {}) do
            if device.metrics[key]==nil then device.metric_observations[key]=nil end
        end
    end
end

function M.new(options)
    options=options or {}
    return setmetatable({reader=options.reader or Hardware.new({id="gpu_drm",default_interval_ms=1000},options.input)},M)
end

function M:probe(context)
    return self.reader:probe(context)
end

function M:sample(context)
    local safe=context and context.safe_mode==true or false
    local now=Common.now_ns(context)
    if self.safe~=safe or (self.now and now<self.now) then self.cached=nil end
    self.safe,self.now=safe,now
    local result=self.reader:sample(context)
    if result.status=="ok" and result.data then
        mark(result,now)
        local ok,bytes=pcall(Wire.encode,result)
        self.cached=ok and bytes or nil
        return result
    end
    local reply={}
    for key,value in pairs(result) do reply[key]=value end
    if self.cached then
        local previous=Wire.decode(self.cached)
        reply.data=previous.data
        reply.value_timestamp_ns=previous.value_timestamp_ns or previous.timestamp_ns
        reply.sample_started_ns,reply.sample_finished_ns=previous.sample_started_ns,previous.sample_finished_ns
        reply.retained=true
        mark(reply,now,true,result.reason)
    else
        reply.data={devices={},anchors={},drm_scan={truncated=false,unattached_render_nodes=0,estimated_render_links=0}}
    end
    reply.data.process_scan={enabled=not context or context.scan_gpu_processes~=false,
        status="unavailable",quality="stale",reason=result.reason,truncated=false}
    return reply
end

function M:metadata(result)
    return {status=result.status,quality=result.retained and "stale" or result.quality,
        reason=result.reason,
        retained=result.retained or false,transport="process",observed_at_ns=result.value_timestamp_ns,
        sample_started_ns=result.sample_started_ns,sample_finished_ns=result.sample_finished_ns}
end

function M:close()
    if self.closed then return end
    self.closed=true
    self.cached=nil
    self.reader:close()
end

return M
