package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

-- Is the RAM-bandwidth inspector honest about what it can do?
--
-- docs/PLAN.md carried "whether to retain the experimental perf stat RAM-bandwidth
-- Inspector in 0.1, including platform claims and default enablement" as an open
-- question, and it was open for the same reason the minimum-GPU-capability
-- question was: it was filed as needing hardware nobody had.  It does not.  The
-- question that is answerable from the source -- what does the capability record
-- claim, and what has actually been established -- was answerable all along, and
-- one host shape turned out to be enough to answer it.
--
-- The finding, measured on a host that publishes all four PMU names the
-- whitelist looks for:
--
--   uncore_imc_0, uncore_imc_1,
--   uncore_imc_free_running_0, uncore_imc_free_running_1
--
-- `perf list` advertises data_read, data_write and data_total on the free-running
-- pair -- exactly the event names the reader matches -- and every one of them
-- fails `sys_perf_event_open` with EINVAL, because a free-running counter is not
-- a counting PMU.  So the probe found four PMUs and reported `available` with an
-- empty reason, and the first real measurement produced
-- `memory_events_not_supported`.  A line that says ready and then says nothing is
-- the same defect as an SBOM with no hashes: it asserts a conclusion nobody
-- established.
--
-- What is deliberately *not* asserted here, because it could not be measured: the
-- `perf_event_paranoid` rule.  The obvious fix -- "downgrade when paranoid >= 2,
-- because uncore needs CAP_PERFMON" -- is a kernel rule that this host cannot
-- demonstrate, since its events fail with EINVAL before any permission check is
-- reached.  Both `perf stat -a -e unc_m_cas_count_rd` and the per-task form fail
-- identically.  Writing an unmeasured rule into a capability record is the defect
-- this project keeps removing, so the fix states only what the probe established.

local Fixture = require("support.fixture_fs")
local Bandwidth = require("wtop.inspectors.ram_bandwidth")
local I18n = require("wtop.i18n")
local ViewModel = require("wtop.view_model")

local translator = assert(I18n.new({ locale = "en-US" }))
local engine = { history_values = function() return {} end }

-- The host measured above, reproduced as a fixture: four matching PMUs, of which
-- the counting pair publishes no events at all and the free-running pair
-- publishes the modern names the reader knows.
local PMUS = { "uncore_imc_0", "uncore_imc_1",
              "uncore_imc_free_running_0", "uncore_imc_free_running_1" }

local files, dirs = {}, {
  ["/sys/bus/event_source/devices"] = PMUS,
  ["/proc/sys/kernel"] = { "perf_event_paranoid" },
}
for _, pmu in ipairs(PMUS) do
  local base = "/sys/bus/event_source/devices/" .. pmu
  files[base .. "/cpumask"] = "0-15\n"
  files[base .. "/type"] = "8\n"
  if pmu:find("free_running", 1, true) then
    dirs[base .. "/events"] = { "data_read", "data_read.scale", "data_read.unit",
                                "data_write", "data_write.scale", "data_write.unit" }
    files[base .. "/events/data_read"] = "event=0xff,umask=0x20\n"
    files[base .. "/events/data_read.scale"] = "6.103515625e-5\n"
    files[base .. "/events/data_read.unit"] = "MiB\n"
    files[base .. "/events/data_write"] = "event=0xff,umask=0x30\n"
    files[base .. "/events/data_write.scale"] = "6.103515625e-5\n"
    files[base .. "/events/data_write.unit"] = "MiB\n"
  end
end
files["/proc/sys/kernel/perf_event_paranoid"] = "2\n"

local fs = Fixture.new({ files = files, dirs = dirs })
local context = { fs = fs, now_ns = function() return 1000000000 end }

local function collector(reader)
    return Bandwidth.new({
        perf_reader = reader,
        event_source_path = "/sys/bus/event_source/devices",
        paranoid_path = "/proc/sys/kernel/perf_event_paranoid",
    })
end

-- ---------------------------------------------------------------------------
-- 1. The capability record must say what it established and what it did not.

local no_reader = collector(nil)
local without_reader = no_reader:probe(context)
assert(without_reader.state == "degraded",
    "a bandwidth inspector with no reader reports " .. tostring(without_reader.state))

-- With a reader, the PMUs are found.  The record must still carry a reason,
-- because finding a PMU is not the same as opening a counter, and the probe does
-- not open one.
local reads = 0
local with_reader = collector(function() reads = reads + 1 return nil end)
local capability = with_reader:probe(context)
assert(capability.available == true,
    "four matching memory-controller PMUs should make the source present")
assert(reads == 0,
    "the probe opened a counter, which means it runs a perf invocation every "
        .. "time the Insights page is built; that is why it states the source "
        .. "is present rather than that it can be read")
assert(capability.reason == "memory_counter_read_unverified",
    "the capability record says " .. tostring(capability.reason) .. " on a host "
        .. "whose counters have not been read.  Without a reason the Insights row "
        .. "reads `ready` beside an empty column, which is a claim about whether "
        .. "the inspector works made by a probe that never tried")

-- The reason has to reach the operator in every catalog, or the correction is
-- invisible on nine of ten locales and the row is still empty there.
-- Capabilities are the fourth argument to build, not a field of the snapshot:
-- the probe results belong to the engine, and a snapshot that carried them
-- would be asserting that a collector produced them.
local rendered = ViewModel.build(engine, {
  cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, processes = {},
  cpu_frequency = {}, mounts = {}, workloads = {}, connections = {},
  sensors = { devices = {} }, inventory = {}, quality = {},
}, translator, { inspectors = { ["memory.bandwidth"] = capability } }, "insights")
local row = rendered.inspector_table and rendered.inspector_table.rows[1]
assert(row ~= nil, "the Insights page has no inspector row for the bandwidth probe")
assert(row.inspector:find("RAM bandwidth", 1, true) ~= nil,
    "the row does not name the inspector: " .. tostring(row.inspector))
assert(row.reason ~= "—" and row.reason ~= nil and row.reason ~= "",
    "the row still shows an empty reason beside `ready`; the probe's reason is "
        .. tostring(capability.reason) .. " and did not reach the table")

-- And it must not become advice.  An available source is not a gap, and putting
-- it in the "Unavailable sources" list on every server that has the hardware
-- would be the opposite correction: under-claiming so loudly that it is noise.
local advice = rendered.advice_list and rendered.advice_list.entries or {}
for _, entry in ipairs(advice) do
    local text = tostring(entry.label) .. " " .. tostring(entry.value)
    assert(not text:find("memory.bandwidth", 1, true),
        "a source that is present has been listed as a gap:\n" .. text)
end

-- ---------------------------------------------------------------------------
-- 2. A host with no memory-controller PMU is unavailable, not degraded and not
--    ready.  This is the ordinary case on a laptop, and the row must say so
--    rather than inviting an operator to run something that cannot work.

local no_pmu_fs = Fixture.new({
  files = { ["/proc/sys/kernel/perf_event_paranoid"] = "2\n" },
  dirs = { ["/sys/bus/event_source/devices"] = { "cpu_core", "software", "tracepoint" },
           ["/proc/sys/kernel"] = { "perf_event_paranoid" } },
})
local absent = collector(function() return nil end):probe(
    { fs = no_pmu_fs, now_ns = function() return 1000000000 end })
assert(absent.available == false and absent.state == "unavailable",
    "a host with no memory-controller PMU reports " .. tostring(absent.state) ..
        "; the ordinary laptop case must read as unavailable")
assert(absent.reason == "memory_controller_pmu_not_found",
    "and it must say why: " .. tostring(absent.reason))

-- ---------------------------------------------------------------------------
-- 3. The measurement itself must state its failure rather than returning an
--    empty reading.  This is the half the capability record was getting wrong,
--    and it is already correct; the assertion is here so the two halves stay
--    consistent, since a probe that warns and an inspect that returns a blank
--    bandwidth would leave the operator with the opposite impression.

local result = with_reader:inspect(context, { id = "system-memory", name = "System RAM" })
assert(result.status == "unavailable",
    "a reader that returns nothing produced status " .. tostring(result.status))
assert(result.reason ~= nil and result.reason ~= "",
    "an unavailable measurement with no reason: the operator is told the number "
        .. "is missing and not why")

-- And the theoretical figure, which does not need a counter at all, must not be
-- presented as a measurement.  It is computed from the memory topology, so it is
-- the one thing the inspector can always offer, and it is labelled `estimated`
-- precisely because it is a formula rather than a reading.
local with_topology = with_reader:inspect(context, {
  id = "system-memory", name = "System RAM",
  data_rate_mt_s = 4800, channels = 2, bus_width_bits = 64,
  topology_source = "dmi",
})
local metrics = with_topology.entity and with_topology.entity.metrics or {}
local theoretical = metrics.theoretical_bandwidth
local total = metrics.total_bandwidth
assert(theoretical ~= nil and theoretical.value ~= nil,
    "the inspector cannot offer its theoretical figure even with a topology; it "
        .. "is the one value that needs no counter and should never be missing")
assert(theoretical.estimated == true,
    "a figure computed from the memory topology is marked as a plain value; it "
        .. "is a formula, and an unlabelled one reads as a measurement")
assert(total == nil or total.value == nil,
    "a total bandwidth was published although no counter was read")
-- 4800 MT/s x 2 channels x 64 bits is 76.8 GB/s.  The figure is derived, and it
-- is the whole reason the inspector survives a host whose counters will not
-- open -- so it has to be right, not merely present.
assert(theoretical.value == 4800 * 1000000 * 8 * 2,
    "the theoretical figure is " .. tostring(theoretical.value) .. " for a "
        .. "declared 4800 MT/s, 2-channel, 64-bit memory interface")
assert(with_topology.provider == "memory_topology_formula",
    "a result built only from the topology formula reports provider "
        .. tostring(with_topology.provider) .. "; a reader is named as the "
        .. "provider even when the reader produced nothing")

return true
