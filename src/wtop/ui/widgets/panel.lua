local Util = require("wtop.ui.widgets.util")

local M = {}

local function copy(source)
  local result = {}
  for key, value in pairs(source or {}) do result[key] = value end
  return result
end

local function border_glyphs(context)
  if context.capabilities and context.capabilities.unicode == false then
    return {top_left = "+", top_right = "+", bottom_left = "+", bottom_right = "+",
      horizontal = "-", vertical = "|"}
  end
  return {top_left = "╭", top_right = "╮", bottom_left = "╰", bottom_right = "╯",
    horizontal = "─", vertical = "│"}
end

function M.render(grid, area, model, context, content_renderer)
  context = context or {}
  model = model or {}
  area = Util.clip_rect(grid, area)
  if area.width < 1 or area.height < 1 then return nil end
  -- Focus lives on the frame/title instead of tinting an entire large card.
  -- This keeps dense dashboards calm while retaining a strong keyboard cue.
  local surface = "surface.raised"
  local raised = Util.style(context, "text.primary", surface)
  grid:fill(area, " ", raised)

  local inner = {x = area.x, y = area.y, width = area.width, height = area.height}
  local border = model.border == true and area.width >= 4 and area.height >= 3
  if border then
    local glyph = border_glyphs(context)
    local border_style = Util.style(context,
      model.focused and "accent.primary" or "border.subtle", surface, {bold = model.focused == true})
    grid:set(area.x, area.y, glyph.top_left, border_style, 1)
    grid:set(area.x + area.width - 1, area.y, glyph.top_right, border_style, 1)
    grid:set(area.x, area.y + area.height - 1, glyph.bottom_left, border_style, 1)
    grid:set(area.x + area.width - 1, area.y + area.height - 1, glyph.bottom_right, border_style, 1)
    for x = area.x + 1, area.x + area.width - 2 do
      grid:set(x, area.y, glyph.horizontal, border_style, 1)
      grid:set(x, area.y + area.height - 1, glyph.horizontal, border_style, 1)
    end
    for y = area.y + 1, area.y + area.height - 2 do
      grid:set(area.x, y, glyph.vertical, border_style, 1)
      grid:set(area.x + area.width - 1, y, glyph.vertical, border_style, 1)
    end
    inner = {x = area.x + 1, y = area.y + 1, width = area.width - 2, height = area.height - 2}
    -- A little breathing room materially improves wide panels, but retaining
    -- every cell on narrow cards keeps their values and table columns useful.
    if inner.width >= 12 then
      inner.x, inner.width = inner.x + 1, inner.width - 2
    end

    -- Put the title into the frame instead of spending a content row on it.
    if model.title and area.width >= 6 then
      local title = Util.truncate(grid, tostring(model.title), area.width - 6)
      if title ~= "" then
        local title_style = Util.style(context,
          model.focused and "accent.primary" or "text.primary", surface, {bold = true})
        grid:write(area.x + 2, area.y, " " .. title .. " ", title_style, area.width - 4)
      end
    end
  end

  if not border and model.title and inner.height > 0 then
    local title_style = Util.style(context, model.focused and "accent.primary" or "text.muted", surface,
      {bold = model.focused == true})
    local title = Util.truncate(grid, tostring(model.title), inner.width)
    grid:write(inner.x, inner.y, title, title_style, inner.width)
    inner.y, inner.height = inner.y + 1, inner.height - 1
  end
  if content_renderer and inner.width > 0 and inner.height > 0 then
    local content_context = copy(context)
    content_context.surface = surface
    content_context.panel_title = model.title ~= nil
    content_renderer(grid, inner, model, content_context)
  end
  return inner
end

return M
