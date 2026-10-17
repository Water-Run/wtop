-- Standard 512-byte NVMe SMART/Health log, shared by native backends.
local M = {}

local function temperature(value)
    if value ~= -32768 and value > -200 and value < 1000 then return value end
end

local function decimal128(bytes, offset)
    -- Decimal strings preserve the full 128-bit counter on both Lua ABIs.
    local digits = { 0 }
    for i = offset + 15, offset, -1 do
        local carry = bytes:byte(i)
        for j = 1, #digits do
            local value = digits[j] * 256 + carry
            digits[j], carry = value % 10, value // 10
        end
        while carry > 0 do digits[#digits + 1], carry = carry % 10, carry // 10 end
    end
    local result = {}
    for i = #digits, 1, -1 do result[#result + 1] = tostring(digits[i]) end
    return table.concat(result)
end

function M.parse(bytes)
    if type(bytes) ~= "string" or #bytes ~= 512 then return nil end
    local kelvin = string.unpack("<I2", bytes, 2)
    local result = {
        critical_warning = bytes:byte(1), available_spare_percent = bytes:byte(4),
        available_spare_threshold_percent = bytes:byte(5), percentage_used = bytes:byte(6),
        data_unit_bytes = 512000, data_units_rounded_up = true,
        percentage_used_lower_bound = bytes:byte(6) == 255,
        temperature_celsius = kelvin ~= 0 and kelvin ~= 65535 and temperature(kelvin - 273.15) or nil,
        source = "NVMe SMART/Health Information Log",
    }
    if result.available_spare_percent > 100 then result.available_spare_percent = nil end
    if result.available_spare_threshold_percent > 100 then result.available_spare_threshold_percent = nil end
    -- Percentage Used may exceed 100; 255 means 255 or more, not absence.
    local names = { "data_units_read", "data_units_written", "host_read_commands",
        "host_write_commands", "controller_busy_minutes", "power_cycles", "power_on_hours",
        "unsafe_shutdowns", "media_errors", "error_log_entries" }
    for i, name in ipairs(names) do result[name] = decimal128(bytes, 33 + (i - 1) * 16) end
    return result
end


return M
