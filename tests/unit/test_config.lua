package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Config = require("wtop.config")

local parsed = assert(Config.parse([[
schema_version: 1
locale: zh_CN.UTF-8
theme: water-light
interval_ms: 500
safe_mode: true
color: false
mouse: false
active_tab: gpu
]]))
assert(parsed.locale == "zh-CN")
assert(parsed.theme == "water-light")
assert(parsed.interval_ms == 500)
assert(parsed.safe_mode == true)
assert(parsed.color == false)
assert(parsed.mouse == false)
assert(parsed.active_tab == "gpu")

assert(Config.parse("unknown: true\n") == nil)
assert(assert(Config.parse("interval_ms: 100\n")).interval_ms == 100)
assert(Config.parse("interval_ms: 99\n") == nil)
assert(Config.parse("theme: impossible\n") == nil)
local _, special_status = Config.load("/dev/null")
assert(special_status.state == "error", "configuration readers must reject special files")
assert(Config.path(function() error("hostile environment") end) == nil)
assert(Config.path(function(name)
    return name == "XDG_CONFIG_HOME" and "relative" or "/home/test"
end) == "/home/test/.config/wtop/config.yml")
local _, unsafe_status = Config.load("/tmp/../config.yml")
assert(unsafe_status.state == "error" and unsafe_status.reason == "invalid configuration path")

local resolved = Config.resolve({
    command = "tui",
    interval_ms = 100,
    color = true,
    explicit = { interval_ms = true },
}, parsed)
assert(resolved.interval_ms == 100)
assert(resolved.color == false)
assert(resolved.theme == "water-light")

return true
