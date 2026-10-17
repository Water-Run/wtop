local Native = require("wtop.native")
local Wire = require("wtop.core.worker_wire")
local base, control, entered = arg[1], arg[2], arg[3]
local function write(path, value)
    local f = assert(io.open(path, "wb")); assert(f:write(value)); assert(f:close())
end
local function exists(path)
    local f = io.open(path, "rb"); if f then f:close(); return true end
end
local function elapsed(start) return (Native.monotonic_ns() - start) / 1000000 end
write(control, "0")
local session = assert(Native.hardware_worker_open("disk_health", Wire.encode({ base_path = base })))
local bytes, meta
local start = Native.monotonic_ns()
repeat
    bytes, meta = Native.hardware_worker_query(session, false, 0)
    if not bytes then Native.sleep_ms(5) end
until bytes or elapsed(start) > 3000
assert(bytes, "normal native NVMe worker did not answer")
local data = Wire.decode(bytes)
assert(data.result.quality == "fresh" and data.result.data.devices[1].nvme.data_units_read == "42")
assert(Native.hardware_worker_close(session, 100))
os.remove(entered)
write(control, "1")
session = assert(Native.hardware_worker_open("disk_health", Wire.encode({ base_path = base })))
assert(not Native.hardware_worker_query(session, false, 0))
start = Native.monotonic_ns()
while not exists(entered) and elapsed(start) < 3000 do Native.sleep_ms(5) end
assert(exists(entered), "blocked NVMe ioctl was not reached")
for _ = 1, 20 do
    start = Native.monotonic_ns()
    local reply, status = Native.hardware_worker_query(session, false, 0)
    assert(reply == nil and status == "hardware_query_pending")
    assert(elapsed(start) < 100, "NVMe ioctl blocked the parent")
end
local f = assert(io.open(entered, "rb")); local pid = assert(tonumber(f:read("a"))); f:close()
start = Native.monotonic_ns()
assert(Native.hardware_worker_close(session, 100))
assert(elapsed(start) < 1500, "blocked reader shutdown exceeded its bound")
assert(not Native.path_type("/proc/" .. pid), "blocked reader was not reaped")
print("ok: native NVMe worker roundtrip, nonblocking parent and cancellation/reap during ioctl")
