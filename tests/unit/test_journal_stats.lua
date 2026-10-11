package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Stats = require("wtop.inspectors.journal_stats")
local SSHD = require("wtop.inspectors.sshd")
local Fixture = require("support.fixture_fs")
local JSON = require("wtop.format.json")
local I18n = require("wtop.i18n")
local TUI = require("wtop.tui")
local function entry(message, extra)
  local value = { message = message, relation = "emitted", identifier = "sshd", priority = 6, timestamp_us = 30 }
  for key, field in pairs(extra or {}) do value[key] = field end
  return value
end
local accepted = "Accepted publickey for PRIVATE-USER from 203.0.113.24 port 42351 ssh2: RSA PRIVATE-KEY"
local failed = "Failed password for invalid user PRIVATE-USER from 2001:db8::4 port 1452 ssh2"
local observed = { status = "ok", quality = "fresh", timestamp_ns = 1000000000, source = "/usr/bin/journalctl",
  data = { unit = "ssh.service", manager = "system", max_entries = 100, entries = {
    entry(accepted), entry(failed, { timestamp_us = 10, priority = 3 }),
    entry("Partial publickey for PRIVATE-USER from 203.0.113.24 port 22 ssh2"),
    entry("Postponed keyboard-interactive/pam for PRIVATE-USER from 203.0.113.24 port 22 ssh2"),
    entry("Invalid user PRIVATE-USER from 203.0.113.24 port 22"),
    entry("Server listening on 0.0.0.0 port 22."),
    entry(accepted, { relation = "referenced" }), entry(accepted, { identifier = "application" }),
    entry("", { message_kind = "unavailable", message_truncated = true }),
  } } }
local summarized = Stats.summarize(observed, true)
assert(summarized.status == "ok" and summarized.quality == "estimated")
local data = summarized.data
assert(data.entries == 9 and data.oldest_us == 10 and data.newest_us == 30)
assert(data.priorities.error == 1 and data.priorities.info == 8 and data.priorities.unknown == 0)
assert(data.relations.emitted == 8 and data.relations.referenced == 1)
assert(data.auth.accepted == 1 and data.auth.failed == 1 and data.auth.partial == 1 and data.auth.postponed == 1)
assert(data.auth.invalid_user == 1 and data.auth.unclassified == 1 and data.auth.unreadable == 1 and data.auth.considered == 7)
assert(#data.events == 5 and data.events[1].method == "publickey")
assert(not JSON.encode(summarized):find("PRIVATE", 1, true) and not JSON.encode(summarized):find("203.0", 1, true))
local generic = Stats.summarize(observed)
assert(generic.quality == "fresh" and generic.data.auth == nil and #generic.data.events == 0)
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "fr-FR", "ru-RU", "de-DE", "es-ES", "pt-BR", "ja-JP", "ko-KR" }) do
  local i18n = I18n.new({ lang = locale })
  local text = table.concat(TUI.event_stats_lines(summarized, i18n, 2000000000, "ssh.service", "service"), "\n")
  for _, key in ipairs({ "events.auth_title", "events.auth_note", "events.auth_failed", "events.service_hint", "events.scope" }) do
    assert(i18n:t(key, { count = 100 }) ~= key and text:find(i18n:t(key, { count = 100 }), 1, true))
  end
  assert(not text:find("PRIVATE", 1, true) and not text:find("203.0", 1, true))
end
for _, record in ipairs({
    entry(accepted, { identifier = "sshd-helper" }), entry(accepted, { relation = "member" }),
    entry(accepted, { message_truncated = true }), entry(accepted .. "\nsecond line"),
    entry("not really " .. accepted), entry("Failed password for x from 127.0.0.1 port 999999 ssh2"),
    entry("Failed unusual-method for x from 127.0.0.1 port 22 ssh2"),
    entry("Failed to read password for x"), entry("Partial authentication failure"),
  }) do assert(Stats.classify(record) == nil) end
assert(Stats.classify(entry(accepted, { identifier = "sshd-session" })) == "accepted")
assert(Stats.classify(entry(failed, { identifier = "sshd-auth" })) == "failed")

observed.data.access_limited = true
assert(Stats.summarize(observed, true).quality == "partial")
observed.data.access_limited = nil
observed.data.truncated = true
assert(Stats.summarize(observed, true).quality == "partial")
observed.data.truncated = nil
for _, status in ipairs({ "denied", "unavailable", "error", "timeout" }) do
  local unavailable = Stats.summarize({ status = status, reason = "journal_unavailable" }, true)
  assert(unavailable.status ~= "ok" and unavailable.data == nil, "failed queries must not publish zero counters")
end
assert(Stats.summarize({ status = "ok", data = { entries = { false } } }).status == "error")
local overflow = {}
for index = 1, 101 do overflow[index] = entry(accepted) end
assert(Stats.summarize({ status = "ok", data = { entries = overflow } }).status == "error")
local empty = Stats.summarize({ status = "ok", data = { entries = {} } }, true)
assert(empty.status == "ok" and empty.data.entries == 0 and empty.data.auth.failed == 0)

local received, calls = nil, 0
local stats = Stats.new({ journal = { read = function(_, _, verified)
  calls, received = calls + 1, verified
  if not verified then return { status = "unavailable", reason = "journal_unit_unverified" } end
  assert(verified.entity.identity.unit == "ssh.service" and verified.entity.identity.manager == "system")
  return observed
end } })
local properties = { Id = "ssh.service", Names = "ssh.service sshd.service", LoadState = "loaded", ActiveState = "active" }
assert(stats:read({}, "sshd.service", properties).status == "ok" and received)
assert(stats:read({}, "elsewhere.service", properties).reason == "journal_unit_unverified" and not received)
assert(stats:read({}, "sshd.service", { Id = "sshd.service", LoadState = "not-found" }).status ~= "ok")
assert(stats:read({}, "sshd.service", { Id = "other.service", LoadState = "loaded" }).status ~= "ok")
local service = SSHD.new({ fs = Fixture.new({}), sessions_provider = false, events_provider = stats, max_events = 1 })
local result = service:inspect({ systemd_show = properties, listening_sockets = {}, max_events = 1 })
local field
for _, section in ipairs(result.sections) do if section.id == "events" then field = section.fields.recent_events end end
assert(field and #field.value == 1 and field.quality == "partial" and field.reason == "event_records_limited")
assert(result.details.event_summary.data.auth.failed == 1, "sample limits must not alter the query's counters")
assert(not JSON.encode(result):find("PRIVATE", 1, true))
result = service:inspect({ systemd_show = properties, listening_sockets = {}, max_events = 0 })
for _, section in ipairs(result.sections) do
  if section.id == "events" then assert(#section.fields.recent_events.value == 0 and section.fields.recent_events.quality == "partial") end
end
local denied = SSHD.new({ fs = Fixture.new({}), sessions_provider = false, events_provider = {
  read = function() return { status = "denied", reason = "journal_access_limited" } end,
} }):inspect({ systemd_show = properties, listening_sockets = {} })
for _, section in ipairs(denied.sections) do
  if section.id == "events" then assert(section.fields.recent_events.value == nil and section.fields.recent_events.quality == "denied") end
end
assert(not pcall(Stats.new, { journal = {} }))
assert(not pcall(SSHD.new, { events_provider = {} }))

print("ok: journal query counters, conservative OpenSSH text classification, coverage, privacy and service event source")
