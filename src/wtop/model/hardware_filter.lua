-- Search the shared device graph without reading hidden identity fields.
local Filter = {}

local FIELDS = {
  bus = true, id = true, name = true, class = true,
  driver = true, vendor = true, model = true,
}

local function fold(value)
  return tostring(value or ""):gsub("[A-Z]", function(char)
    return string.char(char:byte() + 32)
  end)
end

local function field_values(node, row, field)
  local device = type(node.device) == "table" and node.device or {}
  local identity = type(device.identity) == "table" and device.identity or {}
  if field == "bus" then return { row.bus } end
  if field == "id" then return { row.id, node.id, node.identifier } end
  if field == "name" then return { row.device } end
  if field == "class" then return { row.class } end
  if field == "driver" then return { device.driver, identity.driver } end
  if field == "vendor" then return { device.vendor_name, device.manufacturer } end
  if field == "model" then
    return { device.device_name, device.product, device.part_number, identity.model }
  end
  return { row.bus, row.id, node.id, node.identifier, row.device, row.class,
    device.driver, identity.driver, device.vendor_name, device.manufacturer,
    device.device_name, device.product, device.part_number, identity.model }
end

local function contains(values, text)
  local present = false
  for _, value in pairs(values) do
    if value ~= nil then
      present = true
      if fold(value):find(text, 1, true) then return true end
    end
  end
  if present then return false end
  return nil
end

local function parse_term(raw)
  local word = raw
  local negate = word:sub(1, 1) == "!"
  if negate then word = word:sub(2) end
  local field, value = word:match("^([%a]+):(.*)$")
  field = field and fold(field)
  if field and FIELDS[field] and value ~= "" then
    return { field = field, text = fold(value), negate = negate, structured = true }
  end
  if negate and word ~= "" and not word:find(":", 1, true) then
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

function Filter.matches(compiled, node, row)
  if not compiled then return true end
  if compiled.plain then
    return contains(field_values(node, row), compiled.plain) == true
  end
  for _, term in ipairs(compiled.terms) do
    local matched = contains(field_values(node, row, term.field), term.text)
    if matched == nil or matched == term.negate then return false end
  end
  return true
end

function Filter.select(graph, query, row_for)
  local compiled = Filter.compile(query)
  if not compiled then return nil, nil, 0, nil end
  local direct, included, rows_by_id = {}, {}, {}
  local direct_count = 0
  for _, node in ipairs(graph.nodes or {}) do
    local row = row_for(node)
    rows_by_id[node.id] = row
    if Filter.matches(compiled, node, row) then
      direct[node.id] = true
      direct_count = direct_count + 1
      local cursor, seen = node, {}
      for _ = 1, 128 do
        if seen[cursor.id] then break end
        seen[cursor.id] = true
        included[cursor.id] = true
        cursor = cursor.parent_id and graph.by_id[cursor.parent_id] or nil
        if not cursor then break end
      end
    end
  end
  return included, direct, direct_count, rows_by_id
end

return Filter
