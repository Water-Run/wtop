local Clock = require("wtop.core.clock")
local Runner = require("wtop.core.runner")

local PerfBandwidth = {}
PerfBandwidth.__index = PerfBandwidth

local MAX_PMUS = 256
local MAX_EVENTS_PER_PMU = 512

local function safe_identifier(value)
  return type(value) == "string"
    and #value > 0
    and #value <= 255
    and value ~= "."
    and value ~= ".."
    and value:match("^[A-Za-z0-9_][A-Za-z0-9_.%-]*$") ~= nil
end

local function safe_executable(value)
  return type(value) == "string"
    and #value > 1
    and #value <= 4096
    and value:sub(1, 1) == "/"
    and value:find("\0", 1, true) == nil
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function finite_number(value)
  local number
  if type(value) == "number" then
    number = value
  elseif type(value) == "string"
      and value:match("^%d+%.?%d*$") then
    number = tonumber(value)
  end
  if not number or number ~= number or number == math.huge or number == -math.huge then
    return nil
  end
  return number
end

local function bounded_integer(value, default, minimum, maximum)
  local number = finite_number(value)
  if not number then number = default end
  return math.max(minimum, math.min(maximum, math.floor(number)))
end

local function unit_bytes(unit)
  unit = trim(unit):lower():gsub("%s+", "")
  if unit == "b" or unit == "byte" or unit == "bytes" then return 1 end
  if unit == "kib" then return 1024 end
  if unit == "mib" then return 1024 * 1024 end
  if unit == "gib" then return 1024 * 1024 * 1024 end
  if unit == "kb" then return 1000 end
  if unit == "mb" then return 1000000 end
  if unit == "gb" then return 1000000000 end
  return nil
end

local function direction_for(name)
  name = tostring(name or ""):lower()
  if name == "data_read" or name == "cas_count_read"
      or name:find("rdcas", 1, true) or name:find("cas_count_rd", 1, true) then
    return "read"
  end
  if name == "data_write" or name == "cas_count_write"
      or name:find("wrcas", 1, true) or name:find("cas_count_wr", 1, true) then
    return "write"
  end
  return nil
end

local function bytes_per_count(event)
  local multiplier = unit_bytes(event and event.unit)
  if multiplier then
    local scale = event and event.scale
    if scale == nil then scale = 1 else scale = finite_number(scale) end
    if not scale or scale <= 0 then return nil end
    local bytes = scale * (multiplier + 0.0)
    if bytes == math.huge or bytes ~= bytes then return nil end
    return bytes
  end
  -- CAS/DRAM data events count cache-line transfers.  Unknown event names
  -- are filtered before reaching this fallback.
  return 64
end

local function event_signature(event)
  if type(event) ~= "table" then return nil end
  local parts = {}
  local count = 0
  for key, value in pairs(event) do
    count = count + 1
    if count > 64 then return nil end
    local value_type = type(value)
    if type(key) == "string" and key ~= "scale" and key ~= "unit"
        and #key <= 255 and (value_type == "number" or value_type == "boolean"
          or (value_type == "string" and #value <= 4096)) then
      parts[#parts + 1] = key .. "=" .. tostring(value)
    end
  end
  if #parts == 0 then return nil end
  table.sort(parts)
  return table.concat(parts, ",")
end

local function event_priority(name)
  if name == "data_read" or name == "data_write"
      or name == "cas_count_read" or name == "cas_count_write" then
    return 0
  end
  return 1
end

local function split_fields(line, delimiter)
  local fields, start = {}, 1
  while true do
    local position = line:find(delimiter, start, true)
    if not position then
      fields[#fields + 1] = line:sub(start)
      break
    end
    fields[#fields + 1] = line:sub(start, position - 1)
    start = position + #delimiter
  end
  return fields
end

local function normalized_count(value)
  value = trim(value)
  if value == "" or value:sub(1, 1) == "<" then return nil end
  local count = finite_number(value)
  if not count or count < 0 then return nil end
  return count
end

local function parse_stat(text, specifications, delimiter)
  if type(delimiter) ~= "string" or delimiter == "" then delimiter = ";" end
  local counts, unsupported, samples, issues = {}, {}, {}, {}
  local by_label, seen_instances = {}, {}
  local specification_list = type(specifications) == "table" and specifications or {}
  for _, specification in ipairs(specification_list) do
    if type(specification) == "table" and type(specification.label) == "string" then
      by_label[specification.label] = specification
      samples[specification.label] = {}
      seen_instances[specification.label] = {}
    end
  end
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local fields = split_fields(line, delimiter)
    -- With --no-aggr, perf prefixes the regular CSV fields with the CPU (or
    -- uncore control-CPU) instance: CPU;value;unit;event;run;%... .  Keeping
    -- each row separate is essential: perf's default aggregation sums both
    -- values and run times, whose quotient is an instance average rather
    -- than total system bandwidth on multi-socket hosts.
    local instance = trim(fields[1])
    local label = trim(fields[4])
    if by_label[label] then
      local instances = seen_instances[label]
      local previous = instances[instance]
      if instance == "" or #instance > 255 then
        issues[label] = "invalid_instance"
      elseif previous then
        previous.invalid = true
        issues[label] = "duplicate_event"
      else
        local marker = {}
        instances[instance] = marker
        local raw_count = trim(fields[2])
        if raw_count == "<not supported>" then
          unsupported[label] = true
        elseif raw_count:sub(1, 1) == "<" then
          issues[label] = raw_count == "<not counted>" and "not_counted" or "invalid_count"
        else
          local count = normalized_count(raw_count)
          if count then
            local runtime_ns = finite_number(trim(fields[5]))
            local running_percent = finite_number(trim(fields[6]))
            if not runtime_ns or runtime_ns <= 0 then
              issues[label] = "invalid_runtime"
            else
              marker.count = count
              marker.unit = trim(fields[3])
              marker.runtime_ns = runtime_ns
              marker.running_percent = running_percent
              marker.instance = instance
              samples[label][#samples[label] + 1] = marker
            end
          else
            issues[label] = "invalid_count"
          end
        end
      end
    end
  end
  for label, rows in pairs(samples) do
    local total, valid = 0.0, 0
    for _, row in ipairs(rows) do
      if not row.invalid and total + row.count < math.huge then
        total = total + row.count
        valid = valid + 1
      end
    end
    if valid > 0 then counts[label] = total end
  end
  return counts, unsupported, samples, issues
end

local function permission_error(message)
  local lower = tostring(message or ""):lower()
  return lower:find("permission", 1, true)
    or lower:find("not permitted", 1, true)
    or lower:find("access to performance", 1, true)
    or lower:find("perf_event_paranoid", 1, true)
    or lower:find("cap_perfmon", 1, true)
end

local function event_open_failure(message)
  local lower = tostring(message or ""):lower()
  return lower:find("sys_perf_event_open", 1, true)
    or lower:find("failed to open event", 1, true)
    or lower:find("event open failed", 1, true)
end

local function unsupported_event_error(message)
  local lower = tostring(message or ""):lower()
  return lower:find("event is not supported", 1, true)
    or lower:find("event not supported", 1, true)
    or lower:find("no supported events found", 1, true)
end

local function workload_failure(message)
  local lower = tostring(message or ""):lower()
  if not lower:find("workload failed", 1, true) then return nil end
  if lower:find("no such file", 1, true) or lower:find("not found", 1, true) then
    return "missing"
  end
  if lower:find("permission denied", 1, true) or lower:find("not executable", 1, true) then
    return "not_executable"
  end
  return "failed"
end

function PerfBandwidth.new(options)
  options = options or {}
  if type(options) ~= "table" then error("PerfBandwidth options must be a table", 2) end
  return setmetatable({
    runner = options.runner or Runner.new(),
    clock = options.clock or Clock.default,
    executable = options.executable or "/usr/bin/perf",
    sleep_executable = options.sleep_executable or "/usr/bin/sleep",
    paranoid = options.paranoid,
    max_events = bounded_integer(options.max_events, 64, 1, 128),
    max_output_bytes = bounded_integer(options.max_output_bytes, 512 * 1024,
      4096, 4 * 1024 * 1024),
  }, PerfBandwidth)
end

function PerfBandwidth:_events(pmus)
  local list = type(pmus) == "table" and pmus or {}
  local specifications, seen = {}, {}
  local truncated = list.truncated == true
  local groups = {
    intel_free_running = { name = "intel_free_running", items = {}, count = 0 },
    intel_cas = { name = "intel_cas", items = {}, count = 0 },
    other = { name = "other", items = {}, count = 0 },
  }
  local descriptor_seen = {}
  local function add_candidate(group, candidate)
    group.count = group.count + 1
    group[candidate.direction] = true
    if #group.items < self.max_events then
      group.items[#group.items + 1] = candidate
    end
  end
  for pmu_index, pmu in ipairs(list) do
    if pmu_index > MAX_PMUS then truncated = true break end
    if type(pmu) == "table" and safe_identifier(pmu.name or pmu.id) then
      if pmu.events_truncated == true then truncated = true end
      local pmu_name = pmu.name or pmu.id
      local names = {}
      local events = type(pmu.events) == "table" and pmu.events or {}
      local names_seen = 0
      for name in pairs(events) do
        names_seen = names_seen + 1
        if names_seen > MAX_EVENTS_PER_PMU then truncated = true break end
        if safe_identifier(name) then names[#names + 1] = name end
      end
      table.sort(names, function(left, right)
        local left_priority, right_priority = event_priority(left), event_priority(right)
        return left_priority == right_priority and left < right or left_priority < right_priority
      end)
      for _, name in ipairs(names) do
        local direction = direction_for(name)
        local label = direction and (pmu_name .. "/" .. name .. "/") or nil
        local event = type(events[name]) == "table" and events[name] or {}
        local factor = label and bytes_per_count(event) or nil
        if label and factor and not seen[label] then
          seen[label] = true
          local signature = event_signature(event)
          local descriptor_key = signature
            and (pmu_name .. "\0" .. direction .. "\0" .. signature) or nil
          if not descriptor_key or not descriptor_seen[descriptor_key] then
            if descriptor_key then descriptor_seen[descriptor_key] = true end
            local group = pmu_name:match("^uncore_imc_free_running")
                and groups.intel_free_running
              or pmu_name:match("^uncore_imc") and groups.intel_cas
              or groups.other
            add_candidate(group, {
                label = label,
                direction = direction,
                bytes_per_count = factor,
                expected_instance_count = type(pmu.cpus) == "table" and #pmu.cpus > 0
                  and #pmu.cpus or nil,
              })
          else
            -- Multiple sysfs aliases for the same PMU encoding are one
            -- physical counter, not additive bandwidth sources.
          end
        end
      end
    end
  end

  local free, cas = groups.intel_free_running, groups.intel_cas
  local selected_intel
  if free.count > 0 and cas.count > 0 then
    if free.read and free.write then
      selected_intel = free
    elseif cas.read and cas.write then
      selected_intel = cas
    else
      local free_directions = (free.read and 1 or 0) + (free.write and 1 or 0)
      local cas_directions = (cas.read and 1 or 0) + (cas.write and 1 or 0)
      selected_intel = free_directions >= cas_directions and free or cas
    end
  elseif free.count > 0 then
    selected_intel = free
  elseif cas.count > 0 then
    selected_intel = cas
  end

  local candidates = {}
  for _, candidate in ipairs(groups.other.items) do candidates[#candidates + 1] = candidate end
  if selected_intel then
    for _, candidate in ipairs(selected_intel.items) do candidates[#candidates + 1] = candidate end
  end
  table.sort(candidates, function(left, right) return left.label < right.label end)
  for index = 1, math.min(#candidates, self.max_events) do
    specifications[index] = candidates[index]
  end
  local eligible = groups.other.count + (selected_intel and selected_intel.count or 0)
  if eligible > #specifications then truncated = true end
  local alternative_count = free.count + cas.count - (selected_intel and selected_intel.count or 0)
  return specifications, truncated, eligible, alternative_count,
    selected_intel and selected_intel.name or nil
end

function PerfBandwidth:read(request)
  request = type(request) == "table" and request or {}
  local duration_ms = bounded_integer(request.duration_ms, 250, 50, 2000)
  local specifications, events_truncated, eligible_event_count,
    alternative_event_count, selected_event_family = self:_events(request.pmus)
  if #specifications == 0 then
    return { status = "unavailable", reason = "supported_memory_events_not_found" }
  end
  if not safe_executable(self.executable) then
    return { status = "error", reason = "invalid_perf_executable" }
  end
  if not safe_executable(self.sleep_executable) then
    return { status = "error", reason = "invalid_sleep_executable" }
  end
  if type(self.runner) ~= "table" or type(self.runner.run) ~= "function" then
    return { status = "error", reason = "invalid_perf_runner" }
  end
  if type(self.clock) ~= "table" or type(self.clock.now_ns) ~= "function" then
    return { status = "error", reason = "invalid_perf_clock" }
  end
  local event_names = {}
  for index, specification in ipairs(specifications) do
    event_names[index] = specification.label
  end
  local sleep_duration = string.format("%d.%03d",
    math.floor(duration_ms / 1000), duration_ms % 1000)
  local started_ok, started = pcall(self.clock.now_ns, self.clock)
  if not started_ok or not finite_number(started) or started < 0 then
    return { status = "error", reason = "invalid_perf_clock_result" }
  end
  local argv = {
    self.executable,
    "stat",
    "--no-big-num",
    "--no-scale",
    "-x", ";",
    "-a",
    "-A",
    "-e", table.concat(event_names, ","),
    "--",
    self.sleep_executable,
    sleep_duration,
  }
  local policy = {
    timeout_ms = duration_ms + 1250,
    max_output_bytes = self.max_output_bytes,
  }
  local run_ok, run = pcall(self.runner.run, self.runner, argv, policy)
  local finished_ok, finished = pcall(self.clock.now_ns, self.clock)
  if not finished_ok or not finite_number(finished) or finished < 0 then
    return { status = "error", reason = "invalid_perf_clock_result" }
  end
  if not run_ok then
    return { status = "error", reason = "perf_runner_exception" }
  end
  if type(run) ~= "table" then
    return { status = "error", reason = "invalid_perf_runner_result" }
  end
  local stderr = type(run.stderr) == "string" and run.stderr or ""
  -- perf and the fixed sleep workload report diagnostics on stderr.  Do not
  -- let workload stdout spoof permission/tool/event classifications.
  local output = stderr
  if run.truncated or #stderr > self.max_output_bytes then
    return { status = "error", reason = "perf_stat_output_truncated" }
  end
  if run.status ~= "ok" or run.exit_code ~= 0 then
    local paranoid = finite_number(request.perf_event_paranoid)
      or finite_number(self.paranoid)
    local denied = run.status == "denied" or permission_error(output)
    local open_failed = event_open_failure(output) ~= nil
    local workload_issue = workload_failure(output)
    local status, reason
    if run.status == "timeout" then
      status = "error"
      reason = "perf_stat_timeout"
    elseif run.status == "cancelled" then
      status = "error"
      reason = "perf_stat_cancelled"
    elseif run.exit_code == 127 then
      status = "unavailable"
      reason = "perf_executable_not_found"
    elseif run.exit_code == 126 and trim(output) == "" then
      status = "unavailable"
      reason = "perf_executable_not_runnable"
    elseif workload_issue == "missing" then
      status = "unavailable"
      reason = "sleep_executable_not_found"
    elseif workload_issue == "not_executable" then
      status = "unavailable"
      reason = "sleep_executable_not_runnable"
    elseif workload_issue then
      status = "error"
      reason = "sleep_workload_failed"
    elseif denied then
      status = "denied"
      reason = "perf_event_permission_denied"
    elseif unsupported_event_error(output) then
      status = "unavailable"
      reason = "memory_events_not_supported"
    elseif open_failed then
      status = "unavailable"
      reason = "memory_event_open_failed"
    elseif run.status == "unavailable" then
      status = "unavailable"
      reason = run.reason or "perf_runner_unavailable"
    else
      status = "error"
      reason = run.reason or "perf_stat_failed"
    end
    return {
      status = status,
      reason = reason,
      details = {
        exit_code = run.exit_code,
        status = run.status,
        perf_event_paranoid = paranoid,
        permission_may_be_required = paranoid ~= nil and paranoid >= 1 and open_failed or false,
      },
    }
  end
  -- perf stat writes its own CSV stream to stderr.  The workload's stdout is
  -- deliberately excluded so it cannot spoof counter rows.
  local _, unsupported, samples, issues = parse_stat(stderr, specifications, ";")
  local wall_duration_ns = finite_number(run.duration_ns)
  if not wall_duration_ns or wall_duration_ns <= 0 then
    wall_duration_ns = finished >= started and finite_number((finished + 0.0) - started)
      and ((finished + 0.0) - started) or nil
  end
  if wall_duration_ns and wall_duration_ns <= 0 then wall_duration_ns = nil end
  local read_bps, write_bps, supported, instance_count = 0.0, 0.0, 0, 0
  local read_events, write_events, duration_ns = 0, 0, 0
  local multiplexed, running_percent_missing, incomplete_instances = false, false, false
  for _, specification in ipairs(specifications) do
    local valid_instances = 0
    for _, sample in ipairs(samples[specification.label] or {}) do
      if not sample.invalid then
        local multiplier = unit_bytes(sample.unit)
        if sample.unit ~= "" and not multiplier then
          issues[specification.label] = "unsupported_perf_unit"
        else
          multiplier = multiplier or specification.bytes_per_count
          local runtime_ns = sample.runtime_ns
          local percent = sample.running_percent
          if not percent then running_percent_missing = true end
          if percent and (percent <= 0 or percent > 100.01) then
            issues[specification.label] = "invalid_running_percent"
          else
            if percent and percent < 99.995 then multiplexed = true end
            local transferred = sample.count * (multiplier + 0.0)
            local bps = transferred * 1000000000.0 / runtime_ns
            local current = specification.direction == "read" and read_bps or write_bps
            if transferred == transferred and transferred >= 0 and transferred < math.huge
                and bps == bps and bps >= 0 and bps < math.huge
                and current + bps < math.huge then
              if specification.direction == "read" then
                read_bps = read_bps + bps
              else
                write_bps = write_bps + bps
              end
              valid_instances = valid_instances + 1
              instance_count = instance_count + 1
              duration_ns = math.max(duration_ns, runtime_ns)
            else
              issues[specification.label] = "counter_value_out_of_range"
            end
          end
        end
      end
    end
    if valid_instances > 0 then
      supported = supported + 1
      if specification.direction == "read" then
        read_events = read_events + 1
      else
        write_events = write_events + 1
      end
      local expected = specification.expected_instance_count
      if (expected and valid_instances ~= expected)
          or unsupported[specification.label] or issues[specification.label] then
        incomplete_instances = true
      end
    end
  end
  if supported == 0 then
    local reason = next(unsupported) and "memory_events_not_supported" or nil
    if not reason then
      for _, issue in pairs(issues) do
        if issue == "not_counted" then
          reason = "memory_events_not_counted"
          break
        end
        reason = "perf_stat_invalid_counts"
      end
    end
    return {
      status = "unavailable",
      reason = reason or "perf_stat_missing_counts",
    }
  end
  duration_ns = math.max(1, duration_ns)
  local measured_read_bps = read_events > 0 and read_bps or nil
  local measured_write_bps = write_events > 0 and write_bps or nil
  local read_bytes = measured_read_bps and measured_read_bps * duration_ns / 1000000000.0 or nil
  local write_bytes = measured_write_bps and measured_write_bps * duration_ns / 1000000000.0 or nil
  if (read_bytes ~= nil and not finite_number(read_bytes))
      or (write_bytes ~= nil and not finite_number(write_bytes)) then
    return { status = "error", reason = "perf_counter_value_out_of_range" }
  end
  return {
    status = "ok",
    provider = "perf_stat",
    read_bytes = read_bytes,
    write_bytes = write_bytes,
    read_bytes_per_second = measured_read_bps,
    write_bytes_per_second = measured_write_bps,
    duration_ns = duration_ns,
    wall_duration_ns = wall_duration_ns,
    formula_version = "perf-stat-csv-no-aggr-v4",
    event_count = supported,
    instance_count = instance_count,
    read_event_count = read_events,
    write_event_count = write_events,
    requested_event_count = #specifications,
    eligible_event_count = eligible_event_count,
    alternative_event_count = alternative_event_count,
    selected_event_family = selected_event_family,
    events_truncated = events_truncated,
    estimated = supported < #specifications or read_events == 0 or write_events == 0
      or events_truncated or multiplexed or running_percent_missing or incomplete_instances,
  }
end

PerfBandwidth.parse_stat = parse_stat
PerfBandwidth.direction_for = direction_for
PerfBandwidth.bytes_per_count = bytes_per_count
PerfBandwidth.unit_bytes = unit_bytes
PerfBandwidth.safe_identifier = safe_identifier

return PerfBandwidth
