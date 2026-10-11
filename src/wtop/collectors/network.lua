local Capability = require("wtop.core.capability")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")
local Sysfs = require("wtop.linux.sysfs")
local Routes = require("wtop.linux.routes")

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

local QUEUE_SCAN_NS = 30 * 1000000000
local MAX_QUEUE_ENTRIES = 1024
local MAX_TX_TIMEOUT_READS = 512
local MAX_QUEUE_CONFIG_READS = 512
local MAX_CONFIG_QUEUES_PER_DIRECTION = 128
local MAX_CARRIER_READS = 768
local ROUTE_DETAIL_REFRESH_NS = 10 * 1000000000

local function same_default_routes(left, right)
  for name, route in pairs(left or {}) do
    local other = right and right[name]
    if not other then return false end
    for _, family in ipairs({ "ipv4", "ipv6" }) do
      if (route.families and route.families[family] or false)
          ~= (other.families and other.families[family] or false)
          or (route.metrics and route.metrics[family])
          ~= (other.metrics and other.metrics[family]) then return false end
    end
  end
  for name in pairs(right or {}) do
    if not left or not left[name] then return false end
  end
  return true
end

local function softnet_sample(fs, path, now, previous)
  local content, read_error = fs:read(path, 1024 * 1024)
  if not content then
    local status = FS.error_status(read_error)
    return { status = status, quality = status, source = path,
      reason = read_error and read_error.message }
  end
  local parsed, parse_error = Parsers.softnet_stat(content)
  if not parsed then
    return { status = "error", quality = "error", source = path,
      reason = parse_error }
  end
  local rows = parsed.rows
  local result = { status = "ok", quality = "gap", source = path,
    observed_ns = now, cpu_count = #rows, per_cpu = rows,
    processed = 0, dropped = 0, time_squeeze = 0 }
  local backlog, input_backlog, process_backlog = 0, 0, 0
  local detailed_backlog = true
  for _, row in ipairs(rows) do
    row.quality = "gap"
    result.processed = result.processed + row.processed
    result.dropped = result.dropped + row.dropped
    result.time_squeeze = result.time_squeeze + row.time_squeeze
    if row.backlog_packets then
      backlog = backlog + row.backlog_packets
      if result.hot_cpu == nil or row.backlog_packets > result.hot_cpu_backlog then
        result.hot_cpu, result.hot_cpu_backlog = row.cpu, row.backlog_packets
      end
    end
    if row.input_backlog_packets and row.process_backlog_packets then
      input_backlog = input_backlog + row.input_backlog_packets
      process_backlog = process_backlog + row.process_backlog_packets
    else
      detailed_backlog = false
    end
  end
  if parsed.indexed then
    result.backlog_packets = backlog
    if result.hot_cpu_backlog == 0 then
      result.hot_cpu, result.hot_cpu_backlog = nil, nil
    end
    if detailed_backlog then
      result.input_backlog_packets = input_backlog
      result.process_backlog_packets = process_backlog
    end
  else
    result.reason = "softnet_cpu_ids_missing"
    return result
  end

  if type(previous) ~= "table" or previous.status ~= "ok"
      or type(previous.observed_ns) ~= "number" then
    result.reason = "first_sample"
    return result
  end
  local elapsed = Common.elapsed_ns(now, previous.observed_ns)
  if not elapsed or elapsed <= 0 then
    result.reason = "invalid_interval"
    return result
  end
  if #rows ~= previous.cpu_count then
    result.reason = "softnet_cpu_set_changed"
    return result
  end
  local old_by_cpu = {}
  for _, row in ipairs(previous.per_cpu or {}) do
    if type(row.cpu) == "number" then old_by_cpu[row.cpu] = row end
  end
  local updates = {}
  local totals = { processed = 0, dropped = 0, time_squeeze = 0 }
  for index, row in ipairs(rows) do
    local old = old_by_cpu[row.cpu]
    if not old then
      result.reason = "softnet_cpu_set_changed"
      return result
    end
    local update = {}
    for _, key in ipairs({ "processed", "dropped", "time_squeeze" }) do
      local delta, why = Common.delta(row[key], old[key])
      if delta == nil then
        result.quality = why == "reset" and "reset" or "gap"
        result.reason = why == "reset" and "counter_reset" or "softnet_counter_missing"
        if result.quality == "reset" then
          for _, candidate in ipairs(rows) do candidate.quality = "reset" end
        end
        return result
      end
      update[key] = delta
      totals[key] = totals[key] + delta
    end
    updates[index] = update
  end
  local seconds = elapsed / 1000000000
  for index, row in ipairs(rows) do
    row.quality = "fresh"
    row.processed_per_second = updates[index].processed / seconds
    row.dropped_per_second = updates[index].dropped / seconds
    row.time_squeeze_per_second = updates[index].time_squeeze / seconds
  end
  result.quality = "fresh"
  result.interval_ns = elapsed
  result.new_processed = totals.processed
  result.new_dropped = totals.dropped
  result.new_time_squeeze = totals.time_squeeze
  result.processed_per_second = totals.processed / seconds
  result.dropped_per_second = totals.dropped / seconds
  result.time_squeeze_per_second = totals.time_squeeze / seconds
  return result
end

local function queue_integer(fs, path)
  local raw, err = fs:read(path, 64)
  if type(raw) ~= "string" then return nil, FS.error_status(err) end
  local digits = Common.trim(raw):match("^(%d+)$")
  local value = digits and tonumber(digits)
  if value and math.type(value) == "integer" and value >= 0 then return value end
  return nil, "error"
end

local function carrier_events(fs, base, now, previous, budget)
  if budget.remaining < 3 then
    return { status = "truncated", observed_ns = now,
      change = { quality = "gap", reason = "carrier_scan_budget" } }
  end
  budget.remaining = budget.remaining - 3
  local changes, changes_status = queue_integer(fs, base .. "/carrier_changes")
  local up, up_status = queue_integer(fs, base .. "/carrier_up_count")
  local down, down_status = queue_integer(fs, base .. "/carrier_down_count")
  local available = (changes and 1 or 0) + (up and 1 or 0) + (down and 1 or 0)
  local status
  if available == 3 then status = "ok"
  elseif available > 0 then status = "partial"
  elseif changes_status == "denied" or up_status == "denied"
      or down_status == "denied" then status = "denied"
  elseif changes_status == "error" or up_status == "error"
      or down_status == "error" then status = "error"
  else status = "unavailable" end
  local result = {
    status = status, observed_ns = now, changes_total = changes,
    up_total = up, down_total = down,
    changes_status = changes_status, up_status = up_status,
    down_status = down_status,
    change = { quality = "gap", reason = "first_sample" },
  }
  if changes == nil then
    result.change.reason = "carrier_counter_missing"
    return result
  end
  if type(previous) ~= "table" or type(previous.changes_total) ~= "number"
      or type(previous.observed_ns) ~= "number" then return result end
  local interval = Common.elapsed_ns(now, previous.observed_ns)
  if not interval or interval <= 0 then
    result.change.reason = "invalid_interval"
    return result
  end
  local delta, delta_reason = Common.delta(changes, previous.changes_total)
  if delta == nil then
    result.change = { quality = delta_reason == "reset" and "reset" or "gap",
      reason = delta_reason == "reset" and "counter_reset" or "carrier_counter_missing" }
    return result
  end
  local change = { quality = "fresh", new_changes = delta, interval_ns = interval }
  for _, spec in ipairs({ { "up_total", "new_up" }, { "down_total", "new_down" } }) do
    if type(result[spec[1]]) == "number" and type(previous[spec[1]]) == "number" then
      local value, why = Common.delta(result[spec[1]], previous[spec[1]])
      if value == nil and why == "reset" then
        result.change = { quality = "reset", reason = "counter_reset" }
        return result
      end
      change[spec[2]] = value
    end
  end
  if type(change.new_up) == "number" and type(change.new_down) == "number"
      and change.new_up + change.new_down ~= change.new_changes then
    -- The three sysfs attributes are separate atomic reads, not one atomic
    -- snapshot. Keep the total delta but do not publish contradictory parts.
    change.new_up, change.new_down = nil, nil
    change.components_quality = "gap"
    result.status = "partial"
  end
  result.change = change
  return result
end

local function queue_mask(fs, path)
  local raw, err = fs:read(path, 512)
  if type(raw) ~= "string" then return nil, FS.error_status(err) end
  local value = Common.trim(raw)
  if value == "" or #value > 512 or not value:match("^[%x,]+$")
      or value:sub(1, 1) == "," or value:sub(-1) == ","
      or value:find(",,", 1, true) then return nil, "error" end
  return value:lower()
end

local function queue_config(fs, base, rx_ids, tx_ids, budget)
  local config = { rx = {}, tx = {} }
  local values, partial = 0, false
  local function inspect(direction, ids, specifications)
    if #ids > MAX_CONFIG_QUEUES_PER_DIRECTION then partial = true end
    for index = 1, math.min(#ids, MAX_CONFIG_QUEUES_PER_DIRECTION) do
      if budget.remaining == 0 then partial = true break end
      local id = ids[index]
      local row = { id = id }
      for _, spec in ipairs(specifications) do
        if budget.remaining == 0 then partial = true break end
        budget.remaining = budget.remaining - 1
        local value, status = spec[3](fs,
          base .. "/queues/" .. direction .. "-" .. id .. "/" .. spec[1])
        if value ~= nil then
          row[spec[2]] = value
          values = values + 1
          if spec[2] == "maxrate_mbps" then
            row.rate_limit_enabled = value > 0
          end
        elseif status ~= "unavailable" then
          partial = true
          row.issues = row.issues or {}
          row.issues[#row.issues + 1] = { field = spec[1], status = status }
        end
      end
      config[direction][#config[direction] + 1] = row
    end
  end
  inspect("rx", rx_ids, {
    { "rps_cpus", "rps_cpus", queue_mask },
    { "rps_flow_cnt", "rps_flow_count", queue_integer },
  })
  inspect("tx", tx_ids, {
    { "xps_cpus", "xps_cpus", queue_mask },
    { "xps_rxqs", "xps_rxqs", queue_mask },
    { "tx_maxrate", "maxrate_mbps", queue_integer },
  })
  config.status = partial and "partial" or values > 0 and "ok" or "unavailable"
  return config
end

local function queue_topology(fs, base, now_ns, timeout_budget, config_budget, previous)
  local entries, err, truncated = fs:list(base .. "/queues", MAX_QUEUE_ENTRIES)
  if type(entries) ~= "table" then
    return { status = FS.error_status(err), scanned_ns = now_ns }
  end
  local rx_count, tx_count = 0, 0
  local rx_ids, tx_ids, seen = {}, {}, {}
  local partial = truncated == true or #entries > MAX_QUEUE_ENTRIES
  for index = 1, math.min(#entries, MAX_QUEUE_ENTRIES) do
    local name = entries[index]
    if type(name) == "string" then
      local direction, number = name:match("^(rx)%-([0-9]+)$")
      if not direction then direction, number = name:match("^(tx)%-([0-9]+)$") end
      if direction then
        local queue = tonumber(number)
        if queue and math.type(queue) == "integer" and queue >= 0
            and tostring(queue) == number then
          local identity = direction .. ":" .. queue
          if seen[identity] then partial = true
          else
            seen[identity] = true
            if direction == "rx" then
              rx_count = rx_count + 1
              rx_ids[#rx_ids + 1] = queue
            else
              tx_count = tx_count + 1
              tx_ids[#tx_ids + 1] = queue
            end
          end
        else partial = true end
      elseif name:match("^rx%-") or name:match("^tx%-") then
        partial = true
      end
    end
  end
  local result = { rx_count = rx_count, tx_count = tx_count,
    status = partial and "partial" or "ok", scanned_ns = now_ns }
  table.sort(rx_ids)
  table.sort(tx_ids)
  local config = queue_config(fs, base, rx_ids, tx_ids, config_budget)
  result.rx_details, result.tx_details, result.config_status =
    config.rx, config.tx, partial and "partial" or config.status
  if tx_count == 0 then return result end
  result.tx_timeouts = {}
  local total, valid, scanned, failure, mixed, overflow = 0, 0, 0, nil, false, false
  for _, id in ipairs(tx_ids) do
    if timeout_budget.remaining == 0 then break end
    timeout_budget.remaining = timeout_budget.remaining - 1
    scanned = scanned + 1
    local value, status = queue_integer(fs,
      base .. "/queues/tx-" .. id .. "/tx_timeout")
    if value ~= nil then
      valid = valid + 1
      if value > math.maxinteger - total then overflow = true
      else total = total + value end
      result.tx_timeouts[#result.tx_timeouts + 1] = { id = id, total = value }
    else
      if failure and failure ~= status then mixed = true end
      failure = status
      result.tx_timeouts[#result.tx_timeouts + 1] = { id = id, status = status }
    end
  end
  if not partial and scanned == tx_count and valid == tx_count and not overflow then
    result.tx_timeout_total = total
    result.timeout_status = "ok"
  elseif not partial and scanned == tx_count and valid == 0 and not mixed then
    result.timeout_status = failure or "unavailable"
  else
    result.timeout_status = "partial"
  end
  local previous_by_id = {}
  local comparable = type(previous) == "table" and previous.status == "ok"
    and previous.timeout_status == "ok" and result.status == "ok"
    and result.timeout_status == "ok" and previous.tx_count == tx_count
    and type(previous.scanned_ns) == "number" and now_ns > previous.scanned_ns
  if comparable then
    for _, old in ipairs(previous.tx_timeouts or {}) do
      previous_by_id[old.id] = old
    end
  end
  local new_total, complete, reset = 0, comparable, false
  for _, counter in ipairs(result.tx_timeouts) do
    local old = comparable and previous_by_id[counter.id] or nil
    local change, delta_state
    if old then change, delta_state = Common.delta(counter.total, old.total) end
    if change ~= nil then
      counter.change = { new_reports = change, quality = "fresh" }
      if change > math.maxinteger - new_total then complete = false
      else new_total = new_total + change end
    else
      counter.change = { quality = delta_state == "reset" and "reset" or "gap" }
      complete = false
      reset = reset or delta_state == "reset"
    end
  end
  result.timeout_change = complete
    and { new_reports = new_total, quality = "fresh",
      interval_seconds = (now_ns - previous.scanned_ns) / 1000000000 }
    or { quality = reset and "reset" or "gap" }
  return result
end

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
    softnet_path = Common.absolute_path(
      "softnet_path", options.softnet_path, "/proc/net/softnet_stat"),
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

local function default_routes(fs, ipv4_path, ipv6_path)
  return Routes.default_routes(fs, ipv4_path, ipv6_path)
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
  local softnet = softnet_sample(fs, self.softnet_path, now,
    previous_data and previous_data.softnet)
  local elapsed_ns = previous_data and Common.elapsed_ns(now, previous.timestamp_ns) or nil
  local old_by_ifindex = previous_data and previous_data.raw_by_ifindex or {}
  local old_interfaces = {}
  local timeout_budget = { remaining = MAX_TX_TIMEOUT_READS }
  local config_budget = { remaining = MAX_QUEUE_CONFIG_READS }
  local carrier_budget = { remaining = MAX_CARRIER_READS }
  for _, interface in ipairs(previous_data and previous_data.interfaces or {}) do
    if type(interface.ifindex) == "number" then
      old_interfaces[interface.ifindex] = interface
    end
  end
  local interfaces = {}
  local raw_by_name = {}
  local raw_by_ifindex = {}
  local any_gap = false
  local scan_routes = context and context.scan_routes == true
  local routes, routes_partial, route_data
  if scan_routes then
    local held = previous_data and previous_data.routes
    local recent = held and (held.quality == "fresh" or held.quality == "partial")
      and type(held.observed_ns) == "number" and now >= held.observed_ns
      and now - held.observed_ns < ROUTE_DETAIL_REFRESH_NS
      and context.force_route_refresh ~= true
    if recent then
      routes, routes_partial = default_routes(fs, self.route_path, self.ipv6_route_path)
      if not routes_partial and same_default_routes(routes, held.default_routes) then
        route_data = held
      end
    end
    if not route_data then
      route_data = Routes.read(fs, self.route_path, self.ipv6_route_path)
      route_data.observed_ns = now
      route_data.quality = route_data.partial and "partial" or "fresh"
      routes, routes_partial = route_data.default_routes, route_data.partial
    end
    context.force_route_refresh = false
  else
    routes, routes_partial = default_routes(fs, self.route_path, self.ipv6_route_path)
    local held = previous_data and previous_data.routes
    if type(held) == "table" then
      route_data = {}
      for key, value in pairs(held) do route_data[key] = value end
      route_data.quality = "stale"
    end
  end
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
    local device_path = Sysfs.device_path(fs, base)
    local old_interface = ifindex and old_interfaces[ifindex]
    local iflink = fs:read_number(base .. "/iflink")
    local old_carrier = old_interface and old_interface.name == current.name
      and old_interface.device_path == device_path
      and old_interface.iflink == iflink and old_interface.link_events or nil
    local link_events = carrier_events(fs, base, now, old_carrier, carrier_budget)
    local old_queues = old_interface and old_interface.name == current.name
      and old_interface.device_path == device_path and old_interface.queues or nil
    local queues = old_queues and type(old_queues.scanned_ns) == "number"
      and now >= old_queues.scanned_ns
      and now - old_queues.scanned_ns < QUEUE_SCAN_NS and old_queues
      or queue_topology(fs, base, now, timeout_budget, config_budget, old_queues)
    local interface = {
      id = ifindex or current.name,
      ifindex = ifindex,
      name = current.name,
      source = base,
      device_path = device_path,
      operstate = optional_text(fs, base .. "/operstate"),
      mtu = (function()
        local value = fs:read_number(base .. "/mtu")
        return type(value) == "number" and value % 1 == 0 and value > 0 and value or nil
      end)(),
      speed_mbps = speed,
      iflink = iflink,
      link_type = fs:read_number(base .. "/type"),
      carrier = fs:read_number(base .. "/carrier"),
      duplex = optional_text(fs, base .. "/duplex"),
      address = optional_text(fs, base .. "/address"),
      addresses = addresses_by_name and addresses_by_name[current.name] or nil,
      default_route = routes[current.name],
      queues = queues,
      link_events = link_events,
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
  -- The reason is chosen by the expression that chooses the quality, and the
  -- test it has to pass is the one this file records for a single reason slot:
  -- **there must be a sentence that is true in every case that produces this
  -- quality.**  For `partial`, the route data is incomplete when a file was
  -- refused, a row was malformed, or the bounded view was cut. For `gap`, an
  -- interface is left `gap` when it has no
  -- previous sample, when no interval has elapsed, or when a counter could not
  -- be differenced, and all three mean that no rate exists for it this tick.
  -- Which route file was refused, and which counter moved backwards, stay where
  -- they already are: `addresses_status` and `interface.reset_counter`.
  --
  -- Disk is the case that fails this test, and it is why the test is written
  -- down rather than assumed.  Its `partial` has three causes -- the caller's
  -- `include` predicate raised, the slave enumeration hit its cap, and the
  -- slaves file was refused -- and the first of them is not a partial read at
  -- all, so no sentence is true of all three.  That is a different fix.
  local quality = routes_partial and "partial" or (any_gap and "gap" or "fresh")
  return Common.result("ok", now, {
    interfaces = interfaces,
    addresses_status = addresses_by_name and (addresses_note or "ok") or addresses_note,
    default_routes = routes,
    routes = route_data,
    raw_by_name = raw_by_name,
    raw_by_ifindex = raw_by_ifindex,
    softnet = softnet,
  }, {
    quality = quality,
    reason = routes_partial and "route_data_incomplete"
      or (any_gap and "network_rate_unavailable" or nil),
    duration_ns = Common.elapsed_ns(now, started) or 0,
    source = { self.netdev_path, self.route_path, self.ipv6_route_path,
      self.softnet_path, self.sys_class_path },
  })
end

Network.default_routes = default_routes

return Network
