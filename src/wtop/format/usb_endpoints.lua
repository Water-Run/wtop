-- Linux cached endpoint attributes describe an observed alternate setting.
-- They do not measure traffic or reveal SuperSpeed companion capabilities.
local Json = require("wtop.format.json")
local M = { MAX_PER_INTERFACE = 30, MAX_TOTAL = 256 }
local TYPES = { [0] = "control", "isochronous", "bulk", "interrupt" }
local STATES = { ok=true, fresh=true, partial=true, truncated=true, denied=true,
  unavailable=true, error=true, gap=true, stale=true }
local FIELDS = { "bLength", "bEndpointAddress", "bmAttributes", "wMaxPacketSize", "bInterval", "interval" }
local FIELD_SET = {}
for _, field in ipairs(FIELDS) do FIELD_SET[field] = true end
for _, field in ipairs({ "bInterfaceNumber", "bAlternateSetting", "bNumEndpoints", "endpoints", "entries" }) do
  FIELD_SET[field] = true
end

local function uint(value, maximum)
  return type(value) == "number" and value == value and value >= 0
    and value <= maximum and value % 1 == 0 and value or nil
end

function M.hex(raw, maximum)
  if type(raw) ~= "string" or #raw > 32 then return nil end
  local token = raw:match("^%s*(%x+)%s*$") or raw:match("^%s*0[xX](%x+)%s*$")
  if not token or #token > 8 then return nil end
  return uint(tonumber(token, 16), maximum)
end

local function issue(row, field, raw, invalid)
  local errors = type(raw.errors) == "table" and raw.errors or {}
  local errno = errors[field]
  local state = (errno == 1 or errno == 13) and "denied"
    or (errno == 2 or errno == 19 or errno == 61) and "unavailable"
    or (errno ~= nil or invalid) and "error" or "unavailable"
  row.issues[#row.issues + 1] = { field = field, status = state, invalid = invalid == true }
end

local function endpoint(raw, source)
  if type(raw) ~= "table" or type(raw.name) ~= "string"
      or not raw.name:match("^ep_[08][0-9a-f]$") or raw.name:sub(-1) == "0" then return nil end
  local row = { id = raw.name, source = source .. "/" .. raw.name, issues = {} }
  local function value(field, maximum)
    local parsed = M.hex(raw[field], maximum)
    if parsed == nil then issue(row, field, raw, raw[field] ~= nil) end
    return parsed
  end
  row.descriptor_length = value("bLength", 255)
  if row.descriptor_length and row.descriptor_length < 7 then
    row.descriptor_length = nil; issue(row, "bLength", raw, true)
  end
  row.address = value("bEndpointAddress", 255)
  if row.address and row.address ~= tonumber(raw.name:sub(4), 16) then
    row.address = nil; issue(row, "bEndpointAddress", raw, true)
  end
  row.number = row.address and row.address & 15 or nil
  row.attributes = value("bmAttributes", 255)
  row.transfer_type = row.attributes and TYPES[row.attributes & 3] or nil
  row.direction = row.transfer_type == "control" and "both"
    or row.address and (row.address & 128 ~= 0 and "in" or "out") or nil
  row.max_packet_sysfs_value = value("wMaxPacketSize", 65535)
  row.max_packet_bytes = row.max_packet_sysfs_value and row.max_packet_sysfs_value & 2047 or nil
  -- New kernels mask the transaction bits before publishing wMaxPacketSize.
  row.additional_transactions_known = false
  row.interval_code = value("bInterval", 255)
  local interval, unit
  if type(raw.interval) == "string" and #raw.interval <= 32 then
    interval, unit = raw.interval:match("^%s*(%d+)([um])s%s*$")
    interval = interval and #interval <= 10 and uint(tonumber(interval), 4294967295) or nil
  end
  if interval ~= nil then
    row.interval_microseconds = interval * (unit == "m" and 1000 or 1)
    row.interval_basis = "kernel_speed_decoded"
  else issue(row, "interval", raw, raw.interval ~= nil) end
  row.status, row.quality = "ok", "fresh"
  if #row.issues > 0 then row.status, row.quality = "partial", "partial" end
  return row
end

function M.unavailable(failure, source)
  local kind = type(failure) == "table" and failure.kind
  local state = kind == "changed" and "gap" or kind == "denied" and "denied"
    or (kind == "unavailable" or kind == "missing") and "unavailable" or "error"
  return { status = state, quality = state, source = source,
    scope = "observed_interface_alternate", guarded = false }
end

function M.decode(raw, source, limit)
  if type(raw) ~= "table" or raw.guarded ~= true or type(raw.fields) ~= "table"
      or type(raw.endpoints) ~= "table" or not uint(raw.total, 30)
      or type(raw.total_known) ~= "boolean" then
    return M.unavailable({}, source)
  end
  limit = math.min(M.MAX_PER_INTERFACE, uint(limit, M.MAX_PER_INTERFACE) or M.MAX_PER_INTERFACE)
  local result = { status = "ok", quality = "fresh", source = source,
    scope = "observed_interface_alternate", guarded = true, list = {},
    total = raw.total_known and raw.total or nil, observed_count = raw.total, total_known = raw.total_known,
    truncated = raw.truncated == true or #raw.endpoints > limit,
    issues = {}, interface_number = M.hex(raw.fields.bInterfaceNumber, 255),
    alternate_setting = M.hex(raw.fields.bAlternateSetting, 255),
    declared_count = M.hex(raw.fields.bNumEndpoints, 30) }
  for _, pair in ipairs({ { "bInterfaceNumber", "interface_number" },
      { "bAlternateSetting", "alternate_setting" }, { "bNumEndpoints", "declared_count" } }) do
    if result[pair[2]] == nil then issue(result, pair[1], raw.fields, raw.fields[pair[1]] ~= nil) end
  end
  local seen = {}
  for index = 1, math.min(#raw.endpoints, limit) do
    local row = endpoint(raw.endpoints[index], source)
    if row and not seen[row.id] then
      result.list[#result.list + 1] = row; seen[row.id] = true
      if row.quality ~= "fresh" then result.status = "partial" end
    else issue(result, "endpoints", {}, true) end
  end
  if raw.malformed_entries == true then issue(result, "entries", {}, true) end
  if raw.total < #result.list or (not result.truncated and raw.total ~= #result.list)
      or (result.declared_count ~= nil and raw.total_known and raw.total ~= result.declared_count) then
    issue(result, "bNumEndpoints", {}, true)
  end
  if #result.issues > 0 or result.status == "partial" then
    result.status, result.quality = "partial", "partial"
  elseif result.truncated then result.quality = "truncated" end
  return result
end

local function issues(source)
  local result = Json.array({})
  for index, entry in ipairs(type(source) == "table" and source or {}) do
    if index > 8 then break end
    if type(entry) == "table" and FIELD_SET[entry.field] and STATES[entry.status] then
      result[#result + 1] = { field = entry.field, status = entry.status, invalid = entry.invalid == true }
    end
  end
  return result
end

-- Shared explicit whitelist: nested raw fields and vendor payloads stay private.
function M.public(source, stale, limit)
  if type(source) ~= "table" then return nil end
  local result = { scope = "observed_interface_alternate", guarded = source.guarded == true,
    status = STATES[source.status] and source.status or "error",
    quality = stale and "stale" or STATES[source.quality] and source.quality or "error",
    observation_current = not stale and source.guarded == true, issues = issues(source.issues) }
  if type(source.source) == "string" and #source.source <= 4096 then result.source = source.source end
  result.total_known = source.total_known == true
  for _, name in ipairs({ "total", "observed_count", "declared_count", "interface_number", "alternate_setting" }) do
    if name ~= "total" or result.total_known then
      result[name] = uint(source[name], (name == "interface_number" or name == "alternate_setting") and 255 or 30)
    end
  end
  result.truncated = source.truncated == true
  if type(source.list) ~= "table" then return result end
  limit = math.min(30, uint(limit, 30) or 30)
  result.list = Json.array({})
  local numeric = { address=255, number=15, attributes=255, max_packet_sysfs_value=65535,
    max_packet_bytes=2047, interval_code=255, interval_microseconds=4294967295000, descriptor_length=255 }
  local directions = { ["in"]=true, out=true, both=true }
  local types = { control=true, isochronous=true, bulk=true, interrupt=true }
  for index, entry in ipairs(source.list) do
    if index > limit then result.truncated = true break end
    if type(entry) == "table" and type(entry.id) == "string" and entry.id:match("^ep_[08][0-9a-f]$")
        and entry.id:sub(-1) ~= "0" then
      local row = { id = entry.id, status = STATES[entry.status] and entry.status or "error",
        quality = stale and "stale" or STATES[entry.quality] and entry.quality or "error",
        issues = issues(entry.issues), additional_transactions_known = false }
      for field, maximum in pairs(numeric) do row[field] = uint(entry[field], maximum) end
      if types[entry.transfer_type] then row.transfer_type = entry.transfer_type end
      if directions[entry.direction] then row.direction = entry.direction end
      if entry.interval_basis == "kernel_speed_decoded" then row.interval_basis = entry.interval_basis end
      if type(entry.source) == "string" and #entry.source <= 4096 then row.source = entry.source end
      result.list[#result.list + 1] = row
    end
  end
  if result.truncated and result.quality == "fresh" then result.quality = "truncated" end
  return result
end
return M
