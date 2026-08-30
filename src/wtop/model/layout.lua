local JSONDecode = require("wtop.core.json")
local JSONEncode = require("wtop.format.json")

local Layout = {}

local SCHEMA_VERSION = 1
local DEFAULT_MAX_DEPTH = 32
local DEFAULT_MAX_NODES = 511
local DEFAULT_MAX_BYTES = 1024 * 1024
local HARD_MAX_DEPTH = 128
local HARD_MAX_NODES = 4095
local HARD_MAX_BYTES = 16 * 1024 * 1024
local MAX_VIEWPORT_DIMENSION = 1000000
local MAX_WIDGET_ID_BYTES = 128
local DEFAULT_GAP = 1
local MAX_GAP = 16

local AXES = { horizontal = true, vertical = true }

local function finite_number(value)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  return value
end

local function positive_integer(value, fallback)
  if value == nil then return fallback end
  if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then return nil end
  return value
end

local function nonnegative_integer(value, fallback)
  if value == nil then return fallback end
  if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then return nil end
  return value
end

local function valid_widget_id(value)
  return type(value) == "string"
    and #value >= 1
    and #value <= MAX_WIDGET_ID_BYTES
    and value:match("^[A-Za-z0-9][A-Za-z0-9_.:%-]*$") ~= nil
end

local function dense_array(value)
  if type(value) ~= "table" or getmetatable(value) ~= nil then return nil end
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return nil end
    count = count + 1
    if key > maximum then maximum = key end
  end
  if count ~= maximum then return nil end
  return maximum
end

local function allowed_widgets(value)
  if value == nil then return nil, nil end
  if type(value) ~= "table" or getmetatable(value) ~= nil then
    return nil, nil, "allowed_widgets_must_be_table"
  end
  local numeric, textual = false, false
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) == "number" and key >= 1 and key % 1 == 0 then
      numeric = true
      count = count + 1
      maximum = math.max(maximum, key)
    elseif type(key) == "string" then
      textual = true
    else
      return nil, nil, "allowed_widgets_has_invalid_key"
    end
  end
  if numeric and textual then return nil, nil, "allowed_widgets_mixed_shape" end

  local set, order = {}, {}
  if numeric then
    if count ~= maximum then return nil, nil, "allowed_widgets_has_holes" end
    for index = 1, maximum do
      local item = value[index]
      local id = type(item) == "table" and (item.id or item.widget_id) or item
      if not valid_widget_id(id) then return nil, nil, "allowed_widgets_has_invalid_id" end
      if set[id] then return nil, nil, "allowed_widgets_duplicates_" .. id end
      set[id] = true
      order[#order + 1] = id
    end
  else
    for id, specification in pairs(value) do
      if not valid_widget_id(id) then return nil, nil, "allowed_widgets_has_invalid_id" end
      if specification ~= false then
        set[id] = true
        order[#order + 1] = id
      end
    end
    table.sort(order)
  end
  return set, order
end

local function unknown_key(node, accepted)
  for key in pairs(node) do
    if not accepted[key] then return key end
  end
  return nil
end

function Layout.validate(tree, options)
  options = options or {}
  if type(options) ~= "table" then return nil, "options_must_be_table" end
  local max_depth = positive_integer(options.max_depth, DEFAULT_MAX_DEPTH)
  local max_nodes = positive_integer(options.max_nodes, DEFAULT_MAX_NODES)
  if not max_depth or max_depth > HARD_MAX_DEPTH then return nil, "invalid_max_depth" end
  if not max_nodes or max_nodes > HARD_MAX_NODES then return nil, "invalid_max_nodes" end
  local allowed, _, allowed_error = allowed_widgets(options.allowed_widgets or options.widgets)
  if allowed_error then return nil, allowed_error end

  local visiting, visited, widget_ids = {}, {}, {}
  local order = {}
  local node_count = 0
  local function visit(node, depth, path)
    if type(node) ~= "table" or getmetatable(node) ~= nil then
      return nil, path .. ":node_required"
    end
    if visiting[node] then return nil, path .. ":cycle" end
    if visited[node] then return nil, path .. ":shared_node" end
    node_count = node_count + 1
    if node_count > max_nodes then return nil, "node_limit_exceeded" end
    if depth > max_depth then return nil, "depth_limit_exceeded" end
    visiting[node] = true

    if node.type == "leaf" then
      local extra = unknown_key(node, { type = true, widget_id = true })
      if extra ~= nil then return nil, path .. ":unknown_leaf_key:" .. tostring(extra) end
      if not valid_widget_id(node.widget_id) then return nil, path .. ":invalid_widget_id" end
      if allowed and not allowed[node.widget_id] then
        return nil, path .. ":unknown_widget:" .. node.widget_id
      end
      if widget_ids[node.widget_id] then
        return nil, path .. ":duplicate_widget:" .. node.widget_id
      end
      widget_ids[node.widget_id] = true
      order[#order + 1] = node.widget_id
    elseif node.type == "split" then
      local extra = unknown_key(node, {
        type = true, axis = true, ratio = true, gap = true, children = true,
      })
      if extra ~= nil then return nil, path .. ":unknown_split_key:" .. tostring(extra) end
      if not AXES[node.axis] then return nil, path .. ":invalid_axis" end
      local ratio = finite_number(node.ratio)
      if not ratio or ratio <= 0 or ratio >= 1 then return nil, path .. ":invalid_ratio" end
      local gap = nonnegative_integer(node.gap, nil)
      if gap == nil or gap > MAX_GAP then return nil, path .. ":invalid_gap" end
      if dense_array(node.children) ~= 2 then return nil, path .. ":two_children_required" end
      local first_ok, first_error = visit(node.children[1], depth + 1, path .. ".children[1]")
      if not first_ok then return nil, first_error end
      local second_ok, second_error = visit(node.children[2], depth + 1, path .. ".children[2]")
      if not second_ok then return nil, second_error end
    else
      return nil, path .. ":unknown_node_type:" .. tostring(node.type)
    end

    visiting[node] = nil
    visited[node] = true
    return true
  end

  local ok, reason = visit(tree, 1, "root")
  if not ok then return nil, reason end
  return true, {
    nodes = node_count,
    widgets = #order,
    order = order,
  }
end

local function copy_node(node)
  if node.type == "leaf" then
    return { type = "leaf", widget_id = node.widget_id }
  end
  return {
    type = "split",
    axis = node.axis,
    ratio = node.ratio,
    gap = node.gap,
    children = { copy_node(node.children[1]), copy_node(node.children[2]) },
  }
end

local function validated_copy(tree, options)
  local valid, info_or_error = Layout.validate(tree, options)
  if not valid then return nil, info_or_error end
  return copy_node(tree), info_or_error
end

function Layout.leaf(widget_id)
  if not valid_widget_id(widget_id) then return nil, "invalid_widget_id" end
  return { type = "leaf", widget_id = widget_id }
end

function Layout.split(axis, ratio, children, options)
  options = options or {}
  if type(options) ~= "table" then return nil, "options_must_be_table" end
  if not AXES[axis] then return nil, "invalid_axis" end
  ratio = finite_number(ratio)
  if not ratio or ratio <= 0 or ratio >= 1 then return nil, "invalid_ratio" end
  local gap = nonnegative_integer(options.gap, DEFAULT_GAP)
  if not gap or gap > MAX_GAP then return nil, "invalid_gap" end
  if dense_array(children) ~= 2 then return nil, "two_children_required" end
  local candidate = {
    type = "split",
    axis = axis,
    ratio = ratio,
    gap = gap,
    children = { children[1], children[2] },
  }
  local copied, validation_error = validated_copy(candidate, options)
  if not copied then return nil, validation_error end
  return copied
end

function Layout.clone(tree, options)
  return validated_copy(tree, options)
end

Layout.from_table = Layout.clone

function Layout.to_table(tree, options)
  return validated_copy(tree, options)
end

local function validate_order(order)
  local length = dense_array(order)
  if length == nil then return nil, "order_must_be_dense_array" end
  if length == 0 then return nil, "order_must_not_be_empty" end
  return length
end

function Layout.from_order(order, options)
  options = options or {}
  if type(options) ~= "table" then return nil, "options_must_be_table" end
  local length, order_error = validate_order(order)
  if not length then return nil, order_error end
  local allowed, allowed_order, allowed_error = allowed_widgets(options.allowed_widgets or options.widgets)
  if allowed_error then return nil, allowed_error end
  local ids, seen = {}, {}
  for index = 1, length do
    local id = order[index]
    if not valid_widget_id(id) then return nil, "invalid_widget_in_order:" .. tostring(index) end
    if allowed and not allowed[id] then return nil, "unknown_widget_in_order:" .. id end
    if seen[id] then return nil, "duplicate_widget_in_order:" .. id end
    seen[id] = true
    ids[#ids + 1] = id
  end
  if options.append_missing then
    if not allowed then return nil, "append_missing_requires_allowed_widgets" end
    for _, id in ipairs(allowed_order) do
      if not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
      end
    end
  end

  -- Enforce construction limits before allocating the binary tree. A valid
  -- full binary tree with N leaves has exactly 2N-1 nodes.
  local max_nodes = positive_integer(options.max_nodes, DEFAULT_MAX_NODES)
  local max_depth = positive_integer(options.max_depth, DEFAULT_MAX_DEPTH)
  if not max_nodes or max_nodes > HARD_MAX_NODES then return nil, "invalid_max_nodes" end
  if not max_depth or max_depth > HARD_MAX_DEPTH then return nil, "invalid_max_depth" end
  if #ids * 2 - 1 > max_nodes then return nil, "node_limit_exceeded" end

  local initial_axis = options.axis or "vertical"
  if not AXES[initial_axis] then return nil, "invalid_axis" end
  local gap = nonnegative_integer(options.gap, DEFAULT_GAP)
  if not gap or gap > MAX_GAP then return nil, "invalid_gap" end
  local function build(first, last, axis)
    if first == last then return { type = "leaf", widget_id = ids[first] } end
    local count = last - first + 1
    local left_count = math.ceil(count / 2)
    local middle = first + left_count - 1
    local child_axis = axis
    if options.alternate_axes then
      child_axis = axis == "horizontal" and "vertical" or "horizontal"
    end
    return {
      type = "split",
      axis = axis,
      ratio = left_count / count,
      gap = gap,
      children = {
        build(first, middle, child_axis),
        build(middle + 1, last, child_axis),
      },
    }
  end
  local tree = build(1, #ids, initial_axis)
  local valid, validation_error = Layout.validate(tree, options)
  if not valid then return nil, validation_error end
  return tree
end

function Layout.to_order(tree, options)
  local valid, info_or_error = Layout.validate(tree, options)
  if not valid then return nil, info_or_error end
  local order = {}
  for index, id in ipairs(info_or_error.order) do order[index] = id end
  return order
end

local function find_path_unchecked(node, widget_id, path)
  if node.type == "leaf" then
    if node.widget_id == widget_id then
      local result = {}
      for index, value in ipairs(path) do result[index] = value end
      return result
    end
    return nil
  end
  path[#path + 1] = 1
  local found = find_path_unchecked(node.children[1], widget_id, path)
  if found then path[#path] = nil; return found end
  path[#path] = 2
  found = find_path_unchecked(node.children[2], widget_id, path)
  path[#path] = nil
  return found
end

function Layout.find_path(tree, widget_id, options)
  if not valid_widget_id(widget_id) then return nil, "invalid_widget_id" end
  local valid, validation_error = Layout.validate(tree, options)
  if not valid then return nil, validation_error end
  local path = find_path_unchecked(tree, widget_id, {})
  if not path then return nil, "widget_not_found:" .. widget_id end
  return path
end

local function position_options(options)
  local position = options.position or "after"
  local axis = options.axis or "vertical"
  if position == "left" then axis, position = "horizontal", "before"
  elseif position == "right" then axis, position = "horizontal", "after"
  elseif position == "above" then axis, position = "vertical", "before"
  elseif position == "below" then axis, position = "vertical", "after" end
  if position ~= "before" and position ~= "after" then return nil, nil, "invalid_position" end
  if not AXES[axis] then return nil, nil, "invalid_axis" end
  return axis, position
end

local function contains_widget(node, widget_id)
  if node.type == "leaf" then return node.widget_id == widget_id end
  return contains_widget(node.children[1], widget_id) or contains_widget(node.children[2], widget_id)
end

function Layout.insert(tree, target_widget, widget_id, options)
  options = options or {}
  if type(options) ~= "table" then return nil, "options_must_be_table" end
  if not valid_widget_id(target_widget) then return nil, "invalid_target_widget" end
  if not valid_widget_id(widget_id) then return nil, "invalid_widget_id" end
  local working, validation_error = validated_copy(tree, options)
  if not working then return nil, validation_error end
  if not contains_widget(working, target_widget) then return nil, "widget_not_found:" .. target_widget end
  if contains_widget(working, widget_id) then return nil, "duplicate_widget:" .. widget_id end
  local allowed, _, allowed_error = allowed_widgets(options.allowed_widgets or options.widgets)
  if allowed_error then return nil, allowed_error end
  if allowed and not allowed[widget_id] then return nil, "unknown_widget:" .. widget_id end
  local axis, position, position_error = position_options(options)
  if not axis then return nil, position_error end
  local ratio = finite_number(options.ratio or 0.5)
  if not ratio or ratio <= 0 or ratio >= 1 then return nil, "invalid_ratio" end
  local gap = nonnegative_integer(options.gap, DEFAULT_GAP)
  if not gap or gap > MAX_GAP then return nil, "invalid_gap" end

  local function replace(node)
    if node.type == "leaf" then
      if node.widget_id ~= target_widget then return node, false end
      local added = { type = "leaf", widget_id = widget_id }
      local children = position == "before" and { added, node } or { node, added }
      return { type = "split", axis = axis, ratio = ratio, gap = gap, children = children }, true
    end
    local first, replaced = replace(node.children[1])
    if replaced then node.children[1] = first; return node, true end
    local second
    second, replaced = replace(node.children[2])
    if replaced then node.children[2] = second end
    return node, replaced
  end
  working = select(1, replace(working))
  local valid, result_error = Layout.validate(working, options)
  if not valid then return nil, result_error end
  return working
end

function Layout.remove(tree, widget_id, options)
  options = options or {}
  if not valid_widget_id(widget_id) then return nil, "invalid_widget_id" end
  local working, info_or_error = validated_copy(tree, options)
  if not working then return nil, info_or_error end
  if not contains_widget(working, widget_id) then return nil, "widget_not_found:" .. widget_id end
  if info_or_error.widgets == 1 then return nil, "cannot_remove_last_widget" end

  local function remove_from(node)
    if node.type == "leaf" then
      if node.widget_id == widget_id then return nil, true end
      return node, false
    end
    local first, removed = remove_from(node.children[1])
    if removed then
      if first == nil then return node.children[2], true end
      node.children[1] = first
      return node, true
    end
    local second
    second, removed = remove_from(node.children[2])
    if removed then
      if second == nil then return node.children[1], true end
      node.children[2] = second
    end
    return node, removed
  end
  working = select(1, remove_from(working))
  local valid, result_error = Layout.validate(working, options)
  if not valid then return nil, result_error end
  return working
end

Layout.delete = Layout.remove

function Layout.move(tree, widget_id, target_widget, options)
  options = options or {}
  if not valid_widget_id(widget_id) then return nil, "invalid_widget_id" end
  if not valid_widget_id(target_widget) then return nil, "invalid_target_widget" end
  if widget_id == target_widget then return validated_copy(tree, options) end
  local valid, validation_error = Layout.validate(tree, options)
  if not valid then return nil, validation_error end
  if not contains_widget(tree, widget_id) then return nil, "widget_not_found:" .. widget_id end
  if not contains_widget(tree, target_widget) then return nil, "widget_not_found:" .. target_widget end
  local reduced, remove_error = Layout.remove(tree, widget_id, options)
  if not reduced then return nil, remove_error end
  return Layout.insert(reduced, target_widget, widget_id, options)
end

function Layout.swap(tree, first_widget, second_widget, options)
  options = options or {}
  if not valid_widget_id(first_widget) or not valid_widget_id(second_widget) then
    return nil, "invalid_widget_id"
  end
  local working, validation_error = validated_copy(tree, options)
  if not working then return nil, validation_error end
  if not contains_widget(working, first_widget) then return nil, "widget_not_found:" .. first_widget end
  if not contains_widget(working, second_widget) then return nil, "widget_not_found:" .. second_widget end
  if first_widget == second_widget then return working end
  local function visit(node)
    if node.type == "leaf" then
      if node.widget_id == first_widget then node.widget_id = second_widget
      elseif node.widget_id == second_widget then node.widget_id = first_widget end
      return
    end
    visit(node.children[1])
    visit(node.children[2])
  end
  visit(working)
  local valid, result_error = Layout.validate(working, options)
  if not valid then return nil, result_error end
  return working
end

local function validate_path(path)
  local length = dense_array(path)
  if length == nil then return nil, "path_must_be_dense_array" end
  for index = 1, length do
    if path[index] ~= 1 and path[index] ~= 2 then return nil, "invalid_path_step:" .. index end
  end
  return length
end

local function node_at_path(tree, path)
  local node = tree
  for _, step in ipairs(path) do
    if node.type ~= "split" then return nil, "path_enters_leaf" end
    node = node.children[step]
  end
  return node
end

function Layout.set_ratio(tree, path, ratio, options)
  options = options or {}
  local path_length, path_error = validate_path(path)
  if path_length == nil then return nil, path_error end
  ratio = finite_number(ratio)
  if not ratio or ratio <= 0 or ratio >= 1 then return nil, "invalid_ratio" end
  local working, validation_error = validated_copy(tree, options)
  if not working then return nil, validation_error end
  local node, target_error = node_at_path(working, path)
  if not node then return nil, target_error end
  if node.type ~= "split" then return nil, "ratio_target_not_split" end
  node.ratio = ratio
  local valid, result_error = Layout.validate(working, options)
  if not valid then return nil, result_error end
  return working
end

function Layout.adjust_ratio(tree, path, delta, options)
  options = options or {}
  delta = finite_number(delta)
  if not delta then return nil, "invalid_ratio_delta" end
  local path_length, path_error = validate_path(path)
  if path_length == nil then return nil, path_error end
  local valid, validation_error = Layout.validate(tree, options)
  if not valid then return nil, validation_error end
  local source_node, target_error = node_at_path(tree, path)
  if not source_node then return nil, target_error end
  if source_node.type ~= "split" then return nil, "ratio_target_not_split" end
  local minimum = finite_number(options.min_ratio or 0.05)
  local maximum = finite_number(options.max_ratio or 0.95)
  if not minimum or not maximum or minimum <= 0 or maximum >= 1 or minimum > maximum then
    return nil, "invalid_ratio_bounds"
  end
  local ratio = math.max(minimum, math.min(maximum, source_node.ratio + delta))
  return Layout.set_ratio(tree, path, ratio, options)
end

local function strict_wrapper(value)
  if type(value) ~= "table" or getmetatable(value) ~= nil then return nil, "layout_root_required" end
  for key in pairs(value) do
    if key ~= "schema_version" and key ~= "tree" then
      return nil, "unknown_layout_key:" .. tostring(key)
    end
  end
  if value.schema_version ~= SCHEMA_VERSION then
    return nil, "unsupported_schema_version:" .. tostring(value.schema_version)
  end
  if value.tree == nil then return nil, "layout_tree_required" end
  return value.tree
end

function Layout.serialize(tree, options)
  local canonical, validation_error = Layout.to_table(tree, options)
  if not canonical then return nil, validation_error end
  local ok, encoded = pcall(JSONEncode.encode, {
    schema_version = SCHEMA_VERSION,
    tree = canonical,
  })
  if not ok then return nil, tostring(encoded) end
  return encoded
end

function Layout.deserialize(text, options)
  options = options or {}
  if type(options) ~= "table" then return nil, "options_must_be_table" end
  if type(text) ~= "string" then return nil, "serialized_layout_must_be_string" end
  local max_bytes = positive_integer(options.max_bytes, DEFAULT_MAX_BYTES)
  local max_depth = positive_integer(options.max_depth, DEFAULT_MAX_DEPTH)
  if not max_bytes or max_bytes > HARD_MAX_BYTES then return nil, "invalid_max_bytes" end
  if not max_depth or max_depth > HARD_MAX_DEPTH then return nil, "invalid_max_depth" end
  local raw, decode_error = JSONDecode.decode(text, {
    max_bytes = max_bytes,
    max_depth = max_depth * 2 + 8,
  })
  if not raw then
    return nil, "invalid_json:" .. tostring(decode_error.message) .. "@" .. tostring(decode_error.position)
  end
  local tree, wrapper_error = strict_wrapper(raw)
  if not tree then return nil, wrapper_error end
  return validated_copy(tree, options)
end

local function widget_minimums(tree, specifications)
  if specifications == nil then specifications = {} end
  if type(specifications) ~= "table" or getmetatable(specifications) ~= nil then
    return nil, "min_sizes_must_be_table"
  end
  local result = {}
  local function visit(node)
    if node.type == "leaf" then
      local specification = specifications[node.widget_id] or {}
      if type(specification) ~= "table" then return nil, "invalid_min_size:" .. node.widget_id end
      local width = specification.min_width or specification.width or 1
      local height = specification.min_height or specification.height or 1
      local priority = specification.priority or 0
      if type(width) ~= "number" or width < 1 or width > MAX_VIEWPORT_DIMENSION or width % 1 ~= 0 then
        return nil, "invalid_min_width:" .. node.widget_id
      end
      if type(height) ~= "number" or height < 1 or height > MAX_VIEWPORT_DIMENSION or height % 1 ~= 0 then
        return nil, "invalid_min_height:" .. node.widget_id
      end
      priority = finite_number(priority)
      if not priority then return nil, "invalid_priority:" .. node.widget_id end
      result[node.widget_id] = { width = width, height = height, priority = priority }
      return true
    end
    local first_ok, first_error = visit(node.children[1])
    if not first_ok then return nil, first_error end
    return visit(node.children[2])
  end
  local ok, reason = visit(tree)
  if not ok then return nil, reason end
  return result
end

local function rectangle(x, y, width, height)
  return {
    x = math.floor(x),
    y = math.floor(y),
    width = math.max(0, math.floor(width)),
    height = math.max(0, math.floor(height)),
  }
end

local function append_path_step(path, step)
  if path == "root" then return "root." .. tostring(step) end
  return path .. "." .. tostring(step)
end

function Layout.solve(tree, columns, rows, min_sizes, options)
  options = options or {}
  if type(options) ~= "table" then return nil, "options_must_be_table" end
  if type(columns) ~= "number" or columns < 0 or columns > MAX_VIEWPORT_DIMENSION or columns % 1 ~= 0 then
    return nil, "invalid_viewport_columns"
  end
  if type(rows) ~= "number" or rows < 0 or rows > MAX_VIEWPORT_DIMENSION or rows % 1 ~= 0 then
    return nil, "invalid_viewport_rows"
  end
  local valid, validation_error = Layout.validate(tree, options)
  if not valid then return nil, validation_error end
  local minimums, minimum_error = widget_minimums(tree, min_sizes or options.min_sizes)
  if not minimums then return nil, minimum_error end
  local allow_stack = options.allow_stack ~= false
  local focus_widget = options.focus_widget
  local x = nonnegative_integer(options.x, 1)
  local y = nonnegative_integer(options.y, 1)
  if x == nil or y == nil or x > MAX_VIEWPORT_DIMENSION or y > MAX_VIEWPORT_DIMENSION then
    return nil, "invalid_viewport_origin"
  end

  local min_cache = {}
  local function min_size(node)
    if min_cache[node] then return min_cache[node].width, min_cache[node].height end
    local width, height
    if node.type == "leaf" then
      width, height = minimums[node.widget_id].width, minimums[node.widget_id].height
    else
      local first_width, first_height = min_size(node.children[1])
      local second_width, second_height = min_size(node.children[2])
      if node.axis == "horizontal" then
        width = first_width + node.gap + second_width
        height = math.max(first_height, second_height)
      else
        width = math.max(first_width, second_width)
        height = first_height + node.gap + second_height
      end
    end
    min_cache[node] = { width = width, height = height }
    return width, height
  end

  local priority_cache = {}
  local function priority(node)
    if priority_cache[node] then return priority_cache[node] end
    local value
    if node.type == "leaf" then
      value = minimums[node.widget_id].priority
      if node.widget_id == focus_widget then value = value + 1000000000 end
    else
      value = math.max(priority(node.children[1]), priority(node.children[2]))
    end
    priority_cache[node] = value
    return value
  end

  local result = {
    columns = columns,
    rows = rows,
    rects = {},
    placements = {},
    hidden = {},
    reflowed = {},
    mode = "split",
    stacked = false,
    collapsed = false,
  }

  local function hide(node, reason, path)
    if node.type == "leaf" then
      result.hidden[#result.hidden + 1] = {
        widget_id = node.widget_id,
        reason = reason,
        path = path,
      }
      return
    end
    hide(node.children[1], reason, append_path_step(path, 1))
    hide(node.children[2], reason, append_path_step(path, 2))
  end

  local function split_fits(node, area, axis)
    local first_width, first_height = min_size(node.children[1])
    local second_width, second_height = min_size(node.children[2])
    if axis == "horizontal" then
      return area.width >= first_width + node.gap + second_width
        and area.height >= math.max(first_height, second_height)
    end
    return area.width >= math.max(first_width, second_width)
      and area.height >= first_height + node.gap + second_height
  end

  local function split_areas(node, area, axis)
    local first_width, first_height = min_size(node.children[1])
    local second_width, second_height = min_size(node.children[2])
    local total = axis == "horizontal" and area.width or area.height
    local first_min = axis == "horizontal" and first_width or first_height
    local second_min = axis == "horizontal" and second_width or second_height
    local available = total - node.gap
    local first_length = math.floor(available * node.ratio + 0.5)
    first_length = math.max(first_min, math.min(available - second_min, first_length))
    local second_length = available - first_length
    if axis == "horizontal" then
      return rectangle(area.x, area.y, first_length, area.height),
        rectangle(area.x + first_length + node.gap, area.y, second_length, area.height)
    end
    return rectangle(area.x, area.y, area.width, first_length),
      rectangle(area.x, area.y + first_length + node.gap, area.width, second_length)
  end

  local solve_node
  solve_node = function(node, area, path)
    if area.width == 0 or area.height == 0 then
      hide(node, "no_space", path)
      result.collapsed = true
      return
    end
    if node.type == "leaf" then
      local minimum = minimums[node.widget_id]
      local placement = {
        widget_id = node.widget_id,
        x = area.x,
        y = area.y,
        width = area.width,
        height = area.height,
        below_minimum = area.width < minimum.width or area.height < minimum.height,
        path = path,
      }
      result.rects[node.widget_id] = placement
      result.placements[#result.placements + 1] = placement
      return
    end

    local axis = node.axis
    if not split_fits(node, area, axis) and allow_stack then
      local alternate = axis == "horizontal" and "vertical" or "horizontal"
      if split_fits(node, area, alternate) then
        result.stacked = true
        result.reflowed[#result.reflowed + 1] = { path = path, from = axis, to = alternate }
        axis = alternate
      end
    end
    if split_fits(node, area, axis) then
      local first_area, second_area = split_areas(node, area, axis)
      solve_node(node.children[1], first_area, append_path_step(path, 1))
      solve_node(node.children[2], second_area, append_path_step(path, 2))
      return
    end

    result.collapsed = true
    local first_priority = priority(node.children[1])
    local second_priority = priority(node.children[2])
    local keep_first = first_priority >= second_priority
    local kept = keep_first and node.children[1] or node.children[2]
    local omitted = keep_first and node.children[2] or node.children[1]
    local kept_step = keep_first and 1 or 2
    local omitted_step = keep_first and 2 or 1
    solve_node(kept, area, append_path_step(path, kept_step))
    hide(omitted, "collapsed", append_path_step(path, omitted_step))
  end

  solve_node(tree, rectangle(x, y, columns, rows), "root")
  if result.collapsed then result.mode = "collapsed"
  elseif result.stacked then result.mode = "stacked" end
  return result
end

Layout.compute_rects = Layout.solve
Layout.SCHEMA_VERSION = SCHEMA_VERSION
Layout.DEFAULT_MAX_DEPTH = DEFAULT_MAX_DEPTH
Layout.DEFAULT_MAX_NODES = DEFAULT_MAX_NODES
Layout.DEFAULT_MAX_BYTES = DEFAULT_MAX_BYTES
Layout.HARD_MAX_DEPTH = HARD_MAX_DEPTH
Layout.HARD_MAX_NODES = HARD_MAX_NODES
Layout.HARD_MAX_BYTES = HARD_MAX_BYTES
Layout.MAX_WIDGET_ID_BYTES = MAX_WIDGET_ID_BYTES
Layout.MAX_GAP = MAX_GAP
Layout.MAX_VIEWPORT_DIMENSION = MAX_VIEWPORT_DIMENSION

return Layout
