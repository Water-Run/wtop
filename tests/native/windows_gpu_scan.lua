local N=require("wtop.native")
local Wire=require("wtop.core.worker_wire")
local J=require("wtop.format.json")
N.hardware_worker_sources=N.hardware_worker_configure(assert(arg[1]))
local session=assert(N.hardware_worker_open("gpu",Wire.encode({})))
local rounds={}
for _,scan in ipairs({true,false,true}) do
    local deadline=N.monotonic_ns()+5e9
    local response,metadata
    repeat
        local bytes,meta=N.hardware_worker_query(session,false,0,scan)
        if bytes then response=assert(Wire.decode(bytes));metadata=meta;break end
        assert(meta=="hardware_query_pending",meta)
        N.sleep_ms(10)
    until N.monotonic_ns()>deadline
    assert(response and (response.result.status=="ok" or response.result.reason=="no_display_adapters"))
    assert(metadata.worker_pid~=N.pid())
    if not scan and response.result.data then
        for _,device in ipairs(response.result.data.devices) do
            assert(#(device.processes and device.processes.list or {})==0)
            assert(device.capabilities.process_usage==false)
        end
    end
    rounds[#rounds+1]={scan=scan,worker_pid=metadata.worker_pid,observed=response.result.timestamp_ns}
end
assert(rounds[1].worker_pid==rounds[2].worker_pid and rounds[2].worker_pid==rounds[3].worker_pid)
assert(rounds[2].observed>=rounds[1].observed and rounds[3].observed>=rounds[2].observed)
N.hardware_worker_close(session,0)
print(J.encode({scan_cycles=rounds,source="actual Windows SetupAPI/PDH reader"}))
