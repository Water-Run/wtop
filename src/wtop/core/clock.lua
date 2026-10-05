-- Monotonic and wall-clock helpers.
--
-- PUC Lua does not expose clock_gettime.  On Linux, /proc/uptime is a cheap
-- monotonic source.  The injectable reader keeps this module deterministic in
-- tests and lets a future native backend replace it without changing callers.

local Clock = {}
Clock.__index = Clock

local NANOSECONDS = 1000000000

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function decimal_seconds_to_ns(value)
  if type(value) == "number" then
    if not finite_number(value) then
      return nil, "invalid_time"
    end
    if value < 0 then
      return nil, "negative_time"
    end
    if value > math.maxinteger / 1e9 then
      return nil, "time_out_of_range"
    end
    local nanoseconds = math.floor(value * 1e9 + 0.5)
    if not finite_number(nanoseconds) or nanoseconds > math.maxinteger then
      return nil, "time_out_of_range"
    end
    return nanoseconds
  end
  if type(value) ~= "string" then
    return nil, "invalid_time"
  end

  local normalized = value:match("^%s*(.-)%s*$")
  local integer, fraction = normalized:match("^(%d+)%.(%d*)$")
  if not integer then
    integer = normalized:match("^(%d+)$")
    fraction = ""
  end
  if not integer then
    return nil, "invalid_time"
  end
  local significant = integer:gsub("^0+", "")
  if significant == "" then significant = "0" end
  local maximum_seconds = math.maxinteger // NANOSECONDS
  local maximum_text = tostring(maximum_seconds)
  if #significant > #maximum_text
    or (#significant == #maximum_text and significant > maximum_text)
  then
    return nil, "time_out_of_range"
  end
  fraction = (fraction .. "000000000"):sub(1, 9)
  local seconds = tonumber(significant)
  local nanos = tonumber(fraction) or 0
  if not seconds or (seconds == maximum_seconds
      and nanos > math.maxinteger % NANOSECONDS) then
    return nil, "time_out_of_range"
  end
  return seconds * NANOSECONDS + nanos
end

local function default_read(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local content = file:read(128)
  file:close()
  return content
end

function Clock.new(options)
  options = options or {}
  if type(options) ~= "table" then error("clock options must be a table", 2) end
  if options.read_file ~= nil and type(options.read_file) ~= "function" then
    error("clock read_file must be a function", 2)
  end
  if options.fallback ~= nil and type(options.fallback) ~= "function" then
    error("clock fallback must be a function", 2)
  end
  if options.wall ~= nil and type(options.wall) ~= "function" then
    error("clock wall must be a function", 2)
  end
  if options.uptime_path ~= nil and (type(options.uptime_path) ~= "string"
      or options.uptime_path == "" or #options.uptime_path > 4096
      or options.uptime_path:find("\0", 1, true)) then
    error("invalid uptime path", 2)
  end
  return setmetatable({
    read_file = options.read_file or default_read,
    uptime_path = options.uptime_path or "/proc/uptime",
    fallback = options.fallback or os.clock,
    wall = options.wall or os.time,
    last_ns = nil,
    source = nil,
  }, Clock)
end

function Clock:now_ns()
  local read_ok, content = pcall(self.read_file, self.uptime_path)
  if not read_ok then content = nil end
  if content then
    local value = content:match("^%s*([^%s]+)")
    local now = decimal_seconds_to_ns(value)
    if now then
      -- A monotonic clock must never go backwards, including when a test or a
      -- broken proc mount supplies an older value.
      if self.last_ns and now < self.last_ns then
        now = self.last_ns
        -- Named for what it is.  The value is the previous reading, not a new
        -- one, so `procfs_uptime` would be reporting a measurement that was
        -- rejected a line earlier.
        self.source = "held"
      else
        self.source = "procfs_uptime"
      end
      self.last_ns = now
      return now
    end
  end

  local called, fallback_value = pcall(self.fallback)
  local now = called and decimal_seconds_to_ns(fallback_value) or nil
  if now then
    if self.last_ns and now < self.last_ns then
      -- The default fallback is `os.clock`, which is the process's own CPU
      -- time: not a second copy of a monotonic wall clock but a different
      -- quantity on a different scale.  So the moment `/proc/uptime` stops
      -- answering, the candidate is always older than the reading being held,
      -- the clamp below rejects it, and **the clock stops advancing for as long
      -- as the read keeps failing** -- measured, a single failed read after a
      -- two-year uptime freezes every rate derived from `now_ns()` at that
      -- value.  Holding is the safe answer, and it is the answer this keeps
      -- giving.  What was not safe was calling it `process_clock_fallback`,
      -- because nothing came from the process clock at all: the label said the
      -- value had been re-derived while the value was the one already in hand.
      now = self.last_ns
      self.source = "held"
    else
      self.source = "process_clock_fallback"
    end
  elseif self.last_ns then
    now = self.last_ns
    self.source = "held"
  else
    -- Nothing has ever been measured and nothing could be measured.  0 is a
    -- placeholder the caller can see through, and `unavailable` is the word
    -- this project already uses for an optional reading it could not take.
    now = 0
    self.source = "unavailable"
  end
  self.last_ns = now
  return now
end

function Clock:wall_ns()
  local called, value = pcall(self.wall)
  local now = called and decimal_seconds_to_ns(value) or nil
  return now or 0
end

function Clock:source_name()
  return self.source
end

Clock.decimal_seconds_to_ns = decimal_seconds_to_ns

Clock.default = Clock.new()

function Clock.default_now_ns()
  return Clock.default:now_ns()
end

function Clock.default_wall_ns()
  return Clock.default:wall_ns()
end

return Clock
