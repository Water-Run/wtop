local native = require("wtop.native")

local M = {}

local supported = { Linux = "linux", Darwin = "macos", Windows = "windows" }

function M.detect(adapter)
    adapter = adapter or native
    if type(adapter) ~= "table" or adapter.available == false
        or type(adapter.uname) ~= "function" then
        return nil, "native platform probe is unavailable"
    end

    local called, platform, probe_error = pcall(adapter.uname)
    if not called then
        return nil, "platform detection failed: " .. tostring(platform)
    end
    if type(platform) ~= "table" or type(platform.sysname) ~= "string" then
        return nil, "platform detection failed: " .. tostring(probe_error or "invalid uname result")
    end
    return platform
end

function M.require_linux(adapter)
    local platform, detect_error = M.detect(adapter)
    if not platform then
        return nil, detect_error
    end
    if platform.sysname ~= "Linux" then
        return nil, "Linux is required (detected " .. platform.sysname .. ")"
    end
    return platform
end

function M.require_supported(adapter)
    local platform, detect_error = M.detect(adapter)
    if not platform then return nil, detect_error end
    local id = supported[platform.sysname]
    if not id then
        return nil, "unsupported operating system (detected " .. platform.sysname .. ")"
    end
    platform.id = id
    return platform
end

function M.id(adapter)
    local platform = M.require_supported(adapter)
    return platform and platform.id or nil
end

return M
