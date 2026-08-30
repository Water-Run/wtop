local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local Cgroup = {}
Cgroup.__index = Cgroup

local SCHEMA = "dev.waterrun.wtop.cgroup/v1"
local DEFAULT_MAX_DEPTH = 16
local DEFAULT_MAX_NODES = 4096
local MAX_FILE_BYTES = 4 * 1024 * 1024
local MAX_ISSUES_PER_NODE = 128
local DIRECTORY_ENTRY_SLACK = 64
local MAX_DIRECTORY_ENTRIES = 2147483647
local MAX_PIDS_PER_NODE = 65536

local METRIC_FILES = {
  ["cgroup.procs"] = true,
  ["cpu.stat"] = true,
  ["cpu.max"] = true,
  ["cpu.weight"] = true,
  ["memory.current"] = true,
  ["memory.peak"] = true,
  ["memory.low"] = true,
  ["memory.high"] = true,
  ["memory.max"] = true,
  ["memory.swap.current"] = true,
  ["memory.events"] = true,
  ["io.stat"] = true,
  ["pids.current"] = true,
  ["pids.max"] = true,
  ["pids.events"] = true,
  ["cpu.pressure"] = true,
  ["memory.pressure"] = true,
  ["io.pressure"] = true,
  ["cpuset.cpus.effective"] = true,
  ["cpuset.mems.effective"] = true,
  -- These core files are used by probing or topology management rather than
  -- node metrics.  Keeping them out of discovery also avoids spending the
  -- candidate budget on the two files present in every cgroup directory.
  ["cgroup.controllers"] = true,
  ["cgroup.subtree_control"] = true,
}

local function directory_entry_limit(remaining_nodes)
  remaining_nodes = math.max(0, remaining_nodes)
  return math.min(remaining_nodes, MAX_DIRECTORY_ENTRIES - DIRECTORY_ENTRY_SLACK)
    + DIRECTORY_ENTRY_SLACK
end

local function sorted_keys(values)
  local keys = {}
  for key in pairs(values or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function option_integer(name, value, default, minimum, maximum)
  if value == nil then
    return default
  end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
      or value % 1 ~= 0 or value < minimum or value > maximum then
    error(name .. " must be an integer in " .. minimum .. ".." .. maximum, 3)
  end
  return value
end

local function normalize_mount_path(value)
  value = value or "/sys/fs/cgroup"
  if type(value) ~= "string" or value == "" or #value > 4096
      or value:sub(1, 1) ~= "/" or value:find("%z") then
    error("mount_path must be an absolute path", 3)
  end
  for component in value:gmatch("[^/]+") do
    if component == "." or component == ".." then
      error("mount_path must not contain dot path components", 3)
    end
  end
  if value ~= "/" then
    value = value:gsub("/+$", "")
  end
  return value
end

local function normalize_root(value)
  value = value or "/"
  if type(value) ~= "string" or #value > 4096 or value:find("%z") then
    error("root must be a cgroup path", 3)
  end
  value = value:gsub("^/+", ""):gsub("/+$", "")
  local components = {}
  for component in value:gmatch("[^/]+") do
    if component == "." or component == ".." or component:sub(1, 1) == "." then
      error("root must not contain dot path components", 3)
    end
    components[#components + 1] = component
  end
  local relative = table.concat(components, "/")
  return relative, relative == "" and "/" or "/" .. relative
end

local function join_path(base, relative)
  if relative == "" then
    return base
  end
  if base == "/" then
    return "/" .. relative
  end
  return base .. "/" .. relative
end

local function child_id(parent_id, name)
  if parent_id == "/" then
    return "/" .. name
  end
  return parent_id .. "/" .. name
end

local function basename(id)
  if id == "/" then
    return "/"
  end
  return id:match("([^/]+)$") or id
end

local function trim(value)
  return Common.trim(value or "")
end

local function parse_uint(content)
  local value = trim(content)
  if not value:match("^%d+$") then
    return nil, "expected_unsigned_integer"
  end
  local number = tonumber(value)
  if number == nil or number ~= number or number == math.huge
      or (math.type and math.type(number) ~= "integer") then
    return nil, "integer_out_of_range"
  end
  return number
end

local function parse_limit(content)
  local value = trim(content)
  if value == "max" then
    return "max"
  end
  return parse_uint(value)
end

local function parse_cpu_max(content)
  local quota, period, extra = trim(content):match("^(%S+)%s+(%S+)%s*(%S*)$")
  if not quota or extra ~= "" then
    return nil, "expected_cpu_max_quota_and_period"
  end
  local parsed_quota, quota_error = parse_limit(quota)
  if parsed_quota == nil then
    return nil, quota_error
  end
  local parsed_period, period_error = parse_uint(period)
  if parsed_period == nil or parsed_period <= 0 then
    return nil, period_error or "cpu_period_must_be_positive"
  end
  return {
    quota_usec = parsed_quota,
    period_usec = parsed_period,
  }
end

local function parse_key_values(content, allow_empty)
  local output = {}
  local count = 0
  for line in tostring(content):gmatch("[^\r\n]+") do
    local key, raw, extra = line:match("^%s*([%w_.-]+)%s+(%S+)%s*(%S*)%s*$")
    if not key or extra ~= "" then
      return nil, "invalid_key_value_line"
    end
    if output[key] ~= nil then
      return nil, "duplicate_key_" .. key
    end
    local value, value_error = parse_uint(raw)
    if value == nil then
      return nil, value_error
    end
    output[key] = value
    count = count + 1
  end
  if count == 0 and not allow_empty then
    return nil, "empty_key_value_file"
  end
  return output
end

local function parse_procs(content)
  local pids = {}
  local seen = {}
  for line in tostring(content):gmatch("[^\r\n]+") do
    local pid, parse_error = parse_uint(line)
    if pid == nil or pid <= 0 then
      return nil, parse_error or "pid_must_be_positive"
    end
    if not seen[pid] then
      if #pids >= MAX_PIDS_PER_NODE then return nil, "process_limit_exceeded" end
      seen[pid] = true
      pids[#pids + 1] = pid
    end
  end
  table.sort(pids)
  return pids
end

local function parse_io_stat(content)
  local devices = {}
  local by_id = {}
  local totals = {}
  for line in tostring(content):gmatch("[^\r\n]+") do
    local id, fields = line:match("^%s*(%d+:%d+)%s+(.+)%s*$")
    if not id or by_id[id] then
      return nil, id and ("duplicate_device_" .. id) or "invalid_io_stat_line"
    end
    local counters = {}
    local field_count = 0
    for token in fields:gmatch("%S+") do
      local key, raw = token:match("^([%w_.-]+)=(%d+)$")
      if not key or counters[key] ~= nil then
        return nil, "invalid_io_stat_field"
      end
      local value, value_error = parse_uint(raw)
      if value == nil then
        return nil, value_error
      end
      counters[key] = value
      if (totals[key] or 0) > math.maxinteger - value then
        return nil, "io_stat_total_out_of_range"
      end
      totals[key] = (totals[key] or 0) + value
      field_count = field_count + 1
    end
    if field_count == 0 then
      return nil, "empty_io_stat_device"
    end
    local major, minor = id:match("^(%d+):(%d+)$")
    local device = {
      id = id,
      major = tonumber(major),
      minor = tonumber(minor),
      counters = counters,
      rates = {},
    }
    devices[#devices + 1] = device
    by_id[id] = device
  end
  table.sort(devices, function(left, right)
    if left.major == right.major then
      return left.minor < right.minor
    end
    return left.major < right.major
  end)
  return {
    devices = devices,
    by_id = by_id,
    totals = { counters = totals, rates = {} },
  }
end

local function parse_pressure(content)
  local output = {}
  for line in tostring(content):gmatch("[^\r\n]+") do
    local kind, fields = line:match("^%s*([%a]+)%s+(.+)%s*$")
    if (kind ~= "some" and kind ~= "full") or output[kind] then
      return nil, kind and ("duplicate_pressure_" .. kind) or "invalid_pressure_line"
    end
    local parsed = {}
    for token in fields:gmatch("%S+") do
      local key, raw = token:match("^([%w_]+)=([^=]+)$")
      if not key or parsed[key] ~= nil then
        return nil, "invalid_pressure_field"
      end
      if key == "total" then
        local value, value_error = parse_uint(raw)
        if value == nil then
          return nil, value_error
        end
        parsed.total_usec = value
      elseif key == "avg10" or key == "avg60" or key == "avg300" then
        local value = raw:match("^%d+%.?%d*$") and tonumber(raw) or nil
        if value == nil or value ~= value or value == math.huge or value == -math.huge
            or value < 0 or value > 100 then
          return nil, "invalid_pressure_average"
        end
        parsed[key] = value
      end
    end
    if parsed.total_usec == nil then
      return nil, "pressure_total_missing"
    end
    output[kind] = parsed
  end
  if not output.some and not output.full then
    return nil, "empty_pressure_file"
  end
  return output
end

local function issue_kind(error_or_kind)
  if type(error_or_kind) == "table" then
    return error_or_kind.kind or "error"
  end
  return tostring(error_or_kind or "error")
end

local function issue_reason(error_or_kind, fallback)
  if type(error_or_kind) == "table" then
    return error_or_kind.message or fallback or error_or_kind.kind
  end
  return fallback or tostring(error_or_kind or "error")
end

local function add_issue(node, scan, field, error_or_kind, reason, path)
  local kind = issue_kind(error_or_kind)
  node.partial = true
  node.issue_count = node.issue_count + 1
  scan.issue_count = scan.issue_count + 1
  scan.issue_counts[kind] = (scan.issue_counts[kind] or 0) + 1
  if #node.issues < MAX_ISSUES_PER_NODE then
    node.issues[#node.issues + 1] = {
      field = field,
      kind = kind,
      reason = issue_reason(error_or_kind, reason),
      path = path,
    }
  else
    node.dropped_issues = (node.dropped_issues or 0) + 1
  end
end

local function empty_workload(item)
  return {
    id = item.id,
    name = basename(item.id),
    parent_id = item.parent_id,
    depth = item.depth,
    path = item.path,
    accessible = not item.inaccessible,
    partial = false,
    issue_count = 0,
    issues = {},
    processes = { count = 0, pids = {} },
    cpu = { counters = {}, rates = {} },
    memory = { events = {}, event_rates = {} },
    io = { devices = {}, by_id = {}, totals = { counters = {}, rates = {} } },
    pids = { events = {}, event_rates = {} },
    pressure = { cpu = {}, memory = {}, io = {} },
    cpuset = {},
    rate_status = {},
    _rate_counts = { fresh = 0, gap = 0, reset = 0 },
  }
end

local function empty_seqfile_read(error_value)
  return type(error_value) == "table"
    and error_value.kind == "io_error"
    and error_value.message == "read_failed"
end

local function read_metric(fs, node, scan, filename, field, parser, limit, allow_empty)
  local path = node.path .. "/" .. filename
  local content, read_error = fs:read(path, limit or MAX_FILE_BYTES)
  -- Lua's fixed-size file:read() returns nil (without a distinct errno) for
  -- an empty cgroup seqfile.  cgroup.procs and io.stat are legitimately empty;
  -- the directory entry already established that the file exists.
  if not content and allow_empty and empty_seqfile_read(read_error) then
    content = ""
  end
  if not content then
    add_issue(node, scan, field, read_error, "read_failed", path)
    return nil
  end
  local value, parse_error = parser(content)
  if value == nil then
    add_issue(node, scan, field, "parse", parse_error, path)
    return nil
  end
  return value
end

local function record_rate(node, key, current, previous, elapsed_ns)
  local state
  local value
  if type(current) ~= "number" or current ~= current or current == math.huge
      or type(previous) ~= "number" or previous ~= previous or previous == math.huge
      or type(elapsed_ns) ~= "number" or elapsed_ns ~= elapsed_ns
      or elapsed_ns == math.huge or elapsed_ns <= 0 then
    state = "gap"
  elseif current < previous then
    state = "reset"
  else
    state = "fresh"
    value = (current - previous) * 1000000000 / elapsed_ns
    if value ~= value or value == math.huge or value == -math.huge then
      state, value = "gap", nil
    end
  end
  node.rate_status[key] = state
  node._rate_counts[state] = node._rate_counts[state] + 1
  return value, state
end

local function derive_map_rates(node, prefix, current, previous, elapsed_ns, output)
  for _, key in ipairs(sorted_keys(current)) do
    local rate = record_rate(node, prefix .. "." .. key, current[key], previous and previous[key], elapsed_ns)
    if rate ~= nil then
      output[key .. "_per_second"] = rate
    end
  end
end

local function derive_pressure_rates(node, kind, current, previous, elapsed_ns)
  for _, level in ipairs({ "some", "full" }) do
    local current_level = current[level]
    if current_level and current_level.total_usec ~= nil then
      local previous_level = previous and previous[level]
      local rate = record_rate(
        node,
        "pressure." .. kind .. "." .. level .. ".total_usec",
        current_level.total_usec,
        previous_level and previous_level.total_usec,
        elapsed_ns
      )
      if rate ~= nil then
        current_level.total_usec_per_second = rate
      end
    end
  end
end

local function populate_metrics(fs, node, scan, previous_node, elapsed_ns)
  local procs = read_metric(fs, node, scan, "cgroup.procs", "processes", parse_procs, nil, true)
  if procs then
    node.processes = { count = #procs, pids = procs }
  end

  local cpu_counters = read_metric(fs, node, scan, "cpu.stat", "cpu.counters", parse_key_values)
  if cpu_counters then
    node.cpu.counters = cpu_counters
  end
  node.cpu.max = read_metric(fs, node, scan, "cpu.max", "cpu.max", parse_cpu_max, 4096)
  node.cpu.weight = read_metric(fs, node, scan, "cpu.weight", "cpu.weight", parse_uint, 4096)

  node.memory.current_bytes = read_metric(fs, node, scan, "memory.current", "memory.current", parse_uint, 4096)
  node.memory.peak_bytes = read_metric(fs, node, scan, "memory.peak", "memory.peak", parse_uint, 4096)
  node.memory.low_bytes = read_metric(fs, node, scan, "memory.low", "memory.low", parse_limit, 4096)
  node.memory.high_bytes = read_metric(fs, node, scan, "memory.high", "memory.high", parse_limit, 4096)
  node.memory.max_bytes = read_metric(fs, node, scan, "memory.max", "memory.max", parse_limit, 4096)
  node.memory.swap_current_bytes = read_metric(
    fs, node, scan, "memory.swap.current", "memory.swap_current", parse_uint, 4096
  )
  local memory_events = read_metric(fs, node, scan, "memory.events", "memory.events", parse_key_values)
  if memory_events then
    node.memory.events = memory_events
  end

  local io = read_metric(fs, node, scan, "io.stat", "io", parse_io_stat, nil, true)
  if io then
    node.io = io
  end

  node.pids.current = read_metric(fs, node, scan, "pids.current", "pids.current", parse_uint, 4096)
  node.pids.max = read_metric(fs, node, scan, "pids.max", "pids.max", parse_limit, 4096)
  local pids_events = read_metric(fs, node, scan, "pids.events", "pids.events", parse_key_values)
  if pids_events then
    node.pids.events = pids_events
  end

  for _, kind in ipairs({ "cpu", "memory", "io" }) do
    local pressure = read_metric(
      fs, node, scan, kind .. ".pressure", "pressure." .. kind, parse_pressure, 65536
    )
    if pressure then
      node.pressure[kind] = pressure
    end
  end

  local cpus = read_metric(fs, node, scan, "cpuset.cpus.effective", "cpuset.cpus_effective", trim, 65536)
  if cpus ~= nil then
    node.cpuset.cpus_effective = cpus
  end
  local mems = read_metric(fs, node, scan, "cpuset.mems.effective", "cpuset.mems_effective", trim, 65536)
  if mems ~= nil then
    node.cpuset.mems_effective = mems
  end

  local old_cpu = previous_node and previous_node.cpu
  derive_map_rates(node, "cpu", node.cpu.counters, old_cpu and old_cpu.counters, elapsed_ns, node.cpu.rates)
  node.cpu.utilization_percent = node.cpu.rates.usage_usec_per_second
    and node.cpu.rates.usage_usec_per_second / 10000
    or nil

  local old_memory = previous_node and previous_node.memory
  derive_map_rates(
    node,
    "memory.events",
    node.memory.events,
    old_memory and old_memory.events,
    elapsed_ns,
    node.memory.event_rates
  )

  local old_io = previous_node and previous_node.io
  for _, device in ipairs(node.io.devices) do
    local old_device = old_io and old_io.by_id and old_io.by_id[device.id]
    derive_map_rates(
      node,
      "io." .. device.id,
      device.counters,
      old_device and old_device.counters,
      elapsed_ns,
      device.rates
    )
  end
  derive_map_rates(
    node,
    "io.total",
    node.io.totals.counters,
    old_io and old_io.totals and old_io.totals.counters,
    elapsed_ns,
    node.io.totals.rates
  )

  local old_pids = previous_node and previous_node.pids
  derive_map_rates(
    node,
    "pids.events",
    node.pids.events,
    old_pids and old_pids.events,
    elapsed_ns,
    node.pids.event_rates
  )

  local old_pressure = previous_node and previous_node.pressure
  for _, kind in ipairs({ "cpu", "memory", "io" }) do
    derive_pressure_rates(
      node,
      kind,
      node.pressure[kind],
      old_pressure and old_pressure[kind],
      elapsed_ns
    )
  end
end

local function is_safe_entry(entry)
  return type(entry) == "string"
    and entry ~= ""
    and entry:sub(1, 1) ~= "."
    and not entry:find("/", 1, true)
    and not entry:find("%z")
end

local function error_message_contains(err, fragment)
  return type(err) == "table"
    and tostring(err.message or ""):lower():find(fragment, 1, true) ~= nil
end

local function is_not_link(err)
  return type(err) == "table" and (
    err.kind == "not_link"
    or err.errno == 22
    or error_message_contains(err, "invalid argument")
    or error_message_contains(err, "not a symbolic link")
  )
end

local function is_not_directory(err)
  return type(err) == "table" and (
    err.kind == "not_directory"
    or error_message_contains(err, "not a directory")
  )
end

local function discover_children(fs, item, node, queue, scan, max_depth, max_nodes)
  local entries = item.entries
  if item.entries_truncated then
    scan.node_limited = true
    node.truncated = true
  end
  table.sort(entries, function(left, right)
    return tostring(left) < tostring(right)
  end)

  for _, entry in ipairs(entries) do
    if type(entry) == "string" and entry:sub(1, 1) == "." then
      scan.skipped_dot_entries = scan.skipped_dot_entries + 1
    elseif not is_safe_entry(entry) then
      scan.skipped_unsafe_entries = scan.skipped_unsafe_entries + 1
      add_issue(node, scan, "scan", "unsafe", "unsafe_directory_entry")
    elseif not METRIC_FILES[entry] then
      -- Budgets must be checked before any readlink/opendir work.  Apart from
      -- bounding I/O, this avoids preloading one full directory table for every
      -- queued node when a broad cgroup tree approaches the global node cap.
      if item.depth >= max_depth then
        scan.depth_limited = true
        node.truncated = true
        break
      end
      if scan.discovered_nodes >= max_nodes then
        scan.node_limited = true
        node.truncated = true
        break
      end

      local candidate = item.path .. "/" .. entry
      local target, link_error = fs:readlink(candidate)
      if target then
        scan.skipped_symlinks = scan.skipped_symlinks + 1
      elseif not is_not_link(link_error) then
        if link_error and link_error.kind == "missing" then
          add_issue(node, scan, "scan." .. entry, link_error, "entry_disappeared", candidate)
        elseif link_error and link_error.kind == "denied" then
          add_issue(node, scan, "scan." .. entry, link_error, "symlink_check_denied", candidate)
        else
          add_issue(node, scan, "scan." .. entry, link_error or "error", "symlink_check_failed", candidate)
        end
      else
        local candidate_kind = "directory"
        local kind_error
        if type(fs.kind) == "function" then
          candidate_kind, kind_error = fs:kind(candidate)
        end
        if candidate_kind == "symlink" then
          scan.skipped_symlinks = scan.skipped_symlinks + 1
        elseif candidate_kind == nil then
          if kind_error and kind_error.kind == "missing" then
            add_issue(node, scan, "scan." .. entry, kind_error, "entry_disappeared", candidate)
          elseif kind_error and kind_error.kind == "denied" then
            add_issue(node, scan, "scan." .. entry, kind_error, "type_check_denied", candidate)
          else
            add_issue(node, scan, "scan." .. entry, kind_error or "error",
              "type_check_failed", candidate)
          end
        elseif candidate_kind == "directory" then
          -- Queue only identity.  Enumerating here would retain a full entries
          -- table for every pending sibling and turn a broad tree into
          -- O(max_nodes^2) resident names.  The admitted candidate consumes one
          -- node/work slot even if a racing regular file is observed later.
          scan.discovered_nodes = scan.discovered_nodes + 1
          queue[#queue + 1] = {
            id = child_id(item.id, entry),
            parent_id = item.id,
            depth = item.depth + 1,
            path = candidate,
          }
        end
      end
    end
  end
end

local function result_quality(summary)
  if summary.partial_node_count > 0 then
    return "partial"
  end
  if summary.reset_node_count > 0 then
    return "reset"
  end
  if summary.gap_node_count > 0 then
    return "gap"
  end
  return "fresh"
end

local function root_summary(root)
  if not root then
    return nil
  end
  return {
    id = root.id,
    process_count = root.processes.count,
    cpu_utilization_percent = root.cpu.utilization_percent,
    memory_current_bytes = root.memory.current_bytes,
    memory_max_bytes = root.memory.max_bytes,
    memory_swap_current_bytes = root.memory.swap_current_bytes,
    pids_current = root.pids.current,
    pids_max = root.pids.max,
    io_rates = root.io.totals.rates,
    pressure = root.pressure,
  }
end

function Cgroup.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Cgroup options must be a table", 2) end
  local root_relative, root_id = normalize_root(options.root)
  local mount_path = normalize_mount_path(options.mount_path)
  return setmetatable({
    id = "cgroup",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    fs = options.fs or FS.default,
    mount_path = mount_path,
    root = root_relative,
    root_id = root_id,
    root_path = join_path(mount_path, root_relative),
    max_depth = option_integer("max_depth", options.max_depth, DEFAULT_MAX_DEPTH, 0, 64),
    max_nodes = option_integer("max_nodes", options.max_nodes, DEFAULT_MAX_NODES, 1, 65536),
    _method_style = true,
  }, Cgroup)
end

function Cgroup:probe(context)
  local fs = Common.fs(context, self.fs)
  local controllers_path = self.root_path .. "/cgroup.controllers"
  local entries, list_error = fs:list(self.root_path, directory_entry_limit(self.max_nodes))
  if not entries then
    local status = FS.error_status(list_error)
    if status == "denied" then
      return Capability.denied(list_error.message, { source = self.root_path })
    end
    return Capability.unavailable(list_error and list_error.message or "cgroup_enumeration_unavailable", {
      source = self.root_path,
    })
  end
  local content, read_error = fs:read(controllers_path, 65536)
  if not content and empty_seqfile_read(read_error) then
    content = ""
  end
  if not content then
    local status = FS.error_status(read_error)
    if status == "denied" then
      return Capability.denied(read_error.message, { source = controllers_path })
    end
    return Capability.unavailable(read_error and read_error.message or "cgroup_v2_unavailable", {
      source = controllers_path,
    })
  end
  local controllers = {}
  for controller in content:gmatch("%S+") do
    controllers[#controllers + 1] = controller
  end
  table.sort(controllers)
  return Capability.available({
    source = self.root_path,
    details = { schema = SCHEMA, root_id = self.root_id, controllers = controllers },
  })
end

function Cgroup:sample(context, previous)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local root_entries, root_error, root_entries_truncated = fs:list(
    self.root_path, directory_entry_limit(self.max_nodes))
  if not root_entries then
    return Common.error_result(root_error, Common.now_ns(context), self.root_path)
  end

  local now = Common.now_ns(context)
  local previous_data = Common.previous_data(previous)
  local previous_by_id = previous_data and previous_data.by_id or {}
  local elapsed_ns = previous_data and Common.elapsed_ns(now, previous.timestamp_ns) or nil
  local workloads = {}
  local by_id = {}
  local scan = {
    discovered_nodes = 1,
    skipped_symlinks = 0,
    skipped_dot_entries = 0,
    skipped_unsafe_entries = 0,
    depth_limited = false,
    node_limited = false,
    issue_count = 0,
    issue_counts = {},
  }
  local queue = {
    {
      id = self.root_id,
      parent_id = nil,
      depth = 0,
      path = self.root_path,
      entries = root_entries,
      entries_truncated = root_entries_truncated == true,
    },
  }
  -- The queue owns the root listing until that item is processed.  Do not
  -- keep a second function-local reference alive for the whole traversal.
  root_entries = nil

  local head = 1
  while head <= #queue do
    local item = queue[head]
    head = head + 1
    local include_node = true
    local list_error
    if item.entries == nil then
      -- Every queued child was admitted only after the parent checked both
      -- depth and node budgets.  Its directory is opened exactly once, when
      -- dequeued, and bounded by the slots still available for descendants.
      item.entries, list_error, item.entries_truncated = fs:list(
        item.path, directory_entry_limit(self.max_nodes - scan.discovered_nodes))
      item.entries_truncated = item.entries_truncated == true
      if not item.entries and list_error and list_error.kind == "denied" then
        item.inaccessible = true
      end
      if not item.entries and (not list_error or list_error.kind ~= "denied") then
        include_node = false
        if not is_not_directory(list_error) then
          local parent = by_id[item.parent_id]
          if parent then
            add_issue(parent, scan, "scan." .. basename(item.id), list_error or "error",
              "subtree_enumeration_failed", item.path)
            parent.quality = "partial"
          end
        end
      end
    end

    if include_node then
      local node = empty_workload(item)
      if not item.entries then
        add_issue(node, scan, "subtree", list_error,
          "subtree_enumeration_denied", item.path)
      else
        populate_metrics(fs, node, scan, previous_by_id[item.id], elapsed_ns)
        discover_children(fs, item, node, queue, scan, self.max_depth, self.max_nodes)
        -- Processed queue entries remain in the array to preserve O(1) FIFO
        -- indexing, so explicitly release their potentially large listing.
        item.entries = nil
      end

      if node._rate_counts.reset > 0 then
        node.rate_quality = "reset"
      elseif node._rate_counts.gap > 0 then
        node.rate_quality = "gap"
      elseif node._rate_counts.fresh > 0 then
        node.rate_quality = "fresh"
      else
        node.rate_quality = "gap"
      end
      node.quality = node.partial and "partial" or node.rate_quality
      node._rate_counts = nil
      workloads[#workloads + 1] = node
      by_id[node.id] = node
    end
  end

  local summary = {
    root_id = self.root_id,
    node_count = #workloads,
    visible_process_count = 0,
    partial_node_count = 0,
    fresh_node_count = 0,
    gap_node_count = 0,
    reset_node_count = 0,
    issue_count = scan.issue_count,
    issues_by_kind = scan.issue_counts,
    denied_issue_count = scan.issue_counts.denied or 0,
    missing_issue_count = scan.issue_counts.missing or 0,
    parse_issue_count = scan.issue_counts.parse or 0,
    skipped_symlinks = scan.skipped_symlinks,
    skipped_dot_entries = scan.skipped_dot_entries,
    skipped_unsafe_entries = scan.skipped_unsafe_entries,
    max_depth = self.max_depth,
    max_nodes = self.max_nodes,
    depth_limited = scan.depth_limited,
    node_limited = scan.node_limited,
    truncated = scan.depth_limited or scan.node_limited,
  }
  for _, node in ipairs(workloads) do
    summary.visible_process_count = summary.visible_process_count + node.processes.count
    if node.partial then
      summary.partial_node_count = summary.partial_node_count + 1
    end
    if node.rate_quality == "fresh" then
      summary.fresh_node_count = summary.fresh_node_count + 1
    elseif node.rate_quality == "reset" then
      summary.reset_node_count = summary.reset_node_count + 1
    else
      summary.gap_node_count = summary.gap_node_count + 1
    end
  end
  summary.root = root_summary(by_id[self.root_id])

  local finished = Common.now_ns(context)
  local quality = result_quality(summary)
  return Common.result("ok", finished, {
    schema = SCHEMA,
    mount_path = self.mount_path,
    root = self.root_id,
    workloads = workloads,
    by_id = by_id,
    summary = summary,
  }, {
    quality = quality,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = self.root_path,
  })
end

Cgroup.SCHEMA = SCHEMA

return Cgroup
