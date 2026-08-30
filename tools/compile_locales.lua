#!/usr/bin/env lua

local GENERATOR_VERSION = "1.0.0"

local script_path = (arg and arg[0] or "tools/compile_locales.lua"):gsub("\\", "/")
local project_root = script_path:match("^(.*)/tools/[^/]+$") or "."
if project_root == "" then
  project_root = "."
end
package.path = project_root .. "/src/?.lua;" .. project_root .. "/src/?/init.lua;" .. package.path

local Catalog = require("wtop.i18n.catalog")
local Locale = require("wtop.i18n.locale")
local Yaml = require("wtop.i18n.yaml_profile")

local function normalized_cli_path(path)
  -- The runtime file boundary deliberately rejects dot path components.
  -- Preserve that boundary while accepting the conventional `./locales`
  -- spelling used when this tool is launched from the repository root.
  path = path:gsub("^%./+", "")
  return path == "" and "." or path
end

local function parse_arguments(arguments)
  local options = {
    source = normalized_cli_path(project_root .. "/locales"),
    output = normalized_cli_path(project_root .. "/src/wtop/generated/locales"),
    check = false,
  }
  local index = 1
  while index <= #arguments do
    local value = arguments[index]
    if value == "--source" or value == "--output" then
      local next_value = arguments[index + 1]
      if not next_value or next_value:sub(1, 1) == "-" then
        return nil, value .. " requires a path"
      end
      options[value:sub(3)] = normalized_cli_path(next_value:gsub("/+$", ""))
      index = index + 2
    elseif value == "--check" then
      options.check = true
      index = index + 1
    elseif value == "--help" or value == "-h" then
      options.help = true
      index = index + 1
    else
      return nil, "unknown argument: " .. tostring(value)
    end
  end
  return options
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, string.format("cannot open %s: %s", path, err or "unknown error")
  end
  local contents = file:read("*a")
  file:close()
  if not contents then
    return nil, "cannot read " .. path
  end
  return contents
end

local function rotr(value, bits)
  return ((value >> bits) | (value << (32 - bits))) & 0xffffffff
end

local SHA256_CONSTANTS = {
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
}

local function sha256(message)
  local bit_length = #message * 8
  local padding = (56 - ((#message + 1) % 64)) % 64
  message = message .. "\128" .. string.rep("\0", padding) .. string.pack(">I8", bit_length)

  local h = {
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  }
  local words = {}
  for offset = 1, #message, 64 do
    for index = 0, 15 do
      words[index] = string.unpack(">I4", message, offset + index * 4)
    end
    for index = 16, 63 do
      local left = words[index - 15]
      local right = words[index - 2]
      local s0 = rotr(left, 7) ~ rotr(left, 18) ~ (left >> 3)
      local s1 = rotr(right, 17) ~ rotr(right, 19) ~ (right >> 10)
      words[index] = (words[index - 16] + s0 + words[index - 7] + s1) & 0xffffffff
    end

    local a, b, c, d, e, f, g, hh = table.unpack(h)
    for index = 0, 63 do
      local sum1 = rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)
      local choice = (e & f) ~ ((~e) & g)
      local temporary1 = (hh + sum1 + choice + SHA256_CONSTANTS[index + 1] + words[index]) & 0xffffffff
      local sum0 = rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)
      local majority = (a & b) ~ (a & c) ~ (b & c)
      local temporary2 = (sum0 + majority) & 0xffffffff
      hh, g, f, e, d, c, b, a =
        g, f, e, (d + temporary1) & 0xffffffff, c, b, a, (temporary1 + temporary2) & 0xffffffff
    end
    h[1] = (h[1] + a) & 0xffffffff
    h[2] = (h[2] + b) & 0xffffffff
    h[3] = (h[3] + c) & 0xffffffff
    h[4] = (h[4] + d) & 0xffffffff
    h[5] = (h[5] + e) & 0xffffffff
    h[6] = (h[6] + f) & 0xffffffff
    h[7] = (h[7] + g) & 0xffffffff
    h[8] = (h[8] + hh) & 0xffffffff
  end

  local output = {}
  for index = 1, 8 do
    output[index] = string.format("%08x", h[index])
  end
  return table.concat(output)
end

local function quote(value)
  local output = { '"' }
  for index = 1, #value do
    local byte = value:byte(index)
    if byte == 34 then
      output[#output + 1] = '\\"'
    elseif byte == 92 then
      output[#output + 1] = "\\\\"
    elseif byte == 10 then
      output[#output + 1] = "\\n"
    elseif byte == 13 then
      output[#output + 1] = "\\r"
    elseif byte == 9 then
      output[#output + 1] = "\\t"
    elseif byte < 32 or byte == 127 then
      output[#output + 1] = string.format("\\%03d", byte)
    else
      output[#output + 1] = string.char(byte)
    end
  end
  output[#output + 1] = '"'
  return table.concat(output)
end

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

local function is_array(value)
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
      return false
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  return count > 0 and maximum == count
end

local function serialize(value, indent)
  indent = indent or 0
  local kind = type(value)
  if kind == "string" then
    return quote(value)
  elseif kind == "number" or kind == "boolean" then
    return tostring(value)
  elseif kind ~= "table" then
    error("cannot serialize value of type " .. kind)
  end

  if next(value) == nil then
    return "{}"
  end
  local prefix = string.rep(" ", indent)
  local child_prefix = string.rep(" ", indent + 2)
  local output = { "{" }
  if is_array(value) then
    for index = 1, #value do
      output[#output + 1] = "\n" .. child_prefix .. serialize(value[index], indent + 2) .. ","
    end
  else
    for _, key in ipairs(sorted_keys(value)) do
      output[#output + 1] =
        "\n" .. child_prefix .. "[" .. quote(key) .. "] = " .. serialize(value[key], indent + 2) .. ","
    end
  end
  output[#output + 1] = "\n" .. prefix .. "}"
  return table.concat(output)
end

local function manifest_entries(manifest, source)
  if type(manifest) ~= "table" or manifest.schema_version ~= 1 or type(manifest.locales) ~= "table" then
    return nil, source .. ": manifest must contain schema_version: 1 and a locales sequence"
  end
  local result, seen = {}, {}
  for index, entry in ipairs(manifest.locales) do
    if type(entry) ~= "table" then
      return nil, string.format("%s: locales[%d] must be a mapping", source, index)
    end
    local normalized = type(entry.id) == "string" and Locale.normalize(entry.id) or nil
    if not normalized or normalized ~= entry.id then
      return nil, string.format("%s: locales[%d].id is not a canonical locale", source, index)
    end
    if seen[entry.id] then
      return nil, string.format("%s: duplicate locale %s", source, entry.id)
    end
    seen[entry.id] = true
    if entry.status ~= "stable" and entry.status ~= "preview" and entry.status ~= "planned" then
      return nil, string.format("%s: locale %s has invalid status", source, entry.id)
    end
    if entry.direction ~= "ltr" and entry.direction ~= "rtl" then
      return nil, string.format("%s: locale %s has invalid direction", source, entry.id)
    end
    if type(entry.name) ~= "string" or type(entry.wave) ~= "string" then
      return nil, string.format("%s: locale %s is missing name or wave", source, entry.id)
    end
    if entry.status ~= "planned" then
      result[#result + 1] = entry
    end
  end
  table.sort(result, function(a, b)
    return a.id < b.id
  end)
  return result
end

local function build_aliases(entries)
  local candidates = {}
  for _, entry in ipairs(entries) do
    local language = Locale.language(entry.id)
    candidates[language] = candidates[language] or {}
    candidates[language][#candidates[language] + 1] = entry
  end
  local aliases = {}
  for language, choices in pairs(candidates) do
    table.sort(choices, function(a, b)
      if a.status ~= b.status then
        return a.status == "stable"
      end
      return a.id < b.id
    end)
    aliases[language] = choices[1].id
  end
  return aliases
end

local function check_fallbacks(catalogs, aliases)
  local visiting, visited = {}, {}
  local function resolve(locale)
    return catalogs[locale] and locale or aliases[locale]
  end
  local function visit(locale, trail)
    locale = resolve(locale)
    if not locale then
      return nil, "fallback locale is not compiled: " .. tostring(trail[#trail])
    end
    if visiting[locale] then
      trail[#trail + 1] = locale
      return nil, "catalog fallback cycle: " .. table.concat(trail, " -> ")
    end
    if visited[locale] then
      return true
    end
    visiting[locale] = true
    trail[#trail + 1] = locale
    for _, fallback in ipairs(catalogs[locale]._meta.fallback) do
      local ok, err = visit(fallback, trail)
      if not ok then
        return nil, err
      end
    end
    trail[#trail] = nil
    visiting[locale] = nil
    visited[locale] = true
    return true
  end
  for locale in pairs(catalogs) do
    local ok, err = visit(locale, {})
    if not ok then
      return nil, err
    end
  end
  return true
end

local function module_source(catalog, entry, source_name, digest)
  local output_catalog = {
    _build = {
      generator_version = GENERATOR_VERSION,
      source = source_name,
      source_sha256 = digest,
      status = entry.status,
    },
    _meta = catalog._meta,
    messages = catalog.messages,
  }
  return table.concat({
    "-- Generated by tools/compile_locales.lua; DO NOT EDIT.\n",
    "-- Source: ",
    source_name,
    "\n-- SHA-256: ",
    digest,
    "\n\nreturn ",
    serialize(output_catalog, 0),
    "\n",
  })
end

local function registry_source(entries, aliases)
  local lines = {
    "-- Generated by tools/compile_locales.lua; DO NOT EDIT.",
    "",
    "local catalogs = {",
  }
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = string.format(
      "  [%s] = require(%s),",
      quote(entry.id),
      quote("wtop.generated.locales." .. entry.id)
    )
  end
  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "return {"
  lines[#lines + 1] = '  default = "en-US",'
  lines[#lines + 1] = "  catalogs = catalogs,"
  lines[#lines + 1] = "  aliases = {"
  for _, language in ipairs(sorted_keys(aliases)) do
    lines[#lines + 1] = string.format("    [%s] = %s,", quote(language), quote(aliases[language]))
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "  statuses = {"
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = string.format("    [%s] = %s,", quote(entry.id), quote(entry.status))
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = string.format("  generator_version = %s,", quote(GENERATOR_VERSION))
  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

local function write_output(path, contents, check)
  local previous = read_file(path)
  if previous == contents then
    return "unchanged"
  end
  if check then
    return nil, "generated locale is stale or missing: " .. path
  end
  local file, err = io.open(path, "wb")
  if not file then
    return nil, string.format("cannot write %s: %s", path, err or "unknown error")
  end
  local ok, write_err = file:write(contents)
  file:close()
  if not ok then
    return nil, string.format("cannot write %s: %s", path, write_err or "unknown error")
  end
  return "written"
end

local function compile(options)
  local manifest_path = options.source .. "/manifest.yml"
  local manifest, manifest_info_or_error = Yaml.parse_file(manifest_path)
  if not manifest then
    return nil, manifest_info_or_error
  end
  local entries, entries_err = manifest_entries(manifest, manifest_path)
  if not entries then
    return nil, entries_err
  end

  local catalogs, sources, digests = {}, {}, {}
  local reference
  for _, entry in ipairs(entries) do
    local path = options.source .. "/" .. entry.id .. ".yml"
    local source, read_err = read_file(path)
    if not source then
      return nil, read_err
    end
    local catalog, errors = Catalog.from_yaml(source, { source = path })
    if not catalog then
      return nil, Catalog.format_errors(errors)
    end
    if catalog._meta.locale ~= entry.id
      or catalog._meta.name ~= entry.name
      or catalog._meta.direction ~= entry.direction
    then
      return nil, path .. ": _meta locale/name/direction does not match manifest.yml"
    end
    catalogs[entry.id] = catalog
    sources[entry.id] = source
    digests[entry.id] = sha256(source)
    if entry.id == "en-US" then
      reference = catalog
    end
  end
  if not reference then
    return nil, "manifest must contain a compiled en-US reference catalog"
  end

  for _, entry in ipairs(entries) do
    local ok, errors = Catalog.validate_against(catalogs[entry.id], reference, {
      source = options.source .. "/" .. entry.id .. ".yml",
      require_complete = entry.status == "stable",
    })
    if not ok then
      return nil, Catalog.format_errors(errors)
    end
  end

  local aliases = build_aliases(entries)
  local fallbacks_ok, fallback_err = check_fallbacks(catalogs, aliases)
  if not fallbacks_ok then
    return nil, fallback_err
  end

  local changed = 0
  for _, entry in ipairs(entries) do
    local source_name = "locales/" .. entry.id .. ".yml"
    local contents = module_source(catalogs[entry.id], entry, source_name, digests[entry.id])
    local state, write_err = write_output(options.output .. "/" .. entry.id .. ".lua", contents, options.check)
    if not state then
      return nil, write_err
    end
    if state == "written" then
      changed = changed + 1
    end
  end
  local registry_state, registry_err =
    write_output(options.output .. "/registry.lua", registry_source(entries, aliases), options.check)
  if not registry_state then
    return nil, registry_err
  end
  if registry_state == "written" then
    changed = changed + 1
  end

  local coverage = {}
  for _, entry in ipairs(entries) do
    local translated, total, ratio = Catalog.coverage(catalogs[entry.id], reference)
    coverage[#coverage + 1] =
      string.format("%s=%d/%d (%.1f%%, %s)", entry.id, translated, total, ratio * 100, entry.status)
  end
  return {
    catalogs = #entries,
    changed = changed,
    coverage = coverage,
  }
end

local options, argument_err = parse_arguments(arg or {})
if not options then
  error(argument_err, 0)
end
if options.help then
  io.write([[
Usage: lua tools/compile_locales.lua [options]

  --source DIR   YAML source directory (default: locales)
  --output DIR   generated Lua directory
  --check        validate and fail if generated files differ
  --help         show this help
]])
  return
end

local result, compile_err = compile(options)
if not result then
  error(compile_err, 0)
end
io.write(string.format("compiled %d catalogs; %d generated files changed\n", result.catalogs, result.changed))
for _, line in ipairs(result.coverage) do
  io.write("  ", line, "\n")
end
