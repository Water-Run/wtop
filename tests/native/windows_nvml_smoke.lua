local Native = require("wtop.native")
local NVML = require("wtop.collectors.nvml")
local session = assert(Native.gpu_worker_open("nvml"))
local started, maximum, frames, result, reason = Native.monotonic_ns(), 0, 0
repeat
    local before = Native.monotonic_ns()
    result, reason = Native.gpu_worker_query(session, true)
    maximum = math.max(maximum, (Native.monotonic_ns() - before) / 1e6)
    if result then
        assert(result.transport == "process" and result.worker_pid ~= Native.pid())
        assert(result.sample_started_ns >= started and result.sample_finished_ns >= result.sample_started_ns)
        assert(result.sample_finished_ns <= Native.monotonic_ns())
        assert(#result.devices == 2)
        assert(result.devices[1].power_watts == 300 and result.devices[1].power_limit_watts == 355.5)
        assert(result.devices[1].power_measurement == "current" and result.devices[1].power_quality == "fresh")
        frames = frames + 1
    elseif reason ~= "nvml_query_pending" then break end
    Native.sleep_ms(10)
until frames >= 3 or Native.monotonic_ns() - started > 6e9
assert(frames == 3, tostring(reason))
assert(maximum < 150, "foreground driver wait: " .. maximum)
local devices = {}
NVML.refresh_power(result, Native.realtime_ns()/1000)
local provider = NVML.merge(devices, {by_bdf={}}, result, {used_ids={},now_ns=Native.monotonic_ns()})
assert(provider.status == "ok" and #devices == 2)
assert(devices[1].metrics.power_watts == 300 and devices[1].metrics.power_limit_watts == 355.5)
assert(devices[1].performance_limits.domains[1].active == true)
assert(Native.gpu_worker_close(session, 0))
local value, closed = Native.gpu_worker_query(session)
assert(value == nil and closed == "nvml_worker_closed")
print(require("wtop.format.json").encode({frames=frames,maximum_foreground_ms=maximum,
    worker_pid=result.worker_pid,parent_pid=Native.pid(),power_watts=300,limit_watts=355.5,
    power_percent=100*300/355.5,transport=result.transport,processes=#result.devices[1].processes}))
