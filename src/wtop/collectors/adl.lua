-- AMD ADL telemetry. PowerControl offsets are not absolute power limits.
local Normalize = require("wtop.collectors.nvml").normalize_bdf
local M = {}
local function finite(value) return type(value)=="number" and value==value and value>=0 and value<math.huge end
local function bounded(value,maximum) return finite(value) and value<=maximum end
local function text(value) return type(value)=="string" and value:gsub("[%c]",""):sub(1,128) or nil end
function M.default_provider(native)
  return require("wtop.collectors.gpu_worker").default_provider("adl",native)
end
function M.query(provider)
  if type(provider)~="function" then return nil,"adl_provider_unavailable" end
  local ok,data,reason=pcall(provider,false)
  if not ok then return nil,"adl_query_failed" end
  if type(data)~="table" or type(data.devices)~="table" then return nil,type(reason)=="string" and reason or "adl_unavailable" end
  return data
end
function M.merge(devices,data,lookup,options)
  lookup=lookup or {by_bdf={}};options=options or {};local used=options.used_ids or {}
  local added,merged,duplicates,unmatched=0,0,0,0;local seen={};local diagnostics={}
  for index,entry in ipairs(data.devices or {}) do
    if index>64 then break end
    if type(entry)=="table" then
      local bdf=Normalize(entry.pci_bdf)
      if bdf and seen[bdf] then duplicates=duplicates+1
      else
        if bdf then seen[bdf]=true end
        local device=bdf and entry.identity_verified==true and lookup.by_bdf[bdf]
        local usable=bounded(entry.power_watts,100000) or bounded(entry.graphics_clock_hz,1e10)
          or bounded(entry.memory_clock_hz,1e10) or bounded(entry.utilization_percent,100)
          or type(entry.temperature_celsius)=="number" and entry.temperature_celsius==entry.temperature_celsius
            and entry.temperature_celsius>-200 and entry.temperature_celsius<1000
          or bounded(entry.fan_speed_percent,100) or bounded(entry.fan_speed_rpm,100000)
        if entry.identity_verified~=true or (not device and not usable and not (entry.present==true or entry.active==true)) then
          unmatched=unmatched+1
          diagnostics[#diagnostics+1]={adapter_index=entry.index,pci_bdf=bdf,
            active_status=entry.active_status,caps_status=entry.caps_status,
            activity_status=entry.activity_status,temperature_status=entry.temperature_status,
            fan_status=entry.fan_status,power_status=entry.power_status}
        else
        if not device then
          local id=bdf or "adl:"..tostring(entry.index or index)
          while used[id] do id=id.."+" end;used[id]=true
          device={id=id,stable_id=id,pci_bdf=bdf,card="adl"..tostring(entry.index or index),
            vendor_id=entry.vendor_id,device_id=entry.device_id,vendor_name="AMD",model_name=text(entry.name),
            source="adl",identity_quality=entry.identity_verified and "fresh" or "estimated",
            metrics={},quality={},capabilities={},drm_nodes={},render_nodes={},hwmon_refs={},
            frequencies={domains={},by_id={}},processes={list={},by_id={},clients={},clients_by_id={},summary={process_count=0,client_count=0}}}
          devices[#devices+1]=device
          if bdf then lookup.by_bdf[bdf]=device end
          added=added+1
        else merged=merged+1 end
        device.metrics=device.metrics or {};device.quality=device.quality or {};device.capabilities=device.capabilities or {}
        local metrics=device.metrics
        local function fill(key,value,group,maximum)
          if metrics[key]==nil and bounded(value,maximum) then
            metrics[key]=value;device.quality[group]="fresh";device.capabilities[group]=true;return true
          end
        end
        fill("utilization_percent",entry.utilization_percent,"utilization",100)
        if type(entry.temperature_celsius)=="number" and entry.temperature_celsius==entry.temperature_celsius
            and entry.temperature_celsius>-200 and entry.temperature_celsius<1000 and metrics.temperature_celsius==nil then
          metrics.temperature_celsius=entry.temperature_celsius;device.quality.temperature="fresh";device.capabilities.temperature=true
        end
        fill("frequency_current_hz",entry.graphics_clock_hz,"frequency",1e10)
        fill("frequency_graphics_hz",entry.graphics_clock_hz,"frequency",1e10)
        fill("frequency_memory_hz",entry.memory_clock_hz,"frequency",1e10)
        fill("fan_speed_percent",entry.fan_speed_percent,"fan",100)
        fill("fan_speed_rpm",entry.fan_speed_rpm,"fan",100000)
        if fill("power_watts",entry.power_watts,"power",100000) then
          metrics.power_source="adl";metrics.power_scope="asic";metrics.power_measurement="device_sample"
        end
        device.adl={adapter_index=entry.index,aliases=entry.aliases,initialization=data.initialization,
          active=entry.active,overdrive_version=entry.overdrive_version,identity_verified=entry.identity_verified,
          observed_at_ns=data.sample_started_ns or options.now_ns,quality=entry.partial and "partial" or "fresh",
          query_status={}}
        for _,key in ipairs({"active_status","caps_status","activity_status","temperature_status","fan_status","power_status"}) do
          if type(entry[key])=="number" then device.adl.query_status[key]=entry[key] end
        end
        device.capabilities.adl=true
        device.partial=device.partial or entry.partial==true
        end
      end
    end
  end
  return {status=(data.status=="partial" or data.truncated or duplicates>0 or unmatched>0) and "partial" or "ok",source="adl",
    device_count=#(data.devices or {}),added_devices=added,merged_devices=merged,duplicates=duplicates,
    unmatched_devices=unmatched,diagnostics=diagnostics,
    initialization=data.initialization,transport=data.transport,sample_started_ns=data.sample_started_ns,
    sample_finished_ns=data.sample_finished_ns,truncated=data.truncated}
end
return M
