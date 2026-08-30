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

return true
