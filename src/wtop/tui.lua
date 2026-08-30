local Actions = require("wtop.actions")
local Engine = require("wtop.engine")
local I18n = require("wtop.i18n")
local UserCatalogs = require("wtop.i18n.user_catalogs")
local Inspectors = require("wtop.inspectors")
local PerfBandwidth = require("wtop.inspectors.perf_bandwidth")
local LayoutStore = require("wtop.layout_store")
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
    return value and value ~= id and value or fallback
end

local function width_function(codepoint)
    local value = native.wcwidth(codepoint)
    if type(value) == "number" and value >= 0 then
        return value
    end
    return nil
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
        for _, key in ipairs(keys) do
            local field = section.fields[key]
            lines[#lines + 1] = string.format("  %-22s %s  [%s]", key,
                format_value(field and field.value, i18n), tostring(field and field.quality or "unknown"))
        end
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
        if type(value) ~= "number" or not format then return "—" end
        return detail_formatted(function() return assert(format:bytes(value)) end)
    end
    local function percent(value)
        if type(value) ~= "number" or not format then return "—" end
        return detail_formatted(function() return assert(format:percent(value, { precision = 1 })) end)
    end
    local function field(label, value)
        return string.format("  %-18s %s", label, format_value(value, i18n))
    end
    local io = type(process.io) == "table" and process.io or {}
    local switches = type(process.context_switches) == "table" and process.context_switches or {}
    local lines = {
        translated(i18n, "process.details_title", "Process details") .. " · PID " .. tostring(process.pid or "—"),
        "",
        translated(i18n, "process.details_identity", "Identity"),
        field("ID", process.id),
        field("PID", process.pid),
        field("PPID", process.parent_pid),
        field(translated(i18n, "process.details_name", "Name"), process.name),
        field(translated(i18n, "process.details_command", "Command"), process.command),
        field(translated(i18n, "metrics.user", "User"), process.user or process.uid),
        field(translated(i18n, "metrics.state", "State"), process.state),
        "",
        translated(i18n, "process.details_resources", "Resources"),
        field("CPU", percent(process.cpu_percent)),
        field(translated(i18n, "metrics.memory", "Memory"), bytes(process.resident_bytes)),
        field(translated(i18n, "process.details_virtual_memory", "Virtual memory"), bytes(process.virtual_bytes)),
        field(translated(i18n, "process.details_threads", "Threads"), process.threads),
        "",
        translated(i18n, "process.details_scheduling", "Scheduling"),
        field(translated(i18n, "process.details_priority", "Priority"), process.priority),
        field("Nice", process.nice),
        field("CPU", process.processor),
        field(translated(i18n, "process.details_process_group", "Process group"), process.process_group),
        field(translated(i18n, "process.details_session", "Session"), process.session),
        "",
        translated(i18n, "process.details_io", "I/O counters"),
        field(translated(i18n, "metrics.read", "Read"), bytes(io.read_bytes)),
        field(translated(i18n, "metrics.write", "Write"), bytes(io.write_bytes)),
        field(translated(i18n, "process.details_cancelled_write", "Cancelled write"), bytes(io.cancelled_write_bytes)),
        field(translated(i18n, "process.details_voluntary_switches", "Voluntary switches"), switches.voluntary),
        field(translated(i18n, "process.details_involuntary_switches", "Involuntary switches"), switches.involuntary),
    }
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
    lines[#lines + 1] = translated(i18n, "process.details_scroll_hint",
        "Up/Down/PgUp/PgDn scroll · Esc/Enter closes")
    return lines
end

local function help_lines(i18n)
    local title = i18n:t("app.title")
    return {
        title ~= "app.title" and title or "wtop — Linux performance workbench",
        "",
        translated(i18n, "help.switch_tabs", "1-8 / left/right switch tabs"),
        translated(i18n, "help.focus_widget", "Tab            focus next widget"),
        translated(i18n, "help.pause_resume", "Space          pause/resume sampling"),
        translated(i18n, "help.update_frequency", "f / click rate cycle update frequency"),
        translated(i18n, "help.refresh", "r / Ctrl-L     refresh and repaint"),
        translated(i18n, "help.edit_layout", "e              layout edit mode"),
        translated(i18n, "help.process_selection", "Up/Down        process selection"),
        translated(i18n, "help.process_search", "/              search processes"),
        translated(i18n, "help.process_sort", "o              cycle process sort"),
        translated(i18n, "help.process_tree", "t              toggle process tree"),
        translated(i18n, "help.process_details", "Enter          process details"),
        translated(i18n, "help.terminate_process", "k              confirm SIGTERM for selected process"),
        translated(i18n, "help.inspect_smart", "s              choose a SMART/NVMe device"),
        translated(i18n, "help.inspect_bandwidth", "b              inspect RAM bandwidth capability"),
        translated(i18n, "help.inspect_sshd", "d              inspect sshd service/listeners"),
        translated(i18n, "help.toggle", "? / F1         toggle this help"),
        translated(i18n, "help.quit", "q / Ctrl-C     quit"),
        "",
        translated(i18n, "help.layout_adapts", "Layouts adapt in both dimensions; edit mode lets Tab select"),
        translated(i18n, "help.layout_reorder", "a widget and left/right reorder it without restarting wtop."),
        translated(i18n, "help.inspectors_safe", "External inspectors use absolute argv, fixed locale, timeout"),
        translated(i18n, "help.smart_standby", "and output limits. SMART probes do not wake standby drives."),
        "",
        translated(i18n, "help.close", "Esc/Enter closes"),
    }
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

local function draw_overlay(grid, theme, lines, offset, capabilities)
    offset = math.max(0, math.floor(tonumber(offset) or 0))
    local maximum_line = 0
    for _, line in ipairs(lines) do
        maximum_line = math.max(maximum_line, UI.Renderer.Width.display_width(line, grid.width_options))
    end
    local width = math.min(grid.width - 2, math.max(28, maximum_line + 4))
    local height = math.min(grid.height - 2, math.max(5, #lines + 2))
    if width < 4 or height < 3 then
        return
    end
    local x = math.floor((grid.width - width) / 2) + 1
    local y = math.floor((grid.height - height) / 2) + 1
    local area = { x = x, y = y, width = width, height = height }
    local background = theme:style("text.primary", "surface.raised")
    local border = theme:style("accent.primary", "surface.raised", { bold = true })
    local unicode = not (capabilities and capabilities.unicode == false)
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
end

local function overlay_max_offset(terminal_rows, lines)
    local height = math.min(terminal_rows - 2, math.max(5, #lines + 2))
    local body_rows = math.max(1, height - 3)
    return math.max(0, (#lines - 1) - body_rows)
end

local function utf8_backspace(value)
    if type(value) ~= "string" or value == "" then return "" end
    local index = utf8.offset(value, -1)
    return index and value:sub(1, index - 1) or ""
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
    if options.privilege and options.privilege.via_sudo then
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
    local function sync_engine_visibility()
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
    local dirty = true
    local force = true
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
            workspace.active, process_controller, visible_widgets)
        local process_count = #models.process_table.rows
        local process_selected = models.process_table.status.selected_index or 0
        local visible_rows = math.max(1, rows - 5)
        if process_count == 0 then
            process_offset = 0
        elseif process_selected <= process_offset then
            process_offset = process_selected - 1
        elseif process_selected > process_offset + visible_rows then
            process_offset = process_selected - visible_rows
        end
        process_offset = math.max(0, process_offset)
        models.process_table.selected = process_selected
        models.process_table.offset = process_offset
        sync_selected_process()

        local config_status = options.config_status
        local persisted_error = config_status and config_status.state == "error" and config_status.reason
            or (layout_status and layout_status.state == "error" and layout_status.reason)
        local status = {
            message = status_message,
            error = persisted_error,
            privilege = options.privilege,
            filter = workspace.active == "processes" and models.process_table.status_text or nil,
            hints = {
                { key = "1–8", id = "actions.tabs", fallback = "Tabs" },
                { key = "Space", id = paused and "actions.resume" or "actions.pause", fallback = paused and "Resume" or "Pause" },
                { key = "f", id = "actions.update_frequency", fallback = "Rate" },
                { key = "e", id = "actions.edit_layout", fallback = "Layout" },
                { key = "?", id = "actions.help", fallback = "Help" },
                { key = "q", id = "actions.quit", fallback = "Quit" },
            },
        }
        if workspace.active == "processes" then
            status.hints = {
                { key = "↑/↓", id = "actions.select", fallback = "Select" },
                { key = "/", id = "actions.search", fallback = "Search" },
                { key = "o", id = "actions.sort", fallback = "Sort" },
                { key = "t", id = "actions.tree", fallback = "Tree" },
                { key = "Enter", id = "actions.details", fallback = "Details" },
                { key = "k", id = "actions.terminate", fallback = "Terminate" },
            }
        end
        if search_edit then
            status.filter = nil
            status.message = translated(translator, "process.search_prompt",
                "Search: /{query}_ · Enter confirms · Esc cancels", { query = search_edit.draft })
            status.warning = true
        end
        if confirmation then
            status.message = translated(translator, "process.confirm_terminate",
                "Confirm SIGTERM for PID {pid}? y/N", { pid = confirmation.pid })
            status.warning = true
        end
        local grid, metadata = workspace:render(columns, rows, {
            capabilities = terminal_capabilities,
            i18n = translator,
            theme_name = options.theme,
            widgets = models,
            paused = paused,
            frequency_label = current_frequency_label(),
            status = status,
            width_fn = native.available and width_function or nil,
        })
        if overlay then
            overlay_offset = math.min(overlay_offset, overlay_max_offset(rows, overlay))
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

    local function update_search(value)
        local maximum = process_controller:status().max_query_bytes or 256
        value = tostring(value or "")
        if #value > maximum * 4 then
            value = value:sub(1, maximum * 4)
        end
        local normalized = process_controller:set_query(value)
        search_edit.draft = normalized
        sync_selected_process()
        dirty = true
    end

    local function process_event(event)
        -- Ctrl-C is an unconditional emergency exit, including while a
        -- confirmation, search editor, or inspector overlay owns the input.
        if event.type == "key" and event.ctrl and event.key == "c" then
            running = false
            return
        end
        if confirmation then
            if event.type == "key" and event.key:lower() == "y" then
                local sent, send_error = Actions.signal_process(confirmation, 15)
                status_message = sent and translated(translator, "process.term_sent",
                    "SIGTERM sent to PID {pid}", { pid = confirmation.pid })
                    or translated(translator, "process.action_refused", "Action refused: {reason}", {
                        reason = tostring(send_error),
                    })
                confirmation = nil
                engine:tick_visible()
                dirty = true
            elseif event.type == "key" then
                confirmation = nil
                status_message = translated(translator, "process.action_cancelled", "Action cancelled")
                dirty = true
            end
            return
        end

        if search_edit then
            if event.type == "key" and event.key == "enter" then
                search_edit = nil
                dirty = true
            elseif event.type == "key" and event.key == "escape" then
                process_controller:set_query(search_edit.original)
                if search_edit.original_selected_id then
                    process_controller:select_id(search_edit.original_selected_id)
                end
                search_edit = nil
                sync_selected_process()
                dirty = true
            elseif event.type == "key" and event.key == "backspace" then
                update_search(utf8_backspace(search_edit.draft))
            elseif event.type == "key" and event.text and not event.ctrl and not event.alt then
                update_search(search_edit.draft .. event.text)
            elseif event.type == "paste" and type(event.text) == "string" then
                update_search(search_edit.draft .. event.text)
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
            local maximum = overlay_max_offset(rows, overlay)
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
            elseif event.action == "scroll" and workspace.active == "processes" then
                process_controller:move(event.direction == "down" and 1 or -1)
                sync_selected_process()
                dirty = true
            end
            return
        elseif event.type ~= "key" then
            return
        end

        local key = event.key
        if (event.ctrl and key == "c") or key == "q" then
            running = false
        elseif key:match("^[1-8]$") then
            if workspace:select(tonumber(key)) then
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
            workspace:focus_cycle(event.shift and -1 or 1)
            dirty = true
        elseif key == "up" and workspace.edit_mode then
            workspace:move_focused_direction("above")
            dirty = true
        elseif key == "down" and workspace.edit_mode then
            workspace:move_focused_direction("below")
            dirty = true
        elseif (key == "[" or key == "]") and workspace.edit_mode then
            workspace:adjust_focused_ratio(key == "[" and -0.05 or 0.05)
            dirty = true
        elseif (key == "u" or key == "U") and workspace.edit_mode then
            if key == "U" or event.shift then workspace:redo() else workspace:undo() end
            dirty = true
        elseif key == "up" and workspace.active == "processes" then
            process_controller:move(-1)
            sync_selected_process()
            dirty = true
        elseif key == "down" and workspace.active == "processes" then
            process_controller:move(1)
            sync_selected_process()
            dirty = true
        elseif key == "/" and workspace.active == "processes" then
            local query = process_controller:status().query
            search_edit = {
                original = query,
                original_selected_id = process_controller:selected_id(),
                draft = query,
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
        elseif key == "t" and workspace.active == "processes" then
            process_controller:toggle_tree()
            sync_selected_process()
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
            show_overlay(help_lines(translator))
            dirty = true
        elseif key == "r" or (event.ctrl and key == "l") then
            sync_engine_visibility()
            engine:tick_visible()
            renderer:invalidate()
            force = true
            dirty = true
        elseif key == "k" and workspace.active == "processes" then
            confirmation = selected_process()
            status_message = confirmation and nil
                or translated(translator, "process.no_selection", "No process selected")
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
        elseif key == "d" or (key == "enter" and workspace.active == "insights") then
            inspect_sshd()
            dirty = true
        end
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
    if workspace.dirty and not (options.privilege and options.privilege.via_sudo) then
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
    if options.privilege and options.privilege.via_sudo then
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
