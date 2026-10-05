-- Named layout workspaces: several arrangements, one live at a time.
-- A workspace is a name plus a complete set of per-page trees, so switching
-- has to restore every page at once and must not leave an undo history that
-- points at a tree which no longer exists.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Store = require("wtop.layout_store")
local Workspace = require("wtop.workspace")
local Layout = require("wtop.model.layout")

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      message, tostring(expected), tostring(actual)), 0)
  end
end

local DEFAULTS = {
  overview = { "cpu_overview", "memory_overview" },
  gpu = { "gpu_utilization", "gpu_table" },
}

local function page_tree(first, second, ratio)
  return {
    type = "split", axis = "horizontal", ratio = ratio or 0.5, gap = 1,
    children = {
      { type = "leaf", widget_id = first },
      { type = "leaf", widget_id = second },
    },
  }
end

local function order_of(workspace, page)
  local ok, info = Layout.validate(workspace:trees()[page],
    { allowed_widgets = workspace.widget_orders[page] })
  return ok and table.concat(info.order, ",") or "?"
end

-- A real session lays out every tab the build defines, so the assertions below
-- compare each page against the same page before the edit rather than against
-- a fixed widget list.  That is what "the arrangement came back" means.
local function capture(workspace, page)
  local result = {}
  for id, tree in pairs(workspace:trees()) do
    result[id] = Layout.validate(tree, { allowed_widgets = workspace.widget_orders[id] })
      and table.concat((select(2, Layout.validate(tree,
        { allowed_widgets = workspace.widget_orders[id] })).order), ",") or "?"
  end
  return result
end

local function same_layout(left, right, message)
  for id, order in pairs(left) do
    equal(right[id], order, message .. " (page " .. id .. ")")
  end
end

-- 1. A fresh session has no workspace until one is named: claiming a default
--    that was never saved would make "current" a lie the moment the file is
--    written.
local fresh = Workspace.new({})
equal(fresh.workspace, nil, "a new session has no workspace yet")
equal(fresh:workspace_count(), 0, "and none are stored")
equal(fresh:workspace_names()[1], nil, "the list is empty")

-- 2. Saving captures the live trees and makes the name current.
equal(fresh:save_workspace("desktop"), true, "the first workspace is saved")
equal(fresh.workspace, "desktop", "saving makes the name current")
equal(fresh:workspace_count(), 1, "one workspace is stored")
equal(table.concat(fresh:workspace_names(), ","), "desktop", "it is listed")

-- 3. Reordering a page, then saving under a new name, keeps both arrangements.
local default_layout = capture(fresh)
equal(fresh:move_focused_direction("right"), true, "the page was rearranged")
local moved_layout = capture(fresh)
local changed = false
for id, order in pairs(moved_layout) do
  if default_layout[id] ~= order then changed = true end
end
equal(changed, true, "the arrangement really changed")
equal(fresh:save_workspace("server"), true, "the second workspace is saved")
equal(table.concat(fresh:workspace_names(), ","), "desktop,server",
  "both are listed, sorted by name")
same_layout(moved_layout, capture(fresh), "the newly saved one is live")

-- 4. Switching restores the other arrangement on every page, not just one.
fresh:move_focused_direction("right")
equal(fresh:switch_workspace("desktop"), true, "switching to a saved workspace works")
equal(fresh.workspace, "desktop", "the active name follows")
same_layout(default_layout, capture(fresh), "the saved arrangement came back")

-- 5. Switching clears undo: the old history describes a tree that is gone, and
--    an undo that resurrected it would undo the switch itself.
equal(#(fresh.undo_stack.overview or {}), 0, "undo history does not survive a switch")
fresh:move_focused_direction("right")
equal(fresh:switch_workspace("server"), true, "switching back works")
same_layout(moved_layout, capture(fresh), "the other arrangement came back too")
equal(fresh:switch_workspace("nope"), false, "an unknown name is refused")
equal(select(2, fresh:switch_workspace("nope")), "unknown_workspace",
  "and says so")

-- 6. Saving over an existing name renames that workspace; two entries with one
--    name would make "which one is active" unanswerable.
equal(fresh:save_workspace("server"), true, "re-saving an existing name is allowed")
equal(fresh:workspace_count(), 2, "it did not create a second entry")

-- 7. Names the store would reject are refused before they reach the file.
for _, name in ipairs({ "", "   ", "../evil", "a/b", "tab\there", string.rep("x", 65) }) do
  local accepted = fresh:save_workspace(name)
  equal(accepted, false, "a refused name: " .. string.format("%q", name))
end
equal(fresh:workspace_count(), 2, "no refused name reached the workspace set")
equal(fresh:save_workspace(" padded name "), true, "surrounding spaces are trimmed")
equal(table.concat(fresh:workspace_names(), ","), "desktop,padded name,server",
  "the trimmed name is what is stored")

-- 8. The last workspace is protected, and deleting the live one moves the
--    session to another rather than leaving it pointing at nothing.
equal(fresh:switch_workspace("server"), true, "the live workspace is known")
local deletions = 0
while fresh:workspace_count() > 1 do
  local name = fresh:workspace_names()[1]
  equal(fresh:delete_workspace(name), true, "a workspace is deleted: " .. name)
  deletions = deletions + 1
end
equal(deletions, 2, "both extra workspaces went")
equal(fresh:delete_workspace("server"), false, "the last one is refused")
equal(select(2, fresh:delete_workspace("server")), "last_workspace", "and says why")
equal(fresh:workspace_count(), 1, "one workspace remains")
equal(fresh:delete_workspace("absent"), false, "an unknown delete is refused")

-- 9. The limit is bounded, and it is reached by refusing rather than by
--    silently dropping the oldest arrangement.
local many = Workspace.new({})
many:save_workspace("w1")
for index = 2, 16 do many:save_workspace("w" .. index) end
equal(many:workspace_count(), 16, "sixteen workspaces are allowed")
local added, limit_error = many:save_workspace("w17")
equal(added, false, "the seventeenth is refused")
equal(limit_error, "workspace_limit_reached", "and says why")
equal(many:workspace_count(), 16, "nothing was dropped to make room")

-- 10. Persistence.  A v3 file carries every workspace and the active one, and
--     a session rebuilt from it starts on the right arrangement.
-- A real session lays out every tab, so it is validated against the build's own
-- page defaults; DEFAULTS is only for the two-page fixtures above.
local encoded = Store.encode(many:orders(), many:trees(), many:saved_workspaces(), many.workspace)
equal(encoded:match("^schema_version: 3") ~= nil, true,
  "a workspace set exports as v3:\n" .. encoded:sub(1, 120))
local session_defaults = Workspace.default_orders()
local orders, trees, workspaces, active = Store.parse(encoded, session_defaults)
equal(orders ~= nil, true, "the exported file parses back")
equal(active, many.workspace, "the active workspace survives the round trip")
local restored = {}
for name in pairs(workspaces) do restored[#restored + 1] = name end
table.sort(restored)
equal(table.concat(restored, ","), table.concat(many:workspace_names(), ","),
  "every workspace survives the round trip")

local reloaded = Workspace.new({
  orders = orders, layout_trees = trees, workspaces = workspaces, workspace = active,
})
equal(reloaded.workspace, many.workspace, "a session starts on the saved workspace")
equal(reloaded:workspace_count(), 16, "and knows the whole set")
same_layout(capture(many), capture(reloaded), "the live layout is the one that was saved")

-- 11. A v2 file still reads, and reports no workspaces rather than inventing
--     one: a single implicit arrangement is what that schema means.
local V2 = [[
schema_version: 2
pages:
  overview:
    type: split
    axis: horizontal
    ratio_micros: 250000
    gap: 1
    children:
      - type: leaf
        widget_id: memory_overview
      - type: leaf
        widget_id: cpu_overview
  gpu:
    type: split
    axis: horizontal
    ratio_micros: 500000
    gap: 1
    children:
      - type: leaf
        widget_id: gpu_utilization
      - type: leaf
        widget_id: gpu_table
]]
local v2_orders, v2_trees, v2_workspaces, v2_active = Store.parse(V2, DEFAULTS)
equal(v2_orders ~= nil, true, "a v2 file still reads")
equal(table.concat(v2_orders.overview, ","), "memory_overview,cpu_overview",
  "the v2 arrangement is preserved")
equal(v2_workspaces, nil, "v2 reports no workspace set")
equal(v2_active, nil, "v2 names no active workspace")
-- A real session, not the two-page fixture: encode one without a workspace
-- set, read it back the way an existing user's file would be, and start from
-- it.  A v2 file must land in a session that renders, with nothing to switch
-- between -- the single implicit arrangement is exactly what v2 means.
local real = Workspace.new({})
local v2_text = Store.encode(real:orders(), real:trees())
equal(v2_text:match("^schema_version: 2") ~= nil, true, "the v2 form is unchanged")
local r_orders, r_trees, r_workspaces, r_active = Store.parse(v2_text, session_defaults)
equal(r_orders ~= nil, true, "a real v2 file parses")
equal(r_workspaces, nil, "and reports no workspace set")
equal(r_active, nil, "and names no active workspace")
local from_v2 = Workspace.new({ orders = r_orders, layout_trees = r_trees })
equal(from_v2:workspace_count(), 0, "a v2 session has nothing to switch between")
equal(from_v2:workspace_names()[1], nil, "its workspace list is empty")
same_layout(capture(real), capture(from_v2), "but the layout it did carry still renders")

-- 12. The refusals.  Each of these would produce a file the loader rejects, so
--     the writer refuses it first.
equal(Store.parse("schema_version: 3\nworkspaces: {}\n", DEFAULTS) == nil, true,
  "a file with no workspaces is refused")
equal(Store.parse("schema_version: 3\nactive: gone\nworkspaces:\n  a:\n    pages: {}\n",
  DEFAULTS) == nil, true, "an active name that does not exist is refused")
equal(Store.parse("schema_version: 3\nworkspaces:\n  \"../evil\":\n    pages: {}\n",
  DEFAULTS) == nil, true, "a name that is not a plain identifier is refused")
equal(Store.parse("schema_version: 3\nworkspaces:\n  a:\n    extra: 1\n    pages: {}\n",
  DEFAULTS) == nil, true, "an unknown workspace key is refused")
equal(Store.parse("schema_version: 3\nworkspaces:\n  a:\n    pages: {}\nbogus: 1\n",
  DEFAULTS) == nil, true, "an unknown root key is refused")
equal(Store.parse("schema_version: 4\npages: {}\n", DEFAULTS) == nil, true,
  "a future schema version is refused rather than guessed at")
local overflow = { "schema_version: 3", "workspaces:" }
for index = 1, 17 do
  overflow[#overflow + 1] = "  w" .. index .. ":"
  overflow[#overflow + 1] = "    pages: {}"
end
equal(Store.parse(table.concat(overflow, "\n"), DEFAULTS) == nil, true,
  "more than sixteen workspaces is refused")

-- 13. A v3 workspace validates exactly as a v2 page set does, so an unknown
--     widget inside one workspace fails the whole file rather than loading a
--     page set that the renderer cannot place.
local V3_BAD = [[
schema_version: 3
active: a
workspaces:
  a:
    pages:
      overview:
        type: leaf
        widget_id: not_a_widget
]]
equal(Store.parse(V3_BAD, DEFAULTS) == nil, true,
  "an unknown widget inside a workspace is refused")

-- 14. encode() is the same refusal boundary: it must not produce a file it
--     would itself reject.
local ok, content = pcall(Store.encode, DEFAULTS, nil, { ["../evil"] = {} }, "x")
equal(ok, false, "encode refuses an unusable workspace name")
local refused, why = pcall(Store.encode, DEFAULTS, nil, "not a table")
equal(refused, false, "encode refuses a workspace set that is not a table")
equal(why == false or tostring(why):find("workspaces must be a table") ~= nil, true,
  "and says what is wrong")
-- A session that never named a workspace still has to save, and its file stays
-- at v2: an empty set is not a broken set, it is no set.
local never_named = Workspace.new({})
local plain = Store.encode(never_named:orders(), never_named:trees(),
  never_named:saved_workspaces(), never_named.workspace)
equal(plain:match("^schema_version: 2") ~= nil, true,
  "a session with no workspace still saves as v2:\n" .. plain:sub(1, 60))
local p_orders, p_trees, p_workspaces, p_active = Store.parse(plain, session_defaults)
equal(p_orders ~= nil, true, "and that file still reads")
equal(p_workspaces, nil, "still with no workspace set")

-- 15. The page trees a workspace carries are copies.  A caller that reaches in
--     and mutates them must not rewrite the saved arrangement.
local isolation = Workspace.new({})
isolation:save_workspace("keep")
local before = capture(isolation)
local exported = isolation:saved_workspaces()
exported.keep.overview = page_tree("bogus", "worse", 0.5)
same_layout(before, capture(isolation), "the live tree is unchanged")
local reread = Store.parse(Store.encode(isolation:orders(), isolation:trees(),
  isolation:saved_workspaces(), isolation.workspace), session_defaults)
equal(reread ~= nil, true, "the un-mutated set still encodes to a valid file")

-- 16. The list itself: it doubles as the name entry, so a deterministic
--     rendering check belongs here rather than in terminal archaeology.
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local translator = assert(I18n.new({ locale = "en-US" }))
local function lines(selection)
  return table.concat(TUI.workspace_lines(selection, translator, true), "\n")
end
local bare_list = lines({ names = { "desktop", "server" }, active = "server",
  index = 2, draft = "", truncated = false })
equal(bare_list:find("Workspaces", 1, true) ~= nil, true, "the list is titled")
equal(bare_list:find("desktop", 1, true) ~= nil, true, "a saved name is listed")
equal(bare_list:find("server", 1, true) ~= nil, true, "so is the current one")
equal(bare_list:find("(current)", 1, true) ~= nil, true, "the current one is marked")
equal(bare_list:find("New:", 1, true) ~= nil, true, "there is always a new-name row")
equal(bare_list:find("Esc/Enter closes", 1, true) ~= nil, true, "it says how to close")
-- The marker sits on the selected row, which is what makes the list navigable.
local function marked(text, name, marker)
  for line in text:gmatch("[^\n]+") do
    if line:find(name, 1, true) then
      return line:sub(1, #marker) == marker
    end
  end
  return nil
end
equal(marked(bare_list, "server", "▸"), true,
  "the cursor marks the selected row: " .. bare_list)
equal(marked(bare_list, "desktop", "▸"), false,
  "and only that row: " .. bare_list)

local typing = lines({ names = { "desktop" }, active = "desktop",
  index = 2, draft = "night", truncated = false })
equal(typing:find("night", 1, true) ~= nil, true, "the draft name is shown: " .. typing)
local empty_draft = lines({ names = {}, active = nil, index = 1, draft = "",
  truncated = false })
equal(empty_draft:find("New: _", 1, true) ~= nil, true,
  "an empty draft shows a placeholder: " .. empty_draft)
local truncated = lines({ names = { "a" }, active = "a", index = 1, draft = "",
  truncated = true })
equal(truncated:find("More workspaces exist", 1, true) ~= nil, true,
  "a truncated list says so instead of pretending to be complete: " .. truncated)
-- ASCII fallback: the marker must not depend on a Unicode font.
local ascii = table.concat(TUI.workspace_lines({ names = { "a" }, active = "a",
  index = 1, draft = "", truncated = false }, translator, false), "\n")
equal(ascii:find("▸", 1, true), nil, "the ASCII profile gets no block marker")
equal(ascii:find("> a", 1, true) ~= nil, true, "it gets a plain one: " .. ascii)

print("ok: named layout workspaces")
