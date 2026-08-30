package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Actions = require("wtop.actions")

local stat = "42 (worker name) S 1 1 1 0 -1 0 1 2 3 4 5 6 7 8 9 10 11 1234 4096 2 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n"
local fs = {
    read = function(_, path)
        assert(path == "/proc/42/stat")
        return stat
    end,
}
local called
local native = {
    pid = function() return 100 end,
    signal_process = function(pid, signal_number, starttime_ticks)
        called = { pid, signal_number, starttime_ticks }
        return true
    end,
}
local process = { pid = 42, starttime_ticks = 4096 }
assert(Actions.verify_process(process, fs))
assert(Actions.signal_process(process, 15, { fs = fs, native = native }))
assert(called[1] == 42 and called[2] == 15 and called[3] == 4096)
assert(Actions.signal_process(process, 2, { fs = fs, native = native }) == nil)
assert(Actions.signal_process({ pid = 1, starttime_ticks = 1 }, 15, { fs = fs, native = native }) == nil)
assert(Actions.signal_process({ pid = 100, starttime_ticks = 1 }, 15, { fs = fs, native = native }) == nil)
assert(Actions.signal_process({ pid = 42, starttime_ticks = 999 }, 15, { fs = fs, native = native }) == nil)
local function assert_identity_rejected(identity)
    local sent, reason = Actions.signal_process(identity, 15, { fs = fs, native = native })
    assert(sent == nil)
    assert(type(reason) == "string" and reason ~= "")
end

assert_identity_rejected(nil)
assert_identity_rejected({})
assert_identity_rejected({ pid = "42", starttime_ticks = 4096 })
assert_identity_rejected({ pid = 42.5, starttime_ticks = 4096 })
assert_identity_rejected({ pid = 42, starttime_ticks = -1 })

return true
