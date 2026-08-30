local Sparkline = require("wtop.ui.widgets.sparkline")
local Util = require("wtop.ui.widgets.util")

local M = {}

local status_tokens = {
  good = "metric.good", ok = "metric.good", fresh = "metric.good",
  warn = "metric.warn", stale = "metric.warn", estimated = "metric.warn",
  critical = "metric.critical", error = "metric.critical", denied = "metric.critical",
  unavailable = "text.muted", gap = "text.muted",
}

local status_symbols = {
  good = "●", ok = "●", fresh = "●", warn = "!", stale = "~",
  estimated = "~", critical = "!", error = "×", denied = "×",
  unavailable = "-", gap = "·",
}

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function symbol_for(status, context)
  local symbol = status_symbols[status] or "·"
  if context.capabilities and context.capabilities.unicode == false then
    if symbol == "●" then return "*" end
    if symbol == "×" then return "x" end
    if symbol == "·" then return "." end
  end
  return symbol
end

local function render_gauge(grid, x, y, width, value, minimum, maximum, context, token, surface)
  if width < 1 or not finite(value) or not finite(minimum) or not finite(maximum) or maximum <= minimum then
    return false
  end
  local fraction = math.max(0, math.min(1, (value - minimum) / (maximum - minimum)))
  local filled = math.floor(width * fraction + 0.5)
  local unicode = not (context.capabilities and context.capabilities.unicode == false)
  local on, off = unicode and "━" or "#", unicode and "─" or "-"
  if filled > 0 then
    grid:write(x, y, string.rep(on, filled), Util.style(context, token, surface), filled)
  end
  if filled < width then
    grid:write(x + filled, y, string.rep(off, width - filled),
      Util.style(context, "border.subtle", surface), width - filled)
  end
  return true
end

local function format_value(model)
  if model.display_value ~= nil then return tostring(model.display_value) end
  if model.value == nil then return "—" end
  if type(model.value) == "number" then
    if not finite(model.value) then return "—" end
    local precision = model.precision
    if precision == nil then precision = math.abs(model.value) < 10 and 1 or 0 end
    if type(precision) ~= "number" or not finite(precision) then precision = 0 end
    precision = math.max(0, math.min(9, math.floor(precision)))
    return string.format("%." .. precision .. "f", model.value)
  end
  return tostring(model.value)
end

function M.render(grid, area, model, context, variant)
  context, model, variant = context or {}, model or {}, variant or "full"
  area = Util.clip_rect(grid, area)
  if area.width < 1 or area.height < 1 then return end
  local status = model.status or model.quality or "fresh"
  local token = status_tokens[status] or "text.primary"
  local surface = context.surface or "surface.raised"
  local label_style = Util.style(context, "text.muted", surface)
  local value_style = Util.style(context, token, surface, {bold = true})
  local label = model.label_id
      and Util.t(context, model.label_id, model.label or model.title or model.id or "")
      or (model.label or model.title or model.id or "")
  label = tostring(label)
  local value = format_value(model)
  local unit = model.unit and (" " .. tostring(model.unit)) or ""
  local symbol = symbol_for(status, context)
  local row = area.y
  local bottom = area.y + area.height - 1
  local show_label = context.panel_title ~= true

  if variant == "value" or area.height == 1 then
    local text = show_label and string.format("%s %s %s%s", symbol, label, value, unit)
      or string.format("%s %s%s", symbol, value, unit)
    grid:write(area.x, row, Util.truncate(grid, text, area.width), value_style, area.width)
    return
  end

  if show_label then
    grid:write(area.x, row, Util.truncate(grid, label, area.width), label_style, area.width)
    row = row + 1
  end
  if row <= bottom then
    local text = string.format("%s %s%s", symbol, value, unit)
    grid:write(area.x, row, Util.truncate(grid, text, area.width), value_style, area.width)
    row = row + 1
  end

  if (variant == "full" or variant == "spark") and row < bottom then
    if render_gauge(grid, area.x, row, area.width, model.value,
        model.min, model.max, context, token, surface) then
      row = row + 1
    end
  end

  if variant ~= "compact" and model.history and row <= bottom then
    local spark = Sparkline.render(model.history, area.width, {
      mode = context.chart_mode == "ascii" and "ascii" or "block",
      min = model.min,
      max = model.max,
      gap = context.chart_mode == "ascii" and " " or "·",
      pad = true,
    })
    -- Anchor history to the bottom edge so differently-sized metric cards
    -- retain the same visual rhythm.
    grid:write(area.x, bottom, spark, Util.style(context, token, surface), area.width)
  end
end

M.status_tokens = status_tokens
M.status_symbols = status_symbols

return M
