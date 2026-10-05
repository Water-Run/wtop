-- Two rules about what a cell holds after it has been cut, both driven through
-- the real view model and the real table widget.
--
-- The first: a cut cell must not be left holding a different value.  Every other
-- scan in this project asks what the product can *spell*.  This one
-- asks what it can *show after cutting*, and the two are not the same question:
-- a value can be a perfect member of its vocabulary and still be rendered as
-- something else, because `Width.truncate` is grapheme-aware and content-blind.
-- It keeps whole clusters until the budget runs out and appends an ellipsis,
-- which is the right rule for a sentence and for a path, and the wrong rule for
-- a number -- "3254751" clipped to "32547…" is not a shortened process id, it
-- is a different process id, and on a busy host 32547 is very likely a *live*
-- one.
--
-- The second: two rows must not become the same string.  The first rule cannot
-- see this one and the reverse is also true, which is why they are here
-- together.  "4194304" clipped to "4194…" is a wrong number and the first rule
-- names it.  `enp0s31f1` and `enp0s31f2` clipped to `enp0s31…` are not a wrong
-- anything: each cell holds a perfectly good value, each names a real card, and
-- together they are two identical rows -- a loss with no marker on it, which is
-- the property the first rule exists to rule out and cannot, because nothing
-- about either cell is wrong.
--
-- Measured on this host through the real view model and the real table widget,
-- across all eight pages, all ten catalogues and every terminal width from 40 to
-- 200: 27 distinct cells are cut inside a digit run, and every one of them is
-- the process table's PID column, which is declared `min_width = 5` and is
-- therefore handed five or six cells at narrow widths while a real seven-digit
-- pid sits in the row.  No other numeric column is ever cut this way -- memory,
-- cpu, threads, link speed and the rest are all formatted short enough to fit,
-- so the shape is specific rather than general, and the fix is one number.
--
-- What makes it a correctness defect and not a cosmetic one is that the pid is
-- the one value in the table a user acts on: `k` opens a confirmation that names
-- the pid, and the thread picker filters on it.  That confirmation is built from
-- the row's own `pid` field, so the product does not signal the wrong process --
-- the table and the dialog simply disagree, which is its own kind of wrong.  And
-- the full value is not lost the way a sentence is lost: the thread overlay and
-- the confirmation both spell it in full, one keypress away.  So the severity is
-- "a wrong number in the column you scan", not "no number at all" -- which is
-- exactly why it is worth a rule rather than a shrug.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grid = require("wtop.ui.renderer.grid")
local I18n = require("wtop.i18n")
local Inspectors = require("wtop.inspectors")
local Collectors = require("wtop.collectors")
local ProcessTable = require("wtop.model.process_table")
local Table = require("wtop.ui.widgets.table")
local ViewModel = require("wtop.view_model")
local Width = require("wtop.ui.renderer.width")
local Workspace = require("wtop.workspace")

-- The capabilities the Insights page's two tables are built from, which until
-- this increment nothing in this file supplied at all: every call passed `{}`,
-- and a table built from an empty capabilities has no rows, so `collector_table`
-- (seventeen of them) and `inspector_table` (three) were outside all four of the
-- closed invariants.  The rules were fine; the data was not there -- the same
-- shape as `gpus = { devices = {} }` in increment 97, one level further out.
--
-- Both id lists come from the product, not from a hand-copied list of seventeen
-- strings: `Collectors.constructors` is the set of collectors a Linux build
-- registers, and `Inspectors.new_default()` is the registry the product itself
-- probes.  A list written down here would be a fourteenth copy of a fact, and
-- the copies in this project have already drifted twice.
--
-- The reason codes are the extremes rather than a sample, and they were picked by
-- measuring all 156 against all ten catalogues: `gpu_identity_inferred` has the
-- longest label in nine of the ten (86 cells in es-ES, 43 in zh-CN),
-- `memory_counter_read_unverified` is the longest in de-DE, and
-- `hwmon_value_derived`, `cpufreq_value_derived` and
-- `cpu_counter_delta_unavailable` take the next three places.  Seven of the 1560
-- (code, catalogue) pairs fit the ten cells the Reason column guarantees; the
-- other 1553 are cut at it, so a fixture carrying a short code would be asking
-- the column a question it has never been asked.
local EXTREME_REASONS = {
  "gpu_identity_inferred", "memory_counter_read_unverified", "hwmon_value_derived",
  "cpufreq_value_derived", "cpu_counter_delta_unavailable",
}
-- The states a probe can report, from `core/capability.lua`'s own closed set.
-- `degraded` is in it and cannot reach the State column -- `Capability.new`
-- gives it `available = true`, so `collector_rows` takes the quality branch --
-- and it is left in anyway, because a fixture that enumerates a smaller set than
-- the product publishes is a fixture asserting something the product does not
-- promise.
local CAPABILITY_STATES = { "available", "unavailable", "denied", "degraded", "error" }
-- The sources are the paths collectors actually report, and they are here for
-- the shape rather than for the pairing: no rule in this file reads which
-- collector a source belongs to, and inventing a false pairing is how a probe
-- ends up asserting something about a host that does not exist.  The two that
-- share a long prefix are the case worth carrying -- `/sys/devices/system/cpu/
-- cpufreq` and `/sys/devices/system/cpu/cpuidle` both draw `/sys/devices` in the
-- twelve cells the Source column guarantees.
local SOURCES = {
  "/sys/devices/system/cpu/cpufreq", "/sys/devices/system/cpu/cpuidle",
  "/proc/net/tcp", "/proc/net/unix", "/proc/stat", "/proc/meminfo",
  "/proc/pressure/cpu", "/proc/pressure/memory", "/proc/pressure/io",
  "/proc/self/mountinfo", "/proc/self/fd", "/proc/cpuinfo", "/proc/uptime",
  "/proc/loadavg", "/proc/diskstats", "/sys/class/drm", "/sys/class/hwmon",
  "/sys/class/power_supply", "/sys/fs/cgroup", "/sys/bus/pci/devices",
  "/sys/devices/virtual/dmi/id", "/sys/devices/system/cpu/online",
}
local function capabilities()
  local ids = {}
  for id in pairs(Collectors.constructors) do ids[#ids + 1] = id end
  table.sort(ids)
  local result = { inspectors = {} }
  for index, id in ipairs(ids) do
    local state = CAPABILITY_STATES[(index % #CAPABILITY_STATES) + 1]
    result[id] = {
      state = state, available = state == "available",
      reason = EXTREME_REASONS[(index % #EXTREME_REASONS) + 1],
      source = SOURCES[(index % #SOURCES) + 1],
    }
  end
  for index, id in ipairs(Inspectors.new_default().order) do
    local state = CAPABILITY_STATES[index]
    result.inspectors[id] = {
      state = state, available = state == "available",
      reason = EXTREME_REASONS[index],
    }
  end
  return result
end

local locales = { "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR",
                  "de-DE", "fr-FR", "es-ES", "pt-BR", "ru-RU" }
-- The pages, read from the product.  This line was a hand-written list of eight
-- and it was two short, in the same way increment 92 found: the product has ten
-- pages, `memory` and `system` are drill-down pages rather than tabs, and
-- `system` is the one carrying the mount and collector tables.  A page the
-- sweep does not visit is a page whose tables have no rows, and a table with no
-- rows is a table the second rule below has no subject in.
local tabs = {}
for id in pairs(Workspace.new().pages) do tabs[#tabs + 1] = id end
table.sort(tabs)
local WIDEST = 200
local NARROWEST = 40

-- `/proc/sys/kernel/pid_max` cannot exceed 2^22, so the widest pid Linux hands
-- out is 4194304: seven digits, on every kernel, forever.  The fixture sits at
-- that ceiling rather than at this host's pids, because a guard written against
-- today's snapshot is a guard against a snapshot.
local KERNEL_MAX_PID = 4194304

local function process(pid, starttime, name)
  return {
    id = tostring(pid) .. ":" .. tostring(starttime),
    pid = pid,
    starttime_ticks = starttime,
    parent_pid = 1,
    name = name,
    command = name,
    user = "tester",
    state = "S",
    cpu_percent = 1.5,
    resident_bytes = pid * 1024,
    virtual_bytes = pid * 4096,
    threads = 2,
    io = { read_bytes = 1, write_bytes = 2 },
  }
end

-- Interface names one host can really carry at the same time, chosen for the
-- shapes a prefix-based truncation cannot survive rather than for variety: four
-- same-model NICs whose names differ only in the PCI slot, two adjacent VLANs on
-- one of them, two names at the kernel's own 15-character ceiling differing only
-- in the last character, a wireless pair, and a container's two ends.
--
-- The first version of this fixture carried `network = { interfaces = {} }`, and
-- the sweep below renders every table with rows -- so the interface column was
-- never rendered with a value in it, by a guard whose subject is what a cut cell
-- ends up showing.  An empty list is not a small sample; it is the absence of
-- the one column the second rule in this file is about.
--
-- `IFNAMSIZ` is 16 including the terminator, so 15 is the ceiling, and the
-- clause below asserts that of the fixture itself: a name longer than the
-- kernel allows is not a hard case, it is a case the product can never be given,
-- and building a rule on one produces a test that fails for a reason that has
-- nothing to do with the product.  The first version of the measurement that
-- motivated this file did exactly that and reported a 15-cell box as colliding.
local IFNAMSIZ_NAME_LIMIT = 15
local INTERFACE_NAMES = {
  "lo",
  "enp0s31f1", "enp0s31f2", "enp0s31f3", "enp0s31f4",
  "enp0s31f1.100", "enp0s31f1.101",
  "enp0s31f10.4093", "enp0s31f10.4094",
  "wlp3s0", "wlp3s0f0",
  "veth1a2b3c4", "veth1a2b3c5",
  "br0", "bond0", "docker0",
}

local function network_snapshot()
  local interfaces = {}
  for index, name in ipairs(INTERFACE_NAMES) do
    interfaces[index] = {
      name = name, mtu = 1500, operstate = "up", speed_mbps = 10000,
      duplex = "full", mac = "aa:bb:cc:dd:ee:ff",
      rx_bytes = 1024 * index, tx_bytes = 2048 * index,
      rx_packets = 10, tx_packets = 20, rx_errors = 0, tx_errors = 0,
      rx_dropped = 0, tx_dropped = 0, quality = "fresh",
      addresses = { { family = "ipv4", address = "192.0.2." .. index,
                      netmask = "255.255.255.0" } },
    }
  end
  return { interfaces = interfaces, addresses_status = "fresh" }
end

local function snapshot()
  local list = {}
  -- A spread of pids, so the guard is not satisfied by one lucky value: the
  -- widest, the narrowest the kernel issues, and a four-digit one that has to
  -- keep working unchanged.
  local pids = { KERNEL_MAX_PID, KERNEL_MAX_PID - 1, 4194303, 1048576, 9999, 1000, 1 }
  for index, pid in ipairs(pids) do
    list[index] = process(pid, index, "worker" .. index)
  end
  return {
    cpu = { usage_percent = 12, quality = "fresh" },
    memory = { quality = "fresh" },
    pressure = { quality = "fresh" },
    disks = { devices = {} },
    network = network_snapshot(),
    processes = { list = list, truncated = false, clock_ticks_per_second = 100,
                  total = #list, process_candidates = #list },
    -- One card, two processes, pids that differ only in their last digit.  The
    -- GPU process table declares its own `pid` column at its own width, and the
    -- fixture that found the process table's did not have this table in it at
    -- all -- `gpus = { devices = {} }` for every increment that looked at a pid,
    -- so a second pid column was never rendered, never cut, and never checked.
    gpus = { devices = { { id = "card0", card = "card0", model_name = "Test GPU",
      vendor = "pci", vendor_name = "Test", driver = "test", quality = "fresh",
      processes = { list = {
        { id = "p1", pid = KERNEL_MAX_PID - 1, utilization_percent = 3,
          memory_summary = { resident_bytes = 4096 } },
        { id = "p2", pid = KERNEL_MAX_PID, utilization_percent = 4,
          memory_summary = { resident_bytes = 8192 } },
      } } } }, process_scan = { status = "ok", quality = "fresh" } },
    cpu_frequency = { policies = {}, current_quality = "fresh" },
    sensors = { devices = {} },
    quality = { mounts = { status = "ok", quality = "fresh" } },
    connections = { connections = {}, owner_scan = { status = "ok", quality = "fresh" } },
    mounts = { mounts = {} },
    workloads = { workloads = {}, summary = {} },
  }
end

-- A second snapshot, used only by the second rule, and built for it.  Every row
-- in it is indistinguishable from every other row in all its columns except the
-- one that names it: four cards all down and silent, four power zones reading
-- the same watts, three sensors on one device at the same temperature, four
-- disks of the same model and size under the same load, and a hundred and
-- twenty-eight cores -- a count a 32-core server can reach and a 128-core host
-- cannot avoid.  That is the input the rule needs.  A fixture whose other
-- columns vary passes for a reason that has nothing to do with the column under
-- test, which is how `disk_table` and `mount_table` both came out clean: their
-- size and use columns separate the rows, so a truncated device name there is a
-- shortened path and not a lost identity.
--
-- It is kept out of the width sweep on purpose.  The first rule needs all 161
-- widths and small tables; this one needs large tables and a single width, and
-- putting 128 cores through 161 widths across ten catalogues would be 2.4
-- million cells to ask a question that does not vary with width.
local function worst_case_snapshot()
  local base = snapshot()
  local cores = {}
  for index = 0, 127 do
    cores[index + 1] = { name = "cpu" .. index, utilization = 0, user = 0,
      system = 0, iowait = 0, irq = 0, steal = 0, quality = "fresh" }
  end
  local zones = {}
  for index = 0, 3 do
    zones[index + 1] = { name = "package-" .. index, power_watts = 12.5,
      quality = "fresh" }
  end
  local disks = {}
  for index, name in ipairs({ "/dev/sda", "/dev/sdb", "/dev/nvme0n1", "/dev/zram0" }) do
    disks[index] = { name = name,
      identity = { model = "Generic Disk", vendor = "ATA", size_bytes = 500000000000,
                   rotational = 0, scheduler = "mq-deadline" },
      read_bytes_per_second = 65536, write_bytes_per_second = 32768,
      busy_percent = 5, average_queue_size = 1, quality = "fresh" }
  end
  local mounts = {}
  for index, point in ipairs({ "/", "/boot", "/home", "/var/log" }) do
    mounts[index] = { id = tostring(index), mount_point = point, fs_type = "ext4",
      source = "/dev/sda1", kind = "local",
      capacity = { total_bytes = 1000000000, used_percent = 40, available_bytes = 600,
                   block_size_bytes = 4096 },
      inodes = { used_percent = 10, total = 100, free = 90, used = 10,
                 reserved = 0, available = 90 }, quality = "fresh" }
  end
  base.cpu = { usage_percent = 0, cores = cores, quality = "fresh" }
  base.disks = { devices = disks }
  base.mounts = { mounts = mounts }
  base.power = { zones = zones }
  -- Four of the same card, as a four-GPU box actually is: one model, one
  -- driver, one clock, all idle.  Every column but the card's own name is
  -- identical, which is the point -- a fixture with four different models would
  -- never ask the question.
  local gpus = {}
  for index = 1, 4 do
    gpus[index] = { id = "card" .. index, card = "card" .. index,
      model_name = "NVIDIA GeForce RTX 4090", vendor = "pci", vendor_name = "NVIDIA",
      driver = "nvidia", pci = { current_link_speed = "16 GT/s", current_link_width = 16 },
      metrics = { utilization_percent = 0, memory_used_bytes = 0,
                  memory_total_bytes = 25757220864, frequency_current_hz = 2100000000 },
      frequencies = { domains = { { name = "graphics" } } }, quality = "fresh" }
  end
  base.gpus = { devices = gpus, process_scan = { status = "ok", quality = "fresh" } }
  -- Three high-speed links, so the Link column is asked about the range where
  -- its unit used to fall off the end.  The base fixture's interfaces are all
  -- 10 Gbit/s, which is exactly the rate that fits; a column can be one cell
  -- too narrow for every other rate on the planet and pass on that data.
  local links = {}
  for index, mbps in ipairs({ 10, 100000, 200000, 400000 }) do
    links[index] = { name = "eth" .. index, mtu = 1500, operstate = "up",
      speed_mbps = mbps, duplex = "full", mac = "aa:bb:cc:dd:ee:0" .. index,
      rx_bytes = 0, tx_bytes = 0, rx_packets = 0, tx_packets = 0,
      rx_errors = 0, tx_errors = 0, rx_dropped = 0, tx_dropped = 0,
      quality = "fresh",
      addresses = { { family = "ipv4", address = "192.0.2." .. (10 + index),
                      netmask = "255.255.255.0" } } }
  end
  base.network = { interfaces = links, addresses_status = "fresh" }
  -- One browser's four connections to one service, which differ only in the
  -- source port -- the shape that ends the two endpoints columns cannot show.
  -- This one is expected to collide, and the expectation is written down where
  -- the rule is applied rather than left as a gap in the fixture.
  local connections = {}  for index = 1, 4 do
    connections[index] = { id = tostring(index), protocol = "tcp", state = "ESTABLISHED",
      local_endpoint = { text = "192.168.1.20:4432" .. index },
      remote_endpoint = { text = "198.51.100.1:443" }, owners = {},
      queue = "normal", uid = 1000, quality = "fresh" }
  end
  base.connections = { connections = connections, owner_scan = { status = "ok", quality = "fresh" } }
  -- Two processes on each card, with pids that differ only in the last digit --
  -- the kernel's ceiling and the one below it.  `gpu_process_table` declares its
  -- own `pid` column, at its own width, and the fixture that found the process
  -- table's did not include this one.
  local gpu_processes = {}
  for index = 1, 4 do
    gpu_processes[index] = { id = "p" .. index, pid = KERNEL_MAX_PID - (index % 2),
      utilization_percent = 1 + index, memory_summary = { resident_bytes = 1024 * index } }
  end
  for index = 1, 4 do
    gpus[index].processes = { list = { gpu_processes[index], gpu_processes[index + 1] } }
  end
  -- Two of the same board NIC, and two functions of one controller on one bus:
  -- a repeated model name next to a PCI address that differs only late.
  base.inventory = { pci = { devices = {
    { address = "0000:00:1f.6", vendor_name = "Intel Corporation",
      device_name = "Ethernet Controller I219-V", class = "net" },
    { address = "0000:00:1f.7", vendor_name = "Intel Corporation",
      device_name = "Ethernet Controller I219-V", class = "net" },
    { address = "0000:03:00.0", vendor_name = "Intel Corporation",
      device_name = "Ethernet Controller I219-V", class = "net" },
    { address = "0000:41:00.0", vendor_name = "NVIDIA Corporation",
      device_name = "GA100 [A100 PCIe 40GB]", class = "display" },
    { address = "0000:42:00.0", vendor_name = "NVIDIA Corporation",
      device_name = "GA100 [A100 PCIe 40GB]", class = "display" },
  } }, usb = { devices = {} } }
  local workloads = {}
  for index, unit in ipairs({ "user-1000.slice", "user-1001.slice", "session-2.scope",
                              "session-3.scope", "system.slice" }) do
    workloads[index] = { id = "/" .. unit, name = unit, cgroup_path = "/" .. unit,
      state = "idle", cpu_percent = 0, memory_bytes = 0, quality = "fresh" }
  end
  base.workloads = { workloads = workloads, summary = {} }
  base.sensors = { devices = { { class = "coretemp", name = "coretemp",
    quality = "fresh", channels = {
      { type = "temperature", index = 0, label = "Package id 0", input = 45, quality = "fresh" },
      { type = "temperature", index = 1, label = "Core 0", input = 45, quality = "fresh" },
      { type = "temperature", index = 2, label = "Core 1", input = 45, quality = "fresh" } } } } }
  base.cpu_frequency = { current_quality = "fresh", policies = {
    { policy = "performance", affected_cpus = { 0, 1 },
      frequencies = { current_hz = 1890000000, scaling_minimum_hz = 800000000,
                      scaling_maximum_hz = 3900000000 }, quality = "fresh" } } }
  return base
end

-- The boundary of the rule, stated once.  It speaks only when both the kept text
-- and the value are *plain numbers*: an integer, or an integer with a decimal
-- point that is followed by more digits.  A cell that mixes a number with a unit,
-- a sign or a grouping separator is a different shape and the rule makes no claim
-- about it -- which is the honest answer, not a gap papered over.  `45.3%` cut to
-- `45.…` keeps a trailing point, so what the reader sees is not a number at all
-- and the ellipsis is telling the truth; `1234.567` cut to `1234.5…` does leave a
-- number, and it is not the number the column holds.
--
-- The first version of this rule asked instead whether everything kept was a
-- digit, which is simpler and quietly wrong: it excluded `1234.5` because of the
-- decimal point, so it would have passed a cell showing a truncated fraction.  The
-- test that caught that was the self-check at the bottom, which is the only
-- reason a rule this shape can be trusted to report "none found".
local function numeric_token(text)
  local body = text:gsub("^%s+", ""):gsub("%s+$", "")
  local integer, fraction = body:match("^(%d+)%.(%d+)$")
  if integer then return tonumber(integer .. "." .. fraction) end
  local whole = body:match("^(%d+)$")
  if whole then return tonumber(whole) end
  return nil
end

local function strip_ellipsis(text)
  for _, mark in ipairs({ "…", "." }) do
    if text:sub(-#mark) == mark then return text:sub(1, -(#mark + 1)) end
  end
  return text
end

-- The whole rule, as one predicate, so it can be handed a known case.  A rule
-- that recognises nothing passes every sweep below it and reports a clean
-- result, which is the most expensive shape of mistake in this project: it looks
-- like an answer.  The self-check at the bottom is what distinguishes the two.
local function is_wrong_number(text, out)
  local body = strip_ellipsis(out)
  if body == out then return false end
  local kept, value = numeric_token(body), numeric_token(tostring(text))
  if kept == nil or value == nil then return false end
  return kept ~= value
end

-- ---------------------------------------------------------------------------
-- The drive.  The rule is checked on the renderer's own calls rather than on a
-- reimplementation of them, so what is asserted is what a cell would contain.
-- ---------------------------------------------------------------------------
local offenders, seen_offender, cuts, cells = {}, {}, 0, 0
local tables_rendered = {}
local owners = {}

-- The second rule, and where it runs.  A row that cannot be told from another
-- row is a defect with no marker on it: nothing in either cell says it was cut,
-- so the user is looking at a fault that is not there.
--
-- **This used to be a list of columns, and the list was the wrong shape.** The
-- list said which columns are "the row's identity", which is a judgement a person
-- makes by reading the table, and the one entry it started with was the column
-- the person had already been looking at.  It found nothing else.  The criterion
-- below asks no such question: a row is lost when *no* column of it separates it
-- from another.  That is weaker -- a table whose size column separates its rows
-- is fine whatever happens to its device name -- and wider, because it applies to
-- every table the fixture can fill rather than to the ones somebody remembered.
-- `core_table` is what the difference bought: its core name is the row's
-- identity in exactly the sense `interface` is, it was never on the list, and on
-- a 128-core host `cpu100` through `cpu127` are all drawn `cpu1…`.
local real_truncate = Width.truncate
Width.truncate = function(text, max_width, options, ellipsis)
  local out, truncated = real_truncate(text, max_width, options, ellipsis)
  if truncated then
    cuts = cuts + 1
    if is_wrong_number(text, out) then
      -- One line per distinct shape.  The same cell is redrawn once per width
      -- and once per catalogue, and a failure list of two hundred identical
      -- lines is a list nobody reads to the end.
      local id = max_width .. "|" .. out .. "|" .. tostring(text)
      if not seen_offender[id] then
        seen_offender[id] = true
        local line = string.format("a %d-cell cell shows %q for the value %q",
          max_width, out, tostring(text))
        for label in pairs(owners[out] or owners[tostring(text)] or {}) do
          line = line .. " [" .. label .. "]"
          break
        end
        offenders[#offenders + 1] = line
      end
    end
  end
  return out, truncated
end

local engine = { history_values = function() return {} end }

-- One build per (page, catalogue, width) rather than one per (page, catalogue),
-- and that is measured rather than assumed: `ViewModel.build` takes no width, so
-- caching the model and re-rendering it at each width is the obvious saving, and
-- it was implemented and the counts came out identical -- 534,114 cells, 54,304
-- cuts, sixteen tables, to the digit -- while the file got no faster at all.
-- The cost is the 534,114 cell renders, not the 1928 builds: an empty-snapshot
-- build measures 0.57 ms against 13 ms for the extremes.  So the cache is gone,
-- because a mechanism the measurement refuted is a mechanism that only costs
-- the next reader time.
local function drive(translator, width)
  for _, tab in ipairs(tabs) do
    -- The *extremes* fixture, not the base one.  The sweep is what applies the
    -- wrong-number rule, and it was driving `snapshot()` -- which has no cores,
    -- no GPU, no device inventory and no addresses, so seven of the sixteen
    -- tables were never drawn at any width at all.  The row rule below already
    -- used the extremes; the two rules sweep different things and the gap
    -- between them was invisible because each printed its own count.
    local ok, models = pcall(ViewModel.build, engine, worst_case_snapshot(), translator,
      capabilities(), tab, ProcessTable.new({ sort_key = "cpu", descending = true }))
    assert(ok, "view model for " .. tab .. " must build: " .. tostring(models))
    for name, model in pairs(models) do
      if type(model) == "table" and type(model.columns) == "table"
          and type(model.rows) == "table" and #model.rows > 0 then
        tables_rendered[name] = true
        -- Attribute each cell to the column that produced it, so a failure names
        -- the column rather than only the value.
        for _, column in ipairs(model.columns) do
          if type(column) == "table" and type(column.key) == "string" then
            local key, existing = column.key, column.format
            column.format = function(value, row)
              local result
              if type(existing) == "function" then result = existing(value, row)
              else result = value end
              local text = tostring(result == nil and "—" or result)
              local list = owners[text]
              if not list then list = {}; owners[text] = list end
              list[tab .. ":" .. tostring(name) .. "." .. key] = true
              return result
            end
          end
        end
        cells = cells + #model.rows * #model.columns
        local grid = Grid.new(width, 20)
        Table.render(grid, { x = 1, y = 1, width = width, height = 20 },
          model, {}, "full")
      end
    end
  end
end

-- Every width, not a sample of them.  How many cells a column is handed is a
-- step function of the terminal width whose steps are not written down anywhere,
-- and increment 84's width sweep found 22 of 64 combinations changing between
-- two sizes nobody had measured -- so a sampled sweep is a guess about where the
-- cliffs are.  161 widths costs under two seconds.
local primary = assert(I18n.new({ locale = "en-US" }))
for width = NARROWEST, WIDEST do
  drive(primary, width)
end
-- The other nine catalogues, at the sizes the suite exercises plus the narrow
-- band where the column is at its minimum.  Column widths are declared as
-- numbers and do not vary with the language, so the allocation above is the same
-- in every language; what varies is the cell text, and this is where a
-- translated value that happens to be numeric would be caught.
for _, locale in ipairs(locales) do
  local translator = assert(I18n.new({ locale = locale }))
  for _, width in ipairs({ 60, 80, 85, 90, 100, 120, 160, 180 }) do
    drive(translator, width)
  end
end

Width.truncate = real_truncate

-- ---------------------------------------------------------------------------
-- The verdict.
--
-- Every failure is collected and reported together rather than asserted in
-- order.  Under the unfixed width the specific check below fired first and the
-- general rule never ran, so the one run that most needed to explain the defect
-- explained only half of it: the message said the column was six cells wide and
-- said nothing about the `4194…` that six cells produced.  A guard that reports
-- its most specific finding and stops is a guard that hides its own general one.
-- ---------------------------------------------------------------------------
local failures = {}
local function require(condition, message)
  if not condition then failures[#failures + 1] = message end
end

require(cells > 1000,
  "only " .. cells .. " cells were driven; the columns were not exercised")
require(cuts > 0,
  "nothing was truncated at any width, so the rule was never applied to a cut")

-- **Which tables the sweep drew, named -- because "the rule passed" and "the
-- rule had nothing to say" look identical from the outside.** `cuts > 0` above
-- does not settle it: a seven-digit pid is cut in one table and shown whole in
-- another, and a fixture that quietly loses the second one still truncates
-- plenty. That is not hypothetical: the GPU process table declares its own
-- `pid` column, it was six cells wide, and it stayed that way through every
-- increment that looked at a pid, because `gpus = { devices = {} }` meant it
-- was never rendered at all. The rule was fine; the data was not there. Filling
-- the fixture found it without a line of new rule code -- which is the best
-- outcome this project has had from a coverage gap, and only available because
-- something noticed the table was missing.
require(tables_rendered.process_table,
  "the process table was never rendered, so the pid rule was applied to no pid "
  .. "column at all")
require(tables_rendered.gpu_process_table,
  "the GPU process table was never rendered; it declares a pid column of its "
  .. "own, and a fixture without a GPU in it leaves that column unchecked while "
  .. "every clause here stays green")

-- The rule, handed the case it exists for.  Everything above is a sweep, and a
-- sweep cannot tell "found nothing" from "cannot find".  The three cases are the
-- shape of the answer rather than one example: a pid cut between two digits is a
-- wrong number, a cut that landed on a decimal point is not (the prefix is not
-- itself a number), and a cell that fitted was never cut.
require(is_wrong_number("4194304", "4194…"),
  "the rule does not recognise a pid cut between two digits")
require(is_wrong_number("1234.567", "1234.5…"),
  "the rule does not recognise a fraction cut between two digits")
require(not is_wrong_number("45.3%", "45.…"),
  "the rule calls a cut that landed on a trailing decimal point a wrong number")
require(not is_wrong_number("1.2 GiB", "1.2 G…"),
  "the rule calls a cell that lost part of its unit a wrong number")
require(not is_wrong_number("4194304", "4194304"),
  "the rule calls an uncut cell a wrong number")

-- The fixture, checked against the kernel rather than against taste.  This file's
-- coverage of the defect is a property of the values it feeds the columns, so a
-- fixture quietly reduced to four-digit pids would keep every clause green while
-- testing nothing -- the defect needs a seven-digit value to exist at all.
require(#tostring(KERNEL_MAX_PID) == 7,
  "the fixture's widest pid is " .. KERNEL_MAX_PID .. ", which is "
  .. #tostring(KERNEL_MAX_PID) .. " digits; the kernel's ceiling of 4194304 is "
  .. "seven, and a shorter fixture cannot produce a cut pid")

-- The widest pid must actually reach a cell, and the narrowest cell it is handed
-- must be at least as wide as the value.  The first version of this check asked
-- for the opposite -- it required the value to be *asked to fit in a cell
-- narrower than itself* -- because at the time that was the defect, and a guard
-- written for a defect stops being true the moment the defect is closed.  It
-- failed on the fixed code, which is the right behaviour for a test and the
-- wrong behaviour for this one: it had become an assertion that the bug is
-- still there.  A guard for a mechanism that measurement has overturned gets
-- rewritten or deleted, and never left behind asserting the old world.
--
-- The reachability half is what keeps it honest.  The probe this file grew out
-- of asked about a pid taken from the whole process list, rendered only the top
-- rows, and so reported "the column is not drawn" at all thirty-three widths it
-- tried -- a confident answer about a value that was never on screen.  The
-- narrowest width below is read out of the renderer's own calls rather than
-- asserted from the column definition, so it cannot be satisfied by editing the
-- constant and nothing else.
local seen_widest, narrowest_cell = false, nil
Width.truncate = function(text, max_width, options, ellipsis)
  if tostring(text) == tostring(KERNEL_MAX_PID) then
    seen_widest = true
    if narrowest_cell == nil or max_width < narrowest_cell then
      narrowest_cell = max_width
    end
  end
  return real_truncate(text, max_width, options, ellipsis)
end
drive(primary, 60)
drive(primary, 85)
Width.truncate = real_truncate
require(seen_widest,
  "a " .. #tostring(KERNEL_MAX_PID) .. "-digit pid never reached a cell at all, "
  .. "so this file cannot see the shape it is about")
require(narrowest_cell == nil or narrowest_cell >= #tostring(KERNEL_MAX_PID),
  "the narrowest cell the widest pid is drawn in is " .. tostring(narrowest_cell)
  .. " cells, fewer than the " .. #tostring(KERNEL_MAX_PID)
  .. " digits it has to show; the column is being given less than the value needs")
require(#offenders == 0,
  "a cut cell is left holding a different number:\n    "
  .. table.concat(offenders, "\n    "))

-- ---------------------------------------------------------------------------
-- The second rule: an identity column stays an identity after it is cut.
-- ---------------------------------------------------------------------------
-- Two names are indistinguishable once cut when the renderer's own truncation
-- maps them to the same string.  `real_truncate` rather than the hooked one,
-- because the hook above is a counter and this asks the renderer a question.
local function collides(left, right, width)
  return real_truncate(left, width) == real_truncate(right, width)
end

-- The rule, handed the case it exists for and one it must not claim.  The pair is
-- the one that decided the fix: two adjacent VLANs on one card, thirteen
-- characters each, which collide at twelve and separate at fifteen.
require(collides("enp0s31f1.100", "enp0s31f1.101", 12),
  "the rule does not recognise two VLANs on one card cut to the same cell")
require(not collides("enp0s31f1.100", "enp0s31f1.101", 15),
  "the rule calls two names colliding at the kernel's own name limit")

-- **The fixture has to contain a case, and that is a claim about the fixture
-- rather than about the product, so it is checked here.** Reducing the core
-- count to 64 is a smaller fixture in every sense that looks like an
-- improvement, and it takes the second rule's subject away entirely: `cpu0` to
-- `cpu63` are five characters or fewer, so a five-cell column shows them whole
-- and nothing collides.  The file would then be reporting "no two alike" about
-- a set of names that could never be alike, which is the most expensive kind of
-- green -- a rule that has been quietly made unfalsifiable by the data feeding
-- it.  The pair below is the one the fix turned on, and if the fixture stops
-- carrying it, the honest report is that the rule has nothing to say rather than
-- that the product is fine.
require(collides("cpu100", "cpu127", 5),
  "the fixture's core names no longer collide at the guarantee they were found "
  .. "at, so the case this rule was written for is not in the fixture")
require(#worst_case_snapshot().cpu.cores == 128,
  "the second fixture no longer carries 128 cores; its core count is what puts "
  .. "six-character names in the table, and a smaller one cannot")

-- The fixture is checked against the kernel, because a name longer than
-- `IFNAMSIZ` allows is a case the product can never be given, and a rule built
-- on one fails for a reason that has nothing to do with the product.  The
-- measurement that motivated this file did exactly that: it reported a
-- fifteen-cell box as colliding, on a pair where one name was eighteen
-- characters and could not exist.
for _, name in ipairs(INTERFACE_NAMES) do
  require(#name <= IFNAMSIZ_NAME_LIMIT,
    "the fixture's interface name " .. name .. " is " .. #name
    .. " characters; IFNAMSIZ allows " .. IFNAMSIZ_NAME_LIMIT
    .. " and the product can never be given a longer one")
end

-- The rule, over every table the second fixture can fill.  A row is drawn the
-- way the table guarantees it will be drawn at its narrowest -- each column cut
-- to its own `min_width` -- and two rows are the same row if that leaves them
-- with the same string.  `real_truncate` rather than the hooked one: the hook
-- above is a counter, and this asks the renderer a question.
local function cell_text(column, row)
  local value = row[column.key]
  if type(column.format) == "function" then value = column.format(value, row) end
  return tostring(value == nil and "—" or value)
end
local function row_text(model, row, cut)
  local drawn = {}
  for index, column in ipairs(model.columns) do
    local text = cell_text(column, row)
    drawn[index] = cut and real_truncate(text, column.min_width) or text
  end
  return table.concat(drawn, "|")
end

-- The fixture, checked against itself before the rule is applied to it.  A
-- fixture holding two rows that were identical to begin with would have the
-- rule report a collision that is the fixture's own -- true, and useless.
--
-- One build per page, and that is not tidiness: `ViewModel` only fills the rows
-- of the widgets the page it was asked for places, so a single build answers
-- about four tables and says nothing about the other fifteen.  The first version
-- of this rule asked `compute` and reported "4 tables, no two alike" without
-- noticing that the disk, mount and network tables had not been given a single
-- row to check.
local checked, rows_checked, collided = {}, 0, {}
local filled = {}
for _, tab in ipairs(tabs) do
  local page_models = assert(ViewModel.build(engine, worst_case_snapshot(), primary,
    capabilities(), tab, ProcessTable.new({ sort_key = "cpu", descending = true })))
  for name in pairs(page_models) do
    local model = page_models[name]
    if type(model) == "table" and type(model.columns) == "table"
        and type(model.rows) == "table" and #model.rows > 0 then
      filled[name] = model
    end
  end
end
for name in pairs(filled) do checked[#checked + 1] = name end
table.sort(checked)

-- Completeness, asked of the product rather than counted here.  The clause
-- further down that says "at least twelve tables carried rows" is a *count*, and
-- a count cannot say which tables are missing: the Insights page's two tables
-- come back from `ViewModel.build` with an empty `rows` when the fixture passes
-- no capabilities, so they are simply not in `checked`, and fourteen minus two
-- is twelve, which is the floor.  That floor was written with a cell of slack
-- for exactly this reason and it is the wrong shape -- increment 92 found the
-- same thing one level down, where a page-coverage clause compared the sweep's
-- own list of pages against the same function that chose them and so could not
-- see a page go missing.
--
-- So the list of tables is taken from the product: every model the view model
-- returns for any page that carries a `rows` field is a table the product
-- declares, whether or not this fixture gave it anything.  Two tables were
-- declared and empty for the whole life of this file, and the count hid it.
--
-- "Empty" has to mean empty *everywhere*.  `ViewModel` only fills the rows of
-- the widgets the page it was asked for places, so a build of `compute` returns
-- the disk and network tables with an empty `rows` and that is the design, not
-- a hole; the first version of this clause reported all of them and would have
-- been red on a healthy tree.
local declared, rows_seen = {}, {}
for _, tab in ipairs(tabs) do
  local page_models = assert(ViewModel.build(engine, worst_case_snapshot(), primary,
    capabilities(), tab, ProcessTable.new({ sort_key = "cpu", descending = true })))
  for name, model in pairs(page_models) do
    if type(model) == "table" and type(model.rows) == "table" then
      declared[name] = true
      rows_seen[name] = (rows_seen[name] or 0) + #model.rows
    end
  end
end
local declared_list, filled_list, empty = {}, {}, {}
for name in pairs(declared) do declared_list[#declared_list + 1] = name end
for name in pairs(filled) do filled_list[#filled_list + 1] = name end
for _, name in ipairs(declared_list) do
  if (rows_seen[name] or 0) == 0 then empty[#empty + 1] = name end
end
table.sort(declared_list)
table.sort(filled_list)
table.sort(empty)

-- The clause, stated about the product's list rather than about a number.  It
-- reports the names, because a clause that can only say "two tables are
-- missing" is a clause that leaves the reader to go and find them, and the two
-- it would have found are the two tables that carry the Reason column -- the
-- one field increments 99 and 100 spent two rounds pricing, and which no width
-- rule in this project had ever been pointed at.
require(#empty == 0,
  "the product declares " .. #declared_list .. " tables and the fixture filled "
  .. #filled_list .. "; these came back with no rows at all, so every rule in "
  .. "this file was applied to nothing on them: "
  .. (#empty > 0 and table.concat(empty, ", ") or "none"))
-- And the same completeness, read the other way round: a table the fixture
-- filled that the product no longer declares would be a stale expectation in
-- `RECORDED_FORKS` or in the rules below, so the two lists are held to be the
-- same set rather than merely the same size.
local only_declared, only_filled = {}, {}
for _, name in ipairs(declared_list) do
  if not filled[name] then only_declared[#only_declared + 1] = name end
end
for _, name in ipairs(filled_list) do
  if not declared[name] then only_filled[#only_filled + 1] = name end
end
require(#only_declared == 0 and #only_filled == 0,
  "the tables the rules ran over and the tables the product declares are "
  .. "different sets; declared but not filled: "
  .. (#only_declared > 0 and table.concat(only_declared, ", ") or "none")
  .. "; filled but not declared: "
  .. (#only_filled > 0 and table.concat(only_filled, ", ") or "none"))
-- The same tie, for the *width sweep*, which is the half of this file that holds
-- the wrong-number rule.  It has its own list -- `tables_rendered` -- and before
-- this increment the two halves of the file disagreed by nine tables while each
-- printed only its own count, so the line that says "no wrong number" was a
-- statement about seven tables and read as a statement about all of them.  The
-- two named clauses above cover the process table and the GPU process table
-- because those are the ones a pid rule needs; this one is the general form of
-- the same question, and it goes red naming whatever drops out.
local unswept = {}
for _, name in ipairs(declared_list) do
  if not tables_rendered[name] then unswept[#unswept + 1] = name end
end
table.sort(unswept)
require(#unswept == 0,
  "tables the product declares that the width sweep never drew at any width: "
  .. table.concat(unswept, ", ")
  .. "; the wrong-number rule was applied to nothing on them")
-- One table's collision is a recorded decision rather than an oversight, and the
-- entry says so in full -- which is the only thing that makes it different from
-- a hole in the fixture.  `connection_table` draws a source port's last digits
-- off the end of both endpoint columns, and showing them needs 21 cells for an
-- IPv4 endpoint and 47 for an IPv6 one, because `socket_tables.lua` formats
-- addresses in RFC 5952 form and the longest uncompressed address is eight
-- groups.  Forty-seven cells to tell apart four connections to one service is a
-- price, and whether that is worth paying is a question about what the table is
-- *for* rather than something a guard can answer.
--
-- **The expectation runs the other way round from the rule's.** A table listed
-- here has to *still* collide: the day someone widens the columns or moves the
-- port in front of the address, this file goes red and asks for the entry to be
-- rewritten, instead of quietly passing on a product that no longer has the
-- defect the entry describes.  A recorded defect nobody can notice being fixed is
-- an excuse, and this way it is a debt that has to be paid deliberately.
local RECORDED_FORKS = {
  connection_table = "both endpoint columns are given 14 cells and the port's "
    .. "last digits fall off the end; an IPv4 endpoint needs 21 and an IPv6 one "
    .. "47, so the price of separating four connections to one service is a "
    .. "product decision, not a width this file can pick",
}
local fork_seen, collided_by_table = {}, {}
for _, name in ipairs(checked) do
  local model, originals, drawn, repeated = filled[name], {}, {}, false
  local duplicates = 0
  for index, row in ipairs(model.rows) do
    local raw, key = row_text(model, row, false), row_text(model, row, true)
    if originals[raw] then repeated = true end
    if not originals[raw] then originals[raw] = index end
    if drawn[key] then
      duplicates = duplicates + 1
      collided_by_table[name] = collided_by_table[name] or {}
      local list = collided_by_table[name]
      list[#list + 1] = string.format(
        "%s: rows %d and %d are the same string once every column is given the "
        .. "width the table guarantees: %q", name, drawn[key], index, key)
    end
    if not drawn[key] then drawn[key] = index end
    rows_checked = rows_checked + 1
  end
  require(not repeated,
    "the fixture gives " .. name .. " two rows that are identical before "
    .. "anything is cut, so a collision there would be the fixture's own")
  if RECORDED_FORKS[name] then
    fork_seen[name] = duplicates
    require(duplicates > 0,
      name .. " is listed as a recorded fork because its rows collided, and "
      .. "they no longer do (" .. (#model.rows) .. " rows, no pair alike). If "
      .. "that was a fix, delete the entry and say what changed; if the "
      .. "fixture stopped being able to produce the collision, that is a "
      .. "weaker claim than the one this file has been making")
  end
end

-- Non-vacuity, now stated over tables rather than over a list of columns,
-- which is the thing a list cannot do: this is every table the fixture can
-- fill, including the ones nobody remembered to name.  The floor is the
-- measured number with a cell of slack, not a round number -- and building a
-- single page answers for four of them, so a floor of five would have passed a
-- rule that was quietly checking a quarter of what it says it checks.
require(#checked >= 12,
  "only " .. #checked .. " table(s) carried rows in the second fixture ("
  .. (#checked > 0 and table.concat(checked, ", ") or "none")
  .. "); twelve do today, and the rule about rows staying tellable apart is not "
  .. "worth much when it is applied to a handful of tables")
-- Every recorded fork has to have been reached, or the list is a list of things
-- nobody checked -- the same failure as an unchecked column list, one level up.
for name in pairs(RECORDED_FORKS) do
  require(fork_seen[name],
    name .. " is on the recorded-fork list but no longer carries a collision, "
    .. "so the entry describes a table the fixture does not exercise")
end
-- Only a recorded fork is allowed to collide, and every pair it accounts for is
-- printed rather than counted, because "one fork" and "twelve pairs" are very
-- different claims and a bare number does not say which it is.
local unexplained, forks = {}, 0
for name, list in pairs(collided_by_table) do
  if not RECORDED_FORKS[name] then
    for _, entry in ipairs(list) do unexplained[#unexplained + 1] = entry end
  else
    forks = forks + 1
  end
end
table.sort(unexplained)
require(#unexplained == 0,
  "colliding rows in tables that are not recorded forks:\n    "
  .. table.concat(unexplained, "\n    "))

-- The Link column, which neither of the two rules can see.  A rate is a number
-- with a unit at the end of it, so a cut leaves a number: `100 Gbit…` is not a
-- different rate, it is a rate with nothing to say what it is a rate *of*, and
-- the first rule here only speaks when both the kept text and the value are
-- plain numbers.  The second rule cannot see it either, because the other
-- columns of the row tell two links apart perfectly well -- which is exactly
-- why it went unnoticed: the row is distinguishable, and the cell is still
-- unreadable.
--
-- So the clause is about the cell rather than the row, and the fixture is what
-- makes it non-vacuous: the base interfaces are all 10 Gbit/s, the one rate
-- that has always fitted, so a fixture built from them would pass against a
-- column that loses its unit on every link faster than that.
local link_column, link_model = nil, filled.network_table
if link_model then
  for _, column in ipairs(link_model.columns) do
    if column.key == "speed" then link_column = column end
  end
end
require(link_column,
  "the network table's Link column is not where this file expects it, so the "
  .. "clause about a rate keeping its unit was applied to nothing")
if link_column then
  local lost, widest, fastest = {}, 0, 0
  for _, row in ipairs(link_model.rows) do
    local value = row.speed
    if type(link_column.format) == "function" then
      value = link_column.format(value, row)
    end
    local text = tostring(value == nil and "—" or value)
    if #text > widest then widest = #text end
    -- The *rate*, not the digits: `100 Mbit/s` carries the digits 100 and is
    -- not the link this clause is about.  Reading the number off the front of
    -- the cell is the mistake that let the first version of this check pass a
    -- fixture whose fastest link was ten gigabits, and it is the same mistake
    -- as reading the pid out of a filename.
    local amount, unit = text:match("^([%d%.]+)%s+(.+)$")
    if amount and unit == "Gbit/s" then
      local rate = tonumber(amount)
      if rate and rate > fastest then fastest = rate end
    end
    if #text > link_column.min_width then
      lost[#lost + 1] = string.format("%q needs %d cells and the column "
        .. "guarantees %d", text, #text, link_column.min_width)
    end
  end
  require(#lost == 0,
    "link rates that lose something the column promised to show:\n    "
    .. table.concat(lost, "\n    "))
  require(fastest >= 100,
    "the fixture's fastest link is " .. fastest .. " Gbit/s; nothing at or "
    .. "above 100 Gbit/s means the clause is not looking at the range where "
    .. "this was broken")
end

assert(#failures == 0,
  table.concat(failures, "\n  ") .. "\n  (" .. #failures
  .. " problem(s); they are reported together so a run that finds a defect "
  .. "explains all of it)")

-- The two rules are swept over different things and their counts are not
-- interchangeable: the width sweep draws every table the fixture fills at 161
-- widths, and the row rule draws every table at the width each one guarantees.
local swept_tables = 0
for _ in pairs(tables_rendered) do swept_tables = swept_tables + 1 end
io.write(string.format(
  "ok: exact value widths (%d cells across %d tables, %d cuts, no wrong number; "
  .. "%d rows across %d tables, no unrecorded collision, %d recorded fork)\n",
  cells, swept_tables, cuts, rows_checked, #checked, forks))
