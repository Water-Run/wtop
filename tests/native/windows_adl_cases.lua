local N=require("wtop.native")
local J=require("wtop.format.json")
local mode=tonumber(assert(os.getenv("WTOP_ADL_FIXTURE_MODE")))
local legacy=os.getenv("WTOP_ADL_TEST_LEGACY")=="1"
local session=assert(N.gpu_worker_open("adl"))
local began=N.monotonic_ns()
local maximum,data,reason=0
repeat
 local start=N.monotonic_ns()
 data,reason=N.gpu_worker_query(session,false)
 maximum=math.max(maximum,(N.monotonic_ns()-start)/1e6)
 assert(maximum<150,"foreground blocked: "..maximum)
 if data or reason~="adl_query_pending" then break end
 N.sleep_ms(5)
until N.monotonic_ns()-began>7e9
assert(reason~="adl_query_pending","no final reader response")
local failures={[2]="adl_initialization_failed",[3]="adl_device_count_failed",[4]="adl_output_too_large",
 [5]="adl_device_list_failed",[9]="adl_identity_changed",[11]="adl_identity_changed",
 [40]="adl_query_timeout",[41]="adl_query_timeout",[42]="adl_query_timeout",
 [43]="adl_worker_exited",[44]=not legacy and "adl_query_timeout" or nil}
if not legacy and mode>=60 then
 for _,value in ipairs({81,82,83,84,87})do failures[value]="adl_query_timeout"end
 failures[79]="adl_identity_changed";failures[80]="adl_worker_exited";failures[88]="adl_worker_exited"
end
local function query()
 local result,why;local start=N.monotonic_ns()
 repeat
  local turn=N.monotonic_ns();result,why=N.gpu_worker_query(session,false)
  maximum=math.max(maximum,(N.monotonic_ns()-turn)/1e6);assert(maximum<150,"blocked PMLog query")
  if result or why~="adl_query_pending"then return result,why end
  N.sleep_ms(5)
 until N.monotonic_ns()-start>7e9
 error("PMLog query remained pending")
end
local function control(value)
 local f=assert(io.open(assert(os.getenv("WTOP_ADL_FIXTURE_CONTROL")),"wb"));f:write(tostring(value));f:close()
end
local function trace()
 local f=assert(io.open(assert(os.getenv("WTOP_ADL_PMLOG_TRACE")),"rb"));local body=f:read("a");f:close()
 return assert(require("wtop.core.json").decode(body))
end
if failures[mode] then assert(data==nil and reason==failures[mode],tostring(reason))
else
 assert(data,tostring(reason))
 assert(data.worker_pid~=N.pid() and data.transport=="process")
 assert(data.sample_started_ns>=began and data.sample_finished_ns>=data.sample_started_ns)
 assert(data.sample_finished_ns<=N.monotonic_ns())
 assert(data.initialization==(legacy and "adl1" or "adl2"))
 if mode>=60 and not legacy then
  assert(#data.devices==1);local d=data.devices[1]
  assert(d.identity_verified and d.aliases==2 and d.power_limit_watts==nil and d.performance_limits==nil)
  assert(d.hardware_timestamp_available==false)
  local fallback=mode==61 or mode==68 or mode==69 or mode==70 or mode==71 or mode==72 or mode==73 or mode==78 or mode==97 or mode==98
  assert(d.pmlog_method==(fallback and "query"or"shared_memory"))
  if mode==64 or mode==66 or mode==67 or mode==74 or mode==75 or mode==91 or mode==92 then
   assert(d.power_watts==22.5 and d.graphics_clock_hz==3e8 and d.hotspot_temperature_celsius==nil and d.graphics_voltage_volts==nil)
   assert(d.pmlog_valid_sensors==0)
   if mode==64 or mode==66 or mode==67 or mode==91 or mode==92 then assert(d.pmlog_invalid_sensors==9 and d.partial)end
  elseif mode==65 then assert(d.power_watts==22.5 and d.hotspot_temperature_celsius==nil)
  else
   assert(d.power_watts==(mode==63 and 0 or mode==94 and 22.5 or 37)and d.power_measurement==(mode==94 and"device_sample"or"driver_snapshot")and d.power_scope=="asic")
   if mode==93 then assert(d.hotspot_temperature_celsius==nil)else assert(d.hotspot_temperature_celsius==(mode==63 and 0 or 79))end
   assert(math.abs(d.graphics_voltage_volts-(mode==63 and 0 or .95))<1e-12)
   assert(d.graphics_clock_hz==(mode==62 and 3e8 or mode==63 and 0 or 1875e6))
   assert(d.memory_clock_hz==(mode==62 and 150e6 or mode==63 and 0 or 1e9))
   assert(d.temperature_celsius==(mode==62 and 43.25 or mode==63 and 0 or 51))
   assert(d.fan_speed_rpm==(mode==62 and 1200 or mode==63 and 0 or 1500))
   assert(d.utilization_percent==(mode==62 and 25 or mode==63 and 0 or 63))
   assert(d.pmlog_valid_sensors==(mode==62 and 3 or(mode==93 or mode==94)and 8 or 9))
  end
  local second,why=query()
  if mode==76 or mode==77 or mode==85 or mode==86 then
   assert(not second and why==((mode==85 or mode==86)and"adl_query_timeout"or"adl_identity_changed"),why)
   if mode==76 or mode==77 then
    control(60);local recovery=N.monotonic_ns()
    repeat
     second,why=query()
     if second then break end
     assert(why=="adl_identity_changed",why);N.sleep_ms(10)
    until N.monotonic_ns()-recovery>8e9
    assert(second and second.devices[1].power_watts==37,why)
   end
  else assert(second and second.devices[1].power_watts==d.power_watts,why)end
  if mode~=85 and mode~=86 then
   local before=trace()
   if mode==60 or mode==63 or mode==90 then assert(before.created==2 and before.started==2 and before.reads==4 and before.queries==0)end
   control(25);local empty,empty_reason=query();assert(empty and #empty.devices==0,empty_reason)
   local done=trace();assert(done.owned==0 and done.created==done.destroyed,"PMLog devices leaked")
  end
 elseif mode==25 then assert(#data.devices==0)
 else
  assert(#data.devices==1)
  local d=data.devices[1]
  assert(d.vendor_id==0x1002 and d.pci_bdf=="0000:01:00.0")
  assert(d.power_limit_watts==nil and d.power_limit_percent==nil,"PowerTune percentage became a watt cap")
  if mode==10 or mode==12 or mode==13 or mode==28 or mode==29 then
   assert(not d.identity_verified and d.power_watts==nil and d.graphics_clock_hz==nil and d.temperature_celsius==nil and d.aliases==2)
  else
   assert(d.identity_verified==(mode~=12 and mode~=13))
   assert(d.aliases==2)
   if mode==20 then
    assert(d.active==nil and d.present==false and d.power_watts==nil and d.graphics_clock_hz==nil and d.temperature_celsius==nil)
    assert(d.active_status==-5 and d.activity_status==-5 and d.temperature_status==-5 and data.status=="partial")
   else
    if legacy or mode==19 or mode==22 then assert(d.power_watts==nil and data.status=="partial")
    else assert(d.power_watts==(mode==23 and 0 or 22.5) and d.power_scope=="asic" and d.power_measurement=="device_sample")end
    if mode==17 or mode==26 then assert(d.temperature_celsius==nil)
    else assert(d.temperature_celsius==(mode==1 and 45 or 43.25))end
    if mode==15 or mode==21 or mode==27 then assert(d.graphics_clock_hz==nil)
    else assert(d.graphics_clock_hz==(mode==1 and 4e8 or 3e8))end
    if mode==16 or mode==21 or mode==27 then assert(d.utilization_percent==nil)
    else assert(d.utilization_percent==(mode==1 and 30 or 25))end
    if mode==18 then assert(d.fan_speed_percent==nil and d.fan_status==-23)
    else assert(d.fan_speed_rpm==(mode==1 and 1400 or 1200))end
   end
  end
 end
end
assert(N.gpu_worker_close(session,0))
local value,closed=N.gpu_worker_query(session,false)
assert(not value and closed=="adl_worker_closed")
print("ADL_MATRIX_RESULT "..assert(J.encode({mode=mode,reason=reason,devices=data and #data.devices or 0,
 watts=data and data.devices[1] and data.devices[1].power_watts,initialization=data and data.initialization,
 maximum_foreground_ms=maximum,seconds=(N.monotonic_ns()-began)/1e9})))
