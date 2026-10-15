package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local Power = require("wtop.model.power")
local Powercap = require("wtop.collectors.powercap")
local Fixture = require("support.fixture_fs")
local Hardware = require("support.hardware_fixtures")
local Export = require("wtop.export")
local Report = require("wtop.report")
local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")
local Grid = require("wtop.ui.renderer.grid")
local Table = require("wtop.ui.widgets.table")
local TUI = require("wtop.tui")

local function near(actual, expected)
    assert(type(actual) == "number" and math.abs(actual - expected) < 1e-8,
        tostring(actual) .. " != " .. tostring(expected))
end

near(Power.compare(19.52, 20).percent, 97.6)
near(Power.compare(30, 20).percent, 150)
near(Power.compare(30, 20).headroom_watts, -10)
near(Power.compare(0, 20).percent, 0)
assert(Power.compare(10, 0) == nil and Power.compare(10, -1) == nil)
assert(Power.compare(nil, 20) == nil and Power.compare(-1, 20) == nil)
assert(Power.compare(10, 20, false) == nil)
assert(Power.compare(math.huge, 20) == nil and Power.compare(0/0, 20) == nil)
assert(Power.compare(1e308, 1e-308) == nil)

local function zone(id, source, cap)
    return { id = id, name = "package-0", source_kind = source,
        enabled = true, control_enabled = true, controls_enabled = true,
        power_watts = 19.52, power_quality = "measured", quality = "fresh",
        power_interval_ns = 1000000000,
        -- Deliberately unsorted: the first array element is not always PL1.
        constraints = {
            { id = 2, name = "peak_power", power_limit_watts = 114 },
            { id = 0, name = "long_term", power_limit_watts = cap,
                maximum_power_watts = 45, time_window_seconds = 28 },
            { id = 1, name = "short_term", power_limit_watts = 26,
                time_window_seconds = 0.00244 },
        } }
end
local msr, mmio = zone("intel-rapl:0", "intel-rapl", 26), zone("intel-rapl-mmio:0", "intel-rapl-mmio", 20)
msr.aggregate = true
local snap = { power = { zones = { mmio, msr }, total_power_watts = 19.52 } }
local engine = { history_values = function() return {} end }
local en = assert(I18n.new({ locale = "en-US" }))
local function model(value, translator)
    return ViewModel.build(engine, value, translator or en, {}, "compute").power_table
end
local rows = model(snap).rows
assert(#rows == 6 and rows[1].domain == "intel-rapl" and rows[4].domain == "intel-rapl-mmio")
assert(rows[1].constraint == "Sustained" and rows[2].constraint == "Short" and rows[3].constraint == "Peak")
near(rows[1].power_percent, 19.52 / 26 * 100)
near(rows[4].power_percent, 97.6)
assert(rows[4].limit == "20 W" and rows[4].power == "19.52 W")
assert(rows[4].usage:find("97.6%", 1, true) and rows[4].usage:find("[########]", 1, true))
assert(rows[2].window == "2.44 ms" and rows[3].window == "—")
assert(rows[1].interval == "1 s" and rows[1].controls == "enabled")

mmio.power_watts = 30
rows = model(snap).rows
near(rows[4].power_percent, 150)
assert(rows[4].usage:find("150%", 1, true) and rows[4].headroom == "-10 W")
mmio.power_watts = 0
assert(model(snap).rows[4].usage:find("[--------]", 1, true))
mmio.power_watts = 19.52

local exported = Export.snapshot(snap)
near(exported.power.zones[1].constraints[2].usage_percent, 97.6)
near(exported.power.zones[1].constraints[2].headroom_watts, 0.48)
assert(exported.power.zones[1].controls_enabled and exported.power.zones[1].power_interval_ns == 1e9)
local agent = Export.agent(snap)
near(agent.metrics.power.zones[1].constraints[2].usage_percent, 97.6)
assert(agent.metrics.power.zones_total == 2 and not agent.metrics.power.zones_truncated)
local report = Report.render(exported)
assert(report:find("Power caps", 1, true) and report:find("intel-rapl-mmio", 1, true))
assert(report:find("97.6%", 1, true) and report:find("0.002440 s", 1, true))
local detail = table.concat(TUI.power_detail_lines(snap, en), "\n")
assert(detail:find("Power and limits", 1, true) and detail:find("97.6%", 1, true))
assert(detail:find("114 W", 1, true) and detail:find("2.44 ms", 1, true))
snap.quality = { power = { status = "error", quality = "stale" } }
assert(model(snap).rows[4].usage == "—" and model(snap).rows[4].state == "stale")
assert(Export.snapshot(snap).power.zones[1].constraints[2].usage_percent == nil)
assert(Export.agent(snap).metrics.power.zones[1].constraints[2].usage_percent == nil)
snap.quality = nil

-- Both the cap setting and the power reading survive a disabled control, but
-- a disabled cap does not acquire a utilization bar. Missing state stays unknown.
mmio.control_enabled = false
assert(model(snap).rows[4].usage == "—" and model(snap).rows[4].controls == "disabled")
assert(Export.snapshot(snap).power.zones[1].constraints[2].usage_percent == nil)
mmio.control_enabled, mmio.controls_enabled = nil, nil
assert(model(snap).rows[4].controls == "unknown")
mmio.control_enabled, mmio.controls_enabled = true, true
for _, quality in ipairs({ "gap", "stale", "denied", "reset", "unavailable", "error" }) do
    mmio.power_quality = quality
    assert(model(snap).rows[4].usage == "—", quality)
end
mmio.power_watts, mmio.power_quality, snap.power.denied_zones = nil, "denied", 1
assert(model(snap).rows[4].power == "—" and model(snap).rows[4].limit == "20 W")
assert(model(snap).status_text:find("--sudo", 1, true))
mmio.power_watts, mmio.power_quality, snap.power.denied_zones = 19.52, "measured", 0

-- The glyph bar remains visible without colors; all three cap windows survive
-- a wide render in every shipped locale, while small layouts remain bounded.
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR",
    "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
    local translator = assert(I18n.new({ locale = locale }))
    local m = model(snap, translator)
    assert(translator:has("power.comparison_note") and translator:has("status.disabled"))
    for _, width in ipairs({ 24, 40, 60, 80, 120, 240 }) do
        local grid = Grid.new(width, 12)
        Table.render(grid, { x = 1, y = 1, width = width, height = 12 }, m,
            { i18n = translator, capabilities = { unicode = false } }, "full")
        if width == 240 then
            local lines = {}
            for y = 1, 12 do lines[y] = grid:row_text(y) end
            local text = table.concat(lines, "\n")
            assert(text:find("[########]", 1, true), locale)
            assert(text:find("intel-rapl-mmio", 1, true), locale)
        end
    end
end

-- Data from the same vendor query can be compared. A cap from another source,
-- a different hwmon rail, a warning threshold or the CPU cannot be substituted.
local channel = { input = 15, thresholds = { cap = 20, max = 50, crit = 60 }, source = "power2" }
local metrics = { power_watts = 30, power_limit_watts = 40,
    power_source = "nvml", power_limit_source = "nvml" }
near(Power.gpu(metrics, channel).comparison.percent, 75)
assert(Power.gpu(metrics, channel, { quality = "stale" }).comparison == nil)
metrics.power_limit_source = "other"
assert(Power.gpu(metrics, channel).comparison == nil)
local only_cap = Power.gpu({ power_limit_watts = 40, power_limit_source = "nvml" })
assert(only_cap.limit == 40 and only_cap.watts == nil and only_cap.comparison == nil)
metrics.power_limit_watts, metrics.power_limit_source = nil, nil
assert(Power.gpu(metrics, channel).comparison == nil)
near(Power.gpu({}, channel).comparison.percent, 75)
channel.thresholds.cap = nil
assert(Power.gpu({}, channel).comparison == nil)
channel.thresholds.cap, channel.input = 20, 0
near(Power.gpu({}, channel).comparison.percent, 0)
channel.quality = "stale"
assert(Power.gpu({}, channel).comparison == nil)
local fallback_snapshot = { gpus = { devices = {
    { id = "card0", hwmon_refs = { { class = "hwmon0" } }, metrics = {},
        quality = { power = "unavailable" } },
} }, sensors = { devices = { { class = "hwmon0", channels = {
    { type = "power", input = 15, thresholds = { cap = 20 }, quality = "fresh" },
} } } } }
near(ViewModel.build(engine, fallback_snapshot, en, {}, "gpu").gpu_table.rows[1].power_percent, 75)

for _, provider in ipairs({ "nvml", "amdsmi" }) do
    local existing = { id = "0000:01:00.0", card = "card0", metrics = {},
        quality = { power = "unavailable" }, capabilities = { power = false } }
    local devices = { existing }
    require("wtop.collectors." .. provider).merge(devices,
      { by_bdf = { ["0000:01:00.0"] = existing } }, {
        devices = { { index = 0, pci_bdf = "0000:01:00.0", name = "Fixture GPU",
            power_watts = 25, power_limit_watts = 100 } },
    }, { used_ids = {} })
    assert(devices[1].metrics.power_source == provider)
    assert(devices[1].metrics.power_limit_source == provider)
    assert(devices[1].quality.power == "fresh" and devices[1].capabilities.power)
    local gpu_snapshot = { gpus = { devices = devices } }
    near(ViewModel.build(engine, gpu_snapshot, en, {}, "gpu").gpu_table.rows[1].power_percent, 25)
    near(Export.snapshot(gpu_snapshot).gpus.devices[1].metrics.power_limit_percent, 25)
    near(Export.agent(gpu_snapshot).top.gpus[1].metrics.power_limit_percent, 25)
    gpu_snapshot.quality = { gpus = { status = "error", quality = "stale" } }
    assert(Export.snapshot(gpu_snapshot).gpus.devices[1].metrics.power_limit_percent == nil)
    assert(Export.agent(gpu_snapshot).top.gpus[1].metrics.power_limit_percent == nil)
end

-- Real collector shapes: units, first sample, counter wrap, missing control
-- state and the averaging interval all reach the same export as the UI.
local first_tree = Hardware.powercap_intel_rapl()
local collector = Powercap.new({ fs = Fixture.new(first_tree) })
local first = collector:sample({ now_ns = function() return 1e9 end })
collector.fs = Fixture.new(Hardware.powercap_intel_rapl_advanced(nil, 20000000))
local second = collector:sample({ now_ns = function() return 2e9 end }, first)
local measured = assert(second.data.by_id["intel-rapl:0"])
near(measured.power_watts, 20)
assert(measured.power_interval_ns == 1e9)
for _, z in ipairs(first.data.zones) do assert(z.power_watts == nil) end
assert(measured.enabled and measured.control_enabled and measured.controls_enabled)
local package_path = "/sys/class/powercap/intel-rapl:0"
first_tree.files[package_path .. "/enabled"] = nil
first_tree.files["/sys/class/powercap/intel-rapl/enabled"] = nil
collector.fs = Fixture.new(first_tree)
local unknown = collector:sample({ now_ns = function() return 3e9 end })
local unknown_zone = unknown.data.by_id["intel-rapl:0"]
assert(unknown_zone.enabled == nil and unknown_zone.control_enabled == nil)
assert(unknown_zone.controls_enabled == nil)
first_tree.files[package_path .. "/enabled"] = "1\n"
first_tree.files["/sys/class/powercap/intel-rapl/enabled"] = "0\n"
first_tree.files[package_path .. "/power_uw"] = "19520000\n"
first_tree.denied = { [package_path .. "/energy_uj"] = true }
collector.fs = Fixture.new(first_tree)
local disabled = collector:sample({ now_ns = function() return 4e9 end })
local disabled_zone = disabled.data.by_id["intel-rapl:0"]
assert(disabled_zone.enabled and disabled_zone.control_enabled == false)
assert(disabled_zone.controls_enabled == false and disabled_zone.power_quality == "measured")
near(disabled_zone.power_watts, 19.52)
assert(Power.zone(disabled_zone, disabled_zone.constraints[1]) == nil)
local replacement = Hardware.powercap_intel_rapl_advanced(nil, 20000000)
replacement.files[package_path .. "/name"] = "package-9\n"
collector.fs = Fixture.new(replacement)
local replaced = collector:sample({ now_ns = function() return 2e9 end }, first)
assert(replaced.data.by_id["intel-rapl:0"].power_watts == nil)

-- Bound the expanded view and state the omitted rows, not just omitted zones.
local many = { power = { zones = {} } }
for index = 1, 200 do many.power.zones[index] = zone(tostring(index), "fixture", 20) end
local limited = model(many)
assert(#limited.rows == 512 and limited.status_text:find("512 of 600", 1, true))
local compact = Export.agent(many)
assert(#compact.metrics.power.zones == 5 and compact.metrics.power.zones_total == 200)
assert(compact.metrics.power.zones_truncated)
assert(Report.render(Export.snapshot(many)):find("The source list was truncated.", 1, true))

print("ok: power caps, source pairing, averaging windows, percentages and monochrome bars")
