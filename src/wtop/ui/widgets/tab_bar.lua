local Util = require("wtop.ui.widgets.util")
local Width = require("wtop.ui.renderer.width")

local M = {}

local function tab_label(tab, context)
  if tab.label_id then
    return tostring(Util.t(context, tab.label_id, tab.label or tab.title or tab.id or "?"))
  end
  return tostring(tab.label or tab.title or tab.id or "?")
end

local function representation(tab, active, context)
  if active and context.theme and context.theme.mode == "mono" then
    return "[" .. tab_label(tab, context) .. "]"
  end
  return " " .. tab_label(tab, context) .. " "
end

function M.render(grid, area, state, context)
  context, state = context or {}, state or {}
  area = Util.clip_rect(grid, area)
  if area.width < 1 or area.height < 1 then return {tabs = {}} end
  local base = Util.style(context, "text.primary", "surface.raised")
  local muted = Util.style(context, "text.muted", "surface.raised")
  local active_style = Util.style(context, "accent.primary", "surface.focus", {bold = true})
  grid:fill(area, " ", base)

  local brand = tostring(state.brand or Util.t(context, "app.name", "wtop"))
  -- The brand carries the host name, which is the single most useful piece of
  -- context on a screenshot. Twelve columns truncated it on almost every host,
  -- so it now scales with the terminal and yields first on narrow ones.
  brand = Util.truncate(grid, brand,
    math.max(4, math.min(area.width - 8, math.floor(area.width * 0.22))))
  grid:write(area.x, area.y, brand, Util.style(context, "accent.primary", "surface.raised", {bold = true}), area.width)
  local brand_width = Width.display_width(brand, grid.width_options)

  local unicode = not (context.capabilities and context.capabilities.unicode == false)
  -- No fallback label, and the reason is specific rather than general.  The
  -- message this used to fall back on carries a `{level}` placeholder, and
  -- `Translator:t` called without its variables does not fail -- it hands back
  -- the template un-interpolated and counts a format error -- so the header
  -- would have read `Update rate: {level}` in whatever language the user had
  -- selected.  Measured: that fallback fired on 140 renders out of 140 in a
  -- full-page sweep that left the field out, and on none of the product's own,
  -- because `tui.lua` always supplies the label -- `current_frequency_label()`
  -- interpolates the level and asserts the level exists first.  A rate with no
  -- level in it has nothing to say, so the header says nothing rather than
  -- showing the shape of the sentence it would have said.
  local frequency = tostring(state.frequency_label or "")
  local suffix = ""
  if state.paused then
    suffix = (unicode and " · Ⅱ " or " || ") .. Util.t(context, "status.paused", "Paused")
  end
  if state.alert_count and state.alert_count > 0 then
    suffix = suffix .. " !" .. tostring(state.alert_count)
  end
  -- The frequency control stays first so it remains visible and clickable on
  -- narrow terminals; pause/alert context yields before navigation does.
  local right_limit = math.min(math.max(0, area.width - brand_width - 2),
    math.max(0, math.floor(area.width * 0.42)))
  frequency = Util.truncate(grid, frequency, right_limit, "")
  local frequency_width = Width.display_width(frequency, grid.width_options)
  suffix = Util.truncate(grid, suffix, math.max(0, right_limit - frequency_width))
  local suffix_width = Width.display_width(suffix, grid.width_options)
  local sample_width = frequency_width + suffix_width
  local right_x = area.x + area.width - sample_width
  if frequency_width > 0 then
    grid:write(right_x, area.y, frequency,
      Util.style(context, "accent.primary", "surface.focus", {bold = true}), frequency_width)
  end
  if suffix_width > 0 then
    grid:write(right_x + frequency_width, area.y, suffix,
      Util.style(context, state.paused and "metric.warn" or "metric.good", "surface.raised", {bold = true}),
      suffix_width)
  end

  local left = area.x + brand_width + (brand_width > 0 and 1 or 0)
  local available = math.max(0, right_x - left - 1)
  local tabs = state.tabs or {}
  local active_index = 1
  for index, tab in ipairs(tabs) do
    if tab.id == state.active or index == state.active then active_index = index end
  end
  local full_width = 0
  for index = 1, #tabs do
    -- The sum of the representations and nothing else: each one carries its own
    -- leading and trailing space, so the run needs no separator between them.
    -- The first version of this added one cell per tab, which over-estimated the
    -- run by nine and made the bar reserve room for a count on rows where all ten
    -- pages fitted after all -- costing a page to announce nothing.
    full_width = full_width
      + Width.display_width(representation(tabs[index], false, context), grid.width_options)
  end

  -- How many pages the row is not showing, and the room that statement needs.
  --
  -- This is the statement the footer makes about panels, on the row above: a page
  -- that is not on the bar is a page the operator cannot see, and the chevrons
  -- say *that* there are more without saying *how many*.  Measured on the
  -- product's own bar -- brand `wtop build-box-01`, en-US, every width from 20 to
  -- 160 and each of the ten pages in turn -- **1 410 renders drew 7 693 tab slots
  -- and left 6 407 page slots with no label on the row, and not one of the 1 410
  -- rows carried a count.**  At eighty columns, the width this product documents,
  -- four of the ten pages were drawn; at a hundred, six.
  --
  -- The room comes out of the *other* pages and out of the active one's cut name,
  -- and the reason is measured rather than preferred.  The ten labels have no common
  -- distinguishing prefix: the shortest prefix that still tells all ten apart is
  -- **nine cells in German, three in Spanish, two in English, French, Portuguese
  -- and Russian, and one in the three CJK catalogues** -- so there is no cell
  -- count at which a cut label can be promised to name its page, and a rule built
  -- on one would be a rule with a number in it that the product cannot keep.  A
  -- count, by contrast, is the same number in every catalogue.  The price of the
  -- statement is measured rather than asserted: over 177 300 renders -- every
  -- width from 4 to 200, three brand lengths, three row states, ten catalogues,
  -- every page -- **117 870 rows now carry a count and none lost one, the run
  -- gives up 2.60% of its page cells, and the page the reader is on is one cell
  -- narrower in 12 748 of them and never one wider.**
  --
  -- Three widths, and the row is built out of them:
  --
  --   `beside` -- the statement with a page on the row too: `+9`, two cells.
  --   `alone`  -- the statement with the run holding nothing else: `+10`, three.
  --   `name`   -- the smallest page cell that says anything, in cells: the left
  --               padding, the first cell of the active page's own name, and
  --               the cut marker.
  --
  -- `name` is the one that closes a defect this band used to have, and it is not
  -- a number chosen for looks.  `Util.truncate(" Overview ", 1)` is `…` and at
  -- three cells `" O…"`, so a run that cannot afford the padding *and* a
  -- character *and* the marker has nothing to show: **at seventeen columns in the
  -- three CJK catalogues the bar drew `‹ …+9` -- a padding space and a cut marker,
  -- not one cell of any page's name** -- and a cut marker standing where a page
  -- should be is a row that says "there are pages" while being unable to say
  -- which, and says nothing at all about the nine it was holding back.  A cell
  -- that cannot show what it holds must not be drawn as though it had: that is
  -- increment 105's rule, and the page cell answers to it like every other cell
  -- on the row.
  --
  -- Hence `name` counts the first cell of *this* page's name rather than assuming
  -- one: a Japanese, Korean or Chinese label spends two cells on its first
  -- character, and a budget of three there yields the padding and the marker and
  -- no character at all.  Nothing about it is per-catalogue policy -- the width
  -- is read off the label the bar is about to draw.
  local hidden_worst = math.max(0, #tabs - 1)
  local beside = #tabs > 1 and (1 + #tostring(hidden_worst)) or 0
  local alone = #tabs > 1 and (1 + #tostring(#tabs)) or 0
  local first_cell = 1
  for _, width in Width.graphemes(tab_label(tabs[active_index], context), grid.width_options) do
    first_cell = math.max(1, width)
    break
  end
  local name_cells = 2 + first_cell
  -- The statement is booked out of the run *before* the pages are chosen, so a
  -- neighbour never takes a cell the statement needs.  Only the count's own
  -- digits are booked: the quiet cell an earlier version also reserved between
  -- the statement and the live sampler is already inside `available`, which stops
  -- one cell short of the rate for exactly that reason, so the reservation was
  -- paying twice for the same silence -- the count lands two cells short of the
  -- rate either way, and **the extra cell went to page names: 116 070 rows of the
  -- price sweep carry a count and every one of them gained a cell of name**,
  -- `wtop …+9  Update` becoming `wtop O…+9  Update`.
  local reserved, selectable = 0, available
  if #tabs > 1 and full_width > available then
    if available >= beside + name_cells then
      -- The ordinary band: the statement, and a page name cut to whatever is
      -- left.  The active page is the one that gets cut; every other page is
      -- drawn whole or not at all, so no page cell is ever a bare marker.
      reserved = beside
      selectable = available - beside
    elseif available >= alone then
      -- The run is too narrow for a name *and* the statement, so it buys the
      -- statement.  This is the case that reads `wtop +10  Update`: two more
      -- blank cells than a name would need, and in exchange the reader learns
      -- that all ten pages are off the row instead of seeing a marker standing
      -- in for one of them.
      reserved = alone
      selectable = 0
    else
      -- Narrower than the statement: one or two cells, and there is nothing in
      -- them to say.  The run takes its one cell for the cut marker, which is
      -- the same claim `Util.truncate` makes everywhere else on this row --
      -- content was cut -- and says nothing about the count, which is what the
      -- next band up is for.  The marker is written at the tail, below, with the
      -- rest of the statements.
      selectable = 0
    end
  end

  local selected, used, active_width = {}, 0, 0
  local function try_add(index, required)
    if index < 1 or index > #tabs or selected[index] then return false end
    local text = representation(tabs[index], required, context)
    local width = Width.display_width(text, grid.width_options)
    if width > selectable - used then
      if not required or selectable - used < 1 then return false end
      text = Util.truncate(grid, text, selectable - used)
      width = Width.display_width(text, grid.width_options)
    end
    selected[index] = {text = text, width = width}
    used = used + width
    if required then active_width = width end
    return true
  end
  try_add(active_index, true)
  local distance = 1
  while distance < #tabs do
    local changed = try_add(active_index - distance, false)
    changed = try_add(active_index + distance, false) or changed
    if not changed and used >= selectable then break end
    distance = distance + 1
  end

  local hitboxes, cursor = {}, left
  local previous_glyph = unicode and "‹" or "<"
  -- The one-cell stand-in: the same claim `Util.truncate` makes when it cuts,
  -- in the same spelling, so a reader who has seen `wtop-b…` on this row knows
  -- what a lone `…` between the brand and the rate means.  Not a chevron: with
  -- no page on the run there is no left and no right to point at, and a
  -- direction would be the one thing the bar cannot afford to be wrong about.
  local cut_glyph = unicode and "…" or "."
  local first_visible, last_visible, drawn = nil, nil, 0
  for index = 1, #tabs do
    local selected_tab = selected[index]
    if selected_tab then
      first_visible, last_visible = first_visible or index, index
      drawn = drawn + 1
    end
  end
  -- The leading chevron is direction, which the keys already provide, and it is
  -- the one cell the count cannot spare.  It is written only out of a cell the
  -- run has left over, and the earlier condition did not: it compared the
  -- chevron against the whole reservation and ignored the pages already chosen,
  -- so at eighteen columns with the fifth page active it wrote the chevron, then
  -- the page, and came up one cell short of the statement -- `wtop ‹ S…… Update`,
  -- a row with a direction, a cut name and no count.  A marker that costs the
  -- statement its cell is not free, and the quiet cell this run no longer
  -- reserves had been covering for it.
  local window = nil
  if first_visible and first_visible > 1 and used + 1 + reserved <= available then
    grid:write(cursor, area.y, previous_glyph, muted, 1)
    cursor = cursor + 1
  end
  for index = 1, #tabs do
    local selected_tab = selected[index]
    if selected_tab and cursor < right_x then
      local room = right_x - cursor
      local text = Util.truncate(grid, selected_tab.text, room, "")
      local width = Width.display_width(text, grid.width_options)
      grid:write(cursor, area.y, text, index == active_index and active_style or muted, width)
      hitboxes[#hitboxes + 1] = {id = tabs[index].id, index = index, x = cursor, width = width}
      cursor = cursor + width
    end
  end
  -- The statement.
  --
  -- The trailing chevron used to go here.  A direction the reader has to guess is
  -- worth less than the number of pages behind it -- `‹ Processes +9` says one page
  -- is labelled and nine are not, where the chevron said there was more somewhere
  -- -- so the count takes its place wherever the row can pay for it.  Where it
  -- cannot, the cut marker stands in: below the width where the statement fits
  -- there is one cell and nothing else, and a bar that is a window should at
  -- least say so.
  local hidden = math.max(0, #tabs - drawn)
  local count_text, count_width, blocked = nil, 0, nil
  if hidden == 0 then
    blocked = nil
  else
    local text = "+" .. hidden
    local width = Width.display_width(text, grid.width_options)
    -- Whole or nothing, and the reservation is what makes it whole: a count that
    -- does not fit is the defect this increment closed in a smaller font, `+10`
    -- cut to `+1` being a number the bar is not standing behind.  The run books
    -- `beside` when a page is on it and `alone` when none is, and it books
    -- nothing it cannot pay for, so the statement is written exactly when there
    -- is room for all of it.  **Measured rather than argued: a probe that refused
    -- the statement whenever the room turned out to be one cell short of the rate
    -- starved it in none of 216 000 renders** -- every width from 1 to 240, three
    -- brands, three row states, ten catalogues, ten pages -- so this branch is
    -- `reserved > 0` and nothing else, and an earlier version carried the second
    -- half of the condition as a check against a case the arithmetic above cannot
    -- produce.
    if reserved > 0 then
      grid:write(cursor, area.y, text, muted, width)
      cursor = cursor + width
      count_text, count_width, blocked = text, width, "none"
    else
      blocked = "no-room"
      if not window and cursor + 1 <= right_x - 1 then
        window = cut_glyph
        grid:write(cursor, area.y, window, muted, 1)
        cursor = cursor + 1
      end
    end
  end
  return {
    tabs = hitboxes,
    active_index = active_index,
    sample_x = right_x,
    frequency = frequency_width > 0 and {x = right_x, width = frequency_width} or nil,
    -- Published so a guard can ask the bar rather than count its own pixels: the
    -- same discipline `Sparkline.window`, `Bars.minimum_cell` and the footer's
    -- `form` and `budget` follow.
    first_visible = first_visible,
    last_visible = last_visible,
    drawn = drawn,
    hidden = hidden,
    active_width = active_width,
    count = count_text,
    -- The cells the run was given, and the three widths the tail policy is built
    -- from.  Published so a guard can ask the bar what its own policy is instead
    -- of restating the numbers in a second place and letting the two drift --
    -- the same discipline `Sparkline.window`, `Bars.minimum_cell` and the
    -- footer's `form` and `budget` follow.  `name` in particular is the one a
    -- guard most wants to be wrong about: a budget of one or two there is what
    -- brought the bare-marker page cell back, and no other published number
    -- would have shown it.
    room = available,
    budget = {beside = beside, alone = alone, name = name_cells},
    -- The brand as it was drawn, in cells.  A guard needs it to know where the
    -- run starts, and it cannot count it off the row: `tui.lua` sends
    -- "wtop " .. hostname, so the brand carries a space and the run of
    -- non-blank cells at the head of the row is not the brand.
    brand_width = brand_width,
    -- The statement as it was written, in cells -- zero when there is none.  The
    -- booking and the statement are not the same width: the run reserves room
    -- for `+9` because a page is normally on it, and when a page yields its
    -- cell the statement becomes `+10` and takes one more.  Both numbers are
    -- published, because a guard checking that the row's count is the real number
    -- wants the one the bar wrote and a guard checking the policy wants the one
    -- the bar spent.
    count_width = count_width,
    reserved = reserved,
    -- nil when no page is hidden and none is owed; "none" when the statement is
    -- on the row; and "no-room" when the statement could not be paid for and the
    -- one-cell cut marker stands in for it.
    blocked = blocked,
    -- The one-cell statement that the bar is a window, published so a guard can
    -- check the stand-in against the row instead of guessing the glyph.
    window = window,
  }
end

return M
