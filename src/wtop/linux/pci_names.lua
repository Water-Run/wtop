-- Bounded lookup of PCI vendor and device names from the system pci.ids
-- database. The file is loaded once per instance and parsed per query with a
-- small cache; a missing database leaves names nil rather than failing.
local M = {}

local DEFAULT_PATHS = {
  "/usr/share/hwdata/pci.ids",
  "/usr/share/misc/pci.ids",
}
local DEFAULT_MAX_BYTES = 4 * 1024 * 1024
local MAX_NAME_BYTES = 128

local function safe_text(value)
  if type(value) ~= "string" then return nil end
  local trimmed = value:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then return nil end
  if #trimmed > MAX_NAME_BYTES then trimmed = trimmed:sub(1, MAX_NAME_BYTES) end
  return trimmed
end

local function parse(content, vendor_id, device_id)
  if type(content) ~= "string" or type(vendor_id) ~= "number" then
    return nil, nil
  end
  local wanted_vendor = string.format("%04x", vendor_id):lower()
  local wanted_device = device_id and string.format("%04x", device_id):lower() or nil
  local vendor_name, device_name
  for line in content:gmatch("[^\r\n]+") do
    local listed_vendor, listed_vendor_name = line:match("^(%x%x%x%x)%s%s+(.+)$")
    if listed_vendor then
      if vendor_name then break end
      if listed_vendor:lower() == wanted_vendor then
        vendor_name = safe_text(listed_vendor_name)
        if not wanted_device then break end
      end
    elseif vendor_name then
      local listed_device, listed_device_name = line:match("^\t(%x%x%x%x)%s%s+(.+)$")
      if listed_device then
        if listed_device:lower() == wanted_device then
          device_name = safe_text(listed_device_name)
          break
        end
      end
    end
  end
  return vendor_name, device_name
end

function M.new(options)
  options = options or {}
  local self = setmetatable({}, { __index = M })
  self.fs = options.fs or require("wtop.linux.fs").default
  self.paths = options.paths or DEFAULT_PATHS
  self.max_bytes = options.max_bytes or DEFAULT_MAX_BYTES
  self._content = nil
  self._cache = {}
  return self
end

function M:names(vendor_id, device_id)
  if type(vendor_id) ~= "number" then return nil, nil end
  local key = string.format("%04x:%s", vendor_id,
    device_id and string.format("%04x", device_id) or "-")
  local cached = self._cache[key]
  if cached then return cached.vendor, cached.device end
  if self._content == nil then
    self._content = false
    for _, path in ipairs(self.paths) do
      local content = self.fs:read(path, self.max_bytes)
      if content then
        self._content = content
        break
      end
    end
  end
  local vendor, device
  if self._content then
    vendor, device = parse(self._content, vendor_id, device_id)
  end
  self._cache[key] = { vendor = vendor, device = device }
  return vendor, device
end

M._parse = parse

return M
