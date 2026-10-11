local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local CPUInfo = require("wtop.collectors.cpu_info")

local NUMA = {}
NUMA.__index = NUMA

local MEMORY_FIELDS = {
  MemTotal = "total_bytes", MemFree = "free_bytes", FilePages = "file_bytes",
  AnonPages = "anonymous_bytes", Shmem = "shared_bytes",
}
local ALLOCATION_FIELDS = {
  numa_hit = "numa_hit_pages", numa_miss = "numa_miss_pages",
  numa_foreign = "numa_foreign_pages", interleave_hit = "interleave_hit_pages",
  local_node = "local_node_pages", other_node = "other_node_pages",
}

local function id_list(text, limit, maximum)
  if type(text) ~= "string" then return nil end
  if Common.trim(text) == "" then return {} end
  return CPUInfo.parse_cpu_list(text, limit, maximum)
end

local function same_ids(a, b)
  if not a or not b or #a ~= #b then return false end
  for index, id in ipairs(a) do if b[index] ~= id then return false end end
  return true
end

local function memory_info(text, id)
  if type(text) ~= "string" then return nil end
  local result = {}
  for line in text:gmatch("[^\n]+") do
    local node, key, value, unit = line:match("^Node%s+(%d+)%s+([%w_()]+):%s+(%S+)%s*(%a*)%s*$")
    local field = MEMORY_FIELDS[key]
    if field then
      value = value:match("^%d+$") and tonumber(value)
      if tonumber(node) ~= id or unit ~= "kB" or not value
          or math.type(value) ~= "integer" or value < 0
          or value > math.maxinteger // 1024 or result[field] ~= nil then return nil end
      result[field] = value * 1024
    end
  end
  if result.total_bytes == nil or result.free_bytes == nil
      or result.free_bytes > result.total_bytes then return nil end
  result.used_bytes = result.total_bytes - result.free_bytes
  return result
end

local function allocation_info(text)
  if type(text) ~= "string" then return nil, false end
  local values, seen, invalid = {}, {}, false
  for line in text:gmatch("[^\n]+") do
    local key, raw = line:match("^([%w_]+)%s+(%S+)%s*$")
    local field = key and ALLOCATION_FIELDS[key]
    if field then
      if seen[field] then
        values[field] = nil
        invalid = true
      else
        seen[field] = true
        local value = raw:match("^%d+$") and tonumber(raw)
        if value and math.type(value) == "integer" and value >= 0 then
          values[field] = value
        else
          invalid = true
        end
      end
    elseif line:match("%S") and not key then
      invalid = true
    end
  end
  local complete = not invalid
  local count = 0
  for _, field in pairs(ALLOCATION_FIELDS) do
    if values[field] == nil then complete = false else count = count + 1 end
  end
  return count > 0 and values or nil, complete
end

local function distances(text, online)
  if type(text) ~= "string" or not online then return nil end
  local result = {}
  for token in text:gmatch("%S+") do
    local value = token:match("^%d+$") and tonumber(token)
    if not value or value < 1 or value > 65535 or not online[#result + 1] then return nil end
    result[#result + 1] = { node_id = online[#result + 1], distance = value }
  end
  return #result == #online and result or nil
end

local function entries(self, fs)
  local names, err, cut = fs:list(self.base_path, 1024)
  if not names then return nil, err end
  local result = {}
  for index, name in ipairs(names) do
    if index > 1024 then cut = true break end
    local id = type(name) == "string" and tonumber(name:match("^node(%d+)$"))
    if id and id <= 65535 and name == "node" .. tostring(id) then
      result[#result + 1] = id
    end
  end
  table.sort(result)
  return result, nil, cut == true or #result > self.max_nodes
end

function NUMA.new(options)
  options = options or {}
  if type(options) ~= "table" then error("NUMA options must be a table", 2) end
  return setmetatable({ id = "numa", _method_style = true,
    fs = options.fs or FS.default,
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 2000),
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/devices/system/node"),
    max_nodes = Common.positive_integer("max_nodes", options.max_nodes, 128, 128),
    max_cpus = Common.positive_integer("max_cpus", options.max_cpus, 4096, 65536),
  }, NUMA)
end

function NUMA:probe(context)
  local ids, err = entries(self, Common.fs(context, self.fs))
  if ids and #ids > 0 then return Capability.available({ source = self.base_path }) end
  if err and FS.error_status(err) == "denied" then
    return Capability.denied(err.message, { source = self.base_path })
  end
  return Capability.unavailable(ids and "no_numa_nodes" or "numa_unavailable",
    { source = self.base_path })
end

function NUMA:sample(context, previous)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local previous_data = Common.previous_data(previous)
  local previous_by_id = {}
  for _, node in ipairs(previous_data and previous_data.nodes or {}) do
    previous_by_id[node.id] = node
  end
  local ids, err, truncated = entries(self, fs)
  if not ids then return Common.error_result(err, Common.now_ns(context), self.base_path) end
  if #ids == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { reason = "no_numa_nodes", source = self.base_path })
  end
  local online_path = self.base_path .. "/online"
  local online_text, online_error = fs:read(online_path, 65536)
  local online = id_list(online_text, 4096, 65535)
  local online_set = {}
  for _, id in ipairs(online or {}) do online_set[id] = true end
  local distance_nodes = online and #online <= self.max_nodes and online or nil
  truncated = truncated or online ~= nil and #online > self.max_nodes
  local result = { nodes = {}, online_nodes = online, truncated = truncated, issues = {} }
  local function issue(target, field, path, failure)
    target[#target + 1] = { field = field, source = path,
      status = failure and FS.error_status(failure) or "error",
      reason = failure and failure.message or "invalid_result" }
  end
  if not online then issue(result.issues, "online", online_path, online_error) end
  local partial = truncated or #result.issues > 0
  for index = 1, math.min(#ids, self.max_nodes) do
    local id = ids[index]
    local base = self.base_path .. "/node" .. id
    local node = { id = id, source = base, issues = {},
      online = online and online_set[id] == true or nil }
    -- Preserve false for a known offline node; nil means the online set failed.
    if online then node.online = online_set[id] == true end
    local cpus, cpu_error = fs:read(base .. "/cpulist", 65536)
    node.cpu_ids = id_list(cpus, self.max_cpus, 2147483647)
    if not node.cpu_ids then issue(node.issues, "cpu_ids", base .. "/cpulist", cpu_error) end
    local mem, mem_error = fs:read(base .. "/meminfo", 65536)
    node.memory = memory_info(mem, id)
    if not node.memory then issue(node.issues, "memory", base .. "/meminfo", mem_error) end
    local stats_path = base .. "/numastat"
    local stats, stats_error = fs:read(stats_path, 4096)
    if stats then
      local complete
      node.allocations, complete = allocation_info(stats)
      if not complete then issue(node.issues, "allocations", stats_path) end
    elseif stats_error and stats_error.kind ~= "missing" then
      issue(node.issues, "allocations", stats_path, stats_error)
    end
    local dist, dist_error = fs:read(base .. "/distance", 65536)
    node.distances = distances(dist, distance_nodes)
    if not node.distances then issue(node.issues, "distances", base .. "/distance", dist_error) end
    node.quality = #node.issues > 0 and "partial" or "fresh"
    partial = partial or #node.issues > 0
    result.nodes[#result.nodes + 1] = node
  end
  -- Distance columns enumerate ONLINE nodes, not 0..N or the directory list.
  -- A hotplug between reads can change the meaning of every column.
  local after, after_error = fs:read(online_path, 65536)
  if not same_ids(online, id_list(after, 4096, 65535)) then
    partial = true
    issue(result.issues, "online", online_path, after_error)
    for _, node in ipairs(result.nodes) do
      node.distances = nil
      node.quality = "partial"
    end
  end
  local finished = Common.now_ns(context)
  local elapsed_ns = previous and Common.elapsed_ns(finished, previous.timestamp_ns)
  for _, node in ipairs(result.nodes) do
    local current = node.allocations
    local old = previous_by_id[node.id] and previous_by_id[node.id].allocations
    if current then
      local local_rate, local_reason = Common.rate(current.local_node_pages,
        old and old.local_node_pages, elapsed_ns)
      local other_rate, other_reason = Common.rate(current.other_node_pages,
        old and old.other_node_pages, elapsed_ns)
      if local_rate or other_rate then
        current.rates = { local_pages_per_second = local_rate,
          other_pages_per_second = other_rate }
      end
      current.rate_quality = (local_reason == "reset" or other_reason == "reset")
        and "reset" or (local_rate and other_rate) and "fresh" or "gap"
    end
  end
  return Common.result("ok", finished, result, {
    quality = partial and "partial" or "fresh",
    reason = partial and "numa_data_incomplete" or nil,
    source = self.base_path, duration_ns = Common.elapsed_ns(finished, started) or 0,
  })
end

return NUMA
