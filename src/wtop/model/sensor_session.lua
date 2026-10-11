-- Per-process sensor extrema from direct observations. This model neither
-- probes hardware nor turns a driver's own historical values into ours.
local M = {}

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function unique_devices(devices)
  local result = {}
  for _, device in ipairs(type(devices) == "table" and devices or {}) do
    if type(device) == "table" and type(device.id) == "string" then
      if result[device.id] == nil then result[device.id] = device
      else result[device.id] = false end
    end
  end
  return result
end

local function unique_channels(channels)
  local result = {}
  for _, channel in ipairs(type(channels) == "table" and channels or {}) do
    if type(channel) == "table" and type(channel.id) == "string" then
      if result[channel.id] == nil then result[channel.id] = channel
      else result[channel.id] = false end
    end
  end
  return result
end

local function label_counts(channels)
  local counts = {}
  for _, channel in ipairs(type(channels) == "table" and channels or {}) do
    if type(channel) == "table" and type(channel.type) == "string"
        and type(channel.label) == "string" and channel.label ~= "" then
      local key = channel.type .. "\0" .. channel.label
      counts[key] = (counts[key] or 0) + 1
    end
  end
  return counts
end

local function previous_session(unique_current, device, old_device, channel, old, now, kind)
  if unique_current ~= device or type(old_device) ~= "table"
      or device.identity_quality ~= "fresh"
      or old_device.identity_quality ~= "fresh"
      or old_device.id ~= device.id then return nil end
  if kind == "native" and (device.name ~= old_device.name
      or device.class ~= old_device.class
      or device.source ~= old_device.source
      or type(channel.label) ~= "string" or channel.label == "") then return nil end
  if type(old) ~= "table" or old.id ~= channel.id
      or old.type ~= channel.type or old.unit ~= channel.unit
      or old.label ~= channel.label then return nil end
  local session = old.session
  if type(session) ~= "table" or type(session.samples) ~= "number"
      or math.type(session.samples) ~= "integer" or session.samples <= 0
      or session.samples >= math.maxinteger
      or not finite(session.minimum) or not finite(session.maximum)
      or not finite(session.average)
      or not finite(session.first_timestamp_ns)
      or not finite(session.last_timestamp_ns)
      or session.minimum > session.maximum
      or session.first_timestamp_ns > session.last_timestamp_ns
      or session.last_timestamp_ns > now then return nil end
  return session
end

local function direct_value(channel, device, kind, allow_direct)
  if channel.type == "energy" then return nil end
  local value
  if kind == "hwmon" then
    value = type(channel.readings) == "table"
      and channel.readings.input or nil
    if channel.input_source ~= nil then return nil end
  else
    if allow_direct == false or device.quality ~= "fresh"
        or channel.quality ~= "fresh"
        or channel.input_source == "average" then
      return nil
    end
    value = channel.input
  end
  return finite(value) and value or nil
end

function M.attach(devices, previous_data, sampled_at, kind, allow_direct)
  if kind ~= "hwmon" and kind ~= "native" then
    error("sensor session source must be hwmon or native", 2)
  end
  if not finite(sampled_at) then return end
  local current = unique_devices(devices)
  local earlier = unique_devices(previous_data and previous_data.devices)
  for _, device in ipairs(type(devices) == "table" and devices or {}) do
    if type(device) == "table" then
      local old_device = earlier[device.id]
      local old_channels = type(old_device) == "table"
        and unique_channels(old_device.channels) or {}
      local current_channels = unique_channels(device.channels)
      local current_labels = kind == "native" and label_counts(device.channels) or nil
      local old_labels = kind == "native" and type(old_device) == "table"
        and label_counts(old_device.channels) or nil
      for _, channel in ipairs(type(device.channels) == "table" and device.channels or {}) do
        if type(channel) == "table" and channel.type ~= "energy" then
          local old = current[device.id] == device
            and current_channels[channel.id] == channel
            and old_channels[channel.id] or nil
          if kind == "native" then
            local key = type(channel.type) == "string"
              and type(channel.label) == "string"
              and channel.type .. "\0" .. channel.label or nil
            if not key or not current_labels or current_labels[key] ~= 1
                or not old_labels or old_labels[key] ~= 1 then old = nil end
          end
          local prior = previous_session(current[device.id], device,
            old_device, channel, old, sampled_at, kind)
          local direct = direct_value(channel, device, kind, allow_direct)
          if direct ~= nil and (not prior or sampled_at > prior.last_timestamp_ns) then
            local samples = prior and prior.samples + 1 or 1
            channel.session = {
              minimum = prior and math.min(prior.minimum, direct) or direct,
              maximum = prior and math.max(prior.maximum, direct) or direct,
              average = prior and prior.average
                + (direct - prior.average) / samples or direct,
              samples = samples,
              first_timestamp_ns = prior and prior.first_timestamp_ns or sampled_at,
              last_timestamp_ns = sampled_at,
            }
          elseif prior then
            channel.session = {
              minimum = prior.minimum, maximum = prior.maximum,
              average = prior.average, samples = prior.samples,
              first_timestamp_ns = prior.first_timestamp_ns,
              last_timestamp_ns = prior.last_timestamp_ns,
            }
          end
        end
      end
    end
  end
end

return M
