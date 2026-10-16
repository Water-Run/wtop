local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local Parser = require("wtop.format.windows_storage")
local Native = require("wtop.native")
local M = {}
M.__index = M

function M.new(options)
    options = options or {}
    local self = setmetatable({ id = "disk_health", default_interval_ms = 5000,
        _method_style = true, native = options.native or Native,
        deep = options.deep == true, disk_number = options.disk_number }, M)
    if not options._hardware_direct then
        return require("wtop.collectors.hardware_worker").new(self,
            { deep = self.deep, disk_number = self.disk_number }, self.native)
    end
    return self
end

function M:probe()
    return Capability.available({ source = "Windows storage queries" })
end

function M:sample(context)
    local now = Common.now_ns(context)
    if context and context.safe_mode then
        return Common.result("unavailable", now, nil, { reason = "safe_mode" })
    end
    local ok, data = pcall(self.native.collect_disk_health, self.deep, self.disk_number)
    if not ok or type(data) ~= "table" then
        return Common.result("error", now, nil, { reason = "native_collection_failed" })
    end
    local partial = data.quality == "partial"
    for _, device in ipairs(data.devices or {}) do
        local raw = device.raw_health or {}
        device.raw_health = nil
        device.temperature = Parser.temperatures(raw.temperature_data)
        device.nvme = Parser.nvme(raw.nvme_data)
        device.ata = Parser.ata(raw.ata_data)
        device.deep = raw.deep
        device.skipped = raw.skipped
        device.query_errors = {
            temperature = raw.temperature_error ~= 0 and raw.temperature_error or nil,
            nvme = raw.nvme_error ~= 0 and raw.nvme_error or nil,
            ata = raw.ata_error ~= 0 and raw.ata_error or nil,
        }
        device.quality = (device.temperature or device.nvme or device.ata) and "fresh" or "unavailable"
        if raw.temperature_data and not device.temperature
            or raw.nvme_data and not device.nvme or raw.ata_data and not device.ata then
            device.quality = "partial"
            partial = true
        end
        local has_temperature = false
        for _, channel in ipairs(device.temperature and device.temperature.channels or {}) do
            if type(channel.input) == "number" then has_temperature = true; break end
        end
        if not has_temperature and device.nvme and device.nvme.temperature_celsius then
            device.temperature = device.temperature or { channels = {} }
            local composite = { id = "temperature:0", index = 0, label = "Composite", type = "temperature",
                unit = "celsius", quality = "fresh", input = device.nvme.temperature_celsius,
                source = device.nvme.source, thresholds = {} }
            -- Keep descriptor metadata and unsupported sensors, but do not turn
            -- a missing property reading into a measured property temperature.
            local replaced = false
            for index, channel in ipairs(device.temperature.channels) do
                if channel.index == 0 then device.temperature.channels[index] = composite; replaced = true; break end
            end
            if not replaced then table.insert(device.temperature.channels, 1, composite) end
        end
    end
    return Common.result("ok", now, data, { quality = partial and "partial" or "fresh",
        reason = partial and "platform_data_partial" or nil })
end

return M
