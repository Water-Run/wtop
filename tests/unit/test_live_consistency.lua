package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

-- Cross-check the collectors against procfs on the machine actually running the
-- tests.  Unit tests with injected fixtures prove the parsers; this proves the
-- assembled view still corresponds to the kernel's own numbers, which is the
-- property a monitoring tool lives or dies by.
--
-- Everything here reads only procfs, so it needs no external command and no
-- native module.  Whatever this kernel does not expose is skipped rather than
-- failed: the point is to catch drift, not to require a particular host.

local Disk = require("wtop.collectors.disk")
local Memory = require("wtop.collectors.memory")
local Network = require("wtop.collectors.network")
local Process = require("wtop.collectors.process")
local SystemInfo = require("wtop.collectors.system_info")

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local content = handle:read("a")
  handle:close()
  return content
end

local function close_enough(actual, expected, tolerance)
  return type(actual) == "number" and type(expected) == "number"
    and math.abs(actual - expected) <= tolerance
end

local skipped = 0
local function skip(reason)
  skipped = skipped + 1
  io.write("  skipped: ", reason, "\n")
end

-- ---------------------------------------------------------------------------
-- Memory: the exported figures must match /proc/meminfo, and the stacked
-- composition must be an exact partition of MemTotal rather than the
-- overlapping numbers meminfo actually reports.
-- ---------------------------------------------------------------------------

local meminfo_text = read_file("/proc/meminfo")
if not meminfo_text then
  skip("/proc/meminfo is not readable")
else
  local meminfo = {}
  for line in meminfo_text:gmatch("[^\n]+") do
    local key, value, unit = line:match("^(%S+):%s+(%d+)%s*(%a*)")
    if key then
      meminfo[key] = tonumber(value) * (unit:lower() == "kb" and 1024 or 1)
    end
  end
  local sample = Memory.new({}):sample({})
  assert(sample.status == "ok", "memory sample must succeed on a live host")
  local memory = sample.data

  assert(memory.total_bytes == meminfo.MemTotal,
    "MemTotal must be reported exactly, got " .. tostring(memory.total_bytes))
  -- Everything else moves between the two reads, so only a generous drift is
  -- allowed; the check still catches a wrong field or a wrong unit.
  local drift = 128 * 1024 * 1024
  for field, source in pairs({
    free_bytes = "MemFree", buffers_bytes = "Buffers", shared_bytes = "Shmem",
    mapped_bytes = "Mapped", page_tables_bytes = "PageTables",
    swap_total_bytes = "SwapTotal", commit_limit_bytes = "CommitLimit",
  }) do
    if meminfo[source] ~= nil and memory[field] ~= nil then
      assert(close_enough(memory[field], meminfo[source], drift),
        string.format("memory.%s=%s does not match %s=%s", field,
          tostring(memory[field]), source, tostring(meminfo[source])))
    end
  end

  assert(type(memory.segments) == "table" and #memory.segments > 0,
    "memory must expose a stacked composition")
  local total = 0
  local seen = {}
  for _, segment in ipairs(memory.segments) do
    assert(type(segment.bytes) == "number" and segment.bytes >= 0,
      "a segment must carry a non-negative size")
    assert(not seen[segment.id], "segment ids must be unique: " .. tostring(segment.id))
    seen[segment.id] = true
    total = total + segment.bytes
  end
  assert(total == memory.total_bytes,
    string.format("segments must partition MemTotal exactly: %d vs %d",
      total, memory.total_bytes))
end

-- ---------------------------------------------------------------------------
-- Block devices: the device set must match /proc/diskstats exactly.  A missing
-- device is a row an operator will never see; an extra one is fabricated.
-- ---------------------------------------------------------------------------

local diskstats_text = read_file("/proc/diskstats")
if not diskstats_text then
  skip("/proc/diskstats is not readable")
else
  local expected, expected_count = {}, 0
  for line in diskstats_text:gmatch("[^\n]+") do
    local name = line:match("^%s*%d+%s+%d+%s+(%S+)")
    if name then
      expected[name] = true
      expected_count = expected_count + 1
    end
  end
  local sample = Disk.new({}):sample({})
  if sample.status ~= "ok" then
    skip("disk collector reported " .. tostring(sample.status))
  else
    local actual, actual_count = {}, 0
    for _, device in ipairs(sample.data.devices or {}) do
      actual[device.name] = true
      actual_count = actual_count + 1
    end
    for name in pairs(expected) do
      assert(actual[name], "block device missing from the collector: " .. name)
    end
    for name in pairs(actual) do
      assert(expected[name], "collector invented a block device: " .. name)
    end
    assert(actual_count == expected_count, "device counts must agree")
  end
end

-- ---------------------------------------------------------------------------
-- Network: the interface set and the raw byte counters must match
-- /proc/net/dev.  Rates are derived from these, so a wrong column here is a
-- wrong throughput everywhere.
-- ---------------------------------------------------------------------------

local netdev_text = read_file("/proc/net/dev")
if not netdev_text then
  skip("/proc/net/dev is not readable")
else
  local expected = {}
  local line_number = 0
  for line in netdev_text:gmatch("[^\n]+") do
    line_number = line_number + 1
    if line_number > 2 then
      local name, rest = line:match("^%s*(%S+):%s*(.+)$")
      if name then
        local fields = {}
        for value in rest:gmatch("%S+") do fields[#fields + 1] = tonumber(value) end
        expected[name] = { rx = fields[1], tx = fields[9] }
      end
    end
  end
  local sample = Network.new({}):sample({})
  if sample.status ~= "ok" then
    skip("network collector reported " .. tostring(sample.status))
  else
    local seen = 0
    for _, interface in ipairs(sample.data.interfaces or {}) do
      local truth = expected[interface.name]
      assert(truth, "collector invented an interface: " .. tostring(interface.name))
      local counters = interface.counters or {}
      if counters.rx_bytes and truth.rx then
        -- Traffic keeps flowing between the two reads; the counters are
        -- monotonic, so the collector may only be at or ahead of the file we
        -- read first, never behind it by more than a rounding artefact.
        assert(counters.rx_bytes >= truth.rx - 4096,
          string.format("%s rx_bytes went backwards: %d < %d",
            interface.name, counters.rx_bytes, truth.rx))
        assert(counters.tx_bytes >= truth.tx - 4096,
          string.format("%s tx_bytes went backwards: %d < %d",
            interface.name, counters.tx_bytes, truth.tx))
      end
      seen = seen + 1
    end
    local expected_count = 0
    for _ in pairs(expected) do expected_count = expected_count + 1 end
    assert(seen == expected_count,
      string.format("interface count differs: %d vs %d", seen, expected_count))
  end
end

-- ---------------------------------------------------------------------------
-- Processes: the enumerated set must match the /proc/<pid> directories, and
-- the first sample must already carry usable CPU values.
-- ---------------------------------------------------------------------------

local process_sample = Process.new({ read_cmdline = true }):sample({})
if process_sample.status ~= "ok" then
  skip("process collector reported " .. tostring(process_sample.status))
else
  local live = 0
  for _, entry in ipairs(process_sample.data.list or {}) do
    assert(type(entry.pid) == "number" and entry.pid > 0, "every row needs a PID")
    assert(type(entry.starttime_ticks) == "number",
      "every row needs a start time, which is what makes the identity reusable")
    live = live + 1
  end
  assert(live > 5, "a live host must have more than five processes")

  -- The first sample has nothing to difference against.  It must still produce
  -- a usable ordering, marked estimated rather than passed off as measured.
  local with_cpu, estimated = 0, 0
  for _, entry in ipairs(process_sample.data.list or {}) do
    if entry.cpu_percent then with_cpu = with_cpu + 1 end
    if entry.quality == "estimated" then estimated = estimated + 1 end
  end
  assert(with_cpu > live // 2,
    string.format("the first sample must price most processes: %d of %d", with_cpu, live))
  assert(estimated > 0, "first-sample CPU must be labelled estimated, not fresh")
end

-- ---------------------------------------------------------------------------
-- System identity: uptime, hostname and the kernel-wide counters come from
-- files this test can read directly.
-- ---------------------------------------------------------------------------

local uptime_text = read_file("/proc/uptime")
if not uptime_text then
  skip("/proc/uptime is not readable")
else
  local expected_uptime = tonumber(uptime_text:match("^%s*([%d%.]+)"))
  local sample = SystemInfo.new({}):sample({})
  assert(sample.status == "ok", "system_info must succeed on a live host")
  local system = sample.data
  assert(close_enough(system.uptime_seconds, expected_uptime, 60),
    "uptime must match /proc/uptime")

  local hostname = read_file("/proc/sys/kernel/hostname")
  if hostname then
    assert(system.host.hostname == (hostname:gsub("%s+$", "")),
      "hostname must match the kernel's")
  end

  local stat_text = read_file("/proc/stat")
  if stat_text then
    local ctxt = tonumber(stat_text:match("\nctxt (%d+)"))
    if ctxt and system.counters and system.counters.ctxt then
      assert(system.counters.ctxt >= ctxt - 1000,
        "the context-switch counter is monotonic and must not read low")
    end
    local btime = tonumber(stat_text:match("\nbtime (%d+)"))
    if btime then
      assert(system.boot_time_unix == btime, "boot time must come from btime")
    end
  end

  local file_nr = read_file("/proc/sys/fs/file-nr")
  if file_nr and system.limits.file_descriptors then
    local allocated, free = file_nr:match("^%s*(%d+)%s+(%d+)")
    assert(close_enough(system.limits.file_descriptors.open,
      tonumber(allocated) - tonumber(free), 2048),
      "open descriptors must be allocated minus free, not allocated")
  end
end

if skipped > 0 then
  io.write("  (", tostring(skipped), " live checks skipped on this host)\n")
end

return true
