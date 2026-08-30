package.path = "src/?.lua;src/?/init.lua;" .. package.path

local Layout = require("wtop.ui.layout")
local Overview = require("wtop.ui.views.overview")
local Width = require("wtop.ui.renderer.width")
local Workspace = require("wtop.workspace")

local function equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual), 2)
  end
end

local widgets = {
  Layout.widget({id = "cpu", kind = "metric", priority = 100, min_width = 28, min_height = 8}),
  Layout.widget({id = "memory", kind = "metric", priority = 90, min_width = 28, min_height = 8}),
  Layout.widget({id = "pressure", kind = "metric", priority = 80, min_width = 28, min_height = 8}),
}
local tree = Layout.flow(widgets, {gap = 1})
assert(Layout.validate(tree))

local tiny = Layout.solve(tree, 60, 20, {header_height = 1, footer_height = 1})
equal(tiny.mode, "tiny")
equal(#tiny.placements, 3)
equal(tiny.placements[1].id, "cpu")
equal(tiny.placements[1].y, 2)
equal(tiny.placements[1].height, 9)
equal(tiny.placements[1].y, tiny.placements[2].y)
assert(tiny.placements[3].y > tiny.placements[1].y,
  "tiny flow must use available rows instead of wasting the viewport")

local narrow_tall = Layout.solve(tree, 80, 50, {header_height = 1, footer_height = 1})
equal(narrow_tall.mode, "narrow-tall")
equal(#narrow_tall.placements, 3)
equal(narrow_tall.placements[1].x, narrow_tall.placements[2].x)
assert(narrow_tall.placements[1].y < narrow_tall.placements[2].y
  and narrow_tall.placements[2].y < narrow_tall.placements[3].y,
  "narrow-tall must stack vertically")

local wide_short = Layout.solve(tree, 160, 24, {header_height = 1, footer_height = 1})
equal(wide_short.mode, "wide-short")
equal(#wide_short.placements, 3)
equal(wide_short.placements[1].y, wide_short.placements[2].y)
assert(wide_short.placements[1].x < wide_short.placements[2].x
  and wide_short.placements[2].x < wide_short.placements[3].x,
  "wide-short must arrange horizontal summaries")
equal(Layout.mode(200, 22), "wide-short",
  "panoramic low-row terminals must not collapse to tiny")

-- Persisted split ratios already encode subtree cardinality. Responsive
-- reflow must translate that baseline once, not multiply it a second time.
-- The old solver turned three equal network panels into 72/72/36 columns.
local workspace = Workspace.new()
assert(workspace:select("network"))
local balanced_network = workspace:layout(180, 45)
equal(#balanced_network.placements, 3)
local minimum_width, maximum_width = math.huge, 0
for _, placement in ipairs(balanced_network.placements) do
  minimum_width = math.min(minimum_width, placement.width)
  maximum_width = math.max(maximum_width, placement.width)
end
assert(maximum_width - minimum_width <= 1,
  "three-track responsive layout must remain visually balanced")

-- Adjacent heights keep the same two-column flow until one column can retain
-- equally rich forms, avoiding the former one-row breakpoint jump.
local boundary_low = Layout.solve(tree, 80, 24, {header_height = 1, footer_height = 1})
local boundary_high = Layout.solve(tree, 80, 25, {header_height = 1, footer_height = 1})
equal(boundary_low.placements[1].x, boundary_high.placements[1].x)
equal(boundary_low.placements[2].x, boundary_high.placements[2].x)

local wide_tall = Layout.solve(tree, 180, 45, {header_height = 1, footer_height = 1})
equal(wide_tall.mode, "wide-tall")
equal(#wide_tall.placements, 3)
equal(wide_tall.placements[1].y, wide_tall.placements[3].y)
assert(wide_tall.placements[1].width >= 50)

-- An adaptive split changes axis, while focus wins a forced collapse.
local split = Layout.split("row", 0.5,
  Layout.widget({id = "primary", priority = 1, min_width = 50, value_min_width = 20}),
  Layout.widget({id = "detail", priority = 0, min_width = 50, value_min_width = 20}),
  {adaptive = true, gap = 1})
local vertical = Layout.solve(split, 80, 50)
equal(#vertical.placements, 2)
equal(vertical.placements[1].x, vertical.placements[2].x)
assert(vertical.placements[1].y < vertical.placements[2].y)
local collapsed = Layout.solve(split, 30, 10, {focus_id = "detail"})
equal(#collapsed.placements, 1)
equal(collapsed.placements[1].id, "detail", "focused widget must survive collapse")

-- Render complete pages at the four required aspect ratios. Every grid proves
-- wide-cell integrity and remains exactly within the terminal rectangle.
local page = Overview.new({tabs = {
  {id = "overview", label = "概览"}, {id = "processes", label = "进程"},
  {id = "compute", label = "计算"}, {id = "storage", label = "存储与 I/O"},
}})
local cases = {
  {60, 20, "tiny", 3},
  {80, 50, "narrow-tall", 3},
  {160, 24, "wide-short", 3},
  {180, 45, "wide-tall", 3},
}
for _, case in ipairs(cases) do
  local grid, metadata = page:render(case[1], case[2], {
    active_tab = "overview",
    paused = false,
    frequency_label = "更新频率：中",
    capabilities = {truecolor = true, unicode = true},
    widgets = {
      cpu = {label = "处理器", value = 31.5, unit = "%", history = {1, 4, 2, 8}},
      memory = {label = "内存", value = 42, unit = "%", history = {2, 3, 4}},
      pressure = {label = "压力", value = 0.4, unit = "%", history = {0, nil, 0.4}},
    },
    status = {data_age = "fresh 30ms"},
  })
  equal(grid.width, case[1]); equal(grid.height, case[2])
  equal(metadata.mode, case[3]); equal(#metadata.layout.placements, case[4])
  assert(grid:assert_valid())
  equal(Width.display_width(grid:row_text(1)), case[1], "tab bar cell width")
  assert(metadata.tabs.frequency and metadata.tabs.frequency.width > 0,
    "top-right update frequency must expose a mouse hitbox")
  assert(grid:row_text(1):find("更新频率", 1, true),
    "top-right header must name the update frequency instead of live seconds")
  equal(Width.display_width(grid:row_text(case[2])), case[1], "status bar cell width")
end

local compact_frequency_grid, compact_frequency_metadata = page:render(40, 10, {
  active_tab = "overview",
  frequency_label = "更新频率：非常高",
  capabilities = {truecolor = true, unicode = true},
  widgets = {},
})
assert(compact_frequency_grid:row_text(1):find("更新频率：非常高", 1, true),
  "40-column terminals must retain the complete longest Chinese frequency label")
assert(compact_frequency_metadata.tabs.frequency.width == 16)

-- Page chrome consumes the injected translator facade without importing a
-- concrete locale module, so compiled YAML catalogues remain an app concern.
local translated_page = Overview.new()
local translated_grid = translated_page:render(80, 50, {
  active_tab = "overview",
  i18n = {t = function(_, id)
    return ({["app.name"] = "水面", ["tabs.overview"] = "概览",
      ["status.live"] = "实时", ["metrics.cpu"] = "处理器"})[id] or id
  end},
})
assert(translated_grid:row_text(1):find("概览", 1, true))

print("test_ui_layout: ok")
