local root, base, control, entered = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path
local Native = require("wtop.native")
local Worker = require("wtop.collectors.hardware_worker")
local CPPC = require("wtop.collectors.cppc")
local Snapshot = require("wtop.model.snapshot")
local Export = require("wtop.export")
assert(Worker.available(Native, "cppc"))
local reader = Worker.new(CPPC.new(), {base_path=base})
local independent = Worker.new(require("wtop.collectors.hwmon").new())
local context = {now_ns=Native.monotonic_ns}
local function write(path,value)
  local f=assert(io.open(path,"wb"));assert(f:write(value));assert(f:close())
end
local function settle(source, seconds, reason)
  local deadline=Native.monotonic_ns()+seconds*1e9
  repeat
    local start=Native.monotonic_ns();local result=source:sample(context)
    assert(Native.monotonic_ns()-start<250000000,"CPPC foreground query blocked")
    if reason and result.reason==reason or not reason and not result.sampling_pending then return result end
    assert(Native.monotonic_ns()<deadline,tostring(result.reason));Native.sleep_ms(10)
  until false
end
local fresh=settle(reader,3)
assert(fresh.transport=="process" and fresh.status=="ok" and #fresh.data.cpus==1)
assert(fresh.data.cpus[1].nominal_frequency_hz==3300000000 and reader.session==nil)
assert(fresh.quality=="fresh" and fresh.data.cpus[1].guaranteed_performance==nil)
local snapshot=Snapshot.merge(nil,{cppc=fresh},1,Native.monotonic_ns())
write(control,"1\n")
local pending=reader:sample(context);assert(pending.sampling_pending)
Native.sleep_ms(120);pending=reader:sample(context)
snapshot=Snapshot.merge(snapshot,{cppc=pending},2,Native.monotonic_ns())
local retained=Export.snapshot(snapshot).cppc
assert(retained.cpus[1].quality=="stale" and retained.cpus[1].nominal_frequency_hz==3300000000)
assert(settle(independent,3).status=="ok")
assert(settle(reader,3,"hardware_query_timeout").data==nil)
local f=assert(io.open(entered,"rb"));local pid=assert(tonumber(f:read("a")));f:close()
local deadline=Native.monotonic_ns()+1e9
while Native.access("/proc/"..pid,"f") do
  assert(Native.monotonic_ns()<deadline,"CPPC child not reaped");Native.sleep_ms(10)
end
write(control,"0\n")
local recovered=settle(reader,7)
local recovery_deadline=Native.monotonic_ns()+10e9
while recovered.reason=="hardware_query_timeout" do
  assert(Native.monotonic_ns()<recovery_deadline);Native.sleep_ms(100);recovered=settle(reader,7)
end
assert(recovered.status=="ok" and recovered.value_timestamp_ns>fresh.value_timestamp_ns)
assert(recovered.data.cpus[1].quality=="fresh" and reader.session==nil)
reader:close();independent:close()
print("CPPC_WORKER_PASSED:exact references,stateless reader released,stale retained,independent hwmon,timeout,reap,recovery")
