local Hardware = require("wtop.model.hardware")
local Export = require("wtop.export")
local JSON = require("wtop.format.json")
local TUI = require("wtop.tui")
local ViewModel = require("wtop.view_model")
local i18n = assert(require("wtop.i18n").new({ locale = "en-US" }))

local function cpu(group, index)
    return { id = group * 64 + index, processor_group = group,
        logical_processor_index = index, cpu_set_id = group * 64 + index + 256,
        source = "GetSystemCpuSetInformation", core_source = "GetSystemCpuSetInformation",
        core_id = 16, core_key = "win:g" .. group .. ":c16", core_id_known = true,
        core_id_scope = "processor_group", core_id_method = "cpu_set_core_index",
        package_id_known = false, online = true, online_known = true,
        efficiency_class = 128, core_type_id = "efficiency-128", parked = true,
        thread_siblings = { group * 64 + 32, group * 64 + 33 },
        identity_quality = "fresh", _private_instance = "omit" }
end
local state = { cpu_info = {
    identity = { model_name = "Example CPU", heterogeneous = true,
        nominal_frequency_hz = 3000000000 },
    topology = { threads = 4, online_threads = 4, physical_cores = 2,
        processor_groups = 2, source = "GetSystemCpuSetInformation", quality = "partial",
        identity_quality = "fresh", logical_cpus = {
            cpu(0, 32), cpu(0, 33), cpu(1, 32), cpu(1, 33),
        } },
    core_types = { { id = "efficiency-128", efficiency_class = 128,
        logical_cpu_count = 4, physical_core_count = 2, logical_cpu_ids = { 32, 33, 96, 97 } } },
    caches = { { id = "win:L3:fixture", level = 3, type = "Unified", size_bytes = 8388608,
        coherency_line_size_bytes = 64, ways_of_associativity = 16,
        shared_cpu_list = { 32, 33, 96, 97 }, source = "GetLogicalProcessorInformationEx" } },
} }
local graph = Hardware.build(state)
assert(graph.by_id["cpu:32"].parent_id == "core:win:g0:c16")
assert(graph.by_id["cpu:96"].parent_id == "core:win:g1:c16")
assert(graph.by_id["core:win:g0:c16"].parent_id == nil and not graph.by_id["package:0"])
assert(#graph.by_id["core:win:g0:c16"].cpu_ids == 2)
assert(graph.by_id["cpu-cache:win:L3:fixture"].parent_id == nil)
assert(#graph.by_id["cpu-cache:win:L3:fixture"].cpu_ids == 4)
assert(graph.by_id["cpu:32"].cache_ids[1] == "cpu-cache:win:L3:fixture")
local exported = Export.snapshot(state)
assert(exported.cpu_info.identity.nominal_frequency_hz == 3000000000)
assert(exported.cpu_info.topology.processor_groups == 2)
local row = exported.cpu_info.topology.logical_cpus[3]
assert(row.id == 96 and row.processor_group == 1 and row.logical_processor_index == 32)
assert(row.core_id_scope == "processor_group" and row.core_id_method == "cpu_set_core_index")
assert(row.parked and row.online and row.cpu_set_id == 352 and row.efficiency_class == 128)
assert(exported.cpu_info.core_types[1].efficiency_class == 128)
assert(exported.cpu_info.caches[1].shared_cpu_list[4] == 97)
assert(not JSON.encode(exported):find("_private", 1, true))
local detail = table.concat(TUI.hardware_detail_lines(state, "cpu:96", i18n), "\n")
assert(detail:find("Processor group: 1", 1, true) and detail:find("Group CPU index: 32", 1, true))
assert(detail:find("Efficiency class: 128", 1, true) and detail:find("Parked: yes", 1, true))
assert(detail:find("Online: yes", 1, true), "parked is a power state, not an offline CPU")
local core_detail = table.concat(TUI.hardware_detail_lines(state, "core:win:g1:c16", i18n), "\n")
assert(core_detail:find("GetSystemCpuSetInformation", 1, true))

-- A package-relative core ID cannot become a root just because its package is
-- unknown. Independent scope is an explicit promise from the native provider.
for _, row in ipairs(state.cpu_info.topology.logical_cpus) do row.core_id_scope = nil end
assert(Hardware.build(state).by_id["cpu:96"].parent_id == nil)
for _, row in ipairs(state.cpu_info.topology.logical_cpus) do row.core_id_scope = "processor_group" end
state.cpu_info.topology.logical_cpus[3].processor_group = nil
assert(Hardware.build(state).by_id["cpu:96"].parent_id == nil)
state.cpu_info.topology.logical_cpus[3].processor_group = 1
for _, row in ipairs(state.cpu_info.topology.logical_cpus) do
    row.package_id, row.package_id_known = 0, true
    row.package_source = "GetLogicalProcessorInformationEx"
    row.package_id_method = "lowest_logical_cpu"
end
local with_package = Hardware.build(state)
assert(with_package.by_id["core:win:g1:c16"].parent_id == "package:0")
assert(with_package.by_id["package:0"].device.source == "GetLogicalProcessorInformationEx")
assert(with_package.by_id["core:win:g1:c16"].device.source == "GetSystemCpuSetInformation")
assert(with_package.by_id["cpu-cache:win:L3:fixture"].parent_id == "package:0")
local cache_detail = table.concat(TUI.hardware_detail_lines(state, "cpu-cache:win:L3:fixture", i18n), "\n")
assert(cache_detail:find("GetLogicalProcessorInformationEx", 1, true))
assert(cache_detail:find("Cache line (bytes): 64", 1, true)
    and cache_detail:find("Associativity (ways): 16", 1, true))
state.cpu_info.caches[1].shared_cpu_list = { 32, 33 }
assert(Hardware.build(state).by_id["cpu-cache:win:L3:fixture"].parent_id == "core:win:g0:c16")
state.cpu_info.caches[1].shared_cpu_list = { 32, 999 }
local absent = Hardware.build(state)
assert(absent.partial and absent.by_id["cpu-cache:win:L3:fixture"].parent_id == nil)
assert(#absent.by_id["cpu:32"].cache_ids == 0)
state.cpu_info.caches[1].shared_cpu_list = { 32, 32 }
assert(Hardware.build(state).by_id["cpu-cache:win:L3:fixture"].parent_id == nil)
state.cpu_info.caches[1].shared_cpu_list = { 32, 33 }
state.quality = { cpu_info = { status = "ok", quality = "stale" } }
assert(Hardware.build(state).by_id["cpu-cache:win:L3:fixture"].parent_id == nil)
state.quality = nil
state.cpu_info.caches[2] = state.cpu_info.caches[1]
assert(Hardware.build(state).by_id["cpu-cache:win:L3:fixture"].ambiguous)
state.cpu_info.caches[2] = nil
local legacy = Export.snapshot(state).cpu_info.topology.logical_cpus[1]
assert(legacy.package_source == "GetLogicalProcessorInformationEx"
    and legacy.package_id_method == "lowest_logical_cpu")
state.cpu_info.topology.sockets, state.cpu_info.topology.physical_cores = nil, nil
state.cpu_info.core_types[2] = { id = "efficiency-0", efficiency_class = 0 }
local entries = ViewModel.build({ history_values = function() return {} end }, state, i18n, {}, "compute").cpu_identity.entries
local found = {}
for _, entry in ipairs(entries) do
    if entry.label_id == "compute.sockets" or entry.label_id == "compute.cores" then
        assert(entry.value == "—", "unknown physical counts are not measured zero")
    end
    if entry.label == "128 · Efficiency class" then found[128] = entry.value end
    if entry.label == "0 · Efficiency class" then found[0] = entry.value end
end
assert(found[128] == "4T" and found[0] == "—", "reported classes remain distinguishable without inventing counts")
print("ok: Windows CPU group identities, independent cores, canonical packages, cache sharing, parked state and public fields")
