-- User-facing labels for bounded collector codes. Snapshot and JSON values
-- retain their stable machine-readable spelling.
local M = {}

local function localized(i18n, prefix, value)
    if type(value) ~= "string" or #value > 96
        or not value:match("^[a-z][a-z0-9_]*$")
        or type(i18n) ~= "table" or type(i18n.t) ~= "function" then
        return value
    end
    local id = prefix .. "." .. value
    if type(i18n.has) == "function" and not i18n:has(id) then return value end
    local translated = i18n:t(id)
    if type(translated) == "string" and translated ~= id then return translated end
    return value
end

function M.state(i18n, value)
    return localized(i18n, "status", value)
end

function M.reason(i18n, value)
    return localized(i18n, "reason", value)
end

return M
