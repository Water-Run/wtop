local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local Parsers = require("wtop.linux.parsers")
local Sysfs = require("wtop.linux.sysfs")
local Common = require("wtop.collectors.common")

local GPU = {}
GPU.__index = GPU

local MAX_DIRECTORY_LIMIT = 2147483647
local PCI_IDS_PATHS = {
  "/usr/share/hwdata/pci.ids",
  "/usr/share/misc/pci.ids",
}
local DISPLAY_CLASS_NAMES = {
  [0x030000] = "VGA compatible controller",
  [0x030100] = "XGA compatible controller",
  [0x030200] = "3D controller",
  [0x038000] = "Display controller",
}

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function unsigned_decimal(value, maximum)
  if type(value) ~= "string" then
    return nil, "expected_unsigned_integer"
  end
  local raw = Common.trim(value)
  if not raw:match("^%d+$") then
    return nil, "expected_unsigned_integer"
  end
  local number = tonumber(raw)
  if not finite_number(number) then
    return nil, "number_out_of_range"
  end
  -- A bounded value must remain a Lua integer.  Otherwise tonumber() may
  -- round an oversized decimal to a float before the range check.
  if maximum ~= nil and (math.type(number) ~= "integer" or number > maximum) then
    return nil, "number_out_of_range"
  end
  return number
end

local function directory_index(value, minimum)
  local number = unsigned_decimal(value, MAX_DIRECTORY_LIMIT)
  if number == nil or number < (minimum or 0) or tostring(number) ~= value then
    return nil
  end
  return number
end

local function indexed_name(value, prefix)
  if type(value) ~= "string" then
    return nil
  end
  local suffix = value:match("^" .. prefix .. "(%d+)$")
  return suffix and directory_index(suffix, 0) or nil
end

local function positive_integer(name, value, default, maximum)
  if value == nil then
    return default
  end
  maximum = maximum or MAX_DIRECTORY_LIMIT
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
      or value % 1 ~= 0 or value < 1 or value > maximum then
    error(name .. " must be an integer between 1 and " .. maximum, 3)
  end
  return value
end

local function sorted_keys(values)
  local keys = {}
  for key in pairs(values or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function copy_map(values)
  local output = {}
  for key, value in pairs(values or {}) do
    output[key] = value
  end
  return output
end

local function safe_text(value)
  if type(value) ~= "string" then
    return nil
  end
  value = Common.trim(value):gsub("[%z\1-\31\127]", "�")
  if not utf8.len(value) then
    local output = {}
    local index = 1
    while index <= #value do
      local byte = value:byte(index)
      local length
      if byte < 0x80 then length = 1
      elseif byte >= 0xc2 and byte <= 0xdf then length = 2
      elseif byte >= 0xe0 and byte <= 0xef then length = 3
      elseif byte >= 0xf0 and byte <= 0xf4 then length = 4 end
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
  return value ~= "" and value or nil
end

local function parse_pci_ids_name(content, vendor_id, device_id, subsystem_vendor_id,
    subsystem_device_id)
  if type(content) ~= "string" or type(vendor_id) ~= "number"
      or (device_id ~= nil and type(device_id) ~= "number")
      or (subsystem_vendor_id ~= nil and type(subsystem_vendor_id) ~= "number")
      or (subsystem_device_id ~= nil and type(subsystem_device_id) ~= "number") then
    return nil, nil, nil
  end
  local wanted_vendor = string.format("%04x", vendor_id):lower()
  local wanted_device = device_id and string.format("%04x", device_id):lower() or nil
  local wanted_subsystem_vendor = subsystem_vendor_id
    and string.format("%04x", subsystem_vendor_id):lower() or nil
  local wanted_subsystem_device = subsystem_device_id
    and string.format("%04x", subsystem_device_id):lower() or nil
  local vendor_name, device_name, subsystem_name
  local in_device = false
  for line in content:gmatch("[^\r\n]+") do
    local listed_vendor, listed_vendor_name = line:match("^(%x%x%x%x)%s%s+(.+)$")
    if listed_vendor then
      if vendor_name then break end
      if listed_vendor:lower() == wanted_vendor then
        vendor_name = safe_text(listed_vendor_name)
        if not wanted_device then break end
      end
    elseif vendor_name then
      local listed_subvendor, listed_subdevice, listed_subsystem_name =
        line:match("^\t\t(%x%x%x%x)%s+(%x%x%x%x)%s%s+(.+)$")
      if in_device and listed_subvendor
          and listed_subvendor:lower() == wanted_subsystem_vendor
          and listed_subdevice:lower() == wanted_subsystem_device then
        subsystem_name = safe_text(listed_subsystem_name)
        break
      end
      local listed_device, listed_device_name = line:match("^\t(%x%x%x%x)%s%s+(.+)$")
      if listed_device then
        if in_device then break end
        if listed_device:lower() == wanted_device then
          device_name = safe_text(listed_device_name)
          in_device = true
          if not wanted_subsystem_vendor or not wanted_subsystem_device then break end
        end
      end
    end
  end
  return vendor_name, device_name, subsystem_name
end

local function pci_names(self, fs, vendor_id, device_id, subsystem_vendor_id,
    subsystem_device_id)
  if not vendor_id then return nil, nil, nil end
  local key = table.concat({ string.format("%04x", vendor_id),
    device_id and string.format("%04x", device_id) or "-",
    subsystem_vendor_id and string.format("%04x", subsystem_vendor_id) or "-",
    subsystem_device_id and string.format("%04x", subsystem_device_id) or "-" }, ":")
  local cached = self._pci_name_cache[key]
  if cached then return cached.vendor, cached.device, cached.subsystem end
  if self._pci_ids_content == nil then
    self._pci_ids_content = false
    for _, path in ipairs(self.pci_ids_paths) do
      local content = fs:read(path, self.max_pci_ids_bytes)
      if content then
        self._pci_ids_content = content
        self._pci_ids_source = path
        break
      end
    end
  end
  local vendor, device, subsystem = parse_pci_ids_name(
    self._pci_ids_content ~= false and self._pci_ids_content or nil,
    vendor_id, device_id, subsystem_vendor_id, subsystem_device_id)
  cached = { vendor = vendor, device = device, subsystem = subsystem }
  self._pci_name_cache[key] = cached
  return vendor, device, subsystem
end

local function scaled_number(value, multiplier)
  if type(value) ~= "number" or type(multiplier) ~= "number" then
    return nil
  end
  if math.type(value) == "integer" and math.type(multiplier) == "integer"
    and multiplier > 0 and value >= 0 and value <= math.maxinteger // multiplier
  then
    return value * multiplier
  end
  local scaled = value * (multiplier + 0.0)
  if scaled ~= scaled or scaled == math.huge or scaled == -math.huge then
    return nil
  end
  return scaled
end

local function add_nonnegative(left, right)
  if not finite_number(left) or not finite_number(right) or left < 0 or right < 0 then
    return nil
  end
  if math.type(left) == "integer" and math.type(right) == "integer"
    and left <= math.maxinteger - right
  then
    return left + right
  end
  local total = (left + 0.0) + (right + 0.0)
  return finite_number(total) and total or nil
end

local function is_optional_absence(err)
  return type(err) == "table" and (err.kind == "missing" or err.kind == "unavailable")
end

local function add_issue(issues, field, err, path, fallback)
  issues[#issues + 1] = {
    field = field,
    status = FS.error_status(err),
    reason = err and err.message or fallback or "read_failed",
    source = path,
  }
end

local function optional_signed_number(fs, path, issues, field, minimum, maximum)
  local content, err = fs:read(path, 256)
  if not content then
    if not is_optional_absence(err) then add_issue(issues, field, err, path) end
    return nil
  end
  local raw = Common.trim(content)
  if type(raw) ~= "string" or not raw:match("^[+-]?%d+$") then
    add_issue(issues, field, { kind = "parse_error", message = "expected_integer" }, path)
    return nil
  end
  local value = tonumber(raw)
  if not value or math.type(value) ~= "integer"
      or (minimum and value < minimum) or (maximum and value > maximum) then
    add_issue(issues, field, { kind = "parse_error", message = "number_out_of_range" }, path)
    return nil
  end
  return value
end

local function optional_text(fs, path, issues, field, limit)
  local content, err = fs:read(path, limit or 4096)
  if not content then
    if not is_optional_absence(err) then
      add_issue(issues, field, err, path)
    end
    return nil
  end
  local value = safe_text(content)
  if not value then
    add_issue(issues, field, { kind = "parse_error", message = "empty_value" }, path)
  end
  return value
end

local function optional_link_speed(fs, path, issues, field)
  local value = optional_text(fs, path, issues, field, 256)
  if value and (value:lower() == "unknown" or value:lower() == "n/a") then return nil end
  return value
end

local function optional_link_width(fs, path, issues, field)
  local value = optional_signed_number(fs, path, issues, field, 0, 1024)
  -- PCI core uses 0 and 255 when a link width is not meaningful, notably for
  -- integrated GPUs. Do not present those protocol values as x0 or x255.
  if value == 0 or value == 255 then return nil end
  return value
end

local function optional_number(fs, path, issues, field, minimum, maximum)
  local content, err = fs:read(path, 256)
  if content == nil then
    if not is_optional_absence(err) then
      add_issue(issues, field, err, path)
    end
    return nil
  end
  local value, parse_error = unsigned_decimal(content)
  if value == nil then
    add_issue(issues, field, { kind = "parse_error", message = parse_error }, path)
    return nil
  end
  if (minimum ~= nil and value < minimum) or (maximum ~= nil and value > maximum) then
    add_issue(issues, field, { kind = "parse_error", message = "number_out_of_range" }, path)
    return nil
  end
  return value
end

local function apply_entry_limit(entries, limit, truncated)
  truncated = truncated == true
  if entries and limit and #entries > limit then
    truncated = true
    for index = #entries, limit + 1, -1 do entries[index] = nil end
  end
  return entries, truncated
end

local function optional_list(fs, path, issues, field, limit)
  local entries, err, truncated = fs:list(path, limit)
  if entries then
    return apply_entry_limit(entries, limit, truncated)
  end
  if not is_optional_absence(err) then
    add_issue(issues, field, err, path)
  end
  return nil
end

local function normalize_bdf(value)
  if type(value) ~= "string" then
    return nil
  end
  local bdf = value:match("(%x%x%x%x:%x%x:%x%x%.%x)")
  return bdf and bdf:lower() or nil
end

local function numeric_name_sort(prefix)
  return function(left, right)
    local left_number = indexed_name(left, prefix) or math.huge
    local right_number = indexed_name(right, prefix) or math.huge
    if left_number == right_number then
      return left < right
    end
    return left_number < right_number
  end
end

local function inventory(fs, drm_path, max_class_entries, max_cards, max_render_nodes)
  local entries, err, list_truncated = fs:list(drm_path, max_class_entries)
  if not entries then
    return nil, err
  end
  entries, list_truncated = apply_entry_limit(entries, max_class_entries, list_truncated)
  local cards = {}
  local render_nodes = {}
  local truncated = list_truncated
  for index = 1, #entries do
    local entry = entries[index]
    if indexed_name(entry, "card") ~= nil then
      cards[#cards + 1] = entry
    elseif indexed_name(entry, "renderD") ~= nil then
      render_nodes[#render_nodes + 1] = entry
    end
  end
  table.sort(cards, numeric_name_sort("card"))
  table.sort(render_nodes, numeric_name_sort("renderD"))
  if #cards > max_cards then
    truncated = true
    for index = #cards, max_cards + 1, -1 do cards[index] = nil end
  end
  if #render_nodes > max_render_nodes then
    truncated = true
    for index = #render_nodes, max_render_nodes + 1, -1 do render_nodes[index] = nil end
  end
  return { cards = cards, render_nodes = render_nodes, truncated = truncated }
end

local function enumerate(fs, drm_path)
  local found, err = inventory(fs, drm_path, 4096, 256, 512)
  return found and found.cards or nil, err
end

local function describe_node(fs, drm_path, name, kind, issues)
  issues = issues or {}
  local class_path = drm_path .. "/" .. name
  local device_path = class_path .. "/device"
  local uevent_content, uevent_error = fs:read(device_path .. "/uevent", 65536)
  if not uevent_content and not is_optional_absence(uevent_error) then
    add_issue(issues, "identity.uevent", uevent_error, device_path .. "/uevent")
  end
  local uevent, uevent_parse_error = Sysfs.key_values(uevent_content)
  if uevent_parse_error and uevent_content then
    add_issue(issues, "identity.uevent", { kind = "parse_error",
      message = uevent_parse_error }, device_path .. "/uevent")
  end
  local device_link, device_link_error = fs:readlink(device_path)
  if not device_link and not is_optional_absence(device_link_error) then
    add_issue(issues, "identity.device_link", device_link_error, device_path)
  end
  local driver_link, driver_error = fs:readlink(device_path .. "/driver")
  if not driver_link and not is_optional_absence(driver_error) then
    add_issue(issues, "identity.driver", driver_error, device_path .. "/driver")
  end
  local bdf = normalize_bdf(uevent.PCI_SLOT_NAME) or normalize_bdf(device_link)
  return {
    name = name,
    kind = kind,
    class_path = class_path,
    device_path = device_path,
    dev = optional_text(fs, class_path .. "/dev", issues, "identity.dev", 256),
    device_target = device_link,
    device_key = bdf or device_link,
    pci_bdf = bdf,
    driver = uevent.DRIVER or Sysfs.basename(driver_link),
    uevent = uevent,
  }
end

local function parse_dpm_states(content, id)
  local states = {}
  local active
  for line in tostring(content or ""):gmatch("[^\r\n]+") do
    local level, number, unit = line:match("^%s*(%d+):%s*([%d.]+)%s*([kKmMgG]?[hH][zZ])")
    if level and number and unit then
      local multiplier = ({ hz = 1, khz = 1000, mhz = 1000000, ghz = 1000000000 })[unit:lower()]
      local hz = scaled_number(tonumber(number), multiplier)
      local level_number = unsigned_decimal(level, MAX_DIRECTORY_LIMIT)
      if hz and level_number ~= nil then
        local state = { level = level_number, frequency_hz = hz, active = line:find("%*") ~= nil }
        states[#states + 1] = state
        if state.active then
          active = hz
        end
      end
    end
  end
  if #states == 0 then
    return nil, "no_frequency_states"
  end
  table.sort(states, function(left, right) return left.level < right.level end)
  local minimum, maximum
  for _, state in ipairs(states) do
    minimum = not minimum and state.frequency_hz or math.min(minimum, state.frequency_hz)
    maximum = not maximum and state.frequency_hz or math.max(maximum, state.frequency_hz)
  end
  return {
    id = id,
    current_hz = active,
    minimum_hz = minimum,
    maximum_hz = maximum,
    states = states,
    source_kind = "amdgpu_dpm",
  }
end

local function read_dpm_domain(fs, path, id, issues)
  local content, err = fs:read(path, 65536)
  if not content then
    if not is_optional_absence(err) then
      add_issue(issues, "frequency." .. id, err, path)
    end
    return nil
  end
  local domain, parse_error = parse_dpm_states(content, id)
  if not domain then
    add_issue(issues, "frequency." .. id, { kind = "parse_error", message = parse_error }, path)
    return nil
  end
  domain.source = path
  return domain
end

local function mhz_value(fs, path, issues, field)
  local value = optional_number(fs, path, issues, field, 0)
  if value == nil then
    return nil
  end
  local scaled = scaled_number(value, 1000000)
  if scaled == nil then
    add_issue(issues, field, { kind = "parse_error", message = "number_out_of_range" }, path)
  end
  return scaled
end

local function intel_gt_domain(fs, base, id, issues, xe)
  local function read(name, field)
    return mhz_value(fs, base .. "/" .. name, issues, "frequency." .. id .. "." .. field)
  end
  local domain
  if xe then
    domain = {
      id = id,
      actual_hz = read("act_freq", "actual"),
      current_hz = read("cur_freq", "current"),
      minimum_hz = read("min_freq", "minimum"),
      maximum_hz = read("max_freq", "maximum"),
      hardware_minimum_hz = read("rpn_freq", "hardware_minimum"),
      efficient_hz = read("rpe_freq", "efficient") or read("rpa_freq", "achievable"),
      hardware_maximum_hz = read("rp0_freq", "hardware_maximum"),
      source_kind = "xe_gt",
      source = base,
    }
  else
    domain = {
      id = id,
      actual_hz = read("rps_act_freq_mhz", "actual"),
      current_hz = read("rps_cur_freq_mhz", "current"),
      minimum_hz = read("rps_min_freq_mhz", "minimum"),
      maximum_hz = read("rps_max_freq_mhz", "maximum"),
      hardware_minimum_hz = read("rps_RPn_freq_mhz", "hardware_minimum"),
      efficient_hz = read("rps_RP1_freq_mhz", "efficient"),
      hardware_maximum_hz = read("rps_RP0_freq_mhz", "hardware_maximum"),
      source_kind = "i915_gt",
      source = base,
    }
  end
  if domain.actual_hz or domain.current_hz or domain.minimum_hz or domain.maximum_hz
    or domain.hardware_minimum_hz or domain.hardware_maximum_hz
  then
    return domain
  end
  return nil
end

local function read_frequencies(self, fs, device, issues)
  local result = { domains = {}, by_id = {}, truncated = false }
  local probes = 0
  local walks = 0
  local max_walks = self.max_frequency_domains > (MAX_DIRECTORY_LIMIT - 4) // 4
    and MAX_DIRECTORY_LIMIT or self.max_frequency_domains * 4 + 4
  local function add(domain)
    if not domain or result.by_id[domain.id] then
      return
    end
    if #result.domains >= self.max_frequency_domains then
      result.truncated = true
      return
    end
    result.domains[#result.domains + 1] = domain
    result.by_id[domain.id] = domain
  end
  local function probe(reader)
    if probes >= self.max_frequency_domains then
      result.truncated = true
      return false
    end
    probes = probes + 1
    add(reader())
    return true
  end
  local function walk(path, field)
    if walks >= max_walks then
      result.truncated = true
      return nil, false
    end
    walks = walks + 1
    local entries, truncated = optional_list(fs, path, issues, field, max_walks)
    result.truncated = result.truncated or truncated == true
    return entries, true
  end

  if device.driver == "amdgpu" then
    probe(function()
      return read_dpm_domain(fs, device.device_path .. "/pp_dpm_sclk", "graphics", issues)
    end)
    probe(function()
      return read_dpm_domain(fs, device.device_path .. "/pp_dpm_mclk", "memory", issues)
    end)
  elseif device.driver == "i915" then
    local gt_path = device.class_path .. "/gt"
    local gt_entries = walk(gt_path, "frequency.gt_enumeration")
    if gt_entries then
      local names = {}
      for _, entry in ipairs(gt_entries) do
        if indexed_name(entry, "gt") ~= nil then names[#names + 1] = entry end
      end
      table.sort(names, numeric_name_sort("gt"))
      for _, name in ipairs(names) do
        if not probe(function()
          return intel_gt_domain(fs, gt_path .. "/" .. name, name, issues, false)
        end) then break end
      end
    end
    if #result.domains == 0 then
      probe(function()
        local domain = {
          id = "gt0",
          actual_hz = mhz_value(fs, device.class_path .. "/gt_act_freq_mhz", issues, "frequency.gt0.actual"),
          current_hz = mhz_value(fs, device.class_path .. "/gt_cur_freq_mhz", issues, "frequency.gt0.current"),
          minimum_hz = mhz_value(fs, device.class_path .. "/gt_min_freq_mhz", issues, "frequency.gt0.minimum"),
          maximum_hz = mhz_value(fs, device.class_path .. "/gt_max_freq_mhz", issues, "frequency.gt0.maximum"),
          hardware_minimum_hz = mhz_value(fs, device.class_path .. "/gt_RPn_freq_mhz", issues, "frequency.gt0.hardware_minimum"),
          efficient_hz = mhz_value(fs, device.class_path .. "/gt_RP1_freq_mhz", issues, "frequency.gt0.efficient"),
          hardware_maximum_hz = mhz_value(fs, device.class_path .. "/gt_RP0_freq_mhz", issues, "frequency.gt0.hardware_maximum"),
          source_kind = "i915_legacy",
          source = device.class_path,
        }
        return (domain.actual_hz or domain.current_hz) and domain or nil
      end)
    end
  elseif device.driver == "xe" then
    local tile_entries = walk(device.device_path, "frequency.tile_enumeration")
    local tiles = {}
    for _, entry in ipairs(tile_entries or {}) do
      if indexed_name(entry, "tile") ~= nil then tiles[#tiles + 1] = entry end
    end
    table.sort(tiles, numeric_name_sort("tile"))
    for _, tile in ipairs(tiles) do
      local tile_path = device.device_path .. "/" .. tile
      local gt_entries, walked = walk(tile_path, "frequency." .. tile .. ".gt_enumeration")
      if not walked then break end
      local gts = {}
      for _, entry in ipairs(gt_entries or {}) do
        if indexed_name(entry, "gt") ~= nil then gts[#gts + 1] = entry end
      end
      table.sort(gts, numeric_name_sort("gt"))
      for _, gt in ipairs(gts) do
        local gt_path = tile_path .. "/" .. gt
        local freq_entries, gt_walked = walk(gt_path, "frequency." .. tile .. "." .. gt)
        if not gt_walked then break end
        local frequencies = {}
        for _, entry in ipairs(freq_entries or {}) do
          if indexed_name(entry, "freq") ~= nil then frequencies[#frequencies + 1] = entry end
        end
        table.sort(frequencies, numeric_name_sort("freq"))
        for _, frequency in ipairs(frequencies) do
          if not probe(function()
            return intel_gt_domain(
              fs,
              gt_path .. "/" .. frequency,
              tile .. "/" .. gt .. "/" .. frequency,
              issues,
              true
            )
          end) then break end
        end
        if result.truncated then break end
      end
      if result.truncated then break end
    end
  end

  if result.truncated then
    add_issue(issues, "frequency", { kind = "too_large", message = "frequency_domain_limit" }, device.class_path)
  end
  return result
end

local function hwmon_references(self, fs, device, issues)
  local base = device.device_path .. "/hwmon"
  local entries, list_truncated = optional_list(fs, base, issues, "hwmon", self.max_hwmon_refs)
  local refs = {}
  local truncated = list_truncated == true
  if entries then
    local names = {}
    for _, entry in ipairs(entries) do
      if indexed_name(entry, "hwmon") ~= nil then names[#names + 1] = entry end
    end
    table.sort(names, numeric_name_sort("hwmon"))
    truncated = truncated or #names > self.max_hwmon_refs
    for index = 1, math.min(#names, self.max_hwmon_refs) do
      refs[index] = {
        class = names[index],
        pci_bdf = device.pci_bdf,
        device_target = device.device_target,
        source = base .. "/" .. names[index],
      }
    end
  end
  if truncated then
    add_issue(issues, "hwmon", { kind = "too_large", message = "hwmon_reference_limit" }, base)
  end
  return refs, truncated
end

local function frequency_multiplier(unit)
  local normalized = tostring(unit or ""):lower()
  return ({ [""] = 1, hz = 1, khz = 1000, mhz = 1000000, ghz = 1000000000 })[normalized]
end

local function memory_multiplier(unit)
  local normalized = tostring(unit or ""):lower()
  return ({ [""] = 1, b = 1, kib = 1024, mib = 1024 * 1024, gib = 1024 * 1024 * 1024 })[normalized]
end

local function parse_fdinfo(content)
  if type(content) ~= "string" then
    return nil, "content_required"
  end
  local result = {
    engines_ns = {},
    engine_capacity = {},
    cycles = {},
    total_cycles = {},
    maximum_frequency_hz = {},
    current_frequency_hz = {},
    memory = {
      total = {}, shared = {}, resident = {}, active = {}, purgeable = {},
    },
    parse_errors = 0,
  }
  local legacy_resident = {}
  for line in content:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^:%s]+):%s*(.-)%s*$")
    if key and key:sub(1, 4) == "drm-" then
      if key == "drm-driver" then
        result.driver = safe_text(value)
      elseif key == "drm-pdev" then
        result.pci_bdf = normalize_bdf(value)
        if not result.pci_bdf then result.parse_errors = result.parse_errors + 1 end
      elseif key == "drm-client-id" then
        result.client_id = value:match("^%d+$") and value or nil
        if result.client_id == nil then result.parse_errors = result.parse_errors + 1 end
      elseif key == "drm-client-name" then
        result.client_name = safe_text(value)
      else
        local raw, unit = value:match("^(%d+)%s*(%S*)$")
        local number = raw and unsigned_decimal(raw, math.maxinteger) or nil
        local engine_capacity = key:match("^drm%-engine%-capacity%-(.+)$")
        local total_cycles = key:match("^drm%-total%-cycles%-(.+)$")
        local cycles = key:match("^drm%-cycles%-(.+)$")
        local maxfreq = key:match("^drm%-maxfreq%-(.+)$")
        local curfreq = key:match("^drm%-curfreq%-(.+)$")
        local engine = key:match("^drm%-engine%-(.+)$")
        if engine_capacity then
          if number and number > 0 then result.engine_capacity[engine_capacity] = number
          else result.parse_errors = result.parse_errors + 1 end
        elseif total_cycles then
          if number then result.total_cycles[total_cycles] = number
          else result.parse_errors = result.parse_errors + 1 end
        elseif cycles then
          if number then result.cycles[cycles] = number
          else result.parse_errors = result.parse_errors + 1 end
        elseif maxfreq or curfreq then
          local multiplier = frequency_multiplier(unit)
          if number and multiplier then
            local output = maxfreq and result.maximum_frequency_hz or result.current_frequency_hz
            output[maxfreq or curfreq] = scaled_number(number, multiplier)
            if output[maxfreq or curfreq] == nil then
              result.parse_errors = result.parse_errors + 1
            end
          else
            result.parse_errors = result.parse_errors + 1
          end
        elseif engine then
          local multiplier = ({ [""] = 1, ns = 1, us = 1000, ms = 1000000 })[unit:lower()]
          local scaled = scaled_number(number, multiplier)
          if scaled then
            result.engines_ns[engine] = scaled
          else result.parse_errors = result.parse_errors + 1 end
        else
          local category, region
          for _, candidate in ipairs({ "total", "shared", "resident", "active", "purgeable" }) do
            region = key:match("^drm%-" .. candidate .. "%-(.+)$")
            if region then category = candidate break end
          end
          local legacy = key:match("^drm%-memory%-(.+)$")
          if category or legacy then
            local multiplier = memory_multiplier(unit)
            if number and multiplier then
              local scaled = scaled_number(number, multiplier)
              if not scaled then
                result.parse_errors = result.parse_errors + 1
              elseif category then result.memory[category][region] = scaled
              else legacy_resident[legacy] = scaled end
            else
              result.parse_errors = result.parse_errors + 1
            end
          end
        end
      end
    end
  end
  if not result.driver then
    return nil, "drm_driver_missing"
  end
  for region, value in pairs(legacy_resident) do
    if result.memory.resident[region] == nil then
      result.memory.resident[region] = value
    end
  end
  return result
end

local function memory_summary(memory)
  local result = {}
  for _, category in ipairs({ "total", "shared", "resident", "active", "purgeable" }) do
    local total = 0
    local found = false
    local overflow = false
    for _, value in pairs(memory and memory[category] or {}) do
      local next_total = add_nonnegative(total, value)
      if next_total == nil then
        overflow = true
        break
      end
      total = next_total
      found = true
    end
    if found and not overflow then result[category .. "_bytes"] = total end
  end
  return result
end

local function derive_client(parsed, id, previous, observed_at_ns)
  local elapsed_ns = previous and previous.observed_at_ns and observed_at_ns
    and Common.elapsed_ns(observed_at_ns, previous.observed_at_ns) or nil
  local client = {
    id = id,
    client_id = parsed.client_id,
    name = parsed.client_name,
    driver = parsed.driver,
    pci_bdf = parsed.pci_bdf,
    engines = {},
    memory = {
      total = copy_map(parsed.memory.total),
      shared = copy_map(parsed.memory.shared),
      resident = copy_map(parsed.memory.resident),
      active = copy_map(parsed.memory.active),
      purgeable = copy_map(parsed.memory.purgeable),
    },
    process_ids = {},
    fd_references = 0,
    observed_at_ns = observed_at_ns,
    quality = "fresh",
  }
  local engine_names = {}
  for key in pairs(parsed.engines_ns) do engine_names[key] = true end
  for key in pairs(parsed.cycles) do engine_names[key] = true end
  local any_gap = false
  local any_held = false
  for _, name in ipairs(sorted_keys(engine_names)) do
    local current_ns = parsed.engines_ns[name]
    local old = previous and previous.engines and previous.engines[name]
    local capacity = parsed.engine_capacity[name] or 1
    local engine = {
      id = name,
      capacity = capacity,
      busy_ns = current_ns,
      cycles = parsed.cycles[name],
      total_cycles = parsed.total_cycles[name],
      maximum_frequency_hz = parsed.maximum_frequency_hz[name],
      current_frequency_hz = parsed.current_frequency_hz[name],
    }
    if current_ns ~= nil then
      local old_high = old and (old.high_water_ns or old.busy_ns)
      engine.high_water_ns = old_high and math.max(old_high, current_ns) or current_ns
      if old_high == nil or not elapsed_ns or elapsed_ns <= 0 then
        engine.rate_quality = "gap"
        any_gap = true
      else
        engine.rate_quality = current_ns < old_high and "held" or "fresh"
        engine.utilization_percent = math.max(0, math.min(100,
          ((engine.high_water_ns - old_high) + 0.0) * 100 / elapsed_ns / capacity
        ))
        any_held = any_held or engine.rate_quality == "held"
      end
    end
    local busy_cycles = parsed.cycles[name]
    local total_cycles = parsed.total_cycles[name]
    if busy_cycles ~= nil then
      local old_busy = old and (old.high_water_cycles or old.cycles)
      local old_total = old and (old.high_water_total_cycles or old.total_cycles)
      engine.high_water_cycles = old_busy and math.max(old_busy, busy_cycles) or busy_cycles
      if total_cycles ~= nil then
        engine.high_water_total_cycles = old_total and math.max(old_total, total_cycles) or total_cycles
      end
      if not old_busy or not elapsed_ns or elapsed_ns <= 0 then
        engine.cycle_rate_quality = "gap"
        if current_ns == nil then any_gap = true end
      else
        engine.cycle_rate_quality = busy_cycles < old_busy and "held" or "fresh"
        any_held = any_held or engine.cycle_rate_quality == "held"
        local busy_delta = engine.high_water_cycles - old_busy
        local total_delta = engine.high_water_total_cycles and old_total
          and (engine.high_water_total_cycles - old_total) or nil
        if total_delta and total_delta > 0 then
          engine.cycle_utilization_percent = math.max(0, math.min(100,
            (busy_delta + 0.0) * 100 / total_delta / capacity
          ))
        elseif engine.maximum_frequency_hz and engine.maximum_frequency_hz > 0 then
          local available_cycles = engine.maximum_frequency_hz * (elapsed_ns / 1000000000)
          engine.cycle_utilization_percent = math.max(0, math.min(100,
            (busy_delta + 0.0) * 100 / available_cycles / capacity
          ))
        end
      end
      if current_ns == nil and engine.cycle_utilization_percent ~= nil then
        engine.utilization_percent = engine.cycle_utilization_percent
        engine.rate_quality = engine.cycle_rate_quality
      end
    end
    client.engines[name] = engine
  end
  client.memory_summary = memory_summary(client.memory)
  if any_gap then client.quality = "gap"
  elseif any_held then client.quality = "estimated" end
  return client
end

local function aggregate_clients(clients)
  local engines = {}
  local memory = { total = {}, shared = {}, resident = {}, active = {}, purgeable = {} }
  local memory_overflow = { total = {}, shared = {}, resident = {}, active = {}, purgeable = {} }
  local overall
  for _, client in ipairs(clients) do
    for name, engine in pairs(client.engines or {}) do
      local aggregate = engines[name]
      if not aggregate then
        aggregate = { id = name, utilization_percent = 0, clients = 0, quality = "gap" }
        engines[name] = aggregate
      end
      aggregate.clients = aggregate.clients + 1
      if engine.utilization_percent ~= nil then
        aggregate.utilization_percent = math.min(100, aggregate.utilization_percent + engine.utilization_percent)
        if engine.rate_quality == "held" then
          aggregate.quality = "estimated"
        elseif aggregate.quality ~= "estimated" then
          aggregate.quality = "fresh"
        end
        overall = math.max(overall or 0, aggregate.utilization_percent)
      end
    end
    for _, category in ipairs({ "total", "shared", "resident", "active", "purgeable" }) do
      for region, value in pairs(client.memory and client.memory[category] or {}) do
        if not memory_overflow[category][region] then
          local total = add_nonnegative(memory[category][region] or 0, value)
          if total == nil then
            memory[category][region] = nil
            memory_overflow[category][region] = true
          else
            memory[category][region] = total
          end
        end
      end
    end
  end
  return {
    engines = engines,
    utilization_percent = overall,
    memory = memory,
    memory_summary = memory_summary(memory),
  }
end

local function client_view(client, observation)
  return {
    id = client.id,
    client_id = client.client_id,
    name = client.name,
    driver = client.driver,
    pci_bdf = client.pci_bdf,
    mapping_quality = observation.mapping_quality,
    fd_count = #observation.fds,
    fds = observation.fds,
    engines = client.engines,
    memory = client.memory,
    memory_summary = client.memory_summary,
    observed_at_ns = client.observed_at_ns,
    quality = client.quality,
  }
end

local function device_for_fdinfo(parsed, fd_target, lookup)
  if parsed.pci_bdf and lookup.by_bdf[parsed.pci_bdf] then
    return lookup.by_bdf[parsed.pci_bdf], "fresh"
  end
  local node = type(fd_target) == "string" and fd_target:match("/([^/]+)$") or nil
  if node then node = node:gsub("%s+%(deleted%)$", "") end
  if node and lookup.by_node[node] then
    return lookup.by_node[node], "fresh"
  end
  local candidates = lookup.by_driver[parsed.driver]
  if candidates and #candidates == 1 then
    return candidates[1], "estimated"
  end
  return nil, "unmatched"
end

local function process_stat(fs, path)
  local content, err = fs:read(path, 65536)
  if not content then return nil, err end
  local parsed, parse_error = Parsers.process_stat(content)
  if not parsed then
    return nil, { kind = "parse_error", message = parse_error, path = path }
  end
  return parsed
end

local function append_unique(values, value)
  for _, existing in ipairs(values) do
    if existing == value then return end
  end
  values[#values + 1] = value
end

local function initialize_process_data(device)
  device.processes = {
    list = {},
    by_id = {},
    clients = {},
    clients_by_id = {},
    summary = { process_count = 0, client_count = 0 },
  }
end

local function commit_process(observations, stat, uid, previous_by_id)
  local grouped = {}
  for _, observation in pairs(observations) do
    local id = observation.device.id
    grouped[id] = grouped[id] or { device = observation.device, observations = {} }
    grouped[id].observations[#grouped[id].observations + 1] = observation
  end
  for _, group in pairs(grouped) do
    local device = group.device
    local process = {
      id = stat.id,
      pid = stat.pid,
      starttime_ticks = stat.starttime_ticks,
      name = safe_text(stat.comm),
      uid = uid,
      clients = {},
      clients_by_id = {},
      quality = "fresh",
    }
    table.sort(group.observations, function(left, right) return left.id < right.id end)
    local previous_device = previous_by_id and previous_by_id[device.id]
    for _, observation in ipairs(group.observations) do
      local canonical = device.processes.clients_by_id[observation.id]
      if not canonical then
        local old = previous_device and previous_device.processes
          and previous_device.processes.clients_by_id
          and previous_device.processes.clients_by_id[observation.id]
        canonical = derive_client(observation.parsed, observation.id, old, observation.observed_at_ns)
        device.processes.clients[#device.processes.clients + 1] = canonical
        device.processes.clients_by_id[canonical.id] = canonical
      end
      append_unique(canonical.process_ids, stat.id)
      canonical.fd_references = canonical.fd_references + #observation.fds
      local view = client_view(canonical, observation)
      process.clients[#process.clients + 1] = view
      process.clients_by_id[view.id] = view
      if view.quality ~= "fresh" then process.quality = view.quality end
      if observation.mapping_quality == "estimated" then process.quality = "estimated" end
    end
    local aggregate = aggregate_clients(process.clients)
    process.engines = aggregate.engines
    process.utilization_percent = aggregate.utilization_percent
    process.memory = aggregate.memory
    process.memory_summary = aggregate.memory_summary
    device.processes.list[#device.processes.list + 1] = process
    device.processes.by_id[process.id] = process
  end
end

local function scan_processes(self, fs, devices, lookup, previous, context)
  local enabled = self.scan_processes and (not context or context.scan_gpu_processes ~= false)
  local scan = {
    enabled = enabled,
    status = "ok",
    quality = "fresh",
    scanned_processes = 0,
    scanned_fdinfo_files = 0,
    drm_fdinfo_files = 0,
    denied = 0,
    races = 0,
    parse_errors = 0,
    unmatched_clients = 0,
    truncated = false,
  }
  for _, device in ipairs(devices) do initialize_process_data(device) end
  if not enabled then
    scan.status = "disabled"
    scan.quality = "unavailable"
    return scan
  end

  local proc_entry_limit = self.max_processes > MAX_DIRECTORY_LIMIT - 128
    and MAX_DIRECTORY_LIMIT or self.max_processes + 128
  local proc_entries, proc_error, proc_list_truncated = fs:list(self.proc_path, proc_entry_limit)
  if not proc_entries then
    scan.status = FS.error_status(proc_error)
    scan.quality = scan.status
    scan.reason = proc_error and proc_error.message or "proc_enumeration_failed"
    return scan
  end
  proc_entries, proc_list_truncated = apply_entry_limit(
    proc_entries, proc_entry_limit, proc_list_truncated
  )
  local pids = {}
  for _, entry in ipairs(proc_entries) do
    local pid = directory_index(entry, 1)
    if pid then pids[#pids + 1] = pid end
  end
  table.sort(pids)
  if proc_list_truncated or #pids > self.max_processes then scan.truncated = true end
  local stop = false
  local observed_clients = 0
  local previous_data = Common.previous_data(previous)
  local previous_by_id = previous_data and previous_data.by_id or nil

  for pid_index = 1, math.min(#pids, self.max_processes) do
    if stop then break end
    local pid = pids[pid_index]
    scan.scanned_processes = scan.scanned_processes + 1
    local base = self.proc_path .. "/" .. tostring(pid)
    local stat, stat_error = process_stat(fs, base .. "/stat")
    if not stat then
      if stat_error and stat_error.kind == "denied" then scan.denied = scan.denied + 1
      else scan.races = scan.races + 1 end
    else
      local fd_entries, fd_error, fd_list_truncated = fs:list(
        base .. "/fdinfo", self.max_fds_per_process
      )
      if not fd_entries then
        if fd_error and fd_error.kind == "denied" then scan.denied = scan.denied + 1
        else scan.races = scan.races + 1 end
      else
        fd_entries, fd_list_truncated = apply_entry_limit(
          fd_entries, self.max_fds_per_process, fd_list_truncated
        )
        local fds = {}
        for _, entry in ipairs(fd_entries) do
          local fd = directory_index(entry, 0)
          if fd then fds[#fds + 1] = fd end
        end
        table.sort(fds)
        if fd_list_truncated or #fds > self.max_fds_per_process then scan.truncated = true end
        local observations = {}
        for fd_index = 1, math.min(#fds, self.max_fds_per_process) do
          if scan.scanned_fdinfo_files >= self.max_fdinfo_files then
            scan.truncated = true
            stop = true
            break
          end
          local fd = fds[fd_index]
          local fdinfo_path = base .. "/fdinfo/" .. tostring(fd)
          local content, fd_error_value = fs:read(fdinfo_path, self.max_fdinfo_bytes)
          local observed_at_ns = Common.now_ns(context)
          scan.scanned_fdinfo_files = scan.scanned_fdinfo_files + 1
          -- An empty procfs seqfile is reported as read_failed by Lua's
          -- fixed-size file:read(), but is a valid non-DRM descriptor.
          if not content and fd_error_value and fd_error_value.kind == "io_error"
            and fd_error_value.message == "read_failed"
          then
            content = ""
          end
          if not content then
            if fd_error_value and fd_error_value.kind == "denied" then
              scan.denied = scan.denied + 1
            elseif not is_optional_absence(fd_error_value) then
              scan.parse_errors = scan.parse_errors + 1
            else
              scan.races = scan.races + 1
            end
          elseif content:find("drm-driver:", 1, true) then
            scan.drm_fdinfo_files = scan.drm_fdinfo_files + 1
            local parsed, parse_error = parse_fdinfo(content)
            if not parsed then
              scan.parse_errors = scan.parse_errors + 1
              scan.last_parse_error = parse_error
            else
              scan.parse_errors = scan.parse_errors + parsed.parse_errors
              local fd_target
              if not parsed.pci_bdf then
                fd_target = fs:readlink(base .. "/fd/" .. tostring(fd))
              end
              local device, mapping_quality = device_for_fdinfo(parsed, fd_target, lookup)
              if not device then
                scan.unmatched_clients = scan.unmatched_clients + 1
              else
                local key
                if parsed.client_id ~= nil then
                  key = device.id .. ":" .. parsed.driver .. ":" .. tostring(parsed.client_id)
                else
                  key = device.id .. ":" .. stat.id .. ":fd:" .. tostring(fd)
                  mapping_quality = "estimated"
                end
                local observation = observations[key]
                if observation then
                  observation.fds[#observation.fds + 1] = fd
                elseif observed_clients >= self.max_clients then
                  scan.truncated = true
                  stop = true
                  break
                else
                  observations[key] = {
                    id = key,
                    device = device,
                    parsed = parsed,
                    fds = { fd },
                    observed_at_ns = observed_at_ns,
                    mapping_quality = mapping_quality,
                  }
                  observed_clients = observed_clients + 1
                end
              end
            end
          end
        end
        if next(observations) then
          local final_stat = process_stat(fs, base .. "/stat")
          if not final_stat or final_stat.pid ~= stat.pid or final_stat.starttime_ticks ~= stat.starttime_ticks then
            scan.races = scan.races + 1
          else
            local uid
            local status_content, status_error = fs:read(base .. "/status", 256 * 1024)
            if status_content then
              local status = Parsers.process_status(status_content)
              uid = status and status.uid
            elseif status_error and status_error.kind == "denied" then
              scan.denied = scan.denied + 1
            end
            commit_process(observations, stat, uid, previous_by_id)
          end
        end
      end
    end
  end

  if scan.denied > 0 or scan.races > 0 or scan.parse_errors > 0
      or scan.unmatched_clients > 0 or scan.truncated then
    scan.quality = "partial"
  end
  return scan
end

local function finalize_processes(device, scan)
  table.sort(device.processes.clients, function(left, right) return left.id < right.id end)
  table.sort(device.processes.list, function(left, right)
    local left_usage = left.utilization_percent or -1
    local right_usage = right.utilization_percent or -1
    if left_usage == right_usage then return left.pid < right.pid end
    return left_usage > right_usage
  end)
  local aggregate = aggregate_clients(device.processes.clients)
  device.processes.summary = {
    process_count = #device.processes.list,
    client_count = #device.processes.clients,
    utilization_percent = aggregate.utilization_percent,
    engines = aggregate.engines,
    memory = aggregate.memory,
    memory_summary = aggregate.memory_summary,
  }
  device.processes.quality = scan.quality
  device.capabilities.processes = #device.processes.clients > 0
  device.capabilities.process_memory = next(aggregate.memory_summary) ~= nil
  device.quality.processes = scan.quality
  if device.metrics.utilization_percent == nil
      and finite_number(aggregate.utilization_percent) then
    device.metrics.utilization_percent = aggregate.utilization_percent
    device.metrics.utilization_source = "drm_fdinfo"
    device.capabilities.utilization = true
    device.quality.utilization = scan.quality == "fresh" and "estimated" or scan.quality
  end
  local process_memory = aggregate.memory_summary.resident_bytes
    or aggregate.memory_summary.total_bytes
  if finite_number(process_memory) then
    device.metrics.process_memory_bytes = process_memory
    device.metrics.process_memory_source = "drm_fdinfo"
  end
  if scan.quality == "partial" or scan.status == "denied" then
    device.partial = true
  end
end

local function build_device(self, fs, drm_path, card_name, used_ids)
  local issues = {}
  local primary = describe_node(fs, drm_path, card_name, "primary", issues)
  local uevent = primary.uevent
  local vendor_text = optional_text(fs, primary.device_path .. "/vendor", issues, "identity.vendor", 256)
  local device_text = optional_text(fs, primary.device_path .. "/device", issues, "identity.device", 256)
  local vendor_id = Sysfs.hex_id(vendor_text)
  local device_id = Sysfs.hex_id(device_text)
  local pci_vendor_name, pci_device_name = pci_names(self, fs, vendor_id, device_id)
  local bdf = primary.pci_bdf
  local driver = primary.driver
  local id = bdf or (primary.device_target and ((driver or "drm") .. "@" .. primary.device_target)) or card_name
  local identity_quality = bdf and vendor_id and driver and "fresh" or "estimated"
  if used_ids[id] then
    id = id .. "#" .. card_name
    identity_quality = "estimated"
    add_issue(issues, "identity", { kind = "collision", message = "device_identity_collision" }, primary.class_path)
  end
  used_ids[id] = true

  local device = {
    id = id,
    stable_id = bdf and ("pci:" .. bdf) or id,
    card = card_name,
    primary_node = card_name,
    class_path = primary.class_path,
    device_path = primary.device_path,
    device_target = primary.device_target,
    pci_bdf = bdf,
    vendor_id = vendor_id,
    device_id = device_id,
    vendor = Sysfs.vendor_name(vendor_id),
    vendor_name = pci_vendor_name,
    model_name = pci_device_name,
    driver = driver or uevent.DRIVER,
    identity_quality = identity_quality,
    drm_nodes = {
      {
        name = primary.name,
        kind = "primary",
        dev = primary.dev,
        pci_bdf = primary.pci_bdf,
        source = primary.class_path,
      },
    },
    render_nodes = {},
    metrics = {},
    frequencies = {},
    hwmon_refs = {},
    capabilities = {},
    quality = {},
    issues = issues,
    partial = #issues > 0,
    source = primary.class_path,
  }

  local subsystem_vendor_text = optional_text(
    fs, device.device_path .. "/subsystem_vendor", issues, "identity.subsystem_vendor", 256)
  local subsystem_device_text = optional_text(
    fs, device.device_path .. "/subsystem_device", issues, "identity.subsystem_device", 256)
  local revision_text = optional_text(
    fs, device.device_path .. "/revision", issues, "identity.revision", 256)
  local class_text = optional_text(
    fs, device.device_path .. "/class", issues, "identity.class", 256)
  local boot_vga = optional_signed_number(
    fs, device.device_path .. "/boot_vga", issues, "pci.boot_vga", 0, 1)
  local subsystem_vendor_id = Sysfs.hex_id(subsystem_vendor_text)
  local subsystem_device_id = Sysfs.hex_id(subsystem_device_text)
  local subsystem_vendor_name = pci_names(self, fs, subsystem_vendor_id)
  local _, _, subsystem_model_name = pci_names(self, fs, vendor_id, device_id,
    subsystem_vendor_id, subsystem_device_id)
  local class_id = Sysfs.hex_id(class_text)
  device.pci = {
    class_id = class_id,
    class_name = class_id and DISPLAY_CLASS_NAMES[class_id & 0xffff00] or nil,
    revision = Sysfs.hex_id(revision_text),
    subsystem_vendor_id = subsystem_vendor_id,
    subsystem_device_id = subsystem_device_id,
    subsystem_vendor_name = subsystem_vendor_name,
    subsystem_model_name = subsystem_model_name,
    numa_node = optional_signed_number(
      fs, device.device_path .. "/numa_node", issues, "pci.numa_node", -1, 2147483647),
    current_link_speed = optional_link_speed(
      fs, device.device_path .. "/current_link_speed", issues, "pci.current_link_speed"),
    current_link_width = optional_link_width(
      fs, device.device_path .. "/current_link_width", issues, "pci.current_link_width"),
    maximum_link_speed = optional_link_speed(
      fs, device.device_path .. "/max_link_speed", issues, "pci.maximum_link_speed"),
    maximum_link_width = optional_link_width(
      fs, device.device_path .. "/max_link_width", issues, "pci.maximum_link_width"),
    runtime_status = optional_text(
      fs, device.device_path .. "/power/runtime_status", issues, "power.runtime_status", 256),
    modalias = optional_text(
      fs, device.device_path .. "/modalias", issues, "identity.modalias", 4096),
    pci_ids_source = self._pci_ids_source,
  }
  if boot_vga ~= nil then device.pci.boot_vga = boot_vga == 1 end

  device.metrics.utilization_percent = optional_number(
    fs, device.device_path .. "/gpu_busy_percent", issues, "utilization", 0, 100
  )
  if device.metrics.utilization_percent ~= nil then
    device.metrics.utilization_source = "sysfs"
  end
  device.metrics.memory_busy_percent = optional_number(
    fs, device.device_path .. "/mem_busy_percent", issues, "memory_busy", 0, 100
  )
  device.metrics.memory_total_bytes = optional_number(
    fs, device.device_path .. "/mem_info_vram_total", issues, "memory.vram_total", 0
  )
  device.metrics.memory_used_bytes = optional_number(
    fs, device.device_path .. "/mem_info_vram_used", issues, "memory.vram_used", 0
  )
  device.metrics.visible_memory_total_bytes = optional_number(
    fs, device.device_path .. "/mem_info_vis_vram_total", issues, "memory.visible_vram_total", 0
  )
  device.metrics.visible_memory_used_bytes = optional_number(
    fs, device.device_path .. "/mem_info_vis_vram_used", issues, "memory.visible_vram_used", 0
  )
  device.metrics.gtt_total_bytes = optional_number(
    fs, device.device_path .. "/mem_info_gtt_total", issues, "memory.gtt_total", 0
  )
  device.metrics.gtt_used_bytes = optional_number(
    fs, device.device_path .. "/mem_info_gtt_used", issues, "memory.gtt_used", 0
  )

  device.frequencies = read_frequencies(self, fs, device, issues)
  local first_frequency = device.frequencies.domains[1]
  if first_frequency then
    device.metrics.frequency_current_hz = first_frequency.actual_hz or first_frequency.current_hz
    device.metrics.frequency_minimum_hz = first_frequency.minimum_hz or first_frequency.hardware_minimum_hz
    device.metrics.frequency_maximum_hz = first_frequency.maximum_hz or first_frequency.hardware_maximum_hz
  end
  local graphics = device.frequencies.by_id.graphics
  local memory = device.frequencies.by_id.memory
  if graphics then device.metrics.frequency_graphics_hz = graphics.current_hz end
  if memory then device.metrics.frequency_memory_hz = memory.current_hz end

  device.hwmon_refs, device.hwmon_truncated = hwmon_references(self, fs, device, issues)
  device.capabilities.utilization = device.metrics.utilization_percent ~= nil
  device.capabilities.memory = device.metrics.memory_total_bytes ~= nil or device.metrics.memory_used_bytes ~= nil
  device.capabilities.frequency = #device.frequencies.domains > 0
  device.capabilities.hwmon = #device.hwmon_refs > 0
  -- Temperature, power and fan values are owned by the global hwmon collector.
  -- These flags remain false here; hwmon_refs provides the lossless join key.
  device.capabilities.power = false
  device.capabilities.temperature = false
  device.capabilities.fan = false
  device.capabilities.processes = false
  device.capabilities.process_memory = false
  for _, metric in ipairs({ "utilization", "memory", "frequency", "hwmon" }) do
    device.quality[metric] = device.capabilities[metric] and "fresh" or "unavailable"
  end
  local hwmon_quality = #device.hwmon_refs > 0 and "linked" or "unavailable"
  device.quality.power = hwmon_quality
  device.quality.temperature = hwmon_quality
  device.quality.fan = hwmon_quality
  device.partial = device.partial or #issues > 0
  return device
end

local function attach_render_nodes(fs, drm_path, names, devices, lookup, scan)
  for _, name in ipairs(names) do
    local issues = {}
    local node = describe_node(fs, drm_path, name, "render", issues)
    local device = node.pci_bdf and lookup.by_bdf[node.pci_bdf] or nil
    if not device and node.device_key then device = lookup.by_device_key[node.device_key] end
    if not device and node.driver and lookup.by_driver[node.driver] and #lookup.by_driver[node.driver] == 1 then
      device = lookup.by_driver[node.driver][1]
      scan.estimated_render_links = scan.estimated_render_links + 1
    end
    if device then
      local descriptor = {
        name = node.name,
        kind = "render",
        dev = node.dev,
        pci_bdf = node.pci_bdf,
        source = node.class_path,
      }
      device.drm_nodes[#device.drm_nodes + 1] = descriptor
      device.render_nodes[#device.render_nodes + 1] = node.name
      lookup.by_node[node.name] = device
      if #issues > 0 then
        device.partial = true
        for _, issue in ipairs(issues) do device.issues[#device.issues + 1] = issue end
      end
    else
      scan.unattached_render_nodes = scan.unattached_render_nodes + 1
    end
  end
end

function GPU.new(options)
  options = options or {}
  if type(options) ~= "table" then error("GPU options must be a table", 2) end
  if options.scan_processes ~= nil and type(options.scan_processes) ~= "boolean" then
    error("scan_processes must be a boolean", 2)
  end
  if options.pci_ids_paths ~= nil and type(options.pci_ids_paths) ~= "table" then
    error("pci_ids_paths must be an array", 2)
  end
  local pci_ids_paths = {}
  for index, path in ipairs(options.pci_ids_paths or PCI_IDS_PATHS) do
    if index > 8 then error("pci_ids_paths must contain at most 8 paths", 2) end
    pci_ids_paths[index] = Common.absolute_path("pci_ids_paths[" .. index .. "]", path)
  end
  if #pci_ids_paths == 0 then error("pci_ids_paths must not be empty", 2) end
  return setmetatable({
    id = "gpu",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    fs = options.fs or FS.default,
    drm_path = Common.absolute_path("drm_path", options.drm_path, "/sys/class/drm"),
    proc_path = Common.absolute_path("proc_path", options.proc_path, "/proc"),
    scan_processes = options.scan_processes ~= false,
    max_class_entries = positive_integer("max_class_entries", options.max_class_entries, 4096, 65536),
    max_cards = positive_integer("max_cards", options.max_cards, 32, 4096),
    max_render_nodes = positive_integer("max_render_nodes", options.max_render_nodes, 64, 16384),
    max_hwmon_refs = positive_integer("max_hwmon_refs", options.max_hwmon_refs, 16, 4096),
    max_frequency_domains = positive_integer(
      "max_frequency_domains", options.max_frequency_domains, 32, 16384),
    max_processes = positive_integer("max_processes", options.max_processes, 4096, 65536),
    max_fds_per_process = positive_integer(
      "max_fds_per_process", options.max_fds_per_process, 1024, 65536),
    max_fdinfo_files = positive_integer(
      "max_fdinfo_files", options.max_fdinfo_files, 32768, 1048576),
    max_fdinfo_bytes = positive_integer(
      "max_fdinfo_bytes", options.max_fdinfo_bytes, 256 * 1024, 64 * 1024 * 1024),
    max_clients = positive_integer("max_clients", options.max_clients, 8192, 262144),
    max_pci_ids_bytes = positive_integer(
      "max_pci_ids_bytes", options.max_pci_ids_bytes, 8 * 1024 * 1024, 64 * 1024 * 1024),
    pci_ids_paths = pci_ids_paths,
    _pci_name_cache = {},
    _method_style = true,
  }, GPU)
end

function GPU:probe(context)
  local fs = Common.fs(context, self.fs)
  local found, err = inventory(fs, self.drm_path, self.max_class_entries, self.max_cards, self.max_render_nodes)
  if not found then
    local status = FS.error_status(err)
    if status == "denied" then
      return Capability.denied(err.message, { source = self.drm_path })
    end
    return Capability.unavailable(err and err.message or "drm_unavailable", { source = self.drm_path })
  end
  if #found.cards == 0 then
    return Capability.unavailable("no_drm_card_devices", { source = self.drm_path })
  end
  return Capability.available({
    source = self.drm_path,
    details = { cards = #found.cards, render_nodes = #found.render_nodes, truncated = found.truncated },
  })
end

function GPU:sample(context, previous)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  if context and context.scan_gpu_processes ~= nil
      and type(context.scan_gpu_processes) ~= "boolean" then
    return Common.result("error", started, nil, {
      quality = "error", reason = "invalid_gpu_process_scan_policy", source = self.proc_path,
    })
  end
  local found, list_error = inventory(
    fs, self.drm_path, self.max_class_entries, self.max_cards, self.max_render_nodes
  )
  if not found then
    return Common.error_result(list_error, Common.now_ns(context), self.drm_path)
  end
  if #found.cards == 0 then
    local finished = Common.now_ns(context)
    return Common.result("unavailable", finished, nil, {
      quality = "unavailable",
      reason = "no_drm_card_devices",
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.drm_path,
    })
  end

  local devices = {}
  local by_id = {}
  local used_ids = {}
  local lookup = { by_bdf = {}, by_device_key = {}, by_driver = {}, by_node = {} }
  for _, card in ipairs(found.cards) do
    local device = build_device(self, fs, self.drm_path, card, used_ids)
    devices[#devices + 1] = device
    by_id[device.id] = device
    lookup.by_node[card] = device
    if device.pci_bdf then lookup.by_bdf[device.pci_bdf] = device end
    if device.device_target then lookup.by_device_key[device.device_target] = device end
    if device.driver then
      lookup.by_driver[device.driver] = lookup.by_driver[device.driver] or {}
      lookup.by_driver[device.driver][#lookup.by_driver[device.driver] + 1] = device
    end
  end
  local drm_scan = {
    truncated = found.truncated,
    unattached_render_nodes = 0,
    estimated_render_links = 0,
  }
  attach_render_nodes(fs, self.drm_path, found.render_nodes, devices, lookup, drm_scan)

  local previous_data = Common.previous_data(previous)
  local previous_scan = previous_data and previous_data.process_scan
  local process_previous = previous
  if (not previous_scan or previous_scan.enabled ~= true) and self._last_process_result then
    process_previous = self._last_process_result
  end
  local process_scan = scan_processes(self, fs, devices, lookup, process_previous, context)
  local partial = found.truncated or drm_scan.unattached_render_nodes > 0
    or process_scan.quality == "partial"
    or (process_scan.enabled and process_scan.status ~= "ok")
  local estimated = drm_scan.estimated_render_links > 0
  local truncated = found.truncated or process_scan.truncated
  for _, device in ipairs(devices) do
    finalize_processes(device, process_scan)
    estimated = estimated or device.identity_quality == "estimated"
    partial = partial or device.partial
    truncated = truncated or device.frequencies.truncated or device.hwmon_truncated
  end
  table.sort(devices, function(left, right)
    if left.id == right.id then return left.card < right.card end
    return left.id < right.id
  end)

  local finished = Common.now_ns(context)
  local result = Common.result("ok", finished, {
    schema = "dev.waterrun.wtop.gpu/v2",
    devices = devices,
    by_id = by_id,
    process_scan = process_scan,
    drm_scan = drm_scan,
    truncated = truncated,
  }, {
    quality = partial and "partial" or (estimated and "estimated" or "fresh"),
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = { self.drm_path, self.proc_path },
  })
  -- A transient /proc denial must not erase the last good counter baseline;
  -- otherwise the next successful deep scan reports a synthetic gap.
  if process_scan.enabled and process_scan.status == "ok" then
    self._last_process_result = result
  end
  return result
end

GPU.enumerate = enumerate
GPU.parse_fdinfo = parse_fdinfo
GPU.parse_pci_ids_name = parse_pci_ids_name
GPU.parse_dpm_states = parse_dpm_states

return GPU
