-- Locale tag normalization and environment selection.

local M = {}

local MAX_LOCALE_BYTES = 255

local legacy_language = {
  iw = "he",
  ji = "yi",
}
legacy_language["in"] = "id"

local grandfathered = {
  ["art-lojban"] = "jbo",
  ["cel-gaulish"] = "cel-gaulish",
  ["en-gb-oed"] = "en-GB-oxendict",
  ["i-ami"] = "ami",
  ["i-bnn"] = "bnn",
  ["i-default"] = "i-default",
  ["i-enochian"] = "i-enochian",
  ["i-hak"] = "hak",
  ["i-klingon"] = "tlh",
  ["i-lux"] = "lb",
  ["i-mingo"] = "i-mingo",
  ["i-navajo"] = "nv",
  ["i-pwn"] = "pwn",
  ["i-tao"] = "tao",
  ["i-tay"] = "tay",
  ["i-tsu"] = "tsu",
  ["no-bok"] = "nb",
  ["no-nyn"] = "nn",
  ["sgn-be-fr"] = "sfb",
  ["sgn-be-nl"] = "vgt",
  ["sgn-ch-de"] = "sgg",
  ["zh-guoyu"] = "cmn",
  ["zh-hakka"] = "hak",
  ["zh-min"] = "zh-min",
  ["zh-min-nan"] = "nan",
  ["zh-xiang"] = "hsn",
}

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function title(value)
  return value:sub(1, 1):upper() .. value:sub(2):lower()
end

local function alnum(value)
  return value:match("^[A-Za-z0-9]+$") ~= nil
end

function M.normalize(value)
  if type(value) ~= "string" then
    return nil, "locale must be a string"
  end
  local tag = trim(value)
  if tag == "" then
    return nil, "locale must not be empty"
  end
  if #tag > MAX_LOCALE_BYTES then
    return nil, "locale is too long"
  end
  if tag:find("[^%w_.@-]") then
    return nil, "locale contains invalid characters"
  end

  local environment_form = tag:gsub("_", "-")
  local upper = environment_form:upper()
  if upper == "C" or upper == "POSIX" or upper:match("^C[.@]") then
    return "en-US"
  end
  tag = environment_form:match("^([^.@]+)") or environment_form
  if tag:find("--", 1, true) or tag:sub(1, 1) == "-" or tag:sub(-1) == "-" then
    return nil, "locale contains an empty subtag"
  end

  local lower = tag:lower()
  if grandfathered[lower] then
    return grandfathered[lower]
  end

  local parts = {}
  for part in tag:gmatch("[^-]+") do
    parts[#parts + 1] = part
  end
  if #parts == 0 then
    return nil, "locale must contain a language subtag"
  end

  if parts[1]:lower() == "x" then
    if #parts == 1 then
      return nil, "private-use locale requires at least one subtag"
    end
    local output = { "x" }
    for i = 2, #parts do
      if #parts[i] < 1 or #parts[i] > 8 or not alnum(parts[i]) then
        return nil, "invalid private-use locale subtag"
      end
      output[i] = parts[i]:lower()
    end
    return table.concat(output, "-")
  end

  local language = parts[1]
  if #language < 2 or #language > 8 or not language:match("^[A-Za-z]+$") then
    return nil, "invalid language subtag"
  end
  language = legacy_language[language:lower()] or language:lower()
  local output = { language }
  local index = 2

  if #language <= 3 then
    local extlang_count = 0
    while index <= #parts and #parts[index] == 3 and parts[index]:match("^[A-Za-z]+$") and extlang_count < 3 do
      output[#output + 1] = parts[index]:lower()
      extlang_count = extlang_count + 1
      index = index + 1
    end
  end

  if index <= #parts and #parts[index] == 4 and parts[index]:match("^[A-Za-z]+$") then
    output[#output + 1] = title(parts[index])
    index = index + 1
  end
  if index <= #parts then
    local region = parts[index]
    if (#region == 2 and region:match("^[A-Za-z]+$")) or (#region == 3 and region:match("^%d%d%d$")) then
      output[#output + 1] = region:upper()
      index = index + 1
    end
  end

  local variants = {}
  while index <= #parts do
    local variant = parts[index]
    local valid_variant = (#variant >= 5 and #variant <= 8 and alnum(variant))
      or (#variant == 4 and variant:sub(1, 1):match("%d") and alnum(variant))
    if not valid_variant then
      break
    end
    variant = variant:lower()
    if variants[variant] then
      return nil, "duplicate locale variant"
    end
    variants[variant] = true
    output[#output + 1] = variant
    index = index + 1
  end

  local extensions = {}
  while index <= #parts and #parts[index] == 1 and parts[index]:lower() ~= "x" do
    local singleton = parts[index]:lower()
    if not alnum(singleton) then
      return nil, "invalid locale extension singleton"
    end
    if extensions[singleton] then
      return nil, "duplicate locale extension singleton"
    end
    extensions[singleton] = true
    output[#output + 1] = singleton
    index = index + 1
    local count = 0
    while index <= #parts and #parts[index] >= 2 and #parts[index] <= 8 and alnum(parts[index]) do
      output[#output + 1] = parts[index]:lower()
      index = index + 1
      count = count + 1
    end
    if count == 0 then
      return nil, "locale extension requires a value"
    end
  end

  if index <= #parts and parts[index]:lower() == "x" then
    output[#output + 1] = "x"
    index = index + 1
    local count = 0
    while index <= #parts do
      if #parts[index] < 1 or #parts[index] > 8 or not alnum(parts[index]) then
        return nil, "invalid private-use locale subtag"
      end
      output[#output + 1] = parts[index]:lower()
      index = index + 1
      count = count + 1
    end
    if count == 0 then
      return nil, "private-use locale requires at least one subtag"
    end
  end

  if index <= #parts then
    return nil, "invalid locale subtag: " .. parts[index]
  end
  return table.concat(output, "-")
end

function M.language(value)
  local normalized = M.normalize(value)
  return normalized and normalized:match("^([a-z]+)") or nil
end

function M.parents(value)
  local normalized, err = M.normalize(value)
  if not normalized then
    return nil, err
  end
  local result = {}
  local current = normalized
  while current do
    result[#result + 1] = current
    current = current:match("^(.*)%-[^-]+$")
    -- RFC 4647 lookup removes an extension singleton together with the
    -- extension value that was just truncated.  Returning e.g. "en-u" here
    -- would produce an invalid locale and an impossible catalog lookup.
    if current and current:match("%-[A-Za-z0-9]$") then
      current = current:match("^(.*)%-[A-Za-z0-9]$")
    elseif current and current:match("^[xX]$") then
      current = nil
    end
  end
  return result
end

function M.from_environment(options)
  if options == nil then
    options = {}
  elseif type(options) ~= "table" then
    return "en-US"
  end
  local getenv = options.getenv or os.getenv
  if type(getenv) ~= "function" then
    getenv = nil
  end
  local candidates = {}
  local function add(value)
    if type(value) == "string" and value ~= "" and #value <= MAX_LOCALE_BYTES then
      candidates[#candidates + 1] = value
    end
  end
  add(options.cli)
  add(options.config)
  local function environment(name)
    if not getenv then return nil end
    local ok, value = pcall(getenv, name)
    return ok and value or nil
  end
  add(environment("LC_ALL"))
  add(environment("LC_MESSAGES"))
  add(environment("LANG"))
  add(options.default or "en-US")
  for _, candidate in ipairs(candidates) do
    local normalized = M.normalize(candidate)
    if normalized then
      return normalized
    end
  end
  return "en-US"
end

M.MAX_LOCALE_BYTES = MAX_LOCALE_BYTES

return M
