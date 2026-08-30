package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local CPU = require("wtop.collectors.cpu")
local Engine = require("wtop.engine")
local Memory = require("wtop.collectors.memory")
local Pressure = require("wtop.collectors.pressure")
local Disk = require("wtop.collectors.disk")
local Network = require("wtop.collectors.network")
local Process = require("wtop.collectors.process")
local GPU = require("wtop.collectors.gpu")

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
assert(Pressure.new():sample(context).quality == "partial")

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
