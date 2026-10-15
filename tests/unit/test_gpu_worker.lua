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
