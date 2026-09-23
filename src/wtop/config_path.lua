local Platform = require("wtop.platform")
local native = require("wtop.native")

local M = {}

local function host_platform()
    return Platform.id() or "linux"
end

local function environment_value(environment, name)
    local ok, value = pcall(environment, name)
    if not ok or type(value) ~= "string" or value == "" then return nil end
    return value
end

local function normalized(path)
    return type(path) == "string" and path:gsub("\\", "/") or nil
end

local function append(base, suffix)
    base = base:gsub("/+$", "")
    if base == "" then return "/" .. suffix end
    return base .. "/" .. suffix
end

function M.safe_absolute(path, platform)
    platform = platform or host_platform()
    if platform == "windows" then path = normalized(path) end
    if not path or #path < 1 or #path > 4096 or path:find("[%z\1-\31\127]") then
        return false
    end
    if platform == "windows" then
        if not path:match("^[A-Za-z]:/") then return false end
    elseif path:sub(1, 1) ~= "/" then
        return false
    end
    for component in path:gmatch("[^/]+") do
        if component == "." or component == ".." then return false end
    end
    return true
end

function M.normalize(path)
    return host_platform() == "windows" and normalized(path) or path
end

function M.root(environment, platform, name_length)
    platform = platform or host_platform()
    name_length = name_length or 0
    environment = environment or (type(native.getenv) == "function"
        and native.getenv or os.getenv)
    if type(environment) ~= "function" then return nil end
    if platform == "windows" then
        local appdata = normalized(environment_value(environment, "APPDATA"))
        local appdata_root = appdata and append(appdata, "wtop")
        if M.safe_absolute(appdata, platform)
            and #appdata_root + 1 + name_length <= 4096 then
            return appdata_root
        end
        local profile = normalized(environment_value(environment, "USERPROFILE"))
        if M.safe_absolute(profile, platform) then
            local profile_root = append(profile, "AppData/Roaming/wtop")
            if #profile_root + 1 + name_length <= 4096 then
                return profile_root
            end
        end
        return nil
    end
    local config_home = environment_value(environment, "XDG_CONFIG_HOME")
    local xdg_root = config_home and append(config_home, "wtop")
    if M.safe_absolute(config_home, platform)
        and #xdg_root + 1 + name_length <= 4096 then return xdg_root end
    local home = environment_value(environment, "HOME")
    local home_root = home and append(home, ".config/wtop")
    if M.safe_absolute(home, platform)
        and #home_root + 1 + name_length <= 4096 then return home_root end
    return nil
end

function M.file(name, environment, platform)
    local root = M.root(environment, platform, #name)
    return root and root .. "/" .. name or nil
end

return M
