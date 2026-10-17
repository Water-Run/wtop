-- Native NVMe health follows the independently sampled, identity-checked
-- storage reader. Other devices retain the existing smartctl inspector.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local Matching = require("wtop.model.storage_health")
local Thermal = require("wtop.model.thermal")
local Model = require("wtop.inspectors.model")
local Native = require("wtop.native")
local M = {}
M.__index = M

function M.new(options)
    options = options or {}
    return setmetatable({ id = "storage.smart", domain = "storage", _method_style = true,
        native = options.native or Native, fallback = assert(options.fallback) }, M)
end

function M:probe(context)
    if type(self.native.read_nvme_health) == "function" then
        return Capability.available({ source = "NVME_IOCTL_ADMIN_CMD" })
    end
    return self.fallback:probe(context)
end

function M:enumerate(context)
    context = context or {}
    local items, err = self.fallback:enumerate(context)
    if type(self.native.read_nvme_health) ~= "function" then return items, err end
    local by_name = {}
    for _, disk in ipairs(context.snapshot and context.snapshot.disks
        and context.snapshot.disks.devices or {}) do
        if type(disk._health_key) == "string" then
            if by_name[disk.name] == nil then by_name[disk.name] = disk else by_name[disk.name] = false end
        end
    end
    local result, seen = items or {}, {}
    for _, item in ipairs(result) do
        local disk = by_name[item.name]
        if disk then
            item.native_id, item.native_key = disk.id, disk._health_key
            seen[disk.name] = true
        end
    end
    for name, disk in pairs(by_name) do
        if disk and not seen[name] then
            result[#result + 1] = { id = "/dev/" .. name, path = "/dev/" .. name,
                name = name, native_id = disk.id, native_key = disk._health_key }
        end
    end
    table.sort(result, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return result
end

function M:inspect(context, entity, depth)
    if not entity or not entity.native_key then return self.fallback:inspect(context, entity, depth) end
    context = context or {}
    local snapshot, now = context.snapshot or {}, Common.now_ns(context)
    local disk
    for _, row in ipairs(snapshot.disks and snapshot.disks.devices or {}) do
        if row.id == entity.native_id and row._health_key == entity.native_key then
            if disk then disk = nil; break end
            disk = row
        end
    end
    local health = disk and Matching.match(snapshot, disk)
    if not disk then
        return Model.result("unavailable", nil, {}, { timestamp_ns = now,
            reason = "storage_identity_changed", provider = "Linux NVMe" })
    end
    local state = snapshot.quality and snapshot.quality.disk_health or {}
    if not health then
        return Model.result("unavailable", nil, {}, { timestamp_ns = state.value_timestamp_ns or now,
            reason = state.reason or "nvme_health_unavailable", provider = "Linux NVMe" })
    end
    local sections, observed = {}, state.value_timestamp_ns or health.observed_at_ns
    if not health.nvme then
        if health.quality == "unavailable" and self.fallback:probe(context).available then
            return self.fallback:inspect(context, entity, depth)
        end
        local fields = {}
        for key, value in pairs(health.query_errors or {}) do
            fields[key] = Model.field(value, nil, { timestamp_ns = observed, source = health.source })
        end
        if next(fields) then sections[1] = Model.section("Query status", fields) end
        local status = health.quality == "denied" and "denied" or "unavailable"
        return Model.result(status, nil, sections, { timestamp_ns = observed,
            reason = "nvme_health_unavailable", quality = health.quality or status, provider = "Linux NVMe" })
    end
    local current = state.status == "ok" and type(state.value_timestamp_ns) == "number"
        and Thermal.current({ timestamp_ns = now, sensors = {}, quality = { sensors = state } })
    local quality = current and health.quality or "stale"
    local fields = {}
    for key, value in pairs(health.nvme) do
        if key ~= "source" then
            local unit = key == "temperature_celsius" and "celsius"
                or (key == "percentage_used" or key == "available_spare_percent"
                    or key == "available_spare_threshold_percent") and "percent" or nil
            fields[key] = Model.field(value, unit,
                { timestamp_ns = observed, quality = quality, source = health.nvme.source,
                    provider = "Linux NVMe" })
        end
    end
    sections[1] = Model.section("nvme_health", fields, { quality = quality })
    return Model.result("ok", nil, sections, { timestamp_ns = observed,
        quality = quality, provider = "Linux NVMe", source = health.source,
        cached = not current })
end

function M:invalidate(entity)
    if self.fallback.invalidate then return self.fallback:invalidate(entity) end
    return true
end

function M:close()
    if self.fallback.close then self.fallback:close() end
end

return M
