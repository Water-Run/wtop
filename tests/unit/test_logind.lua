package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Logind = require("wtop.inspectors.logind")
local SSHD = require("wtop.inspectors.sshd")
local Systemd = require("wtop.inspectors.systemd")
local Inspectors = require("wtop.inspectors")
local Runner = require("wtop.core.runner")
local Fixture = require("support.fixture_fs")
local JSON = require("wtop.format.json")
local I18n = require("wtop.i18n")
local TUI = require("wtop.tui")
local boot = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
local fs = Fixture.new({ files = { ["/usr/bin/loginctl"] = "tool",
  ["/usr/bin/systemctl"] = "tool", ["/proc/sys/kernel/random/boot_id"] = boot .. "\n" } })
local clock = { now_ns = function() return 1000000000 end }
local function record(changes)
  local fields = { Id = "7", User = "1000", Name = "alice", Timestamp = "Sun 2026-10-11 08:55:49 CST",
    TimestampMonotonic = "100", Leader = "42", Seat = "", TTY = "pts/2", Remote = "yes",
    Service = "sshd", Type = "tty", Class = "user", Active = "yes", State = "active",
    IdleHint = "no", Scope = "session-7.scope", RemoteHost = "PRIVATE-HOST",
    RemoteUser = "PRIVATE-USER", Display = "PRIVATE-DISPLAY" }
  for key, value in pairs(changes or {}) do fields[key] = value end
  local lines = {}
  for key, value in pairs(fields) do lines[#lines + 1] = key .. "=" .. value end
  table.sort(lines)
  return table.concat(lines, "\n") .. "\n"
end
local list = { status = "ok", stdout = "7 1000 alice - pts/2\n8 1000 alice seat0 tty2\n" }
local show = { status = "ok", stdout = record() .. "\n" .. record({ Id = "8", Service = "gdm-password",
  TimestampMonotonic = "200", Leader = "43", Remote = "no", Scope = "session-8.scope" }) }
local calls = {}
local runner = Runner.new({ execute = function(argv, policy)
  calls[#calls + 1] = { argv = argv, policy = policy }
  assert(argv[1] == "/usr/bin/loginctl" and argv[2] == "--no-pager" and argv[3] == "--no-ask-password")
  assert(policy.timeout_ms == 500 and policy.max_output_bytes == 256 * 1024)
  assert(policy.env.LANG == "C" and policy.env.LC_ALL == "C" and policy.env.XDG_RUNTIME_DIR == nil)
  for _, argument in ipairs(argv) do
    assert(not argument:find("--property=RemoteHost", 1, true))
    assert(not argument:find("--property=RemoteUser", 1, true))
    if argument:find("--property=", 1, true) then assert(not argument:find(",", 1, true)) end
  end
  return argv[4] == "list-sessions" and list or show
end })
local logind = Logind.new({ platform = "linux", fs = fs, runner = runner, clock = clock })
assert(logind:probe({}).available and #calls == 0)
local result = logind:read({})
assert(result.status == "ok" and result.quality == "fresh" and #result.data.sessions == 2 and #calls == 2)
assert(result.data.sessions[1].scope == "session-7.scope" and result.data.sessions[2].remote == false)
assert(not JSON.encode(result):find("PRIVATE", 1, true))
assert(calls[2].argv[#calls[2].argv] == "8" and calls[2].argv[#calls[2].argv - 2] == "--")
local selected = result.data.sessions[1]
show = { status = "ok", stdout = record() }
local inspected = logind:inspect({}, selected)
assert(inspected.status == "ok" and inspected.entity.kind == "session")
assert(inspected.entity.identity.started_us == 100 and inspected.entity.summary.uid.value == 1000)
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "fr-FR", "ru-RU", "de-DE", "es-ES", "pt-BR", "ja-JP", "ko-KR" }) do
  local i18n = I18n.new({ lang = locale })
  local text = table.concat(TUI.session_lines({ entity = selected, result = inspected }, i18n, 2000000000), "\n")
  for _, key in ipairs({ "session.service", "session.hint", "session.note", "session.idle_hint" }) do
    assert(i18n:t(key) ~= key and text:find(i18n:t(key), 1, true), locale .. " lacks " .. key)
  end
  assert(text:find("sshd", 1, true) and not text:find("PRIVATE", 1, true))
  assert(text:find(i18n:t("ui.no"), 1, true), "false idle hint was lost")
end
local count = #calls
assert(logind:read({ safe_mode = true }).status == "unavailable" and #calls == count)
assert(logind:inspect({ safe_mode = true }, selected).status == "unavailable" and #calls == count)
assert(Logind.new({ platform = "windows", fs = fs, runner = runner }):read({}).status == "unavailable" and #calls == count)
for _, invalid in ipairs({ "self", "auto", "-7", "bad/name", "a\0", string.rep("x",65) }) do
  assert(not Logind.session_id(invalid))
  assert(not logind:inspect({}, { session_id = invalid }).entity)
end
for _, changes in ipairs({ { User = "1001" }, { TimestampMonotonic = "101" }, { Id = "8" } }) do
  show = { status = "ok", stdout = record(changes) }
  assert(logind:inspect({}, selected).reason == "logind_session_changed")
end
local other_boot = Fixture.new({ files = { ["/proc/sys/kernel/random/boot_id"] = "ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee" } })
count = #calls
assert(logind:inspect({ fs = other_boot }, selected).reason == "logind_session_changed" and #calls == count)

show = { status = "ok", stdout = record() .. "\n" .. record({ Id = "8", Service = "gdm-password",
  TimestampMonotonic = "200", Remote = "no" }) }
local ssh = logind:read({}, "sshd")
assert(ssh.status == "ok" and ssh.quality == "fresh" and #ssh.data.sessions == 1)
local service = SSHD.new({ fs = fs, clock = clock, sessions_provider = logind })
local service_result = service:inspect({ systemd_show = { Id = "sshd.service", ActiveState = "active" },
  listening_sockets = {}, processes = { list = {} } })
local sessions
for _, section in ipairs(service_result.sections) do if section.id == "sessions" then sessions = section.fields.active_sessions end end
assert(sessions and sessions.quality == "fresh" and #sessions.value == 1 and sessions.source == "/usr/bin/loginctl")
assert(sessions.value[1].id == "7" and sessions.value[1].service == "sshd" and sessions.value[1].leader_pid == 42)
assert(sessions.value[1].remote == nil and sessions.value[1].is_remote == true)
assert(not JSON.encode(service_result):find("PRIVATE", 1, true))
local denied_service = SSHD.new({ fs = fs, clock = clock, sessions_provider = {
  read = function() return { status = "denied", reason = "logind_unavailable", source = "/usr/bin/loginctl" } end,
} }):inspect({ systemd_show = { Id = "sshd.service", ActiveState = "active" }, listening_sockets = {} })
for _, section in ipairs(denied_service.sections) do
  if section.id == "sessions" then
    assert(section.fields.active_sessions.value == nil and section.fields.active_sessions.quality == "denied",
      "a failed session query must not publish an empty readable list")
  end
end

local target = assert(Systemd.from_session(inspected))
assert(target.unit == "session-7.scope" and target.manager == "system" and target.session_leader == 42)
local unit_show = "Id=session-7.scope\nNames=session-7.scope\nLoadState=loaded\nActiveState=active\nSubState=running\nLeader=42\nControlGroup=/user.slice/user-1000.slice/session-7.scope\n"
local systemd = Systemd.new({ fs = fs, platform = "linux", clock = clock,
  runner = Runner.new({ execute = function() return { status = "ok", stdout = unit_show } end }) })
assert(systemd:enumerate({ systemd_session = inspected })[1].unit == target.unit)
assert(systemd:inspect({}, target).status == "ok")
local with_leader = unit_show
unit_show = unit_show:gsub("Leader=42\n", "")
local without_leader = systemd:inspect({}, target)
assert(without_leader.status == "ok" and without_leader.entity.summary.leader_pid.value == nil
  and without_leader.entity.relations.main_pid == nil, "a scope must not invent a process from logind's PID")
unit_show = with_leader
unit_show = unit_show:gsub("Leader=42", "Leader=99")
assert(systemd:inspect({}, target).reason == "systemd_unit_changed")
inspected.entity.summary.scope.value = "other.scope"
assert(not Systemd.from_session(inspected))
inspected.entity.summary.scope.value = "session-7.scope"
inspected.entity.identity.started_us = 101
assert(not Systemd.from_session(inspected))

local duplicate = assert(Logind.parse_show(record() .. "User=1000\n"))
assert(#duplicate == 0 and duplicate.partial)
local malformed = assert(Logind.parse_show(record({ User = "18446744073709551616" })))
assert(#malformed == 0 and malformed.partial)
local absent = assert(Logind.parse_show(record({ Service = "", Leader = "0" })))
assert(#absent == 1 and absent.partial and absent[1].service == nil and absent[1].leader_pid == nil)
local inconsistent = assert(Logind.parse_list("7 1000 alice -\n7 1001 bob -\ninvalid\n"))
assert(#inconsistent == 1 and inconsistent.partial)
local many = {}
for index = 1, 129 do many[index] = record({ Id = tostring(index) }) end
local bounded = assert(Logind.parse_show(table.concat(many, "\n")))
assert(#bounded == 128 and bounded.truncated)
assert(not Logind.parse_show(string.rep("x", 256 * 1024 + 1)))
assert(not Logind.parse_list(string.rep("x", 256 * 1024 + 1)))
local smaller = Logind.new({ platform = "linux", fs = fs, runner = runner, clock = clock, max_sessions = 1 })
result = smaller:read({})
assert(result.status == "ok" and result.quality == "partial" and result.data.truncated and #result.data.sessions == 1)
list = { status = "ok", stdout = "" }
count = #calls
result = logind:read({})
assert(result.status == "ok" and result.quality == "fresh" and #result.data.sessions == 0 and #calls == count + 1)
for _, failure in ipairs({ { status = "denied" }, { status = "timeout" }, { status = "error" },
    { status = "error", stderr = "Access denied" } }) do
  list = failure
  result = logind:read({})
  assert(result.status ~= "ok" and result.data == nil)
end
list = { status = "ok", stdout = "7 1000 alice -\n" }
show = { status = "ok", stdout = record() .. "\nId=partial", truncated = true }
result = logind:read({})
assert(result.status == "ok" and result.quality == "partial" and #result.data.sessions == 1)
show = { status = "ok", stdout = "garbage\n" }
assert(logind:read({}).reason == "logind_data_invalid")
local missing = Logind.new({ platform = "linux", fs = Fixture.new({}), runner = runner })
assert(not missing:probe({}).available and missing:read({}).status == "unavailable")
assert(not pcall(Logind.new, { loginctl = "relative" }))
assert(not pcall(Logind.new, { max_sessions = 129 }))
assert(not pcall(SSHD.new, { sessions_provider = {} }))
assert(Inspectors.new_default({ logind = { fs = fs, runner = runner } }):get("session.logind"))

print("ok: bounded logind sessions, PAM service attribution, generation, scope navigation, privacy and failures")
