package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Data = require("support.platform_firmware")
local Fixture = require("support.fixture_fs")
local SMBIOS = require("wtop.format.smbios")
local Collector = require("wtop.collectors.platform_firmware")
local Snapshot = require("wtop.model.snapshot")
local Hardware = require("wtop.model.hardware")
local Export = require("wtop.export")
local Report = require("wtop.report")
local I18n = require("wtop.i18n")
local TUI = require("wtop.tui")
local ViewModel = require("wtop.view_model")
local JSON = require("wtop.format.json")
local d = Data.new()
local function parse(data, options) return assert(SMBIOS.parse(data .. d.ending, nil, options)) end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local parsed = assert(SMBIOS.parse(d.blob))
assert(not parsed.partial and #parsed.platform_firmwares == 2 and #parsed.firmware_systems == 2)
local bios, old = parsed.platform_firmwares[1], parsed.platform_firmwares[2]
assert(bios.vendor == "Example BIOS" and bios.version == "FIXTURE-UEFI" and bios.release_date == "03/04/2024")
assert(bios.rom_size_bytes == 32 * 1024 * 1024 and bios.rom_size_minimum_bytes == 16 * 1024 * 1024)
assert(bios.runtime_segment == 0xe800 and bios.runtime_area_bytes == 98304)
assert(bios.characteristics_known and bios.characteristics_hex == "0x00038880" and bios.vendor_characteristics_present)
assert(bios.features.pci and bios.features.upgradeable and bios.features.rom_socketed and bios.features.acpi)
assert(bios.features.usb_legacy and bios.features.uefi and bios.features.bios_boot_spec == false)
assert(bios.virtual_machine_reported and bios.manufacturing_mode_supported and bios.manufacturing_mode_enabled)
assert(bios.firmware_revision == "2.7" and bios.controller_revision == "1.9")
assert(old.rom_size_bytes == 8 * 1024 * 1024 and old.release_date == "12/31/99")
assert(old.characteristics_known == false and old.features.pci == nil and old.features.acpi == nil)
assert(old.virtual_machine_reported == nil and old.controller_revision == nil and old.runtime_area_bytes == nil)
local system, legacy = parsed.firmware_systems[1], parsed.firmware_systems[2]
assert(system.product == "Fixture Platform" and system.manufacturer == "Example Systems")
assert(system.serial_present and system.uuid_present and system.wake_type == "Power switch")
assert(system.sku == "SKU-BASE" and system.family == "Platform Family")
assert(legacy.uuid_present == nil and legacy.wake_type == nil and legacy.family == nil)
local encoded = JSON.encode(parsed)
assert(not encoded:find("PRIVATE", 1, true) and not encoded:find("OEM!", 1, true))

local fs = Fixture.new({ files = d.files })
local collector = Collector.new({ platform = "linux", fs = fs })
local result = collector:sample({})
assert(result.status == "ok" and result.quality == "fresh" and collector:probe({}).available)
local results = { platform_firmware = result }
for _, name in ipairs({ "firmware_enclosures", "processor_firmware", "firmware_components" }) do
    results[name] = require("wtop.collectors." .. name).new({ platform = "linux", fs = fs }):sample({})
end
local state = Snapshot.merge(nil, results, 1, 1)
local graph = Hardware.build(state)
local platform, machine = graph.by_id["platform-firmware:0000"], graph.by_id["firmware-system:0100"]
assert(platform and platform.kind == "platform_firmware" and platform.parent_id == nil)
assert(machine and machine.kind == "firmware_system" and machine.parent_id == nil)
assert(platform.baseboard_ids[1] == "baseboard:0200" and machine.baseboard_ids[1] == "baseboard:0200")
assert(#platform.firmware_component_ids == 1 and #machine.firmware_component_ids == 1)
local destinations = {}
for _, item in ipairs(Hardware.related(graph, platform.id).items) do destinations[item.id] = true end
assert(destinations["baseboard:0200"] and destinations["firmware-component:4500"])
for _, change in ipairs({
    function(s) s.quality.platform_firmware.quality = "stale" end,
    function(s) s.platform_firmware.truncated = true end,
    function(s) s.platform_firmware.firmwares[1].ambiguous = true end,
    function(s) s.platform_firmware.firmwares[1].quality = "partial" end,
}) do
    local s = copy(state); change(s)
    local g = Hardware.build(s)
    assert(#g.by_id[platform.id].baseboard_ids == 0)
end
local exported = Export.snapshot(state)
assert(exported.platform_firmware.firmwares[1].rom_size_bytes == 33554432)
assert(exported.platform_firmware.firmwares[1].features.bios_boot_spec == false)
assert(exported.platform_firmware.systems[1].uuid_present and exported.platform_firmware.systems[2].uuid_present == nil)
local agent = Export.agent(state)
assert(agent.metrics.platform_firmware.firmwares[1].features.uefi)
assert(agent.overall.signal_count == 0, "firmware declarations are not current boot/security/health observations")
local report = Report.render(exported)
assert(report:find("Platform firmware", 1, true) and report:find("32.00 MiB", 1, true))
assert(report:find("Firmware system declarations", 1, true) and report:find("SKU-BASE", 1, true))
assert(report:find("not the current boot method or Secure Boot state", 1, true))
for _, value in ipairs({ encoded, JSON.encode(exported), JSON.encode(agent), report }) do
    assert(not value:find("PRIVATE", 1, true) and not value:find("OEM!", 1, true))
end
local malicious = copy(state)
malicious.platform_firmware.systems[1].uuid = "PRIVATE-UUID"
malicious.platform_firmware.systems[1].serial_number = "PRIVATE-SERIAL"
malicious.platform_firmware.firmwares[1].vendor_characteristics = "PRIVATE-OEM"
malicious.platform_firmware.firmwares[1].features.secret = "PRIVATE-FLAG"
malicious.platform_firmware.firmwares[1].features.pci = "PRIVATE-FLAG"
assert(not JSON.encode(Export.snapshot(malicious)):find("PRIVATE", 1, true))
assert(not JSON.encode(Export.agent(malicious)):find("PRIVATE", 1, true))

for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
    local i18n = assert(I18n.new({ locale = locale }))
    for _, key in ipairs({ "firmware_platform.note", "firmware_platform.vm_note", "firmware_platform.system_note",
        "reason.no_platform_firmware", "reason.platform_firmware_incomplete" }) do assert(i18n:has(key)) end
    local text = table.concat(TUI.hardware_detail_lines(state, platform.id, i18n), "\n")
    assert(text:find("FIXTURE-UEFI", 1, true) and text:find("32", 1, true) and text:find("MiB", 1, true))
    assert(text:find(i18n:t("firmware_platform.note"), 1, true) and text:find(i18n:t("firmware_platform.vm_note"), 1, true))
    local model = ViewModel.build({ history_values = function() return {} end }, state, i18n, {}, "system", nil, nil,
        { system_query = "vendor:BIOS name:FIXTURE" }).system_devices
    assert(#model.rows == 1 and model.ids[1] == platform.id)
    local system_text = table.concat(TUI.hardware_detail_lines(state, machine.id, i18n), "\n")
    assert(system_text:find("Platform Family", 1, true) and system_text:find("SKU-BASE", 1, true))
    assert(not (text .. system_text):find("PRIVATE", 1, true))
end

-- Positive and malformed sizes must stay exact on both 32-bit and 64-bit hosts.
local gib = parse(Data.put(d.bios, 24, Data.word(0x4030))).platform_firmwares[1]
assert(gib.rom_size_bytes == 48 * 1024 * 1024 * 1024)
for _, raw in ipairs({ 0, 8, 0x8001, 0xc001 }) do
    local bad = parse(Data.put(d.bios, 24, Data.word(raw)))
    assert(bad.partial and bad.platform_firmwares[1].rom_size_bytes == nil)
    assert(bad.platform_firmwares[1].rom_size_minimum_bytes == 16 * 1024 * 1024)
end
local lower_bound = parse(Data.put(d.old_bios, 9, "\255")).platform_firmwares[1]
assert(lower_bound.rom_size_bytes == nil and lower_bound.rom_size_minimum_bytes == 16777216)
local old_size = parse(Data.put(d.bios, 9, "\0")).platform_firmwares[1]
assert(old_size.rom_size_bytes == 65536 and old_size.rom_size_minimum_bytes == nil)
local no_segment = parse(Data.put(d.bios, 6, Data.word(0))).platform_firmwares[1]
assert(no_segment.runtime_area_bytes == nil and no_segment.runtime_segment == nil)
local unknown_revisions = parse(Data.put(d.bios, 20, "\255\255\1\255")).platform_firmwares[1]
assert(unknown_revisions.firmware_revision == nil and unknown_revisions.controller_revision == nil)
local high_vendor = parse(Data.put(d.bios, 14, string.rep("\255", 4)))
assert(not high_vendor.partial and high_vendor.platform_firmwares[1].vendor_characteristics_present)
assert(high_vendor.platform_firmwares[1].features.pci)
local unknown = parse(Data.put(d.bios, 10, string.pack("<I4", 0x84))).platform_firmwares[1]
assert(unknown.characteristics_known == false and unknown.features.pci == nil and unknown.features.acpi)
local reserved = parse(Data.put(d.bios, 19, "\128"))
assert(reserved.partial and reserved.platform_firmwares[1].features.uefi == false)
local reserved_low = parse(Data.put(d.bios, 10, string.pack("<I4", 0x81)))
assert(reserved_low.partial and reserved_low.platform_firmwares[1].features.pci)
for _, fill in ipairs({ "\0", "\255" }) do
    local system = parse(Data.put(d.system, 8, string.rep(fill, 16))).firmware_systems[1]
    assert(system.uuid_present == false and system.product == "Fixture Platform")
end
local unknown_wake = parse(Data.put(d.system, 24, "\254")).firmware_systems[1]
assert(unknown_wake.wake_type == nil and unknown_wake.wake_type_code == 254)
local bad_string = parse(Data.put(d.bios, 4, "\250"))
assert(bad_string.partial and bad_string.platform_firmwares[1].vendor == nil)
for kind, minimum in pairs({ [0] = 18, [1] = 8 }) do
    for length = 4, 255 do
        local value, reason = SMBIOS.parse(Data.record(kind, length, 0x0900) .. d.ending)
        if length < minimum then assert(not value and reason == "smbios_invalid")
        else assert(value and #value[kind == 0 and "platform_firmwares" or "firmware_systems"] == 1) end
    end
end
local duplicate = parse(d.bios .. d.bios)
assert(duplicate.partial and duplicate.platform_firmwares[1].ambiguous and duplicate.platform_firmwares[2].ambiguous)
local capped = assert(SMBIOS.parse(d.blob, nil, { max_platform_firmwares = 1, max_firmware_systems = 1 }))
assert(capped.truncated and #capped.platform_firmwares == 1 and #capped.firmware_systems == 1)
local base = "/sys/firmware/dmi/tables"
local empty = Collector.new({ platform = "linux", fs = Fixture.new({ files = {
    [base .. "/DMI"] = d.ending, [base .. "/smbios_entry_point"] = Data.entry_point(#d.ending) } }) }):sample({})
assert(empty.status == "unavailable" and empty.reason == "no_platform_firmware")
local denied = Collector.new({ platform = "linux", fs = Fixture.new({ denied = { [base .. "/DMI"] = true } }) })
assert(denied:sample({}).status == "denied" and denied:probe({}).state == "denied")
for _, platform in ipairs({ "windows", "macos" }) do
    local calls = 0
    local all = require("wtop.collectors").new_all({ platform = platform, common = { native = {
        read_smbios = function() calls = calls + 1; return { data = d.blob, major = 3, minor = 9 } end } } })
    local ctx = { _collector_batch = {} }
    local value = all.platform_firmware:sample(ctx)
    assert(value.status == "ok" and value.data.firmwares[1].rom_size_bytes == 33554432)
    assert(all.firmware_enclosures:sample(ctx).data.baseboards[1].product == "Fixture Mainboard" and calls == 1)
    value.data.firmwares[1].features.pci = false
    assert(all.platform_firmware:sample(ctx).data.firmwares[1].features.pci and calls == 1)
end
assert(require("wtop.collectors.smbios_worker").sources.platform_firmware)
local many = copy(state);many.platform_firmware.firmwares = {}
for n = 1, 16 do
    local firmware = copy(bios);firmware.id = string.format("%04x", 0x1000 + n);firmware.handle = 0x1000 + n
    many.platform_firmware.firmwares[n] = firmware
end
local bounded = Export.agent(many).metrics.platform_firmware
assert(#bounded.firmwares == 5 and bounded.firmwares_total == 16 and bounded.truncated)
print("ok: Type0/1 firmware ROM units/lower bounds, legacy records, support semantics, private UUID/OEM fields, explicit links and portable UI/exports")
