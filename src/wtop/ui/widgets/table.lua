local Util = require("wtop.ui.widgets.util")
local Width = require("wtop.ui.renderer.width")

local M = {}

local MAX_COLUMNS = 64

local function bounded_width(value, fallback, maximum)
  if type(value) ~= "number" or value ~= value or value == math.huge
      or value == -math.huge then
    return fallback
  end
  return math.max(1, math.min(maximum, math.floor(value)))
end

local function cell_text(row, column)
  if type(row) ~= "table" then return "—" end
  local value = row[column.key or column.id or column[1]]
  if type(column.format) == "function" then
    local ok, formatted = pcall(column.format, value, row)
    value = ok and formatted or "—"
  end
  return tostring(value == nil and "—" or value)
end

local function aligned(grid, text, width, alignment)
  text = Util.truncate(grid, text, width)
  if alignment == "right" then
    return string.rep(" ", math.max(0, width - Width.display_width(text, grid.width_options))) .. text
  end
  return text
end

function M.render(grid, area, model, context, variant)
  context, model = context or {}, model or {}
  area = Util.clip_rect(grid, area)
  local columns = type(model.columns) == "table" and model.columns or {}
  local visible = {}
  local used = 0
  for _, column in ipairs(columns) do
    if #visible >= MAX_COLUMNS then break end
    if type(column) == "table" and (variant == "full" or not column.full_only) then
      local minimum = bounded_width(column.min_width, 6, math.max(1, area.width))
      local required = minimum + (#visible > 0 and 1 or 0)
      if used + required <= area.width then
        visible[#visible + 1] = {
          source = column,
          width = minimum,
          preferred = math.max(minimum,
            bounded_width(column.width, minimum, math.max(1, area.width))),
        }
        used = used + required
      end
    end
  end
  -- Even an extremely narrow table should communicate which field it is
  -- showing instead of rendering an empty panel.
  if #visible == 0 and area.width > 0 then
    for _, column in ipairs(columns) do
      if type(column) == "table" and (variant == "full" or not column.full_only) then
        visible[1] = {source = column, width = area.width, preferred = area.width}
        used = area.width
        break
      end
    end
  end
  if #visible == 0 or area.height < 1 then return end

  -- Select columns at their minima first, then share spare cells fairly.
  -- The old greedy preferred-width allocation let an early name/path column
  -- consume the viewport before CPU, memory, rate, or state columns were even
  -- considered.
  local remaining = math.max(0, area.width - used)
  while remaining > 0 do
    local changed = false
    for _, column in ipairs(visible) do
      if remaining == 0 then break end
      if column.width < column.preferred then
        column.width = column.width + 1
        remaining = remaining - 1
        changed = true
      end
    end
    if not changed then break end
  end

  local y = area.y
  local x = area.x
  local surface = context.surface or "surface.raised"
  local header_style = Util.style(context, "text.muted", "surface.header", {bold = true})
  grid:fill({x = area.x, y = y, width = area.width, height = 1}, " ", header_style)
  for _, column in ipairs(visible) do
    local label = aligned(grid, tostring(column.source.label or column.source.key),
      column.width, column.source.align)
    grid:write(x, y, label,
      header_style, column.width)
    x = x + column.width + 1
  end
  y = y + 1
  local rows = type(model.rows) == "table" and model.rows or {}
  local offset = tonumber(model.offset)
  if not offset or offset ~= offset or offset == math.huge or offset == -math.huge then offset = 0 end
  offset = math.max(0, math.min(#rows, math.floor(offset)))
  local bottom = area.y + area.height - 1
  local status_text = model.status_text and tostring(model.status_text) or ""
  local show_status = status_text ~= "" and variant == "full" and area.height >= 3
  local data_bottom = show_status and bottom - 1 or bottom
  for index = offset + 1, #rows do
    local row = rows[index]
    if y > data_bottom then break end
    local selected = index == model.selected
    local row_surface = selected and "surface.selected"
      or (((index - offset) % 2 == 0) and "surface.row_alt" or surface)
    local style = Util.style(context, selected and "accent.primary" or "text.primary",
      row_surface, {bold = selected})
    grid:fill({x = area.x, y = y, width = area.width, height = 1}, " ", style)
    x = area.x
    for _, column in ipairs(visible) do
      local text = aligned(grid, cell_text(row, column.source), column.width, column.source.align)
      grid:write(x, y, text, style, column.width)
      x = x + column.width + 1
    end
    y = y + 1
  end
  if #rows == 0 and y <= data_bottom then
    local empty = model.empty_text or Util.t(context, "ui.no_data", "No data")
    grid:write(area.x, y, Util.truncate(grid, tostring(empty), area.width),
      Util.style(context, "text.muted", surface), area.width)
  end
  if show_status then
    grid:write(area.x, bottom, Util.truncate(grid, status_text, area.width),
      Util.style(context, "text.muted", surface, {dim = true}), area.width)
  end
end

return M
