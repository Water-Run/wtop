-- The device inventory collector enumerates PCI and USB devices with names
-- from the local pci.ids database, bounded, with absent sources reporting
-- unavailable instead of an empty success.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local FS = require("wtop.linux.fs")
local Inventory = require("wtop.collectors.inventory")
local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")

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
  if files["/__no_pci"] ~= nil then directories["/sys/bus/pci/devices"] = nil end
  if files["/__no_usb"] ~= nil then directories["/sys/bus/usb/devices"] = nil end
  local fs = FS.new({
    root = "/",
    read_file = function(path)
      local content = files[path]
      if content == nil then
        return nil, { kind = "missing", message = "no such file" }
      end
      return content
    end,
    list_dir = function(path)
      local entries = directories[path]
      if not entries then
        return nil, { kind = "missing", message = "no such directory" }
      end
      return entries, nil, false
    end,
    readlink = function() return nil, { kind = "missing" } end,
    path_type = function() return "file" end,
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
equal(usb_only_result.data.pci.total, 0, "absent PCI bus reports zero total")

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

print("ok: device inventory collector")
