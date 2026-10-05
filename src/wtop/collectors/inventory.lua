-- Static hardware device inventory: PCI and USB device lists with names from
-- the local pci.ids database. Identity data such as DMI strings is already
-- part of the system collector; this adds the per-device view. Serial numbers
-- are deliberately not read anywhere in this collector.
local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")
local PciNames = require("wtop.linux.pci_names")

local Inventory = {}
Inventory.__index = Inventory

local MAX_PCI_DEVICES = 256
local MAX_USB_DEVICES = 128
local MAX_SMALL_FILE = 16 * 1024

local function text(fs, path)
  local content = fs:read(path, MAX_SMALL_FILE)
  if type(content) ~= "string" then return nil end
  local trimmed = Common.trim(content)
  if trimmed == "" then return nil end
  return Common.safe_text(trimmed, 128)
end

local function hex_id(fs, path)
  local raw = text(fs, path)
  if type(raw) ~= "string" then return nil end
  local value = tonumber(raw:match("^0x(%x+)$") or raw:match("^(%x+)$"), 16)
  if type(value) ~= "number" or value < 0 or value > 0xffffffff then return nil end
  return value
end

local function decimal(fs, path)
  local value = tonumber(text(fs, path))
  if type(value) ~= "number" or value ~= value or value % 1 ~= 0
      or value < 0 or value > 0xffffffff then
    return nil
  end
  return value
end

local function read_pci_device(self, fs, base, address)
  local path = base .. "/" .. address
  local vendor_id = hex_id(fs, path .. "/vendor")
  if not vendor_id then return nil end
  local device_id = hex_id(fs, path .. "/device")
  local class_id = hex_id(fs, path .. "/class")
  local revision = hex_id(fs, path .. "/revision")
  local vendor_name, device_name = self.pci_names:names(vendor_id, device_id)
  return {
    address = Common.safe_text(address, 32),
    vendor_id = vendor_id,
    device_id = device_id,
    class_id = class_id,
    revision = revision,
    vendor_name = vendor_name,
    device_name = device_name,
  }
end

local function read_usb_device(fs, base, name)
  local path = base .. "/" .. name
  local vendor_id = hex_id(fs, path .. "/idVendor")
  if not vendor_id then return nil end
  local product_id = hex_id(fs, path .. "/idProduct")
  local bus = decimal(fs, path .. "/busnum")
  local number = decimal(fs, path .. "/devnum")
  return {
    id = Common.safe_text(name, 64),
    bus = bus,
    device = number,
    vendor_id = vendor_id,
    product_id = product_id,
    manufacturer = text(fs, path .. "/manufacturer"),
    product = text(fs, path .. "/product"),
  }
end

function Inventory.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Inventory options must be a table", 2) end
  local self = setmetatable({
    id = "inventory",
    default_interval_ms = Common.positive_integer("interval_ms",
      options.interval_ms, 30000),
    fs = options.fs or FS.default,
    pci_base = Common.absolute_path("pci_base", options.pci_base,
      "/sys/bus/pci/devices"),
    usb_base = Common.absolute_path("usb_base", options.usb_base,
      "/sys/bus/usb/devices"),
    _method_style = true,
  }, Inventory)
  self.pci_names = options.pci_names
    or PciNames.new({ fs = self.fs, paths = options.pci_ids_paths })
  return self
end

function Inventory:probe(context)
  local fs = Common.fs(context, self.fs)
  local pci_entries, pci_error = fs:list(self.pci_base, MAX_PCI_DEVICES + 1)
  if pci_entries and #pci_entries > 0 then
    return Capability.available({ source = self.pci_base })
  end
  local usb_entries = fs:list(self.usb_base, MAX_USB_DEVICES + 1)
  if usb_entries and #usb_entries > 0 then
    return Capability.available({ source = self.usb_base })
  end
  if pci_entries or usb_entries then
    return Capability.unavailable("no_device_inventory", { source = self.pci_base })
  end
  local status = FS.error_status(pci_error)
  if status == "denied" then
    return Capability.denied(pci_error and pci_error.message,
      { source = self.pci_base })
  end
  return Capability.unavailable(
    pci_error and pci_error.message or "device_inventory_unavailable",
    { source = self.pci_base })
end

function Inventory:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)

  local pci_entries, pci_list_error = fs:list(self.pci_base, MAX_PCI_DEVICES + 1)
  local usb_entries = fs:list(self.usb_base, MAX_USB_DEVICES + 1)
  if not pci_entries and not usb_entries then
    local finished = Common.now_ns(context)
    return Common.result("unavailable", finished, nil, {
      quality = "unavailable",
      reason = "no_device_inventory",
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.pci_base,
      error = pci_list_error,
    })
  end

  local pci_devices, pci_total, pci_truncated = {}, 0, false
  if pci_entries then
    local sorted = {}
    for _, address in ipairs(pci_entries) do sorted[#sorted + 1] = address end
    table.sort(sorted)
    for _, address in ipairs(sorted) do
      pci_total = pci_total + 1
      if #pci_devices >= MAX_PCI_DEVICES then
        pci_truncated = true
        break
      end
      local device = read_pci_device(self, fs, self.pci_base, address)
      if device then pci_devices[#pci_devices + 1] = device end
    end
  end

  local usb_devices, usb_total, usb_truncated = {}, 0, false
  if usb_entries then
    local sorted = {}
    for _, name in ipairs(usb_entries) do sorted[#sorted + 1] = name end
    table.sort(sorted)
    for _, name in ipairs(sorted) do
      -- Interface entries such as "1-2:1.0" have no idVendor; they are not
      -- devices and must not inflate the total either.
      local device = read_usb_device(fs, self.usb_base, name)
      if device then
        usb_total = usb_total + 1
        if #usb_devices >= MAX_USB_DEVICES then
          usb_truncated = true
          break
        end
        usb_devices[#usb_devices + 1] = device
      end
    end
  end

  local finished = Common.now_ns(context)
  if #pci_devices == 0 and #usb_devices == 0 then
    return Common.result("unavailable", finished, nil, {
      quality = "unavailable",
      reason = "no_device_inventory",
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.pci_base,
    })
  end
  local truncated = (pci_truncated or usb_truncated)
  local quality = truncated and "truncated" or "fresh"
  return Common.result("ok", finished, {
    pci = { devices = pci_devices, total = pci_total, truncated = pci_truncated },
    usb = { devices = usb_devices, total = usb_total, truncated = usb_truncated },
  }, {
    quality = quality,
    -- The cause is one condition and it is measured rather than assumed: an
    -- enumeration stopped at its configured device cap, so the list is shorter
    -- than the total and nothing failed.  That is why the label is `truncated`
    -- and not `partial` -- the figures that are present are current and exact,
    -- and what is missing is the tail of a bounded list.
    --
    -- One cause, one code: the power supply list publishes `truncated` for the
    -- same reason -- an enumeration that stopped at its own cap with nothing
    -- failing -- and a user reading the reason column is already looking at one
    -- collector's row, so a second code for the same fact would be a
    -- distinction without a difference.  Note what the reason is for at all:
    -- `truncated` was published here with no reason, so the quality said the
    -- list was short and nothing said why.  The per-resource flags stay where
    -- they are; they are row markers, and this is the one slot a result has.
    reason = truncated and "device_enumeration_truncated" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = self.pci_base,
  })
end

return Inventory
