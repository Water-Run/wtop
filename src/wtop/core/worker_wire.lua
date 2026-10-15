-- Private process data protocol. No Lua source or bytecode crosses the channel.
local M = { MAX_BYTES = 16 * 1024 * 1024, MAX_NODES = 262144, MAX_DEPTH = 48 }

function M.encode(value)
    local chunks, bytes, nodes, active = {}, 0, 0, {}
    local function put(s)
        bytes = bytes + #s
        assert(bytes <= M.MAX_BYTES, "worker_wire_bytes")
        chunks[#chunks + 1] = s
    end
    local function visit(v, depth)
        nodes = nodes + 1
        assert(nodes <= M.MAX_NODES and depth <= M.MAX_DEPTH, "worker_wire_complexity")
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
            for _ in pairs(v) do count = count + 1; assert(count <= M.MAX_NODES, "worker_wire_complexity") end
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

function M.decode(data)
    assert(type(data) == "string" and #data <= M.MAX_BYTES, "worker_wire_bytes")
    local p, nodes = 1, 0
    local function take(n)
        assert(n <= #data - p + 1, "worker_wire_short")
        local old = p; p = p + n; return old
    end
    local function visit(depth)
        nodes = nodes + 1
        assert(nodes <= M.MAX_NODES and depth <= M.MAX_DEPTH, "worker_wire_complexity")
        local tag = data:sub(take(1), p - 1)
        if tag == "z" then return nil end
        if tag == "t" then return true end
        if tag == "f" then return false end
        if tag == "i" then return (string.unpack("<i8", data, take(8))) end
        if tag == "d" then
            local n = string.unpack("<d", data, take(8))
            assert(n == n and math.abs(n) ~= math.huge, "worker_wire_number"); return n
        end
        if tag == "s" then
            local n = string.unpack("<I4", data, take(4))
            local start = take(n); return data:sub(start, start + n - 1)
        end
        assert(tag == "m", "worker_wire_tag")
        local n = string.unpack("<I4", data, take(4))
        assert(n <= (M.MAX_NODES - nodes) // 2, "worker_wire_complexity")
        local result = {}
        for _ = 1, n do
            local key = visit(depth + 1)
            assert(type(key) == "string" or math.type(key) == "integer", "worker_wire_key")
            assert(result[key] == nil, "worker_wire_duplicate")
            local value = visit(depth + 1)
            assert(value ~= nil, "worker_wire_nil_field")
            result[key] = value
        end
        return result
    end
    local result = visit(0)
    assert(p == #data + 1, "worker_wire_trailing")
    return result
end

return M
