local Capability = require("wtop.core.capability")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local Disk = {}
Disk.__index = Disk

local MAX_SLAVES_PER_DEVICE = 4096

local function positive_integer(value)
  return type(value) == "number" and value == value and value ~= math.huge
    and value ~= -math.huge and value > 0 and value % 1 == 0 and value or nil
end

local function finite_nonnegative(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge and value >= 0
end

local function delta(current, previous, key)
  if not previous then
    return nil, "baseline"
  end
  return Common.delta(current[key], previous[key])
end


-- Static block-device identity.  These files are cheap and change only on
-- hotplug, but they are what turns an opaque "sda" row into something an
-- operator recognises, and `size` is what lets the UI hide the 16 zero-length
-- ramdisks a default kernel registers.
local function read_identity(fs, device)
  local base = "/sys/block/" .. device.name
  local function optional(path, limit)
    local value = fs:read(base .. "/" .. path, 4096)
    if type(value) ~= "string" then return nil end
    local trimmed = Common.trim(value)
    if trimmed == "" then return nil end
    return Common.safe_text(trimmed, limit or 64)
  end
  local sectors = fs:read_number(base .. "/size")
  local rotational = fs:read_number(base .. "/queue/rotational")
  local scheduler = optional("queue/scheduler", 128)
  if scheduler then
    -- The file lists every registered scheduler with the active one bracketed.
    scheduler = scheduler:match("%[(%S+)%]") or scheduler:match("^(%S+)$") or scheduler
  end
  return {
    model = optional("device/model", 64),
    vendor = optional("device/vendor", 64),
    firmware = optional("device/rev", 32),
    size_bytes = type(sectors) == "number" and sectors >= 0
      and sectors <= math.maxinteger // 512 and sectors * 512 or nil,
    rotational = type(rotational) == "number" and rotational or nil,
    removable = fs:read_number(base .. "/removable") == 1,
    scheduler = scheduler,
    queue_depth = fs:read_number(base .. "/device/queue_depth"),
    read_ahead_kib = fs:read_number(base .. "/queue/read_ahead_kb"),
    -- ram/loop/zram devices are kernel plumbing rather than storage the
    -- operator provisioned; the UI hides them by default.
    virtual = device.name:match("^ram%d") ~= nil
      or device.name:match("^loop%d") ~= nil
      or device.name:match("^zram%d") ~= nil,
  }
end

local function read_sector_sizes(fs, device)
  local base = "/sys/dev/block/" .. device.id
  local logical = fs:read_number(base .. "/queue/logical_block_size")
  local physical = fs:read_number(base .. "/queue/physical_block_size")
    or fs:read_number(base .. "/queue/hw_sector_size")
  return positive_integer(logical), positive_integer(physical)
end

local function read_topology(fs, device)
  local base = "/sys/dev/block/" .. device.id
  local partition = positive_integer(fs:read_number(base .. "/partition"))
  local diskseq = positive_integer(fs:read_number(base .. "/diskseq"))
  local slaves, slaves_error, slaves_truncated = fs:list(
    base .. "/slaves", MAX_SLAVES_PER_DEVICE + 1)
  if type(slaves) == "table" and #slaves > MAX_SLAVES_PER_DEVICE then
    for index = #slaves, MAX_SLAVES_PER_DEVICE + 1, -1 do slaves[index] = nil end
    slaves_truncated = true
  end
  local stacked = type(slaves) == "table" and #slaves > 0
  return {
    partition = partition,
    diskseq = diskseq,
    stacked = stacked,
    slaves = type(slaves) == "table" and slaves or nil,
    slaves_truncated = slaves_truncated == true,
    partial = slaves_error ~= nil and slaves_error.kind ~= "missing"
      and slaves_error.kind ~= "unavailable",
  }
end

local function optional_delta(current, previous, key)
  if current[key] == nil or previous[key] == nil then
    return nil
  end
  return Common.delta(current[key], previous[key])
end

function Disk.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Disk options must be a table", 2) end
  if options.include ~= nil and type(options.include) ~= "function" then
    error("disk include must be a function", 2)
  end
  return setmetatable({
    id = "disk",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    fs = options.fs or FS.default,
    diskstats_path = Common.absolute_path(
      "diskstats_path", options.diskstats_path, "/proc/diskstats"),
    include = options.include,
    _method_style = true,
  }, Disk)
end

function Disk:probe(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.diskstats_path, 4 * 1024 * 1024)
  if content then
    return Capability.available({ source = self.diskstats_path })
  end
  local status = FS.error_status(err)
  if status == "denied" then
    return Capability.denied(err.message, { source = self.diskstats_path })
  end
  return Capability.unavailable(err and err.message or "diskstats_unavailable", { source = self.diskstats_path })
end

function Disk:sample(context, previous)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.diskstats_path, 4 * 1024 * 1024)
  if not content then
    return Common.error_result(err, Common.now_ns(context), self.diskstats_path)
  end
  local raw, parse_error = Parsers.diskstats(content)
  if not raw then
    return Common.result("error", Common.now_ns(context), nil, {
      quality = "error",
      reason = parse_error,
      source = self.diskstats_path,
    })
  end
  local now = Common.now_ns(context)
  local previous_data = Common.previous_data(previous)
  local elapsed_ns = previous_data and Common.elapsed_ns(now, previous.timestamp_ns) or nil
  local previous_map = previous_data
    and (previous_data.raw_by_identity or previous_data.raw_by_id) or {}
  local devices = {}
  local raw_by_id = {}
  local raw_by_identity = {}
  local any_gap = false
  local any_partial = false

  for _, current in ipairs(raw) do
    local include_ok, included = true, true
    if self.include then include_ok, included = pcall(self.include, current) end
    if not include_ok then any_partial = true end
    if include_ok and included then
      raw_by_id[current.id] = current
      local logical_sector_size, physical_sector_size = read_sector_sizes(fs, current)
      local topology = read_topology(fs, current)
      local identity = topology.diskseq
        and (current.id .. ":" .. tostring(topology.diskseq)) or current.id
      raw_by_identity[identity] = current
      local old = previous_map[identity]
      local device = {
        id = current.id,
        stable_id = identity,
        name = current.name,
        major = current.major,
        minor = current.minor,
        diskseq = topology.diskseq,
        identity_quality = topology.diskseq and "stable" or "major_minor",
        partition = topology.partition,
        is_partition = topology.partition ~= nil,
        stacked = topology.stacked,
        slaves = topology.slaves,
        topology_truncated = topology.slaves_truncated,
        partial = topology.slaves_truncated or topology.partial,
        -- Overview totals use one accounting layer. Partitions are already
        -- included in their whole disk and stacked targets are already
        -- represented by their leaf devices.
        aggregate = topology.partition == nil and not topology.stacked,
        -- Linux diskstats sector counters are always expressed in 512-byte
        -- accounting sectors, independent of logical/physical block size.
        accounting_sector_size_bytes = 512,
        logical_sector_size_bytes = logical_sector_size,
        physical_sector_size_bytes = physical_sector_size,
        identity = topology.partition == nil and read_identity(fs, current) or nil,
        in_flight = current.io_in_progress,
        counters = current,
        quality = "gap",
      }
      if old and elapsed_ns and elapsed_ns > 0 then
        local sectors_read, r1 = delta(current, old, "sectors_read")
        local sectors_written, r2 = delta(current, old, "sectors_written")
        local reads, r3 = delta(current, old, "reads_completed")
        local writes, r4 = delta(current, old, "writes_completed")
        local io_ms, r5 = delta(current, old, "io_time_ms")
        local read_ms, r6 = delta(current, old, "read_time_ms")
        local write_ms, r7 = delta(current, old, "write_time_ms")
        if sectors_read and sectors_written and reads and writes and io_ms and read_ms and write_ms then
          local seconds = elapsed_ns / 1000000000
          device.read_bytes_per_second = (sectors_read + 0.0) * 512 / seconds
          device.write_bytes_per_second = (sectors_written + 0.0) * 512 / seconds
          device.read_iops = reads / seconds
          device.write_iops = writes / seconds
          device.busy_percent = math.max(0, math.min(100, io_ms / (elapsed_ns / 1000000) * 100))
          device.average_read_latency_ms = reads > 0 and read_ms / reads or nil
          device.average_write_latency_ms = writes > 0 and write_ms / writes or nil
          local weighted_ms = optional_delta(current, old, "weighted_io_time_ms")
          if weighted_ms then
            device.average_queue_size = weighted_ms / (elapsed_ns / 1000000)
          end
          local discarded = optional_delta(current, old, "sectors_discarded")
          local discards = optional_delta(current, old, "discards_completed")
          local discard_ms = optional_delta(current, old, "discard_time_ms")
          if discarded then device.discard_bytes_per_second = (discarded + 0.0) * 512 / seconds end
          if discards then device.discard_iops = discards / seconds end
          if discards and discard_ms then
            device.average_discard_latency_ms = discards > 0 and discard_ms / discards or nil
          end
          local flushes = optional_delta(current, old, "flushes_completed")
          local flush_ms = optional_delta(current, old, "flush_time_ms")
          if flushes then device.flush_iops = flushes / seconds end
          if flushes and flush_ms then
            device.average_flush_latency_ms = flushes > 0 and flush_ms / flushes or nil
          end
          local valid_rates = finite_nonnegative(device.read_bytes_per_second)
            and finite_nonnegative(device.write_bytes_per_second)
            and finite_nonnegative(device.read_iops) and finite_nonnegative(device.write_iops)
            and finite_nonnegative(device.busy_percent)
          for _, key in ipairs({ "average_read_latency_ms", "average_write_latency_ms",
              "average_queue_size", "discard_bytes_per_second", "discard_iops",
              "average_discard_latency_ms", "flush_iops", "average_flush_latency_ms" }) do
            if device[key] ~= nil and not finite_nonnegative(device[key]) then valid_rates = false end
          end
          if valid_rates then
            device.quality = "fresh"
          else
            device.reset_reason = "derived_value_out_of_range"
          end
        else
          device.reset_reason = r1 or r2 or r3 or r4 or r5 or r6 or r7
        end
      end
      if device.partial then
        device.quality = "partial"
        any_partial = true
      end
      any_gap = any_gap or device.quality == "gap"
      devices[#devices + 1] = device
    end
  end

  table.sort(devices, function(left, right)
    if left.major == right.major then
      return left.minor < right.minor
    end
    return left.major < right.major
  end)
  return Common.result("ok", now, {
    devices = devices,
    raw_by_id = raw_by_id,
    raw_by_identity = raw_by_identity,
  }, {
    quality = any_partial and "partial" or (any_gap and "gap" or "fresh"),
    duration_ns = Common.elapsed_ns(now, started) or 0,
    source = self.diskstats_path,
  })
end

return Disk
