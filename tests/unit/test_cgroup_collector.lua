package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Cgroup = require("wtop.collectors.cgroup")
assert(not pcall(Cgroup.new, "invalid"))
assert(not pcall(Cgroup.new, { max_nodes = 65537 }))

local function fixture(name)
  local file = assert(io.open("tests/fixtures/cgroup/" .. name, "rb"))
  local content = assert(file:read("*a"))
  file:close()
  return content
end

local function copy_array(values)
  local output = {}
  for index, value in ipairs(values) do
    output[index] = value
  end
  return output
end

local function fake_fs(files, directories, links, list_errors)
  local fs = {}

  function fs:read(path, limit)
    local value = files[path]
    if type(value) == "function" then
      value = value(path)
    end
    if value == nil then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    value = tostring(value)
    if limit and #value > limit then
      return nil, { kind = "too_large", message = "fixture_too_large", path = path }
    end
    return value
  end

  function fs:list(path)
    if list_errors[path] then
      return nil, list_errors[path]
    end
    if directories[path] then
      return copy_array(directories[path])
    end
    if files[path] ~= nil or links[path] ~= nil then
      return nil, { kind = "not_directory", message = "not a directory", path = path }
    end
    return nil, { kind = "missing", message = "fixture_directory_missing", path = path }
  end

  function fs:readlink(path)
    if links[path] then
      return links[path]
    end
    if files[path] ~= nil or directories[path] ~= nil or list_errors[path] ~= nil then
      return nil, { kind = "not_link", message = "invalid argument", path = path }
    end
    return nil, { kind = "missing", message = "fixture_entry_missing", path = path }
  end

  function fs:kind(path)
    if links[path] then return "symlink" end
    if directories[path] ~= nil or list_errors[path] ~= nil then return "directory" end
    if files[path] ~= nil then return "regular" end
    return nil, { kind = "missing", message = "fixture_entry_missing", path = path }
  end

  return fs
end

local function near(actual, expected, epsilon)
  assert(type(actual) == "number", "expected number, got " .. tostring(actual))
  assert(math.abs(actual - expected) <= (epsilon or 1e-6), tostring(actual) .. " ~= " .. tostring(expected))
end

local metric_names = {
  "cgroup.procs",
  "cpu.stat",
  "cpu.max",
  "cpu.weight",
  "memory.current",
  "memory.peak",
  "memory.low",
  "memory.high",
  "memory.max",
  "memory.swap.current",
  "memory.events",
  "io.stat",
  "pids.current",
  "pids.max",
  "pids.events",
  "cpu.pressure",
  "memory.pressure",
  "io.pressure",
  "cpuset.cpus.effective",
  "cpuset.mems.effective",
}

local files = {}
local directories = {}
local links = {
  ["/cg/loop-link"] = "/cg",
}
local list_errors = {
  ["/cg/user.slice/blocked.scope"] = {
    kind = "denied",
    message = "permission denied",
    path = "/cg/user.slice/blocked.scope",
  },
}
local accessible_nodes = {
  "/cg",
  "/cg/user.slice",
  "/cg/user.slice/app.scope",
}

local function entries(extra)
  local values = { "cgroup.controllers", "cgroup.subtree_control" }
  for _, name in ipairs(metric_names) do
    values[#values + 1] = name
  end
  for _, name in ipairs(extra or {}) do
    values[#values + 1] = name
  end
  return values
end

directories["/cg"] = entries({ ".hidden", "bad/name", "loop-link", "user.slice", "vanished.scope" })
directories["/cg/.hidden"] = entries()
directories["/cg/user.slice"] = entries({ "app.scope", "blocked.scope" })
directories["/cg/user.slice/app.scope"] = entries()

local function set_node_state(base, state)
  files[base .. "/cgroup.controllers"] = "cpu cpuset io memory pids\n"
  files[base .. "/cgroup.subtree_control"] = "cpu memory io pids\n"
  files[base .. "/cgroup.procs"] = fixture("cgroup.procs")
  files[base .. "/cpu.stat"] = fixture("cpu.stat." .. state)
  files[base .. "/cpu.max"] = fixture("cpu.max")
  files[base .. "/cpu.weight"] = "100\n"
  files[base .. "/memory.current"] = "1048576\n"
  files[base .. "/memory.peak"] = "2097152\n"
  files[base .. "/memory.low"] = "0\n"
  files[base .. "/memory.high"] = "max\n"
  files[base .. "/memory.max"] = "4194304\n"
  files[base .. "/memory.swap.current"] = "131072\n"
  files[base .. "/memory.events"] = fixture("memory.events." .. state)
  files[base .. "/io.stat"] = fixture("io.stat." .. state)
  files[base .. "/pids.current"] = "2\n"
  files[base .. "/pids.max"] = "max\n"
  files[base .. "/pids.events"] = fixture("pids.events." .. state)
  files[base .. "/cpu.pressure"] = fixture("pressure." .. state)
  files[base .. "/memory.pressure"] = fixture("pressure." .. state)
  files[base .. "/io.pressure"] = fixture("pressure." .. state)
  files[base .. "/cpuset.cpus.effective"] = fixture("cpuset.cpus.effective")
  files[base .. "/cpuset.mems.effective"] = fixture("cpuset.mems.effective")
end

local function set_tree_state(state)
  for _, base in ipairs(accessible_nodes) do
    set_node_state(base, state)
  end
end

set_tree_state("1")
local fs = fake_fs(files, directories, links, list_errors)
local now = 1000000000
local context = {
  fs = fs,
  now_ns = function()
    return now
  end,
}

local collector = Cgroup.new({
  mount_path = "/cg",
  root = "/",
  max_depth = 8,
  max_nodes = 32,
})
assert(collector.id == "cgroup")
assert(collector:probe(context).available)

-- The first sample establishes a baseline.  Per-counter status remains
-- explicit even though inaccessible/racing subtrees make the aggregate
-- sample partial rather than failed.
local first = collector:sample(context)
assert(first.status == "ok" and first.quality == "partial")
assert(first.data.schema == "dev.waterrun.wtop.cgroup/v1")
assert(first.data.root == "/" and first.data.summary.root_id == "/")
assert(#first.data.workloads == 4 and first.data.summary.node_count == 4)
assert(first.data.workloads[1].id == "/")
assert(first.data.workloads[2].id == "/user.slice")
assert(first.data.workloads[3].id == "/user.slice/app.scope")
assert(first.data.workloads[4].id == "/user.slice/blocked.scope")

local root = assert(first.data.by_id["/"])
assert(root.parent_id == nil and root.depth == 0 and root.rate_quality == "gap")
assert(root.rate_status["cpu.usage_usec"] == "gap")
assert(root.processes.count == 2 and root.processes.pids[1] == 7 and root.processes.pids[2] == 42)
assert(root.cpu.max.quota_usec == "max" and root.cpu.max.period_usec == 100000)
assert(root.memory.low_bytes == 0)
assert(root.memory.high_bytes == "max" and root.memory.max_bytes == 4194304)
assert(root.pids.max == "max")
assert(root.cpuset.cpus_effective == "0-3,8" and root.cpuset.mems_effective == "0")
assert(first.data.by_id["/user.slice/app.scope"].parent_id == "/user.slice")

local blocked = assert(first.data.by_id["/user.slice/blocked.scope"])
assert(blocked.accessible == false and blocked.partial and blocked.issues[1].kind == "denied")
assert(first.data.summary.partial_node_count == 2)
assert(first.data.summary.denied_issue_count == 1)
assert(first.data.summary.missing_issue_count == 1)
assert(first.data.summary.skipped_symlinks == 1)
assert(first.data.summary.skipped_dot_entries == 1)
assert(first.data.summary.skipped_unsafe_entries == 1)
assert(first.data.summary.visible_process_count == 6)

-- Adjacent samples derive every cumulative family without losing the raw
-- values.  Gauges and literal "max" limits are deliberately not converted
-- into counters or ambiguous nils.
set_tree_state("2")
now = now + 1000000000
local second = collector:sample(context, first)
assert(second.status == "ok" and second.quality == "partial")
root = assert(second.data.by_id["/"])
assert(root.rate_quality == "fresh")
near(root.cpu.rates.usage_usec_per_second, 500000)
near(root.cpu.utilization_percent, 50)
near(root.memory.event_rates.high_per_second, 2)
near(root.io.by_id["8:0"].rates.rbytes_per_second, 3000)
near(root.io.totals.rates.rbytes_per_second, 4000)
near(root.pids.event_rates.max_per_second, 2)
near(root.pressure.cpu.some.total_usec_per_second, 200000)
near(second.data.summary.root.cpu_utilization_percent, 50)
assert(root.rate_status["io.8:0.rbytes"] == "fresh")
assert(root.rate_status["pressure.io.full.total_usec"] == "fresh")

-- Counter rollback is surfaced as reset and never emitted as a negative rate.
set_tree_state("reset")
now = now + 1000000000
local reset = collector:sample(context, second)
root = assert(reset.data.by_id["/"])
assert(root.rate_quality == "reset")
assert(root.rate_status["cpu.usage_usec"] == "reset")
assert(root.rate_status["memory.events.high"] == "reset")
assert(root.rate_status["io.8:0.rbytes"] == "reset")
assert(root.rate_status["pressure.cpu.some.total_usec"] == "reset")
assert(root.cpu.rates.usage_usec_per_second == nil)
assert(root.io.by_id["8:0"].rates.rbytes_per_second == nil)
assert(reset.data.summary.reset_node_count == 3)

-- Without partial subtrees, the collector-level quality follows the
-- adjacent-counter state exactly: gap -> fresh -> reset.
set_tree_state("1")
local clean_collector = Cgroup.new({
  mount_path = "/cg",
  root = "/user.slice/app.scope",
  max_depth = 0,
  max_nodes = 1,
})
local clean_first = clean_collector:sample(context)
assert(clean_first.quality == "gap")
set_tree_state("2")
now = now + 1000000000
local clean_second = clean_collector:sample(context, clean_first)
assert(clean_second.quality == "fresh")
set_tree_state("reset")
now = now + 1000000000
local clean_reset = clean_collector:sample(context, clean_second)
assert(clean_reset.quality == "reset")

-- max_depth bounds traversal while retaining the configured root metrics.
set_tree_state("1")
local depth_limited = Cgroup.new({
  mount_path = "/cg",
  max_depth = 0,
  max_nodes = 32,
}):sample(context)
assert(depth_limited.status == "ok")
assert(#depth_limited.data.workloads == 1)
assert(depth_limited.data.summary.depth_limited)
assert(depth_limited.data.summary.truncated)

-- max_nodes includes the root and prevents unbounded queue growth.
local node_limited = Cgroup.new({
  mount_path = "/cg",
  max_depth = 8,
  max_nodes = 2,
}):sample(context)
assert(node_limited.status == "ok")
assert(#node_limited.data.workloads == 2)
assert(node_limited.data.summary.node_limited)
assert(node_limited.data.summary.truncated)

-- Depth and node budgets are I/O budgets as well as output limits.  Reaching
-- either one must happen before probing every would-be child with readlink and
-- listdir, otherwise a shallow but wide tree can still perform millions of
-- directory operations while returning only a handful of nodes.
local function budget_fs(root_entries)
  local calls = { list = 0, readlink = 0, limits = {} }
  local bounded = {}
  function bounded:list(path, limit)
    calls.list = calls.list + 1
    calls.limits[path] = limit
    if path == "/budget" then return copy_array(root_entries) end
    return {}
  end
  function bounded:readlink()
    calls.readlink = calls.readlink + 1
    return nil, { kind = "not_link", message = "invalid argument" }
  end
  function bounded:read(path)
    return nil, { kind = "missing", message = "fixture_missing", path = path }
  end
  return bounded, calls
end

local depth_fs, depth_calls = budget_fs({ "a", "b", "c", "d" })
local depth_budgeted = Cgroup.new({
  fs = depth_fs,
  mount_path = "/budget",
  max_depth = 0,
  max_nodes = 32,
}):sample({ now_ns = function() return now end })
assert(depth_budgeted.status == "ok" and depth_budgeted.data.summary.depth_limited)
assert(depth_calls.list == 1 and depth_calls.readlink == 0,
  "depth budget must stop before child readlink/list calls")

local nodes_fs, nodes_calls = budget_fs({ "a", "b", "c", "d" })
local node_budgeted = Cgroup.new({
  fs = nodes_fs,
  mount_path = "/budget",
  max_depth = 8,
  max_nodes = 2,
}):sample({ now_ns = function() return now end })
assert(node_budgeted.status == "ok" and node_budgeted.data.summary.node_limited)
assert(node_budgeted.data.summary.node_count == 2)
assert(nodes_calls.list == 2 and nodes_calls.readlink == 1,
  "node budget must stop before probing additional candidates")
assert(nodes_calls.limits["/budget/a"] == 64,
  "child enumeration must use remaining node budget plus fixed slack")

-- A wide breadth is admitted by identity first.  No child directory is
-- enumerated while the root is still being discovered, and a full breadth
-- budget prevents any grandchild readlink/list work.
local breadth_trace = {}
local breadth_fs = {}
function breadth_fs:list(path, limit)
  breadth_trace[#breadth_trace + 1] = "list:" .. path
  assert(type(limit) == "number" and limit >= 64)
  if path == "/wide" then return { "a", "b", "c" } end
  if path == "/wide/a" or path == "/wide/b" or path == "/wide/c" then
    return { "grandchild-1", "grandchild-2" }
  end
  error("grandchild directory must not be enumerated: " .. path)
end
function breadth_fs:readlink(path)
  breadth_trace[#breadth_trace + 1] = "readlink:" .. path
  return nil, { kind = "not_link", message = "invalid argument", path = path }
end
function breadth_fs:read(path)
  return nil, { kind = "missing", message = "fixture_missing", path = path }
end
local breadth_budgeted = Cgroup.new({
  fs = breadth_fs,
  mount_path = "/wide",
  max_depth = 8,
  max_nodes = 4,
}):sample({ now_ns = function() return now end })
assert(breadth_budgeted.status == "ok" and breadth_budgeted.data.summary.node_count == 4)
assert(breadth_trace[1] == "list:/wide")
assert(breadth_trace[2] == "readlink:/wide/a")
assert(breadth_trace[3] == "readlink:/wide/b")
assert(breadth_trace[4] == "readlink:/wide/c")
assert(breadth_trace[5] == "list:/wide/a",
  "breadth discovery must not preload child entry tables")
for _, operation in ipairs(breadth_trace) do
  assert(not operation:find("/grandchild%-", 1),
    "node budget must stop before grandchild I/O")
end

-- A configured subtree keeps mount-relative IDs, so by_id remains stable
-- when callers narrow the scan root.
local nested = Cgroup.new({
  mount_path = "/cg",
  root = "/user.slice",
  max_depth = 4,
  max_nodes = 8,
}):sample(context)
assert(nested.status == "ok")
assert(nested.data.root == "/user.slice")
assert(nested.data.workloads[1].id == "/user.slice")
assert(nested.data.by_id["/user.slice/app.scope"])

assert(not pcall(Cgroup.new, { mount_path = "/cg", root = "../escape" }))
assert(not pcall(Cgroup.new, { mount_path = "relative", root = "/" }))
assert(not pcall(Cgroup.new, { mount_path = "/cg", max_depth = -1 }))
assert(not pcall(Cgroup.new, { mount_path = "/cg", max_nodes = 0 }))

local denied_error = { kind = "denied", message = "permission denied", path = "/cg" }
local denied_context = {
  fs = fake_fs({}, {}, {}, { ["/cg"] = denied_error }),
  now_ns = function() return now end,
}
assert(collector:probe(denied_context).state == "denied")
assert(collector:sample(denied_context).status == "denied")

return true
