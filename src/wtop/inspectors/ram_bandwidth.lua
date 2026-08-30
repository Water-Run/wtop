local Capability = require("wtop.core.capability")
local Clock = require("wtop.core.clock")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")
local Model = require("wtop.inspectors.model")

local Bandwidth = {}
Bandwidth.__index = Bandwidth

local MAX_CPU_ENTRIES = 8192
local MAX_CPU_ID = 1048575

local function safe_absolute_path(path)
  return type(path) == "string" and #path > 1 and #path <= 4096
    and path:sub(1, 1) == "/" and not path:find("\0", 1, true)
end

local function safe_text(value, maximum)
  if type(value) ~= "string" then return nil end
  maximum = maximum or 4096
  value = value:gsub("[%z\1-\31\127]", "�")
  if #value > maximum then value = value:sub(1, maximum) end
  while #value > 0 and not utf8.len(value) do value = value:sub(1, -2) end
  return value ~= "" and value or nil
end

local PMU_PATTERNS = {
  "^uncore_imc",
  "^amd_df",
  "^amd_l3",
  "^hisi_sccl",
  "^arm_dmc",
  "^dmc",
}

local function matches_pmu(name)
  if type(name) ~= "string" or #name == 0 or #name > 255
      or name == "." or name == ".."
      or not name:match("^[A-Za-z0-9_][A-Za-z0-9_.%-]*$") then
    return false
  end
  for _, pattern in ipairs(PMU_PATTERNS) do
    if name:match(pattern) then
      return true
    end
  end
  return false
end

local function finite_number(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function finite_nonnegative(value)
  return finite_number(value) and value >= 0
end

local function finite_positive(value)
  return finite_number(value) and value > 0
end

local function decimal_float(value)
  if type(value) ~= "string" then return nil end
  value = Common.trim(value)
  local mantissa, exponent = value:match("^([%+%-]?%d+%.?%d*)[eE]([%+%-]?%d+)$")
  if not mantissa then
    mantissa, exponent = value:match("^([%+%-]?%.%d+)[eE]([%+%-]?%d+)$")
  end
  if not mantissa then
    if value:match("^[%+%-]?%d+%.?%d*$") or value:match("^[%+%-]?%.%d+$") then
      mantissa = value
    else
      return nil
    end
  end
  local number = tonumber(value)
  return finite_number(number) and number or nil
end

local function safe_sysfs_name(value)
  return type(value) == "string"
    and #value > 0
    and #value <= 255
    and value ~= "."
    and value ~= ".."
    and value:match("^[A-Za-z0-9_][A-Za-z0-9_.%-]*$") ~= nil
end

local function event_metadata_name(name)
  return name:match("%.scale$") or name:match("%.unit$")
    or name:match("%.per%-pkg$") or name:match("%.snapshot$")
end

local function parse_cpu_list(value)
  local result = {}
  local seen = {}
  if type(value) ~= "string" then
    return result
  end
  for part in value:gmatch("[^,]+") do
    local first, last = part:match("^%s*(%d+)%-(%d+)%s*$")
    if first then
      first, last = tonumber(first), tonumber(last)
      if first <= last then
        last = math.min(last, MAX_CPU_ID)
        for cpu = first, last do
          if #result >= MAX_CPU_ENTRIES then break end
          if not seen[cpu] then
            result[#result + 1] = cpu
            seen[cpu] = true
          end
        end
      end
    else
      local cpu = tonumber(part:match("^%s*(%d+)%s*$"))
      if cpu and cpu <= MAX_CPU_ID and not seen[cpu] and #result < MAX_CPU_ENTRIES then
        result[#result + 1] = cpu
        seen[cpu] = true
      end
    end
    if #result >= MAX_CPU_ENTRIES then break end
  end
  table.sort(result)
  return result
end

local function parse_event_descriptor(value)
  local result = {}
  if type(value) ~= "string" then
    return result
  end
  for key, raw in value:gmatch("([%w_]+)=([^,%s]+)") do
    local hex = raw:match("^0[xX]([%da-fA-F]+)$")
    local number = hex and tonumber(hex, 16) or tonumber(raw)
    result[key] = finite_number(number) and number or raw
  end
  return result
end

local function theoretical_bytes_per_second(data_rate_mt_s, channels, bus_width_bits)
  if not finite_positive(data_rate_mt_s) then
    return nil, "data_rate_required"
  end
  if not finite_positive(channels) or channels % 1 ~= 0 then
    return nil, "reliable_channel_count_required"
  end
  if not finite_positive(bus_width_bits) or bus_width_bits % 1 ~= 0 then
    return nil, "bus_width_required"
  end
  local result = data_rate_mt_s * 1000000.0 * (bus_width_bits / 8) * channels
  if not finite_positive(result) then
    return nil, "theoretical_bandwidth_out_of_range"
  end
  return result
end

local function measured_rate(measured, rate_key, bytes_key)
  local direct = measured[rate_key]
  if direct ~= nil then
    if finite_nonnegative(direct) then return direct end
    return nil, "perf_reader_invalid_bandwidth"
  end
  local bytes = measured[bytes_key]
  if bytes == nil then return nil end
  if not finite_nonnegative(bytes) or not finite_positive(measured.duration_ns) then
    return nil, "perf_reader_invalid_counter_sample"
  end
  local rate = bytes * 1000000000.0 / measured.duration_ns
  if not finite_nonnegative(rate) then
    return nil, "perf_reader_bandwidth_out_of_range"
  end
  return rate
end

local function error_quality(status)
  if status == "denied" then return "denied" end
  if status == "unavailable" then return "unavailable" end
  return "error"
end

function Bandwidth.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Bandwidth options must be a table", 2) end
  local event_source_path = options.event_source_path or "/sys/bus/event_source/devices"
  local paranoid_path = options.paranoid_path or "/proc/sys/kernel/perf_event_paranoid"
  if not safe_absolute_path(event_source_path) or not safe_absolute_path(paranoid_path) then
    error("invalid bandwidth provider path", 2)
  end
  if options.perf_reader ~= nil and type(options.perf_reader) ~= "function" then
    error("perf_reader must be a function", 2)
  end
  return setmetatable({
    id = "memory.bandwidth",
    domain = "memory",
    fs = options.fs or FS.default,
    clock = options.clock or Clock.default,
    event_source_path = event_source_path,
    paranoid_path = paranoid_path,
    perf_reader = options.perf_reader,
    _method_style = true,
  }, Bandwidth)
end

function Bandwidth:_enumerate_pmus(fs)
  local entries, err, pmus_truncated = fs:list(self.event_source_path, 257)
  if not entries then
    return nil, err
  end
  local pmus = {}
  local maximum = math.min(#entries, 256)
  for index = 1, maximum do
    local name = entries[index]
    if matches_pmu(name) then
      local base = self.event_source_path .. "/" .. name
      local events = {}
      local event_entries, _, events_truncated = fs:list(base .. "/events", 513)
      if event_entries then
        for event_index = 1, math.min(#event_entries, 512) do
          local event_name = event_entries[event_index]
          if safe_sysfs_name(event_name) and not event_metadata_name(event_name) then
            local descriptor = fs:read(base .. "/events/" .. event_name, 65536)
            if descriptor then
              local event = parse_event_descriptor(descriptor)
              local scale_text = fs:read(base .. "/events/" .. event_name .. ".scale", 256)
              local scale = decimal_float(scale_text)
              event.scale = finite_positive(scale) and scale or nil
              local unit = fs:read(base .. "/events/" .. event_name .. ".unit", 256)
              event.unit = safe_text(unit and Common.trim(unit), 64)
              events[event_name] = event
            end
          end
        end
      end
      local cpumask = fs:read(base .. "/cpumask", 65536)
      local pmu_type = fs:read_number(base .. "/type")
      pmus[#pmus + 1] = {
        id = name,
        name = name,
        type = finite_nonnegative(pmu_type) and pmu_type % 1 == 0 and pmu_type or nil,
        cpus = parse_cpu_list(cpumask),
        events = events,
        events_truncated = events_truncated == true or (event_entries and #event_entries > 512),
        source = base,
      }
    end
  end
  table.sort(pmus, function(left, right)
    return left.name < right.name
  end)
  pmus.truncated = pmus_truncated == true or #entries > 256
  return pmus
end

function Bandwidth:probe(context)
  context = type(context) == "table" and context or nil
  local fs = context and context.fs or self.fs
  local pmus, err = self:_enumerate_pmus(fs)
  if not pmus then
    local status = FS.error_status(err)
    if status == "denied" then
      return Capability.denied(err.message, {
        source = self.event_source_path,
        permission = "sysfs_read_access_required",
      })
    end
    return Capability.unavailable(err and err.message or "pmu_sysfs_unavailable", { source = self.event_source_path })
  end
  if #pmus == 0 then
    return Capability.unavailable("memory_controller_pmu_not_found", { source = self.event_source_path })
  end
  local reader = context and context.perf_reader or self.perf_reader
  if type(reader) ~= "function" then
    local paranoid = fs:read_number(self.paranoid_path)
    return Capability.new("degraded", {
      reason = "perf_reader_unavailable",
      source = self.event_source_path,
      details = { pmus = #pmus, perf_event_paranoid = paranoid },
      permission = "CAP_PERFMON_may_be_required",
    })
  end
  return Capability.available({ source = self.event_source_path, details = { pmus = #pmus } })
end

function Bandwidth:enumerate(context)
  context = type(context) == "table" and context or nil
  local fs = context and context.fs or self.fs
  return self:_enumerate_pmus(fs)
end

function Bandwidth:inspect(context, entity)
  context = type(context) == "table" and context or {}
  entity = type(entity) == "table" and entity or {}
  local started = Common.now_ns(context, self.clock)
  local fs = context.fs or self.fs
  local pmus, enumerate_error = self:_enumerate_pmus(fs)
  local theoretical, theoretical_error = theoretical_bytes_per_second(
    entity.data_rate_mt_s,
    entity.channels,
    entity.bus_width_bits
  )

  local measured
  local reader_error
  local reader = context.perf_reader or self.perf_reader
  if type(reader) == "function" and pmus and #pmus > 0 then
    local ok, result = pcall(reader, {
      pmus = pmus,
      duration_ms = type(context.sample_duration_ms) == "number"
          and context.sample_duration_ms == context.sample_duration_ms
          and math.max(50, math.min(2000, math.floor(context.sample_duration_ms))) or 250,
      entity = entity,
      perf_event_paranoid = fs:read_number(self.paranoid_path),
    })
    if ok and type(result) == "table" then
      measured = result
    elseif ok then
      reader_error = { status = "error", reason = "invalid_perf_reader_result" }
    else
      reader_error = { status = "error", reason = "perf_reader_exception", detail = tostring(result) }
    end
  elseif not pmus then
    local status = FS.error_status(enumerate_error)
    reader_error = {
      status = status,
      reason = enumerate_error and enumerate_error.message,
      provider = "pmu_sysfs",
      permission = status == "denied" and "sysfs_read_access_required" or "user",
    }
  elseif #pmus == 0 then
    reader_error = {
      status = "unavailable",
      reason = "memory_controller_pmu_not_found",
      provider = "pmu_sysfs",
      permission = "user",
    }
  else
    local paranoid = fs:read_number(self.paranoid_path)
    reader_error = {
      status = "unavailable",
      reason = "perf_reader_unavailable",
      perf_event_paranoid = paranoid,
    }
  end

  local finished = Common.now_ns(context, self.clock)
  local source = self.event_source_path
  local reader_metadata = measured or reader_error
  local reader_provider = reader_metadata and type(reader_metadata.provider) == "string"
    and reader_metadata.provider ~= "" and reader_metadata.provider or "perf_stat"
  local reader_permission = reader_metadata and type(reader_metadata.permission) == "string"
    and reader_metadata.permission ~= "" and reader_metadata.permission
    or "CAP_PERFMON_may_be_required"
  local quality = "unavailable"
  local read_bps, write_bps, total_bps
  if measured then
    if measured.status == "denied" then
      reader_error = measured
      measured = nil
      quality = "denied"
    elseif measured.status == "ok" or measured.status == nil then
      local read_error, write_error
      read_bps, read_error = measured_rate(measured, "read_bytes_per_second", "read_bytes")
      write_bps, write_error = measured_rate(measured, "write_bytes_per_second", "write_bytes")
      if read_error or write_error then
        quality = "error"
        reader_error = { status = "error", reason = read_error or write_error }
        measured = nil
        read_bps, write_bps = nil, nil
      elseif read_bps ~= nil or write_bps ~= nil then
        total_bps = (read_bps or 0) * 1.0 + (write_bps or 0) * 1.0
        if not finite_nonnegative(total_bps) then
          total_bps, read_bps, write_bps = nil, nil, nil
          quality = "error"
          reader_error = { status = "error", reason = "perf_reader_bandwidth_out_of_range" }
          measured = nil
        else
          quality = (measured.estimated == true or read_bps == nil or write_bps == nil)
            and "estimated" or "fresh"
        end
      else
        quality = "error"
        reader_error = { status = "error", reason = "perf_reader_missing_bandwidth" }
        measured = nil
      end
    else
      local status = measured.status
      if status == "unavailable" or status == "error"
          or status == "timeout" or status == "cancelled" then
        quality = error_quality(status)
        reader_error = {}
        for key, value in pairs(measured) do reader_error[key] = value end
        if not reader_error.reason then
          reader_error.reason = status == "timeout" and "perf_reader_timeout"
            or status == "cancelled" and "perf_reader_cancelled"
            or "perf_reader_failed"
        end
      else
        quality = "error"
        reader_error = { status = "error", reason = "invalid_perf_reader_status" }
      end
      measured = nil
    end
  elseif reader_error then
    quality = error_quality(reader_error.status)
  end

  local utilization
  if total_bps and theoretical and theoretical > 0 then
    utilization = total_bps / theoretical * 100
    if not finite_nonnegative(utilization) then utilization = nil end
  end
  local missing_quality = quality == "denied" and "denied"
    or quality == "error" and "error" or "unavailable"
  local read_quality = read_bps ~= nil and quality or missing_quality
  local write_quality = write_bps ~= nil and quality or missing_quality
  local partial_reason = total_bps ~= nil and (read_bps == nil or write_bps == nil)
    and "perf_reader_partial_bandwidth" or nil
  local fields = {
    read_bandwidth = Model.field(read_bps, "bytes_per_second", {
      source = source,
      timestamp_ns = finished,
      quality = read_quality,
      permission = reader_permission,
      provider = reader_provider,
      provider_version = measured and measured.formula_version,
      reason = read_bps == nil and ((reader_error and reader_error.reason)
        or "perf_reader_missing_read_bandwidth") or nil,
    }),
    write_bandwidth = Model.field(write_bps, "bytes_per_second", {
      source = source,
      timestamp_ns = finished,
      quality = write_quality,
      permission = reader_permission,
      provider = reader_provider,
      provider_version = measured and measured.formula_version,
      reason = write_bps == nil and ((reader_error and reader_error.reason)
        or "perf_reader_missing_write_bandwidth") or nil,
    }),
    total_bandwidth = Model.field(total_bps, "bytes_per_second", {
      source = source,
      timestamp_ns = finished,
      quality = quality,
      permission = reader_permission,
      provider = reader_provider,
      provider_version = measured and measured.formula_version,
      reason = (reader_error and reader_error.reason) or partial_reason,
    }),
    theoretical_bandwidth = Model.field(theoretical, "bytes_per_second", {
      source = entity.topology_source,
      timestamp_ns = finished,
      quality = theoretical and "estimated" or "unavailable",
      estimated = theoretical ~= nil,
      provider = "memory_topology_formula",
      provider_version = "1",
      reason = theoretical_error,
    }),
    utilization = Model.field(utilization, "percent", {
      source = source,
      timestamp_ns = finished,
      quality = utilization and (quality == "fresh" and "estimated" or quality) or "unavailable",
      estimated = utilization ~= nil,
      provider = "derived",
      reason = utilization and nil or "credible_theoretical_limit_required",
    }),
  }
  local entity_id = safe_text(entity.id, 4096) or "system-memory"
  local normalized_entity = Model.entity(entity_id, "memory", {
    name = safe_text(entity.name) or "System RAM",
    metrics = fields,
    evidence = {
      source = source,
      timestamp_ns = finished,
      pmus = pmus,
      reader_error = reader_error,
    },
  })
  local status = total_bps and "ok" or (quality == "denied" and "denied" or "unavailable")
  if not total_bps and theoretical then
    -- The inspector remains useful when only a clearly-labelled theoretical
    -- value is available.
    status = "ok"
    quality = "estimated"
  end
  local result_provider = measured and reader_provider
    or theoretical and "memory_topology_formula"
    or reader_error and reader_provider
    or "memory_topology_formula"
  local result_provider_version = measured and measured.formula_version
    or theoretical and "1" or nil
  local result_source = result_provider == "memory_topology_formula"
    and entity.topology_source or source
  local result_permission = result_provider == "memory_topology_formula"
    and "user" or reader_permission
  local section_source
  if total_bps ~= nil and theoretical ~= nil then
    -- This section contains values from two independent sources.
    section_source = nil
  elseif total_bps ~= nil then
    section_source = source
  elseif theoretical ~= nil then
    section_source = entity.topology_source
  else
    section_source = source
  end
  return Model.result(status, normalized_entity, {
    Model.section("bandwidth", fields, { quality = quality, source = section_source }),
  }, {
    timestamp_ns = finished,
    duration_ns = finished >= started and math.max(0, (finished + 0.0) - started) or 0,
    quality = quality,
    reason = (reader_error and reader_error.reason) or partial_reason,
    source = result_source,
    permission = result_permission,
    provider = result_provider,
    provider_version = result_provider_version,
    details = { pmu_count = pmus and #pmus or 0, reader_error = reader_error },
  })
end

function Bandwidth:invalidate()
  -- Samples are not cached; present for the Inspector protocol.
end

Bandwidth.parse_cpu_list = parse_cpu_list
Bandwidth.parse_event_descriptor = parse_event_descriptor
Bandwidth.theoretical_bytes_per_second = theoretical_bytes_per_second
Bandwidth.matches_pmu = matches_pmu
Bandwidth.decimal_float = decimal_float

return Bandwidth
