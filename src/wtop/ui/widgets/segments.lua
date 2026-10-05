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
  local in_bar = 0
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
      in_bar = in_bar + 1
    end
  end
  y = y + 1

  if variant == "compact" or y > area.y + area.height - 1 then
    return { segments = #segments, in_bar = in_bar, drawn = 0, named = 0, rows = 0 }
  end

  -- Legend entries flow across the remaining rows; each carries its own mark
  -- so the mapping survives a monochrome terminal.
  --
  -- **The flow is laid out before anything is written, because a legend that runs
  -- out of rows has to say so, and the count has to land where the first entry
  -- that did not fit would have gone** -- a position the writing pass no longer
  -- knows once it has wrapped.  A legend entry is the only place a segment's
  -- number appears at all, so a legend that stops is a number that stops: the
  -- clause `key_value` and `bars` now hold, at a third size.  Measured through
  -- the product's own layouts, Portuguese at 40 and at 80 columns -- a 36-by-4
  -- panel, two legend rows, five entries -- dropped `Livre`, the last one, with
  -- nothing on the panel saying so and its segment still on the bar above as a
  -- rule.
  --
  -- **The count takes the dropped entry's own slot rather than a row of its own,
  -- and the price of that choice is measured.**  Reserving a whole row for it is
  -- the form `key_value` uses, and here it is the more expensive form: five
  -- entries need three legend rows and that panel has two, so a reserved row
  -- drops a *second* entry in order to name the first one's absence.  `+N` in
  -- the dropped slot names all five for the price of one three-cell number,
  -- needs no translation, and is the form `bars` already writes per cell.  When
  -- the row the dropped entry would have taken is already full -- which is what a
  -- narrow panel produces, since the last entry on a row leaves only the
  -- separator -- the count displaces that row's last entry, because a count that
  -- cannot be drawn is the silence this rule exists to remove.
  local muted = Util.style(context, "text.muted", surface)
  local dim = Util.style(context, "text.muted", surface, { dim = true })
  local right = area.x + area.width
  local bottom = area.y + area.height - 1

  local function entry_of(index)
    local segment = segments[index]
    local token = segment.token or DEFAULT_TOKENS[((index - 1) % #DEFAULT_TOKENS) + 1]
    local label = segment.label_id
      and tostring(Util.t(context, segment.label_id, segment.label or segment.id or ""))
      or tostring(segment.label or segment.id or "")
    local text = label
    if segment.display_value then text = text .. " " .. tostring(segment.display_value) end
    local mark = unicode and (segment.empty and "○" or "■") or (segment.empty and "o" or "*")
    return { token = token, empty = segment.empty, mark = mark, text = text,
      width = 2 + Width.display_width(text, grid.width_options) }
  end

  local placements, dropped, placed = {}, nil, 0
  local row, cursor = y, area.x
  for index = 1, #segments do
    local entry = entry_of(index)
    -- An entry is placed where it fits **whole**, or not at all.  The first
    -- version of this wrote a mark and whatever fitted, so a four-cell panel
    -- showed `■ B…` and the widget counted that as drawn -- its own report said
    -- five of five while a reader could identify none of them, because a fragment
    -- of a label names nothing.  And the wrap has to be re-tested: moving to the
    -- next row and placing the entry there anyway is how a two-cell panel came to
    -- hold five truncated ones.
    local at_row, at_x = row, cursor
    if at_x + entry.width > right then
      if row + 1 > bottom then
        -- No rows left.  The count goes where this entry would have started, which
        -- is the first slot on the panel that cannot hold it.
        dropped = { row = at_row, x = at_x, clear = 0 }
        break
      end
      at_row, at_x = row + 1, area.x
      if at_x + entry.width > right then
        -- Wider than the panel, so no row will hold it.
        dropped = { row = at_row, x = at_x, clear = 0 }
        break
      end
    end
    placements[index] = { row = at_row, x = at_x, entry = entry }
    placed = placed + 1
    row, cursor = at_row, at_x + entry.width + 1
  end

  local undrawn = #segments - placed
  local count_width = Width.display_width("+" .. tostring(undrawn), grid.width_options)
  if dropped and dropped.x + count_width > right then
    -- The room left on that row cannot hold the count.  Give it that row's last
    -- entry's place, when the count is no narrower than the entry it displaces.
    -- The condition is the count not fitting, not the row being full: an
    -- eighteen-cell panel leaves one cell over and a two-cell count does not fit
    -- in it, so a full row is not the only way to arrive here.
    local victim
    for index = #segments, 1, -1 do
      local place = placements[index]
      if place and place.row == dropped.row then victim = index break end
    end
    if victim then
      local slot = placements[victim]
      local widened = 1 + #tostring(undrawn + 1)
      if slot.entry.width >= widened then
        dropped.x = slot.x
        dropped.clear = slot.entry.width
        placements[victim] = nil
        placed = placed - 1
        undrawn = undrawn + 1
        count_width = widened
      end
    end
  end

  local drawn = 0
  for index = 1, #segments do
    local place = placements[index]
    if place and place.x < right then
      local entry = place.entry
      local room = math.min(entry.width - 1, right - place.x - 1)
      grid:write(place.x, place.row, entry.mark,
        Util.style(context, entry.empty and "border.subtle" or entry.token, surface), 1)
      if room > 0 then
        grid:write(place.x + 1, place.row,
          Util.truncate(grid, " " .. entry.text, room), muted, room)
      end
      drawn = drawn + 1
    end
  end

  -- Blanking the rest of a displaced entry is bounded by the panel, and the entry
  -- text is truncated to the room that is left.  Both bounds are unreachable
  -- redundancy *today* -- an entry is only placed where it fits whole, so
  -- `dropped.clear` cannot exceed the room to the panel's edge and the text is
  -- never longer than the room -- and both were reached in the version before that
  -- rule: the count's blanking wrote fifteen spaces one cell past the edge of a
  -- two-cell panel, and the text was written at its own width with no truncation
  -- at all, which is the defect that put up to thirty-one cells of a legend
  -- outside the panel.  A mutation that removes either bound produces output
  -- byte-identical to the fixed widget's, which is the measurement that says they
  -- are redundant now rather than the measurement that says they are wrong.
  local silent = 0
  if undrawn > 0 and dropped then
    local text = "+" .. tostring(undrawn)
    local width = Width.display_width(text, grid.width_options)
    if dropped.x >= area.x and dropped.x + width <= right then
      local leftover = math.min(dropped.clear, right - dropped.x) - width
      if leftover > 0 then
        grid:write(dropped.x + width, dropped.row, string.rep(" ", leftover), muted, leftover)
      end
      grid:write(dropped.x, dropped.row, Util.truncate(grid, text, width), dim, width)
    else
      -- No room for the number.  A panel narrower than `+N` cannot name what it
      -- dropped, and the product's layouts never produce one: measured over every
      -- page this widget appears on, the narrowest rectangle the layout solver
      -- gives it is 36 cells.  `silent` is reported so the accounting still
      -- closes and the case is named rather than assumed away.
      silent = undrawn
    end
  end

  return { segments = #segments, in_bar = in_bar, drawn = drawn, named = undrawn - silent,
    silent = silent, rows = bottom - y + 1 }
end

M.allocate = allocate

-- Published because it is the bound on the widest count this widget can owe: a
-- list of at most `MAX_SEGMENTS` holds back at most that many entries, so `+N` is
-- at most this many cells wide, and a guard has to be able to say for which panel
-- widths naming what was dropped was possible.
M.MAX_SEGMENTS = MAX_SEGMENTS

return M
