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
if failures[mode] then assert(data==nil and reason==failures[mode],tostring(reason))
else
 assert(data,tostring(reason))
 assert(data.worker_pid~=N.pid() and data.transport=="process")
 assert(data.sample_started_ns>=began and data.sample_finished_ns>=data.sample_started_ns)
 assert(data.sample_finished_ns<=N.monotonic_ns())
 assert(data.initialization==(legacy and "adl1" or "adl2"))
 if mode==25 then assert(#data.devices==0)
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
