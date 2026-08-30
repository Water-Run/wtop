package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local json = require("wtop.format.json")

assert(json.encode(nil) == "null")
assert(json.encode(true) == "true")
assert(json.encode(false) == "false")
assert(json.encode({ "a", 2, false }) == '["a",2,false]')
assert(json.encode(json.array({})) == "[]")
assert(json.encode(json.object({})) == "{}")
assert(json.encode({ z = 1, a = "line\n\0" }) == '{"a":"line\\n\\u0000","z":1}')
assert(json.encode("水") == '"水"')
local replacement = "\239\191\189"
assert(json.encode("bad\255value") == '"bad' .. replacement .. 'value"')
assert(json.encode({ ["bad\255key"] = "ok" }) == '{"bad' .. replacement .. 'key":"ok"}')
local malformed = "truncated:\226\130;surrogate:\237\160\128;overlong:\192\175"
local sanitized_once = json.encode(malformed)
assert(sanitized_once == json.encode(malformed), "invalid UTF-8 replacement must be deterministic")
assert(utf8.len(sanitized_once), "encoded JSON must always be valid UTF-8")
assert(not sanitized_once:find("\255", 1, true))
assert(json.encode(0 / 0) == "null")
assert(json.encode(math.huge) == "null")
assert(json.encode(1787821855685887500) == "1787821855685887500")

local cycle = {}
cycle.self = cycle
assert(not pcall(json.encode, cycle))
assert(not pcall(json.encode, { [1] = "one", named = "value" }))
assert(not pcall(json.encode, { ["bad\255"] = 1, ["bad\254"] = 2 }),
    "sanitized object keys must not produce duplicate JSON members")
assert(not pcall(json.encode, {{{1}}}, {max_depth = 1}),
    "encoder depth must be bounded before recursive overflow")
assert(not pcall(json.encode, {1, 2, 3}, {max_nodes = 2}),
    "encoder node count must be bounded")
assert(not pcall(json.encode, string.rep("x", 32), {max_bytes = 16}),
    "encoder output size must be bounded")
assert(not pcall(json.encode, {}, "invalid"), "encoder options must be validated")

return true
