package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local cli = require("wtop.cli")

local defaults = assert(cli.parse({}))
assert(defaults.command == "tui")
assert(defaults.interval_ms == 1000)
assert(defaults.color == true)

local configured = assert(cli.parse({
    "--lang", "zh-CN",
    "--theme", "water-dark",
    "--interval", "100",
    "--safe-mode",
    "--no-color",
}))
assert(configured.locale == "zh-CN")
assert(configured.theme == "water-dark")
assert(configured.interval_ms == 100)
assert(configured.safe_mode == true)
assert(configured.color == false)
assert(assert(cli.parse({ "--theme", "lua-blue" })).theme == "lua-blue")

local elevated = assert(cli.parse({ "--sudo", "--snapshot" }))
assert(elevated.elevate == true and elevated.command == "snapshot")
assert(assert(cli.parse({ "--elevate" })).elevate == true)
assert(cli.parse({ "--sudo", "--sudo" }) == nil)
assert(cli.parse({ "--sudo", "--elevate" }) == nil)

assert(cli.parse({ "--interval", "99" }) == nil)
assert(cli.parse({ "--interval", "10.5" }) == nil)
assert(cli.parse({ "--lang" }) == nil)
assert(cli.parse({ "--lang", "en--US" }) == nil)
assert(assert(cli.parse({ "--lang", "zh_CN.UTF-8" })).locale == "zh-CN")
assert(cli.parse({ "--theme", "water" }) == nil)
assert(cli.parse({ "--unknown" }) == nil)
assert(cli.parse(nil) == nil)
assert(cli.parse({ 42 }) == nil)
assert(cli.parse({ "--snapshot", "--agent" }) == nil)
assert(cli.parse({ "--help", "--help" }) == nil)

assert(assert(cli.parse({ "--help" })).command == "help")
assert(assert(cli.parse({ "--version" })).command == "version")
assert(assert(cli.parse({ "--diagnose" })).command == "diagnose")
assert(assert(cli.parse({ "--snapshot" })).command == "snapshot")
assert(assert(cli.parse({ "--agent" })).command == "agent")

assert(cli.requires_elevation({ command = "tui", elevate = true }, { root = false }))
assert(cli.requires_elevation({ command = "snapshot", elevate = true }, { root = false }))
assert(not cli.requires_elevation({ command = "help", elevate = true }, { root = false }))
assert(not cli.requires_elevation({ command = "version", elevate = true }, { root = false }))
assert(not cli.requires_elevation({ command = "tui", elevate = true }, { root = true }))

local elevation_calls = 0
local fake_identity = { mode = "user", root = false }
local code = cli.run({ "--sudo", "--diagnose" }, {
    platform = { require_linux = function() return true end },
    privilege = {
        identity = function() return fake_identity end,
        elevate = function()
            elevation_calls = elevation_calls + 1
            return true
        end,
    },
})
assert(code == 0 and elevation_calls == 1)
assert(fake_identity.requested == true)

return true
