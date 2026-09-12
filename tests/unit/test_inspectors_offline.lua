package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

-- Drive the on-demand inspectors without the tools they shell out to.
--
-- `smartctl`, `perf` and `systemctl` are absent from most build machines and
-- from CI, so the parsing behind them is the least-exercised code in the
-- project: on this project's own development host all three report
-- "unavailable" and several hundred lines per inspector never run.  The runner
-- takes an injected executor, so real command output can be replayed instead.
--
-- The output below is copied from real tools, including the parts that are
-- awkward on purpose: smartctl exits non-zero while still printing a valid
-- report, `perf stat` writes its counters to stderr, and a drive in standby
-- must not be woken just to read its temperature.

local Fixture = require("support.fixture_fs")
local Runner = require("wtop.core.runner")
local Smart = require("wtop.inspectors.smart")
local PerfBandwidth = require("wtop.inspectors.perf_bandwidth")
local RamBandwidth = require("wtop.inspectors.ram_bandwidth")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label or "values differ",
      tostring(expected), tostring(actual)), 2)
  end
end

--- A runner whose executor replays canned output, and records what it was asked
--- to run so the argv itself can be asserted.
local function scripted_runner(handler)
  local calls = {}
  local runner = Runner.new({
    execute = function(argv, policy)
      calls[#calls + 1] = { argv = argv, policy = policy }
      return handler(argv, policy) or { status = "ok", exit_code = 0, stdout = "", stderr = "" }
    end,
  })
  return runner, calls
end

local function argv_contains(argv, needle)
  for _, value in ipairs(argv) do
    if value == needle then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- SMART / NVMe
-- ---------------------------------------------------------------------------

-- Trimmed from `smartctl --json --all /dev/sda` on a healthy SATA SSD.
local SMART_SATA = [[
{
  "smartctl": { "exit_status": 0, "version": [7, 4] },
  "device": { "name": "/dev/sda", "type": "sat", "protocol": "ATA" },
  "model_name": "Samsung SSD 870 EVO 1TB",
  "serial_number": "S6PTNJ0TB00000X",
  "firmware_version": "SVT02B6Q",
  "user_capacity": { "bytes": 1000204886016 },
  "rotation_rate": 0,
  "smart_status": { "passed": true },
  "temperature": { "current": 34 },
  "power_on_time": { "hours": 14231 },
  "power_cycle_count": 412,
  "ata_smart_attributes": {
    "table": [
      { "id": 5, "name": "Reallocated_Sector_Ct", "value": 100, "worst": 100,
        "thresh": 10, "when_failed": "", "raw": { "value": 0, "string": "0" } },
      { "id": 177, "name": "Wear_Leveling_Count", "value": 96, "worst": 96,
        "thresh": 0, "when_failed": "", "raw": { "value": 61, "string": "61" } },
      { "id": 199, "name": "UDMA_CRC_Error_Count", "value": 100, "worst": 100,
        "thresh": 0, "when_failed": "", "raw": { "value": 3, "string": "3" } }
    ]
  }
}
]]

-- An NVMe drive.  smartctl reports NVMe health in a different object entirely,
-- and exits with bit 2 set because a warning attribute is raised.
local SMART_NVME = [[
{
  "smartctl": { "exit_status": 4, "version": [7, 4] },
  "device": { "name": "/dev/nvme0", "type": "nvme", "protocol": "NVMe" },
  "model_name": "WD_BLACK SN850X 2TB",
  "firmware_version": "620311WD",
  "user_capacity": { "bytes": 2000398934016 },
  "smart_status": { "passed": true, "nvme": { "value": 0 } },
  "nvme_smart_health_information_log": {
    "critical_warning": 0,
    "temperature": 41,
    "available_spare": 100,
    "available_spare_threshold": 10,
    "percentage_used": 7,
    "data_units_read": 123456789,
    "data_units_written": 98765432,
    "power_cycles": 233,
    "power_on_hours": 9011,
    "unsafe_shutdowns": 18,
    "media_errors": 0
  }
}
]]

local smart_runner, smart_calls = scripted_runner(function(argv)
  if argv_contains(argv, "/dev/nvme0") then
    -- smartctl signals warnings through its exit status while still printing a
    -- complete, valid report.  Treating a non-zero exit as failure would throw
    -- away exactly the reports that matter.
    return { status = "ok", exit_code = 4, stdout = SMART_NVME, stderr = "" }
  end
  return { status = "ok", exit_code = 0, stdout = SMART_SATA, stderr = "" }
end)

local smart = Smart.new({ runner = smart_runner, executable = "/usr/sbin/smartctl" })

local sata = smart:inspect({}, { id = "sda", path = "/dev/sda", name = "sda" }, "summary")
assert(sata, "the SATA inspection must return a result")
equal(sata.status, "ok", "a zero exit is a successful report")
assert(#sata.sections > 0, "a report has sections")

local function field(result, name)
  for _, section in ipairs(result.sections or {}) do
    local entry = section.fields and section.fields[name]
    if entry ~= nil then return entry end
  end
  return nil
end

local health = field(sata, "smart_status") or field(sata, "health") or field(sata, "passed")
assert(health ~= nil, "the pass/fail verdict must be reported")
local model = field(sata, "model_name") or field(sata, "model")
assert(model and tostring(model.value):find("870 EVO", 1, true),
  "the model must survive into the report")
local temperature = field(sata, "temperature") or field(sata, "temperature_celsius")
assert(temperature and tonumber(temperature.value) == 34, "the drive temperature")

-- The probe must never spin a sleeping drive back up just to read it.
for _, call in ipairs(smart_calls) do
  assert(argv_contains(call.argv, "--nocheck=standby")
      or argv_contains(call.argv, "-n") or argv_contains(call.argv, "standby"),
    "SMART reads must pass a standby guard, got: " .. table.concat(call.argv, " "))
end

local nvme = smart:inspect({}, { id = "nvme0", path = "/dev/nvme0", name = "nvme0" }, "summary")
assert(nvme, "the NVMe inspection must return a result")
assert(nvme.status == "ok" or nvme.status == "partial",
  "a warning exit status must still yield a report, got " .. tostring(nvme.status))
local used = field(nvme, "percentage_used")
if used then equal(tonumber(used.value), 7, "NVMe endurance used") end

-- A tool that is genuinely missing is a different outcome from a tool that ran
-- and failed, and both differ from a tool that timed out.
local missing = Smart.new({
  runner = Runner.new({ execute = function()
    return { status = "error", exit_code = 127, stdout = "", stderr = "not found" }
  end }),
}):inspect({}, { id = "sda", path = "/dev/sda" }, "summary")
assert(missing.status ~= "ok", "a failed helper must not report success")

local timed_out = Smart.new({
  runner = Runner.new({ execute = function()
    return { status = "timeout", exit_code = nil, stdout = "", stderr = "" }
  end }),
}):inspect({}, { id = "sda", path = "/dev/sda" }, "summary")
assert(timed_out.status ~= "ok", "a timed-out helper must not report success")
assert(tostring(timed_out.reason or ""):find("timeout", 1, true)
    or timed_out.quality == "unavailable" or timed_out.status == "error",
  "a timeout must be distinguishable, got " .. tostring(timed_out.reason))

-- Garbage on stdout must be rejected rather than half-parsed.
local garbage = Smart.new({
  runner = Runner.new({ execute = function()
    return { status = "ok", exit_code = 0, stdout = "<html>504 Gateway</html>", stderr = "" }
  end }),
}):inspect({}, { id = "sda", path = "/dev/sda" }, "summary")
assert(garbage.status ~= "ok", "non-JSON output must not be accepted as a report")

-- Enumeration must reject a device path that is not a device path.
local enumerated = smart:enumerate({
  block_devices = {
    { id = "sda", path = "/dev/sda", name = "sda", model = "Samsung", rotational = 0 },
    { id = "evil", path = "/etc/shadow", name = "evil" },
    { id = "worse", path = "../../etc/passwd", name = "worse" },
  },
})
equal(#enumerated, 1, "only real device paths are offered for inspection")
equal(enumerated[1].path, "/dev/sda", "and it is the real one")

-- ---------------------------------------------------------------------------
-- RAM bandwidth through `perf stat`
-- ---------------------------------------------------------------------------

-- `perf stat` is invoked with `-x ;` and `-A`, so each row is
-- `instance;value;unit;event;run;%` and the whole table lands on **stderr**,
-- not stdout.  A reader that watches stdout sees nothing at all.  Keeping the
-- per-instance rows separate matters too: perf's aggregation sums both the
-- values and the run times, and the quotient of those sums is a per-instance
-- average rather than total system bandwidth on a multi-socket host.
local PERF_STDERR = table.concat({
  "CPU0;1234567890;;uncore_imc_0/cas_count_read/;250123456;100.00",
  "CPU0;987654321;;uncore_imc_0/cas_count_write/;250123456;100.00",
  "CPU1;1222333444;;uncore_imc_1/cas_count_read/;250123456;100.00",
  "CPU1;975310864;;uncore_imc_1/cas_count_write/;250123456;100.00",
  "",
}, "\n")

-- The PMU inventory the collector would normally have discovered under
-- /sys/bus/event_source/devices.
local PMUS = {
  { name = "uncore_imc_0", events = {
    cas_count_read = { unit = "MiB", scale = 6.103515625e-05 },
    cas_count_write = { unit = "MiB", scale = 6.103515625e-05 },
  } },
  { name = "uncore_imc_1", events = {
    cas_count_read = { unit = "MiB", scale = 6.103515625e-05 },
    cas_count_write = { unit = "MiB", scale = 6.103515625e-05 },
  } },
}

local elapsed_ns = 0
local fake_clock = {
  now_ns = function()
    elapsed_ns = elapsed_ns + 250000000
    return elapsed_ns
  end,
}

local perf_runner, perf_calls = scripted_runner(function(argv)
  if argv_contains(argv, "stat") then
    return { status = "ok", exit_code = 0, stdout = "", stderr = PERF_STDERR }
  end
  return { status = "ok", exit_code = 0, stdout = "", stderr = "" }
end)

local perf = PerfBandwidth.new({
  runner = perf_runner,
  clock = fake_clock,
  executable = "/usr/bin/perf",
  sleep_executable = "/usr/bin/sleep",
})
local reading = perf:read({ duration_ms = 250, pmus = PMUS })
assert(reading ~= nil, "the perf reader must return something")
equal(#perf_calls, 1, "perf must be invoked exactly once")
-- The workload must be the fixed sleep, never a shell.
local argv = perf_calls[1].argv
equal(argv[1], "/usr/bin/perf", "the executable is an absolute path")
assert(argv_contains(argv, "/usr/bin/sleep"), "the workload is the fixed sleep binary")
for _, value in ipairs(argv) do
  assert(not tostring(value):find("sh", 1, true) or tostring(value):find("/sleep", 1, true),
    "no shell may appear in the argv: " .. tostring(value))
end

equal(reading.status, "ok", "a clean perf run yields a reading: " .. tostring(reading.reason))
equal(reading.provider, "perf_stat", "the provider is named")
equal(reading.selected_event_family, "intel_cas", "the event family is recorded")
equal(reading.instance_count, 4, "every per-instance row is counted separately")
equal(reading.read_event_count, 2, "both read events contribute")
equal(reading.write_event_count, 2, "both write events contribute")

-- CAS counts are cache-line transfers, 64 bytes each, summed across both
-- memory controllers.  An implementation that used perf's own aggregation
-- would divide a summed value by a summed run time and land somewhere else.
local expected_read = (1234567890 + 1222333444) * 64
local expected_write = (987654321 + 975310864) * 64
assert(math.abs(reading.read_bytes - expected_read) < 1,
  string.format("read bytes: expected %d, got %s", expected_read, tostring(reading.read_bytes)))
assert(math.abs(reading.write_bytes - expected_write) < 1,
  string.format("write bytes: expected %d, got %s", expected_write, tostring(reading.write_bytes)))

-- The rate must come from the counters' own run time, not from wall clock.
equal(reading.duration_ns, 250123456, "the run time comes from perf's own column")
local expected_rate = expected_read / (250123456 / 1e9)
assert(math.abs(reading.read_bytes_per_second - expected_rate) < expected_rate * 1e-6,
  "the read rate divides by the measured run time")
equal(reading.estimated, false, "a complete, unmultiplexed reading is not estimated")

-- perf reporting on stdout instead of stderr must not be mistaken for silence
-- turning into a zero-bandwidth measurement.
local stdout_only = PerfBandwidth.new({
  runner = Runner.new({ execute = function()
    return { status = "ok", exit_code = 0, stdout = PERF_STDERR, stderr = "" }
  end }),
  clock = fake_clock,
  executable = "/usr/bin/perf",
  sleep_executable = "/usr/bin/sleep",
}):read({ duration_ms = 250, pmus = PMUS })
assert(stdout_only.status ~= "ok" or stdout_only.quality ~= "fresh",
  "counters that never arrived must not read as an exact measurement")

-- Permission denial is the most common real failure and must be named.
local denied = PerfBandwidth.new({
  runner = Runner.new({ execute = function()
    return { status = "ok", exit_code = 255, stdout = "",
      stderr = "Error:\nAccess to performance monitoring and observability operations is limited.\n" }
  end }),
  clock = fake_clock,
  executable = "/usr/bin/perf",
  sleep_executable = "/usr/bin/sleep",
}):read({ duration_ms = 250, pmus = PMUS })
equal(denied.status, "denied", "a paranoid-level refusal is a denial, not an error")

-- No PMU at all is "this machine cannot measure it", not a failure.
local no_pmu = perf:read({ duration_ms = 250, pmus = {} })
equal(no_pmu.status, "unavailable", "a host without memory-controller PMUs")
equal(no_pmu.reason, "supported_memory_events_not_found", "and it says so")

-- The inspector must refuse to invent a number when perf is not there.
local absent = RamBandwidth.new({
  perf_reader = function()
    return { status = "unavailable", reason = "perf_not_found" }
  end,
}):inspect({}, { id = "system-memory", name = "System RAM" }, "summary")
assert(absent, "the bandwidth inspector must return a result even when perf is absent")
assert(absent.status ~= "ok", "a missing PMU must not be reported as a measurement")
assert(absent.reason ~= nil or absent.quality == "unavailable",
  "and the reason must be stated")

-- A partial or multiplexed measurement must be marked estimated rather than
-- passed off as exact.
local partial = RamBandwidth.new({
  perf_reader = function()
    return {
      status = "ok",
      quality = "estimated",
      multiplexed = true,
      directions = { read = 1234567890 },
      duration_seconds = 0.25,
    }
  end,
}):inspect({}, { id = "system-memory", name = "System RAM" }, "summary")
assert(partial, "a partial reading still produces a result")
assert(partial.quality ~= "fresh",
  "a multiplexed or one-directional reading must not claim to be exact, got "
    .. tostring(partial.quality))

return true
