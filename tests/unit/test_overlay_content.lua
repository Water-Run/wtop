-- The overlay is a rendering surface, and until this file it was one with no rule
-- on it.
--
-- Every rendering invariant in this project is driven through `workspace:render`,
-- which draws *pages*.  When an overlay is open the page behind it is not what the
-- user reads, and the overlay is drawn by a different function -- `draw_overlay`,
-- in `tui.lua`, with fourteen line builders feeding it.  `draw_overlay` and
-- thirteen of those builders are exported and have been for a long time, so the
-- surface was reachable; increment 93 recorded the boundary in so many words
-- ("the third rule governs page rendering only; the `status.message` tui.lua
-- assembles outside a page, the pickers and the overlays are not in the drive")
-- and nothing since has closed it.
--
-- Two rules, and they are two because the product itself draws the difference.
-- `draw_overlay` writes a scroll indicator `n/m` into its bottom border, and only
-- when there is more content below, so a render says which of the two questions
-- applies to it:
--
--   R1, a line that is not scrollable is drawn whole.  `wrap_line` breaks at
--      spaces and, failing that, splits an unbroken token across rows with an
--      *empty* ellipsis, so nothing on the face of it can report a loss -- the
--      only way to know is to read the rows back.
--   R2, a line that is scrollable is reachable at some offset.  An overlay that
--      draws its first page and stops is indistinguishable from one that has
--      nothing more, which is the same argument the table's row-count note makes.
--
-- Both rules were measured before they were written down, over the widest line of
-- every builder in every catalogue at every width from 20 to 240, and both came
-- back clean: 6 557 renders with no content lost and 9 167 offset walks with no
-- line out of reach.  **Six versions of the measurement were wrong before the
-- sixth was right, and every one of them reported content as lost, which is worth
-- more than the clean result.**  In order: a containment test over raw rows fails
-- because each wrapped segment is bordered (`|Client ...|` and `|trainer|` are
-- not `Clienttrainer`); a guessed grid height reads a row that is merely below the
-- fold as a row that was never drawn; stripping the box drawing is not enough
-- because the bottom border also carries `7/22`, and those digits are
-- content-shaped, so they were injected between a line's own segments; a border
-- row identified by its corners passes on the top border and fails on the bottom
-- one, because the two corners are *different* glyphs and it is the bottom one
-- that carries the indicator; and a union of *distinct* row texts collapses the
-- eighteen identical rows an 180-character command with no spaces in it wraps
-- into, which is the very case the rule exists to judge.  The sixth recovers the
-- content positionally -- the body row `i` drawn at offset `k` is content row
-- `1 + k + i` -- which is also the only version that can be right.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grid = require("wtop.ui.renderer.grid")
local I18n = require("wtop.i18n")
local Inspectors = require("wtop.inspectors")
local ProcessColumns = require("wtop.model.process_columns")
local Workspace = require("wtop.workspace")
local Theme = require("wtop.ui.theme")
local TUI = require("wtop.tui")
local JournalStats = require("wtop.inspectors.journal_stats")
local Width = require("wtop.ui.renderer.width")

local LOCALES = assert(I18n.available())
local failures = {}
local function require(condition, message)
  if not condition then failures[#failures + 1] = message end
end

-- ---------------------------------------------------------------------------
-- The builders, and the clause that says this list is the product's.
--
-- A hand-written list of overlay builders is a list of things somebody thought
-- of, and the list version has no way to notice a fourteenth one.  So the list is
-- read out of `tui.lua` the same way the width guards read their pages out of
-- `Workspace`, and the clause below fails when the two disagree -- in either
-- direction, because a builder exported and then removed would otherwise stay
-- here forever as a fixture for a function that no longer exists.
--
-- `help_lines` is the one builder in `tui.lua` that is *not* exported, so it is
-- not in this list and not covered here.  That is a real gap and it is stated
-- rather than hidden: the help overlay is the one a reader is most likely to open,
-- it is the only overlay with no test other than the PTY scenarios that press `?`,
-- and exporting it is a one-line change that nothing has asked for yet.
-- ---------------------------------------------------------------------------
local source = (function()
  local handle = assert(io.open("src/wtop/tui.lua", "r"))
  local text = handle:read("a")
  handle:close()
  return text
end)()
local EXPORTED = {}
for name in source:gmatch("\nM%.([%w_]+_lines)%s*=%s*[%w_]+") do
  EXPORTED[#EXPORTED + 1] = name
end
table.sort(EXPORTED)
local HELP_LOCAL = source:match("\nlocal function help_lines%(") ~= nil
  and source:match("\nM%.help_lines%s*=") == nil

-- ---------------------------------------------------------------------------
-- Fixtures, in the shapes `render_frame` passes each builder.
--
-- Read out of the builders' own bodies rather than guessed: a probe that feeds a
-- builder an argument the product never passes it manufactures a defect out of its
-- own fixture, which this project has now paid for four times over.
-- ---------------------------------------------------------------------------
local LONG = string.rep("x", 180)
local process = {
  id = "4194304:1", pid = 4194304, starttime_ticks = 1, parent_pid = 1,
  name = "worker", command = LONG, user = "tester", state = "S",
  cpu_percent = 12.5, resident_bytes = 8 * 1024 * 1024 * 1024,
  virtual_bytes = 16 * 1024 * 1024 * 1024, threads = 7,
  io = { read_bytes = 1, write_bytes = 2, read_status = "partial",
         read_reason = "systemd_unavailable_process_fallback" },
  memory_summary = { resident_bytes = 1024 },
  io_status = "parse_error", io_reason = "systemd_unavailable_process_fallback",
  memory_status = "partial", memory_reason = "process_memory_partial",
}
local threads = {}
for index = 1, 12 do
  threads[index] = { tid = index, name = "thread-" .. index, cpu_percent = index,
    cpu_ticks = index, state = "S", priority = 20, nice = 0 }
end
local thread_detail = { source = "proc", state_text = "S (sleeping)", tgid = 4194304,
  uid = 1000, cgroups = "/system.slice", io = { read_bytes = 1 },
  voluntary_switches = 10, involuntary_switches = 2, scheduler = "schedutil",
  priority = 20 }
local gpu_device = { card = "card0", model_name = "NVIDIA GeForce RTX 4090",
  driver = "nvidia", vendor_name = "NVIDIA", pci_bdf = "0000:01:00.0",
  pci = { address = "0000:01:00.0", current_link_speed = "16 GT/s", current_link_width = 16 },
  metrics = { utilization_percent = 0, memory_used_bytes = 0,
    memory_total_bytes = 25757220864, frequency_current_hz = 2100000000 },
  frequencies = { domains = {
    { id = "graphics", name = "graphics", current_hz = 2100000000, actual_hz = 2100000000,
      minimum_hz = 2100000000, maximum_hz = 2100000000, quality = "fresh",
      source_kind = "requested", states = { active = true } },
    { id = "memory", name = "memory", current_hz = 10500000000, actual_hz = 10500000000,
      minimum_hz = 405000000, maximum_hz = 10500000000, quality = "estimated",
      source_kind = "requested", states = { active = true } } } } }
local inspector_result = { status = "partial", reason = "gpu_identity_inferred",
  source = "/sys/bus/pci/devices/" .. string.rep("0", 30), issues = { "one", "two" },
  items = { { name = "engine0", value = 42 } },
  sections = { { id = "configuration", fields = { effective = { quality = "estimated",
    reason = "sshd_configuration_current_files", value = { port = { "22", "2222" },
      listenaddress = { "0.0.0.0:22", "[::]:2222" }, authenticationmethods = LONG } } } } },
  details = { configuration = { data = { scope = "global", file = "/etc/ssh/" .. LONG } } } }
local snapshot = { sensors = { devices = { { class = "hwmon0", name = "probe",
  channels = { { id = "temperature:1", type = "temperature", unit = "celsius",
    label = "Critical probe", input = 69.8, quality = "fresh",
    thresholds = { max = 80, crit = 85.8 } } } } } } }
local entity = { id = "enp0s31f1", name = "enp0s31f1", model = "I219-V",
  vendor = "Intel", path = "/sys/class/net/enp0s31f1", rotational = false }
local widget_items = { { kind = "metric", title = "CPU usage" },
  { kind = "table", title = "Process table" } }

local function build(i18n, name)
  if name == "inspector_lines" then
    return TUI.inspector_lines("SMART / NVMe health", inspector_result, i18n)
  elseif name == "systemd_unit_lines" then
    return TUI.systemd_unit_lines({ status = "ok", quality = "partial",
      reason = "systemd_data_incomplete", source = "/usr/bin/systemctl", timestamp_ns = 0,
      entity = { summary = {
        unit = { value = "worker.service", quality = "fresh" },
        manager = { value = "user", quality = "fresh" },
        description = { value = LONG, quality = "fresh" },
        memory_max = { value = "unlimited", quality = "fresh" },
        cpu_time = { value = 2500000000, unit = "nanoseconds", quality = "fresh" },
      } } }, i18n, 1000000000)
  elseif name == "journal_lines" then
    return TUI.journal_lines({ unit = "worker.service", index = 1, detail = true,
      result = { status = "ok", quality = "partial", reason = "journal_data_partial", timestamp_ns = 0,
        source = "/usr/bin/journalctl", data = { unit = "worker.service", manager = "system", max_entries = 100,
          entries = { { id = "cursor", timestamp_us = 1700000000123456, priority = 4, pid = 4194304,
            uid = 1000, identifier = "worker", unit = "worker.service", quality = "partial",
            relation = "referenced", message = LONG .. "\n" .. LONG, message_truncated = true } } } } },
      i18n, true, 1000000000)
  elseif name == "session_lines" then
    return TUI.session_lines({ entity = { session_id = "c42" }, result = { status = "ok",
      quality = "partial", reason = "logind_data_partial", timestamp_ns = 0, source = "/usr/bin/loginctl",
      entity = { summary = { session_id = { value = "c42" }, user = { value = LONG },
        service = { value = LONG }, uid = { value = 1000 }, remote = { value = false },
        scope = { value = "session-c42.scope" }, idle_hint = { value = true } } } } }, i18n, 1000000000)
  elseif name == "event_stats_lines" then
    return TUI.event_stats_lines(JournalStats.summarize({ status = "ok", quality = "partial",
      reason = "journal_data_truncated", timestamp_ns = 0, source = "/usr/bin/journalctl", data = {
        unit = "sshd.service", max_entries = 100, truncated = true, rejected = 1,
        entries = { { message = "Failed password for u from 192.0.2.1 port 22 ssh2", priority = 3,
          timestamp_us = 1700000000123456, identifier = "sshd", relation = "emitted" } } } }, true),
      i18n, 1000000000, "sshd.service", "service")
  elseif name == "sensor_detail_lines" then
    return TUI.sensor_detail_lines(snapshot, i18n, 1000000000)
  elseif name == "power_detail_lines" then
    return TUI.power_detail_lines({ cpu_limits = { domains = {
      { id = "package:0", scope = "cpu_package", active = true, quality = "fresh",
        source = LONG, reasons = { { id = "pl1", active = true, logged = true },
          { id = "thermal", active = false, logged = true } } },
    } }, power = { zones = {
      { id = "intel-rapl:0", name = "package-0", source_kind = "intel-rapl",
        enabled = true, controls_enabled = true, power_watts = 30,
        power_interval_ns = 1000000000, power_quality = "measured",
        constraints = {
          { id = 0, name = "long_term", power_limit_watts = 20, time_window_seconds = 28 },
          { id = 1, name = "short_term", power_limit_watts = 26, time_window_seconds = 0.00244 },
          { id = 2, name = "peak_power", power_limit_watts = 114 },
        } },
      { id = LONG, name = LONG, source_kind = LONG, power_quality = "denied" },
    }, denied_zones = 1 }, gpus = { devices = { gpu_device } } }, i18n)
  elseif name == "hardware_detail_lines" then
    return TUI.hardware_detail_lines({ inventory = { pci = { devices = {
      { address = "0000:01:00.0", vendor_name = LONG, device_name = LONG,
        driver = LONG, source = LONG, numa_node = 0, link_speed_gtps = 16,
        link_width = 8, max_link_speed_gtps = 32, max_link_width = 16 },
    } } } }, "pci:0000:01:00.0", i18n, 1000000000)
  elseif name == "route_detail_lines" then
    return TUI.route_detail_lines({ network = { routes = {
      total = 2, ipv4_status = "ok", ipv6_status = "ok", entries = {
        { family = "ipv4", destination_cidr = "0.0.0.0/0", default = true,
          gateway = "10.0.0.1", interface = "eth0", metric = 100, flags = 3 },
        { family = "ipv6", destination_cidr = "2001:db8:abcd:ef01::/64",
          source_cidr = "2001:db8:1234:5678::/64", gateway = "fe80::1",
          interface = "enp0s31f6", metric = 1024, flags = 1 },
      },
    } } }, i18n)
  elseif name == "process_detail_lines" then
    return TUI.process_detail_lines(process, i18n)
  elseif name == "process_fd_lines" then
    return TUI.process_fd_lines({ pid = process.pid, status = "ok",
      entries = { { fd = 0, target = LONG }, { fd = 10, target = "socket:[1234]" } },
      truncated = true }, i18n)
  elseif name == "process_fd_detail_lines" then
    return TUI.process_fd_detail_lines({ pid = process.pid, fd = 10,
      status = "ok", target = LONG, position = "1000", flags = "01002002",
      mount_id = "21", inode = "63107" }, i18n)
  elseif name == "process_column_lines" then
    return TUI.process_column_lines(
      { index = 2, entries = ProcessColumns.entries({}) }, i18n, true)
  elseif name == "signal_menu_lines" then
    return TUI.signal_menu_lines(process, 1, i18n, true)
  elseif name == "tab_manager_lines" then
    return TUI.tab_manager_lines({ index = 3,
      entries = Workspace.new({ tab_order = { "overview", "processes" } }):tab_entries() },
      i18n, true)
  elseif name == "thread_picker_lines" then
    return TUI.thread_picker_lines(process, 1, i18n, true)
  elseif name == "thread_detail_lines" then
    return TUI.thread_detail_lines(threads[1], thread_detail, process, i18n)
  elseif name == "gpu_client_lines" then
    return TUI.gpu_client_lines({ process = process, index = 1 }, i18n, true)
  elseif name == "gpu_client_detail_lines" then
    return TUI.gpu_client_detail_lines(
      { card = "card0", model_name = "NVIDIA GeForce RTX 4090", pid = 4194304,
        name = "trainer", utilization = 91, memory = 1024 }, i18n)
  elseif name == "gpu_device_clock_lines" then
    return TUI.gpu_device_clock_lines(
      { devices = { gpu_device }, index = 1, device = gpu_device }, i18n, true)
  elseif name == "gpu_device_clock_detail_lines" then
    return TUI.gpu_device_clock_detail_lines(gpu_device, i18n)
  elseif name == "workspace_lines" then
    return TUI.workspace_lines({ index = 1, active = 1, names = { "default", "io" },
      truncated = false }, i18n, true)
  elseif name == "move_target_lines" then
    return TUI.move_target_lines({ index = 1, position = 1, truncated = false,
      title = { key = "layout.move_title", fallback = "Move to" },
      targets = { { id = "a", title = "left" }, { id = "b", title = "right" } } },
      i18n, true)
  elseif name == "widget_picker_lines" then
    return TUI.widget_picker_lines("replace", widget_items, 1, i18n, true)
  elseif name == "entity_picker_lines" then
    return TUI.entity_picker_lines({ key = "actions.select", fallback = "Select" },
      { entity, { id = "enp0s31f2", name = "enp0s31f2" } }, 1, false, true)
  end
  return nil
end

-- The list of builders this file has a fixture for, and the clause that holds the
-- two lists to be the same set.
local FIXTURED = {
  "hardware_detail_lines",
  "entity_picker_lines", "gpu_client_detail_lines", "gpu_client_lines",
  "gpu_device_clock_detail_lines", "gpu_device_clock_lines", "inspector_lines",
  "move_target_lines", "process_column_lines", "process_detail_lines",
  "process_fd_detail_lines", "process_fd_lines",
  "route_detail_lines",
  "sensor_detail_lines", "signal_menu_lines", "tab_manager_lines",
  "systemd_unit_lines",
  "journal_lines",
  "session_lines",
  "event_stats_lines",
  "thread_detail_lines", "thread_picker_lines",
  "widget_picker_lines", "workspace_lines", "power_detail_lines",
}
table.sort(FIXTURED)
local only_exported, only_fixtured = {}, {}
for _, name in ipairs(EXPORTED) do
  if not table.concat(FIXTURED, " "):find(name, 1, true) then
    only_exported[#only_exported + 1] = name
  end
end
for _, name in ipairs(FIXTURED) do
  if not table.concat(EXPORTED, " "):find(name, 1, true) then
    only_fixtured[#only_fixtured + 1] = name
  end
end
require(#EXPORTED > 0, "no overlay line builder is exported from tui.lua, so the "
  .. "list this file reads its subject from is empty and both rules below are "
  .. "applied to nothing")
require(#only_exported == 0,
  "tui.lua exports overlay line builders this file has no fixture for: "
  .. table.concat(only_exported, ", ")
  .. "; an overlay nobody rendered is an overlay nobody checked")
require(#only_fixtured == 0,
  "this file has fixtures for builders tui.lua no longer exports: "
  .. table.concat(only_fixtured, ", "))
require(HELP_LOCAL, "help_lines is exported now, so the note in this file's header "
  .. "about the one overlay that is not reachable from a test is out of date")

-- ---------------------------------------------------------------------------
-- Reading the screen back.
-- ---------------------------------------------------------------------------
local theme = Theme.new(Theme.DEFAULT, { unicode = true })
local capabilities = { unicode = true }
local CHROME = "[\u{256D}\u{256E}\u{2570}\u{256F}\u{2500}\u{2502}\u{2588}+]"

local function strip(text)
  local without = tostring(text or ""):gsub(CHROME, "")
  return (without:gsub("%s", ""))
end

-- A border row is one that contains a horizontal run, and the horizontal run is
-- the test rather than the corners: the two corners of a border row are *different*
-- glyphs, so a first-equals-last test passes on the top border and fails on the
-- bottom one -- and the bottom one is the row that carries the scroll indicator,
-- which is the row that must not be mistaken for content.  No overlay line
-- contains a box-drawing horizontal.
local function is_border_row(row)
  return row:find("\u{2500}", 1, true) ~= nil
    or (row:find("+", 1, true) ~= nil and row:find("%-%-+", 1) ~= nil)
end

-- Non-vacuity for the reader itself, because a screen reader that classified
-- every row as a border would return an empty overlay and both rules would pass.
require(not is_border_row("Process columns"),
  "a plain content row is being classified as a border row, so every overlay "
  .. "reads as empty and both rules below are satisfied by nothing")
require(is_border_row("\u{256D}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256E}"),
  "a top border row is not recognised as one")
require(is_border_row("\u{2570}\u{2500}\u{2500}7/22\u{2500}\u{256F}"),
  "a bottom border row carrying the scroll indicator is not recognised as one, "
  .. "which is the row whose digits would otherwise be read as content")

local function grid_rows(grid)
  local rows = {}
  for y = 1, grid.height do rows[y] = grid:row_text(y) or "" end
  return rows
end

local function border_span(rows)
  local top, bottom
  for y = 1, #rows do
    if is_border_row(rows[y]) then
      if top == nil then top = y end
      bottom = y
    end
  end
  return top, bottom
end

-- ---------------------------------------------------------------------------
-- R1 -- a line that is not scrollable is drawn whole.
--
-- The widest line of each builder in each catalogue is the subject, and not as a
-- sample: wrapping can only lose something when there is more of a line than
-- fits, so the widest line decides the answer and the narrow ones cannot lose what
-- they do not have.  The grid is tall enough for every wrapped row by
-- construction, and the scroll indicator is the product's own statement of the
-- case -- a render that carries one is R2's subject and is not counted as a loss.
-- ---------------------------------------------------------------------------
local function needed_height(line_cells, grid_width)
  -- The overlay never gets narrower than 28 cells and each continuation row
  -- spends two on the indent, so the interior available to text is bounded below
  -- by 24 - 2 even at the narrowest terminal.
  local interior = math.max(1, math.min(grid_width - 8, line_cells))
  return 1 + math.ceil(line_cells / math.max(1, interior - 2)) + 4
end

-- The lines a builder produces in a catalogue are the same for both rules, and
-- building them twice was costing a sixth of this file's time for nothing.
local LINE_CACHE = {}
local function lines_for(name, locale)
  local key = name .. "/" .. locale
  if LINE_CACHE[key] == nil then
    LINE_CACHE[key] = build(assert(I18n.new({ locale = locale })), name)
  end
  return LINE_CACHE[key]
end

local renders, scrollable_cases, lines_checked = 0, 0, 0
local lost = {}
for _, name in ipairs(FIXTURED) do
  for _, locale in ipairs(LOCALES) do
    local lines = lines_for(name, locale)
    require(type(lines) == "table" and #lines > 0,
      name .. " produced no lines in " .. locale .. ", so the rules below are "
      .. "applied to nothing for that builder")
    if type(lines) == "table" then
      local widest, widest_cells = nil, 0
      for _, line in ipairs(lines) do
        if type(line) == "string" then
          local cells = Width.display_width(line, { unicode = true })
          if cells > widest_cells then widest, widest_cells = line, cells end
        end
      end
      if widest and strip(widest) ~= "" then
        lines_checked = lines_checked + 1
        local needle = strip(widest)
        for width = 20, math.min(240, widest_cells + 10) do
          local grid = Grid.new(width, needed_height(widest_cells, width),
            { default_style = theme:style("text.primary", "surface.base") })
          TUI.draw_overlay(grid, theme, { widest }, 0, capabilities)
          renders = renders + 1
          local rows = grid_rows(grid)
          local top, bottom = border_span(rows)
          local indicator
          for _, row in ipairs(rows) do indicator = row:match("(%d+/%d+)") or indicator end
          if indicator then
            scrollable_cases = scrollable_cases + 1
          else
            local parts = {}
            for y = (top or 1) + 1, (bottom or #rows) - 1 do
              parts[#parts + 1] = strip(rows[y])
            end
            if not table.concat(parts):find(needle, 1, true) then
              lost[#lost + 1] = ("%s / %s: a %d-cell line is not all on screen at "
                .. "%d columns once every row is drawn: %q")
                :format(name, locale, widest_cells, width, widest)
            end
          end
        end
      end
    end
  end
end

-- R1's own teeth.  The rule above asks whether the drawn rows contain the line;
-- this asks whether a drawn set that does *not* contain it would be reported, and
-- it is the only way to tell a rule that cannot find anything from a rule over
-- content that cannot be lost.
local function contains(haystack, needle) return haystack:find(needle, 1, true) ~= nil end
local sample_needle = strip("Up/Down selects \u{00B7} Space shows/hides \u{00B7} "
  .. "Esc closes")
require(contains(sample_needle, sample_needle),
  "the containment test this file's first rule uses rejects the text it was given")
require(not contains(sample_needle:sub(1, #sample_needle - 6), sample_needle),
  "the containment test used by the first rule accepts a line that is missing its "
  .. "tail, so a truncated overlay would pass it")

require(lines_checked > 0,
  "no builder produced a line to check, so the first rule was applied to nothing")
require(renders > lines_checked,
  "only " .. renders .. " render(s) for " .. lines_checked .. " line(s); the "
  .. "width sweep is not running")
require(scrollable_cases > 0,
  "not one render came back scrollable, which means the first rule is only ever "
  .. "being asked the easy half of its question -- check the height it asks with")
require(#lost == 0, "an overlay line lost content:\n    " .. table.concat(lost, "\n    "))

-- ---------------------------------------------------------------------------
-- R2 -- a line that is scrollable is reachable at some offset.
--
-- The content is recovered *positionally*: the body row `i` drawn at offset `k` is
-- content row `1 + k + i`, so walking the offset fills an array of the whole
-- overlay in order.  A union of distinct row texts is the obvious thing to write
-- and it is wrong -- an 180-character command with no spaces in it wraps into
-- eighteen byte-for-byte identical rows, and a set says there is one of them.
-- ---------------------------------------------------------------------------
local WIDTHS = { 40, 60, 80, 120, 200 }
local draws, unreachable = 0, {}
for _, name in ipairs(FIXTURED) do
  for _, locale in ipairs(LOCALES) do
    local lines = lines_for(name, locale)
    if type(lines) == "table" and #lines > 0 then
      local widest = 0
      for _, line in ipairs(lines) do
        if type(line) == "string" then
          widest = math.max(widest, Width.display_width(line, { unicode = true }))
        end
      end
      for _, width in ipairs(WIDTHS) do
        -- Past the point where the widest line stops wrapping there is no tail to
        -- reach, and the rule has nothing to say about that width.
        if width - 8 < widest then
          local grid = Grid.new(width, 12,
            { default_style = theme:style("text.primary", "surface.base") })
          local content, previous, offset = {}, nil, 0
          while offset <= 400 do
            TUI.draw_overlay(grid, theme, lines, offset, capabilities)
            draws = draws + 1
            local rows = grid_rows(grid)
            local current = table.concat(rows, "\n")
            if current == previous then break end
            previous = current
            local top, bottom = border_span(rows)
            if top and bottom and bottom > top + 1 then
              for y = top + 1, bottom - 1 do
                local position = 1 + offset + (y - top)
                if content[position] == nil then content[position] = strip(rows[y]) end
              end
            end
            offset = offset + 1
          end
          local dense = {}
          for position = 1, 400 do
            if content[position] ~= nil then dense[#dense + 1] = content[position] end
          end
          local haystack = table.concat(dense)
          for index, line in ipairs(lines) do
            if type(line) == "string" then
              local needle = strip(line)
              if needle ~= "" and not contains(haystack, needle) then
                unreachable[#unreachable + 1] =
                  ("%s / %s at %d columns: line %d of %d (%d cells) is never "
                    .. "drawn at any offset")
                  :format(name, locale, width, index, #lines,
                    Width.display_width(line, { unicode = true }))
              end
            end
          end
        end
      end
    end
  end
end

require(draws > 0,
  "the offset walk never drew anything, so the second rule was applied to nothing")
require(#unreachable == 0,
  "overlay lines a reader cannot reach by scrolling:\n    "
  .. table.concat(unreachable, "\n    "))

assert(#failures == 0,
  table.concat(failures, "\n  ") .. "\n  (" .. #failures
  .. " problem(s); they are reported together so a run that finds a defect "
  .. "explains all of it)")

io.write(string.format(
  "ok: overlay content (%d exported builders, %d lines at their widest in %d "
  .. "catalogues, %d renders with no content lost, %d of them scrollable and so "
  .. "the second rule's subject, %d offset walks with every line reachable)\n",
  #EXPORTED, lines_checked, #LOCALES, renders, scrollable_cases, draws))
