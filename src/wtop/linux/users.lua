-- UID/GID to name resolution from /etc/passwd and /etc/group.
--
-- Deliberately not getpwuid(3): that call enters NSS, which on a host
-- configured for LDAP or SSSD can block for seconds inside the render loop.
-- Reading the local databases keeps the cost bounded and predictable, and a
-- missing entry simply leaves the numeric id visible.
local FS = require("wtop.linux.fs")

local M = {}

local MAX_FILE_BYTES = 4 * 1024 * 1024
local MAX_ENTRIES = 8192
local DEFAULT_TTL_NS = 60 * 1000000000

local Resolver = {}
Resolver.__index = Resolver

local function parse_database(content, name_field, id_field)
  if type(content) ~= "string" then return nil end
  local by_id = {}
  local count = 0
  for line in content:gmatch("[^\n]+") do
    if count >= MAX_ENTRIES then break end
    if line:sub(1, 1) ~= "#" then
      local fields = {}
      -- A trailing empty field matters (an empty shell or member list), so the
      -- separator is walked explicitly instead of using gmatch on "[^:]+".
      local position = 1
      while #fields < 8 do
        local separator = line:find(":", position, true)
        if not separator then
          fields[#fields + 1] = line:sub(position)
          break
        end
        fields[#fields + 1] = line:sub(position, separator - 1)
        position = separator + 1
      end
      local name = fields[name_field]
      local id = tonumber(fields[id_field])
      if name and name ~= "" and #name <= 64 and type(id) == "number"
          and id == id and id % 1 == 0 and id >= 0 and id <= 4294967295
          and by_id[id] == nil then
        by_id[id] = name
        count = count + 1
      end
    end
  end
  return by_id, count
end

function M.new(options)
  options = options or {}
  if type(options) ~= "table" then error("users options must be a table", 2) end
  return setmetatable({
    fs = options.fs or FS.default,
    passwd_path = options.passwd_path or "/etc/passwd",
    group_path = options.group_path or "/etc/group",
    ttl_ns = options.ttl_ns or DEFAULT_TTL_NS,
    _users = nil,
    _groups = nil,
    _loaded_ns = nil,
  }, Resolver)
end

function Resolver:_refresh(now_ns)
  if self._users and self._loaded_ns and type(now_ns) == "number"
      and now_ns - self._loaded_ns < self.ttl_ns then
    return
  end
  local passwd = self.fs:read(self.passwd_path, MAX_FILE_BYTES)
  local group = self.fs:read(self.group_path, MAX_FILE_BYTES)
  self._users = parse_database(passwd, 1, 3) or self._users or {}
  self._groups = parse_database(group, 1, 3) or self._groups or {}
  self._loaded_ns = type(now_ns) == "number" and now_ns or 0
end

--- Resolve a UID to a user name, or nil when it is not in the local database.
function Resolver:user(uid, now_ns)
  if type(uid) ~= "number" or uid ~= uid or uid % 1 ~= 0 or uid < 0 then return nil end
  self:_refresh(now_ns)
  return self._users[uid]
end

function Resolver:group(gid, now_ns)
  if type(gid) ~= "number" or gid ~= gid or gid % 1 ~= 0 or gid < 0 then return nil end
  self:_refresh(now_ns)
  return self._groups[gid]
end

--- Display form: the name when known, otherwise the numeric id unchanged.
function Resolver:user_label(uid, now_ns)
  if type(uid) ~= "number" then return nil end
  return self:user(uid, now_ns) or tostring(uid)
end

function Resolver:count(now_ns)
  self:_refresh(now_ns)
  local users, groups = 0, 0
  for _ in pairs(self._users) do users = users + 1 end
  for _ in pairs(self._groups) do groups = groups + 1 end
  return users, groups
end

M.parse_database = parse_database
M.default = M.new()

return M
