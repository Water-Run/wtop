-- The device inventory collector enumerates PCI and USB devices with names
-- from the local pci.ids database, bounded, with absent sources reporting
-- unavailable instead of an empty success.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local FS = require("wtop.linux.fs")
local Inventory = require("wtop.collectors.inventory")
local Parsers = require("wtop.linux.parsers")
local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")
local Hardware = require("wtop.model.hardware")
local Export = require("wtop.export")
local TUI = require("wtop.tui")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "values differ",
      tostring(expected), tostring(actual)), 2)
  end
end

local PCI_IDS = [[
1002  Advanced Micro Devices, Inc.
\tabcd  Navi 31 [Radeon Pro W7900]
8086  Intel Corporation
\t4680  Alder Lake-S GT1
]]

local function fixture(extra)
  extra = extra or {}
  local files = {
    ["/ids/pci.ids"] = PCI_IDS,
    ["/sys/bus/pci/devices/0000:00:02.0/vendor"] = "0x8086\n",
    ["/sys/bus/pci/devices/0000:00:02.0/device"] = "0x4680\n",
    ["/sys/bus/pci/devices/0000:00:02.0/class"] = "0x030000\n",
    ["/sys/bus/pci/devices/0000:00:02.0/revision"] = "0x04\n",
    ["/sys/bus/pci/devices/0000:01:00.0/vendor"] = "0x1002\n",
    ["/sys/bus/pci/devices/0000:01:00.0/device"] = "0xabcd\n",
    ["/sys/bus/pci/devices/0000:01:00.0/class"] = "0x030200\n",
    ["/sys/bus/usb/devices/1-2/idVendor"] = "0x8087\n",
    ["/sys/bus/usb/devices/1-2/idProduct"] = "0x0026\n",
    ["/sys/bus/usb/devices/1-2/busnum"] = "1\n",
    ["/sys/bus/usb/devices/1-2/devnum"] = "3\n",
    ["/sys/bus/usb/devices/1-2/manufacturer"] = "Intel Corp.\n",
    ["/sys/bus/usb/devices/1-2/product"] = "Hub\n",
  }
  for path, content in pairs(extra or {}) do files[path] = content end
  local directories = {
    ["/sys/bus/pci/devices"] = { "0000:00:02.0", "0000:01:00.0" },
    ["/sys/bus/usb/devices"] = { "1-2" },
  }
  -- A list of a given length replaces the default one rather than extending it,
  -- so the counts below are the counts the collector sees.  `MAX_PCI_DEVICES` is
  -- 256 and `MAX_USB_DEVICES` is 128, so 257 and 129 are the shortest lists that
  -- truncate.  These two numbers are the one thing here coupled to the
  -- implementation, and the coupling is deliberate: if a cap moves, the fixture
  -- stops truncating and the assertions below fail loudly instead of quietly
  -- reporting a `fresh` result that says nothing about truncation.
  if extra.pci_count then
    local entries = {}
    for index = 1, extra.pci_count do
      local address = string.format("0000:%02x:00.0", 0x0f + index)
      entries[#entries + 1] = address
      files["/sys/bus/pci/devices/" .. address .. "/vendor"] = "0x8086\n"
      files["/sys/bus/pci/devices/" .. address .. "/device"] = "0x4680\n"
      files["/sys/bus/pci/devices/" .. address .. "/class"] = "0x030000\n"
      files["/sys/bus/pci/devices/" .. address .. "/revision"] = "0x04\n"
    end
    directories["/sys/bus/pci/devices"] = entries
  end
  if extra.usb_count then
    local entries = {}
    for index = 1, extra.usb_count do
      local name = string.format("2-%d", index)
      entries[#entries + 1] = name
      files["/sys/bus/usb/devices/" .. name .. "/idVendor"] = "0x8087\n"
      files["/sys/bus/usb/devices/" .. name .. "/idProduct"] = "0x0026\n"
      files["/sys/bus/usb/devices/" .. name .. "/busnum"] = "1\n"
      files["/sys/bus/usb/devices/" .. name .. "/devnum"] = tostring(index) .. "\n"
    end
    directories["/sys/bus/usb/devices"] = entries
  end
  if files["/__no_pci"] ~= nil then directories["/sys/bus/pci/devices"] = nil end
  if files["/__no_usb"] ~= nil then directories["/sys/bus/usb/devices"] = nil end
  if extra.pci_entries then directories["/sys/bus/pci/devices"] = extra.pci_entries end
  if extra.usb_entries then directories["/sys/bus/usb/devices"] = extra.usb_entries end
  for path, entries in pairs(extra.directories or {}) do directories[path] = entries end
  local fs = FS.new({
    root = "/",
    read_file = function(path)
      assert(not path:match("/serial$"), "inventory must not read device serial numbers")
      local content = files[path]
      if content == nil then
        return nil, { kind = "missing", message = "no such file" }
      end
      if type(content) == "table" and content.kind then return nil, content end
      return content
    end,
    list_dir = function(path)
      local entries = directories[path]
      if not entries then
        return nil, { kind = "missing", message = "no such directory" }
      end
      if entries.kind then return nil, entries end
      return entries, nil, extra.truncated_dirs and extra.truncated_dirs[path] == true
    end,
    -- The key is `read_link`.  This said `readlink`, which is not a name
    -- `FS.new` knows: the key was accepted, kept in the options table, and never
    -- read, so the real readlink implementation was substituted and the double
    -- was not the hermetic thing it looked like.  `path_type` said `"file"`,
    -- which is also not a word the product produces -- `native.path_type`
    -- answers `regular` for S_ISREG.
    read_link = function(path)
      local target = extra.links and extra.links[path]
      if target then return target end
      return nil, { kind = "missing" }
    end,
    path_type = function() return "regular" end,
  })
  return Inventory.new({
    fs = fs,
    pci_names = { names = function(_, vendor_id, device_id)
      if vendor_id == 0x8086 then
        return "Intel Corporation", device_id == 0x4680 and "Alder Lake-S GT1" or nil
      end
      if vendor_id == 0x1002 then
        return "Advanced Micro Devices, Inc.", "Navi 31"
      end
      return nil, nil
    end },
  })
end

local collector = fixture()
local capability = collector:probe({})
equal(capability.state, "available", "PCI devices present make the source available")

local result = collector:sample({})
equal(result.status, "ok", "sample succeeds")
equal(result.quality, "fresh", "a complete inventory is fresh")
equal(result.data.pci.total, 2, "both PCI devices counted")
equal(#result.data.pci.devices, 2, "both PCI devices emitted")
local intel = result.data.pci.devices[1]
equal(intel.address, "0000:00:02.0", "PCI devices sort by address")
equal(intel.vendor_name, "Intel Corporation", "pci.ids supplies the vendor name")
equal(intel.device_name, "Alder Lake-S GT1", "pci.ids supplies the device name")
equal(intel.class_id, 0x030000, "class id parsed as a number")
equal(intel.aer, nil, "a PCI function without AER files has no invented counters")
equal(result.data.usb.total, 1, "USB devices counted")
equal(result.data.usb.devices[1].product, "Hub", "USB product string read")

-- A device without readable identity files is skipped, not emitted half-made.
local partial = fixture({
  ["/sys/bus/pci/devices/0000:03:00.0/class"] = "0x010601\n",
})
directories = nil
local partial_result = partial:sample({})
equal(partial_result.data.pci.total, 2, "unreadable PCI entries do not appear")

local absent = fixture({ ["/__no_pci"] = true, ["/__no_usb"] = true })
local absent_probe = absent:probe({})
equal(absent_probe.state, "unavailable", "no sources report unavailable")
local absent_result = absent:sample({})
equal(absent_result.status, "unavailable", "no devices report unavailable")
equal(absent_result.reason, "no_device_inventory", "absence carries a reason")

local usb_only = fixture({ ["/__no_pci"] = true })
equal(usb_only:probe({}).state, "available", "USB alone keeps the source available")
local usb_only_result = usb_only:sample({})
equal(usb_only_result.status, "ok", "USB alone samples successfully")
equal(usb_only_result.data.pci.total, nil, "an unavailable PCI bus has an unknown total")
equal(usb_only_result.data.pci.status, "unavailable", "PCI keeps its own source status")
assert(not usb_only_result.data.pci.total_known)

-- The System-page table model renders the merged, bounded view.
local translator = assert(I18n.new({ locale = "en-US" }))
local engine = { history_values = function() return {} end }
local snapshot = { inventory = usb_only_result.data, cpu = {}, memory = {},
  pressure = {}, disks = {}, network = {}, processes = {}, cpu_frequency = {},
  mounts = {}, workloads = {}, connections = {}, quality = {}, sensors = {} }
local models = ViewModel.build(engine, snapshot, translator, {}, "system")
equal(models.system_devices.rows[1].bus, "USB", "USB rows render in the device table")
equal(models.system_devices.rows[1].device, "Intel Corp. Hub",
  "manufacturer and product join into the device label")
local hidden = ViewModel.build(engine, snapshot, translator, {}, "system",
  nil, nil, { system_devices = true })
equal(hidden.system_devices.rows[1].id, "1:3", "USB identity keeps bus and number")

-- Truncation is a published degradation, not a silent shortening.  The lists are
-- bounded, so a host with more devices than the cap has always published fewer
-- rows than it counted -- what it did not publish was a word saying so, and the
-- one word it did publish on the result was `fresh` on both paths.  `truncated`
-- is the only result quality in the whole tree used by this collector, and
-- `device_enumeration_truncated` is its reason.
local Snapshot = require("wtop.model.snapshot")

local function truncated_result(extra)
  return fixture(extra):sample({})
end

local over_pci = truncated_result({ ["/__no_usb"] = true, pci_count = 257 })
equal(over_pci.status, "ok", "a capped enumeration is still a successful read")
equal(over_pci.quality, "truncated", "a PCI list past the cap says so")
equal(over_pci.reason, "device_enumeration_truncated", "and names the cause")
equal(over_pci.data.pci.total, 257, "the total counts what the directory held")
equal(#over_pci.data.pci.devices, 256, "the device list stops at the cap")
equal(over_pci.data.pci.truncated, true, "the per-resource flag agrees")
equal(over_pci.data.usb.total, nil, "an unreadable bus has an unknown device count")
equal(over_pci.data.usb.status, "unavailable", "the missing USB source keeps its status")
assert(not over_pci.data.usb.total_known and not over_pci.data.usb.interface_total_known)

local over_usb = truncated_result({ ["/__no_pci"] = true, usb_count = 129 })
equal(over_usb.quality, "truncated", "a USB list past the cap says so")
equal(over_usb.reason, "device_enumeration_truncated",
  "a USB cap reports the same code as a PCI cap: one cause, one code")
equal(over_usb.data.usb.total, 129, "the USB total counts the directory")
equal(#over_usb.data.usb.devices, 128, "the USB list stops at the cap")

-- One entry below the cap is not truncated, and carries no reason: the reason
-- belongs to the condition, not to the collector.
local under_cap = truncated_result({ pci_count = 256, usb_count = 128 })
equal(under_cap.quality, "fresh", "a list exactly at the cap is complete")
equal(under_cap.reason, nil, "a complete inventory has no reason to give")
equal(#under_cap.data.pci.devices, 256, "every device at the cap is emitted")

-- USB interfaces have their own drivers and class descriptors.  A network
-- child or sensor under an inventoried interface belongs to that interface,
-- while the parent device remains a distinct node.
do
  local usb_root = "/sys/bus/usb/devices"
  local first = usb_root .. "/1-2:1.0"
  local second = usb_root .. "/1-2:1.1"
  local interface_inventory = fixture({
    usb_entries = { "1-2", "1-2:1.0", "1-2:1.1" },
    [first .. "/bInterfaceNumber"] = "00\n",
    [first .. "/bAlternateSetting"] = " 0\n",
    [first .. "/bNumEndpoints"] = "03\n",
    [first .. "/bInterfaceClass"] = "e0\n",
    [first .. "/bInterfaceSubClass"] = "01\n",
    [first .. "/bInterfaceProtocol"] = "01\n",
    [first .. "/interface"] = "Bluetooth radio\n",
    [second .. "/bInterfaceNumber"] = "01\n",
    [second .. "/bInterfaceClass"] = "0a\n",
    links = {
      [first] = "../../../devices/pci0000:00/usb1/1-2/1-2:1.0",
      [second] = "../../../devices/pci0000:00/usb1/1-2/1-2:1.1",
      [first .. "/driver"] = "../../../../bus/usb/drivers/btusb",
    },
  }):sample({})
  equal(interface_inventory.quality, "fresh", "USB interface metadata is part of a fresh inventory")
  equal(interface_inventory.data.usb.total, 1, "interfaces do not inflate device count")
  equal(interface_inventory.data.usb.interface_total, 2, "interfaces are counted separately")
  local interface = interface_inventory.data.usb.interfaces[1]
  equal(interface.id, "1-2:1.0", "interface identity follows the kernel name")
  equal(interface.parent_id, "1-2", "sysfs ancestry names the physical parent")
  equal(interface.class_id, 0xe0, "interface class is hexadecimal")
  equal(interface.endpoint_count, 3, "endpoint count comes from the descriptor")
  equal(interface.driver, "btusb", "driver is the bound interface driver")
  local state = { inventory = interface_inventory.data,
    network = { interfaces = { { id = 7, name = "usbnet", device_path =
      "/sys/devices/pci0000:00/usb1/1-2/1-2:1.0/net/usbnet" } } },
    sensors = { devices = { { id = "thermal@usb", name = "fixture",
      device_target = "/sys/devices/pci0000:00/usb1/1-2/1-2:1.0",
      channels = { { id = "temperature:1", type = "temperature", input = 42 } } } } },
    cpu = {}, memory = {}, pressure = {}, disks = {}, processes = {},
    cpu_frequency = {}, mounts = {}, workloads = {}, connections = {}, quality = {} }
  local graph = Hardware.build(state)
  local node = graph.by_id["usb-interface:1-2:1.0"]
  assert(node and node.kind == "usb_interface" and node.parent_id == "usb:1-2")
  equal(graph.by_id["net:7"].parent_id, node.id,
    "USB network interface belongs to its bound function")
  equal(#node.sensor_ids, 1, "an interface sensor stays on that interface")
  equal(#graph.by_id["usb:1-2"].sensor_ids, 0,
    "interface sensor does not become a whole-device reading")
  local detail = table.concat(TUI.hardware_detail_lines(state, node.id, translator), "\n")
  assert(detail:find("Bluetooth radio", 1, true) and detail:find("btusb", 1, true)
    and detail:find("Interface number: 0", 1, true)
    and detail:find("Class: e0", 1, true))
  local table_model = ViewModel.build(engine, state, translator, {}, "system").system_devices
  local found
  for _, row in ipairs(table_model.rows) do
    if row.id == "1-2:1.0" then found = row end
  end
  assert(found and found.class == "e0", "the system table shows the interface class")
  local exported = Export.snapshot(state)
  equal(exported.inventory.usb.interfaces[1].driver, "btusb",
    "the interface driver survives JSON export")
  local exported_by_id = {}
  for _, item in ipairs(exported.inventory.topology.nodes) do exported_by_id[item.id] = item end
  equal(exported_by_id[node.id].parent_id, "usb:1-2",
    "JSON topology retains the interface's physical parent")
  equal(exported_by_id["net:7"].parent_id, node.id,
    "JSON topology retains the network function relationship")
end

-- A short read and a capped read are different facts and must not share a word.
equal(over_pci.reason ~= absent_result.reason, true,
  "a truncated list and an absent bus both reporting one reason would make a "
    .. "short read look like a full one")
equal(over_pci.quality ~= absent_result.quality, true,
  "truncation and absence publish different qualities")

-- The reason has to survive the merge that publishes it: `Snapshot.merge` is
-- where a result becomes a snapshot slot, and a quality vocabulary is closed
-- there, so a word the merge does not publish would be rewritten to `error`
-- beside a reason naming truncation -- two statements, one of them false.
local merged = Snapshot.merge(Snapshot.new(1, 10), { inventory = over_pci }, 2, 20)
local state = merged.quality.inventory
equal(state.quality, "truncated", "merge publishes the truncation quality")
equal(state.reason, "device_enumeration_truncated", "merge keeps the reason")
equal(state.status, "ok", "a capped read is not turned into a failure by merge")
equal(merged.inventory.pci.total, 257, "the data itself is carried through")
local merged_under = Snapshot.merge(Snapshot.new(1, 10), { inventory = under_cap }, 2, 20)
equal(merged_under.quality.inventory.quality, "fresh",
  "a complete inventory stays fresh through merge")

-- And the documentation has to say what the tests just measured, or the two
-- disagree quietly.  `docs/MONITORING.md` used to state that `truncated` was not
-- a top-level Engine quality value, which is true of the rows and false of this
-- result: the same word is both a row marker and this collector's one result
-- quality, and the file now has to distinguish them rather than pick one.
local monitoring = assert(io.open("docs/MONITORING.md")):read("*a")
assert(monitoring:find("`truncated`", 1, true) ~= nil,
  "docs/MONITORING.md no longer mentions `truncated` at all")
assert(monitoring:find("device_enumeration_truncated", 1, true) ~= nil,
  "docs/MONITORING.md does not name the reason the device inventory publishes "
    .. "when an enumeration stops at its cap, so the word a user would see is "
    .. "documented nowhere")
assert(monitoring:find("设备清单", 1, true) ~= nil,
  "docs/MONITORING.md no longer names the collector that publishes it")

-- Shared hierarchy: a PCI bridge, an endpoint and USB descendants. Metadata
-- is optional; missing files must leave values absent, especially NUMA -1.
local bridge, endpoint = "0000:00:01.0", "0000:01:00.0"
local pci_base, usb_base = "/sys/bus/pci/devices/", "/sys/bus/usb/devices/"
local extra = {
  pci_entries = { endpoint, bridge }, usb_entries = { "1-2.3", "usb1", "1-2" },
  links = {
    [pci_base .. bridge] = "../../../devices/pci0000:00/" .. bridge,
    [pci_base .. endpoint] = "../../../devices/pci0000:00/" .. bridge .. "/" .. endpoint,
    [pci_base .. endpoint .. "/driver"] = "../../../../bus/pci/drivers/amdgpu",
    [usb_base .. "usb1"] = "../../../devices/pci0000:00/" .. bridge .. "/usb1",
    [usb_base .. "1-2"] = "../../../devices/pci0000:00/" .. bridge .. "/usb1/1-2",
    [usb_base .. "1-2.3"] = "../../../devices/pci0000:00/" .. bridge .. "/usb1/1-2/1-2.3",
  },
  [pci_base .. bridge .. "/vendor"] = "0x8086\n",
  [pci_base .. bridge .. "/device"] = "0x1234\n",
  [pci_base .. bridge .. "/class"] = "0x060400\n",
  [pci_base .. bridge .. "/numa_node"] = "-1\n",
  [pci_base .. endpoint .. "/numa_node"] = "0\n",
  [pci_base .. endpoint .. "/current_link_speed"] = "16.0 GT/s PCIe\n",
  [pci_base .. endpoint .. "/current_link_width"] = "8\n",
  [pci_base .. endpoint .. "/max_link_speed"] = "32.0 GT/s PCIe\n",
  [pci_base .. endpoint .. "/max_link_width"] = "16\n",
  [usb_base .. "1-2.3/speed"] = "12\n",
}
for _, name in ipairs({ "usb1", "1-2.3" }) do
  extra[usb_base .. name .. "/idVendor"] = "0x8087\n"
  extra[usb_base .. name .. "/idProduct"] = "0x0026\n"
  extra[usb_base .. name .. "/manufacturer"] = "Fixture\n"
  extra[usb_base .. name .. "/product"] = "Probe\n"
end
local hierarchy = fixture(extra):sample({}).data
local endpoint_record = hierarchy.pci.devices[2]
equal(endpoint_record.parent_address, bridge, "kernel path supplies PCI parent")
equal(endpoint_record.driver, "amdgpu", "driver symlink supplies its name")
equal(endpoint_record.numa_node, 0, "NUMA node zero is a real value")
equal(hierarchy.pci.devices[1].numa_node, nil, "NUMA -1 is not a reported node")
equal(endpoint_record.link_speed_gtps, 16, "negotiated speed retains its unit")
equal(endpoint_record.link_width, 8, "negotiated lane width")
equal(endpoint_record.max_link_speed_gtps, 32, "maximum speed is separate")

local aer_files = {}
for key, value in pairs(extra) do aer_files[key] = value end
aer_files[pci_base .. bridge .. "/aer_dev_correctable"] =
  "Receiver Error 2\nBad TLP 3\nTOTAL_ERR_COR 4\n"
aer_files[pci_base .. bridge .. "/aer_dev_nonfatal"] =
  "TOTAL_ERR_NONFATAL 0\n"
aer_files[pci_base .. bridge .. "/aer_dev_fatal"] = "TOTAL_ERR_FATAL 0\n"
aer_files[pci_base .. bridge .. "/aer_rootport_total_err_cor"] = "8\n"
aer_files[pci_base .. bridge .. "/aer_rootport_total_err_nonfatal"] = "1\n"
aer_files[pci_base .. bridge .. "/aer_rootport_total_err_fatal"] = "0\n"
aer_files[pci_base .. endpoint .. "/aer_dev_correctable"] =
  "RxErr 0\nTOTAL_ERR_COR 0\n"
aer_files[pci_base .. endpoint .. "/aer_dev_nonfatal"] =
  "CmpltTO 1\nTOTAL_ERR_NONFATAL 1\n"
aer_files[pci_base .. endpoint .. "/aer_dev_fatal"] = "TOTAL_ERR_FATAL 0\n"
local aer_inventory = fixture(aer_files):sample({}).data
local bridge_aer = aer_inventory.pci.devices[1].aer
equal(bridge_aer.status, "ok", "complete AER files keep local health status")
equal(bridge_aer.correctable.total, 4,
  "the kernel's total is kept even when category counts sum to five")
equal(#bridge_aer.correctable.categories, 2, "nonzero AER classes remain visible")
equal(bridge_aer.rootport.correctable, 8,
  "root-port subtree reports are kept separate from device reports")
equal(aer_inventory.pci.devices[2].aer.rootport, nil,
  "an endpoint is not given a root-port subtree counter")
local aer_snapshot = { inventory = aer_inventory, quality = {} }
local aer_json = Export.snapshot(aer_snapshot).inventory.pci.devices
equal(aer_json[1].aer.correctable.total, 4, "AER totals reach JSON")
equal(aer_json[1].aer.rootport.correctable, 8,
  "root-port subtree totals reach JSON without being summed")
local aer_detail = table.concat(TUI.hardware_detail_lines(aer_snapshot,
  "pci:" .. bridge, translator), "\n")
assert(aer_detail:find("PCIe AER reports since boot", 1, true)
    and aer_detail:find("Receiver Error", 1, true)
    and aer_detail:find("Root-port subtree reports", 1, true)
    and aer_detail:find("not necessarily the failing endpoint", 1, true),
  "PCI detail shows totals, active error class and reporting-link semantics")
local damaged_files = {}
for key, value in pairs(aer_files) do damaged_files[key] = value end
damaged_files[pci_base .. endpoint .. "/aer_dev_fatal"] = nil
local damaged = fixture(damaged_files):sample({}).data.pci.devices[2].aer
equal(damaged.status, "partial", "one absent AER file is local partial data")
equal(damaged.nonfatal.total, 1, "a readable sibling counter survives")
local denied_files = {}
for key, value in pairs(aer_files) do denied_files[key] = value end
denied_files[pci_base .. endpoint .. "/aer_dev_correctable"] =
  { kind = "denied", message = "permission denied" }
local denied_aer_result = fixture(denied_files):sample({})
equal(denied_aer_result.quality, "fresh",
  "one AER permission failure does not degrade the device inventory")
equal(denied_aer_result.data.pci.devices[2].aer.status, "denied",
  "the PCI detail keeps the AER-specific permission state")
local first_aer_sample = fixture(aer_files):sample({
  now_ns = function() return 1000000000 end,
})
equal(first_aer_sample.data.pci.devices[1].aer.correctable.change.quality,
  "gap", "one cumulative reading cannot claim new reports")
local later_files = {}
for key, value in pairs(aer_files) do later_files[key] = value end
later_files[pci_base .. bridge .. "/aer_dev_correctable"] =
  "Receiver Error 4\nBad TLP 4\nTOTAL_ERR_COR 7\n"
later_files[pci_base .. bridge .. "/aer_rootport_total_err_cor"] = "10\n"
later_files[pci_base .. endpoint .. "/aer_dev_nonfatal"] =
  "CmpltTO 0\nTOTAL_ERR_NONFATAL 0\n"
local later_aer_sample = fixture(later_files):sample({
  now_ns = function() return 31000000000 end,
}, first_aer_sample)
local later_bridge = later_aer_sample.data.pci.devices[1].aer
equal(later_bridge.interval_seconds, 30, "the change names its real scan interval")
equal(later_bridge.correctable.change.new_reports, 3,
  "device AER total changes by kernel message count, not by category sums")
equal(later_bridge.rootport.changes.correctable.new_reports, 2,
  "root-port subtree changes stay separate from device changes")
local later_endpoint = later_aer_sample.data.pci.devices[2].aer
equal(later_endpoint.nonfatal.change.quality, "reset",
  "a decreasing counter is a reset, not negative new errors")
equal(later_endpoint.nonfatal.change.new_reports, nil,
  "reset has no invented interval count")
local later_json = Export.snapshot({ inventory = later_aer_sample.data }).inventory.pci.devices
equal(later_json[1].aer.correctable.change.new_reports, 3,
  "device interval change reaches JSON")
equal(later_json[1].aer.rootport.changes.correctable.new_reports, 2,
  "root-port interval change reaches JSON independently")
local later_detail = table.concat(TUI.hardware_detail_lines(
  { inventory = later_aer_sample.data }, "pci:" .. bridge, translator), "\n")
assert(later_detail:find("Scan interval", 1, true)
    and later_detail:find("New since previous scan", 1, true),
  "PCI detail distinguishes cumulative reports from interval changes")
local replaced_files = {}
for key, value in pairs(later_files) do replaced_files[key] = value end
replaced_files[pci_base .. bridge .. "/device"] = "0x5678\n"
local replaced_aer = fixture(replaced_files):sample({
  now_ns = function() return 61000000000 end,
}, later_aer_sample).data.pci.devices[1].aer
equal(replaced_aer.correctable.change.quality, "gap",
  "a new PCI identity at the same address cannot inherit an AER delta")
equal(replaced_aer.interval_seconds, nil,
  "an identity mismatch has no comparable scan interval")
equal(Parsers.pci_aer_stats("RxErr 1\nTOTAL_ERR_COR 2\n", "TOTAL_ERR_COR").total,
  2, "AER classes need not sum to the message total")
assert(Parsers.pci_aer_stats("RxErr 1\n", "TOTAL_ERR_COR") == nil,
  "a missing total cannot be synthesized from classes")
assert(Parsers.pci_aer_stats("TOTAL_ERR_COR 18446744073709551615\n",
  "TOTAL_ERR_COR") == nil, "an overflowing counter is unavailable")

-- SR-IOV is a cross-reference between PCI functions, not a replacement for
-- their bridge-derived bus parents.  The PF advertises capacity and enabled
-- count; each VF's physfn link is the direct source of its PF address.
local vf1, vf2 = "0000:01:00.1", "0000:01:00.2"
local sriov_files = {
  pci_entries = { bridge, endpoint, vf1, vf2 },
  links = {
    [pci_base .. bridge] = "../../../devices/pci0000:00/" .. bridge,
    [pci_base .. endpoint] = "../../../devices/pci0000:00/" .. bridge .. "/" .. endpoint,
    [pci_base .. vf1] = "../../../devices/pci0000:00/" .. bridge .. "/" .. vf1,
    [pci_base .. vf2] = "../../../devices/pci0000:00/" .. bridge .. "/" .. vf2,
    [pci_base .. vf1 .. "/physfn"] = "../" .. endpoint,
    [pci_base .. vf2 .. "/physfn"] = "../" .. endpoint,
  },
  [pci_base .. bridge .. "/vendor"] = "0x8086\n",
  [pci_base .. bridge .. "/device"] = "0x1234\n",
  [pci_base .. endpoint .. "/sriov_totalvfs"] = "4\n",
  [pci_base .. endpoint .. "/sriov_numvfs"] = "2\n",
}
for _, vf in ipairs({ vf1, vf2 }) do
  sriov_files[pci_base .. vf .. "/vendor"] = "0x1002\n"
  sriov_files[pci_base .. vf .. "/device"] = "0xabce\n"
end
local sriov_data = fixture(sriov_files):sample({}).data
local sriov_pf = sriov_data.pci.devices[2]
local sriov_vf = sriov_data.pci.devices[3]
equal(sriov_pf.sriov.role, "pf", "capacity file identifies the physical function")
equal(sriov_pf.sriov.total_vfs, 4, "PF capacity is separate from enabled VFs")
equal(sriov_pf.sriov.enabled_vfs, 2, "PF enabled count comes from numvfs")
equal(sriov_vf.sriov.role, "vf", "physfn identifies a virtual function")
equal(sriov_vf.sriov.physical_function_address, endpoint,
  "VF carries the kernel's PF reference")
local sriov_snapshot = { inventory = sriov_data, quality = {} }
local sriov_graph = Hardware.build(sriov_snapshot)
local pf_node = sriov_graph.by_id["pci:" .. endpoint]
local vf_node = sriov_graph.by_id["pci:" .. vf1]
equal(vf_node.parent_id, "pci:" .. bridge,
  "a VF keeps its physical PCI bus parent rather than moving under its PF")
equal(vf_node.pf_id, pf_node.id, "VF resolves its independent PF reference")
equal(#pf_node.vf_ids, 2, "PF receives both visible VF references")
equal(pf_node.sriov_membership_complete, true,
  "enabled count agrees with the observed VF set")
local sriov_export = Export.snapshot(sriov_snapshot).inventory
equal(sriov_export.pci.devices[2].sriov.enabled_vfs, 2,
  "PF enablement reaches JSON")
equal(sriov_export.topology.nodes[3].pf_id, pf_node.id,
  "the VF-to-PF reference reaches shared topology JSON")
local sriov_pf_detail = table.concat(TUI.hardware_detail_lines(sriov_snapshot,
  pf_node.id, translator), "\n")
assert(sriov_pf_detail:find("VF capacity: 4", 1, true)
    and sriov_pf_detail:find("Enabled VFs: 2", 1, true)
    and sriov_pf_detail:find("pci:" .. vf1, 1, true),
  "PF detail shows capacity, active count and named VF references")
local sriov_vf_detail = table.concat(TUI.hardware_detail_lines(sriov_snapshot,
  vf_node.id, translator), "\n")
assert(sriov_vf_detail:find("Physical function: pci:" .. endpoint, 1, true)
    and sriov_vf_detail:find("Parent device", 1, true),
  "VF detail keeps PF reference distinct from the bus parent")

local incomplete_sriov = {}
for key, value in pairs(sriov_files) do incomplete_sriov[key] = value end
incomplete_sriov[pci_base .. endpoint .. "/sriov_numvfs"] = "3\n"
local incomplete_graph = Hardware.build({ inventory = fixture(incomplete_sriov):sample({}).data })
equal(incomplete_graph.by_id[pf_node.id].sriov_membership_complete, false,
  "an enabled VF missing from the inventory is not claimed as complete")
equal(incomplete_graph.partial, true, "the shared topology reports the missing relationship")
local unknown_sriov = {}
for key, value in pairs(sriov_files) do unknown_sriov[key] = value end
unknown_sriov[pci_base .. endpoint .. "/sriov_numvfs"] = nil
local unknown_data = fixture(unknown_sriov):sample({}).data
equal(unknown_data.pci.devices[2].sriov.status, "partial",
  "an unreadable enabled count stays distinct from zero")
local unknown_graph = Hardware.build({ inventory = unknown_data })
equal(unknown_graph.by_id[pf_node.id].sriov_membership_complete, false,
  "the topology cannot verify PF membership without an enabled count")
equal(unknown_graph.partial, true, "an unverifiable PF relationship marks topology partial")
local conflicting_sriov = {}
for key, value in pairs(sriov_files) do conflicting_sriov[key] = value end
local conflicting_links = {}
for key, value in pairs(sriov_files.links) do conflicting_links[key] = value end
conflicting_links[pci_base .. endpoint .. "/physfn"] = "../" .. bridge
conflicting_sriov.links = conflicting_links
local conflicting_data = fixture(conflicting_sriov):sample({}).data
equal(conflicting_data.pci.devices[2].sriov.role, "ambiguous",
  "a function with PF attributes and a physfn link is not silently classified")
equal(Hardware.build({ inventory = conflicting_data }).partial, true,
  "conflicting SR-IOV roles keep topology explicitly partial")

-- IOMMU groups are independent of the PCI bus parent and SR-IOV PF/VF links.
-- The kernel group directory may include devices outside the visible PCI list.
local iommu_files = {}
for key, value in pairs(sriov_files) do iommu_files[key] = value end
local iommu_links = {}
for key, value in pairs(sriov_files.links) do iommu_links[key] = value end
iommu_links[pci_base .. bridge .. "/iommu_group"] = "../../../../kernel/iommu_groups/0"
iommu_links[pci_base .. endpoint .. "/iommu_group"] = "../../../../kernel/iommu_groups/7"
iommu_links[pci_base .. vf1 .. "/iommu_group"] = "../../../../kernel/iommu_groups/7"
iommu_links[pci_base .. vf2 .. "/iommu_group"] = "../../../../kernel/iommu_groups/8"
iommu_files.links = iommu_links
local group0 = "/sys/kernel/iommu_groups/0/devices"
local group7 = "/sys/kernel/iommu_groups/7/devices"
local group8 = "/sys/kernel/iommu_groups/8/devices"
iommu_files.directories = {
  [group0] = { bridge },
  [group7] = { endpoint, vf1, "platform:example" },
  [group8] = { vf2 },
}
local iommu_data = fixture(iommu_files):sample({}).data
equal(iommu_data.pci.devices[1].iommu_group_id, 0,
  "IOMMU group zero is a valid kernel group ID")
equal(iommu_data.pci.devices[2].iommu_group_id, 7,
  "the PCI symlink supplies the group ID")
equal(iommu_data.pci.iommu_groups[2].members[3], "platform:example",
  "kernel membership is not limited to PCI functions")
local iommu_snapshot = { inventory = iommu_data, quality = {} }
local iommu_graph = Hardware.build(iommu_snapshot)
local group_pf = iommu_graph.by_id["pci:" .. endpoint]
local group_vf = iommu_graph.by_id["pci:" .. vf1]
equal(group_pf.parent_id, "pci:" .. bridge,
  "IOMMU membership does not replace physical bus ancestry")
equal(group_vf.pf_id, group_pf.id,
  "IOMMU membership does not replace the VF-to-PF reference")
equal(group_pf.iommu_peer_ids[1], group_vf.id,
  "visible PCI peers share a group")
equal(group_vf.iommu_peer_ids[1], group_pf.id,
  "group peer references are symmetric")
equal(group_pf.iommu_group_membership_confirmed, true,
  "the group directory confirms the PCI symlink")
equal(#iommu_graph.by_id["pci:" .. vf2].iommu_peer_ids, 0,
  "a separate group does not inherit another group's peers")
local iommu_export = Export.snapshot(iommu_snapshot).inventory
equal(iommu_export.pci.devices[2].iommu_group_id, 7,
  "the device's group ID reaches JSON")
equal(iommu_export.pci.iommu_groups[2].members[3], "platform:example",
  "the kernel's group member list reaches JSON")
equal(iommu_export.topology.nodes[3].iommu_peer_ids[1], group_pf.id,
  "PCI peer references reach topology JSON")
local iommu_detail = table.concat(TUI.hardware_detail_lines(iommu_snapshot,
  group_pf.id, translator), "\n")
assert(iommu_detail:find("IOMMU group 7", 1, true)
    and iommu_detail:find("Group members: 3", 1, true)
    and iommu_detail:find("platform:example", 1, true)
    and iommu_detail:find(group_vf.id, 1, true),
  "device detail shows group identity, full member names and visible PCI peers")

local missing_group = {}
for key, value in pairs(iommu_files) do missing_group[key] = value end
missing_group.directories = { [group0] = { bridge }, [group7] = { endpoint, vf1 } }
local missing_data = fixture(missing_group):sample({}).data
equal(missing_data.pci.iommu_groups[3].status, "unavailable",
  "a missing group directory is not reported as empty")
equal(Hardware.build({ inventory = missing_data }).partial, true,
  "unreadable group membership keeps the topology partial")

local denied_group = {}
for key, value in pairs(iommu_files) do denied_group[key] = value end
denied_group.directories = {
  [group0] = { bridge }, [group7] = { kind = "denied" }, [group8] = { vf2 },
}
local denied_data = fixture(denied_group):sample({}).data
equal(denied_data.pci.iommu_groups[2].status, "denied",
  "a denied group member list is distinct from an empty group")
equal(Hardware.build({ inventory = denied_data }).partial, true,
  "denied group membership stays visible as partial topology")

local mismatched_group = {}
for key, value in pairs(iommu_files) do mismatched_group[key] = value end
mismatched_group.directories = {
  [group0] = { bridge }, [group7] = { vf1 }, [group8] = { vf2 },
}
local mismatched_graph = Hardware.build({
  inventory = fixture(mismatched_group):sample({}).data,
})
equal(mismatched_graph.by_id[group_pf.id].iommu_group_membership_confirmed, false,
  "a symlink absent from the group directory is not silently trusted")
equal(mismatched_graph.partial, true, "inconsistent group membership marks topology partial")

local cut_group = {}
for key, value in pairs(iommu_files) do cut_group[key] = value end
cut_group.truncated_dirs = { [group7] = true }
equal(fixture(cut_group):sample({}).data.pci.iommu_groups[2].status, "partial",
  "a truncated kernel group directory cannot claim complete membership")

local many_member_names = { endpoint, vf1 }
for index = 3, 257 do many_member_names[index] = "platform:device" .. index end
local oversized_group = {}
for key, value in pairs(iommu_files) do oversized_group[key] = value end
oversized_group.directories = {
  [group0] = { bridge }, [group7] = many_member_names, [group8] = { vf2 },
}
local oversized_data = fixture(oversized_group):sample({}).data
equal(#oversized_data.pci.iommu_groups[2].members, 256,
  "a single group cannot exceed its member-name cap")
equal(oversized_data.pci.iommu_groups[2].status, "partial",
  "the per-group cap is disclosed")

local many_groups = { pci_count = 17, links = {}, directories = {} }
for id = 0, 16 do
  local address = string.format("0000:%02x:00.0", 0x10 + id)
  many_groups.links[pci_base .. address .. "/iommu_group"] =
    "../../../../kernel/iommu_groups/" .. id
  local members = { address }
  for index = 2, 256 do
    members[index] = string.format("platform:%d:%d", id, index)
  end
  many_groups.directories["/sys/kernel/iommu_groups/" .. id .. "/devices"] = members
end
local bounded_groups = fixture(many_groups):sample({}).data.pci.iommu_groups
equal(bounded_groups[17].status, "partial",
  "the aggregate member-name cap marks later groups incomplete")
equal(bounded_groups[17].members, nil,
  "the aggregate cap does not invent an empty final group")

local wrong_group_link = {}
for key, value in pairs(iommu_files) do wrong_group_link[key] = value end
local wrong_links = {}
for key, value in pairs(iommu_links) do wrong_links[key] = value end
wrong_links[pci_base .. endpoint .. "/iommu_group"] = "../other/iommu_groups/7"
wrong_group_link.links = wrong_links
equal(fixture(wrong_group_link):sample({}).data.pci.devices[2].iommu_group_id,
  nil, "an unrelated numeric symlink is not an IOMMU group")

-- The sysfs MSI list establishes device ownership; /proc/interrupts only
-- supplies counts for those numeric IRQs, never a guessed text label.
local irq_device = "0000:00:02.0"
local irq_peer = "0000:01:00.0"
local irq_dir = pci_base .. irq_device .. "/msi_irqs"
local peer_irq_dir = pci_base .. irq_peer .. "/msi_irqs"
local irq_files = {
  directories = {
    [irq_dir] = { "100", "101" },
    [peer_irq_dir] = { "200" },
  },
  [irq_dir .. "/100"] = "msix\n",
  [irq_dir .. "/101"] = "msi\n",
  [peer_irq_dir .. "/200"] = "msix\n",
  ["/proc/irq/100/effective_affinity_list"] = "0\n",
  ["/proc/irq/100/smp_affinity_list"] = "0-1\n",
  ["/proc/irq/101/effective_affinity_list"] = "1\n",
  ["/proc/irq/101/smp_affinity_list"] = "1\n",
  ["/proc/irq/200/effective_affinity_list"] = "0-1\n",
  ["/proc/irq/200/smp_affinity_list"] = "0-1\n",
  ["/proc/interrupts"] = " CPU0 CPU1\n"
    .. "  1: 999 999 unrelated\n"
    .. "100: 4 6 renamed-handler\n"
    .. "101: 1 2 another-handler\n"
    .. "200: 0 7 peer-handler\n",
}
local irq_first = fixture(irq_files):sample({
  now_ns = function() return 1000000000 end,
})
local irq_msi = irq_first.data.pci.devices[1].msi
equal(irq_msi.status, "ok", "the MSI directory gives the vector set")
equal(irq_msi.count_status, "ok", "all owned vectors have procfs counts")
equal(irq_msi.total, 13, "per-CPU counts sum only for this device's vectors")
equal(irq_msi.vectors[1].irq, 100, "vector numbers sort numerically")
equal(irq_msi.vectors[1].mode, "msix", "vector mode comes from sysfs")
equal(irq_msi.vectors[1].top_cpus[1].cpu_id, 1,
  "the busiest CPU is identified from the /proc/interrupts header")
equal(irq_msi.vectors[1].top_cpus[1].count, 6,
  "top CPU count is cumulative, not an affinity claim")
equal(irq_msi.affinity_status, "ok",
  "both allowed and effective affinity lists were read")
equal(irq_msi.vectors[1].effective_affinity, "0",
  "effective affinity is separate from the historically busiest CPU")
equal(irq_msi.vectors[1].allowed_affinity, "0-1",
  "the allowed CPU list may be wider than the effective list")
equal(irq_msi.change.quality, "gap", "the first MSI scan has no interval delta")
equal(irq_first.data.pci.devices[2].msi.total, 7,
  "a peer device's vector is not added to this device")
local irq_snapshot = { inventory = irq_first.data, quality = {} }
local irq_json = Export.snapshot(irq_snapshot).inventory
equal(irq_json.pci.devices[1].msi.vectors[1].top_cpus[1].cpu_id, 1,
  "CPU distribution reaches Snapshot JSON")
equal(irq_json.pci.devices[1].msi.vectors[1].effective_affinity, "0",
  "effective IRQ affinity reaches Snapshot JSON")
local irq_detail = table.concat(TUI.hardware_detail_lines(irq_snapshot,
  "pci:" .. irq_device, translator), "\n")
assert(irq_detail:find("MSI interrupt vectors", 1, true)
    and irq_detail:find("Interrupts observed: 13", 1, true)
    and irq_detail:find("CPU1", 1, true)
    and irq_detail:find("Effective CPU list: 0", 1, true)
    and irq_detail:find("Allowed CPU list: 0-1", 1, true),
  "hardware detail separates historical top CPU from current IRQ affinity")

irq_files["/proc/interrupts"] = " CPU0 CPU1\n"
  .. "100: 7 8 unrelated-label\n"
  .. "101: 1 5 unrelated-label\n"
  .. "200: 0 9 unrelated-label\n"
local irq_second = fixture(irq_files):sample({
  now_ns = function() return 2000000000 end,
}, irq_first)
equal(irq_second.data.pci.devices[1].msi.change.new_interrupts, 8,
  "adjacent vector totals report the actual newly observed interrupts")
equal(irq_second.data.pci.devices[1].msi.change.interval_seconds, 1,
  "the scan interval is recorded")
equal(irq_second.data.pci.devices[1].msi.vectors[1].change.new_interrupts, 5,
  "a vector delta identifies which IRQ advanced")
equal(Export.snapshot({ inventory = irq_second.data }).inventory.pci.devices[1]
  .msi.change.new_interrupts, 8, "MSI change reaches Snapshot JSON")

irq_files["/proc/interrupts"] = " CPU0 CPU1\n"
  .. "100: 1 1 handler\n"
  .. "101: 1 6 handler\n"
  .. "200: 0 10 handler\n"
local irq_reset = fixture(irq_files):sample({
  now_ns = function() return 3000000000 end,
}, irq_second)
equal(irq_reset.data.pci.devices[1].msi.change.quality, "reset",
  "a falling IRQ count is a reset, not a negative event count")

irq_files["/proc/interrupts"] = " CPU0 CPU1\n"
  .. "100: 7 8 handler\n"
  .. "200: 0 9 handler\n"
local irq_missing = fixture(irq_files):sample({}).data.pci.devices[1].msi
equal(irq_missing.count_status, "partial",
  "a missing owned IRQ row cannot produce a device total")
equal(irq_missing.total, nil, "the device total is absent when a vector is missing")
local missing_affinity = {}
for key, value in pairs(irq_files) do missing_affinity[key] = value end
missing_affinity["/proc/irq/100/effective_affinity_list"] = nil
missing_affinity["/proc/interrupts"] = " CPU0 CPU1\n"
  .. "100: 7 8 handler\n101: 1 5 handler\n200: 0 9 handler\n"
local no_effective = fixture(missing_affinity):sample({}).data.pci.devices[1].msi
equal(no_effective.vectors[1].affinity_status, "partial",
  "an allowed mask is not relabelled as effective affinity")
equal(no_effective.vectors[1].effective_affinity, nil,
  "missing effective affinity remains unavailable")
equal(no_effective.count_status, "ok",
  "missing affinity does not degrade independently readable IRQ counts")
local malformed_affinity = {}
for key, value in pairs(irq_files) do malformed_affinity[key] = value end
malformed_affinity["/proc/irq/100/effective_affinity_list"] = "0-999999\n"
equal(fixture(malformed_affinity):sample({}).data.pci.devices[1].msi
  .vectors[1].affinity_status, "partial",
  "an unbounded CPU range is rejected rather than expanded")
local denied_irq = {}
for key, value in pairs(irq_files) do denied_irq[key] = value end
denied_irq.directories = {
  [irq_dir] = { kind = "denied" }, [peer_irq_dir] = { "200" },
}
equal(fixture(denied_irq):sample({}).data.pci.devices[1].msi.status, "denied",
  "a denied MSI directory is not an empty vector list")
local shared_irq = {}
for key, value in pairs(irq_files) do shared_irq[key] = value end
shared_irq.directories = {
  [irq_dir] = { "100", "101" }, [peer_irq_dir] = { "100", "200" },
}
shared_irq[peer_irq_dir .. "/100"] = "msi\n"
shared_irq["/proc/interrupts"] = " CPU0 CPU1\n"
  .. "100: 7 8 handler\n101: 1 5 handler\n200: 0 9 handler\n"
local shared_data = fixture(shared_irq):sample({}).data
equal(shared_data.pci.devices[1].msi.vectors[1].count_status, "partial",
  "an IRQ claimed by two PCI devices is not attributed to either")
equal(shared_data.pci.devices[1].msi.total, nil,
  "a conflicting IRQ owner prevents a fabricated device total")
local changed_irq_device = {}
for key, value in pairs(irq_files) do changed_irq_device[key] = value end
changed_irq_device[pci_base .. irq_device .. "/device"] = "0x1234\n"
changed_irq_device["/proc/interrupts"] = shared_irq["/proc/interrupts"]
equal(fixture(changed_irq_device):sample({
  now_ns = function() return 2000000000 end,
}, irq_first).data.pci.devices[1].msi.change.quality, "gap",
  "a different PCI identity at the same address cannot inherit IRQ deltas")
local proc_counts, proc_status = Parsers.proc_interrupts(
  " CPU0 CPU1\n100: 4 6 text\n100: 5 6 text\n", { [100] = true })
equal(proc_status, "partial", "duplicate numeric IRQ rows are not trusted")
equal(proc_counts[100], false, "duplicate IRQ count is not a usable total")
local duplicate_proc = {}
for key, value in pairs(irq_files) do duplicate_proc[key] = value end
duplicate_proc["/proc/interrupts"] = " CPU0 CPU1\n"
  .. "100: 4 6 handler\n100: 5 6 handler\n"
  .. "101: 1 2 handler\n200: 0 7 handler\n"
local duplicate_irq_data = fixture(duplicate_proc):sample({}).data.pci.devices
equal(duplicate_irq_data[1].msi.vectors[1].count_status, "partial",
  "a duplicate procfs row leaves its vector untrusted")
equal(duplicate_irq_data[2].msi.count_status, "partial",
  "a truncated or contradictory source cannot certify other device totals")
equal(Parsers.proc_interrupts("not a CPU header\n", { [100] = true }), nil,
  "malformed CPU headings cannot be interpreted as per-CPU counts")
local overflow_counts, overflow_status = Parsers.proc_interrupts(
  " CPU0 CPU1\n100: 9223372036854775807 1 text\n", { [100] = true })
equal(overflow_status, "partial", "an overflowing per-CPU sum is not reported")
equal(overflow_counts[100], false, "overflow has no usable IRQ total")
local oversized_vectors = {
  directories = { [irq_dir] = {} },
  ["/proc/interrupts"] = " CPU0 CPU1\n",
}
for index = 1, 257 do
  oversized_vectors.directories[irq_dir][index] = tostring(1000 + index)
  oversized_vectors[irq_dir .. "/" .. (1000 + index)] = "msix\n"
end
local cut_vectors = fixture(oversized_vectors):sample({}).data.pci.devices[1].msi
equal(#cut_vectors.vectors, 256, "a PCI device's MSI vector list is bounded")
equal(cut_vectors.status, "partial", "a vector list past its cap is incomplete")
local many_msi = { pci_count = 17, directories = {},
  ["/proc/interrupts"] = " CPU0 CPU1\n" }
for device_index = 0, 16 do
  local address = string.format("0000:%02x:00.0", 0x10 + device_index)
  local directory = pci_base .. address .. "/msi_irqs"
  many_msi.directories[directory] = {}
  for vector_index = 1, 256 do
    local irq = 10000 + device_index * 256 + vector_index
    many_msi.directories[directory][vector_index] = tostring(irq)
    many_msi[directory .. "/" .. irq] = "msix\n"
  end
end
local bounded_msi = fixture(many_msi):sample({}).data.pci.devices
equal(bounded_msi[3].msi.status, "ok",
  "the third device still has its static MSI vector identity")
equal(bounded_msi[3].msi.affinity_status, "partial",
  "the affinity read budget marks later vector settings incomplete")
equal(#bounded_msi[17].msi.vectors, 0,
  "the global MSI budget stops later devices without inventing vectors")
equal(bounded_msi[17].msi.status, "partial",
  "the global vector budget is visible in the last device's status")

equal(hierarchy.usb.devices[2].speed_mbps, 12, "USB speed is in Mb/s")
local device_path = "/sys/devices/pci0000:00/" .. bridge .. "/" .. endpoint
local own_sensor = { id = "own", name = "amdgpu", class = "hwmon0", quality = "fresh",
  source = "/sys/class/hwmon/hwmon0", device_target = "../../nvme0",
  device_path = device_path .. "/nvme/nvme0/hwmon/hwmon0",
  channels = { { type = "temperature", index = 1, input = 45, unit = "celsius",
    label = "Fixture temperature", quality = "fresh" } } }
local graph_snapshot = { inventory = hierarchy,
  sensors = { devices = { own_sensor,
    { id = "usb", device_target = "/sys/devices/usb1/1-2/1-2.3/1-2.3:1.0" },
    { id = "missing-usb", device_target = device_path .. "/usb1/1-2.9" },
    { id = "dimm", device_target = device_path .. "/i2c-1/1-0050" } } },
  gpus = { devices = { { id = "card0", pci_bdf = endpoint, vendor_id = 0x1002,
    device_id = 0xabcd }, { id = "wrong", pci_bdf = endpoint, vendor_id = 0x8086 } } } }
local graph = Hardware.build(graph_snapshot)
equal(#graph.nodes, 5, "every enumerated bus device remains in the tree")
equal(graph.nodes[1].id, "pci:" .. bridge, "parent precedes its children")
equal(graph.by_id["pci:" .. endpoint].depth, 1, "PCI endpoint depth")
equal(graph.by_id["usb:usb1"].parent_id, "pci:" .. bridge, "USB root links to PCI controller")
equal(graph.by_id["usb:1-2.3"].depth, 3, "USB descendants keep their hierarchy")
equal(#graph.by_id["pci:" .. endpoint].sensor_ids, 1,
  "USB and I2C descendants must not donate sensors to a PCI ancestor")
equal(graph.by_id["usb:1-2.3"].sensor_ids[1], "usb", "USB interface maps to physical device")
equal(#graph.by_id["pci:" .. endpoint].gpu_ids, 1, "mismatching GPU identity does not join")
equal(#own_sensor.channels, 1, "model does not mutate the sensor snapshot")
local exported = Export.snapshot(graph_snapshot).inventory
equal(#exported.topology.nodes, #graph.nodes, "export and UI share the same topology")
equal(exported.pci.devices[2].driver, "amdgpu", "new metadata is exported")
equal(exported.topology.nodes[2].sensor_ids[1], "own", "ownership is exported by stable sensor id")
local device_models = ViewModel.build(engine, graph_snapshot, translator, {}, "system",
  nil, { system_devices = true }, { system_selected = "pci:" .. endpoint })
equal(device_models.system_devices.ids[2], "pci:" .. endpoint, "selectable table ids follow tree order")
equal(device_models.system_devices.selected, 2, "selection follows identity")
local details = table.concat(TUI.hardware_detail_lines(graph_snapshot,
  "pci:" .. endpoint, translator, 1000000000), "\n")
assert(details:find("amdgpu", 1, true) and details:find("Fixture temperature", 1, true))
assert(details:find("16", 1, true) and details:find("GT/s", 1, true))
assert(details:find("p parent", 1, true), "a device with a parent offers navigation")
local cycles = { inventory = { pci = { devices = {
  { address = bridge, parent_address = endpoint },
  { address = endpoint, parent_address = bridge },
} } } }
local cyclic_graph = Hardware.build(cycles)
assert(cyclic_graph.partial and #cyclic_graph.nodes == 2,
  "malformed parent cycles must be bounded without losing devices")
equal(cycles.inventory.pci.devices[1].parent_address, endpoint,
  "cycle repair must not change the published snapshot")
local large = { inventory = { pci = { devices = {} } } }
for index = 1, 600 do
  large.inventory.pci.devices[index] = { address = string.format("%04x:00:00.0", index) }
end
local bounded = Hardware.build(large)
assert(bounded.truncated and #bounded.nodes == 256, "topology respects the inventory cap")
assert(#Hardware.build({}).nodes == 0, "absent inventories remain usable")
local ambiguous = Hardware.build({ inventory = { pci = { devices = {
  { address = endpoint }, { address = endpoint },
} } }, sensors = { devices = { own_sensor } } })
assert(ambiguous.partial and ambiguous.by_id["pci:" .. endpoint].ambiguous
  and #ambiguous.by_id["pci:" .. endpoint].sensor_ids == 0,
  "ambiguous identities must not claim a sensor")
-- Storage and network joins use real sysfs ancestry; mounts use major:minor,
-- including mounts whose source is an alias rather than a /dev kernel name.
do
  package.path = "./tests/?.lua;" .. package.path
  local Fixture = require("support.fixture_fs")
  local Disk = require("wtop.collectors.disk")
  local Network = require("wtop.collectors.network")
  local Sysfs = require("wtop.linux.sysfs")
  local controller, nic, host = "0000:04:00.0", "0000:05:00.0", "0000:00:14.0"
  local nvme_path = "/sys/devices/pci0000:00/" .. controller .. "/nvme/nvme0/nvme0n1"
  local usb_path = "/sys/devices/pci0000:00/" .. host .. "/usb1/1-2/1-2:1.0"
  local spec = { files = {
    ["/proc/diskstats"] = table.concat({
      "259 0 nvme0n1 1 0 2 0 3 0 4 0 0 0 0",
      "259 1 nvme0n1p1 1 0 2 0 3 0 4 0 0 0 0",
      "8 0 sda 1 0 2 0 3 0 4 0 0 0 0",
      "7 0 loop0 1 0 2 0 3 0 4 0 0 0 0",
    }, "\n"),
    ["/sys/dev/block/259:0/diskseq"] = "11",
    ["/sys/dev/block/259:1/partition"] = "1",
    ["/sys/block/nvme0n1/device/model"] = "Fixture NVMe",
    ["/sys/block/nvme0n1/size"] = "2097152",
    ["/proc/net/dev"] = table.concat({
      "enp5s0: 1000 1 0 0 0 0 0 0 2000 2 0 0 0 0 0 0",
      "usbnet: 1000 1 0 0 0 0 0 0 2000 2 0 0 0 0 0 0",
      "lo: 1000 1 0 0 0 0 0 0 2000 2 0 0 0 0 0 0",
    }, "\n"),
    ["/sys/class/net/enp5s0/ifindex"] = "4",
    ["/sys/class/net/enp5s0/operstate"] = "up",
    ["/sys/class/net/enp5s0/speed"] = "1000",
    ["/sys/class/net/usbnet/ifindex"] = "7",
    ["/sys/class/net/lo/ifindex"] = "1",
  }, links = {
    ["/sys/dev/block/259:0"] = "../../devices/pci0000:00/" .. controller .. "/nvme/nvme0/nvme0n1",
    ["/sys/dev/block/259:1"] = nvme_path .. "/nvme0n1p1",
    ["/sys/dev/block/8:0"] = usb_path .. "/host2/target2:0:0/2:0:0:0/block/sda",
    ["/sys/dev/block/7:0"] = "../../devices/virtual/block/loop0",
    ["/sys/class/net/enp5s0"] = "../../devices/pci0000:00/" .. nic .. "/net/enp5s0",
    ["/sys/class/net/usbnet"] = usb_path .. "/net/usbnet",
    ["/sys/class/net/lo"] = "../../devices/virtual/net/lo",
  } }
  local fs = Fixture.new(spec)
  local disks = Disk.new({ fs = fs }):sample({}).data
  local network = Network.new({ fs = fs }):sample({}).data
  local state = { disks = disks, network = network,
    inventory = { pci = { devices = {
      { address = controller, device_name = "Storage controller", driver = "nvme" },
      { address = nic, device_name = "Ethernet controller", driver = "r8169" },
      { address = host },
    } }, usb = { devices = {
      { id = "usb1", parent_id = host }, { id = "1-2", parent_id = "usb1" },
    } } }, mounts = { mounts = {
      { id = "40", device_id = "259:1", source = "/dev/disk/by-uuid/fixture",
        mount_point = "/", fs_type = "ext4" },
      { id = "41", device_id = "259:1", source = "/dev/disk/by-uuid/fixture",
        mount_point = "/srv/bind", fs_type = "ext4" },
      { id = "42", device_id = "0:2", source = "/dev/nvme0n1p1",
        mount_point = "/unrelated", fs_type = "tmpfs" },
    } }, quality = { disks = { quality = "gap" }, network = { quality = "fresh" } } }
  local tree = Hardware.build(state)
  local disk_id = "block:259:0:11"
  equal(tree.by_id[disk_id].device.device_path, nvme_path, "class link is resolved into /sys/devices")
  equal(tree.by_id[disk_id].parent_id, "pci:" .. controller, "NVMe links to its PCI controller")
  equal(tree.by_id["block:259:1"].parent_id, disk_id, "partition belongs to the enclosing disk")
  equal(tree.by_id["block:8:0"].parent_id, "usb:1-2", "USB disk belongs to the adapter, not the host")
  equal(tree.by_id["net:4"].parent_id, "pci:" .. nic, "physical interface belongs to its PCI function")
  equal(tree.by_id["net:7"].parent_id, "usb:1-2", "USB interface maps to the physical USB device")
  equal(tree.by_id["net:1"].parent_id, nil, "loopback has no invented physical parent")
  equal(tree.by_id["block:7:0"].parent_id, nil, "virtual block device remains a root")
  equal(#tree.by_id["block:259:1"].mount_ids, 2, "aliases and bind mounts join by device number")
  equal(#tree.by_id[disk_id].mount_ids, 0, "partition mounts are not assigned to the whole disk")
  equal(tree.by_id["block:259:1"].depth, 2, "partition follows the disk in the hierarchy")
  local model = ViewModel.build(engine, state, translator, {}, "system", nil, nil,
    { system_selected = "net:7" }).system_devices
  equal(#model.rows, 12, "system table includes every bus, disk and interface")
  equal(model.ids[model.selected], "net:7", "selection survives the merged tree order")
  local details = table.concat(TUI.hardware_detail_lines(state, "block:259:1", translator), "\n")
  assert(details:find("Mount: /srv/bind", 1, true) and details:find("Filesystem: ext4", 1, true))
  assert(details:find("p parent", 1, true), "partition detail offers parent navigation")
  local disk_details = table.concat(TUI.hardware_detail_lines(state, disk_id, translator), "\n")
  assert(disk_details:find("Fixture NVMe", 1, true) and disk_details:find("GiB", 1, true))
  local net_details = table.concat(TUI.hardware_detail_lines(state, "net:4", translator), "\n")
  assert(net_details:find("Mb/s", 1, true) and net_details:find("/sys/class/net/enp5s0", 1, true))
  local exported = Export.snapshot(state)
  local exported_by_id = {}
  for _, node in ipairs(exported.inventory.topology.nodes) do exported_by_id[node.id] = node end
  equal(exported_by_id["net:7"].resource, "network", "topology names the backing resource")
  equal(exported_by_id["net:7"].resource_id, 7, "network resource id retains its numeric type")
  equal(exported_by_id["block:259:1"].mount_ids[2], "41", "mount references survive JSON export")
  for index, disk in ipairs(disks.devices) do
    equal(exported.disks.devices[index].device_path, disk.device_path, "disk ancestry is exported")
  end
  for index, interface in ipairs(network.interfaces) do
    equal(exported.network.interfaces[index].device_path, interface.device_path, "interface ancestry is exported")
  end

  -- Reusing a disk number after removal cannot reopen the old selection.
  spec.files["/sys/dev/block/259:0/diskseq"] = "12"
  local replaced = { disks = Disk.new({ fs = Fixture.new(spec) }):sample({}).data }
  local replacement = Hardware.build(replaced)
  assert(not replacement.by_id[disk_id] and replacement.by_id["block:259:0:12"])
  assert(TUI.hardware_detail_lines(replaced, disk_id, translator)[1]:find("not in", 1, true))
  equal(#Export.snapshot(replaced).inventory.topology.nodes, 4,
    "hosts without PCI/USB inventory still export storage topology")
  local renamed = { network = { interfaces = { { id = 4, name = "renamed" } } } }
  equal(Hardware.build(renamed).by_id["net:4"].identifier, "renamed", "network selection uses ifindex, not name")
  renamed.network.interfaces[1].device_path = "/sys/devices/pci0000:00/" .. nic .. "/net/1-2"
  equal(Hardware.build(renamed).by_id["net:4"].parent_id, "pci:" .. nic,
    "an interface name resembling a USB address cannot change its bus owner")
  renamed.network.interfaces[1].device_path = usb_path .. "/net/renamed"
  equal(Hardware.build(renamed).by_id["net:4"].parent_id, "usb:1-2",
    "a missing USB inventory cannot attach its interface to the host controller")
  local malformed = Fixture.new({ links = { ["/sys/dev/block/1:0"] = "../../../../etc/passwd" } })
  equal(Sysfs.device_path(malformed, "/sys/dev/block/1:0"), nil, "non-device link is rejected")
  equal(Sysfs.device_path({}, "/sys/dev/block/1:0"), nil, "missing link support is harmless")
  local duplicates = { disks = { devices = {
    { id = "8:0", stable_id = "8:0:1", name = "sda", device_path = nvme_path },
    { id = "8:0", stable_id = "8:0:2", name = "sdb", device_path = nvme_path },
    { id = "8:1", name = "sda1", is_partition = true, device_path = nvme_path .. "/sda1" },
  } }, mounts = { mounts = { { id = "1", device_id = "8:0", mount_point = "/" } } } }
  local uncertain = Hardware.build(duplicates)
  assert(uncertain.partial and not uncertain.by_id["block:8:1"].parent_id)
  equal(#uncertain.by_id["block:8:0:1"].mount_ids, 0, "ambiguous disk numbers must not claim a mount")
  local many = { disks = { devices = {} }, network = { interfaces = {} }, inventory = large.inventory }
  for index = 1, 300 do
    many.disks.devices[index] = { id = "8:" .. index, name = "disk" .. index }
    many.network.interfaces[index] = { id = index, name = "net" .. index }
  end
  local bounded_tree = Hardware.build(many)
  assert(bounded_tree.truncated and #bounded_tree.nodes == 640, "each resource has a bounded node budget")
  local bounded_table = ViewModel.build(engine, many, translator, {}, "system").system_devices
  assert(#bounded_table.rows == 512 and bounded_table.status_text:find("…", 1, true),
    "system table reports its own row cap")
end
print("ok: bus/storage/network topology, metadata, ownership, exports and details")
