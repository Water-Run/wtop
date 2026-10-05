-- The disk collector's reason column.
--
-- This file exists because the disk collector had no test of its own at all
-- before it, and instrumenting the two locals its quality expression reads
-- turned up the reason why that had gone unnoticed: across the whole suite the
-- collector produced three samples, and **not one of them was `partial`** --
-- the quality the item this closes spent eight increments arguing about.  So
-- all three of its leaf causes are built here from nothing, rather than
-- assumed.
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local Disk = require("wtop.collectors.disk")

local REASON = { partial = "disk_data_partial",
  gap = "disk_rate_unavailable", fresh = false }
local reason_is = function(result, label)
  return require("support.collector_reason").assert_reason(result, REASON, label)
end

-- One diskstats line: the two counters that matter here are reads completed
-- (field 4) and writes completed (field 8), and the derived rate needs the
-- sector counters too.
local function diskstats(major, minor, name, reads, writes, read_sectors, write_sectors)
  local fields = { major, minor, name, reads, 0, read_sectors, 0,
    writes, 0, write_sectors, 0, 300, 400, 0, 0, 0, 0, 0, 0 }
  local numbers = {}
  for index, value in ipairs(fields) do numbers[index] = tostring(value) end
  return table.concat(numbers, " ") .. "\n"
end

local function fake_fs(files, directories, list_errors)
  list_errors = list_errors or {}
  return {
    read = function(_, path)
      local value = files[path]
      if type(value) == "function" then value = value(path) end
      if value == nil then
        return nil, { kind = "missing", message = "fixture_missing", path = path }
      end
      return tostring(value)
    end,
    read_number = function(self, path)
      local value, err = self:read(path)
      if not value then return nil, err end
      local number = tonumber(value:match("^%s*([^%s]+)"))
      if not number then
        return nil, { kind = "parse_error", message = "expected_number" }
      end
      return number
    end,
    list = function(_, path)
      local refusal = list_errors[path]
      if refusal then return nil, refusal end
      local values = directories[path]
      if values == nil then
        return nil, { kind = "missing", message = "fixture_directory_missing", path = path }
      end
      local copy = {}
      for index, value in ipairs(values) do copy[index] = value end
      return copy
    end,
  }
end

local now = 1000000000
local function context(fs) return { fs = fs, now_ns = function() return now end } end
local function scan(collector, files, dirs, list_errors, previous)
  return collector:sample(context(fake_fs(files, dirs, list_errors)), previous)
end

local function base_files(body)
  return {
    ["/proc/diskstats"] = body,
    ["/sys/dev/block/8:0/queue/logical_block_size"] = "512\n",
    ["/sys/dev/block/8:0/queue/physical_block_size"] = "4096\n",
    ["/sys/dev/block/8:0/diskseq"] = "7\n",
  }
end
local base_dirs = {
  ["/sys/dev/block/8:0/slaves"] = {},
}

-- `gap`: a first sample.  The table is complete and readable; there is simply
-- no earlier counter to difference against, which is the same word process and
-- cgroup already carry and for the same reason.
local first = scan(Disk.new(), base_files(diskstats(8, 0, "sda", 100, 50, 1000, 500)),
  base_dirs)
assert(first.status == "ok" and first.quality == "gap")
assert(#first.data.devices == 1 and first.data.devices[1].quality == "gap")
assert(first.data.devices[1].read_bytes_per_second == nil)
reason_is(first, "a disk table with nothing to difference against")

-- `fresh`: the same table one second later with the counters moved.  The fresh
-- row is the only one that can contradict the other two, so a reason published
-- here would tell a user their disk data is incomplete when it is not.
now = now + 1000000000
local second = scan(Disk.new(), base_files(diskstats(8, 0, "sda", 300, 150, 3000, 1500)),
  base_dirs, nil, first)
assert(second.status == "ok" and second.quality == "fresh")
assert(second.data.devices[1].quality == "fresh")
assert(type(second.data.devices[1].read_bytes_per_second) == "number")
reason_is(second, "a disk table with a rate")

-- `partial`, first of three: the slaves listing was refused.  This is the
-- cause that looks like the others -- a read that failed -- and the reason
-- needs to say so without the cap and the raising filter being forced into the
-- same description.
now = now + 1000000000
local refused_slaves = scan(Disk.new(),
  base_files(diskstats(8, 0, "sda", 500, 250, 5000, 2500)), base_dirs,
  { ["/sys/dev/block/8:0/slaves"] = { kind = "denied", message = "permission denied",
    path = "/sys/dev/block/8:0/slaves" } }, second)
assert(refused_slaves.status == "ok" and refused_slaves.quality == "partial")
assert(refused_slaves.data.devices[1].partial)
assert(refused_slaves.data.devices[1].slaves == nil
  and refused_slaves.data.devices[1].stacked == false)
assert(refused_slaves.data.devices[1].diskseq == 7,
  "the identity was still read; it is the topology that was refused")
reason_is(refused_slaves, "a disk table whose slave listing was refused")

-- `partial`, second: the same listing stopped at its 4096-slave cap.  Nothing
-- failed to be read here, and that is the whole reason the reason says
-- *collected* rather than *read* -- a user told a read failed would go looking
-- for permissions on a directory it has full access to.
now = now + 1000000000
local many_slaves = {}
for index = 1, 4097 do many_slaves[index] = "sda" .. index end
local capped = scan(Disk.new(),
  base_files(diskstats(8, 0, "sda", 700, 350, 7000, 3500)),
  { ["/sys/dev/block/8:0/slaves"] = many_slaves }, nil, refused_slaves)
assert(capped.status == "ok" and capped.quality == "partial")
assert(capped.data.devices[1].partial)
assert(capped.data.devices[1].topology_truncated == true)
assert(#capped.data.devices[1].slaves == 4096, "the cap is what bounds the list")
reason_is(capped, "a disk table whose slave listing hit its cap")

-- `partial`, third, and the one that closed this item eight increments ago:
-- the caller's `include` predicate raised.  It was recorded then as "not a
-- partial read at all", and the test that rejects a reason is not that every
-- cause is a read that failed -- it is that one sentence is true of every
-- cause.  Here /proc/diskstats published the device, the predicate threw on it,
-- and the result does not contain it.  So the device is *missing from the
-- result*, which is what "could not be collected" says, and asserting that the
-- device is genuinely absent is what makes the sentence true rather than
-- merely plausible.
now = now + 1000000000
local raised = scan(Disk.new({ include = function() error("filter exploded") end }),
  base_files(diskstats(8, 0, "sda", 900, 450, 9000, 4500)), base_dirs, nil, capped)
assert(raised.status == "ok" and raised.quality == "partial")
assert(#raised.data.devices == 0,
  "a device the caller's filter dropped is absent from the result, not shown degraded")
assert(raised.data.raw_by_id == nil or next(raised.data.raw_by_id) == nil)
assert(raised.data.devices[1] == nil)
-- The table itself was read perfectly: diskstats parsed, and the identity and
-- sector sizes are the ones the *same* sample reads for every other device.
-- So nothing about /proc/diskstats is wrong, and a reason claiming something
-- was not read would be false.
reason_is(raised, "a disk table whose caller's filter raised")

-- An `include` that raises on one device and not another is still one reason:
-- the quality does not depend on which device the predicate gave up on.
now = now + 1000000000
local mixed_body = diskstats(8, 0, "sda", 1100, 550, 11000, 5500)
  .. diskstats(8, 16, "sdb", 200, 100, 2000, 1000)
local mixed_files = base_files(mixed_body)
mixed_files["/sys/dev/block/8:16/queue/logical_block_size"] = "512\n"
mixed_files["/sys/dev/block/8:16/queue/physical_block_size"] = "4096\n"
mixed_files["/sys/dev/block/8:16/diskseq"] = "8\n"
local mixed_dirs = {
  ["/sys/dev/block/8:0/slaves"] = {}, ["/sys/dev/block/8:16/slaves"] = {},
}
local mixed = scan(Disk.new({
  include = function(device) if device.id == "8:0" then error("no") end return true end,
}), mixed_files, mixed_dirs, nil, raised)
assert(mixed.quality == "partial")
assert(#mixed.data.devices == 1 and mixed.data.devices[1].id == "8:16",
  "the device the filter accepted is still published")
reason_is(mixed, "a disk table whose caller's filter raised on one device")

return true
