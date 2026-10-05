local Actions = require("wtop.actions")
local CgroupSemantics = require("wtop.collectors.cgroup_semantics")
local Engine = require("wtop.engine")
local I18n = require("wtop.i18n")
local Technical = require("wtop.i18n.technical")
local UserCatalogs = require("wtop.i18n.user_catalogs")
local Inspectors = require("wtop.inspectors")
local PerfBandwidth = require("wtop.inspectors.perf_bandwidth")
local LayoutStore = require("wtop.layout_store")
local Privilege = require("wtop.privilege")
local ProcessTable = require("wtop.model.process_table")
local ProcessColumns = require("wtop.model.process_columns")
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

local NUMBER_UNIT_SUFFIX = {
    watts = " W", volts = " V", amperes = " A", joules = " J",
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

local INSPECTOR_LIST_LIMIT = 128
local INSPECTOR_ROW_WIDTH = 160
local INSPECTOR_FIELD_WIDTH = 80
local INSPECTOR_ROW_FIELDS = {
    items = { "id", "name", "normalized", "worst", "threshold", "raw", "when_failed" },
    processes = { "pid", "parent_pid", "state", "cpu_percent", "resident_bytes", "command" },
    listeners = { "address", "port", "family", "pid", "state" },
    active_sessions = { "user", "tty", "remote", "login_time", "idle_seconds", "pid" },
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
            lines[#lines + 1] = "    " .. tostring(key) .. ": " .. inspector_text(
                inspector_item_value(value[key], i18n, key), INSPECTOR_ROW_WIDTH)
        end
    end
    if count > INSPECTOR_LIST_LIMIT then
        lines[#lines + 1] = "    ... +" .. (count - INSPECTOR_LIST_LIMIT)
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
        lines[#lines + 1] = tostring(section.id or section.title_key
            or translated(i18n, "inspector.details", "Details"))
        local keys = {}
        for key in pairs(section.fields or {}) do keys[#keys + 1] = key end
        table.sort(keys)
        local rows = {}
        for _, key in ipairs(keys) do
            local field = section.fields[key]
            rows[#rows + 1] = { key, format_value(field and field.value, i18n,
                field and field.unit)
                .. "  [" .. tostring(field and field.quality or "unknown") .. "]" }
        end
        local field_lines = aligned_pairs(rows)
        for index, key in ipairs(keys) do
            lines[#lines + 1] = field_lines[index]
            local field = section.fields[key]
            local expanded = INSPECTOR_EXPAND_FIELDS[section.id]
            if field and type(field.value) == "table" and expanded and expanded[key] then
                for _, line in ipairs(inspector_collection_lines(field.value, key, i18n)) do
                    lines[#lines + 1] = line
                end
            end
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
    return lines
end

local SENSOR_DETAIL_LIMIT = 256
local SENSOR_STALE_AFTER_NS = 15 * 1000000000

local function sensor_detail_lines(snapshot, i18n, now_ns)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local data = type(snapshot.sensors) == "table" and snapshot.sensors or {}
    local devices = type(data.devices) == "table" and data.devices or {}
    local quality = type(snapshot.quality) == "table" and snapshot.quality.sensors
    local state = type(quality) == "table" and quality or {}
    local age_ns = type(now_ns) == "number" and type(state.timestamp_ns) == "number"
        and math.max(0, now_ns - state.timestamp_ns) or nil
    local stale_sample = age_ns and age_ns > SENSOR_STALE_AFTER_NS
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
    if stale_sample and #devices > 0 then
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
    local total = 0
    for _, device in ipairs(devices) do total = total + #(device.channels or {}) end
    lines[#lines + 1] = translated(i18n, "metrics.sensor", "Sensor") .. ": " .. total
    if total == 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "ui.no_data", "No data")
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "inspector.close_hint", "Esc/Enter closes")
        return lines
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
    for _, device in ipairs(devices) do
        if shown >= SENSOR_DETAIL_LIMIT then break end
        if #(device.channels or {}) > 0 then
            local device_quality = device.quality or "unavailable"
            if stale_sample and (device_quality == "fresh" or device_quality == "estimated") then
                device_quality = "stale"
            end
            lines[#lines + 1] = ""
            lines[#lines + 1] = inspector_text(
                inspector_text(device.name or device.class or "?", 80) .. "  ["
                    .. Technical.state(i18n, device_quality) .. "]  "
                    .. inspector_text(device.source or "", 64), INSPECTOR_ROW_WIDTH)
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
          bytes(process.virtual_bytes), memory_anchor = true },
        { translated(i18n, "process.details_threads", "Threads"), process.threads },
        { blank = true },
        { section = translated(i18n, "process.details_scheduling", "Scheduling") },
        { translated(i18n, "process.details_priority", "Priority"), process.priority },
        { "Nice", process.nice },
        { translated(i18n, "metrics.cpu", "Last CPU"), process.processor },
        { translated(i18n, "process.details_process_group", "Process group"), process.process_group },
        { translated(i18n, "process.details_session", "Session"), process.session },
    }
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
        { translated(i18n, "metrics.write", "Write"), bytes(io.write_bytes) },
        { translated(i18n, "process.details_cancelled_write", "Cancelled write"),
          bytes(io.cancelled_write_bytes) },
        { translated(i18n, "process.details_voluntary_switches", "Voluntary switches"),
          switches.voluntary },
        { translated(i18n, "process.details_involuntary_switches", "Involuntary switches"),
          switches.involuntary },
    }) do
        rows[#rows + 1] = row
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
    -- The id chain reads innermost first, so a container's init shows its own
    -- pid of 1 and the host pid behind it.  A single value is the ordinary case
    -- and is not worth a section.
    local namespaces = type(process.namespaces) == "table" and process.namespaces or nil
    if namespaces and namespaces.namespaced and type(namespaces.nspid) == "table" then
        local chain = {}
        for _, value in ipairs(namespaces.nspid) do chain[#chain + 1] = tostring(value) end
        lines[#lines + 1] = ""
        lines[#lines + 1] = translated(i18n, "process.details_namespaces", "PID namespaces")
        lines[#lines + 1] = "  " .. translated(i18n, "process.details_namespace_chain",
            "Inside → host") .. "  " .. table.concat(chain, " → ")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "process.details_actions",
        "i thread · k signal · Up/Down/PgUp/PgDn scroll · Esc/Enter closes")
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
  elseif type(thread.cpu_ticks) == "number" then
    cpu_seconds = thread.cpu_ticks / 100
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
    { blank = true },
    { section = translated(i18n, "process.details_scheduling", "Scheduling") },
    { translated(i18n, "process.details_priority", "Priority"), thread.priority },
    { "Nice", thread.nice },
    { translated(i18n, "process.details_voluntary_switches", "Voluntary switches"),
      detail and detail.voluntary_switches },
    { translated(i18n, "process.details_involuntary_switches", "Involuntary switches"),
      detail and detail.involuntary_switches },
  }

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
        "Inside → host") .. "  " .. table.concat(chain, " → ")
  end

  if type(detail) == "table" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = translated(i18n, "metrics.source", "Source") .. "  "
      .. tostring(detail.source or "—")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = translated(i18n, "process.thread_actions",
      "Esc returns to the thread list")
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
            { "Esc", "help.process_clear_filter",
                "clear the search, then a cgroup filter reached from Workloads" },
            { "o", "help.process_sort", "cycle the sort column" },
            { "O", "help.process_direction", "reverse the sort direction" },
            { "t", "help.process_tree", "toggle the parent/child tree" },
            { "p", "help.process_paths", "toggle full executable paths" },
            { "C", "help.process_columns", "choose which columns the table shows" },
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
            { "ns:1", "help.query_ns", "search the id inside a PID namespace" },
            { "cpu>20", "help.query_compare", "compare a number, combined with the terms" },
            { "mem>512M", "help.query_units", "byte sizes take K/M/G/T; time is in seconds" },
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
            { "T", "help.cycle_theme", "cycle the colour theme" },
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
            { "s", "help.inspect_smart", "choose a SMART/NVMe device", "linux" },
            { "b", "help.inspect_bandwidth", "measure RAM bandwidth with perf", "linux" },
            { "d", "help.inspect_sshd", "inspect the sshd service and listeners", "linux" },
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

local function help_lines(i18n, width, linux_host)
    local title = i18n:t("app.title")
    local lines = {
        title ~= "app.title" and title or "wtop — system monitor",
    }
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

-- Signals the action layer accepts.  The UI used to hard-wire SIGTERM even
-- though SIGKILL, SIGSTOP and SIGCONT were already implemented with the same
-- PID-reuse protection, so three safe actions were unreachable.
local SIGNAL_CHOICES = {
    { number = 15, name = "SIGTERM", id = "signal.term", fallback = "ask the process to exit" },
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
    local host = native.uname()
    if not host or host.sysname ~= "Linux" then
        return Inspectors.Registry.new()
    end
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
    local host = native.uname()
    local linux_host = host ~= nil and host.sysname == "Linux"
    local console_cells = terminal_capabilities.native_presentation
        and console_cells_function() or nil
    local action_choices = host and host.sysname == "Windows"
        and WINDOWS_ACTION_CHOICES or (host and host.sysname == "Darwin"
            and {} or SIGNAL_CHOICES)
    local default_orders = Workspace.default_orders()
    local layout_orders, layout_status, layout_trees
    local layout_workspaces, layout_workspace, layout_columns
    if Privilege.restricts_user_files(options.privilege) then
        layout_orders = default_orders
        layout_status = { state = "default", reason = "sudo session ignores persisted layout" }
    else
        layout_orders, layout_status, layout_trees, layout_workspaces, layout_workspace,
            layout_columns = LayoutStore.load(default_orders)
    end
    local workspace = Workspace.new({
        active_tab = options.active_tab,
        orders = layout_orders,
        layout_trees = layout_trees,
        workspaces = layout_workspaces,
        workspace = layout_workspace,
        i18n = translator,
    })
    local columns, rows = assert(backend.size())
    local visible_widgets = {}
    local overlay_collectors
    local workspace_selection
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
        assert(engine:set_active_tab(workspace.active, visible_widgets,
            overlay_collectors))
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
    local thread_selection
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
    local mask_remote = options.mask_remote_addresses == true
    local workload_collapsed = {}
    local workload_selected_id = nil
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
        if owner ~= thread_selection then thread_selection = nil end
        if owner ~= gpu_client_selection then gpu_client_selection = nil end
        if owner ~= gpu_device_selection then gpu_device_selection = nil end
        if owner ~= entity_selection then entity_selection = nil end
        if owner ~= column_selection then column_selection = nil end
        if owner ~= workspace_selection then workspace_selection = nil end
        overlay_collectors = collectors
        overlay_builder = type(lines_or_builder) == "function" and lines_or_builder or nil
        if overlay_builder then
            overlay = overlay_builder()
        else
            overlay = lines_or_builder
        end
        overlay_offset = 0
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
        column_selection.entries = ProcessColumns.entries(process_controller:columns())
        overlay = process_column_lines(column_selection, translator,
            terminal_capabilities.unicode ~= false)
        local body_rows = math.max(1, rows - 7)
        overlay_offset = math.max(0, 5 + column_selection.index - body_rows - 1)
    end

    local function open_column_overlay()
        column_selection = {
            index = 1,
            entries = ProcessColumns.entries(process_controller:columns()),
        }
        refresh_column_overlay()
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
        overlay = entity_picker_lines(entity_selection.title, entity_selection.entities,
            entity_selection.index, translator, entity_selection.truncated,
            terminal_capabilities.unicode ~= false)
        local body_rows = math.max(1, rows - 5)
        local selected_line = 4 + entity_selection.index
        overlay_offset = math.max(0, selected_line - body_rows - 1)
    end

    local function open_process_detail(resolve)
        process_detail = { resolve = resolve }
        show_overlay(function()
            return process_detail_lines(process_with_io_detail(resolve()), translator)
        end)
    end

    -- The thread cursor is held by TID, not by position.  The list is ordered
    -- by CPU share, so a row's position changes every time a thread speeds up
    -- or idles; a cursor stored as an index would silently start inspecting a
    -- different thread while the operator still believes it is looking at the
    -- one they picked.
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
        local index = 1
        for position, thread in ipairs(threads) do
            if thread.tid == thread_selection.tid then
                index = position
                break
            end
        end
        thread_selection.index = math.min(index, math.max(1, #threads))
        local selected = threads[thread_selection.index]
        if selected and type(process) == "table" and process.pid then
            -- This is what makes the collector read the thread's own files: one
            -- TID, one process, three small files, on the tick after the pick.
            engine.context.selected_thread_ids = { [process.pid] = selected.tid }
        else
            engine.context.selected_thread_ids = {}
        end
    end

    local function refresh_thread_picker()
        if not thread_selection or thread_selection.mode ~= "picker" then return end
        sync_thread_selection()
        local process = thread_process()
        -- The picker is frozen lines, not a builder, so the process overlay's
        -- builder has to go: left in place it would overwrite these lines on
        -- the very next frame and the picker would flash and vanish.
        overlay_builder = nil
        overlay_collectors = nil
        overlay = thread_picker_lines(process, thread_selection, translator,
            terminal_capabilities.unicode ~= false)
        local body_rows = math.max(1, rows - 5)
        overlay_offset = math.max(0, 4 + thread_selection.index - body_rows - 1)
    end

    local function open_thread_detail()
        if not thread_selection then return end
        thread_selection.mode = "detail"
        -- A builder, not frozen lines: the per-thread read arrives on the next
        -- sample and the open overlay has to pick it up.  The selection names
        -- itself as this overlay's owner so opening it is not mistaken for
        -- replacing some other overlay.
        show_overlay(function()
            local live = thread_process()
            local threads = thread_rows_by_cpu(type(live) == "table"
                and live.thread_rows or nil)
            local thread = nil
            for _, candidate in ipairs(threads) do
                if candidate.tid == thread_selection.tid then
                    thread = candidate
                    break
                end
            end
            local detail = type(live) == "table" and type(live.thread_details) == "table"
                and live.thread_details[thread_selection.tid] or nil
            return thread_detail_lines(thread, detail, live, translator)
        end, nil, thread_selection)
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
            tid = threads[1].tid,
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

    local function open_inspector(inspector_id, title, empty_key, empty_fallback)
        local context = inspector_context(engine)
        local entities, enumerate_error = inspector_registry:enumerate(inspector_id, context)
        if not entities or #entities == 0 then
            show_overlay({
                translated(translator, title.key, title.fallback), "",
                translated(translator, empty_key, empty_fallback),
                tostring(enumerate_error or ""), "",
                translated(translator, "inspector.close_hint", "Esc/Enter closes"),
            })
            return
        end
        if #entities == 1 then
            inspect_entity(entities[1])
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
        }
        refresh_entity_picker()
    end

    inspect_entity = function(entity)
        local selection = entity_selection
        entity_selection = nil
        if type(entity) ~= "table" then return end
        local result = inspector_registry:inspect(
            selection and selection.inspector or "storage.smart",
            inspector_context(engine), entity, "summary")
        local label = translated(translator,
            selection and selection.title.key or "inspector.smart",
            selection and selection.title.fallback or "SMART / NVMe")
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
                platform = options.platform,
                show_virtual_devices = show_virtual,
                show_pseudo_filesystems = show_virtual,
                mask_remote_addresses = mask_remote,
                workload_collapsed = workload_collapsed,
                workload_selected = workload_selected_id,
                gpu_selected = gpu_selected_pid,
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
        -- Publish the rows the table is about to draw.  The collector reads
        -- /proc/<pid>/schedstat for exactly these, which is what makes a
        -- run-queue column affordable: the viewport is bounded by the terminal
        -- height, so the cost is bounded by what a person can see rather than by
        -- how many processes the machine has.  It is computed after the offset
        -- has settled, because which rows are visible depends on it.
        if workspace.active == "processes" then
            local viewport = {}
            -- The controller's rows are what the table's rows were formatted
            -- from, in the same order and the same count, so the index window
            -- the table drew is the window to measure.  Reading the ids from the
            -- controller rather than from the rendered rows matters: a rendered
            -- row is a formatted cell, not the process identity the collector
            -- keys on.
            local source_rows = process_controller:rows()
            local last = math.min(#source_rows, process_offset + visible_rows)
            for index = process_offset + 1, last do
                local row = source_rows[index]
                if row and row.id then viewport[row.id] = true end
            end
            -- The selected process is always measured even when it has scrolled
            -- out of view, so its detail overlay can answer for it.
            local selected_id = process_controller:selected_id()
            if selected_id then viewport[selected_id] = true end
            engine.context.visible_process_ids = viewport
        else
            engine.context.visible_process_ids = nil
        end
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
        local status = {
            message = status_message or recovered_note,
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
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
            }
            if #action_choices > 0 then
                table.insert(status.hints, #status.hints,
                    { key = "k", id = action_choices == WINDOWS_ACTION_CHOICES
                        and "actions.terminate" or "actions.signal",
                        fallback = action_choices == WINDOWS_ACTION_CHOICES
                            and "Terminate" or "Signal", command = "signal" })
            end
        elseif workspace.active == "compute" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "Space", id = paused and "actions.resume" or "actions.pause",
                  fallback = paused and "Resume" or "Pause", command = "pause" },
                { key = "h", id = "widgets.sensors", fallback = "Sensors", command = "sensors" },
                { key = "f", id = "actions.update_frequency", fallback = "Rate", command = "rate" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            }
        elseif workspace.active == "storage" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "v", id = "actions.toggle_virtual", fallback = "Virtual", command = "virtual" },
                { key = "s", id = "actions.inspect_smart", fallback = "SMART", command = "smart" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            }
        elseif workspace.active == "network" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "v", id = "actions.toggle_virtual", fallback = "Virtual", command = "virtual" },
                { key = "m", id = "actions.toggle_masking", fallback = "Mask", command = "mask" },
                { key = "s", id = "actions.inspect_smart", fallback = "SMART", command = "smart" },
                { key = "?", id = "actions.help", fallback = "Help", command = "help" },
                { key = "q", id = "actions.quit", fallback = "Quit", command = "quit" },
            }
        elseif workspace.active == "gpu" then
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
        elseif workspace.active == "workloads" then
            status.hints = {
                { key = "1–0", id = "actions.tabs", fallback = "Tabs", command = "tabs" },
                { key = "↑↓", id = "actions.workload_select", fallback = "Select",
                  command = "workload_select" },
                { key = "c", id = "actions.toggle_collapse", fallback = "Collapse",
                  command = "collapse" },
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
        if not linux_host then
            -- The SMART, bandwidth, and sshd inspectors are Linux-only.
            local kept = {}
            for _, hint in ipairs(status.hints or {}) do
                if hint.command ~= "smart" and hint.command ~= "bandwidth"
                    and hint.command ~= "sshd" then
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
            ascii_unit_width = native.available,
            console_cells = console_cells,
        })
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

    models = render_frame()
    local last_presented_ns = native.monotonic_ns()

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
        if widget_picker then
            local function close()
                widget_picker = nil
                overlay = nil
                overlay_builder = nil
                overlay_collectors = nil
                overlay_offset = 0
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
                        event.key == "left" and -1 or 1)
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
                    inspect_entity(entity_selection.entities[entity_selection.index])
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
                        thread_selection.index = math.max(1, math.min(count,
                            thread_selection.index + (event.direction == "down" and 1 or -1)))
                        refresh_thread_picker()
                        dirty = true
                    elseif navigate and count > 0 then
                        if event.key == "home" then
                            thread_selection.index = 1
                        elseif event.key == "end" then
                            thread_selection.index = count
                        else
                            local delta = (event.key == "pageup" or event.key == "pagedown")
                                and math.max(1, rows - 8) or 1
                            if event.key == "up" or event.key == "pageup" then delta = -delta end
                            thread_selection.index = math.max(1,
                                math.min(count, thread_selection.index + delta))
                        end
                        refresh_thread_picker()
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
                        dirty = true
                    end
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
                process_detail = nil
                thread_selection = nil
                engine.context.selected_thread_ids = {}
                overlay = nil
                overlay_builder = nil
                overlay_collectors = nil
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
        elseif (key == "up" or key == "down" or key == "pageup"
                or key == "pagedown" or key == "home" or key == "end")
            and workspace.active == "gpu" then
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
        elseif key == "k" and workspace.active == "gpu" then
            -- The device's own clocks, which is a different question from
            -- either drill-down: `Enter` asks who is on this card, `i` asks
            -- what one client is doing, and this asks what the hardware itself
            -- is running.  It stays available when nothing is selected, because
            -- a card's clocks exist whether or not a process is drawing on it.
            gpu_device_selection = { devices = gpu_clock_devices(), index = 1 }
            refresh_gpu_device_overlay()
            dirty = true
        elseif key == "i" and workspace.active == "gpu" then
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
        elseif key == "enter" and workspace.active == "gpu" then
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
        elseif key == "enter" and workspace.active == "workloads" then
            -- Cross-link into the process table.  cgroup.procs is read for
            -- every node already, so the member set costs nothing here.
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
            local members = node and node.processes and node.processes.pids or nil
            if type(members) == "table" and #members > 0 then
                local semantics = node.semantics
                local label = semantics and semantics.label or node.name or node.id
                process_controller:set_pid_filter(members, label)
                workspace:select("processes")
                sync_selected_process()
                status_message = translated(translator, "workloads.members_status",
                    "{count} processes in {name} · Esc clears", {
                        count = #members, name = label,
                    })
            else
                status_message = translated(translator, "workloads.no_members",
                    "No readable process is listed in that cgroup")
            end
            dirty = true
        elseif (key == "up" or key == "down" or key == "pageup"
                or key == "pagedown" or key == "home" or key == "end")
            and workspace.active == "workloads" then
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
        elseif key == "c" and workspace.active == "workloads" then
            if workload_selected_id == nil then
                -- The cursor conceptually starts at the top row; the first
                -- collapse press targets it instead of doing nothing.
                local ids = models and models.workload_table
                    and models.workload_table.ids
                if type(ids) == "table" and ids[1] then
                    workload_selected_id = ids[1]
                end
            end
            if workload_selected_id ~= nil then
                if workload_collapsed[workload_selected_id] then
                    workload_collapsed[workload_selected_id] = nil
                else
                    workload_collapsed[workload_selected_id] = true
                end
                dirty = true
            end
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
        elseif key == "C" and workspace.active == "processes" then
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
        elseif key == "m" and workspace.active == "network" then
            mask_remote = not mask_remote
            status_message = translated(translator,
                mask_remote and "status.mask_on" or "status.mask_off",
                mask_remote and "Remote addresses are masked"
                or "Remote addresses are shown in full")
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
            show_overlay(help_lines(translator, columns, linux_host))
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
        elseif key == "k" and workspace.active == "processes" then
            local process = selected_process()
            if #action_choices == 0 then
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
        elseif key == "enter" and workspace.active == "processes" then
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
        elseif key == "s" and linux_host then
            inspect_smart()
            dirty = true
        elseif key == "b" and linux_host then
            inspect_bandwidth()
            dirty = true
        elseif key == "d" and linux_host then
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
            virtual = "v", mask = "m", smart = "s", bandwidth = "b", sshd = "d",
            sensors = "h",
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
        local _, completed = engine:tick(false)
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
            if input_activity or force or now - last_presented_ns >= interval_ns then
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
        local saved, save_error = LayoutStore.save(
            workspace:orders(), layout_status and layout_status.path, workspace:trees(),
            workspace:saved_workspaces(), workspace.workspace, layout_columns)
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
M.sensor_detail_lines = sensor_detail_lines
M.process_detail_lines = process_detail_lines
M.process_column_lines = process_column_lines
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
M.utf8_backspace = utf8_backspace

return M

