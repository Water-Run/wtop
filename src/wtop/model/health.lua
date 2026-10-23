-- Current observations, shared by the interactive monitor and Agent.
-- No collectors, host calls, full-snapshot copies, or persistent alarm state.
local Quality = require("wtop.model.quality")
local Thermal = require("wtop.model.thermal")
local NVMeWarnings = require("wtop.model.nvme_warnings")
local M = {}
local RANK = { ok = 0, warning = 1, critical = 2 }
local ACTIVE_MD = { active = true, clean = true, ["active-idle"] = true,
    readonly = true, ["read-auto"] = true }
local SENSOR_TYPES = { temperature = true, voltage = true, current = true,
    power = true, energy = true, fan = true }
local SENSOR_QUALITY = { fresh = true, measured = true, partial = true, estimated = true }

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function percentage(used, total)
    if finite(used) and finite(total) and total > 0 then
        return math.max(0, math.min(100, used * 100 / total))
    end
end

local function sensor_subject(device, channel)
    return tostring(device.name or device.id or "?") .. " / "
        .. tostring(channel.label or channel.id or channel.index or "?")
end

function M.summary(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local signals, highest = {}, "ok"
    local function current(resource) return Quality.current_source(snapshot.quality, resource) end
    local function add(resource, code, severity, value, unit, message, subject)
        signals[#signals + 1] = { resource = resource, code = code,
            severity = severity, value = value, unit = unit, message = message,
            subject = subject }
        if RANK[severity] > RANK[highest] then highest = severity end
    end
    local function threshold(resource, code, value, warning, critical, unit, message, source, subject)
        if not current(source or resource) or not finite(value) then return end
        if value >= warning then
            add(resource, code, value >= critical and "critical" or "warning",
                value, unit, message, subject)
        end
    end
    for _, row in ipairs(NVMeWarnings.summary(snapshot).signals) do
        add(row.resource, row.code, row.severity, nil, nil, row.message)
    end
    local cpu = snapshot.cpu or {}
    local total = cpu.total or {}
    -- A newly online core can give the source a gap while the total remains
    -- fresh. Prefer the total's own quality; legacy snapshots fall back to
    -- the source. Source read failures still fence every threshold below.
    local cpu_current = Quality.cpu_total_current(snapshot)
    local load = cpu.load or {}
    local topology = snapshot.cpu_info and snapshot.cpu_info.topology or {}
    local logical = topology.threads or #(cpu.cores or {})
    if cpu_current then
        threshold("cpu", "high_utilization", total.utilization, 75, 90, "percent",
            "CPU utilization is elevated")
        threshold("cpu", "high_iowait", total.iowait, 10, 20, "percent",
            "CPU time waiting for I/O is elevated")
    end
    if finite(logical) and logical > 0 and finite(load.one) then
        threshold("cpu", "high_load", load.one / logical, 1, 1.5, "load_per_cpu",
            "One-minute load exceeds logical CPU capacity")
    end
    local memory = snapshot.memory or {}
    local memory_used = percentage(memory.used_bytes, memory.total_bytes)
    threshold("memory", "high_usage", memory_used, 85, 95, "percent",
        "Memory usage is elevated")
    for _, resource in ipairs({ "cpu", "memory", "io" }) do
        local pressure = snapshot.pressure and snapshot.pressure[resource] or {}
        threshold(resource, "sustained_pressure", pressure.some and pressure.some.avg10,
            5, 20, "percent", resource .. " pressure stalls are elevated", "pressure")
        threshold(resource, "full_pressure", pressure.full and pressure.full.avg10,
            1, 5, "percent", resource .. " full stalls are elevated", "pressure")
    end
    local busiest, busiest_name, no_path, degraded
    for _, device in ipairs(snapshot.disks and snapshot.disks.devices or {}) do
        if finite(device.busy_percent) and device.busy_quality ~= "estimated"
            and Quality.current_metric(device.busy_quality or device.quality)
            and not Quality.UNUSABLE_FOR_ALERT[device.quality]
            and (not busiest or device.busy_percent > busiest) then
            busiest, busiest_name = device.busy_percent, device.name or device.id
        end
        local counters = device.nvme and device.nvme.counters
        local failure = counters and counters.io_failures_no_path
        no_path = no_path or type(failure) == "table" and failure.status == "ok"
            and failure.delta_quality == "fresh" and finite(failure.new) and failure.new > 0
        local stack = device.stack
        degraded = degraded or type(stack) == "table" and stack.kind == "md"
            and stack.status == "ok" and ACTIVE_MD[stack.array_state]
            and finite(stack.raid_disks) and stack.raid_disks > 0
            and finite(stack.degraded) and stack.degraded > 0 and stack.degraded <= stack.raid_disks
    end
    threshold("storage", "device_busy", busiest, 80, 95, "percent",
        "A block device reports high busy time", "disks", busiest_name)
    if current("disks") then
        if no_path then add("disks", "nvme_no_path_io_failure", "warning", nil, nil,
            "NVMe no-path I/O failure counter increased") end
        if degraded then add("disks", "md_array_degraded", "warning", nil, nil,
            "An active MD array reports missing devices") end
    end
    local fullest, mount_name
    for _, mount in ipairs(snapshot.mounts and snapshot.mounts.mounts or {}) do
        local used = mount.capacity and mount.capacity.used_percent
        if mount.kind == "local" and not Quality.UNUSABLE_FOR_ALERT[mount.quality]
            and finite(used) and (not fullest or used > fullest) then
            fullest, mount_name = used, mount.target or mount.mount_point or mount.id
        end
    end
    threshold("mounts", "high_capacity", fullest, 92, 98, "percent",
        "A local filesystem is nearly full", nil, mount_name)
    local gpu_max, gpu_name
    for _, device in ipairs(snapshot.gpus and snapshot.gpus.devices or {}) do
        local value = device.metrics and device.metrics.utilization_percent
        if finite(value) and Quality.current_metric(
                Quality.gpu_metric_quality(device, "utilization_percent", "utilization"))
            and (not gpu_max or value > gpu_max) then
            gpu_max, gpu_name = value, device.model_name or device.card or device.id
        end
    end
    threshold("gpu", "high_utilization", gpu_max, 85, 97, "percent",
        "GPU utilization is elevated", "gpus", gpu_name)
    local hottest, sensor_alarm, sensor_fault
    local sensors_current = Thermal.current(snapshot)
    for _, device in ipairs(snapshot.sensors and snapshot.sensors.devices or {}) do
        for _, channel in ipairs(device.channels or {}) do
            if sensors_current and (device.quality == nil or SENSOR_QUALITY[device.quality])
                and (channel.quality == nil or SENSOR_QUALITY[channel.quality]) and SENSOR_TYPES[channel.type] then
                if channel.alarm == true and not (channel.errors and channel.errors.alarm) then
                    sensor_alarm = sensor_alarm or sensor_subject(device, channel)
                end
                if channel.fault == true and not (channel.errors and channel.errors.fault) then
                    sensor_fault = sensor_fault or sensor_subject(device, channel)
                end
            end
            if channel.type == "temperature" and (channel.unit == nil or channel.unit == "celsius")
                and Thermal.input_current(snapshot, device, channel) then
                local limits, errors = channel.thresholds or {}, channel.errors or {}
                local critical = not errors.crit and limits.crit or nil
                if not finite(critical) and not errors.emergency then critical = limits.emergency end
                local warning = not errors.max and limits.max or nil
                local severity = finite(critical) and channel.input >= critical and "critical"
                    or finite(warning) and channel.input >= warning and "warning" or nil
                if severity and (not hottest or RANK[severity] > RANK[hottest.severity]
                    or severity == hottest.severity and channel.input > hottest.value) then
                    hottest = { severity = severity, value = channel.input,
                        subject = sensor_subject(device, channel) }
                end
            end
        end
    end
    if hottest then add("sensors", "temperature_threshold", hottest.severity, hottest.value,
        "celsius", hottest.severity == "critical"
            and "A temperature sensor reached its critical threshold"
            or "A temperature sensor exceeded its maximum threshold", hottest.subject) end
    if sensor_alarm then add("sensors", "sensor_alarm", "warning", nil, nil,
        "A sensor reports a current alarm flag", sensor_alarm) end
    if sensor_fault then add("sensors", "sensor_fault", "warning", nil, nil,
        "A sensor reports a current fault flag", sensor_fault) end
    local aer_fatal, aer_nonfatal
    local function increased(change)
        return type(change) == "table" and change.quality == "fresh"
            and finite(change.new_reports) and change.new_reports > 0
    end
    if current("inventory") then
        for _, device in ipairs(snapshot.inventory and snapshot.inventory.pci
                and snapshot.inventory.pci.devices or {}) do
            local aer = device.aer
            if aer then
                local root = aer.rootport and aer.rootport.changes
                aer_fatal = aer_fatal or increased(aer.fatal and aer.fatal.change)
                    or increased(root and root.fatal)
                aer_nonfatal = aer_nonfatal or increased(aer.nonfatal and aer.nonfatal.change)
                    or increased(root and root.nonfatal)
            end
        end
    end
    if aer_fatal then add("inventory", "pcie_aer_fatal", "critical", nil, nil,
        "New fatal PCIe AER reports were observed; the reporting link may not be the failing endpoint") end
    if aer_nonfatal then add("inventory", "pcie_aer_nonfatal", "warning", nil, nil,
        "New nonfatal PCIe AER reports were observed; inspect the reporting links") end
    local keys = {}
    for resource in pairs(snapshot.quality or {}) do keys[#keys + 1] = resource end
    table.sort(keys)
    for _, resource in ipairs(keys) do
        local quality = snapshot.quality[resource]
        local severity = Quality.SOURCE_FAILURE_SEVERITY[resource]
        local status, freshness = quality.status, quality.quality
        if severity then
            if status and status ~= "ok" then add(resource, "data_unavailable", severity, nil, nil,
                "A monitoring source could not be read")
            elseif freshness == "stale" then add(resource, "data_stale", "warning", nil, nil,
                "A monitoring source is showing a retained value")
            elseif severity == "critical" and (freshness == "gap" or freshness == "reset") then
                add(resource, "data_gap", "warning", nil, nil,
                    "A core monitoring rate could not be calculated")
            elseif severity == "critical" and (freshness == "partial" or freshness == "truncated"
                or freshness == "error" or freshness == "denied" or freshness == "unavailable") then
                add(resource, "data_incomplete", "warning", nil, nil,
                    "Part of a core monitoring source is unavailable")
            end
        end
    end
    table.sort(signals, function(left, right)
        if left.severity ~= right.severity then return RANK[left.severity] > RANK[right.severity] end
        if left.resource ~= right.resource then return left.resource < right.resource end
        return left.code < right.code
    end)
    local core_observed = cpu_current and finite(total.utilization)
        or current("memory") and finite(memory_used)
    return { signals = signals, state = #signals == 0 and not core_observed and "unknown" or highest }
end

return M
