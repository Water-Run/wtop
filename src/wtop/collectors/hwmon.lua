local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local Hwmon = {}
Hwmon.__index = Hwmon

local SENSOR_SPECS = {
  temp = {
    kind = "temperature", order = 1, unit = "celsius", scale = 1000,
    thresholds = {
      min = true, max = true, crit = true, lcrit = true, emergency = true,
      min_hyst = true, max_hyst = true, crit_hyst = true, lcrit_hyst = true,
      emergency_hyst = true,
    },
    readings = { input = true, lowest = true, highest = true, offset = true },
  },
  fan = {
    kind = "fan", order = 2, unit = "rpm", scale = 1,
    thresholds = { min = true, max = true },
    readings = { input = true, target = true },
  },
  power = {
    kind = "power", order = 3, unit = "watts", scale = 1000000,
    thresholds = { min = true, max = true, crit = true, cap = true, cap_hyst = true },
    readings = { input = true, average = true },
  },
  ["in"] = {
    kind = "voltage", order = 4, unit = "volts", scale = 1000,
    thresholds = { min = true, max = true, crit = true, lcrit = true },
    readings = { input = true },
  },
  curr = {
    kind = "current", order = 5, unit = "amperes", scale = 1000,
    thresholds = { min = true, max = true, crit = true, lcrit = true },
    readings = { input = true, average = true },
  },
  energy = {
    kind = "energy", order = 6, unit = "joules", scale = 1000000,
    thresholds = {},
    readings = { input = true },
  },
}

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
    return nil, { kind = "too_large", message = "file_exceeds_limit", path = path, limit = limit }
  end
  return content
end

local function safe_text(content)
  local value = Common.trim(content)
  if not value or value == "" then
    return nil
  end
  value = value:gsub("[%z\1-\31\127]", "�")
  if not utf8.len(value) then
    local output, index = {}, 1
    while index <= #value do
      local byte = value:byte(index)
      local length = byte < 0x80 and 1
        or (byte >= 0xc2 and byte <= 0xdf and 2)
        or (byte >= 0xe0 and byte <= 0xef and 3)
        or (byte >= 0xf0 and byte <= 0xf4 and 4)
      local candidate = length and value:sub(index, index + length - 1) or nil
      if candidate and #candidate == length and utf8.len(candidate) == 1 then
        output[#output + 1] = candidate
        index = index + length
      else
        output[#output + 1] = "�"
        index = index + 1
      end
    end
    value = table.concat(output)
  end
  return value
end

local function optional_text(fs, path, limit, errors, key)
  local content, err = read_limited(fs, path, limit)
  if not content then
    if errors and not is_optional_absence(err) then
      errors[key] = error_record(err, path)
    end
    return nil
  end
  local value = safe_text(content)
  if not value and errors then
    errors[key] = error_record({ kind = "parse_error", message = "empty_value" }, path)
  end
  return value
end

local function normalized_number(fs, path, scale, maximum_abs_raw)
  local content, err = read_limited(fs, path, 256)
  if not content then
    return nil, err
  end
  local token = Common.trim(content)
  if not token or not token:match("^[+-]?%d+$") then
    return nil, { kind = "parse_error", message = "expected_integer", path = path }
  end
  local raw = tonumber(token)
  if not raw or raw > maximum_abs_raw or raw < -maximum_abs_raw then
    return nil, { kind = "parse_error", message = "number_out_of_range", path = path }
  end
  return raw / scale
end

local function plausible_sensor_value(spec, value)
  -- NVMe and several firmware-backed hwmon drivers expose their protocol
  -- sentinels as -273.15 C or roughly 65,000 C. They are not measurements or
  -- useful thresholds and must not dominate tables and alert calculations.
  if spec.kind == "temperature" and (value <= -200 or value >= 1000) then
    return false
  end
  return true
end

local function boolean_number(fs, path)
  local value, err = normalized_number(fs, path, 1, 1)
  if value == nil then
    return nil, err
  end
  return value ~= 0
end

local function normalize_target(target)
  if type(target) ~= "string" then
    return nil
  end
  target = Common.trim(target)
  if target == "" then
    return nil
  end
  target = target:gsub("/+", "/"):gsub("/%./", "/"):gsub("/$", "")
  return target ~= "" and target or nil
end

local function has_entries(value)
  return next(value) ~= nil
end

function Hwmon.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Hwmon options must be a table", 2) end
  return setmetatable({
    id = "hwmon",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/class/hwmon"),
    max_devices = bounded_integer("max_devices", options.max_devices, 128, 1, 4096),
    max_class_entries = bounded_integer(
      "max_class_entries", options.max_class_entries, 4096, 1, 65536),
    max_entries_per_device = bounded_integer(
      "max_entries_per_device", options.max_entries_per_device, 1024, 1, 65536),
    max_channels_per_device = bounded_integer(
      "max_channels_per_device", options.max_channels_per_device, 256, 1, 16384),
    max_channel_index = bounded_integer(
      "max_channel_index", options.max_channel_index, 4096, 1, 1048576),
    max_text_bytes = bounded_integer("max_text_bytes", options.max_text_bytes, 4096, 1, 1048576),
    max_abs_raw_value = bounded_integer(
      "max_abs_raw_value", options.max_abs_raw_value, 9000000000000000, 1,
      9007199254740991),
    _method_style = true,
  }, Hwmon)
end

local function device_entries(fs, base_path, max_class_entries)
  local entries, err, directory_truncated = fs:list(base_path, max_class_entries + 1)
  if not entries then
    return nil, err
  end
  local devices = {}
  local truncated = directory_truncated == true
  for index, entry in ipairs(entries) do
    if index > max_class_entries then
      truncated = true
      break
    end
    local number = entry:match("^hwmon(%d+)$")
    if number then
      devices[#devices + 1] = { name = entry, number = tonumber(number) }
    end
  end
  table.sort(devices, function(left, right)
    if left.number == right.number then
      return left.name < right.name
    end
    return left.number < right.number
  end)
  return devices, nil, truncated
end

function Hwmon:probe(context)
  local fs = Common.fs(context, self.fs)
  local entries, err = device_entries(fs, self.base_path, self.max_class_entries)
  if not entries then
    local status = FS.error_status(err)
    if status == "denied" then
      return Capability.denied(err.message, { source = self.base_path })
    end
    return Capability.unavailable(err and err.message or "hwmon_unavailable", { source = self.base_path })
  end
  if #entries == 0 then
    return Capability.unavailable("no_hwmon_devices", { source = self.base_path })
  end
  return Capability.available({ source = self.base_path, details = { devices = #entries } })
end

local function discover_channels(entries, options)
  local groups = {}
  local count = 0
  local truncated = false
  for entry_index, filename in ipairs(entries) do
    if entry_index > options.max_entries_per_device then
      truncated = true
      break
    end
    local prefix, number_text, attribute = filename:match("^([a-z]+)(%d+)_([%w_]+)$")
    local spec = prefix and SENSOR_SPECS[prefix]
    local number = tonumber(number_text)
    local recognized = spec and (attribute == "label" or attribute == "alarm" or attribute == "fault"
      or spec.thresholds[attribute] or spec.readings[attribute])
    if recognized and number and number >= 1 and number <= options.max_channel_index then
      local key = prefix .. ":" .. tostring(number)
      local group = groups[key]
      if not group then
        if count >= options.max_channels_per_device then
          truncated = true
        else
          group = { prefix = prefix, number = number, files = {} }
          groups[key] = group
          count = count + 1
        end
      end
      if group then
        group.files[attribute] = filename
      end
    end
  end
  local ordered = {}
  for _, group in pairs(groups) do
    ordered[#ordered + 1] = group
  end
  table.sort(ordered, function(left, right)
    local left_order = SENSOR_SPECS[left.prefix].order
    local right_order = SENSOR_SPECS[right.prefix].order
    if left_order == right_order then
      return left.number < right.number
    end
    return left_order < right_order
  end)
  return ordered, truncated
end

local function read_channel(fs, base, group, options)
  local spec = SENSOR_SPECS[group.prefix]
  local local_id = spec.kind .. ":" .. tostring(group.number)
  local channel = {
    id = local_id,
    type = spec.kind,
    index = group.number,
    unit = spec.unit,
    label = nil,
    input = nil,
    readings = {},
    thresholds = {},
    alarm = nil,
    fault = nil,
    errors = {},
    source = base,
  }

  for attribute, filename in pairs(group.files) do
    local path = base .. "/" .. filename
    if attribute == "label" then
      channel.label = optional_text(fs, path, options.max_text_bytes, channel.errors, attribute)
    elseif attribute == "alarm" or attribute == "fault" then
      local value, err = boolean_number(fs, path)
      if value == nil then
        channel.errors[attribute] = error_record(err, path)
      else
        channel[attribute] = value
      end
    else
      local value, err = normalized_number(fs, path, spec.scale, options.max_abs_raw_value)
      if value ~= nil and not plausible_sensor_value(spec, value) then
        value = nil
        err = { kind = "parse_error", message = "implausible_sensor_value", path = path }
      end
      if value == nil then
        channel.errors[attribute] = error_record(err, path)
      elseif spec.thresholds[attribute] then
        channel.thresholds[attribute] = value
      else
        channel.readings[attribute] = value
        if attribute == "input" then
          channel.input = value
        end
      end
    end
  end

  if has_entries(channel.errors) then
    channel.quality = "partial"
  elseif channel.input ~= nil then
    channel.quality = "fresh"
  elseif channel.readings.average ~= nil then
    channel.input = channel.readings.average
    channel.quality = "estimated"
    channel.input_source = "average"
  else
    channel.quality = "unavailable"
  end
  return channel
end

local function read_device(self, fs, entry, used_ids)
  local base = self.base_path .. "/" .. entry.name
  local errors = {}
  local name = optional_text(fs, base .. "/name", self.max_text_bytes, errors, "name")
  local target, target_error = fs:readlink(base .. "/device")
  target = normalize_target(target)
  if not target and target_error and not is_optional_absence(target_error) then
    errors.device = error_record(target_error, base .. "/device")
  end

  local identity_quality = name and target and "fresh" or "estimated"
  local identity_name = name or "unknown"
  local id = target and (identity_name .. "@" .. target) or (identity_name .. "@class:" .. entry.name)
  if used_ids[id] then
    errors.identity = {
      status = "error",
      reason = "identity_collision",
      source = base,
    }
    id = id .. "#" .. entry.name
    identity_quality = "estimated"
  end
  used_ids[id] = true

  local entries, list_error, directory_truncated = fs:list(base, self.max_entries_per_device + 1)
  local groups = {}
  local channels_truncated = directory_truncated == true
  if entries then
    local discovered_truncated
    groups, discovered_truncated = discover_channels(entries, self)
    channels_truncated = channels_truncated or discovered_truncated
  else
    errors.channels = error_record(list_error, base, "channel_enumeration_failed")
  end
  if channels_truncated then
    errors.channel_limit = {
      status = "error",
      reason = "channel_enumeration_truncated",
      source = base,
    }
  end

  local channels = {}
  local by_id = {}
  local counts = {}
  local any_partial = has_entries(errors)
  local any_estimated = false
  for _, group in ipairs(groups) do
    local channel = read_channel(fs, base, group, self)
    channels[#channels + 1] = channel
    by_id[channel.id] = channel
    counts[channel.type] = (counts[channel.type] or 0) + 1
    any_partial = any_partial or channel.quality == "partial" or channel.quality == "unavailable"
    any_estimated = any_estimated or channel.quality == "estimated"
  end

  local quality
  if any_partial then
    quality = "partial"
  elseif identity_quality == "estimated" or any_estimated then
    quality = "estimated"
  else
    quality = "fresh"
  end
  return {
    id = id,
    class = entry.name,
    class_index = entry.number,
    name = name,
    device_target = target,
    identity_quality = identity_quality,
    quality = quality,
    channels = channels,
    by_id = by_id,
    channel_counts = counts,
    truncated = channels_truncated,
    errors = errors,
    source = base,
  }
end

function Hwmon:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local entries, list_error, class_truncated = device_entries(fs, self.base_path, self.max_class_entries)
  if not entries then
    return Common.error_result(list_error, Common.now_ns(context), self.base_path)
  end
  if #entries == 0 then
    local finished = Common.now_ns(context)
    return Common.result("unavailable", finished, nil, {
      quality = "unavailable",
      reason = "no_hwmon_devices",
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.base_path,
    })
  end

  local truncated = class_truncated or #entries > self.max_devices
  local devices = {}
  local by_id = {}
  local used_ids = {}
  local any_partial = truncated
  local any_estimated = false
  for index = 1, math.min(#entries, self.max_devices) do
    local device = read_device(self, fs, entries[index], used_ids)
    devices[#devices + 1] = device
    by_id[device.id] = device
    any_partial = any_partial or device.quality == "partial"
    any_estimated = any_estimated or device.quality == "estimated"
  end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, {
    devices = devices,
    by_id = by_id,
    truncated = truncated,
  }, {
    quality = any_partial and "partial" or (any_estimated and "estimated" or "fresh"),
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = self.base_path,
  })
end

Hwmon.sensor_specs = SENSOR_SPECS
Hwmon.normalize_target = normalize_target
Hwmon.plausible_sensor_value = plausible_sensor_value

return Hwmon
