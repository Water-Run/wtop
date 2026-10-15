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
