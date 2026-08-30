local ok, native_or_error = pcall(require, "wtop_native")

if ok then
    native_or_error.available = true
    return native_or_error
end

local reason = tostring(native_or_error)

local function unavailable(name)
    return function()
        return nil, "native function " .. name .. " unavailable: " .. reason
    end
end

local fallback = {
    VERSION = "unavailable",
    available = false,
    error = reason,
    terminal_start = unavailable("terminal_start"),
    terminal_stop = function()
        return true
    end,
    terminal_size = function()
        local columns = tonumber(os.getenv("COLUMNS")) or 80
        local rows = tonumber(os.getenv("LINES")) or 24
        if columns ~= columns or columns == math.huge or columns == -math.huge
            or columns % 1 ~= 0 or columns < 1 or columns > 1048576 then columns = 80 end
        if rows ~= rows or rows == math.huge or rows == -math.huge
            or rows % 1 ~= 0 or rows < 1 or rows > 1048576 then rows = 24 end
        return columns, rows
    end,
    poll = unavailable("poll"),
    run = unavailable("run"),
    execve = unavailable("execve"),
    write = function(value)
        if type(value) ~= "string" then return nil, "write value must be a string" end
        local ok, result, write_error = pcall(io.stdout.write, io.stdout, value)
        if not ok or not result then return nil, tostring(ok and write_error or result) end
        local flush_ok, flushed, flush_error = pcall(io.stdout.flush, io.stdout)
        if not flush_ok or not flushed then return nil, tostring(flush_ok and flush_error or flushed) end
        return true
    end,
    monotonic_ns = function()
        return math.floor(os.clock() * 1000000000)
    end,
    realtime_ns = function()
        return os.time() * 1000000000
    end,
    sleep_ms = function(milliseconds)
        if type(milliseconds) ~= "number" or milliseconds ~= milliseconds
            or milliseconds == math.huge or milliseconds == -math.huge
            or milliseconds % 1 ~= 0 or milliseconds < 0 or milliseconds > 60000 then
            return nil, "invalid sleep duration"
        end
        local deadline = os.clock() + math.max(0, milliseconds) / 1000
        while os.clock() < deadline do
        end
        return true
    end,
    isatty = function()
        return false
    end,
    access = function(path, mode)
        if type(path) ~= "string" or path == "" or path:find("\0", 1, true)
            or (mode ~= nil and type(mode) ~= "string") then
            return false
        end
        if mode and mode:find("[wx]") then
            return false
        end
        local file = io.open(path, "rb")
        if not file then
            return false
        end
        file:close()
        return true
    end,
    mkdir = unavailable("mkdir"),
    atomic_write = unavailable("atomic_write"),
    listdir = unavailable("listdir"),
    readfile = unavailable("readfile"),
    readlink = unavailable("readlink"),
    path_type = unavailable("path_type"),
    statvfs = unavailable("statvfs"),
    system_constants = function()
        return {
            clock_ticks_per_second = 100,
            page_size_bytes = 4096,
            estimated = true,
        }
    end,
    signal_process = unavailable("signal_process"),
    setpriority = unavailable("setpriority"),
    uid = unavailable("uid"),
    pid = unavailable("pid"),
    uname = unavailable("uname"),
    wcwidth = function(codepoint)
        if type(codepoint) ~= "number" or codepoint % 1 ~= 0
            or codepoint < 0 or codepoint > 0x10ffff then return -1 end
        if codepoint == 0 then
            return 0
        end
        if codepoint < 32 or (codepoint >= 0x7F and codepoint < 0xA0) then
            return -1
        end
        if (codepoint >= 0x1100 and codepoint <= 0x115F)
            or (codepoint >= 0x2E80 and codepoint <= 0xA4CF)
            or (codepoint >= 0xAC00 and codepoint <= 0xD7A3)
            or (codepoint >= 0xF900 and codepoint <= 0xFAFF)
            or (codepoint >= 0xFE10 and codepoint <= 0xFE6F)
            or (codepoint >= 0xFF00 and codepoint <= 0xFF60)
            or (codepoint >= 0xFFE0 and codepoint <= 0xFFE6)
            or (codepoint >= 0x1F300 and codepoint <= 0x1FAFF)
        then
            return 2
        end
        return 1
    end,
}

return fallback
