-- The child collects DRM/sysfs/fdinfo only; SDK leases stay in the parent.
local Capability = require("wtop.core.capability")
local GPU = require("wtop.collectors.gpu")
local M = {}
M.__index = M

function M.new(options)
    options = options or {}
    local configuration = {}
    for key, value in pairs(options) do configuration[key] = value end
    configuration.nvml, configuration.amdsmi, configuration.levelzero = false, false, false
    return setmetatable({id="gpu_drm",default_interval_ms=1000,_method_style=true,
        collector=GPU.new(configuration)},M)
end

function M:probe()
    return Capability.available({source="drm_input"})
end

function M:sample(context)
    local result = self.collector:_sample_drm(context)
    -- by_id shares the device records; keep it in the child's counter history
    -- and avoid serializing every process/client/device twice.
    if result.data then
        local data = {}
        for key,value in pairs(result.data) do if key~="by_id" then data[key]=value end end
        local reply = {}
        for key,value in pairs(result) do reply[key]=value end
        reply.data=data
        return reply
    end
    return result
end

return M
