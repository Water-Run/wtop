local native = require("wtop.native")
local version = require("wtop.version")
local json = require("wtop.format.json")

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
    "name", "utilization", "user", "nice", "system", "iowait", "irq", "steal", "quality",
}

local function export_cpu(cpu)
    local result = copy_fields(cpu, {
        "context_switches", "interrupts", "processes_created",
        "processes_running", "processes_blocked", "boot_time_seconds",
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
            "field", "status", "reason", "source", "errno",
        })
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
        "core_type_count", "heterogeneous",
    })
    result.identity.flags = copy_array(cpu_info and cpu_info.identity and cpu_info.identity.flags)
    local topology = cpu_info and cpu_info.topology or {}
    result.topology = copy_fields(topology, {
        "sockets", "physical_cores", "threads", "online_threads",
        "threads_per_core_minimum", "threads_per_core_maximum", "quality", "truncated",
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
            "cpu_capacity", "kernel_core_type", "maximum_frequency_hz", "threads_in_core",
            "core_type_id", "source",
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
            "logical_cpu_count",
        })
        output.logical_cpu_ids = copy_array(core_type.logical_cpu_ids)
        result.core_types[index] = output
    end
    result.caches = json.array({})
    for index, cache in ipairs(cpu_info and cpu_info.caches or {}) do
        local output = copy_fields(cache, {
            "id", "cache_id", "level", "type", "size", "size_bytes", "shared_cpu_list_text",
            "coherency_line_size_bytes", "ways_of_associativity", "number_of_sets",
            "physical_line_partition", "source",
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
    return result
end

local function export_power(power)
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
    })
    for index, zone in ipairs(power and power.zones or {}) do
        local output = copy_fields(zone, {
            "id", "name", "source_kind", "parent_id", "enabled", "energy_joules",
            "maximum_energy_range_joules", "observed_at_ns", "power_watts",
            "power_source", "power_quality", "quality", "truncated", "aggregate", "source",
            "platform_aggregate", "aggregate_domain",
        })
        output.constraints = json.array({})
        for constraint_index, constraint in ipairs(zone.constraints or {}) do
            output.constraints[constraint_index] = copy_fields(constraint, {
                "id", "name", "power_limit_watts", "maximum_power_watts",
                "minimum_power_watts", "time_window_seconds", "maximum_time_window_seconds",
                "minimum_time_window_seconds", "source",
            })
        end
        output.issues = export_issues(zone.issues)
        result.zones[index] = output
    end
    result.issues = export_issues(power and power.issues)
    return result
end

local function export_memory(memory)
    local result = copy_fields(memory, {
        "total_bytes", "available_bytes", "used_bytes", "free_bytes",
        "buffers_bytes", "cache_bytes", "anonymous_bytes", "slab_bytes",
        "reclaimable_slab_bytes", "unreclaimable_slab_bytes", "dirty_bytes",
        "writeback_bytes", "swap_total_bytes", "swap_free_bytes", "swap_used_bytes",
        "zswap_bytes", "zswapped_bytes", "available_estimated",
    })
    if memory and memory.vmstat then result.vmstat = copy_object(memory.vmstat) end
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

local function export_disks(disks)
    local result = json.object({ devices = json.array({}) })
    for index, device in ipairs(disks and disks.devices or {}) do
        result.devices[index] = copy_fields(device, {
            "id", "name", "major", "minor", "accounting_sector_size_bytes",
            "stable_id", "diskseq", "identity_quality", "partition", "is_partition",
            "stacked", "slaves", "aggregate",
            "logical_sector_size_bytes", "physical_sector_size_bytes",
            "in_flight", "read_bytes_per_second", "write_bytes_per_second",
            "read_iops", "write_iops", "busy_percent", "average_read_latency_ms",
            "average_write_latency_ms", "average_queue_size", "discard_bytes_per_second",
            "discard_iops", "average_discard_latency_ms", "flush_iops",
            "average_flush_latency_ms", "quality", "reset_reason",
        })
    end
    return result
end

local function export_network(network)
    local result = json.object({ interfaces = json.array({}) })
    for index, interface in ipairs(network and network.interfaces or {}) do
        local exported = copy_fields(interface, {
            "id", "ifindex", "name", "operstate", "mtu", "speed_mbps",
            "iflink", "link_type", "carrier", "duplex", "address",
            "default_route", "aggregate", "quality", "reset_counter",
        })
        exported.rates = copy_object(interface.rates)
        result.interfaces[index] = exported
    end
    return result
end

local function mask_remote_address(address)
    if type(address) ~= "string" then return address end
    local prefix = address:match("^(%d+%.%d+%.%d+%.)%d+$")
    if prefix then return prefix .. "x" end
    if address:find(":", 1, true) then
        local groups = {}
        for group in address:gmatch("[^:]+") do groups[#groups + 1] = group end
        if #groups > 2 then return table.concat({ groups[1], groups[2], "…" }, ":") end
        return address == "::" and address or "…"
    end
    return address
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
            exported.owners[owner_index] = copy_fields(owner, { "pid", "fd", "name" })
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
        "process_limit", "truncated", "partial",
    })
    result.total = #(processes and processes.list or {})
    result.top = json.array({})
    for index = 1, math.min(#candidates, bounded_limit(limit, 50, 2048, 0)) do
        result.top[index] = copy_fields(candidates[index], {
            "id", "pid", "name", "command", "state", "parent_pid", "threads",
            "uid", "user", "priority", "nice", "processor", "cpu_percent",
            "resident_bytes", "virtual_bytes", "quality", "partial", "partial_reason",
        })
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
            "source_kind", "source",
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
        output.memory_summary = copy_object(client.memory_summary)
        result.clients[index] = output
    end
    result.list = json.array({})
    for index, process in ipairs(processes and processes.list or {}) do
        local output = copy_fields(process, {
            "id", "pid", "starttime_ticks", "name", "uid", "quality", "utilization_percent",
        })
        output.engines = export_gpu_engines(process.engines)
        output.memory_summary = copy_object(process.memory_summary)
        output.clients = json.array({})
        for client_index, client in ipairs(process.clients or {}) do
            local exported_client = copy_fields(client, {
                "id", "client_id", "name", "driver", "pci_bdf", "mapping_quality",
                "fd_count", "observed_at_ns", "quality",
            })
            exported_client.engines = export_gpu_engines(client.engines)
            exported_client.memory_summary = copy_object(client.memory_summary)
            output.clients[client_index] = exported_client
        end
        result.list[index] = output
    end
    return result
end

local function export_gpus(gpus)
    local result = json.object({
        schema = gpus and gpus.schema,
        truncated = gpus and gpus.truncated == true or false,
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
    for index, device in ipairs(gpus and gpus.devices or {}) do
        local exported = copy_fields(device, {
            "id", "card", "pci_bdf", "vendor_id", "device_id", "vendor", "driver",
            "vendor_name", "model_name", "stable_id", "primary_node",
            "identity_quality", "partial", "source",
        })
        exported.pci = copy_object(device.pci)
        exported.capabilities = copy_object(device.capabilities)
        exported.metrics = copy_object(device.metrics)
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

local function export_sensors(sensors)
    local result = json.object({ devices = json.array({}) })
    for device_index, device in ipairs(sensors and sensors.devices or {}) do
        local exported = copy_fields(device, {
            "id", "class", "class_index", "name", "device_target",
            "identity_quality", "quality", "truncated", "source",
        })
        exported.channels = json.array({})
        for channel_index, channel in ipairs(device.channels or {}) do
            local output = copy_fields(channel, {
                "id", "type", "index", "unit", "label", "input", "input_source",
                "alarm", "fault", "quality", "source",
            })
            output.readings = copy_object(channel.readings)
            output.thresholds = copy_object(channel.thresholds)
            output.errors = copy_object(channel.errors)
            exported.channels[channel_index] = output
        end
        result.devices[device_index] = exported
    end
    result.truncated = sensors and sensors.truncated == true or false
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
        "root_id", "node_count", "visible_process_count", "partial_node_count",
        "fresh_node_count", "gap_node_count", "reset_node_count", "issue_count",
        "denied_issue_count", "missing_issue_count", "parse_issue_count",
        "skipped_symlinks", "skipped_dot_entries", "skipped_unsafe_entries",
        "max_depth", "max_nodes", "depth_limited", "node_limited", "truncated",
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
            "issue_count", "rate_quality", "quality",
        })
        exported.processes = copy_fields(workload.processes, { "count" })
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

local function export_quality(quality)
    local result = json.object({})
    for resource, value in pairs(quality or {}) do
        result[resource] = copy_fields(value, {
            "status", "quality", "reason", "timestamp_ns", "duration_ns",
        })
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
        quality = export_quality(snapshot.quality),
        cpu = export_cpu(snapshot.cpu),
        cpu_info = export_cpu_info(snapshot.cpu_info),
        memory = export_memory(snapshot.memory),
        pressure = export_pressure(snapshot.pressure),
        disks = export_disks(snapshot.disks),
        network = export_network(snapshot.network),
        connections = export_connections(snapshot.connections, options.connection_limit,
            options.include_remote_addresses == true),
        processes = export_processes(snapshot.processes, options.process_limit),
        gpus = export_gpus(snapshot.gpus),
        cpu_frequency = export_cpu_frequency(snapshot.cpu_frequency),
        sensors = export_sensors(snapshot.sensors),
        power = export_power(snapshot.power),
        mounts = export_mounts(snapshot.mounts),
        workloads = export_workloads(snapshot.workloads, options.workload_limit),
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
    local function threshold(resource, code, value, warning, critical, unit, message)
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
            resource .. " pressure stalls are elevated")
        threshold(resource, "full_pressure", complete, 1, 5, "percent",
            resource .. " full stalls are elevated")
    end

    local disk_devices = full.disks and full.disks.devices or {}
    local ranked_disks = top_by(disk_devices, device_limit, function(device)
        if finite_number(device.busy_percent) then return device.busy_percent end
        local read = finite_number(device.read_bytes_per_second) and device.read_bytes_per_second or 0
        local write = finite_number(device.write_bytes_per_second) and device.write_bytes_per_second or 0
        return read + write
    end)
    local top_disks = json.array({})
    for index, device in ipairs(ranked_disks) do
        top_disks[index] = copy_fields(device, {
            "id", "name", "read_bytes_per_second", "write_bytes_per_second",
            "read_iops", "write_iops", "busy_percent", "average_read_latency_ms",
            "average_write_latency_ms", "in_flight", "quality",
        })
        threshold("storage", "device_busy", device.busy_percent, 80, 95, "percent",
            "A block device is saturated")
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
        })
        exported.rates = copy_fields(interface.rates, {
            "rx_bytes_per_second", "tx_bytes_per_second", "rx_packets_per_second",
            "tx_packets_per_second", "rx_errors_per_second", "tx_errors_per_second",
            "rx_dropped_per_second", "tx_dropped_per_second",
        })
        top_interfaces[index] = exported
    end

    local top_processes = json.array({})
    for index, process in ipairs(full.processes and full.processes.top or {}) do
        top_processes[index] = copy_fields(process, {
            "id", "pid", "name", "state", "user", "cpu_percent",
            "resident_bytes", "threads", "quality", "partial",
        })
    end

    local gpu_devices = full.gpus and full.gpus.devices or {}
    local gpu_summaries = json.array({})
    local maximum_gpu_utilization
    for _, device in ipairs(gpu_devices) do
        local utilization = device.metrics and device.metrics.utilization_percent
        if finite_number(utilization) then
            maximum_gpu_utilization = math.max(maximum_gpu_utilization or utilization, utilization)
        end
    end
    local ranked_gpus = top_by(gpu_devices, device_limit, function(device)
        return device.metrics and device.metrics.utilization_percent
    end)
    for index, device in ipairs(ranked_gpus) do
        local output = copy_fields(device, {
            "id", "card", "vendor", "vendor_name", "model_name", "driver", "quality", "partial",
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
            "frequency_current_hz", "temperature_celsius", "power_watts",
        })
        gpu_summaries[index] = output
    end
    threshold("gpu", "high_utilization", maximum_gpu_utilization, 85, 97, "percent",
        "GPU utilization is elevated")

    local temperature_count, fan_count, sensor_power_count = 0, 0, 0
    local top_temperatures = json.array({})
    local threshold_temperature
    for _, device in ipairs(full.sensors and full.sensors.devices or {}) do
        for _, channel in ipairs(device.channels or {}) do
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
                })
                top_temperatures[#top_temperatures + 1] = temperature
                local critical = temperature.thresholds and (temperature.thresholds.crit
                    or temperature.thresholds.emergency)
                local warning = temperature.thresholds and temperature.thresholds.max
                local severity
                if finite_number(critical) and temperature.temperature_celsius >= critical then
                    severity = "critical"
                elseif finite_number(warning) and temperature.temperature_celsius >= warning then
                    severity = "warning"
                end
                if severity and (not threshold_temperature
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
    if threshold_temperature then
        local critical = threshold_temperature.severity == "critical"
        add_signal("sensors", "temperature_threshold", threshold_temperature.severity,
            threshold_temperature.temperature_celsius, "celsius",
            critical and "A temperature sensor reached its critical threshold"
                or "A temperature sensor exceeded its maximum threshold")
    end

    local top_workloads = json.array({})
    for index, workload in ipairs(full.workloads and full.workloads.items or {}) do
        top_workloads[index] = copy_fields(workload, {
            "id", "name", "depth", "quality", "partial",
        })
        top_workloads[index].cpu = copy_fields(workload.cpu, { "utilization_percent" })
        top_workloads[index].memory = copy_fields(workload.memory, { "current_bytes", "max_bytes" })
        top_workloads[index].processes = copy_fields(workload.processes, { "count" })
    end

    local data_quality = json.array({})
    local quality_keys = {}
    for resource in pairs(full.quality or {}) do quality_keys[#quality_keys + 1] = resource end
    table.sort(quality_keys)
    for _, resource in ipairs(quality_keys) do
        local quality = full.quality[resource]
        data_quality[#data_quality + 1] = copy_fields(quality, { "status", "quality", "reason" })
        data_quality[#data_quality].resource = resource
        local status = quality and quality.status
        local freshness = quality and quality.quality
        if status == "error" or status == "denied" then
            add_signal(resource, "data_unavailable", "critical", nil, nil,
                "A required data source failed")
        elseif status == "unavailable" then
            add_signal(resource, "data_unavailable", "warning", nil, nil,
                "A data source is unavailable")
        elseif freshness == "stale" or freshness == "gap" or freshness == "reset"
            or freshness == "estimated" or freshness == "partial"
            or freshness == "unavailable"
        then
            add_signal(resource, "data_stale", "warning", nil, nil,
                "A data source is not fresh")
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
                power_watts = full.power and full.power.total_power_watts,
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
                receive_bytes_per_second = sum_field(interfaces, "rx_bytes_per_second", "rates"),
                transmit_bytes_per_second = sum_field(interfaces, "tx_bytes_per_second", "rates"),
                interface_count = #interfaces,
            }),
            gpu = json.object({
                device_count = #gpu_devices,
                maximum_utilization_percent = maximum_gpu_utilization,
            }),
            power = json.object({
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
            }),
            sensors = json.object({
                temperature_count = temperature_count,
                fan_count = fan_count,
                power_count = sensor_power_count,
                maximum_temperature_celsius = hottest and hottest.temperature_celsius,
            }),
            processes = json.object({ total = full.processes and full.processes.total }),
        }),
        signals = signals,
        top = json.object({
            processes = top_processes,
            disks = top_disks,
            interfaces = top_interfaces,
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
