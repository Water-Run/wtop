package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

-- The macOS and Windows collectors turn native counters into the Linux
-- Snapshot contract. These fixtures stand in for the native module so the
-- derivation runs on any development host.
local Portable = require("wtop.collectors.portable")

local function close(actual, expected, tolerance, message)
    assert(type(actual) == "number", message .. ": expected a number, got " .. tostring(actual))
    assert(math.abs(actual - expected) <= tolerance,
        string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function equal(actual, expected, message)
    assert(actual == expected,
        string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

-- Each call to a collect_* function returns the next queued value.
local function fake_native(queues)
    local native = { realtime_ns = function() return queues.realtime_ns or 0 end }
    for name, values in pairs(queues) do
        if type(values) == "table" then
            local index = 0
            native[name] = function()
                index = index + 1
                return values[math.min(index, #values)]
            end
        end
    end
    return native
end

local function collectors(native)
    return Portable.new_all({ common = { native = native } })
end

local function at(nanoseconds)
    return { now_ns = function() return nanoseconds end }
end

-- ---------------------------------------------------------------------------
-- Probing: a missing native method is reported, not faked.
-- ---------------------------------------------------------------------------

local sparse = collectors(fake_native({ collect_cpu = { { raw = { busy = 0, total = 0 } } } }))
equal(sparse.cpu:probe().state, "available", "native CPU collector is available")
equal(sparse.connections:probe().state, "unavailable", "missing connections method")
local missing = sparse.connections:sample(at(1))
equal(missing.status, "unavailable", "missing method yields unavailable")
equal(missing.reason, "unsupported_on_this_platform", "missing method reason")
equal(sparse.gpu:sample(at(1)).status, "unavailable", "GPU has no portable backend")

-- A native failure surfaces its reason instead of an empty frame.
local failing = collectors({
    collect_memory = function() return nil, "GlobalMemoryStatusEx failed" end,
})
local failed_memory = failing.memory:sample(at(1))
equal(failed_memory.status, "unavailable", "native failure status")
equal(failed_memory.reason, "GlobalMemoryStatusEx failed", "native failure reason")

-- ---------------------------------------------------------------------------
-- CPU: totals and per-core utilization come from counter deltas.
-- ---------------------------------------------------------------------------

local cpu = collectors(fake_native({ collect_cpu = {
    { raw = { busy = 100, total = 1000 }, cores = {
        { name = "cpu0", raw = { busy = 50, total = 500 } },
        { name = "cpu1", raw = { busy = 50, total = 500 } } } },
    { raw = { busy = 400, total = 2000 }, cores = {
        { name = "cpu0", raw = { busy = 300, total = 1000 } },
        { name = "cpu1", raw = { busy = 100, total = 1000 } } } },
} })).cpu
local cpu_first = cpu:sample(at(0))
equal(cpu_first.quality, "gap", "first CPU sample has no interval")
equal(cpu_first.data.total.utilization, nil, "first CPU sample has no utilization")
local cpu_second = cpu:sample(at(1000000000), cpu_first)
equal(cpu_second.quality, "fresh", "second CPU sample is fresh")
close(cpu_second.data.total.utilization, 30, 1e-9, "300 of 1000 ticks busy")
close(cpu_second.data.cores[1].utilization, 50, 1e-9, "cpu0 utilization")
close(cpu_second.data.cores[2].utilization, 10, 1e-9, "cpu1 utilization")

-- ---------------------------------------------------------------------------
-- Processes: identity, PID maps, CPU share, first-frame estimate, denial.
-- ---------------------------------------------------------------------------

-- 2026-01-01T00:00:00Z as a Windows FILETIME and in Unix nanoseconds.
local unix_ns = 1767225600 * 1000000000
local filetime = (1767225600 + 11644473600) * 10000000
local process_native = fake_native({
    realtime_ns = unix_ns,
    collect_process = {
        { starttime_unit = "filetime", clock_ticks_per_second = 100, list = {
            -- Started 100 s before the sample and used 20 s of CPU.
            { pid = 10, parent_pid = 4, name = "service.exe",
              starttime_ticks = filetime - 100 * 10000000, cpu_ticks = 2000 },
            { pid = 11, parent_pid = 10, name = "worker.exe", id = "pid:11",
              partial = true, partial_reason = "query_denied" },
        }, denied = 1 },
        { starttime_unit = "filetime", clock_ticks_per_second = 100, list = {
            { pid = 10, parent_pid = 4, name = "service.exe",
              starttime_ticks = filetime - 100 * 10000000, cpu_ticks = 2050 },
        }, denied = 0 },
    },
})
local processes = collectors(process_native).process
local process_first = processes:sample(at(0))
local service = process_first.data.by_pid[10]
assert(service, "processes are indexed by PID")
equal(service.id, "10:" .. tostring(filetime - 100 * 10000000), "identity joins PID and start time")
equal(process_first.data.by_id[service.id], service, "processes are indexed by identity")
equal(service.quality, "estimated", "first frame uses the lifetime average")
close(service.cpu_percent, 20, 1e-6, "20 s of CPU over 100 s is 20%")
equal(process_first.data.by_pid[11].quality, "gap", "a denied process has no CPU value")
equal(process_first.quality, "partial", "a denied process makes the sample partial")
local process_second = processes:sample(at(500000000), process_first)
equal(process_second.quality, "fresh", "a complete second sample is fresh")
equal(process_second.data.by_pid[10].quality, "fresh", "interval CPU is fresh")
close(process_second.data.by_pid[10].cpu_percent, 100, 1e-6, "50 ticks in 0.5 s is one full core")

-- A reused PID with a new start time is a new process, not a CPU delta.
local reused = collectors(fake_native({ collect_process = {
    { list = { { pid = 20, starttime_ticks = 1, cpu_ticks = 900 } } },
    { list = { { pid = 20, starttime_ticks = 2, cpu_ticks = 5 } } },
} })).process
local reused_first = reused:sample(at(0))
local reused_second = reused:sample(at(1000000000), reused_first)
equal(reused_second.data.by_pid[20].quality, "gap", "a reused PID starts without a delta")

-- ---------------------------------------------------------------------------
-- Network: 32-bit XP counters wrap; 64-bit counters do not pretend to.
-- ---------------------------------------------------------------------------

local wrap = collectors(fake_native({ collect_network = {
    { counter_bits = 32, interfaces = { { id = 1, name = "eth", counters = {
        rx_bytes = 4294967000, tx_bytes = 10 } } } },
    { counter_bits = 32, interfaces = { { id = 1, name = "eth", counters = {
        rx_bytes = 704, tx_bytes = 1010 } } } },
} })).network
local wrap_first = wrap:sample(at(0))
equal(wrap_first.quality, "gap", "first network sample has no rate")
local wrap_second = wrap:sample(at(1000000000), wrap_first)
close(wrap_second.data.interfaces[1].rates.rx_bytes_per_second, 1000, 1e-9,
    "a wrapped 32-bit counter still yields its true rate")
close(wrap_second.data.interfaces[1].tx_bytes_per_second, 1000, 1e-9, "transmit rate")

local reset = collectors(fake_native({ collect_network = {
    { counter_bits = 64, interfaces = { { id = 1, name = "eth", counters = {
        rx_bytes = 5000, tx_bytes = 5000 } } } },
    { counter_bits = 64, interfaces = { { id = 1, name = "eth", counters = {
        rx_bytes = 10, tx_bytes = 10 } } } },
} })).network
local reset_second = reset:sample(at(1000000000), reset:sample(at(0)))
equal(reset_second.data.interfaces[1].rates.rx_bytes_per_second, nil,
    "a 64-bit counter going backwards is a reset, not a wrap")
equal(reset_second.quality, "gap", "a reset interface is a gap")

-- ---------------------------------------------------------------------------
-- Disks: throughput, IOPS, latency, and busy time against the real interval.
-- ---------------------------------------------------------------------------

local disk = collectors(fake_native({ collect_disk = {
    { devices = { { id = "PhysicalDrive0", name = "PhysicalDrive0", counters = {
        bytes_read = 0, bytes_written = 0, reads = 0, writes = 0,
        read_time_ns = 0, write_time_ns = 0, idle_time_ns = 0 } } } },
    { devices = { { id = "PhysicalDrive0", name = "PhysicalDrive0", counters = {
        bytes_read = 4096 * 100, bytes_written = 8192, reads = 100, writes = 2,
        read_time_ns = 100 * 2000000, write_time_ns = 2 * 5000000,
        idle_time_ns = 750000000 } } } },
} })).disk
local disk_first = disk:sample(at(0))
equal(disk_first.quality, "gap", "first disk sample has no rate")
local drive = disk:sample(at(1000000000), disk_first).data.devices[1]
equal(drive.quality, "fresh", "second disk sample is fresh")
close(drive.read_bytes_per_second, 409600, 1e-6, "read throughput")
close(drive.write_bytes_per_second, 8192, 1e-6, "write throughput")
close(drive.read_iops, 100, 1e-9, "read IOPS")
close(drive.average_read_latency_ms, 2, 1e-9, "read latency")
close(drive.average_write_latency_ms, 5, 1e-9, "write latency")
close(drive.busy_percent, 25, 1e-9, "750 ms idle in 1 s is 25% busy")

-- A disk without idle accounting (macOS) reports no busy figure at all.
local no_idle = collectors(fake_native({ collect_disk = {
    { devices = { { id = "disk0", counters = { bytes_read = 0, bytes_written = 0,
        reads = 0, writes = 0 } } } },
    { devices = { { id = "disk0", counters = { bytes_read = 10, bytes_written = 0,
        reads = 1, writes = 0 } } } },
} })).disk
local mac_drive = no_idle:sample(at(1000000000), no_idle:sample(at(0))).data.devices[1]
equal(mac_drive.busy_percent, nil, "busy time is not invented without idle counters")
equal(mac_drive.average_read_latency_ms, nil, "latency needs a time counter")

-- ---------------------------------------------------------------------------
-- IPv6 text follows RFC 5952.
-- ---------------------------------------------------------------------------

local function bytes(...)
    local values = { ... }
    local out = {}
    for index = 1, 8 do
        local group = values[index] or 0
        out[#out + 1] = string.char(group >> 8, group & 0xff)
    end
    return table.concat(out)
end
equal(Portable.format_ipv6(bytes()), "::", "unspecified address")
equal(Portable.format_ipv6(bytes(0, 0, 0, 0, 0, 0, 0, 1)), "::1", "loopback")
equal(Portable.format_ipv6(bytes(0xfe80, 0, 0, 0, 0x1, 0x2, 0x3, 0x4)), "fe80::1:2:3:4",
    "leading run")
equal(Portable.format_ipv6(bytes(0x2001, 0xdb8, 0, 0, 1, 0, 0, 1)), "2001:db8::1:0:0:1",
    "the first of two equal zero runs is compressed")
equal(Portable.format_ipv6(bytes(0x2001, 0xdb8, 0, 1, 1, 1, 1, 1)), "2001:db8:0:1:1:1:1:1",
    "a single zero group is not compressed")
equal(Portable.format_ipv6("short"), nil, "wrong length is rejected")

-- ---------------------------------------------------------------------------
-- Connections: Windows socket tables become Linux-shaped rows.
-- ---------------------------------------------------------------------------

local loopback6 = bytes(0, 0, 0, 0, 0, 0, 0, 1)
local sockets = collectors(fake_native({ collect_connections = { {
    owners_available = true,
    connections = {
        { protocol = "tcp", family = "ipv4", local_address = "10.0.0.2", local_port = 50000,
          remote_address = "93.184.216.34", remote_port = 443, tcp_state = 5,
          pid = 300, owner_name = "browser.exe" },
        { protocol = "tcp", family = "ipv4", local_address = "0.0.0.0", local_port = 22,
          remote_address = "0.0.0.0", remote_port = 0, tcp_state = 2,
          pid = 200, owner_name = "sshd.exe" },
        { protocol = "tcp", family = "ipv4", local_address = "0.0.0.0", local_port = 22,
          remote_address = "0.0.0.0", remote_port = 0, tcp_state = 2,
          pid = 201, owner_name = "sshd.exe" },
        { protocol = "tcp", family = "ipv6", local_address_bytes = loopback6, local_port = 8080,
          remote_address_bytes = bytes(), remote_port = 0, tcp_state = 2 },
        { protocol = "udp", family = "ipv4", local_address = "0.0.0.0", local_port = 53,
          pid = 400, owner_name = "dns.exe" },
        { protocol = "tcp", family = "ipv4", local_port = 1 }, -- no address: dropped
    },
} } })).connections
local table_sample = sockets:sample(at(1))
local tables = table_sample.data
equal(tables.total, 5, "valid rows are kept")
equal(table_sample.quality, "partial", "a malformed row makes the table partial")
equal(tables.counts.tcp, 3, "IPv4 TCP count")
equal(tables.counts.tcp6, 1, "IPv6 TCP count")
equal(tables.counts.udp, 1, "UDP count")
equal(tables.owner_scan.status, "ok", "owners come with the table")
local by_port = {}
for _, connection in ipairs(tables.connections) do
    by_port[connection.local_port] = by_port[connection.local_port] or connection
end
local established = by_port[50000]
equal(established.state, "ESTABLISHED", "MIB_TCP_STATE 5 is ESTABLISHED")
equal(established.state_code, "01", "Linux state code for ESTABLISHED")
equal(established.remote_endpoint.text, "93.184.216.34:443", "remote endpoint text")
equal(established.owners[1].name, "browser.exe", "owner name")
equal(established.owners_quality, "fresh", "owner quality")
equal(by_port[22].state, "LISTEN", "MIB_TCP_STATE 2 is LISTEN")
equal(by_port[8080].local_endpoint.text, "[::1]:8080", "IPv6 endpoints are bracketed")
equal(by_port[8080].remote_address, "::", "IPv6 unspecified remote")
equal(by_port[53].state, "CLOSE", "UDP sockets use the Linux unconnected state")
equal(by_port[53].remote_endpoint.text, "0.0.0.0:0", "UDP has an unspecified remote")
equal(tables.connections[1].table, "tcp", "IPv4 TCP sorts first")
equal(tables.connections[#tables.connections].table, "udp", "UDP sorts last")
local ids = {}
for _, connection in ipairs(tables.connections) do
    assert(not ids[connection.id], "connection IDs are unique: " .. connection.id)
    ids[connection.id] = true
    equal(tables.by_id[connection.id], connection, "connections are indexed by ID")
end
assert(ids["tcp:0.0.0.0:22:0.0.0.0:0:0A#2"], "a duplicate socket gets a numbered ID")

local ownerless = collectors(fake_native({ collect_connections = { {
    owners_available = false,
    connections = { { protocol = "tcp", family = "ipv4", local_address = "0.0.0.0",
        local_port = 80, remote_address = "0.0.0.0", remote_port = 0, tcp_state = 2 } },
} } })).connections:sample(at(1)).data
equal(ownerless.owner_scan.status, "unavailable", "pre-SP2 XP has no owner PIDs")
equal(ownerless.connections[1].owners_quality, "unavailable", "row owner quality")

return true
