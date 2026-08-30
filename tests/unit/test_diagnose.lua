package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local diagnose = require("wtop.diagnose")

local report = diagnose.collect({ safe_mode = true })
assert(report.application.name == "wtop")
assert(report.platform.sysname == "Linux" or report.platform.sysname == "unknown")
assert(report.sources.proc_stat.state == "available")
assert(report.sources.proc_meminfo.state == "available")
assert(report.helpers.smartctl.state == "disabled")
assert(type(report.terminal.stdin_tty) == "boolean")

return true
