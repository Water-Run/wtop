package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Platform = require("wtop.platform")

local linux = assert(Platform.require_linux({
    available = true,
    uname = function()
        return { sysname = "Linux", release = "test" }
    end,
}))
assert(linux.sysname == "Linux")

local non_linux, non_linux_error = Platform.require_linux({
    available = true,
    uname = function()
        return { sysname = "Darwin" }
    end,
})
assert(non_linux == nil)
assert(non_linux_error == "Linux is required (detected Darwin)")

local unavailable, unavailable_error = Platform.require_linux({ available = false })
assert(unavailable == nil)
assert(unavailable_error == "native platform probe is unavailable")

local failed, failed_error = Platform.require_linux({
    available = true,
    uname = function()
        return nil, "probe failed"
    end,
})
assert(failed == nil)
assert(failed_error == "platform detection failed: probe failed")

return true
