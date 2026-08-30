local M = {}

local variants = {"full", "compact", "spark", "value"}
local variant_set = {full = true, compact = true, spark = true, value = true}
local MAX_NODES = 4095
local MAX_DEPTH = 128
local MAX_ID_BYTES = 256
local MAX_KIND_BYTES = 64
local MAX_DIMENSION = 10000
local MAX_GAP = 16

local function copy(source)
  if source == nil then return {} end
  if type(source) ~= "table" then error("layout options must be a table", 3) end
  local result = {}
  for key, value in pairs(source) do
    result[key] = value
  end
  return result
end

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function safe_identifier(value, maximum)
  return type(value) == "string" and #value >= 1 and #value <= maximum
    and value:match("^[A-Za-z0-9][A-Za-z0-9_.:%-]*$") ~= nil
end

local function dimension(value, fallback, name)
  value = value == nil and fallback or value
  if not finite(value) or value % 1 ~= 0 or value < 1 or value > MAX_DIMENSION then
    error(name .. " must be an integer in 1.." .. MAX_DIMENSION, 3)
  end
  return value
end

local function normalise_forms(options)
  if type(options) ~= "table" then error("widget options must be a table", 3) end
  if options.forms ~= nil and type(options.forms) ~= "table" then
    error("widget forms must be a table", 3)
  end
  local forms = copy(options.forms)
  local full_width = dimension(options.min_width, 30, "min_width")
  local full_height = dimension(options.min_height, 8, "min_height")
  forms.full = copy(forms.full or {min_width = full_width, min_height = full_height})
  forms.compact = copy(forms.compact or {
    min_width = options.compact_min_width or math.min(full_width, 22),
    min_height = options.compact_min_height or math.min(full_height, 5),
  })
  forms.spark = copy(forms.spark or {
    min_width = options.spark_min_width or math.min(full_width, 14),
    min_height = options.spark_min_height or math.min(full_height, 3),
  })
  forms.value = copy(forms.value or {
    min_width = options.value_min_width or math.min(full_width, 8),
    min_height = options.value_min_height or 1,
  })
  for _, name in ipairs(variants) do
    if type(forms[name]) ~= "table" then error("widget form " .. name .. " must be a table", 3) end
    forms[name].min_width = dimension(forms[name].min_width, 1, name .. ".min_width")
    forms[name].min_height = dimension(forms[name].min_height, 1, name .. ".min_height")
  end
  return forms
end

function M.widget(specification, kind, options)
  local spec
  if type(specification) == "table" then
    spec = copy(specification)
  else
    spec = copy(options)
    spec.id = specification
    spec.kind = kind
  end
  assert(safe_identifier(spec.id, MAX_ID_BYTES), "widget requires a safe stable id")
  spec.type = "widget"
  spec.kind = spec.kind or "text"
  assert(safe_identifier(spec.kind, MAX_KIND_BYTES), "widget kind must be a safe identifier")
  spec.priority = spec.priority == nil and 0 or spec.priority
  assert(finite(spec.priority), "widget priority must be finite")
  if spec.preferred_variant ~= nil then
    assert(variant_set[spec.preferred_variant], "unknown preferred widget variant")
  end
  spec.forms = normalise_forms(spec)
  return spec
end

function M.split(axis, ratio, first, second, options)
  options = copy(options)
  assert(axis == "row" or axis == "column", "split axis must be row or column")
  assert(type(first) == "table" and type(second) == "table", "split requires two children")
  ratio = ratio == nil and 0.5 or ratio
  assert(finite(ratio) and ratio > 0 and ratio < 1, "split ratio must be finite and between zero and one")
  options.type = "split"
  options.axis = axis
  options.ratio = math.max(0.05, math.min(0.95, ratio))
  options.first = first
  options.second = second
  local gap = options.gap == nil and 1 or options.gap
  assert(finite(gap) and gap % 1 == 0 and gap >= 0 and gap <= MAX_GAP,
    "split gap must be an integer in 0.." .. MAX_GAP)
  options.gap = gap
  if options.axes ~= nil then
    assert(type(options.axes) == "table", "responsive split axes must be a table")
    for mode, responsive_axis in pairs(options.axes) do
      assert(type(mode) == "string" and (responsive_axis == "row" or responsive_axis == "column"),
        "responsive split axis must be row or column")
    end
  end
  options.id = options.id or ("split:" .. tostring(first.id) .. ":" .. tostring(second.id))
  return options
end

function M.flow(children, options)
  options = copy(options)
  assert(type(children) == "table" and #children > 0 and #children <= MAX_NODES,
    "flow requires a bounded child array")
  local child_copy = {}
  for index = 1, #children do
    assert(type(children[index]) == "table", "flow children must be nodes")
    child_copy[index] = children[index]
  end
  for key in pairs(children) do
    assert(type(key) == "number" and key >= 1 and key <= #children and key % 1 == 0,
      "flow children must be a dense array")
  end
  options.type = "flow"
  options.children = child_copy
  local gap = options.gap == nil and 1 or options.gap
  assert(finite(gap) and gap % 1 == 0 and gap >= 0 and gap <= MAX_GAP,
    "flow gap must be an integer in 0.." .. MAX_GAP)
  options.gap = gap
  options.id = options.id or "flow"
  return options
end

function M.walk(node, visitor)
  assert(type(visitor) == "function", "layout visitor must be a function")
  local stack, seen, count = {node}, {}, 0
  while #stack > 0 do
    local current = table.remove(stack)
    assert(type(current) == "table" and not seen[current], "layout tree contains a cycle or shared node")
    seen[current] = true
    count = count + 1
    assert(count <= MAX_NODES, "layout tree exceeds node limit")
    visitor(current)
    if current.type == "split" then
      stack[#stack + 1] = current.second
      stack[#stack + 1] = current.first
    elseif current.type == "flow" then
      for index = #current.children, 1, -1 do stack[#stack + 1] = current.children[index] end
    end
  end
end

function M.find(node, id)
  local found
  M.walk(node, function(current)
    if not found and current.id == id then
      found = current
    end
  end)
  return found
end

function M.validate(node)
  local ids, visiting, visited = {}, {}, {}
  local nodes = 0
  local function visit(current, path)
    if type(current) ~= "table" then
      return nil, path .. " must be a node"
    end
    if visiting[current] then return nil, path .. " contains a cycle" end
    if visited[current] then return nil, path .. " contains a shared node" end
    nodes = nodes + 1
    if nodes > MAX_NODES then return nil, "layout exceeds node limit" end
    local depth = 1
    for _ in path:gmatch("%.") do depth = depth + 1 end
    if depth > MAX_DEPTH then return nil, "layout exceeds depth limit" end
    visiting[current] = true
    if current.type == "widget" then
      if not safe_identifier(current.id, MAX_ID_BYTES) then
        return nil, path .. " widget has no id"
      end
      if not safe_identifier(current.kind, MAX_KIND_BYTES) then
        return nil, path .. " widget has an invalid kind"
      end
      if not finite(current.priority) then return nil, path .. " widget has an invalid priority" end
      if type(current.forms) ~= "table" then return nil, path .. " widget has no forms" end
      for _, name in ipairs(variants) do
        local form = current.forms[name]
        if type(form) ~= "table" or not finite(form.min_width) or form.min_width % 1 ~= 0
            or form.min_width < 1 or form.min_width > MAX_DIMENSION
            or not finite(form.min_height) or form.min_height % 1 ~= 0
            or form.min_height < 1 or form.min_height > MAX_DIMENSION then
          return nil, path .. " widget has an invalid " .. name .. " form"
        end
      end
      if ids[current.id] then
        return nil, path .. " duplicates widget id " .. current.id
      end
      ids[current.id] = true
    elseif current.type == "split" then
      if current.axis ~= "row" and current.axis ~= "column" then
        return nil, path .. " has an invalid split axis"
      end
      if not finite(current.ratio) or current.ratio <= 0 or current.ratio >= 1 then
        return nil, path .. " has an invalid split ratio"
      end
      if not finite(current.gap) or current.gap % 1 ~= 0
          or current.gap < 0 or current.gap > MAX_GAP then
        return nil, path .. " has an invalid split gap"
      end
      if type(current.first) ~= "table" or type(current.second) ~= "table" then
        return nil, path .. " split requires two children"
      end
      local ok, reason = visit(current.first, path .. ".first")
      if not ok then return nil, reason end
      ok, reason = visit(current.second, path .. ".second")
      if not ok then return nil, reason end
    elseif current.type == "flow" then
      if type(current.children) ~= "table" or #current.children == 0 then
        return nil, path .. " flow has no children"
      end
      if not finite(current.gap) or current.gap % 1 ~= 0
          or current.gap < 0 or current.gap > MAX_GAP then
        return nil, path .. " has an invalid flow gap"
      end
      local count = 0
      for key in pairs(current.children) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
          return nil, path .. " flow children must be a dense array"
        end
        count = count + 1
      end
      if count ~= #current.children then return nil, path .. " flow children have holes" end
      for index, child in ipairs(current.children) do
        local ok, reason = visit(child, path .. ".children[" .. index .. "]")
        if not ok then return nil, reason end
      end
    else
      return nil, path .. " has unknown node type " .. tostring(current.type)
    end
    visiting[current] = nil
    visited[current] = true
    return true
  end
  return visit(node, "root")
end

M.variants = variants
M.MAX_NODES = MAX_NODES
M.MAX_DEPTH = MAX_DEPTH

return M
