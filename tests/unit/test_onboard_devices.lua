package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local SMBIOS = require("wtop.format.smbios")
local OnboardDevices = require("wtop.collectors.onboard_devices")
local Fixture = require("support.fixture_fs")
local Snapshot = require("wtop.model.snapshot")
local Hardware = require("wtop.model.hardware")
local ViewModel = require("wtop.view_model")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Export = require("wtop.export")
local JSON = require("wtop.format.json")
local Report = require("wtop.report")

local function record(kind, handle, fields, strings)
    return string.pack("<BBI2", kind, 4 + #fields, handle) .. fields
        .. table.concat(strings or {}, "\0") .. "\0\0"
end

local function entry3(maximum)
    local entry = "_SM3_\0\24\3\9\0\1\0" .. string.pack("<I4I8", maximum, 0)
    local sum = 0
    for index = 1, #entry do sum = (sum + entry:byte(index)) % 256 end
    return entry:sub(1, 5) .. string.char((-sum) % 256) .. entry:sub(7)
end

local ending = record(127, 0xffff, "")
local legacy = record(10, 0x1000, "\133\1\7\2\140\0",
    { "LAN_ONBOARD", "Sound", "PRIVATE-UNUSED-STRING" })
local singleton = record(10, 0x1001, "\137\1", { "SATA" })
local extended = record(41, 0x4100, "\1\133\1\0\0\2\0", { "LAN_ONBOARD" })
local blob = legacy .. singleton .. extended .. ending
local parsed = assert(SMBIOS.parse(blob, assert(SMBIOS.entry_point(entry3(#blob)))))
assert(not parsed.partial and not parsed.truncated and #parsed.onboard_devices == 5)
local devices = parsed.onboard_devices
assert(devices[1].id == "1000:1" and devices[2].id == "1000:2"
    and devices[3].id == "1000:3" and devices[4].id == "1001:1")
assert(devices[1].handle == 0x1000 and devices[1].device_index == 1
    and devices[1].device_count == 3 and devices[1].structure_type == 10)
assert(devices[1].designation == "LAN_ONBOARD" and devices[1].device_type == "Ethernet"
    and devices[1].enabled == true and devices[1].pci_bdf == nil
    and devices[1].type_instance == nil)
assert(devices[2].device_type == "Sound" and devices[2].enabled == false)
assert(devices[3].device_type_code == 12 and devices[3].device_type == nil
    and devices[3].designation == nil and devices[3].enabled == true,
    "Type 10 cannot borrow newer Type 41 enum values or unreferenced strings")
assert(devices[5].id == "4100" and devices[5].structure_type == 41
    and devices[5].type_instance == 1 and devices[5].pci_bdf == "0000:02:00.0")

local base = "/sys/firmware/dmi/tables"
local fs = Fixture.new({ files = {
    [base .. "/DMI"] = blob, [base .. "/smbios_entry_point"] = entry3(#blob),
} })
local collector = OnboardDevices.new({ fs = fs, platform = "linux" })
local sample = collector:sample({})
assert(collector:probe({}).available and sample.status == "ok" and sample.quality == "fresh")
assert(sample.data.devices[1].source == base .. "/DMI#1000:1")
local state = Snapshot.merge(nil, { onboard_devices = sample, inventory = {
    status = "ok", quality = "fresh", data = { pci = { devices = {
        { address = "0000:02:00.0", device_name = "LAN_ONBOARD" },
    } } },
} }, 1000000000)
local graph = Hardware.build(state)
assert(graph.by_id["onboard:1000:1"] and graph.by_id["onboard:1000:2"]
    and graph.by_id["onboard:4100"])
assert(#graph.by_id["onboard:1000:1"].pci_ids == 0
    and #graph.by_id["onboard:1000:2"].pci_ids == 0,
    "a legacy firmware description is not an operating-system device identity")
assert(#graph.by_id["pci:0000:02:00.0"].onboard_ids == 1
    and graph.by_id["pci:0000:02:00.0"].onboard_ids[1] == "onboard:4100",
    "coexisting Type 10 and 41 records keep their own identities")
local english = I18n.new({ lang = "en-US" })
local model = ViewModel.build({ history_values = function() return {} end },
    state, english, {}, "system", nil, nil,
    { system_query = "bus:firmware name:LAN_ONBOARD" }).system_devices
assert(#model.rows == 2, "System search must expose both firmware declarations")
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "fr-FR", "ru-RU",
    "de-DE", "es-ES", "ja-JP", "ko-KR", "pt-BR" }) do
    local i18n = I18n.new({ lang = locale })
    local details = table.concat(TUI.hardware_detail_lines(state, "onboard:1000:1", i18n), "\n")
    for _, key in ipairs({ "onboard.structure_type", "onboard.entry", "onboard.legacy_note" }) do
        local label = i18n:t(key)
        assert(label ~= key and details:find(label, 1, true), locale .. " lacks " .. key)
    end
    assert(details:find("LAN_ONBOARD", 1, true) and details:find("Ethernet", 1, true))
    assert(not details:find(i18n:t("slot.firmware_address"), 1, true),
        "a Type 10 detail must not invent a PCI address field")
end
local exported = Export.snapshot(state)
assert(exported.onboard_devices.devices[1].structure_type == 10
    and exported.onboard_devices.devices[1].device_index == 1
    and exported.onboard_devices.devices[1].device_count == 3)
assert(exported.onboard_devices.devices[5].structure_type == 41)
assert(not JSON.encode(exported):find("PRIVATE", 1, true))
local report = Report.render(exported)
assert(report:find("| LAN_ONBOARD | 10 | Ethernet | yes | — |", 1, true)
    and report:find("| LAN_ONBOARD | 41 | Ethernet | yes | 0000:02:00.0 |", 1, true))
assert(not report:find("PRIVATE", 1, true))

-- The native SMBIOS reader feeds the same decoder on Windows.
local native = { read_smbios = function() return { data = blob, major = 3, minor = 9 } end }
local windows = require("wtop.collectors.portable").new_all({ platform = "windows",
    common = { native = native } }).onboard_devices:sample({})
assert(windows.status == "ok" and windows.quality == "fresh"
    and windows.data.devices[1].id == "1000:1"
    and windows.data.devices[5].structure_type == 41)

-- A repeated structure handle taints every retained member, including both
-- directions when the other occurrence uses Type 41.
for _, repeated in ipairs({ legacy .. legacy,
    legacy .. record(41, 0x1000, "\1\133\1\0\0\2\0", { "LAN" }),
    record(41, 0x1000, "\1\133\1\0\0\2\0", { "LAN" }) .. legacy }) do
    local duplicate = assert(SMBIOS.parse(repeated .. ending))
    assert(duplicate.partial)
    for _, device in ipairs(duplicate.onboard_devices) do
        assert(device.ambiguous == true and device.quality == "partial")
    end
end

-- Keep complete pairs from odd-length records, and mark them as partial.
local odd = assert(SMBIOS.parse(record(10, 0x1010, "\133\1\255", { "LAN" }) .. ending))
assert(odd.partial and #odd.onboard_devices == 1
    and odd.onboard_devices[1].quality == "partial")
local bad_index = assert(SMBIOS.parse(record(10, 0x1011, "\133\2\135\1", { "Sound" }) .. ending))
assert(bad_index.partial and bad_index.onboard_devices[1].designation == nil
    and bad_index.onboard_devices[1].quality == "partial"
    and bad_index.onboard_devices[2].quality == "fresh")
assert(SMBIOS.parse(record(10, 0x1012, "\133") .. ending) == nil)
local empty = OnboardDevices.new({ platform = "windows", native = {
    read_smbios = function() return { data = record(10, 0x1013, "") .. ending } end,
} }):sample({})
assert(empty.status == "unavailable" and empty.reason == "no_onboard_devices")

-- The shared 128-entry cap counts devices, not just Type 10 structures.
local many = record(10, 0x1020, string.rep("\133\1", 125), { "LAN" })
    .. record(10, 0x1021, string.rep("\135\1", 4), { "Sound" }) .. extended .. ending
local bounded = assert(SMBIOS.parse(many))
assert(bounded.partial and bounded.truncated and #bounded.onboard_devices == 128)
assert(bounded.onboard_devices[128].id == "1021:3")
local clipped = assert(SMBIOS.parse(blob, nil, { max_onboard = 1 }))
assert(clipped.truncated and clipped.partial and #clipped.onboard_devices == 1
    and clipped.onboard_devices[1].device_count == 3)

-- Type 45 references structures. A multi-device Type 10 handle cannot
-- select one arbitrary member, even if a bound hid its other members.
local function component(handles)
    local fields = "\1\0\2\0\0\0\0\0" .. string.rep("\255", 8)
        .. "\0\0\4" .. string.char(#handles)
    for _, handle in ipairs(handles) do fields = fields .. string.pack("<I2", handle) end
    return record(45, 0x4500, fields, { "Board firmware" })
end
local function associated_graph(data, options)
    local value = assert(SMBIOS.parse(data .. ending, nil, options))
    return Hardware.build({
        onboard_devices = { devices = value.onboard_devices, truncated = value.truncated },
        firmware_components = { components = value.firmware_components },
    })
end
local multi = associated_graph(legacy .. component({ 0x1000 }))
assert(#multi.by_id["firmware-component:4500"].associated_ids == 0)
local one = associated_graph(singleton .. component({ 0x1001 }))
assert(one.by_id["firmware-component:4500"].associated_ids[1] == "onboard:1001:1")
local cut = associated_graph(legacy .. component({ 0x1000 }), { max_onboard = 1 })
assert(#cut.by_id["firmware-component:4500"].associated_ids == 0)
local cut_single = associated_graph(singleton .. legacy .. component({ 0x1001 }), { max_onboard = 1 })
assert(#cut_single.by_id["firmware-component:4500"].associated_ids == 0)
local damaged = associated_graph(record(10, 0x1010, "\133\1\255", { "LAN" })
    .. component({ 0x1010 }))
assert(#damaged.by_id["firmware-component:4500"].associated_ids == 0)

print("ok: legacy and extended onboard declarations, bounds, identity, navigation and exports")
