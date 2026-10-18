-- Public declarations from EDID 1.x base and CTA extension blocks. No serial values or raw
-- descriptors leave this parser. Driver-corrected/current modes belong to KMS.
local CTA = require("wtop.format.edid_cta")
local M = {}
local BLOCK = 128
local MAX_BYTES = 256 * BLOCK
local HEADER = "\0\255\255\255\255\255\255\0"
local INTERFACES = { "DVI", "HDMI-A", "HDMI-B", "MDDI", "DisplayPort" }

local function checksum(bytes, start)
  local sum = 0
  for index = start, start + BLOCK - 1 do sum = sum + bytes:byte(index) end
  return sum % 256 == 0
end

local function name(bytes)
  -- EDID text is printable ASCII, terminated by LF, then padded with spaces.
  local value = bytes:match("^([^\n]*)")
  if value:find("[^\32-\126]") then return nil end
  value = value:match("^%s*(.-)%s*$")
  return value ~= "" and value or nil
end

local function timing(bytes, start, preferred)
  local b = function(offset) return bytes:byte(start + offset) end
  local clock = (b(0) + b(1) * 256) * 10000
  local horizontal = b(2) + (b(4) >> 4) * 256
  local hblank = b(3) + (b(4) & 15) * 256
  local vertical = b(5) + (b(7) >> 4) * 256
  local vblank = b(6) + (b(7) & 15) * 256
  if horizontal == 0 or vertical == 0 or hblank == 0 or vblank == 0 then return nil end
  local interlaced = b(17) & 128 ~= 0
  local result = { horizontal_active_pixels = horizontal, vertical_active_lines = vertical,
    horizontal_blanking_pixels = hblank, vertical_blanking_lines = vblank,
    pixel_clock_hz = clock, interlaced = interlaced, preferred = preferred }
  -- Interlaced EDIDs can encode field or frame height. Preserve encoded lines
  -- without guessing frame geometry or a field/frame refresh rate.
  if not interlaced then result.refresh_hz = clock / ((horizontal + hblank) * (vertical + vblank)) end
  local width, height = b(12) + (b(14) >> 4) * 256, b(13) + (b(14) & 15) * 256
  if width > 0 and height > 0 then result.width_mm, result.height_mm = width, height end
  return result
end

function M.parse(bytes)
  if type(bytes) ~= "string" or #bytes < BLOCK then return nil, "edid_incomplete" end
  if #bytes > MAX_BYTES then return nil, "edid_too_large" end
  if bytes:sub(1, 8) ~= HEADER then return nil, "edid_invalid_header" end
  if not checksum(bytes, 1) then return nil, "edid_invalid_checksum" end
  local version, revision = bytes:byte(19, 20)
  if version ~= 1 or revision > 4 then return nil, "edid_unsupported_version" end
  local result = { version = "1." .. revision, quality = "fresh",
    serial_present = bytes:sub(13, 16) ~= "\0\0\0\0",
    extension_count = bytes:byte(127), detailed_timings = {}, extensions = {},
    extensions_decoded = false, extensions_truncated = false }
  local function partial(reason)
    result.quality = "partial"
    result.reason = result.reason or reason
  end
  local manufacturer = bytes:byte(9) * 256 + bytes:byte(10)
  local letters = { (manufacturer >> 10) & 31, (manufacturer >> 5) & 31, manufacturer & 31 }
  if manufacturer & 32768 == 0 and letters[1] >= 1 and letters[1] <= 26
      and letters[2] >= 1 and letters[2] <= 26 and letters[3] >= 1 and letters[3] <= 26 then
    result.manufacturer = string.char(64 + letters[1], 64 + letters[2], 64 + letters[3])
  else partial("edid_invalid_manufacturer") end
  result.product_code = bytes:byte(11) + bytes:byte(12) * 256
  local week, year = bytes:byte(17, 18)
  if revision >= 4 and week == 255 then result.model_year = 1990 + year
  else
    result.manufacture_year = 1990 + year
    if week >= 1 and week <= 54 then result.manufacture_week = week
    elseif week ~= 0 then partial("edid_invalid_date") end
  end
  local input = bytes:byte(21)
  result.digital = input & 128 ~= 0
  if result.digital and revision >= 4 then
    local depth = (input >> 4) & 7
    if depth >= 1 and depth <= 6 then result.bits_per_color = 4 + 2 * depth end
    result.interface = INTERFACES[input & 15]
  end
  local width, height = bytes:byte(22, 23)
  if width > 0 and height > 0 then result.width_mm, result.height_mm = width * 10, height * 10 end
  local preferred = revision >= 4 or bytes:byte(25) & 2 ~= 0
  for start = 55, 109, 18 do
    if bytes:byte(start) ~= 0 or bytes:byte(start + 1) ~= 0 then
      local value = timing(bytes, start, preferred and #result.detailed_timings == 0)
      if value then result.detailed_timings[#result.detailed_timings + 1] = value
      else partial("edid_invalid_timing") end
    elseif bytes:byte(start + 2) == 0 and bytes:byte(start + 4) == 0 then
      local tag = bytes:byte(start + 3)
      if tag == 252 then
        local value = name(bytes:sub(start + 5, start + 17))
        if value and not result.name then result.name = value
        elseif not value then partial("edid_invalid_name") end
      elseif tag == 255 and bytes:sub(start + 5, start + 17):find("[^%s%z]") then
        result.serial_present = true
      end
    end
  end
  local expected = (1 + result.extension_count) * BLOCK
  result.blocks_available = #bytes // BLOCK
  if #bytes ~= expected then partial("edid_incomplete") end
  local budget = CTA.budget()
  local complete = result.extension_count > 0 and #bytes == expected
  for index = 1, math.min(result.blocks_available - 1, result.extension_count) do
    local start = index * BLOCK + 1
    local valid = checksum(bytes, start)
    if not valid then partial("edid_invalid_extension_checksum");complete = false end
    if index <= CTA.MAX_EXTENSIONS then
      local extension = { index = index, tag = bytes:byte(start), checksum_ok = valid,
        quality = valid and "fresh" or "partial", decoded = false }
      result.extensions[#result.extensions + 1] = extension
      if not valid then extension.reason = "edid_invalid_extension_checksum"
      elseif extension.tag == 2 then CTA.parse(bytes, start, extension, budget, timing)
      else
        extension.quality = "partial"
        extension.reason = "edid_unsupported_extension"
      end
      if not extension.decoded then complete = false end
      if extension.quality ~= "fresh" then partial(extension.reason) end
      if extension.truncated then result.extensions_truncated = true end
    else
      result.extensions_truncated, complete = true, false
      partial("edid_extensions_truncated")
    end
  end
  result.extensions_decoded = complete
  return result
end

return M
