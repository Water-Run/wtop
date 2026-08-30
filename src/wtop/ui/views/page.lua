local Grid = require("wtop.ui.renderer.grid")
local Layout = require("wtop.ui.layout")
local Theme = require("wtop.ui.theme")
local Registry = require("wtop.ui.widgets")
local Panel = require("wtop.ui.widgets.panel")
local TabBar = require("wtop.ui.widgets.tab_bar")
local StatusBar = require("wtop.ui.widgets.status_bar")
local Util = require("wtop.ui.widgets.util")

local Page = {}
Page.__index = Page

local function merge(...)
  local result = {}
  for index = 1, select("#", ...) do
    for key, value in pairs(select(index, ...) or {}) do result[key] = value end
  end
  return result
end

function Page.new(specification)
  specification = specification or {}
  assert(specification.layout, "page requires a layout tree")
  local registry = specification.registry or Registry.new(specification.renderers)
  return setmetatable({
    id = specification.id or "page",
    layout = specification.layout,
    widgets = specification.widgets or {},
    tabs = specification.tabs or {},
    registry = registry,
    theme_name = specification.theme or Theme.DEFAULT,
    header = specification.header ~= false,
    footer = specification.footer ~= false,
    brand = specification.brand,
  }, Page)
end

local function normalise_render_arguments(columns, rows, state)
  if type(columns) == "table" then
    state = columns
    columns = state.columns or state.cols or (state.session and state.session.terminal and state.session.terminal.columns)
    rows = state.rows or (state.session and state.session.terminal and state.session.terminal.rows)
  end
  return assert(tonumber(columns), "render columns are required"),
    assert(tonumber(rows), "render rows are required"), state or {}
end

function Page:render(columns, rows, state)
  columns, rows, state = normalise_render_arguments(columns, rows, state)
  columns, rows = math.max(1, math.floor(columns)), math.max(1, math.floor(rows))
  local capabilities = state.capabilities or (state.session and state.session.terminal) or {}
  local theme = state.theme
  if not theme or type(theme.style) ~= "function" then
    theme = Theme.new(state.theme_name or self.theme_name, capabilities)
  end
  local context = merge(state.context, {
    theme = theme,
    i18n = state.i18n,
    capabilities = capabilities,
    chart_mode = capabilities.unicode == false and "ascii" or state.chart_mode,
  })
  local background = theme:style("text.primary", "surface.base")
  local grid = Grid.new(columns, rows, {
    default_style = background,
    width_fn = state.width_fn,
    ambiguous_is_wide = state.ambiguous_is_wide,
    unicode = capabilities.unicode,
  })

  local header_height = self.header and 1 or 0
  local footer_height = self.footer and 1 or 0
  local navigation = state.navigation or {}
  local session = state.session or {}
  local layout = Layout.solve(self.layout, columns, rows, {
    header_height = header_height,
    footer_height = footer_height,
    focus_id = state.focus_id or navigation.focus_id,
  })
  local tab_metadata, status_metadata
  if header_height > 0 then
    tab_metadata = TabBar.render(grid, {x = 1, y = 1, width = columns, height = 1}, {
      brand = state.brand or self.brand,
      tabs = state.tabs or navigation.tabs or self.tabs,
      active = state.active_tab or navigation.active_tab or self.id,
      paused = state.paused == true or session.paused == true,
      frequency_label = state.frequency_label or session.frequency_label,
      alert_count = state.alert_count,
    }, context)
  end
  if footer_height > 0 then
    local status = merge(state.status, {
      layout = {
        visible = #layout.placements,
        total = #layout.placements + #layout.hidden,
      },
    })
    status_metadata = StatusBar.render(grid, {x = 1, y = rows, width = columns, height = 1},
      status, context)
  end
  local live_models = state.widgets or (state.telemetry and state.telemetry.widgets) or {}
  for _, placement in ipairs(layout.placements) do
    local node = placement.node
    local model = merge(node.model, self.widgets[placement.id], live_models[placement.id], {
      id = placement.id,
      focused = placement.focused,
    })
    local area = {
      x = placement.x, y = placement.y,
      width = placement.width, height = placement.height,
    }
    if node.panel == false then
      grid:fill(area, " ", theme:style("text.primary", "surface.raised"))
      self.registry:render(placement.kind, grid, area, model, context, placement.variant)
    else
      local panel_model = {
        title = node.panel_title or model.panel_title,
        border = node.border == true or model.border == true,
        focused = placement.focused,
      }
      Panel.render(grid, area, panel_model, context, function(target, inner, _, panel_context)
        self.registry:render(placement.kind, target, inner, model, panel_context, placement.variant)
      end)
    end
  end

  return grid, {
    layout = layout,
    mode = layout.mode,
    tabs = tab_metadata,
    status = status_metadata,
    theme = theme,
  }
end

return Page
