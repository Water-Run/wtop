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

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
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

-- A column may colour its own cells from the row's data.  Failures fall back
-- to the row style rather than dropping the cell, so a bad accessor degrades
-- the palette instead of the table.
local function cell_token(row, column)
  if type(column.token) == "function" then
    local ok, token = pcall(column.token, row[column.key or column.id], row)
    if ok and type(token) == "string" then return token end
  elseif type(column.token) == "string" then
    return column.token
  end
  return nil
end

local function cell_fraction(row, column)
  if type(column.bar) ~= "function" then return nil end
  local ok, fraction = pcall(column.bar, row[column.key or column.id], row)
  if not ok or not finite(fraction) then return nil end
  return math.max(0, math.min(1, fraction))
end

local function aligned(grid, text, width, alignment)
  text = Util.truncate(grid, text, width)
  local used = Width.display_width(text, grid.width_options)
  if alignment == "right" then
    return string.rep(" ", math.max(0, width - used)) .. text
  elseif alignment == "center" then
    local left = math.floor(math.max(0, width - used) / 2)
    return string.rep(" ", left) .. text
  end
  return text
end

-- Render a value cell as a proportional bar behind its text.  Two cells of
-- headroom keep the number readable; below that the bar is dropped entirely
-- rather than fighting the digits for space.
local function render_bar_cell(grid, x, y, width, text, fraction, style, bar_style, alignment)
  if width < 4 then return false end
  local label = aligned(grid, text, width, alignment)
  local filled = math.max(0, math.min(width, math.floor(width * fraction + 0.5)))
  if filled < 1 then return false end
  grid:write(x, y, label, style, width)
  for offset = 0, filled - 1 do
    local cell = grid:get(x + offset, y)
    local character = cell and not cell.continuation and cell.char or " "
    grid:set(x + offset, y, character, bar_style, 1)
  end
  return true
end


-- Re-style the display cells covered by a matched substring.  Highlighting is
-- applied to the text the widget actually rendered, so truncation and
-- alignment padding are already accounted for.
local function highlight_cell(grid, x, y, text, needles, style, options)
  if type(needles) ~= "table" or #needles == 0 or text == "" then return end
  local lowered = text:lower()
  for _, needle in ipairs(needles) do
    if type(needle) == "string" and needle ~= "" then
      local from = 1
      local guard = 0
      while guard < 16 do
        guard = guard + 1
        local start, finish = lowered:find(needle, from, true)
        if not start then break end
        local before = Width.display_width(text:sub(1, start - 1), options)
        local span = Width.display_width(text:sub(start, finish), options)
        for offset = 0, span - 1 do
          local cell = grid:get(x + before + offset, y)
          if cell and not cell.continuation then
            grid:set(x + before + offset, y, cell.char, style, cell.width or 1)
          end
        end
        from = finish + 1
      end
    end
  end
end

local function cell_highlights(row, column, model)
  if column.highlight == nil then return nil end
  if column.highlight == true then return model.highlights end
  if type(column.highlight) == "function" then
    local ok, needles = pcall(column.highlight, row[column.key or column.id], row)
    if ok and type(needles) == "table" then return needles end
  end
  return nil
end

local function visible_columns(columns, variant, area_width)
  -- Selection runs in priority order so a wide leading name column can no
  -- longer consume the viewport before the numbers it is meant to describe are
  -- considered; rendering still follows the declared order.
  local candidates = {}
  for index, column in ipairs(columns) do
    if type(column) == "table" and (variant == "full" or not column.full_only) then
      candidates[#candidates + 1] = {
        order = index,
        source = column,
        priority = tonumber(column.priority) or (column.full_only and 10 or 50),
      }
    end
  end
  table.sort(candidates, function(left, right)
    if left.priority ~= right.priority then return left.priority > right.priority end
    return left.order < right.order
  end)

  local chosen, used = {}, 0
  for _, candidate in ipairs(candidates) do
    if #chosen >= MAX_COLUMNS then break end
    local minimum = bounded_width(candidate.source.min_width, 6, math.max(1, area_width))
    local required = minimum + (#chosen > 0 and 1 or 0)
    if used + required <= area_width then
      candidate.width = minimum
      candidate.preferred = math.max(minimum,
        bounded_width(candidate.source.width, minimum, math.max(1, area_width)))
      chosen[#chosen + 1] = candidate
      used = used + required
    end
  end

  -- An extremely narrow table should still say which field it is showing.
  if #chosen == 0 and area_width > 0 and candidates[1] then
    candidates[1].width, candidates[1].preferred = area_width, area_width
    chosen[1] = candidates[1]
    used = area_width
  end

  table.sort(chosen, function(left, right) return left.order < right.order end)
  return chosen, used, #candidates
end

function M.render(grid, area, model, context, variant)
  context, model = context or {}, model or {}
  area = Util.clip_rect(grid, area)
  local columns = type(model.columns) == "table" and model.columns or {}
  local visible, used, total_columns = visible_columns(columns, variant, area.width)
  if #visible == 0 or area.height < 1 then
    return { columns_visible = 0, columns_total = total_columns }
  end

  -- Select columns at their minima first, then share spare cells fairly.
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
  local header_style = Util.style(context, "text.muted", "surface.header", { bold = true })
  local sort_style = Util.style(context, "accent.primary", "surface.header", { bold = true })
  grid:fill({ x = area.x, y = y, width = area.width, height = 1 }, " ", header_style)
  local header_boxes = {}
  for _, column in ipairs(visible) do
    local source = column.source
    local label = tostring(source.label or source.key or "")
    local active = model.sort_key ~= nil and source.sort_key == model.sort_key
    if active then
      local unicode = not (context.capabilities and context.capabilities.unicode == false)
      local arrow = model.sort_descending and (unicode and "↓" or "v")
        or (unicode and "↑" or "^")
      label = label .. " " .. arrow
    end
    grid:write(x, y, aligned(grid, label, column.width, source.align),
      active and sort_style or header_style, column.width)
    if source.sort_key then
      header_boxes[#header_boxes + 1] =
        { sort_key = source.sort_key, x = x, width = column.width }
    end
    x = x + column.width + 1
  end
  y = y + 1

  local rows = type(model.rows) == "table" and model.rows or {}
  local offset = tonumber(model.offset)
  if not finite(offset) then offset = 0 end
  offset = math.max(0, math.min(#rows, math.floor(offset)))
  local bottom = area.y + area.height - 1
  local status_text = model.status_text and tostring(model.status_text) or ""
  local unicode = not (context.capabilities and context.capabilities.unicode == false)
  local hidden_columns = total_columns - #visible
  if hidden_columns > 0 and variant == "full" then
    local note = string.format("%s %d/%d", unicode and "▤" or "#", #visible, total_columns)
    status_text = status_text ~= "" and (note .. " · " .. status_text) or note
  end
  -- Rows that did not fit were previously indistinguishable from rows that do
  -- not exist, which is the difference between "this host has eleven
  -- collectors" and "you are looking at eleven of sixteen".
  local body_rows = math.max(0, (status_text ~= "" and variant == "full"
    and area.height >= 3) and area.height - 2 or area.height - 1)
  if #rows > body_rows and body_rows > 0 then
    local note = string.format("%s %d/%d", unicode and "▾" or "v",
      math.min(#rows, offset + body_rows), #rows)
    status_text = status_text ~= "" and (note .. " · " .. status_text) or note
  end
  local show_status = status_text ~= "" and variant == "full" and area.height >= 3
  local data_bottom = show_status and bottom - 1 or bottom
  local data_top = y

  for index = offset + 1, #rows do
    local row = rows[index]
    if y > data_bottom then break end
    local selected = index == model.selected
    local row_surface = selected and "surface.selected"
      or (((index - offset) % 2 == 0) and "surface.row_alt" or surface)
    local base_token = selected and "accent.primary" or "text.primary"
    local style = Util.style(context, base_token, row_surface, { bold = selected })
    grid:fill({ x = area.x, y = y, width = area.width, height = 1 }, " ", style)
    x = area.x
    for _, column in ipairs(visible) do
      local source = column.source
      local token = not selected and cell_token(row, source) or nil
      local cell_style = token and Util.style(context, token, row_surface) or style
      local text = cell_text(row, source)
      local fraction = cell_fraction(row, source)
      local drawn = false
      if fraction then
        local bar_style = Util.style(context, token or base_token,
          selected and "surface.selected" or "surface.focus", { bold = selected })
        drawn = render_bar_cell(grid, x, y, column.width, text, fraction,
          cell_style, bar_style, source.align)
      end
      local rendered = aligned(grid, text, column.width, source.align)
      if not drawn then
        grid:write(x, y, rendered, cell_style, column.width)
      end
      local needles = cell_highlights(row, source, model)
      if needles then
        highlight_cell(grid, x, y, rendered, needles,
          Util.style(context, "metric.warn", row_surface, { bold = true }),
          grid.width_options)
      end
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
      Util.style(context, "text.muted", surface, { dim = true }), area.width)
  end

  -- Geometry the event loop needs for hit-testing and for sizing its own
  -- scroll window; guessing either from the terminal size is what made the
  -- selected row scroll out of view.
  local drawn_rows = math.max(0, data_bottom - data_top + 1)
  return {
    columns_visible = #visible,
    columns_total = total_columns,
    headers = header_boxes,
    header_y = area.y,
    rows_x = area.x,
    rows_y = data_top,
    rows_width = area.width,
    visible_rows = drawn_rows,
    -- Shared shape with the other scrollable widgets so the event loop can
    -- drive any focused panel without knowing which kind it is.
    visible = drawn_rows,
    total = #rows,
    scrollable = #rows > drawn_rows,
    offset = offset,
  }
end

M.visible_columns = visible_columns

return M
