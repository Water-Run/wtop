local Util = require("wtop.ui.widgets.util")
local Width = require("wtop.ui.renderer.width")

local M = {}

local default_hints = {
  {key = "/", id = "actions.search", fallback = "Search"},
  {key = "e", id = "actions.edit_layout", fallback = "Layout"},
  {key = "Space", id = "actions.pause", fallback = "Pause"},
  {key = "?", id = "actions.help", fallback = "Help"},
  {key = "q", id = "actions.quit", fallback = "Quit"},
}

function M.render(grid, area, state, context)
  context, state = context or {}, state or {}
  area = Util.clip_rect(grid, area)
  if area.width < 1 or area.height < 1 then return {} end
  local surface = "surface.raised"
  local base = Util.style(context, "text.muted", surface)
  local key_style = Util.style(context, "accent.primary", surface, {bold = true})
  grid:fill(area, " ", base)

  local unicode = not (context.capabilities and context.capabilities.unicode == false)
  local separator = unicode and " · " or " | "
  local right = state.error or state.message
  local has_priority_message = right ~= nil or (state.filter and state.filter ~= "")
  if not right and state.data_age then right = tostring(state.data_age) end
  if state.filter and state.filter ~= "" then
    right = (right and (tostring(state.filter) .. separator .. tostring(right))) or tostring(state.filter)
  end
  local layout = state.layout
  local layout_total = layout and tonumber(layout.total)
  local layout_visible = layout and tonumber(layout.visible)
  if layout_total and layout_visible and layout_total > layout_visible then
    local layout_state = string.format("%s %d/%d", unicode and "▦" or "[]",
      layout_visible, layout_total)
    right = right and (layout_state .. separator .. tostring(right)) or layout_state
  end
  right = tostring(right or "")
  if state.error and right ~= "" then right = "! " .. right end
  local ratio = has_priority_message and (area.width < 56 and 0.72 or 0.58) or 0.38
  local right_limit = math.max(0, math.floor(area.width * ratio))
  right = Util.truncate(grid, right, right_limit)
  local right_width = Width.display_width(right, grid.width_options)
  local right_x = area.x + area.width - right_width
  if right_width > 0 then
    local token = state.error and "metric.critical" or (state.warning and "metric.warn" or "text.muted")
    grid:write(right_x, area.y, right, Util.style(context, token, surface,
      {bold = state.error ~= nil or state.warning == true}),
      right_width)
  end

  local cursor = area.x
  local hints = state.hints or default_hints
  local rendered = {}
  for _, hint in ipairs(hints) do
    local label = hint.label or Util.t(context, hint.id or "", hint.fallback or hint.command or "")
    local key = tostring(hint.key or "")
    label = tostring(label)
    local key_width = Width.display_width(key, grid.width_options)
    local label_width = Width.display_width(label, grid.width_options)
    local leading = #rendered > 0 and separator or ""
    local leading_width = Width.display_width(leading, grid.width_options)
    local full_width = leading_width + key_width + (label ~= "" and 1 + label_width or 0)
    local compact_width = leading_width + key_width
    local boundary = right_x - 1
    local show_label = cursor + full_width <= boundary
    if show_label or cursor + compact_width <= boundary then
      local start = cursor
      if leading_width > 0 then
        grid:write(cursor, area.y, leading, base, leading_width)
        cursor = cursor + leading_width
      end
      grid:write(cursor, area.y, key, key_style, key_width)
      cursor = cursor + key_width
      if show_label and label ~= "" then
        grid:write(cursor, area.y, " " .. label, base, label_width + 1)
        cursor = cursor + label_width + 1
      end
      rendered[#rendered + 1] = {
        command = hint.command or hint.id,
        x = start,
        width = cursor - start,
        compact = not show_label,
      }
    end
  end
  return {hints = rendered, message_x = right_x}
end

M.default_hints = default_hints

return M
