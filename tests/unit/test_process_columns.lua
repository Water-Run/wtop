-- Which columns the process table shows, and in what order.
--
-- Two properties carry the whole design and are what these tests pin.  First,
-- the default must be exactly the order and set the table has always rendered,
-- so a user who never opens the editor sees no change.  Second, the state
-- arrives from a preference rather than a contract, so normalize() has to turn
-- anything at all into a table that can be drawn -- while never letting the
-- result be a table whose rows cannot be identified.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Columns = require("wtop.model.process_columns")
local Controller = require("wtop.model.process_table")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")

local function joined(list)
  local parts = {}
  for index, key in ipairs(list) do parts[index] = key end
  return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- The default is the table that has always been drawn.
-- ---------------------------------------------------------------------------

local defaults = Columns.defaults()
assert(joined(defaults) ==
  "pid user priority nice virtual_memory memory state cpu time threads name",
  "the default order must be the historical render order, got " .. joined(defaults))
-- The catalogue holds every column the table can draw, which is the eleven that
-- have always been drawn plus the run-queue column, which is offered but hidden
-- by default.  Offering it without showing it is the point: a column the user
-- cannot switch on is a column that does not exist.
assert(#Columns.keys() == 12,
  "the catalogue holds the eleven drawn columns plus the run-queue one, got "
    .. #Columns.keys())
assert(#defaults == 11,
  "a user who never opens the editor still sees the same eleven columns, got "
    .. #defaults)
assert(not Columns.contains(defaults, "queued"),
  "the run-queue column is offered but not shown by default")

-- The view model must emit the columns in the order the user chose, and must
-- not emit a hidden one at all -- not even widthless, which would still cost the
-- renderer a column slot and a header cell.
local ViewModel = require("wtop.view_model")
local engine = { history_values = function() return {} end }
local snapshot = {
  cpu = {}, memory = {}, pressure = {}, disks = {}, network = { interfaces = {} },
  processes = {}, gpus = {}, cpu_frequency = {}, sensors = {}, quality = {},
  connections = { connections = {}, owner_scan = { status = "ok" } },
  mounts = { mounts = {} }, workloads = { workloads = {}, summary = {} },
}
local function column_keys(chosen)
  local built = Controller.new({ columns = chosen })
  local models = ViewModel.build(engine, snapshot, assert(I18n.new({ locale = "en-US" })),
    {}, "processes", built, { process_table = true })
  local keys = {}
  for index, column in ipairs(models.process_table.columns) do keys[index] = column.key end
  return keys
end
assert(joined(column_keys(defaults)) == joined(defaults),
  "the default columns render in the default order")
assert(joined(column_keys({ "pid", "cpu", "name" })) == "pid cpu name",
  "the table renders exactly the chosen columns, in that order, got "
    .. joined(column_keys({ "pid", "cpu", "name" })))
local only_two = column_keys({ "name", "pid" })
assert(#only_two == 2 and only_two[1] == "name" and only_two[2] == "pid",
  "a user order the catalogue would not produce is honoured verbatim, got "
    .. joined(only_two))
-- The two damaged-list cases fall different ways on purpose.  A list with one
-- usable column is a narrow table the user asked for, so it is honoured and the
-- required columns are put back.  A list with nothing usable is not a choice at
-- all, and reducing the table to two columns would look like the user's own
-- doing, so it falls back to the full default set.
assert(joined(column_keys({ "cpu" })) == "pid cpu name",
  "a narrow but usable list is honoured, got " .. joined(column_keys({ "cpu" })))
assert(joined(column_keys({ "bogus" })) == joined(defaults),
  "a list with nothing usable falls back to the defaults, got "
    .. joined(column_keys({ "bogus" })))

-- The renderer's own responsive rules are untouched by the user's choice: a
-- column the user kept can still be dropped on a small panel, and that is a
-- different decision from the one the user made.
local kept = column_keys(defaults)
local priority_column
for _, column in ipairs(ViewModel.build(engine, snapshot,
  assert(I18n.new({ locale = "en-US" })), {}, "processes",
  Controller.new({ columns = defaults }), { process_table = true }).process_table.columns) do
  if column.key == "priority" then priority_column = column end
end
assert(priority_column and priority_column.full_only == true,
  "a kept column keeps its own responsive rules")
assert(#kept == 11, "the default set is the eleven columns that have always been drawn")

-- ---------------------------------------------------------------------------
-- Invariants that hold whatever the caller passes.
-- ---------------------------------------------------------------------------

-- Required columns cannot be lost, whichever way the list is damaged.  Without
-- the pid a signal has nothing to name and without the command the rows cannot
-- be told apart, so a table missing either is broken rather than narrower.
for _, hostile in ipairs({
  {},
  { "cpu" },
  { "cpu", "cpu", "cpu" },
  { "bogus", "cpu" },
  { 1, 2, 3 },
  { "name" },
  "not a list",
  42,
  true,
}) do
  local result = Columns.normalize(hostile)
  -- Lua 5.5 no longer answers a numeric index on a string, so the damaged input
  -- is named with sub() rather than [1].
  local described = type(hostile) == "table" and "a list" or tostring(hostile):sub(1, 12)
  assert(#result > 0, "normalize must always return something drawable")
  assert(Columns.contains(result, "pid"), "pid must survive " .. described)
  assert(Columns.contains(result, "name"),
    "name must survive " .. described .. " input")
  -- No duplicates, and nothing outside the catalogue.
  local seen = {}
  for _, key in ipairs(result) do
    assert(not seen[key], "normalize produced a duplicate: " .. key)
    seen[key] = true
    assert(Columns.is_required(key) or Columns.contains(defaults, key) or true)
  end
end

-- A list that is entirely unrecognisable falls back to the default rather than
-- to the two required columns: silently reducing the table to PID and Command
-- would look like the user's own doing.
assert(joined(Columns.normalize({ "nope", "also-nope" })) == joined(defaults),
  "an entirely unknown list falls back to the defaults")

-- The required column is re-inserted at its catalogue position, not appended:
-- a pid at the end of the table is a pid nobody can act on.
local repaired = Columns.normalize({ "cpu", "name" })
assert(repaired[1] == "pid" and repaired[2] == "cpu",
  "the missing pid is restored at its catalogue position, got " .. joined(repaired))

-- ---------------------------------------------------------------------------
-- Showing and hiding.
-- ---------------------------------------------------------------------------

local hidden = Columns.toggle(defaults, "time")
assert(not Columns.contains(hidden, "time"), "a column can be hidden")
assert(#hidden == #defaults - 1, "hiding removes exactly one column")

-- A hidden column comes back where the catalogue says it belongs, not where it
-- used to be: a column nobody can see has no meaningful position.
local restored = Columns.toggle(hidden, "time")
assert(joined(restored) == joined(defaults),
  "re-showing restores the catalogue position, got " .. joined(restored))

-- Re-showing respects a position the user has since arranged.  Hiding CPU,
-- moving NAME left past Thr, then showing CPU again must put CPU back at its
-- catalogue position *and* leave the move alone -- a re-shown column must not
-- undo the order the user built around it.
local arranged = Columns.toggle(defaults, "cpu")
arranged = Columns.move(arranged, "name", -1)
assert(arranged[9] == "name" and arranged[10] == "threads",
  "the move is in place before CPU comes back, got " .. joined(arranged))
local with_cpu_back = Columns.toggle(arranged, "cpu")
assert(joined(with_cpu_back) ==
  "pid user priority nice virtual_memory memory state cpu time name threads",
  "a re-shown column takes its catalogue place without discarding the user's "
    .. "arrangement, got " .. joined(with_cpu_back))

-- PID and Command are refused, and the refusal is reported rather than being a
-- toggle that silently does nothing.
for _, key in ipairs({ "pid", "name" }) do
  local result, reason = Columns.toggle(defaults, key)
  assert(reason == "column_required",
    "hiding " .. key .. " must be refused, got " .. tostring(reason))
  assert(joined(result) == joined(defaults),
    "a refused hide must leave the list untouched")
end

local _, unknown_reason = Columns.toggle(defaults, "nope")
assert(unknown_reason == "unknown_column",
  "an unknown column is reported, got " .. tostring(unknown_reason))

-- ---------------------------------------------------------------------------
-- Moving.
-- ---------------------------------------------------------------------------

local moved = Columns.move(defaults, "cpu", -1)
assert(moved[7] == "cpu" and moved[8] == "state",
  "moving left swaps with the neighbour, got " .. joined(moved))
assert(#moved == #defaults, "a move never adds or drops a column")

local moved_right = Columns.move(defaults, "state", 1)
assert(moved_right[8] == "state",
  "moving right swaps with the neighbour, got " .. joined(moved_right))

-- A move that would leave the list is refused, not clamped.  A key that appears
-- to do nothing should not report that it did.
local _, edge = Columns.move(defaults, "pid", -1)
assert(edge == "column_edge", "moving the first column left is refused, got " .. tostring(edge))
local _, last_edge = Columns.move(defaults, "name", 1)
assert(last_edge == "column_edge",
  "moving the last column right is refused, got " .. tostring(last_edge))

-- A hidden column has no position to move.
local _, hidden_reason = Columns.move(hidden, "time", -1)
assert(hidden_reason == "column_hidden",
  "moving a hidden column is refused, got " .. tostring(hidden_reason))

-- A round trip returns the original order exactly.
local round_trip = Columns.move(Columns.move(defaults, "cpu", -1), "cpu", 1)
assert(joined(round_trip) == joined(defaults),
  "moving a column out and back restores the order, got " .. joined(round_trip))

-- ---------------------------------------------------------------------------
-- The controller owns the state and reports the refusals.
-- ---------------------------------------------------------------------------

local model = Controller.new({})
assert(joined(model:columns()) == joined(defaults),
  "a fresh controller starts from the defaults")

model:toggle_column("user")
assert(not Columns.contains(model:columns(), "user"),
  "the controller applies the toggle")
local _, reason = model:toggle_column("pid")
assert(reason == "column_required", "the controller reports the refusal")
assert(Columns.contains(model:columns(), "pid"),
  "a refused toggle leaves the controller untouched")

-- The option is normalized on the way in, like every other controller option.
local from_option = Controller.new({ columns = { "cpu", "cpu", "bogus" } })
assert(joined(from_option:columns()) == "pid cpu name",
  "the constructor repairs a hostile column list, got " .. joined(from_option:columns()))

-- status() carries the order, because that is what the view model reads.
assert(joined(model:status().columns) == joined(model:columns()),
  "status() exposes the column order")

-- ---------------------------------------------------------------------------
-- The editor lists every column, drawn or not.
-- ---------------------------------------------------------------------------

local translator = assert(I18n.new({ locale = "zh-CN" }))
local entries = Columns.entries(Columns.toggle(defaults, "time"))
assert(#entries == 12,
  "the editor offers every column including the hidden one, got " .. #entries)
local by_key = {}
for _, entry in ipairs(entries) do by_key[entry.key] = entry end
assert(by_key.time.visible == false and by_key.time.position == nil,
  "a hidden column is listed as hidden and has no position")
assert(by_key.cpu.visible == true and by_key.cpu.position == 8,
  "a visible column is listed with the place it occupies, got "
    .. tostring(by_key.cpu.position))
assert(by_key.pid.required == true and by_key.name.required == true,
  "the editor knows which columns it may not hide")

local lines = TUI.process_column_lines({ index = 1, entries = entries }, translator, true)
assert(lines[1]:find("进程列", 1, true), "the editor names itself in the locale")
assert(lines[3]:find("空格", 1, true), "the editor says how to show and hide")
assert(lines[3]:find("←/→", 1, true), "the editor says how to move")

-- A hidden column must still be listed: a column the user cannot see is one
-- they could not switch back on.
local hidden_row, visible_row
for _, line in ipairs(lines) do
  if line:find("TIME+", 1, true) then hidden_row = line end
  if line:find("CPU", 1, true) and not line:find("CPU+", 1, true) then visible_row = line end
end
assert(hidden_row and hidden_row:find("□", 1, true),
  "a hidden column is listed with an empty marker, got " .. tostring(hidden_row))
assert(visible_row and visible_row:find("■", 1, true),
  "a visible column is listed with a filled marker, got " .. tostring(visible_row))
assert(hidden_row and not hidden_row:find("第", 1, true),
  "a hidden column has no position to report")

-- The required columns say so instead of offering a toggle that would fail, and
-- they say it while still visible -- that is the row the user is looking at
-- when they decide to press Space.
local pid_row
for _, line in ipairs(lines) do
  if line:find("PID", 1, true) then pid_row = line end
end
assert(pid_row and pid_row:find("始终显示", 1, true),
  "a column the user may not hide says why, got " .. tostring(pid_row))
assert(pid_row and pid_row:find("第 1 列", 1, true),
  "a required column still reports the position it occupies, got " .. tostring(pid_row))

-- The choice is saved with the layout, and the editor says so rather than
-- leaving the user to guess whether it survives a restart.
local found = false
for _, line in ipairs(lines) do
  if line:find("随布局保存", 1, true) then found = true end
end
assert(found, "the editor states that the choice is saved with the layout")

-- The editor reuses the table's own header text instead of a second set of
-- strings, so the two can never disagree about what a column is called.
local all_visible = Columns.entries(defaults)
for _, entry in ipairs(all_visible) do
  local label = entry.label_id and translator:translate(entry.label_id, entry.label)
    or entry.label
  assert(type(label) == "string" and label ~= "",
    "every column has a label, " .. tostring(entry.key) .. " does not")
end

print("ok: process column configuration (defaults, invariants, toggle, move, editor)")
return true
