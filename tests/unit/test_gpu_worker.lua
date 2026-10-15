package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Worker = require("wtop.collectors.gpu_worker")
local GPU = require("wtop.collectors.gpu")
local Engine = require("wtop.engine")
local Fixture = require("support.fixture_fs")
local Json = require("wtop.core.json")
local original = package.loaded["wtop.native"]

-- An older/partial native module cannot turn isolation into a direct call.
package.loaded["wtop.native"] = {
  nvml_query = function() error("raw NVML called") end,
  amdsmi_query = function() error("raw AMD called") end,
  levelzero_query = function() error("raw Sysman called") end,
}
for _,source in ipairs({"nvml","amdsmi","levelzero"}) do assert(Worker.default_provider(source)==nil) end
local opened,closed={},{}
package.loaded["wtop.native"] = {
  gpu_worker_open=function(source) local session={source=source};opened[#opened+1]=session;return session end,
  gpu_worker_query=function(session,processes)
    assert(not session.closed);return {devices={},source=session.source,processes=processes}
  end,
  gpu_worker_close=function(session,wait) assert(wait==0);session.closed=true;closed[#closed+1]=session end,
}
local a,stop_a=Worker.default_provider("amdsmi")
local b,stop_b=Worker.default_provider("levelzero")
assert(a(false).source=="amdsmi" and b(false).source=="levelzero")
stop_a();assert(b(false).source=="levelzero" and #closed==1)
local _,why=a(false);assert(why=="amdsmi_worker_closed")
stop_b();assert(#opened==2 and #closed==2)
local reason,retry,failed=Worker.retry(nil,"amdsmi_query_pending",nil)
assert(reason=="amdsmi_query_pending" and retry==250 and failed==false)
reason,retry,failed=Worker.retry(nil,nil,"levelzero_query_timeout")
assert(reason=="levelzero_query_timeout" and retry==5000 and failed)
package.loaded["wtop.native"]=original

-- A slow source must not disappear just because another vendor stays healthy.
-- Retained telemetry keeps its original time and is never a current power bar.
do
  local Export = require("wtop.export")
  local ViewModel = require("wtop.view_model")
  local I18n = require("wtop.i18n")
  local TUI = require("wtop.tui")
  local fixture = Fixture.new({dirs={["/sys/class/drm"]={},["/proc"]={}}})
  local now, state = 1000000000, "ready"
  local watts = 30
  local collector = GPU.new({fs=fixture,scan_processes=false,
    nvml=function()
      if state=="pending" then return nil,"nvml_query_pending" end
      if state=="failed" or state=="allfailed" then return nil,"nvml_query_timeout" end
      return {sample_started_ns=now,sample_finished_ns=now+10,transport="process",devices=
        state=="empty" and {} or {{index=0,uuid="GPU-retained",pci_bdf="0000:01:00.0",
          name="NVIDIA continuity",utilization_percent=90,power_watts=watts,power_limit_watts=60,
          clock_events={status_code=0,raw_hex="0x0000000000000004"}}}}
    end,
    amdsmi=function()
      if state=="allfailed" then return nil,"amdsmi_query_timeout" end
      return {sample_started_ns=now,devices={{index=0,pci_bdf="0000:02:00.0",
      name="AMD healthy",power_watts=now/100000000,power_limit_watts=100,utilization_percent=10}}} end,
    levelzero=function()
      if state=="allfailed" then return nil,"levelzero_query_timeout" end
      return {sample_started_ns=now,devices={{index=0,pci_bdf="0000:03:00.0",
      name="Intel healthy",power_watts=10,power_limit_watts=40,graphics_clock_hz=300000000}}} end})
  local context={fs=fixture,now_ns=function() return now end}
  local first=collector:sample(context)
  assert(#first.data.devices==3)
  now=2000000000;state="pending"
  local second=collector:sample(context,first)
  assert(#second.data.devices==3,"pending NVIDIA erased its device while AMD/Intel stayed healthy")
  local old=second.data.by_id["0000:01:00.0"]
  assert(old.metrics.power_watts==30 and old.quality.power=="stale")
  assert(old.metric_observations.power_watts.observed_at_ns==1000000000)
  assert(old.metric_observations.power_watts.retained)
  assert(old.performance_limits.domains[1].quality=="stale")
  assert(second.data.providers.nvml.retained and second.data.providers.nvml.reason=="nvml_query_pending")
  local healthy=second.data.by_id["0000:02:00.0"]
  assert(healthy.metrics.power_watts==20 and healthy.quality.power=="fresh")
  local exported=Export.snapshot({gpus=second.data,quality={gpus={status="ok",quality="partial"}}})
  assert(exported.gpus.devices[1].metrics.power_limit_percent==nil)
  assert(exported.gpus.devices[2].metrics.power_limit_percent==20)
  assert(exported.gpus.devices[1].metric_observations.power_watts.observed_at_ns==1000000000)
  local agent=Export.agent({gpus=second.data,quality={gpus={status="ok",quality="partial"}}},{device_limit=1})
  assert(agent.metrics.gpu.maximum_utilization_percent==10)
  assert(agent.top.gpus[1].id==healthy.id,"a stale 90% GPU displaced the healthy top GPU")
  local top_two=Export.agent({gpus=second.data,quality={gpus={status="ok",quality="partial"}}},{device_limit=2})
  assert(top_two.top.gpus[2].id=="0000:03:00.0",
    "a stale utilization reading displaced a healthy GPU that only reports power")
  for _,signal in ipairs(agent.signals) do
    assert(signal.resource~="gpu" or signal.code~="high_utilization")
  end
  for _,locale in ipairs({"en-US","zh-CN","zh-TW","ja-JP","ko-KR","fr-FR","de-DE","es-ES","pt-BR","ru-RU"}) do
    local translator=assert(I18n.new({locale=locale}))
    local rows=ViewModel.build({history_values=function() return {} end},
      {timestamp_ns=now,gpus=second.data,quality={gpus={status="ok",quality="partial"}}},translator,{},"gpu").gpu_table.rows
    assert(rows[1].power_percent==nil and rows[2].power_percent==20)
    assert(rows[1].power:find(translator:t("status.stale"),1,true),locale)
    assert(rows[1].power_limit:find(translator:t("status.stale"),1,true),locale)
    assert(rows[1].power_age_ns==1000000000 and rows[1].power_reason=="nvml_query_pending")
    local detail=table.concat(TUI.power_detail_lines({timestamp_ns=now,gpus=second.data,
      quality={gpus={status="ok",quality="partial"}}},translator),"\n")
    assert(detail:find(translator:t("systemd.sample_age"),1,true),locale)
  end
  assert(first.data.by_id[old.id].quality.power=="fresh","retention mutated an older snapshot")
  first.data.by_id[old.id].metrics.power_watts=999
  now=3000000000;state="failed"
  local third=collector:sample(context,second)
  assert(third.data.by_id[old.id].metrics.power_watts==30,"caller mutation escaped into the private observation")
  assert(third.data.by_id[old.id].metric_observations.power_watts.observed_at_ns==1000000000)
  now=4000000000;state="ready";watts=45
  local recovered=collector:sample(context,third)
  assert(recovered.data.by_id[old.id].metrics.power_watts==45)
  assert(recovered.data.by_id[old.id].quality.power=="fresh")
  now=5000000000;state="empty"
  local removed=collector:sample(context,recovered)
  assert(#removed.data.devices==2 and removed.data.by_id[old.id]==nil,"confirmed removal resurrected a cached GPU")
  now=6000000000;state="ready"
  local engine=Engine.new({collectors={gpu=collector},context={fs=fixture},clock={
    now_ns=function() return now end,wall_ns=function() return 1700000000000000000+now end}})
  engine:probe()
  engine:tick(true)
  now=7000000000;state="pending"
  local mixed=engine:tick(true)
  local history=engine:history_values("gpu")
  assert(history[#history]==10,"a stale GPU was recorded as a new chart sample")
  assert(mixed.quality.gpus.quality=="partial")
  now=8000000000;state="allfailed"
  local all_stale=engine:tick(true)
  assert(all_stale.quality.gpus.quality=="stale" and not engine.capabilities.gpu.available)
  assert(all_stale.quality.gpus.timestamp_ns==now and all_stale.quality.gpus.value_timestamp_ns==7000000000)
  assert(Export.agent(all_stale).metrics.gpu.maximum_utilization_percent==nil)
  history=engine:history_values("gpu");assert(history[#history]==false)
  now=9000000000;state="empty"
  local gone=engine:tick(true)
  assert(#gone.gpus.devices==2)
  context.safe_mode=true
  collector:sample(context,gone)
  context.safe_mode=false;now=10000000000;state="pending"
  assert(#collector:sample(context).data.devices==2,"safe mode failed to clear the old vendor observation")
  now=11000000000;state="ready";collector:sample(context)
  now=12000000000;state="pending"
  local other_fs=Fixture.new({dirs={["/sys/class/drm"]={},["/proc"]={}}})
  assert(#collector:sample({fs=other_fs,now_ns=function() return now end}).data.devices==2)
  now=13000000000;state="ready";collector:sample(context)
  now=12000000000;state="pending"
  assert(#collector:sample(context).data.devices==2,"a clock rollback reused an observation from the future")
  engine:stop()
  collector:stop()
end

do
  -- Partial enumeration is not proof that every omitted GPU was removed.
  for _,source in ipairs({"nvml","amdsmi","levelzero"}) do
    local fs=Fixture.new({dirs={["/sys/class/drm"]={},["/proc"]={}}})
    local now,phase=1000000000,"both"
    local function entry(index,bdf,uuid,watts)
      return {index=index,pci_bdf=bdf,uuid=uuid,name=source..uuid,power_watts=watts,power_limit_watts=100}
    end
    local provider=function()
      if phase=="waiting" then return nil,source.."_query_pending" end
      local data={sample_started_ns=now,devices={entry(0,"0000:01:00.0",
        phase=="replacement" and "new-A" or "A",30)}}
      if phase=="no-power" then data.devices[1].power_watts=nil end
      if phase=="both" then data.devices[2]=entry(1,"0000:04:00.0","B",40) end
      if phase=="partial" or phase=="replacement" then data.status="partial" end
      return data
    end
    local options={fs=fs,scan_processes=false,nvml=false,amdsmi=false,levelzero=false}
    options[source]=provider
    local collector=GPU.new(options)
    local context={fs=fs,now_ns=function() return now end}
    local first=collector:sample(context)
    now=2000000000;phase="partial"
    local partial=collector:sample(context,first)
    assert(#partial.data.devices==2 and partial.data.by_id["0000:04:00.0"].quality.power=="stale",source)
    assert(partial.data.by_id["0000:01:00.0"].quality.power=="fresh",source)
    assert(partial.data.providers[source].retained_device_count==1)
    now=3000000000;phase="replacement"
    local replaced=collector:sample(context,partial)
    assert(#replaced.data.devices==2 and replaced.data.by_id["0000:01:00.0"].vendor_uuid=="new-A")
    now=4000000000;phase="only-A"
    assert(#collector:sample(context,replaced).data.devices==1,source)
    now=5000000000;phase="no-power"
    assert(collector:sample(context).data.devices[1].metrics.power_watts==nil)
    now=6000000000;phase="waiting"
    assert(collector:sample(context).data.devices[1].metrics.power_watts==nil,
      "a fresh response's missing field was refilled from an older response")
    collector:stop()
  end
end

do
  local fs=Fixture.new({dirs={["/sys/class/drm"]={},["/proc"]={}}})
  local reads,now=0,1000000000
  local collector=GPU.new({fs=fs,scan_processes=false,amdsmi=false,levelzero=false,nvml=function()
    reads=reads+1
    if reads>1 then return nil,"nvml_query_pending" end
    return {sample_started_ns=now,devices={{uuid="GPU-probe",pci_bdf="0000:01:00.0",power_watts=30}}}
  end})
  local context={fs=fs,now_ns=function() return now end}
  assert(collector:probe(context).available)
  now=2000000000
  local retained=collector:sample(context)
  assert(#retained.data.devices==1 and retained.data.devices[1].quality.power=="stale")
  assert(retained.value_timestamp_ns==1000000000,"the first probe observation was consumed and lost")
  collector:stop()
  assert(collector:sample(context).data==nil,"stop retained the old observation")
end

do
  local fs=Fixture.new({dirs={["/sys/class/drm"]={},["/proc"]={}}})
  local now,partial=1000000000,false
  local collector=GPU.new({fs=fs,scan_processes=false,nvml=false,levelzero=false,amdsmi=function()
    local data={sample_started_ns=now,status=partial and "partial" or "ok",devices={}}
    for index=1,(partial and 1 or 64) do
      data.devices[index]={pci_bdf=string.format("0000:%02x:00.0",partial and 65 or index),
        uuid="GPU-"..tostring(partial and 65 or index),name="bounded",power_watts=10}
    end
    return data
  end})
  local context={fs=fs,now_ns=function() return now end}
  assert(#collector:sample(context).data.devices==64)
  now=2000000000;partial=true
  local bounded=collector:sample(context)
  assert(#bounded.data.devices==64 and bounded.data.by_id["0000:41:00.0"].quality.power=="fresh")
  assert(bounded.data.providers.amdsmi.retention_truncated and bounded.data.truncated,
    "a bounded partial inventory must report omitted observations")
  collector:stop()
end

do
  local Hardware=require("support.hardware_fixtures")
  local spec=Hardware.drm_amdgpu()
  spec.dirs={["/sys/class/drm"]={"card0"},["/proc"]={}}
  local fs=Fixture.new(spec)
  local original_list,removed_card=fs.list_impl,false
  fs.list_impl=function(path,limit)
    if removed_card and path=="/sys/class/drm" then return {},nil,false end
    return original_list(path,limit)
  end
  local now,waiting=1000000000,false
  local collector=GPU.new({fs=fs,scan_processes=false,nvml=false,levelzero=false,
    amdsmi=function()
      if waiting then return nil,"amdsmi_query_pending" end
      return {sample_started_ns=now,devices={{index=0,uuid="GPU-AMD-old",pci_bdf="0000:01:00.0",
        power_watts=50,power_limit_watts=100,utilization_percent=99}}}
    end})
  local context={fs=fs,now_ns=function() return now end}
  local first=collector:sample(context)
  waiting=true;now=2000000000
  spec.files["/sys/class/drm/card0/device/gpu_busy_percent"]="55\n"
  local retained=collector:sample(context,first).data.devices[1]
  assert(retained.metrics.power_watts==50 and retained.quality.power=="stale")
  assert(retained.metrics.utilization_percent==55 and retained.quality.utilization=="fresh")
  assert(retained.vendor_uuid==nil,"an old SDK UUID was promoted to a current DRM identity")
  spec.files["/sys/class/drm/card0/device/device"]="0x744d\n"
  now=3000000000
  assert(collector:sample(context).data.devices[1].metrics.power_watts==nil)
  spec.files["/sys/class/drm/card0/device/device"]="0x744c\n"
  now=4000000000
  assert(collector:sample(context).data.devices[1].metrics.power_watts==nil,
    "invalidated hardware identity was later resurrected")
  waiting=false;now=5000000000;collector:sample(context)
  waiting=true;now=6000000000;removed_card=true
  local removed=collector:sample(context)
  assert(#removed.data.devices==0,"a removed DRM card was recreated as a headless SDK GPU")
  collector:stop()
end

-- Only GPU work exists in this engine: slow SDK startup cannot be hidden by
-- time spent collecting CPU, disk or inventory. Sleeps advance a fake clock.
local fs=Fixture.new({dirs={["/sys/class/drm"]={},["/proc"]={}}})
local old_engine,old_config,old_privilege=package.loaded["wtop.engine"],package.loaded["wtop.config"],package.loaded["wtop.privilege"]
local old_application=package.loaded["wtop.application"]
local now,sleeps,stopped,mode=0,{},false,"slow"
local function provider()
  if mode=="forever" or now<800000000 then return nil,"levelzero_query_pending" end
  local warm=now<1000000000
  return {transport="process",sample_started_ns=now,devices={{index=0,pci_bdf="0000:03:00.0",
    name="SDK GPU",power_watts=not warm and 30 or nil,power_limit_watts=40,
    power_scope="card",power_quality=warm and "gap" or "fresh",
    power_reason=warm and "levelzero_power_warmup" or nil}}}
end
package.loaded["wtop.native"]={
  sleep_ms=function(ms) sleeps[#sleeps+1]=ms;now=now+ms*1000000;return true end,
  uname=function() return {sysname="Fixture OS",machine="fixture"} end,
  realtime_ns=function() return 1700000000000000000+now end,
}
package.loaded["wtop.config"]={load=function() return {},{state="default"} end,resolve=function(options) return options end}
package.loaded["wtop.privilege"]={restricts_user_files=function() return false end}
package.loaded["wtop.engine"]={new=function(options)
  local collector=GPU.new({fs=fs,nvml=false,amdsmi=false,levelzero=provider,scan_processes=false})
  local engine=Engine.new({interval_ms=options.interval_ms,collectors={gpu=collector},context={fs=fs},
    clock={now_ns=function() return now end,wall_ns=function() return 1700000000000000000+now end}})
  local stop=engine.stop;engine.stop=function(self) stopped=true;stop(self) end
  return engine
end}
package.loaded["wtop.application"]=nil
local Application=require("wtop.application")
local write,output=io.write,{}
io.write=function(...) for i=1,select("#",...) do output[#output+1]=tostring(select(i,...)) end;return true end
local function snapshot()
  now,sleeps,stopped,output=0,{},false,{}
  assert(Application.snapshot({interval_ms=1,privilege={mode="user",root=false}})==0)
  assert(stopped and sleeps[1]==1)
  return assert(Json.decode(table.concat(output)))
end
local ok,failure=xpcall(function()
  local result=snapshot()
  assert(now>=1000000000 and now<2251000000)
  assert(result.gpus.devices[1].metrics.power_watts==30)
  assert(result.gpus.devices[1].metrics.power_limit_percent==75)
  assert(result.capabilities.gpu.available)
  mode="forever";result=snapshot()
  assert(now==2251000000,"pending sources must not extend the fixed settle deadline")
  assert(result.capabilities.gpu.available==false and #result.gpus.devices==0)
end,debug.traceback)
io.write=write
package.loaded["wtop.engine"],package.loaded["wtop.config"],package.loaded["wtop.privilege"]=old_engine,old_config,old_privilege
package.loaded["wtop.native"],package.loaded["wtop.application"]=original,old_application
assert(ok,failure)
print("ok: all-vendor process-only leases, independent stop, sparse retries and bounded one-shot startup/energy warmup")
