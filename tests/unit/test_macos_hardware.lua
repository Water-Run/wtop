local Hardware = require("wtop.model.hardware")
local Export = require("wtop.export")
local JSON = require("wtop.format.json")
local TUI = require("wtop.tui")
local i18n = assert(require("wtop.i18n").new({ locale = "en-US" }))

-- Mach logical slots are exact identities, even when physical containment and
-- Apple performance-level membership are not exposed by the OS.
local mach_state = {
    cpu = { counter_bits = 32, counter_source = "mach:HOST_CPU_LOAD_INFO",
        _source_epoch = "private-epoch", cores = {
            { id = 8, name = "cpu8", online = true, identity_quality = "fresh",
                source = "mach:PROCESSOR_CPU_LOAD_INFO", _source_instance = "private-instance",
                raw = { user = 1 }, utilization = 25, quality = "fresh" },
        } },
    cpu_info = { topology = { threads = 2, online_threads = 1, quality = "partial",
        identity_quality = "fresh", source = "mach:PROCESSOR_BASIC_INFO",
        present_cpu_list = { 2, 8 }, online_cpu_list = { 8 }, logical_cpus = {
            { id = 2, online = false, online_known = true, package_id_known = false,
                core_id_known = false, identity_quality = "fresh", source = "mach:PROCESSOR_BASIC_INFO" },
            { id = 8, online = true, online_known = true, package_id_known = false,
                core_id_known = false, identity_quality = "fresh", is_main = true,
                mach_cpu_type = 16777228, mach_cpu_subtype = 2, source = "mach:PROCESSOR_BASIC_INFO" },
        } } },
}
local mach_graph = Hardware.build(mach_state)
assert(mach_graph.by_id["cpu:2"] and mach_graph.by_id["cpu:8"])
assert(mach_graph.by_id["cpu:8"].parent_id == nil and not mach_graph.by_id["package:0"])
local mach_detail = table.concat(TUI.hardware_detail_lines(mach_state, "cpu:8", i18n), "\n")
assert(mach_detail:find("mach:PROCESSOR_BASIC_INFO", 1, true))
local mach_export = Export.snapshot(mach_state)
assert(mach_export.cpu.counter_bits == 32 and mach_export.cpu.counter_source == "mach:HOST_CPU_LOAD_INFO")
assert(mach_export.cpu.cores[1].id == 8 and mach_export.cpu.cores[1].online)
assert(mach_export.cpu_info.topology.identity_quality == "fresh")
assert(mach_export.cpu_info.topology.logical_cpus[2].is_main
    and mach_export.cpu_info.topology.logical_cpus[2].mach_cpu_type == 16777228)
local mach_json = JSON.encode(mach_export)
assert(not mach_json:find("private-", 1, true) and not mach_json:find('"raw"', 1, true))

local controller = { address = "ioreg:1001", device_name = "Controller",
    device_id = 0, revision = 0, _registry_entry_id = "ioreg:9001" }
local hub = { id = "00000000", product = "Hub", _registry_entry_id = "ioreg:9002",
    _registry_parent_id = "ioreg:9001", _registry_parent_bus = "pci" }
local child = { id = "ioreg:1003", product = "Device", _registry_entry_id = "ioreg:9003",
    _registry_parent_id = "ioreg:9002", _registry_parent_bus = "usb" }
-- A public timestamp may contain the same digits as a private registry ID.
local state = { timestamp_ns = 19001000000, inventory = { pci = { devices = { controller } },
    usb = { devices = { child, hub } } } }
local graph = Hardware.build(state)
assert(not graph.partial and graph.by_id["usb:ioreg:1003"].parent_id == "usb:00000000")
assert(graph.by_id["usb:00000000"].parent_id == "pci:ioreg:1001")
local detail = table.concat(TUI.hardware_detail_lines(state, "usb:ioreg:1003", i18n), "\n")
assert(detail:find("Parent device: 00000000", 1, true) and detail:find("p parent", 1, true))
local exported = Export.snapshot(state)
assert(exported.inventory.pci.devices[1].device_id == 0
    and exported.inventory.pci.devices[1].revision == 0)
local text = JSON.encode(exported)
assert(not text:find("_registry", 1, true))
for _, private_id in ipairs({ "ioreg:9001", "ioreg:9002", "ioreg:9003" }) do
    assert(not text:find(private_id, 1, true), "private registry identity exported")
end

state.quality = { inventory = { status = "ok", quality = "stale" } }
graph = Hardware.build(state)
assert(graph.partial and graph.by_id["usb:ioreg:1003"].parent_id == nil
    and graph.by_id["usb:00000000"].parent_id == nil)
state.quality = nil
state.inventory.pci.devices[2] = { address = "02:00.0", _registry_entry_id = "ioreg:9001" }
assert(Hardware.build(state).by_id["usb:00000000"].parent_id == nil)
state.inventory.pci.devices[2] = nil
hub._registry_parent_bus = "usb"
assert(Hardware.build(state).by_id["usb:00000000"].parent_id == nil)
hub._registry_parent_bus = "pci"
hub._registry_parent_id = "ioreg:9999"
assert(Hardware.build(state).by_id["usb:00000000"].parent_id == nil)
hub._registry_parent_id = "ioreg:9001"
state.inventory.usb.devices[3] = { id = child.id, _registry_entry_id = child._registry_entry_id,
    _registry_parent_id = child._registry_parent_id, _registry_parent_bus = "usb" }
assert(Hardware.build(state).by_id["usb:ioreg:1003"].parent_id == nil)
state.inventory.usb.devices[3] = nil
hub._registry_parent_id = "ioreg:0"
assert(Hardware.build(state).partial and Hardware.build(state).by_id["usb:00000000"].parent_id == nil)
hub._registry_parent_id = "ioreg:9001"

-- A Windows PnP string cannot accidentally satisfy the IOKit namespace.
controller._registry_entry_id = nil
controller._pnp_instance_id = "ioreg:9001"
assert(Hardware.build(state).by_id["usb:00000000"].parent_id == nil)
controller._registry_entry_id = "ioreg:9001"

-- The same instance references can be used by resource collectors, with both
-- samples required to be current. Their private identities stay out of JSON.
state.disks = { devices = { { name = "disk0", id = "disk0", stable_id = "ioreg:1000",
    _registry_parent_id = "ioreg:9003", _registry_parent_bus = "usb" } } }
assert(Hardware.build(state).by_id["block:ioreg:1000"].parent_id == "usb:ioreg:1003")
state.quality = { disks = { status = "ok", quality = "stale" } }
assert(Hardware.build(state).by_id["block:ioreg:1000"].parent_id == nil)
state.quality = nil

state.network = { interfaces = { { id = "en0", name = "en0", ifindex = 7,
    _registry_entry_id = "ioreg:9900", _registry_parent_id = "ioreg:9001", _registry_parent_bus = "pci",
    counter_bits = 64, counter_source = "IFMIB_IFDATA", counter_quality = "fresh" } } }
assert(Hardware.build(state).by_id["net:en0"].parent_id == "pci:ioreg:1001")
local net_export = Export.snapshot(state).network.interfaces[1]
assert(net_export.counter_bits == 64 and net_export.counter_source == "IFMIB_IFDATA")
assert(not JSON.encode(Export.snapshot(state)):find("_registry", 1, true))
state.quality = { network = { status = "ok", quality = "stale" } }
assert(Hardware.build(state).by_id["net:en0"].parent_id == nil)
state.quality = nil

local disk = state.disks.devices[1]
disk.source, disk.busy_percent, disk.busy_quality = "IOKit", 25, "estimated"
local disk_export = Export.snapshot(state).disks.devices[1]
assert(disk_export.source == "IOKit" and disk_export.busy_percent == 25
    and disk_export.busy_quality == "estimated")
assert(not JSON.encode(Export.snapshot(state)):find("_registry", 1, true))
local ViewModel = require("wtop.view_model")
local function busy_text()
    local model = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "storage")
    return model.disk_table.rows[1].busy
end
assert(busy_text():sub(1, 1) == "~", "summed request time is visibly an estimate")
disk.busy_quality = nil
assert(busy_text():sub(1, 1) ~= "~", "an exact idle-time reading has no estimate prefix")
disk.busy_percent, disk.busy_quality = nil, "estimated"
assert(busy_text() == "—", "an absent busy reading does not get an estimate prefix")

-- GPU ancestry uses the current instance namespace, including domainless PCI.
do
  local gpu = { id = "ioreg:9901", card = "ioreg:9901", model_name = "Fixture GPU",
    _registry_entry_id = "ioreg:9901", _registry_parent_id = "ioreg:9001",
    _registry_parent_bus = "pci", identity_quality = "fresh", metrics = {
      frequency_current_hz = 500000000, frequency_source_kind = "ioreport:GPUPH" },
    quality = { frequency = "estimated" } }
  state.gpus = { devices = { gpu } }
  local function owners() return Hardware.build(state).by_id["pci:ioreg:1001"].gpu_ids end
  assert(#owners() == 1 and owners()[1] == gpu.id)
  assert(table.concat(TUI.hardware_detail_lines(state, "pci:ioreg:1001", i18n), "\n")
    :find(gpu.id, 1, true), "hardware details expose the resolved GPU instance")
  local encoded = JSON.encode(Export.snapshot(state))
  assert(not encoded:find("_registry", 1, true))
  assert(Export.snapshot(state).inventory.topology.nodes)
  local agent = Export.agent(state, {})
  assert(agent.top.gpus[1].metrics.frequency_source_kind == "ioreport:GPUPH"
    and agent.top.gpus[1].quality.frequency == "estimated",
    "agent frequency includes its provenance and estimated quality")
  local model = ViewModel.build({ history_values = function() return {} end }, state, i18n, {}, "gpu")
  assert(model.gpu_table.rows[1].frequency:sub(1, 1) == "~", "residency mean is visibly estimated")
  state.quality = { gpus = { status = "ok", quality = "stale" } }
  assert(#owners() == 0)
  state.quality = { inventory = { status = "ok", quality = "stale" } }
  assert(#owners() == 0)
  state.quality = nil
  gpu._registry_parent_bus = "usb"; assert(#owners() == 0); gpu._registry_parent_bus = "pci"
  gpu._registry_parent_id = "ioreg:0"; gpu.pci_bdf = "02:00.0"
  state.inventory.pci.devices[2] = { address = "02:00.0" }
  graph = Hardware.build(state)
  assert(#owners() == 0 and #graph.by_id["pci:02:00.0"].gpu_ids == 0,
    "an invalid registry edge cannot fall back to a display BDF")
  gpu._registry_parent_id = nil
  assert(#Hardware.build(state).by_id["pci:02:00.0"].gpu_ids == 0,
    "an integrated GPU without a bus ancestor does not invent a PCI owner")
  gpu._registry_parent_id = "ioreg:9001"
  state.inventory.pci.devices[2]._registry_entry_id = "ioreg:9001"
  assert(#owners() == 0)
  state.inventory.pci.devices[2] = nil
  gpu.identity_quality = "partial"; assert(#owners() == 0); gpu.identity_quality = "fresh"
  state.gpus.devices[2] = gpu; assert(#owners() == 0); state.gpus.devices[2] = nil
  state.gpus.devices[2] = { id = "another", _registry_entry_id = "ioreg:9901",
    _registry_parent_id = "ioreg:9001", _registry_parent_bus = "pci", identity_quality = "fresh" }
  assert(#owners() == 0, "two public names cannot make a duplicated source instance unique")
  state.gpus = nil
end

-- Malformed cycles are broken by the common graph, without editing a sample.
hub._registry_parent_id, hub._registry_parent_bus = "ioreg:9003", "usb"
graph = Hardware.build(state)
assert(graph.partial and hub._registry_parent_id == "ioreg:9003")
print("ok: IOKit identities, zero fields, current ancestors, ambiguity, navigation and private exports")
return true
