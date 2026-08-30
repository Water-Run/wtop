local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local MountInfo = require("wtop.linux.mountinfo")
local Native = require("wtop.native")

local Mounts = {}
Mounts.__index = Mounts

local DEFAULT_STATVFS_BUDGET_MS = 50
local DEFAULT_MAX_STATVFS_CALLS = 512

local function numeric_field(values, name, allow_zero)
  local value = values[name]
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return nil, name .. "_invalid"
  end
  if value < 0 or value % 1 ~= 0 or (not allow_zero and value == 0) then
    return nil, name .. "_invalid"
  end
  return value
end

local function checked_product(left, right)
  if left == 0 or right == 0 then return 0 end
  if left <= math.maxinteger // right then return left * right end
  local value = left * 1.0 * right
  if value == math.huge then return nil end
  return value
end

local function usage_from_statvfs(values)
  if type(values) ~= "table" then return nil, "result_not_table" end
  local block_size, block_size_error = numeric_field(values, "block_size", false)
  if not block_size then return nil, block_size_error end
  local blocks, blocks_error = numeric_field(values, "blocks", true)
  if not blocks then return nil, blocks_error end
  local blocks_free, blocks_free_error = numeric_field(values, "blocks_free", true)
  if not blocks_free then return nil, blocks_free_error end
  local blocks_available, blocks_available_error = numeric_field(values, "blocks_available", true)
  if not blocks_available then return nil, blocks_available_error end
  local files, files_error = numeric_field(values, "files", true)
  if not files then return nil, files_error end
  local files_free, files_free_error = numeric_field(values, "files_free", true)
  if not files_free then return nil, files_free_error end
  if blocks_free > blocks or blocks_available > blocks_free or files_free > files then
    return nil, "inconsistent_counters"
  end

  local files_available = values.files_available
  local available_estimated = files_available == nil
  if files_available == nil then
    files_available = files_free
  else
    local files_available_error
    files_available, files_available_error = numeric_field(values, "files_available", true)
    if not files_available then return nil, files_available_error end
    if files_available > files_free then return nil, "inconsistent_inode_counters" end
  end

  local total_bytes = checked_product(blocks, block_size)
  local free_bytes = checked_product(blocks_free, block_size)
  local available_bytes = checked_product(blocks_available, block_size)
  if not total_bytes or not free_bytes or not available_bytes then
    return nil, "capacity_overflow"
  end
  local used_bytes = total_bytes - free_bytes
  local used_inodes = files - files_free

  return {
    capacity = {
      block_size_bytes = block_size,
      total_bytes = total_bytes,
      free_bytes = free_bytes,
      available_bytes = available_bytes,
      used_bytes = used_bytes,
      reserved_bytes = free_bytes - available_bytes,
      used_percent = total_bytes > 0 and used_bytes / total_bytes * 100 or nil,
    },
    inodes = {
      total = files,
      free = files_free,
      available = files_available,
      used = used_inodes,
      reserved = files_free - files_available,
      used_percent = files > 0 and used_inodes / files * 100 or nil,
      available_estimated = available_estimated,
    },
  }
end

local function statvfs_error(message, errno)
  local kind
  local reason
  if type(message) == "table" then
    kind = message.kind
    reason = message.message or message.reason or tostring(message)
    errno = errno or message.errno
  else
    reason = tostring(message or "statvfs_failed")
  end
  local lower = reason:lower()
  local status
  if kind == "denied" or errno == 1 or errno == 13
      or lower:find("permission denied", 1, true)
      or lower:find("operation not permitted", 1, true) then
    status = "denied"
  elseif kind == "stale" or errno == 116 or lower:find("stale file handle", 1, true) then
    status = "stale"
  elseif kind == "missing" or errno == 2 or errno == 20
      or lower:find("no such file", 1, true)
      or lower:find("not found", 1, true) then
    status = "missing"
  elseif kind == "unavailable" then
    status = "unavailable"
  else
    status = "error"
  end
  return status, reason, errno
end

local function collect_usage(provider, path)
  local called, values, message, errno = pcall(provider, path)
  if not called then
    local status, reason = statvfs_error(values)
    return nil, status, reason
  end
  if not values then
    local status, reason, error_number = statvfs_error(message, errno)
    return nil, status, reason, error_number
  end
  local usage, validation_error = usage_from_statvfs(values)
  if not usage then return nil, "error", validation_error end
  return usage
end

local function stable_mount_order(left, right)
  if left.mount_point ~= right.mount_point then
    return left.mount_point < right.mount_point
  end
  if left.mount_id ~= right.mount_id then
    return left.mount_id < right.mount_id
  end
  return left.id < right.id
end

local function potentially_blocking_filesystem(mount)
  local fs_type = type(mount.fs_type) == "string" and mount.fs_type or ""
  return mount.network == true or fs_type == "autofs"
    or fs_type == "fuse" or fs_type == "fuseblk"
    or fs_type == "virtiofs" or fs_type:match("^fuse%.") ~= nil
end

function Mounts.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Mounts options must be a table", 2) end
  local statvfs_budget_ms = options.statvfs_budget_ms
  if statvfs_budget_ms == nil then
    statvfs_budget_ms = DEFAULT_STATVFS_BUDGET_MS
  elseif type(statvfs_budget_ms) ~= "number" or statvfs_budget_ms ~= statvfs_budget_ms
      or statvfs_budget_ms < 0 or statvfs_budget_ms > 60000 then
    error("statvfs_budget_ms must be a finite number in 0..60000", 2)
  end
  local max_statvfs_calls = options.max_statvfs_calls
  if max_statvfs_calls == nil then
    max_statvfs_calls = DEFAULT_MAX_STATVFS_CALLS
  elseif type(max_statvfs_calls) ~= "number" or max_statvfs_calls ~= max_statvfs_calls
      or max_statvfs_calls < 0 or max_statvfs_calls > 65536 or max_statvfs_calls % 1 ~= 0 then
    error("max_statvfs_calls must be an integer in 0..65536", 2)
  end
  if options.statvfs ~= nil and type(options.statvfs) ~= "function" then
    error("statvfs must be a function", 2)
  end
  if options.skip_risky_statvfs ~= nil and type(options.skip_risky_statvfs) ~= "boolean" then
    error("skip_risky_statvfs must be a boolean", 2)
  end
  local max_bytes = options.max_bytes or MountInfo.DEFAULT_MAX_BYTES
  local max_entries = options.max_entries or MountInfo.DEFAULT_MAX_ENTRIES
  local max_line_bytes = options.max_line_bytes or MountInfo.DEFAULT_MAX_LINE_BYTES
  local max_path_bytes = options.max_path_bytes or MountInfo.DEFAULT_MAX_PATH_BYTES
  for _, limit in ipairs({
    { "max_bytes", max_bytes, MountInfo.HARD_MAX_BYTES },
    { "max_entries", max_entries, MountInfo.HARD_MAX_ENTRIES },
    { "max_line_bytes", max_line_bytes, MountInfo.HARD_MAX_LINE_BYTES },
    { "max_path_bytes", max_path_bytes, MountInfo.HARD_MAX_PATH_BYTES },
  }) do
    if type(limit[2]) ~= "number" or limit[2] ~= limit[2] or limit[2] % 1 ~= 0
        or limit[2] < 1 or limit[2] > limit[3] then
      error("invalid " .. limit[1], 2)
    end
  end
  return setmetatable({
    id = "mounts",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 5000),
    fs = options.fs or FS.default,
    mountinfo_path = Common.absolute_path(
      "mountinfo_path", options.mountinfo_path, "/proc/self/mountinfo"),
    statvfs = options.statvfs or Native.statvfs,
    statvfs_injected = options.statvfs ~= nil,
    statvfs_budget_ms = statvfs_budget_ms,
    statvfs_budget_explicit = options.statvfs_budget_ms ~= nil,
    max_statvfs_calls = max_statvfs_calls,
    max_statvfs_calls_explicit = options.max_statvfs_calls ~= nil,
    skip_risky_statvfs = options.skip_risky_statvfs ~= false,
    max_bytes = max_bytes,
    max_entries = max_entries,
    max_line_bytes = max_line_bytes,
    max_path_bytes = max_path_bytes,
    _method_style = true,
  }, Mounts)
end

function Mounts:_parse(content)
  return MountInfo.parse(content, {
    max_bytes = self.max_bytes,
    max_entries = self.max_entries,
    max_line_bytes = self.max_line_bytes,
    max_path_bytes = self.max_path_bytes,
  })
end

function Mounts:probe(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.mountinfo_path, self.max_bytes)
  if not content then
    local status = FS.error_status(err)
    if status == "denied" then
      return Capability.denied(err and err.message or "mountinfo_denied", { source = self.mountinfo_path })
    end
    return Capability.unavailable(err and err.message or "mountinfo_unavailable", {
      source = self.mountinfo_path,
    })
  end
  local entries, parse_error = self:_parse(content)
  if not entries then
    return Capability.error(parse_error, { source = self.mountinfo_path })
  end
  if not self.statvfs_injected and not Native.available then
    return Capability.new("degraded", {
      reason = Native.error or "native_statvfs_unavailable",
      source = self.mountinfo_path,
      details = { mounts = #entries },
    })
  end
  return Capability.available({ source = self.mountinfo_path, details = { mounts = #entries } })
end

function Mounts:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local content, read_error = fs:read(self.mountinfo_path, self.max_bytes)
  if not content then
    return Common.error_result(read_error, Common.now_ns(context), self.mountinfo_path)
  end
  local entries, parse_error = self:_parse(content)
  if not entries then
    local finished = Common.now_ns(context)
    return Common.result("error", finished, nil, {
      quality = "error",
      reason = parse_error,
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.mountinfo_path,
    })
  end

  local provider = context and context.statvfs or self.statvfs
  if type(provider) ~= "function" then
    local finished = Common.now_ns(context)
    return Common.result("error", finished, nil, {
      quality = "error", reason = "invalid_statvfs_provider",
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.mountinfo_path,
    })
  end
  local provider_injected = (context and context.statvfs ~= nil) or self.statvfs_injected
  local enforce_time_budget = not provider_injected or self.statvfs_budget_explicit
  local enforce_call_budget = not provider_injected or self.max_statvfs_calls_explicit
  local statvfs_started = enforce_time_budget and Common.now_ns(context) or nil
  local statvfs_budget_ns = self.statvfs_budget_ms * 1000000
  local errors = {}
  local by_id = {}
  local complete = 0
  local skipped = 0
  local statvfs_attempted = 0
  local budget_exhausted = false
  local budget_reason
  for _, mount in ipairs(entries) do
    local usage, failure_status, failure_reason, failure_errno
    local skip_reason
    if self.skip_risky_statvfs and not provider_injected and potentially_blocking_filesystem(mount) then
      failure_status = "unavailable"
      skip_reason = "statvfs_skipped_potentially_blocking_filesystem"
      failure_reason = skip_reason
      skipped = skipped + 1
    elseif budget_exhausted
        or (enforce_call_budget and statvfs_attempted >= self.max_statvfs_calls)
        or (enforce_time_budget
          and (Common.elapsed_ns(Common.now_ns(context), statvfs_started) or 0)
            >= statvfs_budget_ns) then
      if not budget_exhausted then
        if enforce_call_budget and statvfs_attempted >= self.max_statvfs_calls then
          budget_reason = "calls"
        else
          budget_reason = "time"
        end
      end
      budget_exhausted = true
      failure_status = "unavailable"
      skip_reason = "statvfs_skipped_budget_exhausted"
      failure_reason = skip_reason
      skipped = skipped + 1
    else
      statvfs_attempted = statvfs_attempted + 1
      usage, failure_status, failure_reason, failure_errno = collect_usage(provider, mount.mount_point)
    end
    if usage then
      mount.capacity = usage.capacity
      mount.inodes = usage.inodes
      mount.quality = "fresh"
      mount.partial = false
      complete = complete + 1
    else
      mount.quality = failure_status
      mount.partial = true
      mount.skipped = skip_reason ~= nil
      mount.partial_reason = skip_reason or ("statvfs_" .. failure_status)
      mount.statvfs_error = {
        status = failure_status,
        reason = failure_reason,
        errno = failure_errno,
      }
      if not skip_reason then
        errors[#errors + 1] = {
          id = mount.id,
          mount_point = mount.mount_point,
          status = failure_status,
          reason = failure_reason,
          errno = failure_errno,
        }
      end
    end
    by_id[mount.id] = mount
  end
  table.sort(entries, stable_mount_order)
  table.sort(errors, function(left, right)
    if left.mount_point == right.mount_point then return left.id < right.id end
    return left.mount_point < right.mount_point
  end)

  local finished = Common.now_ns(context)
  local partial = #errors > 0 or skipped > 0
  return Common.result("ok", finished, {
    mounts = entries,
    by_id = by_id,
    count = #entries,
    complete = complete,
    failed = #errors,
    skipped = skipped,
    budget_exhausted = budget_exhausted,
    budget_reason = budget_reason,
    statvfs_attempted = statvfs_attempted,
    statvfs_budget_ms = enforce_time_budget and self.statvfs_budget_ms or nil,
    max_statvfs_calls = enforce_call_budget and self.max_statvfs_calls or nil,
    partial = partial,
    errors = errors,
  }, {
    quality = partial and "partial" or "fresh",
    reason = partial and "statvfs_partial" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = self.mountinfo_path,
  })
end

Mounts.usage_from_statvfs = usage_from_statvfs
Mounts.statvfs_error = statvfs_error
Mounts.stable_mount_order = stable_mount_order
Mounts.potentially_blocking_filesystem = potentially_blocking_filesystem
Mounts.DEFAULT_STATVFS_BUDGET_MS = DEFAULT_STATVFS_BUDGET_MS
Mounts.DEFAULT_MAX_STATVFS_CALLS = DEFAULT_MAX_STATVFS_CALLS

return Mounts
