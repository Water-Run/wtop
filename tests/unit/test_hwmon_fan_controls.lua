package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tools/?.lua;" .. package.path
local Fixture = require("support.fan_controls")
local FS = require("support.fixture_fs")
local Hwmon = require("wtop.collectors.hwmon")
local FanControl = require("wtop.model.fan_control")
local Snapshot = require("wtop.model.snapshot")
local Export = require("wtop.export")
local JSON = require("wtop.format.json")
local Report = require("wtop.report")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local fixture = Fixture.new()
local fs = FS.new(fixture)
local read, reads = fs.read, {}
function fs:read(path, ...)
  reads[path] = (reads[path] or 0) + 1
  assert(not path:find("auto_point", 1, true), "fan curve or write-only attribute was read")
  return read(self, path, ...)
end
function fs:write() error("hardware settings must not be written") end
local now = 1000000000
local context = { now_ns = function() return now end }
local collector = Hwmon.new({ fs = fs })
local sample = collector:sample(context)
assert(sample.status == "ok" and sample.quality == "fresh")
local device = assert(sample.data.devices[1]); local controls = device.fan_controls
assert(#controls == 4 and #device.channels == 3 and device.channel_counts.fan == 1)
assert(controls[1].id == "pwm1" and controls[1].raw_value == 128 and controls[1].enable_code == 1)
assert(controls[2].raw_value == 0 and controls[2].output_mode_code == 0 and controls[2].frequency_hz == 0)
assert(controls[3].raw_value == 255 and controls[3].enable_code == 5)
assert(controls[4].raw_value == nil and controls[4].quality == "fresh")
assert(controls[4].source == fixture.base .. "/pwm4_enable")
assert(controls[1].observed_at_ns == now and controls[1].read_started_ns == now)
for _, control in ipairs(controls) do
  assert(control.input == nil and control.session == nil and control.rpm == nil)
end
local snapshot = Snapshot.merge(nil, { hwmon = sample }, 1, now)
local full = Export.snapshot(snapshot)
local public = full.sensors.devices[1].fan_controls
assert(public[1].settings_only and math.abs(public[1].setting_percent - 128 / 255 * 100) < 1e-10)
assert(public[1].control_method == "manual" and public[1].output_mode == "pwm")
assert(public[1].temperature_inputs[1] == 1 and public[1].temperature_inputs[2] == 3)
assert(public[2].setting_percent == 0 and public[2].control_method == "full_speed" and public[2].output_mode == "dc")
assert(public[3].setting_percent == 100 and public[3].control_method == "automatic" and public[3].enable_code == 5)
assert(public[4].setting_percent == nil and public[4].control_method == "automatic")
local compact = Export.agent(snapshot)
assert(compact.metrics.sensors.fan_count == 1 and compact.metrics.sensors.fan_controls_total == 4)
assert(#compact.metrics.sensors.fan_controls == 4 and compact.overall.signal_count == 0)
local schema_file = assert(io.open("docs/agent-v1.schema.json", "rb"))
local schema = assert(require("wtop.core.json").decode(schema_file:read("a"))); schema_file:close()
assert(#require("agent_schema").validate(compact, schema) == 0)
local text = Report.render(full)
assert(text:find("Fan control settings", 1, true) and text:find("not verified", 1, true))
assert(text:find("50.2%", 1, true) and text:find("25000 Hz", 1, true))

-- Raw codes survive, while private or invented measurement fields do not.
controls[1].serial_number = "PRIVATE-FAN"
controls[1].rpm, controls[1].session = 9999, { average = 50 }
local filtered = FanControl.public(snapshot, device, controls[1])
assert(filtered.serial_number == nil and filtered.rpm == nil and filtered.session == nil)
assert(not JSON.encode(Export.snapshot(snapshot).sensors):find("PRIVATE", 1, true))
controls[1].serial_number, controls[1].rpm, controls[1].session = nil, nil, nil

for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
  local i18n = assert(I18n.new({ locale = locale }))
  local lines = TUI.sensor_detail_lines(snapshot, i18n, now)
  local rendered = table.concat(lines, "\n")
  assert(rendered:find(i18n:t("fan_control.note"), 1, true), locale)
  assert(rendered:find("pwm1: [####----]", 1, true) and rendered:find("pwm3: [########]", 1, true))
  assert(rendered:find("temp1, temp3", 1, true) and rendered:find("(5)", 1, true))
end
print("hwmon fan controls: bounded readonly settings, zero/endpoints, automatic raw codes, DC/PWM, selectors, separate RPM/health/session and ten-locale details")

-- Errors belong to their field. A denied/invalid control never fabricates a
-- current percentage, and a failed source withdraws derived current fields.
do
  for _, raw in ipairs({ "-1", "256", "1.5", "nan", "9007199254740993", string.rep("1", 257) }) do
    local data = Fixture.new(); data.files[data.base .. "/pwm1"] = raw
    local result = Hwmon.new({ fs = FS.new(data) }):sample(context)
    local control = result.data.devices[1].fan_controls[1]
    assert(result.quality == "partial" and control.raw_value == nil and control.errors.value)
    assert(FanControl.public(snapshot, result.data.devices[1], control).setting_percent == nil)
  end
  local data = Fixture.new(); data.files[data.base .. "/pwm1_mode"] = "9\n"
  local result = Hwmon.new({ fs = FS.new(data) }):sample(context)
  local row = FanControl.public(snapshot, result.data.devices[1], result.data.devices[1].fan_controls[1])
  assert(row.output_mode_code == 9 and row.output_mode == nil and row.errors.mode)
  data = Fixture.new(); data.files[data.base .. "/pwm1"] = nil
  data.denied = { [data.base .. "/pwm1"] = true }
  result = Hwmon.new({ fs = FS.new(data) }):sample(context)
  row = result.data.devices[1].fan_controls[1]
  assert(row.raw_value == nil and row.errors.value.status == "denied" and row.quality == "partial")
  local failed = Snapshot.merge(snapshot, { hwmon = { status = "error", quality = "error", timestamp_ns = now + 1 } }, 2, now + 1)
  row = Export.snapshot(failed).sensors.devices[1].fan_controls[1]
  assert(row.raw_value == 128 and row.setting_percent == nil and row.control_method == nil and row.quality == "stale")
  local late = { sensors = snapshot.sensors, quality = snapshot.quality, timestamp_ns = now + 16000000000 }
  assert(Export.snapshot(late).sensors.devices[1].fan_controls[1].setting_percent == nil)
  local bad = Export.agent(snapshot); bad.metrics.sensors.fan_controls[1].settings_only = false
  assert(#require("agent_schema").validate(bad, schema) > 0)
  bad = Export.agent(snapshot); bad.metrics.sensors.fan_controls[1].setting_percent = 100.1
  assert(#require("agent_schema").validate(bad, schema) > 0)
  -- A control with no readable fields is not a fresh zero setting.
  for _, failure in ipairs({ "denied", "unavailable", "error" }) do
    local single = { files = { [fixture.base .. "/name"] = "Control-only" }, links = fixture.links }
    local path = fixture.base .. "/pwm1"
    if failure == "denied" then single.denied = { [path] = true }
    else single.errors = { [path] = failure == "unavailable" and 61 or 5 } end
    local result = Hwmon.new({ fs = FS.new(single) }):sample(context)
    local control = result.data.devices[1].fan_controls[1]
    assert(control.quality == failure and control.raw_value == nil)
    assert(FanControl.public(snapshot, result.data.devices[1], control).quality == failure)
  end
end
print("hwmon fan controls: malformed/denied fields, unknown mode, stale source and age withdraw current percentages; settings-only schema enforced")

do
  local data = Fixture.new(); local changed = FS.new(data); local original = changed.read
  function changed:read(path, ...)
    if path == data.base .. "/pwm1" then data.links[data.base .. "/device"] = "/devices/replaced-board" end
    return original(self, path, ...)
  end
  local result = Hwmon.new({ fs = changed }):sample(context)
  assert(result.quality == "partial")
  for _, control in ipairs(result.data.devices[1].fan_controls) do assert(control.quality == "gap") end
  local exported = Export.snapshot(Snapshot.merge(nil, { hwmon = result }, 1, now))
  assert(exported.sensors.devices[1].fan_controls[1].setting_percent == nil)
end
print("hwmon fan controls: name/path/device identity checked around reads; changed devices withdraw current settings")

do
  local limited = Hwmon.new({ fs = FS.new(Fixture.new()), max_fan_controls_per_device = 1 }):sample(context)
  assert(limited.data.truncated and limited.data.devices[1].fan_controls_truncated)
  assert(#limited.data.devices[1].fan_controls == 1 and #limited.data.devices[1].channels == 3)
  assert(not pcall(Hwmon.new, { max_fan_controls_per_device = 0 }))
  local many = Fixture.new()
  for index = 5, 10 do many.files[many.base .. "/pwm" .. index] = "127\n" end
  local current = Hwmon.new({ fs = FS.new(many) }):sample(context)
  local data = Export.agent(Snapshot.merge(nil, { hwmon = current }, 1, now)).metrics.sensors
  assert(#data.fan_controls == 5 and data.fan_controls_total == 10 and data.fan_controls_truncated)
  -- A controller can have no tachometer or thermometer channels at all.
  local only = { files = { [fixture.base .. "/name"] = "Control-only",
    [fixture.base .. "/pwm1"] = "128\n" }, links = fixture.links }
  local sample_only = Hwmon.new({ fs = FS.new(only) }):sample(context)
  local state = Snapshot.merge(nil, { hwmon = sample_only }, 1, now)
  local rendered = table.concat(TUI.sensor_detail_lines(state, assert(I18n.new({ locale = "en-US" })), now), "\n")
  assert(rendered:find("pwm1: [####----]", 1, true) and not rendered:find("\nNo data", 1, true))
  local selectors = Fixture.new(); selectors.files[selectors.base .. "/pwm1_auto_channels_temp"] = "9007199254740991\n"
  local all = Hwmon.new({ fs = FS.new(selectors) }):sample(context)
  local state_all = Snapshot.merge(nil, { hwmon = all }, 1, now)
  local control = Export.snapshot(state_all).sensors.devices[1].fan_controls[1]
  assert(#control.temperature_inputs == 53 and control.temperature_inputs[53] == 53)
  local text_all = table.concat(TUI.sensor_detail_lines(state_all, assert(I18n.new({ locale = "en-US" })), now), "\n")
  for index = 1, 53 do assert(text_all:find("temp" .. index, 1, true)) end
end
print("hwmon fan controls: count caps, bounded Agent summary and control-only devices stay distinct from measured sensors")
