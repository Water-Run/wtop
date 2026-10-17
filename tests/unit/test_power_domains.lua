local Domains = require("wtop.model.power_domains")
local Powercap = require("wtop.collectors.powercap")
local Power = require("wtop.model.power")
local Export = require("wtop.export")
local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")
local root = { id = "intel-rapl:0", name = "package-0", source_kind = "intel-rapl" }
local child = { id = "intel-rapl:0:1", name = "uncore", parent_id = root.id, source_kind = "intel-rapl",
    power_watts = .04, power_quality = "measured", quality = "fresh", observed_at_ns = 1000000000,
    controls_enabled = false }
local ids = Domains.identities({ root, child })
assert(Domains.kind(root, ids) == "cpu_package" and Domains.kind(child, ids) == "graphics")
child.name = "core";assert(Domains.kind(child, ids) == "cpu_cores")
child.name = "dram";assert(Domains.kind(child, ids) == "memory")
child.name = "Uncore";assert(Domains.kind(child, ids) == nil)
child.name = "uncore"
local snapshot = { timestamp_ns = 1000000000, power = { zones = { root, child } },
    quality = { power = { status = "ok", quality = "fresh" } } }
local rows = Domains.graphics(snapshot)
assert(#rows == 1 and rows[1].watts == .04 and rows[1].scope == "rapl_graphics_domain")
assert(rows[1].pci_device_known == false and rows[1].controls_enabled == false,
    "readable graphics energy does not imply enabled controls or a PCI association")
assert(Power.zone(child, { power_limit_watts = 20 }, "fresh") == nil)
local public = Export.snapshot(snapshot)
assert(public.power.graphics_domains[1].power_watts == .04)
assert(public.power.graphics_domains[1].pci_device_known == false)
assert(public.power.zones[2].domain_kind == "graphics")
assert(Export.agent(snapshot).metrics.power.graphics_domains[1].scope == "rapl_graphics_domain")
assert(require("wtop.report").render(public):find("RAPL graphics domains", 1, true))
snapshot.gpus = { devices = { { id = "gpu0", card = "card0", metrics = {
    utilization_percent = 10, power_watts = 50, power_source = "nvml",
    power_limit_watts = 100, power_limit_source = "nvml" } } } }
snapshot.quality.gpus = { status = "ok", quality = "fresh" }
local engine = { history_values = function() return {} end }
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "de-DE", "fr-FR", "es-ES", "pt-BR", "ru-RU" }) do
    local tr = assert(I18n.new({ locale = locale }))
    local model = ViewModel.build(engine, snapshot, tr, {}, "gpu")
    assert(model.gpu_summary.secondary_value:find(tr:t("power.rapl_graphics"), 1, true))
    assert(model.gpu_summary.secondary_values[1]:find(tr.format:number(.04, { precision = 2 }) .. " W", 1, true))
end
assert(Export.agent(snapshot).top.gpus[1].metrics.power_watts == 50,
    "graphics-domain power was assigned to a vendor's card reading")
local mirror_root = { id = "intel-rapl-mmio:0", name = "package-0", source_kind = "intel-rapl-mmio" }
local mirror = { id = "intel-rapl-mmio:0:1", parent_id = mirror_root.id, name = "uncore", source_kind = "intel-rapl-mmio",
    power_watts = .04, power_quality = "measured", quality = "fresh", observed_at_ns = 1000000000 }
snapshot.power.zones = { root, child, mirror_root, mirror }
assert(#Domains.graphics(snapshot) == 2, "parallel backends were guessed to be a unique card or summed")
local tr = assert(I18n.new({ locale = "en-US" }))
local multiple = ViewModel.build(engine, snapshot, tr, {}, "gpu").gpu_summary.secondary_value
assert(multiple:find("2", 1, true) and not multiple:find("0.08", 1, true))
local limited = Export.agent(snapshot, { device_limit = 1 }).metrics.power
assert(#limited.graphics_domains == 1 and limited.graphics_domains_truncated)
snapshot.power.zones = { root, child }
snapshot.timestamp_ns = 18000000000
assert(Domains.graphics(snapshot)[1].watts == nil and Domains.graphics(snapshot)[1].quality == "stale")
snapshot.timestamp_ns = 500000000
assert(Domains.graphics(snapshot)[1].quality == "unknown")
snapshot.timestamp_ns = 1000000000
snapshot.quality.power.status = "error"
assert(Domains.graphics(snapshot)[1].watts == nil and Power.unusable(snapshot.quality.power))
snapshot.quality.power.status = "ok"
local fake = { id = "vendor:0:1", name = "uncore", source_kind = "vendor", parent_id = root.id }
assert(not Domains.kind(fake, Domains.identities({ root, fake })))
assert(not Domains.kind(child, Domains.identities({ root, child, child })))
local unrelated = { id = "intel-rapl:9:1", name = "uncore", source_kind = "intel-rapl", parent_id = root.id }
assert(not Domains.kind(unrelated, Domains.identities({ root, unrelated })))

local now, delay, package_energy, graphics_energy = 1000000000, 0, 1000000, 500000
local base = "/sys/class/powercap"
local files = {
    [base .. "/intel-rapl/enabled"] = "1",
    [base .. "/intel-rapl:0/name"] = "package-0", [base .. "/intel-rapl:0/enabled"] = "1",
    [base .. "/intel-rapl:0:1/name"] = "uncore", [base .. "/intel-rapl:0:1/enabled"] = "0",
    [base .. "/intel-rapl:0/max_energy_range_uj"] = "1000000000",
    [base .. "/intel-rapl:0:1/max_energy_range_uj"] = "1000000000",
    [base .. "/intel-rapl:0/constraint_0_name"] = "long_term",
    [base .. "/intel-rapl:0/constraint_0_power_limit_uw"] = "25000000",
    [base .. "/intel-rapl:0:1/constraint_0_name"] = "long_term",
    [base .. "/intel-rapl:0:1/constraint_0_power_limit_uw"] = "0",
}
local fs = {
    list = function(_, path)
        if path == base then return { "intel-rapl:0", "intel-rapl:0:1" } end
        return { "name", "enabled", "energy_uj", "max_energy_range_uj", "constraint_0_name", "constraint_0_power_limit_uw" }
    end,
    read = function(_, path)
        if path == base .. "/intel-rapl:0/energy_uj" then return tostring(package_energy) end
        if path == base .. "/intel-rapl:0:1/energy_uj" then return tostring(graphics_energy) end
        if path == base .. "/intel-rapl:0/constraint_0_name" then now = now + delay end
        return files[path], files[path] == nil and { kind = "missing" } or nil
    end,
}
local collector = Powercap.new({ fs = fs })
local context = { now_ns = function() return now end }
local first = collector:sample(context)
assert(first.data.by_id[root.id].power_quality == "gap")
now, package_energy, graphics_energy, delay = 3000000000, 21000000, 800000, 1000000000
local second = collector:sample(context, first)
local package, graphics = second.data.by_id[root.id], second.data.by_id[child.id]
assert(package.power_interval_ns == 2000000000 and graphics.power_interval_ns == 3000000000)
assert(math.abs(package.power_watts - 10) < 1e-9 and math.abs(graphics.power_watts - .1) < 1e-9)
assert(package.observed_at_ns == 3000000000 and graphics.observed_at_ns == 4000000000)
assert(graphics.domain_kind == "graphics" and graphics.controls_enabled == false and graphics.constraints[1].power_limit_watts == nil)
assert(second.data.total_power_watts == 10, "a child domain was added to package power")
now, package_energy, graphics_energy, delay = 6000000000, 51000000, 1300000, 20000000000
local late = collector:sample(context, second)
assert(late.data.by_id[root.id].power_quality == "stale" and late.data.total_power_watts == nil)
assert(late.quality == "partial" and late.data.by_id[child.id].observed_at_ns == 26000000000)
assert(late.data.by_id[root.id].energy_observed_at_ns == 6000000000,
    "batch completion renewed an earlier energy read")
local late_snapshot = { timestamp_ns = now, power = late.data,
    quality = { power = { status = "ok", quality = "partial", value_timestamp_ns = now } } }
local late_public = Export.snapshot(late_snapshot)
assert(late_public.power.zones[1].constraints[1].usage_percent == nil)
assert(late_public.power.zones[1].energy_observed_at_ns == 6000000000)
assert(late_public.power.graphics_domains[1].quality == "measured")
print("ok: RAPL driver roles, graphics scope, disabled controls, per-domain intervals and slow-batch age")
