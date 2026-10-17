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
-- Modern PMLog keeps API access time distinct from an unknown hardware timestamp.
failed=false;now=3e9
local function modern_sdk()
 local data=sdk();local d=data.devices[1]
 d.power_watts=37;d.power_measurement="driver_snapshot";d.hotspot_temperature_celsius=79
 d.graphics_voltage_volts=.95;d.pmlog_method="shared_memory";d.pmlog_valid_sensors=9
 d.pmlog_invalid_sensors=0;d.pmlog_status=0;d.pmlog_requested_period_ms=1000
 d.pmlog_fields=511
 return data
end
local modern=Windows.new(base,{nvml_provider=false,levelzero_provider=false,adl_provider=modern_sdk},{})
local sampled=modern:sample(ctx);local pm=sampled.data.by_id.amd
assert(pm.metrics.power_watts==37 and pm.metrics.hotspot_temperature_celsius==79 and pm.metrics.graphics_voltage_volts==.95)
assert(pm.metrics.power_measurement=="driver_snapshot" and pm.metrics.power_limit_watts==nil)
assert(pm.adl.pmlog_method=="shared_memory" and pm.adl.hardware_timestamp_available==false and pm.adl.requested_period_ms==1000)
assert(pm.metric_observations.hotspot_temperature_celsius.observed_at_ns==3e9)
assert(pm.metric_observations.graphics_voltage_volts.source=="adl")
assert(pm.metric_observations.graphics_voltage_volts.method=="shared_memory")
assert(pm.metric_observations.graphics_voltage_volts.hardware_timestamp_available==false)
local current={gpus=sampled.data,timestamp_ns=now,quality={gpus={status="ok",quality="fresh"}}}
local agent_pm=Export.agent(current).top.gpus[1]
assert(agent_pm.metrics.hotspot_temperature_celsius==79 and agent_pm.metrics.graphics_voltage_volts==.95)
assert(agent_pm.metrics.power_measurement=="driver_snapshot" and agent_pm.adl.hardware_timestamp_available==false)
local ViewModel=require("wtop.view_model")
local TUI=require("wtop.tui")
local I18n=require("wtop.i18n")
for _,locale in ipairs({"en-US","zh-CN","zh-TW","fr-FR","de-DE","ja-JP","ko-KR","es-ES","pt-BR","ru-RU"})do
 local i18n=assert(I18n.new({locale=locale}))
 local _,gpu_rows=ViewModel.power_detail_rows(current,i18n)
 assert(gpu_rows[1].hotspot_temperature:find("79",1,true)and gpu_rows[1].graphics_voltage:find("0",1,true))
 local lines=table.concat(TUI.power_detail_lines(current,i18n),"\n")
 assert(lines:find(i18n:t("gpu.hotspot_temperature"),1,true),locale)
 assert(lines:find(i18n:t("gpu.graphics_voltage"),1,true),locale)
 assert(lines:find(i18n:t("power.measurement.driver_snapshot"),1,true),locale)
end
now=4e9;failed=true
local retained=modern:sample(ctx).data.by_id.amd
assert(retained.metrics.hotspot_temperature_celsius==79 and retained.metrics.graphics_voltage_volts==.95)
assert(retained.quality.temperature=="stale" and retained.quality.voltage=="stale")
assert(retained.metric_observations.graphics_voltage_volts.observed_at_ns==3e9 and retained.adl.hardware_timestamp_available==false)
assert(retained.metric_observations.graphics_voltage_volts.method=="shared_memory" and retained.metric_observations.graphics_voltage_volts.hardware_timestamp_available==false)
modern:close()
-- Range failures are absent; supported zero and sub-zero Celsius remain real readings.
rows={};ADL.merge(rows,{devices={{identity_verified=true,present=true,hotspot_temperature_celsius=-5,
 graphics_voltage_volts=0,power_watts=0,power_measurement="driver_snapshot"}}},{by_bdf={}},{})
assert(rows[1].metrics.hotspot_temperature_celsius==-5 and rows[1].metrics.graphics_voltage_volts==0 and rows[1].metrics.power_watts==0)
rows={};ADL.merge(rows,{devices={{identity_verified=true,present=true,hotspot_temperature_celsius=-200,
 graphics_voltage_volts=10.1}}},{by_bdf={}},{})
assert(rows[1].metrics.hotspot_temperature_celsius==nil and rows[1].metrics.graphics_voltage_volts==nil)
return true
