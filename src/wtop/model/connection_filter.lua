-- Network table queries. Plain text keeps its original whole-phrase meaning;
-- recognized field terms opt into whitespace-separated AND conditions.
local Filter = {}

local TEXT_FIELDS = {
  proto = true, family = true, state = true,
  local_endpoint = true, remote = true, owner = true,
}
local FIELD_ALIASES = { ["local"] = "local_endpoint", protocol = "proto" }
local NUMBER_FIELDS = { pid = true, uid = true, lport = true, rport = true,
  queue = true, tx = true, rx = true }
local COMPARABLE = { queue = true, tx = true, rx = true }

local function fold(value)
  return tostring(value or ""):gsub("[A-Z]", function(char)
    return string.char(char:byte() + 32)
  end)
end

local function nonnegative_integer(value)
  local number = tonumber(value)
  return number and math.type(number) == "integer" and number >= 0
    and number <= math.maxinteger and number or nil
end

local function term_for(raw)
  local word = raw
  local negate = word:sub(1, 1) == "!"
  if negate then word = word:sub(2) end
  local name, value = word:match("^([%a]+):(.*)$")
  if name then
    name = FIELD_ALIASES[fold(name)] or fold(name)
    if TEXT_FIELDS[name] and value ~= "" then
      return { field = name, text = fold(value), negate = negate, structured = true }
    end
    if NUMBER_FIELDS[name] then
      local number = nonnegative_integer(value)
      if number then
        return { field = name, number = number, operator = "=",
          negate = negate, structured = true }
      end
    end
  end
  local field, operator, number_text = word:match("^([%a]+)([<>]=?)(%d+)$")
  if not field then
    field, number_text = word:match("^([%a]+)=(%d+)$")
    operator = "="
  end
  field = field and fold(field)
  if field and COMPARABLE[field] then
    local number = nonnegative_integer(number_text)
    if number then
      return { field = field, number = number, operator = operator,
        negate = negate, structured = true }
    end
  end
  -- Invalid or unknown expressions remain literal. This follows the process
  -- search's refusal to turn an unreadable numeric condition into zero.
  return { text = fold(raw), structured = false }
end

function Filter.compile(query)
  query = type(query) == "string" and query:match("^%s*(.-)%s*$") or ""
  if query == "" then return nil end
  local terms, structured = {}, false
  for raw in query:gmatch("%S+") do
    local term = term_for(raw)
    terms[#terms + 1] = term
    structured = structured or term.structured
  end
  if not structured then return { plain = fold(query) } end
  return { terms = terms }
end

local function owner_matches(connection, text)
  for _, owner in ipairs(connection.owners or {}) do
    if fold((owner.name or "?") .. "(" .. tostring(owner.pid or "?") .. ")")
        :find(text, 1, true) then return true end
  end
  return false
end

local function any_matches(connection, remote, text)
  local fields = {
    connection.protocol or connection.table or "?",
    connection.local_endpoint and connection.local_endpoint.text or connection.path or "—",
    remote,
    connection.state or "—",
    tostring((connection.tx_queue or 0) + (connection.rx_queue or 0)),
    connection.uid and tostring(connection.uid) or "—",
  }
  for _, value in ipairs(fields) do
    if fold(value):find(text, 1, true) then return true end
  end
  return owner_matches(connection, text)
end

local function numeric_value(connection, field)
  if field == "pid" then return nil end -- tested against each owner below
  if field == "uid" then return nonnegative_integer(connection.uid) end
  if field == "lport" then return nonnegative_integer(connection.local_port) end
  if field == "rport" then return nonnegative_integer(connection.remote_port) end
  if field == "tx" then return nonnegative_integer(connection.tx_queue) end
  if field == "rx" then return nonnegative_integer(connection.rx_queue) end
  if field == "queue" then
    local tx = nonnegative_integer(connection.tx_queue)
    local rx = nonnegative_integer(connection.rx_queue)
    return tx and rx and tx <= math.maxinteger - rx and tx + rx or nil
  end
  return nil
end

local function compare(value, operator, expected)
  if value == nil then return nil end
  if operator == ">" then return value > expected end
  if operator == ">=" then return value >= expected end
  if operator == "<" then return value < expected end
  if operator == "<=" then return value <= expected end
  return value == expected
end

local function term_matches(connection, remote, term)
  if term.number then
    if term.field == "pid" then
      for _, owner in ipairs(connection.owners or {}) do
        if nonnegative_integer(owner.pid) == term.number then return true end
      end
      if connection.owners_quality == "fresh" then return false end
      return nil
    end
    return compare(numeric_value(connection, term.field), term.operator, term.number)
  end
  local field = term.field
  if field == "proto" then
    if connection.protocol == nil and connection.table == nil then return nil end
    return fold(connection.protocol):find(term.text, 1, true) ~= nil
      or fold(connection.table):find(term.text, 1, true) ~= nil
  elseif field == "family" then
    if connection.family == nil then return nil end
    return fold(connection.family):find(term.text, 1, true) ~= nil
  elseif field == "state" then
    if connection.state == nil then return nil end
    return fold(connection.state):find(term.text, 1, true) ~= nil
  elseif field == "local_endpoint" then
    if connection.local_endpoint == nil and connection.path == nil then return nil end
    return fold(connection.local_endpoint and connection.local_endpoint.text
      or connection.path):find(term.text, 1, true) ~= nil
  elseif field == "remote" then
    if connection.remote_endpoint == nil then return nil end
    return fold(remote):find(term.text, 1, true) ~= nil
  elseif field == "owner" then
    if owner_matches(connection, term.text) then return true end
    if connection.owners_quality == "fresh" then return false end
    return nil
  end
  return any_matches(connection, remote, term.text)
end

function Filter.matches(compiled, connection, remote)
  if not compiled then return true end
  if compiled.plain then return any_matches(connection, remote, compiled.plain) end
  for _, term in ipairs(compiled.terms) do
    local matched = term_matches(connection, remote, term)
    if matched == nil or matched == term.negate then return false end
  end
  return true
end

return Filter
