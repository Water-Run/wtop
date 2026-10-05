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
    -- The key is `read_link`.  This said `readlink`, which is not a name
    -- `FS.new` knows: the key was accepted, kept in the options table, and never
    -- read, so the real readlink implementation was substituted and the double
    -- was not the hermetic thing it looked like.  `path_type` said `"file"`,
    -- which is also not a word the product produces -- `native.path_type`
    -- answers `regular` for S_ISREG.
    read_link = function() return nil, { kind = "missing" } end,
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
equal(over_pci.data.usb.total, 0, "the absent bus contributes nothing")

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

print("ok: device inventory collector")
