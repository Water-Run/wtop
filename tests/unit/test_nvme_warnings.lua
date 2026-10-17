local Warnings = require("wtop.model.nvme_warnings")
local Parser = require("wtop.format.nvme_health")
local Export = require("wtop.export")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local function health(mask, id)
    local raw = string.char(mask) .. string.rep("\0", 511)
    return { id = id or "259:0", _health_key = "bound:" .. (id or "259:0"),
        quality = "fresh", observed_at_ns = 1000000000, nvme = assert(Parser.parse(raw)) }
end
local function snapshot(mask)
    return { timestamp_ns = 1000000000,
        disks = { devices = { { id = "259:0", name = "nvme0n1", _health_key = "bound:259:0" } } },
        disk_health = { devices = { health(mask) } },
        quality = { disk_health = { status = "ok", quality = "fresh", value_timestamp_ns = 1000000000 } } }
end
local function signal(document, code)
    for _, row in ipairs(document.signals) do if row.code == code then return row end end
end
local schema_file = assert(io.open("docs/agent-v1.schema.json", "rb"))
local schema = assert(require("wtop.core.json").decode(schema_file:read("a")))
schema_file:close()
local Validator = assert(loadfile("tools/agent_schema.lua"))()
for mask = 0, 255 do
    local decoded = assert(Warnings.decode(mask))
    assert(decoded.known_mask | decoded.unknown_mask == mask)
    assert(decoded.known_mask & decoded.unknown_mask == 0)
    local count = 0
    for bit = 0, 5 do if mask & (1 << bit) ~= 0 then count = count + 1 end end
    assert(#decoded.reasons == count)
end
for _, mask in ipairs({ -1, 256, .5, math.huge, 0/0, "1", true }) do assert(not Warnings.decode(mask)) end
local ids = { "spare_below_threshold", "temperature_threshold", "reliability_degraded",
    "media_read_only", "volatile_backup_failed", "persistent_memory" }
for bit = 0, 5 do
    local s = snapshot(1 << bit)
    assert(Warnings.summary(s).observations[1].reasons[1] == ids[bit + 1])
    local agent = Export.agent(s)
    assert(signal(agent, "nvme_critical_warning").severity == "critical")
    assert(agent.overall.state == "critical" and TUI.alert_count(s) == 1)
    local valid, errors = Validator.validate(agent, schema)
    assert(valid, errors and table.concat(errors, "\n"))
end
local unknown = snapshot(0x80)
assert(not signal(Export.agent(unknown), "nvme_critical_warning"))
assert(signal(Export.agent(unknown), "nvme_unknown_warning_bits").severity == "warning")
assert(TUI.alert_count(unknown) == 1)
local combined = snapshot(0xff)
assert(#Warnings.summary(combined).signals == 2 and TUI.alert_count(combined) == 2)
local quiet = snapshot(0)
quiet.disk_health.devices[1].nvme.percentage_used = 255
quiet.disk_health.devices[1].nvme.media_errors = "9999999999999999999999999999"
quiet.disk_health.devices[1].nvme.unsafe_shutdowns = "20"
assert(#Warnings.summary(quiet).signals == 0 and TUI.alert_count(quiet) == 0,
    "historical counters and life use are not current warning flags")
for _, quality in ipairs({ "stale", "denied", "error", "gap", "reset", "estimated", "held", "unavailable" }) do
    local s = snapshot(8)
    s.quality.disk_health.quality = quality
    assert(#Warnings.summary(s).signals == 0 and not signal(Export.agent(s), "nvme_critical_warning"), quality)
    s.quality.disk_health.quality = "fresh"
    s.disk_health.devices[1].quality = quality
    assert(#Warnings.summary(s).signals == 0 and TUI.alert_count(s) == 0, quality)
end
local stale = snapshot(8)
stale.timestamp_ns, stale.quality.disk_health.value_timestamp_ns = 21000000000, 21000000000
assert(#Warnings.summary(stale).signals == 0, "late batch renewed old warning")
stale.disk_health.devices[1].observed_at_ns = 22000000000
assert(#Warnings.summary(stale).signals == 0, "future observation is not current")
local missing = snapshot(8)
missing.timestamp_ns = nil
assert(#Warnings.summary(missing).signals == 0, "unknown capture time cannot prove current flags")
local changed = snapshot(8)
changed.disks.devices[1]._health_key = "replaced"
assert(#Warnings.summary(changed).signals == 0)
local duplicate = snapshot(8)
duplicate.disk_health.devices[2] = health(0)
assert(#Warnings.summary(duplicate).signals == 0 and Warnings.summary(duplicate).partial)
duplicate = snapshot(8)
duplicate.disks.devices[2] = duplicate.disks.devices[1]
assert(#Warnings.summary(duplicate).signals == 0)
local many = snapshot(8)
for id = 1, 20 do
    local key = "259:" .. id
    many.disks.devices[#many.disks.devices + 1] = { id = key, _health_key = "bound:" .. key }
    many.disk_health.devices[#many.disk_health.devices + 1] = health(8, key)
end
assert(#Warnings.summary(many).signals == 1, "namespaces are not an inferred failing-controller count")
assert(signal(Export.agent(many, { device_limit = 1 }), "nvme_critical_warning"),
    "warning must not depend on the I/O top-list limit")
local s = snapshot(0x3f)
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "de-DE", "fr-FR", "es-ES", "pt-BR", "ru-RU" }) do
    local i18n = assert(I18n.new({ locale = locale }))
    local lines = table.concat(TUI.nvme_warning_lines(s, i18n), "\n")
    assert(lines:find("nvme0n1", 1, true))
    for _, id in ipairs(ids) do assert(lines:find(i18n:t("nvme.warning." .. id), 1, true), locale .. id) end
    assert(table.concat(TUI.nvme_warning_lines(quiet, i18n), "\n"):find(i18n:t("nvme.warning.none"), 1, true))
    assert(not table.concat(TUI.nvme_warning_lines(stale, i18n), "\n"):find(i18n:t("nvme.warning.none"), 1, true))
end
print("ok: current NVMe warning bits, reserved flags, identity/age, deduped signals and localized UI")
