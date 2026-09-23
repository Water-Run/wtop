local native_default = require("wtop.native")

local M = {}

local SUDO_CANDIDATES = {
    "/usr/bin/sudo",
    "/bin/sudo",
    "/run/wrappers/bin/sudo",
}

local SAFE_PATH = "/usr/sbin:/usr/bin:/sbin:/bin"
-- Native execve accepts 512 total entries and a 1 MiB argv+environment
-- budget. Reserve three entries for sudo/-H/-- and 64 KiB for the fixed path
-- plus the bounded terminal/locale environment.
local MAX_COMMAND_BYTES = 960 * 1024
local MAX_ARGUMENTS = 509
local MAX_STATUS_BYTES = 256 * 1024
local MAX_UID = 4294967295

local function call(function_value, ...)
    if type(function_value) ~= "function" then return nil, "native function unavailable" end
    local ok, first, second, third = pcall(function_value, ...)
    if not ok then return nil, tostring(first) end
    return first, second, third
end

local function valid_uid(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and value >= 0 and value <= MAX_UID and value % 1 == 0
end

local function parse_status_uids(content)
    if type(content) ~= "string" or #content > MAX_STATUS_BYTES then return nil end
    local real, effective = content:match("^Uid:%s*(%d+)%s+(%d+)")
    if not real then real, effective = content:match("\nUid:%s*(%d+)%s+(%d+)") end
    real, effective = tonumber(real), tonumber(effective)
    if not valid_uid(real) or not valid_uid(effective) then return nil end
    return real, effective
end

local function status_uids(options, backend)
    local content
    if options.read_status ~= nil then
        if type(options.read_status) ~= "function" then
            error("read_status must be a function", 3)
        end
        local ok, value = pcall(options.read_status)
        if ok then content = value end
    else
        content = call(backend.readfile, "/proc/self/status", MAX_STATUS_BYTES)
        if type(content) ~= "string" then
            local file = io.open("/proc/self/status", "rb")
            if file then
                content = file:read(MAX_STATUS_BYTES + 1)
                file:close()
            end
        end
    end
    return parse_status_uids(content)
end

local function environment_value(getenv, name, maximum)
    local ok, value = pcall(getenv, name)
    if not ok or type(value) ~= "string" or value:find("\0", 1, true) then return nil end
    if #value > (maximum or 4096) then return nil end
    return value
end

local function environment_uid(getenv, name)
    local value = environment_value(getenv, name, 32)
    if not value or not value:match("^%d+$") then return nil end
    local number = tonumber(value)
    return valid_uid(number) and number or nil
end

function M.identity(options)
    options = options or {}
    if type(options) ~= "table" then error("privilege options must be a table", 2) end
    local backend = options.native or native_default
    local getenv = options.getenv or os.getenv
    local platform = call(backend.uname)
    local windows = type(platform) == "table" and platform.sysname == "Windows"
    if windows and type(backend.is_admin) == "function" then
        local administrator = call(backend.is_admin)
        if type(administrator) == "boolean" then
            return {
                mode = "user",
                uid = nil,
                effective_uid = nil,
                original_uid = nil,
                root = false,
                elevated = administrator,
                via_sudo = false,
            }
        end
    end
    local real_uid, effective_uid = call(backend.uid)
    if not valid_uid(real_uid) then real_uid = nil end
    if not valid_uid(effective_uid) then effective_uid = nil end
    if not windows and (real_uid == nil or effective_uid == nil) then
        local status_real, status_effective = status_uids(options, backend)
        real_uid = real_uid or status_real
        effective_uid = effective_uid or status_effective
    end
    local original_uid = environment_uid(getenv, "SUDO_UID")
    local root = effective_uid == 0
    local via_sudo = root and original_uid ~= nil
    return {
        mode = effective_uid == nil and "unknown" or (root and "root" or "user"),
        uid = real_uid,
        effective_uid = effective_uid,
        original_uid = via_sudo and original_uid or nil,
        root = root,
        elevated = root,
        via_sudo = via_sudo,
    }
end

--- Whether this session must ignore files owned by the invoking user.
--
-- Under `sudo` the process is root but the configuration file, the user locale
-- catalogs and the persisted layout all still belong to the unprivileged user
-- who invoked it.  Reading them would let an unprivileged file steer a root
-- process, and writing the layout back would leave root-owned files in that
-- user's config directory.  Every such site consults this one predicate so the
-- policy cannot drift between them.
function M.restricts_user_files(privilege)
    return type(privilege) == "table" and privilege.via_sudo == true
end

function M.parse_proc_cmdline(raw)
    if type(raw) ~= "string" or raw == "" or #raw > MAX_COMMAND_BYTES
        or raw:sub(-1) ~= "\0"
    then
        return nil, "invalid /proc/self/cmdline"
    end
    local result = {}
    local offset = 1
    while offset <= #raw do
        local boundary = raw:find("\0", offset, true)
        if not boundary then return nil, "invalid /proc/self/cmdline" end
        result[#result + 1] = raw:sub(offset, boundary - 1)
        if #result > MAX_ARGUMENTS then return nil, "current command has too many arguments" end
        offset = boundary + 1
    end
    if #result == 0 or result[1] == "" then return nil, "current command has no executable" end
    return result
end

local function sudo_executable(backend, candidates)
    for _, candidate in ipairs(candidates or SUDO_CANDIDATES) do
        if type(candidate) == "string" and candidate:sub(1, 1) == "/"
            and not candidate:find("\0", 1, true)
        then
            local kind = call(backend.path_type, candidate, true)
            local executable = call(backend.access, candidate, "x")
            if kind == "regular" and executable == true then return candidate end
        end
    end
    return nil, "sudo was not found at a supported fixed system path"
end

local function sanitized_environment(getenv)
    local result = { "PATH=" .. SAFE_PATH }
    for _, name in ipairs({ "TERM", "COLORTERM", "LANG", "LC_ALL", "LC_CTYPE", "NO_COLOR" }) do
        local value = environment_value(getenv, name)
        if value ~= nil then result[#result + 1] = name .. "=" .. value end
    end
    return result
end

function M.elevation_command(options)
    options = options or {}
    if type(options) ~= "table" then error("privilege options must be a table", 2) end
    local backend = options.native or native_default
    local getenv = options.getenv or os.getenv
    local sudo, sudo_error = sudo_executable(backend, options.sudo_candidates)
    if not sudo then return nil, nil, sudo_error end

    local raw, read_error = call(backend.readfile, "/proc/self/cmdline", MAX_COMMAND_BYTES)
    if type(raw) ~= "string" then
        return nil, nil, "cannot read current command: " .. tostring(read_error)
    end
    local current, parse_error = M.parse_proc_cmdline(raw)
    if not current then return nil, nil, parse_error end

    local executable, executable_error = call(backend.readlink, "/proc/self/exe")
    if type(executable) ~= "string" or executable:sub(1, 1) ~= "/"
        or executable:find("\0", 1, true)
    then
        return nil, nil, "cannot resolve current executable: " .. tostring(executable_error)
    end
    current[1] = executable

    local command = { sudo, "-H", "--" }
    for _, argument in ipairs(current) do command[#command + 1] = argument end
    return command, sanitized_environment(getenv)
end

function M.elevate(options)
    options = options or {}
    if type(options) ~= "table" then error("privilege options must be a table", 2) end
    local backend = options.native or native_default
    if M.identity(options).root then return true, "already_root" end
    local command, environment, command_error = M.elevation_command(options)
    if not command then return nil, command_error end
    local executor = options.execve or backend.execve
    if type(executor) ~= "function" then return nil, "native execve is unavailable" end
    local ok, executed, execute_error = pcall(executor, command, environment)
    if not ok then return nil, tostring(executed) end
    if not executed then return nil, tostring(execute_error or "sudo exec failed") end
    return nil, "sudo exec returned without replacing the process"
end

M.SAFE_PATH = SAFE_PATH
M.SUDO_CANDIDATES = SUDO_CANDIDATES
M.parse_status_uids = parse_status_uids

return M
