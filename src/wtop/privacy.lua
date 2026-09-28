-- Remote-address masking shared by the JSON exporter and the TUI connection
-- table so both surfaces always agree on what a masked endpoint looks like.
local M = {}

function M.mask_address(address)
    if type(address) ~= "string" then return address end
    local prefix = address:match("^(%d+%.%d+%.%d+%.)%d+$")
    if prefix then return prefix .. "x" end
    if address:find(":", 1, true) then
        local groups = {}
        for group in address:gmatch("[^:]+") do groups[#groups + 1] = group end
        if #groups > 2 then return table.concat({ groups[1], groups[2], "…" }, ":") end
        return address == "::" and address or "…"
    end
    return address
end

-- Display text for an endpoint with the address masked and the port kept,
-- matching the export contract. Falls back to the original text when the
-- structured fields are missing.
function M.masked_endpoint_text(endpoint)
    if type(endpoint) ~= "table" then return endpoint end
    if type(endpoint.address) ~= "string" or type(endpoint.port) ~= "number" then
        return endpoint.text
    end
    local masked = M.mask_address(endpoint.address)
    if endpoint.family == "ipv6" then
        return "[" .. masked .. "]:" .. tostring(endpoint.port)
    end
    return masked .. ":" .. tostring(endpoint.port)
end

return M
