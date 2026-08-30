local Clock = require("wtop.core.clock")

local Scheduler = {}
Scheduler.__index = Scheduler

local VALID_STATUS = {
  ok = true,
  unavailable = true,
  denied = true,
  error = true,
}

local VALID_QUALITY = {
  fresh = true,
  stale = true,
  gap = true,
  estimated = true,
  unavailable = true,
  denied = true,
  error = true,
  partial = true,
  reset = true,
  measured = true,
}

local MAX_INTERVAL_MS = 2147483647

local function elapsed_ns(started_ns, finished_ns)
  if finished_ns < started_ns then return 0 end
  local elapsed = (finished_ns + 0.0) - started_ns
  return elapsed == elapsed and elapsed < math.huge and elapsed or 0
end

local function deadline_ns(now_ns, interval_ms)
  local delta = interval_ms * 1000000
  if now_ns >= math.maxinteger - delta then return math.maxinteger end
  return now_ns + delta
end

local function valid_interval(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
    and value >= 1 and value <= MAX_INTERVAL_MS and value % 1 == 0
end

local function call_now(clock)
  local value
  if type(clock) == "function" then
    value = clock()
  elseif type(clock) == "table" and type(clock.now_ns) == "function" then
    value = clock:now_ns()
  else
    error("scheduler clock must provide now_ns", 3)
  end
  if type(value) ~= "number" or value ~= value
      or value == math.huge or value == -math.huge or value < 0 or value > math.maxinteger then
    error("scheduler clock returned an invalid timestamp", 3)
  end
  return value
end

local function normalize_result(raw, started_ns, finished_ns)
  if type(raw) ~= "table" then
    return {
      status = "error",
      quality = "error",
      reason = "collector_returned_invalid_result",
      timestamp_ns = finished_ns,
      duration_ns = elapsed_ns(started_ns, finished_ns),
    }
  end
  local result = {}
  for key, value in pairs(raw) do result[key] = value end
  if not VALID_STATUS[result.status] then
    result.status = "error"
    result.quality = "error"
    result.reason = result.reason or "collector_returned_invalid_status"
  end
  if not VALID_QUALITY[result.quality] then
    if result.status == "ok" then
      result.quality = "fresh"
    else
      result.quality = result.status
    end
  end
  if result.status ~= "ok" and (result.quality == "fresh" or result.quality == "measured") then
    result.quality = result.status
  end
  if type(result.timestamp_ns) ~= "number" or result.timestamp_ns ~= result.timestamp_ns
      or result.timestamp_ns == math.huge or result.timestamp_ns == -math.huge
      or result.timestamp_ns < 0 then
    result.timestamp_ns = finished_ns
  end
  if type(result.duration_ns) ~= "number" or result.duration_ns ~= result.duration_ns
      or result.duration_ns == math.huge or result.duration_ns == -math.huge
      or result.duration_ns < 0 then
    result.duration_ns = elapsed_ns(started_ns, finished_ns)
  end
  return result
end

function Scheduler.new(options)
  options = options or {}
  if type(options) ~= "table" then error("scheduler options must be a table", 2) end
  local max_backoff_ms = options.max_backoff_ms or 30000
  if not valid_interval(max_backoff_ms) then
    error("max_backoff_ms must be a positive integer no greater than " .. MAX_INTERVAL_MS, 2)
  end
  if options.context ~= nil and type(options.context) ~= "table" then
    error("scheduler context must be a table", 2)
  end
  return setmetatable({
    clock = options.clock or Clock.default,
    context = options.context or {},
    max_backoff_ms = max_backoff_ms,
    tasks = {},
    order = {},
    stopped = false,
  }, Scheduler)
end

function Scheduler:add(collector, options)
  options = options or {}
  if type(options) ~= "table" then return nil, "options_must_be_table" end
  if self.stopped then return nil, "scheduler_stopped" end
  if type(collector) ~= "table" or type(collector.id) ~= "string"
      or collector.id == "" or #collector.id > 256 or collector.id:find("\0", 1, true) then
    return nil, "collector_id_required"
  end
  if type(collector.sample) ~= "function" then
    return nil, "collector_sample_required"
  end
  if self.tasks[collector.id] then
    return nil, "collector_already_registered"
  end
  local interval_ms = options.interval_ms or collector.default_interval_ms or 1000
  if not valid_interval(interval_ms) then
    return nil, "interval_must_be_positive"
  end
  if options.background_interval_ms ~= nil and not valid_interval(options.background_interval_ms) then
    return nil, "background_interval_must_be_positive"
  end
  local now = call_now(self.clock)
  local task = {
    collector = collector,
    interval_ms = interval_ms,
    background_interval_ms = options.background_interval_ms,
    enabled = options.enabled ~= false,
    visible = options.visible ~= false,
    next_due_ns = options.immediate == false and deadline_ns(now, interval_ms) or now,
    failures = 0,
    last_result = nil,
    last_success = nil,
    runs = 0,
  }
  self.tasks[collector.id] = task
  self.order[#self.order + 1] = collector.id
  return task
end

function Scheduler:remove(id)
  if not self.tasks[id] then
    return false
  end
  self.tasks[id] = nil
  for index, value in ipairs(self.order) do
    if value == id then
      table.remove(self.order, index)
      break
    end
  end
  return true
end

function Scheduler:set_enabled(id, enabled)
  local task = self.tasks[id]
  if not task then
    return nil, "collector_not_found"
  end
  task.enabled = enabled == true
  if task.enabled then
    task.next_due_ns = call_now(self.clock)
  end
  return true
end

function Scheduler:set_visible(id, visible)
  local task = self.tasks[id]
  if not task then
    return nil, "collector_not_found"
  end
  local was_visible = task.visible
  task.visible = visible == true
  local now = call_now(self.clock)
  -- A collector that becomes relevant to the current view should refresh on
  -- the next tick instead of waiting for a possibly long background period.
  if task.visible and not was_visible then
    task.next_due_ns = now
  elseif not task.visible and was_visible and task.background_interval_ms then
    -- Apply the background cadence at the visibility edge, including startup,
    -- rather than paying one more foreground-period run after leaving a page.
    -- Never shorten a later failure/backoff deadline.
    local background_due = deadline_ns(now, task.background_interval_ms)
    task.next_due_ns = math.max(task.next_due_ns, background_due)
  end
  return true
end

function Scheduler:set_interval(id, interval_ms)
  local task = self.tasks[id]
  if not task then
    return nil, "collector_not_found"
  end
  if not valid_interval(interval_ms) then
    return nil, "interval_must_be_positive"
  end
  task.interval_ms = interval_ms
  task.next_due_ns = deadline_ns(call_now(self.clock), interval_ms)
  return true
end

function Scheduler:set_background_interval(id, interval_ms)
  local task = self.tasks[id]
  if not task then
    return nil, "collector_not_found"
  end
  if interval_ms ~= nil and not valid_interval(interval_ms) then
    return nil, "interval_must_be_positive"
  end
  task.background_interval_ms = interval_ms
  if not task.visible then
    task.next_due_ns = deadline_ns(call_now(self.clock), interval_ms or task.interval_ms)
  end
  return true
end

function Scheduler:probe_all(context)
  local capabilities = {}
  context = context or self.context
  for _, id in ipairs(self.order) do
    local collector = self.tasks[id].collector
    if type(collector.probe) == "function" then
      local ok, result
      if collector._method_style then
        ok, result = pcall(collector.probe, collector, context)
      else
        ok, result = pcall(collector.probe, context)
      end
      if not ok then
        capabilities[id] = { state = "error", available = false, reason = tostring(result) }
      elseif type(result) ~= "table"
          or not ({ available = true, unavailable = true, denied = true,
            degraded = true, error = true })[result.state]
          or type(result.available) ~= "boolean" then
        capabilities[id] = { state = "error", available = false,
          reason = "invalid_probe_result" }
      else
        capabilities[id] = result
      end
    else
      capabilities[id] = { state = "available", available = true }
    end
  end
  return capabilities
end

function Scheduler:tick(context)
  if self.stopped then
    return {}
  end
  context = context or self.context
  local now = call_now(self.clock)
  local completed = {}

  for _, id in ipairs(self.order) do
    local task = self.tasks[id]
    if task and task.enabled and now >= task.next_due_ns then
      local started = call_now(self.clock)
      local ok, raw
      if task.collector._method_style then
        ok, raw = pcall(task.collector.sample, task.collector, context, task.last_result)
      else
        ok, raw = pcall(task.collector.sample, context, task.last_result)
      end
      local finished = call_now(self.clock)
      if not ok then
        raw = {
          status = "error",
          quality = "error",
          reason = "collector_exception",
          error = tostring(raw),
        }
      end
      local result = normalize_result(raw, started, finished)
      task.last_result = result
      task.runs = task.runs + 1

      local interval_ms = task.interval_ms
      if not task.visible and task.background_interval_ms then
        interval_ms = task.background_interval_ms
      end
      if result.status == "ok" then
        task.failures = 0
        task.last_success = result
      else
        task.failures = math.min(task.failures + 1, 1000000)
        local exponential = interval_ms * (2 ^ math.min(task.failures - 1, 10))
        if valid_interval(result.retry_after_ms) then
          interval_ms = math.min(result.retry_after_ms, self.max_backoff_ms)
        else
          interval_ms = math.min(exponential, self.max_backoff_ms)
        end
      end
      task.next_due_ns = deadline_ns(finished, interval_ms)
      completed[id] = result
    end
  end
  return completed
end

function Scheduler:next_delay_ms()
  if self.stopped then
    return nil
  end
  local now = call_now(self.clock)
  local minimum
  for _, id in ipairs(self.order) do
    local task = self.tasks[id]
    if task and task.enabled then
      local delay = task.next_due_ns > now and (task.next_due_ns + 0.0) - now or 0
      if not minimum or delay < minimum then
        minimum = delay
      end
    end
  end
  if minimum == nil then
    return nil
  end
  return math.floor((minimum + 999999) / 1000000)
end

function Scheduler:stop(context)
  if self.stopped then
    return
  end
  self.stopped = true
  context = context or self.context
  for _, id in ipairs(self.order) do
    local collector = self.tasks[id].collector
    if type(collector.close) == "function" then
      if collector._method_style then
        pcall(collector.close, collector, context)
      else
        pcall(collector.close, context)
      end
    end
  end
end

function Scheduler:task(id)
  return self.tasks[id]
end

Scheduler.normalize_result = normalize_result
Scheduler.MAX_INTERVAL_MS = MAX_INTERVAL_MS

return Scheduler
