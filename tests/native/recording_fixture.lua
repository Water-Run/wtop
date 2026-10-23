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
        if n == 2 then
            -- Finite retained rates are still visible in the historical
            -- measurement, but must not create current health warnings.
            snapshot.cpu.total = { utilization=99, iowait=30, quality="held" }
            snapshot.disks = { devices={ { name="retained-disk", busy_percent=100, busy_quality="reset" } } }
            snapshot.gpus = { devices={ { id="retained-gpu", metrics={utilization_percent=100},
                metric_observations={utilization_percent={quality="missing"}} } } }
            for _, key in ipairs({"disks","gpus"}) do
                snapshot.quality[key] = {status="ok",quality="fresh",timestamp_ns=snapshot.timestamp_ns,
                    value_timestamp_ns=snapshot.timestamp_ns}
            end
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
    if arg[2] == "gpu-pcie" then
        local metrics={utilization_percent=25,pcie_current_generation=3,pcie_current_width=8,
            pcie_maximum_generation=4,pcie_maximum_width=16,pcie_tx_kilobytes_per_second=12345,
            pcie_rx_kilobytes_per_second=0,pcie_throughput_interval_ns=20000000,pcie_source="nvml"}
        local observations={}
        for key in pairs(metrics)do observations[key]={source="nvml",quality="fresh",observed_at_ns=math.min(n,2)*1000000000}end
        if n==2 then observations.pcie_tx_kilobytes_per_second={source="nvml",quality="stale",retained=true,observed_at_ns=1e9}end
        snapshot.gpus={devices={{id="card0",card="card0",model_name="Recorded PCIe GPU",identity_quality="fresh",
            metrics=metrics,quality={pcie="fresh"},metric_observations=observations}}}
        snapshot.quality.gpus={status=n==3 and"error"or"ok",quality=n==3 and"stale"or"fresh",
            timestamp_ns=snapshot.timestamp_ns,value_timestamp_ns=n==3 and 2e9 or snapshot.timestamp_ns}
    end
    if arg[2] == "runtime-pm" then
        local observed = math.min(n,2)*1000000000
        local pm = {status="ok",source="/sys/bus/pci/devices/0000:00:02.0",runtime_status="suspended",
            pci_state=n==1 and"D0"or"D3cold",control="auto",active_time_ms=4294967297,
            suspended_time_ms=17000+math.min(n,2)*1000,autosuspend_delay_ms=-1,d3cold_allowed=n~=1,
            capture_started_ns=observed-1000000,capture_finished_ns=observed,observed_at_ns=observed,errors={}}
        snapshot.inventory={pci={devices={{address="0000:00:02.0",vendor_id=0x8086,device_id=0x1234,
            class_id=0x030000,revision=1,vendor_name="Recorded PCI",device_name="PM demo",runtime_pm=pm}}},
            usb={devices={{id="1-2",vendor_id=0x8087,product_id=0x26,bus=1,device=3,product="USB PM demo",
                runtime_pm={status="ok",source="/sys/bus/usb/devices/1-2",runtime_status="active",control="on",
                    active_time_ms=24000,suspended_time_ms=0,capture_started_ns=observed-1000000,
                    capture_finished_ns=observed,observed_at_ns=observed,errors={}}}}}}
        snapshot.quality.inventory={status=n==3 and"error"or"ok",quality=n==3 and"stale"or"fresh",
            timestamp_ns=snapshot.timestamp_ns,value_timestamp_ns=observed}
    end
    writer:append(snapshot, snapshot.timestamp_ns, 1700000000000000000 + snapshot.timestamp_ns)
end
writer:close(); assert(file:close())
