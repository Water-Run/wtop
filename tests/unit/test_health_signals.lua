local Health = require("wtop.model.health")
local Export = require("wtop.export")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Json = require("wtop.format.json")

local function signal(snapshot, code, resource)
    for _, row in ipairs(Health.summary(snapshot).signals) do
        if row.code == code and (resource == nil or row.resource == resource) then return row end
    end
end

local function parity(snapshot)
    local before = assert(Json.encode(snapshot))
    local health, agent = Health.summary(snapshot), Export.agent(snapshot)
    assert(TUI.alert_count(snapshot) == #agent.signals)
    assert(health.state == agent.overall.state and #health.signals == #agent.signals)
    for index, row in ipairs(health.signals) do
        for _, field in ipairs({ "resource", "code", "severity", "value", "unit", "message" }) do
            assert(row[field] == agent.signals[index][field], field .. " differs between model and Agent")
        end
    end
    assert(before == Json.encode(snapshot), "health projections mutated their measurement")
    return health
end

for _, pair in ipairs({ { 74.9, false }, { 75, "warning" }, { 89.9, "warning" }, { 90, "critical" } }) do
    local s = { cpu = { total = { utilization = pair[1] } } }
    local row = signal(s, "high_utilization", "cpu")
    assert((row and row.severity or false) == pair[2])
    parity(s)
end
for _, pair in ipairs({ { 84.9, false }, { 85, "warning" }, { 95, "critical" }, { 150, "critical" } }) do
    local s = { memory = { used_bytes = pair[1], total_bytes = 100 } }
    local row = signal(s, "high_usage")
    assert((row and row.severity or false) == pair[2])
    if pair[1] == 150 then assert(row.value == 100) end
    parity(s)
end
local bad = { cpu = { total = { utilization = 0 / 0, iowait = math.huge } },
    memory = { total_bytes = -1, used_bytes = math.huge } }
assert(#parity(bad).signals == 0)
assert(parity({ memory = { total_bytes = 100, used_bytes = 40 } }).state == "ok",
    "an available memory observation must not disappear because CPU is absent")
local stale = { cpu = { total = { utilization = 99 } },
    memory = { total_bytes = 100, used_bytes = 99 }, quality = {
        cpu = { status = "error", quality = "stale" },
        memory = { status = "ok", quality = "stale" },
        spd = { status = "denied", quality = "denied" },
        firmware_power_supplies = { status = "unavailable", quality = "unavailable" },
    } }
assert(#parity(stale).signals == 2)
assert(signal(stale, "data_unavailable", "cpu") and signal(stale, "data_stale", "memory"))
assert(not signal(stale, "high_utilization") and not signal(stale, "high_usage"))
for _, quality in ipairs({ "gap", "reset", "partial", "truncated" }) do
    local s = { quality = { cpu = { status = "ok", quality = quality } } }
    assert(#parity(s).signals == 1)
end

-- Rate quality belongs to the measured total, not to every core at once.
-- Retained finite numbers must not become current load alarms or an OK verdict.
for _, quality in ipairs({ "gap", "reset", "held", "missing", "stale", "error", "denied", "unavailable" }) do
    local s = { cpu = { total = { utilization = 99, iowait = 30, quality = quality },
        load = { one = 2 }, cores = { {} } } }
    assert(not signal(s, "high_utilization") and not signal(s, "high_iowait"), quality)
    assert(signal(s, "high_load"), "instantaneous load must survive a rate gap: " .. quality)
    s.cpu.load = nil
    assert(parity(s).state == "unknown", "invalid CPU rate became an OK observation: " .. quality)
    s.cpu.total.quality = nil
    s.quality = { cpu = { status = "ok", quality = quality } }
    assert(not signal(s, "high_utilization") and not signal(s, "high_iowait"), quality)
    parity(s)
end
for _, quality in ipairs({ "fresh", "measured", "estimated", "partial", "truncated" }) do
    local s = { cpu = { total = { utilization = 99, iowait = 30, quality = quality } },
        quality = { cpu = { status = "ok", quality = "gap" } } }
    assert(signal(s, "high_utilization") and signal(s, "high_iowait"), quality)
    assert(signal(s, "data_gap"), "a valid total must not hide the per-core gap")
    parity(s)
    s.quality.cpu.status = "error"
    assert(not signal(s, "high_utilization") and not signal(s, "high_iowait"))
end
assert(parity({ cpu = { total = { utilization = 20, quality = "held" } },
    memory = { total_bytes = 100, used_bytes = 40 } }).state == "ok")
assert(parity({ memory = { total_bytes = 100, used_bytes = 40 },
    quality = { memory = { status = "ok", quality = "unavailable" } } }).state == "warning")

-- Exercise the production Linux derivation: adding a core creates a source
-- gap, while the independently differenced aggregate is still 99% busy.
do
    local CPU = require("wtop.collectors.cpu")
    local stat = "cpu 0 0 0 100 0 0 0 0 0 0\ncpu0 0 0 0 100 0 0 0 0 0 0\n"
    local fs = { read = function(_, path)
        if path == "/proc/stat" then return stat end
        return "0.0 0.0 0.0 1/2 3\n"
    end }
    local cpu = CPU.new({ fs = fs })
    local first = cpu:sample({ now_ns = function() return 1000000000 end })
    stat = "cpu 99 0 0 101 0 0 0 0 0 0\ncpu0 99 0 0 101 0 0 0 0 0 0\n"
        .. "cpu1 0 0 0 0 0 0 0 0 0 0\n"
    local next_sample = cpu:sample({ now_ns = function() return 2000000000 end }, first)
    assert(next_sample.quality == "gap" and next_sample.data.total.quality == "fresh")
    assert(next_sample.data.cores[2].quality == "gap")
    local s = { cpu = next_sample.data, quality = { cpu = next_sample } }
    assert(signal(s, "high_utilization").value == 99 and signal(s, "data_gap"))
    parity(s)
end

for _, quality in ipairs({ "gap", "reset", "held", "missing", "stale", "error", "denied", "unavailable" }) do
    local s = { disks = { devices = {
        { name = "retained", busy_percent = 100, busy_quality = quality },
        { name = "current", busy_percent = 90, busy_quality = "fresh" },
    } }, gpus = { devices = {
        { id = "retained", metrics = { utilization_percent = 100 },
            metric_observations = { utilization_percent = { quality = quality } } },
        { id = "current", metrics = { utilization_percent = 90 },
            quality = { utilization = "fresh" } },
    } } }
    assert(signal(s, "device_busy").value == 90, quality)
    assert(signal(s, "high_utilization", "gpu").value == 90, quality)
    s.disks.devices[2], s.gpus.devices[2] = nil, nil
    assert(not signal(s, "device_busy") and not signal(s, "high_utilization", "gpu"), quality)
    parity(s)
end

local mounts = { mounts = { mounts = {
    { id = "net", kind = "network", mount_point = "/net", capacity = { used_percent = 100 } },
    { id = "old", kind = "local", quality = "stale", capacity = { used_percent = 100 } },
    { id = "local", kind = "local", quality = "fresh", mount_point = "/data",
        capacity = { used_percent = 92 } },
} } }
assert(#parity(mounts).signals == 1)
assert(signal(mounts, "high_capacity").severity == "warning")
assert(signal(mounts, "high_capacity").subject == "/data")
mounts.mounts.mounts[3].capacity.used_percent = 98
assert(signal(mounts, "high_capacity").severity == "critical")
mounts.quality = { mounts = { status = "error", quality = "stale" } }
assert(#parity(mounts).signals == 1 and not signal(mounts, "high_capacity"))

local sensors = { timestamp_ns = 1000000000,
    sensors = { devices = { { id = "chip", name = "chip", channels = {
        { id = "hot", label = "Hot but safe", type = "temperature", unit = "celsius",
            quality = "fresh", input = 95, thresholds = { crit = 110 } },
        { id = "limit", label = "Own limit", type = "temperature", unit = "celsius",
            quality = "fresh", input = 75, thresholds = { max = 70, crit = 74 } },
    } } } }, quality = { sensors = { status = "ok", quality = "fresh", value_timestamp_ns = 1000000000 } } }
assert(signal(sensors, "temperature_threshold").value == 75)
assert(signal(sensors, "temperature_threshold").subject == "chip / Own limit")
parity(sensors)
local channel = sensors.sensors.devices[1].channels[2]
channel.errors = { crit = "parse_error", max = "parse_error" }
assert(not signal(sensors, "temperature_threshold"), "failed threshold fields are not alarm evidence")
channel.errors, channel.thresholds = nil, { emergency = 74 }
assert(signal(sensors, "temperature_threshold").severity == "critical")
channel.unit = "kelvin"
assert(not signal(sensors, "temperature_threshold"), "temperature units must match")
channel.unit, channel.fault, channel.alarm = "celsius", true, true
assert(not signal(sensors, "temperature_threshold"))
assert(signal(sensors, "sensor_fault") and signal(sensors, "sensor_alarm"))
assert(#parity(sensors).signals == 2)
for _, quality in ipairs({ "stale", "gap", "reset", "held", "missing", "denied", "error", "unavailable" }) do
    channel.quality = quality
    assert(#Health.summary(sensors).signals == 0, "old channel flags became current: " .. quality)
end
channel.quality, channel.errors = "fresh", { alarm = "read_failed", fault = "read_failed" }
assert(#Health.summary(sensors).signals == 0)
channel.errors = nil
sensors.timestamp_ns = 17000000000
assert(#parity(sensors).signals == 0, "aged sensor flags became current")
sensors.timestamp_ns = 500000000
assert(#Health.summary(sensors).signals == 0, "future observations became current")

local gpu = { gpus = { devices = {} } }
for i = 1, 8 do
    gpu.gpus.devices[i] = { id = tostring(i), metrics = { utilization_percent = 99 },
        quality = { utilization = "fresh" }, metric_observations = {
            utilization_percent = { quality = i == 8 and "fresh" or "stale" },
        } }
end
assert(signal(gpu, "high_utilization", "gpu").severity == "critical")
assert(#parity(gpu).signals == 1)
gpu.quality = { gpus = { status = "ok", quality = "stale" } }
assert(#parity(gpu).signals == 0)

local storage = { disks = { devices = {
    { id = "estimated", busy_percent = 100, busy_quality = "estimated" },
    { id = "exact", name = "disk0", busy_percent = 96, busy_quality = "fresh",
        stack = { kind = "md", status = "ok", array_state = "clean", raid_disks = 2, degraded = 1 },
        nvme = { counters = { io_failures_no_path = { status = "ok", delta_quality = "fresh", new = 1 } } } },
} } }
assert(#parity(storage).signals == 3)
storage.disks.devices[2].busy_quality = "estimated"
storage.disks.devices[2].stack.degraded = 3
storage.disks.devices[2].nvme.counters.io_failures_no_path.delta_quality = "reset"
assert(#parity(storage).signals == 0)

local aer = { inventory = { pci = { devices = {} } } }
for i = 1, 8 do aer.inventory.pci.devices[i] = { aer = {
    fatal = { change = { quality = "fresh", new_reports = 1 } },
    rootport = { changes = { fatal = { quality = "fresh", new_reports = 1 },
        nonfatal = { quality = "fresh", new_reports = 2 } } },
} } end
assert(#parity(aer).signals == 2, "device/root AER reports were added as separate failures")
aer.quality = { inventory = { status = "ok", quality = "stale" } }
assert(#parity(aer).signals == 0)
local quiet = { cpu = { total = { utilization = 20 } }, memory = { used_bytes = 40, total_bytes = 100 },
    power = { zones = { { enabled = true, power_watts = 21, power_quality = "fresh",
        constraints = { { power_limit_watts = 20 } } } } },
    firmware_power_supplies = { devices = { { status = "critical", capacity_watts = 400 } } },
    sensors = { devices = { { fan_controls = { { setting_percent = 100 } }, channels = {} } } } }
assert(#parity(quiet).signals == 0, "power caps, PWM settings or firmware declarations became faults")
assert(Health.summary({}).state == "unknown")
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "de-DE", "fr-FR", "es-ES", "pt-BR", "ru-RU" }) do
    local i18n = assert(I18n.new({ locale = locale }))
    local lines = table.concat(TUI.health_lines(storage, i18n), "\n")
    assert(lines:find(i18n:t("health.title"), 1, true))
    assert(lines:find(i18n:t("health.unknown"), 1, true))
    lines = table.concat(TUI.health_lines(stale, i18n), "\n")
    assert(lines:find(i18n:t("health.data_unavailable"), 1, true))
    assert(lines:find(i18n:t("health.data_stale"), 1, true))
    assert(table.concat(TUI.health_lines(quiet, i18n), "\n"):find(i18n:t("health.none"), 1, true))
    assert(not table.concat(TUI.health_lines({}, i18n), "\n"):find(i18n:t("health.none"), 1, true))
end
print("ok: shared health signals, Agent/header parity, current sensor flags, bounded categories and ten localized warning views")
