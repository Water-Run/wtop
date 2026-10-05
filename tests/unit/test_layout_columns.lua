-- Persisting the process table's column set in layout.yml.
--
-- The layout file grew a fourth version rather than a fourth layout model: a
-- v4 file is one of the three earlier bodies with a top-level process_columns
-- list beside it.  What has to hold is that the new key is inert until a v4
-- file appears, that the encoder never writes a file the loader would refuse,
-- and that a column set survives the round trip the TUI actually performs --
-- load, hand to the controller, edit, save, load again.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;"
    .. root .. "/tests/?.lua;" .. package.path

local LayoutStore = require("wtop.layout_store")
local LayoutCommands = require("wtop.layout_commands")
local ProcessColumns = require("wtop.model.process_columns")
local ProcessTable = require("wtop.model.process_table")
local Workspace = require("wtop.workspace")
local Layout = require("wtop.model.layout")
local FileBackup = require("wtop.file_backup")
local native = require("wtop.native")

-- A two-page layout written by hand, so the assertions below can name a widget
-- instead of counting through the dozen pages a real session has.
local DEFAULTS = {
  overview = { "cpu_overview", "memory_overview" },
  gpu = { "gpu_utilization", "gpu_table" },
}

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

local function joined(list)
  return type(list) == "table" and table.concat(list, ",") or tostring(list)
end

local function refuse(text, pattern, label)
  local value, reason = LayoutStore.parse(text, DEFAULTS, "<test>")
  assert(value == nil, (label or "text") .. ": expected a refusal, got a value")
  assert(type(reason) == "string" and reason:find(pattern, 1, true),
    (label or "text") .. ": expected a reason containing " .. pattern
      .. ", got " .. tostring(reason))
end

-- The smallest set the model allows: without both of these the rows cannot be
-- identified, so it is the floor every other list is compared against.
local MINIMAL = { "pid", "name" }
-- A set that hides three default-visible columns and shows one that is off by
-- default, which is the shape a real editing session produces.
local EDITED = { "pid", "user", "nice", "cpu", "name", "queued" }

local function page_tree(first, second, ratio)
  return {
    type = "split", axis = "horizontal", ratio = ratio or 0.5, gap = 1,
    children = {
      { type = "leaf", widget_id = first },
      { type = "leaf", widget_id = second },
    },
  }
end

local function default_trees()
  return {
    overview = page_tree("cpu_overview", "memory_overview", 0.7),
    gpu = page_tree("gpu_utilization", "gpu_table"),
  }
end

-- The trees a real session has, for the one section that goes through the
-- layout commands -- those load the persisted file against the build's own
-- page orders, so it has to be a file those orders can read.
local function trees_for(orders)
  local result = {}
  for page, order in pairs(orders) do
    result[page] = assert(Layout.from_order(order, {
      allowed_widgets = order, axis = "horizontal", alternate_axes = true,
    }))
  end
  return result
end

local function version_of(text)
  return text:match("^schema_version: (%d+)") or "none"
end

-- 1. All three bodies carry the column set at v4, and the layout half is
-- unchanged by its presence.  The store has to accept the body it is given
-- rather than assume the newest shape: a v4 file whose pages are widget ids is
-- read as ids, and one whose pages are trees is read as trees.
local id_list = LayoutStore.encode(DEFAULTS, nil, nil, nil, EDITED)
equal(version_of(id_list), "4", "id-list body with columns is v4")
local orders, trees, workspaces, active, columns =
  LayoutStore.parse(id_list, DEFAULTS, "<test>")
equal(joined(columns), joined(EDITED), "id-list body keeps the chosen columns")
assert(active == nil, "id-list body names no workspace")
assert(workspaces == nil, "id-list body must not invent a workspace set")
equal(joined(orders.overview), "cpu_overview,memory_overview",
  "id-list body keeps the page order")
assert(trees.overview.axis == "horizontal" and math.abs(trees.overview.ratio - 0.5) < 1e-9,
  "id-list body falls back to the default tree")

local tree_body = LayoutStore.encode(DEFAULTS, default_trees(), nil, nil, EDITED)
equal(version_of(tree_body), "4", "tree body with columns is v4")
local tree_orders, tree_trees, _, _, tree_columns =
  LayoutStore.parse(tree_body, DEFAULTS, "<test>")
equal(joined(tree_columns), joined(EDITED), "tree body keeps the chosen columns")
assert(math.abs(tree_trees.overview.ratio - 0.7) < 1e-6,
  "tree body keeps its ratio: " .. tostring(tree_trees.overview.ratio))
equal(joined(tree_orders.gpu), "gpu_utilization,gpu_table", "tree body keeps its order")

local workspace_body = LayoutStore.encode(DEFAULTS, nil,
  { alpha = default_trees(), beta = default_trees() }, "beta", EDITED)
equal(version_of(workspace_body), "4", "workspace body with columns is v4")
local ws_orders, _, ws_workspaces, ws_active, ws_columns =
  LayoutStore.parse(workspace_body, DEFAULTS, "<test>")
equal(ws_active, "beta", "workspace body keeps the active name")
assert(ws_workspaces.alpha and ws_workspaces.beta, "workspace body keeps both")
equal(joined(ws_columns), joined(EDITED), "workspace body keeps the chosen columns")
assert(ws_orders.overview, "workspace body projects the active layout")

-- 2. The column set is a property of the session, not of a workspace: it is
-- one top-level list, and the parser returns the same one whichever workspace
-- is live.  Tying it to a workspace would mean hiding a column quietly
-- bringing it back on the next switch.
local _, _, _, _, alpha_view = LayoutStore.parse(LayoutStore.encode(DEFAULTS, nil,
  { alpha = default_trees(), beta = default_trees() }, "alpha", EDITED), DEFAULTS, "<test>")
equal(joined(alpha_view), joined(EDITED),
  "the column set does not follow the active workspace")

-- 3. A stored list is read strictly.  The model repairs a list in memory, but a
-- file is either a layout the loader understands or it is refused whole: a
-- silently substituted list would put back columns the user turned off and
-- give no reason.
refuse("schema_version: 4\npages: {}\n", "process_columns must be a sequence",
  "v4 without columns")
refuse("schema_version: 4\npages: {}\nprocess_columns:\n", "process_columns must be a sequence",
  "v4 with a null column list")
refuse("schema_version: 4\npages: {}\nprocess_columns: pid\n", "process_columns must be a sequence",
  "v4 with a scalar column list")
refuse("schema_version: 4\npages: {}\nprocess_columns:\n  first: pid\n",
  "process_columns must be a dense sequence", "v4 with a mapping column list")
refuse("schema_version: 4\npages: {}\nprocess_columns:\n  - pid\n  - name\n  - bogus\n",
  "unknown process column: bogus", "v4 with an unknown column")
refuse("schema_version: 4\npages: {}\nprocess_columns:\n  - pid\n  - pid\n  - name\n",
  "duplicate process column: pid", "v4 with a repeated column")
refuse("schema_version: 4\npages: {}\nprocess_columns:\n  - pid\n  - cpu\n",
  "process_columns is missing name", "v4 without the Command column")
refuse("schema_version: 4\npages: {}\nprocess_columns:\n  - user\n  - name\n",
  "process_columns is missing pid", "v4 without the PID column")
refuse("schema_version: 4\nprocess_columns:\n  - pid\n  - name\n",
  "must define pages or workspaces", "v4 with neither body")
refuse("schema_version: 4\npages: {}\nworkspaces: {}\nprocess_columns:\n  - pid\n  - name\n",
  "not both", "v4 with both bodies")
refuse("schema_version: 4\npages: {}\nprocess_columns:\n  - pid\n  - name\nsort_key: cpu\n",
  "unknown layout key: sort_key", "v4 with an unrelated key")

-- A hole in the list is not something the YAML reader can produce, but a table
-- can arrive from anywhere, so the store checks the sequence it was handed.
local sparse, sparse_reason = LayoutStore.validate({
  schema_version = 4,
  pages = {},
  process_columns = { [1] = "pid", [3] = "name" },
}, DEFAULTS)
assert(sparse == nil, "a sparse column list must be refused")
assert(sparse_reason:find("dense", 1, true),
  "a sparse list is refused for being sparse, got " .. tostring(sparse_reason))

-- 4. The key belongs to v4 alone.  A v3 file carrying one would otherwise be
-- read as a workspace file with its column set ignored, so the table would
-- reset while the arrangements came back.
refuse(LayoutStore.encode(DEFAULTS, nil, { alpha = default_trees() }, "alpha")
  .. "process_columns:\n  - pid\n  - name\n", "unknown layout key: process_columns",
  "v3 carrying a column list")
refuse("schema_version: 5\npages: {}\n", "unsupported layout schema_version: 5",
  "a version from a newer build")

-- 5. Nothing changes for a session that never opens the editor.  The encoder
-- still writes the version the body has always written, and a reader of those
-- files still gets a layout with no column set to apply.
equal(version_of(LayoutStore.encode(DEFAULTS)), "1", "a bare layout stays v1")
equal(version_of(LayoutStore.encode(DEFAULTS, default_trees())), "2", "a tree layout stays v2")
equal(version_of(LayoutStore.encode(DEFAULTS, nil, { alpha = default_trees() }, "alpha")),
  "3", "a workspace layout stays v3")
for _, body in ipairs({
  LayoutStore.encode(DEFAULTS),
  LayoutStore.encode(DEFAULTS, default_trees()),
  LayoutStore.encode(DEFAULTS, nil, { alpha = default_trees() }, "alpha"),
}) do
  local parsed, _, _, _, none = LayoutStore.parse(body, DEFAULTS, "<test>")
  assert(parsed, "a pre-v4 body still loads")
  assert(none == nil, "a pre-v4 body reports no columns, not an empty list")
end

-- 6. The encoder's contract is that what it writes this loader will read.  A
-- column list damaged in memory is normalized on the way out -- the save path
-- must not fail over a cosmetic view setting -- but the file it produces is
-- still one that passes the strict reader above.
for _, case in ipairs({
  { EDITED, joined(EDITED), "a chosen list is written as given" },
  { MINIMAL, joined(MINIMAL), "the smallest legal list is kept" },
  { { "name", "pid" }, "name,pid", "an explicit order of required columns is kept" },
  { { "pid", "user", "cpu", "time", "name", "bogus" }, "pid,user,cpu,time,name",
    "an unknown key is dropped" },
  { { "pid", "pid", "user", "cpu", "name" }, "pid,user,cpu,name", "a repeat collapses" },
  { { "cpu", "time" }, "pid,cpu,time,name", "a missing required column is put back" },
  { {}, joined(ProcessColumns.defaults()), "an empty list falls back to the defaults" },
  { { 1, 2 }, joined(ProcessColumns.defaults()), "a list of non-strings falls back" },
}) do
  local written = LayoutStore.encode(DEFAULTS, default_trees(), nil, nil, case[1])
  equal(version_of(written), "4", "a column list makes the file v4")
  local _, _, _, _, written_columns = LayoutStore.parse(written, DEFAULTS, "<test>")
  equal(joined(written_columns), case[2], "encoding " .. joined(case[1]) .. " -- " .. case[3])
end
local refused, refusal = pcall(LayoutStore.encode, DEFAULTS, nil, nil, nil, "pid")
assert(not refused and tostring(refusal):find("must be a table"),
  "a non-table column list is refused before any write: " .. tostring(refusal))

-- 7. The round trip the TUI performs, against real files.  Load hands the
-- list to the controller, the editor changes it, and the exit path saves it;
-- the next session has to open with the same table.
local directory = os.getenv("TMPDIR") or "/tmp"
local base = directory .. "/wtop-layout-cols-" .. tostring(os.time()) .. "-"
  .. tostring(math.random(1, 1000000))
local layout_path = base .. "-layout.yml"
local export_path = base .. "-export.yml"
local function read_layout(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local content = handle:read("*a")
  handle:close()
  return content
end
local function write_layout(path, content)
  local handle = assert(io.open(path, "wb"))
  assert(handle:write(content))
  assert(handle:close())
end
local function remove_layout(path)
  os.remove(path)
  os.remove(FileBackup.backup_path(path))
end

-- Every save below goes through the module's atomic writer, so a tree without
-- a built module cannot exercise persistence at all; the rest of the file
-- (v4 inertness, encoder/loader agreement) has already run by this point and
-- does not need it.  A stated skip in the one suite that builds nothing, a
-- failure everywhere else.
if not require("support.artifacts").require_condition(native.available,
        "the native module (atomic layout writes)", "run `make native`") then
  return true
end

-- A missing file is the first run: there is no column set, and the controller
-- keeps its own defaults rather than being handed an empty list.
local fresh_orders, fresh_status, _, _, _, fresh_columns =
  LayoutStore.load(DEFAULTS, layout_path)
equal(fresh_status.state, "default", "a missing layout is not an error")
assert(fresh_orders.overview, "a missing layout falls back to the defaults")
assert(fresh_columns == nil, "a missing layout offers no columns to restore")

local controller = ProcessTable.new({ sort_key = "cpu", descending = true })
equal(joined(controller:columns()), joined(ProcessColumns.defaults()),
  "a session with no file starts on the default columns")
if fresh_columns then controller:set_columns(fresh_columns) end
equal(joined(controller:columns()), joined(ProcessColumns.defaults()),
  "no file means no change to the defaults")

-- The editor's two operations, then the exit save.
assert(select(2, controller:toggle_column("memory")) == nil, "a column can be hidden")
assert(select(2, controller:toggle_column("queued")) == nil, "a hidden column can be shown")
assert(select(2, controller:move_column("cpu", -1)) == nil, "a column can be moved")
local chosen = ProcessColumns.normalize(controller:columns())
assert(joined(chosen) ~= joined(ProcessColumns.defaults()),
  "the edited session holds something other than the defaults")
local saved, save_error = LayoutStore.save(DEFAULTS, layout_path, default_trees(),
  { alpha = default_trees() }, "alpha", chosen)
assert(saved, "save failed: " .. tostring(save_error))
equal(version_of(read_layout(layout_path)), "4", "a session with columns saves v4")
local _, _, _, _, on_disk = LayoutStore.parse(read_layout(layout_path), DEFAULTS, "<test>")
equal(joined(on_disk), joined(chosen), "the saved file holds the choice")

-- The next session loads and applies it, and renders the same columns.
local reloaded, reload_status, _, _, _, reloaded_columns = LayoutStore.load(DEFAULTS, layout_path)
equal(reload_status.state, "loaded", "the saved layout loads again")
assert(reloaded.overview, "the reloaded layout is usable")
assert(reloaded_columns ~= nil and joined(reloaded_columns) == joined(chosen),
  "the reloaded columns are the ones that were chosen: " .. joined(reloaded_columns))
local next_session = ProcessTable.new({ sort_key = "cpu", descending = true })
next_session:set_columns(reloaded_columns)
equal(joined(next_session:columns()), joined(chosen),
  "the next session opens with the table the last one left")
equal(select(2, next_session:toggle_column("pid")), "column_required",
  "the required columns stay required after a reload")

-- Saving again must not drop the workspace set the file already had, or the
-- column set would survive at the cost of the arrangements.
local again, again_error = LayoutStore.save(DEFAULTS, layout_path, default_trees(),
  { alpha = default_trees(), beta = default_trees() }, "alpha", chosen)
assert(again, "a second save failed: " .. tostring(again_error))
local _, _, _, both, both_active, both_columns = LayoutStore.load(DEFAULTS, layout_path)
assert(both.alpha and both.beta, "re-saving a session with columns keeps both workspaces")
equal(both_active, "alpha", "re-saving keeps the active workspace")
equal(joined(both_columns), joined(chosen), "re-saving keeps the columns")

-- A layout that was never edited keeps its own version until the columns
-- actually change.  A v2 file contributes no column set, so a session that only
-- moves a widget leaves it at v2; a session that also hid a column moves it to
-- v4 rather than dropping the key.
write_layout(layout_path, LayoutStore.encode(DEFAULTS, default_trees()))
local _, _, _, _, _, before_edit = LayoutStore.load(DEFAULTS, layout_path)
assert(before_edit == nil, "a v2 file contributes no columns")
local unchanged, unchanged_error = LayoutStore.save(DEFAULTS, layout_path, default_trees())
assert(unchanged, "saving an unedited layout failed: " .. tostring(unchanged_error))
equal(version_of(read_layout(layout_path)), "2", "an unedited session leaves the version alone")
local upgraded, upgrade_error = LayoutStore.save(DEFAULTS, layout_path, default_trees(),
  nil, nil, chosen)
assert(upgraded, "saving a v2 layout with columns failed: " .. tostring(upgrade_error))
equal(version_of(read_layout(layout_path)), "4", "a column change upgrades the file to v4")
local _, _, upgraded_trees, _, _, upgraded_columns = LayoutStore.load(DEFAULTS, layout_path)
assert(math.abs(upgraded_trees.overview.ratio - 0.7) < 1e-6,
  "the upgrade keeps the layout it found: " .. tostring(upgraded_trees.overview.ratio))
equal(joined(upgraded_columns), joined(chosen), "the upgrade writes the columns")

-- A v4 file whose columns cannot be read is refused like any other broken
-- layout, with a reason that names the column.  The saved file is held aside
-- first, so the two recovery paths below start from a known backup rather than
-- from whatever the previous save happened to leave.
local good_file = read_layout(layout_path)
os.remove(FileBackup.backup_path(layout_path))
write_layout(layout_path, "schema_version: 4\npages:\n  overview:\n    - cpu_overview\n"
  .. "process_columns:\n  - pid\n")
local broken_orders, broken_status, _, _, _, broken_columns =
  LayoutStore.load(DEFAULTS, layout_path)
equal(broken_status.state, "error", "a v4 file with a bad column list errors")
assert(broken_orders.overview, "a refused layout still falls back to the defaults")
assert(broken_columns == nil, "a refused layout offers no columns")
assert(tostring(broken_status.reason):find("missing name", 1, true),
  "the refusal names the column that is missing: " .. tostring(broken_status.reason))

-- The backup is the v4 file from before, so a start with it recovers the
-- columns the user chose instead of resetting the table to its defaults.
write_layout(FileBackup.backup_path(layout_path), good_file)
local recovered, recovered_status, _, _, _, recovered_columns =
  LayoutStore.load(DEFAULTS, layout_path)
equal(recovered_status.state, "recovered_backup", "a refused layout recovers its backup")
assert(tostring(recovered_status.reason):find("missing name", 1, true),
  "the recovery says what it recovered from: " .. tostring(recovered_status.reason))
equal(joined(recovered_columns), joined(chosen),
  "the recovered backup carries the columns: " .. joined(recovered_columns))

-- 8. Export and import carry the column set, or a backup would restore the
-- arrangement around the table and not the table.  These two commands load the
-- file against the build's own page orders, so this section uses them.
local real = Workspace.default_orders()
write_layout(layout_path,
  LayoutStore.encode(real, trees_for(real), nil, nil, chosen))
local exported, export_note = LayoutCommands.export(export_path, layout_path)
assert(exported, "export failed: " .. tostring(export_note))
local export_content = read_layout(export_path)
equal(version_of(export_content), "4", "an export of a v4 layout is v4")
local _, _, _, _, exported_columns =
  LayoutStore.parse(export_content, real, "<export>")
equal(joined(exported_columns), joined(chosen), "an export carries the columns")
local imported, import_error = LayoutCommands.import(export_path, layout_path)
assert(imported, "import failed: " .. tostring(import_error))
local _, _, _, _, _, imported_columns = LayoutStore.load(real, layout_path)
equal(joined(imported_columns), joined(chosen),
  "an export/import round trip preserves the columns")

-- A v3 file imported into a session that has columns keeps its own version:
-- the import is faithful, and it is the next save that moves the file on.
local v3_orders, v3_trees, v3_workspaces, v3_active, v3_columns = LayoutStore.parse(
  LayoutStore.encode(real, nil, { default = trees_for(real) }, "default"), real, "<test>")
assert(v3_orders and v3_columns == nil, "a v3 file has no column set to import")
assert(v3_workspaces.default and v3_active == "default", "the v3 file is intact")

-- 9. The key is a top-level name, not a page.  One nested under a page is not
-- the top-level list, and the refusal says so -- the columns are checked
-- before the pages, so the reason is the missing list rather than a page body
-- that is not a tree.
refuse("schema_version: 4\npages:\n  overview:\n    process_columns:\n      - pid\n      - name\n",
  "process_columns must be a sequence", "a column list nested under a page")

remove_layout(export_path)
remove_layout(layout_path)

print("ok: persisted process columns")
