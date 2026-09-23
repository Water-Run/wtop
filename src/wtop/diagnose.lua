local json = require("wtop.format.json")
local native = require("wtop.native")
local Privilege = require("wtop.privilege")
local system = require("wtop.system")
local version = require("wtop.version")

local M = {}

local HELPERS = {
    "nvidia-smi",
    "rocm-smi",
    "intel_gpu_top",
    "smartctl",
    "nvme",
    "perf",
    "systemctl",
    "ss",
    "sensors",
    "lspci",
}

local function probe_file(path)
    if system.readable(path) then
        return { state = "available", path = path }
    elseif system.exists(path) then
        return { state = "denied", path = path }
    end
    return { state = "unavailable", path = path }
end

local function probe_native(name)
    return {
        state = type(native[name]) == "function" and "available" or "unavailable",
        path = "native:" .. name,
    }
end

function M.collect(options)
    options = options or {}
    if type(options) ~= "table" then error("diagnose options must be a table", 2) end
    local uname = native.uname()
    local privilege = type(options.privilege) == "table" and options.privilege
        or Privilege.identity()
    local report = {
        application = {
            name = version.name,
            version = version.version,
            lua = _VERSION,
        },
        platform = uname or { sysname = "unknown" },
        native = {
            state = native.available and "available" or "unavailable",
            version = native.VERSION,
            reason = native.error,
        },
        identity = {
            mode = privilege.mode,
            uid = privilege.uid,
            effective_uid = privilege.effective_uid,
            original_uid = privilege.original_uid,
            root = privilege.root == true,
            elevated = privilege.elevated == true,
            via_sudo = privilege.via_sudo == true,
            requested = privilege.requested == true,
        },
        terminal = {
            stdin_tty = native.isatty(0),
            stdout_tty = native.isatty(1),
        },
        sources = {},
        helpers = {},
        safe_mode = options.safe_mode == true,
    }

    if uname and uname.sysname == "Linux" then
        report.sources = {
            proc_stat = probe_file("/proc/stat"),
            proc_cpuinfo = probe_file("/proc/cpuinfo"),
            proc_meminfo = probe_file("/proc/meminfo"),
            proc_pressure = probe_file("/proc/pressure/cpu"),
            sys_block = probe_file("/sys/block"),
            sys_cpufreq = probe_file("/sys/devices/system/cpu/cpufreq"),
            sys_hwmon = probe_file("/sys/class/hwmon"),
            sys_powercap = probe_file("/sys/class/powercap"),
            sys_dmi = probe_file("/sys/class/dmi/id"),
            sys_power_supply = probe_file("/sys/class/power_supply"),
            proc_uptime = probe_file("/proc/uptime"),
            proc_vmstat = probe_file("/proc/vmstat"),
            etc_passwd = probe_file("/etc/passwd"),
            drm = probe_file("/sys/class/drm"),
            cgroup_v2 = probe_file("/sys/fs/cgroup/cgroup.controllers"),
            perf_pmu = probe_file("/sys/bus/event_source/devices"),
        }
    else
        for _, name in ipairs({
            "collect_cpu", "collect_cpu_info", "collect_memory", "collect_process",
            "collect_disk", "collect_mounts", "collect_network", "collect_system_info",
        }) do
            report.sources[name] = probe_native(name)
        end
    end

    if report.terminal.stdout_tty then
        local columns, rows = native.terminal_size()
        report.terminal.columns = columns
        report.terminal.rows = rows
    end

    for _, helper in ipairs(uname and uname.sysname == "Linux" and HELPERS or {}) do
        local path = system.find_executable(helper)
        report.helpers[helper] = {
            state = options.safe_mode and "disabled" or (path and "available" or "unavailable"),
            path = path,
        }
    end
    return report
end

local function print_section(name, values)
    io.write(name, ":\n")
    local keys = {}
    for key in pairs(values) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local value = values[key]
        if type(value) == "table" then
            local suffix = value.path and (" (" .. value.path .. ")") or ""
            io.write(string.format("  %-18s %s%s\n", key, tostring(value.state or "present"), suffix))
        else
            io.write(string.format("  %-18s %s\n", key, tostring(value)))
        end
    end
end

function M.run(options)
    local report = M.collect(options)
    if options and options.json then
        io.write(json.encode(report), "\n")
        return 0
    end

    io.write(report.application.name, " ", report.application.version, " diagnostics\n")
    io.write("  Lua:      ", report.application.lua, "\n")
    io.write("  Platform: ", tostring(report.platform.sysname), " ", tostring(report.platform.release or ""),
        " ", tostring(report.platform.machine or ""), "\n")
    io.write("  Native:   ", report.native.state, " (", tostring(report.native.version), ")\n")
    io.write("  UID:      ", tostring(report.identity.effective_uid), "\n")
    local access = report.platform.sysname == "Windows" and report.identity.elevated
        and "administrator" or tostring(report.identity.mode)
    io.write("  Access:   ", access,
        report.identity.via_sudo and " (sudo)" or "", "\n")
    io.write("  TTY:      stdin=", tostring(report.terminal.stdin_tty),
        " stdout=", tostring(report.terminal.stdout_tty), "\n")
    print_section("Sources", report.sources)
    print_section("Optional helpers", report.helpers)
    return 0
end

return M
