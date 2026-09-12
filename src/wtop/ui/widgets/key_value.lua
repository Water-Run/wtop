-- Aligned label/value list with optional section headings.
--
-- Alignment is computed from measured display width, not byte length.  The
-- previous approach built these lists with `string.format("%-18s", label)`,
-- which pads by bytes and therefore mis-aligned every translated label: a
-- four-character Chinese label is twelve bytes and eight columns wide.
local Util = require("wtop.ui.widgets.util")
local Width = require("wtop.ui.renderer.width")

local M = {}

local MAX_ENTRIES = 512
local MIN_VALUE_WIDTH = 8

local function entry_label(entry, context)
  if entry.label_id then
    return tostring(Util.t(context, entry.label_id, entry.label or ""))
  end
  return tostring(entry.label or "")
end

local function measure(grid, text)
  return Width.display_width(text, grid.width_options)
end

--- Lay entries into `columns` balanced column groups.
-- Sections are kept whole where possible so a heading never ends up in one
-- column with its rows in another.
local function paginate(entries, rows, columns)
  if columns <= 1 then return { entries } end
  local groups, current = {}, {}
  local per_column = math.max(1, math.ceil(#entries / columns))
  for index, entry in ipairs(entries) do
    -- Start a new column at a section boundary once the current one is full,
    -- so headings stay attached to the rows they introduce.
    if #current >= per_column and entry.section and #groups < columns - 1 then
      groups[#groups + 1] = current
      current = {}
    elseif #current >= rows and #groups < columns - 1 then
      groups[#groups + 1] = current
      current = {}
    end
    current[#current + 1] = entry
    if index == #entries then groups[#groups + 1] = current end
  end
  while #groups > columns do
    local tail = table.remove(groups)
    local target = groups[#groups]
    for _, entry in ipairs(tail) do target[#target + 1] = entry end
  end
  return groups
end

local function render_group(grid, area, entries, context, offset)
  local surface = context.surface or "surface.raised"
  local label_style = Util.style(context, "text.muted", surface)
  local section_style = Util.style(context, "accent.primary", surface, { bold = true })

  local label_width = 0
  for _, entry in ipairs(entries) do
    if not entry.section then
      label_width = math.max(label_width, measure(grid, entry_label(entry, context)))
    end
  end
  label_width = math.min(label_width, math.max(6, area.width - MIN_VALUE_WIDTH))

  local y = area.y
  local bottom = area.y + area.height - 1
  for index = offset + 1, #entries do
    if y > bottom then break end
    local entry = entries[index]
    if entry.section then
      local heading = entry.section_id
        and tostring(Util.t(context, entry.section_id, entry.section))
        or tostring(entry.section)
      -- A blank line before a heading separates groups without a rule.
      if y > area.y then
        y = y + 1
        if y > bottom then break end
      end
      grid:write(area.x, y, Util.truncate(grid, heading, area.width), section_style, area.width)
    elseif entry.blank then
      grid:write(area.x, y, "", label_style, area.width)
    else
      local label = entry_label(entry, context)
      local value = entry.value == nil and "—" or tostring(entry.value)
      local truncated = Util.truncate(grid, label, label_width)
      local used = measure(grid, truncated)
      grid:write(area.x, y, truncated, label_style, label_width)
      local value_x = area.x + label_width + 1
      local value_width = area.x + area.width - value_x
      if value_width > 0 then
        local token = entry.token or "text.primary"
        grid:write(value_x, y, Util.truncate(grid, value, value_width),
          Util.style(context, token, surface, { bold = entry.emphasis == true }),
          value_width)
      end
      -- Pad the measured gap so a wide-glyph label cannot bleed into the value.
      if used < label_width then
        grid:write(area.x + used, y, string.rep(" ", label_width - used),
          label_style, label_width - used)
      end
    end
    y = y + 1
  end
  return y - area.y
end

function M.render(grid, area, model, context, variant)
  context, model = context or {}, model or {}
  area = Util.clip_rect(grid, area)
  if area.width < 1 or area.height < 1 then return end

  local entries = {}
  for _, entry in ipairs(type(model.entries) == "table" and model.entries or {}) do
    if #entries >= MAX_ENTRIES then break end
    if type(entry) == "table" then entries[#entries + 1] = entry end
  end
  if #entries == 0 then
    local empty = model.empty_text or Util.t(context, "ui.no_data", "No data")
    grid:write(area.x, area.y, Util.truncate(grid, tostring(empty), area.width),
      Util.style(context, "text.muted", context.surface or "surface.raised"), area.width)
    return { visible = 0, total = 0 }
  end

  local offset = tonumber(model.offset) or 0
  if offset ~= offset or offset == math.huge or offset == -math.huge then offset = 0 end
  offset = math.max(0, math.min(math.max(0, #entries - 1), math.floor(offset)))

  -- Two or three columns only pay off once each is wide enough to hold a
  -- label and a useful value; otherwise a single column reads better.
  local column_width = tonumber(model.column_width) or 28
  local columns = 1
  if variant ~= "value" and offset == 0 then
    columns = math.max(1, math.min(tonumber(model.max_columns) or 3,
      math.floor((area.width + 2) / (column_width + 2))))
    -- One column is calmer, but only while the content actually fits; spilling
    -- rows off the bottom of the panel loses them silently.
    if #entries <= area.height then columns = 1 end
    while columns > 1 and math.ceil(#entries / columns) < area.height - 1
        and #entries <= (columns - 1) * area.height do
      columns = columns - 1
    end
  end

  if columns <= 1 then
    -- Reserve the last row for an overflow marker when content will not fit.
    local body = { x = area.x, y = area.y, width = area.width, height = area.height }
    local overflow = #entries - offset > area.height
    if overflow and area.height > 1 then body.height = area.height - 1 end
    local drawn = render_group(grid, body, entries, context, offset)
    local shown = 0
    for index = offset + 1, #entries do
      if shown >= body.height then break end
      shown = shown + 1
    end
    if overflow and area.height > 1 then
      local unicode = not (context.capabilities and context.capabilities.unicode == false)
      local remaining = #entries - offset - body.height
      local marker = string.format("%s %d %s", unicode and "▾" or "v", math.max(0, remaining),
        Util.t(context, "ui.more_rows", "more"))
      if offset > 0 then
        marker = (unicode and "▴ " or "^ ") .. tostring(offset) .. "  " .. marker
      end
      grid:write(area.x, area.y + area.height - 1, Util.truncate(grid, marker, area.width),
        Util.style(context, "text.muted", context.surface or "surface.raised", { dim = true }),
        area.width)
    end
    return {
      visible = body.height, total = #entries, columns = 1,
      offset = offset, scrollable = #entries > body.height,
    }
  end

  local groups = paginate(entries, area.height, columns)
  columns = #groups
  local gap = 2
  local each = math.floor((area.width - gap * (columns - 1)) / columns)
  local drawn = 0
  for index, group in ipairs(groups) do
    local x = area.x + (index - 1) * (each + gap)
    drawn = math.max(drawn, render_group(grid,
      { x = x, y = area.y, width = each, height = area.height }, group, context, 0))
  end
  return {
    visible = drawn, total = #entries, columns = columns,
    offset = 0, scrollable = false,
  }
end

M.paginate = paginate

return M
