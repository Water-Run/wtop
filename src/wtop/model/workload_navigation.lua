local M = {}

local function valid_integer(value)
  return type(value) == "number" and value == value and value % 1 == 0
    and value > 0 and value < math.huge
end

function M.target_id(process, kind)
  if type(process) ~= "table" then return nil end
  if kind == "cgroup2" then
    local found
    for index, cgroup in ipairs(process.cgroups or {}) do
      if index > 16 then break end
      if type(cgroup) == "table" and cgroup.hierarchy == 0
          and cgroup.controllers == "" and type(cgroup.path) == "string"
          and cgroup.path:sub(1, 1) == "/" and #cgroup.path <= 4096 then
        if found and found ~= cgroup.path then return nil end
        found = cgroup.path
      end
    end
    return found
  end
  if kind == "service" and valid_integer(process.pid)
      and valid_integer(process.starttime_ticks) then
    return "service:" .. process.pid .. ":" .. process.starttime_ticks
  end
end

-- A thread's cgroup can differ from its process's. Only the detail read for
-- the selected task generation may supply this target; never fall back to the
-- process cgroup when the thread's own read is pending or has disappeared.
function M.thread_target_id(process, thread, detail, selection)
  if type(process) ~= "table" or type(thread) ~= "table"
      or type(detail) ~= "table" or type(selection) ~= "table"
      or selection.mode ~= "detail" or type(process.id) ~= "string"
      or selection.process_id ~= process.id
      or not valid_integer(process.pid) or not valid_integer(thread.tid)
      or selection.tid ~= thread.tid or detail.tid ~= thread.tid
      or type(thread.starttime_ticks) ~= "number"
      or selection.starttime_ticks ~= thread.starttime_ticks
      or detail.starttime_ticks ~= thread.starttime_ticks
      or (detail.tgid ~= nil and detail.tgid ~= process.pid) then
    return nil
  end
  return M.target_id(detail, "cgroup2")
end

function M.find(workloads, id)
  if type(workloads) ~= "table" or type(id) ~= "string" then return nil end
  local indexed = type(workloads.by_id) == "table" and workloads.by_id[id]
  if type(indexed) == "table" and indexed.id == id then return indexed end
  for _, node in ipairs(workloads.workloads or {}) do
    if type(node) == "table" and node.id == id then return node end
  end
end

function M.result(workloads, quality, id, previous_quality)
  local node = M.find(workloads, id)
  if node then return node, "found" end
  if quality and quality ~= previous_quality then return nil, "missing" end
  return nil, "pending"
end

function M.expand_ancestors(workloads, id, collapsed)
  if type(collapsed) ~= "table" then return false end
  local node = M.find(workloads, id)
  if not node then return false end
  local seen = {}
  for _ = 1, 128 do
    local parent = node.parent_id
    if parent == nil then return true end
    if seen[parent] then return false end
    seen[parent] = true
    node = M.find(workloads, parent)
    if not node then return false end
    collapsed[parent] = nil
  end
  return false
end

return M
