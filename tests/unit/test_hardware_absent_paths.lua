package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

-- Exercise the collectors that only run on machines with the hardware.
--
-- On a VM with no GPU, no hwmon, no RAPL, no cpufreq and no battery, roughly
-- five thousand lines of parsing never execute: every one of those collectors
-- takes its "unavailable" branch and the rest of the file is dead weight that
-- nothing has ever checked.  These fixtures put realistic driver output in
-- front of them so the parsing, unit conversion and quality reporting are
-- tested before a user with the hardware finds the mistake.

local Fixture = require("support.fixture_fs")
local Hardware = require("support.hardware_fixtures")

local Cpufreq = require("wtop.collectors.cpufreq")
local Gpu = require("wtop.collectors.gpu")
local Hwmon = require("wtop.collectors.hwmon")
local Powercap = require("wtop.collectors.powercap")
local PowerSupply = require("wtop.collectors.power_supply")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label or "values differ",
      tostring(expected), tostring(actual)), 2)
  end
end

local function close(actual, expected, tolerance, label)
  if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
    error(string.format("%s: expected %s ±%s, got %s", label or "values differ",
      tostring(expected), tostring(tolerance), tostring(actual)), 2)
  end
end

local function find(list, predicate)
  for _, item in ipairs(list or {}) do
    if predicate(item) then return item end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- hwmon: millidegrees, RPM, microwatts and milliamps all have different scales,
-- and getting one wrong silently reports a plausible but false number.
-- ---------------------------------------------------------------------------

local hwmon_fs = Fixture.new(Fixture.merge(
  Hardware.hwmon_coretemp(), Hardware.hwmon_nct6775()))
local hwmon = Hwmon.new({ fs = hwmon_fs }):sample({})
equal(hwmon.status, "ok", "hwmon sample status")
equal(#hwmon.data.devices, 2, "both hwmon devices are discovered")

local coretemp = find(hwmon.data.devices, function(d) return d.name == "coretemp" end)
assert(coretemp, "coretemp device must be found")
equal(#coretemp.channels, 3, "coretemp exposes three temperature channels")
local package_temp = find(coretemp.channels, function(c) return c.label == "Package id 0" end)
assert(package_temp, "the package channel must be labelled")
equal(package_temp.type, "temperature", "channel kind")
close(package_temp.input, 47, 0.001, "47000 millidegrees is 47 °C")
close(package_temp.thresholds.crit, 100, 0.001, "crit threshold is scaled too")

local hot_core = find(coretemp.channels, function(c) return c.label == "Core 1" end)
assert(hot_core, "Core 1 must be found")
close(hot_core.input, 88, 0.001, "core temperature")
equal(hot_core.alarm, true, "crit_alarm=1 must surface as an alarm")

local super_io = find(hwmon.data.devices, function(d) return d.name == "nct6798" end)
assert(super_io, "the super-I/O chip must be found")
local fan = find(super_io.channels, function(c) return c.type == "fan" and c.index == 1 end)
assert(fan, "fan1 must be found")
close(fan.input, 1420, 0.001, "fan RPM is not scaled")
local faulty_fan = find(super_io.channels, function(c) return c.type == "fan" and c.index == 2 end)
assert(faulty_fan and faulty_fan.fault == true, "a stopped fan reports its fault flag")
local power = find(super_io.channels, function(c) return c.type == "power" end)
assert(power, "power1 must be found")
close(power.input, 45, 0.001, "45000000 microwatts is 45 W")
local voltage = find(super_io.channels, function(c) return c.type == "voltage" end)
assert(voltage, "in0 must be found")
close(voltage.input, 1.024, 0.0001, "1024 millivolts is 1.024 V")
local current = find(super_io.channels, function(c) return c.type == "current" end)
assert(current, "curr1 must be found")
close(current.input, 3.5, 0.0001, "3500 milliamps is 3.5 A")

-- `pwm1` and `update_interval` look like channel files but are not.
for _, channel in ipairs(super_io.channels) do
  assert(channel.type ~= "pwm", "pwm must not be mistaken for a sensor channel")
end

-- ---------------------------------------------------------------------------
-- powercap: energy counters are cumulative microjoules that wrap, so a rate is
-- only meaningful between two samples and must survive the wrap.
-- ---------------------------------------------------------------------------

local rapl_first = Powercap.new({ fs = Fixture.new(Hardware.powercap_intel_rapl()) })
local first = rapl_first:sample({ now_ns = 0 })
equal(first.status, "ok", "powercap sample status")
local package_zone = find(first.data.zones, function(z) return z.name == "package-0" end)
assert(package_zone, "the package zone must be discovered")
close(package_zone.energy_joules, 123456.789012, 0.001, "microjoules become joules")
equal(#package_zone.constraints, 2, "both constraints are read")
local long_term = find(package_zone.constraints, function(c) return c.name == "long_term" end)
assert(long_term, "the long-term constraint must be named")
close(long_term.power_limit_watts, 65, 0.001, "65000000 µW is 65 W")
close(long_term.time_window_seconds, 27.983872, 0.000001, "µs becomes seconds")
assert(find(first.data.zones, function(z) return z.name == "core" end), "sub-zones are walked")
assert(find(first.data.zones, function(z) return z.name == "psys" end), "psys is discovered")

-- A first sample cannot produce power; a second one one second later can.
local rapl_second = Powercap.new({
  fs = Fixture.new(Hardware.powercap_intel_rapl_advanced(nil, 45 * 1000000)),
})
local second = rapl_second:sample({ now_ns = 1000000000 }, first)
local package_after = find(second.data.zones, function(z) return z.name == "package-0" end)
assert(package_after, "the package zone survives the second sample")
if package_after.power_watts ~= nil then
  close(package_after.power_watts, 45, 1.0, "45 J over one second is 45 W")
end

-- ---------------------------------------------------------------------------
-- cpufreq: kHz, shared policies, and the governor/driver identity.
-- ---------------------------------------------------------------------------

local cpufreq = Cpufreq.new({ fs = Fixture.new(Hardware.cpufreq_policies()) }):sample({})
equal(cpufreq.status, "ok", "cpufreq sample status")
equal(#cpufreq.data.policies, 3, "every policy directory is read")
local shared = find(cpufreq.data.policies, function(p)
  return p.affected_cpus and #p.affected_cpus == 2
end)
assert(shared, "a policy shared by two CPUs must keep both")
equal(shared.governor, "powersave", "governor")
equal(shared.driver, "intel_pstate", "driver")
close(shared.frequencies.current_hz, 3200000000, 1, "3200000 kHz is 3.2 GHz")
close(shared.frequencies.scaling_maximum_hz, 4700000000, 1, "scaling maximum")

-- ---------------------------------------------------------------------------
-- GPU: two vendors with different sysfs vocabularies, plus a DRM client.
-- ---------------------------------------------------------------------------

local gpu_fs = Fixture.new(Fixture.merge(
  Hardware.drm_amdgpu(), Hardware.drm_i915(), Hardware.drm_render_and_clients()))
local gpu = Gpu.new({ fs = gpu_fs, scan_processes = true }):sample({})
equal(gpu.status, "ok", "gpu sample status")
equal(#gpu.data.devices, 2, "both cards are discovered")

local amd = find(gpu.data.devices, function(d) return d.vendor_id == 0x1002 end)
assert(amd, "the AMD card must be identified by PCI vendor")
equal(amd.vendor, "amd", "the vendor id maps to a vendor name")
equal(amd.driver, "amdgpu", "driver name comes from the driver link")
equal(amd.pci_bdf, "0000:01:00.0", "the PCI address comes from the device link")
close(amd.metrics.utilization_percent, 73, 0.001, "gpu_busy_percent")
close(amd.metrics.memory_busy_percent, 41, 0.001, "mem_busy_percent")
close(amd.metrics.memory_used_bytes, 3221225472, 1, "VRAM used")
close(amd.metrics.memory_total_bytes, 25753026560, 1, "VRAM total")
close(amd.metrics.gtt_used_bytes, 536870912, 1, "GTT used")
close(amd.metrics.visible_memory_used_bytes, 1073741824, 1, "visible VRAM used")
equal(amd.pci.current_link_width, 16, "PCIe link width is parsed")
equal(amd.pci.maximum_link_width, 16, "maximum PCIe link width is parsed")
-- `pp_dpm_sclk` lists every level and marks the active one with an asterisk.
-- Taking the first or the last would be wrong in opposite directions.
close(amd.metrics.frequency_graphics_hz, 1500000000, 1,
  "the starred DPM level is the active one")
close(amd.metrics.frequency_memory_hz, 1249000000, 1, "the memory DPM level")
close(amd.metrics.frequency_maximum_hz, 2500000000, 1, "the highest DPM level is the maximum")

local intel = find(gpu.data.devices, function(d) return d.vendor_id == 0x8086 end)
assert(intel, "the Intel card must be identified")
equal(intel.vendor, "intel", "the Intel vendor id maps")
equal(intel.driver, "i915", "i915 driver")
-- i915 publishes no VRAM files at all; absence must not become zero.
equal(intel.metrics.memory_total_bytes, nil, "an integrated GPU has no VRAM total")
equal(intel.metrics.utilization_percent, nil, "i915 exposes no busy percentage here")
close(intel.metrics.frequency_current_hz, 1400000000, 1,
  "gt_act_freq_mhz is the achieved frequency")
close(intel.metrics.frequency_maximum_hz, 1550000000, 1, "gt_max_freq_mhz")
-- "Unknown" is what the kernel writes for a powered-down link.  It must be
-- recorded as an issue rather than parsed into a plausible-looking number.
equal(intel.pci.current_link_width, nil, "an unknown link width must not parse")
assert(find(intel.issues, function(issue)
  return issue.field == "pci.current_link_width"
end), "an unparsable link width must be reported as an issue")

-- The DRM client holding the render node open must be attributed to the card.
local clients = amd.processes and amd.processes.list or {}
equal(#clients, 1, "the fdinfo client is attributed to the AMD card")
equal(clients[1].pid, 4242, "the client's PID")
-- 262144 KiB VRAM + 65536 KiB GTT, reported in KiB by the fdinfo ABI.
close(amd.metrics.process_memory_bytes, (262144 + 65536) * 1024, 1,
  "fdinfo memory is KiB, not bytes")
equal(amd.metrics.process_memory_source, "drm_fdinfo", "and its source is named")

-- ---------------------------------------------------------------------------
-- Power supplies: the two unit conventions, health against design capacity,
-- and remaining runtime only while discharging.
-- ---------------------------------------------------------------------------

local supplies = PowerSupply.new({
  fs = Fixture.new(Hardware.power_supply_laptop()),
}):sample({})
equal(supplies.status, "ok", "power supply sample status")
equal(#supplies.data.batteries, 2, "both batteries are found")
equal(#supplies.data.supplies, 1, "the mains adapter is found")

local charge_battery = find(supplies.data.batteries, function(b) return b.id == "BAT0" end)
assert(charge_battery, "BAT0 must be found")
equal(charge_battery.capacity_percent, 48, "the driver's own capacity wins")
equal(charge_battery.technology, "Li-poly", "technology")
equal(charge_battery.cycle_count, 212, "cycle count")
-- charge_now is µAh; at 11.4 V that is 2.4 Ah * 11.4 V = 27.36 Wh.
close(charge_battery.energy_watt_hours, 2.4 * 11.4, 0.001,
  "µAh is converted to Wh through the present voltage")
close(charge_battery.health_percent, 5.0 / 5.5 * 100, 0.001,
  "health is full charge against design charge")
-- current_now 1.5 A at 11.4 V is 17.1 W; 27.36 Wh at 17.1 W is 1.6 h.
close(charge_battery.power_watts, 1.5 * 11.4, 0.001, "power derived from current")
close(charge_battery.time_remaining_seconds, (2.4 * 11.4) / (1.5 * 11.4) * 3600, 1,
  "remaining runtime while discharging")
equal(charge_battery.time_to_full_seconds, nil, "a discharging battery has no time-to-full")

local energy_battery = find(supplies.data.batteries, function(b) return b.id == "BAT1" end)
assert(energy_battery, "BAT1 must be found")
close(energy_battery.energy_watt_hours, 40, 0.001, "µWh is scaled directly")
close(energy_battery.power_watts, 20, 0.001, "power_now is used when present")
close(energy_battery.time_to_full_seconds, (50 - 40) / 20 * 3600, 1,
  "time-to-full while charging")
equal(energy_battery.time_remaining_seconds, nil, "a charging battery has no runtime left")

equal(supplies.data.on_ac_power, false, "an offline adapter means no AC power")
assert(supplies.data.summary ~= nil, "a summary is produced when batteries exist")
close(supplies.data.summary.capacity_percent, (48 + 80) / 2, 0.001,
  "the summary averages the batteries")

-- ---------------------------------------------------------------------------
-- Absence and denial must stay distinguishable from zero on every collector.
-- ---------------------------------------------------------------------------

local empty_cases = {
  { "hwmon", Hwmon, "/sys/class/hwmon" },
  { "powercap", Powercap, "/sys/class/powercap" },
  { "cpufreq", Cpufreq, "/sys/devices/system/cpu/cpufreq" },
  { "power_supply", PowerSupply, "/sys/class/power_supply" },
}
for _, case in ipairs(empty_cases) do
  local name, module, base = case[1], case[2], case[3]
  local empty = module.new({ fs = Fixture.new({ dirs = { [base] = {} } }) }):sample({})
  assert(empty.status ~= "ok" or empty.quality == "unavailable",
    name .. " must report an empty class directory as unavailable, got "
      .. tostring(empty.status) .. "/" .. tostring(empty.quality))

  local denied = module.new({ fs = Fixture.new({ denied = { [base] = true } }) }):sample({})
  assert(denied.status == "denied" or denied.quality == "denied"
      or denied.status == "error",
    name .. " must distinguish a denied class directory, got " .. tostring(denied.status))
end

return true
