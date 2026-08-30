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
assert(table_model.status_text:find("partial", 1, true))
assert(models.gpu_table.rows[1].temperature:find("72.5", 1, true))
assert(models.gpu_table.rows[1].power == "118.2 W")
assert(#models.gpu_table.rows[1].sensor_sources == 1)

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

return true
