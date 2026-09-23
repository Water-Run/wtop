local Catalog = require("wtop.i18n.catalog")
local FS = require("wtop.linux.fs")
local ConfigPath = require("wtop.config_path")

local UserCatalogs = {}

local DEFAULT_MAX_FILES = 64
local DEFAULT_MAX_BYTES = 1024 * 1024
local MAX_NAME_BYTES = 255
local MAX_PATH_BYTES = 4096
local DIRECTORY_ENTRY_SLACK = 256
local MAX_FILES = 4096
local MAX_BYTES = 16 * 1024 * 1024

function UserCatalogs.path(getenv)
  local path = ConfigPath.file("locales", getenv)
  if path then return path end
  return nil, "config_home_unavailable"
end

local function make_report(path)
  return {
    loaded = {},
    errors = {},
    truncated = false,
    path = path,
    state = nil,
  }
end

local function reason_text(value, fallback)
  if type(value) == "table" then
    return tostring(value.message or value.reason or fallback or value.kind or "filesystem_error")
  end
  return tostring(value or fallback or "filesystem_error")
end

local function classify_fs_error(value, errno)
  local kind = type(value) == "table" and value.kind or nil
  if type(value) == "table" then errno = errno or value.errno end
  local reason = reason_text(value)
  local lower = reason:lower()
  if kind == "too_large" then return "oversize", reason, errno end
  if kind == "missing" or errno == 2 or errno == 20
      or lower:find("no such file", 1, true)
      or lower:find("not found", 1, true) then
    return "absent", reason, errno
  end
  if kind == "denied" or errno == 1 or errno == 13
      or lower:find("permission denied", 1, true)
      or lower:find("operation not permitted", 1, true) then
    return "denied", reason, errno
  end
  return "error", reason, errno
end

local function add_error(report, fields)
  report.errors[#report.errors + 1] = fields
end

local function error_order(left, right)
  local left_name = tostring(left.name or "")
  local right_name = tostring(right.name or "")
  if left_name ~= right_name then return left_name < right_name end
  local left_kind = tostring(left.kind or "")
  local right_kind = tostring(right.kind or "")
  if left_kind ~= right_kind then return left_kind < right_kind end
  return tostring(left.reason or "") < tostring(right.reason or "")
end

local function finish(report)
  table.sort(report.errors, error_order)
  if not report.state then
    report.state = (report.truncated or #report.errors > 0) and "partial" or "ok"
  end
  return report
end

local function fatal_report(report, state, kind, reason, errno)
  report.state = state
  add_error(report, {
    kind = kind,
    reason = reason,
    errno = errno,
  })
  return finish(report)
end

local function valid_limit(value, default, allow_zero)
  if value == nil then return default end
  if type(value) ~= "number" or value % 1 ~= 0 then return nil end
  if allow_zero then
    if value < 0 then return nil end
  elseif value < 1 then
    return nil
  end
  local maximum = allow_zero and MAX_FILES or MAX_BYTES
  if value > maximum then return nil end
  return value
end

local function filename_disposition(name)
  if type(name) ~= "string" then return "reject", "name_not_string" end
  if name:find("%z") then return "reject", "nul_in_name" end
  if name:find("/", 1, true) then return "reject", "path_separator_in_name" end
  if #name > MAX_NAME_BYTES then return "reject", "name_too_long" end
  if name:sub(-4) ~= ".yml" then return "ignore" end
  if name:sub(1, 1) == "." then return "reject", "hidden_name" end
  if name:find("[%z\1-\31\127]") then return "reject", "control_character_in_name" end
  if #name == 4 then return "reject", "empty_basename" end
  return "load"
end

local function join_file(directory, name)
  if directory:sub(-1) == "/" then return directory .. name end
  return directory .. "/" .. name
end

local function call_list(fs, directory, limit)
  if type(fs) ~= "table" or type(fs.list) ~= "function" then
    return nil, "filesystem_list_function_required"
  end
  local ok, entries, err, detail = pcall(fs.list, fs, directory, limit)
  if not ok then return nil, entries end
  return entries, err, detail
end

local function call_read(fs, path, max_bytes)
  if type(fs) ~= "table" or type(fs.read) ~= "function" then
    return nil, "filesystem_read_function_required"
  end
  local ok, text, err, errno = pcall(fs.read, fs, path, max_bytes)
  if not ok then return nil, text end
  return text, err, errno
end

local function preflight(text, path, max_bytes)
  local catalog, errors = Catalog.from_yaml(text, {
    source = path,
    max_bytes = max_bytes,
  })
  if not catalog then return nil, Catalog.format_errors(errors) end
  return catalog._meta.locale
end

function UserCatalogs.load(translator, options)
  if options == nil then options = {} end
  if type(options) ~= "table" then
    return fatal_report(make_report(nil), "error", "options", "options_must_be_table")
  end
  local directory = options.path
  local path_error
  if directory == nil then
    directory, path_error = UserCatalogs.path(options.getenv)
  end
  local report = make_report(directory)
  if not directory then
    return fatal_report(report, "error", "path", path_error or "config_home_unavailable")
  end
  if type(directory) ~= "string" or directory == "" or not ConfigPath.safe_absolute(directory)
      or directory:find("[%z\1-\31\127]") or #directory > MAX_PATH_BYTES
      or directory:find("/%.%.?/") or directory:match("/%.%.?$") then
    return fatal_report(report, "error", "path", "invalid_catalog_directory")
  end
  if type(translator) ~= "table" or type(translator.load_yaml) ~= "function" then
    return fatal_report(report, "error", "translator", "translator_load_yaml_required")
  end

  local max_files = valid_limit(options.max_files, DEFAULT_MAX_FILES, true)
  local max_bytes = valid_limit(options.max_bytes, DEFAULT_MAX_BYTES, false)
  if not max_files then
    return fatal_report(report, "error", "limit", "invalid_max_files")
  end
  if not max_bytes then
    return fatal_report(report, "error", "limit", "invalid_max_bytes")
  end

  local fs = options.fs or FS.default
  local entries, list_error, list_detail = call_list(
    fs, directory, max_files + DIRECTORY_ENTRY_SLACK)
  if not entries then
    local classification, reason, errno = classify_fs_error(
      list_error, type(list_detail) == "number" and list_detail or nil)
    local state = classification == "absent" and "absent"
      or (classification == "denied" and "denied" or "error")
    return fatal_report(report, state, classification, reason, errno)
  end
  if type(entries) ~= "table" then
    return fatal_report(report, "error", "directory", "directory_entries_not_table")
  end
  if list_detail == true then report.truncated = true end

  local candidates = {}
  local scan_limit = max_files + DIRECTORY_ENTRY_SLACK
  for index, name in ipairs(entries) do
    if index > scan_limit then
      report.truncated = true
      break
    end
    local disposition, rejection = filename_disposition(name)
    if disposition == "load" then
      candidates[#candidates + 1] = name
    elseif disposition == "reject" then
      add_error(report, {
        kind = "unsafe_name",
        name = type(name) == "string" and name or nil,
        reason = rejection,
      })
    end
  end
  table.sort(candidates)
  if #candidates > max_files then report.truncated = true end

  local seen_locales = {}
  local process_count = math.min(#candidates, max_files)
  for index = 1, process_count do
    local name = candidates[index]
    local file_path = join_file(directory, name)
    local text, read_error, read_errno = call_read(fs, file_path, max_bytes)
    if not text then
      local classification, reason, errno = classify_fs_error(read_error, read_errno)
      add_error(report, {
        kind = classification == "absent" and "missing" or classification,
        name = name,
        path = file_path,
        reason = reason,
        errno = errno,
      })
    elseif type(text) ~= "string" then
      add_error(report, {
        kind = "read_error",
        name = name,
        path = file_path,
        reason = "file_content_not_string",
      })
    elseif #text > max_bytes then
      add_error(report, {
        kind = "oversize",
        name = name,
        path = file_path,
        reason = "catalog_exceeds_max_bytes",
        bytes = #text,
        limit = max_bytes,
      })
    else
      local locale, validation_error = preflight(text, file_path, max_bytes)
      if not locale then
        add_error(report, {
          kind = "invalid",
          name = name,
          path = file_path,
          reason = validation_error,
        })
      elseif seen_locales[locale] then
        add_error(report, {
          kind = "duplicate",
          name = name,
          path = file_path,
          locale = locale,
          first = seen_locales[locale].name,
          reason = "duplicate_locale",
        })
      else
        local called, loaded_locale, load_error = pcall(translator.load_yaml, translator, text, {
          source = file_path,
          max_bytes = max_bytes,
          require_complete = false,
        })
        if not called then
          add_error(report, {
            kind = "invalid",
            name = name,
            path = file_path,
            locale = locale,
            reason = tostring(loaded_locale),
          })
        elseif not loaded_locale then
          add_error(report, {
            kind = "invalid",
            name = name,
            path = file_path,
            locale = locale,
            reason = tostring(load_error or "catalog_rejected"),
          })
        elseif loaded_locale ~= locale then
          add_error(report, {
            kind = "invalid",
            name = name,
            path = file_path,
            locale = locale,
            reason = "translator_locale_mismatch",
          })
        else
          local loaded = {
            name = name,
            path = file_path,
            locale = locale,
            bytes = #text,
          }
          report.loaded[#report.loaded + 1] = loaded
          seen_locales[locale] = loaded
        end
      end
    end
  end

  return finish(report)
end

UserCatalogs.DEFAULT_MAX_FILES = DEFAULT_MAX_FILES
UserCatalogs.DEFAULT_MAX_BYTES = DEFAULT_MAX_BYTES
UserCatalogs.MAX_NAME_BYTES = MAX_NAME_BYTES
UserCatalogs.MAX_PATH_BYTES = MAX_PATH_BYTES
UserCatalogs.MAX_FILES = MAX_FILES
UserCatalogs.MAX_BYTES = MAX_BYTES
UserCatalogs.filename_disposition = filename_disposition

return UserCatalogs
