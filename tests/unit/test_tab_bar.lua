-- A page the bar is not showing is counted on the bar.
--
-- The tab bar answers "which page am I on", and for most of the product's widths
-- it answered it while silently swallowing the rest of the product.  The
-- responsive solver's hidden panels got a rule in increment 109 -- `▦ 3/11` on the
-- footer -- and the bar above it had no rule at all: the chevrons said *that* there
-- were more pages and never said *how many*, so on an eighty-column terminal, the
-- width this product documents, six of the ten pages were simply not there.
--
-- Measured on the product's own bar -- brand `wtop build-box-01`, en-US, every
-- width from 20 to 160 and each of the ten pages in turn -- **1 410 renders drew
-- 7 693 tab slots, left 6 407 page slots with no label on the row, and not one of
-- the 1 410 rows carried a count.**  The ten labels have no common distinguishing
-- prefix: the shortest prefix that still tells all ten apart is nine cells in
-- German, three in Spanish, two in English, French, Portuguese and Russian and
-- one in each of the three CJK catalogues, so there is no cell count at which a
-- cut tab label can be promised to name its page, and a rule built on one would
-- carry a number the product cannot keep in ten languages.  A count, by contrast,
-- is the same number in every catalogue.
--
-- So the statement is paid for by the pages that were going to be dropped anyway,
-- and never by the name of the page the reader is on.  The narrow end of the row
-- is the interesting part, and it took three passes to get right.
--
--   * The first version reserved one cell more than the statement needs.  The
--     quiet cell it booked between the count and the live sampler is already in
--     the run's own budget, so the extra cell went to page names: **116 070 rows
--     of the price sweep carry a count, and every one of them gained a cell of
--     name** -- `wtop …+9  Update` became `wtop O…+9  Update`.
--   * That cell had in fact been doing a second job.  The leading chevron was
--     tested against the reservation and not against the pages already chosen, so
--     it took a cell the statement needed: at eighteen columns with the fifth page
--     active the row read `wtop ‹ S…… Update` -- a direction, a cut name, and no
--     count.  A marker that costs the statement its cell is not free.
--   * And the deep tail was the defect this rule was written for.  Below the
--     width where a name is legible, the bar drew a page cell that was nothing
--     but its own cut marker -- `wtop … Updat` at twelve columns in every
--     catalogue, `wtop ‹ …+9` at seventeen in Japanese, where a two-cell
--     character left the padding and the marker and no character at all -- and
--     said nothing about the pages it was holding back.  A cell that cannot show
--     what it holds must not be drawn as though it had: that is increment 105's
--     rule, and the page cell has to answer to it like every other cell on the
--     row.
--
-- What the bar does now, in bands whose boundaries are all widths the row already
-- knows: the statement beside a name (`+9`, two cells), the statement alone
-- (`+10`, three), and the name itself -- the padding, the first cell of the
-- active page's own label, and the cut marker, so four cells in the CJK
-- catalogues and three in the rest.
--
--   run >= beside + name    a name, cut if need be, and `+N`
--   run >= alone             `+N` alone
--   run >= 1                 the one-cell cut marker
--   run == 0                 nothing to say
--
-- The bar publishes those three widths, the run's own width, the statement it
-- wrote and the brand as it drew it, and this file checks each of them against
-- the row before any rule below is allowed to use them.  Beyond that it asks for
-- nothing: the two rules that carry the weight -- a page cell that says nothing
-- is not drawn, and a page the bar does not draw is on the row as a count of
-- exactly that many or as the one-cell mark -- are stated over the row and the
-- boxes the bar drew, with no budget in them, and a bar that published nothing
-- at all would still be held to them.  That is on purpose: an earlier version of
-- this file asked the bar whether a count was owed before asking the row for one,
-- which made the rule skip itself on the very code the rule was written for.
--
-- Mutation evidence: M327-M341, fifteen of fifteen, and **one of them was missed on
-- the second round and the miss was a finding about the product rather than about
-- the file.** The quiet cell between the statement and the sampler is guaranteed by
-- the one-cell lead's condition, not by the statement's booking: a probe that starved
-- the statement whenever the room turned out to be short found it starved in none of
-- 216 000 renders, so the fit check in `tab_bar.lua` was deleted as dead weight --
-- and with it went the only thing that noticed a lead spending the statement's cell
-- (M332), because the statement simply landed one cell closer to the rate and nothing
-- in this file said a row had to leave the cell. It does now: the statement may not
-- touch the sampler, which is increment 105's rule that every padded segment must be
-- visible, stated about this row. A guard that only knows a component's own arithmetic
-- is a guard that goes quiet when the arithmetic changes.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grid = require("wtop.ui.renderer.grid")
local I18n = require("wtop.i18n")
local TabBar = require("wtop.ui.widgets.tab_bar")
local Theme = require("wtop.ui.theme")
local Width = require("wtop.ui.renderer.width")
local Workspace = require("wtop.workspace")

local LOCALES = assert(I18n.available())
local failures = {}
local function require(condition, message)
  if not condition then failures[#failures + 1] = message end
end

local workspace = Workspace.new({})
local tabs = workspace.tabs
local theme = Theme.new(Theme.DEFAULT, { unicode = true })
local contexts, frequencies, labels = { [true] = {}, [false] = {} }, {}, {}
for _, locale in ipairs(LOCALES) do
  local translator = assert(I18n.new({ locale = locale }))
  frequencies[locale] = translator:t("sampling.update_frequency",
    { level = translator:t("sampling.frequency.medium") })
  labels[locale] = {}
  for _, tab in ipairs(tabs) do
    labels[locale][tab.id] = tostring(translator:t(tab.label_id, tab.label))
  end
  for _, unicode in ipairs({true, false}) do
    contexts[unicode][locale] = { theme = theme, i18n = translator,
      capabilities = { unicode = unicode } }
  end
end

-- `tui.lua` sends "wtop " .. hostname, so the brand carries a space and the run of
-- non-blank cells at the head of the row is not the brand.  The reader is given
-- the brand's width and checks the row against it; it never counts the brand off
-- the row, which is why the second brand here has a space in it.
local BRANDS = { "wtop", "wtop build-box-01" }
local STATES = {
  { name = "quiet", extra = {} },
  { name = "paused", extra = { paused = true } },
  { name = "alerts", extra = { alert_count = 9 } },
}
local COLUMNS = {}
for columns = 8, 200, 2 do COLUMNS[#COLUMNS + 1] = columns end
-- The ASCII spellings are the same bar with the cut marker spelled `.` and the
-- chevrons cut to `<` and `>`, and they are swept separately and more thinly: the
-- point is to hold the one-cell stand-in to the same rule in the mode the product
-- falls back to when the terminal cannot take the other one.
local ASCII_COLUMNS = {}
for columns = 8, 60, 4 do ASCII_COLUMNS[#ASCII_COLUMNS + 1] = columns end
local BLOCKED = { [true] = 0, ["none"] = 0, ["no-room"] = 0 }

local function draw(columns, active, brand, locale, extra, unicode)
  local state = { tabs = tabs, brand = brand, active = active,
    frequency_label = frequencies[locale] }
  for key, value in pairs(extra) do state[key] = value end
  local grid = Grid.new(columns, 1, {
    default_style = theme:style("text.primary", "surface.base"),
    unicode = unicode,
  })
  local meta = TabBar.render(grid, { x = 1, y = 1, width = columns, height = 1 },
    state, contexts[unicode][locale])
  return grid, meta
end

-- ---------------------------------------------------------------------------
-- The reader.  One entry per column: the grapheme that starts there, and the
-- empty string where a wide grapheme continues.  Reading columns off the grid
-- rather than off `row_text` is what lets the rules below talk about cells at all
-- -- `row_text` skips the continuation cells, so a string of it is one shorter
-- than the row it came from for every wide grapheme on the row.
-- ---------------------------------------------------------------------------
local function read_cells(grid)
  local cells = {}
  for x = 1, grid.width do
    local cell = grid:get(x, 1)
    cells[x] = cell.continuation and "" or cell.char
  end
  return cells
end

local function slice(cells, from, to)
  local out = {}
  for x = math.max(from, 1), math.min(to, #cells) do out[#out + 1] = cells[x] end
  return table.concat(out)
end

local function blank(cell)
  return cell == nil or cell == " " or cell == ""
end

-- The count, read as cells: a `+` and the digits that follow it with nothing
-- between them.  A count the bar had cut shows fewer digits than it has, and the
-- digits it did show are the wrong number, so the rule below compares the digits
-- against the bar's own hidden count rather than accepting what is there; and a
-- `+` with a hole in it is not a count at all, so this reader will not join
-- across a column that is not carrying a digit.
local function read_count(columns, cells)
  for position, column in ipairs(columns) do
    if cells[column] == "+" then
      local digits, mine, index = {}, {column}, position + 1
      while index <= #columns do
        local next_column, cell = columns[index], cells[columns[index]]
        if not (cell and cell:match("^%d$")) then break end
        digits[#digits + 1] = cell
        mine[#mine + 1] = next_column
        index = index + 1
      end
      if #digits > 0 then return "+" .. table.concat(digits), mine end
    end
  end
  return nil, {}
end

-- The reader's own teeth, before it is trusted with a rule: each of these is a
-- shape the reader has to get right, stated as a shape and not as a product fact,
-- and each of them has to hold.  A rule that fires because the reader cannot see
-- what is on the row is a rule about the reader.
local function cells_of(text, options)
  local cells, x = {}, 1
  for grapheme, width in Width.graphemes(text, options) do
    for offset = 1, width do cells[x + offset - 1] = offset == 1 and grapheme or "" end
    x = x + width
  end
  return cells
end
-- The column a glyph is on, so the self-checks below are not a set of hand-counted
-- offsets that go stale the moment the sample row is edited.
local function column_of(cells, glyph, from)
  for x = from or 1, #cells do
    if cells[x] == glyph then return x end
  end
  return nil
end
do
  local options = { unicode = true }
  local plain = cells_of("wtop Overview +9 Update rate: Medium", options)
  local plus = assert(column_of(plain, "+"))
  local found, mine = read_count({plus, plus + 1, plus + 2}, plain)
  require(found == "+9" and #mine == 2,
    "the reader cannot find a count it is given whole, so every result below is "
    .. "about the reader")
  require(read_count({1, 2, 3, 4},
    cells_of("wtop Overview  Processes  Update rate", options)) == nil,
    "the reader invents a count on a row that carries none")
  local two = cells_of("wtop Overview +10 Update rate", options)
  local wide = assert(column_of(two, "+"))
  require(select(1, read_count({wide, wide + 1, wide + 2}, two)) == "+10",
    "the reader cannot tell a two-digit count from a one-digit one")
  local elsewhere = cells_of("wtop  Overview  Update rate: +9", options)
  local outside = assert(column_of(elsewhere, "+"))
  require(read_count({1, 2}, elsewhere) == nil
    and select(1, read_count({outside, outside + 1}, elsewhere)) == "+9",
    "the reader takes a count from outside the run it was asked about, or misses one "
    .. "inside it")
  local holed = cells_of("wtop Overview + 9 Update rate", options)
  local gap = assert(column_of(holed, "+"))
  require(read_count({gap, gap + 1, gap + 2}, holed) == nil,
    "the reader joins a count across a column that is not carrying a digit, so a cut "
    .. "count would be read as a whole one")
end

-- The snapshot that says what "whole" means: at two hundred columns every page
-- fits, and the cells the bar gives each one there are what every narrower row is
-- compared against.  It is the product's own output rather than a second opinion
-- about what a page looks like, and it is tied to the catalogue by the label it has
-- to carry -- spelled by the bar's own renderer, because in the ASCII fallback the
-- grid substitutes what the terminal cannot take, and a snapshot that has to match
-- a label the grid would never draw is a snapshot that would fire for the wrong
-- reason.  One snapshot per spelling, because the ASCII grid measures a CJK label
-- differently.
local WHOLE = { [true] = {}, [false] = {} }
local function spelled(text, unicode)
  local scratch = Grid.new(200, 1, {
    default_style = theme:style("text.primary", "surface.base"), unicode = unicode,
  })
  scratch:write(1, 1, text, scratch.default_style)
  -- `row_text` is the whole row, blanks to the right edge included.
  local row = scratch:row_text(1)
  return (row:gsub("%s+$", ""))
end
-- How many pages share their spelling with another page.  In the ASCII fallback
-- this is not zero and cannot be made zero by this file: the grid substitutes
-- every grapheme the terminal cannot take, so five Japanese pages arrive on the
-- row as five runs of `?` and the reader cannot tell them apart.  It is measured
-- and reported rather than required, because a rule that fails on it would be a
-- rule about transliterating the catalogues, which is a product decision and not
-- this increment's -- `docs/PLAN.md` carries it as an open item.
local indistinct = 0
for _, unicode in ipairs({true, false}) do
  for _, locale in ipairs(LOCALES) do
    WHOLE[unicode][locale] = {}
    local grid, meta = draw(200, tabs[1].id, "wtop", locale, {}, unicode)
    require(#(meta.tabs or {}) == #tabs,
      "the reference row for " .. locale .. " drew " .. #(meta.tabs or {}) .. " of "
      .. #tabs .. " pages, so 'whole' means nothing in that catalogue")
    local cells = read_cells(grid)
    local seen = {}
    for _, box in ipairs(meta.tabs or {}) do
      local drawn = slice(cells, box.x, box.x + box.width - 1)
      WHOLE[unicode][locale][box.id] = drawn
      local label = spelled(labels[locale][box.id], unicode)
      require(drawn:find(label, 1, true) ~= nil,
        "the reference row for " .. locale .. " does not carry the label of "
        .. box.id .. ": " .. string.format("%q", drawn))
      if seen[drawn] then
        indistinct = indistinct + 1
      else
        seen[drawn] = box.id
      end
    end
  end
end

local renders, with_hidden, counted = 0, 0, 0
local page_rows, count_alone_rows, marker_rows, empty_rows = 0, 0, 0, 0
local pages_with_name, pages_whole, pages_named_cut, ascii_marker = 0, 0, 0, 0
local bad = {brand = 0, bare = 0, silent = 0, off = 0, cut_name = 0, unaccounted = 0,
  overnamed = 0, books = 0, whole = 0, budget = 0, room = 0, flush = 0}
local first = {}
local function note(key, message)
  first[key] = first[key] or message
  bad[key] = bad[key] + 1
end
local problems = {}
local function record(message)
  if #problems >= 6 then return end
  problems[#problems + 1] = message
end

local function sweep(columns_list, unicode)
  local marker = unicode and "…" or "."
  for _, columns in ipairs(columns_list) do
    for _, brand in ipairs(BRANDS) do
      for _, entry in ipairs(STATES) do
        for _, locale in ipairs(LOCALES) do
          for _, tab in ipairs(tabs) do
            local grid, meta = draw(columns, tab.id, brand, locale, entry.extra, unicode)
            renders = renders + 1
            local cells = read_cells(grid)
            local options = grid.width_options
            local boxes = meta.tabs or {}
            local drawn, hidden = #boxes, #tabs - #boxes
            local where = ("%s at %d columns, brand %q, %s, active %s")
              :format(locale, columns, brand, entry.name, tab.id)

            -- The bar's own geometry, checked against the row before any rule
            -- below is allowed to use it.  The brand is the row's first cells and
            -- the sampler is the row's cells at the published x; a published
            -- number the row contradicts is a defect in its own right, and a
            -- published number the row agrees with cannot be used to skip a rule.
            if type(meta.brand_width) ~= "number" or type(meta.sample_x) ~= "number" then
              note("brand", where .. ": the bar published no brand width or sampler "
                .. "position, so its run cannot be found on the row")
            else
              local head = slice(cells, 1, meta.brand_width)
              local stem = head
              if #brand > meta.brand_width then stem = head:sub(1, #head - #marker) end
              local brand_ok = Width.display_width(head, options) == meta.brand_width
                and (brand:sub(1, #stem) == stem)
                and (#brand <= meta.brand_width or head:sub(-#marker) == marker)
              if not brand_ok then
                note("brand", where .. ": the bar says its brand is " ..
                  tostring(meta.brand_width) .. " cells wide and the row's first "
                  .. tostring(meta.brand_width) .. " cells are "
                  .. string.format("%q", head))
                record(where .. ": the row's brand does not match the width the bar "
                  .. "published")
              end
              if meta.room ~= meta.sample_x - meta.brand_width - 3 then
                note("room", where .. ": the bar says its run is " .. tostring(meta.room)
                  .. " cells, and its own brand and sampler positions give "
                  .. tostring(meta.sample_x - meta.brand_width - 3))
                record(where .. ": the bar's published run width and its own "
                  .. "geometry do not add up")
              end
              if meta.frequency and
                  (blank(cells[meta.frequency.x]) or Width.display_width(
                    slice(cells, meta.frequency.x,
                      meta.frequency.x + meta.frequency.width - 1), options)
                    ~= meta.frequency.width) then
                note("brand", where .. ": the bar published a sampler box at "
                  .. meta.frequency.x .. " the row does not fill")
                record(where .. ": the bar published a sampler box the row does not "
                  .. "fill")
              end
            end

            -- The run: the cells between the brand and the sampler, and which of
            -- them the bar drew a page on.
            local from = (meta.brand_width or 0) + 2
            local to = (meta.sample_x or 1) - 1
            local page_at, outside = {}, {}
            for _, box in ipairs(boxes) do
              for x = box.x, box.x + box.width - 1 do page_at[x] = box end
            end
            for x = from, to do
              if not page_at[x] then outside[#outside + 1] = x end
            end
            local found, count_columns = read_count(outside, cells)
            local claimed = {}
            for _, column in ipairs(count_columns) do claimed[column] = true end

            -- The statement does not touch the sampler.  The run leaves one quiet
            -- cell between the last thing it writes and the rate, which is the
            -- padded segment increment 105's rule asks to be visible, and a count
            -- written flush against `Update rate` is a row where two things have
            -- run together rather than a row that says two things.  This clause
            -- exists because the guarantee is not the bar's: **removing the fit
            -- check from `tab_bar.lua` took mutation M332 with it**, because the
            -- reservation says the statement's digits fit and the quiet cell
            -- belongs to the one-cell lead's condition, so a lead that spends a
            -- cell leaves the statement against the rate and the product does not
            -- notice.  Whether a row leaves the cell is a question about the row.
            if found ~= nil and count_columns[#count_columns] > to - 1 then
              note("flush", where .. ": the statement ends at column "
                .. count_columns[#count_columns] .. " and the sampler starts at "
                .. tostring(meta.sample_x) .. ", so the run leaves no quiet cell")
              record(where .. ": the statement is written against the sampler")
            end

            -- The page cells.  A page the bar draws is on the row under a name
            -- that says something: its own label or a cut of it, never the cut
            -- marker and the padding alone, which is the defect this increment
            -- closed.  A page that is not the one the reader is on is drawn whole
            -- or not at all.
            for _, box in ipairs(boxes) do
              if box.x < from or box.x + box.width - 1 > to then
                note("unaccounted", where .. ": page " .. box.id .. " is drawn at "
                  .. box.x .. ".." .. (box.x + box.width - 1) .. ", outside the run "
                  .. from .. ".." .. to)
              end
              local says = false
              for x = box.x, box.x + box.width - 1 do
                local cell = cells[x]
                if not blank(cell) and cell ~= marker then says = true end
              end
              if not says then
                note("bare", where .. ": the bar drew page " .. box.id .. " in "
                  .. string.format("%q", slice(cells, box.x, box.x + box.width - 1))
                  .. ", a cell that says nothing")
                record(where .. ": the bar drew a page in a cell that says nothing")
              else
                pages_with_name = pages_with_name + 1
              end
              if box.id ~= tab.id then
                local text = slice(cells, box.x, box.x + box.width - 1)
                if text ~= WHOLE[unicode][locale][box.id] then
                  note("whole", where .. ": page " .. box.id .. " is on the row as "
                    .. string.format("%q", text) .. ", which is not the whole of it ("
                    .. string.format("%q", WHOLE[unicode][locale][box.id]) .. ")")
                  record(where .. ": a page that is not the reader's is cut")
                  if says then pages_named_cut = pages_named_cut + 1 end
                else
                  pages_whole = pages_whole + 1
                end
              elseif says then
                pages_named_cut = pages_named_cut + 1
              end
            end
            if drawn > 0 then
              page_rows = page_rows + 1
              local active_on_bar = false
              for _, box in ipairs(boxes) do
                if box.id == tab.id then active_on_bar = true end
              end
              if not active_on_bar then
                note("off", where .. ": the bar drew " .. drawn ..
                  " page(s) and the reader's own page is not among them")
                record(where .. ": the bar drew " .. drawn ..
                  " page(s) and left the reader's own page off the bar")
              end
            end
            if drawn == 0 and (meta.active_width or 0) ~= 0 then
              note("books", where .. ": the bar drew nothing and published an active "
                .. "width of " .. tostring(meta.active_width))
              record(where .. ": the bar drew nothing and published an active width")
            end

            -- Every cell of the run belongs to a page, to the statement, to the
            -- silence between them, to the one-cell lead that says there are pages
            -- to the left, or to the one-cell mark that says the run was cut -- and
            -- the lead only counts in the first cell of the run and the mark only
            -- in its last, which are the only two places either can mean anything.
            -- A glyph that is none of those is a claim on the row that this file
            -- cannot read, and a row that makes claims nobody can read is a row
            -- that has lost one.
            local lead = unicode and "‹" or "<"
            local last_lit = nil
            for _, column in ipairs(outside) do
              if not blank(cells[column]) then last_lit = column end
            end
            for _, column in ipairs(outside) do
              if not blank(cells[column]) and not claimed[column]
                  and not (cells[column] == lead and column == from)
                  and not (cells[column] == marker and column == last_lit) then
                note("unaccounted", where .. ": column " .. column .. " of the run "
                  .. "holds " .. string.format("%q", cells[column]) ..
                  ", which belongs to nothing: " .. grid:row_text(1))
              end
            end

            -- The statement.  A page the bar is not drawing is on the row as a
            -- count of exactly that many, or -- where the run is too narrow even
            -- for the count -- as the one-cell mark that says the run was cut.
            -- Which of the two a row owes is the bar's own budget; the row's
            -- obligation is not.
            local budget = meta.budget
            if type(budget) ~= "table" or type(budget.beside) ~= "number"
                or type(budget.alone) ~= "number" or type(budget.name) ~= "number" then
              note("budget", where .. ": the bar published no budget of three widths, "
                .. "so this file cannot tell what the row owes")
              record(where .. ": the bar published no budget of three widths")
            elseif hidden == 0 then
              if found ~= nil then
                note("overnamed", where .. ": all " .. #tabs .. " pages are drawn and "
                  .. "the run still carries " .. found)
                record(where .. ": the run carries a count on a bar that draws "
                  .. "every page")
              end
            elseif meta.room >= budget.beside + budget.name then
              if drawn < 1 then
                note("silent", where .. ": the run had room for a name and the "
                  .. "statement and the bar drew no page at all")
              end
              if found ~= "+" .. hidden then
                note("silent", where .. ": " .. hidden .. " page(s) are not drawn and "
                  .. "the run carries " .. (found or "no count at all") .. ": "
                  .. grid:row_text(1))
                record(where .. ": " .. hidden .. " page(s) are not drawn and the run "
                  .. "carries " .. (found or "no count at all"))
              else
                counted = counted + 1
              end
            elseif meta.room >= budget.alone then
              if drawn ~= 0 then
                note("silent", where .. ": the run bought the statement alone and a "
                  .. "page as well")
                record(where .. ": the run bought the statement alone and a page too")
              end
              if found ~= "+" .. hidden then
                note("silent", where .. ": the run holds the statement alone and it "
                  .. "carries " .. (found or "nothing"))
                record(where .. ": the run holds the statement alone and carries "
                  .. (found or "nothing"))
              else
                counted = counted + 1
                count_alone_rows = count_alone_rows + 1
              end
            elseif meta.room > 0 then
              if drawn ~= 0 then
                note("silent", where .. ": the run is " .. meta.room ..
                  " cell(s) wide and the bar still drew a page on it")
                record(where .. ": the run is " .. meta.room ..
                  " cell(s) wide and still drew a page")
              end
              local lit = {}
              for _, column in ipairs(outside) do
                if not blank(cells[column]) then lit[#lit + 1] = column end
              end
              local text = slice(cells, lit[1] or 0, lit[#lit] or -1)
              if #lit ~= 1 or text ~= marker or meta.window ~= marker then
                note("silent", where .. ": the run is " .. meta.room ..
                  " cell(s) wide, too narrow for a count, and holds "
                  .. (#lit == 0 and "nothing" or string.format("%q", text)))
                record(where .. ": the run is too narrow for a count and holds "
                  .. (#lit == 0 and "nothing" or string.format("%q", text)))
              else
                marker_rows = marker_rows + 1
                if not unicode then ascii_marker = ascii_marker + 1 end
              end
            else
              local lit = 0
              for _, column in ipairs(outside) do
                if not blank(cells[column]) then lit = lit + 1 end
              end
              if drawn ~= 0 or lit > 0 then
                note("silent", where .. ": the run has no cells and the bar still put "
                  .. drawn .. " page(s) and " .. lit .. " non-blank cell(s) on the row")
                record(where .. ": the run has no cells and the bar still put "
                  .. drawn .. " page(s) on it")
              end
              empty_rows = empty_rows + 1
            end
            if hidden > 0 then with_hidden = with_hidden + 1 end

            -- The bar's own books, which are a separate claim from the row's.
            local blocked = meta.blocked
            local key = blocked == nil and true or blocked
            if blocked ~= nil and BLOCKED[blocked] == nil then
              note("books", where .. ": the bar reported the situation "
                .. string.format("%q", tostring(blocked))
                .. ", which is not one of the three it declares")
              record(where .. ": the bar reported a situation it does not declare")
            else
              BLOCKED[key] = (BLOCKED[key] or 0) + 1
            end
            if meta.hidden ~= hidden then
              note("books", where .. ": the row drew " .. drawn .. " of " .. #tabs ..
                " pages and the bar reported " .. tostring(meta.hidden) .. " hidden")
              record(where .. ": the bar's hidden count is not the row's")
            end
            if (meta.count ~= nil) ~= (blocked == "none") then
              note("books", where .. ": the bar reported " .. tostring(blocked) ..
                " and the count " .. tostring(meta.count) ..
                ", which cannot both be right")
              record(where .. ": the bar's count and its report disagree")
            end
            if meta.count ~= nil then
              if meta.count ~= "+" .. meta.hidden then
                note("books", where .. ": the bar wrote " .. string.format("%q", meta.count)
                  .. " while reporting " .. tostring(meta.hidden) .. " pages hidden")
                record(where .. ": the count the bar wrote is not its own hidden count")
              end
              if meta.count_width ~= Width.display_width(meta.count, options) then
                note("books", where .. ": the bar wrote a " .. tostring(meta.count_width)
                  .. "-cell count and the text is not that wide")
                record(where .. ": the count width the bar published is not its width")
              end
              if found ~= meta.count then
                note("books", where .. ": the bar says it wrote " .. meta.count ..
                  " and the run does not carry it")
                record(where .. ": the count the bar claims to have written is not on "
                  .. "the run")
              end
            elseif meta.count_width ~= 0 then
              note("books", where .. ": the bar published a count width of "
                .. tostring(meta.count_width) .. " and wrote no count")
              record(where .. ": the bar published a count width and no count")
            end
            local reserved = 0
            if hidden > 0 and budget then
              if meta.room >= budget.beside + budget.name then reserved = budget.beside
              elseif meta.room >= budget.alone then reserved = budget.alone end
            end
            if meta.reserved ~= reserved then
              note("budget", where .. ": the bar booked " .. tostring(meta.reserved) ..
                " cell(s) for the statement and its own budget books " ..
                tostring(reserved))
              record(where .. ": the bar's booking and its own budget disagree")
            end
            local expected = 1
            for index, candidate in ipairs(tabs) do
              if candidate.id == tab.id then expected = index end
            end
            if meta.active_index ~= expected then
              note("books", where .. ": the bar says the reader's page is number "
                .. tostring(meta.active_index) .. " and it is number " .. expected)
              record(where .. ": the bar's active index is not the page asked for")
            end
            local first_index, last_index = nil, nil
            for _, box in ipairs(boxes) do
              first_index = first_index or box.index
              last_index = box.index
            end
            if meta.first_visible ~= first_index or meta.last_visible ~= last_index then
              note("books", where .. ": the bar says the run holds pages "
                .. tostring(meta.first_visible) .. ".." .. tostring(meta.last_visible)
                .. " and its own boxes say " .. tostring(first_index) .. ".."
                .. tostring(last_index))
              record(where .. ": the bar's first and last page are not its own boxes")
            end
          end
        end
      end
    end
  end
end

sweep(COLUMNS, true)
sweep(ASCII_COLUMNS, false)

-- ---------------------------------------------------------------------------
-- The rules.
-- ---------------------------------------------------------------------------
require(bad.bare == 0, "page cells that say nothing: " .. bad.bare .. " of them\n    "
  .. tostring(first.bare))
require(bad.silent == 0, bad.silent .. " row(s) that hid a page without saying so on "
  .. "the run\n    " .. tostring(first.silent))
require(bad.off == 0, bad.off .. " row(s) that drew a page and left the reader's own "
  .. "page off the bar\n    " .. tostring(first.off))
require(bad.whole == 0, bad.whole .. " page(s) drawn cut that are not the reader's own\n    "
  .. tostring(first.whole))
require(bad.unaccounted == 0, bad.unaccounted .. " cell(s) of the run that belong to "
  .. "nothing\n    " .. tostring(first.unaccounted))
require(bad.overnamed == 0, bad.overnamed .. " row(s) that carry a count and draw every "
  .. "page\n    " .. tostring(first.overnamed))
require(bad.brand == 0, bad.brand .. " row(s) whose published geometry the row "
  .. "contradicts\n    " .. tostring(first.brand))
require(bad.room == 0, bad.room .. " row(s) whose published run width is not its own "
  .. "geometry\n    " .. tostring(first.room))
require(bad.books == 0, bad.books .. " row(s) whose own report does not hold\n    "
  .. tostring(first.books))
require(bad.budget == 0, bad.budget .. " row(s) whose booking and budget disagree\n    "
  .. tostring(first.budget))
require(bad.flush == 0, bad.flush .. " row(s) whose statement is written against the "
  .. "sampler\n    " .. tostring(first.flush))
require(#problems == 0, "the first of the problems above, and "
  .. #problems .. " in all:\n    " .. table.concat(problems, "\n    "))

-- Non-vacuity.  A sweep that never hides a page tests a rule that cannot fire; a
-- sweep where the count always fits beside a name tests no decision at all; and a
-- sweep with one shape of run tests a partition of one.  Each of the four bands
-- the policy has has to be occupied, and each of the two rules that carry the
-- weight has to have rows that pass it and rows that could have failed it.
require(renders > 0, "no render was made, so the rules were applied to nothing")
require(with_hidden > 0, "no render hid a page, so the count rule was applied to nothing")
require(counted > 0, "no render carried a count, so the count rule was applied to nothing")
require(page_rows > 0, "no render drew a page, so the name rules were applied to nothing")
require(count_alone_rows > 0, "no render left the statement alone, so the band where "
  .. "the run cannot pay for a name was never exercised")
require(marker_rows > 0, "no render fell back to the one-cell mark, so the band where "
  .. "the run cannot even pay for the statement was never exercised")
require(empty_rows > 0, "no render had a run with no cells at all, so the floor was "
  .. "never exercised")
require(pages_whole > 0, "no page other than the reader's own was ever drawn, so the "
  .. "rule that such a page is drawn whole was applied to nothing")
require(pages_with_name > 0,
  "no page was ever drawn, so the rule that a page cell has to say something was "
  .. "applied to nothing")
require(pages_named_cut > 0,
  "no page was ever drawn cut, so the rule against a bare marker never had to tell "
  .. "a cut name from a cut marker and could not have caught the defect it was "
  .. "written for")
require(counted + marker_rows + empty_rows == with_hidden,
  "the rows that hid a page do not fall into the three shapes the run has: "
  .. counted .. " carried a count, " .. marker_rows .. " carried the one-cell mark, "
  .. empty_rows .. " had no cells, and " .. with_hidden .. " hid a page in all")
require(BLOCKED["none"] > 0, "the bar never reported writing a count, so the row rule "
  .. "was never asked of a bar that had one to write")
require(BLOCKED["no-room"] > 0, "the bar never reported that the statement could not "
  .. "be paid for, so the one-cell mark was never asked of a bar that owed it")
require(BLOCKED[true] > 0, "no render drew every page, so the rule about a count on a "
  .. "bar that hides nothing was applied to nothing")
require(ascii_marker > 0, "the ASCII spelling of the one-cell mark was never exercised")
require(#LOCALES > 1 and #COLUMNS > 1 and #ASCII_COLUMNS > 1 and #BRANDS > 1
  and #STATES > 1 and #tabs > 1,
  "the sweep is narrower than the product: it must vary the width, the spelling, the "
  .. "catalogue, the brand, the row state and the page")

assert(#failures == 0,
  table.concat(failures, "\n  ") .. "\n  (" .. #failures
  .. " problem(s); they are reported together so a run that finds a defect "
  .. "explains all of it)")

io.write(string.format(
  "ok: the tab bar counts what it is not showing (%d renders over %d widths, %d ASCII "
  .. "widths, %d brands, %d states, %d catalogues and %d pages; %d renders hid a page "
  .. "and %d of those carried the count; the run's four shapes: %d drew a name and a "
  .. "count, %d the count alone, %d the one-cell mark (%d of them in the ASCII "
  .. "spelling), %d had no cells to say anything in; %d pages were drawn and %d of the "
  .. "reader's-neighbour pages whole; the bar's own partition: %d wrote a count, %d "
  .. "could not pay for it, %d had nothing to say; %d page(s) across the twenty "
  .. "reference rows share their ASCII spelling with another page, which is a "
  .. "measurement and not a rule)\n",
  renders, #COLUMNS, #ASCII_COLUMNS, #BRANDS, #STATES, #LOCALES, #tabs,
  with_hidden, counted, counted - count_alone_rows, count_alone_rows, marker_rows,
  ascii_marker, empty_rows, pages_with_name, pages_whole, BLOCKED["none"],
  BLOCKED["no-room"], BLOCKED[true], indistinct))
