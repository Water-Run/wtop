-- Three ways a rendered cell can fail to show what it holds, all on one drive.
--
-- `Grid:write(x, y, text, style, max_width)` drops whatever does not fit and
-- leaves **no marker at all** -- a bare prefix that looks like a complete value.
-- `Width.truncate` is the other way a cell loses content and it always appends an
-- ellipsis, so the two are not equally bad: one says "this was cut", the other
-- does not. The burden is therefore on every widget, and nothing downstream
-- notices when one forgets.
--
-- The third is not about width at all. A cell can hold a *template* -- a message
-- whose `{placeholder}` was never filled in -- and it is neither too wide nor a
-- number, so neither of the other two rules can see it. The translator already
-- counts exactly this (`diagnostics().format_errors`) and nothing asserted it
-- while a render was running, which is how a sweep in this file spent its first
-- version measuring 140 pages that showed `Update rate: {level}`.
--
-- Increment 89 found the one place that had forgotten, by driving the real page
-- render over every tab, eight geometries and all ten catalogues: 104,192
-- bounded writes, boxes from 1 to 200 cells, and the metric chart's axis was
-- writing `1.89 GHz` and `69.8 °C` into four-cell boxes. That scan was a script
-- in /tmp -- it measured, and then it was gone, which is the shape this file
-- exists to end. The invariant is general and the fixture is the product: every
-- page it defines, every widget kind a layout can place, a spread of geometries
-- that enters every layout mode, and every catalogue the build ships -- each
-- list read from the product, and each held against a second, independent
-- account of what it should be, because a sweep that reads its own list back
-- reports the coverage it was given rather than the coverage it has.
--
-- The values in the snapshot are the extremes rather than this host's: a pid at
-- the kernel ceiling, a mount point long enough to need cutting, a name that
-- fills its column, and history with a spike between samples so the chart axis
-- has something to mis-measure if the gutter is ever wrong again.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grid = require("wtop.ui.renderer.grid")
local Collectors = require("wtop.collectors")
local I18n = require("wtop.i18n")
local Inspectors = require("wtop.inspectors")
local ProcessTable = require("wtop.model.process_table")
local Layout = require("wtop.ui.layout")
local Registry = require("wtop.ui.widgets")
local ViewModel = require("wtop.view_model")
local Width = require("wtop.ui.renderer.width")
local Workspace = require("wtop.workspace")

-- The pages, read from the product rather than written down here.  The first
-- version of this file listed the eight *tabs*, and the product has ten pages:
-- `memory` and `system` are drill-down pages reachable from a tab, and the second
-- of them is the one carrying the mount table -- so a sweep that rendered "all
-- eight tabs" had never rendered the page with the storage columns on it.  Eight
-- entries that look varied and are two pages short is the same mistake as the
-- geometry list, and it was found the same way: by asking the product what its
-- list is.  `Workspace.new().pages` is that list.
local function product_pages()
  local ids = {}
  for id in pairs(Workspace.new().pages) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end
local TABS = product_pages()

-- Every catalogue this build ships, read from the product rather than chosen.
-- The first version of this line was `{ "en-US", "ru-RU" }` with a comment
-- arguing the pair was picked for width -- "zh-CN is compact, ru-RU and ja-JP
-- are not" -- and the argument did not survive being applied to the line it
-- described: zh-CN is not in the list, and the catalogue most likely to
-- overrun a column is the one with the longest prose, which en-US and ru-RU are
-- not.  So the pair was a habit wearing the costume of a measurement, and it
-- cost nothing to notice because a rule that holds for two languages also holds
-- for the two you picked.
--
-- Running all ten is affordable and is now measured rather than assumed: 1.67s
-- for two became 8.44s for ten, against a 30s unit suite, and the ten pass.
-- What the extra eight bought is not a green result -- it is that the count of
-- format errors is a count over *catalogue*, so a message that is only wrong in
-- one language can now be seen, and the declared cuts rose from 453 to 2143,
-- which says the language axis moves the thing being measured and was never a
-- dimension this file could leave out.
local LOCALES = assert(I18n.available())

-- The catalogues are read from the runtime registry, so a locale the manifest
-- declares but the build does not carry would be missing from the sweep *and*
-- from this comparison.  `locales/manifest.yml` is the other file -- the
-- declaration the compiler reads, not the registry it produces -- so the two
-- can disagree, and that disagreement is the case worth catching: a language
-- announced in the manifest and absent from every rendered page.
--
-- The comparison is over the locales the build says it has implemented, which
-- is not every locale the manifest lists.  Twenty-one are declared and ten ship;
-- the other eleven are `planned`, and `tools/compile_locales.lua` drops those
-- when it builds the registry -- the manifest says of them, "catalog is not yet
-- implemented".  The first version of this clause asked for all twenty-one and
-- was red on eleven locales no sweep could ever render, which is the wrong
-- reason to be red: a clause that cannot be satisfied is not a strict one, it
-- is a broken one, and it would have been "fixed" by deleting the sweep.
local MANIFEST = assert(I18n.Yaml.parse_file("locales/manifest.yml"))
local DECLARED_LOCALES, PLANNED_LOCALES = {}, 0
for _, entry in ipairs(MANIFEST.locales or {}) do
  if type(entry) == "table" and type(entry.id) == "string" then
    if entry.status == "planned" then
      PLANNED_LOCALES = PLANNED_LOCALES + 1
    else
      DECLARED_LOCALES[#DECLARED_LOCALES + 1] = entry.id
    end
  end
end
table.sort(DECLARED_LOCALES)
-- Wide enough that the layout has to drop and shrink things, and wide enough
-- that it has room for everything: the bug was on the small end, but a rule that
-- only holds when columns are squeezed is a rule about one geometry.
--
-- The last two were added after checking which layout modes this list actually
-- enters, and the answer was that it entered four of five and never once entered
-- `wide-short` -- a 120-column terminal with fewer than 30 rows, which is what a
-- maximized window in a laptop's default desktop looks like. Five geometries
-- looked like coverage and were not: 60x30 is `tiny`, the same mode as 40x24, so
-- the list was one mode short while looking varied. The clause below is the
-- check that would have said so.
local GEOMETRIES = { { 40, 24 }, { 60, 30 }, { 100, 30 }, { 160, 45 },
                     { 200, 50 }, { 180, 24 }, { 200, 22 } }

-- `pid_max` cannot exceed 2^22, so this is the widest pid any kernel hands out.
local KERNEL_MAX_PID = 4194304
local LONG = string.rep("x", 180)

local function process(pid, name, command)
  return {
    id = tostring(pid) .. ":1", pid = pid, starttime_ticks = 1, parent_pid = 1,
    name = name, command = command, user = "tester", state = "S",
    cpu_percent = 12.5, resident_bytes = pid * 1024, virtual_bytes = pid * 4096,
    threads = 7, io = { read_bytes = 1, write_bytes = 2 },
  }
end

-- A series whose peak sits between samples, which is the case a one-cell
-- render cannot see and therefore the case a mis-measured chart gutter drops.
-- The spike is the point: the frequency series is 0, 1.89 GHz, 0, 0, 0, and a
-- gutter measured from a one-cell render sees only zeros.
local function history(values)
  local series = { n = #values }
  for index, value in ipairs(values) do series[index] = value end
  return series
end

-- The engine, not the snapshot, is where a chart's history comes from:
-- `view_model` asks `engine:history_values(key)`, and a stub that answers with an
-- empty table renders every chart with no data at all -- which is why the first
-- version of this fixture reported no axis labels on any geometry and looked
-- like a passing file rather than a blind one.
local HISTORIES = {
  cpu = history({ 1.0, 2.0, 90.0, 3.0, 4.0 }),
  cpu_frequency = history({ 0.0, 1890000000.0, 0.0, 0.0, 0.0 }),
  memory = history({ 1.0, 2.0, 3.0 }),
  temperature = history({ 0.0, 69.8, 0.0, 0.0 }),
  cpu_power = history({ 0.0, 125.0, 0.0 }),
  network = history({ 0.0, 1024.0, 0.0 }),
}

local function snapshot()
  local processes = {}
  for index, pid in ipairs({ KERNEL_MAX_PID, KERNEL_MAX_PID - 1, 4194303,
                             1048576, 9999, 1000, 1 }) do
    processes[index] = process(pid, "worker" .. index,
      string.format("worker%d --flag=%s", index, LONG))
  end
  local mounts = {}
  for index = 1, 6 do
    mounts[index] = {
      id = tostring(9000 + index),
      mount_point = "/mnt/a-considerably-long-mount-point-" .. index,
      fs_type = "ext4", source = "/dev/" .. LONG:sub(1, 40) .. index,
      kind = "local",
      capacity = { total_bytes = 1024 * 1024, used_percent = 41, available_bytes = 512,
                   block_size_bytes = 4096 },
      inodes = { used_percent = 12, total = 100, free = 88, used = 12,
                 reserved = 0, available = 88 },
      quality = "fresh", partial = false, readonly = false,
    }
  end
  local interfaces = {}
  for index = 1, 4 do
    interfaces[index] = {
      name = "enp0s3" .. index .. "1f" .. index, mtu = 1500, operstate = "up",
      speed_mbps = 10000, duplex = "full", mac = "aa:bb:cc:dd:ee:ff",
      rx_bytes = 1024, tx_bytes = 2048, rx_packets = 10, tx_packets = 20,
      rx_errors = 0, tx_errors = 0, rx_dropped = 0, tx_dropped = 0,
      quality = "fresh",
      -- Both families, and the IPv6 one written the way `socket_tables.lua`
      -- writes it: RFC 5952 form, so the longest address on a host with a
      -- real prefix is eight uncompressed groups and the address column is
      -- asked about the case it cannot fit.  A fixture whose interfaces carry
      -- no addresses at all leaves the whole address table unrendered, which is
      -- what this one did.
      addresses = {
        { family = "ipv4", address = "192.0.2." .. (10 + index),
          netmask = "255.255.255.0" },
        { family = "ipv6", address = "2001:0db8:0000:0000:0000:ff00:0042:8329",
          netmask = "ffff:ffff:ffff:ffff::" },
      },
      default_route = { families = { ipv4 = true, ipv6 = false } },
    }
  end
  local workloads = {}
  for index = 1, 5 do
    workloads[index] = {
      id = "c" .. index, name = "workload-" .. index, cgroup_path = "/probe/" .. index,
      state = "running", cpu_percent = 5, memory_bytes = 1024 * 64, quality = "fresh",
    }
  end
  local policies = {}
  for index = 1, 4 do
    policies[index] = {
      id = "policy" .. index, name = "policy" .. index,
      current_khz = 1890000 .. index, min_khz = 800000, max_khz = 4200000,
      governor = "schedutil", driver = "intel_pstate", quality = "fresh",
    }
  end
  local cores = {}
  for index = 0, 127 do
    cores[index + 1] = { name = "cpu" .. index, utilization = 0, user = 0, system = 0,
      iowait = 0, irq = 0, steal = 0, quality = "fresh" }
  end
  local gpus = {}
  for index = 1, 4 do
    -- Two processes per card, and the first one carries a pid at the kernel
    -- ceiling: the GPU process table declares its own `pid` column, and the
    -- reason it was six cells wide for as long as it was is that nothing ever
    -- put a seven-digit pid in it.
    local gpu_processes = {
      { id = tostring(index * 10), pid = KERNEL_MAX_PID, name = "trainer",
        utilization_percent = 91, memory_summary = { resident_bytes = 8 * 1024 * 1024 * 1024 },
        engines = { { utilization_percent = 61 }, { utilization_percent = 30 } },
        quality = "fresh" },
      { id = tostring(index * 10 + 1), pid = 4194303, name = "renderer",
        utilization_percent = 4, memory_summary = { resident_bytes = 256 * 1024 * 1024 },
        quality = "fresh" },
    }
    gpus[index] = { id = "card" .. index, card = "card" .. index,
      model_name = "NVIDIA GeForce RTX 4090", vendor = "pci", vendor_name = "NVIDIA",
      driver = "nvidia", pci = { current_link_speed = "16 GT/s", current_link_width = 16 },
      metrics = { utilization_percent = 0, memory_used_bytes = 0,
                  memory_total_bytes = 25757220864, frequency_current_hz = 2100000000 },
      frequencies = { domains = { { name = "graphics" } } },
      processes = { list = gpu_processes, quality = "fresh" },
      quality = "fresh" }
  end
  -- Two ports of one on-board controller, because `0000:00:1f.6` and
  -- `0000:00:1f.7` are the pair that shares a model name and differs only in
  -- its last character, and a fixture with one device per controller never asks
  -- whether the address column can tell them apart.
  local pci_devices = {
    { address = "0000:00:1f.6", vendor_id = 0x8086, vendor_name = "Intel Corporation",
      device_name = "Ethernet Connection I219-V", class_id = 0x0200 },
    { address = "0000:00:1f.7", vendor_id = 0x8086, vendor_name = "Intel Corporation",
      device_name = "Ethernet Connection I219-V", class_id = 0x0200 },
    { address = "0000:01:00.0", vendor_id = 0x10de, vendor_name = "NVIDIA Corporation",
      device_name = "GA104 [GeForce RTX 4090]", class_id = 0x0300 },
  }
  return {
    host = { hostname = "probe", kernel = "linux", uptime_seconds = 98765 },
    -- 128 cores, not the sixteen `cpu_info` claims.  The core table draws
    -- `cpu<N>`, and `cpu100` is where the name stops fitting in the width this
    -- column used to guarantee -- a fixture with sixteen cores cannot ask the
    -- question at all, which is how a table full of empty space stayed outside
    -- all three rules below.
    cpu = { usage_percent = 12, quality = "fresh", cores = cores },
    memory = { total_bytes = 16 * 1024 * 1024 * 1024, used_bytes = 8 * 1024 * 1024 * 1024,
               available_bytes = 8 * 1024 * 1024 * 1024, quality = "fresh" },
    pressure = { cpu = { some = { avg10 = 1.2 } }, memory = { some = { avg10 = 0.4 } },
                 io = { some = { avg10 = 0.1 } }, quality = "fresh" },
    cpu_info = { logical_cores = 128, model = "probe cpu" },
    disks = { devices = { { id = "sda", model = LONG:sub(1, 60), size = 1024,
                            medium = "SSD", quality = "fresh", read_bytes_per_second = 1,
                            write_bytes_per_second = 1, busy_percent = 3,
                            queue_depth = 1, read_latency_ms = 1 } } },
    network = { interfaces = interfaces, addresses_status = "fresh" },
    processes = { list = processes, truncated = false, clock_ticks_per_second = 100,
                  total = #processes, process_candidates = #processes },
    cpu_frequency = { policies = policies, current_quality = "fresh",
                      current_hz = 1890000000 },
    -- Four of the same card, which is what a four-GPU box is: one model, one
    -- driver, one clock, all idle.  Every column but the card's own name reads
    -- the same, so the device table and the process table are both asked the
    -- question they exist to answer.  `gpus = { devices = {} }` was here
    -- instead, and two tables had nothing in them for the life of this file.
    gpus = { devices = gpus, process_scan = { status = "ok", quality = "partial" } },
    sensors = { devices = { { class = "hwmon0", name = "probe",
                             channels = { { type = "temperature", input = 69.8,
                                            quality = "fresh" } } } } },
    power = { zones = { { name = "package-0", power_watts = 12.5, quality = "fresh" } } },
    quality = { mounts = { status = "ok", quality = "fresh" },
                disks = { status = "ok", quality = "fresh" } },
    connections = { owner_scan = { quality = "fresh" }, connections = {
      { id = "1", protocol = "tcp", state = "ESTABLISHED",
        local_endpoint = { text = "127.0.0.1:1" },
        remote_endpoint = { text = "198.51.100.1:443" }, owners = {} } } },
    mounts = { mounts = mounts },
    workloads = { workloads = workloads, summary = {} },
    -- The device inventory is read from `inventory`, not from `system`: the
    -- two sit next to each other in the snapshot and only one of them is the
    -- slot this table reads, which is the kind of thing a fixture guesses and
    -- gets wrong silently.
    inventory = { pci = { devices = pci_devices, total = #pci_devices },
                  usb = { devices = {}, total = 0 } },
  }
end

-- ---------------------------------------------------------------------------
-- The rule, and the drive.  A cell written into a box is a promise that the text
-- fits, and the grid keeps that promise silently or not at all.
-- ---------------------------------------------------------------------------
local cuts, bounded, self_check_cuts = {}, 0, 0
local self_check = false
local written = {}
local real_write = Grid.write
Grid.write = function(self, x, y, text, style, max_width)
  if max_width then
    bounded = bounded + 1
    local limit = math.max(0, math.floor(max_width))
    text = tostring(text or "")
    if not self_check then written[#written + 1] = text end
    if Width.display_width(text, self.width_options) > limit then
      if self_check then
        self_check_cuts = self_check_cuts + 1
      else
        cuts[#cuts + 1] = string.format("%d-cell box at (%d,%d) holds %q of %q",
          limit, x, y,
          Width.truncate(text, limit, self.width_options), text)
      end
    end
  end
  return real_write(self, x, y, text, style, max_width)
end

local failures = {}
local function require(condition, message)
  if not condition then failures[#failures + 1] = message end
end

-- The detector, handed the case it must catch, with its own write flagged so it
-- cannot be reported as a product defect.
self_check = true
Grid.new(40, 4):write(1, 1, "1.89 GHz", nil, 4)
Grid.new(40, 4):write(1, 1, "4194304", nil, 3)
require(self_check_cuts == 2,
  "an over-wide write was not detected, so a count of zero proves nothing")
self_check = false

-- The second rule, on the same sweep: a cell may be *cut* -- that is the
-- convention, and the ellipsis says so -- but it may never be left holding a
-- different number.  It needs the other hook, because this rule is about the
-- text *before* the cut; the write hook above only ever sees what survived.
--
-- Both rules are on one drive on purpose.  A cell can lose content silently, or
-- lose a number's identity visibly, and a sweep that watched only one of them
-- would have called increment 89's defect absent: the metric axis wrote
-- `"1.89"` into a four-cell box, which is the second rule's shape, and it did so
-- through the first rule's path, and neither hook sees the other's evidence.
local wrong, truncations, self_check_wrong = {}, 0, 0
local function numeric_token(text)
  local body = text:gsub("^%s+", ""):gsub("%s+$", "")
  local integer, fraction = body:match("^(%d+)%.(%d+)$")
  if integer then return tonumber(integer .. "." .. fraction) end
  local whole = body:match("^(%d+)$")
  if whole then return tonumber(whole) end
  return nil
end
local real_truncate = Width.truncate
Width.truncate = function(text, max_width, options, ellipsis)
  local out, truncated = real_truncate(text, max_width, options, ellipsis)
  if truncated then
    truncations = truncations + 1
    local kept = out
    for _, mark in ipairs({ "\u{2026}", "." }) do
      if kept:sub(-#mark) == mark then kept = kept:sub(1, -(#mark + 1)) break end
    end
    local shown, value = numeric_token(kept), numeric_token(tostring(text))
    if kept ~= out and shown and value and shown ~= value then
      if self_check then
        self_check_wrong = self_check_wrong + 1
      else
        wrong[#wrong + 1] = string.format("%q is drawn as %q in a %d-cell cell",
          tostring(text), out, max_width)
      end
    end
  end
  return out, truncated
end

-- The second rule's detector, handed the case it must catch, with the same flag
-- the first rule's uses: a self-check that reports itself as a product defect is
-- the mistake this project keeps making, and the flag is what prevents it.
--
-- It calls `Width.truncate`, not the saved original, and that is the whole
-- subtlety: the first version of these two lines called `real_truncate`, which
-- is the function *behind* the hook, so the self-check exercised the renderer
-- instead of the rule -- and failed, having found that a check which cannot pass
-- is at least a check that cannot lie.  A self-check that calls the thing behind
-- the thing it is checking is the most comfortable kind of wrong code to write,
-- because it looks like a direct call to the function under test and is not.
self_check = true
Width.truncate("4194304", 5, nil, "\u{2026}")
Width.truncate("1.2 GiB", 5, nil, "\u{2026}")
require(self_check_wrong == 1,
  "a pid cut between two digits was not recognised, so a count of zero proves "
  .. "nothing about the second rule either")

-- The third rule's self-check, and it asks the product rather than this file.
-- A cell can be too narrow to hold what it is given, and it can be cut into a
-- different number, and there is a third way a rendered cell lies: it holds a
-- *template*.  `Translator:t(id)` called without its variables does not fail
-- loudly -- `Format.interpolate` returns nil, the translator increments
-- `format_error_count`, hands the raw template back, and the page shows
-- `Update rate: {level}`.  Nothing downstream notices, and the two rules above
-- cannot: the text is not too wide and it is not a number.  That is a defect
-- the sweep drove into and did not see, for the whole time it was here.
--
-- The count is the product's own, asked for through `diagnostics()`, and not a
-- search of the write stream for a brace.  The difference is not a style
-- choice: a template cut down to six cells no longer *contains* `{level}`, so a
-- brace search reports a clean page for a page that is showing a template, and
-- it would do that precisely where the templates are most likely to be cut.
local UNINTERPOLATED_PROBE = "sampling.update_frequency"
local probe = assert(I18n.new({ locale = "en-US" }))
local before_probe = probe:diagnostics().format_errors
local probe_text = probe:t(UNINTERPOLATED_PROBE)
local after_probe = probe:diagnostics().format_errors
require(after_probe == before_probe + 1,
  "looking up a placeholder message without its variables did not register a "
  .. "format error, so a count of zero from the sweep below would prove "
  .. "nothing about the third rule")
require(type(probe_text) == "string" and probe_text:find("{level}", 1, true) ~= nil,
  "the probe message no longer carries a placeholder, so the rule is being "
  .. "tested against a message that cannot fail it")

self_check = false

-- Which widget kinds the sweep actually rendered.  The list of tabs is not the
-- coverage of the widget kinds either: a page can change what it places, and a
-- sweep that renders "all eight tabs" then silently stops rendering one kind.
local kinds_rendered = {}
local real_registry_render = Registry.render
Registry.render = function(self, kind, grid, area, model, context, variant)
  kinds_rendered[kind] = (kinds_rendered[kind] or 0) + 1
  return real_registry_render(self, kind, grid, area, model, context, variant)
end

local engine = { history_values = function(_, key)
  return HISTORIES[key]
end }
-- Two different things share the name "capabilities" and conflating them is how
-- the hole this increment closed stayed open.  The *terminal's* capabilities
-- say what the renderer may assume about the display, and the product always
-- passes `{ unicode = true }` for them.  The *collectors'* capabilities are the
-- probe results the view model reads, and passing the terminal's one to that
-- argument meant the Insights page's two tables were built with no rows at all:
-- `collector_table` has seventeen of them and `inspector_table` three, and both
-- came back empty, so the two tables carrying the Reason column were outside
-- every rule in this file for as long as the file existed.
--
-- The id lists come from the product: `Collectors.constructors` is the set a
-- Linux build registers, and `Inspectors.new_default()` is the registry the
-- product itself probes.  The reason codes are the measured extremes -- the
-- longest label in at least one of the ten catalogues for each of them -- rather
-- than a sample, because seven of the 1560 (code, catalogue) pairs fit the ten
-- cells the Reason column guarantees and a short code would be the one case the
-- column is not asked about.
local COLLECTOR_REASONS = {
  "gpu_identity_inferred", "memory_counter_read_unverified", "hwmon_value_derived",
  "cpufreq_value_derived", "cpu_counter_delta_unavailable",
}
local CAPABILITY_STATES = { "available", "unavailable", "denied", "degraded", "error" }
local CAPABILITY_SOURCES = {
  "/sys/devices/system/cpu/cpufreq", "/sys/devices/system/cpu/cpuidle",
  "/proc/net/tcp", "/proc/net/unix", "/proc/stat", "/proc/meminfo",
  "/proc/pressure/cpu", "/proc/pressure/memory", "/proc/pressure/io",
  "/proc/self/mountinfo", "/proc/self/fd", "/proc/cpuinfo", "/proc/uptime",
  "/proc/loadavg", "/proc/diskstats", "/sys/class/drm", "/sys/class/hwmon",
  "/sys/class/power_supply", "/sys/fs/cgroup", "/sys/bus/pci/devices",
  "/sys/devices/virtual/dmi/id", "/sys/devices/system/cpu/online",
}
local function probe_capabilities()
  local ids = {}
  for id in pairs(Collectors.constructors) do ids[#ids + 1] = id end
  table.sort(ids)
  local result = { inspectors = {} }
  for index, id in ipairs(ids) do
    local state = CAPABILITY_STATES[(index % #CAPABILITY_STATES) + 1]
    result[id] = {
      state = state, available = state == "available",
      reason = COLLECTOR_REASONS[(index % #COLLECTOR_REASONS) + 1],
      source = CAPABILITY_SOURCES[(index % #CAPABILITY_SOURCES) + 1],
    }
  end
  for index, id in ipairs(Inspectors.new_default().order) do
    local state = CAPABILITY_STATES[index]
    result.inspectors[id] = {
      state = state, available = state == "available", reason = COLLECTOR_REASONS[index],
    }
  end
  return result
end
local probe_capabilities_fixture = probe_capabilities()
-- The clause that keeps the hole shut, and it is a *count with the names in it*
-- rather than a floor, because a floor cannot say which tables went missing: the
-- two that did are exactly two, so a floor of twelve passes on a tree that has
-- quietly stopped checking the Reason column altogether.
local declared_tables, filled_tables = {}, {}
local function note_declared(page_models)
  for name, model in pairs(page_models) do
    if type(model) == "table" and type(model.rows) == "table" then
      declared_tables[name] = (declared_tables[name] or 0) + #model.rows
    end
  end
end
local capabilities = { unicode = true }
local pages, pages_by_id, translators = 0, {}, {}
for _, locale in ipairs(LOCALES) do
  local translator = assert(I18n.new({ locale = locale }))
  translators[#translators + 1] = translator
  for _, geometry in ipairs(GEOMETRIES) do
    local columns, rows = geometry[1], geometry[2]
    for _, tab in ipairs(TABS) do
      local workspace = Workspace.new()
      workspace:select(tab)
      local ok, models = pcall(ViewModel.build, engine, snapshot(), translator,
        probe_capabilities_fixture, tab, ProcessTable.new({ sort_key = "cpu", descending = true }))
      require(ok, "the view model for " .. tab .. " must build: " .. tostring(models))
      if ok then note_declared(models) end
      -- `frequency_label` is part of what the real caller hands to a render --
      -- `tui.lua` builds it from the selected level and passes it every time.
      -- The first version of this drive left it out, and the tab bar has a
      -- fallback for a missing one: it looks up `sampling.update_frequency`
      -- *without* the variables, so the translator returns the template
      -- un-interpolated and the page carries the literal text
      -- `Update rate: {level}`.  Measured, that fallback fired on all 140
      -- renders, and the sweep was the only thing putting it there -- the
      -- product's own path always supplies the value.  A probe that feeds the
      -- renderer something the product never feeds it measures a defect that
      -- is the probe's own, and it did so while the two rules below stayed
      -- green, because an un-interpolated template is not too wide and not a
      -- number: it is a third kind of wrong, which is what the rule after the
      -- sweep exists for.
      local rendered, problem = pcall(workspace.render, workspace, columns, rows, {
        capabilities = capabilities, i18n = translator, widgets = models, status = {},
        frequency_label = translator:t("sampling.update_frequency",
          { level = translator:t("sampling.frequency.medium") }),
      })
      require(rendered, tab .. " at " .. columns .. "x" .. rows
        .. " must render: " .. tostring(problem))
      if rendered then pages = pages + 1; pages_by_id[tab] = true end
    end
  end
end

-- The same drive with the field *withheld*, over two geometries and every page.
-- The drive above is the product's own path and it has to be -- feeding a
-- renderer something the product never feeds it manufactures defects, and the
-- two rules below were green through 140 of them.  But a drive that always
-- supplies the value cannot see the product's handling of its absence, and that
-- handling is exactly where the defect was: `tab_bar.lua` had a fallback which
-- looked the message up without its variables.  Measured, restoring that
-- fallback while this drive supplies the field leaves every rule here green,
-- because the field makes the line unreachable -- so the only way this file can
-- know whether the product survives a missing value is to withhold it.
--
-- Two geometries rather than seven because the third rule is not a width rule:
-- the message is either interpolated or it is not, and the narrowest and widest
-- geometry in the list between them cover the case where the header has no room
-- to be wrong in and the case where it has.
local withheld = assert(I18n.new({ locale = "en-US" }))
translators[#translators + 1] = withheld
local unfed_renders = 0
for _, geometry in ipairs({ GEOMETRIES[1], GEOMETRIES[#GEOMETRIES] }) do
  local columns, rows = geometry[1], geometry[2]
  for _, tab in ipairs(TABS) do
    local workspace = Workspace.new()
    workspace:select(tab)
    local ok, models = pcall(ViewModel.build, engine, snapshot(), withheld,
      probe_capabilities_fixture, tab, ProcessTable.new({ sort_key = "cpu", descending = true }))
    require(ok, "the view model for " .. tab .. " must build without a "
      .. "frequency label: " .. tostring(models))
    local rendered, problem = pcall(workspace.render, workspace, columns, rows, {
      capabilities = capabilities, i18n = withheld, widgets = models, status = {},
    })
    require(rendered, tab .. " at " .. columns .. "x" .. rows
      .. " must render without a frequency label: " .. tostring(problem))
    if rendered then unfed_renders = unfed_renders + 1 end
  end
end
Grid.write = real_write
Width.truncate = real_truncate
Registry.render = real_registry_render

-- Reachability, stated about the *label* rather than about the model.  The first
-- version of this clause counted the models that carry an `axis_format`, and it
-- passed on a fixture that never drew an axis label at all -- which is how the
-- first version of this file reported the increment-89 defect as absent while the
-- defect was in the tree.  A model that has an axis formatter is not a chart that
-- drew an axis; the thing that has to appear is the label, so that is what is
-- looked for.  It is also the clause that says the file is not vacuous: under the
-- defect the label is cut, so it never reaches the stream intact, and the rule
-- clause above fires as well.
local axis_labels = 0
for _, text in ipairs(written) do
  if text:find("GHz", 1, true) then axis_labels = axis_labels + 1 end
end

-- Every layout mode the solver can choose, entered at least once.  A sweep that
-- lists five geometries has not thereby covered five things: two of these enter
-- the same mode, and the mode nobody thought to include is the one that goes
-- unchecked.
local modes, expected = {}, { "tiny", "narrow-tall", "standard",
                              "wide-short", "wide-tall" }
for _, geometry in ipairs(GEOMETRIES) do
  modes[Layout.mode(geometry[1], geometry[2])] = true
end
local missed = {}
for _, mode in ipairs(expected) do
  if not modes[mode] then missed[#missed + 1] = mode end
end
require(#missed == 0,
  "the sweep never enters the " .. table.concat(missed, ", ")
  .. " layout mode, so a defect that only appears there is not covered")

require(pages == #LOCALES * #GEOMETRIES * #TABS,
  "only " .. pages .. " pages rendered, not the "
  .. (#LOCALES * #GEOMETRIES * #TABS) .. " this file sweeps")
-- The floor is set from the measurement rather than left at the value the first
-- version happened to have: it was `> 4000` against 5,099 bounded writes, which
-- is a floor no change to this file could cross, and the ten-catalogue drive
-- measures 50,796.  A reachability floor that sits below the measurement it was
-- written from is not a check.
require(bounded > 40000,
  "only " .. bounded .. " bounded writes were made (50796 when measured); the "
  .. "widgets were not exercised")
require(axis_labels > 0,
  "no chart axis label reached the screen, so the family that produced this "
  .. "defect is not in the sweep and the file would pass while the chart axis "
  .. "went unchecked")
require(#cuts == 0,
  "cells written into boxes too small for them, with no marker:\n    "
  .. table.concat(cuts, "\n    "))
require(truncations > 0,
  "nothing was cut anywhere in the sweep, so the second rule was never applied "
  .. "to a cut and its zero says nothing")
require(#wrong == 0,
  "cells left holding a different number:\n    " .. table.concat(wrong, "\n    "))

-- The third rule.  The count is the translator's, summed over every catalogue
-- the sweep rendered, and the clause names the message it saw rather than a
-- count: "somewhere a template was not interpolated" is not a report anybody
-- can act on, and this file is the only place that knows the sweep touched
-- every page.
local format_errors, unrendered_message = 0, nil
for _, translator in ipairs(translators) do
  local diagnostics = translator:diagnostics()
  if diagnostics.format_errors and diagnostics.format_errors > 0 then
    format_errors = format_errors + diagnostics.format_errors
    unrendered_message = unrendered_message or diagnostics.last_format_error
  end
end
require(unfed_renders == #TABS * 2,
  "only " .. unfed_renders .. " of the " .. (#TABS * 2)
  .. " renders that withhold the frequency label ran, so what the product does "
  .. "without that field is not covered")
require(format_errors == 0,
  format_errors .. " message(s) were rendered with a placeholder left in them, "
  .. "so the page shows a template where it should show a value: "
  .. tostring(unrendered_message))

-- Every widget kind the *pages declare*, reached at least once.  The registry is
-- not that list: it also holds `gauge` and `timeseries`, which are the metric
-- renderer under other names, and `process_table`, which is the table renderer
-- under another name, and asking for all of them would demand coverage of three
-- spellings of two widgets.  The layouts are the product's own account of what
-- can appear, so the kinds are read out of them rather than written down here.
local declared = {}
local function collect(node, depth)
  if type(node) ~= "table" or depth > 12 then return end
  if type(node.kind) == "string" then declared[node.kind] = true end
  for _, value in pairs(node) do
    if type(value) == "table" then collect(value, depth + 1) end
  end
end
local missing_kinds = {}
for _, tab in ipairs(TABS) do
  local workspace = Workspace.new()
  workspace:select(tab)
  collect(workspace.pages[tab] and workspace.pages[tab].layout, 0)
end
-- And the pages themselves: the list the sweep renders has to be the list the
-- product has, or the clause above is only checking the pages that happen to be
-- in it.  **The list it is compared against must not be the same list the sweep
-- iterated**, which is the shape the first version of this clause had and the
-- reason it was a clause that could not fail: it compared the rendered pages
-- against `product_pages()`, which is also what built the list of pages to
-- render, so a page missing from that one call was missing from both sides and
-- the comparison reported full coverage of a list with a hole in it.  Measured,
-- dropping `system` from the sweep left this file green -- while rendering 126
-- pages instead of 140 and printing 126 as though it were the count.
--
-- What is compared against is `workspace.tabs`, the tab definitions the pages
-- are *built from* and a table this file never reads to decide what to render.
-- A tab with no page behind it is the real defect this clause is for: the
-- header would be there and the page would not.
local unrendered_pages = {}
for _, specification in ipairs(Workspace.new().tabs) do
  if not pages_by_id[specification.id] then
    unrendered_pages[#unrendered_pages + 1] = specification.id
  end
end
require(#unrendered_pages == 0,
  "pages the product defines that this sweep never rendered: "
  .. table.concat(unrendered_pages, ", "))

-- And the catalogues, against the manifest rather than against the registry the
-- sweep took them from.  The first clause in this group is the one that cannot
-- fail; this one is written so that it can, and its emptiness is checked in the
-- same breath -- a manifest that parsed to nothing would leave the comparison
-- below trivially satisfied, which is the shape of every one of the rules this
-- file has been rewritten to avoid.
require(#DECLARED_LOCALES > 0,
  "the locale manifest parsed to no implemented catalogues, so the comparison "
  .. "against it is an empty set and the clause below cannot fail")
local swept_catalogues = {}
for _, locale in ipairs(LOCALES) do swept_catalogues[locale] = true end
local unswept_catalogues = {}
for _, id in ipairs(DECLARED_LOCALES) do
  if not swept_catalogues[id] then unswept_catalogues[#unswept_catalogues + 1] = id end
end
require(#unswept_catalogues == 0,
  "catalogues the manifest declares that this sweep never rendered: "
  .. table.concat(unswept_catalogues, ", ")
  .. "; the rules above were not applied in those languages")

for kind in pairs(declared) do
  if not kinds_rendered[kind] then missing_kinds[#missing_kinds + 1] = kind end
end
table.sort(missing_kinds)
require(#missing_kinds == 0,
  "widget kinds the pages declare that this sweep never rendered: "
  .. table.concat(missing_kinds, ", ")
  .. "; a defect that only appears in one of them would not be covered here")

-- And the same question one level down, about tables rather than kinds, because
-- a kind can be rendered and still be checked on nothing: every model the view
-- model returns for a page it was asked for, and every page here is asked for.
-- The two that used to be missing are the Insights tables, and the reason is
-- written above where the fixture is: a table built from a capabilities table
-- with no collectors in it has no rows, and a table with no rows cannot be cut
-- and so cannot fail any of the three rules.  The clause names them rather than
-- counting them -- two tables going missing is inside the slack of any floor,
-- which is how they stayed missing.
local empty_tables, swept_tables, rows_swept = {}, 0, 0
for name, rows in pairs(declared_tables) do
  if rows == 0 then empty_tables[#empty_tables + 1] = name else
    swept_tables = swept_tables + 1
    rows_swept = rows_swept + rows
  end
end
table.sort(empty_tables)
require(#empty_tables == 0,
  "tables the pages declare that this sweep was given no rows for: "
  .. table.concat(empty_tables, ", ")
  .. "; a defect that only appears in one of them would not be covered here")

assert(#failures == 0, table.concat(failures, "\n  ") .. "\n  ("
  .. #failures .. " problem(s), reported together)")

-- The truncation count is printed as what it is: cuts that *declared*
-- themselves, with an ellipsis.  Calling that number "cuts" in a line that
-- begins "no silent cell cuts" invites reading it as the count of defects, and
-- the first version of this line said exactly that.  Zero is only meaningful
-- when the zero and the non-zero are named separately.
io.write(string.format(
  "ok: no silent cell cuts (%d pages, %d bounded writes, %d axis labels, "
  .. "%d declared cuts, no wrong number, no un-interpolated message, "
  .. "%d layout modes, %d widget kinds, %d catalogues, %d renders without a "
  .. "frequency label, %d tables holding %d rows)\n",
  pages, bounded, axis_labels, truncations, #expected,
  (function() local n = 0 for _ in pairs(kinds_rendered) do n = n + 1 end return n end)(),
  #LOCALES, unfed_renders, swept_tables, rows_swept))
