-- Layout editing can add, remove and replace widgets.  The palette is the
-- page's own widget list, every change is undoable, focus never dangles, and
-- the refusals are reported with codes the status line can translate.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Workspace = require("wtop.workspace")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Technical = require("wtop.i18n.technical")

-- Each scenario gets its own workspace: the behaviour under test is a single
-- edit, and sharing one workspace across scenarios made the expectations
-- depend on whatever the previous scenario happened to leave behind.
local function memory_page()
  return Workspace.new({ active_tab = "memory" })
end

local function order(workspace)
  return table.concat(workspace:orders().memory, ",")
end

local function slot_of(workspace, widget_id)
  for index, id in ipairs(workspace:orders().memory) do
    if id == widget_id then return index end
  end
end

-- The palette is the page's widgets minus what the tree holds, and its size is
-- always that difference.
local function assert_palette_consistent(workspace)
  local expected = #workspace.widget_orders.memory - #workspace:orders().memory
  assert(#workspace:palette() == expected,
    string.format("palette holds %d entries, expected %d (%s)",
      #workspace:palette(), expected, order(workspace)))
end

-- The default layout places every widget the page defines.
local default_order = order(memory_page())
assert(default_order == "memory_total,memory_segments,memory_detail,swap_detail,"
  .. "memory_pressure,memory_counters")
assert(#memory_page():palette() == 0,
  "the default layout leaves nothing in the palette")

-- Remove takes a widget out of the layout and leaves it in the palette.
do
  local workspace = memory_page()
  workspace.focus.memory = "memory_detail"
  local title = workspace.widgets.memory.memory_detail.panel_title
  assert(workspace:remove_focused_widget())
  assert(order(workspace) == "memory_total,memory_segments,swap_detail,"
    .. "memory_pressure,memory_counters", "got " .. order(workspace))
  assert(workspace.focus.memory == "swap_detail",
    "focus falls to the widget that inherited the slot, got "
      .. tostring(workspace.focus.memory))
  local palette = workspace:palette()
  assert(#palette == 1 and palette[1].id == "memory_detail")
  assert(palette[1].title == title and palette[1].kind == "key_value",
    "palette entries carry the title and kind the picker renders")
  assert_palette_consistent(workspace)
end

-- Add places a widget directly after the focused one and focuses what it put
-- there, so add-then-resize is one flow.
do
  local workspace = memory_page()
  workspace.focus.memory = "memory_detail"
  workspace:remove_focused_widget()
  local holder = workspace.focus.memory
  assert(workspace:add_focused_widget("memory_detail", "after"))
  assert(workspace.focus.memory == "memory_detail",
    "add focuses the widget it placed, got " .. tostring(workspace.focus.memory))
  assert(slot_of(workspace, "memory_detail") == slot_of(workspace, holder) + 1,
    "add after lands directly after the focused widget")
  assert_palette_consistent(workspace)
end

-- The requested side is honoured.
do
  local workspace = memory_page()
  workspace.focus.memory = "memory_detail"
  workspace:remove_focused_widget()
  local holder = workspace.focus.memory
  assert(workspace:add_focused_widget("memory_detail", "before"))
  assert(slot_of(workspace, "memory_detail") == slot_of(workspace, holder) - 1,
    "add before lands directly before the focused widget")
  assert_palette_consistent(workspace)
end

-- Replace holds the removed widget's slot instead of sliding to the end.
do
  local workspace = memory_page()
  workspace.focus.memory = "memory_segments"
  workspace:remove_focused_widget()
  local before = order(workspace)
  local empty_slot = slot_of(workspace, workspace.focus.memory)
  local replacement = workspace:palette()[1].id
  assert(replacement == "memory_segments")
  assert(workspace:replace_focused_widget(replacement))
  assert(workspace.focus.memory == replacement,
    "replace focuses the replacement, got " .. tostring(workspace.focus.memory))
  assert(slot_of(workspace, replacement) == empty_slot,
    string.format("the replacement must hold slot %d but landed at %d",
      empty_slot, slot_of(workspace, replacement)))
  assert(order(workspace) ~= before, "replace actually changed the layout")
  local returned
  for _, item in ipairs(workspace:palette()) do
    if item.id == "memory_detail" then returned = true end
  end
  assert(returned, "the replaced-away widget returns to the palette")
  assert_palette_consistent(workspace)
  assert(workspace:undo())
  assert(order(workspace) == before, "undo reverses the replacement, got " .. order(workspace))
  assert(workspace:redo())
  assert_palette_consistent(workspace)
end

-- Focus must never point at a widget that is not in the tree: adding focuses
-- the new widget, and undoing that insert takes it away again.
do
  local workspace = memory_page()
  workspace.focus.memory = "memory_detail"
  workspace:remove_focused_widget()
  workspace:add_focused_widget("memory_detail", "after")
  local dangling = workspace.focus.memory
  assert(workspace:undo())
  assert(workspace.focus.memory ~= dangling,
    "undo must re-anchor focus; it still points at " .. tostring(dangling))
  assert(slot_of(workspace, workspace.focus.memory) ~= nil,
    "the re-anchored focus points at a placed widget")
  assert(workspace:remove_focused_widget(),
    "the edit keys still work on a re-anchored focus")
end

-- A page keeps at least one widget, and the refusal is a translatable code.
do
  local workspace = Workspace.new({ active_tab = "gpu" })
  local total = #workspace.widget_orders.gpu
  assert(total > 1, "the scenario needs a page with more than one widget")
  for step = 1, total - 1 do
    local removed, reason = workspace:remove_focused_widget()
    assert(removed, "removal works while widgets remain, step " .. step .. ": " .. tostring(reason))
  end
  assert(#workspace:orders().gpu == 1,
    "removal stops with one widget left, got " .. #workspace:orders().gpu)
  assert(#workspace:palette() == total - 1, "the rest wait in the palette")
  local _, reason = workspace:remove_focused_widget()
  assert(reason == "cannot_remove_last_widget",
    "the final widget is protected, got " .. tostring(reason))
  assert(#workspace:orders().gpu == 1, "a refused removal leaves the layout alone")
  while workspace:undo() do end
  assert(#workspace:orders().gpu == total,
    "undo walks back to the full default layout")
end

-- Refusals carry codes the status line can translate, not raw model strings.
do
  local workspace = memory_page()
  workspace.focus.memory = "memory_total"
  local _, duplicate = workspace:add_focused_widget("memory_total")
  assert(duplicate == "widget_already_placed",
    "adding a placed widget reports widget_already_placed, got " .. tostring(duplicate))
  local _, ghost = workspace:add_focused_widget("not_a_widget")
  assert(ghost == "widget_not_in_page",
    "adding an unknown widget reports widget_not_in_page, got " .. tostring(ghost))
  local _, same = workspace:replace_focused_widget("memory_total")
  assert(same == "widget_already_placed",
    "replacing a widget with itself reports widget_already_placed, got " .. tostring(same))
  assert(order(workspace) == default_order, "no refusal changed the layout")
end

-- The picker renders the palette with a selection marker, and says so when the
-- palette is empty rather than showing a blank panel.
do
  local translator = assert(I18n.new({ locale = "en-US" }))
  local items = { { id = "memory_total", title = "Memory utilization", kind = "metric" },
    { id = "swap_detail", title = "Swap", kind = "key_value" } }
  local function joined(lines) return table.concat(lines, "\n") end

  local add_lines = TUI.widget_picker_lines("add", items, 2, translator, true)
  assert(add_lines[1] == "Add widget", "the add picker is titled, got " .. add_lines[1])
  assert(joined(add_lines):find("Memory utilization", 1, true))
  assert(joined(add_lines):find("Swap", 1, true))
  assert(joined(add_lines):find("Up/Down selects", 1, true),
    "the picker states how it is driven")
  assert(add_lines[5] == "  Memory utilization  Metric",
    "an unselected entry is unmarked, got [" .. add_lines[5] .. "]")
  assert(add_lines[6] == "▸ Swap  Detail",
    "the selected entry is marked and labelled, got [" .. add_lines[6] .. "]")

  local replace_lines = TUI.widget_picker_lines("replace", items, 1, translator, true)
  assert(replace_lines[1] == "Replace widget", "the replace picker is titled")
  assert(replace_lines[5] == "▸ Memory utilization  Metric")

  local ascii_lines = TUI.widget_picker_lines("add", items, 1, translator, false)
  assert(ascii_lines[5] == "> Memory utilization  Metric",
    "an ASCII terminal gets a plain marker, got [" .. ascii_lines[5] .. "]")

  local empty_lines = TUI.widget_picker_lines("add", {}, 1, translator, true)
  assert(joined(empty_lines):find("no further widgets", 1, true),
    "an exhausted palette says so instead of showing an empty list")
end

-- The picker and the refusals are translated for the display locale.
do
  local zh = assert(I18n.new({ locale = "zh-CN" }))
  local lines = TUI.widget_picker_lines("add",
    { { id = "memory_total", title = "内存使用率", kind = "metric" } }, 1, zh, true)
  assert(lines[1] == "添加组件", "the picker title is translated, got " .. lines[1])
  assert(Technical.reason(zh, "widget_not_in_page") == "该组件不在此页面上",
    "the refusal reason is translated, got " .. tostring(Technical.reason(zh, "widget_not_in_page")))
  assert(Technical.reason(zh, "widget_already_placed") == "该组件已在布局中")
  assert(Technical.reason(zh, "cannot_remove_last_widget") == "页面至少要保留一个组件")
  assert(Technical.reason(zh, "layout_rejected") == "布局拒绝了该更改")
end

print("ok: layout add/remove/replace widgets (palette, focus, undo, refusals, picker)")
return true
