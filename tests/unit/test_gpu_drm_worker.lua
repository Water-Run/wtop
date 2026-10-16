package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local GPU=require("wtop.collectors.gpu")
local Input=require("wtop.collectors.gpu_drm")
local Worker=require("wtop.collectors.gpu_drm_worker")
local Fixture=require("support.fixture_fs")
local Hardware=require("support.hardware_fixtures")
local Wire=require("wtop.core.worker_wire")
local Export=require("wtop.export")
local now,mode,closes=1000000000,"fresh",0
local spec=Hardware.drm_amdgpu()
spec.dirs={["/sys/class/drm"]={"card0"},["/proc"]={}}
local fs=Fixture.new(spec)
local context={fs=fs,now_ns=function() return now end,scan_gpu_processes=false}
local input=Input.new({fs=fs,scan_processes=false})
local raw=input:sample(context)
local denied_input=Input.new({fs={list=function() return nil,{kind="denied",message="permission denied"} end}}):sample({now_ns=context.now_ns})
assert(denied_input.status=="denied" and denied_input.capability.state=="denied" and not denied_input.capability.available)
assert(raw.status=="ok" and #raw.data.devices==1 and raw.data.by_id==nil)
assert(raw.data.devices[1].metrics.utilization_percent==73)
raw.transport,raw.sample_started_ns,raw.sample_finished_ns,raw.value_timestamp_ns="process",900000000,now,now
local bytes=Wire.encode(raw)
local worker=Worker.new({reader={probe=function() return {available=true} end,sample=function()
    if mode=="fresh" then return Wire.decode(bytes) end
    if mode=="empty" then local empty=Wire.decode(bytes);empty.data.devices={};empty.data.anchors={};return empty end
    return {status="error",quality="stale",reason=mode,timestamp_ns=now,
        sampling_pending=mode=="hardware_query_pending",defer_publish=mode=="hardware_query_pending",retry_after_ms=25}
end,close=function() closes=closes+1 end}})
-- No parent filesystem access is needed for DRM enumeration, attributes,
-- fdinfo or SDK process names once the worker is attached.
local forbidden=setmetatable({},{__index=function(_,key) return function() error("parent filesystem: "..key) end end})
local sdk,other=false,false
local collector=GPU.new({fs=forbidden,nvml=false,levelzero=false,scan_processes=false,amdsmi=function()
    if not sdk and not other then return nil,"amdsmi_query_pending" end
    return {sample_started_ns=now,devices={{pci_bdf=other and "0000:02:00.0" or "0000:01:00.0",
        uuid="GPU-live",name="Live AMD",utilization_percent=20,power_watts=30,power_limit_watts=60}}}
end})
collector._drm_worker=worker
local ctx={now_ns=context.now_ns,scan_gpu_processes=false}
local first=collector:sample(ctx)
assert(first.data.devices[1].metric_observations.utilization_percent.observed_at_ns==1000000000)
first.data.devices[1].metrics.utilization_percent=999
now,mode=2000000000,"hardware_query_pending"
local stale=collector:sample(ctx,first)
local card=stale.data.devices[1]
assert(stale.quality=="stale" and not stale.capability.available and stale.sampling_pending)
assert(stale.value_timestamp_ns==1000000000 and stale.defer_publish)
assert(card.metrics.utilization_percent==73 and card.quality.utilization=="stale")
assert(card.identity_quality=="stale" and #card.processes.list==0 and not card.capabilities.processes)
assert(card.metric_observations.utilization_percent.retained)
assert(card.metric_observations.utilization_percent.observed_at_ns==1000000000)
assert(card.frequencies.domains[1].quality=="stale")
assert(Export.agent({gpus=stale.data,quality={gpus={status="ok",quality="stale"}}}).metrics.gpu.maximum_utilization_percent==nil)
-- Live SDK telemetry wins over retained DRM fields on the same bus address.
sdk=true;now=3000000000
local mixed=collector:sample(ctx,stale)
card=mixed.data.devices[1]
assert(#mixed.data.devices==1 and card.metrics.utilization_percent==20 and card.quality.utilization=="fresh")
assert(card.metric_observations.utilization_percent.source=="amdsmi")
assert(card.metric_observations.utilization_percent.observed_at_ns==now)
assert(mixed.capability.available and mixed.quality=="partial" and not mixed.defer_publish)
assert(card.quality.frequency=="stale" and card.metrics.frequency_current_hz==1500000000)
-- A healthy different GPU does not hide the old GPU's failed DRM source.
other=true;now=4000000000;mode="hardware_query_timeout"
local separate=collector:sample(ctx,mixed)
assert(#separate.data.devices==2 and separate.data.providers.drm.quality=="stale")
assert(separate.data.by_id["0000:01:00.0"].metrics.utilization_percent==73)
assert(separate.data.by_id["0000:01:00.0"].quality.utilization=="stale")
assert(separate.data.by_id["0000:02:00.0"].quality.power=="fresh")
local agent=Export.agent({gpus=separate.data,quality={gpus={status="ok",quality="partial"}}})
assert(agent.metrics.gpu.providers.drm.retained and agent.metrics.gpu.providers.drm.observed_at_ns==1000000000)
assert(agent.metrics.gpu.providers.drm.reason=="hardware_query_timeout")
assert(agent.metrics.gpu.maximum_utilization_percent==20)
-- A confirmed empty inventory invalidates the retained device; it cannot
-- resurrect on the next timeout. The private cache never aliases a snapshot.
sdk,other=false,false;now=5000000000;mode="empty"
collector:sample(ctx,separate)
mode="hardware_query_timeout";now=6000000000
local removed=collector:sample(ctx)
for _,device in ipairs(removed.data and removed.data.devices or {}) do assert(device.pci_bdf~="0000:01:00.0") end
collector:stop();assert(closes==1)
collector:stop();assert(closes==1)

-- An unconsumed probe frame must follow both safe mode and the deep-scan
-- policy. Changing pages cannot consume the previous page's shallow frame.
local old_native,old_worker=package.loaded["wtop.native"],package.loaded["wtop.collectors.hardware_worker"]
local queries=0
package.loaded["wtop.native"]={available=true,hardware_worker_open=function() return {} end,
    hardware_worker_query=function(_,safe,wait,scan)
        queries=queries+1;assert(wait==0 and not safe)
        local response=Wire.decode(bytes);response.result=nil
        response.data.process_scan.enabled=scan
        return Wire.encode({capability={available=true},result=response}),{sample_started_ns=900000000,sample_finished_ns=1000000000}
    end,hardware_worker_close=function() end}
package.loaded["wtop.collectors.hardware_worker"]=nil
local proxy=require("wtop.collectors.hardware_worker").new({id="gpu_drm",default_interval_ms=1000})
now=1000000000;ctx.scan_gpu_processes=false
assert(proxy:probe(ctx).available and queries==1)
ctx.scan_gpu_processes=true
assert(proxy:sample(ctx).data.process_scan.enabled and queries==2)
proxy:close()
package.loaded["wtop.native"],package.loaded["wtop.collectors.hardware_worker"]=old_native,old_worker
print("ok: independent DRM input, private retention, live SDK precedence, stale clocks/processes and confirmed removal")

-- Fast polling of DRM is independent of the SDK energy sampling window.
-- The prefetched SDK frame starts at the previous query, so consuming it too
-- early produces another warmup instead of a current watt reading.
do
 local time,queries,queued,previous=1000000000,0,nil,nil
 local gpu=GPU.new({fs=forbidden,nvml=false,amdsmi=false,levelzero=function()
  queries=queries+1
  local observed=queued or time;queued=time
  local watts=previous and observed-previous>=100000000 and 30 or nil
  if not previous or observed-previous>=100000000 then previous=observed end
  return {sample_started_ns=observed,devices={{pci_bdf="0000:02:00.0",power_watts=watts,
   power_limit_watts=60,power_quality=watts and "fresh" or "gap",
   power_reason=not watts and "levelzero_power_warmup" or nil}}}
 end})
 local w=Worker.new({reader={sample=function()
  return {status="error",quality="stale",timestamp_ns=time,reason="hardware_query_pending",
    sampling_pending=true,retry_after_ms=25}
 end,close=function() end}})
 gpu._drm_worker=w
 local c={now_ns=function() return time end,scan_gpu_processes=false}
 gpu:sample(c)
 time=time+250000000;gpu:sample(c)
 for _=1,3 do time=time+25000000;gpu:sample(c) end
 assert(queries==2,"DRM polling consumed SDK energy frames before their minimum interval")
 time=time+25000000
 local ready=gpu:sample(c)
 assert(queries==3 and ready.data.devices[1].metrics.power_watts==30)
 local observed=ready.data.devices[1].metric_observations.power_watts.observed_at_ns
 time=time+25000000
 local held=gpu:sample(c)
 assert(queries==3 and held.data.devices[1].quality.power=="fresh")
 assert(held.data.devices[1].metric_observations.power_watts.observed_at_ns==observed)
 assert(held.value_timestamp_ns==observed,"cached SDK reply renewed the resource observation time")
 gpu:stop()
end
