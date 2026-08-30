-- Catalog schema, placeholder and cross-locale validation.

local Locale = require("wtop.i18n.locale")
local Plural = require("wtop.i18n.plural")
local Yaml = require("wtop.i18n.yaml_profile")

local M = {}

local MAX_MESSAGES = 20000
local MAX_MESSAGE_ID_BYTES = 255
local MAX_MESSAGE_BYTES = 65536
local MAX_PLACEHOLDERS = 128
local MAX_FALLBACKS = 16
local MAX_NAME_BYTES = 256

local META_FIELDS = {
  locale = true,
  name = true,
  direction = true,
  fallback = true,
  plural_rule = true,
  catalog_version = true,
}

local ROOT_FIELDS = {
  _meta = true,
  messages = true,
}

local function sorted_keys(value)
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function safe_text(value, maximum, allow_newlines)
  if type(value) ~= "string" or value == "" or #value > maximum then return false end
  if not utf8.len(value) then return false end
  local pattern = allow_newlines and "[%z\1-\8\11\12\14-\31\127]" or "[%z\1-\31\127]"
  return not value:find(pattern)
end

local function pointer(...)
  local parts = { ... }
  local encoded = {}
  for i, part in ipairs(parts) do
    encoded[i] = tostring(part):gsub("~", "~0"):gsub("/", "~1")
  end
  return "/" .. table.concat(encoded, "/")
end

local function add_error(errors, options, path, message)
  local source = options.source or (options.info and options.info.source) or "<catalog>"
  if type(source) ~= "string" or #source > 4096 or source:find("[%z\1-\31\127]") then
    source = "<catalog>"
  end
  local location = options.info and options.info.locations and options.info.locations[path]
  errors[#errors + 1] = string.format(
    "%s:%d:%d: %s",
    source,
    location and location.line or 1,
    location and location.column or 1,
    message
  )
end

local function table_shape(value, options, path)
  if type(value) ~= "table" or value == Yaml.null then
    return nil
  end
  local count, maximum, numeric, string_keys = 0, 0, true, true
  for key in pairs(value) do
    count = count + 1
    if type(key) == "number" and math.type(key) == "integer" and key >= 1 then
      maximum = math.max(maximum, key)
      string_keys = false
    else
      numeric = false
    end
    if type(key) ~= "string" then
      string_keys = false
    end
  end
  if count == 0 then
    return options.info and options.info.kinds and options.info.kinds[path] or "empty"
  end
  if numeric and maximum == count then
    return "sequence"
  end
  if string_keys then
    return "mapping"
  end
  return "mixed"
end

local function message_id_valid(id)
  if type(id) ~= "string" or #id > MAX_MESSAGE_ID_BYTES or not id:find(".", 1, true) then
    return false
  end
  for segment in id:gmatch("[^.]+") do
    if not segment:match("^[a-z][a-z0-9_]*$") then
      return false
    end
  end
  return not id:match("%.%.") and id:sub(-1) ~= "."
end

local function same_set(left, right)
  for key in pairs(left) do
    if not right[key] then
      return false
    end
  end
  for key in pairs(right) do
    if not left[key] then
      return false
    end
  end
  return true
end

local function set_text(value)
  local keys = sorted_keys(value)
  return "{" .. table.concat(keys, ", ") .. "}"
end

function M.placeholders(text)
  if type(text) ~= "string" then
    return nil, "message must be a string"
  end
  if not safe_text(text, MAX_MESSAGE_BYTES, true) then
    return nil, "message must be valid UTF-8 without terminal control characters and within the size limit"
  end
  local result = {}
  local count = 0
  local index = 1
  while index <= #text do
    local char = text:sub(index, index)
    if char == "{" then
      if text:sub(index + 1, index + 1) == "{" then
        index = index + 2
      else
        local close = text:find("}", index + 1, true)
        if not close then
          return nil, "unclosed placeholder"
        end
        local name = text:sub(index + 1, close - 1)
        if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
          return nil, "invalid placeholder {" .. name .. "}"
        end
        if text:sub(index + 1, close - 1):find("{", 1, true) then
          return nil, "nested placeholders are forbidden"
        end
        if #name > 128 then return nil, "placeholder name is too long" end
        if not result[name] then
          count = count + 1
          if count > MAX_PLACEHOLDERS then return nil, "message has too many placeholders" end
          result[name] = true
        end
        index = close + 1
      end
    elseif char == "}" then
      if text:sub(index + 1, index + 1) == "}" then
        index = index + 2
      else
        return nil, "unmatched closing brace"
      end
    else
      index = index + 1
    end
  end
  return result
end

local function validate_message(message, id, plural_rule, options, errors)
  local path = pointer("messages", id)
  if type(message) == "string" then
    local placeholders, err = M.placeholders(message)
    if not placeholders then
      add_error(errors, options, path, string.format("message %q: %s", id, err))
      return nil
    end
    return { kind = "text", placeholders = placeholders, value = message }
  end

  if type(message) ~= "table" or message == Yaml.null then
    add_error(errors, options, path, string.format("message %q must be a string or plural mapping", id))
    return nil
  end
  local shape = table_shape(message, options, path)
  if shape ~= "mapping" then
    add_error(errors, options, path, string.format("plural message %q must be a non-empty mapping", id))
    return nil
  end

  local canonical_placeholders
  local output = {}
  for _, category in ipairs(sorted_keys(message)) do
    local value = message[category]
    local category_path = pointer("messages", id, category)
    if type(category) ~= "string" or not Plural.is_category(category) then
      add_error(errors, options, category_path, string.format("message %q has invalid plural category %q", id, tostring(category)))
    elseif type(value) ~= "string" then
      add_error(errors, options, category_path, string.format("plural variant %q.%s must be a string", id, category))
    else
      local placeholders, err = M.placeholders(value)
      if not placeholders then
        add_error(errors, options, category_path, string.format("plural variant %q.%s: %s", id, category, err))
      else
        if not canonical_placeholders then
          canonical_placeholders = placeholders
        elseif not same_set(canonical_placeholders, placeholders) then
          add_error(
            errors,
            options,
            category_path,
            string.format(
              "plural variant %q.%s placeholders %s do not match %s",
              id,
              category,
              set_text(placeholders),
              set_text(canonical_placeholders)
            )
          )
        end
        output[category] = value
      end
    end
  end

  local categories = Plural.categories(plural_rule)
  if categories then
    for _, category in ipairs(categories) do
      if message[category] == nil then
        add_error(
          errors,
          options,
          path,
          string.format("plural message %q is missing required %q category for rule %q", id, category, plural_rule)
        )
      end
    end
  end
  if canonical_placeholders and not canonical_placeholders.count then
    add_error(errors, options, path, string.format("plural message %q must contain the {count} placeholder", id))
  end
  return { kind = "plural", placeholders = canonical_placeholders or {}, value = output }
end

function M.validate(raw, options)
  if options == nil then options = {} end
  if type(options) ~= "table" then
    return nil, { "<catalog>:1:1: validation options must be a table" }
  end
  local errors = {}
  if type(raw) ~= "table" or raw == Yaml.null then
    add_error(errors, options, "/", "catalog root must be a mapping")
    return nil, errors
  end
  if table_shape(raw, options, "/") ~= "mapping" then
    add_error(errors, options, "/", "catalog root must be a mapping")
    return nil, errors
  end

  for _, key in ipairs(sorted_keys(raw)) do
    if not ROOT_FIELDS[key] then
      add_error(errors, options, pointer(key), "unknown catalog root field " .. tostring(key))
    end
  end

  local meta = raw._meta
  if type(meta) ~= "table" or meta == Yaml.null or table_shape(meta, options, pointer("_meta")) ~= "mapping" then
    add_error(errors, options, pointer("_meta"), "_meta must be a mapping")
    meta = {}
  end
  for _, key in ipairs(sorted_keys(meta)) do
    if not META_FIELDS[key] then
      add_error(errors, options, pointer("_meta", key), "unknown _meta field " .. tostring(key))
    end
  end
  for key in pairs(META_FIELDS) do
    if meta[key] == nil then
      add_error(errors, options, pointer("_meta"), "missing required _meta field " .. key)
    end
  end

  local normalized_locale
  if type(meta.locale) ~= "string" then
    add_error(errors, options, pointer("_meta", "locale"), "_meta.locale must be a string")
  else
    local locale_err
    normalized_locale, locale_err = Locale.normalize(meta.locale)
    if not normalized_locale then
      add_error(errors, options, pointer("_meta", "locale"), "invalid locale: " .. locale_err)
    elseif normalized_locale ~= meta.locale then
      add_error(
        errors,
        options,
        pointer("_meta", "locale"),
        string.format("locale must use canonical form %q", normalized_locale)
      )
    end
  end
  if not safe_text(meta.name, MAX_NAME_BYTES, false) then
    add_error(errors, options, pointer("_meta", "name"), "_meta.name must be a safe non-empty UTF-8 string within the size limit")
  end
  if meta.direction ~= "ltr" and meta.direction ~= "rtl" then
    add_error(errors, options, pointer("_meta", "direction"), '_meta.direction must be "ltr" or "rtl"')
  end
  if type(meta.catalog_version) ~= "number"
    or math.type(meta.catalog_version) ~= "integer"
    or meta.catalog_version < 1
  then
    add_error(errors, options, pointer("_meta", "catalog_version"), "_meta.catalog_version must be a positive integer")
  end
  if type(meta.plural_rule) ~= "string" or not Plural.has_rule(meta.plural_rule) then
    add_error(errors, options, pointer("_meta", "plural_rule"), "unknown _meta.plural_rule " .. tostring(meta.plural_rule))
  end

  local fallback = meta.fallback
  local fallback_shape = table_shape(fallback, options, pointer("_meta", "fallback"))
  if fallback_shape ~= "sequence" and fallback_shape ~= "empty" then
    add_error(errors, options, pointer("_meta", "fallback"), "_meta.fallback must be a sequence")
    fallback = {}
  end
  local normalized_fallback, fallback_seen = {}, {}
  if type(fallback) == "table" and fallback ~= Yaml.null then
    if #fallback > MAX_FALLBACKS then
      add_error(errors, options, pointer("_meta", "fallback"), "_meta.fallback has too many entries")
    end
    for index, value in ipairs(fallback) do
      local path = pointer("_meta", "fallback", index)
      if type(value) ~= "string" then
        add_error(errors, options, path, "fallback locale must be a string")
      else
        local normalized, err = Locale.normalize(value)
        if not normalized then
          add_error(errors, options, path, "invalid fallback locale: " .. err)
        elseif normalized ~= value then
          add_error(errors, options, path, string.format("fallback locale must use canonical form %q", normalized))
        elseif normalized == normalized_locale then
          add_error(errors, options, path, "catalog cannot fall back to itself")
        elseif fallback_seen[normalized] then
          add_error(errors, options, path, "duplicate fallback locale " .. normalized)
        else
          fallback_seen[normalized] = true
          normalized_fallback[#normalized_fallback + 1] = normalized
        end
      end
    end
  end

  local messages = raw.messages
  if type(messages) ~= "table"
    or messages == Yaml.null
    or table_shape(messages, options, pointer("messages")) ~= "mapping"
  then
    add_error(errors, options, pointer("messages"), "messages must be a non-empty mapping")
    messages = {}
  end
  local output_messages = {}
  local descriptors = {}
  local message_count = 0
  for _ in pairs(messages) do
    message_count = message_count + 1
    if message_count > MAX_MESSAGES then
      add_error(errors, options, pointer("messages"), "catalog has too many messages")
      break
    end
  end
  local message_ids = message_count <= MAX_MESSAGES and sorted_keys(messages) or {}
  for _, id in ipairs(message_ids) do
    if not message_id_valid(id) then
      add_error(errors, options, pointer("messages", id), "invalid message ID " .. tostring(id))
    else
      local descriptor = validate_message(messages[id], id, meta.plural_rule, options, errors)
      if descriptor then
        output_messages[id] = descriptor.value
        descriptors[id] = descriptor
      end
    end
  end

  if #errors > 0 then
    return nil, errors
  end
  return {
    _meta = {
      locale = normalized_locale,
      name = meta.name,
      direction = meta.direction,
      fallback = normalized_fallback,
      plural_rule = meta.plural_rule,
      catalog_version = meta.catalog_version,
    },
    messages = output_messages,
    _descriptors = descriptors,
  }
end

local function descriptor_for(catalog, id)
  if catalog._descriptors and catalog._descriptors[id] then
    return catalog._descriptors[id]
  end
  local message = catalog.messages[id]
  if type(message) == "string" then
    return { kind = "text", placeholders = M.placeholders(message) or {} }
  end
  if type(message) == "table" then
    local first = message.other
    if not first then
      for _, value in pairs(message) do
        if type(value) == "string" then
          first = value
          break
        end
      end
    end
    return { kind = "plural", placeholders = first and (M.placeholders(first) or {}) or {} }
  end
  return nil
end

function M.validate_against(catalog, reference, options)
  if options == nil then options = {} end
  if type(options) ~= "table" then
    return nil, { "<catalog>:1:1: validation options must be a table" }
  end
  local errors = {}
  if type(catalog) ~= "table" or type(reference) ~= "table"
      or type(catalog.messages) ~= "table" or type(reference.messages) ~= "table" then
    add_error(errors, options, "/", "catalog and reference must already be validated")
    return nil, errors
  end
  for _, id in ipairs(sorted_keys(catalog.messages)) do
    local descriptor = descriptor_for(catalog, id)
    local reference_descriptor = descriptor_for(reference, id)
    if not reference_descriptor then
      add_error(errors, options, pointer("messages", id), string.format("message %q does not exist in en-US", id))
    elseif descriptor.kind ~= reference_descriptor.kind then
      add_error(errors, options, pointer("messages", id), string.format("message %q changes text/plural type", id))
    elseif not same_set(descriptor.placeholders, reference_descriptor.placeholders) then
      add_error(
        errors,
        options,
        pointer("messages", id),
        string.format(
          "message %q placeholders %s do not match en-US %s",
          id,
          set_text(descriptor.placeholders),
          set_text(reference_descriptor.placeholders)
        )
      )
    end
  end
  if options.require_complete then
    for _, id in ipairs(sorted_keys(reference.messages)) do
      if catalog.messages[id] == nil then
        add_error(errors, options, pointer("messages"), string.format("stable catalog is missing message %q", id))
      end
    end
  end
  if #errors > 0 then
    return nil, errors
  end
  return true
end

function M.coverage(catalog, reference)
  if type(catalog) ~= "table" or type(reference) ~= "table"
      or type(catalog.messages) ~= "table" or type(reference.messages) ~= "table" then
    return nil, nil, nil, "catalog and reference must already be validated"
  end
  local total, translated = 0, 0
  for id in pairs(reference.messages) do
    total = total + 1
    if catalog.messages[id] ~= nil then
      translated = translated + 1
    end
  end
  return translated, total, total == 0 and 1 or translated / total
end

function M.from_yaml(text, options)
  if options == nil then options = {} end
  if type(options) ~= "table" then
    return nil, { "<catalog>:1:1: parse options must be a table" }
  end
  local raw, info_or_error = Yaml.parse(text, options)
  if not raw then
    return nil, { info_or_error }
  end
  local validate_options = {}
  for key, value in pairs(options) do
    validate_options[key] = value
  end
  validate_options.info = info_or_error
  validate_options.source = options.source or info_or_error.source
  return M.validate(raw, validate_options)
end

function M.from_file(path, options)
  if options == nil then options = {} end
  if type(options) ~= "table" then
    return nil, { "<catalog>:1:1: parse options must be a table" }
  end
  local raw, info_or_error = Yaml.parse_file(path, options)
  if not raw then
    return nil, { info_or_error }
  end
  local validate_options = {}
  for key, value in pairs(options) do
    validate_options[key] = value
  end
  validate_options.info = info_or_error
  validate_options.source = options.source or path
  return M.validate(raw, validate_options)
end

M.MAX_MESSAGES = MAX_MESSAGES
M.MAX_MESSAGE_ID_BYTES = MAX_MESSAGE_ID_BYTES
M.MAX_MESSAGE_BYTES = MAX_MESSAGE_BYTES

function M.format_errors(errors)
  if type(errors) == "string" then
    return errors
  end
  return table.concat(errors or {}, "\n")
end

return M
