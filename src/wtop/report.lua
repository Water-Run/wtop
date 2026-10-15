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
    }
    table_section(lines, "CPU", { "Field", "Value" }, cpu_items,
        function(row) return row end)
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

    local gpus = object(snapshot.gpus)
    table_section(lines, "Graphics devices", { "Device", "Model", "Driver", "PCI address", "Identity" },
        gpus.devices, function(device)
            return { device.card or device.id, device.model_name or device.vendor_name,
                device.driver, device.pci_bdf, device.identity_quality }
        end, gpus)

    local power = object(snapshot.power_supplies)
    table_section(lines, "Live batteries", { "Battery", "State", "Charge", "Health", "Design energy" },
        power.batteries, function(battery)
            return { battery.name or battery.id, battery.status,
                quantity(battery.capacity_percent, 1, "%", 1),
                quantity(battery.health_percent, 1, "%", 1),
                quantity(battery.energy_design_watt_hours, 1, " Wh", 2) }
        end, power)
    local zones = object(snapshot.power)
    table_section(lines, "Power zones", { "Zone", "Current power", "Quality", "Source" },
        zones.zones, function(zone)
            return { named_id(zone), quantity(zone.power_watts, 1, " W", 2),
                zone.power_quality or zone.quality, zone.power_source }
        end, zones)
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
    table_section(lines, "Sensors", { "Device", "Channel", "Reading", "Quality" },
        readings, function(item)
            local device, channel = object(item.device), object(item.channel)
            return { named_id(device), channel.label or channel.id,
                quantity(channel.input, 1,
                    " " .. tostring(SENSOR_UNITS[channel.unit] or channel.unit or ""), 2),
                channel.quality }
        end, sensors)

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
