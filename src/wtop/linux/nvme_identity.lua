local M = {}

function M.name(name)
    if type(name) ~= "string" or #name > 32 then return false end
    local controller, namespace = name:match("^nvme(%d+)n(%d+)$")
    controller, namespace = tonumber(controller), tonumber(namespace)
    return controller ~= nil and namespace ~= nil
        and controller <= 0xffffffff and namespace > 0 and namespace <= 0xffffffff
        and name == string.format("nvme%.0fn%.0f", controller, namespace)
end

function M.key(name, major, minor, sequence)
    if not M.name(name) then return nil end
    for _, number in ipairs({ major, minor, sequence }) do
        if type(number) ~= "number" or math.type(number) ~= "integer" or number < 0 then return nil end
    end
    if major == nil or minor == nil or sequence == nil or sequence < 1
        or major > 1048575 or minor > 1048575 then return nil end
    return table.concat({ "linux-nvme", name, major, minor, sequence }, ":")
end

return M
