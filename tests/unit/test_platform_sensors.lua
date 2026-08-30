package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local CPUFreq = require("wtop.collectors.cpufreq")
local Hwmon = require("wtop.collectors.hwmon")

local function read_fixture(name)
  local file = assert(io.open("tests/fixtures/platform/" .. name, "rb"))
  local content = assert(file:read("*a"))
  file:close()
  local values = {}
  for line in content:gmatch("[^\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    assert(key, "invalid platform fixture line: " .. line)
    values[key] = value
  end
  return values
end

local function fake_fs(files, directories, links)
  files, directories, links = files or {}, directories or {}, links or {}
  local fs = {}
  function fs:read(path, limit)
    local value = files[path]
    if type(value) == "function" then value = value(path, limit) end
    if value == nil then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    value = tostring(value)
    if limit and #value > limit then
      return nil, { kind = "too_large", message = "file_exceeds_limit", path = path, limit = limit }
    end
    return value
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
  return fs
end

local function near(actual, expected, epsilon)
  assert(type(actual) == "number", "expected number, got " .. tostring(actual))
  assert(math.abs(actual - expected) <= (epsilon or 1e-9), tostring(actual) .. " ~= " .. tostring(expected))
end

local function mount_values(values, base, files, directories, links)
  local entries = {}
  for key, value in pairs(values) do
    if key == "@device" then
      links[base .. "/device"] = value
    else
      files[base .. "/" .. key] = value .. "\n"
      entries[#entries + 1] = key
    end
  end
  table.sort(entries)
  directories[base] = entries
end

local now = 1000000000
local cpufreq_base = "/sys/devices/system/cpu/cpufreq"
local cpu_files, cpu_dirs = {}, {
  [cpufreq_base] = { "policy2", "boost", "policy0", "not-a-policy" },
}
mount_values(read_fixture("cpufreq-policy0.txt"), cpufreq_base .. "/policy0", cpu_files, cpu_dirs, {})
mount_values(read_fixture("cpufreq-policy2.txt"), cpufreq_base .. "/policy2", cpu_files, cpu_dirs, {})
cpu_files[cpufreq_base .. "/boost"] = "1\n"
local cpu_context = { fs = fake_fs(cpu_files, cpu_dirs), now_ns = function() return now end }

local cpufreq = CPUFreq.new()
assert(not pcall(CPUFreq.new, "invalid"))
assert(not pcall(CPUFreq.new, { max_policies = math.huge }))
assert(cpufreq:probe(cpu_context).available)
local frequencies = cpufreq:sample(cpu_context)
assert(frequencies.status == "ok" and frequencies.quality == "estimated")
assert(#frequencies.data.policies == 2, "shared CPU policies must not be expanded per CPU")
assert(frequencies.data.boost.enabled == true)

local policy0 = assert(frequencies.data.by_id["cpus:0,1"])
assert(policy0.policy == "policy0")
assert(#policy0.affected_cpus == 2 and policy0.affected_cpus[2] == 1)
assert(policy0.driver == "amd-pstate-epp" and policy0.governor == "schedutil")
assert(policy0.energy_performance_preference == "balance_performance")
assert(policy0.boost.enabled == true)
assert(policy0.frequencies.current_quality == "measured")
assert(policy0.frequencies.current_source == "cpuinfo_cur_freq")
assert(policy0.frequencies.current_hz == 2312345000)
assert(policy0.frequencies.scaling_current_hz == 2200000000)
assert(policy0.frequencies.scaling_minimum_hz == 800000000)
assert(policy0.frequencies.scaling_maximum_hz == 4200000000)
assert(policy0.frequencies.hardware_minimum_hz == 400000000)
assert(policy0.frequencies.hardware_maximum_hz == 4600000000)
assert(policy0.frequencies.bios_limit_hz == 4400000000)

local policy2 = assert(frequencies.data.by_id["cpus:2,3"])
assert(#policy2.affected_cpus == 1 and #policy2.related_cpus == 2)
assert(policy2.frequencies.hardware_current_hz == nil)
assert(policy2.frequencies.current_quality == "estimated")
assert(policy2.frequencies.current_source == "scaling_cur_freq")
assert(policy2.frequencies.current_hz == 1800000000)
assert(policy2.boost == nil)
assert(next(policy2.errors) == nil, "an unsupported optional cpuinfo_cur_freq is not a malformed field")

local parsed = assert(CPUFreq.parse_cpu_list("0-2, 4 6-7", 16, 64))
assert(table.concat(parsed, ",") == "0,1,2,4,6,7")
assert(CPUFreq.parse_cpu_list("0-9999", 8, 10000) == nil)

-- Duplicate aliases with the same related CPU set are dropped instead of
-- presenting one shared policy multiple times.
cpu_dirs[cpufreq_base][#cpu_dirs[cpufreq_base] + 1] = "policy9"
mount_values(read_fixture("cpufreq-policy0.txt"), cpufreq_base .. "/policy9", cpu_files, cpu_dirs, {})
local deduplicated = cpufreq:sample(cpu_context)
assert(#deduplicated.data.policies == 2 and deduplicated.data.duplicates_skipped == 1)
assert(deduplicated.quality == "partial")

local hwmon_base = "/sys/class/hwmon"
local function build_hwmon(entries)
  local files, directories, links = {}, { [hwmon_base] = {} }, {}
  for _, item in ipairs(entries) do
    directories[hwmon_base][#directories[hwmon_base] + 1] = item.class
    mount_values(read_fixture(item.fixture), hwmon_base .. "/" .. item.class, files, directories, links)
  end
  return fake_fs(files, directories, links), files, directories, links
end

local first_fs = build_hwmon({
  { class = "hwmon3", fixture = "hwmon-coretemp.txt" },
  { class = "hwmon7", fixture = "hwmon-mixed.txt" },
  { class = "hwmon12", fixture = "hwmon-fallback.txt" },
})
local hwmon_context = { fs = first_fs, now_ns = function() return now end }
local hwmon = Hwmon.new()
assert(not pcall(Hwmon.new, "invalid"))
assert(not pcall(Hwmon.new, { max_devices = 0 }))
assert(hwmon:probe(hwmon_context).available)
local sensors = hwmon:sample(hwmon_context)
assert(sensors.status == "ok" and sensors.quality == "partial")
assert(#sensors.data.devices == 3)

local coretemp_id = "coretemp@../../../devices/platform/coretemp.0"
local coretemp = assert(sensors.data.by_id[coretemp_id])
assert(coretemp.identity_quality == "fresh")
assert(coretemp.quality == "partial", "one bad channel field makes only the device partial")
local package_temp = assert(coretemp.by_id["temperature:1"])
near(package_temp.input, -5)
near(package_temp.thresholds.max, 85)
near(package_temp.thresholds.crit, 100)
assert(package_temp.alarm == true and package_temp.fault == false)
assert(package_temp.quality == "fresh")
local bad_temp = assert(coretemp.by_id["temperature:2"])
assert(bad_temp.input == nil and bad_temp.quality == "partial")
assert(bad_temp.errors.input.reason == "expected_integer")
near(bad_temp.thresholds.max, 90)
local sentinel_temp = assert(coretemp.by_id["temperature:3"])
assert(sentinel_temp.input == nil and sentinel_temp.thresholds.max == nil)
assert(sentinel_temp.errors.input.reason == "implausible_sensor_value")
assert(sentinel_temp.errors.max.reason == "implausible_sensor_value")
assert(sentinel_temp.errors.lowest.reason == "implausible_sensor_value")
assert(sentinel_temp.errors.highest.reason == "implausible_sensor_value")
assert(sentinel_temp.errors.offset.reason == "implausible_sensor_value")
assert(sentinel_temp.errors.crit.reason == "implausible_sensor_value")
assert(sentinel_temp.readings.lowest == nil and sentinel_temp.readings.highest == nil)
near(sentinel_temp.thresholds.min, -199.999)
near(sentinel_temp.thresholds.emergency, 999.999)
local lower_boundary = assert(coretemp.by_id["temperature:4"])
assert(lower_boundary.input == nil)
assert(lower_boundary.errors.input.reason == "implausible_sensor_value")
near(lower_boundary.thresholds.max, 999.999)
local upper_boundary = assert(coretemp.by_id["temperature:5"])
near(upper_boundary.input, -199.999)
assert(upper_boundary.thresholds.max == nil)
assert(upper_boundary.errors.max.reason == "implausible_sensor_value")

local mixed_id = "nct6775@../../../devices/platform/nct6775.2592"
local mixed = assert(sensors.data.by_id[mixed_id])
near(mixed.by_id["fan:1"].input, 1500)
near(mixed.by_id["fan:1"].thresholds.min, 500)
assert(mixed.by_id["fan:1"].alarm == false)
assert(mixed.by_id["fan:2"].quality == "unavailable", "missing input is retained as capability data")
near(mixed.by_id["power:1"].input, 125)
near(mixed.by_id["power:1"].thresholds.cap, 180)
near(mixed.by_id["voltage:1"].input, 1.2)
near(mixed.by_id["current:1"].input, 4.5)
near(mixed.by_id["energy:1"].input, 9.876543)

local fallback
for _, device in ipairs(sensors.data.devices) do
  if device.name == "acpitz" then fallback = device end
end
assert(fallback and fallback.identity_quality == "estimated")
assert(fallback.id == "acpitz@class:hwmon12")

-- Renumbering class entries does not change identities derived from the
-- device symlink target and driver-provided name.
local renumbered_fs = build_hwmon({
  { class = "hwmon90", fixture = "hwmon-coretemp.txt" },
  { class = "hwmon1", fixture = "hwmon-mixed.txt" },
})
local renumbered = Hwmon.new():sample({ fs = renumbered_fs, now_ns = function() return now end })
assert(renumbered.data.by_id[coretemp_id])
assert(renumbered.data.by_id[mixed_id])

-- Enumeration and text reads are bounded even for an unexpectedly large or
-- hostile sysfs-like source.
local limited = Hwmon.new({ max_devices = 1 }):sample(hwmon_context)
assert(#limited.data.devices == 1 and limited.data.truncated and limited.quality == "partial")
local oversized_fs, oversized_files = build_hwmon({
  { class = "hwmon0", fixture = "hwmon-fallback.txt" },
})
oversized_files[hwmon_base .. "/hwmon0/name"] = string.rep("x", 32)
local oversized = Hwmon.new({ max_text_bytes = 8 }):sample({
  fs = oversized_fs,
  now_ns = function() return now end,
})
assert(oversized.data.devices[1].quality == "partial")
assert(oversized.data.devices[1].errors.name.reason == "file_exceeds_limit")

local invalid_utf8_fs, invalid_utf8_files = build_hwmon({
  { class = "hwmon0", fixture = "hwmon-fallback.txt" },
})
invalid_utf8_files[hwmon_base .. "/hwmon0/name"] = "bad\255name\n"
local repaired = Hwmon.new():sample({ fs = invalid_utf8_fs, now_ns = function() return now end })
assert(repaired.data.devices[1].name == "bad�name")

return true
