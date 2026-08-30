local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local CPUInfo = {}
CPUInfo.__index = CPUInfo

local ARM_IMPLEMENTERS = {
  ["0x41"] = "Arm Limited",
  ["0x42"] = "Broadcom",
  ["0x43"] = "Cavium",
  ["0x46"] = "Fujitsu",
  ["0x48"] = "HiSilicon",
  ["0x4e"] = "NVIDIA",
  ["0x50"] = "Applied Micro",
  ["0x51"] = "Qualcomm",
  ["0x53"] = "Samsung",
  ["0x56"] = "Marvell",
  ["0x61"] = "Apple",
  ["0xc0"] = "Ampere Computing",
}

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function bounded_integer(name, value, default, minimum, maximum)
  if value == nil then return default end
  if not finite_number(value) or value % 1 ~= 0 or value < minimum or value > maximum then
    error(name .. " must be an integer in " .. minimum .. ".." .. maximum, 3)
  end
  return value
end

local function optional_absence(err)
  return err and (err.kind == "missing" or err.kind == "unavailable")
end

local function add_issue(issues, field, err, source, limit)
  if #issues >= limit then return end
  issues[#issues + 1] = {
    field = field,
    status = FS.error_status(err),
    reason = err and err.message or "read_failed",
    source = source,
  }
end

local function safe_text(value, maximum)
  value = Common.safe_text(Common.trim(value or ""), maximum or 4096)
  return value ~= "" and value or nil
end

local function optional_text(fs, path, issues, field, issue_limit, maximum)
  local content, err = fs:read(path, maximum or 4096)
  if not content then
    if not optional_absence(err) then add_issue(issues, field, err, path, issue_limit) end
    return nil
  end
  local value = safe_text(content, maximum)
  if not value then
    add_issue(issues, field, { kind = "parse_error", message = "empty_value" }, path, issue_limit)
  end
  return value
end

local function parse_integer(value, minimum, maximum)
  value = Common.trim(value)
  if type(value) ~= "string" or not value:match("^[+-]?%d+$") then return nil end
  local number = tonumber(value)
  if not number or math.type(number) ~= "integer"
      or (minimum and number < minimum) or (maximum and number > maximum) then
    return nil
  end
  return number
end

local function optional_integer(fs, path, issues, field, issue_limit, minimum, maximum)
  local text = optional_text(fs, path, issues, field, issue_limit, 256)
  if text == nil then return nil end
  local value = parse_integer(text, minimum, maximum)
  if value == nil then
    add_issue(issues, field, { kind = "parse_error", message = "expected_integer" },
      path, issue_limit)
  end
  return value
end

local function parse_cpu_list(content, maximum_cpus, maximum_cpu_id)
  content = Common.trim(content)
  if type(content) ~= "string" or content == "" then return nil, "empty_cpu_list" end
  local result, seen = {}, {}
  for token in content:gmatch("[^,%s]+") do
    local first, last = token:match("^(%d+)%-(%d+)$")
    if not first then first = token:match("^(%d+)$"); last = first end
    first, last = tonumber(first), tonumber(last)
    if not first or not last or math.type(first) ~= "integer" or math.type(last) ~= "integer"
        or first > last or last > maximum_cpu_id
        or last - first + 1 > maximum_cpus or #result + last - first + 1 > maximum_cpus then
      return nil, "invalid_cpu_list"
    end
    for cpu = first, last do
      if not seen[cpu] then seen[cpu] = true; result[#result + 1] = cpu end
    end
  end
  if #result == 0 then return nil, "empty_cpu_list" end
  table.sort(result)
  return result
end

local function read_cpu_list(fs, path, issues, field, options)
  local content, err = fs:read(path, 65536)
  if not content then
    if not optional_absence(err) then add_issue(issues, field, err, path, options.max_issues) end
    return nil
  end
  local values, reason = parse_cpu_list(content, options.max_cpus, options.max_cpu_id)
  if not values then
    add_issue(issues, field, { kind = "parse_error", message = reason }, path, options.max_issues)
  end
  return values
end

local function parse_cpuinfo(content, maximum_sections)
  if type(content) ~= "string" then return nil, "expected_cpuinfo_text" end
  local sections, current = {}, {}
  local function finish()
    if next(current) then
      if #sections >= maximum_sections then return false end
      sections[#sections + 1] = current
      current = {}
    end
    return true
  end
  local truncated = false
  for raw_line in (content .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw_line:gsub("\r$", "")
    if line:match("^%s*$") then
      if not finish() then truncated = true; break end
    else
      local key, value = line:match("^%s*([^:]+)%s*:%s*(.-)%s*$")
      if key then
        key = Common.trim(key):lower()
        if current[key] == nil then current[key] = safe_text(value, 65536) or "" end
      end
    end
  end
  if not truncated and next(current) then
    if #sections < maximum_sections then sections[#sections + 1] = current else truncated = true end
  end
  if #sections == 0 then return nil, "no_cpuinfo_sections" end
  return sections, nil, truncated
end

local function first_nonempty(fields, keys)
  for _, key in ipairs(keys) do
    local value = fields[key]
    if type(value) == "string" and value ~= "" then return value end
  end
end

local function identity_fields(first)
  first = first or {}
  local model_name = first_nonempty(first, {
    "model name", "hardware", "machine", "uarch", "cpu", "processor",
  })
  if model_name and model_name:match("^%d+$") then model_name = nil end
  local implementer = first["cpu implementer"] and first["cpu implementer"]:lower()
  local vendor = first_nonempty(first, {
    "vendor_id", "vendor", "mvendorid", "platform", "system type",
  }) or (implementer and (ARM_IMPLEMENTERS[implementer] or implementer))
  return {
    model_name = model_name,
    vendor = vendor,
    family = first_nonempty(first, { "cpu family", "cpu architecture", "isa" }),
    model = first_nonempty(first, { "model", "cpu part", "uarch", "cpu" }),
    stepping = first_nonempty(first, { "stepping", "cpu revision", "revision" }),
    microcode = first["microcode"],
    implementer = first["cpu implementer"],
    architecture = first_nonempty(first, { "cpu architecture", "isa", "architecture" }),
    variant = first["cpu variant"],
    part = first["cpu part"],
  }
end

local function identity_from_sections(sections, maximum_flags)
  local first = sections[1] or {}
  local identity = identity_fields(first)
  local flags_text = first_nonempty(first, { "flags", "features", "isa", "cpu features" })
  local flags, seen, flags_truncated = {}, {}, false
  for flag in tostring(flags_text or ""):gmatch("%S+") do
    if not seen[flag] then
      if #flags >= maximum_flags then flags_truncated = true; break end
      seen[flag] = true
      flags[#flags + 1] = safe_text(flag, 256)
    end
  end
  identity.flags = flags
  identity.flags_count = #flags
  identity.flags_truncated = flags_truncated
  return identity
end

local function section_cpu_id(section, fallback)
  return parse_integer(section.processor, 0, 2147483647)
    or parse_integer(section.hart, 0, 2147483647)
    or fallback
end

local function cache_size_bytes(value)
  value = Common.trim(value)
  if type(value) ~= "string" then return nil end
  local number, suffix = value:match("^(%d+)%s*([kKmMgG]?[bB]?)$")
  if not number then return nil end
  number = tonumber(number)
  local multiplier = ({ [""] = 1, b = 1, k = 1024, kb = 1024,
    m = 1024 ^ 2, mb = 1024 ^ 2, g = 1024 ^ 3, gb = 1024 ^ 3 })[suffix:lower()]
  if not number or not multiplier or number > math.maxinteger // multiplier then return nil end
  return number * multiplier
end

local function cached_shared_cpu_list(self, fs, path, issues, cache)
  local content, err = fs:read(path, 65536)
  if not content then
    if not optional_absence(err) then
      add_issue(issues, "cache.shared_cpu_list", err, path, self.max_issues)
    end
    return nil, nil
  end
  local text = Common.trim(content)
  local cached = cache[text]
  if cached then return cached.values, cached.text end
  local values, reason = parse_cpu_list(content, self.max_cpus, self.max_cpu_id)
  if not values then
    add_issue(issues, "cache.shared_cpu_list",
      { kind = "parse_error", message = reason }, path, self.max_issues)
  end
  cached = { values = values, text = text ~= "" and text or nil }
  cache[text] = cached
  return cached.values, cached.text
end

local function read_cache(self, fs, cpu, entry, issues, shared_list_cache)
  local base = self.sys_cpu_path .. "/cpu" .. tostring(cpu) .. "/cache/" .. entry
  local level = optional_integer(fs, base .. "/level", issues, "cache.level", self.max_issues, 1, 64)
  local kind = optional_text(fs, base .. "/type", issues, "cache.type", self.max_issues, 256)
  local size_text = optional_text(fs, base .. "/size", issues, "cache.size", self.max_issues, 256)
  local shared, shared_text = cached_shared_cpu_list(
    self, fs, base .. "/shared_cpu_list", issues, shared_list_cache)
  if not level and not kind and not size_text then return nil end
  local size_bytes = cache_size_bytes(size_text)
  if size_text and not size_bytes then
    add_issue(issues, "cache.size", { kind = "parse_error", message = "invalid_cache_size" },
      base .. "/size", self.max_issues)
  end
  return {
    cache_id = optional_integer(fs, base .. "/id", issues,
      "cache.id", self.max_issues, 0, 2147483647),
    level = level,
    type = kind,
    size = size_text,
    size_bytes = size_bytes,
    shared_cpu_list = shared,
    shared_cpu_list_text = shared_text,
    coherency_line_size_bytes = optional_integer(fs, base .. "/coherency_line_size", issues,
      "cache.coherency_line_size", self.max_issues, 0, 1048576),
    ways_of_associativity = optional_integer(fs, base .. "/ways_of_associativity", issues,
      "cache.ways_of_associativity", self.max_issues, 0, 1048576),
    number_of_sets = optional_integer(fs, base .. "/number_of_sets", issues,
      "cache.number_of_sets", self.max_issues, 0, 2147483647),
    physical_line_partition = optional_integer(fs, base .. "/physical_line_partition", issues,
      "cache.physical_line_partition", self.max_issues, 0, 1048576),
    source = base,
  }
end

local function cache_inventory(self, fs, cpu_ids, issues)
  local caches, seen, truncated = {}, {}, false
  local shared_list_cache = {}
  for _, cpu in ipairs(cpu_ids) do
    local base = self.sys_cpu_path .. "/cpu" .. tostring(cpu) .. "/cache"
    local entries, err, list_truncated = fs:list(base, self.max_cache_indexes_per_cpu + 1)
    if entries then
      if list_truncated or #entries > self.max_cache_indexes_per_cpu then truncated = true end
      for index = 1, math.min(#entries, self.max_cache_indexes_per_cpu) do
        local entry = entries[index]
        if entry:match("^index%d+$") then
          local cache = read_cache(self, fs, cpu, entry, issues, shared_list_cache)
          if cache then
            local key = table.concat({ tostring(cache.level), tostring(cache.type),
              tostring(cache.size_bytes), tostring(cache.cache_id),
              cache.shared_cpu_list_text or ("cpu" .. tostring(cpu)) }, ":")
            if not seen[key] then
              if #caches >= self.max_caches then truncated = true; break end
              seen[key] = true
              cache.id = key
              caches[#caches + 1] = cache
            end
          end
        end
      end
    elseif err and not optional_absence(err) then
      add_issue(issues, "cache.directory", err, base, self.max_issues)
    end
    if #caches >= self.max_caches then break end
  end
  table.sort(caches, function(left, right)
    if left.level ~= right.level then return (left.level or math.huge) < (right.level or math.huge) end
    if left.type ~= right.type then return tostring(left.type) < tostring(right.type) end
    return left.id < right.id
  end)
  local summaries, by_key = {}, {}
  for _, cache in ipairs(caches) do
    local key = "L" .. tostring(cache.level or "?") .. ":" .. tostring(cache.type or "Unknown")
    local summary = by_key[key]
    if not summary then
      summary = { id = key, level = cache.level, type = cache.type, instances = 0,
        total_size_bytes = 0, minimum_size_bytes = nil, maximum_size_bytes = nil }
      by_key[key] = summary
      summaries[#summaries + 1] = summary
    end
    summary.instances = summary.instances + 1
    if cache.size_bytes then
      summary.total_size_bytes = summary.total_size_bytes + cache.size_bytes
      summary.minimum_size_bytes = summary.minimum_size_bytes
        and math.min(summary.minimum_size_bytes, cache.size_bytes) or cache.size_bytes
      summary.maximum_size_bytes = summary.maximum_size_bytes
        and math.max(summary.maximum_size_bytes, cache.size_bytes) or cache.size_bytes
    end
  end
  return caches, summaries, truncated
end

local function topology_inventory(self, fs, sections, issues)
  local proc_by_cpu = {}
  for index, section in ipairs(sections) do proc_by_cpu[section_cpu_id(section, index - 1)] = section end
  local entries, list_error, list_truncated = fs:list(self.sys_cpu_path, self.max_sys_entries + 1)
  local cpu_ids = {}
  if entries then
    for index = 1, math.min(#entries, self.max_sys_entries) do
      local id = entries[index]:match("^cpu(%d+)$")
      id = id and tonumber(id) or nil
      if id and id <= self.max_cpu_id then cpu_ids[#cpu_ids + 1] = id end
    end
    table.sort(cpu_ids)
  elseif list_error and not optional_absence(list_error) then
    add_issue(issues, "topology.directory", list_error, self.sys_cpu_path, self.max_issues)
  end
  if #cpu_ids == 0 then
    for id in pairs(proc_by_cpu) do cpu_ids[#cpu_ids + 1] = id end
    table.sort(cpu_ids)
  end
  if #cpu_ids > self.max_cpus then
    for index = #cpu_ids, self.max_cpus + 1, -1 do cpu_ids[index] = nil end
    list_truncated = true
  end

  local online = read_cpu_list(fs, self.sys_cpu_path .. "/online", issues, "topology.online", self)
  local present = read_cpu_list(fs, self.sys_cpu_path .. "/present", issues, "topology.present", self)
  local possible = read_cpu_list(fs, self.sys_cpu_path .. "/possible", issues, "topology.possible", self)
  local isolated = read_cpu_list(fs, self.sys_cpu_path .. "/isolated", {}, "topology.isolated", self)
  local online_set = {}
  for _, id in ipairs(online or cpu_ids) do online_set[id] = true end

  local logical, sockets, cores = {}, {}, {}
  local estimated = false
  for _, id in ipairs(cpu_ids) do
    local base = self.sys_cpu_path .. "/cpu" .. tostring(id) .. "/topology"
    local proc = proc_by_cpu[id] or {}
    local package_id = optional_integer(fs, base .. "/physical_package_id", issues,
      "topology.package", self.max_issues, -2147483648, 2147483647)
      or parse_integer(proc["physical id"], -2147483648, 2147483647)
    local core_id = optional_integer(fs, base .. "/core_id", issues,
      "topology.core", self.max_issues, -2147483648, 2147483647)
      or parse_integer(proc["core id"], -2147483648, 2147483647)
    local die_id = optional_integer(fs, base .. "/die_id", issues,
      "topology.die", self.max_issues, -2147483648, 2147483647)
    local cluster_id = optional_integer(fs, base .. "/cluster_id", issues,
      "topology.cluster", self.max_issues, -2147483648, 2147483647)
    if package_id == nil then package_id = 0; estimated = true end
    if core_id == nil then core_id = id; estimated = true end
    sockets[tostring(package_id)] = true
    local core_key = table.concat({ tostring(package_id), tostring(die_id or "-"),
      tostring(cluster_id or "-"), tostring(core_id) }, ":")
    cores[core_key] = (cores[core_key] or 0) + 1
    local thread_siblings = read_cpu_list(fs, base .. "/thread_siblings_list", {},
      "topology.thread_siblings", self)
    local maximum_frequency_khz = optional_integer(fs,
      self.sys_cpu_path .. "/cpu" .. tostring(id) .. "/cpufreq/cpuinfo_max_freq", issues,
      "topology.maximum_frequency", self.max_issues, 1, 1000000000000)
    logical[#logical + 1] = {
      id = id,
      online = online_set[id] == true,
      package_id = package_id,
      die_id = die_id,
      cluster_id = cluster_id,
      core_id = core_id,
      core_key = core_key,
      cpu_capacity = optional_integer(fs,
        self.sys_cpu_path .. "/cpu" .. tostring(id) .. "/cpu_capacity", issues,
        "topology.cpu_capacity", self.max_issues, 0, 2147483647),
      kernel_core_type = optional_integer(fs, base .. "/core_type", issues,
        "topology.core_type", self.max_issues, 0, 255),
      maximum_frequency_hz = maximum_frequency_khz and maximum_frequency_khz * 1000 or nil,
      thread_siblings = thread_siblings,
      source = base,
    }
  end
  local socket_count, core_count, minimum_threads, maximum_threads = 0, 0
  for _ in pairs(sockets) do socket_count = socket_count + 1 end
  for _, count in pairs(cores) do
    core_count = core_count + 1
    minimum_threads = minimum_threads and math.min(minimum_threads, count) or count
    maximum_threads = maximum_threads and math.max(maximum_threads, count) or count
  end
  local online_count = 0
  for _, item in ipairs(logical) do
    item.threads_in_core = cores[item.core_key]
    if item.online then online_count = online_count + 1 end
  end
  return {
    sockets = socket_count,
    physical_cores = core_count,
    threads = #logical,
    online_threads = online_count,
    threads_per_core_minimum = minimum_threads,
    threads_per_core_maximum = maximum_threads,
    online_cpu_list = online,
    present_cpu_list = present,
    possible_cpu_list = possible,
    isolated_cpu_list = isolated,
    logical_cpus = logical,
    quality = estimated and "estimated" or "fresh",
    truncated = list_truncated == true or (entries and #entries > self.max_sys_entries) or false,
  }, cpu_ids
end

local function core_type_inventory(self, sections, topology)
  local sections_by_cpu = {}
  for index, section in ipairs(sections) do
    sections_by_cpu[section_cpu_id(section, index - 1)] = section
  end
  local base_groups, base_by_signature = {}, {}
  for _, logical in ipairs(topology.logical_cpus or {}) do
    local fields = identity_fields(sections_by_cpu[logical.id] or {})
    local signature = table.concat({
      tostring(fields.vendor or "-"), tostring(fields.model_name or "-"),
      tostring(fields.family or "-"), tostring(fields.model or "-"),
      tostring(fields.stepping or "-"),
      tostring(fields.implementer or "-"), tostring(fields.architecture or "-"),
      tostring(fields.variant or "-"), tostring(fields.part or "-"),
      tostring(logical.cpu_capacity or "-"), tostring(logical.kernel_core_type or "-"),
      tostring(logical.threads_in_core or "-"),
    }, "\0")
    local base = base_by_signature[signature]
    if not base then
      base = { fields = fields, members = {} }
      base_by_signature[signature] = base
      base_groups[#base_groups + 1] = base
    end
    base.members[#base.members + 1] = logical
  end

  local types, truncated = {}, false
  for _, base in ipairs(base_groups) do
    -- Frequency is a fallback discriminator only when every member exposes a
    -- value and the values form clearly separated clusters. Offline CPUs
    -- commonly lack cpufreq files; absence must not manufacture a core type.
    local frequencies, frequency_seen, complete_frequencies = {}, {}, true
    for _, logical in ipairs(base.members) do
      local value = logical.maximum_frequency_hz
      if not finite_number(value) then
        complete_frequencies = false
      elseif not frequency_seen[value] then
        frequency_seen[value] = true
        frequencies[#frequencies + 1] = value
      end
    end
    table.sort(frequencies)
    local frequency_cluster = {}
    local cluster_count = 1
    if complete_frequencies and #frequencies > 1 then
      frequency_cluster[frequencies[1]] = cluster_count
      for index = 2, #frequencies do
        if (frequencies[index] + 0.0) / frequencies[index - 1] >= 1.10 then
          cluster_count = cluster_count + 1
        end
        frequency_cluster[frequencies[index]] = cluster_count
      end
    end
    local split_by_frequency = complete_frequencies and cluster_count > 1
    local subgroups, subgroup_by_key = {}, {}
    for _, logical in ipairs(base.members) do
      local key = split_by_frequency and tostring(frequency_cluster[logical.maximum_frequency_hz])
        or "stable"
      local subgroup = subgroup_by_key[key]
      if not subgroup then
        subgroup = {}
        subgroup_by_key[key] = subgroup
        subgroups[#subgroups + 1] = subgroup
      end
      subgroup[#subgroup + 1] = logical
    end

    for _, members in ipairs(subgroups) do
      if #types >= self.max_core_types then
        truncated = true
      else
        local first = members[1]
        local fields = base.fields
        local core_type = {
          id = "type-" .. tostring(#types + 1),
          model_name = fields.model_name,
          vendor = fields.vendor,
          family = fields.family,
          model = fields.model,
          stepping = fields.stepping,
          implementer = fields.implementer,
          architecture = fields.architecture,
          variant = fields.variant,
          part = fields.part,
          cpu_capacity = first.cpu_capacity,
          kernel_core_type = first.kernel_core_type,
          threads_per_core = first.threads_in_core,
          maximum_frequency_hz = nil,
          physical_core_count = 0,
          logical_cpu_count = 0,
          logical_cpu_ids = {},
          _core_keys = {},
        }
        for _, logical in ipairs(members) do
          if not core_type._core_keys[logical.core_key] then
            core_type._core_keys[logical.core_key] = true
            core_type.physical_core_count = core_type.physical_core_count + 1
          end
          if finite_number(logical.maximum_frequency_hz) then
            core_type.maximum_frequency_hz = math.max(
              core_type.maximum_frequency_hz or logical.maximum_frequency_hz,
              logical.maximum_frequency_hz)
          end
          core_type.logical_cpu_count = core_type.logical_cpu_count + 1
          core_type.logical_cpu_ids[#core_type.logical_cpu_ids + 1] = logical.id
          logical.core_type_id = core_type.id
        end
        core_type._core_keys = nil
        types[#types + 1] = core_type
      end
    end
  end
  return types, truncated
end

function CPUInfo.new(options)
  options = options or {}
  if type(options) ~= "table" then error("CPUInfo options must be a table", 2) end
  return setmetatable({
    id = "cpu_info",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 30000),
    fs = options.fs or FS.default,
    proc_cpuinfo_path = Common.absolute_path(
      "proc_cpuinfo_path", options.proc_cpuinfo_path, "/proc/cpuinfo"),
    sys_cpu_path = Common.absolute_path(
      "sys_cpu_path", options.sys_cpu_path, "/sys/devices/system/cpu"),
    max_cpus = bounded_integer("max_cpus", options.max_cpus, 4096, 1, 65536),
    max_cpu_id = bounded_integer("max_cpu_id", options.max_cpu_id, 1048575, 0, 2147483647),
    max_flags = bounded_integer("max_flags", options.max_flags, 4096, 1, 65536),
    max_sys_entries = bounded_integer("max_sys_entries", options.max_sys_entries, 8192, 1, 65536),
    max_cache_indexes_per_cpu = bounded_integer(
      "max_cache_indexes_per_cpu", options.max_cache_indexes_per_cpu, 64, 1, 4096),
    max_caches = bounded_integer("max_caches", options.max_caches, 4096, 1, 65536),
    max_core_types = bounded_integer(
      "max_core_types", options.max_core_types, 256, 1, 4096),
    max_issues = bounded_integer("max_issues", options.max_issues, 256, 1, 4096),
    max_cpuinfo_bytes = bounded_integer(
      "max_cpuinfo_bytes", options.max_cpuinfo_bytes, 16 * 1024 * 1024, 4096, 64 * 1024 * 1024),
    _method_style = true,
  }, CPUInfo)
end

function CPUInfo:probe(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.proc_cpuinfo_path, self.max_cpuinfo_bytes)
  if not content then
    local status = FS.error_status(err)
    if status == "denied" then return Capability.denied(err.message, { source = self.proc_cpuinfo_path }) end
    return Capability.unavailable(err and err.message or "cpuinfo_unavailable",
      { source = self.proc_cpuinfo_path })
  end
  local sections, parse_error = parse_cpuinfo(content, self.max_cpus)
  if not sections then
    return Capability.unavailable(parse_error, { source = self.proc_cpuinfo_path })
  end
  return Capability.available({ source = { self.proc_cpuinfo_path, self.sys_cpu_path },
    details = { logical_cpus = #sections } })
end

function CPUInfo:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.proc_cpuinfo_path, self.max_cpuinfo_bytes)
  if not content then return Common.error_result(err, Common.now_ns(context), self.proc_cpuinfo_path) end
  local sections, parse_error, section_truncated = parse_cpuinfo(content, self.max_cpus)
  if not sections then
    local finished = Common.now_ns(context)
    return Common.result("error", finished, nil, { quality = "error", reason = parse_error,
      duration_ns = Common.elapsed_ns(finished, started) or 0, source = self.proc_cpuinfo_path })
  end
  local issues = {}
  local topology, cpu_ids = topology_inventory(self, fs, sections, issues)
  local caches, cache_summary, cache_truncated = cache_inventory(self, fs, cpu_ids, issues)
  local core_types, core_types_truncated = core_type_inventory(self, sections, topology)
  local identity = identity_from_sections(sections, self.max_flags)
  identity.core_type_count = #core_types
  identity.heterogeneous = #core_types > 1
  local truncated = section_truncated or topology.truncated or cache_truncated
    or core_types_truncated or identity.flags_truncated
  local partial = truncated or #issues > 0
  local estimated = topology.quality == "estimated" or not identity.model_name or not identity.vendor
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, {
    schema = "dev.waterrun.wtop.cpu-info/v1",
    identity = identity,
    topology = topology,
    core_types = core_types,
    caches = caches,
    cache_summary = cache_summary,
    issues = issues,
    truncated = truncated,
  }, {
    quality = partial and "partial" or (estimated and "estimated" or "fresh"),
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = { self.proc_cpuinfo_path, self.sys_cpu_path },
  })
end

CPUInfo.parse_cpuinfo = parse_cpuinfo
CPUInfo.parse_cpu_list = parse_cpu_list
CPUInfo.cache_size_bytes = cache_size_bytes

return CPUInfo
