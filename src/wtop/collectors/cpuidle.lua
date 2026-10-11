local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")

local CPUIdle = {}
CPUIdle.__index = CPUIdle

local MAX_COUNTER = 9007199254740991
local OPTIONAL_COUNTERS = { "rejected", "above", "below" }

local function entries(fs, path, pattern, maximum, limit)
  local names, err, cut = fs:list(path, limit)
  if not names then return nil, err end
  local found, seen = {}, {}
  for _, name in ipairs(names) do
    local token = type(name) == "string" and name:match(pattern)
    local id = token and tonumber(token)
    if id and id <= 8191 and name:match("%d+$") == tostring(id) and not seen[id] then
      found[#found + 1] = id
      seen[id] = true
    end
  end
  table.sort(found)
  return found, nil, cut == true or #found > maximum
end

local function optional_text(fs, path, issues, field)
  local content, err = fs:read(path, 128)
  if not content then
    if err and err.kind ~= "missing" and err.kind ~= "unavailable" then
      issues[#issues + 1] = { field = field, source = path,
        status = FS.error_status(err), reason = err.message }
    end
    return nil
  end
  local value = Common.trim(content)
  if value and value ~= "" then return Common.safe_text(value, 128) end
  issues[#issues + 1] = { field = field, source = path,
    status = "error", reason = "empty_cpuidle_text" }
end

local function integer(fs, path, issues, field, optional)
  local content, err = fs:read(path, 64)
  if content then
    local token = Common.trim(content)
    local value = token and token:match("^%d+$") and tonumber(token)
    if value and value <= MAX_COUNTER and math.type(value) == "integer" then return value end
    err = { kind = "parse_error", message = "invalid_cpuidle_counter" }
  elseif optional and err and (err.kind == "missing" or err.kind == "unavailable") then
    return nil
  end
  issues[#issues + 1] = { field = field, source = path,
    status = FS.error_status(err), reason = err and err.message or "read_failed" }
end

local function difference(current, previous)
  if current == nil or previous == nil then return nil, "gap" end
  if current < previous then return nil, "reset" end
  return current - previous, "fresh"
end

local function most_severe(issues)
  local status = "unavailable"
  for _, issue in ipairs(issues) do
    if issue.status == "error" then return "error" end
    if issue.status == "denied" then status = "denied" end
  end
  return status
end

function CPUIdle.new(options)
  options = options or {}
  if type(options) ~= "table" then error("cpuidle options must be a table", 2) end
  return setmetatable({ id = "cpuidle", _method_style = true,
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/devices/system/cpu"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 5000),
    max_cpus = Common.positive_integer("max_cpus", options.max_cpus, 256, 8192),
    max_states = Common.positive_integer("max_states", options.max_states, 16, 1024),
    previous = {},
  }, CPUIdle)
end

function CPUIdle:probe(context)
  local fs = Common.fs(context, self.fs)
  local cpus, err = entries(fs, self.base_path, "^cpu(%d+)$", self.max_cpus,
    math.max(4096, self.max_cpus + 1))
  if not cpus then
    if FS.error_status(err) == "denied" then
      return Capability.denied(err.message, { source = self.base_path })
    end
    return Capability.unavailable("no_cpuidle_states", { source = self.base_path })
  end
  local denied
  for index = 1, math.min(#cpus, self.max_cpus) do
    local id = cpus[index]
    local path = self.base_path .. "/cpu" .. id .. "/cpuidle"
    local states, state_err = entries(fs, path, "^state(%d+)$", self.max_states, 1024)
    if states and #states > 0 then
      return Capability.available({ source = self.base_path })
    end
    if FS.error_status(state_err) == "denied" then denied = state_err end
  end
  if denied then return Capability.denied(denied.message, { source = self.base_path }) end
  return Capability.unavailable("no_cpuidle_states", { source = self.base_path })
end

function CPUIdle:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local cpus, err, truncated = entries(fs, self.base_path, "^cpu(%d+)$", self.max_cpus,
    math.max(4096, self.max_cpus + 1))
  if not cpus then
    self.previous = {}
    return Common.error_result(err, Common.now_ns(context), self.base_path)
  end
  local data = { cpus = {}, issues = {}, truncated = truncated, source = self.base_path,
    driver = nil, governor = nil }
  data.driver = optional_text(fs, self.base_path .. "/cpuidle/current_driver", data.issues, "driver")
  data.governor = optional_text(fs, self.base_path .. "/cpuidle/current_governor_ro",
    data.issues, "governor")
  if data.governor == nil then
    data.governor = optional_text(fs, self.base_path .. "/cpuidle/current_governor",
      data.issues, "governor")
  end
  local next_previous, any_counter = {}, false
  for index = 1, math.min(#cpus, self.max_cpus) do
    local id = cpus[index]
    local path = self.base_path .. "/cpu" .. id .. "/cpuidle"
    local states, state_err, cut = entries(fs, path, "^state(%d+)$", self.max_states, 1024)
    if states then
      if cut then data.truncated = true end
      local cpu = { id = id, states = {}, source = path, issues = {} }
      next_previous[id] = {}
      for state_index = 1, math.min(#states, self.max_states) do
        local state_id = states[state_index]
        local state_path = path .. "/state" .. state_id
        local state = { id = state_id, source = state_path, issues = {} }
        state.name = optional_text(fs, state_path .. "/name", state.issues, "name")
        state.usage = integer(fs, state_path .. "/usage", state.issues, "usage")
        state.time_us = integer(fs, state_path .. "/time", state.issues, "time_us")
        state.exit_latency_us = integer(fs, state_path .. "/latency", state.issues,
          "exit_latency_us", true)
        state.target_residency_us = integer(fs, state_path .. "/residency", state.issues,
          "target_residency_us", true)
        local disabled = integer(fs, state_path .. "/disable", state.issues, "disabled", true)
        if disabled == 0 or disabled == 1 then state.disabled = disabled == 1
        elseif disabled ~= nil then
          state.issues[#state.issues + 1] = { field = "disabled", source = state_path .. "/disable",
            status = "error", reason = "invalid_cpuidle_boolean" }
        end
        local previous = self.previous[id] and self.previous[id][state_id] or nil
        state.usage_delta, state.usage_delta_quality = difference(state.usage,
          previous and previous.usage)
        state.new_time_us, state.time_delta_quality = difference(state.time_us,
          previous and previous.time_us)
        local remembered = { usage = state.usage, time_us = state.time_us }
        for _, field in ipairs(OPTIONAL_COUNTERS) do
          state[field] = integer(fs, state_path .. "/" .. field, state.issues, field, true)
          local delta = field .. "_delta"
          local quality = field .. "_delta_quality"
          if state[field] == nil then
            state[quality] = "unavailable"
          else
            state[delta], state[quality] = difference(state[field], previous and previous[field])
          end
          remembered[field] = state[field]
        end
        next_previous[id][state_id] = remembered
        any_counter = any_counter or state.usage ~= nil or state.time_us ~= nil
        cpu.states[#cpu.states + 1] = state
      end
      if #cpu.states > 0 then data.cpus[#data.cpus + 1] = cpu end
    elseif state_err and state_err.kind ~= "missing" and state_err.kind ~= "unavailable" then
      data.issues[#data.issues + 1] = { field = "cpu" .. id, source = path,
        status = FS.error_status(state_err), reason = state_err.message }
    end
  end
  self.previous = next_previous
  local finished = Common.now_ns(context)
  if not any_counter then
    local issues = {}
    for _, issue in ipairs(data.issues) do issues[#issues + 1] = issue end
    for _, cpu in ipairs(data.cpus) do
      for _, issue in ipairs(cpu.issues) do issues[#issues + 1] = issue end
      for _, state in ipairs(cpu.states) do
        for _, issue in ipairs(state.issues) do issues[#issues + 1] = issue end
      end
    end
    local status = most_severe(issues)
    return Common.result(status, finished, nil, { source = self.base_path,
      quality = status, reason = #issues > 0 and "cpuidle_data_incomplete" or "no_cpuidle_states" })
  end
  local partial = data.truncated or #data.issues > 0
  for _, cpu in ipairs(data.cpus) do
    partial = partial or #cpu.issues > 0
    for _, state in ipairs(cpu.states) do partial = partial or #state.issues > 0 end
  end
  return Common.result("ok", finished, data, { source = self.base_path,
    quality = partial and "partial" or "fresh",
    reason = partial and "cpuidle_data_incomplete" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

return CPUIdle
