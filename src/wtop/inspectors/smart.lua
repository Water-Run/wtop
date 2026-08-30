local Capability = require("wtop.core.capability")
local Clock = require("wtop.core.clock")
local JSON = require("wtop.core.json")
local Runner = require("wtop.core.runner")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")
local Cache = require("wtop.inspectors.cache")
local Model = require("wtop.inspectors.model")

local Smart = {}
Smart.__index = Smart

local MAX_TIMEOUT_MS = 60000
local MAX_OUTPUT_BYTES = 16 * 1024 * 1024
local MAX_ATTRIBUTES = 8192

local function bounded_integer(name, value, default, minimum, maximum)
  if value == nil then return default end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
      or value % 1 ~= 0 or value < minimum or value > maximum then
    error(name .. " must be an integer in " .. minimum .. ".." .. maximum, 3)
  end
  return value
end

local function safe_absolute_path(path)
  return type(path) == "string" and #path > 1 and #path <= 4096
    and path:sub(1, 1) == "/" and not path:find("\0", 1, true)
end

local function safe_name(name)
  return type(name) == "string" and #name > 0 and #name <= 255
    and name ~= "." and name ~= ".."
    and name:match("^[A-Za-z0-9_][A-Za-z0-9_.+:%-]*$") ~= nil
end

local function safe_text(value, maximum)
  if type(value) ~= "string" then return nil end
  maximum = maximum or 4096
  value = value:gsub("[%z\1-\31\127]", "�")
  if #value > maximum then value = value:sub(1, maximum) end
  while #value > 0 and not utf8.len(value) do value = value:sub(1, -2) end
  return value ~= "" and value or nil
end

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function object(value)
  return type(value) == "table" and value or {}
end

local function scalar(value)
  if type(value) == "string" then return safe_text(value) end
  if type(value) == "number" then return finite_number(value) and value or nil end
  if type(value) == "boolean" then return value end
  return nil
end

local function now_ns(context, clock)
  return Common.now_ns(context, clock)
end

local function mask_serial(serial)
  serial = safe_text(serial)
  if not serial then
    return serial
  end
  local characters = {}
  for _, codepoint in utf8.codes(serial) do
    characters[#characters + 1] = utf8.char(codepoint)
  end
  if #characters <= 4 then return string.rep("*", #characters) end
  return string.rep("*", #characters - 4)
    .. table.concat(characters, "", #characters - 3, #characters)
end

local function safe_device_path(path)
  if not safe_absolute_path(path) or path:sub(1, 5) ~= "/dev/"
      or path:sub(-1) == "/" then
    return false
  end
  local remainder = path:sub(6)
  local count = 0
  for component in remainder:gmatch("[^/]+") do
    count = count + 1
    if not safe_name(component) then return false end
  end
  return count > 0 and not remainder:find("//", 1, true)
end

local function field(value, unit, source, timestamp, provider_version, quality, options)
  options = options or {}
  options.source = source
  options.timestamp_ns = timestamp
  options.provider = "smartctl"
  options.provider_version = provider_version
  options.quality = quality or (value == nil and "unavailable" or "fresh")
  return Model.field(value, unit, options)
end

local function explicit_device_kind(data)
  data = object(data)
  local device = object(data.device)
  local protocol = tostring(scalar(device.protocol) or ""):lower()
  local model = tostring(scalar(data.model_name) or ""):lower()
  local product = tostring(scalar(data.product) or ""):lower()
  local descriptor = model .. " " .. product
  if protocol == "nvme" or type(data.nvme_smart_health_information_log) == "table" then
    return "nvme"
  end
  if descriptor:find("sshd", 1, true) or descriptor:find("solid state hybrid", 1, true) then
    return "sshd"
  end
  if finite_number(data.rotation_rate) and data.rotation_rate == 0 then
    return "ssd"
  end
  if finite_number(data.rotation_rate) and data.rotation_rate > 0 then
    return "hdd"
  end
  return "unknown"
end

local function normalize(data, device, timestamp, source, exit_code)
  if type(data) ~= "table" or rawget(data, 1) ~= nil then
    return nil, nil, nil, "smartctl_json_root_must_be_object"
  end
  device = type(device) == "table" and device or {}
  local smartctl = object(data.smartctl)
  local device_data = object(data.device)
  local capacity = object(data.user_capacity)
  local smart_status = object(data.smart_status)
  local temperature = object(data.temperature)
  local power_on_time = object(data.power_on_time)
  local version = smartctl.version
  if type(version) == "table" then
    local parts = {}
    for index, item in ipairs(version) do
      if index > 16 then break end
      local value = scalar(item)
      if value ~= nil then parts[#parts + 1] = tostring(value) end
    end
    version = table.concat(parts, ".")
  end
  version = safe_text(version, 256) or "unknown"
  local kind = explicit_device_kind(data)
  local identity = Model.section("identity", {
    model = field(scalar(data.model_name) or scalar(data.product), nil, source, timestamp, version),
    serial = field(mask_serial(data.serial_number), nil, source, timestamp, version),
    firmware = field(scalar(data.firmware_version), nil, source, timestamp, version),
    capacity = field(scalar(capacity.bytes), "bytes", source, timestamp, version),
    protocol = field(scalar(device_data.protocol), nil, source, timestamp, version),
    kind = field(kind, nil, source, timestamp, version, kind == "unknown" and "unavailable" or "fresh"),
    rotation_rate = field(scalar(data.rotation_rate), "rpm", source, timestamp, version),
  }, { source = source })

  local health = Model.section("health", {
    passed = field(scalar(smart_status.passed), "boolean", source, timestamp, version),
    temperature = field(scalar(temperature.current), "celsius", source, timestamp, version),
    power_on_hours = field(scalar(power_on_time.hours), "hours", source, timestamp, version),
    power_cycles = field(scalar(data.power_cycle_count), "count", source, timestamp, version),
    smartctl_exit_code = field(exit_code, "bitmask", source, timestamp, version),
  }, { source = source })

  local nvme = data.nvme_smart_health_information_log
  local nvme_section
  if type(nvme) == "table" then
    nvme_section = Model.section("nvme_health", {
      critical_warning = field(scalar(nvme.critical_warning), "bitmask", source, timestamp, version),
      available_spare = field(scalar(nvme.available_spare), "percent", source, timestamp, version),
      spare_threshold = field(scalar(nvme.available_spare_threshold), "percent", source, timestamp, version),
      percentage_used = field(scalar(nvme.percentage_used), "percent", source, timestamp, version),
      data_units_read = field(scalar(nvme.data_units_read), "units", source, timestamp, version),
      data_units_written = field(scalar(nvme.data_units_written), "units", source, timestamp, version),
      media_errors = field(scalar(nvme.media_errors), "count", source, timestamp, version),
      unsafe_shutdowns = field(scalar(nvme.unsafe_shutdowns), "count", source, timestamp, version),
    }, { source = source })
  end

  local attributes = {}
  local attribute_table = object(data.ata_smart_attributes).table
  if type(attribute_table) == "table" then
    for index, attribute in ipairs(attribute_table) do
      if index > MAX_ATTRIBUTES then break end
      attribute = object(attribute)
      attributes[#attributes + 1] = {
        id = scalar(attribute.id),
        name = scalar(attribute.name),
        normalized = scalar(attribute.value),
        worst = scalar(attribute.worst),
        threshold = scalar(attribute.thresh),
        when_failed = scalar(attribute.when_failed),
        raw = type(attribute.raw) == "table" and attribute.raw or scalar(attribute.raw),
        source = source,
        timestamp_ns = timestamp,
        quality = "fresh",
      }
    end
  end
  local raw_attributes = Model.section("ata_attributes", {
    items = field(attributes, nil, source, timestamp, version),
  }, { source = source })

  local entity_id = safe_text(device.id, 4096) or safe_text(device.path, 4096)
  if not entity_id then return nil, nil, nil, "smart_device_identity_required" end
  local entity = Model.entity(entity_id, "storage", {
    name = scalar(data.model_name) or safe_text(device.name) or safe_text(device.path) or entity_id,
    identity = identity.fields,
    health = health.fields,
    evidence = {
      source = source,
      provider = "smartctl",
      provider_version = version,
      timestamp_ns = timestamp,
      exit_code = exit_code,
    },
  })
  local sections = { identity, health }
  if nvme_section then
    sections[#sections + 1] = nvme_section
  end
  if #attributes > 0 then
    sections[#sections + 1] = raw_attributes
  end
  return entity, sections, version
end

function Smart.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Smart options must be a table", 2) end
  local max_devices = bounded_integer("max_devices", options.max_devices, 256, 1, 4096)
  local executable = options.executable or "/usr/sbin/smartctl"
  local candidates = options.executable_candidates or {
    "/usr/sbin/smartctl", "/usr/bin/smartctl", "/sbin/smartctl",
  }
  if not safe_absolute_path(executable) then error("invalid smartctl executable", 2) end
  if type(candidates) ~= "table" or #candidates > 64 then
    error("invalid smartctl executable candidates", 2)
  end
  for _, candidate in ipairs(candidates) do
    if not safe_absolute_path(candidate) then error("invalid smartctl executable candidate", 2) end
  end
  local block_path = options.block_path or "/sys/class/block"
  if not safe_absolute_path(block_path) then error("invalid SMART block path", 2) end
  return setmetatable({
    id = "storage.smart",
    domain = "storage",
    fs = options.fs or FS.default,
    runner = options.runner or Runner.new(),
    clock = options.clock or Clock.default,
    executable = executable,
    executable_candidates = candidates,
    ttl_ms = bounded_integer("ttl_ms", options.ttl_ms, 60000, 0, Cache.MAX_TTL_MS),
    timeout_ms = bounded_integer("timeout_ms", options.timeout_ms, 2000, 1, MAX_TIMEOUT_MS),
    max_output_bytes = bounded_integer("max_output_bytes", options.max_output_bytes,
      4 * 1024 * 1024, 4096, MAX_OUTPUT_BYTES),
    cache = Cache.new({ max_entries = bounded_integer(
      "cache_entries", options.cache_entries, 512, 1, 4096) }),
    block_path = block_path,
    max_devices = max_devices,
    _method_style = true,
  }, Smart)
end

function Smart:probe(context)
  local fs = context and context.fs or self.fs
  if context and context.smartctl_available == true then
    return Capability.available({ source = self.executable })
  end
  local last_error
  local candidates = { self.executable }
  for _, candidate in ipairs(self.executable_candidates) do
    if candidate ~= self.executable then
      candidates[#candidates + 1] = candidate
    end
  end
  for _, candidate in ipairs(candidates) do
    local exists, err = fs:exists(candidate)
    if exists then
      self.executable = candidate
      return Capability.available({ source = candidate })
    end
    last_error = err or last_error
  end
  if last_error and last_error.kind == "denied" then
    return Capability.denied(last_error.message, { source = self.executable })
  end
  return Capability.unavailable("smartctl_not_found", { source = self.executable })
end

function Smart:enumerate(context)
  local fs = context and context.fs or self.fs
  if context and type(context.block_devices) == "table" then
    local devices = {}
    for index, device in ipairs(context.block_devices) do
      if index > self.max_devices then break end
      if type(device) == "table" and safe_device_path(device.path or device.id) then
        devices[#devices + 1] = {
          id = device.id or device.path,
          path = device.path or device.id,
          name = safe_text(device.name) or (device.path or device.id):match("([^/]+)$"),
          model = safe_text(device.model),
          vendor = safe_text(device.vendor),
          rotational = scalar(device.rotational),
          source = safe_text(device.source, 4096),
        }
      end
    end
    devices.truncated = #context.block_devices > self.max_devices
    return devices
  end
  local entries, err, directory_truncated = fs:list(self.block_path, self.max_devices + 1)
  if not entries then
    return nil, err
  end
  local devices = {}
  local entry_count = math.min(#entries, self.max_devices)
  for index = 1, entry_count do
    local name = entries[index]
    if not safe_name(name) then goto continue end
    local virtual = name:match("^loop%d+") or name:match("^ram%d+") or name:match("^zram%d+") or name:match("^fd%d+")
    if not virtual then
      local base = self.block_path .. "/" .. name
      local partition, partition_error = fs:read(base .. "/partition", 128)
      if not partition and partition_error and (partition_error.kind == "missing"
          or partition_error.kind == "unavailable") then
        local model = fs:read(base .. "/device/model", 4096)
        local vendor = fs:read(base .. "/device/vendor", 4096)
        local rotational = fs:read_number(base .. "/queue/rotational")
        devices[#devices + 1] = {
          id = "/dev/" .. name,
          path = "/dev/" .. name,
          name = name,
          model = safe_text(model and Common.trim(model)),
          vendor = safe_text(vendor and Common.trim(vendor)),
          rotational = scalar(rotational),
          source = base,
        }
      end
    end
    ::continue::
  end
  table.sort(devices, function(left, right)
    return left.name < right.name
  end)
  devices.truncated = directory_truncated == true or #entries > self.max_devices
  return devices
end

function Smart:inspect(context, entity, depth)
  context = type(context) == "table" and context or {}
  entity = type(entity) == "table" and entity or {}
  local device_path = entity.path or entity.id
  local timestamp = now_ns(context, self.clock)
  if not safe_device_path(device_path) then
    return Model.result("error", nil, {}, {
      timestamp_ns = timestamp,
      quality = "error",
      reason = "invalid_device_path",
      provider = "smartctl",
    })
  end
  depth = depth or "summary"
  if type(depth) ~= "string" or #depth == 0 or #depth > 64
      or not depth:match("^[A-Za-z0-9_.%-]+$") then
    return Model.result("error", nil, {}, {
      timestamp_ns = timestamp, quality = "error", reason = "invalid_inspection_depth",
      provider = "smartctl",
    })
  end
  local cache_key = device_path .. ":" .. depth
  local cached = self.cache:get(cache_key, timestamp)
  if cached then
    cached.cached = true
    return cached
  end

  local started = timestamp
  local argv = {
    self.executable,
    "--json=c",
    "--nocheck=standby",
    "--all",
    device_path,
  }
  local run_ok, run = pcall(self.runner.run, self.runner, argv, {
    timeout_ms = self.timeout_ms,
    max_output_bytes = self.max_output_bytes,
  })
  local finished = now_ns(context, self.clock)
  local duration = math.max(0, finished - started)
  if not run_ok or type(run) ~= "table" then
    return Model.result("error", nil, {}, {
      timestamp_ns = finished, duration_ns = duration, quality = "error",
      reason = run_ok and "invalid_smartctl_runner_result" or "smartctl_runner_exception",
      provider = "smartctl",
    })
  end
  if run.status == "timeout" then
    return Model.result("error", nil, {}, {
      timestamp_ns = finished,
      duration_ns = duration,
      quality = "error",
      reason = "smartctl_timeout",
      provider = "smartctl",
      details = run,
    })
  end
  if run.status == "denied" or (type(run.stderr) == "string"
      and run.stderr:lower():find("permission denied", 1, true)) then
    return Model.result("denied", nil, {}, {
      timestamp_ns = finished,
      duration_ns = duration,
      quality = "denied",
      reason = "smartctl_permission_denied",
      permission = "device_read",
      provider = "smartctl",
      details = run,
    })
  end
  if run.status == "unavailable" then
    return Model.result("unavailable", nil, {}, {
      timestamp_ns = finished, duration_ns = duration, quality = "unavailable",
      reason = run.reason or "smartctl_unavailable", provider = "smartctl", details = run,
    })
  end
  if run.status == "cancelled" then
    return Model.result("error", nil, {}, {
      timestamp_ns = finished, duration_ns = duration, quality = "error",
      reason = "smartctl_cancelled", provider = "smartctl", details = run,
    })
  end
  if run.status ~= "ok" and (run.status ~= "error" or type(run.exit_code) ~= "number"
      or run.exit_code % 1 ~= 0 or run.exit_code < 0 or run.exit_code > 255) then
    return Model.result("error", nil, {}, {
      timestamp_ns = finished, duration_ns = duration, quality = "error",
      reason = "invalid_smartctl_runner_status", provider = "smartctl", details = run,
    })
  end
  if run.truncated then
    return Model.result("error", nil, {}, {
      timestamp_ns = finished,
      duration_ns = duration,
      quality = "error",
      reason = "smartctl_output_truncated",
      provider = "smartctl",
      details = run,
    })
  end
  if not run.stdout or run.stdout == "" then
    return Model.result(run.status == "unavailable" and "unavailable" or "error", nil, {}, {
      timestamp_ns = finished,
      duration_ns = duration,
      reason = run.reason or "smartctl_empty_output",
      provider = "smartctl",
      details = run,
    })
  end
  local decoded, decode_error = JSON.decode(run.stdout, { max_bytes = self.max_output_bytes, max_depth = 64 })
  if not decoded then
    return Model.result("error", nil, {}, {
      timestamp_ns = finished,
      duration_ns = duration,
      quality = "error",
      reason = "smartctl_invalid_json",
      provider = "smartctl",
      details = decode_error,
    })
  end
  local normalized_entity, sections, version, normalize_error = normalize(
    decoded, entity, finished, device_path, run.exit_code)
  if not normalized_entity then
    return Model.result("error", nil, {}, {
      timestamp_ns = finished, duration_ns = duration, quality = "error",
      reason = normalize_error or "smartctl_invalid_payload", provider = "smartctl",
    })
  end
  local result = Model.result("ok", normalized_entity, sections, {
    timestamp_ns = finished,
    duration_ns = duration,
    quality = "fresh",
    source = device_path,
    provider = "smartctl",
    provider_version = version,
    cache_ttl_ms = self.ttl_ms,
    details = { exit_code = run.exit_code, depth = depth },
  })
  self.cache:put(cache_key, result, finished, self.ttl_ms)
  return result
end

function Smart:invalidate(entity)
  if not entity then
    self.cache:invalidate()
    return
  end
  local prefix = (entity.path or entity.id or "") .. ":"
  for key in pairs(self.cache.entries) do
    if key:sub(1, #prefix) == prefix then
      self.cache:invalidate(key)
    end
  end
end

Smart.mask_serial = mask_serial
Smart.safe_device_path = safe_device_path
Smart.explicit_device_kind = explicit_device_kind
Smart.normalize = normalize

return Smart
