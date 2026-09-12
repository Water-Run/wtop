local Chart = require("wtop.ui.widgets.chart")
local Sparkline = require("wtop.ui.widgets.sparkline")
local Util = require("wtop.ui.widgets.util")
local Width = require("wtop.ui.renderer.width")

local M = {}

-- Data quality, not severity.  Colour used to carry this, which meant a CPU at
-- 2% and a CPU at 100% rendered identically; quality now owns the symbol and
-- severity owns the colour, so the two signals stay independent.
local status_tokens = {
  good = "metric.good", ok = "metric.good", fresh = "metric.good",
  warn = "metric.warn", stale = "metric.warn", estimated = "metric.warn",
  partial = "metric.warn", truncated = "metric.warn",
  critical = "metric.critical", error = "metric.critical", denied = "metric.critical",
  unavailable = "text.muted", gap = "text.muted",
}

local status_symbols = {
  good = "●", ok = "●", fresh = "●", warn = "!", stale = "~",
  estimated = "~", partial = "~", truncated = "~",
  critical = "!", error = "×", denied = "×",
  unavailable = "-", gap = "·",
}

local SEVERITY_TOKENS = {
  normal = "accent.primary",
  elevated = "metric.warn",
  critical = "metric.critical",
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

--- Classify a value against its thresholds.
-- `invert` marks metrics where a low reading is the bad one (battery charge,
-- free capacity), so one comparison serves both directions.
function M.severity(value, thresholds, invert)
  if not finite(value) or type(thresholds) ~= "table" then return "normal" end
  local warn, critical = thresholds.warn, thresholds.critical
  if invert then
    if finite(critical) and value <= critical then return "critical" end
    if finite(warn) and value <= warn then return "elevated" end
    return "normal"
  end
  if finite(critical) and value >= critical then return "critical" end
  if finite(warn) and value >= warn then return "elevated" end
  return "normal"
end

local function value_token(model)
  if model.quality == "unavailable" or model.quality == "denied"
      or model.quality == "gap" or model.value == nil then
    return "text.muted"
  end
  return SEVERITY_TOKENS[M.severity(model.value, model.thresholds, model.severity_invert)]
    or "accent.primary"
end

local function render_gauge(grid, x, y, width, value, minimum, maximum, context, token, surface)
  if width < 1 or not finite(value) or not finite(minimum) or not finite(maximum)
      or maximum <= minimum then
    return false
  end
  local fraction = math.max(0, math.min(1, (value - minimum) / (maximum - minimum)))
  local filled = math.floor(width * fraction + 0.5)
  if fraction > 0 and filled == 0 then filled = 1 end
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

-- Short scale labels for a chart's vertical extent.  Percentages and byte
-- rates arrive pre-formatted through `axis_format`; everything else falls back
-- to a compact numeric form.
local function axis_label(model, value)
  if type(model.axis_format) == "function" then
    local ok, text = pcall(model.axis_format, value)
    if ok and type(text) == "string" then return text end
  end
  if not finite(value) then return "" end
  local magnitude = math.abs(value)
  if magnitude >= 1000000 then return string.format("%.1fM", value / 1000000) end
  if magnitude >= 1000 then return string.format("%.1fk", value / 1000) end
  if magnitude >= 100 then return string.format("%d", math.floor(value + 0.5)) end
  if magnitude >= 10 then return string.format("%.0f", value) end
  return string.format("%.1f", value)
end

local function render_chart(grid, area, model, context, token, surface)
  local chart_mode = context.chart_mode == "ascii" and "ascii" or "block"
  local label_width = 0
  local scale_preview
  if area.width >= 22 then
    _, scale_preview = Chart.render(model.history, 1, 1,
      { min = model.min, max = model.max, mode = chart_mode })
    local top = axis_label(model, scale_preview.maximum)
    local bottom = axis_label(model, scale_preview.minimum)
    label_width = math.max(Width.display_width(top, grid.width_options),
      Width.display_width(bottom, grid.width_options))
    if label_width > 0 then label_width = label_width + 1 end
    if label_width > math.floor(area.width / 3) then label_width = 0 end
  end

  local plot_width = area.width - label_width
  if plot_width < 4 then
    plot_width, label_width = area.width, 0
  end
  local rows, scale = Chart.render(model.history, plot_width, area.height, {
    min = model.min,
    max = model.max,
    mode = chart_mode,
    gap = chart_mode == "ascii" and " " or "·",
  })
  local chart_style = Util.style(context, token, surface)
  for index, row in ipairs(rows) do
    grid:write(area.x + label_width, area.y + index - 1, row, chart_style, plot_width)
  end
  if label_width > 0 then
    local muted = Util.style(context, "text.muted", surface)
    -- A flat series has no measured span, so only the value it actually holds
    -- is labelled; printing a synthesised ceiling would invent a scale.
    if not scale.flat then
      grid:write(area.x, area.y, axis_label(model, scale.maximum), muted, label_width - 1)
    end
    if area.height > 1 then
      grid:write(area.x, area.y + area.height - 1, axis_label(model, scale.minimum),
        muted, label_width - 1)
    end
  end
  return true
end

function M.render(grid, area, model, context, variant)
  context, model, variant = context or {}, model or {}, variant or "full"
  area = Util.clip_rect(grid, area)
  if area.width < 1 or area.height < 1 then return end
  local status = model.status or model.quality or "fresh"
  local quality_token = status_tokens[status] or "text.primary"
  local token = value_token(model)
  local surface = context.surface or "surface.raised"
  local label_style = Util.style(context, "text.muted", surface)
  local value_style = Util.style(context, token, surface, { bold = true })
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
    local written = grid:write(area.x, row, Util.truncate(grid, text, area.width),
      value_style, area.width)
    -- A short secondary reading (peak, total, capacity) rides on the value row
    -- when there is room, instead of spending another line on it.
    if model.secondary_value then
      local secondary = tostring(model.secondary_value)
      local used = written - area.x
      local space = area.width - used - 2
      if space >= Width.display_width(secondary, grid.width_options) then
        grid:write(area.x + area.width - Width.display_width(secondary, grid.width_options),
          row, secondary, Util.style(context, "text.muted", surface), space)
      end
    end
    row = row + 1
  end

  if (variant == "full" or variant == "spark") and row <= bottom then
    if render_gauge(grid, area.x, row, area.width, model.value,
        model.min, model.max, context, token, surface) then
      row = row + 1
    end
  end

  if variant == "compact" or not model.history or row > bottom then
    return
  end

  -- A resource this host does not have should not be given a chart: an empty
  -- plot labelled "1 Hz" reads as a broken reading rather than an absent
  -- sensor.
  local has_samples = false
  for index = 1, (model.history.n or 0) do
    if finite(model.history[index]) then
      has_samples = true
      break
    end
  end
  if not has_samples then
    if row <= bottom then
      grid:write(area.x, row, Util.truncate(grid,
        tostring(model.unavailable_text
          or Util.t(context, "ui.not_present", "no samples on this host")), area.width),
        Util.style(context, "text.muted", surface), area.width)
    end
    return
  end

  local chart_height = bottom - row + 1
  -- Below three rows a real plot is noise; keep the familiar single-row
  -- sparkline pinned to the bottom edge so short cards stay rhythmic.
  if chart_height >= 3 and area.width >= 8 and variant == "full" then
    render_chart(grid, { x = area.x, y = row, width = area.width, height = chart_height },
      model, context, quality_token == "text.muted" and "text.muted" or token, surface)
  else
    local spark = Sparkline.render(model.history, area.width, {
      mode = context.chart_mode == "ascii" and "ascii" or "block",
      min = model.min,
      max = model.max,
      gap = context.chart_mode == "ascii" and " " or "·",
      pad = true,
    })
    grid:write(area.x, bottom, spark, Util.style(context, token, surface), area.width)
  end
end

M.status_tokens = status_tokens
M.status_symbols = status_symbols
M.SEVERITY_TOKENS = SEVERITY_TOKENS

return M
