-- The cgroup tree on a systemd host with Docker and Kubernetes under it, seen
-- through the collector, the Workloads page and the snapshot exporter.  The
-- collector already reads these directories, so the unit and container names
-- cost no extra I/O; this file is the proof that they survive all three.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Cgroup = require("wtop.collectors.cgroup")
local Export = require("wtop.export")
local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")

local DOCKER = "8a1bcccc1234567890abcdef0123456789abcdef0123456789abcdef01234567"
local POD = "5d4f9a1b2c3d"
local CONTAINERD = "abc123def4567890abcdef01234567"

-- Every directory in the tree, root first.  The names are the ones a systemd
-- host with Docker and Kubernetes actually produces.
local ROOT = {
  "",
  "system.slice",
  "system.slice/sshd.service",
  "system.slice/cron.service",
  "system.slice/docker-" .. DOCKER .. ".scope",
  "system.slice/docker-" .. DOCKER .. ".scope/init",
  "user.slice",
  "user.slice/user-1000.slice",
  "user.slice/user-1000.slice/session-2.scope",
  "kubepods.slice",
  "kubepods.slice/kubepods-besteffort.slice",
  "kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod" .. POD .. ".slice",
  "kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod" .. POD
    .. ".slice/cri-containerd-" .. CONTAINERD .. ".scope",
  "kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod" .. POD
    .. ".slice/cri-containerd-" .. CONTAINERD .. ".scope/init",
}

local function copy_array(values)
  local output = {}
  for index, value in ipairs(values) do output[index] = value end
  return output
end

local function fake_fs()
  local files, directories = {}, {}
  for _, id in ipairs(ROOT) do
    local base = "/sys/fs/cgroup" .. (id == "" and "" or ("/" .. id))
    files[base .. "/cgroup.controllers"] = "cpu memory pids\n"
    files[base .. "/cgroup.subtree_control"] = "cpu memory pids\n"
    files[base .. "/cgroup.procs"] = "1\n"
    files[base .. "/cpu.stat"] = "usage_usec 1000\n"
    files[base .. "/cpu.max"] = "max 100000\n"
    files[base .. "/cpu.weight"] = "100\n"
    files[base .. "/memory.current"] = "1048576\n"
    files[base .. "/memory.peak"] = "1048576\n"
    files[base .. "/memory.low"] = "0\n"
    files[base .. "/memory.high"] = "max\n"
    files[base .. "/memory.max"] = "max\n"
    files[base .. "/memory.swap.current"] = "0\n"
    files[base .. "/memory.events"] = "low 0\n"
    files[base .. "/io.stat"] = "8:0 rbytes=1024 wbytes=2048 rios=1 wios=1\n"
    files[base .. "/pids.current"] = "1\n"
    files[base .. "/pids.max"] = "max\n"
    files[base .. "/pids.events"] = "max 0\n"
    files[base .. "/cpu.pressure"] = "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
    files[base .. "/memory.pressure"] = "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
    files[base .. "/io.pressure"] = "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
    files[base .. "/cpuset.cpus.effective"] = "0-3\n"
    files[base .. "/cpuset.mems.effective"] = "0\n"

    local children = {}
    local prefix = id == "" and "" or (id .. "/")
    for _, other in ipairs(ROOT) do
      if other:sub(1, #prefix) == prefix and not other:find("/", #prefix + 1) then
        children[#children + 1] = other:sub(#prefix + 1)
      end
    end
    directories[base] = copy_array(children)
  end
  return {
    read = function(_, path)
      local value = files[path]
      if value == nil then
        return nil, { kind = "missing", message = "fixture_missing", path = path }
      end
      return value
    end,
    list = function(_, path)
      local value = directories[path]
      if value == nil then
        return nil, { kind = "missing", message = "fixture_directory_missing", path = path }
      end
      return copy_array(value)
    end,
    readlink = function(_, path)
      -- Not a symlink, which the collector confirms before type-checking.
      return nil, { kind = "not_link", message = "invalid argument", path = path }
    end,
    kind = function(_, path)
      if directories[path] ~= nil then return "directory" end
      if files[path] ~= nil then return "regular" end
      return nil, { kind = "missing", message = "fixture_entry_missing", path = path }
    end,
  }
end

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      message, tostring(expected), tostring(actual)), 0)
  end
end

local collector = Cgroup.new({ fs = fake_fs(), mount_path = "/sys/fs/cgroup" })
local context = { now_ns = function() return 1000000000 end }
local first = collector:sample(context)
equal(first.status, "ok", "the tree is sampled")
equal(#first.data.workloads, #ROOT, "every directory becomes a node")

local by_id = first.data.by_id
local function semantics_of(id)
  local node = assert(by_id[id], "no node for " .. id)
  assert(node.semantics, "no semantics for " .. id)
  return node.semantics
end

-- A container row carries the identity the kernel hid in a 64-character name.
local docker = semantics_of("/system.slice/docker-" .. DOCKER .. ".scope")
equal(docker.runtime, "docker", "the docker scope keeps its runtime")
equal(docker.container_short_id, "8a1bcccc1234", "the row knows the short id")
equal(docker.container_scope, true, "the row is the container itself")
equal(docker.label, "docker 8a1bcccc1234", "the row is labelled by runtime and id")

-- Its own subdirectory is part of the container, so it must not be counted or
-- labelled as a second one.
local init = semantics_of("/system.slice/docker-" .. DOCKER .. ".scope/init")
equal(init.container_scope, false, "a container child is not a second container")
equal(init.container_id, DOCKER, "a container child still knows its container")

-- The pod and the container inside it are two different things.
local pod = semantics_of("/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod"
  .. POD .. ".slice")
equal(pod.pod, "pod" .. POD, "the pod slice names the pod")
equal(pod.pod_scope, true, "the slice is the pod")
equal(pod.container, false, "a pod is not a container")
local containerd = semantics_of("/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod"
  .. POD .. ".slice/cri-containerd-" .. CONTAINERD .. ".scope")
equal(containerd.runtime, "containerd", "the cri scope names containerd")
equal(containerd.pod, "pod" .. POD, "the container names its pod")
equal(containerd.pod_scope, false, "the container is not the pod")

-- A node must not be able to answer differently from its own path: the
-- classification is memoised, so each node gets its own copy to write into.
local root_semantics = semantics_of("/")
equal(root_semantics.unit, nil, "the root cgroup has no unit")
local slice_semantics = semantics_of("/system.slice")
equal(slice_semantics.unit, "system.slice", "a slice names itself")
assert(slice_semantics ~= root_semantics, "each node gets its own table")
slice_semantics.unit = "tampered"
equal(semantics_of("/user.slice/user-1000.slice").user_id, 1000, "the login slice knows its uid")
equal(semantics_of("/user.slice/user-1000.slice/session-2.scope").user_slice, false,
  "a session is not the login slice itself")

-- The summary counts what the tree is made of, and only counts each once.
local summary = first.data.summary
equal(summary.service_count, 2, "two services, not three")
equal(summary.container_count, 2, "the docker scope and the cri scope are containers")
equal(summary.pod_count, 1, "the pod is counted once despite having a container inside")
equal(summary.user_session_count, 1, "one login session")

-- A second sample must reach the same conclusions: the identity is derived
-- from the id, and the id is what the tree is keyed by.
local second = collector:sample(context)
equal(second.data.summary.container_count, 2, "the counts are stable across samples")
equal(second.data.by_id["/system.slice/docker-" .. DOCKER .. ".scope"].semantics.runtime,
  "docker", "the runtime is still known on the next sample")
equal(second.data.by_id["/system.slice"].semantics.unit, "system.slice",
  "writing to one node's semantics cannot change the next sample")

-- The Workloads page shows the container name in the row and the details in
-- the selection panel.
local snapshot = {
  schema = "dev.waterrun.wtop.snapshot/v1",
  timestamp_ns = 1000000000,
  sequence = 1,
  quality = { workloads = { status = "ok", quality = "fresh" } },
  workloads = second.data,
}
local engine = { history_values = function() return {} end }
local translator = assert(I18n.new({ locale = "en-US" }))
local function build(options)
  return ViewModel.build(engine, snapshot, translator, {}, "workloads", nil, nil, options)
end
local function row_for(id)
  local model = build({})
  for index, candidate in ipairs(model.workload_table.ids) do
    if candidate == id then return model.workload_table.rows[index] end
  end
  return nil
end
local function detail_for(id)
  local model = build({ workload_selected = id })
  local detail = {}
  for _, item in ipairs(model.workload_detail.entries) do
    detail[item.label or ""] = item.value
  end
  return detail
end

local docker_row = assert(row_for("/system.slice/docker-" .. DOCKER .. ".scope"))
assert(docker_row.workload:find("docker 8a1bcccc1234", 1, true),
  "the row is named by the container, not the 64-character id: " .. docker_row.workload)
local sshd_row = assert(row_for("/system.slice/sshd.service"))
assert(sshd_row.workload:find("sshd.service", 1, true),
  "a service row keeps its unit name: " .. sshd_row.workload)

local detail = detail_for("/system.slice/docker-" .. DOCKER .. ".scope")
assert(tostring(detail["Workload"]):find("docker 8a1bcccc1234", 1, true),
  "the detail names the container: " .. tostring(detail["Workload"]))
equal(detail["Container"], "docker 8a1bcccc1234", "the container row shows runtime and short id")
equal(detail["Unit"], "docker-" .. DOCKER .. ".scope", "the unit row shows the full unit name")
assert(detail["Path"] ~= nil, "the path is still shown")
equal(detail["Pod"], nil, "a plain container belongs to no pod")

local service_detail = detail_for("/system.slice/sshd.service")
equal(service_detail["Workload"], "sshd.service", "a service is named by its unit")
equal(service_detail["Unit"], nil, "a service does not repeat its unit as an identity")
equal(service_detail["Container"], nil, "a host service is not a container")

local session_detail = detail_for("/user.slice/user-1000.slice/session-2.scope")
equal(session_detail["Login session"], "user-1000", "a session names the login it belongs to")
equal(session_detail["Container"], nil, "a session is not a container")

local pod_detail = detail_for("/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod"
  .. POD .. ".slice/cri-containerd-" .. CONTAINERD .. ".scope")
equal(pod_detail["Pod"], "pod" .. POD, "the container names its pod in the detail")
equal(pod_detail["Container"], "containerd abc123def456", "the cri container is named")
equal(pod_detail["Login session"], nil, "a pod container has no login session")

local pod_slice_detail = detail_for("/kubepods.slice/kubepods-besteffort.slice/"
  .. "kubepods-besteffort-pod" .. POD .. ".slice")
equal(pod_slice_detail["Pod"], "pod" .. POD, "the pod slice names its own pod")
equal(pod_slice_detail["Container"], nil, "a pod is not yet a container")

-- Without a selection the page summarises the tree.
local overview = build({}).workload_detail
local counts = {}
for _, item in ipairs(overview.entries) do
  counts[item.label or ""] = item.value
end
equal(counts["Service units"], 2, "the overview counts services")
equal(counts["Containers"], 2, "the overview counts containers")
equal(counts["Pods"], 1, "the overview counts pods")
equal(counts["Login sessions"], 1, "the overview counts login sessions")
equal(counts["Visible cgroups"], #ROOT, "the overview still counts cgroups")

-- The exporter publishes the same identity, so a consumer does not have to
-- re-derive it from the path.
local exported = Export.snapshot({ workloads = second.data, quality = snapshot.quality })
  .workloads
local items = {}
for _, item in ipairs(exported.items) do items[item.id] = item end
local exported_docker = assert(items["/system.slice/docker-" .. DOCKER .. ".scope"])
equal(exported_docker.semantics.runtime, "docker", "the export names the runtime")
equal(exported_docker.semantics.container_short_id, "8a1bcccc1234",
  "the export publishes the short id")
equal(exported_docker.semantics.container_id, DOCKER, "the export publishes the full id")
equal(exported_docker.semantics.label, "docker 8a1bcccc1234", "the export publishes the label")
local exported_pod = assert(items["/kubepods.slice/kubepods-besteffort.slice/"
  .. "kubepods-besteffort-pod" .. POD .. ".slice"])
equal(exported_pod.semantics.pod, "pod" .. POD, "the export publishes the pod uid")
local exported_root = assert(items["/"])
assert(type(exported_root.semantics) == "table", "every cgroup node carries a semantics object")
equal(next(exported_root.semantics), nil,
  "the root cgroup established no unit, container or pod")
equal(exported.summary.service_count, 2, "the export counts services")
equal(exported.summary.container_count, 2, "the export counts containers")
equal(exported.summary.pod_count, 1, "the export counts pods")
equal(exported.summary.user_session_count, 1, "the export counts login sessions")

print("ok: cgroup unit and container identity end to end")
