local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Decoder = require("wtop.format.spd")

local SPD = {}
SPD.__index = SPD

local function legacy_eeprom_header(fs, path)
  local bytes = fs:read_at(path .. "/eeprom", 0, 64)
  if type(bytes) ~= "string" or #bytes < 3 then return nil end
  local used, total, memory_type = bytes:byte(1, 3)
  if used >= 64 and used <= 128 and (total == 7 or total == 8)
      and (memory_type == 0x01 or memory_type == 0x02
        or memory_type == 0x04 or memory_type == 0x07 or memory_type == 0x08) then
    return total == 7 and 128 or 256
  end
end

local function discover(self, fs)
  local names, err, truncated = fs:list(self.base_path, self.max_entries + 1)
  if not names then return nil, err end
  local devices, issues, legacy_probes = {}, {}, 0
  for index, name in ipairs(names) do
    if index > self.max_entries then truncated = true; break end
    local bus, address
    if type(name) == "string" then bus, address = name:match("^(%d+)%-(%x%x%x%x)$") end
    if bus and tonumber(bus) <= 65535 and tonumber(address, 16) >= 0x50
        and tonumber(address, 16) <= 0x57 then
      local path = self.base_path .. "/" .. name
      local driver, read_error = fs:read(path .. "/name", 128)
      driver = driver and Common.trim(driver)
      local eligible = driver == "spd5118" or driver == "ee1004" or driver == "spd"
      local legacy_size
      if driver == "eeprom" then
        -- The old driver also binds unrelated chips in this address range.
        -- Read only a bounded header before treating one as a memory module.
        if legacy_probes < self.max_devices then
          legacy_probes = legacy_probes + 1
          legacy_size = legacy_eeprom_header(fs, path)
          eligible = legacy_size ~= nil
        else
          truncated = true
        end
      end
      if eligible then
        if #devices < self.max_devices then
          devices[#devices + 1] = { id = name, path = path,
            driver = driver, size = legacy_size }
        else truncated = true end
      elseif not driver and read_error and read_error.kind ~= "missing" then
        issues[#issues + 1] = { field = "name", source = path .. "/name",
          status = FS.error_status(read_error), reason = read_error.message }
      end
    end
  end
  table.sort(devices, function(a, b) return a.id < b.id end)
  return devices, nil, truncated == true, issues
end

local function first_denied(issues)
  for _, issue in ipairs(issues or {}) do
    if issue.status == "denied" then return issue end
  end
end

function SPD.new(options)
  options = options or {}
  if type(options) ~= "table" then error("SPD options must be a table", 2) end
  return setmetatable({ id = "spd", _method_style = true,
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/bus/i2c/devices"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 60000),
    max_entries = Common.positive_integer("max_entries", options.max_entries, 4096, 65536),
    max_devices = Common.positive_integer("max_devices", options.max_devices, 64, 256),
  }, SPD)
end

function SPD:probe(context)
  local devices, err, truncated, issues = discover(self, Common.fs(context, self.fs))
  if devices and #devices > 0 then return Capability.available({ source = self.base_path }) end
  if err and FS.error_status(err) == "denied" then
    return Capability.denied(err.message, { source = self.base_path })
  end
  local denied = first_denied(issues)
  if denied then
    return Capability.denied("spd_access_denied", { source = self.base_path })
  end
  return Capability.unavailable(truncated and "spd_scan_truncated" or "no_spd_devices",
    { source = self.base_path })
end

function SPD:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local devices, err, truncated, issues = discover(self, fs)
  if not devices then return Common.error_result(err, Common.now_ns(context), self.base_path) end
  if #devices == 0 then
    local denied = first_denied(issues)
    return Common.result(denied and "denied" or "unavailable", Common.now_ns(context), nil,
      { source = self.base_path, reason = denied and "spd_access_denied"
          or truncated and "spd_scan_truncated" or "no_spd_devices" })
  end
  local data = { devices = {}, issues = issues, truncated = truncated, source = self.base_path }
  for _, entry in ipairs(devices) do
    local item = { id = entry.id, driver = entry.driver,
      source = entry.path .. "/eeprom", issues = {} }
    local chunks = {}
    local bytes_read = 0
    local size = entry.size or (entry.driver == "spd" and 256)
      or entry.driver == "ee1004" and 512 or 1024
    for offset = 0, size - 128, 128 do
      local bytes, read_error = fs:read_at(item.source, offset, 128)
      if not bytes or #bytes == 0 then
        item.issues[#item.issues + 1] = { field = "eeprom", source = item.source,
          offset = offset, status = FS.error_status(read_error),
          errno = read_error and read_error.errno,
          reason = read_error and "spd_data_incomplete" or "short_spd_read" }
        break
      end
      chunks[#chunks + 1] = bytes
      bytes_read = bytes_read + #bytes
      if #bytes < 128 then
        item.issues[#item.issues + 1] = { field = "eeprom", source = item.source,
          offset = offset + #bytes, status = "error", reason = "short_spd_read" }
        break
      end
    end
    item.bytes_read = bytes_read
    local parsed, reason = Decoder.parse(table.concat(chunks))
    if parsed then
      for key, value in pairs(parsed) do item[key] = value end
      if parsed.crc_valid == false or parsed.crc_base_valid == false then
        item.issues[#item.issues + 1] = { field = "crc", source = item.source,
          status = "error", reason = "spd_crc_mismatch" }
      end
      if parsed.checksum_valid == false then
        item.issues[#item.issues + 1] = { field = "checksum", source = item.source,
          status = "error", reason = "spd_checksum_mismatch" }
      end
    else
      item.issues[#item.issues + 1] = { field = "format", source = item.source,
        status = "error", reason = reason }
    end
    item.quality = #item.issues > 0 and "partial" or "fresh"
    data.devices[#data.devices + 1] = item
  end
  local partial = data.truncated or #data.issues > 0
  for _, device in ipairs(data.devices) do partial = partial or device.quality == "partial" end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, data, { source = self.base_path,
    quality = partial and "partial" or "fresh",
    reason = partial and "spd_data_incomplete" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

return SPD
