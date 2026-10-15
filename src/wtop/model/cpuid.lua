-- Decode the bounded packet from the isolated Windows CPU reader. CPUID is
-- an independent hardware view: OS records and diagnostic leaf counts are
-- retained, rather than added to observed populations or cache capacities.
local M = {}
local function bit(value, position) return (value & (1 << position)) ~= 0 end
local function hex(value) return string.format("0x%08x", value) end
local function word(value) return string.pack("<I4", value) end
local function text(value)
  return value:gsub("%z", ""):gsub("[%c]", "?"):gsub("^%s+", ""):gsub("%s+$", "")
end
local function width(count)
  local bits = 0
  while (1 << bits) < count do bits = bits + 1 end
  return bits
end
local function issue(result, reason, cpu)
  result.issues[#result.issues + 1] = { reason = reason, cpu_id = cpu }
  result.quality = "partial"
end
local function leaf(cpu, number, sub)
  return cpu._leaves[number] and cpu._leaves[number][sub or 0]
end

local function packet(raw, targets)
  if type(raw) ~= "string" or #raw < 32 or #raw > 2097152 then return nil end
  local magic, version, bytes, count, bits, flags, checksum, reserved, offset =
    string.unpack("<I4I4I4I4I4I4I4I4", raw)
  if magic ~= 0x50435457 or version ~= 1 or bytes ~= #raw or count < 1 or count > 512
      or (bits ~= 32 and bits ~= 64) or flags > 1 or reserved ~= 0
      or type(targets) ~= "table" or #targets ~= count then return nil end
  local hash = 2166136261
  for index = 33, #raw do hash = ((hash ~ raw:byte(index)) * 16777619) & 0xffffffff end
  if hash ~= checksum then return nil end
  local cpus, seen, partial = {}, {}, false
  for index = 1, count do
    if offset + 47 > #raw then return nil end
    local id, group, number, status, n, basic, extended, cpu_flags, low, high, after, apic
    id, group, number, status, n, basic, extended, cpu_flags, low, high, after, apic, offset =
      string.unpack("<I4I4I4I4I4I4I4I4I4I4I4I4", raw, offset)
    local target = targets[index]
    if type(target) ~= "table" or id ~= target.id or group ~= target.processor_group
        or number ~= target.logical_processor_index or group >= 64 or number >= 64
        or id ~= group * 64 + number or seen[id] or status > 6 or n > 96
        or cpu_flags > 255 or offset + n * 24 - 1 > #raw then return nil end
    seen[id] = true
    local cpu = { id = id, processor_group = group, logical_processor_index = number,
      status = status, flags = cpu_flags, max_basic = hex(basic), max_extended = hex(extended),
      xcr0 = bit(cpu_flags, 0) and string.format("0x%08x%08x", high, low) or nil,
      affinity_restored = bit(cpu_flags, 4), os_processor_verified = bit(cpu_flags, 3),
      truncated = bit(cpu_flags, 5), leaves = {}, _leaves = {}, _xcr0 = low }
    if status == 0 and (not bit(cpu_flags, 4) or not bit(cpu_flags, 7)) then return nil end
    partial = partial or status ~= 0 or cpu.truncated
    for _ = 1, n do
      local a, s, eax, ebx, ecx, edx
      a, s, eax, ebx, ecx, edx, offset = string.unpack("<I4I4I4I4I4I4", raw, offset)
      cpu._leaves[a] = cpu._leaves[a] or {}
      if cpu._leaves[a][s] then return nil end
      local row = { leaf = hex(a), subleaf = s, eax = hex(eax), ebx = hex(ebx), ecx = hex(ecx), edx = hex(edx) }
      cpu.leaves[#cpu.leaves + 1] = row
      cpu._leaves[a][s] = { eax = eax, ebx = ebx, ecx = ecx, edx = edx }
    end
    local first = leaf(cpu, 1)
    if status == 0 and (not leaf(cpu, 0) or (first and (first.eax ~= after or (first.ebx >> 24) ~= apic))) then return nil end
    cpus[#cpus + 1] = cpu
  end
  if offset ~= #raw + 1 or (partial and 1 or 0) ~= flags then return nil end
  return { schema = "wtop.cpuid.v1", architecture_bits = bits, logical_cpus = cpus,
    quality = partial and "partial" or "fresh", status = "ok", issues = {} }
end

local function identity(cpu)
  local zero, one = leaf(cpu, 0), leaf(cpu, 1)
  if not zero then return {} end
  local result = { vendor = text(word(zero.ebx) .. word(zero.edx) .. word(zero.ecx)), source = "CPUID" }
  if one then
    local base_family, base_model = (one.eax >> 8) & 15, (one.eax >> 4) & 15
    result.family = base_family + (base_family == 15 and ((one.eax >> 20) & 255) or 0)
    result.model = base_model + ((base_family == 6 or base_family == 15) and (((one.eax >> 16) & 15) << 4) or 0)
    result.stepping, result.signature = one.eax & 15, hex(one.eax)
    result.initial_apic_id = one.ebx >> 24
    result.hypervisor_present = bit(one.ecx, 31)
  end
  local brand = {}
  for number = 0x80000002, 0x80000004 do
    local value = leaf(cpu, number)
    if not value then brand = {}; break end
    brand[#brand + 1] = word(value.eax) .. word(value.ebx) .. word(value.ecx) .. word(value.edx)
  end
  if #brand > 0 then result.model_name = text(table.concat(brand)) end
  local address = leaf(cpu, 0x80000008)
  if address then
    local physical, linear = address.eax & 255, (address.eax >> 8) & 255
    if physical > 0 and physical <= 64 then result.physical_address_bits = physical end
    if linear > 0 and linear <= 64 then result.linear_address_bits = linear end
  end
  local hypervisor = leaf(cpu, 0x40000000)
  if result.hypervisor_present and hypervisor then
    result.hypervisor_vendor = text(word(hypervisor.ebx) .. word(hypervisor.ecx) .. word(hypervisor.edx))
  end
  return result
end

-- os_enabled is only filled when this worker can establish the required
-- state. Hardware AMX, NX or 64-bit support alone does not prove OS usability.
local features = {
  {"MMX",1,"edx",23}, {"SSE",1,"edx",25,"xmm"}, {"SSE2",1,"edx",26,"sse2"},
  {"SSE3",1,"ecx",0,"xmm"}, {"SSSE3",1,"ecx",9,"xmm"},
  {"SSE4.1",1,"ecx",19,"xmm"}, {"SSE4.2",1,"ecx",20,"xmm"},
  {"AES",1,"ecx",25,"xmm"}, {"XSAVE",1,"ecx",26},
  {"AVX",1,"ecx",28,"avx"}, {"FMA",1,"ecx",12,"avx"},
  {"AVX2",7,"ebx",5,"avx"}, {"BMI1",7,"ebx",3,"scalar"},
  {"BMI2",7,"ebx",8,"scalar"}, {"ADX",7,"ebx",19,"scalar"},
  {"SHA",7,"ebx",29,"xmm"}, {"AVX512F",7,"ebx",16,"avx512"},
  {"AVX512BW",7,"ebx",30,"avx512"}, {"AVX512VL",7,"ebx",31,"avx512"},
  {"AMX-TILE",7,"edx",24}, {"NX",0x80000001,"edx",20},
  {"RDTSCP",0x80000001,"edx",27,"scalar"}, {"Long mode",0x80000001,"edx",29},
  {"Invariant TSC",0x80000007,"edx",8},
}
local function decode_features(cpu)
  local result, first, seven = {}, leaf(cpu, 1), leaf(cpu, 7)
  local avx = first and bit(first.ecx, 26) and bit(first.ecx, 27)
    and bit(cpu.flags, 0) and (cpu._xcr0 & 6) == 6 or false
  local avx512 = avx and (cpu._xcr0 & 0xe6) == 0xe6
  local avx_hardware = first and bit(first.ecx, 28) or false
  local avx512_hardware = seven and bit(seven.ebx, 16) or false
  for _, definition in ipairs(features) do
    local name, number, register, position, state = table.unpack(definition)
    local value = leaf(cpu, number)
    if value then
      local supported = bit(value[register], position)
      local row = { name = name, hardware = supported, leaf = hex(number), subleaf = 0,
        register = register, bit = position }
      if state then
        row.os_enabled = state == "scalar" or state == "xmm" and bit(cpu.flags, 1)
          or state == "sse2" and bit(cpu.flags, 2) or state == "avx" and avx
          or state == "avx512" and avx512 or false
        row.usable = supported and row.os_enabled
        if state == "avx" then row.usable = row.usable and avx_hardware end
        if state == "avx512" then row.usable = row.usable and avx_hardware and avx512_hardware end
      elseif not supported then row.usable = false end
      result[#result + 1] = row
    end
  end
  return result
end

local function intel_topology(cpu)
  local function levels(number)
    local values, apic, shift, smt, previous = {}, nil, nil, nil, -1
    local terminated, kinds = false, {}
    for sub = 0, 15 do
      local value = leaf(cpu, number, sub)
      if not value then return nil end
      local kind, count, bits = (value.ecx >> 8) & 255, value.ebx & 65535, value.eax & 31
      if kind == 0 or count == 0 then terminated = true; break end
      if kind > (number == 0xb and 2 or 6) or kinds[kind] or (sub == 0 and kind ~= 1)
          or bits < previous or (apic and apic ~= value.edx) or (value.ecx & 255) ~= sub then return nil end
      kinds[kind] = true
      if kind == 1 then if smt then return nil end; smt = bits end
      values[#values + 1] = { level = sub, type = kind, shift = bits, diagnostic_logical_count = count }
      apic, shift, previous = value.edx, bits, bits
    end
    if not terminated or not kinds[2] or #values < 2 or not smt or not shift or shift < smt then return nil end
    return { method = number == 0x1f and "CPUID.1F" or "CPUID.0B", apic_id = apic,
      package_id = apic >> shift, core_id = (apic & ((1 << shift) - 1)) >> smt,
      core_key = "cpuid:intel:" .. tostring(apic >> smt), levels = values }
  end
  return levels(0x1f) or levels(0xb)
end

local function amd15_topology(cpu, id)
  -- 42301 BKDG: Models 00h..0Fh report integer cores per compute unit here,
  -- not SMT threads. ExtendedApicId reads the current, writable APIC register;
  -- initial APIC IDs and the explicit compute-unit/node IDs remain separate.
  if id.family ~= 0x15 or not id.model or id.model > 0xf then return nil end
  local value, address, extended = leaf(cpu, 0x8000001e), leaf(cpu, 0x80000008), leaf(cpu, 0x80000001)
  if not value or not address or not extended or not bit(extended.ecx, 22) then return nil end
  local core_bits, count = (address.ecx >> 12) & 15, (address.ecx & 255) + 1
  if core_bits == 0 then core_bits = width(count) end
  local per_unit, unit, node = ((value.ebx >> 8) & 255) + 1, value.ebx & 255, value.ecx & 255
  if not id.initial_apic_id or core_bits > 8 or per_unit > 2 or ((value.ecx >> 8) & 7) > 1 then return nil end
  local package = id.initial_apic_id >> core_bits
  return { method = "CPUID.8000001E AMD15h", apic_id = value.eax,
    package_id = package, core_id = id.initial_apic_id & ((1 << core_bits) - 1),
    core_key = "cpuid:amd15:" .. id.initial_apic_id, node_id = node,
    compute_unit_id = unit, cores_per_compute_unit = per_unit,
    compute_unit_key = "cpuid:amd15:p" .. package .. ":n" .. node .. ":cu" .. unit }
end

local function topology(result)
  local packages, cores, units, ids = {}, {}, {}, {}
  local complete, vendor = true, nil
  for _, cpu in ipairs(result.logical_cpus) do
    local id = cpu.identity
    if vendor and vendor ~= id.vendor then complete = false end
    vendor = id.vendor
    local decoded = cpu.status == 0 and (id.vendor == "GenuineIntel" and intel_topology(cpu)
      or id.vendor == "AuthenticAMD" and amd15_topology(cpu, id)) or nil
    if decoded and id.vendor == "GenuineIntel" and id.initial_apic_id ~= (decoded.apic_id & 255) then
      decoded = nil; issue(result, "cpuid_apic_views_disagree", cpu.id)
    end
    cpu.topology = decoded
    if not decoded then complete = false
    elseif ids[decoded.apic_id] then complete = false; issue(result, "cpuid_duplicate_apic_id", cpu.id)
    else
      ids[decoded.apic_id] = true
      packages[decoded.package_id] = true
      cores[decoded.core_key] = (cores[decoded.core_key] or 0) + 1
      if decoded.compute_unit_key then units[decoded.compute_unit_key] = true end
    end
  end
  for _, cpu in ipairs(result.logical_cpus) do
    local value = cpu.topology
    if value and value.levels then
      local smt, package
      for _, level in ipairs(value.levels) do
        if level.type == 1 then smt = level.shift end
        package = level.shift
      end
      for _, other in ipairs(result.logical_cpus) do
        local sibling = other.topology
        if sibling and ((sibling.apic_id >> smt == value.apic_id >> smt and sibling.core_key ~= value.core_key)
            or (sibling.apic_id >> package == value.package_id and sibling.package_id ~= value.package_id)) then
          complete = false; issue(result, "cpuid_topology_views_disagree", cpu.id); break
        end
      end
    end
  end
  local initial, unit_counts = {}, {}
  for _, cpu in ipairs(result.logical_cpus) do
    local value = cpu.topology
    if value and value.compute_unit_key then
      local key = tostring(value.package_id) .. ":" .. tostring(cpu.identity.initial_apic_id)
      if initial[key] then complete = false end
      initial[key] = true
      unit_counts[value.compute_unit_key] = (unit_counts[value.compute_unit_key] or 0) + 1
      if unit_counts[value.compute_unit_key] > value.cores_per_compute_unit then complete = false end
    end
  end
  local function count(values) local n = 0; for _ in pairs(values) do n = n + 1 end; return n end
  result.topology = { complete = complete, observed_logical_cpus = #result.logical_cpus }
  if complete then
    local output = result.topology
    output.sockets, output.physical_cores = count(packages), count(cores)
    if next(units) then output.compute_units = count(units) end
    output.threads_per_core_minimum, output.threads_per_core_maximum = 512, 0
    for _, n in pairs(cores) do
      output.threads_per_core_minimum = math.min(output.threads_per_core_minimum, n)
      output.threads_per_core_maximum = math.max(output.threads_per_core_maximum, n)
    end
    for _, cpu in ipairs(result.logical_cpus) do
      local value = cpu.topology
      value.thread_siblings = {}
      for _, sibling in ipairs(result.logical_cpus) do
        if value.core_key == sibling.topology.core_key then value.thread_siblings[#value.thread_siblings + 1] = sibling.id end
      end
    end
  end
end

local function caches(result)
  local groups, complete = {}, result.topology.complete
  for _, cpu in ipairs(result.logical_cpus) do
    cpu.cache_views = {}
    local number = cpu.identity.vendor == "GenuineIntel" and 4
      or cpu.identity.vendor == "AuthenticAMD" and 0x8000001d or nil
    local terminated = false
    for sub = 0, 31 do
      local value = number and leaf(cpu, number, sub)
      if not value then break end
      local kind, level = value.eax & 31, (value.eax >> 5) & 7
      if kind == 0 then terminated = true; break end
      local line, partitions, ways, sets = (value.ebx & 4095) + 1,
        ((value.ebx >> 12) & 1023) + 1, ((value.ebx >> 22) & 1023) + 1, value.ecx + 1
      local size = line * 1.0 * partitions * ways * sets
      if kind > 3 or level == 0 or size <= 0 or size > 1099511627776 then
        complete = false; issue(result, "cpuid_invalid_cache_geometry", cpu.id); break
      end
      local sharing = ((value.eax >> 14) & 4095) + 1
      local row = { level = level, type = ({"Data", "Instruction", "Unified"})[kind],
        size_bytes = size, coherency_line_size_bytes = line, physical_line_partition = partitions,
        ways_of_associativity = ways, number_of_sets = sets, maximum_sharing = sharing,
        leaf = hex(number), subleaf = sub, source = "CPUID" }
      cpu.cache_views[#cpu.cache_views + 1] = row
      local top, key = cpu.topology
      if top and number == 4 then
        key = "intel:a" .. tostring(top.apic_id >> width(sharing))
      elseif top and number == 0x8000001d then
        if sharing == 1 then key = top.core_key
        elseif level <= 2 and sharing == top.cores_per_compute_unit then key = top.compute_unit_key
        elseif level == 3 then key = "amd15:p" .. top.package_id .. ":n" .. top.node_id end
      end
      if key then
        key = "cpuid:L" .. level .. ":" .. row.type .. ":" .. key
        local group = groups[key]
        if not group then
          group = {}; for field, v in pairs(row) do group[field] = v end
          group.id, group.shared_cpu_list, group._seen = key, {}, {}; groups[key] = group
          if number == 4 then group._shift, group._prefix = width(sharing), top.apic_id >> width(sharing) end
        elseif group.size_bytes ~= size or group.coherency_line_size_bytes ~= line
            or group.physical_line_partition ~= partitions or group.ways_of_associativity ~= ways
            or group.number_of_sets ~= sets or group.maximum_sharing ~= sharing then
          -- Overlapping cache views with different available ways can describe
          -- partitioning. They cannot be summed as disjoint physical caches.
          group.ambiguous = true; complete = false
        end
        if group._seen[cpu.id] then group.ambiguous = true; complete = false end
        group._seen[cpu.id] = true
        group.shared_cpu_list[#group.shared_cpu_list + 1] = cpu.id
      else complete = false end
    end
    if not terminated or cpu.status ~= 0 or cpu.truncated then complete = false end
  end
  result.caches, result.cache_summary = {}, {}
  local summaries = {}
  for _, group in pairs(groups) do
    group._seen = nil
    table.sort(group.shared_cpu_list)
    if group._shift then
      local observed = {}
      for _, id in ipairs(group.shared_cpu_list) do observed[id] = true end
      for _, cpu in ipairs(result.logical_cpus) do
        if cpu.topology and cpu.topology.apic_id >> group._shift == group._prefix and not observed[cpu.id] then
          group.ambiguous = true; complete = false
        end
      end
      group._shift, group._prefix = nil, nil
    end
    if #group.shared_cpu_list > group.maximum_sharing then group.ambiguous = true; complete = false end
    if group.ambiguous then issue(result, "cpuid_cache_views_disagree") end
    result.caches[#result.caches + 1] = group
  end
  table.sort(result.caches, function(a,b) return a.id < b.id end)
  result.caches_complete = complete
  if complete then
    for _, cache in ipairs(result.caches) do
      local key = "L" .. cache.level .. ":" .. cache.type
      local sum = summaries[key] or { id = key, level = cache.level, type = cache.type,
        instances = 0, total_size_bytes = 0, minimum_size_bytes = cache.size_bytes, maximum_size_bytes = cache.size_bytes }
      sum.instances, sum.total_size_bytes = sum.instances + 1, sum.total_size_bytes + cache.size_bytes
      sum.minimum_size_bytes = math.min(sum.minimum_size_bytes, cache.size_bytes)
      sum.maximum_size_bytes = math.max(sum.maximum_size_bytes, cache.size_bytes)
      summaries[key] = sum
    end
    for _, sum in pairs(summaries) do result.cache_summary[#result.cache_summary + 1] = sum end
    table.sort(result.cache_summary, function(a,b) return a.id < b.id end)
  end
end

function M.decode(raw, targets)
  local ok, result = pcall(packet, raw, targets)
  if not ok or not result then return nil, "cpuid_invalid_response" end
  local feature_summary = {}
  for _, cpu in ipairs(result.logical_cpus) do
    cpu.identity = identity(cpu)
    cpu.features = cpu.status == 0 and decode_features(cpu) or {}
    for _, feature in ipairs(cpu.features) do
      local sum = feature_summary[feature.name] or { name = feature.name, reported_cpus = 0,
        hardware_cpus = 0, usable_cpus = 0, unknown_usability_cpus = 0 }
      sum.reported_cpus = sum.reported_cpus + 1
      if feature.hardware then sum.hardware_cpus = sum.hardware_cpus + 1 end
      if feature.usable then sum.usable_cpus = sum.usable_cpus + 1 end
      if feature.usable == nil then sum.unknown_usability_cpus = sum.unknown_usability_cpus + 1 end
      feature_summary[feature.name] = sum
    end
  end
  result.features = {}
  for _, sum in pairs(feature_summary) do result.features[#result.features + 1] = sum end
  table.sort(result.features, function(a,b) return a.name < b.name end)
  topology(result)
  caches(result)
  for _, cpu in ipairs(result.logical_cpus) do cpu._leaves, cpu._xcr0 = nil, nil end
  return result
end

function M.enrich(data, observation)
  if type(observation) ~= "table" then return end
  local targets = data.topology and data.topology.logical_cpus or {}
  local result, reason
  if observation.status == "ok" then result, reason = M.decode(observation.raw, targets) end
  result = result or { schema = "wtop.cpuid.v1", status = reason and "error" or observation.status,
    reason = reason or observation.reason, architecture_bits = observation.architecture_bits }
  result.source, result.age_ms = observation.source, observation.age_ms
  result.error_code = observation.error_code
  data.cpuid = result
  if result.status ~= "ok" then
    return (result.status == "pending" or result.status == "gap") and 250 or 5000
  end
  local roster_complete = data.topology and data.topology.truncated ~= true
    and (not data.topology.threads or data.topology.threads == #targets)
  result.scope = "observed_os_logical_cpus"
  result.roster_complete = roster_complete
  if result.topology.complete and roster_complete then
    data.os_topology = data.topology
    local top = {}; for key, value in pairs(data.topology) do top[key] = value end
    top.logical_cpus, top.source = {}, "CPUID"
    for key, value in pairs(result.topology) do
      if key ~= "complete" and key ~= "observed_logical_cpus" then top[key] = value end
    end
    top.quality, top.identity_quality = "fresh", "fresh"
    for index, decoded in ipairs(result.logical_cpus) do
      local row = {}; for key, value in pairs(targets[index]) do row[key] = value end
      local value = decoded.topology
      for _, key in ipairs({"package_id","core_id","core_key","thread_siblings","compute_unit_id","compute_unit_key","node_id","cores_per_compute_unit","apic_id"}) do row[key] = value[key] end
      row.initial_apic_id = decoded.identity.initial_apic_id
      row.package_id_known, row.core_id_known = true, true
      row.core_source, row.package_source, row.core_id_scope = value.method, value.method, "system"
      row.core_id_method, row.package_id_method = "cpuid_observed_apic", "cpuid_observed_apic"
      row.threads_in_core = #value.thread_siblings
      top.logical_cpus[#top.logical_cpus + 1] = row
    end
    data.topology = top
  end
  if result.caches_complete and roster_complete then
    data.os_caches, data.os_cache_summary = data.caches, data.cache_summary
    data.caches, data.cache_summary = result.caches, result.cache_summary
  end
end
return M
