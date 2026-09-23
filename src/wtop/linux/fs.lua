local ok_native, native = pcall(require, "wtop.native")

local FS = {}
FS.__index = FS

local ERRNO_KIND = {
  [1] = "denied",       -- EPERM
  [2] = "missing",      -- ENOENT
  [3] = "missing",      -- Win32 ERROR_PATH_NOT_FOUND
  [5] = "denied",       -- Win32 ERROR_ACCESS_DENIED
  [13] = "denied",      -- EACCES
  [20] = "missing",     -- ENOTDIR
}

local function classify_error(message, errno)
  if ERRNO_KIND[errno] then return ERRNO_KIND[errno] end
  message = tostring(message or "io_error")
  local lower = message:lower()
  if lower:find("permission denied", 1, true) then
    return "denied"
  end
  if lower:find("no such file", 1, true) or lower:find("not found", 1, true) then
    return "missing"
  end
  return "io_error"
end

local function default_read_file(path, limit)
  if ok_native and native and native.available and type(native.readfile) == "function" then
    local called, content, err, errno = pcall(
      native.readfile, path, limit or (4 * 1024 * 1024))
    if not called then
      return nil, { kind = "io_error", message = tostring(content), path = path }
    end
    if content ~= nil then return content end
    local kind = classify_error(err, errno)
    if errno == 40 then kind = "symlink" end
    if errno == 22 then kind = "not_regular" end
    if errno == 27 then kind = "too_large" end
    return nil, { kind = kind, message = tostring(err), path = path, errno = errno }
  end
  local file, open_error = io.open(path, "rb")
  if not file then
    return nil, { kind = classify_error(open_error), message = tostring(open_error), path = path }
  end
  local content, read_error
  if limit then
    content, read_error = file:read(limit + 1)
  else
    content, read_error = file:read("*a")
  end
  local close_ok, close_error = file:close()
  if content == nil then
    -- Lua returns nil (without an error string) when a fixed-size read starts
    -- at EOF.  That is a valid empty regular file, not an I/O failure.
    if read_error ~= nil then
      return nil, { kind = "io_error", message = tostring(read_error), path = path }
    end
    content = ""
  end
  if limit and #content > limit then
    return nil, { kind = "too_large", message = "file_exceeds_limit", path = path, limit = limit }
  end
  if close_ok == nil then
    return nil, { kind = "io_error", message = tostring(close_error), path = path }
  end
  return content
end

local function default_list_dir(path, limit)
  if ok_native and native and native.available and type(native.listdir) == "function" then
    local called, entries, err, detail = pcall(native.listdir, path, limit)
    if not called then
      return nil, { kind = "io_error", message = tostring(entries), path = path }
    end
    if entries then
      table.sort(entries)
      return entries, nil, detail == true
    end
    return nil, {
      kind = classify_error(err, detail), message = tostring(err), path = path, errno = detail,
    }
  end
  return nil, {
    kind = "unavailable",
    message = "directory enumeration requires wtop native support",
    path = path,
  }
end

local function default_read_link(path)
  if ok_native and native and native.available and type(native.readlink) == "function" then
    local called, target, err, errno = pcall(native.readlink, path)
    if not called then
      return nil, { kind = "io_error", message = tostring(target), path = path }
    end
    if target then
      return target
    end
    local kind = classify_error(err, errno)
    if errno == 22 then kind = "not_link" end
    return nil, { kind = kind, message = tostring(err), path = path, errno = errno }
  end
  return nil, {
    kind = "unavailable",
    message = "symlink reading requires wtop native support",
    path = path,
  }
end

local function default_path_type(path)
  if ok_native and native and native.available and type(native.path_type) == "function" then
    local called, kind, err, errno = pcall(native.path_type, path)
    if not called then
      return nil, { kind = "io_error", message = tostring(kind), path = path }
    end
    if kind then return kind end
    return nil, {
      kind = classify_error(err, errno), message = tostring(err), path = path, errno = errno,
    }
  end
  return nil, {
    kind = "unavailable", message = "path type requires wtop native support", path = path,
  }
end

function FS.new(options)
  options = options or {}
  if type(options) ~= "table" then error("FS options must be a table", 2) end
  local default_limit = options.default_limit or (4 * 1024 * 1024)
  if type(default_limit) ~= "number" or default_limit ~= default_limit
      or default_limit < 1 or default_limit > 64 * 1024 * 1024
      or default_limit % 1 ~= 0 then
    error("default_limit must be an integer in 1..67108864", 2)
  end
  if options.root ~= nil and (type(options.root) ~= "string" or #options.root > 4096
      or options.root:find("\0", 1, true)
      or (options.root ~= "" and options.root:sub(1, 1) ~= "/")) then
    error("root must be an absolute NUL-free path", 2)
  end
  for _, key in ipairs({ "read_file", "list_dir", "read_link", "path_type" }) do
    if options[key] ~= nil and type(options[key]) ~= "function" then
      error(key .. " must be a function", 2)
    end
  end
  local root = options.root or ""
  if root ~= "" then
    for component in root:gmatch("[^/]+") do
      if component == "." or component == ".." then error("root contains dot components", 2) end
    end
    if root ~= "/" then root = root:gsub("/+$", "") end
  end
  return setmetatable({
    read_impl = options.read_file or default_read_file,
    list_impl = options.list_dir or default_list_dir,
    readlink_impl = options.read_link or default_read_link,
    path_type_impl = options.path_type or default_path_type,
    root = root,
    default_limit = default_limit,
  }, FS)
end

function FS:path(path)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
    error("path must be a non-empty NUL-free string", 2)
  end
  if #path > 4096 then error("path exceeds 4096 bytes", 2) end
  for component in path:gmatch("[^/]+") do
    if component == "." or component == ".." then
      error("path must not contain dot components", 2)
    end
  end
  if self.root == "" then
    return path
  end
  if path:sub(1, 1) == "/" then
    if self.root == "/" then return path end
    return self.root .. path
  end
  return self.root .. "/" .. path
end

function FS:read(path, limit)
  limit = limit or self.default_limit
  if type(limit) ~= "number" or limit ~= limit or limit < 1
      or limit > 64 * 1024 * 1024 or limit % 1 ~= 0 then
    return nil, { kind = "invalid", message = "invalid_read_limit", path = self:path(path) }
  end
  return self.read_impl(self:path(path), limit)
end

function FS:read_number(path)
  local content, err = self:read(path, 256)
  if not content then
    return nil, err
  end
  local token = content:match("^%s*([+-]?%d+%.?%d*)%s*$")
  local number = token and tonumber(token) or nil
  if number == nil or number ~= number or number == math.huge or number == -math.huge then
    return nil, { kind = "parse_error", message = "expected_number", path = self:path(path) }
  end
  return number
end

-- Success returns entries, nil, truncated.  A positive limit bounds the
-- directory entries retained by the native enumerator before Lua sorting.
function FS:list(path, limit)
  if limit ~= nil and (type(limit) ~= "number" or limit ~= limit or limit < 1
      or limit > 2147483647 or limit % 1 ~= 0) then
    return nil, { kind = "invalid", message = "invalid_list_limit", path = self:path(path) }
  end
  return self.list_impl(self:path(path), limit)
end

function FS:readlink(path)
  return self.readlink_impl(self:path(path))
end

function FS:kind(path)
  return self.path_type_impl(self:path(path))
end

function FS:exists(path)
  if ok_native and native and native.available and type(native.access) == "function" then
    local called, exists = pcall(native.access, self:path(path), "f")
    if called then return exists == true end
  end
  local content, err = self:read(path, 1)
  if content ~= nil then
    return true
  end
  if err and (err.kind == "denied" or err.kind == "too_large") then
    return true, err
  end
  return false, err
end

function FS.error_status(err)
  if type(err) ~= "table" then
    return "error"
  end
  if err.kind == "denied" then
    return "denied"
  end
  if err.kind == "missing" or err.kind == "unavailable" then
    return "unavailable"
  end
  return "error"
end

FS.classify_error = classify_error
FS.default = FS.new()

return FS
