local root,control,entered,reads=assert(arg[1]),assert(arg[2]),assert(arg[3]),assert(arg[4])
package.path=root..'/src/?.lua;'..root..'/src/?/init.lua;'..package.path
local N=require('wtop.native');local E=require('wtop.engine');local JSON=require('wtop.format.json')
local e=E.new({interval_ms=100});local ids={};for _,id in ipairs(e.scheduler.order)do ids[#ids+1]=id end
for _,id in ipairs(ids)do if id~='spd'and id~='cpu'then e.scheduler:remove(id)end end
local function view(name)assert(e:set_active_tab(name,{}, {cpu=true,spd=name=='memory'}))end
local function write(path,value)local f=assert(io.open(path,'wb'));assert(f:write(value));assert(f:close())end
local function tick()
 local start=N.monotonic_ns();local s=e:tick_visible();assert(N.monotonic_ns()-start<250000000,'foreground hardware poll blocked');return s
end
local function no_child()
 local f=assert(io.open(reads,'rb'));local pids={};for line in f:lines()do pids[assert(tonumber(line))]=true end;f:close()
 local end_ns=N.monotonic_ns()+1e9
 for pid in pairs(pids)do while N.access('/proc/'..pid,'f')do assert(N.monotonic_ns()<end_ns,'idle reader not reaped');N.sleep_ms(10)end end
end
view('overview');e:probe()
local deadline=N.monotonic_ns()+2e9;local first
repeat first=tick();if first.spd and first.spd.devices and #first.spd.devices==2 then break end;assert(N.monotonic_ns()<deadline,'hidden probe never published');N.sleep_ms(10)until false
assert(first.quality.spd.quality=='fresh');no_child();assert(e.scheduler:task('spd').runs>=1)
local stamp=first.quality.spd.value_timestamp_ns;write(control,'1\n');view('memory');tick();view('overview');e:set_interval(200)
local stale,timeout=false,false;deadline=N.monotonic_ns()+3500000000
repeat
 local s=tick();assert(s.quality.cpu.status=='ok'and s.cpu.total,'healthy CPU stopped')
 if s.quality.spd.quality=='stale'then stale=true;assert(s.quality.spd.value_timestamp_ns==stamp and s.spd.devices[1].size_bytes==16*1024^3,'stale value or original time lost')end
 if s.quality.spd.reason=='hardware_query_timeout'then timeout=true;break end
 assert(N.monotonic_ns()<deadline,'hidden read not timed out');N.sleep_ms(20)
until false
assert(stale and timeout);local f=assert(io.open(entered,'rb'));local blocked=assert(tonumber(f:read('a')));f:close();no_child()
write(control,'0\n');deadline=N.monotonic_ns()+9e9;local recovered
repeat
 recovered=tick();if recovered.quality.spd.quality=='fresh'and recovered.quality.spd.value_timestamp_ns>stamp then break end
 assert(N.monotonic_ns()<deadline,'hidden reader not recovered');N.sleep_ms(25)
until false
no_child();assert(recovered.spd.devices[2].size_bytes==64*1024^3)
local count=e.scheduler:task('spd').runs;local stable=N.monotonic_ns()+300000000
repeat tick();N.sleep_ms(10)until N.monotonic_ns()>=stable
assert(e.scheduler:task('spd').runs==count,'completed hidden source kept polling')
e:stop();no_child();print(JSON.encode({hidden_initial_result=true,visible_to_hidden_pending=true,cadence_change_pending=true,cpu_independent=true,stale_original_timestamp=true,timeout_reaped=true,hidden_recovery=true,no_idle_child=true,background_cadence_restored=true,private_only=true}))
