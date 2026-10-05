-- Multi-row column chart.
--
-- The sparkline renders one row; this renders the same series across an
-- arbitrary height so a tall panel shows a readable plot instead of a single
-- line floating above empty space.  Output is an array of `height` strings,
-- top row first, each exactly `width` display cells wide.
local Sparkline = require("wtop.ui.widgets.sparkline")

local M = {}

local MAX_WIDTH = 4096
local MAX_HEIGHT = 256

-- A column is the highest reading in its interval.  `Sparkline.buckets` does the
-- reduction; the name travels in the scale so a guard can ask what a column means
-- instead of assuming it.
local REDUCTION = "window-max"

local PARTIAL = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local ASCII_PARTIAL = { ".", ".", ":", ":", "|", "|", "#", "#" }

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function bounded(value, fallback, minimum, maximum)
  if not finite(value) then return fallback end
  return math.max(minimum, math.min(maximum, math.floor(value)))
end

--- Render `values` as `height` rows of `width` cells.
-- @param values   series table (`{n = …, [1..n] = number|nil}`), optionally
--                 carrying `timestamps_ns`/`window_ns`/`end_ns` metadata
-- @param width    display cells per row
-- @param height   number of rows
-- @param options  `min`, `max`, `mode` ("block"|"ascii"), `gap` (string)
-- @return array of strings (top row first), plus a table describing the
--         resolved scale so a caller can label the axis
function M.render(values, width, height, options)
  options = options or {}
  width = bounded(width, 0, 0, MAX_WIDTH)
  height = bounded(height, 0, 0, MAX_HEIGHT)
  if width < 1 or height < 1 then return {}, { minimum = 0, maximum = 0 } end

  local ascii = options.mode == "ascii"
  local partial = ascii and ASCII_PARTIAL or PARTIAL
  local gap = options.gap or (ascii and " " or "·")
  local full = partial[8]

  local buckets, window = Sparkline.buckets(values, width, options)
  local minimum, maximum = options.min, options.max
  local flat = false
  if not finite(minimum) or not finite(maximum) or maximum <= minimum then
    -- The scale comes from the readings the window held, not from the columns
    -- that were drawn from them.  It used to come from the columns, which is the
    -- same number only when the columns and the readings agree -- and a column
    -- that reduces several readings to one cannot carry the reading the panel
    -- prints as its top label.  `Sparkline.window` is the one implementation of
    -- "which readings are in the window", so the scale and the columns cannot
    -- drift apart.
    local low, high = window.minimum, window.maximum
    flat = low ~= nil and high ~= nil and high == low
    if not low then
      low, high = 0, 1
    elseif high <= low then
      -- A flat series still deserves a visible baseline rather than a
      -- division by zero or a full-height block.
      high = low + (math.abs(low) > 0 and math.abs(low) * 0.25 or 1)
    end
    minimum = finite(options.min) and options.min or low
    maximum = finite(options.max) and options.max or high
    if maximum <= minimum then maximum = minimum + 1 end
  end

  local span = maximum - minimum
  local rows = {}
  for row = 1, height do rows[row] = {} end

  for column = 1, width do
    local value = buckets[column]
    if not finite(value) then
      for row = 1, height do rows[row][column] = row == height and gap or " " end
    else
      local fraction = math.max(0, math.min(1, (value - minimum) / span))
      -- Total eighths of a cell the bar occupies across the full height.
      local eighths = fraction * height * 8
      local whole = math.floor(eighths / 8)
      local remainder = math.floor(eighths - whole * 8 + 0.5)
      if remainder >= 8 then
        whole, remainder = whole + 1, 0
      end
      -- A non-zero sample must never render as an empty column; the smallest
      -- visible mark is more honest than a gap the reader reads as "no data".
      if whole == 0 and remainder == 0 and fraction > 0 then remainder = 1 end
      for row = 1, height do
        local from_bottom = height - row + 1
        if from_bottom <= whole then
          rows[row][column] = full
        elseif from_bottom == whole + 1 and remainder > 0 then
          rows[row][column] = partial[math.max(1, math.min(8, remainder))]
        else
          rows[row][column] = " "
        end
      end
    end
  end

  local result = {}
  for row = 1, height do result[row] = table.concat(rows[row]) end
  return result, {
    minimum = minimum, maximum = maximum, columns = width,
    -- A series whose samples are all identical has no real vertical extent.
    -- Labelling a synthesised span as if it were measured invents a scale.
    flat = flat == true,
    -- How a column was reduced, and what the window held, so a caller that
    -- prints this scale and a guard that checks it both read the widget's own
    -- numbers rather than re-deriving the window.
    reduction = REDUCTION,
    samples = window.samples or 0,
    window_minimum = window.minimum,
    window_maximum = window.maximum,
  }
end

M.PARTIAL = PARTIAL

return M
