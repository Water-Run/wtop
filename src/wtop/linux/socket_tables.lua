local SocketTables = {}

local DEFAULT_MAX_BYTES = 16 * 1024 * 1024
local DEFAULT_MAX_LINES = 131072
local DEFAULT_MAX_LINE_BYTES = 64 * 1024
local DEFAULT_MAX_ERRORS = 256
local HARD_MAX_BYTES = 64 * 1024 * 1024
local HARD_MAX_LINES = 1048576
local HARD_MAX_LINE_BYTES = 1024 * 1024
local HARD_MAX_ERRORS = 4096

local TCP_STATES = {
  ["01"] = "ESTABLISHED",
  ["02"] = "SYN_SENT",
  ["03"] = "SYN_RECV",
  ["04"] = "FIN_WAIT1",
  ["05"] = "FIN_WAIT2",
  ["06"] = "TIME_WAIT",
  ["07"] = "CLOSE",
  ["08"] = "CLOSE_WAIT",
  ["09"] = "LAST_ACK",
  ["0A"] = "LISTEN",
  ["0B"] = "CLOSING",
  ["0C"] = "NEW_SYN_RECV",
  ["0D"] = "BOUND_INACTIVE",
}

local UNIX_TYPES = {
  ["0001"] = "STREAM",
  ["0002"] = "DGRAM",
  ["0003"] = "RAW",
  ["0004"] = "RDM",
  ["0005"] = "SEQPACKET",
  ["0006"] = "DCCP",
  ["000A"] = "PACKET",
}

local UNIX_STATES = {
  ["00"] = "FREE",
  ["01"] = "UNCONNECTED",
  ["02"] = "CONNECTING",
  ["03"] = "CONNECTED",
  ["04"] = "DISCONNECTING",
}

local HOST_LITTLE_ENDIAN = string.pack("I2", 1):byte(1) == 1

local function positive_integer(value, fallback)
  if value == nil then return fallback end
  if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then return nil end
  return value
end

local function nonnegative_integer(value, fallback)
  if value == nil then return fallback end
  if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then return nil end
  return value
end

local function canonical_decimal(value)
  if type(value) ~= "string" or not value:match("^%d+$") then return nil end
  local normalized = value:gsub("^0+", "")
  return normalized == "" and "0" or normalized
end

local function decimal_number(value)
  local normalized = canonical_decimal(value)
  if not normalized then return nil end
  local number = tonumber(normalized)
  if not number or number < 0 or number % 1 ~= 0 then return nil end
  if math.type and math.type(number) ~= "integer" then return nil end
  return number
end

local function hex_number(value, maximum_digits)
  if type(value) ~= "string" or #value < 1 or #value > (maximum_digits or 16)
      or not value:match("^[0-9A-Fa-f]+$") then
    return nil
  end
  local number = tonumber(value, 16)
  if not number or number < 0 or number % 1 ~= 0 then return nil end
  if math.type and math.type(number) ~= "integer" then return nil end
  return number
end

local function byte_pairs(hex)
  local bytes = {}
  for index = 1, #hex, 2 do
    local byte = tonumber(hex:sub(index, index + 1), 16)
    if not byte then return nil end
    bytes[#bytes + 1] = byte
  end
  return bytes
end

local function decode_ipv4(hex, little_endian)
  if type(hex) ~= "string" or #hex ~= 8 or not hex:match("^%x+$") then
    return nil, "invalid_ipv4_address"
  end
  local bytes = byte_pairs(hex)
  if little_endian then
    bytes[1], bytes[4] = bytes[4], bytes[1]
    bytes[2], bytes[3] = bytes[3], bytes[2]
  end
  return table.concat({ bytes[1], bytes[2], bytes[3], bytes[4] }, ".")
end

local function canonical_ipv6(groups)
  local best_start, best_length
  local index = 1
  while index <= 8 do
    if groups[index] == 0 then
      local finish = index
      while finish <= 8 and groups[finish] == 0 do finish = finish + 1 end
      local length = finish - index
      if length >= 2 and (not best_length or length > best_length) then
        best_start, best_length = index, length
      end
      index = finish
    else
      index = index + 1
    end
  end
  local function group_text(first, last)
    local values = {}
    for position = first, last do values[#values + 1] = string.format("%x", groups[position]) end
    return table.concat(values, ":")
  end
  if not best_start then return group_text(1, 8) end
  local left = group_text(1, best_start - 1)
  local right = group_text(best_start + best_length, 8)
  if left == "" and right == "" then return "::" end
  if left == "" then return "::" .. right end
  if right == "" then return left .. "::" end
  return left .. "::" .. right
end

local function decode_ipv6(hex, little_endian)
  if type(hex) ~= "string" or #hex ~= 32 or not hex:match("^%x+$") then
    return nil, "invalid_ipv6_address"
  end
  local input = byte_pairs(hex)
  local bytes = {}
  for word = 0, 3 do
    local start = word * 4 + 1
    if little_endian then
      bytes[#bytes + 1] = input[start + 3]
      bytes[#bytes + 1] = input[start + 2]
      bytes[#bytes + 1] = input[start + 1]
      bytes[#bytes + 1] = input[start]
    else
      bytes[#bytes + 1] = input[start]
      bytes[#bytes + 1] = input[start + 1]
      bytes[#bytes + 1] = input[start + 2]
      bytes[#bytes + 1] = input[start + 3]
    end
  end
  local groups = {}
  for group = 0, 7 do
    groups[group + 1] = bytes[group * 2 + 1] * 256 + bytes[group * 2 + 2]
  end
  return canonical_ipv6(groups)
end

local function endpoint(value, family, little_endian)
  local address_hex, port_hex = value:match("^([0-9A-Fa-f]+):([0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])$")
  if not address_hex then return nil, "invalid_endpoint" end
  local address, address_error
  if family == "ipv4" then
    address, address_error = decode_ipv4(address_hex, little_endian)
  else
    address, address_error = decode_ipv6(address_hex, little_endian)
  end
  if not address then return nil, address_error end
  local port = hex_number(port_hex, 4)
  if not port then return nil, "invalid_port" end
  return {
    family = family,
    address = address,
    port = port,
    text = family == "ipv6" and ("[" .. address .. "]:" .. tostring(port))
      or (address .. ":" .. tostring(port)),
  }
end

local function words(line)
  local result = {}
  for word in line:gmatch("%S+") do result[#result + 1] = word end
  return result
end

local function parse_inet_line(line, protocol, family, little_endian)
  local fields = words(line)
  if #fields < 10 then return nil, "incomplete_inet_row" end
  local slot_hex = fields[1]:match("^([0-9A-Fa-f]+):$")
  local slot = hex_number(slot_hex, 8)
  if not slot then return nil, "invalid_slot" end
  local local_endpoint, local_error = endpoint(fields[2], family, little_endian)
  if not local_endpoint then return nil, "local_" .. local_error end
  local remote_endpoint, remote_error = endpoint(fields[3], family, little_endian)
  if not remote_endpoint then return nil, "remote_" .. remote_error end
  if not fields[4]:match("^[0-9A-Fa-f][0-9A-Fa-f]$") then return nil, "invalid_state" end
  local state_code = fields[4]:upper()
  local tx_hex, rx_hex = fields[5]:match("^([0-9A-Fa-f]+):([0-9A-Fa-f]+)$")
  local tx_queue = hex_number(tx_hex, 16)
  local rx_queue = hex_number(rx_hex, 16)
  if not tx_queue or not rx_queue then return nil, "invalid_queue" end
  local uid = decimal_number(fields[8])
  if uid == nil then return nil, "invalid_uid" end
  local inode = canonical_decimal(fields[10])
  if not inode then return nil, "invalid_inode" end
  local table_name = protocol .. (family == "ipv6" and "6" or "")
  local base_id
  if inode ~= "0" then
    base_id = table_name .. ":inode:" .. inode
  else
    base_id = table.concat({
      table_name, local_endpoint.text, remote_endpoint.text, state_code,
    }, ":")
  end
  return {
    protocol = protocol,
    family = family,
    table = table_name,
    slot = slot,
    local_endpoint = local_endpoint,
    remote_endpoint = remote_endpoint,
    local_address = local_endpoint.address,
    local_port = local_endpoint.port,
    remote_address = remote_endpoint.address,
    remote_port = remote_endpoint.port,
    state_code = state_code,
    state = TCP_STATES[state_code] or ("UNKNOWN_" .. state_code),
    tx_queue = tx_queue,
    rx_queue = rx_queue,
    uid = uid,
    inode = inode,
    base_id = base_id,
  }
end

local function parse_unix_line(line)
  local number, ref_count, protocol, flags, socket_type, state, inode, path = line:match(
    "^%s*([0-9A-Fa-f]+):%s+([0-9A-Fa-f]+)%s+([0-9A-Fa-f]+)%s+"
      .. "([0-9A-Fa-f]+)%s+([0-9A-Fa-f]+)%s+([0-9A-Fa-f]+)%s+(%d+)%s*(.*)$"
  )
  if not number then return nil, "invalid_unix_row" end
  local ref_count_number = hex_number(ref_count, 16)
  local protocol_number = hex_number(protocol, 16)
  local flags_number = hex_number(flags, 16)
  local type_number = hex_number(socket_type, 8)
  local state_number = hex_number(state, 8)
  local normalized_inode = canonical_decimal(inode)
  if not ref_count_number or not protocol_number or not flags_number or not type_number
      or not state_number or not normalized_inode then
    return nil, "invalid_unix_fields"
  end
  local type_code = socket_type:upper()
  local state_code = state:upper()
  if #type_code < 4 then type_code = string.rep("0", 4 - #type_code) .. type_code end
  if #state_code < 2 then state_code = "0" .. state_code end
  if path == "" then path = nil end
  local base_id = normalized_inode ~= "0" and ("unix:inode:" .. normalized_inode)
    or ("unix:" .. type_code .. ":" .. tostring(path or number:upper()))
  return {
    protocol = "unix",
    family = "unix",
    table = "unix",
    kernel_address = number:upper(),
    ref_count = ref_count_number,
    protocol_number = protocol_number,
    flags = flags_number,
    type_code = type_code,
    socket_type = UNIX_TYPES[type_code] or ("UNKNOWN_" .. type_code),
    state_code = state_code,
    state = UNIX_STATES[state_code] or ("UNKNOWN_" .. state_code),
    inode = normalized_inode,
    path = path,
    base_id = base_id,
  }
end

local function parser_limits(options)
  options = options or {}
  if type(options) ~= "table" then return nil, "invalid_options" end
  local max_bytes = positive_integer(options.max_bytes, DEFAULT_MAX_BYTES)
  local max_lines = nonnegative_integer(options.max_lines, DEFAULT_MAX_LINES)
  local max_line_bytes = positive_integer(options.max_line_bytes, DEFAULT_MAX_LINE_BYTES)
  local max_errors = nonnegative_integer(options.max_errors, DEFAULT_MAX_ERRORS)
  if not max_bytes or max_bytes > HARD_MAX_BYTES then return nil, "invalid_max_bytes" end
  if max_lines == nil or max_lines > HARD_MAX_LINES then return nil, "invalid_max_lines" end
  if not max_line_bytes or max_line_bytes > HARD_MAX_LINE_BYTES then return nil, "invalid_max_line_bytes" end
  if max_errors == nil or max_errors > HARD_MAX_ERRORS then return nil, "invalid_max_errors" end
  return {
    max_bytes = max_bytes,
    max_lines = max_lines,
    max_line_bytes = max_line_bytes,
    max_errors = max_errors,
  }
end

local function parse_table(content, kind, options)
  if type(content) ~= "string" then return nil, "content_required" end
  local limits, limit_error = parser_limits(options)
  if not limits then return nil, limit_error end
  if #content > limits.max_bytes then return nil, "socket_table_exceeds_max_bytes" end
  local protocol, family
  if kind == "tcp" then protocol, family = "tcp", "ipv4"
  elseif kind == "tcp6" then protocol, family = "tcp", "ipv6"
  elseif kind == "udp" then protocol, family = "udp", "ipv4"
  elseif kind == "udp6" then protocol, family = "udp", "ipv6"
  elseif kind ~= "unix" then return nil, "unknown_socket_table" end
  local little_endian = options and options.little_endian
  if little_endian == nil then little_endian = HOST_LITTLE_ENDIAN end
  if type(little_endian) ~= "boolean" then return nil, "invalid_endianness" end

  local report = {
    kind = kind,
    entries = {},
    errors = {},
    lines_seen = 0,
    parsed = 0,
    error_count = 0,
    truncated = false,
    partial = false,
    header_seen = false,
  }
  local function add_error(line_number, reason)
    report.error_count = report.error_count + 1
    if #report.errors < limits.max_errors then
      report.errors[#report.errors + 1] = { line = line_number, reason = reason }
    end
  end

  local line_number = 0
  for raw_line in (content .. "\n"):gmatch("(.-)\n") do
    line_number = line_number + 1
    local line = raw_line
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if line ~= "" then
      local header = kind == "unix" and line:match("^%s*Num%s+RefCount")
        or (kind ~= "unix" and line:match("^%s*sl%s+local_address"))
      if header and not report.header_seen and #line <= limits.max_line_bytes then
        report.header_seen = true
      else
        if report.lines_seen >= limits.max_lines then
          report.truncated = true
          break
        end
        report.lines_seen = report.lines_seen + 1
        if #line > limits.max_line_bytes then
          add_error(line_number, "line_too_long")
        else
          local entry, parse_error
          if kind == "unix" then
            entry, parse_error = parse_unix_line(line)
          else
            entry, parse_error = parse_inet_line(line, protocol, family, little_endian)
          end
          if entry then
            report.entries[#report.entries + 1] = entry
            report.parsed = report.parsed + 1
          else
            add_error(line_number, parse_error)
          end
        end
      end
    end
  end
  if not report.header_seen then add_error(1, "header_missing") end
  report.partial = report.truncated or report.error_count > 0
  return report
end

function SocketTables.parse(content, kind, options)
  return parse_table(content, kind, options)
end

function SocketTables.parse_inet(content, protocol, family, options)
  local kind
  if protocol == "tcp" and family == "ipv4" then kind = "tcp"
  elseif protocol == "tcp" and family == "ipv6" then kind = "tcp6"
  elseif protocol == "udp" and family == "ipv4" then kind = "udp"
  elseif protocol == "udp" and family == "ipv6" then kind = "udp6"
  else return nil, "invalid_protocol_or_family" end
  return parse_table(content, kind, options)
end

function SocketTables.parse_unix(content, options)
  return parse_table(content, "unix", options)
end

function SocketTables.decode_ipv4(value, options)
  options = options or {}
  if type(options) ~= "table" then return nil, "invalid_options" end
  local little_endian = options.little_endian
  if little_endian == nil then little_endian = HOST_LITTLE_ENDIAN end
  return decode_ipv4(value, little_endian)
end

function SocketTables.decode_ipv6(value, options)
  options = options or {}
  if type(options) ~= "table" then return nil, "invalid_options" end
  local little_endian = options.little_endian
  if little_endian == nil then little_endian = HOST_LITTLE_ENDIAN end
  return decode_ipv6(value, little_endian)
end

SocketTables.TCP_STATES = TCP_STATES
SocketTables.UNIX_TYPES = UNIX_TYPES
SocketTables.UNIX_STATES = UNIX_STATES
SocketTables.HOST_LITTLE_ENDIAN = HOST_LITTLE_ENDIAN
SocketTables.DEFAULT_MAX_BYTES = DEFAULT_MAX_BYTES
SocketTables.DEFAULT_MAX_LINES = DEFAULT_MAX_LINES
SocketTables.DEFAULT_MAX_LINE_BYTES = DEFAULT_MAX_LINE_BYTES
SocketTables.DEFAULT_MAX_ERRORS = DEFAULT_MAX_ERRORS
SocketTables.HARD_MAX_BYTES = HARD_MAX_BYTES
SocketTables.HARD_MAX_LINES = HARD_MAX_LINES
SocketTables.HARD_MAX_LINE_BYTES = HARD_MAX_LINE_BYTES
SocketTables.HARD_MAX_ERRORS = HARD_MAX_ERRORS

return SocketTables
