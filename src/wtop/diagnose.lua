local json = require("wtop.format.json")
local native = require("wtop.native")
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

function M.collect(options)
    options = options or {}
    if type(options) ~= "table" then error("diagnose options must be a table", 2) end
    local uname = native.uname()
    local real_uid, effective_uid = native.uid()
    if type(real_uid) ~= "number" then real_uid = nil end
    if type(effective_uid) ~= "number" then effective_uid = nil end
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
            uid = real_uid,
            effective_uid = effective_uid,
        },
        terminal = {
            stdin_tty = native.isatty(0),
            stdout_tty = native.isatty(1),
        },
        sources = {
            proc_stat = probe_file("/proc/stat"),
            proc_meminfo = probe_file("/proc/meminfo"),
            proc_pressure = probe_file("/proc/pressure/cpu"),
            sys_block = probe_file("/sys/block"),
            drm = probe_file("/sys/class/drm"),
            cgroup_v2 = probe_file("/sys/fs/cgroup/cgroup.controllers"),
            perf_pmu = probe_file("/sys/bus/event_source/devices"),
        },
        helpers = {},
        safe_mode = options.safe_mode == true,
    }

    if report.terminal.stdout_tty then
        local columns, rows = native.terminal_size()
        report.terminal.columns = columns
        report.terminal.rows = rows
    end

    for _, helper in ipairs(HELPERS) do
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
    io.write("  TTY:      stdin=", tostring(report.terminal.stdin_tty),
        " stdout=", tostring(report.terminal.stdout_tty), "\n")
    print_section("Sources", report.sources)
    print_section("Optional helpers", report.helpers)
    return 0
end

return M
