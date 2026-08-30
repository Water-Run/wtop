package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Connections = require("wtop.collectors.connections")
local SocketTables = require("wtop.linux.socket_tables")

local function fixture(name)
  local file = assert(io.open("tests/fixtures/sockets/" .. name, "rb"))
  local content = assert(file:read("*a"))
  file:close()
  return content
end

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

local tcp = assert(SocketTables.parse(fixture("tcp"), "tcp", { little_endian = true }))
equal(#tcp.entries, 2, "TCP rows")
equal(tcp.error_count, 0, "TCP parse errors")
assert(not tcp.partial and tcp.header_seen)
local listen = tcp.entries[1]
equal(listen.local_address, "127.0.0.1", "IPv4 local address")
equal(listen.local_port, 8080, "IPv4 local port")
equal(listen.remote_endpoint.text, "0.0.0.0:0", "IPv4 wildcard endpoint")
equal(listen.state_code, "0A", "TCP state code")
equal(listen.state, "LISTEN", "TCP state")
equal(listen.uid, 1000, "TCP UID")
equal(listen.inode, "111", "TCP inode")
local established = tcp.entries[2]
equal(established.local_endpoint.text, "10.0.2.15:50000", "IPv4 client endpoint")
equal(established.remote_endpoint.text, "93.184.216.34:443", "IPv4 remote endpoint")
equal(established.state, "ESTABLISHED", "established state")
equal(established.tx_queue, 16, "TX queue")
equal(established.rx_queue, 32, "RX queue")

local tcp6 = assert(SocketTables.parse_inet(fixture("tcp6"), "tcp", "ipv6", {
  little_endian = true,
}))
equal(#tcp6.entries, 2, "TCP6 rows")
equal(tcp6.entries[1].local_endpoint.text, "[::1]:22", "IPv6 loopback endpoint")
equal(tcp6.entries[2].local_endpoint.text, "[2001:db8::1]:1234", "canonical IPv6 endpoint")
equal(tcp6.entries[2].remote_endpoint.text, "[::ffff:c000:201]:4321", "IPv4-mapped IPv6")
equal(assert(SocketTables.decode_ipv4("0100007F", { little_endian = true })), "127.0.0.1",
  "little-endian IPv4")
equal(assert(SocketTables.decode_ipv4("7F000001", { little_endian = false })), "127.0.0.1",
  "big-endian IPv4")
equal(assert(SocketTables.decode_ipv6("00000000000000000000000001000000", {
  little_endian = true,
})), "::1", "little-endian IPv6")
equal(assert(SocketTables.decode_ipv6("00000000000000000000000000000001", {
  little_endian = false,
})), "::1", "big-endian IPv6")
equal(assert(SocketTables.decode_ipv6("00000000000000000000000000000000", {
  little_endian = false,
})), "::", "all-zero IPv6")

local udp = assert(SocketTables.parse(fixture("udp"), "udp", { little_endian = true }))
equal(#udp.entries, 1, "UDP rows")
equal(udp.entries[1].local_endpoint.text, "0.0.0.0:53", "UDP endpoint")
equal(udp.entries[1].rx_queue, 8, "UDP receive queue")
local udp6 = assert(SocketTables.parse(fixture("udp6"), "udp6", { little_endian = true }))
equal(udp6.entries[1].local_endpoint.text, "[::1]:5353", "UDP6 endpoint")

local unix = assert(SocketTables.parse_unix(fixture("unix")))
equal(#unix.entries, 3, "UNIX rows")
equal(unix.entries[1].socket_type, "STREAM", "UNIX stream type")
equal(unix.entries[1].state, "UNCONNECTED", "UNIX state")
equal(unix.entries[1].path, "/run/wtop test.sock", "UNIX path with spaces")
equal(unix.entries[2].path, "@wtop-test", "abstract UNIX path")
equal(unix.entries[3].socket_type, "SEQPACKET", "UNIX seqpacket")
equal(unix.entries[3].path, nil, "unnamed UNIX socket")

local invalid = assert(SocketTables.parse(fixture("invalid.tcp"), "tcp", { little_endian = true }))
equal(#invalid.entries, 1, "valid row retained after malformed row")
equal(invalid.error_count, 1, "malformed row counted")
equal(invalid.errors[1].line, 2, "malformed row line")
assert(invalid.partial)
local line_limited = assert(SocketTables.parse(fixture("tcp"), "tcp", {
  little_endian = true, max_lines = 1,
}))
equal(#line_limited.entries, 1, "line limit entries")
assert(line_limited.truncated and line_limited.partial)
local byte_limited, byte_limit_error = SocketTables.parse(fixture("tcp"), "tcp", {
  max_bytes = #fixture("tcp") - 1,
})
equal(byte_limited, nil, "byte limit rejected")
equal(byte_limit_error, "socket_table_exceeds_max_bytes", "byte limit reason")
local long_line = "  sl  local_address rem_address\n" .. string.rep("x", 80) .. "\n"
local long_report = assert(SocketTables.parse(long_line, "tcp", { max_line_bytes = 32 }))
equal(long_report.error_count, 1, "line byte limit")
equal(long_report.errors[1].reason, "line_too_long", "line byte limit reason")
assert(SocketTables.parse("bad\nmore bad\n", "tcp", { max_errors = 1 }).error_count == 3)
assert(SocketTables.parse("", "unknown") == nil)
assert(SocketTables.parse(fixture("tcp"), "tcp", {
  max_bytes = SocketTables.HARD_MAX_BYTES + 1,
}) == nil)
assert(SocketTables.parse(fixture("tcp"), "tcp", "invalid") == nil)

local table_files = {
  ["/proc/net/tcp"] = fixture("tcp"),
  ["/proc/net/tcp6"] = fixture("tcp6"),
  ["/proc/net/udp"] = fixture("udp"),
  ["/proc/net/udp6"] = fixture("udp6"),
  ["/proc/net/unix"] = fixture("unix"),
  ["/proc/100/comm"] = "worker-a\n",
  ["/proc/300/comm"] = "worker-b\n",
}
local directories = {
  ["/proc"] = { "self", "300", "100", "not-a-pid", "200" },
  ["/proc/100/fd"] = { "9", "4", "3", "0", "not-a-fd" },
  ["/proc/200/fd"] = { error = { kind = "denied", message = "fixture_denied" } },
  ["/proc/300/fd"] = { "6", "5" },
}
local links = {
  ["/proc/100/fd/0"] = "socket:[555]",
  ["/proc/100/fd/3"] = "socket:[111]",
  ["/proc/100/fd/4"] = "socket:[222]",
  ["/proc/100/fd/9"] = "/tmp/ordinary-file",
  ["/proc/300/fd/5"] = "socket:[222]",
  ["/proc/300/fd/6"] = { error = { kind = "missing", message = "fixture_race" } },
}

local function fake_fs(files, dirs, symlinks)
  local fs = {}
  function fs:read(path, limit)
    local value = files[path]
    if type(value) == "table" and value.error then return nil, value.error end
    if value == nil then return nil, { kind = "missing", message = "fixture_missing", path = path } end
    if #value > limit then return nil, { kind = "too_large", message = "fixture_too_large" } end
    return value
  end
  function fs:list(path)
    local value = dirs[path]
    if type(value) == "table" and value.error then return nil, value.error end
    if value == nil then return nil, { kind = "missing", message = "fixture_missing", path = path } end
    local copy = {}
    for index, item in ipairs(value) do copy[index] = item end
    return copy
  end
  function fs:readlink(path)
    local value = symlinks[path]
    if type(value) == "table" and value.error then return nil, value.error end
    if value == nil then return nil, { kind = "missing", message = "fixture_missing", path = path } end
    return value
  end
  return fs
end

local now = 1000000000
local context = { now_ns = function() now = now + 10; return now end }
local base_fs = fake_fs(table_files, directories, links)
local collector = Connections.new({ fs = base_fs, little_endian = true })
assert(not pcall(Connections.new, "invalid"))
local capability = collector:probe(context)
assert(capability.available and capability.state == "available")
local result = collector:sample(context)
equal(result.status, "ok", "collector status")
equal(result.quality, "fresh", "collector quality without owner scan")
equal(result.data.total, 9, "collector total")
equal(result.data.counts.tcp, 2, "collector TCP count")
equal(result.data.counts.tcp6, 2, "collector TCP6 count")
equal(result.data.counts.udp, 1, "collector UDP count")
equal(result.data.counts.udp6, 1, "collector UDP6 count")
equal(result.data.counts.unix, 3, "collector UNIX count")
assert(not result.data.partial)
equal(result.data.owner_scan.status, "disabled", "owner scan disabled")
local ids = {}
for index, connection in ipairs(result.data.connections) do
  assert(type(connection.id) == "string" and connection.id ~= "")
  assert(not ids[connection.id])
  ids[connection.id] = true
  assert(result.data.by_id[connection.id] == connection)
  if index > 1 then
    assert(Connections.connection_order(result.data.connections[index - 1], connection)
      or result.data.connections[index - 1].base_id == connection.base_id)
  end
end
local repeated = collector:sample(context)
equal(table.concat((function()
  local values = {}; for index, item in ipairs(result.data.connections) do values[index] = item.id end; return values
end)(), ","), table.concat((function()
  local values = {}; for index, item in ipairs(repeated.data.connections) do values[index] = item.id end; return values
end)(), ","), "stable IDs and order")

local owner_collector = Connections.new({
  fs = base_fs,
  little_endian = true,
  scan_owners = true,
  max_processes = 10,
  max_fds_per_process = 10,
  max_total_links = 20,
  max_owners_per_socket = 2,
})
local owned = owner_collector:sample(context)
equal(owned.status, "ok", "owned collector status")
equal(owned.quality, "partial", "owner permission/race makes result partial")
assert(owned.data.partial and owned.data.owner_scan.partial)
equal(owned.data.owner_scan.process_candidates, 3, "PID candidates")
equal(owned.data.owner_scan.processes_considered, 3, "PIDs considered")
equal(owned.data.owner_scan.processes_denied, 1, "denied PID")
equal(owned.data.owner_scan.link_races, 1, "fd race")
equal(owned.data.owner_scan.owners_attached, 4, "owners attached")
local inode111 = assert(owned.data.by_inode["111"])[1]
equal(#inode111.owners, 1, "one listener owner")
equal(inode111.owners[1].pid, 100, "listener PID")
equal(inode111.owners[1].fd, 3, "listener fd")
equal(inode111.owners[1].name, "worker-a?", "sanitized process name")
local inode222 = assert(owned.data.by_inode["222"])[1]
equal(#inode222.owners, 2, "shared socket owners")
equal(inode222.owners[1].pid, 100, "stable owner order first")
equal(inode222.owners[2].pid, 300, "stable owner order second")
local inode555 = assert(owned.data.by_inode["555"])[1]
equal(inode555.owners[1].fd, 0, "fd zero is scanned")

local bounded_collector = Connections.new({
  fs = base_fs,
  little_endian = true,
  scan_owners = true,
  max_processes = 1,
  max_fds_per_process = 2,
  max_total_links = 1,
  max_owners_per_socket = 1,
})
local bounded = bounded_collector:sample(context)
assert(bounded.data.owner_scan.process_limit_reached)
assert(bounded.data.owner_scan.fd_truncated_processes > 0)
assert(bounded.data.owner_scan.link_limit_reached)
equal(bounded.data.owner_scan.links_examined, 1, "total link bound")

local owner_cap_collector = Connections.new({
  fs = base_fs,
  little_endian = true,
  scan_owners = true,
  max_owners_per_socket = 1,
})
local owner_capped = owner_cap_collector:sample(context)
equal(#assert(owner_capped.data.by_inode["222"])[1].owners, 1, "per-socket owner cap")
equal(owner_capped.data.owner_scan.owner_limit_sockets, 1, "owner cap reported once")

local malformed_files = {}
for path, value in pairs(table_files) do malformed_files[path] = value end
malformed_files["/proc/net/tcp"] = fixture("invalid.tcp")
local malformed_collector = Connections.new({
  fs = fake_fs(malformed_files, directories, links), little_endian = true,
})
local malformed_result = malformed_collector:sample(context)
equal(malformed_result.status, "ok", "malformed row does not fail sample")
equal(malformed_result.quality, "partial", "malformed row quality")
equal(malformed_result.data.tables.tcp.error_count, 1, "malformed table error")
equal(malformed_result.data.counts.tcp, 1, "malformed table valid rows")

local missing_files = {}
for path, value in pairs(table_files) do missing_files[path] = value end
missing_files["/proc/net/udp6"] = nil
local missing_result = Connections.new({
  fs = fake_fs(missing_files, directories, links), little_endian = true,
}):sample(context)
equal(missing_result.status, "ok", "single missing table does not fail sample")
equal(missing_result.quality, "partial", "single missing table quality")
equal(missing_result.data.tables.udp6.status, "unavailable", "missing table status")

local none = Connections.new({
  fs = fake_fs({}, {}, {}), little_endian = true,
}):sample(context)
equal(none.status, "unavailable", "all tables missing")
equal(none.data, nil, "all tables missing data")

local limited_result = Connections.new({
  fs = base_fs, little_endian = true, max_lines = 1,
}):sample(context)
equal(limited_result.status, "ok", "line-limited collector status")
equal(limited_result.quality, "partial", "line-limited quality")
assert(limited_result.data.tables.tcp.truncated)
assert(limited_result.data.tables.unix.truncated)

local largest_read = 0
local capped_fs = fake_fs(table_files, directories, links)
local capped_read = capped_fs.read
function capped_fs:read(path, limit)
  largest_read = math.max(largest_read, limit)
  return capped_read(self, path, limit)
end
assert(not pcall(Connections.new, {
  fs = capped_fs,
  little_endian = true,
  max_bytes = SocketTables.HARD_MAX_BYTES + 1,
}), "invalid hard byte limits must be rejected at construction")
equal(largest_read, 0, "invalid limits must not trigger filesystem reads")

-- Real procfs smoke test; owner scanning remains disabled to keep cost bounded
-- and deterministic for ordinary test runs.
local real = Connections.new():sample({})
equal(real.status, "ok", "real procfs socket tables")
assert(real.data.total >= 0 and real.data.owner_scan.status == "disabled")

return true
