local Actions = require("wtop.actions")
local CgroupSemantics = require("wtop.collectors.cgroup_semantics")
local Engine = require("wtop.engine")
local I18n = require("wtop.i18n")
local Technical = require("wtop.i18n.technical")
local UserCatalogs = require("wtop.i18n.user_catalogs")
local Inspectors = require("wtop.inspectors")
local Systemd = require("wtop.inspectors.systemd")
local Journal = require("wtop.inspectors.journal")
local JournalStats = require("wtop.inspectors.journal_stats")
local PerfBandwidth = require("wtop.inspectors.perf_bandwidth")
local LayoutStore = require("wtop.layout_store")
local Privilege = require("wtop.privilege")
local ProcessTable = require("wtop.model.process_table")
local ProcessColumns = require("wtop.model.process_columns")
local Hardware = require("wtop.model.hardware")
local FS = require("wtop.linux.fs")
local ConnectionOwner = require("wtop.linux.connection_owner")
local NVMe = require("wtop.linux.nvme_diagnostics")
local ThreadMembers = require("wtop.linux.thread_members")
local ProcessCgroup = require("wtop.linux.process_cgroup")
local Quality = require("wtop.model.quality")
local Health = require("wtop.model.health")
local Thermal = require("wtop.model.thermal")
local SensorPower = require("wtop.model.sensor_power")
local FanControl = require("wtop.model.fan_control")
local TypeC = require("wtop.model.typec")
local WorkloadNavigation = require("wtop.model.workload_navigation")
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

-- Cells a classic Windows console gives each character in its code page, or
-- nil where the backend has no such console. Answers are cached because the
-- renderer asks for every non-ASCII character it draws.
local function console_cells_function()
    if type(native.console_cells) ~= "function" then return nil end
    local cache = {}
    return function(codepoint)
        local cached = cache[codepoint]
        if cached == nil then
            local ok, cells = pcall(native.console_cells, codepoint)
            cached = ok and type(cells) == "number" and cells or 0
            cache[codepoint] = cached
        end
        return cached
    end
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
        if not item.section and not item.blank and not item.note then
            width = math.max(width, UI.Renderer.Width.display_width(tostring(item[1] or "")))
        end
    end
    local lines = {}
    for _, item in ipairs(pairs_list) do
        if item.blank then
            lines[#lines + 1] = ""
        elseif item.section then
            lines[#lines + 1] = tostring(item.section)
        elseif item.note then
            lines[#lines + 1] = "  " .. tostring(item.note)
        else
            lines[#lines + 1] = "  " .. pad_to(item[1], width) .. string.rep(" ", gap or 2)
                .. tostring(item[2] == nil and "—" or item[2])
        end
    end
    return lines
end

local NUMBER_UNIT_SUFFIX = {
    watts = " W", watt_hours = " Wh", volts = " V", amperes = " A", joules = " J",
}

local function format_value(value, i18n, unit)
    if type(value) == "table" then
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        return "[" .. count .. " items]"
    elseif value == nil then
        return "—"
    elseif type(value) == "boolean" then
        return value and translated(i18n, "ui.yes", "yes") or translated(i18n, "ui.no", "no")
    end
    if type(value) == "number" and i18n and i18n.format then
        local format = i18n.format
        local ok, formatted = pcall(function()
            if unit == "bytes" then return format:bytes(value) end
            if unit == "bytes_per_second" then
                local amount = format:bytes(value, { system = "si" })
                return amount and amount .. "/s"
            end
            if unit == "percent" then return format:percent(value, { precision = 1 }) end
            if unit == "celsius" then return format:temperature(value) end
            if unit == "hertz" then return format:frequency(value) end
            if unit == "nanoseconds" then return format:duration(value / 1000000000) end
            if unit == "seconds" then return format:duration(value) end
            local suffix = NUMBER_UNIT_SUFFIX[unit]
            if suffix then
                local amount = format:number(value, { precision = unit == "volts" and 3 or 2 })
                return amount and amount .. suffix
            end
            if unit == "rpm" or unit == "hours" then
                local amount = format:number(value, { precision = 0 })
                return amount and amount .. (unit == "rpm" and " rpm" or " h")
            end
        end)
        if ok and type(formatted) == "string" then return formatted end
    end
    if type(value) == "number" and unit == "rpm" then return tostring(value) .. " rpm" end
    if type(value) == "number" and unit == "hours" then return tostring(value) .. " h" end
    return tostring(value)
end

local function fd_count_text(detail, i18n)
    if type(detail) ~= "table" then return nil end
    if type(detail.count) ~= "number" then
        return Technical.state(i18n, detail.status)
    end
    return (detail.status == "truncated" and ">=" or "")
        .. tostring(detail.count)
end

local INSPECTOR_LIST_LIMIT = 128
local INSPECTOR_ROW_WIDTH = 160
local INSPECTOR_FIELD_WIDTH = 80
local INSPECTOR_ROW_FIELDS = {
    items = { "id", "name", "normalized", "worst", "threshold", "raw", "when_failed" },
    processes = { "pid", "parent_pid", "state", "cpu_percent", "resident_bytes", "command" },
    listeners = { "address", "port", "family", "pid", "state" },
    active_sessions = { "id", "user", "tty", "service", "state", "is_remote", "leader_pid", "scope",
        "remote", "login_time", "idle_seconds", "pid" },
}
local INSPECTOR_EXPAND_FIELDS = {
    ata_attributes = { items = true },
    processes = { processes = true },
    listeners = { listeners = true },
    sessions = { active_sessions = true },
    configuration = { effective = true },
}
local INSPECTOR_METADATA = {
    source = true, timestamp_ns = true, quality = true, provider = true,
    provider_version = true,
}

local function inspector_text(value, columns)
    if value == nil then value = "—" end
    local text = tostring(value):gsub("[%c]", " ")
    if UI.Renderer.Width.display_width(text) > columns then
        return UI.Renderer.Width.truncate(text, columns - 3, nil, "") .. "..."
    end
    return text
end

local function inspector_item_value(value, i18n, key)
    if type(value) == "table" then
        if type(value.string) == "string" then return value.string end
        if value.value ~= nil and type(value.value) ~= "table" then
            return format_value(value.value, i18n)
        end
        if #value > 0 then
            local parts = {}
            for index = 1, math.min(#value, 4) do
                local item = value[index]
                if type(item) == "table" then break end
                parts[#parts + 1] = format_value(item, i18n)
            end
            if #parts > 0 then
                if #value > #parts then parts[#parts + 1] = "..." end
                return table.concat(parts, ", ")
            end
        end
        return format_value(value, i18n)
    end
    local unit = key == "resident_bytes" and "bytes"
        or key == "cpu_percent" and "percent" or nil
    return format_value(value, i18n, unit)
end

local function inspector_item_line(item, field_key, i18n)
    if type(item) ~= "table" then
        return inspector_text(format_value(item, i18n), INSPECTOR_ROW_WIDTH)
    end
    local keys = INSPECTOR_ROW_FIELDS[field_key]
    if not keys then
        keys = {}
        for key in pairs(item) do
            if not INSPECTOR_METADATA[key] then keys[#keys + 1] = key end
        end
        table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    end
    local parts = {}
    for _, key in ipairs(keys) do
        local value = item[key]
        if value ~= nil then
            parts[#parts + 1] = tostring(key) .. "=" .. inspector_text(
                inspector_item_value(value, i18n, key), INSPECTOR_FIELD_WIDTH)
            if #parts >= 8 then break end
        end
    end
    return inspector_text(table.concat(parts, "  "), INSPECTOR_ROW_WIDTH)
end

local function inspector_collection_lines(value, field_key, i18n)
    local lines = {}
    local count = #value
    if count > 0 then
        for index = 1, math.min(count, INSPECTOR_LIST_LIMIT) do
            lines[#lines + 1] = "    " .. index .. ". "
                .. inspector_item_line(value[index], field_key, i18n)
        end
    else
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
        count = #keys
        for index = 1, math.min(count, INSPECTOR_LIST_LIMIT) do
            local key = keys[index]
            local repeated = field_key == "effective" and type(value[key]) == "table" and value[key]
            if repeated and #repeated > 0 then
                for item = 1, math.min(#repeated, INSPECTOR_LIST_LIMIT) do
                    lines[#lines + 1] = "    " .. tostring(key) .. "[" .. item .. "]: " .. inspector_text(
                        inspector_item_value(repeated[item], i18n, key), INSPECTOR_ROW_WIDTH)
                end
                if #repeated > INSPECTOR_LIST_LIMIT then
                    lines[#lines + 1] = "    ... +" .. (#repeated - INSPECTOR_LIST_LIMIT)
                end
            else
                lines[#lines + 1] = "    " .. tostring(key) .. ": " .. inspector_text(
                    inspector_item_value(value[key], i18n, key), INSPECTOR_ROW_WIDTH)
            end
        end
    end
    if count > INSPECTOR_LIST_LIMIT then
        lines[#lines + 1] = "    ... +" .. (count - INSPECTOR_LIST_LIMIT)
    end
    return lines
end

local function bandwidth_counter_lines(samples, i18n)
    local lines = { "    " .. translated(i18n, "inspector.bandwidth_control_note",
        "CPU labels identify counter control instances, not DIMM channels.") }
    local function field(id, fallback, value, unit)
        lines[#lines + 1] = inspector_text("      " .. translated(i18n, id, fallback)
            .. ": " .. format_value(value, i18n, unit), INSPECTOR_ROW_WIDTH)
    end
    for index = 1, math.min(#samples, INSPECTOR_LIST_LIMIT) do
        local row = samples[index]
        local read = row.direction == "read"
        local direction = translated(i18n, read and "metrics.read" or "metrics.write", read and "Read" or "Write")
        lines[#lines + 1] = inspector_text("    " .. index .. ". " .. tostring(row.pmu)
            .. " · " .. tostring(row.instance) .. " · " .. direction
            .. " [" .. Technical.state(i18n, row.quality) .. "]", INSPECTOR_ROW_WIDTH)
        field("inspector.bandwidth_event", "Event", row.event)
        field(read and "metrics.read" or "metrics.write", direction, row.bytes_per_second, "bytes_per_second")
        field("inspector.bandwidth_runtime", "Counter runtime", row.runtime_ns, "nanoseconds")
        if row.enabled_ns then field("inspector.bandwidth_enabled", "Counter enabled time", row.enabled_ns, "nanoseconds") end
        if row.bytes_per_count then field("inspector.bandwidth_bytes_per_count", "Bytes per count", row.bytes_per_count) end
        field("inspector.bandwidth_running", "Counter running", row.running_percent, "percent")
        local count = row.count ~= nil and format_value(row.count, i18n)
            .. (row.unit and row.unit ~= "" and " " .. row.unit or "") or "—"
        field("inspector.bandwidth_count", "Reported count", count)
        field("inspector.bandwidth_expected", "Expected control CPU", row.instance_expected == nil
            and Technical.state(i18n, "unknown") or translated(i18n,
            row.instance_expected and "ui.yes" or "ui.no", row.instance_expected and "yes" or "no"))
        if row.reason then field("inspector.reason", "Reason", Technical.reason(i18n, row.reason)) end
    end
    return lines
end

local function inspector_lines(title, result, i18n)
    local lines = { title, "" }
    if not result then
        lines[#lines + 1] = translated(i18n, "inspector.no_result", "Inspector returned no result")
        return lines
    end
    lines[#lines + 1] = translated(i18n, "inspector.status", "Status") .. ": "
        .. tostring(Technical.state(i18n, result.status or "unknown"))
    lines[#lines + 1] = translated(i18n, "inspector.quality", "Quality") .. ": "
        .. tostring(Technical.state(i18n, result.quality or "unknown"))
    if result.provider then
        lines[#lines + 1] = translated(i18n, "inspector.provider", "Provider") .. ": "
            .. tostring(result.provider)
    end
    if result.reason then
        lines[#lines + 1] = translated(i18n, "inspector.reason", "Reason") .. ": "
            .. inspector_text(Technical.reason(i18n, result.reason), INSPECTOR_ROW_WIDTH)
    end
    for _, section in ipairs(result.sections or {}) do
        lines[#lines + 1] = ""
        local nvme = section.id == "nvme_health"
        lines[#lines + 1] = nvme and translated(i18n, "nvme.health_title", "NVMe health")
            or tostring(section.id or section.title_key
                or translated(i18n, "inspector.details", "Details"))
        local keys = {}
        for key in pairs(section.fields or {}) do keys[#keys + 1] = key end
        local priority = nvme and { critical_warning = 1, percentage_used = 2,
            available_spare_percent = 3, temperature_celsius = 4, scope = 5,
            media_errors = 6, power_on_hours = 7, data_units_read = 8, data_units_written = 9 }
            or section.id == "bandwidth" and { measurement_scope = 1, read_bandwidth = 2,
                write_bandwidth = 3, total_bandwidth = 4, theoretical_bandwidth = 5,
                utilization = 6, counter_samples = 7 }
        table.sort(keys, function(a, b)
            if priority then
                local left, right = priority[a] or 100, priority[b] or 100
                if left ~= right then return left < right end
            end
            return a < b
        end)
        local rows = {}
        for _, key in ipairs(keys) do
            local field = section.fields[key]
            local bandwidth_scope = section.id == "bandwidth" and key == "measurement_scope"
            local label = nvme and translated(i18n, "nvme.health_" .. key, key)
                or bandwidth_scope and translated(i18n, "inspector.bandwidth_scope", "Measurement scope")
                or section.id == "bandwidth" and key == "counter_samples"
                    and translated(i18n, "inspector.bandwidth_instances", "Counter instances") or key
            local value = field and field.value
            if nvme and key == "scope" and value == "controller" then
                value = translated(i18n, "nvme.health_controller", "Controller")
            elseif bandwidth_scope and value == "system" then
                value = translated(i18n, "inspector.bandwidth_scope_system", "System aggregate")
            elseif bandwidth_scope and value == "controller_pmu" then
                value = translated(i18n, "inspector.bandwidth_scope_controller", "Selected controller PMU")
            elseif section.id == "bandwidth" and key == "counter_samples" and type(value) == "table" then
                local total = result.details and result.details.counter_samples_total or #value
                value = translated(i18n, "inspector.bandwidth_instances_count", "{shown} shown / {total}",
                    { shown = math.min(#value, INSPECTOR_LIST_LIMIT), total = total })
            end
            rows[#rows + 1] = { label, format_value(value, i18n,
                field and field.unit)
                .. "  [" .. tostring((nvme or section.id == "bandwidth") and Technical.state(i18n, field and field.quality or "unknown")
                    or field and field.quality or "unknown") .. "]" }
        end
        local field_lines = aligned_pairs(rows)
        for index, key in ipairs(keys) do
            lines[#lines + 1] = field_lines[index]
            local field = section.fields[key]
            if nvme and key == "critical_warning" then
                local decoded = require("wtop.model.nvme_warnings").decode(field and field.value)
                if decoded then
                    for _, reason in ipairs(decoded.reasons) do
                        lines[#lines + 1] = "    " .. translated(i18n, "nvme.warning." .. reason, reason)
                            .. " [" .. Technical.state(i18n, field.quality or "unknown") .. "]"
                    end
                    if decoded.unknown_mask ~= 0 then
                        lines[#lines + 1] = "    " .. translated(i18n, "nvme.warning.unknown_bits", "Unrecognized warning bits")
                            .. ": " .. string.format("0x%02x", decoded.unknown_mask)
                            .. " [" .. Technical.state(i18n, field.quality or "unknown") .. "]"
                    end
                end
            end
            local expanded = INSPECTOR_EXPAND_FIELDS[section.id]
            if section.id == "bandwidth" and key == "counter_samples" and field and type(field.value) == "table" then
                for _, line in ipairs(bandwidth_counter_lines(field.value, i18n)) do lines[#lines + 1] = line end
            end
            if field and type(field.value) == "table" and expanded and expanded[key] then
                for _, line in ipairs(inspector_collection_lines(field.value, key, i18n)) do
                    lines[#lines + 1] = line
                end
            end
            if field and field.reason then
                lines[#lines + 1] = "    " .. translated(i18n, "inspector.reason", "Reason")
                    .. ": " .. inspector_text(Technical.reason(i18n, field.reason), INSPECTOR_ROW_WIDTH)
            end
        end
        local config = section.id == "configuration" and result.details and result.details.configuration
        if config and config.data then
            local data = config.data
            lines[#lines + 1] = translated(i18n, "sshd_config.scope", "Configuration scope") .. ": "
                .. translated(i18n, data.scope == "connection" and "sshd_config.connection" or "sshd_config.global",
                    data.scope == "connection" and "Supplied connection (Match rules applied)" or "Global (no connection supplied)")
            lines[#lines + 1] = translated(i18n, "sshd_config.file", "Configuration file") .. ": "
                .. inspector_text(data.file, INSPECTOR_ROW_WIDTH)
            lines[#lines + 1] = translated(i18n, "sshd_config.current_files",
                "Evaluates current files. The daemon may use startup overrides or earlier contents.")
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
end

local function systemd_unit_lines(result, i18n, now_ns)
    local lines = { translated(i18n, "inspector.systemd", "systemd units"), "" }
    if not result then return lines end
    local function add(key, fallback, value)
        lines[#lines + 1] = translated(i18n, key, fallback) .. ": " .. tostring(value or "—")
    end
    add("inspector.status", "Status", Technical.state(i18n, result.status))
    add("inspector.quality", "Quality", Technical.state(i18n, result.quality))
    if result.reason then add("inspector.reason", "Reason", Technical.reason(i18n, result.reason)) end
    local summary = result.entity and result.entity.summary or {}
    for _, item in ipairs({
        { "unit", "systemd.unit", "Unit" }, { "manager", "systemd.manager", "Manager" },
        { "unit_type", "systemd.unit_type", "Unit type" },
        { "description", "systemd.description", "Description" },
        { "load_state", "systemd.load_state", "Load state" },
        { "active_state", "systemd.active_state", "Active state" },
        { "sub_state", "systemd.sub_state", "Substate" },
        { "main_pid", "systemd.main_pid", "Main PID" },
        { "leader_pid", "systemd.leader_pid", "Scope leader PID" },
        { "restarts", "systemd.restarts", "Restarts" },
        { "result", "systemd.result", "Service result" },
        { "exit_status", "systemd.exit_status", "Main exit status" },
        { "exit_code", "systemd.exit_code", "Main exit code" },
        { "memory", "metrics.memory", "Memory" },
        { "cpu_time", "systemd.cpu_time", "CPU time" },
        { "tasks", "systemd.tasks", "Tasks" },
        { "memory_max", "systemd.memory_max", "Configured memory limit" },
        { "tasks_max", "systemd.tasks_max", "Configured task limit" },
        { "cpu_quota", "systemd.cpu_quota", "Configured CPU quota" },
        { "cgroup", "systemd.cgroup", "Control group" },
        { "fragment_path", "systemd.fragment_path", "Unit file" },
    }) do
        local field = summary[item[1]]
        if field then
            local value = field.value
            local shown = value == "unlimited" and translated(i18n, "systemd.unlimited", "unlimited")
                or item[1] == "manager" and value and translated(i18n,
                    value == "user" and "systemd.manager_user" or "systemd.manager_system",
                    value == "user" and "current user" or "system")
                or format_value(value, i18n, field.unit)
            if value == nil then shown = shown .. " [" .. Technical.state(i18n, field.quality) .. "]" end
            add(item[2], item[3], inspector_text(shown, INSPECTOR_ROW_WIDTH))
        end
    end
    add("metrics.source", "Source", result.source)
    if type(now_ns) == "number" and type(result.timestamp_ns) == "number" then
        add("systemd.sample_age", "Sample age", format_value(
            math.max(0, now_ns - result.timestamp_ns), i18n, "nanoseconds"))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "systemd.detail_hint",
        "p main process · g workload · l journal · r refresh · Esc/Enter back")
    return lines
end

local function journal_time(timestamp)
    if type(timestamp) ~= "number" or math.type(timestamp) ~= "integer" then return "—" end
    local ok, shown = pcall(os.date, "!%Y-%m-%d %H:%M:%S", timestamp // 1000000)
    return ok and shown .. string.format(".%06d UTC", timestamp % 1000000) or tostring(timestamp)
end

local function event_stats_lines(result, i18n, now_ns, unit, origin)
    result = type(result) == "table" and result or {}
    local data = result.data
    local lines = { translated(i18n, "events.title", "Log summary · {unit}", {
        unit = data and data.unit or unit or "—" }), "" }
    local function add(key, fallback, value)
        lines[#lines + 1] = translated(i18n, key, fallback) .. ": " .. tostring(value or "—")
    end
    add("inspector.status", "Status", Technical.state(i18n, result.status or "unavailable"))
    add("inspector.quality", "Quality", Technical.state(i18n, result.quality or "unavailable"))
    if result.reason then add("inspector.reason", "Reason", Technical.reason(i18n, result.reason)) end
    if data then
        lines[#lines + 1] = translated(i18n, "events.scope", "Current boot · accessible query · at most {count} entries",
            { count = data.max_entries or 100 })
        add("events.entries", "Queried entries", data.entries)
        add("events.oldest", "Oldest recorded time", journal_time(data.oldest_us))
        add("events.newest", "Newest recorded time", journal_time(data.newest_us))
        add("events.unreadable", "Unavailable or truncated messages", data.unreadable)
        add("events.rejected", "Rejected records", data.rejected)
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "events.priorities", "Journal priorities")
        for index, name in ipairs(JournalStats.priorities) do
            add("journal.priority_" .. (index - 1), name, data.priorities[name])
        end
        add("events.unknown_priority", "Unknown priority", data.priorities.unknown)
        lines[#lines + 1] = ""
        for _, name in ipairs({ "emitted", "member", "referenced" }) do add("journal.relation_" .. name, name, data.relations[name]) end
        add("events.unknown_relation", "Unknown relation", data.relations.unknown)
        if data.auth then
            lines[#lines + 1] = ""
            lines[#lines + 1] = translated(i18n, "events.auth_title", "OpenSSH text matches")
            for _, name in ipairs({ "considered", "accepted", "failed", "partial", "postponed", "invalid_user", "unclassified", "unreadable" }) do
                add("events.auth_" .. name, name, data.auth[name])
            end
            lines[#lines + 1] = translated(i18n, "events.auth_note",
                "Counts match log messages, not distinct attempts, connections or sessions. Unknown formats remain unclassified.")
        end
        if data.entries == 0 then lines[#lines + 1] = translated(i18n, "journal.empty", "No accessible entries in this query") end
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "events.note", "These counts cover the returned query, not all activity in this boot.")
    end
    if type(now_ns) == "number" and type(result.timestamp_ns) == "number" then
        add("systemd.sample_age", "Sample age", format_value(math.max(0, now_ns - result.timestamp_ns), i18n, "nanoseconds"))
    end
    add("metrics.source", "Source", result.source)
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, origin == "journal" and "events.journal_hint" or "events.service_hint",
        origin == "journal" and "s journal · r refresh · Esc/Enter back" or "r refresh · Esc/Enter service")
    return lines
end

local function journal_lines(view, i18n, unicode, now_ns)
    view = type(view) == "table" and view or {}
    if view.stats then
        return event_stats_lines(view.summary or JournalStats.summarize(view.result), i18n, now_ns, view.unit, "journal")
    end
    local result = view.result or {}
    local data = result.data or {}
    local entries = data.entries or {}
    local positions = {}
    local lines = { translated(i18n, "journal.title", "Journal · {unit}", {
        unit = data.unit or view.unit or "—",
    }), "" }
    local function add(key, fallback, value)
        lines[#lines + 1] = translated(i18n, key, fallback) .. ": " .. tostring(value or "—")
    end
    local function priority(entry)
        return entry.priority ~= nil and translated(i18n, "journal.priority_" .. entry.priority,
            tostring(entry.priority)) or "—"
    end
    local function message(entry)
        if entry.message ~= nil then return entry.message end
        if entry.message_kind == "binary_or_multiple" then
            return translated(i18n, "journal.message_binary", "Message is binary or has several values")
        end
        return translated(i18n, "journal.message_unavailable", "Message text is unavailable")
    end
    add("inspector.status", "Status", Technical.state(i18n, result.status or "unavailable"))
    add("inspector.quality", "Quality", Technical.state(i18n, result.quality or "unavailable"))
    if result.reason then add("inspector.reason", "Reason", Technical.reason(i18n, result.reason)) end
    add("systemd.manager", "Manager", (data.manager or view.manager) == "user"
        and translated(i18n, "systemd.manager_user", "current user")
        or translated(i18n, "systemd.manager_system", "system"))
    lines[#lines + 1] = translated(i18n, "journal.scope",
        "Current boot · newest first · at most {count} entries", { count = data.max_entries or 100 })
    if type(now_ns) == "number" and type(result.timestamp_ns) == "number" then
        add("systemd.sample_age", "Sample age", format_value(math.max(0, now_ns - result.timestamp_ns), i18n, "nanoseconds"))
    end
    lines[#lines + 1] = ""
    local entry = view.detail and entries[view.index or 1]
    if entry then
        add("journal.time", "Recorded time", journal_time(entry.timestamp_us))
        add("journal.priority", "Priority", priority(entry))
        add("journal.sender_pid", "Recorded sender PID", entry.pid)
        add("journal.sender_uid", "Recorded sender UID", entry.uid)
        add("journal.identifier", "Identifier", inspector_text(entry.identifier or "—", 128))
        add("systemd.unit", "Unit", entry.unit)
        add("journal.relation", "Relation", translated(i18n, "journal.relation_" .. entry.relation, entry.relation))
        add("inspector.quality", "Quality", Technical.state(i18n, entry.quality))
        lines[#lines + 1] = ""
        for line in (message(entry) .. "\n"):gmatch("(.-)\n") do
            lines[#lines + 1] = line
        end
        if entry.message_truncated then
            lines[#lines + 1] = translated(i18n, "journal.message_truncated", "Message text was truncated")
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "journal.history_note",
            "This is historical journal data; its PID is not a current process identity.")
    elseif result.status == "ok" and #entries == 0 then
        lines[#lines + 1] = translated(i18n, "journal.empty", "No accessible entries in this query")
    else
        for index, item in ipairs(entries) do
            if index > 100 then break end
            positions[index] = #lines + 1
            local mark = index == (view.index or 1) and (unicode and "▸ " or "> ") or "  "
            lines[#lines + 1] = mark .. journal_time(item.timestamp_us) .. " · " .. priority(item)
                .. " · " .. translated(i18n, "journal.relation_" .. item.relation, item.relation)
            lines[#lines + 1] = "    " .. inspector_text(message(item):gsub("\n", " / "), 128)
        end
    end
    add("metrics.source", "Source", result.source)
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, view.detail and "journal.detail_hint" or "journal.list_hint",
        view.detail and "s summary · r refresh · Esc/Enter list" or "Up/Down select · Enter message · s summary · r refresh · Esc unit")
    return lines, positions
end

local function session_lines(view, i18n, now_ns)
    view = type(view) == "table" and view or {}
    local result = view.result or {}
    local fields = result.entity and result.entity.summary or {}
    local lines = { translated(i18n, "session.title", "Login session") .. " · "
        .. tostring(view.entity and view.entity.session_id or "—"), "" }
    local function add(key, fallback, value)
        if type(value) == "boolean" then
            value = translated(i18n, value and "ui.yes" or "ui.no", value and "yes" or "no")
        end
        lines[#lines + 1] = translated(i18n, key, fallback) .. ": " .. inspector_text(value or "—", 512)
    end
    add("inspector.status", "Status", Technical.state(i18n, result.status or "unavailable"))
    add("inspector.quality", "Quality", Technical.state(i18n, result.quality or "unavailable"))
    if result.reason then add("inspector.reason", "Reason", Technical.reason(i18n, result.reason)) end
    for _, row in ipairs({
        { "session_id", "session.id", "Session ID" },
        { "user", "process.details_user", "User" },
        { "uid", "session.uid", "UID" },
        { "login_time", "session.created", "Created" },
        { "service", "session.service", "PAM service" },
        { "session_type", "session.type", "Session type" },
        { "class", "session.class", "Session class" },
        { "state", "session.state", "Session state" },
        { "active", "session.active", "Active" },
        { "remote", "session.remote", "Remote login" },
        { "seat", "session.seat", "Seat" },
        { "tty", "session.tty", "TTY" },
        { "leader_pid", "session.leader", "Session leader PID" },
        { "scope", "session.scope", "Session scope" },
        { "idle_hint", "session.idle_hint", "Idle hint" },
    }) do
        local field = fields[row[1]]
        if field then add(row[2], row[3], field.value) end
    end
    if type(now_ns) == "number" and type(result.timestamp_ns) == "number" then
        add("systemd.sample_age", "Sample age", format_value(math.max(0, now_ns - result.timestamp_ns), i18n, "nanoseconds"))
    end
    add("metrics.source", "Source", result.source)
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "session.note",
        "logind login sessions; PAM service names do not identify a daemon instance. Idle is a hint.")
    lines[#lines + 1] = translated(i18n, "session.hint", "d scope unit · r refresh · Esc/Enter back")
    return lines
end

local SENSOR_DETAIL_LIMIT = 256

local function power_detail_lines(snapshot, i18n)
    local zones, gpus, total = ViewModel.power_detail_rows(snapshot, i18n)
    local supplies = ViewModel.supply_input_rows(snapshot, i18n)
    local lines = {
        translated(i18n, "power.title", "Power and limits"),
        translated(i18n, "inspector.close_hint", "Esc/Enter closes"),
        "",
        translated(i18n, "power.comparison_note", "Sample / configured cap; this does not indicate throttling."),
    }
    if snapshot.power and (snapshot.power.denied_zones or 0) > 0 then
        lines[#lines + 1] = translated(i18n, "power.denied_note", "Power readings need root (--sudo).")
    end
    local function field(id, label, value)
        lines[#lines + 1] = inspector_text("  " .. translated(i18n, id, label)
            .. ": " .. tostring(value or "—"), INSPECTOR_ROW_WIDTH)
    end
    local coverage = ViewModel.cpu_limit_coverage_text(snapshot, i18n)
    if coverage then lines[#lines + 1] = inspector_text(coverage, INSPECTOR_ROW_WIDTH) end
    local limit_rows, limits_total = ViewModel.performance_limit_rows(snapshot, i18n)
    for index = 1, math.min(#limit_rows, 4) do
        local row = limit_rows[index]
        lines[#lines + 1] = inspector_text(row.name .. ": " .. row.current
            .. " · " .. Technical.state(i18n, row.quality), INSPECTOR_ROW_WIDTH)
    end
    if snapshot.cpu_limits and (snapshot.cpu_limits.denied_domains or 0) > 0 then
        lines[#lines + 1] = translated(i18n, "limits.denied_note", "CPU limit status needs root and the msr driver.")
    end
    local previous
    for _, row in ipairs(zones) do
        local identity = row.zone_id or (row.domain .. ":" .. row.zone)
        if identity ~= previous then
            lines[#lines + 1] = ""
            lines[#lines + 1] = inspector_text(row.zone .. " [" .. identity .. "]", INSPECTOR_ROW_WIDTH)
            if row.scope then field("limits.scope", "Scope", row.scope) end
            if row.domain_kind == "graphics" then
                lines[#lines + 1] = translated(i18n, "power.rapl_graphics_note",
                    "RAPL graphics-domain reading; PCI adapter ownership is unknown.")
            end
            field("metrics.source", "Source", row.domain .. " · " .. row.source)
            if row.power_source_path then field("metrics.source", "Source", row.power_source_path) end
            field("metrics.power", "Power", row.power .. " · "
                .. translated(i18n, "power.interval", "Sample window") .. ": " .. row.interval)
            if row.power_age_ns ~= nil then
                field("systemd.sample_age", "Sample age", format_value(row.power_age_ns, i18n, "nanoseconds"))
            end
            field("power.controls", "Controls", Technical.state(i18n, row.controls)
                .. " · " .. Technical.state(i18n, row.state))
            for _, issue in ipairs(row.power_reading_issues or {}) do
                local energy = issue.field == "energy"
                field("inspector.reason", "Reason", translated(i18n,
                    energy and "metrics.energy" or "metrics.power", energy and "Energy" or "Power")
                    .. ": " .. tostring(Technical.state(i18n, issue.status)))
                if issue.source then field("metrics.source", "Source", issue.source) end
            end
            local session = row.power_session
            if session then
                field("sensor.session_range", "Session min / avg / max",
                    format_value(session.minimum_watts, i18n, "watts") .. " / "
                    .. format_value(session.average_watts, i18n, "watts") .. " / "
                    .. format_value(session.maximum_watts, i18n, "watts"))
                local weighted = session.average_kind == "time_weighted"
                field("power.session_average", "Average method", translated(i18n,
                    weighted and "power.session_weighted" or "power.session_sampled",
                    weighted and "Time-weighted" or "By sample count"))
                field("power.session_samples", "Accepted readings", session.samples)
                if weighted then
                    field("power.session_coverage", "Observed time",
                        format_value(session.covered_time_ns / 1e9, i18n, "seconds"))
                    field("power.session_energy", "Observed energy",
                        format_value(session.energy_joules, i18n, "joules"))
                    lines[#lines + 1] = translated(i18n, "power.session_window_note",
                        "Energy-derived minima and maxima are sample-window averages.")
                end
                if snapshot.timestamp_ns then
                    field("power.session_last", "Last accepted reading",
                        format_value((snapshot.timestamp_ns - session.last_timestamp_ns) / 1e9, i18n, "seconds"))
                end
                lines[#lines + 1] = translated(i18n, "power.session_note",
                    "Current reader session; gaps are excluded.")
            end
            previous = identity
        end
        lines[#lines + 1] = inspector_text("  " .. row.constraint .. ": " .. row.limit
            .. " · " .. translated(i18n, "power.window", "Cap window") .. ": " .. row.window,
            INSPECTOR_ROW_WIDTH)
        field("power.of_limit", "% of cap", row.usage .. " · "
            .. translated(i18n, "power.headroom", "To cap") .. ": " .. row.headroom)
    end
    for _, row in ipairs(gpus) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = inspector_text("GPU " .. row.card .. " · " .. row.gpu, INSPECTOR_ROW_WIDTH)
        field("metrics.power", "Power", row.power)
        if row.hotspot_temperature then field("gpu.hotspot_temperature", "Hotspot temperature", row.hotspot_temperature) end
        if row.graphics_voltage then field("gpu.graphics_voltage", "GPU voltage", row.graphics_voltage) end
        if row.power_scope then field("limits.scope", "Scope", row.power_scope) end
        if row.power_age_ns then
            field("systemd.sample_age", "Sample age", format_value(row.power_age_ns, i18n, "nanoseconds"))
        end
        if row.power_reason then field("inspector.reason", "Reason", Technical.reason(i18n,row.power_reason)) end
        if row.power_measurement then field("power.measurement", "Measurement", row.power_measurement) end
        if type(row.power_interval_ns) == "number" and row.power_interval_ns > 0 then
            field("power.interval", "Sample window", format_value(row.power_interval_ns / 1e9, i18n, "seconds"))
        end
        if not row.sensor_power or #(row.sensor_power.limits or {}) == 0 then
            field("power.limit", "Power cap", row.power_limit)
            field("power.of_limit", "% of cap", row.power_usage)
        end
        field("metrics.source", "Source", row.power_budget_source)
        if row.sensor_power then
            local stats = row.sensor_power.power_session
            if stats then
                field("sensor.session_range", "Session min / avg / max", format_value(stats.minimum_watts,i18n,"watts")
                    .. " / " .. format_value(stats.average_watts,i18n,"watts") .. " / " .. format_value(stats.maximum_watts,i18n,"watts"))
                local weighted = stats.average_kind == "time_weighted"
                field("power.session_average", "Average method", translated(i18n,
                    weighted and "power.session_weighted" or "power.session_sampled",
                    weighted and "Time-weighted" or "By sample count"))
                field("power.session_samples", "Accepted readings", stats.samples)
                if weighted then
                    field("power.session_coverage", "Observed time", format_value(stats.covered_time_ns / 1e9,i18n,"seconds"))
                    field("power.session_energy", "Observed energy", format_value(stats.energy_joules,i18n,"joules"))
                end
            end
            if row.sensor_power.interval_uncertainty_ns then
                field("cpu_clock.uncertainty", "Interval uncertainty", format_value(row.sensor_power.interval_uncertainty_ns,i18n,"nanoseconds"))
            end
            for _, cap in ipairs(row.sensor_power.limits or {}) do
                local kind = cap.id == "long_term" and "PL1" or "PL2"
                field("power.limit", "Power cap", kind .. " · " .. format_value(cap.power_limit_watts, i18n, "watts")
                    .. " · " .. (cap.enabled and cap.usage or Technical.state(i18n,"disabled")))
                if cap.headroom_watts then field("power.headroom", "To cap", format_value(cap.headroom_watts, i18n, "watts")) end
                if cap.window_ns then field("power.window", "Cap window", format_value(cap.window_ns / 1e9, i18n, "seconds")) end
                field("metrics.source", "Source", cap.source)
            end
            if stats then lines[#lines + 1] = translated(i18n,"power.session_note","Current reader session; gaps are excluded.") end
        end
        if #(row.power_sessions or {}) > 0 then
            lines[#lines + 1] = translated(i18n, "power.api_statistics", "API power statistics")
            local labels = { power_watts = {"power.reading.reported", "Reported power"},
                power_instant_watts = {"power.reading.instant", "Instantaneous power"},
                power_average_watts = {"power.reading.average", "Driver average power"},
                board_power_watts = {"power.reading.board", "Board power"} }
            local brands = { nvml = "NVML", amdsmi = "AMD SMI", levelzero = "Level Zero", adl = "AMD ADL" }
            for _, session in ipairs(row.power_sessions) do
                local label = labels[session.metric]
                lines[#lines + 1] = "  " .. brands[session.source] .. " · " .. translated(i18n, label[1], label[2])
                field("metrics.power", "Power", format_value(session.current_watts, i18n, "watts"))
                field("sensor.session_range", "Session min / avg / max",
                    format_value(session.minimum_watts, i18n, "watts") .. " / "
                    .. format_value(session.average_watts, i18n, "watts") .. " / "
                    .. format_value(session.maximum_watts, i18n, "watts"))
                field("power.session_average", "Average method", translated(i18n, "power.session_sampled", "By sample count"))
                field("power.session_samples", "Accepted readings", session.samples)
                field("inspector.quality", "Quality", Technical.state(i18n, session.quality))
                local scopes = { asic={"power.scope.asic","GPU chip (ASIC)"}, card={"power.scope.card","Card"},
                    package={"power.scope.package","Package"}, stack={"power.scope.stack","Stack"}, memory={"metrics.memory","Memory"} }
                local scope = scopes[session.scope]
                field("limits.scope", "Scope", scope and translated(i18n, scope[1], scope[2])
                    or session.scope == "gpu" and "GPU" or Technical.state(i18n, "unknown"))
                if ({ current=true, average=true, device_sample=true, driver_snapshot=true })[session.measurement] then
                    field("power.measurement", "Measurement", translated(i18n, "power.measurement." .. session.measurement, session.measurement))
                end
                local basis = session.sample_time_basis == "provider_timestamp"
                field("metrics.source", "Source", translated(i18n,
                    basis and "power.sample.provider_timestamp" or "power.sample.query_capture",
                    basis and "Provider timestamp" or "Query capture time"))
                if session.minimum_interval_ns then
                    field("power.interval", "Sample window", format_value(session.minimum_interval_ns / 1e9, i18n, "seconds")
                        .. " / " .. format_value(session.maximum_interval_ns / 1e9, i18n, "seconds"))
                end
                if snapshot.timestamp_ns then
                    field("power.session_last", "Last accepted reading",
                        format_value((snapshot.timestamp_ns - session.last_timestamp_ns) / 1e9, i18n, "seconds"))
                end
            end
            lines[#lines + 1] = translated(i18n, "power.api_sample_note", "Statistics summarize accepted API readings.")
            lines[#lines + 1] = translated(i18n, "power.api_average_note", "Driver averages may overlap; no energy is integrated.")
        end
    end
    if #supplies > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "supply_input.title", "External power supplies")
        lines[#lines + 1] = translated(i18n, "supply_input.note",
            "Programmable voltage/current are settings; limits describe this input.")
        lines[#lines + 1] = translated(i18n, "supply_input.comparison_note",
            "Input reading / configured input cap; not CPU or outlet power.")
    end
    for _, row in ipairs(supplies) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = inspector_text(tostring(row.name or row.id) .. " ["
            .. Technical.state(i18n, row.quality) .. "]", INSPECTOR_ROW_WIDTH)
        local state = row.online == nil and translated(i18n, "system.unknown", "unknown")
            or row.online == false and translated(i18n, "system.offline", "offline")
            or row.online_mode == "programmable" and translated(i18n, "system.online_programmable", "online (programmable)")
            or translated(i18n, "system.online", "online")
        field("inspector.status", "Status", state)
        if row.scope then field("limits.scope", "Scope", row.scope) end
        if row.usb_type then field("supply_input.usb_type", "USB mode", row.usb_type) end
        if #row.usb_types > 0 then
            field("supply_input.usb_types", "Supported USB modes", table.concat(row.usb_types, ", "))
        end
        field("supply_input.voltage", "Reported/set voltage", format_value(row.voltage_volts, i18n, "volts"))
        field("supply_input.current", "Reported/set current", format_value(row.current_amperes, i18n, "amperes"))
        if row.minimum_voltage_volts ~= nil or row.maximum_voltage_volts ~= nil then
            field("supply_input.voltage_range", "Supported voltage range",
                format_value(row.minimum_voltage_volts, i18n, "volts") .. " / "
                .. format_value(row.maximum_voltage_volts, i18n, "volts"))
        end
        if row.maximum_current_amperes ~= nil then
            field("supply_input.current_max", "Supported current maximum", format_value(row.maximum_current_amperes, i18n, "amperes"))
        end
        for _, item in ipairs({
            { "input_voltage_limit_volts", "supply_input.input_voltage_limit", "Configured input voltage limit", "volts" },
            { "input_current_limit_amperes", "supply_input.input_current_limit", "Configured input current limit", "amperes" },
            { "input_power_limit_watts", "supply_input.input_power_limit", "Configured input power limit", "watts" },
        }) do
            if row[item[1]] ~= nil then field(item[2], item[3], format_value(row[item[1]], i18n, item[4])) end
        end
        if row.power_watts ~= nil then field("metrics.power", "Power", format_value(row.power_watts, i18n, "watts")) end
        if row.input_power_limit_watts ~= nil then field("power.of_limit", "% of cap", row.usage) end
        field("metrics.source", "Source", row.source)
        local keys = {}; for key in pairs(row.errors) do keys[#keys + 1] = key end; table.sort(keys)
        for _, key in ipairs(keys) do
            local issue = row.errors[key]
            field("inspector.reason", "Reason", key .. ": " .. Technical.state(i18n, issue.status))
            field("metrics.source", "Source", issue.source)
        end
    end
    local has_history = false
    for _, row in ipairs(limit_rows) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = inspector_text(row.name, INSPECTOR_ROW_WIDTH)
        if row.current_items and #row.current_items > 1 then
            field("limits.current", "Current limits", row.current_items[1])
            for index = 2, #row.current_items do
                lines[#lines + 1] = inspector_text("    " .. row.current_items[index], INSPECTOR_ROW_WIDTH)
            end
        else
            field("limits.current", "Current limits", row.current)
        end
        field("limits.scope", "Scope", row.scope .. " · " .. Technical.state(i18n, row.quality))
        field("metrics.source", "Source", row.source)
        if row.raw_hex then field("limits.raw", "Raw flags", row.raw_hex) end
        if row.supported_hex then field("limits.supported", "Supported flags", row.supported_hex) end
        if row.recorded then
            has_history = true
            field("limits.recorded", "Recorded flags", row.recorded)
        end
    end
    if has_history then
        lines[#lines + 1] = translated(i18n, "limits.history_note",
            "Recorded flags remain until cleared; the clear time is unknown.")
    end
    if limits_total > #limit_rows then
        lines[#lines + 1] = translated(i18n, "ui.rows_capped", "showing {visible} of {total}",
            { visible = #limit_rows, total = limits_total })
    end
    if total > #zones then
        lines[#lines + 1] = translated(i18n, "ui.rows_capped", "showing {visible} of {total}",
            { visible = #zones, total = total })
    elseif #zones == 0 and #gpus == 0 and #limit_rows == 0 and #supplies == 0 then
        lines[#lines + 1] = translated(i18n, "ui.no_data", "No data")
    end
    return lines
end

local function sensor_detail_lines(snapshot, i18n, now_ns)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local data = type(snapshot.sensors) == "table" and snapshot.sensors or {}
    local devices = type(data.devices) == "table" and data.devices or {}
    local quality = type(snapshot.quality) == "table" and snapshot.quality.sensors
    local state = type(quality) == "table" and quality or {}
    local age_ns = type(now_ns) == "number" and type(state.value_timestamp_ns) == "number"
        and math.max(0, now_ns - state.value_timestamp_ns) or nil
    local stale_sample = not Thermal.current(snapshot, now_ns)
    local shown_quality = state.quality or data.quality or "unavailable"
    if stale_sample
        and (shown_quality == "fresh" or shown_quality == "estimated") then
        shown_quality = "stale"
    end
    local title = translated(i18n, "widgets.sensors", "Sensors")
    local lines = {
        title, "",
        translated(i18n, "inspector.status", "Status") .. ": "
            .. tostring(Technical.state(i18n,
                state.status or (#devices > 0 and "ok" or "unavailable"))),
        translated(i18n, "inspector.quality", "Quality") .. ": "
            .. tostring(Technical.state(i18n, shown_quality)),
    }
    if stale_sample and age_ns and age_ns > Thermal.STALE_AFTER_NS and #devices > 0 then
        lines[#lines + 1] = translated(i18n, "collector.stale",
            "{name} has not updated for {age}", {
                name = title, age = format_value(age_ns / 1000000000, i18n, "seconds"),
            })
    end
    if state.reason then
        lines[#lines + 1] = translated(i18n, "inspector.reason", "Reason")
            .. ": " .. inspector_text(Technical.reason(i18n, state.reason),
                INSPECTOR_ROW_WIDTH)
    end
    local total, sensor_total, control_total = 0, 0, 0
    for _, device in ipairs(devices) do
        sensor_total = sensor_total + #(device.channels or {})
        control_total = control_total + #(device.fan_controls or {})
    end
    total = sensor_total + control_total
    lines[#lines + 1] = translated(i18n, "metrics.sensor", "Sensor") .. ": " .. sensor_total
    if control_total > 0 then
        lines[#lines + 1] = translated(i18n, "fan_control.title", "Fan control settings") .. ": " .. control_total
    end
    if total == 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "ui.no_data", "No data")
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
        return lines
    end

    local closest = Thermal.closest(snapshot, 3, now_ns)
    if #closest > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "sensor.closest_critical", "Closest to critical")
        for _, thermal in ipairs(closest) do
            local device, channel = thermal.device, thermal.channel
            local margin = i18n and i18n.format and i18n.format:temperature_delta(
                thermal.headroom_celsius, { precision = 1 }) or "—"
            lines[#lines + 1] = inspector_text("  "
                .. (device.name or device.class or "?") .. "/"
                .. (channel.label or channel.id or "?") .. ": "
                .. format_value(channel.input, i18n, "celsius") .. " · "
                .. translated(i18n, "sensor.critical", "Critical") .. ": "
                .. format_value(thermal.critical_celsius, i18n, "celsius") .. " · "
                .. translated(i18n, "sensor.headroom", "To critical") .. ": "
                .. margin, INSPECTOR_ROW_WIDTH)
        end
    end

    local function add_values(values, unit, skip_input)
        if type(values) ~= "table" then return end
        local keys = {}
        for key, value in pairs(values) do
            if (not skip_input or key ~= "input") and type(value) == "number" then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        if #keys == 0 then return end
        for first = 1, #keys, 4 do
            local parts = {}
            for index = first, math.min(first + 3, #keys) do
                local key = keys[index]
                parts[#parts + 1] = key .. "=" .. format_value(values[key], i18n, unit)
            end
            lines[#lines + 1] = inspector_text("    " .. table.concat(parts, "  "),
                INSPECTOR_ROW_WIDTH)
        end
    end

    local shown = 0
    -- Which GPU row, if any, took its figures from this hwmon device, and
    -- which channel each one was.  The GPU table's numbers are only honest
    -- while the reader can see that a watt figure may be one rail rather than
    -- a board total, so the account lives next to the channels themselves.
    local gpu_claims = {}
    for _, entry in ipairs(ViewModel.gpu_sensor_join(snapshot)) do
        gpu_claims[entry.sensor] = gpu_claims[entry.sensor] or {}
        gpu_claims[entry.sensor][#gpu_claims[entry.sensor] + 1] = entry
    end
    -- The same account for disks: the storage table's temperature column is
    -- only a claim about which device owns the reading, and the claim is
    -- stated here with the model and the mount point so a reader can tell
    -- two nameless sensors apart by what they are bolted to.
    local disk_claims = {}
    for _, entry in ipairs(ViewModel.disk_sensor_join(snapshot)) do
        disk_claims[entry.sensor] = disk_claims[entry.sensor] or {}
        disk_claims[entry.sensor][#disk_claims[entry.sensor] + 1] = entry
    end
    local disk_mounts = ViewModel.disk_mount_join(snapshot)
    for _, device in ipairs(devices) do
        if shown >= SENSOR_DETAIL_LIMIT then break end
        if #(device.channels or {}) > 0 or #(device.fan_controls or {}) > 0 then
            local device_quality = device.quality or "unavailable"
            if stale_sample and (device_quality == "fresh" or device_quality == "estimated") then
                device_quality = "stale"
            end
            lines[#lines + 1] = ""
            lines[#lines + 1] = inspector_text(
                inspector_text(device.name or device.class or "?", 80) .. "  ["
                    .. Technical.state(i18n, device_quality) .. "]  "
                    .. inspector_text(device.source or "", 64), INSPECTOR_ROW_WIDTH)
            for _, entry in ipairs(disk_claims[device] or {}) do
                local parts = {}
                local identity = type(entry.disk.identity) == "table"
                    and entry.disk.identity or {}
                if type(identity.model) == "string" and identity.model ~= "" then
                    parts[#parts + 1] = identity.model
                end
                local mount_point = disk_mounts[entry.disk.name]
                if mount_point then
                    parts[#parts + 1] = translated(i18n, "sensor.mounted_at",
                        "mounted at {path}", { path = mount_point })
                end
                lines[#lines + 1] = inspector_text(
                    "  " .. translated(i18n, "sensor.disk_claim",
                        "Disk {disk} ({detail}) reads this device:",
                        { disk = tostring(entry.disk.name or "?"),
                          detail = #parts > 0 and table.concat(parts, " · ") or "?" }),
                    INSPECTOR_ROW_WIDTH)
                if entry.temperature then
                    lines[#lines + 1] = inspector_text(
                        "    " .. translated(i18n, "metrics.temperature", "Temp")
                            .. " ← " .. (entry.temperature.label
                                or (tostring(entry.temperature.type or "sensor")
                                    .. " " .. tostring(entry.temperature.index))),
                        INSPECTOR_ROW_WIDTH)
                end
            end
            for _, entry in ipairs(gpu_claims[device] or {}) do
                lines[#lines + 1] = inspector_text(
                    "  " .. translated(i18n, "sensor.gpu_claim", "GPU {card} reads this device:",
                        { card = tostring(entry.gpu.card or entry.gpu.id or "?") }),
                    INSPECTOR_ROW_WIDTH)
                local parts = {}
                for _, claim in ipairs({
                    { entry.temperature, translated(i18n, "metrics.temperature", "Temp") },
                    { entry.power, translated(i18n, "metrics.power", "Power") },
                    { entry.fan, translated(i18n, "metrics.fan", "Fan") },
                }) do
                    if claim[1] then
                        parts[#parts + 1] = claim[2] .. " ← "
                            .. (claim[1].label or (claim[1].type .. " " .. tostring(claim[1].index)))
                    end
                end
                for _, part in ipairs(parts) do
                    lines[#lines + 1] = inspector_text("    " .. part, INSPECTOR_ROW_WIDTH)
                end
                if entry.power_channels > 1 then
                    -- The rule, stated where the numbers are: a device with
                    -- several power channels publishes overlapping domains, so
                    -- the table shows the largest and never their sum.
                    lines[#lines + 1] = inspector_text("    "
                        .. translated(i18n, "sensor.power_channels",
                            "{count} power channels overlap; the largest is shown, never their sum",
                            { count = entry.power_channels }),
                        INSPECTOR_ROW_WIDTH)
                end
            end
        end
        for _, channel in ipairs(device.channels or {}) do
            if shown >= SENSOR_DETAIL_LIMIT then break end
            shown = shown + 1
            local name = channel.label or (tostring(channel.type or "sensor")
                .. " " .. tostring(channel.index or shown))
            local status = channel.fault and "FAULT" or channel.alarm and "ALARM"
                or channel.quality or "unavailable"
            if stale_sample then
                if status == "fresh" or status == "estimated" then status = "stale"
                elseif status == "FAULT" or status == "ALARM" then
                    status = status .. "/stale"
                end
            end
            lines[#lines + 1] = inspector_text("  " .. inspector_text(name, 80) .. ": "
                .. format_value(channel.input, i18n, channel.unit) .. "  ["
                .. Technical.state(i18n, status) .. "]", INSPECTOR_ROW_WIDTH)
            add_values(channel.readings, channel.unit, true)
            add_values(channel.thresholds, channel.unit, false)
            local power = SensorPower.public(channel, now_ns or snapshot.timestamp_ns, quality)
            if power then
                local measurement = power.measurement or "energy_delta"
                lines[#lines + 1] = "    " .. translated(i18n,"power.measurement."..measurement,
                    measurement == "current" and "Instantaneous" or measurement == "average" and "Average" or "Energy-window average")
                    .. ": " .. format_value(power.power_watts,i18n,"watts") .. " [" .. Technical.state(i18n,power.power_quality) .. "]"
                if power.scope then
                    lines[#lines + 1] = "    " .. translated(i18n,"limits.scope","Scope") .. ": "
                        .. translated(i18n,power.scope == "gpu_gt" and "limits.scope.gpu_gt" or "power.scope."..power.scope,power.scope)
                end
                for _, cap in ipairs(power.limits or {}) do
                    local usage = cap.percent and i18n.format:percent(cap.percent,{precision=1}) or "—"
                    lines[#lines + 1] = "    " .. (cap.id=="long_term" and "PL1" or "PL2") .. ": "
                        .. format_value(cap.power_limit_watts,i18n,"watts") .. " · "
                        .. (cap.enabled and usage or Technical.state(i18n,"disabled"))
                    if cap.headroom_watts then
                        lines[#lines + 1] = "    " .. translated(i18n,"power.headroom","To cap") .. ": "
                            .. format_value(cap.headroom_watts,i18n,"watts")
                    end
                end
                if power.power_interval_ns then
                    lines[#lines + 1] = "    " .. translated(i18n,"power.interval","Sample window") .. ": "
                        .. format_value(power.power_interval_ns / 1e9,i18n,"seconds")
                    if power.interval_uncertainty_ns then
                        lines[#lines + 1] = "    " .. translated(i18n,"cpu_clock.uncertainty","Interval uncertainty") .. ": "
                            .. format_value(power.interval_uncertainty_ns,i18n,"nanoseconds")
                    end
                end
                local stats = power.power_session
                if stats then
                    lines[#lines + 1] = "    " .. translated(i18n,"sensor.session_range","Session min / avg / max") .. ": "
                        .. format_value(stats.minimum_watts,i18n,"watts") .. " / " .. format_value(stats.average_watts,i18n,"watts")
                        .. " / " .. format_value(stats.maximum_watts,i18n,"watts")
                    lines[#lines + 1] = "    " .. translated(i18n,
                        stats.average_kind == "time_weighted" and "power.session_weighted" or "power.session_sampled",
                        stats.average_kind == "time_weighted" and "Time-weighted" or "By sample count") .. " · "
                        .. translated(i18n,"power.session_samples","Accepted readings") .. ": " .. stats.samples
                end
                lines[#lines + 1] = inspector_text("    " .. translated(i18n,"metrics.source","Source") .. ": " .. power.source,INSPECTOR_ROW_WIDTH)
            end
            local thermal = Thermal.channel(snapshot, device, channel, now_ns)
            if thermal then
                local margin = "—"
                if thermal.headroom_celsius ~= nil then
                    local ok, value = pcall(function()
                        return i18n.format:temperature_delta(thermal.headroom_celsius,
                            { precision = 1 })
                    end)
                    if ok and type(value) == "string" then margin = value end
                end
                lines[#lines + 1] = inspector_text("    "
                    .. translated(i18n, "sensor.critical", "Critical") .. ": "
                    .. format_value(thermal.critical_celsius, i18n, "celsius")
                    .. " · " .. translated(i18n, "sensor.headroom", "To critical")
                    .. ": " .. margin, INSPECTOR_ROW_WIDTH)
            end
            local session = type(channel.session) == "table" and channel.session or nil
            if session and type(session.samples) == "number"
                and type(session.minimum) == "number"
                and type(session.maximum) == "number"
                and type(session.average) == "number" then
                lines[#lines + 1] = inspector_text("    "
                    .. translated(i18n, "sensor.session_range",
                        "Session min / avg / max") .. ": "
                    .. format_value(session.minimum, i18n, channel.unit) .. " / "
                    .. format_value(session.average, i18n, channel.unit) .. " / "
                    .. format_value(session.maximum, i18n, channel.unit),
                    INSPECTOR_ROW_WIDTH)
                lines[#lines + 1] = inspector_text("    "
                    .. translated(i18n, "sensor.session_samples", "Direct samples")
                    .. ": " .. tostring(session.samples), INSPECTOR_ROW_WIDTH)
                if type(now_ns) == "number"
                    and type(session.last_timestamp_ns) == "number" then
                    lines[#lines + 1] = inspector_text("    "
                        .. translated(i18n, "sensor.session_last",
                            "Last direct sample") .. ": "
                        .. format_value(math.max(0,
                            now_ns - session.last_timestamp_ns) / 1000000000,
                            i18n, "seconds"), INSPECTOR_ROW_WIDTH)
                end
            end
        end
        if #(device.fan_controls or {}) > 0 and shown < SENSOR_DETAIL_LIMIT then
            lines[#lines + 1] = "  " .. translated(i18n, "fan_control.title", "Fan control settings")
            lines[#lines + 1] = inspector_text("    " .. translated(i18n, "fan_control.note",
                "Driver settings; applied output and fan RPM are not verified."), INSPECTOR_ROW_WIDTH)
            for index, control in ipairs(device.fan_controls) do
                if index > FanControl.MAX_CONTROLS or shown >= SENSOR_DETAIL_LIMIT then break end
                shown = shown + 1
                local row = FanControl.public(snapshot, device, control, now_ns)
                local value = "—"
                if row.setting_percent ~= nil then
                    local filled = math.floor(row.setting_percent * 8 / 100 + 0.5)
                    if row.setting_percent > 0 then filled = math.max(1, filled) end
                    value = "[" .. string.rep("#", filled) .. string.rep("-", 8 - filled) .. "] "
                        .. i18n.format:percent(row.setting_percent, { precision = 1 })
                end
                lines[#lines + 1] = "    " .. tostring(row.id) .. ": " .. value
                    .. "  [" .. Technical.state(i18n, row.quality) .. "]"
                local function setting(key, fallback, value)
                    lines[#lines + 1] = inspector_text("      " .. translated(i18n, key, fallback)
                        .. ": " .. tostring(value or "—"), INSPECTOR_ROW_WIDTH)
                end
                setting("fan_control.raw", "Raw control value", row.raw_value)
                local method = row.control_method
                    and translated(i18n, "fan_control.method." .. row.control_method, row.control_method) or "—"
                if row.enable_code ~= nil then method = method .. " (" .. row.enable_code .. ")" end
                setting("fan_control.method", "Control method", method)
                local mode = row.output_mode
                    and translated(i18n, "fan_control.mode." .. row.output_mode, row.output_mode) or "—"
                if row.output_mode_code ~= nil then mode = mode .. " (" .. row.output_mode_code .. ")" end
                setting("fan_control.output_mode", "Output mode", mode)
                setting("fan_control.frequency", "Base PWM frequency", format_value(row.frequency_hz, i18n, "hertz"))
                local temperatures = {}
                for _, input in ipairs(row.temperature_inputs) do temperatures[#temperatures + 1] = "temp" .. input end
                for first = 1, #temperatures, 6 do
                    local group = {}
                    for position = first, math.min(first + 5, #temperatures) do group[#group + 1] = temperatures[position] end
                    setting("fan_control.temperatures", "Temperature selection", table.concat(group, ", "))
                end
                lines[#lines + 1] = inspector_text("      " .. translated(i18n, "metrics.source", "Source")
                    .. ": " .. tostring(row.source), INSPECTOR_ROW_WIDTH)
            end
        end
    end
    if total > shown then lines[#lines + 1] = "  ... +" .. (total - shown) end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
end

local function detail_formatted(call, fallback)
    local ok, value = pcall(call)
    return ok and value or fallback or "—"
end

local function process_with_io_detail(process)
    if type(process) ~= "table" then return nil end
    if type(process.io_read_bytes) == "number"
        or type(process.io_write_bytes) == "number" then
        return setmetatable({
            io = {
                read_bytes = process.io_read_bytes,
                write_bytes = process.io_write_bytes,
                source = "SystemProcessInformation",
            },
        }, { __index = process })
    end
    if type(native.collect_process_io) ~= "function"
        or type(process.pid) ~= "number"
        or type(process.starttime_ticks) ~= "number" then
        return process
    end
    local ok, io, reason = pcall(native.collect_process_io,
        process.pid, process.starttime_ticks)
    if ok and type(io) == "table" then
        return setmetatable({ io = io }, { __index = process })
    end
    local failure = ok and reason or io
    if type(failure) ~= "string" or failure == "" then
        failure = "process_io_unavailable"
    end
    return setmetatable({ io_reason = failure },
        { __index = process })
end

-- One DRM client is one open file on the GPU node, so a process row can hide
-- several of them behind a single PID.  The table aggregates them; these two
-- levels show what the aggregate is made of.
--
-- The detail lists a client's frequency domains separately from its engines
-- rather than folding them in.  The kernel names the two independently --
-- `drm-engine-gfx` against `drm-maxfreq-sclk` on amdgpu, `drm-engine-render`
-- against `drm-maxfreq-rcs0` on i915 -- and gives no field saying which clock an
-- engine runs on, so a domain that happens to share an engine's name is marked
-- as a name match instead of being merged into it.  A clock at its ceiling is a
-- pinned clock, not a busy engine: the share of the ceiling is labelled as
-- exactly that, and never as a utilization.
local function gpu_client_detail_lines(client, i18n)
  local format = i18n and i18n.format
  local function bytes(value)
    if type(value) ~= "number" then return "—" end
    return detail_formatted(function() return assert(format:bytes(value)) end)
  end
  local function percent(value)
    if type(value) ~= "number" then return "—" end
    return detail_formatted(function()
      return assert(format:percent(value, { precision = 1 }))
    end)
  end
  local function frequency(value)
    if type(value) ~= "number" then return nil end
    return detail_formatted(function() return assert(format:frequency(value)) end)
  end

  local heading = translated(i18n, "gpu.client_heading", "Client", {})
  if client.name and client.name ~= "" then heading = heading .. " · " .. client.name end
  local lines = { heading }

  local rows = {}
  if client.client_id then
    rows[#rows + 1] = { translated(i18n, "gpu.client_id", "ID"), tostring(client.client_id) }
  end
  if client.driver and client.driver ~= "" then
    rows[#rows + 1] = { translated(i18n, "gpu.client_driver", "Driver"), client.driver }
  end
  if client.pci_bdf and client.pci_bdf ~= "" then
    rows[#rows + 1] = { translated(i18n, "gpu.client_pci", "PCI"), client.pci_bdf }
  end
  local fds = type(client.fds) == "table" and client.fds or {}
  if #fds > 0 then
    -- The collector records the descriptor number, not the path it resolves
    -- to: a bare "19" is the identity an operator can act on, and claiming a
    -- device node wtop never read would be a guess.
    local shown = {}
    for _, fd in ipairs(fds) do
      if #shown >= 4 then break end
      if type(fd) == "table" then
        shown[#shown + 1] = tostring(fd.path or fd.name or fd.fd or "?")
      else
        shown[#shown + 1] = translated(i18n, "gpu.client_fd", "fd {number}",
          { number = tostring(fd) })
      end
    end
    local value = table.concat(shown, ", ")
    if #fds > #shown then value = value .. " +" .. (#fds - #shown) end
    rows[#rows + 1] = { translated(i18n, "gpu.client_fds", "Files"), value }
  end
  -- "fresh" and "exact" are the good answers; only a guess is worth a line.
  if client.mapping_quality and client.mapping_quality ~= "exact"
      and client.mapping_quality ~= "fresh" then
    rows[#rows + 1] = {
      translated(i18n, "gpu.client_mapping", "Mapping"),
      Technical.state(i18n, client.mapping_quality),
    }
  end
  for _, row in ipairs(aligned_pairs(rows)) do lines[#lines + 1] = row end

  local engines = type(client.engines) == "table" and client.engines or {}
  local engine_names = {}
  for name in pairs(engines) do engine_names[#engine_names + 1] = name end
  if #engine_names > 0 then
    table.sort(engine_names)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  " .. translated(i18n, "gpu.client_engines", "Engines")
    for _, name in ipairs(engine_names) do
      local engine = engines[name]
      local value = percent(engine.utilization_percent)
      if type(engine.capacity) == "number" and engine.capacity ~= 1 then
        value = value .. " / " .. engine.capacity
      end
      if engine.current_frequency_hz then
        local hz = frequency(engine.current_frequency_hz)
        if hz then value = value .. " · " .. hz end
      end
      if engine.rate_quality and engine.rate_quality ~= "fresh" then
        value = value .. " · " .. Technical.state(i18n, engine.rate_quality)
      end
      lines[#lines + 1] = string.format("    %-16s %s", name, value)
    end
  end

  local domains = type(client.frequency_domains) == "table" and client.frequency_domains or {}
  if #domains > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  " .. translated(i18n, "gpu.client_clocks", "Clocks")
    for _, domain in ipairs(domains) do
      local parts = {}
      if domain.current_hz then
        local hz = frequency(domain.current_hz)
        if hz then parts[#parts + 1] = hz end
      end
      if domain.maximum_hz then
        parts[#parts + 1] = translated(i18n, "gpu.client_clock_of_max",
          "of {maximum} max", { maximum = frequency(domain.maximum_hz) or "?" })
      end
      if domain.of_maximum_percent then
        parts[#parts + 1] = percent(domain.of_maximum_percent)
      end
      -- Reported as a name match, because that is all the kernel gives.
      if domain.engine then
        parts[#parts + 1] = translated(i18n, "gpu.client_clock_engine",
          "same name as engine {engine}", { engine = domain.engine })
      end
      if domain.quality == "unavailable" then
        parts[#parts + 1] = Technical.state(i18n, "unavailable")
      end
      lines[#lines + 1] = string.format("    %-16s %s", tostring(domain.id),
        #parts > 0 and table.concat(parts, " · ") or "—")
    end
  end

  local regions = {}
  for category, values in pairs(type(client.memory) == "table" and client.memory or {}) do
    for region, value in pairs(values or {}) do
      regions[region] = true
    end
  end
  local region_names = {}
  for region in pairs(regions) do region_names[#region_names + 1] = region end
  if #region_names > 0 then
    table.sort(region_names)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  " .. translated(i18n, "gpu.client_memory", "Memory regions")
    for _, region in ipairs(region_names) do
      local parts = {}
      for _, category in ipairs({ "total", "resident", "active", "shared", "purgeable" }) do
        local value = client.memory[category] and client.memory[category][region]
        if type(value) == "number" then
          parts[#parts + 1] = translated(i18n, "gpu.client_memory_" .. category, category)
            .. " " .. bytes(value)
        end
      end
      lines[#lines + 1] = string.format("    %-16s %s", tostring(region),
        #parts > 0 and table.concat(parts, "  ") or "—")
    end
  end
  return lines
end

-- The level above it: which of a process's DRM clients to look at.  A process
-- can hold several behind one pid and the table sums them, so this list is the
-- only place the split is visible.  A process with one client skips the level
-- entirely -- there is nothing to choose, and a keypress to reach the only
-- answer is a cost with no return.
local function gpu_client_lines(selection, i18n, unicode)
  if unicode == nil then unicode = true end
  -- The process is named explicitly rather than taken from the table itself:
  -- a selection that lost its process has to be distinguishable from a process
  -- that simply has no clients, and "the table I was handed is the process"
  -- would make those two the same empty answer.
  local process = type(selection) == "table" and selection.process or nil
  local lines = {
    translated(i18n, "gpu.client_title", "GPU clients"), "",
  }
  if not process then
    lines[#lines + 1] = translated(i18n, "gpu.client_gone", "That process is gone")
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
  end
  local clients = type(process.clients) == "table" and process.clients or {}
  if #clients == 0 then
    lines[#lines + 1] = translated(i18n, "gpu.client_none",
        "No DRM client is open for this process right now")
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
  end
  if #clients == 1 then
    for _, line in ipairs(gpu_client_detail_lines(clients[1], i18n)) do
      lines[#lines + 1] = line
    end
  else
    lines[#lines + 1] = translated(i18n, "gpu.client_select_hint",
        "Up/Down selects · Enter inspects · Esc closes")
    lines[#lines + 1] = ""
    local selected = selection.index or 1
    for position, client in ipairs(clients) do
      local label = client.name
      if not label or label == "" then label = client.id or "?" end
      local facts = {}
      if client.client_id then
        facts[#facts + 1] = translated(i18n, "gpu.client_id", "ID")
          .. " " .. tostring(client.client_id)
      end
      local engines = type(client.engines) == "table" and client.engines or {}
      local engine_count = 0
      for _ in pairs(engines) do engine_count = engine_count + 1 end
      if engine_count > 0 then
        facts[#facts + 1] = string.format("%d %s", engine_count,
          translated(i18n, "gpu.client_engines", "Engines"))
      end
      local domain_count = #(type(client.frequency_domains) == "table"
        and client.frequency_domains or {})
      if domain_count > 0 then
        facts[#facts + 1] = string.format("%d %s", domain_count,
          translated(i18n, "gpu.client_clocks", "Clocks"))
      end
      lines[#lines + 1] = string.format("%s %-18s %s",
        position == selected and (unicode and "▸" or ">") or " ",
        tostring(label), table.concat(facts, " · "))
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
  return lines
end

--- A device's own clock domains, side by side.
---
--- The table promotes one clock into a single Frequency cell and, when a device
--- publishes several, says how many it is not showing.  That is enough to stop
--- the cell implying it is the only clock the device has, and not enough to
--- read any of the others: a card driving a graphics clock and a memory clock
--- says so in a count and in an export, but nowhere on screen.  A client has
--- had this view one level down since the DRM drill-down; the device is the
--- level above it, and it is the one that still exists when no client is
--- running at all.
local function gpu_device_clock_detail_lines(device, i18n)
  local format = i18n and i18n.format
  -- A powered-down clock reads 0, and 0 is a state rather than a frequency.
  -- The collector keeps a domain whose *other* fields are still positive, so
  -- the zero has to be turned away here instead of being rendered as 0 Hz.
  local function running(value)
    if type(value) ~= "number" or value ~= value or value <= 0 then return nil end
    return value
  end
  local function percent(value)
    if type(value) ~= "number" then return "—" end
    return detail_formatted(function()
      return assert(format:percent(value, { precision = 1 }))
    end)
  end
  local function frequency(value)
    local hz = running(value)
    if not hz then return nil end
    return detail_formatted(function() return assert(format:frequency(hz)) end)
  end

  local heading = translated(i18n, "metrics.device", "Device")
  if device.model_name and device.model_name ~= "" then
    heading = heading .. " · " .. device.model_name
  end
  local lines = { heading }

  local rows = {}
  if device.vendor_name and device.vendor_name ~= "" then
    rows[#rows + 1] = { translated(i18n, "metrics.vendor", "Vendor"), device.vendor_name }
  end
  if device.driver and device.driver ~= "" then
    rows[#rows + 1] = { translated(i18n, "metrics.driver", "Driver"), device.driver }
  end
  if device.pci_bdf and device.pci_bdf ~= "" then
    rows[#rows + 1] = { translated(i18n, "metrics.pci", "PCI"), device.pci_bdf }
  end
  for _, row in ipairs(aligned_pairs(rows)) do lines[#lines + 1] = row end

  local frequencies = type(device.frequencies) == "table" and device.frequencies or {}
  local domains = type(frequencies.domains) == "table" and frequencies.domains or {}
  lines[#lines + 1] = ""
  if #domains == 0 then
    -- A device that publishes no clock is a fact, not an error: the answer is
    -- that the kernel declines to publish one, and the screen says so rather
    -- than drawing an empty section.
    lines[#lines + 1] = translated(i18n, "gpu.device_no_clocks",
      "This device publishes no clock domain")
    return lines
  end

  local metrics = type(device.metrics) == "table" and device.metrics or {}
  local promoted = metrics.frequency_domain
  lines[#lines + 1] = "  " .. translated(i18n, "gpu.device_clocks", "Clocks")
  for _, domain in ipairs(domains) do
    local parts = {}
    -- Actual before current, which is the order the table promotes in, so the
    -- headline here and the cell there cannot disagree about what "now" is.
    -- The number and its rendering are kept apart: the share of the ceiling is
    -- arithmetic, and a formatted string cannot be divided.
    local current_hz = running(domain.actual_hz) or running(domain.current_hz)
    if current_hz then parts[#parts + 1] = frequency(current_hz) end
    local minimum = running(domain.minimum_hz) or running(domain.hardware_minimum_hz)
    local maximum = running(domain.maximum_hz) or running(domain.hardware_maximum_hz)
    if minimum and maximum then
      parts[#parts + 1] = translated(i18n, "gpu.device_range", "{minimum}–{maximum}", {
        minimum = frequency(minimum) or "?", maximum = frequency(maximum) or "?" })
    end
    -- A clock that is powered down has no rate to show, and a card that
    -- publishes only a ceiling has no range either, so without this the domain
    -- would say nothing but its name.  The ceiling is a fact about the hardware
    -- and stays readable; it is labelled rather than bare so it cannot be taken
    -- for the reading that is missing.
    if not current_hz and maximum then
      parts[#parts + 1] = translated(i18n, "metrics.maximum", "Maximum")
        .. " " .. (frequency(maximum) or "?")
    end
    -- The hardware ceiling is a different statement from the ceiling the driver
    -- will actually pick, and drawing both when they agree is noise.
    local hardware_minimum = running(domain.hardware_minimum_hz)
    local hardware_maximum = running(domain.hardware_maximum_hz)
    if hardware_minimum and hardware_maximum
        and (hardware_minimum ~= minimum or hardware_maximum ~= maximum) then
      parts[#parts + 1] = translated(i18n, "gpu.device_hardware_range",
        "hardware {minimum}–{maximum}", {
          minimum = frequency(hardware_minimum) or "?",
          maximum = frequency(hardware_maximum) or "?" })
    end
    if current_hz and maximum then
      parts[#parts + 1] = translated(i18n, "gpu.device_of_max", "{share} of {maximum} max", {
        share = percent(math.max(0, math.min(100, current_hz / maximum * 100))),
        maximum = frequency(maximum) or "?" })
    end
    -- Which of these the table is currently showing.  Without it the screen
    -- lists the clocks and leaves the reader to guess which one the Frequency
    -- column was talking about.
    if promoted and domain.id == promoted then
      parts[#parts + 1] = translated(i18n, "gpu.device_promoted", "shown in the table")
    end
    if domain.source_kind and domain.source_kind ~= "" then
      parts[#parts + 1] = translated(i18n, "metrics.source", "Source")
        .. " " .. tostring(domain.source_kind)
    end
    -- A clock that is powered down carries `unavailable` precisely so its raw
    -- zero is never read as a rate, so the state belongs on the line.
    if domain.quality and domain.quality ~= "fresh" then
      parts[#parts + 1] = Technical.state(i18n, domain.quality)
    end
    lines[#lines + 1] = string.format("    %-16s %s", tostring(domain.id),
      #parts > 0 and table.concat(parts, " · ") or "—")

    -- amdgpu publishes the performance levels it can choose between, with the
    -- active one starred in the driver's own output.  i915 and xe publish no
    -- such list, and the section is then simply absent.
    local states = type(domain.states) == "table" and domain.states or {}
    if #states > 0 then
      lines[#lines + 1] = "    " .. translated(i18n, "gpu.device_states", "Performance states")
      for _, state in ipairs(states) do
        local text = string.format("%s: %s", tostring(state.level),
          frequency(state.frequency_hz) or "—")
        if state.active then
          text = text .. " · " .. translated(i18n, "gpu.device_state_active", "active")
        end
        lines[#lines + 1] = "      " .. text
      end
    end
  end
  if frequencies.truncated then
    lines[#lines + 1] = "    " .. translated(i18n, "gpu.device_clocks_truncated",
      "more clock domains exist than were read")
  end
  return lines
end

-- One device goes straight to its clocks; several go through a list, exactly as
-- a process holding several DRM clients does.  Reaching the only answer should
-- not cost a keypress.
local function gpu_device_clock_lines(selection, i18n, unicode)
  if unicode == nil then unicode = true end
  local devices = type(selection) == "table" and selection.devices or {}
  local lines = {
    translated(i18n, "gpu.device_clocks_title", "Device clocks"), "",
  }
  if #devices == 0 then
    lines[#lines + 1] = translated(i18n, "gpu.device_no_clocks",
      "This device publishes no clock domain")
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
  end
  local detail = selection.device
  if not detail and #devices == 1 then detail = devices[1] end
  if detail then
    for _, line in ipairs(gpu_device_clock_detail_lines(detail, i18n)) do
      lines[#lines + 1] = line
    end
  else
    lines[#lines + 1] = translated(i18n, "gpu.device_select_hint",
      "Up/Down selects · Enter inspects · Esc closes")
    lines[#lines + 1] = ""
    local selected = selection.index or 1
    for position, device in ipairs(devices) do
      local label = device.model_name or device.card or device.id or "?"
      local facts = {}
      local domains = type(device.frequencies) == "table"
        and type(device.frequencies.domains) == "table" and device.frequencies.domains or {}
      if #domains > 0 then
        facts[#facts + 1] = string.format("%d %s", #domains,
          translated(i18n, "gpu.device_clocks", "Clocks"))
      end
      if device.driver and device.driver ~= "" then
        facts[#facts + 1] = tostring(device.driver)
      end
      lines[#lines + 1] = string.format("%s %-18s %s",
        position == selected and (unicode and "▸" or ">") or " ",
        tostring(label), table.concat(facts, " · "))
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
  return lines
end

-- Threads are ordered by CPU share, hottest first, with the TID as the
-- tie-break so two threads reading zero never swap places between refreshes.
-- The table in the process overlay and the picker that selects from it must
-- agree on this order: a row that moves between the two views is a row the
-- operator cannot keep track of.
local function thread_rows_by_cpu(thread_rows)
  local by_cpu = {}
  for index, thread in ipairs(thread_rows or {}) do by_cpu[index] = thread end
  table.sort(by_cpu, function(left, right)
    local left_cpu = type(left.cpu_percent) == "number" and left.cpu_percent or -1
    local right_cpu = type(right.cpu_percent) == "number" and right.cpu_percent or -1
    if left_cpu ~= right_cpu then return left_cpu > right_cpu end
    return left.tid < right.tid
  end)
  return by_cpu
end

--- How long a process waited on a runqueue, per second, or nil.
---
--- Nil covers three real situations that must not be drawn as a zero: the file
--- was never read for this process, it was unreadable, or there is only one
--- reading so far and therefore no interval to divide by.  A zero would be the
--- claim "this process never waited for a cpu", which is the one thing this
--- figure must not say without having measured it.
local function queued_rate_text(i18n, scheduler)
  if type(scheduler) ~= "table" then return nil end
  if scheduler.quality ~= "fresh" then return nil end
  local rate = scheduler.wait_rate_ns
  if type(rate) ~= "number" or rate ~= rate or rate < 0 then return nil end
  local format = i18n and i18n.format
  if not format then return nil end
  return detail_formatted(function()
    return assert(format:duration(rate / 1000000000)) .. "/s"
  end)
end

local function wait_site_text(i18n, site, status)
    if site then return site end
    if status == "not_reported" then
        return translated(i18n, "process.wait_site_none", "No sleeping site reported")
    end
    return Technical.state(i18n, status == "parse_error" and "error" or status)
end

local function process_detail_lines(process, i18n, linux_host)
    if not process then
        return {
            translated(i18n, "process.details_title", "Process details"), "",
            translated(i18n, "process.no_selection", "No process selected"),
        }
    end
    if process.pending_connection_owner or process.pending_systemd_process then
        return {
            translated(i18n, "process.details_title", "Process details"), "",
            process.pending_systemd_process and translated(i18n, "systemd.process_loading", "Reading the main process…")
                or translated(i18n, "network.owner_loading", "Reading the owner process…"), "",
            translated(i18n, "inspector.close_hint", "Esc/Enter closes"),
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
    local fd = type(process.fd_detail) == "table" and process.fd_detail or nil
    local switches = type(process.context_switches) == "table" and process.context_switches or {}
    local cpu_seconds = process.cpu_time_seconds
    if type(cpu_seconds) ~= "number" or cpu_seconds ~= cpu_seconds
        or cpu_seconds < 0 or cpu_seconds == math.huge then
        local rate = type(process.clock_ticks_per_second) == "number"
            and process.clock_ticks_per_second > 0
            and process.clock_ticks_per_second < math.huge
            and process.clock_ticks_per_second or 100
        cpu_seconds = type(process.cpu_ticks) == "number" and process.cpu_ticks / rate or nil
    end

    local rows = {
        { section = translated(i18n, "process.details_identity", "Identity") },
        { "ID", process.id },
        { "PID", process.pid },
        { "PPID", process.parent_pid },
        { translated(i18n, "process.details_name", "Name"), process.name },
        { translated(i18n, "metrics.user", "User"), process.user or process.uid },
        { translated(i18n, "metrics.state", "State"), process.state },
        { translated(i18n, "process.details_started", "CPU time"), seconds(cpu_seconds) },
        { translated(i18n, "process.details_elapsed", "Elapsed"),
          seconds(process.elapsed_seconds) },
        { blank = true },
        { section = translated(i18n, "process.details_command", "Command") },
        { translated(i18n, "process.details_command", "Command"), process.command },
        { blank = true },
        { section = translated(i18n, "process.details_resources", "Resources") },
        { "CPU", percent(process.cpu_percent) },
        { translated(i18n, "metrics.memory", "Memory"), bytes(process.resident_bytes) },
        { translated(i18n, "process.details_virtual_memory", "Virtual memory"),
          bytes(process.virtual_bytes), memory_anchor = true },
        { translated(i18n, "process.details_threads", "Threads"), process.threads,
          fd_anchor = true },
        { blank = true },
        { section = translated(i18n, "process.details_scheduling", "Scheduling") },
        { translated(i18n, "process.details_priority", "Priority"), process.priority },
        { "Nice", process.nice },
        { translated(i18n, "metrics.cpu", "Last CPU"), process.processor },
        { translated(i18n, "process.details_process_group", "Process group"), process.process_group },
        { translated(i18n, "process.details_session", "Session"), process.session },
    }
    if fd then
        local open_label = translated(i18n, "process.details_open_fds", "Leader open FDs")
        local limit_label = translated(i18n, "process.details_fd_limit",
            "FD limit (soft / hard)")
        local function limit_value(value, unlimited)
            if unlimited then
                return translated(i18n, "process.details_unlimited", "unlimited")
            end
            return type(value) == "number" and tostring(value) or "—"
        end
        local limit = fd.limit
        local limit_text = type(limit) == "table"
            and (limit_value(limit.soft, limit.soft_unlimited) .. " / "
                .. limit_value(limit.hard, limit.hard_unlimited))
            or Technical.state(i18n, fd.limit_status)
        for index, row in ipairs(rows) do
            if row.fd_anchor then
                table.insert(rows, index + 1, { open_label, fd_count_text(fd, i18n) })
                table.insert(rows, index + 2, { limit_label, limit_text })
                break
            end
        end
    end
    local affinity = type(process.affinity) == "table" and process.affinity or nil
    if affinity then
        rows[#rows + 1] = {
            translated(i18n, "process.leader_allowed_cpus", "Leader allowed CPUs"),
            affinity.cpus_allowed_list,
        }
        rows[#rows + 1] = {
            translated(i18n, "process.leader_allowed_nodes",
                "Leader allowed memory nodes"), affinity.mems_allowed_list,
        }
        if affinity.status ~= "ok" then
            rows[#rows + 1] = { translated(i18n, "process.affinity_status",
                "Affinity status"), Technical.state(i18n, affinity.status) }
        end
    end
    -- Run-queue wait, for the same reason the thread view has it: a process
    -- that is starved and a process that is busy are both running, and only the
    -- queueing figure tells them apart.  The row is added only when there is a
    -- real rate behind it -- a row of em dashes here would read as "this process
    -- never queued", which is the one claim this figure must not make without
    -- having measured it.
    local queued = queued_rate_text(i18n, process.scheduler)
    if queued then
        rows[#rows + 1] = { translated(i18n, "process.thread_queued", "Queued"), queued }
    end
    if process.wait_site_status then
        rows[#rows + 1] = { translated(i18n, "process.leader_wait_site",
            "Leader kernel wait site"),
            wait_site_text(i18n, process.wait_site, process.wait_site_status) }
        if process.wait_site then
            rows[#rows + 1] = { note = translated(i18n, "process.wait_site_note",
                "Kernel function; not a diagnosis") }
        end
    end
    for _, row in ipairs({
        { blank = true },
        { section = translated(i18n, "process.details_io", "I/O counters") },
        -- rchar/wchar are what the task asked the kernel for; read_bytes and
        -- write_bytes are what reached the storage layer.  Printing only the
        -- latter makes a process that is busy through pipes and page cache
        -- look idle, and would contradict the per-thread view, which has to
        -- show the syscall pair to be worth opening at all.
        { translated(i18n, "process.thread_syscall_read", "Syscall read"),
          bytes(io.rchar) },
        { translated(i18n, "process.thread_syscall_write", "Syscall write"),
          bytes(io.wchar) },
        { translated(i18n, "metrics.read", "Read"), bytes(io.read_bytes) },
        { translated(i18n, "metrics.write", "Write"), bytes(io.write_bytes),
          io_rate_anchor = true },
        { translated(i18n, "process.details_cancelled_write", "Cancelled write"),
          bytes(io.cancelled_write_bytes) },
        { translated(i18n, "process.details_voluntary_switches", "Voluntary switches"),
          switches.voluntary },
        { translated(i18n, "process.details_involuntary_switches", "Involuntary switches"),
          switches.involuntary },
    }) do
        rows[#rows + 1] = row
    end
    local io_rate = type(process.io_rate) == "table" and process.io_rate or nil
    if io_rate then
        local function bytes_per_second(value)
            if type(value) ~= "number" then return "—" end
            return detail_formatted(function()
                return assert(format:bytes(value)) .. "/s"
            end)
        end
        local additions = {
            { translated(i18n, "process.details_io_read_rate", "Read rate"),
              bytes_per_second(io_rate.read_bytes_per_second) },
            { translated(i18n, "process.details_io_write_rate", "Write rate"),
              bytes_per_second(io_rate.write_bytes_per_second) },
        }
        if io_rate.quality ~= "fresh" then
            additions[#additions + 1] = {
                translated(i18n, "process.details_io_rate_status", "I/O rate status"),
                Technical.state(i18n, io_rate.quality),
            }
        end
        for index, row in ipairs(rows) do
            if row.io_rate_anchor then
                for offset, addition in ipairs(additions) do
                    table.insert(rows, index + offset, addition)
                end
                break
            end
        end
    end
    if io.source then
        rows[#rows + 1] = { translated(i18n, "metrics.source", "Source"), io.source }
    end
    if process.io_reason then
        rows[#rows + 1] = { translated(i18n, "inspector.reason", "Reason"),
            inspector_text(Technical.reason(i18n, process.io_reason), INSPECTOR_ROW_WIDTH) }
    end
    local memory = type(process.memory_detail) == "table" and process.memory_detail or nil
    if memory then
        -- PSS and USS belong with the other memory figures, so they go directly
        -- under the virtual-memory row.  The row is located by its anchor
        -- rather than by index, so a row added above the Resources section
        -- cannot silently move these into the wrong section.  They are omitted
        -- rather than shown as "—" when the kernel has no rollup for this
        -- process.
        local extra = {}
        if type(memory.pss) == "number" then
            extra[#extra + 1] = { translated(i18n, "process.details_pss", "PSS"),
                bytes(memory.pss) }
        end
        if type(memory.uss) == "number" then
            extra[#extra + 1] = { translated(i18n, "process.details_uss", "Private (USS)"),
                bytes(memory.uss) }
        end
        for index, row in ipairs(rows) do
            if row.memory_anchor then
                for offset, addition in ipairs(extra) do
                    table.insert(rows, index + offset, addition)
                end
                break
            end
        end
    end
    for index, row in ipairs(rows) do
        row.memory_anchor = nil
        row.fd_anchor = nil
        row.io_rate_anchor = nil
        if row[2] ~= nil and type(row[2]) ~= "string" then rows[index][2] = format_value(row[2], i18n) end
    end

    local lines = {
        translated(i18n, "process.details_title", "Process details") .. " · PID "
            .. tostring(process.pid or "—"),
        "",
    }

    local thread_rows = type(process.thread_rows) == "table" and process.thread_rows or {}
    if #thread_rows > 0 then
        -- Threads lead the overlay: they are the per-selection data every
        -- other line is context for, and at a small terminal the section
        -- would otherwise only be reachable by scrolling.
        local by_cpu = thread_rows_by_cpu(thread_rows)
        lines[#lines + 1] = translated(i18n, "process.details_threads", "Threads")
        lines[#lines + 1] = string.format("  %-7s %s %6s %3s  %s", "TID", "S", "CPU%",
            "NI", translated(i18n, "process.details_name", "Name"))
        local shown = math.min(#by_cpu, 16)
        for index = 1, shown do
            local thread = by_cpu[index]
            lines[#lines + 1] = string.format("  %-7d %s %6s %3d  %s",
                thread.tid, tostring(thread.state or "?"),
                type(thread.cpu_percent) == "number" and percent(thread.cpu_percent)
                    or "—",
                type(thread.nice) == "number" and thread.nice or 0,
                tostring(thread.name or "—"))
        end
        local scan = type(process.thread_scan) == "table" and process.thread_scan or {}
        local total = type(scan.total) == "number" and scan.total or #thread_rows
        if scan.truncated == true then
            lines[#lines + 1] = "  …"
        elseif total - shown > 0 then
            lines[#lines + 1] = "  … +" .. (total - shown)
        end
        lines[#lines + 1] = ""
    end

    for _, line in ipairs(aligned_pairs(rows)) do lines[#lines + 1] = line end

    local oom = type(process.oom) == "table" and process.oom or nil
    if oom then
        local function oom_value(value, status)
            return type(value) == "number" and format_value(value, i18n)
                or Technical.state(i18n, status or "unavailable")
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "process.oom_title", "OOM selection")
        lines[#lines + 1] = "  " .. translated(i18n, "process.oom_score", "OOM score")
            .. ": " .. oom_value(oom.score, oom.score_status)
        lines[#lines + 1] = "  " .. translated(i18n, "process.oom_adjustment",
            "Score adjustment") .. ": " .. oom_value(oom.adjustment, oom.adjustment_status)
        lines[#lines + 1] = "  " .. translated(i18n, "process.oom_note",
            "Higher scores increase OOM selection likelihood.")
    end

    local numa = type(process.numa_detail) == "table" and process.numa_detail or nil
    if numa or process.numa_status then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "process.details_numa_placement",
            "Mapped pages by NUMA node")
        if numa then
            if #(numa.nodes or {}) == 0 then
                lines[#lines + 1] = "  " .. translated(i18n,
                    "process.details_numa_empty", "No mapped pages")
            end
            for _, node in ipairs(numa.nodes or {}) do
                lines[#lines + 1] = "  " .. translated(i18n, "process.details_numa_node",
                    "Node {node}", { node = node.node_id }) .. "  " .. bytes(node.mapped_bytes)
            end
            lines[#lines + 1] = "  " .. translated(i18n, "process.details_numa_note",
                "Shared pages count here; this is not PSS or a memory access rate.")
        else
            local status = process.numa_status == "parse_error" and "error"
                or process.numa_status == "too_large" and "unavailable"
                or process.numa_status
            lines[#lines + 1] = "  " .. tostring(Technical.state(i18n, status))
        end
    end

    if type(process.cgroups) == "table" and #process.cgroups > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "process.details_cgroups", "Control groups")
        for index, cgroup in ipairs(process.cgroups) do
            if index > 16 then
                lines[#lines + 1] = "  …"
                break
            end
            local path = tostring(cgroup.path or "—")
            -- The path is what the kernel said; the unit and container it
            -- encodes is what an operator recognises, and classifying it here
            -- costs nothing because the file was already read for the overlay.
            -- The label earns its own line only when the path does not already
            -- spell it out: for a container that is the runtime and short id,
            -- while a service's unit name is its last path component and
            -- repeating it would be noise.
            local semantics = CgroupSemantics.classify(path)
            if semantics.label and not path:find(semantics.label, 1, true) then
                lines[#lines + 1] = "  " .. semantics.label
                lines[#lines + 1] = "    " .. path
            else
                lines[#lines + 1] = "  " .. path
            end
        end
    end
    -- Keep the kernel's procfs-to-inner order. A mount inside a container
    -- cannot report IDs from the initial host namespace.
    local namespaces = type(process.namespaces) == "table" and process.namespaces or nil
    if namespaces and namespaces.namespaced and type(namespaces.nspid) == "table" then
        local chain = {}
        for _, value in ipairs(namespaces.nspid) do chain[#chain + 1] = tostring(value) end
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "process.details_namespaces", "PID namespaces")
        lines[#lines + 1] = "  " .. translated(i18n, "process.details_namespace_chain",
            "procfs → inside") .. "  " .. table.concat(chain, " → ")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "process.details_actions",
        "i thread · k signal · Up/Down/PgUp/PgDn scroll · Esc/Enter closes")
    if type(process.cgroups) == "table" and #process.cgroups > 0 then
        lines[#lines + 1] = translated(i18n, "process.details_workload_hint",
            "g opens this process's workload")
    end
    if linux_host and process.id and process.pid then
        lines[#lines + 1] = translated(i18n, "process.details_sockets_hint",
            "n opens this process's sockets on Linux")
        lines[#lines + 1] = translated(i18n, "process.fd_hint",
            "F opens this process's file descriptors on Linux")
    end
    return lines
end

local function process_fd_lines(result, i18n, selected, unicode)
    result = type(result) == "table" and result or {}
    local lines = {
        translated(i18n, "process.fd_title", "Open file descriptors · PID {pid}",
            { pid = result.pid or "?" }), "",
    }
    if result.status ~= "ok" then
        lines[#lines + 1] = result.reason == "process_identity_changed"
            and translated(i18n, "process.fd_changed",
                "Process identity changed; descriptor targets were discarded")
            or translated(i18n, "process.fd_unavailable",
                "File descriptor list is unavailable")
        lines[#lines + 1] = translated(i18n, "inspector.quality", "Quality")
            .. ": " .. Technical.state(i18n, result.status)
    else
        lines[#lines + 1] = translated(i18n, "process.fd_count",
            "Listed descriptors: {count}", { count = #result.entries })
        if #result.entries == 0 then
            lines[#lines + 1] = translated(i18n, "process.fd_empty",
                "No open descriptors were visible")
        end
        for index, entry in ipairs(result.entries) do
            local target = entry.target or Technical.state(i18n, entry.status)
            if entry.target_truncated then target = target .. "…" end
            lines[#lines + 1] = inspector_text(
                (index == (selected or 1) and (unicode == false and "> " or "▸ ")
                    or "  ") .. "FD " .. tostring(entry.fd) .. "  " .. tostring(target),
                INSPECTOR_ROW_WIDTH)
        end
        if result.truncated then
            lines[#lines + 1] = translated(i18n, "process.fd_capped",
                "Showing {count} descriptors; more may exist",
                { count = #result.entries })
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "process.fd_note",
            "Link targets only; file contents were not opened.")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "process.fd_return",
        "↑↓ selects · Enter inspects · Esc returns · q closes")
    return lines
end

local function process_fd_detail_lines(info, i18n)
    info = type(info) == "table" and info or {}
    local lines = {
        translated(i18n, "process.fd_detail_title", "FD {fd} · PID {pid}",
            { fd = info.fd or "?", pid = info.pid or "?" }), "",
        translated(i18n, "process.fd_target", "Link target") .. ": "
            .. inspector_text(info.target
                and (info.target .. (info.target_truncated and "…" or "")) or nil,
                INSPECTOR_ROW_WIDTH),
    }
    if info.status == "ok" then
        for _, spec in ipairs({
            { "process.fd_position", "File offset", info.position },
            { "process.fd_flags", "Flags (octal)", info.flags },
            { "process.fd_mount", "Mount ID", info.mount_id },
            { "process.fd_inode", "Inode", info.inode },
        }) do
            lines[#lines + 1] = translated(i18n, spec[1], spec[2]) .. ": "
                .. inspector_text(spec[3], INSPECTOR_ROW_WIDTH)
        end
        if info.quality == "partial" then
            lines[#lines + 1] = translated(i18n, "inspector.quality", "Quality")
                .. ": " .. Technical.state(i18n, "partial")
        end
    else
        local changed = info.reason == "process_fd_changed"
            or info.reason == "process_identity_changed"
        lines[#lines + 1] = changed
            and translated(i18n, "process.fd_detail_changed",
                "Process or descriptor changed; metadata was discarded")
            or translated(i18n, "process.fd_detail_unavailable",
                "Descriptor metadata is unavailable")
        lines[#lines + 1] = translated(i18n, "inspector.quality", "Quality")
            .. ": " .. Technical.state(i18n, info.status)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "process.fd_detail_note",
        "Target and fdinfo were reread at selection; the target file was not opened.")
    lines[#lines + 1] = translated(i18n, "process.fd_detail_return",
        "Esc/Enter returns to descriptors · q closes")
    return lines
end

--- The cgroup a thread is in versus the cgroup its process is in.
---
--- The kernel tracks cgroup membership per task, and a thread can be moved on
--- its own: the process stays where it is while one worker runs under a
--- different unit or slice.  That difference is invisible in every per-process
--- view, and it is exactly what an operator looking at "why is this process
--- behaving unlike its neighbours" needs, so it is stated rather than left for
--- the reader to diff two path lists by eye.  Returns nil when either side is
--- missing: an unreadable cgroup file is not evidence that the two match.
local function compare_thread_cgroup(thread_cgroups, process_cgroups)
  if type(thread_cgroups) ~= "table" or #thread_cgroups == 0 then return nil end
  if type(process_cgroups) ~= "table" or #process_cgroups == 0 then return nil end
  local process_paths = {}
  for _, cgroup in ipairs(process_cgroups) do
    process_paths[tostring(cgroup.path or "")] = true
  end
  local differing, same = {}, false
  for _, cgroup in ipairs(thread_cgroups) do
    if process_paths[tostring(cgroup.path or "")] then
      same = true
    else
      differing[#differing + 1] = cgroup
    end
  end
  if #differing == 0 then return "same" end
  -- A partial match still means the thread sits somewhere its process is not;
  -- reporting only the differing entries is what makes the mismatch visible.
  return "differs", differing, same
end

--- Every thread of one process, selectable.
---
--- The process overlay shows a fixed slice of the busiest threads; this lists
--- all of them, because a thread with no CPU share is still a thread an
--- operator may need to look at.  The columns are exactly the ones the table
--- already proved readable, and nothing here is read from procfs: the rows come
--- from the sample the collector has already taken.
local function thread_picker_lines(process, selection, i18n, unicode)
  if unicode == nil then unicode = true end
  local name = (process and (process.name or process.command)) or "?"
  local lines = {
    translated(i18n, "process.thread_picker_title", "Select a thread") .. " · "
      .. tostring(name) .. " · PID " .. tostring(process and process.pid or "—"),
    "",
    translated(i18n, "process.thread_select_hint",
        "Up/Down selects · Enter inspects · Esc closes"),
    "",
  }
  local threads = thread_rows_by_cpu(type(process) == "table" and process.thread_rows or nil)
  if #threads == 0 then
    lines[#lines + 1] = translated(i18n, "process.thread_none",
        "This process has no readable threads right now")
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
  end
  for index, thread in ipairs(threads) do
    local marker = index == selection.index and (unicode and "▸ " or "> ") or "  "
    -- The leader is the process itself, so marking it lets the user tell
    -- "the process's own thread" from "a worker" without counting ids.
    local role = thread.leader and translated(i18n, "process.thread_leader", "leader") or ""
    lines[#lines + 1] = string.format("%s%-8d %-2s %6s %3d  %s%s",
      marker, thread.tid, tostring(thread.state or "?"),
      type(thread.cpu_percent) == "number" and string.format("%.1f%%", thread.cpu_percent) or "—",
      type(thread.nice) == "number" and thread.nice or 0,
      tostring(thread.name or "—"), role ~= "" and ("  [" .. role .. "]") or "")
  end
  local scan = type(process.thread_scan) == "table" and process.thread_scan or {}
  if scan.truncated == true or (type(scan.total) == "number" and scan.total > #threads) then
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "process.thread_list_truncated",
        "Showing {shown} of {total} threads", {
          shown = tostring(#threads), total = tostring(scan.total or #threads),
        })
  end
  return lines
end

--- One thread, in full.
---
--- `thread` is the row the collector produced for this TID and `detail` is the
--- per-thread read the collector performs for the selected TID alone.  The two
--- are kept apart because they come from different files with different
--- freshness: the row is a stat sample that exists for every thread, while the
--- detail is read only for this one and can legitimately be missing.
--- The scheduling policy of a thread.
---
--- The numbers come from include/uapi/linux/sched.h and are a stable public
--- ABI, so naming them is not a guess.  They are kernel identifiers, not prose,
--- and are deliberately left untranslated: `SCHED_FIFO` means the same thing in
--- every locale, and translating it would make it mean something else.  A
--- number the kernel has added since this table was written is shown as the
--- number, because inventing a name for it would be exactly the failure this
--- project keeps refusing.
local SCHED_POLICIES = {
  [0] = "SCHED_OTHER",     -- SCHED_NORMAL
  [1] = "SCHED_FIFO",
  [2] = "SCHED_RR",
  [3] = "SCHED_BATCH",
  [4] = "SCHED_ISO",       -- reserved, never implemented by any kernel
  [5] = "SCHED_IDLE",
  [6] = "SCHED_DEADLINE",
  [7] = "SCHED_EXT",
}

local function thread_policy_name(policy)
  if type(policy) ~= "number" or policy ~= policy then return nil end
  return SCHED_POLICIES[policy] or tostring(policy)
end

local function thread_detail_lines(thread, detail, process, i18n)
  if not thread then
    return {
      translated(i18n, "process.thread_title", "Thread details"), "",
      translated(i18n, "process.thread_gone",
          "That thread is no longer part of the process"),
      "",
      translated(i18n, "inspector.close_hint", "Esc/Enter closes"),
    }
  end
  local format = i18n and i18n.format
  local function bytes(value)
    if type(value) ~= "number" then return "—" end
    return detail_formatted(function() return assert(format:bytes(value)) end)
  end
  local function percent(value)
    if type(value) ~= "number" then return "—" end
    return detail_formatted(function()
      return assert(format:percent(value, { precision = 1 }))
    end)
  end
  local function seconds(value)
    if type(value) ~= "number" then return "—" end
    return detail_formatted(function() return assert(format:duration(value)) end)
  end

  local scheduler = type(detail) == "table" and type(detail.scheduler) == "table"
    and detail.scheduler or nil
  -- schedstat's run time is nanoseconds of actual execution and does not
  -- depend on the kernel's tick rate.  The stat counters it replaces are only
  -- as precise as HZ, and a kernel configured with anything other than 100 Hz
  -- would make the old division quietly wrong rather than merely coarse, so
  -- the exact source is preferred whenever it was read.
  local cpu_seconds
  if scheduler and type(scheduler.run_ns) == "number" then
    cpu_seconds = scheduler.run_ns / 1000000000
  elseif type(thread.cpu_time_seconds) == "number"
      and thread.cpu_time_seconds == thread.cpu_time_seconds
      and thread.cpu_time_seconds >= 0 and thread.cpu_time_seconds < math.huge then
    cpu_seconds = thread.cpu_time_seconds
  elseif type(thread.cpu_ticks) == "number" then
    local rate = type(thread.clock_ticks_per_second) == "number"
      and thread.clock_ticks_per_second > 0
      and thread.clock_ticks_per_second < math.huge
      and thread.clock_ticks_per_second or 100
    cpu_seconds = thread.cpu_ticks / rate
  end

  local rows = {
    { section = translated(i18n, "process.details_identity", "Identity") },
    { "TID", thread.tid },
    -- The thread group is the process the thread belongs to.  It is read from
    -- the thread's own status file rather than assumed, because a task that
    -- exited and whose TID was reused belongs to somebody else by the time the
    -- overlay draws, and the number is what tells the two apart.
    { translated(i18n, "process.thread_group", "Thread group"), detail and detail.tgid },
    { translated(i18n, "process.details_name", "Name"), thread.name },
    -- The stat row carries the single-letter state; the status line spells it
    -- out ("S (sleeping)"), which is the difference between a code an operator
    -- has to look up and a word they can read.  Both are shown in preference
    -- order, never both, so the two overlays cannot disagree about the state.
    { translated(i18n, "metrics.state", "State"),
      (detail and detail.state_text) or thread.state },
    { translated(i18n, "metrics.user", "User"),
      (process and process.user) or (detail and detail.uid) },
    { blank = true },
    { section = translated(i18n, "process.details_resources", "Resources") },
    { "CPU", percent(thread.cpu_percent) },
    { translated(i18n, "process.details_started", "CPU time"), seconds(cpu_seconds) },
    { translated(i18n, "process.details_elapsed", "Elapsed"),
      seconds(thread.elapsed_seconds), fd_anchor = true },
    { blank = true },
    { section = translated(i18n, "process.details_scheduling", "Scheduling") },
    { translated(i18n, "process.details_priority", "Priority"), thread.priority },
    { "Nice", thread.nice },
    { translated(i18n, "process.details_voluntary_switches", "Voluntary switches"),
      detail and detail.voluntary_switches },
    { translated(i18n, "process.details_involuntary_switches", "Involuntary switches"),
      detail and detail.involuntary_switches },
  }
  local thread_fd = type(detail) == "table" and detail.fd_detail or nil
  if detail and detail.wait_site_status then
    rows[#rows + 1] = { translated(i18n, "process.wait_site", "Kernel wait site"),
      wait_site_text(i18n, detail.wait_site, detail.wait_site_status) }
    if detail.wait_site then
      rows[#rows + 1] = { note = translated(i18n, "process.wait_site_note",
        "Kernel function; not a diagnosis") }
    end
  end
  if thread_fd then
    for index, row in ipairs(rows) do
      if row.fd_anchor then
        table.insert(rows, index + 1, {
          translated(i18n, "process.thread_open_fds", "Thread open FDs"),
          fd_count_text(thread_fd, i18n),
        })
        local leader_fd = type(process) == "table" and process.fd_detail or nil
        if thread.tid ~= (process and process.pid) and leader_fd then
          table.insert(rows, index + 2, {
            translated(i18n, "process.details_open_fds", "Leader open FDs"),
            fd_count_text(leader_fd, i18n),
          })
        end
        break
      end
    end
  end
    local affinity = type(detail) == "table" and type(detail.affinity) == "table"
        and detail.affinity or nil
    if affinity then
        rows[#rows + 1] = {
            translated(i18n, "process.thread_allowed_cpus", "Allowed CPUs"),
            affinity.cpus_allowed_list,
        }
        rows[#rows + 1] = {
            translated(i18n, "process.thread_allowed_nodes",
                "Allowed memory nodes"), affinity.mems_allowed_list,
        }
        if affinity.status ~= "ok" then
            rows[#rows + 1] = { translated(i18n, "process.affinity_status",
                "Affinity status"), Technical.state(i18n, affinity.status) }
        end
    end

  local io = type(detail) == "table" and type(detail.io) == "table" and detail.io or nil

  local function rate_per_second(value, render)
    if type(value) ~= "number" then return "—" end
    return detail_formatted(function() return render(value) .. "/s" end)
  end

  if scheduler then
    -- The policy is the reason a thread can be starved on purpose: SCHED_IDLE
    -- yields to everything, SCHED_FIFO outranks ordinary tasks.  Without it
    -- "this thread is slow" has no explanation.
    local policy = thread_policy_name(scheduler.policy)
    if policy then
      rows[#rows + 1] = { translated(i18n, "process.thread_policy", "Policy"), policy }
    end
    -- Cumulative counters say nothing about right now, so the two figures that
    -- matter are rates over the interval since this thread was last read.  The
    -- interval is not assumed to be one tick: the cursor may have been on
    -- another thread in between, and the counters span the whole gap.
    if scheduler.quality == "fresh" then
      rows[#rows + 1] = { translated(i18n, "process.thread_queued", "Queued"),
        rate_per_second(scheduler.wait_rate_ns, function(value)
          return assert(format:duration(value / 1000000000))
        end) }
      rows[#rows + 1] = { translated(i18n, "process.thread_timeslices", "Timeslices"),
        rate_per_second(scheduler.timeslice_rate, function(value)
          return string.format("%.1f", value)
        end) }
      -- The switch rates are the answer to a question the cumulative totals
      -- above cannot answer: a thread that switched ten thousand times in its
      -- first minute and not since looks identical, in those totals, to one
      -- switching ten times a second right now.  The split matters more than
      -- the total -- a thread the kernel keeps preempting is competing for a
      -- cpu, while one that blocks on a mutex gave the cpu up itself, and the
      -- two want opposite fixes.
      if type(scheduler.switch_rate) == "number" then
        rows[#rows + 1] = {
          translated(i18n, "process.thread_switch_rate", "Switches"),
          rate_per_second(scheduler.switch_rate, function(value)
            return string.format("%.1f", value)
          end) }
        if scheduler.preempted_fraction ~= nil then
          rows[#rows + 1] = {
            translated(i18n, "process.thread_preempted", "Preempted share"),
            percent(scheduler.preempted_fraction * 100) }
        end
      end
    end
  end

  if io then
    -- rchar/wchar are what the thread asked the kernel for; read_bytes and
    -- write_bytes are what reached the storage layer.  A thread can be doing
    -- all of its I/O through pipes and page cache and still show zero on
    -- disk, so only the syscall pair would make a busy thread look idle.
    rows[#rows + 1] = { blank = true }
    rows[#rows + 1] = { section = translated(i18n, "process.details_io", "I/O counters") }
    rows[#rows + 1] = { translated(i18n, "process.thread_syscall_read", "Syscall read"),
      bytes(io.rchar) }
    rows[#rows + 1] = { translated(i18n, "process.thread_syscall_write", "Syscall write"),
      bytes(io.wchar) }
    rows[#rows + 1] = { translated(i18n, "metrics.read", "Read"), bytes(io.read_bytes) }
    rows[#rows + 1] = { translated(i18n, "metrics.write", "Write"), bytes(io.write_bytes) }
  end

  -- Memory is the one thing in this overlay that is emphatically not the
  -- thread's.  Threads share an address space, and /proc/<tid>/smaps is a
  -- separate file whose content is byte-for-byte the process's own smaps --
  -- verified on this host, not assumed.  Reading it would be a second full
  -- walk of a large file to print the process's numbers under a thread's name,
  -- so it is not read.  The process's own figures are shown instead, labelled
  -- as the process's, which is the truth an operator looking for a thread's
  -- memory can actually use.
  local detail_memory = type(process) == "table" and process.memory_detail or nil
  if detail_memory and (detail_memory.pss or detail_memory.uss or detail_memory.rss) then
    rows[#rows + 1] = { blank = true }
    rows[#rows + 1] = {
      section = translated(i18n, "process.thread_memory_section",
        "Memory (the process's, not the thread's)"),
    }
    if detail_memory.pss then
      rows[#rows + 1] = { "PSS", bytes(detail_memory.pss) }
    end
    if detail_memory.uss then
      rows[#rows + 1] = { "USS", bytes(detail_memory.uss) }
    end
    if not detail_memory.pss and detail_memory.rss then
      rows[#rows + 1] = { "RSS", bytes(detail_memory.rss) }
    end
  end

  for index, row in ipairs(rows) do
    row.fd_anchor = nil
    if row[2] ~= nil and type(row[2]) ~= "string" then
      rows[index][2] = format_value(row[2], i18n)
    end
  end

  local lines = {
    translated(i18n, "process.thread_title", "Thread details") .. " · TID "
      .. tostring(thread.tid),
    "",
  }
  if process then
    lines[#lines + 1] = translated(i18n, "process.thread_of", "Thread of {name} · PID {pid}", {
      name = tostring(process.name or "?"), pid = tostring(process.pid or "—"),
    })
    lines[#lines + 1] = ""
  end

  for _, line in ipairs(aligned_pairs(rows)) do lines[#lines + 1] = line end

  if type(detail) ~= "table" then
    -- The detail read lands on the tick after the thread is selected.  Saying
    -- so is better than an overlay full of em dashes, which reads as "this
    -- thread has no I/O" rather than "not read yet".
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "process.thread_pending",
        "Reading this thread on the next refresh…")
  end

  local cgroups = type(detail) == "table" and type(detail.cgroups) == "table"
    and detail.cgroups or nil
  local process_cgroups = type(process) == "table" and type(process.cgroups) == "table"
    and process.cgroups or nil
  local verdict, differing = compare_thread_cgroup(cgroups, process_cgroups)
  if verdict then
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "process.details_cgroups", "Control groups")
    if verdict == "same" then
      lines[#lines + 1] = "  " .. translated(i18n, "process.thread_cgroup_same",
          "Same as the process")
    else
      lines[#lines + 1] = "  " .. translated(i18n, "process.thread_cgroup_differs",
          "This thread is not in the process' control groups")
    end
    local shown = verdict == "same" and cgroups or differing
    for index, cgroup in ipairs(shown) do
      if index > 8 then
        lines[#lines + 1] = "  …"
        break
      end
      local path = tostring(cgroup.path or "—")
      local semantics = CgroupSemantics.classify(path)
      if semantics.label and not path:find(semantics.label, 1, true) then
        lines[#lines + 1] = "    " .. semantics.label
        lines[#lines + 1] = "      " .. path
      else
        lines[#lines + 1] = "    " .. path
      end
    end
    if verdict == "differs" then
      -- The process' own path is what makes the mismatch actionable, so it is
      -- printed next to the thread's rather than left to memory.
      lines[#lines + 1] = "    " .. translated(i18n, "process.thread_cgroup_process_is",
          "Process is in:")
      for index, cgroup in ipairs(process_cgroups) do
        if index > 8 then
          lines[#lines + 1] = "      …"
          break
        end
        local path = tostring(cgroup.path or "—")
        local semantics = CgroupSemantics.classify(path)
        if semantics.label and not path:find(semantics.label, 1, true) then
          lines[#lines + 1] = "      " .. semantics.label
          lines[#lines + 1] = "        " .. path
        else
          lines[#lines + 1] = "      " .. path
        end
      end
    end
  end

  local namespaces = type(detail) == "table" and type(detail.nspid) == "table"
    and detail.nspid or nil
  if namespaces and #namespaces > 1 then
    local chain = {}
    for _, value in ipairs(namespaces) do chain[#chain + 1] = tostring(value) end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "process.details_namespaces", "PID namespaces")
    lines[#lines + 1] = "  " .. translated(i18n, "process.details_namespace_chain",
        "procfs → inside") .. "  " .. table.concat(chain, " → ")
  end

  if type(detail) == "table" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "metrics.source", "Source") .. "  "
      .. tostring(detail.source or "—")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = translated(i18n, "process.thread_actions",
      "Esc returns to the thread list")
  if type(thread) == "table" and type(detail) == "table"
      and detail.tid == thread.tid
      and detail.starttime_ticks == thread.starttime_ticks
      and WorkloadNavigation.target_id(detail, "cgroup2") then
    lines[#lines + 1] = translated(i18n, "process.thread_workload_hint",
        "g opens this thread's workload")
  end
  return lines
end

-- Help is structured data, laid out here.  It used to live as pre-padded
-- strings inside every locale file, which meant the two columns only lined up
-- in English, a new shortcut required editing ten translations, and the text
-- could not be reflowed for a narrow terminal.
local function route_detail_lines(snapshot, i18n)
    local routes = snapshot.network and snapshot.network.routes
    local lines = { translated(i18n, "network.routes_title", "Procfs routes"), "" }
    if type(routes) ~= "table" then
        lines[#lines + 1] = translated(i18n, "network.routes_loading", "Reading procfs routes…")
    else
        local entries = routes.entries or {}
        local shown = math.min(#entries, 256)
        lines[#lines + 1] = translated(i18n, "network.routes_summary",
            "{visible}/{total} routes · IPv4 {ipv4} · IPv6 {ipv6}", {
                visible = shown, total = routes.total or #entries,
                ipv4 = Technical.state(i18n, routes.ipv4_status or "unavailable"),
                ipv6 = Technical.state(i18n, routes.ipv6_status or "unavailable"),
            })
        lines[#lines + 1] = translated(i18n, "network.routes_note",
            "Procfs view; policy routing tables may differ.")
        if routes.quality == "stale" then
            lines[#lines + 1] = translated(i18n, "inspector.quality", "Quality")
                .. ": " .. Technical.state(i18n, "stale")
        end
        if type(routes.invalid_lines) == "number" and routes.invalid_lines > 0 then
            lines[#lines + 1] = translated(i18n, "network.routes_invalid",
                "Route rows not parsed: {count}", { count = routes.invalid_lines })
        end
        if routes.truncated and (routes.total or 0) <= #entries then
            lines[#lines + 1] = translated(i18n, "network.routes_truncated",
                "The route scan was truncated")
        end
        lines[#lines + 1] = ""
        if shown == 0 then
            lines[#lines + 1] = translated(i18n, "network.routes_empty", "No procfs route data")
        end
        for index = 1, shown do
            local route = entries[index]
            lines[#lines + 1] = (route.selected_default and "* " or "  ")
                .. (route.family == "ipv6" and "IPv6 " or "IPv4 ")
                .. tostring(route.destination_cidr or "?")
                .. (route.up == false and " [" .. translated(i18n,
                    "network.route_inactive", "inactive") .. "]" or "")
            local via = route.gateway and translated(i18n, "network.route_via",
                "via {gateway}", { gateway = route.gateway })
                or translated(i18n, "network.route_direct", "on link")
            lines[#lines + 1] = inspector_text("    " .. via .. " · "
                .. tostring(route.interface or "?") .. " · "
                .. translated(i18n, "network.route_metric", "metric") .. " "
                .. format_value(route.metric, i18n)
                .. " · " .. translated(i18n, "network.route_flags", "flags")
                .. " 0x" .. string.format("%X", route.flags or 0), INSPECTOR_ROW_WIDTH)
            if route.source_cidr then
                lines[#lines + 1] = "    " .. translated(i18n, "metrics.source", "Source")
                    .. ": " .. route.source_cidr
            end
        end
        if routes.truncated or (routes.total or 0) > shown then
            lines[#lines + 1] = translated(i18n, "ui.rows_capped",
                "showing {visible} of {total}", { visible = shown, total = routes.total or #entries })
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
end

local function connection_owner_lines(selection, i18n, unicode)
    local lines = {
        translated(i18n, "network.owners_title", "Connection owners"), "",
        translated(i18n, "metrics.local_endpoint", "Local") .. ": "
            .. tostring(selection.local_endpoint or "—"),
        translated(i18n, "metrics.remote_endpoint", "Remote") .. ": "
            .. tostring(selection.remote_endpoint or "—"), "",
    }
    for index, owner in ipairs(selection.owners) do
        lines[#lines + 1] = (index == selection.index and (unicode and "▸ " or "> ") or "  ")
            .. "PID " .. tostring(owner.pid or "?") .. (unicode and " · FD " or " | FD ")
            .. tostring(owner.fd or "?")
            .. (type(owner.fd_count) == "number" and owner.fd_count > 1
                and " (+" .. tostring(owner.fd_count - 1) .. ")" or "")
            .. (unicode and " · " or " | ")
            .. tostring(owner.name or "?")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "network.owners_hint",
        "↑↓ select · Enter opens process · Esc closes")
    return lines
end

local function hardware_reference_lines(graph, selection, i18n, unicode)
    local source = graph.by_id[selection.source_id]
    local lines = {
        translated(i18n, "inventory.related_title", "Related devices"), "",
        translated(i18n, "inventory.device", "Device") .. ": "
            .. (source and Hardware.label(source, i18n) or selection.source_id), "",
    }
    for index, item in ipairs(selection.items) do
        local target = graph.by_id[item.id]
        lines[#lines + 1] = inspector_text(
            (index == selection.index and (unicode and "▸ " or "> ") or "  ")
            .. item.id .. (unicode and " · " or " | ")
            .. (target and Hardware.label(target, i18n) or (unicode and "—" or "-")),
            INSPECTOR_ROW_WIDTH)
    end
    if selection.truncated then
        lines[#lines + 1] = translated(i18n, "ui.rows_capped",
            "showing {visible} of {total}", {
                visible = #selection.items, total = selection.total,
            })
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inventory.related_hint",
        "↑↓ select · Enter opens · Esc goes back")
    return lines
end

local function hardware_detail_lines(snapshot, id, i18n, now_ns, history_count)
    local graph = Hardware.build(snapshot)
    local node = graph.by_id[id]
    if not node then
        return { translated(i18n, "inventory.not_present", "Device not in the current inventory"),
            translated(i18n, "inspector.close_hint", "Esc/Enter closes") }
    end
    local device = node.device
    local lines = { translated(i18n, "inventory.detail_title", "Device: {id}",
        { id = node.identifier }) }
    local function add(key, fallback, value, unit)
        lines[#lines + 1] = translated(i18n, key, fallback) .. ": "
            .. inspector_text(format_value(value, i18n, unit), INSPECTOR_ROW_WIDTH)
    end
    add("inventory.bus", "Bus", node.bus:upper())
    add("inventory.device", "Device", Hardware.label(node, i18n))
    local parent = graph.by_id[node.parent_id]
    local parent_label = parent and Hardware.label(parent, i18n)
    add("inventory.parent", "Parent device", parent
        and (parent.identifier .. (parent_label ~= parent.identifier and " · " .. parent_label or ""))
        or node.parent_id)
    add("inventory.driver", "Driver", device.driver)
    add("metrics.source", "Source", device.source)
    if device.processor_group ~= nil then
        add("cpu.processor_group", "Processor group", device.processor_group)
    end
    if device.logical_processor_index ~= nil then
        add("cpu.group_index", "Group CPU index", device.logical_processor_index)
    end
    if device.efficiency_class ~= nil then
        add("cpu.efficiency_class", "Efficiency class", device.efficiency_class)
    end
    if device.parked ~= nil then add("cpu.parked", "Parked", device.parked) end
    if device.online ~= nil then
        local online = device.online
        if device.online_known == false then online = nil end
        add("cpu.online", "Online", online)
    end
    if device.cores_per_compute_unit then
        add("cpuid.cores_per_unit", "Cores per compute unit", device.cores_per_compute_unit)
    end
    if device.apic_id then add("cpuid.apic_id", "APIC ID", string.format("0x%x", device.apic_id)) end
    if device.initial_apic_id then
        add("cpuid.initial_apic_id", "Initial APIC ID", string.format("0x%x", device.initial_apic_id))
    end
    if node.kind == "thread" then
        local info = snapshot.cpu_info and snapshot.cpu_info.cpuid
        for _, cpu in ipairs(info and info.logical_cpus or {}) do
            if cpu.id == device.id then
                local identity = cpu.identity or {}
                add("cpuid.title", "CPU capabilities", info.source)
                add("inspector.quality","Quality",Technical.state(i18n,info.quality))
                if info.age_ms then add("systemd.sample_age","Sample age",format_value(info.age_ms*1000000,i18n,"nanoseconds"))end
                add("cpuid.signature", "CPU signature", identity.signature)
                if identity.core_type then add("cpuid.core_type","Hardware core type",string.format("0x%02x · %s",identity.core_type,identity.core_type_source))end
                if identity.native_model_id then add("cpuid.native_model","Native core model",identity.native_model_id)end
                if identity.efficiency_ranking~=nil then add("cpuid.efficiency_ranking","Power efficiency rank",identity.efficiency_ranking)end
                add("cpuid.physical_bits", "Physical address bits", identity.physical_address_bits)
                add("cpuid.linear_bits", "Linear address bits", identity.linear_address_bits)
                add("cpuid.hypervisor", "Hypervisor interface present", identity.hypervisor_present)
                if identity.hypervisor_vendor then add("cpuid.hypervisor_vendor", "Hypervisor vendor", identity.hypervisor_vendor) end
                if cpu.xcr0 then add("cpuid.xcr0", "Enabled extended state (XCR0)", cpu.xcr0) end
                for _, feature in ipairs(cpu.features or {}) do
                    lines[#lines + 1] = feature.name .. ": " .. translated(i18n, "cpuid.hardware", "Hardware")
                        .. " " .. format_value(feature.hardware, i18n) .. " · "
                        .. translated(i18n, "cpuid.usable", "Usable") .. " " .. format_value(feature.usable, i18n)
                end
                break
            end
        end
    end
    local function hardware_hex(value, digits)
        if type(value) == "number" and math.tointeger(value)
                and value >= 0 and value < 16 ^ digits then
            return string.format("%0" .. digits .. "x", value)
        end
    end
    if node.bus == "pci" or node.bus == "usb" then
        local vendor = hardware_hex(device.vendor_id, 4)
        local product = hardware_hex(node.bus == "pci" and device.device_id or device.product_id, 4)
        if vendor or product then
            add("inventory.identifier", "ID", (vendor or "—") .. ":" .. (product or "—"))
        end
    end
    local quality = snapshot.quality and snapshot.quality[node.resource or "inventory"]
    if quality then
        add("inspector.quality", "Quality", Technical.state(i18n, quality.quality))
    end
    local function add_list(key, fallback, values)
        for first = 1, #values, 8 do
            local batch = {}
            for index = first, math.min(#values, first + 7) do batch[#batch + 1] = tostring(values[index]) end
            add(key, fallback, table.concat(batch, ", "))
        end
    end
    if node.kind == "display_connector" then
        if device.backend == "setupapi" then
            add("display.os_present", "Present in OS device list", device.os_present)
            lines[#lines + 1] = translated(i18n, "display.os_note",
                "OS presence does not establish a physical connection or an active desktop mode.")
            if device.desktop_status then
                local current = Quality.current_source(snapshot.quality, "displays")
                add("display.desktop_status", "Desktop association", Technical.state(i18n,
                    current and device.desktop_status or "stale"))
                add("display.desktop_active", "Active in this desktop", device.desktop_active)
                add("display.desktop_primary", "Primary desktop source", device.desktop_primary)
                if device.current_mode_status then
                    add("display.current_mode", "Current mode status", Technical.state(i18n,
                        current and device.current_mode_status or "stale"))
                end
                local mode = device.current_mode
                if type(mode) == "table" then
                    add("display.desktop_pixels", "Desktop source size (pixels)",
                        tostring(mode.pixel_width) .. " x " .. tostring(mode.pixel_height))
                    add("display.nominal_refresh", "Nominal mode refresh", mode.refresh_hz, "hertz")
                    if mode.position_x ~= nil and mode.position_y ~= nil then
                        add("display.desktop_position", "Desktop position (pixels)",
                            tostring(mode.position_x) .. ", " .. tostring(mode.position_y))
                    end
                    add("display.desktop_orientation", "Desktop rotation (degrees)", mode.orientation_degrees)
                    add("display.desktop_bpp", "Framebuffer bits per pixel", mode.bits_per_pixel)
                    add("display.mode_interlaced", "Interlaced mode", mode.interlaced)
                end
                lines[#lines + 1] = translated(i18n, "display.desktop_note",
                    "Current session desktop source; refresh is nominal. Framebuffer depth is not panel color depth or HDR. Physical signal timing and desktop scaling are not determined.")
            end
        elseif device.backend == "coregraphics" then
            add("display.online", "Online OS display", device.online)
            add("display.active", "Drawable", device.active)
            add("display.asleep", "Asleep", device.asleep)
            add("display.builtin", "Built-in", device.builtin)
            add("display.main", "Main display", device.main)
            add("display.os_vendor", "OS vendor number", hardware_hex(device.vendor_number, 8))
            add("display.os_model", "OS model number", hardware_hex(device.model_number, 8))
            add("display.current_mode", "Current mode status", Technical.state(i18n,
                Quality.current_source(snapshot.quality, "displays") and device.current_mode_status or "stale"))
            local mode = device.current_mode
            if type(mode) == "table" then
                add("display.mode_points", "Mode size (points)", tostring(mode.width_points) .. " x " .. tostring(mode.height_points))
                add("display.mode_pixels", "Backing size (pixels)", tostring(mode.pixel_width) .. " x " .. tostring(mode.pixel_height))
                add("display.nominal_refresh", "Nominal mode refresh", mode.refresh_hz, "hertz")
            end
            lines[#lines + 1] = translated(i18n, "display.coregraphics_note",
                "OS displays can be virtual. Refresh is nominal, not measured; physical size, color depth and HDR are not determined.")
        else
            add("display.connection", "Connection", Technical.state(i18n, device.connection))
            add("display.enabled", "Encoder enabled", device.enabled)
            add("display.dpms", "Driver DPMS", device.dpms)
            add("display.connector_id", "DRM connector ID", device.connector_id)
        end
        if device.backend == "drm-sysfs" and device.current_mode_status then
            add("display.current_mode", "Current mode status", Technical.state(i18n,
                Quality.current_source(snapshot.quality, "displays") and device.current_mode_status or "stale"))
            local mode = device.current_mode
            if type(mode) == "table" then
                add("display.configured_pixels", "Configured output size (pixels)",
                    tostring(mode.pixel_width) .. " x " .. tostring(mode.pixel_height))
                add("display.nominal_refresh", "Nominal mode refresh", mode.refresh_hz, "hertz")
                add("display.mode_clock", "Mode pixel clock", mode.pixel_clock_hz, "hertz")
                add("display.mode_interlaced", "Interlaced mode", mode.interlaced)
                add("display.mode_double_scan", "Double-scan mode", mode.double_scan)
                if mode.vscan and mode.vscan > 1 then add("display.mode_vscan", "Vertical scan multiplier", mode.vscan) end
                if not mode.refresh_hz then
                    add("display.mode_approx_refresh", "Kernel approximate refresh", mode.approx_refresh_hz, "hertz")
                end
            end
            if device.current_mode_reason then
                add("inspector.reason", "Reason", Technical.reason(i18n, device.current_mode_reason))
            end
            if type(now_ns) == "number" and type(device.current_mode_observed_at_ns) == "number" then
                add("display.mode_age", "Mode sample age", math.max(0, now_ns - device.current_mode_observed_at_ns), "nanoseconds")
            end
            lines[#lines + 1] = translated(i18n, "display.configured_note",
                "Configured output mode; refresh is nominal. Desktop scaling, rotation, color depth and HDR are not determined.")
        end
        if device.backend ~= "coregraphics" then
            add("display.edid_status", "Cached EDID status", Technical.state(i18n, device.edid_status))
        end
        add("inspector.quality", "Quality", Technical.state(i18n,
            Quality.current_source(snapshot.quality, "displays") and device.quality or "stale"))
        if device.reason then add("inspector.reason", "Reason", Technical.reason(i18n, device.reason)) end
        if device.edid_reason then add("inspector.reason", "Reason", Technical.reason(i18n, device.edid_reason)) end
        if type(now_ns) == "number" and type(device.observed_at_ns) == "number" then
            add("systemd.sample_age", "Sample age", math.max(0, now_ns - device.observed_at_ns), "nanoseconds")
        end
        local edid = device.edid
        if type(edid) == "table" then
            add("display.edid_version", "EDID version", edid.version)
            add("display.manufacturer", "Manufacturer code", edid.manufacturer)
            add("display.name", "EDID name", edid.name)
            add("display.product", "Product code", hardware_hex(edid.product_code, 4))
            add("display.size", "Declared size", edid.width_mm and edid.height_mm
                and tostring(edid.width_mm) .. " x " .. tostring(edid.height_mm) .. " mm")
            add("display.input", "Declared digital input", edid.interface)
            add("display.digital", "Digital signal declared", edid.digital)
            add("display.depth", "Declared bits per color", edid.bits_per_color)
            if edid.model_year then add("display.model_year", "Model year", edid.model_year)
            else add("display.year", "Manufacture year", edid.manufacture_year) end
            add("display.week", "Manufacture week", edid.manufacture_week)
            add("display.serial_present", "Serial number present", edid.serial_present)
            add("display.extensions", "Declared extension blocks", edid.extension_count)
            add("inspector.quality", "Quality", Technical.state(i18n,
                Quality.current_source(snapshot.quality, "displays") and edid.quality or "stale"))
            if edid.reason then add("inspector.reason", "Reason", Technical.reason(i18n, edid.reason)) end
            for _, value in ipairs(edid.detailed_timings or {}) do
                add("display.timing", "EDID base timing (pixels x encoded lines)",
                    tostring(value.horizontal_active_pixels) .. " x " .. tostring(value.vertical_active_lines))
                add("display.pixel_clock", "Declared pixel clock", value.pixel_clock_hz, "hertz")
                if value.refresh_hz then add("display.refresh", "Declared progressive refresh", value.refresh_hz, "hertz") end
                add("display.interlaced", "Interlaced declaration", value.interlaced)
                add("display.preferred", "Preferred declaration", value.preferred)
            end
            require("wtop.ui.edid_declarations").append(edid, add, add_list, i18n,
                Quality.current_source(snapshot.quality, "displays"))
        end
        add_list("display.modes", "Driver mode names", device.modes or {})
        if device.modes_truncated then add("inspector.quality", "Quality", Technical.state(i18n, "truncated")) end
        if device.backend ~= "coregraphics" then
            lines[#lines + 1] = translated(i18n, "display.note",
                "Cached declarations, not active resolution, refresh, color depth, audio, HDR or VRR. CTA rates are nominal format families; interlaced detailed lines remain encoded.")
        end
    elseif node.kind == "numa" then
        add("widgets.logical_cpus", "Logical CPUs", device.cpu_ids and #device.cpu_ids)
    end
    if #node.cpu_ids > 0 or node.kind == "numa" then
        add_list("numa.cpu_ids", "CPU IDs", node.kind == "numa" and device.cpu_ids or node.cpu_ids or {})
    end
    if node.kind == "cpu_cache" then
        add("processor_fw.level", "Cache level", device.level)
        add("metrics.type", "Type", device.type)
        add("metrics.capacity", "Size", device.size_bytes, "bytes")
        if device.coherency_line_size_bytes then
            add("cpu.cache_line", "Cache line (bytes)", device.coherency_line_size_bytes)
        end
        if device.ways_of_associativity then
            add("cpu.cache_ways", "Associativity (ways)", device.ways_of_associativity)
        end
    elseif node.bus == "cpu" and #node.cache_ids > 0 then
        local names = {}
        for _, id in ipairs(node.cache_ids) do
            local cache = graph.by_id[id]
            if cache and cache.kind == "cpu_cache" and not cache.ambiguous then
                names[#names + 1] = Hardware.label(cache, i18n)
            end
        end
        if #names > 0 then add_list("metrics.cache", "Cache", names) end
    end
    if #node.numa_node_ids > 0 then add_list("numa.nodes", "NUMA nodes", node.numa_node_ids) end
    if #node.cpufreq_ids > 0 then
        local names = {}
        for _, id in ipairs(node.cpufreq_ids) do
            local policy = graph.by_id["cpufreq:" .. id]
            names[#names + 1] = policy and policy.identifier or id
        end
        add_list("inventory.related_policies", "Frequency policies", names)
    end
    if node.kind == "numa" then
        local memory = device.memory or {}
        add("metrics.total", "Total", memory.total_bytes, "bytes")
        add("metrics.free", "Free", memory.free_bytes, "bytes")
        add("numa.used", "Used (including cache)", memory.used_bytes, "bytes")
        local allocations = device.allocations
        if allocations then
            lines[#lines + 1] = ""
            lines[#lines + 1] = translated(i18n, "numa.allocations_title",
                "Allocation locality (pages since boot)")
            add("numa.numa_hit", "Preferred-node hit", allocations.numa_hit_pages)
            add("numa.numa_miss", "Allocated here, preferred elsewhere",
                allocations.numa_miss_pages)
            add("numa.numa_foreign", "Preferred here, allocated elsewhere",
                allocations.numa_foreign_pages)
            add("numa.interleave_hit", "Interleave hit", allocations.interleave_hit_pages)
            add("numa.local_node", "CPU on this node", allocations.local_node_pages)
            add("numa.other_node", "CPU on another node", allocations.other_node_pages)
            local rates = allocations.rates or {}
            local function pages_per_second(value)
                if type(value) ~= "number" then return nil end
                local shown = i18n and i18n.format and i18n.format:number(value,
                    { precision = 1 }) or string.format("%.1f", value)
                if type(shown) ~= "string" then shown = string.format("%.1f", value) end
                return shown
            end
            add("numa.local_rate", "CPU-local pages/s",
                pages_per_second(rates.local_pages_per_second))
            add("numa.other_rate", "Cross-node pages/s",
                pages_per_second(rates.other_pages_per_second))
            add("numa.rate_quality", "Allocation rate quality",
                Technical.state(i18n, allocations.rate_quality))
            lines[#lines + 1] = translated(i18n, "numa.allocations_note",
                "These count page allocations, not memory accesses.")
        else
            add("numa.allocations_title", "Allocation locality (pages since boot)", nil)
        end
        for _, distance in ipairs(device.distances or {}) do
            add("numa.distance", "Distance (relative)",
                "node" .. distance.node_id .. " = " .. distance.distance)
        end
        if not device.distances then add("numa.distance", "Distance (relative)", nil) end
        local labels = {
            cpu_ids = { "numa.cpu_ids", "CPU IDs" }, memory = { "metrics.memory", "Memory" },
            distances = { "numa.distance", "Distance (relative)" }, online = { "cpu.online", "Online" },
            allocations = { "numa.allocations_title", "Allocation locality (pages since boot)" },
        }
        for _, issues in ipairs({ device.issues or {}, snapshot.numa and snapshot.numa.issues or {} }) do
            for _, issue in ipairs(issues) do
                local label = labels[issue.field]
                add("inspector.reason", "Reason", (label and translated(i18n, label[1], label[2])
                    or tostring(issue.field)) .. ": " .. tostring(Technical.state(i18n, issue.status)))
                add("metrics.source", "Source", issue.source)
            end
        end
    elseif node.kind == "policy" then
        local frequency = device.frequencies or {}
        add("metrics.governor", "Governor", device.governor)
        add("metrics.frequency", "Frequency", frequency.current_hz, "hertz")
        add("inspector.quality", "Quality", Technical.state(i18n, frequency.current_quality))
        add("metrics.source", "Source", frequency.current_source)
        if frequency.hardware_average_hz
            and frequency.current_source ~= "cpuinfo_avg_freq" then
            add("cpufreq.hardware_average", "Hardware average",
                frequency.hardware_average_hz, "hertz")
        end
        if frequency.scaling_current_hz
            and frequency.current_source ~= "scaling_cur_freq" then
            add("cpufreq.scaling_readout", "Scaling readout",
                frequency.scaling_current_hz, "hertz")
        end
        add("metrics.minimum", "Minimum", frequency.scaling_minimum_hz, "hertz")
        add("metrics.maximum", "Maximum", frequency.scaling_maximum_hz, "hertz")
        if node.temperature then
            local scope = node.temperature.scope == "core"
                and translated(i18n, "cpufreq.temperature_core", "Core")
                or translated(i18n, "cpufreq.temperature_package", "Package")
            add("cpufreq.related_temperature", "Related temp",
                scope .. " " .. format_value(node.temperature.celsius, i18n, "celsius"))
        end
    end
    if #node.thermal_throttle_cpu_ids > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "widgets.thermal_throttle",
            "Thermal throttling per CPU")
        local thermal_state = snapshot.quality and snapshot.quality.thermal_throttle
        if thermal_state then
            add("inspector.quality", "Quality", Technical.state(i18n, thermal_state.quality))
        end
        local function counter(value, delta, quality)
            local function shown(number)
                if type(number) ~= "number" then return "—" end
                local format = i18n and i18n.format
                if format then
                    local ok, text = pcall(format.number, format, number, { precision = 0 })
                    if ok and type(text) == "string" then return text end
                end
                return tostring(number)
            end
            local change = quality == "fresh" and type(delta) == "number"
                and ("+" .. shown(delta)) or Technical.state(i18n, quality or "gap")
            return shown(value) .. " (" .. change .. ")"
        end
        for index, cpu_id in ipairs(node.thermal_throttle_cpu_ids) do
            if index > 32 then break end
            local thread = graph.by_id["cpu:" .. cpu_id]
            local report = thread and thread.thermal_throttle
            if report then
                lines[#lines + 1] = inspector_text("  cpu" .. cpu_id .. " · "
                    .. translated(i18n, "thermal.core_total", "Core total") .. " "
                    .. counter(report.core_count, report.core_new, report.core_delta_quality)
                    .. " · " .. translated(i18n, "thermal.package_total", "Package total")
                    .. " " .. counter(report.package_count, report.package_new,
                        report.package_delta_quality), INSPECTOR_ROW_WIDTH)
                if report.core_total_time_ms ~= nil or report.package_total_time_ms ~= nil then
                    lines[#lines + 1] = inspector_text("    "
                        .. translated(i18n, "thermal.core_time", "Core ms") .. ": "
                        .. format_value(report.core_total_time_ms, i18n) .. " · "
                        .. translated(i18n, "thermal.package_time", "Package ms") .. ": "
                        .. format_value(report.package_total_time_ms, i18n),
                        INSPECTOR_ROW_WIDTH)
                end
            end
        end
        if #node.thermal_throttle_cpu_ids > 32 then
            lines[#lines + 1] = translated(i18n, "ui.rows_capped",
                "showing {visible} of {total}",
                { visible = 32, total = #node.thermal_throttle_cpu_ids })
        end
    end
    if #node.cpuidle_cpu_ids > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "widgets.cpuidle", "CPU idle states")
        local idle = snapshot.cpuidle or {}
        local idle_state = snapshot.quality and snapshot.quality.cpuidle
        if idle_state then
            add("inspector.quality", "Quality", Technical.state(i18n, idle_state.quality))
        end
        if node.kind == "thread" and node.cpuidle then
            add("metrics.driver", "Driver", idle.driver)
            add("metrics.governor", "Governor", idle.governor)
            local function delta(value, quality, milliseconds)
                if quality ~= "fresh" then
                    return Technical.state(i18n, quality or "gap")
                end
                if type(value) ~= "number" then return "—" end
                if milliseconds then
                    local amount = value / 1000
                    local format = i18n and i18n.format
                    if format then
                        local ok, shown = pcall(format.number, format, amount,
                            { precision = 1 })
                        if ok and type(shown) == "string" then return shown end
                    end
                    return string.format("%.1f", amount)
                end
                return format_value(value, i18n)
            end
            for index, state in ipairs(node.cpuidle.states or {}) do
                if index > 16 then break end
                if type(state) == "table" then
                    local label = type(state.name) == "string" and state.name ~= ""
                        and state.name or "state" .. tostring(state.id or "?")
                    lines[#lines + 1] = inspector_text("  " .. label .. " · "
                        .. translated(i18n, "cpuidle.usage_delta", "Usage Δ") .. ": "
                        .. delta(state.usage_delta, state.usage_delta_quality) .. " · "
                        .. translated(i18n, "cpuidle.reported_ms", "Reported ms Δ") .. ": "
                        .. delta(state.new_time_us, state.time_delta_quality, true),
                        INSPECTOR_ROW_WIDTH)
                    lines[#lines + 1] = inspector_text("    "
                        .. translated(i18n, "cpuidle.latency_us", "Exit latency µs") .. ": "
                        .. format_value(state.exit_latency_us, i18n) .. " · "
                        .. translated(i18n, "cpuidle.target_us", "Target µs") .. ": "
                        .. format_value(state.target_residency_us, i18n) .. " · "
                        .. translated(i18n, "cpuidle.disabled", "Disabled") .. ": "
                        .. format_value(state.disabled, i18n), INSPECTOR_ROW_WIDTH)
                    if state.rejected ~= nil or state.above ~= nil or state.below ~= nil
                        or state.rejected_delta ~= nil or state.above_delta ~= nil
                        or state.below_delta ~= nil then
                        lines[#lines + 1] = inspector_text("    "
                            .. translated(i18n, "cpuidle.rejected_delta", "Rejected Δ") .. ": "
                            .. delta(state.rejected_delta, state.rejected_delta_quality) .. " · "
                            .. translated(i18n, "cpuidle.above_delta", "Too short Δ") .. ": "
                            .. delta(state.above_delta, state.above_delta_quality) .. " · "
                            .. translated(i18n, "cpuidle.below_delta", "Deeper fit Δ") .. ": "
                            .. delta(state.below_delta, state.below_delta_quality),
                            INSPECTOR_ROW_WIDTH)
                    end
                end
            end
            if #node.cpuidle.states > 16 then
                lines[#lines + 1] = translated(i18n, "ui.rows_capped",
                    "showing {visible} of {total}",
                    { visible = 16, total = #node.cpuidle.states })
            end
        else
            add("cpuidle.cpus_reporting", "CPUs reporting idle states",
                #node.cpuidle_cpu_ids)
        end
    end
    if node.kind == "memory_device" then
        add("memory_hw.locator", "Position", device.locator)
        add("memory_hw.bank", "Bank", device.bank)
        add("memory_hw.populated", "Populated", device.populated)
        if device.logical then add("memory_hw.logical", "Logical", true) end
        add("metrics.capacity", "Size", device.size_bytes, "bytes")
        add("metrics.medium", "Type", device.memory_type)
        add("memory_hw.form_factor", "Form factor", device.form_factor)
        add("memory_hw.manufacturer", "Manufacturer", device.manufacturer)
        add("memory_hw.part_number", "Part number", device.part_number)
        add("memory_hw.firmware", "Firmware", device.firmware_version)
        add("memory_hw.rank", "Ranks", device.rank)
        add("memory_hw.data_width", "Data width (bits)", device.data_width_bits)
        add("memory_hw.total_width", "Total width (bits)", device.total_width_bits)
        add("memory_hw.rated_rate", "Rated data rate",
            device.speed_mts and format_value(device.speed_mts, i18n) .. " MT/s")
        add("memory_hw.configured_rate", "Configured rate",
            device.configured_speed_mts and format_value(device.configured_speed_mts, i18n) .. " MT/s")
        add("memory_hw.voltage", "Configured voltage",
            device.configured_voltage_mv and device.configured_voltage_mv / 1000, "volts")
        if #node.mapped_range_ids > 0 then
            add_list("memory_hw.mapped_ranges", "Firmware address ranges", node.mapped_range_ids)
        end
        if #node.channel_ids > 0 then
            local names = {}
            for _, channel_id in ipairs(node.channel_ids) do
                local channel = graph.by_id[channel_id]
                names[#names + 1] = channel and Hardware.label(channel, i18n) or channel_id
            end
            add_list("memory_hw.channels", "Firmware memory channels", names)
        end
        if node.edac_module_id then
            local module = graph.by_id[node.edac_module_id]
            add("edac.same_label_module", "Same-label EDAC module",
                module and (module.id .. " · " .. Hardware.label(module, i18n)))
            lines[#lines + 1] = translated(i18n, "edac.label_match_note",
                "Labels match; physical identity is not verified.")
        end
        lines[#lines + 1] = translated(i18n, "memory_hw.firmware_note", "Firmware report: inventory, settings and capabilities.")
    elseif node.kind == "memory_array" then
        add("memory_hw.positions", "Device positions", device.device_count)
        add("metrics.maximum", "Maximum", device.maximum_capacity_bytes, "bytes")
        local uses = { [3] = { "memory_hw.system_memory", "System memory" },
            [4] = { "memory_hw.video_memory", "Video memory" },
            [5] = { "memory_hw.flash", "Flash memory" },
            [6] = { "memory_hw.nvram", "Non-volatile RAM" },
            [7] = { "metrics.cache", "Cache" } }
        local use = uses[device.use_code]
        add("memory_hw.use", "Use", use and translated(i18n, use[1], use[2]))
        local corrections = { [3] = { "memory_hw.ecc_none", "None" },
            [4] = { "memory_hw.ecc_parity", "Parity" },
            [5] = { "memory_hw.ecc_single", "Single-bit ECC" },
            [6] = { "memory_hw.ecc_multi", "Multi-bit ECC" },
            [7] = { "memory_hw.ecc_crc", "CRC" } }
        local correction = corrections[device.error_correction_code]
        add("memory_hw.ecc", "Error correction", correction and translated(i18n, correction[1], correction[2]))
        if #node.mapped_range_ids > 0 then
            add_list("memory_hw.mapped_ranges", "Firmware address ranges", node.mapped_range_ids)
        end
        lines[#lines + 1] = translated(i18n, "memory_hw.firmware_note", "Firmware report: inventory, settings and capabilities.")
    elseif node.kind == "memory_array_range" or node.kind == "memory_device_range" then
        local address = device.start_address_bytes and device.end_address_bytes
            and string.format("0x%X–0x%X", device.start_address_bytes, device.end_address_bytes)
        add("memory_hw.address_range", "Mapped address range", address)
        add("memory_hw.address_span", "Address span", device.address_span_bytes, "bytes")
        if node.kind == "memory_array_range" then
            add("memory_hw.partition_width", "Partition width", device.partition_width)
        else
            local dimm = graph.by_id[node.memory_device_id]
            add("memory_hw.mapped_device", "Mapped memory device",
                dimm and Hardware.label(dimm, i18n))
            add("memory_hw.partition_row", "Partition row position", device.partition_row_position)
            add("memory_hw.interleave_position", "Interleave position", device.interleave_position)
            add("memory_hw.interleave_depth", "Interleaved data depth", device.interleaved_data_depth)
        end
        lines[#lines + 1] = translated(i18n, "memory_hw.range_note",
            "Firmware address mapping; spans can overlap when memory is interleaved.")
    elseif node.kind == "memory_channel" then
        add("memory_hw.channel_type", "Channel type", device.channel_type
            or device.channel_type_code)
        add("memory_hw.channel_max_load", "Maximum channel load", device.maximum_load)
        add("memory_hw.channel_total_load", "Reported channel load", device.total_load)
        add("memory_hw.channel_count", "Referenced memory devices", device.device_count)
        if #node.memory_device_ids > 0 then
            local names = {}
            for _, dimm_id in ipairs(node.memory_device_ids) do
                local dimm = graph.by_id[dimm_id]
                local label = dimm and Hardware.label(dimm, i18n) or dimm_id
                local load
                for _, entry in ipairs(device.devices or {}) do
                    if "dimm:" .. tostring(entry.device_id) == dimm_id then
                        load = entry.load
                        break
                    end
                end
                names[#names + 1] = label .. (load and " (" .. load .. ")" or "")
            end
            add_list("memory_hw.channel_devices", "Channel memory devices", names)
        end
        lines[#lines + 1] = translated(i18n, "memory_hw.channel_note",
            "Firmware channel loads are not measured memory bandwidth.")
    elseif node.kind == "processor_socket" then
        add("processor_fw.designation", "Socket designation", device.designation)
        add("memory_hw.manufacturer", "Manufacturer", device.manufacturer)
        add("metrics.model", "Model", device.version)
        add("memory_hw.part_number", "Part number", device.part_number)
        add("processor_fw.populated", "Socket populated", device.populated)
        local states = { [1] = { "processor_fw.enabled", "Enabled" },
            [2] = { "processor_fw.disabled_user", "Disabled in firmware setup" },
            [3] = { "processor_fw.disabled_firmware", "Disabled by firmware" },
            [4] = { "processor_fw.idle", "Waiting to be enabled" } }
        local state = states[device.status_code]
        add("processor_fw.status", "Firmware CPU status",
            state and translated(i18n, state[1], state[2]))
        add("processor_fw.cores", "Firmware core count", device.core_count)
        add("processor_fw.enabled_cores", "Enabled cores", device.enabled_core_count)
        add("processor_fw.threads", "Firmware thread count", device.thread_count)
        add("processor_fw.enabled_threads", "Enabled threads", device.enabled_thread_count)
        add("processor_fw.maximum_speed", "Socket maximum speed",
            device.max_speed_mhz and device.max_speed_mhz * 1000000, "hertz")
        add("processor_fw.boot_speed", "Boot speed",
            device.boot_speed_mhz and device.boot_speed_mhz * 1000000, "hertz")
        if #node.cache_ids > 0 then
            local names = {}
            for _, cache_id in ipairs(node.cache_ids) do
                local cache = graph.by_id[cache_id]
                names[#names + 1] = cache and Hardware.label(cache, i18n) or cache_id
            end
            add_list("processor_fw.caches", "Firmware cache records", names)
        end
        lines[#lines + 1] = translated(i18n, "processor_fw.note",
            "Firmware socket data; live CPU topology and speed come from the operating system.")
    elseif node.kind == "firmware_cache" then
        add("processor_fw.cache_designation", "Cache designation", device.designation)
        add("processor_fw.level", "Cache level", device.level)
        add("metrics.type", "Type", device.cache_type)
        add("processor_fw.enabled", "Enabled", device.enabled)
        add("metrics.capacity", "Installed size", device.installed_size_bytes, "bytes")
        add("metrics.maximum", "Maximum", device.maximum_size_bytes, "bytes")
        add("processor_fw.speed", "Cache speed", device.speed_ns
            and format_value(device.speed_ns, i18n) .. " ns")
        local corrections = { [3] = { "memory_hw.ecc_none", "None" },
            [4] = { "memory_hw.ecc_parity", "Parity" },
            [5] = { "memory_hw.ecc_single", "Single-bit ECC" },
            [6] = { "memory_hw.ecc_multi", "Multi-bit ECC" } }
        local correction = corrections[device.error_correction_code]
        add("memory_hw.ecc", "Error correction",
            correction and translated(i18n, correction[1], correction[2]))
        if #node.firmware_socket_ids > 1 then
            add_list("processor_fw.sockets", "Firmware socket references", node.firmware_socket_ids)
        end
        lines[#lines + 1] = translated(i18n, "processor_fw.cache_note",
            "Firmware cache report; operating-system cache measurements are separate.")
    elseif node.kind == "expansion_slot" then
        add("slot.designation", "Slot designation", device.designation)
        add("slot.type", "Slot type", device.slot_type)
        add("slot.slot_id", "Firmware slot ID", device.slot_id)
        local usage = { [1] = { "slot.other", "Other" },
            [2] = { "slot.unknown", "Unknown" },
            [3] = { "slot.available", "Available" },
            [4] = { "slot.in_use", "In use" },
            [5] = { "slot.unavailable", "Unavailable" } }
        local state = usage[device.usage_code]
        add("slot.usage", "Firmware usage", state and translated(i18n, state[1], state[2]))
        add("slot.electrical_width", "Maximum electrical width",
            device.electrical_lanes and "x" .. device.electrical_lanes)
        add("slot.firmware_address", "Firmware PCI address", device.pci_bdf)
        if #(device.peer_bdfs or {}) > 0 then
            add_list("slot.peer_address", "Peer PCI address", device.peer_bdfs)
        end
        if #node.pci_ids > 0 then
            add_list("slot.matched_pci", "Present PCI references", node.pci_ids)
        end
        lines[#lines + 1] = translated(i18n, "slot.firmware_note",
            "The firmware address is a reference; it does not prove which card occupies the slot.")
    elseif node.kind == "onboard_device" then
        add("onboard.structure_type", "SMBIOS type", device.structure_type)
        add("onboard.designation", "Reference designation", device.designation)
        add("onboard.type", "Onboard device type", device.device_type
            or device.device_type_code)
        add("onboard.enabled", "Enabled in firmware", device.enabled)
        if device.structure_type == 10 then
            add("onboard.entry", "Device entry", device.device_index)
            lines[#lines + 1] = translated(i18n, "onboard.legacy_note",
                "Legacy firmware declares this function without a PCI address.")
        else
            add("onboard.instance", "Type instance", device.type_instance)
            add("slot.firmware_address", "Firmware PCI address", device.pci_bdf)
            if #node.pci_ids > 0 then
                add_list("slot.matched_pci", "Present PCI references", node.pci_ids)
            end
            lines[#lines + 1] = translated(i18n, "onboard.note",
                "Firmware lists an onboard function; its PCI address is a reference to a present device.")
        end
    elseif node.kind == "port_connector" then
        add("port.internal_designation", "Internal reference", device.internal_designation)
        add("port.internal_type", "Internal connector",
            device.internal_connector or device.internal_connector_code)
        add("port.external_designation", "External reference", device.external_designation)
        add("port.external_type", "External connector",
            device.external_connector or device.external_connector_code)
        add("port.type", "Port function", device.port_type or device.port_type_code)
        lines[#lines + 1] = translated(i18n, "port.note",
            "Firmware describes a connector; it does not identify an operating-system device.")
    elseif node.kind == "firmware_battery" then
        add("firmware_battery.location", "Battery location", device.location)
        add("firmware_battery.name", "Battery name", device.name)
        add("memory_hw.manufacturer", "Manufacturer", device.manufacturer)
        add("firmware_battery.chemistry", "Battery chemistry",
            device.sbds_chemistry or device.chemistry or device.chemistry_code)
        add("firmware_battery.design_capacity", "Design capacity",
            device.design_capacity_mwh and device.design_capacity_mwh / 1000, "watt_hours")
        add("firmware_battery.design_voltage", "Design voltage",
            device.design_voltage_mv and device.design_voltage_mv / 1000, "volts")
        add("firmware_battery.maximum_error", "Maximum reported energy error",
            device.maximum_error_percent, "percent")
        add("firmware_battery.sbds_version", "Smart Battery version", device.sbds_version)
        lines[#lines + 1] = translated(i18n, "firmware_battery.note",
            "Firmware design values; current charge and health come from the operating system.")
    elseif node.kind == "firmware_bmc" then
        add("firmware_bmc.interface", "Interface", device.interface_type
            or device.interface_type_code)
        add("firmware_bmc.revision", "IPMI revision", device.ipmi_revision)
        add("firmware_bmc.i2c_address", "I2C target address",
            device.i2c_target_address and string.format("0x%02x", device.i2c_target_address))
        add("firmware_bmc.nv_storage", "Nonvolatile storage address",
            device.nv_storage_address and string.format("0x%02x", device.nv_storage_address))
        add("firmware_bmc.address_space", "Address space", device.address_space)
        add("firmware_bmc.base_address_field", "Base address field",
            device.base_address_field_hex ~= "0x0" and device.base_address_field_hex or nil)
        add("firmware_bmc.base_address", "Base address", device.base_address_hex)
        add("firmware_bmc.register_spacing", "Register spacing",
            device.register_spacing_bytes and tostring(device.register_spacing_bytes) .. " B")
        add("firmware_bmc.interrupt", "Interrupt", device.interrupt_number)
        lines[#lines + 1] = translated(i18n, "firmware_bmc.note",
            "Firmware declares an interface; current BMC availability is not measured.")
    elseif node.kind == "firmware_tpm" then
        add("firmware_tpm.vendor_id", "Vendor ID", device.vendor_id)
        add("firmware_tpm.spec_version", "TPM specification", device.spec_version)
        add("firmware_tpm.firmware_version_1", "Firmware version field 1",
            device.firmware_version_1_hex)
        add("firmware_tpm.firmware_version_2", "Firmware version field 2",
            device.firmware_version_2_hex)
        add("firmware_tpm.description", "Description", device.description)
        add("firmware_tpm.characteristics_supported", "Characteristics supported",
            device.characteristics_supported)
        if device.characteristics_supported then
            add("firmware_tpm.family_configurable_firmware",
                "Family configurable by firmware update", device.family_configurable_firmware)
            add("firmware_tpm.family_configurable_platform",
                "Family configurable by platform software", device.family_configurable_platform)
            add("firmware_tpm.family_configurable_oem",
                "Family configurable by OEM mechanism", device.family_configurable_oem)
        end
        lines[#lines + 1] = translated(i18n, "firmware_tpm.note",
            "Firmware describes a TPM; current availability and security state are not measured.")
    elseif node.kind == "firmware_component" then
        add("firmware_component.name", "Component", device.name)
        add("firmware_component.version", "Version", device.version)
        add("memory_hw.manufacturer", "Manufacturer", device.manufacturer)
        add("firmware_component.release_date", "Release date", device.release_date)
        add("firmware_component.minimum_version", "Lowest supported version",
            device.lowest_supported_version)
        add("firmware_component.guid", "Firmware GUID", device.firmware_id)
        add("firmware_component.image_size", "Image size",
            device.image_size_bytes or device.image_size_hex,
            device.image_size_bytes and "bytes" or nil)
        add("firmware_component.updatable", "Software updatable", device.updatable)
        add("firmware_component.write_protected", "Write-protected", device.write_protected)
        add("firmware_component.state", "Firmware state",
            device.state or device.state_code)
        if device.associated_count and device.associated_count > 0 then
            add("firmware_component.associated_count", "Associated handles",
                device.associated_count)
            add_list("firmware_component.associated_handles", "SMBIOS handles",
                device.associated_handles or {})
        end
        if #node.associated_ids > 0 then
            local names = {}
            for _, target_id in ipairs(node.associated_ids) do
                local target = graph.by_id[target_id]
                names[#names + 1] = target and Hardware.label(target, i18n) or target_id
            end
            add_list("firmware_component.associated_devices", "Associated devices", names)
        end
        if #node.esrt_ids > 0 then
            local names = {}
            for _, target_id in ipairs(node.esrt_ids) do
                local target = graph.by_id[target_id]
                names[#names + 1] = target and Hardware.label(target, i18n) or target_id
            end
            add_list("firmware_esrt.references", "UEFI firmware resources", names)
        end
        lines[#lines + 1] = translated(i18n, "firmware_component.note",
            "Firmware inventory declaration; live health and update availability are not measured.")
    elseif node.kind == "esrt_firmware" then
        add("firmware_esrt.guid", "Firmware class GUID", device.guid)
        add("firmware_esrt.type", "Resource type", device.type or device.type_code)
        add("firmware_esrt.version", "Installed version", device.version)
        add("firmware_esrt.minimum_version", "Lowest supported version",
            device.lowest_supported_version)
        add("firmware_esrt.flags", "Capsule flags", device.capsule_flags_hex)
        add("firmware_esrt.last_attempt_version", "Last attempted version",
            device.last_attempt_version)
        add("firmware_esrt.last_attempt_status", "Last attempt code",
            device.last_attempt_status)
        if device.status ~= "ok" then
            add("inspector.status", "Status", Technical.state(i18n, device.status))
        end
        lines[#lines + 1] = translated(i18n, "firmware_esrt.note",
            "Code 0 can also mean no update was attempted; this is not live health or update availability.")
    elseif node.kind == "os_tpm" then
        add("tpm.version_major", "TPM specification major",
            device.version_minor and (tostring(device.version_major) .. "."
                .. tostring(device.version_minor)) or device.version_major)
        add("tpm.driver", "Kernel driver", device.driver)
        if device.active ~= nil then add("tpm.active", "Accepting commands", device.active) end
        if device.enabled ~= nil then add("tpm.enabled", "Enabled", device.enabled) end
        if device.temporarily_deactivated ~= nil then
            add("tpm.temp_deactivated", "Temporarily deactivated",
                device.temporarily_deactivated)
        end
        local banks = {}
        for _, bank in ipairs(device.banks or {}) do
            banks[#banks + 1] = bank.algorithm
                .. (bank.pcr_count and " (" .. bank.pcr_count .. ")" or "")
        end
        if #banks > 0 then add_list("tpm.banks", "PCR bank directories", banks) end
        lines[#lines + 1] = translated(i18n, "tpm.note",
            "Linux registered this TPM; PCR values, keys and security posture were not read.")
    elseif node.kind == "watchdog" then
        add("watchdog.identity", "Identity", device.identity)
        add("watchdog.driver", "Kernel driver", device.driver)
        add("watchdog.state", "State", device.state and translated(i18n,
            "watchdog." .. device.state, device.state))
        add("watchdog.timeout", "Programmed timeout", device.timeout_seconds, "seconds")
        if device.state == "active" then
            add("watchdog.timeleft", "Time until reset", device.timeleft_seconds, "seconds")
        end
        add("watchdog.pretimeout", "Pre-timeout", device.pretimeout_seconds, "seconds")
        add("watchdog.nowayout", "Cannot be stopped once started", device.nowayout)
        add("watchdog.status", "Raw status bits",
            device.status and string.format("0x%x", device.status))
        add("watchdog.bootstatus", "Raw boot status bits",
            device.bootstatus and string.format("0x%x", device.bootstatus))
        add("watchdog.firmware_version", "Firmware version", device.firmware_version)
        add("watchdog.governor", "Pre-timeout governor", device.pretimeout_governor)
        lines[#lines + 1] = translated(i18n, "watchdog.note",
            "Read-only sysfs status; no watchdog device was opened or kept alive.")
    elseif node.kind == "typec_port" then
        local port = TypeC.port(snapshot, device)
        add("inspector.quality", "Quality", Technical.state(i18n, port.quality))
        add("typec.data_role", "Reported data role", port.data_role)
        add_list("typec.data_roles", "Available data roles", port.data_roles)
        add("typec.power_role", "Reported power role", port.power_role)
        add_list("typec.power_roles", "Available power roles", port.power_roles)
        add("typec.port_type", "Configured port type", port.port_type)
        add("typec.preferred_role", "Preferred power role", port.preferred_role)
        add("typec.operation_mode", "Reported power mode", port.power_operation_mode)
        add("typec.orientation", "Reported orientation", port.orientation)
        add("typec.vconn", "VCONN source", port.vconn_source)
        add("typec.typec_revision", "Supported Type-C revision", port.usb_typec_revision)
        add("typec.pd_revision", "Supported PD revision", port.usb_power_delivery_revision)
        add("typec.usb_default", "Default next USB mode", port.usb_default_mode)
        add_list("typec.usb_capabilities", "Supported USB modes", port.usb_capabilities)
        add("typec.partner_seen", "Partner object observed", port.partner_observed)
        add("typec.cable_seen", "Cable object observed", port.cable_observed)
        for _, kind in ipairs({ "partner", "cable" }) do
            local child = port[kind]
            if child then
                add("typec.object", "Class object", child.id)
                add("typec.object_type", "Object type", child.type or child.accessory_mode)
                add("typec.pd_revision", "Supported PD revision", child.usb_power_delivery_revision)
                if child.plug_type then add("typec.plug_type", "Cable plug type", child.plug_type) end
                if child.usb_mode then add("typec.usb_mode", "Partner USB mode", child.usb_mode) end
            end
        end
        if port.pd_id then add("typec.related_pd", "Linked PD object", port.pd_id) end
        lines[#lines + 1] = translated(i18n, "typec.note",
            "Driver roles and capabilities; no selected contract or delivered power is inferred.")
    elseif node.kind == "usb_pd" then
        local pd = TypeC.pd(snapshot, device)
        add("inspector.quality", "Quality", Technical.state(i18n, pd.quality))
        add("typec.object_revision", "PD object revision", pd.revision)
        add("typec.object_version", "PD object version", pd.version)
        for _, direction in ipairs({ "source", "sink" }) do
            local label = direction == "source" and "typec.source_profiles" or "typec.sink_profiles"
            add(label, direction == "source" and "Source capabilities" or "Sink requirements",
                Technical.state(i18n, pd.capability_status[direction]))
        end
        for _, profile in ipairs(pd.profiles) do
            lines[#lines + 1] = ""
            add("typec.profile", "Declared PDO", profile.direction .. " · " .. profile.id)
            for _, spec in ipairs({
                { "voltage_volts", "typec.voltage", "Declared voltage", "volts" },
                { "minimum_voltage_volts", "typec.minimum_voltage", "Minimum declared voltage", "volts" },
                { "maximum_voltage_volts", "typec.maximum_voltage", "Maximum declared voltage", "volts" },
                { "maximum_current_amperes", "typec.maximum_current", "Maximum declared current", "amperes" },
                { "operational_current_amperes", "typec.operational_current", "Required operating current", "amperes" },
                { "maximum_power_watts", "typec.maximum_power", "Maximum declared power", "watts" },
                { "operational_power_watts", "typec.operational_power", "Required operating power", "watts" },
                { "maximum_current_9V_to_15V_amperes", "typec.current_9_15", "Maximum current at 9–15 V", "amperes" },
                { "maximum_current_15V_to_20V_amperes", "typec.current_15_20", "Maximum current at 15–20 V", "amperes" },
            }) do
                if profile[spec[1]] ~= nil then add(spec[2], spec[3], profile[spec[1]], spec[4]) end
            end
            for _, key in ipairs({ "peak_current_code", "fast_role_swap_current_code", "dual_role_power",
                "usb_suspend_supported", "higher_capability", "unconstrained_power", "usb_communication_capable",
                "dual_role_data", "unchunked_extended_messages_supported", "pps_power_limited" }) do
                if profile[key] ~= nil then add("typec.flag." .. key, key, profile[key]) end
            end
            add("inspector.quality", "Quality", Technical.state(i18n, profile.quality))
            add("metrics.source", "Source", profile.source)
        end
        lines[#lines + 1] = translated(i18n, "typec.pdo_note",
            "PDOs declare supply capabilities or sink requirements, not active limits or live readings.")
    elseif node.kind == "rfkill" then
        add("rfkill.name", "Switch name", device.name)
        add("rfkill.type", "Radio type", device.type)
        add("rfkill.hard_blocked", "Hardware blocked", device.hard_blocked)
        add("rfkill.soft_blocked", "Software blocked", device.soft_blocked)
        add("rfkill.blocked", "RF blocked", device.blocked)
        add("rfkill.persistent", "Software block persisted", device.persistent)
        if device.state_source == "legacy" then
            lines[#lines + 1] = translated(i18n, "rfkill.legacy_note",
                "Legacy state cannot show hardware and software blocks together.")
        end
        lines[#lines + 1] = translated(i18n, "rfkill.note",
            "Unblocked does not mean connected; wtop does not change this switch.")
    elseif node.kind == "thermal_zone" then
        add("thermal_zone.type", "Zone type", device.type)
        add("thermal_zone.temperature", "Temperature",
            device.temperature_celsius, "celsius")
        add("thermal_zone.mode", "Mode", device.mode)
        add("thermal_zone.policy", "Policy", device.policy)
        for _, trip in ipairs(device.trips or {}) do
            add("thermal_zone.trip", "Trip point",
                tostring(trip.index) .. " · " .. tostring(trip.type or "?")
                    .. " · " .. format_value(trip.temperature_celsius, i18n, "celsius"))
        end
        add("thermal_zone.cooling_count", "Bound cooling devices", #node.cooling_ids)
        for _, binding in ipairs(device.bindings or {}) do
            local target = graph.by_id["cooling-device:" .. tostring(binding.cooling_id)]
            add("thermal_zone.cooling_link", "Cooling link",
                (target and Hardware.label(target, i18n) or binding.cooling_id)
                    .. (binding.trip_index and " · "
                        .. translated(i18n, "thermal_zone.trip", "Trip point")
                        .. " " .. binding.trip_index or ""))
        end
        lines[#lines + 1] = translated(i18n, "thermal_zone.note",
            "Kernel thermal readings; a trip point is a threshold, not a predicted shutdown time.")
    elseif node.kind == "cooling_device" then
        add("cooling_device.type", "Cooling type", device.type)
        add("cooling_device.current", "Current state", device.cur_state)
        add("cooling_device.maximum", "Maximum state", device.max_state)
        add("cooling_device.zones", "Bound thermal zones", #node.thermal_zone_ids)
        if type(device.stats) == "table" then
            add("cooling_device.transitions", "Transitions since stats reset",
                device.stats.total_transitions)
            local times, total = {}, 0
            for _, state in ipairs(device.stats.time_in_state_ms or {}) do
                if type(state.milliseconds) == "number" and state.milliseconds > 0 then
                    total = total + 1
                    if #times < 16 then
                        times[#times + 1] = tostring(state.state) .. " = "
                            .. tostring(state.milliseconds) .. " ms"
                    end
                end
            end
            if #times > 0 then
                add_list("cooling_device.state_time", "Time in state", times)
            end
            if total > #times then
                lines[#lines + 1] = translated(i18n, "ui.rows_capped",
                    "showing {visible} of {total}",
                    { visible = #times, total = total })
            end
            lines[#lines + 1] = translated(i18n, "cooling_device.stats_note",
                "Counters are cumulative since reset; no transition rate is inferred.")
        end
        lines[#lines + 1] = translated(i18n, "cooling_device.note",
            "Cooling states are device-specific; they are not fan speed or percent.")
    elseif node.kind == "platform_firmware" then
        add("memory_hw.manufacturer", "Manufacturer", device.vendor)
        add("firmware_component.version", "Version", device.version)
        add("firmware_component.release_date", "Release date", device.release_date)
        add("firmware_platform.revision", "Firmware revision", device.firmware_revision)
        add("firmware_platform.controller", "Embedded controller revision", device.controller_revision)
        add("firmware_platform.rom", "Firmware ROM capacity", device.rom_size_bytes, "bytes")
        if not device.rom_size_bytes and device.rom_size_minimum_bytes then
            add("firmware_platform.rom_minimum", "Firmware ROM lower bound", device.rom_size_minimum_bytes, "bytes")
        end
        add("firmware_platform.runtime", "Legacy runtime BIOS area", device.runtime_area_bytes, "bytes")
        add("firmware_platform.mask", "Standard characteristics", device.characteristics_hex)
        add("firmware_platform.known", "Base characteristics known", device.characteristics_known)
        local features = device.features or {}
        for _, feature in ipairs({ { "pci", "PCI" }, { "acpi", "ACPI" }, { "uefi", "UEFI" } }) do
            add("firmware_platform.support", "Declared support",
                feature[2] .. " · " .. format_value(features[feature[1]], i18n))
        end
        add("firmware_platform.flash", "Firmware upgrade supported", features.upgradeable)
        add("firmware_platform.socketed", "Firmware ROM socketed", features.rom_socketed)
        add("firmware_platform.usb", "Legacy USB supported", features.usb_legacy)
        add("firmware_platform.vm", "Virtual machine reported", device.virtual_machine_reported)
        add("firmware_platform.manufacturing_support", "Manufacturing mode supported", device.manufacturing_mode_supported)
        add("firmware_platform.manufacturing_enabled", "Manufacturing mode reported enabled", device.manufacturing_mode_enabled)
        local names = {}
        for _, feature in ipairs(require("wtop.format.smbios").PLATFORM_FEATURES) do
            if features[feature[1]] then names[#names + 1] = feature[4] end
        end
        add_list("firmware_platform.features", "Declared supported interfaces", names)
        lines[#lines + 1] = translated(i18n, "firmware_platform.note",
            "Firmware declarations; UEFI support is not the current boot method or Secure Boot state.")
        lines[#lines + 1] = translated(i18n, "firmware_platform.vm_note",
            "An unset VM flag does not establish that this is a physical machine.")
    elseif node.kind == "firmware_system" then
        add("memory_hw.manufacturer", "Manufacturer", device.manufacturer)
        add("metrics.model", "Model", device.product)
        add("firmware_component.version", "Version", device.version)
        add("enclosure.sku", "SKU", device.sku)
        add("firmware_platform.family", "Product family", device.family)
        add("firmware_platform.wake", "Firmware-reported wake-up type", device.wake_type or device.wake_type_code)
        lines[#lines + 1] = translated(i18n, "firmware_platform.system_note",
            "SMBIOS system declarations; serial numbers and UUID values are omitted.")
    elseif node.kind == "baseboard" then
        add("memory_hw.manufacturer", "Manufacturer", device.manufacturer)
        add("metrics.model", "Model", device.product)
        add("firmware_component.version", "Version", device.version)
        add("enclosure.board_type", "Board type", device.board_type or device.board_type_code)
        add("enclosure.location", "Location in chassis", device.location)
        add("enclosure.chassis_handle", "Declared chassis handle", device.chassis_handle)
        if device.feature_flags ~= nil then
            add("enclosure.flags", "Feature flags", string.format("0x%02x", device.feature_flags))
            for _, feature in ipairs({ { 0, "hosting", "Hosting board" },
                { 1, "daughter", "Requires a daughterboard" }, { 2, "removable", "Removable" },
                { 3, "replaceable", "Replaceable" }, { 4, "hot_swap", "Hot-swappable" } }) do
                add("enclosure.feature." .. feature[2], feature[3],
                    device.feature_flags & (1 << feature[1]) ~= 0)
            end
        end
        add("enclosure.contained_count", "Declared element count", device.contained_count)
        add_list("enclosure.handles", "Declared contained handles", device.contained_handles or {})
        lines[#lines + 1] = translated(i18n, "enclosure.board_note",
            "Firmware board declarations; only explicit, unambiguous handles establish device links.")
    elseif node.kind == "enclosure" then
        add("memory_hw.manufacturer", "Manufacturer", device.manufacturer)
        add("enclosure.chassis_type", "Chassis type", device.chassis_type or device.chassis_type_code)
        add("firmware_component.version", "Version", device.version)
        add("enclosure.sku", "SKU", device.sku)
        add("enclosure.lock", "Lock reported present", device.lock_reported_present)
        add("enclosure.height", "Rack height", device.height_u and tostring(device.height_u) .. " U"
            or device.height_ou and tostring(device.height_ou) .. " OU")
        add("enclosure.cords", "Power cords", device.power_cords)
        for _, field in ipairs({ { "boot_state", "Boot state at last boot" },
            { "power_state", "Power supply state at last boot" },
            { "thermal_state", "Thermal state at last boot" },
            { "security_state", "Security state at last boot" } }) do
            add("enclosure." .. field[1], field[2], device[field[1]] or device[field[1] .. "_code"])
        end
        add("enclosure.contained_count", "Declared element count", device.contained_count)
        local elements = {}
        for _, element in ipairs(device.contained_elements or {}) do
            elements[#elements + 1] = (element.type_kind == "structure" and "SMBIOS "
                .. tostring(element.type_code) or element.board_type or tostring(element.type_code))
                .. " " .. tostring(element.minimum) .. ".." .. tostring(element.maximum)
        end
        add_list("enclosure.elements", "Declared element types and ranges", elements)
        lines[#lines + 1] = translated(i18n, "enclosure.element_note",
            "Element ranges are firmware declarations, not measured installed counts.")
        lines[#lines + 1] = translated(i18n, "enclosure.note",
            "SMBIOS enclosure states describe the last boot; they are not live health readings.")
    elseif node.kind == "host_interface" then
        add("host_interface.type", "Interface type", device.interface_type
            or device.interface_type_code)
        add("host_interface.type_code", "Interface type code",
            device.interface_type_code and string.format("0x%02x", device.interface_type_code))
        add("host_interface.oem_vendor", "OEM vendor ID", device.oem_vendor_id)
        if device.legacy_oem_format then
            add("host_interface.legacy_oem", "Legacy OEM layout", true)
        end
        add("host_interface.interface_bytes", "Interface data length",
            device.interface_data_bytes, "bytes")
        add("host_interface.protocol_count", "Declared protocol count", device.protocol_count)
        local names = {}
        for _, protocol in ipairs(device.protocols or {}) do
            names[#names + 1] = protocol.type
                or string.format("0x%02x", protocol.type_code or 0)
        end
        if #names > 0 then
            add_list("host_interface.protocol", "Declared protocols", names)
        end
        lines[#lines + 1] = translated(i18n, "host_interface.note",
            "Firmware declares a host interface; live controller access is not measured.")
    elseif node.kind == "firmware_power_supply" then
        add("firmware_psu.location", "Supply location", device.location)
        add("firmware_psu.name", "Supply name", device.name)
        add("memory_hw.manufacturer", "Manufacturer", device.manufacturer)
        add("memory_hw.part_number", "Part number", device.part_number)
        add("firmware_psu.revision", "Revision", device.revision)
        add("firmware_psu.max_power", "Maximum sustained output",
            device.max_power_watts, "watts")
        add("firmware_psu.type", "Supply type", device.supply_type
            or device.supply_type_code)
        add("firmware_psu.status", "Firmware status", device.status
            or device.status_code)
        add("firmware_psu.range", "Input voltage switching", device.range_switching
            or device.range_switching_code)
        add("firmware_psu.present", "Firmware says present", device.present)
        add("firmware_psu.unplugged", "Firmware says unplugged", device.unplugged)
        add("firmware_psu.hot_replaceable", "Hot-replaceable", device.hot_replaceable)
        add("firmware_psu.group", "Power unit group",
            device.power_unit_group and device.power_unit_group > 0
                and device.power_unit_group or nil)
        if #node.redundant_peer_ids > 0 then
            local names = {}
            for _, peer_id in ipairs(node.redundant_peer_ids) do
                local peer = graph.by_id[peer_id]
                names[#names + 1] = peer and Hardware.label(peer, i18n) or peer_id
            end
            add_list("firmware_psu.peers", "Firmware redundancy peers", names)
        end
        add("firmware_psu.voltage_probe", "Voltage probe handle", device.voltage_probe_id)
        add("firmware_psu.cooling_device", "Cooling device handle", device.cooling_device_id)
        add("firmware_psu.current_probe", "Current probe handle", device.current_probe_id)
        for _, spec in ipairs({ { "firmware_probe_ids", "firmware_probe.related_probes", "Related firmware probes" },
            { "firmware_cooling_ids", "firmware_probe.related_cooling", "Related firmware cooling devices" } }) do
            local labels = {}
            for _, id in ipairs(node[spec[1]]) do
                local target = graph.by_id[id]
                labels[#labels + 1] = target and Hardware.label(target, i18n) or id
            end
            if #labels > 0 then add_list(spec[2], spec[3], labels) end
        end
        lines[#lines + 1] = translated(i18n, "firmware_psu.note",
            "Firmware capacity and status are declarations, not live power or health readings.")
    elseif node.kind == "firmware_probe" or node.kind == "firmware_cooling" then
        lines[#lines + 1] = translated(i18n, "firmware_probe.note",
            "Firmware declarations only; no live readings or alarm thresholds.")
        local function value(number, unit)
            local suffix = ({ volts = "V", celsius = "C", amperes = "A" })[unit]
            if type(number) == "number" and suffix then return string.format("%.6g %s", number, suffix) end
        end
        add("firmware_probe.description", "Description", device.description)
        add("firmware_probe.status", "Firmware status", device.status or device.status_code)
        if node.kind == "firmware_probe" then
            add("firmware_probe.type", "Probe kind", device.probe_type)
            add("firmware_probe.location", "Firmware location", device.location or device.location_code)
            add("firmware_probe.minimum", "Readable minimum", value(device.minimum, device.unit))
            add("firmware_probe.maximum", "Readable maximum", value(device.maximum, device.unit))
            add("firmware_probe.nominal", "Nominal value", value(device.nominal_value, device.unit))
            add("firmware_probe.resolution", "Resolution", value(device.resolution, device.unit))
            add("firmware_probe.tolerance", "Tolerance", value(device.tolerance, device.unit))
            add("firmware_probe.accuracy", "Accuracy (%)", device.accuracy_percent)
        else
            add("firmware_probe.cooling_type", "Cooling device type", device.device_type or device.device_type_code)
            add("firmware_probe.nominal_speed", "Nominal speed (rpm)", device.nominal_speed_rpm)
            add("firmware_probe.group", "Cooling unit group", device.cooling_unit_group)
            add("firmware_probe.temperature_handle", "Temperature probe handle", device.temperature_probe_id)
            local peers = {}
            for _, id in ipairs(node.redundant_peer_ids) do
                local target = graph.by_id[id]
                peers[#peers + 1] = target and Hardware.label(target, i18n) or id
            end
            if #peers > 0 then add_list("firmware_psu.peers", "Firmware redundancy peers", peers) end
        end
        for _, spec in ipairs({ { "firmware_probe_ids", "firmware_probe.related_probes", "Related firmware probes" },
            { "firmware_cooling_ids", "firmware_probe.related_cooling", "Related firmware cooling devices" },
            { "power_supply_ids", "firmware_probe.related_supplies", "Related firmware power supplies" } }) do
            local labels = {}
            for _, id in ipairs(node[spec[1]]) do
                local target = graph.by_id[id]
                labels[#labels + 1] = target and Hardware.label(target, i18n) or id
            end
            if #labels > 0 then add_list(spec[2], spec[3], labels) end
        end
    elseif node.kind == "edac_controller" or node.kind == "edac_module" then
        if node.kind == "edac_controller" then
            add("edac.name", "Controller name", device.name)
        else
            add("edac.label", "Module label", device.label)
            add("edac.location", "Controller location", device.location)
            if node.memory_device_id then
                local dimm = graph.by_id[node.memory_device_id]
                add("edac.same_label_slot", "Same-label firmware slot",
                    dimm and (dimm.id .. " · " .. Hardware.label(dimm, i18n)))
                lines[#lines + 1] = translated(i18n, "edac.label_match_note",
                    "Labels match; physical identity is not verified.")
            end
        end
        add("edac.correctable", "Correctable errors", device.correctable_errors)
        add("edac.uncorrectable", "Uncorrectable errors", device.uncorrectable_errors)
        for _, issue in ipairs(device.issues or {}) do
            add("inspector.reason", "Reason", tostring(issue.field) .. ": "
                .. tostring(Technical.state(i18n, issue.status)))
            add("metrics.source", "Source", issue.source)
        end
    elseif node.kind == "spd_device" then
        add("metrics.medium", "Type", device.memory_type)
        add("spd.module_type", "Module type", device.module_type)
        add("spd.revision", "SPD revision", device.revision)
        add("metrics.capacity", "Size", device.size_bytes, "bytes")
        add("memory_hw.rank", "Ranks", device.rank)
        add("spd.module_banks", "Module banks", device.module_banks)
        add("memory_hw.data_width", "Data width (bits)", device.data_width_bits)
        add("memory_hw.total_width", "Total width (bits)", device.total_width_bits)
        add("spd.minimum_cycle", "Minimum cycle", device.minimum_cycle_ps
            and format_value(device.minimum_cycle_ps, i18n) .. " ps")
        if device.memory_type == "DDR3" or device.memory_type == "DDR4" then
            add("spd.sensor_present", "Temperature sensor indicated",
                device.temperature_sensor_present)
        end
        add("memory_hw.part_number", "Part number", device.part_number)
        add("spd.bytes_read", "SPD bytes read", device.bytes_read)
        if device.memory_type == "DDR3" or device.memory_type == "DDR4" then
            add("spd.base_crc", "Base SPD CRC valid", device.crc_base_valid)
        end
        add("spd.crc", "SPD CRC valid", device.crc_valid)
        add("spd.checksum", "SPD checksum valid", device.checksum_valid)
        for _, issue in ipairs(device.issues or {}) do
            add("inspector.reason", "Reason", tostring(issue.field)
                .. (issue.offset and " @" .. issue.offset or "") .. ": "
                .. tostring(Technical.reason(i18n, issue.reason)))
            add("metrics.source", "Source", issue.source)
        end
        lines[#lines + 1] = translated(i18n, "spd.capability_note",
            "SPD describes module capabilities, not the current memory clock.")
    elseif node.kind == "usb_interface" then
        local function hex_byte(value)
            return type(value) == "number" and string.format("%02x", value) or nil
        end
        add("inventory.usb_interface_name", "Interface", device.interface)
        add("inventory.usb_interface_number", "Interface number", device.interface_number)
        add("inventory.usb_alternate", "Alternate setting", device.alternate_setting)
        add("inventory.usb_endpoints", "Endpoints", device.endpoint_count)
        add("inventory.class", "Class", hex_byte(device.class_id))
        add("inventory.usb_subclass", "Subclass", hex_byte(device.subclass_id))
        add("inventory.usb_protocol", "Protocol", hex_byte(device.protocol_id))
        require("wtop.ui.usb_endpoints").append(device.endpoint_details, add, lines, i18n,
            Quality.current_source(snapshot.quality, "inventory"))
    end
    if node.bus == "pci" then
        add("inventory.class", "Class", hardware_hex(device.class_id, 6))
        add("inventory.revision", "Revision", hardware_hex(device.revision, 2))
        local function pcie(rate, width)
            if rate == nil and width == nil then return nil end
            return format_value(rate, i18n) .. " GT/s x " .. format_value(width, i18n)
        end
        add("inventory.link", "PCIe link", pcie(device.link_speed_gtps, device.link_width))
        add("inventory.max_link", "Maximum PCIe link",
            pcie(device.max_link_speed_gtps, device.max_link_width))
        add("inventory.numa_node", "NUMA node", device.numa_node)
        local msi = type(device.msi) == "table" and device.msi or nil
        if msi then
            local vectors = type(msi.vectors) == "table" and msi.vectors or {}
            lines[#lines + 1] = ""
            lines[#lines + 1] = translated(i18n, "inventory.msi_title",
                "MSI interrupt vectors")
            add("inventory.msi_vectors", "Visible vectors", #vectors)
            if msi.status ~= "ok" then
                add("inventory.msi_status", "Vector status",
                    Technical.state(i18n, msi.status))
            end
            if msi.count_status and msi.count_status ~= "ok" then
                add("inventory.msi_count_status", "Count status",
                    Technical.state(i18n, msi.count_status))
            end
            if msi.affinity_status and msi.affinity_status ~= "ok" then
                add("inventory.msi_affinity_status", "IRQ affinity status",
                    Technical.state(i18n, msi.affinity_status))
            end
            if msi.total ~= nil then
                add("inventory.msi_total", "Interrupts observed", msi.total)
            end
            local change = msi.change
            if type(change) == "table" then
                if change.quality == "fresh" then
                    add("inventory.msi_new", "New since previous scan",
                        change.new_interrupts)
                elseif change.quality == "reset" then
                    add("inventory.msi_new", "New since previous scan",
                        Technical.state(i18n, "reset"))
                end
            end
            local ranked = {}
            for _, vector in ipairs(vectors) do ranked[#ranked + 1] = vector end
            table.sort(ranked, function(left, right)
                if left.total == nil then return false end
                if right.total == nil then return true end
                return left.total > right.total
                    or left.total == right.total and left.irq < right.irq
            end)
            for index = 1, math.min(#ranked, 8) do
                local vector = ranked[index]
                local mode = vector.mode == "msix" and "MSI-X"
                    or vector.mode == "msi" and "MSI" or "—"
                add("inventory.msi_vector", "IRQ vector",
                    "IRQ " .. tostring(vector.irq) .. " · " .. mode .. " · "
                        .. format_value(vector.total, i18n))
                if vector.effective_affinity then
                    add("inventory.msi_effective", "Effective CPU list",
                        vector.effective_affinity)
                end
                if vector.allowed_affinity
                    and vector.allowed_affinity ~= vector.effective_affinity then
                    add("inventory.msi_allowed", "Allowed CPU list",
                        vector.allowed_affinity)
                end
                local top = vector.top_cpus and vector.top_cpus[1]
                if top then
                    add("inventory.msi_top_cpu", "Top CPU (cumulative)",
                        "CPU" .. tostring(top.cpu_id) .. " · "
                            .. format_value(top.count, i18n))
                end
            end
            if #ranked > 8 then
                add("inventory.msi_more", "More vectors", #ranked - 8)
            end
        end
        if type(device.iommu_group_id) == "number" then
            local group = graph.iommu_groups_by_id[device.iommu_group_id]
            lines[#lines + 1] = ""
            lines[#lines + 1] = translated(i18n, "inventory.iommu_title",
                "IOMMU group") .. " " .. tostring(device.iommu_group_id)
            if type(group) == "table" and type(group.members) == "table" then
                add("inventory.iommu_members", "Group members", #group.members)
                add_list("inventory.iommu_member_names", "Member names", group.members)
            end
            add("inventory.iommu_peers", "Visible PCI peers", #node.iommu_peer_ids)
            if #node.iommu_peer_ids > 0 then
                add_list("inventory.iommu_peer_refs", "PCI peer references",
                    node.iommu_peer_ids)
            end
            if type(group) ~= "table" or group.status ~= "ok"
                or node.iommu_group_membership_confirmed == false then
                local status = type(group) == "table" and group.status or "partial"
                if node.iommu_group_membership_confirmed == false then status = "partial" end
                add("inventory.iommu_status", "Group status",
                    Technical.state(i18n, status or "partial"))
            end
        end
        local sriov = type(device.sriov) == "table" and device.sriov or nil
        if sriov then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "SR-IOV"
            add("inventory.sriov_role", "Function",
                sriov.role == "pf" and "PF" or sriov.role == "vf" and "VF" or "PF / VF?")
            if sriov.role == "pf" or sriov.role == "ambiguous" then
                add("inventory.sriov_total", "VF capacity", sriov.total_vfs)
                add("inventory.sriov_enabled", "Enabled VFs", sriov.enabled_vfs)
                add("inventory.sriov_visible", "Visible VFs", #node.vf_ids)
                if #node.vf_ids > 0 then
                    add_list("inventory.sriov_vfs", "VF references", node.vf_ids)
                end
            end
            if sriov.role == "vf" or sriov.role == "ambiguous" then
                add("inventory.sriov_pf", "Physical function",
                    node.pf_id or sriov.physical_function_address)
            end
            if sriov.status ~= "ok" or node.sriov_membership_complete == false then
                add("inspector.quality", "Quality", Technical.state(i18n, "partial"))
            end
            lines[#lines + 1] = translated(i18n, "inventory.sriov_note",
                "PF/VF references are separate from the PCI bus parent.")
        end
        local aer = type(device.aer) == "table" and device.aer or nil
        if aer then
            lines[#lines + 1] = ""
            lines[#lines + 1] = translated(i18n, "inventory.aer_title",
                "PCIe AER reports since boot")
            if aer.interval_seconds then
                add("inventory.aer_interval", "Scan interval",
                    aer.interval_seconds, "seconds")
            end
            if aer.status ~= "ok" then
                add("inventory.aer_status", "AER status",
                    Technical.state(i18n, aer.status))
            end
            for _, specification in ipairs({
                { "correctable", "inventory.aer_correctable", "Correctable" },
                { "nonfatal", "inventory.aer_nonfatal", "Nonfatal" },
                { "fatal", "inventory.aer_fatal", "Fatal" },
            }) do
                local stats = type(aer[specification[1]]) == "table"
                    and aer[specification[1]] or nil
                if stats then
                    add(specification[2], specification[3], stats.total)
                    local change = stats.change
                    if type(change) == "table" then
                        if change.quality == "fresh" then
                            add("inventory.aer_new", "New since previous scan",
                                change.new_reports)
                        elseif change.quality == "reset" then
                            add("inventory.aer_new", "New since previous scan",
                                Technical.state(i18n, "reset"))
                        end
                    end
                    for index, category in ipairs(stats.categories or {}) do
                        if index > 32 then break end
                        lines[#lines + 1] = inspector_text("  " .. tostring(category.name)
                            .. ": " .. format_value(category.count, i18n),
                            INSPECTOR_ROW_WIDTH)
                    end
                end
            end
            if type(aer.rootport) == "table" then
                lines[#lines + 1] = translated(i18n, "inventory.aer_root_title",
                    "Root-port subtree reports")
                add("inventory.aer_correctable", "Correctable", aer.rootport.correctable)
                local function root_change(key)
                    local change = aer.rootport.changes and aer.rootport.changes[key]
                    if type(change) ~= "table" then return end
                    if change.quality == "fresh" then
                        add("inventory.aer_new", "New since previous scan",
                            change.new_reports)
                    elseif change.quality == "reset" then
                        add("inventory.aer_new", "New since previous scan",
                            Technical.state(i18n, "reset"))
                    end
                end
                root_change("correctable")
                add("inventory.aer_nonfatal", "Nonfatal", aer.rootport.nonfatal)
                root_change("nonfatal")
                add("inventory.aer_fatal", "Fatal", aer.rootport.fatal)
                root_change("fatal")
            end
            for _, issue in ipairs(aer.issues or {}) do
                add("inspector.reason", "Reason", tostring(issue.field) .. ": "
                    .. tostring(Technical.state(i18n, issue.status)))
            end
            lines[#lines + 1] = translated(i18n, "inventory.aer_note",
                "Reports belong to the observing link, not necessarily the failing endpoint; root-port totals cover a subtree.")
        end
    elseif device.speed_mbps then
        add("inventory.link", "Link", format_value(device.speed_mbps, i18n) .. " Mb/s")
    end
    if node.bus == "pci" or node.bus == "usb" then
        require("wtop.ui.runtime_pm").append(device.runtime_pm,
            snapshot.quality and snapshot.quality.inventory, now_ns or snapshot.timestamp_ns,
            add, lines, i18n)
    end
    if node.bus == "block" then
        local identity = type(device.identity) == "table" and device.identity or {}
        add("inventory.identifier", "ID", node.resource_id)
        add("metrics.capacity", "Size", identity.size_bytes, "bytes")
        if device.is_partition then
            add("partition.start", "Start offset", identity.start_bytes, "bytes")
        end
        add("metrics.read", "Read", device.read_bytes_per_second, "bytes_per_second")
        add("metrics.write", "Write", device.write_bytes_per_second, "bytes_per_second")
        for _, mount in ipairs(node.mounts) do
            add("metrics.mount", "Mount", mount.mount_point)
            add("metrics.filesystem", "Filesystem", mount.fs_type)
        end
        if #node.slave_ids > 0 then
            local names = {}
            for _, target_id in ipairs(node.slave_ids) do
                local target = graph.by_id[target_id]
                names[#names + 1] = target and target.identifier or target_id
            end
            add_list("inventory.backing_devices", "Backing devices", names)
        end
        if #node.holder_ids > 0 then
            local names = {}
            for _, target_id in ipairs(node.holder_ids) do
                local target = graph.by_id[target_id]
                names[#names + 1] = target and target.identifier or target_id
            end
            add_list("inventory.holding_devices", "Used by block devices", names)
        end
        local stack = type(device.stack) == "table" and device.stack or nil
        if stack then
            lines[#lines + 1] = ""
            lines[#lines + 1] = translated(i18n, "stack.title", "Stacked volume")
            add("stack.kind", "Volume type", stack.kind == "dm" and "device-mapper"
                or stack.kind == "md" and "MD RAID" or stack.kind)
            add("stack.status", "Metadata status", Technical.state(i18n, stack.status))
            if stack.kind == "dm" then
                add("stack.name", "Mapper name", stack.name)
                add("stack.suspended", "I/O suspended", stack.suspended)
            else
                add("stack.level", "RAID level", stack.level)
                add("stack.raid_disks", "Expected devices", stack.raid_disks)
                add("stack.previous_disks", "Previous device count", stack.previous_raid_disks)
                add("stack.degraded", "Missing devices", stack.degraded)
                add("stack.array_state", "Array state", stack.array_state)
                add("stack.sync_action", "Sync action", stack.sync_action)
                if stack.sync_completed_sectors and stack.sync_total_sectors
                    and stack.sync_percent then
                    add("stack.sync_progress", "Sync progress",
                        tostring(stack.sync_completed_sectors) .. "/"
                        .. tostring(stack.sync_total_sectors) .. " ("
                        .. format_value(stack.sync_percent, i18n, "percent") .. ")")
                elseif stack.sync_progress_status and stack.sync_progress_status ~= "ok" then
                    add("stack.sync_progress", "Sync progress",
                        Technical.state(i18n, stack.sync_progress_status))
                end
                local members = type(stack.members) == "table" and stack.members or nil
                if members then
                    add("stack.members_status", "Member inventory",
                        Technical.state(i18n, members.status))
                    for _, member in ipairs(members.items or {}) do
                        local role = member.slot == "none"
                            and translated(i18n, "stack.member_no_slot", "no active position")
                            or type(member.slot) == "number"
                            and translated(i18n, "stack.member_slot", "array position {id}",
                                { id = member.slot }) or "—"
                        local description = tostring(member.name) .. " ("
                            .. tostring(member.device_id) .. ") · " .. role
                        if member.state then description = description .. " · " .. member.state end
                        if member.quality == "partial" then
                            description = description .. " · "
                                .. Technical.state(i18n, "partial")
                        end
                        add("stack.member", "RAID member", description)
                    end
                    for _, issue in ipairs(members.issues or {}) do
                        add("inspector.reason", "Reason", tostring(issue.field) .. ": "
                            .. Technical.state(i18n, issue.status))
                    end
                end
            end
            for _, issue in ipairs(stack.issues or {}) do
                add("inspector.reason", "Reason", tostring(issue.field) .. ": "
                    .. Technical.state(i18n, issue.status))
            end
        end
        local nvme = type(device.nvme) == "table" and device.nvme or nil
        if nvme then
            lines[#lines + 1] = ""
            lines[#lines + 1] = translated(i18n, "nvme.title", "NVMe diagnostics")
            add("nvme.status", "Diagnostic status", Technical.state(i18n, nvme.status))
            add("nvme.ana_state", "ANA path state", nvme.ana_state)
            add("nvme.ana_group", "ANA group", nvme.ana_group_id)
            local nuse = type(nvme.nuse) == "table" and nvme.nuse or nil
            if nuse then
                local allocated = nuse.allocated_bytes
                    and format_value(nuse.allocated_bytes, i18n, "bytes")
                    or nuse.allocated_lbas and format_value(nuse.allocated_lbas, i18n)
                        .. " LBAs"
                    or Technical.state(i18n, nuse.quality or nuse.status)
                if nuse.quality == "stale" or nuse.quality == "partial" then
                    allocated = allocated .. " (" .. Technical.state(i18n, nuse.quality) .. ")"
                end
                add("nvme.nuse", "Namespace allocated", allocated)
                if nuse.allocated_lbas ~= nil then
                    lines[#lines + 1] = translated(i18n, "nvme.nuse_note",
                        "Namespace allocation is not filesystem used space.")
                end
            end
            local labels = {
                command_retries = { "nvme.retries", "Command retries" },
                command_errors = { "nvme.errors", "Command errors" },
                multipath_failovers = { "nvme.failovers", "Path failovers" },
                io_requeues_no_path = { "nvme.requeues", "I/O requeued without a path" },
                io_failures_no_path = { "nvme.failures", "I/O failed without a path" },
            }
            for _, specification in ipairs(NVMe.COUNTERS) do
                local name = specification[1]
                local counter = nvme.counters and nvme.counters[name]
                if counter and counter.status ~= "unavailable" then
                    local value = counter.total ~= nil
                        and format_value(counter.total, i18n)
                        or Technical.state(i18n, counter.status)
                    if counter.delta_quality == "fresh" and counter.new ~= nil
                        and counter.new > 0 then
                        value = value .. " (+" .. format_value(counter.new, i18n) .. ")"
                    elseif counter.total ~= nil and counter.delta_quality == "reset" then
                        value = value .. " (" .. Technical.state(i18n, "reset") .. ")"
                    end
                    add(labels[name][1], labels[name][2], value)
                end
            end
            for _, issue in ipairs(nvme.issues or {}) do
                add("inspector.reason", "Reason", tostring(issue.field) .. ": "
                    .. Technical.state(i18n, issue.status))
            end
            local controller = type(nvme.controller) == "table" and nvme.controller or nil
            if controller then
                lines[#lines + 1] = ""
                lines[#lines + 1] = translated(i18n, "nvme.controller_title",
                    "NVMe controller {id}", { id = controller.name })
                add("nvme.status", "Diagnostic status",
                    Technical.state(i18n, controller.status))
                add("nvme.controller_state", "Controller state", controller.state)
                add("nvme.transport", "Transport", controller.transport)
                local controller_labels = {
                    command_errors = { "nvme.errors", "Command errors" },
                    resets = { "nvme.resets", "Controller resets" },
                    reconnects = { "nvme.reconnects", "Controller reconnects" },
                }
                for _, specification in ipairs(NVMe.CONTROLLER_COUNTERS) do
                    local name = specification[1]
                    local counter = controller.counters and controller.counters[name]
                    if counter and counter.status ~= "unavailable" then
                        local value = counter.total ~= nil
                            and format_value(counter.total, i18n)
                            or Technical.state(i18n, counter.status)
                        if counter.delta_quality == "fresh" and counter.new
                            and counter.new > 0 then
                            value = value .. " (+" .. format_value(counter.new, i18n) .. ")"
                        elseif counter.total ~= nil and counter.delta_quality == "reset" then
                            value = value .. " (" .. Technical.state(i18n, "reset") .. ")"
                        end
                        add(controller_labels[name][1], controller_labels[name][2], value)
                    end
                end
                for _, issue in ipairs(controller.issues or {}) do
                    add("inspector.reason", "Reason", tostring(issue.field) .. ": "
                        .. Technical.state(i18n, issue.status))
                end
            end
            local paths = type(nvme.paths) == "table" and nvme.paths or nil
            if paths then
                lines[#lines + 1] = ""
                lines[#lines + 1] = translated(i18n, "nvme.paths_title", "NVMe multipath")
                add("nvme.paths_status", "Path inventory",
                    Technical.state(i18n, paths.status))
                add("nvme.subsystem", "Subsystem", paths.subsystem)
                add("nvme.iopolicy", "I/O policy", paths.iopolicy)
                for _, path in ipairs(paths.items or {}) do
                    local description = tostring(path.name) .. " -> "
                        .. tostring(path.controller)
                    if path.controller_state then
                        description = description .. " · "
                            .. translated(i18n, "nvme.controller_state", "Controller state")
                            .. ": " .. path.controller_state
                    end
                    if path.transport then
                        description = description .. " · "
                            .. translated(i18n, "nvme.transport", "Transport")
                            .. ": " .. path.transport
                    end
                    if path.ana_state then
                        description = description .. " · "
                            .. translated(i18n, "nvme.ana_state", "ANA path state")
                            .. ": " .. path.ana_state
                    end
                    if path.ana_group_id then
                        description = description .. " · "
                            .. translated(i18n, "nvme.ana_group", "ANA group")
                            .. ": " .. tostring(path.ana_group_id)
                    end
                    if path.status ~= "ok" then
                        description = description .. " · "
                            .. Technical.state(i18n, path.status)
                    end
                    add("nvme.path", "Controller path", description)
                end
                for _, issue in ipairs(paths.issues or {}) do
                    add("inspector.reason", "Reason", tostring(issue.field) .. ": "
                        .. Technical.state(i18n, issue.status))
                end
            end
            lines[#lines + 1] = translated(i18n, "nvme.note",
                "Kernel counters can reset; +N is the change since the preceding sample.")
        end
    elseif node.bus == "net" then
        add("inventory.identifier", "ID", node.resource_id)
        add("metrics.state", "State", Technical.state(i18n, device.operstate))
        add("metrics.address", "Address", device.address)
        add("metrics.receive", "Receive", device.rates and device.rates.rx_bytes_per_second,
            "bytes_per_second")
        add("metrics.transmit", "Transmit", device.rates and device.rates.tx_bytes_per_second,
            "bytes_per_second")
        local link = type(device.link_events) == "table" and device.link_events or nil
        if link then
            lines[#lines + 1] = ""
            lines[#lines + 1] = translated(i18n, "inventory.net_link_title", "Link transitions")
            add("inventory.net_link_total", "Carrier changes", link.changes_total)
            add("inventory.net_link_up", "Link up reports", link.up_total)
            add("inventory.net_link_down", "Link down reports", link.down_total)
            local change = link.change
            if type(change) == "table" then
                if change.quality == "fresh" then
                    add("inventory.net_link_new", "New transitions", change.new_changes)
                    add("inventory.net_link_new_up", "New link up reports", change.new_up)
                    add("inventory.net_link_new_down", "New link down reports", change.new_down)
                elseif change.quality == "reset" then
                    add("inventory.net_link_new", "New transitions",
                        Technical.state(i18n, "reset"))
                end
            end
            if link.status ~= "ok" then
                add("inventory.net_link_status", "Link counter status",
                    Technical.state(i18n, link.status))
            end
        end
        local queues = type(device.queues) == "table" and device.queues or nil
        if queues then
            lines[#lines + 1] = ""
            lines[#lines + 1] = translated(i18n, "inventory.net_queue_title", "Network queues")
            add("inventory.net_rx_queues", "RX queues", queues.rx_count)
            add("inventory.net_tx_queues", "TX queues", queues.tx_count)
            if queues.status ~= "ok" then
                add("inventory.net_queue_status", "Queue status",
                    Technical.state(i18n, queues.status))
            end
            if queues.config_status == "ok" then
                local function enabled(mask)
                    return type(mask) == "string" and mask:find("[1-9a-f]") ~= nil
                end
                local rps, xps, capped = 0, 0, 0
                for _, row in ipairs(queues.rx_details or {}) do
                    if enabled(row.rps_cpus) then rps = rps + 1 end
                end
                for _, row in ipairs(queues.tx_details or {}) do
                    if enabled(row.xps_cpus) or enabled(row.xps_rxqs) then
                        xps = xps + 1
                    end
                    if row.rate_limit_enabled == true then capped = capped + 1 end
                end
                add("inventory.net_rps_queues", "RPS-enabled RX queues", rps)
                add("inventory.net_xps_queues", "XPS-enabled TX queues", xps)
                add("inventory.net_capped_queues", "Rate-capped TX queues", capped)
            end
            if queues.config_status and queues.config_status ~= "ok" then
                add("inventory.net_config_status", "Queue configuration status",
                    Technical.state(i18n, queues.config_status))
            end
            local config_issues = {}
            for _, specification in ipairs({
                { "rx", queues.rx_details },
                { "tx", queues.tx_details },
            }) do
                for _, row in ipairs(specification[2] or {}) do
                    for _, issue in ipairs(row.issues or {}) do
                        config_issues[#config_issues + 1] = specification[1]
                            .. "-" .. tostring(row.id) .. "/" .. tostring(issue.field)
                            .. ": " .. tostring(Technical.state(i18n, issue.status))
                    end
                end
            end
            for index = 1, math.min(#config_issues, 16) do
                add("inspector.reason", "Reason", config_issues[index])
            end
            if #config_issues > 16 then
                add("inventory.net_config_more", "More queue issues",
                    #config_issues - 16)
            end
            if queues.tx_timeout_total ~= nil then
                add("inventory.net_tx_timeout_total", "TX timeout reports",
                    queues.tx_timeout_total)
            end
            local timeout_change = queues.timeout_change
            if type(timeout_change) == "table" then
                if timeout_change.quality == "fresh" then
                    add("inventory.net_tx_timeout_new", "New since previous queue scan",
                        timeout_change.new_reports)
                elseif timeout_change.quality == "reset" then
                    add("inventory.net_tx_timeout_new", "New since previous queue scan",
                        Technical.state(i18n, "reset"))
                end
            end
            if queues.timeout_status and queues.timeout_status ~= "ok" then
                add("inventory.net_tx_timeout_status", "TX timeout status",
                    Technical.state(i18n, queues.timeout_status))
            end
            local nonzero = {}
            for _, counter in ipairs(queues.tx_timeouts or {}) do
                if type(counter.total) == "number" and counter.total > 0 then
                    nonzero[#nonzero + 1] = "tx-" .. tostring(counter.id)
                        .. ": " .. tostring(counter.total)
                end
            end
            if #nonzero > 0 then
                add_list("inventory.net_tx_timeout_queues",
                    "Queues with timeouts", nonzero)
            end
            local newly_reported = {}
            for _, counter in ipairs(queues.tx_timeouts or {}) do
                local change = counter.change
                if type(change) == "table" and change.quality == "fresh"
                    and type(change.new_reports) == "number"
                    and change.new_reports > 0 then
                    newly_reported[#newly_reported + 1] = "tx-" .. tostring(counter.id)
                        .. ": +" .. tostring(change.new_reports)
                end
            end
            if #newly_reported > 0 then
                add_list("inventory.net_tx_timeout_new_queues",
                    "New by queue", newly_reported)
            end
        end
    end
    if #node.gpu_ids > 0 then add("widgets.gpu", "GPU", table.concat(node.gpu_ids, ", ")) end
    if #node.slot_ids > 0 then
        local names = {}
        for _, id in ipairs(node.slot_ids) do
            local slot = graph.by_id[id]
            names[#names + 1] = slot and Hardware.label(slot, i18n) or id
        end
        add_list("slot.references", "Firmware slot references", names)
    end
    if #node.onboard_ids > 0 then
        local names = {}
        for _, id in ipairs(node.onboard_ids) do
            local onboard = graph.by_id[id]
            names[#names + 1] = onboard and Hardware.label(onboard, i18n) or id
        end
        add_list("onboard.references", "Firmware onboard references", names)
    end
    for _, spec in ipairs({ { "baseboard_ids", "enclosure.boards", "Related baseboards" },
        { "chassis_ids", "enclosure.chassis_links", "Related enclosures" },
        { "contained_ids", "enclosure.devices", "Declared contained devices" } }) do
        local names = {}
        for _, related_id in ipairs(node[spec[1]]) do
            local related = graph.by_id[related_id]
            names[#names + 1] = related and Hardware.label(related, i18n) or related_id
        end
        if #names > 0 then add_list(spec[2], spec[3], names) end
    end
    if #node.firmware_component_ids > 0 then
        local names = {}
        for _, component_id in ipairs(node.firmware_component_ids) do
            local component = graph.by_id[component_id]
            names[#names + 1] = component and Hardware.label(component, i18n)
                or component_id
        end
        add_list("firmware_component.references", "Firmware components", names)
    end
    add("inventory.sensors", "Related sensors", #node.sensor_ids)
    if #node.sensors > 0 then
        local sensor_snapshot = {}
        for key, value in pairs(snapshot) do sensor_snapshot[key] = value end
        sensor_snapshot.sensors = { devices = node.sensors }
        local sensor_lines = sensor_detail_lines(sensor_snapshot, i18n, now_ns)
        for _, line in ipairs(sensor_lines) do lines[#lines + 1] = line end
    end
    if node.kind=="thread" then
        for _,clock in ipairs(snapshot.cpu_clocks and snapshot.cpu_clocks.cpus or {}) do
            if clock.id==device.id then
                local q=Quality.current_source(snapshot.quality,"cpu_clocks") and clock.quality or "stale"
                if device.package_id~=nil and clock.package_id~=nil and device.package_id~=clock.package_id
                    or device.core_id~=nil and clock.core_id~=nil and device.core_id~=clock.core_id then q="gap" end
                lines[#lines + 1]=""
                lines[#lines + 1]=translated(i18n,"cpu_clock.includes_idle","Effective clock includes idle time")
                add("metrics.effective_frequency","Effective",q=="fresh" and clock.effective_hz or nil,"hertz")
                add("cpu_clock.sample_window","Window",clock.interval_ns,"nanoseconds")
                add("cpu_clock.uncertainty","Interval uncertainty",clock.interval_uncertainty_ns,"nanoseconds")
                add("inspector.quality","Quality",Technical.state(i18n,q))
                if clock.reason then add("inspector.reason","Reason",Technical.reason(i18n,clock.reason)) end
                add("metrics.source","Source",clock.source)
                add("cpu_clock.counters","APERF / MPERF",clock.aperf_hex and clock.mperf_hex
                    and clock.aperf_hex.." / "..clock.mperf_hex or nil)
                add("systemd.sample_age","Sample age",type(now_ns)=="number" and clock.observed_at_ns
                    and math.max(0,now_ns-clock.observed_at_ns) or nil,"nanoseconds")
                break
            end
        end
    end
    lines[#lines + 1] = ""
    if Hardware.related(graph, id).total > 0 then
        lines[#lines + 1] = translated(i18n, "inventory.related_key_hint",
            "r opens related devices")
    end
    if type(history_count) == "number" and history_count > 0 then
        lines[#lines + 1] = translated(i18n, "inventory.back_hint",
            "b returns to the previous device")
    end
    lines[#lines + 1] = graph.by_id[node.parent_id]
        and translated(i18n, "inventory.detail_hint", "p parent · Esc/Enter closes")
        or translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
end

local HELP_SECTIONS = {
    {
        id = "help.section_navigation", title = "Navigation",
        bindings = {
            { "1–9 0", "help.switch_tabs", "select a tab directly" },
            { "← →", "help.cycle_tabs", "previous / next tab" },
            { "Tab ⇧Tab", "help.focus_widget", "move focus between visible widgets" },
            { "?  F1", "help.toggle", "show or hide this help" },
            { "!", "health.title", "Health and warnings" },
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
            { "Esc", "help.process_clear_filter",
                "clear the search, then a cgroup filter reached from Workloads" },
            { "o", "help.process_sort", "cycle the sort column" },
            { "O", "help.process_direction", "reverse the sort direction" },
            { "t", "help.process_tree", "toggle the parent/child tree" },
            { "c", "help.process_collapse", "fold or unfold the selected process subtree" },
            { "[ ]", "help.process_family", "select the parent or first child in tree view" },
            { "p", "help.process_paths", "toggle full executable paths" },
            { "C", "help.process_columns", "choose which columns the table shows" },
            { "Enter", "help.process_details", "open details for the selection" },
            { "g", "help.process_workload", "jump to the selection's workload" },
            { "n", "help.process_sockets", "show the selection's sockets on Linux" },
            { "k", "help.terminate_process", "send a signal to the selection" },
            { "F", "help.process_fds", "show open file descriptors on Linux" },
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
            { "ns:1", "help.query_ns", "search the id inside a PID namespace" },
            { "cpu>20", "help.query_compare", "compare a number, combined with the terms" },
            { "mem>512M", "help.query_units", "byte sizes take K/M/G/T; time is in seconds" },
            { "proto:tcp pid:42", "help.network_query",
                "on Network, combine protocol, owner PID and queue>0" },
            { "cpu>20 mem>1G", "help.workload_search",
                "on Workloads, combine measured values and text" },
            { "bus:pci driver:nvme", "help.hardware_search",
                "on System, find devices by name, ID, bus or driver" },
            { "path:/mnt used>90", "help.mount_search",
                "on Storage, combine mount paths and measured capacity" },
            { "← → Home End", "help.query_cursor", "move the cursor within the query" },
            { "Ctrl-W Ctrl-U", "help.query_kill", "delete the previous word, or back to the start" },
        },
    },
    {
        id = "help.section_appearance", title = "Appearance",
        bindings = {
            { "e", "help.edit_layout", "enter layout edit mode" },
            { "a r d", "help.layout_widgets", "in edit mode: add, replace or remove a widget" },
            { "m", "help.layout_move", "in edit mode: drop the focused widget onto a named target" },
            { "w", "help.layout_workspaces", "in edit mode: switch or name a saved layout workspace" },
            { "b", "help.layout_tabs", "in edit mode: show, hide or reorder tabs" },
            { "T", "help.cycle_theme", "cycle the colour theme" },
            { "B", "help.cycle_chart", "switch between block and Braille charts" },
            { "z  Z", "help.chart_zoom", "show more or less time in charts" },
            { "p", "power.help", "power and limits on Overview, Compute and GPU" },
            { "L", "help.cycle_language", "cycle the interface language" },
            { "v", "help.toggle_virtual", "show or hide virtual devices and pseudo mounts" },
        },
    },
    {
        id = "help.section_workloads", title = "Workloads",
        bindings = {
            { "↑ ↓ Home End", "help.workload_select",
                "move the workload selection; the detail panel follows" },
            { "c", "help.workload_collapse",
                "collapse or expand the selected workload subtree" },
            { "Enter on workload", "help.workload_processes",
                "show the processes inside the selected cgroup" },
            { "Enter on GPU", "help.gpu_detail",
                "open the host-process detail for the selected GPU process" },
            { "i on GPU", "help.gpu_clients",
                "open the DRM clients, engines and memory regions behind that row" },
            { "k on GPU", "help.gpu_clocks",
                "open a GPU device's own clock domains side by side" },
        },
    },
    {
        id = "help.section_privacy", title = "Privacy",
        bindings = {
            { "m", "help.mask_remote",
                "toggle remote-address masking on the network page" },
        },
    },
    {
        id = "help.section_inspect", title = "Deep inspection",
        bindings = {
            { "h", "widgets.sensors", "Sensors" },
            { "j k Enter", "help.hardware_detail", "in System or memory hardware tables: select a device and open details" },
            { "s", "help.inspect_smart", "choose a SMART/NVMe device", "linux" },
            { "w", "wifi.help", "Wi-Fi link reports on Network", "linux" },
            { "b", "help.inspect_bandwidth", "measure RAM bandwidth with perf", "linux" },
            { "d", "help.inspect_systemd", "inspect systemd units or the selected workload's unit", "linux" },
            { "D", "help.inspect_sshd", "inspect the sshd service and listeners", "linux" },
            { "u", "help.inspect_sessions", "inspect logind login sessions", "linux" },
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

local function help_lines(i18n, width, linux_host, replay)
    local title = i18n:t("app.title")
    local lines = {
        title ~= "app.title" and title or "wtop — system monitor",
    }
    if replay then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "replay.title", "Replay")
        lines[#lines + 1] = translated(i18n, "replay.controls",
            "Space play/pause · Alt-Left/Right step · Alt-Home/End first/last · f speed")
        lines[#lines + 1] = translated(i18n, "replay.no_live_reads",
            "Live inspection and process actions are unavailable during replay")
    end
    -- Two columns when the overlay is wide enough for them, one when it is not.
    local key_width = 0
    for _, group in ipairs(HELP_SECTIONS) do
        for _, binding in ipairs(group.bindings) do
            if linux_host ~= false or binding[4] ~= "linux" then
                key_width = math.max(key_width, UI.Renderer.Width.display_width(binding[1]))
            end
        end
    end
    for _, group in ipairs(HELP_SECTIONS) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, group.id, group.title)
        for _, binding in ipairs(group.bindings) do
            if linux_host ~= false or binding[4] ~= "linux" then
                local description = translated(i18n, binding[2], binding[3])
                if width and width < key_width + 24 then
                    lines[#lines + 1] = "  " .. binding[1]
                    lines[#lines + 1] = "      " .. description
                else
                    lines[#lines + 1] = "  " .. pad_to(binding[1], key_width) .. "  " .. description
                end
            end
        end
    end
    if linux_host ~= false then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "help.inspectors_safe",
            "External inspectors use absolute argv, a fixed locale, timeouts and output limits.")
        lines[#lines + 1] = translated(i18n, "help.smart_standby",
            "SMART probes do not wake standby drives.")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "help.close", "Esc/Enter closes")
    return lines
end

-- Linux actions share the pidfd and start-time checks in the action layer.
-- SIGTERM stays first so opening the menu does not change the default choice.
local SIGNAL_CHOICES = {
    { number = 15, name = "SIGTERM", id = "signal.term", fallback = "ask the process to exit" },
    { number = 1, name = "SIGHUP", id = "signal.hup", fallback = "ask the process to reload" },
    { number = 2, name = "SIGINT", id = "signal.int", fallback = "interrupt the process" },
    { number = 9, name = "SIGKILL", id = "signal.kill", fallback = "force the kernel to kill it" },
    { number = 19, name = "SIGSTOP", id = "signal.stop", fallback = "suspend the process" },
    { number = 18, name = "SIGCONT", id = "signal.cont", fallback = "resume a stopped process" },
}
local WINDOWS_ACTION_CHOICES = {
    { number = 9, name = "Terminate", id = "process.terminate",
        fallback = "end this process" },
}

local function signal_menu_lines(process, selected, i18n, unicode, choices)
    if unicode == nil then unicode = true end
    choices = choices or SIGNAL_CHOICES
    local windows = choices == WINDOWS_ACTION_CHOICES
    local lines = {
        translated(i18n, windows and "process.action_title" or "signal.title",
            windows and "Process action" or "Send a signal") .. " · PID "
            .. tostring(process and process.pid or "—")
            .. "  " .. tostring(process and (process.name or "") or ""),
        "",
        translated(i18n, "signal.hint", "Up/Down selects · Enter sends · Esc cancels"),
        "",
    }
    local rows = {}
    for index, choice in ipairs(choices) do
        rows[#rows + 1] = {
            (index == selected and (unicode and "▸ " or "> ") or "  ") .. choice.name,
            translated(i18n, choice.id, choice.fallback),
        }
    end
    for _, line in ipairs(aligned_pairs(rows, 3)) do lines[#lines + 1] = line end
    lines[#lines + 1] = ""
    lines[#lines + 1] = windows
        and translated(i18n, "process.terminate_warning",
            "The process start time is checked before termination.")
        or translated(i18n, "signal.warning",
            "The target is re-verified by start time, so a recycled PID is never signalled.")
    return lines
end

local function widget_picker_lines(mode, items, selected, i18n, unicode)
    if unicode == nil then unicode = true end
    local replacing = mode == "replace"
    local lines = {
        translated(i18n, replacing and "layout.replace_widget" or "layout.add_widget",
            replacing and "Replace widget" or "Add widget"),
        "",
        translated(i18n, "layout.widget_hint",
            "Up/Down selects · Enter applies · Esc cancels"),
        "",
    }
    if #items == 0 then
        lines[#lines + 1] = translated(i18n, "layout.no_widgets_left",
            "This page has no further widgets to place")
        return lines
    end
    for index, item in ipairs(items) do
        lines[#lines + 1] = (index == selected and (unicode and "▸ " or "> ") or "  ")
            .. item.title
            .. "  "
            -- Every kind the pages define has a label; this keeps an unknown
            -- one readable instead of inventing a title-cased spelling.
            .. translated(i18n, "layout.widget_kind." .. tostring(item.kind),
                tostring(item.kind))
    end
    return lines
end

--- The process table's column editor.
---
--- The list shows every column, drawn or not: a column that is not on screen is
--- a column the user could not switch back on if the editor hid it.  A visible
--- column is annotated with the place it currently occupies, so the effect of
--- the arrow keys is legible before it is taken rather than only after.
---
--- The left and right keys *set* the position relative to the neighbour, exactly
--- as the drop-target list does.  Flipping instead would oscillate while the
--- key is held, and the result would depend on the user remembering the
--- current order.
local function process_column_lines(selection, i18n, unicode)
    if unicode == nil then unicode = true end
    local lines = {
        translated(i18n, "process.columns_title", "Process columns"), "",
        translated(i18n, "process.columns_hint",
            "Up/Down selects · Space shows/hides · ←/→ moves · Esc closes"), "",
    }
    for index, entry in ipairs(selection.entries) do
        local cursor = index == selection.index and (unicode and "▸ " or "> ") or "  "
        -- A column the user is not allowed to hide says so, rather than
        -- offering a toggle that silently refuses.
        local mark = entry.visible and (unicode and "■" or "*") or (unicode and "□" or "-")
        local note = ""
        if entry.visible then
            note = "  " .. translated(i18n, "process.columns_position",
                "position {index}", { index = tostring(entry.position) })
        end
        -- The note that matters most is on a *visible* required column: that is
        -- the row the user is looking at when they decide to press Space, and
        -- the one whose toggle will be refused.
        if entry.required then
            note = note .. "  " .. translated(i18n, "process.columns_required", "always shown")
        end
        lines[#lines + 1] = string.format("%s%s  %s%s", cursor, mark,
            entry.label_id and translated(i18n, entry.label_id, entry.label) or entry.label,
            note)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "process.columns_session",
        "This choice lasts for the session, like the sort column")
    return lines
end

local function tab_manager_lines(selection, i18n, unicode)
    if unicode == nil then unicode = true end
    local lines = {
        translated(i18n, "tabs.manage_title", "Tabs"), "",
        translated(i18n, "tabs.manage_hint",
            "Up/Down selects · n new · c copy · r rename · x delete · Space show/hide · ←/→ move · Enter open · Esc close"), "",
    }
    for index, entry in ipairs(selection.entries) do
        local cursor = index == selection.index and (unicode and "▸ " or "> ") or "  "
        local mark = entry.visible and (unicode and "■" or "*") or (unicode and "□" or "-")
        local label = translated(i18n, entry.label_id, entry.label)
        local position = entry.position and "  " .. translated(i18n,
            "process.columns_position", "position {index}",
            { index = tostring(entry.position) }) or ""
        lines[#lines + 1] = cursor .. mark .. "  " .. label .. position
    end
    lines[#lines + 1] = ""
    if selection.renaming then
        lines[#lines + 1] = translated(i18n, "tabs.rename_prompt",
            "New page name: {name}_", { name = selection.draft or "" })
    elseif selection.confirm_delete then
        local entry = selection.entries[selection.index]
        lines[#lines + 1] = translated(i18n, "tabs.delete_confirm",
            "Press x again to delete {name}; any other key cancels.",
            { name = entry and entry.label or "?" })
    else
        lines[#lines + 1] = translated(i18n, "tabs.manage_note",
            "Hidden tabs keep their layouts and can be shown again.")
    end
    return lines
end

-- One picker for every inspector that can enumerate more than one thing.
-- SMART, RAM bandwidth and the service inspector differ in what they list and
-- in the columns worth showing, but the flow is the same: enumerate, pick one,
-- inspect it.  Columns an entity does not carry are simply left blank rather
-- than invented, so a PMU row and a disk row can share this renderer.
local function entity_picker_lines(title, entities, selected, i18n, truncated, unicode)
    if unicode == nil then unicode = true end
    local lines = {
        translated(i18n, title.key, title.fallback),
        "",
        translated(i18n, "inspector.entity_select_hint",
            "Up/Down selects · Enter inspects · Esc closes"),
        "",
    }
    for index, entity in ipairs(entities or {}) do
        -- A PMU or a service unit carries neither a model nor a medium, and
        -- printing "Unknown" in those columns would be a guess dressed as a
        -- reading.  The name column already identifies the row.
        local identity = entity.model or entity.vendor or ""
        local medium = entity.rotational == 1 and "HDD"
            or (entity.rotational == 0 and "SSD" or "")
        lines[#lines + 1] = string.format("%s %-18s %-4s %s",
            index == selected and (unicode and "▸" or ">") or " ",
            tostring(entity.path or entity.name or entity.id or "?"),
            medium, tostring(identity))
    end
    if truncated then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "inspector.device_list_truncated",
            "Device list truncated for safety")
    end
    return lines
end

-- The workspace list doubles as the name entry.  A separate modal prompt would
-- need its own editor, its own focus rules and its own close path; here the
-- user moves onto the new-workspace row and types, and the same list they were
-- already reading is what they are naming.
local MAX_WORKSPACE_ROWS = 32
-- The store rejects a name longer than this, so the editor stops there rather
-- than letting someone type a name that is refused on Enter.
local MAX_WORKSPACE_NAME_BYTES = 64

-- The drop-target list for a layout move.  The arrows can only step one place
-- at a time, which is not a drop; this names the target instead, and the side
-- is a two-state choice rather than a second list, because "before" and
-- "after" are the same row and listing them twice would double the list for no
-- extra information.
local function move_target_lines(selection, i18n, unicode)
    if unicode == nil then unicode = true end
    local marker = unicode and "▸" or ">"
    local side = selection.position == "before"
        and translated(i18n, "layout.move_before", "before")
        or translated(i18n, "layout.move_after", "after")
    local lines = {
        translated(i18n, "layout.move_title", "Move {widget}", {
            widget = selection.title,
        }),
        "",
        translated(i18n, "layout.move_position", "Side: {side}  (Left/Right changes it)",
            { side = side }),
        translated(i18n, "layout.move_hint",
            "Up/Down selects · Enter drops · Esc cancels"),
        "",
    }
    for index, target in ipairs(selection.targets) do
        -- The panel title and the widget id are both shown: two panels on one
        -- page can share a short title, and the id is what the rest of the
        -- layout keys on.
        lines[#lines + 1] = string.format("%s %-28s %s",
            index == selection.index and marker or " ", target.title, target.id)
    end
    if selection.truncated then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "layout.move_truncated",
            "Not every widget is listed; the drop still applies to the one you pick")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
end

-- Where a name sits in a sorted list, so the cursor can follow a rename to the
-- row that now holds it.  Without this the renamed workspace would be left
-- selected by position, which is a different workspace as soon as the new name
-- sorts before the old one.
local function index_of_name(names, name)
    for index, candidate in ipairs(names) do
        if candidate == name then return index end
    end
    return 1
end

-- The same DRM client, across two reads of the collector.  Each tick rebuilds
-- the client table, so identity never matches and the drill-down would drop
-- back to the list on the very frame it was entered.  The collector's id is
-- the device-scoped `drm-client-id`, which is stable for the life of the
-- client; a client with no id at all can only be compared by identity, and
-- that is the honest answer rather than a guess at which one it was.
local function same_client(left, right)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    if type(left.id) == "string" and type(right.id) == "string" then
        return left.id == right.id
    end
    return false
end

-- The device list is rebuilt from the collector on every tick and its order is
-- the collector's, so a selection held by position drifts onto a different card
-- as soon as one is added or removed.  `stable_id` is the identity the GPU
-- collector derived once from the DRM node; a device with no id at all can only
-- be compared by identity, which is the honest answer rather than a guess.
local function same_device(left, right)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    for _, key in ipairs({ "stable_id", "id" }) do
        if type(left[key]) == "string" and type(right[key]) == "string" then
            return left[key] == right[key]
        end
    end
    return false
end

local function workspace_lines(selection, i18n, unicode)
    if unicode == nil then unicode = true end
    local marker = unicode and "▸" or ">"
    local caret = unicode and "▌" or "_"
    -- The hint says what the keys do *now*, not what they do everywhere: a
    -- rename in progress has a different meaning for Enter and Esc, and a hint
    -- that listed every binding at once would leave the reader to work out
    -- which of them apply to the row the cursor is on.
    local hint = selection.renaming
        and translated(i18n, "layout.workspaces_rename_hint",
            "Enter renames · Esc cancels the rename")
        or translated(i18n, "layout.workspaces_hint",
            "Up/Down selects · r renames · type a new name · Enter switches"
                .. " · x deletes · Esc closes")
    local lines = {
        translated(i18n, "layout.workspaces_title", "Workspaces"),
        "",
        hint,
        "",
    }
    for index, name in ipairs(selection.names) do
        local row = index == selection.index and marker or " "
        if selection.renaming and index == selection.index then
            -- The row under edit shows the text being typed and nothing else.
            -- Its old name is not shown beside it: the row has one name at a
            -- time, and the caret is what says the old one is being replaced
            -- rather than appended to.
            lines[#lines + 1] = string.format("%s %s", row, selection.draft .. caret)
        else
            local suffix = name == selection.active
                and translated(i18n, "layout.workspace_current", "  (current)") or ""
            lines[#lines + 1] = string.format("%s %s%s", row, name, suffix)
        end
    end
    local new_index = #selection.names + 1
    local row = new_index == selection.index and marker or " "
    lines[#lines + 1] = ""
    if selection.renaming then
        -- The new-workspace row is not where this text is going, so it is
        -- shown bare rather than with a stale draft beside it.
        lines[#lines + 1] = string.format("%s %s", row,
            translated(i18n, "layout.workspace_new", "New: "))
    else
        local draft = selection.draft
        lines[#lines + 1] = string.format("%s %s", row,
            translated(i18n, "layout.workspace_new", "New: ")
                .. (draft ~= "" and draft or "_"))
    end
    if selection.truncated then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "layout.workspaces_truncated",
            "More workspaces exist; narrow the list by deleting some")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
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
    if engine.replay then return Inspectors.Registry.new() end
    local host = native.uname()
    if host and host.sysname == "Windows" and type(native.collect_disk_health) == "function" then
        local registry = Inspectors.Registry.new()
        local inspector = require("wtop.inspectors.windows_storage").new({ native = native })
        assert(registry:register(inspector))
        engine._storage_inspector = inspector
        return registry
    end
    if not host or host.sysname ~= "Linux" then
        return Inspectors.Registry.new()
    end
    local smartctl = system.find_executable("smartctl") or "/usr/sbin/smartctl"
    local systemctl = system.find_executable("systemctl") or "/usr/bin/systemctl"
    local loginctl = system.find_executable("loginctl") or "/usr/bin/loginctl"
    local registry = Inspectors.new_default({
        smart = { runner = engine.context.runner, clock = engine.clock, executable = smartctl },
        ram_bandwidth = {
            clock = engine.clock,
            perf_reader = PerfBandwidth.for_context(engine.context),
        },
        sshd = { runner = engine.context.runner, clock = engine.clock, systemctl = systemctl, loginctl = loginctl,
            sshd = system.find_executable("sshd") or "/usr/sbin/sshd",
            journalctl = system.find_executable("journalctl") or "/usr/bin/journalctl" },
        systemd = { runner = engine.context.runner, clock = engine.clock, systemctl = systemctl },
        logind = { runner = engine.context.runner, clock = engine.clock, loginctl = loginctl },
    })
    local storage = require("wtop.inspectors.linux_storage").new({
        native = native, fallback = registry:get("storage.smart"),
    })
    assert(registry:unregister("storage.smart"))
    assert(registry:register(storage))
    engine._storage_inspector = storage
    return registry
end

local function inspector_context(engine)
    return merge(engine.context, {
        snapshot = engine.snapshot,
        processes = engine.snapshot.processes,
        mask_remote_addresses = true,
    })
end

-- One set of current observations supplies Agent, the header and warning details.
local function alert_count(snapshot)
    return #Health.summary(snapshot).signals
end

local function wifi_link_lines(snapshot, i18n)
    local lines = { translated(i18n, "wifi.title", "Wi-Fi link"), "" }
    local devices = snapshot.wifi and snapshot.wifi.devices or {}
    local function quantity(value, suffix)
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return "—" end
        return (i18n.format:number(value, { precision = value % 1 == 0 and 0 or 3 }) or tostring(value)) .. (suffix or "")
    end
    local function add(id, fallback, value)
        lines[#lines + 1] = "  " .. translated(i18n, id, fallback) .. ": " .. value
    end
    if #devices == 0 then
        lines[#lines + 1] = translated(i18n, "reason.wifi_link_unavailable", "Wi-Fi link information is unavailable")
    end
    for index, device in ipairs(devices) do
        if index > 16 then break end
        lines[#lines + 1] = inspector_text(tostring(device.name or "?")
            .. " · #" .. tostring(device.ifindex or "?") .. " · PHY " .. tostring(device.wiphy_id or "?")
            .. " [" .. Technical.state(i18n, require("wtop.model.wifi").quality(snapshot, device)) .. "]", INSPECTOR_ROW_WIDTH)
        if device.association == "not_reported" then
            lines[#lines + 1] = "  " .. translated(i18n, "wifi.no_association", "No associated BSS reported")
        end
        for position, link in ipairs(device.links or {}) do
            if position > 16 then break end
            local label = link.link_id ~= nil and " · " .. translated(i18n, "wifi.link_id", "Link ID")
                .. " " .. tostring(link.link_id) or ""
            local frequency = link.frequency_mhz
            if type(frequency) == "number" and type(link.frequency_offset_khz) == "number" then
                frequency = frequency + link.frequency_offset_khz / 1000
            end
            add("wifi.frequency", "Associated frequency", quantity(frequency, " MHz") .. label)
        end
        local station = device.station
        if type(station) == "table" then
            add("wifi.signal", "Last RX signal", quantity(station.signal_dbm, " dBm"))
            add("wifi.average_signal", "Average RX signal", quantity(station.average_signal_dbm, " dBm"))
            for _, spec in ipairs({ { "receive_phy", "wifi.receive_phy", "RX PHY rate" },
                { "transmit_phy", "wifi.transmit_phy", "TX PHY rate" } }) do
                local data = station[spec[1]] or {}
                local value = data.bits_per_second and i18n.format:bits_per_second(data.bits_per_second) or "—"
                if data.standard then value = value .. " · " .. data.standard end
                if data.mcs ~= nil then value = value .. " · MCS " .. tostring(data.mcs) end
                if data.spatial_streams ~= nil then value = value .. " · NSS " .. tostring(data.spatial_streams) end
                if data.bandwidth_mhz then value = value .. " · " .. quantity(data.bandwidth_mhz, " MHz") end
                add(spec[2], spec[3], value)
            end
            add("wifi.inactive", "Station inactivity", quantity(station.inactive_ms, " ms"))
        end
        if device.multi_link then
            lines[#lines + 1] = translated(i18n, "wifi.multi_link", "MLD station report; rates are not assigned to one link.")
        end
        if device.station_errno then
            lines[#lines + 1] = Technical.state(i18n,
                (device.station_errno == 1 or device.station_errno == 13) and "denied" or "unavailable")
        end
        lines[#lines + 1] = ""
    end
    lines[#lines + 1] = translated(i18n, "wifi.note",
        "Driver link reports: PHY rates are not throughput or guaranteed capacity. Radio sample time is unknown.")
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
end

local function nvme_warning_lines(snapshot, i18n)
    local summary = require("wtop.model.nvme_warnings").summary(snapshot)
    local lines = { translated(i18n, "nvme.warning.title", "NVMe health warnings"), "" }
    if #summary.observations == 0 then
        lines[#lines + 1] = translated(i18n, "reason.nvme_health_unavailable", "Native NVMe health data is unavailable")
        local state = snapshot.quality and snapshot.quality.disk_health
        if state then lines[#lines + 1] = Technical.state(i18n, state.quality or state.status) end
    elseif #summary.signals == 0 then
        lines[#lines + 1] = translated(i18n, "nvme.warning.none", "No warning flags in current observations")
    else
        for _, row in ipairs(summary.observations) do
            if row.mask ~= 0 then
                lines[#lines + 1] = inspector_text(tostring(row.name or row.id)
                    .. " · " .. string.format("0x%02x", row.mask), INSPECTOR_ROW_WIDTH)
                for _, reason in ipairs(row.reasons) do
                    lines[#lines + 1] = "  " .. translated(i18n, "nvme.warning." .. reason, reason)
                end
                if row.unknown_mask ~= 0 then
                    lines[#lines + 1] = "  " .. translated(i18n, "nvme.warning.unknown_bits", "Unrecognized warning bits")
                        .. ": " .. string.format("0x%02x", row.unknown_mask)
                end
                lines[#lines + 1] = ""
            end
        end
    end
    if summary.partial then lines[#lines + 1] = Technical.state(i18n, "partial") end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
end

local HEALTH_RESOURCES = {
    cpu = { "metrics.cpu", "CPU" }, memory = { "metrics.memory", "Memory" },
    io = { "metrics.io_pressure", "I/O pressure" },
    storage = { "metrics.storage", "Storage" }, disks = { "metrics.storage", "Storage" },
    disk_health = { "metrics.storage", "Storage" }, mounts = { "metrics.storage", "Storage" },
    gpu = { "metrics.gpu", "GPU" }, sensors = { "widgets.sensors", "Sensors" },
    inventory = { "metrics.system", "System" }, system = { "metrics.system", "System" },
    network = { "metrics.network", "Network" }, processes = { "metrics.processes", "Processes" },
}

local function health_lines(snapshot, i18n)
    local summary = Health.summary(snapshot)
    local lines = { translated(i18n, "health.title", "Health and warnings"), "" }
    if #summary.signals == 0 then
        lines[#lines + 1] = summary.state == "unknown"
            and translated(i18n, "health.unknown", "No core observations are available")
            or translated(i18n, "health.none", "No warnings in current observations")
    end
    for _, row in ipairs(summary.signals) do
        local resource = HEALTH_RESOURCES[row.resource]
        local label = resource and translated(i18n, resource[1], resource[2]) or row.resource
        local severity = translated(i18n, "health." .. row.severity,
            row.severity == "critical" and "Critical" or "Warning")
        local description = translated(i18n, "health." .. row.code, row.message)
        local value = row.value ~= nil and " · " .. format_value(row.value, i18n, row.unit) or ""
        lines[#lines + 1] = inspector_text(severity .. " · " .. label .. " · "
            .. description .. value, INSPECTOR_ROW_WIDTH)
        if row.subject then
            lines[#lines + 1] = "  " .. inspector_text(row.subject, INSPECTOR_ROW_WIDTH - 2)
        end
    end
    -- Retain the controller warning bits and per-device explanations behind !.
    local nvme = require("wtop.model.nvme_warnings").summary(snapshot)
    if #nvme.observations > 0 then
        lines[#lines + 1] = ""
        local detail = nvme_warning_lines(snapshot, i18n)
        for index = 1, #detail - 2 do lines[#lines + 1] = detail[index] end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "health.note", "Current observations only.")
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
end

-- Detail reads follow an open overlay, not the table cursor. The queued
-- counter follows the column the renderer actually drew, not merely the
-- columns the user kept in a wide-layout preference. Returning the three
-- contexts together prevents one path from quietly re-enabling another.
local function process_sampling_plan(state)
    state = type(state) == "table" and state or {}
    local active_thread = state.overlay ~= nil
        and type(state.thread_selection) == "table"
        and type(state.thread_selection.resolve) == "function"
    local active_process = state.overlay ~= nil
        and type(state.process_detail) == "table"
        and type(state.process_detail.builder) == "function"
        and state.overlay_builder == state.process_detail.builder
        and type(state.process_detail.resolve) == "function"
    local resolve = active_thread and state.thread_selection.resolve
        or (active_process and state.process_detail.resolve or nil)
    local detail_id
    if resolve then
        local ok, process = pcall(resolve)
        if ok and type(process) == "table" and type(process.id) == "string"
            and process.id ~= "" then
            detail_id = process.id
        end
    end
    local picker = detail_id and active_thread
        and state.thread_selection.mode == "picker"
    local selected = detail_id and not picker and { [detail_id] = true } or {}
    local thread_list = picker and { [detail_id] = true } or {}
    local numa = detail_id and active_process and { [detail_id] = true } or {}

    local queued_drawn, wait_drawn, rate_drawn = false, false, false
    local table_visible = state.page == "processes" and state.overlay == nil
    if table_visible then
        local drawn = type(state.drawn_columns) == "table" and state.drawn_columns or {}
        for _, column in ipairs(drawn) do
            if type(column) == "table" then
                if column.key == "queued" and state.queued_chosen == true then
                    queued_drawn = true
                elseif column.key == "wait_site" and state.wait_site_chosen == true then
                    wait_drawn = true
                elseif (column.key == "io_read_rate" or column.key == "io_write_rate")
                    and state.io_rate_columns_chosen == true then
                    rate_drawn = true
                end
            end
        end
    end
    local visible, visible_wait = {}, {}
    local function add_viewport(target)
        if type(state.source_rows) ~= "table" then return end
        local offset = math.max(0, math.floor(tonumber(state.offset) or 0))
        local count = math.max(0, math.floor(tonumber(state.visible_rows) or 0))
        -- The collector's visible-id parser accepts at most 256 entries.
        -- Reserve one for a detail that may be off screen.
        local maximum = detail_id and 255 or 256
        local last = math.min(#state.source_rows, offset + math.min(count, maximum))
        for index = offset + 1, last do
            local row = state.source_rows[index]
            if row and type(row.id) == "string" then target[row.id] = true end
        end
    end
    if queued_drawn then add_viewport(visible) end
    if wait_drawn then add_viewport(visible_wait) end
    -- The process overlay prints this process's run-queue rate. The thread
    -- picker and thread detail use their own thread rows/counters instead.
    if detail_id and active_process then visible[detail_id] = true end
    local io_rate_requested = table_visible
        and (state.io_rate_requested == true or rate_drawn)
    return {
        selected_process_ids = selected,
        selected_process_thread_list_ids = thread_list,
        selected_process_numa_ids = numa,
        visible_process_ids = next(visible) and visible or nil,
        visible_wait_process_ids = next(visible_wait) and visible_wait or nil,
        scan_process_io = table_visible
            and (state.io_requested == true or io_rate_requested),
        scan_process_io_rate = io_rate_requested,
    }
end

local function thread_detail_request(selection, process, thread)
    if type(selection) ~= "table" or selection.mode ~= "detail"
        or type(process) ~= "table" or type(thread) ~= "table"
        or type(process.pid) ~= "number" or type(thread.tid) ~= "number"
        or process.pid % 1 ~= 0 or thread.tid % 1 ~= 0
        or process.pid <= 0 or thread.tid <= 0
        or (selection.tid ~= nil and selection.tid ~= thread.tid)
        or (selection.starttime_ticks ~= nil
            and selection.starttime_ticks ~= thread.starttime_ticks) then
        return {}
    end
    return { [process.pid] = {
        tid = thread.tid, starttime_ticks = thread.starttime_ticks,
    } }
end

local function run_loop(options, backend, renderer, engine, translator)
    local terminal_capabilities = backend.capabilities()
    local host = engine.replay and { sysname=engine.platform } or native.uname()
    local linux_host = host ~= nil and host.sysname == "Linux"
    local console_cells = terminal_capabilities.native_presentation
        and console_cells_function() or nil
    local action_choices = engine.replay and {} or host and host.sysname == "Windows"
        and WINDOWS_ACTION_CHOICES or (host and host.sysname == "Darwin"
            and {} or SIGNAL_CHOICES)
    local default_orders = Workspace.default_orders()
    local layout_orders, layout_status, layout_trees
    local layout_workspaces, layout_workspace, layout_columns, layout_tabs,
        layout_custom_pages
    if Privilege.restricts_user_files(options.privilege) then
        layout_orders = default_orders
        layout_status = { state = "default", reason = "sudo session ignores persisted layout" }
    else
        layout_orders, layout_status, layout_trees, layout_workspaces, layout_workspace,
            layout_columns, layout_tabs, layout_custom_pages =
                LayoutStore.load(default_orders)
    end
    local workspace = Workspace.new({
        active_tab = options.active_tab,
        orders = layout_orders,
        layout_trees = layout_trees,
        workspaces = layout_workspaces,
        workspace = layout_workspace,
        tab_order = layout_tabs,
        custom_pages = layout_custom_pages,
        i18n = translator,
    })
    local columns, rows = assert(backend.size())
    local visible_widgets = {}
    local overlay_collectors
    local workspace_selection
    local tab_selection
    local move_selection
    local column_selection
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
        if not linux_host then suppressed.network_softnet = true end
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
    local network_owner_target

    local function sync_engine_visibility()
        -- A widget entering or leaving the tree rebuilds the page geometry, so
        -- the next frame must be a full repaint rather than a diff.
        if workspace:set_suppressed(suppressed_widgets()) then
            renderer:invalidate()
            force = true
            dirty = true
        end
        visible_widgets = workspace:visible_widgets(columns, rows)
        assert(engine:set_active_tab(workspace.active, visible_widgets,
            overlay_collectors))
        if workspace:content_page() == "network" and network_owner_target
            and engine.context.connection_owner_target ~= network_owner_target then
            -- Returning to Network needs a new owner reading: the old sample
            -- may still name the same process generation after its fd closed.
            network_owner_target.requested_ns = engine.clock:now_ns()
            network_owner_target.prior_quality = engine.snapshot.quality
                and engine.snapshot.quality.connections
            local task = engine.scheduler:task("connections")
            if task then task.next_due_ns = 0 end
        end
        engine.context.connection_owner_target =
            workspace:content_page() == "network" and network_owner_target or nil
        return visible_widgets
    end
    sync_engine_visibility()
    local process_controller = ProcessTable.new({ sort_key = "cpu", descending = true })
    -- The persisted column set is a choice the user made in an earlier session.
    -- It is applied to the controller rather than to the view so the table and
    -- its editor agree on what is shown from the first frame, with no window in
    -- which the two could render different things.
    if layout_columns then process_controller:set_columns(layout_columns) end
    local decoder = UI.Input.Decoder.new()
    local inspector_registry = make_inspectors(engine)
    local storage_overlay_builder
    local journal_path = "/usr/bin/journalctl"
    if not engine.replay then journal_path = system.find_executable("journalctl") or journal_path end
    local journal_reader = Journal.new({ runner = engine.context.runner, clock = engine.clock,
        journalctl = journal_path })
    local collector_capabilities = engine:probe()
    engine:tick_visible()
    local combined_capabilities = merge(collector_capabilities, {
        inspectors = inspector_registry:probe_all(inspector_context(engine)),
    })
    local process_offset = 0
    local frequency_index = UpdateFrequency.nearest_index(engine.interval_ms or options.interval_ms or 1000)
        or UpdateFrequency.DEFAULT_INDEX
    local paused = engine.paused == true
    local running = true
    local overlay
    local overlay_builder
    local overlay_offset = 0
    local entity_selection
    local confirmation
    local widget_picker
    local search_edit
    -- The process overlay is a plain builder, but the thread drill-down needs
    -- to know it is on screen so that `i` means "inspect a thread" there and
    -- nowhere else.  The picker is a real state because it owns a cursor and a
    -- per-thread read that has to be kept alive across ticks.
    local process_detail
    local unit_view
    local unit_return
    local journal_view
    local session_view
    local service_view
    local event_view
    local fd_view
    local thread_selection
    local connection_owner_selection
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
    local chart_mode = "block"
    local chart_intervals_ns = { 500000000, 1000000000, 2000000000,
        4000000000, 8000000000 }
    local chart_interval_index = 2
    local show_virtual = false
    local mask_remote = options.mask_remote_addresses == true
    local network_query = ""
    local mount_query = ""
    local connection_selected_id
    local workload_collapsed = {}
    local workload_selected_id = nil
    local workload_query = ""
    local workload_jump_id, workload_jump_pid, workload_jump_is_thread, workload_jump_focus,
        workload_jump_unit_name,
        workload_jump_prior_quality
    local hardware_selected_id, hardware_detail
    local hardware_query = ""
    local gpu_selected_pid = nil
    local gpu_client_selection
    local gpu_device_selection
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
            tab_order = workspace:tab_ids(),
            custom_pages = workspace:custom_page_definitions(),
            workspaces = workspace:saved_workspaces(),
            workspace = workspace.workspace,
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

    -- Declared here so move_workload_selection can capture it; assigned by
    -- the first render below.
    local models

    local function hardware_widget_id()
        if workspace:content_page() == "memory" then
            return focused_widget_id() == "dimm_table" and "dimm_table" or "numa_table"
        end
        return "system_devices"
    end

    local function hardware_page()
        return workspace:content_page() == "system"
            or workspace:content_page() == "memory" and (focused_widget_id() == "numa_table"
                or focused_widget_id() == "dimm_table")
    end

    local function first_hardware_id()
        if workspace:content_page() == "memory" then
            if hardware_widget_id() == "dimm_table" then
                local device = engine.snapshot.memory_devices and engine.snapshot.memory_devices.devices
                    and engine.snapshot.memory_devices.devices[1]
                return device and "dimm:" .. device.id
            end
            local node = engine.snapshot.numa and engine.snapshot.numa.nodes
                and engine.snapshot.numa.nodes[1]
            return node and "numa:" .. node.id
        end
        if hardware_query ~= "" then
            return ViewModel.system_device_selection(engine.snapshot, translator, hardware_query)
        end
        local node = Hardware.build(engine.snapshot).nodes[1]
        return node and node.id
    end

    local function move_hardware_selection(step)
        local widget_id = hardware_widget_id()
        local table_model = models and models[widget_id]
        local ids = table_model and table_model.ids
        if type(ids) ~= "table" or #ids == 0 then return end
        local current = 1
        for index, id in ipairs(ids) do
            if id == hardware_selected_id then current = index break end
        end
        current = math.max(1, math.min(#ids, current + step))
        hardware_selected_id = ids[current]
        local widget = last_metadata and last_metadata.widgets
            and last_metadata.widgets[widget_id]
        local visible = widget and widget.visible_rows or math.max(1, rows - 6)
        local offset = widget_offsets[widget_id] or 0
        if current < offset + 1 then offset = current - 1 end
        if current > offset + visible then offset = current - visible end
        widget_offsets[widget_id] = math.max(0, offset)
    end

    local function move_workload_selection(step)
        local table_model = models and models.workload_table
        local ids = table_model and table_model.ids
        if type(ids) ~= "table" or #ids == 0 then return end
        local current = 1
        for index, id in ipairs(ids) do
            if id == workload_selected_id then current = index break end
        end
        current = math.max(1, math.min(#ids, current + step))
        workload_selected_id = ids[current]
        -- Keep the cursor inside the panel window through the same offset
        -- store focused-widget scrolling uses.
        local widget = last_metadata and last_metadata.widgets
            and last_metadata.widgets.workload_table
        local visible = widget and widget.visible_rows
            and widget.visible_rows or math.max(1, rows - 6)
        local offset = widget_offsets.workload_table or 0
        if current < offset + 1 then offset = current - 1 end
        if current > offset + visible then offset = current - visible end
        widget_offsets.workload_table = math.max(0, offset)
    end

    local function move_gpu_selection(step)
        local table_model = models and models.gpu_process_table
        local ids = table_model and table_model.ids
        if type(ids) ~= "table" or #ids == 0 then return end
        local current = 1
        for index, id in ipairs(ids) do
            if id == gpu_selected_pid then current = index break end
        end
        current = math.max(1, math.min(#ids, current + step))
        gpu_selected_pid = ids[current]
        local widget = last_metadata and last_metadata.widgets
            and last_metadata.widgets.gpu_process_table
        local visible = widget and widget.visible_rows
            and widget.visible_rows or math.max(1, rows - 6)
        local offset = widget_offsets.gpu_process_table or 0
        if current < offset + 1 then offset = current - 1 end
        if current > offset + visible then offset = current - visible end
        widget_offsets.gpu_process_table = math.max(0, offset)
    end

    local function move_connection_selection(step)
        local table_model = models and models.connection_table
        local ids = table_model and table_model.ids
        if type(ids) ~= "table" or #ids == 0 then return end
        local current = table_model.selected or 1
        for index, id in ipairs(ids) do
            if id == connection_selected_id then current = index; break end
        end
        current = math.max(1, math.min(#ids, current + step))
        connection_selected_id = ids[current]
        local widget = last_metadata and last_metadata.widgets
            and last_metadata.widgets.connection_table
        local visible = widget and widget.visible_rows
            and widget.visible_rows or math.max(1, rows - 6)
        local offset = widget_offsets.connection_table or 0
        if current < offset + 1 then offset = current - 1 end
        if current > offset + visible then offset = current - visible end
        widget_offsets.connection_table = math.max(0, offset)
    end

    local function selected_connection_row()
        local table_model = models and models.connection_table
        local rows = table_model and table_model.rows or {}
        for _, row in ipairs(rows) do
            if row.connection_ref.id == connection_selected_id then return row end
        end
        return rows[table_model and table_model.selected or 1]
    end

    local function gpu_selected_process()
        -- Reverse navigation: the GPU row keys back into the host process
        -- table by PID, matching the exact identity when several rows share
        -- a PID (multi-GPU clients).
        if gpu_selected_pid == nil then return nil end
        local processes = engine.snapshot and engine.snapshot.processes
            and engine.snapshot.processes.list or {}
        local matches = {}
        for _, process in ipairs(processes) do
            if process.pid == gpu_selected_pid then matches[#matches + 1] = process end
        end
        -- A multi-GPU client has several GPU rows for one host PID; the host
        -- detail is the same row either way, so the first match is correct.
        return matches[1] or nil
    end

    --- The GPU-side record for the selected row.  This is a different table
    -- from the host process above: the DRM clients, engines and memory regions
    -- live here, and a host process never carries them.
    local function gpu_selected_gpu_process()
        if gpu_selected_pid == nil then return nil end
        local devices = engine.snapshot and engine.snapshot.gpus
            and engine.snapshot.gpus.devices or {}
        for _, gpu in ipairs(devices) do
            for _, candidate in ipairs(gpu.processes and gpu.processes.list or {}) do
                if candidate.pid == gpu_selected_pid then return candidate end
            end
        end
        return nil
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
        local brand = engine.replay and ("wtop [" .. translated(translator, "replay.title", "Replay") .. "]") or "wtop"
        local host = engine.snapshot.system and engine.snapshot.system.host
            and engine.snapshot.system.host.hostname
        if type(host) == "string" and host ~= "" then
            return brand .. " " .. host
        end
        return brand
    end

    local function current_frequency_label()
        if engine.replay then
            return translated(translator, "replay.position", "{frame}/{total} @ {speed}x", {
                frame=engine.frame_number, total=engine.reader.count, speed=tostring(engine.speed),
            })
        end
        local level = assert(UpdateFrequency.level(frequency_index))
        local level_name = translated(translator, level.label_id, level.fallback)
        return translated(translator, "sampling.update_frequency",
            "Update rate: " .. level_name, { level = level_name })
    end

    local function cycle_frequency(delta)
        if engine.replay then engine:cycle_speed(); dirty = true; return end
        frequency_index = assert(UpdateFrequency.cycle(frequency_index, delta or 1))
        local level = assert(UpdateFrequency.level(frequency_index))
        assert(engine:set_interval(level.interval_ms))
        dirty = true
    end

    local function selected_process()
        return process_controller:selected()
    end

    local function sync_selected_process()
        local table_widget = last_metadata and last_metadata.widgets
            and last_metadata.widgets.process_table
        local requests = process_sampling_plan({
            page = workspace:content_page(),
            queued_chosen = ProcessColumns.contains(process_controller:columns(), "queued"),
            wait_site_chosen = linux_host
                and ProcessColumns.contains(process_controller:columns(), "wait_site"),
            io_requested = linux_host and process_controller:requires_io(),
            io_rate_requested = linux_host and process_controller:requires_io_rate(),
            io_rate_columns_chosen = linux_host and (
                ProcessColumns.contains(process_controller:columns(), "io_read_rate")
                or ProcessColumns.contains(process_controller:columns(), "io_write_rate")),
            drawn_columns = table_widget and table_widget.columns,
            source_rows = process_controller:rows(),
            offset = process_offset, visible_rows = process_visible_rows(),
            overlay = overlay, overlay_builder = overlay_builder,
            process_detail = process_detail, thread_selection = thread_selection,
        })
        engine.context.visible_process_ids = requests.visible_process_ids
        engine.context.visible_wait_process_ids = requests.visible_wait_process_ids
        engine.context.selected_process_ids = requests.selected_process_ids
        engine.context.selected_process_thread_list_ids =
            requests.selected_process_thread_list_ids
        engine.context.selected_process_numa_ids = requests.selected_process_numa_ids
        engine.context.scan_process_io = requests.scan_process_io
        engine.context.scan_process_io_rate = requests.scan_process_io_rate
    end

    local function jump_to_workload(process, thread_target)
        local is_thread = thread_target ~= nil
        if not process and not is_thread then
            status_message = translated(translator, "process.no_selection", "No process selected")
            return false
        end
        local kind = host and host.sysname == "Windows" and "service" or "cgroup2"
        local id
        if is_thread then
            id = WorkloadNavigation.thread_target_id(process,
                thread_target.thread, thread_target.detail, thread_selection)
        elseif linux_host and not engine.replay then
            id = ProcessCgroup.target_id(process)
        else
            id = WorkloadNavigation.target_id(process, kind)
        end
        local subject_id = is_thread and thread_selection.tid or process.pid
        if not id then
            status_message = is_thread and translated(translator,
                "process.thread_workload_unavailable",
                "Workload membership is unavailable for TID {tid}", { tid = subject_id })
                or translated(translator, "process.workload_unavailable",
                    "Workload membership is unavailable for PID {pid}", { pid = subject_id })
            return false
        end
        if not workspace:select("workloads") then
            status_message = translated(translator, "process.workload_tab_hidden",
                "Show the Workloads tab to use this jump")
            return false
        end
        workload_jump_id, workload_jump_pid, workload_jump_is_thread = id, subject_id, is_thread
        workload_jump_unit_name = nil
        workload_jump_prior_quality = engine.snapshot.quality
            and engine.snapshot.quality.workloads
        workload_selected_id = nil
        workload_query = ""
        status_message = is_thread and translated(translator,
            "process.thread_workload_loading",
            "Finding workload for TID {tid}", { tid = subject_id })
            or translated(translator, "process.workload_loading",
                "Finding workload for PID {pid}", { pid = subject_id })
        process_detail = nil
        unit_return = nil
        thread_selection = nil
        engine.context.selected_thread_ids = {}
        overlay, overlay_builder, overlay_collectors = nil, nil, nil
        overlay_offset = 0
        sync_selected_process()
        dirty = true
        return true
    end

    local function jump_to_network(process)
        if engine.replay then
            status_message = translated(translator, "replay.no_live_reads", "Live inspection is unavailable during replay")
            return false
        end
        if not process then
            status_message = translated(translator, "process.no_selection", "No process selected")
            return false
        end
        local pid, id = process.pid, process.id
        if not linux_host or type(pid) ~= "number" or type(id) ~= "string"
            or not id:match("^" .. tostring(pid) .. ":%d+$") then
            status_message = translated(translator, "process.sockets_unavailable",
                "Socket lookup is unavailable for this process")
            return false
        end
        if not workspace:select("network") then
            status_message = translated(translator, "process.sockets_tab_hidden",
                "Show the Network tab to use this jump")
            return false
        end
        network_owner_target = { pid = pid, id = id,
            requested_ns = engine.clock:now_ns(),
            prior_quality = engine.snapshot.quality
                and engine.snapshot.quality.connections }
        network_query = ""
        connection_selected_id = nil
        process_detail = nil
        unit_return = nil
        thread_selection = nil
        engine.context.selected_thread_ids = {}
        overlay, overlay_builder, overlay_collectors = nil, nil, nil
        overlay_offset = 0
        local task = engine.scheduler:task("connections")
        if task then task.next_due_ns = 0 end
        status_message = translated(translator, "process.sockets_loading",
            "Finding sockets for PID {pid}", { pid = pid })
        sync_selected_process()
        dirty = true
        return true
    end

    local function current_thread_workload_source()
        if not thread_selection or thread_selection.mode ~= "detail" then return nil end
        local snapshot = engine.snapshot
        local quality = snapshot.quality and snapshot.quality.processes
        if not quality or quality.status ~= "ok" then return nil end
        local processes = snapshot.processes or {}
        local process = type(processes.by_id) == "table"
            and processes.by_id[thread_selection.process_id] or nil
        if not process then
            for _, candidate in ipairs(processes.list or {}) do
                if candidate.id == thread_selection.process_id then
                    process = candidate
                    break
                end
            end
        end
        if not process then return nil end
        local thread
        for _, candidate in ipairs(process.thread_rows or {}) do
            if candidate.tid == thread_selection.tid
                and candidate.starttime_ticks == thread_selection.starttime_ticks then
                thread = candidate
                break
            end
        end
        local detail = type(process.thread_details) == "table"
            and process.thread_details[thread_selection.tid] or nil
        return process, thread, detail
    end

    local function show_overlay(lines_or_builder, collectors, owner)
        -- Anything that opens an overlay replaces whatever was open, so the
        -- selections that owned the old one are released here: a key handler
        -- left set for an overlay that is no longer on screen would keep
        -- swallowing input for it.
        --
        -- The selection this overlay belongs to is the exception, and it has to
        -- name itself.  `open_thread_detail` sets up its own state and then
        -- opens a builder through here, so a blanket clear took that state
        -- away on the same call and the thread detail never rendered.
        if owner == nil or owner ~= thread_selection then
            thread_selection = nil
            engine.context.selected_thread_ids = {}
        end
        if owner ~= gpu_client_selection then gpu_client_selection = nil end
        if owner ~= gpu_device_selection then gpu_device_selection = nil end
        if owner ~= entity_selection then entity_selection = nil end
        if owner ~= column_selection then column_selection = nil end
        if owner ~= workspace_selection then workspace_selection = nil end
        if owner ~= tab_selection then tab_selection = nil end
        if owner ~= hardware_detail then hardware_detail = nil end
        if owner ~= connection_owner_selection then connection_owner_selection = nil end
        if owner ~= fd_view then fd_view = nil end
        if owner ~= unit_view then unit_view = nil end
        if owner ~= journal_view then journal_view = nil end
        if owner ~= session_view then session_view = nil end
        if owner ~= service_view then service_view = nil end
        if owner ~= event_view then event_view = nil end
        overlay_collectors = collectors
        overlay_builder = type(lines_or_builder) == "function" and lines_or_builder or nil
        if overlay_builder then
            overlay = overlay_builder()
        else
            overlay = lines_or_builder
        end
        overlay_offset = 0
        sync_selected_process()
    end

    local function select_hardware_if_visible(id)
        if workspace:content_page() ~= "system" then return end
        local ids = models and models.system_devices and models.system_devices.ids or {}
        for _, candidate in ipairs(ids) do
            if candidate == id then
                hardware_selected_id = id
                move_hardware_selection(0)
                return
            end
        end
    end

    local function navigate_hardware(id)
        if not hardware_detail or type(id) ~= "string" or id == hardware_detail.id then
            return false
        end
        local history = hardware_detail.history
        if #history >= 32 then table.remove(history, 1) end
        history[#history + 1] = hardware_detail.id
        hardware_detail.id = id
        hardware_detail.references = nil
        select_hardware_if_visible(id)
        overlay = overlay_builder()
        overlay_offset = 0
        dirty = true
        return true
    end

    -- Footer actions and key bindings must stay in step, so both funnel into
    -- the same synthetic key event rather than duplicating the handlers.
    local run_command

    local function refresh_signal_menu()
        if not confirmation then return end
        overlay = signal_menu_lines(confirmation.process, confirmation.index, translator,
            terminal_capabilities.unicode ~= false, action_choices)
    end

    local function refresh_widget_picker()
        if not widget_picker then return end
        overlay = widget_picker_lines(widget_picker.mode, widget_picker.items,
            widget_picker.index, translator, terminal_capabilities.unicode ~= false)
    end

    local function refresh_workspace_overlay()
        if not workspace_selection then return end
        workspace_selection.names = workspace:workspace_names()
        workspace_selection.active = workspace.workspace
        overlay = workspace_lines(workspace_selection, translator,
            terminal_capabilities.unicode ~= false)
        local body_rows = math.max(1, rows - 6)
        overlay_offset = math.max(0, 5 + workspace_selection.index - body_rows - 1)
    end

    local function refresh_move_overlay()
        if not move_selection then return end
        overlay = move_target_lines(move_selection, translator,
            terminal_capabilities.unicode ~= false)
        local body_rows = math.max(1, rows - 7)
        overlay_offset = math.max(0, 5 + move_selection.index - body_rows - 1)
    end

    local function refresh_column_overlay()
        if not column_selection then return end
        column_selection.entries = ProcessColumns.entries(process_controller:columns(), linux_host)
        overlay = process_column_lines(column_selection, translator,
            terminal_capabilities.unicode ~= false)
        local body_rows = math.max(1, rows - 7)
        overlay_offset = math.max(0, 5 + column_selection.index - body_rows - 1)
    end

    local function open_column_overlay()
        column_selection = {
            index = 1,
            entries = ProcessColumns.entries(process_controller:columns(), linux_host),
        }
        refresh_column_overlay()
    end

    local function refresh_tab_overlay()
        if not tab_selection then return end
        local previous = tab_selection.entries
            and tab_selection.entries[tab_selection.index]
        tab_selection.entries = workspace:tab_entries()
        if previous then
            for index, entry in ipairs(tab_selection.entries) do
                if entry.id == previous.id then tab_selection.index = index break end
            end
        end
        tab_selection.index = math.max(1,
            math.min(#tab_selection.entries, tab_selection.index))
        overlay = tab_manager_lines(tab_selection, translator,
            terminal_capabilities.unicode ~= false)
        local body_rows = math.max(1, rows - 7)
        overlay_offset = math.max(0, 5 + tab_selection.index - body_rows - 1)
    end

    local function open_tab_overlay()
        tab_selection = { index = workspace:active_index(),
            entries = workspace:tab_entries() }
        refresh_tab_overlay()
    end

    local function tab_refusal(reason)
        local names = {
            last_tab = { "tabs.last_tab", "Keep at least one tab" },
            tab_edge = { "tabs.edge", "Tab is already at the edge" },
            tab_hidden = { "tabs.hidden", "Show the tab before moving it" },
            custom_page_limit = { "tabs.custom_limit", "Custom page limit reached" },
            invalid_custom_page_name = { "tabs.invalid_name", "Enter a usable page name" },
            not_custom_page = { "tabs.only_custom", "Only custom pages can be renamed or deleted" },
        }
        local label = names[reason]
        if label then status_message = translated(translator, label[1], label[2]) end
    end

    -- A column change is a layout change and belongs in the same file as every
    -- other view arrangement, so the next session opens with the table the
    -- user left rather than resetting it.  It is recorded on the session, not
    -- written here: the save is the one the exit path already performs, and a
    -- file write per keypress would put a disk hit in the middle of holding
    -- down an arrow.
    --
    -- Snapshotted through normalize, which for a list the model already keeps
    -- canonical returns an equal one.  The copy matters only if some later edit
    -- starts editing the controller's list in place instead of replacing it;
    -- then the session holds the state as it was when the user last chose.
    local function record_column_change()
        layout_columns = ProcessColumns.normalize(process_controller:columns())
        workspace.dirty = true
    end

    -- A refusal is reported rather than left silent: a toggle that does nothing
    -- and says nothing is indistinguishable from a broken key.
    local function column_refusal(reason)
        if reason == "column_required" then
            status_message = translated(translator, "process.columns_cannot_hide",
                "PID and Command identify a row and are always shown")
        elseif reason == "column_edge" then
            status_message = translated(translator, "process.columns_edge",
                "That column is already at the end")
        elseif reason == "column_hidden" then
            status_message = translated(translator, "process.columns_hidden",
                "Show the column before moving it")
        end
    end

    local function open_move_overlay()
        local targets = workspace:move_targets()
        local focused = workspace.focus[workspace.active]
        if #targets == 0 then
            -- A one-widget page has nowhere to drop, and saying so is more
            -- useful than a list with a single unselectable row in it.
            show_overlay({
                translated(translator, "layout.move_title_nothing", "Move {widget}", {
                    widget = tostring(focused or "?"),
                }),
                "",
                translated(translator, "layout.move_no_targets",
                    "This page has no other widget to move onto"),
                "",
                translated(translator, "inspector.close_hint", "Esc/Enter closes"),
            })
            return
        end
        local specs = workspace.widgets[workspace.active] or {}
        local function label_of(id)
            local spec = specs[id]
            return (spec and spec.panel_title) or id
        end
        local rows = {}
        for _, id in ipairs(targets) do rows[#rows + 1] = { id = id, title = label_of(id) } end
        move_selection = {
            targets = rows,
            index = 1,
            position = "after",
            title = label_of(focused),
        }
        refresh_move_overlay()
    end

    local function open_workspace_overlay()
        local names = workspace:workspace_names()
        workspace_selection = {
            names = names,
            active = workspace.workspace,
            -- Start on the new-workspace row only when there is nothing to
            -- switch to yet; otherwise the cursor lands on the live workspace,
            -- which is the row the user is most likely reading.
            index = 1,
            draft = "",
            renaming = false,
            truncated = #names > MAX_WORKSPACE_ROWS,
        }
        if #names == 0 then workspace_selection.index = 1 end
        refresh_workspace_overlay()
    end

    local function refresh_entity_picker()
        if not entity_selection then return end
        if entity_selection.inspector == "service.systemd" then
            local selected = entity_selection.entities[entity_selection.index]
            local visible, matching = Systemd.filter_entities(entity_selection.all_entities,
                entity_selection.query, 256)
            entity_selection.entities, entity_selection.matching = visible, matching
            entity_selection.index = math.max(1, math.min(#visible, entity_selection.index))
            for index, item in ipairs(visible) do
                if selected and item.id == selected.id then entity_selection.index = index break end
            end
            entity_selection.truncated = entity_selection.source_truncated or matching > 256
        end
        overlay = entity_picker_lines(entity_selection.title, entity_selection.entities,
            entity_selection.index, translator, entity_selection.truncated,
            terminal_capabilities.unicode ~= false)
        if entity_selection.inspector == "service.systemd" then
            table.insert(overlay, 3, translated(translator, "systemd.unit_count",
                "{visible}/{matching} units · {total} collected", {
                    visible = #entity_selection.entities, matching = entity_selection.matching,
                    total = #entity_selection.all_entities,
                }))
            table.insert(overlay, 4, translated(translator, "systemd.unit_filter", "Filter: {query}", {
                query = entity_selection.query_edit and (entity_selection.query .. "_")
                    or entity_selection.query ~= "" and entity_selection.query or "—",
            }))
            if entity_selection.source_partial then
                table.insert(overlay, 5, Technical.reason(translator, "systemd_data_incomplete"))
            end
            table.insert(overlay, 2, translated(translator, "systemd.picker_hint",
                "/ search · Enter details · Esc clear/back"))
            if entity_selection.query_edit then
                local filter_line = table.remove(overlay, 5)
                table.insert(overlay, 2, filter_line)
            end
        elseif entity_selection.inspector == "session.logind" and entity_selection.source_partial then
            table.insert(overlay, 3, Technical.reason(translator, "logind_data_partial"))
        end
        local body_rows = math.max(1, rows - 5)
        local selected_line = (entity_selection.inspector == "service.systemd"
            and (entity_selection.source_partial and 8 or 7)
            or entity_selection.inspector == "session.logind" and entity_selection.source_partial and 5 or 4)
            + entity_selection.index
        overlay_offset = math.max(0, selected_line - body_rows - 1)
        if entity_selection.query_edit then overlay_offset = 0 end
    end

    local function open_process_detail(resolve)
        process_detail = { resolve = resolve }
        local builder = function()
            local process = resolve()
            return process_detail_lines(engine.replay and process or process_with_io_detail(process), translator, linux_host)
        end
        process_detail.builder = builder
        show_overlay(builder, { process = true })
    end

    local function open_process_fds()
        if engine.replay then
            status_message = translated(translator, "replay.no_live_reads", "Live inspection is unavailable during replay")
            return
        end
        if not linux_host or not process_detail then return end
        local resolve = process_detail.resolve
        local process = resolve and resolve()
        local listing = require("wtop.linux.process_fds").list(FS.default, process)
        fd_view = { resolve = resolve, listing = listing, index = 1, mode = "list" }
        process_detail = nil
        show_overlay(function()
            return process_fd_lines(fd_view.listing, translator, fd_view.index,
                terminal_capabilities.unicode ~= false)
        end, nil, fd_view)
    end

    local function refresh_fd_list()
        fd_view.mode = "list"
        overlay_builder = function()
            return process_fd_lines(fd_view.listing, translator, fd_view.index,
                terminal_capabilities.unicode ~= false)
        end
        overlay = overlay_builder()
        local body_rows = math.max(1, rows - 5)
        overlay_offset = math.max(0, 4 + fd_view.index - body_rows - 1)
    end

    local function open_connection_owner(connection, owner)
        if engine.replay then
            status_message = translated(translator, "replay.no_live_reads", "Live inspection is unavailable during replay")
            return false
        end
        if not linux_host then
            status_message = translated(translator, "network.owner_linux_only",
                "Socket owner drill-down is available on Linux")
            return false
        end
        local process, failure, observed = ConnectionOwner.resolve(FS.default, connection, owner,
            engine.snapshot.processes and engine.snapshot.processes.list)
        if not process and failure ~= "process_not_sampled" then
            status_message = translated(translator, "network.owner_unavailable",
                "Socket owner could not be verified in the current process sample")
            return false
        end
        local identity = process and process.id or observed.id
        local pending = not process and {
            id = identity, pid = observed.pid, starttime_ticks = observed.starttime_ticks,
            pending_connection_owner = true,
        } or nil
        local deadline = pending and engine.clock:now_ns() + 5 * 1000000000 or nil
        open_process_detail(function()
            for _, current in ipairs(engine.snapshot.processes and engine.snapshot.processes.list or {}) do
                if current.id == identity then return current end
            end
            if pending and engine.clock:now_ns() < deadline then return pending end
            return nil
        end)
        if pending then
            local task = engine.scheduler:task("process")
            if task then task.next_due_ns = 0 end
        end
        return true
    end

    local function refresh_connection_owner_picker()
        if not connection_owner_selection then return end
        overlay = connection_owner_lines(connection_owner_selection, translator,
            terminal_capabilities.unicode ~= false)
        overlay_builder = nil
        local body_rows = math.max(1, rows - 5)
        overlay_offset = math.max(0, 5 + connection_owner_selection.index - body_rows - 1)
    end

    -- The thread cursor is held by TID and start time, not by position. The
    -- CPU-sorted rows move between samples, and a TID can later be reused.
    local function thread_process()
        if not thread_selection or type(thread_selection.resolve) ~= "function" then
            return nil
        end
        return thread_selection.resolve()
    end

    local function sync_thread_selection()
        if not thread_selection then
            engine.context.selected_thread_ids = {}
            return
        end
        local process = thread_process()
        local threads = thread_rows_by_cpu(type(process) == "table"
            and process.thread_rows or nil)
        local index
        for position, thread in ipairs(threads) do
            if thread.tid == thread_selection.tid
                and (thread_selection.starttime_ticks == nil
                    or thread.starttime_ticks == thread_selection.starttime_ticks) then
                index = position
                break
            end
        end
        if not index and thread_selection.mode == "picker" then index = 1 end
        local selected = index and threads[index] or nil
        if selected then
            thread_selection.index = index
            thread_selection.tid = selected.tid
            thread_selection.starttime_ticks = selected.starttime_ticks
        end
        -- The picker needs only the already collected thread rows. Open the
        -- task's own files after Enter, when its detail is on screen.
        engine.context.selected_thread_ids =
            thread_detail_request(thread_selection, process, selected)
        return process, selected
    end

    local function refresh_thread_picker()
        if not thread_selection or thread_selection.mode ~= "picker" then return end
        sync_thread_selection()
        local process = thread_process()
        -- The picker is frozen lines, not a builder, so the process overlay's
        -- builder has to go: left in place it would overwrite these lines on
        -- the very next frame and the picker would flash and vanish.
        overlay_builder = nil
        overlay_collectors = { process = true }
        overlay = thread_picker_lines(process, thread_selection, translator,
            terminal_capabilities.unicode ~= false)
        local body_rows = math.max(1, rows - 5)
        overlay_offset = math.max(0, 4 + thread_selection.index - body_rows - 1)
        sync_selected_process()
    end

    local function select_thread_index(threads, index)
        if #threads > 0 then
            thread_selection.index = math.max(1, math.min(#threads, index))
            -- A redraw resolves the cursor by TID to survive CPU reordering.
            -- Record the deliberate move before redrawing, or that resolution
            -- would restore the old row after every arrow or scroll event.
            thread_selection.tid = threads[thread_selection.index].tid
            thread_selection.starttime_ticks =
                threads[thread_selection.index].starttime_ticks
        end
        refresh_thread_picker()
    end

    local function open_thread_detail()
        if not thread_selection then return end
        thread_selection.mode = "detail"
        sync_thread_selection()
        -- A builder, not frozen lines: the per-thread read arrives on the next
        -- sample and the open overlay has to pick it up.  The selection names
        -- itself as this overlay's owner so opening it is not mistaken for
        -- replacing some other overlay.
        show_overlay(function()
            local live, thread = sync_thread_selection()
            local detail = type(live) == "table" and type(live.thread_details) == "table"
                and live.thread_details[thread_selection.tid] or nil
            return thread_detail_lines(thread, detail, live, translator)
        end, { process = true }, thread_selection)
    end

    local function refresh_gpu_client_overlay()
        if not gpu_client_selection then return end
        -- Re-read the process each frame rather than freezing the client list:
        -- the collector re-reads the DRM fds every tick, and a client that was
        -- closed underneath the open overlay should disappear from the list
        -- instead of being a row that no longer exists.
        local process = gpu_selected_gpu_process() or gpu_client_selection.process
        local clients = type(process) == "table" and process.clients or nil
        if type(clients) ~= "table" or #clients == 0 then
            gpu_client_selection = nil
            overlay, overlay_builder, overlay_collectors = nil, nil, nil
            overlay_offset = 0
            return
        end
        local maximum = math.min(#clients, 256)
        if gpu_client_selection.client then
            -- The detail level keeps its client if that client is still open,
            -- and falls back to the list when it is not.
            local still_open
            for index = 1, maximum do
                if same_client(clients[index], gpu_client_selection.client) then
                    still_open = index
                    break
                end
            end
            if still_open then
                overlay = gpu_client_detail_lines(clients[still_open], translator)
                gpu_client_selection.client = clients[still_open]
                overlay_builder = nil
                local body_rows = math.max(1, rows - 7)
                overlay_offset = math.max(0, 5 + 1 - body_rows - 1)
                return
            end
            gpu_client_selection.client = nil
        end
        local visible = {}
        for index = 1, maximum do visible[index] = clients[index] end
        gpu_client_selection.process = process
        gpu_client_selection.truncated = #clients > maximum
        gpu_client_selection.index = math.max(1, math.min(maximum,
            gpu_client_selection.index))
        overlay = gpu_client_lines({
            process = process, index = gpu_client_selection.index,
        }, translator, terminal_capabilities.unicode ~= false)
        overlay_builder = nil
        local body_rows = math.max(1, rows - 7)
        overlay_offset = math.max(0, 5 + gpu_client_selection.index - body_rows - 1)
    end

    --- The GPU devices the clock overlay can choose between.
    ---
    --- Every device is listed, including one that publishes no clock at all:
    --- the answer "this card has no clock domain" is worth being able to reach,
    --- and dropping the device from the list would make its absence
    --- indistinguishable from a scan that missed it.  The cap matches the
    --- client list so one oversized device list cannot cost more to page
    --- through than the one below it.
    local function gpu_clock_devices()
        local devices = engine.snapshot and engine.snapshot.gpus
            and engine.snapshot.gpus.devices or {}
        return devices
    end

    local function refresh_gpu_device_overlay()
        if not gpu_device_selection then return end
        local devices = gpu_clock_devices()
        if #devices == 0 then
            -- The card went away underneath the overlay.  Closing is the honest
            -- response: an overlay naming a device that no longer exists would
            -- keep showing figures for hardware the kernel has dropped.
            gpu_device_selection = nil
            overlay, overlay_builder, overlay_collectors = nil, nil, nil
            overlay_offset = 0
            return
        end
        local maximum = math.min(#devices, 256)
        gpu_device_selection.devices = devices
        gpu_device_selection.index = math.max(1, math.min(maximum, gpu_device_selection.index or 1))
        if #devices == 1 then
            gpu_device_selection.device = devices[1]
        elseif gpu_device_selection.device then
            -- Re-find by identity rather than by position, so a card appearing
            -- or disappearing does not silently move the selection.
            local still_open = nil
            for index, device in ipairs(devices) do
                if same_device(device, gpu_device_selection.device) then
                    still_open = index
                    break
                end
            end
            if still_open then
                gpu_device_selection.index = still_open
                gpu_device_selection.device = devices[still_open]
            else
                gpu_device_selection.device = nil
            end
        end
        overlay = gpu_device_clock_lines(gpu_device_selection, translator,
            terminal_capabilities.unicode ~= false)
        overlay_builder = nil
        local body_rows = math.max(1, rows - 7)
        overlay_offset = math.max(0, 5 + gpu_device_selection.index - body_rows - 1)
    end

    local function open_thread_picker()
        local process = process_detail and process_detail.resolve and process_detail.resolve()
        local threads = thread_rows_by_cpu(type(process) == "table"
            and process.thread_rows or nil)
        if #threads == 0 then
            -- A process with no readable threads has nothing to pick, and a
            -- picker with no rows would be a dead end the user cannot tell
            -- apart from a broken key.
            status_message = translated(translator, "process.thread_unavailable",
                "No readable thread for that process")
            return
        end
        thread_selection = {
            resolve = process_detail.resolve,
            process_id = process.id,
            tid = threads[1].tid,
            starttime_ticks = threads[1].starttime_ticks,
            index = 1,
            mode = "picker",
        }
        refresh_thread_picker()
    end

    -- Every inspector is reached the same way: enumerate what it can inspect,
    -- then inspect one of them.  An inspector that lists a single entity skips
    -- the picker, so a service with one unit behaves exactly as it did when its
    -- entity was hard-coded, while an inspector that starts listing services or
    -- memory controllers gets a picker without any new UI.
    --
    -- The entity handed to inspect() is always one the enumerate step produced.
    -- Building one by hand meant passing the inspector an entity its own
    -- enumeration had never validated -- a unit name that no longer exists, or a
    -- PMU id the current kernel does not expose.
    local inspect_entity
    local show_session
    local function show_unit(view)
        unit_view = view
        show_overlay(function()
            return systemd_unit_lines(view.result, translator, engine.clock:now_ns())
        end, nil, view)
    end

    show_session = function(view)
        session_view = view
        show_overlay(function()
            return session_lines(view, translator, engine.clock:now_ns())
        end, nil, view)
    end

    local function show_service(view)
        service_view = view
        show_overlay(function()
            local lines = inspector_lines(view.title .. " · " .. tostring(view.entity.name or view.entity.id), view.result, translator)
            lines[#lines + 1] = translated(translator, "events.sshd_hint", "s log summary · r refresh · Esc/Enter closes")
            return lines
        end, nil, view)
    end

    local function show_events(view)
        event_view = view
        show_overlay(function()
            local result = view.parent.result and view.parent.result.details and view.parent.result.details.event_summary
            return event_stats_lines(result, translator, engine.clock:now_ns(), view.parent.entity.unit, "service")
        end, nil, view)
    end

    local function refresh_journal(view)
        local previous = view.result and view.result.data
            and view.result.data.entries[view.index or 1]
        -- Revalidate the unit's manager/name/cgroup before every explicit read.
        local context = inspector_context(engine)
        local verified = inspector_registry:inspect("service.systemd", context, view.parent.entity, "summary")
        view.parent.result = verified
        view.result = journal_reader:read(context, verified)
        view.summary = JournalStats.summarize(view.result)
        local entries = view.result.data and view.result.data.entries or {}
        view.index = math.max(1, math.min(#entries, view.index or 1))
        if previous then
            for index, entry in ipairs(entries) do
                if entry.id == previous.id then view.index = index break end
            end
        end
        if #entries == 0 then view.detail = false end
        journal_view = view
        show_overlay(function()
            return journal_lines(view, translator, terminal_capabilities.unicode ~= false, engine.clock:now_ns())
        end, nil, view)
        overlay_offset = 0
    end

    local function open_unit_journal()
        local view = { parent = unit_view, unit = unit_view.entity.unit,
            manager = unit_view.entity.manager, index = 1, detail = false }
        refresh_journal(view)
    end

    local function open_inspector(inspector_id, title, empty_key, empty_fallback, extra_context)
        if engine.replay then
            show_overlay({ translated(translator, "replay.title", "Replay"), "",
                translated(translator, "replay.no_live_reads", "Live inspection is unavailable during replay") })
            return
        end
        local context = inspector_context(engine)
        context = merge(context, extra_context)
        local entities, enumerate_error = inspector_registry:enumerate(inspector_id, context)
        if not entities or #entities == 0 then
            show_overlay({
                translated(translator, title.key, title.fallback), "",
                translated(translator, empty_key, empty_fallback),
                enumerate_error and Technical.reason(translator, enumerate_error) or "", "",
                translated(translator, "inspector.close_hint", "Esc/Enter closes"),
            })
            return
        end
        if inspector_id == "memory.bandwidth" then
            for _, entity in ipairs(entities) do
                if entity.measurement_scope == "system" then
                    entity.name = translated(translator, "inspector.bandwidth_scope_system", "System aggregate")
                end
            end
        end
        if #entities == 1 and not (inspector_id == "session.logind" and entities.partial) then
            inspect_entity(entities[1], inspector_id, title)
            return
        end
        local maximum = math.min(#entities, 256)
        local visible = {}
        for index = 1, maximum do visible[index] = entities[index] end
        entity_selection = {
            inspector = inspector_id,
            title = title,
            entities = visible,
            index = 1,
            truncated = entities.truncated == true or maximum < #entities,
            source_partial = entities.partial == true,
        }
        if inspector_id == "service.systemd" then
            for _, item in ipairs(entities) do
                item.name = translated(translator,
                    item.manager == "user" and "systemd.manager_user" or "systemd.manager_system",
                    item.manager == "user" and "current user" or "system") .. " · " .. item.unit
            end
            entity_selection.all_entities, entity_selection.query = entities, ""
            entity_selection.source_truncated = entities.truncated == true
            entity_selection.source_partial = entities.partial == true
        end
        refresh_entity_picker()
    end

    inspect_entity = function(entity, explicit_inspector, explicit_title)
        local selection = entity_selection
        entity_selection = nil
        if type(entity) ~= "table" then return end
        local inspector_id = explicit_inspector or selection and selection.inspector or "storage.smart"
        local title = explicit_title or selection and selection.title
            or { key = "inspector.smart", fallback = "SMART / NVMe" }
        if inspector_id == "memory.bandwidth" then
            local Live = require("wtop.inspectors.live_bandwidth")
            if Live.available(native) then
                if engine._bandwidth_live then engine._bandwidth_live:close() end
                local view = Live.new(entity)
                engine._bandwidth_live = view
                view.builder = function()
                    local now = view.paused_at or engine.clock:now_ns()
                    local current = view:current(now)
                    local lines = inspector_lines(translated(translator, title.key, title.fallback)
                        .. " · " .. tostring(entity.name or entity.id), current, translator)
                    local read, read_peak = view:series("read", now)
                    local write, write_peak = view:series("write", now)
                    local maximum = math.max(read_peak, write_peak, 1)
                    local Spark = require("wtop.ui.widgets.sparkline")
                    local chart = { min = 0, max = maximum, mode = "ascii", gap = " " }
                    table.insert(lines, 3, translated(translator, "inspector.bandwidth_live", "Live · 60 s · 1 s/column"))
                    if view.paused_at then lines[3] = translated(translator, "status.paused", "Paused") .. " · " .. lines[3] end
                    table.insert(lines, 4, translated(translator, "inspector.bandwidth_read", "Read")
                        .. " [" .. Spark.render(read, 60, chart) .. "]")
                    table.insert(lines, 5, translated(translator, "inspector.bandwidth_write", "Write")
                        .. " [" .. Spark.render(write, 60, chart) .. "]")
                    table.insert(lines, 6, translated(translator, "inspector.bandwidth_scale", "Scale maximum: {value}",
                        { value = format_value(maximum, translator, "bytes_per_second") }))
                    return lines
                end
                view:set_paused(paused, engine.clock:now_ns())
                view:poll(engine.context, engine.clock:now_ns())
                show_overlay(view.builder)
                return
            end
        end
        local result = inspector_registry:inspect(inspector_id,
            inspector_context(engine), entity, "summary")
        if inspector_id == "service.systemd" then
            unit_return = nil
            show_unit({ entity = entity, result = result, picker = selection })
            return
        end
        if inspector_id == "session.logind" then
            show_session({ entity = entity, result = result, picker = selection })
            return
        end
        if inspector_id == "service.sshd" then
            show_service({ entity = entity, result = result, picker = selection,
                title = translated(translator, title.key, title.fallback) })
            return
        end
        local label = translated(translator, title.key, title.fallback)
        if inspector_id == "storage.smart" and engine._storage_inspector then
            storage_overlay_builder = function()
                local current = inspector_registry:inspect(inspector_id,
                    inspector_context(engine), entity, "summary")
                return inspector_lines(label .. " · " .. tostring(entity.name or entity.id), current, translator)
            end
            show_overlay(storage_overlay_builder, { disk = true, disk_health = true })
            return
        end
        show_overlay(inspector_lines(label .. " · "
            .. tostring(entity.path or entity.name or entity.id or "?"), result, translator))
    end

    local function inspect_smart()
        open_inspector("storage.smart",
            { key = "inspector.smart_devices", fallback = "SMART / NVMe devices" },
            "inspector.no_storage_device", "No inspectable block device")
    end

    local function inspect_bandwidth()
        open_inspector("memory.bandwidth",
            { key = "inspector.ram_bandwidth", fallback = "RAM bandwidth" },
            "inspector.no_bandwidth_source", "No memory bandwidth source is available")
    end

    local function inspect_sshd()
        open_inspector("service.sshd",
            { key = "inspector.sshd", fallback = "sshd service" },
            "inspector.no_service_unit", "No service unit could be inspected")
    end

    local function inspect_systemd()
        local extra
        if workspace:content_page() == "workloads" then
            local workloads = engine.snapshot.workloads or {}
            local id = workload_selected_id or (models and models.workload_table and models.workload_table.ids[1])
            local node = WorkloadNavigation.find(workloads, id)
            if Systemd.from_workload(node) then extra = { systemd_workload = node } end
        end
        open_inspector("service.systemd", { key = "inspector.systemd", fallback = "systemd units" },
            "inspector.no_service_unit", "No service unit could be inspected", extra)
    end

    local function inspect_sessions()
        open_inspector("session.logind", { key = "inspector.logind", fallback = "Login sessions" },
            "inspector.no_login_session", "No readable login session")
    end

    local function open_session_scope()
        local view = session_view
        local context = inspector_context(engine)
        view.result = inspector_registry:inspect("session.logind", context, view.entity, "summary")
        local entities = inspector_registry:enumerate("service.systemd",
            merge(context, { systemd_session = view.result }))
        if not entities or not entities[1] then
            status_message = translated(translator, "session.scope_unavailable", "No verified session scope is available")
            return
        end
        local selected = entities[1]
        local result = inspector_registry:inspect("service.systemd", context, selected, "summary")
        show_unit({ entity = selected, result = result, parent_session = view })
    end

    local function open_unit_process()
        local view = unit_view
        local process, observed = Systemd.resolve_process(view.result,
            engine.snapshot.processes and engine.snapshot.processes.list, FS.default)
        if not process and not observed then
            status_message = translated(translator, "systemd.process_unavailable", "No verified main process is available")
            return
        end
        local identity = process and process.id or observed.id
        local pending = observed
        if pending then pending.pending_systemd_process = true end
        local deadline = pending and engine.clock:now_ns() + 5 * 1000000000
        unit_return = view
        open_process_detail(function()
            for _, current in ipairs(engine.snapshot.processes and engine.snapshot.processes.list or {}) do
                if current.id == identity then return current end
            end
            if pending and engine.clock:now_ns() < deadline then return pending end
        end)
        if pending then
            local task = engine.scheduler:task("process")
            if task then task.next_due_ns = 0 end
        end
    end

    local function render_frame()
        if engine.replay then combined_capabilities = merge(engine.capabilities, { inspectors={} }) end
        if workload_jump_id and workspace:content_page() ~= "workloads" then
            workload_jump_id = nil
            workload_jump_prior_quality = nil
            workload_jump_is_thread = nil
            workload_jump_unit_name = nil
        end
        if last_rendered_page ~= workspace.active then
            -- A page switch changes most of the screen. Repaint it as one
            -- explicit full frame so stale content cannot survive even when
            -- terminal width semantics differ at an old/new glyph boundary.
            renderer:invalidate()
            force = true
        end
        sync_engine_visibility()
        if network_owner_target and workspace:content_page() == "network" then
            local scan = engine.snapshot.connections and engine.snapshot.connections.owner_scan
            local quality = engine.snapshot.quality and engine.snapshot.quality.connections
            if quality and (quality.status ~= "ok"
                or scan and scan.target_id == network_owner_target.id)
                and type(quality.timestamp_ns) == "number"
                and quality.timestamp_ns >= network_owner_target.requested_ns
                and quality ~= network_owner_target.prior_quality
                and status_message == translated(translator, "process.sockets_loading",
                    "Finding sockets for PID {pid}", { pid = network_owner_target.pid }) then
                status_message = ""
            end
        end
        if workload_jump_id and workspace:content_page() == "workloads" then
            local workloads = engine.snapshot.workloads
            local state = engine.snapshot.quality and engine.snapshot.quality.workloads
            local node, result = WorkloadNavigation.result(workloads, state,
                workload_jump_id, workload_jump_prior_quality)
            if result == "found" then
                WorkloadNavigation.expand_ancestors(workloads, node.id, workload_collapsed)
                workload_selected_id = node.id
                workload_jump_id = nil
                workload_jump_prior_quality = nil
                workload_jump_focus = true
                status_message = workload_jump_unit_name and translated(translator,
                    "systemd.workload_found", "Workload for {unit}: {name}", {
                        unit = workload_jump_unit_name, name = node.name or node.id,
                    }) or workload_jump_is_thread and translated(translator,
                    "process.thread_workload_found",
                    "Workload for TID {tid}: {name}", {
                        tid = workload_jump_pid, name = node.name or node.id,
                    }) or translated(translator, "process.workload_found",
                    "Workload for PID {pid}: {name}", {
                        pid = workload_jump_pid, name = node.name or node.id,
                    })
                workload_jump_is_thread = nil
                workload_jump_unit_name = nil
            elseif result == "missing" then
                workload_jump_id = nil
                workload_jump_prior_quality = nil
                status_message = workload_jump_unit_name and translated(translator,
                    "systemd.workload_unavailable", "No visible workload matches this unit")
                    or workload_jump_is_thread and translated(translator,
                    "process.thread_workload_not_found",
                    "No visible workload matches TID {tid}", { tid = workload_jump_pid })
                    or translated(translator, "process.workload_not_found",
                        "No visible workload matches PID {pid}", { pid = workload_jump_pid })
                workload_jump_is_thread = nil
                workload_jump_unit_name = nil
            end
        end
        local models = ViewModel.build(engine, engine.snapshot, translator, combined_capabilities,
            workspace.active, process_controller, visible_widgets, {
                privilege = options.privilege,
                platform = options.platform,
                show_virtual_devices = show_virtual,
                show_pseudo_filesystems = show_virtual,
                mask_remote_addresses = mask_remote,
                connection_query = network_query,
                mount_query = mount_query,
                connection_owner_target = network_owner_target,
                connection_selected = connection_selected_id,
                workload_collapsed = workload_collapsed,
                workload_selected = workload_selected_id,
                workload_query = workload_query,
                gpu_selected = gpu_selected_pid,
                system_selected = hardware_selected_id,
                system_query = hardware_query,
            })
        if workload_query ~= "" and models.workload_table then
            workload_selected_id = models.workload_table.selected
                and models.workload_table.ids[models.workload_table.selected] or nil
        end
        if workload_jump_focus then
            local selected = models.workload_table and models.workload_table.selected
            widget_offsets.workload_table = selected and math.max(0, selected - 1) or 0
            workload_jump_focus = nil
        end
        local process_count = #models.process_table.rows
        local hardware_model = models[hardware_widget_id()]
        if workspace:content_page() == "system" and hardware_query ~= "" then
            hardware_selected_id = hardware_model.ids[hardware_model.selected]
        elseif (workspace:content_page() == "system" or workspace:content_page() == "memory")
            and #hardware_model.ids > 0 then
            hardware_selected_id = hardware_model.ids[hardware_model.selected]
        end
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
        local recovered_note
        if not persisted_error then
            for _, persisted in ipairs({ config_status, layout_status }) do
                if type(persisted) == "table" and persisted.state == "recovered_backup" then
                    recovered_note = translated(translator, "status.recovered_backup",
                        "Recovered {path} from its backup after: {reason}",
                        { path = persisted.path or "?",
                          reason = tostring(persisted.reason or "") })
                    break
                end
            end
        end
        local current_alerts = alert_count(engine.snapshot)
        local status = {
            message = status_message or recovered_note,
            error = persisted_error,
            privilege = options.privilege,
            -- The process table prints its own sort/filter status inside the
            -- panel; repeating it in the footer wasted the one place a
            -- transient message can appear.
            filter = workspace:content_page() == "processes"
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
                { key = "B", id = "actions.chart", fallback = "Chart", command = "chart" },
                { key = "z/Z", id = "actions.chart_zoom", fallback = "Time", command = "chart_zoom" },
                { key = "L", id = "actions.language", fallback = "Lang", command = "language" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            },
        }
        if workspace:content_page() == "processes" then
            status.hints = {
                { key = "/", id = "actions.search", fallback = "Search", command = "search" },
                { key = "o", id = "actions.sort", fallback = "Sort", command = "sort" },
                { key = "O", id = "actions.reverse", fallback = "Reverse", command = "reverse" },
                { key = "t", id = "actions.tree", fallback = "Tree", command = "tree" },
                { key = "p", id = "actions.paths", fallback = "Paths", command = "paths" },
                { key = "Enter", id = "actions.details", fallback = "Details", command = "details" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
            }
            if models.process_table.status.tree then
                table.insert(status.hints, 5,
                    { key = "c", id = "actions.toggle_collapse", fallback = "Collapse",
                      command = "collapse" })
            end
            if host and host.sysname ~= "Darwin" then
                table.insert(status.hints, #status.hints,
                    { key = "g", id = "actions.workload", fallback = "Group",
                      command = "workload" })
            end
            if linux_host then
                table.insert(status.hints, #status.hints,
                    { key = "n", id = "actions.sockets", fallback = "Sockets",
                      command = "sockets" })
            end
            if #action_choices > 0 then
                table.insert(status.hints, #status.hints,
                    { key = "k", id = action_choices == WINDOWS_ACTION_CHOICES
                        and "actions.terminate" or "actions.signal",
                        fallback = action_choices == WINDOWS_ACTION_CHOICES
                            and "Terminate" or "Signal", command = "signal" })
            end
        elseif workspace:content_page() == "compute" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "Space", id = paused and "actions.resume" or "actions.pause",
                  fallback = paused and "Resume" or "Pause", command = "pause" },
                { key = "h", id = "widgets.sensors", fallback = "Sensors", command = "sensors" },
                { key = "f", id = "actions.update_frequency", fallback = "Rate", command = "rate" },
                { key = "z/Z", id = "actions.chart_zoom", fallback = "Time", command = "chart_zoom" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            }
        elseif workspace:content_page() == "storage" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "/", id = "actions.search", fallback = "Search", command = "search" },
                { key = "v", id = "actions.toggle_virtual", fallback = "Virtual", command = "virtual" },
                { key = "s", id = "actions.inspect_smart", fallback = "SMART", command = "smart" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            }
        elseif workspace:content_page() == "network" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "/", id = "actions.search", fallback = "Search", command = "search" },
                { key = "↑↓", id = "actions.workload_select", fallback = "Select", command = "connection_select" },
                { key = "v", id = "actions.toggle_virtual", fallback = "Virtual", command = "virtual" },
                { key = "m", id = "actions.toggle_masking", fallback = "Mask", command = "mask" },
                { key = "s", id = "actions.inspect_smart", fallback = "SMART", command = "smart" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            }
            if linux_host then
                table.insert(status.hints, 4,
                    { key = "Enter", id = "actions.details", fallback = "Details",
                      command = "connection_owner" })
                table.insert(status.hints, 5,
                    { key = "g", id = "network.routes_title", fallback = "Routes",
                      command = "routes" })
                table.insert(status.hints, 6,
                    { key = "w", id = "wifi.title", fallback = "Wi-Fi link", command = "wifi" })
            end
        elseif workspace:content_page() == "gpu" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "↑↓", id = "actions.workload_select", fallback = "Select",
                  command = "gpu_select" },
                { key = "Enter", id = "actions.details", fallback = "Details",
                  command = "details" },
                { key = "h", id = "widgets.sensors", fallback = "Sensors", command = "sensors" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            }
        elseif workspace:content_page() == "workloads" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "/", id = "actions.search", fallback = "Search", command = "search" },
                { key = "↑↓", id = "actions.workload_select", fallback = "Select",
                  command = "workload_select" },
                { key = "c", id = "actions.toggle_collapse", fallback = "Collapse",
                  command = "collapse" },
                { key = "d", id = "actions.inspect_systemd", fallback = "Unit", command = "systemd" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            }
        elseif workspace:content_page() == "system" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "/", id = "actions.search", fallback = "Search", command = "search" },
                { key = "↑↓", id = "actions.workload_select", fallback = "Select",
                  command = "workload_select" },
                { key = "Enter", id = "actions.details", fallback = "Details",
                  command = "details" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            }
        elseif workspace:content_page() == "insights" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "s", id = "actions.inspect_smart", fallback = "SMART", command = "smart" },
                { key = "b", id = "actions.inspect_bandwidth", fallback = "Bandwidth", command = "bandwidth" },
                { key = "d", id = "actions.inspect_systemd", fallback = "Units", command = "systemd" },
                { key = "D", id = "actions.inspect_sshd", fallback = "sshd", command = "sshd" },
                { key = "u", id = "actions.inspect_sessions", fallback = "Sessions", command = "sessions" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
            }
        end
        if workspace:content_page() == "overview" or workspace:content_page() == "compute"
            or workspace:content_page() == "gpu" or workspace:content_page() == "system" then
            table.insert(status.hints, 1,
                { key = "p", id = "power.title", fallback = "Power and limits", command = "power" })
        end
        if current_alerts > 0 then
            table.insert(status.hints, 1,
                { key = "!", id = "health.title", fallback = "Health and warnings" })
        end
        if not linux_host or engine.replay then
            -- The SMART, bandwidth, and sshd inspectors are Linux-only.
            local kept = {}
            for _, hint in ipairs(status.hints or {}) do
                if (not engine.replay or (hint.command ~= "signal" and hint.command ~= "connection_owner"))
                    and (hint.command ~= "smart" or engine._storage_inspector) and hint.command ~= "bandwidth"
                    and hint.command ~= "sshd" and hint.command ~= "systemd" and hint.command ~= "sessions" then
                    kept[#kept + 1] = hint
                end
            end
            status.hints = kept
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
            status.message = action_choices == WINDOWS_ACTION_CHOICES
                and translated(translator, "process.action_prompt",
                    "Choose an action for PID {pid}", { pid = confirmation.process.pid })
                or translated(translator, "process.signal_prompt",
                    "Choose a signal for PID {pid}", { pid = confirmation.process.pid })
            status.warning = true
        end
        if widget_picker then
            status.message = translated(translator,
                widget_picker.mode == "replace" and "layout.replace_prompt"
                    or "layout.add_prompt",
                widget_picker.mode == "replace"
                    and "Choose a replacement for {widget}"
                    or "Choose a widget to add next to {widget}", {
                        widget = tostring(widget_picker.previous),
                    })
            status.warning = true
        end
        if thread_selection then
            local process = thread_process()
            status.message = translated(translator,
                thread_selection.mode == "picker" and "process.thread_prompt"
                    or "process.thread_detail_prompt",
                thread_selection.mode == "picker" and "Choose a thread of PID {pid}"
                    or "Thread {tid} of PID {pid}", {
                        pid = tostring(process and process.pid or "?"),
                        tid = tostring(thread_selection.tid or "?"),
                    })
            status.warning = true
        end
        if engine.replay and not search_edit then
            status.message = status_message or translated(translator, "replay.controls",
                "Space play/pause · Alt-Left/Right step · Alt-Home/End first/last · f speed")
            if engine.reader.truncated then
                status.message = translated(translator, "replay.incomplete", "Interrupted recording: complete measurements only")
                    .. " · " .. status.message
            end
        end
        local grid, metadata = workspace:render(columns, rows, {
            capabilities = terminal_capabilities,
            i18n = translator,
            theme_name = theme_name,
            chart_mode = chart_mode,
            chart_column_ns = chart_intervals_ns[chart_interval_index],
            widgets = models,
            paused = paused,
            frequency_label = current_frequency_label(),
            brand = brand_label(),
            alert_count = current_alerts,
            status = status,
            width_fn = native.available and width_function or nil,
            ascii_unit_width = native.available,
            console_cells = console_cells,
        }, renderer.canvas)
        if thread_selection and thread_selection.mode == "picker" then
            refresh_thread_picker()
        end
        if gpu_client_selection then
            -- The client overlay is a builder in spirit: the collector re-reads
            -- the DRM fds every tick, so the list and the detail are rebuilt
            -- each frame and a client closed underneath the overlay leaves it.
            refresh_gpu_client_overlay()
        end
        if gpu_device_selection then
            -- Same reasoning one level up: the card can be removed and a second
            -- one added between two frames, and the overlay has to notice.
            refresh_gpu_device_overlay()
        end
        if overlay_builder then overlay = overlay_builder() end
        if overlay then
            overlay_offset = math.min(overlay_offset, overlay_max_offset(rows, columns, overlay))
            draw_overlay(grid, metadata.theme, overlay, overlay_offset, terminal_capabilities)
        end
        local presented, present_error
        if type(renderer.present_owned) == "function" then
            presented, present_error, renderer.canvas = renderer:present_owned(grid, force)
        else
            presented, present_error = renderer:present(grid, force)
            renderer.canvas = nil
        end
        if not presented then
            error("terminal render failed: " .. tostring(present_error))
        end
        force = false
        dirty = false
        last_rendered_page = workspace.active
        last_metadata = metadata
        return models
    end

    models = render_frame()
    local last_presented_ns = native.monotonic_ns()

    --- Replace the draft and move the cursor.
    -- The draft deliberately keeps exactly what was typed.  Feeding the
    -- controller's normalised result back in trimmed trailing whitespace, which
    -- made a multi-term query (`user:root state:D`) impossible to type: the
    -- space vanished the moment it was entered.
    local function update_search(value, cursor)
        local maximum = (search_edit.kind == "network" or search_edit.kind == "workloads"
            or search_edit.kind == "hardware" or search_edit.kind == "mounts") and 256
            or process_controller:status().max_query_bytes or 256
        value = tostring(value or "")
        if #value > maximum then
            value = value:sub(1, maximum)
            local _, invalid_at = utf8.len(value)
            if invalid_at then value = value:sub(1, invalid_at - 1) end
        end
        search_edit.draft = value
        search_edit.cursor = math.max(1, math.min(#value + 1, cursor or (#value + 1)))
        if search_edit.kind == "network" then
            network_query = value
        elseif search_edit.kind == "mounts" then
            mount_query = value
        elseif search_edit.kind == "workloads" then
            workload_query = value
            workload_selected_id = nil
        elseif search_edit.kind == "hardware" then
            hardware_query = value
            hardware_selected_id = nil
        else
            process_controller:set_query(value)
            sync_selected_process()
        end
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
        if engine.replay and event.type == "key" and event.alt
            and (event.key == "left" or event.key == "right" or event.key == "home" or event.key == "end") then
            if event.key == "home" then engine:seek(1)
            elseif event.key == "end" then engine:seek(engine.reader.count)
            else engine:step(event.key == "left" and -1 or 1) end
            paused, dirty, force = true, true, true
            return
        end
        if widget_picker then
            local function close()
                widget_picker = nil
                overlay = nil
                overlay_builder = nil
                overlay_collectors = nil
                overlay_offset = 0
                sync_selected_process()
                dirty = true
            end
            if event.type == "key" and (event.key == "up" or event.key == "down") then
                local count = #widget_picker.items
                if count > 0 then
                    widget_picker.index = ((widget_picker.index - 1
                        + (event.key == "down" and 1 or -1)) % count) + 1
                end
                refresh_widget_picker()
                dirty = true
            elseif event.type == "key" and event.key == "enter" then
                local item = widget_picker.items[widget_picker.index]
                local previous = widget_picker.previous
                local applied, apply_error
                if widget_picker.mode == "replace" then
                    applied, apply_error = workspace:replace_focused_widget(item.id)
                else
                    applied, apply_error = workspace:add_focused_widget(item.id, "after")
                end
                status_message = applied
                    and translated(translator,
                        widget_picker.mode == "replace" and "layout.widget_replaced"
                            or "layout.widget_added",
                        widget_picker.mode == "replace" and "{widget} replaced {previous}"
                            or "{widget} added", {
                            widget = item.title, previous = tostring(previous),
                        })
                    or translated(translator, "layout.widget_change_failed",
                        "Layout change refused: {reason}", {
                            reason = translated(translator, "reason." .. tostring(apply_error),
                                tostring(apply_error)),
                        })
                close()
                if applied then
                    sync_engine_visibility()
                    dirty = true
                end
            elseif event.type == "key" then
                close()
                status_message = translated(translator, "layout.widget_cancelled",
                    "Layout change cancelled")
            end
            return
        end
        if confirmation then
            local function close()
                confirmation = nil
                overlay = nil
                overlay_builder = nil
                overlay_collectors = nil
                overlay_offset = 0
                sync_selected_process()
                dirty = true
            end
            if event.type == "key" and (event.key == "up" or event.key == "down") then
                local count = #action_choices
                confirmation.index = ((confirmation.index - 1
                    + (event.key == "down" and 1 or -1)) % count) + 1
                refresh_signal_menu()
                dirty = true
            elseif event.type == "key" and event.key == "enter" then
                local choice = action_choices[confirmation.index]
                local sent, send_error = Actions.signal_process(confirmation.process, choice.number)
                status_message = sent and (action_choices == WINDOWS_ACTION_CHOICES
                    and translated(translator, "process.terminated",
                        "Process {pid} terminated", { pid = confirmation.process.pid })
                    or translated(translator, "process.signal_sent",
                        "{signal} sent to PID {pid}",
                        { signal = choice.name, pid = confirmation.process.pid }))
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
                if search_edit.kind == "network" then
                    network_query = network_query:match("^%s*(.-)%s*$")
                elseif search_edit.kind == "mounts" then
                    mount_query = mount_query:match("^%s*(.-)%s*$")
                elseif search_edit.kind == "workloads" then
                    workload_query = workload_query:match("^%s*(.-)%s*$")
                elseif search_edit.kind == "hardware" then
                    hardware_query = hardware_query:match("^%s*(.-)%s*$")
                end
                search_edit = nil
                dirty = true
            elseif key == "escape" then
                if search_edit.kind == "network" then
                    network_query = search_edit.original
                elseif search_edit.kind == "mounts" then
                    mount_query = search_edit.original
                elseif search_edit.kind == "workloads" then
                    workload_query = search_edit.original
                    workload_selected_id = search_edit.original_selected_id
                elseif search_edit.kind == "hardware" then
                    hardware_query = search_edit.original
                    hardware_selected_id = search_edit.original_selected_id
                else
                    process_controller:set_query(search_edit.original)
                    if search_edit.original_selected_id then
                        process_controller:select_id(search_edit.original_selected_id)
                    end
                    sync_selected_process()
                end
                search_edit = nil
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
            if tab_selection then
                local selection = tab_selection
                local count = #selection.entries
                local selected = selection.entries[selection.index]
                if selection.renaming then
                    if event.type == "key" and event.key == "enter" then
                        local renamed, reason = workspace:rename_custom_page(
                            selection.renaming, selection.draft)
                        if renamed then
                            selection.renaming, selection.draft = nil, nil
                            renderer:invalidate()
                        else tab_refusal(reason) end
                    elseif event.type == "key" and event.key == "escape" then
                        selection.renaming, selection.draft = nil, nil
                    elseif event.type == "key" and event.key == "backspace" then
                        selection.draft = utf8_backspace(selection.draft or "")
                    elseif event.type == "key" and event.text
                        and not event.ctrl and not event.alt then
                        local draft = (selection.draft or "") .. event.text:gsub("[%c]", "")
                        if #draft <= 64 and utf8.len(draft) then selection.draft = draft end
                    end
                    refresh_tab_overlay()
                    dirty = true
                    return
                end
                if selection.confirm_delete then
                    if event.type == "key" and event.key == "x"
                        and selected and selected.id == selection.confirm_delete then
                        local deleted, reason = workspace:remove_custom_page(selected.id)
                        if deleted then
                            sync_engine_visibility()
                            renderer:invalidate()
                        else tab_refusal(reason) end
                    end
                    selection.confirm_delete = nil
                    refresh_tab_overlay()
                    dirty = true
                    return
                end
                if event.type == "key" and event.key == "n" then
                    local created, id_or_reason = workspace:new_custom_page(
                        workspace.focus[workspace.active])
                    if created then
                        selection.entries = { { id = id_or_reason } }
                        selection.index = 1
                        sync_engine_visibility()
                        renderer:invalidate()
                    else tab_refusal(id_or_reason) end
                    refresh_tab_overlay()
                    dirty = true
                elseif selected and event.type == "key" and event.key == "c" then
                    local copied, id_or_reason = workspace:duplicate_page(selected.id)
                    if copied then
                        selection.entries = { { id = id_or_reason } }
                        selection.index = 1
                        sync_engine_visibility()
                        renderer:invalidate()
                    else tab_refusal(id_or_reason) end
                    refresh_tab_overlay()
                    dirty = true
                elseif selected and event.type == "key" and event.key == "r" then
                    if selected.custom then
                        selection.renaming = selected.id
                        selection.draft = selected.label
                        refresh_tab_overlay()
                    else tab_refusal("not_custom_page") end
                    dirty = true
                elseif selected and event.type == "key" and event.key == "x" then
                    if selected.custom then
                        selection.confirm_delete = selected.id
                        refresh_tab_overlay()
                    else tab_refusal("not_custom_page") end
                    dirty = true
                elseif event.type == "key" and (event.key == "up" or event.key == "down"
                    or event.key == "pageup" or event.key == "pagedown"
                    or event.key == "home" or event.key == "end") then
                    if event.key == "home" then selection.index = 1
                    elseif event.key == "end" then selection.index = count
                    else
                        local delta = (event.key == "pageup" or event.key == "pagedown")
                            and math.max(1, rows - 8) or 1
                        if event.key == "up" or event.key == "pageup" then delta = -delta end
                        selection.index = math.max(1, math.min(count, selection.index + delta))
                    end
                    refresh_tab_overlay()
                    dirty = true
                elseif selected and event.type == "key" and event.key == "space" then
                    local changed, reason = selected.visible
                        and workspace:hide_tab(selected.id) or workspace:show_tab(selected.id)
                    if changed then
                        sync_engine_visibility()
                        renderer:invalidate()
                    else tab_refusal(reason) end
                    refresh_tab_overlay()
                    dirty = true
                elseif selected and event.type == "key"
                    and (event.key == "left" or event.key == "right") then
                    local moved, reason = workspace:move_tab(selected.id,
                        event.key == "left" and -1 or 1)
                    if moved then renderer:invalidate() else tab_refusal(reason) end
                    refresh_tab_overlay()
                    dirty = true
                elseif selected and selected.visible and event.type == "key"
                    and event.key == "enter" then
                    workspace:select(selected.id)
                    tab_selection = nil
                    overlay, overlay_builder, overlay_collectors = nil, nil, nil
                    overlay_offset = 0
                    sync_engine_visibility()
                    dirty = true
                elseif event.type == "key" and (event.key == "escape" or event.key == "q"
                        or event.key == "?" or event.key == "f1") then
                    tab_selection = nil
                    overlay, overlay_builder, overlay_collectors = nil, nil, nil
                    overlay_offset = 0
                    dirty = true
                end
                return
            end
            if column_selection then
                local selection = column_selection
                local count = #selection.entries
                local selected = selection.entries[selection.index]
                local navigate = event.type == "key"
                    and (event.key == "up" or event.key == "down"
                        or event.key == "pageup" or event.key == "pagedown"
                        or event.key == "home" or event.key == "end")
                if navigate and count > 0 then
                    if event.key == "home" then
                        selection.index = 1
                    elseif event.key == "end" then
                        selection.index = count
                    else
                        local delta = (event.key == "pageup" or event.key == "pagedown")
                            and math.max(1, rows - 8) or 1
                        if event.key == "up" or event.key == "pageup" then delta = -delta end
                        selection.index = math.max(1, math.min(count, selection.index + delta))
                    end
                    refresh_column_overlay()
                    dirty = true
                elseif event.type == "mouse" and event.action == "scroll" then
                    selection.index = math.max(1, math.min(count, selection.index + 1))
                    refresh_column_overlay()
                    dirty = true
                elseif selected and event.type == "key" and event.key == "space" then
                    local _, reason = process_controller:toggle_column(selected.key)
                    if reason == nil then record_column_change() end
                    column_refusal(reason)
                    refresh_column_overlay()
                    dirty = true
                elseif selected and event.type == "key"
                    and (event.key == "left" or event.key == "right") then
                    local _, reason = process_controller:move_column(selected.key,
                        event.key == "left" and -1 or 1, linux_host)
                    if reason == nil then record_column_change() end
                    column_refusal(reason)
                    refresh_column_overlay()
                    dirty = true
                elseif event.type == "key" and (event.key == "escape" or event.key == "q"
                        or event.key == "enter" or event.key == "?" or event.key == "f1") then
                    column_selection = nil
                    overlay = nil
                    overlay_builder = nil
                    overlay_collectors = nil
                    overlay_offset = 0
                    dirty = true
                end
                return
            end
            if move_selection then
                local selection = move_selection
                local count = #selection.targets
                if event.type == "key" and (event.key == "up" or event.key == "down"
                    or event.key == "home" or event.key == "end")
                then
                    if event.key == "home" then
                        selection.index = 1
                    elseif event.key == "end" then
                        selection.index = count
                    else
                        selection.index = math.max(1, math.min(count,
                            selection.index + (event.key == "up" and -1 or 1)))
                    end
                    refresh_move_overlay()
                    dirty = true
                elseif event.type == "key"
                    and (event.key == "left" or event.key == "right"
                        or event.key == "tab")
                then
                    -- Before/after is one bit, not a second list: offering both
                    -- as rows would double a list that is already one screen.
                    -- The keys set the side rather than flipping it, so holding
                    -- right does not oscillate.
                    local step = (event.key == "right"
                        or (event.key == "tab" and not event.shift)) and 1 or -1
                    selection.position = step > 0 and "after" or "before"
                    refresh_move_overlay()
                    dirty = true
                elseif event.type == "key" and event.key == "enter" then
                    local target = selection.targets[selection.index]
                    if target then
                        local moved, move_error = workspace:move_focused_to(
                            target.id, selection.position)
                        move_selection = nil
                        if moved then
                            status_message = translated(translator, "layout.widget_moved",
                                "{widget} moved", { widget = selection.title })
                            overlay, overlay_builder, overlay_collectors = nil, nil, nil
                            overlay_offset = 0
                            status_dirty = true
                        else
                            overlay, overlay_builder, overlay_collectors = nil, nil, nil
                            overlay_offset = 0
                            status_message = translated(translator,
                                "layout.widget_change_failed",
                                "Layout change refused: {reason}", {
                                    reason = translated(translator,
                                        "reason." .. tostring(move_error),
                                        tostring(move_error)),
                                })
                            dirty = true
                        end
                    end
                elseif event.type == "key" and (event.key == "escape" or event.key == "q") then
                    move_selection = nil
                    overlay, overlay_builder, overlay_collectors = nil, nil, nil
                    overlay_offset = 0
                    dirty = true
                end
                return
            end
            if workspace_selection then
                local selection = workspace_selection
                local last = #selection.names + 1
                local named = selection.index <= #selection.names
                    and selection.names[selection.index] or nil
                -- A name is being typed on the new-workspace row, or in a
                -- rename of the selected row.  While that is true, every
                -- printable key is text, and the commands below stand down.
                local editing = selection.renaming or selection.index == last
                if not editing and event.type == "key" and event.key == "r"
                    and named ~= nil
                then
                    -- Renaming starts from the name as it stands, so the first
                    -- keystroke is a deletion rather than an insertion in the
                    -- middle of text the user cannot see the start of.
                    selection.renaming = true
                    selection.draft = named
                    refresh_workspace_overlay()
                    dirty = true
                elseif not editing and event.type == "key" and event.key == "x" then
                    if named then
                        local removed, remove_error = workspace:delete_workspace(named)
                        if removed then
                            status_message = translated(translator,
                                "layout.workspace_deleted", "Workspace {name} deleted",
                                { name = named })
                            selection.index = math.min(selection.index, #selection.names)
                            selection.names = workspace:workspace_names()
                            if #selection.names > MAX_WORKSPACE_ROWS then
                                selection.truncated = true
                            end
                            selection.active = workspace.workspace
                            refresh_workspace_overlay()
                        else
                            status_message = translated(translator,
                                "layout.workspace_change_failed",
                                "Workspace change refused: {reason}", {
                                    reason = translated(translator,
                                        "reason." .. tostring(remove_error),
                                        tostring(remove_error)),
                                })
                        end
                        dirty = true
                    end
                elseif not editing and event.type == "key" and event.key == "q" then
                    workspace_selection = nil
                    overlay, overlay_builder, overlay_collectors = nil, nil, nil
                    overlay_offset = 0
                    dirty = true
                elseif event.type == "key" and event.text and event.text ~= ""
                    and not event.ctrl and not event.alt
                then
                    -- Off the new-workspace row a printable key moves the cursor
                    -- down to it first: the user asked to type a name, and
                    -- silently doing nothing because the cursor happened to be
                    -- on a saved row would be indistinguishable from a dead key.
                    if not editing then selection.index = last end
                    if #selection.draft < MAX_WORKSPACE_NAME_BYTES then
                        selection.draft = selection.draft
                            .. event.text:gsub("[%c]", " ")
                    end
                    refresh_workspace_overlay()
                    dirty = true
                elseif event.type == "key" and event.key == "backspace" then
                    if editing and #selection.draft > 0 then
                        selection.draft = selection.draft:sub(1, #selection.draft - 1)
                        refresh_workspace_overlay()
                        dirty = true
                    end
                elseif event.type == "key" and event.key == "enter" then
                    if selection.renaming then
                        local from = named
                        local target = selection.draft:gsub("^%s+", ""):gsub("%s+$", "")
                        if target == "" then
                            status_message = translated(translator,
                                "layout.workspace_name_required", "A workspace needs a name")
                            dirty = true
                        elseif target == from then
                            -- Confirming a name that did not change is not a
                            -- rename, and saying "renamed to triage" about
                            -- "triage" would be noise where the user wanted
                            -- silence.
                            selection.renaming = false
                            selection.draft = ""
                            workspace_selection = nil
                            overlay, overlay_builder, overlay_collectors = nil, nil, nil
                            overlay_offset = 0
                            dirty = true
                        else
                            local renamed, rename_error = workspace:rename_workspace(from, target)
                            if renamed then
                                status_message = translated(translator,
                                    "layout.workspace_renamed",
                                    "Workspace {from} renamed to {to}",
                                    { from = from, to = target })
                                selection.names = workspace:workspace_names()
                                selection.index = math.max(1,
                                    index_of_name(selection.names, target))
                                selection.active = workspace.workspace
                                selection.renaming = false
                                selection.draft = ""
                                workspace_selection = nil
                                overlay, overlay_builder, overlay_collectors = nil, nil, nil
                                overlay_offset = 0
                                status_dirty = true
                            else
                                -- The rename is refused, so the editor stays
                                -- open with the typed name still in it: the
                                -- user can see what they wrote and correct the
                                -- one part of it that is wrong.
                                status_message = translated(translator,
                                    "layout.workspace_change_failed",
                                    "Workspace change refused: {reason}", {
                                        reason = translated(translator,
                                            "reason." .. tostring(rename_error),
                                            tostring(rename_error)),
                                    })
                                dirty = true
                            end
                        end
                    else
                        local name = named
                        if selection.index == last then name = selection.draft end
                        if name == nil or name == "" then
                            status_message = translated(translator,
                                "layout.workspace_name_required", "A workspace needs a name")
                            dirty = true
                        else
                            local switched, switch_error
                            if named then
                                -- A row in the list is a workspace that already
                                -- exists, so selecting it switches to it.  It
                                -- used to save the live trees over the target
                                -- first, which meant the list could not switch
                                -- anywhere without destroying what it switched
                                -- to -- the hint said "Enter switches" and the
                                -- key overwrote instead.
                                switched, switch_error = workspace:switch_workspace(named)
                            else
                                switched, switch_error = workspace:save_workspace(name)
                                if not switched then
                                    local _, existing_error = workspace:switch_workspace(name)
                                    switched = existing_error == nil
                                end
                            end
                            if switched then
                                status_message = translated(translator,
                                    "layout.workspace_switched", "Workspace {name}",
                                    { name = name })
                                workspace_selection = nil
                                overlay, overlay_builder, overlay_collectors = nil, nil, nil
                                overlay_offset = 0
                                status_dirty = true
                            else
                                status_message = translated(translator,
                                    "layout.workspace_change_failed",
                                    "Workspace change refused: {reason}", {
                                        reason = translated(translator,
                                            "reason." .. tostring(switch_error),
                                            tostring(switch_error)),
                                    })
                                dirty = true
                            end
                        end
                    end
                elseif event.type == "key" and event.key == "escape" then
                    -- Esc undoes one level at a time.  A rename in progress is
                    -- cancelled first, then typed text on the new-workspace row
                    -- is cleared, and only an editor with nothing to undo
                    -- closes -- otherwise the one key that always seems to work
                    -- is the one that throws away what was just typed.
                    if selection.renaming then
                        selection.renaming = false
                        selection.draft = ""
                        refresh_workspace_overlay()
                    elseif selection.index == last and selection.draft ~= "" then
                        selection.draft = ""
                        refresh_workspace_overlay()
                    else
                        workspace_selection = nil
                        overlay, overlay_builder, overlay_collectors = nil, nil, nil
                        overlay_offset = 0
                    end
                    dirty = true
                elseif event.type == "key" and (event.key == "up" or event.key == "down"
                    or event.key == "home" or event.key == "end")
                    and not selection.renaming
                then
                    -- Navigation is refused mid-rename: the row under the
                    -- cursor is the one being renamed, so moving away would take
                    -- the text somewhere the user never pointed it.
                    if event.key == "home" then
                        selection.index = 1
                    elseif event.key == "end" then
                        selection.index = last
                    else
                        selection.index = math.max(1, math.min(last,
                            selection.index + (event.key == "up" and -1 or 1)))
                    end
                    refresh_workspace_overlay()
                    dirty = true
                end
                return
            end
            if gpu_client_selection then
                local selection = gpu_client_selection
                if not selection.client and event.type == "key"
                    and (event.key == "up" or event.key == "down"
                        or event.key == "pageup" or event.key == "pagedown"
                        or event.key == "home" or event.key == "end")
                then
                    local clients = selection.process
                        and type(selection.process.clients) == "table"
                        and selection.process.clients or {}
                    local count = math.min(#clients, 256)
                    if count > 0 then
                        local delta = (event.key == "pageup" or event.key == "pagedown")
                            and math.max(1, rows - 8) or 1
                        if event.key == "home" then
                            selection.index = 1
                        elseif event.key == "end" then
                            selection.index = count
                        else
                            if event.key == "up" or event.key == "pageup" then
                                delta = -delta
                            end
                            selection.index = math.max(1, math.min(count,
                                selection.index + delta))
                        end
                    end
                    refresh_gpu_client_overlay()
                    dirty = true
                elseif not selection.client and event.type == "mouse"
                    and event.action == "scroll"
                then
                    local clients = selection.process
                        and type(selection.process.clients) == "table"
                        and selection.process.clients or {}
                    local count = math.min(#clients, 256)
                    selection.index = math.max(1, math.min(count,
                        selection.index + (event.direction == "down" and 1 or -1)))
                    refresh_gpu_client_overlay()
                    dirty = true
                elseif event.type == "key" and event.key == "enter" then
                    if selection.client then
                        -- The detail level is a reading, not a form: there is
                        -- nothing to apply, so Enter closes rather than
                        -- pretending to commit.
                        gpu_client_selection = nil
                    else
                        local clients = selection.process
                            and type(selection.process.clients) == "table"
                            and selection.process.clients or {}
                        selection.client = clients[selection.index]
                    end
                    if gpu_client_selection then
                        refresh_gpu_client_overlay()
                    else
                        overlay, overlay_builder, overlay_collectors = nil, nil, nil
                        overlay_offset = 0
                    end
                    dirty = true
                elseif event.type == "key" and (event.key == "escape"
                    or event.key == "q")
                then
                    -- Esc steps back one level -- but only when there is a level
                    -- to step back to.  A process holding a single client never
                    -- had a list, and clearing the selection there re-rendered
                    -- the same detail, so the first Esc changed nothing on
                    -- screen and the overlay needed a second one to leave.
                    local client_count = #(type(selection.process) == "table"
                        and type(selection.process.clients) == "table"
                        and selection.process.clients or {})
                    if selection.client and client_count > 1 then
                        selection.client = nil
                        refresh_gpu_client_overlay()
                    else
                        gpu_client_selection = nil
                        overlay, overlay_builder, overlay_collectors = nil, nil, nil
                        overlay_offset = 0
                    end
                    dirty = true
                end
                return
            end
            if gpu_device_selection then
                local selection = gpu_device_selection
                local devices = gpu_clock_devices()
                -- Arrows only mean something while the list is showing.  With a
                -- single device there is nothing to move between, and a key that
                -- silently re-renders would read as a broken binding.
                if not selection.device and #devices > 1 then
                    if event.type == "key"
                        and (event.key == "up" or event.key == "down"
                            or event.key == "pageup" or event.key == "pagedown"
                            or event.key == "home" or event.key == "end")
                    then
                        local count = math.min(#devices, 256)
                        local delta = (event.key == "pageup" or event.key == "pagedown")
                            and math.max(1, rows - 8) or 1
                        if event.key == "home" then
                            selection.index = 1
                        elseif event.key == "end" then
                            selection.index = count
                        else
                            if event.key == "up" or event.key == "pageup" then
                                delta = -delta
                            end
                            selection.index = math.max(1, math.min(count,
                                selection.index + delta))
                        end
                    elseif event.type == "mouse" and event.action == "scroll" then
                        local count = math.min(#devices, 256)
                        selection.index = math.max(1, math.min(count,
                            selection.index + (event.direction == "down" and 1 or -1)))
                    end
                    refresh_gpu_device_overlay()
                    dirty = true
                elseif event.type == "key" and event.key == "enter" then
                    if selection.device then
                        -- The clocks are a reading, not a form: there is nothing
                        -- to commit, so Enter closes rather than implying one.
                        gpu_device_selection = nil
                        overlay, overlay_builder, overlay_collectors = nil, nil, nil
                        overlay_offset = 0
                    else
                        selection.device = devices[selection.index]
                        refresh_gpu_device_overlay()
                    end
                    dirty = true
                elseif event.type == "key"
                    and (event.key == "escape" or event.key == "q")
                then
                    -- Esc steps back one level -- but only when there is a level
                    -- to step back to.  A host with one GPU has no picker, and
                    -- clearing the selection there would re-render the same
                    -- detail, so Esc would appear to do nothing and the overlay
                    -- could only be left by a second Esc.
                    if selection.device and #devices > 1 then
                        selection.device = nil
                        refresh_gpu_device_overlay()
                    else
                        gpu_device_selection = nil
                        overlay, overlay_builder, overlay_collectors = nil, nil, nil
                        overlay_offset = 0
                    end
                    dirty = true
                end
                return
            end
            if entity_selection then
                if entity_selection.inspector == "service.systemd" and event.type == "key" then
                    local selection = entity_selection
                    if selection.query_edit then
                        if event.key == "escape" or event.key == "enter" then selection.query_edit = false
                        elseif event.ctrl and (event.key == "u" or event.key == "w") then selection.query = ""
                        elseif event.key == "backspace" then selection.query = utf8_backspace(selection.query)
                        elseif event.key == "space" and #selection.query < 256 then selection.query = selection.query .. " "
                        elseif type(event.key) == "string" and utf8.len(event.key) == 1 and not event.ctrl and not event.alt
                            and #selection.query + #event.key <= 256 then
                            selection.query = selection.query .. event.key
                        end
                        refresh_entity_picker()
                        dirty = true
                        return
                    elseif event.key == "/" then
                        selection.query_edit = true
                        refresh_entity_picker()
                        dirty = true
                        return
                    elseif event.key == "escape" and selection.query ~= "" then
                        selection.query = ""
                        refresh_entity_picker()
                        dirty = true
                        return
                    end
                end
                local count = #entity_selection.entities
                if event.type == "mouse" and event.action == "scroll" then
                    entity_selection.index = math.max(1, math.min(count,
                        entity_selection.index + (event.direction == "down" and 1 or -1)))
                    refresh_entity_picker()
                    dirty = true
                elseif event.type == "key" and (event.key == "up" or event.key == "down"
                    or event.key == "pageup" or event.key == "pagedown"
                    or event.key == "home" or event.key == "end")
                then
                    local delta = (event.key == "pageup" or event.key == "pagedown")
                        and math.max(1, rows - 8) or 1
                    if event.key == "home" then entity_selection.index = 1
                    elseif event.key == "end" then entity_selection.index = count
                    else
                        if event.key == "up" or event.key == "pageup" then delta = -delta end
                        entity_selection.index = math.max(1, math.min(count, entity_selection.index + delta))
                    end
                    refresh_entity_picker()
                    dirty = true
                elseif event.type == "key" and event.key == "enter" then
                    if count > 0 then inspect_entity(entity_selection.entities[entity_selection.index]) end
                    dirty = true
                elseif event.type == "key" and (event.key == "escape" or event.key == "q") then
                    entity_selection = nil
                    overlay = nil
                    overlay_builder = nil
                    overlay_collectors = nil
                    overlay_offset = 0
                    dirty = true
                end
                return
            end
            if connection_owner_selection then
                local selection = connection_owner_selection
                local count = #selection.owners
                if event.type == "mouse" and event.action == "scroll" then
                    selection.index = math.max(1, math.min(count,
                        selection.index + (event.direction == "down" and 1 or -1)))
                    refresh_connection_owner_picker()
                    dirty = true
                elseif event.type == "key" and (event.key == "up" or event.key == "down"
                    or event.key == "pageup" or event.key == "pagedown"
                    or event.key == "home" or event.key == "end") then
                    local delta = (event.key == "pageup" or event.key == "pagedown")
                        and math.max(1, rows - 8) or 1
                    if event.key == "home" then selection.index = 1
                    elseif event.key == "end" then selection.index = count
                    else
                        if event.key == "up" or event.key == "pageup" then delta = -delta end
                        selection.index = math.max(1, math.min(count, selection.index + delta))
                    end
                    refresh_connection_owner_picker()
                    dirty = true
                elseif event.type == "key" and event.key == "enter" then
                    open_connection_owner(selection.connection, selection.owners[selection.index])
                    dirty = true
                elseif event.type == "key" and (event.key == "escape" or event.key == "q") then
                    connection_owner_selection = nil
                    overlay, overlay_builder, overlay_collectors = nil, nil, nil
                    overlay_offset = 0
                    dirty = true
                end
                return
            end
            if fd_view then
                local count = #fd_view.listing.entries
                if fd_view.mode == "list" then
                    if event.type == "mouse" and event.action == "scroll" and count > 0 then
                        fd_view.index = math.max(1, math.min(count,
                            fd_view.index + (event.direction == "down" and 1 or -1)))
                        refresh_fd_list()
                        dirty = true
                    elseif event.type == "key" and (event.key == "up" or event.key == "down"
                        or event.key == "pageup" or event.key == "pagedown"
                        or event.key == "home" or event.key == "end") and count > 0 then
                        local delta = (event.key == "pageup" or event.key == "pagedown")
                            and math.max(1, rows - 8) or 1
                        if event.key == "home" then fd_view.index = 1
                        elseif event.key == "end" then fd_view.index = count
                        else
                            if event.key == "up" or event.key == "pageup" then delta = -delta end
                            fd_view.index = math.max(1, math.min(count, fd_view.index + delta))
                        end
                        refresh_fd_list()
                        dirty = true
                    elseif event.type == "key" and event.key == "enter" and count > 0 then
                        local entry = fd_view.listing.entries[fd_view.index]
                        local current = fd_view.resolve and fd_view.resolve()
                        fd_view.detail = require("wtop.linux.process_fds").inspect(
                            FS.default, current, entry.fd)
                        fd_view.mode = "detail"
                        overlay_builder = function()
                            return process_fd_detail_lines(fd_view.detail, translator)
                        end
                        overlay = overlay_builder()
                        overlay_offset = 0
                        dirty = true
                    elseif event.type == "key" and event.key == "escape" then
                        local resolve = fd_view.resolve
                        fd_view = nil
                        open_process_detail(resolve)
                        dirty = true
                    end
                else
                    if event.type == "key" and (event.key == "escape" or event.key == "enter") then
                        fd_view.detail = nil
                        refresh_fd_list()
                        dirty = true
                    elseif event.type == "mouse" and event.action == "scroll" then
                        local maximum = overlay_max_offset(rows, columns, overlay)
                        overlay_offset = math.max(0, math.min(maximum,
                            overlay_offset + (event.direction == "down" and 1 or -1)))
                        dirty = true
                    end
                end
                if event.type == "key" and (event.key == "q" or event.key == "?"
                    or event.key == "f1") then
                    fd_view, process_detail = nil, nil
                    overlay, overlay_builder, overlay_collectors = nil, nil, nil
                    overlay_offset = 0
                    sync_selected_process()
                    dirty = true
                end
                return
            end
            if thread_selection then
                -- The picker owns Up/Down: they move the thread cursor rather
                -- than scrolling, because a cursor that scrolls away is a cursor
                -- the operator has lost.  The detail view behind it has no
                -- cursor of its own, so the same keys scroll there.
                if thread_selection.mode == "picker" then
                    local process = thread_process()
                    local threads = thread_rows_by_cpu(type(process) == "table"
                        and process.thread_rows or nil)
                    local count = #threads
                    local navigate = event.type == "key"
                        and (event.key == "up" or event.key == "down"
                            or event.key == "pageup" or event.key == "pagedown"
                            or event.key == "home" or event.key == "end")
                    if event.type == "mouse" and event.action == "scroll" then
                        select_thread_index(threads,
                            thread_selection.index + (event.direction == "down" and 1 or -1))
                        dirty = true
                    elseif navigate and count > 0 then
                        local index
                        if event.key == "home" then
                            index = 1
                        elseif event.key == "end" then
                            index = count
                        else
                            local delta = (event.key == "pageup" or event.key == "pagedown")
                                and math.max(1, rows - 8) or 1
                            if event.key == "up" or event.key == "pageup" then delta = -delta end
                            index = thread_selection.index + delta
                        end
                        select_thread_index(threads, index)
                        dirty = true
                    elseif event.type == "key" and event.key == "enter" then
                        sync_thread_selection()
                        local selected = threads[thread_selection.index]
                        if selected then
                            thread_selection.tid = selected.tid
                            open_thread_detail()
                        end
                        dirty = true
                    elseif event.type == "key" and event.key == "escape" then
                        -- Back to the process overlay the drill-down started
                        -- from, rather than out to the main table: the thread
                        -- list is a question asked about that process.
                        local resolve = thread_selection.resolve
                        thread_selection = nil
                        engine.context.selected_thread_ids = {}
                        open_process_detail(resolve)
                        dirty = true
                    elseif event.type == "key"
                        and (event.key == "q" or event.key == "?"
                            or event.key == "f1") then
                        thread_selection = nil
                        engine.context.selected_thread_ids = {}
                        process_detail = nil
                        overlay = nil
                        overlay_builder = nil
                        overlay_collectors = nil
                        overlay_offset = 0
                        sync_selected_process()
                        dirty = true
                    end
                elseif event.type == "key" and event.key == "g" and linux_host then
                    local process, thread, detail = current_thread_workload_source()
                    if thread and not detail then
                        status_message = translated(translator, "process.thread_pending",
                            "Reading this thread on the next refresh…")
                    else
                        jump_to_workload(process, { thread = thread, detail = detail })
                    end
                    dirty = true
                elseif event.type == "key" and event.key == "escape" then
                    thread_selection.mode = "picker"
                    refresh_thread_picker()
                    dirty = true
                elseif event.type == "key" and (event.key == "q" or event.key == "?"
                        or event.key == "f1") then
                    thread_selection = nil
                    engine.context.selected_thread_ids = {}
                    process_detail = nil
                    overlay = nil
                    overlay_builder = nil
                    overlay_collectors = nil
                    overlay_offset = 0
                    sync_selected_process()
                    dirty = true
                else
                    local maximum = overlay_max_offset(rows, columns, overlay)
                    if event.type == "mouse" and event.action == "scroll" then
                        overlay_offset = math.max(0, math.min(maximum,
                            overlay_offset + (event.direction == "down" and 1 or -1)))
                        dirty = true
                    elseif event.type == "key" and (event.key == "up" or event.key == "down"
                            or event.key == "pageup" or event.key == "pagedown"
                            or event.key == "home" or event.key == "end") then
                        local page = math.max(1, rows - 6)
                        if event.key == "home" then
                            overlay_offset = 0
                        elseif event.key == "end" then
                            overlay_offset = maximum
                        else
                            local delta = (event.key == "pageup" or event.key == "pagedown")
                                and page or 1
                            if event.key == "up" or event.key == "pageup" then delta = -delta end
                            overlay_offset = math.max(0, math.min(maximum, overlay_offset + delta))
                        end
                        dirty = true
                    elseif event.type == "key" and event.key == "enter" then
                        -- Enter has nothing to apply here; the thread detail is
                        -- a reading, not a form.
                        thread_selection.mode = "picker"
                        refresh_thread_picker()
                        dirty = true
                    end
                end
                return
            end
            if process_detail and overlay and event.type == "key" and event.key == "i" then
                -- Drill-down, not a shortcut: the table above already lists the
                -- busiest threads, and `i` is how the operator reaches the rest.
                open_thread_picker()
                dirty = true
                return
            end
            if journal_view then
                local view = journal_view
                local maximum = overlay_max_offset(rows, columns, overlay)
                local entries = view.result and view.result.data and view.result.data.entries or {}
                if event.type == "key" and event.key == "s" then
                    view.stats = not view.stats
                    overlay_offset = 0
                elseif event.type == "key" and event.key == "r" then
                    refresh_journal(view)
                elseif event.type == "key" and (event.key == "escape" or event.key == "q" or event.key == "enter") then
                    if view.stats then
                        view.stats = false
                        overlay_offset = 0
                    elseif view.detail then
                        view.detail = false
                        overlay_offset = 0
                    elseif event.key == "enter" and entries[view.index] then
                        view.detail = true
                        overlay_offset = 0
                    else
                        local parent = view.parent
                        journal_view = nil
                        show_unit(parent)
                    end
                elseif not view.detail and not view.stats and ((event.type == "key" and (event.key == "up" or event.key == "down"
                        or event.key == "pageup" or event.key == "pagedown" or event.key == "home" or event.key == "end"))
                    or event.type == "mouse" and event.action == "scroll") then
                    local step = event.type == "mouse" and (event.direction == "down" and 1 or -1)
                        or (event.key == "up" or event.key == "pageup") and -1 or 1
                    if event.key == "home" then view.index = 1
                    elseif event.key == "end" then view.index = math.max(1, #entries)
                    else
                        if event.key == "pageup" or event.key == "pagedown" then step = step * math.max(1, (rows - 14) // 2) end
                        view.index = math.max(1, math.min(#entries, view.index + step))
                    end
                    local positions
                    overlay, positions = journal_lines(view, translator,
                        terminal_capabilities.unicode ~= false, engine.clock:now_ns())
                    local selected_line = positions[view.index]
                    local body = math.max(1, rows - 5)
                    if selected_line then
                        local prefix = {}
                        for index = 1, selected_line do prefix[index] = overlay[index] end
                        local wrapped = overlay_content({ width = columns, height = rows }, prefix)
                        overlay_offset = math.max(0, #wrapped - body)
                    else overlay_offset = 0 end
                elseif (view.detail or view.stats) and ((event.type == "key" and (event.key == "up" or event.key == "down"
                        or event.key == "pageup" or event.key == "pagedown" or event.key == "home" or event.key == "end"))
                    or event.type == "mouse" and event.action == "scroll") then
                    local page = math.max(1, rows - 6)
                    local step = event.type == "mouse" and (event.direction == "down" and 1 or -1)
                        or (event.key == "up" or event.key == "pageup") and -1 or 1
                    if event.key == "home" then overlay_offset = 0
                    elseif event.key == "end" then overlay_offset = maximum
                    else
                        if event.key == "pageup" or event.key == "pagedown" then step = step * page end
                        overlay_offset = math.max(0, math.min(maximum, overlay_offset + step))
                    end
                end
                dirty = true
                return
            end
            if event_view and event.type == "key" then
                local view = event_view
                if event.key == "r" then
                    view.parent.result = inspector_registry:inspect("service.sshd", inspector_context(engine), view.parent.entity, "summary")
                    show_events(view)
                    overlay_offset = 0
                    dirty = true
                    return
                elseif event.key == "escape" or event.key == "enter" or event.key == "q" then
                    show_service(view.parent)
                    overlay_offset = 0
                    dirty = true
                    return
                end
            end
            if service_view and event.type == "key" then
                local view = service_view
                if event.key == "s" then
                    show_events({ parent = view })
                    overlay_offset = 0
                    dirty = true
                    return
                elseif event.key == "r" then
                    view.result = inspector_registry:inspect("service.sshd", inspector_context(engine), view.entity, "summary")
                    show_service(view)
                    overlay_offset = 0
                    dirty = true
                    return
                elseif event.key == "escape" or event.key == "enter" or event.key == "q" then
                    local previous = view.picker
                    service_view, overlay, overlay_builder, overlay_collectors = nil, nil, nil, nil
                    overlay_offset = 0
                    if previous then entity_selection = previous; refresh_entity_picker() end
                    dirty = true
                    return
                end
            end
            if session_view and event.type == "key" then
                local view = session_view
                if event.key == "r" then
                    view.result = inspector_registry:inspect("session.logind", inspector_context(engine), view.entity, "summary")
                    show_session(view)
                    dirty = true
                    return
                elseif event.key == "d" then
                    open_session_scope()
                    dirty = true
                    return
                elseif event.key == "escape" or event.key == "enter" or event.key == "q" then
                    local previous = view.picker
                    session_view, overlay, overlay_builder, overlay_collectors = nil, nil, nil, nil
                    overlay_offset = 0
                    if previous then entity_selection = previous; refresh_entity_picker() end
                    dirty = true
                    return
                end
            end
            if unit_view and event.type == "key" then
                if event.key == "r" then
                    local view = unit_view
                    view.result = inspector_registry:inspect("service.systemd", inspector_context(engine), view.entity, "summary")
                    show_unit(view)
                    dirty = true
                    return
                elseif event.key == "p" then
                    open_unit_process()
                    dirty = true
                    return
                elseif event.key == "l" then
                    open_unit_journal()
                    dirty = true
                    return
                elseif event.key == "g" then
                    local result = unit_view.result
                    local id = result and result.status == "ok" and result.entity
                        and result.entity.relations.workload_id
                    if id and workspace:select("workloads") then
                        workload_jump_id, workload_jump_unit_name = id, result.entity.name
                        workload_jump_pid, workload_jump_is_thread = nil, nil
                        workload_jump_prior_quality = engine.snapshot.quality and engine.snapshot.quality.workloads
                        workload_query, workload_selected_id = "", nil
                        status_message = translated(translator, "systemd.workload_loading", "Finding this unit's workload")
                        unit_view, unit_return, overlay, overlay_builder, overlay_collectors = nil, nil, nil, nil, nil
                        overlay_offset = 0
                        local task = engine.scheduler:task("cgroup")
                        if task then task.next_due_ns = 0 end
                        sync_selected_process()
                    else
                        status_message = translated(translator, "systemd.workload_unavailable", "No visible workload matches this unit")
                    end
                    dirty = true
                    return
                elseif event.key == "escape" or event.key == "enter" or event.key == "q" then
                    local parent_session = unit_view.parent_session
                    local previous = unit_view.picker
                    unit_view, overlay, overlay_builder, overlay_collectors = nil, nil, nil, nil
                    overlay_offset = 0
                    if parent_session then show_session(parent_session)
                    elseif previous then entity_selection = previous; refresh_entity_picker() end
                    dirty = true
                    return
                end
            end
            if process_detail and overlay and event.type == "key" and event.key == "g" then
                jump_to_workload(process_detail.resolve())
                dirty = true
                return
            end
            if process_detail and overlay and event.type == "key" and event.key == "n" then
                jump_to_network(process_detail.resolve())
                dirty = true
                return
            end
            if process_detail and overlay and event.type == "key" and event.key == "F" then
                open_process_fds()
                dirty = true
                return
            end
            if engine._bandwidth_live and overlay_builder == engine._bandwidth_live.builder
                and event.type == "key" and event.key == "space" then
                paused = not paused
                engine:set_paused(paused)
                engine._bandwidth_live:set_paused(paused, engine.clock:now_ns())
                dirty = true
                return
            end
            local maximum = overlay_max_offset(rows, columns, overlay)
            if hardware_detail and hardware_detail.references then
                local selection = hardware_detail.references
                local count = #selection.items
                if event.type == "mouse" and event.action == "scroll" then
                    selection.index = math.max(1, math.min(count,
                        selection.index + (event.direction == "down" and 1 or -1)))
                    overlay = overlay_builder()
                    dirty = true
                elseif event.type == "key" and (event.key == "up" or event.key == "down"
                    or event.key == "pageup" or event.key == "pagedown"
                    or event.key == "home" or event.key == "end") then
                    local delta = (event.key == "pageup" or event.key == "pagedown")
                        and math.max(1, rows - 8) or 1
                    if event.key == "home" then selection.index = 1
                    elseif event.key == "end" then selection.index = count
                    else
                        if event.key == "up" or event.key == "pageup" then delta = -delta end
                        selection.index = math.max(1, math.min(count, selection.index + delta))
                    end
                    overlay = overlay_builder()
                    local body_rows = math.max(1, rows - 5)
                    overlay_offset = math.max(0, 4 + selection.index - body_rows - 1)
                    dirty = true
                elseif event.type == "key" and event.key == "enter" then
                    local item = selection.items[selection.index]
                    local graph = Hardware.build(engine.snapshot)
                    local target = item and graph.by_id[item.id]
                    if target and not target.ambiguous then
                        navigate_hardware(target.id)
                    else
                        status_message = translated(translator, "inventory.not_present",
                            "Device not in the current inventory")
                        dirty = true
                    end
                elseif event.type == "key" and event.key == "escape" then
                    hardware_detail.references = nil
                    overlay = overlay_builder()
                    overlay_offset = 0
                    dirty = true
                elseif event.type == "key" and event.key == "q" then
                    hardware_detail = nil
                    overlay, overlay_builder, overlay_collectors = nil, nil, nil
                    overlay_offset = 0
                    sync_selected_process()
                    dirty = true
                end
                return
            end
            if hardware_detail and event.type == "key" and event.key == "r" then
                local graph = Hardware.build(engine.snapshot)
                local related = Hardware.related(graph, hardware_detail.id)
                if related.total == 0 then
                    status_message = translated(translator, "inventory.related_empty",
                        "No related device in the current inventory")
                    dirty = true
                elseif related.total == 1 then
                    navigate_hardware(related.items[1].id)
                else
                    related.source_id = hardware_detail.id
                    related.index = 1
                    hardware_detail.references = related
                    overlay = overlay_builder()
                    overlay_offset = 0
                    dirty = true
                end
                return
            end
            if hardware_detail and event.type == "key" and event.key == "b" then
                local previous = table.remove(hardware_detail.history)
                if previous then
                    hardware_detail.id = previous
                    hardware_detail.references = nil
                    select_hardware_if_visible(previous)
                    overlay = overlay_builder()
                    overlay_offset = 0
                    dirty = true
                end
                return
            end
            if hardware_detail and event.type == "key" and event.key == "p" then
                local graph = Hardware.build(engine.snapshot)
                local node = graph.by_id[hardware_detail.id]
                local parent = node and graph.by_id[node.parent_id]
                if parent then navigate_hardware(parent.id) end
                return
            end
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
                local previous_unit = unit_return
                unit_return, unit_view = nil, nil
                process_detail = nil
                fd_view = nil
                thread_selection = nil
                hardware_detail = nil
                engine.context.selected_thread_ids = {}
                overlay = nil
                overlay_builder = nil
                overlay_collectors = nil
                overlay_offset = 0
                if previous_unit then show_unit(previous_unit) end
                sync_selected_process()
                dirty = true
            end
            return
        end

        if event.type == "mouse" then
            for _, widget_id in ipairs(workspace:content_page() == "memory"
                and { "numa_table", "dimm_table" } or { "system_devices" }) do
                local hardware_widget = last_metadata and last_metadata.widgets
                    and last_metadata.widgets[widget_id]
                if (workspace:content_page() == "system" or workspace:content_page() == "memory") and hardware_widget
                    and event.action == "press" and hardware_widget.rows_y
                    and event.y >= hardware_widget.rows_y
                    and event.y < hardware_widget.rows_y + (hardware_widget.visible_rows or 0)
                    and event.x >= hardware_widget.rows_x
                    and event.x < hardware_widget.rows_x + (hardware_widget.rows_width or 0) then
                    local index = (hardware_widget.offset or 0)
                        + event.y - hardware_widget.rows_y + 1
                    local id = models and models[widget_id] and models[widget_id].ids[index]
                    if id then
                        hardware_selected_id, dirty = id, true
                        workspace.focus[workspace.active] = widget_id
                    end
                    return
                end
            end
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
            if event.action == "scroll" and workspace:content_page() ~= "processes" then
                if scroll_focused_widget(event.direction == "down" and 1 or -1, false) then
                    return
                end
            end
            local table_widget = last_metadata and last_metadata.widgets
                and last_metadata.widgets.process_table
            if workspace:content_page() == "processes" and table_widget then
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
            local connection_widget = last_metadata and last_metadata.widgets
                and last_metadata.widgets.connection_table
            if workspace:content_page() == "network" and connection_widget
                and event.action == "press"
                and event.y >= connection_widget.rows_y
                and event.y < connection_widget.rows_y + (connection_widget.visible_rows or 0)
                and event.x >= connection_widget.rows_x
                and event.x < connection_widget.rows_x + (connection_widget.rows_width or 0) then
                local index = (connection_widget.offset or 0)
                    + (event.y - connection_widget.rows_y) + 1
                local ids = models and models.connection_table and models.connection_table.ids
                if ids and ids[index] then
                    connection_selected_id = ids[index]
                    dirty = true
                end
                return
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
        elseif key == "m" and workspace.edit_mode then
            -- The arrows step one place at a time; naming the target is what
            -- makes this a drop rather than a nudge.
            open_move_overlay()
            dirty = true
        elseif key == "w" and workspace.edit_mode then
            -- Workspaces are a layout concept, so they live in edit mode: a
            -- half-arranged layout is exactly the one worth putting aside.
            open_workspace_overlay()
            dirty = true
        elseif key == "b" and workspace.edit_mode then
            open_tab_overlay()
            dirty = true
        elseif (key == "a" or key == "r" or key == "d") and workspace.edit_mode then            local focused = workspace.focus[workspace.active]
            local spec = workspace.widgets[workspace.active][focused]
            local previous_title = (spec and spec.panel_title) or tostring(focused)
            if key == "d" then
                local removed, remove_error = workspace:remove_focused_widget()
                status_message = removed
                    and translated(translator, "layout.widget_removed",
                        "{widget} removed", { widget = previous_title })
                    or translated(translator, "layout.widget_change_failed",
                        "Layout change refused: {reason}", {
                            reason = translated(translator, "reason." .. tostring(remove_error),
                                tostring(remove_error)),
                        })
                if removed then
                    sync_engine_visibility()
                    dirty = true
                end
            else
                local items = workspace:palette()
                widget_picker = {
                    mode = key == "r" and "replace" or "add",
                    items = items,
                    index = 1,
                    previous = previous_title,
                }
                refresh_widget_picker()
                overlay_offset = 0
                dirty = true
            end
        elseif (key == "j" or key == "k") and hardware_page() then
            move_hardware_selection(key == "j" and 1 or -1)
            dirty = true
        elseif key == "enter" and hardware_page() then
            if workspace:content_page() == "system" and hardware_query ~= "" then
                hardware_selected_id = ViewModel.system_device_selection(
                    engine.snapshot, translator, hardware_query, hardware_selected_id)
            end
            if workspace:content_page() == "memory" and hardware_selected_id
                and not hardware_selected_id:match(hardware_widget_id() == "dimm_table" and "^dimm:" or "^numa:") then
                hardware_selected_id = nil
            end
            hardware_selected_id = hardware_selected_id or first_hardware_id()
            -- Memory can legitimately have no readable DIMM/NUMA inventory;
            -- its detail overlay explains that state. Only an empty System
            -- search should refuse to open a different, unfiltered device.
            if not hardware_selected_id and workspace:content_page() == "system"
                and hardware_query ~= "" then
                status_message = translated(translator, "system.no_matching_device",
                    "No matching device is visible")
                dirty = true
                return
            end
            hardware_detail = { id = hardware_selected_id, history = {} }
            show_overlay(function()
                if hardware_detail.id == nil then
                    hardware_detail.id = first_hardware_id()
                    hardware_selected_id = hardware_detail.id
                end
                if hardware_detail.references then
                    return hardware_reference_lines(Hardware.build(engine.snapshot),
                        hardware_detail.references, translator,
                        terminal_capabilities.unicode ~= false)
                end
                return hardware_detail_lines(engine.snapshot, hardware_detail.id,
                    translator, engine.clock:now_ns(), #hardware_detail.history)
            end, { inventory = true, displays = true, hwmon = true, disk = true,
                network = true, mounts = true, cpu_info = true, cpufreq = true, cpu_clocks = true, numa = true,
                memory_devices = true }, hardware_detail)
            dirty = true
        elseif (key == "up" or key == "down" or key == "pageup"
                or key == "pagedown" or key == "home" or key == "end")
            and hardware_page() and focused_widget_id() == hardware_widget_id() then
            local count = models and models[hardware_widget_id()] and #models[hardware_widget_id()].ids or 0
            local step = (key == "pageup" or key == "pagedown") and math.max(1, rows - 6) or 1
            if key == "home" or key == "end" then step = count end
            if key == "up" or key == "pageup" or key == "home" then step = -step end
            move_hardware_selection(step)
            dirty = true
        elseif (key == "up" or key == "down" or key == "pageup"
                or key == "pagedown" or key == "home" or key == "end")
            and workspace:content_page() == "gpu" then
            local table_model = models and models.gpu_process_table
            local count = table_model and table_model.ids and #table_model.ids or 0
            if count > 0 then
                if gpu_selected_pid == nil then gpu_selected_pid = table_model.ids[1] end
                if key == "home" then
                    move_gpu_selection(-count)
                elseif key == "end" then
                    move_gpu_selection(count)
                else
                    local widget = last_metadata and last_metadata.widgets
                        and last_metadata.widgets.gpu_process_table
                    local visible = widget and widget.visible_rows
                        and widget.visible_rows or math.max(1, rows - 6)
                    local step = (key == "pageup" or key == "pagedown")
                        and math.max(1, visible - 1) or 1
                    if key == "up" or key == "pageup" then step = -step end
                    move_gpu_selection(step)
                end
                dirty = true
            end
        elseif key == "k" and workspace:content_page() == "gpu" then
            -- The device's own clocks, which is a different question from
            -- either drill-down: `Enter` asks who is on this card, `i` asks
            -- what one client is doing, and this asks what the hardware itself
            -- is running.  It stays available when nothing is selected, because
            -- a card's clocks exist whether or not a process is drawing on it.
            gpu_device_selection = { devices = gpu_clock_devices(), index = 1 }
            refresh_gpu_device_overlay()
            dirty = true
        elseif key == "i" and workspace:content_page() == "gpu" then
            -- Drill-down rather than reverse navigation: `Enter` answers "who
            -- is this on the host", `i` answers "what is it doing on the GPU".
            if gpu_selected_pid == nil then
                local table_model = models and models.gpu_process_table
                local ids = table_model and table_model.ids
                if type(ids) == "table" and ids[1] then gpu_selected_pid = ids[1] end
            end
            local gpu_process = gpu_selected_gpu_process()
            if gpu_process then
                -- A builder, not frozen lines: the collector re-reads the DRM
                -- fds on the next tick and the open overlay should pick that up.
                --
                -- Several clients sit behind one pid and the table sums them, so
                -- the list is a real choice rather than a formality.  One
                -- client skips it: there is nothing to choose, and a keypress
                -- to reach the only answer costs the user for no information.
                local clients = type(gpu_process.clients) == "table"
                    and gpu_process.clients or {}
                gpu_client_selection = {
                    process = gpu_process,
                    index = 1,
                    -- `nil` means the detail level, and it is the only level
                    -- for a process that holds a single client.
                    client = #clients == 1 and clients[1] or nil,
                }
                refresh_gpu_client_overlay()
            else
                status_message = translated(translator, "gpu.process_gone",
                    "That process is no longer in the process table")
            end
            dirty = true
        elseif key == "enter" and workspace:content_page() == "gpu" then
            if gpu_selected_pid == nil then
                local table_model = models and models.gpu_process_table
                local ids = table_model and table_model.ids
                if type(ids) == "table" and ids[1] then gpu_selected_pid = ids[1] end
            end
            local process = gpu_selected_process()
            if process then
                -- Builder form: the overlay refreshes as the collector's
                -- detail pass for the selection lands on the next tick, and
                -- `i` from inside it drills into this process' threads.
                open_process_detail(function()
                    return gpu_selected_process() or process
                end)
            else
                status_message = translated(translator, "gpu.process_gone",
                    "That process is no longer in the process table")
            end
            dirty = true
        elseif key == "enter" and workspace:content_page() == "workloads" then
            -- Domain groups already publish process IDs. Threaded groups do
            -- not: resolve a bounded set of their TIDs on demand, after
            -- verifying each task still belongs to this cgroup.
            local workloads = engine.snapshot and engine.snapshot.workloads
            local nodes = workloads and workloads.by_id or {}
            local node = workload_selected_id and nodes[workload_selected_id] or nil
            if node == nil then
                local ids = models and models.workload_table
                    and models.workload_table.ids
                if type(ids) == "table" and ids[1] then
                    workload_selected_id = ids[1]
                    node = nodes[workload_selected_id]
                end
            end
            local threaded = node and node.cgroup_type == "threaded"
            local thread_scan = not engine.replay and threaded and node.threads and type(node.threads.tids) == "table"
                and ThreadMembers.resolve(FS.default, node.id, node.threads.tids) or nil
            local members = threaded and thread_scan and thread_scan.pids
                or node and node.processes and node.processes.pids or nil
            if type(members) == "table" and #members > 0 then
                local semantics = node.semantics
                local label = semantics and semantics.label or node.name or node.id
                if workspace:select("processes") then
                    process_controller:set_pid_filter(members, label)
                    sync_selected_process()
                    status_message = threaded and translated(translator,
                        "workloads.thread_owners_status",
                        "{threads} TIDs → {count} processes · Esc clears", {
                            threads = thread_scan.matched_tids, count = #members,
                        }) or node.processes and (node.processes.hidden_entries or 0) > 0
                        and translated(translator, "workloads.visible_members_status",
                            "{count} visible processes in {name} · Esc clears", {
                                count = #members, name = label,
                            }) or translated(translator, "workloads.members_status",
                        "{count} processes in {name} · Esc clears", {
                            count = #members, name = label,
                        })
                    if threaded and thread_scan.truncated then
                        status_message = status_message .. " · " .. translated(translator,
                            "workloads.thread_scan_capped", "checked {checked}/{total} TIDs", {
                                checked = thread_scan.tids_checked,
                                total = thread_scan.tids_total,
                            })
                    end
                else
                    status_message = translated(translator,
                        "workloads.process_tab_hidden", "Show the Processes tab to inspect members")
                end
            elseif threaded and (not node.threads or
                    (node.threads.status ~= "ok" and node.threads.status ~= "partial")) then
                status_message = translated(translator, "workloads.threads_unavailable",
                    "Thread IDs could not be read for that cgroup")
            elseif threaded and node.threads.count == 0 then
                status_message = translated(translator, "workloads.no_threads",
                    "No thread is listed in that cgroup")
            elseif threaded then
                status_message = translated(translator, "workloads.no_thread_owners",
                    "No current process could be matched to this group's TIDs")
            else
                status_message = translated(translator, "workloads.no_members",
                    "No readable process is listed in that cgroup")
            end
            dirty = true
        elseif (key == "up" or key == "down" or key == "pageup"
                or key == "pagedown" or key == "home" or key == "end")
            and workspace:content_page() == "workloads" then
            local table_model = models and models.workload_table
            local count = table_model and table_model.ids and #table_model.ids or 0
            if count > 0 then
                if key == "home" then
                    move_workload_selection(-count)
                elseif key == "end" then
                    move_workload_selection(count)
                else
                    local widget = last_metadata and last_metadata.widgets
                        and last_metadata.widgets.workload_table
                    local visible = widget and widget.visible_rows
                        and widget.visible_rows or math.max(1, rows - 6)
                    local step = (key == "pageup" or key == "pagedown")
                        and math.max(1, visible - 1) or 1
                    if key == "up" or key == "pageup" then step = -step end
                    move_workload_selection(step)
                end
                dirty = true
            end
        elseif key == "c" and workspace:content_page() == "workloads" then
            if workload_query ~= "" then
                status_message = translated(translator, "workloads.filter_collapse_refused",
                    "Clear the Workloads search before folding the tree")
                dirty = true
            elseif workload_selected_id == nil then
                -- The cursor conceptually starts at the top row; the first
                -- collapse press targets it instead of doing nothing.
                local ids = models and models.workload_table
                    and models.workload_table.ids
                if type(ids) == "table" and ids[1] then
                    workload_selected_id = ids[1]
                end
            end
            if workload_query == "" and workload_selected_id ~= nil then
                if workload_collapsed[workload_selected_id] then
                    workload_collapsed[workload_selected_id] = nil
                else
                    workload_collapsed[workload_selected_id] = true
                end
                dirty = true
            end
        elseif (key == "up" or key == "down" or key == "pageup"
                or key == "pagedown" or key == "home" or key == "end")
            and workspace:content_page() == "network"
            and models and models.connection_table
            and #models.connection_table.rows > 0 then
            local count = #models.connection_table.rows
            if key == "home" then move_connection_selection(-count)
            elseif key == "end" then move_connection_selection(count)
            else
                local widget = last_metadata and last_metadata.widgets
                    and last_metadata.widgets.connection_table
                local visible = widget and widget.visible_rows
                    and widget.visible_rows or math.max(1, rows - 6)
                local step = (key == "pageup" or key == "pagedown")
                    and math.max(1, visible - 1) or 1
                if key == "up" or key == "pageup" then step = -step end
                move_connection_selection(step)
            end
            dirty = true
        elseif (key == "up" or key == "down" or key == "pageup" or key == "pagedown")
            and workspace:content_page() ~= "processes"
            and scroll_focused_widget(
                (key == "up" or key == "pageup") and -1 or 1,
                key == "pageup" or key == "pagedown") then
            -- handled by the focused panel
        elseif (key == "up" or key == "down" or key == "pageup" or key == "pagedown"
            or key == "home" or key == "end") and workspace:content_page() == "processes" then
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
        elseif key == "/" and workspace:content_page() == "processes" then
            local query = process_controller:status().query
            search_edit = {
                original = query,
                original_selected_id = process_controller:selected_id(),
                draft = query,
                cursor = #query + 1,
            }
            dirty = true
        elseif key == "/" and workspace:content_page() == "network" then
            search_edit = {
                kind = "network", original = network_query,
                draft = network_query, cursor = #network_query + 1,
            }
            dirty = true
        elseif key == "/" and workspace:content_page() == "storage" then
            search_edit = {
                kind = "mounts", original = mount_query,
                draft = mount_query, cursor = #mount_query + 1,
            }
            dirty = true
        elseif key == "/" and workspace:content_page() == "workloads" then
            search_edit = {
                kind = "workloads", original = workload_query,
                original_selected_id = workload_selected_id,
                draft = workload_query, cursor = #workload_query + 1,
            }
            dirty = true
        elseif key == "/" and workspace:content_page() == "system" then
            -- A hardware search must reveal its table even when a narrow
            -- layout gave the initial space to the host summary panels.
            for _, widget_id in ipairs(workspace:orders()[workspace.active] or {}) do
                if widget_id == "system_devices" then
                    workspace.focus[workspace.active] = widget_id
                    sync_engine_visibility()
                    break
                end
            end
            search_edit = {
                kind = "hardware", original = hardware_query,
                original_selected_id = hardware_selected_id,
                draft = hardware_query, cursor = #hardware_query + 1,
            }
            dirty = true
        elseif key == "escape" and workspace:content_page() == "processes"
            and (process_controller:status().query ~= ""
                or process_controller:status().cgroup_filter ~= nil)
        then
            -- The cgroup filter is cleared only once the query is, so one Esc
            -- undoes one narrowing rather than both at once.
            if process_controller:status().query ~= "" then
                process_controller:set_query("")
            else
                process_controller:clear_pid_filter()
            end
            sync_selected_process()
            dirty = true
        elseif key == "escape" and workspace:content_page() == "network"
            and (network_query ~= "" or network_owner_target) then
            if network_query ~= "" then network_query = ""
            else network_owner_target = nil end
            dirty = true
        elseif key == "escape" and workspace:content_page() == "storage"
            and mount_query ~= "" then
            mount_query = ""
            dirty = true
        elseif key == "escape" and workspace:content_page() == "workloads"
            and workload_query ~= "" then
            workload_query = ""
            workload_selected_id = nil
            dirty = true
        elseif key == "escape" and workspace:content_page() == "system"
            and hardware_query ~= "" then
            hardware_query = ""
            hardware_selected_id = nil
            dirty = true
        elseif key == "o" and workspace:content_page() == "processes" then
            process_controller:cycle_sort()
            sync_selected_process()
            dirty = true
        elseif key == "O" and workspace:content_page() == "processes" then
            process_controller:toggle_direction()
            sync_selected_process()
            dirty = true
        elseif key == "t" and workspace:content_page() == "processes" then
            process_controller:toggle_tree()
            sync_selected_process()
            dirty = true
        elseif key == "c" and workspace:content_page() == "processes" then
            local changed, state = process_controller:toggle_collapse()
            if changed then
                status_message = nil
                sync_selected_process()
            else
                status_message = translated(translator,
                    state == "tree_disabled" and "process.tree_navigation_disabled"
                        or state == "filter_active" and "process.collapse_filter_active"
                        or "process.collapse_no_children",
                    state == "tree_disabled" and "Press t to enable the process tree"
                        or state == "filter_active" and "Clear the filter to fold the tree"
                        or "The selected process has no visible children")
            end
            dirty = true
        elseif (key == "[" or key == "]") and workspace:content_page() == "processes" then
            local process = selected_process()
            if not process then
                status_message = translated(translator, "process.no_selection", "No process selected")
            else
                local moved
                if key == "[" then
                    moved = process_controller:select_parent()
                else
                    moved = process_controller:select_first_child()
                end
                if moved then
                    status_message = nil
                    sync_selected_process()
                elseif not process_controller:status().tree then
                    status_message = translated(translator, "process.tree_navigation_disabled",
                        "Press t to enable the process tree")
                else
                    status_message = translated(translator,
                        key == "[" and "process.no_visible_parent"
                            or "process.no_visible_child",
                        key == "[" and "No visible parent for PID {pid}"
                            or "No visible child for PID {pid}",
                        { pid = process.pid })
                end
            end
            dirty = true
        elseif key == "p" and workspace:content_page() == "processes" then
            process_controller:toggle_paths()
            dirty = true
        elseif key == "C" and workspace:content_page() == "processes" then
            open_column_overlay()
            dirty = true
        elseif key == "v" then
            show_virtual = not show_virtual
            status_message = show_virtual
                and translated(translator, "status.virtual_shown",
                    "Showing virtual devices and pseudo filesystems")
                or translated(translator, "status.virtual_hidden",
                    "Hiding virtual devices and pseudo filesystems")
            dirty = true
        elseif key == "m" and workspace:content_page() == "network" then
            mask_remote = not mask_remote
            -- A query typed while full addresses were visible may itself
            -- contain one. Do not leave it in the table footer after masking.
            if mask_remote then network_query = "" end
            status_message = translated(translator,
                mask_remote and "status.mask_on" or "status.mask_off",
                mask_remote and "Remote addresses are masked"
                or "Remote addresses are shown in full")
            dirty = true
        elseif key == "w" and workspace:content_page() == "network" and linux_host then
            show_overlay(function()
                return wifi_link_lines(engine.snapshot, translator)
            end, { wifi = true })
            dirty = true
        elseif key == "g" and workspace:content_page() == "network" and linux_host then
            show_overlay(function()
                return route_detail_lines(engine.snapshot, translator)
            end, { network = true, route_detail = true })
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
        elseif key == "B" then
            if terminal_capabilities.unicode == false then
                status_message = translated(translator, "status.chart_unavailable",
                    "Braille charts need a Unicode terminal")
            else
                chart_mode = chart_mode == "block" and "braille" or "block"
                status_message = chart_mode == "braille"
                    and translated(translator, "status.chart_braille", "Chart: Braille")
                    or translated(translator, "status.chart_block", "Chart: blocks")
            end
            renderer:invalidate()
            force = true
            dirty = true
        elseif key == "z" or key == "Z" then
            chart_interval_index = math.max(1, math.min(#chart_intervals_ns,
                chart_interval_index + (key == "z" and 1 or -1)))
            local seconds = chart_intervals_ns[chart_interval_index] / 1000000000
            local label = seconds < 1 and string.format("%.1f", seconds)
                or string.format("%d", seconds)
            status_message = translated(translator, "status.chart_zoom",
                "Chart time: {seconds} s/cell", { seconds = label })
            renderer:invalidate()
            force = true
            dirty = true
        elseif key == "space" then
            paused = not paused
            engine:set_paused(paused)
            if engine.replay then paused = engine.paused end
            dirty = true
        elseif key == "f" then
            cycle_frequency(1)
        elseif key == "e" then
            workspace:toggle_edit()
            dirty = true
        elseif key == "?" or key == "f1" then
            show_overlay(help_lines(translator, columns, linux_host and not engine.replay, engine.replay))
            dirty = true
        elseif key == "!" then
            show_overlay(function()
                return health_lines(engine.snapshot, translator)
            end, { disk = true, disk_health = true, hwmon = true, inventory = true,
                gpu = true, pressure = true, mounts = true })
            dirty = true
        elseif key == "p" and (workspace:content_page() == "overview"
            or workspace:content_page() == "compute" or workspace:content_page() == "gpu"
            or workspace:content_page() == "system") then
            show_overlay(function()
                return power_detail_lines(engine.snapshot, translator)
            end, { powercap = true, cpu_limits = true, gpu = true, hwmon = true, power_supply = true })
            dirty = true
        elseif key == "h" then
            show_overlay(function()
                return sensor_detail_lines(engine.snapshot, translator, engine.clock:now_ns())
            end, { hwmon = true })
            dirty = true
        elseif key == "r" or (event.ctrl and key == "l") then
            sync_engine_visibility()
            engine:tick_visible()
            renderer:invalidate()
            force = true
            dirty = true
        elseif key == "k" and workspace:content_page() == "processes" then
            local process = selected_process()
            if engine.replay then
                status_message = translated(translator, "replay.no_live_reads",
                    "Live inspection and process actions are unavailable during replay")
            elseif #action_choices == 0 then
                status_message = translated(translator, "process.actions_unavailable",
                    "Process actions are unavailable on this platform")
            elseif process then
                confirmation = { process = process, index = 1 }
                refresh_signal_menu()
                overlay_offset = 0
            else
                status_message = translated(translator, "process.no_selection", "No process selected")
            end
            dirty = true
        elseif key == "enter" and workspace:content_page() == "processes" then
            local process = selected_process()
            if process then
                -- Builder form: the overlay refreshes as the collector's
                -- detail pass for the selection lands on the next tick.
                open_process_detail(function()
                    return selected_process() or process
                end)
            else
                status_message = translated(translator, "process.no_selection", "No process selected")
            end
            dirty = true
        elseif key == "enter" and workspace:content_page() == "network" then
            local row = selected_connection_row()
            local connection = row and row.connection_ref
            local owners = connection and connection.owners or {}
            if not linux_host then
                status_message = translated(translator, "network.owner_linux_only",
                    "Socket owner drill-down is available on Linux")
            elseif #owners == 0 then
                status_message = translated(translator, "network.no_owner",
                    "No mapped process for the selected socket")
            elseif #owners == 1 then
                open_connection_owner(connection, owners[1])
            else
                connection_owner_selection = {
                    connection = connection, owners = owners, index = 1,
                    local_endpoint = row.local_endpoint,
                    remote_endpoint = row.remote_endpoint,
                }
                show_overlay(connection_owner_lines(connection_owner_selection, translator,
                    terminal_capabilities.unicode ~= false), { process = true },
                    connection_owner_selection)
            end
            dirty = true
        elseif key == "g" and workspace:content_page() == "processes" then
            jump_to_workload(selected_process())
            dirty = true
        elseif key == "n" and workspace:content_page() == "processes" then
            jump_to_network(selected_process())
            dirty = true
        elseif key == "s" and (linux_host or engine._storage_inspector) then
            inspect_smart()
            dirty = true
        elseif key == "b" and linux_host then
            inspect_bandwidth()
            dirty = true
        elseif key == "d" and linux_host then
            inspect_systemd()
            dirty = true
        elseif key == "D" and linux_host then
            inspect_sshd()
            dirty = true
        elseif key == "u" and linux_host then
            inspect_sessions()
            dirty = true
        end
    end

    run_command = function(command)
        local keys = {
            tabs = "1", pause = "space", rate = "f", layout = "e", theme = "T",
            chart = "B",
            chart_zoom = "z",
            help = "?", quit = "q", search = "/", sort = "o", reverse = "O",
            language = "L",
            tree = "t", collapse = "c", paths = "p", details = "enter", signal = "k",
            connection_select = "down", connection_owner = "enter",
            routes = "g",
            wifi = "w",
            workload = "g",
            sockets = "n",
            virtual = "v", mask = "m", smart = "s", bandwidth = "b", sshd = "D", systemd = "d", sessions = "u",
            sensors = "h", power = "p",
        }
        local key = keys[command]
        if not key then return false end
        process_event({ type = "key", key = key, ctrl = false, alt = false, shift = false })
        return true
    end

    while running do
        if engine._bandwidth_live and overlay_builder ~= engine._bandwidth_live.builder then
            engine._bandwidth_live:close()
            engine._bandwidth_live = nil
        end
        if engine._bandwidth_live then engine._bandwidth_live:set_paused(paused, engine.clock:now_ns()) end
        if storage_overlay_builder and overlay_builder ~= storage_overlay_builder then
            engine._storage_inspector:close()
            storage_overlay_builder = nil
        end
        local timeout_ms = math.min(engine:next_delay_ms(100), 100)
        local polled, poll_error = backend.poll(timeout_ms)
        if not polled then
            error(poll_error or "terminal poll failed")
        end
        local input_activity = polled.resize == true
        if polled.events then
            for _, event in ipairs(polled.events) do
                input_activity = true
                process_event(event)
            end
        end
        if polled.data then
            for _, event in ipairs(decoder:feed(polled.data, false)) do
                input_activity = true
                process_event(event)
            end
        elseif decoder:pending() > 0 then
            for _, event in ipairs(decoder:flush()) do
                input_activity = true
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
        if dirty and running and input_activity then
            -- Paint requested interaction from the current snapshot before
            -- synchronous collectors run. Opening, closing and scrolling an
            -- overlay need the same immediate response as a page switch.
            -- Newly completed readings can update it after this first frame.
            models = render_frame()
            last_presented_ns = native.monotonic_ns()
        end
        local _, completed = engine:tick(false)
        if engine.replay then paused = engine.paused end
        if engine._bandwidth_live and running
            and engine._bandwidth_live:poll(engine.context, engine.clock:now_ns()) then dirty = true end
        if next(completed) then
            dirty = true
        end
        if dirty and running then
            -- Several collectors can finish between display updates. Merge
            -- their changes into one frame at the selected update interval;
            -- keyboard, mouse, resize, and forced repaints stay immediate.
            local now = native.monotonic_ns()
            local interval_ns = (engine.interval_ms or options.interval_ms or 1000)
                * 1000000
            if input_activity or force or engine.replay or now - last_presented_ns >= interval_ns then
                models = render_frame()
                last_presented_ns = native.monotonic_ns()
            end
        end
    end
    if workspace.dirty and not Privilege.restricts_user_files(options.privilege) then
        -- The workspace set is written alongside the live trees: saving must
        -- not quietly drop the arrangements the user put aside earlier.  The
        -- column set rides along for the same reason -- it is part of what the
        -- table looks like, not a setting that resets when the process view
        -- does.
        local custom_pages = workspace:custom_page_definitions()
        local saved, save_error = LayoutStore.save(
            workspace:orders(), layout_status and layout_status.path, workspace:trees(),
            workspace:saved_workspaces(), workspace.workspace, layout_columns,
            workspace:custom_tab_order(), Workspace.default_orders(custom_pages),
            custom_pages)
        if not saved then
            error("cannot save layout: " .. tostring(save_error))
        end
    end
    return 0
end

-- Without LANG, --lang, or a configured locale, a Windows console follows the
-- user's display language, provided the console's code page can show it.
-- Otherwise the interface stays in English rather than printing "?" marks.
local LOCALE_PROBES = {
    zh = 0x4E2D, ja = 0x3042, ko = 0xD55C, ru = 0x0414,
    de = 0x00FC, fr = 0x00E9, es = 0x00F1, pt = 0x00E3,
}

local function windows_default_locale(getenv)
    for _, name in ipairs({ "LC_ALL", "LC_MESSAGES", "LANG" }) do
        local value = getenv(name)
        if value and value ~= "" then return nil end
    end
    if type(native.user_locale) ~= "function" or type(native.console_cells) ~= "function" then
        return nil
    end
    local ok, tag = pcall(native.user_locale)
    local normalized = ok and type(tag) == "string" and I18n.normalize_locale(tag) or nil
    if not normalized then return nil end
    local language, region = normalized:match("^(%a+)%-?(%a*)")
    local available = {}
    for _, id in ipairs(I18n.available() or {}) do available[id] = true end
    local candidate = available[normalized] and normalized or nil
    if not candidate and language == "zh" then
        candidate = (region == "TW" or region == "HK" or region == "MO") and "zh-TW" or "zh-CN"
    end
    if not candidate then
        local ids = {}
        for id in pairs(available) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            if id:match("^(%a+)") == language then candidate = id break end
        end
    end
    local probe = LOCALE_PROBES[language]
    if not candidate or not available[candidate] or not probe then return nil end
    local shown, cells = pcall(native.console_cells, probe)
    if shown and type(cells) == "number" and cells > 0 then return candidate end
    return nil
end

M.windows_default_locale = windows_default_locale

function M.run(options)
    options = options or {}
    local uname = native.uname()
    if not uname or (uname.sysname ~= "Linux" and uname.sysname ~= "Darwin"
        and uname.sysname ~= "Windows") then
        io.stderr:write("wtop: unsupported operating system\n")
        return 1
    end
    if not native.available then
        io.stderr:write("wtop: native module unavailable; run 'make native'\n")
        return 1
    end
    options.platform = uname.sysname
    if not native.isatty(0) or not native.isatty(1) then
        io.stderr:write("wtop: interactive mode requires a TTY; use --snapshot or --agent for JSON output\n")
        return 1
    end

    local locale = options.locale
    if locale == nil and uname.sysname == "Windows" then
        locale = windows_default_locale(os.getenv)
    end
    local translator, translation_error = I18n.new({ locale = locale })
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
    local engine
    if options.replay_path then
        engine = require("wtop.replay").new(options.replay_path, { frame=options.replay_frame })
        options.platform = engine.platform
    else
        engine = Engine.new({ interval_ms=initial_frequency.interval_ms, safe_mode=options.safe_mode })
    end
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
    if engine._storage_inspector then engine._storage_inspector:close() end
    if engine._bandwidth_live then engine._bandwidth_live:close() end
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
M.alert_count = alert_count
M.nvme_warning_lines = nvme_warning_lines
M.health_lines = health_lines
M.wifi_link_lines = wifi_link_lines
M.process_sampling_plan = process_sampling_plan
M.thread_detail_request = thread_detail_request
M.inspector_lines = inspector_lines
M.sensor_detail_lines = sensor_detail_lines
M.power_detail_lines = power_detail_lines
M.hardware_detail_lines = hardware_detail_lines
M.route_detail_lines = route_detail_lines
M.process_detail_lines = process_detail_lines
M.process_fd_lines = process_fd_lines
M.process_fd_detail_lines = process_fd_detail_lines
M.process_column_lines = process_column_lines
M.signal_menu_lines = signal_menu_lines
M.tab_manager_lines = tab_manager_lines
M.thread_picker_lines = thread_picker_lines
M.thread_detail_lines = thread_detail_lines
M.compare_thread_cgroup = compare_thread_cgroup
M.gpu_client_lines = gpu_client_lines
M.gpu_client_detail_lines = gpu_client_detail_lines
M.gpu_device_clock_lines = gpu_device_clock_lines
M.gpu_device_clock_detail_lines = gpu_device_clock_detail_lines
M.workspace_lines = workspace_lines
M.move_target_lines = move_target_lines
M.widget_picker_lines = widget_picker_lines
M.entity_picker_lines = entity_picker_lines
M.systemd_unit_lines = systemd_unit_lines
M.journal_lines = journal_lines
M.session_lines = session_lines
M.event_stats_lines = event_stats_lines
M.utf8_backspace = utf8_backspace

return M

