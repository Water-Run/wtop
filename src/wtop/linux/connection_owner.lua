-- Resolve a socket-table owner to the same live process that the process
-- collector sampled. A PID or descriptor from an earlier scan is not enough:
-- both can be reused before the operator opens the detail view.
local Parsers = require("wtop.linux.parsers")

local M = {}

local function integer(value, minimum)
  return type(value) == "number" and math.type(value) == "integer"
    and value >= minimum and value <= 2147483647
end

local function stat(fs, path, pid)
  local raw = fs:read(path, 65536)
  local parsed = raw and Parsers.process_stat(raw)
  return parsed and parsed.pid == pid and parsed or nil
end

function M.resolve(fs, connection, owner, processes)
  local pid = type(owner) == "table" and owner.pid
  local fd = type(owner) == "table" and owner.fd
  local fds = type(owner) == "table" and owner.fds
  local inode = type(connection) == "table" and connection.inode
  if not integer(pid, 1) or not integer(fd, 0)
      or type(inode) ~= "string" or #inode > 32
      or inode == "0" or not inode:match("^%d+$") then
    return nil, "owner_unavailable"
  end
  if type(fds) ~= "table" or #fds == 0 then fds = { fd } end
  if #fds > 4096 then return nil, "owner_unavailable" end
  for _, candidate in ipairs(fds) do
    if not integer(candidate, 0) then return nil, "owner_unavailable" end
  end
  local base = "/proc/" .. pid
  local before = stat(fs, base .. "/stat", pid)
  if not before then return nil, "owner_unavailable" end
  local matched = false
  for _, candidate in ipairs(fds) do
    if fs:readlink(base .. "/fd/" .. candidate) == "socket:[" .. inode .. "]" then
      matched = true
      break
    end
  end
  local after = stat(fs, base .. "/stat", pid)
  if not after or before.id ~= after.id
      or not matched then
    return nil, "owner_changed"
  end
  for _, process in ipairs(processes or {}) do
    if process.id == after.id and process.pid == pid then return process end
  end
  return nil, "process_not_sampled", after
end

return M
