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
local mode_control, mode_entered = arg[5], arg[6]
if mode_control then assert(first.displays.devices[1].current_mode.refresh_hz == 60) end
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
if mode_control then
  local current = engine.snapshot.displays.devices[1].current_mode
  local mode_stamp = current.observed_at_ns
  assert(current.refresh_hz == 60)
  write(mode_control, "1\n")
  deadline = Native.monotonic_ns() + 4000000000
  local timed_out = false
  repeat
    local snapshot = tick()
    assert(snapshot.cpu and snapshot.quality.cpu.status == "ok")
    local p = snapshot.displays.devices[1]
    assert(p.current_mode.refresh_hz == 60 and p.current_mode.observed_at_ns == mode_stamp,
      "blocked mode read replaced or freshened a held configuration")
    if snapshot.quality.displays.quality == "stale" then
      local public = require("wtop.export").snapshot(snapshot).displays.devices[1]
      assert(public.current_mode.quality == "stale" and public.current_mode_status == "stale")
    end
    if snapshot.quality.displays.reason == "hardware_query_timeout" then timed_out = true;break end
    assert(Native.monotonic_ns() < deadline, "mode ioctl timeout deadline");Native.sleep_ms(20)
  until false
  assert(timed_out)
  local f = assert(io.open(mode_entered, "rb"));local blocked_pid = assert(tonumber(f:read("a")));f:close()
  deadline = Native.monotonic_ns() + 1000000000
  while Native.access("/proc/" .. blocked_pid, "f") do
    assert(Native.monotonic_ns() < deadline, "blocked mode reader was not reaped");Native.sleep_ms(10)
  end
  write(mode_control, "2\n")
  deadline = Native.monotonic_ns() + 8000000000
  repeat
    local snapshot = tick()
    local p = snapshot.displays.devices[1]
    if snapshot.quality.displays.quality == "fresh" and p.current_mode.observed_at_ns > mode_stamp then
      assert(p.current_mode.refresh_hz == 75 and p.edid.detailed_timings[1].refresh_hz == 60)
      break
    end
    assert(Native.monotonic_ns() < deadline, "mode ioctl recovery deadline");Native.sleep_ms(25)
  until false
  no_idle_reader()
  print("DISPLAY_MODE_WORKER_PASSED:cached-only ioctls,held configuration and original time,CPU independent,stale public mode,timeout/reap,recovery75Hz distinct from EDID60Hz")
end
engine:stop()
print("DISPLAY_WORKER_PASSED:default Engine selection,cached EDID,nonblocking ticks,CPU independence,stale original time,timeout/reap,recovery,no idle reader and stop")
