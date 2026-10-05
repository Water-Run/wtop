-- The stacked bar and its legend, which had no rule on it.
--
-- Increments 101 to 106 gave a rule to the tables, the overlay, the footer, the
-- panel frame, the two-column detail list and the bar array.  `segments` is what
-- the memory composition panel is drawn with -- a stacked bar plus a legend -- and
-- it was the last widget kind still asking nothing.  Asking it found three
-- defects with one cause: **a legend entry is the only place a memory figure's
-- number appears, and the legend stopped without saying so.**
--
-- **The legend ran out of rows and stopped.**  The loop broke out of the row walk
-- and the panel said nothing: no `+N`, no ellipsis, nothing.  The segment that
-- lost its entry was still on the bar above it as a rule, so the panel showed a
-- part of the composition that had no name and no figure next to it.  Measured
-- through the product's own layouts -- the memory page, ten catalogues, nine
-- terminal sizes, 90 panels, 450 legend entries -- **two panels drop an entry with
-- nothing naming it, and both are Portuguese: at 40 and at 80 columns a 36-by-4
-- panel lost `Livre`.**  Five entries need three legend rows and that panel has
-- two.
--
-- **The legend wrote outside its own rectangle.**  The entry was written at its
-- own `entry_width` with no `Util.truncate`, so an entry wider than the panel ran
-- on past the panel's right edge -- up to 31 cells of it, in the sweep this file
-- drives directly.  **The product's layouts never produce it**: the narrowest
-- rectangle the layout solver gives this widget is 36 cells, and the widest
-- legend entry in any of the ten catalogues fits inside that.  So it is a defect
-- the product cannot currently reach and the next panel that shrinks will, which
-- is why it is measured here by driving the widget rather than swept for in the
-- product and left unmentioned.
--
-- **A third defect was in the fix rather than before it, and it is the one worth
-- keeping.**  The first version wrote a mark and whatever fitted, and counted the
-- entry as drawn: a four-cell panel showed `■ B…`, the widget's report said five
-- of five, and a reader could identify none of them -- a fragment of a label names
-- nothing.  The same family as the width guards' "a cut cell must not show a
-- different value", one size down: **a legend entry is drawn whole or not at
-- all.**  And the blanking that a displaced entry needs is bounded by the panel:
-- the first version wrote `clear - width` spaces from the count onwards, which on
-- a two-cell panel was fifteen spaces starting one cell past the edge, and a space
-- is a write -- in a page render, a neighbour panel's cells being erased.
--
-- **The rules, and each of them is about what a reader can see.**  *The accounting
-- closes*: a segment the widget was given is in the legend, or named by a count,
-- and the only case where neither is possible is a panel too narrow to write the
-- number in, which the widget reports rather than assuming away.  *The count on
-- the panel is the count the widget reports.*  *A drawn entry is identifiable* --
-- checked on the entries whose label survives an ASCII terminal, because the
-- other ones are a limit of the reader and not of the panel.  *The widget writes
-- nothing outside its rectangle*, ink or blank, checked against a sentinel gutter
-- and -- in the product's own layouts -- against the same page rendered without
-- this panel's segments.  And the anti-over-correction clause: a panel that can
-- hold every entry holds every entry and says nothing about a count.
--
-- **The reader found a false clean before it found a defect, twice.**  The first
-- version counted the legend's marks, which are `■` and `○` in the unicode profile
-- and `*` and **`o`** in the ASCII one -- and `o` is a letter that occurs in
-- ordinary text, so it counted 493 marks for 450 entries and called every one of
-- the ninety panels complete.  The second counted cells written outside the panel
-- by looking for ink, and a bug that wrote fifteen *spaces* past the edge was
-- invisible to it, because a space is a write and not a mark: the sentinel it
-- compares against is a character the grid substitutes in one of the two profiles,
-- which made 199 080 untouched cells look torn.  Both mistakes pointed the same
-- way -- **a reader that finds the wrong thing confidently is worse than one that
-- finds nothing**, which is why the third version reads labels, reads the widget's
-- own report, and compares against a sentinel that reads back identically in both
-- profiles.
-- **Mutation evidence: M300-M307, six of eight, and the other two are provably
-- equivalent rather than missed.**  M300 holds nothing back silently, which is the
-- defect itself, and is caught by the rule that reads the drawing alone -- 2 557
-- panels.  M301 names one fewer than is missing (2 233 panels).  M303 places an
-- entry on the next row without asking whether it fits there, which is how a
-- two-cell panel came to hold five truncated ones (530 panels).  M305 never
-- displaces a drawn entry to make room for the count, so a panel with one cell
-- left goes quiet instead (184).  M306 reports the unnameable entries as named
-- anyway, caught by the clause that the accounting must close (140 panels).  M307
-- keeps wrapping past the bottom of the panel (1 183).  **M302 and M304 remove the
-- two bounds in the widget and produce output byte-identical to the fixed
-- baseline's**, which is not a hole in this file: an entry is only placed where it
-- fits whole, so the count's blanking cannot reach past the panel's edge and the
-- text can never be longer than the room it is given.  Both bounds were reached
-- before that placement rule existed -- the first version of the fix wrote fifteen
-- spaces past the edge of a two-cell panel, and wrote the legend text at its own
-- width with no truncation at all -- and the record of an equivalent mutation is
-- more useful than a catch, because it says the bound is insurance and names what
-- it insures against.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grid = require("wtop.ui.renderer.grid")
local I18n = require("wtop.i18n")
local ProcessTable = require("wtop.model.process_table")
local Segments = require("wtop.ui.widgets.segments")
local Theme = require("wtop.ui.theme")
local Util = require("wtop.ui.widgets.util")
local ViewModel = require("wtop.view_model")
local Width = require("wtop.ui.renderer.width")
local Workspace = require("wtop.workspace")

local LOCALES = assert(I18n.available())
local GEOMETRIES = { { 40, 24 }, { 60, 30 }, { 80, 24 }, { 100, 30 }, { 120, 40 },
  { 160, 45 }, { 180, 24 }, { 200, 22 }, { 240, 50 } }
local theme = assert(Theme.new("lua-blue"))
local engine = { history_values = function() return { n = 0 } end }
local fixtures = { capabilities = {}, collectors = {}, inspect = {} }

-- `+N` for N up to `MAX_SEGMENTS` is at most this wide, so a panel of this width
-- can always name what it dropped.  Published so the clause below states the
-- widget's own bound instead of a number copied out of it.
local COUNT_CELLS = 1 + #tostring(assert(type(Segments.MAX_SEGMENTS) == "number"
  and Segments.MAX_SEGMENTS, "segments does not publish the segment cap, so this file "
  .. "would have to keep a copy of the number that bounds the count"))

local function snapshot()
  return {
    memory = {
      total_bytes = 17179869184, used_bytes = 8427483648,
      available_bytes = 8759021568, quality = "fresh",
      swap_total_bytes = 8388608, swap_used_bytes = 0, swap_free_bytes = 8388608,
      swap = { total_bytes = 8388608, free_bytes = 8388608 },
      segments = {
        { id = "used", bytes = 5153960755 },
        { id = "shared", bytes = 858993459 },
        { id = "buffers", bytes = 268435456 },
        { id = "cache", bytes = 2147483648 },
        { id = "free", bytes = 8759021568 },
      },
    },
    pressure = { cpu = { some = { avg10 = 1.2 } }, memory = { some = { avg10 = 0.4 } },
      io = { some = { avg10 = 0.1 } }, quality = "fresh" },
    cpu = { total = { utilization = 12 }, cores = {}, load = {} },
    process = {},
    disk = {},
    network = { interfaces = {}, addresses_status = "fresh" },
    sensors = { devices = {} },
    gpu = {},
    power = { zones = {} },
    power_supplies = { batteries = {}, supplies = {} },
    quality = {},
    connections = { owner_scan = { quality = "fresh" }, connections = {} },
    mounts = { mounts = {} }, workloads = { workloads = {}, summary = {} },
    system = { hostname = "probe", kernel = "linux", uptime_seconds = 98765,
      os_name = "Fedora Linux", os_version = "44 (Workstation Edition)",
      architecture = "x86_64", model = "PROBE-MAINBOARD-0001",
      vendor = "Probe Systems Inc.", bios_vendor = "Probe BIOS",
      bios_version = "1.2.3", serial = "SN-0000000001",
      total_memory_bytes = 17179869184, total_memory_source = "SMBIOS",
      product_support_end = "2027-04-01", chassis = "Desktop",
      virtualization = "kvm", container_hint = "none" },
    inventory = { pci = { devices = {}, total = 0 }, usb = { devices = {}, total = 0 } },
  }
end

local function char_of(grid, x, y)
  local cell = grid and grid:get(x, y)
  return (cell and not cell.continuation) and cell.char or ""
end

-- The panel's own text, joined by newlines so a label cannot match across rows.
local function panel_text(grid, area)
  local rows = {}
  for y = area.y, area.y + area.height - 1 do
    local row = {}
    for x = area.x, area.x + area.width - 1 do
      row[#row + 1] = char_of(grid, x, y)
    end
    rows[#rows + 1] = table.concat(row)
  end
  return table.concat(rows, "\n")
end

-- The count, read the way a reader reads it: a `+` and a number, and this widget
-- writes nothing else of that shape.  `%+` is a literal plus -- in a Lua pattern
-- an unescaped `+` is a quantifier, and a character class of glyphs is a set of
-- bytes.
local function count_in(text)
  local named
  for number in text:gmatch("%+(%d+)") do named = tonumber(number) end
  return named
end

-- A label this profile can still show.  An ASCII terminal substitutes characters
-- outside printable ASCII -- `Búferes` arrives as `B?feres` -- so a reader looking
-- for the exact string finds nothing and would report a whole entry as
-- unaccounted for.  That is a limit of the reader and of the profile, not of the
-- panel, so the label is only dropped from the check when the profile really does
-- rewrite it.  The first version of this dropped every non-ASCII label in both
-- profiles and then compared against a bound that counted the dropped ones as
-- drawn, which failed 194 panels of the unicode sweep that were correct.
local function readable_label(translator, segment, unicode)
  local label = segment.label_id and translator:t(segment.label_id, segment.label)
    or tostring(segment.label or segment.id or "")
  if not unicode and label:find("[^\32-\126]") then return nil end
  return label
end

local stats = {
  pages = 0, panels = 0, entries = 0,
  drawn = 0, named = 0, silent = 0, counted = 0,
  holding = 0, fitting = 0, identifiable = 0,
  shapes = {},
  unclosed = {}, count_off = {}, unidentified = {}, outside = {}, unaccounted = {},
  unclosed_n = 0, count_off_n = 0, unidentified_n = 0, outside_n = 0, outside_cells = 0,
  unaccounted_n = 0,
}

-- The four rules, over one panel.  `outside` is the number of cells outside the
-- rectangle that differ from the reference render, and the caller decides what the
-- reference is: the same page without this panel's segments, or a sentinel gutter.
local function assess(tag, area, model, translator, grid, unicode, outside, report)
  stats.panels = stats.panels + 1
  stats.shapes[area.width .. "x" .. area.height] = true
  stats.entries = stats.entries + #model.segments
  local text = panel_text(grid, area)
  local named = count_in(text)
  if named then
    stats.counted = stats.counted + 1
    stats.named = stats.named + 1
  end
  if report then
    stats.drawn = stats.drawn + (report.drawn or 0)
    stats.silent = stats.silent + (report.silent or 0)
    if (report.named or 0) > 0 then stats.holding = stats.holding + 1 end
    if (report.named or 0) == 0 and (report.silent or 0) == 0 then
      stats.fitting = stats.fitting + 1
    end
  end

  -- 0. **Drawn or named, read from the drawing alone.**  This is the rule the
  --    defect was found with, and it deliberately does not consult the widget's
  --    return value: a widget that reports nothing would be a widget this rule
  --    cannot see, which is what happened the first time.  The pre-fix version
  --    returns no report at all, every report-dependent clause skipped itself, and
  --    the run reported the panel that writes outside itself and four non-vacuity
  --    failures without ever mentioning the legend that stops.
  --
  --    Three assertions, because a profile that substitutes characters limits what
  --    a reader can check and pretending otherwise is how a rule comes to fail on
  --    correct panels -- 1 024 of them, when the count's referent was compared with
  --    the labels one profile could show:
  --      * where the profile can show every label, the labels a reader can name
  --        plus the count equal the list, exactly;
  --      * where it cannot, a label the reader cannot find must still be named by a
  --        count, and the count may not exceed the list -- a count of five on a
  --        five-entry list is right even when two of its labels are not the ones
  --        this reader can spell;
  --      * the labels that are missing are the last ones, so the legend is the
  --        beginning of the list and a reader can count through it.
  local readable, checkable, missing = 0, 0, 0
  local first_missing, last_present = nil, nil
  for index, segment in ipairs(model.segments) do
    local label = readable_label(translator, segment, unicode)
    if label then
      checkable = checkable + 1
      if text:find(label, 1, true) then
        readable = readable + 1
        last_present = index
      else
        missing = missing + 1
        first_missing = first_missing or index
      end
    end
  end
  stats.identifiable = stats.identifiable + readable
  if area.width >= COUNT_CELLS then
    local exact = checkable == #model.segments
    local wrong = exact and (readable + (named or 0) ~= #model.segments)
      or (not exact and ((missing > 0 and named == nil)
        or (readable + (named or 0) > #model.segments)))
    if wrong then
      stats.unaccounted_n = stats.unaccounted_n + 1
      if #stats.unaccounted < 6 then
        stats.unaccounted[#stats.unaccounted + 1] = ("%s: a reader can name %d of the %d "
          .. "labels this profile can show and the panel says %s, so %d of %d are accounted "
          .. "for%s"):format(tag, readable, checkable, tostring(named),
          readable + (named or 0), #model.segments,
          exact and "" or " (this profile rewrites some labels, so the count is the only "
          .. "statement about them)")
      end
    end
  end

  -- 1. The accounting closes, and the count on the panel is the count reported.
  if report then
    local accounted = (report.drawn or 0) + (report.named or 0) + (report.silent or 0)
    if accounted ~= #model.segments then
      stats.unclosed_n = stats.unclosed_n + 1
      if #stats.unclosed < 6 then
        stats.unclosed[#stats.unclosed + 1] = ("%s: the widget reports %d drawn, %d named "
          .. "and %d unnameable, which is %d of %d segments")
          :format(tag, report.drawn or 0, report.named or 0, report.silent or 0,
          accounted, #model.segments)
      end
    end
    if (report.named or 0) > 0 and named ~= report.named then
      stats.count_off_n = stats.count_off_n + 1
      if #stats.count_off < 6 then
        stats.count_off[#stats.count_off + 1] = ("%s: the widget reports %d held back and the "
          .. "panel says %s"):format(tag, report.named, tostring(named))
      end
    end
    if (report.silent or 0) > 0 and area.width >= COUNT_CELLS then
      stats.count_off_n = stats.count_off_n + 1
      if #stats.count_off < 6 then
        stats.count_off[#stats.count_off + 1] = ("%s: a %d-cell panel could have written a "
          .. "%d-cell count and the widget says it had no room")
          :format(tag, area.width, COUNT_CELLS)
      end
    end
  end

  -- 2. Every entry the widget says it drew is one a reader can name -- and the
  --    entries it drew are the first ones in list order, so a label that is not on
  --    the panel must be one the widget did not draw.  Asking "are all the labels
  --    present" instead is the clause that let a four-cell panel's `■ B…` pass
  --    with a report of five drawn out of five.
  if report then
    local drawn = report.drawn or 0
    if first_missing and first_missing <= drawn then
      stats.unidentified_n = stats.unidentified_n + 1
      if #stats.unidentified < 6 then
        stats.unidentified[#stats.unidentified + 1] = ("%s: the widget reports %d drawn and the "
          .. "%dth entry's label is not on the panel, so a drawn entry is a fragment")
          :format(tag, drawn, first_missing)
      end
    end
    -- 3. The legend is the beginning of the list: the labels that are missing are
    --    the last ones.  An entry drawn out of order, or one that is skipped in the
    --    middle, is a legend a reader cannot count through.
    if first_missing and last_present and last_present > first_missing then
      stats.unidentified_n = stats.unidentified_n + 1
      if #stats.unidentified < 12 then
        stats.unidentified[#stats.unidentified + 1] = ("%s: entry %d is on the panel and "
          .. "entry %d is not, so the legend is not the beginning of the list")
          :format(tag, last_present, first_missing)
      end
    end
  end

  -- 4. Nothing outside the rectangle changed, ink or blank.
  if outside and outside > 0 then
    stats.outside_n = stats.outside_n + 1
    stats.outside_cells = stats.outside_cells + outside
    if #stats.outside < 6 then
      stats.outside[#stats.outside + 1] = ("%s: %d cells outside the panel differ from the "
        .. "reference render"):format(tag, outside)
    end
  end
end

-- Phase 1: the product's own layouts.  Every page is rendered twice -- once as
-- the product builds it, once with this panel's segments emptied -- and the
-- difference between the two grids is exactly what this panel wrote.
local real_render = Segments.render
local captured = {}
local function render_page(models, translator, width, height)
  captured = {}
  Segments.render = function(grid, area, model, context, variant)
    local report = real_render(grid, area, model, context, variant)
    captured[#captured + 1] = { area = area, report = report }
    return report
  end
  local workspace = Workspace.new()
  workspace:select("memory")
  local grid = workspace:render(width, height, {
    capabilities = { unicode = true }, i18n = translator, widgets = models, status = {},
    frequency_label = translator:t("sampling.update_frequency",
      { level = translator:t("sampling.frequency.medium") }) })
  Segments.render = real_render
  return grid, captured
end

for _, locale in ipairs(LOCALES) do
  local translator = assert(I18n.new({ locale = locale }))
  for _, geometry in ipairs(GEOMETRIES) do
    local width, height = geometry[1], geometry[2]
    local models = assert(ViewModel.build(engine, snapshot(), translator, fixtures,
      "memory", ProcessTable.new({ sort_key = "cpu", descending = true })))
    local model = models.memory_segments
    if model and #(model.segments or {}) > 0 then
      stats.pages = stats.pages + 1
      local bare = {}
      for key, value in pairs(models) do bare[key] = value end
      bare.memory_segments = { segments = {} }
      local full_grid, areas = render_page(models, translator, width, height)
      local bare_grid = render_page(bare, translator, width, height)
      for _, entry in ipairs(areas) do
        local area = entry.area
        local outside = 0
        for y = 1, height do
          for x = 1, width do
            local inside = x >= area.x and x < area.x + area.width
              and y >= area.y and y < area.y + area.height
            if not inside and char_of(full_grid, x, y) ~= char_of(bare_grid, x, y) then
              outside = outside + 1
            end
          end
        end
        assess(("%s at %d columns"):format(locale, width), area, model, translator,
          full_grid, true, outside, entry.report)
      end
    end
  end
end

-- Phase 2: every rectangle the widget could be given, in both glyph profiles,
-- with a sentinel gutter so a write outside the panel -- ink or blank -- is a
-- changed sentinel.  The sentinel is a character the grid does not substitute in
-- either profile, which is the second half of the fix to the reader that measured
-- 199 080 torn cells that were its own sentinel being rewritten.
local SENTINEL = "@"
for _, locale in ipairs(LOCALES) do
  local translator = assert(I18n.new({ locale = locale }))
  local models = assert(ViewModel.build(engine, snapshot(), translator, fixtures,
    "memory", ProcessTable.new({ sort_key = "cpu", descending = true })))
  local model = models.memory_segments
  for _, unicode in ipairs({ true, false }) do
    for width = 1, 36 do
      for height = 2, 8 do
        local columns, rows = width + 6, height + 2
        local grid = Grid.new(columns, rows, {
          default_style = theme:style("text.primary", "surface.base"), unicode = unicode })
        local fill = Util.style({ theme = theme, capabilities = { unicode = unicode } },
          "text.primary", "surface.base")
        for y = 1, rows do
          for x = 1, columns do grid:write(x, y, SENTINEL, fill, 1) end
        end
        local area = { x = 1, y = 1, width = width, height = height }
        local report = real_render(grid, area, model,
          { theme = theme, i18n = translator, capabilities = { unicode = unicode } })
        local torn = 0
        for y = 1, rows do
          for x = 1, columns do
            local inside = x >= area.x and x < area.x + area.width
              and y >= area.y and y < area.y + area.height
            if not inside and char_of(grid, x, y) ~= SENTINEL then torn = torn + 1 end
          end
        end
        assess(("%s %s at %dx%d"):format(locale, unicode and "unicode" or "ascii",
          width, height), area, model, translator, grid, unicode, torn, report)
      end
    end
  end
end

local failures = {}
local function require_(condition, message)
  if not condition then failures[#failures + 1] = message end
end

require_(stats.unaccounted_n == 0,
  stats.unaccounted_n .. " panels neither drew nor named every legend entry they could have:\n    "
  .. table.concat(stats.unaccounted, "\n    "))
require_(stats.unclosed_n == 0,
  stats.unclosed_n .. " panels do not account for every segment the widget was given:\n    "
  .. table.concat(stats.unclosed, "\n    "))
require_(stats.count_off_n == 0,
  stats.count_off_n .. " panels say something other than what the widget reports, or had the "
  .. "room for a count and did not write one:\n    " .. table.concat(stats.count_off, "\n    "))
require_(stats.unidentified_n == 0,
  stats.unidentified_n .. " panels report a drawn legend entry a reader cannot name:\n    "
  .. table.concat(stats.unidentified, "\n    "))
require_(stats.outside_n == 0,
  stats.outside_n .. " panels wrote outside their own rectangle, " .. stats.outside_cells
  .. " cells in all:\n    " .. table.concat(stats.outside, "\n    "))

-- Anti-over-correction: a panel with room for every entry must show every entry,
-- must not name a count, and must still draw its bar.  Without this, "always write
-- +N" and "always draw one entry" both pass a file that only asks that nothing be
-- lost.
local wide = {}
for index, id in ipairs({ "used", "shared", "buffers", "cache", "free" }) do
  wide[index] = { id = id, label = id, bytes = 5153960755 - index * 100, empty = id == "free",
    display_value = "4,8 GiB" }
end
local wide_grid = Grid.new(60, 6,
  { default_style = theme:style("text.primary", "surface.base"), unicode = true })
local wide_report = Segments.render(wide_grid, { x = 1, y = 1, width = 60, height = 6 },
  { title = "Composition", segments = wide }, { theme = theme, capabilities = { unicode = true } })
local wide_text = panel_text(wide_grid, { x = 1, y = 1, width = 60, height = 6 })
require_(wide_report and wide_report.drawn == 5 and (wide_report.named or 0) == 0,
  "a 60-by-6 panel with room for all five entries reports drawn="
  .. tostring(wide_report and wide_report.drawn) .. " and named="
  .. tostring(wide_report and wide_report.named) .. ", so the overflow path is being taken "
  .. "when the list fits")
require_(count_in(wide_text) == nil and wide_text:find("free", 1, true),
  "a panel that fits its legend must not carry a count, and must carry the last entry: "
  .. string.format("%q", wide_text))
require_(wide_report and (wide_report.in_bar or 0) == 5,
  "a 60-cell panel drew " .. tostring(wide_report and wide_report.in_bar)
  .. " segments in the bar, so the count path is being taken at the cost of the bar")
-- And the other end: a panel one cell wide cannot name anything, and says so rather
-- than going quiet -- `silent` is what keeps the accounting above from being a rule
-- that cannot fail.
local tiny_grid = Grid.new(4, 4,
  { default_style = theme:style("text.primary", "surface.base"), unicode = true })
local tiny_report = Segments.render(tiny_grid, { x = 1, y = 1, width = 1, height = 4 },
  { segments = wide }, { theme = theme, capabilities = { unicode = true } })
require_(tiny_report and (tiny_report.silent or 0) > 0,
  "a one-cell panel reports silent=" .. tostring(tiny_report and tiny_report.silent)
  .. ", so a case where nothing can be named is passing as a case where nothing was dropped")

-- Non-vacuity, in the order that matters: the first clause is the one this file
-- exists for.
require_(stats.holding > 0,
  "not one of the " .. stats.panels .. " panels held an entry back, so the count on the "
  .. "panel is untested and the rule was applied only where nothing happens")
require_(stats.fitting > 0,
  "no panel in the sweep fitted its legend, so a panel that draws everything is untested")
require_(stats.counted > 0 and stats.holding > 0,
  "no panel carried a count, so the count cannot be compared with what the widget reports")
require_(stats.pages > 0 and stats.entries > 0,
  "the sweep offered no segments, so none of the rules above was asked about anything")
require_(stats.silent > 0,
  "no panel was ever too narrow to name what it dropped, so the clause that keeps the "
  .. "accounting from being unfalsifiable is untested")

assert(#failures == 0,
  table.concat(failures, "\n  ") .. "\n  (" .. #failures
  .. " problem(s); they are reported together so a run that finds a defect explains all of it)")

local shapes = {}
for shape in pairs(stats.shapes) do shapes[#shapes + 1] = shape end
table.sort(shapes)
local widest = 0
for _, shape in ipairs(shapes) do
  widest = math.max(widest, tonumber(shape:match("^(%d+)")))
end
io.write(string.format(
  "ok: stacked bars (%d panels -- %d from the product's own layouts and the rest driven at "
  .. "every rectangle from 1 to 36 cells wide and 2 to 8 tall in both glyph profiles -- over "
  .. "%d segments, of which %d are in the legend, %d are named by a count and %d are reported "
  .. "unnameable because the panel is too narrow to write the number in; every panel accounts "
  .. "for all of them, every count on a panel is the count the widget reports, every entry the "
  .. "widget says it drew is one a reader can name, and no panel wrote a cell outside itself; "
  .. "%d panels hold something back and %d fit; %d panel shapes, the widest %d cells)\n",
  stats.panels, stats.pages, stats.entries, stats.drawn, stats.named, stats.silent,
  stats.holding, stats.fitting, #shapes, widest))
