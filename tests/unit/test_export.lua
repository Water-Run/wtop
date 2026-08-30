package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Export = require("wtop.export")
local json = require("wtop.format.json")

local private_connection_id = "tcp:127.0.0.1:8080:192.0.2.42:54321:01"
local result = Export.snapshot({
    sequence = 2,
    timestamp_ns = 10,
    quality = { cpu = { status = "ok", quality = "fresh" } },
    cpu = { total = { utilization = 33, counters = { should_not_leak = true } }, cores = {} },
    cpu_info = {
        schema = "dev.waterrun.wtop.cpu-info/v1",
        identity = { model_name = "Example CPU", vendor = "Example Vendor",
            flags = { "a", "b" }, flags_count = 2, private = "omit" },
        topology = { sockets = 1, physical_cores = 1, threads = 2, online_threads = 1,
            online_cpu_list = { 0 }, present_cpu_list = { 0, 1 }, possible_cpu_list = { 0, 1 },
            isolated_cpu_list = { 1 }, logical_cpus = {
                { id = 0, online = true, package_id = 0, core_id = 0,
                    thread_siblings = { 0, 1 } },
            } },
        caches = { { id = "L1", level = 1, type = "Data", size_bytes = 32768,
            shared_cpu_list = { 0 }, private = "omit" } },
        cache_summary = { { id = "L1:Data", level = 1, type = "Data", instances = 1,
            total_size_bytes = 32768 } },
        issues = { { field = "cache.size", status = "error", reason = "invalid_cache_size",
            source = "/sys/cpu/cache/size", private = "omit" } },
    },
    memory = { total_bytes = 100, used_bytes = 40, raw = { should_not_leak = true } },
    pressure = { cpu = { some = { avg10 = 0.1 } } },
    disks = { devices = {
        { id = "8:0", name = "sda", accounting_sector_size_bytes = 512,
            logical_sector_size_bytes = 4096, physical_sector_size_bytes = 4096 },
    } },
    network = { interfaces = {} },
    connections = { total = 1, counts = { tcp = 1 }, connections = {
        { id = private_connection_id, table = "tcp", protocol = "tcp", family = "ipv4",
            local_address = "127.0.0.1", local_port = 8080,
            remote_address = "192.0.2.42", remote_port = 54321,
            state = "established", inode = "123", owners = {
                { pid = 2, fd = 7, name = "worker" },
            } },
    } },
    processes = { list = {
        { id = "1:1", pid = 1, name = "init", cpu_percent = 1 },
        { id = "2:1", pid = 2, name = "worker", cpu_percent = 10 },
    } },
    gpus = {
        schema = "dev.waterrun.wtop.gpu/v2",
        process_scan = { status = "ok", quality = "fresh", scanned_processes = 2 },
        drm_scan = { truncated = false, unattached_render_nodes = 0 },
        devices = {
            {
                id = "0000:03:00.0", stable_id = "pci:0000:03:00.0", card = "card0",
                capabilities = {}, metrics = {}, quality = {},
                drm_nodes = { { name = "card0", kind = "primary", dev = "226:0" } },
                hwmon_refs = { { class = "hwmon5", pci_bdf = "0000:03:00.0" } },
                frequencies = { domains = { { id = "graphics", current_hz = 1000000000 } } },
                processes = {
                    quality = "fresh",
                    summary = { process_count = 1, client_count = 1 },
                    clients = {},
                    list = {
                        { id = "10:20", pid = 10, name = "render", memory_summary = {}, engines = {} },
                    },
                },
                issues = { { field = "identity.class", status = "denied",
                    reason = "permission denied", source = "/sys/gpu/class", private = "omit" } },
            },
        },
    },
    sensors = { devices = {
        { id = "nvme@0", class = "hwmon1", name = "nvme", channels = {
            { id = "temperature:1", type = "temperature", index = 1, unit = "celsius",
                input = nil, quality = "partial", readings = {}, thresholds = {},
                errors = { input = { status = "error", reason = "implausible_sensor_value" } } },
        } },
    } },
    power = {
        schema = "dev.waterrun.wtop.powercap/v1", total_power_watts = 12,
        aggregate_strategy = "cpu_package_roots", platform_power_watts = 20,
        measured_aggregate_zones = 1, measured_platform_zones = 1, denied_zones = 0,
        zones = { { id = "rapl:0", name = "package-0", aggregate = true,
            platform_aggregate = false, aggregate_domain = "cpu_package",
            power_watts = 12, power_source = "energy_delta", constraints = {},
            issues = { { field = "enabled", status = "error", reason = "number_out_of_range",
                source = "/sys/power/enabled", private = "omit" } } } },
        issues = { { field = "enabled", status = "error", reason = "number_out_of_range",
            source = "/sys/power/enabled", private = "omit" } },
    },
}, {
    process_limit = 1,
    configuration = {
        state = "error",
        reason = "invalid fixture",
        path = "/private/config/path",
    },
    privilege = {
        mode = "root", uid = 0, effective_uid = 0, original_uid = 1000,
        root = true, elevated = true, via_sudo = true, requested = true,
        private = "must not leak",
    },
})

assert(result.schema == "dev.waterrun.wtop.snapshot/v1")
assert(result.configuration.state == "error")
assert(result.configuration.reason == "invalid fixture")
assert(result.configuration.path == nil)
assert(result.privilege.mode == "root" and result.privilege.root == true)
assert(result.privilege.via_sudo == true and result.privilege.original_uid == 1000)
assert(result.privilege.private == nil)
assert(result.cpu.total.utilization == 33)
assert(result.cpu.total.counters == nil)
assert(result.cpu_info.identity.model_name == "Example CPU")
assert(result.cpu_info.identity.private == nil and result.cpu_info.identity.flags[2] == "b")
assert(result.cpu_info.topology.logical_cpus[1].thread_siblings[2] == 1)
assert(result.cpu_info.caches[1].private == nil)
assert(result.cpu_info.issues[1].field == "cache.size")
assert(result.cpu_info.issues[1].private == nil)
assert(result.memory.raw == nil)
assert(result.disks.devices[1].accounting_sector_size_bytes == 512)
assert(result.disks.devices[1].logical_sector_size_bytes == 4096)
assert(result.disks.devices[1].physical_sector_size_bytes == 4096)
assert(result.processes.total == 2)
assert(result.processes.top[1].pid == 2)
assert(result.connections.items[1].remote_address == "192.0.2.x")
assert(result.connections.items[1].id:find("192.0.2.x", 1, true))
assert(not result.connections.items[1].id:find("192.0.2.42", 1, true))
assert(result.connections.items[1].owners[1].pid == 2)
assert(result.sensors.devices[1].channels[1].errors.input.reason
    == "implausible_sensor_value")
assert(result.power.aggregate_strategy == "cpu_package_roots")
assert(result.power.platform_power_watts == 20 and result.power.measured_platform_zones == 1)
assert(result.power.zones[1].aggregate_domain == "cpu_package")
assert(result.power.issues[1].reason == "number_out_of_range")
assert(result.power.zones[1].issues[1].field == "enabled")
assert(result.power.issues[1].private == nil)
assert(result.gpus.devices[1].issues[1].status == "denied")
assert(result.gpus.devices[1].issues[1].private == nil)
local encoded = json.encode(result)
assert(encoded:find('"schema":"dev.waterrun.wtop.snapshot/v1"', 1, true))
assert(encoded:find('"errors":{}', 1, true))
assert(encoded:find('"metrics":{}', 1, true))
assert(encoded:find('"capabilities":{}', 1, true))
assert(encoded:find('"top":[', 1, true))
assert(encoded:find('"schema":"dev.waterrun.wtop.gpu/v2"', 1, true))
assert(encoded:find('"stable_id":"pci:0000:03:00.0"', 1, true))
assert(encoded:find('"process_scan":{', 1, true))
assert(encoded:find('"hwmon_refs":[', 1, true))

local mount_export = Export.snapshot({
    mounts = {
        count = 2,
        complete = 1,
        failed = 0,
        skipped = 1,
        partial = true,
        budget_exhausted = true,
        budget_reason = "calls",
        statvfs_attempted = 1,
        statvfs_budget_ms = 50,
        max_statvfs_calls = 1,
        mounts = {
            { id = "1", mount_point = "/", quality = "fresh", partial = false },
            {
                id = "2", mount_point = "/remote", quality = "unavailable",
                partial = true, skipped = true,
                partial_reason = "statvfs_skipped_budget_exhausted",
            },
        },
    },
})
assert(mount_export.mounts.skipped == 1 and mount_export.mounts.partial)
assert(mount_export.mounts.budget_exhausted and mount_export.mounts.budget_reason == "calls")
assert(mount_export.mounts.statvfs_attempted == 1)
assert(mount_export.mounts.statvfs_budget_ms == 50 and mount_export.mounts.max_statvfs_calls == 1)
assert(mount_export.mounts.mounts[2].skipped == true)

local connection_snapshot = {
    connections = { total = 2, connections = {
        {
            id = private_connection_id,
            table = "tcp", protocol = "tcp", family = "ipv4",
            local_address = "127.0.0.1", local_port = 8080,
            remote_address = "192.0.2.42", remote_port = 54321,
            state_code = "01", inode = "0",
        },
        {
            id = "tcp6:[::1]:8080:[2001:db8::dead:beef]:443:01#2",
            table = "tcp6", protocol = "tcp", family = "ipv6",
            local_address = "::1", local_port = 8080,
            remote_address = "2001:db8::dead:beef", remote_port = 443,
            state_code = "01", inode = "0",
        },
    } },
}
local masked_once = Export.snapshot(connection_snapshot)
local masked_twice = Export.snapshot(connection_snapshot)
assert(masked_once.connections.items[1].id == masked_twice.connections.items[1].id)
assert(masked_once.connections.items[2].id == masked_twice.connections.items[2].id)
assert(not masked_once.connections.items[1].id:find("192.0.2.42", 1, true))
assert(not masked_once.connections.items[2].id:find("2001:db8::dead:beef", 1, true))
assert(masked_once.connections.items[2].id:find("2001:db8:…", 1, true))

local unmasked = Export.snapshot(connection_snapshot, { include_remote_addresses = true })
assert(unmasked.connections.items[1].id == private_connection_id)
assert(unmasked.connections.items[1].remote_address == "192.0.2.42")
assert(unmasked.connections.items[2].id == connection_snapshot.connections.connections[2].id)
assert(unmasked.connections.items[2].remote_address == "2001:db8::dead:beef")

local agent = Export.agent({
    sequence = 9,
    timestamp_ns = 123,
    quality = {
        cpu = { status = "ok", quality = "gap" },
        memory = { status = "ok", quality = "fresh" },
    },
    cpu = {
        total = { utilization = 92, user = 70, system = 12, iowait = 10 },
        cores = { { name = "cpu0" }, { name = "cpu1" } },
        load = { one = 4, five = 2, fifteen = 1 },
        processes_running = 3,
        processes_blocked = 1,
    },
    cpu_info = {
        identity = { model_name = "Example CPU", vendor = "Example Vendor",
            heterogeneous = true, core_type_count = 2 },
        topology = { threads = 2, physical_cores = 1, sockets = 1 },
        core_types = {
            { id = "type-1", model_name = "Fast cores", threads_per_core = 2,
                maximum_frequency_hz = 4700000000, physical_core_count = 1,
                logical_cpu_count = 2 },
            { id = "type-2", model_name = "Efficient cores", threads_per_core = 1,
                maximum_frequency_hz = 3600000000, physical_core_count = 4,
                logical_cpu_count = 4 },
        },
    },
    memory = {
        total_bytes = 1000, used_bytes = 900, available_bytes = 100,
        swap_total_bytes = 100, swap_used_bytes = 20,
    },
    pressure = { cpu = { some = { avg10 = 6 } } },
    power = { total_power_watts = 15, measured_aggregate_zones = 1, denied_zones = 0,
        aggregate_strategy = "cpu_package_roots", platform_power_watts = 22,
        measured_platform_zones = 1 },
    sensors = { devices = {
        { id = "coretemp@0", name = "coretemp", channels = {
            { id = "temperature:1", type = "temperature", label = "Package",
                input = 96, quality = "fresh", thresholds = { max = 90, crit = 100 } },
            { id = "fan:1", type = "fan", input = 1200, quality = "fresh", thresholds = {} },
        } },
    } },
    disks = { devices = {
        { id = "8:0", name = "sda", busy_percent = 96,
            read_bytes_per_second = 10, write_bytes_per_second = 20 },
        { id = "8:1", name = "sda1", aggregate = false,
            read_bytes_per_second = 1000, write_bytes_per_second = 2000 },
    } },
    network = { interfaces = {
        { id = "2", name = "eth0", rates = {
            rx_bytes_per_second = 30, tx_bytes_per_second = 40,
        } },
        { id = "3", name = "veth0", aggregate = false, rates = {
            rx_bytes_per_second = 3000, tx_bytes_per_second = 4000,
        } },
    } },
    processes = { list = {
        { id = "2:1", pid = 2, name = "worker", command = "secret --token",
            cpu_percent = 50, resident_bytes = 64 },
    } },
}, {
    privilege = { mode = "user", uid = 1000, effective_uid = 1000,
        root = false, elevated = false, via_sudo = false },
    capabilities = {
        cpu = { available = true, state = "available" },
        gpu = { available = false, state = "unavailable", reason = "no DRM device" },
    },
})
assert(agent.schema == "dev.waterrun.wtop.agent/v1")
assert(agent.privilege.mode == "user" and agent.privilege.root == false)
assert(agent.overall.state == "critical" and agent.overall.signal_count >= 2)
assert(agent.metrics.cpu.logical_cpus == 2)
assert(agent.metrics.cpu.model_name == "Example CPU")
assert(agent.metrics.cpu.vendor == "Example Vendor")
assert(agent.metrics.cpu.physical_cores == 1 and agent.metrics.cpu.sockets == 1)
assert(agent.metrics.cpu.power_watts == 15)
assert(agent.metrics.cpu.heterogeneous and agent.metrics.cpu.core_type_count == 2)
assert(#agent.metrics.cpu.core_types == 2)
assert(agent.metrics.cpu.core_types[1].maximum_frequency_hz == 4700000000)
assert(agent.metrics.cpu.core_types[1].physical_core_count == 1)
assert(agent.metrics.cpu.core_types[2].threads_per_core == 1)
assert(agent.metrics.cpu.core_types[2].physical_core_count == 4)
assert(agent.metrics.memory.used_percent == 90)
assert(agent.metrics.network.receive_bytes_per_second == 30)
assert(agent.metrics.storage.read_bytes_per_second == 10)
assert(agent.metrics.power.total_watts == 15)
assert(agent.metrics.power.aggregate_strategy == "cpu_package_roots")
assert(agent.metrics.power.platform_watts == 22)
assert(agent.metrics.power.measured_platform_zones == 1)
assert(agent.metrics.sensors.maximum_temperature_celsius == 96)
assert(agent.metrics.sensors.temperature_count == 1 and agent.metrics.sensors.fan_count == 1)
assert(agent.overall.signal_count >= 3, "gap quality must produce an Agent warning")
assert(agent.top.processes[1].pid == 2 and agent.top.processes[1].command == nil)
assert(agent.top.disks[1].name == "sda")
assert(agent.top.sensors[1].label == "Package")
assert(agent.unavailable_sources[1].id == "gpu")
local encoded_agent = json.encode(agent)
assert(encoded_agent:find('"schema":"dev.waterrun.wtop.agent/v1"', 1, true))
assert(not encoded_agent:find("secret --token", 1, true))

local per_sensor_threshold_agent = Export.agent({
    sensors = { devices = {
        { id = "hot", name = "Hot device", channels = {
            { id = "temperature:1", type = "temperature", input = 95,
                quality = "fresh", thresholds = { max = 100, crit = 110 } },
        } },
        { id = "cooler", name = "Cooler device", channels = {
            { id = "temperature:1", type = "temperature", input = 75,
                quality = "fresh", thresholds = { max = 70, crit = 74 } },
        } },
    } },
}, { device_limit = 1 })
assert(#per_sensor_threshold_agent.top.sensors == 1)
assert(per_sensor_threshold_agent.top.sensors[1].temperature_celsius == 95,
    "the bounded top list must retain the absolute hottest sensor")
local per_sensor_signal
for _, signal in ipairs(per_sensor_threshold_agent.signals) do
    if signal.code == "temperature_threshold" then per_sensor_signal = signal end
end
assert(per_sensor_signal and per_sensor_signal.severity == "critical")
assert(per_sensor_signal.value == 75,
    "a cooler sensor crossing its own threshold must not be hidden by a hotter safe sensor")

local bounded_agent = Export.agent({
    gpus = { devices = {
        { id = "slow", metrics = { utilization_percent = 1 } },
        { id = "fast", card = "card1", vendor = "Intel", vendor_name = "Intel Corporation",
            model_name = "Example GPU", driver = "i915",
            pci = { class_id = 0x030000, class_name = "VGA compatible controller",
                subsystem_vendor_name = "Example OEM", current_link_width = 8,
                runtime_status = "active" },
            metrics = { utilization_percent = 99, utilization_source = "drm_fdinfo",
                process_memory_bytes = 64 * 1024 * 1024, frequency_current_hz = 1500000000 } },
    } },
}, { device_limit = 1 })
assert(#bounded_agent.top.gpus == 1 and bounded_agent.top.gpus[1].id == "fast",
    "Agent GPU summaries must respect device_limit and retain the busiest device")
assert(bounded_agent.metrics.gpu.maximum_utilization_percent == 99)
assert(bounded_agent.top.gpus[1].model_name == "Example GPU")
assert(bounded_agent.top.gpus[1].pci.subsystem_vendor_name == "Example OEM")
assert(bounded_agent.top.gpus[1].metrics.utilization_source == "drm_fdinfo")
assert(bounded_agent.top.gpus[1].metrics.process_memory_bytes == 64 * 1024 * 1024)

-- Public Agent options cannot exceed the top-list maxima promised by the v1
-- schema, even when an embedding asks for a larger projection.
local oversized_snapshot = {
    processes = { list = {} }, disks = { devices = {} },
    network = { interfaces = {} }, gpus = { devices = {} },
    workloads = { workloads = {} },
}
for index = 1, 20 do
    oversized_snapshot.processes.list[index] = {
        id = tostring(index), pid = index, name = "p" .. index, cpu_percent = index,
    }
    oversized_snapshot.disks.devices[index] = {
        id = tostring(index), name = "d" .. index, busy_percent = index,
    }
    oversized_snapshot.network.interfaces[index] = {
        id = tostring(index), name = "n" .. index,
        rates = { rx_bytes_per_second = index, tx_bytes_per_second = index },
    }
    oversized_snapshot.gpus.devices[index] = {
        id = tostring(index), metrics = { utilization_percent = index },
    }
    oversized_snapshot.workloads.workloads[index] = {
        id = tostring(index), name = "w" .. index,
        cpu = { utilization_percent = index }, memory = {}, io = {}, processes = {},
    }
end
local schema_bounded = Export.agent(oversized_snapshot, {
    process_limit = 100, device_limit = 50, workload_limit = 100,
})
assert(#schema_bounded.top.processes == 10)
assert(#schema_bounded.top.disks == 5 and #schema_bounded.top.interfaces == 5)
assert(#schema_bounded.top.gpus == 5 and #schema_bounded.top.workloads == 5)

return true
