package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

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
assert(result.formula_version == "perf-stat-csv-no-aggr-v4")
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

local function failed_read(raw, paranoid)
  return PerfBandwidth.new({
    clock = clock_with_step(250000000),
    runner = { run = function() return raw end },
  }):read({
    perf_event_paranoid = paranoid,
    pmus = { { name = "uncore_imc_0", events = { cas_count_read = {} } } },
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

return true
