local root, control, entered, count_file = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
package.path=root.."/src/?.lua;"..root.."/src/?/init.lua;"..package.path
local Native=require("wtop.native")
local Worker=require("wtop.collectors.smbios_worker")
local Hardware=require("wtop.collectors.hardware_worker")
local Scheduler=require("wtop.core.scheduler")
local Snapshot=require("wtop.model.snapshot")
local function write(path,text) local f=assert(io.open(path,"wb"));assert(f:write(text));assert(f:close()) end
local function contents(path) local f=assert(io.open(path,"rb"));local data=f:read("a");f:close();return data end
local clock={now_ns=Native.monotonic_ns,wall_ns=Native.realtime_ns}
local context={clock=clock}
local shared=Worker.new()
local scheduler=Scheduler.new({clock=clock,context=context})
local count=0
for id in pairs(Worker.sources) do
    assert(scheduler:add(shared:wrap(require("wtop.collectors."..id).new())))
    count=count+1
end
assert(count==12 and Worker.sources.firmware_enclosures)
local function tick()
    for _, id in ipairs(scheduler.order) do scheduler:task(id).next_due_ns=0 end
    local start=Native.monotonic_ns();local results=scheduler:tick(context)
    assert(Native.monotonic_ns()-start<250000000,"firmware read blocked parent")
    return results
end
local function settle(seconds,wanted)
    local deadline=Native.monotonic_ns()+seconds*1e9
    repeat
        local results=tick();local done=0
        for _, value in pairs(results) do
            if wanted and value.reason==wanted or not wanted and not value.sampling_pending then done=done+1 end
        end
        if done==count then return results end
        assert(Native.monotonic_ns()<deadline,"firmware batch never settled")
        Native.sleep_ms(10)
    until false
end
local fresh=settle(3)
assert(fresh.onboard_devices.status=="ok" and fresh.port_connectors.status=="ok")
local observed=fresh.onboard_devices.value_timestamp_ns
assert(observed==fresh.port_connectors.value_timestamp_ns and observed<=fresh.onboard_devices.timestamp_ns)
local pids={};for pid in contents(count_file):gmatch("%d+") do pids[#pids+1]=pid end
assert(#pids==1,"firmware views read the table more than once")
for id,value in pairs(fresh) do
    assert(value.reason~="hardware_query_timeout")
    assert(value.capability.available==(value.status=="ok"),id)
end
local snapshot=Snapshot.merge(Snapshot.new(0,0),fresh,1,Native.monotonic_ns())
write(control,"1\n")
local pending=tick()
for _,value in pairs(pending) do assert(value.sampling_pending) end
snapshot=Snapshot.merge(snapshot,pending,2,Native.monotonic_ns())
assert(snapshot.quality.onboard_devices.quality=="stale"
    and snapshot.quality.onboard_devices.value_timestamp_ns==observed)
local independent=Hardware.new(require("wtop.collectors.cpufreq").new())
local deadline=Native.monotonic_ns()+3e9
repeat
    local result=independent:sample(context)
    assert(result.reason~="hardware_query_timeout","firmware blocked another reader")
    if not result.sampling_pending then break end
    assert(Native.monotonic_ns()<deadline);Native.sleep_ms(10)
until false
local failed=settle(3,"hardware_query_timeout")
for _,value in pairs(failed) do assert(not value.sampling_pending and not value.data) end
local old_pid=assert(tonumber(contents(entered)))
deadline=Native.monotonic_ns()+1e9
while Native.access("/proc/"..old_pid,"f") do
    assert(Native.monotonic_ns()<deadline,"firmware reader not reaped");Native.sleep_ms(10)
end
write(control,"0\n")
deadline=Native.monotonic_ns()+9e9
local recovered
repeat
    local results=tick()
    if results.onboard_devices.status=="ok" then recovered=results;break end
    assert(Native.monotonic_ns()<deadline,"firmware did not recover");Native.sleep_ms(20)
until false
assert(recovered.onboard_devices.value_timestamp_ns>observed
    and recovered.onboard_devices.value_timestamp_ns==recovered.port_connectors.value_timestamp_ns)
pids={};for pid in contents(count_file):gmatch("%d+") do pids[#pids+1]=pid end
assert(#pids==3 and pids[1]==pids[2] and pids[3]~=pids[1],"raw source duplication or wrong recovery epoch")
scheduler:stop(context);shared:close();independent:close()
print("ok: twelve firmware views, one raw read/parse epoch, real timestamps, timeout/reap, independent source and shared recovery")
