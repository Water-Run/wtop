package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Journal = require("wtop.inspectors.journal")
local Systemd = require("wtop.inspectors.systemd")
local Fixture = require("support.fixture_fs")
local Runner = require("wtop.core.runner")
local JSON = require("wtop.format.json")
local I18n = require("wtop.i18n")
local TUI = require("wtop.tui")
local boot = string.rep("a", 32)
local fs = Fixture.new({ files = { ["/usr/bin/journalctl"] = "tool",
  ["/proc/sys/kernel/random/boot_id"] = boot .. "\n" } })
local now = 1000000000
local clock = { now_ns = function() return now end }
local unit = { status = "ok", entity = { kind = "service", identity = {
  unit = "worker.service", manager = "system" }, summary = {
    unit = { value = "worker.service" }, manager = { value = "system" } } } }
local function record(extra)
  local entry = { _BOOT_ID = boot, _SYSTEMD_UNIT = "worker.service", _UID = "1000",
    _PID = "42", PRIORITY = "6", __REALTIME_TIMESTAMP = "1700000000000000",
    __CURSOR = "cursor1", MESSAGE = "first\nsecond\27[31m", SYSLOG_IDENTIFIER = "worker",
    _CMDLINE = "PRIVATE-COMMAND", _MACHINE_ID = "PRIVATE-HOST" }
  for key, value in pairs(extra or {}) do entry[key] = value end
  return JSON.encode(entry)
end
local response = { status = "ok", exit_code = 0, stdout = record() .. "\n" }
local calls, argv, policy = 0
local runner = Runner.new({ execute = function(arguments, options)
  calls, argv, policy = calls + 1, arguments, options
  return response
end })
local journal = Journal.new({ platform = "linux", uid = 1000, fs = fs, runner = runner, clock = clock })
local result = journal:read({}, unit)
assert(result.status == "ok" and result.quality == "fresh" and #result.data.entries == 1)
assert(argv[1] == "/usr/bin/journalctl" and argv[4] == "--output=json")
assert(table.concat(argv, " "):find("--boot=" .. boot, 1, true)
  and argv[#argv] == "--unit=worker.service")
assert(policy.timeout_ms == 1000 and policy.max_output_bytes == 512 * 1024)
assert(policy.env.LANG == "C" and policy.env.LC_ALL == "C" and policy.env.XDG_RUNTIME_DIR == nil)
local entry = result.data.entries[1]
assert(entry.pid == 42 and entry.priority == 6 and entry.relation == "emitted")
assert(entry.message:find("\n", 1, true) and not entry.message:find("\27", 1, true))
assert(not JSON.encode(result):find("PRIVATE", 1, true))
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "fr-FR", "ru-RU", "de-DE", "es-ES", "pt-BR", "ja-JP", "ko-KR" }) do
  local i18n = I18n.new({ lang = locale })
  local text = table.concat(TUI.journal_lines({ result = result, index = 1, detail = true }, i18n, true, now), "\n")
  assert(text:find("worker.service", 1, true) and not text:find("\27", 1, true))
  for _, key in ipairs({ "journal.history_note", "journal.sender_pid", "journal.priority", "journal.detail_hint" }) do
    assert(i18n:t(key) ~= key and text:find(i18n:t(key), 1, true), locale .. " lacks " .. key)
  end
end

local count = calls
assert(journal:read({ safe_mode = true }, unit).status == "unavailable" and calls == count)
assert(journal:read({}, { status = "unavailable" }).reason == "journal_unit_unverified" and calls == count)
local user = { status = "ok", entity = { kind = "service", identity = {
  unit = "worker.service", manager = "user", uid = 1000 }, summary = {
    unit = { value = "worker.service" }, manager = { value = "user" } } } }
response = { status = "ok", stdout = record({ _SYSTEMD_UNIT = "user@1000.service",
  _SYSTEMD_USER_UNIT = "worker.service" }) .. "\n" }
result = journal:read({}, user)
assert(result.status == "ok" and #result.data.entries == 1 and argv[#argv] == "--user-unit=worker.service")
assert(result.data.entries[1].unit == "worker.service")
user.entity.identity.uid = 2000
count = calls
assert(journal:read({}, user).reason == "journal_user_unavailable" and calls == count)
user.entity.identity.uid = 1000

-- A unit name from another user, another boot or a non-root reference cannot
-- borrow the selected system unit's identity.
local target = { unit = "worker.service", manager = "system", kind = "service" }
local mixed = record() .. "\n" .. record({ _BOOT_ID = string.rep("b",32) }) .. "\n"
  .. record({ _SYSTEMD_UNIT = "elsewhere.service", _UID = "1000", UNIT = "worker.service" }) .. "\n"
  .. record({ _SYSTEMD_UNIT = "init.scope", _UID = "0", _PID = "1", UNIT = "worker.service",
    __CURSOR = "manager", __REALTIME_TIMESTAMP = "1700000000000001" }) .. "\n"
local parsed = assert(Journal.parse(mixed, target, boot))
assert(#parsed.entries == 2 and parsed.entries[1].relation == "referenced" and parsed.rejected == 2 and parsed.partial)
local user_target = { unit = "worker.service", manager = "user", uid = 1000, kind = "service" }
local wrong_user = assert(Journal.parse(record({ _SYSTEMD_USER_UNIT = "worker.service", _UID = "2000" }), user_target, boot))
assert(#wrong_user.entries == 0 and wrong_user.partial)
local core = assert(Journal.parse(record({ _SYSTEMD_UNIT = "systemd-coredump@1.service", _UID = "0",
  COREDUMP_USER_UNIT = "worker.service", COREDUMP_UID = "1000" }), user_target, boot))
assert(#core.entries == 1 and core.entries[1].relation == "referenced")
local child = assert(Journal.parse(record({ _SYSTEMD_UNIT = "other.service", _SYSTEMD_SLICE = "app.slice" }),
  { unit = "app.slice", kind = "slice", manager = "system" }, boot))
assert(#child.entries == 1 and child.entries[1].relation == "member")
local string_uid = assert(Journal.parse(record({ _SYSTEMD_USER_UNIT = "worker.service" }),
  { unit = "worker.service", manager = "user", uid = "1000" }, boot))
assert(#string_uid.entries == 1 and string_uid.entries[1].relation == "emitted")
local wrong_kind = assert(Journal.parse(record({ _SYSTEMD_UNIT = "other.service",
  _SYSTEMD_SLICE = "worker.service" }),
  { unit = "worker.service", manager = "system", kind = "slice" }, boot))
assert(#wrong_kind.entries == 0 and wrong_kind.rejected == 1)

local malformed = assert(Journal.parse("not json\n" .. record(), target, boot))
assert(malformed.partial and #malformed.entries == 1)
local binary = assert(Journal.parse(record({ MESSAGE = JSON.array({ 0, 255, 27 }) }), target, boot))
assert(binary.entries[1].message_kind == "binary_or_multiple" and binary.partial)
local null_record = record({ MESSAGE = "NULL-MESSAGE" }):gsub('"MESSAGE":"NULL%-MESSAGE"', '"MESSAGE":null', 1)
local nulled = assert(Journal.parse(null_record, target, boot))
assert(nulled.entries[1].message == nil and nulled.partial)
local long = assert(Journal.parse(record({ MESSAGE = string.rep("x", 5000) }), target, boot))
assert(long.entries[1].message_truncated and #long.entries[1].message <= 4096)
local repeated = assert(Journal.parse(record() .. "\n" .. record(), target, boot))
assert(#repeated.entries == 1 and repeated.partial)
local bounded = assert(Journal.parse(record() .. "\n" .. record({ __CURSOR = "second" }), target, boot, 1))
assert(#bounded.entries == 1 and bounded.truncated)
assert(not Journal.parse(string.rep("x", 512 * 1024 + 1), target, boot))
assert(not Journal.boot_id(string.rep("a", 31)) and not Journal.boot_id(string.rep("a",32).."-"))

for _, failure in ipairs({ { status = "denied" }, { status = "timeout" }, { status = "error" },
    { status = "error", stderr = "No journal files were opened due to insufficient permissions." } }) do
  response = failure
  assert(journal:read({}, unit).status ~= "ok")
end
response = { status = "ok", stdout = "not json\n" }
assert(journal:read({}, unit).status == "error")
response = { status = "ok", stdout = "" }
assert(journal:read({}, unit).status == "ok")
response = { status = "ok", stdout = "", stderr = "Hint: You are currently not seeing messages from other users and the system." }
result = journal:read({}, unit)
assert(result.status == "ok" and result.quality == "partial" and result.data.access_limited)
response = { status = "ok", stdout = record() .. "\n{partial", truncated = true }
result = journal:read({}, unit)
assert(result.status == "ok" and #result.data.entries == 1 and result.data.truncated)
local missing = Journal.new({ platform = "linux", uid = 1000, fs = Fixture.new({}), runner = runner })
assert(missing:read({}, unit).reason == "journalctl_unavailable")
local native = require("wtop.native")
local old_uid = native.uid
native.uid = function() return nil, "UID provider unavailable" end
local constructed, without_uid = pcall(Journal.new, { platform = "linux", fs = fs, runner = runner })
native.uid = old_uid
assert(constructed and without_uid.uid == nil, "an unavailable UID detector must not turn its error into a user ID")
assert(without_uid:read({}, user).reason == "journal_user_unavailable")
assert(not pcall(Journal.new, { journalctl = "relative" }))
assert(not pcall(Journal.new, { max_entries = 101 }))

print("ok: bounded unit journal, identity, provenance, privacy, failure states and message rendering")
