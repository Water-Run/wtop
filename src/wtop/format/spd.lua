-- Public FPM/EDO/SDR/DDR/DDR2/DDR3/DDR4/DDR5 SPD fields only. The serial number and raw EEPROM
-- bytes never leave the collector. Offsets follow the JEDEC SPD layouts.
-- DDR5 references are pinned in tests/fixtures/spd/metadata.json.
local M = {}

local DDR5_MODULE_TYPES = {
  [1] = "RDIMM", [2] = "UDIMM", [3] = "SO-DIMM", [4] = "LRDIMM",
  [5] = "CUDIMM", [6] = "CSODIMM", [7] = "MRDIMM", [8] = "CAMM2",
  [9] = "SOCAMM2", [10] = "DDIMM", [11] = "Soldered",
}
local DDR4_MODULE_TYPES = {
  [1] = "RDIMM", [2] = "UDIMM", [3] = "SO-DIMM", [4] = "LRDIMM",
  [5] = "Mini-RDIMM", [6] = "Mini-UDIMM", [8] = "72-bit SO-RDIMM",
  [9] = "72-bit SO-UDIMM", [12] = "16-bit SO-DIMM", [13] = "32-bit SO-DIMM",
}
local DDR3_MODULE_TYPES = {
  [1] = "RDIMM", [2] = "UDIMM", [3] = "SO-DIMM", [4] = "Micro-DIMM",
  [5] = "Mini-RDIMM", [6] = "Mini-UDIMM", [7] = "Mini-CDIMM",
  [8] = "72-bit SO-UDIMM", [9] = "72-bit SO-RDIMM", [10] = "72-bit SO-CDIMM",
  [11] = "LRDIMM", [12] = "16-bit SO-DIMM", [13] = "32-bit SO-DIMM",
}
local DDR2_MODULE_TYPES = {
  [1] = "RDIMM", [2] = "UDIMM", [4] = "SO-DIMM",
  [6] = "72-bit SO-CDIMM", [7] = "72-bit SO-RDIMM",
  [8] = "Micro-DIMM", [16] = "Mini-RDIMM", [32] = "Mini-UDIMM",
}
local DDR2_RANK_MIB = {
  [0x20] = 128, [0x40] = 256, [0x80] = 512,
  [0x01] = 1024, [0x02] = 2048, [0x04] = 4096,
  [0x08] = 8192, [0x10] = 16384,
}
local DDR_RANK_MIB = {
  [0x04] = 16, [0x08] = 32, [0x10] = 64,
  [0x20] = 128, [0x40] = 256, [0x80] = 512,
  [0x01] = 1024, [0x02] = 2048,
}
local SDR_ROW_MIB = {
  [0x01] = 4, [0x02] = 8, [0x04] = 16, [0x08] = 32,
  [0x10] = 64, [0x20] = 128, [0x40] = 256, [0x80] = 512,
}

local function crc16(data, first, length)
  local crc = 0
  for index = first, first + length - 1 do
    crc = crc ~ (data:byte(index) << 8)
    for _ = 1, 8 do
      crc = ((crc << 1) ~ (crc & 0x8000 ~= 0 and 0x1021 or 0)) & 0xffff
    end
  end
  return crc
end

local function part_number(data, offset, length)
  if #data < offset + length then return nil end
  local part = data:sub(offset + 1, offset + length):gsub("%s+$", "")
  return part ~= "" and #part <= length and not part:find("[^ -~]") and part or nil
end

local function legacy_checksum_valid(data)
  local checksum = 0
  for index = 1, 63 do checksum = (checksum + data:byte(index)) & 0xff end
  return checksum == data:byte(64)
end

local function legacy_cycle_ps(data, maximum, special_fractions)
  local cycle = data:byte(10)
  local digit = cycle & 0x0f
  local fraction = digit <= 9 and digit * 100
    or special_fractions and ({ [0xa] = 250, [0xb] = 330,
        [0xc] = 660, [0xd] = 750 })[digit] or nil
  if not fraction then return nil end
  local cycle_ps = (cycle >> 4) * 1000 + fraction
  return cycle_ps >= 200 and cycle_ps <= maximum and cycle_ps or nil
end

local function legacy_module_type(attributes)
  return attributes & 0x02 ~= 0 and "Registered"
    or attributes & 0x01 ~= 0 and "Buffered" or "Unbuffered"
end

local function legacy_widths(data)
  local total = data:byte(7) + 256 * data:byte(8)
  if total < 8 or total > 256 then return nil, nil end
  local correction = data:byte(12) & 0x03 ~= 0
  local width
  if correction then
    for _, extension in ipairs({ 8, 16 }) do
      local candidate = total - extension
      if candidate >= 8 and candidate & (candidate - 1) == 0 then
        width = candidate
        break
      end
    end
  elseif total & (total - 1) == 0 then
    width = total
  end
  return width, total
end

-- FPM/EDO modules include 9- and 36-bit parity widths as well as 72-bit ECC.
-- Byte 11 says whether the extra bits are present; the data portion must be
-- an exact power of two before it can be used to derive a capacity.
local function asynchronous_widths(data)
  local total = data:byte(7) + 256 * data:byte(8)
  if total < 8 or total > 256 then return nil, nil end
  local correction = data:byte(12)
  local width
  if correction == 0 then
    if total & (total - 1) == 0 then width = total end
  elseif correction == 1 or correction == 2 then
    for _, extension in ipairs({ 1, 2, 4, 8, 16 }) do
      local candidate = total - extension
      if candidate >= 8 and candidate & (candidate - 1) == 0 then
        width = candidate
        break
      end
    end
  end
  return width, total
end

local function asynchronous_bank_bytes(row, column, width)
  if row < 8 or row > 15 or column < 8 or column > 15 then return nil end
  return (1 << (row + column)) * (width // 8)
end

local function parse_asynchronous(data)
  if #data < 64 or data:byte(1) < 64 or data:byte(1) > 128
      or (data:byte(2) ~= 7 and data:byte(2) ~= 8) then
    return nil, "unsupported_spd"
  end
  local checksum_valid = legacy_checksum_valid(data)
  local result = {
    memory_type = data:byte(3) == 0x01 and "FPM DRAM" or "EDO DRAM",
    revision = tostring(data:byte(63)),
    checksum_valid = checksum_valid,
    bytes_read = #data, complete = #data >= (data:byte(2) == 7 and 128 or 256),
    part_number = data:byte(1) >= 91 and part_number(data, 73, 18) or nil,
  }
  if checksum_valid then
    local banks = data:byte(6)
    local width, total = asynchronous_widths(data)
    result.module_banks = banks >= 1 and banks <= 4 and banks or nil
    result.data_width_bits = width
    result.total_width_bits = total
    if width and banks >= 1 and banks <= 2 then
      local row_byte, column_byte = data:byte(4), data:byte(5)
      local row1, column1 = row_byte & 0x0f, column_byte & 0x0f
      local first = asynchronous_bank_bytes(row1, column1, width)
      if first then
        if banks == 1 and row_byte >> 4 == 0 and column_byte >> 4 == 0 then
          result.size_bytes = first
        elseif banks == 2 then
          local row2 = row_byte >> 4 ~= 0 and row_byte >> 4 or row1
          local column2 = column_byte >> 4 ~= 0 and column_byte >> 4 or column1
          local second = asynchronous_bank_bytes(row2, column2, width)
          if second then result.size_bytes = first + second end
        end
      end
    end
  end
  return result
end

-- DDR5 common-module widths are per subchannel. Only apply a known,
-- CRC-checked layout; a short page or unsupported organization stays unknown.
local function ddr5_geometry(data, result)
  local total_code = (data:byte(1) >> 4) & 7
  if not result.crc_valid or data:byte(2) >> 4 ~= 1
      or data:byte(193) >> 4 ~= 1 or total_code < 2 or total_code > 4
      or data:byte(4) & 0xf0 ~= 0 or not result.module_type then return end
  local organization, bus = data:byte(235), data:byte(236)
  local channels_code, primary_code, extension_code = bus >> 5, bus & 7, (bus >> 3) & 3
  if channels_code > 3 or primary_code > 3 or extension_code > 2
      or organization & 0x87 ~= 0 then return end
  local channels = 1 << channels_code
  local width = (8 << primary_code) * channels
  local extension = ({ [0] = 0, [1] = 4, [2] = 8 })[extension_code]
  result.rank = ((organization >> 3) & 7) + 1
  result.data_width_bits = width
  result.total_width_bits = width + extension * channels
  local channel_width = 8 << primary_code
  local function rank_bytes(offset)
    local density_package, sdram = data:byte(offset + 1), data:byte(offset + 3)
    local density = ({ [1] = 4, [2] = 8, [3] = 12, [4] = 16,
      [5] = 24, [6] = 32, [7] = 48, [8] = 64 })[density_package & 0x1f]
    local package_code, device_code = density_package >> 5, sdram >> 5
    if not density or package_code > 5 or device_code > 3
        or sdram & 0x1f ~= 0 then return nil end
    local device_width = 4 << device_code
    if channel_width < device_width then return nil end
    -- DDP dies are already represented by ranks; only 3DS adds logical ranks.
    local stack = package_code >= 2 and (1 << (package_code - 1)) or 1
    return (density * 128 * 1024 * 1024)
      * (channel_width // device_width) * channels * stack
  end
  local primary = rank_bytes(4)
  if not primary then return end
  if organization & 0x40 == 0 then
    result.size_bytes = primary * result.rank
  elseif result.rank >= 2 then
    -- Primary SDRAM describes even ranks, secondary SDRAM the odd ranks.
    -- Each may use a different die density, I/O width and 3DS stack.
    local secondary = rank_bytes(8)
    if secondary then
      local odd = result.rank // 2
      result.size_bytes = primary * (result.rank - odd) + secondary * odd
    end
  end
end

local function parse_ddr5(data)
  if #data < 24 then return nil, "unsupported_spd" end
  local total_code = (data:byte(1) >> 4) & 7
  local total_bytes = ({ [1] = 256, [2] = 512, [3] = 1024, [4] = 2048 })[total_code]
  local revision = data:byte(2)
  local type_code = data:byte(4) & 0x0f
  local cycle_ps = data:byte(21) + 256 * data:byte(22)
  local result = {
    memory_type = "DDR5", module_type_code = type_code,
    module_type = DDR5_MODULE_TYPES[type_code],
    revision = string.format("%d.%d", revision >> 4, revision & 0x0f),
    minimum_cycle_ps = cycle_ps >= 200 and cycle_ps <= 5000 and cycle_ps or nil,
    bytes_read = #data, complete = total_bytes ~= nil and #data >= total_bytes,
  }
  if #data >= 512 then
    local stored = data:byte(511) + 256 * data:byte(512)
    result.crc_valid = crc16(data, 1, 510) == stored
  end
  ddr5_geometry(data, result)
  result.part_number = part_number(data, 521, 30)
  return result
end

local function parse_ddr4(data)
  if #data < 128 then return nil, "unsupported_spd" end
  local header = data:byte(1)
  local total_code, used_code = (header >> 4) & 7, header & 0x0f
  local total_bytes = total_code == 1 and 256 or total_code == 2 and 512 or nil
  local used_bytes = ({ [1] = 128, [2] = 256, [3] = 384, [4] = 512 })[used_code]
  if not total_bytes or not used_bytes or used_bytes > total_bytes then
    return nil, "unsupported_spd"
  end
  local revision = data:byte(2)
  local type_code = data:byte(4) & 0x0f
  local fine = data:byte(126)
  if fine >= 128 then fine = fine - 256 end
  local cycle_ps = data:byte(19) * 125 + fine
  local result = {
    memory_type = "DDR4", module_type_code = type_code,
    module_type = DDR4_MODULE_TYPES[type_code],
    revision = string.format("%d.%d", revision >> 4, revision & 0x0f),
    minimum_cycle_ps = cycle_ps >= 200 and cycle_ps <= 5000 and cycle_ps or nil,
    temperature_sensor_present = data:byte(15) & 0x80 ~= 0,
    bytes_read = #data, complete = #data >= 512,
  }
  local base = data:byte(127) + 256 * data:byte(128)
  local base_length = header & 0x80 ~= 0 and 117 or 126
  result.crc_base_valid = crc16(data, 1, base_length) == base
  if result.crc_base_valid then
    local density = data:byte(5) & 0x0f
    local organization = data:byte(13)
    local bus = data:byte(14)
    local sdram_width_code, bus_width_code = organization & 7, bus & 7
    local ranks = ((organization >> 3) & 7) + 1
    if sdram_width_code <= 3 and bus_width_code <= 3 then
      local sdram_width = 4 << sdram_width_code
      local bus_width = 8 << bus_width_code
      result.rank = ranks
      result.data_width_bits = bus_width
      result.total_width_bits = bus_width + (bus & 8 ~= 0 and 8 or 0)
      -- The simple density/organization formula does not describe 3DS stacks.
      if density <= 8 and bus_width >= sdram_width and data:byte(7) & 0x80 == 0 then
        local size_mib = ((256 << density) // 8) * (bus_width // sdram_width) * ranks
        result.size_bytes = size_mib * 1024 * 1024
      end
    end
  end
  if #data >= 256 and used_bytes >= 256 then
    local module = data:byte(255) + 256 * data:byte(256)
    result.crc_valid = result.crc_base_valid and crc16(data, 129, 126) == module
  end
  if used_bytes > 320 then result.part_number = part_number(data, 329, 20) end
  return result
end

local function parse_ddr3(data)
  if #data < 128 then return nil, "unsupported_spd" end
  local header, revision = data:byte(1), data:byte(2)
  local type_code = data:byte(4) & 0x0f
  local stored_crc = data:byte(127) + 256 * data:byte(128)
  local crc_valid = crc16(data, 1, header & 0x80 ~= 0 and 117 or 126) == stored_crc
  local result = {
    memory_type = "DDR3", module_type_code = type_code,
    module_type = DDR3_MODULE_TYPES[type_code],
    revision = string.format("%d.%d", revision >> 4, revision & 0x0f),
    crc_valid = crc_valid, crc_base_valid = crc_valid,
    temperature_sensor_present = data:byte(33) & 0x80 ~= 0,
    bytes_read = #data, complete = #data >= 256,
  }
  if crc_valid then
    local density = data:byte(5) & 0x0f
    local organization, bus = data:byte(8), data:byte(9)
    local width_code, bus_code = organization & 7, bus & 7
    local rank_code, extension_code = (organization >> 3) & 7, (bus >> 3) & 3
    if density <= 6 and width_code <= 3 and bus_code <= 3
        and rank_code <= 3 and extension_code <= 1 then
      local sdram_width, bus_width = 4 << width_code, 8 << bus_code
      if bus_width >= sdram_width then
        result.rank = rank_code + 1
        result.data_width_bits = bus_width
        result.total_width_bits = bus_width + extension_code * 8
        local size_mib = ((256 << density) // 8)
          * (bus_width // sdram_width) * result.rank
        result.size_bytes = size_mib * 1024 * 1024
      end
    end
    local dividend, divisor, cycles = data:byte(11), data:byte(12), data:byte(13)
    if dividend > 0 and divisor > 0 and cycles > 0 then
      local cycle_ps = cycles * 1000 * dividend / divisor
      if revision >= 0x11 then
        local fine_timebase = data:byte(10)
        local fine_divisor = fine_timebase & 0x0f
        if fine_divisor > 0 then
          local fine = data:byte(35)
          if fine >= 128 then fine = fine - 256 end
          cycle_ps = cycle_ps + fine * (fine_timebase >> 4) / fine_divisor
        end
      end
      cycle_ps = math.floor(cycle_ps + 0.5)
      if cycle_ps >= 200 and cycle_ps <= 5000 then result.minimum_cycle_ps = cycle_ps end
    end
  end
  result.part_number = part_number(data, 128, 18)
  return result
end

local function parse_ddr2(data)
  if #data < 64 then return nil, "unsupported_spd" end
  local revision = data:byte(63)
  local checksum_valid = legacy_checksum_valid(data)
  local type_code = data:byte(21) & 0x3f
  local result = {
    memory_type = "DDR2", module_type_code = type_code,
    module_type = DDR2_MODULE_TYPES[type_code],
    revision = string.format("%d.%d", revision >> 4, revision & 0x0f),
    checksum_valid = checksum_valid,
    bytes_read = #data, complete = #data >= 256,
    part_number = data:byte(1) >= 91 and part_number(data, 73, 18) or nil,
  }
  if checksum_valid then
    local ranks = (data:byte(6) & 7) + 1
    local data_width, total_width = legacy_widths(data)
    local density = data:byte(32)
    if ranks <= 4 and total_width then
      result.rank = ranks
      result.data_width_bits = data_width
      result.total_width_bits = total_width
      -- Byte 31 directly describes the density of one rank.
      if DDR2_RANK_MIB[density] then
        result.size_bytes = DDR2_RANK_MIB[density] * ranks * 1024 * 1024
      end
    end
    result.minimum_cycle_ps = legacy_cycle_ps(data, 10000, true)
  end
  return result
end

local function parse_ddr(data)
  if #data < 64 then return nil, "unsupported_spd" end
  local revision = data:byte(63)
  local checksum_valid = legacy_checksum_valid(data)
  local attributes = data:byte(22)
  local result = {
    memory_type = "DDR",
    module_type = legacy_module_type(attributes),
    revision = string.format("%d.%d", revision >> 4, revision & 0x0f),
    checksum_valid = checksum_valid,
    bytes_read = #data, complete = #data >= 256,
    part_number = data:byte(1) >= 91 and part_number(data, 73, 18) or nil,
  }
  if checksum_valid then
    local ranks = data:byte(6)
    local data_width, total_width = legacy_widths(data)
    local density = data:byte(32)
    if ranks >= 1 and ranks <= 4 and total_width then
      result.rank = ranks
      result.data_width_bits = data_width
      result.total_width_bits = total_width
      if DDR_RANK_MIB[density] then
        result.size_bytes = DDR_RANK_MIB[density] * ranks * 1024 * 1024
      end
    end
    result.minimum_cycle_ps = legacy_cycle_ps(data, 10000, true)
  end
  return result
end

local function parse_sdr(data)
  if #data < 64 or data:byte(1) < 64 or data:byte(1) > 128
      or (data:byte(2) ~= 7 and data:byte(2) ~= 8) then
    return nil, "unsupported_spd"
  end
  local revision = data:byte(63)
  local checksum_valid = legacy_checksum_valid(data)
  local result = {
    memory_type = "SDR SDRAM",
    module_type = legacy_module_type(data:byte(22)),
    revision = string.format("%d.%d", revision >> 4, revision & 0x0f),
    checksum_valid = checksum_valid,
    bytes_read = #data, complete = #data >= (data:byte(2) == 7 and 128 or 256),
    part_number = data:byte(1) >= 91 and part_number(data, 73, 18) or nil,
  }
  if checksum_valid then
    local rows = data:byte(6)
    local data_width, total_width = legacy_widths(data)
    if rows >= 1 and rows <= 4 and total_width then
      result.rank = rows
      result.data_width_bits = data_width
      result.total_width_bits = total_width
      local density = data:byte(32)
      local codes, sum = 0, 0
      for bit = 0, 7 do
        local row_mib = SDR_ROW_MIB[1 << bit]
        if density & (1 << bit) ~= 0 then
          codes = codes + 1
          sum = sum + row_mib
        end
      end
      if codes == 1 then
        result.size_bytes = sum * rows * 1024 * 1024
      elseif rows == 2 and codes == 2 then
        result.size_bytes = sum * 1024 * 1024
      end
    end
    result.minimum_cycle_ps = legacy_cycle_ps(data, 20000, false)
  end
  return result
end

function M.parse(data)
  if type(data) ~= "string" or #data < 3 or #data > 1024 then
    return nil, "unsupported_spd"
  end
  if data:byte(3) == 0x12 then return parse_ddr5(data) end
  if data:byte(3) == 0x0c and #data <= 512 then return parse_ddr4(data) end
  if data:byte(3) == 0x0b and #data <= 256 then return parse_ddr3(data) end
  if data:byte(3) == 0x08 and #data <= 256 then return parse_ddr2(data) end
  if data:byte(3) == 0x07 and #data <= 256 then return parse_ddr(data) end
  if data:byte(3) == 0x04 and #data <= 256 then return parse_sdr(data) end
  if (data:byte(3) == 0x01 or data:byte(3) == 0x02) and #data <= 256 then
    return parse_asynchronous(data)
  end
  return nil, "unsupported_spd"
end

return M
