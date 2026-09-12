local Actions = require("wtop.actions")
local Engine = require("wtop.engine")
local I18n = require("wtop.i18n")
local UserCatalogs = require("wtop.i18n.user_catalogs")
local Inspectors = require("wtop.inspectors")
local PerfBandwidth = require("wtop.inspectors.perf_bandwidth")
local LayoutStore = require("wtop.layout_store")
local Privilege = require("wtop.privilege")
local ProcessTable = require("wtop.model.process_table")
local Terminal = require("wtop.terminal")
local UI = require("wtop.ui")
local ViewModel = require("wtop.view_model")
local Workspace = require("wtop.workspace")
local UpdateFrequency = require("wtop.update_frequency")
local native = require("wtop.native")
local system = require("wtop.system")

local M = {}

local function merge(left, right)
    local result = {}
    for key, value in pairs(left or {}) do result[key] = value end
    for key, value in pairs(right or {}) do result[key] = value end
    return result
end

local function translated(i18n, id, fallback, variables)
    local value = i18n and i18n:t(id, variables)
    if value and value ~= id then return value end
    -- A missing key falls back to the English literal, which may itself carry
    -- {placeholders}.  Leaving them unsubstituted printed "{sort} {direction}"
    -- straight into panel titles, so the fallback gets the same interpolation
    -- the catalogue entry would have received.
    if variables and i18n and i18n.format and type(fallback) == "string"
        and fallback:find("{", 1, true) then
        local ok, interpolated = pcall(i18n.format.interpolate, i18n.format, fallback, variables)
        if ok and type(interpolated) == "string" then return interpolated end
    end
    return fallback
end

local function width_function(codepoint)
    local value = native.wcwidth(codepoint)
    if type(value) == "number" and value >= 0 then
        return value
    end
    return nil
end

-- Pad by measured display columns, never by bytes.  `string.format("%-18s")`
-- counts bytes, so a four-character Chinese label (twelve bytes, eight
-- columns) produced a different indent than an eight-column ASCII one and the
-- whole overlay lost its column.
local function pad_to(text, columns)
    text = tostring(text or "")
    local used = UI.Renderer.Width.display_width(text)
    if used >= columns then
        return UI.Renderer.Width.truncate(text, columns)
    end
    return text .. string.rep(" ", columns - used)
end

local function aligned_pairs(pairs_list, gap)
    local width = 0
    for _, item in ipairs(pairs_list) do
        if not item.section and not item.blank then
            width = math.max(width, UI.Renderer.Width.display_width(tostring(item[1] or "")))
        end
    end
    local lines = {}
    for _, item in ipairs(pairs_list) do
        if item.blank then
            lines[#lines + 1] = ""
        elseif item.section then
            lines[#lines + 1] = tostring(item.section)
        else
            lines[#lines + 1] = "  " .. pad_to(item[1], width) .. string.rep(" ", gap or 2)
                .. tostring(item[2] == nil and "—" or item[2])
        end
    end
    return lines
end

local function format_value(value, i18n)
    if type(value) == "table" then
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        return "[" .. count .. " items]"
    elseif value == nil then
        return "—"
    elseif type(value) == "boolean" then
        return value and translated(i18n, "ui.yes", "yes") or translated(i18n, "ui.no", "no")
    end
    return tostring(value)
end

local function inspector_lines(title, result, i18n)
    local lines = { title, "" }
    if not result then
        lines[#lines + 1] = translated(i18n, "inspector.no_result", "Inspector returned no result")
        return lines
    end
    lines[#lines + 1] = translated(i18n, "inspector.status", "Status") .. ": "
        .. tostring(result.status or "unknown")
    lines[#lines + 1] = translated(i18n, "inspector.quality", "Quality") .. ": "
        .. tostring(result.quality or "unknown")
    if result.provider then
        lines[#lines + 1] = translated(i18n, "inspector.provider", "Provider") .. ": "
            .. tostring(result.provider)
    end
    if result.reason then
        lines[#lines + 1] = translated(i18n, "inspector.reason", "Reason") .. ": "
            .. tostring(result.reason)
    end
    for _, section in ipairs(result.sections or {}) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = tostring(section.id or section.title_key
            or translated(i18n, "inspector.details", "Details"))
        local keys = {}
        for key in pairs(section.fields or {}) do keys[#keys + 1] = key end
        table.sort(keys)
        local rows = {}
        for _, key in ipairs(keys) do
            local field = section.fields[key]
            rows[#rows + 1] = { key, format_value(field and field.value, i18n)
                .. "  [" .. tostring(field and field.quality or "unknown") .. "]" }
        end
        for _, line in ipairs(aligned_pairs(rows)) do lines[#lines + 1] = line end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
end

local function detail_formatted(call, fallback)
    local ok, value = pcall(call)
    return ok and value or fallback or "—"
end

local function process_detail_lines(process, i18n)
    if not process then
        return {
            translated(i18n, "process.details_title", "Process details"), "",
            translated(i18n, "process.no_selection", "No process selected"),
        }
    end
    local format = i18n and i18n.format
    local function bytes(value)
        if type(value) ~= "number" then return "—" end
        return detail_formatted(function() return assert(format:bytes(value)) end)
    end
    local function percent(value)
        if type(value) ~= "number" then return "—" end
        return detail_formatted(function() return assert(format:percent(value, { precision = 1 })) end)
    end
    local function seconds(value)
        if type(value) ~= "number" then return "—" end
        return detail_formatted(function() return assert(format:duration(value)) end)
    end
    local io = type(process.io) == "table" and process.io or {}
    local switches = type(process.context_switches) == "table" and process.context_switches or {}
    local ticks = type(process.cpu_ticks) == "number" and process.cpu_ticks / 100 or nil

    local rows = {
        { section = translated(i18n, "process.details_identity", "Identity") },
        { "ID", process.id },
        { "PID", process.pid },
        { "PPID", process.parent_pid },
        { translated(i18n, "process.details_name", "Name"), process.name },
        { translated(i18n, "metrics.user", "User"), process.user or process.uid },
        { translated(i18n, "metrics.state", "State"), process.state },
        { translated(i18n, "process.details_started", "CPU time"), seconds(ticks) },
        { blank = true },
        { section = translated(i18n, "process.details_command", "Command") },
        { translated(i18n, "process.details_command", "Command"), process.command },
        { blank = true },
        { section = translated(i18n, "process.details_resources", "Resources") },
        { "CPU", percent(process.cpu_percent) },
        { translated(i18n, "metrics.memory", "Memory"), bytes(process.resident_bytes) },
        { translated(i18n, "process.details_virtual_memory", "Virtual memory"),
          bytes(process.virtual_bytes) },
        { translated(i18n, "process.details_threads", "Threads"), process.threads },
        { blank = true },
        { section = translated(i18n, "process.details_scheduling", "Scheduling") },
        { translated(i18n, "process.details_priority", "Priority"), process.priority },
        { "Nice", process.nice },
        { translated(i18n, "metrics.cpu", "Last CPU"), process.processor },
        { translated(i18n, "process.details_process_group", "Process group"), process.process_group },
        { translated(i18n, "process.details_session", "Session"), process.session },
        { blank = true },
        { section = translated(i18n, "process.details_io", "I/O counters") },
        { translated(i18n, "metrics.read", "Read"), bytes(io.read_bytes) },
        { translated(i18n, "metrics.write", "Write"), bytes(io.write_bytes) },
        { translated(i18n, "process.details_cancelled_write", "Cancelled write"),
          bytes(io.cancelled_write_bytes) },
        { translated(i18n, "process.details_voluntary_switches", "Voluntary switches"),
          switches.voluntary },
        { translated(i18n, "process.details_involuntary_switches", "Involuntary switches"),
          switches.involuntary },
    }
    for index, row in ipairs(rows) do
        if row[2] ~= nil and type(row[2]) ~= "string" then rows[index][2] = format_value(row[2], i18n) end
    end

    local lines = {
        translated(i18n, "process.details_title", "Process details") .. " · PID "
            .. tostring(process.pid or "—"),
        "",
    }
    for _, line in ipairs(aligned_pairs(rows)) do lines[#lines + 1] = line end

    if type(process.cgroups) == "table" and #process.cgroups > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "process.details_cgroups", "Control groups")
        for index, cgroup in ipairs(process.cgroups) do
            if index > 16 then
                lines[#lines + 1] = "  …"
                break
            end
            lines[#lines + 1] = "  " .. tostring(cgroup.path or "—")
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "process.details_actions",
        "k signal · Up/Down/PgUp/PgDn scroll · Esc/Enter closes")
    return lines
end

-- Help is structured data, laid out here.  It used to live as pre-padded
-- strings inside every locale file, which meant the two columns only lined up
-- in English, a new shortcut required editing ten translations, and the text
-- could not be reflowed for a narrow terminal.
local HELP_SECTIONS = {
    {
        id = "help.section_navigation", title = "Navigation",
        bindings = {
            { "1–9 0", "help.switch_tabs", "select a tab directly" },
            { "← →", "help.cycle_tabs", "previous / next tab" },
            { "Tab ⇧Tab", "help.focus_widget", "move focus between visible widgets" },
            { "?  F1", "help.toggle", "show or hide this help" },
            { "q", "help.quit", "close overlay, or quit from the main view" },
            { "Ctrl-C", "help.force_quit", "always quit" },
        },
    },
    {
        id = "help.section_sampling", title = "Sampling",
        bindings = {
            { "Space", "help.pause_resume", "pause or resume sampling" },
            { "f", "help.update_frequency", "cycle the update rate" },
            { "r  Ctrl-L", "help.refresh", "sample now and repaint" },
        },
    },
    {
        id = "help.section_processes", title = "Processes",
        bindings = {
            { "↑ ↓", "help.process_selection", "move the selection" },
            { "PgUp PgDn", "help.process_page", "move a page at a time" },
            { "Home End", "help.process_ends", "jump to first or last row" },
            { "/", "help.process_search", "search PID, name, command, user, state" },
            { "o", "help.process_sort", "cycle the sort column" },
            { "O", "help.process_direction", "reverse the sort direction" },
            { "t", "help.process_tree", "toggle the parent/child tree" },
            { "p", "help.process_paths", "toggle full executable paths" },
            { "Enter", "help.process_details", "open details for the selection" },
            { "k", "help.terminate_process", "send a signal to the selection" },
        },
    },
    {
        id = "help.section_search", title = "Search syntax",
        bindings = {
            { "root", "help.query_plain", "match any field" },
            { "user:root", "help.query_field", "restrict to pid, ppid, user, state, name or cmd" },
            { "!kernel", "help.query_negate", "exclude matches" },
            { "/^systemd/", "help.query_pattern", "a Lua pattern (not PCRE)" },
            { "a b", "help.query_and", "several terms must all match" },
            { "← → Home End", "help.query_cursor", "move the cursor within the query" },
            { "Ctrl-W Ctrl-U", "help.query_kill", "delete the previous word, or back to the start" },
        },
    },
    {
        id = "help.section_appearance", title = "Appearance",
        bindings = {
            { "e", "help.edit_layout", "enter layout edit mode" },
            { "T", "help.cycle_theme", "cycle the colour theme" },
            { "L", "help.cycle_language", "cycle the interface language" },
            { "v", "help.toggle_virtual", "show or hide virtual devices and pseudo mounts" },
        },
    },
    {
        id = "help.section_inspect", title = "Deep inspection",
        bindings = {
            { "s", "help.inspect_smart", "choose a SMART/NVMe device" },
            { "b", "help.inspect_bandwidth", "measure RAM bandwidth with perf" },
            { "d", "help.inspect_sshd", "inspect the sshd service and listeners" },
        },
    },
    {
        id = "help.section_mouse", title = "Mouse",
        bindings = {
            { "click", "help.mouse_click", "tabs, footer actions, table rows, column headers" },
            { "wheel", "help.mouse_wheel", "scroll tables and overlays" },
        },
    },
}

local function help_lines(i18n, width)
    local title = i18n:t("app.title")
    local lines = {
        title ~= "app.title" and title or "wtop — Linux performance workbench",
    }
    -- Two columns when the overlay is wide enough for them, one when it is not.
    local key_width = 0
    for _, group in ipairs(HELP_SECTIONS) do
        for _, binding in ipairs(group.bindings) do
            key_width = math.max(key_width, UI.Renderer.Width.display_width(binding[1]))
        end
    end
    for _, group in ipairs(HELP_SECTIONS) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, group.id, group.title)
        for _, binding in ipairs(group.bindings) do
            local description = translated(i18n, binding[2], binding[3])
            if width and width < key_width + 24 then
                lines[#lines + 1] = "  " .. binding[1]
                lines[#lines + 1] = "      " .. description
            else
                lines[#lines + 1] = "  " .. pad_to(binding[1], key_width) .. "  " .. description
            end
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "help.inspectors_safe",
        "External inspectors use absolute argv, a fixed locale, timeouts and output limits.")
    lines[#lines + 1] = translated(i18n, "help.smart_standby",
        "SMART probes do not wake standby drives.")
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "help.close", "Esc/Enter closes")
    return lines
end

-- Signals the action layer accepts.  The UI used to hard-wire SIGTERM even
-- though SIGKILL, SIGSTOP and SIGCONT were already implemented with the same
-- PID-reuse protection, so three safe actions were unreachable.
local SIGNAL_CHOICES = {
    { number = 15, name = "SIGTERM", id = "signal.term", fallback = "ask the process to exit" },
    { number = 9, name = "SIGKILL", id = "signal.kill", fallback = "force the kernel to kill it" },
    { number = 19, name = "SIGSTOP", id = "signal.stop", fallback = "suspend the process" },
    { number = 18, name = "SIGCONT", id = "signal.cont", fallback = "resume a stopped process" },
}

local function signal_menu_lines(process, selected, i18n, unicode)
    if unicode == nil then unicode = true end
    local lines = {
        translated(i18n, "signal.title", "Send a signal") .. " · PID "
            .. tostring(process and process.pid or "—")
            .. "  " .. tostring(process and (process.name or "") or ""),
        "",
        translated(i18n, "signal.hint", "Up/Down selects · Enter sends · Esc cancels"),
        "",
    }
    local rows = {}
    for index, choice in ipairs(SIGNAL_CHOICES) do
        rows[#rows + 1] = {
            (index == selected and (unicode and "▸ " or "> ") or "  ") .. choice.name,
            translated(i18n, choice.id, choice.fallback),
        }
    end
    for _, line in ipairs(aligned_pairs(rows, 3)) do lines[#lines + 1] = line end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "signal.warning",
        "The target is re-verified by start time, so a recycled PID is never signalled.")
    return lines
end

local function smart_selection_lines(devices, selected, i18n, truncated, unicode)
    if unicode == nil then unicode = true end
    local lines = {
        translated(i18n, "inspector.smart_devices", "SMART / NVMe devices"),
        "",
        translated(i18n, "inspector.smart_select_hint",
            "Up/Down selects · Enter inspects · Esc closes"),
        "",
    }
    for index, device in ipairs(devices or {}) do
        local identity = device.model or device.vendor
            or translated(i18n, "ui.unknown", "Unknown")
        local medium = device.rotational == 1 and "HDD"
            or (device.rotational == 0 and "SSD" or "?")
        lines[#lines + 1] = string.format("%s %-18s %-4s %s",
            index == selected and (unicode and "▸" or ">") or " ",
            tostring(device.path or device.name or device.id or "?"),
            medium, tostring(identity))
    end
    if truncated then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "inspector.device_list_truncated",
            "Device list truncated for safety")
    end
    return lines
end

-- Wrap one logical line to `width` columns, preserving its leading indent so
-- continuation rows stay visually attached to what they continue.
local MAX_WRAPPED_LINES = 256

local function wrap_line(line, limit)
    local width_of = UI.Renderer.Width.display_width
    if limit < 4 or width_of(line) <= limit then return { line } end
    -- Continuation rows keep the original indent plus two columns, so a wrapped
    -- value stays visually attached to the label that introduced it.
    local indent = line:match("^(%s*)") or ""
    local prefix = indent .. "  "
    if width_of(prefix) > limit - 4 then prefix = "" end

    local result = {}
    local remainder = line
    local current_prefix = ""
    while #result < MAX_WRAPPED_LINES do
        -- The prefix is part of the emitted row, so the text that fits is the
        -- limit minus the prefix.  `limit` itself never changes: shrinking it
        -- each pass made every continuation row narrower than the last.
        local usable = limit - width_of(current_prefix)
        if usable < 2 then break end
        if width_of(remainder) <= usable then
            result[#result + 1] = current_prefix .. remainder
            return result
        end
        local head = UI.Renderer.Width.truncate(remainder, usable, nil, "")
        -- Prefer breaking at the last space so words survive the wrap.
        local break_at = head:match("^.*()%s")
        if break_at and break_at > 4 then
            head = head:sub(1, break_at - 1)
        end
        if head == "" then break end
        result[#result + 1] = current_prefix .. head
        remainder = remainder:sub(#head + 1):gsub("^%s+", "")
        if remainder == "" then return result end
        current_prefix = prefix
    end
    if remainder ~= "" and #result < MAX_WRAPPED_LINES then
        result[#result + 1] = UI.Renderer.Width.truncate(current_prefix .. remainder, limit)
    end
    return result
end

local function overlay_geometry(grid, lines)
    local maximum_line = 0
    for _, line in ipairs(lines) do
        maximum_line = math.max(maximum_line,
            UI.Renderer.Width.display_width(line, grid.width_options))
    end
    local width = math.min(grid.width - 4, math.max(28, maximum_line + 4))
    local height = math.min(grid.height - 2, math.max(5, #lines + 2))
    return width, height, maximum_line
end

--- Reflow overlay content to the width the overlay will actually get.
local function overlay_content(grid, lines)
    local width = select(1, overlay_geometry(grid, lines))
    local inner = width - 4
    local wrapped = {}
    for _, line in ipairs(lines) do
        for _, part in ipairs(wrap_line(line, inner)) do
            wrapped[#wrapped + 1] = part
            if #wrapped > 4096 then return wrapped end
        end
    end
    return wrapped
end

local function draw_overlay(grid, theme, lines, offset, capabilities)
    offset = math.max(0, math.floor(tonumber(offset) or 0))
    lines = overlay_content(grid, lines)
    local width, height = overlay_geometry(grid, lines)
    if width < 4 or height < 3 then
        return
    end
    local x = math.floor((grid.width - width) / 2) + 1
    local y = math.floor((grid.height - height) / 2) + 1
    local area = { x = x, y = y, width = width, height = height }
    local background = theme:style("text.primary", "surface.raised")
    local border = theme:style("accent.primary", "surface.raised", { bold = true })
    local muted = theme:style("text.muted", "surface.raised")
    local unicode = not (capabilities and capabilities.unicode == false)

    -- Dim the page behind the overlay.  Without this the underlying panel
    -- borders run straight into the overlay frame and the two read as one
    -- broken box.
    local scrim = theme:style("text.muted", "surface.base", { dim = true })
    for row = 1, grid.height do
        for column = 1, grid.width do
            local inside = row >= y - 1 and row <= y + height
                and column >= x - 1 and column <= x + width
            if not inside then
                local cell = grid:get(column, row)
                if cell and not cell.continuation then
                    grid:set(column, row, cell.char, scrim, cell.width or 1)
                end
            end
        end
    end

    local glyph = unicode
        and { "╭", "╮", "╰", "╯", "─", "│" }
        or { "+", "+", "+", "+", "-", "|" }
    grid:fill(area, " ", background)
    grid:set(x, y, glyph[1], border, 1)
    grid:set(x + width - 1, y, glyph[2], border, 1)
    grid:set(x, y + height - 1, glyph[3], border, 1)
    grid:set(x + width - 1, y + height - 1, glyph[4], border, 1)
    for column = x + 1, x + width - 2 do
        grid:set(column, y, glyph[5], border, 1)
        grid:set(column, y + height - 1, glyph[5], border, 1)
    end
    for row = y + 1, y + height - 2 do
        grid:set(x, row, glyph[6], border, 1)
        grid:set(x + width - 1, row, glyph[6], border, 1)
    end
    if #lines > 0 then
        grid:write(x + 2, y + 1, lines[1], border, width - 4)
    end
    local body_rows = math.max(0, height - 3)
    for index = 1, body_rows do
        local line = lines[index + 1 + offset]
        if line == nil then break end
        grid:write(x + 2, y + 1 + index, line, background, width - 4)
    end

    -- A scroll indicator: without one, a truncated overlay looks complete and
    -- the reader never discovers the rest of the content.
    local scrollable = #lines - 1
    if scrollable > body_rows and body_rows > 0 then
        local track_top = y + 2
        local track_height = math.max(1, height - 4)
        local maximum_offset = math.max(1, scrollable - body_rows)
        local thumb_height = math.max(1,
            math.floor(track_height * body_rows / scrollable + 0.5))
        thumb_height = math.min(thumb_height, track_height)
        local position = math.floor((track_height - thumb_height)
            * math.min(1, offset / maximum_offset) + 0.5)
        for index = 0, track_height - 1 do
            local inside = index >= position and index < position + thumb_height
            grid:set(x + width - 1, track_top + index,
                unicode and (inside and "█" or "│") or (inside and "#" or "|"),
                inside and border or muted, 1)
        end
        local label = string.format("%d/%d", math.min(scrollable, offset + body_rows), scrollable)
        local label_width = UI.Renderer.Width.display_width(label, grid.width_options)
        if width > label_width + 6 then
            grid:write(x + width - label_width - 2, y + height - 1, label, muted, label_width)
        end
    end
end

-- Wrapping changes the line count, so the scroll bound has to be computed from
-- the reflowed content rather than from the source lines.
local function overlay_max_offset(terminal_rows, terminal_columns, lines)
    local pseudo_grid = { width = terminal_columns, height = terminal_rows }
    local wrapped = overlay_content(pseudo_grid, lines)
    local height = math.min(terminal_rows - 2, math.max(5, #wrapped + 2))
    local body_rows = math.max(1, height - 3)
    return math.max(0, (#wrapped - 1) - body_rows)
end

local function utf8_backspace(value)
    if type(value) ~= "string" or value == "" then return "" end
    local index = utf8.offset(value, -1)
    return index and value:sub(1, index - 1) or ""
end

-- Byte offset of the codepoint boundary before/after `position`.  Positions are
-- 1-based byte offsets of the character the cursor sits *on*, so a cursor at
-- #value + 1 means "at the end".
local function utf8_previous_offset(value, position)
    if position <= 1 then return 1 end
    local index = position - 1
    while index > 1 and value:byte(index) >= 0x80 and value:byte(index) < 0xC0 do
        index = index - 1
    end
    return index
end

local function utf8_next_offset(value, position)
    local limit = #value + 1
    if position >= limit then return limit end
    local index = position + 1
    while index < limit and value:byte(index) >= 0x80 and value:byte(index) < 0xC0 do
        index = index + 1
    end
    return index
end

local function make_inspectors(engine)
    local smartctl = system.find_executable("smartctl") or "/usr/sbin/smartctl"
    local systemctl = system.find_executable("systemctl") or "/usr/bin/systemctl"
    local perf_reader = PerfBandwidth.new({
        runner = engine.context.runner,
        clock = engine.clock,
        executable = system.find_executable("perf") or "/usr/bin/perf",
        sleep_executable = system.find_executable("sleep") or "/usr/bin/sleep",
    })
    return Inspectors.new_default({
        smart = { runner = engine.context.runner, clock = engine.clock, executable = smartctl },
        ram_bandwidth = {
            clock = engine.clock,
            perf_reader = function(request) return perf_reader:read(request) end,
        },
        sshd = { runner = engine.context.runner, clock = engine.clock, systemctl = systemctl },
    })
end

local function inspector_context(engine)
    return merge(engine.context, {
        snapshot = engine.snapshot,
        processes = engine.snapshot.processes,
        mask_remote_addresses = true,
    })
end

local function run_loop(options, backend, renderer, engine, translator)
    local terminal_capabilities = backend.capabilities()
    local default_orders = Workspace.default_orders()
    local layout_orders, layout_status, layout_trees
    if Privilege.restricts_user_files(options.privilege) then
        layout_orders = default_orders
        layout_status = { state = "default", reason = "sudo session ignores persisted layout" }
    else
        layout_orders, layout_status, layout_trees = LayoutStore.load(default_orders)
    end
    local workspace = Workspace.new({
        active_tab = options.active_tab,
        orders = layout_orders,
        layout_trees = layout_trees,
        i18n = translator,
    })
    local columns, rows = assert(backend.size())
    local visible_widgets = {}
    -- Overview cards for a resource this host does not expose at all.  These
    -- are the optional ones: the required CPU/memory/pressure cards always
    -- stay, because "0%" and "absent" are different facts worth showing.
    local OPTIONAL_WIDGETS = {
        gpu_overview = "gpus",
        frequency_overview = "cpu_frequency",
        temperature_overview = "sensors",
        power_overview = "power",
        battery_bars = "power_supplies",
        core_overview = "cpu",
    }

    local function suppressed_widgets()
        local suppressed = {}
        for widget_id, resource in pairs(OPTIONAL_WIDGETS) do
            local state = engine.snapshot.quality and engine.snapshot.quality[resource]
            if state and state.status == "unavailable" then
                suppressed[widget_id] = true
            end
        end
        return suppressed
    end

    -- Declared before the first closure that assigns them; a `local` written
    -- after its use site would silently become a global.
    local dirty = true
    local force = true

    local function sync_engine_visibility()
        -- A widget entering or leaving the tree rebuilds the page geometry, so
        -- the next frame must be a full repaint rather than a diff.
        if workspace:set_suppressed(suppressed_widgets()) then
            renderer:invalidate()
            force = true
            dirty = true
        end
        visible_widgets = workspace:visible_widgets(columns, rows)
        assert(engine:set_active_tab(workspace.active, visible_widgets))
        return visible_widgets
    end
    sync_engine_visibility()
    local process_controller = ProcessTable.new({ sort_key = "cpu", descending = true })
    local decoder = UI.Input.Decoder.new()
    local inspector_registry = make_inspectors(engine)
    local collector_capabilities = engine:probe()
    engine:tick_visible()
    local combined_capabilities = merge(collector_capabilities, {
        inspectors = inspector_registry:probe_all(inspector_context(engine)),
    })
    local process_offset = 0
    local frequency_index = UpdateFrequency.nearest_index(engine.interval_ms or options.interval_ms or 1000)
        or UpdateFrequency.DEFAULT_INDEX
    local paused = false
    local running = true
    local overlay
    local overlay_offset = 0
    local smart_selection
    local confirmation
    local search_edit
    local locale_report = options.locale_report
    local status_message
    if locale_report and locale_report.state == "partial" then
        status_message = translated(translator, "i18n.user_catalog_partial",
            "User locale catalogs: {loaded} loaded, {errors} errors", {
                loaded = #locale_report.loaded,
                errors = #locale_report.errors,
            })
    elseif locale_report and (locale_report.state == "denied" or locale_report.state == "error") then
        status_message = translated(translator, "i18n.user_catalog_failed",
            "User locale catalogs unavailable: {reason}", {
                reason = tostring(locale_report.errors[1] and locale_report.errors[1].reason
                    or locale_report.state),
            })
    end
    local last_metadata
    local last_rendered_page
    -- Resolve the default here rather than leaving it nil: the page falls back
    -- to Theme.DEFAULT when rendering, so a nil name made the first `T` press
    -- jump from the theme actually on screen to the second in the list.
    local theme_name = options.theme or UI.Theme.DEFAULT
    local show_virtual = false
    local available_locales = I18n.available() or { translator:locale() }

    --- Rebuild the translator and every string the workspace baked in.
    -- Page and widget titles are resolved when the workspace is constructed, so
    -- a language change has to rebuild it.  The persisted layout trees, the
    -- active tab, focus, edit mode and the undo history all carry over, so the
    -- switch is invisible apart from the language.
    local function cycle_locale(delta)
        local current = translator:locale()
        local index = 1
        for position, locale in ipairs(available_locales) do
            if locale == current then index = position break end
        end
        local target = available_locales[((index - 1 + (delta or 1)) % #available_locales) + 1]
        local replacement, replacement_error = I18n.new({ locale = target })
        if not replacement then
            status_message = translated(translator, "status.locale_failed",
                "Cannot switch language: {reason}", { reason = tostring(replacement_error) })
            return false
        end
        if not Privilege.restricts_user_files(options.privilege) then
            UserCatalogs.load(replacement)
        end
        translator = replacement
        local rebuilt = Workspace.new({
            active_tab = workspace.active,
            layout_trees = workspace:trees(),
            i18n = translator,
        })
        rebuilt.focus = workspace.focus
        rebuilt.edit_mode = workspace.edit_mode
        rebuilt.dirty = workspace.dirty
        rebuilt.undo_stack = workspace.undo_stack
        rebuilt.redo_stack = workspace.redo_stack
        workspace = rebuilt
        workspace:set_suppressed(suppressed_widgets())
        status_message = translated(translator, "status.locale", "Language: {name}",
            { name = translator:locale() })
        renderer:invalidate()
        force = true
        dirty = true
        return true
    end
    -- Per-widget scroll offsets.  Any panel whose content exceeds its
    -- rectangle becomes scrollable while focused, so overflowing rows are
    -- reachable instead of silently clipped.
    local widget_offsets = {}

    local function focused_widget_id()
        return workspace.focus and workspace.focus[workspace.active] or nil
    end

    local function scroll_focused_widget(delta, page)
        local id = focused_widget_id()
        if not id then return false end
        local widget = last_metadata and last_metadata.widgets and last_metadata.widgets[id]
        if not widget or widget.scrollable ~= true then return false end
        local step = page and math.max(1, (widget.visible or 1) - 1) or 1
        local maximum = math.max(0, (widget.total or 0) - (widget.visible or 1))
        widget_offsets[id] = math.max(0,
            math.min(maximum, (widget_offsets[id] or 0) + delta * step))
        dirty = true
        return true
    end

    --- Rows the process table actually drew last frame.
    local function process_visible_rows()
        local widget = last_metadata and last_metadata.widgets
            and last_metadata.widgets.process_table
        if widget and type(widget.visible_rows) == "number" and widget.visible_rows > 0 then
            return widget.visible_rows
        end
        -- Before the first frame there is no measurement; the conservative
        -- estimate only has to be small enough not to skip rows.
        return math.max(1, rows - 6)
    end

    local function clock_label()
        local wall_ns = engine.clock and engine.clock.wall_ns and engine.clock.wall_ns()
        if type(wall_ns) ~= "number" then return nil end
        local ok, text = pcall(os.date, "%H:%M:%S", math.floor(wall_ns / 1000000000))
        return ok and text or nil
    end

    local function brand_label()
        local host = engine.snapshot.system and engine.snapshot.system.host
            and engine.snapshot.system.host.hostname
        if type(host) == "string" and host ~= "" then
            return "wtop " .. host
        end
        return "wtop"
    end

    -- Anything the operator should look at right now: a denied or failing
    -- collector, or a resource past its critical threshold.
    local function alert_count(snapshot)
        local count = 0
        for _, state in pairs(snapshot.quality or {}) do
            if state.status == "denied" or state.status == "error" then count = count + 1 end
        end
        local memory = snapshot.memory
        if memory and memory.total_bytes and memory.total_bytes > 0
            and memory.used_bytes * 100 / memory.total_bytes >= 92 then
            count = count + 1
        end
        for _, mount in ipairs(snapshot.mounts and snapshot.mounts.mounts or {}) do
            local used = mount.capacity and mount.capacity.used_percent
            if mount.kind == "local" and type(used) == "number" and used >= 92 then
                count = count + 1
            end
        end
        return count
    end

    local function current_frequency_label()
        local level = assert(UpdateFrequency.level(frequency_index))
        local level_name = translated(translator, level.label_id, level.fallback)
        return translated(translator, "sampling.update_frequency",
            "Update rate: " .. level_name, { level = level_name })
    end

    local function cycle_frequency(delta)
        frequency_index = assert(UpdateFrequency.cycle(frequency_index, delta or 1))
        local level = assert(UpdateFrequency.level(frequency_index))
        assert(engine:set_interval(level.interval_ms))
        dirty = true
    end

    local function selected_process()
        return process_controller:selected()
    end

    local function sync_selected_process()
        local id = workspace.active == "processes" and process_controller:selected_id() or nil
        engine.context.selected_process_ids = id and { [id] = true } or {}
    end

    local function show_overlay(lines)
        overlay = lines
        overlay_offset = 0
    end

    -- Footer actions and key bindings must stay in step, so both funnel into
    -- the same synthetic key event rather than duplicating the handlers.
    local run_command

    local function refresh_signal_menu()
        if not confirmation then return end
        overlay = signal_menu_lines(confirmation.process, confirmation.index, translator,
            terminal_capabilities.unicode ~= false)
    end

    local function refresh_smart_selection()
        if not smart_selection then return end
        overlay = smart_selection_lines(smart_selection.devices, smart_selection.index,
            translator, smart_selection.truncated, terminal_capabilities.unicode ~= false)
        local body_rows = math.max(1, rows - 5)
        local selected_line = 4 + smart_selection.index
        overlay_offset = math.max(0, selected_line - body_rows - 1)
    end

    local function inspect_smart_device(device)
        smart_selection = nil
        local result = inspector_registry:inspect(
            "storage.smart", inspector_context(engine), device, "summary")
        show_overlay(inspector_lines(translated(translator, "inspector.smart", "SMART / NVMe")
            .. " · " .. tostring(device.path), result, translator))
    end

    local function inspect_smart()
        local context = inspector_context(engine)
        local devices, enumerate_error = inspector_registry:enumerate("storage.smart", context)
        if not devices or #devices == 0 then
            show_overlay({
                translated(translator, "inspector.smart", "SMART / NVMe"), "",
                translated(translator, "inspector.no_storage_device", "No inspectable block device"),
                tostring(enumerate_error or ""), "",
                translated(translator, "inspector.close_hint", "Esc/Enter closes"),
            })
            return
        end
        local maximum = math.min(#devices, 256)
        local visible = {}
        for index = 1, maximum do visible[index] = devices[index] end
        smart_selection = {
            devices = visible,
            index = 1,
            truncated = devices.truncated == true or maximum < #devices,
        }
        refresh_smart_selection()
    end

    local function inspect_bandwidth()
        local result = inspector_registry:inspect("memory.bandwidth", inspector_context(engine), {
            id = "system-memory",
            name = "System RAM",
        }, "summary")
        show_overlay(inspector_lines(translated(translator, "inspector.ram_bandwidth", "RAM bandwidth"),
            result, translator))
    end

    local function inspect_sshd()
        local result = inspector_registry:inspect("service.sshd", inspector_context(engine), {
            id = "sshd.service", name = "sshd", unit = "sshd.service",
        }, "summary")
        show_overlay(inspector_lines(translated(translator, "inspector.sshd", "sshd service"), result, translator))
    end

    local function render_frame()
        if last_rendered_page ~= workspace.active then
            -- A page switch changes most of the screen. Repaint it as one
            -- explicit full frame so stale content cannot survive even when
            -- terminal width semantics differ at an old/new glyph boundary.
            renderer:invalidate()
            force = true
        end
        sync_engine_visibility()
        local models = ViewModel.build(engine, engine.snapshot, translator, combined_capabilities,
            workspace.active, process_controller, visible_widgets, {
                privilege = options.privilege,
                show_virtual_devices = show_virtual,
                show_pseudo_filesystems = show_virtual,
            })
        local process_count = #models.process_table.rows
        local process_selected = models.process_table.status.selected_index or 0
        -- The table reports the row count it actually drew on the previous
        -- frame.  Deriving it from the terminal height instead was off by the
        -- header, the border and the status row, so the selected row could sit
        -- one line below the viewport and stay invisible while scrolling.
        local visible_rows = process_visible_rows()
        if process_count == 0 then
            process_offset = 0
        elseif process_selected <= process_offset then
            process_offset = process_selected - 1
        elseif process_selected > process_offset + visible_rows then
            process_offset = process_selected - visible_rows
        end
        process_offset = math.max(0, math.min(math.max(0, process_count - 1), process_offset))
        models.process_table.selected = process_selected
        models.process_table.offset = process_offset
        for id, offset in pairs(widget_offsets) do
            if type(models[id]) == "table" then models[id].offset = offset end
        end
        sync_selected_process()

        local config_status = options.config_status
        local persisted_error = config_status and config_status.state == "error" and config_status.reason
            or (layout_status and layout_status.state == "error" and layout_status.reason)
        local status = {
            message = status_message,
            error = persisted_error,
            privilege = options.privilege,
            -- The process table prints its own sort/filter status inside the
            -- panel; repeating it in the footer wasted the one place a
            -- transient message can appear.
            filter = workspace.active == "processes"
                and models.process_table.status.query ~= ""
                and translated(translator, "process.filter_status", " · Filter: {query}",
                    { query = models.process_table.status.query })
                or nil,
            data_age = clock_label(),
            hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "Space", id = paused and "actions.resume" or "actions.pause",
                  fallback = paused and "Resume" or "Pause", command = "pause" },
                { key = "f", id = "actions.update_frequency", fallback = "Rate", command = "rate" },
                { key = "e", id = "actions.edit_layout", fallback = "Layout", command = "layout" },
                { key = "T", id = "actions.theme", fallback = "Theme", command = "theme" },
                { key = "L", id = "actions.language", fallback = "Lang", command = "language" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            },
        }
        if workspace.active == "processes" then
            status.hints = {
                { key = "/", id = "actions.search", fallback = "Search", command = "search" },
                { key = "o", id = "actions.sort", fallback = "Sort", command = "sort" },
                { key = "O", id = "actions.reverse", fallback = "Reverse", command = "reverse" },
                { key = "t", id = "actions.tree", fallback = "Tree", command = "tree" },
                { key = "p", id = "actions.paths", fallback = "Paths", command = "paths" },
                { key = "Enter", id = "actions.details", fallback = "Details", command = "details" },
                { key = "k", id = "actions.signal", fallback = "Signal", command = "signal" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
            }
        elseif workspace.active == "storage" or workspace.active == "network" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "v", id = "actions.toggle_virtual", fallback = "Virtual", command = "virtual" },
                { key = "s", id = "actions.inspect_smart", fallback = "SMART", command = "smart" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            }
        elseif workspace.active == "insights" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "s", id = "actions.inspect_smart", fallback = "SMART", command = "smart" },
                { key = "b", id = "actions.inspect_bandwidth", fallback = "Bandwidth", command = "bandwidth" },
                { key = "d", id = "actions.inspect_sshd", fallback = "sshd", command = "sshd" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
            }
        end
        if search_edit then
            status.filter = nil
            -- Show the caret at the cursor so left/right movement is visible.
            local draft = search_edit.draft
            local cursor = math.max(1, math.min(#draft + 1, search_edit.cursor or (#draft + 1)))
            local shown = draft:sub(1, cursor - 1) .. "▏" .. draft:sub(cursor)
            if terminal_capabilities.unicode == false then
                shown = draft:sub(1, cursor - 1) .. "|" .. draft:sub(cursor)
            end
            status.message = translated(translator, "process.search_prompt",
                "Search: /{query} · Enter confirms · Esc cancels", { query = shown })
            status.warning = true
        end
        if confirmation then
            status.message = translated(translator, "process.signal_prompt",
                "Choose a signal for PID {pid}", { pid = confirmation.process.pid })
            status.warning = true
        end
        local grid, metadata = workspace:render(columns, rows, {
            capabilities = terminal_capabilities,
            i18n = translator,
            theme_name = theme_name,
            widgets = models,
            paused = paused,
            frequency_label = current_frequency_label(),
            brand = brand_label(),
            alert_count = alert_count(engine.snapshot),
            status = status,
            width_fn = native.available and width_function or nil,
        })
        if overlay then
            overlay_offset = math.min(overlay_offset, overlay_max_offset(rows, columns, overlay))
            draw_overlay(grid, metadata.theme, overlay, overlay_offset, terminal_capabilities)
        end
        local presented, present_error = renderer:present(grid, force)
        if not presented then
            error("terminal render failed: " .. tostring(present_error))
        end
        force = false
        dirty = false
        last_rendered_page = workspace.active
        last_metadata = metadata
        return models
    end

    local models = render_frame()

    --- Replace the draft and move the cursor.
    -- The draft deliberately keeps exactly what was typed.  Feeding the
    -- controller's normalised result back in trimmed trailing whitespace, which
    -- made a multi-term query (`user:root state:D`) impossible to type: the
    -- space vanished the moment it was entered.
    local function update_search(value, cursor)
        local maximum = process_controller:status().max_query_bytes or 256
        value = tostring(value or "")
        if #value > maximum then
            value = value:sub(1, maximum)
            local _, invalid_at = utf8.len(value)
            if invalid_at then value = value:sub(1, invalid_at - 1) end
        end
        search_edit.draft = value
        search_edit.cursor = math.max(1, math.min(#value + 1, cursor or (#value + 1)))
        process_controller:set_query(value)
        sync_selected_process()
        dirty = true
    end

    local function search_insert(text)
        if type(text) ~= "string" or text == "" then return end
        local draft, cursor = search_edit.draft, search_edit.cursor
        update_search(draft:sub(1, cursor - 1) .. text .. draft:sub(cursor),
            cursor + #text)
    end

    local function process_event(event)
        -- Ctrl-C is an unconditional emergency exit, including while a
        -- confirmation, search editor, or inspector overlay owns the input.
        if event.type == "key" and event.ctrl and event.key == "c" then
            running = false
            return
        end
        if confirmation then
            local function close()
                confirmation = nil
                overlay = nil
                overlay_offset = 0
                dirty = true
            end
            if event.type == "key" and (event.key == "up" or event.key == "down") then
                local count = #SIGNAL_CHOICES
                confirmation.index = ((confirmation.index - 1
                    + (event.key == "down" and 1 or -1)) % count) + 1
                refresh_signal_menu()
                dirty = true
            elseif event.type == "key" and event.key == "enter" then
                local choice = SIGNAL_CHOICES[confirmation.index]
                local sent, send_error = Actions.signal_process(confirmation.process, choice.number)
                status_message = sent and translated(translator, "process.signal_sent",
                    "{signal} sent to PID {pid}",
                    { signal = choice.name, pid = confirmation.process.pid })
                    or translated(translator, "process.action_refused", "Action refused: {reason}", {
                        reason = tostring(send_error),
                    })
                close()
                engine:tick_visible()
            elseif event.type == "key" then
                close()
                status_message = translated(translator, "process.action_cancelled", "Action cancelled")
            end
            return
        end

        if search_edit then
            local draft, cursor = search_edit.draft, search_edit.cursor
            if event.type == "paste" and type(event.text) == "string" then
                search_insert((event.text:gsub("[%z\1-\31\127]", " ")))
                return
            end
            if event.type ~= "key" then return end
            local key = event.key
            if key == "enter" then
                search_edit = nil
                dirty = true
            elseif key == "escape" then
                process_controller:set_query(search_edit.original)
                if search_edit.original_selected_id then
                    process_controller:select_id(search_edit.original_selected_id)
                end
                search_edit = nil
                sync_selected_process()
                dirty = true
            elseif key == "backspace" then
                if cursor > 1 then
                    local previous = utf8_previous_offset(draft, cursor)
                    update_search(draft:sub(1, previous - 1) .. draft:sub(cursor), previous)
                end
            elseif key == "delete" then
                if cursor <= #draft then
                    local following = utf8_next_offset(draft, cursor)
                    update_search(draft:sub(1, cursor - 1) .. draft:sub(following), cursor)
                end
            elseif key == "left" then
                search_edit.cursor = utf8_previous_offset(draft, cursor)
                dirty = true
            elseif key == "right" then
                search_edit.cursor = utf8_next_offset(draft, cursor)
                dirty = true
            elseif key == "home" or (event.ctrl and key == "a") then
                search_edit.cursor = 1
                dirty = true
            elseif key == "end" or (event.ctrl and key == "e") then
                search_edit.cursor = #draft + 1
                dirty = true
            elseif event.ctrl and key == "u" then
                -- Readline: kill from the cursor back to the start of the line.
                update_search(draft:sub(cursor), 1)
            elseif event.ctrl and key == "k" then
                update_search(draft:sub(1, cursor - 1), cursor)
            elseif event.ctrl and key == "w" then
                local head = draft:sub(1, cursor - 1)
                local trimmed = head:gsub("%s+$", ""):gsub("%S+$", "")
                update_search(trimmed .. draft:sub(cursor), #trimmed + 1)
            elseif event.text and not event.ctrl and not event.alt then
                search_insert(event.text)
            end
            return
        end

        if overlay then
            if smart_selection then
                local count = #smart_selection.devices
                if event.type == "mouse" and event.action == "scroll" then
                    smart_selection.index = math.max(1, math.min(count,
                        smart_selection.index + (event.direction == "down" and 1 or -1)))
                    refresh_smart_selection()
                    dirty = true
                elseif event.type == "key" and (event.key == "up" or event.key == "down"
                    or event.key == "pageup" or event.key == "pagedown"
                    or event.key == "home" or event.key == "end")
                then
                    local delta = (event.key == "pageup" or event.key == "pagedown")
                        and math.max(1, rows - 8) or 1
                    if event.key == "home" then smart_selection.index = 1
                    elseif event.key == "end" then smart_selection.index = count
                    else
                        if event.key == "up" or event.key == "pageup" then delta = -delta end
                        smart_selection.index = math.max(1, math.min(count, smart_selection.index + delta))
                    end
                    refresh_smart_selection()
                    dirty = true
                elseif event.type == "key" and event.key == "enter" then
                    inspect_smart_device(smart_selection.devices[smart_selection.index])
                    dirty = true
                elseif event.type == "key" and (event.key == "escape" or event.key == "q") then
                    smart_selection = nil
                    overlay = nil
                    overlay_offset = 0
                    dirty = true
                end
                return
            end
            local maximum = overlay_max_offset(rows, columns, overlay)
            if event.type == "mouse" and event.action == "scroll" then
                overlay_offset = math.max(0, math.min(maximum,
                    overlay_offset + (event.direction == "down" and 1 or -1)))
                dirty = true
            elseif event.type == "key" and (event.key == "up" or event.key == "down"
                or event.key == "pageup" or event.key == "pagedown"
                or event.key == "home" or event.key == "end")
            then
                local page = math.max(1, rows - 6)
                if event.key == "home" then
                    overlay_offset = 0
                elseif event.key == "end" then
                    overlay_offset = maximum
                else
                    local delta = (event.key == "pageup" or event.key == "pagedown") and page or 1
                    if event.key == "up" or event.key == "pageup" then delta = -delta end
                    overlay_offset = math.max(0, math.min(maximum, overlay_offset + delta))
                end
                dirty = true
            elseif event.type == "key" and (event.key == "escape" or event.key == "enter"
                or event.key == "q" or event.key == "?" or event.key == "f1")
            then
                overlay = nil
                overlay_offset = 0
                dirty = true
            end
            return
        end

        if event.type == "mouse" then
            if event.action == "press" and event.y == 1 and last_metadata and last_metadata.tabs then
                local frequency = last_metadata.tabs.frequency
                if event.button == 1 and frequency
                    and event.x >= frequency.x and event.x < frequency.x + frequency.width
                then
                    cycle_frequency(1)
                    return
                end
                for _, hitbox in ipairs(last_metadata.tabs.tabs or {}) do
                    if event.x >= hitbox.x and event.x < hitbox.x + hitbox.width then
                        if workspace:select(hitbox.id) then
                            sync_engine_visibility()
                        end
                        dirty = true
                        return
                    end
                end
                return
            end
            -- The footer already computed a hit box for every shortcut it drew;
            -- nothing consumed them, so the hints looked like buttons and
            -- behaved like decoration.
            if event.action == "press" and event.y == rows and last_metadata
                and last_metadata.status then
                for _, hint in ipairs(last_metadata.status.hints or {}) do
                    if event.x >= hint.x and event.x < hint.x + hint.width then
                        run_command(hint.command)
                        return
                    end
                end
                return
            end
            if event.action == "scroll" and workspace.active ~= "processes" then
                if scroll_focused_widget(event.direction == "down" and 1 or -1, false) then
                    return
                end
            end
            local table_widget = last_metadata and last_metadata.widgets
                and last_metadata.widgets.process_table
            if workspace.active == "processes" and table_widget then
                if event.action == "press" and table_widget.headers
                    and event.y == table_widget.header_y then
                    for _, header in ipairs(table_widget.headers) do
                        if event.x >= header.x and event.x < header.x + header.width then
                            local status = process_controller:status()
                            if status.sort_key == header.sort_key then
                                process_controller:toggle_direction()
                            else
                                process_controller:set_sort(header.sort_key)
                            end
                            sync_selected_process()
                            dirty = true
                            return
                        end
                    end
                elseif event.action == "press" and event.y >= table_widget.rows_y
                    and event.y < table_widget.rows_y + (table_widget.visible_rows or 0)
                    and event.x >= table_widget.rows_x
                    and event.x < table_widget.rows_x + (table_widget.rows_width or 0) then
                    local index = (table_widget.offset or 0) + (event.y - table_widget.rows_y) + 1
                    if process_controller:select_index(index) then
                        sync_selected_process()
                        dirty = true
                    end
                    return
                elseif event.action == "scroll" then
                    -- Scrolling moves the viewport, not the selection, and by a
                    -- conventional three rows per notch.
                    local step = 3 * (event.direction == "down" and 1 or -1)
                    process_offset = math.max(0, process_offset + step)
                    local count = models and #models.process_table.rows or 0
                    process_offset = math.min(process_offset, math.max(0, count - 1))
                    local visible = process_visible_rows()
                    local selected = process_controller:status().selected_index or 1
                    if selected <= process_offset then
                        process_controller:select_index(process_offset + 1)
                    elseif selected > process_offset + visible then
                        process_controller:select_index(process_offset + visible)
                    end
                    sync_selected_process()
                    dirty = true
                    return
                end
            end
            return
        elseif event.type ~= "key" then
            return
        end

        local key = event.key
        if (event.ctrl and key == "c") or key == "q" then
            running = false
        elseif key:match("^[0-9]$") then
            -- Ten tabs: 1..9 then 0 for the tenth, the familiar browser order.
            local index = key == "0" and 10 or tonumber(key)
            if workspace:select(index) then
                sync_engine_visibility()
            end
            dirty = true
        elseif key == "left" then
            if workspace.edit_mode then
                workspace:move_focused_direction("left")
            else
                workspace:cycle(-1)
                sync_engine_visibility()
            end
            dirty = true
        elseif key == "right" then
            if workspace.edit_mode then
                workspace:move_focused_direction("right")
            else
                workspace:cycle(1)
                sync_engine_visibility()
            end
            dirty = true
        elseif key == "tab" then
            -- Focus only visits widgets the responsive solver actually placed;
            -- cycling through hidden ones looked like the key did nothing.
            workspace:focus_cycle(event.shift and -1 or 1, visible_widgets)
            dirty = true
        elseif key == "up" and workspace.edit_mode then
            workspace:move_focused_direction("above")
            dirty = true
        elseif key == "down" and workspace.edit_mode then
            workspace:move_focused_direction("below")
            dirty = true
        elseif key == "escape" and workspace.edit_mode then
            workspace:toggle_edit()
            dirty = true
        elseif (key == "[" or key == "]") and workspace.edit_mode then
            workspace:adjust_focused_ratio(key == "[" and -0.05 or 0.05)
            dirty = true
        elseif (key == "u" or key == "U") and workspace.edit_mode then
            if key == "U" or event.shift then workspace:redo() else workspace:undo() end
            dirty = true
        elseif (key == "up" or key == "down" or key == "pageup" or key == "pagedown")
            and workspace.active ~= "processes"
            and scroll_focused_widget(
                (key == "up" or key == "pageup") and -1 or 1,
                key == "pageup" or key == "pagedown") then
            -- handled by the focused panel
        elseif (key == "up" or key == "down" or key == "pageup" or key == "pagedown"
            or key == "home" or key == "end") and workspace.active == "processes" then
            -- The decoder always produced these keys and the overlays already
            -- used them; only the main table ignored everything but up/down,
            -- so reaching row 2000 meant two thousand key presses.
            local visible = process_visible_rows()
            if key == "home" then
                process_controller:select_index(1)
            elseif key == "end" then
                process_controller:select_index(#(models and models.process_table.rows or {}))
            else
                local step = (key == "pageup" or key == "pagedown") and math.max(1, visible - 1) or 1
                if key == "up" or key == "pageup" then step = -step end
                process_controller:move(step)
            end
            sync_selected_process()
            dirty = true
        elseif key == "/" and workspace.active == "processes" then
            local query = process_controller:status().query
            search_edit = {
                original = query,
                original_selected_id = process_controller:selected_id(),
                draft = query,
                cursor = #query + 1,
            }
            dirty = true
        elseif key == "escape" and workspace.active == "processes"
            and process_controller:status().query ~= ""
        then
            process_controller:set_query("")
            sync_selected_process()
            dirty = true
        elseif key == "o" and workspace.active == "processes" then
            process_controller:cycle_sort()
            sync_selected_process()
            dirty = true
        elseif key == "O" and workspace.active == "processes" then
            process_controller:toggle_direction()
            sync_selected_process()
            dirty = true
        elseif key == "t" and workspace.active == "processes" then
            process_controller:toggle_tree()
            sync_selected_process()
            dirty = true
        elseif key == "p" and workspace.active == "processes" then
            process_controller:toggle_paths()
            dirty = true
        elseif key == "v" then
            show_virtual = not show_virtual
            status_message = show_virtual
                and translated(translator, "status.virtual_shown",
                    "Showing virtual devices and pseudo filesystems")
                or translated(translator, "status.virtual_hidden",
                    "Hiding virtual devices and pseudo filesystems")
            dirty = true
        elseif key == "L" then
            -- `L` is itself a shifted key, so the shift flag is always set and
            -- cannot select a direction here; the cycle simply wraps.
            cycle_locale(1)
        elseif key == "T" then
            theme_name = UI.Theme.next(theme_name)
            status_message = translated(translator, "status.theme", "Theme: {name}",
                { name = theme_name })
            renderer:invalidate()
            force = true
            dirty = true
        elseif key == "space" then
            paused = not paused
            engine:set_paused(paused)
            dirty = true
        elseif key == "f" then
            cycle_frequency(1)
        elseif key == "e" then
            workspace:toggle_edit()
            dirty = true
        elseif key == "?" or key == "f1" then
            show_overlay(help_lines(translator, columns))
            dirty = true
        elseif key == "r" or (event.ctrl and key == "l") then
            sync_engine_visibility()
            engine:tick_visible()
            renderer:invalidate()
            force = true
            dirty = true
        elseif key == "k" and workspace.active == "processes" then
            local process = selected_process()
            if process then
                confirmation = { process = process, index = 1 }
                refresh_signal_menu()
                overlay_offset = 0
            else
                status_message = translated(translator, "process.no_selection", "No process selected")
            end
            dirty = true
        elseif key == "enter" and workspace.active == "processes" then
            local process = selected_process()
            if process then
                show_overlay(process_detail_lines(process, translator))
            else
                status_message = translated(translator, "process.no_selection", "No process selected")
            end
            dirty = true
        elseif key == "s" then
            inspect_smart()
            dirty = true
        elseif key == "b" then
            inspect_bandwidth()
            dirty = true
        elseif key == "d" then
            inspect_sshd()
            dirty = true
        end
    end

    run_command = function(command)
        local keys = {
            tabs = "1", pause = "space", rate = "f", layout = "e", theme = "T",
            help = "?", quit = "q", search = "/", sort = "o", reverse = "O",
            language = "L",
            tree = "t", paths = "p", details = "enter", signal = "k",
            virtual = "v", smart = "s", bandwidth = "b", sshd = "d",
        }
        local key = keys[command]
        if not key then return false end
        process_event({ type = "key", key = key, ctrl = false, alt = false, shift = false })
        return true
    end

    while running do
        local timeout_ms = math.min(engine:next_delay_ms(100), 100)
        local polled, poll_error = backend.poll(timeout_ms)
        if not polled then
            error(poll_error or "terminal poll failed")
        end
        if polled.data then
            for _, event in ipairs(decoder:feed(polled.data, false)) do
                process_event(event)
            end
        elseif decoder:pending() > 0 then
            for _, event in ipairs(decoder:flush()) do
                process_event(event)
            end
        end
        if polled.interrupt or polled.terminate or polled.hangup then
            running = false
        end
        if polled.resize then
            columns, rows = assert(backend.size())
            sync_engine_visibility()
            renderer:invalidate()
            force = true
            dirty = true
        end
        if dirty then sync_engine_visibility() end
        local _, completed = engine:tick(false)
        if next(completed) then
            dirty = true
        end
        if dirty and running then
            models = render_frame()
        end
    end
    if workspace.dirty and not Privilege.restricts_user_files(options.privilege) then
        local saved, save_error = LayoutStore.save(
            workspace:orders(), layout_status and layout_status.path, workspace:trees())
        if not saved then
            error("cannot save layout: " .. tostring(save_error))
        end
    end
    return 0
end

function M.run(options)
    options = options or {}
    local uname = native.uname()
    if not uname or uname.sysname ~= "Linux" then
        io.stderr:write("wtop: Linux is required\n")
        return 1
    end
    if not native.available then
        io.stderr:write("wtop: native module unavailable; run 'make native'\n")
        return 1
    end
    if not native.isatty(0) or not native.isatty(1) then
        io.stderr:write("wtop: interactive mode requires a TTY; use --snapshot or --agent for JSON output\n")
        return 1
    end

    local translator, translation_error = I18n.new({ locale = options.locale })
    if not translator then
        io.stderr:write("wtop: i18n initialization failed: ", tostring(translation_error), "\n")
        return 1
    end
    if Privilege.restricts_user_files(options.privilege) then
        options.locale_report = { state = "skipped", loaded = {}, errors = {} }
    else
        options.locale_report = UserCatalogs.load(translator)
    end
    local terminal = Terminal.new(native)
    local backend = UI.Backend.new(terminal)
    local frequency_index = UpdateFrequency.nearest_index(options.interval_ms or 1000)
        or UpdateFrequency.DEFAULT_INDEX
    local initial_frequency = assert(UpdateFrequency.level(frequency_index))
    local engine = Engine.new({
        interval_ms = initial_frequency.interval_ms,
        safe_mode = options.safe_mode,
    })
    local started = false
    local ok, result = xpcall(function()
        local start_ok, start_error = backend.start({ color = options.color, mouse = options.mouse })
        if not start_ok then
            error(start_error or "terminal start failed")
        end
        started = true
        local renderer = UI.Renderer.new(backend)
        return run_loop(options, backend, renderer, engine, translator)
    end, debug.traceback)
    engine:stop()
    if started then
        backend.stop()
    end
    if not ok then
        error(result, 0)
    end
    return result
end

M.draw_overlay = draw_overlay
M.inspector_lines = inspector_lines
M.process_detail_lines = process_detail_lines
M.smart_selection_lines = smart_selection_lines
M.utf8_backspace = utf8_backspace

return M
