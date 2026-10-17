local Collector = require("wtop.collectors.linux_nvme")
local Identity = require("wtop.linux.nvme_identity")
local Parser = require("wtop.format.nvme_health")
local Export = require("wtop.export")
local Inspector = require("wtop.inspectors.linux_storage")

for _, name in ipairs({ "nvme0n1", "nvme15n4294967295" }) do assert(Identity.name(name)) end
for _, name in ipairs({ "nvme0", "nvme00n1", "nvme0n01", "nvme0n0", "nvme0n1p1",
    "nvme0c0n1", "../nvme0n1", "nvme4294967296n1", "nvme0n4294967296", "nvme0n1\0" }) do
    assert(not Identity.name(name), name)
end
assert(not Identity.key("nvme0n1", 259, 0, 0))
assert(not Identity.key("nvme0n1", 259, 0, nil))

local bytes = string.char(0, 0x28, 1, 100, 10, 255) .. string.rep("\0", 26)
    .. string.rep("\255", 16) .. string.rep("\0", 464)
local decoded = assert(Parser.parse(bytes))
assert(decoded.data_units_read == "340282366920938463463374607431768211455")
assert(decoded.percentage_used_lower_bound and decoded.percentage_used == 255)
assert(decoded.data_unit_bytes == 512000 and decoded.data_units_rounded_up)
assert(require("wtop.format.windows_storage").nvme == Parser.parse)

local sequence, reads = 7, 0
local fs = {
    list = function() return { "sda", "nvme0n1", "nvme0n1p1", "loop0" } end,
    read = function(_, path)
        if path == "/sys/block/nvme0n1/dev" then return "259:0\n" end
        if path == "/sys/block/nvme0n1/diskseq" then return tostring(sequence) end
        return nil, { kind = "missing" }
    end,
}
local collector = Collector.new({ fs = fs, reader = function(name, major, minor, seq)
    assert(name == "nvme0n1" and major == 259 and minor == 0 and seq == sequence)
    reads = reads + 1
    return bytes
end })
local context = { now_ns = function() return 1000000000 end }
assert(collector:probe(context).available and reads == 0, "probe opened the device")
local result = collector:sample(context)
assert(result.status == "ok" and result.quality == "fresh" and reads == 1)
local health = assert(result.data.devices[1])
assert(health.nvme.scope == "controller" and health.scope == "controller")
assert(math.abs(health.temperature.channels[1].input - 22.85) < 1e-8)
local disk = { id = "259:0", name = "nvme0n1", _health_key = health._health_key }
local snapshot = { timestamp_ns = 1000000000, disks = { devices = { disk } },
    disk_health = result.data, quality = { disk_health = { status = "ok", quality = "fresh",
        value_timestamp_ns = 1000000000 } } }
local public = Export.snapshot(snapshot)
assert(public.disk_health.devices[1].nvme.data_units_read == decoded.data_units_read)
assert(public.disk_health.devices[1].nvme.scope == "controller")
assert(public.disk_health.devices[1]._health_key == nil)
assert(Export.agent(snapshot).top.disks[1].nvme_health.data_units_read == decoded.data_units_read)
assert(Export.agent(snapshot).top.disks[1].nvme_health.scope == "controller")
disk._health_key = "changed"
assert(#Export.snapshot(snapshot).disk_health.devices == 0)
disk._health_key = health._health_key

local fallback_calls = 0
local fallback = { enumerate = function() return { { id = "/dev/nvme0n1", name = "nvme0n1" },
    { id = "/dev/sda", name = "sda" } } end,
    probe = function() return { available = true } end,
    inspect = function() fallback_calls = fallback_calls + 1; return "fallback" end }
local inspector = Inspector.new({ fallback = fallback, native = { read_nvme_health = function() end } })
context.snapshot = snapshot
local entities = inspector:enumerate(context)
local entity
for _, row in ipairs(entities) do if row.name == "nvme0n1" then entity = row end end
local details = inspector:inspect(context, entity)
assert(details.status == "ok" and details.sections[1].fields.percentage_used.value == 255)
assert(inspector:inspect(context, { id = "/dev/sda" }) == "fallback" and fallback_calls == 1)
snapshot.quality.disk_health.quality = "stale"
assert(inspector:inspect(context, entity).quality == "stale")
snapshot.quality.disk_health.quality = "fresh"
disk._health_key = "changed"
assert(inspector:inspect(context, entity).reason == "storage_identity_changed")
disk._health_key = health._health_key

collector.reader = function() return nil, "denied", 13 end
result = collector:sample(context)
assert(result.quality == "partial" and result.data.devices[1].quality == "denied")
assert(not result.data.devices[1].nvme)
collector.reader = function() return nil, "descriptor identity changed", 116 end
result = collector:sample(context)
assert(result.data.devices[1].quality == "gap" and not result.data.devices[1].nvme)
snapshot.disk_health = result.data
assert(inspector:inspect(context, entity).quality == "gap", "identity error used the external fallback")
snapshot.disk_health = { devices = { health } }
collector.reader = function() return nil, "NVMe completion", 0, 0x102 end
result = collector:sample(context)
assert(result.data.devices[1].query_errors.nvme_status == 0x102)
snapshot.disk_health = result.data
assert(inspector:inspect(context, entity) == "fallback", "unsupported native query lost smartctl fallback")
snapshot.disk_health = { devices = { health } }
collector.reader = function() sequence = 8; return bytes end
result = collector:sample(context)
assert(result.data.devices[1].quality == "gap" and not result.data.devices[1].nvme)
collector.reader = function() error("safe mode performed device I/O") end
assert(collector:sample({ safe_mode = true, now_ns = context.now_ns }).status == "unavailable")

local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "de-DE", "fr-FR", "es-ES", "pt-BR", "ru-RU" }) do
    local i18n = assert(I18n.new({ locale = locale }))
    local text = table.concat(TUI.inspector_lines("NVMe", details, i18n), "\n")
    assert(text:find(i18n:t("nvme.health_title"), 1, true), locale)
    assert(text:find(i18n:t("nvme.health_percentage_used"), 1, true), locale)
    assert(not text:find("data_units_read", 1, true), "native key leaked into health UI: " .. locale)
    assert(text:find(decoded.data_units_read, 1, true), "128-bit counter cut: " .. locale)
    assert(text:find(i18n:t("nvme.health_scope"), 1, true)
        < text:find(i18n:t("nvme.health_data_units_read"), 1, true),
        "scope hidden below accumulated counters: " .. locale)
end
local native = require("wtop.native")
if type(native.read_nvme_health) == "function" then
    for _, name in ipairs({ "nvme0", "nvme00n1", "nvme0n0", "nvme0n1p1", "../nvme0n1",
        "nvme" .. string.rep("9", 100) .. "n1", "nvme4294967296n1", "nvme0n4294967296", "nvme0n1\0" }) do
        assert(not pcall(native.read_nvme_health, name, 259, 0, 7), name)
    end
    assert(not pcall(native.read_nvme_health, "nvme0n1", -1, 0, 7))
    assert(not pcall(native.read_nvme_health, "nvme0n1", 259, 0, 0))
end

print("ok: Linux native NVMe identity, fixed controller scope, lossless counters, health export and live inspector")
