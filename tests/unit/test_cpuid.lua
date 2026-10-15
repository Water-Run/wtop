local CPUID = require("wtop.model.cpuid")
local Hardware = require("wtop.model.hardware")
local Export = require("wtop.export")
local JSON = require("wtop.format.json")
local Portable = require("wtop.collectors.portable")
local Scheduler = require("wtop.core.scheduler")
local TUI = require("wtop.tui")
local i18n = assert(require("wtop.i18n").new({ locale = "en-US" }))
local source = debug.getinfo(1,"S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
local function capture(name, count)
  local file = assert(io.open(root .. "/tests/fixtures/cpuid/" .. name .. ".bin", "rb"))
  local raw = file:read("a"); file:close()
  local targets = {}
  for id = 0, count - 1 do targets[#targets + 1] = { id=id, processor_group=0, logical_processor_index=id } end
  return raw, targets
end
local function feature(cpu, name)
  for _, row in ipairs(cpu.features) do if row.name == name then return row end end
end
local function u32(raw, offset, value)
  return raw:sub(1,offset-1) .. string.pack("<I4", value) .. raw:sub(offset+4)
end
local function seal(raw)
  local hash = 2166136261
  for index = 33, #raw do hash = ((hash ~ raw:byte(index)) * 16777619) & 0xffffffff end
  return u32(raw,25,hash)
end
local function leaf_offset(raw, cpu_id, leaf, subleaf)
  local n, offset = string.unpack("<I4",raw,13), 33
  for _ = 1, n do
    local id = string.unpack("<I4",raw,offset)
    local count = string.unpack("<I4",raw,offset+16)
    local first = offset + 48
    if id == cpu_id then
      for index = 0, count - 1 do
        local p = first + index*24
        local number, sub = string.unpack("<I4I4",raw,p)
        if number == leaf and sub == (subleaf or 0) then return p, offset end
      end
    end
    offset = first + count*24
  end
  error("fixture leaf missing")
end
local modern, targets = capture("intel-06-97", 8)
local intel = assert(CPUID.decode(modern, targets))
assert(intel.architecture_bits == 64 and intel.topology.complete and intel.caches_complete)
assert(intel.topology.sockets == 1 and intel.topology.physical_cores == 4 and #intel.caches == 13)
assert(intel.logical_cpus[1].topology.method == "CPUID.1F")
assert(intel.logical_cpus[1].identity.family == 6 and intel.logical_cpus[1].identity.model == 0x97)
assert(feature(intel.logical_cpus[1],"AVX").usable)
assert(intel.caches[#intel.caches].maximum_sharing == 16, "addressable sharing is not observed population")
local altered = modern
for id=0,7 do
  local offset = leaf_offset(altered,id,0x1f,1)
  altered = u32(altered,offset+12,64)
end
assert(assert(CPUID.decode(seal(altered),targets)).topology.physical_cores == 4,
  "Intel EBX topology counts are diagnostic, not population counts")
local legacy, old_targets = capture("amd15h",6)
local amd = assert(CPUID.decode(legacy,old_targets))
assert(amd.topology.complete and amd.topology.compute_units == 3 and amd.topology.physical_cores == 6)
assert(amd.topology.threads_per_core_maximum == 1 and amd.caches_complete and #amd.caches == 13)
local initial = {0,1,4,5,3,2}
for index,cpu in ipairs(amd.logical_cpus) do
  assert(cpu.identity.initial_apic_id == initial[index] and cpu.topology.apic_id == index-1)
  assert(feature(cpu,"AVX").hardware and feature(cpu,"AVX").usable == false)
  assert(cpu.xcr0 == nil and #cpu.topology.thread_siblings == 1)
end
assert(amd.cache_summary[3].total_size_bytes == 6291456 and amd.cache_summary[4].total_size_bytes == 8388608)

-- AVX512 needs both the foundation bit and OS-enabled opmask/ZMM state.
local p, cpu_offset = leaf_offset(modern,0,7)
altered = u32(modern,p+12,string.unpack("<I4",modern,p+12) | (1<<16))
assert(feature(assert(CPUID.decode(seal(altered),targets)).logical_cpus[1],"AVX512F").usable == false)
altered = u32(altered,cpu_offset+32,0xe7)
assert(feature(assert(CPUID.decode(seal(altered),targets)).logical_cpus[1],"AVX512F").usable)
altered = u32(altered,p+20,string.unpack("<I4",altered,p+20) | (1<<24))
assert(feature(assert(CPUID.decode(seal(altered),targets)).logical_cpus[1],"AMX-TILE").usable == nil)

-- Differing ways in overlapping AMD L3 views may describe partitioning.
-- They cannot be counted as additional physical caches or replace OS totals.
p = leaf_offset(legacy,1,0x8000001d,3)
altered = seal(u32(legacy,p+12,string.unpack("<I4",legacy,p+12) ~ (1<<22)))
local partitioned = assert(CPUID.decode(altered,old_targets))
assert(not partitioned.caches_complete and #partitioned.cache_summary == 0 and #partitioned.caches == 13)
assert(partitioned.quality == "partial" and #partitioned.issues > 0)
local os_cache = { {id="os-only", shared_cpu_list={0}} }
local data = { topology={logical_cpus=old_targets}, caches=os_cache }
CPUID.enrich(data,{status="ok",raw=altered})
assert(data.caches == os_cache and not data.os_caches)
data = { topology={threads=128,truncated=true,logical_cpus=targets}, caches=os_cache }
CPUID.enrich(data,{status="ok",raw=modern})
assert(data.caches==os_cache and data.topology.threads==128 and data.cpuid.roster_complete==false)
-- Missing dependencies cannot turn AVX2 into a usable feature, even if the
-- OS has enabled its vector state. Both facts remain independently visible.
p = leaf_offset(modern,0,1)
altered = seal(u32(modern,p+16,string.unpack("<I4",modern,p+16) & ~(1<<28)))
local unavailable = feature(assert(CPUID.decode(altered,targets)).logical_cpus[1],"AVX2")
assert(unavailable.hardware and unavailable.os_enabled and unavailable.usable==false)

-- Missing topology and unknown future domains keep the independent OS view.
altered = modern
for _, number in ipairs({0x1f,0xb}) do
  p = leaf_offset(altered,0,number,0)
  altered = u32(altered,p+16,0xff00)
end
assert(not assert(CPUID.decode(seal(altered),targets)).topology.complete)
altered = modern
for id=0,1 do
  p=leaf_offset(altered,id,4,2)
  altered=u32(altered,p+8,(string.unpack("<I4",altered,p+8) & ~(4095<<14)) | (3<<14))
end
assert(not assert(CPUID.decode(seal(altered),targets)).caches_complete,
  "overlapping cache address ranges cannot form disjoint capacity totals")
p=leaf_offset(modern,1,0x1f,0)
assert(not assert(CPUID.decode(seal(u32(modern,p+8,0)),targets)).topology.complete,
  "contradictory SMT group boundaries must not invent cores")
assert(not CPUID.decode(modern:sub(1,-2),targets))
assert(not CPUID.decode(u32(modern,25,0),targets))
assert(not CPUID.decode(modern.."trailing",targets))
local swapped = {table.unpack(targets)};swapped[1],swapped[2]=swapped[2],swapped[1]
assert(not CPUID.decode(modern,swapped))
assert(not CPUID.decode(seal(u32(modern,33+16,97)),targets))
-- A duplicate leaf is rejected even when a packet's checksum is valid.
p = leaf_offset(modern,0,1)
assert(not CPUID.decode(seal(u32(modern,p,0)),targets))

data = { identity={model_name="AMD fixture"}, topology={threads=6,logical_cpus=old_targets},
  caches=os_cache, cache_summary={} }
CPUID.enrich(data,{status="ok",raw=legacy,source="native-x64 CPUID worker"})
assert(data.os_caches == os_cache and #data.caches == 13 and data.topology.compute_units == 3)
local graph = Hardware.build({cpu_info=data})
local row = data.topology.logical_cpus[1]
local unit_id = "compute-unit:" .. row.compute_unit_key
assert(graph.by_id["core:"..row.core_key].parent_id == unit_id)
assert(graph.by_id[unit_id].parent_id == "package:0" and #graph.by_id[unit_id].cpu_ids == 2)
for _,cache in ipairs(data.caches) do
  if cache.level == 2 then assert(graph.by_id["cpu-cache:"..cache.id].parent_id:find("compute-unit:",1,true)) end
end
local exported = Export.snapshot({cpu_info=data})
assert(exported.cpu_info.os_caches[1].id == "os-only" and #exported.cpu_info.caches == 13)
assert(exported.cpu_info.cpuid.logical_cpus[1].features[10].usable == false)
assert(exported.cpu_info.cpuid.logical_cpus[1].leaves[1].leaf == "0x00000000")
local json = JSON.encode(exported)
assert(not json:find('"raw"',1,true) and not json:find('"_leaves"',1,true))
local detail = table.concat(TUI.hardware_detail_lines({cpu_info=data},"cpu:0",i18n),"\n")
assert(detail:find("AVX: Hardware yes · Usable no",1,true),detail)
assert(detail:find("Initial APIC ID: 0x0",1,true))

-- Async supplemental work requests a short follow-up without turning valid
-- OS CPU info into a failure, backing off, or disturbing other collectors.
local calls, now = 0, 0
local collector = Portable.new_all({cpu_info={native={
  collect_cpu_info=function() return {topology={threads=8,logical_cpus=targets}} end,
  collect_cpuid=function()
    calls=calls+1
    return calls==1 and {status="pending",reason="cpuid_probe_pending"} or {status="ok",raw=modern}
  end,
}}}).cpu_info
local scheduler=Scheduler.new({clock=function() return now end})
assert(scheduler:add(collector,{interval_ms=30000}))
local result=scheduler:tick().cpu_info
assert(result.status=="ok" and result.retry_after_ms==250 and scheduler.tasks.cpu_info.failures==0)
now=249000000;assert(next(scheduler:tick())==nil)
now=250000000;result=scheduler:tick().cpu_info
assert(result.status=="ok" and result.data.cpuid.topology.physical_cores==4)
assert(scheduler:next_delay_ms()==30000)
local failed = {topology={logical_cpus=targets}}
assert(CPUID.enrich(failed,{status="error",reason="cpuid_helper_failed",error_code=5})==5000)
assert(Export.snapshot({cpu_info=failed}).cpu_info.cpuid.error_code==5)
print("ok: real Intel/AMD CPUID, CMT, AVX OS state, diagnostic counts, overlapping caches, packet validation, graph and async enrichment")
