local root,tree,info,counters,control,entered=assert(arg[1]),assert(arg[2]),assert(arg[3]),assert(arg[4]),assert(arg[5]),assert(arg[6])
package.path=root.."/src/?.lua;"..root.."/src/?/init.lua;"..package.path
local Native=require("wtop.native")
local Hardware=require("wtop.collectors.hardware_worker")
local Snapshot=require("wtop.model.snapshot")
local options={cpu_path=tree,cpuinfo_path=info}
local reader=Hardware.new(require("wtop.collectors.cpu_clocks").new(options),options)
local context={clock={now_ns=Native.monotonic_ns,wall_ns=Native.realtime_ns}}
local function write(path,text)local f=assert(io.open(path,"wb"));assert(f:write(text));assert(f:close())end
local function settle(seconds,predicate)
 local deadline=Native.monotonic_ns()+seconds*1e9
 repeat
  local start=Native.monotonic_ns();local r=reader:sample(context)
  assert(Native.monotonic_ns()-start<250000000,"clock read blocked foreground")
  if predicate(r) then return r end
  assert(Native.monotonic_ns()<deadline,"clock reader did not settle: "..tostring(r.reason))
  Native.sleep_ms(10)
 until false
end
local warm=settle(3,function(r)return r.data~=nil end)
assert(warm.data.cpus[1].reason=="cpu_clock_warmup" and warm.data.cpus[1].effective_hz==nil,
 "initial clock sample: quality="..tostring(warm.data.cpus[1].quality)
 .." reason="..tostring(warm.data.cpus[1].reason).." errno="..tostring(warm.data.cpus[1].read_errno))
Native.sleep_ms(150);write(counters,string.pack("<i8i8",1100000000,1200000000))
local fresh=settle(3,function(r)return r.data and r.data.measured_cpus==1 end)
local row=fresh.data.cpus[1]
assert(row.effective_hz>0 and row.aperf_delta_cycles==100000000 and row.mperf_delta_cycles==200000000)
assert(math.abs(row.effective_hz-100000000*1e9/row.interval_ns)<1e-6)
assert(row.active_performance_ratio==0.5 and row.interval_ns>=100000000)
assert(row.observed_at_ns>=fresh.sample_started_ns and row.observed_at_ns<=fresh.sample_finished_ns)
local snapshot=Snapshot.merge(nil,{cpu_clocks=fresh},1,Native.monotonic_ns())
write(control,"1\n")
local pending=reader:sample(context);assert(pending.sampling_pending)
snapshot=Snapshot.merge(snapshot,{cpu_clocks=pending},2,Native.monotonic_ns())
assert(snapshot.quality.cpu_clocks.quality=="stale" and snapshot.cpu_clocks.cpus[1].effective_hz==row.effective_hz)
local other=Hardware.new(require("wtop.collectors.cpufreq").new())
local deadline=Native.monotonic_ns()+3e9
repeat
 local r=other:sample(context)
 assert(r.reason~="hardware_query_timeout")
 if not r.sampling_pending then break end
 assert(Native.monotonic_ns()<deadline);Native.sleep_ms(10)
until false
settle(3,function(r)return r.reason=="hardware_query_timeout" end)
local f=assert(io.open(entered,"rb"));local pid=assert(tonumber(f:read("a")));f:close()
deadline=Native.monotonic_ns()+1e9
while Native.access("/proc/"..pid,"f") do assert(Native.monotonic_ns()<deadline,"clock child not reaped");Native.sleep_ms(10)end
write(control,"0\n")
local recovered=settle(9,function(r)return r.data~=nil end)
assert(recovered.data.cpus[1].reason=="cpu_clock_warmup" and recovered.data.cpus[1].effective_hz==nil)
assert(recovered.data.cpus[1].observed_at_ns>row.observed_at_ns)
reader:close();other:close()
print("ok: actual fixed counter worker, per-CPU bracket/interval arithmetic, idle warmup, timeout/reap, independent source and new-epoch recovery")
