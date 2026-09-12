local Tree = require("wtop.ui.layout.tree")

local M = {}
local MAX_DIMENSION = 10000

local variant_order = {
  -- Variants are selected from the actual rectangle, not merely from the
  -- viewport class.  A short terminal can still give a surviving widget a
  -- generous rectangle, and rendering its one-line form there produced the
  -- large empty panels that were especially visible in tiny mode.
  tiny = {"full", "spark", "compact", "value"},
  ["narrow-tall"] = {"full", "spark", "compact", "value"},
  standard = {"full", "spark", "compact", "value"},
  ["wide-short"] = {"full", "spark", "compact", "value"},
  ["wide-tall"] = {"full", "spark", "compact", "value"},
}

function M.mode(columns, rows)
  assert(type(columns) == "number" and columns == columns and columns ~= math.huge
      and columns ~= -math.huge and columns >= 1 and columns <= MAX_DIMENSION
      and columns == math.floor(columns),
    "layout columns must be an integer in 1..10000")
  assert(type(rows) == "number" and rows == rows and rows ~= math.huge
      and rows ~= -math.huge and rows >= 1 and rows <= MAX_DIMENSION
      and rows == math.floor(rows),
    "layout rows must be an integer in 1..10000")
  -- Width takes precedence for panoramic terminals.  Previously every
  -- viewport at 22 rows or less became `tiny`, so 200x22 showed a single
  -- widget while 160x24 showed a useful grid.
  if columns >= 120 and rows < 30 then
    return "wide-short"
  elseif columns < 70 or rows <= 12 or (columns <= 80 and rows <= 24) then
    return "tiny"
  elseif columns >= 180 and rows >= 45 then
    return "wide-tall"
  elseif columns < 120 then
    return "narrow-tall"
  end
  return "standard"
end

local function rect(x, y, width, height)
  return {
    x = math.floor(x), y = math.floor(y),
    width = math.max(0, math.floor(width)),
    height = math.max(0, math.floor(height)),
  }
end

local function contains_focus(node, focus_id)
  if not focus_id then return false end
  return Tree.find(node, focus_id) ~= nil
end

local function priority(node, focus_id)
  local result = tonumber(node.priority) or 0
  if contains_focus(node, focus_id) then
    result = result + 1000000
  end
  if node.type == "split" then
    result = math.max(result, priority(node.first, focus_id), priority(node.second, focus_id))
  elseif node.type == "flow" then
    for _, child in ipairs(node.children) do
      result = math.max(result, priority(child, focus_id))
    end
  end
  return result
end

local function choose_variant(node, area, mode)
  local preferred = node.preferred_variant and {node.preferred_variant} or variant_order[mode]
  for _, name in ipairs(preferred) do
    local form = node.forms[name]
    if form and area.width >= form.min_width and area.height >= form.min_height then
      return name
    end
  end
  if node.preferred_variant then
    for _, name in ipairs(variant_order[mode]) do
      local form = node.forms[name]
      if form and area.width >= form.min_width and area.height >= form.min_height then
        return name
      end
    end
  end
  -- Below all declared minima, value mode is still rendered in the available
  -- cells. This makes the minimum screen actionable instead of crashing.
  return "value"
end

local function min_size(node, mode)
  if node.type == "widget" then
    local smallest = node.forms.value
    return smallest.min_width, smallest.min_height
  elseif node.type == "flow" then
    return 1, 1
  end
  local first_w, first_h = min_size(node.first, mode)
  local second_w, second_h = min_size(node.second, mode)
  local axis = node.axis
  if node.axes and node.axes[mode] then
    axis = node.axes[mode]
  elseif node.adaptive then
    axis = mode == "narrow-tall" and "column" or "row"
  end
  if axis == "row" then
    return first_w + second_w + node.gap, math.max(first_h, second_h)
  end
  return math.max(first_w, second_w), first_h + second_h + node.gap
end


-- The size at which a subtree renders its richest form.  `min_size` reports
-- the smallest form that merely fits, so a split could satisfy both children
-- while leaving each of them too narrow to show the columns it exists for.
local function preferred_size(node, mode)
  if node.type == "widget" then
    local full = node.forms.full or node.forms.value
    return full.min_width, full.min_height
  elseif node.type == "flow" then
    return 1, 1
  end
  local first_w, first_h = preferred_size(node.first, mode)
  local second_w, second_h = preferred_size(node.second, mode)
  local axis = node.axis
  if node.axes and node.axes[mode] then
    axis = node.axes[mode]
  elseif node.adaptive then
    axis = mode == "narrow-tall" and "column" or "row"
  end
  if axis == "row" then
    return first_w + second_w + node.gap, math.max(first_h, second_h)
  end
  return math.max(first_w, second_w), first_h + second_h + node.gap
end

local function node_axis(node, mode)
  local axis = node.axis
  if node.axes and node.axes[mode] then
    axis = node.axes[mode]
  elseif node.adaptive then
    axis = mode == "narrow-tall" and "column" or "row"
  end
  return axis
end

-- A persisted ratio is authored against the original tree, whose default
-- value is proportional to leaf counts. Responsive mode may turn a vertical
-- branch into a horizontal one, changing how many visible tracks each child
-- occupies. Translate only the user's bias away from that default onto the
-- responsive track baseline. This preserves edited ratios without double
-- weighting default 2:1 branches into 4:1 columns.
local function leaf_count(node)
  if node.type == "widget" then return 1 end
  if node.type == "flow" then
    local total = 0
    for _, child in ipairs(node.children) do total = total + leaf_count(child) end
    return math.max(1, total)
  end
  return leaf_count(node.first) + leaf_count(node.second)
end

local function track_span(node, mode, orientation)
  if node.type == "widget" or node.type == "flow" then return 1 end
  local first = track_span(node.first, mode, orientation)
  local second = track_span(node.second, mode, orientation)
  if node_axis(node, mode) == orientation then return first + second end
  return math.max(first, second)
end

local function responsive_ratio(node, mode, orientation)
  local first_leaves, second_leaves = leaf_count(node.first), leaf_count(node.second)
  local default_ratio = first_leaves / (first_leaves + second_leaves)
  local first_tracks = track_span(node.first, mode, orientation)
  local second_tracks = track_span(node.second, mode, orientation)
  local track_ratio = first_tracks / (first_tracks + second_tracks)
  local authored_odds = node.ratio / (1 - node.ratio)
  local default_odds = default_ratio / (1 - default_ratio)
  local track_odds = track_ratio / (1 - track_ratio)
  local adjusted_odds = authored_odds / default_odds * track_odds
  return adjusted_odds / (1 + adjusted_odds)
end

local function split_lengths(total, gap, ratio, first_min, second_min)
  local available = math.max(0, total - gap)
  if available < first_min + second_min then
    return nil
  end
  local first = math.floor(available * ratio + 0.5)
  first = math.max(first_min, math.min(available - second_min, first))
  return first, available - first
end

local solve_node

local function hide_node(result, node, reason)
  Tree.walk(node, function(current)
    if current.type == "widget" then
      result.hidden[#result.hidden + 1] = {id = current.id, reason = reason}
    end
  end)
end

local function distribute(total, count, gap)
  local available = math.max(0, total - gap * (count - 1))
  local base = count > 0 and math.floor(available / count) or 0
  local remainder = available - base * count
  local result = {}
  for index = 1, count do
    result[index] = base + (index <= remainder and 1 or 0)
  end
  return result
end

local function sorted_children(children, focus_id)
  local result = {}
  for index, child in ipairs(children) do
    result[index] = {node = child, index = index, score = priority(child, focus_id)}
  end
  table.sort(result, function(a, b)
    if a.score == b.score then return a.index < b.index end
    return a.score > b.score
  end)
  return result
end

local function solve_flow(node, area, mode, result, options)
  local gap = node.gap or 1
  local ranked = sorted_children(node.children, options.focus_id)

  local children = {}
  -- Preserve authored order after using priority only to decide overflow.
  for _, item in ipairs(ranked) do children[#children + 1] = item end
  local minimum_cell_width = 8
  local minimum_cell_height = 1
  local max_columns = math.max(1, math.floor((area.width + gap) / (minimum_cell_width + gap)))
  local target_columns = mode == "wide-short" and 4 or (mode == "wide-tall" and 3
    or (mode == "standard" and 2 or 1))
  local policy_columns = mode == "wide-short" and 4 or (mode == "wide-tall" and 3 or 2)
  policy_columns = math.max(1, math.min(policy_columns, max_columns, #children))

  -- Pick the grid that preserves the richest widget forms.  This avoids a
  -- hard 80x24 -> 80x25 jump for generic flow layouts: two columns remain in
  -- use until a single column is tall enough to render equally rich forms.
  local richness = {value = 1, compact = 2, spark = 3, full = 4}
  local columns, best_score, best_distance = 1, -math.huge, math.huge
  for candidate = 1, policy_columns do
    local candidate_rows = math.ceil(#children / candidate)
    local widths = distribute(area.width, candidate, gap)
    local heights = distribute(area.height, candidate_rows, gap)
    local score = 0
    for index, item in ipairs(children) do
      local row = math.floor((index - 1) / candidate) + 1
      local column = ((index - 1) % candidate) + 1
      if item.node.type == "widget" then
        local form = item.node.forms.value
        if widths[column] >= form.min_width and heights[row] >= form.min_height then
          score = score + (richness[choose_variant(item.node,
            {width = widths[column], height = heights[row]}, mode)] or 0)
          -- Variant names alone cannot tell a table showing three columns from
          -- the same table showing seven: both are the same form.  Reward the
          -- cell for approaching the widget's full width so a tie between two
          -- and four columns resolves toward the layout that actually keeps
          -- the data, instead of toward the mode's nominal column count.
          local full_form = item.node.forms.full
          if full_form and full_form.min_width and full_form.min_width > 0 then
            score = score + 0.5 * math.min(1, widths[column] / full_form.min_width)
          end
        end
      else
        local minimum_width, minimum_height = min_size(item.node, mode)
        if widths[column] >= minimum_width and heights[row] >= minimum_height then
          score = score + 1
        end
      end
    end
    local distance = math.abs(candidate - math.min(target_columns, policy_columns))
    if score > best_score or (score == best_score and distance < best_distance) then
      columns, best_score, best_distance = candidate, score, distance
    end
  end
  local max_rows = math.max(1, math.floor((area.height + gap) / (minimum_cell_height + gap)))
  local capacity = math.max(1, columns * max_rows)
  while #children > capacity do
    local removed = table.remove(children) -- lowest priority is last
    hide_node(result, removed.node, "no-space")
  end

  table.sort(children, function(a, b) return a.index < b.index end)
  local rows = math.ceil(#children / columns)
  local widths = distribute(area.width, columns, gap)
  local heights = distribute(area.height, rows, gap)
  local x_positions, y_positions = {}, {}
  local x = area.x
  for column = 1, columns do
    x_positions[column] = x
    x = x + widths[column] + gap
  end
  local y = area.y
  for row = 1, rows do
    y_positions[row] = y
    y = y + heights[row] + gap
  end
  for index, item in ipairs(children) do
    local row = math.floor((index - 1) / columns) + 1
    local column = ((index - 1) % columns) + 1
    solve_node(item.node, rect(x_positions[column], y_positions[row], widths[column], heights[row]),
      mode, result, options)
  end
end

solve_node = function(node, area, mode, result, options)
  if area.width < 1 or area.height < 1 then
    hide_node(result, node, "no-space")
    return
  end
  if node.type == "widget" then
    result.placements[#result.placements + 1] = {
      id = node.id,
      kind = node.kind,
      node = node,
      x = area.x, y = area.y, width = area.width, height = area.height,
      variant = choose_variant(node, area, mode),
      focused = node.id == options.focus_id,
    }
    return
  elseif node.type == "flow" then
    solve_flow(node, area, mode, result, options)
    return
  end

  local axis = node_axis(node, mode)
  local first_w, first_h = min_size(node.first, mode)
  local second_w, second_h = min_size(node.second, mode)
  local first_min = axis == "row" and first_w or first_h
  local second_min = axis == "row" and second_w or second_h
  local total = axis == "row" and area.width or area.height
  local ratio = responsive_ratio(node, mode, axis)
  local first_length, second_length = split_lengths(total, node.gap, ratio, first_min, second_min)

  -- Both axes may satisfy the minimum sizes while only one lets the children
  -- reach their full form.  Splitting a 120-column terminal into four 30-cell
  -- panels "fits" every table and still drops half their columns; stacking the
  -- same panels keeps the data and spends height that was empty anyway.
  if first_length and node.reflow == true then
    local alternate = axis == "row" and "column" or "row"
    local first_pw, first_ph = preferred_size(node.first, mode)
    local second_pw, second_ph = preferred_size(node.second, mode)
    local current_first = axis == "row" and first_pw or first_ph
    local current_second = axis == "row" and second_pw or second_ph
    local satisfied = (first_length >= current_first and 1 or 0)
      + (second_length >= current_second and 1 or 0)
    if satisfied < 2 then
      local alternate_first_min = alternate == "row" and first_w or first_h
      local alternate_second_min = alternate == "row" and second_w or second_h
      local alternate_total = alternate == "row" and area.width or area.height
      local alternate_ratio = responsive_ratio(node, mode, alternate)
      local alternate_first, alternate_second = split_lengths(
        alternate_total, node.gap, alternate_ratio, alternate_first_min, alternate_second_min)
      if alternate_first then
        local alternate_first_pref = alternate == "row" and first_pw or first_ph
        local alternate_second_pref = alternate == "row" and second_pw or second_ph
        local alternate_satisfied = (alternate_first >= alternate_first_pref and 1 or 0)
          + (alternate_second >= alternate_second_pref and 1 or 0)
        if alternate_satisfied > satisfied then
          result.reflowed[#result.reflowed + 1] =
            { id = node.id, from = axis, to = alternate, reason = "preferred-form" }
          axis, first_length, second_length = alternate, alternate_first, alternate_second
        end
      end
    end
  end

  if not first_length and node.reflow == true then
    local alternate = axis == "row" and "column" or "row"
    local alternate_first_min = alternate == "row" and first_w or first_h
    local alternate_second_min = alternate == "row" and second_w or second_h
    local alternate_total = alternate == "row" and area.width or area.height
    local alternate_ratio = responsive_ratio(node, mode, alternate)
    local alternate_first, alternate_second = split_lengths(
      alternate_total, node.gap, alternate_ratio, alternate_first_min, alternate_second_min)
    if alternate_first then
      result.reflowed[#result.reflowed + 1] = {id = node.id, from = axis, to = alternate}
      axis, first_length, second_length = alternate, alternate_first, alternate_second
    end
  end

  if not first_length then
    local keep_first = priority(node.first, options.focus_id) >= priority(node.second, options.focus_id)
    local kept, hidden = keep_first and node.first or node.second,
      keep_first and node.second or node.first
    solve_node(kept, area, mode, result, options)
    hide_node(result, hidden, "split-collapsed")
    return
  end

  local first_area, second_area
  if axis == "row" then
    first_area = rect(area.x, area.y, first_length, area.height)
    second_area = rect(area.x + first_length + node.gap, area.y, second_length, area.height)
  else
    first_area = rect(area.x, area.y, area.width, first_length)
    second_area = rect(area.x, area.y + first_length + node.gap, area.width, second_length)
  end
  solve_node(node.first, first_area, mode, result, options)
  solve_node(node.second, second_area, mode, result, options)
end

function M.solve(tree, columns, rows, options)
  if options == nil then options = {} end
  assert(type(options) == "table", "layout options must be a table")
  assert(type(columns) == "number" and columns == columns and columns ~= math.huge
      and columns ~= -math.huge and columns % 1 == 0
      and columns >= 1 and columns <= MAX_DIMENSION,
    "layout columns must be a positive integer in 1..10000")
  assert(type(rows) == "number" and rows == rows and rows ~= math.huge
      and rows ~= -math.huge and rows % 1 == 0
      and rows >= 1 and rows <= MAX_DIMENSION,
    "layout rows must be a positive integer in 1..10000")
  columns, rows = math.floor(columns), math.floor(rows)
  local valid, reason = Tree.validate(tree)
  assert(valid, reason)
  local mode = options.mode or M.mode(columns, rows)
  assert(variant_order[mode], "unknown responsive layout mode")
  if options.focus_id ~= nil then
    assert(type(options.focus_id) == "string" and #options.focus_id <= 256,
      "layout focus_id must be a bounded string")
  end
  local header_height = options.header_height or 0
  local footer_height = options.footer_height or 0
  assert(type(header_height) == "number" and header_height % 1 == 0 and header_height >= 0
      and header_height <= rows, "header_height must fit the viewport")
  assert(type(footer_height) == "number" and footer_height % 1 == 0 and footer_height >= 0
      and footer_height <= rows, "footer_height must fit the viewport")
  local content
  if options.content_rect ~= nil then
    assert(type(options.content_rect) == "table", "content_rect must be a table")
    local source = options.content_rect
    for _, key in ipairs({"x", "y", "width", "height"}) do
      local value = source[key]
      assert(type(value) == "number" and value == value and value ~= math.huge
          and value ~= -math.huge and value % 1 == 0,
        "content_rect fields must be finite integers")
    end
    local left = math.max(1, source.x)
    local top = math.max(1, source.y)
    local right = math.min(columns, source.x + math.max(0, source.width) - 1)
    local bottom = math.min(rows, source.y + math.max(0, source.height) - 1)
    content = rect(left, top, math.max(0, right - left + 1), math.max(0, bottom - top + 1))
  else
    content = rect(1, header_height + 1, columns,
      math.max(0, rows - header_height - footer_height))
  end
  local result = {
    mode = mode,
    columns = columns,
    rows = rows,
    content = content,
    placements = {},
    hidden = {},
    reflowed = {},
  }
  -- Let the tree's minima, reflow rules and priorities decide how much fits.
  -- This keeps transitions continuous: resizing by one row no longer jumps
  -- from one widget to every widget on the page.
  solve_node(tree, content, mode, result, options)
  table.sort(result.placements, function(a, b)
    if a.y == b.y then return a.x < b.x end
    return a.y < b.y
  end)
  return result
end

return M
