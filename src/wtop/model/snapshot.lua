local Snapshot = {}

local RESOURCE_KEYS = {
  cpu = true,
  cpu_info = true,
  memory = true,
  pressure = true,
  disks = true,
  network = true,
  connections = true,
  processes = true,
  gpus = true,
  cpu_frequency = true,
  sensors = true,
  power = true,
  mounts = true,
  workloads = true,
  system = true,
  power_supplies = true,
  inventory = true,
}

-- A collector id that is not also a slot name is mapped here, because the id is
-- what a collector calls itself and the slot is what a consumer reads.  Measured,
-- nine of the seventeen registered collectors need this and eight do not, and an
-- entry for `psi` sat here for a collector that does not exist -- the pressure
-- collector calls itself `pressure`, which is already a slot name and so never
-- came through here.  It was harmless until it was not: a collector that took
-- the id `psi` would have resolved to `pressure`, which the real one owns, and
-- two collectors would have written one slot with nothing to say so.  Deleted, and
-- `tests/unit/test_core_primitives.lua` now holds the relation as two properties
-- -- every registered id reaches a slot, and no two ids reach the same one -- so a
-- stale alias that is ever taken fails rather than colliding.
local ID_TO_RESOURCE = {
  disk = "disks",
  gpu = "gpus",
  process = "processes",
  cpufreq = "cpu_frequency",
  hwmon = "sensors",
  powercap = "power",
  cgroup = "workloads",
  system_info = "system",
  power_supply = "power_supplies",
  inventory = "inventory",
}

-- The vocabularies live in `model/quality.lua`.  They used to be written here as
-- well as in `core/scheduler.lua` and `inspectors/model.lua`, and the three had
-- already diverged -- this one had eleven entries and the other two ten -- so
-- there is one list now and one place that says what it is.
local Quality = require("wtop.model.quality")
local VALID_STATUS = Quality.VALID_STATUS
local VALID_QUALITY = Quality.VALID_QUALITY

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
    cpu_info = {},
    memory = {},
    pressure = {},
    disks = {},
    network = {},
    connections = {},
    processes = {},
    gpus = {},
    cpu_frequency = {},
    sensors = {},
    power = {},
    mounts = {},
    workloads = {},
    system = {},
    power_supplies = {},
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
    -- The vocabulary is closed on purpose: these are the words the UI, the JSON
    -- snapshot and an agent all read, so an unpublishable one cannot be carried
    -- through.  What it must not become is the permissive answer.  Measured, an
    -- unknown quality on an `ok` result used to be rewritten to `fresh` while the
    -- status stayed `ok` and the reason survived beside it -- a record that
    -- contradicted itself, and a genuine degradation misspelled as `partail`
    -- published as fresh data.  The status line above already refused the
    -- permissive direction; this one now does the same, in one step, so a
    -- collector that cannot describe its own reading loses the label rather than
    -- gaining a flattering one.  The spelling that was refused is not recorded
    -- here -- `quality[resource]` has no field for it and adding one is a change
    -- to a published v1 document, which is a compatibility decision and not this
    -- patch's to make.
    if not VALID_STATUS[status] or not VALID_QUALITY[quality] then
      status, quality = "error", "error"
    end
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

-- The id map itself, so the relation can be inspected rather than only queried.
-- `resource_for_collector` answers "where does this id go" and says nothing about
-- the entries that name nothing, which is the direction a stale alias fails in:
-- it is inert until a collector takes the name, and nothing about a lookup can
-- tell an entry that is about to be needed from one that never will be.
Snapshot.RESOURCE_IDS = ID_TO_RESOURCE

return Snapshot
