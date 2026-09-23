local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local native_default = require("wtop.native")
local Platform = require("wtop.platform")

local M = {}

local ALLOWED_SIGNALS = {
    [9] = true,
    [15] = true,
    [18] = true,
    [19] = true,
}

local function validate_identity(process)
    if type(process) ~= "table" then
        return nil, "process identity is incomplete"
    end
    if type(process.pid) ~= "number" or process.pid ~= process.pid
        or process.pid == math.huge or process.pid == -math.huge
        or process.pid % 1 ~= 0 or process.pid <= 0 or process.pid > 2147483647 then
        return nil, "process identity has an invalid PID"
    end
    if type(process.starttime_ticks) ~= "number"
        or process.starttime_ticks ~= process.starttime_ticks
        or process.starttime_ticks == math.huge or process.starttime_ticks == -math.huge
        or process.starttime_ticks % 1 ~= 0
        or process.starttime_ticks < 0
    then
        return nil, "process identity has an invalid start time"
    end
    return true
end

function M.verify_process(process, fs)
    fs = fs or FS.default
    local valid, identity_error = validate_identity(process)
    if not valid then
        return nil, identity_error
    end
    if type(fs) ~= "table" or type(fs.read) ~= "function" then
        return nil, "filesystem provider is unavailable"
    end
    local read_ok, content, read_error = pcall(
        fs.read, fs, "/proc/" .. process.pid .. "/stat", 65536)
    if not read_ok then return nil, "process verification read failed" end
    if not content then
        return nil, read_error and read_error.message or "process disappeared"
    end
    local current, parse_error = Parsers.process_stat(content)
    if not current then
        return nil, parse_error
    end
    if current.pid ~= process.pid or current.starttime_ticks ~= process.starttime_ticks then
        return nil, "process identity changed (PID reuse prevented)"
    end
    return true
end

function M.signal_process(process, signal_number, options)
    options = options or {}
    if type(options) ~= "table" then return nil, "action options must be a table" end
    local native = options.native or native_default
    if not ALLOWED_SIGNALS[signal_number] then
        return nil, "signal is not allowed"
    end
    local valid, identity_error = validate_identity(process)
    if not valid then
        return nil, identity_error
    end
    if process.pid <= 1 then
        return nil, "refusing to signal PID 1"
    end
    if type(native) ~= "table" or type(native.pid) ~= "function"
        or type(native.signal_process) ~= "function" then
        return nil, "native process controls are unavailable"
    end
    local pid_ok, own_pid = pcall(native.pid)
    if not pid_ok then return nil, "unable to determine wtop PID" end
    if own_pid and process.pid == own_pid then
        return nil, "refusing to signal wtop itself"
    end
    if Platform.id(native) == "windows" then
        if signal_number ~= 9 then
            return nil, "this process action is unavailable on Windows"
        end
    else
        local verified, verify_error = M.verify_process(process, options.fs)
        if not verified then return nil, verify_error end
    end
    -- The native layer revalidates starttime while holding a pidfd, closing
    -- the classic verify-then-kill PID-reuse window.
    local signal_ok, result, signal_error = pcall(
        native.signal_process, process.pid, signal_number, process.starttime_ticks)
    if not signal_ok then return nil, "native signal operation failed" end
    return result, signal_error
end

M.allowed_signals = ALLOWED_SIGNALS
M.validate_identity = validate_identity

return M
