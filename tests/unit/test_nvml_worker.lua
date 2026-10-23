package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local NVML = require("wtop.collectors.nvml")
local GPU = require("wtop.collectors.gpu")
local Engine = require("wtop.engine")
local Export = require("wtop.export")
local Fixture = require("support.fixture_fs")

-- Delivery-time field age can differ from SDK-read-time field age. Retain the
-- original values, but choose the genuinely fresh measurement for the bar.
local fields = {devices={{power_measurement="current",power_watts=300,power_quality="fresh",
  power_instant_watts=300,power_instant_timestamp_us=4900000,
  power_average_watts=40,power_average_timestamp_us=6000000}}}
NVML.refresh_power(fields,10000000)
local device=fields.devices[1]
assert(device.power_instant_quality=="stale" and device.power_average_quality=="fresh")
assert(device.power_watts==40 and device.power_measurement=="average" and device.power_interval_ns==1000000000)
NVML.refresh_power(fields,12000000)
assert(device.power_quality=="stale")
device.power_instant_timestamp_us=15000001
NVML.refresh_power(fields,12000000)
assert(device.power_instant_quality=="gap" and device.power_quality=="gap")
local legacy={devices={{power_measurement="device_sample",power_quality="fresh",power_watts=0}}}
NVML.refresh_power(legacy,12000000)
assert(legacy.devices[1].power_watts==0 and legacy.devices[1].power_quality=="fresh")

-- The default provider must not fall back to a main-process SDK call when a
-- stale or partial native module lacks the process transport.
local original=package.loaded["wtop.native"]
package.loaded["wtop.native"]={nvml_query=function() error("unsafe provider called") end}
assert(NVML.default_provider()==nil)
local opened,closed,queried=0,0,0
package.loaded["wtop.native"]={
  nvml_worker_open=function() opened=opened+1;return {} end,
  nvml_worker_query=function(_,processes) queried=queried+1;assert(processes==true);return {devices={}} end,
  nvml_worker_close=function() closed=closed+1 end,
  realtime_ns=function() return 10000000000 end,
  nvml_query=function() error("unsafe provider called") end,
}
local provider,stop=NVML.default_provider()
assert(provider(true) and opened==1 and queried==1)
stop();assert(closed==1)
local attempts=0
package.loaded["wtop.native"].nvml_worker_open=function()
  attempts=attempts+1;if attempts==1 then error("constructor allocation failed") end;return {}
end
provider,stop=NVML.default_provider()
local missing,why=provider(true)
assert(not missing and why=="nvml_allocation_failed")
assert(provider(true) and attempts==2,"transient constructor OOM must remain retryable")
stop()
package.loaded["wtop.native"]=original

-- A headless NVML device may appear after probe. The source and the exported
-- capability move from pending to available without a fake DRM node or a new
-- Engine; the two-sample CLI keeps the same capability-table reference.
local fs=Fixture.new({dirs={["/sys/class/drm"]={},["/proc"]={}}})
local calls,now,failed=0,3000000000,false
local collector=GPU.new({fs=fs,scan_processes=false,amdsmi=false,levelzero=false,nvml=function()
  calls=calls+1
  if failed then return nil,"nvml_query_timeout" end
  if calls<3 then return nil,"nvml_query_pending" end
  return {status="ok",transport="process",sample_started_ns=2000000000,sample_finished_ns=2100000000,
    devices={{index=0,uuid="GPU-delayed",pci_bdf="00000000:01:00.0",vendor_id="0x10de",
      utilization_percent=25,power_watts=40,power_limit_watts=80,power_quality="fresh",
      clock_events={status_code=0,raw_hex="0x0000000000000004",source="nvmlDeviceGetCurrentClocksEventReasons"}}}}
end})
local engine=Engine.new({collectors={gpu=collector},clock={now_ns=function() return now end,
  wall_ns=function() return 1700000000000000000+now end},context={fs=fs}})
local capabilities=engine:probe()
assert(capabilities.gpu.available==false and capabilities.gpu.reason=="nvml_query_pending")
local _,first=engine:tick()
assert(first.gpu.status=="unavailable" and first.gpu.reason=="nvml_query_pending" and first.gpu.retry_after_ms==250)
now=now+250000000
local snapshot,second=engine:tick()
assert(second.gpu.status=="ok" and #snapshot.gpus.devices==1)
assert(capabilities==engine.capabilities and capabilities.gpu.available)
local gpu=snapshot.gpus.devices[1]
assert(gpu.performance_limits.domains[1].observed_at_ns==2000000000,
  "a delivery tick must not reset the actual hardware sample age")
local exported=Export.snapshot(snapshot)
assert(exported.gpus.providers.nvml.transport=="process"
  and exported.gpus.providers.nvml.sample_started_ns==2000000000)
failed=true;now=now+1000000000
snapshot=engine:tick(true)
assert(capabilities.gpu.available==false and capabilities.gpu.reason=="nvml_query_timeout")
assert(snapshot.quality.gpus.quality=="stale")
assert(Export.snapshot(snapshot).gpus.devices[1].performance_limits.domains[1].quality=="stale")
engine:stop()
print("ok: NVML delivery-time power freshness, process-only default, headless async discovery and capability/sample timestamps")

do
local View=require("wtop.view_model")
local TUI=require("wtop.tui")
local I18n=require("wtop.i18n")
local Report=require("wtop.report")
local PCIe=require("wtop.model.gpu_pcie")
assert(PCIe.reading("pcie_current_generation",3.5)==nil and PCIe.reading("pcie_current_generation",0)==nil)
assert(PCIe.reading("pcie_current_width",0)==0 and PCIe.reading("pcie_current_width",65)==nil)
assert(PCIe.reading("pcie_tx_kilobytes_per_second",4294967294)==4294967294)
assert(PCIe.reading("pcie_tx_kilobytes_per_second",4294967295)==nil)
assert(PCIe.reading("pcie_rx_kilobytes_per_second",0/0)==nil)
local now,failed=2000000000,false
local c=GPU.new({fs=fs,scan_processes=false,amdsmi=false,levelzero=false,nvml=function()
 if failed then return nil,"nvml_query_timeout"end
 return {status="ok",sample_started_ns=1000000000,sample_finished_ns=1100000000,devices={{
  index=0,uuid="GPU-pcie",pci_bdf="00000000:01:00.0",name="PCIe test GPU",utilization_percent=25,
  pcie_current_generation=3,pcie_current_width=8,pcie_maximum_generation=4,pcie_maximum_width=16,
  pcie_tx_kilobytes_per_second=12345,pcie_rx_kilobytes_per_second=0,pcie_throughput_interval_ns=20000000}}}
end})
local result=c:sample({fs=fs,now_ns=function()return now end})
local s={timestamp_ns=now,gpus=result.data,quality={gpus={status="ok",quality="fresh"}}}
local gpu=s.gpus.devices[1];assert(gpu.metrics.pcie_rx_kilobytes_per_second==0 and gpu.capabilities.pcie)
assert(gpu.metric_observations.pcie_tx_kilobytes_per_second.observed_at_ns==1000000000)
assert(gpu.metric_observations.pcie_tx_kilobytes_per_second.hardware_timestamp_available==false)
local en=assert(I18n.new({locale="en-US"}))
local row=View.gpu_pcie_rows(s,en)[1]
assert(row.current=="Gen3 x8"and row.maximum=="Gen4 x16"and row.rx=="0 KB/s"and row.age_ns==1e9)
assert(row.tx:find("12,345",1,true)or row.tx:find("12345",1,true))
local exported=Export.snapshot(s);local agent=Export.agent(s)
assert(exported.gpus.devices[1].metrics.pcie_tx_kilobytes_per_second==12345)
assert(agent.top.gpus[1].metrics.pcie_rx_kilobytes_per_second==0 and agent.top.gpus[1].metrics.pcie_throughput_interval_ns==20000000)
assert(Report.render(exported):find("GPU PCIe links",1,true))
local e={history_values=function()return{}end}
assert(View.build(e,s,en,{},"gpu").gpu_table.rows[1].pcie=="Gen3 x8")
gpu.pci={current_link_speed="8 GT/s",current_link_width=4}
assert(View.build(e,s,en,{},"gpu").gpu_table.rows[1].pcie=="8 GT/s x4","NVML overwrote kernel link")
for _,locale in ipairs(I18n.available())do
 local i=assert(I18n.new({locale=locale}));local lines=table.concat(TUI.gpu_pcie_lines(s,i),"\n")
 assert(lines:find(i:t("gpu.pcie_title"),1,true)and lines:find("Gen4 x16",1,true)and lines:find("KB/s",1,true))
end
local observation=gpu.metric_observations.pcie_tx_kilobytes_per_second
for _,quality in ipairs({"stale","gap","held","missing","reset","error","denied","unavailable"})do
 observation.quality=quality;row=View.gpu_pcie_rows(s,en)[1]
 assert(row.tx:find(en:t("status."..quality),1,true),quality)
 assert(row.rx=="0 KB/s","one failed direction erased the other")
 assert(Report.render(Export.snapshot(s)):find("12345 ("..quality..")",1,true))
end
observation.quality="fresh";observation.retained=true
assert(PCIe.state(s,gpu,"pcie_tx_kilobytes_per_second")=="stale")
observation.retained=false;s.timestamp_ns=9007199254740994;observation.observed_at_ns=9007199254740993
local _,age=PCIe.state(s,gpu,"pcie_tx_kilobytes_per_second");assert(age==1)
s.timestamp_ns=2e9;observation.observed_at_ns=3e9
assert(PCIe.state(s,gpu,"pcie_tx_kilobytes_per_second")=="gap")
observation.observed_at_ns=1e9;s.timestamp_ns=17e9
assert(PCIe.state(s,gpu,"pcie_tx_kilobytes_per_second")=="stale")
s.timestamp_ns=2e9;s.quality.gpus.quality="gap"
assert(PCIe.state(s,gpu,"pcie_tx_kilobytes_per_second")=="fresh","unaffected metric lost to aggregate gap")
s.quality.gpus={status="error",quality="stale"}
assert(PCIe.state(s,gpu,"pcie_tx_kilobytes_per_second")=="stale")
s.quality.gpus={status="ok",quality="fresh"};failed=true;now=3e9
local retained=c:sample({fs=fs,now_ns=function()return now end},result)
local old=retained.data and retained.data.devices[1]
assert(old and old.metrics.pcie_rx_kilobytes_per_second==0 and old.metric_observations.pcie_rx_kilobytes_per_second.retained)
assert(old.metric_observations.pcie_rx_kilobytes_per_second.observed_at_ns==1e9)
assert(#View.gpu_pcie_rows({gpus={devices={}}},en)==0)
local many={gpus={devices={}}};for n=1,65 do many.gpus.devices[n]=gpu end
local rows,total=View.gpu_pcie_rows(many,en);assert(#rows==64 and total==65)
assert(table.concat(TUI.gpu_pcie_lines(many,en),"\n"):find("64 of 65",1,true))
c:stop()
print("ok: PCIe raw SDK units/window, independent quality/zero, exact ages, retained captures, bounded detail, kernel precedence and shared exports")
end
