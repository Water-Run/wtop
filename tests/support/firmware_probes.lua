local Records = require("support.firmware_enclosures")
local M = { record = Records.record, word = Records.word, entry_point = Records.entry_point }
local function w(value) return M.word(value % 65536) end
function M.new()
    local r = {}
    r.voltage = M.record(26, 22, 0x2600, { [4] = "\1\106", [6] = w(12500), [8] = w(-12500),
        [10] = w(25), [12] = w(50), [14] = w(125), [16] = string.pack("<I4", 0x91aadeef), [20] = w(12000) },
        { "Input rail", "PRIVATE-UNUSED-PROBE" })
    r.temperature = M.record(28, 22, 0x2800, { [4] = "\1\172", [6] = w(1050), [8] = w(-400),
        [10] = w(125), [12] = w(15), [14] = w(50), [20] = w(-55) }, { "Inlet probe" })
    r.current = M.record(29, 22, 0x2900, { [4] = "\1\138", [6] = w(5000), [8] = w(-2000),
        [10] = w(10), [12] = w(100), [14] = w(0x8000), [20] = w(2500) }, { "Input current" })
    r.cooling = M.record(27, 15, 0x2700, { [4] = w(0x2800), [6] = "\103\0",
        [8] = string.pack("<I4", 0x91aadeef), [12] = w(1600), [14] = "\1" }, { "PSU fan" })
    r.legacy_probe = M.record(26, 20, 0x2601, { [4] = "\0\66", [6] = w(0x8000), [8] = w(0x8000),
        [10] = w(0x8000), [12] = w(0x8000), [14] = w(0x8000) })
    r.legacy_cooling = M.record(27, 12, 0x2701, { [4] = w(0xffff), [6] = "\81\0" })
    r.supply = M.record(39, 22, 0x3900, { [4] = "\0\1\2\3\4\5\6\7", [12] = w(750),
        [14] = w((4 << 10) | (3 << 7) | (4 << 3) | 2),
        [16] = w(0x2600), [18] = w(0x2700), [20] = w(0x2900) },
        { "Supply bay", "Main supply", "Example Vendor", "PRIVATE-SERIAL", "PRIVATE-ASSET", "Model", "R1" })
    r.ending = M.record(127, 4, 0xffff)
    r.blob = r.voltage .. r.temperature .. r.current .. r.cooling .. r.legacy_probe .. r.legacy_cooling .. r.supply .. r.ending
    r.files = { ["/sys/firmware/dmi/tables/DMI"] = r.blob,
        ["/sys/firmware/dmi/tables/smbios_entry_point"] = M.entry_point(#r.blob) }
    return r
end
return M
