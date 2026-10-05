package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

-- What does wtop 0.1 require of a GPU?
--
-- This was an open question in docs/PLAN.md for as long as there was a GPU page,
-- and it was open for a bad reason: it was filed under "needs hardware".  The
-- kernel-baseline question was answered the same way -- by reading the source
-- and pinning the property -- and the answer there was "none, and here is the
-- test that says so".  The GPU half of that question has the same shape, and
-- this file is the test that says it.
--
-- The answer has two halves, and only asking the first is how a requirement
-- gets invented:
--
--   1. What does a host need of its GPU for wtop to work?  Answer: nothing.
--      No /sys/class/drm at all, an empty one, or one holding only connector
--      nodes are three different ways of having no GPU, and all three make the
--      collector report the source unavailable rather than report an empty
--      success.  That distinction is what the advice row is built on: an
--      operator on a headless host should be told "no DRM GPU exposed, this is
--      expected inside a VM", and an operator whose GPU is merely idle should
--      not be.
--
--   2. What does a GPU need of wtop to be shown at all?  Answer: one directory
--      entry named card<N>.  Not a uevent, not a device symlink, not hwmon, not
--      a frequency domain, not a vendor library.  The identity is marked
--      estimated rather than refused, because a card whose BDF cannot be read
--      is still a card the operator owns.
--
-- So generic DRM is sufficient and no vendor API is required.  NVML, AMD SMI and
-- Level Zero add data to a card that generic DRM already found; none of them is
-- load-bearing, and a host with none of the three installed loses fields rather
-- than the page.
--
-- What this file does not settle is the real-hardware pool.  Every host shape
-- here is a fixture, which is enough to answer "what does the code require" and
-- not enough to answer "what does every real card do".  The measurements that
-- would need a card -- a second clock domain, a fan curve, an RAPL zone behind
-- an iGPU -- are named in docs/PLAN.md as hardware gaps and stay there.

local Fixture = require("support.fixture_fs")
local GPU = require("wtop.collectors.gpu")
local I18n = require("wtop.i18n")
local ViewModel = require("wtop.view_model")

local translator = assert(I18n.new({ locale = "en-US" }))
local engine = { history_values = function() return {} end }

local function sample(spec, options)
  local fs = Fixture.new(spec)
  local context = { fs = fs, now_ns = function() return 1000000000 end }
  options = options or {}
  local collector = GPU.new({
    drm_path = "/sys/class/drm",
    proc_path = "/proc",
    scan_processes = false,
    -- A fixture filesystem gets no vendor provider: the real ones are loaded
    -- from the host's shared libraries, and a fixture has no host.  That is the
    -- point -- the generic path is the one being measured here.
    nvml = false, amdsmi = false, levelzero = false,
  })
  return collector, context
end

-- ---------------------------------------------------------------------------
-- 1. Three ways of having no GPU.  Each must be unavailable, not an empty
--    success, because the difference decides whether the advice row explains
--    the situation or stays silent about it.

local NO_GPU_SHAPES = {
  { label = "no /sys/class/drm at all", spec = { files = {} } },
  { label = "/sys/class/drm empty", spec = { files = {}, dirs = { ["/sys/class/drm"] = {} } } },
  { label = "connector nodes but no card", spec = { files = {},
      dirs = { ["/sys/class/drm"] = { "card0-DP-1", "card0-HDMI-A-1", "version" } } } },
}

for _, shape in ipairs(NO_GPU_SHAPES) do
  local collector, context = sample(shape.spec)
  local capability = collector:probe(context)
  assert(capability.available == false,
    shape.label .. ": the collector reports a GPU source as available when "
        .. "there is nothing to read.  An available probe on a host with no GPU "
        .. "is what makes an empty result indistinguishable from a working one.")

  local result = collector:sample(context, nil)
  assert(result.status == "unavailable",
    shape.label .. ": expected the source to be unavailable, got " ..
        tostring(result.status) .. ".  A successful empty result is the failure "
        .. "this whole project keeps meeting: it reads as a host whose GPU "
        .. "published nothing, rather than a host that has no GPU.")
  assert(result.data == nil or result.data.devices == nil or #result.data.devices == 0,
    shape.label .. ": an unavailable source still produced devices")
end

-- The advice row is the only thing that tells an operator on a headless host
-- that what they are seeing is expected.  It is built from the quality record,
-- so it is checked through the view model rather than against the collector --
-- the collector being right is necessary and not sufficient.
local function snapshot_for(result)
  return {
    cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, processes = {},
    cpu_frequency = {}, mounts = {}, workloads = {}, connections = {},
    sensors = { devices = {} },
    quality = { gpus = { status = result.status, quality = result.quality } },
    gpus = result.data,
  }
end

local no_gpu_collector, no_gpu_context = sample(NO_GPU_SHAPES[1].spec)
local no_gpu_result = no_gpu_collector:sample(no_gpu_context, nil)
local no_gpu_models = ViewModel.build(engine, snapshot_for(no_gpu_result), translator, {}, "system")
local advice = no_gpu_models.advice_list and no_gpu_models.advice_list.entries or {}
local advice_text = {}
for _, entry in ipairs(advice) do
  advice_text[#advice_text + 1] = tostring(entry.label) .. " " .. tostring(entry.value)
end
local joined = table.concat(advice_text, "\n")
assert(joined:find("gpus", 1, true) ~= nil,
    "the advice list does not mention the GPU source at all on a host with no "
        .. "GPU:\n" .. joined)
assert(joined:find("DRM", 1, true) ~= nil,
    "the advice does not say what is missing in terms the operator can act on:\n"
        .. joined)

-- ---------------------------------------------------------------------------
-- 2. The minimum GPU: one entry named card<N> and nothing else.  No uevent to
--    identify the driver, no device symlink for the BDF, no hwmon, no clock
--    domain, no vendor library.  This is the shape that answers "is a vendor API
--    required", and the answer has to come out of a fixture rather than from the
--    card on the machine the test runs on.

local collector, context = sample({ files = {},
  dirs = { ["/sys/class/drm"] = { "card0" } } })
local capability = collector:probe(context)
assert(capability.available == true,
    "a single card entry is the minimum wtop should accept, and the probe "
        .. "rejected it")

local result = collector:sample(context, nil)
assert(result.status == "ok", "the minimum GPU shape was not accepted: " .. tostring(result.status))
assert(result.quality == "estimated",
    "a card whose identity could not be read must be marked estimated rather "
        .. "than fresh; the result claims " .. tostring(result.quality))
assert(result.data and #result.data.devices == 1,
    "the minimum GPU shape produced " .. (result.data and #result.data.devices or 0) .. " devices")

local device = result.data.devices[1]
assert(device.identity_quality == "estimated",
    "a card with no readable device symlink has no BDF, and the device says "
        .. "its identity is " .. tostring(device.identity_quality))

-- The page has to build from it.  A collector that tolerates a minimal card is
-- not the same as a program that can show it, and the second is what a user
-- with a headless GPU meets.
local models = ViewModel.build(engine, snapshot_for(result), translator, {}, "gpu")
assert(models.gpu_table ~= nil, "the GPU page produced no table at all")
assert(type(models.gpu_table.rows) == "table",
    "the GPU page table has no rows field")
assert(#models.gpu_table.rows == 1,
    "the minimum GPU produced " .. #models.gpu_table.rows .. " rows instead of 1")
local row = models.gpu_table.rows[1]
for _, field in ipairs({ "gpu", "vendor", "driver", "utilization", "temperature",
                         "power", "fan", "frequency", "memory", "pcie" }) do
    assert(type(row[field]) == "string",
        "the GPU row field " .. field .. " is " .. type(row[field]) ..
            " on a card that publishes nothing; a row missing a field is a row "
            .. "the renderer has to special-case, and this card is the shape "
            .. "every headless iGPU and every VM passthrough-less host has")
end

-- Every metric the card does not publish has to read as absent, never as zero.
-- A driver that has nothing to say is the same situation as a driver that was
-- never loaded, and the project has already settled which of those is a value.
-- A zero here would be read as 0 degrees or 0 watts, which is a measurement
-- rather than a missing one, and nothing on the page would say otherwise.
for _, field in ipairs({ "temperature", "power", "fan", "utilization" }) do
    assert(row[field] ~= "0" and row[field] ~= "0.0" and row[field] ~= "0 W"
        and row[field] ~= "0.0 W" and row[field] ~= "0 C",
        "a card that publishes no " .. field .. " reported it as " .. row[field] ..
            "; an absent reading drawn as a number is a number nobody measured")
end

-- ---------------------------------------------------------------------------
-- 3. A host with a GPU must not need a vendor library.  The three providers
--    are optional by construction here, and the device still appears, which is
--    the claim that "generic DRM is sufficient" rests on.  Asserting it here
--    rather than in prose is what keeps the sentence in docs/MONITORING.md
--    true if someone later makes a provider load-bearing by accident.

assert(device ~= nil, "the minimum device disappeared between the two checks")
local providers = result.data.providers
assert(type(providers) == "table",
    "the result does not report which vendor providers were consulted, so "
        .. "\"no vendor API is required\" has nothing behind it")

-- All three are absent, and each says why by name rather than being omitted.
-- The device is in the result anyway, which is the claim: a vendor library adds
-- fields to a card generic DRM already found, and its absence removes fields
-- rather than the card.  An omitted provider and an absent one would look the
-- same here, and the difference matters -- an omitted provider is a bug in the
-- provider plumbing, not a fact about the host.
for _, provider in ipairs({ "nvml", "amdsmi", "levelzero" }) do
    local entry = providers[provider]
    assert(type(entry) == "table",
        "the providers table has no " .. provider .. " entry at all; an absent "
            .. "provider and an unavailable one must be told apart, or a bug in "
            .. "the provider plumbing reads as a fact about the host")
    assert(entry.status == "unavailable",
        provider .. " reports " .. tostring(entry.status) .. " on a host with no "
            .. "vendor library installed, and a fixture filesystem has no host "
            .. "to load one from")
    assert(type(entry.reason) == "string" and entry.reason ~= "",
        provider .. " is unavailable without saying why")
end
assert(#result.data.devices == 1,
    "the device is gone now that all three vendor providers are known to be "
        .. "unavailable, which is what would make a vendor API load-bearing")

-- ---------------------------------------------------------------------------
-- 4. Not a GPU defect, found by asking the no-GPU question with the smallest
--    snapshot that can represent it.
--
--    The snapshot a host with no GPU produces is also the snapshot a host with
--    no device inventory produces: `Snapshot.new` pre-populates every resource
--    key as an empty table, and a collector that reports unavailable leaves it
--    that way.  So the two populations are the same machines -- a container, a
--    VM, a host whose PCI enumeration is not readable -- which is exactly where
--    a GPU is least likely to be present.
--
--    `system_device_rows` read `#pci.devices or 0` and `usb.devices` as if the
--    trailing `or 0` guarded the field.  It does not: the length is taken before
--    `or` can fall through, so an absent `devices` raises rather than counting
--    zero, and the whole system page failed to build.  The loop two lines below
--    used the guarded form, and that inconsistency was the tell.

local bare = ViewModel.build(engine, {
  cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, processes = {},
  cpu_frequency = {}, mounts = {}, workloads = {}, connections = {},
  sensors = { devices = {} }, inventory = {}, quality = {},
}, translator, {}, "system")
assert(bare.system_devices ~= nil,
    "the system page could not be built from a snapshot whose inventory is "
        .. "empty, which is what every host without a readable PCI enumeration "
        .. "produces")
assert(type(bare.system_devices.rows) == "table" and #bare.system_devices.rows == 0,
    "a host with no device inventory should show an empty device table, not "
        .. "fail to build the page")
assert(bare.system_devices.status_text:find("PCI 0", 1, true) ~= nil
    and bare.system_devices.status_text:find("USB 0", 1, true) ~= nil,
    "an empty inventory should count zero devices, and the status line says "
        .. tostring(bare.system_devices.status_text))
assert(type(bare.system_devices.empty_text) == "string"
    and bare.system_devices.empty_text ~= "",
    "an empty device table must say so.  A blank panel on the system page reads "
        .. "as a page that failed to load rather than as a host with no PCI "
        .. "devices, and those need different things done about them.")

return true
