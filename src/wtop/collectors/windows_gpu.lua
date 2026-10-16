-- Windows inventory/PDH and vendor readers keep independent observations.
local Common = require("wtop.collectors.common")
local Capability = require("wtop.core.capability")
local NVML = require("wtop.collectors.nvml")
local Worker = require("wtop.collectors.gpu_worker")
local Observations = require("wtop.collectors.gpu_observations")
local Wire = require("wtop.core.worker_wire")
local M = {}
M.__index = M

function M.new(base, options, native)
  return setmetatable({id="gpu",default_interval_ms=1000,_method_style=true,
    base=base,options=options,native=native,observations=Observations.new()}, M)
end

function M:_provider()
  if self.options.nvml_provider then return self.options.nvml_provider end
  if not self.provider then self.provider,self.stop=NVML.default_provider(self.native) end
  return self.provider
end

function M:probe(context)
  -- The SDK is optional. Its first asynchronous reply may discover headless
  -- adapters even when the host inventory has none.
  self.base:probe(context)
  return Capability.available({source="windows+nvml"})
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

local function lookup_for(devices)
  local lookup,used,seen={by_bdf={}},{},{}
  for _,device in ipairs(devices) do
    used[device.id]=true
    local bdf=NVML.normalize_bdf(device.pci_bdf)
    if bdf then
      if seen[bdf] then lookup.by_bdf[bdf]=nil
      elseif device.vendor_id=="0x10de" then lookup.by_bdf[bdf]=device end
      seen[bdf]=true
    end
  end
  return lookup,used
end

function M:sample(context)
  local now=Common.now_ns(context)
  local safe=context and context.safe_mode==true
  if self.closed then return Common.result("error",now,nil,{reason="hardware_worker_closed"}) end
  if self.now and now<self.now then self.raw=nil;self.batch=nil;self.sdk_good=nil;self.sdk_pending=nil end
  self.now=now;self.observations:begin(self,now,safe)
  local result=self.base:sample(context)
  if result.status=="ok" and type(result.data)=="table" then self.raw=result end
  local retained=result.status~="ok" and self.raw~=nil and not result.defer_publish
  local data=self.raw and Observations.copy(self.raw.data, {nodes=Wire.MAX_NODES,bytes=Wire.MAX_BYTES}) or {devices={}}
  if not data then return Common.result("error",now,nil,{reason="gpu_data_incomplete"}) end
  data.devices=data.devices or {}
  if self.raw then base_observations(data,self.raw,now,retained,result.reason) end
  local sdk,reason
  local scan=not context or context.scan_gpu_processes~=false
  if self.scan~=nil and self.scan~=scan then self.batch=nil;self.sdk_good=nil;self.sdk_pending=nil end
  self.scan=scan
  if not scan then
    for _,device in ipairs(data.devices) do device.processes=nil end
  end
  if safe then
    if self.stop then self.stop() end
    self.provider,self.stop,self.batch,self.sdk_good,self.sdk_pending=nil,nil,nil,nil,nil
    reason="safe_mode"
  elseif self.batch and self.batch.scan==scan and now>=self.batch.at_ns and now-self.batch.at_ns<100000000 then
    sdk,reason=self.batch.data,self.batch.reason
  else
    sdk,reason=NVML.query(self:_provider(),scan)
    self.batch={at_ns=now,scan=scan,data=sdk,reason=reason}
  end
  if sdk then self.sdk_good=sdk;self.sdk_pending=nil
  elseif Worker.is_pending(reason) then
    self.sdk_pending=self.sdk_pending or now
    if self.sdk_good and now-self.sdk_pending<100000000 then sdk=self.sdk_good end
  else self.sdk_good=nil;self.sdk_pending=nil end
  local lookup,used=lookup_for(data.devices)
  local anchors=Observations.anchors(data.devices)
  local provider={status="unavailable",reason=reason,source="nvml"}
  if sdk then
    self.observations:observe("nvml",sdk,anchors,now)
    -- A newly reported SDK identity cannot inherit a cached adapter whose
    -- device ID disagrees, even if its PCI slot was reused.
    local merge_lookup={by_bdf={}}
    for bdf,device in pairs(lookup.by_bdf) do merge_lookup.by_bdf[bdf]=device end
    for _,entry in ipairs(sdk.devices or {}) do
      local bdf=NVML.normalize_bdf(entry.pci_bdf)
      local device=bdf and merge_lookup.by_bdf[bdf]
      if device and entry.device_id and device.device_id~=entry.device_id then merge_lookup.by_bdf[bdf]=nil end
    end
    local before=Observations.before(data.devices)
    provider=NVML.merge(data.devices,merge_lookup,sdk,{used_ids=used,now_ns=now,include_processes=scan})
    Observations.mark(data.devices,before,"nvml",sdk,now)
  end
  local count,state=self.observations:apply("nvml",data.devices,lookup,used,anchors,now,reason)
  if count>0 then
    provider.retained=true;provider.retained_device_count=count;provider.quality=sdk and "partial" or "stale"
    provider.attempted_at_ns=now;provider.retention_truncated=state.truncated
    if not sdk then
      provider.sample_started_ns=state.data.sample_started_ns;provider.sample_finished_ns=state.data.sample_finished_ns
      provider.transport=state.data.transport
    end
  end
  local pending,retry=Worker.is_pending(reason),select(2,Worker.retry(reason))
  if #data.devices==0 then
    local output=Common.result("unavailable",now,nil,{reason=result.reason or reason or "no_display_adapters",
      retry_after_ms=result.retry_after_ms or retry})
    output.sampling_pending=result.sampling_pending or pending
    return output
  end
  local partial=retained or count>0 or provider.status=="partial" or data.partial==true
  data.schema=data.schema or "dev.waterrun.wtop.gpu/v2"
  data.partial=partial;data.providers={windows={status=result.status,reason=result.reason,
    quality=retained and "stale" or result.quality,retained=retained,
    sample_started_ns=self.raw and self.raw.sample_started_ns,
    sample_finished_ns=self.raw and self.raw.sample_finished_ns,transport=self.raw and self.raw.transport},nvml=provider}
  data.by_id={};local processes=0
  for _,device in ipairs(data.devices) do
    data.by_id[device.id]=device;processes=processes+#(device.processes and device.processes.list or {})
  end
  data.summary=data.summary or {};data.summary.device_count=#data.devices;data.summary.process_count=processes
  local output=Common.result("ok",now,data,{quality=partial and "partial" or "fresh",
    reason=partial and "gpu_data_incomplete" or nil,retry_after_ms=result.retry_after_ms or (pending and retry or nil)})
  output.capability=Capability.available({source="windows+nvml"})
  output.sampling_pending=result.sampling_pending or pending
  if pending and self.sdk_pending and now-self.sdk_pending<100000000 then output.retry_after_ms=25 end
  local observed=self.raw and (self.raw.value_timestamp_ns or self.raw.timestamp_ns) or nil
  if sdk and sdk.sample_started_ns then observed=math.max(observed or 0,sdk.sample_started_ns) end
  output.value_timestamp_ns=observed
  return output
end

function M:close()
  self.closed=true;self.raw=nil;self.batch=nil;self.observations:clear()
  if self.stop then self.stop() end
  if self.base.close then self.base:close() end
end

return M
