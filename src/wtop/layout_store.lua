local I18n = require("wtop.i18n")
local Layout = require("wtop.model.layout")
local FS = require("wtop.linux.fs")
local native = require("wtop.native")

local M = {}

local MAX_PATH_BYTES = 4096
local MAX_PAGES = 64

local function safe_absolute_path(value)
    if type(value) ~= "string" or #value < 1 or #value > MAX_PATH_BYTES
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

local function validate_defaults(defaults)
    if type(defaults) ~= "table" or getmetatable(defaults) ~= nil then
        return nil, "layout defaults must be a plain mapping"
    end
    local pages = 0
    for page, order in pairs(defaults) do
        pages = pages + 1
        if pages > MAX_PAGES then return nil, "layout defaults exceed 64 pages" end
        if type(page) ~= "string" or #page < 1 or #page > 128
            or not page:match("^[A-Za-z0-9][A-Za-z0-9_.:%-]*$")
        then
            return nil, "invalid layout page id: " .. tostring(page)
        end
        local tree, reason = Layout.from_order(order, { allowed_widgets = order })
        if not tree then
            return nil, "invalid layout defaults for " .. page .. ": " .. tostring(reason)
        end
    end
    return true
end

local function copy_orders(orders)
    local result = {}
    for page, values in pairs(orders or {}) do
        result[page] = {}
        for index, value in ipairs(values) do result[page][index] = value end
    end
    return result
end

local function default_tree(order)
    return assert(Layout.from_order(order, {
        allowed_widgets = order,
        axis = "horizontal",
        alternate_axes = true,
    }))
end

local function copy_trees(trees, defaults)
    local result = {}
    for page, order in pairs(defaults or {}) do
        local tree = trees and trees[page]
        result[page] = tree and assert(Layout.clone(tree, { allowed_widgets = order }))
            or default_tree(order)
    end
    return result
end

function M.path(environment)
    environment = environment or os.getenv
    if type(environment) ~= "function" then return nil end
    local config_home = environment_value(environment, "XDG_CONFIG_HOME")
    if not safe_absolute_path(config_home) then
        local home = environment_value(environment, "HOME")
        config_home = safe_absolute_path(home) and (home .. "/.config") or nil
    end
    return config_home and (config_home .. "/wtop/layout.yml") or nil
end

local function validate_v1(raw, defaults)
    local result = copy_orders(defaults)
    for page, order in pairs(raw.pages) do
        local expected = defaults[page]
        if not expected then
            return nil, "unknown layout page: " .. tostring(page)
        end
        if type(order) ~= "table" or order == I18n.Yaml.null then
            return nil, "layout page " .. tostring(page) .. " must be a sequence"
        end
        local allowed = {}
        for _, id in ipairs(expected) do allowed[id] = true end
        local seen = {}
        local normalized = {}
        for _, id in ipairs(order) do
            if type(id) ~= "string" or not allowed[id] then
                return nil, "unknown widget in " .. page .. ": " .. tostring(id)
            end
            if seen[id] then
                return nil, "duplicate widget in " .. page .. ": " .. id
            end
            seen[id] = true
            normalized[#normalized + 1] = id
        end
        for _, id in ipairs(expected) do
            if not seen[id] then normalized[#normalized + 1] = id end
        end
        result[page] = normalized
    end
    return result, copy_trees(nil, result)
end

local function model_node(raw, path, limits)
    if type(raw) ~= "table" or raw == I18n.Yaml.null then
        return nil, path .. " must be a mapping"
    end
    limits.nodes = limits.nodes + 1
    if limits.nodes > 511 then return nil, "layout tree exceeds 511 nodes" end
    if limits.depth > 32 then return nil, "layout tree exceeds depth 32" end
    if raw.type == "leaf" then
        for key in pairs(raw) do
            if key ~= "type" and key ~= "widget_id" then
                return nil, path .. " has unknown leaf key: " .. tostring(key)
            end
        end
        if type(raw.widget_id) ~= "string" then
            return nil, path .. ".widget_id must be a string"
        end
        return Layout.leaf(raw.widget_id)
    elseif raw.type == "split" then
        for key in pairs(raw) do
            if key ~= "type" and key ~= "axis" and key ~= "ratio_micros"
                and key ~= "gap" and key ~= "children"
            then
                return nil, path .. " has unknown split key: " .. tostring(key)
            end
        end
        if raw.axis ~= "horizontal" and raw.axis ~= "vertical" then
            return nil, path .. ".axis is invalid"
        end
        if type(raw.ratio_micros) ~= "number" or raw.ratio_micros % 1 ~= 0
            or raw.ratio_micros < 1 or raw.ratio_micros > 999999
        then
            return nil, path .. ".ratio_micros must be an integer from 1 to 999999"
        end
        if type(raw.gap) ~= "number" or raw.gap % 1 ~= 0 or raw.gap < 0 or raw.gap > 16 then
            return nil, path .. ".gap must be an integer from 0 to 16"
        end
        if type(raw.children) ~= "table" or #raw.children ~= 2 then
            return nil, path .. ".children must contain exactly two nodes"
        end
        for key in pairs(raw.children) do
            if type(key) ~= "number" or key < 1 or key > 2 or key % 1 ~= 0 then
                return nil, path .. ".children must be a dense sequence"
            end
        end
        local first_limits = { nodes = limits.nodes, depth = limits.depth + 1 }
        local first, first_error = model_node(raw.children[1], path .. ".children[1]", first_limits)
        if not first then return nil, first_error end
        limits.nodes = first_limits.nodes
        local second_limits = { nodes = limits.nodes, depth = limits.depth + 1 }
        local second, second_error = model_node(raw.children[2], path .. ".children[2]", second_limits)
        if not second then return nil, second_error end
        limits.nodes = second_limits.nodes
        return Layout.split(raw.axis, raw.ratio_micros / 1000000, { first, second }, { gap = raw.gap })
    end
    return nil, path .. " has unknown node type: " .. tostring(raw.type)
end

local function validate_v2(raw, defaults)
    local orders, trees = {}, {}
    for page in pairs(raw.pages) do
        if not defaults[page] then return nil, "unknown layout page: " .. tostring(page) end
    end
    for page, expected in pairs(defaults) do
        local tree
        if raw.pages[page] == nil then
            tree = default_tree(expected)
        else
            local limits = { nodes = 0, depth = 1 }
            local parse_error
            tree, parse_error = model_node(raw.pages[page], "pages." .. page, limits)
            if not tree then return nil, parse_error end
            local valid, info_or_error = Layout.validate(tree, { allowed_widgets = expected })
            if not valid then return nil, "invalid layout page " .. page .. ": " .. info_or_error end
            local seen = {}
            for _, id in ipairs(info_or_error.order) do seen[id] = true end
            local last = info_or_error.order[#info_or_error.order]
            for _, id in ipairs(expected) do
                if not seen[id] then
                    tree, parse_error = Layout.insert(tree, last, id, {
                        position = "below", allowed_widgets = expected,
                    })
                    if not tree then return nil, "cannot add widget " .. id .. ": " .. parse_error end
                    last, seen[id] = id, true
                end
            end
        end
        trees[page] = tree
        orders[page] = assert(Layout.to_order(tree, { allowed_widgets = expected }))
    end
    return orders, trees
end

function M.validate(raw, defaults)
    local valid_defaults, defaults_error = validate_defaults(defaults)
    if not valid_defaults then return nil, defaults_error end
    if type(raw) ~= "table" or raw == I18n.Yaml.null then
        return nil, "layout root must be a mapping"
    end
    for key in pairs(raw) do
        if key ~= "schema_version" and key ~= "pages" then
            return nil, "unknown layout key: " .. tostring(key)
        end
    end
    if raw.schema_version ~= 1 and raw.schema_version ~= 2 then
        return nil, "unsupported layout schema_version: " .. tostring(raw.schema_version)
    end
    if type(raw.pages) ~= "table" or raw.pages == I18n.Yaml.null then
        return nil, "layout pages must be a mapping"
    end

    if raw.schema_version == 1 then return validate_v1(raw, defaults) end
    return validate_v2(raw, defaults)
end

function M.parse(text, defaults, source)
    if type(text) ~= "string" then return nil, "layout content must be text" end
    local raw, parse_error = I18n.Yaml.parse(text, { source = source or "<layout>" })
    if not raw then return nil, parse_error end
    return M.validate(raw, defaults)
end

local function quote(value)
    return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"')
        :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

local function emit_node(lines, node, indent, sequence_item)
    local prefix = string.rep(" ", indent) .. (sequence_item and "- " or "")
    local body_indent = indent + (sequence_item and 2 or 0)
    lines[#lines + 1] = prefix .. "type: " .. node.type
    if node.type == "leaf" then
        lines[#lines + 1] = string.rep(" ", body_indent) .. "widget_id: " .. quote(node.widget_id)
        return
    end
    lines[#lines + 1] = string.rep(" ", body_indent) .. "axis: " .. node.axis
    lines[#lines + 1] = string.rep(" ", body_indent) .. "ratio_micros: "
        .. tostring(math.max(1, math.min(999999, math.floor(node.ratio * 1000000 + 0.5))))
    lines[#lines + 1] = string.rep(" ", body_indent) .. "gap: " .. tostring(node.gap)
    lines[#lines + 1] = string.rep(" ", body_indent) .. "children:"
    emit_node(lines, node.children[1], body_indent + 2, true)
    emit_node(lines, node.children[2], body_indent + 2, true)
end

function M.encode(orders, trees)
    local valid_orders, orders_error = validate_defaults(orders)
    if not valid_orders then error(orders_error, 2) end
    if trees ~= nil and type(trees) ~= "table" then error("layout trees must be a table", 2) end
    if trees then
        local pages = {}
        for page in pairs(orders) do pages[#pages + 1] = page end
        table.sort(pages)
        local lines = { "schema_version: 2", "pages:" }
        for _, page in ipairs(pages) do
            lines[#lines + 1] = "  " .. page .. ":"
            local tree = trees[page] or default_tree(orders[page])
            local valid, validation_error = Layout.validate(tree, { allowed_widgets = orders[page] })
            assert(valid, validation_error)
            emit_node(lines, tree, 4, false)
        end
        return table.concat(lines, "\n") .. "\n"
    end
    local pages = {}
    for page in pairs(orders) do pages[#pages + 1] = page end
    table.sort(pages)
    local lines = { "schema_version: 1", "pages:" }
    for _, page in ipairs(pages) do
        lines[#lines + 1] = "  " .. page .. ":"
        for _, id in ipairs(orders[page]) do
            lines[#lines + 1] = "    - \"" .. id .. "\""
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

function M.load(defaults, path)
    local valid_defaults, defaults_error = validate_defaults(defaults)
    if not valid_defaults then
        return {}, { state = "error", reason = defaults_error }, nil
    end
    path = path or M.path()
    if not path then
        return copy_orders(defaults), { state = "unavailable", reason = "HOME is not set" }, nil
    end
    if not safe_absolute_path(path) then
        return copy_orders(defaults), {
            state = "error", path = path, reason = "invalid layout path",
        }, nil
    end
    local text, read_error = FS.default:read(path, 1024 * 1024)
    if not text then
        if read_error and read_error.kind == "missing" then
            return copy_orders(defaults), { state = "default", path = path }, nil
        end
        local reason = read_error and read_error.kind == "too_large" and "layout exceeds 1 MiB"
            or tostring(read_error and read_error.message or "layout read failed")
        return copy_orders(defaults), { state = "error", path = path, reason = reason }, nil
    end
    local orders, trees_or_error = M.parse(text, defaults, path)
    if not orders then
        return copy_orders(defaults), { state = "error", path = path, reason = trees_or_error }, nil
    end
    return orders, { state = "loaded", path = path }, trees_or_error
end

local function ensure_directory(path)
    local current = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        current = current == "/" and (current .. part)
            or (current == "" and part or (current .. "/" .. part))
        local created, create_error = native.mkdir(current, 448)
        if not created then return nil, create_error end
    end
    return true
end

function M.save(orders, path, trees)
    local valid_orders, orders_error = validate_defaults(orders)
    if not valid_orders then return nil, orders_error end
    path = path or M.path()
    if not path then return nil, "HOME is not set" end
    if not safe_absolute_path(path) then return nil, "invalid layout path" end
    if not native.available then return nil, "native atomic writer is unavailable" end
    local directory = path:match("^(.*)/[^/]+$")
    if not directory then return nil, "layout path has no directory" end
    local ensured, ensure_error = ensure_directory(directory)
    if not ensured then return nil, ensure_error end
    local encoded, content = pcall(M.encode, orders, trees)
    if not encoded then return nil, tostring(content) end
    local called, written, write_error = pcall(native.atomic_write, path, content, 384)
    if not called then return nil, tostring(written) end
    return written, write_error
end

M.safe_absolute_path = safe_absolute_path

return M
