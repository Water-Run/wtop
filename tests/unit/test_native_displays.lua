package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local NativeDisplays = require("wtop.collectors.native_displays")
local Portable = require("wtop.collectors.portable")
local Fixtures = require("support.display_fixtures")
local Snapshot = require("wtop.model.snapshot")
local Hardware = require("wtop.model.hardware")
local Export = require("wtop.export")
local JSON = require("wtop.format.json")
local Wire = require("wtop.core.worker_wire")
local Report = require("wtop.report")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local function sample(overrides)
  local row = { id = "monitor0", _identity_verified = true, observed_at_ns = 999,
    quality = "fresh", os_present = true, connection = "connected", enabled = true,
    _edid = Fixtures.edid(), edid_status = "ok", driver = "monitor",
    _pnp_instance_id = "DISPLAY\\FIX1234\\PRIVATE-SERIAL-0",
    _pnp_parent_id = "PCI\\VEN_1234&DEV_5678\\PRIVATE-PARENT", _pnp_parent_bus = "pci" }
  for key, value in pairs(overrides or {}) do row[key] = value end
  return { backend = "setupapi", status = "ok", quality = "fresh", total = 1,
    total_is_lower_bound = false, truncated = false, devices = { row } }
end
local result = NativeDisplays.result(sample(), 1000)
assert(result.status == "ok" and result.quality == "fresh" and result.capability.available)
local row = result.data.devices[1]
assert(row.id == "monitor0" and row.backend == "setupapi" and row.os_present)
assert(row.connection == "unknown" and row.enabled == nil and row.dpms == nil,
  "SetupAPI presence was promoted to a physical connection or active display mode")
assert(row.edid.name == "FixturePanel" and row.edid.detailed_timings[1].refresh_hz == 60)
assert(row._edid == nil and row._identity_verified == nil and row.edid.serial == nil)
local cta = Fixtures.cta({ data = Fixtures.cta_block(2, "\144\97") })
local declared = NativeDisplays.result(sample({ _edid = Fixtures.edid({ extensions = 1, tail = cta }) }), 1000).data.devices[1]
assert(declared.edid.extensions[1].video_formats[2].vic == 97 and declared.edid.extensions_decoded)
assert(declared.current_mode == nil and declared.enabled == nil and declared.connection == "unknown",
  "a native CTA declaration became a current desktop mode or physical connection")
local damaged_cta = cta:sub(1, 127) .. string.char((cta:byte(128) + 1) % 256)
local damaged = NativeDisplays.result(sample({ _edid = Fixtures.edid({ extensions = 1, tail = damaged_cta }) }), 1000).data.devices[1]
assert(damaged.edid.name == "FixturePanel" and damaged.edid.extensions[1].video_formats == nil)
assert(damaged.edid.quality == "partial" and damaged.quality == "partial")
local wire = Wire.encode(result)
assert(not wire:find("PRIVATE-SN", 1, true) and not wire:find("PRIVATE-TEXT", 1, true),
  "raw monitor EDID left the reader normalization boundary")
assert(row._pnp_parent_id == "PCI\\VEN_1234&DEV_5678\\PRIVATE-PARENT")
for _, value in ipairs({ 0, 1001 }) do
  local rejected = NativeDisplays.result(sample({ observed_at_ns = value }), 1000)
  assert(rejected.data.devices[1].quality == "gap" and rejected.data.devices[1].edid == nil)
end
for _, quality in ipairs({ "stale", "gap", "denied", "error", "unavailable", "reset" }) do
  local rejected = NativeDisplays.result(sample({ quality = quality }), 1000).data.devices[1]
  assert(rejected.quality == "gap" and rejected.edid == nil and rejected.os_present == nil)
end
local changed = NativeDisplays.result(sample({ _identity_verified = false }), 1000).data.devices[1]
assert(changed.edid == nil and changed._pnp_parent_id == nil and changed.os_present == nil)
local parent = NativeDisplays.result(sample({ quality = "partial", reason = "display_parent_unavailable" }), 1000).data.devices[1]
assert(parent.edid and parent._pnp_parent_id == nil and parent.reason == "display_parent_unavailable")
local denied = NativeDisplays.result(sample({ edid_status = "denied", win32_error = 5 }), 1000).data.devices[1]
assert(denied.edid == nil and denied.edid_status == "denied" and denied.win32_error == 5)
local incomplete = NativeDisplays.result(sample({ _edid = "bad" }), 1000).data.devices[1]
assert(incomplete.edid == nil and incomplete.edid_reason == "edid_incomplete" and incomplete.quality == "partial")
local large = NativeDisplays.result(sample({ _edid = string.rep("x", 32769) }), 1000).data.devices[1]
assert(large.edid == nil and large.edid_reason == "edid_too_large")
local budget = NativeDisplays.result(sample({ _edid = false, edid_status = "unavailable", quality = "partial",
  edid_reason = "display_edid_budget_exhausted" }), 1000).data.devices[1]
assert(budget.edid_reason == "display_edid_budget_exhausted" and budget.quality == "partial")
for _, state in ipairs({ "unavailable", "denied", "error" }) do
  local failed = sample();failed.status = state;failed.devices = {};failed.total = 0
  local output = NativeDisplays.result(failed, 1000)
  assert(output.status == state and output.data == nil and not output.capability.available)
end
local wrong = sample();wrong.backend = "other"
assert(NativeDisplays.result(wrong, 1000).reason == "display_native_data_invalid")
wrong = sample();wrong.devices = {}
assert(NativeDisplays.result(wrong, 1000).status == "error")
wrong = sample();wrong.devices[2] = wrong.devices[1]
local duplicate = NativeDisplays.result(wrong, 1000)
assert(duplicate.quality == "partial" and duplicate.data.devices[1].quality == "gap" and duplicate.data.truncated)
wrong = sample();wrong.devices = {}
for i = 1, 129 do local copy = sample().devices[1];copy.id = "monitor" .. i;wrong.devices[i] = copy end
local capped = NativeDisplays.result(wrong, 1000)
assert(#capped.data.devices == 128 and capped.data.truncated and capped.data.total == 129)

-- The normal portable path converts the native payload before the worker's
-- Wire.encode, and stamps the result after the call, not before a slow API.
local now = 1000
local collector = Portable.new("displays", { _hardware_direct = true, native = {
  collect_displays = function() now = 1100;return sample() end } })
local direct = collector:sample({ now_ns = function() return now end })
assert(direct.timestamp_ns == 1100 and direct.data.devices[1]._edid == nil)
-- Enumeration reordering must not retarget a selected device. A complete
-- absence retires the identity; failures retain the private bounded map.
local function publication(keys, now, partial)
  local input = sample();input.devices = {};input.quality = partial and "partial" or "fresh"
  input.total_is_lower_bound = partial or false
  for index, key in ipairs(keys) do
    local r = sample().devices[1];r.id = "monitor" .. (index - 1);r._pnp_instance_id = key;input.devices[index] = r
  end
  input.total = #keys
  return NativeDisplays.result(input, now)
end
local state = {}
local first = NativeDisplays.publish(publication({ "DISPLAY\\A", "DISPLAY\\B" }, 1200), state)
local a, b = first.data.devices[1].id, first.data.devices[2].id
assert(a ~= b and first.data.devices[1]._pnp_instance_id == nil and first.data.identity_session)
local reordered = NativeDisplays.publish(publication({ "DISPLAY\\B", "DISPLAY\\A" }, 1300), state)
assert(reordered.data.devices[1].id == b and reordered.data.devices[2].id == a)
NativeDisplays.publish({ status = "error", reason = "hardware_query_timeout", timestamp_ns = 1400 }, state)
assert(NativeDisplays.publish(publication({ "DISPLAY\\A" }, 1500, true), state).data.devices[1].id == a)
assert(NativeDisplays.publish(publication({ "DISPLAY\\B" }, 1600), state).data.devices[1].id == b)
local returned = NativeDisplays.publish(publication({ "DISPLAY\\A", "DISPLAY\\B" }, 1700), state)
assert(returned.data.devices[1].id ~= a and returned.data.devices[2].id == b)
NativeDisplays.publish({ status = "unavailable", reason = "no_windows_displays", timestamp_ns = 1800 }, state)
local after_empty = NativeDisplays.publish(publication({ "DISPLAY\\B" }, 1900), state)
assert(after_empty.data.devices[1].id ~= b)
local before_rewind = after_empty.data.devices[1].id
local after_rewind = NativeDisplays.publish(publication({ "DISPLAY\\B" }, 1850), state)
assert(after_rewind.data.devices[1].id ~= before_rewind)
for index = 1, 300 do NativeDisplays.publish(publication({ "DISPLAY\\D" .. index }, 2000 + index, true), state) end
local cached = 0;for _ in pairs(state.entries) do cached = cached + 1 end
assert(cached <= 256)
local public_identity = Export.snapshot({ displays = after_rewind.data }).displays
assert(public_identity.identity_session and public_identity.devices[1].identity_scope == "session")
assert(not JSON.encode(public_identity):find("DISPLAY\\", 1, true))
local reader_now, reader_order, closed = 3000, { "DISPLAY\\A", "DISPLAY\\B" }, 0
local native = { available = true,
  hardware_worker_open = function(id) assert(id == "displays");return {} end,
  hardware_worker_query = function()
    local reply = publication(reader_order, reader_now - 10)
    for _, r in ipairs(reply.data.devices) do r.observed_at_ns = reader_now - 15 end
    return Wire.encode({ capability = { state = "available", available = true }, result = reply }),
      { sample_started_ns = reader_now - 20, sample_finished_ns = reader_now - 5 }
  end,
  hardware_worker_close = function() closed = closed + 1 end }
local proxy = require("wtop.collectors.hardware_worker").new({ id = "displays", default_interval_ms = 5000 }, {}, native)
local reader_context = { now_ns = function() return reader_now end }
local p1 = proxy:sample(reader_context)
assert(p1.status == "ok" and p1.data.devices[1]._pnp_instance_id == nil and closed == 1)
reader_now, reader_order = 3100, { "DISPLAY\\B", "DISPLAY\\A" }
local p2 = proxy:sample(reader_context)
assert(p1.data.devices[1].id == p2.data.devices[2].id and closed == 2,
  "closing a stateless reader reset the parent's display identities")
assert(p1.data.identity_session == p2.data.identity_session)
proxy:close();assert(closed == 2)
local snap = Snapshot.merge(Snapshot.new(0, 0), { displays = result }, 1, 1000)
snap.inventory = { pci = { devices = { { address = "0:1.0", vendor_id = 0x1234, device_id = 0x5678,
  device_name = "Fixture display controller", _pnp_instance_id = row._pnp_parent_id } } } }
local graph = Hardware.build(snap);local node = assert(graph.by_id["display:monitor0"])
assert(node.parent_id == "pci:0:1.0", "a Windows parent was lost or assigned a guessed PCI domain")
snap.quality.inventory = { status = "error", quality = "stale" }
assert(Hardware.build(snap).by_id[node.id].parent_id == nil)
snap.quality.inventory = nil
snap.quality.displays = { status = "error", quality = "stale" }
assert(Hardware.build(snap).by_id[node.id].parent_id == nil)
snap.quality.displays = nil
local full = Export.snapshot(snap)
local agent = Export.agent(snap)
local public = full.displays.devices[1]
assert(public.os_present and public.backend == "setupapi" and public.connection == "unknown")
assert(public._pnp_parent_id == nil and public._edid == nil)
assert(not JSON.encode(full):find("PRIVATE", 1, true) and not JSON.encode(agent):find("PRIVATE", 1, true))
assert(agent.metrics.displays.devices[1].os_present)
local report = Report.render(full)
assert(report:find("OS present", 1, true) and report:find("FixturePanel", 1, true))
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
  local i18n = assert(I18n.new({ locale = locale }))
  assert(i18n:has("display.os_present") and i18n:has("display.os_note"))
  local text = table.concat(TUI.hardware_detail_lines(snap, node.id, i18n, 1100), "\n")
  assert(text:find("FixturePanel", 1, true) and text:find(i18n:t("display.os_note"), 1, true))
  assert(not text:find("DRM", 1, true) and not text:find("PRIVATE", 1, true))
end

-- CoreGraphics OS displays are not EDID declarations. Points and backing
-- pixels remain distinct, and nominal Hz is never a measured refresh rate.
local function mac_sample(overrides)
  local raw = { id = "monitor0", _identity_verified = true, observed_at_ns = 999,
    quality = "fresh", _display_identity = string.rep("a", 32), online = true,
    active = true, asleep = false, builtin = false, main = true,
    vendor_number = 1970170734, model_number = 1986622068,
    current_mode_status = "ok", current_mode = { width_points = 1920, height_points = 1080,
      pixel_width = 3840, pixel_height = 2160, refresh_hz = 59.94,
      _serial = "PRIVATE-MODE-SERIAL" }, _serial = "PRIVATE-MAC-SERIAL",
    width_mm = 677, _edid = Fixtures.edid() }
  for k, v in pairs(overrides or {}) do raw[k] = v end
  return { backend = "coregraphics", status = "ok", quality = "fresh", total = 1,
    total_is_lower_bound = false, truncated = false, devices = { raw } }
end
local mac_result = NativeDisplays.result(mac_sample(), 1000)
assert(mac_result.status == "ok" and mac_result.quality == "fresh" and mac_result.capability.available)
local mac = mac_result.data.devices[1]
assert(mac.backend == "coregraphics" and mac.os_present and mac.connection == "unknown")
assert(mac.online and mac.active and not mac.asleep and not mac.builtin and mac.main)
assert(mac.enabled == nil and mac.dpms == nil and mac.edid == nil and mac.width_mm == nil)
assert(mac.vendor_number == 1970170734 and mac.model_number == 1986622068)
assert(mac.current_mode.width_points == 1920 and mac.current_mode.pixel_width == 3840)
assert(mac.current_mode.refresh_hz == 59.94 and mac.current_mode.refresh_kind == "nominal")
assert(not Wire.encode(mac_result):find("PRIVATE", 1, true), "unknown native/EDID data crossed the normalization boundary")
for _, field in ipairs({ "active", "asleep", "builtin", "main" }) do
  local raw = mac_sample();raw.devices[1][field] = nil
  assert(NativeDisplays.result(raw, 1000).data.devices[1].quality == "gap")
end
for _, bad in ipairs({ { _identity_verified = false }, { observed_at_ns = 1001 },
    { online = false }, { _display_identity = "invalid" }, { quality = "stale" } }) do
  local r = NativeDisplays.result(mac_sample(bad), 1000).data.devices[1]
  assert(r.quality == "gap" and r.current_mode == nil and r.online == nil)
end
for _, field in ipairs({ "width_points", "height_points", "pixel_width", "pixel_height", "refresh_hz" }) do
  for _, value in ipairs({ -1, 0 / 0, math.huge, "1920" }) do
    local raw = mac_sample();raw.devices[1].current_mode[field] = value
    local r = NativeDisplays.result(raw, 1000).data.devices[1]
    assert(r.quality == "partial" and r.current_mode == nil and r.online
      and r.reason == "display_current_mode_unavailable")
  end
end
local unspecified = mac_sample();unspecified.devices[1].current_mode.refresh_hz = 0
local unspecified_mode = NativeDisplays.result(unspecified, 1000).data.devices[1].current_mode
assert(unspecified_mode.refresh_hz == nil and unspecified_mode.refresh_kind == "nominal")
local missing = NativeDisplays.result(mac_sample({ current_mode = false, current_mode_status = "unavailable" }), 1000)
assert(missing.data.devices[1].online and missing.data.devices[1].current_mode_status == "unavailable")
assert(missing.quality == "partial")
local duplicate_mac = mac_sample();duplicate_mac.devices[2] = mac_sample({ id = "monitor1" }).devices[1]
local duplicates = NativeDisplays.result(duplicate_mac, 1000)
assert(duplicates.data.devices[1].quality == "gap" and duplicates.data.devices[2].quality == "gap")
local mac_state = {}
local function mac_publication(keys, now, partial)
  local input = mac_sample();input.devices = {};input.total = #keys
  input.total_is_lower_bound = partial or false
  for i, key in ipairs(keys) do
    input.devices[i] = mac_sample({ id = "monitor" .. i, _display_identity = string.rep(key, 32) }).devices[1]
  end
  return NativeDisplays.publish(NativeDisplays.result(input, now), mac_state)
end
local mac_first = mac_publication({ "a", "b" }, 1200)
local mac_a, mac_b = mac_first.data.devices[1].id, mac_first.data.devices[2].id
assert(mac_first.data.devices[1]._display_identity == nil and mac_first.data.identity_session)
local mac_reordered = mac_publication({ "b", "a" }, 1300)
assert(mac_reordered.data.devices[1].id == mac_b and mac_reordered.data.devices[2].id == mac_a)
mac_publication({ "b" }, 1400, true)
assert(mac_publication({ "a", "b" }, 1500).data.devices[1].id == mac_a)
mac_publication({ "b" }, 1600)
assert(mac_publication({ "a", "b" }, 1700).data.devices[1].id ~= mac_a)
local empty_mac = { backend = "coregraphics", status = "unavailable", quality = "fresh", devices = {}, total = 0 }
local empty_result = NativeDisplays.result(empty_mac, 1800)
assert(empty_result.status == "unavailable" and empty_result.reason == "no_macos_displays")
NativeDisplays.publish(empty_result, mac_state)
assert(mac_publication({ "b" }, 1900).data.devices[1].id ~= mac_b)
empty_mac.quality = "partial"
assert(NativeDisplays.result(empty_mac, 2000).status == "error", "a racing empty enumeration retired known identities")
for _, status in ipairs({ "denied", "error" }) do
  local raw = mac_sample();raw.status = status;raw.devices = {};raw.total = 0
  assert(NativeDisplays.result(raw, 1000).status == status)
end
local mac_snapshot = Snapshot.merge(Snapshot.new(0, 0), { displays = mac_first }, 1, 1200)
local mac_graph = Hardware.build(mac_snapshot)
local mac_node = assert(mac_graph.by_id["display:" .. mac_first.data.devices[1].id])
assert(mac_node.parent_id == nil, "a CoreGraphics display was attached to a guessed GPU")
local mac_full, mac_agent = Export.snapshot(mac_snapshot), Export.agent(mac_snapshot)
local mac_export = mac_full.displays.devices[1]
assert(mac_export.current_mode.pixel_width == 3840 and mac_export.current_mode.refresh_kind == "nominal")
assert(mac_agent.metrics.displays.devices[1].online and mac_agent.metrics.displays.devices[1].current_mode.height_points == 1080)
assert(not JSON.encode(mac_full):find(string.rep("a", 32), 1, true)
  and not JSON.encode(mac_agent):find("_display_identity", 1, true))
local mac_report = Report.render(mac_full)
assert(mac_report:find("Current display modes", 1, true) and mac_report:find("59.940 Hz", 1, true)
  and not mac_report:find("Windows display IDs", 1, true))
mac_snapshot.quality.displays = { status = "error", quality = "stale" }
local stale_mode = Export.snapshot(mac_snapshot).displays.devices[1]
assert(stale_mode.quality == "stale" and stale_mode.current_mode.quality == "stale")
mac_snapshot.quality.displays = nil
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
  local i18n = assert(I18n.new({ locale = locale }))
  local detail = table.concat(TUI.hardware_detail_lines(mac_snapshot, mac_node.id, i18n, 1300), "\n")
  assert(i18n:has("display.nominal_refresh") and detail:find(i18n:t("display.coregraphics_note"), 1, true))
  assert(detail:find("1920 x 1080", 1, true) and detail:find("3840 x 2160", 1, true))
  assert(not detail:find("DRM", 1, true) and not detail:find("EDID", 1, true) and not detail:find("PRIVATE", 1, true))
end
-- GDI describes a source in the current desktop. Its documented interface
-- association is independent of cached EDID presence and declaration values.
local function desktop_sample(overrides)
  local raw = sample().devices[1]
  raw.desktop_status, raw._desktop_identity_verified = "ok", true
  raw.desktop_active, raw.desktop_primary = true, false
  raw.current_mode_status = "ok"
  raw.current_mode = { pixel_width = 2560, pixel_height = 1440, refresh_hz = 144,
    position_x = -2560, position_y = -120, orientation_degrees = 90, bits_per_pixel = 32,
    interlaced = false, observed_at_ns = 1000, _private = "PRIVATE-GDI-ID", hdr = true }
  for key, value in pairs(overrides or {}) do raw[key] = value end
  local input = sample();input.devices[1] = raw;return input
end
local desktop = NativeDisplays.result(desktop_sample(), 1000)
local d = desktop.data.devices[1]
assert(desktop.quality == "fresh" and d.desktop_status == "ok" and d.desktop_active and not d.desktop_primary)
assert(d.connection == "unknown" and d.enabled == nil and d.current_mode.width_points == nil)
assert(d.current_mode.pixel_width == 2560 and d.current_mode.position_x == -2560
  and d.current_mode.position_y == -120 and d.current_mode.orientation_degrees == 90)
assert(d.current_mode.bits_per_pixel == 32 and d.current_mode.interlaced == false
  and d.current_mode.refresh_hz == 144 and d.current_mode.scope == "windows_desktop_source")
assert(d.current_mode._private == nil and d.current_mode.hdr == nil and d._desktop_identity_verified == nil)
for _, status in ipairs({ "unavailable", "error", "gap", "stale", "bogus" }) do
  local r = NativeDisplays.result(desktop_sample({ desktop_status = status }), 1000).data.devices[1]
  assert(r.current_mode == nil and r.desktop_active == nil and r.edid and r.os_present)
  if status == "unavailable" then assert(r.desktop_status == status and r.quality == "fresh")
  else assert(r.quality == "partial" and r.desktop_status == (status == "gap" and "gap" or "error")) end
end
for _, field in ipairs({ "_desktop_identity_verified", "desktop_active", "desktop_primary" }) do
  local raw = desktop_sample();raw.devices[1][field] = nil
  local r = NativeDisplays.result(raw, 1000).data.devices[1]
  assert(r.desktop_status == "gap" and r.desktop_active == nil and r.current_mode == nil and r.edid)
end
local bad_modes = {
  { "pixel_width", 0 }, { "pixel_height", -1 }, { "pixel_width", 0 / 0 },
  { "pixel_height", 1440.5 }, { "refresh_hz", math.huge }, { "refresh_hz", "144" },
  { "refresh_hz", 144.5 }, { "bits_per_pixel", 0 }, { "bits_per_pixel", 129 },
  { "orientation_degrees", 360 }, { "orientation_degrees", 45 },
  { "position_x", -2147483649 }, { "position_y", 2147483648 }, { "position_x", false },
  { "interlaced", 0 }, { "observed_at_ns", 998 }, { "observed_at_ns", 1001 },
}
for _, invalid in ipairs(bad_modes) do
  local raw = desktop_sample();raw.devices[1].current_mode[invalid[1]] = invalid[2]
  local r = NativeDisplays.result(raw, 1000).data.devices[1]
  assert(r.current_mode == nil and r.current_mode_status == "error" and r.quality == "partial"
    and r.desktop_active and r.edid, invalid[1])
end
local incomplete_position = desktop_sample();incomplete_position.devices[1].current_mode.position_y = nil
assert(NativeDisplays.result(incomplete_position, 1000).data.devices[1].current_mode == nil)
for _, frequency in ipairs({ 0, 1 }) do
  local raw = desktop_sample();raw.devices[1].current_mode.refresh_hz = frequency
  local m = NativeDisplays.result(raw, 1000).data.devices[1].current_mode
  assert(m and m.refresh_hz == nil and m.refresh_kind == "nominal")
end
local inactive = NativeDisplays.result(desktop_sample({ desktop_active = false }), 1000).data.devices[1]
assert(inactive.desktop_active == false and inactive.current_mode == nil and inactive.current_mode_status == "unavailable")
local unmeasured = NativeDisplays.result(desktop_sample({ current_mode = false, current_mode_status = "unavailable" }), 1000)
assert(unmeasured.quality == "partial" and unmeasured.data.devices[1].desktop_active)
local no_optional = desktop_sample()
for _, key in ipairs({ "position_x", "position_y", "orientation_degrees", "refresh_hz", "bits_per_pixel", "interlaced" }) do
  no_optional.devices[1].current_mode[key] = nil
end
assert(NativeDisplays.result(no_optional, 1000).data.devices[1].current_mode.pixel_width == 2560)
local desktop_result = NativeDisplays.publish(desktop, {})
local desktop_snapshot = Snapshot.merge(Snapshot.new(0, 0), { displays = desktop_result }, 1, 1000)
local desktop_node = assert(Hardware.build(desktop_snapshot).by_id["display:" .. desktop_result.data.devices[1].id])
local desktop_full, desktop_agent = Export.snapshot(desktop_snapshot), Export.agent(desktop_snapshot)
local public_mode = desktop_full.displays.devices[1].current_mode
assert(public_mode.position_x == -2560 and public_mode.bits_per_pixel == 32 and public_mode.orientation_degrees == 90)
assert(desktop_agent.metrics.displays.devices[1].current_mode.position_y == -120)
assert(desktop_agent.metrics.displays.devices[1].desktop_primary == false)
for _, exported in ipairs({ desktop_full, desktop_agent }) do
  local text = JSON.encode(exported)
  assert(not text:find("PRIVATE", 1, true) and not text:find("_desktop_identity", 1, true))
end
local desktop_report = Report.render(desktop_full)
assert(desktop_report:find("Windows desktop association", 1, true) and desktop_report:find("144.000 Hz", 1, true)
  and desktop_report:find("Framebuffer bits per pixel", 1, true) and desktop_report:find("-2560", 1, true))
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
  local i18n = assert(I18n.new({ locale = locale }))
  local detail = table.concat(TUI.hardware_detail_lines(desktop_snapshot, desktop_node.id, i18n, 1100), "\n")
  for _, name in ipairs({ "status", "active", "primary", "pixels", "position", "orientation", "bpp", "note" }) do
    assert(i18n:has("display.desktop_" .. name) and detail:find(i18n:t("display.desktop_" .. name), 1, true), locale .. name)
  end
  assert(detail:find("2560 x 1440", 1, true) and detail:find("-2560, -120", 1, true)
    and not detail:find("PRIVATE", 1, true))
end
desktop_snapshot.quality.displays = { status = "error", quality = "stale" }
local stale_desktop = Export.snapshot(desktop_snapshot).displays.devices[1]
assert(stale_desktop.desktop_status == "stale" and stale_desktop.current_mode_status == "stale"
  and stale_desktop.current_mode.quality == "stale")
return true
