-- Panel titles: the last strip of chrome with no rule on it.
--
-- The tab bar got a rule in increment 101, the footer got one in increment 103
-- and the overlay got two in increment 102, and all three of those are things the
-- user reads to answer a question -- *where am I*, *what just happened*, *what is
-- this*.  The panel frame is the fourth, and it is the one every widget sits in:
-- the title is drawn into the top border, and it is the only thing on the panel
-- that says which widget this is.  `panel.lua` truncates it to `area.width - 6`,
-- so it can lose its tail, and nothing had ever asked whether two panels on one
-- page can still be told apart -- which is the question increment 95 asked of a
-- table row, and the one that found `core_table` failing.
--
-- The rule is the weak one on purpose: *no two titles draw the same*.  It says
-- nothing about whether a title is complete, only that you can still tell the
-- panels apart, and that is the property the frame exists to provide.  It is
-- silent about truncation because truncation here is declared and identifying:
-- the measured result is 1 218 title renders at reachable widths with 42 of them
-- cut, every one of them at a frame of 19 or 27 cells, and every cut still names
-- its panel -- `CPU utilization` becomes `CPU utilizat…`, `Filesystems & mounts`
-- becomes `Filesystems …`.  A reader who sees `Filesystem…` on a 19-cell frame
-- knows which panel it is.  A reader who sees the same text on two panels does
-- not, and that is what this file is for.
--
-- The widths are the product's, and that is the whole design.  Three earlier
-- versions of the measurement each reported a result, and each was wrong:
--
--   * Sweeping whole pages at nine terminal sizes found no truncation and no
--     collision -- because the narrowest panel is 19 cells and the longest title
--     is 27, so the budget `area.width - 6` is *usually* not binding and the rule
--     was being asked about a range it never sees.  "No collision" was a
--     statement about titles that cannot collide.
--   * Sweeping frame widths from 6 upward found 3 338 collisions -- every one of
--     them `CPU` against `GPU` cut to a single `U` -- in frames of 6 to 29 cells
--     that the layout solver never produces.  So the fix was to ask the product
--     which widths it produces, and the answer is 21 of them from 19 to 240, all
--     of which this file sweeps.
--   * Rendering synthetic panels without `border = true` takes the *borderless*
--     branch, which truncates to a different width at a different offset, and it
--     reported every single render as truncated.  True of that branch, silent
--     about the one the product uses: all 58 titles in the product are bordered.
--
-- And the clause that would have caught the first version is in here: the fixture
-- must contain a width at which a title is actually cut.  A rule applied only to
-- widths where nothing happens is a rule that cannot fail, and this project's
-- clearest instance of that cost two of the mutations in increments 88 and 91.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Collectors = require("wtop.collectors")
local Grid = require("wtop.ui.renderer.grid")
local I18n = require("wtop.i18n")
local Inspectors = require("wtop.inspectors")
local Panel = require("wtop.ui.widgets.panel")
local ProcessTable = require("wtop.model.process_table")
local Theme = require("wtop.ui.theme")
local ViewModel = require("wtop.view_model")
local Width = require("wtop.ui.renderer.width")
local Workspace = require("wtop.workspace")

local LOCALES = assert(I18n.available())
local failures = {}
local function require(condition, message)
  if not condition then failures[#failures + 1] = message end
end

local theme = Theme.new(Theme.DEFAULT, { unicode = true })
local capabilities = { unicode = true }
local GEOMETRIES = { { 40, 24 }, { 60, 30 }, { 80, 24 }, { 100, 30 }, { 120, 40 },
  { 160, 45 }, { 180, 24 }, { 200, 22 }, { 240, 50 } }

-- A snapshot with rows in it, because a panel with no rows is a different thing
-- from the panels the product draws and the widths it hands them depend on the
-- layout the content asks for.
local function capabilities_table()
  local ids = {}
  for id in pairs(Collectors.constructors) do ids[#ids + 1] = id end
  table.sort(ids)
  local states = { "available", "unavailable", "denied", "degraded", "error" }
  local result = { inspectors = {} }
  for index, id in ipairs(ids) do
    local state = states[(index % #states) + 1]
    result[id] = { state = state, available = state == "available" }
  end
  for index, id in ipairs(Inspectors.new_default().order) do
    local state = states[index]
    result.inspectors[id] = { state = state, available = state == "available" }
  end
  return result
end

local function populated_snapshot()
  local cores = {}
  for index = 0, 127 do
    cores[index + 1] = { name = "cpu" .. index, utilization = 0, user = 0, system = 0,
      iowait = 0, irq = 0, steal = 0, quality = "fresh" }
  end
  local interfaces = {}
  for index = 1, 4 do
    interfaces[index] = { name = "enp0s3" .. index .. "1f" .. index, mtu = 1500,
      operstate = "up", speed_mbps = 10000, duplex = "full",
      mac = "aa:bb:cc:dd:ee:ff", rx_bytes = 1, tx_bytes = 2, rx_packets = 1,
      tx_packets = 2, rx_errors = 0, tx_errors = 0, rx_dropped = 0, tx_dropped = 0,
      quality = "fresh" }
  end
  local processes = {}
  for index = 1, 7 do
    processes[index] = { pid = 1000 + index, starttime_ticks = index, name = "p" .. index,
      command = "p" .. index, user = "tester", state = "S", cpu_percent = index,
      resident_bytes = 1024 * index, memory_summary = { resident_bytes = 1024 * index } }
  end
  return {
    host = { hostname = "probe", kernel = "linux", uptime_seconds = 98765 },
    cpu = { usage_percent = 12, quality = "fresh", cores = cores },
    cpu_info = { logical_cores = 128, model = "probe cpu" },
    memory = { total_bytes = 16 * 1024 * 1024 * 1024, used_bytes = 8 * 1024 * 1024 * 1024,
      available_bytes = 8 * 1024 * 1024 * 1024, quality = "fresh" },
    pressure = { cpu = { some = { avg10 = 1.2 } }, memory = { some = { avg10 = 0.4 } },
      io = { some = { avg10 = 0.1 } }, quality = "fresh" },
    disks = { devices = { { id = "sda", model = "Samsung SSD 990 PRO 2TB",
      size = 2 * 1024 * 1024 * 1024, medium = "SSD", quality = "fresh",
      read_bytes_per_second = 1, write_bytes_per_second = 2, busy_percent = 3,
      queue_depth = 1, read_latency_ms = 1 } } },
    network = { interfaces = interfaces, addresses_status = "fresh" },
    processes = { list = processes, truncated = false, clock_ticks_per_second = 100,
      total = #processes, process_candidates = #processes },
    cpu_frequency = { policies = { { name = "policy0", governor = "schedutil",
      driver = "intel_pstate", quality = "fresh", min_hz = 800000000,
      max_hz = 1890000000, current_hz = 1890000000, available_governors = {} } },
      current_quality = "fresh", current_hz = 1890000000 },
    gpus = { devices = {}, process_scan = { status = "ok", quality = "partial" } },
    sensors = { devices = { { class = "hwmon0", name = "probe",
      channels = { { type = "temperature", input = 69.8, quality = "fresh" } } } } },
    power = { zones = { { name = "package-0", power_watts = 12.5, quality = "fresh" } } },
    quality = { mounts = { status = "ok", quality = "fresh" },
      disks = { status = "ok", quality = "fresh" } },
    connections = { owner_scan = { quality = "fresh" }, connections = {
      { id = "1", protocol = "tcp", state = "ESTABLISHED",
        local_endpoint = { text = "127.0.0.1:1" },
        remote_endpoint = { text = "198.51.100.1:443" }, owners = {} } } },
    mounts = { mounts = { { id = "/", target = "/", fstype = "ext4",
      source = "/dev/sda1", total_bytes = 1024, used_bytes = 512, quality = "fresh" } } },
    workloads = { workloads = { { id = "c1", name = "workload-1", cgroup_path = "/probe/1",
      state = "running", cpu_percent = 5, memory_bytes = 65536, quality = "fresh" } },
      summary = {} },
    inventory = { pci = { devices = {
      { address = "0000:00:1f.6", vendor_id = 0x8086, vendor_name = "Intel Corporation",
        device_name = "Ethernet Connection I219-V", class_id = 0x0200 },
      { address = "0000:00:1f.7", vendor_id = 0x8086, vendor_name = "Intel Corporation",
        device_name = "Ethernet Connection I219-V", class_id = 0x0200 } }, total = 2 },
      usb = { devices = {}, total = 0 } },
  }
end

-- The widths and the titles, both read off the product's own renders.
local reachable, titles, panels_rendered = {}, {}, 0
local seen_title = {}
local real_render = Panel.render
Panel.render = function(grid, area, model, context, content_renderer)
  panels_rendered = panels_rendered + 1
  reachable[area.width] = true
  if model and type(model.title) == "string" and model.title ~= "" and not seen_title[model.title] then
    seen_title[model.title] = true
    titles[#titles + 1] = { title = model.title, border = model.border }
  end
  return real_render(grid, area, model, context, content_renderer)
end

local engine = { history_values = function() return { n = 0 } end }
local snapshot = populated_snapshot()
local capabilities_fixture = capabilities_table()
for _, locale in ipairs(LOCALES) do
  local translator = assert(I18n.new({ locale = locale }))
  for _, geometry in ipairs(GEOMETRIES) do
    for _, tab in ipairs(Workspace.new().tabs) do
      local models = assert(ViewModel.build(engine, snapshot, translator,
        capabilities_fixture, tab.id,
        ProcessTable.new({ sort_key = "cpu", descending = true })))
      local workspace = Workspace.new()
      workspace:select(tab.id)
      local ok, problem = pcall(workspace.render, workspace, geometry[1], geometry[2], {
        capabilities = capabilities, i18n = translator, widgets = models, status = {},
        frequency_label = translator:t("sampling.update_frequency",
          { level = translator:t("sampling.frequency.medium") }) })
      assert(ok, "the " .. tab.id .. " page at " .. geometry[1] .. " columns must render: "
        .. tostring(problem))
    end
  end
end
Panel.render = real_render

local WIDTHS = {}
for width in pairs(reachable) do WIDTHS[#WIDTHS + 1] = width end
table.sort(WIDTHS)

-- Read the title back off the frame.  The panel writes `" " .. title .. " "` at
-- `area.x + 2` on the top border row, so the run from there to the next piece of
-- the frame's own horizontal is exactly what was drawn, and stopping at the
-- horizontal is what keeps the rest of the border out of it.
local function read_frame_title(grid, area)
  local cells = {}
  for x = area.x + 2, grid.width do
    local cell = grid:get(x, area.y)
    cells[#cells + 1] = cell.continuation and "" or cell.char
  end
  local text = table.concat(cells)
  local stop = text:find("\u{2500}")
  if stop then text = text:sub(1, stop - 1) end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The reader's own teeth, on a frame wide enough that nothing is cut.
local wide = Grid.new(120, 3, {
  default_style = theme:style("text.primary", "surface.base"), unicode = true,
})
Panel.render(wide, { x = 1, y = 1, width = 120, height = 3 },
  { title = "Network throughput", border = true, kind = "metric" },
  { theme = theme, i18n = assert(I18n.new({ locale = "en-US" })),
    capabilities = capabilities })
require(read_frame_title(wide, { x = 1, y = 1 }) == "Network throughput",
  "the reader cannot read back a title it is given whole, so every result below is "
  .. "about the reader")
local bare = Grid.new(120, 3, {
  default_style = theme:style("text.primary", "surface.base"), unicode = true,
})
Panel.render(bare, { x = 1, y = 1, width = 120, height = 3 },
  { title = "", border = true, kind = "metric" },
  { theme = theme, i18n = assert(I18n.new({ locale = "en-US" })),
    capabilities = capabilities })
require(read_frame_title(bare, { x = 1, y = 1 }) == "",
  "the reader reports a title on a frame that has none, so an untitled panel would "
  .. "look titled and the empty-title rule could never fire")

local sweep_context = { theme = theme, i18n = assert(I18n.new({ locale = "en-US" })),
  capabilities = capabilities }
local checked, truncated, blank = 0, 0, {}
local collisions, at_width = {}, {}
for _, entry in ipairs(titles) do
  for _, width in ipairs(WIDTHS) do
    local grid = Grid.new(width, 3, {
      default_style = theme:style("text.primary", "surface.base"), unicode = true,
    })
    Panel.render(grid, { x = 1, y = 1, width = width, height = 3 },
      { title = entry.title, border = entry.border ~= false, kind = "metric" },
      sweep_context)
    local text = read_frame_title(grid, { x = 1, y = 1 })
    checked = checked + 1
    if text == "" then
      blank[#blank + 1] = ("a frame of %d cells draws %q as nothing at all")
        :format(width, entry.title)
    else
      if text ~= entry.title then truncated = truncated + 1 end
      local key = width .. "|" .. text
      if at_width[key] and at_width[key] ~= entry.title then
        collisions[#collisions + 1] = ("a frame of %d cells draws %q and %q both as %q")
          :format(width, at_width[key], entry.title, text)
      else
        at_width[key] = entry.title
      end
    end
  end
end

require(#collisions == 0,
  "two panel titles drawn the same, which is a panel you cannot name:\n    "
  .. table.concat(collisions, "\n    "))
require(#blank == 0,
  "a titled panel that draws no title at all:\n    " .. table.concat(blank, "\n    "))

-- Non-vacuity, in the order that matters.  The truncation clause comes first
-- because it is the one that the first version of this measurement failed: with
-- only wide frames in the sweep, "no two titles collide" is a statement about
-- titles too long to be cut, and the rule would be untested.
require(truncated > 0,
  "not one of the " .. checked .. " title renders was cut, so the frames this "
  .. "sweep uses are all wider than the longest title and the rule was applied "
  .. "only where nothing can happen")
require(checked == #titles * #WIDTHS,
  "the sweep should have produced " .. (#titles * #WIDTHS) .. " title renders and "
  .. "produced " .. checked)
require(#titles > 1,
  "only " .. #titles .. " distinct title(s) were collected, so there is nothing for "
  .. "the collision rule to compare")
require(#WIDTHS > 1 and WIDTHS[1] < 32,
  "every frame the product produced is at least 32 cells wide, so the narrow "
  .. "frames where a title can actually be cut are missing from the sweep")
require(panels_rendered > 0, "no panel was rendered, so the widths came from nowhere")
-- `#` on a table counts a sequence, and `seen_title` is keyed by strings, so the
-- count has to be made by walking it.  Getting that wrong makes the clause
-- compare a number against a number and agree with itself.
local distinct_titles = 0
for _ in pairs(seen_title) do distinct_titles = distinct_titles + 1 end
require(distinct_titles == #titles,
  "the title list holds " .. #titles .. " entries and the seen set holds "
  .. distinct_titles .. " keys, so one of them is not what the other is")

assert(#failures == 0,
  table.concat(failures, "\n  ") .. "\n  (" .. #failures
  .. " problem(s); they are reported together so a run that finds a defect "
  .. "explains all of it)")

local widest = 0
for _, entry in ipairs(titles) do
  widest = math.max(widest, Width.display_width(entry.title, { unicode = true }))
end
io.write(string.format(
  "ok: panel titles (%d distinct titles over %d distinct frame widths the product "
  .. "produces (%d..%d), %d title renders, %d of them cut and every cut still "
  .. "naming its panel, no two titles drawn alike, none drawn empty; the longest "
  .. "title is %d cells)\n",
  #titles, #WIDTHS, WIDTHS[1], WIDTHS[#WIDTHS], checked, truncated, widest))
