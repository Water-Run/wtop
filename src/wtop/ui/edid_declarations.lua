local Technical = require("wtop.i18n.technical")
local M = {}
local EOTF = { traditional_sdr = "SDR", traditional_hdr = "HDR", smpte_st2084 = "PQ (SMPTE ST2084)", hlg = "HLG" }

function M.append(edid, add, add_list, i18n, current)
  for _, extension in ipairs(edid.extensions or {}) do
    local kind = extension.tag == 2 and "CTA-861" or string.format("0x%02X", extension.tag)
    add("display.cta_extension", "EDID extension", tostring(extension.index) .. " · " .. kind)
    add("display.cta_revision", "Extension revision", extension.revision)
    add("display.cta_decoded", "Extension decoded", extension.decoded)
    add("inspector.quality", "Quality", Technical.state(i18n, current and extension.quality or "stale"))
    if extension.reason then add("inspector.reason", "Reason", Technical.reason(i18n, extension.reason)) end
    add("display.cta_basic_audio", "Basic audio declared", extension.basic_audio)
    add("display.cta_y444", "YCbCr 4:4:4 declared", extension.ycbcr444)
    add("display.cta_y422", "YCbCr 4:2:2 declared", extension.ycbcr422)
    add("display.cta_native_dtds", "Declared native detailed timings", extension.native_dtd_count)
    for _, value in ipairs(extension.video_formats or {}) do
      local text = "VIC " .. tostring(value.vic)
      if value.horizontal_active_pixels then
        text = text .. " · " .. tostring(value.horizontal_active_pixels) .. " x " .. tostring(value.vertical_active_lines)
      end
      if value.picture_aspect then text = text .. " · " .. value.picture_aspect end
      add("display.cta_video", "CTA video format", text)
      if value.interlaced then add("display.cta_field_rate", "Declared nominal field rate", value.nominal_rate_hz, "hertz")
      else add("display.cta_frame_rate", "Declared nominal frame rate", value.nominal_rate_hz, "hertz") end
      add("display.interlaced", "Interlaced declaration", value.interlaced)
      add("display.cta_native", "Native format declared", value.native)
      if value.pixel_repetition and value.pixel_repetition > 1 then
        add("display.cta_repetition", "Declared pixel repetition", value.pixel_repetition)
      end
      if value.ycbcr420_only then add("display.cta_video", "CTA video format", "YCbCr 4:2:0") end
      if value.ycbcr420_capable then add("display.cta_y420", "YCbCr 4:2:0 also declared", true) end
      if value.reason then add("inspector.reason", "Reason", Technical.reason(i18n, value.reason)) end
    end
    for _, value in ipairs(extension.audio_formats or {}) do
      add("display.cta_audio", "Declared audio format", value.format or tostring(value.format_code))
      add("display.cta_channels", "Maximum audio channels", value.maximum_channels)
      add_list("display.cta_sample_rates", "Audio sample rates (Hz)", value.sample_rates_hz or {})
      add_list("display.cta_sample_sizes", "Audio sample sizes (bits)", value.sample_sizes_bits or {})
      if value.maximum_bitrate_kbps then
        add("display.cta_bitrate", "Maximum audio bitrate (kb/s)", value.maximum_bitrate_kbps)
      end
      if value.reason then add("inspector.reason", "Reason", Technical.reason(i18n, value.reason)) end
    end
    for _, value in ipairs(extension.speaker_allocations or {}) do
      add_list("display.cta_speakers", "Declared speaker allocation", value.speakers or {})
    end
    for _, value in ipairs(extension.colorimetry or {}) do
      add_list("display.cta_colorimetry", "Declared colorimetry", value.names or {})
    end
    for _, value in ipairs(extension.hdr_static_metadata or {}) do
      local eotfs = {}
      for _, name in ipairs(value.eotfs or {}) do eotfs[#eotfs + 1] = EOTF[name] or name end
      add_list("display.cta_hdr", "Declared EOTFs", eotfs)
      add("display.cta_hdr_type1", "Static HDR metadata type 1 declared", value.static_metadata_type1)
      add("display.cta_luminance_max", "Desired content maximum (cd/m²)", value.desired_maximum_luminance_cdm2)
      add("display.cta_luminance_avg", "Desired content frame average (cd/m²)", value.desired_average_luminance_cdm2)
      add("display.cta_luminance_min", "Desired content minimum (cd/m²)", value.desired_minimum_luminance_cdm2)
    end
    for _, value in ipairs(extension.vendors or {}) do
      add("display.cta_vendor", "CTA vendor declaration", (value.vendor or "IEEE OUI") .. " · " .. string.format("%06X", value.oui))
      add_list("display.cta_deep_color", "Declared HDMI bits per color", value.deep_color_bits or {})
      add_list("display.cta_deep_color_420", "Declared HDMI 4:2:0 bits per color", value.deep_color_420_bits or {})
      add("display.cta_tmds", "Declared maximum TMDS clock", value.maximum_tmds_clock_hz, "hertz")
      add("display.cta_tmds_chars", "Declared maximum TMDS character rate", value.maximum_tmds_character_rate_hz, "hertz")
      if value.vrr_minimum_hz and value.vrr_maximum_hz then
        add("display.cta_vrr", "Declared VRR range", tostring(value.vrr_minimum_hz) .. " - " .. tostring(value.vrr_maximum_hz) .. " Hz")
      end
    end
    for _, value in ipairs(extension.detailed_timings or {}) do
      add("display.cta_timing", "CTA timing (pixels x encoded lines)",
        tostring(value.horizontal_active_pixels) .. " x " .. tostring(value.vertical_active_lines))
      add("display.pixel_clock", "Declared pixel clock", value.pixel_clock_hz, "hertz")
      add("display.refresh", "Declared progressive refresh", value.refresh_hz, "hertz")
      add("display.interlaced", "Interlaced declaration", value.interlaced)
    end
  end
end

return M
