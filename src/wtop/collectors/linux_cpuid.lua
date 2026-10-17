-- Nonblocking hardware observations enrich, but do not replace Linux OS data.
local Common=require("wtop.collectors.common")
local Native=require("wtop.native")
local FS=require("wtop.linux.fs")
local Model=require("wtop.model.cpuid")
local Worker=require("wtop.collectors.hardware_worker")
local M={}
local function signature(data)
 local parts={}
 for _,key in ipairs({"vendor","family","model","stepping","microcode","model_name"})do parts[#parts+1]=tostring(data.identity[key])end
 for _,kind in ipairs(data.core_types or{})do
  for _,key in ipairs({"id","vendor","family","model","stepping","model_name","kernel_core_type"})do parts[#parts+1]=tostring(kind[key])end
 end
 for _,cpu in ipairs(data.topology.logical_cpus or{})do
  parts[#parts+1]=table.concat({cpu.id,tostring(cpu.online),tostring(cpu.package_id),tostring(cpu.core_id),tostring(cpu.core_type_id)},":")
 end
 return table.concat(parts,";")
end
local function reset(owner)
 if owner._cpuid_worker then owner._cpuid_worker:close()end
 owner._cpuid_worker,owner._cpuid_last,owner._cpuid_key=nil,nil,nil
end
function M.close(owner)owner._cpuid_closed=true;reset(owner)end
function M.enrich(owner,data,context,fs)
 if owner.cpuid_enabled==false or owner._cpuid_closed then return end
 local native=owner.cpuid_native or Native
 if not owner.cpuid_provider then
  if fs~=FS.default or owner.proc_cpuinfo_path~="/proc/cpuinfo"or owner.sys_cpu_path~="/sys/devices/system/cpu"then return end
  if not Worker.available(native)or not(native.hardware_worker_sources and native.hardware_worker_sources.cpuid)then return end
  local ok,os=pcall(native.uname)
  if not ok or type(os)~="table"or os.sysname~="Linux"or not(tostring(os.machine):match("^i[3-6]86$")or os.machine=="x86_64")then return end
 end
 local now=Common.now_ns(context)
 local key=signature(data)
 if owner._cpuid_key~=key or owner._cpuid_now and now<owner._cpuid_now then reset(owner);owner._cpuid_key=key end
 owner._cpuid_now=now
 local targets={}
 for _,cpu in ipairs(data.topology.logical_cpus or{})do
  if #targets<512 then targets[#targets+1]={id=cpu.id}end
 end
 if #targets==0 then return end
 local observation=owner._cpuid_last
 local pending,refresh_reason
 if not observation or now-observation.observed_at_ns>=(owner.cpuid_cache_ns or 30000000000)then
  local result
  if owner.cpuid_provider then
   local ok,value=pcall(owner.cpuid_provider,targets,context)
   if ok then result=value end
  else
   if not owner._cpuid_worker then owner._cpuid_worker=Worker.new({id="cpuid",default_interval_ms=30000},{targets=targets},native)end
   result=owner._cpuid_worker:sample(context)
  end
  if type(result)=="table"and result.status=="ok"and type(result.data)=="table"then
   observation={};for k,v in pairs(result.data)do observation[k]=v end
   observation.observed_at_ns=result.value_timestamp_ns or result.timestamp_ns or now
   observation.sample_started_ns,observation.sample_finished_ns=result.sample_started_ns,result.sample_finished_ns
   observation.transport=result.transport;owner._cpuid_last=observation
   -- Static metadata stays cached in the parent; no idle probe process is needed.
   if owner._cpuid_worker then owner._cpuid_worker:close();owner._cpuid_worker=nil end
  else
   pending=result and result.sampling_pending==true
   refresh_reason=result and result.reason or "cpuid_helper_failed"
   observation=owner._cpuid_last or {status=pending and "pending"or "error",reason=refresh_reason}
   if refresh_reason=="cpuid_affinity_restore_failed"and owner._cpuid_worker then owner._cpuid_worker:close();owner._cpuid_worker=nil end
  end
 end
 local published={};for k,v in pairs(observation)do published[k]=v end;observation=published
 observation.source=observation.source or"Linux native CPUID reader";observation.platform="linux"
 if refresh_reason and observation.status=="ok"then
  observation.quality="stale";observation.reason=refresh_reason;observation.retained=true
  observation.refresh_status=pending and "pending"or "error"
 end
 observation.targets=targets
 observation.age_ms=observation.observed_at_ns and math.max(0,now-observation.observed_at_ns)/1e6 or nil
 local retry=Model.enrich(data,observation)
 return pending and 25 or refresh_reason and 5000 or retry,pending or observation.status=="pending"
end
return M
