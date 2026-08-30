local Capability = {}

local VALID = {
  available = true,
  unavailable = true,
  denied = true,
  degraded = true,
  error = true,
}

function Capability.new(state, options)
  options = options or {}
  if type(options) ~= "table" then error("capability options must be a table", 2) end
  if not VALID[state] then
    error("invalid capability state: " .. tostring(state), 2)
  end
  return {
    state = state,
    available = state == "available" or state == "degraded",
    reason = options.reason,
    source = options.source,
    details = options.details,
    permission = options.permission,
    retry_after_ms = options.retry_after_ms,
  }
end

function Capability.available(options)
  return Capability.new("available", options)
end

function Capability.unavailable(reason, options)
  options = options or {}
  if type(options) ~= "table" then error("capability options must be a table", 2) end
  local copy = {}
  for key, value in pairs(options) do copy[key] = value end
  copy.reason = reason
  return Capability.new("unavailable", copy)
end

function Capability.denied(reason, options)
  options = options or {}
  if type(options) ~= "table" then error("capability options must be a table", 2) end
  local copy = {}
  for key, value in pairs(options) do copy[key] = value end
  copy.reason = reason
  return Capability.new("denied", copy)
end

function Capability.error(reason, options)
  options = options or {}
  if type(options) ~= "table" then error("capability options must be a table", 2) end
  local copy = {}
  for key, value in pairs(options) do copy[key] = value end
  copy.reason = reason
  return Capability.new("error", copy)
end

return Capability
