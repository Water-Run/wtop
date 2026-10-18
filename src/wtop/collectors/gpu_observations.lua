-- Keep vendor observations separate from the current DRM inventory. A failed
-- vendor cannot erase another vendor's data, or renew an older measurement.
local NVML = require("wtop.collectors.nvml")
local AMD = require("wtop.collectors.amdsmi")
local ZE = require("wtop.collectors.levelzero")
local ADL = require("wtop.collectors.adl")
local PowerSession = require("wtop.model.gpu_power_session")
local M = {}
M.__index = M

local groups = {
  utilization_percent = "utilization", memory_used_bytes = "memory",
  memory_total_bytes = "memory", frequency_current_hz = "frequency",
  temperature_celsius = "temperature", power_watts = "power",
  hotspot_temperature_celsius = "temperature", graphics_voltage_volts = "voltage",
  fan_speed_percent = "fan", fan_speed_rpm = "fan",
}
local function finite(value)
  return type(value)=="number" and value==value and value>=0 and value<math.huge
end
local function copy(value, budget, seen, depth)
  local kind=type(value)
  if kind~="table" then
    if kind=="string" then budget.bytes=budget.bytes-#value end
    budget.nodes=budget.nodes-1
    if budget.nodes<0 or budget.bytes<0 then error("observation budget",0) end
    if kind=="string" or kind=="number" or kind=="boolean" then return value end
    return nil
  end
  if seen[value] then return seen[value] end
  if depth>16 then error("observation depth",0) end
  local result={};seen[value]=result
  for key,item in pairs(value) do
    if type(key)=="string" or type(key)=="number" then
      local name=copy(key,budget,seen,depth+1)
      result[name]=copy(item,budget,seen,depth+1)
    end
  end
  return result
end
local function clone(value,budget)
  local ok,result=pcall(copy,value,budget or {nodes=65536,bytes=1048576},{},0)
  return ok and result or nil
end
local function observed(data,now)
  return finite(data.sample_started_ns) and data.sample_started_ns<=now
    and data.sample_started_ns or now
end
local function metadata(source,data,now,retained,reason)
  return {source=source,observed_at_ns=observed(data,now),
    sample_started_ns=data.sample_started_ns,sample_finished_ns=data.sample_finished_ns,
    received_at_ns=now,quality=retained and "stale" or "fresh",
    retained=retained or false,reason=reason}
end
local function metric_method(observation,source,device,key)
  if source=="adl"and device.adl then
    observation.method=device.adl.metric_methods and device.adl.metric_methods[key]
    if observation.method=="shared_memory"or observation.method=="query"then
      observation.hardware_timestamp_available=false
      observation.measurement="driver_snapshot"
    end
  end
end

function M.copy(value, budget) return clone(value, budget) end

function M.new() return setmetatable({sources={},inventory={},generation=0},M) end
function M:begin(fs,now,safe)
  if self.fs~=fs or (self.now and now<self.now) or safe or self.generation==math.maxinteger then
    self.sources={};self.inventory={};self.inventory_evicted=nil;self.inventory_seen=nil;self.generation=0
  end
  self.fs,self.now=fs,now;self.generation=self.generation+1
end
function M:clear()
  self.sources={};self.inventory={};self.inventory_evicted=nil;self.inventory_seen=nil;self.fs=nil;self.now=nil
end

-- A completed inventory can establish a disappearance, unlike a timeout or a
-- truncated listing. Keep bounded tombstones so the same address cannot renew
-- a packet captured before its disappearance/reappearance was observed.
function M:inventory_frame(anchors,at,complete)
  self.inventory_seen=true
  if not finite(at) or at>self.now then at=self.now end
  local count=0
  for bdf,record in pairs(self.inventory) do
    if complete and anchors[bdf]==nil and record.anchor~=nil then
      record.anchor=nil;record.changed_at_ns=at
    end
    count=count+1
  end
  for bdf,anchor in pairs(anchors) do
    local record=self.inventory[bdf]
    if record then
      if record.anchor~=anchor then record.anchor=anchor;record.changed_at_ns=at end
    else
      if count>=4096 then
        for old,history in pairs(self.inventory) do
          if history.anchor==nil then
            self.inventory[old]=nil;count=count-1;self.inventory_evicted=true;break
          end
        end
      end
      if count<4096 then
        self.inventory[bdf]={anchor=anchor,changed_at_ns=self.inventory_evicted and at or nil}
        count=count+1
      end
    end
  end
end

local function binding(entry,data,anchors)
  if type(entry)~="table" then return end
  local bdf=NVML.normalize_bdf(entry.pci_bdf)
  local parts={}
  for _,value in ipairs({bdf or false,entry.uuid or false,entry.index or false,
      entry.vendor_id or false,entry.device_id or false,entry.name or false,
      entry.driver_version or data.driver_version or false}) do
    local kind=type(value)
    if kind~="string" and kind~="number" and kind~="boolean" then return end
    local token=tostring(value);if #token>4096 then return end
    parts[#parts+1]=kind..#token..":"..token
  end
  local anchor=bdf and anchors[bdf]
  return table.concat(parts,"|"),anchor==nil and true or anchor,bdf
end

function M:_frame(source,data,anchors,now)
  local previous=self.sources[source]
  local captured=data.sample_started_ns
  if captured~=nil and (not finite(captured) or captured>now
      or previous and previous.capture_ns and captured<previous.capture_ns) then
    return nil,source.."_invalid_response"
  end
  local replay=previous and captured~=nil and captured==previous.capture_ns
  local ready,bindings={devices={}},{}
  for key,value in pairs(data) do if key~="devices" then ready[key]=value end end
  local rejected=false
  for index,entry in ipairs(data.devices) do
    if index>64 then ready.truncated=true;break end
    local key,anchor,bdf=binding(entry,data,anchors)
    local inventory=bdf and self.inventory[bdf]
    local before_change=self.inventory_seen and bdf and anchors[bdf]~=nil and not inventory
      or inventory and inventory.changed_at_ns and (not finite(captured) or captured<inventory.changed_at_ns)
    if not key or before_change or replay and (not previous.bindings
        or previous.bindings[key]~=anchor) then rejected=true
    else ready.devices[#ready.devices+1]=entry;bindings[key]=anchor end
  end
  if rejected then
    if #ready.devices==0 then return nil,source.."_invalid_response" end
    ready.status="partial"
  end
  -- Replaying a subset must not forget the original batch's other bindings.
  if replay then bindings=previous.bindings end
  return ready,nil,bindings
end

-- This is a conservative association guard, not a replacement for a device
-- UUID. Changed/missing DRM identities invalidate the old association.
function M.anchors(devices)
  local result,seen={},{}
  for _,d in ipairs(devices) do
    local bdf=d.pci_bdf
    if bdf then
      if seen[bdf] then result[bdf]=false
      else
        seen[bdf]=true
        local p=d.pci or {};local n=(d.drm_nodes or {})[1] or {}
        if d.identity_quality=="fresh" and d.vendor_id and d.device_id and d.driver then
          local values={d.id,d.class_path,d.device_target,d.vendor_id,d.device_id,d.driver,
            p.subsystem_vendor_id,p.subsystem_device_id,p.revision,p.modalias,n.dev}
          local parts={}
          for i=1,11 do parts[i]=tostring(values[i]) end
          result[bdf]=table.concat(parts,"\0")
        else result[bdf]=false end
      end
    end
  end
  return result
end

function M.before(devices)
  local result={}
  for _,device in ipairs(devices) do
    local fields={};for key in pairs(device.metrics or {}) do fields[key]=true end
    result[device]=fields
  end
  return result
end
function M.mark(devices,before,source,data,now)
  for _,device in ipairs(devices) do
    if device.capabilities and device.capabilities[source] then
      device.observations=device.observations or {}
      device.observations[source]=metadata(source,data,now)
      device.metric_observations=device.metric_observations or {}
      device.quality=device.quality or {}
      for key in pairs(device.metrics or {}) do
        if not (before[device] and before[device][key]) then
          local observation=metadata(source,data,now)
          metric_method(observation,source,device,key)
          local group=groups[key]
          if group then
            if group=="power" then observation.quality=device.quality.power or "fresh"
            else device.quality[group]="fresh" end
          end
          device.metric_observations[key]=observation
        end
      end
    end
  end
end

function M:observe(source,data,anchors,now)
  if not data then return end
  local reason,bindings
  data,reason,bindings=self:_frame(source,data,anchors,now)
  if not data then return nil,reason end
  local devices,lookup={}, {by_bdf={}}
  local limited={devices={}}
  for key,value in pairs(data) do if key~="devices" then limited[key]=value end end
  for index=1,math.min(#data.devices,64) do limited.devices[index]=data.devices[index] end
  local options={used_ids={},now_ns=observed(data,now),include_processes=false}
  if source=="nvml" then NVML.merge(devices,lookup,limited,options)
  elseif source=="amdsmi" then AMD.merge(devices,lookup,limited,options)
  elseif source=="adl" then ADL.merge(devices,limited,lookup,options)
  else ZE.merge(devices,limited,lookup,options) end
  local previous=self.sources[source]
  local old_devices={}
  for _,record in ipairs(previous and previous.records or {})do old_devices[#old_devices+1]=record.device end
  PowerSession.attach(devices,old_devices,source,data,now,anchors)
  local state={records={},data={sample_started_ns=data.sample_started_ns,
    sample_finished_ns=data.sample_finished_ns,transport=data.transport},truncated=data.truncated==true,
    capture_ns=data.sample_started_ns,bindings=bindings}
  local budget={nodes=65536,bytes=1048576}
  local ids,bdfs,uuids={},{},{}
  for _,device in ipairs(devices) do
    ids[device.id]=true
    if device.pci_bdf then bdfs[device.pci_bdf]=true end
    if device.vendor_uuid then uuids[device.vendor_uuid]=true end
  end
  for _,device in ipairs(devices) do
    device.processes=nil -- a retained process identifier is not a live process
    local template=clone(device,budget)
    if not template then state.truncated=true;break end
    state.records[#state.records+1]={device=template,anchor=device.pci_bdf and anchors[device.pci_bdf],
      data=state.data,observed_at_ns=observed(data,now),received_at_ns=now,generation=self.generation}
  end
  if previous and (data.status=="partial" or data.truncated) then
    for _,record in ipairs(previous.records) do
      local d=record.device
      if not ids[d.id] and not (d.pci_bdf and bdfs[d.pci_bdf])
          and not (d.vendor_uuid and uuids[d.vendor_uuid]) and (d.pci_bdf or d.vendor_uuid) then
        if #state.records>=64 then state.truncated=true;break end
        local template=clone(d,budget)
        if not template then state.truncated=true;break end
        state.records[#state.records+1]={device=template,anchor=record.anchor,data=record.data,
          observed_at_ns=record.observed_at_ns,received_at_ns=record.received_at_ns,
          generation=record.generation}
      end
    end
  end
  self.sources[source]=state
  return data
end

local function same_pci_id(left,right)
  if left==nil or right==nil then return true end
  local a,b=tonumber(left),tonumber(right)
  if a and b then return a==b end
  return tostring(left):lower()==tostring(right):lower()
end
function M:publish_power_sessions(devices,anchors,now)
  local bdfs,uuids={},{}
  for _,device in ipairs(devices)do
    if device.pci_bdf then bdfs[device.pci_bdf]=bdfs[device.pci_bdf]==nil and device or false end
    if device.vendor_uuid then uuids[device.vendor_uuid]=uuids[device.vendor_uuid]==nil and device or false end
    device.power_sessions={}
  end
  for _,source in ipairs(PowerSession.SOURCES)do
    for _,record in ipairs(self.sources[source]and self.sources[source].records or {})do
      local template=record.device;local bdf=template.pci_bdf
      local anchor=bdf and anchors[bdf]
      local valid=(record.anchor and record.anchor==anchor)or(record.anchor==nil and anchor==nil)
      if valid then
        local pci=bdf and bdfs[bdf]
        local uuid=template.vendor_uuid and uuids[template.vendor_uuid]
        local device=pci or uuid
        if type(device)=="table"and not(pci and uuid and pci~=uuid)then
          local observation=device.observations and device.observations[source]
          local contradictory=template.vendor_uuid and device.vendor_uuid and template.vendor_uuid~=device.vendor_uuid
            or bdf and device.pci_bdf and bdf~=device.pci_bdf
            or not same_pci_id(template.vendor_id,device.vendor_id)
            or not same_pci_id(template.device_id,device.device_id)
          if observation and not contradictory then
            for _,row in ipairs(PowerSession.rows(template,source,now,observation))do
              if #device.power_sessions<16 then device.power_sessions[#device.power_sessions+1]=row end
            end
          end
        end
      end
    end
  end
end

local function stale(device)
  device.partial=true;device.quality=device.quality or {}
  for key in pairs(device.metrics or {}) do
    local group=groups[key];if group then device.quality[group]="stale" end
  end
  for _,key in ipairs({"power_instant_quality","power_average_quality"}) do
    if device.metrics[key]=="fresh" then device.metrics[key]="stale" end
  end
  for _,domain in ipairs(device.performance_limits and device.performance_limits.domains or {}) do
    domain.quality="stale"
  end
  for _,domain in ipairs(device.frequencies and device.frequencies.domains or {}) do domain.quality="stale" end
  if device.adl then device.adl.quality="stale" end
  if device.sysman then
    device.sysman.quality="stale"
    for _,domain in ipairs(device.sysman.frequency_domains or {}) do domain.throttle_quality="stale" end
    for _,domain in ipairs(device.sysman.power_domains or {}) do domain.quality="stale" end
  end
end
function M:apply(source,devices,lookup,used,anchors,now,reason)
  local state=self.sources[source];if not state then return 0 end
  local retained,keep=0,{}
  for _,record in ipairs(state.records) do
    local template=record.device;local bdf=template.pci_bdf
    local anchor=bdf and anchors[bdf]
    local valid=(record.anchor and record.anchor==anchor) or (record.anchor==nil and anchor==nil)
    if valid then
      keep[#keep+1]=record
      if record.generation~=self.generation then
        local target=bdf and lookup.by_bdf[bdf]
        -- Two SDKs can identify the same headless card differently. An old
        -- UUID cannot establish that relationship to a new live observation.
        local compatible=not target or anchor or
          (target.vendor_uuid and target.vendor_uuid==template.vendor_uuid)
        local value=compatible and clone(template) or nil
        if value then
          stale(value)
          if not target then
            value.identity_quality="stale";value.quality.identity="stale"
            while used[value.id] do value.id=value.id.."+" end
            value.stable_id=value.id
            value.processes={list={},by_id={},clients={},clients_by_id={},
              quality="unavailable",summary={process_count=0,client_count=0}}
            value.capabilities.processes=false;value.capabilities.process_memory=false
            used[value.id]=true;target=value;devices[#devices+1]=target
            if bdf then lookup.by_bdf[bdf]=target end
          end
          target.metrics=target.metrics or {};target.quality=target.quality or {}
          target.metric_observations=target.metric_observations or {}
          for key,item in pairs(value.metrics or {}) do
            if target==value or target.metrics[key]==nil then
              target.metrics[key]=item
              local observation=metadata(source,record.data,record.received_at_ns,true,reason)
              metric_method(observation,source,value,key)
              observation.observed_at_ns=record.observed_at_ns
              target.metric_observations[key]=observation
              if groups[key] then target.quality[groups[key]]="stale" end
            end
          end
          if target~=value then
            if value.adl and not target.adl then target.adl=value.adl end
            if value.sysman and not target.sysman then target.sysman=value.sysman end
            if value.frequencies and #(value.frequencies.domains or {})>0
                and #(target.frequencies and target.frequencies.domains or {})==0 then
              target.frequencies=value.frequencies
            end
            target.performance_limits=target.performance_limits or {domains={}}
            local existing={}
            for _,domain in ipairs(target.performance_limits.domains) do
              existing[tostring(domain.source_kind)..":"..tostring(domain.id)]=true
            end
            for _,domain in ipairs(value.performance_limits and value.performance_limits.domains or {}) do
              if not existing[tostring(domain.source_kind)..":"..tostring(domain.id)] then
                target.performance_limits.domains[#target.performance_limits.domains+1]=domain
              end
            end
          end
          target.capabilities=target.capabilities or {};target.capabilities[source]=true
          for key,group in pairs(groups) do
            if target.metrics[key]~=nil then target.capabilities[group]=true end
          end
          target.partial=true;target.observations=target.observations or {}
          local observation=metadata(source,record.data,record.received_at_ns,true,reason)
          observation.observed_at_ns=record.observed_at_ns;observation.attempted_at_ns=now
          target.observations[source]=observation
          retained=retained+1
        end
      end
    end
  end
  state.records=keep
  return retained,state
end

return M
