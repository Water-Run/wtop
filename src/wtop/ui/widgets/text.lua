local Util = require("wtop.ui.widgets.util")

local M = {}

local function lines(text)
  local result = {}
  text = tostring(text or "")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    result[#result + 1] = line
  end
  return result
end

function M.render(grid, area, model, context, variant)
  context, model = context or {}, model or {}
  area = Util.clip_rect(grid, area)
  local style = Util.style(context, model.muted and "text.muted" or "text.primary",
    context.surface or "surface.raised")
  local content = model.text or model.value or ""
  local row = area.y
  for _, line in ipairs(lines(content)) do
    if row > area.y + area.height - 1 then break end
    grid:write(area.x, row, Util.truncate(grid, line, area.width), style, area.width)
    row = row + 1
    if variant == "value" then break end
  end
end

return M
