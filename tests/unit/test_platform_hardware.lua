package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

-- Hardware sources beyond the core resources: Windows service hosts and
-- macOS coalitions as workloads, IOReport-style energy counters, disk
-- service time, per-core time classes, and the NVML provider. Fake native
-- modules and a fake NVML stand in for the libraries.
local Portable = require("wtop.collectors.portable")
local NVML = require("wtop.collectors.nvml")
local GPU = require("wtop.collectors.gpu")
local Fixture = require("support.fixture_fs")
local I18n = require("wtop.i18n")
local ViewModel = require("wtop.view_model")

local function close(actual, expected, tolerance, message)
    assert(type(actual) == "number", message .. ": expected a number, got " .. tostring(actual))
    assert(math.abs(actual - expected) <= tolerance,
        string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function equal(actual, expected, message)
    assert(actual == expected,
        string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function queued(values)
    local index = 0
    return function()
        index = index + 1
        return values[math.min(index, #values)]
    end
end

local function collector(id, method, values)
    return Portable.new_all({ common = { native = { [method] = queued(values) } } })[id]
end

local function at(nanoseconds)
    return { now_ns = function() return nanoseconds end }
end

-- ---------------------------------------------------------------------------
-- Workloads: cumulative CPU and I/O become rates; the root sums its hosts.
-- ---------------------------------------------------------------------------

local function services(cpu_a, cpu_b, read_a)
    return {
        kind = "service",
        running_services = 3,
        workloads = {
            { id = "services", name = "Services", depth = 0,
              processes = { count = 2 }, memory = { current_bytes = 300 } },
            { id = "service:10:1", name = "Dnscache, LanmanWorkstation", depth = 1,
              processes = { count = 1 }, memory = { current_bytes = 100 },
              raw_cpu = { usage_ns = cpu_a }, raw_io = { rbytes = read_a, wbytes = 0 } },
            { id = "service:20:1", name = "Audiosrv", depth = 1,
              processes = { count = 1 }, memory = { current_bytes = 200 },
              raw_cpu = { usage_ns = cpu_b }, raw_io = { rbytes = 0, wbytes = 0 } },
        },
    }
end

local workloads = collector("cgroup", "collect_cgroup", {
    services(0, 0, 0),
    services(500000000, 2000000000, 4096),
})
local first = workloads:sample(at(0))
equal(first.status, "ok", "first service sample")
equal(first.quality, "gap", "the first sample has no rates")
equal(first.data.summary.root.cpu_utilization_percent, nil, "no root rate without a baseline")
local second = workloads:sample(at(1000000000), first)
equal(second.quality, "fresh", "second service sample")
local rows = second.data.workloads
equal(rows[1].id, "services", "the root stays first")
equal(rows[2].name, "Audiosrv", "hosts sort busiest first")
close(rows[2].cpu.utilization_percent, 200, 0.001, "two seconds of CPU per second is 200%")
close(rows[3].cpu.utilization_percent, 50, 0.001, "half a core")
close(rows[3].io.totals.rates.rbytes_per_second, 4096, 0.001, "read rate")
close(second.data.summary.root.cpu_utilization_percent, 250, 0.001, "root sums its hosts")
equal(second.data.summary.node_count, 3, "root and both hosts are nodes")
equal(second.data.summary.visible_process_count, 2, "process count comes from hosts")

-- A counter that moves backwards is a restarted host, not negative CPU.
local restarted = collector("cgroup", "collect_cgroup", {
    services(900, 0, 0), services(100, 0, 0),
})
local before = restarted:sample(at(0))
local after = restarted:sample(at(1000000000), before)
local host = after.data.workloads[2].id == "service:10:1" and after.data.workloads[2]
    or after.data.workloads[3]
equal(host.cpu.utilization_percent, nil, "a reset counter has no rate")
equal(host.quality, "gap", "a reset host is a gap")
equal(after.data.summary.root.cpu_utilization_percent, nil,
    "the root total is unknown while a host has no rate")

-- The ViewModel names what Windows actually groups.
local translator = assert(I18n.new({ locale = "en-US" }))
local engine = { history_values = function() return {} end }
local function model_for(snapshot_workloads)
    return ViewModel.build(engine, {
        cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, processes = {},
        cpu_frequency = {}, mounts = {}, connections = {}, sensors = {}, gpus = {},
        quality = {}, workloads = snapshot_workloads,
    }, translator, {}, "workloads")
end
local service_model = model_for(second.data)
equal(service_model.workload_table.panel_title, "Windows services",
    "service workloads have their own title")
local labels = {}
for _, row in ipairs(service_model.workload_detail.entries) do
    if row.label_id then labels[row.label_id] = row.value end
end
equal(labels["workloads.service_hosts"], 2, "service hosts exclude the root row")
equal(labels["workloads.running_services"], 3, "running services come from the SCM")
local linux_model = model_for({ summary = { node_count = 4, root = {} }, workloads = {} })
equal(linux_model.workload_table.panel_title, nil, "cgroup titles stay unchanged")

-- ---------------------------------------------------------------------------
-- Energy counters become power, like the RAPL collector.
-- ---------------------------------------------------------------------------

local function zones(cpu, gpu)
    return { zones = {
        { id = "cpu", name = "CPU", aggregate = true, energy_joules = cpu },
        { id = "gpu", name = "GPU", aggregate = false, energy_joules = gpu },
        { id = "system", name = "System total", power_watts = 7.5 },
    } }
end
local energy = collector("powercap", "collect_powercap", {
    zones(10, 5), zones(12.5, 5.5), zones(1, 6),
})
local energy_first = energy:sample(at(0))
equal(energy_first.quality, "gap", "power needs two energy readings")
equal(energy_first.data.zones[1].power_watts, nil, "no first-sample power")
equal(energy_first.data.zones[3].power_watts, 7.5, "a direct reading is kept")
local energy_second = energy:sample(at(500000000), energy_first)
close(energy_second.data.zones[1].power_watts, 5, 1e-9, "2.5 J in 0.5 s is 5 W")
close(energy_second.data.zones[2].power_watts, 1, 1e-9, "0.5 J in 0.5 s is 1 W")
close(energy_second.data.total_power_watts, 5, 1e-9, "the aggregate zone is the CPU total")
local energy_reset = energy:sample(at(1000000000), energy_second)
equal(energy_reset.data.zones[1].power_watts, nil, "a counter reset has no power")
equal(energy_reset.data.zones[1].power_quality, "reset", "reset is reported")

-- ---------------------------------------------------------------------------
-- Disk busy time from summed service time is an estimate.
-- ---------------------------------------------------------------------------

local function disk(service_ns)
    return { devices = { { id = "disk0", name = "disk0", counters = {
        bytes_read = 0, bytes_written = 0, reads = 0, writes = 0,
        service_time_ns = service_ns,
    } } } }
end
local disks = collector("disk", "collect_disk", { disk(0), disk(250000000), disk(5000000000) })
local disk_first = disks:sample(at(0))
local disk_second = disks:sample(at(1000000000), disk_first)
close(disk_second.data.devices[1].busy_percent, 25, 1e-9, "250 ms of service per second")
equal(disk_second.data.devices[1].busy_quality, "estimated", "service time is an estimate")
local disk_third = disks:sample(at(2000000000), disk_second)
equal(disk_third.data.devices[1].busy_percent, 100, "overlapping requests are capped")

-- ---------------------------------------------------------------------------
-- Per-core time classes are optional.
-- ---------------------------------------------------------------------------

local function cpu(user, system)
    return { raw = { busy = user + system, total = 1000 + user + system }, cores = {
        { name = "cpu0", raw = { busy = user + system, total = 1000 + user + system,
            user = user, system = system } },
        { name = "cpu1", raw = { busy = user, total = 1000 + user } },
    } }
end
local cpus = collector("cpu", "collect_cpu", { cpu(0, 0), cpu(300, 100) })
local cpu_first = cpus:sample(at(0))
local cpu_second = cpus:sample(at(1000000000), cpu_first)
close(cpu_second.data.cores[1].user, 75, 1e-9, "user share of the interval")
close(cpu_second.data.cores[1].system, 25, 1e-9, "system share")
equal(cpu_second.data.cores[2].system, nil, "a core without the class has no value")

-- ---------------------------------------------------------------------------
-- Sockets read without permission for every process are partial.
-- ---------------------------------------------------------------------------

local sockets = collector("connections", "collect_connections", { {
    owners_available = true, denied_processes = 12,
    connections = { { protocol = "tcp", family = "ipv4", local_address = "127.0.0.1",
        local_port = 631, remote_address = "0.0.0.0", remote_port = 0, tcp_state = 2,
        pid = 90, owner_name = "cupsd" } },
} }):sample(at(1))
equal(sockets.quality, "partial", "unreadable processes make the table partial")
equal(sockets.data.owner_scan.partial, true, "owner scan reports the gap")
equal(sockets.data.owner_scan.denied, 12, "and how many processes were unreadable")

-- ---------------------------------------------------------------------------
-- NVML.
-- ---------------------------------------------------------------------------

equal(NVML.normalize_bdf("0000000F:01:00.0"), "000f:01:00.0", "NVML's eight-digit domain")
equal(NVML.normalize_bdf("0000:3B:00.0"), "0000:3b:00.0", "lowercase hex")
equal(NVML.normalize_bdf("garbage"), nil, "a malformed bus ID is rejected")
local failed, failed_reason = NVML.query(function() error("boom") end)
equal(failed, nil, "a raising provider is contained")
equal(failed_reason, "nvml_query_failed", "and reported")
local missing, missing_reason = NVML.query(function() return nil, "nvml_library_not_found" end)
equal(missing, nil, "an absent library yields no data")
equal(missing_reason, "nvml_library_not_found", "with the provider's reason")

local nvml_data = {
    driver_version = "580.159.03",
    devices = {
        { index = 0, name = "NVIDIA GB10", uuid = "GPU-5f7e", pci_bdf = "0000000F:01:00.0",
          vendor_id = "0x10de", device_id = "0x2e12", utilization_percent = 37,
          memory_utilization_percent = 4, temperature_celsius = 46, power_watts = 10.5,
          graphics_clock_hz = 2411000000, graphics_clock_maximum_hz = 3003000000,
          performance_state = "P0",
          processes = { { pid = 4242, kind = "compute", memory_bytes = 1303363584,
              sm_percent = 35, encoder_percent = 0, decoder_percent = 0 } } },
        { index = 1, name = "NVIDIA A100", uuid = "GPU-a100", pci_bdf = "00000000:3B:00.0",
          vendor_id = "0x10de", device_id = "0x20b0", memory_total_bytes = 80 * 2^30,
          memory_used_bytes = 2^30 },
    },
}
local drm_device = { id = "000f:01:00.0", card = "card1", pci_bdf = "000f:01:00.0",
    driver = "nvidia", metrics = { temperature_celsius = 50 }, capabilities = {},
    processes = { list = {}, by_id = {}, summary = {} } }
local devices = { drm_device }
local lookup = { by_bdf = { ["000f:01:00.0"] = drm_device } }
local status = NVML.merge(devices, lookup, nvml_data, {
    used_ids = { ["000f:01:00.0"] = true },
    include_processes = true,
    process_name = function(pid) return pid == 4242 and "trainer" or nil end,
})
equal(status.merged_devices, 1, "one NVML device joins its DRM node")
equal(status.added_devices, 1, "one NVML device has no DRM node")
equal(#devices, 2, "the unmatched GPU is appended")
equal(drm_device.metrics.utilization_percent, 37, "NVML fills utilization")
equal(drm_device.metrics.utilization_source, "nvml", "and names its source")
equal(drm_device.metrics.temperature_celsius, 50, "a DRM value keeps precedence")
equal(drm_device.metrics.frequency_current_hz, 2411000000, "graphics clock")
equal(drm_device.model_name, "NVIDIA GB10", "the NVML name fills a missing model")
equal(drm_device.vendor_uuid, "GPU-5f7e", "vendor UUID")
equal(drm_device.driver_version, "580.159.03", "driver version")
local process = drm_device.processes.list[1]
equal(process.pid, 4242, "NVML processes fill an empty fdinfo table")
equal(process.name, "trainer", "names come from the process table")
equal(process.memory_summary.resident_bytes, 1303363584, "per-process GPU memory")
equal(process.engines.sm.utilization_percent, 35, "SM share")
equal(process.engines.encoder, nil, "idle engines are omitted")
local added = devices[2]
equal(added.id, "0000:3b:00.0", "an added device is keyed by its bus address")
equal(added.metrics.memory_total_bytes, 80 * 2^30, "added device memory")
equal(added.source, "nvml", "added device source")

-- fdinfo rows, where present, are not replaced.
local fdinfo_device = { id = "x", metrics = {}, capabilities = {},
    processes = { list = { { pid = 1, id = "1:1" } }, summary = {} } }
NVML.merge({ fdinfo_device }, { by_bdf = { ["000f:01:00.0"] = fdinfo_device } },
    nvml_data, { include_processes = true })
equal(#fdinfo_device.processes.list, 1, "fdinfo process rows stay")

-- The collector: a fixture DRM tree plus an injected provider.
local card = "/sys/class/drm/card1"
local nvidia_tree = {
    files = {
        [card .. "/dev"] = "226:1\n",
        [card .. "/uevent"] = "MAJOR=226\nMINOR=1\nDEVNAME=dri/card1\n",
        [card .. "/device/vendor"] = "0x10de\n",
        [card .. "/device/device"] = "0x2e12\n",
        [card .. "/device/class"] = "0x030000\n",
    },
    links = {
        [card] = "../../devices/pci000f:00/000f:00:00.0/000f:01:00.0/drm/card1",
        [card .. "/device"] = "../../../000f:01:00.0",
        [card .. "/device/driver"] = "../../../../bus/pci/drivers/nvidia",
    },
}
local provider_calls = 0
local provider = function()
    provider_calls = provider_calls + 1
    return nvml_data
end
local nvidia = GPU.new({ fs = Fixture.new(nvidia_tree), scan_processes = false, nvml = provider })
local merged = nvidia:sample({ now_ns = function() return 1 end })
equal(merged.status, "ok", "collector with NVML")
equal(merged.data.providers.nvml.status, "ok", "provider status is exported")
local merged_device = merged.data.by_id["000f:01:00.0"]
assert(merged_device, "the DRM device keeps its ID")
equal(merged_device.metrics.power_watts, 10.5, "NVML power reaches the DRM device")
equal(#merged.data.devices, 2, "the second NVML GPU is listed")

local safe = nvidia:sample({ now_ns = function() return 2 end, safe_mode = true })
equal(safe.data.providers.nvml.reason, "safe_mode", "safe mode skips the vendor library")
equal(#safe.data.devices, 1, "only DRM devices in safe mode")

local headless = GPU.new({ fs = Fixture.new({ dirs = { ["/sys/class/drm"] = {} } }),
    scan_processes = false, nvml = provider })
equal(headless:probe({}).state, "available", "NVML alone makes the collector available")
local headless_sample = headless:sample({ now_ns = function() return 3 end })
equal(headless_sample.status, "ok", "a host without DRM nodes still lists NVML GPUs")
equal(#headless_sample.data.devices, 2, "both NVML GPUs")

-- A fixture filesystem never reaches the host's library.
local fixture_only = GPU.new({ fs = Fixture.new(nvidia_tree), scan_processes = false })
equal(#fixture_only:sample({ now_ns = function() return 4 end }).data.devices, 1,
    "no host NVML with a fixture filesystem")
assert(provider_calls >= 3, "the injected provider was used")

return true
