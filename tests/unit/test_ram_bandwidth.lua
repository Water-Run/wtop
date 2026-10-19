package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

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
local entities = assert(bandwidth:enumerate({ fs = fs }))
assert(entities[1].id == "system-memory" and entities[1].measurement_scope == "system")
local pmus = {}
for _, entity in ipairs(entities) do
  if entity.measurement_scope == "controller_pmu" then pmus[#pmus + 1] = entity end
end
pmus.truncated = entities.truncated
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

-- System and controller measurements must retain their actual counter scope.
do
local Bandwidth = require('wtop.inspectors.ram_bandwidth')
local Fixture = require('support.fixture_fs')
local Perf = require('wtop.inspectors.perf_bandwidth')
local base = '/sys/bus/event_source/devices'
local names = { 'uncore_imc_0', 'uncore_imc_free_running_0', 'uncore_imc_free_running_1' }
local files, dirs = { ['/proc/sys/kernel/perf_event_paranoid'] = '2\n' }, { [base] = names }
for index, name in ipairs(names) do
  local path = base .. '/' .. name
  files[path .. '/type'] = tostring(170 + index)
  files[path .. '/cpumask'] = '0,4\n'
  if index > 1 then
    dirs[path .. '/events'] = { 'data_read', 'data_write' }
    files[path .. '/events/data_read'] = 'event=0xff,umask=0x20\n'
    files[path .. '/events/data_write'] = 'event=0xff,umask=0x30\n'
  end
end
local fs = Fixture.new({ files = files, dirs = dirs })
local requested = {}
local reader = function(request)
  local selected = {}
  for _, pmu in ipairs(request.pmus) do selected[#selected + 1] = pmu.name end
  requested[#requested + 1] = selected
  return { status = 'ok', read_bytes_per_second = 100, write_bytes_per_second = 50,
    duration_ns = 250000000, estimated = false }
end
local inspector = Bandwidth.new({ fs = fs, perf_reader = reader })
local context = { fs = fs, now_ns = function() return 1000000000 end }
local selected = { id = names[2], type = 172, source = base .. '/' .. names[2],
  measurement_scope = 'controller_pmu', data_rate_mt_s = 4800,
  channels = 2, bus_width_bits = 64, topology_source = 'whole-system-DMI' }
local result = inspector:inspect(context, selected)
assert(#requested[1] == 1 and requested[1][1] == names[2],
  'A selected PMU must not measure unrelated controllers or display a whole-system total')
assert(result.status == 'ok' and result.quality == 'fresh')
assert(result.entity.metrics.total_bandwidth.value == 150)
assert(result.entity.metrics.total_bandwidth.source == selected.source)
assert(result.entity.metrics.measurement_scope.value == 'controller_pmu')
assert(#result.entity.evidence.pmus == 1 and result.entity.evidence.measurement_scope == 'controller_pmu')
assert(result.entity.metrics.theoretical_bandwidth.value == nil
  and result.entity.metrics.utilization.value == nil,
  'A controller result cannot inherit an unverified whole-system topology limit')

local entities = assert(inspector:enumerate(context))
assert(#entities == 4 and entities[1].id == 'system-memory'
  and entities[1].measurement_scope == 'system')
for index, name in ipairs(names) do
  assert(entities[index + 1].id == name and entities[index + 1].measurement_scope == 'controller_pmu')
end
local whole = { id = entities[1].id, measurement_scope = 'system', data_rate_mt_s = 4800,
  channels = 2, bus_width_bits = 64, topology_source = 'whole-system-DMI' }
result = inspector:inspect(context, whole)
assert(#requested[#requested] == 3 and result.entity.metrics.measurement_scope.value == 'system')
assert(result.entity.metrics.theoretical_bandwidth.estimated
  and result.entity.metrics.utilization.value ~= nil)
assert(result.entity.metrics.total_bandwidth.source == base)

-- Preserve legacy raw PMU selections, and reject stale/forged identities.
result = inspector:inspect(context, { id = names[3] })
assert(#requested[#requested] == 1 and requested[#requested][1] == names[3])
assert(result.entity.name == names[3], 'A legacy PMU selection must retain its controller name')
for _, entity in ipairs({
  { id = names[2], type = 999, measurement_scope = 'controller_pmu' },
  { id = names[2], source = '/other/source', measurement_scope = 'controller_pmu' },
  { id = 'uncore_imc_removed', measurement_scope = 'controller_pmu' },
  { id = '../uncore_imc_0', measurement_scope = 'controller_pmu' },
}) do
  local before = #requested
  result = inspector:inspect(context, entity)
  assert(#requested == before and result.status == 'unavailable'
    and result.entity.metrics.total_bandwidth.value == nil,
    'A missing or changed selected controller must not fall back to the system aggregate')
end

-- The actual perf reader cannot use another PMU to fill an empty selected PMU.
local executions = 0
local perf = Perf.new({ runner = { run = function()
  executions = executions + 1
  error('no event should have been opened')
end } })
local empty = Bandwidth.new({ fs = fs, perf_reader = function(request) return perf:read(request) end })
result = empty:inspect(context, entities[2])
assert(result.status == 'unavailable' and result.entity.metrics.total_bandwidth.value == nil
  and executions == 0 and result.entity.metrics.total_bandwidth.source == base .. '/' .. names[1])

local before = #requested
files[base .. '/' .. names[2] .. '/type'] = '999\n'
result = inspector:inspect(context, entities[3])
assert(result.status == 'unavailable' and #requested == before,
  'A selected identity changed after enumeration must be rejected before running perf')
files[base .. '/' .. names[2] .. '/type'] = '172\n'

for _, replacement in ipairs({ '999\n', false }) do
  local changing = Bandwidth.new({ fs = fs, perf_reader = function()
    files[base .. '/' .. names[2] .. '/type'] = replacement or nil
    return { status = 'ok', read_bytes_per_second = 100, write_bytes_per_second = 50 }
  end })
  result = changing:inspect(context, entities[3])
  assert(result.status == 'unavailable' and result.reason == 'memory_pmu_identity_changed'
    and result.entity.metrics.total_bandwidth.value == nil,
    'A controller changing during the counter read must discard the completed measurement')
  files[base .. '/' .. names[2] .. '/type'] = '172\n'
end
local denied_type = {}
local changing_fs = Fixture.new({ files = files, dirs = dirs, denied = denied_type })
local denied_after = Bandwidth.new({ fs = changing_fs, perf_reader = function()
  denied_type[base .. '/' .. names[2] .. '/type'] = true
  return { status = 'ok', read_bytes_per_second = 100, write_bytes_per_second = 50 }
end })
result = denied_after:inspect({ fs = changing_fs }, entities[3])
assert(result.status == 'denied' and result.entity.metrics.total_bandwidth.value == nil,
  'A post-read identity permission failure must not leave a fresh counter value')

local denied_fs = Fixture.new({ denied = { [base] = true } })
local denied = Bandwidth.new({ fs = denied_fs, perf_reader = reader })
local denied_entities, err = denied:enumerate({ fs = denied_fs })
assert(denied_entities == nil and err.kind == 'denied')
result = denied:inspect({ fs = denied_fs }, selected)
assert(result.status == 'denied' and #requested == before
  and result.entity.metrics.total_bandwidth.value == nil)

local no_pmus_fs = Fixture.new({ dirs = { [base] = {} } })
local no_pmus = Bandwidth.new({ fs = no_pmus_fs, perf_reader = reader })
assert(#assert(no_pmus:enumerate({ fs = no_pmus_fs })) == 0)
result = no_pmus:inspect({ fs = no_pmus_fs }, whole)
assert(result.status == 'ok' and result.quality == 'estimated' and #requested == before
  and result.entity.metrics.total_bandwidth.value == nil
  and result.entity.metrics.total_bandwidth.quality == 'unavailable'
  and result.entity.metrics.theoretical_bandwidth.estimated,
  'No-PMU hosts may retain a labelled topology estimate without a measured bandwidth')

local many = {}
for index = 1, 300 do many[index] = 'uncore_imc_' .. index end
local bounded_files = {}
for index, name in ipairs(many) do bounded_files[base .. '/' .. name .. '/type'] = tostring(10000 + index) end
local bounded_fs = Fixture.new({ files = bounded_files, dirs = { [base] = many } })
local bounded = Bandwidth.new({ fs = bounded_fs, perf_reader = function(request)
  assert(#request.pmus == 1 and request.pmus.truncated)
  return { status = 'ok', read_bytes_per_second = 20, write_bytes_per_second = 10,
    estimated = true }
end })
local bounded_entities = assert(bounded:enumerate({ fs = bounded_fs }))
assert(#bounded_entities == 257 and bounded_entities.truncated,
  'System entity plus bounded PMU list must preserve explicit enumeration truncation')
result = bounded:inspect({ fs = bounded_fs }, bounded_entities[2])
assert(result.quality == 'estimated' and result.entity.metrics.total_bandwidth.quality == 'estimated')

local TUI = require('wtop.tui')
local I18n = require('wtop.i18n')
local lines = TUI.inspector_lines('RAM bandwidth · ' .. bounded_entities[2].name,
  result, assert(I18n.new({ locale = 'en-US' })))
local text = table.concat(lines, '\n')
assert(text:find('Measurement scope', 1, true) and text:find('Selected controller PMU', 1, true)
  and text:find(bounded_entities[2].name, 1, true),
  'The declared measurement scope and selected controller must reach the rendered overlay')
local system_result = inspector:inspect(context, whole)
for _, locale in ipairs(assert(I18n.available())) do
  local translator = assert(I18n.new({ locale = locale }))
  for _, item in ipairs({ { result, 'inspector.bandwidth_scope_controller' },
                          { system_result, 'inspector.bandwidth_scope_system' } }) do
    local rendered = table.concat(TUI.inspector_lines('RAM bandwidth', item[1], translator), '\n')
    assert(rendered:find(translator:t('inspector.bandwidth_scope'), 1, true)
      and rendered:find(translator:t(item[2]), 1, true),
      'Measurement scope must retain its translated label and value in ' .. locale)
  end
end
print('RAM bandwidth scopes: system aggregate, selected-only counters/source, stale identities, absent events, legacy selection and topology isolation passed')

end

return true
