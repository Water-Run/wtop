-- Linux TPM class metadata. PCR values and endorsement material are never read.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")

local TPM = {}
TPM.__index = TPM

local function names(fs, base, maximum)
  local entries, err, cut = fs:list(base, 256)
  if not entries then return nil, err end
  local result = {}
  for _, name in ipairs(entries) do
    local digits = type(name) == "string" and name:match("^tpm(%d+)$")
    local index = digits and tonumber(digits)
    if index and index <= 65535 and name == "tpm" .. tostring(index) then
      result[#result + 1] = { id = name, index = index }
    end
  end
  table.sort(result, function(a, b) return a.index < b.index end)
  return result, nil, cut == true or #result > maximum
end

local function issue(issues, field, source, error, reason)
  if #issues >= 64 then return end
  issues[#issues + 1] = { field = field, source = source,
    status = FS.error_status(error), reason = reason or error and error.message or "invalid_tpm_value" }
end

local function optional_flag(fs, path, field, issues)
  local raw, err = fs:read(path, 32)
  if raw == nil then
    if err and (err.kind == "missing" or err.kind == "unavailable") then return nil end
    issue(issues, field, path, err)
    return nil
  end
  local value = Common.trim(raw)
  if value == "0" then return false end
  if value == "1" then return true end
  issue(issues, field, path, { kind = "parse_error" }, "invalid_tpm_value")
end

local function read_bank(fs, path, name, issues)
  local bank_path = path .. "/pcr-" .. name
  local entries, err, cut = fs:list(bank_path, 64)
  if not entries then
    issue(issues, "pcr_bank", bank_path, err)
    return { algorithm = name, pcr_count = nil }, false
  end
  local count, seen = 0, {}
  for _, entry in ipairs(entries) do
    local number = type(entry) == "string" and entry:match("^%d+$")
      and tonumber(entry) or nil
    if number and number <= 65535 and entry == tostring(number) and not seen[number] then
      seen[number] = true
      count = count + 1
    end
  end
  return { algorithm = name, pcr_count = count }, cut == true or count > 64
end

function TPM.new(options)
  options = options or {}
  if type(options) ~= "table" then error("TPM options must be a table", 2) end
  return setmetatable({ id = "tpm", _method_style = true,
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/class/tpm"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 60000),
    max_devices = Common.positive_integer("max_devices", options.max_devices, 16, 64),
    max_banks = Common.positive_integer("max_banks", options.max_banks, 16, 64),
  }, TPM)
end

function TPM:probe(context)
  local devices, err = names(Common.fs(context, self.fs), self.base_path, self.max_devices)
  if devices and #devices > 0 then return Capability.available({ source = self.base_path }) end
  if err and FS.error_status(err) == "denied" then
    return Capability.denied(err.message, { source = self.base_path })
  end
  return Capability.unavailable("no_tpm_devices", { source = self.base_path })
end

function TPM:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local ids, err, truncated = names(fs, self.base_path, self.max_devices)
  if not ids then return Common.error_result(err, Common.now_ns(context), self.base_path) end
  if #ids == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { source = self.base_path, reason = "no_tpm_devices" })
  end
  local data = { devices = {}, issues = {}, truncated = truncated == true,
    source = self.base_path }
  for index = 1, math.min(#ids, self.max_devices) do
    local id = ids[index].id
    local path = self.base_path .. "/" .. id
    local device = { id = id, index = ids[index].index, source = path,
      banks = {}, issues = {} }
    local raw, version_error = fs:read(path .. "/tpm_version_major", 32)
    local version = raw and Common.trim(raw)
    local major = version and version:match("^%d+$") and tonumber(version) or nil
    if major and major >= 1 and major <= 255 and math.type(major) == "integer" then
      device.version_major = major
    else
      if version_error and version_error.kind == "missing" then
        local caps = fs:read(path .. "/device/caps", 512)
        local old_major, old_minor
        if type(caps) == "string" then
          old_major, old_minor = caps:match("TCG version:%s*(%d+)%.(%d+)")
        end
        old_major, old_minor = tonumber(old_major), tonumber(old_minor)
        if old_major and old_major >= 1 and old_major <= 255
            and old_minor and old_minor >= 0 and old_minor <= 255 then
          device.version_major = old_major
          device.version_minor = old_minor
          device.version_source = "caps"
        end
      end
      if not device.version_major then
        issue(device.issues, "version_major", path .. "/tpm_version_major",
          version_error or { kind = "parse_error" }, "invalid_tpm_version")
      end
    end
    local driver_target = fs:readlink(path .. "/device/driver")
    local driver = type(driver_target) == "string" and driver_target:match("/([^/]+)$")
    if driver and #driver <= 64 and driver:match("^[%w_.-]+$") then
      device.driver = driver
    end
    device.active = optional_flag(fs, path .. "/device/active", "active", device.issues)
    device.enabled = optional_flag(fs, path .. "/device/enabled", "enabled", device.issues)
    device.temporarily_deactivated = optional_flag(fs,
      path .. "/device/temp_deactivated", "temporarily_deactivated", device.issues)
    local entries, bank_error, bank_cut = fs:list(path, 256)
    if entries then
      for _, name in ipairs(entries) do
        local algorithm = type(name) == "string" and name:match("^pcr%-([-a-z0-9_]+)$")
        if algorithm and #algorithm <= 32 then
          if #device.banks < self.max_banks then
            local bank, cut = read_bank(fs, path, algorithm, device.issues)
            device.banks[#device.banks + 1] = bank
            if cut then device.truncated = true; data.truncated = true end
          else device.truncated = true; data.truncated = true end
        end
      end
      table.sort(device.banks, function(a, b) return a.algorithm < b.algorithm end)
      if bank_cut then device.truncated = true; data.truncated = true end
    else
      issue(device.issues, "pcr_banks", path, bank_error)
    end
    device.quality = (#device.issues > 0 or device.truncated) and "partial" or "fresh"
    for _, item in ipairs(device.issues) do
      if #data.issues < 64 then data.issues[#data.issues + 1] = item end
    end
    data.devices[#data.devices + 1] = device
  end
  data.partial = #data.issues > 0
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, data, {
    quality = (data.partial or data.truncated) and "partial" or "fresh",
    reason = (data.partial or data.truncated) and "tpm_data_incomplete" or nil,
    source = self.base_path,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
  })
end

return TPM
