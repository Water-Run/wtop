package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local GPU = require("wtop.collectors.gpu")

-- The reason column.  Both reasons are categories, and the samples below are
-- what decide them: instrumenting the collector's two quality locals across
-- this whole suite showed `partial` reached by ten distinct causes and
-- `estimated` by two, and eight of the ten were reads that failed or never
-- happened while two were reads that *succeeded* and still produced nothing
-- usable.  Each sample isolates one of the two, and each is asserted for the
-- absence of the facts that would make the other sentence true -- which is
-- what a mutation that swapped the two codes would change.
local GPU_REASON = { partial = "gpu_data_incomplete",
  estimated = "gpu_identity_inferred", fresh = false }
local gpu_reason_is = function(result, label)
  return require("support.collector_reason").assert_reason(result, GPU_REASON, label)
end

local function fixture(path)
  local file = assert(io.open("tests/fixtures/" .. path, "rb"))
  local content = assert(file:read("*a"))
  file:close()
  return content
end

local function copy_array(values)
  local output = {}
  for index, value in ipairs(values) do output[index] = value end
  return output
end

local function fake_fs(files, directories, links, list_errors, read_counts, list_limits)
  local fs = {}
  function fs:read(path, limit)
    read_counts[path] = (read_counts[path] or 0) + 1
    local source = files[path]
    local value, injected_error
    if type(source) == "function" then value, injected_error = source(path, limit)
    else value = source end
    if value == nil then
      return nil, injected_error or { kind = "missing", message = "fixture_missing", path = path }
    end
    value = tostring(value)
    if limit and #value > limit then
      return nil, { kind = "too_large", message = "file_exceeds_limit", path = path }
    end
    return value
  end
  function fs:read_number(path)
    local content, err = self:read(path, 256)
    if not content then return nil, err end
    local token = content:match("^%s*([^%s]+)")
    local value = token and tonumber(token)
    if value == nil then
      return nil, { kind = "parse_error", message = "expected_number", path = path }
    end
    return value
  end
  function fs:list(path, limit)
    list_limits[path] = limit
    if list_errors[path] then return nil, list_errors[path] end
    local values = directories[path]
    if not values then
      return nil, { kind = "missing", message = "fixture_directory_missing", path = path }
    end
    local output = copy_array(values)
    local truncated = limit ~= nil and #output > limit
    if truncated then
      for index = #output, limit + 1, -1 do output[index] = nil end
    end
    return output, nil, truncated
  end
  function fs:readlink(path)
    local value = links[path]
    if value then return value end
    return nil, { kind = "missing", message = "fixture_link_missing", path = path }
  end
  return fs
end

local function near(actual, expected, epsilon)
  assert(type(actual) == "number", "expected number, got " .. tostring(actual))
  assert(math.abs(actual - expected) <= (epsilon or 1e-6), tostring(actual) .. " ~= " .. tostring(expected))
end

local base_stat = fixture("proc/100.stat.1")
local function stat_for(pid, name, starttime)
  local value = base_stat:gsub("^100 ", tostring(pid) .. " ", 1)
  value = value:gsub("%(worker%)", "(" .. name .. ")", 1)
  value = value:gsub(" 1000 10485760 ", " " .. tostring(starttime) .. " 10485760 ", 1)
  return value
end

local state = "1"
local files = {
  ["/usr/share/hwdata/pci.ids"] = table.concat({
    "1002  Advanced Micro Devices, Inc. [AMD/ATI]",
    "\t73bf  Navi 21 [Radeon RX 6800/6800 XT / 6900 XT]",
    "8086  Intel Corporation",
    "\t46a6  Alder Lake-P Integrated Graphics Controller",
    "\t\t17aa 3801  Lenovo Alder Lake-P board",
    "17aa  Lenovo",
    "\t3801  Conflicting top-level device name",
  }, "\n") .. "\n",
  ["/drm/card0/device/uevent"] = "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n",
  ["/drm/card0/device/vendor"] = "0x1002\n",
  ["/drm/card0/device/device"] = "0x73bf\n",
  ["/drm/card0/device/current_link_speed"] = "Unknown\n",
  ["/drm/card0/device/current_link_width"] = "0\n",
  ["/drm/card0/device/max_link_speed"] = "Unknown\n",
  ["/drm/card0/device/max_link_width"] = "255\n",
  ["/drm/card0/dev"] = "226:0\n",
  ["/drm/card0/device/gpu_busy_percent"] = "71\n",
  ["/drm/card0/device/mem_busy_percent"] = "42\n",
  ["/drm/card0/device/mem_info_vram_total"] = "17179869184\n",
  ["/drm/card0/device/mem_info_vram_used"] = "4294967296\n",
  ["/drm/card0/device/mem_info_vis_vram_total"] = "8589934592\n",
  ["/drm/card0/device/mem_info_vis_vram_used"] = "2147483648\n",
  ["/drm/card0/device/mem_info_gtt_total"] = "4294967296\n",
  ["/drm/card0/device/mem_info_gtt_used"] = "1073741824\n",
  ["/drm/card0/device/pp_dpm_sclk"] = fixture("gpu/amdgpu-pp-dpm-sclk"),
  ["/drm/card0/device/pp_dpm_mclk"] = fixture("gpu/amdgpu-pp-dpm-mclk"),
  ["/drm/card0/device/hwmon/hwmon5/temp1_input"] = "65000\n",
  ["/drm/card0/device/hwmon/hwmon5/power1_average"] = "120000000\n",

  ["/drm/card1/device/uevent"] = "DRIVER=i915\nPCI_SLOT_NAME=0000:00:02.0\n",
  ["/drm/card1/device/vendor"] = "0x8086\n",
  ["/drm/card1/device/device"] = "0x46a6\n",
  ["/drm/card1/device/class"] = "0x030000\n",
  ["/drm/card1/device/revision"] = "0x0c\n",
  ["/drm/card1/device/subsystem_vendor"] = "0x17aa\n",
  ["/drm/card1/device/subsystem_device"] = "0x3801\n",
  ["/drm/card1/device/boot_vga"] = "1\n",
  ["/drm/card1/device/numa_node"] = "-1\n",
  ["/drm/card1/device/current_link_speed"] = "8.0 GT/s PCIe\n",
  ["/drm/card1/device/current_link_width"] = "8\n",
  ["/drm/card1/device/max_link_speed"] = "16.0 GT/s PCIe\n",
  ["/drm/card1/device/max_link_width"] = "16\n",
  ["/drm/card1/device/power/runtime_status"] = "active\n",
  ["/drm/card1/device/modalias"] = "pci:v00008086d000046A6sv000017AAsd00003801bc03sc00i00\n",
  ["/drm/card1/dev"] = "226:1\n",
  ["/drm/card1/gt/gt0/rps_act_freq_mhz"] = "450\n",
  ["/drm/card1/gt/gt0/rps_cur_freq_mhz"] = "300\n",
  ["/drm/card1/gt/gt0/rps_min_freq_mhz"] = "100\n",
  ["/drm/card1/gt/gt0/rps_max_freq_mhz"] = "1500\n",
  ["/drm/card1/gt/gt0/rps_RPn_freq_mhz"] = "100\n",
  ["/drm/card1/gt/gt0/rps_RP1_freq_mhz"] = "600\n",
  ["/drm/card1/gt/gt0/rps_RP0_freq_mhz"] = "1500\n",
  ["/drm/card1/device/hwmon/hwmon9/temp1_input"] = "55000\n",

  ["/drm/renderD128/device/uevent"] = "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n",
  ["/drm/renderD128/dev"] = "226:128\n",
  ["/drm/renderD129/device/uevent"] = "DRIVER=i915\nPCI_SLOT_NAME=0000:00:02.0\n",
  ["/drm/renderD129/dev"] = "226:129\n",

  ["/proc/100/stat"] = stat_for(100, "render-a", 1000),
  ["/proc/100/status"] = "Name:\trender-a\nUid:\t1000\t1000\t1000\t1000\n",
  ["/proc/100/fdinfo/10"] = function() return fixture("gpu/amdgpu-fdinfo." .. state) end,
  ["/proc/100/fdinfo/11"] = function() return fixture("gpu/amdgpu-fdinfo." .. state) end,
  ["/proc/100/fdinfo/12"] = "pos:\t0\nflags:\t0100002\n",
  ["/proc/101/stat"] = stat_for(101, "render-b", 1001),
  ["/proc/101/status"] = "Name:\trender-b\nUid:\t1001\t1001\t1001\t1001\n",
  ["/proc/101/fdinfo/7"] = function() return fixture("gpu/amdgpu-fdinfo." .. state) end,
  ["/proc/102/stat"] = stat_for(102, "media", 1002),
  ["/proc/102/status"] = "Name:\tmedia\nUid:\t1002\t1002\t1002\t1002\n",
  ["/proc/102/fdinfo/8"] = function()
    local suffix = state == "1" and "1" or "2"
    return fixture("gpu/intel-fdinfo." .. suffix)
  end,
  ["/proc/103/stat"] = stat_for(103, "copy", 1003),
  ["/proc/103/status"] = "Name:\tcopy\nUid:\t1003\t1003\t1003\t1003\n",
  ["/proc/103/fdinfo/5"] = function()
    local content = fixture("gpu/intel-fdinfo-node")
    if state ~= "1" then content = content:gsub("25000000", "125000000") end
    return content
  end,
  ["/proc/104/stat"] = stat_for(104, "denied-fd", 1004),
  ["/proc/104/fdinfo/6"] = function()
    return nil, { kind = "denied", message = "permission denied", path = "/proc/104/fdinfo/6" }
  end,
  ["/proc/999/stat"] = stat_for(999, "hidden", 1999),
}

local directories = {
  ["/drm"] = {
    "card1-HDMI-A-1", "renderD129", "card1", "card0-DP-1", "renderD128", "card0", "version",
  },
  ["/drm/card0/device/hwmon"] = { "hwmon5" },
  ["/drm/card1/device/hwmon"] = { "hwmon9" },
  ["/drm/card1/gt"] = { "gt0" },
  ["/proc"] = { "self", "999", "104", "103", "777", "102", "101", "100" },
  ["/proc/100/fdinfo"] = { "12", "11", "10" },
  ["/proc/101/fdinfo"] = { "7" },
  ["/proc/102/fdinfo"] = { "8" },
  ["/proc/103/fdinfo"] = { "5" },
  ["/proc/104/fdinfo"] = { "6" },
}

local links = {
  ["/drm/card0/device"] = "../../../0000:03:00.0",
  ["/drm/card0/device/driver"] = "../../../../bus/pci/drivers/amdgpu",
  ["/drm/card1/device"] = "../../../0000:00:02.0",
  ["/drm/card1/device/driver"] = "../../../../bus/pci/drivers/i915",
  ["/drm/renderD128/device"] = "../../../0000:03:00.0",
  ["/drm/renderD128/device/driver"] = "../../../../bus/pci/drivers/amdgpu",
  ["/drm/renderD129/device"] = "../../../0000:00:02.0",
  ["/drm/renderD129/device/driver"] = "../../../../bus/pci/drivers/i915",
  ["/proc/103/fd/5"] = "/dev/dri/renderD129",
}

local list_errors = {
  ["/proc/999/fdinfo"] = { kind = "denied", message = "permission denied", path = "/proc/999/fdinfo" },
}
local read_counts = {}
local list_limits = {}
local fs = fake_fs(files, directories, links, list_errors, read_counts, list_limits)
local now = 1000000000
local context = { fs = fs, now_ns = function() return now end }
local collector = GPU.new({
  drm_path = "/drm",
  proc_path = "/proc",
  max_processes = 32,
  max_fds_per_process = 16,
  max_fdinfo_files = 64,
  max_clients = 32,
})

local capability = collector:probe(context)
assert(capability.available and capability.details.cards == 2 and capability.details.render_nodes == 2)

local parsed = assert(GPU.parse_fdinfo(fixture("gpu/intel-fdinfo.1")))
assert(parsed.driver == "i915" and parsed.client_id == "9" and parsed.pci_bdf == "0000:00:02.0")
assert(parsed.engines_ns.render == 50000000)
assert(parsed.maximum_frequency_hz.render == 1500000000)
assert(parsed.memory.resident.system0 == 48 * 1024 * 1024)

local dpm = assert(GPU.parse_dpm_states(fixture("gpu/amdgpu-pp-dpm-sclk"), "graphics"))
assert(dpm.current_hz == 1800000000 and dpm.minimum_hz == 500000000 and dpm.maximum_hz == 1800000000)

local pci_vendor, pci_device = GPU.parse_pci_ids_name(
  files["/usr/share/hwdata/pci.ids"], 0x8086, 0x46a6
)
assert(pci_vendor == "Intel Corporation")
assert(pci_device == "Alder Lake-P Integrated Graphics Controller")
local nested_vendor, nested_device, nested_subsystem = GPU.parse_pci_ids_name(table.concat({
  "8086  Intel Corporation",
  "\ta7a8  Raptor Lake-P UHD Graphics",
  "\t\t17aa 38b8  Lenovo integrated subsystem",
  "17aa  Lenovo",
  "\t38b8  Conflicting top-level subsystem device",
}, "\n"), 0x8086, 0xa7a8, 0x17aa, 0x38b8)
assert(nested_vendor == "Intel Corporation")
assert(nested_device == "Raptor Lake-P UHD Graphics")
assert(nested_subsystem == "Lenovo integrated subsystem",
  "a nested subsystem name must not be replaced by the subsystem vendor's top-level device")
local uppercase_vendor, vendor_only = GPU.parse_pci_ids_name(table.concat({
  "ABCD  Example Vendor\1",
  "\t0001  First Device",
  "DCBA  Other Vendor",
  "\t0002  Must Not Match",
}, "\n"), 0xabcd, 0x0002)
assert(uppercase_vendor == "Example Vendor�" and vendor_only == nil,
  "PCI lookup must stay inside the selected vendor section and sanitize names")
assert(GPU.parse_pci_ids_name(nil, 0x8086, 0x46a6) == nil)
assert(GPU.parse_pci_ids_name("8086  Intel\n", "8086", 0x46a6) == nil)

assert(GPU.parse_fdinfo(nil) == nil)
local missing_driver, missing_driver_error = GPU.parse_fdinfo("drm-client-id: 1\n")
assert(missing_driver == nil and missing_driver_error == "drm_driver_missing")
local malformed_fdinfo = assert(GPU.parse_fdinfo(table.concat({
  "drm-driver: i915",
  "drm-pdev: not-a-bdf",
  "drm-client-id: -1",
  "drm-engine-capacity-render: 0",
  "drm-engine-render: 1 ticks",
  "drm-maxfreq-render: 2 rpm",
  "drm-curfreq-render: 3 GHz",
  "drm-active-vram: 2 KB",
  "drm-total-cycles-render: -1",
  "drm-memory-vram: 4 MiB",
  "drm-resident-vram: 5 MiB",
  "drm-unknown-field: ignored",
}, "\n")))
assert(malformed_fdinfo.parse_errors == 7)
assert(malformed_fdinfo.pci_bdf == nil and malformed_fdinfo.client_id == nil)
assert(malformed_fdinfo.current_frequency_hz.render == 3000000000)
assert(malformed_fdinfo.memory.active.vram == nil)
assert(malformed_fdinfo.memory.resident.vram == 5 * 1024 * 1024,
  "standard resident memory must override the legacy drm-memory alias")

-- Values that cannot remain exact Lua integers are rejected instead of being
-- rounded before rate and memory calculations.
local oversized_fdinfo = assert(GPU.parse_fdinfo(table.concat({
  "drm-driver: amdgpu",
  "drm-engine-gfx: 9223372036854775808 ns",
  "drm-cycles-gfx: 9223372036854775808",
  "drm-resident-vram: 9223372036854775808 B",
}, "\n")))
assert(oversized_fdinfo.parse_errors == 3)
assert(oversized_fdinfo.engines_ns.gfx == nil)
assert(oversized_fdinfo.cycles.gfx == nil)
assert(oversized_fdinfo.memory.resident.vram == nil)

local bounded_dpm = assert(GPU.parse_dpm_states(
  string.rep("9", 400) .. ": 900MHz *\n0: 100MHz\n", "graphics"
))
assert(#bounded_dpm.states == 1 and bounded_dpm.states[1].level == 0)
assert(bounded_dpm.current_hz == nil)

local first = collector:sample(context)
assert(first.status == "ok" and first.quality == "partial")
-- A second, unrelated `partial`: a denied `/proc/<pid>/fdinfo` and a process
-- that exited mid-scan, against the same inventory.  The orphan sample below
-- reaches `partial` with every counter at zero, so between them the two
-- samples are `partial` for opposite reasons -- one where reads failed, one
-- where a read succeeded and the association could not be made -- and both
-- must carry the same category, because one sentence has to cover both.
assert(first.data.process_scan.denied > 0 and first.data.process_scan.unmatched_clients == 0)
gpu_reason_is(first, "the gpu sample with a denied and a raced descriptor")
assert(not pcall(GPU.new, "invalid"))
assert(not pcall(GPU.new, { max_fdinfo_bytes = 64 * 1024 * 1024 + 1 }))
assert(first.data.schema == "dev.waterrun.wtop.gpu/v2")
assert(#first.data.devices == 2)
local amd = assert(first.data.by_id["0000:03:00.0"])
local intel = assert(first.data.by_id["0000:00:02.0"])
assert(amd.stable_id == "pci:0000:03:00.0" and amd.card == "card0")
assert(amd.render_nodes[1] == "renderD128" and #amd.drm_nodes == 2)
assert(intel.render_nodes[1] == "renderD129" and #intel.drm_nodes == 2)
assert(amd.metrics.utilization_percent == 71 and amd.metrics.memory_busy_percent == 42)
assert(amd.metrics.utilization_source == "sysfs")
assert(amd.vendor_name == "Advanced Micro Devices, Inc. [AMD/ATI]")
assert(amd.model_name == "Navi 21 [Radeon RX 6800/6800 XT / 6900 XT]")
assert(amd.pci.current_link_speed == nil and amd.pci.current_link_width == nil)
assert(amd.pci.maximum_link_speed == nil and amd.pci.maximum_link_width == nil)
assert(intel.vendor_name == "Intel Corporation")
assert(intel.model_name == "Alder Lake-P Integrated Graphics Controller")
assert(intel.pci.class_id == 0x030000 and intel.pci.revision == 0x0c)
assert(intel.pci.class_name == "VGA compatible controller")
assert(intel.pci.subsystem_vendor_id == 0x17aa and intel.pci.subsystem_device_id == 0x3801)
assert(intel.pci.subsystem_vendor_name == "Lenovo")
assert(intel.pci.subsystem_model_name == "Lenovo Alder Lake-P board")
assert(intel.pci.boot_vga and intel.pci.numa_node == -1)
assert(intel.pci.current_link_speed == "8.0 GT/s PCIe" and intel.pci.current_link_width == 8)
assert(intel.pci.maximum_link_speed == "16.0 GT/s PCIe" and intel.pci.maximum_link_width == 16)
assert(intel.pci.runtime_status == "active")
assert(intel.pci.modalias == "pci:v00008086d000046A6sv000017AAsd00003801bc03sc00i00")
assert(intel.pci.pci_ids_source == "/usr/share/hwdata/pci.ids")
assert(amd.metrics.memory_total_bytes == 17179869184 and amd.metrics.memory_used_bytes == 4294967296)
assert(amd.metrics.visible_memory_total_bytes == 8589934592 and amd.metrics.gtt_used_bytes == 1073741824)
assert(amd.metrics.frequency_graphics_hz == 1800000000)
assert(amd.metrics.frequency_memory_hz == 1000000000)
-- The promoted scalar is one clock of the set, so it names itself.  Without
-- the id a consumer reading only `frequency_current_hz` cannot tell a
-- graphics clock from a memory clock, and on this card the two are different
-- quantities 800 MHz apart.
assert(amd.metrics.frequency_domain == "graphics")
assert(amd.frequencies.domains[1].id == "graphics"
  and amd.metrics.frequency_current_hz == amd.frequencies.domains[1].current_hz,
  "the promoted clock is the first sorted domain, and the id says so")
assert(intel.metrics.frequency_current_hz == 450000000)
assert(intel.metrics.frequency_domain == "gt0")
assert(intel.frequencies.by_id.gt0.maximum_hz == 1500000000)

-- GPU collection only links the global hwmon identity.  Sensor values are
-- neither read nor duplicated in this collector.
assert(amd.capabilities.hwmon and amd.hwmon_refs[1].class == "hwmon5")
assert(intel.hwmon_refs[1].class == "hwmon9")
assert(amd.metrics.temperature_celsius == nil and amd.metrics.power_watts == nil)
assert(read_counts["/drm/card0/device/hwmon/hwmon5/temp1_input"] == nil)
assert(read_counts["/drm/card0/device/hwmon/hwmon5/power1_average"] == nil)
assert(read_counts["/drm/card1/device/hwmon/hwmon9/temp1_input"] == nil)

-- Duplicate descriptors and inherited descriptors are deduplicated by the
-- standard device-scoped drm-client-id for device totals, while each process
-- retains its own client view.
assert(first.data.process_scan.quality == "partial")
assert(first.data.process_scan.denied == 2 and first.data.process_scan.races == 1)
assert(amd.processes.summary.process_count == 2 and amd.processes.summary.client_count == 1)
assert(amd.processes.clients[1].fd_references == 3)
assert(amd.processes.summary.memory.resident.vram == 128 * 1024 * 1024)
assert(amd.processes.summary.memory.resident.gtt == 32 * 1024 * 1024)
local process100 = assert(amd.processes.by_id["100:1000"])
assert(process100.uid == 1000 and process100.clients[1].fd_count == 2)
assert(process100.clients[1].engines.gfx.rate_quality == "gap")
assert(intel.processes.summary.process_count == 2 and intel.processes.summary.client_count == 2)
assert(intel.processes.by_id["103:1003"].clients[1].mapping_quality == "fresh")

state = "2"
now = now + 1000000000
local second = collector:sample(context, first)
amd = assert(second.data.by_id["0000:03:00.0"])
intel = assert(second.data.by_id["0000:00:02.0"])
local amd_client = amd.processes.clients[1]
near(amd_client.engines.gfx.utilization_percent, 20)
near(amd_client.engines.compute.utilization_percent, 2)
near(amd.processes.summary.utilization_percent, 20)
near(amd.processes.by_id["100:1000"].utilization_percent, 20)
near(amd.processes.by_id["101:1001"].utilization_percent, 20)
assert(amd.processes.summary.memory.resident.vram == 192 * 1024 * 1024)
local intel_client = assert(intel.processes.clients_by_id["0000:00:02.0:i915:9"])
near(intel_client.engines.render.utilization_percent, 10)
near(intel_client.engines.render.cycle_utilization_percent, 20)
local node_client = assert(intel.processes.clients_by_id["0000:00:02.0:i915:10"])
near(node_client.engines.copy.cycle_utilization_percent, 10)
near(node_client.engines.copy.utilization_percent, 10)
near(intel.metrics.utilization_percent, 10)
assert(intel.metrics.utilization_source == "drm_fdinfo")
assert(intel.metrics.process_memory_bytes == 72 * 1024 * 1024)
assert(intel.metrics.process_memory_source == "drm_fdinfo")

-- DRM engine counters may temporarily move backwards.  The standard says to
-- retain the prior high water mark until the reported value catches up.
state = "held"
now = now + 1000000000
local held = collector:sample(context, second)
amd_client = held.data.by_id["0000:03:00.0"].processes.clients[1]
assert(amd_client.engines.gfx.rate_quality == "held")
assert(amd_client.engines.gfx.high_water_ns == 300000000)
near(amd_client.engines.gfx.utilization_percent, 0)

-- Rates use the timestamp taken with each fdinfo observation, rather than the
-- previous sample's end timestamp.  A long scan tail must not shrink the
-- denominator and inflate a 20% engine interval to 100%.
local original_read = fs.read
local skew_generation = 1
local skew_now = 10000000000
function fs:read(path, limit)
  local content, err = original_read(self, path, limit)
  if path == "/proc/100/fdinfo/10" or path == "/proc/100/fdinfo/11" then
    skew_now = skew_generation == 1 and 10000000000 or 11000000000
  elseif path == "/proc/103/fdinfo/5" then
    skew_now = skew_generation == 1 and 10900000000 or 11900000000
  end
  return content, err
end
local skew_context = { fs = fs, now_ns = function() return skew_now end }
local skew_collector = GPU.new({
  drm_path = "/drm", proc_path = "/proc", max_processes = 32,
  max_fds_per_process = 16, max_fdinfo_files = 64, max_clients = 32,
})
state = "1"
local skew_first = skew_collector:sample(skew_context)
assert(skew_first.timestamp_ns == 10900000000)
skew_generation = 2
skew_now = 11000000000
state = "2"
local skew_second = skew_collector:sample(skew_context, skew_first)
near(skew_second.data.by_id["0000:03:00.0"].processes.clients[1]
  .engines.gfx.utilization_percent, 20)
fs.read = original_read

-- Every high-cardinality dimension is bounded, including deterministic card
-- selection even when the injected class listing is unsorted.
local process_limited = GPU.new({
  drm_path = "/drm", proc_path = "/proc", max_processes = 1,
}):sample(context)
assert(process_limited.data.process_scan.truncated)
assert(process_limited.data.process_scan.scanned_processes == 1)
assert(list_limits["/proc"] == 129)

list_limits["/proc"] = "not-called"
local summary_only = collector:sample({
  fs = fs,
  now_ns = function() return now end,
  scan_gpu_processes = false,
}, first)
assert(summary_only.data.process_scan.enabled == false)
assert(summary_only.data.process_scan.status == "disabled")
assert(summary_only.data.process_scan.scanned_processes == 0)
assert(list_limits["/proc"] == "not-called",
  "summary-only GPU sampling must not enumerate process fdinfo")
now = now + 1000000000
local resumed = collector:sample(context, summary_only)
local resumed_engine = resumed.data.by_id["0000:03:00.0"].processes.clients[1].engines.gfx
assert(resumed_engine.rate_quality ~= "gap",
  "summary-only samples must not erase the last deep fdinfo counter baseline")

local fd_limited = GPU.new({
  drm_path = "/drm", proc_path = "/proc", max_fds_per_process = 1,
}):sample(context)
assert(fd_limited.data.process_scan.truncated)
assert(list_limits["/proc/100/fdinfo"] == 1)

local card_limited = GPU.new({
  drm_path = "/drm", proc_path = "/proc", scan_processes = false, max_cards = 1,
}):sample(context)
assert(#card_limited.data.devices == 1 and card_limited.data.devices[1].card == "card0")
assert(card_limited.data.drm_scan.truncated)

local memory_clock_reads = read_counts["/drm/card0/device/pp_dpm_mclk"] or 0
local frequency_limited = GPU.new({
  drm_path = "/drm", proc_path = "/proc", scan_processes = false, max_frequency_domains = 1,
}):sample(context)
local limited_amd = assert(frequency_limited.data.by_id["0000:03:00.0"])
assert(limited_amd.frequencies.truncated and #limited_amd.frequencies.domains == 1)
assert(limited_amd.frequencies.domains[1].id == "graphics")
assert((read_counts["/drm/card0/device/pp_dpm_mclk"] or 0) == memory_clock_reads)
assert(frequency_limited.data.truncated)

local invalid_scan_policy = collector:sample({
  fs = fs, now_ns = function() return now end, scan_gpu_processes = "yes",
})
assert(invalid_scan_policy.status == "error")
assert(invalid_scan_policy.reason == "invalid_gpu_process_scan_policy")

-- Sysfs integer attributes use unsigned decimal syntax.  Lua's tonumber()
-- also accepts exponents, hexadecimal and trailing tokens, none of which are
-- valid values for these kernel attributes.
local saved_busy = files["/drm/card0/device/gpu_busy_percent"]
local saved_memory = files["/drm/card0/device/mem_info_vram_total"]
local saved_frequency = files["/drm/card1/gt/gt0/rps_act_freq_mhz"]
files["/drm/card0/device/gpu_busy_percent"] = "1e2\n"
files["/drm/card0/device/mem_info_vram_total"] = "0x400\n"
files["/drm/card1/gt/gt0/rps_act_freq_mhz"] = "450 trailing\n"
local malformed_sysfs = GPU.new({
  drm_path = "/drm", proc_path = "/proc", scan_processes = false,
}):sample(context)
local malformed_amd = assert(malformed_sysfs.data.by_id["0000:03:00.0"])
local malformed_intel = assert(malformed_sysfs.data.by_id["0000:00:02.0"])
assert(malformed_amd.metrics.utilization_percent == nil)
assert(malformed_amd.metrics.memory_total_bytes == nil)
assert(malformed_intel.frequencies.by_id.gt0.actual_hz == nil)
local malformed_fields = {}
for _, issue in ipairs(malformed_amd.issues) do malformed_fields[issue.field] = issue.reason end
for _, issue in ipairs(malformed_intel.issues) do malformed_fields[issue.field] = issue.reason end
assert(malformed_fields.utilization == "expected_unsigned_integer")
assert(malformed_fields["memory.vram_total"] == "expected_unsigned_integer")
assert(malformed_fields["frequency.gt0.actual"] == "expected_unsigned_integer")
files["/drm/card0/device/gpu_busy_percent"] = saved_busy
files["/drm/card0/device/mem_info_vram_total"] = saved_memory
files["/drm/card1/gt/gt0/rps_act_freq_mhz"] = saved_frequency

-- A clock that is powered down reports 0, and 0 is not a frequency.  This is
-- not hypothetical: on the development host `rps_act_freq_mhz` reads 0 for
-- most of every second, because the GT sits in RC6 whenever nothing is
-- drawing, while `rps_cur_freq_mhz` keeps reporting the clock the hardware is
-- set to.  Lua's `or` treats 0 as a present value, so preferring the actual
-- reading published the zero and the GPU table read 0 Hz on a GPU running at
-- 300 MHz.  The set has to prefer a reading that is actually a reading.
local saved_current = files["/drm/card1/gt/gt0/rps_cur_freq_mhz"]
files["/drm/card1/gt/gt0/rps_act_freq_mhz"] = "0\n"
files["/drm/card1/gt/gt0/rps_cur_freq_mhz"] = "300\n"
local asleep = GPU.new({
  drm_path = "/drm", proc_path = "/proc", scan_processes = false,
}):sample(context)
local asleep_intel = assert(asleep.data.by_id["0000:00:02.0"])
assert(asleep_intel.metrics.frequency_current_hz == 300000000,
  "a powered-down actual reading must not be promoted over the real one: "
    .. tostring(asleep_intel.metrics.frequency_current_hz))
-- The kernel's own zero is kept on the domain, because it is what the kernel
-- said, and the clock is still reported as one of the device's clocks.
assert(asleep_intel.frequencies.by_id.gt0.actual_hz == 0,
  "the raw reading stays visible rather than being rewritten")
assert(asleep_intel.frequencies.by_id.gt0.current_hz == 300000000)
assert(asleep_intel.frequencies.by_id.gt0.quality == nil,
  "a clock with a current reading is available, and says nothing about its absence")
assert(asleep_intel.metrics.frequency_domain == "gt0",
  "the promoted figure is still attributed to a clock")

-- With nothing running and nothing set, there is no figure to promote and the
-- document must say the clock is unavailable rather than report 0 Hz.  A zero
-- here is the claim "this clock runs at zero", which is a different statement
-- from "this clock is not running", and only one of them is true.
files["/drm/card1/gt/gt0/rps_cur_freq_mhz"] = "0\n"
local powered_down = GPU.new({
  drm_path = "/drm", proc_path = "/proc", scan_processes = false,
}):sample(context)
local down_intel = assert(powered_down.data.by_id["0000:00:02.0"])
assert(down_intel.metrics.frequency_current_hz == nil,
  "a clock with no running reading promotes no frequency, not a zero: "
    .. tostring(down_intel.metrics.frequency_current_hz))
assert(down_intel.frequencies.by_id.gt0.quality == "unavailable",
  "and the domain states that it is unavailable rather than reading zero")
-- Minimum and maximum survive: they describe the clock's range, which is a
-- property of the hardware and does not stop being true when the clock is off.
assert(down_intel.metrics.frequency_maximum_hz == 1500000000,
  "a powered-down clock still has a ceiling")
assert(down_intel.metrics.frequency_domain == "gt0",
  "and the promoted range is attributed to the clock it describes")
files["/drm/card1/gt/gt0/rps_act_freq_mhz"] = saved_frequency
files["/drm/card1/gt/gt0/rps_cur_freq_mhz"] = saved_current

-- The same rule on the other promotion path.  An amdgpu DPM table may mark a
-- 0 MHz level as the active one -- the memory clock drops to a powered-down
-- level on its own -- and that zero is a state, not a rate.  Publishing it
-- would also collide with a card that reports no memory clock at all, which is
-- the one distinction a reader of this figure most needs.
local saved_mclk = files["/drm/card0/device/pp_dpm_mclk"]
files["/drm/card0/device/pp_dpm_mclk"] = "0: 0Mhz *\n1: 1000Mhz\n"
local idle_memory = GPU.new({
  drm_path = "/drm", proc_path = "/proc", scan_processes = false,
}):sample(context)
local idle_amd = assert(idle_memory.data.by_id["0000:03:00.0"])
assert(idle_amd.metrics.frequency_memory_hz == nil,
  "a memory clock parked at 0 MHz is not a memory clock reading: "
    .. tostring(idle_amd.metrics.frequency_memory_hz))
assert(idle_amd.metrics.frequency_graphics_hz == 1800000000,
  "and the clock that is running is still reported")
assert(idle_amd.frequencies.by_id.memory.quality == "unavailable",
  "the parked clock states that it is unavailable")
assert(idle_amd.frequencies.by_id.memory.states[1].frequency_hz == 0,
  "while its DPM table still lists the 0 MHz level, which is the real state")
assert(idle_amd.frequencies.by_id.memory.maximum_hz == 1000000000,
  "and the clock's ceiling is a property of the hardware, not of its state")
files["/drm/card0/device/pp_dpm_mclk"] = saved_mclk

-- Denied and malformed optional PCI attributes must remain absent without
-- manufacturing plausible values; permission failures stay visible in the
-- bounded issue list and degrade only the affected device.
local saved_vendor = files["/drm/card1/device/vendor"]
local saved_class = files["/drm/card1/device/class"]
local saved_boot = files["/drm/card1/device/boot_vga"]
local saved_runtime = files["/drm/card1/device/power/runtime_status"]
files["/drm/card1/device/vendor"] = "not-a-pci-id\n"
files["/drm/card1/device/class"] = function()
  return nil, { kind = "denied", message = "permission denied", path = "/drm/card1/device/class" }
end
files["/drm/card1/device/boot_vga"] = "2\n"
files["/drm/card1/device/power/runtime_status"] = function()
  return nil, { kind = "denied", message = "permission denied",
    path = "/drm/card1/device/power/runtime_status" }
end
local degraded_static = GPU.new({
  drm_path = "/drm", proc_path = "/proc", scan_processes = false,
}):sample(context)
local degraded_intel = assert(degraded_static.data.by_id["0000:00:02.0"])
assert(degraded_intel.vendor_id == nil and degraded_intel.vendor == "unknown")
assert(degraded_intel.identity_quality == "estimated")
assert(degraded_intel.pci.class_id == nil and degraded_intel.pci.boot_vga == nil)
assert(degraded_intel.pci.runtime_status == nil and degraded_intel.partial)
local degraded_issues = {}
for _, issue in ipairs(degraded_intel.issues) do degraded_issues[issue.field] = issue end
assert(degraded_issues["identity.class"].status == "denied")
assert(degraded_issues["pci.boot_vga"].reason == "number_out_of_range")
-- A third `partial` family: the inventory itself, with no process scan and no
-- unattributable node.  One code for all three, because the sentence has to
-- cover a denied read, a raced read and an unusable attribute alike.
assert(degraded_static.data.process_scan.enabled == false)
assert(degraded_static.data.drm_scan.unattached_render_nodes == 0)
gpu_reason_is(degraded_static, "the gpu sample with unusable device attributes")
assert(degraded_issues["power.runtime_status"].status == "denied")
files["/drm/card1/device/vendor"] = saved_vendor
files["/drm/card1/device/class"] = saved_class
files["/drm/card1/device/boot_vga"] = saved_boot
files["/drm/card1/device/power/runtime_status"] = saved_runtime

-- pci.ids lookup falls through denied/missing candidates once, caches the
-- bounded database, and still reports numeric PCI identity when no name exists.
local fallback_reads = {}
local fallback_files = {
  ["/pci/first"] = function()
    return nil, { kind = "denied", message = "permission denied", path = "/pci/first" }
  end,
  ["/pci/second"] = "1234  Fallback Vendor\n\t5678  Fallback GPU\n",
  ["/fallback/card0/device/uevent"] = "DRIVER=example\nPCI_SLOT_NAME=0000:05:00.0\n",
  ["/fallback/card0/device/vendor"] = "0x1234\n",
  ["/fallback/card0/device/device"] = "0x5678\n",
  ["/fallback/card0/dev"] = "226:5\n",
}
local fallback_fs = fake_fs(fallback_files, {
  ["/fallback"] = { "card0" },
}, {
  ["/fallback/card0/device"] = "../../../0000:05:00.0",
  ["/fallback/card0/device/driver"] = "../../../../bus/pci/drivers/example",
}, {}, fallback_reads, {})
local fallback_collector = GPU.new({
  drm_path = "/fallback", proc_path = "/empty-proc", scan_processes = false,
  pci_ids_paths = { "/pci/first", "/pci/second" },
})
local fallback_sample = fallback_collector:sample({ fs = fallback_fs, now_ns = function() return 1 end })
local fallback_gpu = assert(fallback_sample.data.by_id["0000:05:00.0"])
assert(fallback_gpu.vendor_name == "Fallback Vendor" and fallback_gpu.model_name == "Fallback GPU")
assert(fallback_gpu.pci.pci_ids_source == "/pci/second")
fallback_files["/pci/second"] = "1234  Changed Vendor\n\t5678  Changed GPU\n"
local cached_fallback = fallback_collector:sample({ fs = fallback_fs, now_ns = function() return 2 end })
assert(cached_fallback.data.by_id["0000:05:00.0"].model_name == "Fallback GPU")
assert(fallback_reads["/pci/first"] == 1 and fallback_reads["/pci/second"] == 1)

local denied_inventory_fs = fake_fs({}, {}, {}, {
  ["/denied-drm"] = { kind = "denied", message = "permission denied", path = "/denied-drm" },
}, {}, {})
local denied_inventory = GPU.new({
  drm_path = "/denied-drm", proc_path = "/proc", scan_processes = false,
}):probe({ fs = denied_inventory_fs })
assert(denied_inventory.state == "denied" and not denied_inventory.available)

-- Exercise calculations at the signed integer boundary.  Multiplication by
-- 100 and addition used to wrap before Lua promoted anything to a float.
local overflow_generation = 1
local overflow_now = 1000000000
local max_integer_text = tostring(math.maxinteger)
local function overflow_client(client_id, with_engines)
  local counter = overflow_generation == 1 and "0" or max_integer_text
  local lines = {
    "drm-driver: amdgpu",
    "drm-client-id: " .. tostring(client_id),
    "drm-pdev: 0000:04:00.0",
    "drm-resident-vram: " .. max_integer_text .. " B",
  }
  if with_engines then
    lines[#lines + 1] = "drm-engine-render: " .. counter .. " ns"
    lines[#lines + 1] = "drm-cycles-copy: " .. counter
    lines[#lines + 1] = "drm-total-cycles-copy: " .. counter
    lines[#lines + 1] = "drm-cycles-video: " .. counter
    lines[#lines + 1] = "drm-maxfreq-video: 1 Hz"
  end
  return table.concat(lines, "\n") .. "\n"
end

local overflow_files = {
  ["/overflow/card0/device/uevent"] = "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:04:00.0\n",
  ["/overflow/card0/device/vendor"] = "0x1002\n",
  ["/overflow/card0/device/device"] = "0x73bf\n",
  ["/overflow/card0/dev"] = "226:4\n",
  ["/overflow-proc/1/stat"] = stat_for(1, "overflow", 4000),
  ["/overflow-proc/1/status"] = "Name:\toverflow\nUid:\t1000\t1000\t1000\t1000\n",
  ["/overflow-proc/1/fdinfo/3"] = function() return overflow_client(1, true) end,
  ["/overflow-proc/1/fdinfo/4"] = function() return overflow_client(2, false) end,
}
local oversized_index = "999999999999999999999999"
local overflow_directories = {
  ["/overflow"] = { "card0", "card000", "card" .. oversized_index, "renderD" .. oversized_index },
  ["/overflow-proc"] = { "1", oversized_index },
  ["/overflow-proc/1/fdinfo"] = { "3", "4", "0003", oversized_index },
}
local overflow_links = {
  ["/overflow/card0/device"] = "../../../0000:04:00.0",
  ["/overflow/card0/device/driver"] = "../../../../bus/pci/drivers/amdgpu",
}
local overflow_fs = fake_fs(
  overflow_files, overflow_directories, overflow_links, {}, {}, {}
)
local overflow_context = {
  fs = overflow_fs,
  now_ns = function() return overflow_now end,
}
local overflow_collector = GPU.new({
  drm_path = "/overflow", proc_path = "/overflow-proc",
  max_processes = 8, max_fds_per_process = 8,
  max_fdinfo_files = 8, max_clients = 8,
})
local overflow_first = overflow_collector:sample(overflow_context)
assert(#overflow_first.data.devices == 1)
assert(overflow_first.data.process_scan.scanned_processes == 1)
assert(overflow_first.data.process_scan.scanned_fdinfo_files == 2)
overflow_generation = 2
overflow_now = overflow_now + 1000000000
local overflow_second = overflow_collector:sample(overflow_context, overflow_first)
local overflow_device = assert(overflow_second.data.by_id["0000:04:00.0"])
local overflow_client_one = assert(
  overflow_device.processes.clients_by_id["0000:04:00.0:amdgpu:1"]
)
near(overflow_client_one.engines.render.utilization_percent, 100)
near(overflow_client_one.engines.copy.cycle_utilization_percent, 100)
near(overflow_client_one.engines.video.cycle_utilization_percent, 100)
local resident_total = overflow_device.processes.summary.memory.resident.vram
assert(resident_total > math.maxinteger and resident_total < math.huge)
assert(overflow_device.processes.list[1].memory.resident.vram == resident_total)

assert(not pcall(GPU.new, { max_processes = 0 }))
assert(not pcall(GPU.new, { max_fdinfo_bytes = -1 }))
assert(not pcall(GPU.new, { max_clients = 2147483648 }))
assert(not pcall(GPU.new, { max_cards = 0 / 0 }))

-- A render node that publishes neither a bus address nor a device symlink, on
-- a host with exactly one device of its driver.  The collector attaches it by
-- driver-uniqueness, which is a guess about which GPU it belongs to, and that
-- is the entire cause of the `estimated` here: the device's own identity is
-- complete and every read succeeded.
local link_guess_fs = fake_fs({
  ["/link/card0/device/uevent"] = "DRIVER=example\nPCI_SLOT_NAME=0000:06:00.0\n",
  ["/link/card0/device/vendor"] = "0x10de\n",
  ["/link/card0/device/device"] = "0x2684\n",
  ["/link/card0/dev"] = "226:6\n",
  ["/link/renderD128/device/uevent"] = "DRIVER=example\n",
  ["/link/renderD128/dev"] = "226:128\n",
}, { ["/link"] = { "renderD128", "card0" } }, {
  ["/link/card0/device"] = "../../../0000:06:00.0",
  ["/link/card0/device/driver"] = "../../../../bus/pci/drivers/example",
  ["/link/renderD128/device/driver"] = "../../../../bus/pci/drivers/example",
}, {}, {}, {})
local link_guess = GPU.new({
  drm_path = "/link", proc_path = "/link-proc", scan_processes = false,
}):sample({ fs = link_guess_fs, now_ns = function() return 1 end })
assert(link_guess.quality == "estimated",
  "a render node attached by driver-uniqueness is estimated, not fresh")
assert(link_guess.data.drm_scan.estimated_render_links == 1)
local linked_device = assert(link_guess.data.devices[1])
assert(linked_device.identity_quality == "fresh",
  "the guess is in the node's attachment, not in the device's identity")
assert(not linked_device.partial and next(linked_device.errors or {}) == nil,
  "every read on this tree succeeded; the cause is the inferred attachment")
assert(#linked_device.render_nodes == 1)
gpu_reason_is(link_guess, "a gpu sample whose render node was attached by inference")

-- The other of the two.  A DRM client naming a bus address that is not in the
-- device list, on a host whose only device is driven by something else.  Every
-- byte of the client was read successfully and the parse succeeded; what could
-- not be produced is which GPU the process belongs to.  This is the sample
-- that decides the `partial` sentence, because "part of the data could not be
-- read" is false of it and a user told that goes looking for a permissions
-- problem that does not exist.
local orphan_fdinfo = table.concat({
  "drm-driver: nvidia",
  "drm-client-id: 4",
  "drm-client-name: stranger",
  "drm-pdev: 0000:0b:00.0",
  "drm-engine-render: 50000000 ns",
  "drm-cycles-render: 100",
  "drm-total-cycles-render: 1000",
  "drm-maxfreq-render: 1500 MHz",
}, "\n") .. "\n"
local orphan_fs = fake_fs({
  ["/orphan/card0/device/uevent"] = "DRIVER=i915\nPCI_SLOT_NAME=0000:00:02.0\n",
  ["/orphan/card0/device/vendor"] = "0x8086\n",
  ["/orphan/card0/device/device"] = "0x46a6\n",
  ["/orphan/card0/dev"] = "226:0\n",
  ["/orphan-proc/200/stat"] = stat_for(200, "stranger", 2000),
  ["/orphan-proc/200/status"] = "Name:\tstranger\nUid:\t2000\t2000\t2000\t2000\n",
  ["/orphan-proc/200/fdinfo/3"] = orphan_fdinfo,
}, {
  ["/orphan"] = { "card0" },
  ["/orphan-proc"] = { "200" },
  ["/orphan-proc/200/fdinfo"] = { "3" },
}, {
  ["/orphan/card0/device"] = "../../../0000:00:02.0",
  ["/orphan/card0/device/driver"] = "../../../../bus/pci/drivers/i915",
}, {}, {}, {})
local orphan = GPU.new({
  drm_path = "/orphan", proc_path = "/orphan-proc",
  max_processes = 8, max_fds_per_process = 8,
  max_fdinfo_files = 8, max_clients = 8,
}):sample({ fs = orphan_fs, now_ns = function() return 1 end })
assert(orphan.quality == "partial", "a client that matched no device degrades the sample")
assert(orphan.data.process_scan.unmatched_clients == 1)
assert(orphan.data.process_scan.drm_fdinfo_files == 1)
assert(orphan.data.process_scan.denied == 0 and orphan.data.process_scan.races == 0
  and orphan.data.process_scan.parse_errors == 0,
  "the client's bytes were read and parsed; nothing failed to be read")
assert(orphan.data.process_scan.status == "ok")
assert(orphan.data.drm_scan.unattached_render_nodes == 0)
-- The device's own reads are not what degraded here.  `device.partial` is set
-- because the device *inherits* the process scan's quality, not because an
-- attribute of it failed: `issues` is empty and the identity is complete, so
-- the only thing missing anywhere in this sample is the client-to-GPU link.
assert(next(orphan.data.devices[1].issues) == nil,
  "no attribute of the device itself failed to be read")
assert(orphan.data.devices[1].partial
  and orphan.data.devices[1].processes.quality == "partial",
  "a device inherits the process scan's degradation rather than staying whole")
assert(orphan.data.devices[1].identity_quality == "fresh")
gpu_reason_is(orphan, "a gpu sample whose client could not be attributed to a device")

-- And the `fresh` half of the invariant: a whole tree, read without a guess
-- and without a loss, names no cause.  A reason table listing only the two
-- degraded qualities has no row to disagree with it, so without this the
-- whole `fresh` direction is untested.
local whole_fs = fake_fs({
  ["/whole/card0/device/uevent"] = "DRIVER=i915\nPCI_SLOT_NAME=0000:00:02.0\n",
  ["/whole/card0/device/vendor"] = "0x8086\n",
  ["/whole/card0/device/device"] = "0x46a6\n",
  ["/whole/card0/dev"] = "226:0\n",
  ["/whole/renderD128/device/uevent"] = "DRIVER=i915\nPCI_SLOT_NAME=0000:00:02.0\n",
  ["/whole/renderD128/dev"] = "226:128\n",
}, { ["/whole"] = { "renderD128", "card0" } }, {
  ["/whole/card0/device"] = "../../../0000:00:02.0",
  ["/whole/card0/device/driver"] = "../../../../bus/pci/drivers/i915",
  ["/whole/renderD128/device"] = "../../../0000:00:02.0",
}, {}, {}, {})
local whole = GPU.new({
  drm_path = "/whole", proc_path = "/whole-proc", scan_processes = false,
}):sample({ fs = whole_fs, now_ns = function() return 1 end })
assert(whole.status == "ok" and whole.quality == "fresh")
assert(#whole.data.devices == 1 and not whole.data.devices[1].partial)
assert(whole.data.devices[1].identity_quality == "fresh")
assert(whole.data.drm_scan.estimated_render_links == 0
  and whole.data.drm_scan.unattached_render_nodes == 0)
gpu_reason_is(whole, "a gpu sample with nothing wrong")

-- The other `estimated` branch, so the pairing table's `estimated` row is not
-- decided by one cause: a card that publishes no `vendor`, so its identity is
-- composed from the bus address and driver alone.  A missing file is an
-- optional absence rather than a failed read, so the device carries no issue
-- and the sample is `estimated` on this alone -- with no render node in the
-- tree for the other branch to fire on.
local nameless_fs = fake_fs({
  ["/nameless/card0/device/uevent"] = "DRIVER=example\nPCI_SLOT_NAME=0000:07:00.0\n",
  ["/nameless/card0/device/device"] = "0x2684\n",
  ["/nameless/card0/dev"] = "226:7\n",
}, { ["/nameless"] = { "card0" } }, {
  ["/nameless/card0/device"] = "../../../0000:07:00.0",
  ["/nameless/card0/device/driver"] = "../../../../bus/pci/drivers/example",
}, {}, {}, {})
local nameless = GPU.new({
  drm_path = "/nameless", proc_path = "/nameless-proc", scan_processes = false,
}):sample({ fs = nameless_fs, now_ns = function() return 1 end })
assert(nameless.quality == "estimated")
assert(nameless.data.drm_scan.estimated_render_links == 0
  and nameless.data.drm_scan.unattached_render_nodes == 0,
  "the cause here is the identity, not a node attachment")
local nameless_device = nameless.data.devices[1]
assert(nameless_device.identity_quality == "estimated" and nameless_device.vendor_id == nil)
assert(not nameless_device.partial and next(nameless_device.issues) == nil,
  "an absent optional attribute is not a read that failed")
gpu_reason_is(nameless, "a gpu sample whose device identity was composed")

return true
