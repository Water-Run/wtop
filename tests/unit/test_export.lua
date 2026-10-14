package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Export = require("wtop.export")
local Report = require("wtop.report")
local Snapshot = require("wtop.model.snapshot")
local TUI = require("wtop.tui")
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
    processes = { io_scan = { status = "partial", covered = 1, total = 2,
        rate_covered = 1, refreshed = 2, reused = 0, capped = 0,
        observed_ns = 10, refresh_interval_ns = 2000000000,
        private = "omit" }, list = {
        { id = "1:1", pid = 1, name = "init", cpu_percent = 1 },
        { id = "2:1", pid = 2, name = "worker", cpu_percent = 10,
          io = { read_bytes = 4096, write_bytes = 8192, rchar = 5000,
            private = "omit" },
          io_observed_ns = 10,
          io_rate = { read_bytes_per_second = 1024,
            write_bytes_per_second = 2048, interval_ns = 4000000000,
            observed_ns = 10, quality = "fresh", private = "omit" },
          affinity = { cpus_allowed_list = "0-1", cpus_allowed_count = 2,
            mems_allowed_list = "0", mems_allowed_count = 1,
            status = "ok", observed_ns = 9, issues = {}, private = "omit" } },
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
assert(result.processes.io_scan.status == "partial"
  and result.processes.io_scan.covered == 1
  and result.processes.io_scan.private == nil)
assert(result.processes.top[1].io.read_bytes == 4096
  and result.processes.top[1].io.write_bytes == 8192
  and result.processes.top[1].io.private == nil)
assert(result.processes.top[1].io_observed_ns == 10
  and result.processes.top[1].io_rate.read_bytes_per_second == 1024
  and result.processes.top[1].io_rate.quality == "fresh"
  and result.processes.top[1].io_rate.private == nil,
  "snapshot exports the bounded process I/O readings and their sample quality")
assert(result.processes.top[1].affinity.cpus_allowed_list == "0-1"
  and result.processes.top[1].affinity.cpus_allowed_count == 2
  and result.processes.top[1].affinity.observed_ns == 9
  and result.processes.top[1].affinity.private == nil,
  "snapshot exports only bounded, observed affinity fields")
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
local report = Report.render(result)
assert(report:find("# wtop hardware report", 1, true)
    and report:find("Example CPU", 1, true)
    and report:find("sda", 1, true)
    and report:find("## Collection status", 1, true)
    and report:find("| cpu | ok | fresh |", 1, true))
assert(not report:find("192.0.2.42", 1, true)
    and not report:find("worker", 1, true),
    "a hardware report excludes connection endpoints and process identities")

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
            cpu_percent = 50, resident_bytes = 64,
            io = { read_bytes = 1024 },
            io_rate = { read_bytes_per_second = 128, quality = "fresh" } },
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
assert(agent.top.processes[1].io == nil and agent.top.processes[1].io_rate == nil,
  "the compact Agent projection does not inherit snapshot-only I/O details")
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

-- A field the collector gathers but the export drops is invisible: the TUI
-- shows a number that `--snapshot` cannot reproduce.  That happened three
-- times while the Memory, Storage and System pages were being built, because
-- every exporter carries an explicit allow-list.  Pin the fields those pages
-- depend on so the next addition cannot quietly fail to ship.
local enriched = Export.snapshot({
    sequence = 1,
    timestamp_ns = 1,
    memory = {
        total_bytes = 1000, available_bytes = 400, used_bytes = 600, free_bytes = 300,
        buffers_bytes = 50, cache_bytes = 100, shared_bytes = 25, mapped_bytes = 75,
        page_tables_bytes = 10, kernel_stack_bytes = 5, committed_bytes = 900,
        commit_limit_bytes = 1500, active_bytes = 200, inactive_bytes = 150,
        swap_total_bytes = 0, swap_free_bytes = 0, swap_used_bytes = 0,
        segments = {
            { id = "used", bytes = 525 }, { id = "shared", bytes = 25 },
            { id = "buffers", bytes = 50 }, { id = "cache", bytes = 100 },
            { id = "free", bytes = 300 },
        },
    },
    disks = { devices = { {
        id = "8:0", name = "sda", partial = false, topology_truncated = false,
        identity = {
            model = "Example SSD", vendor = "Example", size_bytes = 512 * 1024 * 1024,
            rotational = 0, removable = false, scheduler = "none", virtual = false,
        },
    } } },
    network = { interfaces = { {
        name = "eth0", counters = { rx_bytes = 10, tx_bytes = 20 },
        addresses = { { family = "ipv4", address = "192.0.2.5", netmask = "255.255.255.0" } },
    } }, addresses_status = "ok" },
    system = {
        host = { hostname = "example", architecture = "x86_64" },
        kernel = { release = "6.8.0" },
        distribution = { pretty_name = "Example Linux" },
        limits = { pid_max = 4096, file_descriptors = { open = 12, maximum = 1024 } },
        counters = { ctxt = 99, intr = 88, forks = 7 },
        uptime_seconds = 1234, boot_time_unix = 1700000000,
        virtualization = { virtual = true, technology = "kvm" },
    },
    power_supplies = {
        batteries = { { id = "BAT0", name = "BAT0", capacity_percent = 62,
            health_percent = 83, energy_watt_hours = 31, power_watts = 10 } },
        supplies = { { id = "AC", name = "AC", type = "Mains", online = false } },
        summary = { count = 1, capacity_percent = 62, state = "discharging" },
        on_ac_power = false,
    },
}, {})

local memory_out = enriched.memory
for _, field in ipairs({ "shared_bytes", "mapped_bytes", "page_tables_bytes",
    "kernel_stack_bytes", "committed_bytes", "commit_limit_bytes",
    "active_bytes", "inactive_bytes" }) do
    assert(memory_out[field] ~= nil, "memory." .. field .. " must reach the snapshot")
end
assert(#memory_out.segments == 5, "the stacked composition must be exported")
local segment_total = 0
for _, segment in ipairs(memory_out.segments) do
    segment_total = segment_total + segment.bytes
end
assert(segment_total == memory_out.total_bytes,
    "the exported partition must still sum to the total")

local disk_out = enriched.disks.devices[1]
assert(disk_out.identity ~= nil, "block-device identity must reach the snapshot")
assert(disk_out.identity.model == "Example SSD", "model survives")
assert(disk_out.identity.size_bytes == 512 * 1024 * 1024, "capacity survives")
assert(disk_out.identity.scheduler == "none", "scheduler survives")
assert(disk_out.identity.virtual == false, "the virtual-device flag survives")
assert(disk_out.partial == false, "completeness flags survive")

local interface_out = enriched.network.interfaces[1]
assert(#interface_out.addresses == 1, "interface addresses must reach the snapshot")
assert(interface_out.addresses[1].address == "192.0.2.5", "the address survives")
assert(interface_out.counters.rx_bytes == 10, "raw counters survive")
assert(enriched.network.addresses_status == "ok", "the address-scan status survives")

local system_out = enriched.system
assert(system_out.host.hostname == "example", "hostname survives")
assert(system_out.kernel.release == "6.8.0", "kernel release survives")
assert(system_out.distribution.pretty_name == "Example Linux", "distribution survives")
assert(system_out.limits.file_descriptors.open == 12, "descriptor usage survives")
assert(system_out.counters.ctxt == 99, "kernel counters survive")
assert(system_out.virtualization.technology == "kvm", "virtualization survives")
assert(system_out.boot_time_unix == 1700000000, "boot time survives")

local power_out = enriched.power_supplies
assert(#power_out.batteries == 1 and power_out.batteries[1].health_percent == 83,
    "battery health survives")
assert(power_out.on_ac_power == false, "mains state survives")

-- Host-identifying firmware members are never collected, so they must never
-- appear in a snapshot that gets pasted into a bug report.
local leaky = Export.snapshot({
    sequence = 1, timestamp_ns = 1,
    system = { host = { hostname = "example" }, firmware = {
        product_name = "Example", product_serial = "SECRET-SERIAL",
        board_serial = "SECRET-BOARD", product_uuid = "SECRET-UUID",
        chassis_asset_tag = "SECRET-ASSET",
    } },
}, {})
for _, field in ipairs({ "product_serial", "board_serial", "product_uuid",
    "chassis_asset_tag" }) do
    assert(leaky.system.firmware[field] == nil,
        "host-identifying DMI member must never be exported: " .. field)
end
assert(leaky.system.firmware.product_name == "Example", "non-identifying members survive")
leaky.system.firmware.product_name = "Example|<board>\27"
local private_report = Report.render(leaky)
assert(private_report:find("Example\\|&lt;board&gt;", 1, true)
    and not private_report:find("SECRET", 1, true)
    and not private_report:find("\27", 1, true),
    "the readable report preserves Snapshot privacy and escapes terminal/Markdown input")
assert(Report.render({}):find("No records in this snapshot", 1, true))
local denied_report = Report.render({ quality = {
    firmware_batteries = { status = "denied", quality = "denied",
        reason = "permission denied" },
} })
assert(denied_report:find("| firmware_batteries | denied | denied | permission denied |", 1, true)
    and denied_report:find("No records in this snapshot", 1, true),
    "an inaccessible hardware source keeps its reason instead of a fabricated zero")

-- The attempt can be new while the installed value is old.  Both export
-- forms must carry the value's own time and age, never the failed retry's.
local valued = Snapshot.merge(Snapshot.new(0, 0), {
    cpu = { status = "ok", quality = "fresh", timestamp_ns = 1000000000,
        data = { total = { utilization = 25 } } },
}, 1, 1000000000)
local retained = Snapshot.merge(valued, {
    cpu = { status = "error", quality = "error", reason = "race",
        timestamp_ns = 100000000000 },
}, 2, 100000000000)
local quality_out = Export.snapshot(retained).quality.cpu
assert(quality_out.timestamp_ns == 100000000000
    and quality_out.value_timestamp_ns == 1000000000
    and quality_out.value_age_ms == 99000,
    "snapshot distinguishes a fresh retry from a 99-second-old value")
local agent_out = Export.agent(retained)
local agent_cpu_quality
for _, row in ipairs(agent_out.data_quality) do
    if row.resource == "cpu" then agent_cpu_quality = row end
end
assert(agent_cpu_quality and agent_cpu_quality.value_timestamp_ns == 1000000000
    and agent_cpu_quality.value_age_ms == 99000,
    "agent context preserves the retained value's age")
local unknown = Snapshot.merge(Snapshot.new(0, 0), {
    cpu = { status = "error", quality = "error", timestamp_ns = 100000000000 },
}, 1, 100000000000)
local unknown_out = Export.snapshot(unknown).quality.cpu
assert(unknown_out.value_timestamp_ns == nil and unknown_out.value_age_ms == nil,
    "an absent value has no invented age")

local function signal_named(document, code, resource)
    for _, signal in ipairs(document.signals or {}) do
        if signal.code == code and (resource == nil or signal.resource == resource) then
            return signal
        end
    end
end

-- A failed collector preserves its previous values for context.  Those values
-- remain in metrics/top with their age, but cannot assert a *current* alarm.
local alarming = Snapshot.merge(Snapshot.new(0, 0), {
    cpu = { status = "ok", quality = "fresh", timestamp_ns = 1000000000,
        data = { total = { utilization = 98, iowait = 25 }, cores = {} } },
    memory = { status = "ok", quality = "fresh", timestamp_ns = 1000000000,
        data = { total_bytes = 100, used_bytes = 99 } },
    pressure = { status = "ok", quality = "fresh", timestamp_ns = 1000000000,
        data = { cpu = { some = { avg10 = 30 } } } },
    disk = { status = "ok", quality = "fresh", timestamp_ns = 1000000000,
        data = { devices = { { id = "8:0", name = "sda", busy_percent = 98,
            quality = "fresh" } } } },
    gpu = { status = "ok", quality = "fresh", timestamp_ns = 1000000000,
        data = { devices = { { id = "card0", quality = { utilization = "fresh" },
            metrics = { utilization_percent = 99 } } } } },
    hwmon = { status = "ok", quality = "fresh", timestamp_ns = 1000000000,
        data = { devices = { { id = "thermal", name = "Thermal", channels = {
            { id = "temperature:1", type = "temperature", input = 105,
                quality = "fresh", thresholds = { crit = 100 } },
        } } } } },
}, 1, 1000000000)
local fresh_alerts = Export.agent(alarming)
for _, code in ipairs({ "high_utilization", "high_usage", "sustained_pressure",
    "device_busy", "temperature_threshold" }) do
    assert(signal_named(fresh_alerts, code), "fixture did not exercise " .. code)
end
assert(signal_named(fresh_alerts, "high_utilization", "gpu"),
    "the fixture did not exercise the GPU alarm")
local retained_alerts = Snapshot.merge(alarming, {
    cpu = { status = "error", quality = "error", timestamp_ns = 100000000000 },
    memory = { status = "error", quality = "error", timestamp_ns = 100000000000 },
    pressure = { status = "error", quality = "error", timestamp_ns = 100000000000 },
    disk = { status = "error", quality = "error", timestamp_ns = 100000000000 },
    gpu = { status = "error", quality = "error", timestamp_ns = 100000000000 },
    hwmon = { status = "error", quality = "error", timestamp_ns = 100000000000 },
}, 2, 100000000000)
local stale_alerts = Export.agent(retained_alerts)
assert(stale_alerts.metrics.cpu.utilization_percent == 98
    and stale_alerts.data_quality[1].value_age_ms == 99000,
    "the old values remain available with age and quality")
for _, code in ipairs({ "high_utilization", "high_iowait", "high_usage",
    "sustained_pressure", "device_busy", "temperature_threshold" }) do
    assert(not signal_named(stale_alerts, code),
        "a failed collector emitted a current threshold signal: " .. code)
end
assert(signal_named(stale_alerts, "data_unavailable"),
    "failure still has to produce its own quality signal")
local partly_recovered = Snapshot.merge(retained_alerts, {
    cpu = { status = "ok", quality = "fresh", timestamp_ns = 101000000000,
        data = { total = { utilization = 98 }, cores = {} } },
    memory = { status = "ok", quality = "fresh", timestamp_ns = 101000000000,
        data = { total_bytes = 100, used_bytes = 99 } },
}, 3, 101000000000)
local mixed_alerts = Export.agent(partly_recovered)
assert(signal_named(mixed_alerts, "high_utilization")
    and signal_named(mixed_alerts, "high_usage"),
    "healthy sources must still alarm while other sources are unavailable")
assert(not signal_named(mixed_alerts, "sustained_pressure"),
    "CPU pressure comes from the failed pressure collector, not the healthy CPU collector")

local rows = {}
local service_estimate = Export.agent({ quality = { disks = { status = "ok", quality = "fresh" } },
    disks = { devices = { { id = "disk0", name = "disk0", busy_percent = 100,
        busy_quality = "estimated", quality = "fresh" } } } })
assert(not signal_named(service_estimate, "device_busy"),
    "parallel request time cannot assert a wall-clock disk busy alarm")
assert(service_estimate.top.disks[1].busy_percent == 100
    and service_estimate.top.disks[1].busy_quality == "estimated",
    "the estimate remains available with its own quality in Agent")
local exact_busy = Export.agent({ disks = { devices = { { id = "disk0", name = "disk0",
    busy_percent = 100, quality = "fresh" } } } })
assert(signal_named(exact_busy, "device_busy"), "exact busy readings still participate in alerts")

for index = 1, 5 do
    rows[#rows + 1] = { id = "old" .. index, name = "old" .. index,
        busy_percent = 98, quality = "stale" }
end
rows[#rows + 1] = { id = "current", name = "current", busy_percent = 97,
    quality = "fresh" }
local mixed_rows = Export.agent({
    quality = {
        disks = { status = "ok", quality = "partial" },
        gpus = { status = "ok", quality = "fresh" },
        sensors = { status = "ok", quality = "fresh" },
    },
    disks = { devices = rows },
    gpus = { devices = {
        { id = "old", metrics = { utilization_percent = 99 },
            quality = { utilization = "stale" } },
        { id = "current", metrics = { utilization_percent = 30 },
            quality = { utilization = "fresh" } },
    } },
    sensors = { devices = { { id = "thermal", channels = {
        { id = "old", type = "temperature", input = 105, quality = "stale",
            thresholds = { crit = 100 } },
        { id = "current", type = "temperature", input = 50, quality = "fresh",
            thresholds = { crit = 100 } },
    } } } },
}, { device_limit = 5 })
assert(signal_named(mixed_rows, "device_busy")
    and signal_named(mixed_rows, "device_busy").value == 97,
    "a current busy disk outside the stale top five must still alarm")
assert(not signal_named(mixed_rows, "high_utilization")
    and not signal_named(mixed_rows, "temperature_threshold"),
    "stale device and channel values cannot trigger current alarms")

local stale_quality = Export.agent({
    quality = { cpu = { status = "ok", quality = "stale" } },
    cpu = { total = { utilization = 98 } },
})
assert(not signal_named(stale_quality, "high_utilization")
    and signal_named(stale_quality, "data_stale"),
    "an explicit stale quality label is not current threshold evidence")
local partial_quality = Export.agent({
    quality = { memory = { status = "ok", quality = "partial" } },
    memory = { total_bytes = 100, used_bytes = 99 },
})
assert(signal_named(partial_quality, "high_usage"),
    "a current, partially measured resource still has usable present values")

-- Root ports and endpoints may report the same PCIe event.  A current
-- nonfatal/fatal increase is one clue per severity, not a sum of observers.
local function aer_change(new_reports, quality)
    return { change = { new_reports = new_reports, quality = quality or "fresh" } }
end
local aer_inventory = { pci = { devices = {
    { address = "0000:00:01.0", vendor_id = 0x8086, device_id = 1,
        aer = { status = "ok", correctable = aer_change(20),
            nonfatal = aer_change(2), fatal = aer_change(1),
            rootport = { changes = {
                nonfatal = { new_reports = 2, quality = "fresh" },
                fatal = { new_reports = 1, quality = "fresh" },
            } } } },
    { address = "0000:01:00.0", vendor_id = 0x8086, device_id = 2,
        aer = { status = "partial", fatal = aer_change(3),
            nonfatal = aer_change(0) } },
} } }
local aer_snapshot = Snapshot.merge(Snapshot.new(0, 0), {
    inventory = { status = "ok", quality = "fresh", timestamp_ns = 1000000000,
        data = aer_inventory },
}, 1, 1000000000)
local aer_agent = Export.agent(aer_snapshot)
local fatal_signal = signal_named(aer_agent, "pcie_aer_fatal")
local nonfatal_signal = signal_named(aer_agent, "pcie_aer_nonfatal")
assert(fatal_signal and fatal_signal.resource == "inventory"
    and fatal_signal.severity == "critical" and fatal_signal.value == nil,
    "a fatal AER increase yields a clue without a double-counted event total")
assert(nonfatal_signal and nonfatal_signal.severity == "warning"
    and nonfatal_signal.value == nil,
    "a nonfatal AER increase yields a warning without false attribution")
local fatal_count, nonfatal_count = 0, 0
for _, signal in ipairs(aer_agent.signals) do
    if signal.code == "pcie_aer_fatal" then fatal_count = fatal_count + 1 end
    if signal.code == "pcie_aer_nonfatal" then nonfatal_count = nonfatal_count + 1 end
end
assert(fatal_count == 1 and nonfatal_count == 1
    and aer_agent.overall.state == "critical",
    "device and root-port reports do not duplicate a signal")
local retained_aer = Snapshot.merge(aer_snapshot, {
    inventory = { status = "error", quality = "error", timestamp_ns = 100000000000 },
}, 2, 100000000000)
local retained_aer_agent = Export.agent(retained_aer)
assert(not signal_named(retained_aer_agent, "pcie_aer_fatal")
    and not signal_named(retained_aer_agent, "pcie_aer_nonfatal")
    and not signal_named(retained_aer_agent, "data_unavailable", "inventory"),
    "a retained AER delta is not a new event or a critical optional-source failure")
local retained_inventory_quality
for _, row in ipairs(retained_aer_agent.data_quality) do
    if row.resource == "inventory" then retained_inventory_quality = row end
end
assert(retained_inventory_quality and retained_inventory_quality.status == "error",
    "the optional inventory failure remains explicit in data_quality")
local stale_aer_agent = Export.agent({
    inventory = aer_inventory,
    quality = { inventory = { status = "ok", quality = "stale" } },
})
assert(not signal_named(stale_aer_agent, "pcie_aer_fatal")
    and not signal_named(stale_aer_agent, "data_stale", "inventory"),
    "an explicitly stale optional inventory cannot replay an AER signal or mark host health")
local gap_aer = Export.agent({ inventory = { pci = { devices = {
    { address = "0000:00:01.0", aer = {
        fatal = aer_change(nil, "gap"),
        nonfatal = aer_change(nil, "reset"),
        correctable = aer_change(100),
    } },
} } } })
assert(not signal_named(gap_aer, "pcie_aer_fatal")
    and not signal_named(gap_aer, "pcie_aer_nonfatal"),
    "first/reset samples and new correctable reports do not assert hardware failure")
local root_only = Export.agent({ inventory = { pci = { devices = {
    { address = "0000:00:01.0", aer = { rootport = { changes = {
        fatal = { new_reports = 1, quality = "fresh" },
    } } } },
} } } })
assert(signal_named(root_only, "pcie_aer_fatal"),
    "a root-port report is visible even when the endpoint reported none")

-- Hardware diagnostics and elective providers can be missing on a healthy
-- non-root host.  Their status belongs in data_quality, not in a critical
-- overall verdict.  Core CPU/memory/process failures still need a signal.
local optional_snapshot = {
    cpu = { total = { utilization = 30 } },
    memory = { total_bytes = 100, used_bytes = 40 },
    quality = {
        expansion_slots = { status = "denied", quality = "denied" },
        memory_devices = { status = "denied", quality = "denied" },
        processor_firmware = { status = "denied", quality = "denied" },
        edac = { status = "unavailable", quality = "unavailable" },
        gpus = { status = "ok", quality = "partial" },
        cpu_frequency = { status = "ok", quality = "estimated" },
        spd = { status = "ok", quality = "partial" },
    },
}
local optional_only = Export.agent(optional_snapshot)
assert(optional_only.overall.state == "ok" and #optional_only.signals == 0,
    "missing optional hardware cannot make a healthy host critical or stale")
assert(TUI.alert_count(optional_snapshot) == 0,
    "the TUI header cannot alarm on the optional sources Agent calls healthy")
assert(#optional_only.data_quality == 7
    and optional_only.data_quality[1].resource == "cpu_frequency",
    "optional-source quality remains machine-readable")
local failed_core = Export.agent({
    cpu = { total = { utilization = 98 } },
    quality = { cpu = { status = "error", quality = "stale" } },
})
assert(failed_core.overall.state == "critical"
    and signal_named(failed_core, "data_unavailable", "cpu")
    and not signal_named(failed_core, "high_utilization"),
    "failed core monitoring stays critical without alarming on retained numbers")
assert(TUI.alert_count({
    memory = { total_bytes = 100, used_bytes = 99 },
    quality = { memory = { status = "error", quality = "stale" } },
}) == 1,
    "the TUI counts a core failure once, not again through its retained high value")
assert(TUI.alert_count({
    memory = { total_bytes = 100, used_bytes = 99 },
    quality = { memory = { status = "ok", quality = "fresh" } },
}) == 1, "a current high memory reading still reaches the header")
for _, resource in ipairs({ "cpu", "memory", "processes" }) do
    local failed = Export.agent({
        quality = { [resource] = { status = "denied", quality = "denied" } },
    })
    local signal = signal_named(failed, "data_unavailable", resource)
    assert(signal and signal.severity == "critical",
        "core monitoring denial must remain critical: " .. resource)
end
for _, resource in ipairs({ "disks", "network", "mounts", "system" }) do
    local failed = Export.agent({
        quality = { [resource] = { status = "error", quality = "error" } },
    })
    local signal = signal_named(failed, "data_unavailable", resource)
    assert(signal and signal.severity == "warning",
        "supporting monitoring failure must remain a warning: " .. resource)
end
local failed_network = Export.agent({
    cpu = { total = { utilization = 30 } },
    quality = { network = { status = "denied", quality = "denied" } },
})
assert(failed_network.overall.state == "warning"
    and signal_named(failed_network, "data_unavailable", "network").severity == "warning",
    "a failed network source warns rather than claiming host-critical failure")
assert(TUI.alert_count({
    mounts = { mounts = { { kind = "local", quality = "stale",
        capacity = { used_percent = 99 } } } },
    quality = { mounts = { status = "ok", quality = "fresh" } },
}) == 0, "a stale mount row cannot make an old capacity alarm current")
assert(TUI.alert_count({
    mounts = { mounts = { { kind = "local", quality = "fresh",
        capacity = { used_percent = 99 } } } },
    quality = { mounts = { status = "ok", quality = "fresh" } },
}) == 1, "a current high local mount remains actionable")
local missing_rate = Export.agent({
    cpu = { total = { utilization = 30 } },
    quality = { cpu = { status = "ok", quality = "gap" } },
})
assert(signal_named(missing_rate, "data_gap", "cpu")
    and not signal_named(missing_rate, "data_stale", "cpu"),
    "a missing core rate is a gap, not an old retained value")
local partial_core = Export.agent({
    cpu = { total = { utilization = 30 } },
    quality = { cpu = { status = "ok", quality = "partial" } },
})
assert(signal_named(partial_core, "data_incomplete", "cpu")
    and not signal_named(partial_core, "data_stale", "cpu"),
    "current but incomplete core data is not mislabeled stale")

return true
