-- Optional device-mapper and MD identity/state from their read-only sysfs
-- attributes. UUIDs, metadata images, and device-mapper tables stay unread.
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")

local M = {}

local MD_STATES = { clear = true, inactive = true, suspended = true,
  readonly = true, ["read-auto"] = true, clean = true, active = true,
  ["write-pending"] = true, ["active-idle"] = true }
local SYNC_ACTIONS = { idle = true, resync = true, recover = true,
  check = true, repair = true, reshape = true, frozen = true }
local ACTIVE_SYNC = { resync = true, recover = true, check = true,
  repair = true, reshape = true }
local MAX_MD_ENTRIES, MAX_MD_MEMBERS = 512, 64

local function unsigned(token)
  if type(token) ~= "string" or not token:match("^%d+$") then return nil end
  local value = tonumber(token)
  return value and math.type(value) == "integer" and value >= 0
    and value <= 2147483647 and value or nil
end

local function unsigned_sector(token)
  if type(token) ~= "string" or not token:match("^%d+$") then return nil end
  local value = tonumber(token)
  return value and math.type(value) == "integer" and value >= 0
    and value <= math.maxinteger and value or nil
end

local function text(fs, path, limit)
  local raw, err = fs:read(path, 256)
  if not raw then return nil, FS.error_status(err) end
  local value = Common.trim(raw)
  if value == "" then return nil, "unavailable" end
  return Common.safe_text(value, limit), "ok"
end

local function count(fs, path)
  local raw, err = fs:read(path, 64)
  if not raw then return nil, FS.error_status(err) end
  local value = unsigned(Common.trim(raw))
  if value == nil then return nil, "parse_error" end
  return value, "ok"
end

local function raid_disks(fs, path)
  local raw, err = fs:read(path, 64)
  if not raw then return nil, nil, FS.error_status(err) end
  raw = Common.trim(raw)
  if raw == "" then return nil, nil, "unavailable" end
  local current, previous = raw:match("^(%d+)%s+%((%d+)%)$")
  if current then
    current, previous = unsigned(current), unsigned(previous)
    if current and previous then return current, previous, "ok" end
    return nil, nil, "parse_error"
  end
  current = unsigned(raw)
  if current then return current, nil, "ok" end
  return nil, nil, "parse_error"
end

local function sync_completed(fs, path)
  local raw, err = fs:read(path, 96)
  if not raw then return nil, nil, FS.error_status(err) end
  local done, total = Common.trim(raw):match("^(%d+)%s*/%s*(%d+)$")
  done, total = unsigned_sector(done), unsigned_sector(total)
  if not done or not total or done > total then return nil, nil, "parse_error" end
  if total == 0 then return nil, nil, "unavailable" end
  return done, total, "ok"
end

local function md_members(fs, base)
  local result = { source = base, status = "unavailable", items = {},
    issues = {}, total = 0, truncated = false }
  local names, err, cut = fs:list(base, MAX_MD_ENTRIES)
  if not names then
    result.status = FS.error_status(err)
    return result
  end
  local partial, seen_names, seen_devices = false, {}, {}
  local function issue(field, status, path)
    partial = true
    result.issues[#result.issues + 1] = { field = field,
      status = status, source = path }
  end
  for _, entry in ipairs(names) do
    if type(entry) == "string" and entry:sub(1, 4) == "dev-" then
      result.total = result.total + 1
      if result.total > MAX_MD_MEMBERS then
        result.truncated = true
        break
      end
      local safe = #entry > 4 and #entry <= 255
        and not entry:find("/", 1, true)
        and not entry:find("\0", 1, true) and not seen_names[entry]
      if not safe then
        issue("member_name", "parse_error", base)
      else
        seen_names[entry] = true
        local member_base = base .. "/" .. entry
        local dev_path = member_base .. "/block/dev"
        local raw, read_error = fs:read(dev_path, 64)
        local major, minor
        if type(raw) == "string" then
          major, minor = raw:match("^%s*(%d+):(%d+)%s*$")
        end
        major, minor = unsigned(major), unsigned(minor)
        if major == nil or minor == nil then
          issue("member_device", raw and "parse_error" or FS.error_status(read_error),
            dev_path)
        else
          local device_id = tostring(major) .. ":" .. tostring(minor)
          if seen_devices[device_id] then
            issue("member_device", "parse_error", dev_path)
          else
            seen_devices[device_id] = true
            local item = { name = Common.safe_text(entry:sub(5), 255),
              device_id = device_id, source = member_base,
              quality = "fresh" }
            local slot_path = member_base .. "/slot"
            local slot, slot_status = text(fs, slot_path, 64)
            if slot == "none" then item.slot = "none"
            elseif slot then
              local position = unsigned(slot)
              if position == nil then slot_status = "parse_error"
              else item.slot = position end
            end
            if slot_status ~= "ok" then
              item.quality = "partial"
              issue("member_slot", slot_status, slot_path)
            end
            local state_path = member_base .. "/state"
            local state, state_status = text(fs, state_path, 128)
            if state then
              local flags, seen_flags = {}, {}
              for flag in state:gmatch("[^,]+") do
                local normalized = Common.trim(flag)
                if not normalized:match("^[a-z][a-z0-9_]*$") or seen_flags[normalized]
                    or #flags >= 16 then
                  state_status = "parse_error"
                  break
                end
                seen_flags[normalized] = true
                flags[#flags + 1] = normalized
              end
              if #flags == 0 or state:sub(1, 1) == ","
                  or state:sub(-1) == "," or state:find(",,", 1, true) then
                state_status = "parse_error"
              end
              if state_status == "ok" then item.state = table.concat(flags, ",") end
            end
            if state_status ~= "ok" then
              item.quality = "partial"
              issue("member_state", state_status, state_path)
            end
            result.items[#result.items + 1] = item
          end
        end
      end
    end
  end
  table.sort(result.items, function(a, b)
    return a.name == b.name and a.device_id < b.device_id or a.name < b.name
  end)
  result.truncated = result.truncated or cut == true
  result.status = result.truncated and "truncated"
    or partial and "partial" or "ok"
  return result
end

function M.kind(name)
  if type(name) ~= "string" then return nil end
  if name:match("^dm%-%d+$") then return "dm" end
  if name:match("^md%d+$") or name:match("^md_d%d+$") then return "md" end
end

function M.read(fs, name, observed_ns)
  local kind = M.kind(name)
  if not kind then return nil end
  local base = "/sys/block/" .. name .. "/" .. kind
  local result = { kind = kind, source = base, observed_ns = observed_ns,
    status = "unavailable", quality = "unavailable", issues = {} }
  local observed, partial = 0, false
  local function issue(field, status, path)
    if status ~= "ok" and status ~= "unavailable" then
      partial = true
      result.issues[#result.issues + 1] = { field = field,
        status = status, source = path }
    end
  end
  if kind == "dm" then
    local name_path = base .. "/name"
    local mapped_name, name_status = text(fs, name_path, 128)
    if mapped_name then result.name, observed = mapped_name, observed + 1 end
    issue("name", name_status, name_path)
    local suspended_path = base .. "/suspended"
    local suspended, suspended_status = count(fs, suspended_path)
    if suspended == 0 or suspended == 1 then
      result.suspended, observed = suspended == 1, observed + 1
    elseif suspended_status == "ok" then suspended_status = "parse_error" end
    issue("suspended", suspended_status, suspended_path)
  else
    local level_path = base .. "/level"
    local level, level_status = text(fs, level_path, 32)
    if level then result.level, observed = level, observed + 1 end
    issue("level", level_status, level_path)
    local disks_path = base .. "/raid_disks"
    local disks, old_disks, disks_status = raid_disks(fs, disks_path)
    if disks then
      result.raid_disks, result.previous_raid_disks = disks, old_disks
      observed = observed + 1
    end
    issue("raid_disks", disks_status, disks_path)
    local degraded_path = base .. "/degraded"
    local degraded, degraded_status = count(fs, degraded_path)
    if degraded then result.degraded, observed = degraded, observed + 1 end
    issue("degraded", degraded_status, degraded_path)
    local state_path = base .. "/array_state"
    local state, state_status = text(fs, state_path, 32)
    if state and not MD_STATES[state] then state_status = "parse_error" end
    if state then result.array_state, observed = state, observed + 1 end
    issue("array_state", state_status, state_path)
    local action_path = base .. "/sync_action"
    local action, action_status = text(fs, action_path, 32)
    if action and not SYNC_ACTIONS[action] then action_status = "parse_error" end
    if action then result.sync_action, observed = action, observed + 1 end
    issue("sync_action", action_status, action_path)
    if action and ACTIVE_SYNC[action] then
      local completed_path = base .. "/sync_completed"
      local done, total, completed_status = sync_completed(fs, completed_path)
      if completed_status == "ok" then
        -- The operation can change between these two independent sysfs reads.
        local confirmed, confirm_status = text(fs, action_path, 32)
        if confirm_status == "ok" and confirmed == action then
          result.sync_completed_sectors = done
          result.sync_total_sectors = total
          result.sync_percent = math.floor(done / total * 1000 + 0.5) / 10
          result.sync_progress_status = "ok"
          observed = observed + 1
        else
          result.sync_progress_status = "gap"
          if confirmed and SYNC_ACTIONS[confirmed] then result.sync_action = confirmed end
          issue("sync_action", confirm_status, action_path)
        end
      else
        result.sync_progress_status = completed_status
        issue("sync_completed", completed_status, completed_path)
      end
    end
    result.members = md_members(fs, base)
  end
  if partial then result.status, result.quality = "partial", "partial"
  elseif observed > 0 then result.status, result.quality = "ok", "fresh" end
  return result
end

return M
