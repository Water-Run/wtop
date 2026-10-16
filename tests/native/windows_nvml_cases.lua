local Json=require("wtop.format.json")
local native,query,session
local direct=arg[1]=="direct"
if direct then
    native=assert(package.loadlib(arg[2],"luaopen_nvml_reference"))()
    query=function() return native.query(true) end
else
    native=require("wtop.native")
    assert(native.gpu_worker_sources.nvml)
    session=assert(native.gpu_worker_open("nvml"))
    query=function() return native.gpu_worker_query(session,true) end
end
local function now() return direct and os.clock()*1e9 or native.monotonic_ns() end
local started,maximum=now(),0
local data,reason
repeat
    local before=now();data,reason=query();maximum=math.max(maximum,(now()-before)/1e6)
    if data or reason~="nvml_query_pending" then break end
    native.sleep_ms(5)
until now()-started>5e9
if not direct then
    assert(maximum<150,"foreground wait: "..maximum)
    if data then
        assert(data.transport=="process" and data.worker_pid~=native.pid())
        assert(data.sample_started_ns>=started and data.sample_finished_ns>=data.sample_started_ns)
        assert(data.sample_finished_ns<=native.monotonic_ns())
    end
    assert(native.gpu_worker_close(session,0))
    local closed,why=native.gpu_worker_query(session)
    assert(closed==nil and why=="nvml_worker_closed")
end
local function normalize(value)
    if type(value)~="table" then return value end
    local copy={}
    for key,item in pairs(value) do
        if key~="sample_started_ns" and key~="sample_finished_ns" and key~="worker_pid" and key~="transport"
            and key~="power_instant_timestamp_us" and key~="power_average_timestamp_us" then
            copy[key]=normalize(item)
        end
    end
    return copy
end
print("NVML_MATRIX_RESULT "..Json.encode({data=data and normalize(data),reason=reason,
    maximum_foreground_ms=maximum,seconds=(now()-started)/1e9}))
