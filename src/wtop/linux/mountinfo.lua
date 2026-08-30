local MountInfo = {}

local DEFAULT_MAX_BYTES = 16 * 1024 * 1024
local DEFAULT_MAX_ENTRIES = 16384
local DEFAULT_MAX_LINE_BYTES = 64 * 1024
local DEFAULT_MAX_PATH_BYTES = 16 * 1024
local HARD_MAX_BYTES = 64 * 1024 * 1024
local HARD_MAX_ENTRIES = 1048576
local HARD_MAX_LINE_BYTES = 1024 * 1024
local HARD_MAX_PATH_BYTES = 1024 * 1024

local ESCAPES = {
  ["040"] = " ",
  ["011"] = "\t",
  ["012"] = "\n",
  ["134"] = "\\",
}

-- Filesystems which do not represent an independently backed local volume.
-- tmpfs and overlay are deliberately included: showing their usage is useful,
-- but aggregating them with physical storage would double count memory or the
-- backing filesystem.
local PSEUDO_FILESYSTEMS = {
  autofs = true,
  aufs = true,
  bdev = true,
  binfmt_misc = true,
  bpf = true,
  cgroup = true,
  cgroup2 = true,
  configfs = true,
  debugfs = true,
  devpts = true,
  devtmpfs = true,
  efivarfs = true,
  fusectl = true,
  hugetlbfs = true,
  mqueue = true,
  nsfs = true,
  overlay = true,
  pipefs = true,
  proc = true,
  pstore = true,
  ramfs = true,
  rpc_pipefs = true,
  securityfs = true,
  selinuxfs = true,
  sockfs = true,
  sysfs = true,
  tmpfs = true,
  tracefs = true,
}

local NETWORK_FILESYSTEMS = {
  ["9p"] = true,
  afs = true,
  ceph = true,
  cifs = true,
  coda = true,
  davfs = true,
  davfs2 = true,
  ["fuse.glusterfs"] = true,
  ["fuse.sshfs"] = true,
  glusterfs = true,
  lustre = true,
  ncpfs = true,
  nfs = true,
  nfs4 = true,
  smb2 = true,
  smb3 = true,
  sshfs = true,
}

local function positive_integer(value, fallback)
  if value == nil then return fallback end
  if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
    return nil
  end
  return value
end

local function unsigned_integer(value)
  if type(value) ~= "string" or not value:match("^%d+$") then
    return nil
  end
  local number = tonumber(value)
  if number == nil or number < 0 or number % 1 ~= 0 then
    return nil
  end
  -- A floating-point conversion here would silently lose mount identity.
  if math.type and math.type(number) ~= "integer" then
    return nil
  end
  return number
end

local function decode_field(value)
  local result = {}
  local index = 1
  while index <= #value do
    local byte = value:sub(index, index)
    if byte ~= "\\" then
      result[#result + 1] = byte
      index = index + 1
    else
      local code = value:sub(index + 1, index + 3)
      local replacement = ESCAPES[code]
      if not replacement then
        return nil, "invalid_escape"
      end
      result[#result + 1] = replacement
      index = index + 4
    end
  end
  return table.concat(result)
end

local function split_options(value)
  if value == "" then return nil, nil, "empty_options" end
  local values = {}
  local set = {}
  local start = 1
  while true do
    local separator = value:find(",", start, true)
    local raw = separator and value:sub(start, separator - 1) or value:sub(start)
    if raw == "" then return nil, nil, "empty_option" end
    local decoded, decode_error = decode_field(raw)
    if not decoded then return nil, nil, decode_error end
    values[#values + 1] = decoded
    set[decoded] = true
    if not separator then break end
    start = separator + 1
  end
  return values, set
end

local function parse_optional_fields(words, first, last)
  local values = {}
  local structured = {}
  local by_tag = {}
  for index = first, last do
    local decoded, decode_error = decode_field(words[index])
    if not decoded then return nil, nil, nil, decode_error end
    values[#values + 1] = decoded
    local tag, value = decoded:match("^([^:]+):(.*)$")
    if not tag then tag = decoded end
    local field = { tag = tag, value = value, raw = decoded }
    structured[#structured + 1] = field
    local tagged = by_tag[tag]
    if not tagged then
      tagged = {}
      by_tag[tag] = tagged
    end
    tagged[#tagged + 1] = value == nil and true or value
  end
  return values, structured, by_tag
end

local function is_network(fs_type)
  if NETWORK_FILESYSTEMS[fs_type] then return true end
  return fs_type:match("^nfs%d*$") ~= nil
    or fs_type:match("^fuse%.sshfs") ~= nil
    or fs_type:match("^fuse%.glusterfs") ~= nil
end

local function line_error(line_number, reason)
  if line_number then
    return "mountinfo_line_" .. tostring(line_number) .. ":" .. reason
  end
  return reason
end

function MountInfo.decode(value)
  if type(value) ~= "string" then return nil, "string_required" end
  return decode_field(value)
end

function MountInfo.parse_line(line, options)
  options = options or {}
  if type(line) ~= "string" then return nil, "line_required" end
  if type(options) ~= "table" then return nil, "invalid_options" end
  local line_number = options.line_number
  local max_line_bytes = positive_integer(options.max_line_bytes, DEFAULT_MAX_LINE_BYTES)
  local max_path_bytes = positive_integer(options.max_path_bytes, DEFAULT_MAX_PATH_BYTES)
  if not max_line_bytes or max_line_bytes > HARD_MAX_LINE_BYTES then
    return nil, "invalid_max_line_bytes"
  end
  if not max_path_bytes or max_path_bytes > HARD_MAX_PATH_BYTES then
    return nil, "invalid_max_path_bytes"
  end
  if #line > max_line_bytes then
    return nil, line_error(line_number, "line_too_long")
  end
  if line == "" or line:find("%z") then
    return nil, line_error(line_number, "invalid_line")
  end

  local words = {}
  for word in line:gmatch("%S+") do words[#words + 1] = word end
  if #words < 10 then
    return nil, line_error(line_number, "incomplete_line")
  end

  local separator
  for index = 7, #words do
    if words[index] == "-" then
      separator = index
      break
    end
  end
  if not separator then
    return nil, line_error(line_number, "separator_missing")
  end
  if #words ~= separator + 3 then
    return nil, line_error(line_number, "invalid_post_separator_fields")
  end

  local mount_id = unsigned_integer(words[1])
  local parent_id = unsigned_integer(words[2])
  local major_text, minor_text = words[3]:match("^(%d+):(%d+)$")
  local major = unsigned_integer(major_text)
  local minor = unsigned_integer(minor_text)
  if not mount_id or not parent_id then
    return nil, line_error(line_number, "invalid_mount_identity")
  end
  if not major or not minor then
    return nil, line_error(line_number, "invalid_device_identity")
  end

  local root, root_error = decode_field(words[4])
  local mount_point, mount_point_error = decode_field(words[5])
  local source, source_error = decode_field(words[separator + 2])
  if not root then return nil, line_error(line_number, "root_" .. root_error) end
  if not mount_point then return nil, line_error(line_number, "mount_point_" .. mount_point_error) end
  if not source then return nil, line_error(line_number, "source_" .. source_error) end
  -- mount_point is a pathname in the process namespace. root is usually a
  -- pathname within the filesystem, but pseudo filesystems such as nsfs use
  -- identities like "net:[4026533566]" and must not be rejected.
  if mount_point:sub(1, 1) ~= "/" then
    return nil, line_error(line_number, "non_absolute_mount_point")
  end
  if #root > max_path_bytes or #mount_point > max_path_bytes or #source > max_path_bytes then
    return nil, line_error(line_number, "path_too_long")
  end

  local mount_options, mount_option_set, mount_option_error = split_options(words[6])
  if not mount_options then
    return nil, line_error(line_number, "mount_options_" .. mount_option_error)
  end
  local super_options, super_option_set, super_option_error = split_options(words[separator + 3])
  if not super_options then
    return nil, line_error(line_number, "super_options_" .. super_option_error)
  end
  local optional_fields, optional, optional_by_tag, optional_error =
    parse_optional_fields(words, 7, separator - 1)
  if not optional_fields then
    return nil, line_error(line_number, "optional_field_" .. optional_error)
  end

  local fs_type = words[separator + 1]
  if fs_type == "" or fs_type:find("\\", 1, true) then
    return nil, line_error(line_number, "invalid_fs_type")
  end
  local network = is_network(fs_type)
  local pseudo = PSEUDO_FILESYSTEMS[fs_type] == true
  local readonly = mount_option_set.ro == true or super_option_set.ro == true

  return {
    id = tostring(mount_id),
    mount_id = mount_id,
    parent_id = parent_id,
    major = major,
    minor = minor,
    device_id = tostring(major) .. ":" .. tostring(minor),
    root = root,
    mount_point = mount_point,
    mount_options_raw = words[6],
    mount_options = mount_options,
    mount_option_set = mount_option_set,
    optional_fields = optional_fields,
    optional = optional,
    optional_by_tag = optional_by_tag,
    fs_type = fs_type,
    source = source,
    super_options_raw = words[separator + 3],
    super_options = super_options,
    super_option_set = super_option_set,
    readonly = readonly,
    pseudo = pseudo,
    network = network,
    kind = network and "network" or (pseudo and "pseudo" or "local"),
  }
end

function MountInfo.parse(content, options)
  options = options or {}
  if type(content) ~= "string" then return nil, "content_required" end
  if type(options) ~= "table" then return nil, "invalid_options" end
  local max_bytes = positive_integer(options.max_bytes, DEFAULT_MAX_BYTES)
  local max_entries = positive_integer(options.max_entries, DEFAULT_MAX_ENTRIES)
  local max_line_bytes = positive_integer(options.max_line_bytes, DEFAULT_MAX_LINE_BYTES)
  local max_path_bytes = positive_integer(options.max_path_bytes, DEFAULT_MAX_PATH_BYTES)
  if not max_bytes or max_bytes > HARD_MAX_BYTES then return nil, "invalid_max_bytes" end
  if not max_entries or max_entries > HARD_MAX_ENTRIES then return nil, "invalid_max_entries" end
  if not max_line_bytes or max_line_bytes > HARD_MAX_LINE_BYTES then
    return nil, "invalid_max_line_bytes"
  end
  if not max_path_bytes or max_path_bytes > HARD_MAX_PATH_BYTES then
    return nil, "invalid_max_path_bytes"
  end
  if #content > max_bytes then return nil, "mountinfo_content_limit_exceeded" end

  local entries = {}
  local seen_ids = {}
  local line_number = 0
  for raw_line in (content .. "\n"):gmatch("(.-)\n") do
    line_number = line_number + 1
    local line = raw_line
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if line ~= "" then
      if #entries >= max_entries then
        return nil, "mountinfo_entry_limit_exceeded"
      end
      local entry, parse_error = MountInfo.parse_line(line, {
        line_number = line_number,
        max_line_bytes = max_line_bytes,
        max_path_bytes = max_path_bytes,
      })
      if not entry then return nil, parse_error end
      if seen_ids[entry.id] then
        return nil, line_error(line_number, "duplicate_mount_id")
      end
      seen_ids[entry.id] = true
      entries[#entries + 1] = entry
    end
  end
  if #entries == 0 then return nil, "mountinfo_empty" end
  return entries
end

MountInfo.DEFAULT_MAX_BYTES = DEFAULT_MAX_BYTES
MountInfo.DEFAULT_MAX_ENTRIES = DEFAULT_MAX_ENTRIES
MountInfo.DEFAULT_MAX_LINE_BYTES = DEFAULT_MAX_LINE_BYTES
MountInfo.DEFAULT_MAX_PATH_BYTES = DEFAULT_MAX_PATH_BYTES
MountInfo.HARD_MAX_BYTES = HARD_MAX_BYTES
MountInfo.HARD_MAX_ENTRIES = HARD_MAX_ENTRIES
MountInfo.HARD_MAX_LINE_BYTES = HARD_MAX_LINE_BYTES
MountInfo.HARD_MAX_PATH_BYTES = HARD_MAX_PATH_BYTES
MountInfo.PSEUDO_FILESYSTEMS = PSEUDO_FILESYSTEMS
MountInfo.NETWORK_FILESYSTEMS = NETWORK_FILESYSTEMS

return MountInfo
