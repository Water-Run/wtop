-- The only EDID fields exported by Snapshot/Agent. No raw descriptors,
-- CEC addresses, vendor payloads or serial values leave this whitelist.
local M = {}
local TIMING = { "horizontal_active_pixels", "vertical_active_lines", "horizontal_blanking_pixels",
  "vertical_blanking_lines", "pixel_clock_hz", "interlaced", "preferred", "refresh_hz", "width_mm", "height_mm", "offset" }
local LISTS = {
  data_blocks = { 128, { "offset", "tag", "length", "extended_tag", "decoded", "reason" } },
  video_formats = { 128, { "vic", "native", "ycbcr420_only", "ycbcr420_capable", "data_block_offset", "descriptor_index",
    "horizontal_active_pixels", "vertical_active_lines", "nominal_rate_hz", "interlaced", "rate_kind",
    "picture_aspect", "pixel_repetition", "quality", "reason" } },
  audio_formats = { 32, { "format_code", "extended_format_code", "format", "data_block_offset", "descriptor_index",
    "mpeg_h_level", "maximum_channels", "maximum_bitrate_kbps", "format_specific_value", "quality", "reason" },
    { sample_rates_hz = 7, sample_sizes_bits = 3 } },
  vendors = { 16, { "oui", "vendor", "data_block_offset", "quality", "details_decoded", "reason",
    "deep_color_ycbcr444", "supports_ai", "dual_link_dvi", "maximum_tmds_clock_hz", "content_types_mask", "version",
    "maximum_tmds_character_rate_hz", "scdc", "maximum_frl_code", "allm", "qms", "vrr_minimum_hz", "vrr_maximum_hz" },
    { deep_color_bits = 3, deep_color_420_bits = 3 } },
  speaker_allocations = { 16, { "mask", "data_block_offset" }, { speakers = 21 } },
  colorimetry = { 16, { "mask", "data_block_offset" }, { names = 10 } },
  hdr_static_metadata = { 16, { "eotf_mask", "metadata_mask", "static_metadata_type1", "data_block_offset",
    "desired_maximum_luminance_cdm2", "desired_average_luminance_cdm2", "desired_minimum_luminance_cdm2" }, { eotfs = 4 } },
  ycbcr420_maps = { 16, { "all_video_formats", "data_block_offset" }, { video_format_indices = 240 } },
  detailed_timings = { 32, TIMING },
}
local ORDER = { "data_blocks", "video_formats", "audio_formats", "vendors", "speaker_allocations",
  "colorimetry", "hdr_static_metadata", "ycbcr420_maps", "detailed_timings" }

function M.copy(edid, json, fields, current)
  local output = fields(edid, { "version", "quality", "reason", "manufacturer", "name", "product_code", "serial_present",
    "manufacture_week", "manufacture_year", "model_year", "digital", "interface", "bits_per_color", "width_mm", "height_mm",
    "extension_count", "blocks_available", "extensions_decoded", "extensions_truncated" })
  if not current then output.quality = "stale" end
  output.detailed_timings, output.extensions = json.array({}), json.array({})
  for index, value in ipairs(edid.detailed_timings or {}) do
    if index > 4 then break end
    output.detailed_timings[index] = fields(value, TIMING)
  end
  local counts, total = {}, 0
  for index, extension in ipairs(edid.extensions or {}) do
    if index > 32 then output.extensions_truncated = true;break end
    local row = fields(extension, { "index", "tag", "revision", "checksum_ok", "quality", "reason", "decoded", "truncated",
      "underscan", "basic_audio", "ycbcr444", "ycbcr422", "native_dtd_count" })
    if not current then row.quality = "stale" end
    for _, name in ipairs(ORDER) do
      if type(extension[name]) == "table" then
        local spec = LISTS[name]
        row[name] = json.array({})
        for _, value in ipairs(extension[name]) do
          if total >= 256 or (counts[name] or 0) >= spec[1] then
            row.truncated, row.decoded, output.extensions_truncated = true, false, true
            row.quality = current and "partial" or "stale"
            row.reason = row.reason or "edid_extensions_truncated"
            break
          end
          local item = fields(value, spec[2])
          if not current and value.quality then item.quality = "stale" end
          for key, limit in pairs(spec[3] or {}) do
            if type(value[key]) == "table" then
              item[key] = json.array({})
              for position = 1, math.min(#value[key], limit) do
                local scalar = value[key][position]
                if type(scalar) == "string" or type(scalar) == "number" then
                  item[key][#item[key] + 1] = scalar
                end
              end
            end
          end
          row[name][#row[name] + 1] = item
          counts[name], total = (counts[name] or 0) + 1, total + 1
        end
      end
    end
    output.extensions[index] = row
  end
  if output.extensions_truncated then
    output.extensions_decoded = false
    output.quality = current and "partial" or "stale"
    output.reason = output.reason or "edid_extensions_truncated"
  end
  return output
end

return M
