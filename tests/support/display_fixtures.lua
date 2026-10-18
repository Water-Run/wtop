local M = {}

function M.cta_block(tag, payload)
  assert(tag >= 0 and tag <= 7 and #payload <= 31)
  return string.char((tag << 5) | #payload) .. payload
end

function M.cta(options)
  options = options or {}
  local data, dtd = options.data or "", options.timings or ""
  assert(#data + #dtd <= 123)
  local b = {}
  for i = 1, 128 do b[i] = 0 end
  b[1], b[2], b[3], b[4] = 2, options.revision or 3, options.offset or (4 + #data), options.flags or 0
  for i = 1, #data do b[4 + i] = data:byte(i) end
  for i = 1, #dtd do b[4 + #data + i] = dtd:byte(i) end
  for offset, value in pairs(options.bytes or {}) do b[offset + 1] = value end
  local sum = 0
  for i = 1, 127 do sum = sum + b[i] end
  b[128] = (-sum) % 256
  if options.corrupt_checksum then b[128] = (b[128] + 1) % 256 end
  return string.char(table.unpack(b))
end

function M.edid(options)
  options = options or {}
  local b = {}
  for i = 1, 128 do b[i] = 0 end
  local function put(offset, bytes)
    for i = 1, #bytes do b[offset + i] = bytes:byte(i) end
  end
  put(0, "\0\255\255\255\255\255\255\0")
  put(8, string.char(0x4c, 0x2d, 0x34, 0x12, 0xef, 0xbe, 0xad, 0xde)) -- SAM, public product / private serial
  b[17], b[18], b[19], b[20] = 12, 34, 1, options.revision or 4
  b[21], b[22], b[23], b[25] = options.input or 0xa5, 52, 29, 2
  -- 148.5 MHz, 1920 x 1080 + 280 x 45 blanking = 60 progressive Hz.
  put(54, string.char(0x02, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40,
    88, 44, 0x45, 0, 0x08, 0x22, 0x21, 0, 0, options.interlaced and 0x9e or 0x1e))
  put(72, "\0\0\0\252\0FixturePanel\n")
  put(90, "\0\0\0\255\0PRIVATE-SN\n  ")
  put(108, "\0\0\0\254\0PRIVATE-TEXT\n")
  for offset, value in pairs(options.bytes or {}) do b[offset + 1] = value end
  b[127] = options.extensions or 0
  local sum = 0
  for i = 1, 127 do sum = sum + b[i] end
  b[128] = (-sum) % 256
  return string.char(table.unpack(b)) .. (options.tail or "")
end

function M.tree(options)
  options = options or {}
  local base = "/sys/class/drm"
  local files, links = {}, { [base .. "/card1/device"] = "../../../0000:00:02.0" }
  local entries = { "card1", "renderD128", "version" }
  for _, port in ipairs({ "eDP-1", "HDMI-A-1", "DP-1" }) do
    local name = "card1-" .. port
    entries[#entries + 1] = name
    local path = base .. "/" .. name
    links[path] = "../../devices/pci0000:00/0000:00:02.0/drm/card1/" .. name
    files[path .. "/status"] = port == "eDP-1" and "connected\n" or "disconnected\n"
    files[path .. "/connector_id"] = port == "eDP-1" and "95\n" or port == "DP-1" and "100\n" or "101\n"
    files[path .. "/enabled"] = port == "eDP-1" and "enabled\n" or "disabled\n"
    files[path .. "/dpms"] = port == "eDP-1" and "On\n" or "Off\n"
    files[path .. "/modes"] = port == "eDP-1" and "1920x1080\n1280x720\n1920x1080\n" or ""
    files[path .. "/edid"] = port == "eDP-1" and M.edid(options) or ""
  end
  return { files = files, dirs = { [base] = entries }, links = links }
end

return M
