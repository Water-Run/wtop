-- One stacked bar plus a legend, for a quantity that partitions into parts:
-- memory into used/shared/buffers/cache/free, a filesystem into used/free.
--
-- The segments must already be a true partition; overlapping figures (the form
-- meminfo actually reports) would render a bar wider than the whole.
local Util = require("wtop.ui.widgets.util")
local Width = require("wtop.ui.renderer.width")

local M = {}

local MAX_SEGMENTS = 12
local DEFAULT_TOKENS = {
  "accent.primary", "chart.secondary", "metric.warn", "metric.good", "border.subtle",
}

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

--- Distribute `width` cells across segments proportionally.
-- Largest-remainder keeps the total exact, and any segment with a non-zero
-- share is guaranteed at least one cell so small partitions stay visible.
local function allocate(segments, width)
  local total = 0
  for _, segment in ipairs(segments) do
    if finite(segment.bytes) and segment.bytes > 0 then total = total + segment.bytes end
  end
  local widths, remainders, assigned = {}, {}, 0
  if total <= 0 or width <= 0 then
    for index = 1, #segments do widths[index] = 0 end
    return widths, total
  end
  for index, segment in ipairs(segments) do
    local share = finite(segment.bytes) and math.max(0, segment.bytes) or 0
    local exact = share / total * width
    local floor = math.floor(exact)
    if share > 0 and floor < 1 then floor = 1 end
    widths[index] = floor
    remainders[index] = exact - math.floor(exact)
    assigned = assigned + floor
  end
  local order = {}
  for index = 1, #segments do order[index] = index end
  table.sort(order, function(left, right)
    if remainders[left] ~= remainders[right] then
      return remainders[left] > remainders[right]
    end
    return left < right
  end)
  local cursor = 1
  while assigned < width and #order > 0 do
    local index = order[((cursor - 1) % #order) + 1]
    widths[index] = widths[index] + 1
    assigned = assigned + 1
    cursor = cursor + 1
  end
  -- Guaranteeing every non-zero segment at least one cell can overshoot when
  -- the bar is narrower than the number of segments.  Give up the guarantee
  -- smallest-share-first so the dominant segments stay proportional, instead
  -- of drawing a bar wider than the row it lives in.
  if assigned > width then
    local by_share = {}
    for index = 1, #segments do by_share[index] = index end
    table.sort(by_share, function(left, right)
      local left_share = finite(segments[left].bytes) and segments[left].bytes or 0
      local right_share = finite(segments[right].bytes) and segments[right].bytes or 0
      if left_share ~= right_share then return left_share < right_share end
      return left < right
    end)
    for _, index in ipairs(by_share) do
      while assigned > width and widths[index] > 0 do
        widths[index] = widths[index] - 1
        assigned = assigned - 1
      end
      if assigned <= width then break end
    end
  end
  return widths, total
end

function M.render(grid, area, model, context, variant)
  context, model = context or {}, model or {}
  area = Util.clip_rect(grid, area)
  if area.width < 1 or area.height < 1 then return end
  local surface = context.surface or "surface.raised"
  local segments = {}
  for _, segment in ipairs(type(model.segments) == "table" and model.segments or {}) do
    if #segments >= MAX_SEGMENTS then break end
    if type(segment) == "table" then segments[#segments + 1] = segment end
  end
  if #segments == 0 then
    grid:write(area.x, area.y, Util.truncate(grid,
      tostring(model.empty_text or Util.t(context, "ui.no_data", "No data")), area.width),
      Util.style(context, "text.muted", surface), area.width)
    return
  end

  local unicode = not (context.capabilities and context.capabilities.unicode == false)
  local y = area.y
  if model.title and area.height > 1 then
    grid:write(area.x, y, Util.truncate(grid, tostring(model.title), area.width),
      Util.style(context, "text.muted", surface), area.width)
    y = y + 1
  end

  local widths = allocate(segments, area.width)
  local x = area.x
  for index, segment in ipairs(segments) do
    local width = widths[index]
    if width > 0 then
      local token = segment.token or DEFAULT_TOKENS[((index - 1) % #DEFAULT_TOKENS) + 1]
      local glyph = segment.glyph or (unicode and "█" or "#")
      -- The trailing segment is the remainder (free space); drawing it as a
      -- rule instead of a solid block reads as "not in use".
      if segment.empty then glyph = unicode and "─" or "-" end
      grid:write(x, y, string.rep(glyph, width),
        Util.style(context, segment.empty and "border.subtle" or token, surface), width)
      x = x + width
    end
  end
  y = y + 1

  if variant == "compact" or y > area.y + area.height - 1 then return end

  -- Legend entries flow across the remaining rows; each carries its own mark
  -- so the mapping survives a monochrome terminal.
  local muted = Util.style(context, "text.muted", surface)
  local cursor, row = area.x, y
  local bottom = area.y + area.height - 1
  for index, segment in ipairs(segments) do
    local token = segment.token or DEFAULT_TOKENS[((index - 1) % #DEFAULT_TOKENS) + 1]
    local label = segment.label_id
      and tostring(Util.t(context, segment.label_id, segment.label or segment.id or ""))
      or tostring(segment.label or segment.id or "")
    local text = label
    if segment.display_value then text = text .. " " .. tostring(segment.display_value) end
    local mark = unicode and (segment.empty and "○" or "■") or (segment.empty and "o" or "*")
    local entry_width = 2 + Width.display_width(text, grid.width_options)
    if cursor + entry_width > area.x + area.width then
      row = row + 1
      cursor = area.x
      if row > bottom then break end
    end
    grid:write(cursor, row, mark,
      Util.style(context, segment.empty and "border.subtle" or token, surface), 1)
    grid:write(cursor + 1, row, " " .. text, muted, entry_width - 1)
    cursor = cursor + entry_width + 1
  end
end

M.allocate = allocate

return M
