local ok_native, native = pcall(require, "wtop.native")

local FS = {}
FS.__index = FS

local ERRNO_KIND = {
  [1] = "denied",       -- EPERM
  [2] = "missing",      -- ENOENT
  [13] = "denied",      -- EACCES
  [20] = "missing",     -- ENOTDIR
  -- ENODATA is the attribute existing and holding no value, which is the
  -- kernel declining to state a figure rather than a read going wrong.  The
  -- development host produces two of them on every Intel RAPL zone: a
  -- `peak_power` constraint has no time window to publish, and a core or
  -- uncore sub-zone has no maximum power.  Both are answered with this word
  -- because it is the one the readers of an optional attribute already treat as
  -- "not published" rather than as a fault, and calling them read errors left
  -- half of every powercap zone's issue list describing a file the driver
  -- opened successfully and had nothing to say about.
  [61] = "unavailable",  -- ENODATA
}

-- Synthetic sysfs fixtures use Linux errno, independent of the test host.
-- Actual accessors below select the native API or the C stdio error domain.
local function classify_error(message, errno, kinds)
  if type(errno) == "number" then
    return (kinds or ERRNO_KIND)[errno] or "io_error"
  end
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

local function platform_errors()
  if ok_native and native and type(native.file_errors) == "table" then
    local errors = native.file_errors
    if type(errors.general) == "table" and type(errors.readfile) == "table"
        and type(errors.readlink) == "table" and type(errors.stdio) == "table" then
      return errors
    end
  end
  -- Older modules do not export constants. Their existing uname API selects
  -- legacy values without launching a helper or inspecting translated text.
  local system
  if ok_native and native and native.available and type(native.uname) == "function" then
    local called, value = pcall(native.uname)
    if called and type(value) == "table" then system = value.sysname end
  end
  local common = { [1] = "denied", [2] = "missing", [13] = "denied", [20] = "missing" }
  if system == "Windows" then
    return { general = { [2] = "missing", [3] = "missing", [5] = "denied",
        [267] = "missing" },
      readfile = { [87] = "not_regular", [223] = "too_large" },
      readlink = {}, stdio = common }
  end
  local errors = { general = common, stdio = common,
    readfile = { [22] = "not_regular", [27] = "too_large" },
    readlink = { [22] = "not_link" } }
  if system == "Linux" then
    errors.general, errors.stdio = ERRNO_KIND, ERRNO_KIND
    errors.readfile[40] = "symlink"
  elseif system == "Darwin" then
    common[96] = "unavailable"
    errors.readfile[62] = "symlink"
  else
    -- An unknown native API does not acquire Linux numeric meanings. The
    -- common CRT values still handle io.open without native support.
    errors.general, errors.readfile, errors.readlink = {}, {}, {}
  end
  return errors
end

local FILE_ERRORS = platform_errors()

local function classify_native_error(message, errno, operation)
  local kinds = operation and FILE_ERRORS[operation]
  local kind = kinds and kinds[errno]
  if kind then
    -- EINVAL/ERROR_INVALID_PARAMETER can also come from open/read/pread.
    -- Only the native backend's explicit type-check operation proves this
    -- category; its fixed identifier precedes the localized error text.
    if kind ~= "not_regular" or (type(message) == "string"
        and (message:match("^readfile_not_regular:")
          or message:match("^readfile_not_regular failed %(Win32 error %d+%)$"))) then
      return kind
    end
  end
  return classify_error(message, errno, FILE_ERRORS.general)
end

local function default_read_file(path, limit)
  if ok_native and native and native.available and type(native.readfile) == "function" then
    local called, content, err, errno = pcall(
      native.readfile, path, limit or (4 * 1024 * 1024))
    if not called then
      return nil, { kind = "io_error", message = tostring(content), path = path }
    end
    if content ~= nil then return content end
    local kind = classify_native_error(err, errno, "readfile")
    return nil, { kind = kind, message = tostring(err), path = path, errno = errno }
  end
  local file, open_error, open_errno = io.open(path, "rb")
  if not file then
    return nil, { kind = classify_error(open_error, open_errno, FILE_ERRORS.stdio),
      message = tostring(open_error), path = path, errno = open_errno }
  end
  local content, read_error, read_errno
  if limit then
    content, read_error, read_errno = file:read(limit + 1)
  else
    content, read_error, read_errno = file:read("*a")
  end
  local close_ok, close_error, close_errno = file:close()
  if content == nil then
    -- Lua returns nil (without an error string) when a fixed-size read starts
    -- at EOF.  That is a valid empty regular file, not an I/O failure.
    if read_error ~= nil then
      return nil, { kind = classify_error(read_error, read_errno, FILE_ERRORS.stdio),
        message = tostring(read_error), path = path, errno = read_errno }
    end
    content = ""
  end
  if limit and #content > limit then
    return nil, { kind = "too_large", message = "file_exceeds_limit", path = path, limit = limit }
  end
  if close_ok == nil then
    return nil, { kind = classify_error(close_error, close_errno, FILE_ERRORS.stdio),
      message = tostring(close_error), path = path, errno = close_errno }
  end
  return content
end

local function default_read_file_at(path, offset, length)
  if ok_native and native and native.available and type(native.readfile_at) == "function" then
    local called, content, err, errno = pcall(native.readfile_at, path, offset, length)
    if not called then
      return nil, { kind = "io_error", message = tostring(content), path = path }
    end
    if content ~= nil then return content end
    return nil, { kind = classify_native_error(err, errno, "readfile"), message = tostring(err),
      path = path, errno = errno }
  end
  local file, open_error, open_errno = io.open(path, "rb")
  if not file then
    return nil, { kind = classify_error(open_error, open_errno, FILE_ERRORS.stdio),
      message = tostring(open_error), path = path, errno = open_errno }
  end
  local position, seek_error, seek_errno = file:seek("set", offset)
  if not position then file:close(); return nil,
    { kind = classify_error(seek_error, seek_errno, FILE_ERRORS.stdio),
      message = tostring(seek_error), path = path, errno = seek_errno } end
  local content, read_error, read_errno = file:read(length)
  local close_ok, close_error, close_errno = file:close()
  if not content and read_error then
    return nil, { kind = classify_error(read_error, read_errno, FILE_ERRORS.stdio),
      message = tostring(read_error), path = path, errno = read_errno }
  end
  if close_ok == nil then
    return nil, { kind = classify_error(close_error, close_errno, FILE_ERRORS.stdio),
      message = tostring(close_error), path = path, errno = close_errno }
  end
  return content or ""
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
      kind = classify_native_error(err, detail), message = tostring(err), path = path, errno = detail,
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
    local kind = classify_native_error(err, errno, "readlink")
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
      kind = classify_native_error(err, errno), message = tostring(err), path = path, errno = errno,
    }
  end
  return nil, {
    kind = "unavailable", message = "path type requires wtop native support", path = path,
  }
end

function FS.new(options)
  if options == nil then options = {} end
  if type(options) ~= "table" then error("FS options must be a table", 2) end
  local default_limit = options.default_limit
  if default_limit == nil then default_limit = 4 * 1024 * 1024 end
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
  -- An option this constructor does not know is refused rather than ignored.
  -- Measured: two test files spelled the readlink implementation `readlink`,
  -- which is not one of the four names below, so the key was accepted, stored
  -- in the options table, and never read -- and the filesystem quietly fell back
  -- to the real one for that accessor.  A test that believes it is hermetic and
  -- is not is worse than one that knows it is not, because the host it runs on
  -- decides the answer, and the two doubles that made the mistake were testing
  -- collectors that never ask for a symlink, so the substitution stayed invisible
  -- in one case and produced a real `readlink(2)` on this host in the other.
  -- The accessor names are also the only ones `FS.new` will ever substitute a real
  -- implementation for, so an unknown key can only ever be a misspelling or dead
  -- weight.
  local FS_OPTION_KEYS = { "root", "default_limit", "read_file", "read_file_at", "list_dir", "read_link", "path_type", "usb_interface" }
  for key in pairs(options) do
    local known = false
    for _, accepted in ipairs(FS_OPTION_KEYS) do
      if key == accepted then known = true break end
    end
    if not known then
      error("unknown FS option `" .. tostring(key) .. "`; accepted options are "
        .. table.concat(FS_OPTION_KEYS, ", "), 2)
    end
  end
  for _, key in ipairs({ "read_file", "read_file_at", "list_dir", "read_link", "path_type", "usb_interface" }) do
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
    read_at_impl = options.read_file_at or default_read_file_at,
    list_impl = options.list_dir or default_list_dir,
    readlink_impl = options.read_link or default_read_link,
    path_type_impl = options.path_type or default_path_type,
    usb_interface_impl = options.usb_interface,
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
  if limit == nil then limit = self.default_limit end
  if type(limit) ~= "number" or limit ~= limit or limit < 1
      or limit > 64 * 1024 * 1024 or limit % 1 ~= 0 then
    return nil, { kind = "invalid", message = "invalid_read_limit", path = self:path(path) }
  end
  return self.read_impl(self:path(path), limit)
end

function FS:read_at(path, offset, length)
  if type(offset) ~= "number" or offset % 1 ~= 0 or offset < 0 or offset > 64 * 1024 * 1024
      or type(length) ~= "number" or length % 1 ~= 0 or length < 1 or length > 4096 then
    return nil, { kind = "invalid", message = "invalid_read_range", path = self:path(path) }
  end
  return self.read_at_impl(self:path(path), offset, length)
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

-- The fresh names table can be compacted by its caller. Unlike list(), names
-- retain native enumeration order so hints[i] belongs
-- to names[i]. Only a known regular file is marked; everything else needs the
-- caller's normal no-follow checks. Custom filesystems keep their own methods.
function FS:list_hints(path, limit)
  if self.list ~= FS.list or self.kind ~= FS.kind or self.readlink ~= FS.readlink
      or self.kind_nofollow ~= FS.kind_nofollow
      or self.read_impl ~= default_read_file
      or self.list_impl ~= default_list_dir or self.path_type_impl ~= default_path_type
      or self.readlink_impl ~= default_read_link
      or not (ok_native and native and native.available
        and type(native.listdir_hints) == "function") then
    return self:list(path, limit)
  end
  local actual = self:path(path)
  if limit ~= nil and (type(limit) ~= "number" or limit ~= limit or limit < 1
      or limit > 2147483647 or limit % 1 ~= 0) then
    return nil, { kind = "invalid", message = "invalid_list_limit", path = actual }
  end
  local called, entries, message, detail, hints = pcall(native.listdir_hints, actual, limit)
  if not called then
    return nil, { kind = "io_error", message = tostring(entries), path = actual }
  end
  if entries then return entries, nil, detail == true, hints end
  return nil, { kind = classify_native_error(message, detail), message = tostring(message),
    path = actual, errno = detail }
end

function FS:readlink(path)
  return self.readlink_impl(self:path(path))
end

-- A synthetic filesystem does not silently acquire access to the real host.
function FS:usb_interface(path, limit)
  local actual = self:path(path)
  if type(limit) ~= "number" or limit % 1 ~= 0 or limit < 0 or limit > 30 then
    return nil, { kind = "invalid", path = actual }
  end
  if self.usb_interface_impl then return self.usb_interface_impl(actual, limit) end
  if self.read_impl ~= default_read_file or self.list_impl ~= default_list_dir
      or self.readlink_impl ~= default_read_link or self.path_type_impl ~= default_path_type
      or not (ok_native and native and native.available
        and type(native.read_usb_interface) == "function") then
    return nil, { kind = "unavailable", path = actual }
  end
  local called, value, message, errno, category = pcall(native.read_usb_interface, actual, limit)
  if not called then return nil, { kind = "io_error", path = actual } end
  if type(value) == "table" then return value end
  return nil, { kind = category == "changed" and "changed" or classify_native_error(message, errno),
    path = actual, errno = errno }
end

function FS:kind(path)
  return self.path_type_impl(self:path(path))
end

-- Native entry metadata does not follow the final symlink. A supplied
-- path_type or read_link callback does not inherit that guarantee.
function FS:kind_nofollow(path)
  if self.path_type_impl ~= default_path_type
      or self.readlink_impl ~= default_read_link
      or not (ok_native and native and native.available and type(native.path_type) == "function") then
    return nil, nil, false
  end
  local kind, err = default_path_type(self:path(path))
  return kind, err, true
end

function FS:exists(path)
  if self.path_type_impl ~= default_path_type then
    local kind, err = self:kind(path)
    if kind ~= nil then return true end
    if err and err.kind == "denied" then return true, err end
    if self.read_impl == default_read_file then return false, err end
  end
  if self.path_type_impl == default_path_type and self.read_impl == default_read_file
      and ok_native and native and native.available and type(native.access) == "function" then
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
