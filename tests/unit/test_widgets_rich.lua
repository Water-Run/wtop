package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Bars = require("wtop.ui.widgets.bars")
local Chart = require("wtop.ui.widgets.chart")
local Grid = require("wtop.ui.renderer.grid")
local KeyValue = require("wtop.ui.widgets.key_value")
local Metric = require("wtop.ui.widgets.metric")
local Segments = require("wtop.ui.widgets.segments")
local Sparkline = require("wtop.ui.widgets.sparkline")
local Table = require("wtop.ui.widgets.table")
local Theme = require("wtop.ui.theme")
local Width = require("wtop.ui.renderer.width")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "values differ",
      tostring(expected), tostring(actual)), 2)
  end
end

local function context()
  return {
    theme = Theme.new("lua-blue", { truecolor = true }),
    capabilities = { unicode = true },
    surface = "surface.raised",
  }
end

-- ---------------------------------------------------------------------------
-- Chart
-- ---------------------------------------------------------------------------

local series = { n = 8, 0, 10, 20, 30, 40, 50, 60, 70 }
local rows, scale = Chart.render(series, 8, 4, { min = 0, max = 80 })
equal(#rows, 4, "chart honours its height")
for _, row in ipairs(rows) do
  equal(Width.display_width(row), 8, "every chart row is exactly `width` cells")
end
equal(scale.minimum, 0, "explicit minimum survives")
equal(scale.maximum, 80, "explicit maximum survives")
-- Growing series must grow downward-to-upward: the last column is the tallest,
-- so the top row has ink only at its right edge.
assert(rows[1]:sub(-3) ~= "   ", "the tallest column must reach the top row")
assert(rows[1]:sub(1, 1) == " ", "the shortest column must not reach the top row")

-- A gap is a gap, never a zero.
local gapped = { n = 3, 5, nil, 5 }
local gap_rows = Chart.render(gapped, 3, 2, { min = 0, max = 10, gap = "·" })
-- The gap glyph is multi-byte, so search rather than slicing bytes.
assert(gap_rows[2]:find("·", 1, true), "missing samples render as a gap marker")
assert(not gap_rows[1]:find("·", 1, true), "the gap marker sits on the baseline row only")

-- A flat series has no measured extent and must say so rather than inventing
-- a ceiling the reader would take for a real reading.
local _, flat_scale = Chart.render({ n = 3, 7, 7, 7 }, 3, 3, {})
assert(flat_scale.flat, "an all-equal series must be reported as flat")
local _, varied_scale = Chart.render({ n = 3, 1, 5, 9 }, 3, 3, {})
assert(not varied_scale.flat, "a varying series is not flat")

-- Any non-zero sample must leave a visible mark; rendering it as blank would
-- read as missing data.
local tiny = Chart.render({ n = 1, 0.0001 }, 1, 4, { min = 0, max = 100 })
assert(tiny[4] ~= " ", "a small non-zero sample must still be visible")

-- Chart and sparkline must agree on bucketing.
local buckets = Sparkline.buckets(series, 8)
equal(#buckets, 8, "bucket count matches the requested width")
equal(buckets[8], 70, "the newest sample lands in the last column")

-- ---------------------------------------------------------------------------
-- Metric severity
-- ---------------------------------------------------------------------------

equal(Metric.severity(10, { warn = 70, critical = 90 }), "normal", "below warn")
equal(Metric.severity(75, { warn = 70, critical = 90 }), "elevated", "at warn")
equal(Metric.severity(95, { warn = 70, critical = 90 }), "critical", "past critical")
-- Battery charge and free capacity are bad when low, not when high.
equal(Metric.severity(10, { warn = 30, critical = 15 }, true), "critical", "inverted critical")
equal(Metric.severity(80, { warn = 30, critical = 15 }, true), "normal", "inverted normal")
equal(Metric.severity(nil, { warn = 1, critical = 2 }), "normal", "missing value is not an alert")

-- Colour must encode severity while the symbol keeps encoding data quality:
-- the two signals are independent, and conflating them made a CPU at 2% and a
-- CPU at 100% render identically.
local hot = Grid.new(30, 4)
Metric.render(hot, { x = 1, y = 1, width = 30, height = 4 }, {
  label = "CPU", value = 97, display_value = "97%", min = 0, max = 100,
  quality = "fresh", thresholds = { warn = 70, critical = 90 },
  history = { n = 2, 90, 97 },
}, context(), "full")
local cool = Grid.new(30, 4)
Metric.render(cool, { x = 1, y = 1, width = 30, height = 4 }, {
  label = "CPU", value = 3, display_value = "3%", min = 0, max = 100,
  quality = "fresh", thresholds = { warn = 70, critical = 90 },
  history = { n = 2, 2, 3 },
}, context(), "full")
local hot_cell, cool_cell = hot:get(3, 2), cool:get(3, 2)
assert(hot_cell.style.fg.r ~= cool_cell.style.fg.r
    or hot_cell.style.fg.g ~= cool_cell.style.fg.g
    or hot_cell.style.fg.b ~= cool_cell.style.fg.b,
  "a critical value must not render in the same colour as a calm one")

-- A resource with no samples at all must say so instead of drawing an axis.
local absent = Grid.new(40, 6)
Metric.render(absent, { x = 1, y = 1, width = 40, height = 6 }, {
  label = "GPU", value = nil, quality = "unavailable", history = { n = 0 },
  axis_format = function(value) return string.format("%d Hz", value) end,
}, context(), "full")
local absent_text = table.concat({
  absent:row_text(1), absent:row_text(2), absent:row_text(3),
  absent:row_text(4), absent:row_text(5), absent:row_text(6),
}, "\n")
assert(not absent_text:find("Hz", 1, true),
  "an empty series must not be labelled with a synthesised axis")

-- ---------------------------------------------------------------------------
-- Key/value alignment
-- ---------------------------------------------------------------------------

local kv = Grid.new(40, 6)
KeyValue.render(kv, { x = 1, y = 1, width = 40, height = 6 }, {
  entries = {
    { label = "主机名", value = "alpha" },
    { label = "Architecture", value = "beta" },
    { label = "虚拟内存", value = "gamma" },
  },
}, context(), "full")
-- Alignment is a property of display columns, not byte offsets: "主机名" is
-- nine bytes but six columns, which is exactly the confusion that broke the
-- old hand-padded lists.
local function value_column(row, needle)
  local at = row:find(needle, 1, true)
  if not at then return nil end
  return Width.display_width(row:sub(1, at - 1)) + 1
end
local first = value_column(kv:row_text(1), "alpha")
local second = value_column(kv:row_text(2), "beta")
local third = value_column(kv:row_text(3), "gamma")
assert(first and second and third, "all values render")
equal(first, second, "a CJK label must align with an ASCII one")
equal(second, third, "two CJK labels of different widths must align")

-- Content that cannot fit must announce the remainder rather than vanish.
local overflowing = {}
for index = 1, 20 do
  overflowing[index] = { label = "k" .. index, value = "v" .. index }
end
local clipped = Grid.new(30, 5)
local report = KeyValue.render(clipped, { x = 1, y = 1, width = 30, height = 5 },
  { entries = overflowing }, context(), "full")
assert(report.scrollable, "an overflowing list reports that it can scroll")
equal(report.total, 20, "the full entry count is reported")
assert(clipped:row_text(5):find("more", 1, true), "overflow is announced on the last row")

local scrolled = Grid.new(30, 5)
KeyValue.render(scrolled, { x = 1, y = 1, width = 30, height = 5 },
  { entries = overflowing, offset = 6 }, context(), "full")
assert(scrolled:row_text(1):find("k7", 1, true), "offset moves the first visible entry")

-- ---------------------------------------------------------------------------
-- Bars
-- ---------------------------------------------------------------------------

local bars = Grid.new(60, 4)
local bar_report = Bars.render(bars, { x = 1, y = 1, width = 60, height = 4 }, {
  items = {
    { label = "0", value = 95, display_value = "95%" },
    { label = "1", value = 5, display_value = "5%" },
  },
  min = 0, max = 100, thresholds = { warn = 70, critical = 90 },
}, context(), "full")
assert(bar_report.drawn == 2, "every item is drawn")
assert(bars:row_text(1):find("95%", 1, true), "bar values are labelled")

-- Height is spent before width: a longer bar resolves more than a second
-- column does.
local many = {}
for index = 1, 16 do
  many[index] = { label = tostring(index), value = index * 6, display_value = index .. "%" }
end
local tall = Grid.new(60, 8)
local tall_report = Bars.render(tall, { x = 1, y = 1, width = 60, height = 8 },
  { items = many, min = 0, max = 100 }, context(), "full")
assert(tall_report.rows <= 8, "the array never exceeds the available height")
assert(tall_report.columns >= 2, "sixteen items cannot fit one column in eight rows")

-- ---------------------------------------------------------------------------
-- Segments
-- ---------------------------------------------------------------------------

-- The allocation must be exact: a stacked bar that overflows its width would
-- corrupt the row, and one that underflows leaves a false gap.
for _, width in ipairs({ 1, 7, 13, 40, 79 }) do
  local widths = Segments.allocate({
    { bytes = 1000 }, { bytes = 3 }, { bytes = 512 }, { bytes = 0 },
  }, width)
  local total = 0
  for _, value in ipairs(widths) do total = total + value end
  equal(total, width, "segment widths must sum to the bar width at " .. width)
end
local segments_grid = Grid.new(50, 3)
Segments.render(segments_grid, { x = 1, y = 1, width = 50, height = 3 }, {
  segments = {
    { id = "used", label = "Used", bytes = 100, display_value = "100 B" },
    { id = "free", label = "Free", bytes = 300, display_value = "300 B", empty = true },
  },
}, context(), "full")
equal(Width.display_width(segments_grid:row_text(1)), 50, "the bar fills its row")
assert(segments_grid:row_text(2):find("Used", 1, true), "the legend names each segment")

-- ---------------------------------------------------------------------------
-- Table: per-cell styling, column priority, reported geometry
-- ---------------------------------------------------------------------------

local columns = {
  { key = "name", label = "Name", width = 20, min_width = 10, priority = 50 },
  { key = "cpu", label = "CPU", width = 8, min_width = 6, priority = 95,
    sort_key = "cpu", align = "right",
    token = function(_, row) return row.cpu_value > 80 and "metric.critical" or nil end,
    bar = function(_, row) return row.cpu_value / 100 end },
  { key = "extra", label = "Extra", width = 12, min_width = 10, priority = 10 },
}
local rows_model = {
  { name = "alpha", cpu = "95%", cpu_value = 95, extra = "x" },
  { name = "beta", cpu = "2%", cpu_value = 2, extra = "y" },
}

-- A narrow table keeps the high-priority column and drops the low-priority
-- one, rather than filling up in declaration order.
local narrow = Grid.new(20, 4)
local narrow_meta = Table.render(narrow, { x = 1, y = 1, width = 20, height = 4 },
  { columns = columns, rows = rows_model }, context(), "full")
assert(narrow_meta.columns_visible < narrow_meta.columns_total, "columns were dropped")
assert(narrow:row_text(1):find("CPU", 1, true),
  "the highest-priority column must survive a narrow table")

-- Dropping columns silently is what hid capacity data; the count is reported.
assert(narrow:row_text(4):find(tostring(narrow_meta.columns_visible), 1, true),
  "hidden columns are announced in the status row")

local wide = Grid.new(60, 6)
local meta = Table.render(wide, { x = 1, y = 1, width = 60, height = 6 },
  { columns = columns, rows = rows_model, selected = 1,
    sort_key = "cpu", sort_descending = true }, context(), "full")
equal(meta.columns_visible, 3, "a wide table keeps every column")
equal(meta.rows_y, 2, "data starts below the header")
assert(meta.visible_rows >= 2, "the drawn row count is reported")
equal(meta.headers[1].sort_key, "cpu", "sortable headers expose hit boxes")
assert(wide:row_text(1):find("↓", 1, true), "the active sort column shows its direction")

-- Per-cell tokens let one column carry severity without repainting the row.
local hot_row = wide:get(meta.headers[1].x, meta.rows_y)
local calm_row = wide:get(meta.headers[1].x, meta.rows_y + 1)
assert(hot_row.style.fg and calm_row.style.fg, "cells are styled")

return true
