package.path = "./src/?.lua;./src/?/init.lua;./tools/?.lua;" .. package.path
local Recording = require("wtop.recording")
local Snapshot = require("wtop.model.snapshot")
local Collectors = require("wtop.collectors")
local Replay = require("wtop.replay")
local native = require("wtop.native")
-- Sparse-index boundaries and integer CPU keys are exercised without keeping
-- the measurements themselves resident in the replay engine.
local path = os.tmpname()
local file = assert(io.open(path, "wb"))
local writer = Recording.writer({ write=function(s) return file:write(s) end,
    metadata={ platform="Windows", interval_ms=100, capabilities={ cpu={ available=true, state="available" } } } })
for n = 1, 260 do
    local snapshot = Snapshot.new(n, n * 100000000)
    snapshot.cpu = { total={ utilization=n % 100 }, cores={ [0]={ id=0 } } }
    snapshot.quality.cpu = { status="ok", quality="fresh", timestamp_ns=snapshot.timestamp_ns }
    writer:append(snapshot, snapshot.timestamp_ns, 1700000000000000000 + n * 100000000)
end
writer:close(); assert(file:close())
local original = Collectors.new_all
Collectors.new_all = function() error("replay started a live collector") end
local reads = 0
local original_run = native.run
native.run = function() reads=reads+1; error("replay ran a helper") end
local now = 900000000000
local engine = Replay.new(path, { now_ns=function() return now end })
assert(engine.replay and engine.platform == "Windows" and engine.paused)
assert(#engine.reader.index == 2 and engine.reader.count == 260)
assert(engine.clock:now_ns() == 100000000 and engine.clock.wall_ns() == 1700000000100000000)
assert(engine:probe().cpu.available and #engine.scheduler.order == 0)
assert(engine:next_delay_ms(100) == 100 and not next(select(2, engine:tick())))
assert(engine.snapshot.cpu.cores[0].id == 0)
engine:set_paused(false)
assert(engine:next_delay_ms(200) == 100)
now = now + 99999999
assert(not next(select(2, engine:tick())))
now = now + 1
assert(select(2, engine:tick()).replay and engine.frame_number == 2)
local history = engine:history_values("cpu")
assert(history.n == 2 and history[1] == 1 and history[2] == 2)
engine:set_paused(true)
now = now + 10000000000
assert(not next(select(2, engine:tick())))
engine:cycle_speed(); assert(engine.speed == 2)
engine:set_paused(false); assert(engine:next_delay_ms(200) == 50)
now = now + 50000000; engine:tick(); assert(engine.frame_number == 3)
engine:seek(257)
assert(engine.paused and engine.snapshot.sequence == 257 and engine:history_values("cpu").n == 1)
assert(engine.clock:now_ns() == 25700000000)
engine:step(-1); assert(engine.frame_number == 256)
engine:seek(260); assert(engine.frame_number == 260 and engine.paused)
engine:set_paused(false); assert(engine.paused and engine:next_delay_ms(100) == 100)
engine:step(10); assert(engine.frame_number == 260)
engine:step(-1000); assert(engine.frame_number == 1)
assert(not engine:has_pending_samples() and not next(select(2, engine:tick_visible())))
engine:stop(); engine:stop()
assert(engine.reader.file == nil and reads == 0)
-- Offline exports identify the recorded host and capture time rather than
-- borrowing the machine running the viewer. No collector or uname is needed.
local original_uname, original_write = native.uname, io.write
native.uname = function() error("offline export queried the replay host") end
local output = {}
io.write = function(...) output[#output + 1] = table.concat({...}); return true end
local Application = require("wtop.application")
assert(Application.replay({replay_path=path, replay_frame=257, command="snapshot"}) == 0)
assert(Application.replay({replay_path=path, replay_frame=260, command="agent"}) == 0)
assert(Application.replay({replay_path=path, replay_frame=1, command="report"}) == 0)
io.write, native.uname = original_write, original_uname
local JSON = require("wtop.core.json")
local first = assert(JSON.decode(output[1]))
assert(first.host.sysname == "Windows" and first.observation.frame == 257)
assert(first.captured_unix_ns == 1700000025700000000 and first.captured_monotonic_ns == 25700000000)
local agent = assert(JSON.decode(output[2]))
assert(agent.host.sysname == "Windows" and agent.observation.frames == 260 and agent.observation.mode == "recorded")
local schema_file = assert(io.open("docs/agent-v1.schema.json", "rb"))
local schema = assert(JSON.decode(schema_file:read("*a"))); schema_file:close()
local errors = require("agent_schema").validate(agent, schema)
assert(#errors == 0, table.concat(errors, "\n"))
agent.observation.mode = "live"
assert(#require("agent_schema").validate(agent, schema) > 0)
assert(output[3]:find("> Recorded measurement: frame 1/260.", 1, true))
native.run, Collectors.new_all = original_run, original
os.remove(path)
print("Replay: sparse seeks, recorded wall/monotonic time, pause/play/speed/EOF, chart gaps and no live collectors/helpers")
