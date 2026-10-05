local I18n = require("wtop.i18n")
local Layout = require("wtop.model.layout")
local ProcessColumns = require("wtop.model.process_columns")
local FS = require("wtop.linux.fs")
local native = require("wtop.native")
local ConfigPath = require("wtop.config_path")
local FileBackup = require("wtop.file_backup")

local M = {}

local MAX_PATH_BYTES = 4096
local MAX_PAGES = 64
-- A workspace is a name plus a full set of per-page trees.  The bound keeps a
-- hand-edited or generated file from turning into unbounded state, and sixteen
-- is far more arrangements than anyone keeps.
local MAX_WORKSPACES = 16
local MAX_WORKSPACE_NAME_BYTES = 64
-- Not a translated string: this is an identifier written into the file and
-- compared against it on the next load, so it must not move with the locale.
M.DEFAULT_WORKSPACE = "default"

-- The process table's column set is part of the persisted layout, which means
-- the store has to recognise a valid column key without owning the catalogue.
-- It reads the vocabulary from the model rather than repeating the list, so a
-- column added there is valid here by construction instead of by a second edit
-- that a future version can forget.
local COLUMN_KEYS = {}
for _, key in ipairs(ProcessColumns.keys()) do COLUMN_KEYS[key] = true end

-- The name rule lives in the layout model, so the file and the live session
-- cannot disagree about which names exist.  They used to: a second copy of the
-- pattern here meant a name could be accepted on the way out and rejected on the
-- way back in, and one unusable key fails the whole file rather than the entry.
local function workspace_name_ok(name)
    return Layout.workspace_name_ok(name)
end

local function safe_absolute_path(value)
    return ConfigPath.safe_absolute(value)
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
    return ConfigPath.file("layout.yml", environment)
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
            -- Widgets added by a newer wtop have to join a layout that was
            -- saved without them.  Inserting each one below the previous
            -- built a right-leaning chain: every insert halved the remaining
            -- space, so after nine additions the last widget held 1/512 of the
            -- page and the responsive solver collapsed all of them away.
            --
            -- Instead the new widgets become one balanced subtree placed beside
            -- the saved layout, with a ratio proportional to how many leaves
            -- each side holds.  The user's arrangement and ratios survive, and
            -- the additions get a fair share.
            local seen = {}
            for _, id in ipairs(info_or_error.order) do seen[id] = true end
            local additions = {}
            for _, id in ipairs(expected) do
                if not seen[id] then additions[#additions + 1] = id end
            end
            if #additions > 0 then
                local existing = #info_or_error.order
                local addition, addition_error = Layout.from_order(additions, {
                    allowed_widgets = expected,
                    axis = "horizontal",
                    alternate_axes = true,
                })
                if not addition then
                    return nil, "cannot add widgets to " .. page .. ": " .. tostring(addition_error)
                end
                local ratio = existing / (existing + #additions)
                -- Layout.split rejects the degenerate ends of the range.
                ratio = math.max(0.05, math.min(0.95, ratio))
                tree, parse_error = Layout.split("vertical", ratio, { tree, addition },
                    { gap = 1, allowed_widgets = expected })
                if not tree then
                    return nil, "cannot add widgets to " .. page .. ": " .. tostring(parse_error)
                end
            end
        end
        trees[page] = tree
        orders[page] = assert(Layout.to_order(tree, { allowed_widgets = expected }))
    end
    return orders, trees
end

-- A v3 file is a set of named workspaces plus the one that was active.  Each
-- workspace is validated exactly as a v2 page set is, so a layout that reads
-- today reads the same inside a workspace tomorrow.  The active workspace is
-- projected back into the v1/v2 shape that every caller already understands,
-- which is what keeps this additive rather than a rewrite of the store's API.
local function validate_v3(raw, defaults)
    if type(raw.workspaces) ~= "table" or raw.workspaces == I18n.Yaml.null then
        return nil, "layout workspaces must be a mapping"
    end
    local count = 0
    for name in pairs(raw.workspaces) do
        count = count + 1
        if count > MAX_WORKSPACES then
            return nil, "layout exceeds " .. MAX_WORKSPACES .. " workspaces"
        end
        if not workspace_name_ok(name) then
            return nil, "invalid workspace name: " .. tostring(name)
        end
    end
    if count == 0 then return nil, "layout must define at least one workspace" end

    local workspaces = {}
    for name, body in pairs(raw.workspaces) do
        if type(body) ~= "table" or body == I18n.Yaml.null then
            return nil, "workspace " .. name .. " must be a mapping"
        end
        for key in pairs(body) do
            if key ~= "pages" then
                return nil, "unknown workspace key in " .. name .. ": " .. tostring(key)
            end
        end
        if type(body.pages) ~= "table" or body.pages == I18n.Yaml.null then
            return nil, "workspace " .. name .. " must define pages"
        end
        local page_body = {
            schema_version = 2,
            pages = body.pages,
        }
        local orders, trees_or_error = validate_v2(page_body, defaults)
        if not orders then
            return nil, "workspace " .. name .. ": " .. tostring(trees_or_error)
        end
        workspaces[name] = trees_or_error
    end

    local active = raw.active
    if active == nil or active == I18n.Yaml.null then
        -- A file that names workspaces but not the active one still has to say
        -- which layout is on screen; take the first by name so the choice is
        -- stable rather than dependent on hash order.
        local names = {}
        for name in pairs(workspaces) do names[#names + 1] = name end
        table.sort(names)
        active = names[1]
    end
    if not workspace_name_ok(active) or not workspaces[active] then
        return nil, "layout active workspace does not exist: " .. tostring(active)
    end

    local trees = workspaces[active]
    local orders = {}
    for page, tree in pairs(trees) do
        local ok, info_or_error = Layout.validate(tree, { allowed_widgets = defaults[page] })
        if not ok then return nil, "invalid active layout page " .. page end
        orders[page] = info_or_error.order
    end
    return orders, copy_trees(trees, defaults), workspaces, active
end

-- A stored column set is either the list the user chose or it is not
-- readable, and the file is refused rather than repaired.  The model has a
-- total repair for exactly this ambiguity, and it is the right tool for a
-- value that arrives in memory; at the file boundary the store has one
-- outcome per file.  Refusing keeps a typo visible -- the reason reaches the
-- status line, and the one-generation backup is the way back -- where a
-- silently substituted list would put columns back on screen that the user
-- turned off and say nothing about why.
local function parse_columns(value)
    if type(value) ~= "table" or value == I18n.Yaml.null then
        return nil, "layout process_columns must be a sequence"
    end
    -- Density is checked, not just the shape of the keys.  A hole makes ipairs
    -- stop there, so a list with one reads as the part before it -- and the
    -- reason would name a column as missing rather than the hole that lost it.
    local keyed, indexed = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil, "layout process_columns must be a dense sequence"
        end
        keyed = keyed + 1
    end
    for _ in ipairs(value) do indexed = indexed + 1 end
    if keyed ~= indexed then
        return nil, "layout process_columns must be a dense sequence"
    end
    local seen, result = {}, {}
    for _, key in ipairs(value) do
        if type(key) ~= "string" or not COLUMN_KEYS[key] then
            return nil, "unknown process column: " .. tostring(key)
        end
        if seen[key] then
            return nil, "duplicate process column: " .. key
        end
        seen[key] = true
        result[#result + 1] = key
    end
    -- The identifying columns are an invariant of the model, not a default the
    -- user can turn off.  Checking it here makes it a property of the file as
    -- well, so a hand-edited layout cannot describe a table nobody can act on.
    for _, key in ipairs(ProcessColumns.keys()) do
        if ProcessColumns.is_required(key) and not seen[key] then
            return nil, "layout process_columns is missing " .. key
        end
    end
    return result
end

-- A page body is either a nested tree (a mapping) or the flat list of widget
-- ids the first version stored.  The v4 encoder writes whichever the session
-- has, so the loader tells them apart instead of assuming the newest shape: a
-- v4 file whose pages are ids is still readable, and one whose pages are trees
-- is read as trees.  Any mapping means the tree form -- a file mixing the two
-- has a page the chosen reader rejects, which is reported rather than guessed.
local function has_tree_body(pages)
    for _, body in pairs(pages) do
        if type(body) == "table" then
            for key in pairs(body) do
                if type(key) == "string" then return true end
            end
        end
    end
    return false
end

-- A v4 file is one of the earlier bodies plus the process table's column set.
-- The layout half is validated by the version it actually is -- the trees,
-- ratios and workspace rules did not change -- so v4 stays additive: it is the
-- same three shapes with one more top-level key, not a fourth layout model.
local function validate_v4(raw, defaults)
    local has_workspaces = raw.workspaces ~= nil and raw.workspaces ~= I18n.Yaml.null
    local has_pages = raw.pages ~= nil and raw.pages ~= I18n.Yaml.null
    if has_workspaces and has_pages then
        -- Encoding never writes both, so choosing one of them would read the
        -- other as absent and then drop it on the next save.
        return nil, "layout must define pages or workspaces, not both"
    end
    local columns, columns_error = parse_columns(raw.process_columns)
    if not columns then return nil, columns_error end
    if has_workspaces then
        local orders, trees_or_error, workspaces, active = validate_v3(raw, defaults)
        if not orders then return nil, trees_or_error end
        return orders, trees_or_error, workspaces, active, columns
    end
    if not has_pages then
        return nil, "layout must define pages or workspaces"
    end
    if type(raw.pages) ~= "table" or raw.pages == I18n.Yaml.null then
        return nil, "layout pages must be a mapping"
    end
    if has_tree_body(raw.pages) then
        local orders, trees_or_error = validate_v2(raw, defaults)
        if not orders then return nil, trees_or_error end
        return orders, trees_or_error, nil, nil, columns
    end
    local orders, trees_or_error = validate_v1(raw, defaults)
    if not orders then return nil, trees_or_error end
    return orders, trees_or_error, nil, nil, columns
end

-- Each version has an exact key set.  Allowing a key a version does not define
-- would make a file's meaning depend on which part of it is read: a v3 file
-- carrying process_columns would be accepted and then have the column set
-- ignored, so the user's table would silently reset while the layouts came
-- back.  Naming the sets explicitly is also what lets a new version add a key
-- without every older version needing a branch that knows to skip it.
local KNOWN_KEYS = {
    [1] = { schema_version = true, pages = true },
    [2] = { schema_version = true, pages = true },
    [3] = { schema_version = true, workspaces = true, active = true },
    [4] = { schema_version = true, pages = true, workspaces = true, active = true,
        process_columns = true },
}

function M.validate(raw, defaults)
    local valid_defaults, defaults_error = validate_defaults(defaults)
    if not valid_defaults then return nil, defaults_error end
    if type(raw) ~= "table" or raw == I18n.Yaml.null then
        return nil, "layout root must be a mapping"
    end
    local allowed = KNOWN_KEYS[raw.schema_version]
    if not allowed then
        return nil, "unsupported layout schema_version: " .. tostring(raw.schema_version)
    end
    for key in pairs(raw) do
        if not allowed[key] then
            return nil, "unknown layout key: " .. tostring(key)
        end
    end
    if raw.schema_version == 4 then return validate_v4(raw, defaults) end
    if raw.schema_version == 3 then return validate_v3(raw, defaults) end
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

local function sorted_page_names(orders)
    local pages = {}
    for page in pairs(orders) do pages[#pages + 1] = page end
    table.sort(pages)
    return pages
end

local function emit_pages(lines, indent, trees, orders)
    lines[#lines + 1] = string.rep(" ", indent) .. "pages:"
    for _, page in ipairs(sorted_page_names(orders)) do
        lines[#lines + 1] = string.rep(" ", indent + 2) .. page .. ":"
        local tree = trees[page] or default_tree(orders[page])
        local valid, validation_error = Layout.validate(tree, { allowed_widgets = orders[page] })
        assert(valid, validation_error)
        emit_node(lines, tree, indent + 4, false)
    end
end

-- Written last so the file reads as "the layout, then the one view choice that
-- sits beside it" -- and so the block is at a fixed depth regardless of which
-- of the three bodies precedes it.
local function emit_columns(lines, indent, columns)
    lines[#lines + 1] = string.rep(" ", indent) .. "process_columns:"
    for _, key in ipairs(columns) do
        lines[#lines + 1] = string.rep(" ", indent + 2) .. "- " .. quote(key)
    end
end

-- The body a session saves is whichever of the three it actually has, and the
-- version number says which: v3 with a workspace set, v2 with trees, v1 with
-- neither.  Carrying a column set makes the file v4 whichever body it is, so
-- the version tracks what the file can hold rather than how the session got
-- there -- and a session that never opens the column editor keeps writing the
-- version it had.
function M.encode(orders, trees, workspaces, active, columns)
    local valid_orders, orders_error = validate_defaults(orders)
    if not valid_orders then error(orders_error, 2) end
    if trees ~= nil and type(trees) ~= "table" then error("layout trees must be a table", 2) end
    if workspaces ~= nil and type(workspaces) ~= "table" then
        error("layout workspaces must be a table", 2)
    end
    -- Normalized rather than validated: the encoder's contract is that what it
    -- writes, this same loader will read, and a save must not fail over a
    -- column set that the model already keeps canonical.  The file it produces
    -- is still strict -- only a hand-edited file is refused.
    if columns ~= nil then
        if type(columns) ~= "table" then error("layout process_columns must be a table", 2) end
        columns = ProcessColumns.normalize(columns)
    end
    -- An empty set is not a broken workspace set: it is a session that never
    -- named one, and it has to be able to save like any other.  Falling through
    -- keeps such a file at v2, which is what it means.
    if workspaces and next(workspaces) ~= nil then
        local names = {}
        for name in pairs(workspaces) do names[#names + 1] = name end
        table.sort(names)
        assert(#names <= MAX_WORKSPACES,
            "layout exceeds " .. MAX_WORKSPACES .. " workspaces")
        for _, name in ipairs(names) do
            assert(workspace_name_ok(name), "invalid workspace name: " .. tostring(name))
        end
        -- An active name that is not in the set would produce a file this same
        -- loader rejects, so it is resolved here rather than at load time.
        local chosen = active
        if chosen == nil or not workspaces[chosen] then chosen = names[1] end
        local lines = {
            "schema_version: " .. (columns and 4 or 3),
            "active: " .. quote(chosen),
            "workspaces:",
        }
        for _, name in ipairs(names) do
            -- Quoted, because a workspace name may contain a space and the
            -- reader's unquoted-key rule does not.  A workspace called
            -- "my setup" was accepted here and written as a bare key, which
            -- this same loader then refused -- so the exit save replaced a good
            -- layout.yml with a file the next start could not read at all.
            lines[#lines + 1] = "  " .. quote(name) .. ":"
            emit_pages(lines, 4, workspaces[name], orders)
        end
        if columns then emit_columns(lines, 0, columns) end
        return table.concat(lines, "\n") .. "\n"
    end
    if trees then
        local lines = { "schema_version: " .. (columns and 4 or 2) }
        emit_pages(lines, 0, trees, orders)
        if columns then emit_columns(lines, 0, columns) end
        return table.concat(lines, "\n") .. "\n"
    end
    local pages = {}
    for page in pairs(orders) do pages[#pages + 1] = page end
    table.sort(pages)
    local lines = { "schema_version: " .. (columns and 4 or 1), "pages:" }
    for _, page in ipairs(pages) do
        lines[#lines + 1] = "  " .. page .. ":"
        for _, id in ipairs(orders[page]) do
            lines[#lines + 1] = "    - \"" .. id .. "\""
        end
    end
    if columns then emit_columns(lines, 0, columns) end
    return table.concat(lines, "\n") .. "\n"
end

local function recover_from_backup(defaults, path)
    local text = FileBackup.read(path)
    if not text then return nil, nil end
    local orders, trees, workspaces, active, columns = M.parse(text, defaults,
        FileBackup.backup_path(path))
    if not orders then return nil, nil end
    return orders, trees, workspaces, active, columns
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
        local orders, trees, workspaces, active, columns = recover_from_backup(defaults, path)
        if orders then
            return orders, { state = "recovered_backup", path = path,
                reason = reason }, trees, workspaces, active, columns
        end
        return copy_orders(defaults), { state = "error", path = path, reason = reason }, nil
    end
    local orders, trees_or_error, workspaces, active, columns = M.parse(text, defaults, path)
    if not orders then
        local recovered, trees, recovered_workspaces, recovered_active, recovered_columns =
            recover_from_backup(defaults, path)
        if recovered then
            return recovered, { state = "recovered_backup", path = path,
                reason = trees_or_error }, trees, recovered_workspaces, recovered_active,
            recovered_columns
        end
        return copy_orders(defaults), { state = "error", path = path, reason = trees_or_error }, nil
    end
    FileBackup.refresh(path)
    return orders, { state = "loaded", path = path }, trees_or_error, workspaces, active, columns
end

local function ensure_directory(path)
    path = ConfigPath.normalize(path)
    local current, remainder
    if path:match("^[A-Za-z]:/") then
        current, remainder = path:sub(1, 3), path:sub(4)
    else
        current, remainder = "/", path
    end
    for part in remainder:gmatch("[^/]+") do
        current = current == "/" and (current .. part)
            or (current:sub(-1) == "/" and (current .. part)
                or (current .. "/" .. part))
        local created, create_error = native.mkdir(current, 448)
        if not created then return nil, create_error end
    end
    return true
end

function M.save(orders, path, trees, workspaces, active, columns)
    local valid_orders, orders_error = validate_defaults(orders)
    if not valid_orders then return nil, orders_error end
    path = path or M.path()
    if not path then return nil, "HOME is not set" end
    if not safe_absolute_path(path) then return nil, "invalid layout path" end
    if not native.available then return nil, "native atomic writer is unavailable" end
    path = ConfigPath.normalize(path)
    local directory = path:match("^(.*)/[^/]+$")
    if not directory then return nil, "layout path has no directory" end
    local ensured, ensure_error = ensure_directory(directory)
    if not ensured then return nil, ensure_error end
    -- Keep the replaced file recoverable before the atomic write lands.
    FileBackup.capture(path)
    local encoded, content = pcall(M.encode, orders, trees, workspaces, active, columns)
    if not encoded then return nil, tostring(content) end
    local called, written, write_error = pcall(native.atomic_write, path, content, 384)
    if not called then return nil, tostring(written) end
    return written, write_error
end

M.safe_absolute_path = safe_absolute_path

return M
