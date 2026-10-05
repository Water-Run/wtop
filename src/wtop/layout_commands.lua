-- Layout import and export as explicit commands. Export writes the layout
-- the TUI would load right now (persisted file or built-in defaults) as
-- schema-v2 YAML; import validates a file and installs it as the persisted
-- layout, keeping the previous file as the one-generation backup; migrate
-- rewrites the persisted file itself in the form the current encoder
-- produces, without a session, so upgrading an old file is scriptable the
-- way copying one already is.
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
    local orders, status, trees, workspaces, active, columns = LayoutStore.load(
        Workspace.default_orders(), layout_path)
    if status.state == "error" then
        -- A broken persisted layout must not block the export: dumping the
        -- defaults is the recovery starting point, with the reason attached.
        orders = Workspace.default_orders()
        trees, workspaces, active, columns = nil, nil, nil, nil
        status = { state = "default",
            reason = "persisted layout ignored: " .. tostring(status.reason) }
    end
    -- encode() falls back to the linear v1 form without trees; an empty tree
    -- table keeps the v2 branch, which fills each page from its default tree.
    -- A workspace set exports as v3 so a backup carries every arrangement, not
    -- only the one that happened to be live; a column set makes it v4, so an
    -- export is a backup that can actually be restored.
    local encoded, content = pcall(LayoutStore.encode, orders, trees or {}, workspaces, active,
        columns)
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
    local orders, trees_or_error, workspaces, active, columns =
        LayoutStore.parse(text, defaults, input_path)
    if not orders then
        return nil, "not a valid layout file: " .. tostring(trees_or_error)
    end
    -- A v3 file carries its own workspace set; importing it must install all of
    -- them, not just whichever one happened to be active when it was written.
    -- A v4 file carries the column set with the same intent: importing a backup
    -- restores the table the user had, not just the arrangement around it.
    local saved, save_error = LayoutStore.save(orders, target_path, trees_or_error,
        workspaces, active, columns)
    if not saved then
        return nil, "cannot install the layout: " .. tostring(save_error)
    end
    return true, LayoutStore.path()
end

-- In-place migration of the persisted layout. The TUI rewrites the file at
-- exit whenever a session edits something, which is how an old schema gets
-- upgraded in normal use; this command does the same rewrite without a
-- session, for the same reason --import exists: provisioning and backup
-- hygiene should not require driving a full-screen interface.
--
-- The states come from load rather than a separate read, because load is
-- where the product already decided what each broken file means: an
-- unreadable or unparseable file with a usable backup generation is
-- *recovered*, and migrating it is what writes the recovery down; without a
-- backup it is an error, and the command must leave the file exactly as it
-- found it -- a migration that loses work while reporting success would be
-- worse than no migration.
function M.migrate(layout_path)
    layout_path = layout_path or LayoutStore.path()
    if not layout_path then
        return true, "no layout path (HOME is not set); nothing to migrate"
    end
    local orders, status, trees, workspaces, active, columns = LayoutStore.load(
        Workspace.default_orders(), layout_path)
    if status.state == "error" then
        return nil, "cannot migrate " .. layout_path .. ": "
            .. tostring(status.reason)
    end
    if status.state ~= "loaded" and status.state ~= "recovered_backup" then
        -- "default" (no file yet) and "unavailable" have nothing on disk to
        -- bring forward, and saying so is the honest success.
        return true, "no persisted layout at " .. layout_path .. "; nothing to migrate"
    end
    local encoded, content = pcall(LayoutStore.encode, orders, trees or {},
        workspaces, active, columns)
    if not encoded then return nil, tostring(content) end
    local current = FS.default:read(layout_path, MAX_LAYOUT_BYTES)
    if current == content then
        -- Byte-equal is the only honest "already current": the file is in the
        -- form this build's encoder produces. Rewriting it anyway would churn
        -- the backup generation for no change the next reader could observe.
        return true, layout_path .. " is already in the current form"
    end
    local saved, save_error = LayoutStore.save(orders, layout_path, trees,
        workspaces, active, columns)
    if not saved then
        return nil, "cannot write the migrated layout: " .. tostring(save_error)
    end
    return true, "migrated " .. layout_path
        .. (status.state == "recovered_backup"
            and " (recovered from the backup generation; the broken file is kept as .bak)"
            or " (the previous file is kept as .bak)")
end

return M
