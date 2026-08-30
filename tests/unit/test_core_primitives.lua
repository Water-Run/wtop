package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Clock = require("wtop.core.clock")
local JSON = require("wtop.core.json")
local Runner = require("wtop.core.runner")
local Scheduler = require("wtop.core.scheduler")
local Ring = require("wtop.model.ring")
local Snapshot = require("wtop.model.snapshot")

local function equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

equal(Clock.decimal_seconds_to_ns("12.000000345"), 12000000345)
equal(Clock.decimal_seconds_to_ns("0.5"), 500000000)
for _, invalid_time in ipairs({ "12junk", "1.2junk", "1e3", "-1", "", "1.2.3" }) do
  local parsed_time = Clock.decimal_seconds_to_ns(invalid_time)
  assert(parsed_time == nil, "invalid time accepted: " .. invalid_time)
end
assert(Clock.decimal_seconds_to_ns(math.huge) == nil)
assert(Clock.decimal_seconds_to_ns(0 / 0) == nil)
assert(Clock.decimal_seconds_to_ns(tostring(math.maxinteger)) == nil)
local uptime_values = { "10.25 20.0\n", "9.0 20.0\n", "11.0 21.0\n" }
local uptime_index = 0
local clock = Clock.new({
  read_file = function()
    uptime_index = uptime_index + 1
    return uptime_values[uptime_index]
  end,
})
equal(clock:now_ns(), 10250000000)
equal(clock:now_ns(), 10250000000, "clock must not move backwards")
equal(clock:now_ns(), 11000000000)

local ring = Ring.new(3)
assert(not pcall(Ring.new, math.huge))
assert(not pcall(Ring.new, 1000001))
assert(ring:push("a") == nil)
ring:push("b")
ring:push("c")
equal(ring:push("d"), "a")
equal(table.concat(ring:values(), ","), "b,c,d")
ring:resize(2)
equal(table.concat(ring:values(), ","), "c,d")
ring:resize(4)
ring:push("e")
equal(ring:oldest(), "c")
equal(ring:newest(), "e")
assert(ring:get(1.5) == nil)

local now = 1000000000
local fake_clock = { now_ns = function() return now end }
local calls = 0
local scheduler = Scheduler.new({ clock = fake_clock, max_backoff_ms = 10000 })
assert(not pcall(Scheduler.new, "invalid"))
assert(scheduler:add({ id = "bad", sample = function() end }, { interval_ms = "1" }) == nil)
assert(scheduler:add({ id = "bad", sample = function() end }, { interval_ms = 1,
  background_interval_ms = math.huge }) == nil)
assert(scheduler:add({ id = "bad", sample = function() end }, "invalid") == nil)
assert(not pcall(Scheduler.new, { max_backoff_ms = 0 / 0 }))
assert(scheduler:add({
  id = "fixture",
  default_interval_ms = 100,
  sample = function(_, previous)
    calls = calls + 1
    if calls == 1 then
      return { status = "error", quality = "error", reason = "temporary" }
    end
    return { status = "ok", data = { previous = previous }, quality = "fresh" }
  end,
}))
local first = scheduler:tick()
equal(first.fixture.status, "error")
equal(scheduler:task("fixture").failures, 1)
equal(scheduler:next_delay_ms(), 100)
now = now + 100000000
local second = scheduler:tick()
equal(second.fixture.status, "ok")
equal(calls, 2)
equal(scheduler:task("fixture").failures, 0)

local base = Snapshot.new(1, 10)
base.cpu = { total = { utilization = 25 } }
local merged = Snapshot.merge(base, {
  cpu = { status = "error", quality = "error", reason = "race", timestamp_ns = 20 },
  memory = { status = "ok", quality = "fresh", data = { total_bytes = 10 }, timestamp_ns = 20 },
}, 2, 20)
equal(merged.cpu.total.utilization, 25)
equal(merged.quality.cpu.quality, "stale")
equal(merged.memory.total_bytes, 10)
assert(merged.quality.memory.reason == nil)

local observed
local runner = Runner.new({
  default_max_output_bytes = 4,
  execute = function(argv, policy)
    observed = { argv = argv, policy = policy }
    return { status = "ok", exit_code = 0, stdout = "abcdef", stderr = "" }
  end,
})
assert(not pcall(Runner.new, "invalid"))
assert(not pcall(Runner.new, { default_timeout_ms = math.huge }))
equal(runner:run({ "relative", "x" }).reason, "executable_must_be_absolute")
equal(runner:run({ "/usr/bin/example" }, "invalid").reason, "invalid_runner_options")
local run = runner:run({ "/usr/bin/example", "one;two" })
equal(observed.argv[2], "one;two", "arguments must be passed without shell interpretation")
equal(run.stdout, "abcd")
assert(run.truncated)

local invalid_status = Runner.new({ execute = function() return { stdout = "" } end })
  :run({ "/usr/bin/example" })
equal(invalid_status.status, "error")
equal(invalid_status.reason, "invalid_executor_status")
local unavailable_status = Runner.new({ execute = function()
  return { status = "unavailable", reason = "missing" }
end }):run({ "/usr/bin/example" })
equal(unavailable_status.status, "unavailable")
equal(unavailable_status.reason, "missing")
for _, invalid_policy in ipairs({ "1", math.huge, 0 / 0, 1.5, 0, 60001 }) do
  local rejected = runner:run({ "/usr/bin/example" }, { timeout_ms = invalid_policy })
  equal(rejected.reason, "invalid_runner_policy")
end
equal(runner:run({ "/usr/bin/example" }, { env = "invalid" }).reason,
  "invalid_runner_policy")

local raw_result = {
  status = "ok", quality = "fresh", timestamp_ns = math.huge, duration_ns = -1,
}
local normalized = Scheduler.normalize_result(raw_result, 10, 20)
equal(normalized.timestamp_ns, 20)
equal(normalized.duration_ns, 10)
assert(normalized ~= raw_result and raw_result.timestamp_ns == math.huge,
  "scheduler normalization must not mutate collector-owned results")
local invalid_clock = Scheduler.new({ clock = function() return math.huge end })
assert(not pcall(function()
  invalid_clock:add({ id = "clock", sample = function() return { status = "ok" } end })
end))

local decoded = assert(JSON.decode('{"name":"wtop","unicode":"\\u6c34","items":[1,true,null]}'))
equal(decoded.name, "wtop")
equal(decoded.unicode, "水")
assert(decoded.items[3] == JSON.null)
local invalid, decode_error = JSON.decode('{"x":01}')
assert(invalid == nil and decode_error.message == "invalid_number")
local duplicate, duplicate_error = JSON.decode('{"x":1,"x":2}')
assert(duplicate == nil and duplicate_error.message == "duplicate_object_key")
local invalid_utf8, utf8_error = JSON.decode('"bad\255value"')
assert(invalid_utf8 == nil and utf8_error.message == "invalid_utf8")

equal(assert(JSON.decode("-0")), 0)
equal(assert(JSON.decode("0.125")), 0.125)
equal(assert(JSON.decode("1e+2")), 100)
equal(assert(JSON.decode("-2E-1")), -0.2)
for _, number in ipairs({ "-01", "1.", "1e", "1e+" }) do
  local value, number_error = JSON.decode(number)
  assert(value == nil and number_error.message == "invalid_number", number)
end
local out_of_range, range_error = JSON.decode("1e99999")
assert(out_of_range == nil and range_error.message == "number_out_of_range")

assert(JSON.decode("null", { max_nodes = 1 }) == JSON.null)
assert(JSON.decode('"scalar"', { max_nodes = 1 }) == "scalar")
assert(type(assert(JSON.decode("[]", { max_nodes = 1 }))) == "table")
assert(type(assert(JSON.decode("{}", { max_nodes = 1 }))) == "table")
assert(assert(JSON.decode('{"value":1}', { max_nodes = 2 })).value == 1)
local node_limited, node_error = JSON.decode("[0]", { max_nodes = 1 })
assert(node_limited == nil and node_error.message == "maximum_nodes_exceeded")
assert(type(JSON.DEFAULT_MAX_NODES) == "number" and JSON.DEFAULT_MAX_NODES >= 1000)
local default_node_limit = "[" .. string.rep("0,", JSON.DEFAULT_MAX_NODES - 1) .. "0]"
local default_limited, default_limit_error = JSON.decode(default_node_limit)
assert(default_limited == nil and default_limit_error.message == "maximum_nodes_exceeded")

for _, bad_limit in ipairs({ 0, -1, 1.5, "2", math.huge, 0 / 0 }) do
  local value, limit_error = JSON.decode("null", { max_nodes = bad_limit })
  assert(value == nil and limit_error.message == "invalid_max_nodes")
end
local bad_options, options_error = JSON.decode("null", "invalid")
assert(bad_options == nil and options_error.message == "invalid_options")
local bad_bytes, bytes_error = JSON.decode("null", { max_bytes = -1 })
assert(bad_bytes == nil and bytes_error.message == "invalid_max_bytes")
local bad_depth, depth_error = JSON.decode("null", { max_depth = -1 })
assert(bad_depth == nil and depth_error.message == "invalid_max_depth")
assert(JSON.decode("null", {max_depth = JSON.HARD_MAX_DEPTH + 1}) == nil)
assert(JSON.decode("null", {max_nodes = JSON.HARD_MAX_NODES + 1}) == nil)
assert(JSON.decode("null", {max_bytes = JSON.HARD_MAX_BYTES + 1}) == nil)
assert(JSON.decode("null", { max_depth = 0 }) == JSON.null)
local depth_limited, depth_limit_error = JSON.decode("[]", { max_depth = 0 })
assert(depth_limited == nil and depth_limit_error.message == "maximum_depth_exceeded")

-- Performance smoke: a numeric array must not copy the entire unparsed suffix
-- for every element.  The generous bound catches accidental quadratic parsing
-- without turning normal differences between CI hosts into a benchmark gate.
local number_count = 50000
local numeric_array = "[" .. string.rep("0,", number_count - 1) .. "0]"
local decode_started = os.clock()
local many_numbers = assert(JSON.decode(numeric_array, { max_nodes = number_count + 1 }))
local decode_seconds = os.clock() - decode_started
equal(#many_numbers, number_count)
assert(decode_seconds < 5, string.format("large numeric JSON decode took %.3fs", decode_seconds))

return true
