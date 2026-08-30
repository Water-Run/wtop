package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local diagnose = require("wtop.diagnose")

local report = diagnose.collect({
    safe_mode = true,
    privilege = {
        mode = "root", uid = 0, effective_uid = 0, original_uid = 1000,
        root = true, elevated = true, via_sudo = true, requested = true,
    },
})
assert(report.application.name == "wtop")
assert(report.platform.sysname == "Linux" or report.platform.sysname == "unknown")
assert(report.sources.proc_stat.state == "available")
assert(report.sources.proc_cpuinfo.state == "available")
assert(report.sources.proc_meminfo.state == "available")
assert(type(report.sources.sys_hwmon.state) == "string")
assert(type(report.sources.sys_powercap.state) == "string")
assert(report.helpers.smartctl.state == "disabled")
assert(type(report.terminal.stdin_tty) == "boolean")
assert(report.identity.mode == "root" and report.identity.root == true)
assert(report.identity.elevated == true and report.identity.via_sudo == true)
assert(report.identity.original_uid == 1000 and report.identity.requested == true)

return true
