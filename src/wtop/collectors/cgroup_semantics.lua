-- systemd unit and container semantics derived from a cgroup v2 path.
--
-- The kernel reports cgroups as opaque path components, so a pod looks like
-- "/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod5d4f...slice/
-- cri-containerd-8a1b....scope".  That is a fact, but it is not something an
-- operator reads quickly.  This module turns the well-known systemd, Docker,
-- containerd, podman, Kubernetes and LXC conventions back into the unit and
-- container identity they encode.
--
-- Everything here is a pure function over a path string, deliberately separate
-- from the collector: the cgroup name is attacker-influenced (a process can
-- create one), so nothing here touches the filesystem, executes anything, or
-- returns a value it has not matched a documented pattern for.  An
-- unrecognised layout reports nil rather than a guess, because a wrong unit
-- name is worse than no unit name.
local M = {}

-- Long enough for a full container id, short enough that a hostile cgroup name
-- cannot inflate every table row.
local MAX_ID_LENGTH = 128
local MAX_DEPTH = 32

local CONTROL = "%c"
local SAFE = "^[%w%.%-%_@:]+$"

local RUNTIMES = {
  docker = "docker",
  containerd = "containerd",
  ["cri-containerd"] = "containerd",
  crio = "cri-o",
  podman = "podman",
  libpod = "podman",
  lxc = "lxc",
}

-- systemd unit types that can own a cgroup.  A ".device" or ".swap" unit is
-- always synthetic and never appears as a directory, so neither is listed.
local UNIT_TYPES = {
  service = true,
  scope = true,
  slice = true,
  mount = true,
  automount = true,
  socket = true,
  target = true,
  path = true,
  timer = true,
}

local function bounded(value)
  if type(value) ~= "string" or value == "" or #value > MAX_ID_LENGTH then return nil end
  if value:find(CONTROL) then return nil end
  if not value:match(SAFE) then return nil end
  return value
end

-- "/a/b/c" -> { "a", "b", "c" }.  A path with too many components is refused
-- rather than truncated, since a truncated path would name the wrong parent.
local function components(path)
  if type(path) ~= "string" or path == "" or #path > 4096 then return nil end
  if path:find(CONTROL) then return nil end
  local parts = {}
  for part in path:gmatch("[^/]+") do
    parts[#parts + 1] = part
    if #parts > MAX_DEPTH then return nil end
  end
  if #parts == 0 then return nil end
  return parts
end

-- Docker and containerd name a scope "<runtime>-<id>"; the id is a long run of
-- lowercase hex and the whole component carries a .scope suffix.  The runtime
-- name is looked up rather than split off greedily: the entire stem matches
-- the prefix character class, so a greedy split would eat the id.
local function split_runtime_id(component)
  local stem = component:match("^(.-)%.scope$") or component
  for prefix, runtime in pairs(RUNTIMES) do
    local id = stem:match("^" .. prefix:gsub("%-", "%%-") .. "%-(.+)$")
    if id and #id >= 12 and id:match("^[%x][%x%-]+$") then
      return runtime, bounded(id)
    end
  end
  return nil
end

-- Under a runtime directory the next component *is* the container, named by
-- the runtime rather than the kernel: an id for Docker, containerd, CRI-O and
-- podman, a free-form name for LXC.  No shape check is applied, because the
-- layout itself is the evidence and LXC names are not constrained at all.
-- A component with no systemd suffix elsewhere is only a container when it is
-- a long lowercase-hex id, which is all the kubepods cgroupfs form promises.
local function is_container_name(part)
  return #part >= 12 and part:match("^[%x]+$") ~= nil
end

--- Classify one cgroup path.
-- Returns a table that is always safe to render, with nil for anything the
-- path does not establish.  "container" and friends say what the path belongs
-- to; the matching "*_scope" fields say whether *this* component is that
-- thing, so a subtree does not get counted as a second container.
function M.classify(path)
  local parts = components(path)
  if not parts then return {} end
  local result = {}
  local last = #parts

  local unit, unit_type
  local runtime, container_id, container_index
  local user_id, user_index
  local pod_uid, pod_index

  for index, part in ipairs(parts) do
    local safe = bounded(part)
    if safe then
      if safe:match("^user%-(%d+)%.slice$") then
        user_id = tonumber(safe:match("^user%-(%d+)%.slice$"))
        user_index = index
      end
      -- Both drivers name the pod: systemd with a "kubepods-...-pod<uid>.slice"
      -- component, the cgroupfs driver with a bare "pod<uid>" directory.
      local pod = safe:match("^kubepods.*%-(pod[%x%-]+)%.slice$")
        or safe:match("^(pod[%x][%x%-]*)$")
      if pod then
        pod_uid = bounded(pod)
        pod_index = index
      end
      local found_runtime, found_id = split_runtime_id(safe)
      if found_runtime and not container_id then
        runtime, container_id, container_index = found_runtime, found_id, index
        if not unit then unit, unit_type = safe, "scope" end
      elseif RUNTIMES[safe] then
        -- The cgroupfs driver puts the id in the next component, so the
        -- component after this one is the one to read.
        runtime = runtime or RUNTIMES[safe]
      end
    end
  end

  -- A component with no systemd suffix names a container when it sits directly
  -- under a runtime directory, or when it is a container id under a pod slice.
  if not container_id then
    for index, part in ipairs(parts) do
      local safe = bounded(part)
      local parent = index > 1 and bounded(parts[index - 1]) or nil
      if safe and parent and RUNTIMES[parent] then
        container_id, runtime, container_index = safe, RUNTIMES[parent], index
        break
      end
      if safe and is_container_name(safe) then
        -- Under kubepods the runtime is the CRI implementation, which the path
        -- does not record, so it is left unknown rather than invented.
        for ancestor = 1, index - 1 do
          local above = bounded(parts[ancestor])
          if above and above:match("^kubepods") then
            container_id, container_index = safe, index
            break
          end
        end
        if container_id then break end
      end
    end
  end

  -- The innermost systemd component is the unit.  A path that ends in an
  -- opaque component has no unit of its own and inherits nothing, because its
  -- parent's unit is already a row of its own.  Only the unit types that can
  -- own a cgroup are recognised: systemd's device and swap units never have
  -- one, so a ".device" directory is something else entirely.
  local innermost = bounded(parts[last])
  if innermost and unit == nil then
    local suffix = innermost:match("%.([%a]+)$")
    if suffix and UNIT_TYPES[suffix] then
      unit, unit_type = innermost, suffix
    end
  end
  -- A container's own scope is the unit even when a runtime prefix supplied it.
  if unit and not unit_type then unit_type = "scope" end

  result.unit = unit
  result.unit_type = unit_type
  result.container = container_id ~= nil or runtime ~= nil
  result.container_scope = container_index == last
  result.runtime = runtime
  result.container_id = container_id
  result.container_short_id = container_id and container_id:sub(1, 12) or nil
  result.pod = pod_uid
  result.pod_scope = pod_index == last
  result.user_id = user_id
  result.user_slice = user_index == last
  result.label = M.label(result)
  return result
end

--- A one-line label for a table row: what the cgroup is, not where it lives.
-- Only the node that *is* the thing gets the thing's name; a child of a
-- container is left to its own unit, which is what identifies it.
function M.label(class)
  if type(class) ~= "table" then return nil end
  if class.container_scope and class.container_short_id then
    -- Without a runtime the short id is all the path established; naming a CRI
    -- implementation here would be a guess, so the id stands on its own.
    return class.runtime and (class.runtime .. " " .. class.container_short_id)
      or class.container_short_id
  end
  if class.unit then return class.unit end
  if class.user_slice and class.user_id then return "user-" .. tostring(class.user_id) end
  return nil
end

return M
