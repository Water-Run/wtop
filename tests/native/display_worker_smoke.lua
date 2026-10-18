local root, control, entered, reads = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path
local Native = require("wtop.native")
assert(Native.available and Native.hardware_worker_sources.displays)
local engine = require("wtop.engine").new({ interval_ms = 100 })
local ids = {};for _, id in ipairs(engine.scheduler.order) do ids[#ids + 1] = id end
for _, id in ipairs(ids) do if id ~= "displays" and id ~= "cpu" then engine.scheduler:remove(id) end end
local function write(path, value)
  local f = assert(io.open(path, "wb"));assert(f:write(value));assert(f:close())
end
local function tick()
  local started = Native.monotonic_ns()
  local snapshot = engine:tick(true)
  assert(Native.monotonic_ns() - started < 250000000, "display read blocked the foreground")
  return snapshot
end
local function no_idle_reader()
  local f = assert(io.open(reads, "rb"));local children = {}
  for line in f:lines() do children[assert(tonumber(line))] = true end;f:close()
  local deadline = Native.monotonic_ns() + 1000000000
  for pid in pairs(children) do
    while Native.access("/proc/" .. pid, "f") do
      assert(Native.monotonic_ns() < deadline, "stateless display reader stayed alive")
      Native.sleep_ms(10)
    end
  end
end
engine:probe()
local first, deadline = nil, Native.monotonic_ns() + 3000000000
repeat
  first = tick()
  if first.displays and #first.displays.devices == 1 then break end
  assert(Native.monotonic_ns() < deadline, "display initial read deadline");Native.sleep_ms(10)
until false
assert(first.displays.devices[1].edid.name == "FixturePanel" and first.displays.devices[1].connection == "connected")
assert(first.quality.displays.quality == "fresh" and engine.scheduler:task("displays").last_result.transport == "process")
no_idle_reader()
local stamp = first.quality.displays.value_timestamp_ns
write(control, "1\n")
deadline = Native.monotonic_ns() + 4000000000
local stale, timeout
repeat
  local snapshot = tick()
  assert(snapshot.cpu and snapshot.quality.cpu.status == "ok", "CPU stopped during blocked display read")
  if snapshot.quality.displays.quality == "stale" then
    stale = true
    assert(snapshot.displays.devices[1].edid.name == "FixturePanel")
    assert(snapshot.quality.displays.value_timestamp_ns == stamp, "old EDID acquired a new read time")
  end
  if snapshot.quality.displays.reason == "hardware_query_timeout" then timeout = true;break end
  assert(Native.monotonic_ns() < deadline, "display timeout deadline");Native.sleep_ms(20)
until false
assert(stale and timeout)
local f = assert(io.open(entered, "rb"));local pid = assert(tonumber(f:read("a")));f:close()
deadline = Native.monotonic_ns() + 1000000000
while Native.access("/proc/" .. pid, "f") do
  assert(Native.monotonic_ns() < deadline, "blocked display reader was not reaped");Native.sleep_ms(10)
end
write(control, "0\n")
deadline = Native.monotonic_ns() + 8000000000
repeat
  local snapshot = tick()
  if snapshot.quality.displays.quality == "fresh" and snapshot.quality.displays.value_timestamp_ns > stamp then break end
  assert(Native.monotonic_ns() < deadline, "display recovery deadline");Native.sleep_ms(25)
until false
no_idle_reader()
engine:stop()
print("DISPLAY_WORKER_PASSED:default Engine selection,cached EDID,nonblocking ticks,CPU independence,stale original time,timeout/reap,recovery,no idle reader and stop")
