local native = require("wtop.native")
local version = require("wtop.version")
local json = require("wtop.format.json")
local Privacy = require("wtop.privacy")
local Hardware = require("wtop.model.hardware")
local Quality = require("wtop.model.quality")
local Power = require("wtop.model.power")
local PowerDomains = require("wtop.model.power_domains")
local PowerSession = require("wtop.model.power_session")
local GPUPowerSession = require("wtop.model.gpu_power_session")
local SensorPower = require("wtop.model.sensor_power")
local CPULimits = require("wtop.model.cpu_limits")
local Thermal = require("wtop.model.thermal")
local StorageHealth = require("wtop.model.storage_health")
local NVMeWarnings = require("wtop.model.nvme_warnings")
local WiFi = require("wtop.model.wifi")
local NVMe = require("wtop.linux.nvme_diagnostics")

local M = {}

local function finite_number(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function bounded_limit(value, default, maximum, minimum)
    minimum = minimum or 0
    if value == nil then return default end
    value = tonumber(value)
    if not finite_number(value) then return default end
    return math.max(minimum, math.min(maximum, math.floor(value)))
end

local function copy_fields(source, fields)
    local result = json.object({})
    for _, key in ipairs(fields) do
        if source and source[key] ~= nil then
            result[key] = source[key]
        end
    end
    return result
end

local function copy_object(source)
    local result = json.object({})
    for key, value in pairs(source or {}) do
        result[key] = value
    end
    return result
end

local CPU_FIELDS = {
    "id", "name", "online", "identity_quality", "source",
    "processor_group", "logical_processor_index", "cpu_set_id",
    "utilization", "user", "nice", "system", "iowait", "irq", "steal", "quality",
}

local function export_cpu(cpu)
    local result = copy_fields(cpu, {
        "context_switches", "interrupts", "processes_created",
        "processes_running", "processes_blocked", "boot_time_seconds",
        "counter_bits", "counter_source", "counter_scope", "truncated",
    })
    if cpu and cpu.load then
        result.load = copy_fields(cpu.load, { "one", "five", "fifteen", "running", "total", "last_pid" })
    end
    result.total = copy_fields(cpu and cpu.total, CPU_FIELDS)
    result.cores = json.array({})
    for index, core in ipairs(cpu and cpu.cores or {}) do
        result.cores[index] = copy_fields(core, CPU_FIELDS)
    end
    return result
end

local function copy_array(values)
    local result = json.array({})
    for index, value in ipairs(values or {}) do result[index] = value end
    return result
end

local function export_issues(issues)
    local result = json.array({})
    for index, issue in ipairs(issues or {}) do
        result[index] = copy_fields(issue, {
            "field", "status", "reason", "source", "errno", "offset",
        })
    end
    return result
end

local function export_cpuid(cpuid)
    local result = copy_fields(cpuid, { "schema", "source", "status", "reason", "quality",
        "architecture_bits", "age_ms", "caches_complete", "scope", "roster_complete", "error_code",
        "platform", "observed_at_ns", "sample_started_ns", "sample_finished_ns", "transport", "retained", "refresh_status", "truncated" })
    result.topology = copy_fields(cpuid.topology, { "complete", "observed_logical_cpus",
        "sockets", "physical_cores", "compute_units", "threads_per_core_minimum", "threads_per_core_maximum" })
    result.os_comparison=copy_fields(cpuid.os_comparison,{"topology_matches","cache_matches","cache_geometry_complete"})
    result.core_types=json.array({})
    for index,row in ipairs(cpuid.core_types or{})do
        result.core_types[index]=copy_fields(row,{"id","core_type","native_model_id","source","model_name","vendor","core_type_class","quality","logical_cpu_count","physical_core_count","efficiency_ranking_minimum","efficiency_ranking_maximum","efficiency_ranking_cpu_count"})
        result.core_types[index].logical_cpu_ids=copy_array(row.logical_cpu_ids)
    end
    result.cache_summary=json.array({})
    for index,row in ipairs(cpuid.cache_summary or{})do result.cache_summary[index]=copy_fields(row,{"id","level","type","instances","total_size_bytes","minimum_size_bytes","maximum_size_bytes"})end
    result.features, result.logical_cpus, result.issues = json.array({}), json.array({}), json.array({})
    for index = 1, math.min(#(cpuid.features or {}), 32) do
        result.features[index] = copy_fields(cpuid.features[index], { "name", "reported_cpus",
            "hardware_cpus", "usable_cpus", "unknown_usability_cpus" })
    end
    for index = 1, math.min(#(cpuid.logical_cpus or {}), 512) do
        local cpu = cpuid.logical_cpus[index]
        local output = copy_fields(cpu, { "id", "processor_group", "logical_processor_index", "os_logical_cpu_id", "status",
            "flags", "max_basic", "max_extended", "xcr0", "affinity_restored", "os_processor_verified", "truncated" })
        output.identity = copy_fields(cpu.identity, { "source", "vendor", "model_name", "signature", "family", "model", "stepping",
            "initial_apic_id", "physical_address_bits", "linear_address_bits", "hypervisor_present", "hypervisor_vendor",
            "core_type", "core_type_source", "native_model_id", "core_type_class", "efficiency_ranking",
            "heterogeneous_core_topology", "asymmetric_core_topology" })
        output.topology = copy_fields(cpu.topology, { "method", "apic_id", "package_id", "core_id", "core_key",
            "node_id", "compute_unit_id", "compute_unit_key", "cores_per_compute_unit", "diagnostic_nodes_per_socket", "diagnostic_core_id" })
        output.topology.levels = json.array({})
        for level, value in ipairs(cpu.topology and cpu.topology.levels or {}) do
            output.topology.levels[level] = copy_fields(value, { "level", "type", "shift", "diagnostic_logical_count", "domain" })
        end
        output.topology.thread_siblings = copy_array(cpu.topology and cpu.topology.thread_siblings)
        output.features, output.leaves, output.cache_views = json.array({}), json.array({}), json.array({})
        for feature = 1, math.min(#(cpu.features or {}), 32) do
            output.features[feature] = copy_fields(cpu.features[feature], { "name", "hardware", "os_enabled", "usable",
                "leaf", "subleaf", "register", "bit" })
        end
        for record = 1, math.min(#(cpu.leaves or {}), 96) do
            output.leaves[record] = copy_fields(cpu.leaves[record], { "leaf", "subleaf", "eax", "ebx", "ecx", "edx" })
        end
        for cache = 1, math.min(#(cpu.cache_views or {}), 32) do
            output.cache_views[cache] = copy_fields(cpu.cache_views[cache], { "leaf", "subleaf", "source", "level", "type",
                "size_bytes", "coherency_line_size_bytes", "physical_line_partition", "ways_of_associativity", "number_of_sets", "maximum_sharing" })
        end
        result.logical_cpus[index] = output
    end
    for index = 1, math.min(#(cpuid.issues or {}), 512) do
        result.issues[index] = copy_fields(cpuid.issues[index], { "reason", "cpu_id" })
    end
    return result
end

local function export_cpu_info(cpu_info)
    local result = json.object({
        schema = cpu_info and cpu_info.schema,
        truncated = cpu_info and cpu_info.truncated == true or false,
    })
    result.identity = copy_fields(cpu_info and cpu_info.identity, {
        "model_name", "vendor", "family", "model", "stepping", "microcode",
        "implementer", "architecture", "variant", "part", "flags_count", "flags_truncated",
        "core_type_count", "heterogeneous", "nominal_frequency_hz",
    })
    result.identity.flags = copy_array(cpu_info and cpu_info.identity and cpu_info.identity.flags)
    local topology = cpu_info and cpu_info.topology or {}
    result.topology = copy_fields(topology, {
        "sockets", "physical_cores", "threads", "online_threads",
        "threads_per_core_minimum", "threads_per_core_maximum", "quality", "truncated",
        "source", "identity_quality", "processor_groups", "compute_units",
    })
    for _, key in ipairs({
        "online_cpu_list", "present_cpu_list", "possible_cpu_list", "isolated_cpu_list",
    }) do
        result.topology[key] = copy_array(topology[key])
    end
    result.topology.logical_cpus = json.array({})
    for index, cpu in ipairs(topology.logical_cpus or {}) do
        local output = copy_fields(cpu, {
            "id", "online", "package_id", "die_id", "cluster_id", "core_id", "core_key",
            "package_id_known", "core_id_known", "online_known",
            "cpu_capacity", "kernel_core_type", "maximum_frequency_hz", "threads_in_core",
            "core_type_id", "source",
            "mach_cpu_type", "mach_cpu_subtype", "is_main", "identity_quality",
            "processor_group", "logical_processor_index", "cpu_set_id", "efficiency_class",
            "last_level_cache_index", "numa_node_index", "parked", "allocated",
            "core_source", "package_source", "core_id_method", "package_id_method", "core_id_scope",
            "compute_unit_id", "compute_unit_key", "node_id", "cores_per_compute_unit", "apic_id", "initial_apic_id",
        })
        output.thread_siblings = copy_array(cpu.thread_siblings)
        result.topology.logical_cpus[index] = output
    end
    result.core_types = json.array({})
    for index, core_type in ipairs(cpu_info and cpu_info.core_types or {}) do
        local output = copy_fields(core_type, {
            "id", "model_name", "vendor", "family", "model", "stepping", "implementer",
            "architecture", "variant", "part", "cpu_capacity", "kernel_core_type",
            "threads_per_core", "maximum_frequency_hz", "physical_core_count",
            "logical_cpu_count", "efficiency_class", "source",
        })
        output.logical_cpu_ids = copy_array(core_type.logical_cpu_ids)
        result.core_types[index] = output
    end
    result.caches = json.array({})
    for index, cache in ipairs(cpu_info and cpu_info.caches or {}) do
        local output = copy_fields(cache, {
            "id", "cache_id", "level", "type", "size", "size_bytes", "shared_cpu_list_text",
            "coherency_line_size_bytes", "ways_of_associativity", "number_of_sets",
            "physical_line_partition", "source", "leaf", "subleaf", "maximum_sharing", "ambiguous",
        })
        output.shared_cpu_list = copy_array(cache.shared_cpu_list)
        result.caches[index] = output
    end
    result.cache_summary = json.array({})
    for index, cache in ipairs(cpu_info and cpu_info.cache_summary or {}) do
        result.cache_summary[index] = copy_fields(cache, {
            "id", "level", "type", "instances", "total_size_bytes",
            "minimum_size_bytes", "maximum_size_bytes",
        })
    end
    result.issues = export_issues(cpu_info and cpu_info.issues)
    if cpu_info and type(cpu_info.cpuid) == "table" then result.cpuid = export_cpuid(cpu_info.cpuid) end
    if cpu_info and cpu_info.os_topology then
        result.os_topology = export_cpu_info({ topology = cpu_info.os_topology }).topology
    end
    if cpu_info and cpu_info.os_caches then
        local original = export_cpu_info({ caches = cpu_info.os_caches, cache_summary = cpu_info.os_cache_summary })
        result.os_caches, result.os_cache_summary = original.caches, original.cache_summary
    end
    return result
end

local function export_performance_limits(limits, maximum, summary, quality)
    limits = limits or {}
    local domains = limits.domains or {}
    local result = copy_fields(limits, { "schema", "source", "source_kind", "denied_domains",
        "domains_discovered", "domains_supported", "domains_observed", "roster_complete", "enumeration_complete" })
    result.domains, result.domains_total = json.array({}), #domains
    result.truncated = limits.truncated == true or #domains > (maximum or #domains)
    if limits.coverage_complete ~= nil then
        result.coverage_complete = CPULimits.reduce(limits, quality).complete and not result.truncated
    end
    for index = 1, math.min(#domains, maximum or #domains) do
        local domain = domains[index]
        local output = copy_fields(domain, { "id", "scope", "cpu_id", "package_id", "family", "model",
            "active", "quality", "source", "source_kind", "observed_at_ns", "register", "reason",
            "raw_hex", "unknown_status_mask", "unknown_log_mask", "reserved_high",
            "supported_hex", "unknown_status_hex", "unsupported_status_hex", "status_code",
            "supported_status_code", "supported_source", "tile_id", "gt_id", "frequency_id", "reading_kind" })
        output.unknown_reason_names = json.array({})
        for i, name in ipairs(domain.unknown_reason_names or {}) do
            output.unknown_reason_names[i] = name
        end
        local stale = Power.unusable(quality) or Power.unusable(domain.quality)
        if Power.unusable(quality) then
            output.quality = type(quality) == "table" and (quality.quality or quality.status) or quality
        end
        if stale then output.active = nil end
        if summary then
            output.active_reasons, output.recorded_reasons = json.array({}), json.array({})
            for _, reason in ipairs(domain.reasons or {}) do
                if reason.active == true and not stale then output.active_reasons[#output.active_reasons + 1] = reason.id end
                if reason.logged == true then output.recorded_reasons[#output.recorded_reasons + 1] = reason.id end
            end
        else
            output.logical_cpu_ids = json.array({})
            for i, id in ipairs(domain.logical_cpu_ids or {}) do output.logical_cpu_ids[i] = id end
            output.reasons = json.array({})
            for i, reason in ipairs(domain.reasons or {}) do
                output.reasons[i] = copy_fields(reason, { "id", "active", "logged", "supported" })
                if stale then output.reasons[i].active = nil end
            end
            output.issues = export_issues(domain.issues)
        end
        result.domains[index] = output
    end
    return result
end

local function export_power(power, quality, now_ns)
    local result = json.object({
        schema = power and power.schema,
        total_power_watts = power and power.total_power_watts,
        measured_aggregate_zones = power and power.measured_aggregate_zones,
        aggregate_strategy = power and power.aggregate_strategy,
        aggregate_source_kind = power and power.aggregate_source_kind,
        aggregate_zone_count = power and power.aggregate_zone_count,
        aggregate_complete = power and power.aggregate_complete,
        platform_power_watts = power and power.platform_power_watts,
        measured_platform_zones = power and power.measured_platform_zones,
        platform_aggregate_strategy = power and power.platform_aggregate_strategy,
        platform_aggregate_source_kind = power and power.platform_aggregate_source_kind,
        denied_zones = power and power.denied_zones,
        truncated = power and power.truncated == true or false,
        zones = json.array({}),
        graphics_domains = json.array({}),
    })
    local identities = PowerDomains.identities(power and power.zones)
    for index, zone in ipairs(power and power.zones or {}) do
        local output = copy_fields(zone, {
            "id", "name", "source_kind", "parent_id", "enabled", "energy_joules",
            "maximum_energy_range_joules", "observed_at_ns", "energy_observed_at_ns", "power_watts",
            "power_source", "power_quality", "power_interval_ns", "quality", "truncated", "aggregate", "source",
            "platform_aggregate", "aggregate_domain", "control_enabled", "controls_enabled", "control_source",
        })
        output.domain_kind = PowerDomains.kind(zone, identities)
        if output.domain_kind then output.domain_role_source = "linux_intel_rapl" end
        output.power_quality = Power.zone_state(zone, quality, now_ns) or output.power_quality
        output.power_session = PowerSession.public(zone, now_ns)
        output.constraints = json.array({})
        for constraint_index, constraint in ipairs(zone.constraints or {}) do
            output.constraints[constraint_index] = copy_fields(constraint, {
                "id", "name", "power_limit_watts", "maximum_power_watts",
                "minimum_power_watts", "time_window_seconds", "maximum_time_window_seconds",
                "minimum_time_window_seconds", "source",
            })
            local comparison = Power.zone(zone, constraint, quality, now_ns)
            if comparison then
                output.constraints[constraint_index].usage_percent = comparison.percent
                output.constraints[constraint_index].headroom_watts = comparison.headroom_watts
            end
        end
        output.issues = export_issues(zone.issues)
        result.zones[index] = output
    end
    result.issues = export_issues(power and power.issues)
    local graphics, truncated = PowerDomains.graphics({ timestamp_ns = now_ns, power = power,
        quality = { power = quality } })
    for index, domain in ipairs(graphics) do
        if index > 128 then break end
        local output = copy_fields(domain, { "id", "parent_id", "source", "source_kind", "scope", "role_source",
            "quality", "observed_at_ns", "interval_ns", "controls_enabled", "pci_device_known" })
        output.power_watts = domain.watts
        result.graphics_domains[index] = output
    end
    result.graphics_domains_truncated = truncated or #graphics > #result.graphics_domains
    return result
end

local function export_memory(memory)
    local result = copy_fields(memory, {
        "total_bytes", "available_bytes", "used_bytes", "free_bytes",
        "buffers_bytes", "cache_bytes", "anonymous_bytes", "slab_bytes",
        "reclaimable_slab_bytes", "unreclaimable_slab_bytes", "dirty_bytes",
        "writeback_bytes", "swap_total_bytes", "swap_free_bytes", "swap_used_bytes",
        "zswap_bytes", "zswapped_bytes", "available_estimated",
        -- Fields the collector gained alongside the Memory page.  Leaving them
        -- out made the TUI show figures that --snapshot could not reproduce.
        "shared_bytes", "mapped_bytes", "page_tables_bytes", "kernel_stack_bytes",
        "committed_bytes", "commit_limit_bytes", "hugepages_total_bytes",
        "active_bytes", "inactive_bytes",
    })
    if memory and memory.vmstat then result.vmstat = copy_object(memory.vmstat) end
    -- The stacked composition is a non-overlapping partition of MemTotal, which
    -- the overlapping meminfo figures cannot be reassembled into downstream.
    if memory and type(memory.segments) == "table" then
        local segments = json.array({})
        for index, segment in ipairs(memory.segments) do
            if index > 16 then break end
            segments[index] = copy_fields(segment, { "id", "bytes" })
        end
        result.segments = segments
    end
    return result
end

local function export_pressure(pressure)
    local result = json.object({})
    for _, resource in ipairs({ "cpu", "memory", "io" }) do
        local source = pressure and pressure[resource]
        if source then
            local output = json.object({})
            if source.some then output.some = copy_fields(source.some, { "avg10", "avg60", "avg300", "total" }) end
            if source.full then output.full = copy_fields(source.full, { "avg10", "avg60", "avg300", "total" }) end
            result[resource] = output
        end
    end
    result.errors = json.object({})
    for resource, value in pairs(pressure and pressure.errors or {}) do
        result.errors[resource] = copy_fields(value, { "status", "reason", "source" })
    end
    return result
end

local function export_nvme(nvme)
    if type(nvme) ~= "table" then return nil end
    local result = copy_fields(nvme, {
        "status", "quality", "source", "observed_ns", "ana_state", "ana_group_id",
    })
    result.counters = json.object({})
    for _, specification in ipairs(NVMe.COUNTERS) do
        local name = specification[1]
        local counter = nvme.counters and nvme.counters[name]
        if type(counter) == "table" then
            result.counters[name] = copy_fields(counter,
                { "status", "total", "new", "delta_quality" })
        end
    end
    result.issues = export_issues(nvme.issues)
    if type(nvme.nuse) == "table" then
        result.nuse = copy_fields(nvme.nuse, {
            "source", "observed_ns", "status", "quality",
            "cached", "logical_block_size_bytes", "allocated_lbas",
            "allocated_bytes",
        })
    end
    if type(nvme.controller) == "table" then
        local controller = nvme.controller
        result.controller = copy_fields(controller, { "name", "source",
            "observed_ns", "status", "quality", "state", "transport" })
        result.controller.counters = json.object({})
        for _, specification in ipairs(NVMe.CONTROLLER_COUNTERS) do
            local name = specification[1]
            local counter = controller.counters and controller.counters[name]
            if type(counter) == "table" then
                result.controller.counters[name] = copy_fields(counter,
                    { "status", "total", "new", "delta_quality" })
            end
        end
        result.controller.issues = export_issues(controller.issues)
    end
    if type(nvme.paths) == "table" then
        local paths = nvme.paths
        result.paths = copy_fields(paths, { "subsystem", "source", "observed_ns",
            "status", "quality", "iopolicy", "total", "truncated" })
        result.paths.items = json.array({})
        for index, path in ipairs(paths.items or {}) do
            if index > 32 then result.paths.truncated = true break end
            result.paths.items[index] = copy_fields(path,
                { "name", "controller", "controller_source", "source",
                  "status", "quality", "controller_state", "transport",
                  "ana_state", "ana_group_id" })
        end
        result.paths.issues = export_issues(paths.issues)
    end
    return result
end

local function export_stacked_block(stack)
    if type(stack) ~= "table" then return nil end
    local result = copy_fields(stack, {
        "kind", "source", "observed_ns", "status", "quality", "name",
        "suspended", "level", "raid_disks", "previous_raid_disks",
        "degraded", "array_state", "sync_action", "sync_progress_status",
        "sync_completed_sectors", "sync_total_sectors", "sync_percent",
    })
    result.issues = export_issues(stack.issues)
    if type(stack.members) == "table" then
        result.members = copy_fields(stack.members,
            { "source", "status", "total", "truncated" })
        result.members.items = json.array({})
        for index, member in ipairs(stack.members.items or {}) do
            if index > 64 then break end
            result.members.items[index] = copy_fields(member,
                { "name", "device_id", "source", "slot", "state", "quality" })
        end
        result.members.issues = export_issues(stack.members.issues)
    end
    return result
end

local function export_disks(disks, snapshot)
    local result = json.object({ devices = json.array({}),
        total = disks and disks.total or nil,
        truncated = disks and disks.truncated == true or false,
        nvme_diagnostics_truncated = disks and disks.nvme_diagnostics_truncated == true or false })
    for index, device in ipairs(disks and disks.devices or {}) do
        result.devices[index] = copy_fields(device, {
            "id", "name", "major", "minor", "accounting_sector_size_bytes",
            "stable_id", "diskseq", "identity_quality", "partition", "is_partition",
            "source", "device_path",
            "stacked", "slaves", "aggregate",
            "slave_refs_complete",
            "logical_sector_size_bytes", "physical_sector_size_bytes",
            "in_flight", "read_bytes_per_second", "write_bytes_per_second",
            "read_iops", "write_iops", "busy_percent", "busy_quality", "average_read_latency_ms",
            "average_write_latency_ms", "average_queue_size", "discard_bytes_per_second",
            "discard_iops", "average_discard_latency_ms", "flush_iops",
            "average_flush_latency_ms", "quality", "reset_reason",
            -- `partial` and `topology_truncated` say whether the row is a
            -- complete picture; a consumer cannot infer either from the rates.
            "partial", "topology_truncated",
        })
        -- Static identity the storage page gained: model, capacity, medium and
        -- scheduler.  Without it a snapshot could not reproduce what the TUI
        -- showed, and "sdb" alone tells a reader nothing.
        if type(device.identity) == "table" then
            result.devices[index].identity = copy_fields(device.identity, {
                "model", "vendor", "firmware", "size_bytes", "start_bytes", "rotational",
                "removable", "scheduler", "queue_depth", "read_ahead_kib", "virtual",
            })
        end
        result.devices[index].nvme = export_nvme(device.nvme)
        local thermal = snapshot and StorageHealth.temperature(snapshot, device)
        if thermal then
            result.devices[index].temperature = json.object({
                temperature_celsius = thermal.channel.input,
                critical_celsius = thermal.critical_celsius,
                headroom_celsius = thermal.headroom_celsius,
                source = thermal.channel.source, quality = thermal.quality,
                observed_at_ns = thermal.observed_at_ns,
            })
        end
        result.devices[index].stack = export_stacked_block(device.stack)
        result.devices[index].slave_refs = json.array({})
        for position, reference in ipairs(device.slave_refs or {}) do
            if position > 4096 then break end
            result.devices[index].slave_refs[position] = copy_fields(reference,
                { "name", "device_id" })
        end
    end
    return result
end

local function export_network(network)
    local result = json.object({ interfaces = json.array({}) })
    if type(network) == "table" and type(network.routes) == "table" then
        local routes = network.routes
        result.routes = copy_fields(routes, { "total", "truncated", "partial",
            "invalid_lines", "ipv4_status", "ipv6_status", "quality", "observed_ns" })
        result.routes.source = json.array(routes.source or {})
        result.routes.entries = json.array({})
        for index, route in ipairs(routes.entries or {}) do
            if index > 2048 then break end
            result.routes.entries[index] = copy_fields(route, {
                "family", "interface", "destination", "prefix_length",
                "destination_cidr", "source_cidr", "gateway", "metric",
                "flags", "up", "default", "selected_default", "source",
            })
        end
    end
    if type(network) == "table" and type(network.softnet) == "table" then
        local softnet = network.softnet
        result.softnet = copy_fields(softnet, {
            "status", "quality", "reason", "source", "observed_ns", "interval_ns",
            "cpu_count", "processed", "dropped", "time_squeeze",
            "backlog_packets", "input_backlog_packets", "process_backlog_packets",
            "hot_cpu", "hot_cpu_backlog", "new_processed", "new_dropped",
            "new_time_squeeze", "processed_per_second", "dropped_per_second",
            "time_squeeze_per_second",
        })
        result.softnet.per_cpu = json.array({})
        for _, row in ipairs(softnet.per_cpu or {}) do
            if #result.softnet.per_cpu >= 256 then break end
            if type(row.cpu) == "number" then
                result.softnet.per_cpu[#result.softnet.per_cpu + 1] = copy_fields(row, {
                    "cpu", "processed", "dropped", "time_squeeze", "backlog_packets",
                    "input_backlog_packets", "process_backlog_packets", "quality",
                    "processed_per_second", "dropped_per_second",
                    "time_squeeze_per_second",
                })
            end
        end
        result.softnet.exported = #result.softnet.per_cpu
        result.softnet.truncated = #(softnet.per_cpu or {}) > 256
    end
    for index, interface in ipairs(network and network.interfaces or {}) do
        local exported = copy_fields(interface, {
            "id", "ifindex", "name", "operstate", "mtu", "speed_mbps",
            "driver", "description", "hardware",
            "counter_bits", "counter_source", "counter_quality",
            "source", "device_path",
            "iflink", "link_type", "carrier", "duplex", "address",
            "default_route", "aggregate", "quality", "reset_counter",
        })
        exported.rates = copy_object(interface.rates)
        exported.counters = copy_object(interface.counters)
        if type(interface.link_events) == "table" then
            exported.link_events = copy_fields(interface.link_events, {
                "status", "observed_ns", "changes_total", "up_total", "down_total",
                "changes_status", "up_status", "down_status",
            })
            exported.link_events.change = copy_fields(interface.link_events.change, {
                "quality", "reason", "interval_ns", "new_changes", "new_up", "new_down",
                "components_quality",
            })
        end
        if type(interface.queues) == "table" then
            exported.queues = copy_fields(interface.queues,
                { "rx_count", "tx_count", "status",
                  "tx_timeout_total", "timeout_status", "config_status" })
            for _, specification in ipairs({
                { "rx_details", { "id", "rps_cpus", "rps_flow_count" } },
                { "tx_details", { "id", "xps_cpus", "xps_rxqs",
                    "maxrate_mbps", "rate_limit_enabled" } },
            }) do
                local source = interface.queues[specification[1]]
                if type(source) == "table" then
                    local details = json.array({})
                    for position, row in ipairs(source) do
                        if position > 128 then break end
                        details[position] = copy_fields(row, specification[2])
                        if type(row.issues) == "table" then
                            local issues = json.array({})
                            for issue_index, issue in ipairs(row.issues) do
                                if issue_index > 3 then break end
                                issues[issue_index] = copy_fields(issue,
                                    { "field", "status" })
                            end
                            details[position].issues = issues
                        end
                    end
                    exported.queues[specification[1]] = details
                end
            end
            if type(interface.queues.tx_timeouts) == "table" then
                local timeouts = json.array({})
                for position, counter in ipairs(interface.queues.tx_timeouts) do
                    if position > 512 then break end
                    timeouts[position] = copy_fields(counter, { "id", "total", "status" })
                    if type(counter.change) == "table" then
                        timeouts[position].change = copy_fields(counter.change,
                            { "quality", "new_reports" })
                    end
                end
                exported.queues.tx_timeouts = timeouts
            end
            if type(interface.queues.timeout_change) == "table" then
                exported.queues.timeout_change = copy_fields(
                    interface.queues.timeout_change,
                    { "quality", "new_reports", "interval_seconds" })
            end
        end
        -- Interface addresses are local configuration, not remote endpoints,
        -- so they are not subject to the remote-address masking applied to the
        -- connection table.
        local addresses = json.array({})
        for position, address in ipairs(interface.addresses or {}) do
            if position > 16 then break end
            addresses[position] = copy_fields(address,
                { "family", "address", "netmask", "broadcast", "peer" })
        end
        exported.addresses = addresses
        result.interfaces[index] = exported
    end
    result.addresses_status = network and network.addresses_status or nil
    return result
end

local function export_wifi(snapshot)
    local data = snapshot.wifi or {}
    local result = json.object({ devices = json.array({}), source = data.source,
        truncated = data.truncated == true or #(data.devices or {}) > 16 })
    for index, device in ipairs(data.devices or {}) do
        if index > 16 then break end
        local row = copy_fields(device, { "id", "name", "ifindex", "wiphy_id", "wdev_id", "mode",
            "source", "observed_at_ns", "association", "multi_link", "query_errno", "station_errno" })
        row.quality, row.links = WiFi.quality(snapshot, device), json.array({})
        for position, link in ipairs(device.links or {}) do
            if position > 16 then break end
            row.links[position] = copy_fields(link, { "frequency_mhz", "frequency_offset_khz", "link_id" })
        end
        if type(device.station) == "table" then
            row.station = copy_fields(device.station, { "signal_dbm", "average_signal_dbm", "inactive_ms",
                "signal_sample_kind", "radio_sample_time_known", "scope", "source" })
            for _, direction in ipairs({ "receive_phy", "transmit_phy" }) do
                if type(device.station[direction]) == "table" then
                    row.station[direction] = copy_fields(device.station[direction], { "bits_per_second",
                        "standard", "mcs", "spatial_streams", "guard_interval_code", "guard_interval_microseconds",
                        "bandwidth_mhz", "noncontiguous", "short_guard_interval", "source", "scope", "sample_kind" })
                end
            end
        end
        result.devices[#result.devices + 1] = row
    end
    return result
end

local function mask_remote_address(address)
    return Privacy.mask_address(address)
end

local function export_connection_id(connection, include_remote_addresses)
    local id = connection and connection.id
    if include_remote_addresses or type(id) ~= "string" then return id end
    local remote_address = connection.remote_address
    if type(remote_address) ~= "string" or remote_address == "" then return id end
    local masked = mask_remote_address(remote_address)
    local remote_endpoint = connection.family == "ipv6"
        and ("[" .. masked .. "]:" .. tostring(connection.remote_port or 0))
        or (masked .. ":" .. tostring(connection.remote_port or 0))
    local local_endpoint = connection.local_endpoint and connection.local_endpoint.text
        or tostring(connection.local_address or "") .. ":" .. tostring(connection.local_port or 0)
    local duplicate_suffix = id:match("(#%d+)$") or ""
    return table.concat({
        tostring(connection.table or connection.protocol or "inet"), "masked",
        local_endpoint, remote_endpoint, tostring(connection.state_code or connection.state or ""),
    }, ":") .. duplicate_suffix
end

local function export_connections(connections, limit, include_remote_addresses)
    local result = copy_fields(connections, { "total", "partial" })
    result.counts = copy_object(connections and connections.counts)
    result.items = json.array({})
    local values = connections and connections.connections or {}
    local maximum = math.min(#values, bounded_limit(limit, 256, 4096, 0))
    for index = 1, maximum do
        local connection = values[index]
        local exported = copy_fields(connection, {
            "id", "table", "protocol", "family", "local_address", "local_port",
            "remote_port", "state", "state_code", "tx_queue", "rx_queue", "uid",
            "inode", "socket_type", "path", "owner_count", "owners_quality",
        })
        exported.id = export_connection_id(connection, include_remote_addresses)
        exported.remote_address = include_remote_addresses and connection.remote_address
            or mask_remote_address(connection.remote_address)
        exported.owners = json.array({})
        for owner_index, owner in ipairs(connection.owners or {}) do
            exported.owners[owner_index] = copy_fields(owner, { "pid", "fd", "fd_count", "name" })
        end
        result.items[index] = exported
    end
    result.exported = maximum
    result.truncated = maximum < #values
    result.owner_scan = copy_fields(connections and connections.owner_scan, {
        "enabled", "status", "partial", "process_candidates", "processes_scanned",
        "processes_denied", "links_examined", "matched_links", "owners_attached",
        "process_limit_reached", "link_limit_reached",
    })
    return result
end

local function export_process_affinity(affinity)
    if type(affinity) ~= "table" then return nil end
    local result = copy_fields(affinity, {
        "cpus_allowed_list", "cpus_allowed_count",
        "mems_allowed_list", "mems_allowed_count",
        "status", "observed_ns",
    })
    result.issues = json.array({})
    for index, issue in ipairs(affinity.issues or {}) do
        if index > 2 then break end
        result.issues[index] = copy_fields(issue, { "field", "status" })
    end
    return result
end

local function export_process_io(io)
    if type(io) ~= "table" then return nil end
    return copy_fields(io, {
        "read_bytes", "write_bytes", "cancelled_write_bytes",
        "rchar", "wchar", "syscr", "syscw",
    })
end

local function export_processes(processes, limit)
    local candidates = {}
    for _, process in ipairs(processes and processes.list or {}) do
        candidates[#candidates + 1] = process
    end
    table.sort(candidates, function(left, right)
        local left_cpu = finite_number(left.cpu_percent) and left.cpu_percent or -1
        local right_cpu = finite_number(right.cpu_percent) and right.cpu_percent or -1
        if left_cpu == right_cpu then
            return tostring(left.id or left.pid or "") < tostring(right.id or right.pid or "")
        end
        return left_cpu > right_cpu
    end)
    local result = copy_fields(processes, {
        "scanned", "races", "denied", "parse_errors", "process_candidates",
        "process_limit", "clock_ticks_per_second", "uptime_seconds", "truncated", "partial",
    })
    if processes and processes.io_scan then
        result.io_scan = copy_fields(processes.io_scan, {
            "status", "covered", "total", "rate_covered", "refresh_interval_ns",
            "refreshed", "reused", "capped", "observed_ns",
        })
    end
    result.total = #(processes and processes.list or {})
    result.top = json.array({})
    for index = 1, math.min(#candidates, bounded_limit(limit, 50, 2048, 0)) do
        result.top[index] = copy_fields(candidates[index], {
            "id", "pid", "name", "command", "state", "parent_pid", "threads",
            "uid", "user", "priority", "nice", "processor", "cpu_percent",
            "cpu_time_seconds",
            "elapsed_seconds",
            "resident_bytes", "virtual_bytes", "io_read_bytes", "io_write_bytes",
            "io_observed_ns", "io_status",
            "quality", "partial", "partial_reason",
        })
        result.top[index].io = export_process_io(candidates[index].io)
        if type(candidates[index].io_rate) == "table" then
            result.top[index].io_rate = copy_fields(candidates[index].io_rate, {
                "read_bytes_per_second", "write_bytes_per_second", "interval_ns",
                "observed_ns", "reason", "quality",
            })
        end
        result.top[index].affinity = export_process_affinity(candidates[index].affinity)
        -- The outer ID is relative to this procfs mount, which may already
        -- be inside a container. Do not claim an initial-host PID.
        local namespaces = candidates[index].namespaces
        if type(namespaces) == "table" then
            result.top[index].namespaces = json.object({
                namespaced = namespaces.namespaced == true,
                inner_pid = namespaces.inner_pid,
                procfs_pid = namespaces.procfs_pid,
                depth = #namespaces.nspid,
            })
        end
    end
    return result
end

local function export_gpu_engines(engines)
    local result = json.object({})
    for id, engine in pairs(engines or {}) do
        result[id] = copy_fields(engine, {
            "id", "capacity", "busy_ns", "high_water_ns", "cycles",
            "total_cycles", "high_water_cycles", "high_water_total_cycles",
            "maximum_frequency_hz", "current_frequency_hz", "rate_quality", "cycle_rate_quality",
            "utilization_percent", "cycle_utilization_percent", "clients", "quality",
        })
    end
    return result
end

local function export_gpu_frequencies(frequencies)
    local result = json.object({ domains = json.array({}) })
    for index, domain in ipairs(frequencies and frequencies.domains or {}) do
        local output = copy_fields(domain, {
            "id", "actual_hz", "current_hz", "minimum_hz", "maximum_hz",
            "hardware_minimum_hz", "efficient_hz", "hardware_maximum_hz",
            "source_kind", "source", "quality", "requested_hz", "kind", "on_subdevice", "subdevice_id",
        })
        output.states = json.array({})
        for state_index, state in ipairs(domain.states or {}) do
            output.states[state_index] = copy_fields(state, { "level", "frequency_hz", "active" })
        end
        result.domains[index] = output
    end
    result.truncated = frequencies and frequencies.truncated == true or false
    return result
end

-- A client's clocks are a different shape from a device's: the kernel names them
-- independently of the engines and publishes no DPM state table for them, so
-- this does not reuse the device exporter -- an empty `states` array on a
-- client's clock would read as "this clock has no states" rather than "this
-- clock has no state table", which is a different statement.
local function export_gpu_client_frequencies(domains)
    local result = json.array({})
    for index, domain in ipairs(domains or {}) do
        result[index] = copy_fields(domain, {
            "id", "current_hz", "maximum_hz", "engine", "of_maximum_percent", "quality",
        })
    end
    return result
end

local function export_gpu_processes(processes)
    local result = copy_fields(processes, { "quality" })
    local summary = processes and processes.summary or {}
    result.summary = copy_fields(summary, {
        "process_count", "client_count", "utilization_percent",
    })
    result.summary.engines = export_gpu_engines(summary.engines)
    result.summary.memory_summary = copy_object(summary.memory_summary)
    result.clients = json.array({})
    for index, client in ipairs(processes and processes.clients or {}) do
        local output = copy_fields(client, {
            "id", "client_id", "name", "driver", "pci_bdf", "fd_references",
            "observed_at_ns", "quality",
        })
        output.process_ids = json.array({})
        for process_index, process_id in ipairs(client.process_ids or {}) do
            output.process_ids[process_index] = process_id
        end
        output.engines = export_gpu_engines(client.engines)
        output.frequency_domains = export_gpu_client_frequencies(client.frequency_domains)
        output.memory_summary = copy_object(client.memory_summary)
        result.clients[index] = output
    end
    result.list = json.array({})
    for index, process in ipairs(processes and processes.list or {}) do
        local output = copy_fields(process, {
            "id", "pid", "starttime_ticks", "name", "uid", "quality", "utilization_percent",
            "source", "kind", "sample_timestamp_us", "sample_window",
        })
        output.engines = export_gpu_engines(process.engines)
        output.memory_summary = copy_object(process.memory_summary)
        output.memory_contexts = json.array({})
        for _, context in ipairs(process.memory_contexts or {}) do
            if #output.memory_contexts >= 512 then break end
            output.memory_contexts[#output.memory_contexts + 1] = copy_fields(context, {
                "gpu_instance_id", "compute_instance_id", "memory_bytes", "kind",
            })
        end
        output.clients = json.array({})
        for client_index, client in ipairs(process.clients or {}) do
            local exported_client = copy_fields(client, {
                "id", "client_id", "name", "driver", "pci_bdf", "mapping_quality",
                "fd_count", "observed_at_ns", "quality",
            })
            exported_client.engines = export_gpu_engines(client.engines)
            exported_client.frequency_domains =
                export_gpu_client_frequencies(client.frequency_domains)
            exported_client.memory_summary = copy_object(client.memory_summary)
            output.clients[client_index] = exported_client
        end
        result.list[index] = output
    end
    return result
end

local function export_gpu_observations(observations)
    local result = json.object({})
    local count = 0
    for name, observation in pairs(observations or {}) do
        if type(name) == "string" and type(observation) == "table" then
            count = count + 1
            if count > 128 then break end
            result[name] = copy_fields(observation, {
                "source", "quality", "retained", "reason", "observed_at_ns",
                "sample_started_ns", "sample_finished_ns", "received_at_ns", "attempted_at_ns",
                "method", "measurement", "hardware_timestamp_available",
            })
        end
    end
    return result
end

local function export_gpu_providers(providers)
    local result = json.object({})
    for _, name in ipairs({ "nvml", "amdsmi", "levelzero", "drm" }) do
        local provider = type(providers) == "table" and providers[name]
        if type(provider) == "table" then
            result[name] = copy_fields(provider, {
                "status", "reason", "source", "api_version", "driver_version",
                "transport", "sample_started_ns", "sample_finished_ns",
                "device_count", "merged_devices", "added_devices", "incomplete_devices", "truncated",
                "quality", "retained", "retained_device_count", "retention_truncated", "attempted_at_ns",
                "observed_at_ns",
            })
        end
    end
    return result
end

local function export_gpus(gpus, quality, now_ns)
    local result = json.object({
        schema = gpus and gpus.schema,
        truncated = gpus and gpus.truncated == true or false,
        partial = gpus and gpus.partial == true or false,
        devices = json.array({}),
    })
    result.process_scan = copy_fields(gpus and gpus.process_scan, {
        "enabled", "status", "quality", "reason", "scanned_processes",
        "scanned_fdinfo_files", "drm_fdinfo_files", "denied", "races",
        "parse_errors", "unmatched_clients", "truncated",
    })
    result.drm_scan = copy_fields(gpus and gpus.drm_scan, {
        "truncated", "unattached_render_nodes", "estimated_render_links",
    })
    result.providers = copy_object(gpus and gpus.providers)
    for index, device in ipairs(gpus and gpus.devices or {}) do
        local exported = copy_fields(device, {
            "id", "card", "pci_bdf", "vendor_id", "device_id", "vendor", "driver",
            "vendor_name", "model_name", "stable_id", "primary_node",
            "identity_quality", "partial", "source", "vendor_uuid", "driver_version",
            "driver_provider", "core_count",
        })
        exported.pci = copy_object(device.pci)
        exported.capabilities = copy_object(device.capabilities)
        exported.metrics = copy_object(device.metrics)
        exported.observations = export_gpu_observations(device.observations)
        exported.metric_observations = export_gpu_observations(device.metric_observations)
        exported.power_sessions = json.array(GPUPowerSession.public(device, now_ns, quality))
        exported.performance_limits = export_performance_limits(device.performance_limits, nil, false, quality)
        local power_budget = Power.gpu(device.metrics, nil,
            Power.unusable(device.quality) and device.quality or quality)
        if power_budget.comparison then
            exported.metrics.power_limit_percent = power_budget.comparison.percent
            exported.metrics.power_headroom_watts = power_budget.comparison.headroom_watts
        end
        exported.quality = copy_object(device.quality)
        exported.drm_nodes = json.array({})
        for node_index, node in ipairs(device.drm_nodes or {}) do
            exported.drm_nodes[node_index] = copy_fields(node, {
                "name", "kind", "dev", "pci_bdf", "source",
            })
        end
        exported.hwmon_refs = json.array({})
        for ref_index, ref in ipairs(device.hwmon_refs or {}) do
            exported.hwmon_refs[ref_index] = copy_fields(ref, {
                "class", "pci_bdf", "device_target", "source",
            })
        end
        exported.adl = copy_object(device.adl)
        exported.sysman = copy_object(device.sysman)
        exported.frequencies = export_gpu_frequencies(device.frequencies)
        exported.processes = export_gpu_processes(device.processes)
        exported.issues = export_issues(device.issues)
        result.devices[index] = exported
    end
    return result
end

local function export_cpu_frequency(cpu_frequency)
    local result = json.object({ policies = json.array({}) })
    for index, policy in ipairs(cpu_frequency and cpu_frequency.policies or {}) do
        local exported = copy_fields(policy, {
            "id", "policy", "policy_index", "identity_quality", "driver", "governor",
            "processor_group", "processor_number",
            "energy_performance_preference", "quality", "source",
        })
        exported.affected_cpus = json.array({})
        for cpu_index, cpu in ipairs(policy.affected_cpus or {}) do
            exported.affected_cpus[cpu_index] = cpu
        end
        exported.related_cpus = json.array({})
        for cpu_index, cpu in ipairs(policy.related_cpus or {}) do
            exported.related_cpus[cpu_index] = cpu
        end
        exported.frequencies = copy_object(policy.frequencies)
        if policy.boost then exported.boost = copy_object(policy.boost) end
        result.policies[index] = exported
    end
    if cpu_frequency and cpu_frequency.boost then
        result.boost = copy_object(cpu_frequency.boost)
    end
    result.duplicates_skipped = cpu_frequency and cpu_frequency.duplicates_skipped or 0
    result.truncated = cpu_frequency and cpu_frequency.truncated == true or false
    return result
end

local function export_cpu_clocks(clocks, quality, limit)
    local result=json.object({schema=clocks and clocks.schema,scope="logical_cpu",includes_idle=true,
        source=clocks and clocks.source,supported_cpus=clocks and clocks.supported_cpus or 0,
        measured_cpus=0,read_cpus=clocks and clocks.read_cpus or 0,denied_cpus=clocks and clocks.denied_cpus or 0,
        truncated=clocks and clocks.truncated==true or false,cpus=json.array({})})
    local current=Quality.current_source({cpu_clocks=quality},"cpu_clocks")
    local sum,minimum,maximum=0,nil,nil
    for index,row in ipairs(clocks and clocks.cpus or {}) do
        local output=copy_fields(row,{"id","package_id","core_id","source","quality","reason",
            "effective_hz","active_performance_ratio","observed_at_ns","sample_span_ns","read_errno",
            "interval_ns","interval_uncertainty_ns","aperf_hex","mperf_hex",
            "aperf_delta_cycles","mperf_delta_cycles"})
        if not current then output.quality="stale" end
        if current and row.quality=="fresh" and type(row.effective_hz)=="number" then
            sum=sum+row.effective_hz;minimum=math.min(minimum or row.effective_hz,row.effective_hz)
            maximum=math.max(maximum or row.effective_hz,row.effective_hz)
            result.measured_cpus=result.measured_cpus+1
        end
        if not limit or index<=limit then result.cpus[#result.cpus+1]=output else result.truncated=true end
    end
    if result.measured_cpus>0 then
        result.average_effective_hz=sum/result.measured_cpus
        result.minimum_effective_hz,result.maximum_effective_hz=minimum,maximum
    end
    return result
end

local function export_thermal_throttle(thermal)
    local result = json.object({ source = thermal and thermal.source,
        truncated = thermal and thermal.truncated == true or false,
        cpus = json.array({}), issues = export_issues(thermal and thermal.issues) })
    for index, cpu in ipairs(thermal and thermal.cpus or {}) do
        local output = copy_fields(cpu, {
            "id", "source", "core_count", "package_count", "core_new", "package_new",
            "core_delta_quality", "package_delta_quality", "core_total_time_ms",
            "package_total_time_ms", "core_max_time_ms", "package_max_time_ms",
        })
        output.issues = export_issues(cpu.issues)
        result.cpus[index] = output
    end
    return result
end

local function export_cpuidle(cpuidle)
    local result = json.object({ source = cpuidle and cpuidle.source,
        driver = cpuidle and cpuidle.driver, governor = cpuidle and cpuidle.governor,
        truncated = cpuidle and cpuidle.truncated == true or false,
        cpus = json.array({}), issues = export_issues(cpuidle and cpuidle.issues) })
    for index, cpu in ipairs(cpuidle and cpuidle.cpus or {}) do
        local output = copy_fields(cpu, { "id", "source" })
        output.issues = export_issues(cpu.issues)
        output.states = json.array({})
        for state_index, state in ipairs(cpu.states or {}) do
            output.states[state_index] = copy_fields(state, {
                "id", "name", "source", "usage", "time_us", "usage_delta", "new_time_us",
                "usage_delta_quality", "time_delta_quality", "exit_latency_us",
                "target_residency_us", "disabled", "rejected", "above", "below",
                "rejected_delta", "above_delta", "below_delta",
                "rejected_delta_quality", "above_delta_quality", "below_delta_quality",
            })
            output.states[state_index].issues = export_issues(state.issues)
        end
        result.cpus[index] = output
    end
    return result
end

local function export_numa(numa)
    local result = copy_fields(numa, { "truncated" })
    result.nodes = json.array({})
    if numa and numa.online_nodes then result.online_nodes = copy_array(numa.online_nodes) end
    result.issues = export_issues(numa and numa.issues)
    for index, node in ipairs(numa and numa.nodes or {}) do
        if index > 128 then result.truncated = true break end
        local output = copy_fields(node, { "id", "online", "source", "quality" })
        if node.cpu_ids then output.cpu_ids = copy_array(node.cpu_ids) end
        if node.memory then
            output.memory = copy_fields(node.memory, { "total_bytes", "free_bytes", "used_bytes",
                "file_bytes", "anonymous_bytes", "shared_bytes" })
        end
        if node.allocations then
            output.allocations = copy_fields(node.allocations, {
                "numa_hit_pages", "numa_miss_pages", "numa_foreign_pages",
                "interleave_hit_pages", "local_node_pages", "other_node_pages",
                "rate_quality",
            })
            if node.allocations.rates then
                output.allocations.rates = copy_fields(node.allocations.rates, {
                    "local_pages_per_second", "other_pages_per_second",
                })
            end
        end
        if node.distances then
            output.distances = json.array({})
            for position, distance in ipairs(node.distances) do
                if position > 128 then result.truncated = true break end
                output.distances[position] = copy_fields(distance, { "node_id", "distance" })
            end
        end
        output.issues = export_issues(node.issues)
        result.nodes[index] = output
    end
    return result
end

local function export_memory_devices(memory)
    local result = copy_fields(memory, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    result.arrays, result.devices = json.array({}), json.array({})
    result.array_ranges, result.device_ranges = json.array({}), json.array({})
    result.channels = json.array({})
    for index, array in ipairs(memory and memory.arrays or {}) do
        if index > 64 then result.truncated = true break end
        result.arrays[index] = copy_fields(array, { "id", "handle", "location_code", "use_code",
            "error_correction_code", "device_count", "maximum_capacity_bytes", "source", "quality", "ambiguous" })
    end
    for index, device in ipairs(memory and memory.devices or {}) do
        if index > 256 then result.truncated = true break end
        result.devices[index] = copy_fields(device, { "id", "handle", "array_id", "array_handle",
            "locator", "bank", "manufacturer", "part_number", "firmware_version", "form_factor",
            "form_factor_code", "memory_type", "memory_type_code", "type_detail", "size_bytes",
            "logical", "populated", "rank", "total_width_bits", "data_width_bits", "speed_mts",
            "configured_speed_mts", "minimum_voltage_mv", "maximum_voltage_mv", "configured_voltage_mv",
            "source", "quality", "ambiguous" })
    end
    for index, range in ipairs(memory and memory.array_ranges or {}) do
        if index > 256 then result.truncated = true break end
        result.array_ranges[index] = copy_fields(range, { "id", "handle", "array_id",
            "array_handle", "start_address_bytes", "end_address_bytes",
            "address_span_bytes", "partition_width", "source", "quality", "ambiguous" })
    end
    for index, range in ipairs(memory and memory.device_ranges or {}) do
        if index > 512 then result.truncated = true break end
        result.device_ranges[index] = copy_fields(range, { "id", "handle", "device_id",
            "device_handle", "array_range_id", "array_range_handle",
            "start_address_bytes", "end_address_bytes", "address_span_bytes",
            "partition_row_position", "interleave_position", "interleaved_data_depth",
            "source", "quality", "ambiguous" })
    end
    for index, channel in ipairs(memory and memory.channels or {}) do
        if index > 64 then result.truncated = true break end
        local output = copy_fields(channel, { "id", "handle", "channel_type_code",
            "channel_type", "maximum_load", "device_count", "total_load",
            "source", "quality", "ambiguous" })
        output.devices = json.array({})
        for position, member in ipairs(channel.devices or {}) do
            if position > 64 then result.truncated = true break end
            output.devices[position] = copy_fields(member,
                { "device_id", "device_handle", "load" })
        end
        result.channels[index] = output
    end
    result.issues = export_issues(memory and memory.issues)
    return result
end

local function export_expansion_slots(slots)
    local result = copy_fields(slots, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    result.slots = json.array({})
    for index, slot in ipairs(slots and slots.slots or {}) do
        if index > 128 then result.truncated = true break end
        local output = copy_fields(slot, { "id", "handle", "designation",
            "slot_type_code", "slot_type", "slot_width_code", "electrical_lanes",
            "usage_code", "slot_length_code", "slot_id", "pci_bdf",
            "base_width_code", "peer_count", "source", "quality", "ambiguous" })
        output.peer_bdfs = json.array(slot.peer_bdfs or {})
        result.slots[index] = output
    end
    result.issues = export_issues(slots and slots.issues)
    return result
end

local function export_onboard_devices(onboard)
    local result = copy_fields(onboard, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    result.devices = json.array({})
    for index, device in ipairs(onboard and onboard.devices or {}) do
        if index > 128 then result.truncated = true break end
        result.devices[index] = copy_fields(device, { "id", "handle", "designation",
            "device_type_code", "device_type", "type_instance", "enabled", "pci_bdf",
            "structure_type", "device_index", "device_count",
            "source", "quality", "ambiguous" })
    end
    result.issues = export_issues(onboard and onboard.issues)
    return result
end

local function export_port_connectors(ports)
    local result = copy_fields(ports, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    result.ports = json.array({})
    for index, port in ipairs(ports and ports.ports or {}) do
        if index > 128 then result.truncated = true break end
        result.ports[index] = copy_fields(port, { "id", "handle",
            "internal_designation", "internal_connector_code", "internal_connector",
            "external_designation", "external_connector_code", "external_connector",
            "port_type_code", "port_type", "source", "quality", "ambiguous" })
    end
    result.issues = export_issues(ports and ports.issues)
    return result
end

local function export_platform_firmware(firmware, maximum)
    maximum = math.min(maximum or 16, 16)
    local result = copy_fields(firmware, { "source", "major", "minor", "docrev", "partial", "truncated", "structure_count" })
    for _, spec in ipairs({ { "firmwares", { "id", "handle", "structure_type", "vendor", "version", "release_date",
        "runtime_segment", "runtime_area_bytes", "rom_size_raw", "rom_size_bytes", "rom_size_minimum_bytes",
        "rom_size_extended_raw", "characteristics_hex", "characteristics_known", "vendor_characteristics_present",
        "extension_1", "extension_2", "targeted_content_enabled", "virtual_machine_reported",
        "manufacturing_mode_supported", "manufacturing_mode_enabled", "firmware_revision", "controller_revision",
        "source", "quality", "ambiguous" } }, { "systems", { "id", "handle", "structure_type", "manufacturer",
        "product", "version", "sku", "family", "serial_present", "uuid_present", "wake_type_code", "wake_type",
        "source", "quality", "ambiguous" } } }) do
        local list = firmware and firmware[spec[1]] or {}
        result[spec[1]], result[spec[1] .. "_total"] = json.array({}), #list
        for index, device in ipairs(list) do
            if index > maximum then result.truncated = true break end
            local record = copy_fields(device, spec[2])
            if spec[1] == "firmwares" then
                record.features = json.object({})
                for _, feature in ipairs(require("wtop.format.smbios").PLATFORM_FEATURES) do
                    local value = device.features and device.features[feature[1]]
                    if type(value) == "boolean" then record.features[feature[1]] = value end
                end
            end
            result[spec[1]][index] = record
        end
    end
    result.issues = export_issues(firmware and firmware.issues)
    return result
end

local function export_firmware_enclosures(firmware, maximum)
    maximum = math.min(maximum or 64, 64)
    local result = copy_fields(firmware, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    for _, spec in ipairs({ { "baseboards", {
        "id", "handle", "structure_type", "manufacturer", "product", "version", "location",
        "serial_present", "asset_tag_present", "feature_flags", "chassis_handle",
        "board_type_code", "board_type", "contained_count", "containment_complete",
        "source", "quality", "ambiguous" } }, { "enclosures", {
        "id", "handle", "structure_type", "manufacturer", "version", "sku", "chassis_type_code",
        "chassis_type", "serial_present", "asset_tag_present", "lock_reported_present",
        "boot_state_code", "boot_state", "power_state_code", "power_state", "thermal_state_code",
        "thermal_state", "security_state_code", "security_state", "oem_data_present",
        "height_u", "height_ou", "rack_type_code", "power_cords", "contained_count",
        "contained_record_length", "containment_complete", "source", "quality", "ambiguous" } } }) do
        local list = firmware and firmware[spec[1]] or {}
        result[spec[1]] = json.array({})
        result[spec[1] .. "_total"] = #list
        for index, device in ipairs(list) do
            if index > maximum then result.truncated = true break end
            local record = copy_fields(device, spec[2])
            if spec[1] == "baseboards" then
                record.contained_handles = json.array({})
                for n, handle in ipairs(device.contained_handles or {}) do
                    if n > 120 then result.truncated = true break end
                    record.contained_handles[n] = handle
                end
            else
                record.contained_elements = json.array({})
                for n, element in ipairs(device.contained_elements or {}) do
                    if n > 78 then result.truncated = true break end
                    record.contained_elements[n] = copy_fields(element,
                        { "type_code", "type_kind", "board_type", "minimum", "maximum" })
                end
            end
            result[spec[1]][index] = record
        end
    end
    result.issues = export_issues(firmware and firmware.issues)
    return result
end

local function export_firmware_batteries(firmware)
    local result = copy_fields(firmware, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    result.batteries = json.array({})
    for index, battery in ipairs(firmware and firmware.batteries or {}) do
        if index > 64 then result.truncated = true break end
        result.batteries[index] = copy_fields(battery, { "id", "handle",
            "location", "name", "manufacturer", "chemistry_code", "chemistry",
            "sbds_chemistry", "sbds_version", "design_capacity_raw_mwh",
            "design_capacity_multiplier", "design_capacity_mwh",
            "design_voltage_mv", "maximum_error_percent", "source", "quality",
            "ambiguous" })
    end
    result.issues = export_issues(firmware and firmware.issues)
    return result
end

local function export_firmware_power_supplies(firmware)
    local result = copy_fields(firmware, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    result.supplies = json.array({})
    for index, supply in ipairs(firmware and firmware.supplies or {}) do
        if index > 64 then result.truncated = true break end
        result.supplies[index] = copy_fields(supply, { "id", "handle",
            "power_unit_group", "location", "name", "manufacturer", "part_number",
            "revision", "max_power_capacity_raw", "max_power_watts",
            "supply_type_code", "supply_type", "status_code", "status",
            "range_switching_code", "range_switching", "present", "unplugged",
            "hot_replaceable", "voltage_probe_id", "cooling_device_id",
            "current_probe_id", "source", "quality", "ambiguous" })
    end
    result.issues = export_issues(firmware and firmware.issues)
    return result
end

local function export_firmware_bmcs(firmware)
    local result = copy_fields(firmware, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    result.devices = json.array({})
    for index, device in ipairs(firmware and firmware.devices or {}) do
        if index > 64 then result.truncated = true break end
        result.devices[index] = copy_fields(device, { "id", "handle",
            "interface_type_code", "interface_type", "ipmi_revision",
            "i2c_target_address", "nv_storage_address", "base_address_field_hex",
            "address_space", "base_address_hex", "register_spacing_code",
            "register_spacing_bytes", "interrupt_specified", "interrupt_number",
            "interrupt_polarity", "interrupt_trigger", "source", "quality",
            "ambiguous" })
    end
    result.issues = export_issues(firmware and firmware.issues)
    return result
end

local function export_firmware_tpms(firmware)
    local result = copy_fields(firmware, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    result.devices = json.array({})
    for index, device in ipairs(firmware and firmware.devices or {}) do
        if index > 64 then result.truncated = true break end
        result.devices[index] = copy_fields(device, { "id", "handle", "vendor_id",
            "spec_major", "spec_minor", "spec_version", "firmware_version_1_hex",
            "firmware_version_2_hex", "description", "characteristics_supported",
            "family_configurable_firmware", "family_configurable_platform",
            "family_configurable_oem", "source", "quality", "ambiguous" })
    end
    result.issues = export_issues(firmware and firmware.issues)
    return result
end

local function export_firmware_components(firmware)
    local result = copy_fields(firmware, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    result.components = json.array({})
    for index, component in ipairs(firmware and firmware.components or {}) do
        if index > 128 then result.truncated = true break end
        local exported = copy_fields(component, { "id", "handle", "name", "version",
            "version_format", "firmware_id", "firmware_id_format",
            "release_date", "manufacturer", "lowest_supported_version",
            "image_size_bytes", "image_size_hex", "updatable", "write_protected",
            "state_code", "state", "associated_count", "association_complete",
            "source", "quality", "ambiguous" })
        exported.associated_handles = json.array({})
        for position, handle in ipairs(component.associated_handles or {}) do
            if position > 64 then break end
            exported.associated_handles[position] = handle
        end
        result.components[index] = exported
    end
    result.issues = export_issues(firmware and firmware.issues)
    return result
end

local function export_firmware_esrt(esrt)
    local result = copy_fields(esrt, { "source", "partial", "truncated",
        "scanned", "declared_count", "resource_version", "issues_truncated" })
    result.entries = json.array({})
    for index, entry in ipairs(esrt and esrt.entries or {}) do
        if index > 128 then result.truncated = true break end
        result.entries[index] = copy_fields(entry, { "id", "index", "guid",
            "type_code", "type", "version", "lowest_supported_version",
            "capsule_flags_hex", "last_attempt_version", "last_attempt_status",
            "quality", "status", "ambiguous", "source" })
    end
    result.issues = export_issues(esrt and esrt.issues)
    return result
end

local function export_tpm(tpm)
    local result = copy_fields(tpm, { "source", "partial", "truncated" })
    result.devices = json.array({})
    for index, device in ipairs(tpm and tpm.devices or {}) do
        if index > 16 then result.truncated = true break end
        local output = copy_fields(device, { "id", "index", "version_major",
            "version_minor", "version_source", "driver",
            "active", "enabled", "temporarily_deactivated", "truncated",
            "quality", "source" })
        output.banks = json.array({})
        for bank_index, bank in ipairs(device.banks or {}) do
            if bank_index > 16 then result.truncated = true break end
            output.banks[bank_index] = copy_fields(bank, { "algorithm", "pcr_count" })
        end
        output.issues = export_issues(device.issues)
        result.devices[index] = output
    end
    result.issues = export_issues(tpm and tpm.issues)
    return result
end

local function export_watchdog(watchdog)
    local result = copy_fields(watchdog, { "source", "partial", "truncated" })
    result.devices = json.array({})
    for index, device in ipairs(watchdog and watchdog.devices or {}) do
        if index > 16 then result.truncated = true break end
        local output = copy_fields(device, { "id", "index", "identity", "driver",
            "state", "timeout_seconds", "timeleft_seconds", "pretimeout_seconds",
            "nowayout", "status", "bootstatus", "firmware_version",
            "pretimeout_governor", "device_path", "quality", "source" })
        output.issues = export_issues(device.issues)
        result.devices[index] = output
    end
    result.issues = export_issues(watchdog and watchdog.issues)
    return result
end

local function export_rfkill(rfkill)
    local result = copy_fields(rfkill, { "source", "partial", "truncated" })
    result.devices = json.array({})
    for index, device in ipairs(rfkill and rfkill.devices or {}) do
        if index > 64 then result.truncated = true break end
        local output = copy_fields(device, { "id", "index", "name", "type",
            "hard_blocked", "soft_blocked", "blocked", "persistent",
            "state_source", "device_path", "quality", "source" })
        output.issues = export_issues(device.issues)
        result.devices[index] = output
    end
    result.issues = export_issues(rfkill and rfkill.issues)
    return result
end

local function export_thermal_zones(thermal)
    local result = copy_fields(thermal, { "source", "partial", "truncated" })
    result.zones = json.array({})
    result.cooling_devices = json.array({})
    for index, zone in ipairs(thermal and thermal.zones or {}) do
        if index > 64 then result.truncated = true break end
        local output = copy_fields(zone, { "id", "index", "type",
            "temperature_celsius", "mode", "policy", "device_path",
            "truncated", "quality", "source" })
        output.trips = json.array({})
        for trip_index, trip in ipairs(zone.trips or {}) do
            if trip_index > 32 then output.truncated = true break end
            output.trips[trip_index] = copy_fields(trip,
                { "index", "type", "temperature_celsius" })
        end
        output.bindings = json.array({})
        for binding_index, binding in ipairs(zone.bindings or {}) do
            if binding_index > 32 then output.truncated = true break end
            output.bindings[binding_index] = copy_fields(binding,
                { "slot", "cooling_id", "trip_index", "weight" })
        end
        output.issues = export_issues(zone.issues)
        result.zones[index] = output
    end
    for index, device in ipairs(thermal and thermal.cooling_devices or {}) do
        if index > 128 then result.truncated = true break end
        local output = copy_fields(device, { "id", "index", "type",
            "cur_state", "max_state", "device_path", "truncated",
            "quality", "source" })
        if type(device.stats) == "table" then
            output.stats = copy_fields(device.stats,
                { "total_transitions", "truncated", "quality", "source" })
            output.stats.time_in_state_ms = json.array({})
            for state_index, state in ipairs(device.stats.time_in_state_ms or {}) do
                if state_index > 256 then output.stats.truncated = true break end
                output.stats.time_in_state_ms[state_index] =
                    copy_fields(state, { "state", "milliseconds" })
            end
        end
        output.issues = export_issues(device.issues)
        result.cooling_devices[index] = output
    end
    result.issues = export_issues(thermal and thermal.issues)
    return result
end

local function export_host_interfaces(firmware)
    local result = copy_fields(firmware, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    result.devices = json.array({})
    for index, device in ipairs(firmware and firmware.devices or {}) do
        if index > 64 then result.truncated = true break end
        local output = copy_fields(device, { "id", "handle", "interface_type_code",
            "interface_type", "interface_data_bytes", "oem_vendor_id",
            "legacy_oem_format", "protocol_count", "source", "quality", "ambiguous" })
        output.protocols = json.array({})
        for protocol_index, protocol in ipairs(device.protocols or {}) do
            if protocol_index > 64 then result.truncated = true break end
            output.protocols[protocol_index] = copy_fields(protocol,
                { "type_code", "type", "data_bytes" })
        end
        result.devices[index] = output
    end
    result.issues = export_issues(firmware and firmware.issues)
    return result
end

local function export_processor_firmware(firmware)
    local result = copy_fields(firmware, { "source", "major", "minor", "docrev",
        "partial", "truncated", "structure_count" })
    result.processors, result.caches = json.array({}), json.array({})
    for index, processor in ipairs(firmware and firmware.processors or {}) do
        if index > 128 then result.truncated = true break end
        local output = copy_fields(processor, { "id", "handle", "designation",
            "processor_type_code", "family_code", "manufacturer", "version", "part_number",
            "external_clock_mhz", "max_speed_mhz", "boot_speed_mhz",
            "populated", "status_code", "upgrade_code", "core_count",
            "enabled_core_count", "thread_count", "enabled_thread_count",
            "source", "quality", "ambiguous" })
        output.cache_handles = copy_fields(processor.cache_handles, { "l1", "l2", "l3" })
        result.processors[index] = output
    end
    for index, cache in ipairs(firmware and firmware.caches or {}) do
        if index > 512 then result.truncated = true break end
        result.caches[index] = copy_fields(cache, { "id", "handle", "designation",
            "level", "enabled", "location_code", "write_mode_code",
            "maximum_size_bytes", "installed_size_bytes", "speed_ns",
            "error_correction_code", "cache_type_code", "cache_type",
            "associativity_code", "source", "quality", "ambiguous" })
    end
    result.issues = export_issues(firmware and firmware.issues)
    return result
end

local function export_edac(edac)
    local result = json.object({ source = edac and edac.source,
        truncated = edac and edac.truncated == true or false,
        controllers = json.array({}), issues = export_issues(edac and edac.issues) })
    for index, controller in ipairs(edac and edac.controllers or {}) do
        if index > 64 then result.truncated = true break end
        local output = copy_fields(controller, { "id", "index", "name", "source",
            "correctable_errors", "uncorrectable_errors" })
        output.issues = export_issues(controller.issues)
        output.modules = json.array({})
        for module_index, module in ipairs(controller.modules or {}) do
            if module_index > 256 then result.truncated = true break end
            output.modules[module_index] = copy_fields(module, { "id", "kind", "label",
                "location", "correctable_errors", "uncorrectable_errors", "source" })
            output.modules[module_index].issues = export_issues(module.issues)
        end
        result.controllers[index] = output
    end
    return result
end

local function export_spd(spd)
    local result = json.object({ source = spd and spd.source,
        truncated = spd and spd.truncated == true or false,
        devices = json.array({}), issues = export_issues(spd and spd.issues) })
    for index, device in ipairs(spd and spd.devices or {}) do
        if index > 64 then result.truncated = true break end
        local output = copy_fields(device, { "id", "driver", "source", "memory_type", "module_type",
            "module_type_code", "revision", "minimum_cycle_ps", "part_number",
            "crc_valid", "crc_base_valid", "checksum_valid", "bytes_read", "complete",
            "temperature_sensor_present", "size_bytes", "rank", "module_banks",
            "data_width_bits", "total_width_bits", "quality" })
        output.issues = export_issues(device.issues)
        result.devices[index] = output
    end
    return result
end

local function export_sensors(snapshot)
    local sensors = snapshot.sensors
    local result = copy_fields(sensors, { "quality", "partial" })
    result.devices = json.array({})
    for device_index, device in ipairs(sensors and sensors.devices or {}) do
        local exported = copy_fields(device, {
            "id", "class", "class_index", "name", "device_target", "device_path",
            "identity_quality", "quality", "truncated", "source", "driver",
        })
        exported.channels = json.array({})
        for channel_index, channel in ipairs(device.channels or {}) do
            local output = copy_fields(channel, {
                "id", "type", "index", "unit", "label", "input", "input_source",
                "alarm", "fault", "identity_quality", "quality", "source", "enabled",
                "energy_microjoules", "energy_read_started_ns", "energy_read_finished_ns",
            })
            output.readings = copy_object(channel.readings)
            output.thresholds = copy_object(channel.thresholds)
            output.errors = copy_object(channel.errors)
            output.intervals_ms = copy_object(channel.intervals_ms)
            output.power = SensorPower.public(channel, snapshot.timestamp_ns, snapshot.quality and snapshot.quality.sensors)
            if output.power then output.power.limits = json.array(output.power.limits) end
            local thermal = Thermal.channel(snapshot, device, channel)
            if thermal then
                output.critical_celsius = thermal.critical_celsius
                output.headroom_celsius = thermal.headroom_celsius
            end
            if type(channel.session) == "table" then
                output.session = copy_fields(channel.session, {
                    "minimum", "maximum", "average", "samples",
                    "first_timestamp_ns", "last_timestamp_ns",
                })
            end
            exported.channels[channel_index] = output
        end
        result.devices[device_index] = exported
    end
    result.truncated = sensors and sensors.truncated == true or false
    return result
end

local function export_disk_health(snapshot)
    local result = json.object({ devices = json.array({}),
        truncated = snapshot.disk_health and snapshot.disk_health.truncated == true or false })
    for _, disk in ipairs(snapshot.disks and snapshot.disks.devices or {}) do
        local health = StorageHealth.match(snapshot, disk)
        if health then
            local item = copy_fields(health, { "id", "name", "bus_type", "quality", "deep", "skipped", "source", "scope" })
            item.observed_at_ns = StorageHealth.observed_at(snapshot, health)
            if not StorageHealth.current(snapshot, health) then
                item.quality = "stale"
            end
            item.query_errors = copy_object(health.query_errors)
            item.temperature = json.object({ channels = json.array({}),
                critical_celsius = health.temperature and health.temperature.critical_celsius,
                warning_celsius = health.temperature and health.temperature.warning_celsius,
                limit_scope = health.temperature and "device_composite" or nil })
            for index, channel in ipairs(health.temperature and health.temperature.channels or {}) do
                item.temperature.channels[index] = copy_fields(channel, {
                    "id", "index", "label", "input", "unit", "quality", "source",
                    "over_threshold_celsius", "under_threshold_celsius",
                })
                item.temperature.channels[index].thresholds = copy_fields(channel.thresholds, { "crit", "max" })
            end
            if health.nvme then item.nvme = copy_fields(health.nvme, {
                "critical_warning", "available_spare_percent", "available_spare_threshold_percent",
                "percentage_used", "temperature_celsius", "data_units_read", "data_units_written",
                "data_unit_bytes", "data_units_rounded_up", "percentage_used_lower_bound",
                "host_read_commands", "host_write_commands", "controller_busy_minutes", "power_cycles",
                "power_on_hours", "unsafe_shutdowns", "media_errors", "error_log_entries", "source", "scope",
            }) end
            if health.ata then
                item.ata = json.object({ version = health.ata.version, source = health.ata.source,
                    attributes = json.array({}) })
                for index, attribute in ipairs(health.ata.attributes or {}) do
                    item.ata.attributes[index] = copy_fields(attribute, { "id", "flags", "current", "worst", "raw_hex" })
                end
            end
            result.devices[#result.devices + 1] = item
        end
    end
    return result
end

local function export_mounts(mounts)
    local result = json.object({ mounts = json.array({}) })
    for index, mount in ipairs(mounts and mounts.mounts or {}) do
        local exported = copy_fields(mount, {
            "id", "mount_id", "parent_id", "major", "minor", "device_id", "root",
            "mount_point", "fs_type", "source", "readonly", "pseudo", "network",
            "kind", "quality", "partial", "partial_reason", "skipped",
        })
        if mount.capacity then exported.capacity = copy_object(mount.capacity) end
        if mount.inodes then exported.inodes = copy_object(mount.inodes) end
        if mount.statvfs_error then
            exported.statvfs_error = copy_fields(mount.statvfs_error, { "status", "reason", "errno" })
        end
        result.mounts[index] = exported
    end
    result.count = mounts and mounts.count or 0
    result.complete = mounts and mounts.complete or 0
    result.failed = mounts and mounts.failed or 0
    result.skipped = mounts and mounts.skipped or 0
    result.budget_exhausted = mounts and mounts.budget_exhausted == true or false
    result.budget_reason = mounts and mounts.budget_reason or nil
    result.statvfs_attempted = mounts and mounts.statvfs_attempted or 0
    result.statvfs_budget_ms = mounts and mounts.statvfs_budget_ms or nil
    result.max_statvfs_calls = mounts and mounts.max_statvfs_calls or nil
    result.partial = mounts and mounts.partial == true or false
    return result
end

local function export_cgroup_pressure(pressure)
    local result = json.object({})
    for _, resource in ipairs({ "cpu", "memory", "io" }) do
        local source = pressure and pressure[resource]
        if source then
            local exported = json.object({})
            for _, level in ipairs({ "some", "full" }) do
                if source[level] then
                    exported[level] = copy_fields(source[level], {
                        "avg10", "avg60", "avg300", "total_usec", "total_usec_per_second",
                    })
                end
            end
            result[resource] = exported
        end
    end
    return result
end

local function export_workload_summary(summary)
    local result = copy_fields(summary, {
        "root_id", "node_count", "visible_process_count", "unknown_process_nodes",
        "partial_node_count",
        "fresh_node_count", "gap_node_count", "reset_node_count", "issue_count",
        "denied_issue_count", "missing_issue_count", "parse_issue_count",
        "skipped_symlinks", "skipped_dot_entries", "skipped_unsafe_entries",
        "max_depth", "max_nodes", "depth_limited", "node_limited", "truncated",
        "service_count", "container_count", "pod_count", "user_session_count",
    })
    result.issues_by_kind = copy_object(summary and summary.issues_by_kind)
    if summary and summary.root then
        result.root = copy_fields(summary.root, {
            "id", "process_count", "cpu_utilization_percent", "memory_current_bytes",
            "memory_max_bytes", "memory_swap_current_bytes", "pids_current", "pids_max",
        })
        result.root.io_rates = copy_object(summary.root.io_rates)
        result.root.pressure = export_cgroup_pressure(summary.root.pressure)
    end
    return result
end

local function export_workloads(workloads, limit)
    local result = json.object({ items = json.array({}) })
    result.schema = workloads and workloads.schema or "dev.waterrun.wtop.cgroup/v1"
    result.mount_path = workloads and workloads.mount_path or nil
    result.root = workloads and workloads.root or nil
    result.summary = export_workload_summary(workloads and workloads.summary)
    local candidates = {}
    for _, workload in ipairs(workloads and workloads.workloads or {}) do
        candidates[#candidates + 1] = workload
    end
    table.sort(candidates, function(left, right)
        local left_value = left.cpu and left.cpu.utilization_percent
        local right_value = right.cpu and right.cpu.utilization_percent
        local left_cpu = finite_number(left_value) and left_value or -1
        local right_cpu = finite_number(right_value) and right_value or -1
        if left_cpu == right_cpu then return tostring(left.id or "") < tostring(right.id or "") end
        return left_cpu > right_cpu
    end)
    local maximum = math.min(#candidates, bounded_limit(limit, 256, 2048, 0))
    for index = 1, maximum do
        local workload = candidates[index]
        local exported = copy_fields(workload, {
            "id", "name", "parent_id", "depth", "accessible", "partial",
            "cgroup_type",
            "issue_count", "rate_quality", "quality",
        })
        -- Identity derived from the cgroup path, not read from the kernel, so a
        -- consumer can tell "this is a containerd scope" from "the path happens
        -- to contain a long hex run".  Absent fields mean the path never
        -- established them, and a non-Linux workload has no semantics at all.
        if workload.semantics ~= nil then
            exported.semantics = copy_fields(workload.semantics, {
                "unit", "unit_type", "container", "container_scope", "runtime",
                "container_id", "container_short_id", "pod", "pod_scope",
                "user_id", "user_slice", "label",
            })
        end
        exported.processes = copy_fields(workload.processes,
            { "count", "visible_count", "hidden_entries", "status" })
        if workload.threads then
            exported.threads = copy_fields(workload.threads,
                { "count", "visible_count", "hidden_entries", "status" })
        end
        exported.cpu = copy_fields(workload.cpu, { "utilization_percent", "weight" })
        if workload.cpu and workload.cpu.max then
            exported.cpu.max = copy_object(workload.cpu.max)
        end
        exported.memory = copy_fields(workload.memory, {
            "current_bytes", "peak_bytes", "low_bytes", "high_bytes", "max_bytes",
            "swap_current_bytes",
        })
        exported.io = json.object({ rates = copy_object(
            workload.io and workload.io.totals and workload.io.totals.rates
        ) })
        exported.pids = copy_fields(workload.pids, { "current", "max" })
        exported.pressure = export_cgroup_pressure(workload.pressure)
        exported.cpuset = copy_object(workload.cpuset)
        result.items[index] = exported
    end
    result.total = #candidates
    result.exported = maximum
    result.truncated = maximum < #candidates
    return result
end

local function export_quality(quality, captured_ns)
    local result = json.object({})
    for resource, value in pairs(quality or {}) do
        local exported = copy_fields(value, {
            "status", "quality", "reason", "timestamp_ns", "duration_ns",
            "value_timestamp_ns",
        })
        local value_ns = value and value.value_timestamp_ns
        if finite_number(value_ns) and value_ns >= 0
            and finite_number(captured_ns) and captured_ns >= value_ns then
            exported.value_age_ms = math.floor((captured_ns - value_ns) / 1000000)
        end
        result[resource] = exported
    end
    return result
end

function M.capabilities(capabilities)
    local result = json.object({})
    for id, capability in pairs(capabilities or {}) do
        local exported = copy_fields(capability, {
            "state", "available", "reason", "source", "permission", "retry_after_ms",
        })
        if capability.details then exported.details = copy_object(capability.details) end
        result[id] = exported
    end
    return result
end

function M.privilege(privilege)
    return copy_fields(privilege, {
        "mode", "uid", "effective_uid", "original_uid", "root",
        "elevated", "via_sudo", "requested",
    })
end


-- Host identity, firmware and kernel-wide counters.  Deliberately excludes the
-- host-identifying DMI members the collector already refuses to read (serial
-- numbers, asset tags, UUIDs), so a snapshot pasted into a bug report does not
-- leak more than the operator expects.
local function export_system(system)
    if type(system) ~= "table" or next(system) == nil then return json.object({}) end
    return json.object({
        host = copy_fields(system.host, { "hostname", "architecture", "domain" }),
        kernel = copy_fields(system.kernel, { "type", "release", "version", "command_line" }),
        distribution = copy_fields(system.distribution, {
            "name", "pretty_name", "version", "version_id", "id", "id_like",
            "build_id", "variant",
        }),
        firmware = copy_fields(system.firmware, {
            "system_vendor", "product_name", "product_version", "product_family",
            "board_vendor", "board_name", "board_version", "bios_vendor",
            "bios_version", "bios_date", "bios_release", "chassis_vendor",
            "chassis_type", "chassis_type_code",
        }),
        virtualization = copy_fields(system.virtualization, {
            "virtual", "technology", "container", "container_technology",
        }),
        security = copy_fields(system.security, { "selinux", "apparmor", "lockdown" }),
        limits = json.object({
            pid_max = system.limits and system.limits.pid_max or nil,
            threads_max = system.limits and system.limits.threads_max or nil,
            max_map_count = system.limits and system.limits.max_map_count or nil,
            entropy_available = system.limits and system.limits.entropy_available or nil,
            file_descriptors = copy_fields(system.limits and system.limits.file_descriptors,
                { "open", "allocated", "maximum" }),
        }),
        counters = copy_fields(system.counters,
            { "ctxt", "intr", "forks", "procs_running", "procs_blocked" }),
        swap = json.object({
            total_bytes = system.swap and system.swap.total_bytes or nil,
            used_bytes = system.swap and system.swap.used_bytes or nil,
            devices = (function()
                local devices = json.array({})
                for index, device in ipairs(system.swap and system.swap.devices or {}) do
                    if index > 32 then break end
                    devices[index] = copy_fields(device,
                        { "name", "type", "size_bytes", "used_bytes", "priority" })
                end
                return devices
            end)(),
        }),
        vmstat = copy_object(system.vmstat),
        uptime_seconds = system.uptime_seconds,
        idle_seconds = system.idle_seconds,
        boot_time_unix = system.boot_time_unix,
        timezone = system.timezone,
    })
end

local function export_power_supplies(supplies)
    if type(supplies) ~= "table" or next(supplies) == nil then return json.object({}) end
    local function device_list(source, fields)
        local result = json.array({})
        for index, device in ipairs(source or {}) do
            if index > 16 then break end
            result[index] = copy_fields(device, fields)
        end
        return result
    end
    return json.object({
        batteries = device_list(supplies.batteries, {
            "id", "name", "type", "present", "status", "technology", "manufacturer",
            "model", "cycle_count", "capacity_percent", "health_percent",
            "energy_watt_hours", "energy_full_watt_hours", "energy_design_watt_hours",
            "power_watts", "voltage_volts", "temperature_celsius",
            "time_remaining_seconds", "time_to_full_seconds", "capacity_level",
        }),
        supplies = device_list(supplies.supplies,
            { "id", "name", "type", "online", "online_mode", "present" }),
        summary = copy_fields(supplies.summary, { "count", "capacity_percent", "power_watts", "state" }),
        on_ac_power = supplies.on_ac_power,
        skipped_devices = supplies.skipped_devices,
        truncated = supplies.truncated,
    })
end

local function export_pci_aer(aer)
    if type(aer) ~= "table" then return nil end
    local result = copy_fields(aer, { "status", "interval_seconds" })
    for _, kind in ipairs({ "correctable", "nonfatal", "fatal" }) do
        local stats = aer[kind]
        if type(stats) == "table" then
            result[kind] = json.object({ total = stats.total,
                categories = json.array({}) })
            if type(stats.change) == "table" then
                result[kind].change = copy_fields(stats.change,
                    { "new_reports", "quality" })
            end
            for index, category in ipairs(stats.categories or {}) do
                if index > 32 then break end
                result[kind].categories[index] = copy_fields(category, { "name", "count" })
            end
        end
    end
    if type(aer.rootport) == "table" then
        result.rootport = copy_fields(aer.rootport,
            { "correctable", "nonfatal", "fatal" })
        result.rootport.changes = json.object({})
        for _, kind in ipairs({ "correctable", "nonfatal", "fatal" }) do
            local change = aer.rootport.changes and aer.rootport.changes[kind]
            if type(change) == "table" then
                result.rootport.changes[kind] = copy_fields(change,
                    { "new_reports", "quality" })
            end
        end
    end
    result.issues = json.array({})
    for index, issue in ipairs(aer.issues or {}) do
        if index > 6 then break end
        result.issues[index] = copy_fields(issue, { "field", "status" })
    end
    return result
end

local function export_pci_msi(msi)
    if type(msi) ~= "table" then return nil end
    local result = copy_fields(msi,
        { "status", "source", "count_status", "affinity_status", "total" })
    result.vectors = json.array({})
    for index, vector in ipairs(msi.vectors or {}) do
        if index > 256 then break end
        result.vectors[index] = copy_fields(vector,
            { "irq", "mode", "status", "count_status", "total",
              "effective_affinity", "allowed_affinity", "affinity_status" })
        result.vectors[index].top_cpus = json.array({})
        for position, cpu in ipairs(vector.top_cpus or {}) do
            if position > 4 then break end
            result.vectors[index].top_cpus[position] =
                copy_fields(cpu, { "cpu_id", "count" })
        end
        if type(vector.change) == "table" then
            result.vectors[index].change = copy_fields(vector.change,
                { "quality", "new_interrupts" })
        end
    end
    if type(msi.change) == "table" then
        result.change = copy_fields(msi.change,
            { "quality", "new_interrupts", "interval_seconds" })
    end
    return result
end

local function export_displays(source, limit, state)
    source = type(source) == "table" and source or {}
    local devices = type(source.devices) == "table" and source.devices or {}
    local output = json.array({})
    local current = Quality.current_source({ displays = state }, "displays")
    for index = 1, math.min(#devices, limit or 128) do
        local device = devices[index]
        local row = copy_fields(device, { "id", "card", "connector", "connector_id", "connection",
            "enabled", "dpms", "pci_address", "source", "status", "quality", "reason",
            "edid_status", "edid_reason", "observed_at_ns", "modes_status", "modes_truncated" })
        if not current then row.quality = "stale" end
        row.modes = json.array({})
        for position, mode in ipairs(device.modes or {}) do
            if position > 128 then row.modes_truncated = true break end
            row.modes[position] = mode
        end
        if type(device.edid) == "table" then
            row.edid = copy_fields(device.edid, { "version", "quality", "reason", "manufacturer",
                "name", "product_code", "serial_present", "manufacture_week", "manufacture_year",
                "model_year", "digital", "interface", "bits_per_color", "width_mm", "height_mm",
                "extension_count", "blocks_available", "extensions_decoded" })
            if not current then row.edid.quality = "stale" end
            row.edid.detailed_timings = json.array({})
            for position, value in ipairs(device.edid.detailed_timings or {}) do
                if position > 4 then break end
                row.edid.detailed_timings[position] = copy_fields(value, {
                    "horizontal_active_pixels", "vertical_active_lines", "horizontal_blanking_pixels",
                    "vertical_blanking_lines", "pixel_clock_hz", "interlaced", "preferred",
                    "refresh_hz", "width_mm", "height_mm" })
            end
        end
        output[index] = row
    end
    return json.object({ devices = output, total = source.total or #devices,
        total_is_lower_bound = source.total_is_lower_bound,
        truncated = source.truncated == true or #devices > #output,
        status = state and state.status or source.status, quality = state and state.quality,
        source = source.source })
end

local function export_inventory(snapshot)
    local inventory = type(snapshot.inventory) == "table" and snapshot.inventory or {}
    local function devices(source, fields, limit)
        local result = json.array({})
        for index, device in ipairs(source or {}) do
            if index > limit then break end
            result[index] = copy_fields(device, fields)
        end
        return result
    end
    local pci = type(inventory.pci) == "table" and inventory.pci or {}
    local usb = type(inventory.usb) == "table" and inventory.usb or {}
    local pci_devices = devices(pci.devices, {
        "address", "vendor_id", "device_id", "class_id", "revision",
        "vendor_name", "device_name",
        "parent_address", "parent_bus", "source", "driver", "numa_node", "link_speed_gtps",
        "link_width", "max_link_speed_gtps", "max_link_width", "iommu_group_id",
    }, 256)
    for index, device in ipairs(pci.devices or {}) do
        if index > 256 then break end
        pci_devices[index].aer = export_pci_aer(device.aer)
        pci_devices[index].msi = export_pci_msi(device.msi)
        if type(device.sriov) == "table" then
            pci_devices[index].sriov = copy_fields(device.sriov, {
                "role", "status", "total_vfs", "enabled_vfs",
                "physical_function_address",
            })
        end
    end
    local iommu_groups = json.array({})
    for index, group in ipairs(pci.iommu_groups or {}) do
        if index > 256 then break end
        iommu_groups[index] = copy_fields(group, { "id", "status", "source" })
        if type(group.members) == "table" then
            local members = json.array({})
            for position, name in ipairs(group.members) do
                if position > 256 then break end
                members[position] = name
            end
            iommu_groups[index].members = members
        end
    end
    local graph = Hardware.build(snapshot)
    local nodes = json.array({})
    for index, node in ipairs(graph.nodes) do
        nodes[index] = copy_fields(node, { "id", "bus", "identifier", "parent_id", "depth",
            "ambiguous", "resource", "resource_id", "kind", "membership_complete",
            "memory_device_id", "edac_module_id", "match_method",
            "pf_id", "sriov_membership_complete",
            "iommu_group_id", "iommu_group_membership_confirmed" })
        nodes[index].sensor_ids = json.array(node.sensor_ids)
        if node.temperature then
            nodes[index].temperature = copy_fields(node.temperature,
                { "scope", "owner_id", "sensor_id", "channel_id", "celsius" })
        end
        nodes[index].gpu_ids = json.array(node.gpu_ids)
        nodes[index].mount_ids = json.array(node.mount_ids)
        nodes[index].cpu_ids = json.array(node.cpu_ids)
        nodes[index].thermal_throttle_cpu_ids = json.array(node.thermal_throttle_cpu_ids)
        nodes[index].cpuidle_cpu_ids = json.array(node.cpuidle_cpu_ids)
        nodes[index].cooling_ids = json.array(node.cooling_ids)
        nodes[index].thermal_zone_ids = json.array(node.thermal_zone_ids)
        nodes[index].numa_node_ids = json.array(node.numa_node_ids)
        nodes[index].cpufreq_ids = json.array(node.cpufreq_ids)
        nodes[index].pci_ids = json.array(node.pci_ids)
        nodes[index].vf_ids = json.array(node.vf_ids)
        nodes[index].iommu_peer_ids = json.array(node.iommu_peer_ids)
        nodes[index].slot_ids = json.array(node.slot_ids)
        nodes[index].onboard_ids = json.array(node.onboard_ids)
        nodes[index].redundant_peer_ids = json.array(node.redundant_peer_ids)
        nodes[index].slave_ids = json.array(node.slave_ids)
        nodes[index].holder_ids = json.array(node.holder_ids)
        nodes[index].cache_ids = json.array(node.cache_ids)
        nodes[index].firmware_socket_ids = json.array(node.firmware_socket_ids)
        for _, key in ipairs({ "chassis_ids", "baseboard_ids", "contained_ids" }) do
            if #node[key] > 0 then nodes[index][key] = json.array(node[key]) end
        end
        if #node.associated_ids > 0 then
            nodes[index].associated_ids = json.array(node.associated_ids)
        end
        if #node.firmware_component_ids > 0 then
            nodes[index].firmware_component_ids = json.array(node.firmware_component_ids)
        end
        if #node.esrt_ids > 0 then
            nodes[index].esrt_ids = json.array(node.esrt_ids)
        end
        nodes[index].mapped_range_ids = json.array(node.mapped_range_ids)
        nodes[index].channel_ids = json.array(node.channel_ids)
        nodes[index].memory_device_ids = json.array(node.memory_device_ids)
    end
    return json.object({
        pci = json.object({
            devices = pci_devices,
            iommu_groups = iommu_groups,
            total = pci.total, truncated = pci.truncated,
        }),
        usb = json.object({
            devices = devices(usb.devices, {
                "id", "bus", "device", "vendor_id", "product_id",
                "manufacturer", "product",
                "parent_id", "parent_bus", "source", "driver", "speed_mbps",
            }, 128),
            interfaces = devices(usb.interfaces, {
                "id", "interface_number", "alternate_setting", "endpoint_count",
                "class_id", "subclass_id", "protocol_id", "interface",
                "parent_id", "source", "driver",
            }, 256),
            total = usb.total, interface_total = usb.interface_total,
            truncated = usb.truncated, interfaces_truncated = usb.interfaces_truncated,
        }),
        topology = json.object({ schema_version = 1, nodes = nodes,
            truncated = graph.truncated, partial = graph.partial }),
    })
end

function M.snapshot(snapshot, options)
    if type(snapshot) ~= "table" then snapshot = {} end
    if type(options) ~= "table" then options = {} end
    local uname = native.uname()
    local configuration = copy_fields(options.configuration, { "state", "reason" })
    return json.object({
        schema = "dev.waterrun.wtop.snapshot/v1",
        producer = json.object({ name = version.name, version = version.version }),
        host = copy_object(uname or { sysname = "Linux" }),
        sequence = snapshot.sequence,
        captured_monotonic_ns = snapshot.timestamp_ns,
        captured_unix_ns = native.realtime_ns(),
        configuration = configuration,
        privilege = M.privilege(options.privilege),
        quality = export_quality(snapshot.quality, snapshot.timestamp_ns),
        cpu = export_cpu(snapshot.cpu),
        cpu_info = export_cpu_info(snapshot.cpu_info),
        cpu_limits = export_performance_limits(snapshot.cpu_limits, nil, false,
            snapshot.quality and snapshot.quality.cpu_limits),
        cpu_clocks = export_cpu_clocks(snapshot.cpu_clocks,snapshot.quality and snapshot.quality.cpu_clocks),
        memory = export_memory(snapshot.memory),
        pressure = export_pressure(snapshot.pressure),
        disks = export_disks(snapshot.disks, snapshot),
        disk_health = export_disk_health(snapshot),
        network = export_network(snapshot.network),
        wifi = export_wifi(snapshot),
        connections = export_connections(snapshot.connections, options.connection_limit,
            options.include_remote_addresses == true),
        processes = export_processes(snapshot.processes, options.process_limit),
        gpus = export_gpus(snapshot.gpus, snapshot.quality and snapshot.quality.gpus, snapshot.timestamp_ns),
        cpu_frequency = export_cpu_frequency(snapshot.cpu_frequency),
        thermal_throttle = export_thermal_throttle(snapshot.thermal_throttle),
        cpuidle = export_cpuidle(snapshot.cpuidle),
        numa = export_numa(snapshot.numa),
        memory_devices = export_memory_devices(snapshot.memory_devices),
        expansion_slots = export_expansion_slots(snapshot.expansion_slots),
        port_connectors = export_port_connectors(snapshot.port_connectors),
        onboard_devices = export_onboard_devices(snapshot.onboard_devices),
        firmware_batteries = export_firmware_batteries(snapshot.firmware_batteries),
        firmware_enclosures = export_firmware_enclosures(snapshot.firmware_enclosures),
        platform_firmware = export_platform_firmware(snapshot.platform_firmware),
        firmware_power_supplies = export_firmware_power_supplies(snapshot.firmware_power_supplies),
        firmware_bmcs = export_firmware_bmcs(snapshot.firmware_bmcs),
        firmware_tpms = export_firmware_tpms(snapshot.firmware_tpms),
        firmware_components = export_firmware_components(snapshot.firmware_components),
        firmware_esrt = export_firmware_esrt(snapshot.firmware_esrt),
        tpm = export_tpm(snapshot.tpm),
        watchdog = export_watchdog(snapshot.watchdog),
        rfkill = export_rfkill(snapshot.rfkill),
        thermal_zones = export_thermal_zones(snapshot.thermal_zones),
        host_interfaces = export_host_interfaces(snapshot.host_interfaces),
        processor_firmware = export_processor_firmware(snapshot.processor_firmware),
        edac = export_edac(snapshot.edac),
        spd = export_spd(snapshot.spd),
        sensors = export_sensors(snapshot),
        power = export_power(snapshot.power, snapshot.quality and snapshot.quality.power, snapshot.timestamp_ns),
        mounts = export_mounts(snapshot.mounts),
        workloads = export_workloads(snapshot.workloads, options.workload_limit),
        system = export_system(snapshot.system),
        power_supplies = export_power_supplies(snapshot.power_supplies),
        inventory = export_inventory(snapshot),
        displays = export_displays(snapshot.displays, 128, snapshot.quality and snapshot.quality.displays),
    })
end

local severity_rank = { ok = 0, warning = 1, critical = 2 }

local function percentage(part, total)
    if not finite_number(part) or not finite_number(total) or total <= 0 then return nil end
    return math.max(0, math.min(100, part * 100 / total))
end

local function sum_field(values, field, nested)
    local total, found = 0, false
    for _, value in ipairs(values or {}) do
        local source = value.aggregate ~= false and (nested and value[nested] or value) or nil
        local number = source and source[field]
        if finite_number(number) then
            total, found = total + number, true
        end
    end
    return found and total or nil
end

local function top_by(values, limit, score)
    local candidates = {}
    for _, value in ipairs(values or {}) do
        if value.aggregate ~= false then candidates[#candidates + 1] = value end
    end
    table.sort(candidates, function(left, right)
        local left_score, right_score = score(left), score(right)
        if not finite_number(left_score) then left_score = -math.huge end
        if not finite_number(right_score) then right_score = -math.huge end
        if left_score == right_score then
            return tostring(left.id or left.name or "") < tostring(right.id or right.name or "")
        end
        return left_score > right_score
    end)
    local result = {}
    for index = 1, math.min(#candidates, limit) do result[index] = candidates[index] end
    return result
end

-- A token-conscious, deterministic context document for automation and LLM
-- agents. The full snapshot remains the source of truth; this projection keeps
-- only decision-relevant metrics, bounded top lists, quality and signals.
local GPU_CURRENT_METRICS = {power_watts="power",temperature_celsius="temperature",
    frequency_current_hz="frequency",memory_used_bytes="memory"}
local function gpu_score(device)
    local metrics=device.metrics or {}
    local utilization=metrics.utilization_percent
    if finite_number(utilization) and not Quality.UNUSABLE_FOR_ALERT[
        Quality.gpu_metric_quality(device,"utilization_percent","utilization")] then return utilization end
    for key,group in pairs(GPU_CURRENT_METRICS) do
        if finite_number(metrics[key]) and not Quality.UNUSABLE_FOR_ALERT[
            Quality.gpu_metric_quality(device,key,group)] then return -1 end
    end
    if device.identity_quality=="fresh" or device.identity_quality=="estimated" then return -2 end
    return -3
end

function M.agent(snapshot, options)
    if type(options) ~= "table" then options = {} end
    -- These maxima are part of agent-v1.schema.json, not merely defaults.
    local process_limit = bounded_limit(options.process_limit, 10, 10, 1)
    local device_limit = bounded_limit(options.device_limit, 5, 5, 1)
    local workload_limit = bounded_limit(options.workload_limit, 5, 5, 1)
    local full = M.snapshot(snapshot, {
        process_limit = process_limit,
        connection_limit = 0,
        workload_limit = workload_limit,
        configuration = options.configuration,
        privilege = options.privilege,
    })
    local frequency_total, frequency_weight, frequency_source = 0, 0, nil
    local frequency_estimated, frequency_incomplete = false, false
    if Quality.current_source(full.quality, "cpu_frequency") then
        local policies = full.cpu_frequency and full.cpu_frequency.policies or {}
        frequency_incomplete = full.cpu_frequency and full.cpu_frequency.truncated == true or false
        for _, policy in ipairs(policies) do
            local reading = policy.frequencies or {}
            if finite_number(reading.current_hz) and reading.current_hz > 0 then
                local weight = math.max(1, #(policy.affected_cpus or {}))
                frequency_total = frequency_total + reading.current_hz * weight
                frequency_weight = frequency_weight + weight
                if reading.current_quality == "estimated" then
                    frequency_estimated = true
                elseif reading.current_quality ~= "measured" then
                    frequency_incomplete = true
                end
                local source = reading.current_source
                if type(source) ~= "string" or source == "" then
                    source = "unknown"
                    frequency_incomplete = true
                end
                if frequency_source == nil then
                    frequency_source = source
                elseif frequency_source ~= source then
                    frequency_source = "mixed"
                end
            else
                frequency_incomplete = true
            end
        end
    end
    local frequency_metric = json.object({})
    if frequency_weight > 0 then
        frequency_metric.average_hz = frequency_total / frequency_weight
        frequency_metric.source = frequency_source
        frequency_metric.quality = frequency_incomplete and "partial"
            or frequency_estimated and "estimated" or "measured"
    end
    local thermal_core_max, thermal_package_max
    local thermal_quality = full.quality and full.quality.thermal_throttle
    if thermal_quality and thermal_quality.status == "ok" then
        for _, cpu in ipairs(full.thermal_throttle.cpus or {}) do
            if cpu.core_delta_quality == "fresh" then
                thermal_core_max = math.max(thermal_core_max or 0, cpu.core_new)
            end
            if cpu.package_delta_quality == "fresh" then
                thermal_package_max = math.max(thermal_package_max or 0, cpu.package_new)
            end
        end
    end

    local signals = json.array({})
    local highest = "ok"
    local function add_signal(resource, code, severity, value, unit, message)
        signals[#signals + 1] = json.object({
            resource = resource,
            code = code,
            severity = severity,
            value = value,
            unit = unit,
            message = message,
        })
        if severity_rank[severity] > severity_rank[highest] then highest = severity end
    end
    for _, signal in ipairs(NVMeWarnings.summary(snapshot).signals) do
        add_signal(signal.resource, signal.code, signal.severity, nil, nil, signal.message)
    end
    -- A failed collector leaves its last usable numbers in the snapshot for
    -- context.  Those numbers must not create a new current-condition alarm.
    -- A missing quality record is tolerated for direct, partial projections;
    -- an explicit failed or stale record is never treated as current evidence.
    local function current_source(source)
        return Quality.current_source(full.quality, source)
    end
    local function threshold(resource, code, value, warning, critical, unit, message, source)
        if not current_source(source or resource) then return end
        if not finite_number(value) then return end
        if value >= critical then
            add_signal(resource, code, "critical", value, unit, message)
        elseif value >= warning then
            add_signal(resource, code, "warning", value, unit, message)
        end
    end

    local cpu_total = full.cpu and full.cpu.total or {}
    local cpu_load = full.cpu and full.cpu.load or {}
    local cpu_identity = full.cpu_info and full.cpu_info.identity or {}
    local cpu_topology = full.cpu_info and full.cpu_info.topology or {}
    local logical_cpus = cpu_topology.threads or #(full.cpu and full.cpu.cores or {})
    local cpuid_core_types=json.array({})
    local cpuid_types=full.cpu_info and full.cpu_info.cpuid and full.cpu_info.cpuid.core_types or{}
    for index=1,math.min(#cpuid_types,device_limit)do
        cpuid_core_types[index]=copy_fields(cpuid_types[index],{"id","core_type","native_model_id","source","model_name","vendor","core_type_class","quality","logical_cpu_count","physical_core_count","efficiency_ranking_minimum","efficiency_ranking_maximum","efficiency_ranking_cpu_count"})
    end
    local cpu_core_types = json.array({})
    for index = 1, math.min(#(full.cpu_info and full.cpu_info.core_types or {}), device_limit) do
        cpu_core_types[index] = copy_fields(full.cpu_info.core_types[index], {
            "id", "model_name", "vendor", "family", "model", "stepping", "implementer",
            "architecture", "variant", "part", "cpu_capacity", "kernel_core_type",
            "threads_per_core", "maximum_frequency_hz", "physical_core_count",
            "logical_cpu_count",
        })
    end
    threshold("cpu", "high_utilization", cpu_total.utilization, 75, 90, "percent",
        "CPU utilization is elevated")
    threshold("cpu", "high_iowait", cpu_total.iowait, 10, 20, "percent",
        "CPU time waiting for I/O is elevated")
    if logical_cpus > 0 and finite_number(cpu_load.one) then
        threshold("cpu", "high_load", cpu_load.one / logical_cpus, 1, 1.5, "load_per_cpu",
            "One-minute load exceeds logical CPU capacity")
    end

    local memory = full.memory or {}
    local memory_used_percent = percentage(memory.used_bytes, memory.total_bytes)
    local swap_used_percent = percentage(memory.swap_used_bytes, memory.swap_total_bytes)
    threshold("memory", "high_usage", memory_used_percent, 85, 95, "percent",
        "Memory usage is elevated")

    local pressure_metrics = json.object({})
    for _, resource in ipairs({ "cpu", "memory", "io" }) do
        local pressure = full.pressure and full.pressure[resource] or {}
        local some = pressure.some and pressure.some.avg10
        local complete = pressure.full and pressure.full.avg10
        pressure_metrics[resource] = json.object({ some_avg10 = some, full_avg10 = complete })
        threshold(resource, "sustained_pressure", some, 5, 20, "percent",
            resource .. " pressure stalls are elevated", "pressure")
        threshold(resource, "full_pressure", complete, 1, 5, "percent",
            resource .. " full stalls are elevated", "pressure")
    end

    local disk_devices = full.disks and full.disks.devices or {}
    local ranked_disks = top_by(disk_devices, device_limit, function(device)
        if finite_number(device.busy_percent) then return device.busy_percent end
        local read = finite_number(device.read_bytes_per_second) and device.read_bytes_per_second or 0
        local write = finite_number(device.write_bytes_per_second) and device.write_bytes_per_second or 0
        return read + write
    end)
    local top_disks = json.array({})
    local health_by_id = {}
    for _, health in ipairs(full.disk_health and full.disk_health.devices or {}) do
        if health_by_id[health.id] == nil then health_by_id[health.id] = health
        else health_by_id[health.id] = false end
    end
    for index, device in ipairs(ranked_disks) do
        top_disks[index] = copy_fields(device, {
            "id", "name", "read_bytes_per_second", "write_bytes_per_second",
            "read_iops", "write_iops", "busy_percent", "busy_quality", "average_read_latency_ms",
            "average_write_latency_ms", "in_flight", "quality",
        })
        if device.temperature then top_disks[index].temperature = copy_object(device.temperature) end
        local health = health_by_id[device.id]
        if health and health.nvme then
            top_disks[index].nvme_health = copy_fields(health.nvme, {
                "critical_warning", "percentage_used", "percentage_used_lower_bound",
                "available_spare_percent", "available_spare_threshold_percent", "data_units_read",
                "data_units_written", "data_unit_bytes", "data_units_rounded_up", "media_errors",
                "error_log_entries", "unsafe_shutdowns", "power_on_hours", "source", "scope",
            })
            top_disks[index].nvme_health.quality = health.quality
            top_disks[index].nvme_health.observed_at_ns = health.observed_at_ns
        end
    end
    local busiest_current_disk
    for _, device in ipairs(disk_devices) do
        if finite_number(device.busy_percent)
            and device.busy_quality ~= "estimated"
            and not Quality.UNUSABLE_FOR_ALERT[device.busy_quality]
            and not Quality.UNUSABLE_FOR_ALERT[device.quality] then
            busiest_current_disk = math.max(busiest_current_disk or device.busy_percent,
                device.busy_percent)
        end
    end
    threshold("storage", "device_busy", busiest_current_disk, 80, 95, "percent",
        "A block device reports high busy time", "disks")
    local nvme_no_path_failure = false
    if current_source("disks") then
        for _, device in ipairs(disk_devices) do
            local nvme = type(device.nvme) == "table" and device.nvme or nil
            local counters = nvme and type(nvme.counters) == "table" and nvme.counters or nil
            local failure = counters and counters.io_failures_no_path
            if type(failure) == "table" and failure.status == "ok"
                and failure.delta_quality == "fresh"
                and finite_number(failure.new) and failure.new > 0 then
                nvme_no_path_failure = true
                break
            end
        end
    end
    if nvme_no_path_failure then
        add_signal("disks", "nvme_no_path_io_failure", "warning", nil, nil,
            "NVMe no-path I/O failure counter increased")
    end
    local md_degraded = false
    local active_md_states = { active = true, clean = true,
        ["active-idle"] = true, readonly = true, ["read-auto"] = true }
    if current_source("disks") then
        for _, device in ipairs(disk_devices) do
            local stack = type(device.stack) == "table" and device.stack or nil
            if stack and stack.kind == "md" and stack.status == "ok"
                and active_md_states[stack.array_state]
                and finite_number(stack.raid_disks) and stack.raid_disks > 0
                and finite_number(stack.degraded) and stack.degraded > 0
                and stack.degraded <= stack.raid_disks then
                md_degraded = true
                break
            end
        end
    end
    if md_degraded then
        add_signal("disks", "md_array_degraded", "warning", nil, nil,
            "An active MD array reports missing devices")
    end

    local interfaces = full.network and full.network.interfaces or {}
    local ranked_interfaces = top_by(interfaces, device_limit, function(interface)
        local rates = interface.rates or {}
        local receive = finite_number(rates.rx_bytes_per_second) and rates.rx_bytes_per_second or 0
        local transmit = finite_number(rates.tx_bytes_per_second) and rates.tx_bytes_per_second or 0
        return receive + transmit
    end)
    local top_interfaces = json.array({})
    for index, interface in ipairs(ranked_interfaces) do
        local exported = copy_fields(interface, {
            "id", "name", "operstate", "speed_mbps", "carrier", "quality",
            "counter_bits", "counter_source", "counter_quality",
        })
        exported.rates = copy_fields(interface.rates, {
            "rx_bytes_per_second", "tx_bytes_per_second", "rx_packets_per_second",
            "tx_packets_per_second", "rx_errors_per_second", "tx_errors_per_second",
            "rx_dropped_per_second", "tx_dropped_per_second",
        })
        if type(interface.link_events) == "table" then
            exported.link_changes_total = interface.link_events.changes_total
            local change = interface.link_events.change
            if type(change) == "table" and change.quality == "fresh" then
                exported.new_link_changes = change.new_changes
            end
        end
        top_interfaces[index] = exported
    end

    local top_wifi = json.array({})
    for index, device in ipairs(full.wifi and full.wifi.devices or {}) do
        if index > device_limit then break end
        top_wifi[index] = device
    end

    local graphics_domains = json.array({})
    for index, domain in ipairs(full.power and full.power.graphics_domains or {}) do
        if index > device_limit then break end
        graphics_domains[index] = domain
    end

    local top_processes = json.array({})
    for index, process in ipairs(full.processes and full.processes.top or {}) do
        top_processes[index] = copy_fields(process, {
            "id", "pid", "name", "state", "user", "cpu_percent",
            "cpu_time_seconds", "elapsed_seconds", "resident_bytes", "threads",
            "io_read_bytes", "io_write_bytes",
            "quality", "partial",
        })
    end

    local power_zones = full.power and full.power.zones or {}
    local power_zone_summaries = json.array({})
    for index = 1, math.min(#power_zones, device_limit) do
        local zone = power_zones[index]
        local summary = copy_fields(zone, { "id", "name", "source_kind", "parent_id",
            "enabled", "control_enabled", "controls_enabled", "power_watts", "power_quality",
            "power_interval_ns", "aggregate", "aggregate_domain" })
        if zone.power_session then summary.power_session = copy_object(zone.power_session) end
        summary.constraints = json.array({})
        local constraints = zone.constraints or {}
        for constraint_index = 1, math.min(#constraints, 8) do
            summary.constraints[constraint_index] = copy_fields(constraints[constraint_index], {
                "id", "name", "power_limit_watts", "time_window_seconds", "usage_percent", "headroom_watts",
            })
        end
        summary.constraints_total = #constraints
        summary.constraints_truncated = #constraints > 8
        power_zone_summaries[index] = summary
    end

    local gpu_devices = full.gpus and full.gpus.devices or {}
    local gpu_summaries = json.array({})
    local maximum_gpu_utilization
    local maximum_current_gpu_utilization
    for _, device in ipairs(gpu_devices) do
        local utilization = device.metrics and device.metrics.utilization_percent
        if finite_number(utilization) then
            local quality = Quality.gpu_metric_quality(device, "utilization_percent", "utilization")
            if not Quality.UNUSABLE_FOR_ALERT[quality] then
                maximum_current_gpu_utilization = math.max(
                    maximum_current_gpu_utilization or utilization, utilization)
            end
        end
    end
    if current_source("gpus") then maximum_gpu_utilization = maximum_current_gpu_utilization end
    local ranked_gpus = top_by(gpu_devices, device_limit, gpu_score)
    for index, device in ipairs(ranked_gpus) do
        local output = copy_fields(device, {
            "id", "card", "vendor", "vendor_name", "model_name", "driver", "quality", "partial", "identity_quality",
        })
        output.pci = copy_fields(device.pci, {
            "class_id", "class_name", "revision", "subsystem_vendor_id", "subsystem_device_id",
            "subsystem_vendor_name", "subsystem_model_name",
            "boot_vga", "numa_node", "current_link_speed", "current_link_width",
            "maximum_link_speed", "maximum_link_width", "runtime_status",
        })
        output.metrics = copy_fields(device.metrics, {
            "utilization_percent", "utilization_source",
            "memory_used_bytes", "memory_total_bytes", "process_memory_bytes",
            -- `frequency_domain` travels with the scalar it qualifies: a card
            -- that publishes a graphics clock and a memory clock reports two
            -- different quantities, and a summary carrying one of them
            -- unnamed reads as "the" frequency of the device.
            "frequency_current_hz", "frequency_domain", "frequency_source_kind",
            "temperature_celsius", "hotspot_temperature_celsius", "graphics_voltage_volts", "power_watts", "power_source", "power_scope", "power_measurement", "power_limit_watts", "power_limit_source",
            "power_limit_percent", "power_headroom_watts", "power_instant_watts", "power_average_watts",
            "power_interval_ns", "power_average_interval_ns", "power_instant_timestamp_us", "power_average_timestamp_us",
            "power_instant_quality", "power_average_quality",
        })
        output.performance_limits = export_performance_limits(device.performance_limits, device_limit, true)
        output.observations = export_gpu_observations(device.observations)
        output.metric_observations = export_gpu_observations(device.metric_observations)
        output.power_sessions = json.array(GPUPowerSession.public(device, snapshot.timestamp_ns, snapshot.quality and snapshot.quality.gpus))
        output.adl = copy_object(device.adl)
        -- The full clock set, in the same shape the snapshot uses.  This
        -- summary is what an agent or an insight reads, and it is also the
        -- only view that survives into whatever consumes it, so dropping the
        -- domains here would drop them for good: the count is what says a
        -- device has more than one clock, and the truncation flag is what
        -- says the list is not all of them.
        output.frequencies = export_gpu_frequencies(device.frequencies)
        gpu_summaries[index] = output
    end
    threshold("gpu", "high_utilization", maximum_current_gpu_utilization,
        85, 97, "percent",
        "GPU utilization is elevated", "gpus")

    local temperature_count, fan_count, sensor_power_count = 0, 0, 0
    local energy_power, energy_power_count = json.array({}), 0
    local hwmon_power, hwmon_power_count = json.array({}), 0
    local top_temperatures = json.array({})
    local threshold_temperature, closest_critical
    for _, device in ipairs(full.sensors and full.sensors.devices or {}) do
        for _, channel in ipairs(device.channels or {}) do
            if channel.type == "energy" and channel.power then
                energy_power_count = energy_power_count + 1
                if #energy_power < device_limit then
                    local power = copy_object(channel.power)
                    power.device_id, power.channel_id = device.id, channel.id
                    power.device, power.label = device.name, channel.label
                    energy_power[#energy_power + 1] = power
                end
            elseif channel.type == "power" and channel.power then
                hwmon_power_count = hwmon_power_count + 1
                if #hwmon_power < device_limit then
                    local power = copy_object(channel.power)
                    power.device_id, power.channel_id = device.id, channel.id
                    power.device, power.label = device.name, channel.label
                    hwmon_power[#hwmon_power + 1] = power
                end
            end
            if channel.type == "temperature" and finite_number(channel.input) then
                temperature_count = temperature_count + 1
                local temperature = json.object({
                    device_id = device.id,
                    device = device.name,
                    channel_id = channel.id,
                    label = channel.label,
                    temperature_celsius = channel.input,
                    quality = channel.quality,
                    thresholds = copy_fields(channel.thresholds, { "max", "crit", "emergency" }),
                    critical_celsius = channel.critical_celsius,
                    headroom_celsius = channel.headroom_celsius,
                })
                top_temperatures[#top_temperatures + 1] = temperature
                if finite_number(temperature.headroom_celsius) and (not closest_critical
                    or temperature.headroom_celsius < closest_critical.headroom_celsius) then
                    closest_critical = temperature
                end
                local critical = temperature.thresholds and (temperature.thresholds.crit
                    or temperature.thresholds.emergency)
                local warning = temperature.thresholds and temperature.thresholds.max
                local severity
                if finite_number(critical) and temperature.temperature_celsius >= critical then
                    severity = "critical"
                elseif finite_number(warning) and temperature.temperature_celsius >= warning then
                    severity = "warning"
                end
                if severity and Thermal.input_current(snapshot, device, channel)
                    and (not threshold_temperature
                    or severity_rank[severity] > severity_rank[threshold_temperature.severity]
                    or (severity == threshold_temperature.severity
                        and temperature.temperature_celsius
                            > threshold_temperature.temperature_celsius))
                then
                    threshold_temperature = {
                        severity = severity,
                        temperature_celsius = temperature.temperature_celsius,
                    }
                end
                table.sort(top_temperatures, function(left, right)
                    if left.temperature_celsius == right.temperature_celsius then
                        return tostring(left.device_id or "") .. tostring(left.channel_id or "")
                            < tostring(right.device_id or "") .. tostring(right.channel_id or "")
                    end
                    return left.temperature_celsius > right.temperature_celsius
                end)
                if #top_temperatures > device_limit then top_temperatures[#top_temperatures] = nil end
            elseif channel.type == "fan" and finite_number(channel.input) then
                fan_count = fan_count + 1
            elseif channel.type == "power" and finite_number(channel.input) then
                sensor_power_count = sensor_power_count + 1
            end
        end
    end
    local hottest = top_temperatures[1]
    if threshold_temperature and current_source("sensors") then
        local critical = threshold_temperature.severity == "critical"
        add_signal("sensors", "temperature_threshold", threshold_temperature.severity,
            threshold_temperature.temperature_celsius, "celsius",
            critical and "A temperature sensor reached its critical threshold"
                or "A temperature sensor exceeded its maximum threshold")
    end

    -- AER device and root-port counters can observe the same PCIe event, so
    -- their changes are evidence of a report, not additive event totals.  One
    -- signal per severity is enough to direct an operator to the reporting
    -- links; the detailed counters remain in the full snapshot.  A retained
    -- inventory or a first/reset sample cannot create a new-event signal.
    local aer_fatal, aer_nonfatal = false, false
    local function increased(change)
        return type(change) == "table" and change.quality == "fresh"
            and finite_number(change.new_reports) and change.new_reports > 0
    end
    if current_source("inventory") then
        for _, device in ipairs(full.inventory and full.inventory.pci
                and full.inventory.pci.devices or {}) do
            local aer = type(device.aer) == "table" and device.aer or nil
            if aer then
                local root_changes = aer.rootport and aer.rootport.changes
                aer_fatal = aer_fatal
                    or increased(aer.fatal and aer.fatal.change)
                    or increased(root_changes and root_changes.fatal)
                aer_nonfatal = aer_nonfatal
                    or increased(aer.nonfatal and aer.nonfatal.change)
                    or increased(root_changes and root_changes.nonfatal)
            end
        end
    end
    if aer_fatal then
        add_signal("inventory", "pcie_aer_fatal", "critical", nil, nil,
            "New fatal PCIe AER reports were observed; the reporting link may not be the failing endpoint")
    end
    if aer_nonfatal then
        add_signal("inventory", "pcie_aer_nonfatal", "warning", nil, nil,
            "New nonfatal PCIe AER reports were observed; inspect the reporting links")
    end

    local top_workloads = json.array({})
    for index, workload in ipairs(full.workloads and full.workloads.items or {}) do
        top_workloads[index] = copy_fields(workload, {
            "id", "name", "depth", "quality", "partial", "cgroup_type",
        })
        top_workloads[index].cpu = copy_fields(workload.cpu, { "utilization_percent" })
        top_workloads[index].memory = copy_fields(workload.memory, { "current_bytes", "max_bytes" })
        top_workloads[index].processes = copy_fields(workload.processes,
            { "count", "visible_count", "hidden_entries", "status" })
        if workload.threads then
            top_workloads[index].threads = copy_fields(workload.threads,
                { "count", "visible_count", "hidden_entries", "status" })
        end
    end

    local data_quality = json.array({})
    local quality_keys = {}
    -- An absent optional hardware provider is not a failing host.  Keep its
    -- exact status in data_quality/unavailable_sources; reserve critical
    -- source alarms for the measurements a top-like monitor needs to work.
    for resource in pairs(full.quality or {}) do quality_keys[#quality_keys + 1] = resource end
    table.sort(quality_keys)
    for _, resource in ipairs(quality_keys) do
        local quality = full.quality[resource]
        data_quality[#data_quality + 1] = copy_fields(quality, {
            "status", "quality", "reason", "value_timestamp_ns", "value_age_ms",
        })
        data_quality[#data_quality].resource = resource
        local status = quality and quality.status
        local freshness = quality and quality.quality
        local failure_severity = Quality.SOURCE_FAILURE_SEVERITY[resource]
        if status and status ~= "ok" then
            if failure_severity then
                add_signal(resource, "data_unavailable", failure_severity, nil, nil,
                    "A monitoring source could not be read")
            end
        elseif freshness == "stale" and failure_severity then
            add_signal(resource, "data_stale", "warning", nil, nil,
                "A monitoring source is showing a retained value")
        elseif failure_severity == "critical" and (freshness == "gap"
                or freshness == "reset") then
            add_signal(resource, "data_gap", "warning", nil, nil,
                "A core monitoring rate could not be calculated")
        elseif failure_severity == "critical" and (freshness == "partial"
                or freshness == "truncated" or freshness == "error"
                or freshness == "denied" or freshness == "unavailable") then
            add_signal(resource, "data_incomplete", "warning", nil, nil,
                "Part of a core monitoring source is unavailable")
        end
    end

    local unavailable_sources = json.array({})
    local capabilities = M.capabilities(options.capabilities)
    local capability_keys = {}
    for id in pairs(capabilities) do capability_keys[#capability_keys + 1] = id end
    table.sort(capability_keys)
    for _, id in ipairs(capability_keys) do
        local capability = capabilities[id]
        if capability.available ~= true then
            unavailable_sources[#unavailable_sources + 1] = json.object({
                id = id, state = capability.state, reason = capability.reason,
            })
        end
    end

    table.sort(signals, function(left, right)
        local left_rank, right_rank = severity_rank[left.severity], severity_rank[right.severity]
        if left_rank ~= right_rank then return left_rank > right_rank end
        if left.resource ~= right.resource then return left.resource < right.resource end
        return left.code < right.code
    end)

    local observed = 0
    for _, value in ipairs({cpu_total.utilization, memory_used_percent}) do
        if finite_number(value) then observed = observed + 1 end
    end
    local state = (#signals == 0 and observed == 0) and "unknown" or highest
    return json.object({
        schema = "dev.waterrun.wtop.agent/v1",
        producer = full.producer,
        host = full.host,
        sequence = full.sequence,
        captured_unix_ns = full.captured_unix_ns,
        captured_monotonic_ns = full.captured_monotonic_ns,
        privilege = full.privilege,
        overall = json.object({ state = state, signal_count = #signals }),
        metrics = json.object({
            cpu = json.object({
                utilization_percent = cpu_total.utilization,
                user_percent = cpu_total.user,
                system_percent = cpu_total.system,
                iowait_percent = cpu_total.iowait,
                logical_cpus = logical_cpus,
                load_1 = cpu_load.one,
                load_5 = cpu_load.five,
                load_15 = cpu_load.fifteen,
                running_processes = full.cpu and full.cpu.processes_running,
                blocked_processes = full.cpu and full.cpu.processes_blocked,
                model_name = cpu_identity.model_name,
                vendor = cpu_identity.vendor,
                heterogeneous = cpu_identity.heterogeneous,
                core_type_count = cpu_identity.core_type_count,
                core_types = cpu_core_types,
                physical_cores = cpu_topology.physical_cores,
                sockets = cpu_topology.sockets,
                compute_units = cpu_topology.compute_units,
                cpuid = full.cpu_info and full.cpu_info.cpuid and json.object({
                    status = full.cpu_info.cpuid.status, quality = full.cpu_info.cpuid.quality,
                    reason = full.cpu_info.cpuid.reason, source = full.cpu_info.cpuid.source,
                    architecture_bits = full.cpu_info.cpuid.architecture_bits,
                    scope = full.cpu_info.cpuid.scope, platform=full.cpu_info.cpuid.platform, truncated=full.cpu_info.cpuid.truncated,
                    core_types=cpuid_core_types, core_type_count=#cpuid_types, core_types_truncated=#cpuid_types>#cpuid_core_types,
                    os_comparison=full.cpu_info.cpuid.os_comparison,
                    cache_summary=full.cpu_info.cpuid.cache_summary,
                    roster_complete = full.cpu_info.cpuid.roster_complete,
                    topology = full.cpu_info.cpuid.topology, features = full.cpu_info.cpuid.features,
                    caches_complete = full.cpu_info.cpuid.caches_complete,
                }) or nil,
                power_watts = full.power and full.power.total_power_watts,
                frequency = frequency_metric,
                effective_clocks = export_cpu_clocks(full.cpu_clocks,
                    full.quality and full.quality.cpu_clocks,device_limit),
                thermal_throttle = json.object({
                    maximum_core_new_events_per_cpu = thermal_core_max,
                    maximum_package_new_events_per_cpu = thermal_package_max,
                }),
            }),
            memory = json.object({
                used_bytes = memory.used_bytes,
                available_bytes = memory.available_bytes,
                total_bytes = memory.total_bytes,
                used_percent = memory_used_percent,
                swap_used_bytes = memory.swap_used_bytes,
                swap_total_bytes = memory.swap_total_bytes,
                swap_used_percent = swap_used_percent,
            }),
            pressure = pressure_metrics,
            storage = json.object({
                read_bytes_per_second = sum_field(disk_devices, "read_bytes_per_second"),
                write_bytes_per_second = sum_field(disk_devices, "write_bytes_per_second"),
                device_count = #disk_devices,
            }),
            network = json.object({
                wifi_interfaces_total = #(full.wifi and full.wifi.devices or {}),
                wifi_truncated = (full.wifi and full.wifi.truncated == true)
                    or #(full.wifi and full.wifi.devices or {}) > #top_wifi,
                receive_bytes_per_second = sum_field(interfaces, "rx_bytes_per_second", "rates"),
                transmit_bytes_per_second = sum_field(interfaces, "tx_bytes_per_second", "rates"),
                interface_count = #interfaces,
                softnet_status = full.network and full.network.softnet
                    and full.network.softnet.status,
                softnet_quality = full.network and full.network.softnet
                    and full.network.softnet.quality,
                softnet_backlog_packets = full.network and full.network.softnet
                    and full.network.softnet.backlog_packets,
                softnet_dropped_per_second = full.network and full.network.softnet
                    and full.network.softnet.dropped_per_second,
                softnet_budget_squeezes_per_second = full.network and full.network.softnet
                    and full.network.softnet.time_squeeze_per_second,
            }),
            gpu = json.object({
                device_count = #gpu_devices,
                maximum_utilization_percent = maximum_gpu_utilization,
                providers = export_gpu_providers(full.gpus and full.gpus.providers),
            }),
            power = json.object({
                graphics_domains = graphics_domains,
                graphics_domains_truncated = (full.power and full.power.graphics_domains_truncated == true)
                    or #(full.power and full.power.graphics_domains or {}) > #graphics_domains,
                total_watts = full.power and full.power.total_power_watts,
                measured_aggregate_zones = full.power and full.power.measured_aggregate_zones,
                aggregate_zone_count = full.power and full.power.aggregate_zone_count,
                aggregate_complete = full.power and full.power.aggregate_complete,
                aggregate_strategy = full.power and full.power.aggregate_strategy,
                aggregate_source_kind = full.power and full.power.aggregate_source_kind,
                platform_watts = full.power and full.power.platform_power_watts,
                measured_platform_zones = full.power and full.power.measured_platform_zones,
                platform_aggregate_strategy = full.power and full.power.platform_aggregate_strategy,
                platform_aggregate_source_kind = full.power and full.power.platform_aggregate_source_kind,
                denied_zones = full.power and full.power.denied_zones,
                zones = power_zone_summaries,
                zones_total = #power_zones,
                zones_truncated = #power_zones > #power_zone_summaries,
                cpu_limits = export_performance_limits(full.cpu_limits, device_limit, true),
            }),
            sensors = json.object({
                temperature_count = temperature_count,
                fan_count = fan_count,
                power_count = sensor_power_count,
                energy_power = energy_power,
                energy_power_total = energy_power_count,
                energy_power_truncated = energy_power_count > #energy_power,
                hwmon_power = hwmon_power,
                hwmon_power_total = hwmon_power_count,
                hwmon_power_truncated = hwmon_power_count > #hwmon_power,
                maximum_temperature_celsius = hottest and hottest.temperature_celsius,
                minimum_headroom_celsius = closest_critical and closest_critical.headroom_celsius,
                closest_to_critical = closest_critical,
            }),
            firmware_enclosures = export_firmware_enclosures(full.firmware_enclosures, device_limit),
            platform_firmware = export_platform_firmware(full.platform_firmware, device_limit),
            displays = export_displays(full.displays, device_limit, snapshot.quality and snapshot.quality.displays),
            processes = json.object({ total = full.processes and full.processes.total }),
        }),
        signals = signals,
        top = json.object({
            processes = top_processes,
            disks = top_disks,
            interfaces = top_interfaces,
            wifi = top_wifi,
            workloads = top_workloads,
            gpus = gpu_summaries,
            sensors = top_temperatures,
        }),
        data_quality = data_quality,
        unavailable_sources = unavailable_sources,
        privacy = json.object({
            remote_addresses = "omitted",
            process_commands = "omitted",
        }),
    })
end

return M
