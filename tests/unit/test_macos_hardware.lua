local Hardware = require("wtop.model.hardware")
local Export = require("wtop.export")
local JSON = require("wtop.format.json")
local TUI = require("wtop.tui")
local i18n = assert(require("wtop.i18n").new({ locale = "en-US" }))

local controller = { address = "ioreg:1001", device_name = "Controller",
    device_id = 0, revision = 0, _registry_entry_id = "ioreg:9001" }
local hub = { id = "00000000", product = "Hub", _registry_entry_id = "ioreg:9002",
    _registry_parent_id = "ioreg:9001", _registry_parent_bus = "pci" }
local child = { id = "ioreg:1003", product = "Device", _registry_entry_id = "ioreg:9003",
    _registry_parent_id = "ioreg:9002", _registry_parent_bus = "usb" }
local state = { inventory = { pci = { devices = { controller } },
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
assert(not text:find("_registry", 1, true) and not text:find("9001", 1, true))

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

-- Malformed cycles are broken by the common graph, without editing a sample.
hub._registry_parent_id, hub._registry_parent_bus = "ioreg:9003", "usb"
graph = Hardware.build(state)
assert(graph.partial and hub._registry_parent_id == "ioreg:9003")
print("ok: IOKit identities, zero fields, current ancestors, ambiguity, navigation and private exports")
return true
