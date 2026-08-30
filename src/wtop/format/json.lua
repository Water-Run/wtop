local M = {}
local OBJECT = {}
local ARRAY = {}

local DEFAULT_MAX_BYTES = 64 * 1024 * 1024
local DEFAULT_MAX_DEPTH = 128
local DEFAULT_MAX_NODES = 1000000
local HARD_MAX_BYTES = 256 * 1024 * 1024
local HARD_MAX_DEPTH = 256
local HARD_MAX_NODES = 4000000

local ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local REPLACEMENT_CHARACTER = "\239\191\189"

local function continuation(byte)
    return byte and byte >= 0x80 and byte <= 0xbf
end

local function valid_sequence_length(value, position)
    local first = value:byte(position)
    if not first then return nil end
    if first <= 0x7f then return 1 end

    local second = value:byte(position + 1)
    if first >= 0xc2 and first <= 0xdf then
        return continuation(second) and 2 or nil
    end

    local third = value:byte(position + 2)
    if first == 0xe0 then
        return second and second >= 0xa0 and second <= 0xbf and continuation(third) and 3 or nil
    elseif (first >= 0xe1 and first <= 0xec) or (first >= 0xee and first <= 0xef) then
        return continuation(second) and continuation(third) and 3 or nil
    elseif first == 0xed then
        return second and second >= 0x80 and second <= 0x9f and continuation(third) and 3 or nil
    end

    local fourth = value:byte(position + 3)
    if first == 0xf0 then
        return second and second >= 0x90 and second <= 0xbf
            and continuation(third) and continuation(fourth) and 4 or nil
    elseif first >= 0xf1 and first <= 0xf3 then
        return continuation(second) and continuation(third) and continuation(fourth) and 4 or nil
    elseif first == 0xf4 then
        return second and second >= 0x80 and second <= 0x8f
            and continuation(third) and continuation(fourth) and 4 or nil
    end
    return nil
end

local function sanitize_utf8(value)
    local length = #value
    local position = 1
    local chunk_start = 1
    local chunks
    while position <= length do
        local sequence_length = valid_sequence_length(value, position)
        if sequence_length then
            position = position + sequence_length
        else
            chunks = chunks or {}
            chunks[#chunks + 1] = value:sub(chunk_start, position - 1)
            chunks[#chunks + 1] = REPLACEMENT_CHARACTER
            position = position + 1
            chunk_start = position
        end
    end
    if not chunks then return value end
    chunks[#chunks + 1] = value:sub(chunk_start)
    return table.concat(chunks)
end

local function quote(value)
    value = sanitize_utf8(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
        return ESCAPES[character] or string.format("\\u%04x", string.byte(character))
    end) .. '"'
end

local function table_kind(value)
    local shape = getmetatable(value)
    if shape == OBJECT then
        return "object"
    elseif shape == ARRAY then
        local count = 0
        local maximum = 0
        for key in pairs(value) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                error("JSON array keys must be positive integers", 3)
            end
            count = count + 1
            maximum = math.max(maximum, key)
        end
        if maximum ~= count then
            error("JSON arrays cannot contain holes", 3)
        end
        return "array", maximum
    elseif shape ~= nil then
        error("cannot encode a table with an unsupported metatable as JSON", 3)
    end
    local count = 0
    local maximum = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return "object"
        end
        count = count + 1
        if key > maximum then
            maximum = key
        end
    end
    if maximum ~= count then
        return "object"
    end
    return "array", maximum
end

local function shape(value, marker, name)
    if type(value) ~= "table" then
        error("json." .. name .. " expects a table", 2)
    end
    local current = getmetatable(value)
    if current ~= nil and current ~= marker then
        error("json." .. name .. " cannot replace an existing metatable", 2)
    end
    return setmetatable(value, marker)
end

function M.object(value)
    return shape(value == nil and {} or value, OBJECT, "object")
end

function M.array(value)
    return shape(value == nil and {} or value, ARRAY, "array")
end

local function ensure_length(length, state)
    if length > state.max_bytes then
        error("maximum JSON output size exceeded", 3)
    end
end

local function encode(value, stack, state, depth)
    state.nodes = state.nodes + 1
    if state.nodes > state.max_nodes then error("maximum JSON node count exceeded", 3) end
    if depth > state.max_depth then error("maximum JSON depth exceeded", 3) end
    local value_type = type(value)
    if value == nil then
        return "null"
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        if math.type and math.type(value) == "integer" then
            return tostring(value)
        end
        -- C's numeric locale may use a decimal comma. JSON always requires a
        -- dot, independent of the process locale inherited by an embedding app.
        return (string.format("%.17g", value):gsub(",", "."))
    elseif value_type == "string" then
        ensure_length(#value, state)
        local result = quote(value)
        ensure_length(#result, state)
        return result
    elseif value_type ~= "table" then
        error("cannot encode " .. value_type .. " as JSON", 3)
    end

    if stack[value] then
        error("cannot encode cyclic table as JSON", 3)
    end
    stack[value] = true

    local kind, length = table_kind(value)
    local parts = {}
    if kind == "array" then
        if length > state.max_nodes then error("maximum JSON node count exceeded", 3) end
        local total = 2
        for index = 1, length do
            parts[index] = encode(value[index], stack, state, depth + 1)
            total = total + #parts[index] + (index > 1 and 1 or 0)
            ensure_length(total, state)
        end
        stack[value] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for key in pairs(value) do
        if type(key) ~= "string" then
            stack[value] = nil
            error("JSON object keys must be strings", 3)
        end
        ensure_length(#key, state)
        keys[#keys + 1] = key
        if #keys > state.max_nodes then error("maximum JSON node count exceeded", 3) end
    end
    table.sort(keys)
    local encoded_keys = {}
    local total = 2
    for index, key in ipairs(keys) do
        local encoded_key = quote(key)
        if encoded_keys[encoded_key] then
            stack[value] = nil
            error("JSON object keys collide after UTF-8 sanitization", 3)
        end
        encoded_keys[encoded_key] = true
        local encoded_value = encode(value[key], stack, state, depth + 1)
        total = total + #encoded_key + 1 + #encoded_value + (index > 1 and 1 or 0)
        ensure_length(total, state)
        parts[index] = encoded_key .. ":" .. encoded_value
    end
    stack[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function bounded_option(options, name, default, maximum)
    local value = options[name]
    if value == nil then return default end
    if type(value) ~= "number" or math.type(value) ~= "integer"
        or value < 1 or value > maximum then
        error("json.encode " .. name .. " must be an integer in 1.." .. maximum, 3)
    end
    return value
end

function M.encode(value, options)
    if options == nil then options = {} end
    if type(options) ~= "table" then error("json.encode options must be a table", 2) end
    local state = {
        nodes = 0,
        max_bytes = bounded_option(options, "max_bytes", DEFAULT_MAX_BYTES, HARD_MAX_BYTES),
        max_depth = bounded_option(options, "max_depth", DEFAULT_MAX_DEPTH, HARD_MAX_DEPTH),
        max_nodes = bounded_option(options, "max_nodes", DEFAULT_MAX_NODES, HARD_MAX_NODES),
    }
    local result = encode(value, {}, state, 0)
    ensure_length(#result, state)
    return result
end

M.DEFAULT_MAX_BYTES = DEFAULT_MAX_BYTES
M.DEFAULT_MAX_DEPTH = DEFAULT_MAX_DEPTH
M.DEFAULT_MAX_NODES = DEFAULT_MAX_NODES

return M
