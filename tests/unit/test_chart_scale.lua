-- The chart's scale, which had no rule on it.
--
-- `chart` draws a metric's history as columns across a panel's height, and
-- `metric.lua` prints the scale `chart.render` resolves as the panel's top and
-- bottom labels.  So the scale is not decoration: it is two numbers a reader takes
-- as the range the reading moved in.  Increments 101 to 107 gave a rule to the
-- tables, the overlay, the footer, the panel frame, the detail list, the bar array
-- and the stacked bar's legend; this is the last surface that prints numbers
-- derived from a reading rather than the reading itself.
--
-- **The scale was derived from the columns, and a column is not a reading.**
-- `Sparkline.buckets` reduced each column's interval by *averaging* it, and
-- `chart.render` took its minimum and maximum from the columns it had drawn.  A
-- spike shorter than a column was therefore averaged into its neighbours, and the
-- panel printed the average as its top label.  Measured over 135 series -- three
-- shapes, both metadata paths, nine widths, three heights:
--
--   * **30 of them printed a top label below the highest reading in the window.**
--     A series of sixty samples, one of them 100% and the rest 5%, was labelled
--     **36.67** at twenty cells and **18.57** at eight, because the spike was
--     averaged into two and three neighbours.  A sine wave's own amplitude was
--     understated by up to 3.7 points, and an eight-column chart of a noisy series
--     that reached 79.27 was labelled **59.16**.
--   * In every one of those cases the columns and the scale agreed with each other
--     and disagreed with the data, which is what makes it a defect rather than a
--     rounding question: a number on the panel that no reading supports, the same
--     family as the width guards' "a cut cell must not show a different number",
--     one level up.
--
-- **The fix is a column that is a reading: the highest one in its interval.**
-- `Sparkline.buckets` keeps the extreme instead of the mean, and the scale is
-- derived from the window's own readings, which `Sparkline.window` publishes so
-- the scale and the columns cannot drift apart.  The price is measured rather than
-- assumed, and it is the price the *columns* pay, not the scale's: on a series with
-- no spread nothing changes at all (5.00 either way), and on a smooth wave the
-- columns read up to the intra-interval ripple higher -- 86.28 to 90.00 at eight
-- cells -- which is the price of drawing a peak rather than a mean.
--
-- **What this file holds.**  *Every number the panel prints as a scale is a reading
-- the window held*, checked against the widget's own report of what the window
-- held rather than against a second implementation of the window.  *The tallest
-- column is the highest reading*, so a spike shorter than a column is still on the
-- panel.  *A column is a reading from its own interval*, which is what makes the
-- first two statements true of the drawing and not only of the arithmetic.  And the
-- anti-over-correction clauses: a caller that pins `min`/`max` keeps them, and a
-- series with no spread is still reported as flat so `metric.lua` does not print a
-- synthesised scale.
--
-- **The measurement reads the widget's own window, and the first version of this
-- file did not exist for a reason worth recording.**  Its probe compared the axis
-- with the largest sample in the *whole series* and so reported the last-N-samples
-- path as a loss fifteen times over: at four cells a sixty-sample series shows its
-- last four readings, and a spike at sample thirty is outside the window by design.
-- The reference has to be the readings the columns were built from, which is why
-- the window travels out of `buckets` rather than being recomputed here.  A reader
-- with the wrong reference reports a defect that is not there, and reports it
-- fifteen times.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Chart = require("wtop.ui.widgets.chart")
local Sparkline = require("wtop.ui.widgets.sparkline")

local SAMPLE_NS = 1000000000
local COUNT = 60
local WIDTHS = { 4, 8, 12, 20, 30, 40, 60, 80, 120 }
local HEIGHTS = { 1, 3, 8 }

-- A series with timestamps, which is the path a live metric panel's history takes:
-- the window is time-based and several samples share a column.
local function windowed(values)
  local timestamps = {}
  for index = 1, COUNT do timestamps[index] = (index - 1) * SAMPLE_NS end
  values.n = COUNT
  values.timestamps_ns = timestamps
  values.window_ns = COUNT * SAMPLE_NS
  values.end_ns = COUNT * SAMPLE_NS
  return values
end

-- The same readings with no metadata, where a column is one sample and the window
-- is the last `width` of them.
local function plain(values)
  values.n = COUNT
  return values
end

local function series_of(kind, build)
  local values = {}
  for index = 1, COUNT do values[index] = build(index) end
  return (kind == "windowed") and windowed(values) or plain(values)
end

-- Four shapes, each built to have exactly one thing to find: a spike the columns
-- could average away, a smooth wave whose amplitude an average understates, a
-- series with no spread at all, and a series that is mostly holes.
local SHAPES = {
  { "one 100% among 5%", function(index) return index == 30 and 100 or 5 end },
  { "one 0% among 95%", function(index) return index == 30 and 0 or 95 end },
  { "sine 10..90", function(index) return 50 + 40 * math.sin((index - 1) / 60 * 2 * math.pi) end },
  { "steady 42", function() return 42 end },
  { "half the samples missing", function(index) return index % 2 == 0 and 70 or nil end },
}

local stats = {
  renders = 0, columns = 0, spikes = 0, spikes_visible = 0,
  flat = 0, pinned = 0,
  scale_below = {}, scale_above = {}, peak_hidden = {}, not_a_reading = {},
  floor_above = {},
  below_n = 0, above_n = 0, hidden_n = 0, foreign_n = 0, floor_above_n = 0,
}

local function near(left, right)
  return math.abs((left or 0) - (right or 0)) <= 1e-9 * math.max(1, math.abs(right or 0))
end

for _, shape in ipairs(SHAPES) do
  local name, build = shape[1], shape[2]
  for _, kind in ipairs({ "windowed", "plain" }) do
    for _, width in ipairs(WIDTHS) do
      for _, height in ipairs(HEIGHTS) do
        local values = series_of(kind, build)
        local rows, scale = Chart.render(values, width, height, {})
        stats.renders = stats.renders + 1
        local window = Sparkline.window(values, width)
        local columns = Sparkline.buckets(values, width, {})

        -- The dependency the rules lean on, checked: the widget's report of the
        -- window and the window it publishes must be the same table of facts, or
        -- every rule below is comparing a reading against a re-derivation.
        if (window.samples or 0) ~= (scale.samples or 0)
            or not near(window.maximum, scale.window_maximum)
            or not near(window.minimum, scale.window_minimum) then
          stats.foreign_n = stats.foreign_n + 1
          if #stats.not_a_reading < 6 then
            stats.not_a_reading[#stats.not_a_reading + 1] = ("%s %s at %d cells: the widget "
              .. "reports a window of %d samples spanning %s..%s and publishes one of %d "
              .. "spanning %s..%s"):format(name, kind, width, window.samples or 0,
              tostring(window.minimum), tostring(window.maximum), scale.samples or 0,
              tostring(scale.window_minimum), tostring(scale.window_maximum))
          end
        end

        local high = window.maximum
        if high ~= nil and scale.flat then
          stats.flat = stats.flat + 1
        end
        if kind == "windowed" and width < COUNT and high ~= nil then
          -- A spike the columns could have averaged away, and the case the defect
          -- was about: is the highest reading still the tallest column?
          local tallest = nil
          for index = 1, width do
            local value = columns[index]
            if value ~= nil then
              tallest = tallest and math.max(tallest, value) or value
            end
          end
          stats.spikes = stats.spikes + 1
          if near(tallest, high) then stats.spikes_visible = stats.spikes_visible + 1 end
        end

        -- 1. The printed scale covers the readings: a label below the window's
        --    highest reading is a number the data contradicts, and a label above
        --    it is a number the data does not support either -- a scale that
        --    overstates the range is as wrong as one that understates it.
        local low = window.minimum
        if not scale.flat and low ~= nil and scale.minimum > low + 1e-9 then
          -- The other end of the scale, and the end the first version of this file
          -- did not check: a floor above the window's lowest reading is a number the
          -- data contradicts in exactly the way a ceiling below its highest does.
          -- It became reachable when a column became the *highest* reading of its
          -- interval -- the lowest of those columns is not the lowest reading -- and
          -- M309 found it by deriving the scale from the columns again, which is
          -- the old code and which nothing here objected to.
          stats.floor_above_n = stats.floor_above_n + 1
          if #stats.floor_above < 6 then
            stats.floor_above[#stats.floor_above + 1] = ("%s %s at %dx%d: the window held %s "
              .. "as its lowest reading and the panel's bottom label is %s, so the scale does "
              .. "not reach it"):format(name, kind, width, height, tostring(low),
              tostring(scale.minimum))
          end
        end

        if not scale.flat and high ~= nil then
          if scale.maximum < high - 1e-9 then
            stats.below_n = stats.below_n + 1
            if #stats.scale_below < 6 then
              stats.scale_below[#stats.scale_below + 1] = ("%s %s at "
                .. "%dx%d: the window held %s and the panel's top label is %s")
                :format(name, kind, width, height, tostring(high), tostring(scale.maximum))
            end
          elseif scale.maximum > high + 1e-9 then
            stats.above_n = stats.above_n + 1
            if #stats.scale_above < 6 then
              stats.scale_above[#stats.scale_above + 1] = ("%s %s at %dx%d: the window held %s "
                .. "and the panel's top label is %s, so the scale is wider than the data")
                :format(name, kind, width, height, tostring(high), tostring(scale.maximum))
            end
          end
        end

        -- 2. The tallest column is the highest reading, so a spike shorter than a
        --    column is on the panel rather than averaged into its neighbours.
        if not scale.flat and high ~= nil then
          local tallest = nil
          for index = 1, width do
            local value = columns[index]
            if value ~= nil then
              tallest = tallest and math.max(tallest, value) or value
            end
          end
          if tallest ~= nil and tallest < high - 1e-9 then
            stats.hidden_n = stats.hidden_n + 1
            if #stats.peak_hidden < 6 then
              stats.peak_hidden[#stats.peak_hidden + 1] = ("%s %s at %dx%d: the window held %s "
                .. "and the tallest column is %s, so the peak is not on the panel")
                :format(name, kind, width, height, tostring(high), tostring(tallest))
            end
          end
        end

        -- 3. A column is a reading from its own interval, not a statistic.  The
        --    reduction is published, so this asks rather than assumes.
        if scale.reduction ~= "window-max" then
          stats.foreign_n = stats.foreign_n + 1
          if #stats.not_a_reading < 6 then
            stats.not_a_reading[#stats.not_a_reading + 1] = ("the widget reduces a column to "
              .. "%s, so nothing this file says about a reading holds")
              :format(tostring(scale.reduction))
          end
        end
        stats.columns = stats.columns + #rows
      end
    end
  end
end

-- Anti-over-correction: a caller that pins the scale keeps it, whatever the data
-- says, and a series with no spread is still reported flat so the panel does not
-- print a synthesised headroom as if it had been measured.
local PINNED = { { 0, 100 }, { 0, 200 }, { -50, 50 }, { 10, 10.5 } }
for _, range in ipairs(PINNED) do
  local _, scale = Chart.render(series_of("windowed", function(index)
    return index == 30 and 100 or 5 end), 20, 4, { min = range[1], max = range[2] })
  stats.pinned = stats.pinned + 1
  if scale.minimum ~= range[1] or scale.maximum ~= range[2] then
    stats.foreign_n = stats.foreign_n + 1
    if #stats.not_a_reading < 6 then
      stats.not_a_reading[#stats.not_a_reading + 1] = ("a caller that pinned %s..%s got %s..%s")
        :format(tostring(range[1]), tostring(range[2]), tostring(scale.minimum),
          tostring(scale.maximum))
    end
  end
end
local _, flat_scale = Chart.render(series_of("windowed", function() return 42 end),
  20, 4, {})

local failures = {}
local function require_(condition, message)
  if not condition then failures[#failures + 1] = message end
end

require_(flat_scale.flat == true and flat_scale.minimum == 42,
  "a series of sixty identical readings reports flat=" .. tostring(flat_scale.flat)
  .. " and a floor of " .. tostring(flat_scale.minimum) .. ", so a panel with no vertical "
  .. "extent is no longer recognisable as one")
require_(flat_scale.maximum > 42,
  "a flat series reports a maximum of " .. tostring(flat_scale.maximum) .. ", so the "
  .. "synthesised headroom that keeps it off the floor has gone and the plot is a full block")

require_(stats.below_n == 0,
  stats.below_n .. " panels printed a top label below the highest reading in their window:\n    "
  .. table.concat(stats.scale_below, "\n    "))
require_(stats.floor_above_n == 0,
  stats.floor_above_n .. " panels printed a bottom label above the lowest reading in their "
  .. "window:\n    " .. table.concat(stats.floor_above, "\n    "))
require_(stats.above_n == 0,
  stats.above_n .. " panels printed a top label above the highest reading in their window:\n    "
  .. table.concat(stats.scale_above, "\n    "))
require_(stats.hidden_n == 0,
  stats.hidden_n .. " panels did not draw the highest reading their window held:\n    "
  .. table.concat(stats.peak_hidden, "\n    "))
require_(stats.foreign_n == 0,
  stats.foreign_n .. " panels report a window or a reduction this file cannot check:\n    "
  .. table.concat(stats.not_a_reading, "\n    "))

-- Non-vacuity, in the order that matters: the first clause is the one this file
-- exists for.
require_(stats.renders > 0 and stats.spikes > 0,
  "the sweep rendered " .. stats.renders .. " charts and built " .. stats.spikes
  .. " spiking ones, so the rules above were asked about nothing")
require_(stats.spikes > 0 and stats.spikes_visible > 0,
  "no spiking series had its peak on the panel, so the rule about peaks is untested where it "
  .. "matters")
require_(stats.flat > 0,
  "no series in the sweep had no vertical extent, so the flat-series clause is untested")
require_(stats.pinned == #PINNED,
  "only " .. stats.pinned .. " of the " .. #PINNED .. " pinned scales reached this file, so a "
  .. "caller that states a scale is untested")

assert(#failures == 0,
  table.concat(failures, "\n  ") .. "\n  (" .. #failures
  .. " problem(s); they are reported together so a run that finds a defect explains all of it)")

io.write(string.format(
  "ok: chart scale (%d charts over 5 shapes, both metadata paths, %d widths and %d heights; "
  .. "every printed scale is the range the window's own readings span, every one of the %d "
  .. "spiking series has its peak as a column, every column is a reading rather than a "
  .. "statistic, a pinned scale is kept and a series with no spread is still reported flat: "
  .. "%d charts had no vertical extent, %d rows drawn)\n",
  stats.renders, #WIDTHS, #HEIGHTS, stats.spikes, stats.flat, stats.columns))
