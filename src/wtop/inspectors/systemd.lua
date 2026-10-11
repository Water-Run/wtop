-- Read-only system and current-user systemd units. No helper runs at probe time.
local Capability = require("wtop.core.capability")
local Clock = require("wtop.core.clock")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local GUID = require("wtop.core.guid")
local Model = require("wtop.inspectors.model")
local Native = require("wtop.native")
local Platform = require("wtop.platform")
local Runner = require("wtop.core.runner")
local Semantics = require("wtop.collectors.cgroup_semantics")
local ProcessCgroup = require("wtop.linux.process_cgroup")

local Systemd = {}
Systemd.__index = Systemd
local MAX_BYTES, MAX_UNITS = 256 * 1024, 1024
local TYPES = { service = true, socket = true, device = true, mount = true,
  automount = true, swap = true, target = true, path = true, timer = true,
  slice = true, scope = true }
local FIELDS = {
  Id = "text", Names = "text", Description = "text", LoadState = "text",
  ActiveState = "text", SubState = "text", FragmentPath = "text",
  ControlGroup = "path", MainPID = "pid", Leader = "pid", NRestarts = "number",
  ExecMainCode = "number", ExecMainStatus = "number", Result = "text",
  MemoryCurrent = "counter", CPUUsageNSec = "counter", TasksCurrent = "counter",
  MemoryMax = "limit", TasksMax = "limit", CPUQuotaPerSecUSec = "limit",
}
local PROPERTIES = {}
for name in pairs(FIELDS) do PROPERTIES[#PROPERTIES + 1] = name end
table.sort(PROPERTIES)

local function uid(value)
  return type(value) == "number" and math.type(value) == "integer"
    and value >= 0 and value <= 4294967295 and value or nil
end

local function effective_uid()
  if type(Native.uid) ~= "function" then return nil end
  local ok, real, effective = pcall(Native.uid)
  return ok and (uid(effective) or uid(real)) or nil
end

local function unit_name(value)
  if type(value) ~= "string" or #value > 255 then return nil end
  local stem, kind = value:match("^(.+)%.([a-z]+)$")
  if not stem or not TYPES[kind] or stem:find("[^A-Za-z0-9:_.@\\%-]") then return nil end
  local _, instances = stem:gsub("@", "")
  if instances > 1 or stem:sub(1, 1) == "@" then return nil end
  -- A template has no runtime entity until an instance is supplied.
  if stem:sub(-1) == "@" then return nil end
  return kind
end

local function cgroup_path(value)
  if type(value) ~= "string" or value:sub(1, 1) ~= "/" or #value > 4096
      or value:find("[%z\1-\31\127]") or value:find("//", 1, true) then return nil end
  for part in value:gmatch("[^/]+") do
    if part == "." or part == ".." then return nil end
  end
  return value
end

local function entity(unit, manager, user_id, description, group)
  local kind = unit_name(unit)
  if not kind or (manager ~= "system" and manager ~= "user")
      or (manager == "user" and not uid(user_id)) then return nil end
  return { id = manager .. (manager == "user" and (":" .. user_id) or "") .. ":" .. unit,
    name = unit, unit = unit, unit_type = kind, manager = manager,
    uid = manager == "user" and user_id or nil,
    description = Common.safe_text(description, 256), cgroup_id = group }
end

function Systemd.from_workload(node)
  local path = type(node) == "table" and cgroup_path(node.id)
  if not path then return nil end
  local class = Semantics.classify(path)
  if not class.unit or path:match("([^/]+)$") ~= class.unit then return nil end
  local user_id = path:match("/user@(%d+)%.service/")
  if user_id then
    user_id = uid(tonumber(user_id))
    if user_id == nil then return nil end
  end
  return entity(class.unit, user_id and "user" or "system", user_id, nil, path)
end

function Systemd.from_session(result)
  local session = type(result) == "table" and result.status == "ok" and result.entity
  local info = type(session) == "table" and session.kind == "session" and session.identity
  local fields = session and session.summary
  local scope = type(fields) == "table" and fields.scope and fields.scope.value
  local leader = type(fields) == "table" and fields.leader_pid and fields.leader_pid.value
  if type(info) ~= "table" or type(info.session_id) ~= "string" or #info.session_id > 64
      or not info.session_id:match("^[A-Za-z0-9][A-Za-z0-9_%-]*$")
      or uid(info.uid) == nil or type(info.started_us) ~= "number" or math.type(info.started_us) ~= "integer"
      or info.started_us <= 0 or not GUID.normalize(info.boot_id)
      or session.id ~= info.boot_id .. ":" .. info.session_id .. ":" .. info.uid .. ":" .. info.started_us
      or not fields.uid or fields.uid.value ~= info.uid
      or not fields.session_id or fields.session_id.value ~= info.session_id
      or unit_name(scope) ~= "scope" or scope ~= "session-" .. info.session_id .. ".scope"
      or (leader ~= nil and (type(leader) ~= "number" or math.type(leader) ~= "integer"
        or leader <= 0 or leader > 2147483647)) then
    return nil
  end
  local selected = entity(scope, "system")
  selected.session_leader = leader
  return selected
end

function Systemd.parse_list(raw, manager, user_id, maximum)
  if type(raw) ~= "string" or #raw > MAX_BYTES then return nil end
  local result, seen = {}, {}
  maximum = maximum or MAX_UNITS
  for line in raw:gmatch("[^\n]+") do
    local unit, load, active, sub, description = line:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*(.*)$")
    local item = unit and entity(unit, manager, user_id, description)
    if item and not seen[item.id] then
      seen[item.id] = true
      if #result < maximum then
        item.load_state, item.active_state, item.sub_state = load, active, sub
        result[#result + 1] = item
      else result.truncated = true end
    elseif unit and not item then result.partial = true end
  end
  return result
end

function Systemd.parse_show(raw)
  if type(raw) ~= "string" or #raw > MAX_BYTES then return nil end
  local result, seen, partial, lines = {}, {}, false, 0
  for line in raw:gmatch("[^\n]+") do
    lines = lines + 1
    if lines > 512 then return nil end
    local key, value = line:match("^([A-Za-z]+)=(.*)$")
    local kind = key and FIELDS[key]
    if not key or #line > 8192 then partial = true
    elseif kind then
      if seen[key] then
        result[key], partial = nil, true
      else
        if kind == "text" then
          result[key] = Common.safe_text(value, 4096)
          if #value > 4096 or value:find("[%z\1-\31\127]") then partial = true end
        elseif kind == "path" then
          result[key] = value ~= "" and cgroup_path(value) or nil
          if value ~= "" and not result[key] then partial = true end
        elseif kind == "limit" and (value == "infinity" or value == "18446744073709551615") then
          result[key] = "unlimited"
        elseif kind == "counter" and value == "18446744073709551615" then
          -- systemd uses UINT64_MAX for counters it cannot currently read.
        else
          local number = value:match("^%d+$") and tonumber(value)
          if number and math.type(number) == "integer" and number >= 0
              and (kind ~= "pid" or number <= 2147483647) then result[key] = number
          else partial = true end
        end
      end
      seen[key] = true
    end
  end
  return result, partial
end

function Systemd.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Systemd options must be a table", 2) end
  local executable = options.systemctl or "/usr/bin/systemctl"
  if type(executable) ~= "string" or executable:sub(1, 1) ~= "/"
      or #executable > 4096 or executable:find("\0", 1, true) then
    error("systemctl must be an absolute path", 2)
  end
  local user_id = options.uid
  if user_id == nil then user_id = effective_uid() end
  if user_id ~= nil and uid(user_id) == nil then error("invalid systemd user ID", 2) end
  return setmetatable({ id = "service.systemd", domain = "service", _method_style = true,
    platform = options.platform or Platform.id(), fs = options.fs or FS.default,
    runner = options.runner or Runner.new(), clock = options.clock or Clock.default,
    systemctl = executable, uid = user_id,
    max_units = Common.positive_integer("max_units", options.max_units, MAX_UNITS, MAX_UNITS),
    timeout_ms = Common.positive_integer("timeout_ms", options.timeout_ms, 750, 2000),
  }, Systemd)
end

function Systemd:probe(context)
  local fs = context and context.fs or self.fs
  if self.platform ~= "linux" or not fs:exists(self.systemctl) then
    return Capability.unavailable("systemctl_unavailable", { source = self.systemctl })
  end
  return Capability.available({ source = self.systemctl, reason = "systemd_not_queried" })
end

function Systemd:_run(context, manager, arguments)
  if self.platform ~= "linux" or context.safe_mode == true then return { status = "unavailable" } end
  local argv = { self.systemctl, manager == "user" and "--user" or "--system", "--no-pager" }
  for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
  local environment = { LANG = "C", LC_ALL = "C" }
  if manager == "user" then
    if self.uid == nil then return { status = "unavailable" } end
    -- Only the current effective user is queried. In a root session this is
    -- /run/user/0, not a runtime directory inherited from the sudo caller.
    environment.XDG_RUNTIME_DIR = "/run/user/" .. self.uid
  end
  local ok, run = pcall(self.runner.run, self.runner, argv,
    { timeout_ms = self.timeout_ms, max_output_bytes = MAX_BYTES, env = environment })
  return ok and type(run) == "table" and run or { status = "error" }
end

function Systemd:enumerate(context)
  context = type(context) == "table" and context or {}
  if context.systemd_session then
    local selected = Systemd.from_session(context.systemd_session)
    return selected and { selected } or {}, "logind_scope_unavailable"
  end
  if context.systemd_workload then
    local selected = Systemd.from_workload(context.systemd_workload)
    return selected and { selected } or {}, "systemd_unit_unavailable"
  end
  local managers, fs = { "system" }, context.fs or self.fs
  if self.uid ~= nil and fs:exists("/run/user/" .. self.uid .. "/bus") then
    managers[#managers + 1] = "user"
  end
  local result, any_success = {}, false
  local per_manager = math.max(1, self.max_units // #managers)
  for _, manager in ipairs(managers) do
    local run = self:_run(context, manager, { "list-units", "--all", "--full", "--plain", "--no-legend" })
    if run.status == "ok" and type(run.stdout) == "string" then
      local raw = run.stdout
      if run.truncated then raw = raw:match("^(.*)\n") or "" end
      local items = Systemd.parse_list(raw, manager, self.uid, per_manager)
      if items then
        any_success = true
        for _, item in ipairs(items) do
          if #result < self.max_units then result[#result + 1] = item
          else result.truncated = true end
        end
        result.truncated = result.truncated or run.truncated == true or items.truncated == true
        result.partial = result.partial or items.partial == true
      else result.partial = true end
    else result.partial = true end
  end
  table.sort(result, function(left, right) return left.id < right.id end)
  if not any_success then return nil, "systemd_units_unavailable" end
  return result
end

function Systemd:inspect(context, selected)
  context = type(context) == "table" and context or {}
  local started = Common.now_ns(context, self.clock)
  local function failure(status, reason)
    return Model.result(status, nil, {}, { quality = status, reason = reason,
      source = self.systemctl, provider = "systemctl_show",
      timestamp_ns = Common.now_ns(context, self.clock) })
  end
  if type(selected) ~= "table" or not unit_name(selected.unit)
      or (selected.manager ~= "system" and selected.manager ~= "user") then
    return failure("unavailable", "systemd_unit_unavailable")
  end
  local expected = entity(selected.unit, selected.manager, selected.uid)
  if not expected or selected.id ~= expected.id
      or (selected.cgroup_id ~= nil and not cgroup_path(selected.cgroup_id)) then
    return failure("unavailable", "systemd_unit_unavailable")
  end
  if selected.manager == "user" and (self.uid == nil or selected.uid ~= self.uid) then
    return failure("unavailable", "systemd_user_unavailable")
  end
  local run = self:_run(context, selected.manager,
    { "show", "--property=" .. table.concat(PROPERTIES, ","), "--", selected.unit })
  if run.status ~= "ok" or run.truncated or type(run.stdout) ~= "string" then
    return failure(run.status == "denied" and "denied" or "unavailable", "systemd_unit_unavailable")
  end
  local data, partial = Systemd.parse_show(run.stdout)
  if not data or not unit_name(data.Id) or data.LoadState == "not-found" then
    return failure("unavailable", "systemd_unit_unavailable")
  end
  local named = data.Id == selected.unit
  for name in (data.Names or ""):gmatch("%S+") do if name == selected.unit then named = true end end
  if not named or unit_name(data.Id) ~= unit_name(selected.unit)
      or (selected.cgroup_id and data.ControlGroup ~= selected.cgroup_id)
      or (selected.session_leader and data.Leader ~= nil and data.Leader ~= selected.session_leader) then
    return failure("unavailable", "systemd_unit_changed")
  end
  if not data.LoadState or not data.ActiveState or not data.SubState then partial = true end
  local finished = Common.now_ns(context, self.clock)
  local source = "systemd:" .. selected.manager
    .. (selected.manager == "user" and (":" .. self.uid) or "")
  local values = {
    unit = data.Id, description = data.Description, unit_type = unit_name(data.Id),
    manager = selected.manager, load_state = data.LoadState, active_state = data.ActiveState,
    sub_state = data.SubState, fragment_path = data.FragmentPath, cgroup = data.ControlGroup,
    main_pid = data.MainPID, leader_pid = data.Leader, restarts = data.NRestarts,
    result = data.Result, exit_status = data.ExecMainStatus, exit_code = data.ExecMainCode,
    memory = data.MemoryCurrent, cpu_time = data.CPUUsageNSec, tasks = data.TasksCurrent,
    memory_max = data.MemoryMax, tasks_max = data.TasksMax,
    cpu_quota = type(data.CPUQuotaPerSecUSec) == "number" and data.CPUQuotaPerSecUSec / 10000
      or data.CPUQuotaPerSecUSec,
  }
  local units = { memory = "bytes", memory_max = "bytes", cpu_time = "nanoseconds",
    tasks = "count", tasks_max = "count", cpu_quota = "percent" }
  local fields = {}
  for _, key in ipairs({ "unit", "description", "unit_type", "manager", "load_state",
      "active_state", "sub_state", "fragment_path", "cgroup", "main_pid", "leader_pid",
      "restarts", "result", "exit_status", "exit_code", "memory", "cpu_time", "tasks",
      "memory_max", "tasks_max", "cpu_quota" }) do
    fields[key] = Model.field(values[key], units[key], { source = source, timestamp_ns = finished })
  end
  local quality = partial and "partial" or "fresh"
  local normalized = Model.entity(selected.id, "service", { name = data.Id,
    identity = { unit = data.Id, manager = selected.manager, uid = selected.uid },
    summary = fields, relations = { workload_id = data.ControlGroup,
      main_pid = data.MainPID and data.MainPID > 0 and data.MainPID
        or data.Leader and data.Leader > 0 and data.Leader or nil } })
  return Model.result("ok", normalized, { Model.section("service", fields, { quality = quality, source = source }) },
    { timestamp_ns = finished, duration_ns = Common.elapsed_ns(finished, started) or 0,
      quality = quality, source = source, provider = "systemctl_show",
      reason = partial and "systemd_data_incomplete" or nil })
end

function Systemd.filter_entities(entities, query, maximum)
  local result, matches = {}, 0
  query, maximum = type(query) == "string" and query:lower() or "", maximum or 256
  local tokens = {}
  for token in query:gmatch("%S+") do
    tokens[#tokens + 1] = { text = token, manager = token:match("^manager:(.+)$"),
      kind = token:match("^type:(.+)$") }
  end
  for _, item in ipairs(entities or {}) do
    local text = (item.unit .. " " .. item.manager .. " " .. (item.description or "")):lower()
    local match = true
    for _, token in ipairs(tokens) do
      local manager, kind = token.manager, token.kind
      if (manager and item.manager ~= manager) or (kind and item.unit_type ~= kind)
          or (not manager and not kind and not text:find(token.text, 1, true)) then match = false break end
    end
    if match then
      matches = matches + 1
      if #result < maximum then result[#result + 1] = item end
    end
  end
  return result, matches
end

Systemd.unit_name = unit_name
Systemd.cgroup_path = cgroup_path

function Systemd.resolve_process(result, processes, fs)
  local relations = result and result.status == "ok" and result.entity and result.entity.relations
  local pid = relations and relations.main_pid
  local path = relations and cgroup_path(relations.workload_id)
  if not pid or not path then return nil end
  local function belongs(actual)
    return actual == path or (path ~= "/" and type(actual) == "string"
      and actual:sub(1, #path + 1) == path .. "/")
  end
  for _, process in ipairs(processes or {}) do
    if process.pid == pid then
      if belongs(ProcessCgroup.target_id(process, fs)) then return process end
      return nil
    end
  end
  local observed, actual = ProcessCgroup.observe(pid, fs)
  if observed and belongs(actual) then return nil, observed end
  return nil
end
return Systemd
