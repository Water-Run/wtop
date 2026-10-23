package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tools/?.lua;" .. package.path
local FS = require("support.fixture_fs")
local Collector = require("wtop.collectors.power_supply")
local Supply = require("wtop.model.supply_input")
local Snapshot = require("wtop.model.snapshot")
local Export = require("wtop.export")
local Report = require("wtop.report")
local TUI = require("wtop.tui")
local View = require("wtop.view_model")
local I18n = require("wtop.i18n")
local JSON = require("wtop.format.json")
local now = 1000000000
local base = "/sys/class/power_supply/USB0"
local function fixture()
  local data = { files = {}, links = { [base] = "../../devices/fixture/USB0" } }
  for key, value in pairs({ type = "USB", online = "1", scope = "Device",
      usb_type = "C [PD] PD_PPS", voltage_now = "20000000", current_now = "3000000",
      voltage_min = "5000000", voltage_max = "28000000", current_max = "5000000",
      power_now = "60000000", input_power_limit = "80000000",
      input_current_limit = "4000000", input_voltage_limit = "20000000" }) do
    data.files[base .. "/" .. key] = value .. "\n"
  end
  return data
end
local function sample(data, fs)
  fs = fs or FS.new(data)
  function fs:write() error("external power attributes must not be written") end
  local result = Collector.new({ fs = fs }):sample({ now_ns = function() return now end })
  local snapshot = Snapshot.merge(nil, { power_supply = result }, 1, now)
  return snapshot, result, result.data.supplies[1]
end
local snapshot, result, raw = sample(fixture())
assert(result.status == "ok" and result.quality == "fresh" and raw.quality == "fresh")
assert(raw.voltage_volts == 20 and raw.current_amperes == 3 and raw.maximum_current_amperes == 5)
assert(raw.usb_type == "PD" and #raw.usb_types == 3 and raw.usb_types[3] == "PD_PPS")
assert(raw.observed_at_ns == now and raw.read_started_ns == now)
local public = Export.snapshot(snapshot).power_supplies.supplies[1]
assert(public.power_watts == 60 and public.input_power_limit_watts == 80)
assert(public.input_limit_percent == 75 and public.input_headroom_watts == 20)
assert(public.source == base and public.scope == "Device")
raw.serial_number, raw.secret, raw.session = "PRIVATE-ADAPTER", "PRIVATE", { average = 60 }
assert(not JSON.encode(Export.snapshot(snapshot)):find("PRIVATE", 1, true))
local agent = Export.agent(snapshot)
assert(agent.metrics.power.supplies_total == 1 and #agent.metrics.power.supplies == 1)
assert(agent.metrics.power.supplies[1].input_limit_percent == 75)
assert(agent.metrics.power.total_watts == nil and agent.metrics.power.platform_watts == nil)
assert(agent.overall.signal_count == 0, "input settings must not create CPU throttling or health signals")
local schema_file = assert(io.open("docs/agent-v1.schema.json", "rb"))
local schema = assert(require("wtop.core.json").decode(schema_file:read("a"))); schema_file:close()
local validate = require("agent_schema").validate
assert(#validate(agent, schema) == 0)
local invalid = Export.agent(snapshot); invalid.metrics.power.supplies[1].voltage_volts = -1
assert(#validate(invalid, schema) > 0)
invalid = Export.agent(snapshot); invalid.metrics.power.supplies[1].usb_types = JSON.array({})
for index = 1, 17 do invalid.metrics.power.supplies[1].usb_types[index] = "PD" end
assert(#validate(invalid, schema) > 0)
local report = Report.render(Export.snapshot(snapshot))
assert(report:find("External power supplies", 1, true) and report:find("75.0%", 1, true))
assert(report:find("External input capabilities and settings", 1, true))
assert(report:find("28.000 V", 1, true) and report:find("4.000 A", 1, true)
  and report:find("PD_PPS", 1, true) and report:find(base, 1, true))
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
  local tr = assert(I18n.new({ locale = locale }))
  assert(tr:has("supply_input.note"))
  local lines = table.concat(TUI.power_detail_lines(snapshot, tr), "\n")
  assert(lines:find(tr:t("supply_input.note"), 1, true), locale)
  assert(lines:find("[######--]", 1, true) and lines:find(base, 1, true), locale)
  assert(not lines:find("\n" .. tr:t("ui.no_data"), 1, true), locale)
end
print("external supply: readonly units, USB selection, exact input cap, ten-locale bar and separate CPU/health/export domains")

for _, online in ipairs({ "0", "1", "2" }) do
  local data = fixture(); data.files[base .. "/online"] = online .. "\n"
  data.files[base .. "/power_now"] = nil
  local state, _, device = sample(data)
  local row = Supply.public(state, device)
  assert(row.power_watts == nil and row.input_limit_percent == nil, "V*I must not manufacture input power")
  assert(row.maximum_voltage_volts == 28 and row.maximum_current_amperes == 5)
  if online == "2" then assert(row.online_mode == "programmable") end
end
for _, value in ipairs({ "-1", "1.5", "nan", "inf", "9007199254740992", string.rep("9", 300) }) do
  local data = fixture(); data.files[base .. "/power_now"] = value
  local state, _, device = sample(data)
  assert(device.errors.power_now.status == "error" and device.power_watts == nil)
  assert(Supply.public(state, device).input_limit_percent == nil)
end
for _, code in ipairs({ 13, 5, 61 }) do
  local data = fixture(); data.files[base .. "/power_now"] = nil
  data.errors = { [base .. "/power_now"] = code }
  local state, _, device = sample(data)
  assert(device.power_watts == nil and Supply.public(state, device).input_limit_percent == nil)
  if code == 13 then
    assert(device.errors.power_now.status == "denied")
    local denied_report = Report.render(Export.snapshot(state))
    assert(denied_report:find("External input read issues", 1, true) and denied_report:find("power_now", 1, true))
  elseif code == 5 then assert(device.errors.power_now.status == "error")
  else assert(device.errors.power_now == nil) end
end
for _, usb in ipairs({ "[PD] [C]", "PD C", "[PD", "PD]", "[P\27D]", string.rep("X", 33) }) do
  local data = fixture(); data.files[base .. "/usb_type"] = usb
  local _, _, device = sample(data)
  assert(device.usb_type == nil and device.errors.usb_type)
end
for _, online in ipairs({ "0", "3", "broken" }) do
  local data = fixture(); data.files[base .. "/online"] = online
  local state, _, device = sample(data)
  assert(Supply.public(state, device).input_limit_percent == nil)
end
local zero = fixture(); zero.files[base .. "/power_now"] = "0"
local zstate, _, zdevice = sample(zero)
assert(Supply.public(zstate, zdevice).input_limit_percent == 0)
zero.files[base .. "/input_power_limit"] = "0"
zstate, _, zdevice = sample(zero)
assert(zdevice.input_power_limit_watts == 0 and Supply.public(zstate, zdevice).input_limit_percent == nil)
local over = fixture(); over.files[base .. "/power_now"] = "100000000"
local ostate, _, odevice = sample(over)
assert(Supply.public(ostate, odevice).input_limit_percent == 125)
assert(Supply.public(ostate, odevice).input_headroom_watts == -20)
print("external supply: no V*I/maxima inference, offline/programmable states, invalid/denied/no-value fields, zero and over-cap readings")

local late = { power_supplies = snapshot.power_supplies, quality = snapshot.quality, timestamp_ns = now + 16000000000 }
assert(Export.snapshot(late).power_supplies.supplies[1].input_limit_percent == nil)
late.timestamp_ns = now - 1
assert(Export.snapshot(late).power_supplies.supplies[1].input_limit_percent == nil)
local fractional = fixture(); fractional.files[base .. "/input_power_limit"] = "322999"
local fstate, _, fdevice = sample(fractional)
assert(fdevice.quality == "fresh" and Supply.public(fstate, fdevice).input_limit_percent > 100)
for _, quality in ipairs({ "denied", "error", "stale", "gap", "unavailable" }) do
  local state = { timestamp_ns = now, power_supplies = snapshot.power_supplies,
    quality = { power_supplies = { status = "error", quality = quality } } }
  assert(Export.snapshot(state).power_supplies.supplies[1].input_limit_percent == nil)
end
for _, change in ipairs({ "identity", "online", "usb", "cap" }) do
  local data = fixture(); local fs = FS.new(data); local read = fs.read
  local cap_reads = 0
  function fs:read(path, ...)
    if path == base .. "/power_now" then
      if change == "identity" then data.links[base] = "../../devices/replacement/USB0" end
      if change == "online" then data.files[base .. "/online"] = "0" end
      if change == "usb" then data.files[base .. "/usb_type"] = "[C] PD PD_PPS" end
    end
    if path == base .. "/input_power_limit" then
      cap_reads = cap_reads + 1
      if change == "cap" and cap_reads == 2 then data.files[path] = "65000000" end
    end
    return read(self, path, ...)
  end
  local state, _, device = sample(data, fs)
  assert(device.quality == "gap", change)
  assert(Supply.public(state, device).input_limit_percent == nil, change)
end
local many = fixture()
for index = 1, 9 do
  many.files["/sys/class/power_supply/AC" .. index .. "/type"] = "Mains"
  many.files["/sys/class/power_supply/AC" .. index .. "/online"] = "1"
end
local state = sample(many)
agent = Export.agent(state)
assert(#agent.metrics.power.supplies == 5 and agent.metrics.power.supplies_total == 10)
assert(agent.metrics.power.supplies_truncated)
local en = assert(I18n.new({ locale = "en-US" }))
assert(#View.supply_input_rows(state, en) == 10)
print("external supply: stale/failed/future sample, identity/negotiation/cap changes and bounded Agent summaries")

-- New process-isolated sources require an explicit advertisement. An older
-- module can still provide its known workers and the direct collector fallback.
local Hardware = require("wtop.collectors.hardware_worker")
local bridge = { available = true, hardware_worker_open = function() end,
  hardware_worker_query = function() end, hardware_worker_close = function() end,
  hardware_worker_sources = { hwmon = true } }
assert(Hardware.available(bridge) and Hardware.available(bridge, "hwmon"))
assert(not Hardware.available(bridge, "power_supply"))
bridge.hardware_worker_sources.power_supply = true
assert(Hardware.available(bridge, "power_supply"))
bridge.hardware_worker_query = nil
assert(not Hardware.available(bridge, "power_supply"))
print("external supply: advertised isolated source, legacy direct fallback and optional native capability")
