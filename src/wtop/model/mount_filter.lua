-- Storage mount queries. A plain query remains one literal phrase; recognized
-- fields and comparisons combine with AND before the table's row budget.
local Filter = {}

local TEXT_FIELDS = { path = true, source = true, type = true,
  kind = true, state = true }
local NUMBER_FIELDS = { used = "percent", inodes = "percent",
  avail = "bytes", available = "bytes", size = "bytes" }
local BYTE_SCALE = { b = 1, k = 1024, m = 1048576,
  g = 1073741824, t = 1099511627776 }

local function fold(value)
  return tostring(value or ""):gsub("[A-Z]", function(char)
    return string.char(char:byte() + 32)
  end)
end

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function parse_number(raw, kind)
  if type(raw) ~= "string" then return nil end
  local text, scale = fold(raw), 1
  if kind == "bytes" then
    local digits, suffix = text:match("^([%d%.]+)([bkmgt]?)$")
    if not digits then return nil end
    text = digits
    scale = BYTE_SCALE[suffix ~= "" and suffix or "b"]
  else
    text = text:gsub("%%$", "")
    if not text:match("^[%d%.]+$") then return nil end
  end
  local number = tonumber(text)
  if not finite(number) or number < 0 then return nil end
  local value = number * scale
  return finite(value) and value <= math.maxinteger and value or nil
end

local function parse_term(raw)
  local word = raw
  local negate = word:sub(1, 1) == "!"
  if negate then word = word:sub(2) end
  local field, operator, rest = word:match("^([%a]+)([<>]=?)(.+)$")
  if not field then
    field, rest = word:match("^([%a]+)=(.+)$")
    operator = "="
  end
  field = field and fold(field)
  if field and NUMBER_FIELDS[field] then
    local number = parse_number(rest, NUMBER_FIELDS[field])
    if number ~= nil then
      return { field = field, number = number, operator = operator,
        negate = negate, structured = true }
    end
  end
  field, rest = word:match("^([%a]+):(.*)$")
  field = field and fold(field)
  if field and TEXT_FIELDS[field] and rest ~= "" then
    return { field = field, text = fold(rest), negate = negate, structured = true }
  end
  if negate and word ~= "" and not word:find("[<>=:]") then
    return { text = fold(word), negate = true, structured = true }
  end
  return { text = fold(raw), negate = false, structured = false }
end

function Filter.compile(query)
  query = type(query) == "string" and query:match("^%s*(.-)%s*$") or ""
  if query == "" then return nil end
  local terms, structured = {}, false
  for raw in query:gmatch("%S+") do
    local term = parse_term(raw)
    terms[#terms + 1] = term
    structured = structured or term.structured
  end
  if not structured then return { plain = fold(query) } end
  return { terms = terms }
end

local function text_values(mount, field)
  local state
  if mount.readonly ~= nil then state = mount.readonly and "ro" or "rw" end
  if field == "path" then return { mount.mount_point } end
  if field == "source" then return { mount.source } end
  if field == "type" then return { mount.fs_type } end
  if field == "kind" then return { mount.kind } end
  if field == "state" then return { state } end
  return { mount.mount_point, mount.source, mount.fs_type, mount.kind, state }
end

local function text_matches(mount, field, text)
  local present = false
  for _, value in pairs(text_values(mount, field)) do
    if value ~= nil then
      present = true
      if fold(value):find(text, 1, true) then return true end
    end
  end
  if present then return false end
  return nil
end

local function numeric_value(mount, field)
  local value
  if field == "inodes" then
    value = type(mount.inodes) == "table" and mount.inodes.used_percent
  else
    local capacity = type(mount.capacity) == "table" and mount.capacity
    if field == "used" then value = capacity and capacity.used_percent
    elseif field == "avail" or field == "available" then
      value = capacity and capacity.available_bytes
    elseif field == "size" then value = capacity and capacity.total_bytes end
  end
  return finite(value) and value >= 0 and value or nil
end

local function compare(value, operator, expected)
  if value == nil then return nil end
  if operator == ">" then return value > expected end
  if operator == ">=" then return value >= expected end
  if operator == "<" then return value < expected end
  if operator == "<=" then return value <= expected end
  return value == expected
end

function Filter.matches(compiled, mount)
  if not compiled then return true end
  if compiled.plain then return text_matches(mount, nil, compiled.plain) == true end
  for _, term in ipairs(compiled.terms) do
    local matched
    if term.number ~= nil then
      matched = compare(numeric_value(mount, term.field), term.operator, term.number)
    else
      matched = text_matches(mount, term.field, term.text)
    end
    if matched == nil or matched == term.negate then return false end
  end
  return true
end

return Filter
