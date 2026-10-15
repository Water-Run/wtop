package.path = "./src/?.lua;./src/?/init.lua;" .. package.path
local Wire = require("wtop.core.worker_wire")
local Snapshot = require("wtop.model.snapshot")

local original = { minimum = math.mininteger, maximum = math.maxinteger,
    fraction = 12.25, binary = "a\0b\255", enabled = false,
    counters = { [0] = 10, [8] = 22, [-1] = "offline" }, empty = {} }
local copy = Wire.decode(Wire.encode(original))
assert(copy.minimum == math.mininteger and copy.maximum == math.maxinteger)
assert(copy.fraction == 12.25 and copy.binary == original.binary and copy.enabled == false)
assert(copy.counters[0] == 10 and copy.counters[8] == 22 and copy.counters[-1] == "offline")
assert(next(copy.empty) == nil)
local cyclic = {}; cyclic.self = cyclic
for _, value in ipairs({ cyclic, setmetatable({}, {}), { callback = function() end }, { value = math.huge } }) do
    assert(not pcall(Wire.encode, value))
end
local nested = {}; local tail = nested
for _ = 1, Wire.MAX_DEPTH + 1 do tail.child = {}; tail = tail.child end
assert(not pcall(Wire.encode, nested))
for _, data in ipairs({ "", "s", "x", "zextra", "s" .. string.pack("<I4", 0xffffffff),
    "m" .. string.pack("<I4", 0xffffffff), "d" .. string.pack("<d", 0/0),
    "m" .. string.pack("<I4", 1) .. "tt",
    "m" .. string.pack("<I4", 1) .. "s" .. string.pack("<I4", 1) .. "az",
    "m" .. string.pack("<I4", 2) .. "i" .. string.pack("<i8", 0) .. "t" .. "i" .. string.pack("<i8", 0) .. "f" }) do
    assert(not pcall(Wire.decode, data), "malformed worker frame accepted")
end
local data = Wire.encode(original)
for i = 0, #data - 1 do assert(not pcall(Wire.decode, data:sub(1, i))) end

local actual = package.loaded["wtop.native"]
local now, response, closes, opens = 100, nil, 0, 0
local fake = { available = true,
    hardware_worker_open = function(id, bytes)
        assert(id == "powercap" and next(Wire.decode(bytes)) == nil)
        opens = opens + 1; return {}
    end,
    hardware_worker_query = function(_, safe)
        if response then
            return Wire.encode(response), { sample_started_ns = 80, sample_finished_ns = 95 }
        end
        return nil, "hardware_query_pending"
    end,
    hardware_worker_close = function(_, wait) assert(wait == 0); closes = closes + 1 end,
}
package.loaded["wtop.native"] = fake
package.loaded["wtop.collectors.hardware_worker"] = nil
local Hardware = require("wtop.collectors.hardware_worker")
assert(Hardware.available())
local proxy = Hardware.new({ id = "powercap", default_interval_ms = 1000 })
local context = { now_ns = function() return now end }
assert(proxy:probe(context).reason == "hardware_query_pending")
assert(proxy:sample(context).sampling_pending)
response = { capability = { state = "available", available = true },
    result = { status = "ok", quality = "fresh", timestamp_ns = 90,
        data = { total_power_watts = 12.5, zones = {} } } }
local fresh = proxy:sample(context)
assert(fresh.timestamp_ns == 100 and fresh.value_timestamp_ns == 90)
local snapshot = Snapshot.merge(Snapshot.new(0, 0), { powercap = fresh }, 1, now)
local old = snapshot.power
response, now = nil, 110
local pending = proxy:sample(context)
assert(pending.status == "error" and pending.quality == "stale" and pending.sampling_pending)
snapshot = Snapshot.merge(snapshot, { powercap = pending }, 2, now)
assert(snapshot.power == old and snapshot.power.total_power_watts == 12.5)
assert(snapshot.quality.power.quality == "stale" and snapshot.quality.power.value_timestamp_ns == 90)
-- Probing must not discard the first counter sample. A safe-mode change must
-- discard an unconsumed reply from the old worker and cancel that lease.
response = { capability = { state = "available", available = true },
    result = { status = "ok", quality = "fresh", timestamp_ns = 90, data = {} } }
assert(proxy:probe(context).available)
response = nil; context.safe_mode = true
assert(proxy:sample(context).sampling_pending and closes == 1 and opens == 2)
proxy:close(); assert(closes == 2)
assert(proxy:sample(context).reason == "hardware_worker_closed" and opens == 2)
package.loaded["wtop.native"] = actual
package.loaded["wtop.collectors.hardware_worker"] = nil
-- A short normal IPC round trip must neither erase a valid row nor add a
-- fabricated history gap. A sustained pending read must become visibly stale.
local Engine = require("wtop.engine")
now = 100
local stage = 0
local engine = Engine.new({ clock = { now_ns = function() return now end,
    wall_ns = function() return now end }, collectors = {
    powercap = { id = "powercap", default_interval_ms = 1000, sample = function()
        stage = stage + 1
        if stage == 1 then return fresh end
        return { status = "error", quality = "stale", reason = "hardware_query_pending",
            sampling_pending = true, defer_publish = stage == 2, retry_after_ms = 25,
            timestamp_ns = now }
    end },
} })
engine:tick(true)
assert(engine.history.cpu_power:newest().timestamp_ns == 90)
now = 110; local before = engine.snapshot
engine:tick(true)
assert(engine.snapshot == before and engine:has_pending_samples())
assert(engine.history.cpu_power:len() == 1 and engine.snapshot.quality.power.quality == "fresh")
now = 120; engine:tick(true)
assert(engine.snapshot.quality.power.quality == "stale"
    and engine.snapshot.quality.power.value_timestamp_ns == 90)
assert(engine.history.cpu_power:newest().value == false)
engine:stop()
local ViewModel = require("wtop.view_model")
local translator = assert(require("wtop.i18n").new({ locale = "en-US" }))
local state = {
    sensors = { devices = {{ id="chip", name="chip", channels={{ id="temp:1", type="temperature",
        index=1, label="chip temperature", input=99, quality="fresh", alarm=true }} }} },
    cpu_frequency = { policies={{ id="policy0", affected_cpus={0}, quality="fresh",
        frequencies={current_hz=1200000000,current_quality="fresh"} }} },
    cpuidle = { cpus={{ id=0, states={{ id=0, name="C1", usage_delta=10, new_time_us=1000,
        time_delta_quality="fresh",usage_delta_quality="fresh" }} }} },
    thermal_throttle = { cpus={{ id=0, core_new=4,package_new=3,core_count=10,package_count=20 }} },
    quality = {},
}
for _, resource in ipairs({"sensors","cpu_frequency","cpuidle","thermal_throttle"}) do
    state.quality[resource]={status="error",quality="stale"}
end
local models=ViewModel.build({history_values=function() return {} end},state,translator,{},"compute")
assert(models.sensor_table.rows[1].status=="stale" and not models.sensor_table.rows[1].alarm)
assert(models.cpufreq_table.rows[1].quality=="stale")
assert(models.cpuidle_table.rows[1].quality=="stale" and models.cpuidle_table.rows[1].usage_delta=="—")
assert(models.thermal_throttle_table.rows[1].core_new=="—")
return true
