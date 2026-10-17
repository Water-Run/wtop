package.path = "./src/?.lua;./src/?/init.lua;" .. package.path
local Wire = require("wtop.core.worker_wire")
local Snapshot = require("wtop.model.snapshot")

local original = { minimum = math.mininteger, maximum = math.maxinteger,
    fraction = 12.25, binary = "a\0b\255", enabled = false,
    counters = { [0] = 10, [8] = 22, [-1] = "offline" }, empty = {} }
local copy = Wire.decode(Wire.encode(original))
assert(copy.minimum == math.mininteger and copy.maximum == math.maxinteger)
assert(copy.fraction == 12.25 and copy.binary == original.binary and copy.enabled == false)
assert(copy.counters[0] == 10 and copy.counters[8] == 22 and copy.counters[-1] == "offline")
assert(next(copy.empty) == nil)
local cyclic = {}; cyclic.self = cyclic
for _, value in ipairs({ cyclic, setmetatable({}, {}), { callback = function() end }, { value = math.huge } }) do
    assert(not pcall(Wire.encode, value))
end
local nested = {}; local tail = nested
for _ = 1, Wire.MAX_DEPTH + 1 do tail.child = {}; tail = tail.child end
assert(not pcall(Wire.encode, nested))
for _, data in ipairs({ "", "s", "x", "zextra", "s" .. string.pack("<I4", 0xffffffff),
    "m" .. string.pack("<I4", 0xffffffff), "d" .. string.pack("<d", 0/0),
    "m" .. string.pack("<I4", 1) .. "tt",
    "m" .. string.pack("<I4", 1) .. "s" .. string.pack("<I4", 1) .. "az",
    "m" .. string.pack("<I4", 2) .. "i" .. string.pack("<i8", 0) .. "t" .. "i" .. string.pack("<i8", 0) .. "f" }) do
    assert(not pcall(Wire.decode, data), "malformed worker frame accepted")
end
local data = Wire.encode(original)
for i = 0, #data - 1 do assert(not pcall(Wire.decode, data:sub(1, i))) end

local actual = package.loaded["wtop.native"]
local now, response, closes, opens = 100, nil, 0, 0
local fake = { available = true,
    hardware_worker_open = function(id, bytes)
        assert(id == "powercap" and next(Wire.decode(bytes)) == nil)
        opens = opens + 1; return {}
    end,
    hardware_worker_query = function(_, safe)
        if response then
            return Wire.encode(response), { sample_started_ns = 80, sample_finished_ns = 95 }
        end
        return nil, "hardware_query_pending"
    end,
    hardware_worker_close = function(_, wait) assert(wait == 0); closes = closes + 1 end,
}
package.loaded["wtop.native"] = fake
package.loaded["wtop.collectors.hardware_worker"] = nil
local Hardware = require("wtop.collectors.hardware_worker")
assert(Hardware.available())
local proxy = Hardware.new({ id = "powercap", default_interval_ms = 1000 })
local context = { now_ns = function() return now end }
assert(proxy:probe(context).reason == "hardware_query_pending")
assert(proxy:sample(context).sampling_pending)
response = { capability = { state = "available", available = true },
    result = { status = "ok", quality = "fresh", timestamp_ns = 90,
        data = { total_power_watts = 12.5, zones = {} } } }
local fresh = proxy:sample(context)
assert(fresh.timestamp_ns == 100 and fresh.value_timestamp_ns == 90)
local snapshot = Snapshot.merge(Snapshot.new(0, 0), { powercap = fresh }, 1, now)
local old = snapshot.power
response, now = nil, 110
local pending = proxy:sample(context)
assert(pending.status == "error" and pending.quality == "stale" and pending.sampling_pending)
snapshot = Snapshot.merge(snapshot, { powercap = pending }, 2, now)
assert(snapshot.power == old and snapshot.power.total_power_watts == 12.5)
assert(snapshot.quality.power.quality == "stale" and snapshot.quality.power.value_timestamp_ns == 90)
-- Probing must not discard the first counter sample. A safe-mode change must
-- discard an unconsumed reply from the old worker and cancel that lease.
response = { capability = { state = "available", available = true },
    result = { status = "ok", quality = "fresh", timestamp_ns = 90, data = {} } }
assert(proxy:probe(context).available)
response = nil; context.safe_mode = true
assert(proxy:sample(context).sampling_pending and closes == 1 and opens == 2)
proxy:close(); assert(closes == 2)
assert(proxy:sample(context).reason == "hardware_worker_closed" and opens == 2)
package.loaded["wtop.native"] = actual
package.loaded["wtop.collectors.hardware_worker"] = nil
-- A short normal IPC round trip must neither erase a valid row nor add a
-- fabricated history gap. A sustained pending read must become visibly stale.
local Engine = require("wtop.engine")
now = 100
local stage = 0
local engine = Engine.new({ clock = { now_ns = function() return now end,
    wall_ns = function() return now end }, collectors = {
    powercap = { id = "powercap", default_interval_ms = 1000, sample = function()
        stage = stage + 1
        if stage == 1 then return fresh end
        return { status = "error", quality = "stale", reason = "hardware_query_pending",
            sampling_pending = true, defer_publish = stage == 2, retry_after_ms = 25,
            timestamp_ns = now }
    end },
} })
engine:tick(true)
assert(engine.history.cpu_power:newest().timestamp_ns == 90)
now = 110; local before = engine.snapshot
engine:tick(true)
assert(engine.snapshot == before and engine:has_pending_samples())
assert(engine.history.cpu_power:len() == 1 and engine.snapshot.quality.power.quality == "fresh")
now = 120; engine:tick(true)
assert(engine.snapshot.quality.power.quality == "stale"
    and engine.snapshot.quality.power.value_timestamp_ns == 90)
assert(engine.history.cpu_power:newest().value == false)
engine:stop()
local ViewModel = require("wtop.view_model")
local translator = assert(require("wtop.i18n").new({ locale = "en-US" }))
local state = {
    sensors = { devices = {{ id="chip", name="chip", channels={{ id="temp:1", type="temperature",
        index=1, label="chip temperature", input=99, quality="fresh", alarm=true }} }} },
    cpu_frequency = { policies={{ id="policy0", affected_cpus={0}, quality="fresh",
        frequencies={current_hz=1200000000,current_quality="fresh"} }} },
    cpuidle = { cpus={{ id=0, states={{ id=0, name="C1", usage_delta=10, new_time_us=1000,
        time_delta_quality="fresh",usage_delta_quality="fresh" }} }} },
    thermal_throttle = { cpus={{ id=0, core_new=4,package_new=3,core_count=10,package_count=20 }} },
    quality = {},
}
for _, resource in ipairs({"sensors","cpu_frequency","cpuidle","thermal_throttle"}) do
    state.quality[resource]={status="error",quality="stale"}
end
local models=ViewModel.build({history_values=function() return {} end},state,translator,{},"compute")
assert(models.sensor_table.rows[1].status=="stale" and not models.sensor_table.rows[1].alarm)
assert(models.cpufreq_table.rows[1].quality=="stale")
assert(models.cpuidle_table.rows[1].quality=="stale" and models.cpuidle_table.rows[1].usage_delta=="—")
assert(models.thermal_throttle_table.rows[1].core_new=="—")

local SmbiosWorker = require("wtop.collectors.smbios_worker")
local SMBIOS = require("wtop.format.smbios")
local function record(kind, handle, body, strings)
    return string.char(kind, 4 + #body) .. string.pack("<I2", handle) .. body
        .. table.concat(strings or {}, "\0") .. "\0\0"
end
local blob = record(10, 0x1000, "\133\1", {"Ethernet"})
    .. record(8, 0x0800, "\1\0\2\18\16", {"Internal", "USB"})
    .. record(127, 0xffff, "")
local reads, parses, stops, mode = 0, 0, 0, "fresh"
local parser = SMBIOS.parse
SMBIOS.parse = function(...) parses = parses + 1; return parser(...) end
local shared = SmbiosWorker.new({reader={ sample=function()
    reads = reads + 1
    if mode ~= "fresh" then return {status="error",quality="stale",timestamp_ns=now,
        reason=mode,sampling_pending=mode=="hardware_query_pending",retry_after_ms=25,
        defer_publish=mode=="hardware_query_pending"} end
    return {status="ok",quality="fresh",timestamp_ns=now,value_timestamp_ns=80,
        transport="process",sample_started_ns=70,sample_finished_ns=90,
        data={data=blob,source="/sys/firmware/dmi/tables/DMI"}}
end, close=function() stops=stops+1 end}})
local forbidden = {read=function() error("parent must not read firmware files") end}
local onboard = shared:wrap(require("wtop.collectors.onboard_devices").new({platform="linux",fs=forbidden}))
local ports = shared:wrap(require("wtop.collectors.port_connectors").new({platform="linux",fs=forbidden}))
local ctx = {now_ns=function() return now end,_collector_batch={}}
now = 100
assert(onboard:probe(ctx).available and ports:probe(ctx).available)
assert(reads==1 and parses==1, "one raw input and parse per batch")
ctx._collector_batch = {}
local first_onboard, first_ports = onboard:sample(ctx), ports:sample(ctx)
assert(reads==1 and parses==1, "probing must retain the first complete results")
assert(first_onboard.status=="ok" and first_ports.status=="ok")
assert(first_onboard.value_timestamp_ns==80 and first_ports.value_timestamp_ns==80)
assert(first_onboard.timestamp_ns==100 and first_onboard.capability.available)
assert(first_onboard.data~=first_ports.data, "each view owns its parsed records")
local firmware_snapshot=Snapshot.merge(Snapshot.new(0,0),{onboard_devices=first_onboard},1,now)
mode = "hardware_query_pending"; now = 200; ctx._collector_batch = {}
local pending_onboard, pending_ports = onboard:sample(ctx), ports:sample(ctx)
assert(reads==2 and parses==1 and pending_onboard.sampling_pending and pending_ports.sampling_pending)
assert(pending_onboard~=pending_ports and pending_onboard.capability~=pending_ports.capability)
assert(pending_onboard.defer_publish and not pending_onboard.capability.available)
firmware_snapshot=Snapshot.merge(firmware_snapshot,{onboard_devices=pending_onboard},2,now)
assert(firmware_snapshot.quality.onboard_devices.value_timestamp_ns==80
    and firmware_snapshot.quality.onboard_devices.quality=="stale")
mode = "hardware_query_timeout"; ctx._collector_batch = {}
assert(onboard:sample(ctx).reason==mode and ports:sample(ctx).reason==mode)
assert(reads==3 and parses==1)
mode = "fresh"; ctx._collector_batch = {}
assert(onboard:sample(ctx).status=="ok" and ports:sample(ctx).status=="ok")
assert(reads==4 and parses==2)
-- The parser cache must follow the input provider as well as its filesystem.
-- Different shared readers can appear alongside explicit collector injections.
ctx._collector_batch = {}
local a=onboard:sample(ctx)
local second = SmbiosWorker.new({reader={sample=function()
    return {status="ok",quality="fresh",timestamp_ns=now,value_timestamp_ns=85,
        data={data=blob:gsub("Ethernet","OtherBoard"),source="second/DMI"}}
end,close=function() end}})
local second_onboard=second:wrap(require("wtop.collectors.onboard_devices").new({platform="linux",fs=forbidden}))
local other=second_onboard:sample(ctx)
assert(a.data.devices[1].designation=="Ethernet" and other.data.devices[1].designation=="OtherBoard",
    "different raw input readers shared the first reader's parsed table")
assert(other.value_timestamp_ns==85 and other.source=="second/DMI")
second:close()
onboard:close(); assert(stops==0 and onboard:sample(ctx).reason=="hardware_worker_closed")
shared:close(); shared:close(); ctx._collector_batch = {}
assert(stops==1 and ports:sample(ctx).reason=="hardware_worker_closed")
SMBIOS.parse = parser
local cleanup = {first=false,second=false}
local closing_engine=Engine.new({collectors={},clock={now_ns=function() return now end,
    wall_ns=function() return now end}})
closing_engine.hardware_inputs={
    first={close=function() cleanup.first=true;error("failed close") end},
    second={close=function() cleanup.second=true end},
}
closing_engine:stop()
assert(cleanup.first and cleanup.second,"one failed input cleanup prevented another from closing")

-- Portable sources select the advertised process transport, including GPU,
-- without calling a synchronous native API on pending/error paths.
local Portable = require("wtop.collectors.portable")
local slots, portable_closes, pending_energy = {}, 0, false
local transport = {available=true,hardware_worker_sources={powercap=true,cpufreq=true,gpu=true,hwmon=true,network=true}}
for _,id in ipairs({"powercap","cpufreq","gpu","hwmon","network"}) do
    transport["collect_"..id]=function() error("parent entered a synchronous hardware API") end
end
transport.hardware_worker_open=function(id,configuration)
    assert(not slots[id] and next(Wire.decode(configuration))==nil)
    local slot={id=id};slots[id]=slot;return slot
end
transport.hardware_worker_query=function(slot,_,wait)
    assert(wait==0)
    if slot.id=="powercap" and pending_energy then return nil,"hardware_query_pending" end
    return Wire.encode({capability={available=true,state="available"},result={status="ok",
        quality="fresh",timestamp_ns=90,data={source=slot.id}}}),
        {sample_started_ns=80,sample_finished_ns=95}
end
transport.hardware_worker_close=function(slot,wait)
    assert(wait==0 and slots[slot.id]==slot);portable_closes=portable_closes+1
end
local portable_readers={};now=100
for _,id in ipairs({"powercap","cpufreq","gpu","hwmon","network"}) do
    local collector=Portable.new(id,{native=transport});portable_readers[id]=collector
    assert(collector:probe(context).available)
    local result=collector:sample(context)
    assert(result.data.source==id and result.transport=="process" and result.value_timestamp_ns==90)
end
pending_energy=true
assert(portable_readers.powercap:sample(context).sampling_pending)
assert(portable_readers.cpufreq:sample(context).data.source=="cpufreq")
assert(portable_readers.gpu:sample(context).data.source=="gpu")
for _,collector in pairs(portable_readers) do collector:close() end
assert(portable_closes==5)
local direct_calls=0
local direct=Portable.new("powercap",{native={collect_powercap=function()
    direct_calls=direct_calls+1;return {zones={}}
end}})
assert(direct:sample(context).status=="ok" and direct_calls==1,
    "a backend without an advertised worker changed its collection path")
local broken=Portable.new("powercap",{native={available=true,hardware_worker_sources={powercap=true},
    collect_powercap=function()error("missing transport fell back into parent")end}})
assert(broken:sample(context).reason=="hardware_worker_unavailable")
broken:close()

-- Derivation stays inside each reader: actual native sample windows, epoch
-- changes and a new reader's warmup cannot reuse the terminal's prior data.
local prior_native, prior_core=package.loaded["wtop.native"],package.loaded["wtop.core.hardware_worker"]
local child_now,energy,epoch=1000000000,10,"epoch-A"
local child_native={available=true,uname=function() return {sysname="Darwin"} end,
    monotonic_ns=function() return child_now end,realtime_ns=function() return child_now end,
    collect_powercap=function() return {zones={{id="cpu",aggregate=true,energy_joules=energy,
        _source_epoch=epoch,_sample_timestamp_ns=child_now}}} end}
package.loaded["wtop.native"]=child_native;package.loaded["wtop.core.hardware_worker"]=nil
local create_reader=require("wtop.core.hardware_worker")
local child=create_reader("powercap",Wire.encode({}))
assert(Wire.decode(child(false)).result.data.zones[1].power_watts==nil)
child_now,energy=3000000000,22
local watts=Wire.decode(child(false)).result.data.zones[1]
assert(watts.power_watts==6 and watts.power_interval_ns==2000000000)
child_now,energy,epoch=4000000000,0,"epoch-B"
assert(Wire.decode(child(false)).result.data.zones[1].power_watts==nil)
child_now,energy=5000000000,3
assert(Wire.decode(child(false)).result.data.zones[1].power_watts==3)
local restarted=create_reader("powercap",Wire.encode({}))
assert(Wire.decode(restarted(false)).result.data.zones[1].power_watts==nil)
local temperature=40
child_native.collect_hwmon=function()return {devices={{id="hid:chip",name="chip",class="hid",source="iohid",
    quality="fresh",identity_quality="fresh",_source_epoch="hid-epoch",channels={{id="ioreg:100",
    _source_instance="ioreg:100",type="temperature",unit="celsius",label="Core",quality="fresh",
    identity_quality="fresh",input=temperature}}}}}end
local sensors=create_reader("hwmon",Wire.encode({}))
child_now=6000000000
local sensor_first=Wire.decode(sensors(false)).result.data.devices[1].channels[1]
assert(sensor_first.session.samples==1 and sensor_first.session.minimum==40)
child_now,temperature=7000000000,50
local sensor_second=Wire.decode(sensors(false)).result.data.devices[1].channels[1]
assert(sensor_second.session.samples==2 and sensor_second.session.minimum==40
    and sensor_second.session.maximum==50 and sensor_second.session.average==45)
local new_sensors=create_reader("hwmon",Wire.encode({}))
local new_sensor=Wire.decode(new_sensors(false)).result.data.devices[1].channels[1]
assert(new_sensor.session.samples==1 and new_sensor.session.minimum==50 and new_sensor.session.maximum==50,
    "a new sensor reader reused another reader's session statistics")
local received,network_identity=1000,"ioreg:network-A"
child_native.collect_network=function()return {interfaces={{id="en0",name="en0",ifindex=1,
    _registry_entry_id=network_identity,counter_bits=64,counters={rx_bytes=received,tx_bytes=received*2}}}}end
local network=create_reader("network",Wire.encode({}))
child_now=8000000000
assert(Wire.decode(network(false)).result.data.interfaces[1].rx_bytes_per_second==nil)
child_now,received=9000000000,1600
local network_second=Wire.decode(network(false)).result.data.interfaces[1]
assert(network_second.rx_bytes_per_second==600 and network_second.tx_bytes_per_second==1200)
child_now,received,network_identity=10000000000,2200,"ioreg:network-B"
assert(Wire.decode(network(false)).result.data.interfaces[1].rx_bytes_per_second==nil,
    "changed registry identity reused old interface counters")
child_now,received=11000000000,2500
assert(Wire.decode(network(false)).result.data.interfaces[1].rx_bytes_per_second==300)
local new_network=create_reader("network",Wire.encode({}))
assert(Wire.decode(new_network(false)).result.data.interfaces[1].rx_bytes_per_second==nil,
    "a new network reader reused another reader's rate baseline")
package.loaded["wtop.native"],package.loaded["wtop.core.hardware_worker"]=prior_native,prior_core

-- Default construction is a different path from an injected collector set.
-- A portable backend's own proxies must not enter the Linux sysfs/SMBIOS
-- wrapping pass, even when it exposes the shared process transport API.
local saved={}
for _,name in ipairs({"wtop.native","wtop.collectors","wtop.collectors.hardware_worker","wtop.engine"})do
    saved[name]=package.loaded[name]
end
local sysname,wrapped="Darwin",0
local sensor={id="hwmon",default_interval_ms=1000,sample=function()end}
package.loaded["wtop.native"]={available=true,uname=function()return {sysname=sysname}end,
    monotonic_ns=function()return 1000000000 end,realtime_ns=function()return 1000000000 end}
package.loaded["wtop.collectors"]={new_all=function()return {hwmon=sensor}end}
package.loaded["wtop.collectors.hardware_worker"]={sources={hwmon=true},available=function()return true end,
    new=function(collector)wrapped=wrapped+1;return {id=collector.id,default_interval_ms=1000,sample=function()end}end}
package.loaded["wtop.engine"]=nil
local DefaultEngine=require("wtop.engine")
for _,platform in ipairs({"Darwin","Windows"})do
    sysname=platform
    local instance=DefaultEngine.new()
    assert(instance.collectors.hwmon==sensor and next(instance.hardware_inputs)==nil and wrapped==0,
        "portable default engine replaced a sensor with a Linux-only reader")
    instance:stop()
end
sysname="Linux"
local linux_instance=DefaultEngine.new()
assert(wrapped==1 and linux_instance.collectors.hwmon~=sensor,"Linux lost its default isolated reader")
linux_instance:stop()
for name,value in pairs(saved)do package.loaded[name]=value end

do
    local old_native = package.loaded["wtop.native"]
    local old_proxy = package.loaded["wtop.collectors.hardware_worker"]
    local clock, opens, closes, available_reply = 100, 0, 0, true
    local fake_native = { available = true }
    function fake_native.hardware_worker_open(id, configuration)
        assert(id == "spd" or id == "hwmon")
        assert(next(Wire.decode(configuration)) == nil)
        opens = opens + 1
        return { id = id, generation = opens }
    end
    function fake_native.hardware_worker_query(session, _, wait)
        assert(wait == 0 and not session.closed)
        if not available_reply then return nil, "hardware_query_pending" end
        return Wire.encode({ capability = { available = true, state = "available" },
            result = { status = "ok", quality = "fresh", timestamp_ns = clock - 10,
                data = { devices = { { id = "dimm", size_bytes = 17179869184 } } } } }),
            { sample_started_ns = clock - 20, sample_finished_ns = clock - 5 }
    end
    function fake_native.hardware_worker_close(session, wait)
        assert(wait == 0 and not session.closed)
        session.closed = true
        closes = closes + 1
    end
    package.loaded["wtop.native"] = fake_native
    package.loaded["wtop.collectors.hardware_worker"] = nil
    local Proxy = require("wtop.collectors.hardware_worker")
    assert(Proxy.sources.spd)
    local collector = Proxy.new({ id = "spd", default_interval_ms = 60000 })
    local context = { now_ns = function() return clock end }
    assert(collector:probe(context).available)
    assert(opens == 1 and closes == 1, "completed SPD probe kept its reader alive")
    local first = collector:sample(context)
    assert(first.value_timestamp_ns == 90 and first.data.devices[1].size_bytes == 17179869184)
    assert(opens == 1 and closes == 1, "first public observation repeated the completed probe")
    local snapshot = Snapshot.merge(Snapshot.new(0, 0), { spd = first }, 1, clock)
    clock, available_reply = 300000000, false
    local pending = collector:sample(context)
    assert(pending.sampling_pending and opens == 2 and closes == 1)
    clock = clock + 150000000
    pending = collector:sample(context)
    assert(pending.sampling_pending and not pending.defer_publish and opens == 2 and closes == 1)
    snapshot = Snapshot.merge(snapshot, { spd = pending }, 2, clock)
    assert(snapshot.spd.devices[1].size_bytes == 17179869184)
    assert(snapshot.quality.spd.quality == "stale" and snapshot.quality.spd.value_timestamp_ns == 90)
    available_reply = true
    local recovered = collector:sample(context)
    assert(recovered.value_timestamp_ns == clock - 10 and opens == 2 and closes == 2)
    collector:close()
    assert(closes == 2 and collector:sample(context).reason == "hardware_worker_closed")
    -- Counter-bearing/continuous sources keep their previous process lifetime.
    local continuous = Proxy.new({ id = "hwmon", default_interval_ms = 1000 })
    assert(continuous:sample(context).status == "ok")
    assert(opens == 3 and closes == 2)
    assert(continuous:sample(context).status == "ok" and opens == 3 and closes == 2)
    continuous:close()
    assert(closes == 3)
    package.loaded["wtop.native"] = old_native
    package.loaded["wtop.collectors.hardware_worker"] = old_proxy
end

return true
