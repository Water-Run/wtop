-- Array of labelled proportional bars: per-core CPU, per-battery charge,
-- per-filesystem usage.  htop's per-core meters are the reference; a numeric
-- table of the same data is far harder to scan.
local Metric = require("wtop.ui.widgets.metric")
local Util = require("wtop.ui.widgets.util")
local Width = require("wtop.ui.renderer.width")

local M = {}

local MAX_ROWS = 512

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function severity_token(item, model)
  if item.token then return item.token end
  if not finite(item.value) then return "text.muted" end
  local severity = Metric.severity(item.value,
    item.thresholds or model.thresholds, model.severity_invert)
  return Metric.SEVERITY_TOKENS[severity] or "accent.primary"
end

local function draw_bar(grid, x, y, width, fraction, context, token, surface)
  if width < 1 then return end
  local unicode = not (context.capabilities and context.capabilities.unicode == false)
  local on, off = unicode and "━" or "#", unicode and "─" or "-"
  local filled = 0
  if finite(fraction) then
    filled = math.floor(width * math.max(0, math.min(1, fraction)) + 0.5)
    if fraction > 0 and filled == 0 then filled = 1 end
  end
  if filled > 0 then
    grid:write(x, y, string.rep(on, filled), Util.style(context, token, surface), filled)
  end
  if filled < width then
    grid:write(x + filled, y, string.rep(off, width - filled),
      Util.style(context, "border.subtle", surface), width - filled)
  end
end

function M.render(grid, area, model, context, variant)
  context, model = context or {}, model or {}
  area = Util.clip_rect(grid, area)
  if area.width < 1 or area.height < 1 then return end
  local surface = context.surface or "surface.raised"
  local items = {}
  for _, item in ipairs(type(model.items) == "table" and model.items or {}) do
    if #items >= MAX_ROWS then break end
    if type(item) == "table" then items[#items + 1] = item end
  end
  if #items == 0 then
    grid:write(area.x, area.y, Util.truncate(grid,
      tostring(model.empty_text or Util.t(context, "ui.no_data", "No data")), area.width),
      Util.style(context, "text.muted", surface), area.width)
    return { rows = 0, columns = 0 }
  end

  local minimum = finite(model.min) and model.min or 0
  local maximum = finite(model.max) and model.max or 100

  local label_width, value_width = 0, 0
  for _, item in ipairs(items) do
    label_width = math.max(label_width,
      Width.display_width(tostring(item.label or ""), grid.width_options))
    value_width = math.max(value_width,
      Width.display_width(tostring(item.display_value or ""), grid.width_options))
  end
  label_width = math.min(label_width, 12)
  value_width = math.min(value_width, 10)

  -- Spend the panel's height before its width: a longer bar resolves more
  -- detail than a second column does, so start with the fewest columns that
  -- fit vertically and only widen when a cell would be too narrow to read.
  local minimum_cell = label_width + value_width + 6
  local gap = 2
  local maximum_columns = math.max(1, math.min(tonumber(model.max_columns) or 8, #items))
  local columns = math.max(1, math.ceil(#items / math.max(1, area.height)))
  columns = math.min(columns, maximum_columns)
  local function cell_for(count)
    return math.floor((area.width - gap * (count - 1)) / count)
  end
  while columns < maximum_columns and cell_for(columns) > minimum_cell * 2 do
    -- Very wide panels would otherwise draw four cores as four enormous bars
    -- with most of the row empty.
    columns = columns + 1
  end
  while columns > 1 and cell_for(columns) < minimum_cell do
    columns = columns - 1
  end
  local rows_needed = math.ceil(#items / columns)
  local cell_width = cell_for(columns)
  if cell_width < 4 then
    columns, cell_width = 1, area.width
    rows_needed = #items
  end

  local drawn = 0
  for index, item in ipairs(items) do
    local column = (index - 1) // rows_needed
    local row = (index - 1) % rows_needed
    if column >= columns then break end
    local y = area.y + row
    if y > area.y + area.height - 1 then break end
    local x = area.x + column * (cell_width + gap)
    local token = severity_token(item, model)

    local cursor = x
    local remaining = cell_width
    if label_width > 0 and remaining > label_width + 2 then
      local label = Util.truncate(grid, tostring(item.label or ""), label_width)
      grid:write(cursor, y, label, Util.style(context, "text.muted", surface), label_width)
      cursor = cursor + label_width + 1
      remaining = remaining - label_width - 1
    end
    local text = tostring(item.display_value or "")
    local text_width = math.min(value_width, math.max(0, remaining - 3))
    local bar_width = remaining - (text_width > 0 and text_width + 1 or 0)
    if bar_width > 0 then
      local fraction
      if finite(item.fraction) then
        fraction = item.fraction
      elseif finite(item.value) and maximum > minimum then
        fraction = (item.value - minimum) / (maximum - minimum)
      end
      draw_bar(grid, cursor, y, bar_width, fraction, context, token, surface)
      cursor = cursor + bar_width + 1
    end
    if text_width > 0 then
      local truncated = Util.truncate(grid, text, text_width)
      local pad = text_width - Width.display_width(truncated, grid.width_options)
      grid:write(cursor, y, string.rep(" ", math.max(0, pad)) .. truncated,
        Util.style(context, token, surface), text_width)
    end
    drawn = drawn + 1
  end

  return { rows = rows_needed, columns = columns, drawn = drawn, total = #items }
end

return M
