local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local CPUInfo = require("wtop.collectors.cpu_info")
local FS = require("wtop.linux.fs")
local Native = require("wtop.native")
local M = {}
M.__index = M

-- Unscaled, 64-bit feedback counters on these Intel Core families. A counter
-- capability alone does not describe older Atom/Phi scaling or counter width.
local MODELS = { [0x4e]=true,[0x5e]=true,[0x8e]=true,[0x9e]=true,
    [0xa5]=true,[0xa6]=true,[0x7d]=true,[0x7e]=true,[0x8c]=true,[0x8d]=true,
    [0x97]=true,[0x9a]=true,[0xba]=true,[0xb7]=true,[0xbf]=true }
local MIN_INTERVAL = 100000000
local MAX_INTERVAL = 30000000000
local MAX_RATE = 20000000000

local function uint(text)
    text = type(text)=="string" and Common.trim(text) or nil
    if not text or not text:match("^%d+$") then return nil end
    local n=tonumber(text)
    return n and math.type(n)=="integer" and n<=2147483647 and n or nil
end
local function finite(v)
    return type(v)=="number" and v==v and v>=0 and v<math.huge
end
local function roster(self,fs)
    local text,err=fs:read(self.cpu_path.."/online",65536)
    if not text then return nil,err end
    local ids=CPUInfo.parse_cpu_list(Common.trim(text),8192,8191)
    if not ids then return nil,{kind="parse_error",message="invalid_online_cpu_list"} end
    local body,read_error=fs:read(self.cpuinfo_path,4*1024*1024)
    if not body then return nil,read_error end
    local records,_,cut=CPUInfo.parse_cpuinfo(body,self.max_cpus+1)
    if not records then return nil,{kind="parse_error",message="invalid_cpuinfo"} end
    local by_id,duplicates={},{}
    for _,cpu in ipairs(records) do
        local id=uint(cpu.processor)
        if id then
            if by_id[id] then duplicates[id]=true else by_id[id]=cpu end
        end
    end
    local result={cpus={},truncated=cut==true or #ids>self.max_cpus,supported=0}
    local signature={}
    for index=1,math.min(#ids,self.max_cpus) do
        local id=ids[index];local cpu=by_id[id] or {}
        local flags={};for flag in (cpu.flags or ""):gmatch("%S+") do flags[flag]=true end
        local family,model=uint(cpu["cpu family"]),uint(cpu.model)
        local base=self.cpu_path.."/cpu"..id.."/topology/"
        local package,core=uint(fs:read(base.."physical_package_id",64)),uint(fs:read(base.."core_id",64))
        local supported=cpu.vendor_id=="GenuineIntel" and family==6 and MODELS[model]==true
            and flags.aperfmperf==true and not flags.hypervisor and not duplicates[id]
        local identity=table.concat({id,cpu.vendor_id or "?",family or "?",model or "?",
            package or "?",core or "?",tostring(flags.aperfmperf),tostring(flags.hypervisor),
            tostring(duplicates[id])},":")
        result.cpus[#result.cpus+1]={id=id,package_id=package,core_id=core,
            supported=supported,identity=identity}
        if supported then result.supported=result.supported+1 end
        signature[#signature+1]=identity
    end
    result.signature=table.concat(signature,";")
    return result
end

function M.new(options)
    options=options or {}
    if type(options)~="table" then error("CPU clock options must be a table",2) end
    return setmetatable({id="cpu_clocks",_method_style=true,fs=options.fs or FS.default,
        reader=options.reader==nil and Native.read_cpu_clock_counters or options.reader,
        reader_default=options.reader==nil,
        cpu_path=Common.absolute_path("cpu_path",options.cpu_path,"/sys/devices/system/cpu"),
        cpuinfo_path=Common.absolute_path("cpuinfo_path",options.cpuinfo_path,"/proc/cpuinfo"),
        max_cpus=Common.positive_integer("max_cpus",options.max_cpus,256,8192),
        default_interval_ms=Common.positive_integer("interval_ms",options.interval_ms,1000),previous={}},M)
end

function M:probe(context)
    if type(self.reader)~="function" or (self.reader_default and Common.fs(context,self.fs)~=FS.default) then
        return Capability.unavailable("cpu_clock_reader_unavailable")
    end
    return Capability.available({source="IA32_APERF/IA32_MPERF"})
end

local function decode(bytes,metadata,now)
    if type(bytes)~="string" or #bytes~=16 or type(metadata)~="table" then return nil end
    local a0,a1,m0,m1=metadata.aperf_started_ns,metadata.aperf_finished_ns,
        metadata.mperf_started_ns,metadata.mperf_finished_ns
    for _,value in ipairs({a0,a1,m0,m1}) do if not finite(value) or math.type(value)~="integer" then return nil end end
    if not a0 or not a1 or not m0 or not m1 or a0>a1 or a1>m0 or m0>m1 or m1>now then return nil end
    local a,m=string.unpack("<i8i8",bytes)
    return {aperf=a,mperf=m,at_ns=a0+(a1-a0)//2,
        mperf_at_ns=m0+(m1-m0)//2,span_ns=m1-a0,
        uncertainty_ns=(a1-a0+1)//2,aperf_hex=string.format("0x%016x",a),
        mperf_hex=string.format("0x%016x",m)}
end

function M:sample(context)
    local started=Common.now_ns(context)
    local fs=Common.fs(context,self.fs)
    if type(self.reader)~="function" or (self.reader_default and fs~=FS.default) then
        self.previous={};self.signature=nil;self.reader_identity=nil
        return Common.result("unavailable",started,nil,{quality="unavailable",reason="cpu_clock_reader_unavailable"})
    end
    local before,err=roster(self,fs)
    if not before then
        self.previous={};self.signature=nil
        local status=FS.error_status(err)
        local result=Common.result(status,started,nil,{quality=status,reason="cpu_clock_data_incomplete"})
        result.capability=status=="denied" and Capability.denied(result.reason) or Capability.unavailable(result.reason)
        return result
    end
    if self.fs_identity~=fs or self.signature~=before.signature or self.reader_identity~=self.reader then self.previous={} end
    self.fs_identity,self.signature,self.reader_identity=fs,before.signature,self.reader
    local data={schema="dev.waterrun.wtop.cpu-clocks/v1",cpus={},supported_cpus=before.supported,
        measured_cpus=0,read_cpus=0,denied_cpus=0,truncated=before.truncated,
        source="IA32_APERF/IA32_MPERF",scope="logical_cpu",includes_idle=true}
    local pending,partial=false,before.truncated
    for _,cpu in ipairs(before.cpus) do
        local row={id=cpu.id,package_id=cpu.package_id,core_id=cpu.core_id,
            source="/dev/cpu/"..cpu.id.."/msr",quality="unavailable",reason="cpu_clock_not_supported"}
        data.cpus[#data.cpus+1]=row
        if not cpu.supported then partial=true;self.previous[cpu.id]=nil;goto continue end
        local ok,bytes,metadata,errno=pcall(self.reader,cpu.id)
        local current=ok and decode(bytes,metadata,Common.now_ns(context)) or nil
        if not current then
            if type(errno)=="number" and math.type(errno)=="integer" and errno>0 then row.read_errno=errno end
            row.quality=(errno==1 or errno==13) and "denied" or "error"
            if errno==2 or errno==6 or errno==19 then row.quality="unavailable" end
            row.reason="cpu_clock_read_failed"
            if row.quality=="denied" then data.denied_cpus=data.denied_cpus+1 end
            self.previous[cpu.id]=nil;partial=true;goto continue
        end
        data.read_cpus=data.read_cpus+1
        row.observed_at_ns,row.sample_span_ns=current.at_ns,current.span_ns
        row.aperf_hex,row.mperf_hex=current.aperf_hex,current.mperf_hex
        local old=self.previous[cpu.id]
        local interval=old and current.at_ns-old.at_ns
        self.previous[cpu.id]=current
        row.quality="gap"
        row.reason="cpu_clock_warmup"
        if not interval then pending=true;goto continue end
        if interval<0 or interval>MAX_INTERVAL then row.reason="cpu_clock_interval_invalid";pending=true;goto continue end
        if interval<MIN_INTERVAL then
            self.previous[cpu.id]=old;pending=true;goto continue
        end
        row.interval_ns=interval
        row.interval_uncertainty_ns=current.uncertainty_ns+old.uncertainty_ns
        if current.span_ns>math.min(10000000,interval//100)
            or old.span_ns>math.min(10000000,interval//100) then
            row.reason="cpu_clock_sample_skew";partial=true;goto continue
        end
        -- Signed Lua arithmetic wraps modulo 2^64. Real 64-bit rollover gives
        -- a small positive delta; resets or implausible jumps remain gaps.
        local a,m=current.aperf-old.aperf,current.mperf-old.mperf
        local effective=a*1000000000.0/interval
        local m_interval=current.mperf_at_ns-old.mperf_at_ns
        local reference=m_interval>0 and m*1000000000.0/m_interval or nil
        if a<0 or m<0 or not finite(effective) or effective>MAX_RATE
            or not finite(reference) or reference>MAX_RATE then
            row.reason="cpu_clock_counter_reset";partial=true;goto continue
        end
        row.quality="fresh"
        row.reason=nil
        row.effective_hz=effective
        row.aperf_delta_cycles,row.mperf_delta_cycles=a,m
        if m>0 then row.active_performance_ratio=(a+0.0)/m end
        data.measured_cpus=data.measured_cpus+1
        ::continue::
    end
    local after=roster(self,fs)
    if not after or after.signature~=before.signature then
        self.previous={};self.signature=nil;partial=true;pending=true
        data.measured_cpus=0
        for _,row in ipairs(data.cpus) do
            row.effective_hz,row.active_performance_ratio=nil,nil
            row.aperf_delta_cycles,row.mperf_delta_cycles=nil,nil
            row.quality="gap"
            row.reason="cpu_clock_identity_changed"
        end
    end
    local finished=Common.now_ns(context)
    if before.supported==0 then
        local result=Common.result("unavailable",finished,nil,{quality="unavailable",reason="cpu_clock_not_supported"})
        result.capability=Capability.unavailable(result.reason);return result
    end
    local result=Common.result("ok",finished,data,{quality=partial and "partial" or (pending and "gap" or "fresh"),
        reason=partial and "cpu_clock_data_incomplete" or (pending and "cpu_clock_warmup" or nil),
        source=data.source,duration_ns=Common.elapsed_ns(finished,started) or 0})
    result.sampling_pending=pending
    if pending then result.retry_after_ms=100 end
    result.capability=data.read_cpus>0 and Capability.available({source=data.source,
        details={measured_cpus=data.measured_cpus,truncated=data.truncated}})
        or data.denied_cpus>0 and Capability.denied("cpu_clock_read_failed")
        or Capability.unavailable("cpu_clock_read_failed")
    return result
end

return M
