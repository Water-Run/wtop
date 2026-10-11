-- Workloads queries. Plain text keeps its whole-phrase meaning; field terms
-- combine with AND, including numeric comparisons on the values in the table.
local Filter = {}

local TEXT_FIELDS = {
  name = true, path = true, unit = true, container = true, pod = true,
}
local NUMBER_FIELDS = {
  cpu = "cpu", mem = "bytes", memory = "bytes",
  read = "bytes", write = "bytes",
  procs = "count", processes = "count", threads = "count",
  pressure = "cpu",
}
local BYTE_SCALE = {
  b = 1, k = 1024, m = 1048576, g = 1073741824, t = 1099511627776,
}

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
  local text = fold(raw)
  local scale = 1
  if kind == "bytes" then
    local digits, suffix = text:match("^([%d%.]+)([bkmgt]?)$")
    if not digits then return nil end
    text = digits
    scale = BYTE_SCALE[suffix ~= "" and suffix or "b"]
  elseif kind == "cpu" then
    text = text:gsub("%%$", "")
    if not text:match("^[%d%.]+$") then return nil end
  elseif not text:match("^%d+$") then
    return nil
  end
  local number = tonumber(text)
  if not finite(number) or number < 0 then return nil end
  if kind == "count" and (math.type(number) ~= "integer"
      or number > math.maxinteger) then return nil end
  local result = number * scale
  return finite(result) and result <= math.maxinteger and result or nil
end

local function parse_term(raw)
  local word = raw
  local negate = word:sub(1, 1) == "!"
  if negate then word = word:sub(2) end
  local name, operator, value = word:match("^([%a]+)([<>]=?)(.+)$")
  if not name then
    name, value = word:match("^([%a]+)=(.+)$")
    operator = "="
  end
  name = name and fold(name)
  if name and NUMBER_FIELDS[name] then
    local number = parse_number(value, NUMBER_FIELDS[name])
    if number ~= nil then
      return { field = name, number = number, operator = operator,
        negate = negate, structured = true }
    end
  end
  name, value = word:match("^([%a]+):(.*)$")
  name = name and fold(name)
  if name and TEXT_FIELDS[name] and value ~= "" then
    return { field = name, text = fold(value),
      negate = negate, structured = true }
  end
  if negate and word ~= "" and not word:find("[<>=:]") then
    return { text = fold(word), negate = true, structured = true }
  end
  -- A malformed comparison is searched literally, never coerced to zero.
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

local function numeric_value(workload, field)
  local value
  if field == "cpu" then
    value = type(workload.cpu) == "table" and workload.cpu.utilization_percent
  elseif field == "mem" or field == "memory" then
    value = type(workload.memory) == "table" and workload.memory.current_bytes
  elseif field == "read" or field == "write" then
    local io = type(workload.io) == "table" and workload.io
    local totals = io and type(io.totals) == "table" and io.totals
    local rates = totals and type(totals.rates) == "table" and totals.rates
    value = rates and rates[field == "read" and "rbytes_per_second"
      or "wbytes_per_second"]
  elseif field == "procs" or field == "processes" then
    value = type(workload.processes) == "table" and workload.processes.count
  elseif field == "threads" then
    value = type(workload.threads) == "table" and workload.threads.count
  elseif field == "pressure" then
    local pressure = type(workload.pressure) == "table" and workload.pressure
    local cpu = pressure and type(pressure.cpu) == "table" and pressure.cpu
    local some = cpu and type(cpu.some) == "table" and cpu.some
    value = some and some.avg10
  end
  return finite(value) and value >= 0 and value or nil
end

local function text_values(workload, field)
  local semantics = type(workload.semantics) == "table" and workload.semantics or {}
  local name = workload.name or workload.id
  if field == "name" then return { name, semantics.label } end
  if field == "path" then return { workload.id, workload.path } end
  if field == "unit" then return { semantics.unit } end
  if field == "container" then
    return { semantics.container_id, semantics.container_short_id }
  end
  if field == "pod" then return { semantics.pod } end
  return { name, workload.id, workload.path, semantics.label, semantics.unit,
    semantics.container_id, semantics.container_short_id, semantics.pod }
end

local function text_matches(workload, field, text)
  for _, value in pairs(text_values(workload, field)) do
    if type(value) == "string" and fold(value):find(text, 1, true) then
      return true
    end
  end
  return false
end

local function compare(value, operator, expected)
  if value == nil then return nil end
  if operator == ">" then return value > expected end
  if operator == ">=" then return value >= expected end
  if operator == "<" then return value < expected end
  if operator == "<=" then return value <= expected end
  return value == expected
end

function Filter.matches(compiled, workload)
  if not compiled then return true end
  if compiled.plain then return text_matches(workload, nil, compiled.plain) end
  for _, term in ipairs(compiled.terms) do
    local matched
    if term.number ~= nil then
      matched = compare(numeric_value(workload, term.field), term.operator, term.number)
    else
      matched = text_matches(workload, term.field, term.text)
    end
    if matched == nil or matched == term.negate then return false end
  end
  return true
end

return Filter
