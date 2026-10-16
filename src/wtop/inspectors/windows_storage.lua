local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local Health = require("wtop.collectors.windows_storage")
local Matching = require("wtop.model.storage_health")
local Model = require("wtop.inspectors.model")
local M = {}
M.__index = M

function M.new(options)
    options = options or {}
    return setmetatable({ id = "storage.smart", domain = "storage", _method_style = true,
        native = options.native or require("wtop.native") }, M)
end

function M:probe()
    return Capability.available({ source = "Windows storage queries" })
end

function M:enumerate(context)
    local result = {}
    for _, disk in ipairs(context.snapshot and context.snapshot.disks
        and context.snapshot.disks.devices or {}) do
        if type(disk._health_key) == "string" and type(disk.id) == "string"
            and disk.id:match("^PhysicalDrive%d+$") then
            result[#result + 1] = { id = disk.id, name = disk.name,
                key = disk._health_key, identity = disk.identity }
        end
    end
    return result
end

function M:close()
    if self.reader then self.reader:close() end
    self.reader, self.selected, self.selected_id, self.result, self.at_ns = nil, nil, nil, nil, nil
end

function M:inspect(context, entity)
    context, entity = context or {}, entity or {}
    local now = Common.now_ns(context)
    local snapshot = context.snapshot or {}
    local disk
    for _, current in ipairs(snapshot.disks and snapshot.disks.devices or {}) do
        if current.id == entity.id and current._health_key == entity.key then
            if disk then disk = nil; break end
            disk = current
        end
    end
    if not disk or not disk.id:match("^PhysicalDrive%d+$") then
        self:close()
        return Model.result("unavailable", nil, {}, { timestamp_ns = now,
            reason = "storage_identity_changed", provider = "Windows storage" })
    end
    if self.at_ns and now < self.at_ns then self:close() end
    if self.selected ~= entity.key or self.selected_id ~= disk.id then
        self:close(); self.selected = entity.key
        self.selected_id = disk.id
        self.reader = Health.new({ native = self.native, deep = true,
            disk_number = tonumber(disk.id:match("(%d+)$")) })
    end
    local cached = self.result ~= nil and self.at_ns ~= nil and now - self.at_ns < 60000000000
    if not cached then
        local result = self.reader:sample(context)
        if result.status ~= "ok" then
            return Model.result(result.status, nil, {}, { timestamp_ns = now,
                quality = result.quality, reason = result.reason, provider = "Windows storage" })
        end
        self.result, self.at_ns = result, result.value_timestamp_ns or result.timestamp_ns
    end
    local health = Matching.match(snapshot, disk, self.result.data)
    if not health then
        self:close()
        return Model.result("unavailable", nil, {}, { timestamp_ns = now,
            reason = "storage_identity_changed", provider = "Windows storage" })
    end
    local function field(value, unit, source)
        return Model.field(value, unit, { timestamp_ns = self.at_ns, source = source,
            provider = "Windows storage" })
    end
    local sections, usable = {}, health.nvme ~= nil or health.ata ~= nil
    for _, channel in ipairs(health.temperature and health.temperature.channels or {}) do
        if type(channel.input) == "number" then usable = true end
        sections[#sections + 1] = Model.section(channel.label or channel.id, {
            temperature = field(channel.input, "celsius", channel.source),
            critical = field(channel.thresholds and channel.thresholds.crit, "celsius", channel.source),
        })
    end
    if health.nvme then
        local fields = {}
        for key, value in pairs(health.nvme) do
            if key ~= "source" then fields[key] = field(value,
                key == "temperature_celsius" and "celsius" or nil, health.nvme.source) end
        end
        sections[#sections + 1] = Model.section("nvme_health", fields)
    end
    if health.ata then
        for _, attribute in ipairs(health.ata.attributes or {}) do
            sections[#sections + 1] = Model.section("ATA " .. attribute.id, {
                current = field(attribute.current, nil, health.ata.source),
                worst = field(attribute.worst, nil, health.ata.source),
                raw_hex = field(attribute.raw_hex, nil, health.ata.source),
            })
        end
    end
    local query_fields = {}
    for name, code in pairs(health.query_errors or {}) do
        query_fields[name] = field(code, nil, "DeviceIoControl")
    end
    if next(query_fields) then sections[#sections + 1] = Model.section("Query status", query_fields) end
    local denied = false
    for _, code in pairs(health.query_errors or {}) do if code == 5 then denied = true end end
    local status = usable and "ok" or denied and "denied" or "unavailable"
    return Model.result(status, nil, sections,
        { timestamp_ns = self.at_ns, quality = usable and health.quality or status,
            provider = "Windows storage", cache_ttl_ms = 60000, cached = cached })
end

return M
