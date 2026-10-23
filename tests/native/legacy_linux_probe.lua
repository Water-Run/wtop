local Native = require("wtop.native")
local Json = require("wtop.core.json")
local Encode = require("wtop.format.json")
local Recording = require("wtop.recording")
assert(Native.available and string.packsize("T") == 4 and string.packsize("j") == 8)
local kernel = Native.uname()
assert(kernel.machine == "i686" and kernel.release:match("^3%.2%."))
local function load_json(path)
    local file = assert(io.open(path, "rb"))
    local text = assert(file:read("*a"))
    file:close()
    return assert(Json.decode(text))
end
assert(load_json("/out/snapshot.json").schema == "dev.waterrun.wtop.snapshot/v1")
local reader = assert(Recording.open("/out/actual.wtop"))
assert(reader.count == 3 and reader:frame(3).snapshot.memory.total_bytes > 0)
reader:close()
local pm = load_json("/out/PM.json")
assert(pm.schema == "dev.waterrun.wtop.agent/v1")
local large, disabled = false, false
local function walk(value)
    for key, item in pairs(value) do
        if key == "active_time_ms" and item == 4294967297 and math.type(item) == "integer" then large = true end
        if key == "d3cold_allowed" and item == false then disabled = true end
        if type(item) == "table" then walk(item) end
    end
end
walk(pm)
assert(large and disabled)
local file = assert(io.open("/proc/cpuinfo"))
local cpu = file:read("*a")
file:close()
assert(not cpu:match("%s+sse2%s+"))
file = assert(io.open("/out/TTY.bin"))
local screen = file:read("*a")
file:close()
assert(screen:find("CPU", 1, true) and screen:find("Command", 1, true)
    and not screen:find("stack traceback", 1, true))
print(Encode.encode({ pointer_bits = 32, integer_bits = 64, kernel = kernel.release,
    machine = kernel.machine, SSE2 = false, recorded_frames = 3,
    PM_agent_loaded = true, snapshot_loaded = true, TTY_bytes = #screen }))
