-- Standard hwmon control readback. Settings do not measure rotation or prove
-- that an automatic controller is applying the value in pwmN right now.
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local M = {}
local ATTRIBUTES = { value = true, enable = true, mode = true, freq = true,
  auto_channels_temp = true }
local FIELDS = { value = "raw_value", enable = "enable_code", mode = "output_mode_code",
  freq = "frequency_hz", auto_channels_temp = "temperature_channels_mask" }
local MAXIMUMS = { value = 255, enable = 2147483647, mode = 2147483647,
  freq = 2147483647, auto_channels_temp = 9007199254740991 }

local function read_integer(fs, path, maximum)
  local text, err = fs:read(path, 256)
  if not text then return nil, err end
  local token = Common.trim(text)
  if #text > 256 or not token or not token:match("^%+?%d+$") then
    return nil, { kind = "parse_error", message = "expected_integer" }
  end
  local value = tonumber(token)
  if not value or math.type(value) ~= "integer" or value < 0 or value > maximum then
    return nil, { kind = "parse_error", message = "number_out_of_range" }
  end
  return value
end

function M.read(fs, base, entries, options, context, check_identity)
  local groups, ordered, truncated = {}, {}, false
  for position, filename in ipairs(entries or {}) do
    if position > options.max_entries_per_device then truncated = true; break end
    local number, suffix = filename:match("^pwm([1-9]%d*)(.*)$")
    local index = tonumber(number)
    local attribute = suffix == "" and "value" or suffix and suffix:match("^_(.+)$")
    if index and index <= options.max_channel_index and ATTRIBUTES[attribute] then
      local group = groups[index]
      if not group then group = { index = index, files = {} }; groups[index] = group end
      group.files[attribute] = filename
    end
  end
  for _, group in pairs(groups) do ordered[#ordered + 1] = group end
  table.sort(ordered, function(a, b) return a.index < b.index end)
  local stable_before = #ordered == 0 or not check_identity or check_identity(true)
  local controls = {}
  for index, group in ipairs(ordered) do
    if index > options.max_fan_controls_per_device then truncated = true; break end
    local source_file = group.files.value or group.files.enable or group.files.mode
      or group.files.freq or group.files.auto_channels_temp
    local row = { id = "pwm" .. group.index, index = group.index, errors = {},
      source = base .. "/" .. source_file, read_started_ns = Common.now_ns(context) }
    local present, denied = 0, false
    for attribute, filename in pairs(group.files) do
      local source = base .. "/" .. filename
      local value, err = read_integer(fs, source, MAXIMUMS[attribute])
      if value ~= nil then
        present = present + 1
        row[FIELDS[attribute]] = value
        if attribute == "mode" and value > 1 then
          err = { kind = "parse_error", message = "number_out_of_range" }
        end
      end
      if err and err.kind ~= "missing" and err.kind ~= "unavailable" then
        row.errors[attribute] = { status = FS.error_status(err),
          reason = err.message, source = source }
        denied = denied or row.errors[attribute].status == "denied"
      end
    end
    row.observed_at_ns = Common.now_ns(context)
    row.quality = present > 0 and (next(row.errors) and "partial" or "fresh")
      or denied and "denied" or next(row.errors) and "error" or "unavailable"
    controls[#controls + 1] = row
  end
  local stable_after = #ordered == 0 or not check_identity or check_identity(false)
  if not stable_before or not stable_after then
    for _, row in ipairs(controls) do row.quality = "gap" end
  end
  return controls, truncated
end

return M
