local Catalog = require("wtop.i18n.catalog")
local Format = require("wtop.i18n.format")
local Locale = require("wtop.i18n.locale")
local Plural = require("wtop.i18n.plural")
local Yaml = require("wtop.i18n.yaml_profile")

local M = {}
local Translator = {}
Translator.__index = Translator

local MAX_CATALOGS = 256
local MAX_ALIASES = 512
local MAX_MISSING_IDS = 4096

local function default_registry()
  return require("wtop.generated.locales.registry")
end

local function shallow_copy(value)
  if value == nil then return {} end
  if type(value) ~= "table" then return nil, "value must be a table" end
  local result = {}
  for key, item in pairs(value) do
    result[key] = item
  end
  return result
end


local function validate_registry(registry)
  if type(registry) ~= "table" or type(registry.catalogs) ~= "table" then
    return nil, "locale registry must contain a catalogs table"
  end
  local default_locale, default_err = Locale.normalize(registry.default or "en-US")
  if not default_locale then return nil, "invalid default locale: " .. default_err end
  local catalogs, count = {}, 0
  for key, raw in pairs(registry.catalogs) do
    count = count + 1
    if count > MAX_CATALOGS then return nil, "locale registry has too many catalogs" end
    local key_locale, key_err = Locale.normalize(key)
    if not key_locale or key_locale ~= key then
      return nil, "invalid registry locale key: " .. tostring(key_err or key)
    end
    if type(raw) ~= "table" then return nil, "registry catalog must be a table: " .. key end
    local validated, errors = Catalog.validate({ _meta = raw._meta, messages = raw.messages }, {
      source = "<compiled catalog " .. key .. ">",
    })
    if not validated then return nil, Catalog.format_errors(errors) end
    if validated._meta.locale ~= key then return nil, "registry catalog locale mismatch: " .. key end
    catalogs[key] = validated
  end
  if not catalogs[default_locale] then return nil, "default locale is missing from registry" end

  local aliases, alias_count = {}, 0
  if registry.aliases ~= nil and type(registry.aliases) ~= "table" then
    return nil, "locale registry aliases must be a table"
  end
  for alias, target in pairs(registry.aliases or {}) do
    alias_count = alias_count + 1
    if alias_count > MAX_ALIASES then return nil, "locale registry has too many aliases" end
    local normalized_alias = Locale.normalize(alias)
    local normalized_target = Locale.normalize(target)
    if not normalized_alias or normalized_alias ~= alias or not normalized_target
        or normalized_target ~= target or not catalogs[target] then
      return nil, "invalid locale alias: " .. tostring(alias)
    end
    aliases[alias] = target
  end
  local statuses = {}
  if registry.statuses ~= nil and type(registry.statuses) ~= "table" then
    return nil, "locale registry statuses must be a table"
  end
  for locale, status in pairs(registry.statuses or {}) do
    if catalogs[locale] and type(status) == "string" and #status <= 32
        and status:match("^[a-z][a-z0-9_-]*$") then
      statuses[locale] = status
    end
  end

  local reference = catalogs[default_locale]
  for locale, catalog in pairs(catalogs) do
    local compatible, errors = Catalog.validate_against(catalog, reference, {
      source = "<compiled catalog " .. locale .. ">",
      require_complete = statuses[locale] == "stable",
    })
    if not compatible then return nil, Catalog.format_errors(errors) end
  end
  return {
    catalogs = catalogs,
    aliases = aliases,
    statuses = statuses,
    default = default_locale,
  }
end

local function append_unique(output, seen, value)
  if value and not seen[value] then
    seen[value] = true
    output[#output + 1] = value
    return true
  end
  return false
end

local function catalog_locale(catalog)
  return catalog and catalog._meta and catalog._meta.locale
end

function Translator:_resolve_requested(requested)
  local parents = Locale.parents(requested) or { requested }
  for _, candidate in ipairs(parents) do
    if self.catalogs[candidate] then
      return candidate
    end
    local alias = self.aliases[candidate]
    if alias and self.catalogs[alias] then
      return alias
    end
  end
  return self.default_locale
end

function Translator:_rebuild_chain(requested)
  local chain, seen = {}, {}
  local active = self:_resolve_requested(requested)

  local function add_with_fallback(locale)
    if not locale or seen[locale] then
      return
    end
    local catalog = self.catalogs[locale]
    if not catalog then
      local alias = self.aliases[locale]
      catalog = alias and self.catalogs[alias] or nil
      locale = catalog and alias or locale
    end
    if not catalog or not append_unique(chain, seen, locale) then
      return
    end
    for _, fallback in ipairs(catalog._meta.fallback or {}) do
      add_with_fallback(fallback)
    end
  end

  add_with_fallback(active)
  add_with_fallback(self.default_locale)
  self.requested_locale = requested
  self.active_locale = chain[1] or self.default_locale
  self.chain = chain
  local formatter, err = Format.new(self.active_locale, self.format_options)
  if not formatter then return nil, err end
  self.format = formatter
  return true
end

function Translator:set_locale(value)
  local normalized, err = Locale.normalize(value)
  if not normalized then
    return nil, err
  end
  local rebuilt, rebuild_err = self:_rebuild_chain(normalized)
  if not rebuilt then return nil, rebuild_err end
  return self.active_locale
end

function Translator:locale()
  return self.active_locale
end

function Translator:direction()
  local catalog = self.catalogs[self.active_locale]
  return catalog and catalog._meta.direction or "ltr"
end

function Translator:has(id)
  if type(id) ~= "string" then return false end
  for _, locale in ipairs(self.chain) do
    if self.catalogs[locale].messages[id] ~= nil then
      return true, locale
    end
  end
  return false
end

function Translator:t(id, variables, explicit_count)
  if type(id) ~= "string" or #id > Catalog.MAX_MESSAGE_ID_BYTES
      or id:find("[%z\1-\31\127]") then
    return "<invalid-message-id>"
  end
  variables = variables or {}
  local count = explicit_count
  if count == nil and type(variables) == "table" then
    count = variables.count
  end

  local template
  for _, locale in ipairs(self.chain) do
    local catalog = self.catalogs[locale]
    local message = catalog.messages[id]
    if type(message) == "string" then
      template = message
      break
    elseif type(message) == "table" then
      if count ~= nil then
        local category = Plural.select(catalog._meta.plural_rule, count)
        template = message[category] or message.other
      end
      if template then
        break
      end
    end
  end

  if not template then
    if self.missing_count < MAX_MISSING_IDS and not self.missing_ids[id] then
      self.missing_ids[id] = true
      self.missing_count = self.missing_count + 1
    end
    return id
  end

  local formatted, err = Format.interpolate(template, variables)
  if not formatted then
    self.format_error_count = self.format_error_count + 1
    self.last_format_error = string.format("%s: %s", id, err)
    return template
  end
  return formatted
end

Translator.translate = Translator.t

function Translator:add_catalog(raw_catalog, options)
  if options == nil then options = {} end
  if type(options) ~= "table" then return nil, "catalog options must be a table" end
  local source = options.source or "<custom catalog>"
  if type(raw_catalog) ~= "table" then
    return nil, source .. ": catalog must be a table"
  end
  if type(source) ~= "string" or source == "" or #source > 4096
      or source:find("[%z\1-\31\127]") then
    return nil, "catalog source must be a safe non-empty string"
  end
  if options.require_complete ~= nil and type(options.require_complete) ~= "boolean" then
    return nil, "require_complete must be a boolean"
  end
  local candidate, validation_errors = Catalog.validate({
    _meta = raw_catalog._meta,
    messages = raw_catalog.messages,
  }, { source = source })
  if not candidate then
    return nil, Catalog.format_errors(validation_errors)
  end

  local reference = self.catalogs[self.default_locale]
  local compatible, errors = Catalog.validate_against(candidate, reference, {
    source = source,
    require_complete = options.require_complete,
  })
  if not compatible then
    return nil, Catalog.format_errors(errors)
  end

  local locale = catalog_locale(candidate)
  local normalized_alias
  if options.alias then
    local alias, alias_err = Locale.normalize(options.alias)
    if not alias then
      return nil, alias_err
    end
    normalized_alias = alias
  end
  local previous_catalog = self.catalogs[locale]
  local previous_alias = normalized_alias and self.aliases[normalized_alias] or nil
  self.catalogs[locale] = candidate
  if normalized_alias then
    self.aliases[normalized_alias] = locale
  end
  local rebuilt, rebuild_err = self:_rebuild_chain(self.requested_locale)
  if not rebuilt then
    self.catalogs[locale] = previous_catalog
    if normalized_alias then self.aliases[normalized_alias] = previous_alias end
    return nil, rebuild_err
  end
  return locale
end

function Translator:load_yaml(text, options)
  if options == nil then options = {} end
  if type(options) ~= "table" then return nil, "catalog options must be a table" end
  local candidate, errors = Catalog.from_yaml(text, options)
  if not candidate then
    return nil, Catalog.format_errors(errors)
  end
  return self:add_catalog(candidate, options)
end

function Translator:load_file(path, options)
  if options == nil then options = {} end
  if type(options) ~= "table" then return nil, "catalog options must be a table" end
  local copied, copy_err = shallow_copy(options)
  if not copied then return nil, copy_err end
  copied.source = copied.source or path
  local candidate, errors = Catalog.from_file(path, copied)
  if not candidate then
    return nil, Catalog.format_errors(errors)
  end
  return self:add_catalog(candidate, copied)
end

function Translator:diagnostics()
  local chain = {}
  for i, locale in ipairs(self.chain) do
    chain[i] = locale
  end
  local active = self.catalogs[self.active_locale]
  local reference = self.catalogs[self.default_locale]
  local translated, total, ratio = Catalog.coverage(active, reference)
  return {
    requested_locale = self.requested_locale,
    active_locale = self.active_locale,
    direction = self:direction(),
    fallback_chain = chain,
    catalog_version = active._meta.catalog_version,
    status = self.statuses[self.active_locale] or "custom",
    translated_messages = translated,
    total_messages = total,
    coverage = ratio,
    missing_messages = total - translated,
    missing_lookups = self.missing_count,
    format_errors = self.format_error_count,
    last_format_error = self.last_format_error,
  }
end

function M.new(options)
  if type(options) == "string" then
    options = { locale = options }
  else
    options = options or {}
  end
  if type(options) ~= "table" then return nil, "i18n options must be a table or locale string" end
  if options.format ~= nil and type(options.format) ~= "table" then
    return nil, "format options must be a table"
  end
  local raw_registry = options.registry
  if raw_registry == nil then
    local ok, loaded = pcall(default_registry)
    if not ok then return nil, "cannot load locale registry: " .. tostring(loaded) end
    raw_registry = loaded
  end
  local registry, registry_err = validate_registry(raw_registry)
  if not registry then return nil, registry_err end
  local format_options, format_err = shallow_copy(options.format)
  if not format_options then return nil, format_err end
  local instance = setmetatable({
    catalogs = registry.catalogs,
    aliases = registry.aliases,
    statuses = registry.statuses,
    default_locale = registry.default or "en-US",
    format_options = format_options,
    missing_ids = {},
    missing_count = 0,
    format_error_count = 0,
  }, Translator)

  if options.catalogs ~= nil and type(options.catalogs) ~= "table" then
    return nil, "custom catalogs must be a table"
  end
  if type(options.catalogs) == "table" then
    local catalog_count = 0
    for _, catalog in pairs(options.catalogs) do
      catalog_count = catalog_count + 1
      if catalog_count > MAX_CATALOGS then return nil, "too many custom catalogs" end
      local locale, err = instance:add_catalog(catalog, { source = "<custom catalog>" })
      if not locale then
        return nil, err
      end
    end
  end

  local requested
  if options.locale ~= nil then
    requested, format_err = Locale.normalize(options.locale)
    if not requested then return nil, format_err end
  else
    requested = Locale.from_environment({
      cli = options.cli_locale,
      config = options.config_locale,
      getenv = options.getenv,
      default = instance.default_locale,
    })
  end
  local normalized = Locale.normalize(requested) or instance.default_locale
  local rebuilt, rebuild_err = instance:_rebuild_chain(normalized)
  if not rebuilt then return nil, rebuild_err end
  return instance
end

M.normalize_locale = Locale.normalize
M.locale_from_environment = Locale.from_environment
M.Catalog = Catalog
M.Format = Format
--- Locale identifiers this build actually ships, in stable sorted order.
-- The runtime language switch needs a list it can cycle; reaching into the
-- generated registry from the UI would tie the TUI to a generated file.
function M.available(registry)
  if registry == nil then
    local ok, loaded = pcall(default_registry)
    if not ok then return nil, "cannot load locale registry: " .. tostring(loaded) end
    registry = loaded
  end
  if type(registry) ~= "table" or type(registry.catalogs) ~= "table" then
    return nil, "locale registry must contain a catalogs table"
  end
  local locales = {}
  for locale in pairs(registry.catalogs) do
    if type(locale) == "string" then locales[#locales + 1] = locale end
  end
  table.sort(locales)
  return locales
end

M.Locale = Locale
M.Plural = Plural
M.Yaml = Yaml
M.Translator = Translator

return M
