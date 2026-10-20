local M = {}
function M.new()
  local base = "/sys/class/hwmon/hwmon0"
  local values = { name = "Fixture board", temp1_input = "42000", temp1_crit = "95000",
    temp3_input = "35000", fan1_input = "1600", pwm1 = "128", pwm1_enable = "1",
    pwm1_mode = "1", pwm1_freq = "25000", pwm1_auto_channels_temp = "5",
    pwm2 = "0", pwm2_enable = "0", pwm2_mode = "0", pwm2_freq = "0",
    pwm3 = "255", pwm3_enable = "5", pwm3_mode = "1", pwm3_auto_channels_temp = "3",
    pwm4_enable = "2", pwm4_mode = "1", pwm1_auto_point1_pwm = "255",
    pwm1_auto_point1_temp = "60000", pwm0 = "255", pwm01 = "255" }
  local files = {}
  for key, value in pairs(values) do files[base .. "/" .. key] = value .. "\n" end
  return { base = base, files = files, links = {
    [base] = "/devices/platform/fixture-board/hwmon/hwmon0",
    [base .. "/device"] = "/devices/platform/fixture-board" } }
end
return M
