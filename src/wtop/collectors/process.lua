local Capability = require("wtop.core.capability")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")
local native = require("wtop.native")

local Process = {}
Process.__index = Process

local DEFAULT_MAX_PROCESSES = 8192
local HARD_MAX_PROCESSES = 65536
local DIRECTORY_ENTRY_SLACK = 256

local function bounded_process_limit(value)
  if value == nil then return DEFAULT_MAX_PROCESSES end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
      or value % 1 ~= 0 or value < 1 or value > HARD_MAX_PROCESSES then
    error("max_processes must be an integer in 1.." .. HARD_MAX_PROCESSES, 3)
  end
  return value
end

local function canonical_pid(entry)
  if type(entry) ~= "string" or not entry:match("^[1-9]%d*$") then return nil end
  local pid = tonumber(entry)
  if not pid or math.type(pid) ~= "integer" or pid > 2147483647
      or tostring(pid) ~= entry then return nil end
  return pid
end

local function sanitize_text(value)
  if type(value) ~= "string" then
    return nil
  end
  value = value:gsub("%z+", " ")
  value = value:gsub("[%c]", function(character)
    if character == "\t" then
      return " "
    end
    return "?"
  end)
  if not utf8.len(value) then
    local output = {}
    local index = 1
    while index <= #value do
      local byte = value:byte(index)
      local length
      if byte < 0x80 then
        length = 1
      elseif byte >= 0xc2 and byte <= 0xdf then
        length = 2
      elseif byte >= 0xe0 and byte <= 0xef then
        length = 3
      elseif byte >= 0xf0 and byte <= 0xf4 then
        length = 4
      end
      local candidate = length and value:sub(index, index + length - 1) or nil
      local valid = candidate and #candidate == length and utf8.len(candidate) == 1
      if valid then
        output[#output + 1] = candidate
        index = index + length
      else
        output[#output + 1] = "�"
        index = index + 1
      end
    end
    value = table.concat(output)
  end
  return Common.trim(value)
end

function Process.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Process options must be a table", 2) end
  local constants = options.system_constants
  if not constants and type(native.system_constants) == "function" then
    local called, value = pcall(native.system_constants)
    if called then constants = value end
  end
  constants = type(constants) == "table" and constants or {}
  local clock_ticks_per_second = options.clock_ticks_per_second
    or constants.clock_ticks_per_second or 100
  local page_size_bytes = options.page_size_bytes or constants.page_size_bytes or 4096
  if type(clock_ticks_per_second) ~= "number" or clock_ticks_per_second ~= clock_ticks_per_second
      or clock_ticks_per_second <= 0 or clock_ticks_per_second == math.huge then
    error("clock_ticks_per_second must be a finite positive number", 2)
  end
  if type(page_size_bytes) ~= "number" or page_size_bytes ~= page_size_bytes
      or page_size_bytes <= 0 or page_size_bytes == math.huge or page_size_bytes % 1 ~= 0 then
    error("page_size_bytes must be a finite positive integer", 2)
  end
  for _, key in ipairs({ "read_status", "read_cmdline", "read_io", "read_cgroup" }) do
    if options[key] ~= nil and type(options[key]) ~= "boolean" then
      error(key .. " must be a boolean", 2)
    end
  end
  return setmetatable({
    id = "process",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    fs = options.fs or FS.default,
    proc_path = Common.absolute_path("proc_path", options.proc_path, "/proc"),
    clock_ticks_per_second = clock_ticks_per_second,
    page_size_bytes = page_size_bytes,
    read_status = options.read_status ~= false,
    read_cmdline = options.read_cmdline == true,
    read_io = options.read_io == true,
    read_cgroup = options.read_cgroup == true,
    max_processes = bounded_process_limit(options.max_processes),
    _method_style = true,
  }, Process)
end

function Process:probe(context)
  local fs = Common.fs(context, self.fs)
  local entries, err = fs:list(self.proc_path, 1)
  if entries then
    return Capability.available({ source = self.proc_path })
  end
  local status = FS.error_status(err)
  if status == "denied" then
    return Capability.denied(err.message, { source = self.proc_path })
  end
  return Capability.unavailable(err and err.message or "proc_enumeration_unavailable", { source = self.proc_path })
end

local function wants_detail(context, process_id)
  if not context then
    return false
  end
  local selected = context.selected_process_ids
  return type(selected) == "table" and selected[process_id] == true
end

function Process:sample(context, previous)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  -- Bound native getdents retention before Lua allocation/sorting.  The small
  -- slack accounts for /proc's non-PID entries without making a fork storm an
  -- unbounded memory or I/O workload.
  local entries, list_error, directory_truncated = fs:list(
    self.proc_path, self.max_processes + DIRECTORY_ENTRY_SLACK)
  if not entries then
    return Common.error_result(list_error, Common.now_ns(context), self.proc_path)
  end

  local now = Common.now_ns(context)
  local previous_data = Common.previous_data(previous)
  local elapsed_ns = previous_data and Common.elapsed_ns(now, previous.timestamp_ns) or nil
  local previous_by_id = previous_data and previous_data.by_id or {}
  local clock_ticks_per_second = (context and context.clock_ticks_per_second) or self.clock_ticks_per_second
  local page_size_bytes = (context and context.page_size_bytes) or self.page_size_bytes
  if type(clock_ticks_per_second) ~= "number" or clock_ticks_per_second ~= clock_ticks_per_second
      or clock_ticks_per_second <= 0 or clock_ticks_per_second == math.huge
      or type(page_size_bytes) ~= "number" or page_size_bytes ~= page_size_bytes
      or page_size_bytes <= 0 or page_size_bytes == math.huge or page_size_bytes % 1 ~= 0 then
    return Common.result("error", now, nil, {
      quality = "error", reason = "invalid_process_system_constants", source = self.proc_path,
    })
  end
  local processes = {}
  local by_id = {}
  local by_pid = {}
  local races = 0
  local denied = 0
  local parse_errors = 0
  local supplemental_parse_errors = 0
  local scanned = 0

  local candidates = {}
  for _, entry in ipairs(entries) do
    local pid = canonical_pid(entry)
    if pid then candidates[#candidates + 1] = { name = entry, pid = pid } end
  end
  local process_candidates = #candidates
  local truncated = directory_truncated == true or process_candidates > self.max_processes

  table.sort(candidates, function(left, right)
    return left.pid < right.pid
  end)

  for _, candidate in ipairs(candidates) do
    local entry, pid = candidate.name, candidate.pid
      if scanned >= self.max_processes then
        break
      end
      scanned = scanned + 1
      local base = self.proc_path .. "/" .. entry
      local stat_content, stat_error = fs:read(base .. "/stat", 65536)
      if not stat_content then
        if stat_error and stat_error.kind == "denied" then
          denied = denied + 1
        else
          races = races + 1
        end
      else
        local stat = Parsers.process_stat(stat_content)
        if not stat then
          parse_errors = parse_errors + 1
        elseif stat.pid ~= pid then
          races = races + 1
        else
          local process = {
            id = stat.id,
            pid = stat.pid,
            starttime_ticks = stat.starttime_ticks,
            name = sanitize_text(stat.comm),
            state = stat.state,
            parent_pid = stat.ppid,
            process_group = stat.pgrp,
            session = stat.session,
            threads = stat.threads,
            priority = stat.priority,
            nice = stat.nice,
            processor = stat.processor,
            virtual_bytes = stat.vsize_bytes,
            resident_bytes = stat.rss_pages >= 0
              and stat.rss_pages <= math.maxinteger // page_size_bytes
              and (stat.rss_pages * page_size_bytes) or nil,
            cpu_ticks = stat.cpu_ticks,
            cpu_percent = nil,
            quality = "gap",
          }
          local old = previous_by_id[process.id]
          if old and elapsed_ns and elapsed_ns > 0 then
            local ticks = Common.delta(process.cpu_ticks, old.cpu_ticks)
            if ticks then
              local cpu_percent = (ticks + 0.0) / clock_ticks_per_second
                / (elapsed_ns / 1000000000) * 100
              if cpu_percent == cpu_percent and cpu_percent < math.huge then
                process.cpu_percent = math.max(0, cpu_percent)
                process.quality = "fresh"
              end
            end
          end

          if self.read_status then
            local status_content, status_error = fs:read(base .. "/status", 256 * 1024)
            if status_content then
              local status = Parsers.process_status(status_content)
              if status then
                process.uid = status.uid
                process.resident_bytes = status.rss_bytes or process.resident_bytes
                process.context_switches = {
                  voluntary = status.voluntary_context_switches,
                  involuntary = status.nonvoluntary_context_switches,
                }
              else
                process.partial = true
                process.partial_reason = "status_parse_error"
                supplemental_parse_errors = supplemental_parse_errors + 1
              end
            elseif status_error and status_error.kind == "denied" then
              process.partial = true
              process.partial_reason = "status_denied"
            else
              process.partial = true
              process.partial_reason = "status_unavailable"
            end
          end

          local detail = wants_detail(context, process.id)
          local supplemental_read = false
          if self.read_cmdline or detail then
            supplemental_read = true
            local cmdline, cmdline_error = fs:read(base .. "/cmdline", 64 * 1024)
            if cmdline and cmdline ~= "" then
              process.command = sanitize_text(cmdline)
            elseif cmdline_error then
              process.partial = true
              process.command_status = FS.error_status(cmdline_error)
            end
          end
          if self.read_io or detail then
            supplemental_read = true
            local io_content, io_error = fs:read(base .. "/io", 65536)
            if io_content then
              local parsed_io = Parsers.process_io(io_content)
              if parsed_io then
                process.io = parsed_io
              else
                process.io_status = "parse_error"
                process.partial = true
                supplemental_parse_errors = supplemental_parse_errors + 1
              end
            elseif io_error and io_error.kind == "denied" then
              process.io_status = "denied"
              process.partial = true
            elseif io_error then
              process.io_status = FS.error_status(io_error)
              process.partial = true
            end
          end
          if self.read_cgroup or detail then
            supplemental_read = true
            local cgroup_content, cgroup_error = fs:read(base .. "/cgroup", 65536)
            if cgroup_content then
              local parsed_cgroups = Parsers.cgroup(cgroup_content)
              if parsed_cgroups then
                process.cgroups = parsed_cgroups
              else
                process.partial = true
                supplemental_parse_errors = supplemental_parse_errors + 1
              end
            elseif cgroup_error then
              process.partial = true
              process.cgroup_status = FS.error_status(cgroup_error)
            end
          end
          if context and type(context.resolve_username) == "function" and process.uid then
            local resolved, user = pcall(context.resolve_username, process.uid)
            if resolved then process.user = sanitize_text(user) end
          end

          -- status is a supplemental read too.  Each /proc/<pid> path lookup
          -- can resolve to a newly reused PID, so verify the generation again
          -- after all supplemental fields have been collected.  Mixed samples
          -- are discarded instead of attaching another process's UID/RSS/I/O.
          supplemental_read = supplemental_read or self.read_status
          local generation_matches = true
          if supplemental_read then
            local final_content = fs:read(base .. "/stat", 65536)
            if not final_content then
              races = races + 1
              generation_matches = false
            else
              local final_stat = Parsers.process_stat(final_content)
              if not final_stat then
                parse_errors = parse_errors + 1
                generation_matches = false
              elseif final_stat.pid ~= process.pid
                or final_stat.starttime_ticks ~= process.starttime_ticks
              then
                races = races + 1
                generation_matches = false
              end
            end
          end
          if generation_matches then
            by_id[process.id] = process
            by_pid[process.pid] = process
            processes[#processes + 1] = process
          end
        end
      end
  end

  table.sort(processes, function(left, right)
    return left.pid < right.pid
  end)
  local any_fresh, any_process_partial = false, false
  for _, process in ipairs(processes) do
    any_fresh = any_fresh or process.quality == "fresh"
    any_process_partial = any_process_partial or process.partial == true
  end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, {
    list = processes,
    by_id = by_id,
    by_pid = by_pid,
    scanned = scanned,
    races = races,
    denied = denied,
    parse_errors = parse_errors,
    supplemental_parse_errors = supplemental_parse_errors,
    process_candidates = process_candidates,
    process_limit = self.max_processes,
    truncated = truncated,
    partial = truncated or denied > 0 or parse_errors > 0
      or supplemental_parse_errors > 0 or any_process_partial,
  }, {
    quality = (truncated or denied > 0 or parse_errors > 0
        or supplemental_parse_errors > 0 or any_process_partial)
      and "partial" or (any_fresh and "fresh" or "gap"),
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = self.proc_path,
  })
end

Process.sanitize_text = sanitize_text
Process.DEFAULT_MAX_PROCESSES = DEFAULT_MAX_PROCESSES
Process.HARD_MAX_PROCESSES = HARD_MAX_PROCESSES

return Process
