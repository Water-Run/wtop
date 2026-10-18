-- Current KMS configuration is separate from cached EDID declarations.
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local M = {}
local function integer(value, maximum)
  return type(value) == "number" and math.type(value) == "integer"
    and value >= 0 and value <= maximum and value or nil
end

local function normalize(raw)
  if type(raw) ~= "table" then return nil end
  local width, height = integer(raw.pixel_width, 65535), integer(raw.pixel_height, 65535)
  local clock = integer(raw.pixel_clock_hz, 0xffffffff * 1000)
  local htotal, vtotal = integer(raw.horizontal_total, 65535), integer(raw.vertical_total, 65535)
  local vscan, flags = integer(raw.vscan, 65535), integer(raw.flags, 0xffffffff)
  if not width or width == 0 or not height or height == 0 or not clock or not htotal
      or not vtotal or not vscan or not flags
      or htotal > 0 and htotal < width or vtotal > 0 and vtotal < height then return nil end
  local mode = { pixel_width = width, pixel_height = height, flags = flags,
    interlaced = (flags & 0x10) ~= 0, double_scan = (flags & 0x20) ~= 0,
    vscan = vscan, refresh_kind = "nominal", scope = "configured_crtc", source = "drm-kms", quality = "fresh" }
  if clock > 0 then mode.pixel_clock_hz = clock end
  if htotal > 0 then mode.horizontal_total = htotal end
  if vtotal > 0 then mode.vertical_total = vtotal end
  if clock > 0 and htotal > 0 and vtotal > 0 then
    local rate = clock / htotal / vtotal
    if mode.interlaced then rate = rate * 2 end
    if mode.double_scan then rate = rate / 2 end
    if vscan > 1 then rate = rate / vscan end
    if rate <= 0 or rate > 10000 then return nil end
    mode.refresh_hz = rate
  end
  local approximate = integer(raw.approx_refresh_hz, 10000)
  if approximate and approximate > 0 then mode.approx_refresh_hz = approximate end
  return mode
end

-- Only the real DRM filesystem can authorize native device access. Replay
-- filesystems retain their declarations without causing host-device reads.
function M.attach(device, fs, base, context, native)
  if fs ~= FS.default or base ~= "/sys/class/drm" then return false end
  if type(native) ~= "table" or not native.available or type(native.read_drm_mode) ~= "function" then
    device.current_mode_status = "unavailable"
    device.current_mode_reason = "unsupported_on_this_platform"
    return false
  end
  local dev_path = base .. "/" .. device.card .. "/dev"
  local dev = fs:read(dev_path, 64)
  local text = type(dev) == "string" and Common.trim(dev)
  local major, minor
  if text then major, minor = text:match("^(%d+):(%d+)$") end
  major, minor = tonumber(major), tonumber(minor)
  if major ~= 226 or not integer(minor, 1048575) or not device.connector_id then
    device.current_mode_status = "unavailable"
    device.current_mode_reason = "display_mode_identity_unavailable"
    return true
  end
  local called, raw = pcall(native.read_drm_mode, device.card, major, minor, device.connector_id)
  local now = Common.now_ns(context)
  local after = fs:read(dev_path, 64)
  if dev ~= after then
    device.current_mode_status = "gap"
    device.current_mode_reason = "display_changed_during_read"
    return true
  end
  if not called or type(raw) ~= "table" or raw.backend ~= "drm-kms"
      or raw.connector_id ~= device.connector_id or raw.device_major ~= major or raw.device_minor ~= minor
      or not integer(raw.observed_at_ns, math.maxinteger) or raw.observed_at_ns <= 0 or raw.observed_at_ns > now then
    device.current_mode_status = "error"
    device.current_mode_reason = "display_native_data_invalid"
    return true
  end
  device.current_mode_observed_at_ns = raw.observed_at_ns
  device.current_mode_errno = integer(raw.errno, 2147483647)
  if raw.status == "ok" and raw.configured == true then
    local mode = normalize(raw.mode)
    if mode then
      mode.observed_at_ns = raw.observed_at_ns
      device.current_mode, device.current_mode_status, device.current_mode_configured = mode, "ok", true
      return false
    end
    device.current_mode_status = "error"
    device.current_mode_reason = "display_mode_invalid"
    return true
  end
  if raw.status == "unavailable" and raw.configured == false and not raw.errno then
    device.current_mode_status, device.current_mode_configured = "unavailable", false
    device.current_mode_reason = "display_mode_not_configured"
    return false
  end
  device.current_mode_status = raw.status == "denied" and "denied" or raw.status == "gap" and "gap"
    or raw.status == "unavailable" and "unavailable" or "error"
  device.current_mode_reason = device.current_mode_status == "gap" and "display_changed_during_read"
    or "display_current_mode_unavailable"
  return true
end
return M
