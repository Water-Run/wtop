local Registry = {}
Registry.__index = Registry

local builtins = {
  text = require("wtop.ui.widgets.text"),
  metric = require("wtop.ui.widgets.metric"),
  gauge = require("wtop.ui.widgets.metric"),
  timeseries = require("wtop.ui.widgets.metric"),
  table = require("wtop.ui.widgets.table"),
  process_table = require("wtop.ui.widgets.table"),
}

function Registry.new(extra)
  local renderers = {}
  for kind, renderer in pairs(builtins) do renderers[kind] = renderer end
  for kind, renderer in pairs(extra or {}) do renderers[kind] = renderer end
  return setmetatable({renderers = renderers}, Registry)
end

function Registry:register(kind, renderer)
  assert(type(kind) == "string" and kind ~= "", "widget kind is required")
  assert(type(renderer) == "function" or (type(renderer) == "table" and type(renderer.render) == "function"),
    "widget renderer must be a function or implement render")
  self.renderers[kind] = renderer
  return self
end

function Registry:render(kind, grid, area, model, context, variant)
  local renderer = self.renderers[kind]
  if not renderer then
    renderer = self.renderers.text
    model = {text = "[unsupported widget: " .. tostring(kind) .. "]", muted = true}
  end
  if type(renderer) == "function" then
    return renderer(grid, area, model, context, variant)
  end
  return renderer.render(grid, area, model, context, variant)
end

Registry.builtins = builtins
Registry.Sparkline = require("wtop.ui.widgets.sparkline")
Registry.Panel = require("wtop.ui.widgets.panel")

return Registry
