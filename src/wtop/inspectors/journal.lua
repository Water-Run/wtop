-- Bounded current-boot journal reads, requested from verified unit details.
local Clock = require("wtop.core.clock")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local JSON = require("wtop.core.json")
local Native = require("wtop.native")
local Platform = require("wtop.platform")
local Runner = require("wtop.core.runner")
local Systemd = require("wtop.inspectors.systemd")

local Journal = {}
Journal.__index = Journal
local MAX_BYTES, MAX_ENTRIES, MAX_MESSAGE = 512 * 1024, 100, 4096

local function integer(value, maximum)
  if type(value) == "string" and #value <= 20 and value:match("^%d+$") then value = tonumber(value) end
  return type(value) == "number" and math.type(value) == "integer"
    and value >= 0 and value <= maximum and value or nil
end

local function boot_id(value)
  if type(value) ~= "string" then return nil end
  value = value:match("^%s*(.-)%s*$")
  if #value ~= 32 and #value ~= 36 then return nil end
  if #value == 36 and not value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
    return nil
  end
  value = value:gsub("%-", "")
  return #value == 32 and value:match("^%x+$") and value:lower() or nil
end

local function target_from_result(result)
  local entity = type(result) == "table" and result.status == "ok" and result.entity
  local identity = type(entity) == "table" and entity.kind == "service" and entity.identity
  local summary = entity and entity.summary
  if type(identity) ~= "table" or not Systemd.unit_name(identity.unit)
      or (identity.manager ~= "system" and identity.manager ~= "user")
      or type(summary) ~= "table" or not summary.unit or summary.unit.value ~= identity.unit
      or not summary.manager or summary.manager.value ~= identity.manager then return nil end
  if identity.manager == "user" and integer(identity.uid, 4294967295) == nil then return nil end
  return { unit = identity.unit, manager = identity.manager,
    uid = identity.manager == "user" and integer(identity.uid, 4294967295) or nil,
    kind = Systemd.unit_name(identity.unit) }
end

local function relation(raw, target)
  if target.manager == "user" then
    if integer(raw._UID, 4294967295) == 0 and raw.COREDUMP_USER_UNIT == target.unit
        and integer(raw.COREDUMP_UID, 4294967295) == target.uid then return "referenced" end
    if integer(raw._UID, 4294967295) ~= target.uid then return nil end
    if raw._SYSTEMD_USER_UNIT == target.unit then return "emitted" end
    if target.kind == "slice" and raw._SYSTEMD_USER_SLICE == target.unit then return "member" end
    if raw.USER_UNIT == target.unit or raw.COREDUMP_USER_UNIT == target.unit then return "referenced" end
  else
    if raw._SYSTEMD_UNIT == target.unit then return "emitted" end
    if target.kind == "slice" and raw._SYSTEMD_SLICE == target.unit then return "member" end
    if integer(raw._UID, 4294967295) == 0
        and (raw.UNIT == target.unit or raw.COREDUMP_UNIT == target.unit) then return "referenced" end
  end
end

local function message_text(value)
  value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
  local parts, remaining, clipped = {}, MAX_MESSAGE, #value > MAX_MESSAGE
  value = value:sub(1, MAX_MESSAGE)
  for line in (value .. "\n"):gmatch("(.-)\n") do
    if remaining < 1 then clipped = true break end
    local expanded = line:gsub("\t", "  "):gsub("[%z\1-\31\127]", "�")
    if #expanded > remaining then clipped = true end
    local safe = Common.safe_text(expanded, remaining)
    parts[#parts + 1] = safe
    remaining = remaining - #safe - 1
    if #line > #safe then clipped = true end
  end
  return table.concat(parts, "\n"), clipped
end

function Journal.parse(raw, target, current_boot, maximum)
  maximum = Common.positive_integer("max_entries", maximum, MAX_ENTRIES, MAX_ENTRIES)
  if type(raw) ~= "string" or #raw > MAX_BYTES or not boot_id(current_boot)
      or type(target) ~= "table" or not Systemd.unit_name(target.unit)
      or (target.manager ~= "system" and target.manager ~= "user")
      or (target.manager == "user" and integer(target.uid, 4294967295) == nil) then return nil end
  current_boot = boot_id(current_boot)
  target = { unit = target.unit, manager = target.manager,
    uid = target.manager == "user" and integer(target.uid, 4294967295) or nil,
    kind = Systemd.unit_name(target.unit) }
  local data = { entries = {}, partial = false, truncated = false,
    rejected = 0, decoded = 0, max_entries = maximum }
  local seen = {}
  for line in raw:gmatch("[^\n]+") do
    local value = JSON.decode(line, { max_bytes = 65536, max_depth = 16, max_nodes = 12000 })
    local kind = type(value) == "table" and relation(value, target)
    if type(value) ~= "table" or not kind or value._BOOT_ID ~= current_boot then
      data.partial, data.rejected = true, data.rejected + 1
    else
      data.decoded = data.decoded + 1
      if #data.entries >= maximum then data.truncated = true break end
      local timestamp = integer(value.__REALTIME_TIMESTAMP, math.maxinteger)
      local cursor = type(value.__CURSOR) == "string" and #value.__CURSOR <= 2048
        and not value.__CURSOR:find("[%z\1-\31\127]") and value.__CURSOR or nil
      if cursor and seen[cursor] then
        data.partial, data.rejected = true, data.rejected + 1
      else
        if cursor then seen[cursor] = true end
        local entry = { id = cursor or tostring(timestamp or "unknown") .. ":" .. data.decoded,
          timestamp_us = timestamp, priority = integer(value.PRIORITY, 7),
          pid = integer(value._PID, 2147483647), uid = integer(value._UID, 4294967295),
          identifier = Common.safe_text(value.SYSLOG_IDENTIFIER, 128), relation = kind,
          unit = Common.safe_text(value._SYSTEMD_USER_UNIT or value._SYSTEMD_UNIT, 255),
          quality = "fresh" }
        if type(value.MESSAGE) == "string" then
          entry.message, entry.message_truncated = message_text(value.MESSAGE)
          if entry.message_truncated then entry.quality = "partial" end
        elseif type(value.MESSAGE) == "table" and value.MESSAGE ~= JSON.null then
          entry.message_kind = "binary_or_multiple"
          entry.quality = "partial"
        else
          entry.message_kind = "unavailable"
          entry.quality = "partial"
        end
        if not timestamp or entry.priority == nil then entry.quality = "partial" end
        if entry.quality ~= "fresh" then data.partial = true end
        data.entries[#data.entries + 1] = entry
      end
    end
  end
  -- journalctl --reverse orders the query, but numeric timestamps also keep
  -- injected and older-provider output in a consistent newest-first order.
  table.sort(data.entries, function(left, right)
    if left.timestamp_us ~= right.timestamp_us then
      return (left.timestamp_us or -1) > (right.timestamp_us or -1)
    end
    return left.id < right.id
  end)
  return data
end

function Journal.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Journal options must be a table", 2) end
  local user_id = options.uid
  if user_id == nil and type(Native.uid) == "function" then
    local ok, real, effective = pcall(Native.uid)
    if ok then user_id = integer(effective, 4294967295) or integer(real, 4294967295) end
  end
  if user_id ~= nil and (type(user_id) ~= "number" or integer(user_id, 4294967295) == nil) then
    error("invalid journal user ID", 2)
  end
  return setmetatable({ platform = options.platform or Platform.id(), uid = user_id,
    journalctl = Common.absolute_path("journalctl", options.journalctl, "/usr/bin/journalctl"),
    fs = options.fs or FS.default, runner = options.runner or Runner.new(), clock = options.clock or Clock.default,
    max_entries = Common.positive_integer("max_entries", options.max_entries, MAX_ENTRIES, MAX_ENTRIES),
    timeout_ms = Common.positive_integer("timeout_ms", options.timeout_ms, 1000, 2000),
  }, Journal)
end

function Journal:read(context, result)
  context = type(context) == "table" and context or {}
  local started = Common.now_ns(context, self.clock)
  local function failure(status, reason)
    return Common.result(status, Common.now_ns(context, self.clock), nil,
      { reason = reason, source = self.journalctl })
  end
  local target = target_from_result(result)
  if not target then return failure("unavailable", "journal_unit_unverified") end
  if self.platform ~= "linux" or context.safe_mode == true then
    return failure("unavailable", "journal_unavailable")
  end
  if target.manager == "user" and (self.uid == nil or target.uid ~= self.uid) then
    return failure("unavailable", "journal_user_unavailable")
  end
  local fs = context.fs or self.fs
  if not fs:exists(self.journalctl) then return failure("unavailable", "journalctl_unavailable") end
  local called, raw_boot = pcall(fs.read, fs, "/proc/sys/kernel/random/boot_id", 64)
  local current_boot = called and boot_id(raw_boot)
  if not current_boot then return failure("unavailable", "journal_boot_unavailable") end
  -- No pager, no follow mode and no --all: the provider's field-size cap stays
  -- in force. Select the exact canonical name and the current kernel boot.
  local argv = { self.journalctl, "--no-pager", "--reverse", "--output=json",
    "--lines=" .. (self.max_entries + 1), "--boot=" .. current_boot }
  if target.manager == "user" then
    argv[#argv + 1] = "--user-unit=" .. target.unit
  else
    argv[#argv + 1] = "--system"
    argv[#argv + 1] = "--unit=" .. target.unit
  end
  local ok, run = pcall(self.runner.run, self.runner, argv,
    { timeout_ms = self.timeout_ms, max_output_bytes = MAX_BYTES, env = { LANG = "C", LC_ALL = "C" } })
  if not ok or type(run) ~= "table" then return failure("error", "journal_unavailable") end
  local stderr = type(run.stderr) == "string" and run.stderr:lower() or ""
  local access_limited = stderr:find("not seeing messages", 1, true) ~= nil
    or stderr:find("insufficient permissions", 1, true) ~= nil
    or stderr:find("permission denied", 1, true) ~= nil
    or stderr:find("access denied", 1, true) ~= nil
  if run.status ~= "ok" or type(run.stdout) ~= "string" then
    return failure((run.status == "denied" or access_limited) and "denied" or "unavailable",
      (run.status == "denied" or access_limited) and "journal_access_limited" or "journal_unavailable")
  end
  if stderr:find("no journal files were found", 1, true) then
    return failure("unavailable", "journal_unavailable")
  end
  local output = run.stdout
  if run.truncated then output = output:match("^(.*)\n") or "" end
  local data = Journal.parse(output, target, current_boot, self.max_entries)
  if not data then return failure("error", "journal_data_invalid") end
  if data.decoded == 0 and data.rejected > 0 then return failure("error", "journal_data_invalid") end
  data.truncated = data.truncated or run.truncated == true
  data.access_limited = access_limited
  data.unit, data.manager = target.unit, target.manager
  data.uid = target.uid
  local partial = data.partial or data.truncated or access_limited
  local finished = Common.now_ns(context, self.clock)
  return Common.result("ok", finished, data, { source = self.journalctl,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    quality = partial and "partial" or "fresh",
    reason = access_limited and "journal_access_limited"
      or data.truncated and "journal_data_truncated"
      or data.partial and "journal_data_partial" or nil })
end

Journal.target_from_result = target_from_result
Journal.boot_id = boot_id
return Journal
