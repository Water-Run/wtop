local Engine = require("wtop.engine")
local Technical = require("wtop.i18n.technical")
local ProcessTable = require("wtop.model.process_table")
local ProcessColumns = require("wtop.model.process_columns")
local ConnectionFilter = require("wtop.model.connection_filter")
local WorkloadFilter = require("wtop.model.workload_filter")
local MountFilter = require("wtop.model.mount_filter")
local Quality = require("wtop.model.quality")
local Power = require("wtop.model.power")
local PowerDomains = require("wtop.model.power_domains")
local PowerSession = require("wtop.model.power_session")
local GPUPowerSession = require("wtop.model.gpu_power_session")
local SensorPower = require("wtop.model.sensor_power")
local CPULimits = require("wtop.model.cpu_limits")
local Thermal = require("wtop.model.thermal")
local StorageHealth = require("wtop.model.storage_health")
local Hardware = require("wtop.model.hardware")
local HardwareFilter = require("wtop.model.hardware_filter")
local Privacy = require("wtop.privacy")

local M = {}
local EMPTY_PROCESS_SOURCE = {}
local PROCESS_VIEW_CACHE = setmetatable({}, { __mode = "k" })
local TABLE_ROW_LIMIT = 512

-- How wide a column is when its cell is a technical state or quality label.
--
-- Measured, not chosen: the widest label the ten shipped catalogues produce is
-- French "Échantillon manquant" for `gap`, at 20 terminal cells, and five labels
-- exceed 13 (`gap` 20, `denied` and `unavailable` 15, `stale` 14, `reset` and
-- `truncated` 13).  Sizing these columns to the English words clipped the rest.
--
-- It is a *preferred* width, and that is what makes the number safe to raise.
-- `ui/widgets/table.lua` includes a column when its `min_width` fits the area
-- and then hands out the leftover cells one at a time, up to this width, so a
-- preferred width cannot cost another column its place.  Measured across the
-- eight sizes the PTY matrix uses: 22 of 64 (column, size) pairs change and no
-- table loses a column anywhere; the 42 that do not are the tight sizes where
-- the column already sits at its minimum and would have been clipped either
-- way.  `min_width` is deliberately left alone for the same reason -- raising
-- it would make the column *disappear* on a narrow terminal, which is a worse
-- answer than a short cell.
local STATE_COLUMN_WIDTH = 20

local function bounded_best_add(heap, limit, better, value)
    local function worse(left, right) return better(right, left) end
    local function sift_up(index)
        while index > 1 do
            local parent = math.floor(index / 2)
            if not worse(heap[index], heap[parent]) then break end
            heap[index], heap[parent] = heap[parent], heap[index]
            index = parent
        end
    end
    local function sift_down(index)
        while true do
            local left = index * 2
            if left > #heap then break end
            local right = left + 1
            local child = right <= #heap and worse(heap[right], heap[left]) and right or left
            if not worse(heap[child], heap[index]) then break end
            heap[index], heap[child] = heap[child], heap[index]
            index = child
        end
    end
    if #heap < limit then
        heap[#heap + 1] = value
        sift_up(#heap)
    elseif better(value, heap[1]) then
        heap[1] = value
        sift_down(1)
    end
end

local function bounded_best_values(values, limit, better)
    local heap = {}
    for _, value in ipairs(values or {}) do
        bounded_best_add(heap, limit, better, value)
    end
    table.sort(heap, better)
    return heap
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

local function formatted(call, fallback)
    local ok, value = pcall(call)
    return ok and value or fallback or "—"
end

local function percent(format, value)
    if type(value) ~= "number" then
        return "—"
    end
    return formatted(function()
        return assert(format:percent(value, { precision = 1 }))
    end)
end

local function power_usage(format, comparison)
    if not comparison then return "—" end
    local filled = math.floor(math.min(100, comparison.percent) * 8 / 100 + 0.5)
    if comparison.percent > 0 then filled = math.max(1, filled) end
    -- Visible with TERM=dumb, monochrome output and classic Windows consoles.
    return "[" .. string.rep("#", filled) .. string.rep("-", 8 - filled) .. "] "
        .. percent(format, comparison.percent)
end

local function bytes(format, value)
    if type(value) ~= "number" then
        return "—"
    end
    return formatted(function()
        return assert(format:bytes(value))
    end)
end

local function rate(format, value)
    if type(value) ~= "number" then
        return "—"
    end
    return bytes(format, value) .. "/s"
end

local function frequency(format, value)
    if type(value) ~= "number" then return "—" end
    return formatted(function() return assert(format:frequency(value)) end)
end

local function temperature(format, value)
    if type(value) ~= "number" then return "—" end
    return formatted(function() return assert(format:temperature(value, { precision = 1 })) end)
end

local function duration(format, seconds)
    if type(seconds) ~= "number" then return "—" end
    return formatted(function() return assert(format:duration(seconds)) end)
end

local function number(format, value, precision)
    if type(value) ~= "number" then return "—" end
    return formatted(function()
        return assert(format:number(value, { precision = precision or 0 }))
    end)
end

-- Severity accessors shared by the table and bar widgets.  Returning a token
-- name rather than a colour keeps the palette decision inside the theme.
local function severity_token(value, warn, critical)
    if type(value) ~= "number" or value ~= value then return nil end
    if value >= critical then return "metric.critical" end
    if value >= warn then return "metric.warn" end
    return nil
end

-- Severity for quantities where a *low* reading is the bad one (available
-- entropy, battery charge, free capacity).  Expressing it by negating the
-- value and reusing severity_token was both unreadable and wrong at the
-- boundary: a saturated 256-byte entropy pool came out as a warning.
local function severity_below(value, warn, critical)
    if type(value) ~= "number" or value ~= value then return nil end
    if value <= critical then return "metric.critical" end
    if value <= warn then return "metric.warn" end
    return nil
end

local function fraction_of(value, maximum)
    if type(value) ~= "number" or type(maximum) ~= "number" or maximum <= 0 then
        return nil
    end
    return math.max(0, math.min(1, value / maximum))
end

local function entry(label_id, fallback, value, options)
    options = options or {}
    return {
        label_id = label_id,
        label = fallback,
        value = value,
        token = options.token,
        emphasis = options.emphasis,
    }
end

local function section(section_id, fallback)
    return { section = fallback, section_id = section_id }
end

local function quality(snapshot, resource)
    local state = snapshot.quality and snapshot.quality[resource]
    return state and state.quality or "unavailable"
end

local function network_source_status(snapshot, i18n)
    local state = snapshot.quality and snapshot.quality.network
    if type(state) ~= "table" then return nil end
    local label = state.quality == "stale" and "stale"
        or (state.status and state.status ~= "ok" and state.status or nil)
    if not label then return nil end
    local text = Technical.state(i18n, label)
    if state.reason then text = text .. " · " .. Technical.reason(i18n, state.reason) end
    return text
end

local function process_sort_label(i18n, key)
    local labels = {
        cpu = { "process.sort.cpu", "CPU" },
        memory = { "process.sort.memory", "Memory" },
        pid = { "process.sort.pid", "PID" },
        name = { "process.sort.name", "Name" },
        io_read = { "process.sort.io_read", "I/O read" },
        io_write = { "process.sort.io_write", "I/O write" },
        io_read_rate = { "process.sort.io_read_rate", "I/O read rate" },
        io_write_rate = { "process.sort.io_write_rate", "I/O write rate" },
        time = { "process.sort.time", "CPU time" },
        elapsed = { "process.sort.elapsed", "Elapsed time" },
        threads = { "process.sort.threads", "Threads" },
        virtual = { "process.sort.virtual", "Virtual memory" },
        state = { "process.sort.state", "State" },
        user = { "process.sort.user", "User" },
        priority = { "process.sort.priority", "Priority" },
        nice = { "process.sort.nice", "Nice" },
    }
    local label = labels[key] or labels.cpu
    return translated(i18n, label[1], label[2])
end

--- The process table's columns, in the order the user chose.
---
--- Every column is defined here once and then emitted in the order the column
--- state asks for, so a column cannot be described in one place and ordered in
--- another.  `priority` and `full_only` stay on the column: those decide what a
--- *small panel* drops, which is the renderer's call and still applies on top of
--- whatever the user has chosen.  A column the user hid is absent from the list
--- entirely rather than present and widthless, so it is not merely squeezed out
--- on a wide terminal too.
--- The widest pid Linux can hand out, in cells.
---
--- `/proc/sys/kernel/pid_max` is capped at 2^22, so `4194304` -- seven digits --
--- is the ceiling on every kernel, and a column that can be given fewer than
--- seven cells will eventually draw one of those as `41943…`, which is a
--- different pid and, on a long-lived host, a pid that exists.  A pid is the one
--- value in this table a reader acts on: `k` opens a confirmation naming it and
--- the thread picker filters on it, so a shortened pid is not a cosmetic loss the
--- way a shortened sentence is -- increment 84 deliberately left `min_width`
--- alone for exactly that reason, and this is the case where the trade runs the
--- other way.  `min_width` is the right lever rather than `width` because it is
--- what the table guarantees: a column is only selected when its minimum fits,
--- selection runs in priority order, and the PID column is at 90 while the
--- columns that would give up their cells (`Virt` 35, `Link` 40, `MTU` 35) sit
--- near the bottom.  So the two extra cells are taken from the least important
--- column rather than out of the pid's own digits -- and where even that is not
--- enough the column leaves the screen entirely, which is the correct answer for
--- a value that cannot be shown honestly.
local PID_COLUMN_MIN_WIDTH = 7

local function ordered_process_columns(chosen, i18n, process_status, platform)
  local definitions = {
    pid = {
      key = "pid", label = "PID", sort_key = "pid",
      width = 8, min_width = PID_COLUMN_MIN_WIDTH, priority = 90,
      align = "right", highlight = true,
    },
    user = {
      key = "user", label = translated(i18n, "metrics.user", "User"),
      sort_key = "user", width = 12, min_width = 8, priority = 55, highlight = true,
    },
    priority = {
      key = "priority", label = "PRI", sort_key = "priority", width = 4, min_width = 3,
      align = "right", priority = 20, full_only = true,
    },
    nice = {
      key = "nice", label = "NI", sort_key = "nice", width = 4, min_width = 3,
      align = "right", priority = 22, full_only = true,
    },
    virtual_memory = {
      key = "virtual_memory", label = translated(i18n, "metrics.virtual", "Virt"),
      sort_key = "virtual", width = 10, min_width = 8,
      align = "right", priority = 35, full_only = true,
    },
    memory = {
      key = "memory", label = translated(i18n, "metrics.memory", "Res"),
      sort_key = "memory", width = 10, min_width = 8, align = "right", priority = 80,
      token = function(_, row)
        return severity_token(row.memory_fraction and row.memory_fraction * 100, 10, 25)
      end,
      bar = function(_, row) return row.memory_fraction end,
    },
    state = {
      key = "state", label = "S", width = 3, min_width = 3, priority = 45,
      sort_key = "state",
      token = function(value)
        if value == "R" then return "metric.good" end
        if value == "D" then return "metric.critical" end
        if value == "Z" then return "metric.warn" end
        return nil
      end,
    },
    cpu = {
      key = "cpu", label = "CPU", sort_key = "cpu",
      width = 9, min_width = 7, align = "right", priority = 95,
      token = function(_, row) return severity_token(row.cpu_value, 40, 80) end,
      bar = function(_, row)
        return row.cpu_value and math.min(1, row.cpu_value / 100) or nil
      end,
    },
    time = {
      key = "time", label = "TIME+", sort_key = "time",
      width = 10, min_width = 8, align = "right", priority = 40,
    },
    elapsed = {
      key = "elapsed", label = "ETIME", sort_key = "elapsed",
      width = 10, min_width = 8, align = "right", priority = 30,
      full_only = true,
    },
    threads = {
      key = "threads", label = translated(i18n, "metrics.threads", "Thr"),
      sort_key = "threads", width = 5, min_width = 4,
      align = "right", priority = 25, full_only = true,
    },
    name = {
      key = "name", label = translated(i18n, "metrics.command", "Command"),
      sort_key = "name", width = 40, min_width = 12, priority = 85, highlight = true,
      truncate = process_status.show_paths
        and (platform == "Windows" or platform == "Darwin")
        and "path" or nil,
    },
    -- Run-queue wait, read only for the rows the viewport is showing.  The
    -- formatted value is computed in format_row, where the rate and its quality
    -- are known, and is nil for a row that has just scrolled into view or whose
    -- first reading has no interval yet.  Nil renders as "—", which is the
    -- honest cell: a zero here is the claim "this process never waited for a
    -- cpu", and that is exactly what the column exists to say.
    queued = {
      key = "queued", label = translated(i18n, "process.thread_queued", "Queued"),
      width = 11, min_width = 8, align = "right", priority = 30, full_only = true,
    },
    wait_site = {
      key = "wait_site", label = "WCHAN", width = 22, min_width = 12,
      priority = 30, full_only = true,
    },
    io_read_rate = {
      key = "io_read_rate", label = "IO R/s", sort_key = "io_read_rate",
      width = 11, min_width = 8, align = "right", priority = 28, full_only = true,
    },
    io_write_rate = {
      key = "io_write_rate", label = "IO W/s", sort_key = "io_write_rate",
      width = 11, min_width = 8, align = "right", priority = 28, full_only = true,
    },
  }
  local order = ProcessColumns.normalize(chosen)
  local result = {}
  for _, key in ipairs(order) do
    local definition = definitions[key]
    if definition and (key ~= "wait_site" or (platform or "Linux") == "Linux") then
      result[#result + 1] = definition
    end
  end
  return result
end

local function process_status_text(i18n, status)
    local filter = status.query ~= "" and translated(i18n, "process.filter_status",
        " · Filter: {query}", { query = status.query }) or ""
    local tree = status.tree and translated(i18n, "process.tree_status", " · Tree") or ""
    if status.tree and (status.hidden_by_collapse or 0) > 0 then
        tree = tree .. translated(i18n, "process.collapsed_status",
            " · {count} folded", { count = status.hidden_by_collapse })
    end
    local collection = status.collection_truncated and translated(i18n, "process.collection_truncated",
        " · collection capped at {limit}", { limit = status.collection_limit or status.total }) or ""
    -- A cgroup reached from the Workloads page is announced here rather than
    -- hidden, because nothing about the process table says why the rows ended.
    local cgroup = status.cgroup_filter and translated(i18n, "process.cgroup_status",
        " · cgroup: {name} · Esc clears", { name = status.cgroup_filter }) or ""
    local io_note = ""
    if status.requires_io and status.platform == "Linux" then
        local scan = status.io_scan
        if not scan then
            io_note = translated(i18n, "process.io_scan_pending", " · I/O loading")
        elseif status.requires_io_rate and (scan.rate_covered or 0) == 0 then
            io_note = translated(i18n, "process.io_rate_scan_pending",
                " · I/O rate needs another sample")
        elseif status.requires_io_rate and (scan.rate_covered or 0) < (scan.total or 0) then
            io_note = translated(i18n, "process.io_rate_scan_coverage",
                " · I/O rate {covered}/{total}", {
                    covered = scan.rate_covered or 0, total = scan.total or 0,
                })
        elseif scan.status ~= "ok" then
            io_note = translated(i18n, "process.io_scan_coverage",
                " · I/O {covered}/{total}", {
                    covered = scan.covered or 0, total = scan.total or 0,
                })
        end
    end
    tree = tree .. cgroup .. collection .. io_note
    return translated(i18n, "process.table_status",
        "Sort: {sort} {direction} · {visible}/{total}{filter}{tree}", {
            sort = process_sort_label(i18n, status.sort_key),
            direction = translated(i18n, status.descending and "process.direction.descending"
                or "process.direction.ascending", status.descending and "descending" or "ascending"),
            visible = status.visible,
            total = status.total,
            filter = filter,
            tree = tree,
            collection = collection,
        })
end

--- How long a process waited on a runqueue, per second.
---
--- Returns nil unless the collector published a *rate*: the file has to have
--- been read for this row, and two samples have to exist to have an interval to
--- divide by.  Both gaps are real and neither is a zero, so both are nil -- a
--- cell reading 0 would be the claim "this process never queued", and that is
--- exactly the claim this figure must not make without having measured it.
local function queued_rate(format, scheduler)
  if type(scheduler) ~= "table" then return nil end
  if scheduler.quality ~= "fresh" then return nil end
  local rate = scheduler.wait_rate_ns
  if type(rate) ~= "number" or rate ~= rate or rate < 0 then return nil end
  local rendered = format:duration(rate / 1000000000)
  if type(rendered) ~= "string" then return nil end
  return rendered .. "/s"
end

local function top_processes(snapshot, format, controller, i18n, platform)
    local source = snapshot.processes and snapshot.processes.list or EMPTY_PROCESS_SOURCE
    controller:update_if_changed(source)
    local status = controller:status()
    status.collection_truncated = snapshot.processes and snapshot.processes.truncated == true or false
    status.collection_limit = snapshot.processes and snapshot.processes.process_limit
    status.platform = platform
    status.io_scan = snapshot.processes and snapshot.processes.io_scan or nil
    local locale_id = type(i18n.locale) == "function" and i18n:locale() or nil
    local cached = PROCESS_VIEW_CACHE[controller]
    if cached and cached.revision == status.revision and cached.format == format
        and cached.i18n == i18n and cached.locale_id == locale_id
        and cached.platform == platform
        and cached.collection_truncated == status.collection_truncated
        and cached.collection_limit == status.collection_limit
        and cached.io_scan == status.io_scan
    then
        return cached.rows, status, cached.status_text
    end
    local source_rows = controller:rows()
    local row_count = #source_rows
    local clock_ticks = snapshot.processes and snapshot.processes.clock_ticks_per_second or 100
    local total_memory = snapshot.memory and snapshot.memory.total_bytes
    local function format_row(process)
        -- The kernel truncates /proc/<pid>/stat's comm at 15 characters, so a
        -- table built from it shows "systemd-timesyn".  cmdline is the honest
        -- name; `show_paths` decides whether its directory is kept.
        local name = process.command
        if platform == "Windows" and not status.show_paths and process.name then
            -- QueryFullProcessImageNameW supplies an image path, while
            -- Toolhelp already supplies its basename (including names whose
            -- directory contains spaces).
            name = process.name
        elseif platform == "Darwin" and not status.show_paths and name then
            -- proc_pidpath supplies an image path without arguments. Its
            -- basename remains intact when a parent directory has spaces.
            name = name:match("([^/]+)$") or name
        elseif name and not status.show_paths then
            local executable = name:match("^(%S+)") or name
            local base = executable:match("([^/]+)$")
            if base and base ~= "" then
                local arguments = name:sub(#executable + 1)
                name = base .. arguments
            end
        end
        name = name or process.name or "?"
        if status.tree then
            local prefix = string.rep("  ", math.min(process.tree_depth or 0, status.max_tree_depth or 64))
            name = prefix .. (process.tree_has_children
                and (process.tree_collapsed and "▸ " or "▾ ") or "· ") .. name
        end
        local cpu_seconds = process.cpu_time_seconds
        if type(cpu_seconds) ~= "number" or cpu_seconds ~= cpu_seconds
            or cpu_seconds < 0 or cpu_seconds == math.huge then
            cpu_seconds = type(process.cpu_ticks) == "number"
                and clock_ticks > 0 and process.cpu_ticks / clock_ticks or nil
        end
        return {
            id = process.id,
            pid = tostring(process.pid),
            name = name,
            cpu = process.cpu_percent and percent(format, process.cpu_percent) or "—",
            cpu_value = process.cpu_percent,
            memory = bytes(format, process.resident_bytes),
            memory_value = process.resident_bytes,
            memory_fraction = fraction_of(process.resident_bytes, total_memory),
            virtual_memory = bytes(format, process.virtual_bytes),
            threads = process.threads and tostring(process.threads) or "—",
            nice = process.nice and tostring(process.nice) or "—",
            priority = process.priority and tostring(process.priority) or "—",
            time = cpu_seconds and duration(format, cpu_seconds) or "—",
            elapsed = type(process.elapsed_seconds) == "number"
                and duration(format, process.elapsed_seconds) or "—",
            state = process.state or "—",
            user = process.user or "—",
            -- Run-queue wait is only read for the rows the viewport is showing,
            -- and only has a rate once two samples exist.  Both gaps render as
            -- nil, which the table draws as "—": a zero would be the claim that
            -- the process never waited for a cpu, which is the one thing this
            -- column must not invent.
            queued = queued_rate(format, process.scheduler),
            -- A visible Linux row reads the leader's wchan on demand. The
            -- kernel's 0 means no sleeping site was reported, not a measured
            -- zero. Other failures retain their localized status.
            wait_site = process.wait_site or (process.wait_site_status
                and process.wait_site_status ~= "not_reported"
                and Technical.state(i18n, process.wait_site_status == "parse_error"
                    and "error" or process.wait_site_status) or "—"),
            -- Process I/O byte counters are cumulative, not a per-second rate.
            -- Linux samples them for the selection; Windows bulk collection
            -- supplies them for every row without opening each process.
            read = bytes(format, process.io and process.io.read_bytes
                or process.io_read_bytes),
            write = bytes(format, process.io and process.io.write_bytes
                or process.io_write_bytes),
            io_read_rate = rate(format, process.io_rate
                and process.io_rate.read_bytes_per_second),
            io_write_rate = rate(format, process.io_rate
                and process.io_rate.write_bytes_per_second),
            process = process,
        }
    end
    -- The controller has already sorted and filtered every process. The table
    -- only draws the current viewport, so format rows when they are accessed.
    local rows = setmetatable({}, {
        __len = function() return row_count end,
        __index = function(result, index)
            if type(index) ~= "number" or index < 1 or index > row_count
                or index % 1 ~= 0 then return nil end
            local row = format_row(source_rows[index])
            rawset(result, index, row)
            return row
        end,
        __pairs = function(result)
            local function next_row(_, index)
                index = index + 1
                if index <= row_count then return index, result[index] end
            end
            return next_row, nil, 0
        end,
    })
    local status_text = process_status_text(i18n, status)
    PROCESS_VIEW_CACHE[controller] = {
        revision = status.revision,
        format = format,
        i18n = i18n,
        locale_id = locale_id,
        platform = platform,
        collection_truncated = status.collection_truncated,
        collection_limit = status.collection_limit,
        io_scan = status.io_scan,
        rows = rows,
        status_text = status_text,
    }
    return rows, status, status_text
end

local function core_rows(snapshot, format, i18n)
    local rows = {}
    local clocks = {}
    for _, row in ipairs(snapshot.cpu_clocks and snapshot.cpu_clocks.cpus or {}) do clocks[row.id] = row end
    local current = Quality.current_source(snapshot.quality, "cpu_clocks")
    for _, core in ipairs(snapshot.cpu and snapshot.cpu.cores or {}) do
        local id = type(core.name)=="string" and tonumber(core.name:match("^cpu(%d+)$"))
        local clock = id and clocks[id]
        local clock_quality = clock and (current and clock.quality or "stale")
        rows[#rows + 1] = {
            core = core.name,
            total = percent(format, core.utilization),
            total_value = core.utilization,
            user = percent(format, core.user),
            system = percent(format, core.system),
            iowait = percent(format, core.iowait),
            irq = percent(format, core.irq),
            steal = percent(format, core.steal),
            effective = clock and (clock_quality=="fresh" and frequency(format,clock.effective_hz)
                or Technical.state(i18n,clock_quality)) or "—",
            effective_value = clock and current and clock.quality=="fresh" and clock.effective_hz or nil,
            effective_window = clock and clock.interval_ns and string.format("%.1f ms",clock.interval_ns/1000000) or "—",
            effective_observed_at_ns = clock and clock.observed_at_ns,
        }
    end
    return rows
end

-- A default kernel registers sixteen ramdisks and a handful of loop devices.
-- They are always idle, always zero-length, and they used to push the real
-- disks off the visible rows, so they are hidden unless asked for.
local function disk_rows(snapshot, format, options)
    options = options or {}
    local rows = {}
    local hidden = 0
    -- The temperature column states where its figure came from, for the same
    -- reason the GPU table's does: a bare number next to a device is read as
    -- the device's own reading, and only the join's owner rule decides that.
    local temperature_by_disk = {}
    for _, entry in ipairs(M.disk_sensor_join(snapshot)) do
        local current = temperature_by_disk[entry.disk.name]
        if not current or (entry.temperature and current.temperature
            and entry.temperature.input > current.temperature.input)
            or (entry.temperature and not current) then
            temperature_by_disk[entry.disk.name] = entry
        end
    end
    for _, device in ipairs(snapshot.disks and snapshot.disks.devices or {}) do
        local identity = device.identity or {}
        local uninteresting = identity.virtual == true
            and (identity.size_bytes == nil or identity.size_bytes == 0
                or (device.read_bytes_per_second or 0) == 0
                and (device.write_bytes_per_second or 0) == 0)
        if uninteresting and not options.show_virtual then
            hidden = hidden + 1
        elseif #rows < TABLE_ROW_LIMIT then
            local temperature_entry = temperature_by_disk[device.name]
            local temperature_channel = temperature_entry
                and temperature_entry.temperature or nil
            local storage_temperature = StorageHealth.temperature(snapshot, device)
            if storage_temperature then temperature_channel = storage_temperature.channel end
            rows[#rows + 1] = {
                device = device.name,
                model = device.stack and (device.stack.name or device.stack.level)
                    or identity.model or identity.vendor or "—",
                size = bytes(format, identity.size_bytes),
                medium = identity.rotational == 1 and "HDD"
                    or (identity.rotational == 0 and "SSD" or "—"),
                temperature = temperature_channel
                    and (storage_temperature and storage_temperature.quality ~= "fresh"
                        and Technical.state(options.i18n, storage_temperature.quality)
                        or temperature(format, temperature_channel.input)) or "—",
                temperature_source = temperature_channel,
                temperature_quality = storage_temperature and storage_temperature.quality,
                critical = storage_temperature and temperature(format, storage_temperature.critical_celsius) or "—",
                thermal_headroom = storage_temperature and storage_temperature.headroom_celsius ~= nil
                    and formatted(function() return assert(format:temperature_delta(
                        storage_temperature.headroom_celsius, { precision = 1 })) end) or "—",
                scheduler = identity.scheduler or "—",
                read = rate(format, device.read_bytes_per_second),
                write = rate(format, device.write_bytes_per_second),
                busy = (device.busy_quality == "estimated" and type(device.busy_percent) == "number"
                    and "~" or "") .. percent(format, device.busy_percent),
                busy_value = device.busy_percent,
                queue = device.average_queue_size
                    and number(format, device.average_queue_size, 1) or "—",
                latency = device.average_read_latency_ms
                    and formatted(function() return assert(format:number(device.average_read_latency_ms, { precision = 1 })) end) .. " ms"
                    or "—",
            }
        end
    end
    return rows, hidden
end

local function network_rows(snapshot, format)
    local rows = {}
    for _, interface in ipairs(snapshot.network and snapshot.network.interfaces or {}) do
        local rates = interface.rates or {}
        local counters = interface.counters or {}
        local errors = (counters.rx_errors or 0) + (counters.tx_errors or 0)
        local drops = (counters.rx_drops or 0) + (counters.tx_drops or 0)
        local link_change = type(interface.link_events) == "table"
            and interface.link_events.change or nil
        local new_link_changes = type(link_change) == "table"
            and link_change.quality == "fresh" and link_change.new_changes or nil
        rows[#rows + 1] = {
            interface = interface.name,
            state = interface.operstate or "?",
            receive = rate(format, rates.rx_bytes_per_second),
            transmit = rate(format, rates.tx_bytes_per_second),
            -- Scaled, not concatenated.  `tostring(mbps) .. " Mbit/s"` reads the
            -- number sysfs gives and is exactly one cell too long from 100
            -- Gbit/s upward: `100000 Mbit/s` is thirteen cells into twelve, and
            -- what the reader is left with is a quantity with no unit.  The
            -- header says "Link" and not "Mbit/s", so both spellings are correct
            -- -- but only one of them fits.  `format:bits_per_second` is what the
            -- receive and transmit columns already go through, and measured over
            -- every rate a real NIC reports (1 to 400 Gbit/s) its longest
            -- output is `400 Gbit/s`, ten cells, against twelve today.
            speed = interface.speed_mbps
                and formatted(function()
                    return assert(format:bits_per_second(interface.speed_mbps * 1000000))
                end) or "—",
            mac = interface.address or "—",
            mtu = interface.mtu and tostring(interface.mtu) or "—",
            duplex = interface.duplex or "—",
            errors = tostring(errors),
            drops = tostring(drops),
            error_value = errors + drops,
            link_changes = type(new_link_changes) == "number"
                and (new_link_changes > 0 and "+" .. tostring(new_link_changes)
                    or "0") or "—",
            link_change_value = new_link_changes,
        }
    end
    return rows
end

local function softnet_entries(snapshot, format, i18n)
    local softnet = snapshot.network and snapshot.network.softnet or nil
    if type(softnet) ~= "table" or softnet.status ~= "ok" then
        return { entry("softnet.status", "Status",
            Technical.state(i18n, softnet and softnet.status or "unavailable")) }
    end
    local function events_per_second(value)
        return type(value) == "number" and number(format, value, 1) .. "/s" or "—"
    end
    local entries = {
        entry("softnet.cpus", "CPUs observed", number(format, softnet.cpu_count)),
        entry("softnet.backlog", "Receive backlog", number(format, softnet.backlog_packets)),
        entry("softnet.dropped_total", "Softnet drops", number(format, softnet.dropped)),
        entry("softnet.dropped_rate", "New drops", events_per_second(softnet.dropped_per_second)),
        entry("softnet.squeezed_rate", "Budget squeezes", events_per_second(
            softnet.time_squeeze_per_second)),
        entry("softnet.rate_quality", "Rate quality", Technical.state(i18n, softnet.quality)),
    }
    if softnet.hot_cpu ~= nil then
        entries[#entries + 1] = entry("softnet.hot_cpu", "Largest backlog",
            "CPU " .. tostring(softnet.hot_cpu) .. " · "
                .. number(format, softnet.hot_cpu_backlog))
    end
    return entries
end

local function connection_rows(snapshot, mask_remote, query, owner_id)
    local rank = { ESTABLISHED = 1, LISTEN = 2, SYN_SENT = 3, SYN_RECV = 4 }
    local function better(left, right)
        local left_rank, right_rank = rank[left.state] or 10, rank[right.state] or 10
        if left_rank ~= right_rank then return left_rank < right_rank end
        local left_owner = left.owners and left.owners[1]
        local right_owner = right.owners and right.owners[1]
        if (left_owner ~= nil) ~= (right_owner ~= nil) then return left_owner ~= nil end
        if left_owner and right_owner then
            local left_name, right_name = tostring(left_owner.name or "?"), tostring(right_owner.name or "?")
            if left_name ~= right_name then return left_name < right_name end
            local left_pid, right_pid = tonumber(left_owner.pid) or math.huge, tonumber(right_owner.pid) or math.huge
            if left_pid ~= right_pid then return left_pid < right_pid end
        end
        local left_protocol = tostring(left.protocol or left.table or "?")
        local right_protocol = tostring(right.protocol or right.table or "?")
        if left_protocol ~= right_protocol then return left_protocol < right_protocol end
        local left_local = left.local_endpoint and left.local_endpoint.text or left.path or ""
        local right_local = right.local_endpoint and right.local_endpoint.text or right.path or ""
        if left_local ~= right_local then return left_local < right_local end
        return tostring(left.id or left.base_id or "") < tostring(right.id or right.base_id or "")
    end
    local compiled = ConnectionFilter.compile(query)
    local source = snapshot.connections and snapshot.connections.connections or {}
    local selected, matching = {}, 0
    local function visible_remote(connection)
        local endpoint = connection.remote_endpoint
        return endpoint and (mask_remote
            and Privacy.masked_endpoint_text(endpoint) or endpoint.text) or "—"
    end
    local function matches(connection)
        if owner_id then
            local found = false
            for _, owner in ipairs(connection.owners or {}) do
                if owner.id == owner_id then found = true; break end
            end
            if not found then return false end
        end
        return ConnectionFilter.matches(compiled, connection, visible_remote(connection))
    end
    for _, connection in ipairs(source) do
        if matches(connection) then
            matching = matching + 1
            bounded_best_add(selected, TABLE_ROW_LIMIT, better, connection)
        end
    end
    table.sort(selected, better)
    local rows = {}
    for _, connection in ipairs(selected) do
        local owners = {}
        for _, owner in ipairs(connection.owners or {}) do
            owners[#owners + 1] = (owner.name or "?") .. "(" .. tostring(owner.pid or "?") .. ")"
        end
        rows[#rows + 1] = {
            protocol = string.upper(connection.protocol or connection.table or "?"),
            local_endpoint = connection.local_endpoint and connection.local_endpoint.text
                or connection.path or "—",
            remote_endpoint = visible_remote(connection),
            state = connection.state or "—",
            process = #owners > 0 and table.concat(owners, ", ") or "—",
            queue = tostring((connection.tx_queue or 0) + (connection.rx_queue or 0)),
            uid = connection.uid and tostring(connection.uid) or "—",
            connection_ref = connection,
        }
    end
    return rows, matching
end

-- GPU board figures come from the general hwmon snapshot, joined on
-- `class`/`device_target`.  hwmon has no vocabulary for "board total": a GPU
-- driver may publish a package power *and* per-rail powers on the same device,
-- and those overlap, so summing them would invent a number no meter ever
-- measured. Direct power readings take priority over energy-window averages;
-- within that kind the largest channel is shown. Its source travels with it -- otherwise the
-- table shows a bare watt figure that a reader will take for a board total.
--
-- This is one function with two consumers on purpose: the GPU table's numbers
-- and the sensor overlay's account of where they came from must not be able to
-- disagree.
function M.gpu_sensor_join(snapshot)
    local sensors = snapshot and snapshot.sensors and snapshot.sensors.devices or {}
    local by_class, by_target = {}, {}
    for _, sensor in ipairs(sensors) do
        if sensor.class then by_class[sensor.class] = sensor end
        if sensor.device_target then by_target[sensor.device_target] = sensor end
    end

    local entries = {}
    local gpus = snapshot and snapshot.gpus and snapshot.gpus.devices or {}
    for _, gpu in ipairs(gpus) do
        local matched, seen = {}, {}
        local can_join = gpu.identity_quality ~= "stale" and Quality.current_source(snapshot.quality,"gpus")
        local function add_sensor(sensor)
            if can_join and sensor and not seen[sensor] then
                seen[sensor] = true
                matched[#matched + 1] = sensor
            end
        end
        for _, reference in ipairs(gpu.hwmon_refs or {}) do
            add_sensor(reference.class and by_class[reference.class])
            add_sensor(reference.device_target and by_target[reference.device_target])
        end
        add_sensor(gpu.device_target and by_target[gpu.device_target])

        local temperature, power, fan
        local power_channels, energy_channels = 0, 0
        for _, sensor in ipairs(matched) do
            for _, channel in ipairs(sensor.channels or {}) do
                local current = channel.power ~= nil
                    and SensorPower.channel(channel, snapshot.timestamp_ns, snapshot.quality and snapshot.quality.sensors) or channel
                if current and (type(current.input) == "number" or current.input_source == "energy_delta" or current.verified_cap) then
                    if channel.type == "temperature" then
                        -- The hottest junction is the one that throttles; an
                        -- edge sensor and a hot spot are not interchangeable, so
                        -- the maximum is stated as a maximum rather than
                        -- averaged into something that is neither.
                        temperature = temperature
                            and (current.input > temperature.input and current or temperature)
                            or current
                    elseif channel.type == "power" or current.input_source == "energy_delta" then
                        if current.input_source == "energy_delta" then energy_channels = energy_channels + 1
                        else power_channels = power_channels + 1 end
                        local direct = current.input_source ~= "energy_delta"
                        local prior_direct = power and power.input_source ~= "energy_delta"
                        local measured = Power.reading(current.input) ~= nil
                        local prior_measured = power and Power.reading(power.input) ~= nil
                        if not power or (measured and not prior_measured)
                            or (measured == prior_measured and ((direct and not prior_direct)
                                or (direct == prior_direct and (current.input or -1) > (power.input or -1)))) then power = current end
                    elseif channel.type == "fan" then
                        -- A board with several fans reports several channels;
                        -- the fastest is the one an operator would act on.
                        fan = fan and (current.input > fan.input and current or fan) or current
                    end
                end
            end
        end
        for _, sensor in ipairs(matched) do
            entries[#entries + 1] = {
                gpu = gpu,
                sensor = sensor,
                sensors = matched,
                temperature = temperature,
                power = power,
                power_channels = power and power.input_source == "energy_delta" and energy_channels or power_channels,
                fan = fan,
            }
        end
    end
    return entries
end

-- Disk figures come from the same hwmon snapshot, joined on what the sensor
-- device's `device_target` names.  The GPU join keys on `class` because amdgpu
-- publishes one; disks have no such attribute, and the target's basename is
-- the honest key that is left: "../../nvme0" names the nvme controller,
-- "../sda" would name a SATA disk outright.  A disk claims a sensor device
-- when the basename is its own name, or the controller a namespace hangs
-- from -- the kernel names a controller nvme0 and its namespaces nvme0n1,
-- nvme0n2, so nvme0n1 belongs to nvme0 while nvme10n1 does not belong to
-- nvme1, and the "n" is what keeps those apart.  A partition (nvme0n1p3) is
-- never a match: sensors live on the controller or the whole disk, and the
-- mount join below is what carries the partition the rest of the way.
--
-- Like the GPU join this is one function with two consumers -- the storage
-- table's temperature column and the sensor overlay's account of which disk
-- read which device -- so the two cannot disagree.  Temperature is the only
-- figure: disks publish temperature channels, and no defensible rule turns
-- their sparse other channels into a board figure.  The hottest channel is
-- the one that throttles, stated as a maximum rather than averaged into
-- something no sensor measured.
function M.disk_sensor_join(snapshot)
    local disks = snapshot and snapshot.disks and snapshot.disks.devices or {}
    local by_name = {}
    for _, disk in ipairs(disks) do
        if type(disk.name) == "string" and disk.name ~= ""
            and not by_name[disk.name] then
            by_name[disk.name] = disk
        end
    end
    local function owner_disk(target)
        if type(target) ~= "string" then return nil end
        local basename = target:match("([^/]+)%s*$")
        if not basename or basename == "" then return nil end
        local exact = by_name[basename]
        if exact then return exact end
        local controller = basename:match("^nvme%d+$")
        if not controller then return nil end
        local prefix = controller .. "n"
        local best_name
        for name in pairs(by_name) do
            if name:sub(1, #prefix) == prefix
                and name:sub(#prefix + 1):match("^%d+$") then
                if not best_name or #name < #best_name then best_name = name end
            end
        end
        return best_name and by_name[best_name] or nil
    end

    local entries = {}
    for _, sensor in ipairs(snapshot and snapshot.sensors
        and snapshot.sensors.devices or {}) do
        local disk = owner_disk(sensor.device_target)
        if disk then
            local temperature
            for _, channel_entry in ipairs(sensor.channels or {}) do
                if channel_entry.type == "temperature"
                    and type(channel_entry.input) == "number" then
                    temperature = temperature
                        and (channel_entry.input > temperature.input
                            and channel_entry or temperature)
                        or channel_entry
                end
            end
            entries[#entries + 1] = {
                disk = disk,
                sensor = sensor,
                temperature = temperature,
            }
        end
    end
    return entries
end

-- The mount side of the same topology: which disk a mount reads, carried by
-- the device name in the mount's source.  Partitions extend their disk's name
-- by digits or by "p" plus digits (sda1, nvme0n1p3), so the longest disk name
-- that a source basename extends is its owner; stacked devices (dm, md) have
-- slaves of their own in the disk collector's topology and are left to it
-- rather than guessed at here.  The shortest mount point wins, because a
-- reader asking "which disk is / on" wants the filesystem root, not the
-- deepest bind mount that happens to sit on the same partition.
function M.disk_mount_join(snapshot)
    local disks = snapshot and snapshot.disks and snapshot.disks.devices or {}
    local names = {}
    for _, disk in ipairs(disks) do
        -- Only whole disks own mounts: a partition is where the filesystem
        -- lives, but the reader's question is which disk it reads, and the
        -- partition's own entry in the device list would otherwise shadow its
        -- parent for exact source-name matches.
        if type(disk.name) == "string" and disk.name ~= ""
            and disk.is_partition ~= true then
            names[#names + 1] = disk.name
        end
    end
    table.sort(names, function(left, right) return #left > #right end)
    local by_disk = {}
    for _, mount in ipairs(snapshot and snapshot.mounts
        and snapshot.mounts.mounts or {}) do
        local basename = type(mount.source) == "string"
            and mount.source:match("([^/]+)%s*$") or nil
        if basename then
            for _, name in ipairs(names) do
                if basename == name or (basename:sub(1, #name) == name
                    and basename:sub(#name + 1):match("^p?%d+$")) then
                    local point = tostring(mount.mount_point or "")
                    local current = by_disk[name]
                    if not current or #point < #current then by_disk[name] = point end
                    break
                end
            end
        end
    end
    return by_disk
end

local function limit_quality(domain, state)
    if Power.unusable(state) then
        return type(state) == "table" and (state.quality or state.status) or state
    end
    return domain.quality
end

local function limit_names(domain, field, i18n)
    local names = {}
    for _, reason in ipairs(domain.reasons or {}) do
        if reason[field] == true then
            names[#names + 1] = translated(i18n, "limits.reason." .. reason.id, reason.id)
        end
    end
    return names
end

local function limit_status(domain, state, i18n)
    local q = limit_quality(domain, state)
    if Power.unusable(q) then return Technical.state(i18n, q) end
    if domain.active == false then return translated(i18n, "limits.inactive", "Not asserted") end
    if domain.active == true then
        local names = limit_names(domain, "active", i18n)
        if (domain.unknown_status_hex and domain.unknown_status_hex ~= "0x0000000000000000")
            or #(domain.unknown_reason_names or {}) > 0 then
            names[#names + 1] = translated(i18n, "limits.unknown_flags", "Unknown flags")
        end
        return #names > 0 and table.concat(names, ", ")
            or translated(i18n, "limits.unknown_reason", "Asserted; reason unavailable"), names
    end
    return translated(i18n, "status.unknown", "Unknown")
end

local function cpu_limit_overview_text(snapshot, i18n)
    local summary = CPULimits.reduce(snapshot.cpu_limits,
        snapshot.quality and snapshot.quality.cpu_limits)
    if summary.quality == "unavailable" and #summary.packages == 0 then return nil end
    local text
    if summary.active == true then
        local names = {}
        for _, id in ipairs(summary.reasons) do
            names[#names + 1] = translated(i18n, "limits.reason." .. id, id)
        end
        text = #names > 0 and table.concat(names, ", ")
            or translated(i18n, "limits.unknown_reason", "Asserted; reason unavailable")
    elseif summary.active == false then
        text = translated(i18n, "limits.inactive", "Not asserted")
    else
        local failure
        if summary.known_active + summary.known_inactive == 0 then
            for _, row in ipairs(summary.packages) do
                local state = row.quality or "unknown"
                if failure and failure ~= state then failure = "partial"; break end
                failure = state
            end
        end
        text = Technical.state(i18n, failure or summary.quality or "unknown")
    end
    if summary.active ~= nil and summary.quality == "partial" then
        text = text .. " (" .. Technical.state(i18n, "partial") .. ")"
    end
    local count = "?"
    if summary.active == true then
        local known = #summary.reasons
        count = known == 0 and ">=1"
            or (summary.complete and tostring(known) or ">=" .. known)
    elseif summary.active == false then
        count = "0"
    end
    return translated(i18n, "limits.current", "Current limits") .. ": " .. text,
        translated(i18n, "limits.flag_count", "Active flags: {count}", { count = count })
end

function M.cpu_limit_coverage_text(snapshot, i18n)
    local limits = snapshot.cpu_limits
    if type(limits) ~= "table" then return nil end
    local discovered, supported, observed = limits.domains_discovered,
        limits.domains_supported, limits.domains_observed
    for _, value in ipairs({ discovered, supported, observed }) do
        if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 8192 then return nil end
    end
    if discovered == nil or supported == nil or observed == nil
        or observed > supported or supported > discovered then return nil end
    local summary = CPULimits.reduce(limits, snapshot.quality and snapshot.quality.cpu_limits)
    return translated(i18n, "limits.coverage",
        "CPU limit domains: {observed}/{discovered} sampled · {supported} supported", {
            observed = observed, discovered = discovered, supported = supported,
        }) .. " · " .. Technical.state(i18n, summary.quality)
end

function M.performance_limit_rows(snapshot, i18n)
    local rows, total = {}, 0
    local function add(limits, owner, state)
        for _, domain in ipairs(limits and limits.domains or {}) do
            total = total + 1
            if #rows < TABLE_ROW_LIMIT then
                local recorded = limit_names(domain, "logged", i18n)
                local history
                for _, reason in ipairs(domain.reasons or {}) do
                    if reason.logged ~= nil then history = true; break end
                end
                local current, current_items = limit_status(domain, state, i18n)
                rows[#rows + 1] = { name = owner .. " [" .. tostring(domain.id) .. "]",
                    current = current, current_items = current_items,
                    recorded = history and (#recorded > 0 and table.concat(recorded, ", ")
                        or translated(i18n, "limits.no_recorded", "No flags recorded")) or nil,
                    quality = limit_quality(domain, state) or "unknown",
                    scope = translated(i18n, "limits.scope." .. tostring(domain.scope), domain.scope or "—"),
                    source = domain.source or domain.source_kind or "—",
                    raw_hex = domain.raw_hex, supported_hex = domain.supported_hex,
                }
            end
        end
    end
    add(snapshot.cpu_limits, "CPU", snapshot.quality and snapshot.quality.cpu_limits)
    for _, gpu in ipairs(snapshot.gpus and snapshot.gpus.devices or {}) do
        add(gpu.performance_limits, "GPU " .. tostring(gpu.card or gpu.id),
            snapshot.quality and snapshot.quality.gpus)
    end
    return rows, total
end

local function gpu_rows(snapshot, format, i18n)
    local rows = {}
    local joins = M.gpu_sensor_join(snapshot)
    local by_gpu = {}
    for _, entry in ipairs(joins) do
        local list = by_gpu[entry.gpu]
        if not list then
            list = {}
            by_gpu[entry.gpu] = list
        end
        list[#list + 1] = entry
    end
    for _, gpu in ipairs(snapshot.gpus and snapshot.gpus.devices or {}) do
        local metrics = gpu.metrics or {}
        local function qualified(text, value, key, group)
            local state = snapshot.quality and snapshot.quality.gpus
            local q = Power.unusable(state) and (type(state)=="table" and (state.quality or state.status) or state)
                or Quality.gpu_metric_quality(gpu, key, group)
            if value ~= nil and Power.unusable(q) then
                return Technical.state(i18n, q) .. " · " .. text
            end
            return text
        end
        local matched, seen = {}, {}
        local temperature_channel, power_channel, fan_channel
        local power_channels = 0
        for _, entry in ipairs(by_gpu[gpu] or {}) do
            for _, sensor in ipairs(entry.sensors) do
                if not seen[sensor] then
                    seen[sensor] = true
                    matched[#matched + 1] = sensor
                end
            end
            temperature_channel = temperature_channel or entry.temperature
            power_channel = power_channel or entry.power
            fan_channel = fan_channel or entry.fan
            power_channels = math.max(power_channels, entry.power_channels)
        end
        local temperature_celsius = metrics.temperature_celsius
            or (temperature_channel and temperature_channel.input)
        local vendor_power = Power.reading(metrics.power_watts) ~= nil
        local power_state = snapshot.quality and snapshot.quality[vendor_power and "gpus" or "sensors"]
        local vendor_quality = Quality.gpu_metric_quality(gpu,"power_watts","power")
        local vendor_state = Power.unusable(vendor_quality) and vendor_quality or power_state
        local sensor_state = snapshot.quality and snapshot.quality.sensors
        local sensor_current = power_channel and Power.reading(power_channel.input) ~= nil
            and not Power.unusable(power_channel.quality) and not Power.unusable(sensor_state)
            and Quality.current_source(snapshot.quality,"sensors")
        local use_sensor = vendor_power and Power.unusable(vendor_state) and sensor_current
            and gpu.identity_quality ~= "stale" and Quality.current_source(snapshot.quality,"gpus")
        local power_budget = Power.gpu(metrics, power_channel,
            vendor_power and vendor_state or power_state)
        if use_sensor then power_budget=Power.gpu({},power_channel,sensor_state);vendor_power=false end
        local power_from_sensor = power_channel and not vendor_power
        local sensor_power = power_from_sensor and power_channel.power or nil
        for _, cap in ipairs(sensor_power and sensor_power.limits or {}) do
            cap.usage = power_usage(format, cap.percent and { percent = cap.percent } or nil)
        end
        local function qualified_power(text,value,key)
            if not power_from_sensor then return qualified(text,value,key,key=="power_watts" and "power" or nil) end
            local q = Power.unusable(sensor_state) and (type(sensor_state)=="table"
                and (sensor_state.quality or sensor_state.status) or sensor_state) or power_channel.quality
            if value ~= nil and Power.unusable(q) then return Technical.state(i18n,q) .. " · " .. text end
            return text
        end
        local power_watts = power_budget.watts
        local power_observation = not power_from_sensor and gpu.metric_observations
            and gpu.metric_observations.power_watts
        local power_age_ns
        if power_observation and power_observation.retained
            and type(snapshot.timestamp_ns)=="number" and type(power_observation.observed_at_ns)=="number"
            and snapshot.timestamp_ns>=power_observation.observed_at_ns then
            power_age_ns=(snapshot.timestamp_ns+0.0)-power_observation.observed_at_ns
        end
        local fan_rpm = fan_channel and fan_channel.input
        local memory_used = metrics.memory_used_bytes or metrics.process_memory_bytes
        local memory_total = metrics.memory_total_bytes
        local memory_text = "—"
        if memory_used then
            memory_text = bytes(format, memory_used)
            if memory_total then memory_text = memory_text .. " / " .. bytes(format, memory_total) end
        end
        memory_text = qualified(memory_text, memory_used, metrics.memory_used_bytes ~= nil
            and "memory_used_bytes" or "process_memory_bytes", "memory")
        if memory_total and Power.unusable(Quality.gpu_metric_quality(gpu, "memory_total_bytes", "memory"))
            and not Power.unusable(Quality.gpu_metric_quality(gpu, "memory_used_bytes", "memory")) then
            memory_text = qualified(memory_text, memory_total, "memory_total_bytes", "memory")
        end
        local pci = gpu.pci or {}
        local pcie = pci.current_link_speed
        if pci.current_link_width then
            pcie = (pcie and (pcie .. " ") or "") .. "x" .. tostring(pci.current_link_width)
        end
        -- A device can publish several independent clocks: a discrete card
        -- drives a graphics clock and a memory clock, and a multi-tile device
        -- drives one per tile.  The column carries the promoted clock, and
        -- when that is one of several the cell says so -- a bare number under
        -- a header reading "Frequency" would claim to be the device's single
        -- clock, which on such a card is not what was measured.  The count is
        -- of the clocks the cell is *not* showing, so the figure stays the one
        -- people mean by GPU frequency and the row stops implying it is all
        -- of it.  The full set is in the exported clocks, not here: a table
        -- cell has no room to name which clock is which.
        local frequency_text = frequency(format, metrics.frequency_current_hz)
        if type(gpu.quality) == "table" and gpu.quality.frequency == "estimated"
            and metrics.frequency_current_hz ~= nil then frequency_text = "~" .. frequency_text end
        local clock_count = #(type(gpu.frequencies) == "table"
            and gpu.frequencies.domains or {})
        if clock_count > 1 and metrics.frequency_current_hz ~= nil then
            frequency_text = frequency_text .. " +" .. tostring(clock_count - 1)
        end
        frequency_text = qualified(frequency_text, metrics.frequency_current_hz, "frequency_current_hz", "frequency")
        local limits = gpu.performance_limits and gpu.performance_limits.domains or {}
        local limit_text, all_inactive, asserted, degraded = "—",
            #limits > 0 and not gpu.performance_limits.truncated
                and gpu.performance_limits.enumeration_complete ~= false, false, nil
        for _, domain in ipairs(limits) do
            local state = snapshot.quality and snapshot.quality.gpus
            local q = limit_quality(domain, state)
            all_inactive = all_inactive and domain.active == false and not Power.unusable(q)
            if domain.active == true and not Power.unusable(q) then
                limit_text = limit_status(domain, state, i18n)
                asserted = true
                break
            elseif Power.unusable(q) then degraded = Technical.state(i18n, q) end
        end
        if not asserted and all_inactive then
            limit_text = translated(i18n, "limits.inactive", "Not asserted")
        elseif not asserted and #limits > 0 then
            limit_text = degraded or translated(i18n, "status.unknown", "Unknown")
        end
        rows[#rows + 1] = {
            gpu = gpu.identity_quality=="stale" and (Technical.state(i18n,"stale") .. " · "
                .. tostring(gpu.model_name or gpu.card or gpu.id or "?")) or (gpu.model_name or gpu.card or gpu.id),
            -- The name of the card itself, which is the one string that tells two
            -- devices apart when they are the same device.  A four-GPU box
            -- reports four rows of "NVIDIA GeForce RTX 4090" with the same
            -- vendor, the same driver and the same clocks, and there is no
            -- column here that says which of the four a row is: give the model
            -- name forty cells and the rows are still identical.  `card0` is
            -- what the GPU process table has always shown, so the device table
            -- showing the same string is also what makes the two tables join up.
            card = tostring(gpu.card or gpu.id or "?"),
            vendor = gpu.vendor_name or gpu.vendor or "?",
            driver = gpu.driver or "?",
            utilization = qualified(percent(format, metrics.utilization_percent),
                metrics.utilization_percent, "utilization_percent", "utilization"),
            memory = memory_text,
            frequency = frequency_text,
            pcie = pcie or "—",
            temperature = qualified(temperature_celsius
                and formatted(function() return assert(format:temperature(temperature_celsius)) end)
                or "—", metrics.temperature_celsius, "temperature_celsius", "temperature"),
            hotspot_temperature = type(metrics.hotspot_temperature_celsius)=="number"
                and qualified(temperature(format,metrics.hotspot_temperature_celsius),
                    metrics.hotspot_temperature_celsius,"hotspot_temperature_celsius","temperature") or nil,
            graphics_voltage = type(metrics.graphics_voltage_volts)=="number"
                and qualified(number(format,metrics.graphics_voltage_volts,3).." V",
                    metrics.graphics_voltage_volts,"graphics_voltage_volts","voltage") or nil,
            power = qualified_power(power_watts and string.format("%.1f W", power_watts) or "—",
                power_watts, "power_watts"),
            power_limit = qualified_power(power_budget.limit and string.format("%.1f W",power_budget.limit) or "—",
                power_budget.limit,"power_limit_watts"),
            power_usage = power_usage(format, power_budget.comparison),
            power_percent = power_budget.comparison and power_budget.comparison.percent,
            power_budget_source = power_budget.source or power_budget.limit_source,
            power_scope = power_from_sensor and power_channel.power and power_channel.power.scope
                and translated(i18n,power_channel.power.scope == "gpu_gt" and "limits.scope.gpu_gt"
                    or "power.scope."..power_channel.power.scope,power_channel.power.scope)
                or not power_from_sensor and metrics.power_scope=="asic" and translated(i18n,"power.scope.asic","ASIC chip") or nil,
            power_measurement = power_from_sensor and power_channel.input_source == "energy_delta"
                and translated(i18n,"power.measurement.energy_delta","Energy-window average")
                or sensor_power and sensor_power.measurement == "current"
                    and translated(i18n,"power.measurement.current","Instantaneous")
                or power_from_sensor and power_channel.input_source == "average"
                    and translated(i18n,"power.measurement.average","Average")
                or not power_from_sensor and (metrics.power_measurement == "current" or metrics.power_measurement == "average"
                or metrics.power_measurement == "device_sample" or metrics.power_measurement == "driver_snapshot") and translated(i18n,
                    "power.measurement." .. metrics.power_measurement, metrics.power_measurement) or nil,
            power_interval_ns = power_from_sensor and power_channel.power and power_channel.power.power_interval_ns
                or not power_from_sensor and metrics.power_interval_ns or nil,
            sensor_power = sensor_power,
            power_age_ns = power_age_ns,
            power_reason = power_observation and power_observation.retained and power_observation.reason or nil,
            power_sessions = GPUPowerSession.public(gpu, snapshot.timestamp_ns, snapshot.quality and snapshot.quality.gpus),
            limits = limit_text,
            -- The channel the figures came from, so a reader can tell a
            -- package power from a rail and an edge sensor from a hot spot.
            fan = fan_rpm and formatted(function()
                return assert(format:number(fan_rpm, { precision = 0 }))
            end) .. " RPM" or qualified(percent(format,metrics.fan_speed_percent),
                metrics.fan_speed_percent,"fan_speed_percent","fan"),
            temperature_source = temperature_channel,
            power_source = power_channel,
            power_channels = power_channels,
            fan_source = fan_channel,
            sensor_sources = matched,
        }
    end
    return rows
end

local function gpu_process_rows(snapshot, format)
    local limit, total = 512, 0
    local candidates = {}

    local function better(left, right)
        if left.raw_utilization ~= right.raw_utilization then
            return left.raw_utilization > right.raw_utilization
        end
        if left.raw_memory ~= right.raw_memory then return left.raw_memory > right.raw_memory end
        if left.gpu ~= right.gpu then return left.gpu < right.gpu end
        if left.pid_number ~= right.pid_number then return left.pid_number < right.pid_number end
        return left.id < right.id
    end

    local function worse(left, right)
        return better(right, left)
    end

    local function heap_push(candidate)
        candidates[#candidates + 1] = candidate
        local index = #candidates
        while index > 1 do
            local parent = math.floor(index / 2)
            if not worse(candidates[index], candidates[parent]) then break end
            candidates[index], candidates[parent] = candidates[parent], candidates[index]
            index = parent
        end
    end

    local function heap_replace_worst(candidate)
        candidates[1] = candidate
        local index = 1
        while true do
            local left, right = index * 2, index * 2 + 1
            if left > #candidates then break end
            local child = left
            if right <= #candidates and worse(candidates[right], candidates[left]) then child = right end
            if not worse(candidates[child], candidates[index]) then break end
            candidates[index], candidates[child] = candidates[child], candidates[index]
            index = child
        end
    end

    for _, gpu in ipairs(snapshot.gpus and snapshot.gpus.devices or {}) do
        for _, process in ipairs(gpu.processes and gpu.processes.list or {}) do
            total = total + 1
            local memory_summary = process.memory_summary or {}
            local memory_bytes = memory_summary.resident_bytes
                or memory_summary.total_bytes or memory_summary.shared_bytes
            local candidate = {
                gpu = tostring(gpu.card or gpu.id or "?"),
                pid_number = type(process.pid) == "number" and process.pid or math.huge,
                id = tostring(process.id or process.pid or total),
                raw_utilization = type(process.utilization_percent) == "number"
                    and process.utilization_percent or -1,
                raw_memory = type(memory_bytes) == "number" and memory_bytes or -1,
                memory_bytes = memory_bytes,
                process_ref = process,
                gpu_ref = gpu,
            }
            if #candidates < limit then
                heap_push(candidate)
            elseif better(candidate, candidates[1]) then
                heap_replace_worst(candidate)
            end
        end
    end
    table.sort(candidates, better)

    local rows = {}
    for _, candidate in ipairs(candidates) do
            local process, gpu = candidate.process_ref, candidate.gpu_ref
            local engine_rows = {}
            for name, engine in pairs(process.engines or {}) do
                if type(engine) == "table" and type(engine.utilization_percent) == "number" then
                    engine_rows[#engine_rows + 1] = {
                        name = tostring(name),
                        utilization = engine.utilization_percent,
                    }
                end
            end
            table.sort(engine_rows, function(left, right)
                if left.utilization ~= right.utilization then
                    return left.utilization > right.utilization
                end
                return left.name < right.name
            end)
            local engine_labels = {}
            for index = 1, math.min(#engine_rows, 4) do
                local engine = engine_rows[index]
                engine_labels[index] = engine.name .. " " .. percent(format, engine.utilization)
            end
            if #engine_rows > 4 then engine_labels[#engine_labels + 1] = "…" end
            rows[#rows + 1] = {
                gpu = candidate.gpu,
                pid = process.pid and tostring(process.pid) or "—",
                pid_number = candidate.pid_number,
                process = process.name or "?",
                utilization = percent(format, process.utilization_percent),
                memory = bytes(format, candidate.memory_bytes),
                engines = #engine_labels > 0 and table.concat(engine_labels, ", ") or "—",
                quality = process.quality or (gpu.processes and gpu.processes.quality) or "—",
                raw_utilization = candidate.raw_utilization,
                raw_memory = candidate.raw_memory,
                process_ref = process,
                gpu_ref = gpu,
            }
    end
    return rows, total
end

local function cpufreq_rows(snapshot, format, i18n)
    local rows = {}
    local graph = Hardware.build(snapshot)
    local sources = {
        cpuinfo_cur_freq = translated(i18n, "cpufreq.source_hardware_current", "HW current"),
        cpuinfo_avg_freq = translated(i18n, "cpufreq.source_hardware_average", "HW average"),
        scaling_cur_freq = translated(i18n, "cpufreq.source_scaling", "Scaling"),
        ioreport_residency = "IOReport",
        pdh = "PDH",
        CallNtPowerInformation = "PowrProf",
    }
    for _, policy in ipairs(snapshot.cpu_frequency and snapshot.cpu_frequency.policies or {}) do
        local cpus = policy.affected_cpus or policy.related_cpus or {}
        local labels = {}
        for index, cpu in ipairs(cpus) do labels[index] = tostring(cpu) end
        local frequencies = policy.frequencies or {}
        local current_text = frequency(format, frequencies.current_hz)
        if frequencies.current_quality == "estimated" and frequencies.current_hz ~= nil then
            current_text = "~" .. current_text
        end
        local linked = policy.id and graph.by_id["cpufreq:" .. policy.id]
        local reading = linked and linked.temperature
        local scope = reading and reading.scope
        local scope_label = scope == "core"
            and translated(i18n, "cpufreq.temperature_core", "Core")
            or scope == "package"
                and translated(i18n, "cpufreq.temperature_package", "Package") or nil
        rows[#rows + 1] = {
            policy = policy.policy or policy.id,
            cpus = table.concat(labels, ","),
            current = current_text,
            source = sources[frequencies.current_source] or "—",
            temperature = scope_label and (scope_label .. " "
                .. temperature(format, reading.celsius)) or "—",
            temperature_scope = scope,
            temperature_sensor_id = reading and reading.sensor_id,
            minimum = frequency(format, frequencies.scaling_minimum_hz or frequencies.hardware_minimum_hz),
            maximum = frequency(format, frequencies.scaling_maximum_hz or frequencies.hardware_maximum_hz),
            governor = policy.governor or "—",
            driver = policy.driver or "—",
            quality = not Quality.current_source(snapshot.quality, "cpu_frequency")
                and quality(snapshot, "cpu_frequency") or policy.quality or frequencies.current_quality or "—",
        }
    end
    return rows
end

local function thermal_throttle_rows(snapshot, format)
    local rows = {}
    local current = Quality.current_source(snapshot.quality, "thermal_throttle")
    for _, cpu in ipairs(snapshot.thermal_throttle and snapshot.thermal_throttle.cpus or {}) do
        if #rows >= TABLE_ROW_LIMIT then break end
        rows[#rows + 1] = {
            cpu = "cpu" .. cpu.id,
            core_new = number(format, current and cpu.core_new or nil),
            package_new = number(format, current and cpu.package_new or nil),
            core_total = number(format, cpu.core_count),
            package_total = number(format, cpu.package_count),
            core_ms = number(format, cpu.core_total_time_ms),
            package_ms = number(format, cpu.package_total_time_ms),
        }
    end
    return rows
end

local function cpuidle_rows(snapshot, format, i18n)
    local rows, total = {}, 0
    local current = Quality.current_source(snapshot.quality, "cpuidle")
    for _, cpu in ipairs(snapshot.cpuidle and snapshot.cpuidle.cpus or {}) do
        for _, state in ipairs(cpu.states or {}) do
            total = total + 1
            if #rows < TABLE_ROW_LIMIT then
                rows[#rows + 1] = {
                    cpu = "cpu" .. cpu.id,
                    state = state.name or ("state" .. state.id),
                    usage_delta = number(format, current and state.usage_delta or nil),
                    reported_ms = number(format,
                        current and state.new_time_us and state.new_time_us / 1000 or nil, 1),
                    rejected_delta = number(format, current and state.rejected_delta or nil),
                    above_delta = number(format, current and state.above_delta or nil),
                    below_delta = number(format, current and state.below_delta or nil),
                    rejected_delta_quality = state.rejected_delta_quality,
                    above_delta_quality = state.above_delta_quality,
                    below_delta_quality = state.below_delta_quality,
                    latency_us = number(format, state.exit_latency_us),
                    target_us = number(format, state.target_residency_us),
                    disabled = state.disabled == nil and "—" or translated(i18n,
                        state.disabled and "cpuidle.yes" or "cpuidle.no",
                        state.disabled and "Yes" or "No"),
                    quality = not current and quality(snapshot, "cpuidle") or (state.time_delta_quality == "fresh"
                        and state.usage_delta_quality or state.time_delta_quality),
                }
            end
        end
    end
    return rows, total
end

local function sensor_value(channel, format)
    if channel.type == "temperature" then return temperature(format, channel.input) end
    if channel.type == "power" and type(channel.input) == "number" then
        return formatted(function() return assert(format:number(channel.input, { precision = 2 })) end) .. " W"
    end
    if channel.type == "voltage" and type(channel.input) == "number" then
        return formatted(function() return assert(format:number(channel.input, { precision = 3 })) end) .. " V"
    end
    if channel.type == "current" and type(channel.input) == "number" then
        return formatted(function() return assert(format:number(channel.input, { precision = 2 })) end) .. " A"
    end
    if channel.type == "energy" and type(channel.input) == "number" then
        return formatted(function() return assert(format:number(channel.input, { precision = 2 })) end) .. " J"
    end
    if channel.type == "fan" and type(channel.input) == "number" then
        return formatted(function() return assert(format:number(channel.input, { precision = 0 })) end) .. " RPM"
    end
    return "—"
end

local function sensor_rows(snapshot, format)
    local rows = {}
    local current = Thermal.current(snapshot)
    local source_quality = quality(snapshot, "sensors")
    if not current and (source_quality == "fresh" or source_quality == "estimated"
        or source_quality == "partial" or source_quality == "measured") then
        source_quality = "stale"
    end
    local function better(left, right)
        if left.alarm ~= right.alarm then return left.alarm end
        if left.device == right.device then return left.sensor < right.sensor end
        return left.device < right.device
    end
    for _, device in ipairs(snapshot.sensors and snapshot.sensors.devices or {}) do
        for _, channel in ipairs(device.channels or {}) do
            local thermal = Thermal.channel(snapshot, device, channel)
            bounded_best_add(rows, TABLE_ROW_LIMIT, better, {
                device = device.name or device.class or "?",
                sensor = channel.label or (channel.type .. " " .. tostring(channel.index)),
                type = channel.type,
                value = sensor_value(channel, format),
                critical = thermal and temperature(format, thermal.critical_celsius) or "—",
                headroom = thermal and thermal.headroom_celsius ~= nil
                    and formatted(function() return assert(format:temperature_delta(
                        thermal.headroom_celsius, { precision = 1 })) end) or "—",
                headroom_value = thermal and thermal.headroom_celsius,
                status = not current and source_quality
                    or (channel.fault and "FAULT" or (channel.alarm and "ALARM" or channel.quality or "—")),
                alarm = current and (channel.alarm == true or channel.fault == true),
            })
        end
    end
    table.sort(rows, better)
    return rows
end

local function sensor_columns(i18n, rows)
    local columns = {
        { key = "device", label = translated(i18n, "metrics.device", "Device"),
            width = 16, min_width = 9, priority = 80 },
        { key = "sensor", label = translated(i18n, "metrics.sensor", "Sensor"),
            width = 22, min_width = 12, priority = 90 },
        { key = "value", label = translated(i18n, "metrics.value", "Value"),
            width = 14, min_width = 9, align = "right", priority = 95 },
        { key = "status", label = translated(i18n, "metrics.state", "State"),
            width = STATE_COLUMN_WIDTH, min_width = 8, priority = 60,
            format = function(value) return Technical.state(i18n, value) end,
            token = function(value) return (value == "ALARM" or value == "FAULT")
                and "metric.critical" or nil end },
    }
    for _, row in ipairs(rows) do
        if row.critical ~= "—" then
            columns[#columns + 1] = {
                key = "critical", label = translated(i18n, "sensor.critical", "Critical"),
                width = 13, min_width = 8, align = "right", priority = 50,
            }
            columns[#columns + 1] = {
                key = "headroom", label = translated(i18n, "sensor.headroom", "To critical"),
                width = 14, min_width = 9, align = "right", priority = 55,
                token = function(_, row) return row.headroom_value
                    and row.headroom_value <= 0 and "metric.critical" or nil end,
            }
            break
        end
    end
    return columns
end

-- proc, sysfs, cgroup2, devpts, tracefs and friends are kernel plumbing.  A
-- storage page that lists twenty of them buries the one filesystem the
-- operator came to look at, so pseudo mounts are hidden by default and the
-- count of what was hidden is reported instead.
local function mount_rows(snapshot, format, options)
    options = options or {}
    local rank = { ["local"] = 1, network = 2, pseudo = 3 }
    local source = {}
    local hidden = 0
    local seen = {}
    for _, mount in ipairs(snapshot.mounts and snapshot.mounts.mounts or {}) do
        local capacity = mount.capacity or {}
        local is_pseudo = mount.kind == "pseudo"
            or (capacity.total_bytes ~= nil and capacity.total_bytes == 0)
        -- The same path can be mounted repeatedly; the last entry in
        -- mountinfo order is the one currently visible at that path.
        local key = tostring(mount.mount_point or mount.id or #source)
        if is_pseudo and not options.show_pseudo then
            hidden = hidden + 1
        elseif seen[key] then
            source[seen[key]] = mount
        else
            source[#source + 1] = mount
            seen[key] = #source
        end
    end
    local compiled = MountFilter.compile(options.query)
    local matching = {}
    for _, mount in ipairs(source) do
        if MountFilter.matches(compiled, mount) then
            matching[#matching + 1] = mount
        end
    end
    local selected = bounded_best_values(matching, TABLE_ROW_LIMIT,
        function(left, right)
            local left_rank, right_rank = rank[left.kind] or 4, rank[right.kind] or 4
            if left_rank ~= right_rank then return left_rank < right_rank end
            local left_mount, right_mount = tostring(left.mount_point or ""), tostring(right.mount_point or "")
            if left_mount ~= right_mount then return left_mount < right_mount end
            return tostring(left.id or left.source or "") < tostring(right.id or right.source or "")
        end)
    local rows = {}
    for _, mount in ipairs(selected) do
        local capacity = mount.capacity or {}
        local inode_used = mount.inodes and mount.inodes.used_percent
        rows[#rows + 1] = {
            mount = mount.mount_point,
            type = mount.fs_type,
            used = percent(format, capacity.used_percent),
            used_value = capacity.used_percent,
            available = bytes(format, capacity.available_bytes),
            size = bytes(format, capacity.total_bytes),
            inodes = inode_used and percent(format, inode_used) or "—",
            source = mount.source or "—",
            kind = mount.kind or "?",
            quality = mount.quality or (mount.partial and "partial" or "fresh"),
            readonly = mount.readonly == nil and "—"
                or (mount.readonly and "ro" or "rw"),
        }
    end
    return rows, hidden, #source, #matching
end

local function workload_by_id(snapshot)
    local lookup = {}
    for _, workload in ipairs(snapshot.workloads
        and snapshot.workloads.workloads or {}) do
        lookup[workload.id] = workload
    end
    return lookup
end

-- A container cgroup is named by the kernel as a 64-character id, or as a
-- "cri-containerd-<id>.scope" that says nothing at a glance.  The collector
-- already resolved what those components encode, so the row shows the runtime
-- and the short id.  A node that merely sits inside a container keeps its own
-- unit name, because that is the unit an operator would act on.
local function workload_row_name(workload)
    local semantics = workload.semantics
    if semantics and semantics.container_scope and semantics.label then
        return semantics.label
    end
    return workload.name or workload.id
end

local function workload_rows(snapshot, format, collapsed, selected_id, query)
    local source = snapshot.workloads and snapshot.workloads.workloads or {}
    local by_id = {}
    for _, workload in ipairs(source) do by_id[workload.id] = workload end
    query = type(query) == "string" and query:match("^%s*(.-)%s*$") or ""
    local filtering = query ~= ""
    local compiled = WorkloadFilter.compile(query)
    local direct, included = {}, {}
    local direct_count = 0
    if filtering then
        for _, workload in ipairs(source) do
            if WorkloadFilter.matches(compiled, workload) then
                direct[workload.id] = true
                direct_count = direct_count + 1
                local node, seen = workload, {}
                for _ = 1, 128 do
                    if seen[node.id] then break end
                    seen[node.id] = true
                    included[node.id] = true
                    node = node.parent_id and by_id[node.parent_id] or nil
                    if not node then break end
                end
            end
        end
    end
    local has_children = {}
    for _, workload in ipairs(source) do
        if workload.parent_id and by_id[workload.parent_id] then
            has_children[workload.parent_id] = true
        end
    end
    -- A collapsed node hides its whole subtree, not just direct children.
    -- The walk is bounded so a malformed parent graph cannot loop.
    local function hidden(workload)
        local parent = workload.parent_id
        local hops = 0
        while parent ~= nil and by_id[parent] ~= nil and hops < 128 do
            if collapsed and collapsed[parent] then return true end
            parent = by_id[parent].parent_id
            hops = hops + 1
        end
        return false
    end
    local rows, ids, selected_index, first_match_index = {}, {}, nil, nil
    local matched = 0
    for _, workload in ipairs(source) do
        if (not filtering and not hidden(workload)) or (filtering and included[workload.id]) then
            matched = matched + 1
            if #rows < TABLE_ROW_LIMIT then
                local io_rates = workload.io and workload.io.totals and workload.io.totals.rates or {}
                local pressure = workload.pressure and workload.pressure.cpu
                local cpu_pressure = pressure and pressure.some and pressure.some.avg10
                local children = has_children[workload.id]
                local marker = children and (not filtering and collapsed and collapsed[workload.id]
                    and "▸ " or "▾ ") or "· "
                rows[#rows + 1] = {
                    workload = string.rep("  ", math.min(workload.depth or 0, 6))
                        .. marker .. workload_row_name(workload),
                    cpu = percent(format, workload.cpu and workload.cpu.utilization_percent),
                    memory = bytes(format, workload.memory and workload.memory.current_bytes),
                    read = rate(format, io_rates.rbytes_per_second),
                    write = rate(format, io_rates.wbytes_per_second),
                    processes = number(format, workload.processes and workload.processes.count),
                    threads = number(format, workload.threads and workload.threads.count),
                    pressure = percent(format, cpu_pressure),
                    quality = workload.quality or "—",
                    raw_cpu = workload.cpu and workload.cpu.utilization_percent or -1,
                    workload_ref = workload,
                    filter_match = filtering and direct[workload.id] or nil,
                }
                ids[#ids + 1] = workload.id
                if filtering and direct[workload.id] and first_match_index == nil then
                    first_match_index = #rows
                end
                if selected_id ~= nil and workload.id == selected_id then
                    selected_index = #rows
                end
            end
        end
    end
    if filtering and selected_index == nil then selected_index = first_match_index end
    return rows, ids, selected_index, matched, direct_count
end

local function power_rows(snapshot, format, i18n)
    local rows, total = {}, 0
    local domain_ids = PowerDomains.identities(snapshot.power and snapshot.power.zones)
    local domain_labels = {
        cpu_package = { "power.rapl_package", "RAPL CPU package" },
        cpu_cores = { "power.rapl_cores", "RAPL PP0 CPU cores" },
        graphics = { "power.rapl_graphics", "RAPL PP1 graphics domain" },
        memory = { "power.rapl_memory", "RAPL DRAM" },
        platform = { "power.rapl_platform", "RAPL platform" },
    }
    local function seconds(value)
        if not Power.reading(value) then return "—" end
        if value > 0 and value < 1 then return number(format, value * 1000, 3) .. " ms" end
        return number(format, value, 3) .. " s"
    end
    local names = {
        long_term = translated(i18n, "power.long_term", "Sustained"),
        short_term = translated(i18n, "power.short_term", "Short"),
        peak_power = translated(i18n, "power.peak_power", "Peak"),
    }
    local rank = { long_term = 1, short_term = 2, peak_power = 3 }
    local zones = {}
    for _, zone in ipairs(snapshot.power and snapshot.power.zones or {}) do zones[#zones + 1] = zone end
    table.sort(zones, function(left, right)
        if (left.parent_id ~= nil) ~= (right.parent_id ~= nil) then return left.parent_id == nil end
        if (left.aggregate == true) ~= (right.aggregate == true) then return left.aggregate == true end
        if (left.source_kind or "") ~= (right.source_kind or "") then
            return (left.source_kind or "") < (right.source_kind or "")
        end
        return tostring(left.id or left.name) < tostring(right.id or right.name)
    end)
    for _, zone in ipairs(zones) do
        local kind = PowerDomains.kind(zone, domain_ids)
        local role = kind and domain_labels[kind]
        local constraints = {}
        for _, constraint in ipairs(zone.constraints or {}) do constraints[#constraints + 1] = constraint end
        table.sort(constraints, function(left, right)
            if (rank[left.name] or 4) ~= (rank[right.name] or 4) then
                return (rank[left.name] or 4) < (rank[right.name] or 4)
            end
            return tostring(left.id or left.name) < tostring(right.id or right.name)
        end)
        if #constraints == 0 then constraints[1] = {} end
        total = total + #constraints
        local power = Power.reading(zone.power_watts)
            and formatted(function()
                return assert(format:number(zone.power_watts, { precision = 2 }))
            end) .. " W" or "—"
        local energy = type(zone.energy_joules) == "number"
            and formatted(function()
                return assert(format:number(zone.energy_joules, { precision = 1 }))
            end) .. " J" or "—"
        local session = PowerSession.public(zone, snapshot.timestamp_ns)
        local power_state = snapshot.quality and snapshot.quality.power
        local age = Power.reading(zone.power_watts) ~= nil
            and Power.zone_age(zone, power_state, snapshot.timestamp_ns) or nil
        local reading_issues = {}
        for _, issue in ipairs(zone.issues or {}) do
            -- A failed optional cap attribute does not explain a missing
            -- watt reading. Keep these diagnostics tied to the inputs used.
            if issue.field == "energy" or issue.field == "power" then
                reading_issues[#reading_issues + 1] = {
                    field = issue.field, status = issue.status, source = issue.source,
                }
                if #reading_issues == 8 then break end
            end
        end
        for _, constraint in ipairs(constraints) do
            if #rows >= TABLE_ROW_LIMIT then break end
            local comparison = Power.zone(zone, constraint, power_state, snapshot.timestamp_ns)
            local limit = Power.limit(constraint.power_limit_watts)
                and formatted(function()
                    return assert(format:number(constraint.power_limit_watts, { precision = 1 }))
                end) .. " W" or "—"
            rows[#rows + 1] = {
                zone = zone.name or zone.id or "?",
                domain = zone.source_kind or "—",
                zone_id = zone.id,
                domain_kind = kind,
                scope = role and translated(i18n, role[1], role[2]) or nil,
                constraint = names[constraint.name] or constraint.name
                    or (constraint.id ~= nil and "#" .. tostring(constraint.id)) or "—",
                power = power,
                energy = energy,
                limit = limit,
                usage = power_usage(format, comparison),
                power_percent = comparison and comparison.percent,
                headroom = comparison and number(format, comparison.headroom_watts, 2) .. " W" or "—",
                window = seconds(constraint.time_window_seconds),
                interval = seconds(zone.power_interval_ns and zone.power_interval_ns / 1e9),
                source = zone.power_source or zone.power_quality or "—",
                power_source_path = zone.source,
                power_age_ns = age,
                power_reading_issues = reading_issues,
                state = Power.zone_state(zone, power_state, snapshot.timestamp_ns) or "—",
                power_session = session,
                controls = (zone.enabled == false or zone.control_enabled == false
                    or zone.controls_enabled == false) and "disabled"
                    or zone.controls_enabled == true and "enabled" or "unknown",
                aggregate = zone.aggregate == true,
            }
        end
    end
    return rows, total
end

local function overview_power_budgets(snapshot, format, i18n)
    local rows, total = Power.cpu_budgets(snapshot.power, snapshot.quality and snapshot.quality.power,
        TABLE_ROW_LIMIT, snapshot.timestamp_ns)
    local names = {
        long_term = translated(i18n, "power.long_term", "Sustained"),
        short_term = translated(i18n, "power.short_term", "Short"),
        peak_power = translated(i18n, "power.peak_power", "Peak"),
    }
    for index, row in ipairs(rows) do
        local state = Power.unusable(row.quality) and Technical.state(i18n, row.quality)
            or row.disabled and Technical.state(i18n, "disabled") or nil
        row.identity = tostring(index) .. " " .. tostring(row.zone_id)
        row.constraint = names[row.constraint_name] or row.constraint_name or "#" .. tostring(row.constraint_id)
        row.heading = row.identity .. " · " .. row.constraint
        local compact_id = tostring(row.zone_id):gsub("^intel%-rapl%-mmio:(%d+)$", "MMIO %1")
            :gsub("^intel%-rapl:(%d+)$", "RAPL %1")
        row.compact_identity = tostring(index) .. " " .. compact_id
        row.reading = (state and state .. " · " or "")
            .. (row.watts and number(format, row.watts, 2) .. " W" or "—")
            .. " / " .. number(format, row.limit_watts, 2) .. " W"
        row.usage = power_usage(format, row.comparison)
        row.state = state
        row.reading_compact = (row.watts and number(format, row.watts, 2) or "—")
            .. "/" .. number(format, row.limit_watts, 2) .. "W"
        row.percent_text = row.comparison and percent(format, row.comparison.percent) or "—"
        row.headroom_compact = translated(i18n, "power.headroom_short", "Left") .. ":"
            .. (row.comparison and number(format, row.comparison.headroom_watts, 2) .. "W" or "—")
        row.headroom = translated(i18n, "power.headroom", "To cap") .. ": "
            .. (row.comparison and number(format, row.comparison.headroom_watts, 2) .. " W" or "—")
        row.combined = row.usage .. " · " .. row.headroom
    end
    return { rows = rows, total = total }
end

local function graphics_power_summary(snapshot, format, i18n)
    local rows, truncated = PowerDomains.graphics(snapshot)
    if #rows == 0 then return nil end
    if #rows ~= 1 or truncated then
        return translated(i18n, "power.rapl_graphics_many", "RAPL PP1 domains: {count}",
            { count = truncated and tostring(#rows) .. "+" or #rows })
    end
    local row = rows[1]
    local value = row.watts ~= nil and number(format, row.watts, 2) .. " W"
        or Technical.state(i18n, row.quality)
    return translated(i18n, "power.rapl_graphics", "RAPL PP1 graphics domain") .. " · " .. value,
        { "RAPL PP1 · " .. value }
end

function M.power_detail_rows(snapshot, i18n)
    local zones, total = power_rows(snapshot, i18n.format, i18n)
    return zones, gpu_rows(snapshot, i18n.format, i18n), total
end

-- ---------------------------------------------------------------------------
-- Key/value builders
--
-- These replace hand-padded text blocks.  The previous approach concatenated a
-- translated label with a literal run of spaces, which only lined up in
-- English and collapsed entirely under CJK, where one character occupies two
-- display columns but three bytes.
-- ---------------------------------------------------------------------------

local function plural_unit(i18n, id, fallback_one, fallback_other, count)
    local value = i18n and i18n.t and i18n:t(id, { count = count })
    if value and value ~= id then return value end
    return tostring(count) .. " " .. (count == 1 and fallback_one or fallback_other)
end

local function cpu_identity_entries(snapshot, format, i18n)
    local cpu_info = snapshot.cpu_info or {}
    local identity = cpu_info.identity or {}
    local topology = cpu_info.topology or {}
    if not identity.model_name and not identity.vendor and not topology.threads then
        return {}
    end
    local entries = {
        entry("metrics.model", "Model", identity.model_name or "—", { emphasis = true }),
        entry("metrics.vendor", "Vendor", identity.vendor),
    }
    -- Apple silicon and some ARM hosts have no x86-style family triple.
    if identity.family or identity.model or identity.stepping then
        entries[#entries + 1] = entry("compute.family", "Family",
            string.format("%s / %s / %s", tostring(identity.family or "—"),
                tostring(identity.model or "—"), tostring(identity.stepping or "—")))
    end
    if topology.threads then
        entries[#entries + 1] = entry("compute.sockets", "Sockets",
            type(topology.sockets) == "number" and topology.sockets > 0
                and plural_unit(i18n, "compute.socket_count", "socket", "sockets", topology.sockets) or "—")
        entries[#entries + 1] = entry("compute.cores", "Physical cores",
            type(topology.physical_cores) == "number" and topology.physical_cores > 0
                and plural_unit(i18n, "compute.core_count", "core", "cores", topology.physical_cores) or "—")
        entries[#entries + 1] = entry("compute.threads", "Logical CPUs",
            plural_unit(i18n, "compute.thread_count", "thread", "threads", topology.threads or 0))
    end
    if identity.microcode then
        entries[#entries + 1] = entry("compute.microcode", "Microcode", identity.microcode)
    end
    local cpuid = cpu_info.cpuid
    if cpuid then
        entries[#entries + 1] = section("cpuid.title", "CPU capabilities")
        entries[#entries + 1] = entry("metrics.source", "Source", cpuid.source)
        entries[#entries + 1] = entry("inspector.status", "Status", Technical.state(i18n, cpuid.status))
        entries[#entries+1]=entry("inspector.quality","Quality",Technical.state(i18n,cpuid.quality))
        if cpuid.reason then
            entries[#entries + 1] = entry("inspector.reason", "Reason", Technical.reason(i18n, cpuid.reason))
        end
        if topology.compute_units then
            entries[#entries + 1] = entry("cpuid.compute_units", "Compute units", tostring(topology.compute_units))
        end
        if cpuid.os_comparison then
            entries[#entries+1]=entry("cpuid.topology_matches","Topology matches OS",cpuid.os_comparison.topology_matches==nil and "—" or (cpuid.os_comparison.topology_matches and translated(i18n,"ui.yes","yes")or translated(i18n,"ui.no","no")))
            entries[#entries+1]=entry("cpuid.cache_matches","Caches match OS",cpuid.os_comparison.cache_matches==nil and "—" or (cpuid.os_comparison.cache_matches and translated(i18n,"ui.yes","yes")or translated(i18n,"ui.no","no")))
        end
        for _,kind in ipairs(cpuid.core_types or{})do
            entries[#entries+1]={label=Technical.cpu_core_type(i18n,kind)..string.format(" (0x%02x)",kind.core_type),value=tostring(kind.logical_cpu_count).."T · "..kind.source}
        end
        for _, feature in ipairs(cpuid.features or {}) do
            if feature.name == "AVX" or feature.name == "AVX2" or feature.name == "AVX512F" then
                entries[#entries + 1] = { label = feature.name,
                    value = translated(i18n, "cpuid.hardware", "Hardware") .. " " .. feature.hardware_cpus
                        .. "/" .. feature.reported_cpus .. " · " .. translated(i18n, "cpuid.usable", "Usable")
                        .. " " .. feature.usable_cpus .. "/" .. feature.reported_cpus }
            end
        end
    end
    local caches = cpu_info.cache_summary or {}
    if #caches > 0 then
        entries[#entries + 1] = section("compute.cache_section", "Cache")
        for index = 1, math.min(8, #caches) do
            local cache = caches[index]
            entries[#entries + 1] = {
                label = tostring(cache.id or "?"),
                value = bytes(format, cache.total_size_bytes),
            }
        end
    end
    if identity.heterogeneous and #(cpu_info.core_types or {}) > 1 then
        entries[#entries + 1] = section("compute.core_types_section", "Core types")
        for index = 1, math.min(6, #cpu_info.core_types) do
            local core_type = cpu_info.core_types[index]
            local detail = core_type.logical_cpu_count and (tostring(core_type.logical_cpu_count) .. "T") or "—"
            if core_type.maximum_frequency_hz then
                detail = detail .. " · " .. frequency(format, core_type.maximum_frequency_hz)
            end
            local label = core_type.model_name or core_type.part
            if not label and core_type.efficiency_class ~= nil then
                label = tostring(core_type.efficiency_class) .. " · "
                    .. translated(i18n, "cpu.efficiency_class", "Efficiency class")
            end
            entries[#entries + 1] = {
                label = tostring(label or "CPU"),
                value = detail,
            }
        end
    end
    return entries
end

local function load_entries(snapshot, format, i18n)
    local load = snapshot.cpu and snapshot.cpu.load
    local system = snapshot.system or {}
    if not load then return {} end
    local threads = snapshot.cpu_info and snapshot.cpu_info.topology
        and snapshot.cpu_info.topology.threads
    local function load_token(value)
        if type(value) ~= "number" or not threads or threads <= 0 then return nil end
        return severity_token(value / threads * 100, 70, 100)
    end
    local entries = {
        { label = "1m", value = number(format, load.one, 2), token = load_token(load.one) },
        { label = "5m", value = number(format, load.five, 2), token = load_token(load.five) },
        { label = "15m", value = number(format, load.fifteen, 2), token = load_token(load.fifteen) },
        entry("metrics.running", "Running", snapshot.cpu and snapshot.cpu.processes_running),
        entry("metrics.blocked", "Blocked", snapshot.cpu and snapshot.cpu.processes_blocked),
    }
    if system.counters then
        entries[#entries + 1] = entry("system.context_switches", "Context switches",
            number(format, system.counters.ctxt))
        entries[#entries + 1] = entry("system.forks", "Forks since boot",
            number(format, system.counters.forks))
    end
    return entries
end

local function memory_detail_entries(snapshot, format)
    local memory = snapshot.memory
    if not memory or not memory.total_bytes then return {} end
    local function share(value)
        if type(value) ~= "number" or not memory.total_bytes or memory.total_bytes <= 0 then
            return bytes(format, value)
        end
        return string.format("%s  %.0f%%", bytes(format, value), value * 100 / memory.total_bytes)
    end
    return {
        entry("metrics.total", "Total", bytes(format, memory.total_bytes), { emphasis = true }),
        entry("metrics.used", "Used", share(memory.used_bytes),
            { token = severity_token(memory.used_bytes * 100 / memory.total_bytes, 80, 92) }),
        entry("metrics.available", "Available", share(memory.available_bytes)),
        entry("metrics.free", "Free", share(memory.free_bytes)),
        entry("metrics.cache", "Cache", share(memory.cache_bytes)),
        entry("metrics.buffers", "Buffers", share(memory.buffers_bytes)),
        entry("metrics.shared", "Shared", share(memory.shared_bytes)),
        entry("metrics.anonymous", "Anonymous", bytes(format, memory.anonymous_bytes)),
        entry("metrics.mapped", "Mapped", bytes(format, memory.mapped_bytes)),
        entry("metrics.slab", "Slab", bytes(format, memory.slab_bytes)),
        entry("metrics.page_tables", "Page tables", bytes(format, memory.page_tables_bytes)),
        entry("metrics.committed", "Committed", memory.committed_bytes
            and (bytes(format, memory.committed_bytes) .. " / "
                .. bytes(format, memory.commit_limit_bytes)) or "—"),
        entry("metrics.dirty", "Dirty", bytes(format, memory.dirty_bytes)),
        entry("metrics.writeback", "Writeback", bytes(format, memory.writeback_bytes)),
    }
end

local function swap_entries(snapshot, format)
    local memory = snapshot.memory or {}
    local system = snapshot.system or {}
    local total = memory.swap_total_bytes
    if type(total) ~= "number" or total <= 0 then
        return { entry("memory.no_swap", "Swap", "not configured") }
    end
    local used_percent = memory.swap_used_bytes * 100 / total
    local entries = {
        entry("metrics.total", "Total", bytes(format, total)),
        entry("metrics.used", "Used", string.format("%s  %.0f%%",
            bytes(format, memory.swap_used_bytes), used_percent),
            { token = severity_token(used_percent, 40, 75) }),
        entry("metrics.free", "Free", bytes(format, memory.swap_free_bytes)),
    }
    if memory.zswapped_bytes then
        entries[#entries + 1] = entry("metrics.zswap", "Zswap",
            bytes(format, memory.zswap_bytes) .. " / " .. bytes(format, memory.zswapped_bytes))
    end
    for index, device in ipairs(system.swap and system.swap.devices or {}) do
        if index == 1 then entries[#entries + 1] = section("memory.swap_devices", "Devices") end
        if index > 8 then break end
        entries[#entries + 1] = {
            label = tostring(device.name),
            value = string.format("%s / %s  %s", bytes(format, device.used_bytes),
                bytes(format, device.size_bytes), tostring(device.type or "")),
        }
    end
    return entries
end

local function paging_entries(snapshot, format)
    local vmstat = (snapshot.memory and snapshot.memory.vmstat)
        or (snapshot.system and snapshot.system.vmstat)
    if type(vmstat) ~= "table" then return {} end
    local function value(key) return number(format, vmstat[key]) end
    return {
        entry("memory.page_faults", "Page faults", value("pgfault")),
        entry("memory.major_faults", "Major faults", value("pgmajfault")),
        entry("memory.swap_in", "Swapped in", value("pswpin")),
        entry("memory.swap_out", "Swapped out", value("pswpout")),
        entry("memory.direct_reclaim", "Direct reclaim", value("pgscan_direct")),
        entry("memory.oom_kills", "OOM kills", value("oom_kill"),
            { token = (vmstat.oom_kill or 0) > 0 and "metric.critical" or nil }),
    }
end

local function host_entries(snapshot, format, i18n)
    local system = snapshot.system or {}
    if not system.host then return {} end
    local distribution = system.distribution or {}
    local entries = {
        entry("system.hostname", "Host", system.host.hostname, { emphasis = true }),
        entry("system.os", "OS", distribution.pretty_name or distribution.name),
        entry("system.kernel", "Kernel", system.kernel and system.kernel.release),
        entry("system.uptime", "Uptime", duration(format, system.uptime_seconds)),
    }
    local load = snapshot.cpu and snapshot.cpu.load
    if load then
        entries[#entries + 1] = entry("metrics.load", "Load",
            string.format("%s  %s  %s", number(format, load.one, 2),
                number(format, load.five, 2), number(format, load.fifteen, 2)))
    end
    if system.virtualization and system.virtualization.virtual then
        entries[#entries + 1] = entry("system.virtualization", "Virtualization",
            system.virtualization.technology or "yes")
    end
    return entries
end

local function system_identity_entries(snapshot, format, i18n)
    local system = snapshot.system or {}
    local distribution = system.distribution or {}
    local virtualization = system.virtualization or {}
    local entries = {
        section("system.host_section", "Host"),
        entry("system.hostname", "Hostname", system.host and system.host.hostname,
            { emphasis = true }),
        entry("system.domain", "Domain", system.host and system.host.domain),
        entry("system.architecture", "Architecture", system.host and system.host.architecture),
        entry("system.timezone", "Time zone", system.timezone),
        section("system.os_section", "Operating system"),
        entry("system.distribution", "Distribution",
            distribution.pretty_name or distribution.name),
        entry("system.version", "Version", distribution.version_id or distribution.version),
        entry("system.os_id", "Identifier", distribution.id),
        entry("system.build", "Build", distribution.build_id),
    }
    entries[#entries + 1] = section("system.environment_section", "Environment")
    entries[#entries + 1] = entry("system.virtualization", "Virtualization",
        virtualization.virtual and (virtualization.technology or "yes") or "bare metal")
    if virtualization.container then
        entries[#entries + 1] = entry("system.container", "Container",
            virtualization.container_technology or "yes")
    end
    for _, item in ipairs({
        { key = "selinux", id = "system.selinux", label = "SELinux" },
        { key = "apparmor", id = "system.apparmor", label = "AppArmor" },
        { key = "lockdown", id = "system.lockdown", label = "Lockdown" },
    }) do
        local value = system.security and system.security[item.key]
        if value then entries[#entries + 1] = entry(item.id, item.label, value) end
    end
    return entries
end

local function system_kernel_entries(snapshot, format, i18n)
    local system = snapshot.system or {}
    local kernel = system.kernel or {}
    local entries = {
        entry("system.kernel_type", "Kernel", kernel.type),
        entry("system.kernel_release", "Release", kernel.release, { emphasis = true }),
        entry("system.kernel_version", "Build", kernel.version),
        entry("system.uptime", "Uptime", duration(format, system.uptime_seconds)),
    }
    if system.boot_time_unix then
        entries[#entries + 1] = entry("system.boot_time", "Booted",
            formatted(function()
                return os.date("!%Y-%m-%d %H:%M:%S UTC", math.floor(system.boot_time_unix))
            end))
    end
    if system.idle_seconds and system.uptime_seconds and system.uptime_seconds > 0 then
        local threads = snapshot.cpu_info and snapshot.cpu_info.topology
            and snapshot.cpu_info.topology.threads or 1
        local busy = 100 - math.min(100,
            system.idle_seconds / (system.uptime_seconds * math.max(1, threads)) * 100)
        entries[#entries + 1] = entry("system.lifetime_busy", "Busy since boot",
            percent(format, busy))
    end
    if kernel.command_line then
        entries[#entries + 1] = section("system.cmdline_section", "Command line")
        entries[#entries + 1] = { label = "", value = kernel.command_line }
    end
    return entries
end

local function system_firmware_entries(snapshot, format, i18n)
    local system = snapshot.system or {}
    local firmware = system.firmware
    local entries
    if not firmware then
        entries = { entry("system.firmware_unavailable", "Firmware",
            translated(i18n, "system.dmi_unavailable", "DMI not exposed by this platform")) }
    else
        entries = {
            section("system.machine_section", "Machine"),
            entry("system.vendor", "Vendor", firmware.system_vendor),
            entry("system.product", "Product", firmware.product_name, { emphasis = true }),
            entry("system.product_version", "Version", firmware.product_version),
            entry("system.chassis", "Chassis", firmware.chassis_type),
            section("system.board_section", "Board"),
            entry("system.board_vendor", "Vendor", firmware.board_vendor),
            entry("system.board_name", "Model", firmware.board_name),
            entry("system.board_version", "Version", firmware.board_version),
            section("system.bios_section", "Firmware"),
            entry("system.bios_vendor", "Vendor", firmware.bios_vendor),
            entry("system.bios_version", "Version", firmware.bios_version),
            entry("system.bios_date", "Date", firmware.bios_date),
        }
    end
    local esrt = type(snapshot.firmware_esrt) == "table" and snapshot.firmware_esrt or {}
    local count = type(esrt.scanned) == "number" and esrt.scanned or 0
    if count > 0 then
        local denied = 0
        for _, resource in ipairs(esrt.entries or {}) do
            if resource.status == "denied" then denied = denied + 1 end
        end
        local summary = denied > 0
            and translated(i18n, "system.esrt_denied_count",
                "{count} · {denied} denied", { count = count, denied = denied })
            or translated(i18n, "system.esrt_count", "{count}", { count = count })
        table.insert(entries, 1, entry("system.esrt_resources", "UEFI resources", summary))
    end
    return entries
end

local function system_device_rows(snapshot, i18n, query)
    local inventory = type(snapshot.inventory) == "table" and snapshot.inventory or {}
    local pci = type(inventory.pci) == "table" and inventory.pci or {}
    local usb = type(inventory.usb) == "table" and inventory.usb or {}
    local pci_devices = type(pci.devices) == "table" and pci.devices or {}
    local usb_devices = type(usb.devices) == "table" and usb.devices or {}
    local graph = Hardware.build(snapshot)
    local function row_for(node)
        local device = node.device
        local class = (node.bus == "pci" or node.kind == "usb_interface")
            and device.class_id or device.product_id
        return {
            bus = node.bus:upper(),
            id = (node.bus == "slot" or node.bus == "firmware") and node.resource_id
                or node.bus == "usb" and type(device.bus) == "number"
                and type(device.device) == "number"
                and string.format("%d:%d", device.bus, device.device) or node.identifier,
            device = string.rep("  ", math.min(node.depth, 8)) .. Hardware.label(node, i18n),
            class = class and string.format(node.bus == "pci" and "%06x"
                or node.kind == "usb_interface" and "%02x" or "%04x", class) or "—",
        }
    end
    local included, direct, direct_count, cached = HardwareFilter.select(graph, query, row_for)
    local rows, ids, total, first_match_index = {}, {}, 0, nil
    for _, node in ipairs(graph.nodes) do
        if included == nil or included[node.id] then
            total = total + 1
            if #rows < TABLE_ROW_LIMIT then
                local row = cached and cached[node.id] or row_for(node)
                row.filter_match = direct and direct[node.id] or nil
                rows[#rows + 1] = row
                ids[#ids + 1] = node.id
                if direct and direct[node.id] and first_match_index == nil then
                    first_match_index = #rows
                end
            end
        end
    end
    local function bus_total(source, devices)
        local state = source.status
        local text
        if state == "denied" or state == "error" or state == "unavailable" then
            text = Technical.state(i18n, state)
        elseif source.total_known ~= false and type(source.total) == "number"
                and source.total >= 0 and source.total <= math.maxinteger and source.total % 1 == 0 then
            text = string.format("%d", source.total)
        else
            local seen = source.devices_seen or #devices
            if type(seen) == "number" and seen > 0 and seen <= math.maxinteger and seen % 1 == 0 then
                text = string.format("%d+", seen)
            else text = state == "partial" and Technical.state(i18n, state) or "—" end
        end
        if not Quality.current_source(snapshot.quality, "inventory") then
            text = text .. " (" .. Technical.state(i18n, "stale") .. ")"
        end
        return text
    end
    return rows, bus_total(pci, pci_devices), bus_total(usb, usb_devices),
        graph.truncated or graph.partial or total > #rows,
        ids, total, direct_count, first_match_index
end

local function system_limits_entries(snapshot, format, i18n)
    local system = snapshot.system or {}
    local limits = system.limits or {}
    local descriptors = limits.file_descriptors
    local entries = {}
    if descriptors then
        local used_percent = descriptors.maximum > 0
            and descriptors.open * 100 / descriptors.maximum or nil
        entries[#entries + 1] = entry("system.open_files", "Open descriptors",
            number(format, descriptors.open),
            { token = severity_token(used_percent, 70, 90) })
    end
    entries[#entries + 1] = entry("system.pid_max", "Maximum PID", number(format, limits.pid_max))
    entries[#entries + 1] = entry("system.threads_max", "Maximum threads",
        number(format, limits.threads_max))
    -- Modern kernels saturate at 256; anything well below that means the pool
    -- is being drained faster than it refills.
    entries[#entries + 1] = entry("system.entropy", "Entropy available",
        number(format, limits.entropy_available),
        { token = severity_below(limits.entropy_available, 128, 64) })
    local counters = system.counters or {}
    entries[#entries + 1] = section("system.counters_section", "Since boot")
    entries[#entries + 1] = entry("system.context_switches", "Context switches",
        number(format, counters.ctxt))
    entries[#entries + 1] = entry("system.interrupts", "Interrupts", number(format, counters.intr))
    entries[#entries + 1] = entry("system.forks", "Forks", number(format, counters.forks))
    entries[#entries + 1] = entry("system.procs_running", "Running now",
        number(format, counters.procs_running))
    entries[#entries + 1] = entry("system.procs_blocked", "Blocked now",
        number(format, counters.procs_blocked),
        { token = (counters.procs_blocked or 0) > 0 and "metric.warn" or nil })
    return entries
end

local function battery_items(snapshot, format, i18n)
    local supplies = snapshot.power_supplies or {}
    local items = {}
    for _, battery in ipairs(supplies.batteries or {}) do
        local absent = battery.present == false
        local detail = absent and translated(i18n, "system.absent", "absent")
            or (battery.capacity_percent
                and string.format("%.0f%%", battery.capacity_percent) or "—")
        items[#items + 1] = {
            label = battery.name,
            value = not absent and battery.capacity_percent or nil,
            display_value = detail,
            token = absent and "text.muted" or nil,
        }
    end
    for _, supply in ipairs(supplies.supplies or {}) do
        local online = supply.online
        local value
        if online ~= nil then value = online and 100 or 0 end
        local state = online == nil
            and translated(i18n, "system.unknown", "unknown")
            or online == false and translated(i18n, "system.offline", "offline")
            or supply.online_mode == "programmable"
                and translated(i18n, "system.online_programmable", "online (programmable)")
            or translated(i18n, "system.online", "online")
        items[#items + 1] = {
            label = supply.name,
            value = value,
            display_value = state,
            token = online and "metric.good" or "text.muted",
        }
    end
    return items
end

local function core_bar_items(snapshot, format)
    local items = {}
    for _, core in ipairs(snapshot.cpu and snapshot.cpu.cores or {}) do
        if #items >= 256 then break end
        items[#items + 1] = {
            label = (core.name or "cpu"):gsub("^cpu", ""),
            value = core.utilization,
            display_value = type(core.utilization) == "number"
                and string.format("%.0f%%", core.utilization) or "—",
        }
    end
    return items
end

local function memory_segment_model(snapshot, format, i18n)
    local memory = snapshot.memory
    if not memory or not memory.segments then return { segments = {} } end
    local labels = {
        used = { "metrics.used", "Used", "accent.primary" },
        shared = { "metrics.shared", "Shared", "chart.secondary" },
        buffers = { "metrics.buffers", "Buffers", "metric.warn" },
        cache = { "metrics.cache", "Cache", "metric.good" },
        free = { "metrics.free", "Free", "border.subtle" },
    }
    local segments = {}
    for _, segment in ipairs(memory.segments) do
        local label = labels[segment.id] or { nil, segment.id, "accent.primary" }
        segments[#segments + 1] = {
            id = segment.id,
            label_id = label[1],
            label = label[2],
            token = label[3],
            bytes = segment.bytes,
            display_value = bytes(format, segment.bytes),
            empty = segment.id == "free",
        }
    end
    return { segments = segments }
end

local function address_rows(snapshot)
    local rows = {}
    for _, interface in ipairs(snapshot.network and snapshot.network.interfaces or {}) do
        for _, address in ipairs(interface.addresses or {}) do
            if #rows >= TABLE_ROW_LIMIT then break end
            local route = interface.default_route
            rows[#rows + 1] = {
                interface = interface.name,
                family = address.family == "ipv6" and "IPv6" or "IPv4",
                address = address.address,
                netmask = address.netmask or "—",
                scope = address.peer and ("peer " .. address.peer)
                    or (address.broadcast and ("bcast " .. address.broadcast) or "—"),
                default_route = route and route.families
                    and (route.families[address.family] and "yes" or "—") or "—",
            }
        end
    end
    return rows
end

-- Which snapshot slot a collector's row reads.  A collector missing here is not
-- skipped: `collector_rows` looks the slot up, gets nil, and prints `ready` and
-- two em dashes for a collector that may be publishing `truncated` or a failure
-- reason.  Measured, this list had sixteen entries for seventeen registered
-- collectors and `inventory` was the one left out, so the device inventory row
-- could not show any of the states it actually has.  The relation is now a
-- property in `tests/unit/test_view_model_collectors.lua`: every registered
-- collector id must have a row whose reason is the reason of the slot that
-- collector writes, which fails both for a missing entry and for one pointing at
-- a neighbour's slot.
local COLLECTOR_RESOURCE = {
    cpu = "cpu", cpu_info = "cpu_info", memory = "memory", numa = "numa",
    memory_devices = "memory_devices", expansion_slots = "expansion_slots",
    port_connectors = "port_connectors",
    onboard_devices = "onboard_devices",
    firmware_batteries = "firmware_batteries",
    firmware_enclosures = "firmware_enclosures",
    platform_firmware = "platform_firmware",
    firmware_power_supplies = "firmware_power_supplies",
    firmware_bmcs = "firmware_bmcs",
    firmware_tpms = "firmware_tpms",
    firmware_components = "firmware_components",
    firmware_esrt = "firmware_esrt",
    tpm = "tpm",
    watchdog = "watchdog",
    rfkill = "rfkill",
    thermal_zones = "thermal_zones",
    host_interfaces = "host_interfaces",
    processor_firmware = "processor_firmware",
    edac = "edac", spd = "spd", thermal_throttle = "thermal_throttle", cpu_limits = "cpu_limits",
    cpu_clocks = "cpu_clocks",
    cpuidle = "cpuidle",
    pressure = "pressure",
    disk = "disks", disk_health = "disk_health", network = "network", wifi = "wifi", connections = "connections",
    process = "processes", gpu = "gpus", cpufreq = "cpu_frequency", hwmon = "sensors",
    powercap = "power", mounts = "mounts", cgroup = "workloads",
    system_info = "system", power_supply = "power_supplies", inventory = "inventory",
    displays = "displays",
}

local function collector_rows(snapshot, capabilities, i18n)
    local rows = {}
    local ids = {}
    for id in pairs(capabilities or {}) do
        if type(id) == "string" and id ~= "inspectors" then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local capability = capabilities[id]
        if type(capability) == "table" then
            local resource = COLLECTOR_RESOURCE[id]
            local state = resource and snapshot.quality and snapshot.quality[resource]
            local source = capability.source or (capability.details and capability.details.source)
            if type(source) == "table" then source = source[1] end
            rows[#rows + 1] = {
                collector = id,
                available = capability.available == true,
                status = capability.available and (state and state.status or "ready")
                    or (capability.state or "unavailable"),
                quality = state and state.quality or "—",
                reason = capability.reason or (state and state.reason) or "—",
                source = source and tostring(source) or "—",
            }
        end
    end
    return rows
end

local function inspector_rows(capabilities, i18n)
    local rows = {}
    local inspectors = capabilities and capabilities.inspectors or {}
    local ids = {}
    for id in pairs(inspectors) do ids[#ids + 1] = tostring(id) end
    table.sort(ids)
    local keys = {
        ["storage.smart"] = { "s", "inspector.smart", "SMART / NVMe health" },
        ["memory.bandwidth"] = { "b", "inspector.ram_bandwidth", "RAM bandwidth (PMU)" },
        ["service.sshd"] = { "D", "inspector.sshd", "sshd service and listeners" },
        ["service.systemd"] = { "d", "inspector.systemd", "systemd units" },
    }
    for _, id in ipairs(ids) do
        local capability = inspectors[id]
        local meta = keys[id] or { "", nil, id }
        rows[#rows + 1] = {
            inspector = meta[2] and translated(i18n, meta[2], meta[3]) or id,
            key = meta[1],
            status = type(capability) == "table"
                and (capability.available and "ready" or (capability.state or "unavailable"))
                or tostring(capability),
            available = type(capability) == "table" and capability.available == true,
            reason = type(capability) == "table"
                and (capability.reason or "—") or "—",
        }
    end
    return rows
end

-- Turn capability gaps into something the operator can act on.  "GPU:
-- unavailable" is a fact; "install smartctl to read disk health" is a next
-- step, and that is what this page previously failed to provide.
local ADVICE_RULES = {
    { collector = "gpus", id = "advice.gpu",
      text = "No DRM GPU exposed. Inside a VM or on a headless host this is expected." },
    { collector = "cpu_frequency", id = "advice.cpufreq",
      text = "cpufreq is absent: the platform does not export scaling policies." },
    { collector = "sensors", id = "advice.hwmon",
      text = "No hwmon sensors. Temperature and fan data need platform driver support." },
    { collector = "power", id = "advice.powercap",
      text = "RAPL/powercap is unavailable, so CPU package power cannot be read." },
}

local function advice_entries(snapshot, capabilities, i18n, privilege, linux_host)
    local entries = {}
    local denied = {}
    for resource, state in pairs(snapshot.quality or {}) do
        if state.status == "denied" then denied[#denied + 1] = resource end
    end
    table.sort(denied)
    if #denied > 0 then
        entries[#entries + 1] = section("advice.permissions", "Permissions")
        entries[#entries + 1] = {
            label = table.concat(denied, ", "),
            value = linux_host and translated(i18n, "advice.denied",
                "denied; run with sudo for full visibility")
                or translated(i18n, "status.denied", "Denied"),
            token = "metric.warn",
        }
    end
    local gaps = {}
    for _, rule in ipairs(ADVICE_RULES) do
        local state = snapshot.quality and snapshot.quality[rule.collector]
        if not state or state.status == "unavailable" then
            gaps[#gaps + 1] = { rule = rule }
        end
    end
    if #gaps > 0 then
        entries[#entries + 1] = section("advice.gaps", "Unavailable sources")
        for _, gap in ipairs(gaps) do
            entries[#entries + 1] = {
                label = gap.rule.collector,
                value = linux_host and translated(i18n, gap.rule.id, gap.rule.text)
                    or translated(i18n, "status.unavailable", "Unavailable"),
                token = "text.muted",
            }
        end
    end
    local inspectors = capabilities and capabilities.inspectors or {}
    local missing = {}
    for id, capability in pairs(inspectors) do
        if type(capability) == "table" and capability.available ~= true then
            missing[#missing + 1] = tostring(id)
        end
    end
    table.sort(missing)
    if #missing > 0 then
        entries[#entries + 1] = section("advice.inspectors", "Deep inspectors")
        for _, id in ipairs(missing) do
            entries[#entries + 1] = {
                label = id,
                value = translated(i18n, "advice.inspector_missing",
                    "helper not found or not permitted"),
                token = "text.muted",
            }
        end
    end
    if #entries == 0 then
        entries[#entries + 1] = {
            label = translated(i18n, "advice.all_good", "All configured sources are reporting"),
            value = "",
            token = "metric.good",
        }
    end
    if linux_host and privilege and privilege.root ~= true then
        entries[#entries + 1] = section("advice.hint_section", "Hints")
        entries[#entries + 1] = {
            label = translated(i18n, "advice.elevate", "Elevated collection"),
            value = translated(i18n, "advice.elevate_hint",
                "wtop --sudo re-runs with root for SMART and per-process I/O"),
        }
    end
    return entries
end

-- Windows service hosts and macOS resource coalitions fill the Workloads
-- page where Linux has cgroups; their labels name what is actually grouped.
local WORKLOAD_KINDS = {
    service = {
        title = { "widgets.services", "Windows services" },
        nodes = { "workloads.service_hosts", "Service host processes" },
        processes = { "workloads.running_services", "Running services" },
        partial = { "workloads.unreadable_hosts", "Unreadable hosts" },
        root = { "workloads.all_services", "All services" },
        reason = { "workloads.service_partial_reason",
            "Some service processes belong to other accounts and are readable only as administrator." },
    },
    coalition = {
        title = { "widgets.app_groups", "Applications and their helpers" },
        nodes = { "workloads.app_groups", "Application groups" },
        processes = { "workloads.processes", "Visible processes" },
        partial = { "workloads.unreadable_groups", "Partly unreadable groups" },
        root = { "workloads.all_groups", "All groups" },
        reason = { "workloads.coalition_partial_reason",
            "Processes of other users are readable only with sudo." },
    },
}

-- The identity the cgroup path encodes: the systemd unit, and the container,
-- pod or login session it belongs to.  Only fields the path actually
-- established appear, so an ordinary service shows a unit and nothing else.
local function workload_identity_entries(semantics)
    if type(semantics) ~= "table" then return {} end
    local entries = {}
    if semantics.unit and semantics.unit ~= semantics.label then
        entries[#entries + 1] = entry("workloads.selection_unit", "Unit", semantics.unit)
    end
    if semantics.container_id then
        -- The full id is already in the path row above, so the value keeps the
        -- readable form: the runtime when the path named one, the short id
        -- alone when it did not.
        local container = semantics.runtime
            and (semantics.runtime .. " " .. semantics.container_short_id)
            or semantics.container_short_id
        entries[#entries + 1] = entry("workloads.selection_container", "Container", container)
    end
    if semantics.pod then
        entries[#entries + 1] = entry("workloads.selection_pod", "Pod", semantics.pod)
    end
    if semantics.user_id then
        entries[#entries + 1] = entry("workloads.selection_user", "Login session",
            "user-" .. tostring(semantics.user_id))
    end
    return entries
end

local function workload_selected_entries(selected, format, i18n)
    local io_rates = selected.io and selected.io.totals
        and selected.io.totals.rates or {}
    local cpu_pressure = selected.pressure and selected.pressure.cpu
    local entries = {
        section("workloads.selection_section", "Selection"),
        entry("workloads.selection_name", "Workload",
            workload_row_name(selected), { emphasis = true }),
        entry("workloads.selection_path", "Path", selected.path or selected.id),
    }
    for _, identity in ipairs(workload_identity_entries(selected.semantics)) do
        entries[#entries + 1] = identity
    end
    for _, metric in ipairs({
        entry("metrics.cpu", "CPU",
            percent(format, selected.cpu and selected.cpu.utilization_percent)),
        entry("metrics.memory", "Memory",
            bytes(format, selected.memory and selected.memory.current_bytes)),
        entry("metrics.read", "Read", rate(format, io_rates.rbytes_per_second)),
        entry("metrics.write", "Write", rate(format, io_rates.wbytes_per_second)),
        entry("metrics.processes", "Processes",
            number(format, selected.processes and selected.processes.count)),
        entry("metrics.pressure", "Pressure",
            percent(format, cpu_pressure and cpu_pressure.some
                and cpu_pressure.some.avg10)),
        entry("inspector.quality", "Quality", Technical.state(i18n, selected.quality)),
    }) do
        entries[#entries + 1] = metric
    end
    if selected.cgroup_type == "threaded" then
        entries[#entries + 1] = entry("workloads.threaded_group", "Group type",
            translated(i18n, "workloads.threaded_subgroup", "Threaded subgroup"))
        entries[#entries + 1] = entry("workloads.threads", "Threads",
            number(format, selected.threads and selected.threads.count))
    end
    if selected.processes and (selected.processes.hidden_entries or 0) > 0 then
        entries[#entries + 1] = entry("workloads.unmapped_pid_entries",
            "Unmapped PID entries", number(format, selected.processes.hidden_entries))
    end
    if selected.threads and (selected.threads.hidden_entries or 0) > 0 then
        entries[#entries + 1] = entry("workloads.unmapped_tid_entries",
            "Unmapped TID entries", number(format, selected.threads.hidden_entries))
    end
    return entries
end

local function workload_detail_entries(snapshot, format, i18n, selected)
    if selected ~= nil then return workload_selected_entries(selected, format, i18n) end
    local summary = snapshot.workloads and snapshot.workloads.summary
    if not summary then return {} end
    local root = summary.root or {}
    local kind = WORKLOAD_KINDS[snapshot.workloads.kind]
    if kind then
        local processes = snapshot.workloads.kind == "service"
            and (snapshot.workloads.running_services or 0) or (summary.visible_process_count or 0)
        local entries = {
            entry(kind.nodes[1], kind.nodes[2], math.max(0, (summary.node_count or 1) - 1)),
            entry(kind.processes[1], kind.processes[2], processes),
            entry(kind.partial[1], kind.partial[2], summary.partial_node_count or 0,
                { token = (summary.partial_node_count or 0) > 0 and "metric.warn" or nil }),
            section(kind.root[1], kind.root[2]),
            entry("metrics.cpu", "CPU", percent(format, root.cpu_utilization_percent)),
            entry("metrics.memory", "Memory", bytes(format, root.memory_current_bytes)),
        }
        if (summary.unknown_process_nodes or 0) > 0 then
            entries[#entries + 1] = entry("workloads.unknown_process_nodes",
                "Groups without process counts", summary.unknown_process_nodes)
        end
        if (summary.partial_node_count or 0) > 0 then
            entries[#entries + 1] = section("workloads.why_section", "Why partial")
            entries[#entries + 1] = {
                label = "",
                value = translated(i18n, kind.reason[1], kind.reason[2]),
                token = "text.muted",
            }
        end
        return entries
    end
    local entries = {
        entry("workloads.nodes", "Visible cgroups", summary.node_count or 0),
        entry("workloads.processes", "Visible processes", summary.visible_process_count or 0),
        entry("workloads.partial", "Partial cgroups", summary.partial_node_count or 0,
            { token = (summary.partial_node_count or 0) > 0 and "metric.warn" or nil }),
    }
    if (summary.unknown_process_nodes or 0) > 0 then
        entries[#entries + 1] = entry("workloads.unknown_process_nodes",
            "Groups without process counts", summary.unknown_process_nodes)
    end
    -- What the tree is made of, counted only where the path establishes it: a
    -- container's own children are not extra containers, and a cgroupfs pod
    -- that never named its runtime is still a pod.
    for _, count in ipairs({
        { "workloads.services", "Service units", summary.service_count },
        { "workloads.containers", "Containers", summary.container_count },
        { "workloads.pods", "Pods", summary.pod_count },
        { "workloads.user_sessions", "Login sessions", summary.user_session_count },
    }) do
        if (count[3] or 0) > 0 then
            entries[#entries + 1] = entry(count[1], count[2], count[3])
        end
    end
    entries[#entries + 1] = section("workloads.root_section", "Root cgroup")
    entries[#entries + 1] = entry("metrics.cpu", "CPU",
        percent(format, root.cpu_utilization_percent))
    entries[#entries + 1] = entry("metrics.memory", "Memory",
        bytes(format, root.memory_current_bytes))
    if (summary.partial_node_count or 0) > 0 then
        entries[#entries + 1] = section("workloads.why_section", "Why partial")
        entries[#entries + 1] = {
            label = "",
            value = translated(i18n, "workloads.partial_reason",
                "A control file the kernel created could not be read as this user."),
            token = "text.muted",
        }
    end
    return entries
end

local function disk_columns(i18n, rows)
    local columns = {
        { key = "device", label = translated(i18n, "metrics.device", "Device"), width = 12, min_width = 8, priority = 95 },
        { key = "model", label = translated(i18n, "metrics.model", "Model"), width = 20, min_width = 10, priority = 40, full_only = true },
        { key = "size", label = translated(i18n, "metrics.capacity", "Size"), width = 10, min_width = 8, align = "right", priority = 55 },
        { key = "medium", label = translated(i18n, "metrics.medium", "Type"), width = 5, min_width = 4, priority = 30, full_only = true },
        { key = "temperature", label = translated(i18n, "metrics.temperature", "Temp"), width = 9, min_width = 7, align = "right", priority = 60,
            token = function(_, row)
                return row.temperature_source and severity_token(
                    row.temperature_source.input, 55, 65) or nil
            end },
        { key = "read", label = translated(i18n, "metrics.read", "Read"), width = 12, min_width = 10, align = "right", priority = 90 },
        { key = "write", label = translated(i18n, "metrics.write", "Write"), width = 12, min_width = 10, align = "right", priority = 88 },
        { key = "busy", label = translated(i18n, "metrics.busy", "Busy"), width = 9, min_width = 7, align = "right", priority = 70,
            token = function(_, row) return severity_token(row.busy_value, 60, 85) end,
            bar = function(_, row)
                return row.busy_value and math.min(1, row.busy_value / 100) or nil
            end },
        { key = "queue", label = translated(i18n, "metrics.queue", "Queue"), width = 7, min_width = 6, align = "right", priority = 25, full_only = true },
        { key = "latency", label = translated(i18n, "metrics.read_latency", "Read latency"), width = 13, min_width = 10, align = "right", priority = 35, full_only = true },
    }
    for _, row in ipairs(rows) do
        if row.critical ~= "—" then
            columns[#columns + 1] = { key = "critical",
                label = translated(i18n, "sensor.critical", "Critical"),
                width = 12, min_width = 8, align = "right", priority = 50 }
            columns[#columns + 1] = { key = "thermal_headroom",
                label = translated(i18n, "sensor.headroom", "To critical"),
                width = 14, min_width = 9, align = "right", priority = 52 }
            break
        end
    end
    return columns
end

local function smart_hint_entries(snapshot, capabilities, i18n)
    local inspectors = capabilities and capabilities.inspectors or {}
    local smart = inspectors["storage.smart"]
    local available = type(smart) == "table" and smart.available == true
    local windows = smart and smart.source == "Windows storage queries"
    return {
        entry("storage.smart_key", "Inspect", translated(i18n, "storage.smart_hint_short",
            "press s to choose a device")),
        entry("inspector.status", "Status", available
            and translated(i18n, "inspector.ready", "ready")
            or (windows and Technical.state(i18n, "unavailable")
                or translated(i18n, "inspector.helper_missing", "smartctl not available")),
            { token = available and "metric.good" or "metric.warn" }),
        { label = "", value = windows and translated(i18n, "storage.windows_probe",
            "NVMe monitoring is read-only; selecting an ATA disk reads its SMART data.")
            or translated(i18n, "storage.smart_standby",
                "Read-only probes are lazy; standby disks are not awakened."),
          token = "text.muted" },
    }
end

local function process_table_model(i18n, process_rows, process_status,
        process_status_display, platform)
    return {
        panel_title = translated(i18n, "widgets.processes_sorted",
            "Processes · {sort} {direction}", {
                sort = process_sort_label(i18n, process_status.sort_key),
                direction = translated(i18n, process_status.descending
                    and "process.direction.descending" or "process.direction.ascending",
                    process_status.descending and "descending" or "ascending"),
            }),
        columns = ordered_process_columns(process_status.columns, i18n, process_status, platform),
        rows = process_rows,
        highlights = process_status.query_highlights,
        selected = process_status.selected_index,
        sort_key = process_status.sort_key,
        sort_descending = process_status.descending,
        status = process_status,
        status_text = process_status_display,
    }
end

function M.build(engine, snapshot, i18n, capabilities, active_tab, process_controller,
        visible_widgets, options)
    options = options or {}
    local format = i18n.format
    local kernel_type = snapshot.system and snapshot.system.kernel
        and snapshot.system.kernel.type
    local platform = options.platform or kernel_type
    local linux_host = (platform or "Linux") == "Linux"
    local function visible(widget_id)
        return type(visible_widgets) ~= "table" or visible_widgets[widget_id] == true
    end
    local function on(tab, widget_id)
        return (not active_tab or active_tab == tab
            or type(active_tab) == "string" and active_tab:match("^custom[1-8]$"))
            and visible(widget_id)
    end
    local function process_view()
        if on("processes", "process_table") then
            process_controller = process_controller or ProcessTable.new()
            return top_processes(snapshot, format, process_controller, i18n, platform)
        end
        local status = process_controller and process_controller:status()
            or ProcessTable.new():status()
        return {}, status, process_status_text(i18n, status)
    end
    if active_tab == "processes" then
        -- This page contains only the process table. Avoid building models for
        -- the other pages on every process refresh.
        local rows, status, status_display = process_view()
        return { process_table = process_table_model(i18n, rows, status,
            status_display, platform) }
    end

    local cpu_value = snapshot.cpu and snapshot.cpu.total and snapshot.cpu.total.utilization
    local memory_value
    if snapshot.memory and snapshot.memory.total_bytes and snapshot.memory.total_bytes > 0 then
        memory_value = snapshot.memory.used_bytes * 100 / snapshot.memory.total_bytes
    end
    local swap_value
    if snapshot.memory and snapshot.memory.swap_total_bytes
        and snapshot.memory.swap_total_bytes > 0 then
        swap_value = snapshot.memory.swap_used_bytes * 100 / snapshot.memory.swap_total_bytes
    end
    local pressure = Engine.pressure_value(snapshot.pressure)
    local memory_pressure = snapshot.pressure and snapshot.pressure.memory
        and snapshot.pressure.memory.some and snapshot.pressure.memory.some.avg10
    local io_pressure = snapshot.pressure and snapshot.pressure.io
        and snapshot.pressure.io.some and snapshot.pressure.io.some.avg10
    local disk_read = Engine.sum_devices(snapshot.disks and snapshot.disks.devices, "read_bytes_per_second")
    local disk_write = Engine.sum_devices(snapshot.disks and snapshot.disks.devices, "write_bytes_per_second")
    local network_receive = Engine.sum_interfaces(snapshot.network and snapshot.network.interfaces, "rx_bytes_per_second")
    local network_transmit = Engine.sum_interfaces(snapshot.network and snapshot.network.interfaces, "tx_bytes_per_second")
    local gpu_devices = snapshot.gpus and snapshot.gpus.devices or {}
    local first_gpu = gpu_devices[1] and gpu_devices[1].metrics or {}
    local process_count = snapshot.processes and snapshot.processes.process_candidates
        or #(snapshot.processes and snapshot.processes.list or {})

    local process_rows, process_status, process_status_display = process_view()

    local cores = on("compute", "core_table") and core_rows(snapshot, format, i18n) or {}
    local core_items = {}
    if on("compute", "core_bars") or on("overview", "core_overview") then
        core_items = core_bar_items(snapshot, format)
    end
    local disks, disks_hidden = {}, 0
    if on("storage", "disk_table") then
        disks, disks_hidden = disk_rows(snapshot, format,
            { show_virtual = options.show_virtual_devices, i18n = i18n })
    end
    local interfaces = on("network", "network_table") and network_rows(snapshot, format) or {}
    local system_devices_rows, system_pci_total, system_usb_total, system_devices_truncated
    local system_device_ids, system_device_selected = {}, 1
    local system_device_total, system_device_matches = 0, 0
    local system_query = type(options.system_query) == "string"
        and options.system_query:match("^%s*(.-)%s*$") or ""
    if on("system", "system_devices") then
        system_devices_rows, system_pci_total, system_usb_total,
            system_devices_truncated, system_device_ids, system_device_total,
            system_device_matches, system_device_selected =
            system_device_rows(snapshot, i18n, system_query)
        if system_query == "" then system_device_selected = 1 end
        for index, id in ipairs(system_device_ids) do
            if id == options.system_selected then system_device_selected = index break end
        end
    else
        system_devices_rows = {}
    end
    local dimm_rows, dimm_ids, dimm_selected = {}, {}, 1
    local memory_device_state = snapshot.quality and snapshot.quality.memory_devices
        or capabilities and capabilities.memory_devices
    local dimm_empty = translated(i18n, "memory_hw.no_devices", "No memory devices exposed")
    if memory_device_state and (memory_device_state.status == "denied" or memory_device_state.state == "denied") then
        dimm_empty = translated(i18n, "status.denied", "Denied") .. " · SMBIOS"
    elseif memory_device_state and memory_device_state.reason then
        dimm_empty = Technical.reason(i18n, memory_device_state.reason)
    end
    if on("memory", "dimm_table") then
        for index, device in ipairs(snapshot.memory_devices and snapshot.memory_devices.devices or {}) do
            if index > 256 then break end
            dimm_ids[index] = "dimm:" .. device.id
            if options.system_selected == dimm_ids[index] then dimm_selected = index end
            dimm_rows[index] = { id = device.id, slot = device.locator or ("0x" .. device.id),
                size = device.populated == false and translated(i18n, "memory_hw.empty", "Empty")
                    or bytes(format, device.size_bytes),
                type = device.logical and translated(i18n, "memory_hw.logical", "Logical") or device.memory_type or "—",
                manufacturer = device.manufacturer or "—",
                speed = device.configured_speed_mts and number(format, device.configured_speed_mts) .. " MT/s" or "—",
                state = memory_device_state and memory_device_state.status ~= "ok"
                    and memory_device_state.quality or device.quality,
            }
        end
    end
    local numa_rows, numa_ids, numa_selected = {}, {}, 1
    if on("memory", "numa_table") then
        for index, node in ipairs(snapshot.numa and snapshot.numa.nodes or {}) do
            if index > 128 then break end
            local memory = node.memory or {}
            local allocation_rates = node.allocations and node.allocations.rates or {}
            local state = snapshot.quality and snapshot.quality.numa
            numa_ids[#numa_ids + 1] = "numa:" .. node.id
            if options.system_selected == numa_ids[#numa_ids] then numa_selected = index end
            numa_rows[#numa_rows + 1] = {
                node = tostring(node.id), cpus = node.cpu_ids and tostring(#node.cpu_ids) or "—",
                total = bytes(format, memory.total_bytes), free = bytes(format, memory.free_bytes),
                other_rate = number(format, allocation_rates.other_pages_per_second, 1),
                state = state and state.status ~= "ok" and state.quality or node.quality,
            }
        end
    end
    local connections, matching_connections = {}, 0
    local owner_target = type(options.connection_owner_target) == "table"
        and options.connection_owner_target or nil
    local owner_scan = snapshot.connections and snapshot.connections.owner_scan or {}
    local owner_quality = snapshot.quality and snapshot.quality.connections or {}
    local requested_ns = owner_target and type(owner_target.requested_ns) == "number"
        and owner_target.requested_ns or math.huge
    local attempted = owner_target and type(owner_quality.timestamp_ns) == "number"
        and owner_quality.timestamp_ns >= requested_ns
        and (not owner_target.prior_quality
            or owner_quality ~= owner_target.prior_quality)
    local target_seen = attempted and owner_quality.status == "ok"
        and owner_scan.target_id == owner_target.id
    local target_status = target_seen and owner_scan.target_status
        or attempted and owner_quality.status ~= "ok" and owner_quality.status
        or "loading"
    local target_usable = target_seen
        and (target_status == "ok" or target_status == "partial")
    if on("network", "connection_table") then
        if not owner_target or target_usable then
            connections, matching_connections = connection_rows(snapshot,
                options.mask_remote_addresses == true, options.connection_query,
                owner_target and owner_target.id)
        end
    end
    local connection_ids, connection_selected_index = {}, nil
    for index, row in ipairs(connections) do
        connection_ids[index] = row.connection_ref.id
        if options.connection_selected == row.connection_ref.id then
            connection_selected_index = index
        end
    end
    if connection_selected_index == nil and #connection_ids > 0 then
        connection_selected_index = 1
    end
    local addresses = on("network", "address_table") and address_rows(snapshot) or {}
    local gpu_table_rows = on("gpu", "gpu_table") and gpu_rows(snapshot, format, i18n) or {}
    local gpu_has_power, gpu_has_cap, gpu_has_frequency, gpu_has_limits = false, false, false, false
    for _, row in ipairs(gpu_table_rows) do
        gpu_has_power = gpu_has_power or row.power ~= "—"
        gpu_has_cap = gpu_has_cap or row.power_limit ~= "—"
        gpu_has_frequency = gpu_has_frequency or row.frequency ~= "—"
        gpu_has_limits = gpu_has_limits or row.limits ~= "—"
    end
    local gpu_process_table_rows, gpu_process_total = {}, 0
    local gpu_process_table_ids, gpu_process_selected_index = {}, nil
    if on("gpu", "gpu_process_table") then
        gpu_process_table_rows, gpu_process_total = gpu_process_rows(snapshot, format)
        for index, row in ipairs(gpu_process_table_rows) do
            gpu_process_table_ids[index] = row.pid_number
            if options.gpu_selected == row.pid_number then
                gpu_process_selected_index = index
            end
        end
    end
    local cpufreq_table_rows = on("compute", "cpufreq_table")
        and cpufreq_rows(snapshot, format, i18n) or {}
    local thermal_throttle_table_rows = on("compute", "thermal_throttle_table")
        and thermal_throttle_rows(snapshot, format) or {}
    local cpuidle_table_rows, cpuidle_table_total = {}, 0
    if on("compute", "cpuidle_table") then
        cpuidle_table_rows, cpuidle_table_total = cpuidle_rows(snapshot, format, i18n)
    end
    local sensor_table_rows = on("compute", "sensor_table") and sensor_rows(snapshot, format) or {}
    local power_table_rows, power_table_total = {}, 0
    if on("compute", "power_table") then
        power_table_rows, power_table_total = power_rows(snapshot, format, i18n)
    end
    local mount_table_rows, mounts_hidden, mounts_total, mounts_matching = {}, 0, 0, 0
    if on("storage", "mount_table") then
        mount_table_rows, mounts_hidden, mounts_total, mounts_matching =
            mount_rows(snapshot, format,
                { show_pseudo = options.show_pseudo_filesystems,
                  query = options.mount_query })
    end
    local workload_table_rows, workload_row_ids, workload_selected_index,
        workloads_total, workload_matches = {}, {}, nil, 0, 0
    if on("workloads", "workload_table") then
        workload_table_rows, workload_row_ids, workload_selected_index,
            workloads_total, workload_matches =
            workload_rows(snapshot, format,
                type(options.workload_collapsed) == "table"
                    and options.workload_collapsed or nil,
                options.workload_selected, options.workload_query)
    end
    local workload_query = type(options.workload_query) == "string"
        and options.workload_query:match("^%s*(.-)%s*$") or ""
    local effective_workload_id = options.workload_selected
    if workload_query ~= "" then
        effective_workload_id = workload_selected_index
            and workload_row_ids[workload_selected_index] or nil
    end
    local workload_selected = effective_workload_id ~= nil
        and workload_by_id(snapshot)[effective_workload_id] or nil

    -- A table that stopped at the model's row cap must say so: an absent row
    -- is otherwise indistinguishable from an object that does not exist.
    local mount_query = type(options.mount_query) == "string"
        and options.mount_query:match("^%s*(.-)%s*$") or ""
    local mount_status_text = mount_query ~= "" and translated(i18n,
        "storage.mount_filter_status",
        "{visible}/{matching} mounts · Filter: {query} · Esc clears", {
            visible = #mount_table_rows, matching = mounts_matching,
            query = mount_query,
        }) or #mount_table_rows < mounts_total
            and translated(i18n, "ui.rows_capped", "showing {visible} of {total}",
                { visible = #mount_table_rows, total = mounts_total }) or nil
    if mounts_hidden > 0 then
        local hidden_note = translated(i18n, "storage.hidden_mounts",
            "{count} pseudo filesystems hidden", { count = mounts_hidden })
        if mount_query ~= "" and mount_status_text then
            mount_status_text = mount_status_text .. " · " .. hidden_note
        else
            mount_status_text = mount_status_text
                and hidden_note .. " · " .. mount_status_text or hidden_note
        end
    end
    local workload_status_text = workload_query ~= ""
        and translated(i18n, "workloads.filter_status",
            "{matches} matches · {visible}/{total} rows · Filter: {query} · Esc clears", {
                matches = workload_matches, visible = #workload_table_rows,
                total = workloads_total, query = workload_query,
            })
        or #workload_table_rows < workloads_total
            and translated(i18n, "ui.rows_capped", "showing {visible} of {total}",
                { visible = #workload_table_rows, total = workloads_total }) or nil

    local average_frequency = Engine.average_cpu_frequency(snapshot.cpu_frequency)
    local maximum_temperature = Engine.maximum_temperature(snapshot.sensors)
    local cpu_power = snapshot.power and snapshot.power.total_power_watts
    local power_budgets = on("overview", "power_overview")
        and overview_power_budgets(snapshot, format, i18n) or nil
    local graphics_power, graphics_power_compact
    if on("gpu", "gpu_summary") then
        graphics_power, graphics_power_compact = graphics_power_summary(snapshot, format, i18n)
    end
    local workload_root = snapshot.workloads and snapshot.workloads.summary
        and snapshot.workloads.summary.root
    local battery_summary = snapshot.power_supplies and snapshot.power_supplies.summary

    local percent_axis = function(value) return string.format("%d%%", math.floor(value + 0.5)) end
    local rate_axis = function(value) return rate(format, value) end

    local function history(key) return engine:history_values(key) end

    local limit_text, limit_compact
    if on("overview", "cpu_overview") then limit_text, limit_compact = cpu_limit_overview_text(snapshot, i18n) end

    local models = {
        -- Overview -------------------------------------------------------
        cpu_overview = {
            secondary_value = limit_text,
            secondary_values = limit_compact and { limit_compact } or nil,
            label = translated(i18n, "metrics.cpu", "CPU"),
            value = cpu_value,
            display_value = percent(format, cpu_value),
            history = history("cpu"),
            quality = quality(snapshot, "cpu"), min = 0, max = 100,
            thresholds = { warn = 70, critical = 90 },
            axis_format = percent_axis,
        },
        memory_overview = {
            label = translated(i18n, "metrics.memory", "Memory"),
            value = memory_value,
            display_value = percent(format, memory_value),
            secondary_value = snapshot.memory and bytes(format, snapshot.memory.used_bytes)
                .. " / " .. bytes(format, snapshot.memory.total_bytes) or nil,
            history = history("memory"),
            quality = quality(snapshot, "memory"), min = 0, max = 100,
            thresholds = { warn = 80, critical = 92 },
            axis_format = percent_axis,
        },
        host_overview = { entries = host_entries(snapshot, format, i18n) },
        core_overview = {
            items = core_items, min = 0, max = 100,
            thresholds = { warn = 70, critical = 90 },
        },
        pressure_overview = {
            label = translated(i18n, "metrics.pressure", "Pressure"),
            value = pressure,
            display_value = percent(format, pressure),
            history = history("pressure"),
            quality = quality(snapshot, "pressure"), min = 0, max = 100,
            thresholds = { warn = 10, critical = 40 },
            axis_format = percent_axis,
        },
        disk_overview = {
            label = translated(i18n, "metrics.disk_io", "Disk I/O"),
            display_value = "↓ " .. rate(format, disk_read) .. "  ↑ " .. rate(format, disk_write),
            history = history("disk_read"), quality = quality(snapshot, "disks"),
            axis_format = rate_axis,
        },
        network_overview = {
            label = translated(i18n, "metrics.network_io", "Network I/O"),
            display_value = "↓ " .. rate(format, network_receive) .. "  ↑ " .. rate(format, network_transmit),
            history = history("network_receive"), quality = quality(snapshot, "network"),
            axis_format = rate_axis,
        },
        gpu_overview = {
            label = translated(i18n, "metrics.gpu", "GPU"),
            value = first_gpu.utilization_percent,
            display_value = #gpu_devices == 0 and translated(i18n, "ui.no_data", "No data")
                or percent(format, first_gpu.utilization_percent),
            history = history("gpu"), quality = quality(snapshot, "gpus"), min = 0, max = 100,
            thresholds = { warn = 70, critical = 90 },
            axis_format = percent_axis,
        },
        frequency_overview = {
            label = translated(i18n, "metrics.frequency", "Frequency"),
            display_value = frequency(format, average_frequency),
            history = history("cpu_frequency"), quality = quality(snapshot, "cpu_frequency"),
            axis_format = function(value) return frequency(format, value) end,
        },
        temperature_overview = {
            label = translated(i18n, "metrics.temperature", "Temperature"),
            value = maximum_temperature,
            display_value = temperature(format, maximum_temperature),
            history = history("temperature"), quality = quality(snapshot, "sensors"),
            thresholds = { warn = 75, critical = 90 },
            axis_format = function(value) return temperature(format, value) end,
        },
        power_overview = {
            label = translated(i18n, "metrics.power", "Power"),
            value = cpu_power,
            display_value = type(cpu_power) == "number" and string.format("%.1f W", cpu_power) or "—",
            history = history("cpu_power"), quality = quality(snapshot, "power"),
            budgets = power_budgets,
            unavailable_text = (snapshot.power and (snapshot.power.denied_zones or 0) > 0)
                and ("--sudo · " .. Technical.state(i18n, "denied")) or nil,
            axis_format = function(value) return string.format("%.0fW", value) end,
        },

        -- Processes ------------------------------------------------------
        process_table = process_table_model(i18n, process_rows, process_status,
            process_status_display, platform),

        -- Compute --------------------------------------------------------
        cpu_total = {
            label = translated(i18n, "metrics.utilization", "Utilization"),
            value = cpu_value,
            display_value = percent(format, cpu_value),
            history = history("cpu"), quality = quality(snapshot, "cpu"), min = 0, max = 100,
            thresholds = { warn = 70, critical = 90 },
            axis_format = percent_axis,
        },
        core_bars = {
            items = core_items, min = 0, max = 100,
            thresholds = { warn = 70, critical = 90 },
        },
        cpu_identity = { entries = cpu_identity_entries(snapshot, format, i18n) },
        load_summary = { entries = load_entries(snapshot, format, i18n) },
        core_table = {
            columns = {
                -- The core name is the row's identity, and on the machines where a
                -- core table is worth reading the names run past five characters:
                -- `cpu0`..`cpu31` fit, `cpu32` is exactly five, and from `cpu100`
                -- upward a five-cell column draws `cpu1…` for every core, so an
                -- idle 128-core host shows twenty-eight rows with the same text
                -- in every column.  `CONFIG_NR_CPUS` tops out at 8192 on the
                -- architectures this product runs on, so `cpu8191` is seven
                -- characters and seven is the bound -- the same arithmetic as the
                -- PID column's, and for the same reason: a guarantee is not a
                -- sample.  The preference stays at 8, so nothing on screen
                -- changes above the narrow band.
                { key = "core", label = "CPU", width = 8, min_width = 7, priority = 90 },
                { key = "total", label = translated(i18n, "metrics.total", "Total"),
                    width = 9, min_width = 7, align = "right", priority = 95,
                    token = function(_, row) return severity_token(row.total_value, 70, 90) end,
                    bar = function(_, row)
                        return row.total_value and math.min(1, row.total_value / 100) or nil
                    end },
                { key = "user", label = translated(i18n, "metrics.user", "User"),
                    width = 9, min_width = 7, align = "right", priority = 70 },
                { key = "system", label = translated(i18n, "metrics.system", "System"),
                    width = 9, min_width = 7, align = "right", priority = 65 },
                { key = "iowait", label = translated(i18n, "metrics.iowait", "I/O wait"),
                    width = 10, min_width = 7, align = "right", priority = 60 },
                { key = "irq", label = "IRQ", width = 8, min_width = 6,
                    align = "right", priority = 30, full_only = true },
                { key = "steal", label = translated(i18n, "metrics.steal", "Steal"),
                    width = 8, min_width = 6, align = "right", priority = 25, full_only = true },
            },
            rows = cores,
        },
        cpufreq_table = {
            columns = {
                { key = "policy", label = translated(i18n, "metrics.policy", "Policy"), width = 10, min_width = 8, priority = 90 },
                { key = "cpus", label = "CPU", width = 12, min_width = 6, priority = 70 },
                { key = "current", label = translated(i18n, "metrics.frequency", "Frequency"), width = 13, min_width = 9, align = "right", priority = 95 },
                { key = "source", label = translated(i18n, "metrics.source", "Source"), width = 14, min_width = 8, priority = 85 },
                { key = "temperature", label = translated(i18n, "cpufreq.related_temperature", "Related temp"),
                    width = 20, min_width = 12, priority = 52 },
                { key = "quality", label = translated(i18n, "inspector.quality", "Quality"), width = STATE_COLUMN_WIDTH, min_width = 8, priority = 75,
                    format = function(value) return Technical.state(i18n, value) end },
                { key = "minimum", label = translated(i18n, "metrics.minimum", "Minimum"), width = 12, min_width = 9, align = "right", priority = 50 },
                { key = "maximum", label = translated(i18n, "metrics.maximum", "Maximum"), width = 12, min_width = 9, align = "right", priority = 60 },
                { key = "governor", label = translated(i18n, "metrics.governor", "Governor"), width = 14, min_width = 9, priority = 65 },
                { key = "driver", label = translated(i18n, "metrics.driver", "Driver"), width = 16, min_width = 9, priority = 20, full_only = true },
            },
            rows = cpufreq_table_rows,
        },
        thermal_throttle_table = {
            columns = {
                { key = "cpu", label = "CPU", width = 8, min_width = 7, priority = 95 },
                { key = "core_new", label = translated(i18n, "thermal.core_new", "Core Δ"),
                    width = 12, min_width = 8, align = "right", priority = 95 },
                { key = "package_new", label = translated(i18n, "thermal.package_new", "Package Δ"),
                    width = 14, min_width = 9, align = "right", priority = 90 },
                { key = "core_total", label = translated(i18n, "thermal.core_total", "Core total"),
                    width = 14, min_width = 9, align = "right", priority = 70 },
                { key = "package_total", label = translated(i18n, "thermal.package_total", "Package total"),
                    width = 16, min_width = 9, align = "right", priority = 65 },
                { key = "core_ms", label = translated(i18n, "thermal.core_time", "Core ms"),
                    width = 12, min_width = 8, align = "right", priority = 35, full_only = true },
                { key = "package_ms", label = translated(i18n, "thermal.package_time", "Package ms"),
                    width = 14, min_width = 9, align = "right", priority = 30, full_only = true },
            },
            rows = thermal_throttle_table_rows,
        },
        cpuidle_table = {
            columns = {
                { key = "cpu", label = "CPU", width = 8, min_width = 6, priority = 95 },
                { key = "state", label = translated(i18n, "cpuidle.state", "Idle state"),
                    width = 18, min_width = 10, priority = 95 },
                { key = "usage_delta", label = translated(i18n, "cpuidle.usage_delta", "Usage Δ"),
                    width = 13, min_width = 9, align = "right", priority = 90 },
                { key = "reported_ms", label = translated(i18n, "cpuidle.reported_ms", "Reported ms Δ"),
                    width = 16, min_width = 11, align = "right", priority = 88 },
                { key = "rejected_delta", label = translated(i18n, "cpuidle.rejected_delta", "Rejected Δ"),
                    width = 14, min_width = 10, align = "right", priority = 68 },
                { key = "quality", label = translated(i18n, "inspector.quality", "Quality"),
                    width = STATE_COLUMN_WIDTH, min_width = 8, priority = 70,
                    format = function(value) return Technical.state(i18n, value) end },
                { key = "latency_us", label = translated(i18n, "cpuidle.latency_us", "Exit latency µs"),
                    width = 16, min_width = 11, align = "right", priority = 55 },
                { key = "target_us", label = translated(i18n, "cpuidle.target_us", "Target µs"),
                    width = 12, min_width = 9, align = "right", priority = 45 },
                { key = "disabled", label = translated(i18n, "cpuidle.disabled", "Disabled"),
                    width = 10, min_width = 8, priority = 35 },
                { key = "above_delta", label = translated(i18n, "cpuidle.above_delta", "Too short Δ"),
                    width = 14, min_width = 10, align = "right", priority = 30,
                    full_only = true },
                { key = "below_delta", label = translated(i18n, "cpuidle.below_delta", "Deeper fit Δ"),
                    width = 14, min_width = 10, align = "right", priority = 25,
                    full_only = true },
            },
            rows = cpuidle_table_rows,
            status_text = cpuidle_table_total > #cpuidle_table_rows
                and translated(i18n, "ui.rows_capped", "showing {visible} of {total}", {
                    visible = #cpuidle_table_rows, total = cpuidle_table_total }) or nil,
        },
        sensor_table = {
            columns = sensor_columns(i18n, sensor_table_rows),
            rows = sensor_table_rows,
        },
        power_table = {
            columns = {
                { key = "zone", label = translated(i18n, "metrics.device", "Zone"), width = 18, min_width = 10, priority = 100 },
                { key = "domain", label = translated(i18n, "metrics.source", "Source"), width = 15, min_width = 15, priority = 98 },
                { key = "constraint", label = translated(i18n, "power.constraint", "Constraint"), width = 16, min_width = 9, priority = 97 },
                { key = "power", label = translated(i18n, "metrics.power", "Power"), width = 12, min_width = 9, align = "right", priority = 100 },
                { key = "limit", label = translated(i18n, "power.limit", "Power cap"), width = 12, min_width = 9, align = "right", priority = 96 },
                { key = "usage", label = translated(i18n, "power.of_limit", "% of cap"), width = 22, min_width = 18, align = "right", priority = 95 },
                { key = "window", label = translated(i18n, "power.window", "Cap window"), width = 15, min_width = 11, align = "right", priority = 75 },
                { key = "interval", label = translated(i18n, "power.interval", "Sample window"), width = 15, min_width = 11, align = "right", priority = 65 },
                { key = "controls", label = translated(i18n, "power.controls", "Controls"), width = STATE_COLUMN_WIDTH, min_width = 8, priority = 50,
                    format = function(value) return Technical.state(i18n, value) end },
                { key = "headroom", label = translated(i18n, "power.headroom", "To cap"), width = 12, min_width = 9, align = "right", priority = 45 },
                { key = "energy", label = translated(i18n, "metrics.energy", "Energy"), width = 14, min_width = 9, align = "right", priority = 30, full_only = true },
                { key = "source", label = translated(i18n, "metrics.source", "Source"), width = 14, min_width = 9, priority = 20, full_only = true },
                { key = "state", label = translated(i18n, "metrics.state", "State"), width = STATE_COLUMN_WIDTH, min_width = 8, priority = 80,
                    format = function(value) return Technical.state(i18n, value) end },
            },
            rows = power_table_rows,
            status_text = translated(i18n, "power.comparison_note",
                "Sample / configured cap; this does not indicate throttling.")
                .. ((snapshot.power and (snapshot.power.denied_zones or 0) > 0)
                    and " " .. translated(i18n, "power.denied_note", "Power readings need root (--sudo).") or "")
                .. (power_table_total > #power_table_rows and " " .. translated(i18n, "ui.rows_capped",
                    "showing {visible} of {total}", { visible = #power_table_rows, total = power_table_total }) or ""),
        },

        -- Memory ---------------------------------------------------------
        memory_total = {
            label = translated(i18n, "metrics.memory", "Memory"),
            value = memory_value,
            display_value = percent(format, memory_value),
            secondary_value = snapshot.memory and bytes(format, snapshot.memory.used_bytes)
                .. " / " .. bytes(format, snapshot.memory.total_bytes) or nil,
            history = history("memory"),
            quality = quality(snapshot, "memory"), min = 0, max = 100,
            thresholds = { warn = 80, critical = 92 },
            axis_format = percent_axis,
        },
        memory_segments = memory_segment_model(snapshot, format, i18n),
        memory_detail = { entries = memory_detail_entries(snapshot, format) },
        swap_detail = { entries = swap_entries(snapshot, format) },
        memory_pressure = {
            label = translated(i18n, "metrics.memory_pressure", "Memory pressure"),
            value = memory_pressure,
            display_value = percent(format, memory_pressure),
            secondary_value = swap_value and ("swap " .. percent(format, swap_value)) or nil,
            history = history("memory_pressure"),
            quality = quality(snapshot, "pressure"), min = 0, max = 100,
            thresholds = { warn = 5, critical = 20 },
            axis_format = percent_axis,
        },
        memory_counters = { entries = paging_entries(snapshot, format) },
        numa_table = {
            columns = {
                { key = "node", label = translated(i18n, "inventory.numa_node", "NUMA node"),
                    width = 9, min_width = 5, priority = 100 },
                { key = "cpus", label = "CPUs", width = 6, min_width = 5, priority = 75, align = "right" },
                { key = "total", label = translated(i18n, "metrics.total", "Total"),
                    width = 13, min_width = 10, priority = 90, align = "right" },
                { key = "free", label = translated(i18n, "metrics.free", "Free"),
                    width = 13, min_width = 10, priority = 80, align = "right" },
                { key = "other_rate", label = translated(i18n, "numa.other_rate_short", "Cross-node p/s"),
                    width = 15, min_width = 10, priority = 30, align = "right",
                    full_only = true },
                { key = "state", label = translated(i18n, "metrics.state", "State"),
                    width = STATE_COLUMN_WIDTH, min_width = 8, priority = 40,
                    format = function(value) return Technical.state(i18n, value) end },
            },
            rows = numa_rows, ids = numa_ids, selected = numa_selected,
            empty_text = translated(i18n, "numa.no_nodes", "No NUMA nodes exposed"),
            status_text = snapshot.numa and (snapshot.numa.truncated
                or #(snapshot.numa.nodes or {}) > 128) and "…" or nil,
        },
        dimm_table = {
            columns = {
                { key = "id", label = translated(i18n, "inventory.identifier", "ID"),
                    width = 4, min_width = 4, priority = 110 },
                { key = "slot", label = translated(i18n, "memory_hw.locator", "Position"),
                    width = 22, min_width = 8, priority = 100 },
                { key = "size", label = translated(i18n, "metrics.capacity", "Size"),
                    width = 14, min_width = 10, priority = 95, align = "right" },
                { key = "type", label = translated(i18n, "metrics.medium", "Type"),
                    width = 10, min_width = 6, priority = 70 },
                { key = "speed", label = translated(i18n, "memory_hw.configured_rate", "Configured rate"),
                    width = 20, min_width = 10, priority = 80, align = "right" },
                { key = "manufacturer", label = translated(i18n, "memory_hw.manufacturer", "Manufacturer"),
                    width = 18, min_width = 8, priority = 50 },
                { key = "state", label = translated(i18n, "metrics.state", "State"),
                    width = STATE_COLUMN_WIDTH, min_width = 8, priority = 40,
                    format = function(value) return Technical.state(i18n, value) end },
            },
            rows = dimm_rows, ids = dimm_ids, selected = dimm_selected, empty_text = dimm_empty,
            status_text = snapshot.memory_devices and (snapshot.memory_devices.truncated
                or #(snapshot.memory_devices.devices or {}) > 256) and "…" or nil,
        },

        -- Storage --------------------------------------------------------
        storage_summary = {
            label = translated(i18n, "metrics.storage", "Storage"),
            display_value = "↓ " .. rate(format, disk_read) .. "  ↑ " .. rate(format, disk_write),
            history = history("disk_read"), quality = quality(snapshot, "disks"),
            axis_format = rate_axis,
        },
        io_pressure = {
            label = translated(i18n, "metrics.io_pressure", "I/O pressure"),
            value = io_pressure,
            display_value = percent(format, io_pressure),
            history = history("io_pressure"),
            quality = quality(snapshot, "pressure"), min = 0, max = 100,
            thresholds = { warn = 10, critical = 40 },
            axis_format = percent_axis,
        },
        disk_table = {
            columns = disk_columns(i18n, disks),
            rows = disks,
            status_text = disks_hidden > 0 and translated(i18n, "storage.hidden_devices",
                "{count} virtual devices hidden", { count = disks_hidden }) or nil,
        },
        mount_table = {
            columns = {
                { key = "mount", label = translated(i18n, "metrics.mount", "Mount"), width = 26, min_width = 12, priority = 95 },
                { key = "type", label = translated(i18n, "metrics.filesystem", "Type"), width = 10, min_width = 7, priority = 50 },
                { key = "used", label = translated(i18n, "metrics.used", "Used"), width = 9, min_width = 7, align = "right", priority = 90,
                    token = function(_, row) return severity_token(row.used_value, 80, 92) end,
                    bar = function(_, row)
                        return row.used_value and math.min(1, row.used_value / 100) or nil
                    end },
                { key = "available", label = translated(i18n, "metrics.available", "Available"), width = 12, min_width = 9, align = "right", priority = 85 },
                { key = "size", label = translated(i18n, "metrics.total", "Total"), width = 12, min_width = 9, align = "right", priority = 80 },
                { key = "inodes", label = translated(i18n, "metrics.inodes", "Inodes"), width = 9, min_width = 7, align = "right", priority = 30, full_only = true },
                { key = "quality", label = translated(i18n, "inspector.quality", "Quality"), width = STATE_COLUMN_WIDTH, min_width = 8, priority = 28, full_only = true,
                    format = function(value) return Technical.state(i18n, value) end,
                    token = function(_, row)
                        local severity = Quality.SEVERITY[row.quality]
                        return severity and ("metric." .. severity) or "text.muted"
                    end },
                { key = "readonly", label = "RW", width = 3, min_width = 2, priority = 20, full_only = true },
                { key = "source", label = translated(i18n, "metrics.source", "Source"), width = 22, min_width = 10, priority = 25, full_only = true },
            },
            rows = mount_table_rows,
            status_text = mount_status_text,
        },
        smart_hint = { entries = smart_hint_entries(snapshot, capabilities, i18n) },

        -- Network --------------------------------------------------------
        -- The interface name is the one value in this table that says *which*
        -- network interface a row is about: state, rates, MTU, MAC and errors
        -- all describe a card without naming it, and the MAC column is
        -- `full_only` at the lowest priority, so on a narrow terminal it is the
        -- first thing to go.  A truncated interface name is therefore worse
        -- than a shortened sentence -- two names cut to the same string are two
        -- identical rows, and the user is looking at a bug that is not there.
        --
        -- `IFNAMSIZ` is 16 including the terminator, so the kernel guarantees
        -- an interface name is at most 15 characters, and 15 is the only width
        -- that keeps *every* legal pair distinguishable rather than the ones a
        -- fixture happened to list.  Measured with `Width.truncate`: at the
        -- declared 8 cells, four same-model NICs (`enp0s31f1`..`enp0s31f4`) and
        -- the VLANs on them all read `enp0s31…`; at 12, the preference, two
        -- VLANs on one card still collide (`enp0s31f1.1…` for `.100` and
        -- `.101`); at 14, two 15-character legal names on one card collide
        -- (`enp0s31f10.40…` for `.4093` and `.4094`).  Anything less than the
        -- kernel's own bound only works for the names you thought of, and a
        -- guarantee is not a sample.
        network_summary = {
            label = translated(i18n, "metrics.network", "Network"),
            display_value = "↓ " .. rate(format, network_receive) .. "  ↑ " .. rate(format, network_transmit),
            history = history("network_receive"), quality = quality(snapshot, "network"),
            axis_format = rate_axis,
        },
        network_softnet = { entries = softnet_entries(snapshot, format, i18n) },
        network_table = {
            columns = {
                { key = "interface", label = translated(i18n, "metrics.interface", "Interface"), width = 15, min_width = 15, priority = 95 },
                { key = "state", label = translated(i18n, "metrics.state", "State"), width = 9, min_width = 7, priority = 70,
                    token = function(value)
                        if value == "up" then return "metric.good" end
                        if value == "down" then return "metric.critical" end
                        return nil
                    end },
                { key = "receive", label = translated(i18n, "metrics.receive", "Receive"), width = 12, min_width = 10, align = "right", priority = 92 },
                { key = "transmit", label = translated(i18n, "metrics.transmit", "Transmit"), width = 12, min_width = 10, align = "right", priority = 90 },
                { key = "speed", label = translated(i18n, "metrics.link", "Link"),
                  -- Ten, measured over every rate a real NIC reports: the longest
                  -- scaled output is `400 Gbit/s`.  A link rate is not bounded
                  -- the way an interface name or a PCI address is -- sysfs
                  -- reports whatever integer the driver put there -- so this is
                  -- the measured worst case of a known set and not a kernel
                  -- bound, and it is recorded as such rather than dressed up.
                  width = 12, min_width = 10, align = "right", priority = 40 },
                { key = "mtu", label = "MTU", width = 6, min_width = 5, align = "right", priority = 35 },
                { key = "mac", label = "MAC", width = 18, min_width = 17, priority = 25, full_only = true },
                { key = "errors", label = translated(i18n, "metrics.errors", "Err"), width = 6, min_width = 5, align = "right", priority = 30,
                    token = function(_, row)
                        return (row.error_value or 0) > 0 and "metric.warn" or nil
                    end },
                linux_host and { key = "link_changes", label = translated(i18n, "network.link_new", "Link chg"),
                  width = 9, min_width = 8, align = "right", priority = 50,
                  token = function(_, row)
                      return (row.link_change_value or 0) > 0 and "metric.warn" or nil
                  end } or nil,
            },
            rows = interfaces,
            status_text = network_source_status(snapshot, i18n),
        },
        address_table = {
            columns = {
                { key = "interface", label = translated(i18n, "metrics.interface", "Interface"), width = 15, min_width = 15, priority = 90 },
                { key = "family", label = translated(i18n, "metrics.family", "Family"), width = 6, min_width = 5, priority = 70 },
                { key = "address", label = translated(i18n, "metrics.address", "Address"), width = 30, min_width = 14, priority = 95 },
                { key = "netmask", label = translated(i18n, "metrics.netmask", "Netmask"), width = 20, min_width = 12, priority = 40, full_only = true },
                { key = "default_route", label = translated(i18n, "metrics.default_route", "Default"), width = 8, min_width = 7, priority = 50 },
            },
            rows = addresses,
            status_text = snapshot.network and snapshot.network.addresses_status
                and snapshot.network.addresses_status ~= "ok"
                and Technical.state(i18n, snapshot.network.addresses_status) or nil,
        },
        connection_table = {
            ids = connection_ids,
            selected = connection_selected_index,
            columns = {
                { key = "protocol", label = translated(i18n, "metrics.protocol", "Proto"), width = 7, min_width = 5, priority = 80 },
                { key = "local_endpoint", label = translated(i18n, "metrics.local_endpoint", "Local"), width = 26, min_width = 14, priority = 90 },
                { key = "remote_endpoint", label = translated(i18n, "metrics.remote_endpoint", "Remote"), width = 28, min_width = 14, priority = 85 },
                { key = "state", label = translated(i18n, "metrics.state", "State"), width = 13, min_width = 8, priority = 70,
                    token = function(value)
                        if value == "ESTABLISHED" then return "metric.good" end
                        if value == "LISTEN" then return "accent.primary" end
                        return nil
                    end },
                { key = "process", label = translated(i18n, "metrics.process", "Process"), width = 22, min_width = 10, priority = 95 },
                { key = "queue", label = translated(i18n, "metrics.queue", "Queue"), width = 10, min_width = 7, align = "right", priority = 25, full_only = true },
                { key = "uid", label = "UID", width = 8, min_width = 6, align = "right", priority = 20, full_only = true },
            },
            rows = connections,
            status_text = translated(i18n, "network.connection_status",
                "{count} sockets · owner mapping {quality}", {
                    count = snapshot.connections and snapshot.connections.total or #connections,
                    quality = Technical.state(i18n, snapshot.connections and snapshot.connections.owner_scan
                        and snapshot.connections.owner_scan.status or "unavailable"),
                }) .. (owner_target and translated(i18n, "network.owner_filter_status",
                    " · PID {pid}: {visible}/{matching} sockets · {state} · Esc clears", {
                        pid = owner_target.pid, visible = #connections,
                        matching = matching_connections,
                        state = target_status == "loading" and translated(i18n,
                            "network.owner_filter_loading", "finding owners")
                            or target_status == "changed" and translated(i18n,
                                "network.owner_filter_changed", "process identity changed")
                            or target_status == "not_scanned" and translated(i18n,
                                "network.owner_filter_not_scanned", "scan did not reach PID")
                            or Technical.state(i18n, target_status or "unavailable"),
                    }) or "")
                .. (type(options.connection_query) == "string" and options.connection_query ~= ""
                    and translated(i18n, "network.filter_status",
                        " · {visible}/{matching} shown · Filter: {query}", {
                            visible = #connections, matching = matching_connections,
                            query = options.connection_query,
                        }) or ""),
        },

        -- GPU ------------------------------------------------------------
        gpu_summary = {
            secondary_value = graphics_power,
            secondary_values = graphics_power_compact,
            label = translated(i18n, "metrics.gpu", "GPU"),
            value = first_gpu.utilization_percent,
            display_value = #gpu_devices == 0 and translated(i18n, "ui.no_data", "No data")
                or percent(format, first_gpu.utilization_percent),
            history = history("gpu"), quality = quality(snapshot, "gpus"), min = 0, max = 100,
            thresholds = { warn = 70, critical = 90 },
            axis_format = percent_axis,
        },
        gpu_table = {
            columns = {
                { key = "gpu", label = "GPU", width = 26, min_width = 12, priority = 95 },
                { key = "card", label = "Card", width = 10, min_width = 8, priority = 93 },
                { key = "vendor", label = translated(i18n, "metrics.vendor", "Vendor"), width = 16, min_width = 8, priority = 50 },
                { key = "driver", label = translated(i18n, "metrics.driver", "Driver"), width = 12, min_width = 8, priority = 45 },
                { key = "utilization", label = translated(i18n, "metrics.utilization", "Util"), width = 9, min_width = 7, align = "right", priority = 90 },
                { key = "memory", label = translated(i18n, "metrics.memory", "Memory"), width = 20, min_width = 12, align = "right", priority = 85 },
                { key = "frequency", label = translated(i18n, "metrics.frequency", "Frequency"), width = 13, min_width = 9, align = "right", priority = gpu_has_frequency and 82 or 15, full_only = not gpu_has_frequency },
                { key = "pcie", label = "PCIe", width = 18, min_width = 9, priority = 25, full_only = true },
                { key = "temperature", label = translated(i18n, "metrics.temperature", "Temp"), width = 9, min_width = 7, align = "right", priority = 70 },
                { key = "power", label = translated(i18n, "metrics.power", "Power"), width = 10, min_width = 8, align = "right", priority = gpu_has_power and 80 or 14, full_only = not gpu_has_power },
                { key = "power_limit", label = translated(i18n, "power.limit", "Power cap"), width = 12, min_width = 8, align = "right", priority = gpu_has_cap and 78 or 13, full_only = not gpu_has_cap },
                { key = "power_usage", label = translated(i18n, "power.of_limit", "% of cap"), width = 22, min_width = 18, align = "right", priority = gpu_has_cap and 77 or 12, full_only = not gpu_has_cap },
                { key = "limits", label = translated(i18n, "limits.current", "Current limits"), width = 24, min_width = 12, priority = gpu_has_limits and 76 or 11, full_only = not gpu_has_limits },
                { key = "fan", label = translated(i18n, "metrics.fan", "Fan"), width = 10, min_width = 7, align = "right", priority = 30, full_only = true },
            },
            rows = gpu_table_rows,
        },
        gpu_process_table = {
            ids = gpu_process_table_ids,
            selected = gpu_process_selected_index,
            columns = {
                { key = "gpu", label = "GPU", width = 10, min_width = 6, priority = 70 },
                -- The same seven as the process table's own pid column, and for
                -- the same reason: this table declares a second one, and the
                -- fixture that found the first one had no GPU in it, so the
                -- second was never rendered and never cut and never checked.
                -- `4194304` and `4194303` are the pair that proves it -- they
                -- differ in one digit, and a six-cell column draws both as
                -- `41943…`, which is a different process from the one named.
                { key = "pid", label = "PID", width = 8, min_width = 7, align = "right", priority = 80 },
                { key = "process", label = translated(i18n, "metrics.process", "Process"), width = 22, min_width = 10, priority = 95 },
                { key = "utilization", label = translated(i18n, "metrics.utilization", "Utilization"), width = 12, min_width = 8, align = "right", priority = 90 },
                { key = "memory", label = translated(i18n, "metrics.memory", "Memory"), width = 14, min_width = 10, align = "right", priority = 85 },
                { key = "engines", label = translated(i18n, "metrics.engines", "Engines"), width = 30, min_width = 12, priority = 25, full_only = true },
                { key = "quality", label = translated(i18n, "inspector.quality", "Quality"), width = STATE_COLUMN_WIDTH, min_width = 8, priority = 20, full_only = true,
                    format = function(value) return Technical.state(i18n, value) end },
            },
            rows = gpu_process_table_rows,
            status_text = translated(i18n, "gpu.process_status",
                "GPU processes: {visible}/{total} · scan {quality}", {
                    visible = #gpu_process_table_rows,
                    total = gpu_process_total,
                    quality = Technical.state(i18n, snapshot.gpus and snapshot.gpus.process_scan
                        and (snapshot.gpus.process_scan.quality or snapshot.gpus.process_scan.status)
                        or "unavailable"),
                }),
        },

        -- Workloads ------------------------------------------------------
        workload_summary = {
            label = translated(i18n, "metrics.workloads", "Workloads"),
            value = workload_root and workload_root.cpu_utilization_percent,
            display_value = workload_root and percent(format, workload_root.cpu_utilization_percent)
                or translated(i18n, "ui.no_data", "No data"),
            history = history("workload_cpu"), quality = quality(snapshot, "workloads"),
            min = 0, max = 100, thresholds = { warn = 70, critical = 90 },
            axis_format = percent_axis,
        },
        workload_table = {
            columns = {
                { key = "workload", label = translated(i18n, "metrics.workload", "Workload"), width = 34, min_width = 14, priority = 95 },
                { key = "cpu", label = "CPU", width = 9, min_width = 7, align = "right", priority = 90,
                    token = function(_, row) return severity_token(row.raw_cpu, 70, 90) end,
                    bar = function(_, row)
                        return row.raw_cpu and row.raw_cpu >= 0
                            and math.min(1, row.raw_cpu / 100) or nil
                    end },
                { key = "memory", label = translated(i18n, "metrics.memory", "Memory"), width = 12, min_width = 9, align = "right", priority = 85 },
                { key = "read", label = translated(i18n, "metrics.read", "Read"), width = 12, min_width = 9, align = "right", priority = 50 },
                { key = "write", label = translated(i18n, "metrics.write", "Write"), width = 12, min_width = 9, align = "right", priority = 48 },
                { key = "processes", label = translated(i18n, "metrics.processes", "Procs"), width = 7, min_width = 6, align = "right", priority = 60 },
                { key = "threads", label = translated(i18n, "metrics.threads", "Thr"), width = 7, min_width = 6, align = "right", priority = 58 },
                { key = "pressure", label = translated(i18n, "metrics.pressure", "Pressure"), width = 9, min_width = 7, align = "right", priority = 30, full_only = true },
                { key = "quality", label = translated(i18n, "inspector.quality", "Quality"), width = STATE_COLUMN_WIDTH, min_width = 8, priority = 22, full_only = true,
                    format = function(value) return Technical.state(i18n, value) end },
            },
            rows = workload_table_rows,
            ids = workload_row_ids,
            selected = workload_selected_index,
            status_text = workload_status_text,
            panel_title = snapshot.workloads and WORKLOAD_KINDS[snapshot.workloads.kind]
                and translated(i18n, WORKLOAD_KINDS[snapshot.workloads.kind].title[1],
                    WORKLOAD_KINDS[snapshot.workloads.kind].title[2]) or nil,
        },
        workload_detail = { entries = workload_detail_entries(snapshot, format,
            i18n, workload_selected) },

        -- System ---------------------------------------------------------
        system_identity = { entries = system_identity_entries(snapshot, format, i18n) },
        system_kernel = { entries = system_kernel_entries(snapshot, format, i18n) },
        system_firmware = { entries = system_firmware_entries(snapshot, format, i18n) },
        system_limits = { entries = system_limits_entries(snapshot, format, i18n) },
        battery_bars = {
            items = battery_items(snapshot, format, i18n),
            min = 0, max = 100,
            thresholds = { warn = 30, critical = 15 },
            severity_invert = true,
            empty_text = translated(i18n, "system.no_power_supply", "No battery or adapter"),
        },
        system_devices = {
            columns = {
                { key = "bus", label = translated(i18n, "inventory.bus", "Bus"),
                  width = 5, min_width = 4, priority = 80 },
                { key = "id", label = translated(i18n, "inventory.identifier", "ID"),
                  -- A PCI address is `%04x:%02x:%02x.%d` -- twelve characters,
                  -- every time, for every device, forever.  At eight cells the
                  -- two functions of one controller (`0000:00:1f.6` and
                  -- `0000:00:1f.7`, the management and data ports of one board
                  -- NIC) both read `0000:00:…`, and since the model name on the
                  -- neighbouring column is the same for both, the two rows are
                  -- the same row.  Unlike an address, this one has a bound, so
                  -- the guarantee can simply be the bound.
                  width = 12, min_width = 12, priority = 75 },
                { key = "device", label = translated(i18n, "inventory.device", "Device"),
                  width = 34, min_width = 16, priority = 95 },
                { key = "class", label = translated(i18n, "inventory.class", "Class"),
                  width = 8, min_width = 6, priority = 60 },
            },
            rows = system_devices_rows,
            ids = system_device_ids,
            selected = system_device_selected,
            empty_text = translated(i18n, "system.no_devices", "No devices exposed"),
            status_text = system_query ~= "" and translated(i18n,
                "system.device_filter_status",
                "{matches} matches · {visible}/{total} rows · Filter: {query} · Esc clears", {
                    matches = system_device_matches, visible = #system_device_ids,
                    total = system_device_total, query = system_query,
                }) .. (system_devices_truncated and " · …" or "")
                or string.format("PCI %s · USB %s · %s %d%s",
                    system_pci_total or "—", system_usb_total or "—",
                    translated(i18n, "metrics.total", "Total"), #system_device_ids,
                    system_devices_truncated and " · …" or ""),
        },

        -- Insights -------------------------------------------------------
        collector_table = {
            columns = {
                { key = "collector", label = translated(i18n, "insights.collector", "Collector"), width = 14, min_width = 10, priority = 95 },
                { key = "status", label = translated(i18n, "metrics.state", "State"), width = STATE_COLUMN_WIDTH, min_width = 9, priority = 90,
                    format = function(value) return Technical.state(i18n, value) end,
                    token = function(_, row)
                        if not row.available then return "text.muted" end
                        if row.status == "denied" or row.status == "error" then return "metric.critical" end
                        return "metric.good"
                    end },
                { key = "quality", label = translated(i18n, "inspector.quality", "Quality"), width = STATE_COLUMN_WIDTH, min_width = 8, priority = 70,
                    format = function(value) return Technical.state(i18n, value) end },
                { key = "source", label = translated(i18n, "metrics.source", "Source"), width = 34, min_width = 12, priority = 50 },
                { key = "reason", label = translated(i18n, "inspector.reason", "Reason"), width = 28, min_width = 10, priority = 30, full_only = true,
                    format = function(value) return Technical.reason(i18n, value) end },
            },
            rows = collector_rows(snapshot, capabilities, i18n),
            status_text = translated(i18n, "insights.processes", "Processes: {count}",
                { count = process_count }) .. " · "
                .. translated(i18n, "insights.gpu_devices", "GPU devices: {count}",
                    { count = #gpu_devices }),
        },
        inspector_table = {
            columns = {
                { key = "key", label = translated(i18n, "insights.key", "Key"), width = 4, min_width = 3, priority = 80 },
                { key = "inspector", label = translated(i18n, "insights.inspector", "Inspector"), width = 30, min_width = 14, priority = 95 },
                { key = "status", label = translated(i18n, "metrics.state", "State"), width = STATE_COLUMN_WIDTH, min_width = 9, priority = 90,
                    format = function(value) return Technical.state(i18n, value) end,
                    token = function(_, row) return row.available and "metric.good" or "text.muted" end },
                { key = "reason", label = translated(i18n, "inspector.reason", "Reason"), width = 26, min_width = 10, priority = 40, full_only = true,
                    format = function(value) return Technical.reason(i18n, value) end },
            },
            rows = inspector_rows(capabilities, i18n),
        },
        advice_list = {
            entries = advice_entries(snapshot, capabilities, i18n,
                options.privilege, linux_host),
        },
    }
    if snapshot.cpu_clocks and (snapshot.cpu_clocks.supported_cpus or 0)>0 then
        table.insert(models.core_table.columns,3,{key="effective",
            label=translated(i18n,"metrics.effective_frequency","Effective"),
            width=14,min_width=10,align="right",priority=85})
        models.core_table.columns[#models.core_table.columns+1]={key="effective_window",
            label=translated(i18n,"cpu_clock.sample_window","Window"),
            width=14,min_width=10,align="right",priority=20,full_only=true}
    end
    return models
end

return M
