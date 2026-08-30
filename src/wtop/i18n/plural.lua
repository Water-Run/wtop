-- CLDR-style cardinal plural selection used by compiled and user catalogs.
--
-- The implementation intentionally covers the locale families shipped or
-- planned by wtop.  Callers may pass a decimal as a string when visible
-- fraction digits (for example "1.0") must be preserved.

local M = {}

local MAX_DECIMAL_BYTES = 128
local MAX_EXACT_INTEGER = 9007199254740991

local category_order = { "zero", "one", "two", "few", "many", "other" }

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function decimal_text(value)
  if type(value) == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil, "plural value must be a finite number"
    end
    if math.abs(value) > MAX_EXACT_INTEGER then
      return nil, "plural value exceeds the exact numeric range"
    end
    local text = tostring(math.abs(value)):gsub(",", ".")
    if text:find("[eE]") then
      text = string.format("%.15f", math.abs(value)):gsub("0+$", ""):gsub("%.$", "")
    end
    return text
  end

  if type(value) ~= "string" then
    return nil, "plural value must be a number or decimal string"
  end

  local text = trim(value)
  if #text == 0 or #text > MAX_DECIMAL_BYTES then
    return nil, "invalid plural decimal"
  end
  if not text:match("^[+-]?%d+%.?%d*[eE]?[+-]?%d*$")
      and not text:match("^[+-]?%d*%.%d+[eE]?[+-]?%d*$") then
    return nil, "invalid plural decimal"
  end
  text = text:gsub("^[+-]", "")
  if text:find("[eE]") then
    local number = tonumber(text)
    if not number or number ~= number or number == math.huge then
      return nil, "invalid plural decimal"
    end
    if math.abs(number) > MAX_EXACT_INTEGER then
      return nil, "plural value exceeds the exact numeric range"
    end
    text = string.format("%.15f", number):gsub(",", "."):gsub("0+$", ""):gsub("%.$", "")
  end
  return text
end

function M.operands(value)
  local text, err = decimal_text(value)
  if not text then
    return nil, err
  end

  local integer, fraction = text:match("^(%d+)%.(%d+)$")
  if not integer then
    integer = text:match("^(%d+)$")
    fraction = ""
  end
  if not integer then
    return nil, "invalid plural decimal"
  end

  integer = integer:gsub("^0+(%d)", "%1")
  local i = tonumber(integer) or 0
  local v = #fraction
  local f = tonumber(fraction) or 0
  local without_zeroes = fraction:gsub("0+$", "")
  local w = #without_zeroes
  local t = tonumber(without_zeroes) or 0

  local n = tonumber(text)
  if not n or n ~= n or n == math.huge or i > MAX_EXACT_INTEGER
      or f > MAX_EXACT_INTEGER or t > MAX_EXACT_INTEGER then
    return nil, "plural value exceeds the exact numeric range"
  end

  return {
    n = n,
    i = i,
    v = v,
    w = w,
    f = f,
    t = t,
  }
end

local rules = {}
local required = {}

local function define(names, categories, selector)
  for _, name in ipairs(names) do
    rules[name] = selector
    required[name] = categories
  end
end

define({ "other", "zh", "ja", "ko", "id", "vi", "th" }, { "other" }, function()
  return "other"
end)

define({ "en", "de" }, { "one", "other" }, function(o)
  if o.i == 1 and o.v == 0 then
    return "one"
  end
  return "other"
end)

define({ "es" }, { "one", "many", "other" }, function(o)
  if o.n == 1 then
    return "one"
  end
  if o.v == 0 and o.i ~= 0 and o.i % 1000000 == 0 then
    return "many"
  end
  return "other"
end)

define({ "it" }, { "one", "many", "other" }, function(o)
  if o.i == 1 and o.v == 0 then
    return "one"
  end
  if o.v == 0 and o.i ~= 0 and o.i % 1000000 == 0 then
    return "many"
  end
  return "other"
end)

define({ "fr", "pt" }, { "one", "many", "other" }, function(o)
  if o.i == 0 or o.i == 1 then
    return "one"
  end
  if o.v == 0 and o.i ~= 0 and o.i % 1000000 == 0 then
    return "many"
  end
  return "other"
end)

define({ "hi" }, { "one", "other" }, function(o)
  if o.i == 0 or o.n == 1 then
    return "one"
  end
  return "other"
end)

define({ "ru", "uk" }, { "one", "few", "many", "other" }, function(o)
  if o.v ~= 0 then
    return "other"
  end
  local mod10, mod100 = o.i % 10, o.i % 100
  if mod10 == 1 and mod100 ~= 11 then
    return "one"
  end
  if mod10 >= 2 and mod10 <= 4 and not (mod100 >= 12 and mod100 <= 14) then
    return "few"
  end
  if mod10 == 0 or mod10 >= 5 or (mod100 >= 11 and mod100 <= 14) then
    return "many"
  end
  return "other"
end)

define({ "pl" }, { "one", "few", "many", "other" }, function(o)
  if o.v ~= 0 then
    return "other"
  end
  local mod10, mod100 = o.i % 10, o.i % 100
  if o.i == 1 then
    return "one"
  end
  if mod10 >= 2 and mod10 <= 4 and not (mod100 >= 12 and mod100 <= 14) then
    return "few"
  end
  if mod10 == 0 or mod10 == 1 or mod10 >= 5 or (mod100 >= 12 and mod100 <= 14) then
    return "many"
  end
  return "other"
end)

define({ "cs", "sk" }, { "one", "few", "many", "other" }, function(o)
  if o.v ~= 0 then
    return "many"
  end
  if o.i == 1 then
    return "one"
  end
  if o.i >= 2 and o.i <= 4 then
    return "few"
  end
  return "other"
end)

define({ "sl" }, { "one", "two", "few", "other" }, function(o)
  local mod100 = o.i % 100
  if o.v == 0 and mod100 == 1 then
    return "one"
  end
  if o.v == 0 and mod100 == 2 then
    return "two"
  end
  if o.v ~= 0 or mod100 == 3 or mod100 == 4 then
    return "few"
  end
  return "other"
end)

define({ "ar" }, { "zero", "one", "two", "few", "many", "other" }, function(o)
  if o.n == 0 then
    return "zero"
  end
  if o.n == 1 then
    return "one"
  end
  if o.n == 2 then
    return "two"
  end
  local mod100 = o.n % 100
  if mod100 >= 3 and mod100 <= 10 then
    return "few"
  end
  if mod100 >= 11 and mod100 <= 99 then
    return "many"
  end
  return "other"
end)

define({ "he" }, { "one", "two", "other" }, function(o)
  if o.v == 0 and o.i == 1 then
    return "one"
  end
  if o.v == 0 and o.i == 2 then
    return "two"
  end
  return "other"
end)

local function rule_name(rule)
  if type(rule) ~= "string" or #rule == 0 or #rule > 255
      or not rule:match("^[A-Za-z0-9_-]+$") then
    return nil
  end
  local normalized = rule:lower():gsub("_", "-")
  if rules[normalized] then
    return normalized
  end
  return normalized:match("^([a-z]+)")
end

function M.has_rule(rule)
  local name = rule_name(rule)
  return name ~= nil and rules[name] ~= nil
end

function M.select(rule, value)
  local name = rule_name(rule)
  local selector = name and rules[name]
  if not selector then
    return nil, "unknown plural rule: " .. tostring(rule)
  end
  local operands, err = M.operands(value)
  if not operands then
    return nil, err
  end
  return selector(operands)
end

function M.categories(rule)
  local name = rule_name(rule)
  local categories = name and required[name]
  if not categories then
    return nil, "unknown plural rule: " .. tostring(rule)
  end
  local copy = {}
  for i, category in ipairs(categories) do
    copy[i] = category
  end
  return copy
end

function M.is_category(value)
  for _, category in ipairs(category_order) do
    if value == category then
      return true
    end
  end
  return false
end

M.category_order = category_order

return M
