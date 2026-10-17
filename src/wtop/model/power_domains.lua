-- The Linux intel_rapl common driver names PP0 "core" and PP1 "uncore".
-- PP1 is the graphics power plane. This identifies a RAPL domain, not a PCI
-- adapter or total card power. Other drivers' "uncore" names have no such ABI.
local Power = require("wtop.model.power")
local M = {}
local BACKENDS = { ["intel-rapl"] = true, ["intel-rapl-mmio"] = true }
local CHILDREN = { core = "cpu_cores", uncore = "graphics", dram = "memory" }
local function finite(value)
    return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

function M.identities(zones)
    local by_id = {}
    for index, zone in ipairs(zones or {}) do
        if index > 1024 then return {} end
        if type(zone) == "table" and type(zone.id) == "string" then
            if by_id[zone.id] == nil then by_id[zone.id] = zone else by_id[zone.id] = false end
        end
    end
    return by_id
end

function M.kind(zone, by_id)
    if type(zone) ~= "table" or not BACKENDS[zone.source_kind] or by_id[zone.id] ~= zone then return nil end
    if zone.id:sub(1, #zone.source_kind + 1) ~= zone.source_kind .. ":" then return nil end
    local root = zone.parent_id and by_id[zone.parent_id] or zone
    if not root or root.parent_id or root.source_kind ~= zone.source_kind then return nil end
    if type(root.id) ~= "string" or root.id:sub(1, #root.source_kind + 1) ~= root.source_kind .. ":"
        or not root.id:sub(#root.source_kind + 2):match("^%d+$") then return nil end
    local package = root.name == "package" or type(root.name) == "string" and root.name:match("^package%-%d+$")
    if not zone.parent_id then
        if package then return "cpu_package" end
        if root.name == "psys" or type(root.name) == "string" and root.name:match("^psys%-%d+$") then return "platform" end
        return nil
    end
    if package and zone.id:sub(1, #root.id + 1) == root.id .. ":"
        and zone.id:sub(#root.id + 2):match("^%d+$") then return CHILDREN[zone.name] end
end

function M.quality(zone, now_ns, source)
    if type(source) == "table" and source.status and source.status ~= "ok" then
        return source.quality == "stale" and "stale" or source.status
    end
    local state = type(source) == "table" and (source.quality or source.status) or source
    if Power.unusable(state) then return state end
    if state and state ~= "fresh" and state ~= "partial" and state ~= "ok" then return "unknown" end
    if Power.unusable(zone.quality) then return zone.quality end
    local q = zone.power_quality
    if q ~= "measured" and q ~= "wrapped" then return q or "unknown" end
    if not finite(now_ns) or not finite(zone.observed_at_ns) or zone.observed_at_ns > now_ns then return "unknown" end
    if now_ns - zone.observed_at_ns > 15000000000 then return "stale" end
    return zone.quality == "partial" and "partial" or q
end

function M.graphics(snapshot)
    local power = snapshot.power or {}
    local ids, rows = M.identities(power.zones), {}
    for index, zone in ipairs(power.zones or {}) do
        if index > 1024 then break end
        if M.kind(zone, ids) == "graphics" then
            local q = M.quality(zone, snapshot.timestamp_ns, snapshot.quality and snapshot.quality.power)
            local current = q == "measured" or q == "wrapped" or q == "partial"
            rows[#rows + 1] = { id = zone.id, parent_id = zone.parent_id, source = zone.source,
                source_kind = zone.source_kind, scope = "rapl_graphics_domain", role_source = "linux_intel_rapl",
                watts = current and Power.reading(zone.power_watts) or nil,
                quality = q, observed_at_ns = zone.observed_at_ns, interval_ns = zone.power_interval_ns,
                controls_enabled = zone.controls_enabled, pci_device_known = false }
        end
    end
    return rows, power.truncated == true or #(power.zones or {}) > 1024
end

return M
