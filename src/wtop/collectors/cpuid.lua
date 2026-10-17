-- Child-only native instruction probe; the parent uses HardwareWorker's lease.
local Common=require("wtop.collectors.common")
local Capability=require("wtop.core.capability")
local Native=require("wtop.native")
local M={};M.__index=M
function M.new(options)
 options=options or {}
 return setmetatable({id="cpuid",default_interval_ms=30000,targets=options.targets,native=options.native or Native,_method_style=true},M)
end
function M:probe()
 if type(self.native.read_cpuid)~="function" then return Capability.unavailable("cpuid_unsupported_architecture")end
 return Capability.available({source="CPUID"})
end
function M:sample(context)
 local now=Common.now_ns(context)
 local ok,raw,reason=pcall(self.native.read_cpuid,self.targets)
 if not ok then reason="cpuid_helper_failed"end
 if type(raw)~="string" then return Common.result("error",now,nil,{reason=reason or "cpuid_helper_failed"})end
 return Common.result("ok",Common.now_ns(context),{status="ok",raw=raw,source="Linux native CPUID reader",architecture_bits=string.unpack("<I4",raw,17)},{quality="fresh"})
end
return M
