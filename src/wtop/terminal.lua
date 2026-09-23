local Ansi = require("wtop.ui.renderer.ansi")
local native_default = require("wtop.native")

local M = {}

local function first_nonempty_environment(getenv, names)
    for _, name in ipairs(names) do
        local ok, value = pcall(getenv, name)
        if not ok then value = nil end
        if type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

local function locale_is_utf8(locale)
    if type(locale) ~= "string" or locale == "" then
        return false
    end
    local normalized = locale:lower()
    local codeset = normalized:match("%.([^@]+)") or normalized:match("^([^@]+)")
    codeset = codeset:gsub("[-_]", "")
    return codeset == "utf8"
end

local function detect_capabilities(options)
    options = options or {}
    if type(options) ~= "table" then error("terminal options must be a table", 2) end
    local getenv = type(options.getenv) == "function" and options.getenv or os.getenv
    local function environment(name)
        local ok, value = pcall(getenv, name)
        return ok and type(value) == "string" and value or nil
    end
    local term = environment("TERM") or ""
    local color_term = (environment("COLORTERM") or ""):lower()
    local locale = first_nonempty_environment(getenv, { "LC_ALL", "LC_CTYPE", "LANG" })
    local no_color = options.color == false or environment("NO_COLOR") ~= nil or term == "dumb"
    local truecolor = not no_color and (color_term:find("truecolor", 1, true) ~= nil
        or color_term:find("24bit", 1, true) ~= nil
        or term:find("-direct", 1, true) ~= nil)
    local colors = 0
    if not no_color then
        colors = truecolor and 16777216 or (term:find("256color", 1, true) and 256 or 16)
    end
    return {
        truecolor = truecolor,
        colors = colors,
        color = not no_color,
        no_color = no_color,
        unicode = locale_is_utf8(locale),
        mouse = options.mouse ~= false,
        bracketed_paste = true,
    }
end

local function native_capabilities(native, detected)
    if type(native.terminal_capabilities) ~= "function" then return detected end
    local ok, overrides = pcall(native.terminal_capabilities)
    if not ok or type(overrides) ~= "table" then return detected end
    for key, value in pairs(overrides) do
        detected[key] = value
    end
    if detected.no_color then
        detected.colors = 0
        detected.color = false
        detected.truecolor = false
    end
    return detected
end

function M.new(native)
    native = native or native_default
    if type(native) ~= "table" then error("terminal backend must be a table", 2) end
    local active = false
    local capabilities = detect_capabilities()
    local native_presentation = false

    return {
        start = function(options)
            if active then
                return true
            end
            capabilities = detect_capabilities(options)
            local start_ok, started, start_error = pcall(native.terminal_start, 0, 1)
            if not start_ok then return false, "terminal_start_failed" end
            if not started then
                return false, start_error
            end
            active = true
            capabilities = native_capabilities(native, capabilities)
            native_presentation = type(native.terminal_present) == "function"
                and capabilities.native_presentation ~= false
            if native_presentation then return true end
            -- Disable terminal autowrap while the cell renderer owns the
            -- alternate screen. This keeps a write to the bottom-right cell
            -- from scrolling on terminals with eager wrap semantics.
            local sequence = "\27[?1049h\27[?25l\27[?7l\27[2J\27[H\27[?2004h"
            if capabilities.mouse then
                sequence = sequence .. "\27[?1000h\27[?1006h"
            end
            local write_ok, written, write_error = pcall(native.write, sequence)
            if not write_ok then written, write_error = nil, "terminal_write_failed" end
            if not written then
                active = false
                pcall(native.write,
                    "\27[?1000l\27[?1006l\27[?2004l\27[?7h\27[0m\27[?25h\27[?1049l")
                pcall(native.terminal_stop)
                return false, write_error
            end
            return true
        end,
        size = function()
            local ok, columns, rows = pcall(native.terminal_size)
            if not ok then return nil, "terminal_size_failed" end
            return columns, rows
        end,
        poll = function(timeout_ms)
            local ok, event, poll_error = pcall(native.poll, timeout_ms)
            if not ok then return nil, "terminal_poll_failed" end
            return event, poll_error
        end,
        present = function(runs, metadata)
            if native_presentation then
                local ok, presented, present_error = pcall(native.terminal_present, runs, metadata)
                if not ok then return nil, "terminal_present_failed" end
                return presented, present_error
            end
            local encoded, sequence = pcall(Ansi.encode, runs)
            if not encoded then return nil, "terminal_encode_failed" end
            if metadata and metadata.full then
                sequence = "\27[2J\27[H" .. sequence
            end
            local ok, written, write_error = pcall(native.write, sequence)
            if not ok then return nil, "terminal_write_failed" end
            return written, write_error
        end,
        capabilities = function()
            return capabilities
        end,
        stop = function()
            if not active then
                return true
            end
            active = false
            if native_presentation then
                local stop_ok, stopped, stop_error = pcall(native.terminal_stop)
                if not stop_ok then return false, "terminal_stop_failed" end
                return stopped, stop_error
            end
            local sequence = "\27[?1000l\27[?1006l\27[?2004l\27[?7h\27[0m\27[?25h\27[?1049l"
            local write_ok, written, write_error = pcall(native.write, sequence)
            if not write_ok then written, write_error = nil, "terminal_write_failed" end
            local stop_ok, stopped, stop_error = pcall(native.terminal_stop)
            if not stop_ok then stopped, stop_error = nil, "terminal_stop_failed" end
            if not written then
                return false, write_error
            end
            if not stopped then
                return false, stop_error
            end
            return true
        end,
    }
end

M.detect_capabilities = detect_capabilities
M.locale_is_utf8 = locale_is_utf8

return M
