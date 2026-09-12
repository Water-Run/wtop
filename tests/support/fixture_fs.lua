-- An in-memory filesystem for collector tests.
--
-- Most of wtop's hardware collectors only ever run on machines that have the
-- hardware.  On a VM without a GPU, without hwmon, without RAPL and without a
-- battery, thousands of lines of parsing never execute at all, so a fixture
-- filesystem is the only way to test them before a user does.
--
-- Directories are derived from the declared file paths, so a fixture only has
-- to list the files it wants; declare `dirs` explicitly when a test needs an
-- empty directory or a specific enumeration order.
local FS = require("wtop.linux.fs")

local M = {}

local function parent_of(path)
  return path:match("^(.*)/[^/]+$")
end

local function leaf_of(path)
  return path:match("([^/]+)$")
end

--- Build an FS over `files` (path -> content) and optional extras.
-- @param specification
--   files     table  absolute path -> string content
--   dirs      table  absolute path -> array of entry names (overrides derivation)
--   denied    table  absolute path -> true, reported as a permission error
--   links     table  absolute path -> link target
--   truncated table  absolute path -> true, directory listing reports truncation
function M.new(specification)
  specification = specification or {}
  local files = specification.files or {}
  local denied = specification.denied or {}
  local links = specification.links or {}
  local truncated = specification.truncated or {}

  -- Derive the directory tree so fixtures only declare leaves.
  local derived = {}
  local function register(path)
    local parent = parent_of(path)
    if not parent or parent == "" then return end
    local bucket = derived[parent]
    if not bucket then
      bucket = { order = {}, seen = {} }
      derived[parent] = bucket
      register(parent)
    end
    local name = leaf_of(path)
    if name and not bucket.seen[name] then
      bucket.seen[name] = true
      bucket.order[#bucket.order + 1] = name
    end
  end
  for path in pairs(files) do register(path) end
  for path in pairs(denied) do register(path) end
  for path in pairs(links) do register(path) end
  for path in pairs(specification.dirs or {}) do register(path) end

  local directories = {}
  for path, bucket in pairs(derived) do
    table.sort(bucket.order)
    directories[path] = bucket.order
  end
  for path, entries in pairs(specification.dirs or {}) do
    local copy = {}
    for index, name in ipairs(entries) do copy[index] = name end
    directories[path] = copy
  end

  return FS.new({
    root = "/",
    read_file = function(path, limit)
      if denied[path] then
        return nil, { kind = "denied", message = "permission denied", path = path }
      end
      local content = files[path]
      if content == nil then
        if directories[path] then
          return nil, { kind = "invalid", message = "is a directory", path = path }
        end
        return nil, { kind = "missing", message = "no such file", path = path }
      end
      if limit and #content > limit then
        return nil, { kind = "too_large", message = "file exceeds limit", path = path }
      end
      return content
    end,
    list_dir = function(path, limit)
      if denied[path] then
        return nil, { kind = "denied", message = "permission denied", path = path }
      end
      local entries = directories[path]
      if not entries then
        return nil, { kind = "missing", message = "no such directory", path = path }
      end
      local result, cut = {}, false
      for index, name in ipairs(entries) do
        if limit and index > limit then
          cut = true
          break
        end
        result[index] = name
      end
      return result, nil, cut or truncated[path] == true
    end,
    read_link = function(path)
      local target = links[path]
      if target then return target end
      return nil, { kind = "missing", message = "not a symlink", path = path }
    end,
    path_type = function(path)
      if directories[path] then return "directory" end
      if links[path] then return "symlink" end
      if files[path] ~= nil then return "file" end
      return nil, { kind = "missing", message = "no such path", path = path }
    end,
  })
end

--- Merge several fixture specifications into one.
function M.merge(...)
  local result = { files = {}, dirs = {}, denied = {}, links = {}, truncated = {} }
  for index = 1, select("#", ...) do
    local part = select(index, ...) or {}
    for _, key in ipairs({ "files", "dirs", "denied", "links", "truncated" }) do
      for path, value in pairs(part[key] or {}) do result[key][path] = value end
    end
  end
  return result
end

return M
