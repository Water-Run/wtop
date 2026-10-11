-- Optional, read-only NVMe namespace/path diagnostics from the documented
-- Linux sysfs ABI. No identifier, serial, or namespace WWID is read.
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Sysfs = require("wtop.linux.sysfs")

local M = {}

M.COUNTERS = {
  { "command_retries", "diag/command_retries_count" },
  { "command_errors", "diag/command_error_count" },
  { "multipath_failovers", "diag/multipath_failover_count" },
  { "io_requeues_no_path", "diag/io_requeue_no_usable_path_count" },
  { "io_failures_no_path", "diag/io_fail_no_available_path_count" },
}
M.CONTROLLER_COUNTERS = {
  { "command_errors", "diag/command_error_count" },
  { "resets", "diag/reset_count" },
  { "reconnects", "diag/reconnect_count" },
}
M.NUSE_REFRESH_NS = 60 * 1000000000

local ANA_STATES = { ["optimized"] = true, ["non-optimized"] = true,
  ["inaccessible"] = true, ["persistent-loss"] = true, ["change"] = true }
local IO_POLICIES = { numa = true, ["round-robin"] = true,
  ["queue-depth"] = true }
local MAX_PATH_ENTRIES, MAX_PATHS = 256, 32

function M.namespace_name(name)
  return type(name) == "string" and
    (name:match("^nvme%d+n%d+$") ~= nil or name:match("^nvme%d+c%d+n%d+$") ~= nil)
end

local function read_unsigned(fs, path)
  local raw, err = fs:read(path, 64)
  if not raw then return nil, FS.error_status(err) end
  local token = raw:match("^%s*(%d+)%s*$")
  local value = token and tonumber(token) or nil
  if not value or math.type(value) ~= "integer" or value < 0 then
    return nil, "parse_error"
  end
  return value, "ok"
end

local function read_nuse(fs, base, observed_ns, previous, logical_block_size,
    capacity_bytes)
  local path = base .. "/nuse"
  local valid_size = type(logical_block_size) == "number"
    and math.type(logical_block_size) == "integer"
    and logical_block_size > 0 and logical_block_size <= 65536
  local old = type(previous) == "table" and previous.nuse or nil
  if type(old) == "table" and old.source == path
      and old.logical_block_size_bytes == logical_block_size
      and (old.status == "ok" or old.status == "unavailable")
      and type(observed_ns) == "number" and type(old.observed_ns) == "number"
      and observed_ns >= old.observed_ns
      and observed_ns - old.observed_ns < M.NUSE_REFRESH_NS then
    return { source = path, observed_ns = old.observed_ns,
      status = old.status,
      quality = old.quality, cached = true,
      logical_block_size_bytes = logical_block_size,
      allocated_lbas = old.allocated_lbas, allocated_bytes = old.allocated_bytes }
  end
  local value, status = read_unsigned(fs, path)
  local result = { source = path, observed_ns = observed_ns,
    status = status,
    quality = status == "ok" and "fresh"
      or status == "parse_error" and "partial" or status,
    cached = false,
    logical_block_size_bytes = valid_size and logical_block_size or nil }
  if value ~= nil then
    result.allocated_lbas = value
    if valid_size and value <= math.maxinteger // logical_block_size then
      local bytes = value * logical_block_size
      if type(capacity_bytes) ~= "number" or bytes <= capacity_bytes then
        result.allocated_bytes = bytes
      else result.status, result.quality = "parse_error", "partial" end
    end
  end
  return result
end

local function read_ana_state(fs, path)
  local raw, err = fs:read(path, 64)
  if not raw then return nil, FS.error_status(err) end
  local state = Common.trim(raw)
  if not ANA_STATES[state] then return nil, "parse_error" end
  return state, "ok"
end

local function controller_for_physical(fs, physical, name)
  if not physical or Sysfs.basename(physical) ~= name then return nil end
  local parent = physical:match("^(.*)/[^/]+$")
  local controller = Sysfs.basename(parent)
  if not controller or not controller:match("^nvme%d+$") then return nil end
  local source = "/sys/class/nvme/" .. controller
  if Sysfs.device_path(fs, source) ~= parent then return nil end
  return controller, source
end

local function controller_source(fs, namespace_path, name)
  return controller_for_physical(fs, Sysfs.device_path(fs, namespace_path), name)
end

local function read_text(fs, path)
  local raw, err = fs:read(path, 64)
  if not raw then return nil, FS.error_status(err) end
  local value = Common.safe_text(Common.trim(raw), 32)
  return value ~= "" and value or nil, value ~= "" and "ok" or "unavailable"
end

local function multipath_paths(fs, namespace_path, name, observed_ns)
  local physical = Sysfs.device_path(fs, namespace_path)
  if not physical or Sysfs.basename(physical) ~= name then return nil end
  local parent = physical:match("^(.*)/[^/]+$")
  local subsystem = Sysfs.basename(parent)
  if not subsystem or not subsystem:match("^nvme%-subsys%d+$")
      or Sysfs.device_path(fs, "/sys/class/nvme-subsystem/" .. subsystem) ~= parent then
    return nil
  end
  local result = { subsystem = subsystem, source = namespace_path,
    observed_ns = observed_ns, status = "unavailable", quality = "unavailable",
    items = {}, total = 0, truncated = false, issues = {} }
  local partial = false
  local function issue(field, status, path)
    if status ~= "unavailable" then
      partial = true
      result.issues[#result.issues + 1] = {
        field = field, status = status, source = path,
      }
    end
  end
  local policy_path = "/sys/class/nvme-subsystem/" .. subsystem .. "/iopolicy"
  local policy, policy_status = read_text(fs, policy_path)
  if policy and IO_POLICIES[policy] then result.iopolicy = policy
  elseif policy then issue("iopolicy", "parse_error", policy_path)
  else issue("iopolicy", policy_status, policy_path) end
  local entries, list_error, cut = fs:list(physical, MAX_PATH_ENTRIES)
  if not entries then
    result.status = FS.error_status(list_error)
    return result
  end
  local seen = {}
  for _, entry in ipairs(entries) do
    if type(entry) == "string" and entry:match("^nvme%d+c%d+n%d+$") then
      result.total = result.total + 1
      if result.total > MAX_PATHS then result.truncated = true break end
      local link_path = physical .. "/" .. entry
      local target = Sysfs.device_path(fs, link_path)
      local controller, source = controller_for_physical(fs, target, entry)
      if not controller or seen[target] then
        issue("path_link", "parse_error", link_path)
      else
        seen[target] = true
        local item = { name = entry, controller = controller,
          controller_source = source, source = link_path,
          status = "unavailable", quality = "unavailable" }
        local present, bad = 0, false
        local function item_issue(field, status, path)
          if status ~= "unavailable" then
            bad = true
            issue(field, status, path)
          end
        end
        for _, specification in ipairs({
            { "controller_state", source .. "/state" },
            { "transport", source .. "/transport" },
          }) do
          local value, status = read_text(fs, specification[2])
          if value then item[specification[1]], present = value, present + 1
          else item_issue(specification[1], status, specification[2]) end
        end
        local ana_path = target .. "/ana_state"
        local ana, ana_status = read_ana_state(fs, ana_path)
        if ana then item.ana_state, present = ana, present + 1
        else item_issue("ana_state", ana_status, ana_path) end
        local group_path = target .. "/ana_grpid"
        local group, group_status = read_unsigned(fs, group_path)
        if group and group > 0 then item.ana_group_id, present = group, present + 1
        elseif group_status == "ok" then item_issue("ana_grpid", "parse_error", group_path)
        else item_issue("ana_grpid", group_status, group_path) end
        if bad then item.status, item.quality = "partial", "partial"
        elseif present > 0 then item.status, item.quality = "ok", "fresh" end
        result.items[#result.items + 1] = item
      end
    end
  end
  table.sort(result.items, function(a, b) return a.name < b.name end)
  result.truncated = result.truncated or cut == true
  if result.truncated then result.status, result.quality = "truncated", "truncated"
  elseif partial then result.status, result.quality = "partial", "partial"
  elseif #result.items > 0 then result.status, result.quality = "ok", "fresh" end
  return result
end

local function controller_raw(fs, name, source)
  local result = { name = name, source = source, counters = {}, issues = {},
    status = "unavailable", quality = "unavailable" }
  local present, partial = 0, false
  local function issue(field, status, path)
    if status ~= "unavailable" then
      partial = true
      result.issues[#result.issues + 1] = {
        field = field, status = status, source = path,
      }
    end
  end
  for _, field in ipairs({ "state", "transport" }) do
    local path = source .. "/" .. field
    local raw, err = fs:read(path, 64)
    if raw then
      local value = Common.safe_text(Common.trim(raw), 32)
      if value ~= "" then result[field], present = value, present + 1
      else issue(field, "parse_error", path) end
    else issue(field, FS.error_status(err), path) end
  end
  for _, specification in ipairs(M.CONTROLLER_COUNTERS) do
    local field, path = specification[1], source .. "/" .. specification[2]
    local total, status = read_unsigned(fs, path)
    result.counters[field] = { status = status, total = total }
    if total ~= nil then present = present + 1
    else issue(field, status, path) end
  end
  if partial then result.status, result.quality = "partial", "partial"
  elseif present > 0 then result.status, result.quality = "ok", "fresh" end
  return result
end

local function read_controller(fs, namespace_path, name, observed_ns, previous, batch)
  local controller, source = controller_source(fs, namespace_path, name)
  if not controller then return nil end
  local raw = type(batch) == "table" and batch[source] or nil
  if not raw then
    raw = controller_raw(fs, controller, source)
    if type(batch) == "table" then batch[source] = raw end
  end
  local issues = {}
  for index, issue in ipairs(raw.issues) do
    issues[index] = { field = issue.field, status = issue.status,
      source = issue.source }
  end
  local result = { name = controller, source = source, observed_ns = observed_ns,
    state = raw.state, transport = raw.transport, status = raw.status,
    quality = raw.quality, issues = issues, counters = {} }
  local same_controller = type(previous) == "table"
    and previous.name == controller and previous.source == source
  for _, specification in ipairs(M.CONTROLLER_COUNTERS) do
    local field = specification[1]
    local measured = raw.counters[field]
    local counter = { status = measured.status,
      total = measured.total, delta_quality = "unavailable" }
    if measured.total ~= nil then
      local old = same_controller and previous.counters
        and previous.counters[field] or nil
      if type(old) == "table" and old.status == "ok"
          and math.type(old.total) == "integer" then
        local delta, cause = Common.delta(measured.total, old.total)
        if delta ~= nil then counter.new, counter.delta_quality = delta, "fresh"
        else counter.delta_quality = cause == "reset" and "reset" or "gap" end
      else counter.delta_quality = "gap" end
    end
    result.counters[field] = counter
  end
  return result
end

function M.read(fs, name, observed_ns, previous, controller_batch,
    logical_block_size, capacity_bytes)
  if not M.namespace_name(name) then return nil end
  local base = "/sys/block/" .. name
  local result = { source = base, observed_ns = observed_ns, counters = {},
    issues = {}, status = "unavailable", quality = "unavailable" }
  local present, partial = 0, false
  local function issue(field, status, path)
    partial = true
    result.issues[#result.issues + 1] = {
      field = field, status = status, source = path,
    }
  end
  local previous_counters = type(previous) == "table"
    and type(previous.counters) == "table" and previous.counters or {}
  for _, specification in ipairs(M.COUNTERS) do
    local field, path = specification[1], base .. "/" .. specification[2]
    local total, status = read_unsigned(fs, path)
    local counter = { status = status, delta_quality = "unavailable" }
    if total ~= nil then
      present = present + 1
      counter.total = total
      local old = previous_counters[field]
      if type(old) == "table" and old.status == "ok"
          and math.type(old.total) == "integer" then
        local delta, delta_cause = Common.delta(total, old.total)
        if delta ~= nil then
          counter.new, counter.delta_quality = delta, "fresh"
        else counter.delta_quality = delta_cause == "reset" and "reset" or "gap" end
      else counter.delta_quality = "gap" end
    elseif status ~= "unavailable" then issue(field, status, path) end
    result.counters[field] = counter
  end
  local state_path = base .. "/ana_state"
  local ana_state, ana_status = read_ana_state(fs, state_path)
  if ana_state then result.ana_state = ana_state; present = present + 1
  elseif ana_status ~= "unavailable" then issue("ana_state", ana_status, state_path) end
  local group_path = base .. "/ana_grpid"
  local ana_group_id, group_status = read_unsigned(fs, group_path)
  if ana_group_id and ana_group_id > 0 then
    result.ana_group_id = ana_group_id
    present = present + 1
  elseif group_status == "ok" then issue("ana_grpid", "parse_error", group_path)
  elseif group_status ~= "unavailable" then issue("ana_grpid", group_status, group_path) end
  if partial then result.status, result.quality = "partial", "partial"
  elseif present > 0 then result.status, result.quality = "ok", "fresh" end
  result.controller = read_controller(fs, base, name, observed_ns,
    type(previous) == "table" and previous.controller or nil, controller_batch)
  result.paths = multipath_paths(fs, base, name, observed_ns)
  if name:match("^nvme%d+n%d+$") then
    result.nuse = read_nuse(fs, base, observed_ns, previous,
      logical_block_size, capacity_bytes)
  end
  return result
end

return M
