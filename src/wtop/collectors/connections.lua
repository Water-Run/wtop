local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local SocketTables = require("wtop.linux.socket_tables")

local Connections = {}
Connections.__index = Connections

local TABLES = {
  { kind = "tcp", rank = 1 },
  { kind = "tcp6", rank = 2 },
  { kind = "udp", rank = 3 },
  { kind = "udp6", rank = 4 },
  { kind = "unix", rank = 5 },
}

local DEFAULT_OWNER_LIMITS = {
  max_processes = 1024,
  max_fds_per_process = 512,
  max_total_links = 16384,
  max_owners_per_socket = 8,
}

local HARD_OWNER_LIMITS = {
  max_processes = 16384,
  max_fds_per_process = 4096,
  max_total_links = 262144,
  max_owners_per_socket = 64,
}

local function error_kind(err, errno)
  local kind = type(err) == "table" and err.kind or nil
  if type(err) == "table" then errno = errno or err.errno end
  local reason = type(err) == "table" and (err.message or err.reason or kind) or err
  reason = tostring(reason or "filesystem_error")
  local lower = reason:lower()
  if kind == "denied" or errno == 1 or errno == 13
      or lower:find("permission denied", 1, true)
      or lower:find("operation not permitted", 1, true) then
    return "denied", reason, errno
  end
  if kind == "missing" or errno == 2 or errno == 20
      or lower:find("no such file", 1, true)
      or lower:find("not found", 1, true) then
    return "missing", reason, errno
  end
  if kind == "unavailable" then return "unavailable", reason, errno end
  if kind == "too_large" then return "error", reason, errno end
  return "error", reason, errno
end

local function safe_name(value)
  if type(value) ~= "string" then return nil end
  value = value:gsub("%z+", " ")
  value = value:gsub("[%c]", function(character) return character == "\t" and " " or "?" end)
  if not utf8.len(value) then
    local output = {}
    local index = 1
    while index <= #value do
      local byte = value:byte(index)
      local length
      if byte < 0x80 then length = 1
      elseif byte >= 0xc2 and byte <= 0xdf then length = 2
      elseif byte >= 0xe0 and byte <= 0xef then length = 3
      elseif byte >= 0xf0 and byte <= 0xf4 then length = 4 end
      local candidate = length and value:sub(index, index + length - 1) or nil
      if candidate and #candidate == length and utf8.len(candidate) == 1 then
        output[#output + 1] = candidate
        index = index + length
      else
        output[#output + 1] = "�"
        index = index + 1
      end
    end
    value = table.concat(output)
  end
  value = Common.trim(value)
  if #value > 256 then
    value = value:sub(1, 256)
    while #value > 0 and not utf8.len(value) do value = value:sub(1, -2) end
  end
  return value ~= "" and value or nil
end

local function bounded_owner_limits(options)
  local result = {}
  for key, fallback in pairs(DEFAULT_OWNER_LIMITS) do
    local value = options[key]
    if value == nil then value = fallback end
    if type(value) ~= "number" or value < 0 or value % 1 ~= 0 or value > HARD_OWNER_LIMITS[key] then
      return nil, "invalid_" .. key
    end
    result[key] = value
  end
  return result
end

local function bounded_read_limit(value)
  if type(value) ~= "number" or value ~= value or value < 1 or value % 1 ~= 0
      or value > SocketTables.HARD_MAX_BYTES then return nil end
  return value
end

local function numeric_entries(entries, allow_zero)
  if type(entries) ~= "table" then return nil end
  local result = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "string" and entry:match("^%d+$") then
      local number = tonumber(entry)
      if number and ((allow_zero and number >= 0) or (not allow_zero and number > 0))
          and math.type(number) == "integer" and number <= 2147483647
          and tostring(number) == entry then
        result[#result + 1] = { text = entry, number = number }
      end
    end
  end
  table.sort(result, function(left, right)
    if left.number == right.number then return left.text < right.text end
    return left.number < right.number
  end)
  return result
end

local function call_fs(method, fs, ...)
  if type(fs) ~= "table" or type(fs[method]) ~= "function" then
    return nil, "filesystem_" .. method .. "_unavailable"
  end
  local ok, first, second, third = pcall(fs[method], fs, ...)
  if not ok then return nil, first end
  return first, second, third
end

local function scan_owners(fs, proc_path, wanted_inodes, options)
  local limits, limit_error = bounded_owner_limits(options)
  local stats = {
    enabled = true,
    status = "ok",
    partial = false,
    process_candidates = 0,
    processes_considered = 0,
    processes_scanned = 0,
    processes_denied = 0,
    process_races = 0,
    process_errors = 0,
    fd_entries = 0,
    fd_truncated_processes = 0,
    links_examined = 0,
    link_denied = 0,
    link_races = 0,
    link_errors = 0,
    socket_links = 0,
    matched_links = 0,
    owners_attached = 0,
    owner_limit_sockets = 0,
    name_errors = 0,
    process_limit_reached = false,
    link_limit_reached = false,
  }
  local owners_by_inode = {}
  if not limits then
    stats.status = "error"
    stats.partial = true
    stats.reason = limit_error
    return owners_by_inode, stats
  end
  if next(wanted_inodes) == nil then
    stats.status = "empty"
    return owners_by_inode, stats
  end

  if limits.max_processes == 0 or limits.max_total_links == 0 then
    stats.process_limit_reached = limits.max_processes == 0
    stats.link_limit_reached = limits.max_total_links == 0
    stats.partial = true
    stats.status = "partial"
    return owners_by_inode, stats
  end
  local proc_entries, proc_error, proc_detail = call_fs(
    "list", fs, proc_path, limits.max_processes + 1)
  if not proc_entries then
    local kind, reason, errno = error_kind(proc_error, proc_detail)
    stats.status = kind == "missing" and "unavailable" or kind
    stats.partial = true
    stats.reason = reason
    stats.errno = errno
    return owners_by_inode, stats
  end
  local processes = numeric_entries(proc_entries, false)
  if not processes then
    stats.status = "error"
    stats.partial = true
    stats.reason = "proc_entries_not_table"
    return owners_by_inode, stats
  end
  stats.process_candidates = #processes
  if proc_detail == true or #processes > limits.max_processes then stats.process_limit_reached = true end
  local process_count = math.min(#processes, limits.max_processes)
  local owner_limit_seen = {}
  local names = {}
  local stop = false

  local function process_name(pid_text)
    if names[pid_text] ~= nil then return names[pid_text] or nil end
    local content = call_fs("read", fs, proc_path .. "/" .. pid_text .. "/comm", 4096)
    local name = content and safe_name(content) or nil
    if not name then stats.name_errors = stats.name_errors + 1 end
    names[pid_text] = name or false
    return name
  end

  for process_index = 1, process_count do
    if stop then break end
    local process = processes[process_index]
    stats.processes_considered = stats.processes_considered + 1
    local fd_path = proc_path .. "/" .. process.text .. "/fd"
    local fd_entries, fd_error, fd_detail
    if limits.max_fds_per_process > 0 then
      fd_entries, fd_error, fd_detail = call_fs(
        "list", fs, fd_path, limits.max_fds_per_process + 1)
    else
      fd_entries, fd_detail = {}, true
    end
    if not fd_entries then
      local kind = error_kind(fd_error, fd_detail)
      if kind == "denied" then stats.processes_denied = stats.processes_denied + 1
      elseif kind == "missing" then stats.process_races = stats.process_races + 1
      else stats.process_errors = stats.process_errors + 1 end
    else
      stats.processes_scanned = stats.processes_scanned + 1
      local descriptors = numeric_entries(fd_entries, true)
      if not descriptors then
        stats.process_errors = stats.process_errors + 1
        descriptors = {}
      end
      stats.fd_entries = stats.fd_entries + #descriptors
      if fd_detail == true or #descriptors > limits.max_fds_per_process then
        stats.fd_truncated_processes = stats.fd_truncated_processes + 1
      end
      local descriptor_count = math.min(#descriptors, limits.max_fds_per_process)
      for descriptor_index = 1, descriptor_count do
        if stats.links_examined >= limits.max_total_links then
          stats.link_limit_reached = true
          stop = true
          break
        end
        local descriptor = descriptors[descriptor_index]
        stats.links_examined = stats.links_examined + 1
        local target, link_error, link_errno = call_fs(
          "readlink", fs, fd_path .. "/" .. descriptor.text
        )
        if not target then
          local kind = error_kind(link_error, link_errno)
          if kind == "denied" then stats.link_denied = stats.link_denied + 1
          elseif kind == "missing" then stats.link_races = stats.link_races + 1
          else stats.link_errors = stats.link_errors + 1 end
        elseif type(target) ~= "string" then
          stats.link_errors = stats.link_errors + 1
        else
          local inode = target:match("^socket:%[(%d+)%]$")
          if inode then
            inode = inode:gsub("^0+", "")
            if inode == "" then inode = "0" end
            stats.socket_links = stats.socket_links + 1
            if wanted_inodes[inode] then
              stats.matched_links = stats.matched_links + 1
              local owners = owners_by_inode[inode]
              if not owners then owners = {}; owners_by_inode[inode] = owners end
              if #owners < limits.max_owners_per_socket then
                owners[#owners + 1] = {
                  pid = process.number,
                  fd = descriptor.number,
                  name = process_name(process.text),
                }
                stats.owners_attached = stats.owners_attached + 1
              elseif not owner_limit_seen[inode] then
                owner_limit_seen[inode] = true
                stats.owner_limit_sockets = stats.owner_limit_sockets + 1
              end
            end
          end
        end
      end
    end
  end

  for _, owners in pairs(owners_by_inode) do
    table.sort(owners, function(left, right)
      if left.pid == right.pid then return left.fd < right.fd end
      return left.pid < right.pid
    end)
  end
  stats.partial = stats.process_limit_reached or stats.link_limit_reached
    or stats.processes_denied > 0 or stats.process_races > 0 or stats.process_errors > 0
    or stats.fd_truncated_processes > 0 or stats.link_denied > 0 or stats.link_races > 0
    or stats.link_errors > 0 or stats.owner_limit_sockets > 0 or stats.name_errors > 0
  if stats.partial then stats.status = "partial" end
  return owners_by_inode, stats
end

local TABLE_RANK = { tcp = 1, tcp6 = 2, udp = 3, udp6 = 4, unix = 5 }

local function connection_order(left, right)
  local left_rank = TABLE_RANK[left.table] or math.huge
  local right_rank = TABLE_RANK[right.table] or math.huge
  if left_rank ~= right_rank then return left_rank < right_rank end
  local left_local = left.local_endpoint and left.local_endpoint.text or left.path or ""
  local right_local = right.local_endpoint and right.local_endpoint.text or right.path or ""
  if left_local ~= right_local then return left_local < right_local end
  local left_remote = left.remote_endpoint and left.remote_endpoint.text or ""
  local right_remote = right.remote_endpoint and right.remote_endpoint.text or ""
  if left_remote ~= right_remote then return left_remote < right_remote end
  if left.state_code ~= right.state_code then return left.state_code < right.state_code end
  if left.inode ~= right.inode then return left.inode < right.inode end
  if left.base_id ~= right.base_id then return left.base_id < right.base_id end
  return (left.slot or 0) < (right.slot or 0)
end

local function table_summary(report, path)
  return {
    status = "ok",
    source = path,
    lines_seen = report.lines_seen,
    parsed = report.parsed,
    error_count = report.error_count,
    errors = report.errors,
    truncated = report.truncated,
    partial = report.partial,
    header_seen = report.header_seen,
  }
end

function Connections.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Connections options must be a table", 2) end
  local max_bytes = options.max_bytes or SocketTables.DEFAULT_MAX_BYTES
  local proc_net_path = options.proc_net_path or "/proc/net"
  if not bounded_read_limit(max_bytes) then error("invalid max_bytes", 2) end
  if options.paths ~= nil and type(options.paths) ~= "table" then
    error("connection paths must be a table", 2)
  end
  if options.scan_owners ~= nil and type(options.scan_owners) ~= "boolean" then
    error("scan_owners must be a boolean", 2)
  end
  if options.little_endian ~= nil and type(options.little_endian) ~= "boolean" then
    error("little_endian must be a boolean", 2)
  end
  proc_net_path = Common.absolute_path("proc_net_path", proc_net_path, "/proc/net")
  local paths = {}
  for _, specification in ipairs(TABLES) do
    paths[specification.kind] = options.paths and options.paths[specification.kind]
      or (proc_net_path .. "/" .. specification.kind)
    paths[specification.kind] = Common.absolute_path(
      specification.kind .. "_path", paths[specification.kind])
  end
  local owner_limits, owner_error = bounded_owner_limits(options)
  if not owner_limits then error(owner_error, 2) end
  local max_lines = options.max_lines == nil and SocketTables.DEFAULT_MAX_LINES or options.max_lines
  local max_line_bytes = options.max_line_bytes or SocketTables.DEFAULT_MAX_LINE_BYTES
  local max_errors = options.max_errors == nil and SocketTables.DEFAULT_MAX_ERRORS or options.max_errors
  if type(max_lines) ~= "number" or max_lines % 1 ~= 0 or max_lines < 0
      or max_lines > SocketTables.HARD_MAX_LINES then error("invalid max_lines", 2) end
  if type(max_line_bytes) ~= "number" or max_line_bytes % 1 ~= 0 or max_line_bytes < 1
      or max_line_bytes > SocketTables.HARD_MAX_LINE_BYTES then
    error("invalid max_line_bytes", 2)
  end
  if type(max_errors) ~= "number" or max_errors % 1 ~= 0 or max_errors < 0
      or max_errors > SocketTables.HARD_MAX_ERRORS then error("invalid max_errors", 2) end
  return setmetatable({
    id = "connections",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms,
      options.scan_owners and 5000 or 2000),
    fs = options.fs or FS.default,
    proc_path = Common.absolute_path("proc_path", options.proc_path, "/proc"),
    paths = paths,
    scan_owner_fds = options.scan_owners == true,
    max_bytes = max_bytes,
    read_max_bytes = max_bytes,
    max_lines = max_lines,
    max_line_bytes = max_line_bytes,
    max_errors = max_errors,
    little_endian = options.little_endian,
    max_processes = owner_limits.max_processes,
    max_fds_per_process = owner_limits.max_fds_per_process,
    max_total_links = owner_limits.max_total_links,
    max_owners_per_socket = owner_limits.max_owners_per_socket,
    _method_style = true,
  }, Connections)
end

function Connections:probe(context)
  local fs = Common.fs(context, self.fs)
  local available, unavailable, denied = 0, 0, 0
  local sources = {}
  for _, specification in ipairs(TABLES) do
    local path = self.paths[specification.kind]
    sources[#sources + 1] = path
    local content, err = fs:read(path, self.read_max_bytes)
    if content then
      available = available + 1
    else
      local status = FS.error_status(err)
      if status == "denied" then denied = denied + 1 else unavailable = unavailable + 1 end
    end
  end
  if available > 0 then
    local details = { available_tables = available, unavailable_tables = unavailable, denied_tables = denied }
    if unavailable > 0 or denied > 0 then
      return Capability.new("degraded", { source = sources, reason = "socket_tables_partial", details = details })
    end
    return Capability.available({ source = sources, details = details })
  end
  if denied > 0 then return Capability.denied("socket_tables_denied", { source = sources }) end
  return Capability.unavailable("socket_tables_unavailable", { source = sources })
end

function Connections:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local connections = {}
  local reports = {}
  local counts = { tcp = 0, tcp6 = 0, udp = 0, udp6 = 0, unix = 0 }
  local sources = {}
  local tables_ok = 0
  local denied_tables, unavailable_tables, error_tables = 0, 0, 0
  local partial = false

  for _, specification in ipairs(TABLES) do
    local kind = specification.kind
    local path = self.paths[kind]
    sources[#sources + 1] = path
    local content, read_error = fs:read(path, self.read_max_bytes)
    if not content then
      local status = FS.error_status(read_error)
      if status == "denied" then denied_tables = denied_tables + 1
      elseif status == "unavailable" then unavailable_tables = unavailable_tables + 1
      else error_tables = error_tables + 1 end
      reports[kind] = {
        status = status,
        source = path,
        reason = read_error and read_error.message or "read_failed",
      }
      partial = true
    else
      local report, parse_error = SocketTables.parse(content, kind, {
        max_bytes = self.max_bytes,
        max_lines = self.max_lines,
        max_line_bytes = self.max_line_bytes,
        max_errors = self.max_errors,
        little_endian = self.little_endian,
      })
      if not report then
        reports[kind] = { status = "error", source = path, reason = parse_error }
        error_tables = error_tables + 1
        partial = true
      else
        tables_ok = tables_ok + 1
        reports[kind] = table_summary(report, path)
        counts[kind] = #report.entries
        partial = partial or report.partial
        for _, connection in ipairs(report.entries) do connections[#connections + 1] = connection end
      end
    end
  end

  if tables_ok == 0 then
    local finished = Common.now_ns(context)
    local status = error_tables > 0 and "error" or (denied_tables > 0 and "denied" or "unavailable")
    return Common.result(status, finished, nil, {
      quality = status,
      reason = "no_socket_tables_available",
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = sources,
    })
  end

  table.sort(connections, connection_order)
  local duplicate_ids = {}
  local by_id = {}
  local by_inode = {}
  local wanted_inodes = {}
  for _, connection in ipairs(connections) do
    local count = (duplicate_ids[connection.base_id] or 0) + 1
    duplicate_ids[connection.base_id] = count
    connection.id = count == 1 and connection.base_id or (connection.base_id .. "#" .. tostring(count))
    by_id[connection.id] = connection
    if connection.inode ~= "0" then
      wanted_inodes[connection.inode] = true
      local values = by_inode[connection.inode]
      if not values then values = {}; by_inode[connection.inode] = values end
      values[#values + 1] = connection
    end
  end

  local scan_enabled = context and context.scan_connection_owners
  if scan_enabled ~= nil and type(scan_enabled) ~= "boolean" then scan_enabled = false end
  if scan_enabled == nil then scan_enabled = self.scan_owner_fds end
  local owners_by_inode = {}
  local owner_scan
  if scan_enabled then
    owners_by_inode, owner_scan = scan_owners(fs, self.proc_path, wanted_inodes, {
      max_processes = self.max_processes,
      max_fds_per_process = self.max_fds_per_process,
      max_total_links = self.max_total_links,
      max_owners_per_socket = self.max_owners_per_socket,
    })
    partial = partial or owner_scan.partial
  else
    owner_scan = { enabled = false, status = "disabled", partial = false }
  end

  for _, connection in ipairs(connections) do
    connection.owners = {}
    local owners = owners_by_inode[connection.inode]
    if owners then
      for index, owner in ipairs(owners) do
        connection.owners[index] = { pid = owner.pid, fd = owner.fd, name = owner.name }
      end
    end
    connection.owner_count = #connection.owners
    connection.owners_quality = (not scan_enabled or connection.inode == "0") and "unavailable"
      or (owner_scan.partial and "estimated" or "fresh")
  end

  local finished = Common.now_ns(context)
  return Common.result("ok", finished, {
    connections = connections,
    by_id = by_id,
    by_inode = by_inode,
    counts = counts,
    total = #connections,
    partial = partial,
    tables = reports,
    owner_scan = owner_scan,
  }, {
    quality = partial and "partial" or "fresh",
    reason = partial and "connections_partial" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = sources,
  })
end

Connections.scan_owners = scan_owners
Connections.connection_order = connection_order
Connections.DEFAULT_OWNER_LIMITS = DEFAULT_OWNER_LIMITS
Connections.HARD_OWNER_LIMITS = HARD_OWNER_LIMITS

return Connections
