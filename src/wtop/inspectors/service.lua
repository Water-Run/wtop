local Capability = require("wtop.core.capability")
local Clock = require("wtop.core.clock")
local Runner = require("wtop.core.runner")
local FS = require("wtop.linux.fs")
local SocketTables = require("wtop.linux.socket_tables")
local Common = require("wtop.collectors.common")
local Model = require("wtop.inspectors.model")

local Service = {}
Service.__index = Service

local MAX_SYSTEMD_BYTES = 256 * 1024
local MAX_PROCESSES = 65536
local MAX_SOCKETS = 131072
local MAX_SESSIONS = 4096
local MAX_EVENTS = 4096

local function bounded_integer(name, value, default, minimum, maximum)
  if value == nil then return default end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
      or value % 1 ~= 0 or value < minimum or value > maximum then
    error(name .. " must be an integer in " .. minimum .. ".." .. maximum, 3)
  end
  return value
end

local function safe_absolute_path(path)
  return type(path) == "string" and #path > 1 and #path <= 4096
    and path:sub(1, 1) == "/" and not path:find("\0", 1, true)
end

local function safe_identifier(value)
  return type(value) == "string" and #value > 0 and #value <= 255
    and not value:find("\0", 1, true)
    and value:match("^[A-Za-z0-9_][A-Za-z0-9_.@%-]*$") ~= nil
end

local function safe_text(value, maximum)
  if type(value) ~= "string" then return nil end
  maximum = maximum or 8192
  value = value:gsub("[%z\1-\31\127]", "�")
  if #value > maximum then value = value:sub(1, maximum) end
  while #value > 0 and not utf8.len(value) do value = value:sub(1, -2) end
  return value
end

local function decimal_integer(value)
  if type(value) == "number" then
    if value == value and value ~= math.huge and value ~= -math.huge
        and value % 1 == 0 and math.type(value) == "integer" then
      return value
    end
    return nil
  end
  if type(value) ~= "string" or not value:match("^%-?%d+$") then return nil end
  local number = tonumber(value)
  return number and math.type(number) == "integer" and number or nil
end

local SYSTEMD_FIELDS = {
  Id = "string",
  Names = "string",
  Description = "string",
  LoadState = "string",
  ActiveState = "string",
  SubState = "string",
  FragmentPath = "string",
  MainPID = "number",
  ExecMainPID = "number",
  ExecMainStatus = "number",
  ExecMainCode = "number",
  NRestarts = "number",
  Result = "string",
  StatusText = "string",
  ActiveEnterTimestampMonotonic = "number",
  MemoryCurrent = "number",
  CPUUsageNSec = "number",
  TasksCurrent = "number",
  ControlGroup = "string",
}

local SSHD_CONFIG_FIELDS = {
  port = true,
  addressfamily = true,
  listenaddress = true,
  permitrootlogin = true,
  passwordauthentication = true,
  pubkeyauthentication = true,
  maxauthtries = true,
  maxsessions = true,
  allowusers = true,
  allowgroups = true,
  authenticationmethods = true,
  loglevel = true,
}

local function parse_systemctl_show(content)
  local result = {}
  if type(content) ~= "string" then
    return result, { partial = true, reason = "content_required" }
  end
  if #content > MAX_SYSTEMD_BYTES then
    return result, { partial = true, reason = "systemd_output_too_large" }
  end
  local report = { partial = false, lines = 0, errors = 0 }
  for line in content:gmatch("[^\n]+") do
    report.lines = report.lines + 1
    if report.lines > 512 or #line > 65536 then
      report.partial = true
      report.errors = report.errors + 1
      if report.lines > 512 then break end
      goto continue
    end
    local key, value = line:match("^([%w_]+)=(.*)$")
    local kind = key and SYSTEMD_FIELDS[key]
    if kind == "number" then
      local number = decimal_integer(value)
      if number ~= nil then
        result[key] = number
      else
        report.partial = true
        report.errors = report.errors + 1
      end
    elseif kind == "string" then
      result[key] = safe_text(value)
    elseif key == nil then
      report.partial = true
      report.errors = report.errors + 1
    end
    ::continue::
  end
  return result, report
end

local function parse_proc_net(content, family)
  local sockets = {}
  local kind = family == "ipv4" and "tcp" or family == "ipv6" and "tcp6" or nil
  if not kind then return sockets, { partial = true, reason = "invalid_family" } end
  local report, parse_error = SocketTables.parse(content, kind, {
    max_bytes = 2 * 1024 * 1024,
    max_lines = MAX_SOCKETS,
    max_errors = 256,
  })
  if not report then
    return sockets, { partial = true, reason = parse_error }
  end
  for _, entry in ipairs(report.entries) do
    if entry.state == "LISTEN" then
      sockets[#sockets + 1] = {
        family = family,
        address = entry.local_address,
        port = entry.local_port,
        state = "listen",
        uid = entry.uid,
        inode = tonumber(entry.inode) or entry.inode,
      }
    end
  end
  return sockets, report
end

local function mask_address(address)
  if type(address) ~= "string" then
    return address
  end
  local a, b = address:match("^(%d+)%.(%d+)%.")
  if a then
    return a .. "." .. b .. ".x.x"
  end
  if address:find(":", 1, true) then
    local prefix = address:match("^([^:]+:[^:]+)")
    return prefix and (prefix .. ":…") or "…"
  end
  return "masked"
end

local function normalize_processes(context, name, maximum)
  local source = context and (context.processes or (context.snapshot and context.snapshot.processes))
  local list = source and (source.list or source)
  local result = {}
  local truncated = false
  if type(list) == "table" then
    for index, process in ipairs(list) do
      if index > (maximum or MAX_PROCESSES) then truncated = true break end
      if type(process) ~= "table" then goto continue end
      local process_name = tostring(process.name or process.comm or "")
      if process_name == name or process_name:sub(1, #name + 1) == name .. ":" then
        result[#result + 1] = {
          id = process.id,
          pid = process.pid,
          parent_pid = process.parent_pid,
          state = process.state,
          cpu_percent = process.cpu_percent,
          resident_bytes = process.resident_bytes,
          command = process.command,
          cgroups = process.cgroups,
        }
      end
      ::continue::
    end
  end
  return result, truncated
end

local function normalize_config(config)
  local result = {}
  local truncated = false
  if type(config) == "string" then
    if #config > 1024 * 1024 then return result, true end
    local lines = 0
    for line in config:gmatch("[^\n]+") do
      lines = lines + 1
      if lines > 4096 then truncated = true break end
      local key, value = line:match("^%s*([%w]+)%s+(.+)$")
      key = key and key:lower()
      if key and SSHD_CONFIG_FIELDS[key] then
        result[key] = safe_text(value)
      end
    end
  elseif type(config) == "table" then
    local count = 0
    for key, value in pairs(config) do
      count = count + 1
      if count > 4096 then truncated = true break end
      local normalized_key = tostring(key):lower()
      if SSHD_CONFIG_FIELDS[normalized_key] then
        if type(value) == "table" then
          local values = {}
          for index, item in ipairs(value) do
            if index > 256 then truncated = true break end
            local text = safe_text(tostring(item))
            if text then values[#values + 1] = text end
          end
          result[normalized_key] = values
        else
          result[normalized_key] = safe_text(tostring(value))
        end
      end
    end
  end
  return result, truncated
end

local function source_quality(value, source_quality_value)
  if value ~= nil then
    return source_quality_value == "fresh" and "fresh" or source_quality_value
  end
  if source_quality_value == "denied" or source_quality_value == "error" then
    return source_quality_value
  end
  return "unavailable"
end

function Service.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Service options must be a table", 2) end
  local name = options.name or "sshd"
  local id = options.id or ("service." .. name)
  local unit = options.unit or (name .. ".service")
  if not safe_identifier(name) or not safe_identifier(id) or not safe_identifier(unit) then
    error("invalid service identity", 2)
  end
  local systemctl = options.systemctl or "/usr/bin/systemctl"
  local proc_net_tcp = options.proc_net_tcp or "/proc/net/tcp"
  local proc_net_tcp6 = options.proc_net_tcp6 or "/proc/net/tcp6"
  if not safe_absolute_path(systemctl) or not safe_absolute_path(proc_net_tcp)
      or not safe_absolute_path(proc_net_tcp6) then
    error("invalid service provider path", 2)
  end
  return setmetatable({
    id = id,
    domain = "service",
    name = name,
    unit = unit,
    fs = options.fs or FS.default,
    runner = options.runner or Runner.new(),
    clock = options.clock or Clock.default,
    systemctl = systemctl,
    proc_net_tcp = proc_net_tcp,
    proc_net_tcp6 = proc_net_tcp6,
    timeout_ms = bounded_integer("timeout_ms", options.timeout_ms, 500, 1, 60000),
    max_processes = bounded_integer(
      "max_processes", options.max_processes, MAX_PROCESSES, 1, MAX_PROCESSES),
    max_sockets = bounded_integer(
      "max_sockets", options.max_sockets, MAX_SOCKETS, 1, MAX_SOCKETS),
    max_sessions = bounded_integer(
      "max_sessions", options.max_sessions, MAX_SESSIONS, 1, MAX_SESSIONS),
    max_events = bounded_integer(
      "max_events", options.max_events, 100, 0, MAX_EVENTS),
    _method_style = true,
  }, Service)
end

function Service:probe(context)
  context = type(context) == "table" and context or {}
  if context.systemd_show or #normalize_processes(context, self.name, self.max_processes) > 0 then
    return Capability.available({ source = context.systemd_show and "systemd" or "procfs" })
  end
  local fs = context.fs or self.fs
  local exists = fs:exists(self.systemctl)
  if exists then
    return Capability.available({ source = self.systemctl })
  end
  return Capability.new("degraded", {
    reason = "systemd_unavailable_process_fallback",
    source = "/proc",
  })
end

function Service:enumerate(context)
  context = type(context) == "table" and context or {}
  return {
    {
      id = self.unit,
      name = self.name,
      unit = self.unit,
      process_count = #normalize_processes(context, self.name, self.max_processes),
    },
  }
end

function Service:inspect(context, entity)
  context = type(context) == "table" and context or {}
  entity = type(entity) == "table" and entity
    or { id = self.unit, name = self.name, unit = self.unit }
  local started = Common.now_ns(context, self.clock)
  local fs = context.fs or self.fs
  local systemd
  local systemd_status = "unavailable"
  local systemd_error
  local systemd_partial = false
  if type(context.systemd_show) == "table" then
    systemd = {}
    for key, kind in pairs(SYSTEMD_FIELDS) do
      local value = context.systemd_show[key]
      if kind == "number" then
        local number = decimal_integer(value)
        if value == nil or number ~= nil then systemd[key] = number else systemd_partial = true end
      elseif value ~= nil then
        systemd[key] = safe_text(value)
        if systemd[key] == nil then systemd_partial = true end
      end
    end
    systemd_status = next(systemd) and (systemd_partial and "partial" or "fresh") or "error"
  elseif type(context.systemd_show) == "string" then
    local report
    systemd, report = parse_systemctl_show(context.systemd_show)
    systemd_partial = report and report.partial or false
    systemd_status = next(systemd) and (systemd_partial and "partial" or "fresh") or "error"
  else
    local properties = table.concat((function()
      local keys = {}
      for key in pairs(SYSTEMD_FIELDS) do
        keys[#keys + 1] = key
      end
      table.sort(keys)
      return keys
    end)(), ",")
    local run_ok, run = pcall(self.runner.run, self.runner, {
      self.systemctl,
      "show",
      self.unit,
      "--no-pager",
      "--property=" .. properties,
    }, {
      timeout_ms = self.timeout_ms,
      max_output_bytes = 256 * 1024,
    })
    if not run_ok or type(run) ~= "table" then
      systemd_error = { status = "error", reason = run_ok
        and "invalid_systemctl_runner_result" or "systemctl_runner_exception" }
      systemd_status = "error"
    elseif run.status == "ok" and not run.truncated
        and type(run.stdout) == "string" and run.stdout ~= "" then
      local report
      systemd, report = parse_systemctl_show(run.stdout)
      systemd_partial = report and report.partial or false
      systemd_status = next(systemd) and (systemd_partial and "partial" or "fresh") or "error"
    else
      systemd_error = run
      systemd_status = run.status == "denied" and "denied"
        or run.truncated and "error" or "unavailable"
    end
  end

  local processes, processes_truncated = normalize_processes(
    context, self.name, self.max_processes)
  local config, config_truncated = normalize_config(context.effective_config)
  local sockets = {}
  local sockets_partial = false
  if type(context.listening_sockets) == "table" then
    for index, socket in ipairs(context.listening_sockets) do
      if index > self.max_sockets then sockets_partial = true break end
      if type(socket) == "table" and type(socket.port) == "number"
          and socket.port % 1 == 0 and socket.port >= 0 and socket.port <= 65535 then
        sockets[#sockets + 1] = {
          family = socket.family,
          address = safe_text(socket.address),
          port = socket.port,
          state = socket.state,
          uid = decimal_integer(socket.uid),
          inode = decimal_integer(socket.inode) or safe_text(socket.inode, 64),
          pid = decimal_integer(socket.pid),
        }
      else
        sockets_partial = true
      end
    end
  else
    local tcp, tcp_error = fs:read(self.proc_net_tcp, 2 * 1024 * 1024)
    local tcp6, tcp6_error = fs:read(self.proc_net_tcp6, 2 * 1024 * 1024)
    local ipv4, ipv4_report = parse_proc_net(tcp, "ipv4")
    local ipv6, ipv6_report = parse_proc_net(tcp6, "ipv6")
    sockets_partial = tcp_error ~= nil or tcp6_error ~= nil
      or (ipv4_report and ipv4_report.partial) or (ipv6_report and ipv6_report.partial) or false
    for _, socket in ipairs(ipv4) do
      sockets[#sockets + 1] = socket
    end
    for _, socket in ipairs(ipv6) do
      sockets[#sockets + 1] = socket
    end
    -- /proc/net/tcp is host-wide.  Keep only sockets with ownership evidence
    -- or a port declared by the effective configuration.  For sshd, port 22
    -- is a labelled fallback when no config provider is available.
    local allowed_ports = {}
    local configured_ports = config.port
    if type(configured_ports) == "number" or type(configured_ports) == "string" then
      for token in tostring(configured_ports):gmatch("%d+") do
        local value = decimal_integer(token)
        if value and value >= 1 and value <= 65535 then allowed_ports[value] = true end
      end
    elseif type(configured_ports) == "table" then
      for _, port in ipairs(configured_ports) do
        local value = decimal_integer(port)
        if value and value >= 1 and value <= 65535 then allowed_ports[value] = true end
      end
    elseif self.name == "sshd" then
      allowed_ports[22] = true
    end
    local process_pids = {}
    for _, process in ipairs(processes) do
      local pid = decimal_integer(process.pid)
      if pid and pid > 0 then process_pids[pid] = true end
    end
    if systemd and systemd.MainPID then
      process_pids[systemd.MainPID] = true
    end
    local filtered = {}
    for _, socket in ipairs(sockets) do
      local owner = type(context.socket_owners) == "table"
        and (context.socket_owners[socket.inode]
          or context.socket_owners[tostring(socket.inode)]) or nil
      if allowed_ports[socket.port] or (owner and process_pids[owner]) then
        filtered[#filtered + 1] = socket
      end
    end
    sockets = filtered
  end
  if type(context.socket_owners) == "table" then
    for _, socket in ipairs(sockets) do
      socket.pid = decimal_integer(context.socket_owners[socket.inode]
        or context.socket_owners[tostring(socket.inode)])
    end
  end

  local sessions = {}
  local sessions_quality = "unavailable"
  if type(context.sessions) == "table" then
    sessions_quality = "fresh"
    for index, session in ipairs(context.sessions) do
      if index > self.max_sessions then sessions_quality = "partial" break end
      if type(session) ~= "table" then sessions_quality = "partial" goto continue_session end
      sessions[#sessions + 1] = {
        user = safe_text(session.user),
        tty = safe_text(session.tty),
        remote = context.mask_remote_addresses == false and safe_text(session.remote)
          or mask_address(safe_text(session.remote)),
        login_time = session.login_time,
        idle_seconds = session.idle_seconds,
        pid = decimal_integer(session.pid),
      }
      ::continue_session::
    end
  end

  local events
  local events_quality = "unavailable"
  if type(context.recent_events) == "table" then
    events = {}
    local requested_max = context.max_events
    if type(requested_max) ~= "number" or requested_max % 1 ~= 0
        or requested_max < 0 or requested_max > self.max_events then
      requested_max = self.max_events
    end
    for index = 1, math.min(#context.recent_events, requested_max) do
      events[index] = context.recent_events[index]
    end
    events_quality = #context.recent_events > requested_max and "partial" or "fresh"
  end
  local finished = Common.now_ns(context, self.clock)
  local source = systemd and "systemd" or "/proc"
  local status = (systemd and next(systemd)) or #processes > 0 or #sockets > 0
  status = status and "ok" or "unavailable"
  local observation_partial = systemd_partial or processes_truncated or sockets_partial
    or config_truncated or sessions_quality == "partial" or events_quality == "partial"
  local quality
  if status == "ok" then
    quality = observation_partial and "partial"
      or systemd_status == "fresh" and "fresh"
      or #processes > 0 and "estimated" or "partial"
  else
    quality = systemd_status == "denied" and "denied"
      or systemd_status == "error" and "error" or "unavailable"
  end
  local process_quality = #processes > 0
      and (processes_truncated and "partial" or "fresh")
    or processes_truncated and "partial" or "unavailable"
  local socket_quality = #sockets > 0
      and (sockets_partial and "partial" or "fresh")
    or sockets_partial and "partial" or "unavailable"
  local config_quality = next(config)
      and (config_truncated and "partial" or "fresh")
    or config_truncated and "partial" or "unavailable"

  local service_fields = {
    unit = Model.field(self.unit, nil, { source = source, timestamp_ns = finished, quality = quality }),
    description = Model.field(systemd and systemd.Description, nil, { source = "systemd", timestamp_ns = finished, quality = source_quality(systemd and systemd.Description, systemd_status) }),
    active_state = Model.field(systemd and systemd.ActiveState, nil, { source = "systemd", timestamp_ns = finished, quality = source_quality(systemd and systemd.ActiveState, systemd_status) }),
    sub_state = Model.field(systemd and systemd.SubState, nil, { source = "systemd", timestamp_ns = finished, quality = source_quality(systemd and systemd.SubState, systemd_status) }),
    main_pid = Model.field(systemd and systemd.MainPID, "pid", { source = "systemd", timestamp_ns = finished, quality = source_quality(systemd and systemd.MainPID, systemd_status) }),
    restarts = Model.field(systemd and systemd.NRestarts, "count", { source = "systemd", timestamp_ns = finished, quality = source_quality(systemd and systemd.NRestarts, systemd_status) }),
    result = Model.field(systemd and systemd.Result, nil, { source = "systemd", timestamp_ns = finished, quality = source_quality(systemd and systemd.Result, systemd_status) }),
    exit_status = Model.field(systemd and systemd.ExecMainStatus, "exit_code", { source = "systemd", timestamp_ns = finished, quality = source_quality(systemd and systemd.ExecMainStatus, systemd_status) }),
    memory = Model.field(systemd and systemd.MemoryCurrent, "bytes", { source = "systemd", timestamp_ns = finished, quality = source_quality(systemd and systemd.MemoryCurrent, systemd_status) }),
    cpu_time = Model.field(systemd and systemd.CPUUsageNSec, "nanoseconds", { source = "systemd", timestamp_ns = finished, quality = source_quality(systemd and systemd.CPUUsageNSec, systemd_status) }),
    cgroup = Model.field(systemd and systemd.ControlGroup, nil, { source = "systemd", timestamp_ns = finished, quality = source_quality(systemd and systemd.ControlGroup, systemd_status) }),
  }
  local process_fields = {
    processes = Model.field(processes, nil, { source = "/proc", timestamp_ns = finished,
      quality = process_quality, reason = processes_truncated and "process_limit_reached" }),
  }
  local socket_fields = {
    listeners = Model.field(sockets, nil, { source = { self.proc_net_tcp, self.proc_net_tcp6 },
      timestamp_ns = finished, quality = socket_quality,
      reason = sockets_partial and "socket_data_partial" }),
  }
  local session_fields = {
    active_sessions = Model.field(sessions, nil, { source = context.sessions_source, timestamp_ns = finished, quality = sessions_quality, reason = sessions_quality == "unavailable" and "session_provider_unavailable" }),
  }
  local event_fields = {
    recent_events = Model.field(events, nil, { source = context.events_source, timestamp_ns = finished, quality = events_quality, permission = "journal_read_may_be_required", reason = events_quality == "unavailable" and "event_provider_unavailable" }),
  }
  local config_fields = {
    effective = Model.field(config, nil, { source = context.config_source,
      timestamp_ns = finished, quality = config_quality,
      reason = config_truncated and "configuration_limit_reached" }),
  }
  local entity_id = safe_identifier(entity.id) and entity.id or self.unit
  local normalized = Model.entity(entity_id, "service", {
    name = safe_text(entity.name) or self.name,
    summary = service_fields,
    relations = { processes = processes, listeners = sockets, sessions = sessions },
    evidence = {
      timestamp_ns = finished,
      systemd_error = systemd_error,
      sessions_quality = sessions_quality,
      events_quality = events_quality,
      partial = observation_partial,
    },
  })
  return Model.result(status, normalized, {
    Model.section("service", service_fields, { quality = quality, source = source }),
    Model.section("processes", process_fields, { quality = process_quality, source = "/proc" }),
    Model.section("listeners", socket_fields, { quality = socket_quality, source = { self.proc_net_tcp, self.proc_net_tcp6 } }),
    Model.section("sessions", session_fields, { quality = sessions_quality, source = context.sessions_source }),
    Model.section("events", event_fields, { quality = events_quality, source = context.events_source }),
    Model.section("configuration", config_fields, { quality = config_quality, source = context.config_source }),
  }, {
    timestamp_ns = finished,
    duration_ns = math.max(0, finished - started),
    quality = quality,
    reason = status == "unavailable" and "service_not_observed" or nil,
    source = source,
    provider = systemd and "systemd" or "procfs",
    details = {
      systemd_status = systemd_status,
      systemd_error = systemd_error,
      processes_truncated = processes_truncated,
      sockets_partial = sockets_partial,
      config_truncated = config_truncated,
    },
  })
end

function Service:invalidate()
  -- Current service data is intentionally uncached.
end

Service.parse_systemctl_show = parse_systemctl_show
Service.parse_proc_net = parse_proc_net
Service.mask_address = mask_address
Service.normalize_config = normalize_config
Service.normalize_processes = normalize_processes

return Service
