-- Static hardware device inventory: PCI and USB device lists with names from
-- the local pci.ids database. Identity data such as DMI strings is already
-- part of the system collector; this adds the per-device view. Serial numbers
-- are deliberately not read anywhere in this collector.
local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")
local PciNames = require("wtop.linux.pci_names")
local Parsers = require("wtop.linux.parsers")

local Inventory = {}
Inventory.__index = Inventory

local MAX_PCI_DEVICES = 256
local MAX_USB_DEVICES = 128
local MAX_USB_INTERFACES = 256
local MAX_USB_SCAN_ENTRIES = 1024
local MAX_IOMMU_GROUP_MEMBERS = 256
local MAX_IOMMU_MEMBERS_TOTAL = 4096
local MAX_MSI_VECTORS_PER_DEVICE = 256
local MAX_MSI_VECTORS_TOTAL = 4096
local MAX_IRQ_AFFINITY_READS = 1024
local MAX_PROC_INTERRUPTS = 4 * 1024 * 1024
local MAX_SMALL_FILE = 16 * 1024

local AER_DEVICE_FILES = {
  { key = "correctable", file = "aer_dev_correctable", total = "TOTAL_ERR_COR" },
  { key = "nonfatal", file = "aer_dev_nonfatal", total = "TOTAL_ERR_NONFATAL" },
  { key = "fatal", file = "aer_dev_fatal", total = "TOTAL_ERR_FATAL" },
}
local AER_ROOT_FILES = {
  { key = "correctable", file = "aer_rootport_total_err_cor" },
  { key = "nonfatal", file = "aer_rootport_total_err_nonfatal" },
  { key = "fatal", file = "aer_rootport_total_err_fatal" },
}

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

local function link(fs, path)
  if type(fs.readlink) ~= "function" then return nil end
  local target = fs:readlink(path)
  return type(target) == "string" and #target <= 4096 and target or nil
end

local function driver(fs, path)
  local target = link(fs, path .. "/driver")
  local name = target and target:match("([^/]+)$")
  return name and name ~= "." and name ~= ".." and Common.safe_text(name, 128) or nil
end

local function parent(target, name)
  if type(target) ~= "string" then return nil end
  local previous
  for component in target:gmatch("[^/]+") do
    if component == name then return previous end
    if component:match("^%x+:%x%x:%x%x%.[0-7]$")
        or component:match("^usb%d+$") or component:match("^%d+%-%d+[%.%d]*$") then
      previous = component
    end
  end
end

local function speed(fs, path, pattern)
  local raw = text(fs, path)
  local value = raw and tonumber(pattern and raw:match(pattern) or raw)
  if value and value == value and value > 0 and value < 1000000 then return value end
end

local function pci_address_from_link(target)
  local address = type(target) == "string" and target:match("([^/]+)$") or nil
  if address and #address <= 32
      and address:match("^%x+:%x%x:%x%x%.[0-7]$") then
    return address:lower()
  end
end

local function iommu_group_from_link(target)
  local id = type(target) == "string"
    and target:match("/kernel/iommu_groups/(%d+)$") or nil
  local number = id and tonumber(id)
  if number and math.type(number) == "integer"
      and number >= 0 and number <= 2147483647 then return number end
end

local function read_iommu_groups(fs, devices)
  local ids, groups = {}, {}
  local remaining = MAX_IOMMU_MEMBERS_TOTAL
  for _, device in ipairs(devices) do
    if device.iommu_group_id ~= nil then ids[device.iommu_group_id] = true end
  end
  local sorted = {}
  for id in pairs(ids) do sorted[#sorted + 1] = id end
  table.sort(sorted)
  for _, id in ipairs(sorted) do
    local path = "/sys/kernel/iommu_groups/" .. id .. "/devices"
    local group = { id = id, source = path }
    if remaining == 0 then
      group.status = "partial"
    else
      local limit = math.min(MAX_IOMMU_GROUP_MEMBERS, remaining)
      local entries, failure, truncated = fs:list(path, limit + 1)
      if type(entries) ~= "table" then
        group.status = FS.error_status(failure)
      else
        group.members = {}
        local partial = truncated == true or #entries > limit
        for index = 1, math.min(#entries, limit) do
          local name = entries[index]
          if type(name) == "string" and name ~= "" and #name <= 128
              and name ~= "." and name ~= ".." and not name:find("/", 1, true)
              and not name:find("%c") then
            group.members[#group.members + 1] = Common.safe_text(name, 128)
          else partial = true end
        end
        remaining = remaining - #group.members
        table.sort(group.members)
        group.status = partial and "partial" or "ok"
      end
    end
    groups[#groups + 1] = group
  end
  return groups
end

local function read_sriov(fs, path)
  local total = decimal(fs, path .. "/sriov_totalvfs")
  local physical_function_address = pci_address_from_link(link(fs, path .. "/physfn"))
  if total == nil and physical_function_address == nil then return nil end
  if total ~= nil and physical_function_address ~= nil then
    return { role = "ambiguous", status = "partial", total_vfs = total,
      physical_function_address = physical_function_address }
  end
  if physical_function_address then
    return { role = "vf", status = "ok",
      physical_function_address = physical_function_address }
  end
  local enabled = decimal(fs, path .. "/sriov_numvfs")
  return { role = "pf", status = enabled and enabled <= total and "ok" or "partial",
    total_vfs = total, enabled_vfs = enabled }
end

local function irq_affinity(fs, path, budget)
  if budget.remaining == 0 then return nil, "partial" end
  budget.remaining = budget.remaining - 1
  local raw, failure = fs:read(path, 1024)
  if type(raw) ~= "string" then return nil, FS.error_status(failure) end
  local value = Parsers.range_list(raw, 4096, 65535, 1024)
  if value then return value end
  return nil, "error"
end

local function read_msi(fs, path, budget, affinity_budget)
  local base = path .. "/msi_irqs"
  local entries, failure, truncated = fs:list(base, MAX_MSI_VECTORS_PER_DEVICE + 1)
  if type(entries) ~= "table" then
    local status = FS.error_status(failure)
    return status ~= "unavailable" and
      { status = status, source = base, vectors = {} } or nil
  end
  local msi = { status = "ok", source = base, vectors = {} }
  local seen = {}
  if truncated == true or #entries > MAX_MSI_VECTORS_PER_DEVICE then
    msi.status = "partial"
  end
  for index = 1, math.min(#entries, MAX_MSI_VECTORS_PER_DEVICE) do
    if budget.remaining == 0 then msi.status = "partial"; break end
    local name = entries[index]
    local irq = type(name) == "string" and tonumber(name) or nil
    if not irq or math.type(irq) ~= "integer" or irq <= 0
        or irq > 2147483647 or tostring(irq) ~= name or seen[irq] then
      msi.status = "partial"
    else
      seen[irq] = true
      budget.remaining = budget.remaining - 1
      local content, err = fs:read(base .. "/" .. name, 64)
      local mode = content and Common.trim(content) or nil
      local vector = { irq = irq }
      if mode == "msi" or mode == "msix" then
        vector.mode = mode
      else
        vector.status = content and "error" or FS.error_status(err)
        msi.status = "partial"
      end
      local effective, effective_status = irq_affinity(fs,
        "/proc/irq/" .. irq .. "/effective_affinity_list", affinity_budget)
      local allowed, allowed_status = irq_affinity(fs,
        "/proc/irq/" .. irq .. "/smp_affinity_list", affinity_budget)
      vector.effective_affinity = effective
      vector.allowed_affinity = allowed
      if effective and allowed then vector.affinity_status = "ok"
      elseif effective_status == allowed_status then
        vector.affinity_status = effective_status or "partial"
      else vector.affinity_status = "partial" end
      msi.vectors[#msi.vectors + 1] = vector
    end
  end
  table.sort(msi.vectors, function(a, b) return a.irq < b.irq end)
  if #msi.vectors > 0 then
    local first = msi.vectors[1].affinity_status
    local same = true
    for _, vector in ipairs(msi.vectors) do
      if vector.affinity_status ~= first then same = false break end
    end
    msi.affinity_status = msi.status ~= "ok" and "partial"
      or same and first or "partial"
  end
  return msi
end

local function read_aer(fs, path)
  local first, first_error = fs:read(path .. "/aer_dev_correctable", MAX_SMALL_FILE)
  if not first then
    -- No AER capability is ordinary on PCI devices and older kernels.
    if not first_error or FS.error_status(first_error) == "unavailable" then return nil end
    return { status = FS.error_status(first_error), issues = {
      { field = "correctable", status = FS.error_status(first_error) },
    } }
  end
  local aer = { status = "ok", issues = {} }
  local function issue(field, status)
    aer.status = "partial"
    aer.issues[#aer.issues + 1] = { field = field, status = status }
  end
  for index, specification in ipairs(AER_DEVICE_FILES) do
    local content, failure
    if index == 1 then
      content = first
    else
      content, failure = fs:read(path .. "/" .. specification.file, MAX_SMALL_FILE)
    end
    if content then
      local parsed = Parsers.pci_aer_stats(content, specification.total)
      if parsed then aer[specification.key] = parsed
      else issue(specification.key, "error") end
    else
      issue(specification.key, FS.error_status(failure))
    end
  end
  local root_first, root_error = fs:read(path .. "/aer_rootport_total_err_cor", 64)
  if root_first then
    aer.rootport = {}
    for index, specification in ipairs(AER_ROOT_FILES) do
      local content, failure
      if index == 1 then
        content = root_first
      else
        content, failure = fs:read(path .. "/" .. specification.file, 64)
      end
      local value = content and Parsers.pci_aer_root_total(content) or nil
      if value ~= nil then aer.rootport[specification.key] = value
      else issue("rootport_" .. specification.key,
          content and "error" or FS.error_status(failure)) end
    end
  elseif root_error and FS.error_status(root_error) ~= "unavailable" then
    issue("rootport_correctable", FS.error_status(root_error))
  end
  return aer
end

local function read_pci_device(self, fs, base, address, msi_budget, affinity_budget)
  local path = base .. "/" .. address
  local vendor_id = hex_id(fs, path .. "/vendor")
  if not vendor_id then return nil end
  local device_id = hex_id(fs, path .. "/device")
  local class_id = hex_id(fs, path .. "/class")
  local revision = hex_id(fs, path .. "/revision")
  local vendor_name, device_name = self.pci_names:names(vendor_id, device_id)
  local target = link(fs, path)
  return {
    address = Common.safe_text(address, 32),
    vendor_id = vendor_id,
    device_id = device_id,
    class_id = class_id,
    revision = revision,
    vendor_name = vendor_name,
    device_name = device_name,
    source = path,
    parent_address = parent(target, address),
    driver = driver(fs, path),
    numa_node = decimal(fs, path .. "/numa_node"),
    link_speed_gtps = speed(fs, path .. "/current_link_speed", "^([%d.]+)%s+GT/s"),
    link_width = decimal(fs, path .. "/current_link_width"),
    max_link_speed_gtps = speed(fs, path .. "/max_link_speed", "^([%d.]+)%s+GT/s"),
    max_link_width = decimal(fs, path .. "/max_link_width"),
    iommu_group_id = iommu_group_from_link(link(fs, path .. "/iommu_group")),
    msi = read_msi(fs, path, msi_budget, affinity_budget),
    sriov = read_sriov(fs, path),
    aer = read_aer(fs, path),
  }
end

local function same_pci_identity(current, previous)
  if type(previous) ~= "table" or current.vendor_id == nil
      or current.device_id == nil then return false end
  for _, key in ipairs({ "address", "vendor_id", "device_id", "class_id",
      "revision", "parent_address" }) do
    if current[key] ~= previous[key] then return false end
  end
  local current_sriov, previous_sriov = current.sriov, previous.sriov
  if (current_sriov and current_sriov.role) ~= (previous_sriov and previous_sriov.role)
      or (current_sriov and current_sriov.physical_function_address)
        ~= (previous_sriov and previous_sriov.physical_function_address) then
    return false
  end
  return true
end

local function aer_change(current, previous, elapsed_ns)
  if type(current) ~= "number" or type(previous) ~= "number"
      or not elapsed_ns or elapsed_ns <= 0 then return { quality = "gap" } end
  local delta, delta_state = Common.delta(current, previous)
  if delta == nil then
    return { quality = delta_state == "reset" and "reset" or "gap" }
  end
  return { new_reports = delta, quality = "fresh" }
end

local function attach_aer_changes(device, previous, elapsed_ns)
  local aer = device.aer
  if type(aer) ~= "table" then return end
  local same = same_pci_identity(device, previous)
  local old = same and previous.aer or nil
  if type(old) == "table" and elapsed_ns and elapsed_ns > 0 then
    for _, key in ipairs({ "correctable", "nonfatal", "fatal" }) do
      if type(aer[key]) == "table" and type(old[key]) == "table" then
        aer.interval_seconds = elapsed_ns / 1000000000
        break
      end
    end
  end
  for _, key in ipairs({ "correctable", "nonfatal", "fatal" }) do
    local current = aer[key]
    if type(current) == "table" then
      local earlier = type(old) == "table" and old[key] or nil
      current.change = aer_change(current.total,
        type(earlier) == "table" and earlier.total or nil, elapsed_ns)
    end
  end
  if type(aer.rootport) == "table" then
    aer.rootport.changes = {}
    for _, key in ipairs({ "correctable", "nonfatal", "fatal" }) do
      if aer.rootport[key] ~= nil then
        aer.rootport.changes[key] = aer_change(aer.rootport[key],
          type(old) == "table" and type(old.rootport) == "table"
            and old.rootport[key] or nil, elapsed_ns)
      end
    end
  end
end

local function attach_msi_counts(fs, devices, previous_pci, previous, context)
  local owners, wanted = {}, {}
  for _, device in ipairs(devices) do
    for _, vector in ipairs(device.msi and device.msi.vectors or {}) do
      wanted[vector.irq] = true
      if owners[vector.irq] == nil then owners[vector.irq] = device.address
      else owners[vector.irq] = false end
    end
  end
  if next(wanted) == nil then return end
  local content, failure = fs:read("/proc/interrupts", MAX_PROC_INTERRUPTS)
  local totals, source_status
  if content then
    totals, source_status = Parsers.proc_interrupts(content, wanted)
    if totals == nil then source_status = "error" end
  else
    source_status = FS.error_status(failure)
  end
  local sampled_ns = Common.now_ns(context)
  local elapsed_ns = previous and Common.elapsed_ns(sampled_ns, previous.timestamp_ns)
  for _, device in ipairs(devices) do
    local msi = device.msi
    if type(msi) == "table" and #msi.vectors > 0 then
      local sum, valid, failure_status, mixed = 0, 0, nil, false
      for _, vector in ipairs(msi.vectors) do
        local count
        if owners[vector.irq] == device.address and totals then
          count = totals[vector.irq]
        end
        local overflow = type(count) == "table" and count.total > math.maxinteger - sum
        if type(count) == "table" and not overflow then
          vector.total = count.total
          vector.top_cpus = count.top_cpus
          valid = valid + 1
          sum = sum + count.total
        else
          local status = (owners[vector.irq] == false or overflow) and "partial"
            or count == false and "partial"
            or source_status == "ok" and "unavailable"
            or source_status or "error"
          vector.count_status = status
          if failure_status and failure_status ~= status then mixed = true end
          failure_status = status
        end
      end
      if valid == #msi.vectors and msi.status == "ok" and source_status == "ok" then
        msi.total = sum
        msi.count_status = "ok"
      elseif valid == 0 and not mixed and msi.status == "ok"
          and source_status ~= "partial" then
        msi.count_status = failure_status or "unavailable"
      else
        msi.count_status = "partial"
      end
      local previous = previous_pci[device.address]
      local earlier = same_pci_identity(device, previous)
        and type(previous.msi) == "table" and previous.msi or nil
      local old_by_irq, comparable = {}, type(earlier) == "table"
        and earlier.status == "ok" and earlier.count_status == "ok"
        and type(earlier.vectors) == "table"
        and msi.status == "ok" and msi.count_status == "ok"
        and #earlier.vectors == #msi.vectors
        and elapsed_ns and elapsed_ns > 0
      if comparable then
        for _, old in ipairs(earlier.vectors) do old_by_irq[old.irq] = old end
        for _, vector in ipairs(msi.vectors) do
          local old = old_by_irq[vector.irq]
          if not old or old.mode ~= vector.mode then comparable = false break end
        end
      end
      local added, complete, reset = 0, comparable, false
      for _, vector in ipairs(msi.vectors) do
        local old = comparable and old_by_irq[vector.irq] or nil
        local change, delta_state
        if old then change, delta_state = Common.delta(vector.total, old.total) end
        if change ~= nil then
          vector.change = { quality = "fresh", new_interrupts = change }
          if change > math.maxinteger - added then complete = false
          else added = added + change end
        else
          vector.change = { quality = delta_state == "reset" and "reset" or "gap" }
          complete = false
          reset = reset or delta_state == "reset"
        end
      end
      msi.change = complete
        and { quality = "fresh", new_interrupts = added,
          interval_seconds = elapsed_ns / 1000000000 }
        or { quality = reset and "reset" or "gap" }
    end
  end
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
    source = path,
    parent_id = parent(link(fs, path), name),
    driver = driver(fs, path),
    speed_mbps = speed(fs, path .. "/speed"),
  }
end

local function read_usb_interface(fs, base, name)
  local path = base .. "/" .. name
  local number = hex_id(fs, path .. "/bInterfaceNumber")
  local named_number = tonumber(name:match(":%d+%.(%d+)$"))
  if not number or number > 255 or number ~= named_number then return nil end
  local class = hex_id(fs, path .. "/bInterfaceClass")
  local subclass = hex_id(fs, path .. "/bInterfaceSubClass")
  local protocol = hex_id(fs, path .. "/bInterfaceProtocol")
  local alternate = hex_id(fs, path .. "/bAlternateSetting")
  local endpoints = hex_id(fs, path .. "/bNumEndpoints")
  return {
    id = Common.safe_text(name, 64), interface_number = number,
    alternate_setting = alternate and alternate <= 255 and alternate or nil,
    endpoint_count = endpoints and endpoints <= 30 and endpoints or nil,
    class_id = class and class <= 255 and class or nil,
    subclass_id = subclass and subclass <= 255 and subclass or nil,
    protocol_id = protocol and protocol <= 255 and protocol or nil,
    interface = text(fs, path .. "/interface"),
    parent_id = parent(link(fs, path), name),
    driver = driver(fs, path), source = path,
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
  local usb_entries = fs:list(self.usb_base, MAX_USB_SCAN_ENTRIES + 1)
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

function Inventory:sample(context, previous)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local previous_data = Common.previous_data(previous)
  local previous_pci = {}
  for _, device in ipairs(previous_data and previous_data.pci
      and previous_data.pci.devices or {}) do
    if type(device.address) == "string" then previous_pci[device.address] = device end
  end

  local pci_entries, pci_list_error = fs:list(self.pci_base, MAX_PCI_DEVICES + 1)
  local usb_entries, _, usb_entries_truncated = fs:list(self.usb_base,
    MAX_USB_SCAN_ENTRIES + 1)
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
  local msi_budget = { remaining = MAX_MSI_VECTORS_TOTAL }
  local affinity_budget = { remaining = MAX_IRQ_AFFINITY_READS }
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
      local device = read_pci_device(self, fs, self.pci_base, address,
        msi_budget, affinity_budget)
      if device then pci_devices[#pci_devices + 1] = device end
    end
  end

  local usb_devices, usb_total, usb_truncated = {}, 0, false
  local iommu_groups = read_iommu_groups(fs, pci_devices)
  local usb_interfaces, usb_interface_total, usb_interfaces_truncated = {}, 0, false
  if usb_entries then
    local sorted = {}
    for _, name in ipairs(usb_entries) do sorted[#sorted + 1] = name end
    table.sort(sorted)
    for index, name in ipairs(sorted) do
      if index > MAX_USB_SCAN_ENTRIES then
        usb_entries_truncated = true
        break
      end
      if type(name) == "string" and (name:match("^usb%d+$")
          or name:match("^%d+%-%d+[%.%d]*$")) then
        local device = read_usb_device(fs, self.usb_base, name)
        if device then
          usb_total = usb_total + 1
          if #usb_devices >= MAX_USB_DEVICES then
            usb_truncated = true
          else
            usb_devices[#usb_devices + 1] = device
          end
        end
      elseif type(name) == "string"
          and name:match("^%d+%-%d+[%.%d]*:%d+%.%d+$") then
        local interface = read_usb_interface(fs, self.usb_base, name)
        if interface then
          usb_interface_total = usb_interface_total + 1
          if #usb_interfaces >= MAX_USB_INTERFACES then
            usb_interfaces_truncated = true
          else
            usb_interfaces[#usb_interfaces + 1] = interface
          end
        end
      end
    end
  end

  attach_msi_counts(fs, pci_devices, previous_pci, previous, context)
  local finished = Common.now_ns(context)
  local elapsed_ns = previous and Common.elapsed_ns(finished, previous.timestamp_ns)
  for _, device in ipairs(pci_devices) do
    attach_aer_changes(device, previous_pci[device.address], elapsed_ns)
  end
  if #pci_devices == 0 and #usb_devices == 0 and #usb_interfaces == 0 then
    return Common.result("unavailable", finished, nil, {
      quality = "unavailable",
      reason = "no_device_inventory",
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.pci_base,
    })
  end
  usb_truncated = usb_truncated or usb_entries_truncated == true
  usb_interfaces_truncated = usb_interfaces_truncated or usb_entries_truncated == true
  local truncated = pci_truncated or usb_truncated or usb_interfaces_truncated
  local quality = truncated and "truncated" or "fresh"
  return Common.result("ok", finished, {
    pci = { devices = pci_devices, iommu_groups = iommu_groups,
      total = pci_total, truncated = pci_truncated },
    usb = { devices = usb_devices, interfaces = usb_interfaces,
      total = usb_total, interface_total = usb_interface_total,
      truncated = usb_truncated, interfaces_truncated = usb_interfaces_truncated },
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
