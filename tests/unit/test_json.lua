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
-- The ASCII fast path must return every pure-ASCII string unchanged (control
-- characters are escaped by quote, not by sanitization), and a single byte at
-- or above 0x80 must still take the sanitizing walk instead of passing through.
local ascii_bytes = {}
for byte = 0, 127 do ascii_bytes[#ascii_bytes + 1] = string.char(byte) end
local ascii_encoded = json.encode(table.concat(ascii_bytes))
assert(utf8.len(ascii_encoded), "ASCII fast path must produce valid UTF-8")
assert(not ascii_encoded:find("[\128-\255]"),
    "ASCII fast path must not introduce non-ASCII bytes")
assert(json.encode("abc\128def") == '"abc' .. replacement .. 'def"',
    "a single non-ASCII byte must disable the ASCII fast path")
assert(json.encode("\127\128\127") == '"\127' .. replacement .. '\127"',
    "the byte immediately above the ASCII range must be sanitized")
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
