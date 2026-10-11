package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

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

return true
