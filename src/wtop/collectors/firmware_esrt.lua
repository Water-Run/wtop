-- Linux's read-only UEFI ESRT inventory. Status codes describe a past capsule
-- attempt; code 0 can also mean no attempt was ever made.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local GUID = require("wtop.core.guid")
local FS = require("wtop.linux.fs")
local Platform = require("wtop.platform")

local FirmwareEsrt = {}
FirmwareEsrt.__index = FirmwareEsrt

local MAX_ENTRIES = 128
local MAX_DIRECTORY_ENTRIES = 256
local MAX_ISSUES = 128
local TYPES = { [0] = "Unknown", [1] = "System firmware",
  [2] = "Device firmware", [3] = "UEFI driver" }

local function decimal(raw, maximum)
  local text = Common.trim(raw)
  if type(text) ~= "string" or #text > 20 or not text:match("^%d+$") then return nil end
  local value = tonumber(text)
  if value and math.type(value) == "integer" and value >= 0 and value <= maximum then
    return value
  end
end

local function flags(raw)
  local text = Common.trim(raw)
  local digits = type(text) == "string" and text:match("^0[xX](%x+)$") or nil
  if not digits or #digits > 8 then return nil end
  local value = tonumber(digits, 16)
  return value and string.format("0x%x", value) or nil
end

local function issue(result, field, path, status, reason, entry)
  result.partial = true
  if entry then entry.quality = "partial" end
  if #result.issues < MAX_ISSUES then
    result.issues[#result.issues + 1] = { field = field, source = path,
      status = status, reason = reason }
  else result.issues_truncated = true end
end

local function read_value(fs, result, path, field, parser, entry)
  local raw, err = fs:read(path, 64)
  if not raw then
    issue(result, field, path, FS.error_status(err),
      err and err.message or "esrt_unreadable", entry)
    return nil, FS.error_status(err)
  end
  local value = parser(raw)
  if value == nil then
    issue(result, field, path, "error", "invalid_esrt_value", entry)
    return nil, "error"
  end
  return value, "ok"
end

function FirmwareEsrt.new(options)
  options = options or {}
  if type(options) ~= "table" then error("FirmwareEsrt options must be a table", 2) end
  return setmetatable({ id = "firmware_esrt", _method_style = true,
    fs = options.fs or FS.default,
    platform = options.platform or Platform.id(),
    base_path = Common.absolute_path("base_path", options.base_path,
      "/sys/firmware/efi/esrt"),
    max_entries = Common.positive_integer("max_entries", options.max_entries,
      MAX_ENTRIES, MAX_ENTRIES),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 60000),
  }, FirmwareEsrt)
end

function FirmwareEsrt:probe(context)
  if self.platform ~= "linux" then
    return Capability.unavailable("esrt_linux_only", { source = self.base_path })
  end
  local fs = Common.fs(context, self.fs)
  local entries, err = fs:list(self.base_path .. "/entries", 1)
  if not entries then
    local status = FS.error_status(err)
    if status == "denied" then
      return Capability.denied(err.message, { source = self.base_path })
    end
    return Capability.unavailable("no_esrt_entries", { source = self.base_path })
  end
  if #entries == 0 then
    return Capability.unavailable("no_esrt_entries", { source = self.base_path })
  end
  return Capability.available({ source = self.base_path })
end

function FirmwareEsrt:sample(context)
  local started = Common.now_ns(context)
  if self.platform ~= "linux" then
    return Common.result("unavailable", started, nil,
      { reason = "esrt_linux_only", source = self.base_path })
  end
  local fs = Common.fs(context, self.fs)
  local root = self.base_path
  local names, err, cut = fs:list(root .. "/entries", MAX_DIRECTORY_ENTRIES)
  if not names then return Common.error_result(err, Common.now_ns(context), root) end
  if #names == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { reason = "no_esrt_entries", source = root })
  end
  local data = { entries = {}, issues = {}, source = root,
    partial = false, truncated = cut == true }
  local seen_names, indices = {}, {}
  for _, name in ipairs(names) do
    local digits = type(name) == "string" and name:match("^entry(%d+)$")
    local index = digits and tonumber(digits)
    if index and index <= 65535 and tostring(index) == digits and not seen_names[index] then
      seen_names[index] = true
      indices[#indices + 1] = index
    else
      issue(data, "entry_name", root .. "/entries", "error", "invalid_esrt_entry")
    end
  end
  table.sort(indices)
  if #indices > self.max_entries or cut then
    data.truncated = true
    issue(data, "entry_limit", root .. "/entries", "error", "esrt_entry_limit")
  end
  data.scanned = math.min(#indices, self.max_entries)
  data.declared_count = read_value(fs, data, root .. "/fw_resource_count",
    "fw_resource_count", function(raw) return decimal(raw, MAX_ENTRIES) end)
  data.resource_version = read_value(fs, data, root .. "/fw_resource_version",
    "fw_resource_version", function(raw) return decimal(raw, 65535) end)
  if data.declared_count and data.declared_count ~= #indices and not data.truncated then
    issue(data, "fw_resource_count", root .. "/fw_resource_count",
      "error", "esrt_count_mismatch")
  end
  if data.resource_version and data.resource_version ~= 1 then
    issue(data, "fw_resource_version", root .. "/fw_resource_version",
      "error", "esrt_version_unknown")
  end
  local by_guid = {}
  for position = 1, data.scanned do
    local index = indices[position]
    local path = root .. "/entries/entry" .. index
    local entry = { id = "entry" .. index, index = index, source = path,
      quality = "fresh", status = "ok" }
    local guid, guid_status = read_value(fs, data, path .. "/fw_class", "fw_class",
      function(raw) return GUID.normalize(Common.trim(raw)) end, entry)
    entry.guid = guid
    if guid then
      local prior = by_guid[guid]
      if prior then
        prior.ambiguous, prior.quality, prior.status = true, "partial", "partial"
        entry.ambiguous = true
        issue(data, "fw_class", path .. "/fw_class", "error", "esrt_guid_duplicate", entry)
      else by_guid[guid] = entry end
      entry.type_code = read_value(fs, data, path .. "/fw_type", "fw_type",
        function(raw) return decimal(raw, 0xffffffff) end, entry)
      entry.type = TYPES[entry.type_code]
      entry.version = read_value(fs, data, path .. "/fw_version", "fw_version",
        function(raw) return decimal(raw, 0xffffffff) end, entry)
      entry.lowest_supported_version = read_value(fs, data,
        path .. "/lowest_supported_fw_version", "lowest_supported_fw_version",
        function(raw) return decimal(raw, 0xffffffff) end, entry)
      entry.capsule_flags_hex = read_value(fs, data, path .. "/capsule_flags",
        "capsule_flags", flags, entry)
      entry.last_attempt_version = read_value(fs, data,
        path .. "/last_attempt_version", "last_attempt_version",
        function(raw) return decimal(raw, 0xffffffff) end, entry)
      entry.last_attempt_status = read_value(fs, data,
        path .. "/last_attempt_status", "last_attempt_status",
        function(raw) return decimal(raw, 0xffffffff) end, entry)
      if entry.quality ~= "fresh" then entry.status = "partial" end
    else
      entry.status = guid_status
    end
    data.entries[#data.entries + 1] = entry
  end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, data, { source = root,
    quality = data.partial and "partial" or "fresh",
    reason = data.partial and "firmware_esrt_incomplete" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

return FirmwareEsrt
