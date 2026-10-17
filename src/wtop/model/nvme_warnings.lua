-- NVMe SMART Critical Warning is a current, non-persistent bit field.
-- libnvme src/nvme/types.h, enum nvme_smart_crit. Counts and wear are separate.
local Health = require("wtop.model.storage_health")
local M = {}
local REASONS = {
    "spare_below_threshold", "temperature_threshold", "reliability_degraded",
    "media_read_only", "volatile_backup_failed", "persistent_memory",
}
local MAX_DISKS, MAX_HEALTH = 8192, 512

function M.decode(mask)
    if type(mask) ~= "number" or mask % 1 ~= 0 or mask < 0 or mask > 255 then return nil end
    local result = { mask = mask, known_mask = mask & 0x3f, unknown_mask = mask & 0xc0, reasons = {} }
    for index, reason in ipairs(REASONS) do
        if mask & (1 << (index - 1)) ~= 0 then result.reasons[#result.reasons + 1] = reason end
    end
    return result
end

local function unique(rows, maximum)
    local result, incomplete = {}, false
    for index, row in ipairs(rows) do
        if index > maximum then return nil end
        if type(row) == "table" and type(row.id) == "string" then
            if result[row.id] == nil then result[row.id] = row
            else result[row.id], incomplete = false, true end
        else
            incomplete = true
        end
    end
    return result, incomplete
end

function M.summary(snapshot, now_ns)
    snapshot = snapshot or {}
    local result = { observations = {}, signals = {}, partial = false }
    now_ns = now_ns or snapshot.timestamp_ns
    if type(now_ns) ~= "number" or now_ns ~= now_ns or now_ns < 0 or now_ns >= math.huge then return result end
    local state = snapshot.quality and snapshot.quality.disk_health
    local data = snapshot.disk_health
    if type(state) ~= "table" or state.status ~= "ok"
        or (state.quality ~= "fresh" and state.quality ~= "partial")
        or type(data) ~= "table" or type(data.devices) ~= "table" then return result end
    local disks = snapshot.disks and snapshot.disks.devices or {}
    if type(disks) ~= "table" then return result end
    local disk_ids, disk_incomplete = unique(disks, MAX_DISKS)
    local health_ids, health_incomplete = unique(data.devices, MAX_HEALTH)
    if not disk_ids or not health_ids then result.partial = true; return result end
    result.partial = state.quality == "partial" or data.truncated == true or disk_incomplete or health_incomplete
    local critical, unknown = false, false
    for _, disk in ipairs(disks) do
        local health = type(disk) == "table" and health_ids[disk.id]
        if health and disk_ids[disk.id] == disk
            and type(disk._health_key) == "string" and disk._health_key ~= ""
            and health._health_key == disk._health_key
            and (health.quality == "fresh" or health.quality == "partial")
            and type(health.nvme) == "table" and Health.current(snapshot, health, now_ns) then
            local decoded = M.decode(health.nvme.critical_warning)
            if decoded then
                decoded.id, decoded.name, decoded.scope = disk.id, disk.name, health.nvme.scope or health.scope
                decoded.observed_at_ns = Health.observed_at(snapshot, health)
                result.observations[#result.observations + 1] = decoded
                critical = critical or decoded.known_mask ~= 0
                unknown = unknown or decoded.unknown_mask ~= 0
                result.partial = result.partial or health.quality == "partial"
            else
                result.partial = true
            end
        elseif health then
            result.partial = true
        end
    end
    -- Namespaces can share a controller. These are categories of evidence,
    -- not an inferred number of failing drives, nor a unioned device mask.
    if critical then
        result.signals[#result.signals + 1] = { resource = "disk_health", code = "nvme_critical_warning",
            severity = "critical", message = "An NVMe health page reports a current critical warning" }
    end
    if unknown then
        result.signals[#result.signals + 1] = { resource = "disk_health", code = "nvme_unknown_warning_bits",
            severity = "warning", message = "An NVMe health page reports unrecognized warning bits" }
    end
    return result
end

return M
