local root,control,entered=assert(arg[1]),assert(arg[2]),assert(arg[3])
package.path=root..'/src/?.lua;'..root..'/src/?/init.lua;'..package.path
local Native=require('wtop.native')
assert(Native.available and Native.hardware_worker_sources.spd)
local Engine=require('wtop.engine')
local engine=Engine.new({interval_ms=100})
local ids={};for _,id in ipairs(engine.scheduler.order)do ids[#ids+1]=id end
for _,id in ipairs(ids)do if id~='spd' and id~='cpu'then engine.scheduler:remove(id)end end
local function write(path,value)local f=assert(io.open(path,'wb'));assert(f:write(value));assert(f:close())end
local function tick()
 local start=Native.monotonic_ns();local s=engine:tick(true)
 assert(Native.monotonic_ns()-start<250000000,'foreground blocked on SPD')
 return s
end
local deadline=Native.monotonic_ns()+3e9
engine:probe()
local first
repeat
 first=tick()
 if first.spd and first.spd.devices and #first.spd.devices==2 then break end
 assert(Native.monotonic_ns()<deadline,'SPD initial observation deadline');Native.sleep_ms(10)
until false
assert(first.spd.devices[1].size_bytes==16*1024^3 and first.spd.devices[2].size_bytes==64*1024^3)
assert(engine.scheduler:task('spd').last_result.transport=='process' and first.quality.spd.quality=='fresh')
local function no_idle_child()
 local file=assert(io.open(assert(arg[4]),'rb'));local ids={}
 for line in file:lines()do ids[assert(tonumber(line))]=true end;file:close()
 local end_ns=Native.monotonic_ns()+1e9
 for pid in pairs(ids)do
  while Native.access('/proc/'..pid,'f')do
   assert(Native.monotonic_ns()<end_ns,'successful stateless SPD kept an idle child');Native.sleep_ms(10)
  end
 end
end
no_idle_child()
local stamp=first.quality.spd.value_timestamp_ns
write(control,'1\n')
local stale,failed
local ended=Native.monotonic_ns()+4e9
repeat
 local s=tick()
 assert(s.cpu and s.quality.cpu.status=='ok','independent CPU sampling stopped')
 if s.quality.spd.quality=='stale' then
  stale=true;assert(s.spd.devices[1].size_bytes==16*1024^3)
  assert(s.quality.spd.value_timestamp_ns==stamp,'old SPD acquired a new measurement time')
 end
 if s.quality.spd.reason=='hardware_query_timeout'then failed=true;break end
 assert(Native.monotonic_ns()<ended,'SPD timeout deadline');Native.sleep_ms(20)
until false
assert(stale and failed)
local f=assert(io.open(entered,'rb'));local pid=assert(tonumber(f:read('a')));f:close()
deadline=Native.monotonic_ns()+1e9
while Native.access('/proc/'..pid,'f')do
 assert(Native.monotonic_ns()<deadline,'blocked SPD child was not reaped');Native.sleep_ms(10)
end
write(control,'0\n')
deadline=Native.monotonic_ns()+8e9
local recovered
repeat
 recovered=tick()
 if recovered.quality.spd.quality=='fresh' and recovered.quality.spd.value_timestamp_ns>stamp then break end
 assert(Native.monotonic_ns()<deadline,'SPD recovery deadline');Native.sleep_ms(25)
until false
assert(recovered.spd.devices[2].size_bytes==64*1024^3)
no_idle_child()
engine:stop()
print('SPD_WORKER_PASSED:default Engine selection,16/64GiB fixture,nonblocking ticks,CPU independence,stale original timestamp,timeout/reap,recovery and stop')
