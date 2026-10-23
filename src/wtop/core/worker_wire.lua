-- Private process data protocol. No Lua source or bytecode crosses the channel.
local M = { MAX_BYTES = 16 * 1024 * 1024, MAX_NODES = 262144, MAX_DEPTH = 48 }

-- Recording uses the same typed values with a larger, explicit frame budget.
-- Worker callers keep their existing limits; no global policy is changed.
local function limits(options)
    if options == nil then return M.MAX_BYTES, M.MAX_NODES, M.MAX_DEPTH end
    assert(type(options) == "table", "worker_wire_options")
    local function bound(key, default, maximum)
        local n = options[key] == nil and default or options[key]
        assert(math.type(n) == "integer" and n > 0 and n <= maximum, "worker_wire_options")
        return n
    end
    return bound("max_bytes", M.MAX_BYTES, 64 * 1024 * 1024),
        bound("max_nodes", M.MAX_NODES, 4000000), bound("max_depth", M.MAX_DEPTH, 64)
end

function M.encode(value, options)
    local max_bytes, max_nodes, max_depth = limits(options)
    local chunks, bytes, nodes, active = {}, 0, 0, {}
    local function put(s)
        bytes = bytes + #s
        assert(bytes <= max_bytes, "worker_wire_bytes")
        chunks[#chunks + 1] = s
    end
    local function visit(v, depth)
        nodes = nodes + 1
        assert(nodes <= max_nodes and depth <= max_depth, "worker_wire_complexity")
        local kind = type(v)
        if v == nil then put("z")
        elseif kind == "boolean" then put(v and "t" or "f")
        elseif kind == "number" then
            assert(v == v and math.abs(v) ~= math.huge, "worker_wire_number")
            put(math.type(v) == "integer" and ("i" .. string.pack("<i8", v))
                or ("d" .. string.pack("<d", v)))
        elseif kind == "string" then put("s" .. string.pack("<I4", #v)); put(v)
        elseif kind == "table" then
            assert(getmetatable(v) == nil and not active[v], "worker_wire_table")
            active[v] = true
            local count = 0
            for _ in pairs(v) do count = count + 1; assert(count <= max_nodes, "worker_wire_complexity") end
            put("m" .. string.pack("<I4", count))
            for k, item in pairs(v) do
                assert(type(k) == "string" or math.type(k) == "integer", "worker_wire_key")
                visit(k, depth + 1); visit(item, depth + 1)
            end
            active[v] = nil
        else error("worker_wire_type") end
    end
    visit(value, 0)
    return table.concat(chunks)
end

-- Decode tags as bytes and advance fixed-width fields directly. Every field
-- is checked against the frame before string.unpack or substring extraction.
local NIL, TRUE, FALSE, INTEGER, DOUBLE, STRING, MAP = ("ztfidsm"):byte(1, 7)
function M.decode(data, options)
    local max_bytes, max_nodes, max_depth = limits(options)
    if type(data) ~= "string" or #data > max_bytes then error("worker_wire_bytes") end
    local p, nodes, size = 1, 0, #data
    local function visit(depth)
        nodes = nodes + 1
        if nodes > max_nodes or depth > max_depth then error("worker_wire_complexity") end
        local tag = data:byte(p)
        if tag == nil then error("worker_wire_short") end
        p = p + 1
        if tag == NIL then return nil end
        if tag == TRUE then return true end
        if tag == FALSE then return false end
        if tag == INTEGER or tag == DOUBLE then
            if size - p < 7 then error("worker_wire_short") end
            local value
            value, p = string.unpack(tag == INTEGER and "<i8" or "<d", data, p)
            if tag == DOUBLE then
                if value ~= value or math.abs(value) == math.huge then error("worker_wire_number") end
            end
            return value
        end
        if tag == STRING or tag == MAP then
            if size - p < 3 then error("worker_wire_short") end
            local n
            n, p = string.unpack("<I4", data, p)
            if tag == STRING then
                if n > size - p + 1 then error("worker_wire_short") end
                local start = p
                p = p + n
                return data:sub(start, p - 1)
            end
            if n > (max_nodes - nodes) // 2 then error("worker_wire_complexity") end
            local result = {}
            for _ = 1, n do
                local key = visit(depth + 1)
                if type(key) ~= "string" and math.type(key) ~= "integer" then error("worker_wire_key") end
                if result[key] ~= nil then error("worker_wire_duplicate") end
                local value = visit(depth + 1)
                if value == nil then error("worker_wire_nil_field") end
                result[key] = value
            end
            return result
        end
        error("worker_wire_tag")
    end
    local result = visit(0)
    if p ~= size + 1 then error("worker_wire_trailing") end
    return result
end

return M
