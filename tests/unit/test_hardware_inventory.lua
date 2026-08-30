package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local CPUInfo = require("wtop.collectors.cpu_info")
local Export = require("wtop.export")
local Powercap = require("wtop.collectors.powercap")
local Snapshot = require("wtop.model.snapshot")

local function fake_fs(files, directories)
    local fs = {}
    function fs:read(path, limit)
        local value = files[path]
        if type(value) == "table" and value.kind then return nil, value end
        if value == nil then
            return nil, { kind = "missing", message = "fixture_missing", path = path }
        end
        assert(type(limit) == "number" and limit > 0)
        if #value > limit then
            return nil, { kind = "too_large", message = "fixture_too_large", path = path }
        end
        return value
    end
    function fs:list(path, limit)
        local source = directories[path]
        if type(source) == "table" and source.kind then return nil, source end
        if source == nil then
            return nil, { kind = "missing", message = "fixture_missing", path = path }
        end
        local result = {}
        for index = 1, math.min(#source, limit or #source) do result[index] = source[index] end
        table.sort(result)
        return result, nil, limit ~= nil and #source > limit
    end
    return fs
end

local function by_id(values, id)
    for _, value in ipairs(values or {}) do
        if value.id == id then return value end
    end
end

local function issue_by_field(issues, field)
    for _, issue in ipairs(issues or {}) do
        if issue.field == field then return issue end
    end
end

local function near(actual, expected, epsilon)
    assert(type(actual) == "number", "expected a numeric value")
    assert(math.abs(actual - expected) <= (epsilon or 1e-9),
        tostring(actual) .. " ~= " .. tostring(expected))
end

local cpu_files = {
    ["/proc/cpuinfo"] = table.concat({
        "processor : 0",
        "model name : Cortex-A55",
        "CPU implementer : 0x41",
        "CPU architecture : 8",
        "CPU variant : 0x0",
        "CPU part : 0xd05",
        "CPU revision : 0",
        "Features : fp asimd aes sha1 aes",
        "",
        "processor : 1",
        "model name : Cortex-A76",
        "CPU implementer : 0x41",
        "CPU architecture : 8",
        "CPU part : 0xd0b",
        "Features : fp asimd aes sha1",
        "",
    }, "\n"),
    ["/sys/devices/system/cpu/online"] = "0-1\n",
    ["/sys/devices/system/cpu/present"] = "0-1\n",
    ["/sys/devices/system/cpu/possible"] = "0-3\n",
}
local cpu_directories = {
    ["/sys/devices/system/cpu"] = { "cpu0", "cpu1", "online", "present", "possible" },
}
for cpu = 0, 1 do
    local topology = "/sys/devices/system/cpu/cpu" .. cpu .. "/topology"
    cpu_files[topology .. "/physical_package_id"] = "0\n"
    cpu_files[topology .. "/core_id"] = tostring(cpu) .. "\n"
    cpu_files[topology .. "/core_type"] = tostring(cpu + 1) .. "\n"
    cpu_files[topology .. "/thread_siblings_list"] = tostring(cpu) .. "\n"
    cpu_files["/sys/devices/system/cpu/cpu" .. cpu .. "/cpu_capacity"]
        = tostring(cpu == 0 and 512 or 1024) .. "\n"
    cpu_files["/sys/devices/system/cpu/cpu" .. cpu .. "/cpufreq/cpuinfo_max_freq"]
        = tostring(cpu == 0 and 1800000 or 2800000) .. "\n"
    local cache = "/sys/devices/system/cpu/cpu" .. cpu .. "/cache"
    cpu_directories[cache] = { "index1", "index0", "uevent" }
    cpu_files[cache .. "/index0/level"] = "1\n"
    cpu_files[cache .. "/index0/id"] = tostring(cpu) .. "\n"
    cpu_files[cache .. "/index0/type"] = "Data\n"
    cpu_files[cache .. "/index0/size"] = "32K\n"
    cpu_files[cache .. "/index0/shared_cpu_list"] = tostring(cpu) .. "\n"
    cpu_files[cache .. "/index0/coherency_line_size"] = "64\n"
    cpu_files[cache .. "/index0/ways_of_associativity"] = "4\n"
    cpu_files[cache .. "/index0/number_of_sets"] = "128\n"
    cpu_files[cache .. "/index0/physical_line_partition"] = "1\n"
    cpu_files[cache .. "/index1/level"] = "2\n"
    cpu_files[cache .. "/index1/id"] = "7\n"
    cpu_files[cache .. "/index1/type"] = "Unified\n"
    cpu_files[cache .. "/index1/size"] = "512K\n"
    cpu_files[cache .. "/index1/shared_cpu_list"] = "0-1\n"
    cpu_files[cache .. "/index1/coherency_line_size"] = "64\n"
    cpu_files[cache .. "/index1/ways_of_associativity"] = "8\n"
    cpu_files[cache .. "/index1/number_of_sets"] = "1024\n"
end

local cpu_collector = CPUInfo.new({ fs = fake_fs(cpu_files, cpu_directories) })
local cpu_result = cpu_collector:sample({ now_ns = function() return 100 end })
assert(cpu_result.status == "ok" and cpu_result.quality == "fresh")
assert(cpu_result.data.identity.vendor == "Arm Limited")
assert(cpu_result.data.identity.model_name == "Cortex-A55")
assert(cpu_result.data.identity.architecture == "8")
assert(cpu_result.data.identity.flags_count == 4)
assert(cpu_result.data.identity.heterogeneous)
assert(cpu_result.data.identity.core_type_count == 2)
assert(#cpu_result.data.core_types == 2)
assert(cpu_result.data.core_types[1].model_name == "Cortex-A55")
assert(cpu_result.data.core_types[1].part == "0xd05")
assert(cpu_result.data.core_types[1].cpu_capacity == 512)
assert(cpu_result.data.core_types[1].kernel_core_type == 1)
assert(cpu_result.data.core_types[1].threads_per_core == 1)
assert(cpu_result.data.core_types[1].maximum_frequency_hz == 1800000000)
assert(cpu_result.data.core_types[1].physical_core_count == 1)
assert(cpu_result.data.core_types[1].logical_cpu_ids[1] == 0)
assert(cpu_result.data.core_types[2].model_name == "Cortex-A76")
assert(cpu_result.data.core_types[2].part == "0xd0b")
assert(cpu_result.data.core_types[2].cpu_capacity == 1024)
assert(cpu_result.data.core_types[2].kernel_core_type == 2)
assert(cpu_result.data.core_types[2].threads_per_core == 1)
assert(cpu_result.data.core_types[2].maximum_frequency_hz == 2800000000)
assert(cpu_result.data.core_types[2].physical_core_count == 1)
assert(cpu_result.data.topology.logical_cpus[1].core_type_id == "type-1")
assert(cpu_result.data.topology.logical_cpus[2].core_type_id == "type-2")
assert(cpu_result.data.topology.logical_cpus[1].threads_in_core == 1)
assert(cpu_result.data.topology.logical_cpus[2].maximum_frequency_hz == 2800000000)
assert(cpu_result.data.topology.sockets == 1)
assert(cpu_result.data.topology.physical_cores == 2)
assert(cpu_result.data.topology.threads == 2)
assert(cpu_result.data.topology.online_threads == 2)
assert(#cpu_result.data.caches == 3,
    "a cache shared by both logical CPUs must have one inventory record")
assert(cpu_result.data.cache_summary[1].instances == 2)
assert(cpu_result.data.cache_summary[1].total_size_bytes == 65536)
assert(cpu_result.data.cache_summary[1].minimum_size_bytes == 32768)
assert(cpu_result.data.cache_summary[1].maximum_size_bytes == 32768)
assert(cpu_result.data.cache_summary[2].instances == 1)
assert(cpu_result.data.cache_summary[2].total_size_bytes == 512 * 1024)
assert(cpu_result.data.caches[1].physical_line_partition == 1)
assert(cpu_result.data.caches[1].cache_id == 0)
local shared_l2
for _, cache in ipairs(cpu_result.data.caches) do
    if cache.level == 2 then shared_l2 = cache end
end
assert(shared_l2 and shared_l2.cache_id == 7)
assert(shared_l2.shared_cpu_list_text == "0-1")
assert(cpu_result.data.topology.logical_cpus[1].thread_siblings[1] == 0)
assert(cpu_result.data.topology.possible_cpu_list[4] == 3)
assert(CPUInfo.cache_size_bytes("24M") == 24 * 1024 * 1024)
assert(CPUInfo.cache_size_bytes("2kb") == 2048)
assert(CPUInfo.cache_size_bytes("3GB") == 3 * 1024 * 1024 * 1024)
assert(CPUInfo.cache_size_bytes("128") == 128)
assert(CPUInfo.cache_size_bytes("bad") == nil)
assert(CPUInfo.cache_size_bytes("1.5M") == nil)
assert(CPUInfo.cache_size_bytes("999999999999999999999G") == nil)
assert(#assert(CPUInfo.parse_cpu_list("0-2,4", 8, 16)) == 4)
assert(table.concat(assert(CPUInfo.parse_cpu_list("4,0-2,2,1", 8, 16)), ",") == "0,1,2,4")
assert(CPUInfo.parse_cpu_list("4-2", 8, 16) == nil)
assert(CPUInfo.parse_cpu_list("0-8", 8, 16) == nil)
assert(CPUInfo.parse_cpu_list("0,17", 8, 16) == nil)
assert(CPUInfo.parse_cpu_list("0,bad", 8, 16) == nil)

local parsed_sections, _, parsed_truncated = CPUInfo.parse_cpuinfo(table.concat({
    "processor : 0\r",
    "vendor_id : first\r",
    "vendor_id : ignored duplicate\r",
    "malformed line\r",
    "\r",
    "processor : 1\r",
    "vendor_id : second\r",
    "\r",
}, "\n"), 1)
assert(#parsed_sections == 1 and parsed_truncated)
assert(parsed_sections[1].vendor_id == "first",
    "duplicate cpuinfo fields must not overwrite the first kernel value")
local no_sections, no_sections_error = CPUInfo.parse_cpuinfo("comments without fields\n", 8)
assert(no_sections == nil and no_sections_error == "no_cpuinfo_sections")
assert(CPUInfo.parse_cpuinfo(nil, 8) == nil)

local flags_limited = CPUInfo.new({
    fs = fake_fs(cpu_files, cpu_directories),
    max_flags = 2,
}):sample({ now_ns = function() return 101 end })
assert(flags_limited.quality == "partial" and flags_limited.data.truncated)
assert(flags_limited.data.identity.flags_count == 2)
assert(flags_limited.data.identity.flags_truncated)

local caches_limited = CPUInfo.new({
    fs = fake_fs(cpu_files, cpu_directories),
    max_caches = 1,
}):sample({ now_ns = function() return 102 end })
assert(#caches_limited.data.caches == 1 and caches_limited.data.truncated)

local core_types_limited = CPUInfo.new({
    fs = fake_fs(cpu_files, cpu_directories),
    max_core_types = 1,
}):sample({ now_ns = function() return 102 end })
assert(#core_types_limited.data.core_types == 1 and core_types_limited.data.truncated)
assert(core_types_limited.quality == "partial")

local saved_cache_size = cpu_files["/sys/devices/system/cpu/cpu0/cache/index0/size"]
cpu_files["/sys/devices/system/cpu/cpu0/cache/index0/size"] = "32.5K\n"
local malformed_cache = CPUInfo.new({
    fs = fake_fs(cpu_files, cpu_directories),
}):sample({ now_ns = function() return 103 end })
assert(malformed_cache.quality == "partial")
assert(issue_by_field(malformed_cache.data.issues, "cache.size").reason == "invalid_cache_size")
cpu_files["/sys/devices/system/cpu/cpu0/cache/index0/size"] = saved_cache_size

assert(not pcall(CPUInfo.new, "invalid"))
assert(not pcall(CPUInfo.new, { max_cpus = 0 }))
assert(not pcall(CPUInfo.new, { max_flags = math.huge }))
assert(not pcall(CPUInfo.new, { max_core_types = 0 }))
assert(not pcall(CPUInfo.new, { proc_cpuinfo_path = "relative" }))
local denied_cpu_probe = CPUInfo.new({
    fs = fake_fs({
        ["/proc/cpuinfo"] = { kind = "denied", message = "permission denied" },
    }, {}),
}):probe({})
assert(denied_cpu_probe.state == "denied" and not denied_cpu_probe.available)

-- RISC-V systems commonly identify logical CPUs by hart and may not expose
-- the x86 topology sysfs fields. The collector must retain useful identity
-- data and explicitly mark the inferred topology as estimated.
local riscv_cpuinfo = table.concat({
    "hart : 0",
    "uarch : sifive,u74-mc",
    "mvendorid : 0x489",
    "marchid : 0x8000000000000007",
    "isa : rv64imafdc_zicsr",
    "",
    "hart : 2",
    "uarch : sifive,u74-mc",
    "mvendorid : 0x489",
    "isa : rv64imafdc_zicsr",
    "",
}, "\n")
local riscv_result = CPUInfo.new({
    fs = fake_fs({ ["/proc/cpuinfo"] = riscv_cpuinfo }, {}),
}):sample({ now_ns = function() return 104 end })
assert(riscv_result.status == "ok" and riscv_result.quality == "estimated")
assert(riscv_result.data.identity.model_name == "sifive,u74-mc")
assert(riscv_result.data.identity.vendor == "0x489")
assert(riscv_result.data.identity.architecture == "rv64imafdc_zicsr")
assert(riscv_result.data.topology.threads == 2)
assert(riscv_result.data.topology.logical_cpus[2].id == 2)
assert(riscv_result.data.topology.physical_cores == 2)
assert(riscv_result.data.topology.quality == "estimated")
assert(riscv_result.data.topology.logical_cpus[1].maximum_frequency_hz == nil)
assert(riscv_result.data.topology.logical_cpus[1].kernel_core_type == nil)
assert(#riscv_result.data.issues == 0,
    "missing optional topology attributes must remain a clean fallback")

local x86_sections = {}
for cpu = 0, 3 do
    x86_sections[#x86_sections + 1] = table.concat({
        "processor : " .. cpu,
        "vendor_id : GenuineIntel",
        "model name : Example Hybrid CPU",
        "cpu family : 6",
        "model : 191",
        "stepping : 2",
        "microcode : 0x123",
        "physical id : 0",
        "core id : " .. (cpu < 2 and "0" or tostring(cpu - 1)),
        "flags : fpu sse2 avx2",
    }, "\n")
end
local x86_files = {
        ["/proc/cpuinfo"] = table.concat(x86_sections, "\n\n") .. "\n",
        ["/sys/devices/system/cpu/online"] = "0-2\n",
        ["/sys/devices/system/cpu/present"] = "0-3\n",
        ["/sys/devices/system/cpu/possible"] = "0-7\n",
        ["/sys/devices/system/cpu/isolated"] = "3\n",
}
for cpu = 0, 3 do
    if cpu ~= 3 then
        x86_files["/sys/devices/system/cpu/cpu" .. cpu .. "/cpufreq/cpuinfo_max_freq"]
            = tostring(cpu < 2 and 4700000 or 3600000) .. "\n"
    end
end
local x86_result = CPUInfo.new({
    fs = fake_fs(x86_files, {}),
}):sample({ now_ns = function() return 105 end })
assert(x86_result.data.identity.vendor == "GenuineIntel")
assert(x86_result.data.identity.family == "6" and x86_result.data.identity.model == "191")
assert(x86_result.data.identity.stepping == "2" and x86_result.data.identity.microcode == "0x123")
assert(x86_result.data.topology.sockets == 1)
assert(x86_result.data.topology.physical_cores == 3)
assert(x86_result.data.topology.threads == 4 and x86_result.data.topology.online_threads == 3)
assert(x86_result.data.topology.threads_per_core_minimum == 1)
assert(x86_result.data.topology.threads_per_core_maximum == 2)
assert(x86_result.data.topology.logical_cpus[4].online == false)
assert(x86_result.data.topology.isolated_cpu_list[1] == 3)
assert(x86_result.data.identity.heterogeneous and x86_result.data.identity.core_type_count == 2)
assert(x86_result.data.core_types[1].threads_per_core == 2)
assert(x86_result.data.core_types[1].maximum_frequency_hz == 4700000000)
assert(x86_result.data.core_types[1].physical_core_count == 1)
assert(x86_result.data.core_types[1].logical_cpu_count == 2)
assert(x86_result.data.core_types[2].threads_per_core == 1)
assert(x86_result.data.core_types[2].maximum_frequency_hz == 3600000000)
assert(x86_result.data.core_types[2].physical_core_count == 2)
assert(x86_result.data.core_types[2].logical_cpu_count == 2)
assert(x86_result.data.topology.logical_cpus[4].maximum_frequency_hz == nil,
    "an offline CPU may legitimately lack a cpufreq node")
assert(x86_result.data.topology.logical_cpus[1].cpu_capacity == nil)
assert(x86_result.data.topology.logical_cpus[1].kernel_core_type == nil)
assert(#x86_result.data.issues == 0)

local power_files = {
    ["/sys/class/powercap/intel-rapl-mmio:0/name"] = "package-0\n",
    ["/sys/class/powercap/intel-rapl:0/name"] = "package-0\n",
    ["/sys/class/powercap/intel-rapl:0/energy_uj"] = "1000000\n",
    ["/sys/class/powercap/intel-rapl:0/max_energy_range_uj"] = "10000000\n",
    ["/sys/class/powercap/intel-rapl:0/enabled"] = "1\n",
    ["/sys/class/powercap/intel-rapl:0/constraint_0_name"] = "long_term\n",
    ["/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"] = "15000000\n",
    ["/sys/class/powercap/intel-rapl:0/constraint_0_time_window_us"] = "2000000\n",
    ["/sys/class/powercap/intel-rapl:0:0/name"] = "core\n",
    ["/sys/class/powercap/intel-rapl:0:0/energy_uj"] = "500000\n",
    ["/sys/class/powercap/intel-rapl:0:0/max_energy_range_uj"] = "10000000\n",
    ["/sys/class/powercap/intel-rapl:0:0:0/name"] = "uncore\n",
    ["/sys/class/powercap/intel-rapl:0:0:0/energy_uj"] = "250000\n",
    ["/sys/class/powercap/intel-rapl:0:0:0/max_energy_range_uj"] = "10000000\n",
    ["/sys/class/powercap/intel-rapl:1/name"] = "psys\n",
    ["/sys/class/powercap/intel-rapl:1/power_uw"] = "20000000\n",
}
local power_directories = {
    ["/sys/class/powercap"] = {
        "intel-rapl", "intel-rapl-mmio:0", "intel-rapl:0", "intel-rapl:0:0",
        "intel-rapl:0:0:0", "intel-rapl:1",
    },
    ["/sys/class/powercap/intel-rapl-mmio:0"] = { "name" },
    ["/sys/class/powercap/intel-rapl:0"] = {
        "name", "energy_uj", "max_energy_range_uj", "enabled",
        "constraint_0_name", "constraint_0_power_limit_uw", "constraint_0_time_window_us",
    },
    ["/sys/class/powercap/intel-rapl:0:0"] = {
        "name", "energy_uj", "max_energy_range_uj",
    },
    ["/sys/class/powercap/intel-rapl:0:0:0"] = {
        "name", "energy_uj", "max_energy_range_uj",
    },
    ["/sys/class/powercap/intel-rapl:1"] = { "name", "power_uw" },
}
local power_collector = Powercap.new({ fs = fake_fs(power_files, power_directories) })
local first_power = power_collector:sample({ now_ns = function() return 1000000000 end })
assert(first_power.status == "ok" and first_power.data.total_power_watts == nil)
assert(first_power.data.aggregate_strategy == "cpu_package_roots")
assert(first_power.data.platform_power_watts == 20)
assert(first_power.data.measured_platform_zones == 1)
local first_package = assert(by_id(first_power.data.zones, "intel-rapl:0"))
assert(first_package.constraints[1].power_limit_watts == 15)
assert(first_package.constraints[1].time_window_seconds == 2)

power_files["/sys/class/powercap/intel-rapl:0/energy_uj"] = "3000000\n"
power_files["/sys/class/powercap/intel-rapl:0:0/energy_uj"] = "1500000\n"
power_files["/sys/class/powercap/intel-rapl:0:0:0/energy_uj"] = "750000\n"
local second_power = power_collector:sample(
    { now_ns = function() return 2000000000 end }, first_power)
assert(second_power.status == "ok")
assert(second_power.data.by_id["intel-rapl:0"].power_watts == 2)
assert(second_power.data.by_id["intel-rapl:0:0"].power_watts == 1)
assert(second_power.data.by_id["intel-rapl:0:0:0"].power_watts == 0.5)
assert(second_power.data.by_id["intel-rapl:0:0"].parent_id == "intel-rapl:0")
assert(second_power.data.by_id["intel-rapl:0:0:0"].parent_id == "intel-rapl:0:0")
assert(second_power.data.total_power_watts == 2,
    "child power domains must not be added to package power")
assert(second_power.data.aggregate_complete and second_power.data.aggregate_zone_count == 1)
assert(second_power.data.aggregate_source_kind == "intel-rapl")
assert(second_power.data.by_id["intel-rapl:0"].aggregate)
assert(second_power.data.by_id["intel-rapl:0"].aggregate_domain == "cpu_package")
assert(not second_power.data.by_id["intel-rapl:0:0"].aggregate)
assert(not second_power.data.by_id["intel-rapl:0:0:0"].aggregate)
assert(not second_power.data.by_id["intel-rapl-mmio:0"].aggregate,
    "an unreadable parallel backend must not hide measured package power")
local psys = second_power.data.by_id["intel-rapl:1"]
assert(psys.platform_aggregate and not psys.aggregate)
assert(psys.aggregate_domain == "platform")
assert(second_power.data.platform_power_watts == 20,
    "platform power must be reported separately from CPU package power")
assert(Powercap.energy_delta(2, 9, 10) == 3)
local reset_delta, reset_quality = Powercap.energy_delta(8, 9, 10)
assert(reset_delta == nil and reset_quality == "reset")

local merged = Snapshot.merge(Snapshot.new(), {
    cpu_info = cpu_result,
    powercap = second_power,
}, 1, 2000000000)
assert(merged.cpu_info.identity.model_name == "Cortex-A55")
assert(merged.power.total_power_watts == 2)
assert(merged.quality.power.status == "ok")

local exported = Export.snapshot(merged)
assert(exported.cpu_info.topology.physical_cores == 2)
assert(exported.cpu_info.identity.flags[4] == "sha1")
assert(exported.cpu_info.caches[1].size_bytes == 32768)
assert(exported.cpu_info.identity.heterogeneous)
assert(exported.cpu_info.identity.core_type_count == 2)
assert(exported.cpu_info.core_types[2].model_name == "Cortex-A76")
assert(exported.cpu_info.core_types[2].logical_cpu_ids[1] == 1)
assert(exported.cpu_info.core_types[2].threads_per_core == 1)
assert(exported.cpu_info.core_types[2].maximum_frequency_hz == 2800000000)
assert(exported.cpu_info.core_types[2].physical_core_count == 1)
assert(exported.cpu_info.topology.logical_cpus[2].core_type_id == "type-2")
assert(exported.cpu_info.topology.logical_cpus[2].threads_in_core == 1)
assert(exported.cpu_info.topology.logical_cpus[2].maximum_frequency_hz == 2800000000)
assert(exported.cpu_info.caches[1].cache_id == 0)
assert(exported.power.total_power_watts == 2)
assert(exported.power.aggregate_strategy == "cpu_package_roots")
assert(exported.power.platform_power_watts == 20)
assert(exported.power.measured_platform_zones == 1)
assert(by_id(exported.power.zones, "intel-rapl:0").constraints[1].power_limit_watts == 15)
assert(by_id(exported.power.zones, "intel-rapl:1").platform_aggregate)

-- A direct power attribute takes precedence over a derived energy rate and
-- every standardized constraint unit is converted without loss.
local direct_files = {
    ["/sys/class/powercap/vendor:0/name"] = "socket-1\n",
    ["/sys/class/powercap/vendor:0/power_uw"] = "12500000\n",
    ["/sys/class/powercap/vendor:0/energy_uj"] = "9000000\n",
    ["/sys/class/powercap/vendor:0/max_energy_range_uj"] = "10000000\n",
    ["/sys/class/powercap/vendor:0/enabled"] = "0\n",
    ["/sys/class/powercap/vendor:0/constraint_0_name"] = "sustained\n",
    ["/sys/class/powercap/vendor:0/constraint_0_power_limit_uw"] = "15000000\n",
    ["/sys/class/powercap/vendor:0/constraint_0_max_power_uw"] = "25000000\n",
    ["/sys/class/powercap/vendor:0/constraint_0_min_power_uw"] = "5000000\n",
    ["/sys/class/powercap/vendor:0/constraint_0_time_window_us"] = "2000000\n",
    ["/sys/class/powercap/vendor:0/constraint_0_max_time_window_us"] = "4000000\n",
    ["/sys/class/powercap/vendor:0/constraint_0_min_time_window_us"] = "500000\n",
    ["/sys/class/powercap/vendor:0/constraint_1_name"] = "burst\n",
    ["/sys/class/powercap/vendor:0/constraint_1_power_limit_uw"] = "30000000\n",
}
local direct_entries = {
    "name", "power_uw", "energy_uj", "max_energy_range_uj", "enabled",
    "constraint_0_name", "constraint_0_power_limit_uw", "constraint_0_max_power_uw",
    "constraint_0_min_power_uw", "constraint_0_time_window_us",
    "constraint_0_max_time_window_us", "constraint_0_min_time_window_us",
    "constraint_1_name", "constraint_1_power_limit_uw", "constraint_99_unknown",
}
local direct_directories = {
    ["/sys/class/powercap"] = { "vendor-control", "vendor:0" },
    ["/sys/class/powercap/vendor:0"] = direct_entries,
}
local direct_collector = Powercap.new({ fs = fake_fs(direct_files, direct_directories) })
local direct_first = direct_collector:sample({ now_ns = function() return 1000000000 end })
local direct_zone = assert(direct_first.data.by_id["vendor:0"])
near(direct_zone.power_watts, 12.5)
assert(direct_zone.power_source == "power_uw" and direct_zone.power_quality == "measured")
assert(direct_zone.enabled == false and direct_zone.aggregate)
assert(direct_zone.aggregate_domain == "cpu_package")
assert(direct_first.data.aggregate_strategy == "cpu_package_roots")
near(direct_first.data.total_power_watts, 12.5)
local direct_constraint = assert(direct_zone.constraints[1])
near(direct_constraint.power_limit_watts, 15)
near(direct_constraint.maximum_power_watts, 25)
near(direct_constraint.minimum_power_watts, 5)
near(direct_constraint.time_window_seconds, 2)
near(direct_constraint.maximum_time_window_seconds, 4)
near(direct_constraint.minimum_time_window_seconds, 0.5)
direct_files["/sys/class/powercap/vendor:0/energy_uj"] = "1000000\n"
local direct_second = direct_collector:sample(
    { now_ns = function() return 2000000000 end }, direct_first)
assert(direct_second.data.by_id["vendor:0"].power_source == "power_uw")
near(direct_second.data.by_id["vendor:0"].power_watts, 12.5)

local constraint_limited = Powercap.new({
    fs = fake_fs(direct_files, direct_directories),
    max_constraints_per_zone = 1,
}):sample({ now_ns = function() return 1000000000 end })
assert(#constraint_limited.data.by_id["vendor:0"].constraints == 1)
assert(constraint_limited.data.by_id["vendor:0"].truncated)
assert(constraint_limited.quality == "partial")

-- Derived energy rates distinguish monotonic deltas, counter wrap, reset and
-- physically implausible rates rather than publishing spikes.
power_files["/sys/class/powercap/intel-rapl:0/energy_uj"] = "9000000\n"
local before_wrap = power_collector:sample(
    { now_ns = function() return 3000000000 end }, second_power)
near(before_wrap.data.by_id["intel-rapl:0"].power_watts, 6)
power_files["/sys/class/powercap/intel-rapl:0/energy_uj"] = "1000000\n"
local wrapped = power_collector:sample(
    { now_ns = function() return 4000000000 end }, before_wrap)
near(wrapped.data.by_id["intel-rapl:0"].power_watts, 2)
assert(wrapped.data.by_id["intel-rapl:0"].power_quality == "wrapped")
power_files["/sys/class/powercap/intel-rapl:0/energy_uj"] = "9000000\n"
local before_reset = power_collector:sample(
    { now_ns = function() return 5000000000 end }, wrapped)
power_files["/sys/class/powercap/intel-rapl:0/energy_uj"] = "8000000\n"
local reset = power_collector:sample(
    { now_ns = function() return 6000000000 end }, before_reset)
assert(reset.data.by_id["intel-rapl:0"].power_watts == nil)
assert(reset.data.by_id["intel-rapl:0"].power_quality == "reset")
assert(reset.data.total_power_watts == nil)
assert(reset.data.platform_power_watts == 20)

local spike_files = {
    ["/sys/class/powercap/vendor:0/name"] = "package-0\n",
    ["/sys/class/powercap/vendor:0/energy_uj"] = "0\n",
}
local spike_directories = {
    ["/sys/class/powercap"] = { "vendor:0" },
    ["/sys/class/powercap/vendor:0"] = { "name", "energy_uj" },
}
local spike_collector = Powercap.new({
    fs = fake_fs(spike_files, spike_directories), max_power_watts = 10,
})
local spike_first = spike_collector:sample({ now_ns = function() return 1 end })
spike_files["/sys/class/powercap/vendor:0/energy_uj"] = "1000000\n"
local spike_second = spike_collector:sample(
    { now_ns = function() return 2 end }, spike_first)
assert(spike_second.data.by_id["vendor:0"].power_watts == nil)
assert(spike_second.data.by_id["vendor:0"].power_quality == "reset")

local denied_power_files = {
    ["/sys/class/powercap/vendor:0/name"] = "package-0\n",
    ["/sys/class/powercap/vendor:0/energy_uj"] = {
        kind = "denied", message = "permission denied",
    },
}
local denied_power_directories = {
    ["/sys/class/powercap"] = { "vendor:0" },
    ["/sys/class/powercap/vendor:0"] = { "name", "energy_uj" },
}
local denied_power = Powercap.new({
    fs = fake_fs(denied_power_files, denied_power_directories),
}):sample({ now_ns = function() return 1 end })
assert(denied_power.status == "ok" and denied_power.quality == "partial")
assert(denied_power.data.denied_zones == 1 and denied_power.data.total_power_watts == nil)
assert(denied_power.data.by_id["vendor:0"].power_quality == "denied")
assert(issue_by_field(denied_power.data.issues, "energy").status == "denied")

local malformed_power_files = {
    ["/sys/class/powercap/vendor:0/name"] = "package-0\n",
    ["/sys/class/powercap/vendor:0/energy_uj"] = "-1\n",
    ["/sys/class/powercap/vendor:0/power_uw"] = "1.5\n",
    ["/sys/class/powercap/vendor:0/enabled"] = "2\n",
}
local malformed_power = Powercap.new({
    fs = fake_fs(malformed_power_files, {
        ["/sys/class/powercap"] = { "vendor:0" },
        ["/sys/class/powercap/vendor:0"] = { "name", "energy_uj", "power_uw", "enabled" },
    }),
}):sample({ now_ns = function() return 1 end })
assert(malformed_power.quality == "partial")
assert(issue_by_field(malformed_power.data.issues, "energy").reason
    == "expected_nonnegative_integer")
assert(issue_by_field(malformed_power.data.issues, "power").reason
    == "expected_nonnegative_integer")
assert(issue_by_field(malformed_power.data.issues, "enabled").reason
    == "number_out_of_range")

local unknown_roots_files = {
    ["/sys/class/powercap/vendor:0/name"] = "dram\n",
    ["/sys/class/powercap/vendor:0/power_uw"] = "2000000\n",
    ["/sys/class/powercap/vendor:1/name"] = "gpu\n",
    ["/sys/class/powercap/vendor:1/power_uw"] = "3000000\n",
}
local unknown_roots_directories = {
    ["/sys/class/powercap"] = { "vendor:0", "vendor:1" },
    ["/sys/class/powercap/vendor:0"] = { "name", "power_uw" },
    ["/sys/class/powercap/vendor:1"] = { "name", "power_uw" },
}
local ambiguous = Powercap.new({
    fs = fake_fs(unknown_roots_files, unknown_roots_directories),
}):sample({ now_ns = function() return 1 end })
assert(ambiguous.data.aggregate_strategy == "unrecognized_power_roots")
assert(ambiguous.data.total_power_watts == nil)
assert(not ambiguous.data.by_id["vendor:0"].aggregate)
assert(not ambiguous.data.by_id["vendor:1"].aggregate)

unknown_roots_directories["/sys/class/powercap"] = { "vendor:0" }
local single_unknown = Powercap.new({
    fs = fake_fs(unknown_roots_files, unknown_roots_directories),
}):sample({ now_ns = function() return 1 end })
assert(single_unknown.data.aggregate_strategy == "unrecognized_power_roots")
assert(single_unknown.data.total_power_watts == nil)
assert(single_unknown.data.by_id["vendor:0"].aggregate_domain == "other")
assert(not single_unknown.data.by_id["vendor:0"].aggregate,
    "an unrecognized DRAM/GPU root must never be relabeled as CPU power")

local aggregate_roots_files = {
    ["/sys/class/powercap/vendor:0/name"] = "package-0\n",
    ["/sys/class/powercap/vendor:0/power_uw"] = "5000000\n",
    ["/sys/class/powercap/vendor:1/name"] = "socket-1\n",
    ["/sys/class/powercap/vendor:1/power_uw"] = "7000000\n",
    ["/sys/class/powercap/vendor:2/name"] = "system_power\n",
    ["/sys/class/powercap/vendor:2/power_uw"] = "20000000\n",
}
local aggregate_roots_directories = {
    ["/sys/class/powercap"] = { "vendor:0", "vendor:1", "vendor:2" },
    ["/sys/class/powercap/vendor:0"] = { "name", "power_uw" },
    ["/sys/class/powercap/vendor:1"] = { "name", "power_uw" },
    ["/sys/class/powercap/vendor:2"] = { "name", "power_uw" },
}
local aggregate_roots = Powercap.new({
    fs = fake_fs(aggregate_roots_files, aggregate_roots_directories),
}):sample({ now_ns = function() return 1 end })
assert(aggregate_roots.data.aggregate_strategy == "cpu_package_roots")
assert(aggregate_roots.data.total_power_watts == 12)
assert(aggregate_roots.data.measured_aggregate_zones == 2)
assert(aggregate_roots.data.platform_power_watts == 20)
assert(aggregate_roots.data.measured_platform_zones == 1)

-- A backend may expose multiple physical sockets with the same generic name.
-- Preserve both entry IDs instead of treating the second as a parallel copy.
local same_name_files = {
    ["/sys/class/powercap/vendor:0/name"] = "socket\n",
    ["/sys/class/powercap/vendor:0/power_uw"] = "5000000\n",
    ["/sys/class/powercap/vendor:1/name"] = "socket\n",
    ["/sys/class/powercap/vendor:1/power_uw"] = "7000000\n",
}
local same_name_directories = {
    ["/sys/class/powercap"] = { "vendor:0", "vendor:1" },
    ["/sys/class/powercap/vendor:0"] = { "name", "power_uw" },
    ["/sys/class/powercap/vendor:1"] = { "name", "power_uw" },
}
local same_name = Powercap.new({
    fs = fake_fs(same_name_files, same_name_directories),
}):sample({ now_ns = function() return 1 end })
assert(same_name.data.total_power_watts == 12)
assert(same_name.data.aggregate_zone_count == 2
    and same_name.data.measured_aggregate_zones == 2 and same_name.data.aggregate_complete)
assert(same_name.data.by_id["vendor:0"].aggregate
    and same_name.data.by_id["vendor:1"].aggregate)

-- MSR and MMIO trees are parallel backends. Select one complete tree as a
-- cohort; never add the mirrored sockets together.
local parallel_files = {
    ["/sys/class/powercap/intel-rapl:0/name"] = "package\n",
    ["/sys/class/powercap/intel-rapl:0/power_uw"] = "5000000\n",
    ["/sys/class/powercap/intel-rapl:1/name"] = "package\n",
    ["/sys/class/powercap/intel-rapl:1/power_uw"] = "7000000\n",
    ["/sys/class/powercap/intel-rapl-mmio:0/name"] = "package\n",
    ["/sys/class/powercap/intel-rapl-mmio:0/power_uw"] = "50000000\n",
    ["/sys/class/powercap/intel-rapl-mmio:1/name"] = "package\n",
    ["/sys/class/powercap/intel-rapl-mmio:1/power_uw"] = "70000000\n",
}
local parallel_directories = { ["/sys/class/powercap"] = {} }
for _, id in ipairs({ "intel-rapl:0", "intel-rapl:1",
    "intel-rapl-mmio:0", "intel-rapl-mmio:1" }) do
    parallel_directories["/sys/class/powercap"][#parallel_directories["/sys/class/powercap"] + 1] = id
    parallel_directories["/sys/class/powercap/" .. id] = { "name", "power_uw" }
end
local parallel = Powercap.new({
    fs = fake_fs(parallel_files, parallel_directories),
}):sample({ now_ns = function() return 1 end })
assert(parallel.data.total_power_watts == 12)
assert(parallel.data.aggregate_source_kind == "intel-rapl")
assert(not parallel.data.by_id["intel-rapl-mmio:0"].aggregate
    and not parallel.data.by_id["intel-rapl-mmio:1"].aggregate)

-- psys/platform/system are aliases for a whole-platform domain. Even when
-- several are readable, exactly one representative is exported as aggregate.
local platform_alias_files = {
    ["/sys/class/powercap/vendor:0/name"] = "psys\n",
    ["/sys/class/powercap/vendor:0/power_uw"] = "20000000\n",
    ["/sys/class/powercap/vendor:1/name"] = "platform\n",
    ["/sys/class/powercap/vendor:1/power_uw"] = "30000000\n",
}
local platform_alias_directories = {
    ["/sys/class/powercap"] = { "vendor:0", "vendor:1" },
    ["/sys/class/powercap/vendor:0"] = { "name", "power_uw" },
    ["/sys/class/powercap/vendor:1"] = { "name", "power_uw" },
}
local platform_alias = Powercap.new({
    fs = fake_fs(platform_alias_files, platform_alias_directories),
}):sample({ now_ns = function() return 1 end })
assert(platform_alias.data.platform_power_watts == 20)
assert(platform_alias.data.measured_platform_zones == 1)
assert(platform_alias.data.platform_aggregate_strategy == "preferred_platform_root")
assert(platform_alias.data.by_id["vendor:0"].platform_aggregate)
assert(not platform_alias.data.by_id["vendor:1"].platform_aggregate)

aggregate_roots_directories["/sys/class/powercap"] = { "vendor:2" }
local platform_only = Powercap.new({
    fs = fake_fs(aggregate_roots_files, aggregate_roots_directories),
}):sample({ now_ns = function() return 1 end })
assert(platform_only.data.aggregate_strategy == "no_cpu_power_root")
assert(platform_only.data.total_power_watts == nil)
assert(platform_only.data.platform_power_watts == 20)
assert(platform_only.data.by_id["vendor:2"].platform_aggregate)
assert(not platform_only.data.by_id["vendor:2"].aggregate)

local listed_zones, _, listed_truncated = Powercap.zone_entries(fake_fs({}, {
    ["/sys/class/powercap"] = { "control", "z:2", "z:0", "z:1" },
}), "/sys/class/powercap", 2)
assert(table.concat(listed_zones, ",") == "z:0")
assert(listed_truncated,
    "the class scan reports truncation even when a control entry consumes the bound")

assert(not pcall(Powercap.new, "invalid"))
assert(not pcall(Powercap.new, { max_class_entries = 0 }))
assert(not pcall(Powercap.new, { max_power_watts = 0 / 0 }))
assert(not pcall(Powercap.new, { base_path = "relative" }))
local denied_power_probe = Powercap.new({
    fs = fake_fs({}, {
        ["/sys/class/powercap"] = { kind = "denied", message = "permission denied" },
    }),
}):probe({})
assert(denied_power_probe.state == "denied")

local unavailable = Powercap.new({
    fs = fake_fs({}, { ["/sys/class/powercap"] = { "intel-rapl" } }),
}):sample({ now_ns = function() return 1 end })
assert(unavailable.status == "unavailable")

local unreadable = Powercap.new({
    fs = fake_fs({}, {
        ["/sys/class/powercap"] = { "vendor:0" },
        ["/sys/class/powercap/vendor:0"] = {},
    }),
}):sample({ now_ns = function() return 1 end })
assert(unreadable.status == "unavailable" and unreadable.reason == "no_readable_powercap_zones")

return true
