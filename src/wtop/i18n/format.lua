-- Locale-aware formatting facade.  This is intentionally deterministic and
-- independent from the process C locale.

local Locale = require("wtop.i18n.locale")

local M = {}
local Formatter = {}
Formatter.__index = Formatter

local MAX_DECIMAL_BYTES = 128
local MAX_TEMPLATE_BYTES = 256 * 1024
local MAX_INTERPOLATED_BYTES = 1024 * 1024
local MAX_PLACEHOLDER_BYTES = 128

local conventions = {
  de = { decimal = ",", group = "." },
  es = { decimal = ",", group = "." },
  fr = { decimal = ",", group = "\226\128\175" }, -- narrow no-break space
  pt = { decimal = ",", group = "." },
  ru = { decimal = ",", group = "\194\160" }, -- no-break space
}

local function finite_number(value)
  local number
  if type(value) == "number" then
    number = value
  elseif type(value) == "string" and #value <= MAX_DECIMAL_BYTES
      and (value:match("^[+-]?%d+%.?%d*$") or value:match("^[+-]?%d*%.%d+$")) then
    number = tonumber(value)
  end
  if not number or number ~= number or number == math.huge or number == -math.huge then
    return nil, "value must be a finite number"
  end
  return number
end

local function options_table(options)
  if options == nil then return {} end
  if type(options) ~= "table" then
    return nil, "format options must be a table"
  end
  return options
end

local function copy_options(base, override)
  if base ~= nil and type(base) ~= "table" then
    return nil, "format defaults must be a table"
  end
  if override ~= nil and type(override) ~= "table" then
    return nil, "format options must be a table"
  end
  local result = {}
  for key, value in pairs(base or {}) do
    result[key] = value
  end
  for key, value in pairs(override or {}) do
    result[key] = value
  end
  return result
end

local function language_for(options)
  local locale = options.locale or "en-US"
  return Locale.language(locale) or "en"
end

local function group_integer(integer, separator)
  local output = {}
  while #integer > 3 do
    table.insert(output, 1, integer:sub(-3))
    integer = integer:sub(1, -4)
  end
  table.insert(output, 1, integer)
  return table.concat(output, separator)
end

function M.number(value, options)
  local options_err
  options, options_err = options_table(options)
  if not options then return nil, options_err end
  local number, err = finite_number(value)
  if not number then
    return nil, err
  end
  local precision = options.precision
  if precision == nil then
    precision = number % 1 == 0 and 0 or 2
  end
  if type(precision) ~= "number" or math.type(precision) ~= "integer" or precision < 0 or precision > 12 then
    return nil, "precision must be an integer from 0 to 12"
  end
  local minimum = options.min_precision
  if minimum == nil then minimum = 0 end
  if type(minimum) ~= "number" or math.type(minimum) ~= "integer"
      or minimum < 0 or minimum > precision then
    return nil, "min_precision must be an integer from 0 to precision"
  end
  if options.locale ~= nil and not Locale.normalize(options.locale) then
    return nil, "locale must be a valid locale tag"
  end

  local negative = number < 0 or (number == 0 and 1 / number == -math.huge)
  local formatted = string.format("%." .. precision .. "f", math.abs(number)):gsub(",", ".")
  local integer, fraction = formatted:match("^(%d+)%.(%d+)$")
  if not integer then
    integer, fraction = formatted, ""
  end
  if options.trim_zeros ~= false and fraction ~= "" then
    while #fraction > minimum and fraction:sub(-1) == "0" do
      fraction = fraction:sub(1, -2)
    end
  end

  local convention = conventions[language_for(options)] or { decimal = ".", group = "," }
  if options.grouping ~= false then
    integer = group_integer(integer, convention.group)
  end
  local result = integer
  if fraction ~= "" then
    result = result .. convention.decimal .. fraction
  end
  if negative then
    result = "-" .. result
  elseif options.sign and number > 0 then
    result = "+" .. result
  end
  return result
end

function M.integer(value, options)
  local err
  options, err = copy_options(options, { precision = 0 })
  if not options then return nil, err end
  return M.number(value, options)
end

function M.percent(value, options)
  local options_err
  options, options_err = options_table(options)
  if not options then return nil, options_err end
  local number, err = finite_number(value)
  if not number then
    return nil, err
  end
  if options.ratio then
    number = number * 100
  end
  local formatted, format_err = M.number(number, options)
  if not formatted then
    return nil, format_err
  end
  return formatted .. (options.space and " " or "") .. "%"
end

local function scaled(value, base, units)
  local magnitude = math.abs(value)
  local index = 1
  while magnitude >= base and index < #units do
    magnitude = magnitude / base
    value = value / base
    index = index + 1
  end
  return value, units[index]
end

function M.bytes(value, options)
  local options_err
  options, options_err = options_table(options)
  if not options then return nil, options_err end
  local number, err = finite_number(value)
  if not number then
    return nil, err
  end
  if options.system ~= nil and options.system ~= "si" and options.system ~= "iec" then
    return nil, 'byte system must be "si" or "iec"'
  end
  local base = options.system == "si" and 1000 or 1024
  local units = options.system == "si"
      and { "B", "kB", "MB", "GB", "TB", "PB", "EB" }
    or { "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" }
  local amount, unit = scaled(number, base, units)
  local number_options = copy_options(options, {
    precision = options.precision or (math.abs(amount) < 10 and unit ~= "B" and 1 or 0),
  })
  local formatted, format_err = M.number(amount, number_options)
  return formatted and (formatted .. " " .. unit) or nil, format_err
end

function M.bits_per_second(value, options)
  local options_err
  options, options_err = options_table(options)
  if not options then return nil, options_err end
  local number, err = finite_number(value)
  if not number then
    return nil, err
  end
  local amount, unit = scaled(number, 1000, { "bit/s", "kbit/s", "Mbit/s", "Gbit/s", "Tbit/s" })
  local number_options = copy_options(options, {
    precision = options.precision or (math.abs(amount) < 10 and unit ~= "bit/s" and 1 or 0),
  })
  local formatted, format_err = M.number(amount, number_options)
  return formatted and (formatted .. " " .. unit) or nil, format_err
end

function M.frequency(value_hz, options)
  local options_err
  options, options_err = options_table(options)
  if not options then return nil, options_err end
  local number, err = finite_number(value_hz)
  if not number then
    return nil, err
  end
  local amount, unit = scaled(number, 1000, { "Hz", "kHz", "MHz", "GHz", "THz" })
  local number_options = copy_options(options, {
    precision = options.precision or (math.abs(amount) < 10 and unit ~= "Hz" and 2 or 0),
  })
  local formatted, format_err = M.number(amount, number_options)
  return formatted and (formatted .. " " .. unit) or nil, format_err
end

function M.duration(value_seconds, options)
  local options_err
  options, options_err = options_table(options)
  if not options then return nil, options_err end
  local number, err = finite_number(value_seconds)
  if not number then
    return nil, err
  end
  local amount, unit
  local magnitude = math.abs(number)
  if magnitude < 0.001 then
    amount, unit = number * 1000000, "\194\181s"
  elseif magnitude < 1 then
    amount, unit = number * 1000, "ms"
  elseif magnitude < 60 then
    amount, unit = number, "s"
  elseif magnitude < 3600 then
    amount, unit = number / 60, "min"
  elseif magnitude < 86400 then
    amount, unit = number / 3600, "h"
  else
    amount, unit = number / 86400, "d"
  end
  local number_options = copy_options(options, {
    precision = options.precision or (math.abs(amount) < 10 and 1 or 0),
  })
  local formatted, format_err = M.number(amount, number_options)
  return formatted and (formatted .. " " .. unit) or nil, format_err
end

function M.temperature(value_celsius, options)
  local options_err
  options, options_err = options_table(options)
  if not options then return nil, options_err end
  local number, err = finite_number(value_celsius)
  if not number then
    return nil, err
  end
  local unit = options.unit or "C"
  if unit == "F" then
    number = number * 9 / 5 + 32
  elseif unit ~= "C" then
    return nil, 'temperature unit must be "C" or "F"'
  end
  local formatted, format_err = M.number(number, options)
  return formatted and (formatted .. " \194\176" .. unit) or nil, format_err
end

function M.interpolate(template, variables)
  if type(template) ~= "string" then
    return nil, "template must be a string"
  end
  if #template > MAX_TEMPLATE_BYTES then
    return nil, "template exceeds configured size limit"
  end
  if template:find("[%z\1-\8\11\12\14-\31\127]") then
    return nil, "template contains forbidden control characters"
  end
  if variables == nil then
    variables = {}
  elseif type(variables) ~= "table" then
    return nil, "placeholder values must be provided in a table"
  end
  local output = {}
  local index = 1
  while index <= #template do
    local char = template:sub(index, index)
    if char == "{" and template:sub(index + 1, index + 1) == "{" then
      output[#output + 1] = "{"
      index = index + 2
    elseif char == "}" and template:sub(index + 1, index + 1) == "}" then
      output[#output + 1] = "}"
      index = index + 2
    elseif char == "{" then
      local close = template:find("}", index + 1, true)
      if not close then
        return nil, "unclosed placeholder"
      end
      local name = template:sub(index + 1, close - 1)
      if #name > MAX_PLACEHOLDER_BYTES or not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
        return nil, "invalid placeholder {" .. name .. "}"
      end
      local value = variables[name]
      if value == nil then
        return nil, "missing placeholder value: " .. name
      end
      if type(value) ~= "string" and type(value) ~= "number" and type(value) ~= "boolean" then
        return nil, "placeholder value must be a string, number or boolean: " .. name
      end
      local rendered = tostring(value)
      if type(value) == "number" and not finite_number(value) then
        return nil, "placeholder number must be finite: " .. name
      end
      if #rendered > MAX_INTERPOLATED_BYTES
          or rendered:find("[%z\1-\8\11\12\14-\31\127]") then
        return nil, "placeholder value is unsafe or too large: " .. name
      end
      output[#output + 1] = rendered
      index = close + 1
    elseif char == "}" then
      return nil, "unmatched closing brace"
    else
      output[#output + 1] = char
      index = index + 1
    end
  end
  local result = table.concat(output)
  if #result > MAX_INTERPOLATED_BYTES then
    return nil, "interpolated message exceeds configured size limit"
  end
  return result
end

function M.new(locale, defaults)
  local normalized, locale_err = Locale.normalize(locale or "en-US")
  if not normalized then return nil, locale_err end
  if defaults ~= nil and type(defaults) ~= "table" then
    return nil, "format defaults must be a table"
  end
  return setmetatable({
    locale = normalized,
    defaults = defaults or {},
  }, Formatter)
end

function Formatter:with(options)
  if options ~= nil and type(options) ~= "table" then
    return nil, "format options must be a table"
  end
  local merged, err = copy_options(self.defaults, options)
  if not merged then return nil, err end
  return M.new(options and options.locale or self.locale, merged)
end

for _, method in ipairs({
  "number",
  "integer",
  "percent",
  "bytes",
  "bits_per_second",
  "frequency",
  "duration",
  "temperature",
}) do
  Formatter[method] = function(self, value, options)
    local merged, err = copy_options(self.defaults, options)
    if not merged then return nil, err end
    merged.locale = merged.locale or self.locale
    return M[method](value, merged)
  end
end

Formatter.interpolate = function(_, template, variables)
  return M.interpolate(template, variables)
end

M.Formatter = Formatter

return M
