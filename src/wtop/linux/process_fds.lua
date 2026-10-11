-- Bounded, on-demand /proc/<pid>/fd inventory. Targets remain in the TUI only.
local Actions = require("wtop.actions")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Parsers = require("wtop.linux.parsers")

local M = {}
local DIRECTORY_SCAN_LIMIT = 4096

local function verify(fs, process)
  if not Actions.validate_identity(process) then
    return nil, "unavailable", "process_fd_unavailable"
  end
  local raw, err = fs:read("/proc/" .. process.pid .. "/stat", 65536)
  if not raw then
    return nil, FS.error_status(err), "process_fd_unavailable"
  end
  local current = Parsers.process_stat(raw)
  if not current then return nil, "error", "process_fd_unavailable" end
  if current.pid ~= process.pid or current.starttime_ticks ~= process.starttime_ticks then
    return nil, "unavailable", "process_identity_changed"
  end
  return true
end

local function fd_ids(names)
  local ids = {}
  for _, name in ipairs(names) do
    local digits = type(name) == "string" and name:match("^(%d+)$")
    local number = digits and tonumber(digits)
    if number and math.type(number) == "integer" and number <= 2147483647
        and digits == tostring(number) then
      ids[#ids + 1] = number
    end
  end
  table.sort(ids)
  return ids
end

local function fdinfo_fields(raw)
  local result = { issues = {} }
  local fields = { pos = "position", flags = "flags",
    mnt_id = "mount_id", ino = "inode" }
  for line in raw:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_]+):%s*(%S+)%s*$")
    local field = key and fields[key]
    if field then
      local valid = #value <= 32 and ((key == "flags"
          and value:match("^[0-7]+$")) or (key ~= "flags"
          and value:match("^%d+$")))
      if valid and result[field] == nil then
        result[field] = value
      else
        result.issues[#result.issues + 1] = field
      end
    end
  end
  for _, field in ipairs({ "position", "flags" }) do
    if result[field] == nil then result.issues[#result.issues + 1] = field end
  end
  result.quality = #result.issues > 0 and "partial" or "fresh"
  return result
end

function M.list(fs, process, maximum)
  fs = fs or FS.default
  maximum = maximum or 128
  if type(maximum) ~= "number" or math.type(maximum) ~= "integer"
      or maximum < 1 or maximum > 256 then
    error("maximum descriptors must be an integer in 1..256", 2)
  end
  local result = { status = "unavailable", entries = {}, issues = {},
    truncated = false }
  local verified, status, reason = verify(fs, process)
  if not verified then
    result.status, result.reason = status, reason
    return result
  end
  local base = "/proc/" .. process.pid .. "/fd"
  result.pid, result.source = process.pid, base
  local names, err, cut = fs:list(base, DIRECTORY_SCAN_LIMIT)
  if not names then
    result.status = FS.error_status(err)
    result.reason = "process_fd_unavailable"
    return result
  end
  local ids = fd_ids(names)
  result.truncated = cut == true or #ids > maximum
  for index = 1, math.min(#ids, maximum) do
    local fd = ids[index]
    local path = base .. "/" .. fd
    local target, read_error = fs:readlink(path)
    local entry = { fd = fd }
    if type(target) == "string" and target ~= "" then
      entry.target_truncated = #target > 512
      entry.target = Common.safe_text(target, 512)
      entry.status = "ok"
      if entry.target_truncated then result.partial = true end
    else
      entry.status = FS.error_status(read_error)
      result.partial = true
      if #result.issues < 64 then
        result.issues[#result.issues + 1] = {
          fd = fd, source = path, status = entry.status,
          reason = read_error and read_error.message or "readlink_failed",
        }
      end
    end
    result.entries[#result.entries + 1] = entry
  end
  -- A PID can disappear and be reused while links are read. No collected
  -- target is displayed unless the process still has the sampled start time.
  local still_valid, final_status, final_reason = verify(fs, process)
  if not still_valid then
    result.entries, result.issues = {}, {}
    result.status, result.reason = final_status, final_reason
    result.partial = nil
    return result
  end
  result.status = "ok"
  result.quality = (result.partial or result.truncated) and "partial" or "fresh"
  return result
end

function M.inspect(fs, process, fd)
  fs = fs or FS.default
  local result = { status = "unavailable", fd = fd }
  if type(fd) ~= "number" or math.type(fd) ~= "integer"
      or fd < 0 or fd > 2147483647 then
    result.reason = "process_fd_unavailable"
    return result
  end
  local valid, status, reason = verify(fs, process)
  if not valid then
    result.status, result.reason = status, reason
    return result
  end
  result.pid = process.pid
  local base = "/proc/" .. process.pid
  local link_path = base .. "/fd/" .. fd
  local target, link_error = fs:readlink(link_path)
  if type(target) ~= "string" or target == "" then
    result.status = FS.error_status(link_error)
    result.reason = "process_fd_unavailable"
    return result
  end
  local raw, info_error = fs:read_at(base .. "/fdinfo/" .. fd, 0, 1024)
  local target_after = fs:readlink(link_path)
  local still_valid, final_status, final_reason = verify(fs, process)
  if not still_valid or target_after ~= target then
    result.status = still_valid and "unavailable" or final_status
    result.reason = still_valid and "process_fd_changed" or final_reason
    return result
  end
  result.target_truncated = #target > 512
  result.target = Common.safe_text(target, 512)
  if raw == nil then
    result.status = FS.error_status(info_error)
    result.reason = "process_fdinfo_unavailable"
    return result
  end
  local parsed = fdinfo_fields(raw)
  for key, value in pairs(parsed) do result[key] = value end
  result.source = base .. "/fdinfo/" .. fd
  result.status = "ok"
  if result.target_truncated then result.quality = "partial" end
  return result
end

return M
