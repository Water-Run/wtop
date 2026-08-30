local Registry = require("wtop.inspectors.registry")
local Smart = require("wtop.inspectors.smart")
local Bandwidth = require("wtop.inspectors.ram_bandwidth")
local SSHD = require("wtop.inspectors.sshd")

local M = {}

function M.new_default(options)
  options = options or {}
  if type(options) ~= "table" then error("inspector options must be a table", 2) end
  local registry = Registry.new()
  assert(registry:register(Smart.new(options.smart)))
  assert(registry:register(Bandwidth.new(options.ram_bandwidth)))
  assert(registry:register(SSHD.new(options.sshd)))
  return registry
end

M.Registry = Registry
M.Smart = Smart
M.RamBandwidth = Bandwidth
M.SSHD = SSHD

return M
