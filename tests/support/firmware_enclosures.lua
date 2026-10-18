-- Public specification fields with deliberately private serial/asset strings.
local M = {}
function M.put(data, offset, value)
    return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
end
function M.word(value) return string.pack("<I2", value) end
function M.record(kind, length, handle, fields, strings)
    local data = string.pack("<BBI2", kind, length, handle) .. string.rep("\0", length - 4)
    for offset, value in pairs(fields or {}) do
        assert(offset >= 4 and offset + #value <= length)
        data = M.put(data, offset, value)
    end
    return data .. table.concat(strings or {}, "\0") .. "\0\0"
end
function M.entry_point(maximum)
    local data = "_SM3_\0\24\3\9\0\1\0" .. string.pack("<I4I8", maximum, 0)
    local checksum = 0
    for index = 1, #data do checksum = (checksum + data:byte(index)) % 256 end
    return M.put(data, 5, string.char((-checksum) % 256))
end
function M.new()
    local records = {}
    records.board = M.record(2, 19, 0x0200, {
        [4] = "\1\2\3\4\5\31\6", [11] = M.word(0x0300), [13] = "\10\2",
        [15] = M.word(0x0400) .. M.word(0x0201),
    }, { "Example Boards", "Fixture Mainboard", "Rev 2", "PRIVATE-BOARD-SERIAL",
         "PRIVATE-BOARD-ASSET", "Main tray" })
    records.module = M.record(2, 15, 0x0201, {
        [4] = "\1\2", [11] = M.word(0x0300), [13] = "\9\0",
    }, { "Example Boards", "Fixture Daughterboard" })
    records.chassis = M.record(3, 27, 0x0300, {
        [4] = "\1\151\2\3\4\3\4\5\4", [13] = string.pack("<I4", 0xabcdef12),
        [17] = "\255\2\1\3", [21] = "\145\1\8", [24] = "\5\1\2",
    }, { "Example Enclosures", "Rev C", "PRIVATE-CHASSIS-SERIAL", "PRIVATE-CHASSIS-ASSET", "RACK-SKU" })
    records.old_board = M.record(2, 8, 0x0202, { [4] = "\1\2\3\4" },
        { "Legacy Vendor", "Legacy Board", "Legacy Rev", "PRIVATE-LEGACY-SERIAL" })
    records.old_chassis = M.record(3, 9, 0x0301, { [4] = "\1\9\2\3\4" },
        { "Legacy Enclosures", "Rev A", "PRIVATE-OLD-SERIAL", "PRIVATE-OLD-ASSET" })
    records.processor = M.record(4, 26, 0x0400, { [4] = "\1\3\1\2", [16] = "\3", [24] = "\65\1" },
        { "CPU Socket", "Example CPU", "CPU Model" })
    records.component = M.record(45, 28, 0x4500, { [4] = "\1\2", [22] = "\4\2",
        [24] = M.word(0x0200) .. M.word(0x0300) }, { "Board Firmware", "1.0" })
    records.ending = M.record(127, 4, 0xffff)
    records.blob = records.board .. records.module .. records.chassis .. records.old_board
        .. records.old_chassis .. records.processor .. records.component .. records.ending
    records.files = { ["/sys/firmware/dmi/tables/DMI"] = records.blob,
        ["/sys/firmware/dmi/tables/smbios_entry_point"] = M.entry_point(#records.blob) }
    return records
end
return M
