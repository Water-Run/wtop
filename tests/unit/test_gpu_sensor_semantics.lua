-- What a GPU's temperature, power and fan figures actually are.  hwmon has no
-- vocabulary for "board total": a GPU driver may publish a package power and
-- per-rail powers on one device, and those domains overlap.  Summing them
-- invents a number no meter measured, so the rule is the largest published
-- channel -- and that choice has to be visible, not just documented.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local ViewModel = require("wtop.view_model")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      message, tostring(expected), tostring(actual)), 0)
  end
end

local function channel(kind, index, input, label)
  return { type = kind, index = index, input = input, label = label, unit = "u" }
end

local function sensor(name, target, channels, class_name)
  return { name = name, device_target = target, class = class_name,
    channels = channels, quality = "fresh", source = "/sys/class/hwmon/hwmon9/" .. name }
end

local function gpu(card, refs, target, metrics)
  return { id = card, card = card, model_name = "Test GPU", vendor_name = "Test",
    driver = "i915", device_target = target, hwmon_refs = refs or {},
    metrics = metrics or {}, pci = {} }
end

local function snapshot(gpus, sensors, extra)
  local value = { gpus = { devices = gpus }, sensors = { devices = sensors } }
  for key, item in pairs(extra or {}) do value[key] = item end
  return value
end

local translator = assert(I18n.new({ locale = "en-US" }))
local engine = { history_values = function() return {} end }
local function gpu_table(state)
  return ViewModel.build(engine, state, translator, {}, "gpu").gpu_table
end

-- 1. A plain device: the largest temperature, the only power, the fastest fan.
local plain = snapshot(
  { gpu("card1", { { class = "amdgpu" } }, nil) },
  { sensor("amdgpu", nil, {
      channel("temperature", 1, 65),
      channel("power", 1, 42.5),
      channel("fan", 1, 2400),
    }, "amdgpu") })
local row = gpu_table(plain).rows[1]
equal(row.temperature, "65 °C", "the temperature is the device reading")
equal(row.power, "42.5 W", "the power is the device reading")
equal(row.fan, "2,400 RPM", "the fan is the device reading")
equal(row.power_channels, 1, "one power channel is not a semantic problem")

-- 2. Overlapping domains.  A package total plus two rails must never be added
-- up: the table shows the largest, and says how many there were.
local railed = snapshot(
  { gpu("card1", { { class = "amdgpu" } }, nil) },
  { sensor("amdgpu", nil, {
      channel("power", 1, 12.0, "power"),
      channel("power", 2, 48.0, "rail0"),
      channel("power", 3, 30.0, "rail1"),
    }, "amdgpu") })
local rail_row = gpu_table(railed).rows[1]
equal(rail_row.power, "48.0 W", "the largest power channel is the figure")
equal(rail_row.power_channels, 3, "the channel count travels with the figure")
equal(rail_row.power_source.label, "rail0", "the channel that produced it is known")
equal(rail_row.power_source.index, 2, "and which one it was")

-- 3. Several fans: the fastest is the one an operator acts on.
local multi_fan = snapshot(
  { gpu("card1", { { class = "amdgpu" } }, nil) },
  { sensor("amdgpu", nil, {
      channel("fan", 1, 1200),
      channel("fan", 2, 3100),
      channel("fan", 3, 900),
    }, "amdgpu") })
local fan_row = gpu_table(multi_fan).rows[1]
equal(fan_row.fan, "3,100 RPM", "the fastest fan is shown")
equal(fan_row.fan_source.index, 2, "and the channel it came from is known")

-- 4. A driver that reports a hot spot and an edge sensor: the maximum is the
-- figure, and the channel that produced it is identifiable.
local dual_temp = snapshot(
  { gpu("card1", { { class = "amdgpu" } }, nil) },
  { sensor("amdgpu", nil, {
      channel("temperature", 1, 55, "edge"),
      channel("temperature", 2, 91, "junction"),
    }, "amdgpu") })
local temp_row = gpu_table(dual_temp).rows[1]
equal(temp_row.temperature, "91 °C", "the hottest junction is the figure")
equal(temp_row.temperature_source.label, "junction", "the hot spot is named")

-- 5. Current and voltage channels are not power.  A UCSI or rail device that
-- publishes amperes and volts must not turn into a watt figure.
local not_power = snapshot(
  { gpu("card1", { { class = "amdgpu" } }, nil) },
  { sensor("amdgpu", nil, {
      channel("voltage", 1, 0.9),
      channel("current", 1, 2.5),
    }, "amdgpu") })
local quiet = gpu_table(not_power).rows[1]
equal(quiet.power, "—", "volts and amperes are not a power reading")
equal(quiet.fan, "—", "a device with no fan channel has no fan figure")
equal(quiet.power_channels, 0, "no power channel was counted")

-- 6. A driver figure beats the hwmon join: the provider read it directly, so
-- the hwmon channel is not consulted and no channel is claimed for it.
local native = snapshot(
  { gpu("card1", { { class = "amdgpu" } }, nil,
      { temperature_celsius = 70, power_watts = 120, utilization_percent = 30 }) },
  { sensor("amdgpu", nil, { channel("power", 1, 10) }, "amdgpu") })
local native_row = gpu_table(native).rows[1]
equal(native_row.temperature, "70 °C", "the driver temperature wins")
equal(native_row.power, "120.0 W", "the driver power wins")
equal(native_row.power_channels, 1, "the hwmon count is still reported, not hidden")

-- 7. No hwmon at all is the ordinary Intel case, and must stay empty rather
-- than borrowing another device's numbers.
local bare = snapshot(
  { gpu("card1", {}, "0000:00:02.0") },
  { sensor("coretemp", "coretemp.0", {
      channel("temperature", 1, 71), channel("power", 1, 99),
    }, "coretemp") })
local bare_row = gpu_table(bare).rows[1]
equal(bare_row.temperature, "—", "an unmatched GPU has no temperature")
equal(bare_row.power, "—", "an unmatched GPU has no power")
equal(bare_row.fan, "—", "an unmatched GPU has no fan")

-- 8. The join is a single implementation, so the sensor overlay's account of
-- where the GPU's figures came from cannot drift from the table's.
local overlay = table.concat(
  TUI.sensor_detail_lines(railed, translator, nil), "\n")
equal(overlay:find("GPU card1 reads this device", 1, true) ~= nil, true,
  "the overlay names the GPU that reads the device: " .. overlay)
equal(overlay:find("Power ← rail0", 1, true) ~= nil, true,
  "the overlay names the power channel: " .. overlay)
equal(overlay:find("3 power channels overlap", 1, true) ~= nil, true,
  "the overlay states the rule: " .. overlay)
equal(overlay:find("never their sum", 1, true) ~= nil, true,
  "the rule says what is not being done: " .. overlay)

-- A device no GPU reads gets no claim at all.
local plain_overlay = table.concat(
  TUI.sensor_detail_lines(bare, translator, nil), "\n")
equal(plain_overlay:find("reads this device", 1, true), nil,
  "an unrelated hwmon device is not attributed to a GPU: " .. plain_overlay)

-- The fan claim appears when there is a fan and is absent when there is not.
local fan_overlay = table.concat(
  TUI.sensor_detail_lines(multi_fan, translator, nil), "\n")
equal(fan_overlay:find("Fan ← fan 2", 1, true) ~= nil, true,
  "the fan channel is named: " .. fan_overlay)
equal(fan_overlay:find("power channels overlap", 1, true), nil,
  "a device with one power channel is not given the overlap warning")

-- 9. A snapshot with no GPU section at all must not error.
equal(#ViewModel.build(engine, { gpus = {}, sensors = { devices = {} } },
  translator, {}, "gpu").gpu_table.rows, 0, "no GPU devices, no rows")
equal(type(ViewModel.gpu_sensor_join({})), "table", "an empty snapshot still joins")
equal(type(ViewModel.gpu_sensor_join(nil)), "table", "a missing snapshot still joins")

-- 10. A device matched by device_target rather than by class joins the same
-- way, because a driver that publishes no class must not be excluded.
local by_target = snapshot(
  { gpu("card0", {}, "0000:01:00.0") },
  { sensor("amdgpu", "0000:01:00.0", { channel("fan", 1, 1500) }) })
equal(gpu_table(by_target).rows[1].fan, "1,500 RPM",
  "a device_target-only match still contributes a fan")

-- The export publishes the join keys and every raw channel, so a consumer can
-- make the same choice itself.  The joined figure is a presentation decision,
-- and the exporter must not bake a "board total" into the contract.
local json = require("wtop.format.json")
local Export = require("wtop.export")
local function exported(state, section, index)
  local result = Export.snapshot(state)
  return result[section].devices[index or 1]
end
local railed_state = {
  sequence = 1, timestamp_ns = 1,
  quality = { gpus = { status = "ok", quality = "fresh" } },
  gpus = { devices = { gpu("card1", { { class = "amdgpu" } }, nil) } },
  sensors = { devices = { sensor("amdgpu", nil, {
    channel("power", 1, 12.0, "power"), channel("power", 2, 48.0, "rail0"),
  }, "amdgpu") } },
}
local exported_gpu = exported(railed_state, "gpus")
equal(exported_gpu.hwmon_refs[1].class, "amdgpu", "the export carries the join key")
equal(exported_gpu.board_power_watts, nil,
  "the export does not invent a board total the kernel never reported")
equal(json.encode(exported_gpu):find('"board_power', 1, true), nil,
  "and no such field is serialised either")

local exported_sensor = exported(railed_state, "sensors")
equal(json.encode(exported_sensor):find('"rail0"', 1, true) ~= nil, true,
  "every raw channel, labelled, reaches the export")

print("ok: GPU fan, rail and board-power semantics")
