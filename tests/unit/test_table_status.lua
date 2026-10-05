-- A table that does not draw every column says so on the row, in every variant.
--
-- `table.lua` names its two notes after what they count: `▤ v/t` for columns and
-- `▾ r/n` for rows.  Both of them were correct, and both of them were behind the
-- same door -- `variant == "full"`.  The responsive solver picks the variant, so a
-- terminal too narrow for the `full` table was not given a narrower table, it was
-- given a *different* table, one that said nothing at all about the columns or the
-- rows it was holding back.  Three increments had asked this question of a table
-- (no silent cell cuts, rows reachable, the footer naming hidden panels) and every
-- one of them was answered by a component that reports what it dropped.  The
-- statement was the one place on the panel a reader could be told, and on the
-- variants the solver actually chooses it was switched off.
--
-- Measured on the product's own pages with the product's own data -- every page,
-- every width from 20 to 240, every height from 3 to 40, 4 480 renders carrying
-- 4 437 table placements -- **3 406 placements drew fewer columns than they were
-- given and 394 of those said so on the row: 3 012 were silent**, and they are the
-- `spark` (1 981), `value` (949) and `compact` (82) variants, with the `full`
-- variant silent zero times.  The same renders told the same story about rows:
-- 1 030 placements drew fewer rows than they had, 271 named them and **759 did
-- not**.  The sort column, measured and recorded, is never one of the hidden ones:
-- 0 placements in 4 437, which is why no rule here claims anything about it.
--
-- At 80x24 -- the geometry this product documents -- the compute page's table is a
-- `spark` panel 35 cells wide holding four of its seven columns, and its last row
-- is a data row.  That single placement is the whole of this file.
--
-- The denominator was the second defect, and it is the one a count cannot survive.
-- `columns_total` counted the columns *eligible for the variant*, so a `full_only`
-- column was excluded from the drawing and from the count: a reader told `▤ 2/5`
-- about a table given seven columns cannot tell "this table is narrow" apart from
-- "this table is not the one you left", and the `full_only` exclusion is four of
-- the process table's twelve columns.  The denominator is what the model handed the
-- table, and the numerator is what the table drew.
--
-- The price is real and it was measured before the fix was written, not after: over
-- the same sweep the data rows drawn fell from **36 851 to 34 067 -- 2 784 rows,
-- 7.6%** -- because a statement row is a row.  What it bought was 2 558 column
-- statements and 759 row statements that no longer sit silently, and it is paid
-- only by placements that were already hiding something.
--
-- There is a floor, and it is space rather than a defect: **454 of the placements
-- owe a column statement and have no row to spend it on**, every one of them a
-- `value` panel exactly one row tall.  A one-row table has a header and a data row
-- and no third row; the rule is stated for the panels that can speak, and the ones
-- that cannot are counted here rather than papered over.  This file asserts that
-- the count is exactly the set of panels with nowhere to put a statement -- a floor
-- that quietly grows is the same silence the file was written for.
--
-- What this file reads, and what it deliberately does not.  The rules below read
-- the *screen*: they find the statement row by the `dim` style on its cells rather
-- than by guessing a glyph (a data row can carry `#`, `v` and `+113` all at once),
-- they count the drawn columns off the header row, and they read the note's two
-- numbers back out of the text that was drawn.  The table's own return value is
-- not consulted for the numerator: `column_boxes` is used, but only as the
-- *partition* the screen is checked against -- every box must carry ink of its own,
-- no ink may sit outside every box, and each box must be followed by the blank
-- separator cell the product puts between columns.  Those three together are what
-- make the box count the number of columns on the screen rather than the number of
-- columns the table says it drew, and a first version of this file that read
-- `columns_visible` would have agreed with the defect it was written for.
--
-- The declaration -- how many columns the model gave the table, how many rows it
-- had, where it was scrolled to -- is read from the model, because the model is
-- the declaration and the component is the drawer.  That asymmetry is the point:
-- the rule checks the drawer against the declaration through the screen, and never
-- the component against itself.
--
-- The fixture is the product's.  The snapshot, the history series and the
-- capability states are lifted verbatim from `tests/unit/test_no_silent_cell_cuts.lua`,
-- and the drive is the product's own path -- `ViewModel.build` into
-- `workspace.render` with the arguments `tui.lua` hands it -- because a probe that
-- feeds a renderer something the product never feeds it measures a defect that is
-- the probe's own.
local I18n = require("wtop.i18n")
local Collectors = require("wtop.collectors")
local Inspectors = require("wtop.inspectors")
local ProcessTable = require("wtop.model.process_table")
local TableWidget = require("wtop.ui.widgets.table")
local ViewModel = require("wtop.view_model")
local Workspace = require("wtop.workspace")

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

local function history(values)
  local series = { n = #values }
  for index, value in ipairs(values) do series[index] = value end
  return series
end

local HISTORIES = {
  cpu = history({ 1.0, 2.0, 90.0, 3.0, 4.0 }),
  cpu_frequency = history({ 0.0, 1890000000.0, 0.0, 0.0, 0.0 }),
  memory = history({ 1.0, 2.0, 3.0 }),
  temperature = history({ 0.0, 69.8, 0.0, 0.0 }),
  cpu_power = history({ 0.0, 125.0, 0.0 }),
  network = history({ 0.0, 1024.0, 0.0 }),
}
local engine = { history_values = function(_, key) return HISTORIES[key] end }

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
local capabilities = probe_capabilities()
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

local failures = {}
local function require(condition, message)
  if not condition then failures[#failures + 1] = message end
end

-- Reading a row as cells, not as a string.  The statement row carries `▤` and the
-- cut marker is `…`; both are one cell and three bytes, and a header label in a CJK
-- catalogue is one cell and three bytes per character.  A row read as a string and
-- indexed by byte is not the row the product drew, and the first version of this
-- file's own measurement was wrong in exactly that way -- it reported 2 756
-- unreadable column labels and 1 370 panels with header ink outside the table's
-- own column boxes, every one of them an artefact of counting bytes.
local function cells_of(grid, x0, y, width)
  local out = {}
  for i = 1, width do
    local cell = grid:get(x0 + i - 1, y)
    out[i] = (cell and not cell.continuation) and cell.char or ""
  end
  return out
end
local function text_of(cells)
  local out = {}
  for i = 1, #cells do out[#out + 1] = (cells[i] == "") and " " or cells[i] end
  return (table.concat(out):gsub("%s+$", ""))
end
local function inked(cells)
  for i = 1, #cells do
    if cells[i] ~= "" and cells[i] ~= " " then return true end
  end
  return false
end

-- The statement row is found by the `dim` style on its cells, and by nothing else.
-- A glyph cannot carry it: the note is written over whatever `model.status_text`
-- the page gave the table, and the data rows of this very product carry `#`, `v`
-- and `+113` among their cells.  Measured over the sweep: 3 558 placements carried
-- a dim row, it was the panel's last row every time, and no placement ever carried
-- two -- the two facts this function relies on, checked below rather than assumed.
local function statement_y_of(grid, area)
  local found, twice = nil, false
  for y = area.y, area.y + area.height - 1 do
    for x = area.x, area.x + area.width - 1 do
      local cell = grid:get(x, y)
      if cell and cell.style and cell.style.dim then
        if found then twice = true; break end
        found = y
        break
      end
    end
    if twice then break end
  end
  return found, twice
end

-- A note is a mark, a space, and two numbers with a slash between them.  Reading the
-- whole shape rather than searching for a lone mark is what lets a *wrong* count
-- fail: `▤ 3/…` is neither `3/7` nor `3/11`, so a numerator that lost its
-- denominator cannot pass as a count.
local function read_note(cells, mark)
  for i = 1, #cells do
    if cells[i] == mark then
      local run = {}
      for k = i, #cells do run[#run + 1] = cells[k] end
      local v, t = table.concat(run):match("^" .. mark .. "%s+(%d+)/(%d+)")
      if v then return tonumber(v), tonumber(t) end
    end
  end
  return nil
end
local COLUMN_MARKS = { "▤", "#" }
local ROW_MARKS = { "▾", "v" }
local function either_note(cells, marks)
  for _, mark in ipairs(marks) do
    local v, t = read_note(cells, mark)
    if v then return v, t, mark end
  end
  return nil
end

-- The interception.  What each table was *given* is the model's own declaration and
-- is kept as data; what it drew is read off the grid in the rules below.
local real_table_render = TableWidget.render
local captured = {}
TableWidget.render = function(grid, area, model, context, variant)
  local result = real_table_render(grid, area, model, context, variant)
  captured[#captured + 1] = {
    variant = variant or "?", area = area, model = model, result = result, grid = grid,
  }
  return result
end

local engine = { history_values = function(_, key) return HISTORIES[key] end }
local pages = {}
for id in pairs(Workspace.new().pages) do pages[#pages + 1] = id end
table.sort(pages)

-- The reference catalogue, swept everywhere, and then the shapes that the reference
-- catalogue cannot reach: the ASCII spelling of the two marks, and four catalogues
-- whose column labels are one cell and one character (the CJK ones), long (German)
-- and wide-and-lowercase (Russian).  A rule about a statement row that has only ever
-- seen English ASCII labels has not seen a CJK column cut in half by it.
local WIDE = {}
for columns = 20, 240, 4 do WIDE[#WIDE + 1] = columns end
local HEIGHTS = { 3, 5, 8, 12, 16, 24, 32, 40 }
local NARROW = { 40, 56, 72, 88, 110, 140, 200 }
local NARROW_HEIGHTS = { 3, 8, 24 }
local CATALOGUES = { "zh-CN", "ja-JP", "de-DE", "ru-RU" }
local ASCII_GEOMETRIES = { { 20, 3 }, { 40, 8 }, { 60, 24 }, { 88, 12 }, { 140, 40 } }

local renders, placements = 0, 0
-- The closure of the column rule over every placement in the sweep.  These four
-- are exclusive and between them they are every placement there is, which is what
-- makes the sum an identity rather than four loose numbers: a table either owes a
-- column statement and can pay for it, owes one and cannot, or owes none.
local col_spoke, col_silent, col_nowhere, col_quiet = 0, 0, 0, 0
-- The closure of the row rule, in the same four shapes.  Its floor is the same
-- floor: a panel with no row to spend is a panel with no statement row at all.
local row_spoke, row_silent, row_nowhere, row_quiet = 0, 0, 0, 0
local row_numerator_checked, row_scrolled = 0, 0
-- Reading-side counters.  These are the rules' own instruments, so a rule that is
-- not reading the screen must be visible here as a zero.
local dim_rows, dim_not_last, dim_twice = 0, 0, 0
local box_no_ink, box_ink_outside, box_bad_separator, box_unordered = 0, 0, 0, 0
local full_only_hidden, ascii_marks = 0, 0
local header_without_sort_key = 0
local examples = {}
local function example(text)
  if #examples < 6 then examples[#examples + 1] = text end
end

local function check(placement)
  local grid, area, model, result = placement.grid, placement.area, placement.model,
    placement.result
  local where = string.format("%s %s %dx%d panel %dx%d at %d,%d", placement.page,
    placement.variant, placement.columns, placement.rows, area.width, area.height,
    area.x, area.y)
  local boxes = result.columns
  local boxes_ok = type(boxes) == "table" and #boxes > 0
  require(boxes_ok, where .. ": the table published no column boxes, so the header row "
    .. "has nothing to be checked against and the numerator below would be a number "
    .. "this file chose rather than one the screen carries")

  -- The published partition, checked against the header row that was drawn.  Three
  -- facts together, and all three are needed: each box carries ink of its own (so a
  -- box is not an empty reservation), no ink sits outside every box (so the boxes
  -- are not a subset of what was drawn), and each box is followed by the blank cell
  -- the product puts between columns (so the boxes do not overlap and the count is
  -- of columns rather than of glyph groups).  Only then is `#boxes` the number of
  -- columns on the screen rather than the number the table says it drew.
  local drawn, header_ok = 0, boxes_ok
  if boxes_ok then
    local header = cells_of(grid, area.x, area.y, area.width)
    local covered = {}
    local previous_right = nil
    for _, box in ipairs(boxes) do
      local own_ink, inside = false, true
      for i = 0, box.width - 1 do
        local index = box.x - area.x + i + 1
        if index < 1 or index > area.width then
          inside = false
        else
          covered[index] = true
          if header[index] ~= "" and header[index] ~= " " then own_ink = true end
        end
      end
      if previous_right ~= nil and box.x <= previous_right then
        box_unordered = box_unordered + 1
        header_ok = false
        example(where .. ": column boxes are not in reading order")
      end
      previous_right = box.x + box.width
      if not own_ink then
        box_no_ink = box_no_ink + 1
        header_ok = false
        example(where .. ": the box at " .. box.x .. " has no ink of its own in the "
          .. "header row")
      end
      if inside then drawn = drawn + 1 end
      local separator = grid:get(box.x + box.width, area.y)
      if separator and separator.char ~= " " then
        box_bad_separator = box_bad_separator + 1
        header_ok = false
        example(where .. ": the cell after the box at " .. box.x .. " is "
          .. string.format("%q", separator.char) .. ", not the blank between columns")
      end
    end
    for i = 1, #header do
      if not covered[i] and header[i] ~= "" and header[i] ~= " " then
        box_ink_outside = box_ink_outside + 1
        header_ok = false
        example(where .. ": the header row carries ink at cell " .. (area.x + i - 1)
          .. " that belongs to no column box")
        break
      end
    end
  end

  local declared = #(model.columns or {})
  local rows_total = #(model.rows or {})
  local offset = tonumber(model.offset) or 0
  -- A `full_only` column is one the variant will not draw at all.  It is counted
  -- here so that the denominator rule below is known to be exercised against it: a
  -- rule checked only on tables whose hidden columns were all width-limited would
  -- pass a table that counted the wrong denominator.
  for _, column in ipairs(model.columns or {}) do
    if type(column) == "table" and column.full_only then
      local found = false
      for _, box in ipairs(boxes or {}) do
        if box.key == (column.key or column.id) then found = true; break end
      end
      if not found then full_only_hidden = full_only_hidden + 1; break end
    end
  end

  local sy, twice = statement_y_of(grid, area)
  if twice then
    dim_twice = dim_twice + 1
    example(where .. ": two rows of the panel carry the dim style, so the statement "
      .. "row cannot be told from the row above it")
  end
  local statement
  if sy then
    dim_rows = dim_rows + 1
    if sy ~= area.y + area.height - 1 then
      dim_not_last = dim_not_last + 1
      example(where .. ": the statement is on row " .. sy .. " and the panel's last row "
        .. "is " .. (area.y + area.height - 1))
    end
    statement = cells_of(grid, area.x, sy, area.width)
  end

  -- The row count, read from the screen: the rows between the header and the
  -- statement, and the statement's own last row is not one of them.
  local body_rows = sy and (sy - area.y - 1) or (area.height - 1)
  if body_rows < 0 then body_rows = 0 end
  local body_inked = 0
  for k = 1, body_rows do
    if inked(cells_of(grid, area.x, area.y + k, area.width)) then body_inked = body_inked + 1 end
  end

  local has_room = area.height >= 3
  local owe_columns = declared > drawn
  local owe_rows = rows_total > offset + body_rows and body_rows > 0

  local col_value, col_total, col_mark
  local row_value, row_total
  if statement then
    col_value, col_total, col_mark = either_note(statement, COLUMN_MARKS)
    row_value, row_total = either_note(statement, ROW_MARKS)
    if col_mark and (col_mark == "#") then ascii_marks = ascii_marks + 1 end
  end

  -- Rule 1: a table that drew fewer columns than it was given says so, with the
  -- count it was given and the count it drew.  The variant is not in this rule: the
  -- defect was that it was.
  if owe_columns then
    if has_room then
      if col_value == nil then
        col_silent = col_silent + 1
        example(where .. ": the table drew " .. drawn .. " of the " .. declared
          .. " columns it was given and its statement row reads ["
          .. text_of(statement or {}) .. "]")
      else
        col_spoke = col_spoke + 1
        require(col_value == drawn, where .. ": the statement says " .. col_value
          .. " columns were drawn and the header row has " .. drawn)
        -- The denominator is the declaration, never the variant's eligible count.
        require(col_total == declared, where .. ": the statement's denominator is "
          .. tostring(col_total) .. " and the table was given " .. declared
          .. " columns")
      end
    else
      col_nowhere = col_nowhere + 1
      require(col_value == nil, where .. ": a panel " .. area.height
        .. " rows tall has nowhere to spend a statement, yet its row reads ["
        .. text_of(statement or {}) .. "]")
    end
  else
    col_quiet = col_quiet + 1
    require(col_value == nil, where .. ": the table drew all " .. declared
      .. " of its columns and still carried a column count on the row")
  end

  -- Rule 2: a table that drew fewer rows than it has says so, with the count it
  -- has and the index of the last row a reader can see.  Both numbers are read
  -- back off the row and checked against the screen, not against the table's
  -- report of how many rows it drew.
  if owe_rows then
    if has_room then
      if row_value == nil then
        row_silent = row_silent + 1
        example(where .. ": the table has " .. rows_total .. " rows, " .. body_inked
          .. " of them are on the screen, and its statement row reads ["
          .. text_of(statement or {}) .. "]")
      else
        row_spoke = row_spoke + 1
        require(row_total == rows_total, where .. ": the statement says there are "
          .. tostring(row_total) .. " rows and the model handed the table " .. rows_total)
        -- The numerator is the index of the last row in the window, not the number
        -- of rows in it, so the screen's own count is the last row's index: the
        -- rows above the window that were scrolled past, plus the body rows that
        -- carry ink.  Writing it as `offset + body_inked` rather than as
        -- `body_inked` is what makes the clause say something about a scrolled
        -- table, and a first version guarded it with `offset == 0` and so had a
        -- branch the sweep never reached.
        row_numerator_checked = row_numerator_checked + 1
        require(row_value == offset + body_inked, where .. ": the statement says row "
          .. row_value .. " of " .. rows_total .. " is the last one shown, and the "
          .. "window starts at " .. offset .. " and holds " .. body_inked
          .. " body rows carrying ink")
        if offset > 0 then row_scrolled = row_scrolled + 1 end
      end
    else
      row_nowhere = row_nowhere + 1
      require(row_value == nil, where .. ": a panel " .. area.height
        .. " rows tall has nowhere to spend a statement, yet its row reads ["
        .. text_of(statement or {}) .. "]")
    end
  else
    row_quiet = row_quiet + 1
    require(row_value == nil, where .. ": the table shows every row it has and still "
      .. "carried a row count on the row")
  end

  -- `headers` is what the event loop walks on a click, and it calls
  -- `set_sort(header.sort_key)`.  A box for a column that cannot sort is a click
  -- that sorts by nothing, so the sortable list stays the sortable list.
  for _, header in ipairs(result.headers or {}) do
    if header.sort_key == nil then header_without_sort_key = header_without_sort_key + 1 end
  end
end

-- The view model does not depend on the terminal size.  A real session builds it
-- once and re-renders the same models on every resize, so building one per
-- geometry measures the same thing for nothing.  The first version of this file
-- built 4 930 of them and the comment above said it was most of the runtime.
-- **It was not, and that comment is left here because being wrong about it is
-- what the measurement below is for**: hoisting the view model on its own took
-- seven minutes twenty seconds to seven minutes and four.  The workspace stays
-- per-geometry, because a resize does carry layout state.
local model_cache, translator_cache = {}, {}
local function translator_for(locale)
  -- `I18n.new` loads a whole catalogue and validates it against the reference, and
  -- this file built one per render rather than one per catalogue: 5 370 of them.
  -- That is where the seven minutes went.  Phased, the en-US sweep is 4.5 seconds
  -- of `Workspace.new`, **11 seconds of rendering** and 0.7 seconds of the reading
  -- the rules do, and caching the catalogue took the file from seven minutes
  -- twenty seconds to nineteen.  A guard that costs seven minutes is a guard the
  -- suite pays for on every run to test eleven seconds of product.
  if translator_cache[locale] == nil then
    translator_cache[locale] = assert(I18n.new({ locale = locale }))
  end
  return translator_cache[locale]
end

local function models_for(page, locale)
  local key = page .. "\0" .. locale
  if model_cache[key] == nil then
    local translator = translator_for(locale)
    local process_table = ProcessTable.new({ sort_key = "cpu", descending = true })
    local ok, models = pcall(ViewModel.build, engine, snapshot(), translator,
      capabilities, page, process_table)
    require(ok, "the view model for " .. page .. " in " .. locale .. " must build: "
      .. tostring(models))
    model_cache[key] = ok and models or false
  end
  return model_cache[key] or nil
end

local function sweep(page, columns, rows, unicode, locale)
  local translator = translator_for(locale)
  local models = models_for(page, locale)
  if models == nil then return end
  captured = {}
  local workspace = Workspace.new()
  workspace:select(page)
  local rendered, problem = pcall(workspace.render, workspace, columns, rows, {
    capabilities = { unicode = unicode }, i18n = translator, widgets = models, status = {},
    frequency_label = translator:t("sampling.update_frequency",
      { level = translator:t("sampling.frequency.medium") }),
  })
  require(rendered, "the " .. page .. " page must render at " .. columns .. "x" .. rows
    .. ": " .. tostring(problem))
  if not rendered then return end
  renders = renders + 1
  for _, placement in ipairs(captured) do
    placement.page, placement.columns, placement.rows = page, columns, rows
    placements = placements + 1
    check(placement)
  end
end

for _, page in ipairs(pages) do
  for _, columns in ipairs(WIDE) do
    for _, rows in ipairs(HEIGHTS) do
      sweep(page, columns, rows, true, "en-US")
    end
  end
end
for _, page in ipairs(pages) do
  for _, geometry in ipairs(ASCII_GEOMETRIES) do
    sweep(page, geometry[1], geometry[2], false, "en-US")
  end
  for _, catalogue in ipairs(CATALOGUES) do
    for _, columns in ipairs(NARROW) do
      for _, rows in ipairs(NARROW_HEIGHTS) do
        sweep(page, columns, rows, true, catalogue)
      end
    end
  end
end

-- The readings the rules are built on, checked before they are believed.
require(placements > 0, "no table was rendered, so no rule below was applied to anything")
require(dim_twice == 0, dim_twice .. " panels carried a dim row that was not the last row "
  .. "of the panel, or carried two of them; the statement row is located by that style")
require(dim_not_last == 0, dim_not_last .. " statements were drawn on a row that is not "
  .. "the panel's last row")
require(dim_rows > 0, "no statement row was drawn in the whole sweep, so every rule "
  .. "about what a statement must say was applied to nothing")
require(box_no_ink == 0, box_no_ink .. " published column boxes had no ink of their own "
  .. "in the header row, so the box count is not the drawn count")
require(box_ink_outside == 0, box_ink_outside .. " header rows carried ink that belongs to "
  .. "no published column box, so the boxes are not the whole of what was drawn")
require(box_bad_separator == 0, box_bad_separator .. " column boxes were not followed by "
  .. "the blank cell the product puts between columns, so they overlap and the count is "
  .. "of glyph groups rather than of columns")
require(box_unordered == 0, box_unordered .. " published column boxes were not in reading "
  .. "order")
require(header_without_sort_key == 0, header_without_sort_key .. " entries of the sortable "
  .. "header list carried no sort key, which is a click that sorts by nothing")
require(ascii_marks > 0, "the ASCII spelling of the column mark was never drawn, so the "
  .. "rule that a hidden column is named was only ever asked in one spelling")

-- The two closures.  Every placement in the sweep falls into exactly one of the
-- four shapes of each rule, and a rule whose closure does not add up is a rule whose
-- quiet cases are not the ones it thinks they are.
require(col_silent == 0, col_silent .. " placements drew fewer columns than they were "
  .. "given, had a row to spend on saying so, and said nothing")
require(col_spoke + col_silent + col_nowhere + col_quiet == placements,
  "the column rule's closure does not cover every placement: " .. col_spoke
  .. " owed and spoke, " .. col_silent .. " owed and were silent, " .. col_nowhere
  .. " owed and had nowhere to speak, " .. col_quiet .. " owed nothing, and there are "
  .. placements .. " placements")
require(row_silent == 0, row_silent .. " placements drew fewer rows than they had, had a "
  .. "row to spend on saying so, and said nothing")
require(row_spoke + row_silent + row_nowhere + row_quiet == placements,
  "the row rule's closure does not cover every placement: " .. row_spoke
  .. " owed and spoke, " .. row_silent .. " owed and were silent, " .. row_nowhere
  .. " owed and had nowhere to speak, " .. row_quiet .. " owed nothing, and there are "
  .. placements .. " placements")

-- And the shapes are not hollow: a sweep that never asked any of them would pass
-- every rule above.
require(col_spoke > 0, "no placement ever carried the column statement it owed")
require(col_nowhere > 0, "no placement ever owed a statement it had nowhere to put, so "
  .. "the floor is untested -- and a floor that quietly grows is the silence this file "
  .. "was written for")
require(col_quiet > 0, "no placement ever drew every column it was given, so the rule "
  .. "that a table with nothing to hide says nothing was applied to nothing")
require(row_spoke > 0, "no placement ever carried the row statement it owed")
require(row_quiet > 0, "no placement ever showed every row it had, so the rule that a "
  .. "table with nothing to hide says nothing was applied to nothing")
require(row_numerator_checked > 0, "the row statement's numerator was never checked "
  .. "against the rows on the screen")
require(full_only_hidden > 0, "no placement ever hid a column that only the `full` "
  .. "variant will draw, so the denominator rule was never asked the question it exists "
  .. "for -- a table told `2/5` about seven declared columns cannot tell 'narrow' from "
  .. "'not the one you left'")
require(#pages > 1 and #WIDE > 1 and #HEIGHTS > 1 and #CATALOGUES > 1
  and #ASCII_GEOMETRIES > 1,
  "the sweep is narrower than the product: it must vary the page, the width, the height, "
  .. "the catalogue and the spelling of the marks")

assert(#failures == 0,
  table.concat(failures, "\n  ") .. "\n  (" .. #failures
  .. " problem(s); they are reported together so a run that finds a defect explains all "
  .. "of it)")

io.write(string.format(
  "ok: a table says which columns and rows it did not draw (%d renders over %d pages, "
  .. "%d widths, %d heights, %d catalogues and both spellings of the marks; %d table "
  .. "placements; columns: %d carried the statement they owed, %d had nowhere to spend "
  .. "one and %d said nothing while owing it, %d owed nothing and stayed quiet; rows: %d "
  .. "carried the statement they owed, %d owed one with nowhere to put it, %d said nothing "
  .. "while owing it, %d owed nothing and stayed quiet; %d placements hid a `full_only` "
  .. "column, so the denominator rule was asked the question it exists for; the row "
  .. "numerator was checked against the screen %d times, %d of them on a table "
  .. "that had been scrolled)\n",
  renders, #pages, #WIDE, #HEIGHTS, #CATALOGUES + 1, placements, col_spoke, col_nowhere,
  col_silent, col_quiet, row_spoke, row_nowhere, row_silent, row_quiet, full_only_hidden,
  row_numerator_checked, row_scrolled))
