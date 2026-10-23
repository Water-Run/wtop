local root, control, entered = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path
local Native = require("wtop.native")
local Worker = require("wtop.collectors.hardware_worker")
local Snapshot, Export = require("wtop.model.snapshot"), require("wtop.export")
local Hardware = require("wtop.model.hardware")
assert(Worker.available(Native, "typec"))
local reader = Worker.new(require("wtop.collectors.typec").new())
local independent = Worker.new(require("wtop.collectors.hwmon").new())
local context = { now_ns = Native.monotonic_ns }
local function write(path, value)
  local f = assert(io.open(path, "wb"));assert(f:write(value));assert(f:close())
end
local function settle(source, seconds, reason)
  local deadline = Native.monotonic_ns() + seconds * 1e9
  repeat
    local before = Native.monotonic_ns();local value = source:sample(context)
    assert(Native.monotonic_ns() - before < 250000000, "foreground Type-C query blocked")
    if reason and value.reason == reason or not reason and not value.sampling_pending then return value end
    assert(Native.monotonic_ns() < deadline, tostring(value.reason));Native.sleep_ms(10)
  until false
end
local fresh = settle(reader, 3)
assert(fresh.status == "ok" and fresh.data.ports[1].pd_id == "pd7")
assert(#fresh.data.pd_devices[1].profiles == 10)
assert(fresh.data.pd_devices[1].profiles[1].voltage_volts == 5)
local snapshot = Snapshot.merge(nil, { typec = fresh }, 1, Native.monotonic_ns())
assert(Hardware.related(Hardware.build(snapshot), "typec:port0").total == 1)
write(control, "1\n")
local pending = reader:sample(context);assert(pending.sampling_pending)
snapshot = Snapshot.merge(snapshot, { typec = pending }, 2, Native.monotonic_ns())
local stale = Export.snapshot(snapshot).typec
assert(stale.ports[1].pd_id == nil and stale.ports[1].quality == "stale")
assert(stale.pd_devices[1].profiles[1].voltage_volts == 5 and stale.pd_devices[1].profiles[1].quality == "stale")
assert(Hardware.related(Hardware.build(snapshot), "typec:port0").total == 0)
assert(settle(independent, 3).status == "ok")
assert(settle(reader, 3, "hardware_query_timeout").data == nil)
local f = assert(io.open(entered, "rb"));local pid = assert(tonumber(f:read("a")));f:close()
local deadline = Native.monotonic_ns() + 1e9
while Native.access("/proc/" .. pid, "f") do
  assert(Native.monotonic_ns() < deadline, "Type-C child not reaped");Native.sleep_ms(10)
end
write(control, "0\n")
local until_recovered = Native.monotonic_ns() + 10e9
local recovered = settle(reader, 7)
while recovered.reason == "hardware_query_timeout" do
  assert(Native.monotonic_ns() < until_recovered);Native.sleep_ms(100);recovered = settle(reader, 7)
end
assert(recovered.status == "ok" and recovered.value_timestamp_ns > fresh.value_timestamp_ns)
assert(recovered.data.ports[1].pd_id == "pd7")
reader:close();independent:close()
print("TYPEC_WORKER_PASSED:roles and five PDO kinds, real timestamps, stale association withdrawal, independent hwmon, timeout/reap/recovery")
