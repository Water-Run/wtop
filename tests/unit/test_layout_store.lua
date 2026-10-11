package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local LayoutStore = require("wtop.layout_store")

local defaults = {
    overview = { "cpu", "memory", "disk" },
    processes = { "table" },
}
local orders = assert(LayoutStore.parse([[
schema_version: 1
pages:
  overview:
    - disk
    - cpu
]], defaults))
assert(table.concat(orders.overview, ",") == "disk,cpu,memory")
assert(orders.processes[1] == "table")
assert(LayoutStore.parse("schema_version: 2\npages:\n  overview:\n    - cpu\n", defaults) == nil)
assert(LayoutStore.parse("schema_version: 1\npages:\n  overview:\n    - unknown\n", defaults) == nil)

local encoded = LayoutStore.encode(orders)
local roundtrip = assert(LayoutStore.parse(encoded, defaults))
assert(table.concat(roundtrip.overview, ",") == "disk,cpu,memory")

local Layout = require("wtop.model.layout")
local custom = assert(Layout.split("horizontal", 0.6, {
    assert(Layout.leaf("disk")),
    assert(Layout.split("vertical", 0.4, {
        assert(Layout.leaf("cpu")), assert(Layout.leaf("memory")),
    }, { gap = 2 })),
}, { gap = 1 }))
local encoded_v2 = LayoutStore.encode(defaults, {
    overview = custom,
    processes = assert(Layout.leaf("table")),
})
local v2_orders, v2_trees = assert(LayoutStore.parse(encoded_v2, defaults))
assert(table.concat(v2_orders.overview, ",") == "disk,cpu,memory")
assert(v2_trees.overview.type == "split" and v2_trees.overview.axis == "horizontal")
assert(math.abs(v2_trees.overview.ratio - 0.6) < 0.000001)
assert(v2_trees.overview.children[2].gap == 2)

local migrated_orders, migrated_trees = assert(LayoutStore.parse([[
schema_version: 2
pages:
  overview:
    type: split
    axis: horizontal
    ratio_micros: 500000
    gap: 1
    children:
      - type: leaf
        widget_id: "disk"
      - type: leaf
        widget_id: "cpu"
]], defaults))
assert(table.concat(migrated_orders.overview, ",") == "disk,cpu,memory",
    "new default widgets must be appended to saved trees")
assert(#assert(Layout.to_order(migrated_trees.overview)) == 3)
assert(LayoutStore.parse(encoded_v2:gsub("ratio_micros: 600000", "ratio_micros: 0"), defaults) == nil)
local _, special_status = LayoutStore.load(defaults, "/dev/null")
assert(special_status.state == "error", "layout readers must reject special files")
assert(LayoutStore.path(function() error("hostile environment") end) == nil)
assert(LayoutStore.path(function(name)
    return name == "XDG_CONFIG_HOME" and "relative" or "/home/test"
end) == "/home/test/.config/wtop/layout.yml")
local _, unsafe_status = LayoutStore.load(defaults, "/tmp/../layout.yml")
assert(unsafe_status.state == "error" and unsafe_status.reason == "invalid layout path")
assert(LayoutStore.parse("schema_version: 1\npages: {}\n", nil) == nil)

-- Upgrading wtop must not bury the widgets a release adds.  Appending each one
-- below the previous built a right-leaning chain where every insert halved the
-- remaining space, so a layout saved with two widgets kept only those two on
-- screen and the responsive solver collapsed the other nine away.
local Responsive = require("wtop.ui.layout.responsive")
local UI = require("wtop.ui")
local many = {}
for index = 1, 11 do many[index] = "widget" .. index end
local grown_orders, grown_trees = assert(LayoutStore.parse([[
schema_version: 2
pages:
  overview:
    type: split
    axis: horizontal
    ratio_micros: 500000
    gap: 1
    children:
      - type: leaf
        widget_id: "widget1"
      - type: leaf
        widget_id: "widget2"
]], { overview = many }))
assert(#grown_orders.overview == 11, "every default widget must reach the order")
assert(grown_orders.overview[1] == "widget1" and grown_orders.overview[2] == "widget2",
    "the saved arrangement must keep its position")

-- Build a UI tree from the migrated model and solve it: the point is that the
-- additions are reachable, not merely present in the tree.
local function ui_from(model_tree, path)
  if model_tree.type == "leaf" then
    return UI.Layout.widget({
      id = model_tree.widget_id, kind = "metric", priority = 50,
      min_width = 20, min_height = 4,
      value_min_width = 14, value_min_height = 2,
    })
  end
  return UI.Layout.split(model_tree.axis == "horizontal" and "row" or "column",
    model_tree.ratio,
    ui_from(model_tree.children[1], path .. "1"),
    ui_from(model_tree.children[2], path .. "2"),
    { id = "t:" .. path, gap = model_tree.gap, reflow = true })
end
local solved = Responsive.solve(ui_from(grown_trees.overview, "r"), 160, 44,
    { header_height = 1, footer_height = 1 })
assert(#solved.placements == 11,
    "all widgets must be placed, got " .. #solved.placements
      .. " with " .. #solved.hidden .. " hidden")
local smallest = math.huge
for _, placement in ipairs(solved.placements) do
  smallest = math.min(smallest, placement.width * placement.height)
end
assert(smallest >= 60, "no widget may be starved into an unusable sliver")

local tabbed = LayoutStore.encode(defaults, nil, nil, nil, nil,
  { "processes", "overview" })
assert(tabbed:find("schema_version: 5", 1, true))
local _, _, _, _, columns, tab_order = assert(LayoutStore.parse(tabbed, defaults))
assert(#columns > 0 and table.concat(tab_order, ",") == "processes,overview")
assert(LayoutStore.parse(tabbed:gsub('  %- "overview"', '  - "processes"'), defaults) == nil,
  "duplicate visible tabs are refused")
assert(LayoutStore.parse(tabbed:gsub('  %- "overview"', '  - "unknown"'), defaults) == nil,
  "unknown visible tabs are refused")
assert(LayoutStore.parse(tabbed:gsub('tabs:\n  %- "processes"\n  %- "overview"',
  'tabs: []'), defaults) == nil, "a layout cannot hide every tab")
assert(LayoutStore.parse(tabbed:gsub('schema_version: 5', 'schema_version: 4'), defaults)
  == nil, "v4 does not silently ignore a v5 tab list")
local workspace_tabbed = LayoutStore.encode(defaults, nil,
  { alpha = v2_trees }, "alpha", nil, { "overview" })
local _, _, saved_workspaces, active_workspace, _, saved_tabs =
  assert(LayoutStore.parse(workspace_tabbed, defaults))
assert(saved_workspaces.alpha and active_workspace == "alpha"
  and saved_tabs[1] == "overview", "tab order survives named workspaces")
local combined_session = require("wtop.workspace").new({
  active_tab = "memory", tab_order = { "overview", "memory" },
})
local removed_widget = combined_session.focus.memory
assert(combined_session:remove_focused_widget())
local combined = LayoutStore.encode(combined_session:orders(), combined_session:trees(),
  nil, nil, nil, combined_session:custom_tab_order(),
  require("wtop.workspace").default_orders())
local combined_orders, _, _, _, _, combined_tabs = assert(LayoutStore.parse(combined,
  require("wtop.workspace").default_orders()))
assert(table.concat(combined_tabs, ",") == "overview,memory")
for _, id in ipairs(combined_orders.memory) do
  assert(id ~= removed_widget, "tab customization lost the widget removal")
end
local Workspace = require("wtop.workspace")
local mixed_page = Workspace.new()
assert(mixed_page:new_custom_page("cpu_overview", "CPU and processes"))
assert(mixed_page:add_focused_widget("process_table", "after"))
local definitions = mixed_page:custom_page_definitions()
local encoded_v6 = LayoutStore.encode(mixed_page:orders(), mixed_page:trees(),
  nil, nil, nil, mixed_page:custom_tab_order(),
  Workspace.default_orders(definitions), definitions)
assert(encoded_v6:find("schema_version: 6", 1, true)
  and encoded_v6:find("custom_pages:", 1, true))
local v6_orders, v6_trees, _, _, _, v6_tabs, v6_definitions =
  assert(LayoutStore.parse(encoded_v6, Workspace.default_orders()))
assert(table.concat(v6_orders.custom1, ",") == "cpu_overview,process_table"
  and v6_tabs[2] == "custom1" and v6_definitions[1].name == "CPU and processes")
local v6_reopened = Workspace.new({ custom_pages = v6_definitions,
  tab_order = v6_tabs, layout_trees = v6_trees, active_tab = "custom1" })
assert(#v6_reopened:palette() == #Workspace.default_orders(definitions).custom1 - 2)
assert(LayoutStore.parse(encoded_v6:gsub('name: "CPU and processes"',
  'name: ""'), Workspace.default_orders()) == nil)
assert(LayoutStore.parse(encoded_v6:gsub('seed_widget: "cpu_overview"',
  'seed_widget: "unknown"'), Workspace.default_orders()) == nil)

return true
