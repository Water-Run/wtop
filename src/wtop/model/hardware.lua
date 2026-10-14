-- Shared hardware topology, built only from a snapshot.
-- No filesystem work or hardware probing belongs in this model.
local M = {}
local Quality = require("wtop.model.quality")
local GUID = require("wtop.core.guid")

local function identifier(value)
  return type(value) == "string" and value ~= "" and #value <= 4096 and value or nil
end

local function memory_slot_label(value)
  if not identifier(value) or #value > 256 then return nil end
  local label = value:match("^%s*(.-)%s*$"):gsub("[a-z]", function(character)
    return string.char(character:byte() - 32)
  end)
  if label == "" or label == "UNKNOWN" or label == "NONE"
      or label == "N/A" or label == "NOT SPECIFIED" then return nil end
  return label
end

local function pci_address(value)
  return identifier(value) and value:match("^%x+:%x%x:%x%x%.[0-7]$") and value:lower() or nil
end

local function pnp_identity(value)
  if not identifier(value) then return nil end
  return value:gsub("[a-z]", function(character)
    return string.char(character:byte() - 32)
  end)
end

local function registry_identity(value)
  return type(value) == "string" and #value <= 26
    and value:match("^ioreg:[1-9]%d*$") and value or nil
end

local function iommu_group_id(value)
  return type(value) == "number" and math.type(value) == "integer"
    and value >= 0 and value <= 2147483647 and value or nil
end

local function resource_id(value)
  if type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0 then
    return tostring(value)
  end
  return identifier(value)
end

local function device_path(value)
  if not identifier(value) or not value:match("^/sys/devices/.")
      or value:find("/%.%./") or value:find("/%./") or value:find("/%.?%.$") then return nil end
  return value
end

-- Match the most specific bus device named by a kernel path. An unlisted USB
-- child must not donate its temperature to the PCI controller above it.
function M.target_id(target, known)
  if not identifier(target) then return nil end
  local result
  for component in target:gmatch("[^/]+") do
    if component:match("^i2c%-%d+$") then return nil end
    local address = pci_address(component)
    local interface = component:match("^(%d+%-%d+[%.%d]*:%d+%.%d+)$")
    local usb = component:match("^(%d+%-%d+[%.%d]*)[:%d%.]*$")
      or component:match("^(usb%d+)$")
    if address then result = "pci:" .. address
    elseif interface and known and known["usb-interface:" .. interface] then
      result = "usb-interface:" .. interface
    elseif usb then result = "usb:" .. usb end
  end
  return result
end

local KIND_LABELS = {
    package = { "inventory.cpu_package", "CPU package {id}" },
    core = { "inventory.cpu_core", "CPU core {id}" },
    thread = { "inventory.cpu_thread", "Logical CPU {id}" },
    numa = { "inventory.numa", "NUMA node {id}" },
    policy = { "inventory.frequency_policy", "Frequency policy {id}" },
    memory_array = { "memory_hw.array", "Memory array {id}" },
    memory_array_range = { "memory_hw.array_range", "Array address range {id}" },
    memory_device_range = { "memory_hw.device_range", "Device address range {id}" },
    edac_controller = { "edac.controller", "Memory controller {id}" },
    edac_module = { "edac.module", "EDAC module {id}" },
    spd_device = { "spd.device", "SPD device {id}" },
    memory_channel = { "memory_hw.channel", "Memory channel {id}" },
    usb_interface = { "inventory.usb_interface", "USB interface {id}" },
    expansion_slot = { "slot.device", "Expansion slot {id}" },
    port_connector = { "port.connector", "Port connector {id}" },
    onboard_device = { "onboard.device", "Onboard device {id}" },
    firmware_battery = { "firmware_battery.device", "Firmware battery {id}" },
    firmware_power_supply = { "firmware_psu.device", "Firmware power supply {id}" },
    firmware_bmc = { "firmware_bmc.device", "Firmware BMC interface {id}" },
    firmware_tpm = { "firmware_tpm.device", "Firmware TPM {id}" },
    firmware_component = { "firmware_component.device", "Firmware component {id}" },
    esrt_firmware = { "firmware_esrt.device", "UEFI firmware resource {id}" },
    os_tpm = { "tpm.device", "OS TPM {id}" },
    watchdog = { "watchdog.device", "Watchdog {id}" },
    rfkill = { "rfkill.device", "RF switch {id}" },
    thermal_zone = { "thermal_zone.device", "Thermal zone {id}" },
    cooling_device = { "cooling_device.device", "Cooling device {id}" },
    host_interface = { "host_interface.device", "Management host interface {id}" },
    processor_socket = { "processor_fw.socket", "Firmware CPU socket {id}" },
    firmware_cache = { "processor_fw.cache", "Firmware cache {id}" },
}

function M.label(node, i18n)
  local device = node.device
  if node.kind == "edac_module" and identifier(device.label) then return device.label end
  if node.kind == "usb_interface" and identifier(device.interface) then return device.interface end
  if node.kind == "spd_device" and identifier(device.part_number) then return device.part_number end
  if node.kind == "expansion_slot" and identifier(device.designation) then return device.designation end
  if node.kind == "port_connector" then
    local label = identifier(device.external_designation)
      or identifier(device.internal_designation)
    if label then return label end
  end
  if node.kind == "onboard_device" and identifier(device.designation) then return device.designation end
  if node.kind == "firmware_battery" then
    local label = identifier(device.name) or identifier(device.location)
    if label then return label end
  end
  if node.kind == "firmware_power_supply" then
    local label = identifier(device.name) or identifier(device.location)
    if label then return label end
  end
  if node.kind == "firmware_tpm" and identifier(device.description) then
    return device.description
  end
  if node.kind == "firmware_component" and identifier(device.name) then return device.name end
  if node.kind == "esrt_firmware" and GUID.normalize(device.guid) then
    return (device.type or "UEFI firmware") .. " · " .. device.guid
  end
  if node.kind == "watchdog" and identifier(device.identity) then
    return device.identity .. " (" .. tostring(device.id) .. ")"
  end
  if node.kind == "rfkill" and identifier(device.name) then
    return device.name .. " (" .. tostring(device.id) .. ")"
  end
  if (node.kind == "thermal_zone" or node.kind == "cooling_device")
      and identifier(device.type) then
    return device.type .. " (" .. tostring(device.id) .. ")"
  end
  if node.kind == "host_interface" and identifier(device.interface_type) then
    return device.interface_type .. " #" .. tostring(device.id)
  end
  if node.kind == "processor_socket" and identifier(device.designation) then
    local label = KIND_LABELS.processor_socket
    local text = i18n and i18n:t(label[1], { id = device.designation })
    if text and text ~= label[1] then return text end
    return label[2]:gsub("{id}", function() return device.designation end)
  end
  if node.kind == "firmware_cache" and identifier(device.designation) then return device.designation end
  local label = KIND_LABELS[node.kind]
  if label then
    local id = device.policy or device.id
    local text = i18n and i18n:t(label[1], { id = id })
    if text and text ~= label[1] then return text end
    return label[2]:gsub("{id}", function() return tostring(id) end)
  end
  if node.kind == "memory_device" then
    return identifier(device.part_number) or identifier(device.locator) or node.identifier
  end
  if node.bus == "block" then
    local identity = type(device.identity) == "table" and device.identity or {}
    local stack = type(device.stack) == "table" and device.stack or {}
    return identifier(stack.name) or identifier(identity.model) or node.identifier
  elseif node.bus == "net" then
    return node.identifier
  end
  local vendor = node.bus == "pci" and device.vendor_name or device.manufacturer
  local name = node.bus == "pci" and device.device_name or device.product
  vendor = type(vendor) == "string" and vendor
    or (type(device.vendor_id) == "number" and string.format("%04x", device.vendor_id) or "?")
  return vendor .. (type(name) == "string" and name ~= "" and " " .. name or "")
end

function M.build(snapshot)
  snapshot = type(snapshot) == "table" and snapshot or {}
  local inventory = type(snapshot.inventory) == "table" and snapshot.inventory or {}
  local result = { nodes = {}, by_id = {}, iommu_groups_by_id = {},
    truncated = false, partial = inventory.quality == "partial" }
  local unsorted = {}
  local pnp_nodes = {}
  local registry_nodes = {}
  local function add_node(bus, name, device, id, parent, resource, reference)
    if result.by_id[id] then
      result.partial = true
      result.by_id[id].ambiguous = true
      return
    end
    local node = { id = id, bus = bus, identifier = name, device = device,
      parent_id = parent, resource = resource, resource_id = reference,
      children = {}, sensors = {}, sensor_ids = {}, gpu_ids = {},
      mounts = {}, mount_ids = {}, cpu_ids = {}, numa_node_ids = {}, cpufreq_ids = {},
      thermal_throttle_cpu_ids = {}, cpuidle_cpu_ids = {},
      cooling_ids = {}, thermal_zone_ids = {},
      pci_ids = {}, vf_ids = {}, iommu_peer_ids = {}, slot_ids = {}, onboard_ids = {},
      cache_ids = {}, firmware_socket_ids = {},
      mapped_range_ids = {}, channel_ids = {}, memory_device_ids = {},
      redundant_peer_ids = {}, slave_ids = {}, holder_ids = {},
      associated_ids = {}, firmware_component_ids = {}, esrt_ids = {} }
    result.by_id[id] = node
    unsorted[#unsorted + 1] = node
    return node
  end
  for _, bus in ipairs({ { "pci", "address", "parent_address", 256 },
                          { "usb", "id", "parent_id", 128 } }) do
    local section = type(inventory[bus[1]]) == "table" and inventory[bus[1]] or {}
    result.truncated = result.truncated or section.truncated == true
    for index, device in ipairs(type(section.devices) == "table" and section.devices or {}) do
      if index > bus[4] then result.truncated = true break end
      if type(device) == "table" then
        local name = identifier(device[bus[2]])
        if name then
          if bus[1] == "pci" then name = pci_address(name) or name end
          local id = bus[1] .. ":" .. name
          local parent = identifier(device[bus[3]])
          local parent_bus = bus[1]
          if parent and device.parent_bus ~= nil then
            -- Windows identifies a controller by bus:slot.function or an
            -- instance ID. Neither implies a PCI domain or a parent bus.
            if device.parent_bus == "pci" or device.parent_bus == "usb" then
              parent_bus = device.parent_bus
              if parent_bus == "pci" then parent = pci_address(parent) or parent end
            else
              parent, result.partial = nil, true
            end
          elseif parent and pci_address(parent) then
            parent_bus, parent = "pci", pci_address(parent)
          end
          local node = add_node(bus[1], name, device, id,
            parent and parent_bus .. ":" .. parent or nil)
          local pnp = pnp_identity(device._pnp_instance_id)
          if pnp and node then
            if pnp_nodes[pnp] ~= nil then
              pnp_nodes[pnp], result.partial = false, true
            else pnp_nodes[pnp] = node end
          end
          local registry = registry_identity(device._registry_entry_id)
          if registry and node then
            if registry_nodes[registry] ~= nil then
              registry_nodes[registry], result.partial = false, true
            else registry_nodes[registry] = node end
          end
        else
          result.partial = true
        end
      end
    end
  end
  local function registry_parent(node, device, resource)
    local parent = registry_identity(device._registry_parent_id)
    if not parent or node.ambiguous then
      if device._registry_parent_id ~= nil then
        node.parent_id, result.partial = nil, true
      end
      return
    end
    local target = registry_nodes[parent]
    if Quality.current_source(snapshot.quality, "inventory")
        and Quality.current_source(snapshot.quality, resource)
        and target and not target.ambiguous
        and (device._registry_parent_bus == "pci" or device._registry_parent_bus == "usb")
        and target.bus == device._registry_parent_bus then
      node.parent_id = target.id
    else node.parent_id, result.partial = nil, true end
  end
  for _, node in ipairs(unsorted) do
    registry_parent(node, node.device, "inventory")
  end
  local pci_inventory = type(inventory.pci) == "table" and inventory.pci or {}
  for _, group in ipairs(type(pci_inventory.iommu_groups) == "table"
      and pci_inventory.iommu_groups or {}) do
    local id = type(group) == "table" and iommu_group_id(group.id) or nil
    if id and result.iommu_groups_by_id[id] == nil then
      result.iommu_groups_by_id[id] = group
    else
      result.partial = true
      if id then result.iommu_groups_by_id[id] = false end
    end
  end
  -- A group is a cross-reference, not a PCI bus parent. Its sysfs member list
  -- can include non-PCI devices; peer IDs name only PCI nodes visible here.
  local iommu_nodes = {}
  for _, node in ipairs(unsorted) do
    if node.bus == "pci" then
      local raw_id = node.device.iommu_group_id
      local id = iommu_group_id(raw_id)
      if raw_id ~= nil and not id then result.partial = true end
      if id and not node.ambiguous then
        node.iommu_group_id = id
        iommu_nodes[id] = iommu_nodes[id] or {}
        iommu_nodes[id][#iommu_nodes[id] + 1] = node
        local group = result.iommu_groups_by_id[id]
        if type(group) == "table" and type(group.members) == "table" then
          local found = false
          for _, member in ipairs(group.members) do
            if pci_address(member) == node.identifier then found = true break end
          end
          node.iommu_group_membership_confirmed = found
          if not found then result.partial = true end
        end
        if type(group) ~= "table" or group.status ~= "ok" then
          result.partial = true
        end
      end
    end
  end
  for _, members in pairs(iommu_nodes) do
    table.sort(members, function(a, b) return a.id < b.id end)
    for _, node in ipairs(members) do
      for _, peer in ipairs(members) do
        if peer ~= node then node.iommu_peer_ids[#node.iommu_peer_ids + 1] = peer.id end
      end
    end
  end
  -- SR-IOV is a function relationship, not physical PCI bus containment.
  -- Keep the bridge-derived parent_id intact and cross-link only a VF whose
  -- kernel physfn target names one unambiguous PCI function in this snapshot.
  for _, node in ipairs(unsorted) do
    local sriov = node.bus == "pci" and type(node.device.sriov) == "table"
      and node.device.sriov or nil
    if sriov and sriov.role == "vf" and not node.ambiguous then
      local address = pci_address(sriov.physical_function_address)
      local pf = address and result.by_id["pci:" .. address]
      local pf_sriov = pf and type(pf.device.sriov) == "table" and pf.device.sriov
      if pf and pf ~= node and not pf.ambiguous and pf.bus == "pci"
          and not (pf_sriov and (pf_sriov.role == "vf"
            or pf_sriov.role == "ambiguous")) then
        node.pf_id = pf.id
        pf.vf_ids[#pf.vf_ids + 1] = node.id
        if not pf_sriov then result.partial = true end
      else result.partial = true end
    elseif sriov and sriov.role == "ambiguous" then
      result.partial = true
    end
  end
  for _, node in ipairs(unsorted) do
    if node.bus == "pci" then
      table.sort(node.vf_ids)
      local sriov = type(node.device.sriov) == "table" and node.device.sriov or nil
      if sriov and sriov.role == "pf" then
        node.sriov_membership_complete = sriov.status == "ok"
          and type(sriov.enabled_vfs) == "number"
          and #node.vf_ids == sriov.enabled_vfs
        if not node.sriov_membership_complete then result.partial = true end
      end
    end
  end
  local usb = type(inventory.usb) == "table" and inventory.usb or {}
  result.truncated = result.truncated or usb.interfaces_truncated == true
  for index, device in ipairs(type(usb.interfaces) == "table" and usb.interfaces or {}) do
    if index > 256 then result.truncated = true break end
    local id = type(device) == "table" and identifier(device.id)
    if id and id:match("^%d+%-%d+[%.%d]*:%d+%.%d+$") then
      local parent = identifier(device.parent_id)
      local node = add_node("usb", id, device, "usb-interface:" .. id,
        parent and "usb:" .. parent or nil, "inventory", id)
      if node then node.kind = "usb_interface" end
    else result.partial = true end
  end
  local blocks_by_path, blocks_by_id, blocks_by_name = {}, {}, {}
  local function index_unique(index, key, node)
    if not key or not node then return end
    if index[key] ~= nil then
      index[key] = false
      result.partial = true
    else
      index[key] = node
    end
  end
  for _, source in ipairs({ { "block", "disks", "devices", 256 },
                            { "net", "network", "interfaces", 128 } }) do
    local section = type(snapshot[source[2]]) == "table" and snapshot[source[2]] or {}
    result.truncated = result.truncated or section.truncated == true
    for index, device in ipairs(type(section[source[3]]) == "table" and section[source[3]] or {}) do
      if index > source[4] then result.truncated = true break end
      if type(device) == "table" then
        local name = identifier(device.name)
        local reference = resource_id(device.id)
        local identity = source[1] == "block" and identifier(device.stable_id) or nil
        identity = identity or reference or name
        if name and identity then
          local path = device_path(device.device_path)
          local node = add_node(source[1], name, device, source[1] .. ":" .. identity,
            M.target_id(path and path:match("^(.*)/[^/]+$"), result.by_id),
            source[2], device.id or name)
          local pnp_parent = pnp_identity(device._pnp_parent_id)
          if node and pnp_parent then
            local target = pnp_nodes[pnp_parent]
            if Quality.current_source(snapshot.quality, "inventory")
                and Quality.current_source(snapshot.quality, source[2])
                and target and not target.ambiguous
                and (device._pnp_parent_bus == "pci" or device._pnp_parent_bus == "usb")
                and target.bus == device._pnp_parent_bus then
              node.parent_id = target.id
            else result.partial = true end
          end
          if node then registry_parent(node, device, source[2]) end
          if source[1] == "block" then
            index_unique(blocks_by_path, path, node)
            index_unique(blocks_by_id, reference, node)
            index_unique(blocks_by_name, name, node)
          end
        else
          result.partial = true
        end
      end
    end
  end
  for _, node in ipairs(unsorted) do
    if node.bus == "block" and node.device.is_partition then
      local path = device_path(node.device.device_path)
      while path do
        path = path:match("^(.*)/[^/]+$")
        local parent = blocks_by_path[path]
        if parent ~= nil then
          if parent and not parent.ambiguous then node.parent_id = parent.id
          else node.parent_id = nil end
          break
        end
      end
    end
  end
  -- A holder depends on its sysfs slaves. These are references, not physical
  -- parents: a dm/md device can consume partitions from several disks. Resolve
  -- the whole declared set or none of it, using device numbers read through
  -- the slave links rather than guessing from their names alone.
  if Quality.current_source(snapshot.quality, "disks") then
    for _, node in ipairs(unsorted) do
      if node.bus == "block" and node.device.stacked == true then
        local refs = node.device.slave_refs
        if node.ambiguous or node.device.slave_refs_complete ~= true
            or type(refs) ~= "table" or #refs == 0 then
          result.partial = true
        elseif #refs > 256 then
          result.partial, result.truncated = true, true
        else
          local targets, seen, complete = {}, {}, true
          for _, reference in ipairs(refs) do
            local key = type(reference) == "table" and identifier(reference.device_id)
            local target = key and blocks_by_id[key]
            if not target or target == node or target.ambiguous
                or target.bus ~= "block" or target.identifier ~= reference.name
                or blocks_by_name[reference.name] ~= target
                or seen[target.id] then
              complete = false
              break
            end
            seen[target.id] = true
            targets[#targets + 1] = target
          end
          if complete then
            for _, target in ipairs(targets) do
              node.slave_ids[#node.slave_ids + 1] = target.id
              target.holder_ids[#target.holder_ids + 1] = node.id
            end
          else result.partial = true end
        end
      end
    end
    for _, node in ipairs(unsorted) do
      table.sort(node.slave_ids)
      table.sort(node.holder_ids)
    end
  end
  -- CPU packages/cores describe physical containment. NUMA and frequency
  -- policies describe overlapping sets, so their memberships remain links.
  local cpu_info = type(snapshot.cpu_info) == "table" and snapshot.cpu_info or {}
  local topology = type(cpu_info.topology) == "table" and cpu_info.topology or {}
  local function numeric_id(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0
      and value <= 2147483647 and value or nil
  end
  local function cpu_list(list)
    local result_ids, seen = {}, {}
    local complete = type(list) == "table"
    for index, id in ipairs(type(list) == "table" and list or {}) do
      if index > 512 then result.truncated = true; complete = false; break end
      if numeric_id(id) and not seen[id] then
        seen[id] = true
        result_ids[#result_ids + 1] = id
      elseif not numeric_id(id) then
        complete = false
      end
    end
    return result_ids, complete
  end
  local cpus, groups = {}, {}
  result.truncated = result.truncated or topology.truncated == true
  for index, cpu in ipairs(type(topology.logical_cpus) == "table" and topology.logical_cpus or {}) do
    if index > 512 then result.truncated = true break end
    if type(cpu) == "table" and numeric_id(cpu.id) then
      local package_node, parent
      local known = cpu.package_id_known ~= false
        and (cpu.package_id_known == true or topology.quality ~= "estimated")
      if known and numeric_id(cpu.package_id) then
        local id = "package:" .. cpu.package_id
        package_node = result.by_id[id]
        if not package_node then
          package_node = add_node("cpu", "package" .. cpu.package_id,
            { id = cpu.package_id, source = cpu.source }, id, nil, "cpu_info")
          package_node.kind = "package"
          groups[#groups + 1] = package_node
        end
        parent = package_node
        if cpu.core_id_known ~= false and numeric_id(cpu.core_id) and identifier(cpu.core_key) then
          local core_id = "core:" .. cpu.core_key
          parent = result.by_id[core_id]
          if not parent then
            parent = add_node("cpu", cpu.core_key, { id = cpu.core_id, source = cpu.source },
              core_id, package_node.id, "cpu_info")
            parent.kind = "core"
            groups[#groups + 1] = parent
          end
          if parent.parent_id == package_node.id then
            parent.cpu_ids[#parent.cpu_ids + 1] = cpu.id
          else
            result.partial = true
            parent = package_node
          end
        end
        package_node.cpu_ids[#package_node.cpu_ids + 1] = cpu.id
      end
      local node = add_node("cpu", "cpu" .. cpu.id, cpu, "cpu:" .. cpu.id,
        parent and parent.id, "cpu_info", cpu.id)
      if node then
        node.kind, node.cpu_ids = "thread", { cpu.id }
        node.package_id = package_node and package_node.id
        cpus[cpu.id] = node
      end
    end
  end
  -- Thermal-throttle counters are reported per logical CPU. Package counters
  -- repeat on siblings, so this is a set of references rather than a sum.
  local thermal = type(snapshot.thermal_throttle) == "table" and snapshot.thermal_throttle or {}
  if Quality.current_source(snapshot.quality, "thermal_throttle") then
    result.truncated = result.truncated or thermal.truncated == true
    local reports = {}
    for index, report in ipairs(type(thermal.cpus) == "table" and thermal.cpus or {}) do
      if index > 512 then result.truncated = true break end
      local id = type(report) == "table" and numeric_id(report.id)
      if id then
        if reports[id] ~= nil then reports[id] = false; result.partial = true
        else reports[id] = report end
      else result.partial = true end
    end
    for id, node in pairs(cpus) do
      local report = reports[id]
      if type(report) == "table" and not node.ambiguous
          and (report.core_count ~= nil or report.package_count ~= nil) then
        node.thermal_throttle = report
        node.thermal_throttle_cpu_ids[1] = id
        local ancestor = result.by_id[node.parent_id]
        while ancestor and (ancestor.kind == "core" or ancestor.kind == "package") do
          ancestor.thermal_throttle_cpu_ids[#ancestor.thermal_throttle_cpu_ids + 1] = id
          ancestor = result.by_id[ancestor.parent_id]
        end
      end
    end
    for _, node in ipairs(groups) do table.sort(node.thermal_throttle_cpu_ids) end
  end
  -- CPUIdle reports belong to logical CPUs. Keep package and core links as
  -- coverage references; reported time is not a hardware residency counter
  -- and must not be summed across siblings.
  local cpuidle = type(snapshot.cpuidle) == "table" and snapshot.cpuidle or {}
  if Quality.current_source(snapshot.quality, "cpuidle") then
    result.truncated = result.truncated or cpuidle.truncated == true
    local reports = {}
    for index, report in ipairs(type(cpuidle.cpus) == "table" and cpuidle.cpus or {}) do
      if index > 512 then result.truncated = true break end
      local id = type(report) == "table" and numeric_id(report.id)
      if id then
        if reports[id] ~= nil then reports[id] = false; result.partial = true
        else reports[id] = report end
      else result.partial = true end
    end
    for id, node in pairs(cpus) do
      local report = reports[id]
      if type(report) == "table" and not node.ambiguous
          and type(report.states) == "table" and #report.states > 0 then
        node.cpuidle = report
        node.cpuidle_cpu_ids[1] = id
        local ancestor = result.by_id[node.parent_id]
        while ancestor and (ancestor.kind == "core" or ancestor.kind == "package") do
          ancestor.cpuidle_cpu_ids[#ancestor.cpuidle_cpu_ids + 1] = id
          ancestor = result.by_id[ancestor.parent_id]
        end
      end
    end
    for _, node in ipairs(groups) do table.sort(node.cpuidle_cpu_ids) end
  end
  local numa = type(snapshot.numa) == "table" and snapshot.numa or {}
  result.truncated = result.truncated or numa.truncated == true
  for index, device in ipairs(type(numa.nodes) == "table" and numa.nodes or {}) do
    if index > 128 then result.truncated = true break end
    if type(device) == "table" and numeric_id(device.id) then
      local node = add_node("numa", "node" .. device.id, device,
        "numa:" .. device.id, nil, "numa", device.id)
      if node then node.kind, node.cpu_ids = "numa", cpu_list(device.cpu_ids) end
    end
  end
  -- Resolve memberships after all identities are known, including duplicates.
  for _, node in ipairs(unsorted) do
    if node.kind == "numa" and not node.ambiguous then
      for _, cpu_id in ipairs(node.cpu_ids) do
        local cpu = cpus[cpu_id]
        if cpu and not cpu.ambiguous then
          cpu.numa_node_ids[#cpu.numa_node_ids + 1] = node.device.id
          if #cpu.numa_node_ids > 1 then result.partial = true end
        end
      end
    elseif node.bus == "pci" then
      local id = numeric_id(node.device.numa_node)
      local target = id and result.by_id["numa:" .. id]
      if target and not target.ambiguous then node.numa_node_ids = { id } end
    end
  end
  local frequencies = type(snapshot.cpu_frequency) == "table" and snapshot.cpu_frequency or {}
  result.truncated = result.truncated or frequencies.truncated == true
  for index, device in ipairs(type(frequencies.policies) == "table" and frequencies.policies or {}) do
    if index > 128 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local node = add_node("freq", device.policy or device.id, device,
        "cpufreq:" .. device.id, nil, "cpu_frequency", device.id)
      if node then
        local related = type(device.related_cpus) == "table" and device.related_cpus or {}
        node.cpu_ids, node.membership_complete = cpu_list(#related > 0 and related or device.affected_cpus)
        node.kind = "policy"
      end
    else
      result.partial = true
    end
  end
  local function collect_memberships(node, include_policies)
    local seen_numa, seen_policy = {}, {}
    for _, id in ipairs(node.cpu_ids) do
      local cpu = cpus[id]
      if cpu and not cpu.ambiguous then
        for _, nid in ipairs(cpu.numa_node_ids) do seen_numa[nid] = true end
        if include_policies then
          for _, pid in ipairs(cpu.cpufreq_ids) do seen_policy[pid] = true end
        end
      end
    end
    for id in pairs(seen_numa) do node.numa_node_ids[#node.numa_node_ids + 1] = id end
    for id in pairs(seen_policy) do node.cpufreq_ids[#node.cpufreq_ids + 1] = id end
    table.sort(node.numa_node_ids)
    table.sort(node.cpufreq_ids)
  end
  for _, node in ipairs(unsorted) do
    if node.kind == "policy" and not node.ambiguous then
      local package_id, complete = nil, #node.cpu_ids > 0 and node.membership_complete
      for _, id in ipairs(node.cpu_ids) do
        local cpu = cpus[id]
        if cpu and not cpu.ambiguous then
          cpu.cpufreq_ids[#cpu.cpufreq_ids + 1] = node.device.id
          if not cpu.package_id or package_id and package_id ~= cpu.package_id then complete = false end
          package_id = package_id or cpu.package_id
        else complete = false end
      end
      if complete then node.parent_id = package_id end
      collect_memberships(node)
    end
  end
  for _, node in ipairs(groups) do collect_memberships(node, true) end
  local memory = type(snapshot.memory_devices) == "table" and snapshot.memory_devices or {}
  result.truncated = result.truncated or memory.truncated == true
  result.partial = result.partial or memory.partial == true
  for _, section in ipairs({ { "arrays", "memory-array:", "memory_array", 64 },
                              { "devices", "dimm:", "memory_device", 256 },
                              { "array_ranges", "memory-array-range:", "memory_array_range", 256 },
                              { "device_ranges", "memory-device-range:", "memory_device_range", 512 },
                              { "channels", "memory-channel:", "memory_channel", 64 } }) do
    for index, device in ipairs(type(memory[section[1]]) == "table" and memory[section[1]] or {}) do
      if index > section[4] then result.truncated = true break end
      if type(device) == "table" and identifier(device.id) then
        local parent = identifier(device.array_id)
        local parent_prefix = "memory-array:"
        if section[1] == "device_ranges" then
          parent, parent_prefix = identifier(device.array_range_id), "memory-array-range:"
        end
        local node = add_node("mem", device.locator or ("0x" .. device.id), device,
          section[2] .. device.id, parent and parent_prefix .. parent or nil,
          "memory_devices", device.id)
        if node then
          node.kind = section[3]
          if device.ambiguous then node.ambiguous = true; result.partial = true end
        end
      end
    end
  end
  for _, node in ipairs(unsorted) do
    if node.kind == "memory_array_range" and not node.ambiguous and node.parent_id then
      local parent = result.by_id[node.parent_id]
      if parent and parent.kind == "memory_array" and not parent.ambiguous then
        parent.mapped_range_ids[#parent.mapped_range_ids + 1] = node.id
      else node.parent_id = nil; result.partial = true end
    elseif node.kind == "memory_device_range" and not node.ambiguous
        and node.parent_id and identifier(node.device.device_id) then
      local parent = result.by_id[node.parent_id]
      local dimm = result.by_id["dimm:" .. node.device.device_id]
      if parent and parent.kind == "memory_array_range" and not parent.ambiguous
          and dimm and dimm.kind == "memory_device" and not dimm.ambiguous
          and parent.device.array_id == dimm.device.array_id then
        node.memory_device_id = dimm.id
        dimm.mapped_range_ids[#dimm.mapped_range_ids + 1] = node.id
      else node.parent_id = nil; result.partial = true end
    end
  end
  for _, node in ipairs(unsorted) do table.sort(node.mapped_range_ids) end
  local channels = type(memory.channels) == "table" and memory.channels or {}
  if memory.truncated ~= true and #channels <= 64
      and Quality.current_source(snapshot.quality, "memory_devices") then
    for _, node in ipairs(unsorted) do
      if node.kind == "memory_channel" and not node.ambiguous
          and node.device.quality == "fresh" then
        local entries = type(node.device.devices) == "table" and node.device.devices or {}
        local expected = node.device.device_count
        local targets, seen, total_load = {}, {}, 0
        local complete = math.type(expected) == "integer" and expected == #entries
          and expected <= 64 and math.type(node.device.maximum_load) == "integer"
          and node.device.maximum_load >= 0
        if complete then
          for _, entry in ipairs(entries) do
            local id = type(entry) == "table" and identifier(entry.device_id) or nil
            local target = id and result.by_id["dimm:" .. id]
            local load = entry and entry.load
            if not target or target.kind ~= "memory_device" or target.ambiguous
                or target.device.quality ~= "fresh" or seen[id]
                or math.type(load) ~= "integer" or load < 1 or load > 255 then
              complete = false
              break
            end
            seen[id] = true
            total_load = total_load + load
            targets[#targets + 1] = target
          end
          if total_load > node.device.maximum_load then complete = false end
        end
        if complete then
          for _, target in ipairs(targets) do
            node.memory_device_ids[#node.memory_device_ids + 1] = target.id
            target.channel_ids[#target.channel_ids + 1] = node.id
          end
        else result.partial = true end
      end
    end
  end
  for _, node in ipairs(unsorted) do
    table.sort(node.channel_ids)
    table.sort(node.memory_device_ids)
  end
  local edac = type(snapshot.edac) == "table" and snapshot.edac or {}
  result.truncated = result.truncated or edac.truncated == true
  for index, controller in ipairs(type(edac.controllers) == "table" and edac.controllers or {}) do
    if index > 64 then result.truncated = true break end
    if type(controller) == "table" and identifier(controller.id) then
      local parent = add_node("edac", controller.id, controller, "edac:" .. controller.id,
        nil, "edac", controller.id)
      if parent then
        parent.kind = "edac_controller"
        for module_index, module in ipairs(type(controller.modules) == "table" and controller.modules or {}) do
          if module_index > 256 then result.truncated = true break end
          if type(module) == "table" and identifier(module.id)
              and module.id:sub(1, #controller.id + 1) == controller.id .. "/" then
            local child = add_node("edac", module.id, module, "edac:" .. module.id,
              parent.id, "edac", module.id)
            if child then child.kind = "edac_module" end
          else result.partial = true end
        end
      end
    else result.partial = true end
  end
  -- An EDAC label is not a hardware address. Relate it to a populated SMBIOS
  -- slot only when the same non-placeholder label occurs exactly once in each
  -- source. Keep EDAC's controller parent; this is a cross-reference, not a
  -- claim that the two providers have verified physical identity.
  local memory_devices = type(memory.devices) == "table" and memory.devices or {}
  local edac_controllers = type(edac.controllers) == "table" and edac.controllers or {}
  local complete_labels = memory.truncated ~= true and edac.truncated ~= true
    and #memory_devices <= 256 and #edac_controllers <= 64
  for _, controller in ipairs(edac_controllers) do
    if type(controller) ~= "table" or type(controller.modules) ~= "table"
        or #controller.modules > 256 then complete_labels = false; break end
  end
  if complete_labels and Quality.current_source(snapshot.quality, "memory_devices")
      and Quality.current_source(snapshot.quality, "edac") then
    local firmware_labels, edac_labels = {}, {}
    local function index_label(index, label, node, eligible)
      if label then
        if index[label] == nil then index[label] = eligible and node or false
        else index[label] = false end
      end
    end
    for _, node in ipairs(unsorted) do
      if node.kind == "memory_device" then
        index_label(firmware_labels, memory_slot_label(node.device.locator), node,
          not node.ambiguous and node.device.populated == true)
      elseif node.kind == "edac_module" then
        index_label(edac_labels, memory_slot_label(node.device.label), node,
          not node.ambiguous and node.device.kind == "dimm")
      end
    end
    for label, dimm in pairs(firmware_labels) do
      local module = edac_labels[label]
      if dimm and module then
        dimm.edac_module_id = module.id
        module.memory_device_id = dimm.id
        dimm.match_method, module.match_method = "unique_label", "unique_label"
      end
    end
  end
  local spd = type(snapshot.spd) == "table" and snapshot.spd or {}
  result.truncated = result.truncated or spd.truncated == true
  for index, device in ipairs(type(spd.devices) == "table" and spd.devices or {}) do
    if index > 64 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id)
        and device.id:match("^%d+%-%x%x%x%x$") then
      local node = add_node("spd", device.id, device, "spd:" .. device.id,
        nil, "spd", device.id)
      if node then node.kind = "spd_device" end
    else result.partial = true end
  end
  local slots = type(snapshot.expansion_slots) == "table" and snapshot.expansion_slots or {}
  result.truncated = result.truncated or slots.truncated == true
  for index, device in ipairs(type(slots.slots) == "table" and slots.slots or {}) do
    if index > 128 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local node = add_node("slot", device.designation or device.id, device,
        "slot:" .. device.id, nil, "expansion_slots", device.id)
      if node then node.kind = "expansion_slot" end
    else result.partial = true end
  end
  -- A firmware BDF is a reference, not physical containment. Firmware may
  -- report an upstream port even when the slot holds a downstream endpoint.
  local claims = {}
  for _, node in ipairs(unsorted) do
    if node.kind == "expansion_slot" and not node.ambiguous
        and node.device.quality ~= "partial" and node.device.usage_code == 4 then
      local seen = {}
      local addresses = { node.device.pci_bdf }
      for _, address in ipairs(type(node.device.peer_bdfs) == "table"
          and node.device.peer_bdfs or {}) do addresses[#addresses + 1] = address end
      for _, address in ipairs(addresses) do
        address = pci_address(address)
        if address and not seen[address] then
          seen[address] = true
          local target = result.by_id["pci:" .. address]
          if target and not target.ambiguous then
            if claims[address] ~= nil then claims[address] = false; result.partial = true
            else claims[address] = node end
          end
        end
      end
    end
  end
  for address, slot in pairs(claims) do
    if slot then
      local target = result.by_id["pci:" .. address]
      slot.pci_ids[#slot.pci_ids + 1] = address
      target.slot_ids[#target.slot_ids + 1] = slot.id
    end
  end
  for _, node in ipairs(unsorted) do
    table.sort(node.pci_ids)
    table.sort(node.slot_ids)
  end
  -- Type 41 names a PCI function directly; Type 10 has no device address.
  -- Keep both firmware declarations as
  -- its own node: the BDF is a cross-reference, not a containment edge. A
  -- truncated declaration list cannot prove that a BDF is claimed uniquely.
  local onboard = type(snapshot.onboard_devices) == "table" and snapshot.onboard_devices or {}
  local ports = type(snapshot.port_connectors) == "table" and snapshot.port_connectors or {}
  result.truncated = result.truncated or ports.truncated == true
  result.partial = result.partial or ports.partial == true
  for index, device in ipairs(type(ports.ports) == "table" and ports.ports or {}) do
    if index > 128 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local node = add_node("firmware",
        device.external_designation or device.internal_designation or ("0x" .. device.id),
        device, "port:" .. device.id, nil, "port_connectors", device.id)
      if node then node.kind = "port_connector" end
    else result.partial = true end
  end
  local onboard_devices = type(onboard.devices) == "table" and onboard.devices or {}
  result.truncated = result.truncated or onboard.truncated == true
  result.partial = result.partial or onboard.partial == true
  for index, device in ipairs(onboard_devices) do
    if index > 128 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local node = add_node("firmware", device.designation or ("0x" .. device.id), device,
        "onboard:" .. device.id, nil, "onboard_devices", device.id)
      if node then node.kind = "onboard_device" end
    else result.partial = true end
  end
  if onboard.truncated ~= true and #onboard_devices <= 128
      and Quality.current_source(snapshot.quality, "onboard_devices") then
    local onboard_claims = {}
    for _, node in ipairs(unsorted) do
      if node.kind == "onboard_device" and not node.ambiguous
          and node.device.quality == "fresh" and node.device.enabled == true then
        local address = pci_address(node.device.pci_bdf)
        local target = address and result.by_id["pci:" .. address]
        if target and not target.ambiguous then
          if onboard_claims[address] ~= nil then
            onboard_claims[address] = false
            result.partial = true
          else onboard_claims[address] = node end
        end
      end
    end
    for address, node in pairs(onboard_claims) do
      if node then
        local target = result.by_id["pci:" .. address]
        node.pci_ids[#node.pci_ids + 1] = address
        target.onboard_ids[#target.onboard_ids + 1] = node.id
      end
    end
  end
  local batteries = type(snapshot.firmware_batteries) == "table"
    and snapshot.firmware_batteries or {}
  local battery_list = type(batteries.batteries) == "table" and batteries.batteries or {}
  result.truncated = result.truncated or batteries.truncated == true
  result.partial = result.partial or batteries.partial == true
  for index, device in ipairs(battery_list) do
    if index > 64 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local node = add_node("firmware", device.name or device.location or ("0x" .. device.id),
        device, "firmware-battery:" .. device.id, nil, "firmware_batteries", device.id)
      if node then node.kind = "firmware_battery" end
    else result.partial = true end
  end
  local supplies = type(snapshot.firmware_power_supplies) == "table"
    and snapshot.firmware_power_supplies or {}
  local bmcs = type(snapshot.firmware_bmcs) == "table"
    and snapshot.firmware_bmcs or {}
  local bmc_list = type(bmcs.devices) == "table" and bmcs.devices or {}
  result.truncated = result.truncated or bmcs.truncated == true
  result.partial = result.partial or bmcs.partial == true
  for index, device in ipairs(bmc_list) do
    if index > 64 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local node = add_node("firmware", "0x" .. device.id, device,
        "firmware-bmc:" .. device.id, nil, "firmware_bmcs", device.id)
      if node then node.kind = "firmware_bmc" end
    else result.partial = true end
  end
  local tpms = type(snapshot.firmware_tpms) == "table"
    and snapshot.firmware_tpms or {}
  local tpm_list = type(tpms.devices) == "table" and tpms.devices or {}
  result.truncated = result.truncated or tpms.truncated == true
  result.partial = result.partial or tpms.partial == true
  for index, device in ipairs(tpm_list) do
    if index > 64 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local node = add_node("firmware", device.description or ("0x" .. device.id),
        device, "firmware-tpm:" .. device.id, nil, "firmware_tpms", device.id)
      if node then node.kind = "firmware_tpm" end
    else result.partial = true end
  end
  local components = type(snapshot.firmware_components) == "table"
    and snapshot.firmware_components or {}
  result.truncated = result.truncated or components.truncated == true
  result.partial = result.partial or components.partial == true
  for index, component in ipairs(type(components.components) == "table"
      and components.components or {}) do
    if index > 128 then result.truncated = true break end
    if type(component) == "table" and identifier(component.id) then
      local node = add_node("firmware", component.name or ("0x" .. component.id),
        component, "firmware-component:" .. component.id, nil,
        "firmware_components", component.id)
      if node then node.kind = "firmware_component" end
    else result.partial = true end
  end
  local esrt = type(snapshot.firmware_esrt) == "table" and snapshot.firmware_esrt or {}
  result.truncated = result.truncated or esrt.truncated == true
  result.partial = result.partial or esrt.partial == true
  for index, entry in ipairs(type(esrt.entries) == "table" and esrt.entries or {}) do
    if index > 128 then result.truncated = true break end
    local id = type(entry) == "table" and identifier(entry.id) or nil
    local guid = type(entry) == "table" and GUID.normalize(entry.guid) or nil
    if id and guid then
      local node = add_node("firmware", guid, entry, "esrt:" .. id,
        nil, "firmware_esrt", id)
      if node then node.kind = "esrt_firmware" end
    elseif entry and entry.status ~= "denied" and entry.status ~= "unavailable" then
      result.partial = true
    end
  end
  local os_tpms = type(snapshot.tpm) == "table" and snapshot.tpm or {}
  local os_tpm_list = type(os_tpms.devices) == "table" and os_tpms.devices or {}
  result.truncated = result.truncated or os_tpms.truncated == true
  result.partial = result.partial or os_tpms.partial == true
  for index, device in ipairs(os_tpm_list) do
    if index > 16 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local node = add_node("tpm", device.id, device, "tpm:" .. device.id,
        nil, "tpm", device.id)
      if node then node.kind = "os_tpm" end
    else result.partial = true end
  end
  local watchdogs = type(snapshot.watchdog) == "table" and snapshot.watchdog or {}
  local watchdog_list = type(watchdogs.devices) == "table" and watchdogs.devices or {}
  result.truncated = result.truncated or watchdogs.truncated == true
  result.partial = result.partial or watchdogs.partial == true
  for index, device in ipairs(watchdog_list) do
    if index > 16 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local parent = M.target_id(device.device_path, result.by_id)
      if parent and (not result.by_id[parent] or result.by_id[parent].ambiguous) then
        parent = nil
      end
      local node = add_node("watchdog", device.id, device,
        "watchdog:" .. device.id, parent, "watchdog", device.id)
      if node then node.kind = "watchdog" end
    else result.partial = true end
  end
  local switches = type(snapshot.rfkill) == "table" and snapshot.rfkill or {}
  local switch_list = type(switches.devices) == "table" and switches.devices or {}
  result.truncated = result.truncated or switches.truncated == true
  result.partial = result.partial or switches.partial == true
  for index, device in ipairs(switch_list) do
    if index > 64 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local parent = M.target_id(device.device_path, result.by_id)
      if parent and (not result.by_id[parent] or result.by_id[parent].ambiguous) then
        parent = nil
      end
      local node = add_node("rfkill", device.id, device,
        "rfkill:" .. device.id, parent, "rfkill", device.id)
      if node then node.kind = "rfkill" end
    else result.partial = true end
  end
  local thermal = type(snapshot.thermal_zones) == "table" and snapshot.thermal_zones or {}
  result.truncated = result.truncated or thermal.truncated == true
  result.partial = result.partial or thermal.partial == true
  for _, spec in ipairs({ { "zones", 64, "thermal_zone", "thermal-zone:" },
      { "cooling_devices", 128, "cooling_device", "cooling-device:" } }) do
    local devices = type(thermal[spec[1]]) == "table" and thermal[spec[1]] or {}
    for index, device in ipairs(devices) do
      if index > spec[2] then result.truncated = true break end
      if type(device) == "table" and identifier(device.id) then
        local parent = M.target_id(device.device_path, result.by_id)
        if parent and (not result.by_id[parent] or result.by_id[parent].ambiguous) then
          parent = nil
        end
        local node = add_node("thermal", device.id, device,
          spec[4] .. device.id, parent, "thermal_zones", device.id)
        if node then node.kind = spec[3] end
      else result.partial = true end
    end
  end
  for _, zone in ipairs(type(thermal.zones) == "table" and thermal.zones or {}) do
    local source = type(zone) == "table" and result.by_id["thermal-zone:" .. tostring(zone.id)]
    if source and not source.ambiguous then
      local seen = {}
      for _, binding in ipairs(type(zone.bindings) == "table" and zone.bindings or {}) do
        local id = type(binding) == "table" and identifier(binding.cooling_id)
        local target = id and result.by_id["cooling-device:" .. id]
        if target and not target.ambiguous and not seen[target.id] then
          source.cooling_ids[#source.cooling_ids + 1] = target.id
          target.thermal_zone_ids[#target.thermal_zone_ids + 1] = source.id
          seen[target.id] = true
        end
      end
    end
  end
  local hosts = type(snapshot.host_interfaces) == "table"
    and snapshot.host_interfaces or {}
  local host_list = type(hosts.devices) == "table" and hosts.devices or {}
  result.truncated = result.truncated or hosts.truncated == true
  result.partial = result.partial or hosts.partial == true
  for index, device in ipairs(host_list) do
    if index > 64 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local node = add_node("firmware", device.interface_type or ("0x" .. device.id),
        device, "host-interface:" .. device.id, nil, "host_interfaces", device.id)
      if node then node.kind = "host_interface" end
    else result.partial = true end
  end
  local supply_list = type(supplies.supplies) == "table" and supplies.supplies or {}
  result.truncated = result.truncated or supplies.truncated == true
  result.partial = result.partial or supplies.partial == true
  for index, device in ipairs(supply_list) do
    if index > 64 then result.truncated = true break end
    if type(device) == "table" and identifier(device.id) then
      local node = add_node("firmware", device.name or device.location or ("0x" .. device.id),
        device, "firmware-psu:" .. device.id, nil, "firmware_power_supplies", device.id)
      if node then node.kind = "firmware_power_supply" end
    else result.partial = true end
  end
  -- A nonzero power-unit group declares a redundant configuration. It is not
  -- live health or physical containment; only a complete, current firmware
  -- list can establish which declared supplies are peers in that group.
  if supplies.truncated ~= true and supplies.partial ~= true and #supply_list <= 64
      and Quality.current_source(snapshot.quality, "firmware_power_supplies") then
    local groups = {}
    for _, node in ipairs(unsorted) do
      if node.kind == "firmware_power_supply" then
        local group = node.device.power_unit_group
        if math.type(group) == "integer" and group >= 1 and group <= 255 then
          local entry = groups[group] or { members = {}, complete = true }
          groups[group] = entry
          if node.ambiguous or node.device.quality ~= "fresh" then
            entry.complete = false
          else entry.members[#entry.members + 1] = node end
        end
      end
    end
    for _, group in pairs(groups) do
      if group.complete and #group.members >= 2 then
        for _, node in ipairs(group.members) do
          for _, peer in ipairs(group.members) do
            if peer ~= node then
              node.redundant_peer_ids[#node.redundant_peer_ids + 1] = peer.id
            end
          end
          table.sort(node.redundant_peer_ids)
        end
      end
    end
  end
  local firmware = type(snapshot.processor_firmware) == "table"
    and snapshot.processor_firmware or {}
  result.truncated = result.truncated or firmware.truncated == true
  for _, section in ipairs({ { "processors", "firmware-socket:", "processor_socket", 128 },
                            { "caches", "firmware-cache:", "firmware_cache", 512 } }) do
    for index, device in ipairs(type(firmware[section[1]]) == "table"
        and firmware[section[1]] or {}) do
      if index > section[4] then result.truncated = true break end
      if type(device) == "table" and identifier(device.id) then
        local node = add_node("firmware", device.designation or device.id, device,
          section[2] .. device.id, nil, "processor_firmware", device.id)
        if node then node.kind = section[3] end
      else result.partial = true end
    end
  end
  for _, socket in ipairs(unsorted) do
    if socket.kind == "processor_socket" and not socket.ambiguous then
      local seen = {}
      local handles = type(socket.device.cache_handles) == "table"
        and socket.device.cache_handles or {}
      for level = 1, 3 do
        local handle = identifier(handles["l" .. level])
        local cache = handle and result.by_id["firmware-cache:" .. handle]
        if cache and not cache.ambiguous then
          if seen[cache.id] or cache.device.level ~= level then
            result.partial = true
          else
            seen[cache.id] = true
            socket.cache_ids[#socket.cache_ids + 1] = cache.id
            cache.firmware_socket_ids[#cache.firmware_socket_ids + 1] = socket.id
          end
        elseif handle then result.partial = true end
      end
    end
  end
  for _, cache in ipairs(unsorted) do
    if cache.kind == "firmware_cache" and #cache.firmware_socket_ids == 1 then
      cache.parent_id = cache.firmware_socket_ids[1]
    end
  end
  -- Type 45 association handles are explicit firmware cross-references, not
  -- a physical parent relationship. Resolve only handles represented by one
  -- unambiguous SMBIOS node; an unmodeled structure stays a raw handle.
  if Quality.current_source(snapshot.quality, "firmware_components") then
    local smbios_resources = { memory_devices = true, expansion_slots = true,
      port_connectors = true, onboard_devices = true, firmware_batteries = true,
      firmware_power_supplies = true, firmware_bmcs = true, firmware_tpms = true,
      firmware_components = true, host_interfaces = true,
      processor_firmware = true }
    local by_handle = {}
    for _, node in ipairs(unsorted) do
      local handle = type(node.device) == "table" and node.device.handle or nil
      if smbios_resources[node.resource] and type(handle) == "number"
          and math.type(handle) == "integer" and handle >= 0 and handle < 65535 then
        local id = string.format("%04x", handle)
        if by_handle[id] ~= nil or (node.device.structure_type == 10
            and node.device.device_count ~= 1) then by_handle[id] = false
        else by_handle[id] = node end
      end
    end
    for _, source in ipairs(unsorted) do
      if source.kind == "firmware_component" and not source.ambiguous
          and source.device.quality == "fresh"
          and source.device.association_complete == true then
        for _, handle in ipairs(source.device.associated_handles or {}) do
          local target = by_handle[handle]
          if target and not target.ambiguous and target ~= source
              and (target.resource ~= "onboard_devices" or (onboard.truncated ~= true
                and #onboard_devices <= 128 and target.device.quality == "fresh"))
              and Quality.current_source(snapshot.quality, target.resource) then
            source.associated_ids[#source.associated_ids + 1] = target.id
            target.firmware_component_ids[#target.firmware_component_ids + 1] = source.id
          end
        end
      end
    end
    for _, node in ipairs(unsorted) do
      table.sort(node.associated_ids)
      table.sort(node.firmware_component_ids)
    end
  end
  if Quality.current_source(snapshot.quality, "firmware_components")
      and Quality.current_source(snapshot.quality, "firmware_esrt") then
    local component_by_guid, esrt_by_guid = {}, {}
    local function index_unique(index, guid, node)
      if not guid or node.ambiguous then return end
      if index[guid] ~= nil then index[guid] = false
      else index[guid] = node end
    end
    for _, node in ipairs(unsorted) do
      if node.kind == "firmware_component" then
        index_unique(component_by_guid, GUID.normalize(node.device.firmware_id), node)
      elseif node.kind == "esrt_firmware" then
        index_unique(esrt_by_guid, GUID.normalize(node.device.guid), node)
      end
    end
    for guid, component in pairs(component_by_guid) do
      local target = esrt_by_guid[guid]
      if component and target then
        component.esrt_ids[#component.esrt_ids + 1] = target.id
        target.firmware_component_ids[#target.firmware_component_ids + 1] = component.id
      end
    end
  end
  table.sort(unsorted, function(a, b) return a.id < b.id end)
  -- Break malformed cycles without recursion or mutating the source snapshot.
  local done = {}
  for _, node in ipairs(unsorted) do
    local visiting, cursor = {}, node
    while cursor and not done[cursor.id] do
      if visiting[cursor.id] then
        cursor.parent_id = nil
        result.partial = true
        break
      end
      visiting[cursor.id] = true
      cursor = result.by_id[cursor.parent_id]
    end
    for id in pairs(visiting) do done[id] = true end
  end
  local roots = {}
  for _, node in ipairs(unsorted) do
    local parent = result.by_id[node.parent_id]
    if parent and parent.ambiguous then
      parent, node.parent_id = nil, nil
      result.partial = true
    end
    if parent then parent.children[#parent.children + 1] = node
    else roots[#roots + 1] = node end
  end
  local mounts = type(snapshot.mounts) == "table" and snapshot.mounts or {}
  result.truncated = result.truncated or mounts.truncated == true
  for index, mount in ipairs(type(mounts.mounts) == "table" and mounts.mounts or {}) do
    if index > 512 then result.truncated = true break end
    if type(mount) == "table" then
      local node = blocks_by_id[identifier(mount.device_id)]
      local id = resource_id(mount.id)
      if node and not node.ambiguous and id then
        node.mount_ids[#node.mount_ids + 1] = id
        node.mounts[#node.mounts + 1] = mount
      end
    end
  end
  local stack = {}
  for index = #roots, 1, -1 do stack[#stack + 1] = { roots[index], 0 } end
  while #stack > 0 do
    local item = table.remove(stack)
    local node = item[1]
    node.depth = item[2]
    result.nodes[#result.nodes + 1] = node
    for index = #node.children, 1, -1 do
      stack[#stack + 1] = { node.children[index], node.depth + 1 }
    end
  end
  local sensors = Quality.current_source(snapshot.quality, "sensors")
      and type(snapshot.sensors) == "table" and snapshot.sensors or {}
  local function spd_sensor_target(sensor)
    if type(sensor) ~= "table" or type(sensor.device_target) ~= "string" then return nil end
    local bus, address = sensor.device_target:match("/(%d+)%-(%x%x%x%x)$")
    address = address and tonumber(address, 16)
    if not bus or not address then return nil end
    if sensor.name == "spd5118" and address >= 0x50 and address <= 0x57 then
      return string.format("%s-%04x", bus, address)
    end
    if sensor.name == "jc42" and address >= 0x18 and address <= 0x1f then
      return string.format("%s-%04x", bus, 0x50 + (address & 7))
    end
  end
  local spd_sensors = {}
  for index, sensor in ipairs(type(sensors.devices) == "table" and sensors.devices or {}) do
    if index > 128 then break end
    local address = spd_sensor_target(sensor)
    if address then spd_sensors[address] = (spd_sensors[address] or 0) + 1 end
  end
  -- coretemp names its package explicitly. A core number only has meaning
  -- inside that package, and can be reused on another die. Attach each
  -- channel only when the destination is unique in the CPU topology.
  local function coretemp_package_id(label)
    if type(label) ~= "string" then return nil end
    return label:match("^Package id (%d+)$") or label:match("^Physical id (%d+)$")
  end
  local coretemp_packages = {}
  for index, sensor in ipairs(type(sensors.devices) == "table" and sensors.devices or {}) do
    if index > 128 then break end
    if type(sensor) == "table" and sensor.name == "coretemp" then
      local package_id
      for channel_index, channel in ipairs(type(sensor.channels) == "table" and sensor.channels or {}) do
        if channel_index > 256 then break end
        local id = type(channel) == "table" and coretemp_package_id(channel.label)
        if id then
          if package_id and package_id ~= id then package_id = false; break end
          package_id = id
        end
      end
      if package_id then
        local previous = coretemp_packages[package_id]
        coretemp_packages[package_id] = previous == nil and sensor or false
      end
    end
  end
  local function attach_sensor(node, sensor, id, channels)
    if not node or node.ambiguous or not id then return end
    local view = sensor
    if channels then
      view = {}
      for key, value in pairs(sensor) do view[key] = value end
      view.channels = channels
    end
    node.sensor_ids[#node.sensor_ids + 1] = id
    node.sensors[#node.sensors + 1] = view
  end
  for index, sensor in ipairs(type(sensors.devices) == "table" and sensors.devices or {}) do
    if index > 128 then result.truncated = true break end
    if type(sensor) == "table" then
      local node = result.by_id[M.target_id(sensor.device_path or sensor.device_target,
        result.by_id)]
      local id = identifier(sensor.id) or identifier(sensor.class)
      attach_sensor(node, sensor, id)
      local spd_address = spd_sensor_target(sensor)
      if spd_address and spd_sensors[spd_address] == 1
          and sensor.identity_quality ~= "estimated" then
        local spd_node = result.by_id["spd:" .. spd_address]
        local device = spd_node and spd_node.device or {}
        if sensor.name == "spd5118" and device.driver == "spd5118"
            or sensor.name == "jc42" and device.driver == "ee1004"
              and device.memory_type == "DDR4"
              and device.crc_base_valid == true
              and (device.temperature_sensor_present or device.revision == "1.0")
            or sensor.name == "jc42" and device.driver == "spd"
              and device.memory_type == "DDR3"
              and device.crc_base_valid == true
              and device.temperature_sensor_present == true then
          attach_sensor(spd_node, sensor, id)
        end
      end
      if sensor.name == "coretemp" and id then
        for package_id, owner in pairs(coretemp_packages) do
          if owner == sensor then
            local package = result.by_id["package:" .. package_id]
            if package and not package.ambiguous then
              local package_channels = {}
              local core_channels = {}
              for channel_index, channel in ipairs(type(sensor.channels) == "table" and sensor.channels or {}) do
                if channel_index > 256 then result.truncated = true break end
                if type(channel) == "table" and channel.type == "temperature" then
                  if coretemp_package_id(channel.label) == package_id then
                    package_channels[#package_channels + 1] = channel
                  else
                    local core_id = type(channel.label) == "string"
                      and channel.label:match("^Core (%d+)$")
                    if core_id then core_channels[core_id] = core_channels[core_id] or {};
                      core_channels[core_id][#core_channels[core_id] + 1] = channel end
                  end
                end
              end
              if #package_channels == 1 then attach_sensor(package, sensor, id, package_channels) end
              for core_id, channels in pairs(core_channels) do
                local candidate
                for _, child in ipairs(package.children) do
                  if child.kind == "core" and tostring(child.device.id) == core_id then
                    if candidate then candidate = false; break end
                    candidate = child
                  end
                end
                if candidate and #channels == 1 then attach_sensor(candidate, sensor, id, channels) end
              end
            end
          end
        end
      end
    end
  end
  local function trusted_temperature(owner)
    if not owner or owner.ambiguous then return nil end
    local match
    for index, sensor in ipairs(owner.sensors) do
      if sensor.name == "coretemp" then
        for _, channel in ipairs(type(sensor.channels) == "table" and sensor.channels or {}) do
          local value = type(channel) == "table" and channel.input
          if type(value) == "number" and value == value
              and value ~= math.huge and value ~= -math.huge
              and not Quality.UNUSABLE_FOR_ALERT[channel.quality] then
            if match then return nil end
            match = { sensor = sensor, sensor_id = owner.sensor_ids[index],
              channel = channel, celsius = value }
          end
        end
      end
    end
    return match
  end
  -- A policy can overlap cores. Show a core sensor only when all its members
  -- resolve to one core; otherwise a package sensor is a labelled fallback
  -- only when every member belongs to one known package. Neither is a sensor
  -- of the frequency policy itself.
  for _, node in ipairs(unsorted) do
    if Quality.current_source(snapshot.quality, "cpu_info")
        and Quality.current_source(snapshot.quality, "cpu_frequency")
        and node.kind == "policy" and not node.ambiguous
        and node.membership_complete and #node.cpu_ids > 0 then
      local package_id, core_id, same_core, complete = nil, nil, true, true
      for _, id in ipairs(node.cpu_ids) do
        local cpu = cpus[id]
        if not cpu or cpu.ambiguous or not cpu.package_id then
          complete = false
          break
        end
        if package_id and package_id ~= cpu.package_id then
          complete = false
          break
        end
        package_id = cpu.package_id
        local parent = result.by_id[cpu.parent_id]
        if not parent or parent.kind ~= "core" or parent.ambiguous then
          same_core = false
        elseif core_id and core_id ~= parent.id then
          same_core = false
        else
          core_id = parent.id
        end
      end
      if complete then
        local owner = same_core and core_id and result.by_id[core_id] or nil
        local scope = "core"
        local match = trusted_temperature(owner)
        if not match then
          owner = result.by_id[package_id]
          scope = "package"
          match = trusted_temperature(owner)
        end
        if match then
          node.temperature = { scope = scope, owner_id = owner.id,
            sensor_id = match.sensor_id, channel_id = match.channel.id,
            celsius = match.celsius }
          node.sensor_ids[#node.sensor_ids + 1] = match.sensor_id
          node.sensors[#node.sensors + 1] = match.sensor
        end
      end
    end
  end
  local gpus = type(snapshot.gpus) == "table" and snapshot.gpus or {}
  for index, gpu in ipairs(type(gpus.devices) == "table" and gpus.devices or {}) do
    if index > 128 then result.truncated = true break end
    if type(gpu) == "table" then
      local address = pci_address(gpu.pci_bdf)
      local node = address and result.by_id["pci:" .. address]
      local id = identifier(gpu.id) or identifier(gpu.card)
      if node and not node.ambiguous and id
          and (gpu.vendor_id == nil or node.device.vendor_id == nil
            or gpu.vendor_id == node.device.vendor_id)
          and (gpu.device_id == nil or node.device.device_id == nil
            or gpu.device_id == node.device.device_id) then
        node.gpu_ids[#node.gpu_ids + 1] = id
      end
    end
  end
  return result
end

-- Cross-references and children that the shared graph has actually resolved.
-- A raw firmware address, missing target or ambiguous node is not a destination.
-- The order is fixed so a large CPU or PCI tree cannot displace the explicit
-- EDAC/slot/SR-IOV references that brought the operator into this view.
function M.related(graph, id, limit)
  limit = type(limit) == "number" and math.type(limit) == "integer"
    and limit >= 1 and math.min(limit, 256) or 256
  local result = { items = {}, total = 0, truncated = false }
  local by_id = type(graph) == "table" and graph.by_id or nil
  local node = type(by_id) == "table" and by_id[id] or nil
  if not node or node.ambiguous then return result end
  local seen = {}
  local function add(target_id, relation)
    local target = type(target_id) == "string" and by_id[target_id] or nil
    if not target or target.ambiguous or target.id == id or seen[target.id] then return end
    seen[target.id] = true
    result.total = result.total + 1
    if #result.items < limit then
      result.items[#result.items + 1] = { id = target.id, relation = relation }
    else result.truncated = true end
  end
  for _, spec in ipairs({
      { "edac_module_id" }, { "memory_device_id" }, { "pf_id" },
      { "slot_ids" }, { "onboard_ids" }, { "pci_ids", "pci:" }, { "vf_ids" },
      { "iommu_peer_ids" }, { "mapped_range_ids" },
      { "slave_ids" }, { "holder_ids" },
      { "channel_ids" }, { "memory_device_ids" }, { "redundant_peer_ids" },
      { "cooling_ids" }, { "thermal_zone_ids" },
      { "cache_ids" }, { "firmware_socket_ids" },
      { "associated_ids" }, { "firmware_component_ids" },
      { "esrt_ids" },
      { "numa_node_ids", "numa:" }, { "cpufreq_ids", "cpufreq:" },
      { "cpu_ids", "cpu:" },
    }) do
    local value = node[spec[1]]
    if type(value) == "table" then
      for _, item in ipairs(value) do
        add(spec[2] and spec[2] .. tostring(item) or item, spec[1])
      end
    else
      add(value, spec[1])
    end
  end
  local temperature = type(node.temperature) == "table" and node.temperature or nil
  if temperature then add(temperature.owner_id, "temperature") end
  for _, child in ipairs(type(node.children) == "table" and node.children or {}) do
    if type(child) == "table" then add(child.id, "child") end
  end
  return result
end

return M
