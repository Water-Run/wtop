local Engine = require("wtop.engine")
local Export = require("wtop.export")
local Config = require("wtop.config")
local Privilege = require("wtop.privilege")
local json = require("wtop.format.json")
local native = require("wtop.native")

local M = {}

local REPORT_COLLECTORS = {
    system_info = true, cpu_info = true, cpu_limits = true, cpu_clocks = true, memory = true, numa = true,
    memory_devices = true, expansion_slots = true, port_connectors = true,
    onboard_devices = true,
    firmware_batteries = true, firmware_power_supplies = true,
    firmware_enclosures = true,
    platform_firmware = true,
    firmware_bmcs = true,
    firmware_tpms = true,
    firmware_components = true,
    firmware_esrt = true,
    tpm = true,
    watchdog = true,
    rfkill = true,
    typec = true,
    thermal_zones = true,
    host_interfaces = true,
    processor_firmware = true, edac = true, spd = true, disk = true, disk_health = true,
    network = true, wifi = true, gpu = true, cpufreq = true, hwmon = true,
    powercap = true, power_supply = true, inventory = true, displays = true,
}

-- The longest either one-shot JSON invocation deliberately waits between its
-- two samples.  Named, because `docs/AGENT.md` states it and
-- `tests/unit/test_agent_schema.lua` compares the document against this value:
-- written inline as `min(options.interval_ms or 1000, 250)` it was a number the
-- documentation had to repeat without a way to notice it changing.
--
-- It is a *cap on the delay*, not the cost of the invocation.  Measured on the
-- development host, `wtop --agent` takes 1.22-1.25 s at the default interval,
-- of which this is 250 ms: the rest is sampling work.  `--snapshot` uses this
-- same two-tick path and delay, because both modes need interval rates.  The document
-- used to say "normally takes about 250 ms" for the whole invocation, which is
-- this number read as a total, and it was wrong by about five times.  A caller
-- budgeting from it is budgeting from a figure that never included the work.
M.ONESHOT_SAMPLE_DELAY_CAP_MS = 250
M.ONESHOT_ASYNC_SETTLE_CAP_MS = 2250

local function resolve_options(options)
    options = options or {}
    if type(options) ~= "table" then error("application options must be a table", 2) end
    local privilege = type(options.privilege) == "table" and options.privilege
        or Privilege.identity()
    local file_config, status
    if Privilege.restricts_user_files(privilege) then
        file_config = Config.defaults()
        status = { state = "default", reason = "sudo session ignores file configuration" }
    else
        file_config, status = Config.load()
    end
    local resolved = Config.resolve(options, file_config)
    resolved.config_status = status
    resolved.privilege = privilege
    return resolved
end

local function new_engine(options)
    return Engine.new({
        interval_ms = options.interval_ms,
        safe_mode = options.safe_mode,
    })
end

local function collect(options, process_io_rate, selected_collectors)
    options = resolve_options(options)
    local engine = new_engine(options)
    local ok, result = xpcall(function()
        if selected_collectors then
            local registered = {}
            for _, id in ipairs(engine.scheduler.order) do
                registered[#registered + 1] = id
            end
            for _, id in ipairs(registered) do
                if not selected_collectors[id] then engine.scheduler:remove(id) end
            end
            -- The report lists GPU devices, not their per-process fdinfo use.
            engine.context.scan_gpu_processes = false
        end
        if process_io_rate then
            engine.context.scan_process_io_rate = true
            engine.context.scan_routes = true
            engine.context.force_route_refresh = true
        end
        local capabilities = engine:probe()
        engine:tick(true)
        local sleep_ok, slept, sleep_error = pcall(
            native.sleep_ms,
            math.min(options.interval_ms or 1000, M.ONESHOT_SAMPLE_DELAY_CAP_MS))
        if not sleep_ok or not slept then
            error("sampling delay failed: " .. tostring(sleep_ok and sleep_error or slept), 0)
        end
        if process_io_rate then
            -- A one-shot snapshot has only this second sample. The interactive
            -- two-second bulk refresh interval would otherwise hold the first
            -- I/O counters and leave every exported rate as a gap.
            engine.context.force_process_io_refresh = true
        end
        local snapshot = engine:tick(true)
        -- Pending SDK initialization and energy warmup are separate from the
        -- normal rate-sample delay. Poll only scheduled work; don't force every
        -- collector to resample while an optional reader is still starting.
        if engine.has_pending_samples and engine:has_pending_samples() then
            local deadline = engine.clock:now_ns() + M.ONESHOT_ASYNC_SETTLE_CAP_MS * 1000000
            while engine:has_pending_samples() and engine.clock:now_ns() < deadline do
                local remaining = math.ceil((deadline - engine.clock:now_ns()) / 1000000)
                local slept, value, why = pcall(native.sleep_ms, math.max(1, math.min(50, remaining)))
                if not slept or not value then error("sampling delay failed: " .. tostring(slept and why or value), 0) end
                snapshot = engine:tick(false)
            end
        end
        return { snapshot = snapshot, capabilities = capabilities }
    end, debug.traceback)
    engine:stop()
    if not ok then
        error(result, 0)
    end
    return result, options
end

local function closed_pipe(message, errno)
    if errno == 32 or errno == 109 then return true end
    local lower = tostring(message or ""):lower()
    return lower:find("broken pipe", 1, true) ~= nil
        or lower:find("pipe closed", 1, true) ~= nil
end

local function write_json(value, allow_closed_pipe)
    local encoded = json.encode(value)
    local ok, result, write_error, errno = pcall(io.write, encoded, "\n")
    if not ok or not result then
        if allow_closed_pipe and closed_pipe(ok and write_error or result, errno) then
            return false
        end
        error("output write failed: " .. tostring(ok and write_error or result), 0)
    end
    return true
end

function M.snapshot(options)
    local collected, resolved = collect(options, true)
    local result = Export.snapshot(collected.snapshot, {
        process_limit = 50,
        include_remote_addresses = options.include_remote_addresses == true,
        configuration = resolved.config_status,
        privilege = resolved.privilege,
    })
    result.capabilities = Export.capabilities(collected.capabilities)
    write_json(result)
    return 0
end

function M.stream(options)
    local resolved = resolve_options(options)
    local engine = new_engine(resolved)
    local ok, result = xpcall(function()
        engine.context.scan_process_io_rate = true
        engine.context.scan_routes = true
        engine.context.force_route_refresh = true
        local capabilities = engine:probe()
        engine:tick(true)
        engine.context.force_route_refresh = false
        local interval_ns = resolved.interval_ms * 1000000
        local next_due_ns = engine.clock:now_ns() + interval_ns
        local emitted = 0
        while options.stream_count == nil or emitted < options.stream_count do
            local remaining_ns = next_due_ns - engine.clock:now_ns()
            if remaining_ns > 0 then
                local sleep_ok, slept, sleep_error = pcall(native.sleep_ms,
                    math.ceil(remaining_ns / 1000000))
                if not sleep_ok or not slept then
                    error("sampling delay failed: "
                        .. tostring(sleep_ok and sleep_error or slept), 0)
                end
            end
            local started_ns = engine.clock:now_ns()
            if emitted == 0 then engine.context.force_process_io_refresh = true end
            local snapshot = engine:tick(false)
            engine.context.force_process_io_refresh = false
            -- An emission is a new observation point even when no collector
            -- was due. Keep source timestamps and sequence from the engine,
            -- but age retained values against the time this line is written.
            local stream_snapshot = {}
            for key, value in pairs(snapshot) do stream_snapshot[key] = value end
            stream_snapshot.timestamp_ns = engine.clock:now_ns()
            local exported = Export.snapshot(stream_snapshot, {
                process_limit = 50,
                include_remote_addresses = options.include_remote_addresses == true,
                configuration = resolved.config_status,
                privilege = resolved.privilege,
            })
            exported.capabilities = Export.capabilities(capabilities)
            if not write_json(exported, true) then return "closed_pipe" end
            local flush_ok, flushed, flush_error, errno = pcall(io.flush)
            if not flush_ok or not flushed then
                if closed_pipe(flush_ok and flush_error or flushed, errno) then
                    return "closed_pipe"
                end
                error("output flush failed: "
                    .. tostring(flush_ok and flush_error or flushed), 0)
            end
            emitted = emitted + 1
            next_due_ns = started_ns + interval_ns
            local now_ns = engine.clock:now_ns()
            if next_due_ns <= now_ns then next_due_ns = now_ns + interval_ns end
        end
    end, debug.traceback)
    engine:stop()
    if not ok then error(result, 0) end
    return 0
end

function M.record(options)
    if not native.available or type(native.write) ~= "function" then
        error("recording requires the native output transport", 2)
    end
    if native.isatty(1) then error("redirect recording output to a file: wtop --record > sample.wtop", 2) end
    local resolved = resolve_options(options)
    local engine = new_engine(resolved)
    local writer
    local ok, why = xpcall(function()
        local host = assert(native.uname(), "recording platform is unavailable")
        local capabilities = engine:probe()
        local recorded_privilege = {}
        for key, value in pairs(Export.privilege(resolved.privilege)) do recorded_privilege[key] = value end
        writer = require("wtop.recording").writer({ write=native.write,
            include_remote_addresses=options.include_remote_addresses,
            max_bytes=(options.record_limit_mib or 256) * 1024 * 1024,
            metadata={ platform=host.sysname, interval_ms=resolved.interval_ms,
                version=require("wtop.version").version, revision=require("wtop.version").revision,
                host=host, privilege=recorded_privilege, capabilities=capabilities } })
        engine.context.scan_process_io_rate = true
        engine.context.scan_routes = true
        engine:tick(true)
        local emitted = 0
        while not options.stream_count or emitted < options.stream_count do
            local slept, sleep_error = native.sleep_ms(resolved.interval_ms)
            assert(slept, "recording delay failed: " .. tostring(sleep_error))
            if emitted == 0 then engine.context.force_process_io_refresh = true end
            local snapshot = engine:tick(false)
            engine.context.force_process_io_refresh = false
            local appended = writer:append(snapshot, engine.clock:now_ns(), engine.clock.wall_ns(), capabilities)
            if not appended then
                io.stderr:write("wtop: recording size or frame limit reached\n")
                break
            end
            emitted = emitted + 1
        end
        writer:close()
    end, debug.traceback)
    engine:stop()
    if not ok then error(why, 0) end
    return 0
end

function M.replay(options)
    local engine = require("wtop.replay").new(options.replay_path, { frame=options.replay_frame })
    local ok, why = xpcall(function()
        local header = engine.reader.header
        local export_options = { host=header.host or { sysname=header.platform },
            captured_unix_ns=engine.clock.wall_ns(), privilege=header.privilege,
            capabilities=engine.capabilities, include_remote_addresses=options.include_remote_addresses,
            process_limit=options.command == "report" and 0 or 50 }
        local result = options.command == "agent" and Export.agent(engine.snapshot, export_options)
            or Export.snapshot(engine.snapshot, export_options)
        result.observation = { mode="recorded", frame=engine.frame_number, frames=engine.reader.count,
            complete=engine.reader.complete, recorded_version=header.version, recorded_revision=header.revision }
        if options.command == "report" then
            local rendered = "> Recorded measurement: frame " .. engine.frame_number .. "/" .. engine.reader.count
                .. ".\n\n" .. require("wtop.report").render(result)
            local written, error_text = io.write(rendered)
            assert(written, "replay report write failed: " .. tostring(error_text))
        else
            write_json(result)
        end
    end, debug.traceback)
    engine:stop()
    if not ok then error(why, 0) end
    return 0
end

function M.agent(options)
    local collected, resolved = collect(options)
    local result = Export.agent(collected.snapshot, {
        process_limit = 10,
        device_limit = 5,
        workload_limit = 5,
        configuration = resolved.config_status,
        capabilities = collected.capabilities,
        privilege = resolved.privilege,
    })
    write_json(result)
    return 0
end

function M.report(options)
    local collected, resolved = collect(options, false, REPORT_COLLECTORS)
    local exported = Export.snapshot(collected.snapshot, {
        process_limit = 0,
        connection_limit = 0,
        workload_limit = 0,
        configuration = resolved.config_status,
        privilege = resolved.privilege,
    })
    local Report = require("wtop.report")
    local rendered = Report.render(exported)
    local ok, result, write_error = pcall(io.write, rendered)
    if not ok or not result then
        error("output write failed: " .. tostring(ok and write_error or result), 0)
    end
    return 0
end

M.MEMORY_BANDWIDTH_SCHEMA = "dev.waterrun.wtop.memory-bandwidth/v1"

function M.memory_bandwidth(options)
    local resolved = resolve_options(options)
    local Clock = require("wtop.core.clock")
    local Runner = require("wtop.core.runner")
    local Bandwidth = require("wtop.inspectors.ram_bandwidth")
    local Perf = require("wtop.inspectors.perf_bandwidth")
    local Model = require("wtop.inspectors.model")
    local FS = require("wtop.linux.fs")
    local execute = native.run
    if resolved.safe_mode then execute = false end
    local context = { clock = Clock.default, safe_mode = resolved.safe_mode,
        runner = Runner.new({ execute = execute }) }
    local host = native.uname() or {}
    local listing = options.memory_pmu == "list"
    local version = require("wtop.version")
    local output = { schema = M.MEMORY_BANDWIDTH_SCHEMA, mode = listing and "list" or "measure",
        producer = { name = version.name, version = version.version, revision = version.revision },
        platform = host.sysname or "unknown", requested_pmu = options.memory_pmu,
        privilege = { mode = resolved.privilege.mode or "unknown",
            root = resolved.privilege.root == true, requested = resolved.privilege.requested == true } }
    if host.sysname ~= "Linux" then
        output.status = "unavailable"
        output.reason = "unsupported_on_this_platform"
        if listing then output.pmus = json.array({})
        else
            output.result = Model.result("unavailable", nil, json.array({}), { reason = output.reason,
                timestamp_ns = context.clock:now_ns(), provider = "native_platform" })
        end
    else
        local inspector = Bandwidth.new({ clock = context.clock, perf_reader = Perf.for_context(context) })
        if listing then
            local entities, err = inspector:enumerate(context)
            output.pmus = json.array({})
            output.status = entities and "ok" or FS.error_status(err)
            output.reason = not entities and (err and err.message or "read_failed") or nil
            output.pmus_truncated = entities and entities.truncated == true or false
            for _, entity in ipairs(entities or {}) do
                if entity.measurement_scope == "controller_pmu" then
                    output.pmus[#output.pmus + 1] = { id = entity.id, name = entity.name,
                        type = entity.type, source = entity.source,
                        events_truncated = entity.events_truncated == true }
                end
            end
        else
            local entity = options.memory_pmu and { id = options.memory_pmu, measurement_scope = "controller_pmu" }
                or { id = "system-memory", name = "System aggregate", measurement_scope = "system" }
            output.result = inspector:inspect(context, entity)
            output.status, output.reason = output.result.status, output.result.reason
        end
    end
    if listing then
        output.pmus_truncated = output.pmus_truncated == true
        output.result = Model.result(output.status, nil, json.array({}), {
            quality = output.status == "ok" and "fresh" or output.status, reason = output.reason,
            timestamp_ns = context.clock:now_ns(), provider = host.sysname == "Linux" and "pmu_sysfs" or "native_platform" })
    end
    output.captured_monotonic_ns = context.clock:now_ns()
    output.captured_unix_ns = context.clock:wall_ns()
    write_json(output)
    return 0
end

function M.run(options)
    local Tui = require("wtop.tui")
    local resolved = resolve_options(options)
    resolved.replay_path = options and options.replay_path
    resolved.replay_frame = options and options.replay_frame
    return Tui.run(resolved)
end

M.resolve_options = resolve_options

return M
