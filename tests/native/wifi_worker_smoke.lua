local root, tree, control, entered = arg[1], arg[2], arg[3], arg[4]
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path
local Native = require("wtop.native")
local FS = require("wtop.linux.fs").default
local Parser = require("wtop.format.wifi_link")
local Collector = require("wtop.collectors.wifi")
local Proxy = require("wtop.collectors.hardware_worker")
local context = { clock = { now_ns = Native.monotonic_ns, wall_ns = Native.realtime_ns } }
local function write(path, value)
    local file = assert(io.open(path, "wb"));assert(file:write(value));file:close()
end
local function born(pid)
    local raw = FS:read("/proc/" .. pid .. "/stat", 4096)
    if not raw then return nil end
    local fields, rest = {}, raw:match("^%d+ %b() (.+)")
    if not rest then return nil end
    for token in rest:gmatch("%S+") do fields[#fields + 1] = token end
    return fields[20]
end
for _, bad in ipairs({ "", string.rep("x", 16), "bad/name", "wlan0\0suffix" }) do
    assert(not pcall(Native.read_wifi_link, bad, 3), "invalid name reached transport")
end
for _, bad in ipairs({ 0, -1, 2147483648, .5, math.huge }) do
    assert(not pcall(Native.read_wifi_link, "wlan0", bad), "invalid index reached transport")
end
local before = #assert(FS:list("/proc/self/fd", 256))
for _ = 1, 20 do
    local data = assert(Parser.parse(assert(Native.read_wifi_link("wlan0", 3))))
    assert(data.station.signal_dbm == -53 and data.station.receive_phy.bits_per_second == 864800000)
end
assert(#assert(FS:list("/proc/self/fd", 256)) == before, "native query retained a descriptor")

local function proxy()
    return Proxy.new(Collector.new({ base_path = tree }), { base_path = tree }, Native)
end
local function completed(reader)
    local deadline = Native.monotonic_ns() + 2000000000
    repeat
        local result = reader:sample(context)
        if result.status == "ok" then
            assert(result.data.devices[1].quality == "fresh" and result.transport == "process")
            assert(result.data.devices[1].station.signal_dbm == -53)
            assert(reader.session == nil, "stateless WiFi reader kept an idle VM")
            return result
        end
        Native.sleep_ms(5)
    until Native.monotonic_ns() >= deadline
    error("WiFi reader did not finish")
end
write(control, "0\n")
local reader = proxy();completed(reader)
write(control, "1\n");os.remove(entered)
local deadline = Native.monotonic_ns() + 2000000000
local maximum = 0
repeat
    local began = Native.monotonic_ns()
    local result = reader:sample(context)
    maximum = math.max(maximum, Native.monotonic_ns() - began)
    assert(result.sampling_pending)
    assert(FS:read("/proc/stat", 262144), "blocked WiFi stopped independent CPU reads")
    if FS:read(entered, 64) then break end
    Native.sleep_ms(5)
until Native.monotonic_ns() >= deadline
local pid = assert(FS:read(entered, 64)):match("^(%d+)")
local birth = assert(born(pid), "blocked child was not live")
assert(maximum < 100000000, "foreground waited on netlink")
local began = Native.monotonic_ns();reader:close()
assert(Native.monotonic_ns() - began < 250000000, "close waited for blocked netlink")
deadline = Native.monotonic_ns() + 1000000000
while born(pid) == birth and Native.monotonic_ns() < deadline do Native.sleep_ms(5) end
assert(born(pid) ~= birth, "blocked child survived close")
write(control, "0\n")
reader = proxy();completed(reader);reader:close()
print("WiFi native API/FDs andexecworker: fresh/idleVMrelease/blockedparent/close/reap/recovery passed")
