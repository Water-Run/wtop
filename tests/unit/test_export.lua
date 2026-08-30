package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Export = require("wtop.export")
local json = require("wtop.format.json")

local private_connection_id = "tcp:127.0.0.1:8080:192.0.2.42:54321:01"
local result = Export.snapshot({
    sequence = 2,
    timestamp_ns = 10,
    quality = { cpu = { status = "ok", quality = "fresh" } },
    cpu = { total = { utilization = 33, counters = { should_not_leak = true } }, cores = {} },
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
            },
        },
    },
}, {
    process_limit = 1,
    configuration = {
        state = "error",
        reason = "invalid fixture",
        path = "/private/config/path",
    },
})

assert(result.schema == "dev.waterrun.wtop.snapshot/v1")
assert(result.configuration.state == "error")
assert(result.configuration.reason == "invalid fixture")
assert(result.configuration.path == nil)
assert(result.cpu.total.utilization == 33)
assert(result.cpu.total.counters == nil)
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
    memory = {
        total_bytes = 1000, used_bytes = 900, available_bytes = 100,
        swap_total_bytes = 100, swap_used_bytes = 20,
    },
    pressure = { cpu = { some = { avg10 = 6 } } },
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
    capabilities = {
        cpu = { available = true, state = "available" },
        gpu = { available = false, state = "unavailable", reason = "no DRM device" },
    },
})
assert(agent.schema == "dev.waterrun.wtop.agent/v1")
assert(agent.overall.state == "critical" and agent.overall.signal_count >= 2)
assert(agent.metrics.cpu.logical_cpus == 2)
assert(agent.metrics.memory.used_percent == 90)
assert(agent.metrics.network.receive_bytes_per_second == 30)
assert(agent.metrics.storage.read_bytes_per_second == 10)
assert(agent.overall.signal_count >= 3, "gap quality must produce an Agent warning")
assert(agent.top.processes[1].pid == 2 and agent.top.processes[1].command == nil)
assert(agent.top.disks[1].name == "sda")
assert(agent.unavailable_sources[1].id == "gpu")
local encoded_agent = json.encode(agent)
assert(encoded_agent:find('"schema":"dev.waterrun.wtop.agent/v1"', 1, true))
assert(not encoded_agent:find("secret --token", 1, true))

local bounded_agent = Export.agent({
    gpus = { devices = {
        { id = "slow", metrics = { utilization_percent = 1 } },
        { id = "fast", metrics = { utilization_percent = 99 } },
    } },
}, { device_limit = 1 })
assert(#bounded_agent.top.gpus == 1 and bounded_agent.top.gpus[1].id == "fast",
    "Agent GPU summaries must respect device_limit and retain the busiest device")
assert(bounded_agent.metrics.gpu.maximum_utilization_percent == 99)

return true
