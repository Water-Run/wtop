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
return true
