-- Human-readable hardware summary from the privacy-filtered Snapshot export.
-- This module does no probing and never walks raw collector tables.
local Common = require("wtop.collectors.common")

local M = {}

local function object(value)
    return type(value) == "table" and value or {}
end

local function list(value)
    return type(value) == "table" and value or {}
end

local function number(value, digits)
    if type(value) ~= "number" or value ~= value
        or value == math.huge or value == -math.huge then return nil end
    if digits == nil then return tostring(value) end
    return string.format("%." .. digits .. "f", value)
end

local function bytes(value)
    if type(value) ~= "number" or value ~= value or value < 0
        or value == math.huge then return nil end
    local units = { "B", "KiB", "MiB", "GiB", "TiB", "PiB" }
    local index = 1
    while value >= 1024 and index < #units do
        value, index = value / 1024, index + 1
    end
    return index == 1 and number(value, 0) .. " " .. units[index]
        or number(value, 2) .. " " .. units[index]
end

local function quantity(value, divisor, suffix, digits)
    if type(value) ~= "number" then return nil end
    local formatted = number(value / divisor, digits)
    return formatted and formatted .. suffix or nil
end

local function cell(value)
    if value == nil then return "—" end
    if type(value) == "boolean" then return value and "yes" or "no" end
    local raw = tostring(value)
    local shortened = #raw > 256
    raw = Common.safe_text(raw, 256) or ""
    raw = raw:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub("\\", "\\\\"):gsub("|", "\\|"):gsub("`", "\\`")
        :gsub("%[", "\\["):gsub("%]", "\\]")
    return raw .. (shortened and "…" or "")
end

local function table_section(lines, title, headers, items, fields, source)
    lines[#lines + 1] = "## " .. title
    lines[#lines + 1] = ""
    items = list(items)
    if #items == 0 then
        lines[#lines + 1] = "No records in this snapshot. See Collection status above."
    else
        local headings = {}
        for _, heading in ipairs(headers) do headings[#headings + 1] = cell(heading) end
        lines[#lines + 1] = "| " .. table.concat(headings, " | ") .. " |"
        local bars = {}
        for _ = 1, #headings do bars[#bars + 1] = "---" end
        lines[#lines + 1] = "| " .. table.concat(bars, " | ") .. " |"
        for _, item in ipairs(items) do
            local values = fields(item)
            for index = 1, #headers do values[index] = cell(values[index]) end
            lines[#lines + 1] = "| " .. table.concat(values, " | ") .. " |"
        end
    end
    if object(source).truncated == true then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "The source list was truncated."
    end
    lines[#lines + 1] = ""
end

local function captured_time(unix_ns)
    if type(unix_ns) ~= "number" or unix_ns < 0 then return nil end
    local ok, value = pcall(os.date, "!%Y-%m-%d %H:%M:%S UTC",
        math.floor(unix_ns / 1000000000))
    return ok and value or nil
end

local SENSOR_UNITS = {
    celsius = "C", rpm = "rpm", volts = "V", amperes = "A",
    watts = "W", joules = "J",
}

local function named_id(item)
    item = object(item)
    if item.name and item.id and item.name ~= item.id then
        return tostring(item.name) .. " (" .. tostring(item.id) .. ")"
    end
    return item.name or item.id
end

function M.render(snapshot)
    snapshot = object(snapshot)
    local lines = { "# wtop hardware report", "" }
    local producer, system = object(snapshot.producer), object(snapshot.system)
    local host, kernel = object(system.host), object(system.kernel)
    local native_host = object(snapshot.host)
    local firmware, cpu_info = object(system.firmware), object(snapshot.cpu_info)
    local cpu_identity, topology = object(cpu_info.identity), object(cpu_info.topology)
    local memory = object(snapshot.memory)
    lines[#lines + 1] = "Captured: " .. cell(captured_time(snapshot.captured_unix_ns))
    lines[#lines + 1] = "Producer: " .. cell(producer.name) .. " " .. cell(producer.version)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Values and source states reflect one snapshot. Firmware declarations are not live measurements."
    lines[#lines + 1] = ""

    local host_items = {
        { "Hostname", host.hostname or native_host.nodename },
        { "Architecture", host.architecture or native_host.machine },
        { "Operating system", object(system.distribution).pretty_name
            or kernel.type or native_host.sysname },
        { "Kernel", kernel.release or native_host.release },
        { "System vendor", firmware.system_vendor },
        { "Product", firmware.product_version or firmware.product_name },
        { "Board", firmware.board_name }, { "BIOS", firmware.bios_version },
        { "Chassis", firmware.chassis_type },
    }
    table_section(lines, "Host", { "Field", "Value" }, host_items,
        function(row) return row end)

    local quality = object(snapshot.quality)
    local names = {}
    for name in pairs(quality) do
        if type(name) == "string" then names[#names + 1] = name end
    end
    table.sort(names)
    table_section(lines, "Collection status", { "Source", "Status", "Quality", "Reason" },
        names, function(name)
            local entry = object(quality[name])
            return { name, entry.status, entry.quality, entry.reason }
        end)

    local cpu_items = {
        { "Model", cpu_identity.model_name }, { "Vendor", cpu_identity.vendor },
        { "Sockets", topology.sockets }, { "Physical cores", topology.physical_cores },
        { "Logical CPUs", topology.threads }, { "Online CPUs", topology.online_threads },
        { "Core types", cpu_identity.core_type_count },
        { "Compute units", topology.compute_units },
    }
    table_section(lines, "CPU", { "Field", "Value" }, cpu_items,
        function(row) return row end)
    local cpuid = object(cpu_info.cpuid)
    if cpuid.status then
        local comparison=object(cpuid.os_comparison)
        table_section(lines,"CPU hardware observation",{"Field","Value"},{
            {"Source",cpuid.source},{"Status",cpuid.status},{"Quality",cpuid.quality},
            {"Sample age",quantity(cpuid.age_ms,1000," s",3)},
            {"Topology matches OS",comparison.topology_matches},{"Caches match OS",comparison.cache_matches},
        },function(row)return row end)
        if #list(cpuid.core_types)>0 then
            local type_source=cpuid.core_types[1].source
            for _,kind in ipairs(cpuid.core_types)do if kind.source~=type_source then type_source="CPUID";break end end
            local columns={"Type","Native model","Logical CPUs","Physical cores","Source"}
            local ranking=false
            for _,kind in ipairs(cpuid.core_types)do if kind.efficiency_ranking_minimum~=nil then ranking=true;break end end
            if ranking then columns[#columns+1]="Power efficiency rank"end
            table_section(lines,"CPU hardware core types ("..(type_source or "CPUID")..")",
                columns,cpuid.core_types,function(kind)
                    local row={(kind.model_name or "CPU").." "..string.format("0x%02x",kind.core_type),kind.native_model_id,kind.logical_cpu_count,kind.physical_core_count,kind.source}
                    if ranking and kind.efficiency_ranking_minimum~=nil then
                        local minimum,maximum=kind.efficiency_ranking_minimum,kind.efficiency_ranking_maximum
                        row[6]=tostring(minimum)..(maximum~=minimum and "-"..maximum or "")
                            .." · "..kind.efficiency_ranking_cpu_count.."/"..kind.logical_cpu_count.." CPUs"
                    end
                    return row
                end,cpuid)
        end
        table_section(lines, "CPU instruction capabilities (observed logical CPUs)",
            { "Feature", "Reported CPUs", "Hardware support", "OS usable", "Usability unknown" },
            cpuid.features, function(feature)
                return { feature.name, feature.reported_cpus, feature.hardware_cpus,
                    feature.usable_cpus, feature.unknown_usability_cpus }
            end, cpuid)
    end
    table_section(lines, "CPU caches", { "Level", "Type", "Instances", "Total capacity" },
        cpu_info.cache_summary, function(cache)
            return { cache.level, cache.type, cache.instances, bytes(cache.total_size_bytes) }
        end, cpu_info)
    local cpu_frequency = object(snapshot.cpu_frequency)
    table_section(lines, "CPU frequency policies", { "Policy", "Driver", "Governor", "Current", "Source" },
        cpu_frequency.policies, function(policy)
            local frequencies = object(policy.frequencies)
            return { policy.policy or policy.id, policy.driver, policy.governor,
                quantity(frequencies.current_hz, 1000000000, " GHz", 2),
                frequencies.current_source }
        end, cpu_frequency)

    local memory_items = {
        { "Installed memory", bytes(memory.total_bytes) },
        { "Available memory", bytes(memory.available_bytes) },
        { "Swap", bytes(memory.swap_total_bytes) },
    }
    table_section(lines, "Memory", { "Field", "Value" }, memory_items,
        function(row) return row end)
    local dimms = object(snapshot.memory_devices)
    table_section(lines, "Memory devices", { "Locator", "Capacity", "Type", "Speed", "Manufacturer", "Part" },
        dimms.devices, function(device)
            return { device.locator or device.id, bytes(device.size_bytes), device.memory_type,
                quantity(device.configured_speed_mts or device.speed_mts, 1, " MT/s", 0),
                device.manufacturer, device.part_number }
        end, dimms)
    local numa = object(snapshot.numa)
    table_section(lines, "NUMA nodes", { "Node", "CPUs", "Memory", "Free", "Quality" },
        numa.nodes, function(node)
            local node_memory = object(node.memory)
            return { node.id, type(node.cpu_ids) == "table" and #node.cpu_ids or nil,
                bytes(node_memory.total_bytes), bytes(node_memory.free_bytes), node.quality }
        end, numa)
    local spd = object(snapshot.spd)
    table_section(lines, "Memory module SPD", { "Device", "Type", "Capacity", "Part", "Integrity" },
        spd.devices, function(device)
            local integrity
            if device.crc_valid == false or device.crc_base_valid == false
                or device.checksum_valid == false then
                integrity = "invalid"
            elseif device.crc_valid == true or device.crc_base_valid == true
                or device.checksum_valid == true then integrity = "valid"
            else integrity = device.quality end
            return { device.id, device.memory_type, bytes(device.size_bytes),
                device.part_number, integrity }
        end, spd)
    local edac = object(snapshot.edac)
    local modules = {}
    for _, controller in ipairs(list(edac.controllers)) do
        for _, module in ipairs(list(object(controller).modules)) do
            modules[#modules + 1] = { controller = controller, module = module }
        end
    end
    table_section(lines, "Memory error modules", { "Controller", "Module", "Corrected", "Uncorrected" },
        modules, function(item)
            local controller, module = object(item.controller), object(item.module)
            return { controller.name or controller.id, module.label or module.id,
                module.correctable_errors, module.uncorrectable_errors }
        end, edac)

    local disks = object(snapshot.disks)
    table_section(lines, "Storage devices", { "Device", "Kind", "Capacity", "Start on disk", "Model", "Medium", "Quality" },
        disks.devices, function(device)
            local identity = object(device.identity)
            local kind = device.is_partition and "partition"
                or device.stacked and "stacked" or "disk"
            local medium = identity.rotational == 0 and "solid-state"
                or identity.rotational == 1 and "rotational" or nil
            local stack = object(device.stack)
            return { device.name, kind, bytes(identity.size_bytes),
                device.is_partition and bytes(identity.start_bytes) or nil,
                stack.name or stack.level or identity.model,
                medium, device.quality }
        end, disks)
    local thermal_disks = {}
    for _, device in ipairs(list(disks.devices)) do
        if type(object(device).temperature) == "table" then thermal_disks[#thermal_disks + 1] = device end
    end
    if #thermal_disks > 0 then
        table_section(lines, "Storage temperatures", { "Device", "Temperature", "Critical", "To critical", "Source", "Quality" },
            thermal_disks, function(device)
                local t = device.temperature
                return { device.name, quantity(t.temperature_celsius,1," °C",2),
                    quantity(t.critical_celsius,1," °C",2), quantity(t.headroom_celsius,1," °C",2),
                    t.source, t.quality }
            end)
    end
    local health = object(snapshot.disk_health)
    local nvme_health = {}
    for _, device in ipairs(list(health.devices)) do
        if type(object(device).nvme) == "table" then nvme_health[#nvme_health + 1] = device end
    end
    if #nvme_health > 0 then
        table_section(lines, "NVMe health", { "Device", "Warning bits", "Life used %", "Spare %", "Power-on hours", "Media errors", "Quality", "Scope" },
            nvme_health, function(device)
                local n = device.nvme
                return { device.name, n.critical_warning, n.percentage_used,
                    n.available_spare_percent, n.power_on_hours, n.media_errors, device.quality, n.scope }
            end, health)
    end
    local stacked_volumes = {}
    for _, device in ipairs(list(disks.devices)) do
        if type(object(device).stack) == "table" then
            stacked_volumes[#stacked_volumes + 1] = device
        end
    end
    table_section(lines, "Stacked volumes",
        { "Device", "Type", "Name or level", "State", "Sync", "Members", "Missing devices", "Expected devices" },
        stacked_volumes, function(device)
            local stack = object(device.stack)
            local state = stack.array_state
            if stack.kind == "dm" and stack.suspended ~= nil then
                state = stack.suspended and "suspended" or "not suspended"
            end
            local sync = stack.sync_action
            if sync and stack.sync_percent ~= nil then
                sync = sync .. " " .. string.format("%.1f%%", stack.sync_percent)
            elseif sync and stack.sync_progress_status
                and stack.sync_progress_status ~= "ok" then
                sync = sync .. " (" .. stack.sync_progress_status .. ")"
            end
            local members = type(stack.members) == "table" and stack.members or nil
            local member_count = members and tostring(members.total or 0)
                .. " (" .. tostring(members.status or "unavailable") .. ")" or nil
            return { device.name, stack.kind, stack.name or stack.level,
                state, sync, member_count, stack.degraded, stack.raid_disks }
        end, disks)
    local md_members, md_members_truncated = {}, false
    for _, device in ipairs(list(disks.devices)) do
        local stack = object(device.stack)
        if stack.kind == "md" then
            local members = object(stack.members)
            for _, member in ipairs(list(members.items)) do
                if #md_members < 512 then
                    md_members[#md_members + 1] = { array = device.name, member = member }
                else md_members_truncated = true end
            end
        end
    end
    table_section(lines, "MD members",
        { "Array", "Member", "Device ID", "Array position", "State", "Quality" },
        md_members, function(row)
            local member = object(row.member)
            return { row.array, member.name, member.device_id,
                member.slot, member.state, member.quality }
        end, { truncated = md_members_truncated })
    local nvme_devices = {}
    for _, device in ipairs(list(disks.devices)) do
        if type(object(device).nvme) == "table" then nvme_devices[#nvme_devices + 1] = device end
    end
    local function counter_text(counter)
        counter = object(counter)
        if counter.total == nil then return nil end
        local shown = number(counter.total)
        if not shown then return nil end
        if counter.delta_quality == "fresh" and counter.new ~= nil
            and counter.new > 0 then
            local increment = number(counter.new)
            return increment and shown .. " (+" .. increment .. ")" or shown
        elseif counter.delta_quality == "reset" then return shown .. " (reset)" end
        return shown
    end
    table_section(lines, "NVMe diagnostics",
        { "Device", "Status", "ANA state", "Allocated namespace",
          "Use reading", "Command errors", "Failovers", "No-path I/O failures" },
        nvme_devices, function(device)
            local nvme, counters = object(device.nvme), object(object(device.nvme).counters)
            local nuse = object(nvme.nuse)
            local allocation = nuse.allocated_bytes and bytes(nuse.allocated_bytes)
                or nuse.allocated_lbas and number(nuse.allocated_lbas) .. " LBAs"
            local reading = nuse.allocated_lbas ~= nil and nuse.cached == true
                and "cached" or nuse.quality
            return { device.name, nvme.status, nvme.ana_state,
                allocation, reading,
                counter_text(counters.command_errors), counter_text(counters.multipath_failovers),
                counter_text(counters.io_failures_no_path) }
        end, { truncated = disks.nvme_diagnostics_truncated })
    local nvme_controllers = {}
    for _, device in ipairs(nvme_devices) do
        if type(object(device.nvme).controller) == "table" then
            nvme_controllers[#nvme_controllers + 1] = device
        end
    end
    table_section(lines, "NVMe controllers",
        { "Namespace", "Controller", "State", "Transport",
          "Command errors", "Resets", "Reconnects" },
        nvme_controllers, function(device)
            local controller = object(object(device.nvme).controller)
            local counters = object(controller.counters)
            return { device.name, controller.name, controller.state,
                controller.transport, counter_text(counters.command_errors),
                counter_text(counters.resets), counter_text(counters.reconnects) }
        end, { truncated = disks.nvme_diagnostics_truncated })
    local nvme_paths, nvme_paths_truncated = {}, false
    for _, device in ipairs(nvme_devices) do
        local paths = object(object(device.nvme).paths)
        nvme_paths_truncated = nvme_paths_truncated or paths.truncated == true
        for _, path in ipairs(list(paths.items)) do
            if #nvme_paths < 512 then
                nvme_paths[#nvme_paths + 1] = {
                    namespace = device.name, subsystem = paths.subsystem, path = path,
                }
            else nvme_paths_truncated = true end
        end
    end
    table_section(lines, "NVMe paths",
        { "Namespace", "Subsystem", "Path", "Controller", "Controller state",
          "Transport", "ANA state", "ANA group", "Quality" },
        nvme_paths, function(row)
            local path = object(row.path)
            return { row.namespace, row.subsystem, path.name, path.controller,
                path.controller_state, path.transport, path.ana_state,
                path.ana_group_id, path.quality }
        end, { truncated = nvme_paths_truncated or disks.nvme_diagnostics_truncated })

    local network = object(snapshot.network)
    table_section(lines, "Network interfaces", { "Interface", "State", "Speed", "Quality" },
        network.interfaces, function(interface)
            return { interface.name, interface.operstate,
                quantity(interface.speed_mbps, 1, " Mb/s", 0),
                interface.quality }
        end, network)

    local wifi = object(snapshot.wifi)
    if #list(wifi.devices) > 0 then
        table_section(lines, "Wi-Fi link reports",
            { "Interface", "Association", "Frequency", "Last RX signal", "RX PHY", "TX PHY", "Rate scope", "Quality" },
            wifi.devices, function(device)
                local station = object(device.station)
                local frequencies = {}
                for _, link in ipairs(list(device.links)) do
                    if type(link.frequency_mhz) == "number" then
                        frequencies[#frequencies + 1] = quantity(link.frequency_mhz
                            + (tonumber(link.frequency_offset_khz) or 0) / 1000, 1, " MHz", 3)
                    end
                end
                return { device.name, device.association, table.concat(frequencies, ", "),
                    quantity(station.signal_dbm, 1, " dBm", 0),
                    quantity(object(station.receive_phy).bits_per_second, 1000000, " Mbit/s", 1),
                    quantity(object(station.transmit_phy).bits_per_second, 1000000, " Mbit/s", 1),
                    station.scope, device.quality }
            end, wifi)
        lines[#lines + 1] = "Driver PHY rates are not throughput or guaranteed capacity; the radio sample time is unknown."
        lines[#lines + 1] = ""
    end

    local gpus = object(snapshot.gpus)
    table_section(lines, "Graphics devices", { "Device", "Model", "Driver", "PCI address", "Identity" },
        gpus.devices, function(device)
            return { device.card or device.id, device.model_name or device.vendor_name,
                device.driver, device.pci_bdf, device.identity_quality }
        end, gpus)

    local gpu_power_sessions = {}
    for _, device in ipairs(list(gpus.devices)) do
        for _, session in ipairs(list(device.power_sessions)) do
            gpu_power_sessions[#gpu_power_sessions + 1] = { device = device, session = session }
        end
    end
    if #gpu_power_sessions > 0 then
        table_section(lines, "GPU API power statistics",
            { "GPU", "Source", "Reading", "Scope", "Measurement", "Current", "Minimum", "Average", "Maximum", "Readings", "Quality", "Sample identity" },
            gpu_power_sessions, function(entry)
                local s = entry.session
                return { entry.device.card or entry.device.id, s.source, s.metric, s.scope, s.measurement, quantity(s.current_watts, 1, " W", 2),
                    quantity(s.minimum_watts, 1, " W", 2), quantity(s.average_watts, 1, " W", 2),
                    quantity(s.maximum_watts, 1, " W", 2), s.samples, s.quality, s.sample_time_basis }
            end, gpus)
        lines[#lines + 1] = "Statistics summarize accepted API readings by sample count; driver averaging windows may overlap. No energy is integrated."
        lines[#lines + 1] = ""
    end

    local power = object(snapshot.power_supplies)
    local performance_limits, limits_truncated = {}, false
    local function add_limits(owner, limits)
        limits = object(limits)
        limits_truncated = limits_truncated or limits.truncated == true
        for _, domain in ipairs(list(limits.domains)) do
            if #performance_limits < 512 then
                performance_limits[#performance_limits + 1] = { owner = owner, domain = domain }
            else limits_truncated = true end
        end
    end
    add_limits("CPU", snapshot.cpu_limits)
    for _, gpu in ipairs(list(gpus.devices)) do add_limits(gpu.card or gpu.id, gpu.performance_limits) end
    table_section(lines, "Performance limit status",
        { "Device", "Domain", "Scope", "Asserted", "Current reasons", "Recorded flags", "Quality", "Source" },
        performance_limits, function(entry)
            local domain, active, recorded = entry.domain, {}, {}
            for _, reason in ipairs(list(entry.domain.reasons)) do
                if reason.active == true then active[#active + 1] = reason.id end
                if reason.logged == true then recorded[#recorded + 1] = reason.id end
            end
            if domain.active == true then
                for _, name in ipairs(list(domain.unknown_reason_names)) do
                    active[#active + 1] = name .. " (unknown)"
                end
            end
            return { entry.owner, domain.id, domain.scope, domain.active,
                #active > 0 and table.concat(active, ", ") or nil,
                #recorded > 0 and table.concat(recorded, ", ") or nil, domain.quality, domain.source }
        end, { truncated = limits_truncated })
    if #performance_limits > 0 then
        lines[#lines + 1] = "Recorded flags remain until cleared; their clear time is unknown. Current flags describe the recorded sample."
        lines[#lines + 1] = ""
    end
    table_section(lines, "Live batteries", { "Battery", "State", "Charge", "Health", "Design energy" },
        power.batteries, function(battery)
            return { battery.name or battery.id, battery.status,
                quantity(battery.capacity_percent, 1, "%", 1),
                quantity(battery.health_percent, 1, "%", 1),
                quantity(battery.energy_design_watt_hours, 1, " Wh", 2) }
        end, power)
    local zones = object(snapshot.power)
    table_section(lines, "Power zones", { "Zone", "Domain", "Current power", "Sample window", "Quality", "Source" },
        zones.zones, function(zone)
            return { named_id(zone), zone.domain_kind, quantity(zone.power_watts, 1, " W", 2),
                quantity(zone.power_interval_ns, 1e9, " s", 6), zone.power_quality or zone.quality, zone.power_source }
        end, zones)
    local power_sessions = {}
    for _, zone in ipairs(list(zones.zones)) do
        if type(zone.power_session) == "table" then power_sessions[#power_sessions + 1] = zone end
    end
    if #power_sessions > 0 then
        table_section(lines, "Power session statistics",
            { "Domain", "Minimum", "Average", "Maximum", "Average method", "Readings", "Observed time", "Observed energy", "Last reading age" },
            power_sessions, function(zone)
                local session = zone.power_session
                local age = type(snapshot.captured_monotonic_ns) == "number"
                    and type(session.last_timestamp_ns) == "number"
                    and snapshot.captured_monotonic_ns - session.last_timestamp_ns or nil
                return { named_id(zone), quantity(session.minimum_watts, 1, " W", 2),
                    quantity(session.average_watts, 1, " W", 2), quantity(session.maximum_watts, 1, " W", 2),
                    session.average_kind, session.samples, quantity(session.covered_time_ns, 1e9, " s", 6),
                    quantity(session.energy_joules, 1, " J", 3), quantity(age, 1e9, " s", 6) }
            end, zones)
        lines[#lines + 1] = "Statistics cover accepted readings in the current reader session; gaps are excluded. Energy-derived extrema are sample-window averages."
        lines[#lines + 1] = ""
    end
    if #list(zones.graphics_domains) > 0 then
        table_section(lines, "RAPL graphics domains",
            { "Domain", "Parent", "Power", "Sample window", "Quality", "PCI adapter known" },
            zones.graphics_domains, function(domain)
                return { domain.id, domain.parent_id, quantity(domain.power_watts, 1, " W", 2),
                    quantity(domain.interval_ns, 1e9, " s", 6), domain.quality, domain.pci_device_known }
            end, { truncated = zones.graphics_domains_truncated })
        lines[#lines + 1] = "These readings cover the RAPL graphics power plane; PCI adapter ownership is unknown."
        lines[#lines + 1] = ""
    end
    local constraints, constraints_truncated = {}, zones.truncated == true
    for _, zone in ipairs(list(zones.zones)) do
        for _, constraint in ipairs(list(zone.constraints)) do
            if #constraints < 512 then
                constraints[#constraints + 1] = { zone = zone, constraint = constraint }
            else constraints_truncated = true end
        end
    end
    table_section(lines, "Power caps", { "Zone", "Interface", "Constraint", "Power cap",
        "Sample / cap", "Cap window", "Sample window", "Controls enabled" },
        constraints, function(entry)
            local zone, cap = entry.zone, entry.constraint
            return { named_id(zone), zone.source_kind, cap.name or cap.id,
                quantity(cap.power_limit_watts, 1, " W", 2),
                quantity(cap.usage_percent, 1, "%", 1),
                quantity(cap.time_window_seconds, 1, " s", 6),
                quantity(zone.power_interval_ns, 1e9, " s", 6), zone.controls_enabled }
        end, { truncated = constraints_truncated })
    if #constraints > 0 then
        lines[#lines + 1] = "Ratios compare sampled power with configured caps; they do not establish throttling."
        lines[#lines + 1] = ""
    end
    local enclosures = object(snapshot.firmware_enclosures)
    table_section(lines, "Baseboards", { "Handle", "Manufacturer", "Product", "Version", "Type", "Location", "Chassis handle" },
        enclosures.baseboards, function(board)
            return { board.id, board.manufacturer, board.product, board.version,
                board.board_type or board.board_type_code, board.location, board.chassis_handle }
        end, enclosures)
    table_section(lines, "Enclosures", { "Handle", "Manufacturer", "Type", "Version", "SKU", "Height", "Power cords" },
        enclosures.enclosures, function(chassis)
            return { chassis.id, chassis.manufacturer, chassis.chassis_type or chassis.chassis_type_code,
                chassis.version, chassis.sku, chassis.height_u and tostring(chassis.height_u) .. " U"
                    or chassis.height_ou and tostring(chassis.height_ou) .. " OU", chassis.power_cords }
        end, enclosures)
    table_section(lines, "Enclosure states at last boot", { "Handle", "Boot", "Power supply", "Thermal", "Security" },
        enclosures.enclosures, function(chassis)
            return { chassis.id, chassis.boot_state or chassis.boot_state_code,
                chassis.power_state or chassis.power_state_code,
                chassis.thermal_state or chassis.thermal_state_code,
                chassis.security_state or chassis.security_state_code }
        end, enclosures)
    if #(enclosures.enclosures or {}) > 0 then
        lines[#lines + 1] = "SMBIOS enclosure states describe the last boot; they are not live health readings."
        lines[#lines + 1] = ""
    end
    local firmware_batteries = object(snapshot.firmware_batteries)
    table_section(lines, "Firmware batteries", { "Battery", "Location", "Chemistry", "Design energy", "Design voltage" },
        firmware_batteries.batteries, function(battery)
            return { battery.name or battery.id, battery.location,
                battery.sbds_chemistry or battery.chemistry,
                quantity(battery.design_capacity_mwh, 1000, " Wh", 2),
                quantity(battery.design_voltage_mv, 1000, " V", 2) }
        end, firmware_batteries)
    local firmware_supplies = object(snapshot.firmware_power_supplies)
    table_section(lines, "Firmware power supplies", { "Supply", "Location", "Rated output", "Firmware status", "Group" },
        firmware_supplies.supplies, function(supply)
            return { supply.name or supply.id, supply.location,
                quantity(supply.max_power_watts, 1, " W", 0), supply.status,
                supply.power_unit_group and supply.power_unit_group > 0
                    and supply.power_unit_group or nil }
        end, firmware_supplies)
    local processor_firmware = object(snapshot.processor_firmware)
    local firmware_bmcs = object(snapshot.firmware_bmcs)
    table_section(lines, "Firmware BMC interfaces",
        { "Interface", "IPMI revision", "Address space", "Address field", "Base address", "Interrupt" },
        firmware_bmcs.devices, function(device)
            return { (device.interface_type or "?") .. " #" .. tostring(device.id),
                device.ipmi_revision, device.address_space, device.base_address_field_hex,
                device.base_address_hex,
                device.interrupt_number }
        end, firmware_bmcs)
    local firmware_tpms = object(snapshot.firmware_tpms)
    table_section(lines, "Firmware TPM devices",
        { "TPM", "Vendor ID", "Specification", "Firmware 1", "Firmware 2" },
        firmware_tpms.devices, function(device)
            return { device.description or device.id, device.vendor_id,
                device.spec_version, device.firmware_version_1_hex,
                device.firmware_version_2_hex }
        end, firmware_tpms)
    local firmware_components = object(snapshot.firmware_components)
    table_section(lines, "Firmware components",
        { "Component", "Version", "Manufacturer", "Release date", "Firmware state" },
        firmware_components.components, function(component)
            return { component.name or component.id, component.version,
                component.manufacturer, component.release_date,
                component.state or component.state_code }
        end, firmware_components)
    local firmware_esrt = object(snapshot.firmware_esrt)
    table_section(lines, "UEFI firmware resources",
        { "Entry", "Class GUID", "Type", "Version", "Minimum", "Last attempt code" },
        firmware_esrt.entries, function(entry)
            return { entry.id, entry.guid, entry.type or entry.type_code,
                entry.version, entry.lowest_supported_version,
                entry.last_attempt_status }
        end, firmware_esrt)
    local os_tpms = object(snapshot.tpm)
    table_section(lines, "Operating-system TPM devices",
        { "TPM", "Specification major", "Driver", "PCR banks", "Quality" },
        os_tpms.devices, function(device)
            local banks = {}
            for _, bank in ipairs(list(device.banks)) do
                banks[#banks + 1] = bank.algorithm
            end
            local version = device.version_minor and device.version_major
                and (tostring(device.version_major) .. "." .. tostring(device.version_minor))
                or device.version_major
            return { device.id, version, device.driver,
                table.concat(banks, ", "), device.quality }
        end, os_tpms)
    local watchdogs = object(snapshot.watchdog)
    table_section(lines, "Watchdog devices",
        { "Device", "Identity", "State", "Timeout", "Time left", "Nowayout" },
        watchdogs.devices, function(device)
            return { device.id, device.identity, device.state,
                quantity(device.timeout_seconds, 1, " s", 0),
                quantity(device.timeleft_seconds, 1, " s", 0), device.nowayout }
        end, watchdogs)
    local rfkill = object(snapshot.rfkill)
    table_section(lines, "RF switches",
        { "Switch", "Name", "Type", "Hardware blocked", "Software blocked", "Blocked" },
        rfkill.devices, function(device)
            return { device.id, device.name, device.type, device.hard_blocked,
                device.soft_blocked, device.blocked }
        end, rfkill)
    local thermal = object(snapshot.thermal_zones)
    table_section(lines, "Thermal zones",
        { "Zone", "Type", "Temperature", "Mode", "Policy", "Trip points", "Cooling links" },
        thermal.zones, function(zone)
            return { zone.id, zone.type,
                quantity(zone.temperature_celsius, 1, " °C", 1),
                zone.mode, zone.policy, #(zone.trips or {}), #(zone.bindings or {}) }
        end, thermal)
    local thermal_trips, trips_truncated = {}, false
    local thermal_bindings, bindings_truncated = {}, false
    for _, zone in ipairs(list(thermal.zones)) do
        for _, trip in ipairs(list(zone.trips)) do
            if #thermal_trips < 256 then
                thermal_trips[#thermal_trips + 1] = { zone = zone.id, trip = trip }
            else trips_truncated = true end
        end
        for _, binding in ipairs(list(zone.bindings)) do
            if #thermal_bindings < 256 then
                thermal_bindings[#thermal_bindings + 1] = { zone = zone.id, binding = binding }
            else bindings_truncated = true end
        end
    end
    table_section(lines, "Thermal trip points",
        { "Zone", "Trip", "Type", "Threshold" }, thermal_trips, function(row)
            local trip = row.trip
            return { row.zone, trip.index, trip.type,
                quantity(trip.temperature_celsius, 1, " °C", 1) }
        end, { truncated = trips_truncated or thermal.truncated })
    table_section(lines, "Cooling devices",
        { "Device", "Type", "Current state", "Maximum state", "Transitions" },
        thermal.cooling_devices, function(device)
            return { device.id, device.type, device.cur_state, device.max_state,
                object(device.stats).total_transitions }
        end, thermal)
    local state_times, state_times_truncated = {}, false
    for _, device in ipairs(list(thermal.cooling_devices)) do
        local stats = object(device.stats)
        state_times_truncated = state_times_truncated or stats.truncated == true
        for _, state in ipairs(list(stats.time_in_state_ms)) do
            if type(state.milliseconds) == "number" and state.milliseconds > 0 then
                if #state_times < 256 then
                    state_times[#state_times + 1] = { device = device.id, state = state }
                else state_times_truncated = true end
            end
        end
    end
    table_section(lines, "Cooling state time (nonzero)",
        { "Device", "State", "Cumulative time (ms)" }, state_times, function(row)
            return { row.device, row.state.state, row.state.milliseconds }
        end, { truncated = state_times_truncated or thermal.truncated })
    table_section(lines, "Thermal cooling links",
        { "Zone", "Cooling device", "Trip", "Weight" },
        thermal_bindings, function(row)
            local binding = row.binding
            return { row.zone, binding.cooling_id, binding.trip_index, binding.weight }
        end, { truncated = bindings_truncated or thermal.truncated })
    local host_interfaces = object(snapshot.host_interfaces)
    table_section(lines, "Management host interfaces",
        { "Interface", "Type code", "Protocols", "Declared count" },
        host_interfaces.devices, function(device)
            local protocols = {}
            for _, protocol in ipairs(list(device.protocols)) do
                protocols[#protocols + 1] = protocol.type
                    or string.format("0x%02x", protocol.type_code or 0)
            end
            return { device.interface_type or device.id, device.interface_type_code,
                table.concat(protocols, ", "), device.protocol_count }
        end, host_interfaces)
    table_section(lines, "Firmware CPU sockets", { "Socket", "Processor", "Cores", "Threads", "Populated" },
        processor_firmware.processors, function(processor)
            return { processor.designation or processor.id, processor.version,
                processor.core_count, processor.thread_count, processor.populated }
        end, processor_firmware)
    local slots = object(snapshot.expansion_slots)
    table_section(lines, "Expansion slots", { "Slot", "Type", "Firmware use", "PCI reference" },
        slots.slots, function(slot)
            return { slot.designation or slot.id, slot.slot_type,
                slot.usage_code, slot.pci_bdf }
        end, slots)
    local onboard = object(snapshot.onboard_devices)
    table_section(lines, "Onboard devices", { "Device", "SMBIOS type", "Type", "Enabled", "PCI reference" },
        onboard.devices, function(device)
            return { device.designation or device.id, device.structure_type,
                device.device_type or device.device_type_code,
                device.enabled, device.pci_bdf }
        end, onboard)
    local ports = object(snapshot.port_connectors)
    table_section(lines, "Firmware ports",
        { "Port", "Function", "Internal connector", "External connector",
          "Internal reference", "External reference" },
        ports.ports, function(port)
            return { port.external_designation or port.internal_designation or port.id,
                port.port_type or port.port_type_code,
                port.internal_connector or port.internal_connector_code,
                port.external_connector or port.external_connector_code,
                port.internal_designation, port.external_designation }
        end, ports)

    local sensors = object(snapshot.sensors)
    local readings = {}
    for _, device in ipairs(list(sensors.devices)) do
        for _, channel in ipairs(list(object(device).channels)) do
            readings[#readings + 1] = { device = device, channel = channel }
        end
    end
    table_section(lines, "Sensors", { "Device", "Channel", "Reading", "Critical", "To critical", "Quality" },
        readings, function(item)
            local device, channel = object(item.device), object(item.channel)
            return { named_id(device), channel.label or channel.id,
                quantity(channel.input, 1,
                    " " .. tostring(SENSOR_UNITS[channel.unit] or channel.unit or ""), 2),
                quantity(channel.critical_celsius, 1, " °C", 2),
                quantity(channel.headroom_celsius, 1, " °C", 2),
                channel.quality }
        end, sensors)

    local energy_power, hwmon_power = {}, {}
    for _, item in ipairs(readings) do
        if item.channel.power then
            if item.channel.type == "energy" then energy_power[#energy_power + 1] = item
            else hwmon_power[#hwmon_power + 1] = item end
        end
    end
    table_section(lines,"Direct hwmon power",
        { "Device","Channel","Scope","Measurement","Power","Driver window","Session average","Readings","Quality","Source" },
        hwmon_power,function(item)
            local p=item.channel.power;local stats=p.power_session or {}
            return { named_id(item.device),item.channel.label or item.channel.id,p.scope,p.measurement,
                quantity(p.power_watts,1," W",2),quantity(p.power_interval_ns,1e9," s",3),
                quantity(stats.average_watts,1," W",2),stats.samples,p.power_quality,p.source }
        end,sensors)
    table_section(lines, "Energy-derived sensor power",
        { "Device", "Channel", "Scope", "Average power", "Window", "Timing uncertainty", "Minimum", "Session average", "Maximum", "Readings", "Quality", "Source" },
        energy_power, function(item)
            local p = item.channel.power
            local stats = p.power_session or {}
            return { named_id(item.device), item.channel.label or item.channel.id, p.scope,
                quantity(p.power_watts,1," W",2),quantity(p.power_interval_ns,1e9," s",3),
                quantity(p.interval_uncertainty_ns,1e9," s",6),quantity(stats.minimum_watts,1," W",2),
                quantity(stats.average_watts,1," W",2),quantity(stats.maximum_watts,1," W",2),stats.samples,p.power_quality,p.source }
        end,sensors)
    local energy_limits = {}
    for _, item in ipairs(energy_power) do
        for _, cap in ipairs(item.channel.power.limits or {}) do
            energy_limits[#energy_limits+1] = { item=item,cap=cap }
        end
    end
    for _, item in ipairs(hwmon_power) do
        for _, cap in ipairs(item.channel.power.limits or {}) do
            energy_limits[#energy_limits+1] = { item=item,cap=cap }
        end
    end
    table_section(lines,"Energy-domain power limits",{ "Device","Channel","Scope","Limit","Configured","Enabled","Cap window","Usage","Headroom","Source" },
        energy_limits,function(entry)
            local item,cap=entry.item,entry.cap
            return { named_id(item.device),item.channel.label or item.channel.id,item.channel.power.scope,
                cap.id=="long_term" and "PL1" or "PL2",quantity(cap.power_limit_watts,1," W",2),cap.enabled,
                quantity(cap.window_ns,1e9," s",3),quantity(cap.percent,1,"%",1),quantity(cap.headroom_watts,1," W",2),cap.source }
        end,sensors)
    if #energy_power>0 then
        lines[#lines+1]="Power comes from adjacent cumulative energy observations. Session averages are time-weighted; gaps and resets are excluded."
        lines[#lines+1]=""
    end
    if #hwmon_power>0 then
        lines[#lines+1]="Direct and driver-average power sessions use sample-count averages; overlapping driver windows are not integrated as energy."
        lines[#lines+1]=""
    end

    local inventory = object(snapshot.inventory)
    local pci, usb = object(inventory.pci), object(inventory.usb)
    table_section(lines, "PCI devices", { "Address", "Vendor", "Device", "Driver" },
        pci.devices, function(device)
            return { device.address, device.vendor_name or device.vendor_id,
                device.device_name or device.device_id, device.driver }
        end, pci)
    table_section(lines, "USB devices", { "ID", "Manufacturer", "Product", "Driver" },
        usb.devices, function(device)
            return { device.id, device.manufacturer, device.product, device.driver }
        end, usb)
    table_section(lines, "USB interfaces", { "ID", "Interface", "Class", "Driver" },
        usb.interfaces, function(interface)
            return { interface.id, interface.interface, interface.class_id,
                interface.driver }
        end, usb)

    local graph = object(inventory.topology)
    table_section(lines, "Device relationships", { "ID", "Kind", "Parent", "Sensors" },
        graph.nodes, function(node)
            return { node.id, node.kind or node.bus, node.parent_id,
                type(node.sensor_ids) == "table" and #node.sensor_ids or nil }
        end, graph)
    local dependencies = {}
    for _, node in ipairs(list(graph.nodes)) do
        if type(node) == "table" and node.bus == "block"
            and (#list(node.slave_ids) > 0 or #list(node.holder_ids) > 0) then
            dependencies[#dependencies + 1] = node
        end
    end
    table_section(lines, "Block dependencies", { "Device", "Backing devices", "Used by" },
        dependencies, function(node)
            return { node.identifier or node.id,
                #list(node.slave_ids) > 0 and table.concat(node.slave_ids, ", ") or nil,
                #list(node.holder_ids) > 0 and table.concat(node.holder_ids, ", ") or nil }
        end, graph)
    lines[#lines + 1] = "For machine-readable fields and source details, use `wtop --snapshot`."
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

return M
