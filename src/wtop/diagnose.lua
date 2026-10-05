local json = require("wtop.format.json")
local native = require("wtop.native")
local Clock = require("wtop.core.clock")
local PciNames = require("wtop.linux.pci_names")
local Privilege = require("wtop.privilege")
local system = require("wtop.system")
local version = require("wtop.version")

local M = {}

-- The external commands wtop actually executes, and nothing else.
--
-- Every entry here is reachable from an inspector: `smartctl` and `nvme` from
-- the storage inspector, `perf` from the bandwidth inspector, `systemctl` from
-- the service inspector.  A binary wtop never runs is not a helper but a
-- coincidence -- `nvidia-smi` and `rocm-smi` are superseded by the libraries
-- below, `intel_gpu_top` and `sensors` by the i915 and hwmon reads it does
-- itself, and `ss` by the `/proc/net` tables the socket collector parses.
--
-- The one that was doing real harm is `lspci`.  Its job -- turning a PCI id
-- into a vendor and a device name -- is done here by reading the system's
-- `pci.ids` database, which is a *source* and is probed as one below.  So the
-- diagnostic could reassure a user about a tool wtop ignores while staying
-- silent about the file that decides whether the GPU table shows "Intel
-- Corporation" or nothing at all.
local HELPERS = {
    "smartctl",
    "nvme",
    "perf",
    "systemctl",
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

--- The first of several equivalent files that exists, named in the report.
--
-- A source with fallback paths has no single location to print, and reporting
-- only the first would say `unavailable` on a host that has the second.  When
-- none is there the first path is named, so the line still says what was looked
-- for rather than going blank.
local function probe_first_file(paths)
    for _, path in ipairs(paths) do
        if system.readable(path) then
            return { state = "available", path = path }
        end
    end
    for _, path in ipairs(paths) do
        if system.exists(path) then
            return { state = "denied", path = path }
        end
    end
    return { state = "unavailable", path = paths[1] }
end

-- Which GPU vendor backends this build can actually reach, and why not when it
-- cannot.
--
-- The `rocm-smi` and `nvidia-smi` entries above answer a different question than
-- the one a user brings to a diagnostic: wtop never runs either binary.  It
-- dlopens `libnvidia-ml.so.1`, `libamdsmi.so.1` and `libze_loader.so.1` at run
-- time, and a host can have the command-line tool installed and the library
-- absent, or -- the case this host demonstrates -- `rocm-smi` present with no
-- `libamdsmi.so.1` at all, so wtop has no AMD backend while the helper line
-- reads `available`.  A shared library also cannot be probed like a source file:
-- it is found through the dynamic loader's search path, not at a fixed path, so
-- `system.readable` on a guessed location would answer a question nobody asked.
--
-- So this asks the only question worth asking, by doing the thing itself: it
-- calls the same native entry point the collector calls, and the native layer
-- already distinguishes a library that was not found from one whose symbols are
-- missing from one that failed to initialise.  That also keeps the diagnostic
-- honest about which vendors exist at all -- a machine with no NVIDIA hardware
-- gets a different answer from one whose driver is installed but whose library
-- will not load, and only the second is a problem worth reporting.
local VENDOR_PROBES = {
    { key = "nvml", label = "nvidia", query = "nvml_query", library = "libnvidia-ml.so.1" },
    { key = "amdsmi", label = "amd", query = "amdsmi_query", library = "libamdsmi.so.1" },
    { key = "levelzero", label = "intel", query = "levelzero_query", library = "libze_loader.so.1" },
}

local function probe_vendor(entry, safe_mode)
    local result = { library = entry.library }
    if type(native[entry.query]) ~= "function" then
        -- The native module was built without this backend.  That is a build
        -- fact rather than a host one, and saying so stops it from being read
        -- as "this machine has no such GPU".
        result.state = "uncompiled"
        return result
    end
    if safe_mode then
        result.state = "skipped"
        result.reason = "safe_mode"
        return result
    end
    local ok, data, reason = pcall(native[entry.query], false)
    if not ok then
        result.state = "error"
        result.reason = tostring(data)
        return result
    end
    if data then
        local devices = type(data.devices) == "table" and #data.devices or 0
        result.state = devices > 0 and "available" or "loaded"
        result.devices = devices
        if data.driver_version or data.driver then
            result.version = data.driver_version or data.driver
        end
        return result
    end
    result.state = "unavailable"
    result.reason = reason
    return result
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
            revision = version.revision,
            lua = _VERSION,
        },
        -- Which clock the monitor is actually timing against.  This is not the
        -- same fact as `sources.proc_uptime` below, which says whether
        -- /proc/uptime is readable *at the moment the diagnostic runs*: the
        -- clock is a process-wide instance that has already been sampling, and
        -- a read that started failing leaves it on a fallback or holding a
        -- stale value for as long as the failure lasts.  A user whose rates have
        -- frozen needs to know which of the three it is looking at, and the
        -- source name is the only place that is written down.  The read below
        -- is deliberate: a diagnostic that reported the clock's state without
        -- taking a reading would report "no source" on every host, because
        -- nothing has sampled yet.
        clock = {
            source = Clock.default_now_ns() and Clock.default:source_name()
                or "unavailable",
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
        gpu_vendors = {},
        safe_mode = options.safe_mode == true,
    }

    -- Without the native module the host is unknown; the Linux file probes
    -- still answer truthfully there, while macOS and Windows use native ones.
    local linux_sources = not uname or uname.sysname == "Linux"
    if linux_sources then
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
            -- The PCI name database, not `lspci`.  Without it every vendor and
            -- device name in the GPU table is nil rather than wrong, which is
            -- exactly the kind of blank cell a user brings to a diagnostic with
            -- no way to tell a missing database from an unidentified device.
            pci_ids = probe_first_file(PciNames.DEFAULT_PATHS),
        }
    else
        for _, name in ipairs({
            "collect_cpu", "collect_cpu_info", "collect_memory", "collect_process",
            "collect_disk", "collect_mounts", "collect_network", "collect_connections",
            "collect_system_info",
        }) do
            report.sources[name] = probe_native(name)
        end
    end

    if report.terminal.stdout_tty then
        local columns, rows = native.terminal_size()
        report.terminal.columns = columns
        report.terminal.rows = rows
    end

    for _, helper in ipairs(linux_sources and HELPERS or {}) do
        local path = system.find_executable(helper)
        report.helpers[helper] = {
            state = options.safe_mode and "disabled" or (path and "available" or "unavailable"),
            path = path,
        }
    end

    -- The vendor backends are probed only on Linux, because that is the only
    -- host where wtop dlopens a vendor library; on the other two the native
    -- collectors report the vendor themselves.
    if linux_sources then
        for _, entry in ipairs(VENDOR_PROBES) do
            report.gpu_vendors[entry.key] = probe_vendor(entry, options.safe_mode == true)
        end
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
    io.write("  Clock:    ", tostring(report.clock.source), "\n")
    io.write("  UID:      ", tostring(report.identity.effective_uid), "\n")
    local access = report.platform.sysname == "Windows" and report.identity.elevated
        and "administrator" or tostring(report.identity.mode)
    io.write("  Access:   ", access,
        report.identity.via_sudo and " (sudo)" or "", "\n")
    io.write("  TTY:      stdin=", tostring(report.terminal.stdin_tty),
        " stdout=", tostring(report.terminal.stdout_tty), "\n")
    print_section("Sources", report.sources)
    print_section("Optional helpers", report.helpers)
    if next(report.gpu_vendors) then
        -- Its own printer because a vendor line carries more than a state: the
        -- library it tried, how many devices the backend then found, and the
        -- reason when it could not get that far.  Without those, "unavailable"
        -- cannot be told apart from "this machine has no such GPU", which is
        -- the distinction the section exists to draw.
        io.write("GPU vendor libraries:\n")
        local keys = {}
        for key in pairs(report.gpu_vendors) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local value = report.gpu_vendors[key]
            local detail = {}
            if value.devices ~= nil then
                detail[#detail + 1] = string.format("%d device(s)", value.devices)
            end
            if value.version then detail[#detail + 1] = tostring(value.version) end
            if value.reason then detail[#detail + 1] = tostring(value.reason) end
            local suffix = #detail > 0 and (" (" .. table.concat(detail, ", ") .. ")") or ""
            io.write(string.format("  %-18s %s%s\n", key,
                tostring(value.state), suffix))
        end
    end
    return 0
end

return M
