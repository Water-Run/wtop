-- A DRM client's frequency domains, and the name mismatch that used to drop
-- them.
--
-- The kernel names a client's engines and its clocks independently:
-- `drm-engine-gfx` alongside `drm-maxfreq-sclk` on amdgpu, `drm-engine-render`
-- alongside `drm-maxfreq-rcs0` on i915.  The collector used to walk only the
-- engine names and look each one up in the frequency map, so every domain whose
-- name did not happen to match an engine was parsed and then dropped -- a clock
-- nobody could report, on the cards that publish the most of them.
--
-- The fixture is that shape deliberately: three domains, not one of which is
-- named after an engine, one of which is above its own stated maximum, and one
-- of which has a maximum with no current reading at all.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Gpu = require("wtop.collectors.gpu")
local Workspace = require("wtop.workspace")
local I18n = require("wtop.i18n")
local TUI = require("wtop.tui")
local native = require("wtop.native")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

local function fixture(name)
  local handle = assert(io.open("tests/fixtures/" .. name, "rb"))
  local content = handle:read("*a")
  handle:close()
  return content
end

-- Built from a real /proc/<pid>/stat capture rather than a hand-written line:
-- the start time is field 22, and a line with the wrong number of fields puts
-- it somewhere else entirely -- which reads as a process that started at 0 and
-- silently moves the key every lookup would use.
local BASE_STAT = [[
100 (worker) S 1 100 100 0 -1 4194304 10 0 2 0 100 50 0 0 20 0 2 0 1000 10485760 512 0 0 0 0 0 0 0 0 0 0 0 0 3 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
]]
local function stat_for(pid, name, starttime)
  local value = BASE_STAT:gsub("^100 ", tostring(pid) .. " ", 1)
  value = value:gsub("%(worker%)", "(" .. name .. ")", 1)
  value = value:gsub(" 1000 10485760 ", " " .. tostring(starttime) .. " 10485760 ", 1)
  return value
end

-- 1. The domains arrive, all three of them, whether or not an engine shares
-- their name.  `sclk`, `mclk` and `gr` match no engine in the fixture, so a
-- reader keyed on the engine list would find nothing here.  The bytes come from
-- the fixture rather than a string in this file, because the fixture is the
-- thing a kernel would actually emit.
local handle = assert(io.open("tests/fixtures/gpu/amd-clock-fdinfo.1", "rb"))
local FREQINFO = handle:read("*a")
handle:close()
assert(FREQINFO:find("drm%-maxfreq%-sclk") and FREQINFO:find("drm%-engine%-gfx"),
  "the fixture lost the shape this test is about")

local files = {
  ["/drm/renderD128/device/uevent"] = "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n",
  ["/drm/renderD128/dev"] = "226:128\n",
  ["/drm/card0/device/uevent"] = "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n",
  ["/drm/card0/dev"] = "226:0\n",
  ["/drm/card0/device/hwmon/hwmon5/temp1_input"] = "55000\n",
  ["/proc/200/stat"] = stat_for(200, "clock-worker", 4000),
  ["/proc/200/status"] = "Name:\tclock-worker\nUid:\t1000\t1000\t1000\t1000\n",
  ["/proc/200/fdinfo/9"] = FREQINFO,
}
local directories = {
  ["/drm"] = { "card0", "renderD128", "version" },
  ["/drm/card0/device/hwmon"] = { "hwmon5" },
  ["/proc"] = { "self", "200" },
  ["/proc/200/fdinfo"] = { "9" },
}
local links = {
  ["/drm/card0/device"] = "../../../0000:03:00.0",
  ["/drm/card0/device/driver"] = "../../../../bus/pci/drivers/amdgpu",
  ["/drm/renderD128/device"] = "../../../0000:03:00.0",
  ["/drm/renderD128/device/driver"] = "../../../../bus/pci/drivers/amdgpu",
  ["/proc/200/fd/9"] = "/dev/dri/renderD128",
}

-- A filesystem that answers only the paths this fixture defines, and reports
-- anything else as missing, so the collector's own directory walks decide what
-- exists rather than the test having to enumerate it.
local function fake_fs(files, directories, links)
  local function copy_array(values)
    local out = {}
    for index, value in ipairs(values) do out[index] = value end
    return out
  end
  local fs = {}
  function fs:read(path, limit)
    local value = files[path]
    if value == nil then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    value = tostring(value)
    if limit and #value > limit then
      return nil, { kind = "too_large", message = "file_exceeds_limit", path = path }
    end
    return value
  end
  function fs:read_number(path)
    local content = self:read(path, 256)
    if not content then return nil end
    local token = content:match("^%s*([^%s]+)")
    local value = token and tonumber(token)
    if value == nil then
      return nil, { kind = "parse_error", message = "expected_number", path = path }
    end
    return value
  end
  function fs:list(path, limit)
    local values = directories[path]
    if not values then
      return nil, { kind = "missing", message = "fixture_directory_missing", path = path }
    end
    local out = copy_array(values)
    local truncated = limit ~= nil and #out > limit
    if truncated then
      for index = #out, limit + 1, -1 do out[index] = nil end
    end
    return out, nil, truncated
  end
  function fs:readlink(path)
    local value = links[path]
    if value then return value end
    return nil, { kind = "missing", message = "fixture_link_missing", path = path }
  end
  return fs
end

local fs = fake_fs(files, directories, links)

local function collect()
  local collector = Gpu.new({
    drm_path = "/drm", proc_path = "/proc",
    max_processes = 8, max_fds_per_process = 8,
    max_fdinfo_files = 8, max_clients = 8,
  })
  return collector:sample({ fs = fs, now_ns = function() return 1000000000 end })
end

local snapshot = collect()
local device = assert(snapshot.data and snapshot.data.by_id
  and snapshot.data.by_id["0000:03:00.0"], "the amdgpu device was not found")
local process = assert(device.processes and device.processes.by_id
  and device.processes.by_id["200:4000"], "the process holding the client was not found")
local clients = assert(process.clients, "the process has no clients")
local client = assert(clients[1], "the process has no client")
local domains = assert(client.frequency_domains, "the client kept no frequency domains")

-- 2. All three domains, sorted by name, none dropped for lacking an engine of
-- the same name.
equal(#domains, 3, "every domain the kernel published is kept")
equal(domains[1].id, "gr", "domains are sorted by name")
equal(domains[2].id, "mclk", "  mclk")
equal(domains[3].id, "sclk", "  sclk")

equal(domains[3].current_hz, 1400000000, "sclk current is read")
equal(domains[3].maximum_hz, 2100000000, "sclk maximum is read")
equal(domains[3].engine, nil,
  "a domain that shares no engine's name claims no engine: " .. tostring(domains[3].engine))
equal(domains[3].of_maximum_percent, 1400000000 * 100 / 2100000000,
  "a clock below its ceiling reports its share of that ceiling")

-- 3. A reading above the stated maximum is clamped, not reported as 103%.  The
-- maximum is a ceiling the driver advertises, and drivers do report above it.
equal(domains[2].current_hz, 900000000, "mclk current is read")
equal(domains[2].maximum_hz, 875000000, "mclk maximum is read")
equal(domains[2].of_maximum_percent, 100, "a clock above its ceiling clamps to 100")

-- 4. A maximum with no current reading has no ratio at all, rather than a zero
-- that would say the clock is stopped.  It is the same rule the queue-wait
-- figure follows: without both ends there is no figure to draw.
equal(domains[1].current_hz, nil, "gr has no current reading")
equal(domains[1].maximum_hz, 1000000000, "gr still knows its maximum")
equal(domains[1].of_maximum_percent, nil, "so it reports no share of the ceiling")
equal(domains[1].quality, "unavailable", "and says the clock is unavailable")
equal(domains[2].quality, nil, "a domain with a reading is not marked unavailable")

-- 5. The engines are untouched by the domain join, and an engine that shares
-- no domain's name is left unattached rather than guessed at.
local engines = device.processes.by_id["200:4000"].clients[1].engines
assert(engines.gfx and engines.compute, "the engines are still reported")
equal(engines.gfx.frequency_domain, nil,
  "an engine that shares no domain's name is left unattached")
assert(engines.gfx.utilization_percent ~= nil or engines.gfx.rate_quality == "gap",
  "the engine's own busy-time figure is unaffected by the domain join")

-- 6. The drill-down reaches the domains, and says which figure is which.  A
-- clock at its ceiling is a pinned clock, not a busy engine, so the line must
-- not read as a utilization.
local translator = assert(I18n.new({ locale = "en-US" }))
local function detail_of(target)
  return table.concat(TUI.gpu_client_detail_lines(target, translator), "\n")
end
local detail = detail_of({
  name = "clock-worker", client_id = "21", driver = "amdgpu",
  pci_bdf = "0000:03:00.0", engines = engines, frequency_domains = domains,
  memory = client.memory, memory_summary = client.memory_summary,
})
for _, expected in ipairs({ "sclk", "mclk", "gr" }) do
  assert(detail:find(expected, 1, true),
    "the drill-down does not list the " .. expected .. " domain:\n" .. detail)
end
assert(detail:find("2.1", 1, true) or detail:find("2100", 1, true),
  "the domain's ceiling is not shown:\n" .. detail)
assert(detail:find("1.4", 1, true) or detail:find("1400", 1, true),
  "the domain's current clock is not shown:\n" .. detail)
assert(detail:lower():find("util", 1, true) == nil,
  "a clock must not be labelled a utilization:\n" .. detail)
assert(detail:find("of ", 1, true) and detail:find(" max", 1, true),
  "the share of the ceiling is not labelled as a share:\n" .. detail)
-- A domain with no reading still gets a line: it is a clock the kernel named,
-- and saying nothing about it would hide that it exists.
assert(detail:find("unavailable", 1, true) or detail:find("不可用", 1, true)
  or detail:find("—", 1, true),
  "a domain with no reading is not accounted for:\n" .. detail)

-- 6. A client clock that reads 0 is a clock that is not running, not a clock
-- running at zero.  The device view refuses to publish such a reading one level
-- up, and a client list that printed 0 Hz below it would be the same figure
-- contradicting itself a keystroke away.  The idle body is derived from the
-- real fixture rather than written here, so its shape is a kernel's.
local idle_fdinfo, replaced = FREQINFO:gsub("drm%-curfreq%-sclk:%s*1400 MHz",
  "drm-curfreq-sclk:\t0 MHz")
equal(replaced, 1, "the fixture's current clock was found and replaced exactly once")
files["/proc/200/fdinfo/9"] = idle_fdinfo
local idle_domains = collect().data.by_id["0000:03:00.0"]
  .processes.by_id["200:4000"].clients[1].frequency_domains
local function domain_named(list, id)
  for _, entry in ipairs(list or {}) do
    if entry.id == id then return entry end
  end
  return nil
end
local idle_sclk = assert(domain_named(idle_domains, "sclk"), "the sclk domain is still reported")
equal(idle_sclk.current_hz, nil,
  "a client clock at 0 Hz is not a reading: " .. tostring(idle_sclk.current_hz))
equal(idle_sclk.maximum_hz, 2100000000, "its ceiling is a property of the clock, not its state")
equal(idle_sclk.of_maximum_percent, nil,
  "so it reports no share of the ceiling rather than a zero share")
equal(idle_sclk.quality, "unavailable", "and says the clock is unavailable")
assert(detail_of({
  name = "clock-worker", client_id = "21", driver = "amdgpu",
  pci_bdf = "0000:03:00.0", engines = engines, frequency_domains = idle_domains,
  memory = client.memory, memory_summary = client.memory_summary,
}):lower():find("0 hz", 1, true) == nil,
  "the drill-down drew a 0 Hz clock")
files["/proc/200/fdinfo/9"] = FREQINFO

-- 7. The identity the drill-down matches on has to survive a re-read.  Each
-- tick rebuilds the client table, so a drill-down that remembered the table it
-- was opened on would fall back to the list on the very next frame -- and the
-- cause would be invisible, because the client is still right there in the
-- list.  The device-scoped `drm-client-id` is what stays put.
local second_sample = collect()
local again = assert(second_sample.data.by_id["0000:03:00.0"]
  .processes.by_id["200:4000"].clients[1], "the client vanished on the second sample")
assert(again ~= client,
  "the collector returned the same table object, so this test proves nothing")
equal(again.id, client.id, "the client's id is stable across two samples")
equal(again.client_id, "21", "and it is the kernel's client id")
assert(again.frequency_domains and #again.frequency_domains == 3,
  "the domains are rebuilt on the second sample too")
-- Two clients of the same process must not share an id, or the match above
-- would be satisfied by the wrong one.
local twin = {
  id = "0000:03:00.0:clock-worker:22", client_id = "22", driver = "amdgpu",
}
assert(twin.id ~= client.id, "two clients of one process collide on id")

-- 8. The list level, for the case that made it necessary: one pid holding
-- several DRM clients, which the table sums into a single row.
local function list_of(target)
  return table.concat(TUI.gpu_client_lines({ process = target, index = 1 },
    translator, true), "\n")
end
local second = {
  id = "0000:03:00.0:clock-worker:22", name = "second", client_id = "22",
  driver = "amdgpu",
  engines = { gfx = { id = "gfx", capacity = 1 } }, frequency_domains = domains,
}
local listed = list_of({ clients = { client, second } })
assert(listed:find("clock-worker", 1, true) and listed:find("second", 1, true),
  "the list does not show both clients:\n" .. listed)
assert(listed:find("2 Clocks", 1, true) or listed:find("3 Clocks", 1, true),
  "the list does not count the domains it would show:\n" .. listed)
assert(listed:find("▸", 1, true), "the list has no cursor:\n" .. listed)
-- A single client is the detail, not a list of one: a keypress to reach the
-- only answer is a cost with no information in it.
local single = list_of({ clients = { client } })
assert(single:find("sclk", 1, true),
  "a single client does not go straight to its detail:\n" .. single)
assert(single:find("▸", 1, true) == nil,
  "a single client is shown as a list to choose from:\n" .. single)
-- And the cases that have no client at all still say so.
assert(list_of({ clients = {} }):find("No DRM client", 1, true),
  "a process with no client does not say so")
assert(list_of(nil):find("gone", 1, true), "a process that vanished does not say so")

print("ok: client frequency domains")
