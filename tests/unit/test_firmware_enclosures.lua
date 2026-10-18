package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Data = require("support.firmware_enclosures")
local FS = require("support.fixture_fs")
local SMBIOS = require("wtop.format.smbios")
local Collector = require("wtop.collectors.firmware_enclosures")
local Snapshot = require("wtop.model.snapshot")
local Hardware = require("wtop.model.hardware")
local Export = require("wtop.export")
local Report = require("wtop.report")
local ViewModel = require("wtop.view_model")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local JSON = require("wtop.format.json")
local fixture = Data.new()
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end
local function parse(data, options) return assert(SMBIOS.parse(data .. fixture.ending, nil, options)) end

local parsed = assert(SMBIOS.parse(fixture.blob))
assert(not parsed.partial and #parsed.baseboards == 3 and #parsed.enclosures == 2)
local board, chassis = parsed.baseboards[1], parsed.enclosures[1]
assert(board.product == "Fixture Mainboard" and board.manufacturer == "Example Boards")
assert(board.board_type == "Motherboard" and board.location == "Main tray" and board.feature_flags == 31)
assert(board.chassis_handle == "0300" and board.containment_complete and #board.contained_handles == 2)
assert(board.contained_handles[1] == "0400" and board.contained_handles[2] == "0201")
assert(board.serial_present and board.asset_tag_present)
assert(chassis.chassis_type == "Rack mount chassis" and chassis.lock_reported_present)
assert(chassis.height_ou == 2 and chassis.height_u == nil and chassis.power_cords == 2)
assert(chassis.boot_state == "Safe" and chassis.power_state == "Warning" and chassis.thermal_state == "Critical")
assert(chassis.security_state == "External interface locked out" and chassis.oem_data_present)
assert(chassis.sku == "RACK-SKU" and chassis.containment_complete and #chassis.contained_elements == 1)
assert(chassis.contained_elements[1].type_kind == "structure" and chassis.contained_elements[1].type_code == 17)
assert(chassis.contained_elements[1].minimum == 1 and chassis.contained_elements[1].maximum == 8)
local legacy_board, legacy_chassis = parsed.baseboards[3], parsed.enclosures[2]
assert(legacy_board.feature_flags == nil and legacy_board.chassis_handle == nil and legacy_board.board_type == nil)
assert(legacy_board.contained_count == nil and not legacy_board.containment_complete)
assert(legacy_chassis.boot_state == nil and legacy_chassis.boot_state_code == nil and legacy_chassis.height_u == nil)
assert(legacy_chassis.lock_reported_present == false and legacy_chassis.chassis_type == "Laptop")
assert(not JSON.encode(parsed):find("PRIVATE", 1, true))
assert(not JSON.encode(parsed):find("abcdef12", 1, true))

local collector = Collector.new({ platform = "linux", fs = FS.new({ files = fixture.files }) })
local result = collector:sample({})
assert(result.status == "ok" and result.quality == "fresh" and collector:probe({}).available)
assert(result.data.baseboards[1].source == "/sys/firmware/dmi/tables/DMI#0200")
local state = Snapshot.merge(nil, { firmware_enclosures = result,
    processor_firmware = require("wtop.collectors.processor_firmware").new({
        platform = "linux", fs = FS.new({ files = fixture.files }) }):sample({}),
    firmware_components = require("wtop.collectors.firmware_components").new({
        platform = "linux", fs = FS.new({ files = fixture.files }) }):sample({}),
}, 1, 1)
local graph = Hardware.build(state)
local main, rack = graph.by_id["baseboard:0200"], graph.by_id["enclosure:0300"]
assert(main and main.kind == "baseboard" and main.parent_id == rack.id)
assert(#main.chassis_ids == 1 and main.chassis_ids[1] == rack.id and #rack.baseboard_ids == 2)
assert(#main.contained_ids == 2 and main.contained_ids[1] == "baseboard:0201")
assert(graph.by_id["firmware-socket:0400"].baseboard_ids[1] == main.id)
assert(graph.by_id["firmware-socket:0400"].parent_id == nil, "cross-references must not invent physical parents")
assert(#rack.contained_ids == 0, "contained type/count declarations are not handles")
assert(#graph.by_id["firmware-component:4500"].associated_ids == 2)
assert(#main.firmware_component_ids == 1 and #rack.firmware_component_ids == 1)
local destinations = {}
for _, item in ipairs(Hardware.related(graph, main.id).items) do destinations[item.id] = true end
assert(destinations[rack.id] and destinations["baseboard:0201"] and destinations["firmware-socket:0400"])
assert(Hardware.related(graph, main.id, 1).truncated)
local exported = Export.snapshot(state)
assert(exported.firmware_enclosures.enclosures[1].height_ou == 2)
assert(exported.firmware_enclosures.baseboards_total == 3 and exported.firmware_enclosures.enclosures_total == 2)
local topology = {}
for _, node in ipairs(exported.inventory.topology.nodes) do topology[node.id] = node end
assert(topology[main.id].chassis_ids[1] == rack.id and #topology[main.id].contained_ids == 2)
assert(topology[rack.id].baseboard_ids[1] == main.id)
local agent = Export.agent(state)
assert(agent.metrics.firmware_enclosures.enclosures[1].thermal_state == "Critical")
assert(agent.overall.signal_count == 0, "last-boot enclosure states cannot create live health alerts")
local report = Report.render(exported)
assert(report:find("Baseboards", 1, true) and report:find("Enclosures", 1, true))
assert(report:find("2 OU", 1, true) and report:find("RACK-SKU", 1, true))
assert(report:find("Enclosure states at last boot", 1, true) and report:find("not live health", 1, true))

for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
    local i18n = assert(I18n.new({ locale = locale }))
    for _, key in ipairs({ "enclosure.board", "enclosure.chassis", "enclosure.note", "enclosure.board_note",
        "enclosure.lock", "enclosure.element_note", "enclosure.boot_state", "enclosure.thermal_state",
        "reason.no_firmware_enclosures", "reason.firmware_enclosures_incomplete" }) do assert(i18n:has(key), locale .. " " .. key) end
    local board_text = table.concat(TUI.hardware_detail_lines(state, main.id, i18n), "\n")
    local chassis_text = table.concat(TUI.hardware_detail_lines(state, rack.id, i18n), "\n")
    assert(board_text:find("Fixture Mainboard", 1, true) and board_text:find("Main tray", 1, true))
    assert(board_text:find("0x1f", 1, true) and board_text:find("CPU Socket", 1, true))
    assert(chassis_text:find("2 OU", 1, true) and chassis_text:find(i18n:t("enclosure.note"), 1, true))
    assert(not (board_text .. chassis_text):find("PRIVATE", 1, true))
    local system = ViewModel.build({ history_values = function() return {} end }, state, i18n, {}, "system",
        nil, nil, { system_query = "bus:firmware model:Mainboard" }).system_devices
    assert(#system.rows == 2 and system.ids[1] == rack.id and system.ids[2] == main.id)
    assert(system.rows[2].filter_match and not system.rows[1].filter_match)
end
assert(not JSON.encode(exported):find("PRIVATE", 1, true) and not JSON.encode(agent):find("PRIVATE", 1, true))
-- Defensive export also excludes fields supplied by an untrusted adapter.
local untrusted = copy(state)
untrusted.firmware_enclosures.baseboards[1].serial_number = "PRIVATE-EXPORT"
untrusted.firmware_enclosures.enclosures[1].asset_tag = "PRIVATE-EXPORT"
untrusted.firmware_enclosures.enclosures[1].oem_data = "PRIVATE-EXPORT"
assert(not JSON.encode(Export.snapshot(untrusted)):find("PRIVATE", 1, true))
assert(not JSON.encode(Export.agent(untrusted)):find("PRIVATE", 1, true))

-- Handle ambiguity, stale records and truncation cannot establish relationships.
for _, change in ipairs({
    function(s) s.quality.firmware_enclosures.quality = "stale" end,
    function(s) s.quality.firmware_enclosures.status = "denied" end,
    function(s) s.firmware_enclosures.truncated = true end,
    function(s) s.firmware_enclosures.baseboards[1].quality = "partial" end,
    function(s) s.firmware_enclosures.baseboards[1].ambiguous = true end,
    function(s) s.firmware_enclosures.enclosures[1].ambiguous = true end,
    function(s) s.firmware_enclosures.enclosures[1].quality = "stale" end,
    function(s) s.firmware_enclosures.baseboards[1].chassis_handle = "ff00" end,
    function(s) s.firmware_enclosures.baseboards[1].chassis_handle = "0400" end,
}) do
    local s = copy(state); change(s)
    local g = Hardware.build(s)
    assert(g.by_id[main.id].parent_id == nil and #g.by_id[main.id].chassis_ids == 0)
end
for _, change in ipairs({
    function(s) s.quality.processor_firmware.quality = "stale" end,
    function(s) s.processor_firmware.truncated = true end,
    function(s) s.processor_firmware.processors[1].ambiguous = true end,
    function(s) s.processor_firmware.processors[1].quality = "partial" end,
    function(s) s.firmware_enclosures.baseboards[1].containment_complete = false end,
}) do
    local s = copy(state); change(s)
    local g = Hardware.build(s)
    for _, id in ipairs(g.by_id[main.id].contained_ids) do assert(id ~= "firmware-socket:0400") end
end
local collision = copy(state)
collision.firmware_enclosures.baseboards[3].handle = 0x0300
assert(Hardware.build(collision).by_id[main.id].parent_id == nil)

local bad_count = parse(Data.put(fixture.board, 14, "\255") .. fixture.chassis)
assert(bad_count.partial and not bad_count.baseboards[1].containment_complete)
for _, handle in ipairs({ 0xffff, 0x0200, 0x0400 }) do
    local bad = parse(Data.put(fixture.board, 17, Data.word(handle)))
    assert(bad.partial and not bad.baseboards[1].containment_complete)
end
local reserved = parse(Data.put(fixture.board, 9, "\255"))
assert(reserved.partial and reserved.baseboards[1].feature_flags == 255)
for _, change in ipairs({ { 19, "\255" }, { 20, "\0" }, { 20, "\2" },
    { 20, "\255" }, { 22, "\255" }, { 23, "\0" }, { 22, "\9" } }) do
    local bad = parse(Data.put(fixture.chassis, change[1], change[2]))
    assert(bad.partial and not bad.enclosures[1].containment_complete)
end
local malformed_tail = parse(Data.put(fixture.chassis, 19, "\2"))
assert(malformed_tail.partial and malformed_tail.enclosures[1].sku == nil
    and malformed_tail.enclosures[1].height_ou == nil)
local unknown_rack = parse(Data.put(fixture.chassis, 25, "\2"))
assert(unknown_rack.partial and unknown_rack.enclosures[1].height_u == nil
    and unknown_rack.enclosures[1].height_ou == nil and unknown_rack.enclosures[1].rack_type_code == 2)
local height_u = parse(Data.put(fixture.chassis, 17, "\4"))
assert(not height_u.partial and height_u.enclosures[1].height_u == 4 and height_u.enclosures[1].height_ou == nil)
local zero_cords = parse(Data.put(fixture.chassis, 18, "\0"))
assert(zero_cords.enclosures[1].power_cords == nil)
local board_element = parse(Data.put(fixture.chassis, 21, "\10"))
assert(board_element.enclosures[1].contained_elements[1].type_kind == "baseboard"
    and board_element.enclosures[1].contained_elements[1].board_type == "Motherboard")
local future = parse(Data.put(fixture.chassis, 5, "\127") .. Data.put(fixture.board, 13, "\254"))
assert(future.enclosures[1].chassis_type == nil and future.enclosures[1].chassis_type_code == 127)
assert(future.baseboards[1].board_type == nil and future.baseboards[1].board_type_code == 254)
local invalid_string = parse(Data.put(fixture.board, 5, "\250"))
assert(invalid_string.partial and invalid_string.baseboards[1].product == nil)
local duplicate = parse(fixture.board .. fixture.board .. fixture.chassis)
assert(duplicate.partial and duplicate.baseboards[1].ambiguous and duplicate.baseboards[2].ambiguous)
local unsupported_collision = parse(fixture.board .. Data.record(11, 5, 0x0200, { [4] = "\0" }))
assert(unsupported_collision.baseboards[1].ambiguous)
local limited = assert(SMBIOS.parse(fixture.blob, nil, { max_baseboards = 1, max_enclosures = 1 }))
assert(limited.truncated and #limited.baseboards == 1 and #limited.enclosures == 1)

-- Old, short and variable-width records stay bounded at every length.
for kind, minimum in pairs({ [2] = 8, [3] = 9 }) do
    for length = 4, 255 do
        local value, reason = SMBIOS.parse(Data.record(kind, length, 0x0900) .. fixture.ending)
        if length >= minimum then
            assert(value and #value[kind == 2 and "baseboards" or "enclosures"] == 1)
        else assert(value == nil and reason == "smbios_invalid") end
    end
end
local wide_elements = Data.record(3, 31, 0x0305, { [5] = "\23", [17] = "\4\1\2\4",
    [21] = "\10\1\2\0\145\2\4\0", [29] = "\1" }, { "WIDE-SKU" })
local wide = parse(wide_elements).enclosures[1]
assert(wide.containment_complete and #wide.contained_elements == 2 and wide.sku == "WIDE-SKU")
local truncated_extended = parse(Data.record(3, 19, 0x0306, { [17] = "\255" }))
assert(truncated_extended.partial and truncated_extended.enclosures[1].height_u == nil)

local base = "/sys/firmware/dmi/tables"
local no_data = Collector.new({ platform = "linux", fs = FS.new({ files = {
    [base .. "/DMI"] = fixture.ending, [base .. "/smbios_entry_point"] = Data.entry_point(#fixture.ending) } }) }):sample({})
assert(no_data.status == "unavailable" and no_data.reason == "no_firmware_enclosures")
local denied = Collector.new({ platform = "linux", fs = FS.new({ denied = { [base .. "/DMI"] = true } }) })
assert(denied:sample({}).status == "denied" and denied:probe({}).state == "denied")
local missing_metadata = Collector.new({ platform = "linux", fs = FS.new({ files = { [base .. "/DMI"] = fixture.blob } }) }):sample({})
assert(missing_metadata.status == "ok" and missing_metadata.quality == "partial")
local invalid = Collector.new({ platform = "linux", fs = FS.new({ files = {
    [base .. "/DMI"] = fixture.blob, [base .. "/smbios_entry_point"] = "invalid" } }) }):sample({})
assert(invalid.status == "error")
for _, platform in ipairs({ "windows", "macos" }) do
    local queries = 0
    local native = { read_smbios = function()
        queries = queries + 1
        return { data = fixture.blob, major = 3, minor = 9 }
    end }
    local all = require("wtop.collectors").new_all({ platform = platform, common = { native = native } })
    local context = { _collector_batch = {} }
    local a = all.firmware_enclosures:sample(context)
    local b = all.processor_firmware:sample(context)
    assert(a.status == "ok" and a.data.enclosures[1].sku == "RACK-SKU" and queries == 1)
    assert(b.data.processors[1].designation == "CPU Socket")
    a.data.enclosures[1].sku = "mutated"
    assert(all.firmware_enclosures:sample(context).data.enclosures[1].sku == "RACK-SKU" and queries == 1)
end
local workers = require("wtop.collectors.smbios_worker")
assert(workers.sources.firmware_enclosures)
local reads = 0
local shared = workers.new({ reader = { sample = function()
    reads = reads + 1
    return { status = "ok", timestamp_ns = 1, quality = "fresh", data = {
        data = fixture.blob, metadata = { major = 3, minor = 9 }, source = base .. "/DMI" } }
end, close = function() end } })
local proxy = shared:wrap(collector)
local batch = { _collector_batch = {} }
assert(proxy:sample(batch).data.baseboards[1].product == "Fixture Mainboard")
assert(proxy:sample(batch).data.enclosures[1].sku == "RACK-SKU" and reads == 1)
shared:close()
assert(proxy:sample({ _collector_batch = {} }).status == "error")
proxy:close()
assert(proxy:sample(batch).status == "error")

local many = copy(state)
many.firmware_enclosures.baseboards = {}
for n = 1, 64 do
    local entry = copy(board); entry.id = string.format("%04x", 0x1000 + n); entry.handle = 0x1000 + n
    many.firmware_enclosures.baseboards[n] = entry
end
local bounded = Export.agent(many).metrics.firmware_enclosures
assert(#bounded.baseboards == 5 and bounded.baseboards_total == 64 and bounded.truncated)
assert(JSON.encode(Export.snapshot({})):find('"enclosures":[]', 1, true))
print("ok: SMBIOS boards/enclosures, legacy bounds, rack units, private fields, explicit relationships, UI/export/report and shared cross-platform input")
