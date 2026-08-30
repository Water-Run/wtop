package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local I18n = require("wtop.i18n")
local ViewModel = require("wtop.view_model")

local translator = assert(I18n.new({ locale = "en-US" }))
local engine = { history_values = function() return {} end }

local function snapshot()
  return {
    cpu = {}, memory = {}, pressure = {}, disks = {}, network = { interfaces = {} },
    processes = {}, gpus = {}, cpu_frequency = {}, sensors = {}, quality = {},
    connections = { connections = {}, owner_scan = { status = "ok" } },
    mounts = { mounts = {} }, workloads = { workloads = {}, summary = {} },
  }
end

local network = snapshot()
for index = 1, 600 do
  local endpoint = string.format("127.0.0.1:%04d", index)
  network.connections.connections[index] = {
    id = tostring(index), protocol = "tcp", state = "ESTABLISHED",
    local_endpoint = { text = endpoint }, remote_endpoint = { text = "198.51.100.1:443" },
    owners = {},
  }
end
network.connections.total = 600
local network_models = ViewModel.build(engine, network, translator, {}, "network", nil,
  { connection_table = true })
assert(#network_models.connection_table.rows == 512)
assert(network_models.connection_table.rows[1].local_endpoint == "127.0.0.1:0001")
assert(network_models.connection_table.rows[512].local_endpoint == "127.0.0.1:0512")

local storage = snapshot()
for index = 1, 600 do
  storage.mounts.mounts[index] = {
    id = tostring(index), mount_point = string.format("/mnt/%04d", index),
    fs_type = "ext4", kind = "local", source = "/dev/test", capacity = {},
  }
end
local storage_models = ViewModel.build(engine, storage, translator, {}, "storage", nil,
  { mount_table = true })
assert(#storage_models.mount_table.rows == 512)
assert(storage_models.mount_table.rows[1].mount == "/mnt/0001")
assert(storage_models.mount_table.rows[512].mount == "/mnt/0512")

local workloads = snapshot()
for index = 1, 600 do
  workloads.workloads.workloads[index] = {
    id = "/scope/" .. tostring(index), name = "scope-" .. tostring(index), depth = 1,
    cpu = {}, memory = {}, io = {}, processes = {},
  }
end
local workload_models = ViewModel.build(engine, workloads, translator, {}, "workloads", nil,
  { workload_table = true })
assert(#workload_models.workload_table.rows == 512)
assert(workload_models.workload_table.rows[1].workload:find("scope%-1"))
assert(workload_models.workload_table.rows[512].workload:find("scope%-512"))

local hidden_models = ViewModel.build(engine, network, translator, {}, "network", nil,
  { network_summary = true })
assert(#hidden_models.connection_table.rows == 0,
  "responsive-hidden high-cardinality tables must not be materialized")

return true
