package.path="./src/?.lua;./src/?/init.lua;./tests/?.lua;"..package.path
local Clock=require("wtop.collectors.cpu_clocks")
local Fixture=require("support.fixture_fs")
local Snapshot=require("wtop.model.snapshot")
local Export=require("wtop.export")
local View=require("wtop.view_model")
local I18n=require("wtop.i18n")
local root="/sys/devices/system/cpu"
local files={[root.."/online"]="0-1\n"}
local info={}
for id=0,1 do
 info[#info+1]="processor : "..id.."\nvendor_id : GenuineIntel\ncpu family : 6\nmodel : 186\nflags : msr aperfmperf\n\n"
 files[root.."/cpu"..id.."/topology/physical_package_id"]="0\n"
 files[root.."/cpu"..id.."/topology/core_id"]="0\n"
end
files["/proc/cpuinfo"]=table.concat(info)
local fs=Fixture.new({files=files})
local now,mode=1000000010,"good"
local counters={{a=5000000000,m=6000000000},{a=7000000000,m=8000000000}}
local function reader(id)
 if mode=="denied" then return nil,"permission denied",13 end
 if mode=="partial" and id==0 then return nil,"permission denied",13 end
 if mode=="hotplug" and id==0 then files[root.."/online"]="1\n" end
 local c=counters[id+1]
 local span=mode=="skew" and 20000000 or 4
 return string.pack("<i8i8",c.a,c.m),{aperf_started_ns=now-span,
  aperf_finished_ns=now-span+1,mperf_started_ns=now-2,mperf_finished_ns=now-1}
end
local clock=Clock.new({fs=fs,reader=reader})
local context={now_ns=function() return now end}
assert(Clock.new({fs=fs}):sample(context).reason=="cpu_clock_reader_unavailable",
    "fixture filesystems must not read the host's MSR counters")
local first=clock:sample(context)
assert(first.status=="ok" and first.sampling_pending and first.data.measured_cpus==0)
assert(first.data.cpus[1].effective_hz==nil and first.data.cpus[1].quality=="gap")
local missing=Clock.new({fs=fs,reader=function() return nil,"missing device",2 end}):sample(context)
assert(not missing.capability.available and missing.capability.state=="unavailable")
assert(missing.data.cpus[1].quality=="unavailable" and missing.data.read_cpus==0)
now=now+1000000000;counters[1].a=counters[1].a+1000000000;counters[1].m=counters[1].m+2000000000
local measured=clock:sample(context)
local a,b=measured.data.cpus[1],measured.data.cpus[2]
assert(a.effective_hz==1000000000 and a.active_performance_ratio==0.5 and a.interval_ns==1000000000)
assert(b.effective_hz==0 and b.active_performance_ratio==nil,"idle is zero executed cycles, not the busy or requested clock")
assert(a.observed_at_ns==now-4 and a.sample_span_ns==3 and a.interval_uncertainty_ns==2)
assert(a.aperf_delta_cycles==1000000000 and a.mperf_delta_cycles==2000000000)
assert(measured.data.measured_cpus==2 and measured.data.includes_idle)
local state=Snapshot.merge(nil,{cpu_clocks=measured},1,now)
state.cpu={cores={{name="cpu0",utilization=10},{name="cpu1",utilization=0}}}
local exported=Export.snapshot(state)
assert(exported.cpu_clocks.average_effective_hz==500000000 and exported.cpu_clocks.minimum_effective_hz==0)
local agent=Export.agent(state,{device_limit=1}).metrics.cpu.effective_clocks
assert(agent.measured_cpus==2 and #agent.cpus==1 and agent.truncated and agent.maximum_effective_hz==1000000000)
local i18n=assert(I18n.new({locale="en-US"}))
local rows=View.build({history_values=function()return{}end},state,i18n,{},"compute").core_table.rows
assert(rows[1].effective_value==1000000000 and rows[2].effective_value==0)
assert(rows[1].effective_window=="1000.0 ms")
state.cpu_info={topology={quality="fresh",logical_cpus={{id=0,package_id=0,core_id=0,
 core_key="p0:c0",package_id_known=true,core_id_known=true,online=true}}}}
local detail=table.concat(require("wtop.tui").hardware_detail_lines(state,"cpu:0",i18n,now+100),"\n")
assert(detail:find("Effective clock includes idle time",1,true) and detail:find("APERF / MPERF:",1,true))
assert(detail:find("Window:",1,true) and detail:find("Interval uncertainty:",1,true))
assert(detail:find("Quality: Fresh",1,true) and not detail:find("Effective: —",1,true))
state=Snapshot.merge(state,{cpu_clocks={status="error",quality="stale",timestamp_ns=now+100,
 reason="hardware_query_timeout"}},2,now+100)
assert(Export.agent(state).metrics.cpu.effective_clocks.average_effective_hz==nil)
rows=View.build({history_values=function()return{}end},state,i18n,{},"compute").core_table.rows
assert(rows[1].effective_value==nil and rows[1].effective==i18n:t("status.stale"))
detail=table.concat(require("wtop.tui").hardware_detail_lines(state,"cpu:0",i18n,now+100),"\n")
assert(detail:find("Quality: Stale",1,true) and detail:find("Effective: —",1,true))

-- Small polls keep the original baseline; no 25 ms frame is called a rate.
clock=Clock.new({fs=fs,reader=reader});clock:sample(context)
for _=1,3 do
 now=now+25000000;counters[1].a=counters[1].a+50000000;counters[1].m=counters[1].m+25000000
 local short=clock:sample(context);assert(short.sampling_pending and short.data.cpus[1].effective_hz==nil)
end
now=now+25000000;counters[1].a=counters[1].a+50000000;counters[1].m=counters[1].m+25000000
assert(clock:sample(context).data.cpus[1].effective_hz==2000000000)
mode="denied";now=now+1000000000
local denied=clock:sample(context)
assert(denied.data.denied_cpus==2 and denied.capability.state=="denied" and not denied.capability.available)
assert(denied.data.cpus[1].effective_hz==nil)
mode="good";now=now+1000000000
assert(clock:sample(context).data.cpus[1].effective_hz==nil,"a denial must clear the counter baseline")
now=now+1000000000;counters[1].a=0;counters[1].m=0
local reset=clock:sample(context)
assert(reset.data.cpus[1].quality=="gap" and reset.data.cpus[1].reason=="cpu_clock_counter_reset")
mode="skew";now=now+1000000000
local skew=clock:sample(context)
assert(skew.data.cpus[1].quality=="gap" and skew.data.cpus[1].reason=="cpu_clock_sample_skew")
mode="hotplug";now=now+1000000000
local changed=clock:sample(context)
assert(changed.data.measured_cpus==0 and changed.data.cpus[1].reason=="cpu_clock_identity_changed")
mode="good";now=now+1000000000
local offline=clock:sample(context)
assert(#offline.data.cpus==1 and offline.data.cpus[1].id==1 and offline.data.cpus[1].effective_hz==nil)
files[root.."/online"]="0-1\n"
-- A real 64-bit rollover remains exact, including the signed Lua boundary.
clock=Clock.new({fs=fs,reader=reader});counters[1]={a=-10,m=-20};now=now+1000000000;clock:sample(context)
counters[1]={a=5,m=10};now=now+1000000000
local wrap=clock:sample(context).data.cpus[1]
assert(wrap.effective_hz==15 and wrap.aperf_delta_cycles==15 and wrap.mperf_delta_cycles==30)
files["/proc/cpuinfo"]=files["/proc/cpuinfo"]:gsub("186","92")
local calls=0
local unsupported=Clock.new({fs=fs,reader=function()calls=calls+1;error("unsupported MSR")end}):sample(context)
assert(unsupported.status=="unavailable" and calls==0)
print("ok: effective cycles/wall time, idle zero, private baselines, exact rollover, denied/reset/skew/hotplug and truthful UI/exports")
