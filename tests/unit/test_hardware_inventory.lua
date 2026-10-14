package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local CPUInfo = require("wtop.collectors.cpu_info")
local Export = require("wtop.export")
local Powercap = require("wtop.collectors.powercap")
local Snapshot = require("wtop.model.snapshot")

-- The reason column.  Both reasons are categories, and the two samples added at
-- the end of the cpu-info block are what decide them.  Instrumenting the two
-- quality locals across this suite gave six samples: two `fresh`, four
-- `partial` reached by three distinct causes, and one `estimated` -- all from
-- the same cause, a CPU whose topology the system did not state.  The three
-- that never appeared are the ones the sentences turn on, and they are added
-- here as samples of their own.
local CPU_INFO_REASON = { partial = "cpu_info_data_incomplete",
    estimated = "cpu_info_value_not_stated", fresh = false }
local cpu_info_reason_is = function(result, label)
    return require("support.collector_reason").assert_reason(result, CPU_INFO_REASON, label)
end

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
-- The `fresh` half of the invariant, and the third time in three increments
-- that the mutation battery has found a reason table with no row for `fresh`:
-- a sample that states its identity, publishes a whole topology and hits no
-- cap names no cause, and nothing above this line was asserting it.  M196
-- published one anyway and passed.
assert(not cpu_result.data.truncated and #cpu_result.data.issues == 0)
assert(cpu_result.data.identity.model_name ~= nil and cpu_result.data.identity.vendor ~= nil)
assert(cpu_result.data.topology.quality == "fresh")
cpu_info_reason_is(cpu_result, "the cpu-info sample with nothing wrong")
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
-- A cap, not a failure.  Nothing was unreadable and nothing errored: the
-- collector stopped at the flag limit it was given.  It is still `partial`,
-- and this is the sample that keeps the reason's verb honest -- "collected"
-- is true of a limit wtop chose, "read" would not be.
assert(#flags_limited.data.issues == 0)
cpu_info_reason_is(flags_limited, "the cpu-info sample stopped at its flag cap")

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
-- The opposite half of the same quality: a read that happened and produced
-- something unusable, against the cap above where nothing failed at all.
assert(not malformed_cache.data.truncated)
cpu_info_reason_is(malformed_cache, "the cpu-info sample with an unusable cache size")
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
cpu_info_reason_is(riscv_result, "the cpu-info sample whose topology the system left unstated")

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

-- The three causes that no existing sample reached, each isolated, because the
-- `estimated` sentence is decided by two of them and the `partial` verb by the
-- third.

-- A machine that states everything the topology needs and *no model name*.
-- This is not a derivation: the field is absent, so nothing was inferred from
-- anything, and "some CPU value was derived rather than read directly" -- the
-- sentence hwmon and gpu both use -- is false of it.  What is true is that the
-- system did not state it, which is what the reason says.
local nameless_sections = {}
for cpu = 0, 1 do
    nameless_sections[#nameless_sections + 1] = table.concat({
        "processor : " .. cpu,
        "vendor_id : GenuineIntel",
        "cpu family : 6",
        "physical id : 0",
        "core id : " .. cpu,
        "flags : fpu sse2",
    }, "\n")
end
local nameless_result = CPUInfo.new({
    fs = fake_fs({ ["/proc/cpuinfo"] = table.concat(nameless_sections, "\n\n") .. "\n" }, {}),
}):sample({ now_ns = function() return 106 end })
assert(nameless_result.status == "ok" and nameless_result.quality == "estimated")
assert(nameless_result.data.identity.model_name == nil)
assert(nameless_result.data.identity.vendor == "GenuineIntel",
    "only the model name is missing; the vendor is still stated")
assert(nameless_result.data.topology.quality ~= "estimated",
    "the topology is complete, so this sample is not estimated for its sake")
assert(not nameless_result.data.truncated and #nameless_result.data.issues == 0,
    "nothing failed and nothing was cut off; the identity is simply incomplete")
cpu_info_reason_is(nameless_result, "the cpu-info sample whose model name the system omits")

-- And the same with the vendor missing instead, which is a different key on
-- different architectures: a RISC-V board publishes `vendor_id` and a model
-- string, an ARM one publishes `CPU implementer`, and plenty of systems
-- publish neither.  Both absences must reach the same sentence.
local vendorless_sections = {}
for cpu = 0, 1 do
    vendorless_sections[#vendorless_sections + 1] = table.concat({
        "processor : " .. cpu,
        "model name : Example CPU",
        "cpu family : 6",
        "physical id : 0",
        "core id : " .. cpu,
        "flags : fpu sse2",
    }, "\n")
end
local vendorless_result = CPUInfo.new({
    fs = fake_fs({ ["/proc/cpuinfo"] = table.concat(vendorless_sections, "\n\n") .. "\n" }, {}),
}):sample({ now_ns = function() return 107 end })
assert(vendorless_result.status == "ok" and vendorless_result.quality == "estimated")
assert(vendorless_result.data.identity.vendor == nil)
assert(vendorless_result.data.identity.model_name == "Example CPU")
assert(vendorless_result.data.topology.quality ~= "estimated")
assert(not vendorless_result.data.truncated and #vendorless_result.data.issues == 0)
cpu_info_reason_is(vendorless_result, "the cpu-info sample whose vendor the system omits")

-- A topology enumeration stopped at its cap: the third `partial` shape, and
-- the one that is a limit rather than a failure.  `max_sys_entries = 1` clips
-- the `/sys/devices/system/cpu` listing while /proc/cpuinfo still parses in
-- full, so this is the topology cap alone and not the section cap.
local capped_result = CPUInfo.new({
    fs = fake_fs(cpu_files, cpu_directories),
    max_sys_entries = 1,
}):sample({ now_ns = function() return 108 end })
assert(capped_result.quality == "partial" and capped_result.data.truncated)
assert(#capped_result.data.issues == 0,
    "nothing was unreadable; the listing was cut at the cap wtop was given")
-- `max_sys_entries` clips twice on purpose: the listing is asked for one more
-- than the cap so the collector can tell a full directory from a cut one, and
-- the loop then re-clips to the cap.  Two CPUs are in the fixture and one
-- survives, which is what makes this the cap alone rather than a section cap.
assert(#capped_result.data.topology.logical_cpus == 1)
cpu_info_reason_is(capped_result, "the cpu-info sample whose topology listing hit its cap")
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

-- NUMA locality is independent of package containment and frequency policy
-- membership. Sparse online node IDs define distance columns.
do
    local NUMA = require("wtop.collectors.numa")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local TUI = require("wtop.tui")
    local I18n = require("wtop.i18n")
    local base = "/sys/devices/system/node"
    local files = { [base .. "/online"] = "0,2,5\n" }
    for _, id in ipairs({ 0, 2, 5 }) do
        local path = base .. "/node" .. id
        files[path .. "/cpulist"] = id == 0 and "0-1\n" or id == 2 and "\n" or "2-3\n"
        files[path .. "/distance"] = id == 0 and "10 21 31\n" or "21 10 21\n"
        files[path .. "/meminfo"] = string.format(
            "Node %d MemTotal: 8192 kB\nNode %d MemFree: 2048 kB\nNode %d FilePages: 4096 kB\n",
            id, id, id)
        files[path .. "/numastat"] = "numa_hit 100\nnuma_miss 5\nnuma_foreign 7\n"
            .. "interleave_hit 2\nlocal_node 80\nother_node 20\n"
    end
    local spec = { files = files }
    local fs = Fixture.new(spec)
    assert(x86_result.data.topology.logical_cpus[1].package_id_known == true)
    assert(riscv_result.data.topology.logical_cpus[1].package_id_known == false)
    local reader = NUMA.new({ fs = fs })
    assert(reader:probe({}).available)
    local tick = 1000000000
    local context = { now_ns = function() return tick end }
    local result = reader:sample(context)
    assert(result.status == "ok" and result.quality == "fresh" and not result.reason)
    assert(#result.data.nodes == 3 and #result.data.nodes[2].cpu_ids == 0,
        "a memory-only node has a measured empty CPU set")
    assert(result.data.nodes[1].distances[2].node_id == 2
        and result.data.nodes[1].distances[3].node_id == 5,
        "distance columns use sparse online IDs, not their array positions")
    assert(result.data.nodes[1].memory.free_bytes == 2048 * 1024)
    assert(result.data.nodes[1].memory.used_bytes == 6144 * 1024)
    assert(result.data.nodes[1].allocations.numa_hit_pages == 100)
    assert(result.data.nodes[1].allocations.rate_quality == "gap")
    local state = Snapshot.merge(nil, { numa = result }, 1, 1)
    assert(state.numa.nodes[3].id == 5 and state.quality.numa.quality == "fresh")
    state.cpu_info = { topology = { quality = "fresh", logical_cpus = {
        { id = 0, package_id = 0, core_id = 0, core_key = "0:0", online = true },
        { id = 1, package_id = 0, core_id = 0, core_key = "0:0", online = false },
        { id = 2, package_id = 1, core_id = 0, core_key = "1:0", online = true },
        { id = 3, package_id = 2, core_id = 0, core_key = "2:0", online = true },
    } } }
    state.inventory = { pci = { devices = { { address = "0000:04:00.0", numa_node = 5 } } } }
    state.cpu_frequency = { policies = {
        { id = "cpus:0,1", policy = "policy0", related_cpus = { 0, 1 }, affected_cpus = { 0 },
            driver = "fixture", governor = "powersave", frequencies = {
                current_hz = 2000000000, current_quality = "estimated", current_source = "scaling_cur_freq",
            } },
        { id = "cpus:2,3", policy = "policy2", related_cpus = { 2, 3 } },
    } }
    local graph = Hardware.build(state)
    assert(graph.by_id["cpu:1"].parent_id == "core:0:0")
    assert(graph.by_id["core:0:0"].parent_id == "package:0")
    assert(graph.by_id["cpu:1"].cpufreq_ids[1] == "cpus:0,1",
        "related CPUs includes offline members, unlike affected CPUs")
    assert(graph.by_id["cpufreq:cpus:0,1"].parent_id == "package:0")
    assert(graph.by_id["cpufreq:cpus:2,3"].parent_id == nil,
        "a policy spanning packages must remain independent")
    assert(graph.by_id["numa:5"].parent_id == nil,
        "NUMA nodes are not guessed to be physical packages")
    assert(graph.by_id["cpu:2"].numa_node_ids[1] == 5)
    assert(graph.by_id["pci:0000:04:00.0"].numa_node_ids[1] == 5)
    assert(graph.by_id["package:0"].cpufreq_ids[1] == "cpus:0,1")
    assert(graph.by_id["package:0"].numa_node_ids[1] == 0)
    assert(#graph.by_id["numa:2"].cpu_ids == 0)
    local translated = assert(I18n.new({ locale = "en-US" }))
    local details = table.concat(TUI.hardware_detail_lines(state, "cpufreq:cpus:0,1", translated), "\n")
    assert(details:find("GHz", 1, true) and details:find("Estimated", 1, true)
        and details:find("scaling_cur_freq", 1, true), "requested frequency must retain its provenance and quality")
    details = table.concat(TUI.hardware_detail_lines(state, "numa:0", translated), "\n")
    assert(details:find("node5 = 31", 1, true) and details:find("including cache", 1, true))
    local en_cpu = Hardware.label(graph.by_id["cpu:0"], translated)
    local zh_cpu = Hardware.label(graph.by_id["cpu:0"], assert(I18n.new({ locale = "zh-CN" })))
    assert(en_cpu == "Logical CPU 0" and zh_cpu == "逻辑 CPU 0")
    local engine = { history_values = function() return {} end }
    local rows = ViewModel.build(engine, state, translated, {}, "memory", nil, nil,
        { system_selected = "numa:2" }).numa_table
    assert(#rows.rows == 3 and rows.rows[2].cpus == "0" and rows.selected == 2)
    local retained = Snapshot.merge(state, { numa = { status = "denied", quality = "denied" } }, 2, 2)
    assert(ViewModel.build(engine, retained, translated, {}, "memory").numa_table.rows[1].state == "denied",
        "retained NUMA readings must not appear fresh after collection fails")
    local exported = Export.snapshot(state)
    assert(exported.numa.nodes[1].distances[3].node_id == 5)
    assert(exported.numa.nodes[1].allocations.local_node_pages == 80)
    assert(exported.numa.nodes[2].cpu_ids and #exported.numa.nodes[2].cpu_ids == 0)
    local found
    for _, node in ipairs(exported.inventory.topology.nodes) do
        if node.id == "cpu:1" then found = node end
    end
    assert(found and found.cpufreq_ids[1] == "cpus:0,1" and found.numa_node_ids[1] == 0)

    local stats_path = base .. "/node0/numastat"
    local original_stats = files[stats_path]
    files[stats_path] = "numa_hit 120\nnuma_miss 6\nnuma_foreign 8\n"
        .. "interleave_hit 3\nlocal_node 100\nother_node 30\n"
    tick = tick + 2000000000
    local next_result = reader:sample(context, result)
    local allocation = next_result.data.nodes[1].allocations
    assert(allocation.rate_quality == "fresh")
    assert(allocation.rates.local_pages_per_second == 10
        and allocation.rates.other_pages_per_second == 5)
    local next_state = Snapshot.merge(state, { numa = next_result }, 2, tick)
    assert(Export.snapshot(next_state).numa.nodes[1].allocations.rates.other_pages_per_second == 5)
    local next_detail = table.concat(TUI.hardware_detail_lines(next_state, "numa:0", translated), "\n")
    assert(next_detail:find("Cross-node pages/s: 5", 1, true)
        and next_detail:find("not memory accesses", 1, true))
    local next_rows = ViewModel.build(engine, next_state, translated, {}, "memory").numa_table
    assert(next_rows.rows[1].other_rate == "5")
    files[stats_path] = "numa_hit 121\nnuma_miss 6\nnuma_foreign 8\n"
        .. "interleave_hit 3\nlocal_node 101\nother_node 1\n"
    tick = tick + 2000000000
    local reset = reader:sample(context, next_result)
    assert(reset.data.nodes[1].allocations.rate_quality == "reset"
        and reset.data.nodes[1].allocations.rates.other_pages_per_second == nil)
    files[stats_path] = "numa_hit 10\nnuma_miss invalid\n"
    local invalid_stats = reader:sample(context)
    assert(invalid_stats.quality == "partial" and invalid_stats.data.nodes[1].allocations.numa_hit_pages == 10)
    assert(invalid_stats.data.nodes[1].issues[1].field == "allocations")
    files[stats_path] = nil
    local absent_stats = reader:sample(context)
    assert(absent_stats.quality == "fresh" and absent_stats.data.nodes[1].allocations == nil,
        "older kernels without numastat keep usable NUMA topology fresh")
    files[stats_path] = original_stats

    state.cpu_info.topology.logical_cpus[1].package_id_known = false
    state.cpu_info.topology.logical_cpus[1].online_known = false
    assert(table.concat(TUI.hardware_detail_lines(state, "cpu:0", translated), "\n"):find("Online: —", 1, true),
        "unknown online state is not presented as a confirmed running CPU")
    assert(Hardware.build(state).by_id["cpu:0"].parent_id == nil,
        "inferred package zero is not physical containment evidence")
    local fallback = Hardware.build({ cpu_info = { topology = { quality = "estimated",
        logical_cpus = { { id = 0, package_id = 0, core_id = 0, core_key = "0:0" } } } } })
    assert(not fallback.by_id["package:0"] and fallback.by_id["cpu:0"],
        "portable or old snapshots with estimated topology do not invent packages")
    local absent = NUMA.new({ fs = Fixture.new() })
    assert(absent:probe({}).reason == "numa_unavailable" and absent:sample({}).status == "unavailable")
    local empty = NUMA.new({ fs = Fixture.new({ dirs = { [base] = {} } }) })
    assert(empty:probe({}).reason == "no_numa_nodes" and empty:sample({}).reason == "no_numa_nodes")
    local denied = NUMA.new({ fs = Fixture.new({ denied = { [base] = true } }) })
    assert(denied:probe({}).state == "denied" and denied:sample({}).status == "denied")
    spec.denied = { [base .. "/node0/meminfo"] = true }
    local partial = NUMA.new({ fs = Fixture.new(spec) }):sample({})
    assert(partial.quality == "partial" and partial.reason == "numa_data_incomplete")
    assert(partial.data.nodes[1].memory == nil and partial.data.nodes[1].issues[1].status == "denied")
    spec.denied = nil
    files[base .. "/node0/meminfo"] = "Node 0 MemTotal: 1 kB\nNode 0 MemFree: 2 kB\n"
    assert(NUMA.new({ fs = Fixture.new(spec) }):sample({}).data.nodes[1].memory == nil,
        "inconsistent memory counters cannot yield negative usage")
    files[base .. "/node0/cpulist"] = "0-2147483647"
    assert(NUMA.new({ fs = Fixture.new(spec) }):sample({}).data.nodes[1].cpu_ids == nil,
        "a malformed CPU range is rejected before expansion")
    files[base .. "/node0/distance"] = "10 20"
    assert(NUMA.new({ fs = Fixture.new(spec) }):sample({}).data.nodes[1].distances == nil,
        "a short distance row cannot shift node identities")
    local limited = NUMA.new({ fs = fs, max_nodes = 2 }):sample({})
    assert(limited.data.truncated and limited.quality == "partial" and #limited.data.nodes == 2)
    local changing = Fixture.new(spec)
    local read, calls = changing.read, 0
    function changing:read(path, limit)
        if path == base .. "/online" then
            calls = calls + 1
            return calls == 1 and "0,2,5" or "0,3,5"
        end
        return read(self, path, limit)
    end
    local changed = NUMA.new({ fs = changing }):sample({})
    assert(changed.quality == "partial" and not changed.data.nodes[3].distances,
        "same-length hotplug sets must still invalidate all distance mappings")
    files[base .. "/online"] = nil
    local unknown_online = NUMA.new({ fs = Fixture.new(spec) }):sample({})
    assert(Export.snapshot({ numa = unknown_online.data }).numa.online_nodes == nil,
        "an unreadable online set is not exported as a measured empty set")
    assert(not pcall(NUMA.new, { max_nodes = 0 }) and not pcall(NUMA.new, { base_path = "relative" }))
end

-- SMBIOS memory inventory: binary framing, units, unknown/empty slots,
-- privacy, topology and the shared Linux/Windows reader.
do
    local SMBIOS = require("wtop.format.smbios")
    local MemoryDevices = require("wtop.collectors.memory_devices")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local JSON = require("wtop.format.json")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local ViewModel = require("wtop.view_model")
    local function replace(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(kind, length, handle, fields, strings)
        local data = string.pack("<BBI2", kind, length, handle) .. string.rep("\0", length - 4)
        for offset, field in pairs(fields or {}) do data = replace(data, offset, field) end
        return data .. table.concat(strings or {}, "\0") .. "\0\0"
    end
    local function word(value) return string.pack("<I2", value) end
    local function dword(value) return string.pack("<I4", value) end
    local function qword(value) return string.pack("<I8", value) end
    local array = record(16, 23, 0x1000, {
        [4] = "\3\3\6", [7] = dword(0x80000000), [13] = word(4), [15] = qword(1024^4),
    })
    local full = record(17, 92, 0x1100, {
        [4] = word(0x1000), [8] = word(72), [10] = word(64), [12] = word(0x7fff),
        [14] = "\13", [16] = "\1\2\34", [19] = word(0x4080), [21] = word(65535),
        [23] = "\3\4\5\6\2", [28] = dword(65536), [32] = word(6400),
        [34] = word(1000) .. word(1200) .. word(1100), [43] = "\7", [84] = dword(88000),
    }, { "DIMM_A1", "Bank A", "Fixture Vendor", "PRIVATE-SERIAL-123", "PRIVATE-ASSET-456", "TEST-64G", "1.2" })
    assert(full:sub(1, 4) == "\17\92\0\17", "fixture uses SMBIOS type/length/little-endian handle framing")
    local empty = record(17, 21, 0x1101, { [4] = word(0x1000), [8] = word(65535), [10] = word(65535), [16] = "\1" }, { "DIMM_A2" })
    local unknown = record(17, 21, 0x1102, { [4] = word(0x1000), [12] = word(65535), [16] = "\1" }, { "DIMM_B1" })
    local legacy = record(17, 21, 0x1103, { [4] = word(0x1000), [12] = word(0x8100), [16] = "\1" }, { "DIMM_B2" })
    local ending = record(127, 4, 65535)
    local unrelated = record(1, 8, 1, {}, { "PRIVATE-SYSTEM-UUID" })
    local blob = unrelated .. array .. full .. empty .. unknown .. legacy .. ending
    local function sum(data)
        local value = 0
        for index = 1, #data do value = (value + data:byte(index)) % 256 end
        return value
    end
    local function entry3(maximum)
        local entry = "_SM3_\0\24\3\8\0\1\0" .. dword(maximum) .. qword(0)
        return replace(entry, 5, string.char((-sum(entry)) % 256))
    end
    local function entry2(length, count)
        local entry = "_SM_\0\31\2\8" .. word(92) .. "\0" .. string.rep("\0", 5)
            .. "_DMI_\0" .. word(length) .. dword(0) .. word(count) .. "\40"
        entry = replace(entry, 21, string.char((-sum(entry:sub(17, 31))) % 256))
        return replace(entry, 4, string.char((-sum(entry)) % 256))
    end
    local parsed = assert(SMBIOS.parse(blob, assert(SMBIOS.entry_point(entry3(#blob + 128)))))
    assert(not parsed.partial and #parsed.arrays == 1 and #parsed.devices == 4)
    assert(parsed.arrays[1].maximum_capacity_bytes == 1024^4)
    assert(parsed.arrays[1].error_correction_code == 6 and parsed.arrays[1].device_count == 4)
    local module = parsed.devices[1]
    assert(module.id == "1100" and module.array_id == "1000" and module.locator == "DIMM_A1")
    assert(module.size_bytes == 64 * 1024^3 and module.populated == true)
    assert(module.memory_type == "DDR5" and module.form_factor == "SO-DIMM")
    assert(module.speed_mts == 88000 and module.configured_speed_mts == 6400)
    assert(module.total_width_bits == 72 and module.data_width_bits == 64 and module.rank == 2)
    assert(module.configured_voltage_mv == 1100 and module.firmware_version == "1.2")
    assert(module.part_number == "TEST-64G" and module.manufacturer == "Fixture Vendor")
    assert(parsed.devices[2].populated == false and parsed.devices[2].size_bytes == 0)
    assert(parsed.devices[2].total_width_bits == nil and parsed.devices[2].data_width_bits == nil)
    assert(parsed.devices[3].populated == nil and parsed.devices[3].size_bytes == nil)
    assert(parsed.devices[4].size_bytes == 256 * 1024 and parsed.devices[4].speed_mts == nil)
    assert(not JSON.encode(parsed):find("PRIVATE", 1, true), "only whitelisted strings leave the decoder")
    local ep2 = assert(SMBIOS.entry_point(entry2(#blob, 7)))
    assert(ep2.major == 2 and ep2.minor == 8 and ep2.structure_count == 7)
    assert(not assert(SMBIOS.parse(blob, ep2)).partial)
    assert(SMBIOS.entry_point(replace(entry3(#blob), 5, "\127")) == nil, "entry checksum is verified")
    assert(SMBIOS.entry_point("_SM3_\0") == nil)
    assert(SMBIOS.parse(blob, { maximum_table_bytes = #blob - 1 }) == nil)
    assert(assert(SMBIOS.parse(blob, { structure_count = 8 })).partial)
    for length = 0, #blob - 1 do
        local ok, value = pcall(SMBIOS.parse, blob:sub(1, length), { major = 3 })
        assert(ok, "a truncated record must not throw at byte " .. length)
        assert(value == nil or value.partial, "a truncated table must not report a complete read")
    end
    assert(assert(SMBIOS.parse(blob, nil, { max_devices = 2 })).truncated)
    local duplicate = assert(SMBIOS.parse(array .. full .. full .. ending))
    assert(duplicate.partial and duplicate.devices[1].ambiguous and duplicate.devices[2].ambiguous)
    assert(not duplicate.devices[1].array_id, "ambiguous modules cannot claim array ownership")
    local broken_size = replace(full, 28, dword(0x80000000))
    local invalid = assert(SMBIOS.parse(array .. broken_size .. ending))
    assert(invalid.partial and invalid.devices[1].size_bytes == nil)
    local bad_string = assert(SMBIOS.parse(array .. replace(full, 16, "\255") .. ending))
    assert(bad_string.partial and bad_string.devices[1].locator == nil
        and bad_string.devices[1].part_number == "TEST-64G",
        "an out-of-range string index cannot read into the next structure")
    local short_extended = replace(full, 21, word(0))
    assert(assert(SMBIOS.parse(array .. short_extended .. ending)).devices[1].speed_mts == nil)
    local logical = record(17, 84, 0x1110, { [4] = word(0x1000), [18] = "\31", [76] = qword(8 * 1024^3) })
    local logical_module = assert(SMBIOS.parse(array .. logical .. ending)).devices[1]
    assert(logical_module.logical and logical_module.size_bytes == 8 * 1024^3 and logical_module.populated == nil)

    local base = "/sys/firmware/dmi/tables"
    local fs = Fixture.new({ files = { [base .. "/DMI"] = blob, [base .. "/smbios_entry_point"] = entry3(#blob) } })
    local collector = MemoryDevices.new({ fs = fs, platform = "linux" })
    assert(collector:probe({}).available)
    local result = collector:sample({})
    assert(result.status == "ok" and result.quality == "fresh")
    local state = Snapshot.merge(nil, { memory_devices = result }, 1, 1)
    local graph = Hardware.build(state)
    assert(graph.by_id["dimm:1100"].parent_id == "memory-array:1000")
    assert(graph.by_id["memory-array:1000"].kind == "memory_array")
    local exported = Export.snapshot(state)
    assert(exported.memory_devices.devices[1].size_bytes == 64 * 1024^3)
    assert(not JSON.encode(exported):find("PRIVATE", 1, true), "snapshot export contains no raw firmware or private identity")
    local translator = assert(I18n.new({ locale = "en-US" }))
    local details = table.concat(TUI.hardware_detail_lines(state, "dimm:1100", translator), "\n")
    assert(details:find("TEST-64G", 1, true) and details:find("MT/s", 1, true) and details:find("Firmware report", 1, true))
    assert(details:find("p parent", 1, true) and not details:find("PRIVATE", 1, true))
    local array_details = table.concat(TUI.hardware_detail_lines(state, "memory-array:1000", translator), "\n")
    assert(array_details:find("Multi-bit ECC", 1, true) and array_details:find("Device positions: 4", 1, true))
    local engine = { history_values = function() return {} end }
    local model = ViewModel.build(engine, state, translator, {}, "memory", nil, nil, { system_selected = "dimm:1101" }).dimm_table
    assert(#model.rows == 4 and model.rows[2].size == "Empty" and model.rows[3].size == "—" and model.selected == 2)
    local denied = MemoryDevices.new({ platform = "linux", fs = Fixture.new({ denied = { [base .. "/DMI"] = true } }) })
    assert(denied:probe({}).state == "denied" and denied:sample({}).status == "denied")
    local retained = Snapshot.merge(state, { memory_devices = denied:sample({}) }, 2, 2)
    assert(ViewModel.build(engine, retained, translator, {}, "memory").dimm_table.rows[1].state == "denied")
    local absent = MemoryDevices.new({ platform = "linux", fs = Fixture.new() })
    assert(absent:sample({}).status == "unavailable")
    local no_entry = MemoryDevices.new({ platform = "linux", fs = Fixture.new({ files = { [base .. "/DMI"] = blob } }) }):sample({})
    assert(no_entry.quality == "partial" and #no_entry.data.devices == 4)
    local native = { read_smbios = function() return { data = blob, major = 3, minor = 8 } end }
    local portable = require("wtop.collectors.portable").new_all({ platform = "windows", common = { native = native } }).memory_devices
    assert(portable:sample({}).data.devices[1].part_number == "TEST-64G")
    assert(portable:sample({}).source == "native:read_smbios")
    assert(MemoryDevices.new({ platform = "windows", native = {} }):sample({}).reason == "smbios_unavailable")
    native.read_smbios = function() return nil, "smbios_unavailable", "denied" end
    assert(portable:probe({}).state == "denied")
    native.read_smbios = function() return { data = "bad" } end
    assert(portable:sample({}).status == "error")
    native.read_smbios = function() error("provider failed") end
    assert(portable:sample({}).status == "error")
    assert(not pcall(MemoryDevices.new, { base_path = "relative" }))

    local mapped_array = replace(array, 13, word(1))
    local extended_start = 4 * 1024^4
    local array_range = record(19, 31, 0x1200, {
        [4] = dword(0xffffffff) .. dword(0xffffffff),
        [12] = word(0x1000), [14] = "\2",
        [15] = qword(extended_start), [23] = qword(extended_start + 64 * 1024^3 - 1),
    })
    local device_range = record(20, 35, 0x1300, {
        [4] = dword(0xffffffff) .. dword(0xffffffff),
        [12] = word(0x1100) .. word(0x1200) .. "\255\1\1",
        [19] = qword(extended_start + 16 * 1024^3),
        [27] = qword(extended_start + 48 * 1024^3 - 1),
    })
    local legacy_array_range = record(19, 15, 0x1201, {
        [4] = dword(1024) .. dword(2047), [12] = word(0x1000), [14] = "\1",
    })
    local legacy_device_range = record(20, 19, 0x1301, {
        [4] = dword(1280) .. dword(1535),
        [12] = word(0x1100) .. word(0x1201) .. "\1\0\0",
    })
    local mapping_blob = mapped_array .. full .. array_range .. device_range
        .. legacy_array_range .. legacy_device_range .. ending
    local mapping = assert(SMBIOS.parse(mapping_blob,
        assert(SMBIOS.entry_point(entry3(#mapping_blob)))))
    assert(not mapping.partial and #mapping.array_ranges == 2 and #mapping.device_ranges == 2)
    assert(mapping.array_ranges[1].array_id == "1000"
        and mapping.array_ranges[1].start_address_bytes == extended_start
        and mapping.array_ranges[1].address_span_bytes == 64 * 1024^3)
    assert(mapping.device_ranges[1].device_id == "1100"
        and mapping.device_ranges[1].array_range_id == "1200"
        and mapping.device_ranges[1].address_span_bytes == 32 * 1024^3
        and mapping.device_ranges[1].partition_row_position == nil
        and mapping.device_ranges[1].interleave_position == 1)
    assert(mapping.array_ranges[2].start_address_bytes == 1024^2
        and mapping.array_ranges[2].end_address_bytes == 2 * 1024^2 - 1)
    assert(mapping.device_ranges[2].address_span_bytes == 256 * 1024)
    local mapped_collector = MemoryDevices.new({ platform = "linux", fs = Fixture.new({ files = {
        [base .. "/DMI"] = mapping_blob,
        [base .. "/smbios_entry_point"] = entry3(#mapping_blob),
    } }) })
    local mapped_result = mapped_collector:sample({})
    assert(mapped_result.status == "ok" and mapped_result.quality == "fresh")
    local mapped_state = Snapshot.merge(nil, { memory_devices = mapped_result }, 1, 1)
    local mapped_graph = Hardware.build(mapped_state)
    assert(not mapped_graph.partial)
    assert(mapped_graph.by_id["memory-array-range:1200"].parent_id == "memory-array:1000")
    assert(mapped_graph.by_id["memory-device-range:1300"].parent_id == "memory-array-range:1200")
    assert(mapped_graph.by_id["memory-device-range:1300"].memory_device_id == "dimm:1100")
    assert(#mapped_graph.by_id["dimm:1100"].mapped_range_ids == 2
        and #mapped_graph.by_id["memory-array:1000"].mapped_range_ids == 2)
    local mapped_export = Export.snapshot(mapped_state)
    assert(#mapped_export.memory_devices.array_ranges == 2
        and #mapped_export.memory_devices.device_ranges == 2)
    assert(mapped_export.memory_devices.device_ranges[1].start_address_bytes
        == extended_start + 16 * 1024^3)
    assert(not JSON.encode(mapped_export):find("PRIVATE", 1, true))
    local range_node
    for _, node in ipairs(mapped_export.inventory.topology.nodes) do
        if node.id == "memory-device-range:1300" then range_node = node end
    end
    assert(range_node and range_node.memory_device_id == "dimm:1100")
    local range_detail = table.concat(TUI.hardware_detail_lines(mapped_state,
        "memory-device-range:1300", translator), "\n")
    assert(range_detail:find("0x", 1, true)
        and range_detail:find("32 GiB", 1, true)
        and range_detail:find("TEST-64G", 1, true)
        and range_detail:find("can overlap", 1, true))
    local mapped_rows = ViewModel.build(engine, mapped_state, translator, {}, "system")
        .system_devices.rows
    local saw_range = false
    for _, row in ipairs(mapped_rows) do
        if row.device:find("Device address range", 1, true) then saw_range = true end
    end
    assert(saw_range)
    local second_dimm = record(17, 21, 0x1101, {
        [4] = word(0x1000), [12] = word(16384), [16] = "\1",
    }, { "DIMM_A2" })
    local overlapping = replace(replace(device_range, 2, word(0x1302)), 12, word(0x1101))
    local interleaved_blob = replace(mapped_array, 13, word(2)) .. full .. second_dimm
        .. array_range .. device_range .. overlapping .. ending
    local interleaved = assert(SMBIOS.parse(interleaved_blob))
    assert(not interleaved.partial and #interleaved.device_ranges == 2)
    local interleaved_graph = Hardware.build({ memory_devices = interleaved })
    assert(not interleaved_graph.partial
        and interleaved_graph.by_id["memory-device-range:1302"].memory_device_id == "dimm:1101"
        and interleaved_graph.by_id["memory-device-range:1302"].parent_id
            == "memory-array-range:1200",
        "interleaved device ranges may overlap without losing either handle relationship")
    local mixed = assert(SMBIOS.parse(mapped_array .. full
        .. replace(array_range, 8, dword(100)) .. ending))
    assert(mixed.partial and mixed.array_ranges[1].start_address_bytes == nil)
    local short_extension = assert(SMBIOS.parse(mapped_array .. full
        .. replace(legacy_array_range, 4, dword(0xffffffff) .. dword(0xffffffff)) .. ending))
    assert(short_extension.partial and short_extension.array_ranges[1].address_span_bytes == nil)
    local reverse = assert(SMBIOS.parse(mapped_array .. full
        .. replace(legacy_array_range, 4, dword(2047) .. dword(1024)) .. ending))
    assert(reverse.partial and reverse.array_ranges[1].address_span_bytes == nil)
    local overflow = assert(SMBIOS.parse(mapped_array .. full
        .. replace(array_range, 23, string.rep("\0", 7) .. "\128") .. ending))
    assert(overflow.partial and overflow.array_ranges[1].end_address_bytes == nil)
    local out_of_bounds = assert(SMBIOS.parse(mapped_array .. full .. legacy_array_range
        .. replace(legacy_device_range, 8, dword(2048)) .. ending))
    assert(out_of_bounds.partial and out_of_bounds.device_ranges[1].device_id == nil)
    local reserved_row = assert(SMBIOS.parse(mapped_array .. full .. array_range
        .. replace(device_range, 16, "\0") .. ending))
    assert(reserved_row.partial and reserved_row.device_ranges[1].partition_row_position == nil)
    local missing_device = assert(SMBIOS.parse(mapped_array .. array_range .. device_range .. ending))
    assert(missing_device.partial and missing_device.device_ranges[1].device_id == nil)
    local foreign_array = replace(replace(mapped_array, 2, word(0x1001)), 13, word(0))
    local foreign_range = replace(array_range, 12, word(0x1001))
    local mismatched = assert(SMBIOS.parse(mapped_array .. full .. foreign_array
        .. foreign_range .. device_range .. ending))
    assert(mismatched.partial and mismatched.device_ranges[1].device_id == nil)
    local duplicate_range = assert(SMBIOS.parse(mapped_array .. full
        .. array_range .. array_range .. device_range .. ending))
    assert(duplicate_range.partial and duplicate_range.array_ranges[1].ambiguous
        and duplicate_range.device_ranges[1].array_range_id == nil)
    assert(assert(SMBIOS.parse(mapping_blob, nil, { max_array_ranges = 1 })).truncated)
    assert(assert(SMBIOS.parse(mapping_blob, nil, { max_device_ranges = 1 })).truncated)
    for length = 0, #mapping_blob - 1 do
        local ok, value = pcall(SMBIOS.parse, mapping_blob:sub(1, length))
        assert(ok and (value == nil or value.partial), "truncated Type 19/20 table at " .. length)
    end
    local native_mapping = { read_smbios = function()
        return { data = mapping_blob, major = 3, minor = 8 }
    end }
    local windows_mapping = require("wtop.collectors.portable").new_all({
        platform = "windows", common = { native = native_mapping },
    }).memory_devices:sample({})
    assert(windows_mapping.status == "ok" and #windows_mapping.data.device_ranges == 2)
end

-- Type 37 ties firmware memory channels to Type 17 handles. A label, capacity
-- or physical-looking order is not a substitute for those explicit handles.
do
    local SMBIOS = require("wtop.format.smbios")
    local MemoryDevices = require("wtop.collectors.memory_devices")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(kind, length, handle, fields, strings)
        local data = string.pack("<BBI2", kind, length, handle) .. string.rep("\0", length - 4)
        for offset, value in pairs(fields or {}) do data = put(data, offset, value) end
        return data .. table.concat(strings or {}, "\0") .. "\0\0"
    end
    local function word(value) return string.pack("<I2", value) end
    local array = record(16, 23, 0x1000, {
        [4] = "\3\3\6", [7] = string.pack("<I4", 16777216), [13] = word(2),
    })
    local dimm_a = record(17, 21, 0x1100, {
        [4] = word(0x1000), [12] = word(8192), [16] = "\1",
    }, { "DIMM_A1" })
    local dimm_b = record(17, 21, 0x1101, {
        [4] = word(0x1000), [12] = word(8192), [16] = "\1",
    }, { "DIMM_B1" })
    local channel = record(37, 13, 0x3700, {
        [4] = "\3\4\2", [7] = "\1" .. word(0x1100) .. "\2" .. word(0x1101),
    })
    local second = record(37, 10, 0x3701, {
        [4] = "\3\2\1", [7] = "\1" .. word(0x1101),
    })
    local ending = record(127, 4, 65535)
    local private = record(1, 8, 0x4000, {}, { "PRIVATE-SERIAL" })
    local blob = private .. array .. dimm_a .. dimm_b .. channel .. second .. ending
    local parsed = assert(SMBIOS.parse(blob))
    assert(not parsed.partial and #parsed.channels == 2 and #parsed.devices == 2)
    assert(parsed.channels[1].channel_type == "Rambus"
        and parsed.channels[1].maximum_load == 4
        and parsed.channels[1].total_load == 3
        and parsed.channels[1].device_count == 2
        and parsed.channels[1].devices[1].device_id == "1100"
        and parsed.channels[1].devices[2].load == 2)
    local extended = assert(SMBIOS.parse(array .. dimm_a .. dimm_b
        .. record(37, 14, 0x3702, { [4] = "\3\4\2",
            [7] = "\1" .. word(0x1100) .. "\2" .. word(0x1101),
            [13] = "\170" }) .. ending))
    assert(not extended.partial and #extended.channels[1].devices == 2,
        "trailing Type 37 fields must not be counted as another memory device")
    local base = "/sys/firmware/dmi/tables"
    local fs = Fixture.new({ files = { [base .. "/DMI"] = blob } })
    local collector = MemoryDevices.new({ fs = fs, platform = "linux" })
    local result = collector:sample({})
    assert(result.status == "ok" and #result.data.channels == 2
        and result.data.channels[1].source:find("#3700", 1, true))
    local bare = record(37, 7, 0x3704, { [4] = "\3\0\0" }) .. ending
    local bare_result = MemoryDevices.new({ platform = "linux", fs = Fixture.new({
        files = { [base .. "/DMI"] = bare },
    }) }):sample({})
    assert(bare_result.status == "ok" and #bare_result.data.channels == 1
        and #bare_result.data.devices == 0,
        "a firmware table containing only an empty channel is still a channel inventory")
    local state = Snapshot.merge(nil, { memory_devices = result }, 1, 1)
    local graph = Hardware.build(state)
    local first = graph.by_id["memory-channel:3700"]
    local second_node = graph.by_id["memory-channel:3701"]
    assert(first and second_node and first.parent_id == nil
        and first.memory_device_ids[1] == "dimm:1100"
        and first.memory_device_ids[2] == "dimm:1101")
    assert(graph.by_id["dimm:1100"].parent_id == "memory-array:1000"
        and graph.by_id["dimm:1100"].channel_ids[1] == first.id
        and #graph.by_id["dimm:1101"].channel_ids == 2)
    assert(Hardware.related(graph, first.id).total == 2
        and Hardware.related(graph, "dimm:1100").items[1].id == first.id)
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local system = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "system", nil, nil,
        { system_query = "name:3700" }).system_devices
    assert(#system.rows == 1 and system.ids[1] == first.id)
    local detail = table.concat(TUI.hardware_detail_lines(state, first.id, i18n), "\n")
    assert(detail:find("Memory channel 3700", 1, true)
        and detail:find("Maximum channel load: 4", 1, true)
        and detail:find("DIMM_A1 (1)", 1, true)
        and detail:find("not measured memory bandwidth", 1, true))
    local dimm_detail = table.concat(TUI.hardware_detail_lines(state, "dimm:1100", i18n), "\n")
    assert(dimm_detail:find("Firmware memory channels: Memory channel 3700", 1, true))
    local exported = Export.snapshot(state)
    assert(exported.memory_devices.channels[1].devices[2].device_id == "1101")
    local exported_dimm
    for _, node in ipairs(exported.inventory.topology.nodes) do
        if node.id == "dimm:1100" then exported_dimm = node end
    end
    assert(exported_dimm and exported_dimm.channel_ids[1] == first.id)
    assert(not JSON.encode(exported):find("PRIVATE", 1, true))
    local missing = assert(SMBIOS.parse(array .. dimm_a .. dimm_b
        .. put(channel, 11, word(0x9999)) .. ending))
    assert(missing.partial and missing.channels[1].quality == "partial")
    local missing_graph = Hardware.build({ memory_devices = missing })
    assert(#missing_graph.by_id["memory-channel:3700"].memory_device_ids == 0)
    local unparented = assert(SMBIOS.parse(array
        .. put(dimm_a, 4, word(0x9999)) .. dimm_b .. channel .. ending))
    local unparented_graph = Hardware.build({ memory_devices = unparented })
    assert(unparented.channels[1].quality == "partial"
        and #unparented_graph.by_id["memory-channel:3700"].memory_device_ids == 0)
    local overloaded = assert(SMBIOS.parse(array .. dimm_a .. dimm_b
        .. put(channel, 5, "\2") .. ending))
    local overloaded_graph = Hardware.build({ memory_devices = overloaded })
    assert(overloaded.partial and overloaded.channels[1].total_load == 3
        and #overloaded_graph.by_id["memory-channel:3700"].memory_device_ids == 0)
    local zero_load = assert(SMBIOS.parse(array .. dimm_a .. dimm_b
        .. put(channel, 7, "\0") .. ending))
    assert(zero_load.partial and zero_load.channels[1].quality == "partial")
    local repeated = assert(SMBIOS.parse(array .. dimm_a .. dimm_b
        .. put(channel, 10, "\1" .. word(0x1100)) .. ending))
    assert(repeated.partial and repeated.channels[1].quality == "partial")
    local short = assert(SMBIOS.parse(array .. dimm_a .. dimm_b
        .. put(channel, 6, "\3") .. ending))
    assert(short.partial and short.channels[1].quality == "partial")
    local duplicate = assert(SMBIOS.parse(array .. dimm_a .. dimm_b
        .. channel .. channel .. ending))
    assert(duplicate.partial and duplicate.channels[1].ambiguous)
    local limited = assert(SMBIOS.parse(blob, nil, { max_channels = 1 }))
    assert(limited.truncated and #limited.channels == 1)
    local clipped = Hardware.build({ memory_devices = limited })
    assert(#clipped.by_id["memory-channel:3700"].memory_device_ids == 0)
    local poisoned = Hardware.build({ memory_devices = {
        arrays = parsed.arrays, devices = parsed.devices, channels = { {
            id = "3709", quality = "fresh", device_count = 1, maximum_load = 10,
            devices = { { device_id = "1100", load = math.huge } },
        } },
    } })
    assert(poisoned.partial
        and #poisoned.by_id["memory-channel:3709"].memory_device_ids == 0,
        "a non-finite fixture load cannot create a channel relationship")
    local many = record(37, 7 + 65 * 3, 0x3703, {
        [4] = "\3\255\65", [7] = string.rep("\1" .. word(0x1100), 65),
    })
    local bounded = assert(SMBIOS.parse(array .. dimm_a .. dimm_b .. many .. ending))
    assert(bounded.truncated and bounded.channels[1].quality == "partial"
        and #bounded.channels[1].devices == 64)
    for length = 0, #channel - 1 do
        local ok, partial = pcall(SMBIOS.parse,
            array .. dimm_a .. dimm_b .. channel:sub(1, length))
        assert(ok and (partial == nil or partial.partial),
            "truncated Type 37 record escaped bounds at byte " .. length)
    end
    local native = { read_smbios = function() return { data = blob, major = 3, minor = 9 } end }
    local portable = require("wtop.collectors.portable").new_all({ platform = "windows",
        common = { native = native } }).memory_devices:sample({})
    assert(portable.status == "ok" and #portable.data.channels == 2)
end

-- coretemp's package label is the only cross-source identity. Core numbers
-- are scoped to that package and must be unique before they can be linked.
do
    local Hardware = require("wtop.model.hardware")
    local cpu = { topology = { quality = "fresh", logical_cpus = {
        { id = 0, package_id = 0, package_id_known = true, core_id = 2,
          core_id_known = true, core_key = "0:-:2" },
        { id = 1, package_id = 1, package_id_known = true, core_id = 2,
          core_id_known = true, core_key = "1:-:2" },
    } } }
    local sensor = { id = "coretemp@test", name = "coretemp", channels = {
        { id = "temperature:1", type = "temperature", label = "Package id 0", input = 53 },
        { id = "temperature:2", type = "temperature", label = "Core 2", input = 49 },
        { id = "temperature:3", type = "temperature", label = "Core 3", input = 47 },
    } }
    local graph = Hardware.build({ cpu_info = cpu, sensors = { devices = { sensor } } })
    assert(#graph.by_id["package:0"].sensors == 1)
    assert(#graph.by_id["package:0"].sensors[1].channels == 1)
    assert(graph.by_id["package:0"].sensors[1].channels[1].input == 53)
    assert(#graph.by_id["core:0:-:2"].sensors == 1)
    assert(graph.by_id["core:0:-:2"].sensors[1].channels[1].input == 49)
    assert(#graph.by_id["package:1"].sensors == 0)
    assert(#graph.by_id["core:1:-:2"].sensors == 0)
    sensor.channels[2].label = "Core 3"
    graph = Hardware.build({ cpu_info = cpu, sensors = { devices = { sensor } } })
    assert(#graph.by_id["core:0:-:2"].sensors == 0)
    sensor.channels[2].label = "Core 2"
    local duplicate = { id = "second", name = "coretemp", channels = {
        { type = "temperature", label = "Package id 0", input = 42 },
    } }
    graph = Hardware.build({ cpu_info = cpu, sensors = { devices = { sensor, duplicate } } })
    assert(#graph.by_id["package:0"].sensors == 0)
    assert(#graph.by_id["core:0:-:2"].sensors == 0)
end

-- A CPUFreq policy has no temperature sensor of its own. It can reference a
-- coretemp reading only when every member resolves to the same measured core
-- or, less specifically, the same measured package.
do
    local Hardware = require("wtop.model.hardware")
    local TUI = require("wtop.tui")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local cpu = { topology = { quality = "fresh", logical_cpus = {
        { id = 0, package_id = 0, package_id_known = true,
          core_id = 0, core_id_known = true, core_key = "0:-:0" },
        { id = 1, package_id = 0, package_id_known = true,
          core_id = 1, core_id_known = true, core_key = "0:-:1" },
        { id = 2, package_id = 1, package_id_known = true,
          core_id = 0, core_id_known = true, core_key = "1:-:0" },
    } } }
    local sensor = { id = "coretemp@cpu0", name = "coretemp", channels = {
        { id = "temperature:1", type = "temperature", label = "Package id 0", input = 53 },
        { id = "temperature:2", type = "temperature", label = "Core 0", input = 49 },
        { id = "temperature:3", type = "temperature", label = "Core 1", input = 47 },
    } }
    local function policy(id, cpus)
        return { id = id, policy = id, related_cpus = cpus,
            affected_cpus = cpus, frequencies = { current_hz = 2000000000 } }
    end
    local state = { cpu_info = cpu, sensors = { devices = { sensor } },
        cpu_frequency = { policies = {
            policy("p0", { 0 }), policy("p1", { 0, 1 }),
            policy("p2", { 0, 2 }), policy("p3", { 0, 9 }),
        } }, quality = { sensors = { status = "ok", quality = "fresh" } } }
    local graph = Hardware.build(state)
    local core = graph.by_id["cpufreq:p0"]
    local package = graph.by_id["cpufreq:p1"]
    assert(core.temperature.scope == "core" and core.temperature.celsius == 49)
    assert(core.temperature.owner_id == "core:0:-:0")
    assert(core.temperature.sensor_id == sensor.id
        and core.temperature.channel_id == "temperature:2")
    assert(#core.sensor_ids == 1 and #core.sensors == 1)
    assert(package.temperature.scope == "package" and package.temperature.celsius == 53)
    assert(package.temperature.owner_id == "package:0")
    sensor.channels[1].label = "Physical id 0"
    local physical_label_graph = Hardware.build(state)
    assert(physical_label_graph.by_id["cpufreq:p1"].temperature.celsius == 53,
        "older coretemp package labels still identify the measured package")
    sensor.channels[1].label = "Package id 0"
    assert(graph.by_id["cpufreq:p2"].temperature == nil,
        "a policy crossing packages must not inherit either package temperature")
    assert(graph.by_id["cpufreq:p3"].temperature == nil,
        "an unknown member must not make a partial policy look package-local")
    local exported = Export.snapshot(state).inventory.topology.nodes
    local exported_core
    for _, node in ipairs(exported) do
        if node.id == "cpufreq:p0" then exported_core = node end
    end
    assert(exported_core and exported_core.temperature.scope == "core"
        and exported_core.temperature.sensor_id == sensor.id)
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local detail = table.concat(TUI.hardware_detail_lines(state, "cpufreq:p0", i18n), "\n")
    assert(detail:find("Related temp: Core", 1, true)
        and detail:find("Related sensors: 1", 1, true))
    local view = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "compute")
    assert(view.cpufreq_table.rows[1].temperature_scope == "core")
    assert(view.cpufreq_table.rows[1].temperature:find("Core", 1, true))
    assert(view.cpufreq_table.rows[2].temperature_scope == "package")
    assert(view.cpufreq_table.rows[3].temperature == "—")
    state.quality.sensors.status = "error"
    graph = Hardware.build(state)
    assert(graph.by_id["cpufreq:p0"].temperature == nil
        and #graph.by_id["core:0:-:0"].sensors == 0,
        "a retained failed sensor sample cannot create a current association")
    local failed_view = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "compute")
    assert(failed_view.cpufreq_table.rows[1].temperature == "—")
    state.quality.sensors = { status = "ok", quality = "fresh" }
    sensor.channels[2].input = nil
    graph = Hardware.build(state)
    assert(graph.by_id["cpufreq:p0"].temperature.scope == "package"
        and graph.by_id["cpufreq:p0"].temperature.celsius == 53,
        "a missing core reading may use a clearly labelled package reading")
    state.quality.cpu_info = { status = "ok", quality = "stale" }
    graph = Hardware.build(state)
    assert(graph.by_id["cpufreq:p0"].temperature == nil)
    state.quality.cpu_info = nil
    state.quality.cpu_frequency = { status = "denied", quality = "denied" }
    graph = Hardware.build(state)
    assert(graph.by_id["cpufreq:p0"].temperature == nil)
    state.quality.cpu_frequency = nil
    state.sensors.devices[2] = { id = "duplicate-coretemp", name = "coretemp",
        channels = { { type = "temperature", label = "Package id 0", input = 42 } } }
    graph = Hardware.build(state)
    assert(graph.by_id["cpufreq:p1"].temperature == nil,
        "ambiguous coretemp devices cannot supply a policy temperature")
end

do
    local Hardware = require("wtop.model.hardware")
    local TUI = require("wtop.tui")
    local I18n = require("wtop.i18n")
    local cpu = { topology = { quality = "fresh", logical_cpus = {
        { id = 0, package_id = 0, package_id_known = true, core_id = 2,
          core_id_known = true, core_key = "0:-:2" },
        { id = 1, package_id = 0, package_id_known = true, core_id = 2,
          core_id_known = true, core_key = "0:-:2" },
        { id = 2, package_id = 1, package_id_known = true, core_id = 2,
          core_id_known = true, core_key = "1:-:2" },
    } } }
    local thermal = { cpus = {
        { id = 0, core_count = 12, package_count = 100, core_new = 2,
          package_new = 1, core_delta_quality = "fresh", package_delta_quality = "fresh",
          core_total_time_ms = 0, package_total_time_ms = 0 },
        { id = 1, core_count = 12, package_count = 100, core_new = 2,
          package_new = 1, core_delta_quality = "fresh", package_delta_quality = "fresh" },
        { id = 2, core_count = 3, package_count = 20, core_delta_quality = "gap",
          package_delta_quality = "gap" },
    } }
    local state = { cpu_info = cpu, thermal_throttle = thermal,
        quality = { thermal_throttle = { status = "ok", quality = "fresh" } } }
    local graph = Hardware.build(state)
    assert(#graph.by_id["package:0"].thermal_throttle_cpu_ids == 2)
    assert(#graph.by_id["core:0:-:2"].thermal_throttle_cpu_ids == 2)
    assert(graph.by_id["cpu:0"].thermal_throttle == thermal.cpus[1])
    assert(graph.by_id["package:1"].thermal_throttle_cpu_ids[1] == 2)
    local exported = Export.snapshot(state).inventory.topology.nodes
    local package_ref
    for _, node in ipairs(exported) do
        if node.id == "package:0" then package_ref = node end
    end
    assert(package_ref and #package_ref.thermal_throttle_cpu_ids == 2)
    local detail = table.concat(TUI.hardware_detail_lines(state, "package:0",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(detail:find("Thermal throttling per CPU", 1, true))
    assert(detail:find("cpu0 · Core total 12 (+2)", 1, true))
    assert(detail:find("cpu1 · Core total 12 (+2)", 1, true))
    assert(not detail:find("cpu2 · Core total", 1, true))
    thermal.cpus[4] = { id = 0, core_count = 999, package_count = 999 }
    graph = Hardware.build(state)
    assert(graph.partial and #graph.by_id["package:0"].thermal_throttle_cpu_ids == 1)
    state.quality.thermal_throttle.status = "denied"
    graph = Hardware.build(state)
    assert(#graph.by_id["package:0"].thermal_throttle_cpu_ids == 0,
        "a retained counter must not appear in current device details after a failed read")
    local idle = { driver = "intel_idle", governor = "menu", cpus = {
        { id = 0, states = {
            { id = 0, name = "POLL", usage_delta = 4, usage_delta_quality = "fresh",
              new_time_us = 1500, time_delta_quality = "fresh", exit_latency_us = 0,
              target_residency_us = 0, disabled = false,
              rejected_delta = 2, rejected_delta_quality = "fresh",
              above_delta = 4, above_delta_quality = "fresh",
              below_delta = 5, below_delta_quality = "fresh" },
            { id = 1, name = "C1", usage_delta_quality = "reset",
              time_delta_quality = "reset", exit_latency_us = 1,
              target_residency_us = 10, disabled = false },
        } },
        { id = 1, states = { { id = 0, name = "POLL", usage_delta = 1,
            usage_delta_quality = "fresh", new_time_us = 20,
            time_delta_quality = "fresh" } } },
        { id = 2, states = { { id = 0, name = "POLL", usage_delta = 2,
            usage_delta_quality = "fresh", new_time_us = 40,
            time_delta_quality = "fresh" } } },
    } }
    state.cpuidle = idle
    state.quality.cpuidle = { status = "ok", quality = "fresh" }
    graph = Hardware.build(state)
    assert(#graph.by_id["package:0"].cpuidle_cpu_ids == 2)
    assert(#graph.by_id["core:0:-:2"].cpuidle_cpu_ids == 2)
    assert(graph.by_id["cpu:0"].cpuidle == idle.cpus[1])
    assert(graph.by_id["package:1"].cpuidle_cpu_ids[1] == 2)
    local idle_export = Export.snapshot(state).inventory.topology.nodes
    local idle_package
    for _, node in ipairs(idle_export) do
        if node.id == "package:0" then idle_package = node end
    end
    assert(idle_package and #idle_package.cpuidle_cpu_ids == 2)
    local package_detail = table.concat(TUI.hardware_detail_lines(state, "package:0",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(package_detail:find("CPUs reporting idle states: 2", 1, true))
    assert(not package_detail:find("POLL · Usage", 1, true),
        "package detail must not aggregate per-CPU state time")
    local cpu_detail = table.concat(TUI.hardware_detail_lines(state, "cpu:0",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(cpu_detail:find("POLL · Usage Δ: 4 · Reported ms Δ: 1.5", 1, true))
    assert(cpu_detail:find("Rejected Δ: 2 · Too short Δ: 4 · Deeper fit Δ: 5", 1, true))
    assert(cpu_detail:find("C1 · Usage Δ: Reset", 1, true))
    local _, diagnostic_lines = cpu_detail:gsub("Rejected Δ", "")
    assert(diagnostic_lines == 1,
        "states without optional diagnostics must not gain a line of unavailable values")
    idle.cpus[4] = { id = 0, states = { { id = 0, name = "wrong" } } }
    graph = Hardware.build(state)
    assert(graph.partial and #graph.by_id["package:0"].cpuidle_cpu_ids == 1)
    state.quality.cpuidle.status = "denied"
    graph = Hardware.build(state)
    assert(#graph.by_id["package:0"].cpuidle_cpu_ids == 0)
    local denied_detail = table.concat(TUI.hardware_detail_lines(state, "cpu:0",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(not denied_detail:find("CPU idle states", 1, true),
        "retained idle counters must not appear after a failed sample")
    state.quality.cpuidle.status = "ok"
    state.quality.cpuidle.quality = "stale"
    state.quality.thermal_throttle.status = "ok"
    state.quality.thermal_throttle.quality = "stale"
    graph = Hardware.build(state)
    assert(#graph.by_id["package:0"].cpuidle_cpu_ids == 0)
    assert(#graph.by_id["package:0"].thermal_throttle_cpu_ids == 0,
        "stale counter samples must not reappear as current device data")
end

do
    local Thermal = require("wtop.collectors.thermal_throttle")
    local Fixture = require("support.fixture_fs")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local root = "/sys/devices/system/cpu"
    local files = {}
    local function set_cpu(id, core, package, time_ms)
        local path = root .. "/cpu" .. id .. "/thermal_throttle/"
        files[path .. "core_throttle_count"] = tostring(core) .. "\n"
        files[path .. "package_throttle_count"] = tostring(package) .. "\n"
        files[path .. "core_throttle_total_time_ms"] = tostring(time_ms) .. "\n"
        files[path .. "package_throttle_total_time_ms"] = tostring(time_ms) .. "\n"
        files[path .. "core_throttle_max_time_ms"] = "0\n"
        files[path .. "package_throttle_max_time_ms"] = "0\n"
    end
    -- cpu0 and cpu1 receive the same package event notification. Summing their
    -- package counters would report one hardware event twice.
    set_cpu(0, 12, 100, 0)
    set_cpu(1, 7, 100, 0)
    set_cpu(2, 3, 20, 0)
    local fs = Fixture.new({ files = files })
    local capped = Thermal.new({ fs = fs, max_cpus = 2 }):sample({})
    assert(capped.quality == "partial" and capped.data.truncated and #capped.data.cpus == 2)
    local thermal = Thermal.new({ fs = fs, max_cpus = 3 })
    assert(thermal:probe({}).available)
    local first = thermal:sample({})
    assert(first.status == "ok" and first.quality == "fresh" and not first.data.truncated)
    assert(#first.data.cpus == 3 and first.data.cpus[1].core_delta_quality == "gap")
    assert(first.data.cpus[1].core_new == nil and first.data.cpus[1].core_total_time_ms == 0)
    set_cpu(0, 14, 101, 0)
    set_cpu(1, 9, 101, 0)
    set_cpu(2, 3, 23, 0)
    local second = thermal:sample({})
    assert(second.data.cpus[1].core_new == 2 and second.data.cpus[1].package_new == 1)
    assert(second.data.cpus[2].core_new == 2 and second.data.cpus[2].package_new == 1)
    assert(second.data.cpus[3].core_new == 0 and second.data.cpus[3].package_new == 3)
    local state = Snapshot.merge(nil, { thermal_throttle = second }, 1, 1)
    local exported = Export.snapshot(state)
    assert(exported.thermal_throttle.cpus[1].core_count == 14)
    assert(exported.thermal_throttle.cpus[1].package_new == 1)
    local agent = Export.agent(state)
    assert(agent.metrics.cpu.thermal_throttle.maximum_core_new_events_per_cpu == 2)
    assert(agent.metrics.cpu.thermal_throttle.maximum_package_new_events_per_cpu == 3)
    local view = ViewModel.build({ history_values = function() return {} end }, state,
        assert(I18n.new({ locale = "en-US" })), {}, "compute")
    assert(#view.thermal_throttle_table.rows == 3)
    assert(view.thermal_throttle_table.rows[1].core_new == "2")
    assert(view.thermal_throttle_table.rows[1].package_new == "1")
    -- A reset removes the interval value; lifetime counts still remain visible.
    set_cpu(0, 1, 1, 0)
    local reset = thermal:sample({})
    assert(reset.data.cpus[1].core_delta_quality == "reset")
    assert(reset.data.cpus[1].core_new == nil and reset.data.cpus[1].core_count == 1)
    files[root .. "/cpu1/thermal_throttle/package_throttle_count"] = "bad\n"
    local damaged = thermal:sample({})
    assert(damaged.quality == "partial" and damaged.reason == "thermal_throttle_data_incomplete")
    assert(damaged.data.cpus[2].package_count == nil)
    assert(damaged.data.cpus[2].package_delta_quality == "gap")
    local absent = Thermal.new({ fs = Fixture.new({ files = {} }) })
    assert(absent:probe({}).reason == "no_thermal_throttle_counters")
    assert(absent:sample({}).status == "unavailable")
    local cpu0 = root .. "/cpu0/thermal_throttle"
    local cpu1 = root .. "/cpu1/thermal_throttle"
    local only_counts = { [cpu1 .. "/core_throttle_count"] = "2\n",
        [cpu1 .. "/package_throttle_count"] = "4\n" }
    local mixed = Thermal.new({ fs = Fixture.new({ files = only_counts,
        denied = { [cpu0] = true } }) })
    assert(mixed:probe({}).available)
    assert(mixed:sample({}).quality == "partial")
    local denied = Thermal.new({ fs = Fixture.new({ denied = { [cpu0] = true } }) })
    assert(denied:probe({}).state == "denied")
    assert(denied:sample({}).status == "denied")
    local minimal = Thermal.new({ fs = Fixture.new({ files = only_counts }) })
    assert(minimal:sample({}).quality == "fresh",
        "older kernels may omit the duration files without losing event counts")
    only_counts[cpu1 .. "/core_throttle_count"] = "bad\n"
    only_counts[cpu1 .. "/package_throttle_count"] = "bad\n"
    assert(minimal:sample({}).status == "error",
        "a directory whose counters are all invalid does not contain usable data")
end

do
    local EDAC = require("wtop.collectors.edac")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local TUI = require("wtop.tui")
    local I18n = require("wtop.i18n")
    local JSON = require("wtop.format.json")
    local root = "/sys/devices/system/edac/mc"
    local mc = root .. "/mc0"
    local dimm = mc .. "/dimm0"
    local rank = mc .. "/rank1"
    local fs = Fixture.new({ files = {
        [mc .. "/mc_name"] = "i10nm\n",
        [mc .. "/ce_count"] = "12\n", [mc .. "/ue_count"] = "0\n",
        [dimm .. "/dimm_label"] = "DIMM_A1\n",
        [dimm .. "/dimm_location"] = "channel 0 slot 1\n",
        [dimm .. "/dimm_ce_count"] = "7\n", [dimm .. "/dimm_ue_count"] = "0\n",
        [rank .. "/dimm_label"] = "RANK_B\n",
        [rank .. "/dimm_location"] = "csrow 1 channel 0\n",
        [rank .. "/dimm_ce_count"] = "2\n", [rank .. "/dimm_ue_count"] = "0\n",
    } })
    local collector = EDAC.new({ fs = fs })
    assert(collector:probe({}).available)
    local result = collector:sample({})
    assert(result.status == "ok" and result.quality == "fresh")
    assert(result.data.controllers[1].correctable_errors == 12)
    assert(result.data.controllers[1].modules[1].correctable_errors == 7)
    assert(result.data.controllers[1].modules[2].kind == "rank")
    local state = Snapshot.merge(nil, { edac = result }, 1, 1)
    local graph = Hardware.build(state)
    assert(graph.by_id["edac:mc0/dimm0"].parent_id == "edac:mc0")
    local exported = Export.snapshot(state)
    assert(exported.edac.controllers[1].modules[1].label == "DIMM_A1")
    assert(exported.inventory.topology.nodes and #exported.inventory.topology.nodes == 3)
    local detail = table.concat(TUI.hardware_detail_lines(state, "edac:mc0/dimm0",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(detail:find("Correctable errors: 7", 1, true))
    assert(detail:find("Uncorrectable errors: 0", 1, true))
    assert(not JSON.encode(exported):find("dimm_label", 1, true))
    local linked = { memory_devices = { devices = {
        { id = "1100", locator = "dimm_a1", populated = true },
        { id = "1101", locator = "RANK_B", populated = true },
    } }, edac = result.data }
    local linked_graph = Hardware.build(linked)
    local slot = linked_graph.by_id["dimm:1100"]
    local module = linked_graph.by_id["edac:mc0/dimm0"]
    assert(slot.edac_module_id == module.id and module.memory_device_id == slot.id)
    assert(slot.match_method == "unique_label" and module.match_method == "unique_label")
    local slot_refs = Hardware.related(linked_graph, slot.id)
    local module_refs = Hardware.related(linked_graph, module.id)
    assert(slot_refs.total == 1 and slot_refs.items[1].id == module.id
        and slot_refs.items[1].relation == "edac_module_id")
    assert(module_refs.total == 1 and module_refs.items[1].id == slot.id)
    assert(module.parent_id == "edac:mc0", "a label reference must not replace the controller parent")
    assert(not linked_graph.by_id["dimm:1101"].edac_module_id,
        "a rank label must not identify a DIMM")
    local linked_export = Export.snapshot(linked).inventory.topology.nodes
    assert(by_id(linked_export, slot.id).edac_module_id == module.id)
    assert(by_id(linked_export, module.id).memory_device_id == slot.id)
    local slot_detail = table.concat(TUI.hardware_detail_lines(linked, slot.id,
        assert(I18n.new({ locale = "en-US" }))), "\n")
    local module_detail = table.concat(TUI.hardware_detail_lines(linked, module.id,
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(slot_detail:find("Same-label EDAC module", 1, true)
        and module_detail:find("Same-label firmware slot", 1, true)
        and module_detail:find("physical identity is not verified", 1, true))
    linked.memory_devices.devices[3] = { id = "1102", locator = "DIMM_A1", populated = true }
    local duplicate = Hardware.build(linked)
    assert(not duplicate.by_id[slot.id].edac_module_id
        and not duplicate.by_id[module.id].memory_device_id,
        "duplicate firmware labels must not claim one EDAC module")
    linked.memory_devices.devices[3].populated = false
    assert(not Hardware.build(linked).by_id[slot.id].edac_module_id,
        "an empty slot with the same label still makes the label ambiguous")
    linked.memory_devices.devices[3] = nil
    linked.edac = { controllers = { { id = "mc0", modules = {
        { id = "mc0/dimm0", kind = "dimm", label = "DIMM_A1" },
        { id = "mc0/dimm1", kind = "dimm", label = "dimm_a1" },
    } } } }
    duplicate = Hardware.build(linked)
    assert(not duplicate.by_id[slot.id].edac_module_id,
        "duplicate EDAC labels must not claim one firmware slot")
    linked.edac.controllers[1].modules[2].kind = "rank"
    assert(not Hardware.build(linked).by_id[slot.id].edac_module_id,
        "a rank with the same label still makes EDAC's label ambiguous")
    linked.edac = result.data
    linked.memory_devices.devices[1].populated = false
    assert(not Hardware.build(linked).by_id[slot.id].edac_module_id)
    linked.memory_devices.devices[1].populated = true
    linked.memory_devices.truncated = true
    assert(not Hardware.build(linked).by_id[slot.id].edac_module_id,
        "a capped firmware list cannot prove label uniqueness")
    linked.memory_devices.truncated = nil
    linked.quality = { edac = { status = "ok", quality = "stale" } }
    assert(not Hardware.build(linked).by_id[slot.id].edac_module_id,
        "stale EDAC data must not be linked to a current firmware slot")
    local bounded = Hardware.related({ by_id = {
        root = { id = "root", children = { { id = "first" }, { id = "second" },
            { id = "ambiguous" }, { id = "missing" } } },
        first = { id = "first" }, second = { id = "second" },
        ambiguous = { id = "ambiguous", ambiguous = true },
    } }, "root", 1)
    assert(bounded.total == 2 and bounded.truncated
        and bounded.items[1].id == "first",
        "related-device picker caps valid targets without inventing ambiguous or missing ones")
    local damaged = Fixture.new({ files = {
        [mc .. "/mc_name"] = "i10nm\n", [mc .. "/ce_count"] = "bad\n",
        [mc .. "/ue_count"] = "0\n", [dimm .. "/dimm_label"] = "DIMM_A1\n",
        [dimm .. "/dimm_location"] = "channel 0 slot 1\n",
        [dimm .. "/dimm_ce_count"] = "9007199254740992\n",
    } })
    result = EDAC.new({ fs = damaged }):sample({})
    assert(result.status == "ok" and result.quality == "partial")
    assert(result.reason == "edac_data_incomplete")
    assert(result.data.controllers[1].correctable_errors == nil)
    assert(#result.data.controllers[1].modules[1].issues == 2)
    assert(EDAC.new({ fs = Fixture.new({ dirs = { [root] = {} } }) }):sample({}).status == "unavailable")
    assert(EDAC.new({ fs = Fixture.new({ denied = { [root] = true } }) }):probe({}).state == "denied")
    assert(not pcall(EDAC.new, { max_controllers = 0 }))
end

do
    local SPD = require("wtop.collectors.spd")
    local Decoder = require("wtop.format.spd")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local I18n = require("wtop.i18n")
    local JSON = require("wtop.format.json")
    local TUI = require("wtop.tui")
    local root = "/sys/bus/i2c/devices"
    local path = root .. "/13-0050"
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local blob = string.rep("\0", 1024)
    blob = put(blob, 0, "\48\16\18\3")
    blob = put(blob, 20, string.pack("<I2", 357))
    blob = put(blob, 517, "LEAK")
    blob = put(blob, 521, "TEST-DDR5" .. string.rep(" ", 21))
    local crc = 0
    for index = 1, 510 do
        crc = crc ~ (blob:byte(index) << 8)
        for _ = 1, 8 do
            crc = ((crc << 1) ~ (crc & 0x8000 ~= 0 and 0x1021 or 0)) & 0xffff
        end
    end
    blob = put(blob, 510, string.pack("<I2", crc))
    local parsed = assert(Decoder.parse(blob))
    assert(parsed.crc_valid and parsed.part_number == "TEST-DDR5")
    assert(parsed.module_type == "SO-DIMM" and parsed.minimum_cycle_ps == 357)
    assert(Decoder.parse(put(blob, 2, "\12")) == nil)
    local fs = Fixture.new({ files = {
        [path .. "/name"] = "spd5118\n", [path .. "/eeprom"] = blob,
        [root .. "/13-0051/name"] = "unrelated\n",
    } })
    local collector = SPD.new({ fs = fs })
    assert(collector:probe({}).available)
    local result = collector:sample({})
    assert(result.status == "ok" and result.quality == "fresh")
    assert(#result.data.devices == 1 and result.data.devices[1].bytes_read == 1024)
    local state = Snapshot.merge(nil, { spd = result, hwmon = {
        status = "ok", quality = "fresh", data = { devices = { {
            id = "spd5118@test", name = "spd5118", device_target = "../../../13-0050",
            identity_quality = "fresh", channels = { {
                id = "temperature:1", type = "temperature", label = "temp1", input = 40,
            } },
        } } },
    } }, 1, 1)
    local node = Hardware.build(state).by_id["spd:13-0050"]
    assert(node and #node.sensors == 1 and node.sensors[1].channels[1].input == 40)
    local duplicate_sensors = Hardware.build({ spd = result.data, sensors = { devices = {
        { id = "a", name = "spd5118", device_target = "../../../13-0050" },
        { id = "b", name = "spd5118", device_target = "../../../13-0050" },
    } } })
    assert(#duplicate_sensors.by_id["spd:13-0050"].sensors == 0)
    local exported = Export.snapshot(state)
    assert(exported.spd.devices[1].part_number == "TEST-DDR5")
    assert(exported.inventory.topology.nodes[1].sensor_ids[1] == "spd5118@test")
    assert(not JSON.encode(exported):find("LEAK", 1, true))
    local details = table.concat(TUI.hardware_detail_lines(state, "spd:13-0050",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(details:find("SO-DIMM", 1, true) and details:find("357 ps", 1, true))
    assert(details:find("Related sensors: 1", 1, true))
    assert(not details:find("LEAK", 1, true))
    local partial_fs = Fixture.new({ files = {
        [path .. "/name"] = "spd5118\n", [path .. "/eeprom"] = blob,
    } })
    local base_read_at = partial_fs.read_at
    function partial_fs:read_at(file, offset, length)
        if offset >= 128 then return nil,
            { kind = "io_error", message = "page_unavailable", path = file } end
        return base_read_at(self, file, offset, length)
    end
    local partial = SPD.new({ fs = partial_fs }):sample({})
    assert(partial.quality == "partial" and partial.reason == "spd_data_incomplete")
    assert(partial.data.devices[1].bytes_read == 128)
    assert(partial.data.devices[1].memory_type == "DDR5")
    assert(partial.data.devices[1].issues[1].offset == 128)
    assert(partial.data.devices[1].issues[1].reason == "spd_data_incomplete")
    assert(Export.snapshot(Snapshot.merge(nil, { spd = partial }, 1, 1))
        .spd.devices[1].issues[1].offset == 128)
    local broken = put(blob, 20, "\0\0")
    local damaged = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "spd5118\n", [path .. "/eeprom"] = broken,
    } }) }):sample({})
    assert(damaged.quality == "partial" and damaged.data.devices[1].crc_valid == false)
    local cut = SPD.new({ fs = Fixture.new({ dirs = { [root] = {} },
        truncated = { [root] = true } }) })
    assert(cut:probe({}).reason == "spd_scan_truncated")
    assert(cut:sample({}).reason == "spd_scan_truncated")
    local denied = SPD.new({ fs = Fixture.new({ dirs = { [root] = { "13-0050" } },
        denied = { [path .. "/name"] = true } }) })
    assert(denied:probe({}).state == "denied")
    assert(denied:sample({}).reason == "spd_access_denied")
    assert(not pcall(SPD.new, { max_devices = 0 }))
end

do
    local SPD = require("wtop.collectors.spd")
    local Decoder = require("wtop.format.spd")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local root = "/sys/bus/i2c/devices"
    local path = root .. "/14-0053"
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function crc(data, first, length)
        local value = 0
        for index = first, first + (length or 126) - 1 do
            value = value ~ (data:byte(index) << 8)
            for _ = 1, 8 do
                value = ((value << 1) ~ (value & 0x8000 ~= 0 and 0x1021 or 0)) & 0xffff
            end
        end
        return value
    end
    local blob = string.rep("\0", 512)
    blob = put(blob, 0, "\35\17\12\3")
    blob = put(blob, 4, "\5")
    blob = put(blob, 12, "\9\11")
    blob = put(blob, 14, "\128")
    blob = put(blob, 18, "\5")
    blob = put(blob, 128, "\42")
    blob = put(blob, 325, "LEAK")
    blob = put(blob, 329, "DDR4-TEST" .. string.rep(" ", 11))
    assert(crc(blob, 1) == 0x1c9f and crc(blob, 129) == 0x2d86,
        "DDR4 CRC fixture agrees with an independent CRC-16/XMODEM calculation")
    blob = put(blob, 126, string.pack("<I2", crc(blob, 1)))
    blob = put(blob, 254, string.pack("<I2", crc(blob, 129)))
    local decoded = assert(Decoder.parse(blob))
    assert(decoded.memory_type == "DDR4" and decoded.module_type == "SO-DIMM")
    assert(decoded.revision == "1.1" and decoded.minimum_cycle_ps == 625)
    assert(decoded.size_bytes == 16 * 1024^3 and decoded.rank == 2)
    assert(decoded.data_width_bits == 64 and decoded.total_width_bits == 72)
    assert(decoded.temperature_sensor_present and decoded.crc_valid and decoded.complete)
    assert(decoded.part_number == "DDR4-TEST")
    assert(Decoder.parse(put(blob, 0, "\0")) == nil)
    local short_coverage = put(blob, 0, "\163")
    short_coverage = put(short_coverage, 126,
        string.pack("<I2", crc(short_coverage, 1, 117)))
    assert(Decoder.parse(short_coverage).crc_base_valid,
        "DDR4 header bit 7 selects CRC coverage through byte 116")
    local collector = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "ee1004\n", [path .. "/eeprom"] = blob,
    } }) })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok" and result.quality == "fresh")
    assert(result.data.devices[1].bytes_read == 512 and result.data.devices[1].driver == "ee1004")
    local sensor = { id = "jc42@test", name = "jc42", device_target = "../../../14-001b",
        identity_quality = "fresh", channels = { {
            id = "temperature:1", type = "temperature", input = 42,
        } } }
    local state = Snapshot.merge(nil, { spd = result, hwmon = {
        status = "ok", quality = "fresh", data = { devices = { sensor } },
    } }, 1, 1)
    local node = Hardware.build(state).by_id["spd:14-0053"]
    assert(node and #node.sensors == 1 and node.sensors[1].channels[1].input == 42)
    local exported = Export.snapshot(state)
    assert(exported.spd.devices[1].temperature_sensor_present == true)
    assert(exported.spd.devices[1].size_bytes == 16 * 1024^3)
    assert(exported.inventory.topology.nodes[1].sensor_ids[1] == "jc42@test")
    assert(not JSON.encode(exported):find("LEAK", 1, true))
    local details = table.concat(TUI.hardware_detail_lines(state, "spd:14-0053",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(details:find("DDR4-TEST", 1, true) and details:find("625 ps", 1, true))
    assert(details:find("Base SPD CRC valid", 1, true))
    assert(not details:find("LEAK", 1, true))
    sensor.device_target = "../../../14-001a"
    assert(#Hardware.build(state).by_id["spd:14-0053"].sensors == 0)
    sensor.device_target = "../../../14-001b"
    local no_flag = put(blob, 14, "\0")
    no_flag = put(no_flag, 126, string.pack("<I2", crc(no_flag, 1)))
    local no_flag_result = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "ee1004\n", [path .. "/eeprom"] = no_flag,
    } }) }):sample({})
    assert(not no_flag_result.data.devices[1].temperature_sensor_present)
    assert(#Hardware.build({ spd = no_flag_result.data, sensors = { devices = { sensor } } })
        .by_id["spd:14-0053"].sensors == 0)
    local rev10 = put(no_flag, 1, "\16")
    rev10 = put(rev10, 126, string.pack("<I2", crc(rev10, 1)))
    local rev10_result = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "ee1004\n", [path .. "/eeprom"] = rev10,
    } }) }):sample({})
    assert(#Hardware.build({ spd = rev10_result.data, sensors = { devices = { sensor } } })
        .by_id["spd:14-0053"].sensors == 1)
    local damaged = put(blob, 128, "\43")
    assert(Decoder.parse(damaged).crc_valid == false)
    assert(Decoder.parse(put(blob, 14, "\0")).crc_base_valid == false)
    assert(Decoder.parse(put(blob, 4, "\6")).size_bytes == nil,
        "a bad base CRC cannot publish a plausible but unsupported capacity")
    local stacked = put(blob, 6, "\128")
    stacked = put(stacked, 126, string.pack("<I2", crc(stacked, 1)))
    assert(Decoder.parse(stacked).size_bytes == nil,
        "the monolithic density formula does not describe 3DS packages")
end

do
    local SPD = require("wtop.collectors.spd")
    local Decoder = require("wtop.format.spd")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local I18n = require("wtop.i18n")
    local JSON = require("wtop.format.json")
    local TUI = require("wtop.tui")
    local path = "/sys/bus/i2c/devices/9-0056"
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function crc(data, length)
        local value = 0
        for index = 1, length do
            value = value ~ (data:byte(index) << 8)
            for _ = 1, 8 do
                value = ((value << 1) ~ (value & 0x8000 ~= 0 and 0x1021 or 0)) & 0xffff
            end
        end
        return value
    end
    local blob = string.rep("\0", 256)
    blob = put(blob, 0, "\146\17\11\3\4")
    blob = put(blob, 7, "\9\11\17\1\8\10")
    blob = put(blob, 32, "\128")
    blob = put(blob, 34, "\254")
    blob = put(blob, 122, "LEAK")
    blob = put(blob, 128, "DDR3-TEST" .. string.rep(" ", 9))
    assert(crc(blob, 117) == 0xa084,
        "DDR3 CRC fixture agrees with an independent CRC-16/XMODEM calculation")
    blob = put(blob, 126, string.pack("<I2", crc(blob, 117)))
    local decoded = assert(Decoder.parse(blob))
    assert(decoded.memory_type == "DDR3" and decoded.module_type == "SO-DIMM")
    assert(decoded.crc_valid and decoded.complete and decoded.revision == "1.1")
    assert(decoded.minimum_cycle_ps == 1248 and decoded.temperature_sensor_present)
    assert(decoded.size_bytes == 8 * 1024^3 and decoded.rank == 2)
    assert(decoded.data_width_bits == 64 and decoded.total_width_bits == 72)
    assert(decoded.part_number == "DDR3-TEST")
    local fs = Fixture.new({ files = {
        [path .. "/name"] = "spd\n", [path .. "/eeprom"] = blob,
    } })
    local collector = SPD.new({ fs = fs })
    local sample = collector:sample({})
    assert(collector:probe({}).available and sample.quality == "fresh")
    assert(sample.data.devices[1].bytes_read == 256 and sample.data.devices[1].driver == "spd")
    local sensor = { id = "jc42@9-001e", name = "jc42", device_target = "../../../9-001e",
        identity_quality = "fresh", channels = { {
            id = "temperature:1", type = "temperature", input = 37,
        } } }
    local state = Snapshot.merge(nil, { spd = sample, hwmon = {
        status = "ok", quality = "fresh", data = { devices = { sensor } },
    } }, 1, 1)
    local node = Hardware.build(state).by_id["spd:9-0056"]
    assert(node and #node.sensors == 1 and node.sensors[1].channels[1].input == 37)
    local exported = Export.snapshot(state)
    assert(exported.spd.devices[1].size_bytes == 8 * 1024^3)
    assert(exported.inventory.topology.nodes[1].sensor_ids[1] == "jc42@9-001e")
    assert(not JSON.encode(exported):find("LEAK", 1, true))
    local detail = table.concat(TUI.hardware_detail_lines(state, "spd:9-0056",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(detail:find("DDR3-TEST", 1, true) and detail:find("1248 ps", 1, true))
    assert(not detail:find("LEAK", 1, true))
    local no_sensor = put(blob, 32, "\0")
    no_sensor = put(no_sensor, 126, string.pack("<I2", crc(no_sensor, 117)))
    local no_sensor_data = assert(Decoder.parse(no_sensor))
    assert(not no_sensor_data.temperature_sensor_present)
    assert(#Hardware.build({ spd = { devices = { {
        id = "9-0056", driver = "spd", memory_type = "DDR3",
        crc_base_valid = true, temperature_sensor_present = false,
    } } }, sensors = { devices = { sensor } } }).by_id["spd:9-0056"].sensors == 0)
    local corrupt = put(blob, 4, "\5")
    assert(Decoder.parse(corrupt).crc_valid == false)
    local short_fs = Fixture.new({ files = {
        [path .. "/name"] = "spd\n", [path .. "/eeprom"] = blob,
    } })
    local original = short_fs.read_at
    function short_fs:read_at(file, offset, length)
        if offset >= 128 then return nil,
            { kind = "io_error", message = "second_page_unavailable", path = file } end
        return original(self, file, offset, length)
    end
    local partial = SPD.new({ fs = short_fs }):sample({})
    assert(partial.quality == "partial" and partial.data.devices[1].bytes_read == 128)
    assert(partial.data.devices[1].part_number == nil and partial.data.devices[1].crc_valid)
end

do
    local SPD = require("wtop.collectors.spd")
    local Decoder = require("wtop.format.spd")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local I18n = require("wtop.i18n")
    local JSON = require("wtop.format.json")
    local TUI = require("wtop.tui")
    local path = "/sys/bus/i2c/devices/7-0051"
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function checksum(data)
        local value = 0
        for index = 1, 63 do value = (value + data:byte(index)) % 256 end
        return value
    end
    local blob = string.rep("\0", 256)
    blob = put(blob, 0, "\128\8\8")
    blob = put(blob, 5, "\97\72")
    blob = put(blob, 9, "\37")
    blob = put(blob, 11, "\2")
    blob = put(blob, 14, "\8")
    blob = put(blob, 20, "\1")
    blob = put(blob, 31, "\2")
    blob = put(blob, 62, "\19")
    assert(checksum(blob) == 0x7e, "DDR2 fixture has an independently calculated checksum")
    blob = put(blob, 63, string.char(checksum(blob)))
    blob = put(blob, 73, "DDR2-TEST" .. string.rep(" ", 9))
    blob = put(blob, 95, "LEAK")
    local decoded = assert(Decoder.parse(blob))
    assert(decoded.memory_type == "DDR2" and decoded.module_type == "RDIMM")
    assert(decoded.revision == "1.3" and decoded.checksum_valid and decoded.complete)
    assert(decoded.rank == 2 and decoded.size_bytes == 4 * 1024^3)
    assert(decoded.data_width_bits == 64 and decoded.total_width_bits == 72)
    assert(decoded.minimum_cycle_ps == 2500 and decoded.part_number == "DDR2-TEST")
    local short_base = assert(Decoder.parse(blob:sub(1, 64)))
    assert(short_base.checksum_valid and short_base.size_bytes == 4 * 1024^3
        and short_base.part_number == nil and short_base.complete == false)
    local fractional = put(blob, 9, "\61")
    fractional = put(fractional, 63, string.char(checksum(fractional)))
    assert(Decoder.parse(fractional).minimum_cycle_ps == 3750)
    local fs = Fixture.new({ files = {
        [path .. "/name"] = "spd\n", [path .. "/eeprom"] = blob,
    } })
    local collector = SPD.new({ fs = fs })
    local sample = collector:sample({})
    assert(collector:probe({}).available and sample.quality == "fresh")
    assert(sample.data.devices[1].driver == "spd" and sample.data.devices[1].bytes_read == 256)
    local old_driver = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "eeprom\n", [path .. "/eeprom"] = blob,
    } }) })
    assert(old_driver:probe({}).available
        and old_driver:sample({}).data.devices[1].memory_type == "DDR2")
    local state = Snapshot.merge(nil, { spd = sample }, 1, 1)
    local exported = Export.snapshot(state)
    assert(exported.spd.devices[1].checksum_valid and exported.spd.devices[1].size_bytes == 4 * 1024^3)
    assert(not JSON.encode(exported):find("LEAK", 1, true))
    local sensor = { id = "jc42@7-0019", name = "jc42",
        device_target = "../../../7-0019", identity_quality = "fresh",
        channels = { { id = "temperature:1", type = "temperature", input = 40 } } }
    assert(#Hardware.build({ spd = sample.data, sensors = { devices = { sensor } } })
        .by_id["spd:7-0051"].sensors == 0)
    local detail = table.concat(TUI.hardware_detail_lines(state, "spd:7-0051",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(detail:find("DDR2-TEST", 1, true) and detail:find("SPD checksum valid", 1, true))
    assert(not detail:find("LEAK", 1, true))
    local invalid = put(blob, 9, "\38")
    local broken = assert(Decoder.parse(invalid))
    assert(broken.checksum_valid == false and broken.size_bytes == nil
        and broken.minimum_cycle_ps == nil)
    local damaged = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "spd\n", [path .. "/eeprom"] = invalid,
    } }) }):sample({})
    assert(damaged.quality == "partial" and damaged.data.devices[1].issues[1].reason
        == "spd_checksum_mismatch")
    assert(Export.snapshot(Snapshot.merge(nil, { spd = damaged }, 2, 1))
        .spd.devices[1].checksum_valid == false)
    local unsupported_density = put(blob, 31, "\3")
    unsupported_density = put(unsupported_density, 63,
        string.char(checksum(unsupported_density)))
    assert(Decoder.parse(unsupported_density).size_bytes == nil)
    local short_fs = Fixture.new({ files = {
        [path .. "/name"] = "spd\n", [path .. "/eeprom"] = blob,
    } })
    local original = short_fs.read_at
    function short_fs:read_at(file, offset, length)
        if offset >= 128 then return nil,
            { kind = "io_error", message = "second_page_unavailable", path = file } end
        return original(self, file, offset, length)
    end
    local partial = SPD.new({ fs = short_fs }):sample({})
    assert(partial.quality == "partial" and partial.data.devices[1].checksum_valid)
    assert(partial.data.devices[1].part_number == "DDR2-TEST"
        and partial.data.devices[1].complete == false)
end

do
    local SPD = require("wtop.collectors.spd")
    local Decoder = require("wtop.format.spd")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local I18n = require("wtop.i18n")
    local JSON = require("wtop.format.json")
    local TUI = require("wtop.tui")
    local path = "/sys/bus/i2c/devices/5-0052"
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function checksum(data)
        local value = 0
        for index = 1, 63 do value = (value + data:byte(index)) % 256 end
        return value
    end
    local blob = string.rep("\0", 256)
    blob = put(blob, 0, "\128\8\7")
    blob = put(blob, 5, "\2\72")
    blob = put(blob, 9, "\117")
    blob = put(blob, 11, "\2")
    blob = put(blob, 14, "\8")
    blob = put(blob, 21, "\38")
    blob = put(blob, 31, "\128")
    blob = put(blob, 62, "\18")
    assert(checksum(blob) == 0x10, "DDR fixture has an independently calculated checksum")
    blob = put(blob, 63, string.char(checksum(blob)))
    blob = put(blob, 73, "DDR-TEST" .. string.rep(" ", 10))
    blob = put(blob, 95, "LEAK")
    local decoded = assert(Decoder.parse(blob))
    assert(decoded.memory_type == "DDR" and decoded.module_type == "Registered")
    assert(decoded.revision == "1.2" and decoded.checksum_valid and decoded.complete)
    assert(decoded.rank == 2 and decoded.size_bytes == 1024^3)
    assert(decoded.data_width_bits == 64 and decoded.total_width_bits == 72)
    assert(decoded.minimum_cycle_ps == 7500 and decoded.part_number == "DDR-TEST")
    local fs = Fixture.new({ files = {
        [path .. "/name"] = "spd\n", [path .. "/eeprom"] = blob,
    } })
    local collector = SPD.new({ fs = fs })
    local sample = collector:sample({})
    assert(collector:probe({}).available and sample.quality == "fresh")
    local old_driver = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "eeprom\n", [path .. "/eeprom"] = blob,
    } }) })
    assert(old_driver:probe({}).available
        and old_driver:sample({}).data.devices[1].memory_type == "DDR")
    local state = Snapshot.merge(nil, { spd = sample }, 1, 1)
    local exported = Export.snapshot(state)
    assert(exported.spd.devices[1].size_bytes == 1024^3
        and exported.spd.devices[1].checksum_valid)
    assert(not JSON.encode(exported):find("LEAK", 1, true))
    local detail = table.concat(TUI.hardware_detail_lines(state, "spd:5-0052",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(detail:find("DDR-TEST", 1, true) and detail:find("7500 ps", 1, true))
    local sensor = { id = "jc42@5-001a", name = "jc42",
        device_target = "../../../5-001a", identity_quality = "fresh",
        channels = { { id = "temperature:1", type = "temperature", input = 40 } } }
    assert(#Hardware.build({ spd = sample.data, sensors = { devices = { sensor } } })
        .by_id["spd:5-0052"].sensors == 0)
    local damaged = put(blob, 9, "\118")
    assert(Decoder.parse(damaged).checksum_valid == false
        and Decoder.parse(damaged).size_bytes == nil)
    local damaged_sample = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "spd\n", [path .. "/eeprom"] = damaged,
    } }) }):sample({})
    assert(damaged_sample.quality == "partial"
        and damaged_sample.data.devices[1].issues[1].reason == "spd_checksum_mismatch")
    local short = assert(Decoder.parse(blob:sub(1, 64)))
    assert(short.checksum_valid and short.size_bytes == 1024^3
        and short.part_number == nil and short.complete == false)
    local short_fs = Fixture.new({ files = {
        [path .. "/name"] = "spd\n", [path .. "/eeprom"] = blob,
    } })
    local original = short_fs.read_at
    function short_fs:read_at(file, offset, length)
        if offset == 0 then return assert(original(self, file, offset, length)):sub(1, 64) end
        return original(self, file, offset, length)
    end
    local partial = SPD.new({ fs = short_fs }):sample({})
    assert(partial.quality == "partial" and partial.data.devices[1].bytes_read == 64)
    assert(partial.data.devices[1].memory_type == "DDR"
        and partial.data.devices[1].size_bytes == 1024^3)
end

do
    local SPD = require("wtop.collectors.spd")
    local Decoder = require("wtop.format.spd")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local I18n = require("wtop.i18n")
    local JSON = require("wtop.format.json")
    local TUI = require("wtop.tui")
    local path = "/sys/bus/i2c/devices/4-0050"
    local other = "/sys/bus/i2c/devices/4-0053"
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function checksum(data)
        local value = 0
        for index = 1, 63 do value = (value + data:byte(index)) % 256 end
        return value
    end
    local blob = string.rep("\0", 256)
    blob = put(blob, 0, "\128\8\4")
    blob = put(blob, 5, "\2\72")
    blob = put(blob, 9, "\160")
    blob = put(blob, 11, "\2")
    blob = put(blob, 14, "\4")
    blob = put(blob, 21, "\2")
    blob = put(blob, 31, "\8")
    blob = put(blob, 62, "\18")
    assert(checksum(blob) == 0x98, "SDR fixture has an independently calculated checksum")
    blob = put(blob, 63, string.char(checksum(blob)))
    blob = put(blob, 73, "SDR-TEST" .. string.rep(" ", 10))
    blob = put(blob, 95, "LEAK")
    local decoded = assert(Decoder.parse(blob))
    assert(decoded.memory_type == "SDR SDRAM" and decoded.module_type == "Registered")
    assert(decoded.revision == "1.2" and decoded.checksum_valid and decoded.complete)
    assert(decoded.rank == 2 and decoded.size_bytes == 64 * 1024^2)
    assert(decoded.data_width_bits == 64 and decoded.total_width_bits == 72,
        "x4 ECC device width does not mean a four-bit bus extension")
    assert(decoded.minimum_cycle_ps == 10000 and decoded.part_number == "SDR-TEST")
    local mixed = put(blob, 31, "\12")
    mixed = put(mixed, 63, string.char(checksum(mixed)))
    assert(Decoder.parse(mixed).size_bytes == 48 * 1024^2)
    local ambiguous = put(mixed, 5, "\3")
    ambiguous = put(ambiguous, 63, string.char(checksum(ambiguous)))
    assert(Decoder.parse(ambiguous).rank == 3
        and Decoder.parse(ambiguous).size_bytes == nil)
    local slow = put(blob, 9, "\240")
    slow = put(slow, 63, string.char(checksum(slow)))
    assert(Decoder.parse(slow).minimum_cycle_ps == 15000)
    local unprogrammed_part = put(blob, 0, "\64")
    unprogrammed_part = put(unprogrammed_part, 63,
        string.char(checksum(unprogrammed_part)))
    assert(Decoder.parse(unprogrammed_part).part_number == nil)
    local invalid = put(blob, 9, "\161")
    assert(Decoder.parse(invalid).checksum_valid == false
        and Decoder.parse(invalid).size_bytes == nil)
    local fs = Fixture.new({ files = {
        [path .. "/name"] = "eeprom\n", [path .. "/eeprom"] = blob,
        [other .. "/name"] = "eeprom\n", [other .. "/eeprom"] = string.rep("\0", 256),
    } })
    local collector = SPD.new({ fs = fs })
    local sample = collector:sample({})
    assert(collector:probe({}).available and sample.quality == "fresh")
    assert(#sample.data.devices == 1 and sample.data.devices[1].driver == "eeprom")
    assert(sample.data.devices[1].bytes_read == 256)
    local unrelated = SPD.new({ fs = Fixture.new({ files = {
        [other .. "/name"] = "eeprom\n", [other .. "/eeprom"] = string.rep("\0", 256),
    } }) })
    assert(unrelated:probe({}).state == "unavailable")
    local state = Snapshot.merge(nil, { spd = sample }, 1, 1)
    local exported = Export.snapshot(state)
    assert(exported.spd.devices[1].size_bytes == 64 * 1024^2)
    assert(not JSON.encode(exported):find("LEAK", 1, true))
    local detail = table.concat(TUI.hardware_detail_lines(state, "spd:4-0050",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(detail:find("SDR-TEST", 1, true) and detail:find("10000 ps", 1, true))
    local sensor = { id = "jc42@4-0018", name = "jc42",
        device_target = "../../../4-0018", identity_quality = "fresh",
        channels = { { id = "temperature:1", type = "temperature", input = 40 } } }
    assert(#Hardware.build({ spd = sample.data, sensors = { devices = { sensor } } })
        .by_id["spd:4-0050"].sensors == 0)
    local short = assert(Decoder.parse(blob:sub(1, 64)))
    assert(short.checksum_valid and short.size_bytes == 64 * 1024^2
        and short.part_number == nil and short.complete == false)
    local small = put(blob:sub(1, 128), 1, "\7")
    small = put(small, 63, string.char(checksum(small)))
    local small_path = "/sys/bus/i2c/devices/4-0051"
    local small_sample = SPD.new({ fs = Fixture.new({ files = {
        [small_path .. "/name"] = "eeprom\n", [small_path .. "/eeprom"] = small,
    } }) }):sample({})
    assert(small_sample.quality == "fresh" and small_sample.data.devices[1].complete)
    assert(small_sample.data.devices[1].bytes_read == 128)
    local damaged_sample = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "eeprom\n", [path .. "/eeprom"] = invalid,
    } }) }):sample({})
    assert(damaged_sample.quality == "partial"
        and damaged_sample.data.devices[1].issues[1].reason == "spd_checksum_mismatch")
end

do
    -- FPM/EDO uses address geometry, not the SDR byte-31 density bitmap.
    -- The checksum covers bytes 0-62; serial bytes stay out of every export.
    local SPD = require("wtop.collectors.spd")
    local Decoder = require("wtop.format.spd")
    local Fixture = require("support.fixture_fs")
    local I18n = require("wtop.i18n")
    local JSON = require("wtop.format.json")
    local TUI = require("wtop.tui")
    local path = "/sys/bus/i2c/devices/3-0050"
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function checksum(data)
        local value = 0
        for index = 1, 63 do value = (value + data:byte(index)) % 256 end
        return value
    end
    local function signed(data)
        return put(data, 63, string.char(checksum(data)))
    end
    local blob = string.rep("\0", 256)
    blob = put(blob, 0, "\128\8\2\11\9\2\36\0\1\60\15\1\0\9")
    blob = put(blob, 62, "\1")
    assert(checksum(blob) == 0x1b, "the EDO checksum is calculated independently")
    blob = signed(blob)
    blob = put(blob, 73, "EDO-TEST" .. string.rep(" ", 10))
    blob = put(blob, 95, "LEAK")
    local edo = assert(Decoder.parse(blob))
    assert(edo.memory_type == "EDO DRAM" and edo.revision == "1"
        and edo.checksum_valid and edo.complete and edo.module_banks == 2)
    assert(edo.data_width_bits == 32 and edo.total_width_bits == 36
        and edo.size_bytes == 8 * 1024^2 and edo.part_number == "EDO-TEST")
    local collector = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "eeprom\n", [path .. "/eeprom"] = blob,
    } }) })
    local sample = collector:sample({})
    assert(collector:probe({}).available and sample.quality == "fresh"
        and sample.data.devices[1].module_banks == 2,
        "the legacy eeprom probe and collector accept an EDO SPD")
    local state = Snapshot.merge(nil, { spd = sample }, 1, 1)
    local exported = Export.snapshot(state)
    assert(exported.spd.devices[1].module_banks == 2
        and exported.spd.devices[1].size_bytes == 8 * 1024^2
        and not JSON.encode(exported):find("LEAK", 1, true))
    local detail = table.concat(TUI.hardware_detail_lines(state, "spd:3-0050",
        assert(I18n.new({ locale = "en-US" }))), "\n")
    assert(detail:find("EDO-TEST", 1, true)
        and detail:find("Module banks", 1, true), detail)

    local asymmetric = put(blob, 3, "\171") -- bank 1: 11 rows; bank 2: 10 rows
    asymmetric = signed(asymmetric)
    assert(Decoder.parse(asymmetric).size_bytes == 6 * 1024^2,
        "unequal FPM/EDO banks use each bank's own row count")
    local fpm = put(blob, 2, "\1\12\10\1\64")
    fpm = put(fpm, 11, "\0")
    fpm = put(fpm, 13, "\16")
    fpm = signed(fpm)
    local fpm_decoded = assert(Decoder.parse(fpm))
    assert(fpm_decoded.memory_type == "FPM DRAM"
        and fpm_decoded.module_banks == 1
        and fpm_decoded.data_width_bits == 64
        and fpm_decoded.size_bytes == 32 * 1024^2)
    local fpm_sample = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "eeprom\n", [path .. "/eeprom"] = fpm,
    } }) }):sample({})
    assert(fpm_sample.quality == "fresh"
        and fpm_sample.data.devices[1].memory_type == "FPM DRAM")
    local small = signed(put(blob:sub(1, 128), 1, "\7"))
    local small_sample = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "eeprom\n", [path .. "/eeprom"] = small,
    } }) }):sample({})
    assert(small_sample.quality == "fresh"
        and small_sample.data.devices[1].bytes_read == 128
        and small_sample.data.devices[1].complete,
        "a declared 128-byte FPM/EDO EEPROM is read without a second page")
    local malformed_geometry = signed(put(blob, 3, "\0"))
    assert(Decoder.parse(malformed_geometry).size_bytes == nil,
        "a checksum does not make a missing address count into capacity")
    local ambiguous_width = signed(put(blob, 11, "\0"))
    assert(Decoder.parse(ambiguous_width).data_width_bits == nil
        and Decoder.parse(ambiguous_width).size_bytes == nil,
        "36 bits without a parity declaration cannot be called 32 data bits")
    local bad_checksum = put(blob, 9, "\61")
    assert(Decoder.parse(bad_checksum).checksum_valid == false
        and Decoder.parse(bad_checksum).size_bytes == nil)
    local damaged = SPD.new({ fs = Fixture.new({ files = {
        [path .. "/name"] = "eeprom\n", [path .. "/eeprom"] = bad_checksum,
    } }) }):sample({})
    assert(damaged.quality == "partial"
        and damaged.data.devices[1].issues[1].reason == "spd_checksum_mismatch")
    local short = assert(Decoder.parse(blob:sub(1, 64)))
    assert(short.checksum_valid and not short.complete
        and short.size_bytes == 8 * 1024^2 and short.part_number == nil)
end

do
    local SMBIOS = require("wtop.format.smbios")
    local Slots = require("wtop.collectors.expansion_slots")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(kind, length, handle, fields, strings)
        local data = string.pack("<BBI2", kind, length, handle) .. string.rep("\0", length - 4)
        for offset, value in pairs(fields or {}) do data = put(data, offset, value) end
        return data .. table.concat(strings or {}, "\0") .. "\0\0"
    end
    local function word(value) return string.pack("<I2", value) end
    local occupied = record(9, 24, 0x2200, {
        [4] = "\1\170\13\4\4", [9] = word(7), [13] = word(0),
        [15] = "\2\0\13\1", [19] = word(0) .. "\3\0\8",
    }, { "PCIEX16_1" })
    local empty = record(9, 19, 0x2201, {
        [4] = "\1\168\10\3\4", [9] = word(8), [13] = word(0),
        [15] = "\4\0\10\0",
    }, { "PCIEX4_2" })
    local legacy = record(9, 12, 0x2202, { [4] = "\1\6\5\2\4", [9] = word(9) }, { "PCI_OLD" })
    local ending = record(127, 4, 65535)
    local unrelated = record(1, 8, 0x3000, {}, { "PRIVATE-SYSTEM-UUID" })
    local blob = unrelated .. occupied .. empty .. legacy .. ending
    local function entry3(maximum)
        local value = "_SM3_\0\24\3\8\0\1\0" .. string.pack("<I4I8", maximum, 0)
        local sum = 0
        for index = 1, #value do sum = (sum + value:byte(index)) % 256 end
        return put(value, 5, string.char((-sum) % 256))
    end
    local parsed = assert(SMBIOS.parse(blob, assert(SMBIOS.entry_point(entry3(#blob)))))
    assert(not parsed.partial and #parsed.slots == 3 and #parsed.devices == 0)
    assert(parsed.slots[1].designation == "PCIEX16_1")
    assert(parsed.slots[1].slot_type == "PCI Express x16"
        and parsed.slots[1].electrical_lanes == 16)
    assert(parsed.slots[1].pci_bdf == "0000:02:00.0"
        and parsed.slots[1].peer_bdfs[1] == "0000:03:00.0")
    assert(parsed.slots[2].usage_code == 3 and parsed.slots[2].pci_bdf == "0000:04:00.0")
    assert(parsed.slots[3].pci_bdf == nil and parsed.slots[3].slot_id == 9)
    local base = "/sys/firmware/dmi/tables"
    local fs = Fixture.new({ files = {
        [base .. "/DMI"] = blob, [base .. "/smbios_entry_point"] = entry3(#blob),
    } })
    local collector = Slots.new({ fs = fs, platform = "linux" })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok" and result.quality == "fresh")
    local state = Snapshot.merge(nil, { expansion_slots = result, inventory = {
        status = "ok", quality = "fresh", data = { pci = { devices = {
            { address = "0000:02:00.0" }, { address = "0000:03:00.0" },
            { address = "0000:04:00.0" },
        } } },
    } }, 1, 1)
    local graph = Hardware.build(state)
    local slot = graph.by_id["slot:2200"]
    assert(slot and #slot.pci_ids == 2 and slot.pci_ids[1] == "0000:02:00.0")
    assert(graph.by_id["pci:0000:02:00.0"].slot_ids[1] == "slot:2200")
    local slot_refs = Hardware.related(graph, "slot:2200")
    assert(slot_refs.total == 2 and slot_refs.items[1].id == "pci:0000:02:00.0"
        and slot_refs.items[2].id == "pci:0000:03:00.0")
    assert(Hardware.related(graph, "pci:0000:02:00.0").items[1].id == "slot:2200")
    assert(Hardware.related(graph, "slot:2201").total == 0,
        "an available slot cannot navigate to a card it does not hold")
    assert(#graph.by_id["slot:2201"].pci_ids == 0,
        "an available slot's firmware BDF does not claim a present device")
    assert(#graph.by_id["pci:0000:04:00.0"].slot_ids == 0)
    local system_model = ViewModel.build({ history_values = function() return {} end },
        state, assert(I18n.new({ locale = "en-US" })), {}, "system").system_devices
    local saw_handle = false
    for _, row in ipairs(system_model.rows) do
        if row.bus == "SLOT" and row.id == "2200" then saw_handle = true end
    end
    assert(saw_handle, "the system table must keep the slot handle as a distinct short ID")
    local slot_filter = ViewModel.build({ history_values = function() return {} end },
        state, assert(I18n.new({ locale = "en-US" })), {}, "system", nil, nil,
        { system_query = "bus:slot name:PCIEX16_1" }).system_devices
    assert(#slot_filter.rows == 1 and slot_filter.ids[1] == "slot:2200"
        and slot_filter.status_text:find("1 matches", 1, true),
        "system search combines bus and the displayed slot designation")
    local tree_state = { inventory = { pci = { devices = {
        { address = "0000:00:01.0", vendor_name = "Acme", device_name = "Parent bridge" },
        { address = "0000:01:00.0", parent_address = "0000:00:01.0",
          vendor_name = "Acme", device_name = "Child Accelerator", driver = "nvme",
          serial = "PRIVATE-HARDWARE-SERIAL" },
    } } } }
    local tree_filter = ViewModel.build({ history_values = function() return {} end },
        tree_state, assert(I18n.new({ locale = "en-US" })), {}, "system", nil, nil,
        { system_query = "driver:nvme bus:pci" }).system_devices
    assert(#tree_filter.rows == 2 and tree_filter.ids[1] == "pci:0000:00:01.0"
        and tree_filter.ids[2] == "pci:0000:01:00.0" and tree_filter.selected == 2,
        "a driver match keeps its parent bridge and selects the matched device")
    local private_filter = ViewModel.build({ history_values = function() return {} end },
        tree_state, assert(I18n.new({ locale = "en-US" })), {}, "system", nil, nil,
        { system_query = "PRIVATE-HARDWARE-SERIAL" }).system_devices
    assert(#private_filter.rows == 0,
        "search cannot disclose a serial number absent from the hardware view")
    local exported = Export.snapshot(state)
    assert(exported.expansion_slots.slots[1].peer_bdfs[1] == "0000:03:00.0")
    assert(exported.inventory.topology.nodes and #exported.inventory.topology.nodes == 6)
    assert(not JSON.encode(exported):find("PRIVATE", 1, true))
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local detail = table.concat(TUI.hardware_detail_lines(state, "slot:2200", i18n), "\n")
    assert(detail:find("PCIEX16_1", 1, true) and detail:find("In use", 1, true))
    assert(detail:find("0000:02:00.0", 1, true)
        and detail:find("does not prove", 1, true))
    local pci_detail = table.concat(TUI.hardware_detail_lines(state, "pci:0000:02:00.0", i18n), "\n")
    assert(pci_detail:find("Firmware slot references: PCIEX16_1", 1, true))
    local duplicated = assert(SMBIOS.parse(occupied .. occupied .. ending))
    assert(duplicated.partial and duplicated.slots[1].ambiguous)
    local malformed = put(occupied, 18, "\5")
    local bad = assert(SMBIOS.parse(malformed .. ending))
    assert(bad.partial and #bad.slots[1].peer_bdfs == 0)
    local no_bdf = put(occupied, 13, word(65535))
    assert(assert(SMBIOS.parse(no_bdf .. ending)).slots[1].pci_bdf == nil)
    local conflict = assert(SMBIOS.parse(occupied .. put(occupied, 2, word(0x2203)) .. ending))
    local conflict_graph = Hardware.build({ expansion_slots = conflict,
        inventory = { pci = { devices = { { address = "0000:02:00.0" } } } } })
    assert(conflict_graph.partial and #conflict_graph.by_id["pci:0000:02:00.0"].slot_ids == 0)
    local native = { read_smbios = function() return { data = blob, major = 3, minor = 8 } end }
    local portable = require("wtop.collectors.portable").new_all({ platform = "windows",
        common = { native = native } }).expansion_slots
    assert(portable:sample({}).data.slots[1].designation == "PCIEX16_1")
    local empty_slots = Slots.new({ fs = Fixture.new({ files = {
        [base .. "/DMI"] = ending,
        [base .. "/smbios_entry_point"] = entry3(#ending),
    } }), platform = "linux" }):sample({})
    assert(empty_slots.status == "unavailable" and empty_slots.reason == "no_expansion_slots")
    local denied = Slots.new({ fs = Fixture.new({ denied = {
        [base .. "/DMI"] = true,
    } }), platform = "linux" })
    assert(denied:probe({}).state == "denied" and denied:sample({}).status == "denied")
    local no_entry = Slots.new({ fs = Fixture.new({ files = {
        [base .. "/DMI"] = blob,
    } }), platform = "linux" }):sample({})
    assert(no_entry.quality == "partial" and #no_entry.data.slots == 3)
    assert(Slots.new({ platform = "windows", native = {} }):sample({}).status == "unavailable")
    assert(not pcall(Slots.new, { base_path = "relative" }))
end

-- Type 8 describes physical connectors, not a relationship to an OS device.
do
    local SMBIOS = require("wtop.format.smbios")
    local PortConnectors = require("wtop.collectors.port_connectors")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local Report = require("wtop.report")
    local JSON = require("wtop.format.json")
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(kind, length, handle, fields, strings)
        local data = string.pack("<BBI2", kind, length, handle) .. string.rep("\0", length - 4)
        for offset, value in pairs(fields or {}) do data = put(data, offset, value) end
        return data .. table.concat(strings or {}, "\0") .. "\0\0"
    end
    local function entry3(maximum)
        local value = "_SM3_\0\24\3\8\0\1\0" .. string.pack("<I4I8", maximum, 0)
        local sum = 0
        for index = 1, #value do sum = (sum + value:byte(index)) % 256 end
        return put(value, 5, string.char((-sum) % 256))
    end
    local serial = record(1, 8, 0x080f, {}, { "PRIVATE-SERIAL" })
    local serial_port = record(8, 9, 0x0800,
        { [4] = "\1\24\2\8\9" }, { "J101", "COM A" })
    local usb_c = record(8, 9, 0x0801,
        { [4] = "\0\0\1\35\16" }, { "USB-C 1" })
    local ending = record(127, 4, 65535)
    local blob = serial .. serial_port .. usb_c .. ending
    local parsed = assert(SMBIOS.parse(blob, assert(SMBIOS.entry_point(entry3(#blob)))))
    assert(not parsed.partial and #parsed.ports == 2)
    assert(parsed.ports[1].internal_designation == "J101"
        and parsed.ports[1].external_designation == "COM A"
        and parsed.ports[1].internal_connector == "9-pin Dual Inline"
        and parsed.ports[1].external_connector == "DB-9 male"
        and parsed.ports[1].port_type == "Serial 16550A")
    assert(parsed.ports[2].internal_designation == nil
        and parsed.ports[2].internal_connector == "None"
        and parsed.ports[2].external_connector == "USB Type-C"
        and parsed.ports[2].port_type == "USB")
    local base = "/sys/firmware/dmi/tables"
    local fs = Fixture.new({ files = {
        [base .. "/DMI"] = blob, [base .. "/smbios_entry_point"] = entry3(#blob),
    } })
    local collector = PortConnectors.new({ fs = fs, platform = "linux" })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok"
        and result.quality == "fresh" and #result.data.ports == 2)
    local state = Snapshot.merge(nil, { port_connectors = result,
        inventory = { status = "ok", quality = "fresh", data = {
            pci = { devices = { { address = "0000:00:14.0" } } },
            usb = { devices = { { id = "1-1" } } },
        } },
    }, 1, 1)
    local graph = Hardware.build(state)
    local first, second = graph.by_id["port:0800"], graph.by_id["port:0801"]
    assert(first and second and first.parent_id == nil and second.parent_id == nil
        and #Hardware.related(graph, first.id).items == 0,
        "a port label cannot identify an operating-system device")
    local i18n = assert(I18n.new({ locale = "en-US" }))
    assert(Hardware.label(first, i18n) == "COM A"
        and Hardware.label(second, i18n) == "USB-C 1")
    local detail = table.concat(TUI.hardware_detail_lines(state, first.id, i18n), "\n")
    assert(detail:find("Internal reference: J101", 1, true)
        and detail:find("External connector: DB-9 male", 1, true)
        and detail:find("Port function: Serial 16550A", 1, true))
    local rows = require("wtop.view_model").build(
        { history_values = function() return {} end }, state, i18n, {}, "system")
        .system_devices.rows
    local visible = false
    for _, row in ipairs(rows) do
        if row.bus == "FIRMWARE" and row.id == "0800" then visible = true end
    end
    assert(visible, "the firmware port appears in the System device table")
    local exported = Export.snapshot(state)
    assert(exported.port_connectors.ports[1].external_designation == "COM A"
        and exported.port_connectors.ports[2].external_connector == "USB Type-C"
        and not JSON.encode(exported):find("PRIVATE", 1, true))
    local report = Report.render(exported)
    assert(report:find("## Firmware ports", 1, true)
        and report:find("| COM A | Serial 16550A | 9-pin Dual Inline | DB-9 male | J101 | COM A |", 1, true))
    local limited = assert(SMBIOS.parse(blob, nil, { max_ports = 1 }))
    assert(limited.truncated and #limited.ports == 1)
    local duplicate = assert(SMBIOS.parse(serial_port
        .. record(8, 9, 0x0800, { [4] = "\1\24\2\8\9" }, { "J102", "COM B" })
        .. ending))
    assert(duplicate.partial and duplicate.ports[1].ambiguous
        and duplicate.ports[2].ambiguous)
    assert(PortConnectors.new({ platform = "windows", native = {
        read_smbios = function() return { data = blob, major = 3, minor = 8 } end,
    } }):sample({}).status == "ok")
    local portable = require("wtop.collectors.portable").new_all({
        platform = "windows", port_connectors = { native = {
            read_smbios = function() return { data = blob, major = 3, minor = 8 } end,
        } },
    })
    assert(portable.port_connectors:sample({}).status == "ok")
    assert(PortConnectors.new({ fs = Fixture.new(), platform = "linux" }):sample({}).status
        == "unavailable")
end

-- SMBIOS Type 41 is a firmware declaration with an explicit PCI function,
-- not an operating-system parent edge. Only a unique enabled declaration
-- may cross-reference a currently enumerated PCI function.
do
    local SMBIOS = require("wtop.format.smbios")
    local OnboardDevices = require("wtop.collectors.onboard_devices")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(kind, length, handle, fields, strings)
        local data = string.pack("<BBI2", kind, length, handle) .. string.rep("\0", length - 4)
        for offset, value in pairs(fields or {}) do data = put(data, offset, value) end
        return data .. table.concat(strings or {}, "\0") .. "\0\0"
    end
    local function entry3(maximum)
        local value = "_SM3_\0\24\3\8\0\1\0" .. string.pack("<I4I8", maximum, 0)
        local sum = 0
        for index = 1, #value do sum = (sum + value:byte(index)) % 256 end
        return put(value, 5, string.char((-sum) % 256))
    end
    local enabled = record(41, 11, 0x4100, {
        [4] = "\1\133\1", [7] = string.pack("<I2", 0), [9] = "\2\0",
    }, { "LAN_ONBOARD" })
    local disabled = record(41, 11, 0x4101, {
        [4] = "\1\5\2", [7] = string.pack("<I2", 0), [9] = "\3\0",
    }, { "LAN_DISABLED" })
    local no_pci = record(41, 11, 0x4102, {
        [4] = "\1\140\1", [7] = string.pack("<I2", 0xffff), [9] = "\255\255",
    }, { "BT_ONBOARD" })
    local ending = record(127, 4, 65535)
    local private = record(1, 8, 0x4000, {}, { "PRIVATE-SYSTEM-SERIAL" })
    local blob = private .. enabled .. disabled .. no_pci .. ending
    local parsed = assert(SMBIOS.parse(blob, assert(SMBIOS.entry_point(entry3(#blob)))))
    assert(not parsed.partial and #parsed.onboard_devices == 3)
    assert(parsed.onboard_devices[1].designation == "LAN_ONBOARD"
        and parsed.onboard_devices[1].device_type == "Ethernet"
        and parsed.onboard_devices[1].type_instance == 1
        and parsed.onboard_devices[1].enabled == true
        and parsed.onboard_devices[1].pci_bdf == "0000:02:00.0")
    assert(parsed.onboard_devices[2].enabled == false
        and parsed.onboard_devices[2].pci_bdf == "0000:03:00.0")
    assert(parsed.onboard_devices[3].device_type == "Bluetooth"
        and parsed.onboard_devices[3].pci_bdf == nil)
    local old_sentinel = assert(SMBIOS.parse(put(no_pci, 7,
        string.pack("<I2", 0xff)) .. ending))
    assert(old_sentinel.onboard_devices[1].pci_bdf == nil,
        "the specification's 0FFh word spelling is also an absent address")
    local base = "/sys/firmware/dmi/tables"
    local fs = Fixture.new({ files = {
        [base .. "/DMI"] = blob, [base .. "/smbios_entry_point"] = entry3(#blob),
    } })
    local collector = OnboardDevices.new({ fs = fs, platform = "linux" })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok"
        and result.quality == "fresh" and #result.data.devices == 3)
    local state = Snapshot.merge(nil, { onboard_devices = result, inventory = {
        status = "ok", quality = "fresh", data = { pci = { devices = {
            { address = "0000:02:00.0", device_name = "Ethernet function" },
            { address = "0000:03:00.0", device_name = "Disabled function" },
        } } },
    } }, 1, 1)
    local graph = Hardware.build(state)
    local node = graph.by_id["onboard:4100"]
    assert(node and node.parent_id == nil and node.pci_ids[1] == "0000:02:00.0")
    assert(graph.by_id["pci:0000:02:00.0"].onboard_ids[1] == node.id
        and graph.by_id["pci:0000:02:00.0"].parent_id == nil)
    assert(Hardware.related(graph, node.id).items[1].id == "pci:0000:02:00.0"
        and Hardware.related(graph, "pci:0000:02:00.0").items[1].id == node.id)
    assert(#graph.by_id["pci:0000:03:00.0"].onboard_ids == 0
        and #graph.by_id["onboard:4101"].pci_ids == 0
        and #graph.by_id["onboard:4102"].pci_ids == 0)
    local stale = Hardware.build({ onboard_devices = result.data,
        inventory = state.inventory,
        quality = { onboard_devices = { status = "ok", quality = "stale" } } })
    assert(#stale.by_id["pci:0000:02:00.0"].onboard_ids == 0,
        "a retained firmware address must not claim a current PCI function")
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local rows = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "system").system_devices
    local found = false
    for _, row in ipairs(rows.rows) do
        if row.id == "4100" and row.device:find("LAN_ONBOARD", 1, true) then found = true end
    end
    assert(found, "the system device table omitted the firmware declaration")
    local filtered = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "system", nil, nil,
        { system_query = "bus:firmware name:LAN_ONBOARD" }).system_devices
    assert(#filtered.rows == 1 and filtered.ids[1] == node.id,
        "the system search cannot select the onboard firmware record")
    local details = table.concat(TUI.hardware_detail_lines(state, node.id, i18n), "\n")
    assert(details:find("LAN_ONBOARD", 1, true)
        and details:find("Ethernet", 1, true)
        and details:find("Enabled in firmware: yes", 1, true)
        and details:find("0000:02:00.0", 1, true))
    local pci_detail = table.concat(TUI.hardware_detail_lines(state,
        "pci:0000:02:00.0", i18n), "\n")
    assert(pci_detail:find("Firmware onboard references", 1, true)
        and pci_detail:find("LAN_ONBOARD", 1, true))
    local exported = Export.snapshot(state)
    assert(exported.onboard_devices.devices[1].pci_bdf == "0000:02:00.0"
        and exported.inventory.topology.nodes[1] ~= nil)
    local topology
    for _, item in ipairs(exported.inventory.topology.nodes) do
        if item.id == "pci:0000:02:00.0" then topology = item end
    end
    assert(topology and topology.onboard_ids[1] == node.id)
    assert(not JSON.encode(exported):find("PRIVATE", 1, true))
    local duplicate = assert(SMBIOS.parse(enabled
        .. put(enabled, 2, string.pack("<I2", 0x4103)) .. ending))
    local conflicting = Hardware.build({ onboard_devices = { devices = duplicate.onboard_devices },
        inventory = { pci = { devices = { { address = "0000:02:00.0" } } } } })
    assert(conflicting.partial and #conflicting.by_id["pci:0000:02:00.0"].onboard_ids == 0)
    local repeated_handle = assert(SMBIOS.parse(enabled .. enabled .. ending))
    assert(repeated_handle.partial and repeated_handle.onboard_devices[1].ambiguous)
    local truncated = assert(SMBIOS.parse(blob, nil, { max_onboard = 1 }))
    assert(truncated.truncated and #truncated.onboard_devices == 1)
    local clipped = Hardware.build({ onboard_devices = { devices = truncated.onboard_devices,
        truncated = true }, inventory = { pci = { devices = {
            { address = "0000:02:00.0" },
        } } } })
    assert(#clipped.by_id["pci:0000:02:00.0"].onboard_ids == 0)
    local oversized_devices = { result.data.devices[1] }
    for index = 2, 129 do
        oversized_devices[index] = { id = string.format("%04x", 0x4200 + index),
            quality = "fresh", enabled = true,
            pci_bdf = index == 129 and "0000:02:00.0" or nil }
    end
    local oversized = Hardware.build({ onboard_devices = { devices = oversized_devices },
        inventory = { pci = { devices = { { address = "0000:02:00.0" } } } } })
    assert(oversized.truncated and #oversized.by_id["pci:0000:02:00.0"].onboard_ids == 0,
        "a hidden duplicate after the 128-record cap cannot leave a unique address claim")
    local edge = assert(SMBIOS.parse(put(enabled, 10, "\255") .. ending))
    assert(edge.onboard_devices[1].pci_bdf == "0000:02:1f.7",
        "a legal device/function byte FF is not the all-FF absent address")
    local malformed = assert(SMBIOS.parse(enabled
        .. record(41, 10, 0x4104, { [4] = "\1\133\1" }, { "SHORT" }) .. ending))
    assert(malformed.partial and #malformed.onboard_devices == 1)
    assert(Hardware.build({ onboard_devices = { devices = malformed.onboard_devices,
        partial = true } }).partial,
        "the shared topology must retain a partial firmware-source verdict")
    local native = { read_smbios = function() return { data = blob, major = 3, minor = 9 } end }
    local portable = require("wtop.collectors.portable").new_all({ platform = "windows",
        common = { native = native } }).onboard_devices
    assert(portable:sample({}).data.devices[1].designation == "LAN_ONBOARD")
    local empty = OnboardDevices.new({ fs = Fixture.new({ files = {
        [base .. "/DMI"] = ending,
        [base .. "/smbios_entry_point"] = entry3(#ending),
    } }), platform = "linux" }):sample({})
    assert(empty.status == "unavailable" and empty.reason == "no_onboard_devices")
    local denied = OnboardDevices.new({ fs = Fixture.new({ denied = {
        [base .. "/DMI"] = true,
    } }), platform = "linux" })
    assert(denied:probe({}).state == "denied" and denied:sample({}).status == "denied")
    assert(OnboardDevices.new({ platform = "windows", native = {} }):sample({}).status == "unavailable")
    assert(not pcall(OnboardDevices.new, { base_path = "relative" }))
end

-- Type 22 gives static battery design data, separate from live charge state.
do
    local SMBIOS = require("wtop.format.smbios")
    local FirmwareBatteries = require("wtop.collectors.firmware_batteries")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(kind, length, handle, fields, strings)
        local data = string.pack("<BBI2", kind, length, handle) .. string.rep("\0", length - 4)
        for offset, value in pairs(fields or {}) do data = put(data, offset, value) end
        return data .. table.concat(strings or {}, "\0") .. "\0\0"
    end
    local function word(value) return string.pack("<I2", value) end
    local function entry3(maximum)
        local value = "_SM3_\0\24\3\9\0\1\0" .. string.pack("<I4I8", maximum, 0)
        local sum = 0
        for index = 1, #value do sum = (sum + value:byte(index)) % 256 end
        return put(value, 5, string.char((-sum) % 256))
    end
    local modern = record(22, 26, 0x2200, {
        [4] = "\1\2\3\4\5\2", [10] = word(6000), [12] = word(11400),
        [14] = "\6\10", [16] = word(0x1234), [18] = word(0x5678),
        [20] = "\7\10", [22] = string.pack("<I4", 0xabcdef12),
    }, { "Left bay", "Fixture Vendor", "PRIVATE-DATE", "PRIVATE-SERIAL",
        "PACK_A", "SBDS 1.1", "LiP" })
    local old = record(22, 16, 0x2201, {
        [4] = "\1\2\3\4\5\6", [10] = word(45000), [12] = word(11000),
        [14] = "\0\255",
    }, { "Right bay", "Old Vendor", "PRIVATE-OLD-DATE", "PRIVATE-OLD-SERIAL",
        "PACK_OLD" })
    local ending = record(127, 4, 65535)
    local blob = modern .. old .. ending
    local parsed = assert(SMBIOS.parse(blob))
    assert(not parsed.partial and #parsed.firmware_batteries == 2)
    local a, b = parsed.firmware_batteries[1], parsed.firmware_batteries[2]
    assert(a.location == "Left bay" and a.name == "PACK_A"
        and a.manufacturer == "Fixture Vendor" and a.chemistry == "Unknown"
        and a.sbds_chemistry == "LiP" and a.sbds_version == "SBDS 1.1")
    assert(a.design_capacity_raw_mwh == 6000 and a.design_capacity_multiplier == 10
        and a.design_capacity_mwh == 60000 and a.design_voltage_mv == 11400
        and a.maximum_error_percent == 10)
    assert(b.chemistry == "Lithium-ion" and b.design_capacity_mwh == 45000
        and b.design_capacity_multiplier == 1 and b.maximum_error_percent == nil)
    assert(not JSON.encode(parsed):find("PRIVATE", 1, true))
    local base = "/sys/firmware/dmi/tables"
    local files = { [base .. "/DMI"] = blob, [base .. "/smbios_entry_point"] = entry3(#blob) }
    local collector = FirmwareBatteries.new({ platform = "linux", fs = Fixture.new({ files = files }) })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok"
        and result.quality == "fresh" and #result.data.batteries == 2)
    local state = Snapshot.merge(nil, { firmware_batteries = result }, 1, 1)
    local graph = Hardware.build(state)
    local battery = graph.by_id["firmware-battery:2200"]
    assert(battery and battery.kind == "firmware_battery" and battery.parent_id == nil)
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local system = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "system", nil, nil,
        { system_query = "name:PACK_A" }).system_devices
    assert(#system.rows == 1 and system.ids[1] == battery.id)
    local detail = table.concat(TUI.hardware_detail_lines(state, battery.id, i18n), "\n")
    assert(detail:find("PACK_A", 1, true) and detail:find("60", 1, true)
        and detail:find("Wh", 1, true) and detail:find("11.4", 1, true)
        and detail:find("current charge", 1, true)
        and not detail:find("PRIVATE", 1, true))
    local exported = Export.snapshot(state)
    assert(exported.firmware_batteries.batteries[1].design_capacity_mwh == 60000
        and exported.firmware_batteries.batteries[2].design_capacity_mwh == 45000)
    assert(Export.agent(state).overall.signal_count == 0)
    local topology
    for _, node in ipairs(exported.inventory.topology.nodes) do
        if node.id == battery.id then topology = node end
    end
    assert(topology and topology.resource == "firmware_batteries")
    assert(not JSON.encode(exported):find("PRIVATE", 1, true))
    local unknown = assert(SMBIOS.parse(put(modern, 10, word(0))
        .. put(old, 12, word(0)) .. ending))
    assert(unknown.firmware_batteries[1].design_capacity_mwh == nil
        and unknown.firmware_batteries[2].design_voltage_mv == nil)
    local zero_multiplier = assert(SMBIOS.parse(put(modern, 21, "\0") .. ending))
    assert(zero_multiplier.partial and zero_multiplier.firmware_batteries[1].quality == "partial"
        and zero_multiplier.firmware_batteries[1].design_capacity_mwh == nil)
    local bad_error = assert(SMBIOS.parse(put(modern, 15, "\101") .. ending))
    assert(bad_error.partial and bad_error.firmware_batteries[1].maximum_error_percent == nil)
    local duplicate = assert(SMBIOS.parse(modern .. modern .. ending))
    assert(duplicate.partial and duplicate.firmware_batteries[1].ambiguous)
    local capped = assert(SMBIOS.parse(blob, nil, { max_firmware_batteries = 1 }))
    assert(capped.truncated and #capped.firmware_batteries == 1)
    local native = { read_smbios = function() return { data = blob, major = 3, minor = 9 } end }
    local portable = require("wtop.collectors.portable").new_all({ platform = "windows",
        common = { native = native } }).firmware_batteries
    assert(portable:sample({}).data.batteries[1].name == "PACK_A")
    local empty = FirmwareBatteries.new({ platform = "linux", fs = Fixture.new({ files = {
        [base .. "/DMI"] = ending, [base .. "/smbios_entry_point"] = entry3(#ending),
    } }) }):sample({})
    assert(empty.status == "unavailable" and empty.reason == "no_firmware_batteries")
    local denied = FirmwareBatteries.new({ platform = "linux", fs = Fixture.new({ denied = {
        [base .. "/DMI"] = true,
    } }) })
    assert(denied:probe({}).state == "denied" and denied:sample({}).status == "denied")
    assert(FirmwareBatteries.new({ platform = "windows", native = {} }):sample({}).status == "unavailable")
    assert(not pcall(FirmwareBatteries.new, { base_path = "relative" }))
end

-- Eleven SMBIOS collectors share a decoded table within one scheduler pass, but
-- their output records and quality issues remain independent and refresh later.
do
    local Scheduler = require("wtop.core.scheduler")
    local FirmwareBatteries = require("wtop.collectors.firmware_batteries")
    local FirmwareBmcs = require("wtop.collectors.firmware_bmcs")
    local FirmwareTpms = require("wtop.collectors.firmware_tpms")
    local FirmwareComponents = require("wtop.collectors.firmware_components")
    local HostInterfaces = require("wtop.collectors.host_interfaces")
    local PortConnectors = require("wtop.collectors.port_connectors")
    local Fixture = require("support.fixture_fs")
    local function battery(name)
        local fields = string.pack("<BBI2", 22, 16, 0x2200)
            .. "\1\2\0\0\3\6" .. string.pack("<I2I2", 5000, 11000)
            .. "\0\255"
        local port = string.pack("<BBI2", 8, 9, 0x0800)
            .. "\0\0\1\8\9" .. "COM A\0\0"
        local bmc = string.pack("<BBI2", 38, 16, 0x3800)
            .. "\1\32\32\255" .. string.pack("<I8", 0xca3) .. "\0\0"
        local tpm = string.pack("<BBI2", 43, 31, 0x4300)
            .. "ABC\0\2\0" .. string.pack("<I4I4", 1, 2)
            .. "\1" .. string.rep("\0", 12) .. "Batch TPM\0\0"
        local component = string.pack("<BBI2", 45, 24, 0x4500)
            .. "\1\2\0\0\0\0\3\0"
            .. string.pack("<I8I2BB", 8192, 0, 4, 0)
            .. "Platform firmware\0" .. "1.2\0" .. "Vendor\0\0"
        local host = string.pack("<BBI2", 42, 13, 0x4200)
            .. "\64\4DATA\1\2\0\0\0"
        return fields .. "Bay\0Vendor\0" .. name .. "\0\0"
            .. port .. bmc .. tpm .. component .. host
            .. string.pack("<BBI2", 127, 4, 65535) .. "\0\0"
    end
    local base = "/sys/firmware/dmi/tables"
    local files_a = { [base .. "/DMI"] = battery("PACK_A") }
    local files_b = { [base .. "/DMI"] = battery("PACK_B") }
    local function counted(files)
        local fs = Fixture.new({ files = files })
        local original = fs.read
        local reads = { dmi = 0, entry = 0 }
        function fs:read(path, limit)
            if path == base .. "/DMI" then reads.dmi = reads.dmi + 1 end
            if path == base .. "/smbios_entry_point" then reads.entry = reads.entry + 1 end
            return original(self, path, limit)
        end
        return fs, reads
    end
    local fs_a, reads_a = counted(files_a)
    local fs_b, reads_b = counted(files_b)
    local now = 0
    local context = { now_ns = function() return now end }
    local scheduler = Scheduler.new({ clock = function() return now end, context = context })
    for index, fs in ipairs({ fs_a, fs_a, fs_b }) do
        local collector = FirmwareBatteries.new({ platform = "linux", fs = fs })
        collector.id = "firmware_fixture_" .. index
        assert(scheduler:add(collector, { interval_ms = 1000 }))
    end
    assert(scheduler:add(PortConnectors.new({ platform = "linux", fs = fs_a }),
        { interval_ms = 1000 }))
    assert(scheduler:add(FirmwareBmcs.new({ platform = "linux", fs = fs_a }),
        { interval_ms = 1000 }))
    assert(scheduler:add(FirmwareTpms.new({ platform = "linux", fs = fs_a }),
        { interval_ms = 1000 }))
    assert(scheduler:add(FirmwareComponents.new({ platform = "linux", fs = fs_a }),
        { interval_ms = 1000 }))
    assert(scheduler:add(HostInterfaces.new({ platform = "linux", fs = fs_a }),
        { interval_ms = 1000 }))
    local capabilities = scheduler:probe_all()
    assert(capabilities.firmware_fixture_1.available
        and capabilities.firmware_fixture_2.available
        and capabilities.firmware_fixture_3.available
        and capabilities.port_connectors.available
        and capabilities.firmware_bmcs.available
        and capabilities.firmware_tpms.available
        and capabilities.firmware_components.available
        and capabilities.host_interfaces.available)
    assert(reads_a.dmi == 1 and reads_a.entry == 1
        and reads_b.dmi == 1 and reads_b.entry == 1
        and context._collector_batch == nil,
        "one probe pass reads each distinct SMBIOS source once")
    local first = scheduler:tick()
    assert(reads_a.dmi == 2 and reads_a.entry == 2
        and reads_b.dmi == 2 and reads_b.entry == 2
        and context._collector_batch == nil,
        "one sampling pass reads each distinct SMBIOS source once")
    local a = first.firmware_fixture_1.data
    local other = first.firmware_fixture_2.data
    assert(a.batteries[1].name == "PACK_A" and other.batteries[1].name == "PACK_A"
        and first.firmware_fixture_3.data.batteries[1].name == "PACK_B"
        and first.port_connectors.data.ports[1].external_designation == "COM A"
        and first.firmware_bmcs.data.devices[1].interface_type == "KCS"
        and first.firmware_tpms.data.devices[1].vendor_id == "ABC"
        and first.firmware_components.data.components[1].name == "Platform firmware"
        and first.host_interfaces.data.devices[1].protocols[1].type == "IPMI")
    a.batteries[1].name = "changed"
    a.issues[1].source = "changed"
    assert(other.batteries[1].name == "PACK_A" and other.issues[1].source ~= "changed",
        "a collector cannot mutate another collector's decoded record or issue")
    files_a[base .. "/DMI"] = battery("PACK_NEW")
    now = 1000000000
    local second = scheduler:tick()
    assert(reads_a.dmi == 3 and reads_a.entry == 3
        and reads_b.dmi == 3 and reads_b.entry == 3
        and second.firmware_fixture_1.data.batteries[1].name == "PACK_NEW",
        "the next scheduler pass must reread firmware, not keep a stale cache")
end

-- Type 39 is a firmware inventory of possible PSUs. A shared nonzero group
-- is a redundancy declaration, not a live power or health measurement.
do
    local SMBIOS = require("wtop.format.smbios")
    local FirmwarePower = require("wtop.collectors.firmware_power_supplies")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(kind, length, handle, fields, strings)
        local data = string.pack("<BBI2", kind, length, handle) .. string.rep("\0", length - 4)
        for offset, value in pairs(fields or {}) do data = put(data, offset, value) end
        return data .. table.concat(strings or {}, "\0") .. "\0\0"
    end
    local function word(value) return string.pack("<I2", value) end
    local function entry3(maximum)
        local value = "_SM3_\0\24\3\9\0\1\0" .. string.pack("<I4I8", maximum, 0)
        local sum = 0
        for index = 1, #value do sum = (sum + value:byte(index)) % 256 end
        return put(value, 5, string.char((-sum) % 256))
    end
    local first = record(39, 22, 0x3900, {
        [4] = "\1\1\2\3\4\5\6\7", [12] = word(750), [14] = word(0x11a3),
        [16] = word(0x2600), [18] = word(0x2700), [20] = word(0x2900),
    }, { "Left bay", "PSU_A", "Fixture Vendor", "PRIVATE-SERIAL-PSU",
        "PRIVATE-ASSET-PSU", "MODEL-750", "R2" })
    local second = record(39, 16, 0x3901, {
        [4] = "\1\1\2\3\4\5\6\7", [12] = word(750), [14] = word(0x12a6),
    }, { "Right bay", "PSU_B", "Fixture Vendor", "PRIVATE-SERIAL-B",
        "PRIVATE-ASSET-B", "MODEL-750", "R2" })
    local spare = record(39, 16, 0x3902, {
        [4] = "\0\1\2\3\4\5\6\7", [12] = word(0x8000), [14] = word(0x1800),
    }, { "Spare bay", "PSU_SPARE", "Fixture Vendor", "PRIVATE-SERIAL-C",
        "PRIVATE-ASSET-C", "MODEL-X", "R1" })
    local ending = record(127, 4, 65535)
    local blob = first .. second .. spare .. ending
    local parsed = assert(SMBIOS.parse(blob))
    assert(not parsed.partial and #parsed.firmware_power_supplies == 3)
    local a, b, c = parsed.firmware_power_supplies[1],
        parsed.firmware_power_supplies[2], parsed.firmware_power_supplies[3]
    assert(a.location == "Left bay" and a.name == "PSU_A"
        and a.manufacturer == "Fixture Vendor" and a.part_number == "MODEL-750"
        and a.revision == "R2" and a.max_power_watts == 750
        and a.max_power_capacity_raw == 750)
    assert(a.supply_type == "Switching" and a.status == "OK"
        and a.range_switching == "Auto-switch" and a.present
        and not a.unplugged and a.hot_replaceable)
    assert(a.voltage_probe_id == "2600" and a.cooling_device_id == "2700"
        and a.current_probe_id == "2900")
    assert(b.status == "Critical" and b.unplugged and b.present
        and not b.hot_replaceable and b.voltage_probe_id == nil)
    assert(c.power_unit_group == 0 and c.max_power_watts == nil
        and c.max_power_capacity_raw == 0x8000 and not c.present)
    local base = "/sys/firmware/dmi/tables"
    local fs = Fixture.new({ files = { [base .. "/DMI"] = blob,
        [base .. "/smbios_entry_point"] = entry3(#blob) } })
    local collector = FirmwarePower.new({ platform = "linux", fs = fs })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok"
        and result.quality == "fresh" and #result.data.supplies == 3)
    local state = Snapshot.merge(nil, { firmware_power_supplies = result }, 1, 1)
    local graph = Hardware.build(state)
    local left, right = graph.by_id["firmware-psu:3900"], graph.by_id["firmware-psu:3901"]
    assert(left and right and left.parent_id == nil
        and left.redundant_peer_ids[1] == right.id
        and right.redundant_peer_ids[1] == left.id)
    assert(#graph.by_id["firmware-psu:3902"].redundant_peer_ids == 0)
    assert(Hardware.related(graph, left.id).items[1].id == right.id)
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local system = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "system", nil, nil,
        { system_query = "name:PSU_A" }).system_devices
    assert(#system.rows == 1 and system.ids[1] == left.id)
    local detail = table.concat(TUI.hardware_detail_lines(state, left.id, i18n), "\n")
    assert(detail:find("PSU_A", 1, true)
        and detail:find("Maximum sustained output: 750 W", 1, true)
        and detail:find("Firmware redundancy peers: PSU_B", 1, true)
        and detail:find("not live power or health readings", 1, true))
    local exported = Export.snapshot(state)
    assert(exported.firmware_power_supplies.supplies[1].max_power_watts == 750
        and exported.firmware_power_supplies.supplies[1].max_power_capacity_raw == 750
        and exported.firmware_power_supplies.supplies[3].max_power_watts == nil
        and exported.firmware_power_supplies.supplies[3].max_power_capacity_raw == 0x8000)
    local agent = Export.agent(state)
    assert(agent.overall.signal_count == 0,
        "a Type 39 firmware Critical flag must not become a live health alert")
    local topology
    for _, node in ipairs(exported.inventory.topology.nodes) do
        if node.id == left.id then topology = node end
    end
    assert(topology and topology.redundant_peer_ids[1] == right.id)
    assert(not JSON.encode(exported):find("PRIVATE", 1, true))
    local singleton = assert(SMBIOS.parse(first .. ending))
    assert(singleton.partial and singleton.firmware_power_supplies[1].quality == "partial")
    local changed_group = assert(SMBIOS.parse(first
        .. put(second, 4, "\2") .. ending))
    local changed_graph = Hardware.build({ firmware_power_supplies = {
        supplies = changed_group.firmware_power_supplies, partial = true,
    } })
    assert(changed_group.partial
        and #changed_graph.by_id["firmware-psu:3900"].redundant_peer_ids == 0)
    local reserved = assert(SMBIOS.parse(first
        .. put(second, 14, word(0xd2a6)) .. ending))
    assert(reserved.partial and reserved.firmware_power_supplies[2].quality == "partial")
    local duplicate = assert(SMBIOS.parse(first .. first .. ending))
    assert(duplicate.partial and duplicate.firmware_power_supplies[1].ambiguous)
    local limited = assert(SMBIOS.parse(blob, nil, { max_firmware_supplies = 1 }))
    assert(limited.truncated and #limited.firmware_power_supplies == 1)
    local clipped = Hardware.build({ firmware_power_supplies = {
        supplies = limited.firmware_power_supplies, truncated = true,
    } })
    assert(#clipped.by_id["firmware-psu:3900"].redundant_peer_ids == 0)
    local stale = Hardware.build({ firmware_power_supplies = result.data,
        quality = { firmware_power_supplies = { status = "ok", quality = "stale" } } })
    assert(#stale.by_id["firmware-psu:3900"].redundant_peer_ids == 0)
    local native = { read_smbios = function() return { data = blob, major = 3, minor = 9 } end }
    local portable = require("wtop.collectors.portable").new_all({ platform = "windows",
        common = { native = native } }).firmware_power_supplies
    assert(portable:sample({}).data.supplies[1].name == "PSU_A")
    local empty = FirmwarePower.new({ platform = "linux", fs = Fixture.new({ files = {
        [base .. "/DMI"] = ending, [base .. "/smbios_entry_point"] = entry3(#ending),
    } }) }):sample({})
    assert(empty.status == "unavailable" and empty.reason == "no_firmware_power_supplies")
    local denied = FirmwarePower.new({ platform = "linux", fs = Fixture.new({ denied = {
        [base .. "/DMI"] = true,
    } }) })
    assert(denied:probe({}).state == "denied" and denied:sample({}).status == "denied")
    assert(FirmwarePower.new({ platform = "windows", native = {} }):sample({}).status == "unavailable")
    assert(not pcall(FirmwarePower.new, { base_path = "relative" }))
end

-- Type 38 describes a firmware-declared IPMI interface, not live BMC health.
do
    local SMBIOS = require("wtop.format.smbios")
    local FirmwareBmcs = require("wtop.collectors.firmware_bmcs")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local Report = require("wtop.report")
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(length, handle, fields)
        local data = string.pack("<BBI2", 38, length, handle)
            .. string.rep("\0", length - 4)
        for offset, value in pairs(fields or {}) do data = put(data, offset, value) end
        return data .. "\0\0"
    end
    local function entry3(maximum)
        local value = "_SM3_\0\24\3\9\0\1\0" .. string.pack("<I4I8", maximum, 0)
        local sum = 0
        for index = 1, #value do sum = (sum + value:byte(index)) % 256 end
        return put(value, 5, string.char((-sum) % 256))
    end
    local kcs = record(18, 0x3800, { [4] = "\1\32\32\255",
        [8] = string.pack("<I8", 0xca3), [16] = "\91\9" })
    local ssif = record(16, 0x3801, { [4] = "\4\32\32\255" })
    local ending = string.pack("<BBI2", 127, 4, 65535) .. "\0\0"
    local blob = kcs .. ssif .. ending
    local parsed = assert(SMBIOS.parse(blob))
    assert(not parsed.partial and #parsed.firmware_bmcs == 2)
    local a, b = parsed.firmware_bmcs[1], parsed.firmware_bmcs[2]
    assert(a.interface_type == "KCS" and a.ipmi_revision == "2.0"
        and a.i2c_target_address == 0x20 and a.nv_storage_address == nil
        and a.address_space == "io" and a.base_address_field_hex == "0xca3"
        and a.base_address_hex == "0xca3" and a.register_spacing_bytes == 4
        and a.interrupt_number == 9 and a.interrupt_polarity == "active_high"
        and a.interrupt_trigger == "level")
    assert(b.interface_type == "SSIF" and b.base_address_hex == nil
        and b.register_spacing_bytes == nil and b.interrupt_number == nil)
    local base = "/sys/firmware/dmi/tables"
    local fs = Fixture.new({ files = { [base .. "/DMI"] = blob,
        [base .. "/smbios_entry_point"] = entry3(#blob) } })
    local collector = FirmwareBmcs.new({ platform = "linux", fs = fs })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok"
        and result.quality == "fresh" and #result.data.devices == 2)
    local state = Snapshot.merge(nil, { firmware_bmcs = result }, 1, 1)
    local graph = Hardware.build(state)
    local node = graph.by_id["firmware-bmc:3800"]
    assert(node and node.resource == "firmware_bmcs" and node.parent_id == nil)
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local system = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "system", nil, nil,
        { system_query = "bus:firmware name:BMC" }).system_devices
    assert(#system.rows == 2)
    local detail = table.concat(TUI.hardware_detail_lines(state, node.id, i18n), "\n")
    assert(detail:find("IPMI revision: 2.0", 1, true)
        and detail:find("Base address field: 0xca3", 1, true)
        and detail:find("Base address: 0xca3", 1, true)
        and detail:find("Register spacing: 4 B", 1, true)
        and detail:find("current BMC availability is not measured", 1, true))
    local exported = Export.snapshot(state)
    assert(exported.firmware_bmcs.devices[1].base_address_hex == "0xca3"
        and exported.firmware_bmcs.devices[2].base_address_hex == nil)
    assert(Report.render(exported):find("Firmware BMC interfaces", 1, true))
    local legacy = assert(SMBIOS.parse(record(16, 0x3803,
        { [4] = "\1\32\32\255", [8] = string.pack("<I8", 0xca3) }) .. ending))
    assert(legacy.firmware_bmcs[1].base_address_field_hex == "0xca3"
        and legacy.firmware_bmcs[1].base_address_hex == nil)
    assert(not JSON.encode(exported):find("PRIVATE", 1, true))
    local duplicate = assert(SMBIOS.parse(kcs .. kcs .. ending))
    assert(duplicate.partial and duplicate.firmware_bmcs[1].ambiguous)
    local limited = assert(SMBIOS.parse(blob, nil, { max_firmware_bmcs = 1 }))
    assert(limited.truncated and #limited.firmware_bmcs == 1)
    local bad_revision = assert(SMBIOS.parse(put(kcs, 5, "\255") .. ending))
    assert(bad_revision.partial and bad_revision.firmware_bmcs[1].ipmi_revision == nil)
    local bad_modifier = assert(SMBIOS.parse(put(kcs, 16, "\255") .. ending))
    assert(bad_modifier.partial and bad_modifier.firmware_bmcs[1].base_address_hex == nil)
    local high_address = assert(SMBIOS.parse(put(kcs, 8,
        string.pack("<I8", 0x7000000000000003):sub(1, 7) .. "\128") .. ending))
    assert(not high_address.partial
        and high_address.firmware_bmcs[1].base_address_hex == "0x8000000000000003")
    local bad_ssif = assert(SMBIOS.parse(record(17, 0x3801,
        { [4] = "\4\32\32\255", [16] = "\1" }) .. ending))
    assert(bad_ssif.partial and bad_ssif.firmware_bmcs[1].register_spacing_bytes == nil)
    local short = assert(SMBIOS.parse(kcs .. record(15, 0x3802) .. ending))
    assert(short.partial and #short.firmware_bmcs == 1)
    local native = { read_smbios = function() return { data = blob, major = 3, minor = 9 } end }
    local portable = require("wtop.collectors.portable").new_all({ platform = "windows",
        common = { native = native } }).firmware_bmcs
    assert(portable:sample({}).data.devices[1].interface_type == "KCS")
    local empty = FirmwareBmcs.new({ platform = "linux", fs = Fixture.new({ files = {
        [base .. "/DMI"] = ending, [base .. "/smbios_entry_point"] = entry3(#ending),
    } }) }):sample({})
    assert(empty.status == "unavailable" and empty.reason == "no_firmware_bmcs")
    local denied = FirmwareBmcs.new({ platform = "linux", fs = Fixture.new({ denied = {
        [base .. "/DMI"] = true,
    } }) })
    assert(denied:probe({}).state == "denied" and denied:sample({}).status == "denied")
    assert(FirmwareBmcs.new({ platform = "windows", native = {} }):sample({}).status == "unavailable")
    assert(not pcall(FirmwareBmcs.new, { base_path = "relative" }))
end

-- Type 42 has bounded variable-length protocol records; raw interface payloads
-- can contain management network configuration and stay out of public output.
do
    local SMBIOS = require("wtop.format.smbios")
    local HostInterfaces = require("wtop.collectors.host_interfaces")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local Report = require("wtop.report")
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(handle, interface_type, payload, protocols)
        local body = string.char(interface_type, #payload) .. payload
            .. string.char(#protocols)
        for _, protocol in ipairs(protocols) do
            body = body .. string.char(protocol[1], #protocol[2]) .. protocol[2]
        end
        return string.pack("<BBI2", 42, 4 + #body, handle) .. body .. "\0\0"
    end
    local function entry3(maximum)
        local value = "_SM3_\0\24\3\9\0\1\0" .. string.pack("<I4I8", maximum, 0)
        local sum = 0
        for index = 1, #value do sum = (sum + value:byte(index)) % 256 end
        return put(value, 5, string.char((-sum) % 256))
    end
    local network = record(0x4200, 0x40, "PRIV", {
        { 2, "AB" }, { 3, "C" }, { 4, "IP!!" },
    })
    local oem = record(0x4201, 0xf0, "\0\0\18\52", { { 0xf0, "Z" } })
    local ending = string.pack("<BBI2", 127, 4, 65535) .. "\0\0"
    local blob = network .. oem .. ending
    local parsed = assert(SMBIOS.parse(blob))
    assert(not parsed.partial and #parsed.host_interfaces == 2)
    local a, b = parsed.host_interfaces[1], parsed.host_interfaces[2]
    assert(a.interface_type == "Network host interface" and a.interface_data_bytes == 4
        and a.protocol_count == 3 and #a.protocols == 3
        and a.protocols[1].type == "IPMI" and a.protocols[2].type == "MCTP"
        and a.protocols[3].type == "Redfish over IP"
        and a.protocols[3].data_bytes == 4)
    assert(b.interface_type == "OEM host interface" and b.oem_vendor_id == "00001234"
        and b.protocols[1].type == "OEM")
    local legacy = string.pack("<BBI2", 42, 13, 0x4202)
        .. "\240\0\0\18\52\1\240\1Z\0\0"
    local old = assert(SMBIOS.parse(legacy .. ending, { major = 3, minor = 1 }))
    assert(not old.partial and old.host_interfaces[1].legacy_oem_format
        and old.host_interfaces[1].oem_vendor_id == "00001234")
    local unknown_version = assert(SMBIOS.parse(legacy .. ending))
    assert(unknown_version.partial and unknown_version.host_interfaces[1].legacy_oem_format == nil,
        "a missing entry point must not guess the legacy OEM format")
    local base = "/sys/firmware/dmi/tables"
    local fs = Fixture.new({ files = { [base .. "/DMI"] = blob,
        [base .. "/smbios_entry_point"] = entry3(#blob) } })
    local collector = HostInterfaces.new({ platform = "linux", fs = fs })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok"
        and result.quality == "fresh" and #result.data.devices == 2)
    local state = Snapshot.merge(nil, { host_interfaces = result }, 1, 1)
    local graph = Hardware.build(state)
    local node = graph.by_id["host-interface:4200"]
    assert(node and node.resource == "host_interfaces" and node.parent_id == nil)
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local system = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "system", nil, nil,
        { system_query = "bus:firmware name:Network" }).system_devices
    assert(#system.rows == 1 and system.ids[1] == node.id)
    local detail = table.concat(TUI.hardware_detail_lines(state, node.id, i18n), "\n")
    assert(detail:find("Interface type: Network host interface", 1, true)
        and detail:find("Declared protocols: IPMI, MCTP, Redfish over IP", 1, true)
        and detail:find("live controller access is not measured", 1, true))
    local exported = Export.snapshot(state)
    assert(exported.host_interfaces.devices[1].protocols[3].type == "Redfish over IP"
        and exported.host_interfaces.devices[2].oem_vendor_id == "00001234")
    assert(Report.render(exported):find("Management host interfaces", 1, true))
    local encoded = JSON.encode(exported)
    assert(not encoded:find("PRIV", 1, true)
        and not encoded:find("IP!!", 1, true))
    local duplicate = assert(SMBIOS.parse(network .. network .. ending))
    assert(duplicate.partial and duplicate.host_interfaces[1].ambiguous)
    local limited = assert(SMBIOS.parse(blob, nil, { max_host_interfaces = 1 }))
    assert(limited.truncated and #limited.host_interfaces == 1)
    local bad_data_length = assert(SMBIOS.parse(put(network, 5, "\3") .. ending))
    assert(bad_data_length.partial and bad_data_length.host_interfaces[1].quality == "partial")
    local bad_protocol_length = assert(SMBIOS.parse(put(network, 12, "\255") .. ending))
    assert(bad_protocol_length.partial and #bad_protocol_length.host_interfaces[1].protocols == 0)
    local many = {}
    for index = 1, 65 do many[index] = { 2, "" } end
    local capped = assert(SMBIOS.parse(record(0x4203, 0x40, "DATA", many) .. ending))
    assert(capped.truncated and #capped.host_interfaces[1].protocols == 64)
    local native = { read_smbios = function() return { data = blob, major = 3, minor = 9 } end }
    local portable = require("wtop.collectors.portable").new_all({ platform = "windows",
        common = { native = native } }).host_interfaces
    assert(portable:sample({}).data.devices[1].protocol_count == 3)
    local empty = HostInterfaces.new({ platform = "linux", fs = Fixture.new({ files = {
        [base .. "/DMI"] = ending, [base .. "/smbios_entry_point"] = entry3(#ending),
    } }) }):sample({})
    assert(empty.status == "unavailable" and empty.reason == "no_host_interfaces")
    local denied = HostInterfaces.new({ platform = "linux", fs = Fixture.new({ denied = {
        [base .. "/DMI"] = true,
    } }) })
    assert(denied:probe({}).state == "denied" and denied:sample({}).status == "denied")
    assert(HostInterfaces.new({ platform = "windows", native = {} }):sample({}).status == "unavailable")
    assert(not pcall(HostInterfaces.new, { base_path = "relative" }))
end

-- Type 43 is a firmware TPM declaration, not current OS TPM or security state.
do
    local SMBIOS = require("wtop.format.smbios")
    local FirmwareTpms = require("wtop.collectors.firmware_tpms")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local Report = require("wtop.report")
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(length, handle, fields, strings)
        local data = string.pack("<BBI2", 43, length, handle)
            .. string.rep("\0", length - 4)
        for offset, value in pairs(fields or {}) do data = put(data, offset, value) end
        return data .. table.concat(strings or {}, "\0") .. "\0\0"
    end
    local function entry3(maximum)
        local value = "_SM3_\0\24\3\9\0\1\0" .. string.pack("<I4I8", maximum, 0)
        local sum = 0
        for index = 1, #value do sum = (sum + value:byte(index)) % 256 end
        return put(value, 5, string.char((-sum) % 256))
    end
    local primary = record(31, 0x4300, {
        [4] = "ABC\0\2\0", [10] = string.pack("<I4I4", 0x11223344, 0x55667788),
        [18] = "\1\24", [27] = "OEM!",
    }, { "Board TPM", "PRIVATE-TPM-STRING" })
    local unsupported = record(31, 0x4301, {
        [4] = "XYZ\0\1\2", [18] = "\1\4",
    }, { "Other TPM" })
    local ending = string.pack("<BBI2", 127, 4, 65535) .. "\0\0"
    local blob = primary .. unsupported .. ending
    local parsed = assert(SMBIOS.parse(blob))
    assert(not parsed.partial and #parsed.firmware_tpms == 2)
    local a, b = parsed.firmware_tpms[1], parsed.firmware_tpms[2]
    assert(a.vendor_id == "ABC" and a.spec_version == "2.0"
        and a.firmware_version_1_hex == "0x11223344"
        and a.firmware_version_2_hex == "0x55667788"
        and a.description == "Board TPM" and a.characteristics_supported
        and a.family_configurable_firmware and a.family_configurable_platform
        and not a.family_configurable_oem)
    assert(b.vendor_id == "XYZ" and b.spec_version == "1.2"
        and b.characteristics_supported == false
        and b.family_configurable_firmware == nil)
    local base = "/sys/firmware/dmi/tables"
    local fs = Fixture.new({ files = { [base .. "/DMI"] = blob,
        [base .. "/smbios_entry_point"] = entry3(#blob) } })
    local collector = FirmwareTpms.new({ platform = "linux", fs = fs })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok"
        and result.quality == "fresh" and #result.data.devices == 2)
    local state = Snapshot.merge(nil, { firmware_tpms = result }, 1, 1)
    local graph = Hardware.build(state)
    local node = graph.by_id["firmware-tpm:4300"]
    assert(node and node.resource == "firmware_tpms" and node.parent_id == nil)
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local system = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "system", nil, nil,
        { system_query = "bus:firmware name:Board" }).system_devices
    assert(#system.rows == 1 and system.ids[1] == node.id)
    local detail = table.concat(TUI.hardware_detail_lines(state, node.id, i18n), "\n")
    assert(detail:find("Vendor ID: ABC", 1, true)
        and detail:find("TPM specification: 2.0", 1, true)
        and detail:find("Firmware version field 1: 0x11223344", 1, true)
        and detail:find("current availability and security state are not measured", 1, true))
    local exported = Export.snapshot(state)
    assert(exported.firmware_tpms.devices[1].vendor_id == "ABC"
        and exported.firmware_tpms.devices[2].characteristics_supported == false)
    assert(Report.render(exported):find("Firmware TPM devices", 1, true))
    local encoded = JSON.encode(exported)
    assert(not encoded:find("PRIVATE-TPM", 1, true)
        and not encoded:find("OEM!", 1, true))
    local duplicate = assert(SMBIOS.parse(primary .. primary .. ending))
    assert(duplicate.partial and duplicate.firmware_tpms[1].ambiguous)
    local limited = assert(SMBIOS.parse(blob, nil, { max_firmware_tpms = 1 }))
    assert(limited.truncated and #limited.firmware_tpms == 1)
    local invalid_vendor = assert(SMBIOS.parse(put(primary, 4, "A\1C\0") .. ending))
    assert(invalid_vendor.partial and invalid_vendor.firmware_tpms[1].vendor_id == nil)
    local reserved = assert(SMBIOS.parse(put(primary, 20, "\1") .. ending))
    assert(reserved.partial and reserved.firmware_tpms[1].quality == "partial")
    local bad_v1_version = assert(SMBIOS.parse(put(unsupported, 14,
        string.pack("<I4", 1)) .. ending))
    assert(bad_v1_version.partial
        and bad_v1_version.firmware_tpms[1].quality == "partial")
    local short = assert(SMBIOS.parse(primary .. record(30, 0x4302) .. ending))
    assert(short.partial and #short.firmware_tpms == 1)
    local native = { read_smbios = function() return { data = blob, major = 3, minor = 9 } end }
    local portable = require("wtop.collectors.portable").new_all({ platform = "windows",
        common = { native = native } }).firmware_tpms
    assert(portable:sample({}).data.devices[1].vendor_id == "ABC")
    local empty = FirmwareTpms.new({ platform = "linux", fs = Fixture.new({ files = {
        [base .. "/DMI"] = ending, [base .. "/smbios_entry_point"] = entry3(#ending),
    } }) }):sample({})
    assert(empty.status == "unavailable" and empty.reason == "no_firmware_tpms")
    local denied = FirmwareTpms.new({ platform = "linux", fs = Fixture.new({ denied = {
        [base .. "/DMI"] = true,
    } }) })
    assert(denied:probe({}).state == "denied" and denied:sample({}).status == "denied")
    assert(FirmwareTpms.new({ platform = "windows", native = {} }):sample({}).status == "unavailable")
    assert(not pcall(FirmwareTpms.new, { base_path = "relative" }))
end

-- Firmware processor sockets and cache records remain separate from OS CPU topology.
do
    local SMBIOS = require("wtop.format.smbios")
    local ProcessorFirmware = require("wtop.collectors.processor_firmware")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(kind, length, handle, fields, strings)
        local data = string.pack("<BBI2", kind, length, handle) .. string.rep("\0", length - 4)
        for offset, value in pairs(fields or {}) do data = put(data, offset, value) end
        return data .. table.concat(strings or {}, "\0") .. "\0\0"
    end
    local function word(value) return string.pack("<I2", value) end
    local function dword(value) return string.pack("<I4", value) end
    local socket = record(4, 50, 0x4000, {
        [4] = "\1\3\179\2", [16] = "\3", [18] = word(100),
        [20] = word(4000), [22] = word(3200), [24] = "\65\63",
        [26] = word(0x5001) .. word(0x5002) .. word(0xffff),
        [32] = "\4\5\6\255\8\255", [42] = word(300),
        [44] = word(8), [46] = word(600), [48] = word(590),
    }, { "CPU_A", "Fixture Maker", "Fixture CPU", "PRIVATE-SERIAL",
        "PRIVATE-ASSET", "Fixture Part" })
    local empty = record(4, 26, 0x4001, { [4] = "\1", [24] = "\0\2" }, { "CPU_B" })
    local l1 = record(7, 19, 0x5001, {
        [4] = "\1", [5] = word(0x80), [7] = word(32), [9] = word(32),
        [15] = "\2\5\4\7",
    }, { "CACHE_L1" })
    local l2 = record(7, 27, 0x5002, {
        [4] = "\1", [5] = word(0x81), [7] = word(0xffff),
        [9] = word(0xffff), [15] = "\3\6\5\8",
        [19] = dword(0x80008000), [23] = dword(0x80004000),
    }, { "CACHE_L2" })
    local unreferenced = record(7, 19, 0x5003, {
        [4] = "\1", [5] = word(0x82), [7] = word(8192), [9] = word(8192),
    }, { "CACHE_L3" })
    local ending = record(127, 4, 65535)
    local blob = socket .. empty .. l1 .. l2 .. unreferenced .. ending
    local function entry3(maximum)
        local value = "_SM3_\0\24\3\8\0\1\0" .. string.pack("<I4I8", maximum, 0)
        local sum = 0
        for index = 1, #value do sum = (sum + value:byte(index)) % 256 end
        return put(value, 5, string.char((-sum) % 256))
    end
    local parsed = assert(SMBIOS.parse(blob, assert(SMBIOS.entry_point(entry3(#blob)))))
    assert(not parsed.partial and #parsed.processors == 2 and #parsed.caches == 3)
    local cpu = parsed.processors[1]
    assert(cpu.id == "4000" and cpu.designation == "CPU_A" and cpu.populated)
    assert(cpu.manufacturer == "Fixture Maker" and cpu.version == "Fixture CPU"
        and cpu.part_number == "Fixture Part")
    assert(cpu.core_count == 300 and cpu.enabled_core_count == 8)
    assert(cpu.thread_count == 600 and cpu.enabled_thread_count == 590)
    assert(cpu.cache_handles.l1 == "5001" and cpu.cache_handles.l2 == "5002"
        and cpu.cache_handles.l3 == nil)
    assert(not parsed.processors[2].populated and parsed.processors[2].core_count == nil)
    assert(parsed.caches[1].level == 1 and parsed.caches[1].cache_type == "Data"
        and parsed.caches[1].installed_size_bytes == 32 * 1024)
    assert(parsed.caches[2].maximum_size_bytes == 2 * 1024^3
        and parsed.caches[2].installed_size_bytes == 1024^3)
    assert(not JSON.encode(parsed):find("PRIVATE", 1, true))
    local old_count = put(socket, 35, "\255")
    old_count = old_count:sub(1, 42) .. "\0\0" .. old_count:sub(45)
    assert(assert(SMBIOS.parse(old_count .. ending)).processors[1].core_count == 255)
    local missing_size = assert(SMBIOS.parse(socket .. record(7, 19, 0x5002, {
        [5] = word(0x81), [7] = word(0xffff), [9] = word(0),
    }) .. ending))
    assert(missing_size.partial and missing_size.caches[1].maximum_size_bytes == nil)
    local extended_kib = assert(SMBIOS.parse(socket .. record(7, 27, 0x5002, {
        [5] = word(0x81), [7] = word(0xffff), [9] = word(0),
        [19] = dword(0x00008000), [23] = dword(0),
    }) .. ending))
    assert(extended_kib.caches[1].maximum_size_bytes == 32 * 1024^2,
        "extended cache sizes use their own granularity bit")
    assert(assert(SMBIOS.parse(blob, nil, { max_processors = 1 })).truncated)
    assert(assert(SMBIOS.parse(blob, nil, { max_caches = 2 })).truncated)
    for length = 0, #blob - 1 do
        local ok, value = pcall(SMBIOS.parse, blob:sub(1, length))
        assert(ok and (value == nil or value.partial), "truncated Type 4/7 table at " .. length)
    end
    local base = "/sys/firmware/dmi/tables"
    local files = { [base .. "/DMI"] = blob, [base .. "/smbios_entry_point"] = entry3(#blob) }
    local collector = ProcessorFirmware.new({ fs = Fixture.new({ files = files }), platform = "linux" })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok" and result.quality == "fresh")
    local state = Snapshot.merge(nil, { processor_firmware = result }, 1, 1)
    local graph = Hardware.build(state)
    local first = graph.by_id["firmware-socket:4000"]
    assert(first and #first.cache_ids == 2 and first.cache_ids[1] == "firmware-cache:5001")
    assert(graph.by_id["firmware-cache:5001"].parent_id == first.id)
    assert(graph.by_id["firmware-cache:5002"].parent_id == first.id)
    assert(graph.by_id["firmware-cache:5003"].parent_id == nil,
        "unreferenced firmware caches cannot be attached by level alone")
    assert(graph.by_id["firmware-socket:4001"].parent_id == nil)
    local exported = Export.snapshot(state)
    assert(#exported.processor_firmware.processors == 2 and #exported.processor_firmware.caches == 3)
    assert(exported.processor_firmware.processors[1].cache_handles.l1 == "5001")
    assert(not JSON.encode(exported):find("PRIVATE", 1, true))
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local detail = table.concat(TUI.hardware_detail_lines(state, first.id, i18n), "\n")
    assert(detail:find("Fixture CPU", 1, true) and detail:find("Firmware cache records", 1, true)
        and detail:find("operating system", 1, true) and not detail:find("PRIVATE", 1, true))
    local cache_detail = table.concat(TUI.hardware_detail_lines(state, "firmware-cache:5002", i18n), "\n")
    assert(cache_detail:find("1 GiB", 1, true) and cache_detail:find("Firmware cache report", 1, true))
    local rows = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "system").system_devices.rows
    local saw_socket, saw_cache = false, false
    for _, row in ipairs(rows) do
        if row.bus == "FIRMWARE" and row.id == "4000" then saw_socket = true end
        if row.bus == "FIRMWARE" and row.id == "5002" then saw_cache = true end
    end
    assert(saw_socket and saw_cache)
    local duplicate = assert(SMBIOS.parse(socket .. l1 .. l1 .. ending))
    local duplicate_graph = Hardware.build({ processor_firmware = duplicate })
    assert(duplicate.partial and duplicate_graph.partial)
    assert(#duplicate_graph.by_id["firmware-socket:4000"].cache_ids == 0,
        "duplicate cache handles cannot establish a firmware relationship")
    local dangling_graph = Hardware.build({ processor_firmware = assert(SMBIOS.parse(socket .. ending)) })
    assert(dangling_graph.partial and #dangling_graph.by_id["firmware-socket:4000"].cache_ids == 0)
    local mismatch = assert(SMBIOS.parse(socket .. put(l1, 5, word(0x82)) .. l2 .. ending))
    assert(Hardware.build({ processor_firmware = mismatch }).partial,
        "a cache reference with the wrong level is not linked")
    local shared = assert(SMBIOS.parse(socket .. put(socket, 2, word(0x4002)) .. l1 .. l2 .. ending))
    local shared_graph = Hardware.build({ processor_firmware = shared })
    assert(shared_graph.by_id["firmware-cache:5001"].parent_id == nil
        and #shared_graph.by_id["firmware-cache:5001"].firmware_socket_ids == 2)
    local no_entry = ProcessorFirmware.new({ fs = Fixture.new({ files = {
        [base .. "/DMI"] = blob,
    } }), platform = "linux" }):sample({})
    assert(no_entry.quality == "partial" and #no_entry.data.processors == 2)
    local denied = ProcessorFirmware.new({ fs = Fixture.new({ denied = {
        [base .. "/DMI"] = true,
    } }), platform = "linux" })
    assert(denied:probe({}).state == "denied" and denied:sample({}).status == "denied")
    local none = ProcessorFirmware.new({ fs = Fixture.new({ files = {
        [base .. "/DMI"] = ending,
        [base .. "/smbios_entry_point"] = entry3(#ending),
    } }), platform = "linux" }):sample({})
    assert(none.status == "unavailable" and none.reason == "no_processor_firmware")
    local native = { read_smbios = function() return { data = blob, major = 3, minor = 8 } end }
    local portable = require("wtop.collectors.portable").new_all({ platform = "windows",
        common = { native = native } }).processor_firmware
    assert(portable:sample({}).data.processors[1].designation == "CPU_A")
    assert(portable:sample({}).source == "native:read_smbios")
    assert(ProcessorFirmware.new({ platform = "windows", native = {} }):sample({}).status == "unavailable")
    assert(not pcall(ProcessorFirmware.new, { base_path = "relative" }))
end

do
    local CPUIdle = require("wtop.collectors.cpuidle")
    local Fixture = require("support.fixture_fs")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local base = "/sys/devices/system/cpu"
    local files = { [base .. "/cpuidle/current_driver"] = "intel_idle\n",
        [base .. "/cpuidle/current_governor_ro"] = "menu\n" }
    local function state(cpu, id, usage, time, rejected, above, below)
        local path = base .. "/cpu" .. cpu .. "/cpuidle/state" .. id .. "/"
        files[path .. "name"] = id == 0 and "POLL\n" or "C1\n"
        files[path .. "usage"] = tostring(usage) .. "\n"
        files[path .. "time"] = tostring(time) .. "\n"
        files[path .. "rejected"] = tostring(rejected) .. "\n"
        files[path .. "above"] = tostring(above) .. "\n"
        files[path .. "below"] = tostring(below) .. "\n"
        files[path .. "latency"] = "1\n"
        files[path .. "residency"] = "10\n"
        files[path .. "disable"] = "0\n"
    end
    state(0, 0, 10, 1000, 1, 2, 3)
    state(0, 1, 20, 2000, 0, 5, 7)
    state(1, 0, 30, 3000, 0, 0, 0)
    local collector = CPUIdle.new({ fs = Fixture.new({ files = files }) })
    assert(collector:probe({}).available)
    local first = collector:sample({})
    assert(first.status == "ok" and first.quality == "fresh")
    assert(first.data.driver == "intel_idle" and first.data.governor == "menu")
    assert(first.data.cpus[1].states[1].usage_delta == nil)
    assert(first.data.cpus[1].states[1].time_delta_quality == "gap")
    assert(first.data.cpus[1].states[1].rejected_delta_quality == "gap")
    state(0, 0, 14, 2500, 3, 6, 8)
    state(0, 1, 23, 3400, 0, 8, 9)
    state(1, 0, 31, 3200, 0, 1, 1)
    local second = collector:sample({})
    local state0 = second.data.cpus[1].states[1]
    assert(state0.usage_delta == 4 and state0.new_time_us == 1500)
    assert(state0.usage_delta_quality == "fresh" and state0.time_delta_quality == "fresh")
    assert(state0.target_residency_us == 10 and state0.exit_latency_us == 1)
    assert(state0.rejected_delta == 2 and state0.above_delta == 4
        and state0.below_delta == 5)
    assert(state0.rejected_delta_quality == "fresh")
    local snapshot = Snapshot.merge(nil, { cpuidle = second }, 1, 1)
    local exported = Export.snapshot(snapshot)
    assert(exported.cpuidle.cpus[1].states[1].new_time_us == 1500)
    assert(exported.cpuidle.cpus[1].states[1].usage == 14)
    assert(exported.cpuidle.cpus[1].states[1].rejected == 3)
    assert(exported.cpuidle.cpus[1].states[1].above_delta == 4)
    local view = ViewModel.build({ history_values = function() return {} end }, snapshot,
        assert(I18n.new({ locale = "en-US" })), {}, "compute")
    assert(#view.cpuidle_table.rows == 3)
    assert(view.cpuidle_table.rows[1].usage_delta == "4")
    assert(view.cpuidle_table.rows[1].reported_ms == "1.5")
    assert(view.cpuidle_table.rows[1].rejected_delta == "2")
    assert(view.cpuidle_table.rows[1].above_delta == "4")
    assert(view.cpuidle_table.rows[1].below_delta == "5")
    local many = { cpus = {} }
    for id = 0, 512 do
        many.cpus[#many.cpus + 1] = { id = id, states = {
            { id = 0, name = "C1", usage_delta = id, new_time_us = 1000,
                usage_delta_quality = "fresh", time_delta_quality = "fresh" },
        } }
    end
    local large_view = ViewModel.build({ history_values = function() return {} end },
        Snapshot.merge(nil, { cpuidle = { status = "ok", quality = "fresh",
            timestamp_ns = 1, data = many } }, 1, 1),
        assert(I18n.new({ locale = "en-US" })), {}, "compute")
    assert(#large_view.cpuidle_table.rows == 512)
    assert(large_view.cpuidle_table.status_text:find("512 of 513", 1, true))
    state(0, 0, 1, 50, 1, 1, 1)
    local reset = collector:sample({})
    assert(reset.data.cpus[1].states[1].usage_delta == nil)
    assert(reset.data.cpus[1].states[1].time_delta_quality == "reset")
    assert(reset.data.cpus[1].states[1].rejected_delta_quality == "reset")
    assert(reset.data.cpus[1].states[1].above_delta == nil)
    files[base .. "/cpu0/cpuidle/state1/time"] = "invalid\n"
    local partial = collector:sample({})
    assert(partial.quality == "partial" and partial.reason == "cpuidle_data_incomplete")
    assert(partial.data.cpus[1].states[2].time_us == nil)
    files[base .. "/cpu0/cpuidle/state1/time"] = "3400\n"
    files[base .. "/cpu0/cpuidle/state1/rejected"] = "bad\n"
    local optional_bad = collector:sample({})
    assert(optional_bad.quality == "partial"
        and optional_bad.data.cpus[1].states[2].rejected_delta_quality == "unavailable")
    files[base .. "/cpu0/cpuidle/state1/rejected"] = "0\n"
    local capped = CPUIdle.new({ fs = Fixture.new({ files = files }), max_cpus = 1,
        max_states = 1 }):sample({})
    assert(capped.quality == "partial" and capped.data.truncated)
    assert(#capped.data.cpus == 1 and #capped.data.cpus[1].states == 1)
    local later = CPUIdle.new({ max_cpus = 1, fs = Fixture.new({
        files = { [base .. "/cpu1/cpuidle/state0/usage"] = "3\n",
            [base .. "/cpu1/cpuidle/state0/time"] = "30\n" },
        dirs = { [base .. "/cpu0/cpuidle"] = {} },
    }) })
    assert(later:probe({}).reason == "no_cpuidle_states")
    assert(later:sample({}).status == "unavailable")
    local only_basic = CPUIdle.new({ fs = Fixture.new({ files = {
        [base .. "/cpu0/cpuidle/state0/usage"] = "3\n",
        [base .. "/cpu0/cpuidle/state0/time"] = "30\n",
    } }) }):sample({})
    assert(only_basic.quality == "fresh"
        and only_basic.data.cpus[1].states[1].rejected_delta_quality == "unavailable",
        "older kernels can omit optional diagnostics without losing idle usage")
    local absent = CPUIdle.new({ fs = Fixture.new({ files = {} }) })
    assert(absent:probe({}).reason == "no_cpuidle_states")
    assert(absent:sample({}).status == "unavailable")
    local denied = CPUIdle.new({ fs = Fixture.new({ denied = { [base] = true } }) })
    assert(denied:probe({}).state == "denied")
    assert(denied:sample({}).status == "denied")
end

-- Type 45 exposes firmware components and explicit SMBIOS association handles.
-- A free-form firmware ID is deliberately not published: firmware may use it
-- for a machine-specific asset or serial identifier.
do
    local SMBIOS = require("wtop.format.smbios")
    local FirmwareComponents = require("wtop.collectors.firmware_components")
    local FirmwareTpms = require("wtop.collectors.firmware_tpms")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local Report = require("wtop.report")
    local function put(data, offset, value)
        return data:sub(1, offset) .. value .. data:sub(offset + #value + 1)
    end
    local function record(kind, length, handle, fields, strings)
        local data = string.pack("<BBI2", kind, length, handle)
            .. string.rep("\0", length - 4)
        for offset, value in pairs(fields or {}) do data = put(data, offset, value) end
        return data .. table.concat(strings or {}, "\0") .. "\0\0"
    end
    local function entry3(maximum)
        local value = "_SM3_\0\24\3\9\0\1\0" .. string.pack("<I4I8", maximum, 0)
        local sum = 0
        for index = 1, #value do sum = (sum + value:byte(index)) % 256 end
        return put(value, 5, string.char((-sum) % 256))
    end
    local guid = "1624A9DF-5E13-47FC-874A-DF3AFF143089"
    local primary_fields = {
        [4] = "\1\2\1\3\1\4\5\6",
        [12] = string.pack("<I8I2BBI2", 16384, 3, 4, 1, 0x4300),
    }
    local primary = record(45, 26, 0x4500, primary_fields,
        { "BMC firmware", "2.7", guid, "2026-01-05T00:00:00Z",
          "Board vendor", "1.5" })
    local private = record(45, 24, 0x4501, {
        [4] = "\1\2\0\3\0\0\4\0",
        [12] = string.rep("\255", 8) .. string.pack("<I2BB", 0, 2, 0),
    }, { "Platform firmware", "1.0", "PRIVATE-SERIAL-123", "Board vendor" })
    local tpm = record(43, 31, 0x4300, {
        [4] = "ABC\0\2\0", [10] = string.pack("<I4I4", 1, 2),
        [18] = "\1\24",
    }, { "Board TPM" })
    local ending = string.pack("<BBI2", 127, 4, 65535) .. "\0\0"
    local blob = primary .. private .. tpm .. ending
    local parsed = assert(SMBIOS.parse(blob))
    assert(not parsed.partial and #parsed.firmware_components == 2)
    local a, b = parsed.firmware_components[1], parsed.firmware_components[2]
    assert(a.name == "BMC firmware" and a.version == "2.7"
        and a.version_format == 1 and a.firmware_id == guid:lower()
        and a.release_date == "2026-01-05T00:00:00Z"
        and a.manufacturer == "Board vendor"
        and a.lowest_supported_version == "1.5"
        and a.image_size_bytes == 16384 and a.image_size_hex == nil
        and a.updatable and a.write_protected and a.state == "Enabled"
        and a.association_complete and a.associated_count == 1
        and a.associated_handles[1] == "4300")
    assert(b.firmware_id == nil and b.image_size_bytes == nil
        and b.state == "Unknown" and b.associated_count == 0,
        "free-form firmware IDs and unknown image size stay out of the inventory")
    local base = "/sys/firmware/dmi/tables"
    local fs = Fixture.new({ files = { [base .. "/DMI"] = blob,
        [base .. "/smbios_entry_point"] = entry3(#blob) } })
    local collector = FirmwareComponents.new({ platform = "linux", fs = fs })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok"
        and result.quality == "fresh" and #result.data.components == 2)
    local tpm_result = FirmwareTpms.new({ platform = "linux", fs = fs }):sample({})
    local state = Snapshot.merge(nil,
        { firmware_components = result, firmware_tpms = tpm_result }, 1, 1)
    local graph = Hardware.build(state)
    local component = graph.by_id["firmware-component:4500"]
    local tpm_node = graph.by_id["firmware-tpm:4300"]
    assert(component and tpm_node and component.parent_id == nil
        and component.associated_ids[1] == tpm_node.id
        and tpm_node.firmware_component_ids[1] == component.id,
        "an explicit Type 45 handle makes a navigable two-way reference, not a parent")
    assert(Hardware.related(graph, component.id).items[1].id == tpm_node.id)
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local system = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "system", nil, nil,
        { system_query = "bus:firmware name:BMC" }).system_devices
    assert(#system.rows == 1 and system.ids[1] == component.id)
    local detail = table.concat(TUI.hardware_detail_lines(state, component.id, i18n), "\n")
    assert(detail:find("Component: BMC firmware", 1, true)
        and detail:find("Version: 2.7", 1, true)
        and detail:find("Image size: 16 KiB", 1, true)
        and detail:find("Board TPM", 1, true)
        and detail:find("live health and update availability are not measured", 1, true))
    local exported = Export.snapshot(state)
    assert(exported.firmware_components.components[1].firmware_id == guid:lower()
        and exported.firmware_components.components[1].associated_handles[1] == "4300"
        and exported.firmware_components.components[2].firmware_id == nil)
    assert(by_id(exported.inventory.topology.nodes, component.id).associated_ids[1]
        == tpm_node.id and by_id(exported.inventory.topology.nodes,
        tpm_node.id).firmware_component_ids[1] == component.id,
        "Snapshot topology exports the same Type 45 handle links as the TUI")
    assert(Report.render(exported):find("Firmware components", 1, true))
    assert(not JSON.encode(exported):find("PRIVATE-SERIAL", 1, true),
        "a free-form firmware ID cannot escape through Snapshot JSON")
    local limited = assert(SMBIOS.parse(blob, nil, { max_firmware_components = 1 }))
    assert(limited.truncated and #limited.firmware_components == 1)
    local reserved = assert(SMBIOS.parse(record(45, 26, 0x4500, {
        [4] = primary_fields[4],
        [12] = string.pack("<I8I2BBI2", 16384, 0x8003, 4, 1, 0x4300),
    }, { "BMC firmware", "2.7", guid, "2026-01-05T00:00:00Z",
         "Board vendor", "1.5" }) .. ending))
    assert(reserved.partial and reserved.firmware_components[1].quality == "partial")
    local short = assert(SMBIOS.parse(record(45, 24, 0x4500, {
        [4] = primary_fields[4],
        [12] = string.pack("<I8I2BB", 16384, 3, 4, 1),
    }, { "BMC firmware", "2.7", guid, "2026-01-05T00:00:00Z",
         "Board vendor", "1.5" }) .. ending))
    assert(short.partial and not short.firmware_components[1].association_complete
        and #short.firmware_components[1].associated_handles == 0)
    local extended = assert(SMBIOS.parse(record(45, 28, 0x4500, {
        [4] = primary_fields[4],
        [12] = string.pack("<I8I2BBI2I2", 16384, 3, 4, 1, 0x4300, 0x9999),
    }, { "BMC firmware", "2.7", guid, "2026-01-05T00:00:00Z",
         "Board vendor", "1.5" }) .. ending))
    assert(not extended.partial and extended.firmware_components[1].associated_count == 1
        and #extended.firmware_components[1].associated_handles == 1,
        "the declared count, not the formatted length, bounds association handles")
    local repeated = assert(SMBIOS.parse(record(45, 28, 0x4500, {
        [4] = primary_fields[4],
        [12] = string.pack("<I8I2BBI2I2", 16384, 3, 4, 2, 0x4300, 0x4300),
    }, { "BMC firmware", "2.7", guid, "2026-01-05T00:00:00Z",
         "Board vendor", "1.5" }) .. tpm .. ending))
    assert(repeated.partial and not repeated.firmware_components[1].association_complete)
    local repeated_graph = Hardware.build({ firmware_components = {
        components = repeated.firmware_components }, firmware_tpms = {
        devices = repeated.firmware_tpms } })
    assert(#repeated_graph.by_id["firmware-component:4500"].associated_ids == 0,
        "a duplicate association cannot become a graph link")
    local invalid_id = assert(SMBIOS.parse(record(45, 26, 0x4500, {
        [4] = primary_fields[4],
        [12] = primary_fields[12],
    }, { "BMC firmware", "2.7", "PRIVATE-SERIAL", "2026-01-05T00:00:00Z",
         "Board vendor", "1.5" }) .. ending))
    assert(invalid_id.partial and invalid_id.firmware_components[1].firmware_id == nil,
        "a malformed standard GUID cannot turn into a public identity")
    local high_size = assert(SMBIOS.parse(record(45, 26, 0x4500, {
        [4] = primary_fields[4],
        [12] = "\1\0\0\0\0\0\0\128" .. string.pack("<I2BBI2", 3, 4, 1, 0x4300),
    }, { "BMC firmware", "2.7", guid, "2026-01-05T00:00:00Z",
         "Board vendor", "1.5" }) .. ending))
    assert(high_size.firmware_components[1].image_size_bytes == nil
        and high_size.firmware_components[1].image_size_hex == "0x8000000000000001",
        "an unsigned 64-bit size above Lua's integer range remains exact text")
    local ambiguous_graph = Hardware.build({ firmware_components = {
        components = { a } }, firmware_tpms = { devices = parsed.firmware_tpms },
        firmware_batteries = { batteries = {
            { id = "4300", handle = 0x4300, name = "colliding handle" },
        } } })
    assert(#ambiguous_graph.by_id["firmware-component:4500"].associated_ids == 0,
        "two graph nodes with one SMBIOS handle cannot receive a guessed link")
    local duplicate = assert(SMBIOS.parse(primary .. primary .. ending))
    assert(duplicate.partial and duplicate.firmware_components[1].ambiguous)
    local native = { read_smbios = function()
        return { data = blob, major = 3, minor = 9 }
    end }
    local portable = require("wtop.collectors.portable").new_all({ platform = "windows",
        common = { native = native } }).firmware_components
    assert(portable:sample({}).data.components[1].version == "2.7")
    local empty = FirmwareComponents.new({ platform = "linux", fs = Fixture.new({ files = {
        [base .. "/DMI"] = ending, [base .. "/smbios_entry_point"] = entry3(#ending),
    } }) }):sample({})
    assert(empty.status == "unavailable" and empty.reason == "no_firmware_components")
    local denied = FirmwareComponents.new({ platform = "linux", fs = Fixture.new({ denied = {
        [base .. "/DMI"] = true,
    } }) })
    assert(denied:probe({}).state == "denied" and denied:sample({}).status == "denied")
    assert(FirmwareComponents.new({ platform = "windows", native = {} }):sample({}).status
        == "unavailable")
end

-- Linux ESRT exposes capsule-targetable firmware resources. Type 45 can name
-- the same standard GUID, so that exact GUID makes a cross-source reference;
-- a status code of zero must not be presented as proof an update succeeded.
do
    local Esrt = require("wtop.collectors.firmware_esrt")
    local Fixture = require("support.fixture_fs")
    local Hardware = require("wtop.model.hardware")
    local ViewModel = require("wtop.view_model")
    local I18n = require("wtop.i18n")
    local TUI = require("wtop.tui")
    local Report = require("wtop.report")
    local JSON = require("wtop.format.json")
    local base = "/sys/firmware/efi/esrt"
    local first_guid = "1624A9DF-5E13-47FC-874A-DF3AFF143089"
    local second_guid = "874A9DF1-5E13-47FC-874A-DF3AFF143089"
    local files = {
        [base .. "/fw_resource_count"] = "2\n",
        [base .. "/fw_resource_version"] = "1\n",
    }
    for index, spec in ipairs({ { first_guid, "1", "16777218", "1", "0x5", "0", "0" },
            { second_guid, "2", "10", "5", "0x0", "9", "5" } }) do
        local path = base .. "/entries/entry" .. (index - 1)
        for field, value in pairs({ fw_class = spec[1], fw_type = spec[2],
            fw_version = spec[3], lowest_supported_fw_version = spec[4],
            capsule_flags = spec[5], last_attempt_version = spec[6],
            last_attempt_status = spec[7] }) do
            files[path .. "/" .. field] = value .. "\n"
        end
    end
    local fs = Fixture.new({ files = files,
        dirs = { [base .. "/entries"] = { "entry1", "entry0" } } })
    local collector = Esrt.new({ platform = "linux", fs = fs })
    local result = collector:sample({})
    assert(collector:probe({}).available and result.status == "ok"
        and result.quality == "fresh" and result.data.scanned == 2
        and result.data.declared_count == 2 and result.data.resource_version == 1)
    local a, b = result.data.entries[1], result.data.entries[2]
    assert(a.id == "entry0" and a.guid == first_guid:lower()
        and a.type == "System firmware" and a.version == 16777218
        and a.lowest_supported_version == 1 and a.capsule_flags_hex == "0x5"
        and a.last_attempt_version == 0 and a.last_attempt_status == 0
        and b.id == "entry1" and b.type == "Device firmware"
        and b.last_attempt_status == 5,
        "ESRT sysfs values remain raw, ordered by entry number and bounded")
    local component = { id = "4500", handle = 0x4500, name = "Platform firmware",
        firmware_id = first_guid:lower(), association_complete = true,
        associated_handles = {}, quality = "fresh" }
    local state = Snapshot.merge(nil, { firmware_esrt = result }, 1, 1)
    state.firmware_components = { components = { component } }
    local visible_resources = ViewModel.build({ history_values = function() return {} end },
        state, assert(I18n.new({ locale = "en-US" })), {}, "system", nil,
        { system_firmware = true }).system_firmware.entries
    assert(visible_resources[1].label_id == "system.esrt_resources"
        and visible_resources[1].value == "2",
        "readable ESRT entries appear in the System firmware summary")
    local graph = Hardware.build(state)
    local component_node = graph.by_id["firmware-component:4500"]
    local esrt_node = graph.by_id["esrt:entry0"]
    assert(component_node and esrt_node and component_node.parent_id == nil
        and esrt_node.parent_id == nil
        and component_node.esrt_ids[1] == esrt_node.id
        and esrt_node.firmware_component_ids[1] == component_node.id,
        "a unique standard GUID links Type 45 and ESRT without making a parent")
    assert(Hardware.related(graph, component_node.id).items[1].id == esrt_node.id)
    local i18n = assert(I18n.new({ locale = "en-US" }))
    local system = ViewModel.build({ history_values = function() return {} end },
        state, i18n, {}, "system", nil, nil,
        { system_query = "bus:firmware name:System" }).system_devices
    assert(#system.rows == 1 and system.ids[1] == esrt_node.id)
    local detail = table.concat(TUI.hardware_detail_lines(state, esrt_node.id, i18n), "\n")
    assert(detail:find("Firmware class GUID: " .. first_guid:lower(), 1, true)
        and detail:find("Installed version: 16777218", 1, true)
        and detail:find("Last attempt code: 0", 1, true)
        and detail:find("Code 0 can also mean no update was attempted", 1, true))
    local exported = Export.snapshot(state)
    assert(exported.firmware_esrt.entries[1].guid == first_guid:lower()
        and exported.firmware_esrt.entries[1].last_attempt_status == 0)
    assert(by_id(exported.inventory.topology.nodes, component_node.id).esrt_ids[1]
        == esrt_node.id and by_id(exported.inventory.topology.nodes,
        esrt_node.id).firmware_component_ids[1] == component_node.id,
        "Snapshot topology exports both sides of the exact GUID link")
    assert(Report.render(exported):find("UEFI firmware resources", 1, true))
    assert(not JSON.encode(exported):find("last_attempt_success", 1, true),
        "status code zero must remain a code, not an invented success verdict")
    local denied_fs = Fixture.new({ dirs = { [base .. "/entries"] = { "entry0" } },
        denied = { [base .. "/fw_resource_count"] = true,
            [base .. "/fw_resource_version"] = true,
            [base .. "/entries/entry0/fw_class"] = true } })
    local denied = Esrt.new({ platform = "linux", fs = denied_fs }):sample({})
    assert(denied.status == "ok" and denied.quality == "partial"
        and denied.data.scanned == 1 and denied.data.entries[1].status == "denied"
        and denied.data.entries[1].guid == nil and #denied.data.issues == 3,
        "visible directory entries survive root-only attributes without invented values")
    assert(Hardware.build({ firmware_esrt = denied.data }).by_id["esrt:entry0"] == nil,
        "an unreadable GUID cannot be used as a device identity")
    local unavailable_firmware = Snapshot.merge(nil, { firmware_esrt = denied }, 1, 1)
    local firmware_rows = ViewModel.build({ history_values = function() return {} end },
        unavailable_firmware, i18n, {}, "system", nil,
        { system_firmware = true }).system_firmware.entries
    assert(firmware_rows[1].label_id == "system.esrt_resources"
        and firmware_rows[1].value == "1 · 1 denied"
        and firmware_rows[2].label_id == "system.firmware_unavailable",
        "System shows discovered but unreadable ESRT entries even without DMI")
    local chinese_rows = ViewModel.build({ history_values = function() return {} end },
        unavailable_firmware, assert(I18n.new({ locale = "zh-CN" })), {},
        "system", nil, { system_firmware = true }).system_firmware.entries
    assert(chinese_rows[1].value == "1 · 1 项无权限",
        "the visible ESRT permission summary is localized")
    local duplicate_files = {}
    for path, value in pairs(files) do duplicate_files[path] = value end
    duplicate_files[base .. "/entries/entry1/fw_class"] = first_guid .. "\n"
    local duplicate = Esrt.new({ platform = "linux", fs = Fixture.new({ files = duplicate_files,
        dirs = { [base .. "/entries"] = { "entry0", "entry1" } } }) }):sample({})
    assert(duplicate.quality == "partial" and duplicate.data.entries[1].ambiguous
        and duplicate.data.entries[2].ambiguous)
    local duplicate_graph = Hardware.build({ firmware_esrt = duplicate.data,
        firmware_components = { components = { component } } })
    assert(#duplicate_graph.by_id["firmware-component:4500"].esrt_ids == 0,
        "duplicate ESRT GUIDs cannot select one arbitrary firmware resource")
    local second_component = { id = "4501", handle = 0x4501,
        name = "Another component", firmware_id = first_guid:lower(),
        association_complete = true, associated_handles = {}, quality = "fresh" }
    local duplicate_component_graph = Hardware.build({ firmware_esrt = result.data,
        firmware_components = { components = { component, second_component } } })
    assert(#duplicate_component_graph.by_id["esrt:entry0"].firmware_component_ids == 0,
        "two Type 45 records with one GUID cannot select one arbitrary component")
    local stale_graph = Hardware.build({ firmware_esrt = result.data,
        firmware_components = { components = { component } },
        quality = { firmware_esrt = { status = "ok", quality = "stale" } } })
    assert(#stale_graph.by_id["firmware-component:4500"].esrt_ids == 0,
        "an old ESRT snapshot cannot establish a current firmware reference")
    local capped = Esrt.new({ platform = "linux", fs = fs, max_entries = 1 }):sample({})
    assert(capped.data.truncated and capped.data.scanned == 1
        and #capped.data.entries == 1)
    local invalid = Esrt.new({ platform = "linux", fs = Fixture.new({ files = files,
        dirs = { [base .. "/entries"] = { "entry0", "entry01", "../escape" } } }) })
        :sample({})
    assert(invalid.quality == "partial" and invalid.data.scanned == 1
        and #invalid.data.entries == 1,
        "noncanonical entry names cannot reach a file read or graph identity")
    assert(Esrt.new({ platform = "windows", fs = fs }):sample({}).status == "unavailable")
    assert(Esrt.new({ platform = "linux", fs = Fixture.new({
        dirs = { [base .. "/entries"] = {} } }) }):sample({}).reason == "no_esrt_entries")
    assert(Esrt.new({ platform = "linux", fs = Fixture.new({
        denied = { [base .. "/entries"] = true } }) }):probe({}).state == "denied")
end

-- Windows has no PCI domain in SetupAPI addresses. Explicit bus metadata
-- connects USB root hubs to those addresses (and instance-ID fallbacks).
do
    local Hardware = require("wtop.model.hardware")
    local TUI = require("wtop.tui")
    local i18n = assert(require("wtop.i18n").new({ locale = "en-US" }))
    local bridge = { address = "00:01.0", vendor_id = 0x1234, device_id = 0,
        revision = 0, class_id = 0x060400, driver = "pci", device_name = "Bridge" }
    local controller = { address = "01:00.0", parent_address = bridge.address,
        parent_bus = "pci", device_name = "USB controller" }
    local root = { id = "USB\\ROOT_HUB30\\fixture", parent_id = controller.address,
        parent_bus = "pci", product = "Root hub" }
    local leaf = { id = "USB\\fixture", parent_id = root.id, parent_bus = "usb",
        vendor_id = 0x1234, product_id = 0, product = "Device" }
    local state = { inventory = { pci = { devices = { bridge, controller } },
        usb = { devices = { root, leaf } } } }
    local graph = Hardware.build(state)
    assert(not graph.partial and #graph.nodes == 4
        and graph.by_id["pci:" .. controller.address].parent_id == "pci:" .. bridge.address
        and graph.by_id["usb:" .. root.id].parent_id == "pci:" .. controller.address
        and graph.by_id["usb:" .. leaf.id].depth == 3)
    local detail = table.concat(TUI.hardware_detail_lines(state, "usb:" .. root.id, i18n), "\n")
    assert(detail:find("01:00.0", 1, true) and detail:find("p parent", 1, true),
        "Windows controller ancestry is available in the hardware inspector")
    detail = table.concat(TUI.hardware_detail_lines(state, "pci:" .. bridge.address, i18n), "\n")
    assert(detail:find("ID: 1234:0000", 1, true) and detail:find("Class: 060400", 1, true)
        and detail:find("Revision: 00", 1, true) and detail:find("Driver: pci", 1, true))
    local chinese = assert(require("wtop.i18n").new({ locale = "zh-CN" }))
    assert(table.concat(TUI.hardware_detail_lines(state, "pci:" .. bridge.address, chinese), "\n")
        :find("修订号: 00", 1, true), "PCI revision has a localized inspector label")
    local exported = Export.snapshot(state)
    assert(exported.inventory.pci.devices[1].device_id == 0
        and exported.inventory.pci.devices[1].class_id == 0x060400
        and exported.inventory.pci.devices[1].revision == 0
        and exported.inventory.pci.devices[1].driver == "pci"
        and exported.inventory.usb.devices[1].vendor_id == nil
        and exported.inventory.usb.devices[1].parent_bus == "pci"
        and exported.inventory.usb.devices[2].product_id == 0
        and by_id(exported.inventory.topology.nodes, "usb:" .. root.id).parent_id
            == "pci:" .. controller.address,
        "raw inventory and exported topology agree without inventing root-hub IDs")
    controller.address, root.parent_id = "PCI\\CONTROLLER", "PCI\\CONTROLLER"
    graph = Hardware.build(state)
    assert(graph.by_id["usb:" .. root.id].parent_id == "pci:PCI\\CONTROLLER")
    root.parent_bus = "invalid"
    graph = Hardware.build(state)
    assert(graph.partial and graph.by_id["usb:" .. root.id].parent_id == nil)
    root.parent_bus = "pci"
    root.parent_id = "PCI\\removed"
    graph = Hardware.build(state)
    assert(graph.by_id["usb:" .. root.id].depth == 0
        and graph.by_id["pci:PCI\\removed"] == nil,
        "an absent parent is not synthesized from the child's reference")
    root.parent_id = controller.address
    state.inventory.pci.devices[3] = { address = controller.address }
    graph = Hardware.build(state)
    assert(graph.partial and graph.by_id["usb:" .. root.id].parent_id == nil,
        "duplicate addresses cannot choose an arbitrary controller")
    state.inventory.pci.devices[3] = nil
    state.inventory.quality = "partial"
    assert(Hardware.build(state).partial,
        "partial native enumeration remains visible in the topology summary")
end

-- Windows disk references name the exact PnP instance, so the current bus
-- node can supply its public address without guessing a PCI domain.
do
    local Hardware = require("wtop.model.hardware")
    local TUI = require("wtop.tui")
    local JSON = require("wtop.format.json")
    local i18n = assert(require("wtop.i18n").new({ locale = "en-US" }))
    local controller = { address = "00:14.0", device_name = "Controller",
        _pnp_instance_id = "PCI\\PRIVATE-CONTROLLER" }
    local usb = { id = "usb-device", product = "USB drive",
        _pnp_instance_id = "USB\\PRIVATE-INSTANCE" }
    local sata_disk = { id = "PhysicalDrive0", name = "Disk 0", stable_id = "disk-epoch-1",
        _pnp_instance_id = "SCSI\\PRIVATE-DISK", _pnp_parent_id = "pci\\private-controller",
        _pnp_parent_bus = "pci", identity = { model = "SATA disk" } }
    local usb_disk = { id = "PhysicalDrive257", name = "Disk 257", stable_id = "disk-epoch-2",
        _pnp_parent_id = "USB\\PRIVATE-INSTANCE", _pnp_parent_bus = "usb" }
    local state = { inventory = { pci = { devices = { controller } }, usb = { devices = { usb } } },
        disks = { total = 2, devices = { sata_disk, usb_disk } } }
    local graph = Hardware.build(state)
    assert(graph.by_id["block:disk-epoch-1"].parent_id == "pci:00:14.0"
        and graph.by_id["block:disk-epoch-2"].parent_id == "usb:usb-device")
    local detail = table.concat(TUI.hardware_detail_lines(state, "block:disk-epoch-1", i18n), "\n")
    assert(detail:find("Parent device: 00:14.0", 1, true) and detail:find("p parent", 1, true))
    local exported = Export.snapshot(state)
    assert(exported.disks.total == 2 and exported.disks.devices[1].stable_id == "disk-epoch-1"
        and by_id(exported.inventory.topology.nodes, "block:disk-epoch-1").parent_id == "pci:00:14.0")
    assert(not JSON.encode(exported):find("PRIVATE", 1, true),
        "private PnP identities are consumed by the graph and not exported")
    state.quality = { inventory = { status = "ok", quality = "stale" } }
    assert(Hardware.build(state).by_id["block:disk-epoch-1"].parent_id == nil,
        "a stale controller snapshot cannot establish a current disk parent")
    state.quality = { disks = { status = "error", quality = "stale" } }
    assert(Hardware.build(state).by_id["block:disk-epoch-1"].parent_id == nil)
    state.quality = nil
    state.inventory.pci.devices[2] = { address = "01:00.0",
        _pnp_instance_id = controller._pnp_instance_id }
    assert(Hardware.build(state).by_id["block:disk-epoch-1"].parent_id == nil,
        "a duplicate instance cannot pick an arbitrary controller")
    state.inventory.pci.devices[2] = nil
    sata_disk._pnp_parent_id = "PCI\\replaced-controller"
    assert(Hardware.build(state).by_id["block:disk-epoch-1"].parent_id == nil)
    sata_disk._pnp_parent_id = controller._pnp_instance_id
    sata_disk._pnp_parent_bus = "usb"
    assert(Hardware.build(state).by_id["block:disk-epoch-1"].parent_id == nil,
        "the native bus assertion must agree with the matched device")
    state.disks.truncated = true
    assert(Export.snapshot(state).disks.truncated)
end

do
    local Hardware = require("wtop.model.hardware")
    local JSON = require("wtop.format.json")
    local adapter = { address = "02:00.0", _pnp_instance_id = "PCI\\PRIVATE-NIC" }
    local interface = { id = 17, name = "Ethernet", driver = "rtl8168",
        description = "Ethernet controller", hardware = true,
        _interface_guid = "PRIVATE-GUID", _pnp_instance_id = "PCI\\PRIVATE-NIC",
        _pnp_parent_id = "PCI\\PRIVATE-NIC", _pnp_parent_bus = "pci" }
    local state = { inventory = { pci = { devices = { adapter } } },
        network = { interfaces = { interface } } }
    assert(Hardware.build(state).by_id["net:17"].parent_id == "pci:02:00.0")
    local data = Export.snapshot(state)
    assert(data.network.interfaces[1].driver == "rtl8168"
        and data.network.interfaces[1].description == "Ethernet controller"
        and data.network.interfaces[1].hardware)
    assert(not JSON.encode(data):find("PRIVATE", 1, true))
    state.quality = { network = { status = "ok", quality = "stale" } }
    assert(Hardware.build(state).by_id["net:17"].parent_id == nil)
    state.quality = nil
    state.inventory.pci.devices[2] = { address = "03:00.0", _pnp_instance_id = adapter._pnp_instance_id }
    assert(Hardware.build(state).by_id["net:17"].parent_id == nil)
end

return true
