-- A bound of exactly zero is not a bound.
--
-- Both collectors in this file publish limit attributes that the kernel driver
-- never programmed, and both do it by leaving the number at zero rather than by
-- withholding the file.  That is not a hypothetical: the development host does
-- both at once, and the powercap case carries its own contradiction inside a
-- single snapshot -- a constraint whose maximum reads 0 W beside its own 78 W
-- limit, which is not a specification no matter what the ABI says about it.
--
-- The rule is narrow on purpose, and the fixtures are built to keep it narrow.
-- A bound of zero is dropped; a *reading* of zero is a measurement and stays, so
-- the UCSI channel keeps reporting no voltage and no current; and a real bound
-- of any other value is untouched, including the nvme channel's negative
-- minimum of -40.15 C, which is the case a "drop the zero" fix implemented as
-- "drop anything suspicious" would take with it.
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local Fixture = require("support.fixture_fs")
local Hardware = require("support.hardware_fixtures")

local Hwmon = require("wtop.collectors.hwmon")
local Powercap = require("wtop.collectors.powercap")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label or "values differ",
      tostring(expected), tostring(actual)), 2)
  end
end

local function find(list, predicate)
  for _, value in ipairs(list or {}) do
    if predicate(value) then return value end
  end
  return nil
end

local function close(actual, expected, tolerance, label)
  if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
    error(string.format("%s: expected %s ±%s, got %s", label or "values differ",
      tostring(expected), tostring(tolerance), tostring(actual)), 2)
  end
end

-- ---------------------------------------------------------------------------
-- hwmon: `spd5118` registers temp1_min and temp1_lcrit and leaves them at 0.
-- ---------------------------------------------------------------------------

local hwmon = Hwmon.new({ fs = Fixture.new(Hardware.hwmon_unset_bounds()) })
local sample = hwmon:sample({ now_ns = function() return 0 end })
equal(sample.status, "ok", "hwmon sample status")

local spd = find(sample.data.devices, function(d) return d.name == "spd5118" end)
assert(spd, "the DIMM sensor must be discovered")
local dimm = spd.channels[1]
assert(dimm, "the DIMM temperature channel must be read")
close(dimm.input, 46.25, 0.001, "46250 millidegrees is 46.25 C")
close(dimm.thresholds.max, 55, 0.001, "the maximum the driver did set survives")
close(dimm.thresholds.crit, 85, 0.001, "and so does the critical")
equal(dimm.thresholds.min, nil,
  "a DIMM does not warn below 0 C, so an unset minimum is not a minimum")
equal(dimm.thresholds.lcrit, nil,
  "and the same holds for the lower critical the driver never programmed")
-- The two dropped bounds are not recorded as read errors either.  The number
-- parsed and the file existed; it simply was not a bound, and a channel that
-- lists an unreadable file for an attribute no driver sets would be reporting
-- the collector's plumbing as a hardware fault.
equal(dimm.errors.min, nil, "an unset bound is not a read error")
equal(dimm.errors.lcrit, nil, "nor is the other one")

-- A real negative bound is still a bound.
local nvme = find(sample.data.devices, function(d) return d.name == "nvme" end)
assert(nvme, "the nvme sensor must be discovered")
local nvme_temp = nvme.channels[1]
assert(nvme_temp, "the nvme temperature channel must be read")
close(nvme_temp.thresholds.min, -40.15, 0.001,
  "a real negative minimum survives: the rule is the zero, not the sign")
close(nvme_temp.thresholds.max, 83.85, 0.001, "and its positive bounds too")

-- A reading of zero is a measurement, and a device reporting nothing is still
-- reported as a device.
local ucsi = find(sample.data.devices,
  function(d) return (d.name or ""):find("ucsi") ~= nil end)
assert(ucsi, "the UCSI power source must still be discovered")
local voltage = find(ucsi.channels, function(c) return c.type == "voltage" end)
assert(voltage, "its voltage channel must still be read")
close(voltage.input, 0, 0.0001, "a 0 V rail is a reading, and it is a real one")
equal(voltage.thresholds.min, nil, "while its 0 V lower limit is not a bound")
equal(voltage.thresholds.max, nil, "and neither is its 0 V upper limit")
local current = find(ucsi.channels, function(c) return c.type == "current" end)
assert(current, "its current channel must still be read")
close(current.input, 0, 0.0001, "a 0 A reading is a reading")
equal(current.thresholds.max, nil, "while its 0 A limit is not a bound")

-- ---------------------------------------------------------------------------
-- powercap: a disabled zone publishes a 0 W limit, and two enabled constraints
-- publish a 0 W maximum beside real limits.
-- ---------------------------------------------------------------------------

local rapl = Powercap.new({ fs = Fixture.new(Hardware.powercap_intel_rapl_unset_bounds()) })
local power = rapl:sample({ now_ns = function() return 0 end })
equal(power.status, "ok", "powercap sample status")

local package_zone = find(power.data.zones, function(z) return z.name == "package-0" end)
assert(package_zone, "the package zone must be discovered")
close(package_zone.energy_joules, 123456.789012, 0.001, "the energy counter still reads")

local long_term = find(package_zone.constraints, function(c) return c.name == "long_term" end)
assert(long_term, "the long-term constraint must be named")
close(long_term.power_limit_watts, 26, 0.001, "its real limit survives")
close(long_term.maximum_power_watts, 45, 0.001, "and its real maximum too")

-- The self-contradicting pair.  Each of these sets a real limit of its own and a
-- maximum of 0, so reporting the maximum would state that the zone may not
-- exceed zero watts while also stating that it is capped at 78.
local short_term = find(package_zone.constraints, function(c) return c.name == "short_term" end)
assert(short_term, "the short-term constraint must be named")
close(short_term.power_limit_watts, 78, 0.001, "its real limit survives")
equal(short_term.maximum_power_watts, nil,
  "a maximum of 0 W beside a limit of 78 W is not a maximum")
local peak = find(package_zone.constraints, function(c) return c.name == "peak_power" end)
assert(peak, "the peak constraint must be named")
close(peak.power_limit_watts, 114, 0.001, "its real limit survives")
equal(peak.maximum_power_watts, nil, "and its unset maximum is absent rather than zero")

-- A disabled zone publishes 0 for its limit, which means nothing is capping it.
for _, name in ipairs({ "core", "uncore" }) do
  local zone = find(power.data.zones, function(z) return z.name == name end)
  assert(zone, name .. " zone must be discovered")
  equal(zone.enabled, false, name .. " zone is disabled")
  local constraint = zone.constraints[1]
  assert(constraint, name .. " zone's constraint must be read")
  equal(constraint.power_limit_watts, nil,
    name .. " zone is capped at zero watts, which a disabled zone does not mean")
  -- The zone itself is still reported, with its energy counter: a zone that is
  -- switched off is a fact about the machine, and dropping it would be a second
  -- answer to the same question.
  assert(zone.energy_joules ~= nil, name .. " zone's energy counter still reads")
end

print("ok: a bound of exactly zero is not a bound (hwmon, powercap)")
