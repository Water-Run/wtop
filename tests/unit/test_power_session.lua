package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Session = require("wtop.model.power_session")
local Powercap = require("wtop.collectors.powercap")
local Portable = require("wtop.collectors.portable")
local Export = require("wtop.export")
local Report = require("wtop.report")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Common = require("wtop.collectors.common")
local function near(a, b) assert(type(a) == "number" and math.abs(a - b) < 1e-8, tostring(a) .. " != " .. b) end
local function zone(watts, at, interval)
    return { id = "intel-rapl:0", name = "package-0", source_kind = "intel-rapl",
        source = "/sys/class/powercap/intel-rapl:0", observed_at_ns = at * 1e9,
        power_watts = watts, power_quality = "measured", quality = "fresh",
        power_source = interval and "energy_delta" or "power_uw", power_interval_ns = interval and interval * 1e9 }
end
local function step(z, prior, now)
    local data = { zones = { z } }; Session.attach(data.zones, prior, (now or z.observed_at_ns / 1e9) * 1e9)
    return data, z.power_session
end
local first, stats = step(zone(10, 2, 1))
assert(stats.samples == 1 and stats.average_kind == "time_weighted")
local second; second, stats = step(zone(20, 5, 3), first)
near(stats.average_watts, 17.5); near(stats.energy_joules, 70); near(stats.covered_time_ns, 4e9)
near(stats.minimum_watts, 10); near(stats.maximum_watts, 20); assert(stats.samples == 2)
assert(first.zones[1].power_session.samples == 1, "a later observation mutated an earlier snapshot")
local replay; replay, stats = step(zone(20, 5, 3), second)
assert(stats.samples == 2, "a replayed window was counted twice")
local overlap; overlap, stats = step(zone(50, 6, 2), replay)
assert(stats.samples == 2 and stats.last_timestamp_ns == 5e9, "overlapping energy was double-counted")
local missing = zone(nil, 7); missing.power_quality, missing.power_source = "denied", nil
local denied; denied, stats = step(missing, overlap)
assert(stats.samples == 2 and stats.last_timestamp_ns == 5e9)
local recovered; recovered, stats = step(zone(0, 9, 1), denied)
near(stats.average_watts, 14); near(stats.energy_joules, 70); near(stats.covered_time_ns, 5e9)
assert(stats.samples == 3 and stats.first_timestamp_ns == 1e9, "a gap was filled with zero or lost the recorded range")
local stale; stale, stats = step(zone(100, 10, 1), recovered, 30)
assert(stats.samples == 3 and stats.last_timestamp_ns == 9e9, "an old observation became a new sample")
local reset = zone(nil, 31, 1); reset.power_quality = "reset"
local cleared = step(reset, stale); assert(cleared.zones[1].power_session == nil)
local after_reset; after_reset, stats = step(zone(5, 32, 1), cleared)
assert(stats.samples == 1 and stats.minimum_watts == 5)
for _, field in ipairs({ "name", "source", "source_kind", "parent_id", "_source_epoch", "maximum_energy_range_joules" }) do
    local changed = zone(30, 10, 1); changed[field] = "changed"
    local _, current = step(changed, recovered); assert(current.samples == 1, field)
end
local direct, point = step(zone(10, 1))
local direct2; direct2, point = step(zone(30, 11), direct)
assert(point.average_kind == "samples" and point.samples == 2)
near(point.average_watts, 20); assert(point.covered_time_ns == nil and point.energy_joules == nil)
local _, changed = step(zone(40, 12, 1), direct2); assert(changed.samples == 1, "point and window statistics were mixed")
local duplicates = { zones = { zone(10, 2, 1), zone(20, 2, 1) } }
Session.attach(duplicates.zones, first, 2e9)
assert(not duplicates.zones[1].power_session and not duplicates.zones[2].power_session)
local _, unique = step(zone(30, 3, 1), duplicates); assert(unique.samples == 1)
for _, q in ipairs({ "stale", "held", "gap", "denied", "error", "unknown", "estimated" }) do
    local z = zone(999, 10, 1); z.power_quality = q
    local _, held = step(z, recovered); assert(held.samples == 3 and held.maximum_watts == 20, q)
end
local future = step(zone(999, 40, 1), recovered, 39)
assert(future.zones[1].power_session.samples == 3)
local _, backwards = step(zone(4, 2, 1), recovered, 2); assert(backwards.samples == 1)
-- More than 104 days of nanoseconds: absolute-clock float conversion used to
-- turn a 1000000001ns gap into 1000000002ns and discard the second window.
local large_start = 9007199254740993
local large_middle, large_end = large_start + 1000000000, large_start + 2000000001
assert(Common.elapsed_ns(large_end, large_middle) == 1000000001)
assert(Common.elapsed_ns(math.maxinteger, math.maxinteger - 5) == 5)
local function large_zone(at, before)
    local z = zone(10, 1, 1)
    z.observed_at_ns, z.power_interval_ns = at, Common.elapsed_ns(at, before)
    return z
end
local large_first = { zones = { large_zone(large_middle, large_start) } }
Session.attach(large_first.zones, nil, large_middle)
local large_second = { zones = { large_zone(large_end, large_middle) } }
Session.attach(large_second.zones, large_first, large_end)
assert(large_second.zones[1].power_session.samples == 2, "long-uptime windows were mistaken for overlap")
assert(large_second.zones[1].power_session.first_timestamp_ns == large_start)
assert(large_second.zones[1].power_session.covered_time_ns == 2000000001)
local reused = { zones = { zone(10, 2, 1) } }; Session.attach(reused.zones, nil, 2e9)
Session.attach(reused.zones, reused, 2e9); assert(reused.zones[1].power_session.samples == 1)

-- Real collector state, including a nonuniform interval and a wrapped counter.
local now, energy = 1e9, 1000000
local base = "/sys/class/powercap"
local fs = { list = function(_, path) return path == base and { "intel-rapl:0" } or { "name", "energy_uj", "max_energy_range_uj" } end,
    read = function(_, path)
        if path == base .. "/intel-rapl:0/name" then return "package-0" end
        if path == base .. "/intel-rapl:0/energy_uj" then return tostring(energy) end
        if path == base .. "/intel-rapl:0/max_energy_range_uj" then return "1000000000" end
        return nil, { kind = "missing" }
    end }
local collector = Powercap.new({ fs = fs }); local context = { now_ns = function() return now end }
local baseline = collector:sample(context); assert(not baseline.data.zones[1].power_session)
now, energy = 2e9, 11000000
local measured = collector:sample(context, baseline)
now, energy = 5e9, 71000000
local weighted = collector:sample(context, measured); near(weighted.data.zones[1].power_session.average_watts, 17.5)
now, energy = 6e9, 950000000
local before_wrap = collector:sample(context, weighted)
now, energy = 7e9, 50000000
local wrapped = collector:sample(context, before_wrap)
assert(wrapped.data.zones[1].power_quality == "wrapped" and wrapped.data.zones[1].power_session.samples == 4)

-- Native energy epochs and direct SMC-style observations share the model.
local native_value, epoch = 0, "epoch1"
local native = { collect_powercap = function() return { zones = {
    { id = "cpu", name = "CPU", source = "ioreport", source_kind = "package", _source_epoch = epoch,
        _sample_timestamp_ns = now, energy_joules = native_value, aggregate = true },
    { id = "system", name = "System", source = "smc", power_source = "smc:PSTR", power_watts = 7.5 },
} } end }
local portable = Portable.new("powercap", { native = native })
now = 1e9; local native_first = portable:sample(context)
assert(native_first.data.zones[2].power_session.samples == 1)
now, native_value = 3e9, 10; local native_second = portable:sample(context, native_first)
near(native_second.data.zones[1].power_session.average_watts, 5)
assert(native_second.data.zones[1].observed_at_ns == 3e9)
now, native_value, epoch = 4e9, 100, "epoch2"
local native_reopen = portable:sample(context, native_second)
assert(not native_reopen.data.zones[1].power_session, "an IOReport reopen kept the previous session")

local snapshot = { timestamp_ns = 9e9, power = recovered, quality = { power = { status = "ok", quality = "fresh" } } }
local public = Export.snapshot(snapshot); near(public.power.zones[1].power_session.average_watts, 14)
assert(public.power.zones[1].power_session._power_source == nil)
local agent = Export.agent(snapshot); near(agent.metrics.power.zones[1].power_session.energy_joules, 70)
assert(Report.render(public):find("Power session statistics", 1, true))
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
    local tr = assert(I18n.new({ locale = locale }))
    local lines = table.concat(TUI.power_detail_lines(snapshot, tr), "\n")
    assert(lines:find(tr:t("power.session_weighted"), 1, true), locale)
    assert(lines:find(tr:t("power.session_samples"), 1, true), locale)
    assert(not lines:find("power.session_", 1, true), locale)
end
for _, key in ipairs({ "samples", "minimum_watts", "average_watts", "covered_time_ns", "energy_joules" }) do
    local bad = {}; for k, v in pairs(recovered.zones[1].power_session) do bad[k] = v end
    bad[key] = math.huge
    assert(Session.public({ power_session = bad }, 9e9) == nil, key)
end
assert(Session.public(recovered.zones[1], 1e9) == nil, "future statistics were exported")
print("ok: power-domain sessions, weighted coverage, gaps, replay, identity, native epochs and all consumer paths")
