-- Level Zero provider for Intel GPUs.  The host running the suite has no
-- libze_loader and an iGPU whose sysfs exposes neither temperature nor power,
-- so every assertion drives an injected provider.  That covers the join, the
-- precedence rules and the refusal paths; the C layer only crosses the
-- boundary with pointers, doubles and 32-bit integers, precisely so that what
-- remains unverified on real hardware cannot misread a structure.
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local LEVELZERO = require("wtop.collectors.levelzero")
local GPU = require("wtop.collectors.gpu")
local Fixture = require("support.fixture_fs")

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: got %s, expected %s", message,
      tostring(actual), tostring(expected)), 2)
  end
end
local function truthy(value, message)
  if not value then error(message .. ": got " .. tostring(value), 2) end
end

-- A provider that raises, or a host with no loader, must not take the
-- collector down.
local raised, raised_reason = LEVELZERO.query(function() error("boom") end)
equal(raised, nil, "a raising provider is contained")
equal(raised_reason, "levelzero_query_failed", "and reported")
local missing, missing_reason = LEVELZERO.query(function()
  return nil, "levelzero_library_not_found"
end)
equal(missing, nil, "an absent library yields no data")
equal(missing_reason, "levelzero_library_not_found", "with the provider's reason")
equal(LEVELZERO.query("not callable"), nil, "a missing provider is rejected")
local _, no_provider = LEVELZERO.query(nil)
equal(no_provider, "levelzero_provider_unavailable", "with its own reason")

local levelzero_data = {
  driver_count = 1,
  devices = {
    { index = 0, temperature_celsius = 47.0, graphics_clock_hz = 1200000000,
      memory_clock_hz = 6400000000, board_power_watts = 28.5 },
    { index = 1, temperature_celsius = 52.0, board_power_watts = 61.25 },
  },
}

-- The counters i915 sysfs does not publish reach a DRM device that has none.
local arc = {
  id = "0000:00:02.0", card = "card1", pci_bdf = "0000:00:02.0", driver = "i915",
  metrics = {}, capabilities = {}, processes = { list = {}, by_id = {}, summary = {} },
}
local arc2 = {
  id = "0000:00:03.0", card = "card2", pci_bdf = "0000:00:03.0", driver = "i915",
  metrics = {}, capabilities = {}, processes = { list = {}, by_id = {}, summary = {} },
}
local devices = { arc, arc2 }
local status = LEVELZERO.merge(devices, levelzero_data, { arc, arc2 }, { used_ids = {} })
equal(status.status, "ok", "a fully matched provider is ok")
equal(status.merged_devices, 2, "both devices join DRM cards")
equal(status.added_devices, 0, "nothing is appended")
equal(status.driver_count, 1, "the driver count is reported")
equal(arc.metrics.temperature_celsius, 47.0, "edge temperature")
equal(arc.metrics.frequency_current_hz, 1200000000, "GPU clock")
equal(arc.metrics.frequency_graphics_hz, 1200000000, "named GPU clock")
equal(arc.metrics.frequency_memory_hz, 6400000000, "memory clock")
equal(arc.metrics.board_power_watts, 28.5, "package power")
equal(arc.metrics.board_power_source, "levelzero", "and names its source")
equal(arc.capabilities.levelzero, true, "the device records the provider")
-- Package power is kept beside the per-socket figure rather than merged into
-- it, so a panel can say which measurement it is showing.
truthy(arc.metrics.power_watts == nil,
  "board power does not masquerade as socket power")
equal(arc2.metrics.board_power_watts, 61.25, "the second card gets its own power")
equal(arc2.metrics.temperature_celsius, 52.0, "and its own temperature")

-- A value the driver already reported keeps precedence.
local filled = { id = "x", driver = "i915", metrics = {
  temperature_celsius = 39, power_watts = 12 }, capabilities = {},
  processes = { list = {}, by_id = {}, summary = {} } }
LEVELZERO.merge({ filled }, levelzero_data, { filled }, { used_ids = {} })
equal(filled.metrics.temperature_celsius, 39,
  "a temperature hwmon already measured keeps precedence")
equal(filled.metrics.board_power_watts, 28.5,
  "the figure only sysfs could not give is still filled")

-- More Level Zero devices than DRM cards: the extras are listed on their own
-- and the result is partial, never cross-wired onto the wrong card.
local lonely = { id = "only", driver = "i915", metrics = {}, capabilities = {},
  processes = { list = {}, by_id = {}, summary = {} } }
local grown = { lonely }
local uneven = LEVELZERO.merge(grown, levelzero_data, { lonely }, { used_ids = {} })
equal(uneven.status, "partial", "an unmatched device makes the result partial")
equal(uneven.added_devices, 1, "the extra device is appended")
equal(uneven.unmatched_devices, 1, "and is counted")
equal(grown[2].identity_quality, "estimated",
  "a device with no bus address cannot claim a confirmed identity")
equal(grown[2].quality.identity, "estimated", "and says so in its quality")
equal(grown[2].source, "levelzero", "the appended device names its source")
equal(grown[2].metrics.temperature_celsius, 52.0, "and still carries its counters")
equal(grown[2].partial, true, "an estimated-identity device is partial")

-- Fewer Level Zero devices than DRM cards: the extra cards are left alone.
local two = {
  { id = "a", driver = "i915", metrics = {}, capabilities = {},
    processes = { list = {}, by_id = {}, summary = {} } },
  { id = "b", driver = "i915", metrics = {}, capabilities = {},
    processes = { list = {}, by_id = {}, summary = {} } },
}
local few = LEVELZERO.merge(two, { driver_count = 1, devices = {
  { index = 0, temperature_celsius = 40 } } }, two, { used_ids = {} })
equal(few.status, "ok", "fewer provider devices than cards is not partial")
equal(two[2].metrics.temperature_celsius, nil,
  "the second card is not given the first card's reading")

-- No Intel card: nothing to join, so the devices stand alone rather than
-- borrowing another vendor's card.  Filtering to i915 is the collector's job,
-- so the merge is given the order it would actually receive.
local no_intel = LEVELZERO.merge({}, levelzero_data, {}, { used_ids = {} })
equal(no_intel.added_devices, 2, "every device stands alone")
equal(no_intel.merged_devices, 0, "nothing is joined")
truthy(no_intel.status == "partial", "and the result says so")

-- A device that reported neither temperature nor power is incomplete.
local blind = LEVELZERO.merge({}, { devices = { { index = 0 } } }, nil, { used_ids = {} })
truthy(blind.added_devices == 1, "the device is still listed")
equal(blind.status, "partial", "a device with no counters at all is partial")

-- ---------------------------------------------------------------------------
-- The collector: an i915 fixture tree plus an injected provider.
local card = "/sys/class/drm/card1"
local intel_tree = {
  files = {
    [card .. "/dev"] = "226:0\n",
    [card .. "/uevent"] = "MAJOR=226\nMINOR=0\nDEVNAME=dri/card1\n",
    [card .. "/device/vendor"] = "0x8086\n",
    [card .. "/device/device"] = "0x56a0\n",
    [card .. "/device/class"] = "0x030000\n",
  },
  links = {
    [card] = "../../devices/pci0000:00/0000:00:02.0/drm/card1",
    [card .. "/device"] = "../../../0000:00:02.0",
    [card .. "/device/driver"] = "../../../../bus/pci/drivers/i915",
  },
}

local calls = 0
local single = { driver_count = 1, devices = { levelzero_data.devices[1] } }
local collector = GPU.new({ fs = Fixture.new(intel_tree), scan_processes = false,
  levelzero = function()
    calls = calls + 1
    return single
  end })
local merged = collector:sample({ now_ns = function() return 1 end })
equal(merged.status, "ok", "the collector runs with a Level Zero provider")
equal(merged.data.providers.levelzero.status, "ok", "a fully matched provider is ok")
equal(merged.data.providers.levelzero.merged_devices, 1, "the card is joined")
equal(calls, 1, "the provider is consulted once per sample")
local device = merged.data.by_id["0000:00:02.0"]
truthy(device, "the DRM device keeps its bus-address ID")
equal(device.metrics.board_power_watts, 28.5, "package power reaches the DRM device")
equal(device.metrics.board_power_source, "levelzero", "with its source")
equal(#merged.data.devices, 1, "no stray device is invented")

-- A provider that sees more devices than the page has cards must not
-- cross-wire them onto the wrong card.
local wide = GPU.new({ fs = Fixture.new(intel_tree), scan_processes = false,
  levelzero = function() return levelzero_data end })
local wide_sample = wide:sample({ now_ns = function() return 6 end })
equal(wide_sample.data.providers.levelzero.status, "partial",
  "a device with no matching card makes the provider partial")
equal(wide_sample.data.providers.levelzero.unmatched_devices, 1, "and is counted")
equal(#wide_sample.data.devices, 2, "the extra device is listed on its own")
equal(wide_sample.data.devices[2].identity_quality, "estimated",
  "with an identity it cannot confirm")

-- Safe mode must not load a vendor library.
local safe = collector:sample({ now_ns = function() return 2 end, safe_mode = true })
equal(safe.data.providers.levelzero.reason, "safe_mode", "safe mode skips Level Zero")
equal(safe.data.devices[1].metrics.board_power_watts, nil,
  "and no vendor figure reaches the panel")

-- A host with no loader still works, and says why.
local bare = GPU.new({ fs = Fixture.new(intel_tree), scan_processes = false,
  levelzero = function() return nil, "levelzero_library_not_found" end })
local bare_sample = bare:sample({ now_ns = function() return 3 end })
equal(bare_sample.status, "ok", "the DRM path works without Level Zero")
equal(bare_sample.data.providers.levelzero.status, "unavailable", "provider unavailable")
equal(bare_sample.data.providers.levelzero.reason, "levelzero_library_not_found",
  "with its reason")
equal(#bare_sample.data.devices, 1, "and the card is still listed")

-- A fixture filesystem gets no host library unless a test injects one.
local injected = GPU.new({ fs = Fixture.new(intel_tree), scan_processes = false })
local injected_sample = injected:sample({ now_ns = function() return 4 end })
equal(injected_sample.data.providers.levelzero.reason, "levelzero_provider_unavailable",
  "a fixture filesystem never reaches the host loader")
equal(#injected_sample.data.devices, 1, "and only sees its own tree")

-- The collector only offers Level Zero devices to i915 cards, so an NVIDIA
-- card on the same page is never handed an Intel reading.
local nvidia_card = "/sys/class/drm/card1"
local nvidia_tree = {
  files = {
    [nvidia_card .. "/dev"] = "226:1\n",
    [nvidia_card .. "/uevent"] = "MAJOR=226\nMINOR=1\nDEVNAME=dri/card1\n",
    [nvidia_card .. "/device/vendor"] = "0x10de\n",
    [nvidia_card .. "/device/device"] = "0x2520\n",
    [nvidia_card .. "/device/class"] = "0x030000\n",
  },
  links = {
    [nvidia_card] = "../../devices/pci0000:00/0000:00:01.0/0000:01:00.0/drm/card1",
    [nvidia_card .. "/device"] = "../../../0000:01:00.0",
    [nvidia_card .. "/device/driver"] = "../../../../bus/pci/drivers/nvidia",
  },
}
local foreign = GPU.new({ fs = Fixture.new(nvidia_tree), scan_processes = false,
  levelzero = function() return levelzero_data end })
local foreign_sample = foreign:sample({ now_ns = function() return 5 end })
equal(#foreign_sample.data.devices, 3,
  "the NVIDIA card is listed and both Level Zero devices stand alone")
local nv = foreign_sample.data.devices[1]
truthy(nv.driver == "nvidia", "the DRM card is the NVIDIA one")
equal(nv.metrics.temperature_celsius, nil,
  "an Intel reading is never attached to another vendor's card")
equal(nv.metrics.board_power_watts, nil, "nor is board power")

print("ok: Level Zero provider (Intel join, board power, partial identity, safe mode)")
return true
