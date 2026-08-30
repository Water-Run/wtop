package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Layout = require("wtop.model.layout")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

local function order_text(tree, options)
  return table.concat(assert(Layout.to_order(tree, options)), ",")
end

local cpu = assert(Layout.leaf("cpu"))
local memory = assert(Layout.leaf("memory"))
local root = assert(Layout.split("horizontal", 0.6, { cpu, memory }, { gap = 1 }))
local valid, info = Layout.validate(root, { allowed_widgets = { "cpu", "memory" } })
assert(valid)
equal(info.nodes, 3, "basic node count")
equal(info.widgets, 2, "basic widget count")
equal(table.concat(info.order, ","), "cpu,memory", "basic leaf order")
equal(root.type, "split", "split type")
equal(root.axis, "horizontal", "split axis")
equal(root.ratio, 0.6, "split ratio")
equal(root.gap, 1, "split gap")
equal(root.children[1].widget_id, "cpu", "first leaf")

assert(Layout.leaf("") == nil)
assert(Layout.leaf("bad/id") == nil)
assert(Layout.leaf(string.rep("x", Layout.MAX_WIDGET_ID_BYTES + 1)) == nil)
assert(Layout.split("diagonal", 0.5, { cpu, memory }) == nil)
assert(Layout.split("horizontal", 0, { cpu, memory }) == nil)
assert(Layout.split("horizontal", 1, { cpu, memory }) == nil)
assert(Layout.split("horizontal", 0 / 0, { cpu, memory }) == nil)
assert(Layout.split("horizontal", 0.5, { cpu }) == nil)
assert(Layout.split("horizontal", 0.5, { cpu, cpu }) == nil)

local cloned, clone_info = assert(Layout.clone(root))
assert(cloned ~= root and cloned.children ~= root.children)
assert(cloned.children[1] ~= root.children[1])
equal(clone_info.widgets, 2, "clone validation info")
cloned.children[1].widget_id = "changed"
equal(root.children[1].widget_id, "cpu", "clone is independent")

local unknown_ok, unknown_error = Layout.validate(root, { allowed_widgets = { "cpu" } })
equal(unknown_ok, nil, "unknown widget rejected")
assert(unknown_error:find("unknown_widget:memory", 1, true))
local duplicate_tree = {
  type = "split", axis = "vertical", ratio = 0.5, gap = 1,
  children = {
    { type = "leaf", widget_id = "cpu" },
    { type = "leaf", widget_id = "cpu" },
  },
}
local duplicate_ok, duplicate_error = Layout.validate(duplicate_tree)
equal(duplicate_ok, nil, "duplicate widget rejected")
assert(duplicate_error:find("duplicate_widget:cpu", 1, true))

local extra_key = { type = "leaf", widget_id = "cpu", command = "unsafe" }
assert(Layout.validate(extra_key) == nil)
local bad_children = {
  type = "split", axis = "horizontal", ratio = 0.5, gap = 1,
  children = { [1] = { type = "leaf", widget_id = "a" }, [3] = { type = "leaf", widget_id = "b" } },
}
assert(Layout.validate(bad_children) == nil)
local shared_leaf = { type = "leaf", widget_id = "shared" }
local shared_tree = {
  type = "split", axis = "horizontal", ratio = 0.5, gap = 1,
  children = { shared_leaf, shared_leaf },
}
local shared_ok, shared_error = Layout.validate(shared_tree)
equal(shared_ok, nil, "shared node rejected")
assert(shared_error:find("shared_node", 1, true) or shared_error:find("duplicate_widget", 1, true))
local cyclic = { type = "split", axis = "vertical", ratio = 0.5, gap = 1, children = {} }
cyclic.children[1] = { type = "leaf", widget_id = "safe" }
cyclic.children[2] = cyclic
local cycle_ok, cycle_error = Layout.validate(cyclic)
equal(cycle_ok, nil, "cycle rejected")
assert(cycle_error:find("cycle", 1, true))

local deep = { type = "leaf", widget_id = "depth0" }
for index = 1, 6 do
  deep = {
    type = "split", axis = "vertical", ratio = 0.5, gap = 1,
    children = { deep, { type = "leaf", widget_id = "depth" .. index } },
  }
end
local deep_ok, deep_error = Layout.validate(deep, { max_depth = 4 })
equal(deep_ok, nil, "depth limit")
equal(deep_error, "depth_limit_exceeded", "depth limit reason")
local nodes_ok, nodes_error = Layout.validate(deep, { max_nodes = 5 })
equal(nodes_ok, nil, "node limit")
equal(nodes_error, "node_limit_exceeded", "node limit reason")
assert(Layout.validate(cpu, { max_depth = Layout.HARD_MAX_DEPTH + 1 }) == nil)
assert(Layout.validate(cpu, { max_nodes = Layout.HARD_MAX_NODES + 1 }) == nil)

local migrated = assert(Layout.from_order({ "disk", "cpu" }, {
  allowed_widgets = { "cpu", "memory", "disk", "network" },
  append_missing = true,
  axis = "vertical",
  alternate_axes = true,
}))
equal(order_text(migrated), "disk,cpu,memory,network", "order migration with new widgets")
equal(migrated.axis, "vertical", "migration initial axis")
assert(Layout.from_order({ "cpu", "cpu" }) == nil)
assert(Layout.from_order({ "unknown" }, { allowed_widgets = { "cpu" } }) == nil)
assert(Layout.from_order({}) == nil)
assert(Layout.from_order({ "cpu" }, { append_missing = true }) == nil)
assert(Layout.from_order({ "a", "b", "c" }, { max_nodes = 4 }) == nil)

local base = assert(Layout.from_order({ "cpu", "disk" }, {
  allowed_widgets = { "cpu", "memory", "disk" },
  axis = "vertical",
}))
local base_serialized = assert(Layout.serialize(base))
local inserted = assert(Layout.insert(base, "cpu", "memory", {
  allowed_widgets = { "cpu", "memory", "disk" },
  position = "right",
  ratio = 0.4,
}))
equal(order_text(inserted), "cpu,memory,disk", "insert order")
equal(assert(Layout.serialize(base)), base_serialized, "insert does not mutate source")
local memory_path = assert(Layout.find_path(inserted, "memory"))
assert(#memory_path >= 1)
local restored = assert(Layout.remove(inserted, "memory", {
  allowed_widgets = { "cpu", "memory", "disk" },
}))
equal(order_text(restored), "cpu,disk", "remove collapses parent")
equal(assert(Layout.serialize(base)), base_serialized, "remove does not mutate source")
assert(Layout.remove(assert(Layout.leaf("only")), "only") == nil)

local swapped = assert(Layout.swap(base, "cpu", "disk", {
  allowed_widgets = { "cpu", "memory", "disk" },
}))
equal(order_text(swapped), "disk,cpu", "swap leaves")
local moved = assert(Layout.move(base, "disk", "cpu", {
  allowed_widgets = { "cpu", "memory", "disk" },
  position = "left",
}))
equal(order_text(moved), "disk,cpu", "move relative to target")
equal(moved.axis, "horizontal", "move direction sets split axis")
assert(Layout.move(base, "missing", "cpu") == nil)
assert(Layout.move(base, "bad/id", "bad/id") == nil)
assert(Layout.insert(base, "cpu", "cpu") == nil)
assert(Layout.insert(base, "cpu", "unknown", {
  allowed_widgets = { "cpu", "memory", "disk" },
}) == nil)

local ratio_changed = assert(Layout.set_ratio(base, {}, 0.7))
equal(ratio_changed.ratio, 0.7, "set root ratio")
equal(base.ratio, 0.5, "set ratio immutable")
local ratio_adjusted = assert(Layout.adjust_ratio(ratio_changed, {}, 1))
equal(ratio_adjusted.ratio, 0.95, "adjust ratio upper clamp")
ratio_adjusted = assert(Layout.adjust_ratio(ratio_adjusted, {}, -2))
equal(ratio_adjusted.ratio, 0.05, "adjust ratio lower clamp")
assert(Layout.set_ratio(base, { 1 }, 0.5) == nil)
assert(Layout.adjust_ratio(base, { 3 }, 0.1) == nil)

local encoded = assert(Layout.serialize(inserted, {
  allowed_widgets = { "cpu", "memory", "disk" },
}))
equal(encoded, assert(Layout.serialize(inserted)), "deterministic serialization")
local decoded = assert(Layout.deserialize(encoded, {
  allowed_widgets = { "cpu", "memory", "disk" },
}))
equal(assert(Layout.serialize(decoded)), encoded, "serialization round trip")
local table_copy = assert(Layout.to_table(decoded))
table_copy.children[1].children[1].widget_id = "mutated"
equal(assert(Layout.serialize(decoded)), encoded, "table contract is independent")
assert(Layout.deserialize("not json") == nil)
assert(Layout.deserialize('{"schema_version":2,"tree":{"type":"leaf","widget_id":"cpu"}}') == nil)
assert(Layout.deserialize('{"extra":true,"schema_version":1,"tree":{"type":"leaf","widget_id":"cpu"}}') == nil)
assert(Layout.deserialize('{"schema_version":1,"tree":{"type":"leaf","widget_id":"unknown"}}', {
  allowed_widgets = { "cpu" },
}) == nil)
assert(Layout.deserialize(encoded, { max_bytes = #encoded - 1 }) == nil)
assert(Layout.deserialize(encoded, { max_bytes = Layout.HARD_MAX_BYTES + 1 }) == nil)

local two = assert(Layout.split("horizontal", 0.5, {
  assert(Layout.leaf("left")), assert(Layout.leaf("right")),
}, { gap = 1 }))
local minima = {
  left = { min_width = 15, min_height = 5, priority = 1 },
  right = { min_width = 15, min_height = 5, priority = 2 },
}
local spacious = assert(Layout.solve(two, 100, 10, minima))
equal(spacious.mode, "split", "spacious split mode")
equal(#spacious.placements, 2, "spacious placements")
assert(spacious.rects.left.width >= 15 and spacious.rects.right.width >= 15)
equal(spacious.rects.left.width + spacious.rects.right.width + 1, 100, "spacious width conservation")

local stacked = assert(Layout.solve(two, 20, 11, minima))
equal(stacked.mode, "stacked", "narrow viewport stacks")
equal(stacked.stacked, true, "stacked flag")
equal(#stacked.placements, 2, "stacked placements")
assert(stacked.rects.left.y < stacked.rects.right.y)
assert(stacked.rects.left.height >= 5 and stacked.rects.right.height >= 5)

local collapsed = assert(Layout.solve(two, 20, 10, minima))
equal(collapsed.mode, "collapsed", "insufficient viewport collapses")
equal(#collapsed.placements, 1, "collapsed placement count")
assert(collapsed.rects.right and not collapsed.rects.left)
equal(#collapsed.hidden, 1, "collapsed hidden count")
local focused = assert(Layout.solve(two, 1, 1, minima, { focus_widget = "left" }))
equal(#focused.placements, 1, "focused tiny placement")
assert(focused.rects.left and focused.rects.left.width == 1 and focused.rects.left.height == 1)
assert(focused.rects.left.below_minimum)
local zero = assert(Layout.solve(two, 0, 0, minima))
equal(#zero.placements, 0, "zero viewport placements")
equal(#zero.hidden, 2, "zero viewport hidden")
for _, item in ipairs(zero.hidden) do assert(item.widget_id == "left" or item.widget_id == "right") end
local no_stack = assert(Layout.solve(two, 20, 11, minima, { allow_stack = false }))
equal(no_stack.mode, "collapsed", "stacking can be disabled")
assert(Layout.solve(two, 20, 11, { left = { min_width = 0, min_height = 1 } }) == nil)
assert(Layout.solve(two, Layout.MAX_VIEWPORT_DIMENSION + 1, 1, minima) == nil)
assert(Layout.solve(two, 20, 11, {
  left = { min_width = Layout.MAX_VIEWPORT_DIMENSION + 1, min_height = 1 },
}) == nil)

local vertical = assert(Layout.split("vertical", 0.5, {
  assert(Layout.leaf("top")), assert(Layout.leaf("bottom")),
}, { gap = 1 }))
local wide_short = assert(Layout.solve(vertical, 31, 5, {
  top = { width = 15, height = 5 }, bottom = { width = 15, height = 5 },
}))
equal(wide_short.mode, "stacked", "short viewport reflows horizontally")
assert(wide_short.rects.top.x < wide_short.rects.bottom.x)

local function overlaps(left, right)
  return not (left.x + left.width <= right.x
    or right.x + right.width <= left.x
    or left.y + left.height <= right.y
    or right.y + right.height <= left.y)
end

local random_state = 0x12345
local function random(maximum)
  random_state = (random_state * 1103515245 + 12345) % 2147483648
  return (random_state % maximum) + 1
end

local all_widgets = { "w1", "w2", "w3", "w4", "w5", "w6", "w7", "w8" }
local random_tree = assert(Layout.from_order({ "w1", "w2", "w3", "w4", "w5" }, {
  allowed_widgets = all_widgets,
  axis = "horizontal",
  alternate_axes = true,
}))
local random_mins = {}
for index, id in ipairs(all_widgets) do
  random_mins[id] = {
    min_width = 2 + index % 4,
    min_height = 1 + index % 3,
    priority = index,
  }
end

local function split_paths(node, path, output)
  if node.type == "leaf" then return end
  local copied = {}
  for index, value in ipairs(path) do copied[index] = value end
  output[#output + 1] = copied
  path[#path + 1] = 1
  split_paths(node.children[1], path, output)
  path[#path] = 2
  split_paths(node.children[2], path, output)
  path[#path] = nil
end

for iteration = 1, 400 do
  local before = assert(Layout.serialize(random_tree, { allowed_widgets = all_widgets }))
  local current_order = assert(Layout.to_order(random_tree, { allowed_widgets = all_widgets }))
  local operation = random(5)
  local next_tree
  if operation == 1 and #current_order >= 2 then
    local first = random(#current_order)
    local second = random(#current_order - 1)
    if second >= first then second = second + 1 end
    next_tree = assert(Layout.swap(random_tree, current_order[first], current_order[second], {
      allowed_widgets = all_widgets,
    }))
  elseif operation == 2 and #current_order >= 2 then
    local source_index = random(#current_order)
    local target_index = random(#current_order - 1)
    if target_index >= source_index then target_index = target_index + 1 end
    next_tree = assert(Layout.move(random_tree, current_order[source_index], current_order[target_index], {
      allowed_widgets = all_widgets,
      position = random(2) == 1 and "left" or "below",
      ratio = random(80) / 100 + 0.1,
    }))
  elseif operation == 3 then
    local paths = {}
    split_paths(random_tree, {}, paths)
    local chosen = paths[random(#paths)]
    next_tree = assert(Layout.adjust_ratio(random_tree, chosen, (random(21) - 11) / 100, {
      allowed_widgets = all_widgets,
    }))
  elseif operation == 4 and #current_order > 2 then
    next_tree = assert(Layout.remove(random_tree, current_order[random(#current_order)], {
      allowed_widgets = all_widgets,
    }))
  else
    local present = {}
    for _, id in ipairs(current_order) do present[id] = true end
    local missing = {}
    for _, id in ipairs(all_widgets) do if not present[id] then missing[#missing + 1] = id end end
    if #missing > 0 then
      next_tree = assert(Layout.insert(random_tree, current_order[random(#current_order)], missing[random(#missing)], {
        allowed_widgets = all_widgets,
        position = random(2) == 1 and "right" or "above",
        ratio = 0.5,
      }))
    else
      next_tree = assert(Layout.swap(random_tree, current_order[1], current_order[#current_order], {
        allowed_widgets = all_widgets,
      }))
    end
  end
  equal(assert(Layout.serialize(random_tree, { allowed_widgets = all_widgets })), before,
    "random operation source immutable")
  random_tree = next_tree
  local invariant, invariant_info = Layout.validate(random_tree, { allowed_widgets = all_widgets })
  assert(invariant, invariant_info)
  local seen = {}
  for _, id in ipairs(invariant_info.order) do
    assert(not seen[id])
    seen[id] = true
  end

  local columns = random(51) - 1
  local rows = random(21) - 1
  local solved = assert(Layout.solve(random_tree, columns, rows, random_mins, {
    allowed_widgets = all_widgets,
    focus_widget = invariant_info.order[random(#invariant_info.order)],
  }))
  equal(#solved.placements + #solved.hidden, invariant_info.widgets, "solve accounts for every widget")
  for index, placement in ipairs(solved.placements) do
    assert(placement.width >= 0 and placement.height >= 0)
    assert(placement.x >= 1 and placement.y >= 1)
    assert(placement.x + placement.width - 1 <= columns)
    assert(placement.y + placement.height - 1 <= rows)
    for other_index = index + 1, #solved.placements do
      assert(not overlaps(placement, solved.placements[other_index]), "layout rectangles overlap")
    end
  end
  if iteration % 25 == 0 then
    local snapshot = assert(Layout.serialize(random_tree, { allowed_widgets = all_widgets }))
    random_tree = assert(Layout.deserialize(snapshot, { allowed_widgets = all_widgets }))
    equal(assert(Layout.serialize(random_tree)), snapshot, "random serialization invariant")
  end
end

return true
