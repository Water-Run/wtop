local M = {}
local Platform = require("wtop.platform")

local constructors = {
  cpu = require("wtop.collectors.cpu"),
  cpu_info = require("wtop.collectors.cpu_info"),
  memory = require("wtop.collectors.memory"),
  pressure = require("wtop.collectors.pressure"),
  disk = require("wtop.collectors.disk"),
  network = require("wtop.collectors.network"),
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
