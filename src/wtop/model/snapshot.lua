local Snapshot = {}

local RESOURCE_KEYS = {
  cpu = true,
  memory = true,
  pressure = true,
  disks = true,
  network = true,
  connections = true,
  processes = true,
  gpus = true,
  cpu_frequency = true,
  sensors = true,
  mounts = true,
  workloads = true,
}

local ID_TO_RESOURCE = {
  disk = "disks",
  gpu = "gpus",
  process = "processes",
  cpufreq = "cpu_frequency",
  hwmon = "sensors",
  cgroup = "workloads",
  psi = "pressure",
}

local VALID_STATUS = { ok = true, unavailable = true, denied = true, error = true }
local VALID_QUALITY = {
  fresh = true, stale = true, gap = true, estimated = true, unavailable = true,
  denied = true, error = true, partial = true, reset = true, measured = true,
}

local function nonnegative_integer(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge and value >= 0 and value % 1 == 0
end

local function nonnegative_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge and value >= 0
end

local function shallow_copy(value)
  local result = {}
  if value then
    for key, item in pairs(value) do
      result[key] = item
    end
  end
  return result
end

function Snapshot.new(sequence, timestamp_ns)
  sequence = sequence == nil and 0 or sequence
  timestamp_ns = timestamp_ns == nil and 0 or timestamp_ns
  if not nonnegative_integer(sequence) then error("invalid snapshot sequence", 2) end
  if not nonnegative_number(timestamp_ns) then error("invalid snapshot timestamp", 2) end
  return {
    sequence = sequence,
    timestamp_ns = timestamp_ns,
    cpu = {},
    memory = {},
    pressure = {},
    disks = {},
    network = {},
    connections = {},
    processes = {},
    gpus = {},
    cpu_frequency = {},
    sensors = {},
    mounts = {},
    workloads = {},
    quality = {},
    collectors = {},
  }
end

function Snapshot.merge(previous, results, sequence, timestamp_ns)
  previous = previous or Snapshot.new()
  if type(previous) ~= "table" then error("previous snapshot must be a table", 2) end
  if results ~= nil and type(results) ~= "table" then error("results must be a table", 2) end
  local next_sequence = sequence
  if next_sequence == nil then
    if not nonnegative_integer(previous.sequence) or previous.sequence >= math.maxinteger then
      error("snapshot sequence is out of range", 2)
    end
    next_sequence = previous.sequence + 1
  end
  local snapshot = Snapshot.new(next_sequence, timestamp_ns or previous.timestamp_ns)
  for key in pairs(RESOURCE_KEYS) do
    snapshot[key] = previous[key]
  end
  snapshot.quality = shallow_copy(previous.quality)
  snapshot.collectors = shallow_copy(previous.collectors)

  for id, result in pairs(results or {}) do
    if type(id) ~= "string" or id == "" or #id > 256 or id:find("\0", 1, true) then
      goto continue
    end
    local resource = ID_TO_RESOURCE[id] or id
    local status = type(result) == "table" and result.status or "error"
    local quality = type(result) == "table" and result.quality or "error"
    if not VALID_STATUS[status] then status, quality = "error", "error" end
    if not VALID_QUALITY[quality] then quality = status == "ok" and "fresh" or status end
    if RESOURCE_KEYS[resource] and status == "ok" and result.data ~= nil then
      snapshot[resource] = result.data
    elseif RESOURCE_KEYS[resource] and previous[resource] ~= nil then
      -- Preserve the last usable sample, but never preserve its freshness.
      if status == "denied" then
        quality = "denied"
      elseif status == "unavailable" then
        quality = "unavailable"
      elseif quality ~= "gap" then
        quality = "stale"
      end
    end
    snapshot.quality[resource] = {
      status = status,
      quality = quality,
      reason = type(result) == "table" and result.reason or nil,
      timestamp_ns = type(result) == "table" and nonnegative_number(result.timestamp_ns)
          and result.timestamp_ns or snapshot.timestamp_ns,
      duration_ns = type(result) == "table" and nonnegative_number(result.duration_ns)
          and result.duration_ns or nil,
    }
    if type(result) ~= "table" then
      snapshot.quality[resource].reason = "invalid_result"
    end
    snapshot.collectors[id] = result
    ::continue::
  end

  return snapshot
end

function Snapshot.resource_for_collector(id)
  return ID_TO_RESOURCE[id] or id
end

return Snapshot
