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

-- Two vendor sources have independent clocks, identity guards and failures.
local mixed_now,nvidia_wait,intel_wait=20e9,false,false
local intel_id=0x5600
local host_intel_id="0x5600"
local mixed_base={probe=function()return {available=true}end}
function mixed_base:sample()
 return {status="ok",quality="fresh",timestamp_ns=mixed_now,value_timestamp_ns=mixed_now,data={devices={
  {id="nvidia",pci_bdf="0000:01:00.0",vendor_id="0x10de",device_id="0x1234",driver="nvidia",
   identity_quality="fresh",metrics={utilization_percent=20},quality={},capabilities={}},
  {id="intel",pci_bdf="0000:02:00.0",vendor_id="0x8086",device_id=host_intel_id,driver="intel",
   identity_quality="fresh",metrics={utilization_percent=40},quality={},capabilities={}},
 }}}
end
local function intel_data()
 return {status="ok",sample_started_ns=mixed_now,sample_finished_ns=mixed_now,transport="process",devices={
  {index=0,vendor_id=0x8086,device_id=intel_id,pci_bdf="0000:02:00.0",uuid="intel-fixture",
   power_watts=30,power_limit_watts=40,power_quality="fresh",power_measurement="average",power_interval_ns=1e9,
   power_domains={{index=0,scope="card",quality="fresh",power_watts=30,interval_ns=1e9}},
   frequency_domains={{index=0,kind="gpu",actual_hz=8e8,throttle_quality="fresh",throttle_raw_hex="0x1"}},
  }}}
end
local mixed=Windows.new(mixed_base,{
 nvml_provider=function()
  if nvidia_wait then return nil,"nvml_query_timeout"end
  return {devices={{pci_bdf="0000:01:00.0",device_id="0x1234",power_watts=100,power_limit_watts=200,
   uuid="nvidia-fixture",power_quality="fresh"}},sample_started_ns=mixed_now,sample_finished_ns=mixed_now}
 end,
 levelzero_provider=function()
  if intel_wait then return nil,"levelzero_query_timeout"end
  return intel_data()
 end,
},{})
local mixed_context={now_ns=function()return mixed_now end}
local mixed_first=mixed:sample(mixed_context)
assert(#mixed_first.data.devices==2)
assert(mixed_first.data.by_id.intel.metrics.power_watts==30)
assert(mixed_first.data.by_id.intel.metrics.power_limit_watts==40)
assert(mixed_first.data.by_id.intel.metric_observations.power_watts.source=="levelzero")
assert(mixed_first.data.by_id.nvidia.metrics.power_watts==100)
local mixed_export=Export.snapshot({gpus=mixed_first.data})
assert(mixed_export.gpus.devices[2].metrics.power_limit_percent==75)
assert(mixed_first.data.by_id.intel.sysman.frequency_domains[1].actual_hz==8e8)
mixed_now=21e9;intel_wait=true
local intel_stalled=mixed:sample(mixed_context)
assert(intel_stalled.data.by_id.intel.quality.power=="stale")
assert(intel_stalled.data.by_id.intel.metric_observations.power_watts.observed_at_ns==20e9)
assert(intel_stalled.data.by_id.nvidia.metric_observations.power_watts.observed_at_ns==21e9)
assert(intel_stalled.data.by_id.intel.sysman.power_domains[1].quality=="stale")
mixed_now=22e9;intel_wait=false;nvidia_wait=true
local nvidia_stalled=mixed:sample(mixed_context)
assert(nvidia_stalled.data.by_id.intel.quality.power=="fresh")
assert(nvidia_stalled.data.by_id.intel.metric_observations.power_watts.observed_at_ns==22e9)
assert(nvidia_stalled.data.by_id.nvidia.quality.power=="stale")
mixed_now=23e9;intel_id=0x5601
local conflict=mixed:sample(mixed_context)
assert(conflict.data.by_id.intel.metrics.power_watts==nil)
mixed_now=24e9;intel_wait=true
local conflict_stalled=mixed:sample(mixed_context)
assert(conflict_stalled.data.by_id.intel.metrics.power_watts==nil,
 "a conflicting fresh SDK device cannot later leak retained power onto the host adapter")
assert(not _G.pending and not _G.warming,"collector state escaped its instance")
mixed:close()
print("ok: Windows Intel/NVIDIA power ratios, independent failures, Sysman limits and conflicting identity retention")

-- A missing Sysman property response cannot identify a vendor from the loader.
local unidentified=Windows.new(mixed_base,{nvml_provider=false,levelzero_provider=function()
 return {devices={{pci_bdf="0000:02:00.0",uuid="unknown-vendor",power_watts=30,power_quality="fresh"}},
  sample_started_ns=mixed_now,sample_finished_ns=mixed_now}
end},{})
local unknown=unidentified:sample(mixed_context)
assert(unknown.data.by_id.intel.metrics.power_watts==nil)
local separate
for _,row in ipairs(unknown.data.devices)do if row.vendor_uuid=="unknown-vendor"then separate=row end end
assert(separate and separate.vendor_id==nil,"the loader name became a fabricated PCI vendor")
unidentified:close()

-- Hex parsing on Lua integers wraps huge inputs; it must not forge PCI IDs.
local overflowed=Windows.new(mixed_base,{nvml_provider=false,levelzero_provider=function()
 return {devices={{pci_bdf="0000:02:00.0",vendor_id="0x10000000000008086",
  device_id="0x10000000000005600",uuid="overflowed-ids",power_watts=30,power_quality="fresh"}},
  sample_started_ns=mixed_now,sample_finished_ns=mixed_now}
end},{})
local rejected=overflowed:sample(mixed_context)
assert(rejected.data.by_id.intel.metrics.power_watts==nil,"overflowed PCI IDs forged a matching identity")
overflowed:close()

-- A normal base-worker round trip must reach Engine's publication gate.
-- If a vendor packet arrives independently, publish it with the older base
-- values explicitly retained, rather than claiming they were sampled again.
do
 local Engine=require("wtop.engine")
 local at,mode,pending_at,sdk_ready=1000000000,"fresh",nil,false
 local base={probe=function()return {available=true,state="available"}end,close=function()end}
 function base:sample()
  if mode=="pending" then
   return {status="error",quality="stale",reason="hardware_query_pending",timestamp_ns=at,
    sampling_pending=true,retry_after_ms=25,defer_publish=at-pending_at<100000000}
  end
  return {status="ok",quality="fresh",timestamp_ns=at,value_timestamp_ns=at,
   sample_started_ns=at,sample_finished_ns=at,transport="process",data={devices={{
    id="windows-pending",pci_bdf="0000:01:00.0",vendor_id="0x10de",device_id="0x1234",
    identity_quality="fresh",driver="test",metrics={utilization_percent=20},quality={utilization="fresh"}}}}}
 end
 local collector=Windows.new(base,{levelzero_provider=false,adl_provider=false,nvml_provider=function()
  if not sdk_ready then return nil,"nvml_library_not_found"end
  return {sample_started_ns=at,sample_finished_ns=at,devices={{index=0,pci_bdf="0000:01:00.0",
   power_watts=25,power_limit_watts=50,power_quality="fresh",power_measurement="device_sample"}}}
 end},{})
 local engine=Engine.new({collectors={gpu=collector},clock={now_ns=function()return at end,
  wall_ns=function()return 1700000000000000000+at end}})
 engine:probe();local initial=engine:tick(true);local sequence=initial.sequence
 local history_samples=engine:history_values("gpu").n
 mode="pending";at=1025000000;pending_at=at
 local waiting,completed=engine:tick(true)
 assert(completed.gpu==nil and waiting==initial and waiting.sequence==sequence,
  "Windows wrapper published a normal base-worker pending poll")
 assert(engine.pending_collectors.gpu and engine.scheduler:task("gpu").last_result.defer_publish)
 assert(engine:history_values("gpu").n==history_samples,"a deferred poll appended duplicate GPU history")
 local retained=engine.scheduler:task("gpu").last_result.data.devices[1]
 assert(retained.metric_observations.utilization_percent.retained
  and retained.metric_observations.utilization_percent.observed_at_ns==1000000000)
 at=1126000000;local stale,published=engine:tick(true)
 assert(published.gpu and published.gpu.quality=="partial" and not published.gpu.defer_publish)
 assert(stale.gpus.devices[1].metric_observations.utilization_percent.quality=="stale")
 assert(stale.gpus.providers.windows.retained and stale.gpus.providers.windows.reason=="hardware_query_pending")
 assert(Export.agent(stale).metrics.gpu.maximum_utilization_percent==nil)
 mode="fresh";at=1500000000;local recovered=engine:tick(true)
 assert(recovered.gpus.devices[1].metric_observations.utilization_percent.quality=="fresh")
 assert(recovered.gpus.devices[1].metric_observations.utilization_percent.observed_at_ns==at)
 mode="pending";at=1625000000;pending_at=at;sdk_ready=true
 local independent,changed=engine:tick(true)
 assert(changed.gpu and not changed.gpu.defer_publish,"base polling hid an independent vendor packet")
 local gpu=independent.gpus.devices[1]
 assert(gpu.metric_observations.utilization_percent.retained
  and gpu.metric_observations.utilization_percent.quality=="stale"
  and gpu.metric_observations.utilization_percent.observed_at_ns==1500000000)
 assert(gpu.metric_observations.power_watts.quality=="fresh"and gpu.metric_observations.power_watts.observed_at_ns==at)
 assert(Export.snapshot(independent).gpus.devices[1].metrics.power_limit_percent==50)
 mode="fresh";at=2000000000;engine:tick(true)
 mode="pending";at=2125000000;pending_at=at;sdk_ready=false
 local failed,failed_completed=engine:tick(true)
 assert(failed_completed.gpu and not failed_completed.gpu.defer_publish,
  "base polling delayed an independent vendor failure")
 assert(failed.gpus.devices[1].metric_observations.power_watts.retained)
 assert(Export.snapshot(failed).gpus.devices[1].metrics.power_limit_percent==nil)
 engine:stop()

 -- The same publication grace applies to a confirmed empty host inventory.
 at=2000000000;mode="fresh"
 local empty_base={probe=base.probe,close=base.close,sample=function()
  if mode=="pending"then return {status="error",reason="hardware_query_pending",timestamp_ns=at,
   sampling_pending=true,retry_after_ms=25,defer_publish=true}end
  return {status="ok",timestamp_ns=at,data={devices={}}}
 end}
 local empty=Windows.new(empty_base,{nvml_provider=false,levelzero_provider=false,adl_provider=false},{})
 assert(empty:sample({now_ns=function()return at end}).status=="unavailable")
 mode="pending";at=2025000000
 local waiting_empty=empty:sample({now_ns=function()return at end})
 assert(waiting_empty.defer_publish and waiting_empty.sampling_pending)
 empty:close()
end
