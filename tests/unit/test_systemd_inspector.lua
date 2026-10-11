package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local Systemd = require("wtop.inspectors.systemd")
local Runner = require("wtop.core.runner")
local Fixture = require("support.fixture_fs")
local I18n = require("wtop.i18n")
local TUI = require("wtop.tui")
local clock = { now_ns = function() return 1000000000 end }
local fs = Fixture.new({ files = { ["/usr/bin/systemctl"] = "tool", ["/run/user/1000/bus"] = "bus" } })
local calls = {}
local show = table.concat({
  "Id=worker@a.service", "Names=worker@a.service worker-alias.service",
  "LoadState=loaded", "ActiveState=active", "SubState=running",
  "Description=Worker", "MainPID=42", "ControlGroup=/system.slice/worker@a.service",
  "MemoryCurrent=1024", "CPUUsageNSec=2000000000", "TasksCurrent=3",
  "MemoryMax=infinity", "TasksMax=100", "CPUQuotaPerSecUSec=2000000",
  "ExecStart=PRIVATE-COMMAND", "Environment=PRIVATE-SECRET", "\n",
}, "\n")
local response = { status = "ok", stdout = show, exit_code = 0 }
local runner = Runner.new({ execute = function(argv, policy)
  calls[#calls + 1] = { argv = argv, policy = policy }
  assert(policy.timeout_ms == 750 and policy.max_output_bytes == 256 * 1024)
  assert(policy.env.LANG == "C" and policy.env.LC_ALL == "C")
  if argv[4] == "list-units" then
    return { status = "ok", exit_code = 0, stdout =
      "worker@a.service loaded active running Worker\n"
      .. "idle.service loaded inactive dead Idle\n"
      .. "app.scope loaded active running App\n" }
  end
  return response
end })
local inspector = Systemd.new({ fs = fs, runner = runner, clock = clock, uid = 1000, platform = "linux" })
assert(inspector:probe({}).available and #calls == 0, "probe must not query a manager")
local entities = assert(inspector:enumerate({}))
assert(#entities == 6 and #calls == 2)
assert(calls[1].argv[2] == "--system" and calls[1].policy.env.XDG_RUNTIME_DIR == nil)
assert(calls[2].argv[2] == "--user" and calls[2].policy.env.XDG_RUNTIME_DIR == "/run/user/1000")
local selected = assert(Systemd.from_workload({ id = "/system.slice/worker@a.service" }))
assert(selected.id == "system:worker@a.service" and selected.manager == "system")
local result = inspector:inspect({}, selected)
assert(result.status == "ok" and result.quality == "fresh")
local fields = result.entity.summary
assert(fields.main_pid.value == 42 and fields.memory.value == 1024
  and fields.cpu_time.value == 2000000000 and fields.tasks.value == 3)
assert(fields.memory_max.value == "unlimited" and fields.tasks_max.value == 100
  and fields.cpu_quota.value == 200)
assert(result.entity.relations.main_pid == 42
  and result.entity.relations.workload_id == "/system.slice/worker@a.service")
local complete_result = result
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "fr-FR", "ru-RU", "de-DE", "es-ES", "pt-BR", "ja-JP", "ko-KR" }) do
  local i18n = I18n.new({ lang = locale })
  local text = table.concat(TUI.systemd_unit_lines(result, i18n, 2000000000), "\n")
  assert(text:find("worker@a.service", 1, true) and text:find(i18n:t("systemd.unlimited"), 1, true))
  for _, key in ipairs({ "systemd.main_pid", "systemd.manager", "systemd.detail_hint", "systemd.sample_age" }) do
    assert(i18n:t(key) ~= key and text:find(i18n:t(key), 1, true), locale .. " lacks " .. key)
  end
end
assert(fields.ExecStart == nil and fields.Environment == nil)
local last = calls[#calls]
assert(last.argv[4] == "show" and last.argv[#last.argv - 1] == "--"
  and last.argv[#last.argv] == "worker@a.service", "units stay positional argv arguments")

-- User-manager units have the same names as system-manager units, and must
-- keep their UID and manager as part of their identity.
local user_unit = assert(Systemd.from_workload({
  id = "/user.slice/user-1000.slice/user@1000.service/app.slice/app.scope" }))
assert(user_unit.manager == "user" and user_unit.uid == 1000 and user_unit.id == "user:1000:app.scope")
assert(Systemd.from_workload({ id = "/user.slice/user-1000.slice/user@1000.service" }).manager == "system")
assert(Systemd.from_workload({ id = "/system.slice/worker.service/opaque" }) == nil)
assert(Systemd.from_workload({ id = "/../worker.service" }) == nil)
assert(Systemd.from_workload({ id = "/foo.service\27" }) == nil)
local before = #calls
user_unit.uid, user_unit.id = 2000, "user:2000:app.scope"
assert(inspector:inspect({}, user_unit).reason == "systemd_user_unavailable" and #calls == before)
assert(inspector:inspect({ safe_mode = true }, selected).status == "unavailable" and #calls == before)
local empty_fs = Fixture.new({})
assert(not Systemd.new({ fs = empty_fs, platform = "linux" }):probe({}).available)
assert(not Systemd.new({ fs = fs, platform = "windows" }):probe({}).available)

-- Aliases are accepted only when the returned Names list confirms them.
local alias = { id = "system:worker-alias.service", unit = "worker-alias.service", manager = "system" }
assert(inspector:inspect({}, alias).status == "ok")
response = { status = "ok", stdout = show:gsub("worker%-alias.service", "unrelated.service"), exit_code = 0 }
assert(inspector:inspect({}, alias).reason == "systemd_unit_changed")
response = { status = "ok", stdout = show:gsub("ControlGroup=/system.slice/worker@a.service",
  "ControlGroup=/elsewhere"), exit_code = 0 }
assert(inspector:inspect({}, selected).reason == "systemd_unit_changed")
response = { status = "ok", stdout = show .. "Id=other.service\n", exit_code = 0 }
assert(inspector:inspect({}, selected).status == "unavailable")
response = { status = "ok", stdout = show:gsub("LoadState=loaded", "LoadState=not-found"), exit_code = 0 }
assert(inspector:inspect({}, selected).status == "unavailable")
for _, failed in ipairs({ { status = "denied" }, { status = "timeout" }, { status = "error" },
    { status = "ok", stdout = show, truncated = true } }) do
  response = failed
  assert(inspector:inspect({}, selected).status ~= "ok")
end
response = { status = "ok", stdout = show:gsub("MemoryCurrent=1024", "MemoryCurrent=18446744073709551615")
  :gsub("TasksCurrent=3", "TasksCurrent=18446744073709551615"), exit_code = 0 }
result = inspector:inspect({}, selected)
assert(result.status == "ok" and result.quality == "fresh"
  and result.entity.summary.memory.value == nil and result.entity.summary.memory.quality == "unavailable"
  and result.entity.summary.tasks.value == nil, "unknown accounting is not a zero reading")
response = { status = "ok", stdout = show:gsub("MemoryCurrent=1024", "MemoryCurrent=bad"), exit_code = 0 }
result = inspector:inspect({}, selected)
assert(result.quality == "partial" and result.reason == "systemd_data_incomplete")

local list = assert(Systemd.parse_list("worker\\x2dtest.service loaded active running Name\n"
  .. "-dash.service loaded inactive dead Dash\n../bad.service loaded active running Bad\n", "system"))
assert(#list == 2 and list.partial)
assert(Systemd.unit_name("foo@bar.service") and Systemd.unit_name("foo.timer")
  and Systemd.unit_name("dev-a.device"))
for _, name in ipairs({ "a@.service", "../bad.service", "x;rm.service", "@a.service", "a@@b.service",
    "x\0.service", string.rep("a", 250) .. ".service" }) do
  assert(not Systemd.unit_name(name))
end
assert(Systemd.parse_show(string.rep("x", 256 * 1024 + 1)) == nil)
local clipped = Systemd.new({ fs = fs, runner = runner, clock = clock, uid = 1000,
  platform = "linux", max_units = 1 }):enumerate({})
assert(#clipped == 1 and clipped.truncated)
local wanted = inspector:enumerate({ systemd_workload = { id = "/system.slice/worker@a.service" } })
assert(#wanted == 1 and wanted[1].cgroup_id == "/system.slice/worker@a.service")

-- Search runs over the full enumerated set before the display cap.
local many = {}
for index = 1, 600 do
  many[index] = { unit = "worker" .. index .. ".service", manager = "system", unit_type = "service" }
end
many[601] = { unit = "last.scope", manager = "user", unit_type = "scope" }
local found, matches = Systemd.filter_entities(many, "manager:user type:scope last", 256)
assert(#found == 1 and matches == 1 and found[1] == many[601])
found, matches = Systemd.filter_entities(many, "worker", 256)
assert(#found == 256 and matches == 600)
assert(#Systemd.filter_entities(many, "[", 256) == 0)
for _, options in ipairs({ { uid = false }, { uid = -1 }, { systemctl = "relative" }, { max_units = 1025 } }) do
  assert(not pcall(Systemd.new, options))
end

local function stat_line(pid, started)
  local values = {}
  for index = 1, 44 do values[index] = "0" end
  values[15], values[17], values[19] = "20", "1", tostring(started)
  return pid .. " (worker) S " .. table.concat(values, " ") .. "\n"
end
local process_fs = Fixture.new({ files = {
  ["/proc/42/stat"] = stat_line(42, 4096),
  ["/proc/42/cgroup"] = "0::/system.slice/worker@a.service/child\n",
} })
local process = { id = "42:4096", pid = 42, starttime_ticks = 4096 }
assert(Systemd.resolve_process(complete_result, { process }, process_fs) == process,
  "main-process navigation requires current identity and matching cgroup containment")
local sampled, observed = Systemd.resolve_process(complete_result, {}, process_fs)
assert(sampled == nil and observed.id == process.id and observed.pid == 42)
local reused = Fixture.new({ files = {
  ["/proc/42/stat"] = stat_line(42, 4097),
  ["/proc/42/cgroup"] = "0::/system.slice/worker@a.service\n",
} })
assert(Systemd.resolve_process(complete_result, { process }, reused) == nil,
  "a recycled PID cannot inherit an earlier sampled process")
local wrong_unit = Fixture.new({ files = {
  ["/proc/42/stat"] = stat_line(42, 4096),
  ["/proc/42/cgroup"] = "0::/system.slice/worker@a.service-other\n",
} })
assert(Systemd.resolve_process(complete_result, { process }, wrong_unit) == nil,
  "a similar prefix is not a child cgroup")
assert(Systemd.resolve_process({ status = "unavailable" }, { process }, process_fs) == nil)

print("ok: system and user units, bounded providers, identity, accounting, limits and search")
