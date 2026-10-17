local Util = require("wtop.ui.widgets.util")
local Width = require("wtop.ui.renderer.width")
local M = {}

function M.indicator(total, width, grid)
  for _, text in ipairs({ "+" .. total .. " · p", "+" .. total, "p" }) do
    if Width.display_width(text, grid.width_options) <= width then return text end
  end
  return ""
end

local function row_lines(row, width, grid)
  local lines
  if Width.display_width(row.heading, grid.width_options) <= width then
    lines = { row.heading }
  else
    lines = { row.identity, row.constraint }
  end
  lines[#lines + 1] = row.reading
  if Width.display_width(row.combined, grid.width_options) <= width then
    lines[#lines + 1] = row.combined
  else
    lines[#lines + 1], lines[#lines + 2] = row.usage, row.headroom
  end
  for _, line in ipairs(lines) do
    if Width.display_width(line, grid.width_options) > width then
      local compact = { row.compact_identity, row.constraint }
      if row.state then compact[#compact + 1] = row.state end
      compact[#compact + 1] = row.reading_compact
      local usage = row.percent_text
      if row.comparison then
        local cells = math.min(8, width - Width.display_width(usage, grid.width_options) - 3)
        if cells > 0 then
          local filled = math.floor(math.min(100, row.comparison.percent) * cells / 100 + 0.5)
          if row.comparison.percent > 0 then filled = math.max(1, filled) end
          usage = "[" .. string.rep("#", filled) .. string.rep("-", cells - filled) .. "] " .. usage
        end
      end
      compact[#compact + 1], compact[#compact + 2] = usage, row.headroom_compact
      for _, text in ipairs(compact) do
        if Width.display_width(text, grid.width_options) > width then return compact, false end
      end
      return compact, true
    end
  end
  return lines, true
end

function M.preview_height(model, width, grid)
  local height, visible = 0, 0
  for index = 1, math.min(2, #(model.rows or {})) do
    local lines, fits = row_lines(model.rows[index], width, grid)
    if not fits then break end
    height, visible = height + #lines, visible + 1
  end
  return height + ((model.total or 0) > visible and 1 or 0)
end

-- A complete reading either fits or is counted as omitted. Truncating a watt
-- value can silently turn 114 W into a different limit.
function M.render(grid, area, model, context)
  area = Util.clip_rect(grid, area)
  local rows, total = model.rows or {}, model.total or #(model.rows or {})
  local y, bottom, visible = area.y, area.y + area.height - 1, 0
  local style = Util.style(context, "text.primary", context.surface or "surface.raised")
  for _, row in ipairs(rows) do
    local lines, fits = row_lines(row, area.width, grid)
    local more = total > visible + 1 and 1 or 0
    if not fits or y + #lines - 1 + more > bottom then break end
    for index = 1, #lines do
      grid:write(area.x, y + index - 1, lines[index], style, area.width)
    end
    y, visible = y + #lines, visible + 1
  end
  local hidden = total - visible
  if hidden > 0 and y <= bottom then
    grid:write(area.x, y, M.indicator(hidden, area.width, grid), style, area.width)
    y = y + 1
  end
  return { visible = visible, hidden = hidden, total = total, next_row = y }
end

return M
