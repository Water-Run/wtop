package.path="./src/?.lua;./src/?/init.lua;"..package.path
local Windows=require("wtop.collectors.windows_gpu")
local ADL=require("wtop.collectors.adl")
local Export=require("wtop.export")
local now,failed=1e9,false
local base={probe=function()return{available=true}end,sample=function()
 return{status="ok",timestamp_ns=now,value_timestamp_ns=now,quality="fresh",data={devices={
  {id="amd",card="GPU0",pci_bdf="0000:01:00.0",vendor_id="0x1002",device_id="0x6613",driver="driver",
   identity_quality="fresh",metrics={utilization_percent=10},quality={},capabilities={}}
 }}}
end}
local function sdk()
 if failed then return nil,"adl_query_timeout"end
 return{status="ok",initialization="adl2",transport="process",sample_started_ns=now,sample_finished_ns=now,devices={
  {index=9,pci_bdf="0000:01:00.0",vendor_id=0x1002,device_id=0x6613,name="SDK AMD",identity_verified=true,
   active=true,present=true,power_watts=22.5,power_scope="asic",temperature_celsius=43.25,graphics_clock_hz=3e8,
   fan_speed_percent=25,fan_speed_rpm=1200,power_status=0,activity_status=0,temperature_status=0,fan_status=0,
   power_control_offset=20,partial=false},
 }}
end
local c=Windows.new(base,{nvml_provider=false,levelzero_provider=false,adl_provider=sdk},{})
local ctx={now_ns=function()return now end}
local first=c:sample(ctx);assert(#first.data.devices==1)
local gpu=first.data.by_id.amd
assert(gpu.metrics.power_watts==22.5 and gpu.metrics.power_scope=="asic")
assert(gpu.metrics.power_limit_watts==nil,"PowerTune offset became a cap in watts")
assert(gpu.metrics.utilization_percent==10 and gpu.metrics.temperature_celsius==43.25)
assert(gpu.metrics.fan_speed_rpm==1200 and gpu.adl.adapter_index==9)
assert(gpu.metric_observations.power_watts.source=="adl")
local snapshot={gpus=first.data,timestamp_ns=now,quality={gpus={status="ok",quality="fresh"}}}
local exported=Export.snapshot(snapshot)
assert(exported.gpus.devices[1].metrics.power_limit_percent==nil)
assert(exported.gpus.devices[1].adl.query_status.power_status==0)
local agent=Export.agent(snapshot)
assert(agent.top.gpus[1].metrics.power_scope=="asic")
now=2e9;failed=true
local stalled=c:sample(ctx);gpu=stalled.data.by_id.amd
assert(gpu.metrics.power_watts==22.5 and gpu.quality.power=="stale")
assert(gpu.metric_observations.power_watts.observed_at_ns==1e9 and gpu.adl.quality=="stale")
c:close()
-- No telemetry on inactive OS-known entries must not fabricate another card.
local rows={};local status=ADL.merge(rows,{status="partial",devices={{index=0,identity_verified=true,
 pci_bdf="0000:01:00.0",present=false,active_status=-5,power_status=-8,partial=true}}},{by_bdf={}},{})
assert(#rows==0 and status.unmatched_devices==1 and status.diagnostics[1].power_status==-8)
-- A different device behind the same PCI slot must never inherit AMD power.
local changed=Windows.new({probe=base.probe,sample=function()
 local value=base:sample();value.data.devices[1].device_id="0x9999";return value
end},{nvml_provider=false,levelzero_provider=false,adl_provider=function()failed=false;return sdk()end},{})
local conflict=changed:sample(ctx)
assert(conflict.data.by_id.amd.metrics.power_watts==nil)
changed:close()
-- Malformed identities and out-of-range SDK fields stay out of displayed values.
rows={};status=ADL.merge(rows,{devices={{identity_verified=false,pci_bdf="0000:01:00.0",power_watts=50}}},{by_bdf={}},{})
assert(#rows==0 and status.unmatched_devices==1)
rows={};ADL.merge(rows,{devices={{identity_verified=true,present=true,pci_bdf="0000:01:00.0",
 utilization_percent=101,fan_speed_percent=1000,power_watts=math.huge,graphics_clock_hz=-1}}},{by_bdf={}},{})
assert(#rows==1 and next(rows[1].metrics)==nil)
return true
