-- One-generation backups for the user's configuration files. A successful
-- load refreshes <path>.bak so it holds the last known-good content that
-- differs from the current file; a load that cannot read or parse the main
-- file retries the backup before falling back to defaults.
local FS = require("wtop.linux.fs")
local native = require("wtop.native")

local M = {}

local LIMIT = 1024 * 1024

function M.backup_path(path)
    return path .. ".bak"
end

-- Best-effort copy of the current file to its backup location. A missing
-- source is a successful no-op; callers never fail a save because the backup
-- could not be written.
function M.capture(path)
    local text, read_error = FS.default:read(path, LIMIT)
    if not text then
        if read_error and read_error.kind == "missing" then return true end
        return nil, read_error and read_error.message or "backup read failed"
    end
    if not native.available or type(native.atomic_write) ~= "function" then
        return nil, "native atomic writer is unavailable"
    end
    local called, written, write_error = pcall(native.atomic_write,
        M.backup_path(path), text, 384)
    if not called then return nil, tostring(written) end
    if not written then return nil, write_error end
    return true
end

-- Refresh the backup after a successful load so the backup trails the file
-- by at most one saved generation. Skipped silently when writing is not
-- possible; recovery simply keeps whatever backup exists.
function M.refresh(path)
    local text = FS.default:read(path, LIMIT)
    if not text then return true end
    local existing = FS.default:read(M.backup_path(path), LIMIT)
    if existing == text then return true end
    M.capture(path)
    return true
end

function M.read(path)
    local text, read_error = FS.default:read(M.backup_path(path), LIMIT)
    if not text then return nil, read_error end
    return text
end

return M
