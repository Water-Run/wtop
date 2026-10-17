local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Identity = require("wtop.linux.nvme_identity")
local Parser = require("wtop.format.nvme_health")
local Native = require("wtop.native")
local M = {}
M.__index = M

local function integer(value)
    local token = type(value) == "string" and value:match("^%s*(%d+)%s*$")
    local number = token and tonumber(token)
    if number and math.type(number) == "integer" and number >= 0 then return number end
end

local function identity(fs, base, name)
    local device = fs:read(base .. "/" .. name .. "/dev", 64)
    local major, minor
    if type(device) == "string" then major, minor = device:match("^%s*(%d+):(%d+)%s*$") end
    major, minor = tonumber(major), tonumber(minor)
    local sequence = integer(fs:read(base .. "/" .. name .. "/diskseq", 64))
    local key = Identity.key(name, major, minor, sequence)
    if not key then return nil end
    return { id = major .. ":" .. minor, name = name, major = major, minor = minor,
        diskseq = sequence, _health_key = key }
end

function M.new(options)
    options = options or {}
    return setmetatable({ id = "disk_health", _method_style = true,
        fs = options.fs or FS.default, reader = options.reader or Native.read_nvme_health,
        base_path = Common.absolute_path("base_path", options.base_path, "/sys/block"),
        max_devices = Common.positive_integer("max_devices", options.max_devices, 128, 128),
        default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 5000),
    }, M)
end

function M:_discover(context)
    local fs = Common.fs(context, self.fs)
    local entries, err, truncated = fs:list(self.base_path, 4096)
    if not entries then return nil, err end
    local names, seen = {}, {}
    for _, name in ipairs(entries) do
        if Identity.name(name) then
            if seen[name] then truncated = true
            else names[#names + 1], seen[name] = name, true end
        end
    end
    table.sort(names)
    if #names > self.max_devices then truncated = true end
    local devices = {}
    for index = 1, math.min(#names, self.max_devices) do
        local row = identity(fs, self.base_path, names[index])
        if row then devices[#devices + 1] = row else truncated = true end
    end
    return devices, nil, truncated == true
end

function M:probe(context)
    if type(self.reader) ~= "function" then
        return Capability.unavailable("nvme_health_unavailable", { source = "NVME_IOCTL_ADMIN_CMD" })
    end
    local devices, err = self:_discover(context)
    if devices and #devices > 0 then return Capability.available({ source = "NVME_IOCTL_ADMIN_CMD" }) end
    if err and FS.error_status(err) == "denied" then
        return Capability.denied("nvme_health_unavailable", { source = self.base_path })
    end
    return Capability.unavailable("nvme_health_unavailable", { source = self.base_path })
end

function M:sample(context)
    local started = Common.now_ns(context)
    if context and context.safe_mode then
        return Common.result("unavailable", started, nil, { reason = "safe_mode" })
    end
    if type(self.reader) ~= "function" then
        return Common.result("unavailable", started, nil, { reason = "nvme_health_unavailable" })
    end
    local devices, err, truncated = self:_discover(context)
    if not devices then
        return Common.result(FS.error_status(err), started, nil, { reason = "nvme_health_unavailable" })
    end
    if #devices == 0 then
        return Common.result("unavailable", started, nil, { reason = "nvme_health_unavailable" })
    end
    local data = { devices = devices, truncated = truncated, source = "NVME_IOCTL_ADMIN_CMD" }
    local partial = truncated
    for _, device in ipairs(devices) do
        device.source, device.scope = "/dev/" .. device.name, "controller"
        local ok, bytes, message, errno, nvme_status = pcall(self.reader,
            device.name, device.major, device.minor, device.diskseq)
        local current = identity(Common.fs(context, self.fs), self.base_path, device.name)
        local health = ok and Parser.parse(bytes)
        if not current or current._health_key ~= device._health_key then
            device.quality = "gap"
        elseif health then
            device.quality, device.nvme = "fresh", health
            health.scope = "controller"
            device.temperature = { channels = {} }
            if health.temperature_celsius ~= nil then
                device.temperature.channels[1] = { id = "temperature:0", index = 0,
                    type = "temperature", unit = "celsius", label = "Composite",
                    input = health.temperature_celsius, quality = "fresh", thresholds = {},
                    source = health.source }
            end
        else
            device.quality = (errno == 1 or errno == 13) and "denied" or "unavailable"
            if errno == 116 or errno == 40 or errno == 19 or errno == 6 then device.quality = "gap" end
            if not ok then device.quality = "error" end
            device.query_errors = { errno = type(errno) == "number" and errno or nil,
                nvme_status = type(nvme_status) == "number" and nvme_status or nil }
        end
        partial = partial or device.quality ~= "fresh"
        device.observed_at_ns = Common.now_ns(context)
    end
    local finished = Common.now_ns(context)
    return Common.result("ok", finished, data, { quality = partial and "partial" or "fresh",
        reason = partial and "platform_data_partial" or nil, source = data.source,
        duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

return M
