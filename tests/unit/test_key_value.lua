-- The two-column detail list, which had no rule on it at all.
--
-- Increments 101 to 104 gave the tables a rule, the overlay two, the footer
-- three and the panel frame one.  `key_value` is the last widget kind, and it is
-- the one every "Details" panel is: a list of labels with values beside them,
-- where the label column is sized to the longest label in the list and the
-- value column gets what is left.  It had been asked nothing, and asking it
-- found two defects that share one cause.
--
-- **The cause.**  Three of the four budgets in `M.render` counted *entries* to
-- decide how many *rows* were needed, and a section heading is not one row: it
-- spends a row of its own plus a blank row before it.  So a list of nine
-- entries with a heading needs ten rows, the overflow test believed nine rows
-- were enough, and the entry that fell off the bottom went nowhere -- with no
-- marker, and with `scrollable = false`, so the event loop would not even let
-- the reader scroll to it.  Measured over the product's own layouts -- 3 060
-- renders, 53 areas, ten catalogues, three fixtures, 14 900 entries offered:
-- **420 renders held an entry back and named it by something else, 1 720 entries
-- in all, and 90 of those renders had no count on the panel at all.**  The two
-- symptoms are the same bug seen from two ends -- `overflow` said "it fits" where
-- it did not (nothing drawn, nothing named), and `remaining` subtracted a row
-- count from an entry count (a count, but a wrong one: `▾ 6 weitere` above four
-- hidden entries).
--
-- **And a one-cell arithmetic slip.**  The value column is `area.width -
-- label_width - 1`, the gap being the one cell between the columns, but the
-- label budget reserved `area.width - MIN_VALUE_WIDTH`.  The floor the widget
-- declares for itself, 8, was therefore reachable at 7: 611 rendered rows in
-- the sweep had a value column narrower than the widget says it guarantees, the
-- narrowest being 7 cells at 35 wide.
--
-- After the fix: all 570 renders that hold something back name the exact count,
-- nothing is named by nothing, the narrowest value column is 8, and no row is
-- under the floor.  The price is stated rather than absorbed -- 150 renders are
-- new to holding something back, because the marker row is now reserved on the
-- ones whose heading needed it, and the entry that row costs is one the panel
-- used to drop without saying so.
--
-- The multi-column path is the third thing here, and it needed a different kind
-- of evidence.  Sweeping the product never once lost an entry through it: the
-- layout solver's form minima keep this widget's lists short enough, and all
-- 420 defect renders were single-column.  Driving the widget directly with a
-- list the solver does not produce -- 14 entries into 76 by 5 -- the code before
-- the fix dropped four of them, with no marker and `scrollable = false`, and the
-- fixed code falls back to one column that names all ten.  That is a real defect
-- in a reusable component with the product's own layouts as the only reason it
-- does not fire, so both facts are written down here rather than one of them
-- being quietly dropped.
--
-- The measurement reads the drawing, not the arithmetic, and that is not a
-- stylistic choice.  The first version of this probe re-implemented the
-- label/value split to ask "is the value column under its floor", and so it
-- could not tell its own arithmetic from the widget's; it also built its own
-- grids, which are places the product never draws.  This one hooks
-- `KeyValue.render`, mirrors each render into a private grid with one mark
-- planted in every entry, and reads the marks back: a mark's own cell *is* the
-- value column's first cell, so the value width is measured off the drawing,
-- and the count on the overflow row is the count the reader sees.  Seven
-- versions of that reader were wrong before this one, and every one of them
-- reported a result:
--   * a byte offset used as a cell offset, which put a mark at column -9 in a row
--     of CJK labels;
--   * one mark read per row, which is wrong the moment two columns share a line
--     and invented a 14-entry panel losing 2;
--   * a marker recognised by the word after it, and French says `▾ 6 de plus`, two
--     words, so every French row read as no marker at all;
--   * a marker glyph inside a Lua character class, which is a set of *bytes*, so
--     `[▾▴^v]` matched one byte of a three-byte glyph and **no row in any of the
--     ten locales was ever recognised** -- a 100% "names nothing" across 540
--     overflow renders, reported as a total failure of the product;
--   * a tuple of mine bound one position off, so the drawn count was the offered
--     one and a panel that draws two reported "drew 5 of five";
--   * and, twice, the filler.  Planting a mark in a blank filler makes it
--     readable *and* makes the `entry.blank` branch unreachable at the same time,
--     so a filler that cost no row passed a guard written to catch it; and
--     counting every empty body row as a filler invented 130 failures in the
--     sweep, every one of them the blank line the widget puts above a heading.
--     The reader is back to counting marks only, and the branch is left unmeasured
--     on purpose -- the note where the filler case used to be says why, and a row
--     of nothing is a row of nothing.
--
-- The rewrite is also the only cross-check available here: it reproduced the
-- sweep's counts digit for digit (14 900 offered, 11 890 drawn, 570 holding
-- something back), and an unexplained count is the measurement, not a footnote.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Collectors = require("wtop.collectors")
local Grid = require("wtop.ui.renderer.grid")
local I18n = require("wtop.i18n")
local Inspectors = require("wtop.inspectors")
local KeyValue = require("wtop.ui.widgets.key_value")
local ProcessTable = require("wtop.model.process_table")
local Theme = require("wtop.ui.theme")
local Util = require("wtop.ui.widgets.util")
local ViewModel = require("wtop.view_model")
local Workspace = require("wtop.workspace")

local LOCALES = assert(I18n.available())
local failures = {}
local function require(condition, message)
  if not condition then failures[#failures + 1] = message end
end

local theme = Theme.new(Theme.DEFAULT, { unicode = true })
local capabilities = { unicode = true }
local GEOMETRIES = { { 40, 24 }, { 60, 30 }, { 80, 24 }, { 100, 30 }, { 120, 40 },
  { 160, 45 }, { 180, 24 }, { 200, 22 }, { 240, 50 } }

-- The floor is asked of the widget, not written down here, because a copy of the
-- number is a number that stops being checked the day it changes.
require(type(KeyValue.MIN_VALUE_WIDTH) == "number" and KeyValue.MIN_VALUE_WIDTH > 0,
  "the widget does not publish the value-column floor it declares, so this file cannot "
  .. "ask about it and a floor that changes would leave the rule asserting the old number")

-- The fixture builds `quality` from the product's own collector list, so the
-- Permissions row -- whose label is `table.concat(denied, ", ")`, the one label
-- in the product that is not a translation -- is as long as wtop can make it:
-- all seventeen collectors denied, 159 cells of it, which is what pins the value
-- column to its floor in every one of the ten locales.
local function capabilities_table()
  local ids = {}
  for id in pairs(Collectors.constructors) do ids[#ids + 1] = id end
  table.sort(ids)
  local states = { "available", "unavailable", "denied", "degraded", "error" }
  local result = { inspectors = {} }
  for index, id in ipairs(ids) do
    local state = states[(index % #states) + 1]
    result[id] = { state = state, available = state == "available" }
  end
  for index, id in ipairs(Inspectors.new_default().order) do
    local state = states[index]
    result.inspectors[id] = { state = state, available = state == "available" }
  end
  return result
end

local function snapshot(denied_count)
  local quality = {}
  local ids = {}
  for id in pairs(Collectors.constructors) do ids[#ids + 1] = id end
  table.sort(ids)
  for index, id in ipairs(ids) do
    quality[id] = index <= denied_count
      and { status = "denied", quality = "unavailable" }
      or { status = "ok", quality = "fresh" }
  end
  local cores = {}
  for index = 0, 127 do
    cores[index + 1] = { name = "cpu" .. index, utilization = 0, user = 0, system = 0,
      iowait = 0, irq = 0, steal = 0, quality = "fresh" }
  end
  local processes = {}
  for index = 1, 7 do
    processes[index] = { pid = 1000 + index, starttime_ticks = index, name = "p" .. index,
      command = "p" .. index, user = "tester", state = "S", cpu_percent = index,
      resident_bytes = 1024 * index, memory_summary = { resident_bytes = 1024 * index } }
  end
  return {
    host = { hostname = "probe", kernel = "linux", uptime_seconds = 98765 },
    cpu = { usage_percent = 12, quality = "fresh", cores = cores },
    cpu_info = { logical_cores = 128, model = "probe cpu" },
    memory = { total_bytes = 16 * 1024 * 1024 * 1024, used_bytes = 8 * 1024 * 1024 * 1024,
      available_bytes = 8 * 1024 * 1024 * 1024, quality = "fresh" },
    pressure = { cpu = { some = { avg10 = 1.2 } }, memory = { some = { avg10 = 0.4 } },
      io = { some = { avg10 = 0.1 } }, quality = "fresh" },
    disks = { devices = { { id = "sda", model = "Samsung SSD 990 PRO 2TB",
      size = 2 * 1024 * 1024 * 1024, medium = "SSD", quality = "fresh" } } },
    network = { interfaces = {}, addresses_status = "fresh" },
    processes = { list = processes, truncated = false, clock_ticks_per_second = 100,
      total = #processes, process_candidates = #processes },
    cpu_frequency = { policies = {}, current_quality = "fresh", current_hz = 1890000000 },
    gpus = { devices = {}, process_scan = { status = "ok", quality = "partial" } },
    sensors = { devices = {} }, power = { zones = {} },
    quality = quality,
    connections = { owner_scan = { quality = "fresh" }, connections = {} },
    mounts = { mounts = {} }, workloads = { workloads = {}, summary = {} },
    system = { hostname = "probe", kernel = "linux", uptime_seconds = 98765,
      os_name = "Fedora Linux", os_version = "44 (Workstation Edition)",
      architecture = "x86_64", model = "PROBE-MAINBOARD-0001",
      vendor = "Probe Systems Inc.", bios_vendor = "Probe BIOS",
      bios_version = "1.2.3", serial = "SN-0000000001",
      total_memory_bytes = 17179869184, total_memory_source = "SMBIOS",
      product_support_end = "2027-04-01", chassis = "Desktop",
      virtualization = "kvm", container_hint = "none",
      command_line = "BOOT_IMAGE=(hd0,msdos1)/vmlinuz-6.12.0 root=UUID=6f1c "
        .. "ro quiet rhgb console=tty0 rd.luks.name=6f1c-luks systemd.machine_id=6f1c "
        .. "systemd.show_status=false" },
    inventory = { pci = { devices = {}, total = 0 }, usb = { devices = {}, total = 0 } },
  }
end

-- Three-cell marks.  Three cells is the widest mark the reader can still name
-- with two follower cells, and the value column is never narrower than the
-- floor this file checks, so a mark cannot be cut by the very column whose
-- width is under test.
local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local VALUE_MARK = "#"
local HEADING_MARK = "!"
local function mark(index)
  local column = math.floor((index - 1) / 26) + 1
  return "#" .. LETTERS:sub(column, column)
    .. LETTERS:sub((index - 1) % 26 + 1, (index - 1) % 26 + 1)
end

local stats = {
  renders = 0, empty = 0, with_sections = 0, overflowing = 0,
  overflowing_with_sections = 0, columns_over_one = 0,
  offered = 0, drawn = 0, held_back = 0, named = 0, unnamed = {}, spurious = 0,
  unnamed_renders = 0, unnamed_entries = 0, unnamed_silent = 0,
  narrowest_value = math.huge, narrowest_at = "", under_floor = {}, capped = {},
  largest_list = 0,
}
local areas = {}
local real_render = KeyValue.render

local function row_text(grid, x, y, right)
  local parts = {}
  for column = x, right do
    local cell = grid:get(column, y)
    parts[#parts + 1] = cell and cell.char or " "
  end
  return table.concat(parts)
end

-- The reader: every mark on a row, read by cell, walking the grid's own cells
-- rather than a string built out of them.  A grid stores a two-cell glyph as its
-- lead cell plus a continuation cell whose `char` is the empty string, so a row
-- assembled from `char` fields is missing a byte per wide glyph and its display
-- width over-counts the cells -- the mark in a row of four CJK cells came back at
-- column 10 instead of 5.  That was the third wrong version of this reader, and
-- like the others it reported a result rather than failing.
local function read_body(grid, area, last_row_is_count)
  local values, headings = {}, {}
  local bottom = area.y + area.height - (last_row_is_count and 1 or 0) - 1
  for y = area.y, bottom do
    local x = area.x
    while x <= area.x + area.width - 1 do
      local cell = grid:get(x, y)
      local char = (cell and not cell.continuation) and cell.char or ""
      if char == VALUE_MARK or char == HEADING_MARK then
        -- Every mark on the row, not the first: a multi-column render puts one
        -- entry per column on the same line, and a reader that stops at the
        -- first mark invents a lost entry out of every two-column row.  That was
        -- the second wrong version of this reader, and it reported "a 14-entry
        -- panel lost 2 entries" as though the product had.
        local letters = {}
        for step = 1, 2 do
          local follower = grid:get(x + step, y)
          letters[step] = (follower and not follower.continuation) and follower.char or ""
        end
        if letters[1]:match("^[%a]$") and letters[2]:match("^[%a]$") then
          local tag = char .. letters[1] .. letters[2]
          if char == VALUE_MARK then
            values[tag] = x
          else
            headings[tag] = x
          end
          x = x + 3
        else
          x = x + 1
        end
      else
        x = x + 1
      end
    end
  end
  local value_count = 0
  for _ in pairs(values) do value_count = value_count + 1 end
  local heading_count = 0
  for _ in pairs(headings) do heading_count = heading_count + 1 end
  return values, value_count + heading_count, value_count, heading_count
end

-- One mark per entry that draws something, planted in place of what it draws.
-- A value row gets `#`, a heading gets `!`, and a blank filler is left alone --
-- and a filler is the one entry this file cannot read back, which is stated
-- where it is stated rather than papered over.  Two characters rather than one
-- let the reader tell a heading from a value row, which is what makes the blank
-- line above a heading countable by omission rather than by guessing.
local function stamped_model(model)
  local out = {}
  for index, entry in ipairs(type(model.entries) == "table" and model.entries or {}) do
    if type(entry) == "table" then
      local copy = {}
      for key, value in pairs(entry) do copy[key] = value end
      if entry.section then
        local tag = mark(index)
        copy.section = HEADING_MARK .. tag:sub(2)
        copy.section_id = nil
      elseif not entry.blank then
        copy.value = mark(index)
      end
      out[#out + 1] = copy
    end
  end
  local probe = {}
  for key, value in pairs(model) do if key ~= "entries" then probe[key] = value end end
  probe.entries = out
  return probe, #out
end

-- The overflow row, read the way a reader reads it: a marker glyph, a number,
-- and the word this locale uses for "more" -- which is two words in French and
-- one in Russian, so the word is asked of the product rather than assumed.
--
-- The glyphs are compared as strings, never inside a character class: a Lua
-- pattern class is a set of *bytes*, so `[▾▴^v]` matches one byte of a
-- three-byte glyph and then fails on the other two, and no row in any of the
-- ten locales was ever recognised as a marker.  That version reported a result
-- too: a 100% "names nothing" across 540 overflow renders.
local GLYPHS = { "\u{25be}", "\u{25b4}", "v", "^" }
local function starts_with_marker(text)
  for _, glyph in ipairs(GLYPHS) do
    local head = text:sub(1, #glyph)
    if head == glyph and text:sub(#glyph + 1, #glyph + 2):match("^ %d") then
      return true
    end
  end
  return false
end

local function named_count(context)
  local more = Util.t(context, "ui.more_rows", "more")
  return function(grid, area)
    local trimmed = row_text(grid, area.x, area.y + area.height - 1,
      area.x + area.width - 1):gsub("^%s+", ""):gsub("%s+$", "")
    if not starts_with_marker(trimmed) then return nil, trimmed end
    if trimmed:sub(-#more) ~= more then return nil, trimmed end
    local last = nil
    for number in trimmed:gmatch("%d+") do last = tonumber(number) end
    return last, trimmed
  end
end

KeyValue.render = function(grid, area, model, context, variant)
  stats.renders = stats.renders + 1
  areas[area.width .. "x" .. area.height] = true

  local sections = 0
  local probe, count = stamped_model(model)
  if count == 0 then
    stats.empty = stats.empty + 1
    return real_render(grid, area, model, context, variant)
  end
  stats.largest_list = math.max(stats.largest_list, count)
  for _, entry in ipairs(probe.entries) do
    if entry.section then sections = sections + 1 end
  end
  if sections > 0 then stats.with_sections = stats.with_sections + 1 end

  -- Mirror the real render into a grid the product does not know about, and read
  -- the marks back off the drawing.
  local mirror = Grid.new(math.max(1, (area.x or 1) + (area.width or 0)),
    math.max(1, (area.y or 1) + (area.height or 0)), grid.width_options)
  local result = real_render(mirror, area, probe, context, variant)
  local read_count = named_count(context)
  local last_line = read_count(mirror, area)
  local values, drawn = read_body(mirror, area, last_line ~= nil)
  local column_key = tostring(result and result.columns or "?")
  if result and type(result.columns) == "number" and result.columns > 1 then
    stats.columns_over_one = stats.columns_over_one + 1
  end

  if result and (result.total or 0) ~= count then
    stats.capped[#stats.capped + 1] = ("%d x %d offers %d entries and reports %d, so the "
      .. "cap took some without saying so"):format(area.width, area.height, count,
      result.total or 0)
  end

  stats.offered = stats.offered + count
  stats.drawn = stats.drawn + drawn
  for tag, x in pairs(values) do
    local value_width = area.x + area.width - x
    if value_width < stats.narrowest_value then
      stats.narrowest_value = value_width
      stats.narrowest_at = ("%d cells wide, %d tall"):format(area.width, area.height)
    end
    if value_width < KeyValue.MIN_VALUE_WIDTH then
      stats.under_floor[#stats.under_floor + 1] = ("%d cells wide, %d tall: entry %q gets "
        .. "a %d-cell value column, under the widget's declared %d")
        :format(area.width, area.height, tag, value_width, KeyValue.MIN_VALUE_WIDTH)
    end
  end

  local held = count - drawn
  if held > 0 then
    stats.held_back = stats.held_back + 1
    stats.overflowing = stats.overflowing + 1
    if sections > 0 then stats.overflowing_with_sections = stats.overflowing_with_sections + 1 end
    local named = last_line
    if named == held then
      stats.named = stats.named + 1
    else
      stats.unnamed_renders = stats.unnamed_renders + 1
      stats.unnamed_entries = stats.unnamed_entries + held
      if not named then stats.unnamed_silent = stats.unnamed_silent + 1 end
      if #stats.unnamed < 12 then
        stats.unnamed[#stats.unnamed + 1] = ("%d x %d, %d entries, %d drawn, %s column(s), "
          .. "%d held back, the last row reads %q, so it names %s")
          :format(area.width, area.height, count, drawn, column_key, held, last_line or "",
            named and tostring(named) or "nothing")
      end
    end
  else
    local named = last_line
    if named then
      stats.spurious = stats.spurious + 1
      if #stats.unnamed < 12 then
        stats.unnamed[#stats.unnamed + 1] = ("%d x %d draws every entry it was given and "
          .. "still its last row reads %q, which claims %d more")
          :format(area.width, area.height, last_line, named)
      end
    end
  end

  return real_render(grid, area, model, context, variant)
end

local engine = { history_values = function() return { n = 0 } end }
local fixtures = capabilities_table()
for _, denied in ipairs({ 0, 4, 17 }) do
  for _, locale in ipairs(LOCALES) do
    local translator = assert(I18n.new({ locale = locale }))
    for _, geometry in ipairs(GEOMETRIES) do
      for _, tab in ipairs(Workspace.new().tabs) do
        local models = assert(ViewModel.build(engine, snapshot(denied), translator,
          fixtures, tab.id, ProcessTable.new({ sort_key = "cpu", descending = true })))
        local workspace = Workspace.new()
        workspace:select(tab.id)
        local ok, problem = pcall(workspace.render, workspace, geometry[1], geometry[2], {
          capabilities = capabilities, i18n = translator, widgets = models, status = {},
          frequency_label = translator:t("sampling.update_frequency",
            { level = translator:t("sampling.frequency.medium") }) })
        assert(ok, "the " .. tab.id .. " page at " .. geometry[1] .. " columns must render: "
          .. tostring(problem))
      end
    end
  end
end
KeyValue.render = real_render

-- The reader's own teeth, before its results are believed.  A reader that cannot
-- find a mark it planted is a reader whose zeros are worth nothing, which is the
-- whole reason the overlay guard spent six versions on the same question.
local tooth_context = { theme = theme, i18n = assert(I18n.new({ locale = "en-US" })),
  capabilities = capabilities }
local function drive(model, width, height)
  local area = { x = 1, y = 1, width = width, height = height }
  local grid = Grid.new(width, height, {
    default_style = theme:style("text.primary", "surface.base"), unicode = true,
  })
  -- Marked, the way the sweep above marks: the marks are what the reader looks
  -- for, and driving the widget unmarked was one of the versions of this
  -- measurement that reported a result -- every count came back zero.
  local probe, offered = stamped_model(model)
  local result = KeyValue.render(grid, area, probe, tooth_context)
  local last = named_count(tooth_context)(grid, area)
  local values, drawn = read_body(grid, area, last ~= nil)
  return area, grid, result, values, drawn, offered
end

local three = { entries = {
  { label = "Hostname", value = "probe" },
  { label = "Kernel", value = "linux" },
  { label = "Uptime", value = "1d" },
} }
local _, _, _, _, planted = drive(three, 40, 6)
require(planted == 3,
  "the reader found " .. planted .. " of 3 planted marks in a 40 by 6 panel, so every "
  .. "count below is a statement about the reader")
local _, _, _, _, empty_count = drive({ entries = {} }, 40, 6)
require(empty_count == 0,
  "the reader invents " .. empty_count .. " marks in a panel with no entries, so a lost "
  .. "entry would be counted as a found one")
-- The cell offset, checked against a label whose byte count and cell count
-- differ: two CJK characters are six bytes and four cells, so a reader that
-- measured bytes puts the mark at column 8 and a reader that measured cells puts
-- it at 6.  The widget measures cells.
local cjk = { entries = { { label = "\u{4e3b}\u{673a}", value = "probe" } } }
local cjk_area, cjk_grid = drive(cjk, 40, 6)
local cjk_found = read_body(cjk_grid, cjk_area, false)
local cjk_x = cjk_found["#AA"]
require(cjk_x == 6,
  "the reader put a mark at column " .. tostring(cjk_x) .. " of a panel whose label is six "
  .. "bytes and four cells wide, so it measured bytes where the widget measures cells")
-- The count reader, and then the count rule: five entries into three rows is two
-- rows of list, one row of count, and three named.
local tooth_read = named_count(tooth_context)
local _, overflow_grid, overflow_result, _, overflow_drawn, _ = drive({ entries = {
  { label = "one", value = "1" }, { label = "two", value = "2" },
  { label = "three", value = "3" }, { label = "four", value = "4" },
  { label = "five", value = "5" },
} }, 40, 3)
require(overflow_drawn == 2,
  "a five-entry list in three rows drew " .. overflow_drawn .. " of five, so the reader's "
  .. "expectation below is not the widget's arithmetic")
local tooth_named = tooth_read(overflow_grid, { x = 1, y = 1, width = 40, height = 3 })
require(tooth_named == 3 and overflow_result.scrollable == true,
  "the reader read " .. tostring(tooth_named) .. " from an overflow row that says 3, so a "
  .. "wrong count on a real panel would read as right")
local _, plain_grid = drive(three, 40, 6)
require(tooth_read(plain_grid, { x = 1, y = 1, width = 40, height = 6 }) == nil,
  "the reader finds an overflow count on a panel that shows everything, so every panel "
  .. "that loses nothing would look like one that does")

-- The rules.
require(#stats.unnamed == 0,
  ("%d renders held an entry back and named it by something else -- %d entries in all, "
    .. "and %d of those renders had no count on the panel at all:\n    %s")
    :format(stats.unnamed_renders, stats.unnamed_entries, stats.unnamed_silent,
      table.concat(stats.unnamed, "\n    ")))
require(#stats.under_floor == 0,
  "a value column narrower than the widget's own declared floor:\n    "
  .. table.concat(stats.under_floor, "\n    "))
require(#stats.capped == 0,
  "the widget's entry cap dropped rows without counting them:\n    "
  .. table.concat(stats.capped, "\n    "))
require(stats.spurious == 0,
  stats.spurious .. " panels claim a count of what they are holding back while drawing "
  .. "every entry they were given")

-- The two cases the layout solver does not produce, driven straight at the
-- widget.  The solver's form minima are why the multi-column loss never fires in
-- the sweep above, and a component is still a component.
local function list_of(count, section_at)
  local entries = {}
  for index = 1, count do
    if index == section_at then entries[#entries + 1] = { section = "Second group" } end
    entries[#entries + 1] = { label = "row" .. index, value = "value" .. index }
  end
  return { entries = entries }
end

local function entries_reported(area, grid, entries, drawn)
  local held = #entries - drawn
  local named = tooth_read(grid, area)
  return held, named, held == 0 or named == held
end

local tall = list_of(14)
local short_area, short_grid, short_result, _, short_drawn = drive(tall, 76, 5)
local short_held, short_named, short_ok = entries_reported(short_area, short_grid,
  tall.entries, short_drawn)
require(short_ok,
  ("14 entries into 76 by 5 draws %d of them and names %s of the %d it kept back -- the "
    .. "two-column split dropped rows it never counted")
    :format(short_drawn, short_named and tostring(short_named) or "nothing", short_held))
require(short_result.scrollable == true or short_drawn == #tall.entries,
  "a key_value panel holding entries back reports itself not scrollable, so the event "
  .. "loop will not scroll it and the reader cannot reach the rest")

-- The anti-over-correction clause: the same list into a panel tall enough for the
-- three-column split is drawn in full, and the columns are kept.  Without this,
-- "always fall back to one column" would pass every rule above.
local wide_area, wide_grid, wide_result, _, wide_drawn = drive(list_of(14), 116, 6)
require(wide_drawn == 14,
  "14 entries into 116 by 6 drew " .. wide_drawn .. ", so the fit check is dropping rows a "
  .. "three-column split holds comfortably")
require(wide_result.columns and wide_result.columns > 1,
  "a 116-cell panel that fits its list in three columns fell back to one, so the fit "
  .. "check is costing a layout the widget was asked to use")

-- The scrolled case, which the event loop drives and no product layout drives:
-- `tui.lua` sets `maximum = total - visible` and asks for `offset = maximum`, so
-- the last entry has to be on screen at the offset its own first render
-- reported.  A 40-cell panel is the geometry that scrolls at all: wider ones
-- hand the list to the two-column split, which reports `scrollable = false` and
-- so is never scrolled.
local scrolled = list_of(14)
local scroll_area, scroll_grid, scroll_result, _, scroll_drawn =
  drive({ entries = scrolled.entries }, 40, 9)
local last_offset = math.max(0, (scroll_result.total or 0) - (scroll_result.visible or 1))
require(scroll_drawn > 0 and scroll_result.scrollable == true,
  "a 14-entry list in a 40 by 9 panel reports " .. tostring(scroll_result.scrollable)
  .. " after drawing " .. scroll_drawn .. ", so the scroll arithmetic below is about a "
  .. "panel the event loop would never scroll")
local _, _, _, reach_found, reach_drawn =
  drive({ entries = scrolled.entries, offset = last_offset }, 40, 9)
local last_entry = mark(#scrolled.entries)
require(reach_drawn > 0 and reach_found[last_entry] ~= nil,
  "at the offset the event loop computes (" .. last_offset .. ") the last of "
  .. #scrolled.entries .. " entries is not on screen, so the tail of a scrolled list "
  .. "cannot be reached")
local reach_read = tooth_read((function()
  local _, grid = drive({ entries = scrolled.entries, offset = last_offset }, 40, 9)
  return grid
end)(), { x = 1, y = 1, width = 40, height = 9 })
require(reach_read == nil or reach_read == (#scrolled.entries - last_offset - reach_drawn),
  "at the last offset the panel names " .. tostring(reach_read) .. " more while holding "
  .. "back " .. (#scrolled.entries - last_offset - reach_drawn))
-- A count row is a claim about what is missing, so it has to be there when
-- something is missing and absent when nothing is.  Measuring the row budget from
-- the top of the list rather than from the offset leaves a panel holding nothing
-- back still drawing the row, and the row says zero: `▾ 0 more`, which is a lie
-- with a row of the panel's height spent on it.
require(reach_read == nil,
  "a panel scrolled to its last offset draws the count row anyway ("
  .. tostring(reach_read and "naming " .. reach_read) .. "), so the last row of a list "
  .. "claims there is more of it")
-- `scrollable` stays true at the last offset, and deliberately so: `total` counts
-- the whole list including the entries above the offset, and `tui.lua` clamps
-- the offset with `total - visible` anyway, so the reachable range is already
-- right.  Requiring the flag to clear would be a rule the measurement does not
-- ask for, and a flag that lies is worse than one that is merely pessimistic.

-- **The one branch this file cannot hold, and why, is `entry.blank`.**  A filler
-- is a row of nothing: in the grid it is a row of blanks, which is exactly what
-- the blank line above a heading is and exactly what a row nothing used is at
-- the bottom of a panel.  So "a filler costs a row" cannot be read off a
-- drawing, and the position where it would be visible -- a filler as the last
-- row drawn -- is the one position where the reader cannot recognise it.  The
-- first version of this file tried the honest-looking thing and got it wrong in
-- both directions at once: it planted a mark in the filler, which made the mark
-- readable and the `entry.blank` branch unreachable, so a filler that cost *no*
-- row (M291) passed a guard written to catch it; and counting every empty body
-- row as a filler invented 130 failures in the sweep, all of them the blank line
-- above a heading.  Both were caught by the counts rather than by reasoning, and
-- the resolution is not a cleverer reader.  No `key_value` model the product
-- builds contains a filler -- the blank entries in this project belong to the
-- overlay and metric lists in `tui.lua` -- so the branch has no caller here
-- either, and it is left unmeasured on purpose rather than guarded by a clause
-- that cannot fail.

-- Non-vacuity, in the order that matters.  The first clause is the one this
-- file exists for: if nothing in the sweep is ever held back, then "every entry
-- is drawn or counted" is a rule applied only where nothing can happen.
require(stats.held_back > 0,
  "not one of the " .. stats.renders .. " renders held an entry back, so the count on "
  .. "the overflow row is untested and the rule was applied only where nothing happens")
require(stats.overflowing_with_sections > 0,
  "no panel that held entries back had a section heading, so the defect this file was "
  .. "written for -- a heading spending a row the budget did not know about -- is not in "
  .. "the sweep at all")
require(stats.with_sections > 0, "no list in the sweep had a heading, so the row "
  .. "arithmetic was never asked about headings")
require(stats.columns_over_one > 0,
  "no panel in the sweep took the two- or three-column split, so the split the widget "
  .. "does use most of the time is unmeasured here")
require(stats.largest_list > 0 and stats.largest_list < KeyValue.MAX_ENTRIES,
  "the largest list in the sweep is " .. stats.largest_list .. " entries against a cap of "
  .. KeyValue.MAX_ENTRIES .. ", so the cap is either being hit or is not being measured")
require(stats.offered > 0 and stats.drawn > 0 and stats.drawn <= stats.offered,
  "the sweep offered " .. stats.offered .. " entries and drew " .. stats.drawn
  .. ", which is not a measurement of anything")
require(stats.renders > 1000 and stats.held_back > 100,
  "the sweep only drove " .. stats.renders .. " renders and " .. stats.held_back
  .. " overflows, so the fixture is too thin for the counts above to mean anything")

assert(#failures == 0,
  table.concat(failures, "\n  ") .. "\n  (" .. #failures
  .. " problem(s); they are reported together so a run that finds a defect "
  .. "explains all of it)")

local shape_count = 0
local min_width, max_width, min_height, max_height = math.huge, 0, math.huge, 0
for shape in pairs(areas) do
  shape_count = shape_count + 1
  local width, height = shape:match("^(%d+)x(%d+)$")
  width, height = tonumber(width), tonumber(height)
  min_width, max_width = math.min(min_width, width), math.max(max_width, width)
  min_height, max_height = math.min(min_height, height), math.max(max_height, height)
end
io.write(string.format(
  "ok: key_value lists (%d renders over %d areas the product produces (%d..%d cells wide, "
  .. "%d..%d tall), %d entries offered, %d drawn, %d renders holding something back and "
  .. "every one of them naming the exact count, none named by nothing, none claiming a "
  .. "count with nothing held back; the value column's narrowest is %d cells against the "
  .. "widget's declared %d, and no row is under it; the largest list is %d entries; "
  .. "%d renders took the two- or three-column split, which the layout's form minima keep "
  .. "from ever losing an entry, so two cases are driven at the widget directly)\n",
  stats.renders, shape_count, min_width, max_width, min_height, max_height, stats.offered,
  stats.drawn, stats.held_back, stats.narrowest_value, KeyValue.MIN_VALUE_WIDTH,
  stats.largest_list, stats.columns_over_one))
