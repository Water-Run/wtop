-- Layout import and export as explicit commands. Export writes the layout
-- the TUI would load right now (persisted file or built-in defaults) as
-- schema-v2 YAML; import validates a file and installs it as the persisted
-- layout, keeping the previous file as the one-generation backup.
local LayoutStore = require("wtop.layout_store")
local Workspace = require("wtop.workspace")
local FS = require("wtop.linux.fs")
local native = require("wtop.native")

local M = {}

local MAX_LAYOUT_BYTES = 1024 * 1024

function M.export(output_path, layout_path)
    if type(output_path) ~= "string" or output_path == "" then
        return nil, "an output path is required"
    end
    local orders, status, trees = LayoutStore.load(
        Workspace.default_orders(), layout_path)
    if status.state == "error" then
        -- A broken persisted layout must not block the export: dumping the
        -- defaults is the recovery starting point, with the reason attached.
        orders = Workspace.default_orders()
        trees = nil
        status = { state = "default",
            reason = "persisted layout ignored: " .. tostring(status.reason) }
    end
    -- encode() falls back to the linear v1 form without trees; an empty tree
    -- table keeps the v2 branch, which fills each page from its default tree.
    local encoded, content = pcall(LayoutStore.encode, orders, trees or {})
    if not encoded then return nil, tostring(content) end
    if native.available and type(native.atomic_write) == "function" then
        local written, write_error = native.atomic_write(output_path, content, 384)
        if not written then return nil, write_error or "layout export failed" end
    else
        local handle, open_error = io.open(output_path, "wb")
        if not handle then return nil, tostring(open_error) end
        handle:write(content)
        handle:close()
    end
    return true, ("%s (%s%s)"):format(output_path,
        status.state == "loaded" and "persisted layout" or "default layout",
        status.reason and "; " .. status.reason or "")
end

function M.import(input_path, target_path)
    if type(input_path) ~= "string" or input_path == "" then
        return nil, "an input path is required"
    end
    local text, read_error = FS.default:read(input_path, MAX_LAYOUT_BYTES)
    if not text then
        return nil, "cannot read " .. input_path .. ": "
            .. tostring(read_error and read_error.message or read_error)
    end
    local defaults = Workspace.default_orders()
    local orders, trees_or_error = LayoutStore.parse(text, defaults, input_path)
    if not orders then
        return nil, "not a valid layout file: " .. tostring(trees_or_error)
    end
    local saved, save_error = LayoutStore.save(orders, target_path, trees_or_error)
    if not saved then
        return nil, "cannot install the layout: " .. tostring(save_error)
    end
    return true, LayoutStore.path()
end

return M
