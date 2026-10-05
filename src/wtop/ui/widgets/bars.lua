-- Array of labelled proportional bars: per-core CPU, per-battery charge,
-- per-filesystem usage.  htop's per-core meters are the reference; a numeric
-- table of the same data is far harder to scan.
local Metric = require("wtop.ui.widgets.metric")
local Util = require("wtop.ui.widgets.util")
local Width = require("wtop.ui.renderer.width")

local M = {}

local MAX_ROWS = 512
-- The blank columns between two cells.  Published so the guard can partition a row
-- into cells with the widget's own number instead of a second copy of it.
local GAP = 2
-- The ceiling a label is cut to, and the width of the smallest cell that can hold
-- a label, a value and a bar worth reading.  Both are published for the same
-- reason `GAP` is: a guard that keeps its own copy of either number is a guard
-- that stops measuring the thing when the thing changes.
local MAX_LABEL_WIDTH = 12
local CELL_BAR_CELLS = 6

function M.minimum_cell(label_width, value_width)
  return (label_width or 0) + (value_width or 0) + CELL_BAR_CELLS
end

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function severity_token(item, model)
  if item.token then return item.token end
  if not finite(item.value) then return "text.muted" end
  local severity = Metric.severity(item.value,
    item.thresholds or model.thresholds, model.severity_invert)
  return Metric.SEVERITY_TOKENS[severity] or "accent.primary"
end

local function draw_bar(grid, x, y, width, fraction, context, token, surface)
  if width < 1 then return end
  local unicode = not (context.capabilities and context.capabilities.unicode == false)
  local on, off = unicode and "━" or "#", unicode and "─" or "-"
  local filled = 0
  if finite(fraction) then
    filled = math.floor(width * math.max(0, math.min(1, fraction)) + 0.5)
    if fraction > 0 and filled == 0 then filled = 1 end
  end
  if filled > 0 then
    grid:write(x, y, string.rep(on, filled), Util.style(context, token, surface), filled)
  end
  if filled < width then
    grid:write(x + filled, y, string.rep(off, width - filled),
      Util.style(context, "border.subtle", surface), width - filled)
  end
end

function M.render(grid, area, model, context, variant)
  context, model = context or {}, model or {}
  area = Util.clip_rect(grid, area)
  if area.width < 1 or area.height < 1 then return end
  local surface = context.surface or "surface.raised"
  local items = {}
  for _, item in ipairs(type(model.items) == "table" and model.items or {}) do
    if #items >= MAX_ROWS then break end
    if type(item) == "table" then items[#items + 1] = item end
  end
  if #items == 0 then
    grid:write(area.x, area.y, Util.truncate(grid,
      tostring(model.empty_text or Util.t(context, "ui.no_data", "No data")), area.width),
      Util.style(context, "text.muted", surface), area.width)
    return { rows = 0, columns = 0 }
  end

  local minimum = finite(model.min) and model.min or 0
  local maximum = finite(model.max) and model.max or 100

  local label_width, value_width = 0, 0
  for _, item in ipairs(items) do
    label_width = math.max(label_width,
      Width.display_width(tostring(item.label or ""), grid.width_options))
    value_width = math.max(value_width,
      Width.display_width(tostring(item.display_value or ""), grid.width_options))
  end
  -- A label keeps a ceiling of twelve cells.  The widest label the product's own
  -- models build is four, so the cap is for a model nobody has written yet; a
  -- label wider than its cell is not cut but skipped whole (see the `remaining >
  -- label_width + 2` test below), and skipping a name is a worse thing to do to
  -- it than shortening it.
  label_width = math.min(label_width, MAX_LABEL_WIDTH)
  -- A value has no ceiling.  It used to be capped at ten cells, and the cap was
  -- tuned to the reference catalogue: es-ES spells `system.offline` as "sin
  -- conexión", twelve cells, so a Spanish battery panel drew "sin conexió" -- a
  -- fragment of a word, in the one place a reader looks to learn whether a
  -- laptop is plugged in.  Cutting a translated string to fit a bar is the same
  -- defect the width guards exist to prevent, and this widget already spends
  -- columns instead of letters: 236 drawn values in one sweep were short of
  -- their own list's widest value, and the fix costs 28 of 13 254 drawn items.

  -- Spend the panel's height before its width: a longer bar resolves more
  -- detail than a second column does, so start with the fewest columns that
  -- fit vertically and only widen when a cell would be too narrow to read.
  local minimum_cell = M.minimum_cell(label_width, value_width)
  local gap = GAP
  local maximum_columns = math.max(1, math.min(tonumber(model.max_columns) or 8, #items))
  local function cell_for(count)
    return math.floor((area.width - gap * (count - 1)) / count)
  end

  -- Two numbers bound the choice, and the previous code had neither.
  --
  -- `needed` is how many columns it takes to fit every item in the panel's
  -- height, and it is a **floor**.  Trading columns below it does not make a
  -- cell more readable; it makes `rows_needed` taller than the panel, and the
  -- placement loop is column-major, so the first column that runs off the
  -- bottom ends the loop and every other column is left blank.  On a 128-core
  -- host that is what a 75-by-21 panel did: 21 of 128 cores drawn, four of its
  -- five columns empty, and nothing on the panel saying 107 were missing.
  --
  -- `fitting` is how many columns a cell of `minimum_cell` still fits in -- the
  -- widget's own width for a cell that holds a label and a useful value -- capped
  -- by the panel's height so that filling the panel row by row cannot run off
  -- the bottom either.  The floor is `minimum_cell` and not a smaller number
  -- because a cell narrower than that is not a cheaper version of a cell, it is
  -- a cell with nothing in it: the first version of this fix bounded the cell at
  -- four cells, the number the old dead `cell_width < 4` branch used, and the
  -- panel filled up -- forty cores into 40 by 5, with the widget reporting 24 of
  -- them drawn and the panel carrying **no mark at all**, because a four-cell cell
  -- with a three-cell label has no room left for a bar or a value.  When `needed`
  -- exceeds `fitting` the list cannot fit at all, and the widget says how much of
  -- it is missing rather than showing a panel that looks complete.
  local needed = math.max(1, math.ceil(#items / math.max(1, area.height)))
  local fitting = math.max(1, math.min(
    math.floor((area.width + gap) / (minimum_cell + gap)), math.max(1, area.height)))
  local columns = math.min(needed, fitting)
  while columns < math.min(maximum_columns, fitting)
      and cell_for(columns) > minimum_cell * 2 do
    -- Very wide panels would otherwise draw four cores as four enormous bars
    -- with most of the row empty.
    --
    -- The cap is `fitting` and not `maximum_columns` for the same reason `needed`
    -- is a floor: `fitting` is by definition the largest count whose cells are
    -- still `minimum_cell` wide, so staying at or below it is what keeps a cell
    -- readable.  An earlier version also narrowed back down when a cell came out
    -- under `minimum_cell`, and that loop could not run -- with `columns` never
    -- above `fitting`, `cell_for(columns)` is never below `minimum_cell` -- which
    -- a mutation and then 68.6 million arithmetic cases agreed on.  The floor is
    -- now a property of the two bounds rather than a second place to enforce it.
    columns = columns + 1
  end
  local cell_width = math.max(1, cell_for(columns))

  -- A list longer than the panel fills the panel row by row rather than down the
  -- first column, and spends its last cell on the count of what it is holding
  -- back.  `key_value` spends a whole row on `▾ N more`; a cell has no room for
  -- a word, so it is `+N` -- a count needs no translation, and the overlay's
  -- `n/m` is the same idea.  Filling across is also the only arrangement in
  -- which the panel starts at the first of the list: down the first column the
  -- top row would hold items 1, 6 and 11 of a forty-item list, and the count
  -- would be right while the panel read from the middle.
  local rows_needed = math.min(math.ceil(#items / columns), area.height)
  local row_major = rows_needed * columns < #items
  local capacity = columns * area.height
  local held = math.max(0, #items - capacity)
  if held > 0 then
    capacity = math.max(0, capacity - 1)
    held = #items - capacity
  end
  local marker_at = held > 0 and { column = columns - 1, row = area.height - 1 } or nil

  local drawn = 0
  for index = 1, math.min(#items, capacity) do
    local column, row
    if row_major then
      column = (index - 1) % columns
      row = (index - 1) // columns
    else
      column = (index - 1) // rows_needed
      row = (index - 1) % rows_needed
    end
    if not (marker_at and column == marker_at.column and row == marker_at.row) then
      local item = items[index]
      local y = area.y + row
      local x = area.x + column * (cell_width + gap)
      local token = severity_token(item, model)

      local cursor = x
      local remaining = cell_width
      if label_width > 0 and remaining > label_width + 2 then
        local label = Util.truncate(grid, tostring(item.label or ""), label_width)
        grid:write(cursor, y, label, Util.style(context, "text.muted", surface), label_width)
        cursor = cursor + label_width + 1
        remaining = remaining - label_width - 1
      end
      local text = tostring(item.display_value or "")
      local text_width = math.min(value_width, math.max(0, remaining - 3))
      local bar_width = remaining - (text_width > 0 and text_width + 1 or 0)
      if bar_width > 0 then
        local fraction
        if finite(item.fraction) then
          fraction = item.fraction
        elseif finite(item.value) and maximum > minimum then
          fraction = (item.value - minimum) / (maximum - minimum)
        end
        draw_bar(grid, cursor, y, bar_width, fraction, context, token, surface)
        cursor = cursor + bar_width + 1
      end
      if text_width > 0 then
        local truncated = Util.truncate(grid, text, text_width)
        local pad = text_width - Width.display_width(truncated, grid.width_options)
        grid:write(cursor, y, string.rep(" ", math.max(0, pad)) .. truncated,
          Util.style(context, token, surface), text_width)
      end
      drawn = drawn + 1
    end
  end

  if marker_at then
    local x = area.x + marker_at.column * (cell_width + gap)
    local y = area.y + marker_at.row
    local text = "+" .. tostring(held)
    grid:write(x, y, Util.truncate(grid, text, cell_width),
      Util.style(context, "text.muted", surface, { dim = true }), cell_width)
  end

  return { rows = rows_needed, columns = columns, drawn = drawn, total = #items,
    held = held }
end

-- Published so a guard can partition a row into cells with the widget's own gap
-- rather than a second copy of the number.
M.GAP = GAP
M.MAX_LABEL_WIDTH = MAX_LABEL_WIDTH

return M
