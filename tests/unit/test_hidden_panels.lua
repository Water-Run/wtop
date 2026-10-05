-- A panel that is not on the screen is named on the footer row.
--
-- The responsive solver drops panels when the terminal is too small, and it
-- records each one: `solve` returns `hidden` with an id and a reason.  For three
-- increments the question had been the *widget's* content -- does a table row, a
-- bar or a segment get silently dropped -- and each time the answer turned out to
-- be that the component reports what it dropped.  The panel is the outer layer of
-- the same question, and nobody had asked it.
--
-- The chain is real and it is wired: `page.lua` computes
-- `layout = {visible = #placements, total = #placements + #hidden}` and hands it
-- to the status bar, and `status_bar.lua` prints `▦ v/t` when `total > visible`.
-- The solver's own accounting is sound -- over 151 900 solves across every page,
-- every width from 16 to 260 and every height from 3 to 64, no declared panel was
-- missing from both lists, none was in both, and none was counted twice.  The
-- defect was one layer up, in what the row had room for.
--
-- Measured over ten pages, every width from 20 to 240 and every height from 3 to
-- 40 -- 28 620 renders in which the solver hid at least one declared panel,
-- carrying the `data_age` `tui.lua` actually writes and nothing else competing --
-- the count was printed whole in 22 357 and **absent from the row in 6 263**, all
-- of them below 45 columns.  Worse, the shape of the loss was not always absence:
-- at 40x24 the row ended `14:23:07 · ▦ 3…`, and at 44 it ended `▦ 3/…` -- a
-- numerator with no denominator, which reads as "3".  Forty-four columns is an
-- ordinary split-pane width, and `status_bar.lua`'s own comment already calls
-- forty one.
--
-- Two causes, and the second is the one that kept it invisible to a test.
--
-- `data_age` was assigned to `right`, which is the *message's* slot, so the age
-- outranked the count -- and the age is not a message.  `tui.lua` fills it from
-- `clock_label()`, a `%H:%M:%S` wall clock, eight cells.  `test_footer_message.lua`
-- checks this row's quiet states with a `data_age` of `2s`, three cells: a guard
-- built on a marker five cells narrower than the product's own could not see the
-- row it is guarding.  The answer is not to repair that one fixture but to make
-- the rule hold for every age width, which is why the sweep varies it.
--
-- The fix is an ordering and a shorter form, and a shorter form has to answer a
-- real constraint or it is a style.  The count now leads the context -- count,
-- then the filter, then the age -- and drops to `▦ +N` when the full `v/t` does
-- not fit the budget the row has left, which is the idiom `bars` and `segments`
-- already use for entries that did not fit.  The price is real: the age loses its
-- tail where a count is on the row and the two do not both fit, and the count
-- still yields to a message, which is the price increment 103 already measured
-- and accepted.
--
-- What this file deliberately does not do is read the two components' return
-- values in the rule that found the defect.  A rule that asks `solve` what it hid
-- and then asks the row to agree tests the components against each other.  This
-- one asks the *screen* which panels are on it -- through the frames the product
-- actually drew -- asks the page's own tree which panels were declared, and then
-- asks the row what it says about the difference.  What the components publish is
-- checked in its own clause, which is where a report belongs.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local I18n = require("wtop.i18n")
local Panel = require("wtop.ui.widgets.panel")
local Width = require("wtop.ui.renderer.width")
local Workspace = require("wtop.workspace")

local failures = {}
local function require(condition, message)
  if not condition then failures[#failures + 1] = message end
end

local COLUMNS = {}
for columns = 20, 240, 6 do COLUMNS[#COLUMNS + 1] = columns end
-- Heights sit either side of every band the solver switches in: 3 is the
-- degenerate one, 12 is the `tiny` ceiling, 24 and 40 are the two shapes this
-- product documents.
local HEIGHTS = { 3, 5, 8, 12, 16, 24, 32, 40 }
-- Four ages, from none to wider than the product's own.  `nil` is a real product
-- state: `clock_label()` returns nil when the engine has no wall clock.  `2s` is
-- the shape `test_footer_message.lua` uses, kept so that file's width is covered
-- here too.  `14:23:07` is `clock_label()`'s own format, eight cells.  The last is
-- wider than anything the product writes, and the rule has to hold for it anyway:
-- a count that leads is a count that survives.
local AGES = { { name = "no clock", value = nil },
  { name = "2s", value = "2s" },
  { name = "14:23:07", value = "14:23:07" },
  { name = "dated", value = "2024-06-01 14:23:07" } }
-- A root session puts `root` at the head of the row's right-hand side.  It is
-- context, not a message -- nothing yields to it -- so the count is still owed
-- behind it, and it is the only thing in the product's states that stands between
-- the count and the budget.  The first version of this sweep had no such state,
-- and a mutation that stopped the row subtracting what the lead had already spent
-- passed it: the arithmetic was never executed.  A rule needs a shape that
-- exercises it, not only shapes that cannot reach it.
local PRIVILEGES = { { name = "user", value = nil },
  { name = "root", value = { root = true } } }
local ASCII_GEOMETRIES = { { 20, 3 }, { 40, 5 }, { 44, 12 }, { 60, 24 }, { 80, 40 } }
-- Two sweeps carry a message, and they are on a short geometry list because the
-- count is *not* owed behind one -- that is the price increment 103 accepted and
-- measured -- while the budget arithmetic, which subtracts what the lead already
-- spent, only ever runs when there *is* a lead.  A mutation that stopped the row
-- subtracting it passed a sweep that held no message at all, and then passed a
-- second one that held a root marker, because the marker follows the count and
-- never became a lead either.  A rule needs a shape that reaches the arithmetic.
local MESSAGE_GEOMETRIES = { { 20, 3 }, { 28, 5 }, { 36, 8 }, { 44, 12 }, { 52, 16 },
  { 60, 24 }, { 80, 24 }, { 120, 40 }, { 160, 24 }, { 200, 40 } }
-- A real catalogue string, not a shape invented here: the message slot is filled
-- by `tui.lua` and the sweep should fill it the same way.  It is 32 cells wide,
-- which matters -- a shorter message would narrow the band of widths where the
-- count's own budget is the binding constraint, and that band is where the
-- subtraction is observable.
local MESSAGE = assert(I18n.new({ locale = "en-US" }))
  :t("process.columns_hidden", "Show the column before moving it")

local function width_of(text)
  return Width.display_width(text, { unicode = true })
end

-- What a page declares.  This is the page's own tree, which is data rather than a
-- report: `total` counts every widget node the solver accounts for, and `titles`
-- counts the ones a reader could name.
local function declared(node, out)
  if node.type == "widget" then
    out.total = out.total + 1
    if node.panel == false then
      out.unpanelled = out.unpanelled + 1
    elseif type(node.panel_title) ~= "string" or node.panel_title == "" then
      out.untitled = out.untitled + 1
    else
      out.titles[#out.titles + 1] = node.panel_title
    end
  elseif node.type == "flow" then
    for _, child in ipairs(node.children) do declared(child, out) end
  else
    declared(node.first, out)
    declared(node.second, out)
  end
end

local workspace = Workspace.new({})
local pages = {}
for id in pairs(workspace.pages) do pages[#pages + 1] = id end
table.sort(pages)

local page_declaration, identity_problems = {}, {}
for _, id in ipairs(pages) do
  local collected = { titles = {}, total = 0, untitled = 0, unpanelled = 0 }
  declared(workspace.pages[id].layout, collected)
  local seen = {}
  for _, title in ipairs(collected.titles) do
    if seen[title] then
      collected.untitled = collected.untitled + 1
    else
      seen[title] = true
    end
  end
  page_declaration[id] = collected
  if collected.untitled > 0 then
    identity_problems[#identity_problems + 1] = ("%s declares %d widget(s) with no "
      .. "panel title, or two with the same one, so a title cannot say which panel "
      .. "is on the screen"):format(id, collected.untitled)
  end
  if collected.unpanelled > 0 then
    identity_problems[#identity_problems + 1] = ("%s declares %d widget(s) with no "
      .. "panel, which this file cannot see: a widget with no panel draws no frame")
      :format(id, collected.unpanelled)
  end
end
require(#identity_problems == 0, "the pages this sweep reads cannot be identified by "
  .. "their titles, so a panel on the screen could not be told from one that is not:\n    "
  .. table.concat(identity_problems, "\n    "))

-- Which panels the product actually drew.  `Panel.render` is the one place a panel
-- frame is written, so the titles it is handed are the panels on the screen --
-- counted without asking the solver or the status bar anything.
local drawn, drawing = {}, false
local real_panel_render = Panel.render
Panel.render = function(grid, area, model, context, content_renderer)
  if drawing and type(model) == "table" and type(model.title) == "string" then
    drawn[model.title] = (drawn[model.title] or 0) + 1
  end
  return real_panel_render(grid, area, model, context, content_renderer)
end

-- The token the row carries after the mark: `v/t`, `+k`, a fragment of either, or
-- nothing.  Reading the token instead of searching for a known one is what makes a
-- *wrong* count a failure: `▦ 3/…` is neither `3/11` nor `+8`, so a numerator that
-- lost its denominator cannot pass as a count.
--
-- The trailing ellipsis is not part of the number.  `Width.truncate` closes a cut
-- string with `…` (a `.` on an ascii terminal), and the first version of this
-- reader kept it, so a row that ended `▦ 1/11…` -- the count whole, the data age
-- behind it cut -- was reported as carrying the count `1/11…`, which is neither
-- form.  Stripping it with `sub(-1)` did not work either: `sub` indexes *bytes*,
-- and the last byte of `…` is 0xA6, so the comparison against a three-byte
-- literal was false and nothing was stripped.  A reader that invents a defect is
-- as bad as one that misses one, and this one cost a 29-second sweep to report a
-- punctuation mark.
local ELLIPSIS = "[%.…]+$"
local function count_token(row, mark)
  local at = row:find(mark, 1, true)
  if not at then return nil end
  local token = row:sub(at + #mark):match("^%s*(%S+)")
  if token == nil then return nil end
  local trimmed = token:gsub(ELLIPSIS, "")
  return trimmed ~= "" and trimmed or nil
end

local renders, losses, quiet, privileged = 0, 0, 0, 0
local leads, message_losses, message_named = 0, 0, 0
local named_full, named_compact, unnamed, overnamed = 0, 0, 0, 0
local first_unnamed, first_over = nil, nil
local ascii_renders, ascii_named = 0, 0
local solves, partitions = 0, 0
local form_full, form_compact, form_none = 0, 0, 0
local report_problems, solver_problems = {}, {}
-- A defect in the row repeats across every width in the sweep, so an uncapped list
-- is not a diagnosis: the first version of this file reported one line per render
-- and turned a single finding into thousands of them.  Six is enough to see the
-- shape, and the rest are counted rather than printed.
local PROBLEM_LIMIT = 6
local overflow = { report = 0, solver = 0 }
local function record(list, kind, message)
  if #list >= PROBLEM_LIMIT then
    overflow[kind] = overflow[kind] + 1
  else
    list[#list + 1] = message
  end
end
local function problem_text(list, kind)
  if overflow[kind] == 0 then return table.concat(list, "\n    ") end
  return table.concat(list, "\n    ") .. string.format("\n    ... and %d more of the "
    .. "same shape", overflow[kind])
end

-- A state is what `tui.lua` can hand the row, and `owed` says whether the count is
-- owed on it.  A message is the one piece the count yields to, so a state with a
-- message is not owed one; everything else on the row is context and does not
-- excuse the count.
local function state_of(age, privilege, message)
  return { age = age, privilege = privilege, message = message, owed = message == nil }
end
local QUIET_STATES = {}
for _, age in ipairs(AGES) do
  for _, privilege in ipairs(PRIVILEGES) do
    QUIET_STATES[#QUIET_STATES + 1] = state_of(age.value, privilege.value, nil)
  end
end
local MESSAGE_STATES = { state_of("14:23:07", nil, MESSAGE),
  state_of("2s", { root = true }, MESSAGE) }

local function sweep(unicode, geometries, states)
  local mark = unicode and "▦" or "[]"
  local capabilities = { unicode = unicode }
  local count = { renders = 0, losses = 0, quiet = 0, full = 0, compact = 0,
    unnamed = 0, overnamed = 0, named = 0, privileged = 0, leads = 0,
    message_losses = 0, message_named = 0 }
  for _, id in ipairs(pages) do
    local declaration = page_declaration[id]
    local declared_count = #declaration.titles
    workspace:select(id)
    for _, geometry in ipairs(geometries) do
      local columns, rows = geometry[1], geometry[2]
      if unicode then
        -- The solver's own books, kept apart from the rule below on purpose: this
        -- one asks the component, so it cannot be the rule that found the defect.
        local solved = workspace:layout(columns, rows)
        solves = solves + 1
        local placed, hidden = {}, {}
        for _, placement in ipairs(solved.placements) do
          placed[placement.id] = (placed[placement.id] or 0) + 1
        end
        for _, entry in ipairs(solved.hidden) do
          hidden[entry.id] = (hidden[entry.id] or 0) + 1
        end
        local overlap, twice = 0, 0
        for name, count in pairs(placed) do
          if count > 1 then twice = twice + 1 end
          if hidden[name] then overlap = overlap + 1 end
        end
        for _, count in pairs(hidden) do if count > 1 then twice = twice + 1 end end
        local complete = #solved.placements + #solved.hidden == declaration.total
        if complete and overlap == 0 and twice == 0 then partitions = partitions + 1 end
        if not complete or overlap > 0 or twice > 0 then
          record(solver_problems, "solver", ("%s at %dx%d: %d placed and %d "
            .. "hidden against %d declared, %d id(s) in both lists, %d listed twice")
            :format(id, columns, rows, #solved.placements, #solved.hidden,
              declaration.total, overlap, twice))
        end
      end
      for _, entry in ipairs(states) do
        local status = {}
        if entry.age then status.data_age = entry.age end
        if entry.privilege then status.privilege = entry.privilege end
        if entry.message then status.message = entry.message end
        drawn = {}
        drawing = true
        local grid, meta = workspace:render(columns, rows,
          { capabilities = capabilities, status = status })
        drawing = false
        count.renders = count.renders + 1
        local row = grid:row_text(rows)
        -- Counted on quiet states only.  A root marker on a row that carries a
        -- message is a different claim: the product prints the marker whenever it
        -- leads, and letting the message states satisfy this counter let a
        -- mutation that drops the marker from every quiet row pass it.
        if entry.owed and entry.privilege and row:find("root", 1, true) then
          count.privileged = count.privileged + 1
        end
        -- The lead is what the count's budget is measured against.  It is empty
        -- unless a message is on the row: the marker leads only when there is a
        -- message to explain, and on a quiet row it follows the count instead, so
        -- counting renders that merely *carry* a root marker would claim a lead
        -- the budget never saw.
        if entry.message then count.leads = count.leads + 1 end
        local on_screen = 0
        for _ in pairs(drawn) do on_screen = on_screen + 1 end
        local missing = declared_count - on_screen
        local token = count_token(row, mark)
        local full = string.format("%d/%d", on_screen, declared_count)
        local compact = string.format("+%d", missing)
        if missing > 0 then
          if entry.owed then count.losses = count.losses + 1 else count.message_losses = count.message_losses + 1 end
          if token == full or token == compact then
            count.named = count.named + 1
            if entry.owed then
              if token == full then count.full = count.full + 1 else count.compact = count.compact + 1 end
            else
              count.message_named = count.message_named + 1
            end
          elseif entry.owed then
            count.unnamed = count.unnamed + 1
            if not first_unnamed then
              first_unnamed = ("%s at %dx%d, data_age %s: %d of %d panels are not on "
                .. "the screen and the row carries %s: %q")
                :format(id, columns, rows, tostring(entry.age), missing,
                  declared_count, token == nil and "no count at all"
                    or ("the count " .. token), row)
            end
          end
        else
          count.quiet = count.quiet + 1
          if token ~= nil then
            count.overnamed = count.overnamed + 1
            if not first_over then
              first_over = ("%s at %dx%d, data_age %s: all %d declared panels are on "
                .. "the screen and the row still carries the count %q")
                :format(id, columns, rows, tostring(entry.age), declared_count, token)
            end
          end
        end
        -- What the row's own component says it did, asked rather than re-derived.
        local report = meta and meta.status and meta.status.layout
        if type(report) ~= "table" then
          record(report_problems, "report", ("%s at %dx%d: the status bar "
            .. "published nothing about the panel count, so nothing can tell which "
            .. "form it chose"):format(id, columns, rows))
        elseif report.missing ~= missing then
          record(report_problems, "report", ("%s at %dx%d: the screen says %d "
            .. "panels are missing and the status bar published %s")
            :format(id, columns, rows, missing, tostring(report.missing)))
        else
          local full = string.format("%s %d/%d", mark, on_screen, declared_count)
          local compact = string.format("%s +%d", mark, missing)
          local full_width, compact_width = width_of(full), width_of(compact)
          local budget = report.budget or 0
          if report.form == "full" then
            form_full = form_full + 1
            if budget < full_width then
              record(report_problems, "report", ("%s at %dx%d: the long form is "
                .. "%d cells and the row had %d for it, so it could not have been "
                .. "printed whole"):format(id, columns, rows, full_width, budget))
            elseif token == nil then
              -- The row's own account of itself, on any state.  This is the clause
              -- that makes a lead necessary rather than optional: a sweep with no
              -- message never reaches the subtraction the budget is measured by,
              -- and a component that says it printed the long form while the row
              -- carries no count has said something false.
              record(report_problems, "report", ("%s at %dx%d: the status bar reports "
                .. "the long form with a budget of %d cells and the row carries no "
                .. "count at all: %q"):format(id, columns, rows, budget, row))
            end
          elseif report.form == "compact" then
            form_compact = form_compact + 1
            if budget >= full_width then
              record(report_problems, "report", ("%s at %dx%d: the long form is "
                .. "%d cells and the row had %d, so there was room for it and the row "
                .. "printed the short one anyway"):format(id, columns, rows, full_width,
                budget))
            elseif budget < compact_width then
              record(report_problems, "report", ("%s at %dx%d: the short form is "
                .. "%d cells and the row had %d, so neither form could fit")
                :format(id, columns, rows, compact_width, budget))
            end
          else
            form_none = form_none + 1
            if budget >= compact_width then
              record(report_problems, "report", ("%s at %dx%d: the row had %d "
                .. "cells, the short form is %d, and the row carries neither")
                :format(id, columns, rows, budget, compact_width))
            end
          end
        end
      end
    end
  end
  if unicode then
    renders = renders + count.renders
    losses = losses + count.losses
    quiet = quiet + count.quiet
    named_full = named_full + count.full
    named_compact = named_compact + count.compact
    unnamed = unnamed + count.unnamed
    overnamed = overnamed + count.overnamed
    privileged = privileged + count.privileged
    leads = leads + count.leads
    message_losses = message_losses + count.message_losses
    message_named = message_named + count.message_named
  else
    ascii_renders = ascii_renders + count.renders
    ascii_named = ascii_named + count.named
  end
  return count
end

local WIDE_GEOMETRIES = {}
for _, columns in ipairs(COLUMNS) do
  for _, rows in ipairs(HEIGHTS) do WIDE_GEOMETRIES[#WIDE_GEOMETRIES + 1] = { columns, rows } end
end

sweep(true, WIDE_GEOMETRIES, QUIET_STATES)
sweep(true, MESSAGE_GEOMETRIES, MESSAGE_STATES)
sweep(false, ASCII_GEOMETRIES, { state_of("14:23:07", nil, nil) })
Panel.render = real_panel_render

-- ---------------------------------------------------------------------------
-- The rules.
-- ---------------------------------------------------------------------------
require(unnamed == 0, "a panel that is not on the screen with nothing on the row "
  .. "that names it:\n    " .. tostring(first_unnamed))
require(overnamed == 0, "a count on a row where every declared panel is on the "
  .. "screen:\n    " .. tostring(first_over))
require(#solver_problems == 0, "the solver's accounting is not a partition of the "
  .. "declared panels:\n    " .. problem_text(solver_problems, "solver"))
require(#report_problems == 0, "the status bar's report of the count does not match "
  .. "the row it drew:\n    " .. problem_text(report_problems, "report"))

-- Non-vacuity, in the order the rules need.  A sweep that never loses a panel
-- tests a rule that cannot fire; a sweep that only ever prints one form never
-- tests the other; a sweep with no quiet renders cannot tell "no count because
-- nothing is missing" from "no count because it did not fit".
require(renders > 0, "no render was made, so the rules were applied to nothing")
require(losses > 0, "no render lost a panel, so the count rule was applied to nothing")
require(quiet > 0, "no render had every panel on the screen, so the rule about a "
  .. "count appearing when nothing is missing was applied to nothing")
require(named_full > 0, "the long form of the count never appeared, so the rule is "
  .. "only ever satisfied by the short one")
require(named_compact > 0, "the short form of the count never appeared, so the row's "
  .. "answer to a narrow terminal is untested")
require(losses > named_full, "the long form was printed in all " .. named_full
  .. " of the " .. losses .. " renders that lost a panel, so the sweep holds no "
  .. "shape narrow enough to need the short one")
require(privileged > 0, "no quiet render carried a privilege marker, so the product "
  .. "was never asked to put one behind the count, and a mutation that stopped it "
  .. "printing the marker on a quiet row could not fail")
require(leads > 0, "no render had anything ahead of the count, so the budget was "
  .. "never measured against a lead and a mutation that stopped the row subtracting "
  .. "it could not fail")
require(message_losses > 0, "no render behind a message lost a panel, so the message "
  .. "states are not being exercised at all")
require(width_of(MESSAGE) >= 20, "the catalogue message this sweep puts on the row is "
  .. width_of(MESSAGE) .. " cells wide, and a short one would narrow the band of "
  .. "widths where the count's own budget is the binding constraint")
require(solves > 0, "the solver was never asked to solve a layout")
require(partitions == solves, partitions .. " of " .. solves .. " solves partitioned "
  .. "the declared panels into placed and hidden, which is fewer than all of them")
require(ascii_renders > 0 and ascii_named > 0, "the ascii sweep made " .. ascii_renders
  .. " renders and named the missing panels in " .. ascii_named .. " of them")
require(form_full > 0, "the long form was never reported, so the row's own account of "
  .. "its choice is untested")
require(form_compact > 0, "the short form was never reported, so the same is true of "
  .. "the row's answer to a narrow terminal")
require(#pages > 1, "the sweep covers a single page, so the digit widths the count "
  .. "can take are not being varied")
require(width_of("14:23:07") == 8, "the product's own data_age is not eight cells "
  .. "wide, so the fixture that reproduces `clock_label()` has drifted from it")

assert(#failures == 0,
  table.concat(failures, "\n  ") .. "\n  (" .. #failures
  .. " problem(s); they are reported together so a run that finds a defect "
  .. "explains all of it)")

io.write(string.format(
  "ok: hidden panels are named (%d renders over %d pages, %d widths, %d heights, %d "
  .. "data_age widths and two privilege states, plus %d renders behind a real "
  .. "catalogue message and %d ascii renders; %d of the quiet ones lost at least one "
  .. "panel and named it -- %d in the long v/t form and %d in the short +N form -- %d "
  .. "quiet renders lost nothing and none of them carries a count, %d renders put "
  .. "something ahead of the count, the message renders lost a panel %d times and "
  .. "named it in %d, the ascii sweep named its loss in %d of %d; %d solves, all of "
  .. "which partitioned the declared panels into placed and hidden; the row reported "
  .. "the long form %d times and the short form %d)\n",
  renders, #pages, #COLUMNS, #HEIGHTS, #AGES, #MESSAGE_GEOMETRIES * #MESSAGE_STATES
    * #pages, ascii_renders, losses, named_full, named_compact, quiet, leads,
    message_losses, message_named, ascii_named, ascii_renders, solves, form_full,
    form_compact))
