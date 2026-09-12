local Engine = require("wtop.engine")
local Export = require("wtop.export")
local Config = require("wtop.config")
local Privilege = require("wtop.privilege")
local json = require("wtop.format.json")
local native = require("wtop.native")

local M = {}

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
            native.sleep_ms, math.min(options.interval_ms or 1000, 250))
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
