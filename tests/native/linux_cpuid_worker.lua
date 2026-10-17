local root,control,marker,mode,sensors=table.unpack(arg)
package.path=root..'/src/?.lua;'..root..'/src/?/init.lua;'..package.path
local N=require('wtop.native')
if not N.uname().machine:match('^i[3-6]86$')and N.uname().machine~='x86_64'then print('Linux CPUID worker:non-x86 guard passed');return end
local CPU=require('wtop.collectors.cpu_info')
local Portable=require('wtop.collectors.hwmon')
local Worker=require('wtop.collectors.hardware_worker')
local c=CPU.new({cpuid_cache_ms=100})
local healthy=Worker.new(Portable.new(),{base_path=sensors},N)
local ctx={clock={now_ns=N.monotonic_ns,wall_ns=N.realtime_ns}}
local function set(value)local f=assert(io.open(control,'w'));f:write(value);f:close()end
local function exists(path)local f=io.open(path,'r');if not f then return end;local v=f:read('a');f:close();return v end
local function born(pid)
 local f=io.open('/proc/'..pid..'/stat','r');if not f then return end
 local text=f:read('a');f:close();local rest=text:match('^%d+ %(.+%) (.*)$');local fields={};for v in rest:gmatch('%S+')do fields[#fields+1]=v end
 return fields[20]
end
set('0')
local result,h;local began=N.monotonic_ns()
repeat result=c:sample(ctx);h=healthy:sample(ctx);if result.data.cpuid and result.data.cpuid.status=='ok'and h.status=='ok'then break end;N.sleep_ms(10)until N.monotonic_ns()-began>5e9
assert(result.data.cpuid and result.data.cpuid.status=='ok')
local observed=result.data.cpuid.observed_at_ns
local before=h.value_timestamp_ns
local healthy_seen=before
set('1');local blocked;began=N.monotonic_ns()
repeat result=c:sample(ctx);h=healthy:sample(ctx);blocked=tonumber((exists(marker)));N.sleep_ms(10)until blocked or N.monotonic_ns()-began>5e9
assert(blocked,'API did not enter blocking call');local birth=born(blocked)
assert(birth)
-- A result sent before the control switch may be the last valid observation.
if result.data.cpuid.observed_at_ns then observed=result.data.cpuid.observed_at_ns end
if mode=='quit'then
 print('CPUID_BLOCKED',blocked,birth);io.stdout:flush();os.exit(19,false)
end
while N.monotonic_ns()-began<2600000000 do
 result=c:sample(ctx);h=healthy:sample(ctx);if h.status=='ok'then healthy_seen=h.value_timestamp_ns end;N.sleep_ms(20)
end
assert(result.data.cpuid.quality=='stale'and result.data.cpuid.retained)
assert(result.data.cpuid.observed_at_ns==observed and not result.data.cpuid.os_comparison)
assert(healthy_seen>before,'healthy reader stopped')
assert(born(blocked)~=birth,'blocked reader was not reaped before API release')
set('0');c:close();c=CPU.new({cpuid_cache_ms=100});began=N.monotonic_ns()
repeat result=c:sample(ctx);if result.data.cpuid and result.data.cpuid.status=='ok'and not result.data.cpuid.retained then break end;N.sleep_ms(10)until N.monotonic_ns()-began>5e9
assert(result.data.cpuid.status=='ok'and not result.data.cpuid.retained and result.data.cpuid.observed_at_ns>observed)
c:close();healthy:close()
print('Linux CPUID warm API block:old timestamp/stale capability,live sensor source,pre-release reap and recovery passed')
