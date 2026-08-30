local Width = require("wtop.ui.renderer.width")

local M = {}

function M.style(context, foreground, background, attributes)
  if context.theme and context.theme.style then
    return context.theme:style(foreground, background, attributes)
  end
  local result = attributes or {}
  result.fg_token, result.bg_token = foreground, background
  return result
end

function M.t(context, id, fallback, variables)
  if context.i18n and type(context.i18n.t) == "function" then
    local ok, translated = pcall(context.i18n.t, context.i18n, id, variables)
    if ok and translated and translated ~= id then
      return translated
    end
  end
  return fallback or id
end

function M.clip_rect(grid, area)
  local x = math.max(1, math.floor(area.x or 1))
  local y = math.max(1, math.floor(area.y or 1))
  local right = math.min(grid.width, math.floor((area.x or 1) + (area.width or 0) - 1))
  local bottom = math.min(grid.height, math.floor((area.y or 1) + (area.height or 0) - 1))
  return {x = x, y = y, width = math.max(0, right - x + 1), height = math.max(0, bottom - y + 1)}
end

function M.truncate(grid, text, width, ellipsis)
  if ellipsis == nil and grid and grid.width_options
      and grid.width_options.unicode == false then
    ellipsis = "."
  end
  return Width.truncate(text, width, grid.width_options, ellipsis)
end

return M
