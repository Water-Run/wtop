-- Shared, bounded SMBIOS table input for firmware-backed collectors.
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local SMBIOS = require("wtop.format.smbios")

local M = {}

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do result[key] = copy(item, seen) end
  return result
end

-- Retain one filtered public revision per provider, not raw firmware or a
-- hash of private identifiers. Reads and parsing still happen afresh. Stable
-- tokens let independently scheduled views recognize unchanged declarations.
local revisions = setmetatable({}, { __mode = "k" })
local function equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
  for key in pairs(right) do if left[key] == nil then return false end end
  return true
end

local function revision_token(collector, provider, input, parsed)
  if not parsed or type(provider) ~= "table" then return {} end
  local failure = input.metadata_error
  local status = failure and FS.error_status(failure) or nil
  local reason = type(failure) == "table" and failure.message or nil
  local prior = revisions[provider]
  if prior and prior.platform == collector.platform and prior.base_path == collector.base_path
      and prior.source == input.source and prior.metadata_status == status
      and prior.metadata_reason == reason and equal(prior.public, parsed) then return prior.token end
  local token = {}
  revisions[provider] = { platform = collector.platform, base_path = collector.base_path,
    source = input.source, metadata_status = status, metadata_reason = reason,
    public = copy(parsed), token = token }
  return token
end

function M.read(collector, context)
  if context and context.smbios_input and collector.platform == "linux" then
    return context.smbios_input:read(collector, context)
  end
  if collector.platform == "linux" then
    local fs = Common.fs(context, collector.fs)
    local source = collector.base_path .. "/DMI"
    local data, failure = fs:read(source, SMBIOS.MAX_BYTES)
    if not data then
      return nil, Common.error_result(failure, Common.now_ns(context), source)
    end
    local entry, entry_error = fs:read(collector.base_path .. "/smbios_entry_point", 512)
    local metadata, metadata_error
    if entry then
      metadata, metadata_error = SMBIOS.entry_point(entry)
      if not metadata then
        return nil, Common.result("error", Common.now_ns(context), nil,
          { reason = metadata_error, source = source })
      end
    else
      metadata_error = entry_error or { kind = "unavailable", message = "smbios_unavailable" }
    end
    return { data = data, metadata = metadata, source = source,
      metadata_error = metadata_error }
  end
  local source = "native:read_smbios"
  local backend = context and context.native or collector.native
  if type(backend.read_smbios) ~= "function" then
    return nil, Common.result("unavailable", Common.now_ns(context), nil,
      { reason = "smbios_unavailable", source = source })
  end
  local ok, payload, reason, status = pcall(backend.read_smbios)
  if not ok or type(payload) ~= "table" or type(payload.data) ~= "string" then
    return nil, Common.result(not ok and "error" or status == "denied" and "denied"
      or status == "error" and "error" or "unavailable", Common.now_ns(context), nil,
      { reason = ok and type(reason) == "string" and reason or "smbios_unavailable",
        source = source })
  end
  return { data = payload.data, source = source,
    metadata = { major = payload.major, minor = payload.minor, docrev = payload.docrev } }
end

-- One scheduler probe or sampling pass can ask several collectors for the same
-- static table. Keep the read and decode scoped to that pass; each consumer
-- gets its own record tables because it attaches source and quality details.
-- Direct collector calls without a scheduler batch still read afresh.
function M.load(collector, context)
  local batch = context and type(context._collector_batch) == "table"
    and context._collector_batch or nil
  local entries = batch and batch.smbios or nil
  local provider = collector.platform == "linux"
    and (context and context.smbios_input or Common.fs(context, collector.fs))
    or context and context.native or collector.native
  if entries then
    for _, entry in ipairs(entries) do
      if entry.platform == collector.platform and entry.base_path == collector.base_path
          and entry.provider == provider then
        return entry.input, copy(entry.parsed), entry.reason, nil, entry.cohort
      end
    end
  end
  local input, read_error = M.read(collector, context)
  if not input then return nil, nil, nil, read_error end
  local parsed, reason = SMBIOS.parse(input.data, input.metadata)
  local cohort = revision_token(collector, provider, input, parsed)
  if batch then
    entries = entries or {}
    batch.smbios = entries
    entries[#entries + 1] = { platform = collector.platform,
      base_path = collector.base_path, provider = provider,
      input = input, parsed = parsed, reason = reason, cohort = cohort }
    return input, copy(parsed), reason, nil, cohort
  end
  return input, parsed, reason, nil, cohort
end

function M.attach_metadata_issue(parsed, input, base_path)
  if not input.metadata_error then return end
  parsed.partial = true
  parsed.issues[#parsed.issues + 1] = { field = "entry_point",
    source = base_path .. "/smbios_entry_point",
    status = FS.error_status(input.metadata_error),
    reason = input.metadata_error.message }
end

return M
