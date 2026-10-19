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

do
  local Perf = require("wtop.inspectors.perf_bandwidth")
  local Json = require("wtop.format.json")
  local Fixture = require("support.fixture_fs")
  local TUI = require("wtop.tui")
  local I18n = require("wtop.i18n")
  local root = "/sys/bus/event_source/devices"
  local name = "uncore_imc_0"
  local path = root .. "/" .. name
  local files = { [path .. "/type"] = "8", [path .. "/cpumask"] = "0,24",
    [path .. "/events/cas_count_read"] = "event=0x04,umask=0x03",
    [path .. "/events/cas_count_write"] = "event=0x04,umask=0x0c" }
  local fs = Fixture.new({ files = files, dirs = { [root] = { name },
    [path .. "/events"] = { "cas_count_read", "cas_count_write" } } })
  local csv = {
    "CPU0;1000;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
    "CPU24;2000;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
    "CPU0;500;;uncore_imc_0/cas_count_write/;1000000000;100.00;;",
    "CPU24;0;;uncore_imc_0/cas_count_write/;1000000000;100.00;;",
  }
  local perf = Perf.new({ clock = stepping_clock(), runner = { run = function()
    return { status = "ok", exit_code = 0, stderr = table.concat(csv, "\n") }
  end } })
  local provided
  local inspector = Bandwidth.new({ fs = fs, clock = stepping_clock(), perf_reader = function(request)
    provided = perf:read(request); return provided
  end })
  local context = { fs = fs, now_ns = function() return 2e9 end }
  local result = inspector:inspect(context, { id = name, type = 8, measurement_scope = "controller_pmu" })
  assert(result.status == "ok" and result.quality == "fresh")
  local samples = result.entity.metrics.counter_samples.value
  assert(#samples == 4 and result.details.counter_samples_total == 4 and not result.details.counter_samples_truncated)
  local read, write = 0, 0
  for _, row in ipairs(samples) do
    assert(row.source == path and row.quality == "fresh" and row.instance_expected)
    assert(row.runtime_ns == 1e9 and row.running_percent == 100)
    if row.direction == "read" then read = read + row.bytes_per_second else write = write + row.bytes_per_second end
  end
  assert(read == result.entity.metrics.read_bandwidth.value and write == result.entity.metrics.write_bandwidth.value)
  assert(samples[4].bytes_per_second == 0, "a measured zero instance disappeared")
  provided.counter_samples[1].bytes_per_second = 999
  assert(samples[1].bytes_per_second == 64000, "a provider mutated published evidence")
  assert(type(Json.encode(result)) == "string")
  for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
    local tr = assert(I18n.new({ locale = locale }))
    local lines = table.concat(TUI.inspector_lines("RAM bandwidth", result, tr), "\n")
    for _, key in ipairs({ "bandwidth_instances", "bandwidth_control_note", "bandwidth_runtime", "bandwidth_running", "bandwidth_expected" }) do
      assert(lines:find(tr:t("inspector." .. key), 1, true), locale .. " " .. key)
    end
    assert(lines:find("CPU24", 1, true) and lines:find("cas_count_write", 1, true))
    assert(not lines:find("inspector.bandwidth_", 1, true), locale)
  end
  csv = { "CPU0;<not supported>;;uncore_imc_0/cas_count_read/;;;;",
          "CPU0;<not counted>;;uncore_imc_0/cas_count_write/;;;;" }
  local unavailable = inspector:inspect(context, { id = "system-memory" })
  assert(unavailable.status == "unavailable" and #unavailable.entity.metrics.counter_samples.value == 4)
  assert(unavailable.entity.metrics.read_bandwidth.value == nil and unavailable.entity.metrics.write_bandwidth.value == nil)
  assert(unavailable.details.reader_error.counter_samples == nil, "unbounded raw records escaped the public reducer")
  local legacy = Bandwidth.new({ fs = fs, perf_reader = function()
    return { status = "ok", read_bytes_per_second = 10, write_bytes_per_second = 20 }
  end }):inspect(context, {})
  assert(legacy.entity.metrics.counter_samples == nil and legacy.entity.metrics.total_bandwidth.value == 30)
  -- A provider cannot attach foreign PMUs, invented events or the opposite
  -- direction to the selected source's instance evidence.
  local valid = { pmu = name, event = "cas_count_read", instance = "CPU0", direction = "read",
    bytes_per_second = 64, count = 1, runtime_ns = 1e9, running_percent = 100, quality = "fresh" }
  local input = { valid }
  for _, change in ipairs({ { pmu = "uncore_imc_other" }, { event = "unknown" }, { direction = "write" } }) do
    local row = {}; for k, v in pairs(valid) do row[k] = v end
    for k, v in pairs(change) do row[k] = v end
    input[#input + 1] = row
  end
  local filtered = Bandwidth.new({ fs = fs, perf_reader = function()
    return { status = "ok", read_bytes_per_second = 64, counter_samples = input }
  end }):inspect(context, { id = name, type = 8, measurement_scope = "controller_pmu" })
  assert(#filtered.entity.metrics.counter_samples.value == 1 and filtered.details.counter_samples_total == 4)
  assert(filtered.details.counter_samples_truncated and filtered.entity.metrics.counter_samples.quality == "truncated")
  files[path .. "/cpumask"] = "0-1279"
  csv = { "CPU0;1;;uncore_imc_0/cas_count_read/;1000000000;100.00;;",
          "CPU0;0;;uncore_imc_0/cas_count_write/;1000000000;100.00;;" }
  local bounded = inspector:inspect(context, {})
  assert(#bounded.entity.metrics.counter_samples.value == 1024 and bounded.details.counter_samples_total == 2560)
  local tr = assert(I18n.new({ locale = "en-US" }))
  local lines = TUI.inspector_lines("RAM bandwidth", bounded, tr)
  local text = table.concat(lines, "\n")
  assert(text:find(tr:t("inspector.bandwidth_instances_count", { shown = 128, total = 2560 }), 1, true))
  assert(not text:find("CPU127", 1, true) and #lines < 1400, "instance expansion ignored its view bound")
  print("ok: PMU instance evidence end-to-end, metadata/source isolation, no-zero-fill, legacy readers, JSON and10locale bounded UI")
end


-- Live history never blocks on a pending reader, mixes identities or fills gaps.
do
  local Live = require("wtop.inspectors.live_bandwidth")
  local Model = require("wtop.inspectors.model")
  local function result(timestamp, id, status)
    status = status or "ok"
    local fields = {
      read_bandwidth = Model.field(status=="ok" and 64 or nil,"bytes_per_second"),
      write_bandwidth = Model.field(status=="ok" and 32 or nil,"bytes_per_second") }
    return Model.result(status, Model.entity("system-memory","memory",{metrics=fields,
      evidence={measurement_scope="system",pmus={{name=id,type=8}}}}),{}, {timestamp_ns=timestamp})
  end
  assert(not pcall(Live.new,{measurement_scope="controller_pmu"},{}))
  local calls, closes = 0, 0
  local worker={sample=function()
    calls=calls+1
    if calls==1 then return {sampling_pending=true}end
    return {data={inspection=result(200000000,"uncore_imc_0")}}
  end,close=function()closes=closes+1 end}
  local live=Live.new({id="system-memory"},{worker=worker})
  assert(not live:poll({},0)and calls==1)
  assert(not live:poll({},1000)and calls==1)
  assert(live:poll({},250000000)and calls==2 and live.history:len()==1)
  assert(not live:record(result(200000000,"uncore_imc_0"),500000000))
  assert(not live:record(result(600000000,"uncore_imc_0"),500000000))
  assert(live:record(result(2000000000,"uncore_imc_1"),2000000000))
  assert(live.history:len()==1 and live.epoch==2)
  assert(live:current(6000000000).quality=="stale")
  assert(live:record(result(3000000000,"uncore_imc_1","denied"),3000000000))
  local values,peak=live:series("read",3000000000)
  assert(#values==2 and values[1]==64 and values[2]==false and peak==64)
  assert(live:current(9000000000).status=="denied")
  for index=1,200 do local now=10000000000+index*1000000000;assert(live:record(result(now,"uncore_imc_1"),now))end
  assert(live.history:len()==128)
  local _,empty=live:series("read",999000000000);assert(empty==0)
  live:close();live:close();assert(closes==1 and live.history:len()==0 and not live:poll({},999000000000))
  local safe=Live.new({id="system-memory"},{worker=worker})
  assert(safe:poll({safe_mode=true},0)and calls==2 and safe:current(0).reason=="safe_mode")
  safe:close()
  local pause_closes,pause_opens=0,0
  local paused=Live.new({id="system-memory"},{create_worker=function()
    pause_opens=pause_opens+1
    return {sample=function()return {sampling_pending=true}end,close=function()pause_closes=pause_closes+1 end}
  end})
  paused:set_paused(true,100);assert(pause_closes==1 and not paused:poll({},1000))
  paused:set_paused(true,200);assert(pause_closes==1 and paused.paused_at==100)
  paused:set_paused(false,300);assert(not paused:poll({},300)and pause_opens==2)
  paused:close();assert(pause_closes==2)
  print("ok: live RAM nonblocking polling, source epochs, stale values, gap preservation, bounded history and idempotent close")
end

return true
