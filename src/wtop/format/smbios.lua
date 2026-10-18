-- Bounded SMBIOS 2.x/3.x hardware inventory (DSP0134, types 2, 3, 4, 7, 8, 9, 10,
-- 16, 17, 19, 20, 22, 37, 38, 39, 41, 42, 43 and 45).
-- Only named public fields are copied out. Serial numbers, asset tags, UUIDs
-- and raw firmware bytes are not retained in the parsed result.
local Common = require("wtop.collectors.common")
local GUID = require("wtop.core.guid")
local M = { MAX_BYTES = 4 * 1024 * 1024 }

local function uint(data, offset, size)
  if offset < 0 or offset + size > #data then return nil end
  local value = 0
  for index = offset + size, offset + 1, -1 do
    local byte = data:byte(index)
    if value > (math.maxinteger - byte) // 256 then return nil end
    value = value * 256 + byte
  end
  return value
end

local function qword_hex(data, offset)
  local bytes = {}
  for index = offset + 8, offset + 1, -1 do
    bytes[#bytes + 1] = string.format("%02x", data:byte(index))
  end
  local digits = table.concat(bytes):gsub("^0+", "")
  return "0x" .. (digits ~= "" and digits or "0")
end

local function checksum(data, first, length)
  local value = 0
  for index = first, first + length - 1 do value = (value + data:byte(index)) % 256 end
  return value == 0
end

function M.entry_point(data)
  if type(data) ~= "string" or #data > 512 then return nil, "smbios_invalid" end
  if data:sub(1, 5) == "_SM3_" then
    local size = uint(data, 6, 1)
    if not size or size < 24 or size > #data or not checksum(data, 1, size) then
      return nil, "smbios_invalid"
    end
    return { major = uint(data, 7, 1), minor = uint(data, 8, 1), docrev = uint(data, 9, 1),
      maximum_table_bytes = uint(data, 12, 4) }
  elseif data:sub(1, 4) == "_SM_" then
    local size = uint(data, 5, 1)
    if not size or size < 31 or size > #data or not checksum(data, 1, size)
        or data:sub(17, 21) ~= "_DMI_" or not checksum(data, 17, 15) then
      return nil, "smbios_invalid"
    end
    return { major = uint(data, 6, 1), minor = uint(data, 7, 1),
      table_bytes = uint(data, 22, 2), structure_count = uint(data, 28, 2) }
  end
  return nil, "smbios_invalid"
end

local MEMORY_TYPES = {
  [3] = "DRAM", [4] = "EDRAM", [5] = "VRAM", [6] = "SRAM", [7] = "RAM",
  [8] = "ROM", [9] = "Flash", [10] = "EEPROM", [11] = "FEPROM", [12] = "EPROM",
  [13] = "CDRAM", [14] = "3DRAM", [15] = "SDRAM", [16] = "SGRAM", [17] = "RDRAM",
  [18] = "DDR", [19] = "DDR2", [20] = "DDR2 FB-DIMM", [24] = "DDR3",
  [25] = "FBD2", [26] = "DDR4", [27] = "LPDDR", [28] = "LPDDR2",
  [29] = "LPDDR3", [30] = "LPDDR4", [32] = "HBM", [33] = "HBM2",
  [34] = "DDR5", [35] = "LPDDR5", [36] = "HBM3",
}
local FORM_FACTORS = { [3] = "SIMM", [4] = "SIP", [5] = "Chip", [6] = "DIP",
  [7] = "ZIP", [9] = "DIMM", [10] = "TSOP", [11] = "Row of chips", [12] = "RIMM",
  [13] = "SO-DIMM", [14] = "SRIMM", [15] = "FB-DIMM", [16] = "Die" }
local SLOT_TYPES = { [0x06] = "PCI", [0x0f] = "AGP", [0x12] = "PCI-X",
  [0x14] = "M.2 Key A", [0x15] = "M.2 Key E", [0x16] = "M.2 Key B",
  [0x17] = "M.2 Key M", [0x26] = "OCP NIC 3.0 SFF",
  [0x27] = "OCP NIC 3.0 LFF", [0xc4] = "PCI Express Gen 6+" }
for _, generation in ipairs({ { 0xa5, "PCI Express" }, { 0xab, "PCI Express Gen 2" },
    { 0xb1, "PCI Express Gen 3" }, { 0xb8, "PCI Express Gen 4" },
    { 0xbe, "PCI Express Gen 5" } }) do
  SLOT_TYPES[generation[1]] = generation[2]
  for index, lanes in ipairs({ 1, 2, 4, 8, 16 }) do
    SLOT_TYPES[generation[1] + index] = generation[2] .. " x" .. lanes
  end
end
local SLOT_LANES = { [8] = 1, [9] = 2, [10] = 4, [11] = 8,
  [12] = 12, [13] = 16, [14] = 32 }
local CACHE_TYPES = { [3] = "Instruction", [4] = "Data", [5] = "Unified" }
local CONNECTOR_TYPES = {
  [0] = "None", [1] = "Centronics", [2] = "Mini Centronics", [3] = "Proprietary",
  [4] = "DB-25 male", [5] = "DB-25 female", [6] = "DB-15 male",
  [7] = "DB-15 female", [8] = "DB-9 male", [9] = "DB-9 female",
  [10] = "RJ-11", [11] = "RJ-45", [12] = "50-pin MiniSCSI",
  [13] = "Mini-DIN", [14] = "Micro-DIN", [15] = "PS/2", [16] = "Infrared",
  [17] = "HP-HIL", [18] = "USB", [19] = "SSA SCSI",
  [20] = "Circular DIN-8 male", [21] = "Circular DIN-8 female",
  [22] = "Onboard IDE", [23] = "Onboard Floppy",
  [24] = "9-pin Dual Inline", [25] = "25-pin Dual Inline",
  [26] = "50-pin Dual Inline", [27] = "68-pin Dual Inline",
  [28] = "Onboard CD audio", [29] = "Mini-Centronics Type-14",
  [30] = "Mini-Centronics Type-26", [31] = "Mini-jack", [32] = "BNC",
  [33] = "IEEE 1394", [34] = "SAS/SATA plug", [35] = "USB Type-C",
  [0xa0] = "PC-98", [0xa1] = "PC-98Hireso", [0xa2] = "PC-H98",
  [0xa3] = "PC-98Note", [0xa4] = "PC-98Full", [0xff] = "Other",
}
local PORT_TYPES = {
  [0] = "None", [1] = "Parallel XT/AT", [2] = "Parallel PS/2",
  [3] = "Parallel ECP", [4] = "Parallel EPP", [5] = "Parallel ECP/EPP",
  [6] = "Serial XT/AT", [7] = "Serial 16450", [8] = "Serial 16550",
  [9] = "Serial 16550A", [10] = "SCSI", [11] = "MIDI",
  [12] = "Joystick", [13] = "Keyboard", [14] = "Mouse",
  [15] = "SSA SCSI", [16] = "USB", [17] = "IEEE 1394",
  [18] = "PCMCIA Type I", [19] = "PCMCIA Type II",
  [20] = "PCMCIA Type III", [21] = "CardBus", [22] = "Access Bus",
  [23] = "SCSI II", [24] = "SCSI Wide", [25] = "PC-98",
  [26] = "PC-98Hireso", [27] = "PC-H98", [28] = "Video",
  [29] = "Audio", [30] = "Modem", [31] = "Network",
  [32] = "SATA", [33] = "SAS", [34] = "Multi-Function DisplayPort",
  [35] = "Thunderbolt", [0xa0] = "8251 compatible",
  [0xa1] = "8251 FIFO compatible", [0xff] = "Other",
}
local ONBOARD_TYPES = {
  [1] = "Other", [2] = "Unknown", [3] = "Video", [4] = "SCSI controller",
  [5] = "Ethernet", [6] = "Token Ring", [7] = "Sound",
  [8] = "PATA controller", [9] = "SATA controller", [10] = "SAS controller",
  [11] = "Wireless LAN", [12] = "Bluetooth", [13] = "WWAN",
  [14] = "eMMC controller", [15] = "NVMe controller", [16] = "UFS controller",
}
local CHANNEL_TYPES = { [1] = "Other", [2] = "Unknown",
  [3] = "Rambus", [4] = "SyncLink" }
local BMC_INTERFACES = { [0] = "Unknown", [1] = "KCS",
  [2] = "SMIC", [3] = "BT", [4] = "SSIF" }
local BMC_REGISTER_SPACING = { [0] = 1, [1] = 4, [2] = 16 }
local HOST_PROTOCOLS = { [2] = "IPMI", [3] = "MCTP",
  [4] = "Redfish over IP", [0xf0] = "OEM" }
local SUPPLY_TYPES = { [1] = "Other", [2] = "Unknown", [3] = "Linear",
  [4] = "Switching", [5] = "Battery", [6] = "UPS",
  [7] = "Converter", [8] = "Regulator" }
local SUPPLY_STATUSES = { [1] = "Other", [2] = "Unknown", [3] = "OK",
  [4] = "Non-critical", [5] = "Critical" }
local SUPPLY_RANGES = { [1] = "Other", [2] = "Unknown", [3] = "Manual",
  [4] = "Auto-switch", [5] = "Wide range", [6] = "Not applicable" }
local BATTERY_CHEMISTRIES = { [1] = "Other", [2] = "Unknown",
  [3] = "Lead acid", [4] = "Nickel cadmium", [5] = "Nickel metal hydride",
  [6] = "Lithium-ion", [7] = "Zinc air", [8] = "Lithium polymer" }
local FIRMWARE_STATES = { [1] = "Other", [2] = "Unknown", [3] = "Disabled",
  [4] = "Enabled", [5] = "Absent", [6] = "Standby offline",
  [7] = "Standby spare", [8] = "Unavailable offline" }
local BOARD_TYPES = { [1] = "Unknown", [2] = "Other", [3] = "Server blade",
  [4] = "Connectivity switch", [5] = "System management module", [6] = "Processor module",
  [7] = "I/O module", [8] = "Memory module", [9] = "Daughter board", [10] = "Motherboard",
  [11] = "Processor/memory module", [12] = "Processor/I/O module", [13] = "Interconnect board" }
local CHASSIS_TYPES = { [1] = "Other", [2] = "Unknown", [3] = "Desktop", [4] = "Low profile desktop",
  [5] = "Pizza box", [6] = "Mini tower", [7] = "Tower", [8] = "Portable", [9] = "Laptop",
  [10] = "Notebook", [11] = "Hand held", [12] = "Docking station", [13] = "All in one",
  [14] = "Sub notebook", [15] = "Space-saving", [16] = "Lunch box", [17] = "Main server chassis",
  [18] = "Expansion chassis", [19] = "Subchassis", [20] = "Bus expansion chassis",
  [21] = "Peripheral chassis", [22] = "RAID chassis", [23] = "Rack mount chassis",
  [24] = "Sealed-case PC", [25] = "Multi-system chassis", [26] = "Compact PCI", [27] = "Advanced TCA",
  [28] = "Blade", [29] = "Blade enclosure", [30] = "Tablet", [31] = "Convertible",
  [32] = "Detachable", [33] = "IoT gateway", [34] = "Embedded PC", [35] = "Mini PC", [36] = "Stick PC" }
local CHASSIS_STATES = { [1] = "Other", [2] = "Unknown", [3] = "Safe", [4] = "Warning",
  [5] = "Critical", [6] = "Non-recoverable" }
local CHASSIS_SECURITY = { [1] = "Other", [2] = "Unknown", [3] = "None",
  [4] = "External interface locked out", [5] = "External interface enabled" }
local PLACEHOLDERS = { ["unknown"] = true, ["not specified"] = true, ["not provided"] = true,
  ["none"] = true, ["default string"] = true, ["to be filled by o.e.m."] = true }

function M.parse(data, metadata, options)
  options, metadata = options or {}, metadata or {}
  if type(data) ~= "string" or #data < 4 or #data > M.MAX_BYTES then return nil, "smbios_invalid" end
  local max_devices = Common.positive_integer("max_devices", options.max_devices, 256, 256)
  local max_arrays = Common.positive_integer("max_arrays", options.max_arrays, 64, 64)
  local max_slots = Common.positive_integer("max_slots", options.max_slots, 128, 128)
  local max_ports = Common.positive_integer("max_ports", options.max_ports, 128, 128)
  local max_onboard = Common.positive_integer("max_onboard", options.max_onboard, 128, 128)
  local max_processors = Common.positive_integer("max_processors", options.max_processors, 128, 128)
  local max_caches = Common.positive_integer("max_caches", options.max_caches, 512, 512)
  local max_array_ranges = Common.positive_integer("max_array_ranges", options.max_array_ranges, 256, 256)
  local max_device_ranges = Common.positive_integer("max_device_ranges", options.max_device_ranges, 512, 512)
  local max_channels = Common.positive_integer("max_channels", options.max_channels, 64, 64)
  local max_firmware_supplies = Common.positive_integer(
    "max_firmware_supplies", options.max_firmware_supplies, 64, 64)
  local max_firmware_batteries = Common.positive_integer(
    "max_firmware_batteries", options.max_firmware_batteries, 64, 64)
  local max_baseboards = Common.positive_integer("max_baseboards", options.max_baseboards, 64, 64)
  local max_enclosures = Common.positive_integer("max_enclosures", options.max_enclosures, 64, 64)
  local max_firmware_bmcs = Common.positive_integer(
    "max_firmware_bmcs", options.max_firmware_bmcs, 64, 64)
  local max_firmware_tpms = Common.positive_integer(
    "max_firmware_tpms", options.max_firmware_tpms, 64, 64)
  local max_firmware_components = Common.positive_integer(
    "max_firmware_components", options.max_firmware_components, 128, 128)
  local max_host_interfaces = Common.positive_integer(
    "max_host_interfaces", options.max_host_interfaces, 64, 64)
  local result = { arrays = {}, devices = {}, slots = {}, ports = {}, onboard_devices = {},
    baseboards = {}, enclosures = {},
    processors = {}, caches = {},
    array_ranges = {}, device_ranges = {}, channels = {}, firmware_power_supplies = {},
    firmware_batteries = {}, firmware_bmcs = {}, firmware_tpms = {},
    firmware_components = {},
    host_interfaces = {},
    issues = {}, partial = false, truncated = false,
    major = metadata.major, minor = metadata.minor, docrev = metadata.docrev, structure_count = 0 }
  local function issue(field, offset, record)
    result.partial = true
    if record then record.quality = "partial" end
    if #result.issues < 64 then
      result.issues[#result.issues + 1] = { field = field, offset = offset,
        status = "error", reason = "smbios_invalid" }
    end
  end
  local limit = #data
  if metadata.table_bytes then
    if #data < metadata.table_bytes then issue("table_length", 0) end
    limit = math.min(limit, metadata.table_bytes)
  end
  if metadata.maximum_table_bytes and #data > metadata.maximum_table_bytes then
    return nil, "smbios_invalid"
  end
  local position, ended, seen, arrays = 1, false, {}, {}
  while position <= limit do
    if result.structure_count >= 4096 then result.truncated = true; issue("structure_limit", position - 1); break end
    local kind, length = data:byte(position), data:byte(position + 1)
    if not length or length < 4 or position + length - 1 > limit then issue("structure_length", position - 1); break end
    local terminator = data:find("\0\0", position + length, true)
    if not terminator or terminator + 1 > limit then issue("string_terminator", position - 1); break end
    local fields = data:sub(position, position + length - 1)
    local handle = uint(fields, 2, 2)
    result.structure_count = result.structure_count + 1
    if kind == 127 then ended = true; break end
    local record, members
    if kind == 2 or kind == 3 or kind == 4 or kind == 7 or kind == 8 or kind == 9 or kind == 10 or kind == 16 or kind == 17
        or kind == 19 or kind == 20 or kind == 22 or kind == 37
        or kind == 38 or kind == 39 or kind == 41 or kind == 42 or kind == 43
        or kind == 45 then
      record = { id = string.format("%04x", handle), handle = handle,
        offset = position - 1, quality = "fresh" }
      local function read_string(offset, target)
        target = target or record
        local wanted = uint(fields, offset, 1)
        if not wanted or wanted == 0 then return nil end
        local cursor = position + length
        for index = 1, wanted do
          local last = data:find("\0", cursor, true)
          if not last or last > terminator or last == cursor then
            issue("string_index", position - 1, target); return nil
          end
          if index == wanted then
            if last - cursor > 256 then issue("string_length", position - 1, target) end
            local text = Common.safe_text(Common.trim(data:sub(cursor, math.min(last - 1, cursor + 255))), 256)
            return text ~= "" and not PLACEHOLDERS[text:lower()] and text or nil
          end
          cursor = last + 1
        end
      end
      local function speed(offset, extended)
        local value = uint(fields, offset, 2)
        if value == 65535 then
          value = uint(fields, extended, 4)
          if not value or value >= 0x80000000 then issue("speed", position - 1, record); return nil end
        end
        return value and value > 0 and value or nil
      end
      local function address_range(extended_offset)
        local first, last = uint(fields, 4, 4), uint(fields, 8, 4)
        local start_bytes, end_bytes
        if first == 0xffffffff and last == 0xffffffff then
          start_bytes = uint(fields, extended_offset, 8)
          end_bytes = uint(fields, extended_offset + 8, 8)
        elseif first ~= 0xffffffff and last ~= 0xffffffff then
          start_bytes, end_bytes = first * 1024, last * 1024 + 1023
        end
        if not start_bytes or not end_bytes or end_bytes < start_bytes then
          issue("mapped_address", position - 1, record)
          return
        end
        record.start_address_bytes, record.end_address_bytes = start_bytes, end_bytes
        if end_bytes - start_bytes < math.maxinteger then
          record.address_span_bytes = end_bytes - start_bytes + 1
        else issue("mapped_address_span", position - 1, record) end
      end
      if kind == 2 and length >= 8 then
        record.manufacturer, record.product, record.version = read_string(4), read_string(5), read_string(6)
        record.serial_present, record.asset_tag_present = read_string(7) ~= nil, read_string(8) ~= nil
        record.structure_type = 2
        record.location = read_string(10)
        local flags = uint(fields, 9, 1)
        if flags then
          record.feature_flags = flags
          if flags & 0xe0 ~= 0 then issue("baseboard_reserved_flags", position - 1, record) end
        end
        local chassis = uint(fields, 11, 2)
        if chassis and chassis ~= 0xffff then record.chassis_handle = string.format("%04x", chassis) end
        record.board_type_code = uint(fields, 13, 1)
        record.board_type = BOARD_TYPES[record.board_type_code]
        record.contained_handles = {}
        record.contained_count = uint(fields, 14, 1)
        record.containment_complete = record.contained_count ~= nil
          and 15 + record.contained_count * 2 <= length
        if record.contained_count and not record.containment_complete then issue("baseboard_contained_length", position - 1, record) end
        local references = {}
        for index = 1, math.min(record.contained_count or 0, math.max(0, (length - 15) // 2)) do
          local reference = uint(fields, 15 + (index - 1) * 2, 2)
          if reference == 0xffff or reference == handle or references[reference] then
            record.containment_complete = false
            issue("baseboard_contained_handle", position - 1, record)
          else
            references[reference] = true
            record.contained_handles[#record.contained_handles + 1] = string.format("%04x", reference)
          end
        end
        if #result.baseboards < max_baseboards then result.baseboards[#result.baseboards + 1] = record
        else result.truncated = true; issue("baseboard_limit", position - 1) end
      elseif kind == 3 and length >= 9 then
        record.structure_type = 3
        record.manufacturer, record.version = read_string(4), read_string(6)
        record.serial_present, record.asset_tag_present = read_string(7) ~= nil, read_string(8) ~= nil
        local chassis = uint(fields, 5, 1)
        record.chassis_type_code, record.lock_reported_present = chassis & 0x7f, chassis & 0x80 ~= 0
        record.chassis_type = CHASSIS_TYPES[record.chassis_type_code]
        for offset, key in pairs({ [9] = "boot_state", [10] = "power_state", [11] = "thermal_state" }) do
          local value = uint(fields, offset, 1)
          record[key .. "_code"], record[key] = value, CHASSIS_STATES[value]
        end
        record.security_state_code = uint(fields, 12, 1)
        record.security_state = CHASSIS_SECURITY[record.security_state_code]
        local oem = uint(fields, 13, 4)
        record.oem_data_present = oem ~= nil and oem ~= 0
        local height, cords = uint(fields, 17, 1), uint(fields, 18, 1)
        record.height_u = height and height > 0 and height < 255 and height or nil
        record.power_cords = cords and cords > 0 and cords or nil
        record.contained_elements = {}
        local count, stride = uint(fields, 19, 1), uint(fields, 20, 1)
        record.contained_count, record.contained_record_length = count, stride
        if count ~= nil then
          local complete = stride ~= nil and ((count == 0 and stride == 0) or (count > 0 and stride >= 3))
            and 21 + count * stride <= length
          record.containment_complete = complete
          if not complete then issue("enclosure_contained_length", position - 1, record)
          else
            for index = 1, count do
              local offset = 21 + (index - 1) * stride
              local code, minimum, maximum = uint(fields, offset, 1), uint(fields, offset + 1, 1), uint(fields, offset + 2, 1)
              local element = { type_code = code & 0x7f, type_kind = code & 0x80 ~= 0 and "structure" or "baseboard",
                minimum = minimum, maximum = maximum }
              if element.type_kind == "baseboard" then element.board_type = BOARD_TYPES[element.type_code] end
              if minimum == 255 or maximum == 0 or minimum > maximum then
                record.containment_complete = false;issue("enclosure_contained_range", position - 1, record)
              else record.contained_elements[#record.contained_elements + 1] = element end
            end
            local tail = 21 + count * stride
            record.sku = read_string(tail)
            record.rack_type_code = uint(fields, tail + 1, 1)
            local rack_height = uint(fields, tail + 2, 1)
            if height == 255 and record.rack_type_code == 1 and rack_height and rack_height > 0 then
              record.height_ou = rack_height
            end
          end
        end
        if height == 255 and not record.height_ou then issue("enclosure_extended_height", position - 1, record) end
        if #result.enclosures < max_enclosures then result.enclosures[#result.enclosures + 1] = record
        else result.truncated = true; issue("enclosure_limit", position - 1) end
      elseif kind == 4 and length >= 26 then
        record.designation = read_string(4)
        record.processor_type_code = uint(fields, 5, 1)
        record.family_code = uint(fields, 6, 1)
        record.manufacturer = read_string(7)
        record.version = read_string(16)
        record.part_number = read_string(34)
        for offset, key in pairs({ [18] = "external_clock_mhz",
            [20] = "max_speed_mhz", [22] = "boot_speed_mhz" }) do
          local value = uint(fields, offset, 2)
          record[key] = value and value > 0 and value or nil
        end
        local status = uint(fields, 24, 1)
        record.populated = status & 0x40 ~= 0
        record.status_code = status & 7
        record.upgrade_code = uint(fields, 25, 1)
        record.cache_handles = {}
        for level, offset in ipairs({ 26, 28, 30 }) do
          local reference = uint(fields, offset, 2)
          if reference and reference ~= 0xffff then
            record.cache_handles["l" .. level] = string.format("%04x", reference)
          end
        end
        local function count(short_offset, extended_offset)
          local short = uint(fields, short_offset, 1)
          local extended = uint(fields, extended_offset, 2)
          if extended and extended > 0 and extended < 0xffff then return extended end
          if extended == 0xffff then return nil end
          return short and short > 0 and short or nil
        end
        record.core_count = count(35, 42)
        record.enabled_core_count = count(36, 44)
        record.thread_count = count(37, 46)
        local enabled_threads = uint(fields, 48, 2)
        record.enabled_thread_count = enabled_threads and enabled_threads > 0
          and enabled_threads < 0xffff and enabled_threads or nil
        if #result.processors < max_processors then
          result.processors[#result.processors + 1] = record
        else result.truncated = true; issue("processor_limit", position - 1) end
      elseif kind == 7 and length >= 15 then
        record.designation = read_string(4)
        local configuration = uint(fields, 5, 2)
        record.level = (configuration & 7) + 1
        record.enabled = configuration & 0x80 ~= 0
        record.location_code = (configuration >> 5) & 3
        record.write_mode_code = (configuration >> 8) & 3
        local function cache_size(old_offset, extended_offset)
          local old = uint(fields, old_offset, 2)
          local extended
          if old == 0xffff then
            extended = uint(fields, extended_offset, 4)
            if not extended then issue("cache_size", position - 1, record); return nil end
          end
          local value = extended or old
          if not value then return nil end
          local granularity
          if extended then granularity = value & 0x80000000 ~= 0
          else granularity = value & 0x8000 ~= 0 end
          local count = extended and (value & 0x7fffffff) or (value & 0x7fff)
          return count * (granularity and 65536 or 1024)
        end
        record.maximum_size_bytes = cache_size(7, 19)
        record.installed_size_bytes = cache_size(9, 23)
        local speed = uint(fields, 15, 1)
        record.speed_ns = speed and speed > 0 and speed or nil
        record.error_correction_code = uint(fields, 16, 1)
        record.cache_type_code = uint(fields, 17, 1)
        record.cache_type = CACHE_TYPES[record.cache_type_code]
        record.associativity_code = uint(fields, 18, 1)
        if #result.caches < max_caches then
          result.caches[#result.caches + 1] = record
        else result.truncated = true; issue("cache_limit", position - 1) end
      elseif kind == 8 and length >= 9 then
        record.internal_designation = read_string(4)
        record.internal_connector_code = uint(fields, 5, 1)
        record.internal_connector = CONNECTOR_TYPES[record.internal_connector_code]
        record.external_designation = read_string(6)
        record.external_connector_code = uint(fields, 7, 1)
        record.external_connector = CONNECTOR_TYPES[record.external_connector_code]
        record.port_type_code = uint(fields, 8, 1)
        record.port_type = PORT_TYPES[record.port_type_code]
        if #result.ports < max_ports then
          result.ports[#result.ports + 1] = record
        else result.truncated = true; issue("port_limit", position - 1) end
      elseif kind == 9 and length >= 12 then
        record.designation = read_string(4)
        record.slot_type_code = uint(fields, 5, 1)
        record.slot_type = SLOT_TYPES[record.slot_type_code]
        record.slot_width_code = uint(fields, 6, 1)
        record.electrical_lanes = SLOT_LANES[record.slot_width_code]
        record.usage_code = uint(fields, 7, 1)
        record.slot_length_code = uint(fields, 8, 1)
        record.slot_id = uint(fields, 9, 2)
        record.peer_bdfs = {}
        local function bdf(offset)
          local segment, bus = uint(fields, offset, 2), uint(fields, offset + 2, 1)
          local devfn = uint(fields, offset + 3, 1)
          if not segment or not bus or not devfn
              or segment == 0xffff or bus == 0xff or devfn == 0xff then return nil end
          return string.format("%04x:%02x:%02x.%d", segment, bus, devfn >> 3, devfn & 7)
        end
        if length >= 17 then record.pci_bdf = bdf(13) end
        if length >= 18 then record.base_width_code = uint(fields, 17, 1) end
        if length >= 19 then
          local peers = uint(fields, 18, 1)
          if 19 + peers * 5 > length then
            issue("peer_count", position - 1, record)
          else
            record.peer_count = peers
            if peers > 16 then result.truncated = true; issue("peer_limit", position - 1, record) end
            for index = 0, math.min(peers, 16) - 1 do
              local address = bdf(19 + index * 5)
              if address then record.peer_bdfs[#record.peer_bdfs + 1] = address end
            end
          end
        end
        if #result.slots < max_slots then result.slots[#result.slots + 1] = record
        else result.truncated = true; issue("slot_limit", position - 1) end
      elseif kind == 16 and length >= 15 then
        record.location_code, record.use_code = uint(fields, 4, 1), uint(fields, 5, 1)
        record.error_correction_code, record.device_count = uint(fields, 6, 1), uint(fields, 13, 2)
        local maximum = uint(fields, 7, 4)
        if maximum == 0x80000000 then
          record.maximum_capacity_bytes = uint(fields, 15, 8)
          if not record.maximum_capacity_bytes then issue("maximum_capacity", position - 1, record) end
        else record.maximum_capacity_bytes = maximum * 1024 end
        if #result.arrays < max_arrays then
          result.arrays[#result.arrays + 1] = record
          arrays[handle] = record
        else result.truncated = true; issue("array_limit", position - 1) end
      elseif kind == 17 and length >= 21 then
        record.array_handle = uint(fields, 4, 2)
        record.array_id = string.format("%04x", record.array_handle)
        record.locator, record.bank = read_string(16), read_string(17)
        record.manufacturer, record.part_number = read_string(23), read_string(26)
        record.firmware_version = read_string(43)
        record.memory_type_code = uint(fields, 18, 1)
        record.memory_type = MEMORY_TYPES[record.memory_type_code]
        record.form_factor_code = uint(fields, 14, 1)
        record.form_factor = FORM_FACTORS[record.form_factor_code]
        record.type_detail = uint(fields, 19, 2)
        local total, width = uint(fields, 8, 2), uint(fields, 10, 2)
        record.total_width_bits = total ~= 65535 and total or nil
        record.data_width_bits = width ~= 65535 and width or nil
        local attributes = uint(fields, 27, 1)
        record.rank = attributes and attributes % 16 > 0 and attributes % 16 or nil
        record.speed_mts, record.configured_speed_mts = speed(21, 84), speed(32, 88)
        for offset, key in pairs({ [34] = "minimum_voltage_mv", [36] = "maximum_voltage_mv", [38] = "configured_voltage_mv" }) do
          local voltage = uint(fields, offset, 2)
          record[key] = voltage and voltage > 0 and voltage or nil
        end
        local size = uint(fields, 12, 2)
        record.logical = record.memory_type_code == 31
        if record.logical then
          record.size_bytes = uint(fields, 76, 8)
        elseif size == 0 then
          record.populated, record.size_bytes = false, 0
        elseif size ~= 65535 then
          if size == 32767 then
            local extended = uint(fields, 28, 4)
            if extended and extended > 0 and extended < 0x80000000 then record.size_bytes = extended * 1024 * 1024
            else issue("size", position - 1, record) end
          else
            record.size_bytes = (size % 32768) * (size >= 32768 and 1024 or 1024 * 1024)
            if record.size_bytes == 0 then record.size_bytes = nil; issue("size", position - 1, record) end
          end
          record.populated = record.size_bytes and true or nil
        end
        if #result.devices < max_devices then result.devices[#result.devices + 1] = record
        else result.truncated = true; issue("device_limit", position - 1) end
      elseif kind == 19 and length >= 15 then
        address_range(15)
        record.array_handle = uint(fields, 12, 2)
        record.array_id = string.format("%04x", record.array_handle)
        local width = uint(fields, 14, 1)
        record.partition_width = width ~= 0xff and width or nil
        if #result.array_ranges < max_array_ranges then
          result.array_ranges[#result.array_ranges + 1] = record
        else result.truncated = true; issue("array_range_limit", position - 1) end
      elseif kind == 20 and length >= 19 then
        address_range(19)
        record.device_handle = uint(fields, 12, 2)
        record.device_id = string.format("%04x", record.device_handle)
        record.array_range_handle = uint(fields, 14, 2)
        record.array_range_id = string.format("%04x", record.array_range_handle)
        for offset, field in pairs({ [16] = "partition_row_position",
            [17] = "interleave_position", [18] = "interleaved_data_depth" }) do
          local value = uint(fields, offset, 1)
          if field == "partition_row_position" and value == 0 then
            issue("partition_row_position", position - 1, record)
          else record[field] = value ~= 0xff and value or nil end
        end
        if #result.device_ranges < max_device_ranges then
          result.device_ranges[#result.device_ranges + 1] = record
        else result.truncated = true; issue("device_range_limit", position - 1) end
      elseif kind == 37 and length >= 7 then
        record.channel_type_code = uint(fields, 4, 1)
        record.channel_type = CHANNEL_TYPES[record.channel_type_code]
        record.maximum_load = uint(fields, 5, 1)
        record.device_count = uint(fields, 6, 1)
        record.devices = {}
        if 7 + 3 * record.device_count > length then
          issue("channel_length", position - 1, record)
        else
          local total_load, seen_handles = 0, {}
          if record.device_count > 64 then
            result.truncated = true
            issue("channel_device_limit", position - 1, record)
          end
          for index = 0, record.device_count - 1 do
            local load = uint(fields, 7 + 3 * index, 1)
            local handle = uint(fields, 8 + 3 * index, 2)
            total_load = total_load + load
            if load == 0 then issue("channel_load", position - 1, record) end
            if seen_handles[handle] then
              issue("channel_device_duplicate", position - 1, record)
            end
            seen_handles[handle] = true
            if index < 64 then
              record.devices[#record.devices + 1] = {
                device_handle = handle, device_id = string.format("%04x", handle), load = load,
              }
            end
          end
          record.total_load = total_load
          if total_load > record.maximum_load then
            issue("channel_load", position - 1, record)
          end
        end
        if #result.channels < max_channels then
          result.channels[#result.channels + 1] = record
        else result.truncated = true; issue("channel_limit", position - 1) end
      elseif kind == 22 and length >= 16 then
        record.location = read_string(4)
        record.manufacturer = read_string(5)
        -- String offsets 06h/07h and word offsets 10h/12h contain manufacture
        -- dates and serials. Do not copy them into the parsed record.
        record.name = read_string(8)
        record.chemistry_code = uint(fields, 9, 1)
        record.chemistry = BATTERY_CHEMISTRIES[record.chemistry_code]
        local capacity = uint(fields, 10, 2)
        record.design_capacity_raw_mwh = capacity
        local multiplier = length >= 22 and uint(fields, 21, 1) or 1
        if multiplier == 0 then
          issue("battery_capacity_multiplier", position - 1, record)
        else
          record.design_capacity_multiplier = multiplier
          record.design_capacity_mwh = capacity > 0 and capacity * multiplier or nil
        end
        local voltage = uint(fields, 12, 2)
        record.design_voltage_mv = voltage > 0 and voltage or nil
        record.sbds_version = read_string(14)
        local maximum_error = uint(fields, 15, 1)
        if maximum_error <= 100 then record.maximum_error_percent = maximum_error
        elseif maximum_error ~= 0xff then issue("battery_maximum_error", position - 1, record) end
        if length >= 21 and record.chemistry_code == 2 then
          record.sbds_chemistry = read_string(20)
        end
        if #result.firmware_batteries < max_firmware_batteries then
          result.firmware_batteries[#result.firmware_batteries + 1] = record
        else result.truncated = true; issue("firmware_battery_limit", position - 1) end
      elseif kind == 38 and length >= 16 then
        record.interface_type_code = uint(fields, 4, 1)
        record.interface_type = BMC_INTERFACES[record.interface_type_code]
        local revision = uint(fields, 5, 1)
        if revision >> 4 <= 9 and (revision & 0x0f) <= 9 then
          record.ipmi_revision = string.format("%d.%d", revision >> 4, revision & 0x0f)
        else issue("bmc_revision", position - 1, record) end
        record.i2c_target_address = uint(fields, 6, 1)
        local storage = uint(fields, 7, 1)
        record.nv_storage_address = storage ~= 0xff and storage or nil
        local raw_address = qword_hex(fields, 8)
        record.base_address_field_hex = raw_address
        if raw_address ~= "0x0" and record.interface_type_code ~= 4 then
          record.address_space = fields:byte(9) & 1 == 1 and "io" or "memory"
        end
        if length >= 17 then
          local modifier = uint(fields, 16, 1)
          if record.interface_type_code == 4 and modifier ~= 0 then
            issue("bmc_address_modifier", position - 1, record)
          elseif record.interface_type_code ~= 4 then
            record.register_spacing_code = modifier >> 6
            record.register_spacing_bytes = BMC_REGISTER_SPACING[record.register_spacing_code]
            if modifier & 0x24 ~= 0 or record.register_spacing_bytes == nil then
              issue("bmc_address_modifier", position - 1, record)
            elseif raw_address ~= "0x0" then
              local low = (fields:byte(9) & 0xfe) | ((modifier >> 4) & 1)
              local decoded = fields:sub(1, 8) .. string.char(low) .. fields:sub(10)
              record.base_address_hex = qword_hex(decoded, 8)
            end
            record.interrupt_specified = modifier & 0x08 ~= 0
            if record.interrupt_specified then
              if length < 18 then issue("bmc_interrupt_length", position - 1, record)
              else
                local interrupt = uint(fields, 17, 1)
                record.interrupt_number = interrupt > 0 and interrupt or nil
                if record.interrupt_number then
                  record.interrupt_polarity = modifier & 0x02 ~= 0
                      and "active_high" or "active_low"
                  record.interrupt_trigger = modifier & 0x01 ~= 0
                      and "level" or "edge"
                end
              end
            end
          end
        end
        if #result.firmware_bmcs < max_firmware_bmcs then
          result.firmware_bmcs[#result.firmware_bmcs + 1] = record
        else result.truncated = true; issue("firmware_bmc_limit", position - 1) end
      elseif kind == 39 and length >= 16 then
        record.power_unit_group = uint(fields, 4, 1)
        record.location = read_string(5)
        record.name = read_string(6)
        record.manufacturer = read_string(7)
        -- Offsets 08h and 09h are serial and asset tag; neither leaves the parser.
        record.part_number = read_string(10)
        record.revision = read_string(11)
        local capacity = uint(fields, 12, 2)
        record.max_power_capacity_raw = capacity
        record.max_power_watts = capacity ~= 0x8000 and capacity or nil
        local characteristics = uint(fields, 14, 2)
        record.supply_type_code = (characteristics >> 10) & 0x0f
        record.supply_type = SUPPLY_TYPES[record.supply_type_code]
        record.status_code = (characteristics >> 7) & 0x07
        record.status = SUPPLY_STATUSES[record.status_code]
        record.range_switching_code = (characteristics >> 3) & 0x0f
        record.range_switching = SUPPLY_RANGES[record.range_switching_code]
        record.unplugged = characteristics & 0x04 ~= 0
        record.present = characteristics & 0x02 ~= 0
        record.hot_replaceable = characteristics & 0x01 ~= 0
        if characteristics & 0xc000 ~= 0 then
          issue("power_supply_characteristics", position - 1, record)
        end
        for _, spec in ipairs({ { 16, "voltage_probe_id" },
            { 18, "cooling_device_id" }, { 20, "current_probe_id" } }) do
          local reference = uint(fields, spec[1], 2)
          if reference and reference ~= 0xffff then
            record[spec[2]] = string.format("%04x", reference)
          end
        end
        if #result.firmware_power_supplies < max_firmware_supplies then
          result.firmware_power_supplies[#result.firmware_power_supplies + 1] = record
        else result.truncated = true; issue("firmware_power_supply_limit", position - 1) end
      elseif kind == 10 then
        -- Type 10 packs several functions into one structure. The handle
        -- identifies that structure, so each entry also needs its position.
        members = {}
        local count = (length - 4) // 2
        if (length - 4) % 2 ~= 0 then issue("onboard_length", position - 1, record) end
        for index = 1, count do
          if #result.onboard_devices >= max_onboard then
            result.truncated = true; issue("onboard_limit", position - 1); break
          end
          local member = { id = string.format("%04x:%d", handle, index), handle = handle,
            offset = position - 1, quality = record.quality, structure_type = 10,
            device_index = index, device_count = count }
          local offset = 4 + (index - 1) * 2
          local device_type = uint(fields, offset, 1)
          member.enabled = device_type & 0x80 ~= 0
          member.device_type_code = device_type & 0x7f
          -- Type 10's enumeration stops at SAS; newer Type 41 values do
          -- not acquire the same meaning in a legacy declaration.
          member.device_type = member.device_type_code <= 10
            and ONBOARD_TYPES[member.device_type_code] or nil
          member.designation = read_string(offset + 1, member)
          members[#members + 1] = member
          result.onboard_devices[#result.onboard_devices + 1] = member
        end
      elseif kind == 41 and length >= 11 then
        record.structure_type = 41
        record.designation = read_string(4)
        local device_type = uint(fields, 5, 1)
        record.enabled = device_type & 0x80 ~= 0
        record.device_type_code = device_type & 0x7f
        record.device_type = ONBOARD_TYPES[record.device_type_code]
        record.type_instance = uint(fields, 6, 1)
        local segment = uint(fields, 7, 2)
        local bus = uint(fields, 9, 1)
        local devfn = uint(fields, 10, 1)
        -- The all-FF tuple means no PCI address. Each field is otherwise a
        -- value: bus FF and device 1F.function 7 are legal coordinates.
        if not ((segment == 0xffff or segment == 0xff)
            and bus == 0xff and devfn == 0xff) then
          record.pci_bdf = string.format("%04x:%02x:%02x.%d",
            segment, bus, devfn >> 3, devfn & 7)
        end
        if #result.onboard_devices < max_onboard then
          result.onboard_devices[#result.onboard_devices + 1] = record
        else result.truncated = true; issue("onboard_limit", position - 1) end
      elseif kind == 42 and length >= 10 then
        record.interface_type_code = uint(fields, 4, 1)
        if record.interface_type_code <= 0x3f then
          record.interface_type = "MCTP host interface"
        elseif record.interface_type_code == 0x40 then
          record.interface_type = "Network host interface"
        elseif record.interface_type_code == 0xf0 then
          record.interface_type = "OEM host interface"
        end
        local old_oem = record.interface_type_code == 0xf0
          and type(metadata.major) == "number"
          and (metadata.major < 3 or (metadata.major == 3
            and type(metadata.minor) == "number" and metadata.minor < 2))
        if length < 11 and not old_oem then
          issue("structure_length", position - 1, record)
        else
          local data_offset, data_bytes, count_offset
          if old_oem then
            record.legacy_oem_format = true
            data_offset, data_bytes, count_offset = 5, 4, 9
          else
            data_offset, data_bytes = 6, uint(fields, 5, 1)
            count_offset = data_offset + data_bytes
          end
          record.interface_data_bytes = data_bytes
          record.protocols = {}
          if data_bytes < 4 or count_offset >= length then
            issue("host_interface_data_length", position - 1, record)
          else
            if record.interface_type_code == 0xf0 then
              record.oem_vendor_id = string.format("%02x%02x%02x%02x",
                fields:byte(data_offset + 1, data_offset + 4))
            end
            local declared = uint(fields, count_offset, 1)
            record.protocol_count = declared
            local cursor = count_offset + 1
            if declared > 64 then
              result.truncated = true
              issue("host_protocol_limit", position - 1, record)
            end
            for index = 1, declared do
              local protocol_type = uint(fields, cursor, 1)
              local protocol_bytes = uint(fields, cursor + 1, 1)
              if not protocol_bytes or cursor + 2 + protocol_bytes > length then
                issue("host_protocol_length", position - 1, record)
                break
              end
              if index <= 64 then
                record.protocols[#record.protocols + 1] = {
                  type_code = protocol_type, type = HOST_PROTOCOLS[protocol_type],
                  data_bytes = protocol_bytes,
                }
              end
              cursor = cursor + 2 + protocol_bytes
            end
            if cursor ~= length and #record.protocols == math.min(declared, 64) then
              issue("host_protocol_trailing_bytes", position - 1, record)
            end
          end
          if #result.host_interfaces < max_host_interfaces then
            result.host_interfaces[#result.host_interfaces + 1] = record
          else result.truncated = true; issue("host_interface_limit", position - 1) end
        end
      elseif kind == 43 and length >= 31 then
        local vendor = fields:sub(5, 8):gsub("%z+$", "")
        if vendor ~= "" and not vendor:find("[^ -~]") then
          record.vendor_id = vendor
        else issue("tpm_vendor_id", position - 1, record) end
        record.spec_major = uint(fields, 8, 1)
        record.spec_minor = uint(fields, 9, 1)
        record.spec_version = string.format("%d.%d", record.spec_major, record.spec_minor)
        record.firmware_version_1_hex = string.format("0x%08x", uint(fields, 10, 4))
        local firmware_version_2 = uint(fields, 14, 4)
        record.firmware_version_2_hex = string.format("0x%08x", firmware_version_2)
        if record.spec_major == 1 and firmware_version_2 ~= 0 then
          issue("tpm_firmware_version_2", position - 1, record)
        end
        record.description = read_string(18)
        local bits = uint(fields, 19, 1)
        local reserved = bits & 0xc3 ~= 0
        for offset = 20, 26 do
          if uint(fields, offset, 1) ~= 0 then reserved = true end
        end
        if reserved then issue("tpm_characteristics", position - 1, record) end
        record.characteristics_supported = bits & 0x04 == 0
        if record.characteristics_supported then
          record.family_configurable_firmware = bits & 0x08 ~= 0
          record.family_configurable_platform = bits & 0x10 ~= 0
          record.family_configurable_oem = bits & 0x20 ~= 0
        end
        -- OEM-defined bytes at 1Bh are intentionally not copied out.
        if #result.firmware_tpms < max_firmware_tpms then
          result.firmware_tpms[#result.firmware_tpms + 1] = record
        else result.truncated = true; issue("firmware_tpm_limit", position - 1) end
      elseif kind == 45 and length >= 24 then
        record.name = read_string(4)
        record.version = read_string(5)
        record.version_format = uint(fields, 6, 1)
        record.firmware_id_format = uint(fields, 8, 1)
        -- Free-form IDs can encode an asset or serial number. Only a valid
        -- standard GUID is public; unknown/OEM formats remain unexported.
        if record.firmware_id_format == 1 then
          local id = read_string(7)
          local normalized = GUID.normalize(id)
          if normalized then
            record.firmware_id = normalized
          elseif id then issue("firmware_component_id", position - 1, record) end
        end
        record.release_date = read_string(9)
        record.manufacturer = read_string(10)
        record.lowest_supported_version = read_string(11)
        local image = fields:sub(13, 20)
        if image ~= string.rep("\255", 8) then
          record.image_size_bytes = uint(fields, 12, 8)
          if not record.image_size_bytes then
            record.image_size_hex = qword_hex(fields, 12)
          end
        end
        local characteristics = uint(fields, 20, 2)
        record.updatable = characteristics & 1 ~= 0
        record.write_protected = characteristics & 2 ~= 0
        if characteristics & 0xfffc ~= 0 then
          issue("firmware_component_characteristics", position - 1, record)
        end
        record.state_code = uint(fields, 22, 1)
        record.state = FIRMWARE_STATES[record.state_code]
        record.associated_count = uint(fields, 23, 1)
        record.associated_handles = {}
        local available = (length - 24) // 2
        record.association_complete = available >= record.associated_count
            and record.associated_count <= 64
        if not record.association_complete then
          result.truncated = record.associated_count > 64 or result.truncated
          issue("firmware_component_associations", position - 1, record)
        end
        local associated_seen = {}
        for index = 1, math.min(record.associated_count, available, 64) do
          local associated = uint(fields, 24 + (index - 1) * 2, 2)
          if associated ~= 0xffff then
            if associated_seen[associated] then
              record.association_complete = false
              issue("firmware_component_association_duplicate", position - 1, record)
            else
              associated_seen[associated] = true
              record.associated_handles[#record.associated_handles + 1] =
                string.format("%04x", associated)
            end
          end
        end
        if #result.firmware_components < max_firmware_components then
          result.firmware_components[#result.firmware_components + 1] = record
        else result.truncated = true; issue("firmware_component_limit", position - 1) end
      else issue("structure_length", position - 1, record) end
    end
    local retained = members or (record and { record })
    if seen[handle] then
      issue("duplicate_handle", position - 1, record)
      for _, group in ipairs({ type(seen[handle]) == "table" and seen[handle] or {}, retained or {} }) do
        for _, item in ipairs(group) do item.ambiguous = true; item.quality = "partial" end
      end
    else seen[handle] = retained or true end
    position = terminator + 2
  end
  if not ended and not (metadata.table_bytes and metadata.structure_count == result.structure_count
      and position == limit + 1) then issue("end_of_table", position - 1) end
  if metadata.structure_count and metadata.structure_count ~= result.structure_count then
    issue("structure_count", position - 1)
  end
  local device_counts = {}
  for _, device in ipairs(result.devices) do
    local parent = arrays[device.array_handle]
    if not parent or parent.ambiguous or device.ambiguous then
      device.array_id = nil
      issue("array_handle", device.offset, device)
    else
      device_counts[device.array_handle] = (device_counts[device.array_handle] or 0) + 1
    end
  end
  for _, array in ipairs(result.arrays) do
    if not array.ambiguous and array.device_count ~= (device_counts[array.handle] or 0) then
      issue("device_count", array.offset, array)
    end
  end
  local devices, array_ranges = {}, {}
  for _, device in ipairs(result.devices) do devices[device.handle] = device end
  for _, channel in ipairs(result.channels) do
    if not channel.ambiguous and channel.quality == "fresh" then
      for _, member in ipairs(channel.devices) do
        local device = devices[member.device_handle]
        if not device or device.ambiguous or device.quality ~= "fresh" then
          issue("channel_device_handle", channel.offset, channel)
          break
        end
      end
    end
  end
  if not result.truncated then
    local group_counts = {}
    for _, supply in ipairs(result.firmware_power_supplies) do
      if supply.power_unit_group > 0 then
        group_counts[supply.power_unit_group] =
          (group_counts[supply.power_unit_group] or 0) + 1
      end
    end
    for _, supply in ipairs(result.firmware_power_supplies) do
      if supply.power_unit_group > 0
          and group_counts[supply.power_unit_group] < 2 then
        issue("power_unit_group", supply.offset, supply)
      end
    end
  end
  for _, range in ipairs(result.array_ranges) do
    array_ranges[range.handle] = range
    local parent = arrays[range.array_handle]
    if not parent or parent.ambiguous or range.ambiguous then
      range.array_id = nil
      issue("array_range_handle", range.offset, range)
    end
  end
  for _, range in ipairs(result.device_ranges) do
    local device, parent = devices[range.device_handle], array_ranges[range.array_range_handle]
    if not device or not parent or device.ambiguous or parent.ambiguous
        or range.ambiguous or not parent.array_id
        or device.array_handle ~= parent.array_handle then
      range.device_id, range.array_range_id = nil, nil
      issue("device_range_handle", range.offset, range)
    elseif range.start_address_bytes and parent.start_address_bytes
        and (range.start_address_bytes < parent.start_address_bytes
          or range.end_address_bytes > parent.end_address_bytes) then
      range.device_id, range.array_range_id = nil, nil
      issue("device_range_bounds", range.offset, range)
    end
  end
  if #result.arrays == 0 and #result.devices == 0 and #result.slots == 0
      and #result.baseboards == 0 and #result.enclosures == 0
      and #result.ports == 0
      and #result.onboard_devices == 0
      and #result.channels == 0
      and #result.firmware_batteries == 0
      and #result.firmware_bmcs == 0
      and #result.firmware_tpms == 0
      and #result.firmware_components == 0
      and #result.host_interfaces == 0
      and #result.firmware_power_supplies == 0
      and #result.processors == 0 and #result.caches == 0
      and #result.array_ranges == 0 and #result.device_ranges == 0
      and result.partial then return nil, "smbios_invalid" end
  return result
end

return M
