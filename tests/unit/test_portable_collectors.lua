package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

-- The dispatcher publishes a reason for its degraded readings, and it is the
-- one collector where the reason column was guaranteed to be empty rather than
-- merely often empty: this is the whole collector on every macOS and Windows
-- host.  Both of its reasons are categories, measured across the seven
-- derivation helpers -- `gap` is set when a counter cannot be differenced
-- against the previous sample, for the CPU helper, an interface, a device or a
-- workload, and `partial` from three unrelated places, `data.partial` for
-- processes, a workload summary count, and a truncated scan.
--
-- Disk rates with an instance ID but no unique device identity now publish
-- `estimated` with their own reason. A lifetime-average estimate from another
-- source remains a separate case; its reason must not borrow that sentence.
local PORTABLE_REASON = { partial = "platform_data_partial",
  gap = "platform_rate_unavailable", estimated = "disk_identity_estimated", fresh = false }
local function portable_reason_is(result, label)
  return require("support.collector_reason").assert_reason(
    result, PORTABLE_REASON, label)
end

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

-- That last assertion is the shape a reason can legitimately take here, and it
-- is worth saying why the next one is different.  A native module's own failure
-- string arrives from the operating system and cannot be enumerated, so the
-- presentation layer shows it as it is.  A string *this project writes* cannot
-- be argued that way: it is a fixed set of words, it is rendered through
-- `Technical.reason`, and `docs/PLAN.md` once recorded an English sentence in
-- this very field with the note that the path could not be exercised here.  That
-- note was wrong -- this collector is driven by a fake native module on every
-- host, so the case is one line of fixture -- and the sentence was real.
--
-- `cpu_data` returned `(nil, "missing CPU counters")` for a payload with no
-- `raw` table, and the caller assigned that second value to a variable named
-- `quality` and published it as `reason`, so one return slot was carrying a
-- quality word on the success path and a sentence on the failure path.
local shapeless = collectors(fake_native({ collect_cpu = { { busy = 1, total = 2 } } })).cpu
local shapeless_result = shapeless:sample(at(1))
equal(shapeless_result.status, "error", "a payload the derivation cannot read fails")
equal(shapeless_result.reason, "cpu_counters_missing",
  "the reason is a code, not a sentence: this field is rendered through "
    .. "`Technical.reason`, which has a translation for a code and none for prose")
equal(shapeless_result.data, nil, "and there is nothing to report")
-- The shape is checked rather than the string, because a sentence satisfies both
-- clauses: it is a string, and it differs from the code.  What a sentence fails
-- is the inventory, and that is a separate guard -- a code that is not
-- translated reaches nine of ten users as a raw token, which is the same defect
-- in a different dress.
assert(type(shapeless_result.reason) == "string"
    and not shapeless_result.reason:find("%s"), 
  "a reason written by this project must be a single code with no spaces in it; "
    .. "got " .. string.format("%q", tostring(shapeless_result.reason))
    .. ", which renders untranslated in every catalogue")
-- The success path is checked in the CPU section below, and it is the other half
-- of the same change: the second return used to be published as a reason when the
-- data was absent and as a quality when it was present, so a payload that derives
-- nothing used to report a description of a reading that did not exist.

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
portable_reason_is(cpu_first, "the first CPU sample")
equal(cpu_first.data.total.utilization, nil, "first CPU sample has no utilization")
local cpu_second = cpu:sample(at(1000000000), cpu_first)
equal(cpu_second.quality, "fresh", "second CPU sample is fresh")
portable_reason_is(cpu_second, "the second CPU sample")
close(cpu_second.data.total.utilization, 30, 1e-9, "300 of 1000 ticks busy")
close(cpu_second.data.cores[1].utilization, 50, 1e-9, "cpu0 utilization")
close(cpu_second.data.cores[2].utilization, 10, 1e-9, "cpu1 utilization")

-- Mach exposes one unsigned 32-bit counter for each time class. A wrap in
-- user/idle must be resolved before summing, against the same CPU identity.
local function mach_cpu(user, system, nice, idle, epoch, instance, online)
    local raw = { user = user, system = system, nice = nice, idle = idle,
        busy = user + system + nice, total = user + system + nice + idle }
    return { raw = raw, counter_bits = 32, _source_epoch = epoch or "mach:1",
        cores = { { id = 7, name = "cpu7", online = online ~= false,
            _source_instance = instance or "mach:7:7:3", raw = raw } } }
end
local mach_before = mach_cpu(4294967285, 100, 6, 4294967275)
local mach_after = mach_cpu(9, 110, 11, 44)
local mach = collectors(fake_native({ collect_cpu = { mach_before, mach_after } })).cpu
local mach_first = mach:sample(at(0))
local mach_second = mach:sample(at(1000000000), mach_first)
equal(mach_second.quality, "fresh", "wrapped Mach time classes stay fresh")
close(mach_second.data.total.utilization, 35, 1e-9, "independently wrapped aggregate ticks")
close(mach_second.data.cores[1].user, 20, 1e-9, "wrapped per-core user ticks")
close(mach_second.data.cores[1].system, 10, 1e-9, "unwrapped per-core system ticks")
close(mach_second.data.cores[1].nice, 5, 1e-9, "unwrapped per-core nice ticks")

local function mach_pair(first, second)
    local source = collectors(fake_native({ collect_cpu = { first, second } })).cpu
    return source:sample(at(1000000000), source:sample(at(0)))
end
local changed_roster = mach_pair(mach_cpu(100, 10, 0, 100),
    mach_cpu(120, 20, 0, 170, "mach:2"))
equal(changed_roster.data.total.utilization, nil, "a changed roster resets aggregate ticks")
equal(changed_roster.data.cores[1].utilization, 30, "an unchanged logical CPU retains its baseline")
local changed_type = mach_pair(mach_cpu(100, 10, 0, 100),
    mach_cpu(120, 20, 0, 170, "mach:2", "mach:7:7:4"))
equal(changed_type.data.cores[1].quality, "gap", "a changed Mach subtype resets the slot baseline")
equal(changed_type.data.cores[1].utilization, nil, "replacement identity has no inherited utilization")
local offline = mach_pair(mach_cpu(100, 10, 0, 100),
    mach_cpu(120, 20, 0, 170, "mach:2", nil, false))
equal(offline.data.cores[1].quality, "unavailable", "an offline logical CPU has no current reading")
equal(offline.data.cores[1].utilization, nil, "offline counters do not become current utilization")
local online = mach_pair(mach_cpu(100, 10, 0, 100, "mach:1", nil, false),
    mach_cpu(120, 20, 0, 170, "mach:2"))
equal(online.data.cores[1].quality, "gap", "returning online requires a new interval")
for _, invalid in ipairs({ -1, 4294967296, 0.5, math.huge, 0/0, "100" }) do
    local bad = mach_cpu(120, 20, 0, 170)
    bad.raw.user = invalid
    local result = mach_pair(mach_cpu(100, 10, 0, 100), bad)
    equal(result.data.total.utilization, nil, "invalid Mach ticks cannot produce utilization")
    equal(result.data.cores[1].quality, "gap", "invalid Mach time class is a gap")
end
local missing_class = mach_cpu(120, 20, 0, 170)
missing_class.raw.idle = nil
equal(mach_pair(mach_cpu(100, 10, 0, 100), missing_class).quality, "gap",
    "32-bit counters without every time class cannot infer a wrapped sum")
local partial_cpu = mach_cpu(120, 20, 0, 170)
partial_cpu.partial = true
equal(mach_pair(mach_cpu(100, 10, 0, 100), partial_cpu).quality, "partial",
    "a native partial roster remains visible to the scheduler")
local narrower = mach_cpu(120, 20, 0, 170)
narrower.counter_bits = nil
equal(mach_pair(mach_cpu(100, 10, 0, 100), narrower).data.total.utilization, nil,
    "changing the counter representation starts a new baseline")

local function wide_cpu(busy, total, user, system)
    local raw = { busy = busy, total = total, user = user, system = system }
    return { raw = raw, counter_bits = 64, cores = { { name = "cpu0", raw = raw } } }
end
local wide = collectors(fake_native({ collect_cpu = {
    wide_cpu(0, 0, 0, 0), wide_cpu(1 << 61, 1 << 62, 1 << 60, 1 << 60),
} })).cpu
local wide_second = wide:sample(at(1000000000), wide:sample(at(0)))
close(wide_second.data.total.utilization, 50, 1e-9, "large 64-bit CPU deltas avoid integer multiplication overflow")
close(wide_second.data.cores[1].user, 25, 1e-9, "large 64-bit user time avoids overflow")
close(wide_second.data.cores[1].system, 25, 1e-9, "large 64-bit system time avoids overflow")
local wide_reset = collectors(fake_native({ collect_cpu = {
    wide_cpu(100, 1000, 100, 0), wide_cpu(1, 10, 1, 0),
} })).cpu
equal(wide_reset:sample(at(1000000000), wide_reset:sample(at(0))).data.total.utilization, nil,
    "64-bit Windows counters going backwards do not invent a wrap")

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
close(service.elapsed_seconds, 100, 1e-3, "FILETIME creation produces process age")
equal(process_first.data.by_pid[11].quality, "gap", "a denied process has no CPU value")
equal(process_first.quality, "partial", "a denied process makes the sample partial")
portable_reason_is(process_first, "a sample with a denied process")
local process_second = processes:sample(at(500000000), process_first)
equal(process_second.quality, "fresh", "a complete second sample is fresh")
portable_reason_is(process_second, "a complete process sample")
equal(process_second.data.by_pid[10].quality, "fresh", "interval CPU is fresh")
close(process_second.data.by_pid[10].cpu_percent, 100, 1e-6, "50 ticks in 0.5 s is one full core")
close(process_first.data.by_pid[10].cpu_time_seconds, 20, 1e-9,
    "portable process CPU time is published in seconds")
local unusual_ticks = collectors(fake_native({ collect_process = {
    { clock_ticks_per_second = 250, list = {
        { pid = 30, starttime_ticks = 1, cpu_ticks = 375 },
    } },
} })).process:sample(at(0))
close(unusual_ticks.data.by_pid[30].cpu_time_seconds, 1.5, 1e-9,
    "portable CPU time uses the provider's tick rate")
local mac_age = collectors(fake_native({ realtime_ns = unix_ns,
    collect_process = { { starttime_unit = "unix_us", list = {
        { pid = 31, starttime_ticks = unix_ns // 1000 - 30000000, cpu_ticks = 0 },
    } } },
})).process:sample(at(0))
close(mac_age.data.by_pid[31].elapsed_seconds, 30, 1e-3,
    "microsecond Unix creation time produces process age")

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
portable_reason_is(wrap_first, "the first network sample")
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
portable_reason_is(disk_first, "the first disk sample")
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

-- Numbered Windows disks may be replaced while the new counters are larger
-- than the old ones. Identity, not counter monotonicity, decides continuity.
do
    local samples = {}
    for index, id in ipairs({ "epoch-A", "epoch-B", "epoch-B" }) do
        samples[index] = { devices = { { id = "PhysicalDrive0", stable_id = id,
            identity_quality = "stable", counters = { bytes_read = index * 1000,
                bytes_written = index * 200, reads = index * 10, writes = index } } } }
    end
    local source = collectors(fake_native({ collect_disk = samples })).disk
    local first = source:sample(at(0))
    local replaced = source:sample(at(1000000000), first)
    equal(replaced.data.devices[1].read_bytes_per_second, nil,
        "a reused disk number cannot inherit the old device's rate")
    equal(replaced.quality, "gap", "replacement starts a new rate baseline")
    local next_sample = source:sample(at(2000000000), replaced)
    equal(next_sample.data.devices[1].read_bytes_per_second, 1000,
        "a second sample of the new identity restores throughput")
    local weak = collectors(fake_native({ collect_disk = {
        { devices = { { id = "PhysicalDrive0", stable_id = "epoch-C", identity_quality = "instance",
            counters = { bytes_read = 0, bytes_written = 0, reads = 0, writes = 0 } } } },
        { devices = { { id = "PhysicalDrive0", stable_id = "epoch-C", identity_quality = "instance",
            counters = { bytes_read = 10, bytes_written = 0, reads = 1, writes = 0 } } } },
    } })).disk
    local estimate = weak:sample(at(1000000000), weak:sample(at(0)))
    equal(estimate.data.devices[1].read_bytes_per_second, 10,
        "legacy devices still expose measured counters")
    equal(estimate.quality, "estimated", "weak identity is visible beside the rate")
    portable_reason_is(estimate, "disk identity without a unique device ID")
    local incomplete = collectors(fake_native({ collect_disk = {
        { quality = "partial", devices = {} },
    } })).disk:sample(at(0))
    equal(incomplete.quality, "partial", "native disk enumeration errors survive derivation")
end

-- IOKit driver counters can outlive a removable medium, and either instance
-- can change while the BSD name stays the same and the new counters grow.
do
    local samples = {}
    for index, epoch in ipairs({ "ioreg:10:20", "ioreg:10:21", "ioreg:10:21",
        "ioreg:11:21", "ioreg:11:21" }) do
        samples[index] = { devices = { { name = "disk0", id = "disk0", stable_id = epoch,
            identity_quality = "stable", counters = { bytes_read = index * 100,
                bytes_written = index * 20, reads = index * 10, writes = index,
                service_time_ns = index * 250000000 } } } }
    end
    local source = collectors(fake_native({ collect_disk = samples })).disk
    local previous
    for index = 1, #samples do
        local sample = source:sample(at(index * 1000000000), previous)
        local device = sample.data.devices[1]
        if index == 3 or index == 5 then
            equal(device.read_bytes_per_second, 100, "the same driver and medium restore throughput")
            equal(device.busy_percent, 25, "request service time estimates busy time")
            equal(device.busy_quality, "estimated", "parallel service time is not exact wall-clock busy time")
        else
            equal(device.read_bytes_per_second, nil, "a replaced driver or medium resets the BSD disk baseline")
        end
        previous = sample
    end
    previous.data.devices[1].partial = true
    local incomplete = source:sample(at(6000000000), previous)
    equal(incomplete.quality, "partial", "a partial native row stays partial during derivation")
    equal(incomplete.data.devices[1].quality, "partial", "the row cannot be labelled fresh")
end

-- Interface indexes can be recycled, including while XP counters wrap.
do
    local entries = {}
    for index, specification in ipairs({ { "ioreg:10", 64, 100 },
        { "ioreg:10", 64, 200 }, { "ioreg:11", 64, 300 }, { "ioreg:11", 64, 400 } }) do
        entries[index] = { interfaces = {
            { id = "en0", name = "en0", ifindex = 7, _registry_entry_id = specification[1],
              counter_bits = specification[2], counters = { rx_bytes = specification[3], tx_bytes = specification[3] } },
            { id = "en1", name = "en1", ifindex = 8, counter_bits = index == 1 and 32 or 64,
              counters = { rx_bytes = index * 100, tx_bytes = index * 100 } },
        } }
    end
    local source = collectors(fake_native({ collect_network = entries })).network
    local first = source:sample(at(0))
    local second = source:sample(at(1000000000), first)
    equal(second.data.interfaces[1].rx_bytes_per_second, 100,
        "another interface's fallback width does not reset a wide interface")
    equal(second.data.interfaces[2].rx_bytes_per_second, nil,
        "only the interface that changed width starts a new baseline")
    local third = source:sample(at(2000000000), second)
    equal(third.data.interfaces[1].rx_bytes_per_second, nil,
        "IOKit instance replacement resets counters even with the same name and index")
    local fourth = source:sample(at(3000000000), third)
    equal(fourth.data.interfaces[1].rx_bytes_per_second, 100,
        "a second sample of the new registry instance restores rates")
    local software = collectors(fake_native({ collect_network = {
        { interfaces = { { id = "utun0", ifindex = 20, _interface_last_change = "1:0",
            counter_bits = 64, counters = { rx_bytes = 100, tx_bytes = 100 } } } },
        { interfaces = { { id = "utun0", ifindex = 20, _interface_last_change = "2:0",
            counter_bits = 64, counters = { rx_bytes = 300, tx_bytes = 300 } } } },
    } })).network
    local changed = software:sample(at(1000000000), software:sample(at(0)))
    equal(changed.data.interfaces[1].rx_bytes_per_second, nil,
        "a software interface transition cannot carry a previous epoch")
end

do
    local entries = {}
    for index, spec in ipairs({ { "GUID-A", "PCI-A", 4000 }, { "GUID-B", "PCI-B", 100 },
        { "GUID-B", "PCI-B", 150 }, { "GUID-B", "PCI-C", 200 } }) do
        entries[index] = { counter_bits = 32, interfaces = { {
            id = 10, name = index == 3 and "Renamed" or "Ethernet",
            _interface_guid = spec[1], _pnp_instance_id = spec[2],
            counters = { rx_bytes = spec[3], tx_bytes = spec[3] },
        } } }
    end
    local source = collectors(fake_native({ collect_network = entries })).network
    local first = source:sample(at(0))
    local reused = source:sample(at(1000000000), first)
    equal(reused.data.interfaces[1].rates.rx_bytes_per_second, nil,
        "a new interface GUID cannot look like a 32-bit wrap of the old adapter")
    local renamed = source:sample(at(2000000000), reused)
    equal(renamed.data.interfaces[1].rates.rx_bytes_per_second, 50,
        "renaming a verified interface keeps its counter baseline")
    local replaced = source:sample(at(3000000000), renamed)
    equal(replaced.data.interfaces[1].rates.rx_bytes_per_second, nil,
        "a new PnP instance cannot reuse the previous adapter's counters")
    local denied = collectors(fake_native({ collect_network = { {
        quality = "partial", interfaces = {},
    } } })).network:sample(at(0))
    equal(denied.quality, "partial", "network discovery errors survive rate derivation")
    local switched = collectors(fake_native({ collect_network = {
        { counter_bits = 64, interfaces = { { id = 10, counters = { rx_bytes = 10, tx_bytes = 10 } } } },
        { counter_bits = 32, interfaces = { { id = 10, counters = { rx_bytes = 20, tx_bytes = 20 } } } },
    } })).network
    local fallback = switched:sample(at(1000000000), switched:sample(at(0)))
    equal(fallback.data.interfaces[1].rates.rx_bytes_per_second, nil,
        "changing between modern and legacy counter tables resets the baseline")
end

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
portable_reason_is(table_sample, "a socket table with a malformed row")
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
-- A counted zero is a count; where the lookup did not run there is no count to
-- publish, and saying "this socket has no owner" next to "owner data is
-- unavailable" contradicts the record it sits in.
equal(established.owner_count, 1, "a socket with one owner reports one owner")
equal(by_port[8080].owner_count, 0,
  "a scanned socket the lookup found nothing for reports a counted zero")
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
equal(ownerless.connections[1].owner_count, nil,
  "a backend that could not look up owners does not report that there are none")

-- Portable hwmon data has direct native inputs but no Linux readings.input
-- table. Stable device IDs and channel labels allow the same session model.
local function thermal(value, label, quality, source)
  return { devices = { {
    id = "acpi_thermal_zones", class = "acpi_thermal_zones",
    name = "ACPI thermal zone", identity_quality = "fresh",
    quality = "fresh", source = "pdh:Thermal Zone Information",
    channels = { { id = "temp1", type = "temperature", unit = "celsius",
      label = label or "TZ0", input = value, input_source = source or "pdh",
      quality = quality or "fresh" } },
  } } }
end
local portable_hwmon = collectors(fake_native({ collect_hwmon = {
  thermal(40), thermal(44), thermal(47, nil, "estimated"),
  thermal(50, "Another zone"), thermal(52, "Another zone", "fresh", "average"),
} })).hwmon
local thermal_first = portable_hwmon:sample(at(1000000000))
local thermal_second = portable_hwmon:sample(at(2000000000), thermal_first)
local session = thermal_second.data.devices[1].channels[1].session
equal(session.samples, 2, "portable direct input accumulates across samples")
close(session.minimum, 40, 1e-9, "portable session minimum")
close(session.average, 42, 1e-9, "portable session average")
close(session.maximum, 44, 1e-9, "portable session maximum")
local portable_export = require("wtop.export").snapshot({ sensors = thermal_second.data })
equal(portable_export.sensors.devices[1].channels[1].session.samples, 2,
  "portable session statistics reach Snapshot JSON")
local estimated_thermal = portable_hwmon:sample(at(3000000000), thermal_second)
equal(estimated_thermal.data.devices[1].channels[1].session.samples, 2,
  "an estimated native input does not enter direct statistics")
local stale_payload = thermal(47)
stale_payload.quality = "stale"
local stale_thermal = collectors({
  collect_hwmon = function() return stale_payload end,
}).hwmon:sample(at(3000000000), thermal_second)
equal(stale_thermal.data.devices[1].channels[1].session.samples, 2,
  "a stale native collector value does not become another direct sample")
local stale_device = thermal(47)
stale_device.devices[1].quality = "stale"
local held_native_device = collectors({
  collect_hwmon = function() return stale_device end,
}).hwmon:sample(at(3000000000), thermal_second)
equal(held_native_device.data.devices[1].channels[1].session.samples, 2,
  "a stale native device does not increment the session even if its channel says fresh")
local relabeled_thermal = portable_hwmon:sample(at(4000000000), estimated_thermal)
equal(relabeled_thermal.data.devices[1].channels[1].session.samples, 1,
  "a changed native channel label starts a new series")
local substituted_thermal = portable_hwmon:sample(at(5000000000), relabeled_thermal)
equal(substituted_thermal.data.devices[1].channels[1].session.samples, 1,
  "a native average substituted for input is not counted")

local function hid(value)
  return { devices = { { id = "hid:Thermal", class = "hid:Thermal",
    name = "Thermal", source = "iohid", identity_quality = "fresh",
    quality = "fresh",
    channels = { { id = "temperature1", type = "temperature",
      unit = "celsius", label = "Board", input = value, quality = "fresh" } },
  } } }
end
local mac_hwmon = collectors(fake_native({ collect_hwmon = {
  hid(32), hid(35),
} })).hwmon
local mac_first = mac_hwmon:sample(at(1000000000))
local mac_second = mac_hwmon:sample(at(2000000000), mac_first)
close(mac_second.data.devices[1].channels[1].session.average, 33.5, 1e-9,
  "macOS HID-shaped direct readings use the shared session model")
local function smc(value)
  return { devices = { { id = "smc", class = "smc", name = "SMC",
    source = "smc", identity_quality = "fresh", quality = "fresh",
    channels = { { id = "power1", type = "power", unit = "watts",
      label = "System total", input = value, input_source = "PSTR",
      quality = "fresh" } },
  } } }
end
local mac_power = collectors(fake_native({ collect_hwmon = {
  smc(10), smc(20),
} })).hwmon
local power_first = mac_power:sample(at(1000000000))
local power_second = mac_power:sample(at(2000000000), power_first)
close(power_second.data.devices[1].channels[1].session.average, 15, 1e-9,
  "a named macOS SMC source is still a direct measurement")
do
  local function reading(epoch, value, extra)
    local channels = { { id = "PSTR", type = "power", unit = "watts", label = "System total",
      input = value, input_source = "PSTR", quality = "fresh" } }
    if extra then table.insert(channels, 1, { id = "TC0D", type = "temperature", unit = "celsius",
      label = "TC0D", input = 40, input_source = "TC0D", quality = "fresh" }) end
    return { devices = { { id = "smc", class = "smc", name = "SMC", source = "smc",
      _source_epoch = epoch, identity_quality = "fresh", quality = "fresh", channels = channels } } }
  end
  local source = collectors(fake_native({ collect_hwmon = {
    reading("smc:1", 10), reading("smc:1", 20, true), reading("smc:2", 30, true),
  } })).hwmon
  local first = source:sample(at(1000000000))
  local second = source:sample(at(2000000000), first)
  local function power_channel(sample)
    for _, channel in ipairs(sample.data.devices[1].channels) do
      if channel.id == "PSTR" then return channel end
    end
    error("SMC PSTR channel missing")
  end
  local channel = power_channel(second)
  equal(channel.session.samples, 2, "optional SMC keys cannot renumber a stable channel")
  close(channel.session.average, 15, 1e-9, "a key-based channel preserves statistics")
  local third = source:sample(at(3000000000), second)
  equal(power_channel(third).session.samples, 1,
    "reopening an SMC source starts a new measurement session")
  local exported = require("wtop.export").snapshot({ sensors = third.data })
  assert(not require("wtop.format.json").encode(exported):find("_source_epoch", 1, true),
    "private SMC connection epochs do not enter export")
end

local duplicate_native = collectors({
  collect_hwmon = function()
    return { devices = { { id = "acpi_thermal_zones",
      class = "acpi_thermal_zones", name = "ACPI thermal zone",
      source = "pdh:Thermal Zone Information", identity_quality = "fresh",
      quality = "fresh",
      channels = {
        { id = "temp1", type = "temperature", unit = "celsius",
          label = "TZ0", input = 46, input_source = "pdh", quality = "fresh" },
        { id = "temp1", type = "temperature", unit = "celsius",
          label = "TZ1", input = 49, input_source = "pdh", quality = "fresh" },
      },
    } } }
  end,
}).hwmon:sample(at(3000000000), thermal_second)
equal(duplicate_native.data.devices[1].channels[1].session.samples, 1,
  "duplicate native channel IDs cannot inherit another channel's extrema")
local changed_source = thermal(46)
changed_source.devices[1].source = "different-provider"
local changed_source_result = collectors({
  collect_hwmon = function() return changed_source end,
}).hwmon:sample(at(3000000000), thermal_second)
equal(changed_source_result.data.devices[1].channels[1].session.samples, 1,
  "a changed native provider cannot inherit an old device series")
local duplicated_devices = thermal(46)
duplicated_devices.devices[2] = thermal(49).devices[1]
local ambiguous_devices = collectors({
  collect_hwmon = function() return duplicated_devices end,
}).hwmon:sample(at(3000000000), thermal_second)
equal(ambiguous_devices.data.devices[1].channels[1].session.samples, 1,
  "duplicate native device IDs cannot inherit the first matching history")
local duplicate_labels = thermal(46)
duplicate_labels.devices[1].channels[2] = {
  id = "temp2", type = "temperature", unit = "celsius",
  label = "TZ0", input = 49, input_source = "pdh", quality = "fresh",
}
local ambiguous_labels = collectors({
  collect_hwmon = function() return duplicate_labels end,
}).hwmon:sample(at(3000000000), thermal_second)
equal(ambiguous_labels.data.devices[1].channels[1].session.samples, 1,
  "duplicate native labels of the same type cannot carry historical extrema")
local unlabeled = thermal(46)
unlabeled.devices[1].channels[1].label = nil
local weak_label = collectors({
  collect_hwmon = function() return unlabeled end,
}).hwmon:sample(at(3000000000), thermal_second)
equal(weak_label.data.devices[1].channels[1].session.samples, 1,
  "a native channel without a stable label starts a new series")

-- Registry IDs survive service reordering and distinguish same-named probes.
do
  local function reading(value, reverse, missing, partial)
    local channels = {}
    for _, id in ipairs(reverse and { 2002, 2001 } or { 2001, 2002 }) do
      local instance = "ioreg:" .. id
      channels[#channels + 1] = { id = missing and "unresolved:" .. id or instance,
        _source_instance = not missing and instance or nil,
        identity_quality = missing and "partial" or "fresh",
        label = "Board", type = "temperature", unit = "celsius", input = value + id - 2001,
        quality = "fresh" }
    end
    return { quality = partial and "partial" or "fresh", devices = { {
      id = "hid:Thermal", class = "hid:Thermal", name = "Thermal", source = "iohid",
      identity_quality = "fresh", quality = "fresh", channels = channels } } }
  end
  local native = collectors(fake_native({ collect_hwmon = {
    reading(30), reading(40, true, false, true), reading(50, false, true), reading(60, true, true),
  } })).hwmon
  local first = native:sample(at(1000000000))
  local second = native:sample(at(2000000000), first)
  equal(second.quality, "partial", "a partial scan reports its missing observations")
  local channels = second.data.devices[1].channels
  equal(channels[1].id, "ioreg:2002", "channel order can change")
  equal(channels[1].session.samples, 2, "same labels retain distinct verified source history")
  close(channels[1].session.average, 36, 1e-9, "first source is matched by identity, not position")
  close(channels[2].session.average, 35, 1e-9, "other source history remains independent")
  local third = native:sample(at(3000000000), second)
  local fourth = native:sample(at(4000000000), third)
  equal(fourth.data.devices[1].channels[1].session.samples, 1,
    "unidentified service readings cannot accumulate across polls")
  local replaced = reading(70)
  replaced.devices[1].channels[1]._source_instance = "ioreg:3001"
  local changed = collectors({ collect_hwmon = function() return replaced end }).hwmon:sample(at(3000000000), second)
  equal(changed.data.devices[1].channels[1].session.samples, 1, "a changed source instance resets history")
  local duplicate = reading(70)
  duplicate.devices[1].channels[2].id = "ioreg:2001"
  duplicate.devices[1].channels[2]._source_instance = "ioreg:2001"
  local ambiguous = collectors({ collect_hwmon = function() return duplicate end }).hwmon:sample(at(3000000000), second)
  for _, channel in ipairs(ambiguous.data.devices[1].channels) do
    equal(channel.session.samples, 1, "duplicate service identities cannot carry historical extrema")
  end
  local exported = require("wtop.export").snapshot({ sensors = second.data })
  equal(exported.sensors.quality, "partial", "sensor scan quality reaches Snapshot JSON")
  equal(exported.sensors.devices[1].channels[1].identity_quality, "fresh",
    "verified channel identity quality is exported")
  local unidentified = require("wtop.export").snapshot({ sensors = fourth.data })
  equal(unidentified.sensors.devices[1].channels[1].identity_quality, "partial",
    "unconfirmed channel identity is visible in Snapshot JSON")
  assert(not require("wtop.format.json").encode(exported):find("_source_instance", 1, true),
    "private source instances are not exported")
end

-- IOReport deltas must remain within one observation epoch and actual window.
do
  local function energy(epoch, value, stamp, quality)
    return { zones = {
      { id = "cpu", energy_joules = value, aggregate = true, _source_epoch = epoch,
        _sample_timestamp_ns = stamp, power_quality = quality or "fresh" },
      { id = "system", power_watts = 20, power_quality = "fresh", aggregate = false },
    } }
  end
  local failed = { quality = "partial", zones = { { id = "system", power_watts = 20 } } }
  local warming = energy("epoch1",0,1000000000,"gap"); warming._sampling_pending=true
  local source = collectors(fake_native({ collect_powercap = {
    warming, energy("epoch1",10,3000000000), failed,
    energy("epoch2",0,5000000000,"gap"), energy("epoch2",10,6000000000),
    energy("epoch3",100,7000000000), energy("epoch3",120,8000000000,"gap"),
  } })).powercap
  local first = source:sample(at(1000000000))
  equal(first.data.zones[1].power_watts,nil,"warmup does not fabricate zero watts")
  assert(first.sampling_pending and first.retry_after_ms==100 and first.data._sampling_pending==nil,
    "native warmup must schedule a real second observation without exporting its private hint")
  local second = source:sample(at(2000000000),first)
  equal(second.data.zones[1].power_watts,5,"power uses the actual two-second IOReport interval")
  equal(second.data.zones[1].power_interval_ns,2000000000,"the observed averaging window is retained")
  assert(not second.sampling_pending,"a completed energy interval remained pending")
  local third = source:sample(at(3000000000),second)
  equal(third.quality,"partial","failed energy and fresh independent SMC remain partial")
  equal(#third.data.zones,1,"failed energy zones disappear rather than repeat old counters")
  local fourth = source:sample(at(4000000000),third)
  equal(fourth.data.zones[1].power_watts,nil,"reopen first establishes a new baseline")
  local fifth = source:sample(at(5000000000),fourth)
  equal(fifth.data.zones[1].power_watts,10,"a second valid observation restores power")
  local sixth = source:sample(at(6000000000),fifth)
  equal(sixth.data.zones[1].power_watts,nil,"even an increasing counter cannot cross source epochs")
  local seventh = source:sample(at(7000000000),sixth)
  equal(seventh.data.zones[1].power_watts,nil,"an explicit source gap cannot turn unchanged or new totals into watts")
  local backwards = collectors({collect_powercap=function()return energy("epoch2",30,5000000000)end}).powercap:sample(at(6000000000),fifth)
  equal(backwards.data.zones[1].power_watts,nil,"a backwards native sample clock cannot use the outer timestamp as fallback")
  local stale = energy("epoch2",20,7000000000,"stale");stale.zones[1].power_watts=123
  local held = collectors({collect_powercap=function()return stale end}).powercap:sample(at(6000000000),fifth)
  equal(held.data.zones[1].power_watts,nil,"a retained direct power reading does not become current")
  local exported=require("wtop.export").snapshot({power=second.data})
  equal(exported.power.zones[1].power_interval_ns,2000000000,"Snapshot exposes the actual averaging interval")
  local text=require("wtop.format.json").encode(exported)
  assert(not text:find("_source_epoch",1,true) and not text:find("_sample_timestamp_ns",1,true),"private counter identity and clock are not exported")
  local gpu=collectors(fake_native({collect_gpu={
    {devices={},quality="fresh",_sampling_pending=true},{devices={},quality="fresh"}
  }})).gpu
  local warming_gpu=gpu:sample(at(1000000000))
  assert(warming_gpu.quality=="fresh" and warming_gpu.sampling_pending
    and warming_gpu.retry_after_ms==100 and warming_gpu.data._sampling_pending==nil,
    "fresh GPU identity/utilization must not suppress its frequency warmup")
  assert(not gpu:sample(at(1100000000),warming_gpu).sampling_pending)
end

-- A group-aware frequency provider can have a valid query before its second
-- rate sample. Keep this distinct from permanent unavailability.
do
  local source=collectors(fake_native({collect_cpufreq={
    {policies={},quality="gap",_sampling_pending=true},
    {policies={{id="cpu64",affected_cpus={64},frequencies={current_hz=4000000000}}},quality="partial"}
  }})).cpufreq
  local cold=source:sample(at(1000000000))
  assert(cold.status=="ok" and cold.quality=="gap" and cold.sampling_pending and cold.retry_after_ms==100)
  assert(cold.data._sampling_pending==nil)
  local warm=source:sample(at(2000000000),cold)
  assert(warm.quality=="partial" and warm.reason=="platform_data_partial" and not warm.sampling_pending)
  assert(warm.data.policies[1].affected_cpus[1]==64)
end

return true
