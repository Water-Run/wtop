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
assert(network_models.connection_table.selected == 1
  and network_models.connection_table.ids[1] == "1")
local selected_network = ViewModel.build(engine, network, translator, {}, "network", nil,
  { connection_table = true }, { connection_selected = "512" })
assert(selected_network.connection_table.selected == 512)
network.connections.connections[600].owners = { { pid = 42, name = "needled" } }
local filtered_network = ViewModel.build(engine, network, translator, {}, "network", nil,
  { connection_table = true }, { connection_query = "NEEDLED(42)" })
assert(#filtered_network.connection_table.rows == 1
  and filtered_network.connection_table.rows[1].local_endpoint == "127.0.0.1:0600",
  "connection filtering must search the full source before the 512-row display cap")
assert(filtered_network.connection_table.status_text:find("1/1 shown", 1, true))

-- A process jump must wait for the requested owner scan, then filter by the
-- whole process generation before applying the visible-row cap.
network.connections.connections[599].owners = { { pid = 42, id = "42:old", name = "needled" } }
network.connections.connections[600].owners[1].id = "42:new"
network.connections.owner_scan.target_id = "42:new"
network.connections.owner_scan.target_status = "ok"
network.quality.connections = { status = "ok", timestamp_ns = 99 }
local target_options = {
  connection_owner_target = { pid = 42, id = "42:new", requested_ns = 100 },
  connection_query = "NEEDLED(42)",
}
local pending_network = ViewModel.build(engine, network, translator, {}, "network", nil,
  { connection_table = true }, target_options)
assert(#pending_network.connection_table.rows == 0
  and pending_network.connection_table.status_text:find("finding owners", 1, true))
network.quality.connections.timestamp_ns = 100
target_options.connection_owner_target.prior_quality = network.quality.connections
local same_tick_network = ViewModel.build(engine, network, translator, {}, "network", nil,
  { connection_table = true }, target_options)
assert(#same_tick_network.connection_table.rows == 0,
  "a clock tick shared with the previous sample is not a new owner scan")
network.quality.connections = { status = "ok", timestamp_ns = 100 }
local target_network = ViewModel.build(engine, network, translator, {}, "network", nil,
  { connection_table = true }, target_options)
assert(#target_network.connection_table.rows == 1
  and target_network.connection_table.ids[1] == "600"
  and target_network.connection_table.status_text:find("1/1 sockets", 1, true))
network.connections.owner_scan.target_status = "changed"
local changed_network = ViewModel.build(engine, network, translator, {}, "network", nil,
  { connection_table = true }, target_options)
assert(#changed_network.connection_table.rows == 0
  and changed_network.connection_table.status_text:find("process identity changed", 1, true))
network.connections.owner_scan.target_status = "ok"
network.quality.connections.status = "error"
local failed_network = ViewModel.build(engine, network, translator, {}, "network", nil,
  { connection_table = true }, target_options)
assert(#failed_network.connection_table.rows == 0,
  "a failed new sample cannot publish owners retained from an earlier scan")
assert(not failed_network.connection_table.status_text:find("finding owners", 1, true),
  "a failed owner refresh should end its loading state")

-- Network field terms intersect before the 512-row cap. Numeric fields are
-- exact or compared as numbers, so missing queue readings are not zero.
local last_connection = network.connections.connections[600]
last_connection.uid = 1000
last_connection.local_port = 8080
last_connection.remote_port = 443
last_connection.tx_queue, last_connection.rx_queue = 16, 32
last_connection.owners_quality = "fresh"
network.connections.connections[599].owners_quality = "fresh"
local function network_search(query)
  return ViewModel.build(engine, network, translator, {}, "network", nil,
    { connection_table = true }, { connection_query = query }).connection_table
end
assert(#network_search("proto:tcp state:established pid:42").rows == 2,
  "structured terms combine across protocol, state and exact owner PID")
assert(network_search("proto:tcp uid:1000 lport:8080").ids[1] == "600",
  "structured conditions run before the display cap")
assert(#network_search("pid:4").rows == 0,
  "PID comparisons are exact, not numeric substrings")
assert(network_search("queue>30").ids[1] == "600"
  and #network_search("queue<5").rows == 0,
  "queue comparison does not turn missing readings into zero")
assert(network_search("queue>=48").ids[1] == "600"
  and #network_search("queue<=47").rows == 0
  and network_search("tx=16 rx>30").ids[1] == "600",
  "both inclusive operators and separate queue directions compare numerically")
assert(network_search("proto:tcp !state:listen owner:needled").ids[1] == "599",
  "field negation and owner text work together")
last_connection.owners_quality = "estimated"
assert(#network_search("pid:42 !owner:absent").rows == 1,
  "an incomplete owner scan cannot satisfy a negated owner condition")
last_connection.owners_quality = "fresh"
assert(#network_search("queue>bogus").rows == 0,
  "invalid numeric comparisons remain literal instead of becoming zero")
last_connection.tx_queue, last_connection.rx_queue = math.maxinteger, 1
assert(#network_search("queue>0").rows == 0,
  "an overflowing queue sum is unknown, not a wrapped value")
last_connection.tx_queue, last_connection.rx_queue = 16, 32
last_connection.local_endpoint.text = "unix path with space"
assert(network_search("unix path with space").ids[1] == "600",
  "a plain query still searches the whole phrase")

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
assert(storage_models.mount_table.status_text == "showing 512 of 600",
  "a mount table capped at the model row limit reports what was dropped")
assert(network_models.mount_table.status_text == nil,
  "a mount table below the cap shows no truncation note")
storage.mounts.mounts[600].source = "/dev/late"
storage.mounts.mounts[600].capacity = {
  used_percent = 93, available_bytes = 2 * 1024^3,
  total_bytes = 20 * 1024^3,
}
storage.mounts.mounts[600].inodes = { used_percent = 80 }
storage.mounts.mounts[600].readonly = true
local function mount_search(query, show_pseudo)
  return ViewModel.build(engine, storage, translator, {}, "storage", nil,
    { mount_table = true }, { mount_query = query,
      show_pseudo_filesystems = show_pseudo }).mount_table
end
assert(#mount_search("path:/mnt/0600 used>90").rows == 1
  and mount_search("path:/mnt/0600 used>90").rows[1].mount == "/mnt/0600",
  "mount path and measured usage intersect before the 512-row cap")
assert(#mount_search("source:/dev/late state:ro avail<3G inodes>=80").rows == 1,
  "source, read-only state, byte units and inode percentage combine")
assert(#mount_search("used<1").rows == 0
  and #mount_search("!used>90").rows == 0,
  "unknown capacities cannot become zero under positive or negated comparisons")
assert(#mount_search("used>bogus").rows == 0,
  "malformed capacity thresholds remain literal")
storage.mounts.mounts[601] = { id = "601", mount_point = "/sys/late",
  fs_type = "sysfs", kind = "pseudo", source = "sysfs", capacity = {} }
assert(#mount_search("path:/sys/late").rows == 0
  and #mount_search("path:/sys/late", true).rows == 1,
  "search respects the pseudo-filesystem visibility switch")
storage.mounts.mounts[602] = { id = "602", mount_point = "/mnt/0600",
  fs_type = "ext4", kind = "local", source = "/dev/replaced", capacity = {} }
assert(#mount_search("source:/dev/late").rows == 0
  and #mount_search("source:/dev/replaced").rows == 1,
  "search sees the last mount visible at a repeatedly mounted path")

local sensors = snapshot()
sensors.sensors.devices = { { name = "device", channels = {} } }
for index = 1, 600 do
  sensors.sensors.devices[1].channels[index] = {
    type = "temperature", index = index, label = string.format("sensor-%04d", index),
    input = index, quality = "fresh", alarm = index == 600,
  }
end
local sensor_models = ViewModel.build(engine, sensors, translator, {}, "compute", nil,
  { sensor_table = true })
assert(#sensor_models.sensor_table.rows == 512)
assert(sensor_models.sensor_table.rows[1].sensor == "sensor-0600"
  and sensor_models.sensor_table.rows[1].alarm,
  "bounded sensor selection must retain alarms even when they occur after the first 512 channels")

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
assert(workload_models.workload_table.status_text == "showing 512 of 600",
  "a workload table capped at the model row limit reports what was dropped")
local filtered_workloads = ViewModel.build(engine, workloads, translator, {},
  "workloads", nil, { workload_table = true }, { workload_query = "scope-600" })
assert(#filtered_workloads.workload_table.rows == 1
  and filtered_workloads.workload_table.ids[1] == "/scope/600",
  "workload search scans the complete tree before the 512-row display cap")
workloads.workloads.workloads[600].cpu.utilization_percent = 80
local hot_workload = ViewModel.build(engine, workloads, translator, {},
  "workloads", nil, { workload_table = true },
  { workload_query = "cpu>70 scope-600" })
assert(#hot_workload.workload_table.rows == 1
  and hot_workload.workload_table.ids[1] == "/scope/600",
  "numeric workload conditions apply before the display cap")

local hidden_models = ViewModel.build(engine, network, translator, {}, "network", nil,
  { network_summary = true })
assert(#hidden_models.connection_table.rows == 0,
  "responsive-hidden high-cardinality tables must not be materialized")

local hardware = snapshot()
hardware.cpu_info = { topology = { quality = "fresh", logical_cpus = {} } }
for cpu = 0, 300 do
  hardware.cpu_info.topology.logical_cpus[#hardware.cpu_info.topology.logical_cpus + 1] = {
    id = cpu, package_id = 0, package_id_known = true,
    core_id = cpu, core_id_known = true, core_key = "0:" .. cpu,
  }
end
local Hardware = require("wtop.model.hardware")
local late_position
for index, node in ipairs(Hardware.build(hardware).nodes) do
  if node.id == "cpu:99" then late_position = index end
end
assert(late_position and late_position > 512, "fixture target is beyond the normal table cap")
local hardware_models = ViewModel.build(engine, hardware, translator, {}, "system", nil,
  { system_devices = true }, { system_query = "id:cpu:99" })
assert(#hardware_models.system_devices.rows == 3
  and hardware_models.system_devices.ids[3] == "cpu:99"
  and hardware_models.system_devices.selected == 3,
  "hardware search finds a late device with its package and core before applying the cap")

return true
