-- OpenSSH evaluates Include/defaults/Match; wtop retains only public fields.
local Common = require("wtop.collectors.common")
local Clock = require("wtop.core.clock")
local Runner = require("wtop.core.runner")
local Platform = require("wtop.platform")

local Config = {}
Config.__index = Config
local MAX_BYTES, MAX_LINES, MAX_LINE, MAX_VALUES = 128 * 1024, 512, 8192, 128
local FIELDS = {
  port = true, addressfamily = true, listenaddress = true, permitrootlogin = true,
  passwordauthentication = true, pubkeyauthentication = true, maxauthtries = true,
  maxsessions = true, allowusers = true, allowgroups = true,
  authenticationmethods = true, loglevel = true,
}
local REPEATED = { port = true, listenaddress = true }
local CONNECTION_KEYS = { "user", "addr", "host", "laddr", "lport", "rdomain" }
local CONNECTION_SET = {}
for _, key in ipairs(CONNECTION_KEYS) do CONNECTION_SET[key] = true end

local function connection_spec(connection)
  if connection == nil then return nil end
  if type(connection) ~= "table" or next(connection) == nil then return nil, false end
  local parts = {}
  for key in pairs(connection) do if not CONNECTION_SET[key] then return nil, false end end
  for _, key in ipairs(CONNECTION_KEYS) do
    local value = connection[key]
    if value ~= nil then
      if key == "lport" and type(value) == "number" and math.type(value) == "integer" then value = tostring(value) end
      if type(value) ~= "string" or #value == 0 or #value > 255
          or not value:match("^[A-Za-z0-9_.@:%-]+$") then return nil, false end
      if key == "lport" and (not value:match("^%d+$") or #value > 5
          or tonumber(value) < 1 or tonumber(value) > 65535) then return nil, false end
      parts[#parts + 1] = key .. "=" .. value
    end
  end
  return table.concat(parts, ","), true
end

function Config.parse(content)
  if type(content) ~= "string" or #content == 0 or #content > MAX_BYTES then return nil end
  local fields, partial, lines, retained = {}, false, 0, 0
  for line in content:gmatch("[^\n]+") do
    lines = lines + 1
    if lines > MAX_LINES then partial = true break end
    if #line > MAX_LINE or line:find("[%c]") or not utf8.len(line) then
      partial = true
      goto continue
    end
    local key, value = line:match("^([a-z][a-z0-9]*) (.+)$")
    if not key then partial = true goto continue end
    if FIELDS[key] then
      if (key == "port" or key == "maxauthtries" or key == "maxsessions")
          and (not value:match("^%d+$") or #value > 10 or not tonumber(value)
            or tonumber(value) > (key == "port" and 65535 or 2147483647)
            or (key == "port" and tonumber(value) < 1)) then
        partial = true
        goto continue
      end
      if REPEATED[key] and fields[key] ~= nil then
        if type(fields[key]) ~= "table" then fields[key] = { fields[key] } end
        if #fields[key] < MAX_VALUES then fields[key][#fields[key] + 1] = value else partial = true end
      elseif fields[key] ~= nil then
        partial = true -- A scalar repeated in a dump isn't trustworthy.
      else
        fields[key], retained = value, retained + 1
      end
    end
    ::continue::
  end
  if retained == 0 then return nil end
  return fields, partial
end

function Config.new(options)
  options = options or {}
  if type(options) ~= "table" then error("sshd configuration options must be a table", 2) end
  return setmetatable({
    executable = Common.absolute_path("sshd", options.sshd, "/usr/sbin/sshd"),
    config_file = Common.absolute_path("config_file", options.config_file, "/etc/ssh/sshd_config"),
    timeout_ms = Common.positive_integer("timeout_ms", options.timeout_ms, 500, 500),
    runner = options.runner or Runner.new(), clock = options.clock or Clock.default,
    platform = options.platform or Platform.id(),
  }, Config)
end

local function unsupported_g(run)
  if type(run) ~= "table" or run.status ~= "error" or run.truncated
      or (run.stdout or "") ~= "" or type(run.stderr) ~= "string" then return false end
  return run.stderr:find("unknown option %-%- G") ~= nil
    or run.stderr:find("illegal option %-%- G") ~= nil
    or run.stderr:find("invalid option %-%- '?G'?") ~= nil
    or run.stderr:find("Config test connection parameter (-C) provided without test mode (-T)", 1, true) ~= nil
end

function Config:read(context)
  context = type(context) == "table" and context or {}
  local started = Common.now_ns(context, self.clock)
  local function result(status, data, reason, quality)
    local finished = Common.now_ns(context, self.clock)
    return Common.result(status, finished, data, { quality = quality or status, reason = reason,
      source = self.executable, duration_ns = Common.elapsed_ns(finished, started) or 0 })
  end
  if self.platform ~= "linux" or context.safe_mode == true then
    return result("unavailable", nil, "sshd_configuration_unavailable")
  end
  local spec, valid = connection_spec(context.sshd_connection)
  if valid == false then return result("error", nil, "sshd_configuration_connection_invalid") end
  local function query(mode)
    local argv = { self.executable, mode, "-f", self.config_file }
    if spec then argv[#argv + 1], argv[#argv + 2] = "-C", spec end
    local ok, run = pcall(self.runner.run, self.runner, argv, {
      timeout_ms = self.timeout_ms, max_output_bytes = MAX_BYTES, env = { LANG = "C", LC_ALL = "C" },
    })
    return ok and type(run) == "table" and run or nil
  end
  local mode, run = "-G", query("-G")
  if unsupported_g(run) then mode, run = "-T", query("-T") end
  if not run then return result("error", nil, "sshd_configuration_unavailable") end
  local stderr = type(run.stderr) == "string" and run.stderr:lower() or ""
  if run.status == "denied" or stderr:find("permission denied", 1, true)
      or stderr:find("operation not permitted", 1, true) then
    return result("denied", nil, "sshd_configuration_denied")
  end
  if run.status ~= "ok" then
    return result(run.status == "error" and "error" or "unavailable", nil,
      run.status == "error" and "sshd_configuration_invalid" or "sshd_configuration_unavailable")
  end
  if run.truncated then return result("error", nil, "sshd_configuration_invalid") end
  local fields, partial = Config.parse(run.stdout)
  if not fields then return result("error", nil, "sshd_configuration_invalid") end
  partial = partial or stderr ~= ""
  return result("ok", { configuration = fields, file = self.config_file, mode = mode,
    scope = spec and "connection" or "global", partial = partial },
    partial and "sshd_configuration_partial" or "sshd_configuration_current_files",
    partial and "partial" or "estimated")
end

Config.fields = FIELDS
Config.connection_spec = connection_spec
return Config
