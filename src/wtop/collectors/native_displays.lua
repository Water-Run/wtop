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

local function signed_coordinate(value)
  return type(value) == "number" and math.type(value) == "integer"
    and value >= -2147483648 and value <= 2147483647
end

local function windows_desktop(row, raw, now)
  if raw.desktop_status == nil then return end -- Older readers have no GDI observation.
  local status = raw.desktop_status
  if status ~= "ok" then
    row.desktop_status = status == "gap" and "gap" or status == "unavailable" and "unavailable" or "error"
    if row.desktop_status ~= "unavailable" then row.quality = "partial" end
    return
  end
  if raw._desktop_identity_verified ~= true or type(raw.desktop_active) ~= "boolean"
      or type(raw.desktop_primary) ~= "boolean" then
    row.desktop_status, row.quality = "gap", "partial"
    return
  end
  row.desktop_status = "ok"
  row.desktop_active, row.desktop_primary = raw.desktop_active, raw.desktop_primary
  local mode = raw.current_mode
  if not raw.desktop_active then
    row.current_mode_status = "unavailable"
    return
  end
  local valid = raw.current_mode_status == "ok" and type(mode) == "table"
    and integer(mode.pixel_width, 2147483647) and mode.pixel_width > 0
    and integer(mode.pixel_height, 2147483647) and mode.pixel_height > 0
    and integer(mode.observed_at_ns, math.maxinteger) and mode.observed_at_ns >= row.observed_at_ns
    and mode.observed_at_ns <= now
    and (mode.refresh_hz == nil or integer(mode.refresh_hz, 10000))
    and (mode.bits_per_pixel == nil or integer(mode.bits_per_pixel, 128) and mode.bits_per_pixel > 0)
    and ((mode.position_x == nil and mode.position_y == nil)
      or signed_coordinate(mode.position_x) and signed_coordinate(mode.position_y))
    and (mode.orientation_degrees == nil or integer(mode.orientation_degrees, 270)
      and mode.orientation_degrees % 90 == 0)
    and (mode.interlaced == nil or type(mode.interlaced) == "boolean")
  if not valid then
    row.current_mode_status = raw.current_mode_status == "unavailable" and "unavailable" or "error"
    row.quality = "partial"
    return
  end
  row.current_mode_status, row.current_mode_observed_at_ns = "ok", mode.observed_at_ns
  row.current_mode = { pixel_width = mode.pixel_width, pixel_height = mode.pixel_height,
    bits_per_pixel = mode.bits_per_pixel, position_x = mode.position_x, position_y = mode.position_y,
    orientation_degrees = mode.orientation_degrees, interlaced = mode.interlaced,
    observed_at_ns = mode.observed_at_ns, refresh_kind = "nominal", scope = "windows_desktop_source",
    source = "GDI:EnumDisplaySettingsExW", quality = "fresh" }
  if mode.refresh_hz and mode.refresh_hz > 1 then row.current_mode.refresh_hz = mode.refresh_hz end
end

local function setupapi_result(input, now)
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
        windows_desktop(row, raw, now)
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

local function coregraphics_result(input, now)
  local source = "native:collect_displays"
  local function failure(status, reason)
    local result = Common.result(status, now, nil, { source = source, reason = reason })
    result.capability = status == "denied" and Capability.denied(reason, { source = source })
      or status == "unavailable" and Capability.unavailable(reason, { source = source })
      or Capability.error(reason, { source = source })
    return result
  end
  if type(input.devices) ~= "table" then return failure("error", "display_native_data_invalid") end
  if input.status == "unavailable" then
    if #input.devices ~= 0 or input.total ~= 0 or input.truncated == true
        or input.total_is_lower_bound == true or input.quality ~= "fresh" then
      return failure("error", "display_native_data_invalid")
    end
    return failure("unavailable", "no_macos_displays")
  end
  if input.status == "denied" then return failure("denied", "display_inventory_denied") end
  if input.status == "error" then return failure("error", "display_inventory_incomplete") end
  if input.status ~= "ok" or #input.devices == 0 then return failure("error", "display_native_data_invalid") end
  local data = { devices = {}, source = "CoreGraphics:online/current-mode",
    total = integer(input.total, 2147483647) or #input.devices,
    total_is_lower_bound = input.total_is_lower_bound == true,
    truncated = input.truncated == true or #input.devices > MAX_DEVICES }
  local seen, counts, identities, partial = {}, {}, {}, input.quality == "partial"
  for index = 1, math.min(#input.devices, MAX_DEVICES) do
    local r = input.devices[index]
    if type(r) == "table" then
      if type(r.id) == "string" then counts[r.id] = (counts[r.id] or 0) + 1 end
      if type(r._display_identity) == "string" then
        local key = r._display_identity:lower()
        identities[key] = (identities[key] or 0) + 1
      end
    end
  end
  for index = 1, math.min(#input.devices, MAX_DEVICES) do
    local raw = input.devices[index]
    local id = type(raw) == "table" and type(raw.id) == "string" and raw.id:match("^monitor%d+$")
    if id and #id <= 32 and not seen[id] then
      seen[id] = true
      local row = { id = id, backend = "coregraphics", source = data.source, modes = {} }
      local observed = integer(raw.observed_at_ns, math.maxinteger)
      local key = type(raw._display_identity) == "string" and raw._display_identity:lower()
      local valid = raw._identity_verified == true and counts[id] == 1 and observed and observed > 0 and observed <= now
        and key and #key == 32 and key:match("^[0-9a-f]+$") and not key:match("^0+$") and identities[key] == 1
        and (raw.quality == "fresh" or raw.quality == "partial") and raw.online == true
        and type(raw.active) == "boolean" and type(raw.asleep) == "boolean"
        and type(raw.builtin) == "boolean" and type(raw.main) == "boolean"
      if valid then
        row._display_identity, row.identity_scope = key, "session"
        row.observed_at_ns, row.quality = observed, raw.quality
        row.os_present, row.connection = true, "unknown"
        row.online, row.active, row.asleep, row.builtin, row.main = true, raw.active, raw.asleep, raw.builtin, raw.main
        row.vendor_number, row.model_number = integer(raw.vendor_number, 0xffffffff), integer(raw.model_number, 0xffffffff)
        local m = raw.current_mode
        local refresh = type(m) == "table" and m.refresh_hz or nil
        local mode_valid = raw.current_mode_status == "ok" and type(m) == "table"
          and integer(m.width_points, 2147483647) and m.width_points > 0
          and integer(m.height_points, 2147483647) and m.height_points > 0
          and integer(m.pixel_width, 2147483647) and m.pixel_width > 0
          and integer(m.pixel_height, 2147483647) and m.pixel_height > 0
          and (refresh == nil or type(refresh) == "number" and refresh >= 0 and refresh <= 10000)
        if mode_valid then
          row.current_mode_status = "ok"
          row.current_mode = { width_points = m.width_points, height_points = m.height_points,
            pixel_width = m.pixel_width, pixel_height = m.pixel_height, refresh_kind = "nominal" }
          if refresh and refresh > 0 then row.current_mode.refresh_hz = refresh end
        else
          row.current_mode_status = raw.current_mode_status == "unavailable" and "unavailable" or "error"
          row.quality = "partial"
          row.reason = "display_current_mode_unavailable"
        end
      else
        row.quality, row.current_mode_status = "gap", "gap"
        row.reason = raw.reason == "display_identity_unavailable" and raw.reason or "display_changed_during_read"
      end
      if row.quality ~= "fresh" then partial = true end
      data.devices[#data.devices + 1] = row
    else partial = true end
  end
  if #data.devices < #input.devices then data.truncated = true end
  data.total = math.max(data.total, #input.devices)
  local quality = partial and "partial" or data.truncated and "truncated" or "fresh"
  local reason = partial and "display_inventory_incomplete" or data.truncated and "device_enumeration_truncated" or nil
  local result = Common.result("ok", now, data, { source = source, quality = quality, reason = reason })
  result.capability = Capability.available({ source = source })
  return result
end

function M.result(input, now)
  if type(input) == "table" and input.backend == "coregraphics" then return coregraphics_result(input, now) end
  return setupapi_result(input, now)
end

-- The reader is stateless; the parent owns continuity. Private OS identities
-- become opaque IDs for this sampling session, so enumeration order cannot
-- rebind a selected device. Complete disappearance retires the old identity.
function M.publish(result, state)
  state.entries = state.entries or {}
  state.next_id = state.next_id or 0
  local now = result.timestamp_ns
  if state.last_ns and now < state.last_ns then state.entries = {} end
  state.last_ns = now
  if result.status == "unavailable" and (result.reason == "no_windows_displays" or result.reason == "no_macos_displays") then
    state.entries = {}
    return result
  end
  local data = result.data
  if result.status ~= "ok" or type(data) ~= "table" then return result end
  local native = false
  for _, row in ipairs(data.devices or {}) do
    if row.backend == "setupapi" or row.backend == "coregraphics" then native = true break end
  end
  if not native then return result end
  if not state.session then
    local ok, pid = pcall(require("wtop.native").pid)
    state.session = tostring(ok and pid or 0) .. ":" .. tostring(now)
  end
  state.generation = (state.generation or 0) + 1
  local complete = not data.truncated and not data.total_is_lower_bound and data.total == #(data.devices or {})
  local seen = {}
  for _, row in ipairs(data.devices or {}) do
    local key = row.backend == "coregraphics" and row._display_identity or row._pnp_instance_id
    row._pnp_instance_id, row._display_identity = nil, nil
    if type(key) == "string" and row.quality ~= "gap" then
      key = key:gsub("[a-z]", function(c) return string.char(c:byte() - 32) end)
      key = row.backend .. ":" .. key
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
