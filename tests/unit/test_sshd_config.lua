package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Config = require("wtop.inspectors.sshd_config")
local Service = require("wtop.inspectors.service")
local SSHD = require("wtop.inspectors.sshd")
local Fixture = require("support.fixture_fs")
local JSON = require("wtop.format.json")
local I18n = require("wtop.i18n")
local TUI = require("wtop.tui")
local linux = "linux"
local dump = "port 22\nport 2222\nlistenaddress [::]:22\nlistenaddress 0.0.0.0:2222\n"
  .. "passwordauthentication no\npermitrootlogin prohibit-password\nmaxauthtries 6\nmaxsessions 10\n"
  .. "authenticationmethods publickey\nhostkey PRIVATE-KEY\nsetenv PRIVATE-SECRET\n"
local fields, partial = Config.parse(dump)
assert(not partial and #fields.port == 2 and fields.port[2] == "2222")
assert(#fields.listenaddress == 2 and fields.passwordauthentication == "no")
assert(not fields.hostkey and not fields.setenv)
for _, invalid in ipairs({ "", "unknown value\n", "port 0\n", "port 65536\n", "port -1\n", "port 2.0\n",
    "port " .. string.rep("9", 80), "passwordauthentication \27[31mno\n", string.rep("x", 128 * 1024 + 1) }) do
  assert(Config.parse(invalid) == nil)
end
fields, partial = Config.parse("port 22\ninvalid line with tab\t\npasswordauthentication no\npasswordauthentication yes\n")
assert(partial and fields.port == "22" and fields.passwordauthentication == "no")
fields, partial = Config.parse("port 22\n" .. string.rep("port 2222\n", 130))
assert(partial and #fields.port == 128)
fields, partial = Config.parse("port 22\n" .. string.rep("unknown x\n", 520))
assert(partial and fields.port == "22")

local calls, argv_seen = 0, nil
local provider = Config.new({ platform = linux, runner = { run = function(_, argv, policy)
  calls, argv_seen = calls + 1, argv
  assert(argv[1] == "/usr/sbin/sshd" and argv[2] == "-G" and argv[3] == "-f" and argv[4] == "/etc/ssh/sshd_config")
  assert(policy.timeout_ms == 500 and policy.max_output_bytes == 128 * 1024 and policy.env.LC_ALL == "C")
  return { status = "ok", stdout = dump }
end } })
local observed = provider:read({})
assert(observed.status == "ok" and observed.quality == "estimated" and observed.data.scope == "global")
assert(observed.reason == "sshd_configuration_current_files" and calls == 1)
assert(not JSON.encode(observed):find("PRIVATE", 1, true))
observed = provider:read({ sshd_connection = { user = "PRIVATE-USER", addr = "203.0.113.5", host = "client.example",
  laddr = "2001:db8::1", lport = 2222 } })
assert(observed.data.scope == "connection" and argv_seen[5] == "-C")
assert(argv_seen[6] == "user=PRIVATE-USER,addr=203.0.113.5,host=client.example,laddr=2001:db8::1,lport=2222")
assert(not JSON.encode(observed):find("PRIVATE-USER", 1, true) and not JSON.encode(observed):find("203.0", 1, true))
local prior = calls
for _, connection in ipairs({ {}, { user = "x,addr=another" }, { host = "x\n" }, { lport = 0 }, { lport = 65536 },
    { unknown = "x" }, { addr = "--option" }, { lport = 2.5 } }) do
  if connection.addr == "--option" then
    assert(provider:read({ sshd_connection = connection }).status == "ok")
    prior = prior + 1 -- A value in a single -C argument cannot become a flag.
  else
    assert(provider:read({ sshd_connection = connection }).reason == "sshd_configuration_connection_invalid")
  end
end
assert(calls == prior)

for _, message in ipairs({ "sshd: unknown option -- G", "sshd: illegal option -- G", "sshd: invalid option -- 'G'",
    "Config test connection parameter (-C) provided without test mode (-T)" }) do
  local modes = {}
  local fallback = Config.new({ platform = linux, runner = { run = function(_, argv)
    modes[#modes + 1] = argv[2]
    if message:find("connection parameter", 1, true) then
      assert(argv[5] == "-C" and argv[6] == "user=fixture")
    end
    return #modes == 1 and { status = "error", stdout = "", stderr = message }
      or { status = "ok", stdout = dump }
  end } }):read(message:find("connection parameter", 1, true) and { sshd_connection = { user = "fixture" } } or {})
  assert(fallback.status == "ok" and fallback.data.mode == "-T" and #modes == 2)
end
for _, failure in ipairs({
    { status = "error", stderr = "config: Permission denied", expected = "denied" },
    { status = "denied", expected = "denied" }, { status = "timeout", expected = "unavailable" },
    { status = "unavailable", expected = "unavailable" },
    { status = "error", stderr = "Bad configuration option PRIVATE-SECRET", expected = "error" },
    { status = "ok", stdout = dump, truncated = true, expected = "error" },
    { status = "ok", stdout = "", expected = "error" },
  }) do
  local runs = 0
  local result = Config.new({ platform = linux, runner = { run = function()
    runs = runs + 1 return failure
  end } }):read({})
  assert(result.status == failure.expected and result.data == nil and runs == 1)
  assert(not JSON.encode(result):find("PRIVATE", 1, true))
end
assert(Config.new({ platform = linux, runner = { run = function() error("PRIVATE") end } }):read({}).data == nil)
assert(Config.new({ platform = "macos", runner = { run = function() error("must not run") end } }):read({}).status == "unavailable")
assert(Config.new({ platform = linux, runner = { run = function() error("must not run") end } }):read({ safe_mode = true }).status == "unavailable")
assert(not pcall(Config.new, { sshd = "sshd" }))
assert(not pcall(Config.new, { config_file = "/x\0" }))
assert(not pcall(Config.new, { timeout_ms = 501 }))
assert(not pcall(SSHD.new, { config_provider = {} }))

local function section(result, id)
  for _, value in ipairs(result.sections) do if value.id == id then return value end end
  error("section missing: " .. id)
end
local context = { systemd_show = { Id = "sshd.service", LoadState = "loaded", ActiveState = "active" },
  listening_sockets = {}, sessions = {}, recent_events = {} }
local service = SSHD.new({ fs = Fixture.new({}), config_provider = provider,
  sessions_provider = false, events_provider = false })
local result = service:inspect(context)
local effective = section(result, "configuration").fields.effective
assert(effective.quality == "estimated" and #effective.value.port == 2)
assert(effective.source == "/usr/sbin/sshd" and result.details.configuration.data.scope == "global")
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "fr-FR", "ru-RU", "de-DE", "es-ES", "pt-BR", "ja-JP", "ko-KR" }) do
  local i18n = I18n.new({ lang = locale })
  local text = table.concat(TUI.inspector_lines("sshd", result, i18n), "\n")
  for _, key in ipairs({ "sshd_config.scope", "sshd_config.global", "sshd_config.file", "sshd_config.current_files" }) do
    assert(i18n:t(key) ~= key and text:find(i18n:t(key), 1, true))
  end
  assert(text:find("2222", 1, true) and not text:find("PRIVATE", 1, true))
end
effective.value.port = { "22", "2201", "2202", "2203", "2204", "2205" }
local text = table.concat(TUI.inspector_lines("sshd", result, I18n.new({ lang = "en-US" })), "\n")
assert(text:find("port[6]: 2205", 1, true), "all retained repeated configuration values must be reachable")
local previous_calls = calls
context.effective_config = "Port 2200\nPort 2222\nListenAddress 0.0.0.0:2200\nListenAddress [::]:2222\n"
result = service:inspect(context)
assert(calls == previous_calls and section(result, "configuration").fields.effective.value.port[2] == "2222")
context.effective_config = nil
result = SSHD.new({ fs = Fixture.new({}), sessions_provider = false, events_provider = false,
  config_provider = { read = function() return { status = "denied", reason = "sshd_configuration_denied" } end },
}):inspect(context)
effective = section(result, "configuration").fields.effective
assert(effective.value == nil and effective.quality == "denied")
assert(table.concat(TUI.inspector_lines("sshd", result, I18n.new({ lang = "en-US" })), "\n")
  :find("configuration", 1, true))
local repeated = Service.normalize_config("Port 22\nPort 2222\nListenAddress 0.0.0.0:22\nListenAddress [::]:2222\n")
assert(#repeated.port == 2 and #repeated.listenaddress == 2)
local file = assert(io.open("tests/fixtures/inspectors/proc-net-tcp", "rb"))
local tcp = file:read("a")
file:close()
local socket_service = SSHD.new({ fs = Fixture.new({ files = { ["/proc/net/tcp"] = tcp,
  ["/proc/net/tcp6"] = assert(tcp:match("^(.-\n)")) } }),
  config_provider = provider, sessions_provider = false, events_provider = false })
result = socket_service:inspect({ systemd_show = { MainPID = 4242 }, sessions = {}, recent_events = {} })
local listeners = section(result, "listeners").fields.listeners
assert(#listeners.value == 1 and listeners.quality == "estimated"
  and listeners.reason == "service_listener_attribution_unknown")
result = socket_service:inspect({ systemd_show = { MainPID = 4242 }, socket_owners = { [12345] = 4242 },
  sessions = {}, recent_events = {} })
listeners = section(result, "listeners").fields.listeners
assert(#listeners.value == 1 and listeners.value[1].pid == 4242 and listeners.quality == "fresh")
result = SSHD.new({ fs = Fixture.new({}), sessions_provider = false, events_provider = false,
  config_provider = { read = function() return { status = "ok", quality = "partial",
    reason = "sshd_configuration_partial", data = { configuration = { port = "22" } } } end },
}):inspect(context)
assert(result.quality == "partial" and section(result, "configuration").fields.effective.quality == "partial")
print("ok: bounded OpenSSH configuration evaluation, legacy mode, Match, scope, failure states, repeated values and privacy")
