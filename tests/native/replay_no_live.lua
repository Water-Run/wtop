-- Run the real terminal with every live inspection boundary made observable.
local Native = require("wtop.native")
local function forbidden() error("replay attempted live inspection", 2) end
for name, value in pairs(Native) do
    if type(value) == "function" and (name:match("^collect_") or name == "run"
        or name == "signal_process" or name == "setpriority" or name == "hardware_worker_open"
        or name == "gpu_worker_open" or name == "read_cpu_clock_counters"
        or name:match("^perf_")) then Native[name] = forbidden end
end
local FS = require("wtop.linux.fs")
for _, name in ipairs({"read","list","readlink"}) do
    local old = FS.default[name]
    if old then FS.default[name] = function(self, path, ...)
        if type(path) == "string" and (path:match("^/proc/") or path:match("^/sys/")) then forbidden() end
        return old(self, path, ...)
    end end
end
require("wtop.system").find_executable = forbidden
local code = require("wtop.cli").run(arg)
assert(code == 0)
print("REPLAY_NO_LIVE_READS_PASSED")
