package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local PerfBandwidth = require("wtop.inspectors.perf_bandwidth")

local function clock_with_step(step)
  local now = 1000000000
  return {
    now_ns = function()
      local value = now
      now = now + step
      return value
    end,
  }
end

local observed
local runner = {
  run = function(_, argv, policy)
    observed = { argv = argv, policy = policy }
    return {
      status = "ok",
      exit_code = 0,
      stdout = "CPU0;999999;;uncore_imc_free_running_0/data_read/;1;100.00;;",
      stderr = table.concat({
        -- Named sysfs events are already multiplied by their .scale by perf;
        -- the CSV unit therefore controls the final byte conversion.
        "CPU0;64;MiB;uncore_imc_free_running_0/data_read/;200000000;80.00;;",
        "CPU0;0.030517578125;MiB;uncore_imc_free_running_0/data_write/;250000000;100.00;;",
      }, "\n"),
    }
  end,
}

local reader = PerfBandwidth.new({ runner = runner, clock = clock_with_step(400000000) })
local result = reader:read({
  duration_ms = 250,
  pmus = {
    {
      name = "uncore_imc_free_running_0",
      events = {
        data_read = { event = 255, umask = 32, scale = 6.103515625e-5, unit = "MiB" },
        data_write = { event = 255, umask = 33, scale = 6.103515625e-5, unit = "MiB" },
      },
    },
    {
      name = "uncore_imc_0",
      events = {
        cas_count_read = { event = 4, umask = 3 },
        cas_count_write = { event = 4, umask = 12 },
      },
    },
  },
})
assert(result.status == "ok")
assert(result.provider == "perf_stat")
assert(math.abs(result.read_bytes_per_second - (64 * 1024 * 1024 * 5)) < 0.001)
assert(math.abs(result.write_bytes_per_second - 128000) < 0.001)
assert(result.duration_ns == 250000000, "perf event runtime must win over process wall time")
assert(result.wall_duration_ns == 400000000)
assert(result.formula_version == "perf-stat-csv-no-aggr-v5")
assert(result.estimated == true, "multiplexed samples must be labelled estimated")
assert(result.read_event_count == 1 and result.write_event_count == 1)
assert(result.selected_event_family == "intel_free_running")
assert(result.alternative_event_count == 2 and result.eligible_event_count == 2)
assert(observed.policy.timeout_ms == 1500)
local command = table.concat(observed.argv, " ")
assert(command:find("--no-scale", 1, true))
assert(command:find(" -A ", 1, true), "multi-instance PMUs must not use perf's global aggregation")
assert(command:find("uncore_imc_free_running_0/data_read/", 1, true))
assert(command:find("uncore_imc_free_running_0/data_write/", 1, true))
assert(not command:find("uncore_imc_0/cas_count", 1, true),
  "alternative Intel counter families must not double count the same DRAM traffic")
assert(command:find("/usr/bin/sleep 0.250", 1, true))

local counts, unsupported, samples, issues = PerfBandwidth.parse_stat(table.concat({
  "CPU0;7;;unrelated/event/;100;100.00;;uncore_imc_0/cas_count_read/",
  "CPU0;<not supported>;;uncore_imc_0/cas_count_read/;;;;",
  "CPU0;<not counted>;;uncore_imc_0/cas_count_write/;;;;",
}, "\n"), {
  { label = "uncore_imc_0/cas_count_read/" },
  { label = "uncore_imc_0/cas_count_write/" },
}, ";")
assert(next(counts) == nil)
assert(unsupported["uncore_imc_0/cas_count_read/"])
assert(issues["uncore_imc_0/cas_count_write/"] == "not_counted")
assert(#samples["uncore_imc_0/cas_count_read/"] == 0,
  "labels outside the event-name column must not match")

counts, unsupported, samples = PerfBandwidth.parse_stat(
  "CPU0;0;bytes;uncore_imc_0/cas_count_read/;123;100.00;;\n", {
    { label = "uncore_imc_0/cas_count_read/" },
  }, ";")
assert(counts["uncore_imc_0/cas_count_read/"] == 0)
assert(samples["uncore_imc_0/cas_count_read/"][1].runtime_ns == 123)
counts, unsupported, samples, issues = PerfBandwidth.parse_stat(table.concat({
  "CPU0;1;;uncore_imc_0/cas_count_read/;100;100.00;;",
  "CPU0;2;;uncore_imc_0/cas_count_read/;100;100.00;;",
}, "\n"), {
  { label = "uncore_imc_0/cas_count_read/" },
}, ";")
assert(counts["uncore_imc_0/cas_count_read/"] == nil)
assert(issues["uncore_imc_0/cas_count_read/"] == "duplicate_event",
  "the same event/CPU row must never be double counted")
assert(PerfBandwidth.direction_for("unc_mc0_rdcas_count_freerun") == "read")
assert(PerfBandwidth.direction_for("unc_mc0_wrcas_count_freerun") == "write")
assert(PerfBandwidth.direction_for("clockticks") == nil)
assert(PerfBandwidth.bytes_per_count({ scale = 0.5, unit = "MiB" }) == 524288)
assert(PerfBandwidth.bytes_per_count({ unit = "bytes" }) == 1)
assert(PerfBandwidth.bytes_per_count({ scale = -1, unit = "MiB" }) == nil)
assert(PerfBandwidth.unit_bytes(" GiB ") == 1024 * 1024 * 1024)
assert(PerfBandwidth.safe_identifier("uncore_imc-0.data_read"))
assert(not PerfBandwidth.safe_identifier("../uncore_imc"))
assert(not PerfBandwidth.safe_identifier("pmu,event"))

local only_read = PerfBandwidth.new({
  clock = clock_with_step(100000000),
  runner = { run = function()
    return {
      status = "ok", exit_code = 0,
      stderr = "CPU0;10;;uncore_imc_0/cas_count_read/;100000000;100.00;;",
    }
  end },
}):read({ pmus = {
  { name = "uncore_imc_0", events = { cas_count_read = {} } },
} })
assert(only_read.status == "ok" and only_read.estimated == true)
assert(only_read.read_bytes_per_second == 6400 and only_read.write_event_count == 0)
assert(only_read.write_bytes_per_second == nil, "an unavailable direction must not look like measured zero")

local multi_instance = PerfBandwidth.new({
  clock = clock_with_step(1000000000),
  runner = { run = function()
    return {
      status = "ok", exit_code = 0,
      stderr = table.concat({
        "CPU0;1000;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
        "CPU24;1000;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
        "CPU0;500;;uncore_imc_0/cas_count_write/;1000000000;100.00;;",
        "CPU24;500;;uncore_imc_0/cas_count_write/;1000000000;100.00;;",
      }, "\n"),
    }
  end },
}):read({ pmus = {
  {
    name = "uncore_imc_0",
    cpus = { 0, 24 },
    events = { cas_count_read = {}, cas_count_write = {} },
  },
} })
assert(multi_instance.status == "ok" and multi_instance.estimated == false)
assert(multi_instance.read_bytes_per_second == 128000)
assert(multi_instance.write_bytes_per_second == 64000)
assert(multi_instance.instance_count == 4 and multi_instance.event_count == 2,
  "per-instance rates must be summed without treating instances as duplicate events")

local missing_instance = PerfBandwidth.new({
  clock = clock_with_step(1000000000),
  runner = { run = function()
    return {
      status = "ok", exit_code = 0,
      stderr = table.concat({
        "CPU0;1000;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
        "CPU0;500;;uncore_imc_0/cas_count_write/;1000000000;100.00;;",
      }, "\n"),
    }
  end },
}):read({ pmus = {
  {
    name = "uncore_imc_0",
    cpus = { 0, 24 },
    events = { cas_count_read = {}, cas_count_write = {} },
  },
} })
assert(missing_instance.status == "ok" and missing_instance.estimated == true,
  "missing PMU control instances must downgrade the sample")

local alias_command
local deduplicated_alias = PerfBandwidth.new({
  clock = clock_with_step(1000000000),
  runner = { run = function(_, argv)
    alias_command = table.concat(argv, " ")
    return {
      status = "ok", exit_code = 0,
      stderr = table.concat({
        "CPU0;1000;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
        "CPU0;500;;uncore_imc_0/cas_count_write/;1000000000;100.00;;",
      }, "\n"),
    }
  end },
}):read({ pmus = {
  {
    name = "uncore_imc_0",
    events = {
      cas_count_read = { event = 4, umask = 3 },
      unc_mc0_rdcas_alias = { event = 4, umask = 3 },
      cas_count_write = { event = 4, umask = 12 },
    },
  },
} })
assert(deduplicated_alias.status == "ok" and deduplicated_alias.event_count == 2)
assert(not alias_command:find("unc_mc0_rdcas_alias", 1, true),
  "aliases with the same PMU encoding must be counted once")

local bounded_events = PerfBandwidth.new({
  max_events = 2,
  clock = clock_with_step(100000000),
  runner = { run = function()
    return {
      status = "ok", exit_code = 0,
      stderr = table.concat({
        "CPU0;1;;uncore_imc_0/cas_count_read/;100000000;100.00;;",
        "CPU0;1;;uncore_imc_0/cas_count_write/;100000000;100.00;;",
      }, "\n"),
    }
  end },
}):read({ pmus = {
  { name = "uncore_imc_0", events = { cas_count_read = {}, cas_count_write = {} } },
  { name = "uncore_imc_1", events = { cas_count_read = {}, cas_count_write = {} } },
} })
assert(bounded_events.status == "ok" and bounded_events.events_truncated == true)
assert(bounded_events.requested_event_count == 2 and bounded_events.eligible_event_count == 4)
assert(bounded_events.estimated == true, "event-cap truncation must not be labelled fresh")

local large_count = PerfBandwidth.new({
  clock = clock_with_step(1000000000),
  runner = { run = function()
    return {
      status = "ok", exit_code = 0,
      stderr = "CPU0;" .. tostring(math.maxinteger)
        .. ";;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
    }
  end },
}):read({ pmus = {
  { name = "uncore_imc_0", events = { cas_count_read = {} } },
} })
assert(large_count.status == "ok" and large_count.read_bytes_per_second > 5e20,
  "large integer counters must convert in floating point instead of wrapping")

local function failed_read(raw, paranoid, pmus)
  return PerfBandwidth.new({
    clock = clock_with_step(250000000),
    runner = { run = function() return raw end },
  }):read({
    perf_event_paranoid = paranoid,
    pmus = pmus or { { name = "uncore_imc_0", events = { cas_count_read = {} } } },
  })
end

local denied = failed_read({
  status = "error", exit_code = 255,
  stderr = "Access to performance monitoring is limited by perf_event_paranoid",
})
assert(denied.status == "denied" and denied.reason == "perf_event_permission_denied")

local unsupported_failure = failed_read({
  status = "error", exit_code = 1, stderr = "event is not supported by this PMU",
}, 4)
assert(unsupported_failure.status == "unavailable"
    and unsupported_failure.reason == "memory_events_not_supported",
  "unsupported PMU events must remain unavailable, not become permission denied")

local stdout_spoofed_failure = failed_read({
  status = "error", exit_code = 1,
  stdout = "permission denied by spoofed workload output",
  stderr = "event is not supported by this PMU",
})
assert(stdout_spoofed_failure.status == "unavailable"
  and stdout_spoofed_failure.reason == "memory_events_not_supported")

local denied_open_fallback = failed_read({
  status = "error", exit_code = 1,
  stderr = "The sys_perf_event_open() syscall failed for event: Invalid argument",
}, 2)
assert(denied_open_fallback.status == "unavailable"
    and denied_open_fallback.reason == "memory_event_open_failed",
  "ambiguous EINVAL must not be reported as a definite permission denial")
assert(denied_open_fallback.details.permission_may_be_required == true)

local unsupported_open = failed_read({
  status = "error", exit_code = 1,
  stderr = "No supported events found.\nThe sys_perf_event_open() syscall failed: Invalid argument",
}, 2)
assert(unsupported_open.status == "unavailable"
  and unsupported_open.reason == "memory_events_not_supported")
assert(unsupported_open.details.permission_may_be_required == true)

-- Captured on the i7-13620H host: perf_event_open first returned EACCES,
-- then perf retried with exclude_kernel/exclude_hv and reported only EINVAL.
local permission_retry = table.concat({
  "Error:",
  "No supported events found.",
  "The sys_perf_event_open() syscall failed for event (uncore_imc_free_running_0/data_read/u): Invalid argument",
  '"dmesg | grep -i perf" may provide additional information.',
}, "\n")
local retry_pmus = { {
  name = "uncore_imc_free_running_0",
  events = { data_read = {}, data_write = {} },
} }
local function retry_failure(diagnostics, paranoid, stdout)
  return failed_read({ status = "error", exit_code = 1,
    stderr = diagnostics, stdout = stdout }, paranoid, retry_pmus)
end
local retry_denied = retry_failure(permission_retry, 2)
assert(retry_denied.status == "denied"
  and retry_denied.reason == "perf_event_permission_denied")
assert(retry_denied.details.perf_event_paranoid == 2
  and retry_denied.details.permission_may_be_required)
assert(retry_denied.read_bytes_per_second == nil
  and retry_denied.write_bytes_per_second == nil)
for _, paranoid in ipairs({ -1, 0, 1 }) do
  assert(retry_failure(permission_retry, paranoid).status == "unavailable",
    "the user modifier alone cannot prove a restrictive permission fallback")
end
assert(retry_failure(permission_retry).status == "unavailable")
for _, diagnostics in ipairs({
  permission_retry:gsub("data_read/u", "data_read/"),
  permission_retry:gsub("uncore_imc_free_running_0", "other_pmu"),
  permission_retry:gsub("data_read/u", "data_read/uk"),
  permission_retry:gsub("Invalid argument", "No such device") .. "\nInvalid argument",
  permission_retry:gsub("The sys_perf_event_open%(%) syscall failed for event", "failed to open event"),
  (permission_retry:gsub("Invalid argument", "Invalid argument (unrelated)")),
}) do
  assert(retry_failure(diagnostics, 2).status == "unavailable",
    "unrelated or ambiguous diagnostics must not assert permission denial")
end
assert(retry_failure("No supported events found.", 2, permission_retry).status == "unavailable",
  "workload stdout must not supply a permission-fallback diagnostic")
local retry_write = permission_retry:gsub("data_read/u", "data_write/u")
assert(retry_failure(retry_write, 3).status == "denied",
  "the fallback must match any requested direction, not only the first event")
print("perf memory permission retry: captured EACCES-to-EINVAL and exact-line negatives passed")

local unavailable = failed_read({
  status = "unavailable", reason = "argv_executor_unavailable",
}, 4)
assert(unavailable.status == "unavailable" and unavailable.reason == "argv_executor_unavailable")

local missing_perf = failed_read({ status = "error", exit_code = 127, stderr = "" }, 4)
assert(missing_perf.status == "unavailable" and missing_perf.reason == "perf_executable_not_found")

local unrunnable_perf = failed_read({ status = "error", exit_code = 126, stderr = "" }, 4)
assert(unrunnable_perf.status == "unavailable"
  and unrunnable_perf.reason == "perf_executable_not_runnable")

local missing_sleep = failed_read({
  status = "error", exit_code = 1, stderr = "Workload failed: No such file or directory",
})
assert(missing_sleep.status == "unavailable" and missing_sleep.reason == "sleep_executable_not_found")

local unrunnable_sleep = failed_read({
  status = "error", exit_code = 1, stderr = "Workload failed: Permission denied",
}, 4)
assert(unrunnable_sleep.status == "unavailable"
  and unrunnable_sleep.reason == "sleep_executable_not_runnable")

local timeout = failed_read({ status = "timeout", reason = "timeout", stderr = "" })
assert(timeout.status == "error" and timeout.reason == "perf_stat_timeout")

local truncated = failed_read({
  status = "ok", exit_code = 0, truncated = true,
  stderr = "CPU0;1;;uncore_imc_0/cas_count_read/;100000000;100.00;;",
})
assert(truncated.status == "error" and truncated.reason == "perf_stat_output_truncated")
local truncated_failure = failed_read({
  status = "error", exit_code = 255, truncated = true,
  stderr = "Access to performance monitoring is limited",
})
assert(truncated_failure.status == "error"
  and truncated_failure.reason == "perf_stat_output_truncated")

local unsupported_events = failed_read({
  status = "ok", exit_code = 0,
  stderr = "CPU0;<not supported>;;uncore_imc_0/cas_count_read/;;;;",
})
assert(unsupported_events.status == "unavailable"
  and unsupported_events.reason == "memory_events_not_supported")

local not_counted = failed_read({
  status = "ok", exit_code = 0,
  stderr = "CPU0;<not counted>;;uncore_imc_0/cas_count_read/;;;;",
})
assert(not_counted.status == "unavailable" and not_counted.reason == "memory_events_not_counted")

local missing_runtime = failed_read({
  status = "ok", exit_code = 0,
  stderr = "CPU0;1;;uncore_imc_0/cas_count_read/;;;;",
})
assert(missing_runtime.status == "unavailable" and missing_runtime.reason == "perf_stat_invalid_counts")

local runner_called = false
local invalid_executable = PerfBandwidth.new({
  executable = "perf",
  runner = { run = function() runner_called = true end },
}):read({ pmus = {
  { name = "uncore_imc_0", events = { cas_count_read = {} } },
} })
assert(invalid_executable.status == "error" and invalid_executable.reason == "invalid_perf_executable")
assert(not runner_called)

local runner_exception = PerfBandwidth.new({
  clock = clock_with_step(1),
  runner = { run = function() error("boom") end },
}):read({ pmus = {
  { name = "uncore_imc_0", events = { cas_count_read = {} } },
} })
assert(runner_exception.status == "error" and runner_exception.reason == "perf_runner_exception")

local no_events = reader:read({ pmus = {
  { name = "uncore_imc_0", events = { clockticks = {}, ["bad,event"] = {} } },
} })
assert(no_events.status == "unavailable")
assert(reader:read({ pmus = "not-a-table", duration_ms = 0 / 0 }).status == "unavailable")

do
  local function near(a, b) assert(type(a) == "number" and math.abs(a - b) < 1e-7, tostring(a) .. " != " .. b) end
  local function sum(records, direction)
    local value = 0
    for _, row in ipairs(records) do
      if row.direction == direction and row.bytes_per_second ~= nil then value = value + row.bytes_per_second end
    end
    return value
  end
  assert(#result.counter_samples == 2 and result.counter_samples_total == 2 and not result.counter_samples_truncated)
  near(result.counter_samples[1].runtime_ns, 200000000)
  assert(result.counter_samples[1].quality == "estimated" and result.counter_samples[1].instance == "CPU0")
  near(sum(result.counter_samples, "read"), result.read_bytes_per_second)
  near(sum(result.counter_samples, "write"), result.write_bytes_per_second)
  assert(#multi_instance.counter_samples == 4 and multi_instance.counter_samples_total == 4)
  for _, row in ipairs(multi_instance.counter_samples) do
    assert(row.pmu == "uncore_imc_0" and row.instance_expected == true and row.quality == "fresh")
    assert(row.runtime_ns == 1000000000 and row.running_percent == 100)
  end
  near(sum(multi_instance.counter_samples, "read"), multi_instance.read_bytes_per_second)
  near(sum(multi_instance.counter_samples, "write"), multi_instance.write_bytes_per_second)
  assert(#missing_instance.counter_samples == 4)
  local missing = 0
  for _, row in ipairs(missing_instance.counter_samples) do
    if row.instance == "CPU24" then
      assert(row.bytes_per_second == nil and row.runtime_ns == nil and row.count == nil)
      assert(row.quality == "unavailable" and row.instance_expected and row.reason == "perf_reader_partial_bandwidth")
      missing = missing + 1
    end
  end
  assert(missing == 2, "absent instances disappeared instead of retaining missing values")
  local function read_rows(rows, cpus)
    return PerfBandwidth.new({ clock = clock_with_step(1000000000), runner = { run = function()
      return { status = "ok", exit_code = 0, stderr = table.concat(rows, "\n") }
    end } }):read({ pmus = { { name = "uncore_imc_0", cpus = cpus,
      events = { cas_count_read = {}, cas_count_write = {} } } } })
  end
  -- Two returned instances is insufficient: one belongs to a different
  -- control CPU. It must not replace CPU24 or enter its PMU's numerator.
  local foreign = read_rows({
    "CPU0;1000;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
    "CPU48;99999;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
    "CPU0;500;;uncore_imc_0/cas_count_write/;1000000000;100.00;;",
    "CPU48;99999;;uncore_imc_0/cas_count_write/;1000000000;100.00;;",
  }, { 0, 24 })
  assert(foreign.status == "ok" and foreign.estimated)
  near(foreign.read_bytes_per_second, 64000); near(foreign.write_bytes_per_second, 32000)
  assert(#foreign.counter_samples == 6)
  local rejected = 0
  for _, row in ipairs(foreign.counter_samples) do
    if row.instance == "CPU48" then
      assert(row.instance_expected == false and row.bytes_per_second == nil and row.quality == "unavailable")
      rejected = rejected + 1
    end
  end
  assert(rejected == 2)
  local invalid = read_rows({
    "CPU0;1;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
    "CPU0;2;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
    "CPU0;<not supported>;;uncore_imc_0/cas_count_write/;;;;",
  }, { 0 })
  assert(invalid.status == "unavailable" and #invalid.counter_samples == 2)
  for _, row in ipairs(invalid.counter_samples) do assert(row.bytes_per_second == nil and row.quality == "unavailable") end
  local not_counted = read_rows({
    "CPU0;<not counted>;;uncore_imc_0/cas_count_read/;;;;",
    "CPU0;<not counted>;;uncore_imc_0/cas_count_write/;;;;",
  }, { 0 })
  assert(not_counted.reason == "memory_events_not_counted" and #not_counted.counter_samples == 2)
  for _, row in ipairs(not_counted.counter_samples) do assert(row.reason == "memory_events_not_counted") end
  local bad_percent = read_rows({
    "CPU0;1;;uncore_imc_0/cas_count_read/;1000000000;101.00;;",
    "CPU0;0;;uncore_imc_0/cas_count_write/;1000000000;100.00;;",
  }, { 0 })
  assert(bad_percent.status == "ok" and bad_percent.read_bytes_per_second == nil and bad_percent.write_bytes_per_second == 0)
  assert(bad_percent.counter_samples[1].quality == "unavailable" and bad_percent.counter_samples[2].bytes_per_second == 0)
  local unknown_coverage = read_rows({
    "CPU0;1;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
    "CPU0;0;;uncore_imc_0/cas_count_write/;1000000000;100.00;;",
  })
  assert(unknown_coverage.estimated and unknown_coverage.counter_samples[1].quality == "estimated")
  local cpus = {}; for id = 0, 1279 do cpus[#cpus + 1] = id end
  local bounded = read_rows({
    "CPU0;1;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
    "CPU0;0;;uncore_imc_0/cas_count_write/;1000000000;100.00;;",
  }, cpus)
  assert(#bounded.counter_samples == 1024 and bounded.counter_samples_total == 2560 and bounded.counter_samples_truncated)
  assert(bounded.counter_samples[1].bytes_per_second == 64 and bounded.counter_samples[2].bytes_per_second == 0,
    "missing-instance placeholders hid real observations at the detail bound")
  assert(bounded.read_bytes_per_second == 64 and bounded.write_bytes_per_second == 0)
  assert(PerfBandwidth.bytes_per_count({ unit = "cycles" }) == nil,
    "an explicit non-byte unit was silently converted into 64-byte transfers")
  print("ok: per-event PMU instances, rates/runtime/coverage, foreign CPUs, duplicates, missing/unsupported rows and bounded evidence")
end


-- The direct kernel path reuses event selection but executes no helpers.
do
  local Direct = require("wtop.inspectors.native_bandwidth")
  local Fixture = require("support.fixture_fs")
  assert(Direct.encode("event=0xff,umask=0x20", {event="config:0-7",umask="config:8-15"}).config == 0x20ff)
  assert(Direct.encode("event=7", {event="config1:1,6-7"}).config1 == 194)
  assert(Direct.encode("event=3", {event="config2:6,1"}).config2 == 66)
  assert(Direct.encode("a=3,b=1", {a="config:0-1",b="config:0"}).config == 3)
  assert(Direct.encode("a=3,b=0", {a="config:0-1",b="config:0"}) == nil)
  assert(Direct.encode("event=0xffffffffffffffff", {event="config:0-63"}).config == -1)
  assert(Direct.encode("event=0x000000000000000000ff", {event="config:0-7"}).config == 255)
  for _, case in ipairs({
    {"event=256", {event="config:0-7"}}, {"event=1,event=2",{event="config:0-7"}},
    {"event=1,",{event="config:0-7"}}, {"event=1,,umask=2",{event="config:0-7",umask="config:8-15"}},
    {"event=1",{event="config3:0-7"}}, {"event=1",{event="config:0-64"}},
    {"event=1",{event="config:1-0"}}, {"event=1",{event="config:0,0"}},
    {"event=18446744073709551616",{event="config:0-63"}}, {"event=$(id)",{event="config:0-7"}},
  }) do assert(Direct.encode(case[1],case[2]) == nil,case[1]) end
  local base="/sys/bus/event_source/devices/uncore_imc_0"
  local files={ [base.."/type"]="8", [base.."/cpumask"]="0",
    [base.."/events/cas_count_read"]="event=4,umask=3",
    [base.."/events/cas_count_write"]="event=4,umask=12",
    [base.."/format/event"]="config:0-7", [base.."/format/umask"]="config:8-15" }
  local fs=Fixture.new({files=files})
  local pmus={{name="uncore_imc_0",id="uncore_imc_0",source=base,type=8,cpus={0},events={
    cas_count_read={event=4,umask=3},cas_count_write={event=4,umask=12}}}}
  local calls, running, errno, changed=0,1000000000,nil,false
  local native={read_perf_counts=function(events,duration)
    calls=calls+1; assert(duration==250 and #events==2)
    assert(events[1].type==8 and events[1].cpu==0 and events[1].config==0x304)
    assert(events[2].config==0xc04)
    return {started_ns=1000000000,finished_ns=3000000000,samples={
      errno and {errno=errno} or {count=100,enabled_ns=1000000000,running_ns=running},
      errno and {errno=errno} or {count=50,enabled_ns=1000000000,running_ns=running}}}
  end}
  local direct=Direct.new({fs=fs,native=native})
  assert(direct:read({pmus=pmus,safe_mode=true}).reason=="safe_mode" and calls==0)
  local result=direct:read({pmus=pmus})
  assert(result.status=="ok" and result.read_bytes_per_second==6400 and result.write_bytes_per_second==3200)
  assert(#result.counter_samples==2 and result.counter_samples[1].count==100)
  assert(result.counter_samples[1].bytes_per_count==64 and result.counter_samples[1].enabled_ns==1000000000)
  running=500000000;result=direct:read({pmus=pmus})
  assert(result.estimated and result.counter_samples[1].quality=="estimated" and result.counter_samples[1].running_percent==50)
  errno=13;result=direct:read({pmus=pmus});assert(result.status=="denied" and result.reason=="perf_event_permission_denied")
  errno=5;assert(direct:read({pmus=pmus}).status=="error")
  errno=nil;running=0;assert(direct:read({pmus=pmus}).status=="unavailable")
  running=1000000000
  local partial_native={read_perf_counts=function(events,duration)
    local r=native.read_perf_counts(events,duration);r.samples[2]={errno=13};return r
  end}
  local partial=Direct.new({fs=fs,native=partial_native}):read({pmus=pmus})
  assert(partial.status=="ok" and partial.estimated and partial.read_bytes_per_second==6400
    and partial.write_bytes_per_second==nil,"missing write counter was filled with zero")
  local duplicate=direct:read({pmus={pmus[1],pmus[1]}})
  assert(duplicate.reason=="memory_pmu_identity_changed")
  local malformed=Direct.new({fs=fs,native={read_perf_counts=function()
    return {started_ns=1,finished_ns=2,samples={false,false}}
  end}}):read({pmus=pmus})
  assert(malformed.status=="error" and malformed.reason=="invalid_perf_reader_result")
  local old=native.read_perf_counts
  native.read_perf_counts=function(...) local r=old(...);changed=true;return r end
  local changing={read=function(_,path,limit)
    if changed and path==base.."/type"then return "9"end
    return fs:read(path,limit)
  end}
  local invalid=Direct.new({fs=changing,native=native}):read({pmus=pmus})
  assert(invalid.reason=="memory_pmu_identity_changed" and invalid.read_bytes_per_second==nil)
  print("ok: direct kernel encoding, overlapping masks, native count/running conversion, permissions, safe mode and identity changes")
end

return true
