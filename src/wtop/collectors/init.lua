local M = {}
local Platform = require("wtop.platform")

local constructors = {
  cpu = require("wtop.collectors.cpu"),
  cpu_info = require("wtop.collectors.cpu_info"),
  cpu_limits = require("wtop.collectors.cpu_limits"),
  cpu_clocks = require("wtop.collectors.cpu_clocks"),
  thermal_throttle = require("wtop.collectors.thermal_throttle"),
  cpuidle = require("wtop.collectors.cpuidle"),
  memory = require("wtop.collectors.memory"),
  numa = require("wtop.collectors.numa"),
  memory_devices = require("wtop.collectors.memory_devices"),
  expansion_slots = require("wtop.collectors.expansion_slots"),
  port_connectors = require("wtop.collectors.port_connectors"),
  onboard_devices = require("wtop.collectors.onboard_devices"),
  firmware_batteries = require("wtop.collectors.firmware_batteries"),
  firmware_enclosures = require("wtop.collectors.firmware_enclosures"),
  firmware_power_supplies = require("wtop.collectors.firmware_power_supplies"),
  firmware_bmcs = require("wtop.collectors.firmware_bmcs"),
  firmware_tpms = require("wtop.collectors.firmware_tpms"),
  firmware_components = require("wtop.collectors.firmware_components"),
  firmware_esrt = require("wtop.collectors.firmware_esrt"),
  tpm = require("wtop.collectors.tpm"),
  watchdog = require("wtop.collectors.watchdog"),
  rfkill = require("wtop.collectors.rfkill"),
  thermal_zones = require("wtop.collectors.thermal_zones"),
  host_interfaces = require("wtop.collectors.host_interfaces"),
  processor_firmware = require("wtop.collectors.processor_firmware"),
  edac = require("wtop.collectors.edac"),
  spd = require("wtop.collectors.spd"),
  pressure = require("wtop.collectors.pressure"),
  disk = require("wtop.collectors.disk"),
  disk_health = require("wtop.collectors.linux_nvme"),
  network = require("wtop.collectors.network"),
  wifi = require("wtop.collectors.wifi"),
  connections = require("wtop.collectors.connections"),
  process = require("wtop.collectors.process"),
  gpu = require("wtop.collectors.gpu"),
  cpufreq = require("wtop.collectors.cpufreq"),
  hwmon = require("wtop.collectors.hwmon"),
  powercap = require("wtop.collectors.powercap"),
  mounts = require("wtop.collectors.mounts"),
  cgroup = require("wtop.collectors.cgroup"),
  system_info = require("wtop.collectors.system_info"),
  power_supply = require("wtop.collectors.power_supply"),
  inventory = require("wtop.collectors.inventory"),
}

function M.new_all(options)
  options = options or {}
  if type(options) ~= "table" then error("collector options must be a table", 2) end
  local platform = options.platform or Platform.id()
  if platform == "windows" or platform == "macos" then
    return require("wtop.collectors.portable").new_all(options)
  end
  local result = {}
  for id, module in pairs(constructors) do
    result[id] = module.new(options[id] or options.common)
  end
  return result
end

M.constructors = constructors

return M
