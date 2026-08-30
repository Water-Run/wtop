package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Terminal = require("wtop.terminal")

local function capabilities(environment)
    return Terminal.detect_capabilities({
        getenv = function(name) return environment[name] end,
    })
end

assert(not capabilities({}).unicode, "an unset locale is not known to be UTF-8")
assert(not capabilities({ LC_ALL = "", LANG = "C" }).unicode,
    "an empty LC_ALL must fall through to a C LANG")
assert(not capabilities({ LANG = "en_US.ISO-8859-1" }).unicode,
    "a non-UTF-8 locale must not enable Unicode rendering")
assert(capabilities({ LANG = "en_US.UTF-8" }).unicode)
assert(capabilities({ LC_ALL = "C.UTF-8", LANG = "C" }).unicode)
assert(capabilities({ LC_ALL = "", LC_CTYPE = "zh_CN.utf8", LANG = "C" }).unicode)
assert(not capabilities({ LC_ALL = "POSIX", LANG = "en_US.UTF-8" }).unicode,
    "a non-empty LC_ALL has locale precedence")

local writes = {}
local stopped = 0
local fake = {
    terminal_start = function()
        return true
    end,
    terminal_stop = function()
        stopped = stopped + 1
        return true
    end,
    terminal_size = function()
        return 80, 24
    end,
    poll = function(timeout)
        return { data = "q", timeout = timeout }
    end,
    write = function(value)
        writes[#writes + 1] = value
        return true
    end,
}

local backend = Terminal.new(fake)
assert(backend.start({ color = false, mouse = false }))
assert(backend.start({ color = false, mouse = false }))
local columns, rows = backend.size()
assert(columns == 80 and rows == 24)
assert(backend.poll(50).data == "q")
assert(backend.capabilities().no_color == true)
assert(writes[1]:find("?1049h", 1, true))
assert(writes[1]:find("?7l", 1, true), "terminal autowrap must be disabled while rendering")
assert(not writes[1]:find("?1000h", 1, true))

assert(backend.present({ { x = 1, y = 1, text = "ok", style = {} } }, {full = true}))
assert(writes[2]:find("ok", 1, true))
assert(writes[2]:find("\27[2J\27[H", 1, true))
assert(backend.stop())
assert(backend.stop())
assert(stopped == 1)
assert(writes[3]:find("?1049l", 1, true))
assert(writes[3]:find("?7h", 1, true), "terminal autowrap must be restored")

return true
