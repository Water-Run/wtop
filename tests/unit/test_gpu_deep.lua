package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local GPU = require("wtop.collectors.gpu")

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
  ["/drm/card0/device/uevent"] = "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n",
  ["/drm/card0/device/vendor"] = "0x1002\n",
  ["/drm/card0/device/device"] = "0x73bf\n",
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
assert(amd.metrics.memory_total_bytes == 17179869184 and amd.metrics.memory_used_bytes == 4294967296)
assert(amd.metrics.visible_memory_total_bytes == 8589934592 and amd.metrics.gtt_used_bytes == 1073741824)
assert(amd.metrics.frequency_graphics_hz == 1800000000)
assert(amd.metrics.frequency_memory_hz == 1000000000)
assert(intel.metrics.frequency_current_hz == 450000000)
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

return true
