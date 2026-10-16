package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local saved = {}
for _, name in ipairs({"wtop.native", "wtop.cli", "wtop.core.hardware_worker"}) do saved[name] = package.loaded[name] end
local original_arg, original_exit = arg, os.exit
local original_path, original_cpath = package.path, package.cpath
local function bootstrap(arguments, worker)
    local configured, ran_cli, ran_worker = false, false, false
    local adapter = {available = true}
    function adapter.hardware_worker_configure(entry)
        assert(not worker)
        assert(entry == (arguments[-1] and arguments[0] or nil))
        configured = true
        return {cpufreq = true}
    end
    function adapter.hardware_worker_run(...)
        assert(worker and not configured)
        assert(select("#", ...) == 5)
        local parent, cancel, input, output, source = ...
        assert(parent == "1" and cancel == "2" and input == "3" and output == "4" and source == "cpufreq")
        ran_worker = true
        return 0
    end
    package.loaded["wtop.native"] = adapter
    package.loaded["wtop.core.hardware_worker"] = function() error("the native runner owns initialization") end
    package.loaded["wtop.cli"] = {run = function(received)
        assert(not worker and configured and received == arguments)
        assert(adapter.hardware_worker_sources.cpufreq)
        ran_cli = true
        return 0
    end}
    arg = arguments
    os.exit = function(code, close) assert(code == 0 and close == true);error({exit = true}, 0) end
    local ok, reason = pcall(assert(loadfile("src/wtop.lua")))
    assert(not ok and type(reason) == "table" and reason.exit)
    assert(ran_worker == worker and ran_cli ~= worker)
    package.path, package.cpath = original_path, original_cpath
end
bootstrap({[-1] = "C:/runtime/lua.exe", [0] = "C:/source/src/wtop.lua", "--snapshot"}, false)
bootstrap({[0] = "C:/Program Files/wtop/wtop.exe", "--snapshot"}, false)
bootstrap({[0] = "C:/Program Files/wtop/wtop-onefile.exe", "--wtop-hardware-reader", "1", "2", "3", "4", "cpufreq"}, true)
arg, os.exit = original_arg, original_exit

-- A reader uses the complete Windows adapter directly. Advertising the same
-- source in its native table must not recursively start another process.
local calls = 0
local adapter = {available = true, hardware_worker_sources = {cpufreq = true}}
function adapter.uname() return {sysname = "Windows"} end
function adapter.monotonic_ns() return 123456 end
adapter.realtime_ns = adapter.monotonic_ns
function adapter.collect_cpufreq() calls = calls + 1;return {policies = {}} end
function adapter.hardware_worker_open() error("recursive reader") end
package.loaded["wtop.native"] = adapter
package.loaded["wtop.core.hardware_worker"] = nil
local run = require("wtop.core.hardware_worker")("cpufreq", require("wtop.core.worker_wire").encode({}))
local message = require("wtop.core.worker_wire").decode(run(false, false))
assert(calls == 1 and message.result.status == "ok" and message.result.data.policies)
for name, value in pairs(saved) do package.loaded[name] = value end
if saved["wtop.native"] == nil then package.loaded["wtop.native"] = nil end
if saved["wtop.cli"] == nil then package.loaded["wtop.cli"] = nil end
if saved["wtop.core.hardware_worker"] == nil then package.loaded["wtop.core.hardware_worker"] = nil end
package.path, package.cpath = original_path, original_cpath
return true
