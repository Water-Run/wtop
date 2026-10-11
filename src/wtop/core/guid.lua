-- Canonical text form shared by SMBIOS Type 45 and Linux UEFI ESRT.
local M = {}

function M.normalize(value)
  if type(value) ~= "string" or #value ~= 36
      or not value:match("^[%x%-]+$")
      or select(2, value:gsub("%-", "")) ~= 4
      or value:sub(9, 9) ~= "-" or value:sub(14, 14) ~= "-"
      or value:sub(19, 19) ~= "-" or value:sub(24, 24) ~= "-" then
    return nil
  end
  return value:lower()
end

return M
