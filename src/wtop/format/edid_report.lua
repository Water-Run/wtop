local M = {}
function M.append(lines, displays, table_section, quantity)
  local extensions, video, audio, speakers, colors, hdr, vendors, timings = {}, {}, {}, {}, {}, {}, {}, {}
  for _, device in ipairs(displays.devices or {}) do
    for _, extension in ipairs(device.edid and device.edid.extensions or {}) do
      extensions[#extensions + 1] = { device = device.id, value = extension }
      for name, target in pairs({ video_formats = video, audio_formats = audio, speaker_allocations = speakers,
          colorimetry = colors, hdr_static_metadata = hdr, vendors = vendors, detailed_timings = timings }) do
        for _, value in ipairs(extension[name] or {}) do
          target[#target + 1] = { device = device.id, extension = extension.index, value = value }
        end
      end
    end
  end
  table_section(lines, "EDID extension blocks", { "Connector", "Block", "Tag", "Revision", "Checksum valid", "Decoded", "Basic audio", "YCbCr 4:4:4", "YCbCr 4:2:2", "Native detailed timings", "Quality", "Reason" },
    extensions, function(item)
      local e = item.value
      return { item.device, e.index, e.tag == 2 and "CTA-861" or e.tag, e.revision, e.checksum_ok, e.decoded,
        e.basic_audio, e.ycbcr444, e.ycbcr422, e.native_dtd_count, e.quality, e.reason }
    end, displays)
  table_section(lines, "CTA video declarations", { "Connector", "Block", "VIC", "Pixels", "Lines", "Nominal rate", "Rate kind", "Aspect", "Interlaced", "Pixel repetition", "Native", "Y420 only", "Y420 capable", "Quality" },
    video, function(item)
      local v = item.value
      return { item.device, item.extension, v.vic, v.horizontal_active_pixels, v.vertical_active_lines,
        quantity(v.nominal_rate_hz, 1, " Hz", 0), v.rate_kind, v.picture_aspect, v.interlaced, v.pixel_repetition, v.native,
        v.ycbcr420_only, v.ycbcr420_capable, v.quality }
    end, displays)
  table_section(lines, "CTA audio declarations", { "Connector", "Block", "Format", "Maximum channels", "Sample rates (Hz)", "Sample sizes (bits)", "Maximum bitrate (kb/s)", "Quality" },
    audio, function(item)
      local v = item.value
      return { item.device, item.extension, v.format or v.format_code, v.maximum_channels,
        table.concat(v.sample_rates_hz or {}, ", "), table.concat(v.sample_sizes_bits or {}, ", "), v.maximum_bitrate_kbps, v.quality }
    end, displays)
  table_section(lines, "CTA speaker declarations", { "Connector", "Block", "Allocation" },
    speakers, function(item) return { item.device, item.extension, table.concat(item.value.speakers or {}, ", ") } end, displays)
  table_section(lines, "CTA colorimetry declarations", { "Connector", "Block", "Colorimetry" },
    colors, function(item) return { item.device, item.extension, table.concat(item.value.names or {}, ", ") } end, displays)
  table_section(lines, "CTA static HDR declarations", { "Connector", "Block", "EOTFs", "Metadata type 1", "Desired maximum (cd/m²)", "Desired frame average (cd/m²)", "Desired minimum (cd/m²)" },
    hdr, function(item)
      local v = item.value
      return { item.device, item.extension, table.concat(v.eotfs or {}, ", "), v.static_metadata_type1,
        quantity(v.desired_maximum_luminance_cdm2, 1, "", 3), quantity(v.desired_average_luminance_cdm2, 1, "", 3),
        quantity(v.desired_minimum_luminance_cdm2, 1, "", 6) }
    end, displays)
  table_section(lines, "CTA HDMI declarations", { "Connector", "Block", "Vendor", "OUI", "Deep color (bits)", "4:2:0 deep color (bits)", "Maximum TMDS clock", "Maximum TMDS character rate", "VRR minimum", "VRR maximum", "ALLM", "Quality" },
    vendors, function(item)
      local v = item.value
      return { item.device, item.extension, v.vendor, string.format("%06X", v.oui),
        table.concat(v.deep_color_bits or {}, ", "), table.concat(v.deep_color_420_bits or {}, ", "),
        quantity(v.maximum_tmds_clock_hz, 1e6, " MHz", 0), quantity(v.maximum_tmds_character_rate_hz, 1e6, " MHz", 0),
        quantity(v.vrr_minimum_hz, 1, " Hz", 0), quantity(v.vrr_maximum_hz, 1, " Hz", 0), v.allm, v.quality }
    end, displays)
  table_section(lines, "CTA extension detailed timings", { "Connector", "Block", "Horizontal pixels", "Encoded vertical lines", "Pixel clock", "Progressive refresh", "Interlaced" },
    timings, function(item)
      local v = item.value
      return { item.device, item.extension, v.horizontal_active_pixels, v.vertical_active_lines,
        quantity(v.pixel_clock_hz, 1e6, " MHz", 3), quantity(v.refresh_hz, 1, " Hz", 3), v.interlaced }
    end, displays)
end
return M
