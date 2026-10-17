package.path="./src/?.lua;./src/?/init.lua;"..package.path
local N=require("wtop.native")
if arg[1]=="--wtop-hardware-reader"then os.exit(N.hardware_worker_run(table.unpack(arg,2,#arg)),true)end
N.hardware_worker_sources=N.hardware_worker_configure("lifecycle.lua")
local Windows=require("wtop.collectors.windows_gpu")
local Portable=require("wtop.collectors.portable")
local Snapshot=require("wtop.model.snapshot")
local JSON=require("wtop.core.json")
local Export=require("wtop.export")
local root=assert(os.getenv("WTOP_ADL_LIFECYCLE_MARKER"))
local control=assert(os.getenv("WTOP_ADL_FIXTURE_CONTROL"))
local mode=arg[1]
local pmlog=os.getenv("WTOP_ADL_LIFECYCLE_PMLOG")=="1"
local normal,blocked_mode,expected_watts=pmlog and 60 or 0,pmlog and 84 or 44,pmlog and 37 or 22.5
local function read(suffix)
 local f=io.open(root.."."..suffix,"rb");if not f then return end
 local bytes=f:read("a");f:close();local ok,value=pcall(JSON.decode,bytes);if ok then return value end
end
local function set(value)local f=assert(io.open(control,"wb"));f:write(tostring(value));f:close()end
local context={clock={now_ns=N.monotonic_ns,wall_ns=N.realtime_ns},scan_gpu_processes=false}
local base={probe=function()return{available=true}end,sample=function()
 local now=N.monotonic_ns()
 return{status="ok",quality="fresh",timestamp_ns=now,value_timestamp_ns=now,data={devices={
  {id="fixture-amd",pci_bdf="0000:01:00.0",vendor_id="0x1002",device_id="0x6613",driver="fixture",
   identity_quality="fresh",metrics={},quality={},capabilities={}},
 }}}
end}
local collector=Windows.new(base,{nvml_provider=false,levelzero_provider=false},N)
local frequency=Portable.new("cpufreq",{native=N})
local snapshot
local function sample()
 local now=N.monotonic_ns();context.now_ns=function()return now end
 snapshot=Snapshot.merge(snapshot,{gpu=collector:sample(context),cpufreq=frequency:sample(context)},nil,now)
 return snapshot
end
local function find(s)
 for _,d in ipairs(s.gpus and s.gpus.devices or{})do if d.id=="fixture-amd"then return d end end
end
local began=N.monotonic_ns()
if mode=="quit"then set(blocked_mode)else set(normal)end
if mode~="quit"then
 repeat
  sample();local d=find(snapshot)
  if d and d.quality.power=="fresh"and snapshot.quality.cpu_frequency
      and snapshot.quality.cpu_frequency.status=="ok"then break end
  N.sleep_ms(30)
 until N.monotonic_ns()-began>7e9
 local d=assert(find(snapshot));assert(d.quality.power=="fresh"and d.metrics.power_watts==expected_watts)
 local fields=Export.snapshot(snapshot).gpus.devices
 local seen=false;for _,value in ipairs(fields)do if value.id=="fixture-amd"then assert(value.metrics.power_limit_percent==nil and value.metrics.power_scope=="asic");seen=true end end;assert(seen)
end
local original,observed
local cpu_before=snapshot and snapshot.quality.cpu_frequency.value_timestamp_ns
set(blocked_mode);local blocked;began=N.monotonic_ns()
repeat sample();blocked=read("blocked");N.sleep_ms(10)until blocked or N.monotonic_ns()-began>5e9
assert(blocked and type(blocked.birth)=="string")
if mode=="quit"then print("exiting while ADL power API blocked",blocked.pid,blocked.birth);os.exit(19,false)end
-- A successful request already in flight when control changes may complete.
-- Pin the last value after the blocking call is observed, not before dispatch.
original=assert(find(snapshot));observed=original.metric_observations.power_watts.observed_at_ns
while N.monotonic_ns()-began<2700000000 do sample();N.sleep_ms(30)end
local retained=assert(find(snapshot))
assert(retained.metrics.power_watts==original.metrics.power_watts and retained.quality.power=="stale")
assert(retained.metric_observations.power_watts.observed_at_ns==observed)
if pmlog then
 assert(retained.metrics.hotspot_temperature_celsius==79 and math.abs(retained.metrics.graphics_voltage_volts-.95)<1e-12)
 assert(retained.adl.hardware_timestamp_available==false and retained.metric_observations.power_watts.measurement=="driver_snapshot")
end
assert(snapshot.quality.cpu_frequency.value_timestamp_ns>cpu_before,"healthy actual frequency reader stopped")
for _,d in ipairs(Export.snapshot(snapshot).gpus.devices)do
 if d.id=="fixture-amd"then assert(d.metrics.power_limit_percent==nil)end
end
assert(os.execute("process-reaped.exe "..blocked.pid.." "..blocked.birth.." 1000"))
assert((N.monotonic_ns()-began)/1e6<9000,"missed blocked API lease")
collector:close();frequency:close();set(normal)
local reader=assert(N.gpu_worker_open("adl"));local result,reason;began=N.monotonic_ns()
repeat result,reason=N.gpu_worker_query(reader,false);if result then break end;assert(reason=="adl_query_pending",reason);N.sleep_ms(5)until N.monotonic_ns()-began>5e9
assert(result and result.devices[1].power_watts==expected_watts and result.devices[1].power_limit_watts==nil)
local loaded=assert(read("loaded"));assert(loaded.pid~=blocked.pid or loaded.birth~=blocked.birth)
N.gpu_worker_close(reader,0)
print("Windows AMD ADL lifecycle: retained power/time, live actual CPU frequency, identity-bound pre-lease reap and fresh-reader recovery passed")
