local M = {}

local constructors = {
  cpu = require("wtop.collectors.cpu"),
  memory = require("wtop.collectors.memory"),
  pressure = require("wtop.collectors.pressure"),
  disk = require("wtop.collectors.disk"),
  network = require("wtop.collectors.network"),
  connections = require("wtop.collectors.connections"),
  process = require("wtop.collectors.process"),
  gpu = require("wtop.collectors.gpu"),
  cpufreq = require("wtop.collectors.cpufreq"),
  hwmon = require("wtop.collectors.hwmon"),
  mounts = require("wtop.collectors.mounts"),
  cgroup = require("wtop.collectors.cgroup"),
}

function M.new_all(options)
  options = options or {}
  if type(options) ~= "table" then error("collector options must be a table", 2) end
  local result = {}
  for id, module in pairs(constructors) do
    result[id] = module.new(options[id] or options.common)
  end
  return result
end

M.constructors = constructors

return M
