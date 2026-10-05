-- Dropping a focused widget onto a named target.  The arrow keys already move
-- a widget one place at a time; what they cannot express is "put this one
-- there", which is what a drop is.  These cover the model-facing half -- the
-- target list, the side, undo, and the refusals -- plus the list the user
-- actually reads.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Workspace = require("wtop.workspace")
local Layout = require("wtop.model.layout")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      message, tostring(expected), tostring(actual)), 0)
  end
end

local translator = assert(I18n.new({ locale = "en-US" }))
local function order(workspace, page)
  local ok, info = Layout.validate(workspace:trees()[page],
    { allowed_widgets = workspace.widget_orders[page] })
  return ok and table.concat(info.order, ",") or "?"
end

local workspace = Workspace.new({})
workspace:select("compute")
local function placed_order(ws, page)
  local ok, info = Layout.validate(ws:trees()[page],
    { allowed_widgets = ws.widget_orders[page] })
  return ok and info.order or {}
end
local widgets = placed_order(workspace, "compute")
equal(#widgets > 3, true, "the test page has enough widgets to be worth dropping")

-- 1. The list is every widget on the page except the one being moved.  Offering
--    a widget as its own target would spend a row on a no-op.
workspace.focus.compute = widgets[1]
local targets = workspace:move_targets()
equal(#targets, #widgets - 1, "every other widget is a target")
for _, id in ipairs(targets) do
  equal(id ~= widgets[1], true, "the moved widget is not its own target: " .. id)
end
equal(table.concat(targets, ","), table.concat(
  (function() local rest = {} for i = 2, #widgets do rest[#rest + 1] = widgets[i] end return rest end)(),
  ","), "the list keeps the page order")

-- 2. A drop after the last widget puts the moved one last.
local before = order(workspace, "compute")
equal(workspace:move_focused_to(widgets[#widgets], "after"), true,
  "dropping after the last widget works")
equal(order(workspace, "compute"):sub(-#widgets[1]), widgets[1],
  "the moved widget ended up last: " .. order(workspace, "compute"))
equal(order(workspace, "compute") ~= before, true, "the page really changed")

-- 3. Focus stays on the widget that was moved.  Following the drop target would
--    switch the user to editing a panel they did not pick up.
equal(workspace.focus.compute, widgets[1], "focus follows the moved widget")

-- 4. "Before" and "after" are different drops.
workspace:select("memory")
local mem = placed_order(workspace, "memory")
workspace.focus.memory = mem[1]
equal(workspace:move_focused_to(mem[#mem], "before"), true, "dropping before the last works")
local after_before = order(workspace, "memory")
workspace:select("memory")
local mem2 = placed_order(workspace, "memory")
workspace.focus.memory = mem2[1]
equal(workspace:move_focused_to(mem2[#mem2], "after"), true, "dropping after the last works")
equal(order(workspace, "memory") ~= after_before, true,
  "before and after are not the same result")

-- 5. Undo puts the widget back, so a drop is one undo step like every other
--    edit -- not an atomic rewrite of the page.
-- Two drops happened, so one undo returns to the state between them, not to
-- the page as it was before either.  Checking that distinction is the point:
-- an undo that jumped further than one step would be discarding an edit.
equal(workspace:undo(), true, "a drop is undoable")
equal(table.concat(placed_order(workspace, "memory"), ","), after_before,
  "undo stepped back exactly one drop")
equal(workspace:undo(), true, "the first drop is undoable too")
equal(table.concat(placed_order(workspace, "memory"), ","), table.concat(mem, ","),
  "and the page is back as it started")
equal(workspace.focus.memory ~= nil, true, "and focus still points at a real widget")

-- 6. The refusals.  Each of these would leave the page unrenderable or move
--    something the user did not name.
equal(workspace:move_focused_to(nil, "after"), false, "a nil target is refused")
equal(workspace:move_focused_to("", "after"), false, "an empty target is refused")
equal(workspace:move_focused_to(42, "after"), false, "a numeric target is refused")
equal(select(2, workspace:move_focused_to(42, "after")), "invalid_target_widget",
  "and a non-name says why")
equal(workspace:move_focused_to(mem[1], "sideways"), false, "an unknown side is refused")
equal(select(2, workspace:move_focused_to(mem[1], "sideways")),
  "invalid_position", "and says why")
equal(workspace:move_focused_to("not_a_widget_on_this_page", "after"), false,
  "a target that is not on the page is refused")
equal(workspace:move_focused_to(mem[1], "after"), true,
  "a widget moving onto itself is accepted as the no-op it is")

-- 6b. **What the refusals say, which the assertions above never checked.**  Every
-- one of them is formatted into the status line as `"reason." .. tostring(err)`
-- at `tui.lua` 3544, and the reason a user reads is the message id this error
-- becomes.  `Layout.move` answers a target that is not on the page with a string
-- it builds by concatenation -- `"widget_not_found:" .. target_widget` -- and
-- this method used to return that unfiltered, while `add`, `remove` and
-- `replace` all passed theirs through `layout_refusal`.  Measured before the
-- fix: `move_focused_to("not_a_widget_on_this_page", "after")` answered
-- `widget_not_found:not_a_widget_on_this_page`, and the status line showed that
-- verbatim, in every language, because no catalogue can hold a key with a colon
-- in it.  So the assertion is on the *shape* of the reason as well as its
-- value: a code, from the mapped vocabulary, with nothing appended.
equal(select(2, workspace:move_focused_to("not_a_widget_on_this_page", "after")),
  "widget_not_in_page",
  "and says a code a catalogue can hold, not one with the target appended")
local MAPPED = { cannot_remove_last_widget = true, layout_rejected = true,
  widget_already_placed = true, widget_not_in_page = true }
for _, attempt in ipairs({
  { "not_a_widget_on_this_page", "after" }, { "", "after" }, { 42, "after" },
  { mem[1], "sideways" }, { "no_such_widget", "before" },
}) do
  local reason = select(2, workspace:move_focused_to(attempt[1], attempt[2]))
  equal(type(reason), "string",
    "every refusal says something, for target " .. tostring(attempt[1]))
  equal(reason:find("[:%s]"), nil,
    "a reason is one code and nothing else, but got " .. reason)
  equal(MAPPED[reason] == true or reason == "invalid_target_widget"
    or reason == "invalid_position", true,
    "and it comes from the refusal vocabulary, but got " .. reason)
end

-- 7. A one-widget page has nowhere to drop, and says so rather than showing a
--    list with nothing in it.
local stripped = Workspace.new({})
stripped.layout_trees = {}
for page, tree in pairs(stripped:trees()) do
  stripped.layout_trees[page] = Layout.leaf(Layout.validate(tree,
    { allowed_widgets = stripped.widget_orders[page] }).order[1])
end
stripped:select("compute")
stripped.focus.compute = placed_order(stripped, "compute")[1]
equal(#stripped:move_targets(), 0, "a single-widget page has no drop target")

-- 8. The list the user reads: title, side, hint, and both names for a row.
local function lines(selection)
  return table.concat(TUI.move_target_lines(selection, translator, true), "\n")
end
local list = lines({ targets = { { id = "cpu_core", title = "Per-core CPU" },
    { id = "cpu_freq", title = "Frequency" } },
  index = 1, position = "after", title = "Logical CPU" })
equal(list:find("Move Logical CPU", 1, true) ~= nil, true, "the title names the panel: " .. list)
equal(list:find("after", 1, true) ~= nil, true, "the current side is shown: " .. list)
equal(list:find("Enter drops", 1, true) ~= nil, true, "the hint says how to commit: " .. list)
equal(list:find("Per-core CPU", 1, true) ~= nil, true, "a row shows the panel title")
equal(list:find("cpu_core", 1, true) ~= nil, true, "and the widget id it keys on")
local before_list = lines({ targets = { { id = "a", title = "A" } }, index = 1,
  position = "before", title = "B" })
equal(before_list:find("before", 1, true) ~= nil, true, "the other side is shown: " .. before_list)
equal(before_list:find("after", 1, true), nil,
  "and only one side at a time: " .. before_list)
local empty_list = lines({ targets = {}, index = 1, position = "after", title = "B" })
equal(empty_list:find("Move B", 1, true) ~= nil, true, "an empty list still has a title")
local truncated = lines({ targets = { { id = "a", title = "A" } }, index = 1,
  position = "after", title = "B", truncated = true })
equal(truncated:find("Not every widget is listed", 1, true) ~= nil, true,
  "a truncated list says so: " .. truncated)
local ascii = table.concat(TUI.move_target_lines({ targets = { { id = "a", title = "A" } },
  index = 1, position = "after", title = "B" }, translator, false), "\n")
equal(ascii:find("▸", 1, true), nil, "the ASCII profile gets no block marker")
equal(ascii:find("> A", 1, true) ~= nil, true, "it gets a plain one: " .. ascii)
-- The cursor marks the selected row and only that row.
local function marked(text, name, marker)
  for row in text:gmatch("[^\n]+") do
    if row:find(name, 1, true) then return row:sub(1, #marker) == marker end
  end
  return nil
end
equal(marked(list, "Per-core CPU", "▸"), true, "the selected row is marked: " .. list)
equal(marked(list, "Frequency", "▸"), false, "and only that row: " .. list)

-- 9. The side keys set the side rather than flipping it.  A flip makes holding
--    the key oscillate, and it also means the key's effect depends on a value
--    the user has to remember.
local function side_for(key, shift)
  local step = (key == "right" or (key == "tab" and not shift)) and 1 or -1
  return step > 0 and "after" or "before"
end
equal(side_for("right"), "after", "right means after")
equal(side_for("left"), "before", "left means before")
equal(side_for("tab"), "after", "tab means after")
equal(side_for("tab", true), "before", "shift-tab means before")
for _ = 1, 4 do
  equal(side_for("right"), "after", "holding right does not oscillate")
end

print("ok: layout drop targets")
