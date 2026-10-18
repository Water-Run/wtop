local D = require("support.firmware_enclosures")
local M = { put = D.put, record = D.record, word = D.word, entry_point = D.entry_point }
function M.new()
    local data = D.new()
    data.bios = D.record(0, 26, 0, { [4] = "\1\2", [6] = D.word(0xe800), [8] = "\3\255",
        [10] = string.pack("<I4", 0x38880) .. "OEM!", [18] = "\3\120",
        [20] = "\2\7\1\9", [24] = D.word(32) }, { "Example BIOS", "FIXTURE-UEFI", "03/04/2024" })
    data.old_bios = D.record(0, 18, 1, { [4] = "\1\2", [8] = "\3\127", [10] = string.pack("<I4", 0x88) },
        { "Legacy BIOS", "LEGACY-ROM", "12/31/99" })
    data.system = D.record(1, 27, 0x0100, { [4] = "\1\2\3\4", [8] = "PRIVATE-UUID-XYZ",
        [24] = "\6\5\6" }, { "Example Systems", "Fixture Platform", "Model Rev 3", "PRIVATE-SYSTEM-SERIAL", "SKU-BASE", "Platform Family" })
    data.old_system = D.record(1, 8, 0x0101, { [4] = "\1\2\3\4" },
        { "Legacy Systems", "Legacy Platform", "v1", "PRIVATE-OLD-SYSTEM-SERIAL" })
    data.board = D.put(data.board, 15, D.word(0) .. D.word(0x0100))
    data.component = D.put(data.component, 24, D.word(0) .. D.word(0x0100))
    data.blob = data.bios .. data.old_bios .. data.system .. data.old_system .. data.board .. data.module
        .. data.chassis .. data.old_board .. data.old_chassis .. data.processor .. data.component .. data.ending
    data.files = { ["/sys/firmware/dmi/tables/DMI"] = data.blob,
        ["/sys/firmware/dmi/tables/smbios_entry_point"] = D.entry_point(#data.blob) }
    return data
end
return M
