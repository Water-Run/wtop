package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Data = require("support.firmware_probes")
local FS = require("support.fixture_fs")
local SMBIOS = require("wtop.format.smbios")
local Collector = require("wtop.collectors.firmware_probes")
local Supplies = require("wtop.collectors.firmware_power_supplies")
local Snapshot = require("wtop.model.snapshot")
local Hardware = require("wtop.model.hardware")
local Export = require("wtop.export")
local Report = require("wtop.report")
local JSON = require("wtop.format.json")
local fixture = Data.new()
local parsed = assert(SMBIOS.parse(fixture.blob))
assert(not parsed.partial and #parsed.firmware_probes == 4 and #parsed.firmware_cooling == 2)
local voltage, temperature, current, old = table.unpack(parsed.firmware_probes)
assert(voltage.minimum == -12.5 and voltage.maximum == 12.5 and voltage.nominal_value == 12)
assert(voltage.resolution == 0.0025 and voltage.tolerance == 0.05 and voltage.accuracy_percent == 1.25)
assert(voltage.minimum_raw == 53036 and voltage.status == "OK" and voltage.location == "Power Unit")
assert(temperature.minimum == -40 and temperature.maximum == 105 and temperature.nominal_value == -5.5)
assert(temperature.resolution == 0.125 and temperature.tolerance == 1.5 and temperature.location == "Front Panel Board")
assert(temperature.status == "Critical" and current.minimum == -2 and current.nominal_value == 2.5)
assert(current.resolution == 0.001 and current.accuracy_percent == nil and current.accuracy_percent_raw == 0x8000)
assert(old.minimum == nil and old.maximum == nil and old.nominal_value_raw == nil and old.status == "Unknown")
local cooling, passive = table.unpack(parsed.firmware_cooling)
assert(cooling.nominal_speed_rpm == 1600 and cooling.device_type == "Power Supply Fan")
assert(cooling.temperature_probe_id == "2800" and passive.temperature_probe_id == nil)
assert(passive.device_type == "Passive Cooling" and passive.nominal_speed_raw == nil)
assert(not JSON.encode(parsed):find("PRIVATE", 1, true) and not JSON.encode(parsed):find("91aadeef", 1, true))

local fs = FS.new({ files = fixture.files })
local context = { _collector_batch = {}, now_ns = function() return 1 end }
local probe = Collector.new({ platform = "linux", fs = fs })
local result = probe:sample(context)
local supply = Supplies.new({ platform = "linux", fs = fs }):sample(context)
assert(result.status == "ok" and result.quality == "fresh" and supply.status == "ok")
assert(result.data._smbios_cohort == supply.data._smbios_cohort)
assert(result.data.probes[1].source == "/sys/firmware/dmi/tables/DMI#2600")
local snapshot = Snapshot.merge(nil, { firmware_probes = result, firmware_power_supplies = supply }, 1, 1)
local graph = Hardware.build(snapshot)
local psu = assert(graph.by_id["firmware-psu:3900"])
local fan = assert(graph.by_id["firmware-cooling:2700"])
assert(#psu.firmware_probe_ids == 2 and psu.firmware_probe_ids[1] == "firmware-probe:2600")
assert(psu.firmware_probe_ids[2] == "firmware-probe:2900" and psu.firmware_cooling_ids[1] == fan.id)
assert(fan.firmware_probe_ids[1] == "firmware-probe:2800" and fan.power_supply_ids[1] == psu.id)
assert(graph.by_id["firmware-probe:2800"].firmware_cooling_ids[1] == fan.id)
assert(fan.parent_id == nil and #fan.sensors == 0 and #graph.by_id["firmware-probe:2800"].sensors == 0)
local related = Hardware.related(graph, psu.id)
assert(related.total == 3)
local exported = Export.snapshot(snapshot)
assert(exported.firmware_probes.declarations_only and exported.firmware_probes.probes[1].nominal_value == 12)
assert(exported.firmware_probes.cooling_devices[1].nominal_speed_rpm == 1600)
assert(not JSON.encode(exported):find("_smbios_cohort", 1, true))
assert(not JSON.encode(exported):find("PRIVATE", 1, true))
local agent = Export.agent(snapshot)
assert(agent.metrics.firmware_probes.declarations_only and agent.overall.signal_count == 0,
    "firmware status or nominal values created live health signals")
local report = Report.render(exported)
assert(report:find("Firmware probes", 1, true) and report:find("Firmware cooling devices", 1, true))
assert(report:find("not live measurements or alarm thresholds", 1, true) and report:find("-5.5 C", 1, true))

local function clone(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}; if seen[value] then return seen[value] end
    local out = {}; seen[value] = out
    for key, item in pairs(value) do out[key] = clone(item, seen) end
    return out
end
for _, mutate in ipairs({
    function(s) s.firmware_probes._smbios_cohort = {} end,
    function(s) s.firmware_power_supplies._smbios_cohort = nil end,
    function(s) s.quality.firmware_probes.quality = "stale" end,
    function(s) s.firmware_probes.truncated = true end,
    function(s) s.firmware_probes._handles_complete = false end,
    function(s) s.firmware_power_supplies.supplies[1].voltage_probe_id = "2800";
        s.firmware_power_supplies.supplies[1].current_probe_id = "2800";
        s.firmware_power_supplies.supplies[1].cooling_device_id = "2800" end,
}) do
    local changed = clone(snapshot); mutate(changed)
    local rows = Hardware.build(changed)
    assert(#rows.by_id[psu.id].firmware_probe_ids == 0 and #rows.by_id[psu.id].firmware_cooling_ids == 0)
end
local changed = clone(snapshot)
changed.firmware_probes.cooling_devices[1].temperature_probe_id = "2900"
assert(#Hardware.build(changed).by_id[fan.id].firmware_probe_ids == 0)
local invalid = assert(SMBIOS.parse(fixture.voltage .. fixture.voltage .. fixture.ending))
assert(invalid.partial and invalid.firmware_probes[1].ambiguous and invalid.firmware_probes[2].ambiguous)
local limited = assert(SMBIOS.parse(fixture.blob, nil, { max_firmware_probes = 1, max_firmware_cooling = 1 }))
assert(limited.truncated and #limited.firmware_probes == 1 and #limited.firmware_cooling == 1)
for _, length in ipairs({ 20, 21, 22 }) do
    local bytes = Data.record(28, length, 0x2801, { [4] = "\0\66" }) .. fixture.ending
    local item = assert(SMBIOS.parse(bytes))
    assert(item.partial == (length == 21))
end
for _, length in ipairs({ 12, 13, 14, 15 }) do
    local bytes = Data.record(27, length, 0x2702, { [4] = Data.word(0xffff), [6] = "\81" }) .. fixture.ending
    local item = assert(SMBIOS.parse(bytes)); assert(item.partial == (length == 13))
end
local missing = Collector.new({ platform = "linux", fs = FS.new({ files = {
    ["/sys/firmware/dmi/tables/DMI"] = fixture.ending,
    ["/sys/firmware/dmi/tables/smbios_entry_point"] = Data.entry_point(#fixture.ending) } }) }):sample({})
assert(missing.status == "unavailable" and missing.reason == "no_firmware_probes")
local denied = Collector.new({ platform = "linux", fs = FS.new({ denied = { ["/sys/firmware/dmi/tables/DMI"] = true } }) }):sample({})
assert(denied.status == "denied")
local portable = Collector.new({ platform = "windows", native = { read_smbios = function()
    return { data = fixture.blob, major = 3, minor = 9 } end } }):sample({})
assert(portable.status == "ok" and #portable.data.probes == 4)
print("firmware probes: signed specs, unknown sentinels, legacy lengths, private OEM fields, typed same-decode links and no live health promotion")

-- Details are translated and reachable without promoting firmware status to
-- sensor input. The PSU itself can navigate to the typed references.
do
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local ViewModel = require("wtop.view_model")
    for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
        local i18n = assert(I18n.new({ locale = locale }))
        for _, key in ipairs({ "firmware_probe.device", "firmware_probe.cooling", "firmware_probe.note",
            "firmware_probe.minimum", "firmware_probe.maximum", "firmware_probe.nominal",
            "reason.no_firmware_probes", "reason.firmware_probes_incomplete" }) do
            assert(i18n:has(key), locale .. " " .. key)
        end
        local text = table.concat(TUI.hardware_detail_lines(snapshot, "firmware-probe:2800", i18n), "\n")
        assert(text:find("-5.5 C", 1, true) and text:find("-40 C", 1, true))
        assert(text:find(i18n:t("firmware_probe.note"), 1, true))
        local supply_text = table.concat(TUI.hardware_detail_lines(snapshot, psu.id, i18n), "\n")
        assert(supply_text:find("Input rail", 1, true) and supply_text:find("PSU fan", 1, true))
        local cooling_text = table.concat(TUI.hardware_detail_lines(snapshot, fan.id, i18n), "\n")
        assert(cooling_text:find("1600", 1, true) and cooling_text:find("Inlet probe", 1, true))
        local view = ViewModel.build({ history_values = function() return {} end }, snapshot, i18n,
            {}, "system", nil, nil, { system_query = "bus:firmware name:Input rail" }).system_devices
        assert(#view.rows == 1 and view.ids[1] == "firmware-probe:2600")
    end
end

-- All optional sentinels stay absent, while literal zero specifications stay
-- present. Minimum/maximum/nominal values use signed 16-bit representations.
do
    local function parse(bytes) return assert(SMBIOS.parse(bytes .. fixture.ending)) end
    local unknown = Data.record(29, 22, 0x2901, { [4] = "\0\66", [6] = Data.word(0x8000),
        [8] = Data.word(0x8000), [10] = Data.word(0x8000), [12] = Data.word(0x8000),
        [14] = Data.word(0x8000), [20] = Data.word(0x8000) })
    local value = parse(unknown).firmware_probes[1]
    assert(value.nominal_value == nil and value.nominal_value_raw == 0x8000)
    assert(value.resolution == nil and value.tolerance == nil and value.accuracy_percent == nil)
    value = parse(Data.record(26, 22, 0x2603, { [4] = "\0\66" })).firmware_probes[1]
    assert(value.minimum == 0 and value.maximum == 0 and value.nominal_value == 0)
    assert(value.resolution == 0 and value.tolerance == 0 and value.accuracy_percent == 0)
    value = parse(Data.record(27, 14, 0x2703, { [4] = Data.word(0xffff), [6] = "\81",
        [12] = Data.word(0x8000) })).firmware_cooling[1]
    assert(value.nominal_speed_raw == 0x8000 and value.nominal_speed_rpm == nil)
    local bad = parse(fixture.voltage .. Data.record(28, 19, 0x2801))
    assert(bad.partial and #bad.firmware_probes == 1)
    bad = parse(Data.record(26, 22, 0x2604, { [6] = Data.word(1), [8] = Data.word(2) }))
    assert(bad.partial and bad.firmware_probes[1].quality == "partial")
    -- A duplicate after the parser's retention cap still invalidates the
    -- original record rather than allowing a typed link to the retained one.
    bad = assert(SMBIOS.parse(fixture.voltage .. fixture.current .. fixture.voltage .. fixture.ending,
        nil, { max_firmware_probes = 1 }))
    assert(bad.truncated and bad.firmware_probes[1].ambiguous)
end

-- A later source failure keeps old declarations as context but withdraws
-- relationships. Untrusted export fields cannot leak raw/OEM/private data.
do
    local failed = Snapshot.merge(snapshot, { firmware_probes = { status = "denied", quality = "denied",
        timestamp_ns = 2, reason = "denied" } }, 2, 2)
    local rows = Hardware.build(failed)
    assert(rows.by_id["firmware-probe:2600"] and #rows.by_id[psu.id].firmware_probe_ids == 0)
    local untrusted = clone(snapshot)
    untrusted.firmware_probes.probes[1].serial_number = "PRIVATE-PROBE"
    untrusted.firmware_probes.probes[1].oem_data = "PRIVATE-OEM"
    untrusted.firmware_probes.cooling_devices[1].raw = "PRIVATE-COOLER"
    untrusted.firmware_probes._smbios_cohort.private = "PRIVATE-COHORT"
    local public, compact = Export.snapshot(untrusted), Export.agent(untrusted)
    assert(not JSON.encode(public):find("PRIVATE", 1, true) and not JSON.encode(compact):find("PRIVATE", 1, true))
    local many = clone(snapshot)
    for index = 5, 9 do
        local row = clone(many.firmware_probes.probes[1]); row.id = string.format("%04x", 0x2600 + index)
        row.handle = 0x2600 + index; many.firmware_probes.probes[index] = row
    end
    compact = Export.agent(many)
    assert(#compact.metrics.firmware_probes.probes == 5 and compact.metrics.firmware_probes.probes_total == 9)
    assert(compact.metrics.firmware_probes.truncated)
    package.path = "./tools/?.lua;" .. package.path
    local f = assert(io.open("docs/agent-v1.schema.json", "rb")); local body = f:read("a"); assert(f:close())
    local schema = assert(require("wtop.core.json").decode(body))
    assert(#require("agent_schema").validate(compact, schema) == 0)
    compact.metrics.firmware_probes.declarations_only = false
    assert(#require("agent_schema").validate(compact, schema) > 0)
end
print("firmware probes: ten-locale details, bounded Snapshot/Agent/report, stale links, private fields and declaration-only schema")

do
    local a = Data.record(27, 15, 0x2710, { [4] = Data.word(0xffff), [6] = "\99\7", [14] = "\1" }, { "Fan A" })
    local b = Data.record(27, 15, 0x2711, { [4] = Data.word(0xffff), [6] = "\99\7", [14] = "\1" }, { "Fan B" })
    local bytes = a .. b .. fixture.ending
    local r = Collector.new({ platform = "linux", fs = FS.new({ files = {
        ["/sys/firmware/dmi/tables/DMI"] = bytes,
        ["/sys/firmware/dmi/tables/smbios_entry_point"] = Data.entry_point(#bytes) } }) }):sample({})
    assert(r.status == "ok" and not r.data.partial)
    local rows = Hardware.build(Snapshot.merge(nil, { firmware_probes = r }, 1, 1))
    assert(rows.by_id["firmware-cooling:2710"].redundant_peer_ids[1] == "firmware-cooling:2711")
    assert(rows.by_id["firmware-cooling:2711"].redundant_peer_ids[1] == "firmware-cooling:2710")
    local lonely = assert(SMBIOS.parse(a .. fixture.ending))
    assert(lonely.partial and lonely.firmware_cooling[1].quality == "partial")
end
print("firmware cooling redundancy: complete declared groups only; no physical containment or health inference")

-- Independently scheduled views keep verified links across unchanged public
-- revisions. Private bytes are neither fingerprinted nor retained; public
-- changes and distinct providers withdraw links until both views agree.
do
    local data = Data.new()
    local filesystem = FS.new({ files = data.files })
    local read, reads = filesystem.read, 0
    function filesystem:read(path, ...)
        if path == "/sys/firmware/dmi/tables/DMI" then reads = reads + 1 end
        return read(self, path, ...)
    end
    local p = Collector.new({ platform = "linux", fs = filesystem })
    local s = Supplies.new({ platform = "linux", fs = filesystem })
    local supply_a, probe_a = s:sample({}), p:sample({})
    assert(reads == 2, "revision recognition must not suppress firmware reads")
    assert(supply_a.data._smbios_cohort == probe_a.data._smbios_cohort,
        "separate unchanged reads lost firmware relationships")
    local function graph_for(probe_result, supply_result)
        return Hardware.build(Snapshot.merge(nil, { firmware_probes = probe_result,
            firmware_power_supplies = supply_result }, 1, 1))
    end
    assert(#graph_for(probe_a, supply_a).by_id[psu.id].firmware_probe_ids == 2)
    local private_only = data.blob:gsub("PRIVATE%-UNUSED%-PROBE", "PRIVATE-UNUSED-OTHER")
        :gsub("PRIVATE%-SERIAL", "PRIVATE-SECRET")
    data.files["/sys/firmware/dmi/tables/DMI"] = private_only
    local same_public = p:sample({})
    assert(same_public.data._smbios_cohort == probe_a.data._smbios_cohort)
    local changed_voltage = data.voltage:sub(1, 20) .. Data.word(12100)
        .. data.voltage:sub(23)
    data.files["/sys/firmware/dmi/tables/DMI"] = changed_voltage .. data.blob:sub(#data.voltage + 1)
    local probe_b = p:sample({})
    assert(probe_b.data.probes[1].nominal_value == 12.1)
    assert(probe_b.data._smbios_cohort ~= supply_a.data._smbios_cohort)
    assert(#graph_for(probe_b, supply_a).by_id[psu.id].firmware_probe_ids == 0)
    local supply_b = s:sample({})
    assert(#graph_for(probe_b, supply_b).by_id[psu.id].firmware_probe_ids == 2)
    local other = Collector.new({ platform = "linux", fs = FS.new({ files = data.files }) }):sample({})
    assert(other.data._smbios_cohort ~= supply_b.data._smbios_cohort)
    assert(#graph_for(other, supply_b).by_id[psu.id].firmware_probe_ids == 0)
end
print("firmware revision links: unchanged public declarations persist; changed tables and provider boundaries withdraw links without private-byte fingerprints")

-- Unrelated semantic defects do not invalidate a complete, unambiguous
-- handle namespace. Structural truncation still withdraws every new link.
do
    local damaged_battery = Data.record(22, 26, 0x2200)
    local bytes = fixture.blob:sub(1, #fixture.blob - #fixture.ending) .. damaged_battery .. fixture.ending
    local files = { ["/sys/firmware/dmi/tables/DMI"] = bytes,
        ["/sys/firmware/dmi/tables/smbios_entry_point"] = Data.entry_point(#bytes) }
    local filesystem = FS.new({ files = files })
    local p, s = Collector.new({ platform = "linux", fs = filesystem }), Supplies.new({ platform = "linux", fs = filesystem })
    local pr, sr = p:sample({}), s:sample({})
    assert(pr.data.partial and pr.data._handles_complete and sr.data._handles_complete)
    local rows = Hardware.build(Snapshot.merge(nil, { firmware_probes = pr, firmware_power_supplies = sr }, 1, 1))
    assert(#rows.by_id[psu.id].firmware_probe_ids == 2 and #rows.by_id[fan.id].firmware_probe_ids == 1)
    bytes = bytes:sub(1, #bytes - #fixture.ending)
    files["/sys/firmware/dmi/tables/DMI"] = bytes
    files["/sys/firmware/dmi/tables/smbios_entry_point"] = Data.entry_point(#bytes)
    pr, sr = p:sample({}), s:sample({})
    assert(pr.data.partial and pr.data._handles_complete == false)
    rows = Hardware.build(Snapshot.merge(nil, { firmware_probes = pr, firmware_power_supplies = sr }, 1, 1))
    assert(#rows.by_id[psu.id].firmware_probe_ids == 0 and #rows.by_id[fan.id].firmware_probe_ids == 0)
end
print("firmware handle integrity: unrelated attribute errors preserve typed links; incomplete namespaces withdraw them")
