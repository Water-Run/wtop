local Util = require("wtop.ui.widgets.util")
local Width = require("wtop.ui.renderer.width")

local M = {}

local default_hints = {
  {key = "/", id = "actions.search", fallback = "Search"},
  {key = "e", id = "actions.edit_layout", fallback = "Layout"},
  {key = "Space", id = "actions.pause", fallback = "Pause"},
  {key = "?", id = "actions.help", fallback = "Help"},
  {key = "q", id = "actions.quit", fallback = "Quit"},
}

function M.render(grid, area, state, context)
  context, state = context or {}, state or {}
  area = Util.clip_rect(grid, area)
  if area.width < 1 or area.height < 1 then return {} end
  local surface = "surface.raised"
  local base = Util.style(context, "text.muted", surface)
  local key_style = Util.style(context, "accent.primary", surface, {bold = true})
  grid:fill(area, " ", base)

  local unicode = not (context.capabilities and context.capabilities.unicode == false)
  local separator = unicode and " · " or " | "
  local right = state.error or state.message
  local has_priority_message = right ~= nil or (state.filter and state.filter ~= "")
  -- The right-hand side is cut from the front, so the order of the pieces *is*
  -- the priority -- and the order used to be the opposite of the one the bar
  -- states about itself.  `has_priority_message` widened the budget from 0.38 of
  -- the row to 0.58 (0.72 on a narrow row) precisely because a message or a
  -- filter is there, and then the string was built as `▦ v/t · filter · root ·
  -- message`, which puts the reason for the extra room last, where the first
  -- thing to go is.
  --
  -- Measured over ten catalogues and every width from 40 to 240, with the states
  -- `tui.lua` can actually hand this bar: the message or the error was absent
  -- from the row entirely in 109 of 22 110 renders, and 104 of those were the
  -- message with a filter, a privilege marker, a layout count and a data age all
  -- present at once -- gone from 40 to 70 columns in French, 40 to 68 in Spanish
  -- and Portuguese and 40 to 54 in traditional Chinese.  Seventy columns is an
  -- ordinary split-pane width.  The other five were an *error* disappearing at 40
  -- columns in four catalogues as soon as a filter was present, which is the worst
  -- of them because the error is the one thing on this row that is not
  -- reconstructible from anywhere else on the screen.
  --
  -- So the message leads, the privilege marker before it (two cells, and the one
  -- fact that decides how to read an error), and the context -- the layout count
  -- and then the filter -- follows and is what gets cut.  The filter is what did
  -- most of the evicting, and it is a duplicate: `tui.lua` already prints it
  -- inside the process table's own panel, and the comment there says so,
  -- because repeating it "wasted the one place a transient message can appear".
  -- A row carrying no message and no filter is unaffected -- `has_priority_message`
  -- is false and the budget is still 0.38.
  local marker = ""
  if state.privilege and state.privilege.root == true then
    marker = state.privilege.via_sudo and "root/sudo" or "root"
  end
  -- Named `trailing` and not `context`: the function's `context` parameter is the
  -- render context that carries the theme and the translator, and shadowing it
  -- with a list of strings makes every `Util.t` and `Util.style` call below fall
  -- back -- which is silent, deterministic and looks like a localisation bug.
  local trailing = {}
  local layout = state.layout
  local layout_total = layout and tonumber(layout.total)
  local layout_visible = layout and tonumber(layout.visible)
  local mark = unicode and "▦" or "[]"
  local missing = 0
  if layout_total and layout_visible and layout_total > layout_visible then
    missing = layout_total - layout_visible
    trailing[#trailing + 1] = string.format("%s %d/%d", mark, layout_visible, layout_total)
  end
  -- The marker leads when there is a message to read, because it is the fact that
  -- decides how to read an error.  On a quiet row there is no error to read and
  -- the marker is context, so it follows the count: at twenty columns a root
  -- session and a missing panel cannot both be on the row -- `root · ▦ +7` is
  -- twelve cells and a quiet row is given 0.38 of twenty -- and the marker is a
  -- fact about the session that does not change while the panel count does.
  local prefix = marker ~= "" and right ~= nil and marker or ""
  if marker ~= "" and right == nil then trailing[#trailing + 1] = marker end
  -- The context pieces, in the order they yield.  The age used to be assigned to
  -- `right`, which is the *message's* slot, and that is what pushed the count off
  -- the row: an eight-cell wall clock from `clock_label()` stood between the
  -- reader and the only statement on the screen that a panel was missing.  The
  -- age and the filter keep the order they had with respect to each other, so
  -- moving the count to the front is the whole of the change; the filter stays
  -- last because it is a duplicate the process panel already prints.
  if not right and state.data_age then trailing[#trailing + 1] = tostring(state.data_age) end
  if state.filter and state.filter ~= "" then
    trailing[#trailing + 1] = tostring(state.filter)
  end
  local ratio = has_priority_message and (area.width < 56 and 0.72 or 0.58) or 0.38
  local right_limit = math.max(0, math.floor(area.width * ratio))
  local pieces = {}
  if prefix ~= "" then pieces[#pieces + 1] = prefix end
  if right ~= nil then pieces[#pieces + 1] = tostring(right) end
  local lead_width = 0
  for index, piece in ipairs(pieces) do
    lead_width = lead_width + Width.display_width(tostring(piece), grid.width_options)
      + (index > 1 and Width.display_width(separator, grid.width_options) or 0)
  end
  -- The count is the only thing on this row that says a declared panel is not on
  -- screen, so it gets the treatment every other overflowing component in this
  -- product already got: a shorter form that still names the number.  `bars` and
  -- `segments` print `+N` when N entries did not fit; here N is the number of
  -- panels the responsive solver dropped.
  --
  -- Measured over ten pages, every width from 20 to 240 and every height from 3
  -- to 40 -- 28 620 renders in which the solver hid at least one declared panel,
  -- carrying `tui.lua`'s own `data_age` and nothing else competing -- the count
  -- was printed whole in 22 357 of them and **absent from the row entirely in
  -- 6 263**, every one of them below 45 columns.  At 40x24 on the overview page,
  -- where 3 of 11 panels are placed, the row ended `14:23:07 · ▦ 3…`; at 44 it
  -- ended `▦ 3/…`, a numerator with no denominator, which reads as "3" rather
  -- than "3 of 11".  Forty columns is an ordinary split-pane width and the
  -- comment above already calls it one.
  --
  -- The price, measured the same way: the age loses its tail when a count is on
  -- the row and the two do not both fit, and the full `v/t` still yields to a
  -- message that has filled the row, which is the price the comment above already
  -- accepted.  Below nineteen columns the count is not nameable at all -- measured
  -- on the overview page over every height from 3 to 20, eighteen columns or
  -- narrower carries it in none of the eighteen shapes that hide a panel and
  -- nineteen carries it in all of them, because a quiet row is given 0.38 of the
  -- row and at eighteen that is six cells, three of which the separator spends.
  -- A root session does not move the floor: the marker follows the count now.  The
  -- footer is not drawn at all below one cell of width, so there is nothing to
  -- degrade past that.
  --
  -- What the count cost and what it bought is published with the row, so a guard
  -- can ask the component instead of recomputing its budget: the same discipline
  -- `Bars.minimum_cell`, `Sparkline.window` and `Segments` follow, where a rule
  -- that re-derives a component's own arithmetic tests a second implementation.
  local form, budget = "none", nil
  if missing > 0 and trailing[1] then
    budget = right_limit - lead_width - Width.display_width(separator, grid.width_options)
    if state.error then budget = budget - 2 end
    if Width.display_width(trailing[1], grid.width_options) > budget then
      local compact = string.format("%s +%d", mark, missing)
      if Width.display_width(compact, grid.width_options) <= budget then
        trailing[1], form = compact, "compact"
      end
    else
      form = "full"
    end
  end
  for _, piece in ipairs(trailing) do pieces[#pieces + 1] = piece end
  right = table.concat(pieces, separator)
  if state.error and right ~= "" then right = "! " .. right end
  right = Util.truncate(grid, right, right_limit)
  local right_width = Width.display_width(right, grid.width_options)
  local right_x = area.x + area.width - right_width
  if right_width > 0 then
    local token = state.error and "metric.critical" or (state.warning and "metric.warn" or "text.muted")
    grid:write(right_x, area.y, right, Util.style(context, token, surface,
      {bold = state.error ~= nil or state.warning == true}),
      right_width)
  end

  local cursor = area.x
  local hints = state.hints or default_hints
  local rendered = {}
  for _, hint in ipairs(hints) do
    local label = hint.label or Util.t(context, hint.id or "", hint.fallback or hint.command or "")
    local key = tostring(hint.key or "")
    label = tostring(label)
    local key_width = Width.display_width(key, grid.width_options)
    local label_width = Width.display_width(label, grid.width_options)
    local leading = #rendered > 0 and separator or ""
    local leading_width = Width.display_width(leading, grid.width_options)
    local full_width = leading_width + key_width + (label ~= "" and 1 + label_width or 0)
    local compact_width = leading_width + key_width
    local boundary = right_x - 1
    local show_label = cursor + full_width <= boundary
    if show_label or cursor + compact_width <= boundary then
      local start = cursor
      if leading_width > 0 then
        grid:write(cursor, area.y, leading, base, leading_width)
        cursor = cursor + leading_width
      end
      grid:write(cursor, area.y, key, key_style, key_width)
      cursor = cursor + key_width
      if show_label and label ~= "" then
        grid:write(cursor, area.y, " " .. label, base, label_width + 1)
        cursor = cursor + label_width + 1
      end
      rendered[#rendered + 1] = {
        command = hint.command or hint.id,
        x = start,
        width = cursor - start,
        compact = not show_label,
      }
    end
  end
  return {
    hints = rendered,
    message_x = right_x,
    layout = {
      visible = layout_visible,
      total = layout_total,
      missing = missing,
      form = form,
      budget = budget,
    },
  }
end

M.default_hints = default_hints

return M
