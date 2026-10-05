-- AMD SMI provider.  The host running the suite has no amdgpu card and no
-- libamdsmi, so every assertion here drives an injected provider -- the same
-- seam the NVML provider is tested through.  That covers the join logic and
-- the refusal paths; the C layer's dlopen and struct reads can only be
-- exercised on real hardware, which is why the provider treats every field
-- as independently optional.
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local AMDSMI = require("wtop.collectors.amdsmi")
local GPU = require("wtop.collectors.gpu")
local Fixture = require("support.fixture_fs")

local failures = 0
local function equal(actual, expected, message)
  if actual ~= expected then
    failures = failures + 1
    error(string.format("%s: got %s, expected %s", message,
      tostring(actual), tostring(expected)), 2)
  end
end
local function truthy(value, message)
  if not value then
    failures = failures + 1
    error(message .. ": got " .. tostring(value), 2)
  end
end

-- The bus address is the join key, so a malformed one must be rejected rather
-- than silently creating a second device for the same card.
equal(AMDSMI.normalize_bdf("0000:03:00.0"), "0000:03:00.0", "a well-formed BDF passes")
equal(AMDSMI.normalize_bdf("000F:03:00.0"), "000f:03:00.0", "hex is lowercased")
equal(AMDSMI.normalize_bdf("0000:3:00.0"), nil, "a short bus number is rejected")
equal(AMDSMI.normalize_bdf("0000:03:00.8"), nil, "an impossible function is rejected")
equal(AMDSMI.normalize_bdf("0000:03:00"), nil, "a missing function is rejected")
equal(AMDSMI.normalize_bdf("garbage"), nil, "a malformed bus ID is rejected")
equal(AMDSMI.normalize_bdf(nil), nil, "a missing bus ID is rejected")

-- A provider that raises, or a host with no library, must not take the
-- collector down.
local raised, raised_reason = AMDSMI.query(function() error("boom") end)
equal(raised, nil, "a raising provider is contained")
equal(raised_reason, "amdsmi_query_failed", "and reported")
local missing, missing_reason = AMDSMI.query(function()
  return nil, "amdsmi_library_not_found"
end)
equal(missing, nil, "an absent library yields no data")
equal(missing_reason, "amdsmi_library_not_found", "with the provider's reason")
local non_table = AMDSMI.query(function() return "not a table" end)
equal(non_table, nil, "a malformed payload is rejected")
local not_a_function, no_provider_reason = AMDSMI.query("not callable")
equal(not_a_function, nil, "a missing provider is rejected")
equal(no_provider_reason, "amdsmi_provider_unavailable", "with its own reason")

local amdsmi_data = {
  driver_version = "6.8.5",
  devices = {
    { index = 0, name = "AMD Radeon RX 7900 XTX", uuid = "GPU-79c0",
      pci_bdf = "0000:03:00.0", utilization_percent = 71,
      memory_utilization_percent = 12, memory_total_bytes = 24 * 2^30,
      memory_used_bytes = 6 * 2^30, temperature_celsius = 58,
      power_watts = 47.5, power_limit_watts = 355.0,
      graphics_clock_hz = 2500000000, graphics_clock_maximum_hz = 2800000000,
      memory_clock_hz = 10500000000, fan_speed_percent = 42 },
    { index = 1, name = "AMD Radeon 780M", uuid = "GPU-igpu",
      pci_bdf = "0000:c6:00.0", utilization_percent = 18,
      memory_total_bytes = 2^30, temperature_celsius = 47 },
  },
}

-- A DRM device amdsmi knows about gets the counters the kernel does not
-- publish, and keeps the values DRM already measured.
local drm_device = {
  id = "0000:03:00.0", card = "card1", pci_bdf = "0000:03:00.0",
  driver = "amdgpu", metrics = { temperature_celsius = 61 }, capabilities = {},
  processes = { list = {}, by_id = {}, summary = {} },
}
local devices = { drm_device }
local lookup = { by_bdf = { ["0000:03:00.0"] = drm_device } }
local status = AMDSMI.merge(devices, lookup, amdsmi_data, {
  used_ids = { ["0000:03:00.0"] = true },
})
equal(status.status, "ok", "a complete provider is ok")
equal(status.merged_devices, 1, "one amdsmi device joins its DRM node")
equal(status.added_devices, 1, "one amdsmi device has no DRM node")
equal(status.incomplete_devices, 0, "nothing is incomplete")
equal(status.driver_version, "6.8.5", "the driver version is reported")
equal(#devices, 2, "the unmatched GPU is appended")

equal(drm_device.metrics.utilization_percent, 71, "amdsmi fills utilization")
equal(drm_device.metrics.utilization_source, "amdsmi", "and names its source")
equal(drm_device.metrics.temperature_celsius, 61,
  "a value DRM already measured keeps precedence")
equal(drm_device.metrics.memory_busy_percent, 12, "memory-controller activity")
equal(drm_device.metrics.power_watts, 47.5, "socket power")
equal(drm_device.metrics.power_limit_watts, 355, "power cap")
equal(drm_device.metrics.frequency_current_hz, 2500000000, "graphics clock")
equal(drm_device.metrics.frequency_graphics_hz, 2500000000, "named graphics clock")
equal(drm_device.metrics.frequency_maximum_hz, 2800000000, "maximum clock")
equal(drm_device.metrics.frequency_memory_hz, 10500000000, "memory clock")
equal(drm_device.metrics.fan_speed_percent, 42, "fan speed")
equal(drm_device.model_name, "AMD Radeon RX 7900 XTX", "the name fills a missing model")
equal(drm_device.vendor_uuid, "GPU-79c0", "vendor UUID")
equal(drm_device.driver_version, "6.8.5", "driver version")
equal(drm_device.capabilities.amdsmi, true, "the device records the provider")
equal(drm_device.partial, nil, "a complete device is not partial")

local added = devices[2]
equal(added.id, "0000:c6:00.0", "an added device is keyed by its bus address")
equal(added.source, "amdsmi", "added device source")
equal(added.vendor_name, "AMD", "added device vendor")
equal(added.driver, "amdgpu", "added device driver")
equal(added.model_name, "AMD Radeon 780M", "added device name")
equal(added.metrics.memory_total_bytes, 2^30, "added device memory")
-- A device amdsmi can see but not fully describe must not look healthy.
equal(added.metrics.fan_speed_percent, nil, "a field the library omitted stays absent")
equal(added.metrics.power_watts, nil, "so does another")

-- A device with neither name nor bus address is a real gap.
local blind = AMDSMI.merge({}, { by_bdf = {} }, {
  devices = { { index = 0 } },
}, { used_ids = {} })
equal(blind.status, "partial", "an undescribable device makes the result partial")
equal(blind.incomplete_devices, 1, "and is counted")
truthy(blind.added_devices == 1, "the device is still listed")

-- A BDF that cannot join leaves the DRM device untouched and adds its own.
local odd = AMDSMI.merge({}, { by_bdf = {} }, {
  devices = { { index = 0, name = "AMD", pci_bdf = "not-a-bdf", uuid = "GPU-x" } },
}, { used_ids = {} })
equal(odd.added_devices, 1, "an unjoinable BDF becomes its own device")
equal(odd.devices, nil, "the result does not smuggle the device list")

-- A second card whose BDF collides must not overwrite the first.
local collide = { id = "0000:03:00.0", metrics = {}, capabilities = {},
  processes = { list = {}, by_id = {}, summary = {} } }
local collide_devices = { collide }
AMDSMI.merge(collide_devices, { by_bdf = { ["0000:03:00.0"] = collide } }, {
  devices = { { index = 0, name = "AMD", uuid = "GPU-dup", pci_bdf = "0000:03:00.0" } },
}, { used_ids = { ["0000:03:00.0"] = true } })
equal(#collide_devices, 1, "a device is not duplicated by its own provider")

-- ---------------------------------------------------------------------------
-- The collector: a fixture DRM tree plus an injected provider.
local card = "/sys/class/drm/card1"
local amd_tree = {
  files = {
    [card .. "/dev"] = "226:0\n",
    [card .. "/uevent"] = "MAJOR=226\nMINOR=0\nDEVNAME=dri/card1\n",
    [card .. "/device/vendor"] = "0x1002\n",
    [card .. "/device/device"] = "0x744c\n",
    [card .. "/device/class"] = "0x030000\n",
  },
  links = {
    [card] = "../../devices/pci0000:00/0000:00:01.0/0000:03:00.0/drm/card1",
    [card .. "/device"] = "../../../0000:03:00.0",
    [card .. "/device/driver"] = "../../../../bus/pci/drivers/amdgpu",
  },
}

local calls = 0
local function provider()
  calls = calls + 1
  return amdsmi_data
end

local collector = GPU.new({ fs = Fixture.new(amd_tree), scan_processes = false,
  amdsmi = provider })
local merged = collector:sample({ now_ns = function() return 1 end })
equal(merged.status, "ok", "the collector runs with an amdsmi provider")
equal(merged.data.providers.amdsmi.status, "ok", "the provider status is exported")
equal(calls, 1, "the provider is consulted once per sample")
local merged_device = merged.data.by_id["0000:03:00.0"]
truthy(merged_device, "the DRM device keeps its bus-address ID")
equal(merged_device.metrics.power_watts, 47.5, "amdsmi power reaches the DRM device")
equal(merged_device.metrics.utilization_source, "amdsmi", "and the source is recorded")
equal(#merged.data.devices, 2, "the second amdsmi GPU is listed too")

-- Safe mode must not load a vendor library.
local safe = collector:sample({ now_ns = function() return 2 end, safe_mode = true })
equal(safe.data.providers.amdsmi.reason, "safe_mode", "safe mode skips amdsmi")
equal(#safe.data.devices, 1, "only DRM devices survive safe mode")

-- A host with no amdsmi still reports the page, and says why the provider is
-- missing rather than pretending the GPU has no counters.
local bare = GPU.new({ fs = Fixture.new(amd_tree), scan_processes = false,
  amdsmi = function() return nil, "amdsmi_library_not_found" end })
local bare_sample = bare:sample({ now_ns = function() return 3 end })
equal(bare_sample.status, "ok", "the DRM path still works without amdsmi")
equal(bare_sample.data.providers.amdsmi.status, "unavailable", "the provider is unavailable")
equal(bare_sample.data.providers.amdsmi.reason, "amdsmi_library_not_found", "with its reason")
equal(#bare_sample.data.devices, 1, "and the card is still listed")

-- A headless amdgpu card with no DRM node at all is still a usable GPU page.
local headless = GPU.new({ fs = Fixture.new({ dirs = { ["/sys/class/drm"] = {} } }),
  scan_processes = false, amdsmi = provider })
equal(headless:probe({}).state, "available", "amdsmi alone makes the collector available")
local headless_sample = headless:sample({ now_ns = function() return 4 end })
equal(headless_sample.status, "ok", "a host without DRM nodes still lists amdsmi GPUs")
equal(#headless_sample.data.devices, 2, "both amdsmi GPUs")
equal(headless_sample.data.providers.amdsmi.status, "ok", "the provider is reported")

print("ok: AMD SMI provider (BDF join, precedence, headless, safe mode, refusals)")
return true
