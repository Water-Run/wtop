-- The labelled proportional bars, which had no rule on it.
--
-- Increments 101 to 105 gave a rule to the tables, the overlay, the footer, the
-- panel frame and the two-column detail list.  `bars` is what the per-core CPU
-- panel, the power-supply panel and the per-filesystem panel are drawn with, and
-- it was the last list-shaped widget still asking nothing.  Asking it found a
-- defect that is worse than a lost row, because the panel looks finished.
--
-- **The panel drew one column and left the rest of its width blank.**  The
-- column arithmetic started from "the fewest columns that fit the items in the
-- panel's height" -- the right instinct, and the height is the scarce resource --
-- and then traded columns away twice: the `minimum_cell` narrowing loop could
-- take it below the number the height needed, and the `max_columns` cap of eight
-- could as well.  When `rows_needed` ends up taller than the panel, the
-- placement loop is column-major, so the first column that runs off the bottom
-- ends the whole loop and the remaining columns are never reached.
--
-- Measured over the product's own layouts with core counts of 8, 16, 64 and 128,
-- ten catalogues and nine terminal sizes -- 840 renders, 32 760 items offered:
-- **8 832 drawn and 23 928 named by nothing**, in 348 of the 840 renders.  What
-- that looked like on a host this project develops on: a sixteen-core machine in
-- a 46-by-5 panel drew **5 cores of 16** and said nothing, and a 128-core
-- machine in a 75-by-21 panel drew **21 of 128** with four of its five columns
-- entirely empty.  The widget's own return value said `drawn = 21, total = 128`
-- the whole time -- nothing read it.
--
-- **The rule is the weak one, and it is the one a reader needs: an item the
-- widget was given is either drawn, or named by a count in the panel.**  It says
-- nothing about how much of a value is legible, only that a reader can tell a
-- panel that ends from a panel that stops -- the same clause increment 105 closed
-- for `key_value`, and the same reason it needed saying.
--
-- **The first fix was right about the loss and wrong about the price, and the
-- price is what changed the fix.**  Bounding the column count by a four-cell
-- minimum -- the number the old dead `cell_width < 4` branch used -- fills the
-- panel, and then a four-cell cell with a three-cell label has no room left for
-- anything: forty cores into 40 by 5 draws **no mark at all** while the widget
-- reports 24 of them drawn.  Trading "cores you cannot see" for a cell that
-- cannot hold a core is not a fix.  The floor is now the widget's own
-- `minimum_cell` -- the width at which a cell holds a label and a useful value,
-- which the file already computed and used only to give up on multi-column --
-- and the numbers over the sweep are: **13 226 items drawn against 8 832 before,
-- 356 renders hold something back and every one of them names the exact count,
-- and nothing is unnamed.**  The cut count in `test_no_silent_cell_cuts.lua` is
-- 4 148 before and after, so the extra items cost no legibility at all; the
-- bounded writes rise 68 288 to 75 118 because there are more of them.
--
-- **The fix's footprint is exactly the renders that were losing items.**  Of the
-- 52 distinct (list size, panel shape) combinations in the sweep, 28 changed and
-- every one of the 28 was a shape where items were being dropped; the other 24
-- chose the same columns, the same rows and drew every item before and after.  A
-- sixteen-core panel at 46 by 5 goes from 5 of 16 to 14 of 16 with `+2` in the
-- last cell, and a sixteen-core panel at 56 by 7 was already drawing all 16 and
-- still does.
--
-- **Three more rules came out of mutating the first two, and each of them found
-- something the first two could not see.**  *A drawn value is not cut*: the mark
-- this file plants is padded to the width of the value it replaces, and the
-- padding is `_` rather than a space precisely so that a slot shorter than the
-- list's widest value is visible.  It was blank in the first version, which is
-- why the rule did not exist then -- and with the value's ten-cell ceiling
-- restored (M299) it reports **236 of 13 254 drawn values** stopping short,
-- because es-ES spells `system.offline` as "sin conexión", twelve cells, and a
-- ceiling tuned to the reference catalogue draws "sin conexió" where a reader
-- looks to find out whether a laptop is plugged in.  The ceiling is gone; a list
-- now gives up columns before it gives up letters, which costs 28 of 13 254 drawn
-- items.  *An overrunning list starts at the first of the list*: filling the panel
-- across a row and filling it down the first column draw the same number of items
-- and name the same number, so **the count rules cannot see the difference** --
-- a mutation that turned the row-major fill off produced output byte-identical to
-- the baseline's -- and only the arrangement can, which is what a reader scanning
-- a core list is looking at.  And *a cell is never narrower than the width the
-- widget publishes as readable*, which is the one rule here that checks a
-- declaration instead of a drawing: widening past that width produced a panel with
-- no two cells alike **and** no value cut, so both of the other rules passed it,
-- and what it actually produced was bars in less room than the widget had claimed
-- for them.
--
-- **Two clauses were deleted rather than written, and one mechanism was deleted
-- after a mutation proved it could not run.**  The file was asked to check that a
-- cell is at least the label width plus the value width, which `minimum_cell`
-- already guarantees and which no product layout can make otherwise; a clause
-- that cannot fail is worse than no clause.  And a narrowing loop added with the
-- fix -- "while the cell has come out under `minimum_cell`, give a column back" --
-- was reported MISSED with output byte-identical to the baseline's, which is not a
-- hole in the file: with `columns` never above `fitting`, `cell_for(columns)` is
-- never below `minimum_cell`, and 68.6 million arithmetic cases over the widths,
-- heights, list lengths and column caps agreed.  It was dead code, it is gone, and
-- the floor is now a property of the two bounds rather than a second place to
-- enforce it.
--
-- **The measurement reads the drawing, and four readers came before this one,
-- each reporting a result.**  The rule is counted by counting planted marks: one
-- per item, in the value-text slot, padded to the value's own width so that it
-- cannot change the layout being measured.  The first reader planted the mark in
-- the value-text slot with a narrow cell having no room for it, and so reported
-- items that were on the panel in full as lost; the second counted occupied cells
-- without excluding padding and reported an eight-item panel as 16 cells; the
-- third read the count with `^(%d+)` off a cell that says `+17`; the fourth
-- counted the *bar glyphs*, which in pt-BR is how a nine-item panel read as
-- twelve, because the catalogue spells `system.online` as "on-line" and the
-- hyphen is this widget's ASCII track.  A fifth version of this file's own new
-- rules was wrong twice before it was right, and both slips are worth keeping:
-- a mark with one pad cell and two spaces was expected to read as three cells
-- (it reads four -- the mark is three cells and the pad is the fourth), and the
-- column-major arrangement was expected at the field name `rows_needed` when the
-- widget publishes `rows`.  **A rule about a number a reader cannot produce is a
-- rule about the reader.**
--
-- Six rules guard the result rather than one, because the second is what stopped
-- the first version of the fix from shipping and the other four are what mutations
-- showed the first two could not see.  **No two items on one panel may draw the
-- same thing**, which is the increment-101 family applied to a widget that had
-- never been asked; **a list that fits must be drawn in full, with no count and
-- the columns it had before** -- the anti-over-correction clause, without which
-- "always one column" and "always hold something back" both pass a file that only
-- asks that nothing be lost; and the three above.  The single-column layout is
-- driven directly rather than asked about a range the sweep never enters, because
-- **the product's own layouts never make it**: every bars panel in the sweep is at
-- least two columns wide, because a core list is wide and a panel is not.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Bars = require("wtop.ui.widgets.bars")
local Collectors = require("wtop.collectors")
local Grid = require("wtop.ui.renderer.grid")
local I18n = require("wtop.i18n")
local Inspectors = require("wtop.inspectors")
local ProcessTable = require("wtop.model.process_table")
local Theme = require("wtop.ui.theme")
local ViewModel = require("wtop.view_model")
local Width = require("wtop.ui.renderer.width")
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
-- The core counts are the fixture's extremes, and two of them are the point:
-- 16 is what a machine this project develops on has, and 128 is a real server
-- size.  8 is a small machine that fits everywhere, and 64 sits between.
local CORE_COUNTS = { 8, 16, 64, 128 }

require(type(Bars.GAP) == "number" and Bars.GAP > 0,
  "the widget does not publish the gap between its cells, so this file would have to "
  .. "keep a second copy of the number to partition a row")

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

local function snapshot(core_count)
  local cores = {}
  for index = 0, core_count - 1 do
    -- Every core a different load, so two cells that render alike are two
    -- different facts rendered alike.  A fixture of equal loads would make the
    -- sameness rule unfalsifiable and its absence a gift.
    cores[index + 1] = { name = "cpu" .. index, utilization = (index * 7) % 101,
      user = 0, system = 0, iowait = 0, irq = 0, steal = 0, quality = "fresh" }
  end
  local processes = {}
  for index = 1, 7 do
    processes[index] = { pid = 1000 + index, starttime_ticks = index, name = "p" .. index,
      command = "p" .. index, user = "tester", state = "S", cpu_percent = index,
      resident_bytes = 1024 * index, memory_summary = { resident_bytes = 1024 * index } }
  end
  local quality = {}
  for id in pairs(Collectors.constructors) do
    quality[id] = { status = "ok", quality = "fresh" }
  end
  -- `battery_items` reads `snapshot.power_supplies`, a **top-level** field, and
  -- the first version of this fixture put the batteries under `power.supplies`
  -- instead -- so the power-supply panel took its empty path in all 280 of the
  -- renders that carried it, and a third of this file's widgets was measured
  -- without ever being given data.  A fixture that quietly leaves a panel empty
  -- makes every rule written about it unfalsifiable.
  local power_supplies = { batteries = {}, supplies = {} }
  for index = 1, 6 do
    power_supplies.batteries[index] = { name = "BAT" .. index, status = "Discharging",
      capacity_percent = 97 - index * 7, energy_now = 40000 - index, energy_full = 45000,
      design_capacity = 45000, quality = "fresh" }
  end
  for index = 1, 3 do
    power_supplies.supplies[index] = { name = "AC" .. index, online = index ~= 2,
      quality = "fresh" }
  end
  return {
    host = { hostname = "probe", kernel = "linux", uptime_seconds = 98765 },
    cpu = { usage_percent = 12, quality = "fresh", cores = cores },
    cpu_info = { logical_cores = core_count, model = "probe cpu" },
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
    sensors = { devices = {} },
    power = { zones = {} },
    power_supplies = power_supplies,
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
      virtualization = "kvm", container_hint = "none" },
    inventory = { pci = { devices = {}, total = 0 }, usb = { devices = {}, total = 0 } },
  }
end

-- The bar glyphs, in both profiles.  They are read for the *sameness* rule only,
-- and a fifth version of this reader counted them for the item count as well --
-- which is how a prose hyphen became a defect: pt-BR spells `system.online` as
-- **"on-line"**, the hyphen is this widget's ASCII track, and a nine-item panel
-- read as twelve bars in that one catalogue out of ten.  Counting items by
-- glyphs means counting them by what a word may contain, which is the same
-- mistake as putting a multi-byte glyph in a Lua character class.
local BAR = { ["\u{2501}"] = true, ["\u{2500}"] = true, ["#"] = true, ["-"] = true }

-- One three-cell mark per item, planted in place of the value text.  Two details
-- are not decoration:
--
--   * the slot is the value text because `minimum_cell` guarantees it -- a cell
--     is never chosen unless it can hold the label, the value and six cells of
--     bar, so every item the widget draws writes its whole mark.  That guarantee
--     is what this reader leans on, it is checked in the teeth below, and a floor
--     that stopped guaranteeing it would make the reader undercount rather than
--     lie;
--   * the mark is **padded to the width of the value it replaces**, because a
--     three-cell mark in a list of nine-cell values makes `value_width` smaller,
--     which makes `minimum_cell` smaller, which changes how many columns the
--     widget chooses.  The first version planted a bare three-cell mark and the
--     marked and unmarked renders then chose different column counts, so the
--     reader partitioned one drawing with the other's geometry and reported two
--     cells identical that begin one cell apart.  A mark that changes the layout
--     is a mark that measures the probe;
--   * the padding is `_` and not a space, because the padding is how the reader
--     learns whether a value was **cut**: the widget gives the value text
--     `min(value_width, cell - label - 4)` cells, so a panel whose cells are
--     narrower than `minimum_cell` draws a value that stops short of the widest
--     value in its own list.  The first version padded with spaces and that
--     measurement did not exist, which is why widening past `minimum_cell` was
--     invisible to this file while it was already drawing shorter values.
local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local PAD = "_"
local function mark(index, width)
  local column = math.floor((index - 1) / 26) + 1
  local tag = "#" .. LETTERS:sub(column, column)
    .. LETTERS:sub((index - 1) % 26 + 1, (index - 1) % 26 + 1)
  return tag .. string.rep(PAD, math.max(0, (width or 0) - #tag))
end

local function stamped_model(model)
  local probe = {}
  for key, value in pairs(model) do probe[key] = value end
  local widest = 0
  for _, item in ipairs(type(model.items) == "table" and model.items or {}) do
    if type(item) == "table" then
      widest = math.max(widest, Width.display_width(tostring(item.display_value or ""),
        { unicode = true }))
    end
  end
  probe.items = {}
  for index, item in ipairs(type(model.items) == "table" and model.items or {}) do
    local copy = {}
    for key, value in pairs(item) do copy[key] = value end
    copy.display_value = mark(index, widest)
    probe.items[index] = copy
  end
  return probe, #probe.items, widest
end

local stats = {
  renders = 0, empty = 0, offered = 0, drawn = 0, fitting = 0, holding = 0,
  counted = 0, single_column = 0, multi_column = 0, widest_list = 0,
  renderings = 0, duplicates = 0, areas = {},
  unnamed = {}, unnamed_renders = 0, alike = {}, disagree = {},
  value_slots = 0, cut_values = 0, cut = {}, widest_label = 0,
  floor_checks = 0, short_cells = 0, short = {},
  overrunning = 0, ordered = 0, out_of_order = 0, disordered = {},
}
local real_render = Bars.render

-- Read a marked panel: which items it drew, where each one landed, and how wide
-- its value was drawn.  Marks are read out of the grid's cells, not out of a
-- string built from them -- a two-cell glyph is a lead cell plus a continuation
-- cell whose `char` is the empty string, so a row assembled from `char` fields
-- is short a byte per wide glyph.
--
-- `width` is the run of non-blank cells starting at the mark, which is the value
-- slot as the reader sees it: the widget writes `min(value_width, cell - label
-- - 4)` cells of it, so a slot shorter than the list's widest value is a value
-- that was cut.
local function read_marks(grid, area)
  local seen = {}
  for y = area.y, area.y + area.height - 1 do
    for x = area.x, area.x + area.width - 1 do
      local cell = grid:get(x, y)
      if cell and not cell.continuation and cell.char == "#" then
        local letters = {}
        for step = 1, 2 do
          local follower = grid:get(x + step, y)
          letters[step] = (follower and not follower.continuation) and follower.char or ""
        end
        if letters[1]:match("^[%a]$") and letters[2]:match("^[%a]$") then
          local width = 0
          for step = 0, area.x + area.width - x - 1 do
            local filler = grid:get(x + step, y)
            local char = (filler and not filler.continuation) and filler.char or ""
            if char == "" or char == " " then break end
            width = width + 1
          end
          seen["#" .. letters[1] .. letters[2]] =
            { x = x, y = y, width = width }
        end
      end
    end
  end
  local marks, count = {}, 0
  for tag, at in pairs(seen) do
    count = count + 1
    marks[count] = { tag = tag, x = at.x, y = at.y, width = at.width }
  end
  table.sort(marks, function(left, right)
    if left.y == right.y then return left.x < right.x end
    return left.y < right.y
  end)
  return count, marks
end

-- The count, read the way a reader reads it: a `+` and a number, in the last cell
-- of the last row.  The mark scan has already said no mark is over there, so what
-- is left in that cell is the widget's own claim.
local function read_count(grid, area, columns)
  local width = math.max(1, math.floor((area.width - Bars.GAP * (columns - 1)) / columns))
  local x0 = area.x + (columns - 1) * (width + Bars.GAP)
  local y = area.y + area.height - 1
  local chars = {}
  for x = x0, x0 + width - 1 do
    local cell = grid:get(x, y)
    local char = (cell and not cell.continuation) and cell.char or ""
    if char ~= "" and char ~= " " then chars[#chars + 1] = char end
  end
  local text = table.concat(chars)
  local named = nil
  for number in text:gmatch("%+(%d+)") do named = tonumber(number) end
  return named, text
end

-- Each cell's ink, for the sameness rule, read from the **unmarked** render: a
-- mark in every cell would make every cell unique and the rule unable to fire.
local function read_cells(grid, area, columns, held)
  local cells = {}
  local width = math.max(1, math.floor((area.width - Bars.GAP * (columns - 1)) / columns))
  for column = 0, columns - 1 do
    local x0 = area.x + column * (width + Bars.GAP)
    for y = area.y, area.y + area.height - 1 do
      if not (held and column == columns - 1 and y == area.y + area.height - 1) then
        local runs, current = {}, nil
        for x = x0, x0 + width - 1 do
          local cell = grid:get(x, y)
          local char = (cell and not cell.continuation) and cell.char or ""
          if char == "" or char == " " then
            if current then runs[#runs + 1] = current; current = nil end
          else
            current = (current or "") .. char
          end
        end
        if current then runs[#runs + 1] = current end
        if #runs > 0 then cells[#cells + 1] = table.concat(runs, "|") end
      end
    end
  end
  return cells
end

Bars.render = function(grid, area, model, context, variant)
  stats.renders = stats.renders + 1
  stats.areas[area.width .. "x" .. area.height] = true
  local items = {}
  for _, item in ipairs(type(model.items) == "table" and model.items or {}) do
    if type(item) == "table" then items[#items + 1] = item end
  end
  if #items == 0 then
    stats.empty = stats.empty + 1
    return real_render(grid, area, model, context, variant)
  end
  stats.widest_list = math.max(stats.widest_list, #items)
  local label_widest = 0
  for _, item in ipairs(items) do
    label_widest = math.max(label_widest,
      Width.display_width(tostring((item or {}).label or ""), grid.width_options))
  end
  stats.widest_label = math.max(stats.widest_label, label_widest)

  local function mirror()
    return Grid.new(math.max(1, (area.x or 1) + (area.width or 0)),
      math.max(1, (area.y or 1) + (area.height or 0)), grid.width_options)
  end
  -- Marked, for which items were drawn.
  local marked, count, widest = stamped_model(model)
  local marks_grid = mirror()
  local marked_result = real_render(marks_grid, area, marked, context, variant)
  local columns = (marked_result and marked_result.columns) or 1
  local drawn, marks = read_marks(marks_grid, area)
  local named = read_count(marks_grid, area, columns)
  -- Unmarked, for what the cells look like and for what the widget reports.
  local plain_grid = mirror()
  local result = real_render(plain_grid, area, model, context, variant)
  -- Partitioned with the unmarked render's own column count, so the reader cannot
  -- measure one drawing with another drawing's geometry even if the two differ.
  local cells = read_cells(plain_grid, area, (result and result.columns) or columns, named)

  stats.offered = stats.offered + count
  stats.drawn = stats.drawn + drawn
  stats.renderings = stats.renderings + #cells
  if columns > 1 then
    stats.multi_column = stats.multi_column + 1
  else
    stats.single_column = stats.single_column + 1
  end

  -- The two things a reader can be told.
  if drawn + (named or 0) ~= count then
    stats.unnamed_renders = stats.unnamed_renders + 1
    if #stats.unnamed < 12 then
      stats.unnamed[#stats.unnamed + 1] = ("%d x %d, %d items, %d drawn, the panel names "
        .. "%s of the %d it is not showing, columns=%s rows=%s")
        :format(area.width, area.height, count, drawn, tostring(named), count - drawn,
          tostring(marked_result and marked_result.columns),
          tostring(marked_result and marked_result.rows))
    end
  elseif named then
    stats.counted = stats.counted + 1
    if (result or {}).held ~= named then
      if #stats.disagree < 8 then
        stats.disagree[#stats.disagree + 1] = ("%d x %d: the panel names %d held back and "
          .. "the widget reports %s, so the program is told something the screen does "
          .. "not say"):format(area.width, area.height, named, tostring((result or {}).held))
      end
    end
  else
    stats.fitting = stats.fitting + 1
  end
  if named then stats.holding = stats.holding + 1 end

  if (result or {}).drawn ~= drawn and #stats.disagree < 12 then
    stats.disagree[#stats.disagree + 1] = nil
    stats.disagree[#stats.disagree + 1] = ("%d x %d: the widget reports %s drawn and the "
      .. "panel carries %d of this file's marks"):format(area.width, area.height,
      tostring((result or {}).drawn), drawn)
  end

  -- A cell is never narrower than the width the widget published as the smallest
  -- one that can hold this list's label, its value and a bar worth reading.  This
  -- is the one rule here that checks a declaration rather than the drawing, and it
  -- exists because of what it caught: widening past the readable width drew a
  -- panel with **no two cells alike and no value cut**, so both of the other rules
  -- passed it, and what it produced was cells whose bar was two cells short of
  -- the room the widget itself claimed for it.  The floor the widget publishes is
  -- `min(its own minimum_cell, the panel's width)`, because a panel too narrow to
  -- hold one readable cell is the panel's own width and not a violation.
  stats.floor_checks = stats.floor_checks + 1
  local label_floor = math.min(label_widest, Bars.MAX_LABEL_WIDTH)
  local promised = math.min(Bars.minimum_cell(label_floor, widest), area.width)
  local cell = math.floor((area.width - Bars.GAP * (columns - 1)) / columns)
  if cell < promised then
    stats.short_cells = stats.short_cells + 1
    if #stats.short < 8 then
      stats.short[#stats.short + 1] = ("%d x %d, %d items, %d columns: the cell is %d cells "
        .. "wide where the widget's own readable cell for a %d-cell label and a %d-cell "
        .. "value is %d, so the bar is drawn in less room than the widget promised")
        :format(area.width, area.height, count, columns, cell, label_floor, widest, promised)
    end
  end

  -- The value of a drawn item is drawn whole.  The list's widest value is
  -- `widest` cells, the widget offers the slot `min(value_width, cell - label -
  -- 4)`, and a mark padded to `widest` makes the difference between the two
  -- visible as a run of padding that stops early.  This is the rule behind
  -- `minimum_cell`, and it is the rule that caught a panel widened past the width
  -- a readable cell fits in: that panel drew no two cells alike, because it cut
  -- the values off before the cells could collide.
  for _, mark in ipairs(marks) do
    stats.value_slots = stats.value_slots + 1
    if mark.width < widest then
      stats.cut_values = stats.cut_values + 1
      if #stats.cut < 8 then
        stats.cut[#stats.cut + 1] = ("%d x %d, %d items, %d columns: item %s was drawn with "
          .. "%d cells of value where the list's widest value is %d, so its number is "
          .. "truncated"):format(area.width, area.height, count, columns, mark.tag,
          mark.width, widest)
      end
    end
  end

  -- A list that overruns its panel is drawn in reading order: the top row holds
  -- the first items of the list, side by side, and the count is in the last cell.
  -- Filling the panel down the first column instead draws the same number of
  -- items and names the same number, so the count rules cannot see the
  -- difference -- only the arrangement can, and a reader scanning a core list
  -- wants 0, 1, 2, 3 across the top rather than 0, 5, 10, 15.
  if named then
    stats.overrunning = stats.overrunning + 1
    local top = {}
    for _, mark in ipairs(marks) do
      if mark.y == area.y then top[#top + 1] = mark end
    end
    local in_order = true
    for position, mark in ipairs(top) do
      local column = math.floor(position - 1) % 26
      local letter = math.floor((position - 1) / 26)
      if mark.tag ~= "#" .. LETTERS:sub(letter + 1, letter + 1)
          .. LETTERS:sub(column + 1, column + 1) then
        in_order = false
      end
    end
    if in_order then
      stats.ordered = stats.ordered + 1
    else
      stats.out_of_order = stats.out_of_order + 1
      if #stats.disordered < 8 then
        local tags = {}
        for _, mark in ipairs(top) do tags[#tags + 1] = mark.tag end
        stats.disordered[#stats.disordered + 1] = ("%d x %d, %d items, %d columns: an "
          .. "overrunning list drew %s across its top row, so the panel does not start at the "
          .. "first of the list"):format(area.width, area.height, count, columns,
          table.concat(tags, " "))
      end
    end
  end

  -- Two items that look the same on one panel.  A cell's ink is compared with the
  -- cells around it; no mapping from cell back to item is needed, and building
  -- one would mean re-deriving the placement order, which is the one thing a
  -- reader must not do.
  local seen_cells = {}
  for _, ink in ipairs(cells) do
    if seen_cells[ink] then
      stats.duplicates = stats.duplicates + 1
      if #stats.alike < 8 then
        stats.alike[#stats.alike + 1] = ("%d x %d, %d items, %d columns: two cells on this "
          .. "panel both draw %q, and this fixture gives every core a different load")
          :format(area.width, area.height, count, columns, ink)
      end
    else
      seen_cells[ink] = true
    end
  end

  return real_render(grid, area, model, context, variant)
end

local engine = { history_values = function() return { n = 0 } end }
local fixtures = capabilities_table()
stats.pages = 0
for _, core_count in ipairs(CORE_COUNTS) do
  for _, locale in ipairs(LOCALES) do
    local translator = assert(I18n.new({ locale = locale }))
    for _, geometry in ipairs(GEOMETRIES) do
      for _, tab in ipairs(Workspace.new().tabs) do
        local models = assert(ViewModel.build(engine, snapshot(core_count), translator,
          fixtures, tab.id, ProcessTable.new({ sort_key = "cpu", descending = true })))
        local workspace = Workspace.new()
        workspace:select(tab.id)
        local ok, problem = pcall(workspace.render, workspace, geometry[1], geometry[2], {
          capabilities = capabilities, i18n = translator, widgets = models, status = {},
          frequency_label = translator:t("sampling.update_frequency",
            { level = translator:t("sampling.frequency.medium") }) })
        assert(ok, "the " .. tab.id .. " page at " .. geometry[1] .. " columns must render: "
          .. tostring(problem))
        stats.pages = stats.pages + 1
      end
    end
  end
end
Bars.render = real_render

-- The reader's own teeth, before its counts are believed.  A rule about zeros
-- from a reader that finds nothing is a rule that cannot fail, and the overlay
-- guard spent six versions learning that.
local tooth_context = { theme = theme, i18n = assert(I18n.new({ locale = "en-US" })),
  capabilities = capabilities }
local function drive(items, width, height)
  local area = { x = 1, y = 1, width = width, height = height }
  local model = { items = items, min = 0, max = 100 }
  local function surface()
    return Grid.new(width, height, {
      default_style = theme:style("text.primary", "surface.base"), unicode = true,
    })
  end
  local marked = stamped_model(model)
  local marks_grid = surface()
  local marked_result = Bars.render(marks_grid, area, marked, tooth_context)
  local columns = (marked_result and marked_result.columns) or 1
  local drawn, marks = read_marks(marks_grid, area)
  local named = read_count(marks_grid, area, columns)
  local plain_grid = surface()
  local result = Bars.render(plain_grid, area, model, tooth_context)
  local cells = read_cells(plain_grid, area, (result and result.columns) or columns, named)
  return area, result, drawn, named, cells, marks
end

local three = { { label = "0", value = 95, display_value = "95%" },
  { label = "1", value = 5, display_value = "5%" },
  { label = "2", value = 60, display_value = "60%" } }
local _, _, three_drawn, three_named, three_cells = drive(three, 60, 6)
require(three_drawn == 3 and three_named == nil and #three_cells == 3,
  "the reader found " .. three_drawn .. " marks, a count of " .. tostring(three_named)
  .. " and " .. #three_cells .. " cells where a three-item panel in 60 by 6 has 3 of "
  .. "each, so every count below is a statement about the reader")
local _, _, none_drawn = drive({}, 60, 6)
require(none_drawn == 0,
  "the reader invents " .. none_drawn .. " marks in a panel with no items, so an item that "
  .. "was never drawn would be counted as drawn")
local many = {}
for index = 1, 40 do
  many[index] = { label = tostring(index), value = (index * 7) % 101,
    display_value = tostring((index * 7) % 101) .. "%" }
end
local _, over_result, over_drawn, over_named, over_cells = drive(many, 40, 5)
require(over_drawn + (over_named or 0) == 40 and over_named and over_named > 0,
  "a forty-item list in 40 by 5 drew " .. over_drawn .. " and named "
  .. tostring(over_named) .. ", so the reader cannot tell a held-back item from a "
  .. "drawn one")
require(over_result.held == over_named and over_result.drawn == over_drawn,
  "the widget reports " .. tostring(over_result.drawn) .. " drawn and "
  .. tostring(over_result.held) .. " held while the panel carries " .. over_drawn
  .. " marks and names " .. tostring(over_named))
require(#over_cells == over_drawn,
  "the reader found " .. #over_cells .. " cells for " .. over_drawn .. " marks, so the "
  .. "sameness rule below would be comparing the count cell with items")
-- The dependency the planted marks lean on, checked: at the narrowest cell the
-- widget is willing to choose, the value text is still drawn whole.  If a floor
-- ever stops guaranteeing that, this fails before the rules do, and says why.
local narrowest = nil
for _, count in ipairs({ 6, 8, 12, 20 }) do
  for _, width in ipairs({ 30, 40, 50, 60, 80, 100, 140 }) do
    local list = {}
    for index = 1, count do
      list[index] = { label = "lbl" .. index, value = (index * 11) % 101,
        display_value = tostring((index * 11) % 101) .. "%" }
    end
    local _, result, drawn, named = drive(list, width, 6)
    if result and result.columns and result.columns > 1 then
      local cell = math.floor((width - Bars.GAP * (result.columns - 1)) / result.columns)
      if not narrowest or cell < narrowest.cell then
        narrowest = { cell = cell, drawn = drawn, named = named, items = count, width = width }
      end
    end
  end
end
require(narrowest ~= nil and narrowest.drawn + (narrowest.named or 0) == narrowest.items,
  "at a cell of " .. tostring(narrowest and narrowest.cell) .. " cells the reader counts "
  .. tostring(narrowest and narrowest.drawn) .. " marks for "
  .. tostring(narrowest and narrowest.items) .. " items, so a plant can be cut by the very "
  .. "column whose width is under test")

-- The reader that watches a value slot, on grids built for the purpose: a mark
-- with its padding intact is read as that many cells wide, and the same mark one
-- cell short is read one cell short.  Without this, "no value was cut" is a rule
-- about a measurement nobody made, which is the failure the width guards already
-- paid for once.
local tooth_style = theme:style("text.primary", "surface.base")
local function planted(text, width)
  local probe = Grid.new(width, 1, { default_style = tooth_style, unicode = true })
  probe:write(1, 1, text, tooth_style)
  return probe
end
local probe_area = { x = 1, y = 1, width = 6, height = 1 }
local _, whole_marks = read_marks(planted("#AB___", 6), probe_area)
local _, short_marks = read_marks(planted("#AB  ", 6), probe_area)
require(#whole_marks == 1 and whole_marks[1].width == 6 and #short_marks == 1
  and short_marks[1].width == 3,
  "the reader calls a whole value slot "
  .. tostring(#whole_marks == 1 and whole_marks[1].width) .. " cells and a slot cut one cell "
  .. "short " .. tostring(#short_marks == 1 and short_marks[1].width) .. " cells, so the "
  .. "value rule below is being asked about a number the reader cannot produce")

-- The reader that reads an arrangement apart, on the panel both arrangements
-- produce the same counts for.  Filling 40 items into 40 by 5 column by column
-- would put items 1, 6 and 11 across the top row; filling it across draws items
-- 1, 2 and 3.  Same number drawn, same number named -- only the cells differ.
local _, over_layout, _, _, _, over_marks = drive(many, 40, 5)
local top_tags = {}
for _, mark in ipairs(over_marks) do
  if mark.y == 1 then top_tags[#top_tags + 1] = mark.tag end
end
local strided = {}
for step = 0, math.max(0, #top_tags - 1) do
  local index = step * (over_layout and over_layout.rows or 1) + 1
  if index <= #LETTERS then
    strided[#strided + 1] = "#" .. LETTERS:sub(1, 1) .. LETTERS:sub(index, index)
  end
end
require(#top_tags > 0 and table.concat(top_tags, " ") ~= table.concat(strided, " "),
  "the top row of an overrunning 40-by-5 panel reads " .. table.concat(top_tags, " ")
  .. ", which is the arrangement filling the panel down its first column would also "
  .. "produce (" .. table.concat(strided, " ") .. "), so the reading-order rule cannot fail")

-- The rules.
require(#stats.unnamed == 0,
  ("%d renders drew an item list shorter than the list they were given, with nothing on "
    .. "the panel naming the difference: %d items offered, %d drawn, over %d renders that had "
    .. "any items at all (the first twelve):\n    %s")
    :format(stats.unnamed_renders, stats.offered, stats.drawn,
      stats.renders - stats.empty, table.concat(stats.unnamed, "\n    ")))
require(#stats.alike == 0,
  ("%d cells on a panel drew the same thing as another cell on the same panel, which is "
    .. "two different facts a reader cannot tell apart (the first eight):\n    %s")
    :format(stats.duplicates, table.concat(stats.alike, "\n    ")))
require(#stats.disagree == 0,
  "the widget's own report and the panel disagree, so the program is told something the "
  .. "screen does not say:\n    " .. table.concat(stats.disagree, "\n    "))
require(#stats.cut == 0,
  ("%d of %d drawn values stopped short of the list's own widest value, so a bar's number "
    .. "was cut to fit a cell the widget had already decided was too narrow (the first "
    .. "eight):\n    %s"):format(stats.cut_values, stats.value_slots,
    table.concat(stats.cut, "\n    ")))
require(#stats.short == 0,
  ("%d of %d panels chose a cell narrower than the width the widget publishes as the "
    .. "smallest readable one, so a bar was drawn in less room than the widget promised "
    .. "(the first eight):\n    %s"):format(stats.short_cells, stats.floor_checks,
    table.concat(stats.short, "\n    ")))
require(#stats.disordered == 0,
  ("%d of %d panels that hold something back do not start at the first of the list: the "
    .. "cells across the top row are not consecutive items, so a reader scanning the panel "
    .. "starts in the middle of it (the first eight):\n    %s")
    :format(stats.out_of_order, stats.overrunning, table.concat(stats.disordered, "\n    ")))

-- Anti-over-correction, in the form that matters for this widget: a panel that can
-- hold the list must hold it, and a wide panel must still use the columns it used
-- before.  Without this, "always one column" and "always hold something back" both
-- pass a file that only asks that nothing be lost.
local _, wide_result, wide_drawn, wide_named = drive(many, 160, 40)
require(wide_drawn == 40 and wide_named == nil,
  "a forty-item list in a 160-by-40 panel drew " .. wide_drawn .. " and named "
  .. tostring(wide_named) .. ", so the overflow path is being taken when the list fits")
require(wide_result.columns and wide_result.columns > 1,
  "a 160-cell panel drew a forty-item list in one column, so the cost of the fix is "
  .. "being paid in a layout that could afford not to")
-- The single-column layout is the other choice the widget can make, and **the
-- product's own layouts never make it**: every bars panel in the sweep is at
-- least two columns wide, because a core list is wide and a panel is not.  So it
-- is driven here rather than asked about a range the sweep never enters, and
-- named here rather than left to look covered.
local _, narrow_result, narrow_drawn, narrow_named = drive(three, 20, 4)
require(narrow_result.columns == 1 and narrow_drawn + (narrow_named or 0) == 3,
  "a three-item list in a 20-by-4 panel chose " .. tostring(narrow_result.columns)
  .. " columns, drew " .. narrow_drawn .. " and named " .. tostring(narrow_named)
  .. ", so the one-column layout this clause exists for is not the one the widget takes")

-- Non-vacuity, in the order that matters.  The first clause is the one this file
-- exists for: if nothing in the sweep is ever held back, then "drawn or named" is a
-- rule applied only where nothing happens.
require(stats.holding > 0,
  "not one of the " .. stats.renders .. " renders held an item back, so the count on "
  .. "the panel is untested and the rule was applied only where nothing happens")
require(stats.fitting > 0,
  "no render in the sweep fitted its list, so the rule is only ever asked about "
  .. "overflow and a panel that draws everything is untested")
require(stats.multi_column > 0,
  "the sweep only ever produced one column, so the multi-column layout this file is "
  .. "mostly about is unmeasured")
require(stats.duplicates == 0 and stats.renderings > 0,
  "the sweep compared no cells, so the sameness rule cannot fail")
require(stats.value_slots > 0 and stats.cut_values == 0,
  "the sweep read " .. stats.value_slots .. " value slots, so the rule about a value being "
  .. "cut is being asked about a measurement the sweep never made")
require(stats.floor_checks > 0 and stats.short_cells == 0,
  "the sweep checked " .. stats.floor_checks .. " cells against the width the widget "
  .. "publishes, so the rule about keeping that promise is asked about nothing")
require(stats.overrunning > 0 and stats.ordered > 0 and stats.out_of_order == 0,
  stats.overrunning .. " panels held something back and "
  .. tostring(stats.ordered) .. " of them start at the first of the list, so the "
  .. "reading-order rule is asked about "
  .. (stats.overrunning == 0 and "nothing" or "the panels that overflow"))
require(stats.widest_list >= 128,
  "the widest list the fixture built is " .. stats.widest_list .. " items, so the sweep "
  .. "never held a server-sized core count back")
require(stats.offered > 0 and stats.drawn > 0 and stats.drawn <= stats.offered,
  "the sweep offered " .. stats.offered .. " items and drew " .. stats.drawn
  .. ", which is not a measurement of anything")
local expected_pages = #LOCALES * #GEOMETRIES * #CORE_COUNTS * #Workspace.new().tabs
require(stats.pages == expected_pages,
  "the sweep should have rendered " .. expected_pages .. " pages and rendered "
  .. stats.pages .. ", so a page is missing from the measurement")

assert(#failures == 0,
  table.concat(failures, "\n  ") .. "\n  (" .. #failures
  .. " problem(s); they are reported together so a run that finds a defect "
  .. "explains all of it)")

local shapes = 0
local min_width, max_width, min_height, max_height = math.huge, 0, math.huge, 0
for shape in pairs(stats.areas) do
  shapes = shapes + 1
  local width, height = shape:match("^(%d+)x(%d+)$")
  width, height = tonumber(width), tonumber(height)
  min_width, max_width = math.min(min_width, width), math.max(max_width, width)
  min_height, max_height = math.min(min_height, height), math.max(max_height, height)
end
io.write(string.format(
  "ok: bar lists (%d renders over %d areas the product produces (%d..%d cells wide, "
  .. "%d..%d tall), %d items offered and %d drawn, and every item either on the panel or "
  .. "named by a count: %d renders hold something back and all of them say how much, "
  .. "%d draw the whole list; %d of %d cells came out identical to another cell on the "
  .. "same panel and %d of %d drawn values came out shorter than the list's widest value, "
  .. "which is what the widget's own minimum cell width is there to prevent; %d of %d "
  .. "panels that hold something back start at the first of the list; %d of %d cells were "
  .. "at least the width the widget publishes as readable; the widest list the "
  .. "fixture built is %d items, carrying a label of %d cells)\n",
  stats.renders, shapes, min_width, max_width, min_height, max_height, stats.offered,
  stats.drawn, stats.holding, stats.fitting, stats.duplicates, stats.renderings,
  stats.cut_values, stats.value_slots, stats.ordered, stats.overrunning,
  stats.floor_checks - stats.short_cells, stats.floor_checks,
  stats.widest_list, stats.widest_label))
