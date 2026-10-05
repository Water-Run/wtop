-- A GPU's clocks in the agent projection.
--
-- A discrete card drives a graphics clock and a memory clock.  They are
-- different quantities -- on the card modelled here they are 800 MHz apart --
-- and a projection that carries one of them under a bare `frequency_current_hz`
-- has not lost a number, it has published an ambiguous one: a consumer has no
-- way to tell which clock it is looking at, and the other clock is not merely
-- unshown but absent, so there is nothing to notice is missing.
--
-- The agent document is the projection that survives into whatever consumes it,
-- which is what makes the loss permanent rather than cosmetic.  The full
-- snapshot already carried every domain; these assertions are about the
-- projection agreeing with it.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Export = require("wtop.export")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

local function snapshot_with(device)
  return {
    quality = {},
    processes = { list = {} },
    disks = { devices = {} },
    network = { interfaces = {} },
    connections = { connections = {} },
    gpus = { schema = "dev.waterrun.wtop.gpu/v2", devices = { device } },
  }
end

-- 1. Two clocks, and the projection has to carry both.
local discrete = {
  id = "0000:03:00.0", card = "card0", driver = "amdgpu",
  vendor = "amd", capabilities = {}, quality = {},
  metrics = {
    utilization_percent = 40,
    frequency_current_hz = 1800000000,
    frequency_domain = "graphics",
    frequency_graphics_hz = 1800000000,
    frequency_memory_hz = 1000000000,
  },
  frequencies = { domains = {
    { id = "graphics", current_hz = 1800000000, maximum_hz = 2500000000,
      source_kind = "amdgpu_dpm" },
    { id = "memory", current_hz = 1000000000, maximum_hz = 1249000000,
      source_kind = "amdgpu_dpm" },
  } },
}
local agent = Export.agent(snapshot_with(discrete), {})
local gpu = agent.top.gpus[1]
equal(#gpu.frequencies.domains, 2, "the agent projection keeps every clock the card publishes")
equal(gpu.frequencies.domains[1].id, "graphics", "the first clock is the graphics clock")
equal(gpu.frequencies.domains[1].current_hz, 1800000000, "with its own reading")
equal(gpu.frequencies.domains[2].id, "memory", "and the memory clock is present, not just counted")
equal(gpu.frequencies.domains[2].current_hz, 1000000000,
  "the memory clock reads 800 MHz below the graphics one, which is the whole point")
equal(gpu.frequencies.domains[2].maximum_hz, 1249000000,
  "a clock's ceiling travels with it, so a pinned clock can be told from a busy one")

-- 2. The promoted scalar names the clock it was taken from.  This is what makes
-- the two fields above a set rather than two unrelated numbers.
equal(gpu.metrics.frequency_domain, "graphics",
  "the promoted frequency is attributed to a clock")
equal(gpu.metrics.frequency_current_hz, 1800000000, "and the value is unchanged")
-- The attribution has to agree with the list it points into, or it is worse than
-- no attribution: it would name a clock the document does not contain.
equal(gpu.frequencies.domains[1].id, gpu.metrics.frequency_domain,
  "the named clock is the one the list actually carries")

-- 3. The two projections must not disagree.  A summary that reshaped or dropped
-- part of the clock set would make the snapshot and the agent document two
-- different accounts of the same hardware.
local full = Export.snapshot(snapshot_with(discrete), {})
local snapshot_clocks = full.gpus.devices[1].frequencies.domains
equal(#snapshot_clocks, #gpu.frequencies.domains, "snapshot and agent agree on the clock count")
for index, domain in ipairs(snapshot_clocks) do
  equal(gpu.frequencies.domains[index].id, domain.id,
    "clock " .. index .. " is the same clock in both projections")
  equal(gpu.frequencies.domains[index].current_hz, domain.current_hz,
    "clock " .. index .. " carries the same reading in both projections")
end

-- 4. A clock list cut short by the collector's bound must say it was cut short.
-- Without the flag a bounded list is indistinguishable from a complete one, and
-- the reader concludes the card has no other clocks.
local bounded = {
  id = "0000:04:00.0", card = "card1", driver = "amdgpu",
  capabilities = {}, quality = {},
  metrics = { utilization_percent = 10, frequency_current_hz = 900000000,
    frequency_domain = "graphics" },
  frequencies = { truncated = true, domains = {
    { id = "graphics", current_hz = 900000000 },
  } },
}
local bounded_gpu = Export.agent(snapshot_with(bounded), {}).top.gpus[1]
equal(#bounded_gpu.frequencies.domains, 1, "the one clock that was read is still reported")
equal(bounded_gpu.frequencies.truncated, true,
  "and the list says it is not the whole set, so a missing clock is not read as an absent one")

-- 5. A device that publishes no clock at all states an empty set.  Omitting the
-- key would leave a consumer unable to tell "this device has no clocks" from
-- "this projection does not carry clocks", and those need different handling.
local silent = {
  id = "0000:05:00.0", card = "card2", driver = "unknown",
  capabilities = {}, quality = {}, metrics = {},
}
local silent_gpu = Export.agent(snapshot_with(silent), {}).top.gpus[1]
equal(type(silent_gpu.frequencies), "table", "the clock set is always present")
equal(#silent_gpu.frequencies.domains, 0, "and is empty rather than invented")
equal(silent_gpu.frequencies.truncated, false, "an empty set is not a truncated one")
equal(silent_gpu.metrics.frequency_current_hz, nil,
  "a device with no clock promotes no frequency")
equal(silent_gpu.metrics.frequency_domain, nil,
  "and names no clock, because there is none to name")

-- 6. A clock the kernel published incompletely is still a clock.  This host's
-- i915 reports a current frequency but publishes no ceiling at all, so a domain
-- that carries only what was read has to survive the projection rather than
-- being discarded for being incomplete -- dropping it would leave the document
-- claiming the device has no clock, which is a different and wrong statement.
local partial = {
  id = "0000:06:00.0", card = "card3", driver = "i915",
  capabilities = {}, quality = {},
  metrics = { frequency_current_hz = 450000000, frequency_domain = "gt0" },
  frequencies = { domains = { { id = "gt0", current_hz = 450000000, source_kind = "i915_gt" } } },
}
local partial_gpu = Export.agent(snapshot_with(partial), {}).top.gpus[1]
equal(#partial_gpu.frequencies.domains, 1, "an incomplete clock is still reported")
equal(partial_gpu.frequencies.domains[1].current_hz, 450000000, "with the reading it did carry")
equal(partial_gpu.frequencies.domains[1].maximum_hz, nil,
  "a ceiling the kernel never published stays absent rather than becoming zero")
equal(partial_gpu.metrics.frequency_domain, "gt0", "and it is still attributed")

-- 7. A clock that is powered down travels with its state, and the state is
-- what makes the zero readable.  The kernel prints 0 for a clock that is off;
-- keeping the reading honest means keeping the reading *and* saying what it
-- means, because "this clock is not running" and "this clock runs at 0 Hz" are
-- different statements and only the first is true.
local parked = {
  id = "0000:07:00.0", card = "card4", driver = "i915",
  capabilities = {}, quality = {},
  -- No current promoted: the collector refuses to promote a zero, so the
  -- summary carries the domain without a scalar, and names no clock, because
  -- there is no figure to attribute to one.
  metrics = { frequency_domain = "gt0" },
  frequencies = { domains = {
    { id = "gt0", actual_hz = 0, current_hz = 0, minimum_hz = 100000000,
      maximum_hz = 1500000000, quality = "unavailable" },
  } },
}
local parked_gpu = Export.agent(snapshot_with(parked), {}).top.gpus[1]
equal(parked_gpu.frequencies.domains[1].quality, "unavailable",
  "a powered-down clock says it is unavailable in the exported document")
equal(parked_gpu.frequencies.domains[1].actual_hz, 0,
  "the kernel's zero is still reported as what the kernel said")
equal(parked_gpu.metrics.frequency_current_hz, nil,
  "and no current frequency is claimed for a clock that is not running")
-- The ceiling is reachable, and through the domain rather than as a second
-- scalar: a maximum next to a current is the shape that invites reading the
-- pair as "this clock is at 300 MHz of 1500", and there is no current here for
-- that phrase to be about.  Inside the domain the two are plainly unrelated
-- readings, one of which the collector marked unavailable.
equal(parked_gpu.frequencies.domains[1].maximum_hz, 1500000000,
  "the ceiling, which is a property of the hardware, survives on the clock itself")
equal(parked_gpu.metrics.frequency_maximum_hz, nil,
  "and is not duplicated as a device scalar beside a current that does not exist")

-- 8. The client's clocks belong in the document too, and they belong in the
-- snapshot rather than the agent summary.  They are a different shape from a
-- device's -- the kernel names them independently of the engines and publishes
-- no DPM state table for them -- so they must not go through the device
-- exporter, whose field list would attach an empty `states` array and make
-- "this clock has no state table" read as "this clock has no states".
--
-- The full client model already lives in the snapshot, so its clocks cost
-- nothing to carry there.  The agent summary is a bounded projection -- it
-- already omits `processes`, and a client tree is up to 8192 entries per
-- device, so adding one would trade the document's size contract for a handful
-- of fields.  The device's own clocks were the different case: a few domains
-- per device against a 5-device cap, which the summary can carry whole.
local with_clients = {
  id = "0000:08:00.0", card = "card5", driver = "amdgpu",
  capabilities = {}, quality = {},
  metrics = { utilization_percent = 60 },
  processes = {
    quality = "fresh",
    clients = {
      { id = "0000:08:00.0:worker:31", client_id = "31", name = "worker",
        driver = "amdgpu", quality = "fresh",
        engines = {},
        frequency_domains = {
          { id = "sclk", current_hz = 1400000000, maximum_hz = 2100000000,
            of_maximum_percent = 1400000000 * 100 / 2100000000 },
          { id = "mclk", maximum_hz = 1249000000, quality = "unavailable" },
        } },
    },
    list = {},
  },
}
local snapshot_with_clients = Export.snapshot(snapshot_with(with_clients), {})
local exported_client = snapshot_with_clients.gpus.devices[1].processes.clients[1]
equal(exported_client.client_id, "31", "the client's kernel id is the identity")
equal(#exported_client.frequency_domains, 2, "both of the client's clocks are reported")
equal(exported_client.frequency_domains[1].id, "sclk", "the running clock")
equal(exported_client.frequency_domains[1].current_hz, 1400000000)
equal(exported_client.frequency_domains[1].of_maximum_percent,
  1400000000 * 100 / 2100000000, "with its share of the ceiling")
-- The fixture above is already in post-collector shape: a clock the kernel
-- reported as 0 reaches the exporter as "no current, quality unavailable",
-- because turning a powered-down clock into an absence is the collector's job
-- and doing it again here would be a second place to get it wrong.  What the
-- exporter owes is fidelity -- it must not resurrect the zero, and it must not
-- drop the verdict that explains the absence.
equal(exported_client.frequency_domains[2].current_hz, nil,
  "a parked client clock stays without a current rather than regaining a 0 Hz")
equal(exported_client.frequency_domains[2].quality, "unavailable",
  "and the verdict that explains the absence survives the projection")
equal(exported_client.frequency_domains[2].maximum_hz, 1249000000,
  "while its ceiling, which is a property of the clock, survives")
-- The device exporter's field list must not leak onto a client clock.
equal(exported_client.frequency_domains[1].states, nil,
  "a client clock carries no DPM state table, so it does not claim an empty one")
equal(exported_client.frequency_domains[1].source_kind, nil,
  "and no sysfs provenance, which is a device-side notion")
-- The agent summary still stops at the device, and that is the bounding working
-- as intended rather than an accident of the field list.
local client_agent = Export.agent(snapshot_with(with_clients), {}).top.gpus[1]
equal(client_agent.processes, nil,
  "the agent summary does not carry the client tree, so the device clocks above "
    .. "are the whole of its clock coverage")
equal(#client_agent.frequencies.domains, 0,
  "and this device's own clock list is empty rather than borrowed from a client")

print("ok: agent GPU clocks (full set, attribution, truncation, absence)")
