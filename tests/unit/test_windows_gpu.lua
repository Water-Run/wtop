package.path="./src/?.lua;./src/?/init.lua;"..package.path
local Windows=require("wtop.collectors.windows_gpu")
local Export=require("wtop.export")
local now,fail_base,fail_sdk,vendor,device,queries,enabled=1e9,false,false,"0x10de","0x1234",0,true
local input
local base={probe=function() return {available=false,state="unavailable"} end}
function base:sample()
  if fail_base then return {status="error",reason="hardware_query_timeout"} end
  input={devices={{id="0000:01:00.0",pci_bdf="0000:01:00.0",vendor_id=vendor,device_id=device,
    identity_quality="fresh",driver="test",metrics={utilization_percent=20},quality={utilization="fresh"},
    capabilities={},processes={list={{pid=333}}}}}}
  return {status="ok",timestamp_ns=now,value_timestamp_ns=now,sample_started_ns=now,
    sample_finished_ns=now,data=input,quality="fresh",transport="process"}
end
function base:close() self.closed=true end
local function sdk(scan)
  queries=queries+1;assert(scan==enabled)
  if fail_sdk then return nil,"nvml_query_timeout" end
  return {status="ok",transport="process",sample_started_ns=now,sample_finished_ns=now,
    devices={{index=0,uuid="gpu-test",pci_bdf="00000000:01:00.0",vendor_id="0x10de",device_id="0x1234",
      power_watts=100,power_limit_watts=200,power_measurement="device_sample",power_quality="fresh",
      clock_events={current_mask_hex="0x0000000000000004",supported_mask_hex="0x00000000000007ff",
        quality="fresh",source="nvmlDeviceGetCurrentClocksEventReasons"},
      processes=scan and {{pid=444,used_gpu_memory_bytes=1024}} or nil}}}
end
local context={now_ns=function() return now end,scan_gpu_processes=true}
local collector=Windows.new(base,{nvml_provider=sdk},{})
assert(collector:probe(context).available)
local first=collector:sample(context)
assert(first.status=="ok" and #first.data.devices==1)
local one=first.data.devices[1]
assert(one.metrics.power_watts==100 and one.metrics.power_limit_watts==200)
assert(one.metrics.utilization_percent==20 and one.metric_observations.power_watts.source=="nvml")
assert(one.metric_observations.power_watts.observed_at_ns==1e9)
assert(input.devices[1].metrics.power_watts==nil,"SDK merge modified cached host inventory")
now=2e9;fail_sdk=true
local second=collector:sample(context)
local two=second.data.devices[1]
assert(second.quality=="partial" and two.metrics.power_watts==100 and two.quality.power=="stale")
assert(two.metric_observations.power_watts.observed_at_ns==1e9 and two.quality.utilization=="fresh")
assert(second.data.providers.nvml.retained and second.data.providers.nvml.reason=="nvml_query_timeout")
local exported=Export.snapshot({gpus=second.data})
assert(exported.gpus.devices[1].metrics.power_limit_percent==nil,"stale watts became a current percentage")
now=3e9;device="0x5678"
local replaced=collector:sample(context)
assert(replaced.data.devices[1].metrics.power_watts==nil,"old SDK power crossed a changed host identity")
now=4e9;fail_sdk=false
local changed=collector:sample(context)
assert(#changed.data.devices==2 and changed.data.devices[1].metrics.power_watts==nil)
now=5e9;device="0x1234";context.safe_mode=true
local before=queries;local safe=collector:sample(context)
assert(queries==before and safe.data.devices[1].metrics.power_watts==nil)
assert(safe.data.providers.nvml.reason=="safe_mode")
now=6e9;context.safe_mode=false;fail_base=true
local independent=collector:sample(context)
assert(independent.status=="ok" and independent.data.devices[1].metrics.power_watts==100)
assert(independent.data.devices[1].quality.utilization=="stale")
now=7e9;enabled=false;context.scan_gpu_processes=false
local shallow=collector:sample(context)
assert(shallow.data.devices[1].processes==nil or #shallow.data.devices[1].processes.list==0)
collector:close();assert(base.closed)
assert(collector:sample(context).reason=="hardware_worker_closed")

-- No host inventory must still permit headless SDK discovery.
now=8e9
local absent={probe=function()return {available=false}end,sample=function()return {status="unavailable",reason="no_display_adapters"}end}
local headless=Windows.new(absent,{nvml_provider=sdk},{})
assert(headless:probe(context).available)
local found=headless:sample(context)
assert(found.status=="ok" and #found.data.devices==1 and found.data.devices[1].source=="nvml")
assert(found.data.devices[1].metrics.power_watts==100)
print("ok: independent Windows inventory/NVML power, stale timestamps, identity guards, safe mode, scan policy and headless discovery")

-- A backwards clock invalidates cached observations, including the short
-- pending grace period. No measurement from the future may be republished.
local at=10e9;local wait=false
local no_base={probe=function()return {available=true}end,sample=function()return {status="unavailable"}end}
local reset=Windows.new(no_base,{nvml_provider=function()
 if wait then return nil,"nvml_query_pending" end
 return {devices={{index=0,uuid="clock-reset",power_watts=9}},sample_started_ns=at,sample_finished_ns=at}
end},{})
local reset_context={now_ns=function()return at end}
assert(reset:sample(reset_context).status=="ok")
at=9e9;wait=true
local after_reset=reset:sample(reset_context)
assert(after_reset.status=="unavailable" and after_reset.data==nil and after_reset.sampling_pending)

-- A valid host reply may exceed the smaller SDK retention cache budget.
-- Copying inventory uses the transport budget and still leaves its source
-- immutable when the vendor merge adds metrics.
local large={devices={{id="0000:01:00.0",pci_bdf="0000:01:00.0",vendor_id="0x10de",device_id="0x1234",
 driver="test",identity_quality="fresh",metrics={},quality={},capabilities={},processes={list={}}}}}
for i=1,1024 do large.devices[1].processes.list[i]={pid=i,name=string.rep("x",1200)} end
local big_base={probe=function()return {available=true}end,sample=function()return {status="ok",timestamp_ns=now,data=large}end}
enabled=true;fail_sdk=false
local big=Windows.new(big_base,{nvml_provider=sdk},{})
local big_result=big:sample({now_ns=function()return now end})
assert(big_result.status=="ok" and #big_result.data.devices[1].processes.list==1024)
assert(big_result.data.devices[1].metrics.power_watts==100 and large.devices[1].metrics.power_watts==nil)
