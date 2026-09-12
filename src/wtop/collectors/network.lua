local Capability = require("wtop.core.capability")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local Network = {}
Network.__index = Network

local COUNTERS = {
  "rx_bytes",
  "rx_packets",
  "rx_errors",
  "rx_drops",
  "tx_bytes",
  "tx_packets",
  "tx_errors",
  "tx_drops",
}

function Network.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Network options must be a table", 2) end
  return setmetatable({
    id = "network",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    fs = options.fs or FS.default,
    netdev_path = Common.absolute_path("netdev_path", options.netdev_path, "/proc/net/dev"),
    route_path = Common.absolute_path("route_path", options.route_path, "/proc/net/route"),
    ipv6_route_path = Common.absolute_path(
      "ipv6_route_path", options.ipv6_route_path, "/proc/net/ipv6_route"),
    sys_class_path = Common.absolute_path(
      "sys_class_path", options.sys_class_path, "/sys/class/net"),
    native = options.native,
    _method_style = true,
  }, Network)
end

function Network:probe(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.netdev_path, 1024 * 1024)
  if content then
    return Capability.available({ source = self.netdev_path })
  end
  local status = FS.error_status(err)
  if status == "denied" then
    return Capability.denied(err.message, { source = self.netdev_path })
  end
  return Capability.unavailable(err and err.message or "netdev_unavailable", { source = self.netdev_path })
end

local function optional_text(fs, path)
  local value = fs:read(path, 4096)
  return value and Common.safe_text(Common.trim(value), 4096) or nil
end

local function decimal_integer(value)
  if type(value) ~= "string" or not value:match("^%d+$") then return nil end
  local number = tonumber(value)
  return number and math.type(number) == "integer" and number or nil
end

local function hexadecimal_integer(value, digits)
  if type(value) ~= "string" or #value < 1 or #value > digits
      or not value:match("^[0-9A-Fa-f]+$") then return nil end
  local number = tonumber(value, 16)
  return number and math.type(number) == "integer" and number or nil
end

local function default_routes(fs, ipv4_path, ipv6_path)
  local candidates = {}
  local partial = false
  local ipv4, ipv4_error = fs:read(ipv4_path, 1024 * 1024)
  if not ipv4 and ipv4_error and ipv4_error.kind ~= "missing"
      and ipv4_error.kind ~= "unavailable" then partial = true end
  if ipv4 then
    local lines = 0
    for line in ipv4:gmatch("[^\n]+") do
      lines = lines + 1
      if lines > 131072 then partial = true break end
      local fields = {}
      for value in line:gmatch("%S+") do fields[#fields + 1] = value end
      if line:match("^%s*Iface%s") then
        -- Header.
      elseif #fields >= 8 and fields[2]:match("^[0-9A-Fa-f]+$")
          and fields[8]:match("^[0-9A-Fa-f]+$") then
        local flags = hexadecimal_integer(fields[4], 8)
        local metric = decimal_integer(fields[7])
        if fields[2] == "00000000" and fields[8] == "00000000"
            and flags and metric and flags % 2 == 1
            and type(fields[1]) == "string" and #fields[1] <= 255
            and not fields[1]:find("/", 1, true) then
          candidates[#candidates + 1] = {
            name = fields[1], metric = metric, family = "ipv4",
          }
        elseif not flags or not metric then
          partial = true
        end
      elseif #fields > 0 then partial = true
      end
    end
  end
  local ipv6, ipv6_error = fs:read(ipv6_path, 2 * 1024 * 1024)
  if not ipv6 and ipv6_error and ipv6_error.kind ~= "missing"
      and ipv6_error.kind ~= "unavailable" then partial = true end
  if ipv6 then
    local lines = 0
    for line in ipv6:gmatch("[^\n]+") do
      lines = lines + 1
      if lines > 131072 then partial = true break end
      local fields = {}
      for value in line:gmatch("%S+") do fields[#fields + 1] = value end
      local metric = #fields >= 10 and hexadecimal_integer(fields[6], 8) or nil
      local valid = #fields >= 10 and #fields[1] == 32
        and fields[1]:match("^[0-9A-Fa-f]+$") and #fields[2] == 2
        and fields[2]:match("^[0-9A-Fa-f]+$") and metric
        and #fields[10] <= 255 and not fields[10]:find("/", 1, true)
      if valid then
        if fields[1] == string.rep("0", 32) and fields[2] == "00" then
          candidates[#candidates + 1] = {
            name = fields[10], metric = metric, family = "ipv6",
          }
        end
      elseif #fields > 0 then
        partial = true
      end
    end
  end
  local minimum = {}
  for _, candidate in ipairs(candidates) do
    minimum[candidate.family] = math.min(minimum[candidate.family] or math.huge, candidate.metric)
  end
  local result = {}
  for _, candidate in ipairs(candidates) do
    if candidate.metric == minimum[candidate.family] then
      local route = result[candidate.name] or { families = {} }
      route.metric = candidate.metric
      route.families[candidate.family] = true
      result[candidate.name] = route
    end
  end
  return result, partial
end


-- getifaddrs(3) is the only reliable source for IPv4 addresses; procfs exposes
-- IPv6 through /proc/net/if_inet6 but has no IPv4 equivalent short of an ioctl.
-- A missing or failing native module simply leaves interfaces without
-- addresses rather than degrading the rest of the sample.
local MAX_ADDRESSES_PER_INTERFACE = 16

local function interface_addresses(native)
  if type(native) ~= "table" or type(native.interface_addresses) ~= "function" then
    return nil, "native_unavailable"
  end
  local ok, entries = pcall(native.interface_addresses)
  if not ok or type(entries) ~= "table" then
    return nil, "interface_addresses_failed"
  end
  local by_name = {}
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and type(entry.interface) == "string"
        and type(entry.address) == "string" and entry.family ~= "link" then
      local bucket = by_name[entry.interface]
      if not bucket then
        bucket = {}
        by_name[entry.interface] = bucket
      end
      if #bucket < MAX_ADDRESSES_PER_INTERFACE then
        bucket[#bucket + 1] = {
          family = entry.family,
          address = Common.safe_text(entry.address, 64),
          netmask = type(entry.netmask) == "string"
            and Common.safe_text(entry.netmask, 64) or nil,
          broadcast = type(entry.broadcast) == "string"
            and Common.safe_text(entry.broadcast, 64) or nil,
          peer = type(entry.peer) == "string"
            and Common.safe_text(entry.peer, 64) or nil,
        }
      end
    end
  end
  return by_name, entries.truncated == true and "truncated" or nil
end

function Network:sample(context, previous)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.netdev_path, 1024 * 1024)
  if not content then
    return Common.error_result(err, Common.now_ns(context), self.netdev_path)
  end
  local raw, parse_error = Parsers.net_dev(content)
  if not raw then
    return Common.result("error", Common.now_ns(context), nil, {
      quality = "error",
      reason = parse_error,
      source = self.netdev_path,
    })
  end
  local now = Common.now_ns(context)
  local previous_data = Common.previous_data(previous)
  local elapsed_ns = previous_data and Common.elapsed_ns(now, previous.timestamp_ns) or nil
  local old_by_ifindex = previous_data and previous_data.raw_by_ifindex or {}
  local interfaces = {}
  local raw_by_name = {}
  local raw_by_ifindex = {}
  local any_gap = false
  local routes, routes_partial = default_routes(fs, self.route_path, self.ipv6_route_path)
  local has_default_route = next(routes) ~= nil
  local addresses_by_name, addresses_note = interface_addresses(
    self.native or (context and context.native))

  for _, current in ipairs(raw) do
    raw_by_name[current.name] = current
    local base = self.sys_class_path .. "/" .. current.name
    local ifindex = fs:read_number(base .. "/ifindex")
    if type(ifindex) ~= "number" or ifindex % 1 ~= 0 or ifindex <= 0
        or ifindex > 2147483647 then ifindex = nil end
    if ifindex then
      -- Keep the counter sample and its stable kernel identity together.  A
      -- name may be reused or renamed without representing the same link.
      current.ifindex = ifindex
      raw_by_ifindex[ifindex] = current
    end
    local speed = fs:read_number(base .. "/speed")
    if type(speed) ~= "number" or speed ~= speed or speed == math.huge
        or speed == -math.huge or speed <= 0 then
      speed = nil
    end
    local aggregate = current.name ~= "lo"
    if has_default_route then aggregate = routes[current.name] ~= nil end
    local interface = {
      id = ifindex or current.name,
      ifindex = ifindex,
      name = current.name,
      operstate = optional_text(fs, base .. "/operstate"),
      mtu = (function()
        local value = fs:read_number(base .. "/mtu")
        return type(value) == "number" and value % 1 == 0 and value > 0 and value or nil
      end)(),
      speed_mbps = speed,
      iflink = fs:read_number(base .. "/iflink"),
      link_type = fs:read_number(base .. "/type"),
      carrier = fs:read_number(base .. "/carrier"),
      duplex = optional_text(fs, base .. "/duplex"),
      address = optional_text(fs, base .. "/address"),
      addresses = addresses_by_name and addresses_by_name[current.name] or nil,
      default_route = routes[current.name],
      aggregate = aggregate,
      counters = current,
      quality = "gap",
      rates = {},
    }
    local old = ifindex and old_by_ifindex[ifindex] or nil
    if old and elapsed_ns and elapsed_ns > 0 then
      local valid = true
      for _, key in ipairs(COUNTERS) do
        local rate = Common.rate(current[key], old[key], elapsed_ns)
        if rate == nil then
          valid = false
          interface.reset_counter = key
          break
        end
        interface.rates[key .. "_per_second"] = rate
      end
      if valid then
        interface.quality = ifindex and "fresh" or "estimated"
      end
    end
    any_gap = any_gap or interface.quality == "gap"
    interfaces[#interfaces + 1] = interface
  end

  table.sort(interfaces, function(left, right)
    if left.ifindex and right.ifindex then
      return left.ifindex < right.ifindex
    end
    return left.name < right.name
  end)
  return Common.result("ok", now, {
    interfaces = interfaces,
    addresses_status = addresses_by_name and (addresses_note or "ok") or addresses_note,
    default_routes = routes,
    raw_by_name = raw_by_name,
    raw_by_ifindex = raw_by_ifindex,
  }, {
    quality = routes_partial and "partial" or (any_gap and "gap" or "fresh"),
    duration_ns = Common.elapsed_ns(now, started) or 0,
    source = { self.netdev_path, self.route_path, self.ipv6_route_path, self.sys_class_path },
  })
end

Network.default_routes = default_routes

return Network
