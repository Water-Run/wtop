local N=require("wtop.native")
local Json=require("wtop.format.json")
local mode=tonumber(assert(os.getenv("WTOP_LEVELZERO_FIXTURE_MODE")))
local session=assert(N.gpu_worker_open("levelzero"))
local began=N.monotonic_ns()
local maximum,first_pid,first_observed=0
local data,reason
local function query()
    local start=N.monotonic_ns()
    local value,why=N.gpu_worker_query(session,false)
    maximum=math.max(maximum,(N.monotonic_ns()-start)/1e6)
    assert(maximum<150,"foreground blocked: "..maximum)
    return value,why
end
repeat
    data,reason=query()
    if data then
        assert(data.worker_pid~=N.pid() and data.transport=="process")
        assert(data.sample_started_ns>=began and data.sample_finished_ns>=data.sample_started_ns)
        assert(data.sample_finished_ns<=N.monotonic_ns())
        first_pid=first_pid or data.worker_pid
        first_observed=first_observed or data.sample_started_ns
        local d=data.devices[1]
        if not d or d.power_quality~="gap" then break end
        N.sleep_ms(150)
    elseif reason~="levelzero_query_pending" then break
    else N.sleep_ms(5) end
until N.monotonic_ns()-began>7e9
assert(reason~="levelzero_query_pending","no final reader response")
if data then
    assert(first_pid==data.worker_pid)
    assert(data.sample_started_ns>=first_observed)
    local d=data.devices[1]
    assert(d and d.vendor_id==0x8086 and d.power_limit_watts~=0)
    if mode==0 or mode==2 or mode==15 or mode==20 or mode==25 or mode==46 or mode==49 then
        assert(#data.devices==3)
        assert(d.power_scope=="card" and math.abs(d.power_watts-30)<0.1
            or mode==20 and math.abs(d.power_watts-40)<0.1)
        assert(d.power_limit_watts==40 and d.power_measurement=="average")
        assert(d.power_interval_ns>=100000000 and d.power_interval_ns<=5000000000)
        assert(#d.power_domains==4 and #d.frequency_domains==3)
    elseif mode==6 then assert(d.pci_bdf==nil and d.uuid)
    elseif mode==7 then assert(d.temperature_celsius==nil and data.status=="partial")
    elseif mode==8 or mode==9 then assert(#data.devices==1 and data.status=="partial")
    elseif mode==10 or mode==11 then assert(d.graphics_clock_hz==nil)
    elseif mode==13 then assert(d.power_watts==nil and d.power_quality=="unavailable")
    elseif mode>=16 and mode<=19 and data.initialization=="sysman" then assert(d.power_limit_watts==nil)
    end
else
    local expected=mode==24 and "levelzero_device_lost"
        or mode==43 and "levelzero_worker_exited" or "levelzero_query_timeout"
    assert(reason==expected,reason)
end
assert(N.gpu_worker_close(session,0))
local value,closed=N.gpu_worker_query(session,false)
assert(not value and closed=="levelzero_worker_closed")
local count=data and #data.devices or 0
local watts=data and data.devices[1] and data.devices[1].power_watts
print("LEVELZERO_MATRIX_RESULT "..assert(Json.encode({mode=mode,reason=reason,devices=count,
    watts=watts,initialization=data and data.initialization,maximum_foreground_ms=maximum,
    seconds=(N.monotonic_ns()-began)/1e9})))
