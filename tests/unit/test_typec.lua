package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tools/?.lua;" .. package.path
local Fixture = require("support.typec")
local FS = require("support.fixture_fs")
local Collector = require("wtop.collectors.typec")
local PD = require("wtop.format.usb_pd")
local Public = require("wtop.model.typec")
local Snapshot = require("wtop.model.snapshot")
local Export = require("wtop.export")
local Hardware = require("wtop.model.hardware")
local now = 1000000000
local context = { now_ns = function() return now end }
local function sample(data, custom)
  local fs = custom or FS.new(data); local read = fs.read
  function fs:read(path, ...)
    assert(not path:find("/identity/", 1, true), "identity VDO must not be read")
    return read(self, path, ...)
  end
  function fs:write() error("role swaps and PD selection are not monitoring") end
  local result = Collector.new({ fs = fs }):sample(context)
  return result, Snapshot.merge(nil, { typec = result }, 1, now)
end
local data = Fixture.new(); local result, snapshot = sample(data)
assert(result.status == "ok" and result.quality == "fresh")
local port, pd = result.data.ports[1], result.data.pd_devices[1]
assert(port.id == "port0" and port.pd_id == "pd7" and pd.id == "pd7")
assert(port.data_role == "host" and port.power_role == "source" and port.usb_default_mode == "usb4")
assert(port.partner_observed and port.cable_observed and port.partner.usb_mode == "usb3")
assert(port.vconn_source and port.usb_power_delivery_revision == "3.1")
assert(#pd.profiles == 10 and pd.capability_status.source == "available")
assert(pd.profiles[1].voltage_volts == 5 and pd.profiles[1].maximum_current_amperes == 3)
assert(pd.profiles[1].unconstrained_power == false and pd.profiles[1].peak_current_code == 2)
assert(pd.profiles[3].maximum_power_watts == 45)
assert(pd.profiles[4].minimum_voltage_volts == 3.3 and pd.profiles[4].maximum_voltage_volts == 21)
assert(pd.profiles[5].maximum_current_9V_to_15V_amperes == 5)
assert(pd.profiles[6].operational_current_amperes == 1 and pd.profiles[6].fast_role_swap_current_code == 2)
assert(pd.profiles[8].operational_power_watts == 45)
local full, agent = Export.snapshot(snapshot), Export.agent(snapshot)
assert(#full.typec.ports == 1 and #full.typec.pd_devices[1].profiles == 10)
assert(#agent.metrics.power.pd_devices[1].profiles == 8 and agent.metrics.power.pd_devices[1].truncated)
assert(agent.metrics.power.typec_ports[1].pd_id == "pd7")
local schema_file = assert(io.open("docs/agent-v1.schema.json", "rb"))
local schema = assert(require("wtop.core.json").decode(schema_file:read("a"))); schema_file:close()
local validate = require("agent_schema").validate
assert(#validate(agent, schema) == 0)
local bad = Export.agent(snapshot); bad.metrics.power.pd_devices[1].declarations_only = false
assert(#validate(bad, schema) > 0)
bad = Export.agent(snapshot); bad.metrics.power.pd_devices[1].profiles[1].voltage_volts = -1
assert(#validate(bad, schema) > 0)
assert(agent.metrics.power.total_watts == nil and agent.metrics.power.platform_watts == nil and agent.overall.signal_count == 0)
for _, profile in ipairs(full.typec.pd_devices[1].profiles) do
  assert(profile.declarations_only and profile.power_watts == nil and profile.usage_percent == nil)
end
local graph = Hardware.build(snapshot)
local related = Hardware.related(graph, "typec:port0")
assert(related.total == 1 and related.items[1].id == "usb-pd:pd7")
assert(Hardware.related(graph, "usb-pd:pd7").items[1].id == "typec:port0")
assert(graph.by_id["usb-pd:pd7"].parent_id == nil, "association is not physical containment")
local TUI, I18n, Report = require("wtop.tui"), require("wtop.i18n"), require("wtop.report")
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
  local tr = assert(I18n.new({ locale = locale }))
  local lines = table.concat(TUI.hardware_detail_lines(snapshot, "typec:port0", tr, now), "\n")
  assert(lines:find(tr:t("typec.note"), 1, true) and lines:find("pd7", 1, true), locale)
  local pd_lines = table.concat(TUI.hardware_detail_lines(snapshot, "usb-pd:pd7", tr, now), "\n")
  assert(pd_lines:find(tr:t("typec.pdo_note"), 1, true) and pd_lines:find("spr_adjustable_voltage_supply", 1, true), locale)
end
local report = Report.render(full)
assert(report:find("USB Type-C ports", 1, true) and report:find("USB PD declared profiles", 1, true))
assert(report:find("45.00 W", 1, true) and report:find("no selected contract", 1, true))
pd.private_serial, port.private_serial = "PRIVATE-SERIAL", "PRIVATE-SERIAL"
assert(not require("wtop.format.json").encode(Export.snapshot(snapshot)):find("PRIVATE", 1, true))
print("Type-C/PD: readonly roles, explicit canonical association, five source/sink PDO kinds, milli units, flags and declaration-only outputs")

for _, invalid in ipairs({ "-1mV", "1.5V", "5000uV", "nan", "2147483648mV", string.rep("0", 129) }) do
  assert(PD.parse("voltage", invalid) == nil)
end
assert(PD.parse("voltage", "5000") == 5 and PD.parse("maximum_current", "3000mA") == 3)
assert(PD.parse("dual_role_power", "2") == nil and PD.parse("peak_current", "4") == nil)
for _, change in ipairs({ "unknown", "denied", "bad_unit", "bad_range" }) do
  local f = Fixture.new(); local path = f.pd .. "/source-capabilities/1:fixed_supply/voltage"
  if change == "unknown" then
    f.files[f.pd .. "/source-capabilities/6:future_supply/secret"] = "must not be read"
  elseif change == "denied" then f.files[path] = nil; f.denied = { [path] = true }
  elseif change == "bad_unit" then f.files[path] = "5000uV"
  else f.files[f.pd .. "/source-capabilities/2:variable_supply/minimum_voltage"] = "25000mV" end
  local sampled = sample(f); assert(sampled.quality == "partial")
  assert(sampled.data.pd_devices[1].quality == "partial")
end
local unavailable = Collector.new({ fs = FS.new() }):sample(context)
assert(unavailable.status == "unavailable" and unavailable.reason == "no_typec_devices")
local denied = Collector.new({ fs = FS.new({ denied = { ["/sys/class/typec"] = true, ["/sys/class/usb_power_delivery"] = true } }) }):sample(context)
assert(denied.status == "denied")
local late = { typec = snapshot.typec, quality = snapshot.quality, timestamp_ns = now + 61000000000 }
assert(Export.snapshot(late).typec.ports[1].pd_id == nil)
assert(Hardware.related(Hardware.build(late), "typec:port0").total == 0)
local failed = Snapshot.merge(snapshot, { typec = { status = "error", quality = "stale", timestamp_ns = now + 1 } }, 2, now + 1)
assert(Export.snapshot(failed).typec.ports[1].pd_id == nil)
print("Type-C/PD: malformed/denied/unknown profiles, missing classes, stale links and no power/health promotion")

for _, change in ipairs({ "role", "partner", "pd_link", "alias" }) do
  local f = Fixture.new(); local reads = 0
  if change == "alias" then
    f.files["/sys/class/usb_power_delivery/pd8/revision"] = "3.1"
    f.files["/sys/class/usb_power_delivery/pd9/revision"] = "3.1"
    f.links["/sys/class/usb_power_delivery/pd8"] = f.links[f.pd]
    f.links["/sys/class/usb_power_delivery/pd9"] = f.links[f.pd]
  end
  local fs = FS.new(f); local read, list = fs.read, fs.list
  function fs:list(path, ...)
    local values, err, cut = list(self, path, ...)
    if change == "partner" and reads >= 2 and path == "/sys/class/typec" then
      local filtered = {}; for _, value in ipairs(values) do if value ~= "port0-partner" then filtered[#filtered + 1] = value end end
      return filtered, err, cut
    end
    return values, err, cut
  end
  function fs:read(path, ...)
    if path == f.base .. "/data_role" then
      reads = reads + 1
      if reads == 2 then
        if change == "role" then f.files[path] = "host [device]" end
        if change == "partner" then
          for name in pairs(f.files) do if name:find(f.base .. "-partner/", 1, true) == 1 then f.files[name] = nil end end
        end
        if change == "pd_link" then
          for name in pairs(f.links) do if name:match("/typec/port0/usb_power_delivery$") then f.links[name] = "../../usb_power_delivery/pd99" end end
        end
      end
    end
    return read(self, path, ...)
  end
  local current = sample(f, fs)
  assert(current.data.ports[1].pd_id == nil, change)
  if change ~= "alias" then assert(current.data.ports[1].quality == "gap", change) end
end
local f = Fixture.new(); local limited = Collector.new({ fs = FS.new(f), max_profiles = 2 }):sample(context)
assert(limited.data.truncated and #limited.data.pd_devices[1].profiles == 2)
local cut = Fixture.new(); cut.truncated = { ["/sys/class/usb_power_delivery"] = true }
assert(sample(cut).data.ports[1].pd_id == nil)
print("Type-C/PD: role/partner/link changes withdraw association, three aliases stay ambiguous and profile/class budgets stay bounded")
