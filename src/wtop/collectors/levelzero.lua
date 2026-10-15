-- Sysman devices join DRM by PCI address. Unknown relationships remain separate;
-- enumeration position cannot identify a physical device or a power domain.
local Limits = require("wtop.collectors.gpu_limits")
local Normalize = require("wtop.collectors.nvml").normalize_bdf
local M = {}
local function finite(value)
  return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge
end
local function text(value,limit)
  if type(value)~="string" or value=="" then return nil end
  return value:gsub("[%c]",""):sub(1,limit or 128)
end
local function pick(object,fields)
  local out={}
  for _,key in ipairs(fields) do
    local value=object[key]
    if finite(value) or type(value)=="boolean" then out[key]=value
    elseif type(value)=="string" then out[key]=text(value,128) end
  end
  return out
end
local function missing(metrics,key,value)
  if metrics[key]==nil and finite(value) and value>=0 then metrics[key]=value;return true end
end
function M.default_provider()
  return require("wtop.collectors.gpu_worker").default_provider("levelzero")
end
function M.query(provider)
  if type(provider)~="function" then return nil,"levelzero_provider_unavailable" end
  local called,data,reason=pcall(provider,false)
  if not called then return nil,"levelzero_query_failed" end
  if type(data)~="table" or type(data.devices)~="table" then
    return nil,type(reason)=="string" and reason or "levelzero_unavailable"
  end
  return data
end
local function new_device(entry,index,bdf,used)
  local id=bdf or "levelzero:"..tostring(text(entry.uuid,96) or entry.index or index)
  while used[id] do id=id.."+" end
  used[id]=true
  return {id=id,stable_id=id,pci_bdf=bdf,card="ze"..tostring(index),
    vendor_id=entry.vendor_id,device_id=entry.device_id,vendor_name=text(entry.vendor_name,96),
    model_name=text(entry.name,96),vendor=text(entry.vendor_name,32),
    identity_quality=bdf and "fresh" or "estimated",quality={identity=bdf and "fresh" or "estimated"},
    partial=not bdf,source="levelzero",drm_nodes={},render_nodes={},hwmon_refs={},
    frequencies={domains={},by_id={}},metrics={},capabilities={},issues={},
    processes={list={},by_id={},clients={},clients_by_id={},summary={process_count=0,client_count=0}}}
end
local function sysman_fields(entry,observed)
  local result={observed_at_ns=observed,power_domains={},frequency_domains={}}
  for index,domain in ipairs(entry.power_domains or {}) do
    if index>32 then break end
    local out=pick(domain,{"index","scope","on_subdevice","subdevice_id","quality","reason",
      "power_watts","interval_ns","energy_microjoules","counter_timestamp_us","energy_raw_hex",
      "sustained_enabled","sustained_limit_watts","sustained_window_seconds",
      "burst_enabled","burst_limit_watts","peak_ac_watts","peak_dc_watts"})
    out.limits={}
    for n,limit in ipairs(domain.limits or {}) do
      if n>16 then break end
      out.limits[#out.limits+1]=pick(limit,{"level_code","source_code","unit_code","enabled","window_seconds","watts","amperes"})
    end
    result.power_domains[#result.power_domains+1]=out
  end
  for index,domain in ipairs(entry.frequency_domains or {}) do
    if index>32 then break end
    result.frequency_domains[#result.frequency_domains+1]=pick(domain,{"index","kind","on_subdevice",
      "subdevice_id","actual_hz","requested_hz","minimum_hz","maximum_hz","throttle_raw_hex","throttle_quality"})
  end
  return result
end
local function append_clocks(device,domains)
  device.frequencies=device.frequencies or {domains={},by_id={}}
  local frequencies=device.frequencies
  frequencies.domains=frequencies.domains or {};frequencies.by_id=frequencies.by_id or {}
  -- Sysfs GTs and Sysman domains have no universal identity mapping. Keep the
  -- second observation in sysman metadata when DRM already describes clocks.
  if #frequencies.domains>0 then return end
  for index,domain in ipairs(domains) do
    local id="sysman:"..tostring(domain.kind or "unknown")..":"
      ..(domain.on_subdevice and "tile"..tostring(domain.subdevice_id or "?") or "root")
      ..":"..tostring(domain.index or index-1)
    local out={id=id,kind=domain.kind,on_subdevice=domain.on_subdevice,subdevice_id=domain.subdevice_id,
      actual_hz=domain.actual_hz,requested_hz=domain.requested_hz,minimum_hz=domain.minimum_hz,
      maximum_hz=domain.maximum_hz,source_kind="levelzero_sysman",source="zesFrequencyGetState",
      quality=finite(domain.actual_hz) and domain.actual_hz>0 and "fresh" or "unavailable"}
    frequencies.domains[#frequencies.domains+1]=out;frequencies.by_id[id]=out
  end
end
function M.merge(devices,data,lookup,options)
  options=options or {};lookup=lookup or {};local by_bdf=lookup.by_bdf or {}
  -- Accept older injected caller lists by address, never by their ordering.
  if not lookup.by_bdf then for _,d in ipairs(lookup) do if d.pci_bdf then by_bdf[d.pci_bdf]=d end end end
  local merged,added,unmatched,duplicates=0,0,0,0
  local seen_bdf,seen_uuid={},{};local pending=false
  for index,entry in ipairs(data.devices or {}) do
    if index>64 then break end
    if type(entry)=="table" then
      local bdf,uuid=Normalize(entry.pci_bdf),text(entry.uuid,96)
      if (bdf and seen_bdf[bdf]) or (uuid and seen_uuid[uuid]) then duplicates=duplicates+1
      else
        if bdf then seen_bdf[bdf]=true end;if uuid then seen_uuid[uuid]=true end
        local device=bdf and by_bdf[bdf] or nil
        if not device then
          device=new_device(entry,index,bdf,options.used_ids or {});devices[#devices+1]=device
          if bdf then by_bdf[bdf]=device end;added=added+1
          if not bdf then unmatched=unmatched+1 end
        else merged=merged+1 end
        device.levelzero_index=entry.index or index-1;device.vendor_uuid=uuid or device.vendor_uuid
        device.driver_version=text(entry.driver_version,96) or device.driver_version
        device.model_name=device.model_name or text(entry.name,96)
        device.metrics=device.metrics or {};device.quality=device.quality or {};device.capabilities=device.capabilities or {}
        local metrics=device.metrics
        if metrics.temperature_celsius==nil and finite(entry.temperature_celsius)
            and entry.temperature_celsius>-274 and entry.temperature_celsius<1000 then
          metrics.temperature_celsius=entry.temperature_celsius
        end
        if finite(entry.graphics_clock_hz) and entry.graphics_clock_hz>0 then
          missing(metrics,"frequency_current_hz",entry.graphics_clock_hz);missing(metrics,"frequency_graphics_hz",entry.graphics_clock_hz)
        end
        if finite(entry.memory_clock_hz) and entry.memory_clock_hz>0 then missing(metrics,"frequency_memory_hz",entry.memory_clock_hz) end
        if missing(metrics,"power_watts",entry.power_watts) then
          metrics.power_source="levelzero";metrics.power_scope=text(entry.power_scope,32)
          metrics.power_measurement=entry.power_measurement;metrics.power_interval_ns=entry.power_interval_ns
          device.quality.power=entry.power_quality or "fresh";device.capabilities.power=true
        end
        if missing(metrics,"power_limit_watts",entry.power_limit_watts) then metrics.power_limit_source="levelzero" end
        if missing(metrics,"board_power_watts",entry.board_power_watts) then metrics.board_power_source="levelzero" end
        local observed=data.sample_started_ns or options.now_ns
        device.sysman=sysman_fields(entry,observed);device.sysman.initialization=text(data.initialization,32)
        append_clocks(device,device.sysman.frequency_domains)
        local limits=Limits.levelzero(device.sysman.frequency_domains,observed)
        if #limits>0 then
          device.performance_limits=device.performance_limits or {domains={}}
          for _,domain in ipairs(limits) do device.performance_limits.domains[#device.performance_limits.domains+1]=domain end
          device.capabilities.performance_limits=true
        end
        local reason=entry.power_reason
        pending=pending or reason=="levelzero_power_warmup" or reason=="levelzero_energy_counter_reset" or reason=="levelzero_energy_counter_gap"
        device.capabilities.levelzero=true
        device.capabilities.frequency=device.capabilities.frequency or #device.sysman.frequency_domains>0
      end
    end
  end
  return {status=(unmatched>0 or duplicates>0 or data.status=="partial" or data.truncated) and "partial" or "ok",
    source="levelzero",driver_count=data.driver_count,device_count=#(data.devices or {}),
    merged_devices=merged,added_devices=added,unmatched_devices=unmatched,duplicates=duplicates,
    pending_measurements=pending,transport=data.transport,sample_started_ns=data.sample_started_ns,
    sample_finished_ns=data.sample_finished_ns,truncated=data.truncated or #(data.devices or {})>64}
end
return M
