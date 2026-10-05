-- Which columns the process table shows, and in what order.
--
-- The table's column set is a user decision, not a property of the data: an
-- operator triaging CPU wants CPU and TIME and nothing else, while one watching
-- memory wants the resident column where it cannot be missed.  The columns
-- themselves, their widths, their priorities and the renderer's responsive
-- rules all belong to the view; this module owns only the user's choice, and
-- keeps it separate so the two mechanisms cannot be confused:
--
--   * `full_only` and `priority` in the view model decide what a *small panel*
--     drops.  That is the renderer's call and it still applies.
--   * the order and the visibility held here decide what the user has chosen.
--     A column the user hid is never drawn, at any size.
--
-- The state is the ordered list of the columns that are visible.  That is also
-- the render order, so there is no second list to keep consistent with the
-- first.  A hidden column reappears at its catalogue position rather than
-- where it used to be: a column nobody can see has no meaningful position, and
-- remembering one would only make the result depend on the order in which the
-- user happened to toggle things.
--
-- Two columns are not the user's to hide.  Without the pid the rows cannot be
-- acted on -- a signal has to name one -- and without the command they cannot
-- be told apart.  A table of numbers with no way to identify a row is not a
-- narrower table, it is a broken one, so the invariant is enforced here rather
-- than left to the editor to remember.
local M = {}

-- The catalogue order is also the default.  It is deliberately the order the
-- columns have always rendered in, so a user who never opens the editor sees no
-- change at all.
--
-- `label_id` names an existing catalogue key where the table header is already
-- translated, and is nil where the header is a fixed abbreviation the view has
-- always drawn untranslated (PID, PRI, NI, S, CPU, TIME+).  The editor therefore
-- shows exactly the header the table shows, without a second set of strings to
-- keep in step with the first -- and without turning a fixed abbreviation into
-- translated prose as a side effect of adding an editor.
local CATALOGUE = {
  { key = "pid", required = true, label = "PID" },
  { key = "user", default_visible = true, label_id = "metrics.user", label = "User" },
  { key = "priority", default_visible = true, label = "PRI" },
  { key = "nice", default_visible = true, label = "NI" },
  { key = "virtual_memory", default_visible = true,
    label_id = "metrics.virtual", label = "Virt" },
  { key = "memory", default_visible = true, label_id = "metrics.memory", label = "Res" },
  { key = "state", default_visible = true, label = "S" },
  { key = "cpu", default_visible = true, label = "CPU" },
  { key = "time", default_visible = true, label = "TIME+" },
  { key = "threads", default_visible = true, label_id = "metrics.threads", label = "Thr" },
  { key = "name", required = true, label_id = "metrics.command", label = "Command" },
  -- Hidden by default.  Run-queue wait is read only for the rows the viewport
  -- is showing, so a row that has just scrolled into view has no reading for a
  -- tick; adding this to the default set would therefore ship a column that is
  -- blank for the first second after every scroll, for every user, to answer a
  -- question only some of them have.
  { key = "queued", label_id = "process.thread_queued", label = "Queued" },
}

local INDEX = {}
for position, entry in ipairs(CATALOGUE) do INDEX[entry.key] = position end

-- A stored list comes from a file a user can edit, so it is repaired rather
-- than trusted: unknown keys are dropped, duplicates collapse to their first
-- occurrence, a required column that went missing is put back at its catalogue
-- position, and a list that is not a list at all falls back to the defaults.
-- The repair is total -- normalize always returns a usable list -- because a
-- table that cannot be rendered is worse than one that renders the wrong
-- columns.
function M.normalize(value)
  local defaults = M.defaults()
  if type(value) ~= "table" then return defaults end
  local seen, result = {}, {}
  for _, key in ipairs(value) do
    if type(key) == "string" and INDEX[key] and not seen[key] then
      seen[key] = true
      result[#result + 1] = key
    end
  end
  if #result == 0 then return defaults end
  -- Re-insert the required columns at their catalogue positions so a hand-edited
  -- file that dropped them, or dropped the ones around them, still renders a
  -- table whose rows can be identified.
  for position, entry in ipairs(CATALOGUE) do
    if entry.required and not seen[entry.key] then
      local at = #result + 1
      for index, key in ipairs(result) do
        if INDEX[key] > position then
          at = index
          break
        end
      end
      table.insert(result, at, entry.key)
      seen[entry.key] = true
    end
  end
  return result
end

function M.defaults()
  local result = {}
  for _, entry in ipairs(CATALOGUE) do
    if entry.default_visible or entry.required then result[#result + 1] = entry.key end
  end
  return result
end

local function index_of(list, key)
  for index, item in ipairs(list) do
    if item == key then return index end
  end
  return nil
end

-- Every column the editor offers, in catalogue order, each carrying whether it
-- is currently drawn.  The editor shows hidden columns too: a column the user
-- cannot see is a column they cannot switch back on.
function M.entries(visible)
  local state = M.normalize(visible)
  local shown = {}
  for _, key in ipairs(state) do shown[key] = true end
  local result = {}
  for _, entry in ipairs(CATALOGUE) do
    result[#result + 1] = {
      key = entry.key,
      visible = shown[entry.key] == true,
      required = entry.required == true,
      position = shown[entry.key] and index_of(state, entry.key) or nil,
      label_id = entry.label_id,
      label = entry.label or entry.key,
    }
  end
  return result
end

function M.is_required(key)
  local entry = INDEX[key] and CATALOGUE[INDEX[key]] or nil
  return entry ~= nil and entry.required == true
end

function M.contains(list, key)
  return index_of(M.normalize(list), key) ~= nil
end

-- Showing or hiding a column.  Hiding a required column is refused rather than
-- applied, and the refusal is reported so the editor can say why nothing
-- changed instead of appearing to have a broken toggle.
function M.toggle(visible, key)
  local state = M.normalize(visible)
  if not INDEX[key] then return state, "unknown_column" end
  local at = index_of(state, key)
  if at then
    if M.is_required(key) then return state, "column_required" end
    table.remove(state, at)
    return state
  end
  -- Reappears where the catalogue says it belongs: before the first visible
  -- column that comes after it.
  local position, insert_at = INDEX[key], #state + 1
  for index, item in ipairs(state) do
    if INDEX[item] > position then
      insert_at = index
      break
    end
  end
  table.insert(state, insert_at, key)
  return state
end

-- Moves a column one place left or right.  A move that would leave the list is
-- refused rather than clamped silently, because a key that appears to do
-- nothing should not report that it did.
function M.move(visible, key, direction)
  local state = M.normalize(visible)
  local at = index_of(state, key)
  if not at then return state, "column_hidden" end
  local target = direction < 0 and at - 1 or at + 1
  if target < 1 or target > #state then return state, "column_edge" end
  state[at], state[target] = state[target], state[at]
  return state
end

M.catalogue = CATALOGUE
M.keys = function()
  local result = {}
  for _, entry in ipairs(CATALOGUE) do result[#result + 1] = entry.key end
  return result
end

return M
