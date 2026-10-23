local M = {}
function M.new()
  local base, pd = "/sys/class/typec/port0", "/sys/class/usb_power_delivery/pd7"
  local physical = "/sys/devices/pci0000:00/0000:00:14.0/controller"
  local data = { base = base, pd = pd, files = {}, links = {
    [base] = physical .. "/typec/port0", [pd] = physical .. "/usb_power_delivery/pd7",
    [physical .. "/typec/port0/device"] = "../..",
    [physical .. "/usb_power_delivery/pd7/device"] = "../..",
    [physical .. "/typec/port0/usb_power_delivery"] = "../../usb_power_delivery/pd7",
  } }
  local function files(path, values)
    for name, value in pairs(values) do data.files[path .. "/" .. name] = value .. "\n" end
  end
  files(base, { data_role = "[host] device", power_role = "[source] sink", port_type = "dual",
    preferred_role = "none", power_operation_mode = "usb_power_delivery", orientation = "normal",
    vconn_source = "yes", usb_power_delivery_revision = "3.1", usb_typec_revision = "2.0",
    usb_capability = "usb2 usb3 [usb4]" })
  files(base .. "-partner", { type = "hub", supports_usb_power_delivery = "yes",
    usb_power_delivery_revision = "3.0", usb_mode = "usb2 [usb3]" })
  files(base .. "-cable", { type = "active", plug_type = "type-c", usb_power_delivery_revision = "3.0" })
  files(base .. "-partner/identity", { id_header = "PRIVATE-IDENTITY-MUST-NOT-BE-READ" })
  files(pd, { revision = "3.1", version = "1.0" })
  for _, direction in ipairs({ "source", "sink" }) do
    local path = pd .. "/" .. direction .. "-capabilities/"
    local source = direction == "source"
    local fixed = { voltage = "5000mV", dual_role_power = "1", unconstrained_power = "0",
      usb_communication_capable = "1", dual_role_data = "1", unchunked_extended_messages_supported = "0" }
    fixed[source and "maximum_current" or "operational_current"] = source and "3000mA" or "1000mA"
    fixed[source and "peak_current" or "fast_role_swap_current"] = "2"
    fixed[source and "usb_suspend_supported" or "higher_capability"] = "1"
    files(path .. "1:fixed_supply", fixed)
    files(path .. "2:variable_supply", { minimum_voltage = "5000mV", maximum_voltage = "20000mV",
      [source and "maximum_current" or "operational_current"] = "2000mA" })
    files(path .. "3:battery", { minimum_voltage = "5000mV", maximum_voltage = "20000mV",
      [source and "maximum_power" or "operational_power"] = "45000mW" })
    files(path .. "4:programmable_supply", { minimum_voltage = "3300mV", maximum_voltage = "21000mV",
      maximum_current = "3000mA", pps_power_limited = "1" })
    files(path .. "5:spr_adjustable_voltage_supply", { maximum_current_9V_to_15V = "5000mA",
      maximum_current_15V_to_20V = "4000mA", peak_current = "3" })
  end
  return data
end
return M
