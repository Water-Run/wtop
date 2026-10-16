-- Inventory/PDH and native-architecture vendor readers retain separate clocks.
local Common = require("wtop.collectors.common")
local Capability = require("wtop.core.capability")
local NVML = require("wtop.collectors.nvml")
local ZE = require("wtop.collectors.levelzero")
local Worker = require("wtop.collectors.gpu_worker")
local Observations = require("wtop.collectors.gpu_observations")
local Wire = require("wtop.core.worker_wire")
local M = {}
M.__index = M
local sources = { "nvml", "levelzero" }
local vendors = { nvml = "0x10de", levelzero = "0x8086" }
local adapters = { nvml = NVML, levelzero = ZE }

function M.new(base, options, native)
  return setmetatable({id="gpu",default_interval_ms=1000,_method_style=true,
    base=base,options=options or {},native=native,readers={},observations=Observations.new()}, M)
end

function M:_provider(source, state)
  local injected = self.options[source .. "_provider"]
  if type(injected)=="function" then return injected end
  if injected==false then return nil end
  if not state.provider then state.provider,state.stop=adapters[source].default_provider(self.native) end
  return state.provider
end

function M:probe(context)
  self.base:probe(context)
  return Capability.available({source="windows+nvml+levelzero"})
end

local function base_observations(data, result, now, retained, reason)
  data.sample_started_ns=result.sample_started_ns or result.value_timestamp_ns or result.timestamp_ns
  data.sample_finished_ns=result.sample_finished_ns or data.sample_started_ns
  for _, device in ipairs(data.devices or {}) do
    device.capabilities=device.capabilities or {};device.capabilities.windows=true
  end
  Observations.mark(data.devices or {}, {}, "windows", data, now)
  if retained then
    for _, device in ipairs(data.devices or {}) do
      device.partial=true;device.processes=nil
      for _, observation in pairs(device.observations or {}) do
        observation.quality="stale";observation.retained=true;observation.reason=reason
      end
      for _, observation in pairs(device.metric_observations or {}) do
        observation.quality="stale";observation.retained=true;observation.reason=reason
      end
      for key in pairs(device.quality or {}) do device.quality[key]="stale" end
    end
  end
end

local function pci_id(value)
  if type(value)=="number" and value>=0 and value<=65535 and value%1==0 then
    return string.format("0x%04x",value)
  end
  if type(value)=="string" then
    local digits=value:match("^0[xX]([%x]+)$")
    digits=digits and digits:gsub("^0+","")
    if digits and #digits<=4 then
      local number=digits=="" and 0 or tonumber(digits,16)
      if number and number>=0 and number<=65535 then return string.format("0x%04x",number) end
    end
  end
end

local function lookup_for(devices, source)
  local lookup,used,seen={by_bdf={}},{},{}
  for _,device in ipairs(devices) do
    used[device.id]=true
    local bdf=NVML.normalize_bdf(device.pci_bdf)
    if bdf then
      if seen[bdf] then lookup.by_bdf[bdf]=nil
      elseif pci_id(device.vendor_id)==vendors[source] then lookup.by_bdf[bdf]=device end
      seen[bdf]=true
    end
  end
  return lookup,used
end

function M:_query(source, state, now, safe, scan)
  if safe then
    if state.stop then state.stop() end
    state.provider,state.stop,state.batch,state.good,state.pending=nil,nil,nil,nil,nil
    return nil,"safe_mode"
  end
  local sdk,reason
  if state.batch and state.batch.scan==scan and now>=state.batch.at_ns
      and now-state.batch.at_ns<100000000 then
    sdk,reason=state.batch.data,state.batch.reason
  else
    sdk,reason=adapters[source].query(self:_provider(source,state),scan)
    state.batch={at_ns=now,scan=scan,data=sdk,reason=reason}
  end
  if sdk then state.good=sdk;state.pending=nil
  elseif Worker.is_pending(reason) then
    state.pending=state.pending or now
    if state.good and now-state.pending<100000000 then sdk=state.good end
  else state.good=nil;state.pending=nil end
  return sdk,reason
end

function M:sample(context)
  local now=Common.now_ns(context)
  local safe=context and context.safe_mode==true
  if self.closed then return Common.result("error",now,nil,{reason="hardware_worker_closed"}) end
  if self.now and now<self.now then
    self.raw=nil
    for _,state in pairs(self.readers) do state.batch,state.good,state.pending=nil,nil,nil end
  end
  self.now=now;self.observations:begin(self,now,safe)
  local result=self.base:sample(context)
  if result.status=="ok" and type(result.data)=="table" then self.raw=result end
  local retained=result.status~="ok" and self.raw~=nil and not result.defer_publish
  local data=self.raw and Observations.copy(self.raw.data, {nodes=Wire.MAX_NODES,bytes=Wire.MAX_BYTES}) or {devices={}}
  if not data then return Common.result("error",now,nil,{reason="gpu_data_incomplete"}) end
  data.devices=data.devices or {}
  if self.raw then base_observations(data,self.raw,now,retained,result.reason) end
  local scan=not context or context.scan_gpu_processes~=false
  if self.scan~=nil and self.scan~=scan then
    for _,state in pairs(self.readers) do state.batch,state.good,state.pending=nil,nil,nil end
  end
  self.scan=scan
  if not scan then for _,device in ipairs(data.devices) do device.processes=nil end end
  local anchors=Observations.anchors(data.devices)
  local providers,pending,retry,any_reason,any_retained,warming={}
  local observed=self.raw and (self.raw.value_timestamp_ns or self.raw.timestamp_ns) or nil
  for _,source in ipairs(sources) do
    local state=self.readers[source] or {};self.readers[source]=state
    local sdk,reason=self:_query(source,state,now,safe,scan)
    local lookup,used=lookup_for(data.devices,source)
    local association={}
    for bdf,anchor in pairs(anchors) do association[bdf]=anchor end
    local provider={status="unavailable",reason=reason,source=source}
    if sdk then
      -- Provider data may be retained for its next poll. Normalize only a copy.
      local merge_data=Observations.copy(sdk,{nodes=Wire.MAX_NODES,bytes=Wire.MAX_BYTES})
      if merge_data then
        for _,entry in ipairs(merge_data.devices or {}) do
          if type(entry)=="table" then
            entry.vendor_id=pci_id(entry.vendor_id) or (source=="nvml" and vendors.nvml or nil)
            entry.device_id=pci_id(entry.device_id)
            local bdf=NVML.normalize_bdf(entry.pci_bdf)
            local device=bdf and lookup.by_bdf[bdf]
            if device and (entry.vendor_id~=pci_id(device.vendor_id)
                or entry.device_id and entry.device_id~=pci_id(device.device_id)
                or source=="levelzero" and not entry.device_id) then
              lookup.by_bdf[bdf]=nil;association[bdf]=false
            end
          end
        end
        self.observations:observe(source,merge_data,association,now)
        local before=Observations.before(data.devices)
        if source=="nvml" then
          provider=NVML.merge(data.devices,lookup,merge_data,{used_ids=used,now_ns=now,include_processes=scan})
        else provider=ZE.merge(data.devices,merge_data,lookup,{used_ids=used,now_ns=now}) end
        Observations.mark(data.devices,before,source,merge_data,now)
        if sdk.sample_started_ns then observed=math.max(observed or 0,sdk.sample_started_ns) end
      else
        provider.status="partial"
        provider.reason="gpu_data_incomplete"
      end
    end
    local count,history=self.observations:apply(source,data.devices,lookup,used,association,now,reason)
    if count>0 then
      provider.retained=true;provider.retained_device_count=count;provider.quality=sdk and "partial" or "stale"
      provider.attempted_at_ns=now;provider.retention_truncated=history.truncated
      if not sdk then
        provider.sample_started_ns=history.data.sample_started_ns;provider.sample_finished_ns=history.data.sample_finished_ns
        provider.transport=history.data.transport
      end
      any_retained=true
    end
    local is_pending,delay=Worker.is_pending(reason),select(2,Worker.retry(reason))
    pending=pending or is_pending
    if delay then retry=math.min(retry or delay,delay) end
    any_reason=any_reason or reason
    warming=warming or provider.pending_measurements
    providers[source]=provider
  end
  if #data.devices==0 then
    local output=Common.result("unavailable",now,nil,{reason=result.reason or any_reason or "no_display_adapters",
      retry_after_ms=result.retry_after_ms or retry})
    output.sampling_pending=result.sampling_pending or pending
    return output
  end
  local partial=retained or any_retained or data.partial==true
  for _,provider in pairs(providers) do partial=partial or provider.status=="partial" end
  data.schema=data.schema or "dev.waterrun.wtop.gpu/v2"
  data.partial=partial;data.providers=providers
  data.providers.windows={status=result.status,reason=result.reason,
    quality=retained and "stale" or result.quality,retained=retained,
    sample_started_ns=self.raw and self.raw.sample_started_ns,
    sample_finished_ns=self.raw and self.raw.sample_finished_ns,transport=self.raw and self.raw.transport}
  data.by_id={};local processes=0
  for _,device in ipairs(data.devices) do
    data.by_id[device.id]=device;processes=processes+#(device.processes and device.processes.list or {})
  end
  data.summary=data.summary or {};data.summary.device_count=#data.devices;data.summary.process_count=processes
  local output=Common.result("ok",now,data,{quality=partial and "partial" or "fresh",
    reason=partial and "gpu_data_incomplete" or nil,retry_after_ms=result.retry_after_ms or ((pending or warming) and 250 or nil)})
  output.capability=Capability.available({source="windows+nvml+levelzero"})
  output.sampling_pending=result.sampling_pending or pending or warming
  for _,state in pairs(self.readers) do
    if state.pending and now-state.pending<100000000 then output.retry_after_ms=25 end
  end
  output.value_timestamp_ns=observed
  return output
end

function M:close()
  self.closed=true;self.raw=nil;self.observations:clear()
  for _,state in pairs(self.readers) do if state.stop then state.stop() end end
  self.readers={}
  if self.base.close then self.base:close() end
end

return M
