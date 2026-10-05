-- A chart axis label is never cut without saying so.
--
-- Increment 88's sweep hooked `Width.truncate` and asked what the product can
-- show after cutting.  That answer was bounded by the hook: the renderer has a
-- second path, `Grid:write(x, y, text, style, max_width)`, which drops whatever
-- does not fit and leaves no marker at all.  Driving the real page render over
-- every tab, eight geometries and all ten catalogues -- 104,192 bounded writes,
-- boxes from 1 to 200 cells -- found the path is real and found what uses it:
-- the metric widget's chart axis, where `1.89 GHz` and `69.8 °C` were written
-- into four-cell boxes and shown as `1.89` and `69.8`.
--
-- The cause is one line.  `metric.lua` measured the axis gutter by rendering the
-- history at **1x1** and measuring the two labels that came back, then rendered
-- the real plot and wrote the labels *that* scale produces.  `Chart.render`
-- derives its range from width-dependent buckets, and at one cell wide
-- `Sparkline.buckets` cannot see a spike that falls between samples: measured,
-- a five-sample series with a 1.89 GHz peak in the middle buckets to a single
-- zero, so the preview range was [0, 1] where the plot's range was
-- [0, 1.89e9].  The gutter was sized from a scale that was not the scale drawn.
--
-- A peak in the *last* sample does not reproduce it, which is why this is worth
-- a fixture rather than a hope: the earlier host sweep missed it most of the
-- time, and the count of clipped writes moved between 0 and 82 across four runs
-- on the same machine.  A data-dependent observation cannot be a guard.
--
-- A fourth line here once fitted every label to its box before writing it, and a
-- fifth clause counted the labels that had to be marked.  Both were measured and
-- removed: across 640 rendered pages, 104,192 bounded writes, eight geometries
-- and all ten catalogues, no label inside a metric widget was ever cut once the
-- gutter was measured from the plot's own width, so the code guarded nothing --
-- and the mutation that removed it was MISSED, which is how that was established
-- rather than assumed.  The count of marked labels was worse than useless: its 62
-- hits were the "no samples on this host" status text in ten languages, not axis
-- labels.  The estimate is the thing doing the work, and this file is the net.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Chart = require("wtop.ui.widgets.chart")
local Format = require("wtop.i18n.format")
local Grid = require("wtop.ui.renderer.grid")
local Metric = require("wtop.ui.widgets.metric")
local Theme = require("wtop.ui.theme")
local Width = require("wtop.ui.renderer.width")

local background = Theme.new(Theme.DEFAULT, {}):style("text.primary", "surface.base")

-- The formatters the view model actually installs as `axis_format`, so a label
-- here is a label the product produces.
local function frequency(value) return Format.frequency(value) end
local function temperature(value) return Format.temperature(value, { precision = 1 }) end

local function series(values)
  local result = { n = #values }
  for index, value in ipairs(values) do result[index] = value end
  return result
end

-- A peak between samples, a peak at the end, a peak at the start, and a flat
-- series.  The middle one is the case the guard exists for; the others are there
-- so a fix cannot pass by breaking the common shapes.
local cases = {
  { name = "peak between samples", format = frequency, value = 1.89e9,
    history = series({ 0.0, 1.89e9, 0.0, 0.0, 0.0 }) },
  { name = "peak last", format = frequency, value = 1.89e9,
    history = series({ 0.0, 0.0, 0.0, 1.89e9 }) },
  { name = "peak first", format = frequency, value = 2.4e9,
    history = series({ 2.4e9, 0.0, 1.2e9, 0.8e9 }) },
  { name = "temperature peak between samples", format = temperature, value = 69.8,
    history = series({ 0.0, 69.8, 0.0, 0.0, 0.0 }) },
  { name = "flat series", format = temperature, value = 40.0,
    history = series({ 40.0, 40.0, 40.0, 40.0 }) },
  { name = "two-digit band edge", format = frequency, value = 9600,
    history = series({ 0.0, 9600.0, 0.0, 0.0, 0.0 }) },
}

-- ---------------------------------------------------------------------------
-- The rule, and the drive.  A cell written into a box is a promise that the text
-- fits; the grid does not mark what it drops, so the widget has to.
-- ---------------------------------------------------------------------------
local cuts, bounded, self_check = {}, 0, false
local self_check_cuts = 0
local real_write = Grid.write
Grid.write = function(self, x, y, text, style, max_width)
  if max_width then
    bounded = bounded + 1
    local limit = math.max(0, math.floor(max_width))
    text = tostring(text or "")
    if Width.display_width(text, self.width_options) > limit then
      if self_check then
        self_check_cuts = self_check_cuts + 1
      else
        cuts[#cuts + 1] = string.format("%q into %d cells, kept %q",
          text, limit, Width.truncate(text, limit, self.width_options))
      end
    end
  end
  return real_write(self, x, y, text, style, max_width)
end

local failures = {}
local function require(condition, message)
  if not condition then failures[#failures + 1] = message end
end

-- The detector, handed a case it must catch.  Its own write is flagged so it
-- cannot be reported as a product defect, which is the third time in this
-- project a probe has handed its own mistake to its own detector.
self_check = true
Grid.new(40, 4):write(1, 1, "1.89 GHz", nil, 4)
require(self_check_cuts == 1,
  "an over-wide write was not detected, so a count of zero proves nothing")
self_check = false

local rendered = 0
for _, case in ipairs(cases) do
  for width = 20, 120 do
    for _, height in ipairs({ 6, 8, 12 }) do
      local model = { id = "probe", label = "Metric", value = case.value,
                      history = case.history, axis_format = case.format }
      local grid = Grid.new(width, height, { default_style = background })
      Metric.render(grid, { x = 1, y = 1, width = width, height = height },
        model, {}, "full")
      rendered = rendered + 1
    end
  end
end
Grid.write = real_write

-- ---------------------------------------------------------------------------
-- Non-vacuity.  Three ways this file could pass without testing anything, and
-- each number is the one the drive produces, so none can drift upward unnoticed.
-- ---------------------------------------------------------------------------
require(rendered == #cases * 101 * 3,
  "the drive ran " .. rendered .. " renders, not the " .. (#cases * 101 * 3)
  .. " this file was written against; the case list or the sweep changed")
require(bounded > 1000,
  "only " .. bounded .. " bounded writes were made; the widget was not exercised")
require(#cuts == 0,
  "a cell was written into a box too small for it, with no marker:\n    "
  .. table.concat(cuts, "\n    "))

-- There is deliberately no second clause saying "and no label had to be marked
-- either".  One was written and removed, for the same reason the matching line of
-- product code was: with nothing in the widget marking an axis label, a
-- measurement of "labels that were marked" is a measurement of zero that can
-- never be anything else -- 62 marked writes inside metric widgets turned out to
-- be the "no samples on this host" status text in ten languages, not axis
-- labels at all.  A clause that cannot fail is worse than no clause, because it
-- reads like coverage.  Both sizing regressions are caught by the clause above
-- anyway, since with the product net removed a mis-sized gutter cuts *silently*.
--
-- So the guard is the net.  A formatter added later whose labels do not survive
-- the gutter fails here rather than quietly on a user's screen.

-- And the fixture has to keep exercising the cause.  If `buckets` ever learned
-- to see a spike at one cell wide, this case would stop reproducing anything and
-- the file would go green while testing a mechanism that no longer exists -- so
-- the disagreement is asserted rather than assumed.
local probe = cases[1]
local _, one_cell = Chart.render(probe.history, 1, 1, { mode = "block" })
local _, many_cells = Chart.render(probe.history, 60, 8, { mode = "block" })
require(one_cell.maximum < many_cells.maximum,
  "a one-cell render now sees the same maximum as a sixty-cell render ("
  .. tostring(one_cell.maximum) .. " vs " .. tostring(many_cells.maximum)
  .. "), so the case that reproduces this defect no longer reproduces it; the "
  .. "measurement behind the fix needs revisiting")

assert(#failures == 0, table.concat(failures, "\n  ") .. "\n  ("
  .. #failures .. " problem(s), reported together)")

io.write(string.format(
  "ok: chart axis labels (%d renders, %d bounded writes, no unmarked cut)\n",
  rendered, bounded))
