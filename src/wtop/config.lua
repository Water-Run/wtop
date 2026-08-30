local I18n = require("wtop.i18n")
local FS = require("wtop.linux.fs")
local Theme = require("wtop.ui.theme")

local M = {}

local KNOWN = {
    schema_version = true,
    locale = true,
    theme = true,
    interval_ms = true,
    safe_mode = true,
    color = true,
    mouse = true,
    active_tab = true,
}

local VALID_TABS = {
    overview = true,
    processes = true,
    compute = true,
    storage = true,
    network = true,
    gpu = true,
    workloads = true,
    insights = true,
}

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do
        result[key] = item
    end
    return result
end

local function safe_config_root(value)
    if type(value) ~= "string" or #value < 1 or #value > 4096
        or value:sub(1, 1) ~= "/" or value:find("\0", 1, true)
    then
        return false
    end
    for component in value:gmatch("[^/]+") do
        if component == "." or component == ".." then return false end
    end
    return true
end

local function environment_value(environment, name)
    local ok, value = pcall(environment, name)
    return ok and type(value) == "string" and value or nil
end

function M.defaults()
    return {
        schema_version = 1,
        theme = Theme.DEFAULT,
        interval_ms = 1000,
        safe_mode = false,
        color = true,
        mouse = true,
        active_tab = "overview",
    }
end

function M.path(environment)
    environment = environment or os.getenv
    if type(environment) ~= "function" then return nil end
    local config_home = environment_value(environment, "XDG_CONFIG_HOME")
    if safe_config_root(config_home) then
        return config_home .. "/wtop/config.yml"
    end
    local home = environment_value(environment, "HOME")
    return safe_config_root(home) and (home .. "/.config/wtop/config.yml") or nil
end

local function validate(raw)
    if type(raw) ~= "table" or raw == I18n.Yaml.null then
        return nil, "configuration root must be a mapping"
    end
    for key in pairs(raw) do
        if not KNOWN[key] then
            return nil, "unknown configuration key: " .. tostring(key)
        end
    end
    if raw.schema_version ~= nil and raw.schema_version ~= 1 then
        return nil, "unsupported schema_version: " .. tostring(raw.schema_version)
    end

    local output = M.defaults()
    if raw.locale ~= nil and raw.locale ~= I18n.Yaml.null then
        local locale, locale_error = I18n.normalize_locale(raw.locale)
        if not locale then
            return nil, "invalid locale: " .. locale_error
        end
        output.locale = locale
    end
    if raw.theme ~= nil then
        local valid = false
        for _, name in ipairs(Theme.available()) do
            valid = valid or raw.theme == name
        end
        if not valid then
            return nil, "unknown theme: " .. tostring(raw.theme)
        end
        output.theme = raw.theme
    end
    if raw.interval_ms ~= nil then
        if type(raw.interval_ms) ~= "number" or raw.interval_ms % 1 ~= 0
            or raw.interval_ms < 100 or raw.interval_ms > 10000
        then
            return nil, "interval_ms must be an integer from 100 to 10000"
        end
        output.interval_ms = raw.interval_ms
    end
    for _, key in ipairs({ "safe_mode", "color", "mouse" }) do
        if raw[key] ~= nil then
            if type(raw[key]) ~= "boolean" then
                return nil, key .. " must be true or false"
            end
            output[key] = raw[key]
        end
    end
    if raw.active_tab ~= nil then
        if not VALID_TABS[raw.active_tab] then
            return nil, "unknown active_tab: " .. tostring(raw.active_tab)
        end
        output.active_tab = raw.active_tab
    end
    return output
end

function M.parse(text, source)
    if type(text) ~= "string" then return nil, "configuration content must be text" end
    local raw, parse_error = I18n.Yaml.parse(text, { source = source or "<config>" })
    if not raw then
        return nil, parse_error
    end
    return validate(raw)
end

function M.load(path)
    path = path or M.path()
    if not path then
        return M.defaults(), { state = "unavailable", reason = "HOME is not set" }
    end
    if not safe_config_root(path) then
        return M.defaults(), { state = "error", path = path, reason = "invalid configuration path" }
    end
    local text, read_error = FS.default:read(path, 1024 * 1024)
    if not text then
        if read_error and read_error.kind == "missing" then
            return M.defaults(), { state = "default", path = path }
        end
        local reason = read_error and read_error.kind == "too_large"
            and "configuration exceeds 1 MiB"
            or tostring(read_error and read_error.message or "configuration read failed")
        return M.defaults(), { state = "error", path = path, reason = reason }
    end
    local parsed, parse_error = M.parse(text, path)
    if not parsed then
        return M.defaults(), { state = "error", path = path, reason = parse_error }
    end
    return parsed, { state = "loaded", path = path }
end

function M.resolve(cli_options, file_config)
    if type(cli_options) ~= "table" then error("CLI options must be a table", 2) end
    if file_config ~= nil and type(file_config) ~= "table" then
        error("file configuration must be a table", 2)
    end
    local result = copy(file_config or M.defaults())
    local explicit = cli_options.explicit or {}
    if type(explicit) ~= "table" then error("explicit CLI options must be a table", 2) end
    for _, key in ipairs({ "locale", "theme", "interval_ms", "safe_mode", "color", "mouse",
        "active_tab" }) do
        if explicit[key] then
            result[key] = cli_options[key]
        end
    end
    local validated, validation_error = validate(result)
    if not validated then error("invalid resolved configuration: " .. validation_error, 2) end
    validated.command = cli_options.command
    return validated
end

M.validate = validate

return M
