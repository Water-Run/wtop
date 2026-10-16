package.path="./src/?.lua;./src/?/init.lua;"..package.path
local N=require("wtop.native")
if arg[1]=="--wtop-hardware-reader"then os.exit(N.hardware_worker_run(table.unpack(arg,2,#arg)),true)end
N.hardware_worker_sources=N.hardware_worker_configure("storage_lifecycle.lua")
local P=require("wtop.collectors.portable")
local H=require("wtop.collectors.windows_storage")
local S=require("wtop.model.snapshot")
local JSON=require("wtop.core.json")
local mode=arg[1];local target=assert(os.getenv("WTOP_STORAGE_FAULT_TARGET"));local root=assert(os.getenv("WTOP_STORAGE_FAULT_ROOT"))
local ctx={clock={now_ns=N.monotonic_ns,wall_ns=N.realtime_ns}}
local function read(name)
 local f=io.open(root.."/"..target.."."..name,"rb");if not f then return end
 local b=f:read("a");f:close();local ok,v=pcall(JSON.decode,b);if ok then return v end
end
local function trigger()local f=assert(io.open(root.."/trigger","wb"));f:write("test");f:close()end
if mode=="direct"then
 trigger();local started=N.monotonic_ns()
 if target=="health"then assert(N.collect_disk_health(false))else assert(N.collect_disk())end
 local elapsed=(N.monotonic_ns()-started)/1000000;assert(elapsed>=9900)
 print("direct baseline ms",elapsed);return
end
local readers={disk=P.new("disk",{native=N}),disk_health=H.new({native=N}),
 cpufreq=P.new("cpufreq",{native=N}),gpu=P.new("gpu",{native=N})}
local bad=target=="health"and"disk_health"or"disk"
local slots={disk="disks",disk_health="disk_health",cpufreq="cpu_frequency",gpu="gpus"}
local allow_unavailable=os.getenv("WTOP_STORAGE_ALLOW_UNAVAILABLE")=="1"
local function waitgood(reader,id)
 local deadline=N.monotonic_ns()+7000000000
 repeat local r=reader:sample(ctx);if r.status=="ok"or(allow_unavailable and(id=="gpu"or id=="cpufreq")and r.status=="unavailable")then return r end
  assert(r.reason=="hardware_query_pending"or r.sampling_pending,r.reason);N.sleep_ms(10)
 until N.monotonic_ns()>deadline;error("warmup failed")
end
local results={};for id,r in pairs(readers)do results[id]=waitgood(r,id)end
local snapshot=S.merge(nil,results,1,N.monotonic_ns())
local original=snapshot[slots[bad]];local observed=snapshot.quality[slots[bad]].value_timestamp_ns
local healthy={};for id in pairs(readers)do if id~=bad then healthy[id]={observed=snapshot.quality[slots[id]].value_timestamp_ns,attempted=snapshot.quality[slots[id]].timestamp_ns} end end
trigger();local began=N.monotonic_ns();local blocked
repeat
 local updates={}
 for id,r in pairs(readers)do local result=r:sample(ctx);if not result.defer_publish then updates[id]=result end end
 snapshot=S.merge(snapshot,updates,nil,N.monotonic_ns())
 blocked=read("blocked");N.sleep_ms(50)
until blocked or N.monotonic_ns()-began>5000000000
assert(blocked,"instrumented API was not entered")
assert(type(blocked.birth)=="string"and blocked.birth:match("^%d+$")and math.type(blocked.pid)=="integer")
if mode=="quit"then print("parent exiting with blocked reader",blocked.pid,blocked.birth);os.exit(19,false)end
while N.monotonic_ns()-began<3000000000 do
 local updates={};for id,r in pairs(readers)do local result=r:sample(ctx);if not result.defer_publish then updates[id]=result end end
 snapshot=S.merge(snapshot,updates,nil,N.monotonic_ns());N.sleep_ms(70)
end
assert(snapshot[slots[bad]]==original and snapshot.quality[slots[bad]].value_timestamp_ns==observed,
 "blocked source renewed its retained value")
for id,before in pairs(healthy)do local q=snapshot.quality[slots[id]]
 if before.observed then assert(q.value_timestamp_ns and q.value_timestamp_ns>before.observed,"healthy source stopped: "..id)
 else assert(q.timestamp_ns>before.attempted,"unavailable source no longer queried: "..id)end
end
local ok=os.execute("process-reaped.exe "..blocked.pid.." "..blocked.birth.." 1000");assert(ok,"blocked reader was not reaped")
assert((N.monotonic_ns()-began)/1000000<9000,"reaping proof missed lease")
assert(os.remove(root.."/trigger"))
local recovered
repeat
 local result=readers[bad]:sample(ctx)
 if result.status=="ok"then recovered=result;break end
 N.sleep_ms(70)
until N.monotonic_ns()-began>12000000000
assert(recovered,"reader did not recover")
local seen=assert(read("seen"));assert(seen.pid~=blocked.pid or seen.birth~=blocked.birth)
for _,r in pairs(readers)do if r.close then r:close()end end
local out={target=target,retained_timestamp=true,healthy_sources_advance=true,reaped_before_lease=true,
 new_reader_recovered=true,blocked=blocked,recovered=seen}
local f=assert(io.open(root.."/result.json","wb"));f:write(assert(require("wtop.format.json").encode(out)));f:close()
print("isolated API lifecycle passed",target)
