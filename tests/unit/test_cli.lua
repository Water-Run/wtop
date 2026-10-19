package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local cli = require("wtop.cli")

local defaults = assert(cli.parse({}))
assert(defaults.command == "tui")
assert(defaults.interval_ms == 1000)
assert(defaults.color == true)

local configured = assert(cli.parse({
    "--lang", "zh-CN",
    "--theme", "water-dark",
    "--interval", "100",
    "--safe-mode",
    "--no-color",
}))
assert(configured.locale == "zh-CN")
assert(configured.theme == "water-dark")
assert(configured.interval_ms == 100)
assert(configured.safe_mode == true)
assert(configured.color == false)
assert(assert(cli.parse({ "--theme", "lua-blue" })).theme == "lua-blue")

local elevated = assert(cli.parse({ "--sudo", "--snapshot" }))
assert(elevated.elevate == true and elevated.command == "snapshot")
assert(assert(cli.parse({ "--elevate" })).elevate == true)
assert(cli.parse({ "--sudo", "--sudo" }) == nil)
assert(cli.parse({ "--sudo", "--elevate" }) == nil)

assert(cli.parse({ "--interval", "99" }) == nil)
assert(cli.parse({ "--interval", "10.5" }) == nil)
assert(cli.parse({ "--lang" }) == nil)
assert(cli.parse({ "--lang", "en--US" }) == nil)
assert(assert(cli.parse({ "--lang", "zh_CN.UTF-8" })).locale == "zh-CN")
assert(cli.parse({ "--theme", "water" }) == nil)
assert(cli.parse({ "--unknown" }) == nil)
assert(cli.parse(nil) == nil)
assert(cli.parse({ 42 }) == nil)
assert(cli.parse({ "--snapshot", "--agent" }) == nil)
assert(cli.parse({ "--help", "--help" }) == nil)

assert(assert(cli.parse({ "--help" })).command == "help")
assert(assert(cli.parse({ "--version" })).command == "version")
assert(assert(cli.parse({ "--diagnose" })).command == "diagnose")
assert(assert(cli.parse({ "--snapshot" })).command == "snapshot")
assert(assert(cli.parse({ "--stream" })).command == "stream")
assert(assert(cli.parse({ "--stream", "--count", "2" })).stream_count == 2)
assert(assert(cli.parse({ "--count", "2", "--stream" })).stream_count == 2)
assert(cli.parse({ "--count", "2" }) == nil)
assert(cli.parse({ "--stream", "--count", "0" }) == nil)
assert(cli.parse({ "--stream", "--count", "1000001" }) == nil)
assert(cli.parse({ "--stream", "--count", "2", "--count", "3" }) == nil)
assert(assert(cli.parse({ "--report" })).command == "report")
assert(assert(cli.parse({ "--memory-bandwidth" })).command == "memory_bandwidth")
assert(assert(cli.parse({ "--memory-bandwidth", "--memory-pmu", "list" })).memory_pmu == "list")
assert(assert(cli.parse({ "--memory-pmu", "uncore_imc_free_running_0", "--memory-bandwidth" })).memory_pmu == "uncore_imc_free_running_0")
assert(cli.parse({ "--memory-pmu", "uncore_imc_0" }) == nil)
assert(cli.parse({ "--memory-bandwidth", "--snapshot" }) == nil)
assert(cli.parse({ "--memory-bandwidth", "--memory-pmu", "../uncore_imc_0" }) == nil)
assert(cli.parse({ "--memory-bandwidth", "--memory-pmu", "uncore_imc_0,other" }) == nil)
assert(cli.parse({ "--memory-bandwidth", "--memory-pmu", string.rep("x", 256) }) == nil)
assert(cli.parse({ "--memory-bandwidth", "--memory-pmu", "list", "--memory-pmu", "list" }) == nil)
assert(cli.parse({ "--memory-bandwidth", "--unmask-remote-addresses" }) == nil)
assert(assert(cli.parse({ "--agent" })).command == "agent")
assert(cli.parse({ "--report", "--snapshot" }) == nil)
assert(cli.parse({ "--stream", "--snapshot" }) == nil)
assert(cli.parse({ "--report", "--unmask-remote-addresses" }) == nil)

local unmasked = assert(cli.parse({ "--snapshot", "--unmask-remote-addresses" }))
assert(unmasked.command == "snapshot" and unmasked.include_remote_addresses == true)
assert(assert(cli.parse({ "--unmask-remote-addresses", "--snapshot" }))
    .include_remote_addresses == true,
    "flag order must not matter for the end-of-parse command check")
assert(assert(cli.parse({ "--snapshot" })).include_remote_addresses == nil)
assert(assert(cli.parse({ "--stream", "--unmask-remote-addresses" }))
    .include_remote_addresses == true)
assert(cli.parse({ "--unmask-remote-addresses" }) == nil,
    "unmasking without --snapshot has nothing to affect")
assert(cli.parse({ "--unmask-remote-addresses", "--agent" }) == nil)
assert(cli.parse({ "--unmask-remote-addresses", "--snapshot",
    "--unmask-remote-addresses" }) == nil)

assert(cli.requires_elevation({ command = "tui", elevate = true }, { root = false }))
assert(cli.requires_elevation({ command = "snapshot", elevate = true }, { root = false }))
assert(not cli.requires_elevation({ command = "help", elevate = true }, { root = false }))
assert(not cli.requires_elevation({ command = "version", elevate = true }, { root = false }))
assert(not cli.requires_elevation({ command = "tui", elevate = true }, { root = true }))

local elevation_calls = 0
local fake_identity = { mode = "user", root = false }
local code = cli.run({ "--sudo", "--diagnose" }, {
    platform = { require_linux = function() return true end },
    privilege = {
        identity = function() return fake_identity end,
        elevate = function()
            elevation_calls = elevation_calls + 1
            return true
        end,
    },
})
assert(code == 0 and elevation_calls == 1)
assert(fake_identity.requested == true)

-- The readable report must not pay for collectors it never renders. Its two
-- samples still run the selected hardware sources, while Linux GPU fdinfo
-- process scanning stays off.
local Engine = require("wtop.engine")
local Native = require("wtop.native")
local original_engine_new, original_sleep = Engine.new, Native.sleep_ms
local original_write = io.write
local removed, sampled, stopped = {}, 0, false
local fake_engine = {
    context = {},
    scheduler = {
        order = { "cpu", "cpu_info", "memory", "disk", "network", "gpu",
            "process", "connections", "cgroup", "mounts", "pressure",
            "system_info", "inventory", "power_supply" },
        remove = function(self, id)
            removed[id] = true
            for index, current in ipairs(self.order) do
                if current == id then table.remove(self.order, index); return true end
            end
            return false
        end,
    },
    probe = function(self)
        assert(removed.process and removed.connections and removed.cgroup
            and removed.mounts and removed.pressure and removed.cpu)
        assert(not removed.cpu_info and not removed.memory and not removed.disk
            and not removed.gpu and not removed.system_info)
        assert(self.context.scan_gpu_processes == false)
        return {}
    end,
    tick = function()
        sampled = sampled + 1
        return { sequence = sampled, timestamp_ns = sampled,
            quality = { cpu_info = { status = "ok", quality = "fresh" } } }
    end,
    stop = function() stopped = true end,
}
Engine.new = function() return fake_engine end
Native.sleep_ms = function() return true end
local written = {}
io.write = function(...) written[#written + 1] = table.concat({ ... }); return true end
local Application = require("wtop.application")
assert(Application.report({ explicit = { interval_ms = true }, interval_ms = 100,
    privilege = { via_sudo = true, root = true } }) == 0)
io.write, Engine.new, Native.sleep_ms = original_write, original_engine_new, original_sleep
assert(sampled == 2 and stopped and table.concat(written):find("# wtop hardware report", 1, true))

-- A bounded stream writes independently parseable Snapshot lines, honours the
-- requested cadence and cleans up the engine when a wait fails.
local Snapshot = require("wtop.model.snapshot")
local JSON = require("wtop.core.json")
local original_flush = io.flush
local now_ns, stream_ticks, stream_stopped, flushes = 0, 0, false, 0
local sleeps, lines = {}, {}
Engine.new = function()
    return {
        context = {}, clock = { now_ns = function() return now_ns end },
        probe = function() return {} end,
        tick = function(_, force)
            stream_ticks = stream_ticks + 1
            assert((stream_ticks == 1) == (force == true),
                "only the baseline forces all collectors")
            if stream_ticks > 1 then
                assert(_.context.force_route_refresh == false,
                    "route inventory follows its refresh cadence after the baseline")
            end
            return Snapshot.new(stream_ticks, now_ns)
        end,
        stop = function() stream_stopped = true end,
    }
end
Native.sleep_ms = function(ms)
    sleeps[#sleeps + 1] = ms
    now_ns = now_ns + ms * 1000000
    return true
end
io.write = function(...) lines[#lines + 1] = table.concat({ ... }); return true end
io.flush = function() flushes = flushes + 1; return true end
local stream_options = assert(cli.parse({ "--stream", "--count", "2",
    "--interval", "100" }))
stream_options.privilege = { root = true }
assert(Application.stream(stream_options) == 0)
assert(stream_ticks == 3 and stream_stopped and flushes == 2
    and #sleeps == 2 and sleeps[1] == 100 and sleeps[2] == 100
    and #lines == 2)
local first_line = assert(JSON.decode(lines[1]))
local second_line = assert(JSON.decode(lines[2]))
assert(first_line.schema == "dev.waterrun.wtop.snapshot/v1"
    and first_line.sequence == 2 and second_line.sequence == 3
    and first_line.captured_monotonic_ns < second_line.captured_monotonic_ns)
now_ns, stream_ticks, stream_stopped, flushes = 0, 0, false, 0
sleeps, lines = {}, {}
Engine.new = function()
    local retained
    return {
        context = {}, clock = { now_ns = function() return now_ns end },
        probe = function() return {} end,
        tick = function()
            stream_ticks = stream_ticks + 1
            if stream_ticks == 1 then return Snapshot.new(1, now_ns) end
            if not retained then
                retained = Snapshot.new(2, now_ns)
                retained.quality.cpu = { status = "ok", quality = "fresh",
                    timestamp_ns = now_ns, value_timestamp_ns = now_ns }
            end
            return retained
        end,
        stop = function() stream_stopped = true end,
    }
end
assert(Application.stream(stream_options) == 0 and stream_stopped and #lines == 2)
local held_first = assert(JSON.decode(lines[1]))
local held_second = assert(JSON.decode(lines[2]))
assert(held_first.sequence == held_second.sequence
    and held_second.captured_monotonic_ns > held_first.captured_monotonic_ns
    and held_second.quality.cpu.value_age_ms > held_first.quality.cpu.value_age_ms,
    "a held source ages on each emitted line without inventing a new sample")
stream_stopped = false
io.write = function() return nil, "Broken pipe", 32 end
assert(Application.stream(stream_options) == 0 and stream_stopped,
    "a consumer closing the stream is a normal shutdown")
io.write = function(...) lines[#lines + 1] = table.concat({ ... }); return true end
io.flush = function() return nil, "Broken pipe", 32 end
stream_stopped = false
assert(Application.stream(stream_options) == 0 and stream_stopped,
    "a pipe closing during flush also stops the stream")
io.flush = function() flushes = flushes + 1; return true end
io.write = function() return nil, "disk full", 28 end
stream_stopped = false
assert(not pcall(Application.stream, stream_options) and stream_stopped,
    "a genuine output error is still reported after cleanup")
io.write = function(...) lines[#lines + 1] = table.concat({ ... }); return true end
stream_stopped = false
Native.sleep_ms = function() return nil, "refused" end
assert(not pcall(Application.stream, stream_options) and stream_stopped,
    "a failed cadence wait still stops the stream engine")
io.write, io.flush, Engine.new, Native.sleep_ms =
    original_write, original_flush, original_engine_new, original_sleep

-- Directory and onefile launchers start with an incremental Lua state. The
-- application must use the same mode as standalone Lua before either entry.
do
    local function entry_mode(initial_mode, reader)
        local previous_mode = collectgarbage(initial_mode)
        local previous_arg, previous_exit = arg, os.exit
        local previous_path, previous_cpath = package.path, package.cpath
        local names = { "wtop.native", "wtop.cli", "wtop.core.hardware_worker" }
        local previous = {}
        for _, name in ipairs(names) do previous[name] = package.loaded[name] end
        local stopped, exit_code, observed_mode = {}, nil, nil
        local called_cli, called_reader = false, false
        arg = { [0] = "src/wtop.lua", reader and "--wtop-hardware-reader" or "--version", "fixture" }
        local function capture() observed_mode = collectgarbage("generational") end
        package.loaded["wtop.native"] = {
            hardware_worker_run = function(value)
                assert(value == "fixture")
                called_reader = true; capture(); return 0
            end,
            hardware_worker_configure = function(value) assert(value == nil); return {} end,
        }
        package.loaded["wtop.cli"] = { run = function(arguments)
            assert(arguments == arg)
            called_cli = true; capture(); return 0
        end }
        package.loaded["wtop.core.hardware_worker"] = {}
        os.exit = function(code, close)
            assert(close == true); exit_code = code; error(stopped, 0)
        end
        local ok, result = pcall(function() assert(loadfile("src/wtop.lua"))() end)
        arg, os.exit = previous_arg, previous_exit
        package.path, package.cpath = previous_path, previous_cpath
        for _, name in ipairs(names) do package.loaded[name] = previous[name] end
        collectgarbage(previous_mode)
        assert(not ok and result == stopped, tostring(result))
        assert(exit_code == 0)
        assert((reader and called_reader and not called_cli)
            or (not reader and called_cli and not called_reader))
        return observed_mode
    end
    for _, reader in ipairs({ false, true }) do
        assert(entry_mode("incremental", reader) == "generational",
            "embedded CLI and reader must match standalone Lua's collector")
        assert(entry_mode("generational", reader) == "generational",
            "standalone execution must keep its collector mode")
    end
end

do
    local Application = require("wtop.application")
    local Bandwidth = require("wtop.inspectors.ram_bandwidth")
    local Native = require("wtop.native")
    local Clock = require("wtop.core.clock")
    local Config = require("wtop.config")
    local Engine = require("wtop.engine")
    local System = require("wtop.system")
    local Fixture = require("support.fixture_fs")
    local Decode = require("wtop.core.json")
    local base = "/sys/bus/event_source/devices"
    local pmu = base .. "/uncore_imc_0"
    local fs = Fixture.new({ files = {
        [pmu .. "/type"] = "8", [pmu .. "/cpumask"] = "0",
        [pmu .. "/events/cas_count_read"] = "event=4,umask=3",
        [pmu .. "/events/cas_count_write"] = "event=4,umask=12",
    }, dirs = { [base] = { "uncore_imc_0" }, [pmu .. "/events"] = { "cas_count_read", "cas_count_write" } } })
    local before = { uname = Native.uname, run = Native.run, clock = Clock.default,
        load = Config.load, engine = Engine.new, constructor = Bandwidth.new,
        find = System.find_executable, write = io.write, command = Application.memory_bandwidth }
    local host, calls, encoded = "Linux", 0, nil
    local Validator = assert(loadfile("tools/agent_schema.lua"))()
    local schema_file = assert(io.open("docs/memory-bandwidth-v1.schema.json", "rb"))
    local schema = assert(Decode.decode(schema_file:read("*a")))
    schema_file:close()
    local ok, why = xpcall(function()
        Engine.new = function() error("bandwidth CLI started unrelated collectors") end
        Native.uname = function() return { sysname = host } end
        Clock.default = { now_ns = function() return 2e9 end, wall_ns = function() return 3e9 end }
        Config.load = function() return Config.defaults(), { state = "default" } end
        System.find_executable = function(name) return "/fixed/" .. name end
        Bandwidth.new = function(options) options.fs = fs; return before.constructor(options) end
        Native.run = function(argv)
            calls = calls + 1
            assert(argv[1] == "/fixed/perf" and table.concat(argv, " "):find("/fixed/sleep", 1, true))
            return { status = "ok", exit_code = 0, stdout = "", duration_ns = 250000000,
                stderr = "CPU0;100;;uncore_imc_0/cas_count_read/;1000000000;100.00;;\n"
                    .. "CPU0;50;;uncore_imc_0/cas_count_write/;1000000000;100.00;;\n" }
        end
        io.write = function(...) encoded = table.concat({ ... }); return true end
        local function command(pmu_name, safe)
            encoded = nil
            assert(Application.memory_bandwidth({ memory_pmu = pmu_name, safe_mode = safe,
                explicit = { safe_mode = true }, privilege = { mode = "user", root = false } }) == 0)
            assert(encoded:sub(-1) == "\n" and select(2, encoded:gsub("\n", "")) == 1)
            local document = assert(Decode.decode(encoded))
            local errors = assert(Validator.validate(document, schema))
            assert(#errors == 0, table.concat(errors, "\n"))
            return document
        end
        local list = command("list", false)
        assert(list.schema == Application.MEMORY_BANDWIDTH_SCHEMA and list.mode == "list" and list.status == "ok")
        assert(calls == 0 and #list.pmus == 1 and list.pmus[1].id == "uncore_imc_0")
        assert(list.pmus[1].type == 8 and list.pmus[1].source == pmu)
        assert(list.result.status == "ok" and #list.result.sections == 0 and list.pmus_truncated == false)
        list.status = "invented"
        assert(#Validator.validate(list, schema) > 0)
        list.status, list.processes = "ok", { { pid = 1 } }
        assert(#Validator.validate(list, schema) > 0)
        list.processes, list.pmus[1].id = nil, ""
        assert(#Validator.validate(list, schema) > 0)
        local measured = command(nil, false)
        assert(calls == 1 and measured.mode == "measure" and measured.status == "ok")
        assert(measured.result.entity.metrics.measurement_scope.value == "system")
        assert(measured.result.entity.metrics.total_bandwidth.value == 9600)
        assert(#measured.result.entity.metrics.counter_samples.value == 2)
        assert(measured.captured_monotonic_ns == 2e9 and measured.captured_unix_ns == 3e9)
        local read = measured.result.entity.metrics.read_bandwidth
        read.unit = "watts"
        assert(#Validator.validate(measured, schema) > 0)
        read.unit = "bytes_per_second"
        local sample = measured.result.entity.metrics.counter_samples.value[1]
        sample.bytes_per_second = -1
        assert(#Validator.validate(measured, schema) > 0)
        local single = command("uncore_imc_0", false)
        assert(calls == 2 and single.result.entity.metrics.measurement_scope.value == "controller_pmu")
        assert(single.result.source == pmu and single.producer.name == "wtop")
        local absent = command("uncore_imc_missing", false)
        assert(calls == 2 and absent.status == "unavailable" and absent.result.entity.metrics.read_bandwidth.value == nil)
        local safe = command(nil, true)
        assert(calls == 2 and safe.status == "unavailable" and safe.reason == "safe_mode")
        assert(command("list", true).status == "ok" and calls == 2)
        local readable_fs = fs
        fs = Fixture.new({ denied = { [base] = true } })
        local denied_list = command("list", false)
        assert(denied_list.status == "denied" and #denied_list.pmus == 0 and calls == 2)
        fs = readable_fs
        for _, platform in ipairs({ "Windows", "Darwin" }) do
            host = platform
            local unavailable = command(nil, false)
            assert(unavailable.platform == platform and unavailable.status == "unavailable")
            assert(unavailable.reason == "unsupported_on_this_platform" and calls == 2)
            local missing = command("list", false)
            assert(#missing.pmus == 0 and missing.status == "unavailable" and calls == 2)
        end
        host = "Linux"
        io.write = function() return nil, "disk full" end
        assert(not pcall(Application.memory_bandwidth, { safe_mode = true, explicit = { safe_mode = true },
            privilege = { root = false } }), "output failure was reported as a successful command")
        local dispatched = false
        Application.memory_bandwidth = function(options)
            dispatched = true; assert(options.memory_pmu == "list"); return 0
        end
        assert(cli.run({ "--memory-bandwidth", "--memory-pmu", "list" }, {
            platform = { require_supported = function() return { sysname = "Linux" } end },
            privilege = { identity = function() return { root = true } end },
        }) == 0 and dispatched)
    end, debug.traceback)
    Native.uname, Native.run, Clock.default, Config.load = before.uname, before.run, before.clock, before.load
    Engine.new, Bandwidth.new, System.find_executable, io.write = before.engine, before.constructor, before.find, before.write
    Application.memory_bandwidth = before.command
    assert(ok, why)
    print("ok: bandwidth CLI parsing, dispatch, same real reader/model, list/no-counter, selection, safe/unsupported states and no unrelated sampling")
end

return true
