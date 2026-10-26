local root=assert(arg[1])
package.path=root.."/src/?.lua;"..root.."/src/?/init.lua;"..package.path
local native=require("wtop.native")
local wire=require("wtop.core.worker_wire")
local sessions={}
local names={"hwmon","cpufreq","powercap","cpu_limits","thermal_throttle","cpuidle","thermal_zones","smbios_input","gpu_drm","cpu_clocks","cppc"}
if type(native.hardware_worker_sources)=="table" then
    names={};for name in pairs(native.hardware_worker_sources)do names[#names+1]=name end;table.sort(names)
end
for _, name in ipairs(names) do
    local configuration=name=="cpuid"and{targets={{id=0}}}or{}
    local session=native.hardware_worker_open(name,wire.encode(configuration))
    native.hardware_worker_query(session,false)
    sessions[#sessions+1]=session
end
if arg[2]=="hold" then
    print(native.pid());io.stdout:flush();assert(io.read("l")=="close")
end
for _, session in ipairs(sessions) do native.hardware_worker_close(session,0) end
-- Exercise the standalone interpreter's real CLIBS/module finalization while
-- controller threads are still allowed to reap. No C harness holds the DSO.
os.exit(0,true)
