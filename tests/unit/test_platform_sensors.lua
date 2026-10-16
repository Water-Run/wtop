package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

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
assert(policy0.frequencies.hardware_average_hz == 2280000000,
  "a hardware feedback average is kept beside the instantaneous reading")
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

-- The hardware feedback average is a measured value on kernels that expose
-- it, even when cpuinfo_cur_freq is absent. EAGAIN on an idle CPU and a zero
-- value are temporary absence, not a zero-hertz measurement or parse failure.
cpu_files[cpufreq_base .. "/policy2/cpuinfo_avg_freq"] = "1750000\n"
local averaged = cpufreq:sample(cpu_context)
local averaged_policy = averaged.data.by_id["cpus:2,3"]
assert(averaged.quality == "fresh" and averaged_policy.frequencies.current_quality == "measured")
assert(averaged_policy.frequencies.current_source == "cpuinfo_avg_freq")
assert(averaged_policy.frequencies.hardware_average_hz == 1750000000
  and averaged_policy.frequencies.current_hz == 1750000000)
local hardware_current_path = cpufreq_base .. "/policy0/cpuinfo_cur_freq"
local hardware_current = cpu_files[hardware_current_path]
cpu_files[hardware_current_path] = "0\n"
local idle_policy = cpufreq:sample(cpu_context).data.by_id["cpus:0,1"]
assert(idle_policy.frequencies.current_source == "cpuinfo_avg_freq"
  and idle_policy.errors.cpuinfo_cur_freq == nil,
  "a zero current value cannot replace valid hardware feedback")
cpu_files[hardware_current_path] = hardware_current
local Snapshot = require("wtop.model.snapshot")
local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")
local state = Snapshot.merge(nil, { cpufreq = averaged }, 1, 1)
local Export = require("wtop.export")
local TUI = require("wtop.tui")
local exported = Export.snapshot(state)
assert(exported.cpu_frequency.policies[2].frequencies.hardware_average_hz == 1750000000)
local agent_frequency = Export.agent(state).metrics.cpu.frequency
near(agent_frequency.average_hz, (2312345000 * 2 + 1750000000) / 3, 1)
assert(agent_frequency.source == "mixed" and agent_frequency.quality == "measured")
local source_name = state.cpu_frequency.policies[2].frequencies.current_source
state.cpu_frequency.policies[2].frequencies.current_source = nil
local unknown_source = Export.agent(state).metrics.cpu.frequency
assert(unknown_source.quality == "partial" and unknown_source.source == "mixed",
  "a measured number without provenance cannot become a fully measured summary")
state.cpu_frequency.policies[2].frequencies.current_source = source_name
local stale = Snapshot.merge(state, { cpufreq = {
  status = "error", quality = "error", reason = "read_failed",
} }, 2, 2)
assert(Export.agent(stale).metrics.cpu.frequency.average_hz == nil,
  "a retained frequency after a failed read is not a current agent metric")
local detail = table.concat(TUI.hardware_detail_lines(state, "cpufreq:cpus:2,3",
  assert(I18n.new({ locale = "en-US" }))), "\n")
assert(detail:find("cpuinfo_avg_freq", 1, true)
  and detail:find("Scaling readout", 1, true),
  "policy details distinguish hardware feedback from scaling readout")
local view = ViewModel.build({ history_values = function() return {} end }, state,
  assert(I18n.new({ locale = "en-US" })), {}, "compute")
assert(view.cpufreq_table.rows[2].source == "HW average"
  and view.cpufreq_table.rows[2].quality == "fresh")
local has_source, has_quality = false, false
for _, column in ipairs(view.cpufreq_table.columns) do
  has_source = has_source or column.key == "source"
  has_quality = has_quality or column.key == "quality"
end
assert(has_source and has_quality, "the Compute table states provenance and quality")

local retry_fs = fake_fs(cpu_files, cpu_dirs)
local regular_read = retry_fs.read
function retry_fs:read(path, limit)
  if path == cpufreq_base .. "/policy2/cpuinfo_avg_freq"
      or path == hardware_current_path then
    return nil, { kind = "io_error", errno = 11, message = "try again", path = path }
  end
  return regular_read(self, path, limit)
end
local retried = cpufreq:sample({ fs = retry_fs, now_ns = function() return now end })
local retried_policy = retried.data.by_id["cpus:2,3"]
local retried_hardware = retried.data.by_id["cpus:0,1"]
assert(retried_hardware.frequencies.current_source == "cpuinfo_avg_freq"
  and retried_hardware.errors.cpuinfo_cur_freq == nil)
assert(retried_policy.frequencies.current_source == "scaling_cur_freq"
  and retried_policy.frequencies.current_quality == "estimated")
assert(retried_policy.errors.cpuinfo_avg_freq == nil and retried.quality == "estimated")
cpu_files[cpufreq_base .. "/policy2/cpuinfo_avg_freq"] = "0\n"
local zero_avg = cpufreq:sample(cpu_context).data.by_id["cpus:2,3"]
assert(zero_avg.frequencies.hardware_average_hz == nil
  and zero_avg.frequencies.current_source == "scaling_cur_freq"
  and zero_avg.errors.cpuinfo_avg_freq == nil)
cpu_files[cpufreq_base .. "/policy2/cpuinfo_avg_freq"] = nil

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

-- The hwmon collector publishes a reason for its degraded readings, and both of
-- its reasons are categories: `partial` is set when the class directory
-- produced errors or any channel came back partial or unavailable, and
-- `estimated` when the device identity could not be read or a channel
-- published no `input` file and the average of its readings stood in for it.
-- "Part of the sensor data could not be read" and "some sensor values were
-- derived rather than read directly" are the two sentences that hold for all
-- the causes, and the channel's own `errors` and `input_source` say which.
local HWMON_REASON = { partial = "hwmon_data_partial",
  estimated = "hwmon_value_derived", fresh = false }
local hwmon_reason_is = function(result, label)
  return require("support.collector_reason").assert_reason(result, HWMON_REASON, label)
end
hwmon_reason_is(sensors, "the hwmon sample with one bad channel")

-- A device that is whole: it has a name, a device target, and a channel with a
-- readable input.  The fresh case is half the invariant, and a table that lists
-- only the two degraded qualities would not notice a reason published here.
local healthy_fs, healthy_files, healthy_directories, healthy_links =
  build_hwmon({ { class = "hwmon0", fixture = "hwmon-healthy.txt" } })
local class_path = "../../devices/pci0000:00/0000:01:00.0/nvme/nvme0/hwmon0"
healthy_links[hwmon_base .. "/hwmon0"] = class_path
local healthy = Hwmon.new():sample({ fs = healthy_fs, now_ns = function() return now end })
assert(healthy.status == "ok", "a whole hwmon device is sampled")
assert(healthy.quality == "fresh", "a whole hwmon device is fresh, not estimated")
assert(#healthy.data.devices == 1)
local healthy_device = healthy.data.devices[1]
assert(healthy_device.device_path == class_path,
  "class symlink preserves ancestry when the device link is relative")
assert(require("wtop.export").snapshot({ sensors = healthy.data }).sensors.devices[1].device_path
  == class_path, "the exported sensor preserves its ancestry")
assert(healthy_device.quality == "fresh"
  and healthy_device.identity_quality == "fresh",
  "a name and a device target are the whole identity")
assert(next(healthy_device.errors) == nil)
assert(#healthy_device.channels == 1)
local healthy_channel = healthy_device.channels[1]
assert(healthy_channel.id == "temperature:1" and healthy_channel.quality == "fresh")
assert(healthy_channel.input_source == nil,
  "a value read from `input` is not a value derived from somewhere else")
assert(healthy_channel.readings.average == nil)
assert(healthy_channel.session and healthy_channel.session.samples == 1)
near(healthy_channel.session.minimum, 42)
near(healthy_channel.session.average, 42)
near(healthy_channel.session.maximum, 42)
local history_now = now + 1000000000
local history_context = { fs = healthy_fs, now_ns = function() return history_now end }
healthy_files[hwmon_base .. "/hwmon0/temp1_input"] = "45000"
local warmer = Hwmon.new():sample(history_context, healthy)
local warm_session = warmer.data.devices[1].channels[1].session
assert(warm_session.samples == 2)
near(warm_session.minimum, 42)
near(warm_session.average, 43.5)
near(warm_session.maximum, 45)
assert(warm_session.first_timestamp_ns == now and warm_session.last_timestamp_ns == history_now)

-- A failed direct read preserves the previous extrema but is not another
-- sample. Recovery resumes only when the stable channel is directly measured.
healthy_files[hwmon_base .. "/hwmon0/temp1_input"] = "bad"
history_now = history_now + 1000000000
local unreadable = Hwmon.new():sample(history_context, warmer)
local held_session = unreadable.data.devices[1].channels[1].session
assert(unreadable.data.devices[1].channels[1].input == nil)
assert(held_session.samples == 2 and held_session.last_timestamp_ns == now + 1000000000)
healthy_files[hwmon_base .. "/hwmon0/temp1_input"] = "39000"
history_now = history_now + 1000000000
local recovered = Hwmon.new():sample(history_context, unreadable)
local recovered_channel = recovered.data.devices[1].channels[1]
local recovered_session = recovered_channel.session
assert(recovered_session.samples == 3)
near(recovered_session.minimum, 39)
near(recovered_session.average, 42)
near(recovered_session.maximum, 45)
local exported_session = require("wtop.export").snapshot({ sensors = recovered.data })
  .sensors.devices[1].channels[1].session
assert(exported_session.samples == 3 and exported_session.last_timestamp_ns == history_now,
  "Snapshot JSON carries direct sample history and its time boundary")
local translator = assert(require("wtop.i18n").new({ locale = "en-US" }))
local detail = table.concat(require("wtop.tui").sensor_detail_lines(
  { sensors = recovered.data }, translator, history_now), "\n")
assert(detail:find("Session min / avg / max", 1, true)
    and detail:find("Direct samples: 3", 1, true),
  "sensor detail names session statistics separately from driver limits")

healthy_files[hwmon_base .. "/hwmon0/temp1_max"] = "bad"
healthy_directories[hwmon_base .. "/hwmon0"][#healthy_directories[hwmon_base .. "/hwmon0"] + 1] =
  "temp1_max"
history_now = history_now + 1000000000
local partial_threshold = Hwmon.new():sample(history_context, recovered)
assert(partial_threshold.data.devices[1].channels[1].quality == "partial")
assert(partial_threshold.data.devices[1].channels[1].session.samples == 4,
  "a failed threshold read does not discard a fresh direct input")

healthy_files[hwmon_base .. "/hwmon0/temp1_label"] = "Different"
history_now = history_now + 1000000000
local relabeled = Hwmon.new():sample(history_context, partial_threshold)
assert(relabeled.data.devices[1].channels[1].session.samples == 1,
  "a changed channel label starts a new session history")
healthy_files[hwmon_base .. "/hwmon0/temp1_input"] = "41000"
local same_clock = Hwmon.new():sample(history_context, relabeled)
assert(same_clock.data.devices[1].channels[1].session.samples == 1,
  "a held monotonic clock cannot count another direct sample")
healthy_files[hwmon_base .. "/hwmon0/name"] = "replacement"
history_now = history_now + 1000000000
local replaced_sensor = Hwmon.new():sample(history_context, same_clock)
assert(replaced_sensor.data.devices[1].channels[1].session.samples == 1,
  "a changed device identity cannot inherit old extrema")
local saved_class_entries = healthy_directories[hwmon_base]
healthy_directories[hwmon_base] = nil
history_now = history_now + 1000000000
local whole_failure = Hwmon.new():sample(history_context, replaced_sensor)
assert(whole_failure.status ~= "ok")
healthy_directories[hwmon_base] = saved_class_entries
history_now = history_now + 1000000000
local after_failure = Hwmon.new():sample(history_context, whole_failure)
assert(after_failure.data.devices[1].channels[1].session.samples == 1,
  "an entire collector failure starts a new verified statistics interval")
hwmon_reason_is(healthy, "a hwmon sample with nothing wrong")

-- And the fourth case, the one whose absence let a mutation through: a channel
-- that published no `input` file, so the average of its readings was
-- substituted.  The reading *was* taken, from a neighbouring field, which is
-- why its reason is the derived one and not the unreadable one -- a user told
-- "part of the sensor data could not be read" goes looking for a permissions
-- problem that does not exist.  The mutation that swapped the two codes for
-- this quality passed every assertion above, because all three were `partial`.
local average_fs = build_hwmon({ { class = "hwmon0", fixture = "hwmon-averaged.txt" } })
local averaged = Hwmon.new():sample({ fs = average_fs, now_ns = function() return now end })
assert(averaged.status == "ok" and averaged.quality == "estimated",
  "a channel with only an average reading is estimated, not partial")
assert(#averaged.data.devices == 1)
local average_device = averaged.data.devices[1]
assert(average_device.quality == "estimated")
-- The whole reason this case exists.  Nothing failed to be read: there is no
-- error record on the device or the channel, so "part of the sensor data could
-- not be read" is a false sentence about this sample, and a user who believed
-- it would go looking for a permissions problem that does not exist.  What
-- happened instead is that the driver published `power1_average` and no
-- `power1_input`, and the collector stood the former in for the latter.
assert(next(average_device.errors) == nil,
  "the average reading is a substitution, not a failed read")
assert(#average_device.channels == 1)
local average_channel = average_device.channels[1]
assert(average_channel.id == "power:1" and average_channel.quality == "estimated")
assert(next(average_channel.errors) == nil, "no attribute of this channel failed to be read")
assert(average_channel.readings.input == nil,
  "`input` was never published, which is the whole cause of the estimate")
near(average_channel.readings.average, 125)
assert(average_channel.input == average_channel.readings.average)
assert(average_channel.input_source == "average",
  "the channel itself must say which of its readings stood in for the input")
assert(average_channel.session == nil,
  "a driver average substituted for input is not a direct session sample")
hwmon_reason_is(averaged, "a hwmon sample whose input came from an average")
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
-- The two u16 range endpoints are how that encoding says "nothing stated", so
-- they are absent without an error, exactly like a threshold of exactly zero.
-- A merely implausible number on the same channel is still an error.
assert(sentinel_temp.errors.input == nil, "a protocol sentinel is not a failed read")
assert(sentinel_temp.errors.max == nil, "a protocol sentinel is not a failed read")
assert(sentinel_temp.errors.offset == nil, "a protocol sentinel is not a failed read")
assert(sentinel_temp.errors.lowest.reason == "implausible_sensor_value")
assert(sentinel_temp.errors.highest.reason == "implausible_sensor_value")
assert(sentinel_temp.errors.crit.reason == "implausible_sensor_value")
assert(sentinel_temp.readings.lowest == nil and sentinel_temp.readings.highest == nil)
near(sentinel_temp.thresholds.min, -199.999)
near(sentinel_temp.thresholds.emergency, 999.999)
-- The `nvme` shape: a sensor the driver rates but states no limits for.  Every
-- attribute it publishes is a sentinel, so the channel reports no figure and
-- no error rather than degrading the device on a healthy host.
local silent_temp = assert(coretemp.by_id["temperature:6"])
assert(silent_temp.input == nil and silent_temp.readings.input == nil)
assert(silent_temp.thresholds.min == nil and silent_temp.thresholds.max == nil)
assert(next(silent_temp.errors) == nil, "a wholly sentinel channel records no error")
assert(silent_temp.quality == "unavailable", "a channel that published nothing is unavailable")
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
assert(mixed.by_id["energy:1"].session == nil,
  "cumulative energy is not given a level average")

local fallback
for _, device in ipairs(sensors.data.devices) do
  if device.name == "acpitz" then fallback = device end
end
assert(fallback and fallback.identity_quality == "estimated")
assert(fallback.id == "acpitz@class:hwmon12")
local weak_fs, weak_files =
  build_hwmon({ { class = "hwmon0", fixture = "hwmon-fallback.txt" } })
local weak_now = now
local weak_context = { fs = weak_fs, now_ns = function() return weak_now end }
local weak_first = Hwmon.new():sample(weak_context)
weak_files[hwmon_base .. "/hwmon0/temp1_input"] = "43000"
weak_now = weak_now + 1000000000
local weak_second = Hwmon.new():sample(weak_context, weak_first)
assert(weak_second.data.devices[1].channels[1].session.samples == 1,
  "class-only identity is too weak to carry statistics across samples")

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
hwmon_reason_is(limited, "the hwmon sample cut off at its device cap")
hwmon_reason_is(oversized, "the hwmon sample whose name overflowed the text cap")
assert(oversized.data.devices[1].quality == "partial")
assert(oversized.data.devices[1].errors.name.reason == "file_exceeds_limit")

local invalid_utf8_fs, invalid_utf8_files = build_hwmon({
  { class = "hwmon0", fixture = "hwmon-fallback.txt" },
})
invalid_utf8_files[hwmon_base .. "/hwmon0/name"] = "bad\255name\n"
local repaired = Hwmon.new():sample({ fs = invalid_utf8_fs, now_ns = function() return now end })
assert(repaired.data.devices[1].name == "bad�name")

-- Critical headroom belongs to the same channel, and is a temperature
-- difference rather than a percentage or a claim that throttling is active.
do
  local Thermal = require("wtop.model.thermal")
  local channel = { id = "temperature:1", type = "temperature", unit = "celsius",
    label = "Package", input = 65, quality = "fresh",
    thresholds = { max = 85, crit = 100, emergency = 110 } }
  local device = { id = "thermal-test", name = "coretemp", quality = "fresh",
    channels = { channel } }
  local sample = Snapshot.merge(nil, { hwmon = { status = "ok", quality = "fresh",
    data = { devices = { device } } } }, 1, 1000000000)
  local function margin() return Thermal.channel(sample, device, channel) end
  near(margin().critical_celsius, 100)
  near(margin().headroom_celsius, 35)
  local exported = Export.snapshot(sample)
  near(exported.sensors.devices[1].channels[1].headroom_celsius, 35)
  near(Export.agent(sample).top.sensors[1].headroom_celsius, 35)
  device.channels[2] = { id = "temperature:2", type = "temperature", unit = "celsius",
    label = "Lower threshold", input = 50, quality = "fresh", thresholds = { crit = 55 } }
  local closest = Thermal.closest(sample, 1)
  assert(#closest == 1 and closest[1].channel == device.channels[2])
  near(closest[1].headroom_celsius, 5)
  local bounded_agent = Export.agent(sample, { device_limit = 1 })
  assert(#bounded_agent.top.sensors == 1 and bounded_agent.top.sensors[1].label == "Package")
  near(bounded_agent.metrics.sensors.minimum_headroom_celsius, 5)
  assert(bounded_agent.metrics.sensors.closest_to_critical.channel_id == "temperature:2",
    "a cooler probe near its lower critical threshold survives the hottest-list cap")
  device.channels[2] = nil
  local view = ViewModel.build({ history_values = function() return {} end }, sample,
    translator, {}, "compute", nil, { sensor_table = true })
  assert(view.sensor_table.rows[1].critical == "100 °C"
    and view.sensor_table.rows[1].headroom == "35 °C")
  local detail = table.concat(TUI.sensor_detail_lines(sample, translator, sample.timestamp_ns), "\n")
  assert(detail:find("Critical: 100 °C · To critical: 35 °C", 1, true))
  local fahrenheit = assert(I18n.new({ locale = "en-US", format = { unit = "F" } }))
  local fahrenheit_view = ViewModel.build({ history_values = function() return {} end }, sample,
    fahrenheit, {}, "compute", nil, { sensor_table = true })
  assert(fahrenheit_view.sensor_table.rows[1].critical == "212 °F"
    and fahrenheit_view.sensor_table.rows[1].headroom == "63 °F")
  local fahrenheit_detail = table.concat(TUI.sensor_detail_lines(sample, fahrenheit,
    sample.timestamp_ns), "\n")
  assert(fahrenheit_detail:find("Critical: 212 °F · To critical: 63 °F", 1, true))
  local report = require("wtop.report").render(exported)
  assert(report:find("| Critical | To critical |", 1, true)
    and report:find("100.00 °C | 35.00 °C", 1, true))

  channel.input = 102.5
  near(margin().headroom_celsius, -2.5)
  local function has_temperature_signal(state)
    for _, signal in ipairs(Export.agent(state).signals) do
      if signal.code == "temperature_threshold" then return true end
    end
    return false
  end
  assert(has_temperature_signal(sample))
  assert(channel.alarm == nil and next(sample.cpu_limits) == nil,
    "crossing a configured critical threshold must not invent a throttle bit or hardware alarm")
  channel.input = 100
  near(margin().headroom_celsius, 0)
  channel.input = -5
  near(margin().headroom_celsius, 105)
  channel.input = 65

  channel.thresholds.crit = nil
  assert(margin() == nil, "maximum/emergency are not substitutes for the critical threshold")
  channel.thresholds.crit = 100
  channel.errors = { crit = { reason = "query_denied" } }
  assert(margin() == nil)
  channel.errors = { max = { reason = "query_denied" } }
  channel.quality, device.quality = "partial", "partial"
  near(margin().headroom_celsius, 35, 1e-9)
  channel.errors = { input = { reason = "query_denied" } }
  assert(margin().headroom_celsius == nil)
  channel.errors = nil
  for _, quality in ipairs({ "stale", "gap", "reset", "held", "missing",
      "denied", "error", "unavailable" }) do
    channel.quality, device.quality = quality, "fresh"
    assert(margin().headroom_celsius == nil, "unusable input: " .. quality)
    channel.quality, device.quality = "fresh", quality
    assert(margin().headroom_celsius == nil, "unusable device: " .. quality)
    device.quality = "fresh"
    sample.quality.sensors.quality = quality
    assert(margin().headroom_celsius == nil, "unusable source: " .. quality)
    sample.quality.sensors.quality = "fresh"
  end
  channel.quality, device.quality = "fresh", "fresh"
  channel.fault = true
  assert(margin().headroom_celsius == nil)
  channel.input = 102.5
  assert(not has_temperature_signal(sample), "a faulted probe cannot raise a current thermal alert")
  channel.input = 65
  channel.fault = false
  for _, value in ipairs({ math.huge, -math.huge, 0/0 }) do
    channel.input = value
    assert(margin().headroom_celsius == nil)
    channel.input, channel.thresholds.crit = 65, value
    assert(margin() == nil)
    channel.thresholds.crit = 100
  end
  channel.unit = "millivolts"
  assert(margin() == nil, "a voltage from a thermistor is not a Celsius margin")
  channel.unit = "celsius"

  sample.timestamp_ns = 16000000000
  near(margin().headroom_celsius, 35)
  sample.timestamp_ns = 16000000001
  assert(margin().headroom_celsius == nil, "a retained observation ages out")
  assert(#Thermal.closest(sample, 3) == 0)
  assert(Export.agent(sample).metrics.sensors.minimum_headroom_celsius == nil)
  assert(Export.agent(sample).top.sensors[1].headroom_celsius == nil)
  channel.input = 102.5
  assert(not has_temperature_signal(sample), "an aged source cannot raise a new thermal alert")
  channel.input = 65
  view = ViewModel.build({ history_values = function() return {} end }, sample,
    translator, {}, "compute", nil, { sensor_table = true })
  assert(view.sensor_table.rows[1].status == "stale"
    and view.sensor_table.rows[1].headroom == "—")
  detail = table.concat(TUI.sensor_detail_lines(sample, translator, sample.timestamp_ns), "\n")
  assert(detail:find("To critical: —", 1, true)
    and not detail:find("To critical: 35", 1, true))
  sample.timestamp_ns = 999999999
  assert(margin().headroom_celsius == nil, "clock rollback cannot renew a comparison")
  sample.timestamp_ns = 1000000000
  local failed = Snapshot.merge(sample, { hwmon = { status = "error", quality = "error" } },
    2, 2000000000)
  assert(Export.snapshot(failed).sensors.devices[1].channels[1].headroom_celsius == nil)
  assert(Thermal.channel(sample, device, channel, 999999999).headroom_celsius == nil)
end

return true
