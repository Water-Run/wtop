local Clock = require("wtop.core.clock")
local FS = require("wtop.linux.fs")

local Common = {}

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

function Common.positive_integer(name, value, default, maximum)
  if value == nil then return default end
  maximum = maximum or 2147483647
  if not finite_number(value) or value % 1 ~= 0 or value < 1 or value > maximum then
    error(name .. " must be an integer in 1.." .. maximum, 3)
  end
  return value
end

function Common.absolute_path(name, value, default)
  value = value == nil and default or value
  if type(value) ~= "string" or #value < 1 or #value > 4096
      or value:sub(1, 1) ~= "/" or value:find("\0", 1, true) then
    error(name .. " must be an absolute NUL-free path", 3)
  end
  return value
end

function Common.elapsed_ns(current, previous)
  if not finite_number(current) or not finite_number(previous) or current < previous then
    return nil
  end
  local elapsed = (current + 0.0) - previous
  return finite_number(elapsed) and elapsed or nil
end

function Common.safe_text(value, maximum)
  if type(value) ~= "string" then return nil end
  maximum = maximum or 4096
  if type(maximum) ~= "number" or maximum % 1 ~= 0 or maximum < 1 or maximum > 1048576 then
    error("invalid text limit", 2)
  end
  value = value:gsub("[%z\1-\31\127]", "�")
  if #value > maximum then value = value:sub(1, maximum) end
  if not utf8.len(value) then
    local output, index = {}, 1
    while index <= #value do
      local byte = value:byte(index)
      local length = byte < 0x80 and 1
        or byte >= 0xc2 and byte <= 0xdf and 2
        or byte >= 0xe0 and byte <= 0xef and 3
        or byte >= 0xf0 and byte <= 0xf4 and 4 or nil
      local candidate = length and value:sub(index, index + length - 1) or nil
      if candidate and #candidate == length and utf8.len(candidate) == 1 then
        output[#output + 1] = candidate
        index = index + length
      else
        output[#output + 1] = "�"
        index = index + 1
      end
    end
    value = table.concat(output)
  end
  return value
end

function Common.safe_add(...)
  local total = 0.0
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if not finite_number(value) then return nil end
    total = total + value
    if not finite_number(total) then return nil end
  end
  return total
end

function Common.fs(context, fallback)
  if context ~= nil and type(context) ~= "table" then
    error("collector context must be a table", 2)
  end
  if context and context.fs then
    return context.fs
  end
  return fallback or FS.default
end

function Common.now_ns(context, fallback)
  if context ~= nil and type(context) ~= "table" then
    error("collector context must be a table", 2)
  end
  local value
  if context then
    if type(context.now_ns) == "function" then
      value = context.now_ns()
    elseif context.clock then
      if type(context.clock) == "function" then
        value = context.clock()
      elseif type(context.clock) == "table" and type(context.clock.now_ns) == "function" then
        value = context.clock:now_ns()
      else
        error("collector clock must provide now_ns", 2)
      end
    end
  end
  if value == nil then
    local clock = fallback or Clock.default
    if type(clock) ~= "table" or type(clock.now_ns) ~= "function" then
      error("collector clock must provide now_ns", 2)
    end
    value = clock:now_ns()
  end
  if not finite_number(value) or value < 0 or value > math.maxinteger then
    error("collector clock returned an invalid timestamp", 2)
  end
  return value
end

function Common.result(status, timestamp_ns, data, options)
  options = options or {}
  if type(options) ~= "table" then error("collector result options must be a table", 2) end
  return {
    status = status,
    timestamp_ns = timestamp_ns,
    duration_ns = options.duration_ns or 0,
    data = data,
    quality = options.quality or (status == "ok" and "fresh" or status),
    reason = options.reason,
    retry_after_ms = options.retry_after_ms,
    source = options.source,
    error = options.error,
  }
end

function Common.error_result(fs_error, timestamp_ns, source)
  local status = FS.error_status(fs_error)
  return Common.result(status, timestamp_ns, nil, {
    quality = status,
    reason = fs_error and fs_error.message or "read_failed",
    source = source,
    error = fs_error,
  })
end

function Common.delta(current, previous)
  if not finite_number(current) or not finite_number(previous) then
    return nil, "missing"
  end
  if current < previous then
    return nil, "reset"
  end
  return current - previous
end

function Common.rate(current, previous, elapsed_ns)
  if not finite_number(elapsed_ns) or elapsed_ns <= 0 then
    return nil, "invalid_interval"
  end
  local delta, reason = Common.delta(current, previous)
  if not delta then
    return nil, reason
  end
  local rate = (delta + 0.0) * 1e9 / elapsed_ns
  if not finite_number(rate) then return nil, "out_of_range" end
  return rate
end

function Common.previous_data(previous)
  if type(previous) == "table" and previous.status == "ok" then
    return previous.data
  end
  return nil
end

function Common.trim(value)
  if type(value) ~= "string" then
    return value
  end
  return value:match("^%s*(.-)%s*$")
end

function Common.map_by_id(values)
  local map = {}
  if values ~= nil and type(values) ~= "table" then return map end
  for _, value in ipairs(values or {}) do
    if type(value) == "table" and value.id ~= nil then
      map[value.id] = value
    end
  end
  return map
end

return Common
