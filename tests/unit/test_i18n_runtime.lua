local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local I18n = require("wtop.i18n")
local registry = require("wtop.generated.locales.registry")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

local function truthy(value, label)
  if not value then
    error((label or "value") .. ": expected a truthy value", 2)
  end
end

local expected_locales = {
  "de-DE",
  "en-US",
  "es-ES",
  "fr-FR",
  "ja-JP",
  "ko-KR",
  "pt-BR",
  "ru-RU",
  "zh-CN",
  "zh-TW",
}
for _, locale in ipairs(expected_locales) do
  truthy(registry.catalogs[locale], "compiled catalog " .. locale)
  equal(registry.catalogs[locale]._meta.locale, locale, "catalog identity")
  truthy(registry.catalogs[locale]._build.source_sha256:match("^[0-9a-f]+$"), "catalog digest")
  equal(#registry.catalogs[locale]._build.source_sha256, 64, "catalog digest length")
end
equal(registry.statuses["en-US"], "stable", "English status")
equal(registry.statuses["zh-CN"], "stable", "Chinese status")
equal(registry.statuses["ja-JP"], "preview", "preview status")

local english = assert(I18n.new({ locale = "en-US" }))
equal(english:t("tabs.overview"), "Overview", "English translation")
equal(english:t("process.count", { count = 1 }), "1 process", "English singular")
equal(english:t("process.count", { count = 5 }), "5 processes", "English plural")
equal(english:t("unknown.message"), "unknown.message", "unknown ID safety")

local chinese = assert(I18n.new({ locale = "zh_CN.UTF-8" }))
equal(chinese:locale(), "zh-CN", "normalized active locale")
equal(chinese:t("tabs.overview"), "概览", "Chinese translation")
equal(chinese:t("status.paused_at", { time = "10:20" }), "已暂停于 10:20", "Chinese interpolation")
equal(chinese:t("process.count", { count = 8 }), "8 个进程", "Chinese plural")

local traditional = assert(I18n.new({ locale = "zh-TW" }))
equal(traditional:t("tabs.overview"), "總覽", "preview translation")
equal(traditional:t("actions.cancel"), "取消", "complete preview translation")
local diagnostics = traditional:diagnostics()
equal(table.concat(diagnostics.fallback_chain, ","), "zh-TW,zh-CN,en-US", "fallback chain")
equal(diagnostics.status, "preview", "diagnostic status")
equal(diagnostics.missing_messages, 0, "complete preview catalog")

local regional_fallback = assert(I18n.new({ locale = "fr-CA" }))
equal(regional_fallback:locale(), "fr-FR", "language alias fallback")
equal(regional_fallback:t("tabs.overview"), "Vue d’ensemble", "language alias translation")

local unavailable = assert(I18n.new({ locale = "xx-YY" }))
equal(unavailable:locale(), "en-US", "unknown locale default")
equal(unavailable:t("tabs.overview"), "Overview", "unknown locale translation")

local environment = assert(I18n.new({
  cli_locale = "de-DE",
  config_locale = "fr-FR",
  getenv = function(name)
    return ({ LC_ALL = "zh-CN", LC_MESSAGES = "ja-JP", LANG = "ko-KR" })[name]
  end,
}))
equal(environment:locale(), "de-DE", "locale selection priority")

local custom_yaml = [[
_meta:
  locale: "en-GB"
  name: "English (United Kingdom)"
  direction: "ltr"
  fallback:
    - "en-US"
  plural_rule: "en"
  catalog_version: 1
messages:
  tabs.overview: "Summary"
]]
local custom = assert(I18n.new({ locale = "en-US" }))
local loaded, load_err = custom:load_yaml(custom_yaml, { source = "custom.yml" })
assert(loaded, load_err)
assert(custom:set_locale("en-GB"))
equal(custom:t("tabs.overview"), "Summary", "custom catalog")
equal(custom:t("actions.help"), "Help", "custom per-key fallback")

local invalid_custom = custom_yaml:gsub("tabs.overview: \"Summary\"", "tabs.unknown: \"Unknown\"")
local invalid_loaded, invalid_err = custom:load_yaml(invalid_custom, { source = "bad-custom.yml" })
equal(invalid_loaded, nil, "unknown custom message rejected")
truthy(invalid_err:find("does not exist in en-US", 1, true), "custom validation reason")

return true
