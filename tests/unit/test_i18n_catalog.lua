local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local Catalog = require("wtop.i18n.catalog")
local Format = require("wtop.i18n.format")
local Locale = require("wtop.i18n.locale")
local Plural = require("wtop.i18n.plural")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

local function contains(value, fragment, label)
  if type(value) ~= "string" or not value:find(fragment, 1, true) then
    error(string.format("%s: expected %q to contain %q", label or "value", tostring(value), fragment), 2)
  end
end

equal(Locale.normalize("zh_CN.UTF-8"), "zh-CN", "POSIX locale normalization")
equal(Locale.normalize("pt_br@custom"), "pt-BR", "modifier stripping")
equal(Locale.normalize("sr_latn_rs"), "sr-Latn-RS", "script normalization")
equal(Locale.normalize("C.UTF-8"), "en-US", "C locale")
equal(Locale.normalize("iw_IL"), "he-IL", "legacy language")
equal(Locale.normalize("en--US"), nil, "empty locale subtag")
equal(table.concat(assert(Locale.parents("en-US-u-ca-gregory")), ","),
  "en-US-u-ca-gregory,en-US-u-ca,en-US,en", "extension-aware locale parents")
equal(Locale.from_environment({
  getenv = function(name)
    return name == "LANG" and "ja_JP.UTF-8" or nil
  end,
}), "ja-JP", "environment without CLI/config")

equal(Plural.select("en", 1), "one", "English singular")
equal(Plural.select("en", "1.0"), "other", "English visible decimal")
equal(Plural.select("es", "1.0"), "one", "Spanish decimal one")
equal(Plural.select("es", 1000000), "many", "Spanish many")
equal(Plural.select("ru", 1), "one", "Russian one")
equal(Plural.select("ru", 3), "few", "Russian few")
equal(Plural.select("ru", 12), "many", "Russian many")
equal(Plural.select("ru", "1.2"), "other", "Russian decimal")
equal(Plural.select("ar", 0), "zero", "Arabic zero")
equal(Plural.select("ar", 2), "two", "Arabic two")
equal(Plural.select("en", string.rep("9", 129)), nil, "bounded plural decimal")

local valid_yaml = [[
_meta:
  locale: "en-US"
  name: "English"
  direction: "ltr"
  fallback: []
  plural_rule: "en"
  catalog_version: 1
messages:
  app.name: "wtop"
  process.count:
    one: "{count} process"
    other: "{count} processes"
]]
local reference, errors = Catalog.from_yaml(valid_yaml, { source = "valid.yml" })
assert(reference, Catalog.format_errors(errors))

local invalid_placeholder = valid_yaml:gsub("{count} processes", "{total} processes")
local invalid, invalid_errors = Catalog.from_yaml(invalid_placeholder, { source = "placeholder.yml" })
equal(invalid, nil, "plural placeholder mismatch")
contains(Catalog.format_errors(invalid_errors), "placeholders", "placeholder reason")

local missing_plural = valid_yaml:gsub('    other: "{count} processes"\n', "")
local missing, missing_errors = Catalog.from_yaml(missing_plural, { source = "plural.yml" })
equal(missing, nil, "missing plural category")
contains(Catalog.format_errors(missing_errors), 'missing required "other"', "plural category reason")

local unknown_meta = valid_yaml:gsub("  catalog_version: 1", "  catalog_version: 1\n  executable: true")
local unknown, unknown_errors = Catalog.from_yaml(unknown_meta, { source = "unknown.yml" })
equal(unknown, nil, "unknown meta rejected")
contains(Catalog.format_errors(unknown_errors), "unknown _meta field executable", "unknown meta reason")

local translated_yaml = [[
_meta:
  locale: "de-DE"
  name: "Deutsch"
  direction: "ltr"
  fallback:
    - "en-US"
  plural_rule: "de"
  catalog_version: 1
messages:
  app.name: "wtop"
]]
local translated = assert(Catalog.from_yaml(translated_yaml, { source = "de.yml" }))
local compatible = Catalog.validate_against(translated, reference, { source = "de.yml" })
equal(compatible, true, "partial preview compatibility")
local complete, complete_errors = Catalog.validate_against(translated, reference, {
  source = "de.yml",
  require_complete = true,
})
equal(complete, nil, "stable coverage")
contains(Catalog.format_errors(complete_errors), "stable catalog is missing", "stable coverage reason")

equal(Format.interpolate("{{{name}}}", { name = "wtop" }), "{wtop}", "escaped braces")
equal(Format.interpolate("{name}", {}), nil, "missing interpolation value")
equal(Format.number(12345.5, { locale = "en-US", precision = 1 }), "12,345.5", "English number")
equal(Format.number(12345.5, { locale = "de-DE", precision = 1 }), "12.345,5", "German number")
equal(Format.percent(0.125, { locale = "en-US", ratio = true, precision = 1 }), "12.5%", "percentage")
equal(Format.bytes(1536, { locale = "en-US", precision = 1 }), "1.5 KiB", "IEC bytes")
equal(Format.frequency(4800000000, { locale = "en-US", precision = 1 }), "4.8 GHz", "frequency")
equal(Format.temperature(25, { locale = "en-US", unit = "F", precision = 0 }), "77 °F", "temperature")
equal(Format.number(1, {min_precision = "invalid"}), nil, "invalid minimum precision")
equal(Format.bytes(1, {system = "invalid"}), nil, "invalid byte system")
equal(Format.interpolate("{value}", {value = "\27[2J"}), nil,
  "terminal controls rejected from interpolation")

return true
