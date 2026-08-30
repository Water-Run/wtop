local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local CPUFreq = {}
CPUFreq.__index = CPUFreq

local TEXT_LIMIT = 4096
local CPU_LIST_LIMIT = 65536

local function bounded_integer(name, value, default, minimum, maximum)
  if value == nil then return default end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
      or value % 1 ~= 0 or value < minimum or value > maximum then
    error(name .. " must be an integer in " .. minimum .. ".." .. maximum, 3)
  end
  return value
end

local function error_record(err, path, fallback)
  return {
    status = FS.error_status(err),
    reason = err and err.message or fallback or "read_failed",
    source = path,
  }
end

local function is_optional_absence(err)
  return err and (err.kind == "missing" or err.kind == "unavailable")
end

local function read_limited(fs, path, limit)
  local content, err = fs:read(path, limit)
  if not content then
    return nil, err
  end
  if #content > limit then
    return nil, {
      kind = "too_large",
      message = "file_exceeds_limit",
      path = path,
      limit = limit,
    }
  end
  return content
end

local function optional_text(fs, path, errors, key, limit)
  local content, err = read_limited(fs, path, limit or TEXT_LIMIT)
  if not content then
    if not is_optional_absence(err) then
      errors[key] = error_record(err, path)
    end
    return nil
  end
  local value = Common.trim(content)
  if value == "" then
    errors[key] = error_record({ kind = "parse_error", message = "empty_value" }, path)
    return nil
  end
  return value
end

local function optional_number(fs, path, errors, key, maximum)
  local content, err = read_limited(fs, path, 256)
  if not content then
    if not is_optional_absence(err) then
      errors[key] = error_record(err, path)
    end
    return nil
  end
  local token = Common.trim(content)
  if not token or not token:match("^%+?%d+$") then
    errors[key] = error_record({ kind = "parse_error", message = "expected_nonnegative_integer" }, path)
    return nil
  end
  local value = tonumber(token)
  if not value or value < 0 or value > maximum then
    errors[key] = error_record({ kind = "parse_error", message = "number_out_of_range" }, path)
    return nil
  end
  return value
end

local function optional_khz(fs, path, errors, key, maximum_khz)
  local value = optional_number(fs, path, errors, key, maximum_khz)
  return value and value * 1000 or nil
end

local function optional_boolean(fs, path, errors, key)
  local value = optional_text(fs, path, errors, key, 256)
  if value == nil then
    return nil
  end
  value = value:lower()
  if value == "1" or value == "yes" or value == "on" or value == "enabled" then
    return true
  end
  if value == "0" or value == "no" or value == "off" or value == "disabled" then
    return false
  end
  errors[key] = error_record({ kind = "parse_error", message = "expected_boolean" }, path)
  return nil
end

local function parse_cpu_list(content, maximum_cpus, maximum_cpu_id)
  content = Common.trim(content)
  if not content or content == "" then
    return nil, "empty_cpu_list"
  end
  local seen = {}
  local cpus = {}
  content = content:gsub(",", " ")
  for token in content:gmatch("%S+") do
    local first, last = token:match("^(%d+)%-(%d+)$")
    if not first then
      first = token:match("^(%d+)$")
      last = first
    end
    first, last = tonumber(first), tonumber(last)
    if not first or not last or first > last or last > maximum_cpu_id then
      return nil, "invalid_cpu_list"
    end
    if last - first + 1 > maximum_cpus or #cpus + (last - first + 1) > maximum_cpus then
      return nil, "cpu_list_exceeds_limit"
    end
    for cpu = first, last do
      if not seen[cpu] then
        seen[cpu] = true
        cpus[#cpus + 1] = cpu
      end
    end
  end
  if #cpus == 0 then
    return nil, "empty_cpu_list"
  end
  table.sort(cpus)
  return cpus
end

local function optional_cpu_list(fs, path, errors, key, maximum_cpus, maximum_cpu_id)
  local content, err = read_limited(fs, path, CPU_LIST_LIMIT)
  if not content then
    if not is_optional_absence(err) then
      errors[key] = error_record(err, path)
    end
    return nil
  end
  local cpus, reason = parse_cpu_list(content, maximum_cpus, maximum_cpu_id)
  if not cpus then
    errors[key] = error_record({ kind = "parse_error", message = reason }, path)
  end
  return cpus
end

local function cpu_identity(cpus)
  if not cpus then
    return nil
  end
  local values = {}
  for index, cpu in ipairs(cpus) do
    values[index] = tostring(cpu)
  end
  return "cpus:" .. table.concat(values, ",")
end

local function has_entries(value)
  return next(value) ~= nil
end

local function boost_value(enabled, source)
  if enabled == nil then
    return nil
  end
  return {
    enabled = enabled,
    quality = "fresh",
    source = source,
  }
end

function CPUFreq.new(options)
  options = options or {}
  if type(options) ~= "table" then error("CPUFreq options must be a table", 2) end
  return setmetatable({
    id = "cpufreq",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    fs = options.fs or FS.default,
    base_path = Common.absolute_path(
      "base_path", options.base_path, "/sys/devices/system/cpu/cpufreq"),
    max_policies = bounded_integer("max_policies", options.max_policies, 1024, 1, 65536),
    max_class_entries = bounded_integer(
      "max_class_entries", options.max_class_entries, 4096, 1, 65536),
    max_cpus_per_policy = bounded_integer(
      "max_cpus_per_policy", options.max_cpus_per_policy, 4096, 1, 1048576),
    max_cpu_id = bounded_integer("max_cpu_id", options.max_cpu_id, 1048575, 0, 2147483647),
    max_frequency_khz = bounded_integer(
      "max_frequency_khz", options.max_frequency_khz, 1000000000, 1,
      math.maxinteger // 1000),
    _method_style = true,
  }, CPUFreq)
end

local function policy_entries(fs, base_path, max_class_entries)
  local entries, err, directory_truncated = fs:list(base_path, max_class_entries + 1)
  if not entries then
    return nil, err
  end
  local policies = {}
  local truncated = directory_truncated == true
  for index, entry in ipairs(entries) do
    if index > max_class_entries then
      truncated = true
      break
    end
    local number = entry:match("^policy(%d+)$")
    if number then
      policies[#policies + 1] = { name = entry, number = tonumber(number) }
    end
  end
  table.sort(policies, function(left, right)
    if left.number == right.number then
      return left.name < right.name
    end
    return left.number < right.number
  end)
  return policies, nil, truncated
end

function CPUFreq:probe(context)
  local fs = Common.fs(context, self.fs)
  local entries, err = policy_entries(fs, self.base_path, self.max_class_entries)
  if not entries then
    local status = FS.error_status(err)
    if status == "denied" then
      return Capability.denied(err.message, { source = self.base_path })
    end
    return Capability.unavailable(err and err.message or "cpufreq_unavailable", { source = self.base_path })
  end
  if #entries == 0 then
    return Capability.unavailable("no_cpufreq_policies", { source = self.base_path })
  end
  return Capability.available({ source = self.base_path, details = { policies = #entries } })
end

function CPUFreq:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local entries, list_error, class_truncated = policy_entries(fs, self.base_path, self.max_class_entries)
  if not entries then
    return Common.error_result(list_error, Common.now_ns(context), self.base_path)
  end
  if #entries == 0 then
    local finished = Common.now_ns(context)
    return Common.result("unavailable", finished, nil, {
      quality = "unavailable",
      reason = "no_cpufreq_policies",
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.base_path,
    })
  end

  local policies = {}
  local by_id = {}
  local duplicates_skipped = 0
  local truncated = class_truncated or #entries > self.max_policies
  local any_partial = truncated
  local any_estimated = false

  for entry_index = 1, math.min(#entries, self.max_policies) do
    local entry = entries[entry_index]
    local path = self.base_path .. "/" .. entry.name
    local errors = {}
    local affected = optional_cpu_list(fs, path .. "/affected_cpus", errors, "affected_cpus",
      self.max_cpus_per_policy, self.max_cpu_id)
    local related = optional_cpu_list(fs, path .. "/related_cpus", errors, "related_cpus",
      self.max_cpus_per_policy, self.max_cpu_id)
    local identity_cpus = related or affected
    local id = cpu_identity(identity_cpus) or ("policy:" .. tostring(entry.number))
    local identity_quality = identity_cpus and "fresh" or "estimated"

    if by_id[id] then
      duplicates_skipped = duplicates_skipped + 1
      any_partial = true
    else
      local frequencies = {
        scaling_current_hz = optional_khz(fs, path .. "/scaling_cur_freq", errors,
          "scaling_cur_freq", self.max_frequency_khz),
        scaling_minimum_hz = optional_khz(fs, path .. "/scaling_min_freq", errors,
          "scaling_min_freq", self.max_frequency_khz),
        scaling_maximum_hz = optional_khz(fs, path .. "/scaling_max_freq", errors,
          "scaling_max_freq", self.max_frequency_khz),
        hardware_current_hz = optional_khz(fs, path .. "/cpuinfo_cur_freq", errors,
          "cpuinfo_cur_freq", self.max_frequency_khz),
        hardware_minimum_hz = optional_khz(fs, path .. "/cpuinfo_min_freq", errors,
          "cpuinfo_min_freq", self.max_frequency_khz),
        hardware_maximum_hz = optional_khz(fs, path .. "/cpuinfo_max_freq", errors,
          "cpuinfo_max_freq", self.max_frequency_khz),
        bios_limit_hz = optional_khz(fs, path .. "/bios_limit", errors,
          "bios_limit", self.max_frequency_khz),
      }
      if frequencies.hardware_current_hz then
        frequencies.current_hz = frequencies.hardware_current_hz
        frequencies.current_quality = "measured"
        frequencies.current_source = "cpuinfo_cur_freq"
      elseif frequencies.scaling_current_hz then
        frequencies.current_hz = frequencies.scaling_current_hz
        frequencies.current_quality = "estimated"
        frequencies.current_source = "scaling_cur_freq"
        any_estimated = true
      else
        frequencies.current_quality = "unavailable"
        errors.current_frequency = {
          status = "unavailable",
          reason = "current_frequency_unavailable",
          source = path,
        }
      end

      local boost_enabled = optional_boolean(fs, path .. "/boost", errors, "boost")
      local policy = {
        id = id,
        policy = entry.name,
        policy_index = entry.number,
        affected_cpus = affected or {},
        related_cpus = related or {},
        identity_quality = identity_quality,
        driver = optional_text(fs, path .. "/scaling_driver", errors, "scaling_driver"),
        governor = optional_text(fs, path .. "/scaling_governor", errors, "scaling_governor"),
        energy_performance_preference = optional_text(fs, path .. "/energy_performance_preference",
          errors, "energy_performance_preference"),
        frequencies = frequencies,
        boost = boost_value(boost_enabled, path .. "/boost"),
        errors = errors,
        source = path,
      }
      if has_entries(errors) then
        policy.quality = "partial"
        any_partial = true
      elseif identity_quality == "estimated" or frequencies.current_quality == "estimated" then
        policy.quality = "estimated"
        any_estimated = true
      else
        policy.quality = "fresh"
      end
      policies[#policies + 1] = policy
      by_id[id] = policy
    end
  end

  local global_errors = {}
  local boost_enabled = optional_boolean(fs, self.base_path .. "/boost", global_errors, "boost")
  if has_entries(global_errors) then
    any_partial = true
  end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, {
    policies = policies,
    by_id = by_id,
    boost = boost_value(boost_enabled, self.base_path .. "/boost"),
    errors = global_errors,
    duplicates_skipped = duplicates_skipped,
    truncated = truncated,
  }, {
    quality = any_partial and "partial" or (any_estimated and "estimated" or "fresh"),
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = self.base_path,
  })
end

CPUFreq.parse_cpu_list = parse_cpu_list

return CPUFreq
