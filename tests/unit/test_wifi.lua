local Parser = require("wtop.format.wifi_link")
local Collector = require("wtop.collectors.wifi")
local Quality = require("wtop.model.wifi")
local Export = require("wtop.export")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local function attr(key, value)
    local length = #value + 4
    return string.pack("=I2I2", length, key) .. value .. string.rep("\0", (-length) % 4)
end
local function number(key, value, size) return attr(key, string.pack("=I" .. (size or 4), value)) end
local function rate(value, mcs)
    return number(5, value) .. number(13, mcs, 1) .. number(14, 2, 1) .. attr(8, "")
end
local function fixture()
    return { source = "nl80211",
        interface = number(3, 3) .. attr(4, "wlan0\0") .. number(1, 0) .. number(5, 2)
            .. attr(153, string.pack("=I8", 1)) .. attr(6, "abcdef"),
        associations = { attr(1, "123456") .. number(2, 5745) .. number(9, 1) },
        station = number(3, 3) .. attr(6, "123456") .. attr(21,
            attr(7, string.pack("i1", -53)) .. attr(13, string.pack("i1", -55)) .. number(1, 9)
                .. attr(14, rate(8648, 8)) .. attr(8, rate(7206, 7))) }
end
local decoded = assert(Parser.parse(fixture()))
assert(decoded.name == "wlan0" and decoded.ifindex == 3 and decoded.wiphy_id == 0)
assert(decoded.wdev_id == "0000000000000001" and decoded.association == "associated")
assert(decoded.links[1].frequency_mhz == 5745 and decoded.station.signal_dbm == -53)
assert(decoded.station.average_signal_dbm == -55 and decoded.station.inactive_ms == 9)
assert(decoded.station.receive_phy.bits_per_second == 864800000)
assert(decoded.station.transmit_phy.bits_per_second == 720600000)
assert(decoded.station.receive_phy.standard == "HE" and decoded.station.receive_phy.mcs == 8)
assert(decoded.station.receive_phy.spatial_streams == 2 and decoded.station.receive_phy.bandwidth_mhz == 80)
assert(decoded.station.radio_sample_time_known == false and decoded.station.signal_sample_kind == "last_received_ppdu")
for _, mutate in ipairs({
    function(s) s.interface = "\0" end,
    function(s) s.interface = s.interface .. number(3, 4) end,
    function(s) s.interface = number(0x4000 | 3, 3) .. s.interface:sub(9) end,
    function(s) s.interface = string.rep("x", 8193) end,
    function(s) s.associations[2] = s.associations[1] end,
    function(s) for n = 1, 17 do s.associations[n] = "x" end end,
    function(s) s.associations[1] = attr(1, "short") .. number(9, 1) end,
    function(s) s.station_errno = 0 end,
}) do
    local s = fixture(); mutate(s)
    assert(not Parser.parse(s))
end
local future = fixture();future.interface = future.interface .. attr(0x4000 | 4095, "future")
assert(Parser.parse(future), "unknown attributes should not invent meanings or break older readers")
local conflict = fixture()
conflict.station = attr(21, attr(8, number(1, 10, 2) .. number(5, 11)))
assert(not Parser.parse(conflict))
local maximum = fixture()
maximum.station = attr(21, attr(8, number(5, 4294967295)))
assert(Parser.parse(maximum).station.transmit_phy.bits_per_second == 429496729500000)
local zero = fixture();zero.station = attr(21, attr(8, number(5, 0)))
assert(Parser.parse(zero).station.transmit_phy.bits_per_second == nil)
local mlo = fixture()
mlo.associations[1] = mlo.associations[1] .. number(21, 0, 1) .. attr(22, "mldkey")
mlo.associations[2] = attr(1, "654321") .. number(2, 6135) .. number(9, 1) .. number(21, 1, 1) .. attr(22, "mldkey")
assert(Parser.parse(mlo).station.receive_phy.scope == "mld_station")
assert(#Parser.parse(mlo).links == 2)
local empty = fixture();empty.associations,empty.station = {},nil
assert(Parser.parse(empty).association == "not_reported")

local calls, ifindex, time = 0, 3, 1000000000
local fs = { list = function() return { "wlan0", "eth0" } end,
    read_number = function(_, path)
        if path == "/sys/class/net/wlan0/ifindex" then return ifindex end
        if path == "/sys/class/net/wlan0/phy80211/index" then return 0 end
    end }
local context = { now_ns = function() return time end }
local collector = Collector.new({ fs = fs, reader = function(name, index)
    assert(name == "wlan0" and index == 3);calls = calls + 1;return fixture()
end })
assert(collector:probe(context).available and calls == 0, "probe queried the radio")
local sample = collector:sample(context)
assert(sample.status == "ok" and sample.quality == "fresh" and calls == 1)
assert(sample.data.devices[1].id == "phy:0:wdev:0000000000000001")
context.safe_mode = true;assert(collector:sample(context).status == "unavailable" and calls == 1);context.safe_mode = nil
collector.reader = function() ifindex = 4;return fixture() end
assert(collector:sample(context).data.devices[1].quality == "gap");ifindex = 3
collector.reader = function() return nil,"denied",13 end
assert(collector:sample(context).data.devices[1].quality == "denied")
collector.reader = function() local s = fixture();s.station=nil;s.station_errno=13;return s end
assert(collector:sample(context).data.devices[1].quality == "partial")

local two_fs = { list = function() return { "wlan0", "wlan1" } end,
    read_number = function(_, path)
        if path:find("phy80211/index", 1, true) then return 0 end
        if path:find("wlan0/ifindex", 1, true) then return 3 end
        if path:find("wlan1/ifindex", 1, true) then return 4 end
    end }
local two = Collector.new({ fs = two_fs, reader = function(name, index)
    local raw = fixture()
    if name == "wlan1" then
        time = time + 20000000000
        raw.interface = number(3, index) .. raw.interface:sub(9):gsub("wlan0", "wlan1")
    end
    return raw
end }):sample(context)
local late = { timestamp_ns = time, wifi = two.data,
    quality = { wifi = { status = "ok", quality = "fresh", value_timestamp_ns = time } } }
assert(Quality.quality(late, two.data.devices[1]) == "stale", "late batch renewed early radio report")
assert(Quality.quality(late, two.data.devices[2]) == "fresh")
local limited = Export.agent(late, { device_limit = 1 })
assert(#limited.top.wifi == 1 and limited.metrics.network.wifi_interfaces_total == 2 and limited.metrics.network.wifi_truncated)
time = 1000000000

local snapshot = { timestamp_ns = time, wifi = sample.data,
    quality = { wifi = { status = "ok", quality = "fresh", value_timestamp_ns = time } } }
local device = snapshot.wifi.devices[1]
assert(Quality.quality(snapshot, device) == "fresh")
for _, status in ipairs({ "denied", "error", "unavailable" }) do
    snapshot.quality.wifi.status = status
    assert(Quality.quality(snapshot, device) ~= "fresh", "failed source cannot label a retained report fresh")
end
snapshot.quality.wifi.status = "ok"
snapshot.timestamp_ns = time + 16000000000
assert(Quality.quality(snapshot, device) == "stale")
assert(Export.snapshot(snapshot).wifi.devices[1].quality == "stale")
snapshot.timestamp_ns = time - 1;assert(Quality.quality(snapshot, device) == "unknown")
snapshot.timestamp_ns = time
local public = Export.snapshot(snapshot).wifi.devices[1]
assert(public.station.receive_phy.bits_per_second == 864800000 and public.station.radio_sample_time_known == false)
assert(not public.interface and not public.associations and not public.bssid and not public.ssid)
assert(Export.agent(snapshot).top.wifi[1].station.transmit_phy.bits_per_second == 720600000)
local report = require("wtop.report").render(Export.snapshot(snapshot))
assert(report:find("Wi-Fi link reports", 1, true) and report:find("864.8 Mbit/s", 1, true))
assert(report:find("not throughput or guaranteed capacity", 1, true))
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "de-DE", "fr-FR", "es-ES", "pt-BR", "ru-RU" }) do
    local tr = assert(I18n.new({ locale = locale }))
    local text = table.concat(TUI.wifi_link_lines(snapshot, tr), "\n")
    assert(text:find(tr:t("wifi.title"), 1, true)
        and text:find(tr.format:number(5745, { precision = 0 }), 1, true), locale)
    assert(text:find(tr:t("wifi.note"), 1, true)
        and text:find(tr.format:number(-53, { precision = 0 }), 1, true), locale)
end
print("ok: nl80211 types/units/MLO scope; capture age, identity, denial, safe mode, exports andtenlanguage WiFi view")
