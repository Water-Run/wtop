-- Counts of the accessible journal query, not lifetime or connection totals.
local Common = require("wtop.collectors.common")
local Journal = require("wtop.inspectors.journal")
local Systemd = require("wtop.inspectors.systemd")

local Stats = {}
Stats.__index = Stats
local PRIORITIES = { "emergency", "alert", "critical", "error", "warning", "notice", "info", "debug" }
local IDENTIFIERS = { sshd = true, ["sshd-session"] = true, ["sshd-auth"] = true }
local METHODS = { password = true, publickey = true, hostbased = true, none = true,
  ["keyboard-interactive"] = true, ["keyboard-interactive/pam"] = true,
  ["gssapi-with-mic"] = true, ["gssapi-keyex"] = true, ["challenge-response"] = true }
local AUTH = { Accepted = "accepted", Failed = "failed", Partial = "partial", Postponed = "postponed" }

local function integer(value, minimum, maximum)
  return type(value) == "number" and math.type(value) == "integer"
    and value >= minimum and value <= maximum and value or nil
end

function Stats.classify(entry)
  if type(entry) ~= "table" or entry.relation ~= "emitted" or not IDENTIFIERS[entry.identifier]
      or type(entry.message) ~= "string" or entry.message_truncated
      or #entry.message > 4096 or entry.message:find("[%c]") then return nil end
  local state, method, port, suffix = entry.message:match("^(%a+) ([%w%-%/]+) for .- from %S+ port (%d+) (.*)$")
  local kind = AUTH[state]
  if kind and METHODS[method] and #port <= 5 and tonumber(port) >= 1 and tonumber(port) <= 65535
      and (suffix == "ssh2" or suffix:sub(1, 6) == "ssh2: ") then
    return kind, method
  end
  port = entry.message:match("^Invalid user .- from %S+ port (%d+)$")
  if port and #port <= 5 and tonumber(port) >= 1 and tonumber(port) <= 65535 then return "invalid_user" end
end

function Stats.summarize(observed, ssh)
  observed = type(observed) == "table" and observed or {}
  local function result(status, data, quality, reason)
    return Common.result(status, observed.timestamp_ns or 0, data, {
      source = observed.source, quality = quality, reason = reason,
      duration_ns = observed.duration_ns or 0 })
  end
  if observed.status ~= "ok" then
    local status = observed.status == "denied" and "denied" or observed.status == "error" and "error" or "unavailable"
    return result(status, nil, status, observed.reason or "journal_unavailable")
  end
  local source = observed.data
  if type(source) ~= "table" or type(source.entries) ~= "table" or #source.entries > 100 then
    return result("error", nil, "error", "journal_data_invalid")
  end
  local data = { unit = source.unit, manager = source.manager, max_entries = source.max_entries or 100,
    entries = #source.entries, unreadable = 0, priorities = { unknown = 0 },
    relations = { emitted = 0, member = 0, referenced = 0, unknown = 0 },
    rejected = source.rejected or 0, access_limited = source.access_limited == true,
    truncated = source.truncated == true, partial = source.partial == true,
    events = {} }
  for _, name in ipairs(PRIORITIES) do data.priorities[name] = 0 end
  if ssh then data.auth = { accepted = 0, failed = 0, partial = 0, postponed = 0,
    invalid_user = 0, unclassified = 0, unreadable = 0, considered = 0 } end
  for _, entry in ipairs(source.entries) do
    if type(entry) ~= "table" then return result("error", nil, "error", "journal_data_invalid") end
    local level = integer(entry.priority, 0, 7)
    local name = level and PRIORITIES[level + 1] or "unknown"
    data.priorities[name] = data.priorities[name] + 1
    local relation = data.relations[entry.relation] ~= nil and entry.relation or "unknown"
    data.relations[relation] = data.relations[relation] + 1
    local timestamp = integer(entry.timestamp_us, 0, math.maxinteger)
    if timestamp then
      data.oldest_us = math.min(data.oldest_us or timestamp, timestamp)
      data.newest_us = math.max(data.newest_us or timestamp, timestamp)
    end
    local readable = type(entry.message) == "string" and not entry.message_truncated
    if not readable then data.unreadable = data.unreadable + 1 end
    if data.auth and entry.relation == "emitted" and IDENTIFIERS[entry.identifier] then
      data.auth.considered = data.auth.considered + 1
      local kind, method = Stats.classify(entry)
      if kind then
        data.auth[kind] = data.auth[kind] + 1
        data.events[#data.events + 1] = { kind = kind, method = method, timestamp_us = timestamp, priority = level }
      elseif not readable then data.auth.unreadable = data.auth.unreadable + 1
      else data.auth.unclassified = data.auth.unclassified + 1 end
    end
  end
  local partial = observed.quality == "partial" or data.partial or data.truncated or data.access_limited
  return result("ok", data, partial and "partial" or ssh and "estimated" or "fresh",
    partial and (observed.reason or "journal_data_partial") or ssh and "event_classification_estimated" or nil)
end

function Stats.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Journal stats options must be a table", 2) end
  if options.journal ~= nil and (type(options.journal) ~= "table" or type(options.journal.read) ~= "function") then
    error("invalid journal provider", 2)
  end
  return setmetatable({ journal = options.journal or Journal.new(options) }, Stats)
end

function Stats:read(context, unit, properties)
  -- The caller has just read systemctl show. Preserve its exact canonical name
  -- and verify the requested alias before handing it to the journal reader.
  local matches = type(properties) == "table" and properties.Id == unit
  if type(properties) == "table" and type(properties.Names) == "string" then
    for name in properties.Names:gmatch("%S+") do if name == unit then matches = true end end
  end
  local verified
  if matches and Systemd.unit_name(unit) == "service" and Systemd.unit_name(properties.Id) == "service"
      and properties.LoadState == "loaded" then
    verified = { status = "ok", entity = { kind = "service",
      identity = { unit = properties.Id, manager = "system" },
      summary = { unit = { value = properties.Id }, manager = { value = "system" } } } }
  end
  return Stats.summarize(self.journal:read(context, verified), true)
end

Stats.priorities = PRIORITIES
return Stats
