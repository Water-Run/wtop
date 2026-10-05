-- Reaching from a workload into the process table.  cgroup.procs is read for
-- every node already, so the member set exists; this file is the proof that
-- it narrows the process table, that the narrowing is visible and reversible,
-- and that the process detail names the cgroup it lives in.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local ProcessTable = require("wtop.model.process_table")
local Semantics = require("wtop.collectors.cgroup_semantics")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local ViewModel = require("wtop.view_model")

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      message, tostring(expected), tostring(actual)), 0)
  end
end

local function process(pid, name)
  return {
    pid = pid, starttime_ticks = pid * 10,
    name = name or ("proc" .. pid), command = name or ("proc" .. pid),
    user = "root", state = "S", cpu_percent = 1, resident_bytes = 1024,
    cpu_ticks = 10, parent_pid = 1, threads = 1,
  }
end

local function processes()
  return {
    process(1, "systemd"), process(2, "sshd"), process(7, "docker-init"),
    process(9, "nginx"), process(42, "worker"), process(4300, "render"),
  }
end

-- Setting the filter keeps exactly the cgroup's members, in their own order.
local controller = ProcessTable.new({})
controller:update(processes())
equal(#controller:rows(), 6, "every process is listed before filtering")
equal(controller:status().cgroup_filter, nil, "no cgroup filter at first")

local accepted, size = controller:set_pid_filter({ 7, 9, 42 }, "docker 8a1bcccc1234")
equal(accepted, true, "the filter is accepted")
equal(size, 3, "three members were offered")
local status = controller:status()
equal(status.cgroup_filter, "docker 8a1bcccc1234", "the filter announces which cgroup it is")
equal(status.cgroup_filter_size, 3, "the filter reports its size")
equal(status.visible, 3, "only the members are visible")
equal(status.total, 6, "the collection itself is unchanged")
local pids = {}
for _, row in ipairs(controller:rows()) do pids[row.pid] = true end
equal(pids[7] == true and pids[9] == true and pids[42] == true, true,
  "the three members are visible")
equal(pids[1] == nil and pids[4300] == nil, true, "processes outside the cgroup are not")

-- The cursor lands inside the set the user just asked for, not on the row the
-- selection happened to be on before.
equal(controller:selected().pid, 7, "the selection starts at the first member")

-- A member set is bounded by what cgroup.procs actually reported, and the
-- duplicates and non-integers a racing procfs read can produce must not widen
-- it or crash it.
local noisy = ProcessTable.new({})
noisy:update(processes())
equal(select(1, noisy:set_pid_filter({ 1, 1, 2.5, -3, 0, "9", 4300 }, "odd")),
  true, "a noisy member set is still accepted")
equal(noisy:status().cgroup_filter_size, 2, "only whole positive pids count")
equal(noisy:status().visible, 2, "the two real pids are visible")

-- An empty set clears the filter instead of hiding every row behind a name
-- the user would have to guess to undo.
local empty = ProcessTable.new({})
empty:update(processes())
equal(select(1, empty:set_pid_filter({}, "docker gone")), false,
  "an empty member set is refused")
equal(empty:status().cgroup_filter, nil, "no filter survives an empty set")
equal(empty:status().visible, 6, "every row is still listed")
equal(select(1, empty:set_pid_filter({ "x", 2.5, -1, 0, nil }, "all noise")), false,
  "a set with no usable pid is refused too")
equal(empty:status().visible, 6, "a refused set leaves the table alone")

-- Reversing the filter restores exactly the previous view, selection included.
local before_id = controller:selected_id()
equal(controller:clear_pid_filter(), true, "the filter clears")
status = controller:status()
equal(status.cgroup_filter, nil, "the announcement is gone")
equal(status.visible, 6, "every row is back")
equal(controller:selected_id(), before_id, "the selection survives clearing")
equal(controller:clear_pid_filter(), false, "clearing twice is a no-op")

-- A cgroup filter intersects with a search rather than replacing it: the
-- filter says which cgroup, the query says which of its processes.
controller:set_pid_filter({ 7, 9, 42, 4300 }, "docker 8a1bcccc1234")
controller:set_query("nginx")
equal(controller:status().visible, 1, "the search narrows within the cgroup")
equal(controller:rows()[1].pid, 9, "the surviving row is the one that matched")
controller:set_query("")
equal(controller:status().visible, 4, "clearing the search restores the cgroup")
controller:clear_pid_filter()

-- A search that matches nothing inside the cgroup shows nothing, rather than
-- falling back to the unfiltered table.
controller:set_pid_filter({ 7, 9, 42 }, "docker 8a1bcccc1234")
controller:set_query("definitely-not-here")
equal(controller:status().visible, 0, "an empty intersection is empty")
controller:set_query("")
controller:clear_pid_filter()

-- Tree mode keeps the ancestor chain, the same way a search does, so a
-- cgroup's processes are still readable under their parents.
local tree = ProcessTable.new({ tree = true })
tree:update(processes())
tree:set_pid_filter({ 42 }, "docker 8a1bcccc1234")
equal(tree:status().visible > 1, true,
  "the parent chain is kept so the match is readable")
local found = false
for _, row in ipairs(tree:rows()) do
  if row.pid == 42 then found = true end
end
equal(found, true, "the member is present in tree mode")
tree:clear_pid_filter()
equal(tree:status().visible, 6, "clearing restores the whole tree")

-- The status line says why the rows ended, because nothing else does.
local translator = assert(I18n.new({ locale = "en-US" }))
local engine = { history_values = function() return {} end }
local function status_text(controller_instance)
  local snapshot = {
    schema = "dev.waterrun.wtop.snapshot/v1",
    timestamp_ns = 1, sequence = 1,
    quality = { processes = { status = "ok", quality = "fresh" } },
    processes = { list = processes(), clock_ticks_per_second = 100 },
  }
  local model = ViewModel.build(engine, snapshot, translator, {}, "processes",
    controller_instance)
  return model.process_table.status_text
end
controller:set_pid_filter({ 7, 9, 42 }, "docker 8a1bcccc1234")
local text = status_text(controller)
equal(text:find("cgroup: docker 8a1bcccc1234", 1, true) ~= nil, true,
  "the status line names the cgroup: " .. tostring(text))
equal(text:find("Esc clears", 1, true) ~= nil, true,
  "the status line says how to undo it: " .. tostring(text))
controller:clear_pid_filter()
text = status_text(controller)
equal(text:find("cgroup:", 1, true), nil, "clearing removes the segment: " .. tostring(text))

-- The process detail names the cgroup it lives in, not just its raw path.
local DOCKER_ID = "8a1bcccc1234567890abcdef0123456789abcdef0123456789abcdef01234567"
local overlay = TUI.process_detail_lines({
  pid = 7, name = "docker-init", command = "/usr/bin/docker-init", user = "root",
  state = "S", cpu_ticks = 42, threads = 1, resident_bytes = 1024,
  cgroups = { { path = "/system.slice/docker-" .. DOCKER_ID .. ".scope" } },
}, translator)
local joined = table.concat(overlay, "\n")
equal(joined:find("docker 8a1bcccc1234", 1, true) ~= nil, true,
  "the detail names the container: " .. joined)
equal(joined:find("/system.slice/docker-" .. DOCKER_ID .. ".scope", 1, true) ~= nil, true,
  "the detail keeps the path the kernel reported")
-- The path already contains the full unit, so a second copy of it is noise.
local path_lines = 0
for line in joined:gmatch("[^\n]+") do
  if line:find("/system.slice/docker-" .. DOCKER_ID .. ".scope", 1, true) then
    path_lines = path_lines + 1
  end
end
equal(path_lines, 1, "the path is shown exactly once: " .. joined)

-- A cgroup wtop cannot classify still shows its path, and a service whose unit
-- name is already its last path component is not decorated with a copy of it.
local service = table.concat(TUI.process_detail_lines({
  pid = 1, name = "systemd", command = "/usr/lib/systemd/systemd", user = "root",
  state = "S", cpu_ticks = 42, threads = 1, resident_bytes = 1024,
  cgroups = { { path = "/system.slice/sshd.service" } },
}, translator), "\n")
local service_lines = 0
for line in service:gmatch("[^\n]+") do
  if line:find("/system.slice/sshd.service", 1, true) then service_lines = service_lines + 1 end
end
equal(service_lines, 1, "a plain service is one line: " .. service)
equal(service:find("\nsshd.service", 1, true), nil,
  "a plain service is not decorated with its own name: " .. service)

-- The classification used by the overlay is the same one the collector uses,
-- so the two cannot drift apart.
local classified = Semantics.classify("/system.slice/docker-" .. DOCKER_ID .. ".scope")
equal(classified.label, "docker 8a1bcccc1234", "one classifier, one answer")
equal(joined:find(classified.label, 1, true) ~= nil, true,
  "the overlay shows exactly what the collector classified")

print("ok: cgroup to process cross-linking")
