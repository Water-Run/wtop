local Service = require("wtop.inspectors.service")
local Logind = require("wtop.inspectors.logind")
local JournalStats = require("wtop.inspectors.journal_stats")
local Config = require("wtop.inspectors.sshd_config")

local SSHD = {}

function SSHD.new(options)
  options = options or {}
  options.id = options.id or "service.sshd"
  options.name = options.name or "sshd"
  options.unit = options.unit or "sshd.service"
  if options.sessions_provider == nil then
    options.sessions_provider = Logind.new({ fs = options.fs, runner = options.runner,
      clock = options.clock, platform = options.platform, loginctl = options.loginctl })
  end
  if options.events_provider == nil then
    options.events_provider = JournalStats.new({ fs = options.fs, runner = options.runner,
      clock = options.clock, platform = options.platform, journalctl = options.journalctl })
  end
  if options.config_provider == nil then
    options.config_provider = Config.new({ runner = options.runner, clock = options.clock,
      platform = options.platform, sshd = options.sshd, config_file = options.config_file })
  end
  return Service.new(options)
end

return SSHD
