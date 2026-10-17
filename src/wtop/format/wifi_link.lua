-- nl80211 UAPI attributes are native-endian, four-byte aligned records.
-- This decoder runs after the native reader verifies the interface and BSS
-- identities. PHY bitrates and last-received signal are driver reports, not
-- measured throughput or a guarantee of usable link capacity.
local M = {}
local function valid(condition) if not condition then error("invalid_wifi_data", 0) end end
local function attributes(bytes)
    valid(type(bytes) == "string" and #bytes <= 8192)
    local result, entries, offset = {}, {}, 1
    while offset <= #bytes do
        valid(#bytes - offset + 1 >= 4)
        local length, kind = string.unpack("=I2I2", bytes, offset)
        valid(length >= 4 and offset + ((length + 3) & ~3) - 1 <= #bytes)
        local key = kind & 0x3fff
        local row = { bytes = bytes:sub(offset + 4, offset + length - 1), network_order = kind & 0x4000 ~= 0 }
        if result[key] ~= nil then result[key] = false else result[key] = row end
        entries[#entries + 1] = row
        offset = offset + ((length + 3) & ~3)
    end
    return result, entries
end
local function field(rows, key, size)
    local row = rows[key]
    if row == nil then return nil end
    valid(row ~= false and not row.network_order and (size == nil or #row.bytes == size))
    return row.bytes
end
local function integer(rows, key, size, signed)
    local bytes = field(rows, key, size)
    if bytes == nil then return nil end
    return (string.unpack("=" .. (signed and "i" or "I") .. size, bytes))
end
local function flag(rows, key)
    return field(rows, key, 0) ~= nil or nil
end
local function hex(bytes)
    return (bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end

local function bitrate(bytes)
    if bytes == nil then return nil end
    local rows = attributes(bytes)
    local rate16, rate32 = integer(rows, 1, 2), integer(rows, 5, 4)
    valid(not rate16 or not rate32 or rate16 == rate32)
    local result = { source = "nl80211", scope = "station", sample_kind = "driver_unicast_phy_rate" }
    local value = rate32 or rate16
    if value and value > 0 then result.bits_per_second = value * 100000 end
    local families = {
        { key = 2, name = "HT" }, { key = 6, streams = 7, name = "VHT" },
        { key = 13, streams = 14, gi = 15, name = "HE" },
        { key = 19, streams = 20, gi = 21, name = "EHT" },
    }
    for _, family in ipairs(families) do
        local mcs = integer(rows, family.key, 1)
        if mcs ~= nil then
            valid(not result.standard)
            result.standard, result.mcs = family.name, mcs
            if family.streams then result.spatial_streams = integer(rows, family.streams, 1) end
            if family.gi then
                local gi = integer(rows, family.gi, 1)
                if gi ~= nil then
                    result.guard_interval_code = gi
                    result.guard_interval_microseconds = ({ [0] = .8, [1] = 1.6, [2] = 3.2 })[gi]
                end
            end
        end
    end
    for key, width in pairs({ [3] = 40, [8] = 80, [9] = 160, [10] = 160, [11] = 10, [12] = 5, [18] = 320 }) do
        if flag(rows, key) then
            valid(not result.bandwidth_mhz)
            result.bandwidth_mhz = width
            if key == 9 then result.noncontiguous = true end
        end
    end
    result.short_guard_interval = flag(rows, 4)
    return result
end

local function station(bytes)
    if bytes == nil then return nil end
    local top = attributes(bytes)
    local value = field(top, 21)
    if value == nil then return nil end
    local rows = attributes(value)
    return { signal_dbm = integer(rows, 7, 1, true),
        average_signal_dbm = integer(rows, 13, 1, true), inactive_ms = integer(rows, 1, 4),
        receive_phy = bitrate(field(rows, 14)), transmit_phy = bitrate(field(rows, 8)),
        signal_sample_kind = "last_received_ppdu", radio_sample_time_known = false,
        scope = "station", source = "nl80211" }
end

local function decode(raw)
    valid(type(raw) == "table" and raw.source == "nl80211"
        and type(raw.associations) == "table" and #raw.associations <= 16)
    local info = attributes(raw.interface)
    local name, wdev = field(info, 4), field(info, 153, 8)
    valid(name and #name >= 2 and #name <= 16 and name:sub(-1) == "\0"
        and not name:sub(1, -2):find("\0", 1, true) and wdev)
    local index, wiphy, mode = integer(info, 3, 4), integer(info, 1, 4), integer(info, 5, 4)
    valid(index and index > 0 and index <= 2147483647 and wiphy and (mode == 2 or mode == 8))
    local result = { name = name:sub(1, -2), ifindex = index, wiphy_id = wiphy,
        wdev_id = string.format("%016x", (string.unpack("=i8", wdev))),
        mode = mode == 2 and "station" or "p2p_client", source = "nl80211",
        association = #raw.associations > 0 and "associated" or "not_reported", links = {} }
    local seen, link_ids = {}, {}
    for index = 1, #raw.associations do
        local bytes = raw.associations[index]
        local bss = attributes(bytes)
        local bssid, mld = field(bss, 1, 6), field(bss, 22, 6)
        valid(bssid and integer(bss, 9, 4) == 1 and not seen[hex(bssid)])
        seen[hex(bssid)] = true
        local link = { frequency_mhz = integer(bss, 2, 4), frequency_offset_khz = integer(bss, 20, 4),
            link_id = integer(bss, 21, 1) }
        if link.link_id ~= nil then
            valid(link.link_id <= 15 and not link_ids[link.link_id])
            link_ids[link.link_id] = true
        end
        if link.frequency_mhz == 0 then link.frequency_mhz = nil end
        result.multi_link = result.multi_link or mld ~= nil or #raw.associations > 1
        result.links[#result.links + 1] = link
    end
    if raw.station_errno ~= nil then
        valid(type(raw.station_errno) == "number" and raw.station_errno % 1 == 0
            and raw.station_errno > 0 and raw.station_errno <= 4095)
        result.station_errno = raw.station_errno
    end
    result.station = station(raw.station)
    valid(not result.station or #result.links > 0)
    if result.multi_link and result.station then
        -- A top-level MLD station report does not identify one physical link.
        result.station.scope = "mld_station"
        for _, rate in ipairs({ result.station.receive_phy or false, result.station.transmit_phy or false }) do
            if rate then rate.scope = "mld_station" end
        end
    end
    return result
end

function M.parse(raw)
    local ok, value = pcall(decode, raw)
    if not ok then return nil, "invalid_wifi_data" end
    return value
end
return M
