package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local CPU = require("wtop.collectors.cpu")
local Engine = require("wtop.engine")
local Memory = require("wtop.collectors.memory")
local Pressure = require("wtop.collectors.pressure")
local Disk = require("wtop.collectors.disk")
local Network = require("wtop.collectors.network")
local Routes = require("wtop.linux.routes")
local Process = require("wtop.collectors.process")
local GPU = require("wtop.collectors.gpu")
local Common = require("wtop.collectors.common")
local Snapshot = require("wtop.model.snapshot")
local Export = require("wtop.export")
local Report = require("wtop.report")
local ViewModel = require("wtop.view_model")
local Hardware = require("wtop.model.hardware")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")

local function fixture(path)
  local file = assert(io.open("tests/fixtures/" .. path, "rb"))
  local content = assert(file:read("*a"))
  file:close()
  return content
end

local function fake_fs(files, directories, links)
  files, directories, links = files or {}, directories or {}, links or {}
  local fs = {}
  function fs:read(path)
    local value = files[path]
    if type(value) == "function" then
      value = value(path)
    end
    if value == nil then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    return tostring(value)
  end
  function fs:read_number(path)
    local value, err = self:read(path)
    if not value then return nil, err end
    local number = tonumber(value:match("^%s*([^%s]+)"))
    if not number then return nil, { kind = "parse_error", message = "expected_number" } end
    return number
  end
  function fs:list(path)
    local values = directories[path]
    if not values then
      return nil, { kind = "missing", message = "fixture_directory_missing", path = path }
    end
    local copy = {}
    for index, value in ipairs(values) do copy[index] = value end
    return copy
  end
  function fs:readlink(path)
    local value = links[path]
    if value then return value end
    return nil, { kind = "missing", message = "fixture_link_missing", path = path }
  end
  function fs:exists(path)
    return files[path] ~= nil or directories[path] ~= nil
  end
  return fs
end

local function near(actual, expected, epsilon)
  assert(type(actual) == "number", "expected a number, got " .. tostring(actual))
  assert(math.abs(actual - expected) <= (epsilon or 1e-6), tostring(actual) .. " ~= " .. tostring(expected))
end

local now = 1000000000
local context = { now_ns = function() return now end }

local cpu_files = {
  ["/proc/stat"] = fixture("proc/stat.1"),
  ["/proc/loadavg"] = fixture("proc/loadavg"),
}
context.fs = fake_fs(cpu_files)
local cpu = CPU.new()
assert(cpu:probe(context).available)
local cpu_first = cpu:sample(context)
assert(cpu_first.status == "ok" and cpu_first.quality == "gap")
cpu_files["/proc/stat"] = fixture("proc/stat.2")
now = now + 1000000000
local cpu_second = cpu:sample(context, cpu_first)
near(cpu_second.data.total.utilization, 45)
assert(cpu_second.data.load.running == 2)
local reset_cpu_text = fixture("proc/stat.2"):gsub(
  "cpu  130 5 50 850 25 3 4 0 0 0", "cpu  90 5 50 1000 25 3 4 0 0 0", 1)
cpu_files["/proc/stat"] = reset_cpu_text
now = now + 1000000000
local cpu_reset = cpu:sample(context, cpu_second)
assert(cpu_reset.data.total.quality == "gap" and cpu_reset.data.total.user == nil)

-- The CPU collector is the eleventh to publish a reason for a degraded but
-- running reading, and it is the first one where the measurement says the slot
-- cannot be ambiguous: `derive_cpu` returns `gap` from five places -- no
-- previous sample, a counter that went backwards, a delta that overflowed, an
-- idle larger than total, and a missing per-field delta -- and all five mean
-- the same thing, that this sample cannot be differenced against the last one.
-- `partial` has one cause too, the load average.  So the test asserts the
-- pairing, not just the presence of a reason: one quality, one code, and a
-- fresh reading with none at all.
local CPU_REASON = { gap = "cpu_counter_delta_unavailable",
  partial = "loadavg_unavailable", fresh = false }
local CollectorReason = require("support.collector_reason")
local cpu_reason_is = function(result, label)
  return CollectorReason.assert_reason(result, CPU_REASON, label)
end
cpu_reason_is(cpu_first, "the first sample")
cpu_reason_is(cpu_second, "the second sample")
cpu_reason_is(cpu_reset, "the sample after a counter reset")

-- The load average is the other half, and it is a different code because it is
-- a different cause: the counters differenced fine and one file was unreadable.
cpu_files["/proc/loadavg"] = nil
now = now + 1000000000
local cpu_no_loadavg = cpu:sample(context, cpu_reset)
assert(cpu_no_loadavg.status == "ok", "a missing load average is not a failure")
cpu_reason_is(cpu_no_loadavg, "a sample with no load average")
assert(cpu_no_loadavg.quality == "partial",
  "and it degrades the reading rather than dropping a field silently")
assert(cpu_no_loadavg.data.load == nil, "with no load invented for it")
-- And a malformed load average is the same cause, not a second one: the file
-- was read and could not be understood, which is still "could not be read".
cpu_files["/proc/loadavg"] = "not a load average\n"
now = now + 1000000000
local cpu_broken = cpu:sample(context, cpu_no_loadavg)
cpu_reason_is(cpu_broken, "a sample with a broken load average")
-- With the load average back and the counters unchanged, both causes are live
-- at once -- the load average reads and the samples cannot be differenced -- and
-- the published quality is `gap`, so the reason must name the gap and not the
-- load average.  This is the case that would catch a reason written as an
-- independent second guess rather than as the cause of what was published.
cpu_files["/proc/loadavg"] = fixture("proc/loadavg")
now = now + 1000000000
local cpu_both = cpu:sample(context, cpu_broken)
cpu_reason_is(cpu_both, "a sample with a readable load average and no counter delta")
assert(cpu_both.quality == "gap",
  "the unchanged counters are still the reason the reading is degraded")
assert(cpu_both.reason == "cpu_counter_delta_unavailable",
  "and the reason names them, not the load average that is now readable")

context.fs = fake_fs({
  ["/proc/meminfo"] = fixture("proc/meminfo"),
  ["/proc/vmstat"] = fixture("proc/vmstat"),
})
local memory = Memory.new():sample(context)
assert(memory.status == "ok" and memory.quality == "fresh")
assert(memory.data.total_bytes == 16384000 * 1024)
assert(memory.data.swap_used_bytes == 1048576 * 1024)
context.fs = fake_fs({
  ["/proc/meminfo"] = fixture("proc/meminfo"),
  ["/proc/vmstat"] = "broken vmstat line trailing\n",
})
local partial_memory = Memory.new():sample(context)
assert(partial_memory.status == "ok" and partial_memory.quality == "partial")
-- A reading that is `partial` has to say why, on the result and not only in the
-- data.  `Snapshot.merge` copies `result.reason` into `quality[resource].reason`
-- and that is the slot a caller reads to answer "why is this degraded" -- and
-- only the error path had ever filled it, through `Common.error_result`.  So a
-- degraded-but-running reading was the single kind that could not say why: it
-- reported `partial` with a nil reason, while a collector that failed outright
-- reported `unavailable` with one.  This collector computed the reason and put
-- it in `data.vmstat_error`, where no reader was looking.
assert(type(partial_memory.reason) == "string" and partial_memory.reason ~= "",
  "a memory reading that is partial carries no reason: the vmstat parse failed "
    .. "and the collector knows why, so the snapshot can only say `partial` and "
    .. "a caller has nothing to report to the user but the word itself")
-- The other way to be partial: the file is not readable at all.  A different
-- cause, so it has to be a different reason -- a guard that only ever saw the
-- parse failure would accept a constant here.
context.fs = fake_fs({ ["/proc/meminfo"] = fixture("proc/meminfo") })
local unreadable = Memory.new():sample(context)
assert(unreadable.status == "ok" and unreadable.quality == "partial")
assert(type(unreadable.reason) == "string" and unreadable.reason ~= ""
    and unreadable.reason ~= partial_memory.reason,
  "an unreadable /proc/vmstat and an unparseable one both report "
    .. tostring(unreadable.reason) .. " / " .. tostring(partial_memory.reason) ..
    ": the two are different failures and the snapshot has to be able to say "
    .. "which one happened")
-- And the reason has to survive the merge, because that is the copy the UI, the
-- JSON snapshot and an agent all read.
local merged = Snapshot.merge(Snapshot.new(0, 1), { memory = partial_memory })
assert(merged.quality.memory.reason == partial_memory.reason,
  "the reason a collector computed does not reach quality[resource].reason: "
    .. tostring(merged.quality.memory.reason) .. " instead of "
    .. tostring(partial_memory.reason) .. ".  Everything downstream reads the "
    .. "snapshot, not the collector result.")
-- The two paths are comparable only if both carry one, so pin the other half
-- too: a collector that failed outright says why, and has always been able to.
local failed_memory = Snapshot.merge(Snapshot.new(0, 1), {
  memory = Common.error_result({ kind = "missing", message = "no such file" }, 1, "/proc/meminfo"),
})
assert(failed_memory.quality.memory.reason == "no such file",
  "a collector that failed outright no longer says why, so a degraded reading "
    .. "and a failed one are not comparable and the vocabulary is not a "
    .. "contract: " .. tostring(failed_memory.quality.memory.reason))
context.fs = fake_fs({
  ["/proc/meminfo"] = "MemTotal: 100 kB\nMemAvailable: 200 kB\n",
  ["/proc/vmstat"] = fixture("proc/vmstat"),
})
assert(Memory.new():sample(context).status == "error")

context.fs = fake_fs({
  ["/proc/pressure/cpu"] = fixture("proc/pressure.cpu"),
  ["/proc/pressure/memory"] = fixture("proc/pressure.memory"),
  ["/proc/pressure/io"] = fixture("proc/pressure.io"),
})
local pressure = Pressure.new():sample(context)
assert(pressure.status == "ok" and pressure.data.memory.full.total == 50)
context.fs = fake_fs({ ["/proc/pressure/cpu"] = fixture("proc/pressure.cpu") })

-- A reading that degraded without failing has to say why, and the reason has to
-- be *measured* rather than a constant that happens to be attached.  This is the
-- second collector to carry that contract after memory; the shape is the same one
-- that made the first worth closing, and the collector is a good second case
-- because the cause is genuinely single -- the only condition that degrades the
-- sample is a resource that could not be read, so the aggregate reason and the
-- per-resource reasons in `data.errors` cannot disagree about which cause it was.
local partial_pressure = Pressure.new():sample(context)
assert(partial_pressure.status == "ok" and partial_pressure.quality == "partial")
assert(type(partial_pressure.reason) == "string" and partial_pressure.reason ~= "",
  "a pressure sample that is partial carries no reason: two of the three "
    .. "configured resources could not be read, the collector counted them, and "
    .. "the snapshot can therefore only say `partial` and leave the question "
    .. "open.  This is the same contract memory closes above, and the per-"
    .. "resource detail is already in data.errors -- the aggregate is the one "
    .. "thing the result did not say.")

-- A different cause, so a different reason.  Every resource failing is a
-- different state with its own status and its own reason, and a guard that only
-- ever saw the partial case would be satisfied by any string at all.  The
-- resources are named so that none of them is the one the current tree declares:
-- a missing resource and a present one have to be told apart by the fixture, not
-- by which word follows it.
local previous_fs = context.fs
context.fs = fake_fs({})
local none_pressure = Pressure.new():sample(context)
assert(none_pressure.status ~= "ok" and none_pressure.quality ~= "partial",
  "a pressure sample with no readable resource is no longer reported as a "
    .. "partial ok result: it came back " .. tostring(none_pressure.status) .. " / "
    .. tostring(none_pressure.quality))
assert(type(none_pressure.reason) == "string" and none_pressure.reason ~= ""
    and none_pressure.reason ~= partial_pressure.reason,
  "the all-unreadable case and the partial case give the same reason ("
    .. tostring(none_pressure.reason) .. "), so the reason does not identify the "
    .. "cause: a snapshot reader cannot tell a sample that lost some resources "
    .. "from one that lost all of them")

-- And the reason has to survive the merge, because that is the copy the UI, the
-- JSON snapshot and an agent read.
local pressure_merged = Snapshot.merge(Snapshot.new(0, 1), { pressure = partial_pressure })
assert(pressure_merged.quality.pressure.reason == partial_pressure.reason,
  "the reason the pressure collector computed does not reach "
    .. "quality[pressure].reason: " .. tostring(pressure_merged.quality.pressure.reason)
    .. " instead of " .. tostring(partial_pressure.reason))

-- And a sample that is not degraded must not claim to be: a reason attached to a
-- `fresh` reading is a lie of the same shape, and the guard has to see it.
context.fs = fake_fs({
  ["/proc/pressure/cpu"] = fixture("proc/pressure.cpu"),
  ["/proc/pressure/memory"] = fixture("proc/pressure.memory"),
  ["/proc/pressure/io"] = fixture("proc/pressure.io"),
})
local all_readable = Pressure.new():sample(context)
context.fs = previous_fs
assert(all_readable.status == "ok" and all_readable.quality == "fresh"
    and all_readable.reason == nil,
  "a pressure sample where every resource was read reports `" .. tostring(all_readable.quality)
    .. "` and still carries a reason (" .. tostring(all_readable.reason)
    .. "), so a reading that is not degraded is explaining a degradation that "
    .. "did not happen")

local disk_files = {
  ["/proc/diskstats"] = fixture("proc/diskstats.1"),
  ["/sys/dev/block/8:0/queue/logical_block_size"] = "512\n",
  ["/sys/dev/block/8:0/queue/physical_block_size"] = "4096\n",
  ["/sys/dev/block/259:0/queue/logical_block_size"] = "4096\n",
  ["/sys/dev/block/259:0/queue/physical_block_size"] = "4096\n",
  ["/sys/dev/block/259:0/diskseq"] = "42\n",
  ["/sys/dev/block/259:1/partition"] = "1\n",
  ["/sys/dev/block/259:1/diskseq"] = "42\n",
  ["/sys/dev/block/259:1/size"] = "1228800\n",
  ["/sys/dev/block/259:1/start"] = "2048\n",
  ["/sys/block/nvme0n1/diag/command_retries_count"] = "10\n",
  ["/sys/block/nvme0n1/diag/command_error_count"] = "1\n",
  ["/sys/block/nvme0n1/diag/multipath_failover_count"] = "0\n",
  ["/sys/block/nvme0n1/diag/io_requeue_no_usable_path_count"] = "2\n",
  ["/sys/block/nvme0n1/diag/io_fail_no_available_path_count"] = "0\n",
  ["/sys/block/nvme0n1/ana_state"] = "optimized\n",
  ["/sys/block/nvme0n1/ana_grpid"] = "2\n",
  ["/sys/block/nvme0n1/nuse"] = "1000\n",
  ["/sys/class/nvme/nvme0/state"] = "live\n",
  ["/sys/class/nvme/nvme0/transport"] = "pcie\n",
  ["/sys/class/nvme/nvme0/diag/command_error_count"] = "5\n",
  ["/sys/class/nvme/nvme0/diag/reset_count"] = "1\n",
  ["/sys/class/nvme/nvme0/serial"] = "PRIVATE-NVME-SERIAL\n",
  ["/sys/class/nvme/nvme0/subsysnqn"] = "PRIVATE-NVME-NQN\n",
  ["/sys/class/nvme/nvme0/address"] = "PRIVATE-NVME-ADDRESS\n",
}
local disk_directories = {
  ["/sys/dev/block/8:0/slaves"] = {},
  ["/sys/dev/block/259:0/slaves"] = {},
  ["/sys/dev/block/259:1/slaves"] = {},
}
local disk_links = {
  ["/sys/block/nvme0n1"] =
    "../devices/pci0000:00/0000:00:06.0/0000:01:00.0/nvme/nvme0/nvme0n1",
  ["/sys/class/nvme/nvme0"] =
    "../../devices/pci0000:00/0000:00:06.0/0000:01:00.0/nvme/nvme0",
}
context.fs = fake_fs(disk_files, disk_directories, disk_links)
local disk_read, nuse_reads = context.fs.read, 0
function context.fs:read(path, limit)
  if path == "/sys/block/nvme0n1/nuse" then nuse_reads = nuse_reads + 1 end
  return disk_read(self, path, limit)
end
local disk_collector = Disk.new()
local disk_first_content = disk_files["/proc/diskstats"]
  .. " 259 1 nvme0n1p1 50 0 800 120 30 0 400 80 0 150 160 0 0 0 0 0 0\n"
disk_files["/proc/diskstats"] = disk_first_content
local disk_first = disk_collector:sample(context)
local first_nvme = disk_first.data.devices[2].nvme
assert(first_nvme.status == "ok" and first_nvme.ana_state == "optimized"
  and first_nvme.ana_group_id == 2
  and first_nvme.controller.name == "nvme0"
  and first_nvme.controller.state == "live"
  and first_nvme.controller.transport == "pcie"
  and first_nvme.controller.counters.resets.total == 1
  and first_nvme.controller.counters.resets.delta_quality == "gap")
assert(first_nvme.counters.command_errors.total == 1
  and first_nvme.counters.command_errors.new == nil
  and first_nvme.counters.command_errors.delta_quality == "gap",
  "the first cumulative NVMe sample is not a new error")
assert(first_nvme.nuse.status == "ok" and first_nvme.nuse.quality == "fresh"
  and first_nvme.nuse.cached == false
  and first_nvme.nuse.allocated_lbas == 1000
  and first_nvme.nuse.allocated_bytes == 4096000 and nuse_reads == 1)
assert(disk_first.data.devices[3].nvme == nil,
  "partitions do not reread their whole namespace diagnostics")
disk_files["/proc/diskstats"] = fixture("proc/diskstats.2")
  .. " 259 1 nvme0n1p1 80 0 2000 210 50 0 1200 150 1 350 420 0 0 0 0 0 0\n"
disk_files["/sys/block/nvme0n1/diag/command_retries_count"] = "12\n"
disk_files["/sys/block/nvme0n1/diag/command_error_count"] = "3\n"
disk_files["/sys/block/nvme0n1/diag/multipath_failover_count"] = "1\n"
disk_files["/sys/block/nvme0n1/diag/io_requeue_no_usable_path_count"] = "4\n"
disk_files["/sys/block/nvme0n1/diag/io_fail_no_available_path_count"] = "2\n"
disk_files["/sys/class/nvme/nvme0/diag/command_error_count"] = "7\n"
disk_files["/sys/class/nvme/nvme0/diag/reset_count"] = "2\n"
disk_files["/sys/block/nvme0n1/nuse"] = "2000\n"
now = now + 1000000000
local disk_second = disk_collector:sample(context, disk_first)
assert(disk_second.status == "ok")
near(disk_second.data.devices[1].read_bytes_per_second, 400 * 512)
near(disk_second.data.devices[1].write_iops, 20)
near(disk_second.data.devices[2].read_bytes_per_second, 1200 * 512)
assert(disk_second.data.devices[2].logical_sector_size_bytes == 4096)
assert(disk_second.data.devices[2].stable_id == "259:0:42")
assert(disk_second.data.devices[3].is_partition and not disk_second.data.devices[3].aggregate)
assert(disk_second.data.devices[3].identity.size_bytes == 600 * 1024 * 1024
  and disk_second.data.devices[3].identity.start_bytes == 1024 * 1024,
  "partition size and offset use 512-byte kernel sectors, not logical block size")
local disk_snapshot = Snapshot.merge(nil, { disk = disk_second }, 1, now)
local disk_i18n = assert(I18n.new({ locale = "en-US" }))
local disk_model = ViewModel.build({ history_values = function() return {} end },
  disk_snapshot, disk_i18n, {}, "storage").disk_table
local partition_row
for _, row in ipairs(disk_model.rows) do
  if row.device == "nvme0n1p1" then partition_row = row end
end
assert(partition_row and partition_row.size:find("600", 1, true),
  "Storage shows the partition's capacity")
local partition_export = Export.snapshot(disk_snapshot).disks.devices[3]
assert(partition_export.identity.size_bytes == 600 * 1024 * 1024
  and partition_export.identity.start_bytes == 1024 * 1024)
local partition_detail = table.concat(TUI.hardware_detail_lines(disk_snapshot,
  "block:259:1:42", disk_i18n), "\n")
assert(partition_detail:find("Start offset", 1, true)
  and partition_detail:find("1 MiB", 1, true))
assert(Report.render(Export.snapshot(disk_snapshot)):find("600.00 MiB", 1, true))
local nvme = disk_second.data.devices[2].nvme
assert(nvme.status == "ok" and nvme.counters.command_retries.new == 2
  and nvme.counters.command_errors.new == 2
  and nvme.counters.multipath_failovers.new == 1
  and nvme.counters.io_requeues_no_path.new == 2
  and nvme.counters.io_failures_no_path.new == 2)
assert(nvme.controller.status == "ok"
  and nvme.controller.counters.command_errors.new == 2
  and nvme.controller.counters.resets.new == 1
  and nvme.controller.counters.reconnects.status == "unavailable")
assert(nvme.nuse.allocated_lbas == 1000 and nvme.nuse.quality == "fresh"
  and nvme.nuse.cached == true
  and nuse_reads == 1, "NUSE is held during its 60-second read budget")
local nvme_export = Export.snapshot({ disks = disk_second.data })
local exported_nvme = nvme_export.disks.devices[2].nvme
assert(exported_nvme.counters.command_errors.total == 3
  and exported_nvme.counters.command_errors.new == 2
  and exported_nvme.ana_state == "optimized"
  and exported_nvme.controller.name == "nvme0"
  and exported_nvme.controller.counters.resets.new == 1
  and exported_nvme.nuse.allocated_bytes == 4096000
  and exported_nvme.nuse.cached == true)
assert(not require("wtop.format.json").encode(nvme_export):find("PRIVATE", 1, true))
local nvme_detail = table.concat(TUI.hardware_detail_lines({ disks = disk_second.data },
  "block:259:0:42", assert(I18n.new({ locale = "en-US" }))), "\n")
assert(nvme_detail:find("NVMe diagnostics", 1, true)
  and nvme_detail:find("Command errors: 3 (+2)", 1, true)
  and nvme_detail:find("Namespace allocated:", 1, true)
  and nvme_detail:find("not filesystem used space", 1, true)
  and nvme_detail:find("NVMe controller nvme0", 1, true)
  and nvme_detail:find("Controller resets: 2 (+1)", 1, true))
local nvme_report = Report.render(nvme_export)
assert(nvme_report:find("## NVMe diagnostics", 1, true)
  and nvme_report:find("3 (+2)", 1, true)
  and nvme_report:find("| nvme0n1 | ok | optimized | 3.91 MiB | cached |", 1, true)
  and nvme_report:find("## NVMe controllers", 1, true)
  and nvme_report:find("| nvme0n1 | nvme0 | live | pcie | 7 (+2) | 2 (+1) |", 1, true))
local function no_path_signals(data, quality)
  local agent = Export.agent({ disks = data,
    quality = { disks = { status = "ok", quality = quality or "fresh" } } })
  local count = 0
  for _, signal in ipairs(agent.signals) do
    if signal.code == "nvme_no_path_io_failure" then
      assert(signal.severity == "warning")
      count = count + 1
    end
  end
  return count
end
assert(no_path_signals(disk_first.data) == 0
  and no_path_signals(disk_second.data) == 1,
  "only a fresh increase in failed I/O creates an Agent signal")
assert(no_path_signals({ devices = { disk_second.data.devices[2],
  disk_second.data.devices[2] } }) == 1,
  "two observations of one event yield one signal, not a summed count")
assert(no_path_signals(disk_second.data, "stale") == 0)
disk_files["/sys/block/nvme0n1/diag/command_error_count"] = "1\n"
disk_files["/sys/class/nvme/nvme0/diag/reset_count"] = "1\n"
now = now + 1000000000
local disk_reset = disk_collector:sample(context, disk_second)
assert(disk_reset.data.devices[2].nvme.counters.command_errors.total == 1
  and disk_reset.data.devices[2].nvme.counters.command_errors.new == nil
  and disk_reset.data.devices[2].nvme.counters.command_errors.delta_quality == "reset")
assert(disk_reset.data.devices[2].nvme.controller.counters.resets.new == nil
  and disk_reset.data.devices[2].nvme.controller.counters.resets.delta_quality == "reset")
assert(no_path_signals(disk_reset.data) == 0)
disk_files["/sys/block/nvme0n1/diag/command_error_count"] = "bad\n"
now = now + 1000000000
local disk_invalid = disk_collector:sample(context, disk_reset)
assert(disk_invalid.quality == "partial" and disk_invalid.reason == "disk_data_partial")
assert(disk_invalid.data.devices[2].nvme.counters.command_errors.total == nil
  and disk_invalid.data.devices[2].nvme.counters.command_errors.status == "parse_error")
disk_files["/sys/block/nvme0n1/diag/command_error_count"] = "4\n"
disk_files["/sys/dev/block/259:0/diskseq"] = "43\n"
now = now + 1000000000
local replaced_nvme = disk_collector:sample(context, disk_invalid)
assert(replaced_nvme.data.devices[2].nvme.counters.command_errors.delta_quality == "gap"
  and replaced_nvme.data.devices[2].nvme.counters.command_errors.new == nil,
  "a new disk generation cannot inherit the previous namespace counter")
assert(replaced_nvme.data.devices[2].nvme.controller.counters.resets.delta_quality == "gap",
  "a new namespace generation cannot inherit controller event counts")
local NVMeDiagnostics = require("wtop.linux.nvme_diagnostics")
do
local before_refresh = nuse_reads
local refresh_time = first_nvme.nuse.observed_ns + NVMeDiagnostics.NUSE_REFRESH_NS
local refreshed_nuse = NVMeDiagnostics.read(context.fs, "nvme0n1",
  refresh_time, first_nvme, {}, 4096).nuse
assert(refreshed_nuse.status == "ok" and refreshed_nuse.quality == "fresh"
  and refreshed_nuse.allocated_lbas == 2000 and nuse_reads == before_refresh + 1,
  "the Identify-backed utilization refreshes after its read budget")
disk_files["/sys/block/nvme0n1/nuse"] = "bad\n"
local invalid_nuse = NVMeDiagnostics.read(context.fs, "nvme0n1",
  refresh_time + NVMeDiagnostics.NUSE_REFRESH_NS,
  { nuse = refreshed_nuse }, {}, 4096).nuse
assert(invalid_nuse.status == "parse_error" and invalid_nuse.quality == "partial"
  and nuse_reads == before_refresh + 2)
disk_files["/sys/block/nvme0n1/nuse"] = "2000\n"
local bounded_nuse = NVMeDiagnostics.read(context.fs, "nvme0n1",
  refresh_time + NVMeDiagnostics.NUSE_REFRESH_NS + 1,
  { nuse = invalid_nuse }, {}, 4096, 1000).nuse
assert(bounded_nuse.status == "parse_error" and bounded_nuse.quality == "partial"
  and bounded_nuse.allocated_lbas == 2000 and bounded_nuse.allocated_bytes == nil
  and nuse_reads == before_refresh + 3,
  "an out-of-capacity count is visible without claiming a byte estimate")
end
assert(not NVMeDiagnostics.namespace_name("nvme0n1p1")
  and not NVMeDiagnostics.namespace_name("nvme0n1/../etc"),
  "only namespace names can form NVMe diagnostic sysfs paths")
local wrong_controller_links = {
  ["/sys/block/nvme0n1"] = disk_links["/sys/block/nvme0n1"],
  ["/sys/class/nvme/nvme0"] =
    "../../devices/pci0000:00/0000:00:06.0/0000:01:00.1/nvme/nvme0",
}
assert(NVMeDiagnostics.read(fake_fs(disk_files, disk_directories,
  wrong_controller_links), "nvme0n1", now).controller == nil,
  "a controller class link must match the namespace's real sysfs parent")
local multipath_head_links = {
  ["/sys/block/nvme0n1"] =
    "../devices/virtual/nvme-subsystem/nvme-subsys0/nvme0n1",
  ["/sys/class/nvme/nvme0"] = disk_links["/sys/class/nvme/nvme0"],
  ["/sys/class/nvme/nvme1"] =
    "../../devices/pci0000:00/0000:00:07.0/0000:02:00.0/nvme/nvme1",
  ["/sys/class/nvme-subsystem/nvme-subsys0"] =
    "../../devices/virtual/nvme-subsystem/nvme-subsys0",
}
local physical_head = "/sys/devices/virtual/nvme-subsystem/nvme-subsys0/nvme0n1"
local physical_path0 = "/sys/devices/pci0000:00/0000:00:06.0/0000:01:00.0/nvme/nvme0/nvme0c0n1"
local physical_path1 = "/sys/devices/pci0000:00/0000:00:07.0/0000:02:00.0/nvme/nvme1/nvme0c1n1"
multipath_head_links[physical_head .. "/nvme0c0n1"] =
  "../../../../pci0000:00/0000:00:06.0/0000:01:00.0/nvme/nvme0/nvme0c0n1"
multipath_head_links[physical_head .. "/nvme0c1n1"] = physical_path1
disk_files["/sys/class/nvme-subsystem/nvme-subsys0/iopolicy"] = "round-robin\n"
disk_files["/sys/class/nvme/nvme1/state"] = "connecting\n"
disk_files["/sys/class/nvme/nvme1/transport"] = "tcp\n"
disk_files[physical_path0 .. "/ana_state"] = "optimized\n"
disk_files[physical_path0 .. "/ana_grpid"] = "2\n"
disk_files[physical_path1 .. "/ana_state"] = "non-optimized\n"
disk_files[physical_path1 .. "/ana_grpid"] = "3\n"
local path_dirs = { [physical_head] = { "nvme0c0n1", "nvme0c1n1", "nvme0n1p1" } }
local multipath = NVMeDiagnostics.read(fake_fs(disk_files, path_dirs,
  multipath_head_links), "nvme0n1", now)
assert(multipath.controller == nil,
  "a multipath head does not name one of its controllers")
assert(multipath.paths and multipath.paths.status == "ok"
  and multipath.paths.subsystem == "nvme-subsys0"
  and multipath.paths.iopolicy == "round-robin"
  and multipath.paths.total == 2 and #multipath.paths.items == 2
  and multipath.paths.items[1].controller == "nvme0"
  and multipath.paths.items[1].ana_state == "optimized"
  and multipath.paths.items[2].controller == "nvme1"
  and multipath.paths.items[2].ana_state == "non-optimized")
local multipath_state = { disks = { devices = {
  { id = "259:0", name = "nvme0n1", nvme = multipath },
} } }
local multipath_export = Export.snapshot(multipath_state)
assert(multipath_export.disks.devices[1].nvme.paths.items[2].controller_state
  == "connecting"
  and not require("wtop.format.json").encode(multipath_export):find("PRIVATE", 1, true))
local multipath_detail = table.concat(TUI.hardware_detail_lines(multipath_state,
  "block:259:0", disk_i18n), "\n")
assert(multipath_detail:find("NVMe multipath", 1, true)
  and multipath_detail:find("nvme0c1n1 -> nvme1", 1, true))
assert(Report.render(multipath_export):find(
  "| nvme0n1 | nvme-subsys0 | nvme0c1n1 | nvme1 | connecting | tcp | non-optimized | 3 | fresh |",
  1, true))
local wrong_path_links = {}
for key, value in pairs(multipath_head_links) do wrong_path_links[key] = value end
wrong_path_links[physical_head .. "/nvme0c1n1"] =
  "/sys/devices/pci0000:00/0000:00:07.0/0000:02:00.1/nvme/nvme1/nvme0c1n1"
local wrong_path = NVMeDiagnostics.read(fake_fs(disk_files, path_dirs,
  wrong_path_links), "nvme0n1", now).paths
assert(wrong_path.status == "partial" and #wrong_path.items == 1,
  "a path link with no matching controller class path is not published")
local no_subsystem_links = {}
for key, value in pairs(multipath_head_links) do no_subsystem_links[key] = value end
no_subsystem_links["/sys/class/nvme-subsystem/nvme-subsys0"] = nil
assert(NVMeDiagnostics.read(fake_fs(disk_files, path_dirs,
  no_subsystem_links), "nvme0n1", now).paths == nil,
  "a namespace name alone cannot establish a multipath subsystem")
local missing_path_directory = NVMeDiagnostics.read(fake_fs(disk_files, {},
  multipath_head_links), "nvme0n1", now).paths
assert(missing_path_directory.status == "unavailable"
  and #missing_path_directory.items == 0)
local too_many_paths = {}
for index = 0, 32 do
  too_many_paths[#too_many_paths + 1] = "nvme0c" .. index .. "n1"
end
local capped_paths = NVMeDiagnostics.read(fake_fs(disk_files,
  { [physical_head] = too_many_paths }, multipath_head_links),
  "nvme0n1", now).paths
assert(capped_paths.status == "truncated" and capped_paths.truncated
  and capped_paths.total == 33 and #capped_paths.items <= 32)
local shared_links = {
  ["/sys/block/nvme0n1"] = disk_links["/sys/block/nvme0n1"],
  ["/sys/block/nvme0n2"] =
    "../devices/pci0000:00/0000:00:06.0/0000:01:00.0/nvme/nvme0/nvme0n2",
  ["/sys/class/nvme/nvme0"] = disk_links["/sys/class/nvme/nvme0"],
}
local counted_fs = fake_fs(disk_files, disk_directories, shared_links)
local original_read, controller_reset_reads = counted_fs.read, 0
function counted_fs:read(path, limit)
  if path == "/sys/class/nvme/nvme0/diag/reset_count" then
    controller_reset_reads = controller_reset_reads + 1
  end
  return original_read(self, path, limit)
end
local controller_batch = {}
local first_shared = NVMeDiagnostics.read(counted_fs, "nvme0n1", now,
  nil, controller_batch)
local second_shared = NVMeDiagnostics.read(counted_fs, "nvme0n2", now,
  nil, controller_batch)
assert(controller_reset_reads == 1 and first_shared.controller
  and second_shared.controller and first_shared.controller ~= second_shared.controller
  and first_shared.controller.issues ~= second_shared.controller.issues,
  "namespaces share one controller read without sharing mutable output")
disk_files["/sys/dev/block/259:0/diskseq"] = nil
now = now + 1000000000
local without_generation = disk_collector:sample(context, replaced_nvme)
assert(without_generation.data.devices[2].nvme.counters.command_errors.new == nil
  and without_generation.data.devices[2].nvme.counters.command_errors.delta_quality == "gap",
  "major:minor identity alone cannot make a new health event")
for _, specification in ipairs(NVMeDiagnostics.COUNTERS) do
  disk_files["/sys/block/nvme0n1/" .. specification[2]] = nil
end
disk_files["/sys/block/nvme0n1/ana_state"] = nil
disk_files["/sys/block/nvme0n1/ana_grpid"] = nil
now = now + 1000000000
local unsupported_nvme = disk_collector:sample(context, without_generation)
assert(unsupported_nvme.data.devices[2].nvme.status == "unavailable"
  and unsupported_nvme.data.devices[2].partial == false,
  "older kernels may omit optional diagnostics without degrading disk I/O")
disk_files["/sys/class/nvme/nvme0/diag/reset_count"] = "bad\n"
local bad_controller = disk_collector:sample(context, unsupported_nvme)
assert(bad_controller.data.devices[2].nvme.controller.status == "partial"
  and bad_controller.data.devices[2].partial == false,
  "controller diagnostics have separate quality from namespace I/O")
disk_files["/sys/class/nvme/nvme0/diag/reset_count"] = "1\n"
disk_files["/proc/diskstats"] = disk_files["/proc/diskstats"]
  .. " 259 2 nvme1n1 1 0 2 3 4 0 5 6 0 7 8 0 0 0 0 0 0\n"
local capped_nvme = Disk.new({ max_nvme_diagnostics = 1 }):sample(context)
assert(capped_nvme.quality == "partial" and capped_nvme.data.nvme_diagnostics_truncated)
assert(capped_nvme.data.devices[4].nvme.status == "truncated"
  and Export.snapshot({ disks = capped_nvme.data }).disks.nvme_diagnostics_truncated,
  "the per-scan NVMe budget is explicit in the row and Snapshot")
disk_files["/sys/dev/block/259:1/size"] = "18014398509481984\n"
disk_files["/sys/dev/block/259:1/start"] = "bad\n"
local invalid_partition = disk_collector:sample(context, capped_nvme)
assert(invalid_partition.data.devices[3].identity == nil,
  "overflow and malformed partition extents remain unknown")
near(Engine.sum_devices(disk_second.data.devices, "read_bytes_per_second"),
  disk_second.data.devices[1].read_bytes_per_second
    + disk_second.data.devices[2].read_bytes_per_second)

-- A kernel holder points at each slave through sysfs. Resolve the device
-- number behind that link; the relationship is not physical containment.
local stacked_files = {
  ["/proc/diskstats"] = disk_first_content
    .. " 253 0 dm-0 1 0 2 3 4 0 5 6 0 7 8 0 0 0 0 0 0\n",
  ["/sys/dev/block/253:0/slaves/nvme0n1p1/dev"] = "259:1\n",
  ["/sys/block/dm-0/dm/name"] = "cryptroot\n",
  ["/sys/block/dm-0/dm/suspended"] = "0\n",
  ["/sys/block/dm-0/dm/uuid"] = "PRIVATE-DM-UUID\n",
}
local stacked_dirs = {
  ["/sys/dev/block/8:0/slaves"] = {},
  ["/sys/dev/block/259:0/slaves"] = {},
  ["/sys/dev/block/259:1/slaves"] = {},
  ["/sys/dev/block/253:0/slaves"] = { "nvme0n1p1" },
}
local stacked_collector = Disk.new({ fs = fake_fs(stacked_files, stacked_dirs) })
local stacked_sample = stacked_collector:sample({})
local holder
for _, device in ipairs(stacked_sample.data.devices) do
  if device.name == "dm-0" then holder = device end
end
assert(holder and holder.stacked and not holder.aggregate and holder.slave_refs_complete)
assert(holder.stack and holder.stack.kind == "dm" and holder.stack.name == "cryptroot"
  and holder.stack.suspended == false and holder.stack.status == "ok")
assert(holder.slave_refs[1].name == "nvme0n1p1"
  and holder.slave_refs[1].device_id == "259:1")
local stacked_state = { disks = stacked_sample.data }
local stacked_graph = Hardware.build(stacked_state)
local holder_id, slave_id = "block:253:0", "block:259:1"
assert(stacked_graph.by_id[holder_id].parent_id == nil
  and stacked_graph.by_id[holder_id].slave_ids[1] == slave_id
  and stacked_graph.by_id[slave_id].holder_ids[1] == holder_id)
assert(Hardware.related(stacked_graph, holder_id).items[1].id == slave_id
  and Hardware.related(stacked_graph, slave_id).items[1].id == holder_id)
local holder_detail = table.concat(TUI.hardware_detail_lines(stacked_state,
  holder_id, disk_i18n), "\n")
local slave_detail = table.concat(TUI.hardware_detail_lines(stacked_state,
  slave_id, disk_i18n), "\n")
assert(holder_detail:find("Backing devices: nvme0n1p1", 1, true)
  and holder_detail:find("Mapper name: cryptroot", 1, true)
  and slave_detail:find("Used by block devices: dm-0", 1, true))
local stacked_export = Export.snapshot(stacked_state)
local exported_nodes = {}
for _, node in ipairs(stacked_export.inventory.topology.nodes) do exported_nodes[node.id] = node end
local exported_holder
for _, device in ipairs(stacked_export.disks.devices) do
  if device.name == "dm-0" then exported_holder = device end
end
assert(exported_holder and exported_holder.slave_refs_complete
  and exported_holder.slave_refs[1].device_id == "259:1"
  and exported_holder.stack.name == "cryptroot")
assert(not require("wtop.format.json").encode(stacked_export):find("PRIVATE", 1, true))
assert(exported_nodes[holder_id].slave_ids[1] == slave_id
  and exported_nodes[slave_id].holder_ids[1] == holder_id)
local stacked_report = Report.render(stacked_export)
assert(stacked_report:find("## Block dependencies", 1, true)
  and stacked_report:find("| dm-0 | block:259:1 |", 1, true)
  and stacked_report:find("| dm-0 | dm | cryptroot | not suspended |", 1, true))
stacked_files["/sys/block/dm-0/dm/suspended"] = "1\n"
local suspended_stack = stacked_collector:sample({})
for _, device in ipairs(suspended_stack.data.devices) do
  if device.name == "dm-0" then assert(device.stack.suspended == true) end
end
stacked_files["/sys/dev/block/253:0/slaves/nvme0n1p1/dev"] = nil
local missing_slave = stacked_collector:sample({})
local missing_holder
for _, device in ipairs(missing_slave.data.devices) do
  if device.name == "dm-0" then missing_holder = device end
end
assert(missing_slave.quality == "partial" and missing_holder
  and missing_holder.slave_refs_complete == false and #missing_holder.slave_refs == 0)
local incomplete_graph = Hardware.build({ disks = missing_slave.data })
assert(incomplete_graph.partial and #incomplete_graph.by_id[holder_id].slave_ids == 0)
local stale_graph = Hardware.build({ disks = stacked_sample.data,
  quality = { disks = { status = "error", quality = "stale" } } })
assert(#stale_graph.by_id[holder_id].slave_ids == 0)
local ambiguous_graph = Hardware.build({ disks = { devices = {
  { id = "8:0", name = "sda" }, { id = "8:16", name = "sda" },
  { id = "253:0", name = "dm-0", stacked = true, slave_refs_complete = true,
    slave_refs = { { name = "sda", device_id = "8:0" } } },
} } })
assert(ambiguous_graph.partial and #ambiguous_graph.by_id[holder_id].slave_ids == 0)
local incomplete_set = Hardware.build({ disks = { devices = {
  { id = "8:0", name = "sda" }, { id = "8:16", name = "sdb" },
  { id = "253:0", name = "dm-0", stacked = true, slave_refs_complete = true,
    slave_refs = { { name = "sda", device_id = "8:0" },
      { name = "sdb", device_id = "8:17" } } },
} } })
assert(incomplete_set.partial and #incomplete_set.by_id[holder_id].slave_ids == 0
  and #incomplete_set.by_id["block:8:0"].holder_ids == 0,
  "one missing dependency rejects the whole holder set")
local self_graph = Hardware.build({ disks = { devices = {
  { id = "253:0", name = "dm-0", stacked = true, slave_refs_complete = true,
    slave_refs = { { name = "dm-0", device_id = "253:0" } } },
} } })
assert(self_graph.partial and #self_graph.by_id[holder_id].slave_ids == 0)

local StackedBlock = require("wtop.linux.stacked_block")
assert(StackedBlock.read(fake_fs({}), "dm-1").status == "unavailable")
assert(StackedBlock.kind("dm-0p1") == nil and StackedBlock.kind("md0p1") == nil)
local md_files = {
  ["/proc/diskstats"] = " 9 0 md0 1 0 2 3 4 0 5 6 0 7 8 0 0 0 0 0 0\n",
  ["/sys/block/md0/md/level"] = "raid1\n",
  ["/sys/block/md0/md/raid_disks"] = "2\n",
  ["/sys/block/md0/md/degraded"] = "1\n",
  ["/sys/block/md0/md/array_state"] = "clean\n",
  ["/sys/block/md0/md/sync_action"] = "recover\n",
  ["/sys/block/md0/md/sync_completed"] = "4294967296 / 8589934592\n",
  ["/sys/block/md0/md/uuid"] = "PRIVATE-MD-UUID\n",
  ["/sys/block/md0/md/dev-nvme0n1p1/block/dev"] = "259:1\n",
  ["/sys/block/md0/md/dev-nvme0n1p1/slot"] = "0\n",
  ["/sys/block/md0/md/dev-nvme0n1p1/state"] = "in_sync\n",
  ["/sys/block/md0/md/dev-nvme1n1p1/block/dev"] = "259:4\n",
  ["/sys/block/md0/md/dev-nvme1n1p1/slot"] = "none\n",
  ["/sys/block/md0/md/dev-nvme1n1p1/state"] = "spare,write_error\n",
  ["/sys/block/md0/md/dev-nvme1n1p1/super"] = "PRIVATE-MD-SUPER\n",
}
local md_collector = Disk.new({ fs = fake_fs(md_files,
  { ["/sys/dev/block/9:0/slaves"] = {},
    ["/sys/block/md0/md"] = { "dev-nvme1n1p1", "level", "dev-nvme0n1p1" } }) })
local md_sample = md_collector:sample({})
local md = md_sample.data.devices[1]
assert(md.stack.kind == "md" and md.stack.level == "raid1"
  and md.stack.raid_disks == 2 and md.stack.degraded == 1
  and md.stack.array_state == "clean" and md.stack.status == "ok"
  and md.stack.sync_action == "recover" and md.stack.sync_progress_status == "ok"
  and md.stack.sync_completed_sectors == 4294967296
  and md.stack.sync_total_sectors == 8589934592
  and md.stack.sync_percent == 50
  and md.stack.members.status == "ok" and md.stack.members.total == 2
  and md.stack.members.items[1].device_id == "259:1"
  and md.stack.members.items[1].slot == 0
  and md.stack.members.items[2].device_id == "259:4"
  and md.stack.members.items[2].slot == "none"
  and md.stack.members.items[2].state == "spare,write_error")
local md_state = { disks = md_sample.data,
  quality = { disks = { status = "ok", quality = "fresh" } } }
local md_export = Export.snapshot(md_state)
assert(md_export.disks.devices[1].stack.degraded == 1
  and md_export.disks.devices[1].stack.sync_percent == 50
  and md_export.disks.devices[1].stack.members.items[2].slot == "none"
  and not require("wtop.format.json").encode(md_export):find("PRIVATE", 1, true))
local md_detail = table.concat(TUI.hardware_detail_lines(md_state,
  "block:9:0", disk_i18n), "\n")
assert(md_detail:find("RAID level: raid1", 1, true)
  and md_detail:find("Missing devices: 1", 1, true)
  and md_detail:find("Sync progress: 4294967296/8589934592 (50%)", 1, true)
  and md_detail:find("RAID member: nvme0n1p1 (259:1) · array position 0 · in_sync", 1, true)
  and md_detail:find("RAID member: nvme1n1p1 (259:4) · no active position", 1, true))
assert(Report.render(md_export):find(
  "| md0 | md | raid1 | clean | recover 50.0% | 2 (ok) | 1 | 2 |", 1, true))
assert(Report.render(md_export):find(
  "| md0 | nvme0n1p1 | 259:1 | 0 | in_sync | fresh |", 1, true))
assert(Report.render(md_export):find(
  "| md0 | nvme1n1p1 | 259:4 | none | spare,write_error | fresh |", 1, true))
local many_arrays = {}
for array = 1, 9 do
  local members = {}
  for index = 1, 64 do
    members[index] = { name = "member" .. index,
      device_id = tostring(array) .. ":" .. tostring(index), slot = index - 1 }
  end
  many_arrays[array] = { name = "md_array" .. array,
    stack = { kind = "md", members = { items = members } } }
end
local bounded_report = Report.render({ disks = { devices = many_arrays } })
local exported_member_rows = 0
for _ in bounded_report:gmatch("| md_array%d+ | member") do
  exported_member_rows = exported_member_rows + 1
end
assert(exported_member_rows == 512
  and bounded_report:find("The source list was truncated.", 1, true),
  "the report bounds its combined MD member table")
md_files["/sys/block/md0/md/dev-nvme1n1p1/block/dev"] = "259:1\n"
local repeated_member = md_collector:sample({}).data.devices[1].stack
assert(repeated_member.status == "ok" and repeated_member.members.status == "partial"
  and #repeated_member.members.items == 1,
  "a repeated device number does not create a second member")
md_files["/sys/block/md0/md/dev-nvme1n1p1/block/dev"] = "259:4\n"
md_files["/sys/block/md0/md/dev-nvme0n1p1/slot"] = "bad\n"
md_files["/sys/block/md0/md/dev-nvme0n1p1/state"] = "in_sync,,faulty\n"
local damaged_member = md_collector:sample({}).data.devices[1].stack
assert(damaged_member.status == "ok" and damaged_member.members.status == "partial"
  and damaged_member.members.items[1].slot == nil
  and damaged_member.members.items[1].state == nil
  and damaged_member.members.items[1].quality == "partial")
md_files["/sys/block/md0/md/dev-nvme0n1p1/slot"] = "0\n"
md_files["/sys/block/md0/md/dev-nvme0n1p1/state"] = "in_sync\n"
local no_member_directory = StackedBlock.read(fake_fs(md_files), "md0")
assert(no_member_directory.status == "ok"
  and no_member_directory.members.status == "unavailable")
local many_members = {}
for index = 1, 65 do many_members[index] = "dev-fake" .. index end
local capped_members = StackedBlock.read(fake_fs(md_files,
  { ["/sys/block/md0/md"] = many_members }), "md0").members
assert(capped_members.status == "truncated" and capped_members.truncated
  and capped_members.total == 65 and #capped_members.items <= 64)
local function md_signals(state)
  local count = 0
  for _, signal in ipairs(Export.agent(state).signals) do
    if signal.code == "md_array_degraded" then
      assert(signal.severity == "warning")
      count = count + 1
    end
  end
  return count
end
assert(md_signals(md_state) == 1)
md_files["/sys/block/md0/md/sync_action"] = "idle\n"
local idle_md = md_collector:sample({}).data.devices[1].stack
assert(idle_md.status == "ok" and idle_md.sync_action == "idle"
  and idle_md.sync_percent == nil)
md_files["/sys/block/md0/md/sync_action"] = "recover\n"
md_files["/sys/block/md0/md/sync_completed"] = "1001 / 1000\n"
local bad_progress = md_collector:sample({}).data.devices[1].stack
assert(bad_progress.status == "partial"
  and bad_progress.sync_progress_status == "parse_error"
  and bad_progress.sync_percent == nil)
md_files["/sys/block/md0/md/sync_completed"] = "500 / 1000\n"
local action_reads = 0
md_files["/sys/block/md0/md/sync_action"] = function()
  action_reads = action_reads + 1
  return action_reads == 1 and "recover\n" or "idle\n"
end
local changed_action = md_collector:sample({}).data.devices[1].stack
assert(changed_action.status == "ok" and changed_action.sync_action == "idle"
  and changed_action.sync_progress_status == "gap"
  and changed_action.sync_percent == nil)
assert(Report.render(Export.snapshot({ disks = { devices = {
  { name = "md0", stack = changed_action },
} } })):find("idle (gap)", 1, true))
md_files["/sys/block/md0/md/sync_action"] = "recover\n"
md_files["/sys/block/md0/md/sync_completed"] = nil
local absent_progress = md_collector:sample({}).data.devices[1].stack
assert(absent_progress.status == "ok" and absent_progress.sync_action == "recover"
  and absent_progress.sync_progress_status == "unavailable"
  and absent_progress.sync_percent == nil)
assert(Report.render(Export.snapshot({ disks = { devices = {
  { name = "md0", stack = absent_progress },
} } })):find("recover (unavailable)", 1, true))
md_files["/sys/block/md0/md/sync_action"] = nil
local no_sync = md_collector:sample({}).data.devices[1].stack
assert(no_sync.status == "ok" and no_sync.sync_action == nil,
  "nonredundant or older MD arrays can omit the sync attributes")
md_state.quality.disks.quality = "stale"
assert(md_signals(md_state) == 0)
md_files["/sys/block/md0/md/array_state"] = "inactive\n"
local inactive_md = md_collector:sample({})
assert(md_signals({ disks = inactive_md.data,
  quality = { disks = { status = "ok", quality = "fresh" } } }) == 0)
md_files["/sys/block/md0/md/array_state"] = "active\n"
md_files["/sys/block/md0/md/raid_disks"] = "3 (2)\n"
local reshaping_md = md_collector:sample({})
assert(reshaping_md.data.devices[1].stack.raid_disks == 3
  and reshaping_md.data.devices[1].stack.previous_raid_disks == 2)
md_files["/sys/block/md0/md/raid_disks"] = "bad\n"
local invalid_md = md_collector:sample({})
assert(invalid_md.quality == "partial"
  and invalid_md.data.devices[1].stack.status == "partial"
  and md_signals({ disks = invalid_md.data,
    quality = { disks = { status = "ok", quality = "partial" } } }) == 0)

local net_files = {
  ["/proc/net/dev"] = fixture("proc/netdev.1"),
  ["/proc/net/route"] = table.concat({
    "Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT",
    "eth0 00000000 0100000A 0003 0 0 100 00000000 0 0 0",
  }, "\n"),
  ["/sys/class/net/lo/ifindex"] = "1\n",
  ["/sys/class/net/lo/operstate"] = "unknown\n",
  ["/sys/class/net/lo/mtu"] = "65536\n",
  ["/sys/class/net/eth0/ifindex"] = "2\n",
  ["/sys/class/net/eth0/operstate"] = "up\n",
  ["/sys/class/net/eth0/mtu"] = "1500\n",
  ["/sys/class/net/eth0/speed"] = "1000\n",
}
context.fs = fake_fs(net_files)
local network_collector = Network.new()
local network_first = network_collector:sample(context)
assert(network_first.data.routes == nil and network_first.data.default_routes.eth0,
  "ordinary network sampling scans defaults without building the route inventory")
net_files["/proc/net/dev"] = fixture("proc/netdev.2")
now = now + 1000000000
context.scan_routes = true
local network_second = network_collector:sample(context, network_first)
local eth0 = network_second.data.interfaces[2]
assert(eth0.name == "eth0" and eth0.ifindex == 2)
assert(eth0.aggregate and eth0.default_route.families.ipv4)
assert(not network_second.data.interfaces[1].aggregate)
near(eth0.rates.rx_bytes_per_second, 3000)
near(eth0.rates.tx_bytes_per_second, 4000)
near(Engine.sum_interfaces(network_second.data.interfaces, "rx_bytes_per_second"), 3000)
assert(network_second.data.routes.total == 1)
assert(network_second.data.routes.entries[1].destination_cidr == "0.0.0.0/0")
assert(network_second.data.routes.entries[1].gateway == "10.0.0.1")
local exported_route = Export.snapshot({ network = network_second.data }).network.routes
assert(exported_route.total == 1 and exported_route.entries[1].gateway == "10.0.0.1")
assert(exported_route.entries[1].destination_cidr == "0.0.0.0/0"
  and exported_route.entries[1].source == "/proc/net/route"
  and exported_route.entries[1].selected_default == true)
now = now + 1000000000
local cached_network = network_collector:sample(context, network_second)
assert(cached_network.data.routes == network_second.data.routes,
  "an open route overlay reuses its recent full reading between refreshes")
local original_route_file = net_files["/proc/net/route"]
net_files["/proc/net/route"] = original_route_file:gsub(" 100 00000000", " 200 00000000")
now = now + 1000000000
local changed_default = network_collector:sample(context, cached_network)
assert(changed_default.data.routes.observed_ns == now
  and changed_default.data.default_routes.eth0.metrics.ipv4 == 200,
  "a changed default route refreshes the detail before its ten-second deadline")
now = now + 10 * 1000000000
local expired_routes = network_collector:sample(context, changed_default)
assert(expired_routes.data.routes.observed_ns == now,
  "the full route inventory refreshes after ten seconds while its overlay stays open")
net_files["/proc/net/route"] = net_files["/proc/net/route"]
  .. "\neth0 0000000A 00000000 0001 0 0 20 00FF00FF 0 0 0"
context.force_route_refresh = true
now = now + 1000000000
local partial_inventory = network_collector:sample(context, expired_routes)
assert(partial_inventory.data.routes.partial and partial_inventory.data.routes.invalid_lines == 1)
now = now + 1000000000
local held_partial = network_collector:sample(context, partial_inventory)
assert(held_partial.data.routes == partial_inventory.data.routes,
  "a bad but bounded route list is not redecoded every second")
net_files["/proc/net/route"] = original_route_file

local route_source = fake_fs({
  ["/proc/net/route"] = table.concat({
    "Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT",
    "eth0 00000000 0100000A 0003 0 0 100 00000000 0 0 0",
    "eth0 0000000A 00000000 0001 0 0 20 00FFFFFF 0 0 0",
    "lo 0100007F 00000000 0001 0 0 0 FFFFFFFF 0 0 0",
    "eth0 0000000A 00000000 0001 0 0 20 00FF00FF 0 0 0",
  }, "\n"),
  ["/proc/net/ipv6_route"] = table.concat({
    "00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 000000C8 00000000 00000000 00000001 eth0",
    "20010db8000000000000000000000000 40 20010db9000000000000000000000000 40 00000000000000000000000000000000 00000100 00000000 00000000 00000001 eth0",
    "00000000000000000000000000000000 00 00000000000000000000000000000000 00 00000000000000000000000000000000 ffffffff 00000001 00000000 00200200 lo",
  }, "\n"),
})
local route_view = Routes.read(route_source, "/proc/net/route", "/proc/net/ipv6_route")
local summary_defaults = Routes.default_routes(route_source,
  "/proc/net/route", "/proc/net/ipv6_route")
assert(summary_defaults.eth0.families.ipv4 and summary_defaults.eth0.families.ipv6
  and not summary_defaults.lo,
  "the cheap default scan agrees with the full route inventory")
assert(summary_defaults.eth0.metrics.ipv4 == 100
  and summary_defaults.eth0.metrics.ipv6 == 200
  and summary_defaults.eth0.metric == 100,
  "per-family default metrics cannot overwrite each other")
assert(route_view.total == 6 and route_view.invalid_lines == 1 and route_view.partial)
assert(route_view.default_routes.eth0.families.ipv4
  and route_view.default_routes.eth0.families.ipv6
  and route_view.default_routes.lo == nil,
  "an inactive IPv6 fallback on lo is not a usable default route")
assert(route_view.default_routes.eth0.metrics.ipv4 == 100
  and route_view.default_routes.eth0.metrics.ipv6 == 200)
local seen = {}
for _, route in ipairs(route_view.entries) do
  seen[route.interface .. ":" .. route.destination_cidr] = route
end
assert(seen["eth0:10.0.0.0/24"].gateway == nil and seen["lo:127.0.0.1/32"])
assert(seen["eth0:2001:db8::/64"].source_cidr == "2001:db9::/64")
assert(seen["eth0:::/0"].gateway == "fe80::1")
assert(seen["eth0:::/0"].selected_default
  and not seen["lo:::/0"].selected_default,
  "a prefix-zero fallback is not the selected default route")
local route_lines = table.concat(TUI.route_detail_lines({ network = { routes = route_view } },
  assert(I18n.new({ locale = "en-US" }))), "\n")
assert(route_lines:find("10.0.0.0/24", 1, true)
  and route_lines:find("fe80::1", 1, true)
  and route_lines:find("2001:db9::/64", 1, true)
  and route_lines:find("policy routing", 1, true)
  and route_lines:find("Route rows not parsed: 1", 1, true)
  and route_lines:find("inactive", 1, true))
local many_routes = { "Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT" }
for index = 1, Routes.MAX_ENTRIES do
  many_routes[#many_routes + 1] = string.format(
    "eth0 %08X 00000000 0001 0 0 10 FFFFFFFF 0 0 0", index)
end
many_routes[#many_routes + 1] = "eth0 00000000 0100000A 0003 0 0 100 00000000 0 0 0"
local capped_source = fake_fs({
  ["/proc/net/route"] = table.concat(many_routes, "\n"),
})
local capped_routes = Routes.read(capped_source, "/proc/net/route", "/proc/net/ipv6_route")
assert(capped_routes.total == Routes.MAX_ENTRIES + 1
  and #capped_routes.entries == Routes.MAX_ENTRIES and capped_routes.truncated)
assert(capped_routes.default_routes.eth0.families.ipv4,
  "default-route selection still sees a route after the display cap")
assert(Routes.default_routes(capped_source, "/proc/net/route",
  "/proc/net/ipv6_route").eth0.families.ipv4,
  "the cheap scan also sees a default route after the inventory cap")
assert(capped_routes.entries[1].destination_cidr == "0.0.0.0/0",
  "the selected default route remains visible after the inventory cap")
context.scan_routes = false

-- Reusing an interface name with a new ifindex must not continue the old
-- counter baseline.
net_files["/sys/class/net/eth0/ifindex"] = "9\n"
net_files["/proc/net/dev"] = fixture("proc/netdev.1")
now = now + 1000000000
local replaced_network = network_collector:sample(context, held_partial)
assert(replaced_network.data.routes.quality == "stale"
  and replaced_network.data.routes.observed_ns == held_partial.data.routes.observed_ns,
  "closing route detail retains its last reading with an explicit stale quality")
assert(table.concat(TUI.route_detail_lines({ network = replaced_network.data },
  assert(I18n.new({ locale = "en-US" }))), "\n"):find("Stale", 1, true),
  "held route inventory is labelled stale in its overlay")
assert(Export.snapshot({ network = replaced_network.data }).network.routes.quality == "stale",
  "export retains the age label when the last route inventory is held")
local replaced_eth0 = replaced_network.data.interfaces[2]
assert(replaced_eth0.name == "eth0" and replaced_eth0.ifindex == 9)
assert(replaced_eth0.quality == "gap" and next(replaced_eth0.rates) == nil)

-- Without an ifindex there is no safe identity to which a previous counter
-- sample can be attached.
net_files["/sys/class/net/eth0/ifindex"] = nil
now = now + 1000000000
local unidentified_network = network_collector:sample(context, replaced_network)
local unidentified_eth0
for _, interface in ipairs(unidentified_network.data.interfaces) do
  if interface.name == "eth0" then unidentified_eth0 = interface end
end
assert(unidentified_eth0 and unidentified_eth0.ifindex == nil)
assert(unidentified_eth0.quality == "gap" and next(unidentified_eth0.rates) == nil)

-- The network collector is the twelfth to publish a reason for a degraded but
-- running reading, and it passes the test a single reason slot has to pass: a
-- sentence that is true in *every* case that produces the quality. `partial`
-- means some procfs route data could not be read or kept. `gap` is
-- set when an interface has no previous sample, when no interval has elapsed,
-- or when a counter could not be differenced, and all three mean no rate
-- exists for it this tick.  So the assertion is the pairing again, and it needs
-- a route read that is refused rather than absent, because an absent file is
-- how a host with no IPv4 route table looks and it is not a degradation.
local NET_REASON = { partial = "route_data_incomplete",
  gap = "network_rate_unavailable", fresh = false }
local network_reason_is = function(result, label)
  return CollectorReason.assert_reason(result, NET_REASON, label)
end
network_reason_is(network_first, "the first network sample")
network_reason_is(network_second, "the second network sample")
network_reason_is(replaced_network, "a sample after the ifindex changed")
network_reason_is(unidentified_network, "a sample with no ifindex")

local open_fs = context.fs
local denying_fs = {}
for key, value in pairs(open_fs) do denying_fs[key] = value end
function denying_fs:read(path, limit)
  if path == "/proc/net/route" then
    return nil, { kind = "denied", message = "fixture_denied", path = path }
  end
  return open_fs.read(self, path, limit)
end
context.fs = denying_fs
now = now + 1000000000
local denied_routes = network_collector:sample(context, unidentified_network)
network_reason_is(denied_routes, "a sample whose route table was refused")
assert(denied_routes.quality == "partial",
  "a refused route table degrades the reading")
assert(#denied_routes.data.default_routes == 0,
  "and no default route is invented for it")
context.fs = open_fs
-- Both causes live at once: the route table reads again, and the counters are
-- unchanged from the sample just taken, so no rate exists for any interface.
-- The published quality is `gap`, so the reason must name that.
now = now + 1000000000
local network_both = network_collector:sample(context, denied_routes)
network_reason_is(network_both, "a readable route table and no counter delta")
assert(network_both.quality == "gap",
  "the unchanged counters are still why the reading is degraded")
assert(network_both.reason == "network_rate_unavailable",
  "and the reason names them, not the route table that now reads")

local process_files = {
  ["/proc/100/stat"] = fixture("proc/100.stat.1"),
  ["/proc/100/status"] = fixture("proc/100.status"),
  ["/proc/100/cmdline"] = "lua\0worker.lua\0",
  ["/proc/100/io"] = fixture("proc/100.io"),
  ["/proc/100/cgroup"] = fixture("proc/100.cgroup"),
}
context.fs = fake_fs(process_files, { ["/proc"] = { "self", "101", "100", "uptime" } })
local process_collector = Process.new({ read_cmdline = true, read_io = true, read_cgroup = true })
local process_first = process_collector:sample(context)
assert(#process_first.data.list == 1 and process_first.data.races == 1)
assert(process_first.data.list[1].id == "100:1000")
assert(process_first.data.list[1].command == "lua worker.lua")
assert(process_first.data.list[1].resident_bytes == 4096 * 1024)
process_files["/proc/100/stat"] = fixture("proc/100.stat.2")
now = now + 1000000000
local process_second = process_collector:sample(context, process_first)
near(process_second.data.list[1].cpu_percent, 50)
assert(process_second.data.list[1].io.write_bytes == 8192)
assert(Process.sanitize_text("bad\255name") == "bad�name")

-- A selected refresh can observe an empty command line after a non-empty one.
-- Drop the old text immediately, while later argv changes keep refreshing.
do
  local command = "old\0argument\0"
  local command_now = 1000000000
  local files = {
    ["/proc/100/stat"] = fixture("proc/100.stat.1"),
    ["/proc/100/cmdline"] = function() return command end,
  }
  local collector = Process.new({ read_status = false, read_cmdline = true,
    read_io = false, read_cgroup = false, clock_ticks_per_second = 100, page_size_bytes = 4096 })
  local ctx = { fs = fake_fs(files, { ["/proc"] = { "100" } }),
    now_ns = function() return command_now end }
  local first = collector:sample(ctx)
  assert(first.data.by_id["100:1000"].command == "old argument")
  command = ""
  ctx.selected_process_ids = { ["100:1000"] = true }
  command_now = command_now + 1000000000
  local empty = collector:sample(ctx, first)
  assert(empty.data.by_id["100:1000"].command == nil,
    "a fresh empty command must not retain the old cached text")
  ctx.selected_process_ids = nil
  command = "changed\0arguments\0"
  local updated = empty
  for _ = 1, 5 do
    command_now = command_now + 1000000000
    updated = collector:sample(ctx, updated)
  end
  assert(updated.data.by_id["100:1000"].command == "changed arguments",
    "the empty-value correction must preserve bounded argv refreshes")
end

-- A PID reused between stat and supplemental status reads must be discarded.
local original_stat = fixture("proc/100.stat.1")
local reused_stat = original_stat:gsub(" 1000 10485760 ", " 2000 10485760 ")
assert(reused_stat ~= original_stat)
local generation_reads = 0
local generation_fs = fake_fs({
  ["/proc/100/stat"] = function()
    generation_reads = generation_reads + 1
    return generation_reads == 1 and original_stat or reused_stat
  end,
  ["/proc/100/status"] = fixture("proc/100.status"),
}, { ["/proc"] = { "100" } })
local reused_result = Process.new():sample({ fs = generation_fs, now_ns = function() return now end })
assert(generation_reads == 2)
assert(#reused_result.data.list == 0)
assert(reused_result.data.races == 1)

-- Enumeration is bounded in the native list call, not after an unbounded
-- directory allocation. The result exposes its partial quality downstream.
local bound_stat = fixture("proc/100.stat.1")
local bound_files = {}
for _, pid in ipairs({ 100, 101, 102, 103 }) do
  bound_files["/proc/" .. tostring(pid) .. "/stat"] = bound_stat:gsub("^100", tostring(pid), 1)
end
local bound_fs = fake_fs(bound_files, { ["/proc"] = { "self", "103", "102", "101", "100" } })
local bound_list_limit
local original_bound_list = bound_fs.list
function bound_fs:list(path, limit)
  bound_list_limit = limit
  local entries, list_error = original_bound_list(self, path)
  return entries, list_error, true
end
local bounded_processes = Process.new({ max_processes = 2, read_status = false }):sample({
  fs = bound_fs, now_ns = function() return now end,
})
assert(bound_list_limit == 258)
assert(bounded_processes.data.scanned == 2 and #bounded_processes.data.list == 2)
assert(bounded_processes.data.list[1].pid == 100 and bounded_processes.data.list[2].pid == 101)
assert(bounded_processes.data.truncated and bounded_processes.data.partial
  and bounded_processes.data.process_limit == 2)
assert(bounded_processes.quality == "partial")
assert(not pcall(Process.new, { max_processes = 0 }))
assert(not pcall(Process.new, { max_processes = 999999 }))
assert(not pcall(Process.new, "invalid"))
assert(not pcall(Process.new, { clock_ticks_per_second = 0 }))

local gpu_files = {
  ["/sys/class/drm/card0/device/uevent"] = "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n",
  ["/sys/class/drm/renderD128/device/uevent"] = "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n",
  ["/sys/class/drm/card0/dev"] = "226:0\n",
  ["/sys/class/drm/renderD128/dev"] = "226:128\n",
  ["/sys/class/drm/card0/device/vendor"] = "0x1002\n",
  ["/sys/class/drm/card0/device/device"] = "0x73bf\n",
  ["/sys/class/drm/card0/device/gpu_busy_percent"] = "71\n",
  ["/sys/class/drm/card0/device/mem_info_vram_total"] = "17179869184\n",
  ["/sys/class/drm/card0/device/mem_info_vram_used"] = "4294967296\n",
  ["/sys/class/drm/card0/device/hwmon/hwmon0/name"] = "amdgpu\n",
  ["/sys/class/drm/card0/device/hwmon/hwmon0/temp1_input"] = "65000\n",
  ["/sys/class/drm/card0/device/hwmon/hwmon0/power1_average"] = "120000000\n",
  ["/sys/class/drm/card0/device/hwmon/hwmon0/fan1_input"] = "1450\n",
}
context.fs = fake_fs(gpu_files, {
  ["/sys/class/drm"] = { "card0", "card0-DP-1", "renderD128" },
  ["/sys/class/drm/card0/device/hwmon"] = { "hwmon0" },
}, {
  ["/sys/class/drm/card0/device"] = "../../../0000:03:00.0",
  ["/sys/class/drm/card0/device/driver"] = "../../../../bus/pci/drivers/amdgpu",
  ["/sys/class/drm/renderD128/device"] = "../../../0000:03:00.0",
  ["/sys/class/drm/renderD128/device/driver"] = "../../../../bus/pci/drivers/amdgpu",
})
local gpu_collector = GPU.new({ scan_processes = false })
assert(gpu_collector:probe(context).available)
local gpu = gpu_collector:sample(context)
assert(gpu.status == "ok" and #gpu.data.devices == 1)
local device = gpu.data.devices[1]
assert(device.id == "0000:03:00.0" and device.vendor == "amd" and device.driver == "amdgpu")
assert(device.metrics.temperature_celsius == nil and device.metrics.power_watts == nil)
assert(device.capabilities.hwmon and #device.hwmon_refs == 1)
assert(device.render_nodes[1] == "renderD128")
assert(device.capabilities.utilization and device.capabilities.memory)

-- Direct procfs collectors should tolerate real Linux state as a smoke test.
context.fs = nil
context.now_ns = nil
assert(CPU.new():sample(context).status == "ok")
assert(Memory.new():sample(context).status == "ok")

return true
