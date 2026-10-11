-- Bounded, read-only view of the legacy IPv4 and IPv6 procfs route tables.
-- These files are not an RTM_GETROUTE dump of every policy table.
local FS = require("wtop.linux.fs")
local SocketTables = require("wtop.linux.socket_tables")

local M = { MAX_ENTRIES = 2048, MAX_LINES = 131072 }
local MAX_LINE_BYTES = 4096
local IPV6_ZERO = string.rep("0", 32)

local function decimal(value)
  if type(value) ~= "string" or not value:match("^%d+$") then return nil end
  local number = tonumber(value)
  return number and math.type(number) == "integer" and number >= 0 and number or nil
end

local function hex(value, length)
  if type(value) ~= "string" or #value ~= length
      or not value:match("^[0-9A-Fa-f]+$") then return nil end
  local number = tonumber(value, 16)
  return number and math.type(number) == "integer" and number or nil
end

local function hex_text(value, length)
  return type(value) == "string" and #value == length
    and value:match("^[0-9A-Fa-f]+$") ~= nil
end

local function hex_bounded(value, maximum)
  if type(value) ~= "string" or #value < 1 or #value > maximum
      or not value:match("^[0-9A-Fa-f]+$") then return nil end
  local number = tonumber(value, 16)
  return number and math.type(number) == "integer" and number or nil
end

local function interface(value)
  return type(value) == "string" and #value > 0 and #value <= 255
    and not value:find("[%z/%c]") and value or nil
end

local function ipv4_prefix(mask)
  local length, zero_seen = 0, false
  for octet in mask:gmatch("%d+") do
    local byte = tonumber(octet)
    if not byte or byte > 255 then return nil end
    for bit = 7, 0, -1 do
      if byte & (1 << bit) ~= 0 then
        if zero_seen then return nil end
        length = length + 1
      else zero_seen = true end
    end
  end
  return length
end

local function fields(line, maximum)
  local values = {}
  for value in line:gmatch("%S+") do
    values[#values + 1] = value
    if #values > maximum then return nil end
  end
  return values
end

local function ipv4(line, source)
  local parts = fields(line, 16)
  if not parts or #parts < 8 then return nil end
  local name = interface(parts[1])
  local flags, metric = hex_bounded(parts[4], 8), decimal(parts[7])
  local destination = SocketTables.decode_ipv4(parts[2])
  local gateway = SocketTables.decode_ipv4(parts[3])
  local mask = SocketTables.decode_ipv4(parts[8])
  local prefix = mask and ipv4_prefix(mask)
  if not name or not flags or not metric or not destination or not gateway
      or prefix == nil or #parts[2] ~= 8 or #parts[3] ~= 8
      or #parts[8] ~= 8 then return nil end
  return { family = "ipv4", interface = name, destination = destination,
    prefix_length = prefix, destination_cidr = destination .. "/" .. prefix,
    gateway = gateway ~= "0.0.0.0" and gateway or nil,
    metric = metric, flags = flags, up = flags & 1 ~= 0,
    default = destination == "0.0.0.0" and prefix == 0, source = source }
end

local function ipv6(line, source)
  local parts = fields(line, 10)
  if not parts or #parts ~= 10 then return nil end
  local name = interface(parts[10])
  local destination = SocketTables.decode_ipv6(parts[1], { little_endian = false })
  local source_address = SocketTables.decode_ipv6(parts[3], { little_endian = false })
  local gateway = SocketTables.decode_ipv6(parts[5], { little_endian = false })
  local prefix, source_prefix = hex(parts[2], 2), hex(parts[4], 2)
  local metric, flags = hex(parts[6], 8), hex(parts[9], 8)
  if not name or not destination or not source_address or not gateway
      or not prefix or prefix > 128 or not source_prefix or source_prefix > 128
      or not metric or not flags then return nil end
  return { family = "ipv6", interface = name, destination = destination,
    prefix_length = prefix, destination_cidr = destination .. "/" .. prefix,
    source_cidr = (source_address ~= "::" or source_prefix ~= 0)
      and (source_address .. "/" .. source_prefix) or nil,
    gateway = gateway ~= "::" and gateway or nil,
    metric = metric, flags = flags, up = flags & 1 ~= 0,
    default = destination == "::" and prefix == 0, source = source }
end

local function consume(result, content, family, source)
  local count = 0
  for line in content:gmatch("[^\n]+") do
    count = count + 1
    if count > M.MAX_LINES then
      result.truncated, result.partial = true, true
      break
    end
    if family == "ipv4" and line:match("^%s*Iface%s") then
      -- The first line is a header; kernel versions differ in its spacing.
    elseif #line > MAX_LINE_BYTES then
      result.invalid_lines, result.partial = result.invalid_lines + 1, true
    else
      local route = family == "ipv4" and ipv4(line, source) or ipv6(line, source)
      if route then
        result.total = result.total + 1
        if #result.entries < M.MAX_ENTRIES then
          result.entries[#result.entries + 1] = route
        else result.truncated, result.partial = true, true end
        if route.default and route.up then
          result.default_candidates[#result.default_candidates + 1] = route
        end
      elseif line:match("%S") then
        result.invalid_lines, result.partial = result.invalid_lines + 1, true
      end
    end
  end
end

-- The network-rate collector needs the active default interface on every
-- refresh. Most route fields do not: decoding thousands of prefixes at 1 Hz
-- costs more than the rate counters themselves. Scan the same bounded files
-- for default candidates without building the inventory or canonical IP text.
function M.default_routes(fs, ipv4_path, ipv6_path)
  local best = { ipv4 = { metric = nil, interfaces = {} },
    ipv6 = { metric = nil, interfaces = {} } }
  local partial, statuses = false, {}
  for _, spec in ipairs({
      { "ipv4", ipv4_path, 1024 * 1024 },
      { "ipv6", ipv6_path, 2 * 1024 * 1024 },
    }) do
    local content, err = fs:read(spec[2], spec[3])
    local status = content and "ok" or FS.error_status(err)
    statuses[spec[1] .. "_status"] = status
    if not content then
      if status ~= "unavailable" then partial = true end
    else
      local lines = 0
      for line in content:gmatch("[^\n]+") do
        lines = lines + 1
        if lines > M.MAX_LINES then partial = true; break end
        if spec[1] == "ipv4" and line:match("^%s*Iface%s") then
          -- Header.
        elseif #line > MAX_LINE_BYTES then
          partial = true
        else
          local first, destination = line:match("^%s*(%S+)%s+(%S+)")
          if not first or not destination then
            if line:match("%S") then partial = true end
          elseif (spec[1] == "ipv4" and destination == "00000000")
              or (spec[1] == "ipv6" and first == IPV6_ZERO) then
            local parts = fields(line, spec[1] == "ipv4" and 16 or 10)
            local name = parts and interface(parts[spec[1] == "ipv4" and 1 or 10])
            local metric, flags, is_default
            if spec[1] == "ipv4" and parts and #parts >= 8 then
              flags, metric = hex_bounded(parts[4], 8), decimal(parts[7])
              if not hex(parts[2], 8) or not hex(parts[3], 8)
                  or not hex(parts[8], 8) then name = nil end
              is_default = parts[8] == "00000000"
            elseif spec[1] == "ipv6" and parts and #parts == 10 then
              metric, flags = hex(parts[6], 8), hex(parts[9], 8)
              if not hex_text(parts[1], 32) or not hex(parts[2], 2)
                  or not hex_text(parts[3], 32) or not hex(parts[4], 2)
                  or not hex_text(parts[5], 32) then name = nil end
              is_default = parts[2] == "00"
            end
            if not name or not metric or not flags then
              partial = true
            elseif is_default and flags & 1 ~= 0 then
              local family = best[spec[1]]
              if family.metric == nil or metric < family.metric then
                family.metric, family.interfaces = metric, { [name] = true }
              elseif metric == family.metric then
                family.interfaces[name] = true
              end
            end
          end
        end
      end
    end
  end
  local defaults = {}
  for family, entry in pairs(best) do
    for name in pairs(entry.interfaces) do
      local current = defaults[name] or { families = {}, metrics = {} }
      current.families[family] = true
      current.metrics[family] = entry.metric
      current.metric = math.min(current.metric or math.huge, entry.metric)
      defaults[name] = current
    end
  end
  return defaults, partial, statuses
end

function M.read(fs, ipv4_path, ipv6_path)
  local result = { entries = {}, total = 0, invalid_lines = 0,
    truncated = false, partial = false, default_candidates = {},
    source = { ipv4_path, ipv6_path } }
  for _, spec in ipairs({
      { "ipv4", ipv4_path, 1024 * 1024 },
      { "ipv6", ipv6_path, 2 * 1024 * 1024 },
    }) do
    local content, err = fs:read(spec[2], spec[3])
    local status = content and "ok" or FS.error_status(err)
    result[spec[1] .. "_status"] = status
    if content then consume(result, content, spec[1], spec[2])
    elseif status ~= "unavailable" then result.partial = true end
  end
  local minimum = {}
  for _, route in ipairs(result.default_candidates) do
    minimum[route.family] = math.min(minimum[route.family] or math.huge, route.metric)
  end
  local defaults = {}
  local best_routes = {}
  for _, route in ipairs(result.default_candidates) do
    if route.metric == minimum[route.family] then
      route.selected_default = true
      best_routes[route.family] = best_routes[route.family] or route
      local current = defaults[route.interface] or { families = {}, metrics = {} }
      current.metrics[route.family] = route.metric
      current.metric = math.min(current.metric or math.huge, route.metric)
      current.families[route.family] = true
      defaults[route.interface] = current
    end
  end
  result.default_routes = defaults
  -- A full inventory must still show the chosen default routes, even when
  -- they appeared after the retention cap. The default-route summary above
  -- already considered every parsed line.
  local replacement = #result.entries
  for _, family in ipairs({ "ipv4", "ipv6" }) do
    local route = best_routes[family]
    if route then
      local retained = false
      for _, entry in ipairs(result.entries) do
        if entry == route then retained = true; break end
      end
      if not retained and replacement > 0 then
        result.entries[replacement] = route
        replacement = replacement - 1
      end
    end
  end
  result.default_candidates = nil
  table.sort(result.entries, function(left, right)
    if left.selected_default ~= right.selected_default then
      return left.selected_default == true
    end
    if left.default ~= right.default then return left.default end
    if left.family ~= right.family then return left.family < right.family end
    if left.interface ~= right.interface then return left.interface < right.interface end
    if left.prefix_length ~= right.prefix_length then
      return left.prefix_length > right.prefix_length
    end
    if left.destination ~= right.destination then return left.destination < right.destination end
    return left.metric < right.metric
  end)
  return result
end

return M
