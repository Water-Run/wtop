-- A cgroup control file exists only when its controller is delegated to that
-- subtree, and the real root additionally gets no cpu/memory/pids limit files
-- because nothing above it accounts for usage.  Neither is a failed read, so
-- the collector must not turn them into issues or a partial node.  A file the
-- kernel did create and that still cannot be read must remain an issue, and a
-- truncated listing cannot prove absence at all.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root_dir = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root_dir == "" then root_dir = "." end
package.path = root_dir .. "/src/?.lua;" .. root_dir .. "/src/?/init.lua;" .. package.path

local Cgroup = require("wtop.collectors.cgroup")
local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")

local function check(condition, message)
  if not condition then error(message, 2) end
end

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

-- Every file the collector may open, grouped by the controller that owns it.
-- The grouping matters: a cgroup only ever gains a whole controller at a time,
-- which is what makes "the kernel never created this" a coherent explanation.
local CONTROLLER_FILES = {
  always = { "cgroup.procs" },
  cpuset = { "cpuset.cpus.effective", "cpuset.mems.effective" },
  cpu = { "cpu.max", "cpu.weight" },
  memory = {
    "memory.current", "memory.peak", "memory.low", "memory.high", "memory.max",
    "memory.swap.current", "memory.events",
  },
  pids = { "pids.current", "pids.max", "pids.events" },
  io = { "io.stat" },
  -- cpu.stat and the three pressure files are created for every cgroup whether
  -- or not the owning controller was delegated, so they are never optional.
  unconditional = { "cpu.stat", "cpu.pressure", "memory.pressure", "io.pressure" },
}

local CONTENT = {
  ["cgroup.controllers"] = "cpuset cpu io memory pids\n",
  ["cgroup.subtree_control"] = "cpuset cpu io memory pids\n",
  ["cgroup.procs"] = "42\n7\n",
  ["cpu.stat"] = "usage_usec 1000000\nuser_usec 600000\nsystem_usec 400000\n",
  ["cpu.pressure"] = "some avg10=0.10 avg60=0.20 avg300=0.30 total=100000\n",
  ["memory.pressure"] = "some avg10=0.20 avg60=0.30 avg300=0.40 total=200000\n",
  ["io.pressure"] = "some avg10=0.30 avg60=0.40 avg300=0.50 total=300000\n",
  ["cpu.max"] = "max 100000\n",
  ["cpu.weight"] = "100\n",
  ["memory.current"] = "1048576\n",
  ["memory.peak"] = "2097152\n",
  ["memory.low"] = "0\n",
  ["memory.high"] = "max\n",
  ["memory.max"] = "4194304\n",
  ["memory.swap.current"] = "131072\n",
  ["memory.events"] = "low 0\nhigh 1\nmax 2\noom 0\noom_kill 0\n",
  ["pids.current"] = "2\n",
  ["pids.max"] = "max\n",
  ["pids.events"] = "max 0\n",
  ["io.stat"] = "8:0 rbytes=1000 wbytes=2000 rios=10 wios=20 dbytes=0 dios=0\n",
  ["cpuset.cpus.effective"] = "0-3,8\n",
  ["cpuset.mems.effective"] = "0\n",
}

-- Materialise one cgroup directory from the set of files it publishes.  A
-- controller is delegated to a whole subtree at a time, which is what makes
-- "the kernel never created this" a coherent explanation.
local function files_for(controllers)
  local names = {}
  local function add(list)
    for _, name in ipairs(list) do names[#names + 1] = name end
  end
  add(CONTROLLER_FILES.always)
  add(CONTROLLER_FILES.unconditional)
  for _, controller in ipairs({ "cpuset", "cpu", "memory", "pids", "io" }) do
    if controllers[controller] then add(CONTROLLER_FILES[controller]) end
  end
  return names
end

-- The real cgroup root publishes the read-only account of the controllers it
-- has -- cpu.stat, io.stat and the pressure files -- but no cpu, memory or pids
-- usage or limit file, because nothing above the root accounts for any of them.
-- Modelled as the observed file set rather than as a rule the collector knows.
local REAL_ROOT_FILES = {
  "cgroup.controllers", "cgroup.subtree_control", "cgroup.procs",
  "cpu.stat", "cpu.pressure", "memory.pressure", "io.pressure",
  "cpuset.cpus.effective", "cpuset.mems.effective", "io.stat",
}

local function populate(files, directories, path, names)
  local entries = {}
  for _, name in ipairs(names) do
    entries[#entries + 1] = name
    files[path .. "/" .. name] = CONTENT[name]
  end
  directories[path] = entries
  return entries
end

local function fake_fs(files, directories, truncated_paths, read_overrides)
  local fs = {}
  function fs:read(path, limit)
    if read_overrides and read_overrides[path] then
      return read_overrides[path](path)
    end
    local value = files[path]
    if value == nil then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    if limit and #value > limit then
      return nil, { kind = "too_large", message = "fixture_too_large", path = path }
    end
    return value
  end
  function fs:list(path)
    local entries = directories[path]
    if not entries then
      return nil, { kind = "missing", message = "fixture_directory_missing", path = path }
    end
    local copy = {}
    for index, value in ipairs(entries) do copy[index] = value end
    return copy, nil, truncated_paths and truncated_paths[path] == true or false
  end
  function fs:readlink(path)
    if directories[path] ~= nil or files[path] ~= nil then
      return nil, { kind = "not_link", message = "invalid argument", path = path }
    end
    return nil, { kind = "missing", message = "fixture_entry_missing", path = path }
  end
  function fs:kind(path)
    if directories[path] ~= nil then return "directory" end
    if files[path] ~= nil then return "regular" end
    return nil, { kind = "missing", message = "fixture_entry_missing", path = path }
  end
  return fs
end

local ALL = { cpuset = true, cpu = true, memory = true, pids = true, io = true }
local function sample(files, directories, options)
  options = options or {}
  local now = 1000000000
  local context = {
    fs = fake_fs(files, directories, options.truncated_paths, options.read_overrides),
    now_ns = function() return now end,
  }
  local collector = Cgroup.new({ mount_path = "/cg", root = "/", max_nodes = 32 })
  return collector:sample(context)
end

-- 1. The live shape of a healthy host: the real root carries no cpu/memory/pids
--    limit files, a session subtree was never given cpuset, and a nested app
--    scope was never given the io controller.  None of that is a read failure.
local files, directories = {}, {}
local root_entries = populate(files, directories, "/cg", REAL_ROOT_FILES)
local user_slice_entries = populate(files, directories, "/cg/user.slice", files_for(ALL))
local inner_entries = populate(files, directories, "/cg/user.slice/user-1000.slice",
  files_for({ cpu = true, memory = true, pids = true, io = true }))
populate(files, directories, "/cg/user.slice/user-1000.slice/app.scope",
  files_for({ cpu = true, memory = true, pids = true }))
user_slice_entries[#user_slice_entries + 1] = "user-1000.slice"
root_entries[#root_entries + 1] = "user.slice"
inner_entries[#inner_entries + 1] = "app.scope"

local live = sample(files, directories)
equal(live.status, "ok", "sample status")
equal(live.data.summary.node_count, 4, "every discovered node is present")
equal(live.data.summary.issue_count, 0, "an absent control file is not an issue")
equal(live.data.summary.missing_issue_count, 0, "no missing-file issues")
equal(live.data.summary.denied_issue_count, 0, "no denied reads")
equal(live.data.summary.parse_issue_count, 0, "no parse failures")
equal(live.data.summary.partial_node_count, 0, "no node is partial")
-- The first sample has no interval yet, so the aggregate is a rate gap.  What
-- matters is that it is no longer degraded as partial.
equal(live.quality, "gap", "the sample is not degraded as partial")
for _, node in ipairs(live.data.workloads) do
  check(node.partial == false, node.id .. " must not be partial")
  equal(node.issue_count, 0, node.id .. " issue count")
  equal(#node.issues, 0, node.id .. " issue list")
  equal(node.quality, "gap", node.id .. " first-sample rate quality")
end

-- The real root: cpuset and the always-created files are read, the limit files
-- simply are not there.
local live_root = live.data.by_id["/"]
equal(live_root.cpuset.cpus_effective, "0-3,8", "root cpuset CPUs")
equal(live_root.cpuset.mems_effective, "0", "root cpuset NUMA nodes")
equal(live_root.cpu.max, nil, "the root has no cpu.max")
equal(live_root.cpu.weight, nil, "the root has no cpu.weight")
equal(live_root.memory.current_bytes, nil, "the root has no memory.current")
equal(live_root.pids.current, nil, "the root has no pids.current")
equal(live_root.cpu.counters.usage_usec, 1000000, "root cpu.stat is read")
equal(#live_root.io.devices, 1, "root io.stat is read")
equal(live_root.pressure.cpu.some.avg10, 0.10, "root cpu.pressure is read")

-- The fully delegated cgroup is complete, and the zero bound is still a value.
local live_slice = live.data.by_id["/user.slice"]
equal(live_slice.cpuset.cpus_effective, "0-3,8", "delegated cpuset CPUs")
equal(live_slice.memory.low_bytes, 0, "a zero memory.low is a reading, not an absence")
equal(live_slice.cpu.max.quota_usec, "max", "delegated cpu.max")
equal(live_slice.memory.current_bytes, 1048576, "delegated memory.current")
equal(live_slice.pids.current, 2, "delegated pids.current")

-- cpuset was never delegated below user-1000.slice: the metric is absent and
-- the node is still whole.
local live_inner = live.data.by_id["/user.slice/user-1000.slice"]
equal(live_inner.cpuset.cpus_effective, nil, "undelegated cpuset is absent")
equal(live_inner.cpuset.mems_effective, nil, "undelegated cpuset NUMA is absent")
equal(live_inner.memory.current_bytes, 1048576, "the rest of the node is intact")
equal(live_inner.pids.current, 2, "pids is still delegated here")

-- The app scope also lost the io controller, so it has no devices -- which is
-- the default empty table, not a fabricated zero-byte reading.
local live_app = live.data.by_id["/user.slice/user-1000.slice/app.scope"]
equal(#live_app.io.devices, 0, "an undelegated io controller yields no devices")
equal(live_app.cpuset.cpus_effective, nil, "undelegated cpuset is absent")
equal(live_app.memory.current_bytes, 1048576, "the app scope is otherwise intact")

-- 2. A file the kernel did create and that cannot be opened is still an issue.
local denied_files, denied_dirs = {}, {}
populate(denied_files, denied_dirs, "/cg", files_for(ALL))
denied_dirs["/cg"][#denied_dirs["/cg"] + 1] = "child"
populate(denied_files, denied_dirs, "/cg/child", files_for(ALL))
local denied = sample(denied_files, denied_dirs, {
  read_overrides = {
    ["/cg/child/memory.current"] = function(path)
      return nil, { kind = "denied", message = "permission denied", path = path }
    end,
  },
})
local denied_child = denied.data.by_id["/child"]
check(denied_child.partial == true, "a denied read makes the node partial")
equal(denied_child.quality, "partial", "a denied read degrades the node quality")
equal(denied_child.issue_count, 1, "exactly one issue")
equal(denied_child.issues[1].field, "memory.current", "the issue names the field")
equal(denied_child.issues[1].kind, "denied", "the issue names the failure")
equal(denied.data.summary.partial_node_count, 1, "only the denied node is partial")
equal(denied.data.summary.denied_issue_count, 1, "the denied read is counted")
equal(denied.quality, "partial", "the sample is partial")

-- 2b. A listing can go stale: a cgroup that was replaced between the directory
--     read and the file read can fail with EACCES for a name the old listing
--     never mentioned.  Only a *missing* read proves the kernel created
--     nothing, so a denied read is reported even for an unlisted name.
local stale_files, stale_dirs = {}, {}
populate(stale_files, stale_dirs, "/cg", files_for({ cpu = true, memory = true, pids = true, io = true }))
stale_dirs["/cg"][#stale_dirs["/cg"] + 1] = "child"
populate(stale_files, stale_dirs, "/cg/child", files_for({ cpu = true, memory = true, pids = true, io = true }))
local stale = sample(stale_files, stale_dirs, {
  read_overrides = {
    ["/cg/child/cpuset.cpus.effective"] = function(path)
      return nil, { kind = "denied", message = "permission denied", path = path }
    end,
  },
})
local stale_child = stale.data.by_id["/child"]
check(stale_child.partial == true, "a denied read of an unlisted name is an issue")
equal(stale_child.issue_count, 1, "only the denied read is reported")
equal(stale_child.issues[1].kind, "denied", "the denial is not mistaken for an absence")
equal(stale_child.issues[1].field, "cpuset.cpus_effective", "the issue names the field")
equal(stale.data.summary.denied_issue_count, 1, "the denial is counted as denied")

-- 3. A file that was listed and then vanished under us is a race, not an
--    absence, and the listing cannot be used to excuse it.
local race_files, race_dirs = {}, {}
populate(race_files, race_dirs, "/cg", files_for(ALL))
race_dirs["/cg"][#race_dirs["/cg"] + 1] = "child"
populate(race_files, race_dirs, "/cg/child", files_for(ALL))
local raced = sample(race_files, race_dirs, {
  read_overrides = {
    ["/cg/child/cpu.max"] = function(path)
      return nil, { kind = "missing", message = "no such file", path = path }
    end,
  },
})
local raced_child = raced.data.by_id["/child"]
check(raced_child.partial == true, "a listed file that vanished is an issue")
equal(raced_child.issues[1].kind, "missing", "the race is reported as missing")
equal(raced_child.issue_count, 1, "exactly one issue")
equal(raced.data.summary.missing_issue_count, 1, "the vanished file is counted")

-- 4. A truncated listing cannot prove that a name is absent, so the collector
--    must fall back to reporting the read instead of silently dropping it.
local truncated_files, truncated_dirs = {}, {}
populate(truncated_files, truncated_dirs, "/cg", files_for(ALL))
truncated_dirs["/cg"][#truncated_dirs["/cg"] + 1] = "child"
local child_entries = populate(truncated_files, truncated_dirs, "/cg/child",
  files_for({ cpu = true, memory = true, pids = true, io = true }))
-- Model the kernel listing only part of the directory: cpuset is gone from the
-- truncated listing even though the cgroup has it.
local kept = {}
for _, name in ipairs(child_entries) do
  if name ~= "cpuset.cpus.effective" and name ~= "cpuset.mems.effective" then
    kept[#kept + 1] = name
  end
end
truncated_dirs["/cg/child"] = kept
local truncated = sample(truncated_files, truncated_dirs, {
  truncated_paths = { ["/cg/child"] = true },
})
equal(truncated.data.summary.truncated, true, "the sample records the truncation")
local truncated_child = truncated.data.by_id["/child"]
check(truncated_child.partial == true, "a truncated listing cannot prove absence")
equal(truncated_child.issue_count, 2, "both unread cpuset files are reported")
equal(truncated_child.issues[1].field, "cpuset.cpus_effective", "cpuset CPUs reported")
equal(truncated_child.issues[2].field, "cpuset.mems_effective", "cpuset NUMA reported")
equal(truncated.data.summary.partial_node_count, 1, "the truncated node is partial")

-- 5. The Workloads page explains partial with what now actually causes it, and
--    stays silent when nothing is partial.
local translator = assert(I18n.new({ locale = "en-US" }))
local engine = { history_values = function() return {} end }
local function detail(summary)
  local snapshot = {
    cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, processes = {},
    cpu_frequency = {}, mounts = {}, connections = {}, quality = {}, sensors = {},
    gpus = {},
    workloads = {
      kind = "cgroup2",
      workloads = {},
      summary = summary,
    },
  }
  local built = ViewModel.build(engine, snapshot, translator, {}, "workloads",
    nil, nil, {})
  local labels = {}
  for _, item in ipairs(built.workload_detail.entries) do
    labels[#labels + 1] = tostring(item.value)
  end
  return table.concat(labels, "\n")
end
local clean = detail({ node_count = 4, partial_node_count = 0,
  root = { cpu_utilization_percent = 5 } })
check(clean:find("Why partial", 1, true) == nil,
  "a clean cgroup scan does not explain a problem that does not exist")
local degraded = detail({ node_count = 4, partial_node_count = 1,
  root = { cpu_utilization_percent = 5 } })
check(degraded:find("A control file the kernel created could not be read as this user.",
  1, true) ~= nil, "the partial explanation names the real cause")
check(degraded:find("not delegated", 1, true) == nil,
  "an undelegated controller is no longer offered as a cause of partial")

-- A device the kernel does not account for.  The real line, read off a live
-- container scope on this host, is a bare `251:0` with no key=value pairs -- the
-- overlay and fuse filesystems a container mounts have no bio counters, so the
-- kernel names the device and stops.  The parser required at least one field,
-- called that a malformed line, and turned every container cgroup on the host
-- into a partial node: measured here, one of 190, with the issue
-- `parse/invalid_io_stat_line`, which is enough to open a "why is this partial"
-- section on a tree that has nothing unreadable in it.  A line that parses as a
-- device and carries no counters is a device with no accounting, not a
-- malformed line, so it is a state and not an issue.
local unaccounted = sample(files, directories, {
  read_overrides = {
    ["/cg/user.slice/user-1000.slice/app.scope/io.stat"] = function()
      -- Exactly what the kernel wrote: an accounted loop device and an
      -- unaccounted overlay device, the second with a single trailing space.
      return "251:0 \n259:0 rbytes=212447232 wbytes=871768064 rios=2794 "
        .. "wios=81353 dbytes=0 dios=0\n", nil
    end,
  },
})
equal(unaccounted.status, "ok", "an unaccounted device does not fail the sample")
equal(unaccounted.data.summary.parse_issue_count, 0,
  "a device with no counters is not a parse failure")
equal(unaccounted.data.summary.partial_node_count, 0,
  "and no node is partial because of it")
for _, node in ipairs(unaccounted.data.workloads) do
  check(node.partial == false, node.id .. " must not be partial")
  equal(node.issue_count, 0, node.id .. " issue count")
end
-- The devices are not dropped either: both are visible, the unaccounted one
-- carries no counter and invents no rate -- a counter that was never accounted
-- for is unknown, not zero -- and the totals cover only the accounted one.
local scope = unaccounted.data.by_id["/user.slice/user-1000.slice/app.scope"]
equal(#scope.io.devices, 2, "both devices are listed")
local overlay = scope.io.by_id["251:0"]
check(overlay ~= nil, "the unaccounted device is still listed")
equal(next(overlay.counters), nil, "and it has no counters to report")
equal(next(overlay.rates), nil, "and no rate is invented for it")
equal(scope.io.by_id["259:0"].counters.rbytes, 212447232,
  "the accounted device keeps its counters")
equal(scope.io.totals.counters.rbytes, 212447232,
  "and the totals are exactly the accounted device's")
-- Compared as tables rather than key by key: the totals must be the accounted
-- device and nothing else, which is the claim that no counter was invented for
-- the device the kernel named but did not account for.
local total_keys = {}
for key in pairs(scope.io.totals.counters) do total_keys[#total_keys + 1] = key end
table.sort(total_keys)
local accounted_keys = {}
for key in pairs(scope.io.by_id["259:0"].counters) do
  accounted_keys[#accounted_keys + 1] = key
end
table.sort(accounted_keys)
equal(table.concat(total_keys, ","), table.concat(accounted_keys, ","),
  "the totals carry exactly the accounted device's counters")
equal(scope.io.totals.counters.rios, 2794,
  "and their values, with nothing standing in for the device that has none")

print("ok: cgroup absent control files")
