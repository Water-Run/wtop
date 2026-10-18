package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local O = require("wtop.collectors.gpu_observations")
local GPU = require("wtop.collectors.gpu")
local Windows = require("wtop.collectors.windows_gpu")
local Input = require("wtop.collectors.gpu_drm")
local Fixture = require("support.fixture_fs")
local Hardware = require("support.hardware_fixtures")
local BDF, OTHER = "0000:01:00.0", "0000:02:00.0"
local function packet(at, watts, both)
    local d = { sample_started_ns = at, sample_finished_ns = at, devices = {
        { index = 0, pci_bdf = BDF, uuid = "GPU-A", name = "GPU A", power_watts = watts,
            power_quality = "fresh", vendor_id = "0x10de", device_id = "0x1234" },
    } }
    if both then d.devices[2] = { index = 1, pci_bdf = OTHER, uuid = "GPU-B", name = "GPU B",
        power_watts = 50, power_quality = "fresh" } end
    return d
end
local function target(bdf)
    return { id = bdf, pci_bdf = bdf, observations = { nvml = { quality = "fresh" } } }
end
local now, fs = 1e9, {}
local o = O.new()
local function begin() o:begin(fs, now, false) end
local function row(anchors)
    local d = target(BDF);o:publish_power_sessions({ d }, anchors, now)
    return d.power_sessions[1]
end
begin()
local old = { [BDF] = "instance1" }
local data = packet(now, 30)
assert(o:observe("nvml", data, old, now))
assert(row(old).current_watts == 30)
now = 2e9;begin()
assert(o:observe("nvml", data, old, now) and row(old).samples == 1)
local new = { [BDF] = "instance2" }
assert(not o:observe("nvml", data, new, now), "cached packet rebound to another instance")
assert(not row(new))
o:apply("nvml", {}, { by_bdf = {} }, {}, new, now, "nvml_query_pending")
assert(#o.sources.nvml.records == 0)
assert(not o:observe("nvml", data, new, now), "pruning history forgot the packet's binding")
assert(data.status == nil and #data.devices == 1 and data.devices[1].power_watts == 30)

-- A newer prefetched SDK packet can still predate the observed replacement.
o:inventory_frame(old, 1e9, true)
o:inventory_frame(new, now, true)
assert(not o:observe("nvml", packet(1.5e9, 90), new, now))
local unknown = packet(nil, 90)
assert(not o:observe("nvml", unknown, new, now))
assert(o:observe("nvml", packet(now, 40), new, now))
assert(row(new).samples == 1 and row(new).current_watts == 40)
assert(not o:observe("nvml", packet(1e9, 99), new, now), "out-of-order packet became current")
assert(not o:observe("nvml", packet(3e9, 99), new, now), "future packet became current")
assert(row(new).samples == 1 and row(new).current_watts == 40)

-- Filter only the affected device; a cached healthy sibling keeps its own
-- clock and sample count. A partial inventory is not a confirmed removal.
o = O.new();now = 10e9;begin()
old = { [BDF] = "a", [OTHER] = "b" }
data = packet(now, 30, true)
o:inventory_frame(old, now, true)
assert(o:observe("nvml", data, old, now))
now = 11e9;begin()
o:inventory_frame({}, now, false)
assert(o:observe("nvml", data, old, now))
new = { [BDF] = "replacement", [OTHER] = "b" }
o:inventory_frame(new, now, true)
local filtered = assert(o:observe("nvml", data, new, now))
assert(filtered ~= data and filtered.status == "partial" and #filtered.devices == 1)
assert(filtered.devices[1].pci_bdf == OTHER and #data.devices == 2 and not data.status)
local a, b = target(BDF), target(OTHER)
o:apply("nvml", { a, b }, { by_bdf = { [BDF] = a, [OTHER] = b } }, {}, new, now)
o:publish_power_sessions({ a, b }, new, now)
assert(#a.power_sessions == 0 and b.power_sessions[1].samples == 1)
assert(b.power_sessions[1].current_watts == 50)

-- Complete disappearance and reuse of exactly the same anchor still require
-- a post-reappearance capture. Ordinary failed inventory does not do this.
now = 12e9;begin();o:inventory_frame({}, now, true)
o:apply("nvml", {}, { by_bdf = {} }, {}, {}, now)
now = 13e9;begin();o:inventory_frame(old, now, true)
assert(not o:observe("nvml", packet(12.5e9, 99), old, now))
assert(o:observe("nvml", packet(now, 7), old, now))
assert(row(old).samples == 1 and row(old).current_watts == 7)

-- Headless UUIDs remain useful, but an old headless batch cannot attach to a
-- newly observed DRM instance or silently change UUID within one capture.
o = O.new();now = 20e9;begin()
data = packet(now, 10)
assert(o:observe("nvml", data, {}, now))
local contradictory = packet(now, 90);contradictory.devices[1].uuid = "GPU-new"
assert(not o:observe("nvml", contradictory, {}, now))
o:inventory_frame({ [BDF] = "first DRM" }, now, true)
assert(not o:observe("nvml", data, { [BDF] = "first DRM" }, now))
now = 21e9;begin()
assert(o:observe("nvml", packet(now, 20), { [BDF] = "first DRM" }, now))
now = 1e9;begin()
assert(o:observe("nvml", packet(now, 5), {}, now), "clock reset retained a future packet fence")
o:clear();assert(next(o.sources) == nil and next(o.inventory) == nil)

for _,source in ipairs({ "nvml", "amdsmi", "levelzero", "adl" }) do
    o = O.new();now = 30e9;begin()
    data = packet(now, 30);data.devices[1].identity_verified = true
    local ready = assert(o:observe(source, data, old, now))
    assert(#o.sources[source].records == 1, source)
    assert(not o:observe(source, data, new, now), source .. " rebound a cached packet")
    now = 31e9;begin()
    assert(o:observe(source, packet(now, 40), new, now))
    -- An invalid list element is a partial provider reply, not an exception.
    local malformed = packet(now, 40);malformed.devices[2] = false
    ready = assert(o:observe(source, malformed, new, now))
    assert(#ready.devices == 1 and ready.status == "partial")
    o:begin(fs, now, true)
    assert(next(o.sources) == nil and next(o.inventory) == nil)
end

-- Bounded tombstones can be evicted without allowing an old packet to bind
-- when an evicted address is rediscovered. Active entries are not evicted.
o = O.new();now = 40e9;begin()
local many = {}
for i=1,4096 do many["slot" .. i] = "instance" end
o:inventory_frame(many, now, true)
local count = 0;for _ in pairs(o.inventory) do count=count+1 end;assert(count == 4096)
now = 41e9;begin();o:inventory_frame({}, now, true)
now = 42e9;begin();o:inventory_frame({ [BDF] = "new" }, now, true)
count = 0;for _ in pairs(o.inventory) do count=count+1 end;assert(count == 4096)
assert(o.inventory_evicted and not o:observe("nvml", packet(41e9, 90), { [BDF] = "new" }, now))
assert(o:observe("nvml", packet(now, 10), { [BDF] = "new" }, now))
o:begin({}, now, false)
assert(next(o.inventory) == nil and not o.inventory_evicted and next(o.sources) == nil)

-- Linux's actual compose stage must filter before the SDK writes metrics,
-- including its short SDK cache and a later prefetched old observation.
do
    local at, captured, watts, instance = 1e9, 1e9, 30, "first"
    local spec = Hardware.drm_amdgpu()
    spec.dirs = { ["/sys/class/drm"] = { "card0" }, ["/proc"] = {} }
    local fixture = Fixture.new(spec)
    local context = { fs = fixture, now_ns = function() return at end, scan_gpu_processes = false }
    local raw = Input.new({ fs = fixture, scan_processes = false }):sample(context)
    local gpu = GPU.new({ fs = fixture, scan_processes = false, nvml = false, levelzero = false,
        amdsmi = function()
            local p = packet(captured, watts);p.devices[1].vendor_id = "0x1002"
            p.devices[1].device_id = nil;return p
        end })
    gpu._drm_worker = {
        sample = function()
            local r = assert(O.copy(raw));r.timestamp_ns, r.value_timestamp_ns = at, at
            local d = r.data.devices[1]
            d.device_target = instance
            d.metrics.power_watts, d.metrics.power_limit_watts = nil, nil
            r.data.anchors = O.anchors(r.data.devices)
            return r
        end,
        prepare = function() end, restore = function() end, metadata = function() return {} end,
        close = function() end,
    }
    local first = gpu:sample(context)
    assert(first.data.devices[1].metrics.power_watts == 30)
    at, instance = 1.05e9, "replacement"
    local cached = gpu:sample(context, first)
    assert(cached.data.devices[1].metrics.power_watts == nil and #cached.data.devices[1].power_sessions == 0)
    at, captured = 1.2e9, 1.025e9
    local prefetch = gpu:sample(context, cached)
    assert(prefetch.data.devices[1].metrics.power_watts == nil)
    at, captured, watts = 1.4e9, 1.4e9, 40
    local recovered = gpu:sample(context, prefetch).data.devices[1]
    assert(recovered.metrics.power_watts == 40 and recovered.power_sessions[1].samples == 1)
    gpu:stop()
end

-- Windows caches its inventory separately; a cached SDK batch must also be
-- checked against a new native inventory before either metrics or statistics.
do
    local at, captured, watts, driver = 1e9, 1e9, 30, "first"
    local base = { probe = function() return { available = true } end }
    function base:sample()
        return { status = "ok", timestamp_ns = at, value_timestamp_ns = at, data = { devices = {
            { id = BDF, pci_bdf = BDF, vendor_id = "0x10de", device_id = "0x1234", driver = driver,
                identity_quality = "fresh", metrics = {}, quality = {}, capabilities = {} },
        } } }
    end
    local gpu = Windows.new(base, { nvml_provider = function() return packet(captured, watts) end,
        levelzero_provider = false, adl_provider = false }, {})
    local context = { now_ns = function() return at end, scan_gpu_processes = false }
    assert(gpu:sample(context).data.devices[1].metrics.power_watts == 30)
    at, driver = 1.05e9, "replacement"
    local cached = gpu:sample(context).data.devices[1]
    assert(cached.metrics.power_watts == nil and #cached.power_sessions == 0)
    at, captured = 1.2e9, 1.025e9
    assert(gpu:sample(context).data.devices[1].metrics.power_watts == nil)
    at, captured, watts = 1.4e9, 1.4e9, 40
    local recovered = gpu:sample(context).data.devices[1]
    assert(recovered.metrics.power_watts == 40 and recovered.power_sessions[1].samples == 1)
    at, captured, watts = 1.6e9, 1.3e9, 99
    local older = gpu:sample(context).data.devices[1]
    assert(older.metrics.power_watts == 40 and older.quality.power == "stale")
    assert(older.power_sessions[1].samples == 1 and older.power_sessions[1].current_watts == nil)
    assert(older.metric_observations.power_watts.observed_at_ns == 1.4e9)
    at, captured, watts = 1.8e9, 1.8e9, 50
    local resumed = gpu:sample(context).data.devices[1]
    assert(resumed.metrics.power_watts == 50 and resumed.power_sessions[1].samples == 2)
    assert(resumed.power_sessions[1].average_watts == 45)
    gpu:close()
end
-- The receive clock advances while a provider or native inventory is queried.
-- Compare capture times at receipt, rather than against the sample's start.
do
    local at = 1e9
    local base = { probe = function() return { available = true } end,
        sample = function() return { status = "unavailable" } end }
    local gpu = Windows.new(base, { nvml_provider = function()
        at = at + 2e6
        return packet(at, 30)
    end, levelzero_provider = false, adl_provider = false }, {})
    local result = gpu:sample({ now_ns = function() return at end })
    assert(result.status == "ok" and result.data.devices[1].metrics.power_watts == 30,
        "a query completed after sample start was mistaken for future data")
    assert(result.timestamp_ns == at and result.data.devices[1].power_sessions[1].last_timestamp_ns == at)
    gpu:close()

    local phase = "first"
    at = 10e9
    function base:sample()
        at = at + 1e6
        return { status = "ok", timestamp_ns = at, value_timestamp_ns = at, data = { devices = {
            { id = BDF, pci_bdf = BDF, vendor_id = "0x10de", device_id = "0x1234",
                driver = phase == "first" and "instance1" or "instance2", identity_quality = "fresh",
                metrics = {}, quality = {}, capabilities = {} },
        } } }
    end
    gpu = Windows.new(base, { nvml_provider = function()
        at = at + 1e6
        return packet(phase == "prefetch" and 11e9 + .5e6 or at, phase == "prefetch" and 99 or 40)
    end, levelzero_provider = false, adl_provider = false }, {})
    local context = { now_ns = function() return at end }
    assert(gpu:sample(context).data.devices[1].metrics.power_watts == 40)
    at, phase = 11e9, "prefetch"
    local replaced = gpu:sample(context).data.devices[1]
    assert(replaced.metrics.power_watts == nil and #replaced.power_sessions == 0,
        "inventory completion was clamped back to sample start, admitting older prefetched watts")
    at, phase = 12e9, "recovered"
    local recovered = gpu:sample(context).data.devices[1]
    assert(recovered.metrics.power_watts == 40 and recovered.power_sessions[1].samples == 1)
    gpu:close()
end
print("ok: GPU packet bindings, inventory replacement/removal, capture/receive clocks, prefetch fences and Linux/Windows compose")
