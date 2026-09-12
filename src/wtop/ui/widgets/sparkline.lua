local Width = require("wtop.ui.renderer.width")

local M = {}

local MAX_WIDTH = 10000
local MAX_POINTS = 1000000
local MAX_GLYPHS = 64

local glyphs = {
  block = {"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"},
  ascii = {".", ":", "-", "=", "+", "*", "#", "@"},
}

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function sequence_length(values)
  local length = values.n or 0
  if type(length) ~= "number" or not finite(length) or length < 0
      or length % 1 ~= 0 or length > MAX_POINTS then
    error("sparkline length must be an integer in 0..1000000", 3)
  end
  for key in pairs(values) do
    if type(key) == "number" and finite(key) and key >= 1 and key == math.floor(key) then
      if key > MAX_POINTS then error("sparkline index exceeds 1000000", 3) end
      if key > length then
      length = key
      end
    end
  end
  return length
end

local function valid_cell(value, name)
  if type(value) ~= "string" or value == "" or #value > 16
      or Width.display_width(value) ~= 1 then
    error(name .. " must be a single display-cell string", 3)
  end
  return value
end

local function time_buckets(values, length, width)
  local timestamps = values.timestamps_ns
  if timestamps == nil then return nil end
  if type(timestamps) ~= "table" then
    error("sparkline timestamps_ns must be a table", 3)
  end
  local window_ns, end_ns = values.window_ns, values.end_ns
  if not finite(window_ns) or window_ns <= 0 or not finite(end_ns) or end_ns < 0 then
    error("sparkline time window metadata must be finite and positive", 3)
  end
  local active_width = width
  if values.column_ns ~= nil then
    if not finite(values.column_ns) or values.column_ns <= 0 then
      error("sparkline column_ns must be finite and positive", 3)
    end
    active_width = math.min(width, math.max(1, math.floor(window_ns / values.column_ns)))
    window_ns = math.min(window_ns, values.column_ns * active_width)
  end
  local bucket_offset = width - active_width
  local start_ns = end_ns - window_ns
  local sums, counts, buckets = {}, {}, {n = width}
  for index = 1, length do
    local timestamp = timestamps[index]
    if timestamp ~= nil and (not finite(timestamp) or timestamp < 0) then
      error("sparkline timestamps must be finite and non-negative", 3)
    end
    if timestamp and timestamp >= start_ns and timestamp <= end_ns then
      local bucket = math.floor(((timestamp + 0.0) - start_ns) / window_ns * active_width) + 1
      bucket = bucket_offset + math.max(1, math.min(active_width, bucket))
      local value = values[index]
      if finite(value) then
        sums[bucket] = (sums[bucket] or 0) + value
        counts[bucket] = (counts[bucket] or 0) + 1
      elseif counts[bucket] == nil then
        counts[bucket] = 0
      end
    end
  end
  for index = 1, width do
    if counts[index] and counts[index] > 0 then
      buckets[index] = sums[index] / counts[index]
    elseif counts[index] == 0 then
      buckets[index] = false
    end
  end
  return buckets
end

function M.render(values, width, options)
  if values ~= nil and type(values) ~= "table" then
    error("sparkline values must be a table", 2)
  end
  if options ~= nil and type(options) ~= "table" then
    error("sparkline options must be a table", 2)
  end
  options = options or {}
  values = values or {}
  local length = sequence_length(values)
  width = width == nil and length or width
  if type(width) ~= "number" or not finite(width) or width < 0
      or width % 1 ~= 0 or width > MAX_WIDTH then
    error("sparkline width must be an integer in 0..10000", 2)
  end
  if width == 0 then return "" end
  local bucketed = time_buckets(values, length, width)
  if bucketed then
    values, length = bucketed, width
  end
  local set = options.glyphs or glyphs[options.mode == "ascii" and "ascii" or "block"]
  if type(set) ~= "table" or #set < 1 or #set > MAX_GLYPHS then
    error("sparkline glyphs must contain 1..64 entries", 2)
  end
  for index, glyph in ipairs(set) do valid_cell(glyph, "sparkline glyph " .. index) end
  local gap = valid_cell(options.gap or (options.mode == "ascii" and " " or "·"),
    "sparkline gap")
  if options.pad ~= nil and type(options.pad) ~= "boolean" then
    error("sparkline pad must be a boolean", 2)
  end
  local first = math.max(1, length - width + 1)
  local minimum, maximum = options.min, options.max
  if minimum ~= nil and not finite(minimum) then error("sparkline min must be finite", 2) end
  if maximum ~= nil and not finite(maximum) then error("sparkline max must be finite", 2) end
  if minimum ~= nil and maximum ~= nil and maximum < minimum then
    error("sparkline max must not be less than min", 2)
  end
  for index = first, length do
    local value = values[index]
    if finite(value) then
      minimum = minimum == nil and value or math.min(minimum, value)
      maximum = maximum == nil and value or math.max(maximum, value)
    end
  end
  if minimum == nil then minimum = 0 end
  if maximum == nil then maximum = minimum end
  local range = maximum - minimum
  local result = {}
  for index = first, length do
    local value = values[index]
    if not finite(value) then
      result[#result + 1] = gap
    else
      local level
      if range <= 0 then
        level = math.ceil(#set / 2)
      else
        level = math.floor((value - minimum) / range * (#set - 1) + 0.5) + 1
      end
      level = math.max(1, math.min(#set, level))
      result[#result + 1] = set[level]
    end
  end
  local text = table.concat(result)
  if options.pad and #result < width then
    text = string.rep(" ", width - #result) .. text
  end
  return text
end

--- Resolve a series into exactly `width` right-aligned column values.
-- Columns with no sample are `nil` so a caller can draw a gap rather than a
-- zero.  When the series carries timestamp metadata the same one-column-per
-- -interval bucketing the sparkline uses is applied, which keeps a chart and a
-- sparkline built from one history aligned column for column.
function M.buckets(values, width, options)
  if values ~= nil and type(values) ~= "table" then
    error("sparkline values must be a table", 2)
  end
  values, options = values or {}, options or {}
  if type(width) ~= "number" or not finite(width) or width < 0
      or width % 1 ~= 0 or width > MAX_WIDTH then
    error("sparkline width must be an integer in 0..10000", 2)
  end
  local result = {}
  if width == 0 then return result end
  local length = sequence_length(values)
  local bucketed = time_buckets(values, length, width)
  if bucketed then
    for index = 1, width do
      local value = bucketed[index]
      result[index] = finite(value) and value or nil
    end
    return result
  end
  local first = math.max(1, length - width + 1)
  local offset = width - (length - first + 1)
  for index = first, length do
    local value = values[index]
    result[offset + index - first + 1] = finite(value) and value or nil
  end
  return result
end

M.glyphs = glyphs
M.MAX_WIDTH = MAX_WIDTH
M.MAX_POINTS = MAX_POINTS

return M
