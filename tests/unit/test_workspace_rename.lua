-- Renaming a saved workspace, and the two bugs it turned up in the manager
-- that drives it.
--
-- The model half is small but load-bearing: a rename moves a name, and the
-- arrangement stored under it has to come along untouched.  That is the whole
-- difference from "save under the new name, delete the old one" -- and the
-- reason it is worth its own method is that the save/delete pair would throw
-- away every edit made since the workspace was last saved.
--
-- The manager half is where the two bugs were.  `x` and `q` were matched before
-- the printable-key branch, so a workspace could not be named with either
-- letter in it -- the keys the user pressed to type a letter were taken as
-- commands.  And Enter on an existing row saved the live trees over the target
-- before switching to it, so the list could not switch anywhere without
-- destroying what it switched to, while the hint said "Enter switches".
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Workspace = require("wtop.workspace")
local LayoutStore = require("wtop.layout_store")
local Layout = require("wtop.model.layout")
local I18n = require("wtop.i18n")
local TUI = require("wtop.tui")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

-- A full description of a page, not just its leaf order: two arrangements can
-- hold the same order and still be different layouts, so a test that compared
-- only the order would pass for the wrong reason.  The root ratio and axis are
-- in the string for the same reason.
--
-- The stored trees live at `workspaces[name][page]`, so a stored page needs the
-- workspace it belongs to; the live one is `layout_trees[page]` regardless.
local function shape_of(workspace, page, from_saved, name)
  local trees
  if from_saved then
    trees = workspace.workspaces[name or workspace.workspace]
  else
    trees = workspace.layout_trees
  end
  local tree = trees and trees[page]
  if not tree then return nil end
  if tree.type == "leaf" then return "leaf:" .. tree.widget_id end
  local ok, info = Layout.validate(tree,
    { allowed_widgets = workspace.widget_orders[page] })
  if not ok then return "invalid" end
  return table.concat(info.order, ",")
    .. string.format("|%.4f|%s", tree.ratio or 0, tostring(tree.axis))
end

-- 1. A rename moves the name and carries the arrangement with it.
local w = Workspace.new({})
equal(w:save_workspace("desktop"), true, "the first workspace is saved")
equal(w.workspace, "desktop", "saving makes the name current")
local before = shape_of(w, "overview", true)
assert(before and before ~= "invalid", "the saved workspace has a comparable tree")

equal(w:rename_workspace("desktop", "desk"), true, "the workspace is renamed")
equal(table.concat(w:workspace_names(), ","), "desk", "only the new name is listed")
equal(w.workspace, "desk", "renaming the live workspace keeps it live under the new name")
equal(w:workspace_count(), 1, "a rename is not a second workspace")
equal(shape_of(w, "overview", true), before, "the stored arrangement came along")
equal(w.dirty, true, "a rename is a change worth saving")

-- 2. The arrangement that comes along is the one that was *saved*, not the one
-- on screen.  Renaming is not a save: the trees have moved on since the
-- workspace was captured, and re-saving them here would silently overwrite the
-- snapshot with whatever happened to be live.
equal(w:remove_focused_widget(), true, "the live arrangement is edited after saving")
local live_after_edit = shape_of(w, "overview", false)
assert(live_after_edit ~= before, "the edit really changed the live arrangement")
local renamed, rename_error = w:rename_workspace("desk", "station")
equal(renamed, true, "the rename is not refused: " .. tostring(rename_error))
equal(shape_of(w, "overview", true), before,
  "the rename did not re-save the live trees over the stored one")
equal(shape_of(w, "overview", false), live_after_edit,
  "and the live arrangement is still the edited one")
equal(w.workspace, "station", "the active name followed the rename")

-- 3. Renaming a workspace that is not live touches nothing but its key.  A
-- rename that switched to the workspace it renamed would move the user out of
-- the layout they were looking at to save them from typing.
w:save_workspace("laptop")
w:save_workspace("spare")
equal(w:rename_workspace("station", "workstation"), true, "a non-active rename works")
equal(w:rename_workspace("workstation", "idle"), true, "and it renames onward")
equal(w.workspace, "spare", "renaming another workspace does not switch to it")
local live_before = shape_of(w, "overview", false)
local spare_shape = shape_of(w, "overview", true, "spare")
assert(spare_shape, "the active workspace had a stored tree")

equal(w:rename_workspace("spare", "cold"), true, "the active name is renamed")
equal(w.workspace, "cold", "and the active workspace follows its new name")
equal(shape_of(w, "overview", false), live_before,
  "renaming did not disturb the live arrangement")
equal(shape_of(w, "overview", true, "cold"), spare_shape,
  "and the stored trees came along under the new name")
equal(table.concat(w:workspace_names(), ","), "cold,idle,laptop",
  "the list is sorted, so a name that sorts earlier moves the others along")
equal(w:workspace_count(), 3, "three workspaces are stored")

-- 4. A name already in use is refused rather than merged: two arrangements
-- under one name make "which one is live" unanswerable, and the loser is gone.
-- The two are given different arrangements first, so a merge would be visible.
w:save_workspace("scratch")
w:rename_workspace("scratch", "spare2")
w:remove_focused_widget()
w:save_workspace("cold")
local cold_shape = shape_of(w, "overview", true, "cold")
assert(cold_shape ~= spare_shape,
  "the two fixtures differ, or this test proves nothing: " .. tostring(cold_shape))
local taken, taken_error = w:rename_workspace("spare2", "cold")
equal(taken, false, "a rename onto a name in use is refused")
equal(taken_error, "workspace_name_taken", "and says why")
equal(shape_of(w, "overview", true, "cold"), cold_shape,
  "the target arrangement is untouched by the refusal")
equal(w:workspace_count(), 4, "the refusal did not drop a workspace")
assert(w.workspaces.spare2, "the workspace that tried to take the name is still there")
assert(w.workspaces.cold, "and so is the one it wanted")
-- Both are still reachable by name, which is what "neither was harmed" means.
equal(w:rename_workspace("spare2", "spare3"), true, "the loser can be renamed onward")
equal(w:rename_workspace("cold", "cold2"), true, "and so can the winner")

-- 5. Renaming to the name it already carries is the success it looks like, and
-- the workspace survives.  The move is a write followed by a delete of the key
-- just written, so a missing early return here would delete the workspace and
-- then report that it worked.
local same, same_error = w:rename_workspace("cold2", "cold2")
equal(same, true, "renaming to the same name is not an error: " .. tostring(same_error))
assert(w.workspaces.cold2, "the workspace still exists after renaming it to itself")
equal(w:workspace_count(), 4, "and the count is unchanged")
w.dirty = false
w:rename_workspace("cold2", "cold2")
equal(w.dirty, false, "a rename that changed nothing does not mark the file dirty")

-- Surrounding spaces are trimmed before the comparison, so this is the same
-- name rather than a collision with itself.
equal(w:rename_workspace("cold2", "  cold2  "), true, "a padded same-name rename works")
assert(w.workspaces.cold2, "trimming did not delete the workspace")
equal(w:workspace_count(), 4, "and did not add one either")

-- 6. The same name rules as saving, because the same check runs for both.  A
-- name the manager would refuse to create must not be one it will set, or the
-- refusal would only surface after the file was written.
for _, case in ipairs({
  { "", "workspace_name_length" },
  { "   ", "workspace_name_length" },
  { string.rep("n", 65), "workspace_name_length" },
  { "bad/name", "invalid_workspace_name" },
  { "-leading", "invalid_workspace_name" },
  { "tab\there", "invalid_workspace_name" },
  { "new\nline", "invalid_workspace_name" },
  { 42, "workspace_name_must_be_text" },
  { {}, "workspace_name_must_be_text" },
}) do
  local refused, reason = w:rename_workspace("cold2", case[1])
  equal(refused, false, "a rename to " .. tostring(case[1]) .. " is refused")
  equal(reason, case[2], "  and says why for " .. tostring(case[1]))
  assert(w.workspaces.cold2, "  and leaves the workspace in place")
end
equal(w:rename_workspace("absent", "whatever"), false, "an unknown source is refused")
equal(select(2, w:rename_workspace("absent", "whatever")), "unknown_workspace",
  "and says why")

-- The boundary the store also enforces.  The name rule is written in two files
-- -- here and in layout_store -- and this is what keeps them equal.
--
-- It is worth the trouble: a name with a space in it used to be accepted here,
-- written out as a bare YAML key, and then refused by this same loader on the
-- next start.  The exit save replaced a good layout.yml with a file nothing
-- could read, and the one-generation backup held the same broken text, so the
-- whole layout was gone.  A name the model accepts that the store rejects is
-- therefore not a cosmetic disagreement -- it is a silent loss.
for _, name in ipairs({ string.rep("n", 64), "ok name.", "a_b-c.d", "W1" }) do
  local ok, reason = w:rename_workspace("cold2", name)
  equal(ok, true, "a legal name is accepted: " .. name .. " -- " .. tostring(reason))
  local encoded = LayoutStore.encode(w:orders(), nil, { [name] = w.workspaces[name] },
    name, nil)
  local parsed, _, workspaces, active = LayoutStore.parse(encoded, w.widget_orders, "<test>")
  assert(parsed and workspaces and workspaces[name],
    "the store agrees the name is legal: " .. name)
  equal(active, name, "and it is the active one")
  equal(w:rename_workspace(name, "cold2"), true, "  and it renames back: " .. name)
end
-- The same rule the other way round: a name the store's own validator refuses
-- is one the model refuses, so the file and the session cannot disagree.
for _, name in ipairs({ "bad/name", "-leading", "a" .. string.rep("b", 64) }) do
  local ok = w:rename_workspace("cold2", name)
  equal(ok, false, "the model refuses what the store would refuse: " .. name)
end

-- 7. The manager's hints, which are what tell the user which mode the editor
-- is in.  A hint that still described the other mode would leave them pressing
-- the wrong key, and the one that lists every binding at once would leave them
-- working out which of them apply to the row the cursor is on.
local translator = assert(I18n.new({ locale = "en-US" }))
local function render(state, unicode)
  return TUI.workspace_lines({
    names = { "alpha", "beta" },
    active = "alpha",
    index = 1,
    draft = "",
    renaming = false,
  } and {
    names = { "alpha", "beta" },
    active = "alpha",
    index = state.index or 1,
    draft = state.draft or "",
    renaming = state.renaming == true,
  }, translator, unicode)
end
local function row_with(lines, text)
  for _, line in ipairs(lines) do
    if line:find(text, 1, true) then return line end
  end
  return nil
end

local idle_hint = render({})[3]
assert(idle_hint:find("r renames", 1, true),
  "the manager hint does not say that r renames: " .. idle_hint)
assert(idle_hint:find("Esc closes", 1, true),
  "the manager hint does not say that Esc closes: " .. idle_hint)
assert(row_with(render({}), "alpha") ~= nil, "the saved workspaces are listed")
assert(row_with(render({ index = 3, draft = "queue" }), "queue") ~= nil,
  "the new-workspace row shows its draft")

-- The active row is the interesting one to rename: it is the row that also
-- carries the "(current)" marker, so a renderer that drew the suffix from the
-- old name would show the draft and "current" on the same line, claiming two
-- things about a name that is about to stop being either.
local renaming = render({ index = 1, draft = "alp", renaming = true })
local rename_hint = renaming[3]
assert(rename_hint:find("Enter renames", 1, true),
  "the rename hint does not say what Enter does: " .. rename_hint)
assert(rename_hint:find("Esc cancels", 1, true),
  "the rename hint does not say that Esc cancels: " .. rename_hint)
-- Substring matching would trip over "Ente[r renames]", so the check is for
-- the bindings that are genuinely suspended mid-rename rather than for the
-- letters of the word "renames".
for _, suspended in ipairs({ "x deletes", "type a new name", "Up/Down selects" }) do
  assert(rename_hint:find(suspended, 1, true) == nil,
    "the rename hint lists " .. suspended .. ", which does nothing mid-rename: "
      .. rename_hint)
end
assert(row_with(renaming, "alpha") == nil,
  "the row being renamed still shows its old name: "
    .. tostring(row_with(renaming, "alpha")))
assert(row_with(renaming, "alp") ~= nil,
  "the row being renamed does not show the text being typed")
assert(row_with(renaming, "current") == nil,
  "the row being renamed still claims to be the current one: "
    .. tostring(row_with(renaming, "current")))
assert(row_with(renaming, "beta") ~= nil, "the other rows are still listed")

-- The new-workspace row is not where the rename text is going, so it must not
-- show a draft that looks like it is.  Checked by content rather than by line
-- number, because the row's position moves with the list length.
assert(row_with(renaming, "New") ~= nil, "the new-workspace row is still offered")
for _, line in ipairs(renaming) do
  assert(not (line:find("New", 1, true) and line:find("alp", 1, true)),
    "the new-workspace row shows the rename draft: " .. line)
end

-- The ASCII profile has no block glyphs, so the caret has to degrade to
-- something the row still reads as "being edited".
local ascii = render({ index = 2, draft = "be", renaming = true }, false)
local ascii_row = row_with(ascii, "be")
assert(ascii_row and ascii_row:find("_", 1, true),
  "the ASCII profile has no caret, so the row gives no hint it is being edited: "
    .. tostring(ascii_row))

-- 8. The footer's resting state in edit mode, and the message that has to
-- outrank it.  This is where the confirmation went: the workspace manager is
-- reachable only in edit mode, and edit mode replaced the whole status table,
-- so a deleted, switched or renamed workspace all happened with nothing on
-- screen to say so -- the rename worked and the user had no way to know.
local editor = Workspace.new({ i18n = translator })
editor:toggle_edit()
equal(editor.edit_mode, true, "edit mode is on")

-- Render mutates the caller's state table, which is how the TUI hands the
-- status down, so reading it back is the same path the renderer reads.
local with_message = { status = { message = "Workspace alpha renamed to my qx" } }
editor:render(200, 50, with_message)
equal(with_message.status.message, "Workspace alpha renamed to my qx",
  "a transient message outranks the edit banner")
equal(with_message.status.warning, false,
  "and it is not styled as a mode, because it is not one")

-- With nothing to say, the banner is the footer's resting state again.
local bare = { status = {} }
editor:render(200, 50, bare)
assert(bare.status.message:find("LAYOUT", 1, true),
  "the edit banner is missing when there is no message: " .. tostring(bare.status.message))
equal(bare.status.warning, true, "and it is still styled as a mode")

-- The rest of the caller's status survives edit mode.  It used to be dropped
-- along with the message, which took the persisted-layout error and the
-- root/sudo marker off the footer for as long as the user stayed in edit mode.
local kept = { status = {
  error = "persisted layout ignored", privilege = { root = true },
  filter = "cpu>50", data_age = "1s",
} }
editor:render(200, 50, kept)
equal(kept.status.error, "persisted layout ignored", "edit mode keeps a status error")
equal(kept.status.privilege and kept.status.privilege.root, true,
  "edit mode keeps the privilege marker")
equal(kept.status.filter, "cpu>50", "edit mode keeps the process filter")
equal(kept.status.data_age, "1s", "edit mode keeps the data age")
assert(kept.status.message:find("LAYOUT", 1, true),
  "and still falls back to the banner when there is no message")

-- Leaving edit mode hands the footer back to the page's own status, banner
-- included, so the banner is not a one-way door.
editor:toggle_edit()
equal(editor.edit_mode, false, "edit mode is off")
local after = { status = { message = "Workspace alpha renamed to my qx" } }
editor:render(200, 50, after)
equal(after.status.message, "Workspace alpha renamed to my qx",
  "outside edit mode the message is the status, untouched")

print("ok: workspace rename")
