local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then root = "." end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local I18n = require("wtop.i18n")
local UserCatalogs = require("wtop.i18n.user_catalogs")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

local function catalog(locale, name, overview, plural_rule)
  return table.concat({
    "_meta:",
    "  locale: \"" .. locale .. "\"",
    "  name: \"" .. name .. "\"",
    "  direction: \"ltr\"",
    "  fallback:",
    "    - \"en-US\"",
    "  plural_rule: \"" .. (plural_rule or "en") .. "\"",
    "  catalog_version: 1",
    "messages:",
    "  tabs.overview: \"" .. overview .. "\"",
    "",
  }, "\n")
end

local function environment(values)
  return function(name) return values[name] end
end

equal(UserCatalogs.path(environment({
  XDG_CONFIG_HOME = "/xdg/config",
  HOME = "/home/test",
})), "/xdg/config/wtop/locales", "XDG path")
equal(UserCatalogs.path(environment({
  XDG_CONFIG_HOME = "/xdg/config/",
  HOME = "/home/test",
})), "/xdg/config/wtop/locales", "XDG trailing slash")
equal(UserCatalogs.path(environment({
  XDG_CONFIG_HOME = "",
  HOME = "/home/test",
})), "/home/test/.config/wtop/locales", "HOME fallback")
equal(UserCatalogs.path(environment({
  XDG_CONFIG_HOME = "relative/config",
  HOME = "/home/test",
})), "/home/test/.config/wtop/locales", "relative XDG ignored")
equal(UserCatalogs.path(environment({
  XDG_CONFIG_HOME = "/" .. string.rep("x", UserCatalogs.MAX_PATH_BYTES - 1),
  HOME = "/home/test",
})), "/home/test/.config/wtop/locales", "overlong expanded XDG ignored")
local no_path, no_path_error = UserCatalogs.path(environment({}))
equal(no_path, nil, "missing config path")
equal(no_path_error, "config_home_unavailable", "missing config path reason")

local long_name = string.rep("a", 252) .. ".yml"
local nul_name = "nul\0.yml"
local files = {
  ["/catalogs/10-good.yml"] = catalog("en-GB", "English UK", "Summary", "en"),
  ["/catalogs/20-invalid.yml"] = "value: *forbidden\n",
  ["/catalogs/30-duplicate.yml"] = catalog("en-GB", "Duplicate", "Replacement", "en"),
  ["/catalogs/40-oversize.yml"] = string.rep("x", 513),
  ["/catalogs/50-other.yml"] = catalog("it-IT", "Italian", "Riepilogo", "it"),
}
local read_limits = {}
local fs = {}
function fs:list(path)
  equal(path, "/catalogs", "listed directory")
  return {
    "50-other.yml",
    "ignored.yaml",
    ".hidden.yml",
    "30-duplicate.yml",
    "../escape.yml",
    nul_name,
    long_name,
    "20-invalid.yml",
    "40-oversize.yml",
    "README",
    "10-good.yml",
  }
end
function fs:read(path, limit)
  read_limits[path] = limit
  local text = files[path]
  if text == nil then return nil, { kind = "missing", message = "fixture_missing" } end
  return text
end

local translator = assert(I18n.new({ locale = "en-US" }))
local load_calls = 0
local original_load_yaml = translator.load_yaml
translator.load_yaml = function(self, ...)
  load_calls = load_calls + 1
  return original_load_yaml(self, ...)
end
local report = UserCatalogs.load(translator, {
  path = "/catalogs",
  fs = fs,
  max_files = 16,
  max_bytes = 512,
})
equal(report.path, "/catalogs", "report path")
equal(report.state, "partial", "mixed directory state")
equal(report.truncated, false, "mixed directory not truncated")
equal(#report.loaded, 2, "loaded catalog count")
equal(report.loaded[1].name, "10-good.yml", "stable first load")
equal(report.loaded[1].locale, "en-GB", "first locale")
equal(report.loaded[2].name, "50-other.yml", "stable second load")
equal(report.loaded[2].locale, "it-IT", "second locale")
equal(load_calls, 2, "only accepted unique catalogs reach translator")
for path, limit in pairs(read_limits) do
  assert(path:sub(1, 10) == "/catalogs/")
  equal(limit, 512, "bounded read")
end

local error_counts = {}
local duplicate_error
for _, item in ipairs(report.errors) do
  error_counts[item.kind] = (error_counts[item.kind] or 0) + 1
  if item.kind == "duplicate" then duplicate_error = item end
end
equal(error_counts.invalid, 1, "invalid YAML isolated")
equal(error_counts.duplicate, 1, "duplicate locale reported")
equal(error_counts.oversize, 1, "oversize isolated")
equal(error_counts.unsafe_name, 4, "unsafe names rejected")
equal(duplicate_error.locale, "en-GB", "duplicate locale identity")
equal(duplicate_error.first, "10-good.yml", "duplicate retained first catalog")

assert(translator:set_locale("en-GB"))
equal(translator:t("tabs.overview"), "Summary", "duplicate did not overwrite first")
equal(translator:t("actions.help"), "Help", "partial catalog per-key fallback")
assert(translator:set_locale("it-IT"))
equal(translator:t("tabs.overview"), "Riepilogo", "second custom catalog active")
equal(translator:t("actions.help"), "Help", "second catalog fallback")

local truncated_files = {
  ["/truncated/a.yml"] = catalog("de-AT", "German Austria", "Uebersicht", "de"),
  ["/truncated/m.yml"] = catalog("es-MX", "Spanish Mexico", "Resumen", "es"),
  ["/truncated/z.yml"] = catalog("fr-CA", "French Canada", "Sommaire", "fr"),
}
local truncated_reads = {}
local truncated_fs = {}
function truncated_fs:list() return { "z.yml", "m.yml", "a.yml" } end
function truncated_fs:read(path)
  truncated_reads[path] = true
  return truncated_files[path]
end
local truncated_translator = assert(I18n.new({ locale = "en-US" }))
local truncated = UserCatalogs.load(truncated_translator, {
  path = "/truncated",
  fs = truncated_fs,
  max_files = 2,
  max_bytes = 1024,
})
equal(truncated.state, "partial", "truncated state")
equal(truncated.truncated, true, "truncated flag")
equal(#truncated.loaded, 2, "truncated loaded count")
equal(truncated.loaded[1].name, "a.yml", "truncated stable first")
equal(truncated.loaded[2].name, "m.yml", "truncated stable second")
equal(truncated_reads["/truncated/z.yml"], nil, "truncated file not read")

local function failed_fs(kind, message)
  return { list = function() return nil, { kind = kind, message = message } end }
end
local empty_translator = assert(I18n.new({ locale = "en-US" }))
local absent = UserCatalogs.load(empty_translator, {
  path = "/absent",
  fs = failed_fs("missing", "No such file or directory"),
})
equal(absent.state, "absent", "absent directory")
equal(absent.errors[1].kind, "absent", "absent classification")
local denied = UserCatalogs.load(empty_translator, {
  path = "/denied",
  fs = failed_fs("denied", "Permission denied"),
})
equal(denied.state, "denied", "denied directory")
equal(denied.errors[1].kind, "denied", "denied classification")
local failed = UserCatalogs.load(empty_translator, {
  path = "/failed",
  fs = failed_fs("io_error", "I/O error"),
})
equal(failed.state, "error", "directory error")
equal(failed.errors[1].kind, "error", "directory error classification")

local getenv_absent = UserCatalogs.load(empty_translator, {
  getenv = environment({ XDG_CONFIG_HOME = "/custom" }),
  fs = failed_fs("missing", "not found"),
})
equal(getenv_absent.path, "/custom/wtop/locales", "load-derived path")
equal(getenv_absent.state, "absent", "derived path absence")

local list_called = false
local invalid_path = UserCatalogs.load(empty_translator, {
  path = "bad\0path",
  fs = { list = function() list_called = true; return {} end },
})
equal(invalid_path.state, "error", "NUL path rejected")
equal(list_called, false, "invalid path not accessed")

local zero_limit = UserCatalogs.load(empty_translator, {
  path = "/zero",
  fs = {
    list = function() return { "one.yml" } end,
    read = function() error("max_files zero must not read") end,
  },
  max_files = 0,
})
equal(zero_limit.state, "partial", "zero file limit state")
equal(zero_limit.truncated, true, "zero file limit truncation")
equal(#zero_limit.loaded, 0, "zero file limit loaded")

return true
