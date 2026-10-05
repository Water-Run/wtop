package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local CPU = require("wtop.collectors.cpu")
local Engine = require("wtop.engine")
local Memory = require("wtop.collectors.memory")
local Pressure = require("wtop.collectors.pressure")
local Disk = require("wtop.collectors.disk")
local Network = require("wtop.collectors.network")
local Process = require("wtop.collectors.process")
local GPU = require("wtop.collectors.gpu")
local Common = require("wtop.collectors.common")
local Snapshot = require("wtop.model.snapshot")

local function fixture(path)
  local file = assert(io.open("tests/fixtures/" .. path, "rb"))
  local content = assert(file:read("*a"))
  file:close()
  return content
end

local function fake_fs(files, directories, links)
  files, directories, links = files or {}, directories or {}, links or {}
  local fs = {}
  function fs:read(path)
    local value = files[path]
    if type(value) == "function" then
      value = value(path)
    end
    if value == nil then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    return tostring(value)
  end
  function fs:read_number(path)
    local value, err = self:read(path)
    if not value then return nil, err end
    local number = tonumber(value:match("^%s*([^%s]+)"))
    if not number then return nil, { kind = "parse_error", message = "expected_number" } end
    return number
  end
  function fs:list(path)
    local values = directories[path]
    if not values then
      return nil, { kind = "missing", message = "fixture_directory_missing", path = path }
    end
    local copy = {}
    for index, value in ipairs(values) do copy[index] = value end
    return copy
  end
  function fs:readlink(path)
    local value = links[path]
    if value then return value end
    return nil, { kind = "missing", message = "fixture_link_missing", path = path }
  end
  function fs:exists(path)
    return files[path] ~= nil or directories[path] ~= nil
  end
  return fs
end

local function near(actual, expected, epsilon)
  assert(type(actual) == "number", "expected a number, got " .. tostring(actual))
  assert(math.abs(actual - expected) <= (epsilon or 1e-6), tostring(actual) .. " ~= " .. tostring(expected))
end

local now = 1000000000
local context = { now_ns = function() return now end }

local cpu_files = {
  ["/proc/stat"] = fixture("proc/stat.1"),
  ["/proc/loadavg"] = fixture("proc/loadavg"),
}
context.fs = fake_fs(cpu_files)
local cpu = CPU.new()
assert(cpu:probe(context).available)
local cpu_first = cpu:sample(context)
assert(cpu_first.status == "ok" and cpu_first.quality == "gap")
cpu_files["/proc/stat"] = fixture("proc/stat.2")
now = now + 1000000000
local cpu_second = cpu:sample(context, cpu_first)
near(cpu_second.data.total.utilization, 45)
assert(cpu_second.data.load.running == 2)
local reset_cpu_text = fixture("proc/stat.2"):gsub(
  "cpu  130 5 50 850 25 3 4 0 0 0", "cpu  90 5 50 1000 25 3 4 0 0 0", 1)
cpu_files["/proc/stat"] = reset_cpu_text
now = now + 1000000000
local cpu_reset = cpu:sample(context, cpu_second)
assert(cpu_reset.data.total.quality == "gap" and cpu_reset.data.total.user == nil)

-- The CPU collector is the eleventh to publish a reason for a degraded but
-- running reading, and it is the first one where the measurement says the slot
-- cannot be ambiguous: `derive_cpu` returns `gap` from five places -- no
-- previous sample, a counter that went backwards, a delta that overflowed, an
-- idle larger than total, and a missing per-field delta -- and all five mean
-- the same thing, that this sample cannot be differenced against the last one.
-- `partial` has one cause too, the load average.  So the test asserts the
-- pairing, not just the presence of a reason: one quality, one code, and a
-- fresh reading with none at all.
local CPU_REASON = { gap = "cpu_counter_delta_unavailable",
  partial = "loadavg_unavailable", fresh = false }
local CollectorReason = require("support.collector_reason")
local cpu_reason_is = function(result, label)
  return CollectorReason.assert_reason(result, CPU_REASON, label)
end
cpu_reason_is(cpu_first, "the first sample")
cpu_reason_is(cpu_second, "the second sample")
cpu_reason_is(cpu_reset, "the sample after a counter reset")

-- The load average is the other half, and it is a different code because it is
-- a different cause: the counters differenced fine and one file was unreadable.
cpu_files["/proc/loadavg"] = nil
now = now + 1000000000
local cpu_no_loadavg = cpu:sample(context, cpu_reset)
assert(cpu_no_loadavg.status == "ok", "a missing load average is not a failure")
cpu_reason_is(cpu_no_loadavg, "a sample with no load average")
assert(cpu_no_loadavg.quality == "partial",
  "and it degrades the reading rather than dropping a field silently")
assert(cpu_no_loadavg.data.load == nil, "with no load invented for it")
-- And a malformed load average is the same cause, not a second one: the file
-- was read and could not be understood, which is still "could not be read".
cpu_files["/proc/loadavg"] = "not a load average\n"
now = now + 1000000000
local cpu_broken = cpu:sample(context, cpu_no_loadavg)
cpu_reason_is(cpu_broken, "a sample with a broken load average")
-- With the load average back and the counters unchanged, both causes are live
-- at once -- the load average reads and the samples cannot be differenced -- and
-- the published quality is `gap`, so the reason must name the gap and not the
-- load average.  This is the case that would catch a reason written as an
-- independent second guess rather than as the cause of what was published.
cpu_files["/proc/loadavg"] = fixture("proc/loadavg")
now = now + 1000000000
local cpu_both = cpu:sample(context, cpu_broken)
cpu_reason_is(cpu_both, "a sample with a readable load average and no counter delta")
assert(cpu_both.quality == "gap",
  "the unchanged counters are still the reason the reading is degraded")
assert(cpu_both.reason == "cpu_counter_delta_unavailable",
  "and the reason names them, not the load average that is now readable")

context.fs = fake_fs({
  ["/proc/meminfo"] = fixture("proc/meminfo"),
  ["/proc/vmstat"] = fixture("proc/vmstat"),
})
local memory = Memory.new():sample(context)
assert(memory.status == "ok" and memory.quality == "fresh")
assert(memory.data.total_bytes == 16384000 * 1024)
assert(memory.data.swap_used_bytes == 1048576 * 1024)
context.fs = fake_fs({
  ["/proc/meminfo"] = fixture("proc/meminfo"),
  ["/proc/vmstat"] = "broken vmstat line trailing\n",
})
local partial_memory = Memory.new():sample(context)
assert(partial_memory.status == "ok" and partial_memory.quality == "partial")
-- A reading that is `partial` has to say why, on the result and not only in the
-- data.  `Snapshot.merge` copies `result.reason` into `quality[resource].reason`
-- and that is the slot a caller reads to answer "why is this degraded" -- and
-- only the error path had ever filled it, through `Common.error_result`.  So a
-- degraded-but-running reading was the single kind that could not say why: it
-- reported `partial` with a nil reason, while a collector that failed outright
-- reported `unavailable` with one.  This collector computed the reason and put
-- it in `data.vmstat_error`, where no reader was looking.
assert(type(partial_memory.reason) == "string" and partial_memory.reason ~= "",
  "a memory reading that is partial carries no reason: the vmstat parse failed "
    .. "and the collector knows why, so the snapshot can only say `partial` and "
    .. "a caller has nothing to report to the user but the word itself")
-- The other way to be partial: the file is not readable at all.  A different
-- cause, so it has to be a different reason -- a guard that only ever saw the
-- parse failure would accept a constant here.
context.fs = fake_fs({ ["/proc/meminfo"] = fixture("proc/meminfo") })
local unreadable = Memory.new():sample(context)
assert(unreadable.status == "ok" and unreadable.quality == "partial")
assert(type(unreadable.reason) == "string" and unreadable.reason ~= ""
    and unreadable.reason ~= partial_memory.reason,
  "an unreadable /proc/vmstat and an unparseable one both report "
    .. tostring(unreadable.reason) .. " / " .. tostring(partial_memory.reason) ..
    ": the two are different failures and the snapshot has to be able to say "
    .. "which one happened")
-- And the reason has to survive the merge, because that is the copy the UI, the
-- JSON snapshot and an agent all read.
local merged = Snapshot.merge(Snapshot.new(0, 1), { memory = partial_memory })
assert(merged.quality.memory.reason == partial_memory.reason,
  "the reason a collector computed does not reach quality[resource].reason: "
    .. tostring(merged.quality.memory.reason) .. " instead of "
    .. tostring(partial_memory.reason) .. ".  Everything downstream reads the "
    .. "snapshot, not the collector result.")
-- The two paths are comparable only if both carry one, so pin the other half
-- too: a collector that failed outright says why, and has always been able to.
local failed_memory = Snapshot.merge(Snapshot.new(0, 1), {
  memory = Common.error_result({ kind = "missing", message = "no such file" }, 1, "/proc/meminfo"),
})
assert(failed_memory.quality.memory.reason == "no such file",
  "a collector that failed outright no longer says why, so a degraded reading "
    .. "and a failed one are not comparable and the vocabulary is not a "
    .. "contract: " .. tostring(failed_memory.quality.memory.reason))
context.fs = fake_fs({
  ["/proc/meminfo"] = "MemTotal: 100 kB\nMemAvailable: 200 kB\n",
  ["/proc/vmstat"] = fixture("proc/vmstat"),
})
assert(Memory.new():sample(context).status == "error")

context.fs = fake_fs({
  ["/proc/pressure/cpu"] = fixture("proc/pressure.cpu"),
  ["/proc/pressure/memory"] = fixture("proc/pressure.memory"),
  ["/proc/pressure/io"] = fixture("proc/pressure.io"),
})
local pressure = Pressure.new():sample(context)
assert(pressure.status == "ok" and pressure.data.memory.full.total == 50)
context.fs = fake_fs({ ["/proc/pressure/cpu"] = fixture("proc/pressure.cpu") })

-- A reading that degraded without failing has to say why, and the reason has to
-- be *measured* rather than a constant that happens to be attached.  This is the
-- second collector to carry that contract after memory; the shape is the same one
-- that made the first worth closing, and the collector is a good second case
-- because the cause is genuinely single -- the only condition that degrades the
-- sample is a resource that could not be read, so the aggregate reason and the
-- per-resource reasons in `data.errors` cannot disagree about which cause it was.
local partial_pressure = Pressure.new():sample(context)
assert(partial_pressure.status == "ok" and partial_pressure.quality == "partial")
assert(type(partial_pressure.reason) == "string" and partial_pressure.reason ~= "",
  "a pressure sample that is partial carries no reason: two of the three "
    .. "configured resources could not be read, the collector counted them, and "
    .. "the snapshot can therefore only say `partial` and leave the question "
    .. "open.  This is the same contract memory closes above, and the per-"
    .. "resource detail is already in data.errors -- the aggregate is the one "
    .. "thing the result did not say.")

-- A different cause, so a different reason.  Every resource failing is a
-- different state with its own status and its own reason, and a guard that only
-- ever saw the partial case would be satisfied by any string at all.  The
-- resources are named so that none of them is the one the current tree declares:
-- a missing resource and a present one have to be told apart by the fixture, not
-- by which word follows it.
local previous_fs = context.fs
context.fs = fake_fs({})
local none_pressure = Pressure.new():sample(context)
assert(none_pressure.status ~= "ok" and none_pressure.quality ~= "partial",
  "a pressure sample with no readable resource is no longer reported as a "
    .. "partial ok result: it came back " .. tostring(none_pressure.status) .. " / "
    .. tostring(none_pressure.quality))
assert(type(none_pressure.reason) == "string" and none_pressure.reason ~= ""
    and none_pressure.reason ~= partial_pressure.reason,
  "the all-unreadable case and the partial case give the same reason ("
    .. tostring(none_pressure.reason) .. "), so the reason does not identify the "
    .. "cause: a snapshot reader cannot tell a sample that lost some resources "
    .. "from one that lost all of them")

-- And the reason has to survive the merge, because that is the copy the UI, the
-- JSON snapshot and an agent read.
local pressure_merged = Snapshot.merge(Snapshot.new(0, 1), { pressure = partial_pressure })
assert(pressure_merged.quality.pressure.reason == partial_pressure.reason,
  "the reason the pressure collector computed does not reach "
    .. "quality[pressure].reason: " .. tostring(pressure_merged.quality.pressure.reason)
    .. " instead of " .. tostring(partial_pressure.reason))

-- And a sample that is not degraded must not claim to be: a reason attached to a
-- `fresh` reading is a lie of the same shape, and the guard has to see it.
context.fs = fake_fs({
  ["/proc/pressure/cpu"] = fixture("proc/pressure.cpu"),
  ["/proc/pressure/memory"] = fixture("proc/pressure.memory"),
  ["/proc/pressure/io"] = fixture("proc/pressure.io"),
})
local all_readable = Pressure.new():sample(context)
context.fs = previous_fs
assert(all_readable.status == "ok" and all_readable.quality == "fresh"
    and all_readable.reason == nil,
  "a pressure sample where every resource was read reports `" .. tostring(all_readable.quality)
    .. "` and still carries a reason (" .. tostring(all_readable.reason)
    .. "), so a reading that is not degraded is explaining a degradation that "
    .. "did not happen")

local disk_files = {
  ["/proc/diskstats"] = fixture("proc/diskstats.1"),
  ["/sys/dev/block/8:0/queue/logical_block_size"] = "512\n",
  ["/sys/dev/block/8:0/queue/physical_block_size"] = "4096\n",
  ["/sys/dev/block/259:0/queue/logical_block_size"] = "4096\n",
  ["/sys/dev/block/259:0/queue/physical_block_size"] = "4096\n",
  ["/sys/dev/block/259:0/diskseq"] = "42\n",
  ["/sys/dev/block/259:1/partition"] = "1\n",
  ["/sys/dev/block/259:1/diskseq"] = "42\n",
}
local disk_directories = {
  ["/sys/dev/block/8:0/slaves"] = {},
  ["/sys/dev/block/259:0/slaves"] = {},
  ["/sys/dev/block/259:1/slaves"] = {},
}
context.fs = fake_fs(disk_files, disk_directories)
local disk_collector = Disk.new()
local disk_first_content = disk_files["/proc/diskstats"]
  .. " 259 1 nvme0n1p1 50 0 800 120 30 0 400 80 0 150 160 0 0 0 0 0 0\n"
disk_files["/proc/diskstats"] = disk_first_content
local disk_first = disk_collector:sample(context)
disk_files["/proc/diskstats"] = fixture("proc/diskstats.2")
  .. " 259 1 nvme0n1p1 80 0 2000 210 50 0 1200 150 1 350 420 0 0 0 0 0 0\n"
now = now + 1000000000
local disk_second = disk_collector:sample(context, disk_first)
assert(disk_second.status == "ok")
near(disk_second.data.devices[1].read_bytes_per_second, 400 * 512)
near(disk_second.data.devices[1].write_iops, 20)
near(disk_second.data.devices[2].read_bytes_per_second, 1200 * 512)
assert(disk_second.data.devices[2].logical_sector_size_bytes == 4096)
assert(disk_second.data.devices[2].stable_id == "259:0:42")
assert(disk_second.data.devices[3].is_partition and not disk_second.data.devices[3].aggregate)
near(Engine.sum_devices(disk_second.data.devices, "read_bytes_per_second"),
  disk_second.data.devices[1].read_bytes_per_second
    + disk_second.data.devices[2].read_bytes_per_second)

local net_files = {
  ["/proc/net/dev"] = fixture("proc/netdev.1"),
  ["/proc/net/route"] = table.concat({
    "Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT",
    "eth0 00000000 0100000A 0003 0 0 100 00000000 0 0 0",
  }, "\n"),
  ["/sys/class/net/lo/ifindex"] = "1\n",
  ["/sys/class/net/lo/operstate"] = "unknown\n",
  ["/sys/class/net/lo/mtu"] = "65536\n",
  ["/sys/class/net/eth0/ifindex"] = "2\n",
  ["/sys/class/net/eth0/operstate"] = "up\n",
  ["/sys/class/net/eth0/mtu"] = "1500\n",
  ["/sys/class/net/eth0/speed"] = "1000\n",
}
context.fs = fake_fs(net_files)
local network_collector = Network.new()
local network_first = network_collector:sample(context)
net_files["/proc/net/dev"] = fixture("proc/netdev.2")
now = now + 1000000000
local network_second = network_collector:sample(context, network_first)
local eth0 = network_second.data.interfaces[2]
assert(eth0.name == "eth0" and eth0.ifindex == 2)
assert(eth0.aggregate and eth0.default_route.families.ipv4)
assert(not network_second.data.interfaces[1].aggregate)
near(eth0.rates.rx_bytes_per_second, 3000)
near(eth0.rates.tx_bytes_per_second, 4000)
near(Engine.sum_interfaces(network_second.data.interfaces, "rx_bytes_per_second"), 3000)

-- Reusing an interface name with a new ifindex must not continue the old
-- counter baseline.
net_files["/sys/class/net/eth0/ifindex"] = "9\n"
net_files["/proc/net/dev"] = fixture("proc/netdev.1")
now = now + 1000000000
local replaced_network = network_collector:sample(context, network_second)
local replaced_eth0 = replaced_network.data.interfaces[2]
assert(replaced_eth0.name == "eth0" and replaced_eth0.ifindex == 9)
assert(replaced_eth0.quality == "gap" and next(replaced_eth0.rates) == nil)

-- Without an ifindex there is no safe identity to which a previous counter
-- sample can be attached.
net_files["/sys/class/net/eth0/ifindex"] = nil
now = now + 1000000000
local unidentified_network = network_collector:sample(context, replaced_network)
local unidentified_eth0
for _, interface in ipairs(unidentified_network.data.interfaces) do
  if interface.name == "eth0" then unidentified_eth0 = interface end
end
assert(unidentified_eth0 and unidentified_eth0.ifindex == nil)
assert(unidentified_eth0.quality == "gap" and next(unidentified_eth0.rates) == nil)

-- The network collector is the twelfth to publish a reason for a degraded but
-- running reading, and it passes the test a single reason slot has to pass: a
-- sentence that is true in *every* case that produces the quality.  `partial`
-- is set only when a route file could not be read or was longer than the line
-- cap, and "the default-route table is incomplete" is true of both.  `gap` is
-- set when an interface has no previous sample, when no interval has elapsed,
-- or when a counter could not be differenced, and all three mean no rate
-- exists for it this tick.  So the assertion is the pairing again, and it needs
-- a route read that is refused rather than absent, because an absent file is
-- how a host with no IPv4 route table looks and it is not a degradation.
local NET_REASON = { partial = "default_routes_incomplete",
  gap = "network_rate_unavailable", fresh = false }
local network_reason_is = function(result, label)
  return CollectorReason.assert_reason(result, NET_REASON, label)
end
network_reason_is(network_first, "the first network sample")
network_reason_is(network_second, "the second network sample")
network_reason_is(replaced_network, "a sample after the ifindex changed")
network_reason_is(unidentified_network, "a sample with no ifindex")

local open_fs = context.fs
local denying_fs = {}
for key, value in pairs(open_fs) do denying_fs[key] = value end
function denying_fs:read(path, limit)
  if path == "/proc/net/route" then
    return nil, { kind = "denied", message = "fixture_denied", path = path }
  end
  return open_fs.read(self, path, limit)
end
context.fs = denying_fs
now = now + 1000000000
local denied_routes = network_collector:sample(context, unidentified_network)
network_reason_is(denied_routes, "a sample whose route table was refused")
assert(denied_routes.quality == "partial",
  "a refused route table degrades the reading")
assert(#denied_routes.data.default_routes == 0,
  "and no default route is invented for it")
context.fs = open_fs
-- Both causes live at once: the route table reads again, and the counters are
-- unchanged from the sample just taken, so no rate exists for any interface.
-- The published quality is `gap`, so the reason must name that.
now = now + 1000000000
local network_both = network_collector:sample(context, denied_routes)
network_reason_is(network_both, "a readable route table and no counter delta")
assert(network_both.quality == "gap",
  "the unchanged counters are still why the reading is degraded")
assert(network_both.reason == "network_rate_unavailable",
  "and the reason names them, not the route table that now reads")

local process_files = {
  ["/proc/100/stat"] = fixture("proc/100.stat.1"),
  ["/proc/100/status"] = fixture("proc/100.status"),
  ["/proc/100/cmdline"] = "lua\0worker.lua\0",
  ["/proc/100/io"] = fixture("proc/100.io"),
  ["/proc/100/cgroup"] = fixture("proc/100.cgroup"),
}
context.fs = fake_fs(process_files, { ["/proc"] = { "self", "101", "100", "uptime" } })
local process_collector = Process.new({ read_cmdline = true, read_io = true, read_cgroup = true })
local process_first = process_collector:sample(context)
assert(#process_first.data.list == 1 and process_first.data.races == 1)
assert(process_first.data.list[1].id == "100:1000")
assert(process_first.data.list[1].command == "lua worker.lua")
assert(process_first.data.list[1].resident_bytes == 4096 * 1024)
process_files["/proc/100/stat"] = fixture("proc/100.stat.2")
now = now + 1000000000
local process_second = process_collector:sample(context, process_first)
near(process_second.data.list[1].cpu_percent, 50)
assert(process_second.data.list[1].io.write_bytes == 8192)
assert(Process.sanitize_text("bad\255name") == "bad�name")

-- A PID reused between stat and supplemental status reads must be discarded.
local original_stat = fixture("proc/100.stat.1")
local reused_stat = original_stat:gsub(" 1000 10485760 ", " 2000 10485760 ")
assert(reused_stat ~= original_stat)
local generation_reads = 0
local generation_fs = fake_fs({
  ["/proc/100/stat"] = function()
    generation_reads = generation_reads + 1
    return generation_reads == 1 and original_stat or reused_stat
  end,
  ["/proc/100/status"] = fixture("proc/100.status"),
}, { ["/proc"] = { "100" } })
local reused_result = Process.new():sample({ fs = generation_fs, now_ns = function() return now end })
assert(generation_reads == 2)
assert(#reused_result.data.list == 0)
assert(reused_result.data.races == 1)

-- Enumeration is bounded in the native list call, not after an unbounded
-- directory allocation. The result exposes its partial quality downstream.
local bound_stat = fixture("proc/100.stat.1")
local bound_files = {}
for _, pid in ipairs({ 100, 101, 102, 103 }) do
  bound_files["/proc/" .. tostring(pid) .. "/stat"] = bound_stat:gsub("^100", tostring(pid), 1)
end
local bound_fs = fake_fs(bound_files, { ["/proc"] = { "self", "103", "102", "101", "100" } })
local bound_list_limit
local original_bound_list = bound_fs.list
function bound_fs:list(path, limit)
  bound_list_limit = limit
  local entries, list_error = original_bound_list(self, path)
  return entries, list_error, true
end
local bounded_processes = Process.new({ max_processes = 2, read_status = false }):sample({
  fs = bound_fs, now_ns = function() return now end,
})
assert(bound_list_limit == 258)
assert(bounded_processes.data.scanned == 2 and #bounded_processes.data.list == 2)
assert(bounded_processes.data.list[1].pid == 100 and bounded_processes.data.list[2].pid == 101)
assert(bounded_processes.data.truncated and bounded_processes.data.partial
  and bounded_processes.data.process_limit == 2)
assert(bounded_processes.quality == "partial")
assert(not pcall(Process.new, { max_processes = 0 }))
assert(not pcall(Process.new, { max_processes = 999999 }))
assert(not pcall(Process.new, "invalid"))
assert(not pcall(Process.new, { clock_ticks_per_second = 0 }))

local gpu_files = {
  ["/sys/class/drm/card0/device/uevent"] = "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n",
  ["/sys/class/drm/renderD128/device/uevent"] = "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n",
  ["/sys/class/drm/card0/dev"] = "226:0\n",
  ["/sys/class/drm/renderD128/dev"] = "226:128\n",
  ["/sys/class/drm/card0/device/vendor"] = "0x1002\n",
  ["/sys/class/drm/card0/device/device"] = "0x73bf\n",
  ["/sys/class/drm/card0/device/gpu_busy_percent"] = "71\n",
  ["/sys/class/drm/card0/device/mem_info_vram_total"] = "17179869184\n",
  ["/sys/class/drm/card0/device/mem_info_vram_used"] = "4294967296\n",
  ["/sys/class/drm/card0/device/hwmon/hwmon0/name"] = "amdgpu\n",
  ["/sys/class/drm/card0/device/hwmon/hwmon0/temp1_input"] = "65000\n",
  ["/sys/class/drm/card0/device/hwmon/hwmon0/power1_average"] = "120000000\n",
  ["/sys/class/drm/card0/device/hwmon/hwmon0/fan1_input"] = "1450\n",
}
context.fs = fake_fs(gpu_files, {
  ["/sys/class/drm"] = { "card0", "card0-DP-1", "renderD128" },
  ["/sys/class/drm/card0/device/hwmon"] = { "hwmon0" },
}, {
  ["/sys/class/drm/card0/device"] = "../../../0000:03:00.0",
  ["/sys/class/drm/card0/device/driver"] = "../../../../bus/pci/drivers/amdgpu",
  ["/sys/class/drm/renderD128/device"] = "../../../0000:03:00.0",
  ["/sys/class/drm/renderD128/device/driver"] = "../../../../bus/pci/drivers/amdgpu",
})
local gpu_collector = GPU.new({ scan_processes = false })
assert(gpu_collector:probe(context).available)
local gpu = gpu_collector:sample(context)
assert(gpu.status == "ok" and #gpu.data.devices == 1)
local device = gpu.data.devices[1]
assert(device.id == "0000:03:00.0" and device.vendor == "amd" and device.driver == "amdgpu")
assert(device.metrics.temperature_celsius == nil and device.metrics.power_watts == nil)
assert(device.capabilities.hwmon and #device.hwmon_refs == 1)
assert(device.render_nodes[1] == "renderD128")
assert(device.capabilities.utilization and device.capabilities.memory)

-- Direct procfs collectors should tolerate real Linux state as a smoke test.
context.fs = nil
context.now_ns = nil
assert(CPU.new():sample(context).status == "ok")
assert(Memory.new():sample(context).status == "ok")

return true
