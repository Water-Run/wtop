-- The TUI connection-table masking and the JSON export must agree on what a
-- masked endpoint looks like, and the switch must default to full display.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local Privacy = require("wtop.privacy")
local ViewModel = require("wtop.view_model")
local Config = require("wtop.config")
local Export = require("wtop.export")
local json = require("wtop.format.json")
local I18n = require("wtop.i18n")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

equal(Privacy.mask_address("192.0.2.42"), "192.0.2.x", "IPv4 keeps three octets")
equal(Privacy.mask_address("2001:db8:a:b:c:d:e:f"), "2001:db8:…",
  "IPv6 keeps two groups")
equal(Privacy.mask_address("::"), "::", "unspecified address unchanged")
equal(Privacy.mask_address(42), 42, "non-string values pass through")

equal(Privacy.masked_endpoint_text({ family = "ipv4", address = "192.0.2.42",
  port = 443, text = "192.0.2.42:443" }), "192.0.2.x:443", "IPv4 endpoint mask")
equal(Privacy.masked_endpoint_text({ family = "ipv6",
  address = "2001:db8:a:b:c:d:e:f", port = 22,
  text = "[2001:db8:a:b:c:d:e:f]:22" }), "[2001:db8:…]:22", "IPv6 endpoint mask")
equal(Privacy.masked_endpoint_text({ text = "opaque" }), "opaque",
  "endpoints without structured fields keep their text")

local snapshot = {
  cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, processes = {},
  cpu_frequency = {}, mounts = {}, workloads = {}, quality = {}, sensors = {},
  connections = { connections = {
    { id = "tcp:10.0.0.1:51000:203.0.113.9:443", table = "tcp",
      protocol = "tcp", family = "ipv4", state = "ESTABLISHED",
      local_address = "10.0.0.1", local_port = 51000,
      remote_address = "203.0.113.9", remote_port = 443,
      local_endpoint = { family = "ipv4", address = "10.0.0.1", port = 51000,
        text = "10.0.0.1:51000" },
      remote_endpoint = { family = "ipv4", address = "203.0.113.9", port = 443,
        text = "203.0.113.9:443" } },
    { id = "tcp6:local", table = "tcp6", protocol = "tcp", family = "ipv6",
      state = "ESTABLISHED",
      local_address = "2001:db8:1::1", local_port = 51001,
      remote_address = "2001:db8:a:b::9", remote_port = 443,
      local_endpoint = { family = "ipv6", address = "2001:db8:1::1", port = 51001,
        text = "[2001:db8:1::1]:51001" },
      remote_endpoint = { family = "ipv6", address = "2001:db8:a:b::9", port = 443,
        text = "[2001:db8:a:b::9]:443" } },
  } },
}
local engine = { history_values = function() return {} end }
local translator = assert(I18n.new({ locale = "en-US" }))

local plain = ViewModel.build(engine, snapshot, translator, {}, "network")
equal(plain.connection_table.rows[1].remote_endpoint, "203.0.113.9:443",
  "masking off shows the full remote endpoint")
equal(plain.connection_table.rows[2].remote_endpoint, "[2001:db8:a:b::9]:443",
  "masking off keeps IPv6 brackets")

local masked = ViewModel.build(engine, snapshot, translator, {}, "network",
  nil, nil, { mask_remote_addresses = true })
equal(masked.connection_table.rows[1].remote_endpoint, "203.0.113.x:443",
  "masking on truncates the remote IPv4 address")
equal(masked.connection_table.rows[2].remote_endpoint, "[2001:db8:…]:443",
  "masking on truncates the remote IPv6 address")
equal(masked.connection_table.rows[1].local_endpoint, "10.0.0.1:51000",
  "local endpoints are never masked")

-- The config default keeps today's full-display behaviour; the file key only
-- accepts booleans; snapshots keep masking by default regardless of config.
equal(Config.defaults().mask_remote_addresses, false, "default keeps full display")
local file_config = assert(Config.validate({ schema_version = 1,
  mask_remote_addresses = true }))
local resolved = Config.resolve({}, file_config)
equal(resolved.mask_remote_addresses, true, "file key enables masking")
local _, rejection = Config.validate({ mask_remote_addresses = "yes" })
equal(rejection, "mask_remote_addresses must be true or false",
  "non-boolean masking config is rejected")

local exported = Export.snapshot(snapshot, {})
local encoded = json.encode(exported)
assert(encoded:find("203.0.113.x", 1, true), "export masks remote addresses")
assert(not encoded:find("203.0.113.9", 1, true), "export never leaks the full remote address")

print("ok: privacy masking (table, config, export agree)")
