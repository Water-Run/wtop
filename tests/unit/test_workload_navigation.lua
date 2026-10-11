-- Workload-page navigation: collapsed subtrees hide their rows, the cursor
-- indexes the visible set, and the detail panel follows the selection.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")
local Navigation = require("wtop.model.workload_navigation")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

local function workload(id, parent_id, depth, name)
  return {
    id = id, parent_id = parent_id, depth = depth, name = name or id,
    path = "/sys/fs/cgroup" .. id,
    cpu = { utilization_percent = depth * 10 },
    memory = { current_bytes = depth * 1024 },
    io = { totals = { rates = { rbytes_per_second = 10, wbytes_per_second = 20 } } },
    pressure = { cpu = { some = { avg10 = 0.5 } } },
    processes = { count = depth },
    quality = "fresh",
  }
end

local snapshot = {
  cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, processes = {},
  cpu_frequency = {}, mounts = {}, connections = {}, quality = {}, sensors = {},
  gpus = {},
  workloads = {
    kind = "cgroup2",
    workloads = {
      workload("/", nil, 0, "root"),
      workload("/system", "/", 1),
      workload("/system/slice-a", "/system", 2),
      workload("/system/slice-a/deep", "/system/slice-a", 3),
      workload("/user", "/", 1),
    },
    summary = { root = { cpu_utilization_percent = 12 } },
  },
}
local engine = { history_values = function() return {} end }
local translator = assert(I18n.new({ locale = "en-US" }))

local function build(options)
  return ViewModel.build(engine, snapshot, translator, {}, "workloads",
    nil, nil, options)
end

-- 1. Plain rows: every node visible, children carry the expanded marker.
local plain = build({})
equal(#plain.workload_table.rows, 5, "all workload rows visible by default")
assert(plain.workload_table.rows[2].workload:find("▾", 1, true),
  "a node with children shows the expanded marker")
assert(plain.workload_table.rows[5].workload:find("·", 1, true),
  "a leaf shows the leaf marker")

-- 2. Collapsing a node hides its whole subtree, not just direct children.
local collapsed = build({ workload_collapsed = { ["/system"] = true } })
equal(#collapsed.workload_table.rows, 3, "the subtree is hidden entirely")
assert(collapsed.workload_table.rows[2].workload:find("▸", 1, true),
  "a collapsed node shows the collapsed marker")
equal(collapsed.workload_table.ids[3], "/user",
  "the visible id list skips the hidden subtree")

-- 3. The selection indexes the visible rows only.
local selected = build({ workload_collapsed = { ["/system"] = true },
  workload_selected = "/user" })
equal(selected.workload_table.selected, 3, "the cursor points at the visible row")

-- Search reveals a match inside a folded branch without changing the stored
-- fold state. The parent chain remains visible so the result has context.
local search_folded = { ["/system"] = true }
local found = build({ workload_collapsed = search_folded,
  workload_selected = "/user", workload_query = "DEEP" })
equal(#found.workload_table.rows, 4, "matching descendants and ancestors are visible")
equal(found.workload_table.ids[4], "/system/slice-a/deep", "deep match reached")
equal(found.workload_table.selected, 4, "a hidden old selection moves to the first match")
assert(found.workload_table.rows[2].workload:find("▾", 1, true),
  "a folded ancestor appears expanded during the search")
assert(found.workload_table.status_text:find("1 matches", 1, true))
assert(search_folded["/system"], "search does not mutate the prior fold choice")
local restored = build({ workload_collapsed = search_folded })
equal(#restored.workload_table.rows, 3, "clearing search restores the fold")
local empty_search = build({ workload_query = "wt0absent",
  workload_selected = "/user" })
equal(#empty_search.workload_table.rows, 0, "unmatched search has no stale row")
assert(empty_search.workload_detail.entries[1].section ~= "Selection",
  "the detail panel does not keep a selection hidden by the search")
snapshot.workloads.workloads[4].semantics = { label = "Container Worker" }
local labeled = build({ workload_query = "container worker" })
equal(labeled.workload_table.ids[4], "/system/slice-a/deep",
  "the displayed semantic label is searchable")
snapshot.workloads.workloads[4].semantics = nil
local hot = build({ workload_query = "cpu>25 procs>2" })
equal(hot.workload_table.ids[4], "/system/slice-a/deep",
  "CPU and process-count comparisons combine before ancestor expansion")
equal(hot.workload_table.selected, 4, "the first numeric match becomes selected")
local memory_cutoff = build({ workload_query = "mem>=2K cpu>=20" })
assert(memory_cutoff.workload_table.status_text:find("2 matches", 1, true),
  "byte suffixes and inclusive comparisons count direct matches")
snapshot.workloads.workloads[4].io.totals.rates.rbytes_per_second = 2 * 1048576
local io_cutoff = build({ workload_query = "read>1M" })
equal(io_cutoff.workload_table.ids[4], "/system/slice-a/deep",
  "I/O rate comparisons use bytes per second")
local write_pressure = build({ workload_query = "write>=20 pressure>0.1" })
assert(write_pressure.workload_table.status_text:find("5 matches", 1, true),
  "write rate and CPU pressure use their measured units")
local percent_cutoff = build({ workload_query = "cpu>=20% !name:deep" })
assert(percent_cutoff.workload_table.status_text:find("1 matches", 1, true)
  and percent_cutoff.workload_table.ids[3] == "/system/slice-a",
  "percent syntax and negated text narrow the workload tree")
equal(#build({ workload_query = "threads>0" }).workload_table.rows, 0,
  "missing thread counts are not zero")
equal(#build({ workload_query = "!threads>0" }).workload_table.rows, 0,
  "negating a missing number still does not claim a measurement")
snapshot.workloads.workloads[4].semantics = { unit = "example.service" }
local unit_cutoff = build({ workload_query = "unit:example.service cpu>25" })
equal(unit_cutoff.workload_table.ids[4], "/system/slice-a/deep",
  "semantic unit and numeric condition intersect")
snapshot.workloads.workloads[4].semantics = nil
equal(#build({ workload_query = "cpu>bogus" }).workload_table.rows, 0,
  "an invalid numeric expression remains literal")

-- 4. The detail panel follows the selection instead of the root summary.
local detail = selected.workload_detail.entries
local labels = {}
for _, entry in ipairs(detail) do labels[#labels + 1] = tostring(entry.label) end
assert(#detail > 0 and detail[1].section == "Selection",
  "detail starts with a selection section")
local found_path = false
for _, entry in ipairs(detail) do
  if entry.value == "/sys/fs/cgroup/user" then found_path = true end
end
assert(found_path, "the detail panel shows the selected workload's path")

-- 5. Without a selection the root summary stays, as before.
local root_detail = build({}).workload_detail.entries
assert(#root_detail > 0, "root summary detail still renders without a selection")

-- A process can name the exact unified cgroup it belongs to.  A v1 path is
-- not an identity for the v2 tree, and two conflicting unified paths are not
-- grounds to pick one arbitrarily.
local member = { pid = 42, starttime_ticks = 4096, cgroups = {
  { hierarchy = 2, controllers = "cpu", path = "/different" },
  { hierarchy = 0, controllers = "", path = "/system/slice-a/deep" },
} }
equal(Navigation.target_id(member, "cgroup2"), "/system/slice-a/deep",
  "unified cgroup path is the Linux workload identity")
assert(Navigation.target_id({ cgroups = {
  { hierarchy = 2, controllers = "cpu", path = "/different" },
} }, "cgroup2") == nil)
assert(Navigation.target_id({ cgroups = {
  { hierarchy = 0, controllers = "", path = "/a" },
  { hierarchy = 0, controllers = "", path = "/b" },
} }, "cgroup2") == nil)
local collapsed_chain = { ["/system"] = true, ["/system/slice-a"] = true,
  ["/user"] = true }
assert(Navigation.expand_ancestors(snapshot.workloads, "/system/slice-a/deep",
  collapsed_chain))
assert(not collapsed_chain["/system"] and not collapsed_chain["/system/slice-a"]
  and collapsed_chain["/user"], "only the target's ancestors are expanded")
assert(Navigation.find(snapshot.workloads, "/system/slice-a/deep")
  == snapshot.workloads.workloads[4])
assert(Navigation.find(snapshot.workloads, "/missing") == nil)
local prior = { status = "ok" }
assert(select(2, Navigation.result(snapshot.workloads, prior, "/missing", prior))
  == "pending", "an old workload sample cannot disprove a new membership")
assert(select(2, Navigation.result(snapshot.workloads, { status = "ok" },
  "/missing", prior)) == "missing", "a new sample can settle absence")
assert(select(2, Navigation.result(snapshot.workloads, prior,
  "/system/slice-a/deep", prior)) == "found", "a present node can be used now")

-- Windows service-host IDs include creation time.  A PID alone is not enough
-- to navigate to a host that may have been replaced.
equal(Navigation.target_id(member, "service"), "service:42:4096")
local process = { id = "42:4096", pid = 42, starttime_ticks = 4096,
  cgroups = { { hierarchy = 0, controllers = "", path = "/process" } } }
local thread = { tid = 44, starttime_ticks = 4100 }
local detail = { tid = 44, starttime_ticks = 4100, tgid = 42,
  cgroups = { { hierarchy = 0, controllers = "", path = "/thread" } } }
local selection = { mode = "detail", process_id = process.id,
  tid = 44, starttime_ticks = 4100 }
equal(Navigation.thread_target_id(process, thread, detail, selection), "/thread",
  "thread navigation follows the selected TID's own cgroup")
assert(Navigation.thread_target_id(process, thread, nil, selection) == nil,
  "a pending thread read must not fall back to the process cgroup")
assert(Navigation.thread_target_id(process, thread, detail,
  { mode = "detail", process_id = "42:old", tid = 44, starttime_ticks = 4100 }) == nil)
assert(Navigation.thread_target_id(process, thread,
  { tid = 44, starttime_ticks = 4101, cgroups = detail.cgroups }, selection) == nil,
  "a recycled TID cannot inherit its prior cgroup target")
assert(Navigation.thread_target_id(process, thread,
  { tid = 44, starttime_ticks = 4100, tgid = 99, cgroups = detail.cgroups },
  selection) == nil,
  "a detail from another thread group cannot be used")
assert(Navigation.thread_target_id(process, thread,
  { tid = 44, starttime_ticks = 4100, tgid = 42 }, selection) == nil,
  "a denied cgroup read does not mean the process cgroup")
local service_workloads = { workloads = {
  { id = "services", name = "Services" },
  { id = "service:42:4096", pid = 42, name = "Example service" },
} }
equal(Navigation.find(service_workloads, Navigation.target_id(member, "service")).name,
  "Example service", "a matching service host is selected by creation time")
assert(Navigation.target_id({ pid = 42 }, "service") == nil)
assert(Navigation.target_id({ pid = 42, starttime_ticks = 4096.5 }, "service") == nil)
assert(Navigation.target_id(member, "coalition") == nil)

-- Threaded cgroups list TIDs, not process IDs. Resolve owners lazily and only
-- after checking task generation and current cgroup membership on both sides
-- of the supplemental reads.
local ThreadMembers = require("wtop.linux.thread_members")
local function stat_line(tid, starttime)
  local fields = {}
  for index = 1, 44 do fields[index] = "0" end
  fields[15], fields[17], fields[19] = "20", "1", tostring(starttime)
  return tid .. " (worker) S " .. table.concat(fields, " ") .. "\n"
end
local member_files = {}
for _, tid in ipairs({ 43, 44, 45, 46 }) do
  local base = "/proc/" .. tid
  member_files[base .. "/stat"] = stat_line(tid, 100)
  member_files[base .. "/status"] = "Name:\tworker\nTgid:\t500\n"
  member_files[base .. "/cgroup"] = tid == 46 and "0::/elsewhere\n"
    or "0::/workers\n"
end
local stat_reads = {}
local fs = { read = function(_, path)
  if path == "/proc/45/stat" then
    stat_reads[path] = (stat_reads[path] or 0) + 1
    if stat_reads[path] == 2 then return stat_line(45, 101) end
  end
  return member_files[path]
end }
local owners = assert(ThreadMembers.resolve(fs, "/workers", { 43, 44, 45, 46 }))
assert(#owners.pids == 1 and owners.pids[1] == 500 and owners.matched_tids == 2)
assert(owners.tids_checked == 4 and owners.tids_total == 4 and not owners.truncated)
assert(stat_reads["/proc/45/stat"] == 2, "a TID is reread after status and cgroup")
local bounded = assert(ThreadMembers.resolve(fs, "/workers", { 43, 44, 45, 46 }, 2))
assert(bounded.truncated and bounded.tids_checked == 2 and #bounded.pids == 1)
assert(ThreadMembers.resolve(fs, "/workers", { 43 }, 0) == nil)

-- Table rows do not request expensive process details. Direct navigation must
-- fetch just this task's membership and verify its generation on both sides.
local ProcessCgroup = require("wtop.linux.process_cgroup")
local selected_process = { id = "42:4096", pid = 42, starttime_ticks = 4096,
  cgroups = { { hierarchy = 0, controllers = "", path = "/old" } } }
local function membership_fs(first, membership, last)
  local provider = { reads = {} }
  local checks = 0
  function provider:read(path, limit)
    assert(limit == 65536, "membership navigation must use bounded reads")
    self.reads[#self.reads + 1] = path
    if path == "/proc/42/stat" then
      checks = checks + 1
      return checks == 1 and first or last
    end
    assert(path == "/proc/42/cgroup", "navigation read an unrelated process file")
    if type(membership) == "function" then return membership() end
    return membership
  end
  return provider
end
local live = membership_fs(stat_line(42, 4096), "0::/current\n", stat_line(42, 4096))
equal(ProcessCgroup.target_id(selected_process, live), "/current",
  "navigation rereads membership even when a snapshot has an old path")
assert(#live.reads == 3 and live.reads[1] == "/proc/42/stat"
  and live.reads[2] == "/proc/42/cgroup" and live.reads[3] == "/proc/42/stat")
assert(selected_process.cgroups[1].path == "/old", "an on-demand read does not mutate the snapshot")
local no_detail = { id = "42:4096", pid = 42, starttime_ticks = 4096 }
equal(ProcessCgroup.target_id(no_detail, live), "/current",
  "a process row without detail fields can still navigate")
local replaced = membership_fs(stat_line(42, 4097), "0::/new\n", stat_line(42, 4097))
assert(ProcessCgroup.target_id(selected_process, replaced) == nil and #replaced.reads == 1,
  "an already replaced process cannot donate its membership")
local raced = membership_fs(stat_line(42, 4096), "0::/new\n", stat_line(42, 4097))
assert(ProcessCgroup.target_id(selected_process, raced) == nil and #raced.reads == 3,
  "PID reuse during membership reading discards the target")
local wrong_pid = membership_fs(stat_line(43, 4096), "0::/other\n", stat_line(43, 4096))
assert(ProcessCgroup.target_id(selected_process, wrong_pid) == nil)
local vanished = membership_fs(stat_line(42, 4096), "0::/current\n", nil)
assert(ProcessCgroup.target_id(selected_process, vanished) == nil)
for _, unavailable in ipairs({ false, "bad", "2:cpu:/legacy\n", "0::/a\n0::/b\n",
    string.rep("x", 65537), function() error("read failed") end }) do
  local denied = membership_fs(stat_line(42, 4096), unavailable, stat_line(42, 4096))
  assert(ProcessCgroup.target_id(selected_process, denied) == nil,
    "unreadable or ambiguous membership must not reuse the snapshot path")
end
assert(ProcessCgroup.target_id({ pid = "42", starttime_ticks = 4096 }, live) == nil)
assert(ProcessCgroup.target_id({ pid = 42 }, live) == nil)
assert(ProcessCgroup.target_id(selected_process, {}) == nil)

print("ok: workload collapse and selection navigation")
