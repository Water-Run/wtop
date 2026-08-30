package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Bandwidth = require("wtop.inspectors.ram_bandwidth")

local function fake_fs(files, directories)
  local fs = {}
  function fs:read(path)
    local value = files[path]
    if value == nil then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    return tostring(value)
  end
  function fs:read_number(path)
    local value, err = self:read(path)
    if not value then return nil, err end
    return tonumber(value:match("^%s*([^%s]+)"))
  end
  function fs:list(path, limit)
    local values = directories[path]
    if not values then
      return nil, { kind = "missing", message = "directory_missing", path = path }
    end
    local result = {}
    for index = 1, math.min(#values, limit or #values) do result[index] = values[index] end
    return result, nil, limit ~= nil and #values > limit
  end
  return fs
end

local function stepping_clock()
  local now = 1000000000
  return {
    now_ns = function()
      local value = now
      now = now + 1000000
      return value
    end,
  }
end

local function section(result, id)
  for _, candidate in ipairs(result.sections or {}) do
    if candidate.id == id then return candidate end
  end
end

local base = "/sys/bus/event_source/devices"
local pmu = base .. "/uncore_imc_free_running_0"
local fs = fake_fs({
  [pmu .. "/type"] = "172\n",
  [pmu .. "/cpumask"] = "0-3,2,8\n",
  [pmu .. "/events/data_read"] = "event=0x01\n",
  [pmu .. "/events/data_read.scale"] = "6.103515625e-5\n",
  [pmu .. "/events/data_read.unit"] = "MiB\n",
  [pmu .. "/events/data_write"] = "event=0x02\n",
  [pmu .. "/events/data_write.scale"] = "6.103515625e-5\n",
  [pmu .. "/events/data_write.unit"] = "MiB\n",
  [pmu .. "/events/unc_mc0_rdcas_count.per-pkg"] = "1\n",
  ["/proc/sys/kernel/perf_event_paranoid"] = "2\n",
}, {
  [base] = { "../uncore_imc_escape", "uncore_imc_free_running_0" },
  [pmu .. "/events"] = { "../data_read", "data_read", "data_read.scale", "data_read.unit",
    "data_write", "data_write.scale", "data_write.unit", "unc_mc0_rdcas_count.per-pkg" },
})

local bandwidth = Bandwidth.new({ fs = fs, clock = stepping_clock() })
local pmus = assert(bandwidth:enumerate({ fs = fs }))
assert(#pmus == 1 and pmus[1].name == "uncore_imc_free_running_0")
assert(#pmus[1].cpus == 5 and pmus[1].cpus[5] == 8)
assert(pmus[1].events.data_read.scale == 6.103515625e-5)
assert(pmus[1].events.data_read.unit == "MiB")
assert(pmus[1].events["../data_read"] == nil)
assert(pmus[1].events["unc_mc0_rdcas_count.per-pkg"] == nil)
local degraded_probe = bandwidth:probe({ fs = fs })
assert(degraded_probe.state == "degraded" and degraded_probe.reason == "perf_reader_unavailable")

local bounded_cpus = Bandwidth.parse_cpu_list("0-999999999")
assert(#bounded_cpus == 8192 and bounded_cpus[#bounded_cpus] == 8191,
  "host-provided CPU ranges must have a hard expansion bound")
assert(Bandwidth.matches_pmu("uncore_imc_0"))
assert(not Bandwidth.matches_pmu("../uncore_imc_0"))
assert(not Bandwidth.matches_pmu({}))

local theoretical = assert(Bandwidth.theoretical_bytes_per_second(3200, 2, 64))
assert(theoretical == 51200000000)
assert(select(2, Bandwidth.theoretical_bytes_per_second(math.huge, 2, 64))
  == "data_rate_required")
assert(select(2, Bandwidth.theoretical_bytes_per_second(3200, 1.5, 64))
  == "reliable_channel_count_required")
assert(select(2, Bandwidth.theoretical_bytes_per_second(1e308, 8192, 64))
  == "theoretical_bandwidth_out_of_range")
assert(Bandwidth.theoretical_bytes_per_second(math.maxinteger, 1, 8) > 9e24,
  "theoretical multiplication must not wrap Lua integers")

local function inspect_with(measurement, entity)
  local inspector = Bandwidth.new({ fs = fs, clock = stepping_clock() })
  return inspector:inspect({
    fs = fs,
    perf_reader = function() return measurement end,
  }, entity or { id = "system-memory" })
end

local fresh = inspect_with({
  status = "ok",
  provider = "fixture_perf_stat",
  read_bytes_per_second = 100,
  write_bytes_per_second = 50,
  formula_version = "fixture-v2",
})
assert(fresh.status == "ok" and fresh.quality == "fresh")
local fields = section(fresh, "bandwidth").fields
assert(fields.total_bandwidth.value == 150)
assert(fields.read_bandwidth.provider_version == "fixture-v2")
assert(fields.read_bandwidth.provider == "fixture_perf_stat")

local from_counts = inspect_with({
  status = "ok", read_bytes = 1000, write_bytes = 500, duration_ns = 1000000000,
})
fields = section(from_counts, "bandwidth").fields
assert(fields.read_bandwidth.value == 1000 and fields.write_bandwidth.value == 500)

local partial = inspect_with({ status = "ok", read_bytes_per_second = 100 })
assert(partial.status == "ok" and partial.quality == "estimated")
assert(partial.reason == "perf_reader_partial_bandwidth")
fields = section(partial, "bandwidth").fields
assert(fields.total_bandwidth.value == 100)
assert(fields.write_bandwidth.value == nil and fields.write_bandwidth.quality == "unavailable")
assert(fields.write_bandwidth.reason == "perf_reader_missing_write_bandwidth")

local zero = inspect_with({
  status = "ok", read_bytes_per_second = 0, write_bytes_per_second = 0,
})
assert(zero.status == "ok" and section(zero, "bandwidth").fields.total_bandwidth.value == 0)

local large_direct = inspect_with({
  status = "ok", read_bytes_per_second = math.maxinteger, write_bytes_per_second = 1,
})
assert(section(large_direct, "bandwidth").fields.total_bandwidth.value > 9e18,
  "provider rates must be added in floating point instead of wrapping")

local timeout = inspect_with({ status = "timeout" })
assert(timeout.status == "unavailable" and timeout.quality == "error")
assert(timeout.reason == "perf_reader_timeout")
assert(timeout.provider == "perf_stat" and timeout.provider_version == nil)

local invalid = inspect_with({
  status = "ok", read_bytes_per_second = "100", write_bytes_per_second = 20,
})
assert(invalid.status == "unavailable" and invalid.quality == "error")
assert(invalid.reason == "perf_reader_invalid_bandwidth")

local negative = inspect_with({
  status = "ok", read_bytes = -1, write_bytes = 20, duration_ns = 1000000000,
})
assert(negative.status == "unavailable" and negative.reason == "perf_reader_invalid_counter_sample")

local invalid_status = inspect_with({ status = "mystery" })
assert(invalid_status.status == "unavailable" and invalid_status.quality == "error")
assert(invalid_status.reason == "invalid_perf_reader_status")

local empty_fs = fake_fs({ ["/proc/sys/kernel/perf_event_paranoid"] = "2\n" }, {
  [base] = {},
})
local no_pmu = Bandwidth.new({ fs = empty_fs, clock = stepping_clock() }):inspect({
  fs = empty_fs,
  perf_reader = function() error("must not run without a PMU") end,
}, { id = "system-memory" })
assert(no_pmu.status == "unavailable" and no_pmu.reason == "memory_controller_pmu_not_found")
assert(no_pmu.provider == "pmu_sysfs" and no_pmu.permission == "user")
local no_pmu_probe = Bandwidth.new({ fs = empty_fs }):probe({ fs = empty_fs })
assert(no_pmu_probe.state == "unavailable"
  and no_pmu_probe.reason == "memory_controller_pmu_not_found")

local denied_fs = fake_fs({}, {})
function denied_fs:list(path)
  return nil, { kind = "denied", message = "fixture_permission_denied", path = path }
end
local denied_probe = Bandwidth.new({ fs = denied_fs }):probe({ fs = denied_fs })
assert(denied_probe.state == "denied"
  and denied_probe.permission == "sysfs_read_access_required")
local denied_inspect = Bandwidth.new({ fs = denied_fs, clock = stepping_clock() }):inspect(
  { fs = denied_fs }, { id = "system-memory" })
assert(denied_inspect.status == "denied" and denied_inspect.provider == "pmu_sysfs")
assert(denied_inspect.permission == "sysfs_read_access_required")

local theoretical_only = Bandwidth.new({ fs = fs, clock = stepping_clock() }):inspect({ fs = fs }, {
  id = "system-memory",
  data_rate_mt_s = 3200,
  channels = 2,
  bus_width_bits = 64,
  topology_source = "fixture",
})
assert(theoretical_only.status == "ok" and theoretical_only.quality == "estimated")
assert(section(theoretical_only, "bandwidth").fields.theoretical_bandwidth.value == 51200000000)
assert(theoretical_only.provider == "memory_topology_formula")
assert(theoretical_only.provider_version == "1" and theoretical_only.permission == "user")
assert(theoretical_only.source == "fixture")
assert(section(theoretical_only, "bandwidth").source == "fixture")

return true
