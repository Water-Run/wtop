local Power = require("wtop.model.power")
local M = {}
local FIELDS = { "id", "name", "type", "online", "online_mode", "present", "scope", "status",
  "usb_type", "source", "identity_quality", "quality", "read_started_ns", "observed_at_ns",
  "voltage_volts", "current_amperes", "minimum_voltage_volts", "maximum_voltage_volts",
  "maximum_current_amperes", "power_watts", "input_voltage_limit_volts",
  "input_current_limit_amperes", "input_power_limit_watts" }

function M.public(snapshot, supply)
  local row = { errors = {}, usb_types = {} }
  for _, key in ipairs(FIELDS) do row[key] = supply[key] end
  for index, value in ipairs(supply.usb_types or {}) do
    if index > 16 then break end
    row.usb_types[index] = value
  end
  for key, issue in pairs(supply.errors or {}) do
    row.errors[key] = { status = issue.status, reason = issue.reason, source = issue.source }
  end
  local quality = snapshot.quality and snapshot.quality.power_supplies
  row.quality = Power.zone_state(supply, quality, snapshot.timestamp_ns)
  local usb = type(supply.type) == "string" and (supply.type == "USB" or supply.type:match("^USB_"))
  -- Explicit input power and its configured cap on this USB supply only.
  -- Capability maxima, V*I, other supplies and CPU/board totals are not used.
  if usb and supply.online == true and not Power.unusable(row.quality)
      and not row.errors.power_now and not row.errors.input_power_limit then
    local comparison = Power.compare(supply.power_watts, supply.input_power_limit_watts)
    if comparison then
      row.input_limit_percent, row.input_headroom_watts = comparison.percent, comparison.headroom_watts
    end
  end
  return row
end

return M
