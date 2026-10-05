package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Engine = require("wtop.engine")
local Runner = require("wtop.core.runner")
local UpdateFrequency = require("wtop.update_frequency")

local expected_frequencies = {
    {"very_low", 8000}, {"low", 5000}, {"moderately_low", 3000},
    {"medium_low", 2000}, {"medium", 1000}, {"medium_high", 750},
    {"moderately_high", 500}, {"high", 300}, {"very_high", 100},
}
for index, expected in ipairs(expected_frequencies) do
    local level = assert(UpdateFrequency.level(index))
    assert(level.id == expected[1] and level.interval_ms == expected[2])
    assert(UpdateFrequency.nearest_index(expected[2]) == index)
    assert(UpdateFrequency.cycle(index, 1) == (index % #expected_frequencies) + 1)
end

local safe_engine = Engine.new({ safe_mode = true, collectors = {} })
assert(safe_engine.context.runner.execute == false,
    "safe mode must keep the external argv executor disabled")

local injected_calls = 0
local injected_runner = Runner.new({
    execute = function()
        injected_calls = injected_calls + 1
        return { status = "ok", stdout = "", stderr = "", exit_code = 0 }
    end,
})
local isolated_engine = Engine.new({
    safe_mode = true,
    collectors = {},
    context = { runner = injected_runner },
})
local isolated_result = isolated_engine.context.runner:run({ "/usr/bin/true" })
assert(isolated_result.status == "unavailable")
assert(injected_calls == 0, "safe mode must replace an injected executable runner")
assert(not pcall(Engine.new, "invalid"))
assert(not pcall(Engine.new, { collectors = "invalid" }))
assert(not pcall(Engine.new, { collectors = {}, interval_ms = math.huge }))
assert(not pcall(Engine.new, { collectors = {}, history_capacity = 1000001 }))

local now = 1000000000
local clock = {
    now_ns = function()
        now = now + 1000000
        return now
    end,
    wall_ns = function()
        return 1700000000000000000
    end,
}

local function collector(id, data)
    return {
        id = id,
        default_interval_ms = 1000,
        probe = function()
            return { state = "available", available = true }
        end,
        sample = function()
            return { status = "ok", quality = "fresh", timestamp_ns = clock:now_ns(), data = data }
        end,
    }
end

local collectors = {
    cpu = collector("cpu", { total = { utilization = 42 } }),
    memory = collector("memory", { total_bytes = 100, used_bytes = 25 }),
    pressure = collector("pressure", { cpu = { some = { avg10 = 1.5 } } }),
    disk = collector("disk", { devices = { { read_bytes_per_second = 10, write_bytes_per_second = 20 } } }),
    network = collector("network", { interfaces = { { rates = {
        rx_bytes_per_second = 30,
        tx_bytes_per_second = 40,
    } } } }),
    connections = collector("connections", { connections = {} }),
    process = collector("process", { list = {} }),
    gpu = collector("gpu", { devices = { { metrics = { utilization_percent = 50 } } } }),
    hwmon = collector("hwmon", { devices = {} }),
}

local engine = Engine.new({ clock = clock, collectors = collectors, history_capacity = 4 })
local capabilities = engine:probe()
assert(capabilities.cpu.available)
local snapshot = engine:tick(true)
assert(snapshot.sequence == 1)
assert(snapshot.cpu.total.utilization == 42)
assert(snapshot.disks.devices[1].read_bytes_per_second == 10)
assert(engine:history_values("cpu")[1] == 42)
assert(engine:history_values("memory")[1] == 25)
assert(engine:history_values("network_transmit")[1] == 40)
local cpu_history = engine:history_values("cpu")
assert(cpu_history.n == 1 and #cpu_history.timestamps_ns == 1)
assert(cpu_history.window_ns == Engine.HISTORY_WINDOW_MS * 1000000)
assert(cpu_history.column_ns == 1000000000,
    "one chart column must retain the default one-second time scale")
assert(not pcall(function() engine:next_delay_ms(0) end))

assert(engine:set_interval(100))
assert(engine.scheduler:task("cpu").interval_ms == 100)
assert(engine.scheduler:task("network").interval_ms == 100)
assert(engine.scheduler:task("process").interval_ms == 1000,
    "high-cardinality collector floor must survive very-high UI updates")
assert(engine.scheduler:task("network").background_interval_ms == 3000)
assert(engine:set_interval(8000))
assert(engine.scheduler:task("cpu").interval_ms == 8000)
assert(engine.scheduler:task("network").background_interval_ms == 8000)
assert(engine:set_interval(100))
assert(engine.scheduler:task("network").background_interval_ms == 3000,
    "lowering the foreground interval must restore the configured background cadence")
assert(engine:set_interval(99) == nil)

assert(engine:set_active_tab("processes"))
assert(engine.scheduler:task("process").visible == true)
assert(engine.scheduler:task("cpu").visible == true)
assert(engine.scheduler:task("network").visible == false)
assert(engine.scheduler:task("network").background_interval_ms == 3000)
assert(engine.context.scan_gpu_processes == false)
local network_due = engine.scheduler:task("network").next_due_ns
assert(network_due >= clock:now_ns() + 2900 * 1000000,
    "hiding a collector must immediately apply its background cadence")
assert(engine:set_active_tab("network"))
assert(engine.scheduler:task("network").visible == true)
assert(engine.scheduler:task("connections").visible == true)
assert(engine.context.scan_connection_owners == true)
assert(engine.scheduler:task("network").next_due_ns <= network_due,
    "showing a page must make its collectors immediately eligible")
assert(engine:set_active_tab("gpu"))
assert(engine.context.scan_gpu_processes == true)
assert(engine.scheduler:task("hwmon").visible == true)
assert(engine:set_active_tab("gpu", { gpu_summary = true }))
assert(engine.scheduler:task("gpu").visible == true)
assert(engine.scheduler:task("hwmon").visible == false)
assert(engine.context.scan_gpu_processes == false,
    "a collapsed GPU process table must disable fdinfo scans")
assert(engine:set_active_tab("gpu", { gpu_process_table = true }))
assert(engine.context.scan_gpu_processes == true)
assert(engine:set_active_tab("network", { network_summary = true }))
assert(engine.scheduler:task("connections").visible == false)
assert(engine.context.scan_connection_owners == false)
assert(engine:set_active_tab("network", { connection_table = true }))
assert(engine.scheduler:task("connections").visible == true)
assert(engine.context.scan_connection_owners == true)
assert(engine:set_active_tab("not-a-tab") == false)

-- A CPU-only completion must not manufacture duplicate memory/history samples.
local memory_samples = engine:history_values("memory").n
engine:_record_history(engine.snapshot, {
    cpu = {status = "ok", timestamp_ns = engine.snapshot.timestamp_ns},
})
assert(engine:history_values("cpu").n == cpu_history.n + 1)
assert(engine:history_values("memory").n == memory_samples)
engine:set_paused(true)
assert(engine:tick().sequence == 1)
assert(engine:next_delay_ms(100) == 100, "paused engines must not expose an expired zero deadline")
engine:stop()

-- Before first paint, never-run hidden collectors are deferred instead of
-- being swept into the active page's synchronous refresh.
local fresh = Engine.new({ clock = clock, collectors = collectors, history_capacity = 4 })
assert(fresh:set_active_tab("processes"))
local _, first_page = fresh:tick_visible()
assert(first_page.cpu and first_page.memory and first_page.process)
assert(first_page.network == nil and first_page.connections == nil and first_page.gpu == nil)
assert(fresh.scheduler:task("network").runs == 0)
assert(fresh.scheduler:task("network").next_due_ns > clock:now_ns())
assert(fresh:set_active_tab("network"))
local _, network_page = fresh:tick_visible()
assert(network_page.network and network_page.connections)
fresh:stop()

-- An absent kernel interface must cost its own panel and nothing else.
--
-- This is what "wtop has no minimum kernel" means in practice, so it is worth
-- more than the sentence: the claim only holds because a collector whose probe
-- cannot find its source is recorded as a capability and then sampled anyway,
-- returning nothing, while every other collector keeps producing.  The shape
-- below is an old kernel rather than a broken one -- no cgroup v2, no PSI, no
-- hwmon, no DRM, no powercap, no cpufreq, no DMI -- and the program still ticks.
local function absent(id, reason)
    return {
        id = id,
        default_interval_ms = 1000,
        probe = function()
            return { state = "unavailable", available = false, reason = reason }
        end,
        sample = function()
            return {
                status = "unavailable", quality = "unavailable",
                timestamp_ns = clock:now_ns(), reason = reason, data = nil,
            }
        end,
    }
end

local old_kernel = Engine.new({
    clock = clock,
    history_capacity = 4,
    collectors = {
        cpu = collector("cpu", { total = { utilization = 11 } }),
        memory = collector("memory", { total_bytes = 100, used_bytes = 25 }),
        cgroup = absent("cgroup", "cgroup_v2_unavailable"),
        pressure = absent("pressure", "proc_pressure_unavailable"),
        hwmon = absent("hwmon", "sys_hwmon_unavailable"),
        gpu = absent("gpu", "drm_unavailable"),
        powercap = absent("powercap", "sys_powercap_unavailable"),
        cpufreq = absent("cpufreq", "sys_cpufreq_unavailable"),
    },
})
local old_capabilities = old_kernel:probe()
assert(old_capabilities.cpu.available, "a present interface is still available")
for _, id in ipairs({ "cgroup", "pressure", "hwmon", "gpu", "powercap", "cpufreq" }) do
    assert(old_capabilities[id], "the absent interface is still reported: " .. id)
    assert(old_capabilities[id].available == false,
        "an interface the kernel does not have is not available: " .. id)
end
local old_snapshot = old_kernel:tick(true)
assert(old_snapshot.sequence == 1, "an old kernel still produces a snapshot")
assert(old_snapshot.cpu.total.utilization == 11,
    "the collectors that do have a source keep their figures")
assert(old_snapshot.memory.total_bytes == 100, "and so does memory")
-- Absent, not zero, and *why*.  A panel with no source to read must not be
-- handed a figure for the interface it could not find -- and the reason has to
-- reach the snapshot, because that record is what the panel and the export both
-- read.  Asserting the key is nil would prove nothing, since a fresh snapshot
-- pre-populates every resource key; the claim under test is what the quality
-- record says, and that no figure was invented to fill the space.
for _, id in ipairs({ "workloads", "pressure", "sensors", "gpus", "power", "cpu_frequency" }) do
    local record = assert(old_snapshot.quality[id], "the snapshot reports " .. id)
    assert(record.status == "unavailable",
        id .. " is reported unavailable rather than as a reading: " .. tostring(record.status))
    assert(type(record.reason) == "string" and record.reason ~= "",
        id .. " carries the reason the collector gave, not a bare state")
    assert(record.quality == "unavailable",
        id .. " is not dressed up as a fresh or estimated sample")
end
-- `Snapshot.merge` stores data only on an ok result, so each of these is what a
-- fresh snapshot starts as rather than something the collector produced.
for _, id in ipairs({ "workloads", "sensors", "gpus", "power" }) do
    local value = old_snapshot[id]
    assert(value == nil or next(value) == nil,
        "a panel with no source must not carry invented data: " .. id)
end
-- The chart history follows the same rule, but in a subtler way.  Asserting
-- "no sample" would be wrong: the ring is dense on purpose, and a missing slot
-- would silently shift every later column.  What the renderer must see is a
-- gap -- the boolean sentinel -- rather than a fabricated zero watts, which
-- would draw a line along the floor and read as a powered-down machine.
local power_history = old_kernel:history_values("cpu_power")
assert(power_history.n == 1, "an absent panel still occupies its slot in the ring")
assert(power_history[1] == false,
    "and that slot is a gap sentinel, not a fabricated zero: " .. tostring(power_history[1]))
assert(old_kernel:history_values("cpu")[1] == 11,
    "a panel that does have a source still charts a real reading")
old_kernel:stop()

-- An old kernel is not only a kernel whose probes answer "absent".  A probe
-- that reads a file the running kernel never laid out can raise before it gets
-- to answer, and `probe_all` runs every probe under a pcall precisely so that
-- one raising probe cannot take the program down with it.  That pcall is the
-- load-bearing half of "no minimum kernel", so it gets its own case: a probe
-- that throws is still just a capability, and its absence is still local.
local function raising(id)
    return {
        id = id,
        default_interval_ms = 1000,
        probe = function()
            error("probe exploded on " .. id, 0)
        end,
        sample = function()
            return {
                status = "unavailable", quality = "unavailable",
                timestamp_ns = clock:now_ns(), reason = id .. "_unavailable", data = nil,
            }
        end,
    }
end

local hostile = Engine.new({
    clock = clock,
    history_capacity = 4,
    collectors = {
        cpu = collector("cpu", { total = { utilization = 7 } }),
        hwmon = raising("hwmon"),
        powercap = raising("powercap"),
    },
})
local hostile_capabilities = assert(hostile:probe(), "a raising probe does not stop probing")
assert(hostile_capabilities.hwmon.state == "error" and hostile_capabilities.hwmon.available == false,
    "a probe that raised is recorded as an errored capability, not an available one")
assert(hostile_capabilities.hwmon.reason:find("hwmon", 1, true) ~= nil,
    "and it keeps the failure text, so the cause is not swallowed into a bare state")
assert(hostile_capabilities.cpu.available,
    "the collectors that did answer are unaffected by their neighbour's failure")
local hostile_snapshot = hostile:tick(true)
assert(hostile_snapshot.cpu.total.utilization == 7,
    "a raising probe costs its own panel and nothing else")
for _, id in ipairs({ "sensors", "power" }) do
    assert(hostile_snapshot.quality[id].status == "unavailable",
        "the panel behind a raising probe is still reported unavailable: " .. id)
end
hostile:stop()

-- And the engine does not take a collector's word for it that its data is
-- good.  Every collector in the tree returns `data = nil` alongside a non-ok
-- status today, so nothing exercises the guard that refuses to install data
-- from a result that is not ok -- which means a future collector that returns
-- partial figures alongside a failed status would silently paint them onto a
-- panel that the snapshot is simultaneously labelling unavailable.  The two
-- claims would then disagree in the same record, so the guard is pinned here.
local function contradicting(id)
    return {
        id = id,
        default_interval_ms = 1000,
        probe = function()
            return { state = "unavailable", available = false, reason = id .. "_unavailable" }
        end,
        sample = function()
            return {
                status = "unavailable", quality = "unavailable",
                timestamp_ns = clock:now_ns(), reason = id .. "_unavailable",
                -- Deliberately self-contradictory: the collector both refuses to
                -- read and hands over a figure anyway.
                data = { devices = { { name = "phantom" } } },
            }
        end,
    }
end

local liar = Engine.new({
    clock = clock,
    history_capacity = 4,
    collectors = {
        cpu = collector("cpu", { total = { utilization = 5 } }),
        hwmon = contradicting("hwmon"),
    },
})
local liar_snapshot = liar:tick(true)
assert(liar_snapshot.quality.sensors.status == "unavailable",
    "the result is still labelled unavailable")
local liar_sensors = liar_snapshot.sensors
assert(liar_sensors == nil or next(liar_sensors) == nil,
    "and its self-contradictory payload is not installed: " .. type(liar_sensors))
liar:stop()

return true
