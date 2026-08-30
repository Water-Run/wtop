package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Parsers = require("wtop.linux.parsers")

local function fixture(path)
  local file = assert(io.open("tests/fixtures/" .. path, "rb"))
  local content = assert(file:read("*a"))
  file:close()
  return content
end

local function near(actual, expected, epsilon)
  assert(math.abs(actual - expected) <= (epsilon or 1e-9), tostring(actual) .. " ~= " .. tostring(expected))
end

local stat = assert(Parsers.proc_stat(fixture("proc/stat.1")))
assert(stat.total.total == 970)
assert(#stat.cores == 2)
assert(stat.metadata.procs_blocked == 1)

local load = assert(Parsers.loadavg(fixture("proc/loadavg")))
near(load.one, 0.5)
assert(load.running == 2 and load.total == 200 and load.last_pid == 4321)

local memory = assert(Parsers.meminfo(fixture("proc/meminfo")))
assert(memory.MemTotal == 16384000 * 1024)
assert(memory["Active(anon)"] == 2000000 * 1024)

local pressure = assert(Parsers.psi(fixture("proc/pressure.memory")))
near(pressure.some.avg10, 0.10)
assert(pressure.full.total == 50)

local disks = assert(Parsers.diskstats(fixture("proc/diskstats.1")))
assert(#disks == 2 and disks[1].id == "8:0")
assert(disks[2].flushes_completed == 3)

local network = assert(Parsers.net_dev(fixture("proc/netdev.1")))
assert(#network == 2 and network[2].name == "eth0")
assert(network[2].rx_drops == 2 and network[2].tx_bytes == 3000)

local process = assert(Parsers.process_stat(fixture("proc/100.stat.1")))
assert(process.id == "100:1000")
assert(process.cpu_ticks == 150)
assert(process.rss_pages == 512)
local unusual = fixture("proc/100.stat.1"):gsub("%(worker%)", "(worker ) helper)")
local unusual_process = assert(Parsers.process_stat(unusual))
assert(unusual_process.comm == "worker ) helper")
local malformed_process = fixture("proc/100.stat.1"):gsub(" 1000 ", " broken ", 1)
local invalid_process, invalid_process_error = Parsers.process_stat(malformed_process)
assert(invalid_process == nil and invalid_process_error == "invalid_process_stat_number")
local short_process = "100 (worker) S 1 2 3 0 -1 1 0 0 0 0 1 1 0 0 20 0 1 0 10 20 3"
local parsed_short = assert(Parsers.process_stat(short_process))
assert(parsed_short.processor == nil, "absent optional processor must not be invented as CPU 0")

assert(Parsers.loadavg("0.1 0.2 0.3 1/2 3 junk") == nil)
assert(Parsers.diskstats("8 0 sda 1 2 broken 4 5 6 7 8 9 10 11") == nil)
assert(Parsers.diskstats("8 0 sda 1 2 3") == nil)
assert(Parsers.net_dev("eth0: 1 2 3 bad 5 6 7 8 9 10 11 12 13 14 15 16") == nil)
assert(Parsers.net_dev("eth0: 1 2 3") == nil)
assert(Parsers.proc_stat("cpu 9223372036854775807 0 0 1") == nil)
assert(Parsers.meminfo("MemTotal: 1 bananas\n") == nil)
assert(Parsers.vmstat("pgfault 1 trailing\n") == nil)
assert(Parsers.psi("some avg10=1 avg60=2 total=3\n") == nil)

local status = assert(Parsers.process_status(fixture("proc/100.status")))
assert(status.uid == 1000 and status.rss_bytes == 4096 * 1024)
local io = assert(Parsers.process_io(fixture("proc/100.io")))
assert(io.read_bytes == 4096 and io.write_bytes == 8192)
assert(Parsers.process_status("Uid: nope\n") == nil)
assert(Parsers.process_io("read_bytes: 1 trailing\n") == nil)
assert(Parsers.cgroup("broken") == nil)
local cgroups = Parsers.cgroup(fixture("proc/100.cgroup"))
assert(cgroups[1].path == "/user.slice/user-1000.slice/session-2.scope")

local fdinfo = assert(Parsers.drm_fdinfo([[
drm-driver: amdgpu
drm-client-id: 7
drm-engine-gfx: 123456 ns
drm-memory-vram: 128 MiB
]]))
assert(fdinfo["drm-driver"] == "amdgpu")
assert(fdinfo.engines_ns.gfx == 123456)
assert(fdinfo.memory_bytes.vram == 128 * 1024 * 1024)
local unknown_memory_unit = assert(Parsers.drm_fdinfo("drm-memory-vram: 2 widgets\n"))
assert(unknown_memory_unit.memory_bytes.vram == nil)
assert(unknown_memory_unit.unknown["drm-memory-vram"].unit == "widgets")

return true
