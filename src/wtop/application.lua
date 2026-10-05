local Engine = require("wtop.engine")
local Export = require("wtop.export")
local Config = require("wtop.config")
local Privilege = require("wtop.privilege")
local json = require("wtop.format.json")
local native = require("wtop.native")

local M = {}

-- The longest an agent invocation will spend deliberately waiting between its
-- two samples.  Named, because `docs/AGENT.md` states it and
-- `tests/unit/test_agent_schema.lua` compares the document against this value:
-- written inline as `min(options.interval_ms or 1000, 250)` it was a number the
-- documentation had to repeat without a way to notice it changing.
--
-- It is a *cap on the delay*, not the cost of the invocation.  Measured on the
-- development host, `wtop --agent` takes 1.22-1.25 s at the default interval,
-- of which this is 250 ms: the rest is a full sampling round, which
-- `--snapshot` -- one tick, no delay at all -- also pays (1.26 s).  The document
-- used to say "normally takes about 250 ms" for the whole invocation, which is
-- this number read as a total, and it was wrong by about five times.  A caller
-- budgeting from it is budgeting from a figure that never included the work.
M.AGENT_SAMPLE_DELAY_CAP_MS = 250

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

local function collect(options)
    options = resolve_options(options)
    local engine = new_engine(options)
    local ok, result = xpcall(function()
        local capabilities = engine:probe()
        engine:tick(true)
        local sleep_ok, slept, sleep_error = pcall(
            native.sleep_ms,
            math.min(options.interval_ms or 1000, M.AGENT_SAMPLE_DELAY_CAP_MS))
        if not sleep_ok or not slept then
            error("sampling delay failed: " .. tostring(sleep_ok and sleep_error or slept), 0)
        end
        local snapshot = engine:tick(true)
        return { snapshot = snapshot, capabilities = capabilities }
    end, debug.traceback)
    engine:stop()
    if not ok then
        error(result, 0)
    end
    return result, options
end

local function write_json(value)
    local encoded = json.encode(value)
    local ok, result, write_error = pcall(io.write, encoded, "\n")
    if not ok or not result then
        error("output write failed: " .. tostring(ok and write_error or result), 0)
    end
end

function M.snapshot(options)
    local collected, resolved = collect(options)
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

function M.run(options)
    local Tui = require("wtop.tui")
    return Tui.run(resolve_options(options))
end

M.resolve_options = resolve_options

return M
