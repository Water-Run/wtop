-- Read-only logind sessions. No login records enter the background snapshot.
local Capability = require("wtop.core.capability")
local Clock = require("wtop.core.clock")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local GUID = require("wtop.core.guid")
local Model = require("wtop.inspectors.model")
local Platform = require("wtop.platform")
local Runner = require("wtop.core.runner")

local Logind = {}
Logind.__index = Logind
local MAX_SESSIONS, MAX_BYTES = 128, 256 * 1024
local PROPERTIES = { "Id", "User", "Name", "Timestamp", "TimestampMonotonic", "Leader",
  "Seat", "TTY", "Remote", "Service", "Type", "Class", "Active", "State",
  "IdleHint", "Scope" }
local NUMERIC = { User = 4294967295, TimestampMonotonic = math.maxinteger,
  Leader = 2147483647 }
local BOOLEAN = { Remote = true, Active = true, IdleHint = true }
local ALLOWED = {}
for _, name in ipairs(PROPERTIES) do ALLOWED[name] = true end

local function integer(value, maximum)
  if type(value) == "string" and #value <= 20 and value:match("^%d+$") then value = tonumber(value) end
  return type(value) == "number" and math.type(value) == "integer"
    and value >= 0 and value <= maximum and value or nil
end

local function session_id(value)
  return type(value) == "string" and #value > 0 and #value <= 64
    and value ~= "self" and value ~= "auto"
    and value:match("^[A-Za-z0-9][A-Za-z0-9_%-]*$") and value or nil
end

local function identity(record, boot)
  return boot .. ":" .. record.session_id .. ":" .. record.uid .. ":" .. record.started_us
end

function Logind.parse_list(raw, maximum)
  if type(raw) ~= "string" or #raw > MAX_BYTES then return nil end
  maximum = Common.positive_integer("max_sessions", maximum, MAX_SESSIONS, MAX_SESSIONS)
  local list, seen = {}, {}
  for line in raw:gmatch("[^\n]+") do
    if line:find("%S") then
      local id, user_id = line:match("^%s*(%S+)%s+(%d+)%s+")
      user_id = integer(user_id, 4294967295)
      if not session_id(id) or user_id == nil or seen[id] then list.partial = true
      elseif #list >= maximum then list.truncated = true
      else
        seen[id] = true
        list[#list + 1] = { session_id = id, uid = user_id }
      end
    end
  end
  return list
end

function Logind.parse_show(raw)
  if type(raw) ~= "string" or #raw > MAX_BYTES then return nil end
  local records, seen = {}, {}
  local fields, present, duplicate, lines = {}, {}, false, 0
  local function finish()
    if lines == 0 then return end
    local id = session_id(fields.Id)
    local user_id, started = fields.User, fields.TimestampMonotonic
    if duplicate or not id or user_id == nil or not started or started == 0 or seen[id] then
      records.partial = true
    else
      seen[id] = true
      local record = { session_id = id, uid = user_id, started_us = started,
        user = fields.Name, login_time = fields.Timestamp, leader_pid = fields.Leader,
        seat = fields.Seat, tty = fields.TTY, remote = fields.Remote,
        service = fields.Service, session_type = fields.Type, class = fields.Class,
        active = fields.Active, state = fields.State, idle_hint = fields.IdleHint,
        scope = fields.Scope }
      if record.leader_pid == 0 then record.leader_pid = nil end
      record.partial = not record.user or not record.service or not record.state
        or record.remote == nil or record.active == nil or record.idle_hint == nil
      records.partial = records.partial or record.partial
      if #records < MAX_SESSIONS then records[#records + 1] = record
      else records.truncated = true end
    end
    fields, present, duplicate, lines = {}, {}, false, 0
  end
  for line in (raw .. "\n\n"):gmatch("([^\n]*)\n") do
    if line == "" then finish()
    else
      lines = lines + 1
      local name, value = line:match("^([A-Za-z]+)=(.*)$")
      if lines > 128 or #line > 8192 or not name then duplicate = true
      elseif ALLOWED[name] then
        if present[name] then duplicate = true end
        present[name] = true
        if NUMERIC[name] then
          fields[name] = integer(value, NUMERIC[name])
          if fields[name] == nil then duplicate = true end
        elseif BOOLEAN[name] then
          if value == "yes" then fields[name] = true
          elseif value == "no" then fields[name] = false
          else duplicate = true end
        else
          fields[name] = Common.safe_text(value, 512)
          if fields[name] == "" then fields[name] = nil end
        end
      end
    end
  end
  return records
end

function Logind.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Logind options must be a table", 2) end
  return setmetatable({ id = "session.logind", domain = "session", _method_style = true,
    platform = options.platform or Platform.id(), fs = options.fs or FS.default,
    runner = options.runner or Runner.new(), clock = options.clock or Clock.default,
    loginctl = Common.absolute_path("loginctl", options.loginctl, "/usr/bin/loginctl"),
    max_sessions = Common.positive_integer("max_sessions", options.max_sessions, MAX_SESSIONS, MAX_SESSIONS),
    timeout_ms = Common.positive_integer("timeout_ms", options.timeout_ms, 500, 1000),
  }, Logind)
end

function Logind:probe(context)
  local fs = context and context.fs or self.fs
  if self.platform ~= "linux" or not fs:exists(self.loginctl) then
    return Capability.unavailable("loginctl_unavailable", { source = self.loginctl })
  end
  return Capability.available({ source = self.loginctl, reason = "logind_not_queried" })
end

function Logind:_boot(context)
  local fs = context.fs or self.fs
  local ok, raw = pcall(fs.read, fs, "/proc/sys/kernel/random/boot_id", 64)
  return ok and type(raw) == "string" and GUID.normalize(raw:match("^%s*(.-)%s*$")) or nil
end

function Logind:_run(context, arguments)
  local fs = context.fs or self.fs
  if self.platform ~= "linux" or context.safe_mode == true or not fs:exists(self.loginctl) then
    return { status = "unavailable" }
  end
  local argv = { self.loginctl, "--no-pager", "--no-ask-password" }
  for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
  local ok, run = pcall(self.runner.run, self.runner, argv,
    { timeout_ms = self.timeout_ms, max_output_bytes = MAX_BYTES, env = { LANG = "C", LC_ALL = "C" } })
  if not ok or type(run) ~= "table" then return { status = "error" } end
  if type(run.stderr) == "string" and (run.stderr:find("Access denied", 1, true)
      or run.stderr:find("Permission denied", 1, true)) then run.status = "denied" end
  return run
end

function Logind:_show(context, ids)
  local argv = { "show-session", "--all" }
  -- loginctl requires a separate --property for each name (no comma list).
  for _, property in ipairs(PROPERTIES) do argv[#argv + 1] = "--property=" .. property end
  argv[#argv + 1] = "--"
  for _, id in ipairs(ids) do argv[#argv + 1] = id end
  return self:_run(context, argv)
end

function Logind:read(context, service)
  context = type(context) == "table" and context or {}
  local started = Common.now_ns(context, self.clock)
  local function failure(status, reason)
    return Common.result(status, Common.now_ns(context, self.clock), nil,
      { reason = reason, source = self.loginctl })
  end
  if self.platform ~= "linux" or context.safe_mode == true then
    return failure("unavailable", "logind_unavailable")
  end
  if service ~= nil and (type(service) ~= "string" or #service > 128
      or not service:match("^[A-Za-z0-9_][A-Za-z0-9_.%-]*$")) then
    return failure("error", "logind_data_invalid")
  end
  local boot = self:_boot(context)
  if not boot then return failure("unavailable", "logind_boot_unavailable") end
  local listed = self:_run(context, { "list-sessions", "--no-legend" })
  if listed.status ~= "ok" or type(listed.stdout) ~= "string" then
    return failure(listed.status == "denied" and "denied" or "unavailable", "logind_unavailable")
  end
  local raw = listed.stdout
  if listed.truncated then raw = raw:match("^(.*)\n") or "" end
  local candidates = Logind.parse_list(raw, self.max_sessions)
  if not candidates or (#candidates == 0 and candidates.partial) then return failure("error", "logind_data_invalid") end
  local records = {}
  local show_partial, show_truncated = false, false
  if #candidates > 0 then
    local ids, expected = {}, {}
    for _, candidate in ipairs(candidates) do
      ids[#ids + 1] = candidate.session_id
      expected[candidate.session_id] = candidate.uid
    end
    local shown = self:_show(context, ids)
    if shown.status ~= "ok" or type(shown.stdout) ~= "string" then
      return failure(shown.status == "denied" and "denied" or "unavailable", "logind_unavailable")
    end
    raw = shown.stdout
    if shown.truncated then raw = raw:match("^(.*)\n\n") or "" end
    local parsed = Logind.parse_show(raw)
    if not parsed or (#parsed == 0 and parsed.partial) then return failure("error", "logind_data_invalid") end
    show_partial = parsed.partial or #parsed ~= #candidates
    show_truncated = parsed.truncated or shown.truncated == true
    for _, record in ipairs(parsed) do
      if expected[record.session_id] == record.uid then
        record.id, record.boot_id = identity(record, boot), boot
        record.name = record.session_id .. " · " .. (record.user or "?") .. " · " .. (record.service or "?")
        if not service or record.service == service then records[#records + 1] = record end
      else show_partial = true end
    end
  end
  if self:_boot(context) ~= boot then return failure("unavailable", "logind_session_changed") end
  local partial = candidates.partial or candidates.truncated or listed.truncated or show_partial or show_truncated
  local finished = Common.now_ns(context, self.clock)
  return Common.result("ok", finished, { sessions = records, boot_id = boot,
    truncated = candidates.truncated or listed.truncated or show_truncated or false,
    partial = partial == true, service = service }, { source = self.loginctl,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    quality = partial and "partial" or "fresh", reason = partial and "logind_data_partial" or nil })
end

function Logind:enumerate(context)
  local result = self:read(context)
  if result.status ~= "ok" then return nil, result.reason end
  local sessions = result.data.sessions
  sessions.partial, sessions.truncated = result.data.partial, result.data.truncated
  return sessions
end

function Logind:inspect(context, selected)
  context = type(context) == "table" and context or {}
  local started = Common.now_ns(context, self.clock)
  local function failure(status, reason)
    return Model.result(status, nil, {}, { reason = reason, source = self.loginctl,
      timestamp_ns = Common.now_ns(context, self.clock), provider = "loginctl_show_session" })
  end
  if type(selected) ~= "table" or not session_id(selected.session_id)
      or integer(selected.uid, 4294967295) == nil or integer(selected.started_us, math.maxinteger) == nil
      or selected.started_us == 0 or not GUID.normalize(selected.boot_id)
      or selected.id ~= identity(selected, selected.boot_id) then
    return failure("unavailable", "logind_session_changed")
  end
  if self.platform ~= "linux" or context.safe_mode == true then return failure("unavailable", "logind_unavailable") end
  if self:_boot(context) ~= selected.boot_id then return failure("unavailable", "logind_session_changed") end
  local shown = self:_show(context, { selected.session_id })
  if shown.status ~= "ok" or shown.truncated or type(shown.stdout) ~= "string" then
    return failure(shown.status == "denied" and "denied" or "unavailable", "logind_unavailable")
  end
  local records = Logind.parse_show(shown.stdout)
  local record = records and #records == 1 and records[1]
  if not record or record.session_id ~= selected.session_id or record.uid ~= selected.uid
      or record.started_us ~= selected.started_us or self:_boot(context) ~= selected.boot_id then
    return failure("unavailable", "logind_session_changed")
  end
  local finished = Common.now_ns(context, self.clock)
  local fields = {}
  for _, name in ipairs({ "session_id", "uid", "user", "login_time", "leader_pid", "seat", "tty",
      "remote", "service", "session_type", "class", "active", "state", "idle_hint", "scope" }) do
    fields[name] = Model.field(record[name], nil, { source = self.loginctl, timestamp_ns = finished })
  end
  local quality = records.partial and "partial" or "fresh"
  return Model.result("ok", Model.entity(selected.id, "session", {
    name = record.session_id,
    identity = { session_id = record.session_id, uid = record.uid,
      started_us = record.started_us, boot_id = selected.boot_id },
    summary = fields,
  }), {}, { source = self.loginctl, provider = "loginctl_show_session", quality = quality,
    reason = records.partial and "logind_data_partial" or nil,
    timestamp_ns = finished, duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

Logind.session_id = session_id
return Logind
