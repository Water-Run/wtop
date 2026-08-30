local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local Powercap = {}
Powercap.__index = Powercap

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

local function optional_text(fs, path, issues, field, options)
  local content, err = fs:read(path, options.max_text_bytes)
  if not content then
    if not optional_absence(err) then add_issue(issues, field, err, path, options.max_issues) end
    return nil
  end
  local value = Common.safe_text(Common.trim(content), options.max_text_bytes)
  if not value or value == "" then
    add_issue(issues, field, { kind = "parse_error", message = "empty_value" }, path,
      options.max_issues)
    return nil
  end
  return value
end

local function optional_integer(fs, path, issues, field, options, maximum)
  local content, err = fs:read(path, 256)
  if not content then
    if not optional_absence(err) then add_issue(issues, field, err, path, options.max_issues) end
    return nil, err
  end
  local token = Common.trim(content)
  if type(token) ~= "string" or not token:match("^%d+$") then
    local parse_error = { kind = "parse_error", message = "expected_nonnegative_integer" }
    add_issue(issues, field, parse_error, path, options.max_issues)
    return nil, parse_error
  end
  local value = tonumber(token)
  if not value or math.type(value) ~= "integer" or value < 0 or (maximum and value > maximum) then
    local range_error = { kind = "parse_error", message = "number_out_of_range" }
    add_issue(issues, field, range_error, path, options.max_issues)
    return nil, range_error
  end
  return value
end

local function zone_entries(fs, base_path, maximum)
  local entries, err, directory_truncated = fs:list(base_path, maximum + 1)
  if not entries then return nil, err end
  local result, truncated = {}, directory_truncated == true or #entries > maximum
  for index = 1, math.min(#entries, maximum) do
    local entry = entries[index]
    -- Control-type directories do not have a colon and expose no zone name.
    -- Other powercap drivers may use a different prefix, so the colon is the
    -- only naming convention used here.
    if entry:find(":", 1, true) then result[#result + 1] = entry end
  end
  table.sort(result)
  return result, nil, truncated
end

local CONSTRAINT_ATTRIBUTES = {
  name = "name",
  power_limit_uw = "power_limit_uw",
  max_power_uw = "max_power_uw",
  min_power_uw = "min_power_uw",
  time_window_us = "time_window_us",
  max_time_window_us = "max_time_window_us",
  min_time_window_us = "min_time_window_us",
}

local function constraints(self, fs, base, entries, issues)
  local indexes = {}
  for _, entry in ipairs(entries or {}) do
    local index, attribute = entry:match("^constraint_(%d+)_([%w_]+)$")
    if index and CONSTRAINT_ATTRIBUTES[attribute] then indexes[tonumber(index)] = true end
  end
  local ordered = {}
  for index in pairs(indexes) do ordered[#ordered + 1] = index end
  table.sort(ordered)
  local result, truncated = {}, #ordered > self.max_constraints_per_zone
  for item = 1, math.min(#ordered, self.max_constraints_per_zone) do
    local index = ordered[item]
    local prefix = base .. "/constraint_" .. tostring(index) .. "_"
    local constraint = {
      id = index,
      name = optional_text(fs, prefix .. "name", issues, "constraint.name", self),
      power_limit_watts = nil,
      maximum_power_watts = nil,
      minimum_power_watts = nil,
      time_window_seconds = nil,
      maximum_time_window_seconds = nil,
      minimum_time_window_seconds = nil,
      source = base,
    }
    local limit = optional_integer(fs, prefix .. "power_limit_uw", issues,
      "constraint.power_limit", self)
    local maximum = optional_integer(fs, prefix .. "max_power_uw", issues,
      "constraint.maximum_power", self)
    local minimum = optional_integer(fs, prefix .. "min_power_uw", issues,
      "constraint.minimum_power", self)
    local window = optional_integer(fs, prefix .. "time_window_us", issues,
      "constraint.time_window", self)
    local maximum_window = optional_integer(fs, prefix .. "max_time_window_us", issues,
      "constraint.maximum_time_window", self)
    local minimum_window = optional_integer(fs, prefix .. "min_time_window_us", issues,
      "constraint.minimum_time_window", self)
    constraint.power_limit_watts = limit and limit / 1000000 or nil
    constraint.maximum_power_watts = maximum and maximum / 1000000 or nil
    constraint.minimum_power_watts = minimum and minimum / 1000000 or nil
    constraint.time_window_seconds = window and window / 1000000 or nil
    constraint.maximum_time_window_seconds = maximum_window and maximum_window / 1000000 or nil
    constraint.minimum_time_window_seconds = minimum_window and minimum_window / 1000000 or nil
    result[#result + 1] = constraint
  end
  return result, truncated
end

local function source_kind(entry)
  return entry:match("^([^:]+)") or entry
end

local function parent_id(entry, available)
  local candidate = entry:match("^(.*):[^:]+$")
  while candidate do
    if available[candidate] then return candidate end
    candidate = candidate:match("^(.*):[^:]+$")
  end
end

local function normalized_zone_name(name)
  return tostring(name or ""):lower():gsub("[%s_]+", "-")
end

local function aggregate_domain(name)
  local normalized = normalized_zone_name(name)
  if normalized == "package" or normalized == "socket"
      or normalized == "cpu" or normalized == "cpu-package"
      or normalized:match("^package%-?%d+$") or normalized:match("^socket%-?%d+$")
      or normalized:match("^cpu%-?%d+$") then
    return "cpu_package"
  end
  if normalized == "psys" or normalized == "platform"
      or normalized == "system" or normalized == "system-power" then
    return "platform"
  end
  return "other"
end

local function backend_cohort(source)
  local normalized = tostring(source or "unknown"):lower():gsub("_", "-")
  -- Intel commonly exposes the same RAPL domains through MSR and MMIO
  -- control types. Treat those as parallel backends and choose one tree.
  return normalized:gsub("%-mmio$", "")
end

local function energy_delta(current, previous, maximum_range)
  if not finite_number(current) or not finite_number(previous) then return nil, "gap" end
  if current >= previous then return current - previous, "measured" end
  if finite_number(maximum_range) and maximum_range > 0
      and previous <= maximum_range and current <= maximum_range
      and previous >= maximum_range * 0.5 and current <= maximum_range * 0.5 then
    return (maximum_range - previous) + current, "wrapped"
  end
  return nil, "reset"
end

local function read_zone(self, fs, entry, entries, previous, now_ns)
  local base = self.base_path .. "/" .. entry
  local issues = {}
  local listed, list_error, list_truncated = fs:list(base, self.max_zone_entries + 1)
  if not listed then
    if not optional_absence(list_error) then
      add_issue(issues, "directory", list_error, base, self.max_issues)
    end
    listed = {}
  end
  local name = optional_text(fs, base .. "/name", issues, "name", self)
  if not name then return nil, issues end
  local energy, energy_error = optional_integer(fs, base .. "/energy_uj", issues,
    "energy", self, self.max_counter_value)
  local maximum_range = optional_integer(fs, base .. "/max_energy_range_uj", issues,
    "maximum_energy_range", self, self.max_counter_value)
  local direct_power = optional_integer(fs, base .. "/power_uw", issues,
    "power", self, self.max_counter_value)
  local enabled = optional_integer(fs, base .. "/enabled", issues,
    "enabled", self, 1)
  local zone_constraints, constraints_truncated = constraints(self, fs, base, listed, issues)
  local zone = {
    id = entry,
    name = name,
    source_kind = source_kind(entry),
    parent_id = parent_id(entry, entries),
    enabled = enabled == nil and nil or enabled == 1,
    energy_joules = energy and energy / 1000000 or nil,
    energy_uj = energy,
    maximum_energy_range_joules = maximum_range and maximum_range / 1000000 or nil,
    maximum_energy_range_uj = maximum_range,
    observed_at_ns = now_ns,
    power_watts = direct_power and direct_power / 1000000 or nil,
    power_source = direct_power and "power_uw" or nil,
    power_quality = direct_power and "measured" or "gap",
    constraints = zone_constraints,
    issues = issues,
    truncated = list_truncated == true or #listed > self.max_zone_entries or constraints_truncated,
    source = base,
  }
  local previous_zone = previous and previous.by_id and previous.by_id[entry]
  if not zone.power_watts and energy and previous_zone and previous_zone.energy_uj then
    local elapsed_ns = Common.elapsed_ns(now_ns, previous_zone.observed_at_ns)
    local delta, delta_quality = energy_delta(energy, previous_zone.energy_uj,
      maximum_range or previous_zone.maximum_energy_range_uj)
    if delta and elapsed_ns and elapsed_ns > 0 then
      local watts = (delta + 0.0) * 1000 / elapsed_ns
      if finite_number(watts) and watts >= 0 and watts <= self.max_power_watts then
        zone.power_watts = watts
        zone.power_source = "energy_delta"
        zone.power_quality = delta_quality
      else
        zone.power_quality = "reset"
      end
    else
      zone.power_quality = delta_quality
    end
  elseif not energy and energy_error and energy_error.kind == "denied" then
    zone.power_quality = "denied"
  end
  zone.quality = (#issues > 0 or zone.truncated) and "partial" or "fresh"
  return zone, issues
end

function Powercap.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Powercap options must be a table", 2) end
  return setmetatable({
    id = "powercap",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/class/powercap"),
    max_class_entries = bounded_integer(
      "max_class_entries", options.max_class_entries, 1024, 1, 65536),
    max_zone_entries = bounded_integer(
      "max_zone_entries", options.max_zone_entries, 256, 1, 65536),
    max_constraints_per_zone = bounded_integer(
      "max_constraints_per_zone", options.max_constraints_per_zone, 64, 1, 4096),
    max_text_bytes = bounded_integer("max_text_bytes", options.max_text_bytes, 4096, 1, 1048576),
    max_issues = bounded_integer("max_issues", options.max_issues, 128, 1, 4096),
    max_counter_value = bounded_integer("max_counter_value", options.max_counter_value,
      9007199254740991, 1, 9007199254740991),
    max_power_watts = bounded_integer("max_power_watts", options.max_power_watts,
      1000000, 1, 1000000000),
    _method_style = true,
  }, Powercap)
end

function Powercap:probe(context)
  local fs = Common.fs(context, self.fs)
  local entries, err, truncated = zone_entries(fs, self.base_path, self.max_class_entries)
  if not entries then
    local status = FS.error_status(err)
    if status == "denied" then return Capability.denied(err.message, { source = self.base_path }) end
    return Capability.unavailable(err and err.message or "powercap_unavailable",
      { source = self.base_path })
  end
  if #entries == 0 then
    return Capability.unavailable("no_powercap_zones", { source = self.base_path })
  end
  return Capability.available({ source = self.base_path,
    details = { zones = #entries, truncated = truncated == true } })
end

function Powercap:sample(context, previous)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local entries, err, class_truncated = zone_entries(fs, self.base_path, self.max_class_entries)
  if not entries then return Common.error_result(err, Common.now_ns(context), self.base_path) end
  if #entries == 0 then
    local finished = Common.now_ns(context)
    return Common.result("unavailable", finished, nil, { quality = "unavailable",
      reason = "no_powercap_zones", duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.base_path })
  end
  local now_ns = Common.now_ns(context)
  local previous_data = Common.previous_data(previous)
  local entry_set = {}
  for _, entry in ipairs(entries) do entry_set[entry] = true end
  local zones, by_id, all_issues = {}, {}, {}
  local truncated, partial, denied = class_truncated == true, false, 0
  for _, entry in ipairs(entries) do
    local zone, issues = read_zone(self, fs, entry, entry_set, previous_data, now_ns)
    if zone then
      zones[#zones + 1] = zone
      by_id[zone.id] = zone
      truncated = truncated or zone.truncated
      partial = partial or zone.quality == "partial"
      if zone.power_quality == "denied" then denied = denied + 1 end
    end
    for _, issue in ipairs(issues or {}) do
      if #all_issues < self.max_issues then all_issues[#all_issues + 1] = issue end
    end
  end
  if #zones == 0 then
    local finished = Common.now_ns(context)
    return Common.result("unavailable", finished, nil, { quality = "unavailable",
      reason = "no_readable_powercap_zones", duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.base_path })
  end

  -- Child domains must never be added to their package. Select a complete
  -- backend tree rather than deduplicating roots by name: two sockets in the
  -- same backend may both be called "package", while an MMIO backend may
  -- mirror an MSR tree under different entry IDs.
  local cpu_cohorts, platform_roots = {}, {}
  local other_root_count = 0
  for _, zone in ipairs(zones) do
    zone.aggregate = false
    zone.platform_aggregate = false
    if not zone.parent_id then
      local domain = aggregate_domain(zone.name)
      zone.aggregate_domain = domain
      if domain == "cpu_package" then
        local cohort_id = backend_cohort(zone.source_kind)
        local cohort = cpu_cohorts[cohort_id]
        if not cohort then
          cohort = { id = cohort_id, backends = {} }
          cpu_cohorts[cohort_id] = cohort
        end
        local backend = cohort.backends[zone.source_kind]
        if not backend then
          backend = { source_kind = zone.source_kind, roots = {} }
          cohort.backends[zone.source_kind] = backend
        end
        backend.roots[#backend.roots + 1] = zone
      elseif domain == "platform" then
        platform_roots[#platform_roots + 1] = zone
      else
        other_root_count = other_root_count + 1
      end
    end
  end

  local cohort_ids = {}
  for cohort_id in pairs(cpu_cohorts) do cohort_ids[#cohort_ids + 1] = cohort_id end
  table.sort(cohort_ids)
  local selected_roots, aggregate_strategy, aggregate_source_kind = {}, nil, nil
  if #cohort_ids == 1 then
    local cohort = cpu_cohorts[cohort_ids[1]]
    local backend_names = {}
    for name in pairs(cohort.backends) do backend_names[#backend_names + 1] = name end
    table.sort(backend_names)
    local best, best_score
    for _, name in ipairs(backend_names) do
      local backend = cohort.backends[name]
      local measured_count, energy_count, denied_count = 0, 0, 0
      for _, zone in ipairs(backend.roots) do
        if finite_number(zone.power_watts) then measured_count = measured_count + 1 end
        if finite_number(zone.energy_uj) then energy_count = energy_count + 1 end
        if zone.power_quality == "denied" then denied_count = denied_count + 1 end
      end
      local score = { measured_count, energy_count, -denied_count, #backend.roots }
      local better = best_score == nil
      if not better then
        for index = 1, #score do
          if score[index] ~= best_score[index] then
            better = score[index] > best_score[index]
            break
          end
        end
      end
      if better then best, best_score = backend, score end
    end
    if best then
      selected_roots = best.roots
      aggregate_source_kind = best.source_kind
      aggregate_strategy = "cpu_package_roots"
    end
  elseif #cohort_ids > 1 then
    aggregate_strategy = "ambiguous_cpu_backends"
  end
  if not aggregate_strategy then
    aggregate_strategy = other_root_count > 0 and "unrecognized_power_roots"
      or "no_cpu_power_root"
  end

  local total_power_watts, measured = 0, 0
  for _, zone in ipairs(selected_roots) do
    zone.aggregate = true
    if finite_number(zone.power_watts) then
      total_power_watts = total_power_watts + zone.power_watts
      measured = measured + 1
    end
  end
  local aggregate_complete = #selected_roots > 0 and measured == #selected_roots

  local function platform_rank(zone)
    if finite_number(zone.power_watts) then return 3 end
    if finite_number(zone.energy_uj) then return 2 end
    if zone.power_quality == "denied" then return 0 end
    return 1
  end
  table.sort(platform_roots, function(left, right)
    local left_rank, right_rank = platform_rank(left), platform_rank(right)
    if left_rank ~= right_rank then return left_rank > right_rank end
    return left.id < right.id
  end)
  local platform_root = platform_roots[1]
  local platform_power_watts, platform_measured = nil, 0
  if platform_root then
    platform_root.platform_aggregate = true
    if finite_number(platform_root.power_watts) then
      platform_power_watts = platform_root.power_watts
      platform_measured = 1
    end
  end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, {
    schema = "dev.waterrun.wtop.powercap/v1",
    zones = zones,
    by_id = by_id,
    total_power_watts = aggregate_complete and total_power_watts or nil,
    aggregate_zone_count = #selected_roots,
    measured_aggregate_zones = measured,
    aggregate_complete = aggregate_complete,
    aggregate_strategy = aggregate_strategy,
    aggregate_source_kind = aggregate_source_kind,
    platform_power_watts = platform_power_watts,
    measured_platform_zones = platform_measured,
    platform_aggregate_strategy = #platform_roots == 0 and "no_platform_power_root"
      or (#platform_roots == 1 and "single_platform_root" or "preferred_platform_root"),
    platform_aggregate_source_kind = platform_root and platform_root.source_kind or nil,
    denied_zones = denied,
    issues = all_issues,
    truncated = truncated,
  }, {
    quality = (partial or truncated) and "partial" or "fresh",
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = self.base_path,
  })
end

Powercap.energy_delta = energy_delta
Powercap.zone_entries = zone_entries

return Powercap
