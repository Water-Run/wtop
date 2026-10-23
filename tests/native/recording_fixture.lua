local Recording = require("wtop.recording")
local Snapshot = require("wtop.model.snapshot")
local file = assert(io.open(assert(arg[1]), "wb"))
local writer = Recording.writer({ write=function(s) return file:write(s) end,
    metadata={ platform="Linux", interval_ms=1000, version="0.2.0", host={sysname="Linux",nodename="recorded-fixture"},
        privilege={mode="user",root=false,requested=false}, capabilities={} } })
for n = 1, 3 do
    local snapshot = Snapshot.new(n, n * 1000000000)
    snapshot.cpu = { total={utilization=n * 10}, logical_cpus=1 }
    snapshot.memory = { total_bytes=8589934592, used_bytes=2147483648 }
    snapshot.system = { host={hostname="recorded-fixture",architecture="x86_64"} }
    snapshot.processes = { list={ {id="4242:1",pid=4242,starttime_ticks=1,name="recorded-demo",command="recorded-demo",
        state="S",cpu_percent=1,resident_bytes=1024,threads=1} }, total=1 }
    local zone = { id="intel-rapl:0", name="package-0", source_kind="intel-rapl", aggregate_domain="cpu_package",
        enabled=true, control_enabled=true, controls_enabled=true, power_watts=n == 1 and 10 or 18,
        power_quality="measured", quality="fresh", observed_at_ns=snapshot.timestamp_ns,
        power_interval_ns=1000000000, constraints={ {id=0,name="long_term",power_limit_watts=20} } }
    snapshot.power = { zones={zone}, total_power_watts=zone.power_watts }
    for _, key in ipairs({"cpu","memory","system","processes","power"}) do
        snapshot.quality[key] = {status="ok",quality="fresh",timestamp_ns=snapshot.timestamp_ns,
            value_timestamp_ns=snapshot.timestamp_ns}
    end
    if n == 3 then snapshot.quality.power.status="error";snapshot.quality.power.quality="stale" end
    if arg[2] == "health" then
        local alarm = n ~= 2
        snapshot.cpu.total.utilization = alarm and 98 or 20
        snapshot.memory.used_bytes = snapshot.memory.total_bytes * (alarm and 0.96 or 0.4)
        snapshot.sensors = { devices = { { id="demo-sensor", name="demo-sensor", channels={
            { id="temperature:1", label="CPU package", type="temperature", unit="celsius",
                input=alarm and 101 or 60, quality="fresh", thresholds={crit=100}, alarm=alarm },
            { id="fan:1", label="Fan input", type="fan", unit="rpm",
                quality="fresh", fault=alarm },
        } } } }
        snapshot.mounts = { mounts = { { id="demo-volume", mount_point="/recorded-data",
            kind="local", quality="fresh", capacity={used_percent=alarm and 99 or 40} } } }
        snapshot.inventory = { pci={devices={ {address="0000:00:01.0",aer={fatal={
            change={quality="fresh",new_reports=alarm and 1 or 0} } } } }} }
        for _, key in ipairs({"sensors","mounts","inventory"}) do
            snapshot.quality[key] = {status="ok",quality="fresh",timestamp_ns=snapshot.timestamp_ns,
                value_timestamp_ns=snapshot.timestamp_ns}
        end
        if n == 3 then
            for _, key in ipairs({"sensors","memory","mounts","inventory"}) do
                snapshot.quality[key].quality="stale"
                snapshot.quality[key].value_timestamp_ns=1000000000
            end
            snapshot.quality.cpu.status="error";snapshot.quality.cpu.quality="stale"
            snapshot.quality.cpu.value_timestamp_ns=1000000000
        end
    end
    writer:append(snapshot, snapshot.timestamp_ns, 1700000000000000000 + snapshot.timestamp_ns)
end
writer:close(); assert(file:close())
