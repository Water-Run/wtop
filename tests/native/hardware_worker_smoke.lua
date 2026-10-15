local root, control, entered = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path
local Native = require("wtop.native")
local Hardware = require("wtop.collectors.hardware_worker")
local Snapshot = require("wtop.model.snapshot")
local function write(path, text) local f=assert(io.open(path,"wb"));assert(f:write(text));assert(f:close()) end
local context = { clock = { now_ns = Native.monotonic_ns, wall_ns = Native.realtime_ns } }
local hwmon = Hardware.new(require("wtop.collectors.hwmon").new())
local cpufreq = Hardware.new(require("wtop.collectors.cpufreq").new())
local power_options={base_path=assert(arg[4])}
local power=Hardware.new(require("wtop.collectors.powercap").new(power_options),power_options)
local function settle(proxy, seconds, expected)
    local deadline = Native.monotonic_ns() + seconds * 1e9
    repeat
        local started = Native.monotonic_ns()
        local value = proxy:sample(context)
        assert(Native.monotonic_ns()-started < 250000000, "foreground query blocked")
        if expected and value.reason == expected then return value end
        if not expected and not value.sampling_pending then return value end
        assert(Native.monotonic_ns()<deadline, "worker deadline: " .. tostring(value.reason))
        assert(Native.sleep_ms(10))
    until false
end
local fresh = settle(hwmon, 3)
assert(fresh.status=="ok" and fresh.data.devices[1].channels[1].input==42)
local sampled = fresh.value_timestamp_ns
local first_power=settle(power,3)
assert(first_power.status=="ok" and first_power.data.zones[1].power_watts==nil,
    "first energy observation fabricated watts")
local snapshot = Snapshot.merge(Snapshot.new(0, 0), { hwmon=fresh }, 1, Native.monotonic_ns())
write(control,"1\n")
local pending = hwmon:sample(context)
assert(pending.sampling_pending)
snapshot = Snapshot.merge(snapshot,{hwmon=pending},2,Native.monotonic_ns())
assert(snapshot.quality.sensors.quality=="stale" and snapshot.quality.sensors.value_timestamp_ns==sampled)
assert(snapshot.sensors.devices[1].channels[1].input==42)
local other = settle(cpufreq,3)
assert(other.reason~="hardware_query_timeout", "one stuck source blocked another")
Native.sleep_ms(150)
write(power_options.base_path.."/intel-rapl:0/energy_uj","5000000\n")
local measured=settle(power,3)
local zone=measured.data.zones[1]
assert(zone.energy_uj==5000000 and zone.power_interval_ns>0)
assert(math.abs(zone.power_watts-4000000*1000/zone.power_interval_ns)<1e-9,
    "energy delta used poll/receive time instead of measurement time")
local comparison=require("wtop.model.power").zone(zone,zone.constraints[1],measured.quality)
assert(comparison and math.abs(comparison.percent-zone.power_watts/25*100)<1e-9)
assert(zone.observed_at_ns>first_power.data.zones[1].observed_at_ns)
local failed = settle(hwmon,3,"hardware_query_timeout")
assert(not failed.sampling_pending and failed.data==nil)
local file=assert(io.open(entered,"rb"));local old_pid=assert(tonumber(file:read("a")));file:close()
local deadline=Native.monotonic_ns()+1e9
while Native.access("/proc/"..old_pid,"f") do
    assert(Native.monotonic_ns()<deadline,"timed-out child was not reaped");Native.sleep_ms(10)
end
write(control,"0\n")
-- The reader's bounded retry starts a new process. Retained sensor sessions
-- must not be copied into a new worker as if the interrupted read succeeded.
local recovery_deadline=Native.monotonic_ns()+10e9
local recovered = settle(hwmon,7)
while recovered.reason=="hardware_query_timeout" do
    assert(Native.monotonic_ns()<recovery_deadline,"reader never recovered")
    Native.sleep_ms(100);recovered=settle(hwmon,7)
end
assert(recovered.status=="ok" and recovered.value_timestamp_ns>sampled)
assert(recovered.data.devices[1].channels[1].input==42)
hwmon:close();cpufreq:close();power:close()
print("ok: complete hardware samples, real timestamps, bounded timeout/reap, independent source and recovery; exact energy delta and cap arithmetic")
