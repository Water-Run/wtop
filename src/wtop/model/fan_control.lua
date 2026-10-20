-- Fan-control settings remain separate from measured sensor channels.
local Thermal = require("wtop.model.thermal")
local M = { MAX_CONTROLS = 64 }
local FIELDS = { "id", "index", "raw_value", "enable_code", "output_mode_code",
  "frequency_hz", "temperature_channels_mask", "source", "quality",
  "read_started_ns", "observed_at_ns" }
local function integer(value, maximum)
  return math.type(value) == "integer" and value >= 0 and value <= maximum
end

function M.public(snapshot, device, control, now_ns)
  local out = { settings_only = true, errors = {} }
  for _, key in ipairs(FIELDS) do out[key] = control[key] end
  for key, issue in pairs(type(control.errors) == "table" and control.errors or {}) do
    if type(issue) == "table" then out.errors[key] = {
      status = issue.status, reason = issue.reason, source = issue.source } end
  end
  local source_current = Thermal.current(snapshot, now_ns)
    and (device.quality == "fresh" or device.quality == "partial" or device.quality == "estimated")
  local current = source_current and (control.quality == "fresh" or control.quality == "partial")
  if not source_current then out.quality = "stale" end
  now_ns = now_ns or snapshot.timestamp_ns
  if current and type(now_ns) == "number" and type(control.observed_at_ns) == "number"
      and (now_ns < control.observed_at_ns or now_ns - control.observed_at_ns > Thermal.STALE_AFTER_NS) then
    current, out.quality = false, "stale"
  end
  if current then
    if integer(control.raw_value, 255) and not out.errors.value then
      out.setting_percent = control.raw_value / 255 * 100
    end
    if integer(control.enable_code, 2147483647) and not out.errors.enable then
      out.control_method = control.enable_code == 0 and "full_speed"
        or control.enable_code == 1 and "manual" or "automatic"
    end
    if not out.errors.mode then
      out.output_mode = control.output_mode_code == 0 and "dc"
        or control.output_mode_code == 1 and "pwm" or nil
    end
  end
  out.temperature_inputs = {}
  if integer(control.temperature_channels_mask, 9007199254740991)
      and not out.errors.auto_channels_temp then
    for bit = 0, 52 do
      if control.temperature_channels_mask & (1 << bit) ~= 0 then
        out.temperature_inputs[#out.temperature_inputs + 1] = bit + 1
      end
    end
  end
  return out
end

return M
