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

return true
