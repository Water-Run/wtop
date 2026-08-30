local native = require("wtop.native")

local M = {}

local DEFAULT_READ_LIMIT = 4 * 1024 * 1024
local MAX_READ_LIMIT = 64 * 1024 * 1024
local ROOT_EXECUTABLE_PATH = "/usr/sbin:/usr/bin:/sbin:/bin"

local function valid_path(path)
    return type(path) == "string" and path ~= "" and not path:find("\0", 1, true)
end

local function valid_limit(limit)
    return type(limit) == "number" and limit == limit
        and limit ~= math.huge and limit ~= -math.huge
        and limit >= 1 and limit <= MAX_READ_LIMIT and limit % 1 == 0
end

function M.read_file(path, limit)
    limit = limit or DEFAULT_READ_LIMIT
    if not valid_path(path) then return nil, "invalid path" end
    if not valid_limit(limit) then return nil, "invalid read limit" end
    if native.available and type(native.readfile) == "function" then
        local called, content, read_error = pcall(native.readfile, path, limit)
        if not called then return nil, tostring(content) end
        return content, read_error
    end
    local file, open_error = io.open(path, "rb")
    if not file then
        return nil, open_error
    end
    local content, read_error = file:read(limit + 1)
    local closed, close_error = file:close()
    if content == nil then
        return nil, read_error
    end
    if #content > limit then return nil, "file exceeds read limit" end
    if closed == nil then return nil, close_error end
    return content
end

function M.exists(path)
    if not valid_path(path) or type(native.access) ~= "function" then return false end
    local called, value = pcall(native.access, path, "f")
    return called and value == true
end

function M.readable(path)
    if not valid_path(path) or type(native.access) ~= "function" then return false end
    local called, value = pcall(native.access, path, "r")
    return called and value == true
end

function M.default_executable_path(effective_uid, environment)
    environment = environment or os.getenv
    if effective_uid == nil and type(native.uid) == "function" then
        local called, _, detected = pcall(native.uid)
        if called then effective_uid = detected end
    end
    if effective_uid == 0 then return ROOT_EXECUTABLE_PATH end
    local called, value = pcall(environment, "PATH")
    if called and type(value) == "string" and value ~= "" then return value end
    return "/usr/local/sbin:/usr/local/bin:" .. ROOT_EXECUTABLE_PATH
end

function M.find_executable(name, path_value)
    if type(name) ~= "string" or name == "" or name:find("/", 1, true) then
        return nil
    end
    local search = path_value or M.default_executable_path()
    for directory in (search .. ":"):gmatch("([^:]*):") do
        -- Runner only accepts absolute executable paths.  Empty and relative
        -- PATH entries mean the current directory and would silently weaken
        -- that boundary.
        if directory:sub(1, 1) == "/" then
            local candidate = directory .. "/" .. name
            local kind_called, kind = false, nil
            if type(native.path_type) == "function" then
                kind_called, kind = pcall(native.path_type, candidate, true)
            end
            local access_called, executable = false, false
            if type(native.access) == "function" then
                access_called, executable = pcall(native.access, candidate, "x")
            end
            if kind_called and kind == "regular" and access_called and executable == true then
                return candidate
            end
        end
    end
    return nil
end

M.ROOT_EXECUTABLE_PATH = ROOT_EXECUTABLE_PATH

function M.trim(value)
    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

return M
