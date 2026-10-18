-- Normalize native declarations in the reader before any raw EDID can cross
-- the process transport. PnP ancestor IDs stay private to the shared graph.
local Common = require("wtop.collectors.common")
local Capability = require("wtop.core.capability")
local EDID = require("wtop.format.edid")
local M = {}
local MAX_DEVICES, MAX_EDID = 128, 32768

local function integer(value, maximum)
  return type(value) == "number" and math.type(value) == "integer"
    and value >= 0 and value <= maximum and value or nil
end

function M.result(input, now)
  local source = "native:collect_displays"
  if type(input) ~= "table" or input.backend ~= "setupapi"
      or type(input.devices) ~= "table" then
    return Common.result("error", now, nil, { source = source, reason = "display_native_data_invalid" })
  end
  local status = input.status
  if status == "unavailable" and (#input.devices ~= 0 or input.total ~= 0
      or input.truncated == true or input.total_is_lower_bound == true) then
    return Common.result("error", now, nil, { source = source, reason = "display_native_data_invalid" })
  end
  if status == "unavailable" or status == "denied" or status == "error" then
    local reason = status == "unavailable" and "no_windows_displays"
      or status == "denied" and "display_inventory_denied" or "display_inventory_incomplete"
    local result = Common.result(status, now, nil, { source = source, reason = reason })
    result.capability = status == "denied" and Capability.denied(reason, { source = source })
      or status == "error" and Capability.error(reason, { source = source })
      or Capability.unavailable(reason, { source = source })
    return result
  end
  if status ~= "ok" or #input.devices == 0 then
    return Common.result("error", now, nil, { source = source, reason = "display_native_data_invalid" })
  end
  local data = { devices = {}, source = "SetupAPI:GUID_DEVCLASS_MONITOR/EDID",
    total = integer(input.total, 2147483647) or #input.devices,
    total_is_lower_bound = input.total_is_lower_bound == true,
    truncated = input.truncated == true or #input.devices > MAX_DEVICES }
  local partial, seen, counts = input.quality == "partial", {}, {}
  for index = 1, math.min(#input.devices, MAX_DEVICES) do
    local raw = input.devices[index]
    if type(raw) == "table" and type(raw.id) == "string" then counts[raw.id] = (counts[raw.id] or 0) + 1 end
  end
  for index = 1, math.min(#input.devices, MAX_DEVICES) do
    local raw = input.devices[index]
    local id = type(raw) == "table" and type(raw.id) == "string" and raw.id:match("^monitor%d+$")
    if id and #id <= 32 and not seen[id] then
      seen[id] = true
      local row = { id = id, backend = "setupapi", source = data.source, modes = {} }
      local observed = integer(raw.observed_at_ns, math.maxinteger)
      local valid = raw._identity_verified == true and observed and observed > 0 and observed <= now
        and counts[id] == 1 and (raw.quality == "fresh" or raw.quality == "partial")
        and type(raw._pnp_instance_id) == "string" and #raw._pnp_instance_id > 0 and #raw._pnp_instance_id <= 1024
      if valid then
        row.os_present, row.connection = true, "unknown"
        row._pnp_instance_id = raw._pnp_instance_id
        row.observed_at_ns = observed
        row.driver = Common.safe_text(raw.driver, 160)
        row.quality = raw.quality == "partial" and "partial" or "fresh"
        if raw.reason == "display_parent_unavailable" then row.reason = raw.reason end
        if raw.reason ~= "display_parent_unavailable" and type(raw._pnp_parent_id) == "string" and #raw._pnp_parent_id <= 1024
            and (raw._pnp_parent_bus == "pci" or raw._pnp_parent_bus == "usb") then
          row._pnp_parent_id, row._pnp_parent_bus = raw._pnp_parent_id, raw._pnp_parent_bus
        end
        row.win32_error = integer(raw.win32_error, 0xffffffff)
        if raw.edid_status == "ok" and type(raw._edid) == "string" then
          if #raw._edid <= MAX_EDID then
            row.edid, row.edid_reason = EDID.parse(raw._edid)
            row.edid_status = row.edid and "ok" or "error"
          else row.edid_status, row.edid_reason = "error", "edid_too_large" end
          if not row.edid or row.edid.quality ~= "fresh" then
            row.quality = "partial"
            row.reason = row.reason or "display_edid_incomplete"
          end
        else
          row.edid_status = raw.edid_status == "denied" and "denied"
            or raw.edid_status == "error" and "error" or "unavailable"
          if raw.edid_reason == "edid_too_large" or raw.edid_reason == "display_edid_budget_exhausted" then
            row.edid_reason = raw.edid_reason
          end
          if row.edid_status ~= "unavailable" or row.edid_reason or raw.edid_status == "ok" then
            row.quality = "partial"
            row.reason = row.reason or "display_edid_unavailable"
          end
        end
      else
        row.quality = "gap"
        if raw.reason == "display_identity_unavailable" then row.reason = raw.reason
        else row.reason = "display_changed_during_read" end
        row.edid_status = "gap"
      end
      if row.quality ~= "fresh" then partial = true end
      data.devices[#data.devices + 1] = row
    else partial = true end
  end
  if #data.devices < #input.devices then data.truncated = true end
  data.total = math.max(data.total, #input.devices)
  local quality = partial and "partial" or data.truncated and "truncated" or "fresh"
  local reason
  if partial then reason = "display_inventory_incomplete"
  elseif data.truncated then reason = "device_enumeration_truncated" end
  local result = Common.result("ok", now, data, { source = source, quality = quality, reason = reason })
  result.capability = Capability.available({ source = source })
  return result
end

-- The reader is stateless; the parent owns continuity. Private PnP identities
-- become opaque IDs for this sampling session, so enumeration order cannot
-- rebind a selected device. Complete disappearance retires the old identity.
function M.publish(result, state)
  state.entries = state.entries or {}
  state.next_id = state.next_id or 0
  local now = result.timestamp_ns
  if state.last_ns and now < state.last_ns then state.entries = {} end
  state.last_ns = now
  if result.status == "unavailable" and result.reason == "no_windows_displays" then
    state.entries = {}
    return result
  end
  local data = result.data
  if result.status ~= "ok" or type(data) ~= "table" then return result end
  local setupapi = false
  for _, row in ipairs(data.devices or {}) do if row.backend == "setupapi" then setupapi = true break end end
  if not setupapi then return result end
  if not state.session then
    local ok, pid = pcall(require("wtop.native").pid)
    state.session = tostring(ok and pid or 0) .. ":" .. tostring(now)
  end
  state.generation = (state.generation or 0) + 1
  local complete = not data.truncated and not data.total_is_lower_bound and data.total == #(data.devices or {})
  local seen = {}
  for _, row in ipairs(data.devices or {}) do
    local key = row._pnp_instance_id
    row._pnp_instance_id = nil
    if type(key) == "string" and row.quality ~= "gap" then
      key = key:gsub("[a-z]", function(c) return string.char(c:byte() - 32) end)
      local identity = state.entries[key]
      if not identity then
        identity = { id = "monitor" .. state.next_id }
        state.next_id = state.next_id + 1
        state.entries[key] = identity
      end
      row.id, row.identity_scope = identity.id, "session"
      identity.generation, seen[key] = state.generation, true
    else
      row.id, row.identity_scope = "unverified" .. state.next_id, "observation"
      state.next_id = state.next_id + 1
      complete = false
    end
  end
  if complete then
    for key in pairs(state.entries) do if not seen[key] then state.entries[key] = nil end end
  end
  local keys = {}
  for key, identity in pairs(state.entries) do keys[#keys + 1] = { key = key, generation = identity.generation } end
  if #keys > 256 then
    table.sort(keys, function(a, b) return a.generation == b.generation and a.key < b.key or a.generation > b.generation end)
    for index = 257, #keys do state.entries[keys[index].key] = nil end
  end
  data.identity_session = state.session
  return result
end

return M
