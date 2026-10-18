package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local EDID = require("wtop.format.edid")
local Input = require("support.display_fixtures")
local JSON = require("wtop.format.json")
local Wire = require("wtop.core.worker_wire")
local Snapshot = require("wtop.model.snapshot")
local Export = require("wtop.export")
local Report = require("wtop.report")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Fixture = require("support.fixture_fs")
local Displays = require("wtop.collectors.drm_displays")
local block = Input.cta_block
local function parse(options, count)
  local bytes = type(options) == "string" and options or Input.cta(options)
  return assert(EDID.parse(Input.edid({ extensions = count or 1, tail = bytes })))
end
local function first(options) local result = parse(options);return result.extensions[1], result end
local video, audio = block(2, string.char(0x81, 2, 76, 4, 193, 219)), block(1, string.char(9, 7, 7, 0x15, 0x54, 80))
local data = video .. audio .. block(4, "\7\0\0") .. block(3, "\3\12\0\16\0\56\30")
local ext, result = first({ data = data, flags = 0xf1, timings = Input.edid():sub(55, 72) })
assert(result.quality == "fresh" and result.extensions_decoded and not result.extensions_truncated)
assert(ext.index == 1 and ext.tag == 2 and ext.revision == 3 and ext.checksum_ok and ext.decoded)
assert(ext.basic_audio and ext.underscan and ext.ycbcr444 and ext.ycbcr422 and ext.native_dtd_count == 1)
assert(#ext.video_formats == 6 and ext.video_formats[1].native and not ext.video_formats[2].native)
assert(ext.video_formats[3].vic == 76 and ext.video_formats[3].picture_aspect == "64:27")
assert(ext.video_formats[3].horizontal_active_pixels == 1920 and ext.video_formats[3].nominal_rate_hz == 60)
assert(ext.video_formats[5].vic == 193 and ext.video_formats[5].horizontal_active_pixels == 5120)
assert(ext.video_formats[6].vic == 219 and ext.video_formats[6].horizontal_active_pixels == 4096)
assert(ext.audio_formats[1].format == "Linear PCM" and ext.audio_formats[1].maximum_channels == 2)
assert(table.concat(ext.audio_formats[1].sample_rates_hz, ",") == "32000,44100,48000")
assert(table.concat(ext.audio_formats[1].sample_sizes_bits, ",") == "16,20,24")
assert(ext.audio_formats[2].format == "AC-3" and ext.audio_formats[2].maximum_channels == 6)
assert(ext.audio_formats[2].maximum_bitrate_kbps == 640)
assert(table.concat(ext.speaker_allocations[1].speakers, ",") == "FL/FR,LFE1,FC")
assert(ext.vendors[1].oui == 0xc03 and ext.vendors[1].vendor == "HDMI")
assert(ext.vendors[1].maximum_tmds_clock_hz == 150000000)
assert(table.concat(ext.vendors[1].deep_color_bits, ",") == "10,12" and ext.vendors[1].deep_color_ycbcr444)
assert(ext.vendors[1].physical_address == nil and ext.vendors[1].raw == nil)
assert(#ext.detailed_timings == 1 and ext.detailed_timings[1].refresh_hz == 60)
assert(ext.detailed_timings[1].preferred == nil and ext.detailed_timings[1].offset == 4 + #data)
assert(#result.detailed_timings == 1, "CTA timings were mixed into base descriptors")
-- Extended VICs are not native-bit forms; 129..192 are native VIC1..64.
for _, codes in ipairs({ { 64, 192, 65, 127, 193, 219 }, { 0, 128, 220, 255 } }) do
  local value = first({ data = block(2, string.char(table.unpack(codes))) })
  for index, code in ipairs(codes) do
    local entry = value.video_formats[index]
    assert(entry.vic == (code >= 129 and code <= 192 and code & 127 or code))
  end
end
assert(first({ data = block(2, "\5\6") }).video_formats[1].rate_kind == "field")
assert(first({ data = block(2, "\6") }).video_formats[1].pixel_repetition == 2)
-- All supported table families have consistent public facts, including both
-- boundary codes; reserved codes stay numeric with an explicit reason.
for code = 1, 255 do
  local value = first({ data = block(2, string.char(code)) }).video_formats[1]
  local known = code <= 127 or code >= 129 and code <= 219
  assert((value.quality == "fresh") == known, tostring(code))
  if known then assert(value.nominal_rate_hz > 0 and value.picture_aspect and value.vertical_active_lines > 0)
  else assert(value.reason == "edid_cta_unknown_video_code" and value.nominal_rate_hz == nil) end
end
-- Y420 capability bits follow regular VDB order within the same extension;
-- a Y420-only list is separate and never masquerades as the active encoding.
local y420 = block(7, "\15\2") .. block(2, "\16\97") .. block(7, "\14\96")
ext = first({ data = y420 })
assert(ext.video_formats[2].ycbcr420_capable and not ext.video_formats[1].ycbcr420_capable)
assert(ext.video_formats[3].ycbcr420_only and ext.video_formats[3].vic == 96)
assert(not ext.video_formats[3].native and ext.video_formats[3].ycbcr420_capable == nil)
ext = first({ data = block(7, "\15") .. video })
for _, v in ipairs(ext.video_formats) do assert(v.ycbcr420_capable) end
local scoped = parse(Input.cta({ data = block(2, "\16") }) .. Input.cta({ data = block(7, "\15\2") }), 2)
assert(scoped.extensions[1].video_formats[1].ycbcr420_capable == nil and scoped.quality == "partial")
-- HDR content luminance is declared metadata, not measured panel brightness.
-- Zero codes are unspecified, and min luminance needs a known maximum.
ext = first({ data = block(7, "\6\15\1\96\64\128") .. block(7, "\5\224\192") })
local hdr = ext.hdr_static_metadata[1]
assert(table.concat(hdr.eotfs, ",") == "traditional_sdr,traditional_hdr,smpte_st2084,hlg")
assert(hdr.static_metadata_type1 and hdr.desired_maximum_luminance_cdm2 == 400)
assert(hdr.desired_average_luminance_cdm2 == 200)
assert(math.abs(hdr.desired_minimum_luminance_cdm2 - 400 * (128 / 255) ^ 2 / 100) < 1e-12)
assert(table.concat(ext.colorimetry[1].names, ",") == "BT2020cYCC,BT2020YCC,BT2020RGB,DCI-P3,ICtCp")
ext = first({ data = block(7, "\6\4\1\0\0\0") })
hdr = ext.hdr_static_metadata[1]
assert(hdr.desired_maximum_luminance_cdm2 == nil and hdr.desired_minimum_luminance_cdm2 == nil)
assert(first({ data = block(7, "\6\4\1\0\0\1") }).quality == "partial")
-- HDMI Forum uses a versioned layout, with optional VRR bounds. HF-SCDB's
-- reserved prefix must not shift the version/TMDS/VRR offsets.
local hf = "\216\93\196\1\120\128\3\2\40\120"
ext = first({ data = block(3, hf) .. block(7, "\121\0\0" .. hf:sub(4)) })
for _, v in ipairs(ext.vendors) do
  assert(v.vendor == "HDMI Forum" and v.version == 1 and v.maximum_tmds_character_rate_hz == 600000000)
  assert(v.vrr_minimum_hz == 40 and v.vrr_maximum_hz == 120 and v.allm and v.scdc)
  assert(table.concat(v.deep_color_420_bits, ",") == "10,12")
end
assert(#ext.vendors == 2)
ext = first({ data = block(3, hf:sub(1, 7)) })
assert(ext.vendors[1].vrr_minimum_hz == nil and ext.vendors[1].allm == nil)
assert(first({ data = block(3, hf:sub(1, 8) .. "\0\120") }).vendors[1].vrr_minimum_hz == nil)
assert(first({ data = block(2, "\16\16") }).quality == "partial")
assert(first({ data = block(2, "\16") .. block(7, "\14\16") }).quality == "partial")
assert(first({ data = block(7, "\6\4\1") .. block(7, "\6\8\1") }).quality == "partial")
assert(first({ data = audio }).quality == "partial", "audio claims without the basic-audio flag were accepted as complete")
-- Extended audio 3D-LPCM carries extra channel bits; MPEG-H's low bits are
-- a level, not a channel count. Common audio fields retain their units.
ext = first({ data = block(1, string.char(0xff, 0x87, (13 << 3) | 7, 0x7c, 0x14, (11 << 3))) })
assert(ext.audio_formats[1].maximum_channels == 32 and ext.audio_formats[1].format == "L-PCM 3D Audio")
assert(ext.audio_formats[2].mpeg_h_level == 4 and ext.audio_formats[2].maximum_channels == nil)
-- Invalid checksums are never allowed to donate any extension capability.
ext, result = first({ data = data, corrupt_checksum = true })
assert(ext.reason == "edid_invalid_extension_checksum" and not ext.decoded)
assert(ext.video_formats == nil and not result.extensions_decoded and result.name == "FixturePanel")
for _, offset in ipairs({ 1, 2, 3, 128, 255 }) do
  ext = first({ offset = offset })
  assert(ext.reason == "edid_cta_invalid_offset" and #ext.data_blocks == 0)
end
assert(first({ offset = 0 }).quality == "fresh")
assert(first({ offset = 0, data = video }).reason == "edid_cta_invalid_offset")
assert(first({ offset = 127 }).quality == "fresh")
for _, revision in ipairs({ 0, 4, 255 }) do
  assert(first({ revision = revision, data = video }).reason == "edid_cta_unsupported_revision")
end
for revision = 1, 2 do
  assert(first({ revision = revision, timings = Input.edid():sub(55, 72) }).decoded)
  assert(not first({ revision = revision, data = video }).decoded)
end
for _, bytes in ipairs({ block(1, "\9"), block(2, ""), block(3, "\3\12"), block(4, "\0\0"),
    block(7, ""), block(7, "\6\4"), block(7, "\5\1"), block(3, "\3\12\0\16"),
    block(3, hf:sub(1, 9)), block(3, "\3\12\0\16\0\0\0\64") }) do
  ext = first({ data = bytes })
  assert(ext.quality == "partial" and not ext.decoded, JSON.encode(ext))
end
ext = first({ data = string.char(0x5f) .. "\16", offset = 6 })
assert(ext.reason == "edid_cta_invalid_data_block" and #ext.video_formats == 0)
assert(first({ data = block(5, "PRIVATE-VENDOR-DATA") }).reason == "edid_cta_unsupported_data_block")
assert(first({ data = block(3, "\1\2\3PRIVATE-VENDOR") }).vendors[1].details_decoded == false)
assert(first({ timings = Input.edid():sub(91, 108) }).reason == "edid_cta_invalid_data_block")
assert(not JSON.encode(first({ timings = Input.edid():sub(91, 108) })):find("PRIVATE", 1, true))
-- Damage/truncation/mutation cannot crash a stateless hardware reader.
for length = 0, 127 do
  local incomplete = Input.cta({ data = data }):sub(1, length)
  local value = parse(incomplete)
  assert(value.reason == "edid_incomplete" and not value.extensions_decoded)
end
for offset = 0, 126 do
  for _, byte in ipairs({ 0, 1, 31, 127, 255 }) do
    assert(pcall(parse, { data = data, bytes = { [offset] = byte } }), tostring(offset))
  end
end
-- Global caps apply across extensions rather than resetting per block.
local many = Input.cta({ data = block(2, string.rep("\16", 31)) .. block(2, string.rep("\97", 31)) })
result = parse(string.rep(many, 255), 255)
assert(#result.extensions == 32 and result.extensions_truncated and not result.extensions_decoded)
local count = 0
for _, e in ipairs(result.extensions) do count = count + #e.video_formats end
assert(count == 128 and #Wire.encode(result) < 70000)
-- Linux attaches exactly these shared declarations; public exports keep
-- nested stale state and discard raw additions, including vendor serials.
local tree = Input.tree({ extensions = 1, tail = Input.cta({ data = data }) })
local sample = Displays.new({ fs = Fixture.new(tree) }):sample({ now_ns = function() return 1000000000 end })
local panel = sample.data.devices[3]
panel.edid.extensions[1].raw = "PRIVATE-EXTENSION"
panel.edid.extensions[1].vendors[1].serial = "PRIVATE-VENDOR-SERIAL"
panel.edid.extensions[1].video_formats[1].raw = "PRIVATE-VIDEO"
panel.edid.extensions[1].audio_formats[1].raw = "PRIVATE-AUDIO"
panel.edid.extensions[1].audio_formats[1].sample_rates_hz[4] = { raw = "PRIVATE-NESTED" }
local snap = Snapshot.merge(Snapshot.new(0, 0), { displays = sample }, 1, 1000000000)
local out = Export.snapshot(snap)
assert(out.displays.devices[3].edid.extensions[1].video_formats[3].vic == 76)
assert(not JSON.encode(out):find("PRIVATE", 1, true))
assert(not JSON.encode(Export.agent(snap)):find("PRIVATE", 1, true))
local report = Report.render(out)
assert(report:find("CTA video declarations", 1, true) and report:find("64:27", 1, true))
assert(report:find("CTA audio declarations", 1, true) and report:find("640", 1, true))
assert(not report:find("PRIVATE", 1, true))
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
  local i18n = assert(I18n.new({ locale = locale }))
  assert(i18n:has("display.cta_video") and i18n:has("reason.edid_cta_invalid_data_block"))
  -- The actual collector only provides scalar list entries. Remove the
  -- intentionally hostile export fixture before exercising the UI model.
  panel.edid.extensions[1].audio_formats[1].sample_rates_hz[4] = nil
  local lines = table.concat(TUI.hardware_detail_lines(snap, "display:card1-eDP-1", i18n, 1100000000), "\n")
  assert(lines:find("CTA-861", 1, true) and lines:find("VIC 76", 1, true) and lines:find("64:27", 1, true))
  assert(lines:find("Linear PCM", 1, true) and not lines:find("PRIVATE", 1, true))
end
snap.quality.displays.quality = "stale"
local stale = Export.snapshot(snap).displays.devices[3].edid.extensions[1]
assert(stale.quality == "stale" and stale.video_formats[1].quality == "stale" and stale.vendors[1].quality == "stale")
