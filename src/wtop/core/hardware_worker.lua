-- Runs in the exec'd hardware reader, using its own clock and collector state.
local Wire = require("wtop.core.worker_wire")
local Native = require("wtop.native")

-- Literal constructors keep the child entry graph discoverable in both
-- directory and onefile bundles without running platform-specific readers.
local constructors = {
    hwmon = function(o) return require("wtop.collectors.hwmon").new(o) end,
    power_supply = function(o) return require("wtop.collectors.power_supply").new(o) end,
    typec = function(o) return require("wtop.collectors.typec").new(o) end,
    ram_bandwidth = function(o) return require("wtop.collectors.ram_bandwidth").new(o) end,
    spd = function(o) return require("wtop.collectors.spd").new(o) end,
    cpufreq = function(o) return require("wtop.collectors.cpufreq").new(o) end,
    powercap = function(o) return require("wtop.collectors.powercap").new(o) end,
    cpu_limits = function(o) return require("wtop.collectors.cpu_limits").new(o) end,
    thermal_throttle = function(o) return require("wtop.collectors.thermal_throttle").new(o) end,
    cppc = function(o) return require("wtop.collectors.cppc").new(o) end,
    cpuidle = function(o) return require("wtop.collectors.cpuidle").new(o) end,
    thermal_zones = function(o) return require("wtop.collectors.thermal_zones").new(o) end,
    smbios_input = function(o) return require("wtop.collectors.smbios_input").new(o) end,
    gpu_drm = function(o) return require("wtop.collectors.gpu_drm").new(o) end,
    cpuid = function(o) return require("wtop.collectors.cpuid").new(o) end,
    cpu_clocks = function(o) return require("wtop.collectors.cpu_clocks").new(o) end,
    disk_health = function(o) return require("wtop.collectors.linux_nvme").new(o) end,
    wifi = function(o) return require("wtop.collectors.wifi").new(o) end,
    displays = function(o) return require("wtop.collectors.drm_displays").new(o) end,
}

return function(id, configuration)
    local options = Wire.decode(configuration)
    assert(type(options) == "table", "hardware_configuration")
    local collector
    local platform = require("wtop.platform").id(Native)
    if platform == "macos" or platform == "windows" then
        options.native = Native
        options._hardware_direct = true
        if id == "disk_health" and platform == "windows" then
            collector = require("wtop.collectors.windows_storage").new(options)
        else collector = require("wtop.collectors.portable").new(id, options) end
    else
        collector = assert(constructors[id], "hardware_collector")(options)
    end
    local previous
    return function(safe_mode, scan_gpu_processes)
        local context = { safe_mode = safe_mode, scan_gpu_processes = scan_gpu_processes, native = Native,
            clock = { now_ns = Native.monotonic_ns, wall_ns = Native.realtime_ns } }
        local capability = collector:probe(context)
        local result = collector:sample(context, previous)
        previous = result
        return Wire.encode({ capability = result.capability or capability, result = result })
    end
end
