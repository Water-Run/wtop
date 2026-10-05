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

-- The one list of things a fixture can declare.  Both `new` and `merge` read it,
-- because a second copy of this list is a second thing to forget: `new` knew
-- about six kinds and `merge` knew about five, so every `errors` declaration
-- handed to `merge` was dropped on the floor.  Measured, and the consequence is
-- not a missing table entry -- it is a fixture that says the opposite of what
-- it was told.  A driver answering ENODATA reads as `unavailable`, with its
-- containing directory present; the same declaration, once merged, reads as
-- `missing` with no directory, which is what you get from declaring no error at
-- all.  A test modelling "the attribute exists and holds no value" would have
-- been asserting about an absent file, in a project whose entire quality-label
-- vocabulary turns on the difference between the two.  Nothing was wrong with
-- it for an increment only because no caller merged an `errors` fixture yet,
-- and the two callers that exist are in `test_hardware_absent_paths.lua`, whose
-- whole subject is absence -- so the next case added there is the one that
-- would have hit it.
M.KINDS = { "files", "dirs", "denied", "links", "truncated", "errors" }

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
--   errors    table  absolute path -> errno, or { errno = n, message = s }
--
-- `errors` models a read that fails for a reason other than a missing or
-- forbidden file -- ENODATA above all, which is how a driver answers for an
-- attribute that exists and holds no value.  It is classified through the real
-- `FS.classify_error` rather than carrying a hand-written `kind`, so a fixture
-- that declares an errno is exercising the mapping under test rather than
-- asserting its own conclusion back at the collector.
function M.new(specification)
  specification = specification or {}
  -- Normalise every declared kind in one pass, so a kind added to KINDS above
  -- cannot be wired into `new` and forgotten by `merge`, or the other way round.
  local given = {}
  for _, key in ipairs(M.KINDS) do given[key] = specification[key] or {} end
  local files, dirs = given.files, given.dirs
  local denied, links = given.denied, given.links
  local truncated, errors = given.truncated, given.errors

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
  for _, key in ipairs(M.KINDS) do
    for path in pairs(given[key]) do register(path) end
  end

  local directories = {}
  for path, bucket in pairs(derived) do
    table.sort(bucket.order)
    directories[path] = bucket.order
  end
  for path, entries in pairs(dirs) do
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
        if errors[path] then
          local declared = errors[path]
          local errno, message = declared, "io_error"
          if type(declared) == "table" then
            errno = declared.errno
            message = declared.message or message
          end
          return nil, {
            kind = FS.classify_error(message, errno),
            message = message, path = path, errno = errno,
          }
        end
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
    -- `path_type` has to answer the way the product answers, because a fixture
    -- that says something different is asserting about a filesystem that does
    -- not exist.  Two ways it did not, both measured against `native.path_type`
    -- (src/wtop/linux/fs.lua:121, native/wtop_native.c:1541):
    --
    --   * it asked `directories` first, so a path that is both a derived
    --     directory and a declared link came back "directory".  The product
    --     uses `lstat` unless told otherwise, and every `/sys/class` device
    --     directory is a symlink, so the product says "symlink".  This is not a
    --     cosmetic difference: `collectors/cgroup.lua` counts a symlink as a
    --     skipped entry to avoid walking a cycle, and the only test of that
    --     branch passes a private filesystem that answers "symlink" -- so the
    --     shared one would have made the branch unreachable for every test that
    --     used it, and nobody would have found out.
    --   * it answered "file" for a regular file, where the product answers
    --     "regular" (`S_ISREG`).
    --
    -- Links are therefore asked first: a fixture that declares a link and also
    -- declares files beneath it is describing a symlinked directory, which is
    -- what a class device directory is.
    path_type = function(path)
      if links[path] then return "symlink" end
      if directories[path] then return "directory" end
      if files[path] ~= nil then return "regular" end
      return nil, { kind = "missing", message = "no such path", path = path }
    end,
  })
end

--- Merge several fixture specifications into one.
--
-- Every kind `new` reads is copied, because a merge that quietly drops a
-- declaration produces a fixture that contradicts the one it was given rather
-- than one that is merely smaller.  `KINDS` is the list both functions walk, so
-- this cannot fall behind `new` -- which is the only reason it does not need a
-- test of its own to say so.  `tests/unit/test_fixture_fs.lua` does test it,
-- but by checking the property rather than the list: a merge may not change
-- what a fixture says, so a kind added to `KINDS` and not wired into either
-- function is caught there too.
function M.merge(...)
  local result = {}
  for _, key in ipairs(M.KINDS) do result[key] = {} end
  for index = 1, select("#", ...) do
    local part = select(index, ...) or {}
    for _, key in ipairs(M.KINDS) do
      for path, value in pairs(part[key] or {}) do result[key][path] = value end
    end
  end
  return result
end

return M
