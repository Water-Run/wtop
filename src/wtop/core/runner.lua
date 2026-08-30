-- Safe abstraction for optional external providers.
--
-- There is deliberately no shell-based default executor. Production injects
-- the native argv executor; tests can inject a deterministic function.

local Runner = {}
Runner.__index = Runner

local MAX_TIMEOUT_MS = 60000
local MAX_OUTPUT_BYTES = 16 * 1024 * 1024

local VALID_STATUS = {
  ok = true,
  unavailable = true,
  denied = true,
  timeout = true,
  cancelled = true,
  error = true,
}

local function bounded_positive_integer(value, maximum)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
    and value >= 1 and value <= maximum and value % 1 == 0
end

local function valid_locale(value)
  return type(value) == "string" and #value <= 4096
    and not value:find("\0", 1, true)
end

local function validate_argv(argv)
  if type(argv) ~= "table" or #argv == 0 then
    return nil, "argv_required"
  end
  if type(argv[1]) ~= "string" or argv[1]:sub(1, 1) ~= "/" then
    return nil, "executable_must_be_absolute"
  end
  for index, value in ipairs(argv) do
    if type(value) ~= "string" then
      return nil, "argv_" .. index .. "_must_be_string"
    end
    if value:find("\0", 1, true) then
      return nil, "argv_" .. index .. "_contains_nul"
    end
  end
  return true
end

function Runner.new(options)
  options = options or {}
  if type(options) ~= "table" then error("runner options must be a table", 2) end
  local timeout_ms = options.default_timeout_ms or 500
  local max_output_bytes = options.default_max_output_bytes or (1024 * 1024)
  local locale = options.default_locale or "C"
  if not bounded_positive_integer(timeout_ms, MAX_TIMEOUT_MS)
      or not bounded_positive_integer(max_output_bytes, MAX_OUTPUT_BYTES) then
    error("invalid default runner policy", 2)
  end
  if not valid_locale(locale) then error("invalid default runner locale", 2) end
  if options.execute ~= nil and options.execute ~= false and type(options.execute) ~= "function" then
    error("runner execute must be a function, false, or nil", 2)
  end
  return setmetatable({
    execute = options.execute,
    default_timeout_ms = timeout_ms,
    default_max_output_bytes = max_output_bytes,
    default_locale = locale,
  }, Runner)
end

function Runner:run(argv, options)
  local valid, validation_error = validate_argv(argv)
  if not valid then
    return {
      status = "error",
      reason = validation_error,
      argv = argv,
    }
  end
  if type(self.execute) ~= "function" then
    return {
      status = "unavailable",
      reason = "argv_executor_unavailable",
      argv = argv,
    }
  end

  options = options or {}
  if type(options) ~= "table" then
    return { status = "error", reason = "invalid_runner_options", argv = argv }
  end
  local policy = {
    timeout_ms = options.timeout_ms or self.default_timeout_ms,
    max_output_bytes = options.max_output_bytes or self.default_max_output_bytes,
    env = options.env or {
      LANG = self.default_locale,
      LC_ALL = self.default_locale,
    },
    cancel = options.cancel,
  }
  if not bounded_positive_integer(policy.timeout_ms, MAX_TIMEOUT_MS)
    or not bounded_positive_integer(policy.max_output_bytes, MAX_OUTPUT_BYTES)
    or type(policy.env) ~= "table"
    or (policy.cancel ~= nil and type(policy.cancel) ~= "function")
  then
    return { status = "error", reason = "invalid_runner_policy", argv = argv }
  end
  for _, key in ipairs({ "LANG", "LC_ALL" }) do
    if policy.env[key] ~= nil and not valid_locale(policy.env[key]) then
      return { status = "error", reason = "invalid_runner_policy", argv = argv }
    end
  end

  local ok, raw = pcall(self.execute, argv, policy)
  if not ok then
    return { status = "error", reason = "executor_exception", error = tostring(raw), argv = argv }
  end
  if type(raw) ~= "table" then
    return { status = "error", reason = "invalid_executor_result", argv = argv }
  end

  local stdout = type(raw.stdout) == "string" and raw.stdout or ""
  local stderr = type(raw.stderr) == "string" and raw.stderr or ""
  local truncated = false
  if #stdout > policy.max_output_bytes then
    stdout = stdout:sub(1, policy.max_output_bytes)
    truncated = true
  end
  if #stderr > policy.max_output_bytes then
    stderr = stderr:sub(1, policy.max_output_bytes)
    truncated = true
  end
  if #stdout + #stderr > policy.max_output_bytes then
    local remaining = math.max(0, policy.max_output_bytes - #stdout)
    stderr = stderr:sub(1, remaining)
    truncated = true
  end

  local status = raw.status
  local reason = raw.reason
  if not VALID_STATUS[status] then
    status = raw.timed_out == true and "timeout" or "error"
    reason = reason or (status == "timeout" and "timeout" or "invalid_executor_status")
  end
  return {
    status = status,
    reason = reason,
    exit_code = raw.exit_code,
    signal = raw.signal,
    stdout = stdout,
    stderr = stderr,
    truncated = truncated or raw.truncated == true,
    duration_ns = raw.duration_ns,
    argv = argv,
  }
end

Runner.validate_argv = validate_argv
Runner.MAX_TIMEOUT_MS = MAX_TIMEOUT_MS
Runner.MAX_OUTPUT_BYTES = MAX_OUTPUT_BYTES

return Runner
