local native=require("wtop.native")
local GPU=require("wtop.collectors.gpu")
local Export=require("wtop.export")
local source,path=assert(arg[1]),assert(arg[2])
local collector=GPU.new({scan_processes=false})
local context={now_ns=native.monotonic_ns,scan_gpu_processes=false}
local previous,maximum_ms
local function until_sample(predicate,seconds)
  local deadline=native.monotonic_ns()+seconds*1e9
  repeat
    local started=native.monotonic_ns()
    previous=collector:sample(context,previous)
    maximum_ms=math.max(maximum_ms or 0,(native.monotonic_ns()-started)/1e6)
    if previous.data and predicate(previous.data) then return previous.data end
    native.sleep_ms(120)
  until native.monotonic_ns()>deadline
  error("GPU continuity deadline: "..source)
end
local expected={}
until_sample(function(data)
  local seen={}
  for _,device in ipairs(data.devices) do
    local metrics=device.metrics
    if metrics.power_watts and device.quality.power=="fresh" then
      seen[metrics.power_source]=true
      if metrics.power_source==source then expected[device.id]=metrics.power_watts end
    end
  end
  return seen.nvml and seen.amdsmi and seen.levelzero
end,5)
local control=assert(io.open(path,"w"));assert(control:write(source=="nvml" and "47\n" or source=="amdsmi" and "41\n" or "42\n"));assert(control:close())
local armed=native.monotonic_ns()
local first_stale=until_sample(function(data) return data.providers[source].retained end,5)
local times={}
for id,watts in pairs(expected) do
  local device=assert(first_stale.by_id[id],"pending source lost a known GPU")
  assert(device.metrics.power_watts==watts and device.quality.power=="stale")
  times[id]=device.metric_observations.power_watts.observed_at_ns
  assert(times[id]<=armed,"pending work acquired a newer measurement time")
end
local timed_out=until_sample(function(data) return data.providers[source].reason==source.."_query_timeout" end,5)
for id,watts in pairs(expected) do
  local device=assert(timed_out.by_id[id])
  assert(device.metrics.power_watts==watts and device.quality.power=="stale")
  assert(device.metric_observations.power_watts.observed_at_ns==times[id])
end
local healthy={}
for _,device in ipairs(timed_out.devices) do
  local observation=device.metric_observations and device.metric_observations.power_watts
  if observation and observation.source~=source and observation.quality=="fresh" then
    healthy[observation.source]=true
    assert(observation.observed_at_ns>armed,"healthy vendor stopped sampling")
  end
end
for _,vendor in ipairs({"nvml","amdsmi","levelzero"}) do
  if vendor~=source then assert(healthy[vendor],"another vendor was starved") end
end
local snapshot=Export.snapshot({gpus=timed_out,quality={gpus={status="ok",quality="partial"}}})
for _,device in ipairs(snapshot.gpus.devices) do
  if expected[device.id] then assert(device.metrics.power_limit_percent==nil) end
end
control=assert(io.open(path,"w"));assert(control:write("0\n"));assert(control:close())
until_sample(function(data)
  if data.providers[source].retained then return false end
  for id,watts in pairs(expected) do
    local device=data.by_id[id]
    if not device or device.metrics.power_watts~=watts or device.quality.power~="fresh" then return false end
    assert(not device.metric_observations.power_watts.retained)
    assert(device.metric_observations.power_watts.observed_at_ns>armed)
  end
  return true
end,10)
local maps=assert(io.open("/proc/self/maps","r"));local content=maps:read("a");maps:close()
for _,library in ipairs({"libnvidia-ml","libamd_smi","libze_loader"}) do
  assert(not content:find(library,1,true),"vendor SDK loaded into the parent")
end
collector:stop()
print("ok: "..source.." warmed -> pending -> timeout -> recovered; stable GPU identities, old timestamps, healthy vendors, suppressed stale bars; max foreground ms "..maximum_ms)
