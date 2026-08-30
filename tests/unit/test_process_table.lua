package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Controller = require("wtop.model.process_table")

local function process(pid, starttime, fields)
  fields = fields or {}
  local value = {
    id = tostring(pid) .. ":" .. tostring(starttime),
    pid = pid,
    starttime_ticks = starttime,
    parent_pid = fields.parent_pid or 0,
    name = fields.name or ("p" .. tostring(pid)),
    command = fields.command,
    user = fields.user,
    state = fields.state or "S",
    cpu_percent = fields.cpu,
    resident_bytes = fields.memory,
    io = fields.io,
  }
  return value
end

local function ids(rows)
  local result = {}
  for index, row in ipairs(rows) do result[index] = row.id end
  return table.concat(result, ",")
end

-- Refreshes and reorderings retain the selected pid:starttime identity.
local a = process(10, 100, { cpu = 10 })
local b = process(20, 200, { cpu = 20 })
local c = process(30, 300, { cpu = 5 })
local controller = Controller.new({ sort_key = "cpu", descending = true })
controller:update({ a, b, c })
assert(ids(controller:rows()) == "20:200,10:100,30:300")
assert(controller:selected_id() == "20:200")
assert(controller:select_id("10:100"))
a.cpu_percent = 1
c.cpu_percent = 50
controller:update({ c, b, a })
assert(ids(controller:rows()) == "30:300,20:200,10:100")
assert(controller:selected_id() == "10:100")

-- If the generation disappears, select the row that moved into its old
-- visible position; clamp to the previous row at the end.
controller:set_sort("pid", false)
controller:select_id("20:200")
controller:update({ a, c })
assert(controller:selected_id() == "30:300")
controller:update({ a })
assert(controller:selected_id() == "10:100")
controller:update({ process(10, 999, { cpu = 1 }) })
assert(controller:selected_id() == "10:999", "a reused PID is a new selectable identity")

-- Movement is bounded and invalid deltas leave selection unchanged.
controller:update({ a, b, c })
controller:set_sort("pid", false)
controller:move(-100)
assert(controller:selected_id() == "10:100")
controller:move(100)
assert(controller:selected_id() == "30:300")
controller:move(-1.9)
assert(controller:selected_id() == "20:200")
controller:move(0 / 0)
assert(controller:selected_id() == "20:200")

-- Plain, bounded, case-insensitive filtering covers every documented field.
local searchable = {
  process(101, 1, { name = "Worker", command = "lua batch.lua", user = "alice", state = "R" }),
  process(202, 2, { name = "sshd", command = "sshd: bob", user = "root", state = "S" }),
}
controller:update(searchable)
controller:set_query("WORK")
assert(ids(controller:rows()) == "101:1")
controller:set_query("batch.lua")
assert(ids(controller:rows()) == "101:1")
controller:set_query("ROOT")
assert(ids(controller:rows()) == "202:2")
controller:set_query("202")
assert(ids(controller:rows()) == "202:2")
controller:set_query("R")
assert(#controller:rows() >= 1)
local limited_query = Controller.new({ max_query_bytes = 8, query = "abcdefghijk" })
assert(limited_query:status().query == "abcdefgh")
assert(limited_query:status().query_truncated and limited_query:status().query_bytes == 8)
limited_query:set_query("abc\255tail")
assert(limited_query:status().query == "abc" and limited_query:status().query_truncated)

-- Tree filtering retains the full chain of ancestors of a direct match.
local root = process(1, 1, { name = "init" })
local shell = process(2, 2, { parent_pid = 1, name = "shell" })
local child = process(3, 3, { parent_pid = 2, name = "worker", command = "needle task" })
local unrelated = process(4, 4, { parent_pid = 1, name = "other" })
local tree = Controller.new({ sort_key = "pid", tree = true, query = "needle" })
tree:update({ unrelated, child, root, shell })
assert(ids(tree:rows()) == "1:1,2:2,3:3")
assert(tree:rows()[1].tree_depth == 0 and tree:rows()[1].filter_ancestor)
assert(tree:rows()[2].tree_depth == 1 and tree:rows()[2].filter_ancestor)
assert(tree:rows()[3].tree_depth == 2 and tree:rows()[3].filter_match)
assert(tree:rows()[1].tree_has_children and tree:rows()[2].tree_has_children)
assert(tree:select_id("3:3"))
tree:set_query("")
assert(tree:selected_id() == "3:3")
assert(#tree:rows() == 4)
assert(tree:toggle_tree() == false and tree:selected_id() == "3:3")

-- Cycles are broken deterministically, orphans remain roots, and displayed
-- depth is capped without losing descendants.
local cyclic_a = process(10, 10, { parent_pid = 11 })
local cyclic_b = process(11, 11, { parent_pid = 10 })
local orphan = process(12, 12, { parent_pid = 999 })
local deep1 = process(21, 21, {})
local deep2 = process(22, 22, { parent_pid = 21 })
local deep3 = process(23, 23, { parent_pid = 22 })
local deep4 = process(24, 24, { parent_pid = 23 })
local guarded = Controller.new({ sort_key = "pid", tree = true, max_tree_depth = 2 })
guarded:update({ cyclic_b, deep4, orphan, deep2, cyclic_a, deep3, deep1 })
assert(#guarded:rows() == 7)
local seen = {}
local maximum_depth = 0
for _, row in ipairs(guarded:rows()) do
  assert(not seen[row.id], "cycle handling emitted a row twice")
  seen[row.id] = true
  maximum_depth = math.max(maximum_depth, row.tree_depth)
end
assert(maximum_depth == 2)
assert(guarded:status().cycles == 1)
assert(guarded:status().orphans == 1)
assert(guarded:status().depth_limited == 1)
assert(guarded:status().visible == 7 and guarded:status().total == 7)

-- Every sort puts missing values last; equal keys have a stable PID/id
-- tie-break independent of input order.
local values = {
  process(3, 3, { name = "same", cpu = nil, memory = 100, io = { read_bytes = 5, write_bytes = 90 } }),
  process(1, 1, { name = "same", cpu = 20, memory = nil, io = { read_bytes = 20 } }),
  process(2, 2, { name = "Beta", cpu = 20, memory = 300, io = { write_bytes = 40 } }),
}
local sorted = Controller.new({ sort_key = "cpu", descending = true })
sorted:update(values)
assert(ids(sorted:rows()) == "1:1,2:2,3:3")
sorted:update({ values[2], values[1], values[3] })
assert(ids(sorted:rows()) == "1:1,2:2,3:3")
assert(sorted:set_sort("memory", false))
assert(ids(sorted:rows()) == "3:3,2:2,1:1")
assert(sorted:set_sort("name", false))
assert(ids(sorted:rows()) == "2:2,1:1,3:3")
assert(sorted:set_sort("io_read", true))
assert(ids(sorted:rows()) == "1:1,3:3,2:2")
assert(sorted:set_sort("io_write", true))
assert(ids(sorted:rows()) == "3:3,2:2,1:1")
local before = sorted:selected_id()
assert(sorted:set_sort("bogus", true) == false)
assert(sorted:selected_id() == before and sorted:status().sort_key == "io_write")
local next_key, next_descending = sorted:cycle_sort()
assert(next_key == "cpu" and next_descending == true)

-- Missing and duplicate identities are accounted for, never selected twice.
local malformed = Controller.new({ sort_key = "pid", descending = false })
malformed:update({ {}, process(5, 5), process(5, 5) })
assert(#malformed:rows() == 1)
assert(malformed:status().invalid == 1 and malformed:status().duplicates == 1)
assert(Controller.stable_id({ pid = 7, starttime_ticks = 8 }) == "7:8")
assert(Controller.stable_id({ id = "stale", pid = 7, starttime_ticks = 9 }) == "7:9")
assert(Controller.stable_id({ id = string.rep("x", Controller.MAX_ID_BYTES + 1) }) == nil)
assert(Controller.stable_id({ id = "bad\27id" }) == nil)
assert(not pcall(Controller.new, "invalid"))

local unchanged_source = { process(40, 40, { cpu = 1 }) }
local unchanged = Controller.new()
assert(unchanged:update_if_changed(unchanged_source) == true)
local unchanged_revision = unchanged:status().revision
assert(unchanged:update_if_changed(unchanged_source) == false)
assert(unchanged:status().revision == unchanged_revision)
unchanged_source[1].cpu_percent = 99
unchanged:update(unchanged_source) -- explicit update always remains authoritative
assert(unchanged:rows()[1].cpu_percent == 99)
assert(unchanged:status().revision == unchanged_revision + 1)

-- High-cardinality flat views search the complete collected set but retain a
-- bounded, correctly ordered viewport model.
local many = {}
for pid = 1, 100 do
  many[pid] = process(pid, pid, { cpu = pid })
end
local bounded = Controller.new({ sort_key = "cpu", descending = true, max_rows = 10 })
bounded:update(many)
assert(#bounded:rows() == 10)
assert(bounded:rows()[1].pid == 100 and bounded:rows()[10].pid == 91)
assert(bounded:status().truncated and bounded:status().matched == 100
  and bounded:status().max_rows == 10)
bounded:set_query("1")
assert(bounded:status().matched == 20, "search must run before the row cap")
bounded:set_query("pid-does-not-exist")
assert(#bounded:rows() == 0 and bounded:status().matched == 0)

return true
