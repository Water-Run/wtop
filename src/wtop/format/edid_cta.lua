-- Bounded public CTA declarations from a checksum-verified EDID extension.
-- These describe the sink's cached claims, not an active HDMI/DP signal.
local Modes = require("wtop.format.cta_modes")
local M = { MAX_EXTENSIONS = 32 }
local LIMITS = { blocks = 128, video = 128, audio = 32, timings = 32,
  vendors = 16, speakers = 16, colorimetry = 16, hdr = 16, maps = 16 }
local AUDIO = { "Linear PCM", "AC-3", "MPEG-1 Layers 1/2", "MP3", "MPEG-2 multichannel",
  "AAC LC", "DTS", "ATRAC", "One Bit Audio", "Enhanced AC-3", "DTS-HD", "MAT", "DST", "WMA Pro" }
local EXT_AUDIO = { [4] = "MPEG-4 HE AAC", [5] = "MPEG-4 HE AAC v2", [6] = "MPEG-4 AAC LC",
  [7] = "DRA", [8] = "MPEG-4 HE AAC + MPEG Surround", [10] = "MPEG-4 AAC LC + MPEG Surround",
  [11] = "MPEG-H 3D Audio", [12] = "AC-4", [13] = "L-PCM 3D Audio" }
local RATES = { 32000, 44100, 48000, 88200, 96000, 176400, 192000 }
local SPEAKERS = { "FL/FR", "LFE1", "FC", "BL/BR", "BC", "FLc/FRc", "RLC/RRC",
  "FLw/FRw", "TpFL/TpFR", "TpC", "TpFC", "LS/RS", "LFE2", "TpBC", "SiL/SiR",
  "TpSiL/TpSiR", "TpBL/TpBR", "BtFC", "BtFL/BtFR", "TpLS/TpRS", "LSd/RSd" }
local COLOR = { "xvYCC601", "xvYCC709", "sYCC601", "opYCC601", "opRGB",
  "BT2020cYCC", "BT2020YCC", "BT2020RGB", "DCI-P3", "ICtCp" }
local EOTF = { "traditional_sdr", "traditional_hdr", "smpte_st2084", "hlg" }

function M.budget() return { total = 0 } end

local function issue(extension, block, reason)
  extension.quality, extension.decoded = "partial", false
  extension.reason = extension.reason or reason
  if block then block.decoded, block.reason = false, block.reason or reason end
end

local function append(extension, budget, list, value, kind)
  if budget.total >= 256 or (budget[kind] or 0) >= LIMITS[kind] then
    extension.truncated = true
    issue(extension, nil, "edid_extensions_truncated")
    return false
  end
  budget.total, budget[kind] = budget.total + 1, (budget[kind] or 0) + 1
  list[#list + 1] = value
  return true
end

local function bits(mask, names)
  local result = {}
  for index, value in ipairs(names) do
    if mask & (1 << (index - 1)) ~= 0 then result[#result + 1] = value end
  end
  return result
end

local function video(extension, budget, block, payload, y420)
  if #payload == 0 then issue(extension, block, "edid_cta_invalid_data_block");return end
  for index = 1, #payload do
    local code = payload:byte(index)
    -- Only codes 1..64 have a native-bit encoding. 193..219 are VICs in
    -- their own right; masking all SVDs with 0x7f corrupts these formats.
    local native = code >= 129 and code <= 192
    local vic = native and code & 127 or code
    local value = { vic = vic, native = native,
      ycbcr420_only = y420, data_block_offset = block.offset, descriptor_index = index }
    local mode = Modes[vic]
    if mode then
      value.horizontal_active_pixels, value.vertical_active_lines = mode[1], mode[2]
      value.nominal_rate_hz, value.interlaced = mode[3], mode[4] == 1
      value.rate_kind = value.interlaced and "field" or "frame"
      value.picture_aspect = tostring(mode[5]) .. ":" .. tostring(mode[6])
      value.pixel_repetition = mode[7]
      value.quality = "fresh"
    else
      value.quality = "partial"
      value.reason = "edid_cta_unknown_video_code"
      issue(extension, block, value.reason)
    end
    if not append(extension, budget, extension.video_formats, value, "video") then break end
  end
end

local function audio(extension, budget, block, payload)
  if #payload == 0 or #payload % 3 ~= 0 then
    issue(extension, block, "edid_cta_invalid_data_block");return
  end
  for index = 1, #payload, 3 do
    local a, b, c = payload:byte(index, index + 2)
    local format = (a >> 3) & 15
    local extended = format == 15 and c >> 3 or nil
    local value = { format_code = format, extended_format_code = extended,
      format = extended and EXT_AUDIO[extended] or AUDIO[format],
      sample_rates_hz = bits(b & 127, RATES), data_block_offset = block.offset,
      descriptor_index = (index + 2) // 3, quality = "fresh" }
    if extended == 11 then value.mpeg_h_level = a & 7
    elseif extended == 13 then value.maximum_channels = ((b & 128) >> 3) + ((a & 128) >> 4) + (a & 7) + 1
    elseif value.format then value.maximum_channels = (a & 7) + 1 end
    if format == 1 or extended == 13 then value.sample_sizes_bits = bits(c & 7, { 16, 20, 24 })
    elseif format >= 2 and format <= 8 then value.maximum_bitrate_kbps = c * 8
    else value.format_specific_value = extended and c & 7 or c end
    if not value.format or #value.sample_rates_hz == 0 or (a & 128 ~= 0 and extended ~= 13)
        or (b & 128 ~= 0 and extended ~= 13) or (format == 1 and (c & 248 ~= 0 or c & 7 == 0))
        or (extended == 11 and value.mpeg_h_level > 5) then
      value.quality = "partial"
      value.reason = "edid_cta_invalid_data_block"
      issue(extension, block, value.reason)
    end
    if not append(extension, budget, extension.audio_formats, value, "audio") then break end
  end
end

local function vendor(extension, budget, block, payload, forum_capability)
  if #payload < 3 then issue(extension, block, "edid_cta_invalid_data_block");return end
  local oui = payload:byte(1) + (payload:byte(2) << 8) + (payload:byte(3) << 16)
  local value = { oui = oui, data_block_offset = block.offset, quality = "fresh", details_decoded = true }
  local function incomplete(reason)
    value.quality, value.details_decoded = "partial", false
    value.reason = reason
    issue(extension, block, reason)
  end
  if oui == 0x000c03 and not forum_capability then
    value.vendor = "HDMI"
    if #payload < 5 then incomplete("edid_cta_invalid_data_block")
    else
      -- The CEC physical address is deliberately not retained.
      if #payload >= 6 then
        local flags = payload:byte(6)
        value.deep_color_bits = bits((flags >> 4) & 7, { 10, 12, 16 })
        value.deep_color_ycbcr444 = flags & 8 ~= 0
        value.supports_ai, value.dual_link_dvi = flags & 128 ~= 0, flags & 1 ~= 0
        if flags & 6 ~= 0 then incomplete("edid_cta_unsupported_data_block") end
      end
      if #payload >= 7 and payload:byte(7) ~= 0 then value.maximum_tmds_clock_hz = payload:byte(7) * 5000000 end
      if #payload >= 8 then
        local flags = payload:byte(8)
        value.content_types_mask = flags & 15
        local required = 8 + (flags & 128 ~= 0 and 2 or 0) + (flags & 64 ~= 0 and 2 or 0)
        if flags & 64 ~= 0 and flags & 128 == 0 or #payload < required then
          incomplete("edid_cta_invalid_data_block")
        elseif flags & 224 ~= 0 or #payload > 8 then incomplete("edid_cta_unsupported_data_block") end
      end
    end
  elseif oui == 0xc45dd8 or forum_capability then
    value.vendor = "HDMI Forum"
    value.version = payload:byte(4)
    if #payload < 7 then incomplete("edid_cta_invalid_data_block")
    elseif payload:byte(4) ~= 1 then incomplete("edid_cta_unsupported_data_block")
    else
      value.version = 1
      if payload:byte(5) ~= 0 then value.maximum_tmds_character_rate_hz = payload:byte(5) * 5000000 end
      value.scdc = payload:byte(6) & 128 ~= 0
      value.deep_color_420_bits = bits(payload:byte(7) & 7, { 10, 12, 16 })
      value.maximum_frl_code = payload:byte(7) >> 4
      if value.maximum_frl_code > 6 then incomplete("edid_cta_unsupported_data_block") end
      if #payload >= 8 then
        value.allm = payload:byte(8) & 2 ~= 0
        value.qms = payload:byte(8) & 64 ~= 0
      end
      if #payload == 9 then incomplete("edid_cta_invalid_data_block") end
      if #payload >= 10 then
        local minimum, maximum = payload:byte(9) & 63, ((payload:byte(9) >> 6) << 8) + payload:byte(10)
        if minimum > 0 and minimum <= 48 and maximum >= 100 and maximum >= minimum then
          value.vrr_minimum_hz, value.vrr_maximum_hz = minimum, maximum
        elseif minimum ~= 0 or maximum ~= 0 then incomplete("edid_cta_invalid_data_block") end
      end
      -- DSC and later revisions have their own semantics. Do not claim that
      -- parsing the preceding public fields decoded an unknown tail.
      if #payload > 10 then incomplete("edid_cta_unsupported_data_block") end
    end
  else incomplete("edid_cta_unsupported_data_block") end
  append(extension, budget, extension.vendors, value, "vendors")
end

local function extended(extension, budget, block, payload)
  if #payload == 0 then issue(extension, block, "edid_cta_invalid_data_block");return end
  local tag, data = payload:byte(1), payload:sub(2)
  block.extended_tag = tag
  if tag == 14 then video(extension, budget, block, data, true)
  elseif tag == 15 then
    local indices = {}
    for index = 1, #data do
      local mask = data:byte(index)
      for bit = 0, 7 do if mask & (1 << bit) ~= 0 then indices[#indices + 1] = (index - 1) * 8 + bit + 1 end end
    end
    append(extension, budget, extension.ycbcr420_maps,
      { all_video_formats = #data == 0, video_format_indices = indices, data_block_offset = block.offset }, "maps")
  elseif tag == 5 then
    if #data < 2 then issue(extension, block, "edid_cta_invalid_data_block");return end
    local mask = data:byte(1) | ((data:byte(2) & 128) << 1) | ((data:byte(2) & 64) << 3)
    append(extension, budget, extension.colorimetry,
      { names = bits(mask, COLOR), mask = mask, data_block_offset = block.offset }, "colorimetry")
    if #data ~= 2 or data:byte(2) & 48 ~= 0 then issue(extension, block, "edid_cta_unsupported_data_block") end
  elseif tag == 6 then
    if #data < 2 or #data > 5 then issue(extension, block, "edid_cta_invalid_data_block");return end
    local eotf, metadata = data:byte(1, 2)
    local value = { eotfs = bits(eotf, EOTF), eotf_mask = eotf, metadata_mask = metadata,
      static_metadata_type1 = metadata & 1 ~= 0, data_block_offset = block.offset }
    local maximum, average, minimum = data:byte(3, 5)
    if maximum and maximum > 0 then value.desired_maximum_luminance_cdm2 = 50 * 2 ^ (maximum / 32) end
    if average and average > 0 then value.desired_average_luminance_cdm2 = 50 * 2 ^ (average / 32) end
    if minimum and minimum > 0 then
      if value.desired_maximum_luminance_cdm2 then
        value.desired_minimum_luminance_cdm2 = value.desired_maximum_luminance_cdm2 * (minimum / 255) ^ 2 / 100
      else issue(extension, block, "edid_cta_invalid_data_block") end
    end
    append(extension, budget, extension.hdr_static_metadata, value, "hdr")
    if eotf & 240 ~= 0 or metadata & 254 ~= 0 then issue(extension, block, "edid_cta_unsupported_data_block") end
  elseif tag == 121 then
    -- HF-SCDB has two reserved bytes in place of the three-byte IEEE OUI;
    -- replacing those bytes gives the same SCDS offsets as an HF-VSDB.
    if #data < 6 or data:byte(1) ~= 0 or data:byte(2) ~= 0 then
      issue(extension, block, "edid_cta_invalid_data_block");return
    end
    vendor(extension, budget, block, "\216\93\196" .. data:sub(3), true)
  else issue(extension, block, "edid_cta_unsupported_data_block") end
end

function M.parse(bytes, start, extension, budget, timing)
  local function b(offset) return bytes:byte(start + offset) end
  local revision, offset = b(1), b(2)
  extension.revision, extension.decoded = revision, true
  extension.data_blocks, extension.video_formats, extension.audio_formats = {}, {}, {}
  extension.vendors, extension.speaker_allocations, extension.colorimetry = {}, {}, {}
  extension.hdr_static_metadata, extension.ycbcr420_maps, extension.detailed_timings = {}, {}, {}
  if revision < 1 or revision > 3 then issue(extension, nil, "edid_cta_unsupported_revision");return end
  if offset ~= 0 and (offset < 4 or offset > 127) then issue(extension, nil, "edid_cta_invalid_offset");return end
  if revision >= 2 then
    local flags = b(3)
    extension.underscan, extension.basic_audio = flags & 128 ~= 0, flags & 64 ~= 0
    extension.ycbcr444, extension.ycbcr422 = flags & 32 ~= 0, flags & 16 ~= 0
    extension.native_dtd_count = flags & 15
  elseif b(3) ~= 0 then issue(extension, nil, "edid_cta_invalid_data_block") end
  if offset == 0 then
    if bytes:sub(start + 4, start + 126):find("[^%z]") then issue(extension, nil, "edid_cta_invalid_offset") end
    return
  end
  if revision < 3 and offset > 4 then
    issue(extension, nil, "edid_cta_unsupported_data_block")
  elseif revision == 3 then
    local position, seen = 4, {}
    while position < offset do
      local header = b(position)
      if header == 0 then
        if bytes:sub(start + position, start + offset - 1):find("[^%z]") then
          issue(extension, nil, "edid_cta_invalid_data_block")
        end
        break
      end
      local length, tag = header & 31, header >> 5
      local block = { offset = position, tag = tag, length = length, decoded = true }
      if not append(extension, budget, extension.data_blocks, block, "blocks") then break end
      if position + length + 1 > offset then issue(extension, block, "edid_cta_invalid_data_block");break end
      local payload = bytes:sub(start + position + 1, start + position + length)
      local unique
      if tag == 4 then unique = "speakers"
      elseif tag == 7 and #payload > 0 then unique = "extended:" .. tostring(payload:byte(1))
      elseif tag == 3 and #payload >= 3 then
        unique = "vendor:" .. tostring(payload:byte(1) + (payload:byte(2) << 8) + (payload:byte(3) << 16))
      end
      if unique then
        if seen[unique] then issue(extension, block, "edid_cta_invalid_data_block") end
        seen[unique] = true
      end
      if tag == 1 then audio(extension, budget, block, payload)
      elseif tag == 2 then video(extension, budget, block, payload, false)
      elseif tag == 3 then vendor(extension, budget, block, payload, false)
      elseif tag == 4 then
        if length ~= 3 then issue(extension, block, "edid_cta_invalid_data_block")
        else
          local mask = payload:byte(1) | (payload:byte(2) << 8) | (payload:byte(3) << 16)
          append(extension, budget, extension.speaker_allocations,
            { mask = mask, speakers = bits(mask, SPEAKERS), data_block_offset = position }, "speakers")
          if mask & 0xe00000 ~= 0 then issue(extension, block, "edid_cta_unsupported_data_block") end
        end
      elseif tag == 7 then extended(extension, budget, block, payload)
      else issue(extension, block, "edid_cta_unsupported_data_block") end
      position = position + length + 1
      if extension.truncated then break end
    end
  end
  local position = offset
  while position + 18 <= 127 do
    if bytes:sub(start + position, start + position + 17) == string.rep("\0", 18) then break end
    if b(position) == 0 and b(position + 1) == 0 then
      issue(extension, nil, "edid_cta_invalid_data_block")
    else
      local value = timing(bytes, start + position)
      if value then
        value.offset = position
        if not append(extension, budget, extension.detailed_timings, value, "timings") then break end
      else issue(extension, nil, "edid_invalid_timing") end
    end
    position = position + 18
  end
  if not extension.truncated and bytes:sub(start + position, start + 126):find("[^%z]") then
    issue(extension, nil, "edid_cta_invalid_data_block")
  end
  -- Capability-map indices are scoped to the regular VDB entries in this
  -- extension, never to another extension's modes or to Y420-only entries.
  local regular, regular_vics, y420_vics = {}, {}, {}
  for _, value in ipairs(extension.video_formats) do
    local set = value.ycbcr420_only and y420_vics or regular_vics
    if set[value.vic] then issue(extension, nil, "edid_cta_invalid_data_block") end
    set[value.vic] = true
    if not value.ycbcr420_only then regular[#regular + 1] = value end
  end
  for vic in pairs(y420_vics) do
    if regular_vics[vic] then issue(extension, nil, "edid_cta_invalid_data_block") end
  end
  if (#extension.audio_formats > 0 or #extension.speaker_allocations > 0) and not extension.basic_audio then
    issue(extension, nil, "edid_cta_invalid_data_block")
  end
  for _, map in ipairs(extension.ycbcr420_maps) do
    if map.all_video_formats then
      for _, value in ipairs(regular) do value.ycbcr420_capable = true end
    else
      for _, index in ipairs(map.video_format_indices) do
        if regular[index] then regular[index].ycbcr420_capable = true
        else issue(extension, nil, "edid_cta_invalid_data_block") end
      end
    end
  end
end

return M
