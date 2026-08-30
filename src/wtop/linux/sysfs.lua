local Sysfs = {}

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

function Sysfs.key_values(content)
  local result = {}
  if type(content) ~= "string" then
    return result, "content_required"
  end
  if #content > 1024 * 1024 then return result, "content_too_large" end
  local lines = 0
  for line in content:gmatch("[^\n]+") do
    lines = lines + 1
    if lines > 16384 or #line > 65536 then return result, "content_limit_exceeded" end
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key then
      if result[key] ~= nil then return result, "duplicate_key_" .. key end
      result[key] = value
    elseif line ~= "" then
      return result, "invalid_key_value_line"
    end
  end
  return result
end

function Sysfs.basename(path)
  if type(path) ~= "string" then
    return nil
  end
  path = path:gsub("/+$", "")
  local name = path:match("([^/]+)$")
  return name and name ~= "." and name ~= ".." and name or nil
end

function Sysfs.pci_bdf(path)
  if type(path) ~= "string" then
    return nil
  end
  return path:match("(%x%x%x%x:%x%x:%x%x%.%x)$")
end

function Sysfs.hex_id(value)
  if type(value) ~= "string" then
    return nil
  end
  local hex = value:match("^%s*0[xX]([%da-fA-F]+)%s*$")
    or value:match("^%s*([%da-fA-F]+)%s*$")
  local number = hex and tonumber(hex, 16) or nil
  return finite_number(number) and number >= 0 and math.type(number) == "integer" and number or nil
end

function Sysfs.vendor_name(vendor_id)
  local vendors = {
    [0x10de] = "nvidia",
    [0x1002] = "amd",
    [0x8086] = "intel",
  }
  return vendors[vendor_id] or "unknown"
end

function Sysfs.millidegrees_to_celsius(value)
  return finite_number(value) and value / 1000 or nil
end

function Sysfs.microwatts_to_watts(value)
  return finite_number(value) and value / 1000000 or nil
end

return Sysfs
