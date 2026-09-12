local Util = require("wtop.ui.widgets.util")
local Width = require("wtop.ui.renderer.width")

local M = {}

local function tab_label(tab, context)
  if tab.label_id then
    return tostring(Util.t(context, tab.label_id, tab.label or tab.title or tab.id or "?"))
  end
  return tostring(tab.label or tab.title or tab.id or "?")
end

local function representation(tab, active, context)
  if active and context.theme and context.theme.mode == "mono" then
    return "[" .. tab_label(tab, context) .. "]"
  end
  return " " .. tab_label(tab, context) .. " "
end

function M.render(grid, area, state, context)
  context, state = context or {}, state or {}
  area = Util.clip_rect(grid, area)
  if area.width < 1 or area.height < 1 then return {tabs = {}} end
  local base = Util.style(context, "text.primary", "surface.raised")
  local muted = Util.style(context, "text.muted", "surface.raised")
  local active_style = Util.style(context, "accent.primary", "surface.focus", {bold = true})
  grid:fill(area, " ", base)

  local brand = tostring(state.brand or Util.t(context, "app.name", "wtop"))
  -- The brand carries the host name, which is the single most useful piece of
  -- context on a screenshot. Twelve columns truncated it on almost every host,
  -- so it now scales with the terminal and yields first on narrow ones.
  brand = Util.truncate(grid, brand,
    math.max(4, math.min(area.width - 8, math.floor(area.width * 0.22))))
  grid:write(area.x, area.y, brand, Util.style(context, "accent.primary", "surface.raised", {bold = true}), area.width)
  local brand_width = Width.display_width(brand, grid.width_options)

  local unicode = not (context.capabilities and context.capabilities.unicode == false)
  local frequency = tostring(state.frequency_label
    or Util.t(context, "sampling.update_frequency", "Update rate"))
  local suffix = ""
  if state.paused then
    suffix = (unicode and " · Ⅱ " or " || ") .. Util.t(context, "status.paused", "Paused")
  end
  if state.alert_count and state.alert_count > 0 then
    suffix = suffix .. " !" .. tostring(state.alert_count)
  end
  -- The frequency control stays first so it remains visible and clickable on
  -- narrow terminals; pause/alert context yields before navigation does.
  local right_limit = math.min(math.max(0, area.width - brand_width - 2),
    math.max(0, math.floor(area.width * 0.42)))
  frequency = Util.truncate(grid, frequency, right_limit, "")
  local frequency_width = Width.display_width(frequency, grid.width_options)
  suffix = Util.truncate(grid, suffix, math.max(0, right_limit - frequency_width))
  local suffix_width = Width.display_width(suffix, grid.width_options)
  local sample_width = frequency_width + suffix_width
  local right_x = area.x + area.width - sample_width
  if frequency_width > 0 then
    grid:write(right_x, area.y, frequency,
      Util.style(context, "accent.primary", "surface.focus", {bold = true}), frequency_width)
  end
  if suffix_width > 0 then
    grid:write(right_x + frequency_width, area.y, suffix,
      Util.style(context, state.paused and "metric.warn" or "metric.good", "surface.raised", {bold = true}),
      suffix_width)
  end

  local left = area.x + brand_width + (brand_width > 0 and 1 or 0)
  local available = math.max(0, right_x - left - 1)
  local tabs = state.tabs or {}
  local active_index = 1
  for index, tab in ipairs(tabs) do
    if tab.id == state.active or index == state.active then active_index = index end
  end
  local selected, used = {}, 0
  local function try_add(index, required)
    if index < 1 or index > #tabs or selected[index] then return false end
    local text = representation(tabs[index], index == active_index, context)
    local width = Width.display_width(text, grid.width_options)
    if width > available - used then
      if not required or available - used < 1 then return false end
      text = Util.truncate(grid, text, available - used)
      width = Width.display_width(text, grid.width_options)
    end
    selected[index] = {text = text, width = width}
    used = used + width
    return true
  end
  try_add(active_index, true)
  local distance = 1
  while distance < #tabs do
    local changed = try_add(active_index - distance)
    changed = try_add(active_index + distance) or changed
    if not changed and used >= available then break end
    distance = distance + 1
  end

  local hitboxes, cursor = {}, left
  local previous_glyph, next_glyph = unicode and "‹" or "<", unicode and "›" or ">"
  local first_visible, last_visible
  for index = 1, #tabs do
    local selected_tab = selected[index]
    if selected_tab then
      first_visible, last_visible = first_visible or index, index
    end
  end
  if first_visible and first_visible > 1 and available > 0 then
    grid:write(cursor, area.y, previous_glyph, muted, 1)
    cursor = cursor + 1
  end
  for index = 1, #tabs do
    local selected_tab = selected[index]
    if selected_tab and cursor < right_x then
      local room = right_x - cursor
      local text = Util.truncate(grid, selected_tab.text, room, "")
      local width = Width.display_width(text, grid.width_options)
      grid:write(cursor, area.y, text, index == active_index and active_style or muted, width)
      hitboxes[#hitboxes + 1] = {id = tabs[index].id, index = index, x = cursor, width = width}
      cursor = cursor + width
    end
  end
  -- Preserve one quiet cell before the live sampler; an overflow chevron
  -- touching the status dot reads as one accidental symbol on narrow screens.
  if last_visible and last_visible < #tabs and cursor < right_x - 1 then
    grid:write(cursor, area.y, next_glyph, muted, 1)
  end
  return {
    tabs = hitboxes,
    active_index = active_index,
    sample_x = right_x,
    frequency = frequency_width > 0 and {x = right_x, width = frequency_width} or nil,
  }
end

return M
