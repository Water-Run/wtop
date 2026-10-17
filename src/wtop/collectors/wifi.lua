local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Native = require("wtop.native")
local Parser = require("wtop.format.wifi_link")
local M = {}
M.__index = M

local function integer(value)
    return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 2147483647 and value or nil
end
local function identity(fs, base, name)
    local index = integer(fs:read_number(base .. "/" .. name .. "/ifindex"))
    local phy = integer(fs:read_number(base .. "/" .. name .. "/phy80211/index"))
    if index and index > 0 and phy then return { name = name, ifindex = index, wiphy_id = phy } end
end

function M.new(options)
    options = options or {}
    return setmetatable({ id = "wifi", _method_style = true,
        fs = options.fs or FS.default, reader = options.reader or (Native.available and Native.read_wifi_link),
        base_path = Common.absolute_path("base_path", options.base_path, "/sys/class/net"),
        max_devices = Common.positive_integer("max_devices", options.max_devices, 16, 16),
        default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 5000),
    }, M)
end

function M:_discover(context)
    local fs = Common.fs(context, self.fs)
    local names, err, truncated = fs:list(self.base_path, 4096)
    if not names then return nil, err end
    local rows, seen = {}, {}
    table.sort(names)
    for _, name in ipairs(names) do
        if type(name) == "string" and #name > 0 and #name < 16 and name ~= "." and name ~= ".."
            and not name:find("[/\0%c%s]") then
            local row = identity(fs, self.base_path, name)
            if row then
                if seen[row.ifindex] or #rows == self.max_devices then truncated = true
                else rows[#rows + 1], seen[row.ifindex] = row, true end
            end
        end
    end
    return rows, nil, truncated == true
end

function M:probe(context)
    if type(self.reader) ~= "function" then
        return Capability.unavailable("wifi_link_unavailable", { source = "nl80211" })
    end
    local rows, err = self:_discover(context)
    if rows and #rows > 0 then return Capability.available({ source = "nl80211" }) end
    if err and FS.error_status(err) == "denied" then
        return Capability.denied("wifi_link_unavailable", { source = self.base_path })
    end
    return Capability.unavailable("wifi_link_unavailable", { source = self.base_path })
end

function M:sample(context)
    local began = Common.now_ns(context)
    if context and context.safe_mode then
        return Common.result("unavailable", began, nil, { reason = "safe_mode" })
    end
    if type(self.reader) ~= "function" then
        return Common.result("unavailable", began, nil, { reason = "wifi_link_unavailable" })
    end
    local rows, err, truncated = self:_discover(context)
    if not rows then return Common.result(FS.error_status(err), began, nil, { reason = "wifi_link_unavailable" }) end
    if #rows == 0 then return Common.result("unavailable", began, nil, { reason = "wifi_link_unavailable" }) end
    local fs = Common.fs(context, self.fs)
    local data, partial = { devices = {}, source = "nl80211", truncated = truncated }, truncated
    for _, expected in ipairs(rows) do
        local ok, raw, message, errno = pcall(self.reader, expected.name, expected.ifindex)
        local parsed = ok and Parser.parse(raw)
        local after = identity(fs, self.base_path, expected.name)
        local row = parsed or expected
        if not after or after.ifindex ~= expected.ifindex or after.wiphy_id ~= expected.wiphy_id
            or parsed and (parsed.name ~= expected.name or parsed.ifindex ~= expected.ifindex
                or parsed.wiphy_id ~= expected.wiphy_id) then
            row = expected
            row.quality = "gap"
        elseif parsed then
            row.quality = (row.station_errno or (row.association == "associated" and not row.station)) and "partial" or "fresh"
            row.id = "phy:" .. row.wiphy_id .. ":wdev:" .. row.wdev_id
        else
            row.quality = (errno == 1 or errno == 13) and "denied" or "unavailable"
            if errno == 116 or errno == 19 or errno == 6 then row.quality = "gap" end
            if not ok then row.quality = "error" end
            row.query_errno = type(errno) == "number" and errno or nil
        end
        row.source, row.observed_at_ns = "nl80211", Common.now_ns(context)
        partial = partial or row.quality ~= "fresh"
        data.devices[#data.devices + 1] = row
    end
    local finished = Common.now_ns(context)
    return Common.result("ok", finished, data, { quality = partial and "partial" or "fresh",
        reason = partial and "platform_data_partial" or nil, source = "nl80211",
        duration_ns = Common.elapsed_ns(finished, began) or 0 })
end
return M
