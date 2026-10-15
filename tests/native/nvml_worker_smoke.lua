local native = require("wtop.native")
local scenario = tonumber(arg[1])
local session = assert(native.nvml_worker_open())
local last, reason, maximum_ms, frames = 0, nil, 0, 0
local beginning = native.monotonic_ns()
repeat
  local started = native.monotonic_ns()
  local data
  data, reason = native.nvml_worker_query(session, true)
  maximum_ms = math.max(maximum_ms, (native.monotonic_ns() - started) / 1e6)
  if data then
    assert(data.transport == "process" and data.worker_pid ~= native.pid() and #data.devices == 2)
    assert(data.devices[1].power_watts == 300)
    local process = data.devices[1].processes[1]
    assert(process.sample_timestamp_us >= last)
    last, frames = process.sample_timestamp_us, frames + 1
    if frames >= 3 then break end
  elseif reason ~= "nvml_query_pending" then break end
  native.sleep_ms(30)
until native.monotonic_ns() - beginning > 4e9
assert(maximum_ms < 150, "foreground driver wait: " .. maximum_ms)
if scenario == 45 or scenario == 46 or scenario == 47 or scenario == 48 then
  assert(reason == "nvml_query_timeout", reason)
elseif scenario == 51 then
  assert(reason == "nvml_worker_exited", reason)
elseif scenario == 56 or scenario == 57 then
  assert(reason == "nvml_invalid_response", reason)
else assert(frames >= 3, reason) end
local maps = assert(io.open("/proc/self/maps", "r"))
assert(not maps:read("a"):find("libnvidia-ml", 1, true), "driver mapped in parent")
maps:close()
local started = native.monotonic_ns()
assert(native.nvml_worker_close(session))
assert(native.monotonic_ns() - started < 200e6)
local data, closed = native.nvml_worker_query(session, true)
assert(not data and closed == "nvml_worker_closed")
print("NVML worker scenario", scenario, "frames", frames, "maximum foreground ms", maximum_ms)
