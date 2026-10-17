-- Windows storage descriptors and standard NVMe health pages. ATA raw
-- attributes stay vendor-specific; their IDs alone do not define a unit.
local M = {}

local function temperature(value)
    if value ~= -32768 and value > -200 and value < 1000 then return value end
end

function M.temperatures(bytes)
    if type(bytes) ~= "string" or #bytes < 24 or #bytes > 536 then return nil end
    local version, size, critical, warning, count = string.unpack("<I4I4i2i2I2", bytes)
    if version ~= 40 or size < 24 or size > #bytes or count > 32
        or count > (size - 24) // 16 then return nil end
    local result = { channels = {}, critical_celsius = temperature(critical),
        warning_celsius = temperature(warning) }
    local seen = {}
    for i = 1, count do
        local index, input, over, under = string.unpack("<I2i2i2i2", bytes, 25 + (i - 1) * 16)
        if seen[index] then return nil end
        seen[index] = true
        result.channels[#result.channels + 1] = {
            id = "temperature:" .. index, type = "temperature", unit = "celsius",
            index = index, label = index == 0 and "Composite" or "Sensor " .. index,
            input = temperature(input), quality = temperature(input) and "fresh" or "unavailable",
            -- The descriptor's device limits belong to the composite reading.
            -- Individual sensors retain their own over/under thresholds below.
            thresholds = { crit = index == 0 and temperature(critical) or nil,
                max = index == 0 and temperature(warning) or nil },
            over_threshold_celsius = temperature(over), under_threshold_celsius = temperature(under),
            source = "StorageDeviceTemperatureProperty",
        }
    end
    return result
end

M.nvme = require("wtop.format.nvme_health").parse

function M.ata(bytes)
    if type(bytes) ~= "string" or #bytes ~= 512 then return nil end
    local sum = 0
    for i = 1, #bytes do sum = sum + bytes:byte(i) end
    if sum % 256 ~= 0 then return nil end
    local version = string.unpack("<I2", bytes)
    if version == 0 or version == 65535 then return nil end
    local result, seen = { version = version, attributes = {}, source = "SMART READ DATA" }, {}
    for i = 0, 29 do
        local at = 3 + i * 12
        local id = bytes:byte(at)
        if id ~= 0 then
            if seen[id] then return nil end
            seen[id] = true
            local raw = {}
            for j = at + 10, at + 5, -1 do raw[#raw + 1] = string.format("%02x", bytes:byte(j)) end
            result.attributes[#result.attributes + 1] = {
                id = id, flags = string.unpack("<I2", bytes, at + 1),
                current = bytes:byte(at + 3), worst = bytes:byte(at + 4),
                raw_hex = table.concat(raw),
            }
        end
    end
    return result
end

return M
