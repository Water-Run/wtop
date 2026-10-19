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
    return { id = id, name = "package-0", source_kind = source, aggregate_domain = "cpu_package",
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

-- The panel reports each domain's own observation time and failed read
-- inputs. An optional cap failure cannot masquerade as a watt-read failure.
local observed = zone("intel-rapl:9", "intel-rapl", 20)
observed.source = "/sys/class/powercap/intel-rapl:9"
observed.observed_at_ns = 19e9
local observed_snapshot = { timestamp_ns = 20e9, power = { zones = { observed } },
    quality = { power = { status = "ok", quality = "fresh", value_timestamp_ns = 20e9 } } }
local function observed_row()
    return ViewModel.power_detail_rows(observed_snapshot, en)[1]
end
near(observed_row().power_age_ns, 1e9)
assert(observed_row().power_source_path == observed.source)
observed.power_watts = 0
near(observed_row().power_age_ns, 1e9)
observed.observed_at_ns = 20e9
near(observed_row().power_age_ns, 0)
observed.observed_at_ns = nil
near(observed_row().power_age_ns, 0) -- older native providers use collector timestamps
observed.observed_at_ns = 21e9
assert(observed_row().power_age_ns == nil and observed_row().state == "unknown")
assert(observed_row().power_percent == nil)
observed.observed_at_ns = 1e9
near(observed_row().power_age_ns, 19e9)
assert(observed_row().state == "stale" and observed_row().power_percent == nil)
observed_snapshot.timestamp_ns = 9007199254740994
observed.observed_at_ns = 9007199254740993
assert(observed_row().power_age_ns == 1, "float conversion corrupted a long-uptime age")
for _, bad in ipairs({ -1, math.huge, 0/0 }) do
    observed.observed_at_ns = bad
    assert(observed_row().power_age_ns == nil and observed_row().state == "unknown")
end
observed_snapshot.timestamp_ns, observed.observed_at_ns = 20e9, 19e9
observed.power_watts, observed.power_quality = nil, "denied"
observed.issues = {
    { field = "constraint.time_window", status = "error", source = "CAP-ONLY-PATH" },
    { field = "energy", status = "denied", source = observed.source .. "/energy_uj",
      reason = "RAW-ERROR-SHOULD-NOT-BE-A-LABEL" },
    { field = "power", status = "error", source = observed.source .. "/power_uw" },
}
local denied_row = observed_row()
assert(denied_row.power_age_ns == nil and denied_row.power_percent == nil)
assert(#denied_row.power_reading_issues == 2 and denied_row.power_reading_issues[1] ~= observed.issues[2])
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR",
    "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
    local tr = assert(I18n.new({ locale = locale }))
    local lines = table.concat(TUI.power_detail_lines(observed_snapshot, tr), "\n")
    assert(lines:find(tr:t("inspector.reason") .. ": " .. tr:t("metrics.energy")
        .. ": " .. tr:t("status.denied"), 1, true), locale)
    assert(lines:find(observed.source .. "/energy_uj", 1, true), locale)
    assert(not lines:find("RAW-ERROR-SHOULD-NOT-BE-A-LABEL", 1, true))
    assert(not lines:find("CAP-ONLY-PATH", 1, true))
    assert(not lines:find(tr:t("systemd.sample_age") .. ":", 1, true), locale)
    observed.power_watts, observed.power_quality = 0, "measured"
    local measured_lines = table.concat(TUI.power_detail_lines(observed_snapshot, tr), "\n")
    assert(measured_lines:find(tr:t("systemd.sample_age") .. ":", 1, true), locale)
    observed.power_watts, observed.power_quality = nil, "denied"
end
observed.issues = {}
for index = 1, 20 do
    observed.issues[index] = { field = "energy", status = "denied", source = "READ-" .. index .. "-PATH" }
end
assert(#observed_row().power_reading_issues == 8)
local bounded_detail = table.concat(TUI.power_detail_lines(observed_snapshot, en), "\n")
assert(bounded_detail:find("READ-8-PATH", 1, true) and not bounded_detail:find("READ-9-PATH", 1, true))
assert(select(2, bounded_detail:gsub("READ%-8%-PATH", "")) == 1, "each cap repeated its domain's diagnostics")

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

-- A retained SDK reading cannot hide a current hwmon measurement on the same
-- live DRM device, or lend its stale cap/window to that sensor reading.
local mixed_power={timestamp_ns=2000000000,
  quality={gpus={status="ok",quality="partial"},sensors={status="ok",quality="fresh"}},
  gpus={devices={{id="card0",identity_quality="fresh",hwmon_refs={{class="hwmon0"}},
    metrics={power_watts=30,power_source="nvml",power_limit_watts=40,power_limit_source="nvml",
      power_measurement="average",power_interval_ns=1000000000},quality={power="stale"},
    metric_observations={power_watts={quality="stale",retained=true,observed_at_ns=1000000000},
      power_limit_watts={quality="stale",retained=true,observed_at_ns=1000000000}}}}},
  sensors={devices={{class="hwmon0",channels={{type="power",input=15,quality="fresh",
    source="/sys/class/hwmon/hwmon0/power1_input",thresholds={cap=20}}}}}}}
local function mixed_row()
  return ViewModel.build(engine,mixed_power,en,{},"gpu").gpu_table.rows[1]
end
local measured=mixed_row()
assert(measured.power=="15.0 W" and measured.power_limit=="20.0 W")
near(measured.power_percent,75)
assert(measured.power_budget_source=="/sys/class/hwmon/hwmon0/power1_input")
assert(measured.power_measurement==nil and measured.power_interval_ns==nil and measured.power_age_ns==nil)
mixed_power.sensors.devices[1].channels[1].thresholds.cap=nil
assert(mixed_row().power_percent==nil,"a current hwmon wattage borrowed a stale SDK cap")
mixed_power.sensors.devices[1].channels[1].thresholds.cap=20
mixed_power.quality.sensors.quality="stale"
assert(mixed_row().power:find("30.0 W",1,true) and mixed_row().power_percent==nil)
mixed_power.quality.sensors.quality="fresh"
mixed_power.sensors.devices[1].channels[1].quality="stale"
assert(mixed_row().power:find("30.0 W",1,true))
mixed_power.sensors.devices[1].channels[1].quality="fresh"
mixed_power.gpus.devices[1].identity_quality="stale"
assert(mixed_row().power:find("30.0 W",1,true),"an old GPU identity joined a current sensor")
mixed_power.gpus.devices[1].metrics.power_watts=nil
assert(mixed_row().power=="—" and #ViewModel.gpu_sensor_join(mixed_power)==0)
mixed_power.gpus.devices[1].metrics.power_watts=30
mixed_power.gpus.devices[1].identity_quality="fresh"
mixed_power.quality.gpus.quality="stale"
assert(mixed_row().power:find("30.0 W",1,true),"an old inventory joined a current sensor")
mixed_power.quality.gpus.quality="partial"
mixed_power.gpus.devices[1].quality.power="fresh"
mixed_power.gpus.devices[1].metric_observations.power_watts.quality="fresh"
mixed_power.gpus.devices[1].metric_observations.power_limit_watts.quality="fresh"
mixed_power.gpus.devices[1].metric_observations.power_watts.retained=false
mixed_power.gpus.devices[1].metric_observations.power_limit_watts.retained=false
assert(mixed_row().power=="30.0 W");near(mixed_row().power_percent,75)

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

-- Overview shows each controller's own numerator, not the aggregate headline.
local Metric=require("wtop.ui.widgets.metric")
local Budget=require("wtop.ui.widgets.power_budget")
local function overview(value,translator)
 return ViewModel.build(engine,value,translator or en,{},"overview").power_overview
end
local budgets,total=Power.cpu_budgets(snap.power,nil)
assert(#budgets==6 and total==6)
assert(budgets[1].constraint_name=="long_term"and budgets[2].constraint_name=="long_term")
for _,b in ipairs(budgets)do
 if b.zone_id==mmio.id and b.constraint_name=="long_term"then near(b.comparison.percent,97.6)end
end
local small,count=Power.cpu_budgets(snap.power,nil,1);assert(#small==1 and count==6)
local child=zone("intel-rapl:0:0","intel-rapl",1);child.parent_id=msr.id
local platform=zone("intel-rapl:1","intel-rapl",100);platform.aggregate_domain="platform"
snap.power.zones={mmio,msr,child,platform};assert(#Power.cpu_budgets(snap.power,nil)==6)
snap.power.zones={mmio,msr}
local function frame(model,width,height,variant,context)
 local grid=Grid.new(width,height)
 context=context or{panel_title=true,capabilities={unicode=false}}
 Metric.render(grid,{x=1,y=1,width=width,height=height},model,context,variant)
 local lines={};for row=1,height do lines[row]=grid:row_text(row)end
 return table.concat(lines,"\n")
end
local m=overview(snap);m.history={n=3,18,19,19.52}
local screen=frame(m,80,24,"full")
assert(screen:find("97.6%",1,true)and screen:find("75.1%",1,true))
assert(screen:find("19.52 W / 20 W",1,true)and screen:find("0.48 W",1,true))
assert(screen:find("intel-rapl:0",1,true)and screen:find("intel-rapl-mmio:0",1,true))
local dense=frame(m,36,9,"full");assert(dense:find("97.6%",1,true)and dense:find("+",1,true))
for _,variant in ipairs({"value","compact","spark","full"})do
 for _,width in ipairs({8,12,20,24,36,40,60,80,120})do
  for _,height in ipairs({1,2,3,4,6,8,12,20,28})do
   local text=frame(m,width,height,variant)
   assert(text:find("+",1,true)or text:find("97.6%",1,true),variant.." omitted budgets without notice")
  end
 end
end
mmio.power_watts=30;m=overview(snap);screen=frame(m,80,24,"full")
assert(screen:find("150%",1,true)and screen:find("-10 W",1,true))
mmio.power_watts=0;m=overview(snap);screen=frame(m,80,24,"full");assert(screen:find("[--------] 0%",1,true))
mmio.power_watts=19.52
for _,state in ipairs({"stale","denied","reset","gap","error","unavailable"})do
 snap.quality={power={status="error",quality=state}}
 m=overview(snap);assert(m.budgets.total==6)
 for _,b in ipairs(m.budgets.rows)do assert(b.comparison==nil)end
 screen=frame(m,80,24,"full");assert(not screen:find("%",1,true),state)
end
snap.quality=nil
mmio.controls_enabled=false
assert(model(snap).rows[4].controls=="disabled"and model(snap).rows[4].usage=="—")
m=overview(snap);screen=frame(m,80,24,"full");assert(screen:find("Disabled",1,true))
for _,b in ipairs(m.budgets.rows)do if b.zone_id==mmio.id then assert(not b.comparison)end end
mmio.controls_enabled=true
for _,locale in ipairs({"en-US","zh-CN","zh-TW","fr-FR","de-DE","es-ES","pt-BR","ja-JP","ko-KR","ru-RU"})do
 local translator=assert(I18n.new({locale=locale}));local value=overview(snap,translator)
 for _,width in ipairs({8,12,20,24,36,40,60,80,120})do
  for _,height in ipairs({1,2,3,4,6,8,12,20,28})do
   local grid=Grid.new(width,height);local report=Budget.render(grid,{x=1,y=1,width=width,height=height},value.budgets,{i18n=translator,capabilities={unicode=false}})
   local lines={};for y=1,height do lines[y]=grid:row_text(y)end;local text=table.concat(lines,"\n")
   assert(report.visible+report.hidden==6)
   if report.hidden>0 then assert(text:find("+"..report.hidden,1,true),locale)end
   for i=1,report.visible do
    local b=value.budgets.rows[i]
    assert(text:find(b.reading,1,true)or text:find(b.reading_compact,1,true),locale.." cut numeric row")
   end
  end
 end
end
-- Hidden and process-only views do not build the overview budget model.
assert(ViewModel.build(engine,snap,en,{},"overview",nil,{power_overview=false}).power_overview.budgets==nil)
assert(ViewModel.build(engine,snap,en,{},"processes").power_overview==nil)
print("ok: overview independent CPU cap bars,quality,disabled controls,history,variants,whole values and omitted counts")

local narrow=overview(snap);narrow.history={n=3,18,19,19.52}
local narrow_screen=frame(narrow,15,8,"full")
assert(narrow_screen:find("MMIO 0",1,true)and narrow_screen:find("Sustained",1,true))
assert(narrow_screen:find("19.52/20W",1,true)and narrow_screen:find("97.6%",1,true))
assert(narrow_screen:find("Left:0.48W",1,true)and narrow_screen:find("+5",1,true))
