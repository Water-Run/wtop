-- systemd unit and container identity, recovered from an opaque cgroup path.
-- The classification is pure string work on attacker-influenced names, so the
-- cases below cover both the well-known layouts and what must stay unknown.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Semantics = require("wtop.collectors.cgroup_semantics")

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      message, tostring(expected), tostring(actual)), 0)
  end
end

local function classify(path)
  local result = Semantics.classify(path)
  equal(type(result), "table", "classify returns a table for " .. path)
  return result
end

-- A plain systemd service is the case that has to stay exactly as it was.
local sshd = classify("/system.slice/sshd.service")
equal(sshd.unit, "sshd.service", "a service names itself")
equal(sshd.unit_type, "service", "a service is a service")
equal(sshd.container, false, "a host service is not a container")
equal(sshd.container_scope, false, "nothing scopes it to a container")
equal(sshd.label, "sshd.service", "a service is labelled by its unit")
equal(sshd.runtime, nil, "a host service has no runtime")
equal(sshd.pod, nil, "a host service belongs to no pod")

-- A login session sits under the user's slice, which is recorded separately so
-- that the session row and its children can be told apart.
local user_slice = classify("/user.slice/user-1000.slice")
equal(user_slice.unit_type, "slice", "user-1000.slice is a slice")
equal(user_slice.user_id, 1000, "the uid is read from the slice")
equal(user_slice.user_slice, true, "the slice is the session itself")
local session = classify("/user.slice/user-1000.slice/session-2.scope")
equal(session.unit, "session-2.scope", "the scope is its own unit")
equal(session.user_id, 1000, "the session still belongs to that uid")
equal(session.user_slice, false, "the session is not the slice")
equal(session.label, "session-2.scope", "the session is labelled by its unit")

-- Docker over the systemd driver: the runtime prefix and the id share one
-- component, and a greedy split would eat the id.
local DOCKER_ID = "8a1bcccc1234567890abcdef0123456789abcdef0123456789abcdef01234567"
local docker_scope = classify("/system.slice/docker-" .. DOCKER_ID .. ".scope")
equal(docker_scope.runtime, "docker", "the docker scope names its runtime")
equal(docker_scope.container_id, DOCKER_ID, "the whole id is recovered")
equal(docker_scope.container_short_id, "8a1bcccc1234", "the short id is 12 characters")
equal(docker_scope.container, true, "a docker scope is a container")
equal(docker_scope.container_scope, true, "the scope is the container itself")
equal(docker_scope.label, "docker 8a1bcccc1234", "the label is the runtime and short id")
equal(docker_scope.unit, "docker-" .. DOCKER_ID .. ".scope", "the full unit is still known")

-- The same container under the cgroupfs driver, where the id is a directory.
local docker_dir = classify("/docker/" .. DOCKER_ID)
equal(docker_dir.runtime, "docker", "the cgroupfs layout names its runtime too")
equal(docker_dir.container_id, DOCKER_ID, "the directory name is the id")
equal(docker_dir.container_scope, true, "the directory is the container itself")
equal(docker_dir.unit, nil, "a cgroupfs container is not a systemd unit")
equal(docker_dir.label, "docker 8a1bcccc1234", "the label needs no unit")

-- A container's own subdirectory is part of that container, not another one.
local docker_child = classify("/docker/" .. DOCKER_ID .. "/init")
equal(docker_child.container_id, DOCKER_ID, "the child still knows its container")
equal(docker_child.container_scope, false, "the child is not a second container")
equal(docker_child.label, nil, "the child has no label of its own")

-- LXC names containers freely, so the layout is the only evidence available.
local lxc = classify("/lxc/mycontainer")
equal(lxc.runtime, "lxc", "the lxc directory names the runtime")
equal(lxc.container_id, "mycontainer", "an lxc name is not required to be hex")
equal(lxc.container_short_id, "mycontainer", "a short name is not truncated further")
equal(lxc.container_scope, true, "the lxc directory is the container")
equal(lxc.label, "lxc mycontainer", "the label reads like the others")

-- podman names its scopes after itself, under the machine scope.
local podman = classify("/machine.slice/libpod-abc123def4567890abcdef01234567.scope")
equal(podman.runtime, "podman", "libpod is podman")
equal(podman.container_short_id, "abc123def456", "the podman id is read")
equal(podman.label, "podman abc123def456", "the podman label is readable")

-- Kubernetes: the pod is named by a slice under systemd and by a bare directory
-- under the cgroupfs driver.  Neither form records the CRI implementation, so
-- the runtime stays unknown instead of being guessed.
local POD = "pod5d4f9a1b2c3d"
local pod_slice = classify("/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-"
  .. POD .. ".slice")
equal(pod_slice.pod, POD, "the pod uid is read from the systemd slice")
equal(pod_slice.pod_scope, true, "the slice is the pod itself")
equal(pod_slice.container, false, "a pod is not yet a container")
local cri_scope = classify("/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-"
  .. POD .. ".slice/cri-containerd-abc123def4567890abcdef01234567.scope")
equal(cri_scope.runtime, "containerd", "cri-containerd is containerd")
equal(cri_scope.pod, POD, "the container still names its pod")
equal(cri_scope.pod_scope, false, "the container is not the pod")
equal(cri_scope.label, "containerd abc123def456", "the container label names the runtime")

local cgroupfs_pod = classify("/kubepods/" .. POD .. "/" .. DOCKER_ID)
equal(cgroupfs_pod.pod, POD, "the cgroupfs pod directory is named")
equal(cgroupfs_pod.container_id, DOCKER_ID, "the cgroupfs container id is named")
equal(cgroupfs_pod.runtime, nil, "the CRI implementation is not in the path")
equal(cgroupfs_pod.label, "8a1bcccc1234", "without a runtime the short id stands alone")

-- Every systemd unit type that can own a cgroup is named by its own component.
-- device and swap units never have a cgroup, so those suffixes stay unknown.
for _, unit_type in ipairs({ "service", "scope", "slice", "mount", "automount",
    "socket", "target", "path", "timer" }) do
  local classified = classify("/system.slice/sshd." .. unit_type)
  equal(classified.unit, "sshd." .. unit_type, "a ." .. unit_type .. " names itself")
  equal(classified.unit_type, unit_type, "a ." .. unit_type .. " is a " .. unit_type)
  equal(classified.label, "sshd." .. unit_type, "a ." .. unit_type .. " is labelled by its unit")
end
for _, unit_type in ipairs({ "device", "swap", "bogus" }) do
  equal(classify("/system.slice/sshd." .. unit_type).unit, nil,
    "a ." .. unit_type .. " is not a cgroup-owning unit")
end

-- What must stay unknown.  A path wtop cannot parse reports nothing, rather
-- than a plausible-looking guess.  The result is still a table, so a caller
-- never has to distinguish "unknown" from "broken" before reading a field.
local function establishes_nothing(path)
  local result = Semantics.classify(path)
  equal(next(result), nil, "an unparsed path establishes nothing: " .. tostring(path))
  return result
end

establishes_nothing("/")
equal(establishes_nothing("").label, nil, "an empty path has no label")
equal(establishes_nothing(nil).label, nil, "a nil path has no label")
equal(establishes_nothing(42).unit, nil, "a non-string path has no unit")

local spaced = classify("/opt/weird name")
equal(spaced.container, false, "a name with a space is not a container")
equal(spaced.unit, nil, "a name with a space names no unit")
equal(spaced.label, nil, "a name with a space has no label")

-- Refusing a path is different from truncating it: a truncated path would name
-- the wrong parent, so the whole classification is dropped.
local deep = "/" .. string.rep("b/", 40) .. "c"
equal(next(establishes_nothing(deep)), nil, "an over-deep path is refused outright")
establishes_nothing("/system.slice/sshd\tservice")

-- A short hex run outside a known layout is not a container.  The shape alone
-- is not evidence, and a wrong runtime is worse than none.
equal(classify("/system.slice/abcdef123456.service").container, false,
  "a hex-looking service name is not a container")
equal(classify("/system.slice/docker-tooshort.scope").container, false,
  "a docker prefix without a usable id is not a container")
equal(classify("/docker/toolongtorightbeingavalididentifier").container_scope, true,
  "the docker layout itself is evidence, whatever the child is called")

-- label() is also a public entry point for callers that already hold a class.
equal(Semantics.label({ container_scope = true, runtime = "docker",
  container_short_id = "8a1bcccc1234" }), "docker 8a1bcccc1234",
  "label composes runtime and short id")
equal(Semantics.label({ container_scope = false, unit = "child.scope" }), "child.scope",
  "label falls back to the unit")
equal(Semantics.label({}), nil, "an empty class has no label")
equal(Semantics.label(nil), nil, "a missing class has no label")
equal(Semantics.label("not a table"), nil, "a non-table has no label")

print("ok: cgroup systemd-unit and container semantics")
