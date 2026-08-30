local Service = require("wtop.inspectors.service")

local SSHD = {}

function SSHD.new(options)
  options = options or {}
  options.id = options.id or "service.sshd"
  options.name = options.name or "sshd"
  options.unit = options.unit or "sshd.service"
  return Service.new(options)
end

return SSHD
