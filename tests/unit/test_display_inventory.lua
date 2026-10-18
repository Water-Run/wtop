package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local EDID = require("wtop.format.edid")
local Displays = require("wtop.collectors.drm_displays")
local Fixture = require("support.fixture_fs")
local Input = require("support.display_fixtures")
local Hardware = require("wtop.model.hardware")
local Snapshot = require("wtop.model.snapshot")
local Export = require("wtop.export")
local JSON = require("wtop.format.json")
local Report = require("wtop.report")
local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")
local TUI = require("wtop.tui")
local Wire = require("wtop.core.worker_wire")

local raw = Input.edid()
local parsed = assert(EDID.parse(raw))
assert(parsed.quality == "fresh" and parsed.version == "1.4")
assert(parsed.manufacturer == "SAM" and parsed.product_code == 0x1234)
assert(parsed.name == "FixturePanel" and parsed.serial_present)
assert(parsed.bits_per_color == 8 and parsed.interface == "DisplayPort" and parsed.digital)
assert(parsed.width_mm == 520 and parsed.height_mm == 290)
assert(parsed.manufacture_week == 12 and parsed.manufacture_year == 2024)
local timing = parsed.detailed_timings[1]
assert(#parsed.detailed_timings == 1 and timing.horizontal_active_pixels == 1920)
assert(timing.vertical_active_lines == 1080 and timing.pixel_clock_hz == 148500000)
assert(timing.refresh_hz == 60 and timing.preferred and not timing.interlaced)
assert(timing.width_mm == 520 and timing.height_mm == 290)
assert(not parsed.extensions_decoded and parsed.extension_count == 0)
assert(not JSON.encode(parsed):find("PRIVATE", 1, true) and parsed.serial == nil)
assert(not EDID.parse(nil) and not EDID.parse(string.rep("\0", 128)))
assert(not EDID.parse(raw:sub(1, 127)) and not EDID.parse(raw .. string.rep("\0", 32768)))
assert(select(2, EDID.parse(raw:sub(1, 127) .. string.char((raw:byte(128) + 1) % 256))) == "edid_invalid_checksum")
assert(select(2, EDID.parse(Input.edid({ bytes = { [18] = 2 } }))) == "edid_unsupported_version")
assert(EDID.parse(Input.edid({ bytes = { [8] = 0 } })).quality == "partial")
for revision = 0, 3 do
  local old = assert(EDID.parse(Input.edid({ revision = revision })))
  assert(old.digital and old.bits_per_color == nil and old.interface == nil)
end
assert(not EDID.parse(Input.edid({ input = 0x25 })).digital)
assert(EDID.parse(Input.edid({ input = 0xf5 })).bits_per_color == nil)
assert(EDID.parse(Input.edid({ input = 0xa6 })).interface == nil)
local year = assert(EDID.parse(Input.edid({ bytes = { [16] = 255 } })))
assert(year.model_year == 2024 and year.manufacture_year == nil and year.manufacture_week == nil)
assert(EDID.parse(Input.edid({ bytes = { [16] = 55 } })).quality == "partial")
assert(EDID.parse(Input.edid({ bytes = { [21] = 0 } })).width_mm == nil,
  "EDID 1.4 aspect-ratio byte was reported as a physical size")
local interlaced = assert(EDID.parse(Input.edid({ interlaced = true }))).detailed_timings[1]
assert(interlaced.interlaced and interlaced.refresh_hz == nil and interlaced.vertical_active_lines == 1080,
  "interlaced EDID lines must not be guessed into a frame height or refresh")
assert(#EDID.parse(Input.edid({ bytes = { [56] = 0, [58] = 1 } })).detailed_timings == 0)
assert(EDID.parse(Input.edid({ bytes = { [77] = 27 } })).name == nil, "control bytes escaped the name validator")
local extended = assert(EDID.parse(Input.edid({ extensions = 1, tail = string.rep("\0", 128) })))
assert(extended.quality == "fresh" and extended.blocks_available == 2 and not extended.extensions_decoded)
assert(EDID.parse(Input.edid({ extensions = 1 })).reason == "edid_incomplete")
assert(EDID.parse(Input.edid({ extensions = 1, tail = "\1" .. string.rep("\0", 127) })).reason == "edid_invalid_extension_checksum")
assert(EDID.parse(raw .. "\0").quality == "partial")
assert(not EDID.parse(Input.edid({ bytes = { [12] = 0, [13] = 0, [14] = 0, [15] = 0, [93] = 254 } })).serial_present)
local empty_serial = { [12] = 0, [13] = 0, [14] = 0, [15] = 0 }
for offset = 95, 107 do empty_serial[offset] = 0 end
assert(not EDID.parse(Input.edid({ bytes = empty_serial })).serial_present,
  "an empty serial descriptor was reported as a serial value being present")
-- Corrupt/truncated device input remains a bounded parse result, not an
-- exception that can bring down the independent reader or its next sample.
for offset = 0, 127 do
  for _, value in ipairs({ 0, 1, 127, 255 }) do
    assert(pcall(EDID.parse, Input.edid({ bytes = { [offset] = value } })))
  end
end

local context = { now_ns = function() return 2000000000 end }
local function sample(tree)
  local source = Displays.new({ fs = Fixture.new(tree or Input.tree()) })
  assert(source:probe(context).available)
  return source:sample(context)
end
local result = sample()
assert(result.status == "ok" and result.quality == "fresh" and #result.data.devices == 3)
local panel = result.data.devices[3]
assert(panel.id == "card1-eDP-1" and panel.connector == "eDP-1" and panel.card == "card1")
assert(panel.connection == "connected" and panel.enabled and panel.dpms == "On")
assert(panel.pci_address == "0000:00:02.0" and #panel.modes == 2)
assert(panel.connector_id == 95 and panel.observed_at_ns == 2000000000)
assert(result.data.devices[1].connection == "disconnected" and not result.data.devices[1].enabled)
local base, path = "/sys/class/drm", "/sys/class/drm/card1-eDP-1"
local denied = Input.tree();denied.denied = { [path .. "/edid"] = true }
local denied_result = sample(denied)
assert(denied_result.quality == "partial" and denied_result.data.devices[3].edid_status == "denied")
local unknown = Input.tree();unknown.files[path .. "/status"] = "unknown\n"
assert(sample(unknown).data.devices[3].connection == "unknown")
local disconnected = Input.tree();disconnected.files[path .. "/status"] = "disconnected\n"
assert(sample(disconnected).data.devices[3].edid == nil, "disconnected connector exported an old monitor identity")
local malformed = Input.tree();malformed.files[path .. "/edid"] = "invalid"
assert(sample(malformed).data.devices[3].edid_reason == "edid_incomplete")
local absent = Displays.new({ fs = Fixture.new({}) })
assert(not absent:probe(context).available and absent:sample(context).reason == "no_display_connectors")
local refused = Displays.new({ fs = Fixture.new({ denied = { [base] = true } }) })
assert(refused:probe(context).state == "denied" and refused:sample(context).status == "denied")
local broken_fs = { list = function() return nil, { kind = "io_error" } end }
local broken = Displays.new({ fs = broken_fs })
assert(broken:probe(context).state == "error" and broken:sample(context).status == "error")
local many = Input.tree()
for i = 1, 130 do many.dirs[base][#many.dirs[base] + 1] = "card1-DP-1-" .. i end
local capped = sample(many)
assert(capped.data.truncated and #capped.data.devices == 128)
local bounded = Input.tree();bounded.dirs[base] = { "card1-eDP-1" }
for i = 1, 1100 do bounded.dirs[base][#bounded.dirs[base] + 1] = "renderD" .. i end
local bounded_source = Displays.new({ fs = Fixture.new(bounded) })
local limited = bounded_source:sample(context)
assert(limited.data.total_is_lower_bound and limited.data.truncated)
bounded.dirs[base][1] = "renderD0"
bounded_source = Displays.new({ fs = Fixture.new(bounded) })
assert(bounded_source:probe(context).reason == "device_enumeration_truncated")
assert(bounded_source:sample(context).reason == "device_enumeration_truncated",
  "an incomplete scan claimed that there were no display connectors")
assert(not pcall(Displays.new, { drm_base = "relative" }))
-- A changed EDID, status, connector ID or device link invalidates the whole
-- observation. Nothing from either side of the replacement acquires a parent.
for _, changed in ipairs({ "/edid", "/status", "/connector_id", "link", "card" }) do
  local fs = Fixture.new(Input.tree())
  local read, readlink, calls = fs.read, fs.readlink, 0
  if changed == "link" or changed == "card" then
    fs.readlink = function(self, value)
      local wanted = changed == "link" and path or base .. "/card1/device"
      if value == wanted then calls = calls + 1;if calls == 2 then return "changed" end end
      return readlink(self, value)
    end
  else
    fs.read = function(self, value, limit)
      if value == path .. changed then
        calls = calls + 1
        if calls == 2 then return changed == "/status" and "disconnected\n" or "changed" end
      end
      return read(self, value, limit)
    end
  end
  local value = Displays.new({ fs = fs }):sample(context).data.devices[3]
  assert(value.quality == "gap" and value.edid == nil and value.pci_address == nil
    and value.connection == nil and #value.modes == 0, changed)
end

local snap = Snapshot.merge(Snapshot.new(0, 0), { displays = result }, 1, 2000000000)
snap.inventory = { pci = { devices = { { address = "0000:00:02.0", vendor_id = 0x8086,
  device_id = 0x1234, device_name = "Fixture GPU" } } } }
local graph = Hardware.build(snap)
local node = assert(graph.by_id["display:card1-eDP-1"])
assert(node.parent_id == "pci:0000:00:02.0" and node.resource == "displays")
assert(Hardware.related(graph, node.parent_id).total == 3)
snap.quality.inventory = { quality = "stale" }
assert(Hardware.build(snap).by_id[node.id].parent_id == nil)
snap.quality.inventory = nil
-- Whitelists discard private/raw additions even from an injected collector.
panel.edid.serial, panel.edid.raw = "PRIVATE-INJECTED", raw
panel.edid.detailed_timings[1].raw = "PRIVATE-TIMING"
panel.serial = "PRIVATE-DEVICE"
local full = Export.snapshot(snap)
local agent = Export.agent(snap, { device_limit = 2 })
assert(#full.displays.devices == 3 and full.displays.devices[3].edid.name == "FixturePanel")
assert(agent.metrics.displays.total == 3 and #agent.metrics.displays.devices == 2 and agent.metrics.displays.truncated)
assert(not JSON.encode(full):find("PRIVATE", 1, true) and not JSON.encode(agent):find("PRIVATE", 1, true))
local report = Report.render(full)
assert(report:find("FixturePanel", 1, true) and report:find("60.000 Hz", 1, true))
assert(report:find("not the active resolution", 1, true) and not report:find("PRIVATE", 1, true))
-- Verify that the public report actually keeps this source in its schedule.
-- A rendering-only fixture cannot detect a missing report collector entry.
local Engine, Runtime = require("wtop.engine"), require("wtop.native")
local original_new, original_sleep, original_write = Engine.new, Runtime.sleep_ms, io.write
local written, removed = {}, {}
Engine.new = function() return {
  scheduler = { order = { "inventory", "displays" }, remove = function(_, id) removed[id] = true end },
  context = {}, probe = function() return {} end, stop = function() end,
  tick = function()
    if not removed.displays then return snap end
    return { inventory = snap.inventory, quality = {} }
  end } end
Runtime.sleep_ms = function() return true end
io.write = function(text) written[#written + 1] = text;return true end
local report_ok, report_error = pcall(require("wtop.application").report, { privilege = { via_sudo = true } })
Engine.new, Runtime.sleep_ms, io.write = original_new, original_sleep, original_write
assert(report_ok, report_error)
assert(table.concat(written):find("FixturePanel", 1, true), "public report omitted display readings")
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
  local i18n = assert(I18n.new({ locale = locale }))
  assert(i18n:has("display.note") and i18n:has("reason.display_changed_during_read"))
  local lines = table.concat(TUI.hardware_detail_lines(snap, node.id, i18n, 2100000000), "\n")
  assert(lines:find("FixturePanel", 1, true) and lines:find("1920 x 1080", 1, true))
  assert(not lines:find("PRIVATE", 1, true) and not lines:find("0xdeadbeef", 1, true))
end
local model = ViewModel.build({ history_values = function() return {} end }, snap,
  assert(I18n.new({ locale = "en-US" })), {}, "system", nil, nil, { system_query = "vendor:sam" })
assert(#model.system_devices.ids == 2 and model.system_devices.ids[2] == node.id)
snap.quality.displays = { status = "error", quality = "stale" }
assert(Hardware.build(snap).by_id[node.id].parent_id == nil)
assert(Export.agent(snap).metrics.displays.devices[3].quality == "stale")
assert(Export.snapshot(snap).displays.devices[3].edid.quality == "stale")
local unavailable = require("wtop.collectors.portable").new("displays", { native = {} })
assert(unavailable:sample(context).reason == "unsupported_on_this_platform")
-- The successful stateless read releases its process and reuses probe output.
local closes, opens = 0, 0
local native = { available = true,
  hardware_worker_open = function(id) assert(id == "displays");opens = opens + 1;return {} end,
  hardware_worker_query = function() return Wire.encode({ capability = { available = true, state = "available" },
    result = result }), { sample_started_ns = 1000000000, sample_finished_ns = 2000000000 } end,
  hardware_worker_close = function() closes = closes + 1 end }
local proxy = require("wtop.collectors.hardware_worker").new({ id = "displays", default_interval_ms = 5000 }, {}, native)
assert(proxy:probe(context).available and closes == 1 and opens == 1)
assert(proxy:sample(context).status == "ok" and closes == 1 and opens == 1)
assert(proxy:sample(context).status == "ok" and closes == 2 and opens == 2)
proxy:close();assert(closes == 2)
return true
