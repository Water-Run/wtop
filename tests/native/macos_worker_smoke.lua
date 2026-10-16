local root=assert(arg[1])
package.path=root.."/src/?.lua;"..root.."/src/?/init.lua;"..package.path
local Native=require("wtop.native")
local Wire=require("wtop.core.worker_wire")
local Json=require("wtop.format.json")
local names={"cpufreq","powercap","gpu","hwmon"}
local suspended=arg[2]or "powercap"
assert(suspended=="powercap"or suspended=="hwmon")
local sessions,pids,counts={},{},{}
local function emit(value)print(Json.encode(value));io.stdout:flush()end
local function now()return Native.monotonic_ns()end
local function query(id)
    local bytes,metadata=Native.hardware_worker_query(sessions[id],false,0)
    if not bytes then return nil,metadata end
    local decoded=Wire.decode(bytes)
    assert(type(decoded.result)=="table" and type(decoded.capability)=="table")
    assert(metadata.transport=="process" and metadata.worker_pid>1)
    assert(metadata.sample_started_ns<=decoded.result.timestamp_ns
        and decoded.result.timestamp_ns<=metadata.sample_finished_ns
        and metadata.sample_finished_ns<=now())
    pids[id]=metadata.worker_pid;counts[id]=(counts[id]or 0)+1
    return decoded,metadata
end
assert(not pcall(Native.hardware_worker_open,"thermal_zones",Wire.encode({})))
for _,id in ipairs(names)do
    assert(Native.hardware_worker_sources[id]);sessions[id]=Native.hardware_worker_open(id,Wire.encode({}))
end
local deadline=now()+4e9
repeat
    for _,id in ipairs(names)do if not pids[id]then query(id)end end
    Native.sleep_ms(10)
until (pids.cpufreq and pids.powercap and pids.gpu and pids.hwmon)or now()>deadline
assert(pids.cpufreq and pids.powercap and pids.gpu and pids.hwmon,"initial reader frames unavailable")
local old_pid=pids[suspended]
emit({event="ready",pids=pids})
assert(io.read("l")=="stopped")
local before={}
for _,id in ipairs(names)do before[id]=counts[id]end
local function healthy_advanced()
    for _,id in ipairs(names)do
        if id~=suspended and counts[id]<=before[id]then return false end
    end
    return true
end
deadline=now()+4e9;local failure
repeat
    local _,reason=query(suspended);failure=reason
    for _,id in ipairs(names)do if id~=suspended then query(id)end end
    Native.sleep_ms(10)
until (failure=="hardware_query_timeout" and healthy_advanced())or now()>deadline
assert(failure=="hardware_query_timeout" and healthy_advanced(),
    "a suspended reader stopped independent polling or escaped its deadline")
emit({event="timeout",reason=failure,source=suspended})
assert(io.read("l")=="recover")
deadline=now()+11e9;local recovered
repeat
    local bytes=query(suspended);if bytes then recovered=true;break end
    for _,id in ipairs(names)do if id~=suspended then query(id)end end
    Native.sleep_ms(25)
until now()>deadline
assert(recovered and pids[suspended]~=old_pid,"reader did not recover with a new process")
local invalid=Native.hardware_worker_open("powercap","bad")
deadline=now()+3e9;local reason
repeat
    local bytes;bytes,reason=Native.hardware_worker_query(invalid,false,0)
    assert(not bytes);Native.sleep_ms(10)
until reason~="hardware_query_pending"or now()>deadline
assert(reason=="hardware_collector_error","malformed configuration was accepted")
assert(Native.hardware_worker_close(invalid,100),"bounded close did not finish reaping the failed reader")
emit({event="recovered",pids=pids,malformed_configuration=reason})
assert(io.read("l")=="close")
for _,session in pairs(sessions)do Native.hardware_worker_close(session,0)end
os.exit(0,true)
