-- The footer's right-hand side, and the one thing it is for.
--
-- Both width guards call `workspace:render` with `status = {}`, so this row has
-- been drawn empty in every render any invariant in this project has ever made.
-- That is not a small gap: `tui.lua` says of it "the one place a transient
-- message can appear" -- the comment that explains why the process table is
-- *not* also printing the filter in its own panel -- and nothing measured what
-- the footer does to a message once one is there.
--
-- It cuts from the front, and the order the pieces were assembled in was the
-- opposite of the priority the bar states about itself.  `has_priority_message`
-- widened the budget from 0.38 of the row to 0.58 (0.72 on a narrow row)
-- precisely because a message or a filter is there, and then the string was
-- built as `▦ v/t · filter · root · message` -- the reason for the extra room
-- last, where the first thing to go is.  Measured over ten catalogues and every
-- width from 40 to 240 with the states `tui.lua` can actually hand this bar, the
-- message or the error was gone from the row entirely in **109 of 22 110
-- renders**: 104 of them the message with a filter, a privilege marker, a layout
-- count and a data age all present at once, absent from 40 to 70 columns in
-- French, 40 to 68 in Spanish and Portuguese and 40 to 54 in traditional
-- Chinese, and 5 of them an *error* disappearing at 40 columns in four
-- catalogues as soon as a filter was there.  Seventy columns is an ordinary
-- split-pane width, and an error is the one thing on this row that cannot be
-- reconstructed from anywhere else on the screen.
--
-- The fix is an ordering, and an ordering has a price, so the price is stated
-- here and not only the benefit: the context -- the layout count, then the
-- filter -- now follows the message and is what gets cut, in 2 815 and 2 708
-- renders respectively.  The filter is a duplicate the product already prints
-- inside the process panel, and the layout count only moves behind a message
-- that has already filled the row.  The two clauses near the bottom hold the
-- other direction: with no message on the row, the status markers do not move.
--
-- Two measurement mistakes are recorded because both of them nearly became
-- findings.  The first version of the metric counted `%S+` tokens of the
-- message, and Japanese and Chinese do not separate words with spaces -- so a
-- whole sentence is one token, and *any* cut read as "entirely absent".  That
-- reported 753 absent renders instead of 109 and named three CJK catalogues as
-- the worst offenders when they were only slightly cut.  The metric is now the
-- longest visible **prefix** of the message, which is both language-agnostic and
-- the same shape as what truncation keeps.  The second mistake was mine and it
-- was in the product, not the measurement: the first version of the fix named
-- its list of trailing pieces `local context`, which shadows this function's
-- `context` parameter -- the one that carries the theme and the translator -- so
-- every `Util.t` and `Util.style` call below it silently fell back and every hint
-- in the footer rendered as English fallback text in all ten catalogues.  It was
-- caught by a number that moved without an explanation: the silent-cut sweep's
-- bounded-write count went from 68 298 to 68 565, because shorter hint labels let
-- more hints fit, and a footer whose only change is a reordering of the right-hand
-- side has no business changing the left.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grid = require("wtop.ui.renderer.grid")
local I18n = require("wtop.i18n")
local StatusBar = require("wtop.ui.widgets.status_bar")
local Theme = require("wtop.ui.theme")
local Width = require("wtop.ui.renderer.width")

local LOCALES = assert(I18n.available())
local failures = {}
local function require(condition, message)
  if not condition then failures[#failures + 1] = message end
end

local theme = Theme.new(Theme.DEFAULT, { unicode = true })
local capabilities = { unicode = true }
local NARROWEST, WIDEST = 40, 240

local function strip(text)
  return (tostring(text or ""):gsub("%s", ""))
end

-- How much of the message is on the row, measured in a way that does not assume
-- the language separates words with spaces.
--
-- This walks down from the full length rather than bisecting, and the bisecting
-- version was written and thrown away: the guess was that the linear search over
-- a 267-cell Russian message at 22 110 renders was costing this file thirteen
-- seconds, and the measurement said the bisected version took the same 14.6
-- seconds as the walk.  The cost is the 22 110 renders -- `StatusBar.render`
-- fills every cell of the row before it writes any of it, which is up to 240
-- cells each time -- and the search is not on it.  A *sampled* search would have
-- been the tempting way to make it fast, and it would have been measuring
-- something else.
local function visible_prefix(row, message)
  local needle = strip(message)
  if needle == "" then return 0 end
  if row:find(needle, 1, true) then return #needle end
  for index = #needle - 1, 1, -1 do
    if row:find(needle:sub(1, index), 1, true) then return index end
  end
  return 0
end

-- The metric's own teeth, before it is used on the product.
require(visible_prefix(strip("Show the column before moving it"),
    "Show the column before moving it")
  == #strip("Show the column before moving it"),
  "the visibility metric does not recognise a message that is on the row in full")
require(visible_prefix(strip("Show the column"), "Show the column before moving it") > 0
  and visible_prefix(strip("Show the column"), "Show the column before moving it")
    < #strip("Show the column before moving it"),
  "the visibility metric cannot tell a cut message from a whole one")
require(visible_prefix(strip("root · ▦ 3/5 · · Filter: node"),
    "Show the column before moving it") == 0,
  "the visibility metric reports a message as visible when the row holds only the "
  .. "context around it, which is the exact defect this file exists for")

-- The messages the product itself puts there, read from the catalogue with the
-- variables `tui.lua` passes.  The states are the combinations `tui.lua` can
-- produce: a filter only exists on the processes page, a privilege marker only
-- when the session is root, the layout count only when widgets are hidden.
local function messages(i18n)
  local function t(id, fallback, vars) return i18n:t(id, vars) or fallback end
  return {
    columns_hidden = t("process.columns_hidden", "Show the column before moving it"),
    filter_status = t("process.filter_status", " · Filter: {query}", { query = "node" }),
    search = t("process.search_prompt", "Search: /{query} · Enter confirms · Esc cancels",
      { query = "worker" }),
    edit = t("layout.edit_message",
      "LAYOUT · Tab select · arrows split/move · [/] resize · e finish"),
    locale_failed = t("status.locale_failed", "Cannot switch language: {reason}",
      { reason = "unknown locale" }),
    recovered = t("status.recovered_backup",
      "Recovered {path} from its backup after: {reason}",
      { path = "/root/.config/wtop/layout.yml.bak", reason = "invalid workspace tree" }),
  }
end

local CASES = {
  { name = "message only", build = function(m) return { message = m.columns_hidden } end },
  { name = "message + data age", build = function(m)
    return { message = m.columns_hidden, data_age = "2s" } end },
  { name = "message + privilege", build = function(m)
    return { message = m.columns_hidden, privilege = { root = true } } end },
  { name = "message + layout overflow", build = function(m)
    return { message = m.columns_hidden, layout = { visible = 3, total = 5 } } end },
  { name = "message + filter", build = function(m)
    return { message = m.columns_hidden, filter = m.filter_status } end },
  { name = "message + filter + privilege + layout + age", build = function(m)
    return { message = m.columns_hidden, filter = m.filter_status,
      privilege = { root = true, via_sudo = true },
      layout = { visible = 3, total = 5 }, data_age = "2s" } end },
  { name = "search prompt + filter", build = function(m)
    return { message = m.search, filter = m.filter_status, warning = true } end },
  { name = "edit banner + layout overflow", build = function(m)
    return { message = m.edit, layout = { visible = 3, total = 5 }, warning = true } end },
  { name = "recovered backup + privilege", build = function(m)
    return { message = m.recovered, privilege = { root = true } } end },
  { name = "error only", build = function(m) return { error = m.locale_failed } end },
  { name = "error + filter + privilege", build = function(m)
    return { error = m.locale_failed, filter = m.filter_status,
      privilege = { root = true } } end },
  -- The three quiet states, which the price clauses below are about.
  { name = "filter only", build = function(m) return { filter = m.filter_status } end },
  { name = "data age only", build = function() return { data_age = "2s" } end },
  { name = "layout overflow only", build = function()
    return { data_age = "2s", layout = { visible = 3, total = 5 } } end },
}

local function render(columns, state, i18n)
  local grid = Grid.new(columns, 1, {
    default_style = theme:style("text.primary", "surface.base"), unicode = true,
  })
  StatusBar.render(grid, { x = 1, y = 1, width = columns, height = 1 }, state,
    { theme = theme, i18n = i18n, capabilities = capabilities })
  return strip(grid:row_text(1))
end

-- ---------------------------------------------------------------------------
-- The rule, and the price of it.
-- ---------------------------------------------------------------------------
local renders, checked, absent, partial = 0, 0, {}, 0
local context_lost = { filter = 0, layout = 0, filter_seen = 0, layout_seen = 0 }
local quiet_lost = { filter = 0, layout = 0, data_age = 0, quiet_renders = 0 }
local longest_message, longest_locale = 0, nil
local message_cases = 0
for _, case in ipairs(CASES) do
  local built = case.build(messages(assert(I18n.new({ locale = "en-US" }))))
  if (built.message or built.error) ~= nil then message_cases = message_cases + 1 end
end

for _, locale in ipairs(LOCALES) do
  local i18n = assert(I18n.new({ locale = locale }))
  local m = messages(i18n)
  for _, case in ipairs(CASES) do
    local state = case.build(m)
    local message = state.message or state.error
    local silent = message == nil
    local subject_cells = #strip(message or "")
    if subject_cells > longest_message then
      longest_message, longest_locale = subject_cells, locale
    end
    for columns = NARROWEST, WIDEST do
      local row = render(columns, state, i18n)
      renders = renders + 1
      if silent then
        quiet_lost.quiet_renders = quiet_lost.quiet_renders + 1
        if state.filter and row:find(strip(state.filter), 1, true) == nil then
          quiet_lost.filter = quiet_lost.filter + 1
        end
        if state.layout and row:find("3/5", 1, true) == nil then
          quiet_lost.layout = quiet_lost.layout + 1
        end
        if state.data_age and row:find(strip(state.data_age), 1, true) == nil then
          quiet_lost.data_age = quiet_lost.data_age + 1
        end
      else
        checked = checked + 1
        local seen = visible_prefix(row, message)
        if seen == 0 then
          absent[#absent + 1] = ("%s / %s at %d columns: a %d-cell message is not "
            .. "on the row at all: %q")
            :format(case.name, locale, columns, subject_cells, message)
        elseif seen < subject_cells then
          partial = partial + 1
        end
        if state.filter then
          context_lost.filter_seen = context_lost.filter_seen + 1
          if row:find(strip(state.filter), 1, true) == nil then
            context_lost.filter = context_lost.filter + 1
          end
        end
        if state.layout then
          context_lost.layout_seen = context_lost.layout_seen + 1
          if row:find("3/5", 1, true) == nil then
            context_lost.layout = context_lost.layout + 1
          end
        end
      end
    end
  end
end

require(#absent == 0,
  "the footer dropped a message or an error from the row entirely:\n    "
  .. table.concat(absent, "\n    "))

-- The price, held in the other direction.  An ordering that lets the message lead
-- must not also let a *quiet* row lose its status markers: there is nothing on a
-- quiet row for the context to yield to, so a loss here would be a change nobody
-- asked for and nothing else in this file would notice.
require(quiet_lost.data_age == 0,
  "the data age is missing from " .. quiet_lost.data_age .. " of "
  .. quiet_lost.quiet_renders .. " quiet renders, where it is the only thing on the "
  .. "right-hand side and there is nothing for it to yield to")
require(quiet_lost.filter == 0,
  "the filter is missing from " .. quiet_lost.filter .. " quiet renders, where it "
  .. "is the only thing on the right-hand side")
require(quiet_lost.layout == 0,
  "the layout count is missing from " .. quiet_lost.layout .. " quiet renders, "
  .. "where nothing competes with it")

-- Non-vacuity.  Every one of these has been the way a rule in this project was
-- satisfied by looking at nothing.
require(renders > 0, "no render was made, so the rule was applied to nothing")
require(checked > 0, "no render carried a message, so the rule was applied to nothing")
require(checked == (renders - quiet_lost.quiet_renders),
  "the quiet and the message-carrying renders do not add up: " .. checked .. " + "
  .. quiet_lost.quiet_renders .. " is not " .. renders)
require(checked == message_cases * #LOCALES * (WIDEST - NARROWEST + 1),
  message_cases .. " of the " .. #CASES .. " states carry a message, so the sweep "
  .. "should have produced " .. (message_cases * #LOCALES * (WIDEST - NARROWEST + 1))
  .. " message renders and produced " .. checked)
require(longest_message > 0 and longest_locale ~= nil,
  "no message was measured, so the rule is about an empty string")
require(context_lost.filter_seen > 0 and context_lost.layout_seen > 0,
  "no render put a filter or a layout count next to a message, so the price of "
  .. "the ordering is not being measured at all")
require(quiet_lost.quiet_renders > 0,
  "no quiet render was made, so the price clauses are applied to nothing")

-- The error marker, which is its own rule and was found by a mutation rather
-- than by a reading.  Dropping the "! " costs the message *less* -- it frees two
-- cells -- so the rule above does not object and the mutation passes, and an
-- error with no marker is a line that looks like any other line on the row.  No
-- test in the suite asserted it either: `metric.critical` is a theme token and
-- nothing checked the character next to the message.
local unmarked = {}
local errors_checked = 0
for _, locale in ipairs(LOCALES) do
  local i18n = assert(I18n.new({ locale = locale }))
  local m = messages(i18n)
  for _, case in ipairs(CASES) do
    local state = case.build(m)
    if state.error then
      for columns = NARROWEST, WIDEST do
        local row = render(columns, state, i18n)
        errors_checked = errors_checked + 1
        -- The marker and the error are both on the row, and the marker is not
        -- required to be *adjacent* to the error: the privilege marker sits
        -- between them, which is why the check is about order and not adjacency.
        local body = strip(state.error)
        local at_error = row:find(body:sub(1, 4), 1, true)
        local at_marker = row:find("!", 1, true)
        if at_error == nil or at_marker == nil or at_marker > at_error then
          unmarked[#unmarked + 1] = ("%s / %s at %d columns: the error carries no "
            .. "marker in front of it: %q"):format(case.name, locale, columns, state.error)
        end
      end
    end
  end
end
require(errors_checked > 0, "no error render was made, so the marker rule is "
  .. "applied to nothing")
require(#unmarked == 0,
  "an error on the footer with nothing to mark it as one:\n    "
  .. table.concat(unmarked, "\n    "))

-- The privilege marker's *place*, which has no clause anywhere and was found by a
-- mutation rather than by a reading.  The comment at the top of `status_bar.lua`
-- says the marker leads the message, because it is the two-cell fact that decides
-- how to read an error, and the two orderings do not look the same to a reader:
-- `root · Show the column…` puts the session in front of the thing it explains and
-- `Show the column… · root` does not.  Increment 109 moved the marker behind the
-- count on a quiet row, and while checking that move the mutation that puts it
-- behind the *message* passed every guard in the suite -- the message is still
-- present, the marker is still present, and the row is still a truthful row.  A
-- documented property with no clause is a property one refactor from being an
-- accident, and the state needed to ask it is already in `CASES`.
local misplaced, misplaced_checked = 0, 0
local misplaced_example = nil
for _, locale in ipairs(LOCALES) do
  local i18n = assert(I18n.new({ locale = locale }))
  local m = messages(i18n)
  for _, case in ipairs(CASES) do
    local state = case.build(m)
    local subject = state.message or state.error
    if state.privilege and subject then
      for columns = NARROWEST, WIDEST do
        local row = render(columns, state, i18n)
        misplaced_checked = misplaced_checked + 1
        -- Four cells of the subject rather than all of it: a catalogue that does
        -- not separate words with spaces is cut by bytes, and the marker's side of
        -- the comparison only needs to know where the subject starts.
        local at_marker = row:find(strip(state.privilege.via_sudo and "root/sudo"
          or "root"), 1, true)
        local at_subject = row:find(strip(subject):sub(1, 4), 1, true)
        if at_marker and at_subject and at_marker > at_subject then
          misplaced = misplaced + 1
          if not misplaced_example then
            misplaced_example = ("%s / %s at %d columns: the privilege marker follows "
              .. "the message it is there to explain: %q")
              :format(case.name, locale, columns, row)
          end
        end
      end
    end
  end
end
require(misplaced_checked > 0, "no render carried both a privilege marker and a "
  .. "message, so the order between them is being asked of nothing")
require(misplaced == 0, "the privilege marker is behind the message on "
  .. misplaced .. " of " .. misplaced_checked .. " renders:\n    "
  .. tostring(misplaced_example))

assert(#failures == 0,
  table.concat(failures, "\n  ") .. "\n  (" .. #failures
  .. " problem(s); they are reported together so a run that finds a defect "
  .. "explains all of it)")

io.write(string.format(
  "ok: footer message (%d states x %d widths x %d catalogues, %d renders with a "
  .. "message and none of them missing it, %d truncated, longest message %d cells "
  .. "in %s; the ordering's price: the filter goes in %d of %d and the layout "
  .. "count in %d of %d renders that carry a message, and in none of the %d "
  .. "quiet ones, and %d error renders all marked)\n",
  #CASES, WIDEST - NARROWEST + 1, #LOCALES, checked, partial,
  longest_message, longest_locale,
  context_lost.filter, context_lost.filter_seen,
  context_lost.layout, context_lost.layout_seen, quiet_lost.quiet_renders,
  errors_checked))
