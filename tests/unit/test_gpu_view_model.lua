package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local I18n = require("wtop.i18n")
local ViewModel = require("wtop.view_model")
local Workspace = require("wtop.workspace")

local translator = assert(I18n.new({ locale = "en-US" }))
local engine = { history_values = function() return {} end }
local snapshot = {
  cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, processes = {},
  cpu_frequency = {}, mounts = {}, workloads = {}, connections = {}, quality = {},
  sensors = { devices = {
    {
      class = "hwmon7", device_target = "../../../devices/pci0000:00/0000:03:00.0",
      channels = {
        { type = "temperature", input = 61, quality = "fresh" },
        { type = "temperature", input = 72.5, quality = "fresh" },
        { type = "power", input = 118.25, quality = "fresh" },
      },
    },
  } },
  gpus = {
    process_scan = { status = "ok", quality = "partial" },
    devices = {
      {
        id = "0000:03:00.0", card = "card0", metrics = {},
        device_target = "../../../devices/pci0000:00/0000:03:00.0",
        hwmon_refs = { { class = "hwmon7" } },
        processes = { list = {
          {
            id = "20:200", pid = 20, name = "renderer", utilization_percent = 72.5,
            quality = "fresh", memory_summary = { resident_bytes = 256 * 1024 * 1024 },
            engines = {
              render = { utilization_percent = 72.5 },
              copy = { utilization_percent = 5 },
            },
          },
          {
            id = "10:100", pid = 10, name = "video", utilization_percent = 15,
            quality = "estimated", memory_summary = { total_bytes = 64 * 1024 * 1024 },
            engines = { video = { utilization_percent = 15 } },
          },
        } },
      },
    },
  },
}

local models = ViewModel.build(engine, snapshot, translator, {}, "gpu")
local table_model = models.gpu_process_table
assert(#table_model.rows == 2)
assert(table_model.rows[1].pid == "20" and table_model.rows[1].process == "renderer")
assert(table_model.rows[1].utilization == "72.5%")
assert(table_model.rows[1].memory:find("256", 1, true))
assert(table_model.rows[1].engines:find("render 72.5%", 1, true))
assert(table_model.rows[2].quality == "estimated")
assert(table_model.status_text:find("2", 1, true))
assert(table_model.status_text:find("Partial", 1, true))
assert(models.gpu_table.rows[1].temperature:find("72.5", 1, true))
assert(models.gpu_table.rows[1].power == "118.2 W")
assert(#models.gpu_table.rows[1].sensor_sources == 1)

-- The frequency column against a one-clock and a two-clock device.  A discrete
-- card drives a graphics clock and a memory clock, and a bare number under a
-- header reading "Frequency" would claim to be the device's single clock, which
-- is not what was measured.  The single-clock device is the other half of the
-- contract: it is the common case and it must stay exactly as it was.
local clock_snapshot = {
  cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, processes = {},
  cpu_frequency = {}, mounts = {}, workloads = {}, connections = {}, quality = {},
  sensors = { devices = {} },
  gpus = { devices = {
    { id = "0000:01:00.0", card = "card9",
      metrics = { frequency_current_hz = 450000000, frequency_domain = "gt0" },
      frequencies = { domains = { { id = "gt0", current_hz = 450000000 } } } },
    { id = "0000:02:00.0", card = "card8",
      metrics = { frequency_current_hz = 1800000000, frequency_domain = "graphics" },
      frequencies = { domains = {
        { id = "graphics", current_hz = 1800000000 },
        { id = "memory", current_hz = 1000000000 },
      } } },
    -- A clock the kernel published a reading for but no ceiling for, which is
    -- what i915 does on this host.  The annotation counts the device's clocks,
    -- not how complete they are.
    { id = "0000:03:00.0", card = "card7",
      metrics = { frequency_current_hz = 900000000, frequency_domain = "tile0/gt0/freq0" },
      frequencies = { domains = {
        { id = "tile0/gt0/freq0", current_hz = 900000000 },
        { id = "tile1/gt0/freq0", current_hz = 1400000000 },
      } } },
    -- No clock list at all: nothing to count, so nothing to annotate, and the
    -- em dash stands alone rather than gaining a "+0".
    { id = "0000:04:00.0", card = "card6", metrics = {} },
  } },
}
local clock_rows = ViewModel.build(engine, clock_snapshot, translator, {}, "gpu").gpu_table.rows
assert(clock_rows[1].frequency == "450 MHz",
  "one clock needs no annotation, and the cell is unchanged: " .. tostring(clock_rows[1].frequency))
assert(clock_rows[2].frequency == "1.8 GHz +1",
  "two clocks must not read as one: " .. tostring(clock_rows[2].frequency))
assert(clock_rows[3].frequency == "900 MHz +1",
  "an incomplete clock is still one of several: " .. tostring(clock_rows[3].frequency))
assert(clock_rows[4].frequency == "—",
  "a device with no reading gets no annotation: " .. tostring(clock_rows[4].frequency))

-- Reverse navigation feeds: every row carries its numeric PID, the model
-- exposes the id list, and a selected PID maps to a row index.
local nav_models = ViewModel.build(engine, snapshot, translator, {}, "gpu", nil,
  nil, { gpu_selected = 10 })
assert(#nav_models.gpu_process_table.ids == 2, "ids list the visible rows")
assert(nav_models.gpu_process_table.ids[1] == 20
  and nav_models.gpu_process_table.ids[2] == 10, "ids follow row order")
assert(nav_models.gpu_process_table.selected == 2,
  "a selected PID maps onto its row index")
local unselected = ViewModel.build(engine, snapshot, translator, {}, "gpu")
assert(unselected.gpu_process_table.selected == nil,
  "without a selection no row is highlighted")
assert(type(nav_models.gpu_process_table.rows[1].pid_number) == "number",
  "rows keep their numeric PID for host-process lookup")

local summary_only_models = ViewModel.build(engine, snapshot, translator, {}, "gpu", nil,
  { gpu_summary = true })
assert(#summary_only_models.gpu_process_table.rows == 0 and #summary_only_models.gpu_table.rows == 0,
  "responsive-hidden GPU tables must not be materialized")

local many = {}
for index = 1, 520 do
  many[index] = {
    id = tostring(index) .. ":1",
    pid = index,
    name = "gpu-" .. tostring(index),
    utilization_percent = index / 10,
    memory_summary = { resident_bytes = index * 1024 },
    engines = {},
    quality = "fresh",
  }
end
snapshot.gpus.devices[1].processes.list = many
models = ViewModel.build(engine, snapshot, translator, {}, "gpu")
assert(#models.gpu_process_table.rows == 512)
assert(models.gpu_process_table.rows[1].pid == "520")
assert(models.gpu_process_table.rows[512].pid == "9")
assert(models.gpu_process_table.status_text:find("512/520", 1, true),
  "bounded GPU rows must still report visible/total counts")

local workspace = Workspace.new({ active_tab = "gpu", i18n = translator })
local order = table.concat(workspace:orders().gpu, ",")
assert(order:find("gpu_process_table", 1, true))

-- Current gauges must agree with history/Agent rather than painting retained
-- raw rates. The generic GPU summary uses the highest current device value.
for _, q in ipairs({ "gap", "reset", "held", "missing", "stale", "denied", "error", "unavailable" }) do
  local s = { cpu = { total = { utilization = 99, quality = q }, cores = {
      { name = "cpu0", utilization = 99, user = 90, quality = q },
      { name = "cpu1", utilization = 20, quality = "fresh" },
    } }, gpus = { devices = {
      { id = "invalid", metrics = { utilization_percent = 100 },
        metric_observations = { utilization_percent = { quality = q } } },
    } }, quality = { cpu = { status = "ok", quality = "fresh" },
      gpus = { status = "ok", quality = "fresh" } } }
  local m = ViewModel.build(engine, s, translator, {}, "compute")
  assert(m.cpu_overview.value == nil and m.cpu_total.value == nil, q)
  assert(m.cpu_overview.display_value == "—" and m.cpu_overview.quality == q, q)
  assert(m.gpu_overview.value == nil and m.gpu_summary.value == nil, q)
  assert(m.gpu_summary.display_value == "—" and m.gpu_summary.quality == q, q)
  assert(m.core_bars.items[1].value == nil and m.core_bars.items[1].display_value == "—", q)
  assert(m.core_table.rows[1].total_value == nil and m.core_table.rows[1].user == "—", q)
  assert(m.core_bars.items[2].value == 20 and m.core_table.rows[2].total_value == 20)
  s.cpu.total.quality = "fresh"
  s.quality.cpu.quality, s.quality.gpus.quality = "gap", "gap"
  s.gpus.devices[2] = { metrics = { utilization_percent = 20 }, quality = { utilization = "fresh" } }
  s.gpus.devices[3] = { metrics = { utilization_percent = 30 }, quality = { utilization = "fresh" } }
  m = ViewModel.build(engine, s, translator, {}, "compute")
  assert(m.cpu_total.value == 99 and m.cpu_total.quality == "fresh")
  assert(m.gpu_summary.value == 30 and m.gpu_overview.value == 30 and m.gpu_summary.quality == "fresh")
  assert(s.cpu.total.utilization == 99 and s.gpus.devices[1].metrics.utilization_percent == 100)
  s.quality.cpu.status, s.quality.gpus.status = "error", "error"
  m = ViewModel.build(engine, s, translator, {}, "compute")
  assert(m.cpu_total.value == nil and m.gpu_summary.value == nil)
  assert(m.cpu_total.quality == "error" and m.gpu_summary.quality == "error")
end
for _, q in ipairs({ false, "fresh", "measured", "estimated", "partial", "truncated" }) do
  local s = { cpu = { total = { utilization = 0, quality = q or nil }, cores = {
      { name = "cpu0", utilization = 0, quality = q or nil },
    } }, gpus = { devices = { { metrics = { utilization_percent = 0 },
      quality = { utilization = q or nil } } } } }
  local m = ViewModel.build(engine, s, translator, {}, "compute")
  assert(m.cpu_total.value == 0 and m.gpu_summary.value == 0 and m.core_bars.items[1].value == 0)
end

return true
